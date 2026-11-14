#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Isolated private layout/storage/native controls. No network or OS backend.
@MainActor enum WorkspaceNetworkVerification {
    enum Failure: Error { case scope, check(UInt), injected }
    static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func argument(_ key: String) throws -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index+1) else { throw Failure.scope }; return args[index+1]
    }
    static func scope() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "workspace-native"
            && Bundle.main.bundleIdentifier == "local.macexplorer.development"
            && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
        return root
    }
    static func sample(root: URL) throws -> PaneWorkspaceSnapshot {
        let first = UUID(), second = UUID()
        var layout = PaneLayout(paneID: first); try layout.split(first, inserting: second, at: .trailing)
        let local = BrowserTab(location: .directory(root.appendingPathComponent("source/Local")))
        let direct = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: UUID(), binding: Data(repeating: 4, count: 32),
            title: "Studio · Artwork", components: [Data("Artwork".utf8)], relativeToHome: true).disconnectedTab()
        let share = try WorkspaceConnectionBookmark(kind: .smbServer, serverID: UUID(), binding: Data(repeating: 6, count: 32),
            title: "Archive · Reports", components: [try SMBRemoteName("Reports").wireUTF16]).disconnectedTab()
        let route = try WorkspaceConnectionBookmark(kind: .sftpRoute, serverID: UUID(), binding: Data(repeating: 8, count: 32),
            title: "Studio via gateway", components: [Data("References".utf8)]).disconnectedTab()
        return .init(layout: layout, activePane: second, panes: [
            .init(id: first, tabs: try .captureLaunchTemplate([local, share], activeID: local.id), viewMode: "Details"),
            .init(id: second, tabs: try .captureLaunchTemplate([direct, route], activeID: direct.id), viewMode: "Details")])
    }
    static func configure(_ workspace: BrowserWorkspaceController, root: URL, snapshot: PaneWorkspaceSnapshot) throws {
        workspace.sessionReady = true; try workspace.applyRestoredSnapshot(snapshot)
        for browser in workspace.browsers.values {
            browser.permitsBackgroundVerification = true; browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.readVolumesForVerification = { [] }
            browser.privateNames = ApplicationPrivateNames(directory: root.appendingPathComponent("state/Names"), settings: browser.settings)
            browser.loadLocation()
        }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func connectButton(in browser: BrowserViewController) -> NSButton? {
        descendants(browser.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "workspace-connect-saved" && !$0.isHiddenOrHasHiddenAncestor }
    }
    static func run() async {
        var root: URL?, checkpoint = "scope", controller: BrowserWindowController?
        do {
            let admitted = try scope(); root = admitted
            let mode = try argument("--workspace-mode")
            try require(["offline","crash-stage","crash-published","cold-stage","cold-published"].contains(mode))
            if mode != "offline" {
                let report = try await crashControl(root: admitted, mode: mode)
                try write(report, root: admitted, name: mode); NSApplication.shared.terminate(nil); return
            }
            WorkspaceNetworkFeature.qualifying = false
            try require(WorkspaceNetworkFeature.available)
            let snapshot = try sample(root: admitted)
            checkpoint = "durable-layout-controls"
            let storage = try await storageControls(root: admitted, snapshot: snapshot)
            let settings = BrowserSettings(persist: false)
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false; settings.autoRefreshFolders = false
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            guard let window = owner.window else { throw Failure.scope }
            window.title = "Network workspace · generated review"; window.setContentSize(.init(width: 1220, height: 800))
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let workspace = owner.workspace
            checkpoint = "actual-disconnected-layout"
            try configure(workspace, root: admitted, snapshot: snapshot)
            try await wait { workspace.browsers.values.allSatisfy { !$0.isLoading } }
            let browser = workspace.activeBrowser, originalID = browser.activeID
            try require(browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty && browser.location.isRemote && browser.status.stringValue.contains("Not connected"))
            for selector in [#selector(BrowserViewController.copyFileURLs(_:)), #selector(BrowserViewController.pasteFileURLs(_:)),
                #selector(BrowserViewController.trashSelection(_:)), #selector(BrowserViewController.showProperties(_:))] {
                try require(!browser.commandEnabled(selector))
            }
            guard let target = WorkspaceReconnectTarget(browser: browser), let button = connectButton(in: browser) else { throw Failure.scope }
            var clicks = 0; browser.reconnectPresenterForVerification = { received in clicks += 1; precondition(received.bookmark == target.bookmark) }
            button.performClick(nil); try require(clicks == 1 && target.isCurrent)
            let directChoice = try SFTPServerDraft(name: "Generated", address: .init("sftp://generated.example.test"), account: "generated")
            let form = SMBConnectModel { _, _ in throw Failure.scope }
            form.selectWorkspaceLocation(target.bookmark)
            try require(form.workspaceBlocked && !form.workspaceNotice.isEmpty && form.password.isEmpty)
            let missing = SFTPConnectSubmission(draft: directChoice, password: nil, rememberServer: false, rememberPassword: false,
                editingServer: target.bookmark.serverID, authentication: .password(nil))
            do { try target.validate(missing, snapshot: nil); throw Failure.check(#line) }
            catch is WorkspaceReconnectFailure { }
            checkpoint = "duplicate-move-stale"
            let clone = ClosedBrowserTab(browser.tabs[browser.activeIndex]).restored()
            try require(clone.connectionBookmark == target.bookmark && clone.location != browser.location)
            browser.tabs.append(clone); browser.selectTab(clone.id)
            try require(!target.isCurrent && browser.sftpTabs.isEmpty)
            browser.selectTab(originalID)
            guard let moved = WorkspaceReconnectTarget(browser: browser), let peer = workspace.browsers.values.first(where: { $0 !== browser }) else { throw Failure.scope }
            let count = browser.tabs.count
            try require(workspace.moveTab(originalID, from: browser, into: peer, before: nil))
            try require(!moved.isCurrent && browser.tabs.count == count-1 && peer.tabs.contains { $0.id == originalID && $0.connectionBookmark == target.bookmark })
            let captured = try workspace.captureLaunchProfile()
            try require(captured.version == 2 && captured.panes.flatMap { $0.tabs.tabs }.filter { $0.location.kind == .connection }.count == 4)
            checkpoint = "native-layout"
            try await Task.sleep(for: .milliseconds(350)); window.contentView?.layoutSubtreeIfNeeded()
            try await UIVerification.snapshot(window, to: admitted.appendingPathComponent("evidence/workspace-native.png"))
            for pane in workspace.browsers.values {
                pane.suspendBrowser(); pane.reconnectPresenterForVerification = nil
            }
            window.orderOut(nil); controller = nil; WorkspaceNetworkFeature.qualifying = false
            try write(["passed": true, "checks": storage, "actualNativeButton": true, "disconnectedTabCount": 4,
                "freshDuplicateIdentity": true, "movedTargetRejected": true, "localCommandsRefused": true,
                "networkRequests": 0, "keychainCalls": 0, "fileBodyReads": 0], root: admitted, name: mode)
            NSApplication.shared.terminate(nil)
        } catch {
            controller?.window?.orderOut(nil); WorkspaceNetworkFeature.qualifying = false
            if let root { try? write(["passed": false, "checkpoint": checkpoint, "error": String(describing: error)], root: root, name: "failure") }
            NSApplication.shared.terminate(nil)
        }
    }
    private static func storageControls(root: URL, snapshot: PaneWorkspaceSnapshot) async throws -> [String] {
        let area = root.appendingPathComponent("state/Layouts"), store = LaunchProfileStore(directory: root.appendingPathComponent("state/Layouts"))
        let absent = try await store.load(); try require(!absent.exists && !FileManager().fileExists(atPath: area.path))
        let saved = try await store.edit(expected: nil) { try $0.add(name: "Generated network", snapshot: snapshot) }
        try require(saved.library.version == 2 && saved.library.profiles.first?.snapshot == snapshot)
        let file = area.appendingPathComponent("launch-profiles-v1.json"), before = try Data(contentsOf: file)
        await store.setCheckpointForVerification { if $0 == .staged { throw Failure.injected } }
        do { _ = try await store.edit(expected: saved.revision) { try $0.rename(saved.library.profiles[0].id, to: "Not committed") }; throw Failure.check(#line) }
        catch Failure.injected { }
        await store.setCheckpointForVerification(nil)
        try require(try Data(contentsOf: file) == before)
        let cold = try await LaunchProfileStore(directory: area).load(); try require(cold.library == saved.library)
        do { _ = try await store.edit(expected: nil) { try $0.remove(saved.library.profiles[0].id) }; throw Failure.check(#line) }
        catch WorkspaceLaunchProfiles.Failure.stale { }
        let memory = WorkspaceProfileStore(directory: root.appendingPathComponent("state/Remembered")), profile = saved.library.profiles[0]
        let enabled = try await memory.enable(profile, initial: snapshot), session = try await memory.begin(profile)
        try require(session.record.snapshot == snapshot)
        try await memory.disable(profile.id, expectedConsent: enabled.consent, ownedBy: session.token)
        try require(try await memory.load().memory.records.isEmpty)
        try require(await memory.heldSessionsForVerification() == 0); await memory.drain()
        let passive = BrowserWorkspacePersistence(stateDirectory: root.appendingPathComponent("state/LastSession"))
        passive.setEnabled(true); passive.record(snapshot); try require(await passive.flush() == nil)
        let read = await BrowserWorkspacePersistence(stateDirectory: root.appendingPathComponent("state/LastSession"))
            .restore(enabled: true, legacyPane: UUID(), viewMode: "Details")
        try require(read == snapshot)
        var future = try JSONSerialization.jsonObject(with: before) as! [String: Any]; future["version"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: future), futureArea = root.appendingPathComponent("state/Future")
        try FileManager().createDirectory(at: futureArea, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let futureFile = futureArea.appendingPathComponent("launch-profiles-v1.json"); try bytes.write(to: futureFile, options: .withoutOverwriting)
        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: futureFile.path)
        let futureStore = LaunchProfileStore(directory: futureArea)
        do { _ = try await futureStore.load(); throw Failure.check(#line) } catch WorkspaceLaunchProfiles.Failure.invalidDocument { }
        do { _ = try await futureStore.edit(expected: nil) { try $0.add(name: "Refused", snapshot: snapshot) }; throw Failure.check(#line) }
        catch WorkspaceLaunchProfiles.Failure.invalidDocument { }
        try require(try Data(contentsOf: futureFile) == bytes)
        let removed = try await store.edit(expected: saved.revision) { try $0.remove(profile.id) }
        try require(removed.library.profiles.isEmpty && removed.library.version == 2)
        return ["Passive empty reads create no file", "Explicit network save and cold read retain exact references",
            "Failed prepublication edit and stale writer preserve original", "Working reference Forget releases its lease without reconnecting",
            "Last-session restores descriptions only", "Unknown versions refuse reads/edits without replacement", "Explicit layout removal keeps version2"]
    }
    private static func crashControl(root: URL, mode: String) async throws -> [String: Any] {
        let suffix = mode.hasSuffix("published") ? "published" : "stage"
        let area = root.appendingPathComponent("state/Crash-" + suffix), store = LaunchProfileStore(directory: area)
        if mode.hasPrefix("crash-") {
            let snapshot = try sample(root: root), saved = try await store.edit(expected: nil) { try $0.add(name: "Before", snapshot: snapshot) }
            await store.setCheckpointForVerification { boundary in
                if boundary == (suffix == "stage" ? .staged : .published) { _exit(suffix == "stage" ? 91 : 92) }
            }
            _ = try await store.edit(expected: saved.revision) { try $0.add(name: "After", snapshot: snapshot) }
            throw Failure.check(#line)
        }
        let read = try await store.load()
        try require(read.library.version == 2 && read.library.profiles.map(\.name) == (suffix == "stage" ? ["Before"] : ["Before", "After"]))
        return ["passed": true, "actualColdRead": true, "profileCount": read.library.profiles.count,
            "passiveReadOnly": true, "networkRequests": 0, "keychainCalls": 0]
    }
    static func write(_ report: [String: Any], root: URL, name: String) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/" + name + ".json"), options: .withoutOverwriting)
    }
}
#endif
