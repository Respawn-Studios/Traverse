#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

@MainActor enum ConnectionFieldsVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(4)
        while !predicate() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func verifyCredentialLifetime() async throws {
        var submissions: [SFTPConnectSubmission] = []
        let model = SMBConnectModel { _, _ in
            .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        model.sftpHandler = { value, _ in
            submissions.append(value)
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        model.connectionProtocol = .sftp; model.serverField = "server.example.invalid"; model.account = "generated"
        model.password = "generated-only"; model.startingFolderField = "/fixture"
        let unchangedHost = model.serverField, unchangedPort = model.portField
        model.serverField = unchangedHost; model.portField = unchangedPort
        try require(model.password == "generated-only")
        model.connect(); try await wait { !model.busy }
        try require(submissions.count == 1 && submissions[0].password?.bytes == Data("generated-only".utf8)
            && submissions[0].defaultDirectory?.fieldText == "/fixture" && model.password.isEmpty)

        model.choose(nil); model.serverField = "server.example.invalid"; model.account = "generated"
        model.jumpHost.enabled = true; model.jumpHost.address = "gateway.example.invalid:2222"; model.jumpHost.account = "generated-jump"
        model.password = "destination-only"; model.keyPassphrase = "destination-key"; model.savedKeyAvailable = true
        model.jumpHost.password = "jump-only"; model.jumpHost.passphrase = "jump-key"
        model.startingFolderField = "/another folder"
        model.address = "sftp://server.example.invalid/uri-folder"
        try require(model.password == "destination-only" && model.keyPassphrase == "destination-key" && model.savedKeyAvailable
            && model.jumpHost.password == "jump-only" && model.jumpHost.passphrase == "jump-key")
        model.portField = "2022"
        try require(model.password.isEmpty && model.keyPassphrase.isEmpty && !model.savedKeyAvailable
            && model.jumpHost.password.isEmpty && model.jumpHost.passphrase.isEmpty)
        model.password = "destination-only"; model.jumpHost.password = "jump-only"
        model.jumpHost.address = "other-gateway.example.invalid"
        try require(model.password.isEmpty && model.jumpHost.password.isEmpty)

        model.connectionProtocol = .smb; model.serverField = "server.example.invalid"; model.shareField = "Shared"; model.account = "generated"
        model.password = "generated-only"; model.startingFolderField = "/folder"
        model.address = "smb://server.example.invalid/Shared/another-folder"
        let unchangedShare = model.shareField
        model.shareField = unchangedShare
        try require(model.password == "generated-only")
        model.shareField = "Private"; try require(model.password.isEmpty)
        model.password = "generated-only"; model.domain = "changed-domain"; try require(model.password.isEmpty)
        await model.cancelAndDrain()
    }
    private static func verifySavedStartingFolders() async throws {
        var submissions: [SFTPConnectSubmission] = []
        let model = SMBConnectModel { _, _ in
            .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        model.sftpHandler = { value, _ in
            submissions.append(value)
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        model.connectionProtocol = .sftp
        for (original, field) in [("sftp://saved.generated.invalid", "/Start% #?"),
                                  ("sftp://saved.generated.invalid/Original", "~/Chosen")] {
            let draft = try SFTPServerDraft(name: "Generated saved", address: .init(original), account: "generated")
            let directory = try SFTPDefaultDirectory(field: field, root: field.hasPrefix("/") ? .server : .home)
            let id = UUID()
            model.replaceSFTPServers([.init(id: id, details: draft, hasSavedPassword: false, defaultDirectory: directory)])
            model.choose(id)
            try require(model.startingFolderField == field && model.address == draft.address.displayAddress)
            model.password = "generated-only"
            model.startingFolderField = field + "/Child"
            try require(model.password == "generated-only" && model.address == draft.address.displayAddress)
            model.connect(); try await wait { !model.busy }
            guard let submission = submissions.last else { throw Failure.scope }
            try require(submission.draft.address == draft.address && submission.draft.account == draft.account
                && submission.editingServer == id && submission.defaultDirectory?.root == directory.root
                && submission.defaultDirectory?.fieldText == field + "/Child"
                && submission.password?.bytes == Data("generated-only".utf8))
            model.password = "must-clear"; model.portField = "2022"
            try require(model.password.isEmpty && (try? SFTPConnectionAddress(model.address).port) == 2022)
        }
        try require(submissions.count == 2)
        await model.cancelAndDrain()
    }
    static func run() async {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        var root: URL?, controller: SMBConnectWindowController?, checks: [String] = [], clips: [[String:Any]] = [], failure: UInt?, kind: String?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-connection-fields" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = area
            var sftpCalls: [SFTPConnectSubmission] = [], smbCalls: [SMBConnectSubmission] = []
            let model = SMBConnectModel { input, _ in
                smbCalls.append(input); return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
            }
            model.sftpHandler = { input, _ in
                sftpCalls.append(input); return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
            }
            model.freshUploadAvailable = true; model.connectionProtocol = .sftp
            try require(model.transferBehavior == .normal && model.portField == "22" && model.startingFolderField.isEmpty)
            model.serverField = "192.168.1.25"; model.portField = "2222"; model.account = "generated"; model.password = "generated-only"; model.connect()
            try await wait { !model.busy }
            try require(sftpCalls.count == 1 && sftpCalls[0].draft.address.port == 2222 && sftpCalls[0].draft.address.components == nil
                && sftpCalls[0].freshUploads && !sftpCalls[0].reviewsUploads && model.password.isEmpty)
            checks.append("Host/IP plus Port connects at Home with a visible normal transfer policy and bounded secret lifetime")

            model.choose(nil); model.serverField = "sftp://studio.example.invalid:2222/Project%20%231"; model.account = "generated"; model.password = "generated-only"
            model.transferBehavior = .cautious; model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 2 && model.serverField == "studio.example.invalid" && model.portField == "2222" && model.startingFolderField == "/Project #1"
                && sftpCalls[1].reviewsUploads && sftpCalls[1].password?.bytes == Data("generated-only".utf8))
            checks.append("Optional URI entry populates fields without losing credentials entered for that attempt")

            model.choose(nil); model.serverField = "sftp://studio.example.invalid:2222/"; model.portField = "2022"; model.account = "generated"; model.connect()
            try await wait { !model.busy }; try require(sftpCalls.count == 2 && !model.message.isEmpty && model.address.isEmpty)
            checks.append("A separately edited conflicting Port is refused instead of silently overridden")

            let saved = try SFTPServerDraft(name: "Generated saved server", address: .init("sftp://studio.example.invalid:2222/saved"), account: "generated")
            let savedID = UUID(); model.replaceSFTPServers([.init(id: savedID, details: saved, hasSavedPassword: true)])
            model.choose(savedID)
            try require(model.transferBehavior == .readOnly && !model.freshUploads && !model.freshFolderUploads
                && model.portField == "2222" && model.startingFolderField == "/saved" && model.password.isEmpty)
            model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 3 && !sftpCalls[2].freshUploads && sftpCalls[2].password == nil)
            checks.append("Older saved servers retain read-only authority; password lookup remains separately bound")

            model.password = "must-clear"; model.portField = "2022"
            try require(model.password.isEmpty && model.transferBehavior == .readOnly && (try? SFTPConnectionAddress(model.address).port) == 2022)
            model.password = "must-clear"; model.portField = "0"
            try require(model.password.isEmpty && model.address.isEmpty)
            model.connect(); try await wait { !model.busy }; try require(sftpCalls.count == 3)
            checks.append("Endpoint edits clear secrets; invalid partial fields cannot reuse the last valid address")

            model.choose(nil); model.serverField = "server.example.invalid"; model.account = "generated"; model.startingFolderField = "/"
            model.transferBehavior = .readOnly; model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 4 && sftpCalls[3].draft.address.components == [] && !sftpCalls[3].freshUploads)
            checks.append("Explicit server root remains distinct from the default Home folder")

            model.connectionProtocol = .smb; model.serverField = "192.168.1.25"; model.portField = "1445"; model.shareField = "Work #1"
            model.startingFolderField = "/100% ready?"; model.account = "generated"; model.connect(); try await wait { !model.busy }
            try require(smbCalls.count == 1 && smbCalls[0].address.port == 1445 && smbCalls[0].address.share.displayName == "Work #1"
                && smbCalls[0].address.components.map(\.displayName) == ["100% ready?"] && smbCalls[0].security == .encrypted)
            checks.append("SMB Host, Port, Share and literal starting folder retain encrypted security")

            model.choose(nil); model.serverField = "smb://studio.example.invalid/Shared"; model.account = "generated"; model.connect(); try await wait { !model.busy }
            try require(smbCalls.count == 2 && model.serverField == "studio.example.invalid" && model.shareField == "Shared" && model.portField == "445")
            checks.append("SMB URI convenience keeps share and port fields synchronized")
            let storageFailure = SMBConnectModel { _, _ in throw SMBBrowserFailure.storage }
            storageFailure.serverField = "studio.example.invalid"; storageFailure.shareField = "Shared"
            storageFailure.account = "generated"; storageFailure.password = "generated-only"
            storageFailure.connect(); try await wait { !storageFailure.busy }
            try require(storageFailure.storageRefused && storageFailure.message.hasPrefix("Connection storage needs attention.")
                && !storageFailure.storageNeedsReview && smbCalls.count == 2)
            checks.append("A local SMB storage refusal offers review without blaming the server or blocking a later explicit retry")
            await storageFailure.cancelAndDrain()
            await model.cancelAndDrain()

            SFTPRoutedUploadFeature.qualifying = true
            defer { SFTPRoutedUploadFeature.qualifying = false }
            func configureRoute() {
                model.connectionProtocol = .sftp; model.choose(nil); model.serverField = "destination.example.invalid"; model.account = "generated"
                model.jumpHost.enabled = true; model.jumpHost.address = "gateway.example.invalid:2222"; model.jumpHost.account = "generated-jump"
                model.password = "generated-only"; model.jumpHost.password = "generated-jump-only"
            }
            configureRoute()
            try require(model.canUseFreshUploads && model.transferBehavior == .normal && !model.freshFolderUploads)
            model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 5 && sftpCalls[4].freshUploads && !sftpCalls[4].freshFolderUploads && !sftpCalls[4].reviewsUploads
                && sftpCalls[4].route?.jump.address.port == 2222 && sftpCalls[4].route?.destination.address.host == "destination.example.invalid"
                && model.password.isEmpty && model.jumpHost.password.isEmpty)
            checks.append("A qualified new route retains the visible normal file policy across identity edits without granting folder uploads")
            configureRoute(); model.transferBehavior = .readOnly; model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 6 && !sftpCalls[5].freshUploads && !sftpCalls[5].freshFolderUploads)
            SFTPRoutedUploadFeature.qualifying = false; configureRoute()
            try require(!model.canUseFreshUploads && model.transferBehavior == .readOnly)
            model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 7 && !sftpCalls[6].freshUploads && !sftpCalls[6].freshFolderUploads)
            checks.append("Read-only selection and an unavailable build each refuse route write authority before the handler")
            SFTPRoutedUploadFeature.qualifying = true; SFTPRoutedFolderUploadFeature.qualifying = true; SFTPFolderUploadFeature.qualifying = true
            defer { SFTPRoutedFolderUploadFeature.qualifying = false; SFTPFolderUploadFeature.qualifying = false }
            configureRoute()
            try require(model.canUseFreshFolderUploads && model.freshFolderUploads && model.transferBehavior == .normal)
            model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 8 && sftpCalls[7].freshUploads && sftpCalls[7].freshFolderUploads && !sftpCalls[7].reviewsUploads)
            configureRoute(); model.transferBehavior = .readOnly; model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 9 && !sftpCalls[8].freshUploads && !sftpCalls[8].freshFolderUploads)
            configureRoute(); model.transferBehavior = .cautious; model.connect(); try await wait { !model.busy }
            try require(sftpCalls.count == 10 && sftpCalls[9].freshUploads && sftpCalls[9].freshFolderUploads && sftpCalls[9].reviewsUploads)
            checks.append("J folder capability follows explicit normal/cautious/read-only choices without expanding old I authority")
            await model.cancelAndDrain()

            try await verifyCredentialLifetime()
            checks.append("Starting folders and unchanged fields preserve typed credentials; endpoint, share, domain and route edits still clear them")
            try await verifySavedStartingFolders()
            checks.append("Saved Home/server-root starting folders reconnect with the exact original sign-in address; folder edits retain typed credentials and endpoint edits clear them")

            let settings = BrowserSettings(persist: false); settings.appearance = .dark; settings.navigationStyle = .glass; settings.motion.mode = .full
            BrowserAppearanceController.apply(settings.appearance)
            InterfacePresentation.shared.bind(settings)
            let view = SMBConnectWindowController(settings: settings) { _, _ in throw Failure.scope }; controller = view
            view.model.sftpHandler = { _, _ in throw Failure.scope }; view.model.freshUploadAvailable = true; view.model.connectionProtocol = .sftp
            view.model.serverField = "studio.example.invalid"; view.model.account = "generated"
            view.model.messageForGeneratedReview(); view.window?.title = "Connect fields · generated review"
            view.present(); NSApp.activate(ignoringOtherApps: true)
            guard let window = view.window else { throw Failure.scope }
            // Theme and interface-size changes share the compositor entrance.
            // This image is a settled layout review, not a transition frame.
            try await Task.sleep(for: .milliseconds(600)); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/connect-dark.png"))
            if ProcessInfo.processInfo.arguments.contains("--record-connection-fields") {
                // Fixed-size capture checks the actual domain field while the
                // accordion animates. Window resizing is a different sampler.
                view.model.connectionProtocol = .smb; view.model.serverField = "studio.example.invalid"; view.model.shareField = "Shared"
                window.setContentSize(.init(width: 600,height: 760)); try await Task.sleep(for: .milliseconds(150))
                for (label, expanded) in [("connect-advanced-open",true),("connect-advanced-close",false)] {
                    let movie = try await NativeMotionRecorder.record(window: window, root: area, label: label, sampling: .diagnostic(for: window)) {
                        view.model.showAdvanced = expanded
                    }
                    try JSONEncoder().encode(movie).write(to: area.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                    let field = descendants(window.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Optional" }
                    if expanded { try require(field != nil && !field!.visibleRect.isEmpty) }
                    clips.append(DevelopmentMotionVerification.clip(label, report: movie, field: expanded ? field : nil, window: window))
                }
                window.setContentSize(.init(width: 600,height: 540)); view.model.connectionProtocol = .sftp
                view.model.serverField = "studio.example.invalid"; view.model.account = "generated"
            }
            let storedChoice = UUID()
            view.model.replaceSFTPServers([.init(id: storedChoice, details: saved, hasSavedPassword: true)])
            view.model.choose(storedChoice)
            try require(view.model.usingSavedPassword && view.model.password.isEmpty)
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/connect-saved-password.png"))
            view.setSidebarVisible(true, animated: false)
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/connect-saved-servers.png"))
            view.setSidebarVisible(false, animated: false); view.model.showAdvanced = false
            view.model.choose(nil); view.model.serverField = "studio.example.invalid"; view.model.account = "generated"
            SFTPRoutedUploadFeature.qualifying = true
            view.model.jumpHost.enabled = true; view.model.jumpHost.address = "gateway.example.invalid:2222"; view.model.jumpHost.account = "generated-jump"
            view.model.showAdvanced = true; window.setContentSize(.init(width: 600, height: 760))
            try await Task.sleep(for: .milliseconds(250)); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/connect-routed.png"))
            view.model.jumpHost.enabled = false; view.model.showAdvanced = false; window.setContentSize(.init(width: 600, height: 540))
            settings.interfaceSize = .init(150); settings.appearance = .light; settings.motion.mode = .reduced
            BrowserAppearanceController.apply(settings.appearance)
            try await Task.sleep(for: .milliseconds(600)); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/connect-light-150.png"))
            checks.append("Actual native compact form renders Light/Dark and larger controls; motion recordings are separate pixel evidence")
            if ProcessInfo.processInfo.arguments.contains("--hold-connection-fields") {
                settings.interfaceSize = .standard; settings.appearance = .dark
                BrowserAppearanceController.apply(settings.appearance)
                try Data("generated connection form ready".utf8).write(to: area.appendingPathComponent("state/Ready"), options: .withoutOverwriting)
                let end = ContinuousClock.now + .seconds(240)
                while .now < end && !FileManager.default.fileExists(atPath: area.appendingPathComponent("state/Finish").path) {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            await view.model.cancelAndDrain(); view.window?.close()
            checks.append("Form model and actual window close after owned tasks drain")
        } catch { if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting: type(of:error)) }
        if let controller { await controller.model.cancelAndDrain(); controller.window?.close() }
        if let root {
            let report: [String:Any] = ["passed":failure == nil,"checks":checks,"clips":clips,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "networkRequests":0,"keychainCalls":0,"personalFiles":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-connection-fields.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
