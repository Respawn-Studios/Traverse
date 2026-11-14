#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Real Connect and selected-file flow against a separately admitted generated
/// route. No personal server, password backend, grant or ordinary startup.
@MainActor enum SFTPRoutedUploadVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func note() { lock.withLock { count += 1 } }; var value: Int { lock.withLock { count } }
    }
    @MainActor private final class Responsiveness {
        var stage = "scope", gap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        var byStage: [String: Double] = [:]
        func sample() {
            let now = ProcessInfo.processInfo.systemUptime, elapsed = now - previous
            gap = max(gap, elapsed); previous = now
            byStage[stage] = max(byStage[stage] ?? 0, elapsed)
        }
    }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ value: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 40
        while !value() { try require(ProcessInfo.processInfo.systemUptime < until); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, windowOwner: BrowserWindowController?, service: ApplicationSMBConnections?, tab: SFTPTabController?
        var signIn: Task<Void, Error>?, ticker: Task<Void, Never>?, recorder: DiagnosticRecorder?
        let responsiveness = Responsiveness()
        var clips: [[String:Any]] = [], captureFailure: [String:Any] = [:]
        let calls = Calls()
        do {
            let args = ProcessInfo.processInfo.arguments
            let folderUpload = args.contains("--folder-upload")
            func argument(_ key: String) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { throw Failure.scope }; return args[index + 1]
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.resolvingSymlinksInPath() == location && location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == (folderUpload ? "routed-folder-upload-native" : "sftp-native-routed-file-upload") && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = location
            let method = try argument("--generated-method"), scenario = try argument("--generated-transfer")
            let independent = args.contains("--independent-openssh"), large = args.contains("--large-interface")
            try require(["key", "mfa", "prompts"].contains(method) && ["success", "stop", "lost-close"].contains(scenario) && (!independent || scenario == "success"))
            guard let port = UInt16(try argument("--generated-port")), let jumpPort = UInt16(try argument("--generated-jump-port")), port > 0, jumpPort > 0 else { throw Failure.scope }
            let fingerprint = try argument("--generated-fingerprint"), jumpFingerprint = try argument("--generated-jump-fingerprint")
            let settings = BrowserSettings(persist: false)
            settings.appearance = large ? .light : .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
            if large { settings.interfaceSize = .init(150); settings.motion.mode = .reduced }
            InterfacePresentation.shared.bind(settings); SFTPUploadFeature.qualifying = true; SFTPRoutedUploadFeature.qualifying = true
            SFTPFolderUploadFeature.qualifying = folderUpload; SFTPRoutedFolderUploadFeature.qualifying = folderUpload
            defer { SFTPUploadFeature.qualifying = false; SFTPRoutedUploadFeature.qualifying = false; SFTPFolderUploadFeature.qualifying = false; SFTPRoutedFolderUploadFeature.qualifying = false }
            let profile = location.appendingPathComponent("state/Native")
            let source = location.appendingPathComponent(folderUpload ? independent ? "source/Local/Folder/Nested/Member.bin" : "source/Local/Folder/A/Member" : "source/Local/Upload.bin")
            let original = try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) }.value
            let logs = DiagnosticRecorder(directory: profile.appendingPathComponent("diagnostics"), limits: try .init(bytes: 128 << 10, segmentBytes: 16 << 10), recording: true)
            recorder = logs; ApplicationDiagnostics.shared.configureForVerification(logs)
            let controller = BrowserWindowController(settings: settings); windowOwner = controller
            let browser = controller.browser
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.readVolumesForVerification = { [] }; browser.permitsBackgroundVerification = true
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: profile.appendingPathComponent("operation-recovery"))
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            browser.tabs = [.init(location: .directory(source.deletingLastPathComponent()))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = controller.window else { throw Failure.scope }
            window.setContentSize(.init(width: large ? 1180 : 960, height: 680)); window.title = "SFTP jump Upload · generated review"
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let connections = ApplicationSMBConnections(directory: profile, passwords: .refusingQualification { calls.note() },
                sftpPasswords: .refusingQualification { calls.note() }, sftpEnabled: true); service = connections
            connections.present(in: browser); try await wait { connections.verificationWindow?.model.managing == false }
            guard let connect = connections.verificationWindow else { throw Failure.scope }; let model = connect.model
            model.connectionProtocol = .sftp; model.serverField = independent ? "localhost" : "private.internal.test"; model.portField = String(port)
            model.startingFolderField = independent ? "/fixture/Uploads/MFA/Native" : ""; model.account = "generated"; model.name = "Generated routed destination"
            let selectedKey = location.appendingPathComponent("source/client-key")
            if method == "prompts" { model.sftpAuthentication = .serverPrompts }
            else { model.useSSHKey(selectedKey); model.extraServerPrompts = method == "mfa" }
            model.jumpHost.enabled = true; model.jumpHost.address = "sftp://127.0.0.1:\(jumpPort)"; model.jumpHost.account = "generated"
            if method == "prompts" { model.jumpHost.method = .serverPrompts }
            else {
                model.jumpHost.method = .keyFile; model.jumpHost.selectedKey = try .init(file: selectedKey)
                model.jumpHost.keyName = "Generated key"; model.jumpHost.extraPrompts = method == "mfa"; model.jumpHost.passphrase = "generated-only-not-a-secret"
                model.keyPassphrase = "generated-only-not-a-secret"
            }
            model.transferBehavior = .cautious; try require(model.canUseFreshUploads && model.freshUploads && !model.rememberServer && !model.rememberPassword)
            responsiveness.previous = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                responsiveness.sample()
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            } }
            responsiveness.stage = "two-role-connect"; model.connect(); var reviews = [String: String](), rounds = Set<String>()
            signIn = Task { @MainActor in
                while model.busy {
                    if let trust = connections.verificationSFTPTrust, !trust.model.busy, trust.model.finished == nil {
                        let role = trust.model.review.host + ":" + String(trust.model.review.port)
                        if reviews[role] == nil {
                            try require(trust.model.review.kind == .first && trust.model.review.fingerprint == (reviews.isEmpty ? jumpFingerprint : fingerprint))
                            reviews[role] = trust.model.review.fingerprint; trust.model.proceed()
                        }
                    }
                    if let prompt = connections.verificationSFTPInteractive, prompt.model.phase == .input,
                       SFTPInteractiveConnectionVerification.fieldsReady(prompt), !rounds.contains(prompt.model.challenge.id), let panel = prompt.window {
                        rounds.insert(prompt.model.challenge.id); try require(rounds.count <= 4)
                        for (index, field) in prompt.model.challenge.prompts.enumerated() {
                            try SFTPInteractiveConnectionVerification.enterResponse(independent ? "123456" : prompt.model.challenge.round == 2 ? "654321" : field.echo ? "generated" : "123456", at: index, in: prompt)
                        }
                        try SFTPInteractiveConnectionVerification.pressReturn(panel)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await wait { !model.busy }; try await signIn?.value; signIn = nil
            try require(model.connected && reviews.count == 2 && rounds.count == (method == "key" ? 0 : 4) && calls.value == 0)
            guard let owner = browser.sftpTabs[browser.activeID], let history = owner.uploads else { throw Failure.scope }; tab = owner
            try await wait { owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages }
            try require(owner.session.allowsFreshUploads && owner.session.allowsRequestedFolderDownloads && owner.session.allowsFreshFolderUploads == folderUpload && owner.routeLabel == "via 127.0.0.1")
            responsiveness.stage = "cancel-review"
            let localFolder = location.appendingPathComponent("source/Local/Folder")
            if folderUpload {
                browser.sftpFolderUpload.chooseForVerification = { _ in localFolder }; browser.sftpFolderUpload.reviewForVerification = { _ in nil }
                browser.sftpFolderUpload.request(from: owner)
            } else {
                browser.sftpUpload.chooseForVerification = { _ in source }; browser.sftpUpload.reviewForVerification = { _ in nil }
                browser.sftpUpload.request(from: owner)
            }
            try await wait { browser.operationPreparationTask == nil }
            try require((try await history.inspect()).records.isEmpty && owner.session.latest.failure == nil)
            responsiveness.stage = "upload"; var routeVisible = false,nativeFolderConfirmation = !folderUpload
            if folderUpload {
                browser.sftpFolderUpload.reviewForVerification = { review in
                    routeVisible = review.model.destination.contains("via 127.0.0.1"); review.model.name = independent ? "Native Folder" : "Folder"
                    let presented = Task { @MainActor in await review.choose(in: window) }
                    try? await wait { window.attachedSheet === review.window && review.window?.isVisible == true }
                    // A real user acts after presentation has returned to the
                    // event loop. Directly calling finish in the same turn
                    // concatenates AppKit's two synchronous sheet animations.
                    try? await Task.sleep(for:.milliseconds(30))
                    if scenario == "success", let panel = review.window {
                        panel.title = "Upload Folder · generated review"
                        for (label,expanded) in [("routed-folder-details-open",true),("routed-folder-details-close",false)] {
                            // A sheet's WindowServer stream can represent its
                            // whole parent. Capture that exact generated owner
                            // at its real geometry, including the attached sheet.
                            do {
                                // Remote navigation updates the browser title.
                                // Restore only this owned generated window's
                                // title immediately before the scope check.
                                window.title = "SFTP jump Upload · generated review"
                                let report = try await NativeMotionRecorder.record(window: window,root: location,label: label,sampling: .diagnostic(for: window),action: { review.model.details = expanded })
                                try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/" + label + ".json"),options: .withoutOverwriting)
                                clips.append(DevelopmentMotionVerification.clip(label,report: report,field: nil,window: window))
                            } catch {
                                captureFailure = ["label":label,"errorType":String(reflecting:type(of:error)),
                                    "failure":(error as? NativeMotionRecorder.Failure)?.rawValue ?? "other",
                                    "generatedTitle":window.title.contains("generated review"),"width":window.frame.width,"height":window.frame.height]
                                review.finish(nil); _ = await presented.value; return nil
                            }
                        }
                    }
                    nativeFolderConfirmation=SFTPFolderUploadPreviewVerification.pressUpload(in:review)
                    if !nativeFolderConfirmation{review.finish(nil)}
                    return await presented.value
                }
                browser.sftpFolderUpload.request(from: owner)
            } else {
            browser.sftpUpload.reviewForVerification = { review in
                routeVisible = review.model.destination.contains("via 127.0.0.1"); review.model.name = "Draft-Notes.bin"
                let finish = Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); review.finish(review.model.valid ? review.model.name : nil) }
                let result = await review.choose(in: window); await finish.value; return result
            }
            browser.sftpUpload.request(from: owner)
            }
            if scenario == "stop" {
                try await wait { browser.operationTask != nil }
                try await wait { FileManager().fileExists(atPath: location.appendingPathComponent("state/Stop.control").path) }
                browser.cancelFileOperation(nil)
            }
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
            let outcome = try await history.inspect()
            try require(nativeFolderConfirmation)
            try require(routeVisible && outcome.records.count == 1 && !outcome.records[0].active && outcome.records[0].publication == (folderUpload ? .exclusiveFreshFolder : .exclusiveFinal))
            try require(outcome.records[0].outcome == (scenario == "success" ? .verified : .reviewPublication))
            if folderUpload {
                try require(scenario == "success" ? browser.sftpFolderUpload.lastCompleted?.logicalBytes == (independent ? 65556 : 3)
                    && browser.sftpFolderUpload.lastCompleted?.files == (independent ? 3 : 1)
                    && outcome.records[0].folder?.verifiedFiles == (independent ? 3 : 1)
                    : browser.sftpFolderUpload.lastCompleted == nil && owner.drain?.localResourcesEnded == true)
                if scenario == "success" { try require(clips.count == 2) }
            } else {
                try require(scenario == "success" ? browser.sftpUpload.lastCompleted?.logicalBytes == 65553 : browser.sftpUpload.lastCompleted == nil && owner.drain?.localResourcesEnded == true)
            }
            responsiveness.stage = "actual-drain"; let ended = await owner.close().value
            try require(ended.localResourcesEnded && ended.actualExit && ended.ipcEOF && ended.temporaryStoreRemoved == true
                && ended.terminal?.jumpTaskEndedBeforeRuntimeDrop != nil && ended.terminal?.tasksAfterRuntimeDrop == 0 && ended.terminal?.catalogWriterEnd == .closed)
            await connections.closeAndDrain(); service = nil
            try require(ApplicationSMBActivity.gate.activeCount == 0 && calls.value == 0)
            let coldStore = SFTPUploadStorage(directory: profile.appendingPathComponent("sftp-upload-history")), cold = try await coldStore.inspect()
            try require(cold.records.count == 1 && !cold.records[0].active && cold.records[0].outcome == outcome.records[0].outcome); _ = await coldStore.close()
            try require(try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) == original }.value)
            responsiveness.stage = "diagnostics"; await logs.flush(); let events = try await logs.page(limit: 256).events.filter { $0.action == .remoteUpload }
            let groups = Dictionary(grouping: events, by: \.trace)
            try require(groups.count == 2 && groups.values.allSatisfy { rows in rows.filter { [.completed, .partial, .cancelled, .failed, .blocked].contains($0.phase) }.count == 1 })
            // Successful source completion keeps the connection usable. Its
            // later exact owner.close above proves child/catalog drain; only
            // interrupted transfers emit the operation's separate drain event.
            try require(scenario == "success" ? events.contains { $0.phase == .completed }
                : events.contains { $0.phase == .finished && ($0.count ?? 0) & 3 == 3 } && !events.contains { $0.phase == .completed })
            let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            try require(!text.contains(location.path) && !text.contains("Draft-Notes.bin") && !text.contains("Native Folder") && !text.contains("generated-only-not-a-secret") && !text.contains("123456"))
            try Data(text.utf8).write(to: location.appendingPathComponent("evidence/routed-upload-diagnostics.json"), options: .withoutOverwriting)
            await ApplicationDiagnostics.shared.closeAndDrain(); recorder = nil
            ticker?.cancel(); await ticker?.value; ticker = nil; try require(responsiveness.gap < 0.5)
            try report(["passed": true, "scenario": scenario, "method": method, "independentOpenSSH": independent, "twoRoleReviews": reviews.count,
                "promptRounds": rounds.count, "keychainCalls": calls.value, "routeVisibleInReview": routeVisible, "cancelBeforeIntent": true,
                "uploadOutcome": cold.records[0].outcome.rawValue, "sourceUnchanged": true, "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF,
                "catalogRemoved": ended.temporaryStoreRemoved == true, "jumpTerminalPresent": true, "maximumMainActorGapSeconds": responsiveness.gap,
                "mainActorGapsByStage": responsiveness.byStage,
                "interfacePercent": settings.interfaceSize.percent, "folderUpload":folderUpload,"nativeFolderConfirmation":nativeFolderConfirmation,"clips":clips,
                "transferDiagnosticsVerified": true, "visualAcceptance": false], to: location)
        } catch {
            signIn?.cancel(); _ = await signIn?.result
            windowOwner?.browser.cancelFileOperation(nil); await windowOwner?.browser.operationTask?.value
            if let tab { _ = await tab.close().value }; await service?.closeAndDrain(); ticker?.cancel(); await ticker?.value
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? report(["passed": false, "stage": responsiveness.stage, "line": line, "errorType": String(reflecting: type(of: error)), "keychainCalls": calls.value, "maximumMainActorGapSeconds": responsiveness.gap, "mainActorGapsByStage": responsiveness.byStage,"captureFailure":captureFailure], to: root) }
        }
        await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        windowOwner?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private static func report(_ data: [String: Any], to root: URL) throws {
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-routed-upload.json"), options: .withoutOverwriting)
    }
}
#endif
