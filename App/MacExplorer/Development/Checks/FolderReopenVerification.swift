#if DEBUG
import AppKit
import Darwin
import ExplorerCore

/// Two independent native processes, one explicit picker, and an isolated store.
/// Only the offered generated listing fixture can be remembered or enumerated.
@MainActor
enum FolderReopenVerification {
    /// Controlled refusal regression; the fake backend counts calls only and
    /// never resolves a real bookmark or requests any operating-system scope.
    static func verifyScopeRecorderRefusal(fixture: URL) throws -> String {
        let foreign = fixture.appendingPathComponent("not-the-offered-root", isDirectory: true)
        let backend = ScopeRefusalProbe(resolved: foreign)
        let recorder = ReopenScopeRecorder(expected: fixture, underlying: backend)
        try require(!recorder.startAccess(to: foreign), "Qualification recorder accepted an out-of-fixture scope")
        recorder.stopAccess(to: foreign)
        var rejected = false
        do { _ = try recorder.resolve(Data()) } catch { rejected = true }
        try require(rejected && backend.scopeCalls == 0 && recorder.counts.successfulStarts == 0,
                    "Qualification recorder touched an out-of-fixture system scope before rejecting it")
        return "Controlled qualification recorder rejects mismatched references before any underlying scope call"
    }

    private struct Receipt: Codable, Sendable {
        let version: Int
        var status: String
        let owner: UUID
        let reference: UUID
        let fixture: String
        let state: String
        let application: String
        let preparedProcess: Int32
        let chosenScopeStarted: Bool
        var reopenedProcess: Int32?
        var restoredScopeStarted: Bool?
        var shallowEntryCount: Int?
        var metadataIssueCount: Int?
        var forgotten: Bool?
        var sessionSavedForStartup: Bool?
        var actualBrowserStartup: Bool?
        var internalScopeAttemptCount: Int?
        var internalScopeStartCount: Int?
        var internalScopeStopCount: Int?
        var scopeLifetimeBalanced: Bool?
        var sessionForgotten: Bool?
    }

    static func run(_ browser: BrowserViewController, fixture: URL, output: URL, priorReceipt: URL?) async throws -> [String: Any] {
        let args = ProcessInfo.processInfo.arguments
        try require(args.contains("--verify-ui") && !args.contains("--offscreen")
            && (args.contains("--qualify-folder-reopen") != args.contains("--resume-folder-access")),
            "Folder reopen requires one explicit foreground phase")
        guard let window = browser.view.window, NSApplication.shared.isActive, window.isKeyWindow else {
            throw UIVerification.Failure(message: "Folder reopen requires the active native browser")
        }
        let build = fixture.deletingLastPathComponent().deletingLastPathComponent()
        try await Task.detached {
            try validateRoots(fixture: fixture, output: output, build: build)
        }.value
        let receiptURL = output.appendingPathComponent("folder-reopen-qualification.json")
        try await Task.detached { try reserveReceipt(receiptURL) }.value
        let completed: Receipt
        if let priorReceipt {
            let prior = try await Task.detached { try loadPreparedReceipt(priorReceipt, fixture: fixture, build: build) }.value
            try require(prior.preparedProcess != getpid(), "Reopen must use an independent process")
            try require(prior.application == Bundle.main.bundleURL.path, "Reopen must use the same immutable development app")
            try require(prior.sessionSavedForStartup == true, "This earlier receipt requires a new prepare phase for actual browser-startup qualification")
            let state = URL(fileURLWithPath: prior.state, isDirectory: true)
            // Validate only app-owned session data before startup can read any
            // target. A historical receipt without a stored session decodes,
            // but cannot qualify this stronger actual-startup workflow.
            let preflight = BrowserSessionController(stateDirectory: state)
            guard case .restored(let snapshot) = await preflight.restore(enabled: true),
                  snapshot.tabs.count == 1, snapshot.activeTab == 0,
                  snapshot.tabs[0].location.kind == .directory,
                  snapshot.tabs[0].location.url?.standardizedFileURL.path == fixture.path,
                  snapshot.tabs[0].filter.isEmpty, snapshot.tabs[0].selection.isEmpty else {
                throw UIVerification.Failure(message: "The isolated startup session is missing or does not identify only the offered fixture")
            }
            let recorder = ReopenScopeRecorder(expected: fixture)
            let settings = BrowserSettings(persist: false)
            settings.restoresSession = true
            let testWindow = BrowserWindowController(settings: settings)
            let reopened = testWindow.browser
            let controller = FolderAccessController(stateDirectory: state, backend: recorder)
            reopened.folderAccess = controller
            reopened.sessionPersistence = BrowserSessionController(stateDirectory: state)
            testWindow.window?.isReleasedWhenClosed = false
            window.orderOut(nil)
            testWindow.showWindow(nil)
            testWindow.window?.makeKeyAndOrderFront(nil)
            defer {
                reopened.suspendBrowser()
                testWindow.close()
                window.makeKeyAndOrderFront(nil)
            }
            reopened.begin() // Exactly one real startup; no helper-acquired lease.
            try await waitForStartup(reopened, fixture: fixture)
            let references = reopened.rememberedFolders
            try require(references.count == 1 && references.first?.id == prior.reference,
                        "Actual browser startup did not restore the saved reference")
            guard case .resolvedUnverified = references[0].state, let restoredURL = references[0].url,
                  restoredURL.standardizedFileURL.path == fixture.path else {
                throw UIVerification.Failure(message: "Saved reference was unavailable, stale or resolved outside the owned fixture")
            }
            let savedGroup = reopened.sidebarRoots.first { $0.title == "Remembered Folders" }
            try require(savedGroup?.children?.count == 1
                && savedGroup?.children?.first.map({ reopened.rememberedFolderSidebar.referenceID(for: $0) == prior.reference }) == true,
                "Actual startup sidebar lost the saved reference ID")
            let expected = try await Task.detached { try expectedCount(fixture) }.value
            let entryCount = reopened.rawEntries.count
            let issueCount = reopened.issueCount
            try require(reopened.location == .directory(fixture) && reopened.loadError == nil && entryCount == expected && issueCount == 0,
                        "Actual reopened browser did not produce complete shallow fixture metadata")
            try require(recorder.counts.successfulStarts > 0 && recorder.counts.unexpectedURLs == 0,
                        "Actual browser startup did not start an internal scope for the exact fixture")
            guard let fixtureWindow = testWindow.window else { throw UIVerification.Failure(message: "Reopened fixture window is unavailable") }
            try await UIVerification.snapshot(fixtureWindow, to: output.appendingPathComponent("folder-reopened.png"))
            let watcher = reopened.directoryObservation
            let listing = reopened.listingTask
            reopened.suspendBrowser()
            if let watcher { await watcher.waitUntilStopped() }
            _ = await listing?.value
            let deadline = Date().addingTimeInterval(8)
            while !recorder.counts.balanced && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let scopeCounts = recorder.counts
            try require(scopeCounts.balanced, "Internal browser scope starts/stops did not balance after worker/watcher shutdown")
            let forgetFailure = await controller.forget(id: prior.reference)
            let afterForget = await FolderAccessController(stateDirectory: state).resolveRememberedFolders()
            try require(forgetFailure == nil && afterForget.isEmpty,
                                       "The isolated saved reference could not be forgotten")
            reopened.rememberedFolders = afterForget
            settings.restoresSession = false // In-memory settings only.
            reopened.sessionPersistence.setEnabled(false)
            try require(await reopened.sessionPersistence.flush() == nil, "The isolated valid session could not be forgotten")
            var receipt = prior
            receipt.status = "independent-app-reopen-metadata-and-forget-qualified"
            receipt.reopenedProcess = getpid()
            receipt.restoredScopeStarted = scopeCounts.successfulStarts > 0
            receipt.shallowEntryCount = entryCount
            receipt.metadataIssueCount = issueCount
            receipt.forgotten = true
            receipt.actualBrowserStartup = true
            receipt.internalScopeAttemptCount = scopeCounts.attempts
            receipt.internalScopeStartCount = scopeCounts.successfulStarts
            receipt.internalScopeStopCount = scopeCounts.stops
            receipt.scopeLifetimeBalanced = scopeCounts.balanced
            receipt.sessionForgotten = true
            completed = receipt
        } else {
            let owner = UUID()
            let state = build.appendingPathComponent("test-fixtures/folder-reopen-\(owner.uuidString)", isDirectory: true)
            let controller = FolderAccessController(stateDirectory: state)
            guard let chosen = await controller.chooseFolder(in: window, initialDirectory: fixture) else {
                throw UIVerification.Failure(message: "Folder reopen qualification was cancelled; no reference was saved")
            }
            defer { withExtendedLifetime(chosen) {} }
            try require(chosen.selection.url.standardizedFileURL.path == fixture.path,
                                       "A different folder was selected; it was not enumerated or remembered")
            let alert = NSAlert()
            alert.messageText = "Remember this generated folder and reopen Mac Explorer?"
            alert.informativeText = "This saves the generated fixture's reference and an optional startup session in isolated test state. This test app will close; a fresh process will use normal browser startup to restore them without another chooser, list shallow metadata through its internal scope, then forget both test records. Your other Mac Explorer windows remain open."
            alert.addButton(withTitle: "Remember and Reopen")
            alert.addButton(withTitle: "Cancel")
            try require(await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                                       "Remembering was cancelled; no reference was saved")
            try await Task.detached { try createOwnedState(state, owner: owner, build: build) }.value
            guard let saved = await controller.acceptChosenFolder(chosen.selection.url, remember: true), case .saved = saved.remembering else {
                throw UIVerification.Failure(message: "The native bookmark could not be saved")
            }
            defer { withExtendedLifetime(saved) {} }
            let session = BrowserSessionController(stateDirectory: state)
            if case .unavailable = await session.restore(enabled: true) { throw UIVerification.Failure(message: "Isolated startup session could not be prepared") }
            let tab = BrowserTab(location: .directory(fixture))
            session.record(try WorkspaceSession.capture([tab], activeID: tab.id))
            try require(await session.flush() == nil, "Isolated startup session could not be saved")
            var receipt = Receipt(version: 1, status: "remembered-awaiting-independent-app-reopen", owner: owner,
                reference: saved.selection.id, fixture: fixture.path, state: state.path,
                application: Bundle.main.bundleURL.path, preparedProcess: getpid(), chosenScopeStarted: saved.lease.securityScopeStarted)
            receipt.sessionSavedForStartup = true
            completed = receipt
        }
        try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(completed).write(to: receiptURL, options: .atomic)
        }.value
        if priorReceipt != nil {
            let alert = NSAlert()
            alert.messageText = "Remembered folder reopened successfully"
            alert.informativeText = "A fresh browser’s real startup restored the generated folder without another chooser and read \(completed.shallowEntryCount ?? 0) shallow metadata entries through internally acquired scope. Its scope starts/stops balanced after worker shutdown. The isolated test bookmark and session have been forgotten. Ordinary fixture access does not prove scope was necessary or qualify sandbox/privacy policy."
            alert.addButton(withTitle: "Finish Check")
            _ = await alert.beginSheetModal(for: window)
        }
        return ["passed": true, "mode": priorReceipt == nil ? "folder-reopen-prepare" : "folder-reopen-resume",
                "status": completed.status,
                "checks": priorReceipt == nil
                    ? ["Explicit native picker selected only the generated fixture; real bookmark and isolated startup session saved for next process"]
                    : ["Independent process used actual browser startup/sidebar/session and internal scope for real fixture metadata; scope lifetime balanced and isolated records forgotten"],
                "captureBoundary": "Generated fixture browser only; no desktop, protected-folder prompt or bookmark bytes recorded",
                "notExercised": ["Scope necessity/enforcement for an ordinary nonsandboxed fixture", "Protected-folder consent retention", "Rebuild/update retention", "Sandboxed-store access", "Revoking macOS privacy grants"]]
    }

    private static func waitForStartup(_ browser: BrowserViewController, fixture: URL) async throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            try Task.checkCancellation()
            if browser.sessionPersistence.isReady && browser.location == .directory(fixture)
                && !browser.isLoading && browser.orderingTask == nil { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw UIVerification.Failure(message: "Actual browser startup did not finish restoring the owned fixture")
    }

    nonisolated private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw UIVerification.Failure(message: message) }
    }

    nonisolated private static func reserveReceipt(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation {
            $0.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        try require(descriptor >= 0, "Folder reopen receipt already exists or cannot be reserved")
        close(descriptor)
    }

    nonisolated private static func validateRoots(fixture: URL, output: URL, build: URL) throws {
        try require(fixture.isFileURL && output.isFileURL && build.lastPathComponent == ".build"
            && fixture.deletingLastPathComponent() == build.appendingPathComponent("fixtures", isDirectory: true)
            && output.deletingLastPathComponent() == build.appendingPathComponent("evidence", isDirectory: true)
            && output.lastPathComponent.hasPrefix("ui-")
            && fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL
            && output.standardizedFileURL == output.resolvingSymlinksInPath().standardizedFileURL,
            "Folder reopen requires unredirected owned fixture/evidence roots")
        _ = try expectedCount(fixture)
    }

    nonisolated private static func expectedCount(_ fixture: URL) throws -> Int {
        let data = try readBounded(fixture.appendingPathComponent(".mac-explorer-fixture.json"), maximum: 65_536)
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard metadata?["generator"] as? String == "mac-explorer-dev", metadata?["complete"] as? Bool == true,
              let count = metadata?["plainFileCount"] as? Int, count >= 0, count <= 1_000_000 else {
            throw UIVerification.Failure(message: "Folder reopen refused an unowned listing fixture")
        }
        return count + 7
    }

    nonisolated private static func createOwnedState(_ state: URL, owner: UUID, build: URL) throws {
        let parent = build.appendingPathComponent("test-fixtures", isDirectory: true)
        try require(state == parent.appendingPathComponent("folder-reopen-\(owner.uuidString)", isDirectory: true)
            && parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL,
            "Folder reopen state was redirected")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager().createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(owner.uuidString.utf8).write(to: state.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
    }

    nonisolated private static func loadPreparedReceipt(_ url: URL, fixture: URL, build: URL) throws -> Receipt {
        let receipt = url.standardizedFileURL
        try require(receipt.lastPathComponent == "folder-reopen-qualification.json"
            && receipt.deletingLastPathComponent().lastPathComponent.hasPrefix("ui-")
            && receipt.deletingLastPathComponent().deletingLastPathComponent() == build.appendingPathComponent("evidence", isDirectory: true)
            && receipt.deletingLastPathComponent() == receipt.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL,
            "Reopen requires a receipt under this checkout's evidence root")
        let prior = try JSONDecoder().decode(Receipt.self, from: readBounded(receipt, maximum: 65_536))
        let state = build.appendingPathComponent("test-fixtures/folder-reopen-\(prior.owner.uuidString)", isDirectory: true)
        try require(prior.version == 1 && prior.status == "remembered-awaiting-independent-app-reopen"
            && prior.fixture == fixture.path && prior.state == state.path
            && state.standardizedFileURL == state.resolvingSymlinksInPath().standardizedFileURL,
            "Reopen receipt does not identify the exact owned fixture and state")
        try require(try readBounded(state.appendingPathComponent(".fixture-owner"), maximum: 64) == Data(prior.owner.uuidString.utf8),
                                   "Reopen state owner marker is invalid")
        return prior
    }

    nonisolated private static func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard descriptor >= 0 else { throw UIVerification.Failure(message: "Owned qualification input was unavailable") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0 && metadata.st_size <= Int64(maximum),
              let data = try handle.read(upToCount: maximum + 1), data.count == Int(metadata.st_size) else {
            throw UIVerification.Failure(message: "Owned qualification input is not a bounded regular file")
        }
        return data
    }
}

/// Observes real Foundation scope calls without substituting fake results,
/// retaining leases, logging URLs, or creating any additional access grant.
private final class ReopenScopeRecorder: FolderAccessBackend, @unchecked Sendable {
    struct Counts: Sendable {
        let attempts: Int
        let successfulStarts: Int
        let stops: Int
        let unexpectedURLs: Int
        let unmatchedStops: Int
        var balanced: Bool { successfulStarts > 0 && successfulStarts == stops && unexpectedURLs == 0 && unmatchedStops == 0 }
    }

    private let underlying: any FolderAccessBackend
    private let expected: URL
    private let lock = NSLock()
    private var attempts = 0
    private var starts = 0
    private var stops = 0
    private var unexpected = 0
    private var unmatched = 0
    private var active: [String: Int] = [:]

    init(expected: URL, underlying: any FolderAccessBackend = SystemFolderAccessBackend()) {
        self.expected = expected
        self.underlying = underlying
    }

    var counts: Counts {
        lock.lock(); defer { lock.unlock() }
        return Counts(attempts: attempts, successfulStarts: starts, stops: stops, unexpectedURLs: unexpected, unmatchedStops: unmatched)
    }

    func startAccess(to url: URL) -> Bool {
        lock.lock()
        attempts += 1
        guard isExpected(url) else { unexpected += 1; lock.unlock(); return false }
        lock.unlock()
        let started = underlying.startAccess(to: url)
        lock.lock()
        if started { starts += 1; active[url.absoluteString, default: 0] += 1 }
        lock.unlock()
        return started
    }

    func stopAccess(to url: URL) {
        lock.lock()
        guard isExpected(url) else { unexpected += 1; lock.unlock(); return }
        guard let count = active[url.absoluteString], count > 0 else { unmatched += 1; lock.unlock(); return }
        if count == 1 { active.removeValue(forKey: url.absoluteString) }
        else { active[url.absoluteString] = count - 1 }
        lock.unlock()
        underlying.stopAccess(to: url)
        lock.lock(); stops += 1; lock.unlock()
    }

    func bookmark(for url: URL) throws -> Data {
        guard isExpected(url) else { throw UIVerification.Failure(message: "Qualification reference is outside its offered fixture") }
        return try underlying.bookmark(for: url)
    }

    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
        let result = try underlying.resolve(bookmark)
        if !isExpected(result.url) {
            lock.lock(); unexpected += 1; lock.unlock()
            throw UIVerification.Failure(message: "Qualification reference resolved outside its offered fixture")
        }
        return result
    }

    private func isExpected(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.standardizedFileURL.path == expected.standardizedFileURL.path
    }
}

private final class ScopeRefusalProbe: FolderAccessBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let resolved: URL
    init(resolved: URL) { self.resolved = resolved }
    var scopeCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func startAccess(to url: URL) -> Bool { lock.lock(); calls += 1; lock.unlock(); return true }
    func stopAccess(to url: URL) { lock.lock(); calls += 1; lock.unlock() }
    func bookmark(for url: URL) throws -> Data { Data() }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { FolderBookmarkResolution(url: resolved, isStale: false) }
}
#endif
