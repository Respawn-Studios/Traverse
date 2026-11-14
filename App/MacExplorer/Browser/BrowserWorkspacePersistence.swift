import AppKit
import ExplorerCore

@MainActor
final class BrowserWorkspacePersistence {
    private let worker: WorkspaceSnapshotWorker
    private let gate = WorkspaceSnapshotGate()
    private var enabled = false
    private(set) var lastFailure: String?
    #if DEBUG
    var beforeRestoreResult: (@MainActor () async -> Void)?
    #endif
    init(stateDirectory: URL?) { worker = WorkspaceSnapshotWorker(directory: stateDirectory) }

    func restore(enabled: Bool, legacyPane: UUID, viewMode: String) async -> PaneWorkspaceSnapshot? {
        self.enabled = enabled
        let generation = gate.advance(enabled: enabled)
        let result = await worker.restore(enabled: enabled, legacyPane: legacyPane, viewMode: viewMode, gate: gate, generation: generation)
        #if DEBUG
        if let beforeRestoreResult { await beforeRestoreResult() }
        #endif
        guard gate.current(generation) else { return nil }
        switch result {
        case .success(let snapshot): lastFailure = nil; return snapshot
        case .failure: lastFailure = "The saved workspace could not be read safely. Existing data was preserved."; return nil
        }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        let generation = gate.advance(enabled: value)
        if !value { worker.forget(gate: gate, generation: generation) }
    }
    func record(_ snapshot: PaneWorkspaceSnapshot) {
        guard enabled else { return }
        let generation = gate.advance(enabled: true)
        worker.save(snapshot, gate: gate, generation: generation)
    }
    func flush() async -> String? { lastFailure = await worker.flush(); return lastFailure }
}

private final class WorkspaceSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var enabled = false
    func advance(enabled: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); self.enabled = enabled; return generation
    }
    func current(_ value: UUID, requireEnabled: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == value && (!requireEnabled || enabled)
    }
}

private final class WorkspaceSnapshotWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.PaneWorkspacePersistence", qos: .utility)
    private let directory: URL?
    private var failure: String?
    private struct Document: Codable { let owner: String; let snapshot: PaneWorkspaceSnapshot }
    init(directory: URL?) { self.directory = directory }
    private var store: BrowserSnapshotFile? {
        directory.map { BrowserSnapshotFile(directory: $0, name: "browser-workspace-v2.json", maximumBytes: 4_194_304) }
    }
    private func decode(_ data: Data) throws -> PaneWorkspaceSnapshot {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.owner == "mac-explorer-pane-workspace" else { throw BrowserSnapshotFile.Failure.invalidDocument }
        try document.snapshot.validate()
        return document.snapshot
    }
    func restore(enabled: Bool, legacyPane: UUID, viewMode: String, gate: WorkspaceSnapshotGate, generation: UUID) async -> Result<PaneWorkspaceSnapshot?, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard gate.current(generation), let store, let directory else { continuation.resume(returning: .success(nil)); return }
                do {
                    if !enabled {
                        try store.forget { _ = try self.decode($0) }
                        try BrowserSessionStore(directory).forget()
                        failure = nil
                        continuation.resume(returning: .success(nil)); return
                    }
                    if let data = try store.read() {
                        let result = try decode(data); failure = nil
                        continuation.resume(returning: .success(result)); return
                    }
                    // An invalid/newer pane document never falls back to legacy.
                    // The old snapshot stays intact as migration evidence.
                    if let legacy = try BrowserSessionStore(directory).load() {
                        let result = PaneWorkspaceSnapshot(layout: PaneLayout(paneID: legacyPane), activePane: legacyPane,
                            panes: [.init(id: legacyPane, tabs: legacy, viewMode: viewMode)])
                        try result.validate(); failure = nil
                        continuation.resume(returning: .success(result)); return
                    }
                    failure = nil; continuation.resume(returning: .success(nil))
                } catch { failure = "Workspace restoration could not complete safely."; continuation.resume(returning: .failure(error)) }
            }
        }
    }
    func save(_ snapshot: PaneWorkspaceSnapshot, gate: WorkspaceSnapshotGate, generation: UUID) {
        queue.async { [self] in
            guard gate.current(generation, requireEnabled: true), let store else { return }
            do {
                try snapshot.validate()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(Document(owner: "mac-explorer-pane-workspace", snapshot: snapshot))
                guard gate.current(generation, requireEnabled: true) else { return }
                try store.write(data) { _ = try self.decode($0) }
                failure = nil
            } catch { failure = "The workspace could not be saved safely. Existing data was preserved." }
        }
    }
    func forget(gate: WorkspaceSnapshotGate, generation: UUID) {
        queue.async { [self] in
            guard gate.current(generation), let store, let directory else { return }
            do { try store.forget { _ = try self.decode($0) }; try BrowserSessionStore(directory).forget(); failure = nil }
            catch { failure = "The workspace could not be forgotten safely. Existing data was preserved." }
        }
    }
    func flush() async -> String? {
        await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: failure) } }
    }
}

@MainActor
extension BrowserWorkspaceController {
    func begin() {
        guard !isClosing, !sessionReady, startupTask == nil else { return }
        _ = view
        let visits = browsers.mapValues { ($0.sessionID, $0.activeID) }
        let initialState = try? captureSessionSnapshot(syncViewState: false)
        let initialFrame = view.window?.frame
        let token = UUID()
        startupGeneration = token
        startupTask = Task { [weak self] in
            guard let self, !self.isClosing else { return }
            defer { if self.startupGeneration == token { self.startupTask = nil } }
            let settings = self.primaryBrowser.settings
            let mode = self.hasIncomingFolderRequest ? .computer : settings.startupMode, selectedProfile = settings.startupProfileID
            let enabled = mode == .lastSession
            var snapshot = await self.persistence.restore(enabled: enabled, legacyPane: self.primaryBrowser.paneID,
                viewMode: self.primaryBrowser.effectiveViewMode.rawValue)
            var updateResume: UpdateWorkspaceResume?
            var updateFailure: String?
            do {
                let build = UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
                updateResume = try await self.updateResumeStore.read(build: build)
            } catch { updateFailure = "Your previous update workspace could not be read safely. Saved information was preserved." }
            var profileFailure: String?
            var openedTemplate: (WorkspaceLaunchProfile, String)?
            if mode == .profile, updateResume == nil {
                do {
                    let saved = try await self.launchProfileStore.load()
                    if let profile = saved.library.profiles.first(where: { $0.id == selectedProfile }) {
                        snapshot = profile.snapshot
                        openedTemplate = (profile, try await self.profileWorkspaceStore.key(for: profile))
                    } else { snapshot = nil }
                    if snapshot == nil { profileFailure = "The selected launch profile is missing. Choose another in Launch Profiles; saved data was preserved." }
                } catch { profileFailure = "The launch profile could not be read safely. Open Launch Profiles to review it; saved data was preserved." }
            }
            guard !Task.isCancelled, !self.isClosing, self.startupGeneration == token else { return }
            let unchanged = initialState != nil && (try? self.captureSessionSnapshot(syncViewState: false)) == initialState && self.browsers.allSatisfy { id, browser in
                visits[id]?.0 == browser.sessionID && visits[id]?.1 == browser.activeID
            }
            let samePolicy = settings.startupMode == mode && (mode != .profile || settings.startupProfileID == selectedProfile)
            var appliedUpdate = false
            if let updateResume { snapshot = updateResume.workspace }
            if !self.hasIncomingFolderRequest, mode != .computer || updateResume != nil, samePolicy, unchanged, let snapshot {
                self.restoringSession = true
                do {
                    try self.applyRestoredSnapshot(snapshot)
                    if let updateResume {
                        appliedUpdate = true
                        if let window = self.view.window, window.frame == initialFrame,
                           let screen = window.screen ?? NSScreen.main {
                            window.setFrame(UpdateWorkspaceResume.rect(updateResume.frame).clamped(to: screen.visibleFrame), display: true)
                        }
                        do { try await self.updateResumeStore.consume(updateResume.id) }
                        catch { updateFailure = "Your windows were restored, but the update checkpoint could not be cleared. Saved information was preserved." }
                    }
                    if let openedTemplate { self.profileWorkspaces.noteStartupTemplate(openedTemplate.0, key: openedTemplate.1) }
                }
                catch { self.activeBrowser.status.stringValue = "The saved pane layout could not be restored safely." }
                self.restoringSession = false
            }
            self.sessionReady = true
            self.persistence.setEnabled(self.primaryBrowser.settings.restoresSession)
            for browser in self.browsers.values { self.startBrowser(browser) }
            if appliedUpdate, let updateResume { self.restoreUpdateTools(updateResume) }
            if let failure = self.persistence.lastFailure { self.activeBrowser.status.stringValue = failure }
            if samePolicy, let profileFailure { self.activeBrowser.status.stringValue = profileFailure }
            if let updateFailure { self.activeBrowser.status.stringValue = updateFailure }
            self.recordSession()
        }
    }

    func recordSession() {
        primaryBrowser.refreshConnectedLocations()
        guard sessionReady, !restoringSession else { return }
        profileWorkspaceController?.workspaceChanged()
        guard primaryBrowser.settings.restoresSession else { return }
        do {
            let snapshot = try captureSessionSnapshot(syncViewState: true)
            try snapshot.validate(); persistence.record(snapshot)
        } catch { activeBrowser.status.stringValue = "This workspace could not be saved safely." }
    }
    func captureSessionSnapshot(syncViewState: Bool) throws -> PaneWorkspaceSnapshot {
        let panes = try layout.paneIDs.compactMap { id -> PaneWorkspaceSnapshot.Pane? in
                guard let browser = browsers[id] else { return nil }
                if syncViewState, browser.isArchiveLocation { browser.captureArchiveViewState() }
                else if syncViewState, !browser.isInstallingLocation, !browser.restoringScroll, !browser.metadataSearch.isShowingResults {
                    browser.tabs[browser.activeIndex].state = NavigationState(selection: browser.selectedURLs,
                        scrollOffset: browser.showsComputerVolumes ? 0 : browser.currentScrollOffset)
                }
                return .init(id: id, tabs: try WorkspaceSession.capture(browser.tabs, activeID: browser.activeID),
                    viewMode: (browser.isArchiveLocation ? browser.paneViewMode : browser.effectiveViewMode).rawValue)
            }
            let snapshot = PaneWorkspaceSnapshot(layout: layout, activePane: activeBrowser.paneID, panes: panes,
                sidebar: sidebarSnapshot)
        try snapshot.validate()
        return snapshot
    }
    func sessionPreferenceChanged(_ enabled: Bool) {
        persistence.setEnabled(enabled)
        if enabled { Task { @MainActor [weak self] in self?.recordSession() } }
    }
    func flushSession(closingTools: Bool = false) async {
        await quickProfileSwitcher?.drain()
        await profileWorkspaceController?.flush(closing: closingTools || isClosing)
        await primaryBrowser.folderViews.drain()
        if closingTools { launchProfilesWindow?.close() }
        await launchProfilesModel?.drain()
        recordSession()
        if let failure = await persistence.flush() { activeBrowser.status.stringValue = failure }
    }
}
