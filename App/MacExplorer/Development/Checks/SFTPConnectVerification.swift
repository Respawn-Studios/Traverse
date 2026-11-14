#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SFTPConnectVerification {
    private enum Failure: Error { case generated, check(UInt) }
    private static var retained: BrowserWindowController?
    private static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 12
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < limit); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func runStandalone() async {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--prepared-editor") || args.contains("--prepared-editor-cold") {
            await runPreparedEditor(cold: args.contains("--prepared-editor-cold")); return
        }
        var root: URL?, service: ApplicationSMBConnections?, ownedState: SFTPRememberedState?, stage = "input"
        var ticker: Task<Void, Never>?, maximumGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        do {
            func field(_ key: String) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { throw Failure.generated }; return args[index + 1]
            }
            let location = URL(fileURLWithPath: try field("--analysis-source")); root = location
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let ordinary = args.contains("--ordinary-worker")
            let caseBound = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String == location.lastPathComponent
            let developmentBound = ordinary && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app")
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil
                && ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == location.path
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/b11-native-qualification")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && (caseBound && !ordinary || developmentBound))
            guard let port = UInt16(try field("--generated-port")), port > 0, let namespace = UUID(uuidString: location.lastPathComponent) else { throw Failure.generated }
            let fingerprint = try field("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            let windowController = BrowserWindowController(settings: settings); retained = windowController
            let browser = windowController.browser
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.tabs = [BrowserTab(location: .directory(location.appendingPathComponent("source/Empty")))]; browser.activeID = browser.tabs[0].id
            browser.loadLocation(); guard let window = windowController.window else { throw Failure.generated }
            window.title = "SFTP Connect · generated review"; window.center(); window.makeKeyAndOrderFront(nil)
            let profile = location.appendingPathComponent("stores/Profile"), vault = SFTPPasswordVault.generatedQualification(namespace: namespace)
            let store = SFTPSettingsStore(directory: profile.appendingPathComponent("sftp-servers"))
            let state = SFTPRememberedState(settings: store, passwords: vault)
            ownedState = state
            let storage = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing")), pool = SMBTemporaryCatalogPool(storage: storage)
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - previous); previous = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }}
            var savedID: UUID?, rowsObserved = 0
            for iteration in 0..<3 {
                stage = "connect-\(iteration)"
                let owner = ApplicationSMBConnections(directory: profile, sftpPasswords: vault, sftpEnabled: true); service = owner
                owner.present(in: browser)
                try await wait { owner.verificationWindow?.model.managing == false }
                guard let connect = owner.verificationWindow, let connectWindow = connect.window else { throw Failure.generated }
                connectWindow.title = "Connect to Server · generated SFTP review"
                let model = connect.model; try require(model.sftpHandler != nil && model.connectionProtocol == .smb)
                model.connectionProtocol = .sftp
                if iteration == 0 {
                    try require(model.password.isEmpty && !model.rememberServer && !model.rememberPassword && model.sftpServers.isEmpty)
                    model.address = "sftp://127.0.0.1:\(port)/"; model.account = "generated"; model.password = "ephemeral qualification password"
                    model.name = "Generated SFTP"; model.rememberServer = true; model.rememberPassword = true
                    connect.setSidebarVisible(true, animated: false); model.showAdvanced = true
                    try await Task.sleep(for: .milliseconds(180))
                    try await UIVerification.snapshot(connectWindow, to: location.appendingPathComponent("evidence/sftp-connect.png"))
                } else {
                    guard let savedID else { throw Failure.generated }; model.choose(savedID)
                    try require(model.password.isEmpty && model.sftpServers.count == 1 && model.sftpServers[0].hasSavedPassword)
                }
                model.connect()
                try await wait { owner.verificationSFTPTrust != nil || !model.busy }
                guard let trust = owner.verificationSFTPTrust else { throw Failure.generated }
                try require(trust.model.review.fingerprint == (iteration == 2 ? trust.model.review.fingerprint : fingerprint))
                if iteration == 2 {
                    try require(trust.model.review.kind == .changed && trust.model.review.previousFingerprint == fingerprint)
                    trust.model.proceed(); await Task.yield()
                    try require(trust.model.finished == nil && trust.model.page == .identity)
                    trust.model.cancel(); try await wait { !model.busy }
                    try require(!model.connected && model.message.contains("cancelled"))
                } else {
                    try require(trust.model.review.kind == (iteration == 0 ? .first : .matching))
                    if iteration == 0 { try require(trust.model.rememberKeyPrefilled && trust.model.rememberKey) }
                    trust.model.proceed(); try await wait { !model.busy }
                    try require(model.connected && !model.rememberingIncomplete)
                    guard let tab = browser.sftpTabs[browser.activeID] else { throw Failure.generated }
                    try await wait { tab.session.latest.snapshot?.state == .complete && tab.rows.cache.retainedCount == 2 && !tab.hasPendingPages }
                    rowsObserved += tab.rows.cache.retainedCount
                    let snapshot = try await state.inspect(); savedID = snapshot?.visibleServers.first?.id
                    try require(snapshot?.visibleHosts.count == 1 && snapshot?.visibleServers.count == 1 && snapshot?.credentials.count == 1)
                    browser.disconnectSFTPConnection(nil); try await wait { browser.sftpTabs[browser.activeID] == nil }
                    try require(tab.drain?.localResourcesEnded == true && tab.drain?.temporaryStoreRemoved == true)
                }
                await owner.closeAndDrain(); service = nil
            }
            stage = "forget"
            let storageWindow = SFTPConnectionStorageWindow(settings: settings, remembered: state, storage: storage)
            storageWindow.window?.title = "SFTP Connection Storage · generated review"; storageWindow.present(relativeTo: window)
            try await wait { !storageWindow.model.busy }
            try require(storageWindow.model.saved?.visibleHosts.count == 1 && storageWindow.model.saved?.credentials.count == 1 && storageWindow.model.catalogs.isEmpty)
            if let window = storageWindow.window { try await UIVerification.snapshot(window, to: location.appendingPathComponent("evidence/sftp-storage.png")) }
            storageWindow.model.forget(.all); try await wait { !storageWindow.model.busy }
            try require(storageWindow.model.saved?.hosts.isEmpty == true && storageWindow.model.saved?.servers.isEmpty == true
                && storageWindow.model.saved?.credentials.isEmpty == true && storageWindow.model.saved?.forgetAllPending == false)
            await storageWindow.closeAndDrain(); await state.drain()
            let empty = try await pool.inspect(); try require(empty.isEmpty)
            let adoptedEnded = await SFTPBrowserLifetimes.shared.closeAndDrain(), rawEnded = await SFTPWorkerSession.pauseAndDrainOwned()
            try require(adoptedEnded && rawEnded && ApplicationSMBActivity.gate.activeCount == 0)
            ticker?.cancel(); await ticker?.value; ticker = nil
            try require(maximumGap < 0.4)
            let report: [String: Any] = ["passed": true, "completedLifetimes": 3, "rows": rowsObserved,
                "actualSharedConnect": true, "coldSavedPassword": true, "changedKeySentNoAuthentication": true,
                "ordinaryPackagedWorker": ordinary, "normalStartupPrevented": true,
                "generatedKeychainEntriesCreated": 1, "generatedKeychainEntriesRemoved": 1,
                "allChildrenAndCatalogsDrained": true, "poolEmpty": true, "maximumMainActorGapSeconds": maximumGap,
                "passwordContentLogged": false, "personalEndpoints": 0, "physicalKeyboardAcceptance": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: location.appendingPathComponent("evidence/connect-live.json"), options: .withoutOverwriting)
            window.close(); retained = nil; NSApplication.shared.terminate(nil)
        } catch {
            ticker?.cancel(); await ticker?.value; await service?.closeAndDrain()
            _ = await SFTPBrowserLifetimes.shared.closeAndDrain(); _ = await SFTPWorkerSession.pauseAndDrainOwned()
            var credentialsCleaned = ownedState == nil
            if let ownedState {
                if let root, let snapshot = try? await ownedState.inspect() {
                    try? JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("evidence/failure-private-state.json"), options: .withoutOverwriting)
                }
                let result = await ownedState.forget(.all); credentialsCleaned = result.password == .complete
                await ownedState.drain()
            }
            if let root { let report: [String: Any] = ["passed": false, "stage": stage, "errorType": String(reflecting: type(of: error)), "maximumMainActorGapSeconds": maximumGap, "generatedCredentialCleanup": credentialsCleaned]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/connect-live.json"), options: .withoutOverwriting) }
            fputs("Generated SFTP Connect qualification failed\n", stderr); NSApplication.shared.terminate(nil)
        }
    }

    private final class EditorVaultCalls: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    @MainActor private final class EditorPromptContext {
        var round = 0, count = -1
    }
    @MainActor private final class EditorCompletion {
        var finished = false
    }
    private static func editorWait(_ predicate: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 55
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < limit); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func editorField(_ key: String) throws -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { throw Failure.check(#line) }
        return args[index + 1]
    }
    private static func editorRoot() throws -> URL {
        let location = URL(fileURLWithPath: try editorField("--analysis-source"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
        try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && location.resolvingSymlinksInPath() == location
            && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
            && marker?["packet"] as? String == "traverse-development-v1"
            && marker?["action"] as? String == "sftp-native-editor"
            && Bundle.main.bundleIdentifier == "local.macexplorer.development"
            && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app")
            && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil
            && ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == location.path)
        return location
    }
    private static func editorBrowser(_ location: URL) throws -> (BrowserWindowController, BrowserViewController) {
        let settings = BrowserSettings(persist: false)
        settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
        InterfacePresentation.shared.bind(settings)
        let controller = BrowserWindowController(settings: settings), browser = controller.browser
        let profile = location.appendingPathComponent("state/Profile")
        browser.recoverableFileOperations = browser.operationCoordinator.engine(at: profile.appendingPathComponent("operation-recovery"))
        browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        browser.tabs = [BrowserTab(location: .directory(location.appendingPathComponent("source/Empty")))]; browser.activeID = browser.tabs[0].id
        browser.loadLocation()
        guard let window = controller.window else { throw Failure.check(#line) }
        window.setContentSize(.init(width: 960, height: 650)); window.title = "Generated SFTP editor review"
        window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        retained = controller; return (controller, browser)
    }
    private static func answerEditorAuthentication(_ service: ApplicationSMBConnections, fingerprint: String,
                                                   context: EditorPromptContext,
                                                   completed: @escaping @MainActor () -> Bool) async throws {
        context.round = 0; context.count = -1
        try await editorWait { completed() || service.verificationSFTPTrust != nil }
        if completed() { return }
        guard let trust = service.verificationSFTPTrust else { throw Failure.check(#line) }
        try require(trust.model.review.fingerprint == fingerprint
            && (trust.model.review.kind == .first || trust.model.review.kind == .matching))
        try require(!trust.model.rememberKey)
        trust.model.proceed()
        for round in 1...8 {
            try await editorWait { completed() || service.verificationSFTPInteractive?.model.phase == .input
                && service.verificationSFTPInteractive?.model.challenge.round == UInt8(round) }
            if completed() { return }
            guard let prompt = service.verificationSFTPInteractive, let panel = prompt.window else { throw Failure.check(#line) }
            context.round = round; context.count = prompt.model.challenge.prompts.count
            try require(context.count <= 1)
            try await editorWait { SFTPInteractiveConnectionVerification.fieldsReady(prompt) }
            for index in prompt.model.challenge.prompts.indices {
                do { try SFTPInteractiveConnectionVerification.enterResponse("123456", at: index, in: prompt) }
                catch { throw Failure.check(#line) }
            }
            do { try SFTPInteractiveConnectionVerification.pressReturn(panel) }
            catch { throw Failure.check(#line) }
            try await editorWait { completed() || prompt.model.phase != .input
                || prompt.model.challenge.round != UInt8(round) }
        }
        try await editorWait { completed() || service.verificationSFTPInteractive?.model.phase == .input }
        if !completed() {
            context.round = Int(service.verificationSFTPInteractive?.model.challenge.round ?? 0)
            context.count = service.verificationSFTPInteractive?.model.challenge.prompts.count ?? -1
        }
        try require(completed())
    }
    private static func insertEditorText(_ document: RemoteTextDocumentController, _ text: String) {
        let view = document.window.surface.textView
        document.window.window?.makeFirstResponder(view)
        view.setSelectedRange(.init(location: view.string.utf16.count, length: 0))
        view.insertText(text, replacementRange: view.selectedRange()); view.breakUndoCoalescing()
    }
    private static func pressEditorSave(_ document: RemoteTextDocumentController) async throws {
        document.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await editorWait { document.window.window?.isKeyWindow == true && document.window.saveButton.isEnabled }
        document.window.saveButton.performClick(nil)
        // performClick/AXPress never makes a background window key. Prove the
        // native action entered before waiting for an asynchronous Save result.
        try require(document.state.activeCapture != nil)
    }
    private static func clickDiscard(in view: NSView) -> Bool {
        if let button = view as? NSButton, button.title == "Don't Save" { button.performClick(nil); return true }
        for child in view.subviews where clickDiscard(in: child) { return true }
        return false
    }
    private static func waitForExternalEditorChange(_ location: URL) async throws {
        let signal = location.appendingPathComponent("state/editor-source-changed.json")
        let valid = try await Task.detached { () throws -> Bool in
            let limit = ProcessInfo.processInfo.systemUptime + 55
            while ProcessInfo.processInfo.systemUptime < limit {
                if let data = try? Data(contentsOf: signal),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["generatedOnly"] as? Bool == true,
                   object["bytes"] as? Int == 19 { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }.value
        try require(valid)
    }
    private static func readEditorChoice(_ choice: SFTPInPlaceRecoveryChoice,
                                         before: String, edited: String) async throws {
        try require(choice.availableVersions == [.before, .edited])
        let first = try await choice.readPinnedVersion(.before)
        let firstMatches = first.contents.text == before
        let firstClosed = await first.closeAndDrain()
        try require(firstMatches && firstClosed)
        let second = try await choice.readPinnedVersion(.edited)
        let secondMatches = second.contents.text == edited
        let secondClosed = await second.closeAndDrain()
        try require(secondMatches && secondClosed)
    }
    private static func runPreparedEditor(cold: Bool) async {
        var root: URL?, service: ApplicationSMBConnections?, browserOwner: BrowserWindowController?, stage = "scope"
        var diagnostics: DiagnosticRecorder?
        var observedDocument: RemoteTextDocumentController?
        let calls = EditorVaultCalls()
        let promptContext = EditorPromptContext()
        let firstSaveOnly = cold && ProcessInfo.processInfo.arguments.contains("--prepared-editor-first-save-only")
        let reportName = firstSaveOnly ? "editor-cold-first-save.json" : cold ? "editor-cold.json" : "editor-native.json"
        do {
            let location = try editorRoot(); root = location
            let logger = DiagnosticRecorder(directory: location.appendingPathComponent("state/editor-diagnostics"),
                limits: try .init(bytes: 512 << 10, segmentBytes: 64 << 10), recording: true)
            diagnostics = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            try require(RemoteTextEditorFeature.ordinaryEnabled)
            RemoteTextEditorFeature.qualifying = true
            let (controller, browser) = try editorBrowser(location); browserOwner = controller
            let profile = location.appendingPathComponent("state/Profile")
            let owner = ApplicationSMBConnections(directory: profile,
                passwords: .refusingQualification { calls.increment() },
                sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true)
            service = owner
            if cold {
                stage = "cold-recovery"
                try require(owner.installPersistentSavedVersionsLoader())
                ApplicationRemoteSavedVersions.shared.bind(browser: browser)
                ApplicationRemoteSavedVersions.shared.showSavedVersions(nil)
                try await editorWait { ApplicationRemoteSavedVersions.shared.controller?.work == nil
                    && ApplicationRemoteSavedVersions.shared.controller?.choices.isEmpty == false }
                guard let versions = ApplicationRemoteSavedVersions.shared.controller?.choices else { throw Failure.check(#line) }
                let verifiedItems = versions.filter { $0.presentation.fileName == "Editor.txt" && $0.outcome == .verified }
                let verified = verifiedItems.first
                let refused = versions.first { $0.presentation.fileName == "Editor.txt" && $0.outcome == .notStarted }
                guard let verified else { throw Failure.check(#line) }
                try await readEditorChoice(verified, before: "before\n", edited: "before\nfirst edit\n")
                if firstSaveOnly {
                    // The interrupted parent stopped before the conflict step.
                    // Record only the real first Save; do not invent a refusal.
                    try require(verifiedItems.count == 1 && refused == nil)
                } else {
                    guard let refused else { throw Failure.check(#line) }
                    try await readEditorChoice(refused, before: "before\nfirst edit\n", edited: "before\nfirst edit\nsecond edit\n")
                }
                await ApplicationRemoteSavedVersions.shared.controller?.closeAndDrain()
                try require(calls.value == 0 && browser.sftpTabs[browser.activeID] == nil)
                try await exportEditorDiagnostics(logger, root: location,
                    name: firstSaveOnly ? "editor-cold-first-save-diagnostics.json" : "editor-cold-diagnostics.json")
                try reportEditor(location, name: reportName, values: ["passed": true,
                    "verifiedOutcome": true, "notStartedOutcome": !firstSaveOnly, "beforeAndEditedRead": true,
                    "firstSaveOnly": firstSaveOnly,
                    "networkConnections": 0, "keychainCalls": 0])
            } else {
                guard let port = UInt16(try editorField("--generated-port")), port > 0 else { throw Failure.check(#line) }
                let fingerprint = try editorField("--generated-fingerprint")
                stage = "connect"
                owner.present(in: browser)
                try await editorWait { owner.verificationWindow?.model.managing == false }
                guard let connect = owner.verificationWindow else { throw Failure.check(#line) }
                let model = connect.model
                model.connectionProtocol = .sftp; model.address = "sftp://127.0.0.1:\(port)/fixture"
                model.startingFolderField = "/fixture"; model.account = "generated"; model.name = "Generated editor"
                model.transferBehavior = .normal; model.sftpAuthentication = .serverPrompts
                model.rememberServer = false; model.rememberPassword = false; model.freshFolderUploads = false
                try require(model.freshUploads && !model.reviewsUploads && model.password.isEmpty)
                model.connect(); try await answerEditorAuthentication(owner, fingerprint: fingerprint,
                    context: promptContext, completed: { !model.busy })
                try await editorWait { !model.busy }
                try require(model.connected && !model.rememberingIncomplete && calls.value == 0)
                guard let tab = browser.sftpTabs[browser.activeID] else { throw Failure.check(#line) }
                try require(tab.session.allowsInPlaceEditing)
                try await editorWait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                let count = Int(tab.rows.cache.snapshot?.count ?? 0)
                guard let index = (0..<count).first(where: { tab.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == "Editor.txt" }) else { throw Failure.check(#line) }
                tab.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                controller.window?.makeFirstResponder(tab.rows.table)
                try require(browser.canEditTextInTraverse)
                stage = "first-save"
                try require(tab.rows.canOpenSelectedItem)
                tab.rows.openSelectedItem()
                try await editorWait { ApplicationRemoteTextEditors.shared.documentsForVerification.count == 1 }
                guard let document = ApplicationRemoteTextEditors.shared.documentsForVerification.first else { throw Failure.check(#line) }
                observedDocument = document
                try require(document.window.surface.textView.string == "before\n")
                insertEditorText(document, "first edit\n")
                try await editorWait { document.pendingEdit == nil && document.state.isDirty && document.window.saveButton.isEnabled }
                try await pressEditorSave(document)
                try await editorWait { document.work == nil && document.message == "Saved · SFTP" }
                try require(document.window.surface.textView.string == "before\nfirst edit\n" && !document.state.isDirty)
                stage = "first-save-diagnostics"
                await logger.flush()
                let events = try await logger.page(limit: 256).events
                guard let saved = events.first(where: { $0.context?.checkpoint == .remoteEditorSave
                    && $0.relatedTrace == document.id && $0.phase == .completed }) else { throw Failure.check(#line) }
                try require([DiagnosticPhase.preparing, .waiting, .admitted, .committing, .verifying, .completed].allSatisfy { phase in
                    events.contains { $0.trace == saved.trace && $0.relatedTrace == document.id && $0.phase == phase }
                })
                try reportEditor(location, name: "editor-first-save.json", values: ["passed": true, "saveVerified": true])
                stage = "wait-external-change"
                try await waitForExternalEditorChange(location)
                stage = "second-edit-ready"
                insertEditorText(document, "second edit\n")
                try await editorWait { document.pendingEdit == nil && document.state.isDirty && document.window.saveButton.isEnabled }
                stage = "changed-source-save-outcome"
                try await pressEditorSave(document)
                try await editorWait { document.work == nil && document.verificationSaveTerminal }
                try require(document.message.contains("Needs Review") && document.window.surface.textView.string == "before\nfirst edit\nsecond edit\n")
                stage = "close-disconnect"
                document.requestClose()
                try await editorWait { document.window.window?.attachedSheet != nil }
                guard let sheet = document.window.window?.attachedSheet, let contents = sheet.contentView else { throw Failure.check(#line) }
                try require(clickDiscard(in: contents))
                try await editorWait { document.closed && ApplicationRemoteTextEditors.shared.documentsForVerification.isEmpty }
                browser.disconnectSFTPConnection(nil)
                try await editorWait { browser.sftpTabs[browser.activeID] == nil }
                try require(tab.drain?.localResourcesEnded == true)
                await owner.closeAndDrain(); service = nil
                stage = "authenticated-unopened-discard"
                let second = ApplicationSMBConnections(directory: profile,
                    passwords: .refusingQualification { calls.increment() },
                    sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true)
                service = second; second.present(in: browser)
                try await editorWait { second.verificationWindow?.model.managing == false }
                guard let handler = second.verificationWindow?.model.sftpHandler else { throw Failure.check(#line) }
                let draft = try SFTPServerDraft(name: "Generated unopened editor", address:
                    SFTPConnectionAddress("sftp://127.0.0.1:\(port)/fixture"), account: "generated")
                let submission = SFTPConnectSubmission(draft: draft, password: nil,
                    rememberServer: false, rememberPassword: false, editingServer: nil,
                    freshUploads: true, freshFolderUploads: false, reviewsUploads: false,
                    transferPreference: .normal, authentication: .serverPrompts,
                    defaultDirectory: try .init(field: "/fixture", root: .server))
                let completion = EditorCompletion()
                let pending = Task { [completion] in
                    defer { completion.finished = true }
                    return try await handler(submission) { _ in }
                }
                try await answerEditorAuthentication(second, fingerprint: fingerprint,
                    context: promptContext, completed: { completion.finished })
                let unopened = try await pending.value
                try require(ApplicationRemoteTextEditors.shared.registeredConnectionCountForVerification == 1)
                let unopenedClosed = await unopened.discard()
                try require(unopenedClosed)
                try require(ApplicationRemoteTextEditors.shared.registeredConnectionCountForVerification == 0
                    && browser.sftpTabs[browser.activeID] == nil && calls.value == 0)
                await second.closeAndDrain(); service = nil
                let adoptedEnded = await SFTPBrowserLifetimes.shared.closeAndDrain()
                let rawEnded = await SFTPWorkerSession.pauseAndDrainOwned()
                try require(adoptedEnded && rawEnded && ApplicationSMBActivity.gate.activeCount == 0)
                try await exportEditorDiagnostics(logger, root: location, name: "editor-native-diagnostics.json")
                try reportEditor(location, name: "editor-native.json", values: ["passed": true,
                    "ordinaryConnect": true, "explicitEdit": true, "firstSaveVerified": true,
                    "changedSourceNeedsReview": true, "explicitCloseAndDisconnect": true,
                    "unopenedOutcomeDiscarded": true, "allChildrenDrained": true,
                    "peerAuthentications": 2, "keychainCalls": 0, "remoteSaveDiagnosticCorrelation": true])
            }
            await logger.closeAndDrain(); diagnostics = nil
            ApplicationDiagnostics.shared.configureForVerification(nil)
            browserOwner?.window?.close(); retained = nil; RemoteTextEditorFeature.qualifying = false
            NSApplication.shared.terminate(nil)
        } catch {
            // Capture before cleanup changes a connection's state. Keep this
            // bounded and input-free: no text, paths or authentication values.
            let documentState: [String: Any] = observedDocument.map { document in
                ["pendingEdit": document.pendingEdit != nil,
                 "saveWorkRunning": document.work != nil,
                 "captureActive": document.state.activeCapture != nil,
                 "keyWindow": document.window.window?.isKeyWindow == true,
                 "dirty": document.state.isDirty,
                 "saveButtonEnabled": document.window.saveButton.isEnabled,
                 "needsReview": document.needsReview,
                 "saveBoundary": document.verificationSaveBoundary,
                 "saveNotSubmitted": document.verificationSaveBoundary.hasPrefix("refused.")
                    || document.verificationSaveBoundary == "failedBeforeRemoteResult"]
            } ?? [:]
            let editorMutationWaiters = ApplicationLocalTextEditors.shared.waitingMutationsForVerification
            let operationOwnerActive = ApplicationOperationCoordinator.shared.activeOwner != nil
            await service?.closeAndDrain()
            if let diagnostics {
                if let root { try? await exportEditorDiagnostics(diagnostics, root: root,
                    name: cold ? "editor-cold-diagnostics.json" : "editor-native-diagnostics.json") }
                await diagnostics.closeAndDrain()
            }
            ApplicationDiagnostics.shared.configureForVerification(nil)
            let checkLine: UInt
            if case let Failure.check(line) = error { checkLine = line } else { checkLine = 0 }
            if let root { try? reportEditor(root, name: reportName,
                values: ["passed": false, "stage": stage, "checkLine": checkLine,
                    "promptRound": promptContext.round, "promptCount": promptContext.count,
                    "errorType": String(reflecting: type(of: error)), "keychainCalls": calls.value,
                    "editorMutationWaiters": editorMutationWaiters,
                    "operationOwnerActive": operationOwnerActive,
                    "documentState": documentState]) }
            browserOwner?.window?.close(); retained = nil; RemoteTextEditorFeature.qualifying = false
            fputs("Generated SFTP editor qualification failed\n", stderr); NSApplication.shared.terminate(nil)
        }
    }
    private static func exportEditorDiagnostics(_ recorder: DiagnosticRecorder, root: URL, name: String) async throws {
        await recorder.flush()
        guard case .saved = await recorder.export(to: root.appendingPathComponent("evidence/" + name), retainingAccess: ()) else {
            throw Failure.check(#line)
        }
    }
    private static func reportEditor(_ root: URL, name: String, values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("evidence/").appendingPathComponent(name), options: .withoutOverwriting)
    }
}
#endif
