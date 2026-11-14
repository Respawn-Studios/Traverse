#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Real metadata-only shared Connect on an owned four-session loopback peer.
@MainActor enum WorkspaceNetworkConnectionVerification {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var number = 0
        func add() { lock.withLock { number += 1 } }
        var count: Int { lock.withLock { number } }
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { try WorkspaceNetworkVerification.require(value, line: line) }
    private static func wait(_ predicate: () -> Bool) async throws { try await WorkspaceNetworkVerification.wait(predicate) }
    static func run() async {
        var root: URL?, checkpoint = "scope", controller: BrowserWindowController?, service: ApplicationSMBConnections?
        let calls = Calls()
        do {
            let admitted = try WorkspaceNetworkVerification.scope(); root = admitted
            let mode = try WorkspaceNetworkVerification.argument("--workspace-mode")
            try require(["seed","resume"].contains(mode))
            guard let port = UInt16(try WorkspaceNetworkVerification.argument("--generated-port")) else { throw WorkspaceNetworkVerification.Failure.scope }
            let fingerprint = try WorkspaceNetworkVerification.argument("--generated-fingerprint")
            WorkspaceNetworkFeature.qualifying = true
            let settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.restoresSession = false; settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let workspace = owner.workspace, profile = admitted.appendingPathComponent("state/Connection")
            let templates = LaunchProfileStore(directory: profile.appendingPathComponent("Layouts"))
            let memory = WorkspaceProfileStore(directory: profile.appendingPathComponent("Workspaces"))
            let last = BrowserWorkspacePersistence(stateDirectory: profile.appendingPathComponent("LastSession"))
            let update = UpdateWorkspaceResumeStore(directory: profile.appendingPathComponent("Update"))
            guard let window = owner.window else { throw WorkspaceNetworkVerification.Failure.scope }
            window.title = "Saved network connection · generated review"; window.setContentSize(.init(width: 1000, height: 700))
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            workspace.sessionReady = true
            let connections = ApplicationSMBConnections(directory: profile,
                passwords: .refusingQualification { calls.add() }, sftpPasswords: .refusingQualification { calls.add() }, sftpEnabled: true)
            service = connections
            var browser = workspace.activeBrowser
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.permitsBackgroundVerification = true
            browser.readVolumesForVerification = { [] }
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("Names"), settings: settings)
            var results: [String: Any] = ["passed": false, "keychainCalls": 0]
            if mode == "seed" {
                browser.tabs = [BrowserTab(location: .directory(admitted.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id
                browser.loadLocation()
                checkpoint = "initial-shared-connect"
                connections.present(in: browser)
                try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                form.model.connectionProtocol = .sftp; form.model.address = "sftp://127.0.0.1:\(port)"
                form.model.account = "generated"; form.model.name = "Generated workspace"
                form.model.password = "ephemeral qualification password"; form.model.rememberServer = true; form.model.rememberPassword = false
                form.model.connect()
                try await review(connections, fingerprint: fingerprint, matching: false)
                try await wait { !form.model.busy }
                try require(form.model.connected && form.model.password.isEmpty && calls.count == 0)
                guard let tab = browser.sftpTabs[browser.activeID] else { throw WorkspaceNetworkVerification.Failure.scope }
                try await wait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                let beforeGeneration = tab.session.latest.generation
                let total = Int(tab.rows.cache.snapshot?.count ?? 0)
                guard let folder = (0..<total).first(where: { tab.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == "Folder" }) else { throw WorkspaceNetworkVerification.Failure.scope }
                tab.rows.table.selectRowIndexes(.init(integer: folder), byExtendingSelection: false)
                browser.openSelection(nil)
                try await wait { tab.session.latest.generation != beforeGeneration && tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                try require(browser.tabs[browser.activeIndex].connectionBookmark?.components == [Data("Folder".utf8)] && !tab.session.allowsFreshUploads)
                checkpoint = "save-and-close"
                let snapshot = try workspace.captureLaunchProfile()
                let saved = try await templates.edit(expected: nil) { try $0.add(name: "Generated connected layout", snapshot: snapshot) }
                let template = saved.library.profiles[0]
                _ = try await memory.enable(template, initial: snapshot)
                last.setEnabled(true); last.record(snapshot); try require(await last.flush() == nil)
                try await update.save(.init(id: UUID(), sourceBuild: 13, targetBuild: 14, created: Date(), workspace: snapshot,
                    frame: UpdateWorkspaceResume.coordinates(window.frame), tools: []))
                let close = await tab.close().value
                try require(close.localResourcesEnded && close.temporaryStoreRemoved == true && saved.library.version == 2)
                results = ["passed": true, "keychainCalls": calls.count, "actualSharedConnect": true, "savedFolder": true,
                    "savedLayoutVersion": 2, "actualWorkerExit": close.actualExit, "pipeEOF": close.ipcEOF,
                    "catalogRemoved": close.temporaryStoreRemoved == true]
            } else {
                checkpoint = "cold-passive-restore"
                let saved = try await templates.load(); guard let template = saved.library.profiles.first else { throw WorkspaceNetworkVerification.Failure.scope }
                let working = try await memory.load()
                try require(working.memory.record(for: template.id)?.snapshot == template.snapshot)
                let previous = await last.restore(enabled: true, legacyPane: UUID(), viewMode: "Details")
                let updater = try await update.read(build: 14)
                try require(previous == template.snapshot && updater?.workspace == template.snapshot)
                try WorkspaceNetworkVerification.configure(workspace, root: admitted, snapshot: template.snapshot)
                browser = workspace.activeBrowser
                try require(browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty && browser.isSFTPLocation && calls.count == 0)
                guard let bookmark = browser.tabs[browser.activeIndex].connectionBookmark else { throw WorkspaceNetworkVerification.Failure.scope }
                let originalID = browser.activeID, count = browser.tabs.count
                browser.reconnectPresenterForVerification = { [weak browser] target in
                    if let browser { connections.present(in: browser, reconnect: target) }
                }
                checkpoint = "actual-button-reconnect"
                guard let button = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                button.performClick(nil)
                try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(form.model.selectedServer == bookmark.serverID && !form.model.workspaceBlocked && !form.model.freshUploads
                    && form.model.password.isEmpty && !form.model.workspaceNotice.isEmpty)
                form.model.password = "ephemeral qualification password"; form.model.connect()
                try await review(connections, fingerprint: fingerprint, matching: true)
                try await wait { !form.model.busy }
                guard let tab = browser.sftpTabs[browser.activeID] else { throw WorkspaceNetworkVerification.Failure.scope }
                try await wait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                guard case .sftp(let connectedLocation) = browser.location else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(form.model.connected && browser.activeID == originalID && browser.tabs.count == count
                    && browser.tabs[browser.activeIndex].connectionBookmark == bookmark
                    && tab.references.pathUTF8(for: connectedLocation) == Data("./Folder".utf8)
                    && !tab.session.allowsFreshUploads && calls.count == 0)
                let close = await tab.close().value; try require(close.localResourcesEnded && close.temporaryStoreRemoved == true)
                try await wait { browser.sftpTabs[originalID] == nil }
                checkpoint = "close-target-during-trust"
                guard let staleButton = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                staleButton.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let staleForm = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                staleForm.model.password = "ephemeral qualification password"; staleForm.model.connect()
                try await wait { connections.verificationSFTPTrust != nil || !staleForm.model.busy }
                guard let staleTrust = connections.verificationSFTPTrust else { throw WorkspaceNetworkVerification.Failure.scope }
                browser.closeTab(id: originalID); try require(!browser.tabs.contains { $0.id == originalID })
                staleTrust.model.proceed(); try await wait { !staleForm.model.busy }
                try require(!staleForm.model.connected && browser.sftpTabs.isEmpty && !browser.isRemoteLocation
                    && staleForm.model.message == WorkspaceReconnectFailure.stale.message)
                checkpoint = "cancel-host-review"
                let cancelled = try bookmark.disconnectedTab(); browser.tabs.append(cancelled); browser.selectTab(cancelled.id)
                guard let cancelButton = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                cancelButton.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let cancelForm = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                cancelForm.model.password = "ephemeral qualification password"; cancelForm.model.connect()
                try await wait { connections.verificationSFTPTrust != nil || !cancelForm.model.busy }
                guard let cancelTrust = connections.verificationSFTPTrust else { throw WorkspaceNetworkVerification.Failure.scope }
                cancelTrust.model.cancel(); try await wait { !cancelForm.model.busy }
                try require(!cancelForm.model.connected && browser.tabs[browser.activeIndex].connectionBookmark == bookmark && browser.sftpTabs.isEmpty)
                checkpoint = "forgotten-server-before-connect"
                guard let remembered = connections.verificationSFTPRemembered else { throw WorkspaceNetworkVerification.Failure.scope }
                let forgotten = await remembered.forget(.server(bookmark.serverID, removePassword: false))
                try require(forgotten.server == .complete)
                guard let missingButton = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                missingButton.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let missingForm = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(missingForm.model.workspaceBlocked); missingForm.model.connect()
                try require(!missingForm.model.busy && !missingForm.model.connected && browser.sftpTabs.isEmpty && calls.count == 0)
                results = ["passed": true, "keychainCalls": calls.count, "startupConnections": 0, "coldTemplateAndWorkingRestore": true,
                    "lastSessionAndUpdateRestore": true, "actualNativeButton": true, "sameTabRestored": true,
                    "exactRemoteFolderRestored": true, "uploadAuthorityNotRestored": true,
                    "closedTargetDrainedWithoutNewTab": true, "hostCancelPreservesReference": true,
                    "forgottenServerRefusedBeforeConnection": true]
            }
            checkpoint = "all-owned-drain"
            browser.reconnectPresenterForVerification = nil
            let liveEnded = await SFTPBrowserLifetimes.shared.closeAndDrain(); try require(liveEnded)
            await connections.closeAndDrain(); service = nil
            try require(calls.count == 0)
            for pane in workspace.browsers.values { pane.suspendBrowser() }
            window.orderOut(nil); controller = nil; WorkspaceNetworkFeature.qualifying = false
            try WorkspaceNetworkVerification.write(results, root: admitted, name: "connection-" + mode)
            NSApplication.shared.terminate(nil)
        } catch {
            let ended = await SFTPBrowserLifetimes.shared.closeAndDrain()
            await service?.closeAndDrain(); controller?.window?.orderOut(nil); WorkspaceNetworkFeature.qualifying = false
            if let root { try? WorkspaceNetworkVerification.write(["passed": false, "checkpoint": checkpoint,
                "error": String(describing: error), "localResourcesEnded": ended], root: root, name: "connection-failure") }
            NSApplication.shared.terminate(nil)
        }
    }
    private static func review(_ service: ApplicationSMBConnections, fingerprint: String, matching: Bool) async throws {
        try await wait { service.verificationSFTPTrust != nil || service.verificationWindow?.model.busy == false }
        guard let trust = service.verificationSFTPTrust else { throw WorkspaceNetworkVerification.Failure.scope }
        try require(trust.model.review.fingerprint == fingerprint && trust.model.review.kind == (matching ? .matching : .first))
        if !matching { trust.model.rememberKey = true }; trust.model.proceed()
    }
}

#endif
