import AppKit
import Combine
import Darwin
import ExplorerCore

/// Optional session persistence is independent of security-scoped references.
/// Every filesystem call runs on one FIFO queue; none runs on MainActor.
@MainActor
final class BrowserSessionController {
    enum Restoration: Sendable {
        case none, restored(WorkspaceSession), unavailable
    }

    private let worker: BrowserSessionWorker
    private let gate = BrowserSessionGate()
    private var enabled = false
    private(set) var isReady = false
    private(set) var lastFailure: String?

    init(stateDirectory: URL?) { worker = BrowserSessionWorker(directory: stateDirectory) }

    func restore(enabled: Bool) async -> Restoration {
        self.enabled = enabled
        isReady = false
        let token = gate.advance(enabled: enabled)
        let result = await worker.restore(enabled: enabled, gate: gate, token: token)
        guard gate.isCurrent(token) else { return .none }
        isReady = true
        switch result {
        case .success(let snapshot):
            lastFailure = nil
            return snapshot.map(Restoration.restored) ?? .none
        case .failure:
            lastFailure = enabled ? "The saved session could not be safely restored. It was preserved for inspection." : "The saved session could not be safely forgotten."
            return .unavailable
        }
    }

    /// Called with the emitted preference value, without relying on @Published
    /// having assigned its backing property yet. Enabling records current UI;
    /// it never replays a stale session over a running browser.
    func setEnabled(_ value: Bool) {
        enabled = value
        isReady = true
        lastFailure = nil
        let token = gate.advance(enabled: value)
        if !value { worker.forget(gate: gate, token: token) }
    }

    func record(_ snapshot: WorkspaceSession) {
        guard enabled, isReady else { return }
        let token = gate.advance(enabled: true)
        worker.save(snapshot, gate: gate, token: token)
    }

    /// FIFO drain includes an in-flight save followed by Disable's removal.
    /// Once this returns after disabling, no earlier save can recreate the file.
    func flush() async -> String? {
        lastFailure = await worker.flush()
        return lastFailure
    }
}

@MainActor
extension BrowserViewController {
    /// Root calls before the first loadLocation. A concurrent navigation/toggle
    /// wins over startup restoration; missing targets are kept for honest reads.
    @discardableResult
    func restoreBrowserSessionIfEnabled(expectedVisit: UUID? = nil) async -> Bool {
        let visit = expectedVisit ?? sessionID
        let result = await sessionPersistence.restore(enabled: settings.restoresSession)
        guard settings.restoresSession, sessionID == visit else {
            recordBrowserSession()
            return false
        }
        switch result {
        case .restored(let snapshot):
            do {
                let restored = try snapshot.restoredTabs()
                tabs = restored.tabs
                for index in tabs.indices { tabs[index].resolveFolderView(mode: settings.viewMode, sort: tabs[index].sort) }
                activeID = restored.activeID
                restoringScroll = true
                return true
            } catch { status.stringValue = "The saved session was invalid. Start a new tab to continue." }
        case .unavailable: status.stringValue = sessionPersistence.lastFailure ?? "The saved session is unavailable."
        case .none: break
        }
        return false
    }

    /// Root hooks tab/navigation/filter/sort/selection/scroll changes here.
    /// Capture current selection directly: calling saveViewState would recurse
    /// if that method itself is one of the integration hooks.
    func recordBrowserSession() {
        refreshConnectedLocations()
        guard !metadataSearch.isShowingResults else { return }
        if let workspace { workspace.recordSession(); return }
        guard settings.restoresSession, sessionPersistence.isReady, !tabs.isEmpty else { return }
        if isArchiveLocation { captureArchiveViewState() }
        else if !restoringScroll, !isInstallingLocation {
            tabs[activeIndex].state = NavigationState(selection: selectedURLs,
                scrollOffset: location == .computer ? 0 : currentScrollOffset)
        }
        do { sessionPersistence.record(try WorkspaceSession.capture(tabs, activeID: activeID)) }
        catch { status.stringValue = "This session could not be saved safely." }
    }

    func sessionRestorePreferenceChanged(_ enabled: Bool) {
        if let workspace { workspace.sessionPreferenceChanged(enabled); return }
        sessionPersistence.setEnabled(enabled)
        if enabled {
            // @Published emits before its property assignment; defer capture to
            // the next main-actor turn, then respect any newer preference change.
            Task { @MainActor [weak self] in self?.recordBrowserSession() }
        }
    }

    func flushBrowserSession() async {
        if isBrowserSuspended {
            await operationPreparationTask?.value
            await selectionGroupWindow?.drain()
        }
        await folderViews.drain()
        if let workspace { await workspace.flushSession(); return }
        recordBrowserSession()
        if let failure = await sessionPersistence.flush() { status.stringValue = failure }
    }
}

private final class BrowserSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID()
    private var enabled = false
    func advance(enabled: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        token = UUID(); self.enabled = enabled
        return token
    }
    func isCurrent(_ value: UUID, requireEnabled: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == value && (!requireEnabled || enabled)
    }
}

private final class BrowserSessionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.WorkspaceSession", qos: .utility)
    private let store: BrowserSessionStore?
    // Accessed only on queue. Errors are deliberately fixed text without paths,
    // decoded values, bookmark bytes or user-authored filters/selections.
    private var failure: String?

    init(directory: URL?) { store = directory.map(BrowserSessionStore.init) }

    func restore(enabled: Bool, gate: BrowserSessionGate, token: UUID) async -> Result<WorkspaceSession?, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard gate.isCurrent(token), let store else { continuation.resume(returning: .success(nil)); return }
                do {
                    if enabled { continuation.resume(returning: .success(try store.load())) }
                    else { try store.forget(); continuation.resume(returning: .success(nil)) }
                    failure = nil
                } catch {
                    failure = "Session storage could not be read safely. Existing data was preserved."
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    func save(_ snapshot: WorkspaceSession, gate: BrowserSessionGate, token: UUID) {
        queue.async { [self] in
            guard gate.isCurrent(token, requireEnabled: true), let store else { return }
            do {
                let data = try store.encoded(snapshot)
                guard gate.isCurrent(token, requireEnabled: true) else { return }
                try store.save(data)
                failure = nil
            } catch { failure = "The session could not be saved. Existing session data was preserved." }
        }
    }

    func forget(gate: BrowserSessionGate, token: UUID) {
        queue.async { [self] in
            guard gate.isCurrent(token), let store else { return }
            do { try store.forget(); failure = nil }
            catch { failure = "The session could not be forgotten safely. Other app data was preserved." }
        }
    }

    func flush() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: failure) }
        }
    }
}

struct BrowserSessionStore: Sendable {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    private var store: BrowserSnapshotFile {
        BrowserSnapshotFile(directory: directory, name: "browser-session-v1.json", maximumBytes: 1_048_576)
    }
    private struct Document: Codable {
        let owner: String
        let snapshot: WorkspaceSession
    }
    private func decode(_ data: Data) throws -> WorkspaceSession {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.owner == "mac-explorer-workspace-session" else { throw BrowserSnapshotFile.Failure.invalidDocument }
        try document.snapshot.validate()
        return document.snapshot
    }
    func load() throws -> WorkspaceSession? { try store.read().map(decode) }
    func encoded(_ snapshot: WorkspaceSession) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(owner: "mac-explorer-workspace-session", snapshot: snapshot))
        guard data.count <= 1_048_576 else { throw BrowserSnapshotFile.Failure.oversized }
        return data
    }
    func save(_ data: Data) throws { try store.write(data) { _ = try decode($0) } }
    func forget() throws { try store.forget { _ = try decode($0) } }
}
