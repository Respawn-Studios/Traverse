#if DEBUG && TRAVERSE_NETWORK_QUALIFICATION
import Darwin
@MainActor enum SFTPFolderDownloadVerification {
    static func run() async { Darwin.exit(78) }
}
#endif
#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// Exact signed-app composition over generated peers/targets. No OS password
/// backend, personal location, arbitrary provider or distribution activation.
@MainActor enum SFTPFolderDownloadVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }; var value: Int { lock.withLock { count } }
    }
    private final class Trace { var name = "scope"; weak var tab: SFTPTabController? }
    private static func require(_ condition: Bool, _ line: UInt = #line) throws { if !condition { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 60
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < until); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, windowOwner: BrowserWindowController?, connections: ApplicationSMBConnections?, tab: SFTPTabController?
        var ticker: Task<Void, Never>?, signInDriver: Task<Void, Error>?, gap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        let calls = Calls(), trace = Trace()
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { throw Failure.scope }; return args[index + 1]
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.resolvingSymlinksInPath() == location && location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "sftp-native-folder-download"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = location
            let method = try argument("--generated-method"), scenario = try argument("--generated-transfer")
            let independent = args.contains("--independent-openssh"), large = args.contains("--large-interface")
            let routed = args.contains("--check-sftp-routed-download")
            let ordinary = args.contains("--check-ordinary-routed-download")
            try require(!ordinary || routed && SFTPRoutedDownloadFeature.enabled && SFTPFolderDownloadFeature.enabled)
            try require(["key", "prompts", "mfa"].contains(method) && ["success", "stop", "collision", "slow"].contains(scenario) && (!independent || scenario == "success"))
            guard let port = UInt16(try argument("--generated-port")), port > 0,
                  let motion = BrowserMotionMode(rawValue: try argument("--generated-motion")) else { throw Failure.scope }
            let fingerprint = try argument("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            let jumpPort = routed ? UInt16(try argument("--generated-jump-port")) : nil
            let jumpFingerprint = routed ? try argument("--generated-jump-fingerprint") : nil
            try require(!routed || jumpPort != nil && jumpPort != 0)
            settings.appearance = large ? .light : .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.motion.mode = motion; if large { settings.interfaceSize = .init(150) }
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
            InterfacePresentation.shared.bind(settings); SFTPFolderDownloadFeature.qualifying = !ordinary
            SFTPRoutedDownloadFeature.qualifying = routed && !ordinary
            let controller = BrowserWindowController(settings: settings); windowOwner = controller
            let browser = controller.browser, profile = location.appendingPathComponent("state/Native"), destination = location.appendingPathComponent("source/Destination")
            let metadata = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"))
            let bodies = try SFTPDownloadStorage(directory: profile.appendingPathComponent("remote-downloads"))
            let engine = browser.operationCoordinator.engine(at: profile.appendingPathComponent("operation-recovery"))
            browser.recoverableFileOperations = engine; browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.readVolumesForVerification = { [] }
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.tabs = [BrowserTab(location: .directory(destination))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = controller.window else { throw Failure.scope }
            window.setContentSize(.init(width: large ? 1180 : 960, height: 650)); window.title = "SFTP folders · generated review"
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let service = ApplicationSMBConnections(directory: profile, passwords: .refusingQualification { calls.increment() },
                sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true); connections = service
            service.present(in: browser); try await wait { service.verificationWindow?.model.managing == false }
            guard let connect = service.verificationWindow else { throw Failure.scope }
            let model = connect.model
            model.connectionProtocol = .sftp
            model.address = "sftp://\(routed ? (independent ? "localhost" : "private.internal.test") : "127.0.0.1"):\(port)" + (independent ? "/fixture" : "")
            model.account = "generated"; model.name = "Generated folders"
            if method == "prompts" { model.sftpAuthentication = .serverPrompts }
            else { model.useSSHKey(location.appendingPathComponent("source/client-key")); model.extraServerPrompts = method == "mfa" }
            if routed, let jumpPort {
                model.rememberServer = true
                model.jumpHost.enabled = true; model.jumpHost.address = "sftp://127.0.0.1:\(jumpPort)"; model.jumpHost.account = "generated"
                if method == "prompts" { model.jumpHost.method = .serverPrompts }
                else {
                    model.jumpHost.method = .keyFile
                    model.jumpHost.selectedKey = try SFTPSelectedPrivateKey(file: location.appendingPathComponent("source/client-key"))
                    model.jumpHost.keyName = "Generated key"; model.jumpHost.passphrase = "generated-only-not-a-secret"
                    model.jumpHost.extraPrompts = method == "mfa"
                }
            }
            // Enter secrets only after BOTH endpoint identities are final.
            // Editing a jump identity intentionally clears destination secrets.
            if method != "prompts" { model.keyPassphrase = "generated-only-not-a-secret" }
            model.transferBehavior = .readOnly
            try require(!model.freshUploads)
            var lastDiagnostic = 0.0
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; gap = max(gap, now - previous); previous = now
                if now - lastDiagnostic >= 2 {
                    lastDiagnostic = now
                    let values: [String: Any] = ["stage": trace.name, "pendingPages": trace.tab?.hasPendingPages ?? false,
                        "rows": trace.tab?.rows.cache.snapshot?.count ?? 0, "sessionRows": trace.tab?.session.latest.snapshot?.count ?? 0,
                        "closing": trace.tab?.isClosing ?? false, "reading": trace.tab?.session.latest.reading ?? false,
                        "failure": trace.tab?.session.latest.failure?.rawValue ?? "none"]
                    if let bytes = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) {
                        print("TRAVERSE_FOLDER_NATIVE " + String(decoding: bytes, as: UTF8.self)); fflush(stdout)
                    }
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            } }
            trace.name = "shared-connect"; model.connect(); try require(model.password.isEmpty && model.keyPassphrase.isEmpty)
            var rounds = Set<String>(), reviews = [String: String]()
            signInDriver = Task { @MainActor in
                while model.busy {
                    if let trust = service.verificationSFTPTrust, !trust.model.busy, trust.model.finished == nil {
                        // This is presentation-only deduplication in a generated
                        // UI driver. Production trust uses its existing route
                        // session/role nonces; do not invent a UI session field.
                        let role = trust.model.review.host + ":" + String(trust.model.review.port)
                        if reviews[role] == nil {
                            let expected = reviews.isEmpty && routed ? jumpFingerprint : fingerprint
                            try require(trust.model.review.fingerprint == expected && trust.model.review.kind == .first)
                            reviews[role] = trust.model.review.fingerprint; trust.model.proceed()
                        }
                    }
                    if let prompt = service.verificationSFTPInteractive, prompt.model.phase == .input,
                       SFTPInteractiveConnectionVerification.fieldsReady(prompt), !rounds.contains(prompt.model.challenge.id), let panel = prompt.window {
                        let challenge = prompt.model.challenge; rounds.insert(challenge.id)
                        try require(rounds.count <= (routed ? 4 : 2))
                        for (index, field) in challenge.prompts.enumerated() {
                            let response = independent ? "123456" : challenge.round == 2 ? "654321" : field.echo ? "generated" : "123456"
                            try SFTPInteractiveConnectionVerification.enterResponse(response, at: index, in: prompt)
                        }
                        try SFTPInteractiveConnectionVerification.pressReturn(panel)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await wait { !model.busy }; try await signInDriver?.value; signInDriver = nil
            // Generated-only failure detail, after the exact bundle/root guard:
            // counts and a bounded static connection notice, never responses.
            let connectFacts: [String: Any] = ["connected": model.connected, "trustReviews": reviews.count,
                "promptRounds": rounds.count, "keychainCalls": calls.value, "notice": String(model.message.prefix(512))]
            let connectData = try JSONSerialization.data(withJSONObject: connectFacts, options: .sortedKeys)
            print("TRAVERSE_FOLDER_CONNECT " + String(decoding: connectData, as: UTF8.self)); fflush(stdout)
            try require(model.connected)
            try require(calls.value == 0)
            try require(reviews.count == (routed ? 2 : 1))
            try require(rounds.count == (method == "key" ? 0 : routed ? 4 : 2))
            if routed {
                // Connect does not reload the editor's sidebar after opening a
                // tab. Verify the durable saved route through a read-only
                // snapshot instead of expecting that closed editor to refresh.
                let saved = SFTPRememberedState(settings: .init(directory: profile.appendingPathComponent("sftp-servers")),
                    passwords: .refusingQualification { calls.increment() })
                let snapshot = try await saved.inspect()
                try require(!model.rememberingIncomplete && snapshot?.visibleRoutes.count == 1)
            }
            guard let owner = browser.sftpTabs[browser.activeID] else { throw Failure.scope }; tab = owner; trace.tab = owner
            let initialDirectory = browser.location
            try require(initialDirectory == .sftp(try owner.directoryLocation(components: owner.initialComponents)))
            try require(owner.session.allowsRequestedFolderDownloads && owner.session.allowsRequestedDownloads && !owner.session.allowsFreshUploads)
            func select(_ name: String) async throws {
                try await wait { owner.session.latest.failure != nil || owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages }
                try require(owner.session.latest.failure == nil)
                let count = owner.rows.cache.snapshot?.count ?? 0; try require(count <= 16)
                guard let row = (0..<Int(count)).first(where: { owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == name }) else { throw Failure.scope }
                owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            func idle() async throws { try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil } }
            func undo(_ result: RecoverableOperationResult) async throws -> [String: String] {
                guard let id = result.recordID else { throw Failure.scope }; let value = await engine.undo(recordID: id)
                try require(value.result.disposition == .succeeded)
                let retained = try await engine.retentionRecord(recordID: id); try require(retained.areas.count == 1 && retained.areas[0].verified)
                return ["operation": id.uuidString, "area": retained.areas[0].url.lastPathComponent]
            }
            try await select("Folder"); try require(browser.sftpFolderDownload.canRequest(from: owner))
            trace.name = "occupied-before-review"
            browser.sftpFolderDownload.chooseForVerification = { _ in destination.appendingPathComponent("Existing.txt") }
            browser.sftpFolderDownload.request(from: owner, toPane: false); try await idle()
            let occupiedRecords = try await bodies.inspect()
            try require(browser.sftpFolderDownload.bodyRequestsForVerification == 0 && occupiedRecords.isEmpty)
            var clips: [[String: Any]] = [], undos: [[String: String]] = [], reviewCalls = 0, fieldEdited = false
            browser.sftpFolderDownload.chooseForVerification = { _ in destination.appendingPathComponent("Received") }
            browser.sftpFolderDownload.reviewForVerification = { _ in reviewCalls += 1; return .cancel }
            trace.name = "metadata-review-cancel"
            browser.sftpFolderDownload.request(from: owner, toPane: false); try await idle()
            if scenario == "collision" {
                try require(reviewCalls == 0 && browser.sftpFolderDownload.bodyRequestsForVerification == 0 && browser.sftpFolderDownload.lastOutcome == nil)
                try require((try await bodies.inspect()).isEmpty && !FileManager().fileExists(atPath: destination.appendingPathComponent("Received").path))
            } else {
                let cancelledRecords = try await bodies.inspect()
                try require(reviewCalls == 1 && browser.sftpFolderDownload.bodyRequestsForVerification == 0 && cancelledRecords.isEmpty && owner.session.latest.failure == nil)
                browser.sftpFolderDownload.reviewForVerification = { preview in
                    reviewCalls += 1
                    // Stop and slow-round-trip cases qualify ownership and
                    // deadlines. Appearance is captured in success cases.
                    if scenario == "stop" || scenario == "slow" { return .download(preview.model.name) }
                    let choice = Task { @MainActor in await preview.choose(in: window) }
                    var previewStep = "attach"
                    do {
                        try await wait { window.attachedSheet === preview.window }
                        guard let panel = preview.window else { throw Failure.scope }
                        panel.title = "Folder Download · generated review"
                        window.title = "SFTP folders · generated review"
                        try await Task.sleep(for: .milliseconds(200))
                        // ScreenCaptureKit composites an attached sheet into
                        // its owning window. Record that exact owner instead
                        // of stretching its composite into the sheet's frame.
                        try require(panel.sheetParent === window)
                        try JSONSerialization.data(withJSONObject: ["parentWidth": window.frame.width, "parentHeight": window.frame.height,
                            "sheetWidth": panel.frame.width, "sheetHeight": panel.frame.height, "visible": window.isVisible,
                            "parentTitleMarked": window.title.contains("generated review")], options: [.prettyPrinted, .sortedKeys])
                            .write(to: location.appendingPathComponent("evidence/folder-preview-scope.json"), options: .withoutOverwriting)
                        for (label, expanded) in [("folder-details-open", true), ("folder-details-close", false)] {
                            previewStep = label
                            // Normal document-title updates are coalesced;
                            // restore the generated-only marker at admission.
                            window.title = "SFTP folders · generated review"
                            let report = try await NativeMotionRecorder.record(window: window, root: location, label: label, sampling: .diagnostic(for: window)) { preview.model.details = expanded }
                            try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                            clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
                        }
                        @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                        previewStep = "find-native-name-field"
                        guard let content = panel.contentView,
                              let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Folder name" }),
                              panel.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.scope }
                        previewStep = "edit-native-name-field"
                        window.title = "SFTP folders · generated review"
                        let report = try await NativeMotionRecorder.record(window: window, root: location, label: "folder-name-edit", sampling: .diagnostic(for: window)) {
                            editor.selectAll(nil); editor.insertText("Received", replacementRange: .init(location: 0, length: field.stringValue.utf16.count))
                        }
                        fieldEdited = preview.model.name == "Received" && preview.model.valid
                        try require(fieldEdited)
                        try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/folder-name-edit.json"), options: .withoutOverwriting)
                        var clip = DevelopmentMotionVerification.clip("folder-name-edit", report: report, field: nil, window: window)
                        let screen = panel.convertToScreen(field.convert(field.bounds, to: nil))
                        clip["fieldRegion"] = ["x": screen.minX - window.frame.minX, "y": window.frame.maxY - screen.maxY,
                            "width": screen.width, "height": screen.height]
                        clips.append(clip)
                        preview.finish(.download(preview.model.name)); return await choice.value
                    } catch {
                        var detail: [String: Any] = ["passed": false, "step": previewStep, "errorType": String(reflecting: type(of: error))]
                        if let failure = error as? NativeMotionRecorder.Failure { detail["captureFailure"] = failure.rawValue }
                        if case let Failure.check(line) = error { detail["line"] = line }
                        try? JSONSerialization.data(withJSONObject: detail, options: [.prettyPrinted, .sortedKeys])
                            .write(to: location.appendingPathComponent("evidence/folder-preview-refusal.json"), options: .withoutOverwriting)
                        preview.finish(.cancel); _ = await choice.value; return .cancel
                    }
                }
                trace.name = "native-folder-download"; let began = ProcessInfo.processInfo.systemUptime
                browser.sftpFolderDownload.request(from: owner, toPane: false)
                if scenario == "stop" {
                    try await wait { FileManager().fileExists(atPath: location.appendingPathComponent("state/Stop.control").path) }
                    browser.cancelFileOperation(nil); try await idle()
                    let records = try await bodies.inspect()
                    try require(records.count == 1 && !records[0].active && records[0].isFolder && owner.drain?.localResourcesEnded == true
                        && browser.sftpFolderDownload.lastOutcome == nil && !FileManager().fileExists(atPath: destination.appendingPathComponent("Received").path))
                } else {
                    try await idle()
                    guard let result = browser.sftpFolderDownload.lastOutcome else { throw Failure.scope }
                    try require(result.result.disposition == .succeeded && browser.sftpFolderDownload.bodyRequestsForVerification == 1)
                    let remoteRoot = independent ? "/fixture" : "/generated"
                    try require(try await Task.detached { try verifyTree(destination.appendingPathComponent("Received"), remoteRoot: remoteRoot) }.value)
                    if scenario == "slow" { try require(ProcessInfo.processInfo.systemUptime - began >= 34) }
                    undos.append(try await undo(result))
                    trace.name = "regular-file-regression"
                    guard let folder = owner.rows.cache.entry(at: UInt64(owner.rows.table.selectedRow)) else { throw Failure.scope }
                    owner.rows.onOpen?(folder)
                    try await select("Café")
                    guard let nested = owner.rows.cache.entry(at: UInt64(owner.rows.table.selectedRow)) else { throw Failure.scope }
                    owner.rows.onOpen?(nested); try await select("Report.bin")
                    browser.sftpDownload.chooseForVerification = { _ in destination.appendingPathComponent("File.txt") }
                    let fileBegan = ProcessInfo.processInfo.systemUptime
                    browser.sftpDownload.request(from: owner, toPane: false); try await idle()
                    guard let file = browser.sftpDownload.lastOutcome else { throw Failure.scope }; try require(file.result.disposition == .succeeded)
                    if scenario == "slow" { try require(ProcessInfo.processInfo.systemUptime - fileBegan >= 34) }
                    undos.append(try await undo(file))
                    // An explicit /fixture address is below the server root;
                    // home-relative loopback fixtures happen to share them.
                    browser.navigate(to: initialDirectory); try await select("Empty")
                    trace.name = "empty-folder"
                    browser.sftpFolderDownload.chooseForVerification = { _ in destination.appendingPathComponent("Empty") }
                    browser.sftpFolderDownload.reviewForVerification = { .download($0.model.name) }
                    browser.sftpFolderDownload.request(from: owner, toPane: false); try await idle()
                    guard let empty = browser.sftpFolderDownload.lastOutcome else { throw Failure.scope }
                    try require(empty.recordID != result.recordID && empty.result.disposition == .succeeded
                        && (try FileManager().contentsOfDirectory(atPath: destination.appendingPathComponent("Empty").path)).isEmpty)
                    undos.append(try await undo(empty)); try await select("Folder")
                    trace.name = "changed-original-parent-before-bodies"
                    let race = location.appendingPathComponent("source/RaceTarget"), beforeBodies = browser.sftpFolderDownload.bodyRequestsForVerification
                    browser.sftpFolderDownload.chooseForVerification = { _ in race.appendingPathComponent("Refused") }
                    browser.sftpFolderDownload.reviewForVerification = { preview in
                        do {
                            try FileManager().moveItem(at: race, to: location.appendingPathComponent("source/RetainedRaceTarget"))
                            try FileManager().createDirectory(at: race, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        } catch { return .cancel }
                        return .download(preview.model.name)
                    }
                    browser.sftpFolderDownload.request(from: owner, toPane: false); try await idle()
                    let raceRecords = try await bodies.inspect()
                    try require(browser.sftpFolderDownload.bodyRequestsForVerification == beforeBodies && !FileManager().fileExists(atPath: race.appendingPathComponent("Refused").path)
                        && owner.session.latest.failure == nil && raceRecords.isEmpty)
                }
            }
            trace.name = "actual-drain"; let ended = await owner.close().value
            try require(ended.localResourcesEnded)
            if scenario == "collision" {
                // A locally unrepresentable manifest poisons the new decoder.
                // Actual exit/EOF remain mandatory, but terminal evidence is
                // deliberately untrusted and its catalog stays for review.
                try require(!ended.protocolValid && ended.temporaryStoreRemoved == false)
            } else {
                try require(ended.protocolValid && ended.terminal?.tasksAfterRuntimeDrop == 0 && ended.temporaryStoreRemoved == true)
                if routed { try require(ended.terminal?.jumpTaskEndedBeforeRuntimeDrop == true) }
            }
            let again = await owner.close().value
            try require(again.localResourcesEnded && abs(again.drainElapsedSeconds - ended.drainElapsedSeconds) < 0.001)
            await service.closeAndDrain(); connections = nil
            let catalogs = try await SMBTemporaryCatalogPool(storage: metadata).inspect()
            try require(catalogs.count == (scenario == "collision" ? 1 : 0) && catalogs.allSatisfy { !$0.active }
                && ApplicationSMBActivity.gate.activeCount == 0 && calls.value == 0)
            ticker?.cancel(); await ticker?.value; ticker = nil; try require(gap < 0.5)
            try write(["passed": true, "method": method, "scenario": scenario, "independentOpenSSH": independent,
                "actualSharedConnect": true, "promptRounds": rounds.count, "trustReviews": reviews.count, "routed": routed,
                "ordinaryActivation": ordinary,
                "jumpTaskEnded": ended.terminal?.jumpTaskEndedBeforeRuntimeDrop.map { $0 as Any } ?? NSNull(),
                "drainElapsedSeconds": ended.drainElapsedSeconds, "repeatedCloseDoesNotRestartClock": true,
                "keychainCalls": calls.value, "reviewCancelBeforeBodies": scenario != "collision",
                "initialDirectoryPreserved": true,
                "folderBodyRequests": browser.sftpFolderDownload.bodyRequestsForVerification, "exactUndo": undos,
                "nativeNameFieldEdited": fieldEdited, "clips": clips, "maximumMainActorGapSeconds": gap,
                "motion": motion.rawValue, "interfacePercent": settings.interfaceSize.percent,
                "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF, "protocolValid": ended.protocolValid,
                "retainedInactiveCatalogs": catalogs.count, "catalogRemoved": ended.temporaryStoreRemoved == true], root: location)
        } catch {
            signInDriver?.cancel(); try? await signInDriver?.value; signInDriver = nil
            windowOwner?.browser.cancelFileOperation(nil); await windowOwner?.browser.operationTask?.value
            if let tab { _ = await tab.close().value }
            if let browser = windowOwner?.browser {
                for installed in Array(browser.sftpTabs.values) { _ = await installed.close().value }
            }
            await connections?.closeAndDrain(); ticker?.cancel(); await ticker?.value
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "checkpoint": trace.name, "line": line, "errorType": String(reflecting: type(of: error)), "keychainCalls": calls.value,
                "fileFailureCode": windowOwner?.browser.sftpDownload.lastFailureCodeForVerification ?? "",
                "fileNotice": windowOwner?.browser.sftpDownload.lastNotice ?? ""], root: root) }
        }
        windowOwner?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private nonisolated static func verifyTree(_ root: URL, remoteRoot: String) throws -> Bool {
        for (relative, size) in [("Café/Report.bin", 65_553), ("Readme.txt", 17), ("Zero\\file", 0)] {
            let url = root.appendingPathComponent(relative), descriptor = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return false }; defer { close(descriptor) }
            var facts = stat(); guard fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
                facts.st_nlink == 1, facts.st_size == size, facts.st_mode & 0o7777 == 0o644 else { return false }
            var bytes = Data(count: size)
            if size > 0 { guard bytes.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, size, 0) }) == size else { return false } }
            let seed = UInt64(Data((remoteRoot + "/Folder/" + relative).utf8).reduce(0) { $0 + UInt64($1) })
            guard bytes.enumerated().allSatisfy({ $0.element == UInt8((UInt64($0.offset) * 31 + seed) % 251) }),
                  try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { return false }
        }
        return try FileManager().contentsOfDirectory(atPath: root.appendingPathComponent("Empty").path).isEmpty
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-folder-download.json"), options: .withoutOverwriting)
    }
}
#endif
