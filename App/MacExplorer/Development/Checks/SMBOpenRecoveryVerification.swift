#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

@MainActor enum SMBOpenRecoveryVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ value: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(12)
        while !value() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func button(_ view: NSView, _ id: String) -> NSButton? {
        if view.accessibilityIdentifier() == id { return view as? NSButton }
        return view.subviews.lazy.compactMap { button($0, id) }.first
    }
    private static func password() async throws -> SMBPassword {
        let data = try await Task.detached {
            var bytes = Data()
            while bytes.count <= 64 {
                var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 2000) > 0 else { throw Failure.scope }
                var byte: UInt8 = 0; guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { throw Failure.scope }
                if byte == 10 { return bytes }; bytes.append(byte)
            }
            throw Failure.scope
        }.value
        guard data.count == 64, data.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), let text = String(data: data, encoding: .ascii) else { throw Failure.scope }
        return try SMBPassword(text)
    }
    static func run() async {
        var root: URL?, host: NSWindow?, browser: BrowserViewController?, tab: SMBTabController?, session: SMBBrowserSession?
        var checks: [String] = [], failure: UInt?, kind: String?, drain: SMBBrowserDrainResult?, poolEmpty: Bool?
        var temporaryStorage: SMBTemporaryStorage?, failureReason: String?
        var nonDirectoryOutcome: String?
        var receivedError: Int64?, commandCounts: [UInt64]?
        var clips: [[String:Any]] = []
        var stage = "scope", failureCode: Int64?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            let args = ProcessInfo.processInfo.arguments
            guard let portIndex = args.firstIndex(of: "--generated-port"), portIndex + 1 < args.count,
                  let port = UInt16(args[portIndex + 1]), port > 1024,
                  let modeIndex = args.firstIndex(of: "--recovery-scenario"), modeIndex + 1 < args.count else { throw Failure.scope }
            let mode = args[modeIndex + 1]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "smb-directory-recovery-native" && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && ["preflight", "recovery", "share-denied", "bad-password"].contains(mode))
            root = area
            stage = "storage"
            // The common pool reserves its supported maximum per live writer;
            // this is admission accounting, not an allocation of source bytes.
            let storage = try SMBTemporaryStorage(directory: area.appendingPathComponent("cache/smb"), sessionByteLimit: 8 << 20,
                poolByteLimit: SMBTemporaryStorage.maximumSessionBytes)
            temporaryStorage = storage
            let address = try SMBConnectionAddress(server: "127.0.0.1", port: port, share: mode == "share-denied" ? "DeniedQA" : "ExplorerQA", startingFolder: "/Denied")
            let request = try SMBServerDraft(name: "Generated share", address: address, account: "nobody", domain: "", security: .encrypted)
            stage = "helper-identity"
            let endpoint = try await SMBPreparedConnection.prepareValidated(address, bundleURL: Bundle.main.bundleURL, activity: ApplicationFileActivity.gate)
            if mode == "preflight" {
                stage = "catalog-reservation"
                let reserved = try await SMBTemporaryCatalogPool(storage: storage).reserve()
                try require(await reserved.finishWithoutWorker())
                poolEmpty = try await SMBTemporaryCatalogPool(storage: storage).inspect().isEmpty
                try require(poolEmpty == true && ApplicationFileActivity.gate.activeCount == 0)
                checks.append("The sealed helper and exact temporary catalog reserve/drain pass without a credential or network connection")
                if args.contains("--recording-scope-preflight") {
                    stage = "recording-scope"
                    let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
                    settings.reviewsRecoveryAtStartup = false
                    let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
                    let window = NSWindow(contentRect: .init(x: 160,y: 150,width: 1000,height: 640),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
                    host = window; window.isReleasedWhenClosed = false; window.contentViewController = owner
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    window.title = "SMB folder recovery · generated review"; owner.updateNavigation()
                    try require(!window.title.contains("generated review"))
                    do { try NativeMotionRecorder.validateScope(window: window, root: area, label: "smb-scope-preflight"); throw Failure.scope }
                    catch NativeMotionRecorder.Failure.scope { }
                    window.title = "SMB folder recovery · generated review"
                    let movie = try await NativeMotionRecorder.record(window: window,root: area,label: "smb-scope-preflight",sampling: .diagnostic(for: window)) { owner.updateNavigation() }
                    try JSONEncoder().encode(movie).write(to: area.appendingPathComponent("evidence/smb-scope-preflight.json"),options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip("smb-scope-preflight",report: movie,field: nil,window: window))
                    checks.append("Actual browser navigation replaces the generated title; the recorder refuses it until the owned review title is restored")
                }
                stage = "finished"
                throw PreflightComplete.done
            }
            stage = "credential-input"
            let secret = try await password()
            stage = "connect"
            do {
                session = try await SMBBrowserSession.connectPrepared(bundleURL: Bundle.main.bundleURL, request: request, endpoint: endpoint,
                    storage: storage, activity: ApplicationFileActivity.gate, password: secret)
            } catch {
                guard mode != "recovery" else { throw error }
                let expected: SMBBrowserFailure = mode == "share-denied" ? .denied : .authentication
                try require(error as? SMBBrowserFailure == expected); receivedError = DiagnosticErrors.project(error).code
                checks.append("Authentication or share denial stays terminal rather than becoming a recoverable folder refusal")
            }
            if mode == "recovery" {
                stage = "native-folder-recovery"
                guard let session else { throw Failure.scope }
                let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
                settings.reviewsRecoveryAtStartup = false; settings.navigationStyle = .glass; settings.glassFileContent = true
                settings.appearance = args.contains("--large-interface") ? .light : .dark
                settings.interfaceSize = .init(args.contains("--large-interface") ? 150 : 100)
                InterfacePresentation.shared.bind(settings)
                let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
                let window = NSWindow(contentRect: .init(x: 160, y: 150, width: 1000, height: 640), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
                host = window; window.isReleasedWhenClosed = false; window.contentViewController = owner; window.title = "SMB folder recovery · generated review"
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                let controller = SMBTabController(session: session, share: address.share, title: "Generated share"); tab = controller
                owner.installSMBTab(controller, initialComponents: address.components)
                try await wait { controller.rows.recoveryVisibleForVerification && session.latest.directoryRejection == .denied }
                try require(session.latest.failure == nil && session.latest.security == .encrypted && session.latest.idle
                    && controller.selectedItemObservation == nil && controller.rows.cache.snapshot == nil)
                checks.append("An initial denied folder preserves one encrypted native session with no old row or Properties authority")
                let home = button(controller.rows, "smb-recovery-home"), up = button(controller.rows, "smb-recovery-up"), retry = button(controller.rows, "smb-recovery-retry")
                try require(home != nil && up != nil && retry != nil && !home!.isHidden && !up!.isHidden)
                let denied = session.latest.snapshot?.readID; retry?.performClick(nil)
                try await wait { controller.rows.recoveryVisibleForVerification && session.latest.snapshot?.readID != denied }
                try require(session.latest.directoryRejection == .denied && session.latest.failure == nil)
                checks.append("Retry creates a fresh exact request generation on the same connection")
                up?.performClick(nil)
                try await wait { controller.rows.cache.retainedCount == 2 && !controller.hasPendingPages }
                try require(owner.location == .smb(controller.root) && session.latest.directoryRejection == nil)
                checks.append("Up explicitly opens the failed initial folder’s share parent without reconnecting")
                owner.updateSMBBreadcrumbs()
                try require(owner.pathControl.logicalItems.first?.image?.size == NSSize(width: 16, height: 16)
                    && owner.pathControl.logicalItems.first?.image?.isTemplate == true)
                let missing = try controller.directoryLocation(components: [SMBRemoteName("Missing")]); owner.navigate(to: .smb(missing))
                try await wait { controller.rows.recoveryVisibleForVerification && session.latest.directoryRejection == .missing }
                try require(session.latest.failure == nil && owner.connectedLocationSnapshot.count == 1)
                let label = args.contains("--large-interface") ? "smb-recovery-light-150" : "smb-recovery-dark-100"
                // Ordinary navigation updates the title. Restore the generated
                // review tag before the recorder's existing exact-window gate.
                stage = "recording"; window.title = "SMB folder recovery · generated review"
                let movie = try await NativeMotionRecorder.record(window: window, root: area, label: label, sampling: .diagnostic(for: window)) { home?.performClick(nil) }
                try JSONEncoder().encode(movie).write(to: area.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip(label, report: movie, field: nil, window: window))
                stage = "native-folder-recovery"
                try await wait { controller.rows.cache.retainedCount == 2 && !controller.hasPendingPages }
                checks.append("A missing folder offers Share Root while the live connection remains reachable")
                let allowed = try controller.directoryLocation(components: [SMBRemoteName("Allowed")]); owner.navigate(to: .smb(allowed))
                try await wait { controller.rows.cache.retainedCount == 1 && !controller.hasPendingPages }
                controller.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try require(controller.selectedItemObservation?.copyName == "Empty.txt")
                checks.append("A successful later folder restores cached Properties authority without a body request")
                let stable = owner.location; home?.performClick(nil); up?.performClick(nil); retry?.performClick(nil)
                try require(owner.location == stable && session.latest.directoryRejection == nil)
                let notFolder = try controller.directoryLocation(components: [SMBRemoteName("Allowed"),SMBRemoteName("Empty.txt")]); owner.navigate(to: .smb(notFolder))
                try await wait { session.latest.failure != nil || controller.rows.recoveryVisibleForVerification }
                let terminalNonDirectory = session.latest.failure != nil
                if let rejection = session.latest.directoryRejection {
                    try require(session.latest.failure == nil && controller.rows.recoveryVisibleForVerification)
                    nonDirectoryOutcome = "rejected-" + rejection.rawValue
                    home?.performClick(nil); try await wait { controller.rows.cache.retainedCount == 2 && !controller.hasPendingPages }
                } else {
                    // A successful CREATE can return non-directory attributes.
                    // The pinned reader then hides its CLOSE outcome behind
                    // InvalidData; the existing policy correctly stays terminal.
                    try require(session.latest.failure == .invalidOutput && !controller.rows.recoveryVisibleForVerification
                        && controller.selectedItemObservation == nil)
                    nonDirectoryOutcome = "terminal-invalid-output"
                }
                checks.append("Hidden recovery controls cannot navigate; a failed non-directory open may recover, but unproven handle closure remains terminal")
                drain = await controller.close().value; commandCounts = session.commandCounts
                try require(drain?.actualExit == true && drain?.pipeDrained == true && drain?.socketAndCatalogDrained == true
                    && drain?.ownerReleased == true && drain?.temporaryCatalogRemoved == true && drain?.forcedContainment == false)
                try require(commandCounts?.count == 19 && commandCounts?[5] == (terminalNonDirectory ? 7 : 8)
                    && [7,8,9,10,11,15,16,17,18].allSatisfy { commandCounts?[$0] == 0 })
                checks.append("The packaged worker actually exits, drains its socket and removes only its exact temporary catalog")
            } else { try require(session == nil && receivedError != nil) }
            poolEmpty = try await SMBTemporaryCatalogPool(storage: storage).inspect().isEmpty
            try require(poolEmpty == true && ApplicationFileActivity.gate.activeCount == 0)
            checks.append("The runtime catalog pool and activity admission drain after the exact connection")
            stage = "finished"
        } catch PreflightComplete.done {
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting: type(of: error))
            failureCode = DiagnosticErrors.project(error).code
            if let value = error as? SMBBrowserFailure { failureReason = value.rawValue }
            else if let value = error as? SMBTemporaryStorageFailure { failureReason = String(describing: value) }
            else if let value = error as? NativeMotionRecorder.Failure { failureReason = value.rawValue }
        }
        if let tab { let ended = await tab.close().value; if drain == nil { drain = ended } }
        else if let session { let ended = await session.close(); if drain == nil { drain = ended } }
        commandCounts = commandCounts ?? session?.commandCounts
        if let temporaryStorage { poolEmpty = try? await SMBTemporaryCatalogPool(storage: temporaryStorage).inspect().isEmpty }
        browser?.suspendBrowser(); host?.close()
        if let root {
            var report: [String:Any] = ["passed":failure == nil,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "checks":checks,"stage":stage,"failureCode":failureCode as Any? ?? NSNull(),"failureReason":failureReason as Any? ?? NSNull(),
                "poolEmpty":poolEmpty as Any? ?? NSNull(),"activityDrained":ApplicationFileActivity.gate.activeCount == 0,
                "actualExit":drain?.actualExit as Any? ?? NSNull(),"socketAndCatalogDrained":drain?.socketAndCatalogDrained as Any? ?? NSNull(),
                "pipeDrained":drain?.pipeDrained as Any? ?? NSNull(),"contained":drain?.forcedContainment as Any? ?? NSNull(),
                "commandCounts":commandCounts as Any? ?? NSNull(),"terminalErrorCode":receivedError as Any? ?? NSNull(),"bodyRequests":0,"keychainCalls":0,"clips":clips]
            report["nonDirectoryOutcome"] = nonDirectoryOutcome as Any? ?? NSNull()
            report["lastSessionFailure"] = session?.latest.failure?.rawValue as Any? ?? NSNull()
            report["lastDirectoryRejection"] = session?.latest.directoryRejection?.rawValue as Any? ?? NSNull()
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-smb-open-recovery.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private enum PreflightComplete: Error { case done }
}
#endif
