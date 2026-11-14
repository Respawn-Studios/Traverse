#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// Real shared Connect, guarded Download/Undo and Upload on generated sources.
/// No personal file, OS password backend or ordinary startup is admitted.
@MainActor enum SFTPTransferAuthenticationVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    @MainActor private final class PhaseTrace {
        var name = "scope"
        var gaps: [String: Double] = [:]
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 25
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        if ProcessInfo.processInfo.arguments.contains("--preview-only") { await runPreview(); return }
        var root: URL?, windowOwner: BrowserWindowController?, connections: ApplicationSMBConnections?, tab: SFTPTabController?
        var ticker: Task<Void, Never>?, gap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        var diagnosticRecorder: DiagnosticRecorder?
        let trace = PhaseTrace()
        let calls = Calls()
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) throws -> String {
                guard let at = args.firstIndex(of: key), args.indices.contains(at+1) else { throw Failure.scope }; return args[at+1]
            }
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: path), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "sftp-native-auth-transfer"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app"))
            root = location
            if args.contains("--move-history-only") {
                trace.name = "cold-move-outcomes"
                let cutHistory = args.contains("--remote-cut-flow")
                let earlierBytes = try Data(contentsOf: location.appendingPathComponent("evidence/native-auth-transfer.json"))
                let earlier = try JSONSerialization.jsonObject(with: earlierBytes) as? [String: Any]
                try require(earlier?["passed"] as? Bool == true && earlier?["sameSessionMoves"] as? Bool == true
                    && (cutHistory ? earlier?["cutPaste"] as? Bool == true : earlier?["cutPaste"] as? Bool != true))
                let store = SFTPRemoteActionStore(directory: location.appendingPathComponent("state/Native/sftp-remote-actions"))
                let history = try await store.inspect(); try validateMoveHistory(history, usingCut: cutHistory)
                try require(await store.close())
                let value: [String: Any] = ["passed": true, "coldHistory": true, "sameSessionMoves": true, "cutPaste": cutHistory,
                    "earlierReportSHA256": Data(SHA256.hash(data: earlierBytes)).base64EncodedString(),
                    "outcomes": history.records.map { $0.id.uuidString + ":" + $0.kind.rawValue + ":" + $0.outcome.rawValue },
                    "networkConnections": 0, "fileOperations": 0, "keychainCalls": 0]
                try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                    .write(to: location.appendingPathComponent("evidence/" + (cutHistory ? "native-cut-outcomes-cold.json" : "native-move-outcomes-cold.json")), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return
            }
            if args.contains("--permission-history-only") {
                // Replay the retained failed verifier after its original app
                // has drained. Never reconnect or repeat a file operation.
                let earlierBytes = try Data(contentsOf: location.appendingPathComponent("evidence/native-auth-transfer.json"))
                let earlier = try JSONSerialization.jsonObject(with: earlierBytes) as? [String: Any]
                try require(earlier?["passed"] as? Bool == false
                    && earlier?["checkpoint"] as? String == "same-session-editor-save"
                    && earlier?["localStorageFailure"] as? String == "busy")
                let history = SFTPUploadStorage(directory: location.appendingPathComponent("state/Native/sftp-upload-history"))
                let cold = try await history.inspect()
                try require(cold.records.count == 3 && cold.records.filter { $0.outcome == .notStarted }.count == 1
                    && cold.records.filter { $0.outcome == .verified }.count == 2 && !cold.records.contains { $0.active })
                try require(await history.close())
                let value: [String: Any] = ["passed": true, "coldHistory": true,
                    "earlierReportSHA256": Data(SHA256.hash(data: earlierBytes)).base64EncodedString(),
                    "outcomes": cold.records.map { $0.id.uuidString + ":" + $0.outcome.rawValue },
                    "networkConnections": 0, "fileOperations": 0, "keychainCalls": 0,
                    "originalRuntimeVerdictUnchanged": true]
                try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                    .write(to: location.appendingPathComponent("evidence/native-auth-transfer-cold.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return
            }
            let diagnostic = DiagnosticRecorder(directory: location.appendingPathComponent("state/diagnostics"),
                limits: try .init(bytes: 128 << 10, segmentBytes: 16 << 10), recording: true)
            diagnosticRecorder = diagnostic; ApplicationDiagnostics.shared.configureForVerification(diagnostic)
            let method = try argument("--generated-method"), scenario = try argument("--generated-transfer")
            let independent = args.contains("--independent-openssh")
            let folderUpload = args.contains("--fresh-folder-upload")
            let ordinary = args.contains("--ordinary-exclusive-upload")
            let permissionFlow = args.contains("--upload-permission-flow")
            let moveFlow = args.contains("--remote-move-flow")
            let cutFlow = args.contains("--remote-cut-flow")
            try require(!cutFlow || moveFlow)
            try require(!permissionFlow || independent && ordinary && !folderUpload && method == "prompts" && scenario == "success")
            try require(!moveFlow || !permissionFlow && independent && ordinary && !folderUpload && method == "prompts" && scenario == "success")
            SFTPRemoteActionFeature.qualifying = permissionFlow || moveFlow
            SFTPRemoteActionFeature.qualifyingMoves = moveFlow
            SFTPRemoteActionFeature.qualifyingDirectoryMoves = moveFlow
            RemoteClipboardFeature.qualifying = cutFlow
            defer {
                SFTPRemoteActionFeature.qualifying = false; SFTPRemoteActionFeature.qualifyingMoves = false
                SFTPRemoteActionFeature.qualifyingDirectoryMoves = false
                RemoteClipboardFeature.qualifying = false
            }
            SFTPFolderUploadFeature.qualifying = folderUpload
            defer { SFTPFolderUploadFeature.qualifying = false }
            if ordinary { try require(SFTPUploadFeature.enabled) }
            SFTPUploadFeature.qualifying = !ordinary
            defer { SFTPUploadFeature.qualifying = false }
            try require(["key","prompts","mfa"].contains(method) && ["success","download-stop","upload-lost-close","upload-stop"].contains(scenario)
                && (!independent || scenario == "success"))
            guard let port = UInt16(try argument("--generated-port")), port > 0 else { throw Failure.scope }
            let fingerprint = try argument("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            if args.contains("--large-interface") { settings.interfaceSize = .init(150) }
            if args.contains("--light-interface") { settings.appearance = .light; settings.motion.mode = .reduced }
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
            InterfacePresentation.shared.bind(settings)
            let controller = BrowserWindowController(settings: settings); windowOwner = controller
            let browser = controller.browser, profile = location.appendingPathComponent("state/Native")
            let destination = location.appendingPathComponent("source/Destination/Received.bin"), occupied = location.appendingPathComponent("source/Destination/Existing.txt")
            let source = location.appendingPathComponent("source/Local/Upload.bin"), key = location.appendingPathComponent("source/client-key")
            let original = try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) }.value
            let metadata = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"))
            let bodies = try SFTPDownloadStorage(directory: profile.appendingPathComponent("remote-downloads"))
            let engine = browser.operationCoordinator.engine(at: profile.appendingPathComponent("operation-recovery"))
            browser.recoverableFileOperations = engine; browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.readVolumesForVerification = { [] }
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.tabs = [BrowserTab(location: .directory(source.deletingLastPathComponent()))]; browser.activeID = browser.tabs[0].id
            browser.loadLocation()
            guard let window = controller.window else { throw Failure.scope }
            window.setContentSize(.init(width: 960, height: 650)); window.title = "SFTP authenticated transfers · generated review"
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let service = ApplicationSMBConnections(directory: profile, passwords: .refusingQualification { calls.increment() },
                sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true); connections = service
            service.present(in: browser); try await wait { service.verificationWindow?.model.managing == false }
            guard let connect = service.verificationWindow else { throw Failure.scope }
            let model = connect.model
            model.connectionProtocol = .sftp; model.address = "sftp://127.0.0.1:\(port)" + (independent ? "/fixture" : "/")
            model.account = "generated"; model.name = "Generated authenticated transfers"
            try require(model.profileFeaturesAvailable && model.serverPromptsAvailable && model.freshUploadAvailable && model.freshUploads)
            // This control intentionally exercises review cancellation/naming;
            // new ordinary connections now visibly default to normal transfers.
            model.transferBehavior = permissionFlow || moveFlow ? .normal : .cautious
            if method == "prompts" { model.sftpAuthentication = .serverPrompts }
            else { model.useSSHKey(key); model.keyPassphrase = "generated-only-not-a-secret"; model.extraServerPrompts = method == "mfa" }
            model.freshUploads = true; model.freshFolderUploads = folderUpload
            previous = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; gap = max(gap, now-previous)
                trace.gaps[trace.name] = max(trace.gaps[trace.name] ?? 0, now-previous); previous = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            } }
            trace.name = "native-authentication"; model.connect()
            try require(model.password.isEmpty && model.keyPassphrase.isEmpty)
            try await wait { service.verificationSFTPTrust != nil || !model.busy }
            guard let trust = service.verificationSFTPTrust else { throw Failure.scope }
            try require(trust.model.review.fingerprint == fingerprint && trust.model.review.kind == .first)
            trust.model.proceed()
            var promptRounds = 0, promptWindow: Int?
            for round in 1...8 where method != "key" {
                try await wait { !model.busy || service.verificationSFTPInteractive?.model.phase == .input
                    && service.verificationSFTPInteractive?.model.challenge.round == UInt8(round) }
                if !model.busy { break }
                guard let prompt = service.verificationSFTPInteractive, let panel = prompt.window else { throw Failure.scope }
                try await wait { SFTPInteractiveConnectionVerification.fieldsReady(prompt) }
                if let promptWindow { try require(promptWindow == panel.windowNumber) } else { promptWindow = panel.windowNumber }
                for (index, field) in prompt.model.challenge.prompts.enumerated() {
                    let response = independent ? "123456" : round == 2 ? "654321" : field.echo ? "generated" : "123456"
                    try SFTPInteractiveConnectionVerification.enterResponse(response, at: index, in: prompt)
                }
                promptRounds += 1; try SFTPInteractiveConnectionVerification.pressReturn(panel)
                try await wait { prompt.model.phase != .input }
            }
            try await wait { !model.busy }
            try require(model.connected && service.verificationSFTPInteractive == nil && calls.value == 0
                && promptRounds == (method == "key" ? 0 : permissionFlow || moveFlow ? 1 : 2))
            guard let owner = browser.sftpTabs[browser.activeID], owner.downloads != nil, let history = owner.uploads else { throw Failure.scope }; tab = owner
            try require(owner.session.allowsRequestedDownloads && owner.session.allowsFreshUploads && owner.session.allowsFreshFolderUploads == folderUpload)
            try await wait { owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages }
            if moveFlow {
                let outcomes = try await verifyMoves(browser: browser, owner: owner, window: window, trace: trace, usingCut: cutFlow)
                trace.name = "move-actual-drain"
                let ended = await owner.close().value
                try require(ended.localResourcesEnded && ended.actualExit && ended.ipcEOF
                    && ended.temporaryStoreRemoved == true && ended.terminal?.tasksAfterRuntimeDrop == 0)
                await service.closeAndDrain(); connections = nil
                try require(calls.value == 0 && ApplicationSMBActivity.gate.activeCount == 0)
                let actionWriterEnded = await owner.remoteActions?.close()
                try require(actionWriterEnded == true)
                let coldStore = SFTPRemoteActionStore(directory: profile.appendingPathComponent("sftp-remote-actions"))
                let cold = try await coldStore.inspect(); try validateMoveHistory(cold, usingCut: cutFlow)
                try require(await coldStore.close())
                await ApplicationDiagnostics.shared.closeAndDrain(); diagnosticRecorder = nil
                ticker?.cancel(); await ticker?.value; ticker = nil
                try write(["passed": true, "sameSessionMoves": true, "cutPaste": cutFlow, "actualSharedConnect": true,
                    "actualConnections": 1, "promptRounds": promptRounds, "keychainCalls": calls.value,
                    "outcomes": outcomes, "coldOutcomes": cold.records.count,
                    "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF, "catalogRemoved": ended.temporaryStoreRemoved == true,
                    "maximumMainActorGapSeconds": gap, "phaseMainActorGapSeconds": trace.gaps,
                    "independentServerInventory": false, "physicalPickerInput": false], to: location)
                ApplicationDiagnostics.shared.configureForVerification(nil)
                window.close(); NSApplication.shared.terminate(nil); return
            }
            if permissionFlow {
                trace.name = "permission-continuation"
                let facts = try await verifyPermissionContinuation(browser: browser, owner: owner,
                    history: history, source: source, window: window,
                    profile: profile, diagnostic: diagnostic, trace: trace)
                trace.name = "actual-drain"
                let ended = await owner.close().value
                try require(ended.localResourcesEnded && ended.actualExit && ended.ipcEOF
                    && ended.temporaryStoreRemoved == true && ended.terminal?.tasksAfterRuntimeDrop == 0)
                await service.closeAndDrain(); connections = nil
                try require(calls.value == 0 && ApplicationSMBActivity.gate.activeCount == 0)
                try require(try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) == original }.value)
                await ApplicationDiagnostics.shared.closeAndDrain(); diagnosticRecorder = nil
                ticker?.cancel(); await ticker?.value; ticker = nil
                try write(["passed": true, "permissionContinuation": facts, "actualSharedConnect": true,
                    "actualConnections": 1, "promptRounds": promptRounds, "keychainCalls": calls.value,
                    "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF, "catalogRemoved": ended.temporaryStoreRemoved == true,
                    "maximumMainActorGapSeconds": gap, "phaseMainActorGapSeconds": trace.gaps], to: location)
                ApplicationDiagnostics.shared.configureForVerification(nil)
                window.close(); NSApplication.shared.terminate(nil); return
            }
            let count = owner.rows.cache.snapshot?.count ?? 0; try require(count <= 8)
            guard let index = (0..<Int(count)).first(where: { owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == "Requested.bin" }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try require(owner.rows.selectedDownload?.logicalBytes == 1_048_593 && browser.sftpDownload.canRequest(from: owner))
            trace.name = "occupied-destination"
            browser.sftpDownload.chooseForVerification = { _ in occupied }; browser.sftpDownload.request(from: owner, toPane: false)
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            let beforeBodies = try await bodies.inspect()
            try require(browser.sftpDownload.lastOutcome == nil && beforeBodies.isEmpty)
            trace.name = "native-download"
            browser.sftpDownload.chooseForVerification = { _ in destination }; browser.sftpDownload.request(from: owner, toPane: false)
            var exactUndo = false, retainedArea = "", operation = ""
            if scenario == "download-stop" {
                try await wait { browser.operationTask != nil }
                try await wait { FileManager().fileExists(atPath: location.appendingPathComponent("state/Stop.control").path) }
                browser.cancelFileOperation(nil)
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                let kept = try await bodies.inspect()
                try require(kept.count == 1 && !kept[0].active && browser.sftpDownload.lastOutcome == nil
                    && !FileManager().fileExists(atPath: destination.path) && owner.drain?.localResourcesEnded == true)
            } else {
                try await wait { browser.sftpDownload.lastOutcome != nil && browser.operationTask == nil && browser.operationPreparationTask == nil }
                guard let received = browser.sftpDownload.lastOutcome, let id = received.recordID else { throw Failure.scope }
                try require(received.result.disposition == .succeeded)
                let valid = try await Task.detached {
                    let data = try Data(contentsOf: destination)
                    let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
                    let prior = try Data(contentsOf: occupied)
                    return data.count == 1_048_593 && data.enumerated().allSatisfy { $0.element == UInt8((UInt64($0.offset)*31+7)%251) }
                        && quarantine != nil && prior == Data("Existing generated file".utf8)
                }.value
                let receivedBodies = try await bodies.inspect(); try require(valid && receivedBodies.isEmpty)
                trace.name = "native-exact-undo"
                browser.openOperationRecovery(recordID: id)
                try await wait { browser.recoveryWindow?.selectedRecordID == id && browser.recoveryRecords.contains(where: { $0.id == id && $0.canUndo }) }
                guard let record = browser.recoveryRecords.first(where: { $0.id == id }) else { throw Failure.scope }
                browser.startRecoveryOperation(record, rollback: false)
                try await wait { browser.operationTask == nil }
                try require(browser.lastOperationResult?.disposition == .succeeded && !FileManager().fileExists(atPath: destination.path))
                browser.recoveryWindow?.close()
                let retained = try await engine.retentionRecord(recordID: id)
                try require(retained.areas.count == 1 && retained.areas[0].verified)
                retainedArea = retained.areas[0].url.lastPathComponent; operation = id.uuidString; exactUndo = true
                if independent {
                    let parts = try (["fixture","Uploads",method == "mfa" ? "MFA" : "Prompts"] + (folderUpload ? ["Native"] : [])).map { try SFTPRemoteName(Data($0.utf8)) }
                    browser.navigate(to: .sftp(try owner.directoryLocation(components: parts)))
                    try await wait { owner.session.latest.snapshot?.state == .complete && !owner.hasPendingPages && owner.rows.cache.snapshot?.count == 0 }
                }
                if folderUpload {
                    let folder = source.deletingLastPathComponent().appendingPathComponent("Folder")
                    trace.name = "cancel-folder-upload-preview"
                    browser.sftpFolderUpload.chooseForVerification = { _ in folder }; browser.sftpFolderUpload.reviewForVerification = { _ in nil }
                    browser.sftpFolderUpload.request(from: owner); try await wait { browser.operationPreparationTask == nil }
                    try require((try await history.inspect()).records.isEmpty && owner.session.latest.failure == nil)
                    trace.name = "native-folder-upload"
                    browser.sftpFolderUpload.reviewForVerification = { preview in
                        preview.model.name = "Native Folder"
                        let completion = Task { @MainActor in try? await Task.sleep(for: .milliseconds(450)); preview.finish(preview.model.valid ? preview.model.name : nil) }
                        let result = await preview.choose(in: window); await completion.value; return result
                    }
                    browser.sftpFolderUpload.request(from: owner)
                    try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                    let outcome = try await history.inspect()
                    try require(outcome.records.count == 1 && !outcome.records[0].active && outcome.records[0].publication == .exclusiveFreshFolder
                        && outcome.records[0].outcome == .verified && outcome.records[0].folder?.verifiedFiles == 3
                        && browser.sftpFolderUpload.lastCompleted?.files == 3 && browser.sftpFolderUpload.lastCompleted?.logicalBytes == 65556)
                } else {
                trace.name = "cancel-upload-preview"
                browser.sftpUpload.chooseForVerification = { _ in source }; browser.sftpUpload.reviewForVerification = { _ in nil }
                browser.sftpUpload.request(from: owner)
                try await wait { browser.operationPreparationTask == nil }
                try require((try await history.inspect()).records.isEmpty && owner.session.latest.failure == nil)
                trace.name = "native-upload"
                browser.sftpUpload.reviewForVerification = { preview in
                    preview.model.name = "Draft-Notes.bin"
                    let completion = Task { @MainActor in try? await Task.sleep(for: .milliseconds(450)); preview.finish(preview.model.valid ? preview.model.name : nil) }
                    let result = await preview.choose(in: window); await completion.value; return result
                }
                browser.sftpUpload.request(from: owner)
                if scenario == "upload-stop" {
                    try await wait { browser.operationTask != nil }
                    try await wait { FileManager().fileExists(atPath: location.appendingPathComponent("state/Stop.control").path) }
                    browser.cancelFileOperation(nil)
                }
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                let outcome = try await history.inspect()
                try require(outcome.records.count == 1 && !outcome.records[0].active
                    && outcome.records[0].publication == .exclusiveFinal
                    && outcome.records[0].outcome == (scenario == "success" ? .verified : .reviewPublication))
                try require(scenario != "success" ? browser.sftpUpload.lastCompleted == nil
                    && owner.drain?.localResourcesEnded == true : browser.sftpUpload.lastCompleted?.logicalBytes == 65553)
                }
                if scenario == "success" { _ = await owner.close().value }
            }
            trace.name = "actual-drain"
            let ended = await owner.close().value
            try require(ended.localResourcesEnded && ended.actualExit && ended.ipcEOF && ended.temporaryStoreRemoved == true
                && ended.terminal?.tasksAfterRuntimeDrop == 0 && ended.terminal?.catalogWriterEnd == .closed)
            await service.closeAndDrain(); connections = nil
            try require((try await SMBTemporaryCatalogPool(storage: metadata).inspect()).isEmpty
                && ApplicationSMBActivity.gate.activeCount == 0 && calls.value == 0)
            let cold = try await SFTPUploadStorage(directory: profile.appendingPathComponent("sftp-upload-history")).inspect()
            try require(cold.records.count == (scenario == "download-stop" ? 0 : 1))
            try require(try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) == original }.value)
            await diagnostic.flush()
            var page = try await diagnostic.page(limit: 256), logged = page.events
            while let cursor = page.next {
                try require(logged.count <= 512)
                page = try await diagnostic.page(before: cursor, limit: 256); logged += page.events
            }
            let downloads = logged.filter { $0.action == .remoteDownload }
            try require(downloads.contains { $0.phase == .failed && $0.error?.symbol == "conflict" })
            if scenario == "download-stop" {
                try require(downloads.contains { $0.phase == .cancelled }
                    && downloads.contains { $0.phase == .draining }
                    && downloads.contains { $0.phase == .finished && ($0.count ?? 0) & 3 == 3 })
            } else {
                guard let done = downloads.first(where: { $0.phase == .completed }) else { throw Failure.scope }
                try require([DiagnosticPhase.resolving,.preparing,.transferring,.verifying,.committing,.cleaning].allSatisfy { phase in
                    downloads.contains { $0.trace == done.trace && $0.phase == phase }
                } && logged.contains { $0.trace == done.trace && $0.relatedTrace != nil })
                let upload = logged.filter { $0.action == .remoteUpload }
                if scenario == "upload-lost-close" {
                    try require(upload.contains { $0.phase == .partial && $0.error?.domain == .network
                        && ($0.error?.code ?? 0) >= 501 && $0.causes?.count == 2 }
                        && upload.contains { $0.phase == .finished && ($0.count ?? 0) & 3 == 3 })
                } else if scenario == "upload-stop" {
                    try require(upload.contains { $0.phase == .partial || $0.phase == .cancelled }
                        && upload.contains { $0.phase == .finished && ($0.count ?? 0) & 3 == 3 })
                } else { try require(upload.contains { $0.phase == .completed }) }
            }
            for transfer in [DiagnosticAction.remoteDownload,.remoteUpload] {
                let groups = Dictionary(grouping: logged.filter { $0.action == transfer }, by: \.trace)
                for events in groups.values {
                    try require(events.filter { [.completed,.partial,.cancelled,.failed,.blocked].contains($0.phase) }.count == 1)
                }
            }
            let encoded = try JSONEncoder().encode(logged), logText = String(decoding: encoded, as: UTF8.self)
            try require(!logText.contains(location.path) && !logText.contains("Requested.bin") && !logText.contains("Upload.bin")
                && !logText.contains("generated-only-not-a-secret") && !logText.contains("\"123456\"") && !logText.contains("\"654321\""))
            try encoded.write(to: location.appendingPathComponent("evidence/transfer-diagnostics.json"), options: .withoutOverwriting)
            await ApplicationDiagnostics.shared.closeAndDrain(); diagnosticRecorder = nil
            ticker?.cancel(); await ticker?.value; ticker = nil; try require(gap < 0.5)
            try write(["passed": true, "method": method, "scenario": scenario, "independentOpenSSH": independent,
                "actualSharedConnect": true, "promptRounds": promptRounds, "allInputSecretsCleared": true, "keychainCalls": calls.value,
                "occupiedDestinationPreserved": true, "exactUndo": exactUndo, "retainedUndoArea": retainedArea, "retainedUndoOperation": operation,
                "uploadOutcome": cold.records.first?.outcome.rawValue ?? "none", "uploadSourceUnchanged": true, "transferDiagnosticsVerified": true,
                "folderUpload": folderUpload, "ordinaryUpload": ordinary, "qualificationOverride": SFTPUploadFeature.qualifying,
                "interfacePercent": settings.interfaceSize.percent,
                "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF, "catalogRemoved": ended.temporaryStoreRemoved == true,
                "maximumMainActorGapSeconds": gap, "phaseMainActorGapSeconds": trace.gaps, "visualAcceptance": false], to: location)
        } catch {
            windowOwner?.browser.cancelFileOperation(nil); await windowOwner?.browser.operationTask?.value
            if let tab { _ = await tab.close().value }; await connections?.closeAndDrain()
            ticker?.cancel(); await ticker?.value
            var line: UInt = 0; if case let Failure.check(number) = error { line = number }
            if let root { try? write(["passed": false, "checkpoint": trace.name, "line": line,
                "errorType": String(reflecting: type(of: error)), "keychainCalls": calls.value,
                "maximumMainActorGapSeconds": gap, "phaseMainActorGapSeconds": trace.gaps,
                "localStorageFailure": (error as? RemoteSettingsFailure).map { String(describing: $0) } ?? "none"], to: root,
                name: ProcessInfo.processInfo.arguments.contains("--move-history-only")
                    ? (ProcessInfo.processInfo.arguments.contains("--remote-cut-flow") ? "native-cut-outcomes-cold.json" : "native-move-outcomes-cold.json")
                    : "native-auth-transfer.json") }
        }
        await diagnosticRecorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        windowOwner?.window?.close(); NSApplication.shared.terminate(nil)
    }

    private static func validateMoveHistory(_ history: SFTPRemoteActionSnapshot, usingCut: Bool = false) throws {
        try require(history.records.count == 5 && history.active.isEmpty)
        var expected: [(SFTPRemoteActionKind, SFTPRemoteActionOutcome, String, String)] = [
            (.moveFile, .failedSafe, "Rename Source.txt", "/fixture/MissingParent"),
            (.moveFile, .failedSafe, "Rename Source.txt", "/fixture/OccupiedParent"),
            (.moveDirectory, .failedSafe, "NonemptyKeep", "/fixture/OccupiedParent"),
            (.moveFile, .confirmed, "Rename Source.txt", "/fixture/MoveTarget"),
            (.moveDirectory, .confirmed, "NonemptyKeep", "/fixture/MoveTarget"),
        ]
        // The Cut flow checks the folder collision first, so its file collision
        // can continue with the exact retained Cut instead of publishing anew.
        if usingCut { expected.swapAt(1, 2) }
        for (record, value) in zip(history.records, expected) {
            try require(record.kind == value.0 && record.outcome == value.1
                && record.remoteDirectory == "/fixture" && record.remoteName == value.2
                && record.destinationDirectory == value.3)
        }
        try require(history.records[0].refusal == .sourceChanged
            && history.records[1].refusal == .targetExists && history.records[2].refusal == .targetExists)
    }

    /// One real authenticated connection, existing UI commands and outcome
    /// owner. The driver owns independent baseline/final inventories separately.
    private static func verifyMoves(browser: BrowserViewController, owner: SFTPTabController,
        window: NSWindow, trace: PhaseTrace, usingCut: Bool = false) async throws -> [String] {
        guard let store = owner.remoteActions else { throw Failure.scope }
        try require(owner.allowsFileMove && owner.allowsDirectoryMove && !owner.reviewsUploads)
        let connection = owner.connectionID
        let sourceLocation = owner.currentBrowserLocation
        let oldBoard = browser.transferPasteboard
        let cutBoard = usingCut ? NSPasteboard.withUniqueName() : nil
        if let cutBoard { browser.transferPasteboard = cutBoard }
        defer {
            browser.sftpFileActions.destinationForVerification = nil
            if let cutBoard { browser.clipboardState.clear(); browser.transferPasteboard = oldBoard; cutBoard.releaseGlobally() }
        }
        @MainActor func sourceReady() async throws {
            if browser.location != sourceLocation { browser.navigate(to: sourceLocation) }
            try await wait { owner.navigationAdmittedForVerification && !owner.hasPendingPages }
        }
        @MainActor func select(_ name: String) async throws {
            if usingCut { try await sourceReady() }
            try await wait { owner.sealedActionSnapshot != nil && !owner.hasPendingPages
                && (0..<owner.rows.table.numberOfRows).contains { owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == name } }
            guard let index = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == name
            }) else { throw Failure.scope }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try require(window.makeFirstResponder(owner.rows.table))
            owner.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await wait { browser.commandEnabled(#selector(BrowserViewController.moveServerSelection(_:))) }
            let requiredKind: UInt32 = name == "NonemptyKeep" ? 0o040000 : 0o100000
            try require(owner.rows.selectedObservation?.entry.name.wireUTF8 == Data(name.utf8)
                && owner.rows.selectedObservation?.entry.permissions.map({ $0 & 0o170000 == requiredKind }) == true)
        }
        @MainActor func move(_ name: String, to path: String, expecting outcome: SFTPRemoteActionOutcome,
                             reusingCut: ScopedItemClipboardIntent? = nil) async throws -> SFTPRemoteActionRecord {
            try await select(name)
            // A missing destination cannot be opened for Paste. Preserve that
            // existing Move To refusal; real Cut/Paste covers existing folders.
            let pasted = usingCut && path != "/fixture/MissingParent"
            if pasted {
                if let reusingCut {
                    try require(browser.clipboardState.scopedItem === reusingCut
                        && reusingCut.matchesCurrentSelection(in: browser))
                } else { browser.cutFileURLs(nil) }
                try require(browser.clipboardState.scopedItem != nil && cutBoard?.types == [ScopedItemClipboardIntent.pasteboardType])
                let destination = try SFTPDefaultDirectory(field: path, root: .server)
                browser.navigate(to: .sftp(try owner.directoryLocation(components: destination.components, relativeToHome: false)))
                try await wait { owner.navigationAdmittedForVerification && browser.canPasteScopedItem }
                window.makeFirstResponder(owner.rows.table); owner.rows.table.paste(nil)
            } else {
                browser.sftpFileActions.destinationForVerification = { model in model.path = path; return model.canMove ? model.path : nil }
                browser.moveServerSelection(nil)
            }
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
            guard let result = browser.sftpFileActions.lastResult else { throw Failure.scope }
            try require(result.record.outcome == outcome && owner.connectionID == connection
                && !owner.isClosing && owner.session.latest.failure == nil
                && ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation)
            try await wait { owner.sealedActionSnapshot != nil && !owner.hasPendingPages }
            if pasted {
                try require((outcome == .confirmed) == (browser.clipboardState.scopedItem == nil))
                if outcome == .confirmed {
                    try require(owner.rows.cache.loadedEntries.contains { $0.row.entry.name.wireUTF8 == Data(name.utf8) })
                }
                try await sourceReady()
            }
            return result.record
        }
        trace.name = "move-cancel"
        try await select("Rename Source.txt")
        browser.sftpFileActions.destinationForVerification = { _ in nil }
        browser.moveServerSelection(nil)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        try require(try await store.inspect().records.isEmpty)
        trace.name = "move-missing-parent"
        _ = try await move("Rename Source.txt", to: "/fixture/MissingParent", expecting: .failedSafe)
        let collisionNames = usingCut ? ["NonemptyKeep", "Rename Source.txt"] : ["Rename Source.txt", "NonemptyKeep"]
        for name in collisionNames {
            trace.name = name == "NonemptyKeep" ? "move-folder-collision" : "move-file-collision"
            let collision = try await move(name, to: "/fixture/OccupiedParent", expecting: .failedSafe)
            try require(collision.refusal == .targetExists)
        }
        let retainedCut = usingCut ? browser.clipboardState.scopedItem : nil
        trace.name = "move-file-confirmed"
        if usingCut { try require(retainedCut != nil) }
        _ = try await move("Rename Source.txt", to: "/fixture/MoveTarget", expecting: .confirmed, reusingCut: retainedCut)
        try require(!owner.rows.cache.loadedEntries.contains { $0.row.entry.name.displayName == "Rename Source.txt" })
        trace.name = "move-descendant-refusal"
        try await select("NonemptyKeep")
        var rejected = false
        browser.sftpFileActions.destinationForVerification = { model in
            model.path = "/fixture/NonemptyKeep/Child"; rejected = !model.canMove; return nil
        }
        browser.moveServerSelection(nil)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        let beforeFolder = try await store.inspect()
        try require(rejected && beforeFolder.records.count == 4)
        trace.name = "move-folder-confirmed"
        _ = try await move("NonemptyKeep", to: "/fixture/MoveTarget", expecting: .confirmed)
        try require(!owner.rows.cache.loadedEntries.contains { $0.row.entry.name.displayName == "NonemptyKeep" })
        let warm = try await store.inspect(); try validateMoveHistory(warm, usingCut: usingCut)
        return warm.records.map { $0.id.uuidString + ":" + $0.kind.rawValue + ":" + $0.outcome.rawValue }
    }

    /// One ordinary authenticated connection survives a definite create denial,
    /// then performs new writes in its generated writable child. No retry of
    /// the denied operation, elevation or replacement of an existing name.
    private static func verifyPermissionContinuation(browser: BrowserViewController, owner: SFTPTabController,
        history: SFTPUploadStorage, source: URL, window: NSWindow,
        profile: URL, diagnostic: DiagnosticRecorder, trace: PhaseTrace) async throws -> [String: Any] {
        let connection = owner.connectionID
        try require(owner.session.allowsInPlaceEditing && owner.newTextStorage != nil && !owner.reviewsUploads)
        browser.sftpUpload.chooseForVerification = { _ in source }
        var unexpectedReview = false
        browser.sftpUpload.reviewForVerification = { _ in unexpectedReview = true; return nil }
        trace.name = "denied-first-create"
        browser.sftpUpload.request(from: owner)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        let denied = try await history.inspect()
        try require(denied.records.count == 1 && denied.records[0].outcome == .notStarted
            && !denied.records[0].active && browser.sftpUpload.lastCompleted == nil
            && owner.session.latest.failure == nil && !owner.isClosing && owner.drain == nil
            && browser.sftpTabs[browser.activeID] === owner && !unexpectedReview)
        trace.name = "same-session-writable-child"
        let parts = try ["fixture", "Uploads", "Prompts"].map { try SFTPRemoteName(Data($0.utf8)) }
        browser.navigate(to: .sftp(try owner.directoryLocation(components: parts)))
        try await wait { owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages
            && owner.rows.cache.snapshot?.count == 0 }
        try require(owner.connectionID == connection && browser.sftpUpload.canRequest(from: owner))
        trace.name = "same-session-upload"
        browser.sftpUpload.request(from: owner)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        let uploaded = try await history.inspect()
        let sourceBytes = try await Task.detached { try Data(contentsOf: source).count }.value
        try require(uploaded.records.count == 2 && uploaded.records.filter { $0.outcome == .notStarted }.count == 1
            && uploaded.records.filter { $0.outcome == .verified }.count == 1
            && browser.sftpUpload.lastCompleted?.logicalBytes == UInt64(sourceBytes)
            && owner.session.latest.failure == nil && !unexpectedReview)
        try await wait { owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages
            && owner.rows.cache.snapshot?.count == 1 }
        trace.name = "same-session-new-file"
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try require(window.makeFirstResponder(owner.rows.table))
        try await wait { browser.sftpNewFile.canRequest(from: owner) }
        var namePrompts = 0
        browser.operationNamePrompt = { title, _ in
            namePrompts += 1
            return title == FilenamePrompt.newFileTitle ? "Created.json" : nil
        }
        defer { browser.operationNamePrompt = nil; browser.sftpUpload.chooseForVerification = nil
            browser.sftpUpload.reviewForVerification = nil }
        browser.sftpNewFile.request(from: owner)
        try await wait { ApplicationRemoteTextEditors.shared.documentsForVerification.count == 1 }
        guard let document = ApplicationRemoteTextEditors.shared.documentsForVerification.first else { throw Failure.scope }
        try require(document.connectionID == connection && document.displayName == "Created.json"
            && document.window.surface.textView.string.isEmpty && namePrompts == 1)
        let text = "{\n  \"ready\": true\n}\n"
        document.show()
        let view = document.window.surface.textView
        document.window.window?.makeFirstResponder(view)
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0)); view.breakUndoCoalescing()
        try await wait { document.pendingEdit == nil && document.state.isDirty && document.window.saveButton.isEnabled }
        trace.name = "same-session-editor-save"
        document.window.saveButton.performClick(nil)
        try require(document.state.activeCapture != nil)
        try await wait { document.work == nil && document.verificationSaveTerminal }
        try require(document.message == "Saved · SFTP" && !document.state.isDirty && !document.needsReview
            && document.window.surface.textView.string == text && owner.session.latest.failure == nil)
        document.requestClose()
        try await wait { document.closed && ApplicationRemoteTextEditors.shared.documentsForVerification.isEmpty }
        trace.name = "cold-upload-outcomes"
        try require(await history.close())
        let cold = try await SFTPUploadStorage(directory: profile.appendingPathComponent("sftp-upload-history")).inspect()
        try require(cold.records.count == 3 && cold.records.filter { $0.outcome == .notStarted }.count == 1
            && cold.records.filter { $0.outcome == .verified }.count == 2 && !cold.records.contains { $0.active })
        await diagnostic.flush()
        let events = try await diagnostic.page(limit: 256).events
        try require(events.contains { $0.action == .remoteUpload && $0.error?.domain == .network && $0.error?.code == 517 }
            && events.contains { $0.context?.checkpoint == .remoteEditorSave && $0.phase == .completed })
        return ["definiteCreateDenial": true, "sameConnection": true, "uploadVerified": true,
            "newFileAndNativeEditor": true, "savedTextBytes": text.utf8.count,
            "coldOutcomes": 3, "unexpectedUploadReviews": unexpectedReview]
    }
    /// Recording is a separate zero-network workload. It must not be conflated
    /// with the normal transfer responsiveness measurement above.
    private static func runPreview() async {
        var root: URL?, controller: BrowserWindowController?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "exclusive-upload-preview"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = location
            let settings = BrowserSettings(persist: false), args = ProcessInfo.processInfo.arguments
            settings.appearance = args.contains("--light-interface") ? .light : .dark
            settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
            settings.motion.mode = args.contains("--light-interface") ? .reduced : .full
            if args.contains("--large-interface") { settings.interfaceSize = .init(150) }
            InterfacePresentation.shared.bind(settings)
            let source = try await SFTPUploadSourceReview.inspect(location.appendingPathComponent("source/Local/Upload.bin"), excluding: [])
            try require(source.logicalBytes == 65553)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let browser = owner.browser
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.readVolumesForVerification = { [] }
            browser.tabs = [.init(location: .directory(location.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = owner.window else { throw Failure.scope }
            window.setContentSize(.init(width: 970, height: 650)); window.center(); window.title = "SFTP Upload · generated review"
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let preview = SFTPUploadPreview(source: source, destination: "Generated server · selected folder", settings: settings)
            let choice = Task { @MainActor in await preview.choose(in: window) }
            var clips = [[String: Any]]()
            do {
                try await wait { window.attachedSheet === preview.window }
                guard let panel = preview.window, panel.sheetParent === window else { throw Failure.scope }
                try await Task.sleep(for: .milliseconds(200))
                for (label, expanded) in [("upload-details-open", true), ("upload-details-close", false)] {
                    window.title = "SFTP Upload · generated review"
                    let report = try await NativeMotionRecorder.record(window: window, root: location, label: label, sampling: .diagnostic(for: window)) { preview.model.details = expanded }
                    try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
                }
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                guard let content = panel.contentView,
                      let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "New filename" }),
                      panel.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.scope }
                window.title = "SFTP Upload · generated review"
                let report = try await NativeMotionRecorder.record(window: window, root: location, label: "upload-name-edit", sampling: .diagnostic(for: window)) {
                    editor.selectAll(nil); editor.insertText("Reviewed.bin", replacementRange: .init(location: 0, length: field.stringValue.utf16.count))
                }
                try require(preview.model.name == "Reviewed.bin")
                try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/upload-name-edit.json"), options: .withoutOverwriting)
                var clip = DevelopmentMotionVerification.clip("upload-name-edit", report: report, field: nil, window: window)
                let rect = panel.convertToScreen(field.convert(field.bounds, to: nil))
                clip["fieldRegion"] = ["x": rect.minX-window.frame.minX, "y": window.frame.maxY-rect.maxY, "width": rect.width, "height": rect.height]
                clips.append(clip); preview.finish(nil); try require(await choice.value == nil)
            } catch { preview.finish(nil); _ = await choice.value; throw error }
            try JSONSerialization.data(withJSONObject: ["passed": true, "surface": "upload-preview", "clips": clips,
                "interfacePercent": settings.interfaceSize.percent, "motion": settings.motion.mode.rawValue,
                "networkRequests": 0, "uploadCommands": 0, "visualAcceptance": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: location.appendingPathComponent("evidence/native-upload-preview.json"), options: .withoutOverwriting)
        } catch {
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false, "errorType": String(reflecting: type(of: error)),
                "captureFailure": (error as? NativeMotionRecorder.Failure)?.rawValue ?? "none"]).write(to: root.appendingPathComponent("evidence/native-upload-preview.json"), options: .withoutOverwriting) }
        }
        controller?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], to root: URL, name: String = "native-auth-transfer.json") throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/" + name), options: .withoutOverwriting)
    }
}
#endif
