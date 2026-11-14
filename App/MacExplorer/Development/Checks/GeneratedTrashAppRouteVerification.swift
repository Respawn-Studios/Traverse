#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import FileOperations
@_spi(Qualification) import LocalStorage

/// Exercises the actual Browser Trash command with a sealed generated rename
/// adapter. This process cannot invoke the native system Trash from the test.
@MainActor enum GeneratedTrashAppRouteVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws {
        if !value { throw Failure.check(line) }
    }
    private static func wait(_ condition: () -> Bool, _ line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < end, line)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func run() async {
        var root: URL?, owner: BrowserWindowController?, recorder: DiagnosticRecorder?
        var probe: GeneratedTrashRouteProbe?, failure: UInt?, checks: [String] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted
                && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == "trash-app-route-generated"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            let source = admitted.appendingPathComponent("Input/Generated.bin")
            let target = admitted.appendingPathComponent("Returned/Generated.bin")
            let payload = Data("Traverse generated App Trash route v1\n".utf8)
            try require(try Data(contentsOf: source) == payload)
            var sourceFacts = stat()
            try require(lstat(source.path, &sourceFacts) == 0 && sourceFacts.st_mode & S_IFMT == S_IFREG
                && sourceFacts.st_mode & 0o7777 == 0o600 && sourceFacts.st_nlink == 1)
            let originalSourceFacts = sourceFacts
            let (engine, adapter) = try GeneratedTrashRouteProbe.make(root: admitted)
            probe = adapter
            let logger = DiagnosticRecorder(directory: admitted.appendingPathComponent("State/diagnostics"),
                limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10), recording: true)
            recorder = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
            settings.motion.mode = .off; settings.viewMode = .details
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser
            browser.permitsBackgroundVerification = true
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            let scope = RouteScopeBackend(root: admitted.appendingPathComponent("Input"))
            browser.folderAccess = FolderAccessController(stateDirectory: nil, backend: scope)
            controller.window?.setFrameOrigin(.init(x: -12000, y: -12000))
            controller.beginBrowsing()
            guard let window = controller.window else { throw Failure.scope }
            window.makeKeyAndOrderFront(nil)
            browser.navigate(to: .directory(scope.root))
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
            browser.recoverableFileOperations = engine
            try require(browser.recoverableFileOperations === engine)
            guard let choice = await browser.folderAccess.acceptChosenFolder(scope.root) else { throw Failure.scope }
            choice.lease.close()
            try await wait { scope.active == 0 && ApplicationFileActivity.gate.activeCount == 0 }
            browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
            try require(browser.selectedURLs == [source] && browser.canModifyCurrentFolder)
            try require(!settings.asksBeforeMovingToTrash
                && !BrowserSettings(persist: false, restoredData: Data("{\"version\":20}".utf8)).asksBeforeMovingToTrash)
            settings.asksBeforeMovingToTrash = true
            let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try require(restored.asksBeforeMovingToTrash
                && SettingsSearchCatalog.pages(matching: "trash confirmation").contains(.operations))
            let action = #selector(BrowserViewController.trashSelection(_:))
            let sender = NSMenuItem(title: browser.trashCommandTitle, action: action, keyEquivalent: "")
            try require(browser.validateMenuItem(sender) && sender.title == "Move to Trash…")
            browser.operationTrashPrompt = nil
            try require(NSApplication.shared.sendAction(action, to: browser, from: sender))
            try await wait { window.attachedSheet != nil }
            try require(scope.active > 0 && adapter.callCount == 0)
            guard let confirmation = window.attachedSheet else { throw Failure.scope }
            window.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil && window.attachedSheet == nil }
            try await wait { scope.active == 0 && ApplicationFileActivity.gate.activeCount == 0 }
            let cancelledHistory = try await engine.inspectExistingHistory()
            try require(adapter.callCount == 0 && FileManager().fileExists(atPath: source.path)
                && cancelledHistory.records.isEmpty)
            checks.append("The optional local confirmation can be cancelled without adapter calls or history; its setting roundtrips and defaults off for older preferences")

            settings.asksBeforeMovingToTrash = false
            let denyBefore = scope.snapshot
            var promptCount = 0, promptHadScope = false
            browser.operationTrashPrompt = { count in
                promptCount += 1
                let live = scope.snapshot
                promptHadScope = count == 1 && live.active > 0 && live.stops == denyBefore.stops
                return false
            }
            try require(NSApplication.shared.sendAction(action, to: browser, from: sender))
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            try await wait { scope.active == 0 && ApplicationFileActivity.gate.activeCount == 0 }
            let deniedHistory = try await engine.inspectExistingHistory()
            try require(promptCount == 1 && promptHadScope && adapter.callCount == 0
                && FileManager().fileExists(atPath: source.path) && deniedHistory.records.isEmpty)
            checks.append("An injected deny prompt remains authoritative while the ordinary local command is direct")

            browser.operationTrashPrompt = nil
            try require(browser.validateMenuItem(sender) && sender.title == "Move to Trash")
            let before = scope.snapshot
            try require(NSApplication.shared.sendAction(action, to: browser, from: sender))
            try await wait { adapter.didEnter }
            let inWorker = scope.snapshot
            try require(promptCount == 1 && promptHadScope && inWorker.active >= 2
                && inWorker.stops == before.stops && adapter.callCount == 1 && window.attachedSheet == nil)
            checks.append("Default direct Trash reaches the sealed generated adapter without a sheet and retains access through the actual Browser command and worker")
            adapter.release()
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                && browser.lastOperationResult != nil && browser.lastRecoveryRecordID != nil }
            try await wait { scope.active == 0 && ApplicationFileActivity.gate.activeCount == 0 }
            let result = browser.lastOperationResult!, recordID = browser.lastRecoveryRecordID!
            let after = scope.snapshot
            try require(after.starts == after.stops && adapter.callCount == 1
                && result.disposition == .partial && result.items.count == 2
                && result.items[0].source == source && result.items[0].destination == target
                && result.items[0].status == .succeeded)
            let history = try await engine.inspectExistingHistory()
            try require(history.records.count == 1 && history.records[0].id == recordID
                && history.records[0].state == "needsReview" && !history.records[0].canUndo)
            var returnedFacts = stat(), absentSourceFacts = stat()
            try require(lstat(source.path, &absentSourceFacts) != 0 && errno == ENOENT
                && lstat(target.path, &returnedFacts) == 0
                && returnedFacts.st_ino == originalSourceFacts.st_ino && returnedFacts.st_dev == originalSourceFacts.st_dev
                && returnedFacts.st_mode & 0o7777 == 0o640
                && (try Data(contentsOf: target)) == payload)
            checks.append("One generated rename returns the same object; mismatch remains recoverable in exact history")
            await logger.flush()
            let events = try await logger.page(limit: 256).events
            let caught = events.filter { $0.action == .fileOperation && $0.error?.symbol == "nativeTrash.fingerprint" }
            try require(caught.count == 1 && caught[0].context?.checkpoint == .nativeStatus
                && caught[0].context?.flags == [.nativeTrashEntryMetadata]
                && caught[0].relatedTrace == recordID && caught[0].causes?.first?.symbol == "recoveryUncertain")
            try require(events.contains { $0.action == .fileOperation && $0.phase == .finished
                && $0.trace == caught[0].trace && $0.ordinal != nil }
                && events.contains { $0.command == .trash && $0.phase == .requested })
            let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            try require(!encoded.contains(admitted.path) && !encoded.contains(source.lastPathComponent)
                && !encoded.contains(String(decoding: payload, as: UTF8.self)))
            checks.append("App recorder emits only the closed fingerprint family and exact journal correlation")
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }
        }
        probe?.release()
        if let owner {
            if let sheet = owner.window?.attachedSheet {
                owner.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
            owner.browser.operationPreparationTask?.cancel(); owner.browser.operationTask?.cancel()
            await owner.browser.operationPreparationTask?.value; await owner.browser.operationTask?.value
            owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        }
        await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        if let root {
            let report: [String: Any] = ["passed": failure == nil, "failureLine": failure ?? 0,
                "checks": checks, "adapterCalls": probe?.callCount ?? 0,
                "activityDrained": ApplicationFileActivity.gate.activeCount == 0,
                "systemTrashCalls": 0, "generatedOnly": true, "networkRequests": 0, "keychainCalls": 0]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        }
        NSApplication.shared.terminate(nil)
    }
}

private final class RouteScopeBackend: FolderAccessBackend, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var startCount = 0, stopCount = 0
    init(root: URL) { self.root = root }
    var active: Int { lock.withLock { startCount - stopCount } }
    var snapshot: (starts: Int, stops: Int, active: Int) {
        lock.withLock { (startCount, stopCount, startCount - stopCount) }
    }
    func startAccess(to url: URL) -> Bool {
        guard url == root else { return false }
        lock.withLock { startCount += 1 }
        return true
    }
    func stopAccess(to url: URL) { lock.withLock { stopCount += 1 } }
    func bookmark(for url: URL) throws -> Data { throw FileOperationFailure.unsupported }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw FileOperationFailure.unsupported }
}
#endif
