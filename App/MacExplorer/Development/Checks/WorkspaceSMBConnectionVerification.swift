#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum WorkspaceSMBConnectionVerification {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { try WorkspaceNetworkVerification.require(value, line: line) }
    private static func wait(_ predicate: () -> Bool) async throws { try await WorkspaceNetworkVerification.wait(predicate) }
    static func run() async {
        var root: URL?, checkpoint = "scope", controller: BrowserWindowController?, service: ApplicationSMBConnections?
        let calls = Calls()
        do {
            let admitted = try WorkspaceNetworkVerification.scope(); root = admitted
            let mode = try WorkspaceNetworkVerification.argument("--workspace-mode")
            guard ["smb-seed","smb-resume"].contains(mode), let port = UInt16(try WorkspaceNetworkVerification.argument("--generated-port")), port > 0 else {
                throw WorkspaceNetworkVerification.Failure.scope
            }
            let input = try await Task.detached { try FileHandle.standardInput.read(upToCount: 129) ?? Data() }.value
            guard let text = String(data: input, encoding: .utf8), text.hasSuffix("\n"), text.utf8.count == 65,
                  text.dropLast().utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw WorkspaceNetworkVerification.Failure.scope }
            let password = String(text.dropLast())
            WorkspaceNetworkFeature.qualifying = true
            let settings = BrowserSettings(persist: false)
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            settings.restoresSession = false; settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let workspace = owner.workspace, profile = admitted.appendingPathComponent("state/SMB")
            let templates = LaunchProfileStore(directory: profile.appendingPathComponent("Layouts"))
            guard let window = owner.window else { throw WorkspaceNetworkVerification.Failure.scope }
            window.title = "SMB saved layout · generated review"; window.setContentSize(.init(width: 980, height: 680)); window.center()
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); workspace.sessionReady = true
            let connections = ApplicationSMBConnections(directory: profile, passwords: .refusingQualification { calls.add() },
                sftpPasswords: .refusingQualification { calls.add() }, sftpEnabled: false); service = connections
            var browser = workspace.activeBrowser
            browser.permitsBackgroundVerification = true; browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.readVolumesForVerification = { [] }
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("Names"), settings: settings)
            var results: [String: Any]
            if mode == "smb-seed" {
                browser.tabs = [BrowserTab(location: .directory(admitted.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id
                browser.loadLocation(); connections.present(in: browser)
                try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                form.model.address = "smb://127.0.0.1:\(port)/ExplorerQA"; form.model.account = "nobody"; form.model.name = "Generated SMB layout"
                form.model.password = password; form.model.rememberServer = true; form.model.rememberPassword = false
                checkpoint = "initial-authenticated-connect"; form.model.connect(); try await wait { !form.model.busy }
                try require(form.model.connected && form.model.password.isEmpty && calls.count == 0)
                guard let tab = browser.smbTabs[browser.activeID] else { throw WorkspaceNetworkVerification.Failure.scope }
                try await wait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                let count = Int(tab.rows.cache.snapshot?.count ?? 0)
                guard let index = (0..<count).first(where: { tab.rows.cache.entry(at: Int64($0))?.name.displayName == "Folder" }) else { throw WorkspaceNetworkVerification.Failure.scope }
                let prior = tab.rows.cache.snapshot?.readID
                tab.rows.table.selectRowIndexes(.init(integer: index), byExtendingSelection: false); browser.openSelection(nil)
                try await wait { tab.rows.cache.snapshot?.state == .complete && tab.rows.cache.snapshot?.readID != prior && !tab.hasPendingPages }
                try require(browser.tabs[browser.activeIndex].connectionBookmark?.components == [try SMBRemoteName("Folder").wireUTF16]
                    && tab.session.latest.security == .encrypted)
                let snapshot = try workspace.captureLaunchProfile()
                _ = try await templates.edit(expected: nil) { try $0.add(name: "Generated SMB workspace", snapshot: snapshot) }
                let ended = await tab.close().value
                try require(ended.ownerReleased && ended.actualExit && ended.pipeDrained && ended.temporaryCatalogRemoved == true)
                results = ["passed": true, "keychainCalls": calls.count, "encryptedSMB": true, "actualSharedForm": true,
                    "exactSavedFolder": true, "actualWorkerExit": true, "catalogRemoved": true]
            } else {
                checkpoint = "passive-cold-layout"
                let saved = try await templates.load(); guard let template = saved.library.profiles.first else { throw WorkspaceNetworkVerification.Failure.scope }
                try WorkspaceNetworkVerification.configure(workspace, root: admitted, snapshot: template.snapshot); browser = workspace.activeBrowser
                guard let bookmark = browser.tabs[browser.activeIndex].connectionBookmark else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(bookmark.kind == .smbServer && browser.smbTabs.isEmpty && calls.count == 0)
                let tabID = browser.activeID, count = browser.tabs.count
                browser.reconnectPresenterForVerification = { [weak browser] target in if let browser { connections.present(in: browser, reconnect: target) } }
                checkpoint = "native-in-place-reconnect"
                guard let button = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                button.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(form.model.connectionProtocol == .smb && form.model.selectedServer == bookmark.serverID && form.model.security == .encrypted
                    && !form.model.workspaceBlocked && form.model.password.isEmpty)
                form.model.password = password; form.model.connect(); try await wait { !form.model.busy }
                guard let tab = browser.smbTabs[browser.activeID] else { throw WorkspaceNetworkVerification.Failure.scope }
                try await wait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
                guard case .smb(let location) = browser.location else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(form.model.connected && browser.activeID == tabID && browser.tabs.count == count
                    && tab.references.resolve(location) == [try SMBRemoteName("Folder")] && tab.session.latest.security == .encrypted)
                let ended = await tab.close().value
                try require(ended.actualExit && ended.pipeDrained && ended.ownerReleased && ended.temporaryCatalogRemoved == true)
                try await wait { browser.smbTabs[tabID] == nil }
                checkpoint = "security-substitution-refusal"
                guard let changed = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                changed.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let changedForm = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                changedForm.model.security = .signedCompatibility; changedForm.model.password = password
                changedForm.model.connect(); try await wait { !changedForm.model.busy }
                try require(!changedForm.model.connected && changedForm.model.message == WorkspaceReconnectFailure.changed.message && browser.smbTabs.isEmpty)
                changedForm.model.security = .encrypted
                checkpoint = "actual-forget-and-missing-refusal"
                changedForm.model.onForgetServer?(bookmark.serverID)
                try await wait { changedForm.window?.attachedSheet != nil }
                guard let sheet = changedForm.window?.attachedSheet,
                      let confirm = WorkspaceNetworkVerification.descendants(sheet.contentView ?? NSView()).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == "Forget Server" }) else { throw WorkspaceNetworkVerification.Failure.scope }
                confirm.performClick(nil)
                try await wait { !changedForm.model.managing && changedForm.model.servers.isEmpty }
                guard let missing = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                missing.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let missingForm = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(missingForm.model.workspaceBlocked); missingForm.model.connect()
                try require(!missingForm.model.busy && !missingForm.model.connected && calls.count == 0)
                results = ["passed": true, "keychainCalls": calls.count, "startupConnections": 0, "sameTabRestored": true,
                    "exactFolderRestored": true, "encryptedSMB": true, "securityChangeRefusedBeforeWorker": true,
                    "actualForgetConfirmation": true, "forgottenServerRefusedBeforeWorker": true]
            }
            checkpoint = "drain"
            browser.reconnectPresenterForVerification = nil
            try require(await SMBBrowserLifetimes.shared.closeAndDrain())
            await connections.closeAndDrain(); service = nil; try require(calls.count == 0 && ApplicationSMBActivity.gate.activeCount == 0)
            for pane in workspace.browsers.values { pane.suspendBrowser() }
            window.orderOut(nil); controller = nil; WorkspaceNetworkFeature.qualifying = false
            try WorkspaceNetworkVerification.write(results, root: admitted, name: "connection-"+mode); NSApplication.shared.terminate(nil)
        } catch {
            let ended = await SMBBrowserLifetimes.shared.closeAndDrain(); await service?.closeAndDrain()
            controller?.window?.orderOut(nil); WorkspaceNetworkFeature.qualifying = false
            if let root { try? WorkspaceNetworkVerification.write(["passed": false, "checkpoint": checkpoint,
                "error": String(describing: error), "localResourcesEnded": ended], root: root, name: "smb-connection-failure") }
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
