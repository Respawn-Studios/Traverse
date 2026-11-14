#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
@_spi(Qualification) import FileOperations
@_spi(Qualification) import LocalStorage
import Security

/// Draft only. A later source-bound, signed App packet must review this file.
/// There is no native call unless a private generated authority, exact copied
/// bundle, signed identity and selected Browser row all pass their gates.
@MainActor enum NativeTrashBrowserRouteVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws {
        if !value { throw Failure.check(line) }
    }
    private static func wait(_ condition: () -> Bool, _ line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < end, line)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func sameGeneratedObject(_ value: stat, as source: stat) -> Bool {
        value.st_dev == source.st_dev && value.st_ino == source.st_ino
            && (value.st_mode & S_IFMT) == (source.st_mode & S_IFMT)
            && value.st_birthtimespec.tv_sec == source.st_birthtimespec.tv_sec
            && value.st_birthtimespec.tv_nsec == source.st_birthtimespec.tv_nsec
    }
    private static func generatedReturnedSHA(_ target: URL, source: stat) -> String? {
        guard target.isFileURL, target.resolvingSymlinksInPath().path == target.path else { return nil }
        let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var first = stat()
        guard fstat(fd, &first) == 0,
              sameGeneratedObject(first, as: source),
              first.st_mode & S_IFMT == S_IFREG,
              first.st_size <= 16 << 10 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count >= 0, data.count + count <= 16 << 10 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        var last = stat()
        guard fstat(fd, &last) == 0,
              sameGeneratedObject(last, as: source),
              last.st_size == first.st_size,
              last.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec,
              last.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec else { return nil }
        return sha(data)
    }
    private static func writePrivateJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.scope }
        defer { close(fd) }
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == data.count && fsync(fd) == 0 else { throw Failure.scope }
    }
    private static func privateFields(_ url: URL) throws -> [String: Any] {
        guard url.resolvingSymlinksInPath().path == url.path else { throw Failure.scope }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.scope }
        defer { close(fd) }
        var facts = stat()
        guard fstat(fd, &facts) == 0,
              facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_mode & 0o077 == 0, facts.st_size <= 4096 else { throw Failure.scope }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try input.read(upToCount: 4097), data.count <= 4096,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.scope
        }
        return fields
    }

    private static func signedPreviewCodeHash() -> String? {
        guard Bundle.main.bundleIdentifier == "local.macexplorer.preview",
              Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "development-preview"
        else { return nil }
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures),
                  nil) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode,
                  SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              fields[kSecCodeInfoIdentifier as String] as? String == "local.macexplorer.preview",
              fields[kSecCodeInfoTeamIdentifier as String] as? String == "CDLNJRG82U",
              let unique = fields[kSecCodeInfoUnique as String] as? Data,
              (20...32).contains(unique.count),
              let executable = fields[kSecCodeInfoMainExecutable as String] as? URL,
              executable.standardizedFileURL == Bundle.main.executableURL?.standardizedFileURL
        else { return nil }
        if let rawRights = fields[kSecCodeInfoEntitlementsDict as String] {
            guard let rights = rawRights as? [String: Any], rights.isEmpty else { return nil }
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    static func run() async {
        var root: URL?, owner: BrowserWindowController?, recorder: DiagnosticRecorder?
        var scopeAudit: NativeTrashScopeAuditBackend?
        var session: GeneratedNativeTrashRouteSession?, failure: UInt?, summaries: [[String: Any]] = []
        var custody: [[String: Any]] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let codeHash = signedPreviewCodeHash()
            try require(raw.hasPrefix("/")
                && admitted.resolvingSymlinksInPath().path == admitted.path
                && admitted.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-development").path
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && Bundle.main.bundleURL.path == admitted.appendingPathComponent("Traverse Qualification.app").path
                && Bundle.main.bundleURL.resolvingSymlinksInPath().path == Bundle.main.bundleURL.path
                && ProcessInfo.processInfo.arguments.contains("--verify-ui")
                && ProcessInfo.processInfo.arguments.contains("--check-trash-app-route-native")
                && codeHash != nil)
            let marker = try privateFields(admitted.appendingPathComponent("reservation.json"))
            let authority = try privateFields(admitted.appendingPathComponent("native-authority.json"))
            guard let modeText = marker["mode"] as? String,
                  let mode = GeneratedNativeTrashMode(rawValue: modeText) else { throw Failure.scope }
            try require(marker["packet"] as? String == "traverse-native-trash-browser-v1"
                && authority["approved"] as? Bool == true
                && authority["case"] as? String == admitted.lastPathComponent
                && authority["maximumNativeCalls"] as? Int == 4
                && authority["mode"] as? String == modeText
                && authority["cdhash"] as? String == codeHash)
            root = admitted
            let (engine, audit) = try GeneratedNativeTrashRouteFactory.make(root: admitted, mode: mode,
                activity: ApplicationFileActivity.beginOperation)
            session = audit
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
            let scope = NativeTrashScopeAuditBackend(root: admitted.appendingPathComponent("Input"))
            scopeAudit = scope
            browser.folderAccess = FolderAccessController(stateDirectory: nil, backend: scope)
            controller.window?.setFrameOrigin(.init(x: -12000, y: -12000))
            controller.beginBrowsing()
            guard let window = controller.window else { throw Failure.scope }
            window.makeKeyAndOrderFront(nil)
            browser.navigate(to: .directory(scope.root))
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            browser.recoverableFileOperations = engine
            let chosen = await browser.folderAccess.acceptChosenFolder(scope.root)
            try require(chosen != nil)
            chosen?.lease.close()
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            for index in 1...4 {
                let source = scope.root.appendingPathComponent("Generated-\(index).dmg")
                var sourceFacts = stat()
                try require(lstat(source.path, &sourceFacts) == 0
                    && sourceFacts.st_mode & S_IFMT == S_IFREG
                    && sourceFacts.st_uid == geteuid() && sourceFacts.st_nlink == 1
                    && sourceFacts.st_size <= 16 << 10)
                // The external sealed fixture receipt holds the source hash;
                // the App adds no source-body prewarming pass in cold mode.
                guard let expectedSourceSHA = marker["sha256-\(index)"] as? String,
                      expectedSourceSHA.count == 64 else { throw Failure.scope }
                browser.navigate(to: .directory(scope.root))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
                browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
                try require(browser.selectedURLs == [source] && browser.canModifyCurrentFolder)
                let previousRecord = browser.lastRecoveryRecordID
                let before = audit.snapshot
                let beforeScope = scope.snapshot
                try audit.arm(source)
                var promptCount = 0
                var promptScopeAttempted = false, promptScopeRetained = false
                browser.operationTrashPrompt = { count in
                    promptCount += 1
                    let live = scope.snapshot
                    promptScopeAttempted = live.attempts > beforeScope.attempts
                    promptScopeRetained = live.started > live.stopped
                    return count == 1
                }
                let action = #selector(BrowserViewController.trashSelection(_:))
                let sender = NSMenuItem(title: "Move to Trash…", action: action, keyEquivalent: "")
                try require(NSApplication.shared.sendAction(action, to: browser, from: sender))
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                    && browser.lastOperationResult != nil && browser.lastRecoveryRecordID != previousRecord }
                try await wait { ApplicationFileActivity.gate.activeCount == 0 }
                audit.disarm()
                let after = audit.snapshot
                try require(promptCount == 1 && promptScopeAttempted
                    && after.calls == before.calls + 1
                    && after.calls <= 4 && after.returned <= after.calls)
                let result = browser.lastOperationResult!
                let recordID = browser.lastRecoveryRecordID!
                let history = try await engine.inspectExistingHistory()
                try require(history.records.count == index && history.refusedEntries.isEmpty
                    && history.nextCursor == nil)
                guard let record = history.records.first(where: { $0.id == recordID }) else { throw Failure.scope }
                try require(record.operation == "Move to Trash")
                guard let item = result.items.first(where: { $0.source == source }),
                      let target = item.destination else {
                    summaries.append(["index": index, "state": "returned-url-unavailable",
                                      "calls": after.calls - before.calls])
                    break
                }
                try require(record.locations.contains { $0.path == target.path })
                var returnedFacts = stat()
                let sameObject = lstat(target.path, &returnedFacts) == 0
                    && sameGeneratedObject(returnedFacts, as: sourceFacts)
                    && returnedFacts.st_mode & S_IFMT == S_IFREG
                // Only an independently same-inode generated object enters
                // the private custody file. A mismatched returned URL remains
                // in the engine's own guarded journal, not a diagnostic log.
                if sameObject {
                    custody.append(["recordID": recordID.uuidString, "returnedURL": target.absoluteString,
                                    "device": Int64(returnedFacts.st_dev), "inode": UInt64(returnedFacts.st_ino),
                                    "birthSeconds": returnedFacts.st_birthtimespec.tv_sec,
                                    "birthNanos": returnedFacts.st_birthtimespec.tv_nsec,
                                    "sameObject": true])
                }
                let bodyEqual = sameObject && generatedReturnedSHA(target, source: sourceFacts) == expectedSourceSHA
                await logger.flush()
                let events = try await logger.page(limit: 256).events
                let caught = events.filter { $0.action == .fileOperation && $0.relatedTrace == recordID
                    && $0.context?.checkpoint == .nativeStatus }
                let closedBoundaries = caught.compactMap { $0.error?.symbol }
                let closedFamilies = caught.flatMap { $0.context?.flags ?? [] }.map(\.rawValue).sorted()
                let privacy = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
                try require(!privacy.contains(admitted.path) && !privacy.contains(target.path)
                    && !privacy.contains(source.lastPathComponent))
                try require(custody.count <= 16 && after.warmCompleted <= after.returned)
                let warmCorrect = mode == .cold
                    ? after.warmCompleted == before.warmCompleted
                    : after.warmCompleted == before.warmCompleted + 1
                let succeeded = result.disposition == .succeeded && record.state == "committed"
                    && item.status == .succeeded && sameObject && bodyEqual
                    && caught.isEmpty && warmCorrect
                if !succeeded { try require(record.state == "needsReview" && !record.canUndo) }
                summaries.append(["index": index, "state": succeeded ? "committed" : "needs-review",
                                  "recordID": recordID.uuidString,
                                  "calls": after.calls - before.calls,
                                  "sameObject": sameObject, "bodyEqual": bodyEqual,
                                  "warmCompleted": after.warmCompleted - before.warmCompleted,
                                  "closedCaughtCount": caught.count,
                                  "closedBoundaries": closedBoundaries,
                                  "closedFamilies": closedFamilies,
                                  "promptScopeAttempted": promptScopeAttempted,
                                  "promptScopeRetained": promptScopeRetained,
                                  "scopeAttempts": scope.snapshot.attempts,
                                  "scopeStarted": scope.snapshot.started,
                                  "scopeStopped": scope.snapshot.stopped])
                if !succeeded { break } // Preserve uncertainty; no Undo/retry.
            }
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }
        }
        if let owner {
            owner.browser.operationPreparationTask?.cancel(); owner.browser.operationTask?.cancel()
            await owner.browser.operationPreparationTask?.value; await owner.browser.operationTask?.value
            owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        }
        session?.disarm(); session?.finishAfterDrain()
        await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        if let root {
            let finalScope = scopeAudit?.snapshot
            let activityDrained = ApplicationFileActivity.gate.activeCount == 0
            let scopeBalanced = finalScope.map { $0.started == $0.stopped } ?? false
            let result: [String: Any] = ["passed": failure == nil && summaries.count == 4
                && summaries.allSatisfy { $0["state"] as? String == "committed" }
                && session?.snapshot.calls == 4 && activityDrained && scopeBalanced,
                "failureLine": failure ?? 0, "cases": summaries,
                "nativeCalls": session?.snapshot.calls ?? 0,
                "activityDrained": activityDrained, "scopeBalanced": scopeBalanced,
                "scopeAttempts": finalScope?.attempts ?? 0,
                "scopeStarted": finalScope?.started ?? 0,
                "scopeStopped": finalScope?.stopped ?? 0,
                "personalFiles": 0, "otherTrashEntriesListed": 0,
                "networkRequests": 0, "keychainCalls": 0]
            try? writePrivateJSON(result, to: root.appendingPathComponent("result.json"))
            if !custody.isEmpty { try? writePrivateJSON(custody, to: root.appendingPathComponent("custody.json")) }
        }
        NSApplication.shared.terminate(nil)
    }
}

/// Delegates to the actual OS backend. `false` is reported, never treated as a
/// grant. The generated path is also checked by the signed process's open.
private final class NativeTrashScopeAuditBackend: FolderAccessBackend, @unchecked Sendable {
    let root: URL
    private let underlying = SystemFolderAccessBackend()
    private let lock = NSLock()
    private var attempts = 0, started = 0, stopped = 0
    init(root: URL) { self.root = root }
    var snapshot: (attempts: Int, started: Int, stopped: Int) {
        lock.withLock { (attempts, started, stopped) }
    }
    func startAccess(to url: URL) -> Bool {
        guard url == root else { return false }
        let did = underlying.startAccess(to: url)
        lock.withLock { attempts += 1; if did { started += 1 } }
        return did
    }
    func stopAccess(to url: URL) {
        guard url == root else { return }
        underlying.stopAccess(to: url)
        lock.withLock { stopped += 1 }
    }
    func bookmark(for url: URL) throws -> Data { throw FileOperationFailure.unsupported }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw FileOperationFailure.unsupported }
}
#endif
