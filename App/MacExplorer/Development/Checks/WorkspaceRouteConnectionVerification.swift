#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum WorkspaceRouteConnectionVerification {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    @MainActor private final class Reviews {
        var fingerprints = Set<String>(), rounds = Set<String>(), windows: [UUID: Int] = [:]
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { try WorkspaceNetworkVerification.require(value, line: line) }
    private static func wait(_ predicate: () -> Bool) async throws { try await WorkspaceNetworkVerification.wait(predicate) }
    static func run() async {
        var root: URL?, checkpoint = "scope", controller: BrowserWindowController?, service: ApplicationSMBConnections?, driver: Task<Void, Error>?
        let calls = Calls()
        do {
            let admitted = try WorkspaceNetworkVerification.scope(); root = admitted
            let phase = try WorkspaceNetworkVerification.argument("--generated-phase")
            guard ["seed","reconnect"].contains(phase),
                  let port = UInt16(try WorkspaceNetworkVerification.argument("--generated-port")),
                  let targetPort = UInt16(try WorkspaceNetworkVerification.argument("--generated-target-port")) else { throw WorkspaceNetworkVerification.Failure.scope }
            let fingerprints: Set<String> = [try WorkspaceNetworkVerification.argument("--generated-fingerprint"),
                try WorkspaceNetworkVerification.argument("--generated-target-fingerprint")]
            let factor = ProcessInfo.processInfo.arguments.contains("--generated-both-factors")
            WorkspaceNetworkFeature.qualifying = true
            let settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.restoresSession = false; settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let workspace = owner.workspace, profile = admitted.appendingPathComponent("state/Route")
            let layouts = LaunchProfileStore(directory: profile.appendingPathComponent("Layouts"))
            guard let window = owner.window else { throw WorkspaceNetworkVerification.Failure.scope }
            window.title = "Saved jump layout · generated review"; window.setContentSize(.init(width: 1000, height: 700))
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); workspace.sessionReady = true
            let connections = ApplicationSMBConnections(directory: profile, passwords: .refusingQualification { calls.add() },
                sftpPasswords: .refusingQualification { calls.add() }, sftpEnabled: true); service = connections
            var browser = workspace.activeBrowser
            if phase == "seed" {
                browser.permitsBackgroundVerification = true; browser.folderAccess = FolderAccessController(stateDirectory: nil)
                browser.readVolumesForVerification = { [] }
                browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("Names"), settings: settings)
                browser.tabs = [BrowserTab(location: .directory(admitted.appendingPathComponent("source")))]; browser.activeID = browser.tabs[0].id
                browser.loadLocation(); connections.present(in: browser)
                try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                form.model.connectionProtocol = .sftp; form.model.address = "sftp://private.internal.test:\(targetPort)/generated"
                form.model.account = "generated"; form.model.name = "Generated jump layout"
                form.model.jumpHost.enabled = true; form.model.jumpHost.address = "sftp://127.0.0.1:\(port)"; form.model.jumpHost.account = "generated"
                let key = admitted.appendingPathComponent("source/client-key")
                form.model.useSSHKey(key); form.model.jumpHost.method = .keyFile
                form.model.jumpHost.selectedKey = try SFTPSelectedPrivateKey(file: key); form.model.jumpHost.keyName = "Generated key"
                form.model.rememberServer = true; form.model.rememberKeyAccess = true; form.model.jumpHost.rememberKey = true
                form.model.extraServerPrompts = factor; form.model.jumpHost.extraPrompts = factor
            } else {
                checkpoint = "cold-route-layout"
                let saved = try await layouts.load(); guard let layout = saved.library.profiles.first else { throw WorkspaceNetworkVerification.Failure.scope }
                try WorkspaceNetworkVerification.configure(workspace, root: admitted, snapshot: layout.snapshot); browser = workspace.activeBrowser
                try require(browser.sftpTabs.isEmpty && browser.tabs[browser.activeIndex].connectionBookmark?.kind == .sftpRoute && calls.count == 0)
                browser.reconnectPresenterForVerification = { [weak browser] target in if let browser { connections.present(in: browser, reconnect: target) } }
                guard let button = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                button.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(!form.model.workspaceBlocked && form.model.jumpHost.enabled && form.model.savedKeyAvailable
                    && form.model.jumpHost.savedKeyAvailable && form.model.selectedKey == nil && form.model.jumpHost.selectedKey == nil
                    && !form.model.freshUploads)
            }
            guard let form = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
            let tabBefore = browser.activeID, countBefore = browser.tabs.count
            form.model.keyPassphrase = "generated-only-not-a-secret"; form.model.jumpHost.passphrase = "generated-only-not-a-secret"
            let observed = Reviews()
            checkpoint = "actual-two-role-sign-in"; form.model.connect()
            driver = Task { @MainActor in
                while form.model.busy {
                    if let trust = connections.verificationSFTPTrust, !trust.model.busy, trust.model.finished == nil,
                       observed.fingerprints.insert(trust.model.review.fingerprint).inserted {
                        try require(fingerprints.contains(trust.model.review.fingerprint)
                            && trust.model.review.kind == (phase == "seed" ? .first : .matching))
                        trust.model.proceed()
                    }
                    if let prompt = connections.verificationSFTPInteractive, prompt.model.phase == .input,
                       SFTPInteractiveConnectionVerification.fieldsReady(prompt), !observed.rounds.contains(prompt.model.challenge.id), let panel = prompt.window {
                        let challenge = prompt.model.challenge
                        if let number = observed.windows[challenge.session] { try require(number == panel.windowNumber) }
                        else { observed.windows[challenge.session] = panel.windowNumber }
                        observed.rounds.insert(challenge.id)
                        for (index, field) in challenge.prompts.enumerated() {
                            try SFTPInteractiveConnectionVerification.enterResponse(challenge.round == 2 ? "654321" : field.echo ? "generated" : "123456", at: index, in: prompt)
                        }
                        try SFTPInteractiveConnectionVerification.pressReturn(panel)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await wait { !form.model.busy }; try await driver?.value; driver = nil
            try require(form.model.connected && observed.fingerprints == fingerprints && observed.rounds.count == (factor ? 4 : 0)
                && observed.windows.count == (factor ? 2 : 0) && form.model.keyPassphrase.isEmpty && form.model.jumpHost.passphrase.isEmpty)
            guard let tab = browser.sftpTabs[browser.activeID] else { throw WorkspaceNetworkVerification.Failure.scope }
            try await wait { tab.rows.cache.snapshot?.state == .complete && !tab.hasPendingPages }
            guard case .sftp(let location) = browser.location,
                  let bookmark = browser.tabs[browser.activeIndex].connectionBookmark else { throw WorkspaceNetworkVerification.Failure.scope }
            try require(bookmark.kind == .sftpRoute && bookmark.components == [Data("generated".utf8)] && !bookmark.relativeToHome
                && tab.references.pathUTF8(for: location) == Data("/generated".utf8) && calls.count == 0
                && !tab.session.allowsRequestedDownloads && !tab.session.allowsFreshUploads && tab.downloads == nil && tab.uploads == nil
                && tab.rows.onDownload == nil && tab.rows.onDownloadToPane == nil
                && tab.rows.table.menu?.items.filter { $0.title.hasPrefix("Download") }.allSatisfy(\.isHidden) == true)
            if phase == "seed" {
                let snapshot = try workspace.captureLaunchProfile()
                _ = try await layouts.edit(expected: nil) { try $0.add(name: "Generated route workspace", snapshot: snapshot) }
            } else { try require(browser.activeID == tabBefore && browser.tabs.count == countBefore) }
            let ended = await tab.close().value; try require(ended.localResourcesEnded && ended.temporaryStoreRemoved == true)
            try await wait { browser.sftpTabs.isEmpty }
            if phase == "reconnect" {
                checkpoint = "forgotten-route-refusal"
                guard let remembered = connections.verificationSFTPRemembered else { throw WorkspaceNetworkVerification.Failure.scope }
                let removed = await remembered.forget(.route(bookmark.serverID, removePasswords: false)); try require(removed.server == .complete)
                guard let button = WorkspaceNetworkVerification.connectButton(in: browser) else { throw WorkspaceNetworkVerification.Failure.scope }
                button.performClick(nil); try await wait { connections.verificationWindow?.model.managing == false }
                guard let missing = connections.verificationWindow else { throw WorkspaceNetworkVerification.Failure.scope }
                try require(missing.model.workspaceBlocked && missing.model.sftpServers.isEmpty); missing.model.connect()
                try require(!missing.model.busy && !missing.model.connected && browser.sftpTabs.isEmpty)
            }
            browser.reconnectPresenterForVerification = nil
            try require(await SFTPBrowserLifetimes.shared.closeAndDrain()); await connections.closeAndDrain(); service = nil
            for pane in workspace.browsers.values { pane.suspendBrowser() }
            window.orderOut(nil); controller = nil; WorkspaceNetworkFeature.qualifying = false
            try WorkspaceNetworkVerification.write(["passed": true, "phase": phase, "actualSharedConnect": true,
                "sameTabAndExactFolder": phase == "reconnect", "startupConnections": 0, "keychainCalls": calls.count,
                "visibleNativeReviews": true, "nativeTypedRounds": observed.rounds.count, "actualPromptWindows": observed.windows.count,
                "ordinaryFeatureFlags": form.model.routeFeaturesAvailable && form.model.profileFeaturesAvailable && form.model.serverPromptsAvailable,
                "unsupportedDownloadHidden": true, "coldReferencesAuthenticated": phase == "reconnect",
                "routeForgotten": phase == "reconnect", "actualExit": ended.actualExit, "ipcEOF": ended.ipcEOF,
                "catalogRemoved": ended.temporaryStoreRemoved == true], root: admitted, name: "native-workspace-route-"+phase)
            NSApplication.shared.terminate(nil)
        } catch {
            driver?.cancel(); _ = await driver?.result; let ended = await SFTPBrowserLifetimes.shared.closeAndDrain()
            await service?.closeAndDrain(); controller?.window?.orderOut(nil); WorkspaceNetworkFeature.qualifying = false
            if let root { try? WorkspaceNetworkVerification.write(["passed": false, "checkpoint": checkpoint, "error": String(describing: error),
                "localResourcesEnded": ended], root: root, name: "native-workspace-route-failure") }
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
