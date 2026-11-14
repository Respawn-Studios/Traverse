#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SMBUserInterfaceVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-helper-identity")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSMBBrowserProtocolFixture") as? Bool == true,
            "Generated SMB UI scope differs")
        guard let workspace = browser.workspace, let window = browser.view.window else { throw UIVerification.Failure(message: "Generated SMB workspace missing") }
        browser.permitsBackgroundVerification = true
        browser.settings.keyboardProfile = .explorer; browser.settings.navigationStyle = .glass; browser.settings.glassFileContent = true
        window.setContentSize(NSSize(width: 900, height: 560)); window.title = "SMB browser · generated review"
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000)); window.orderFront(nil)
        let activity = FileActivityGate()
        let session = try await SMBBrowserSession.connectGenerated(bundleURL: Bundle.main.bundleURL, generatedCase: root,
            activity: activity, password: SMBPassword("unused-generated-ui-input"))
        let owner = SMBTabController(session: session, share: try SMBRemoteName("ExplorerQA"), title: "Generated Studio")
        browser.installSMBTab(owner); let tab = browser.activeID
        do {
            try await wait { owner.rows.cache.retainedCount == 3 && !owner.hasPendingPages }
            browser.updateMaterialSurfaces()
            try require(owner.root.displayHint == "Generated Studio · ExplorerQA", "Connection caption lost its server context")
            let pane = UUID(), layout = PaneLayout(paneID: pane)
            let replacement = PaneWorkspaceSnapshot(layout: layout, activePane: pane, panes: [
                .init(id: pane, tabs: .init(tabs: [.init(location: .init(kind: .computer))]), viewMode: "Details")])
            let profile = try WorkspaceLaunchProfile(name: "Generated live-connection guard", snapshot: replacement)
            var profileRefused = false
            do { try workspace.openLaunchProfile(profile) } catch { profileRefused = true }
            try require(!workspace.canOpenLaunchProfile && profileRefused && browser.smbTabs[tab] === owner,
                "Profile replacement silently closed a live connection")
            guard let header = owner.rows.table.headerView as? FileTableHeaderView else { throw UIVerification.Failure(message: "Remote header does not share the native browser material") }
            try require(header.usesGlass && !owner.rows.scroll.drawsBackground, "Remote Glass policy differs")
            browser.settings.navigationStyle = .solid; browser.updateMaterialSurfaces()
            try require(!header.usesGlass && owner.rows.scroll.drawsBackground, "Remote Solid policy differs")
            browser.settings.navigationStyle = .glass; browser.updateMaterialSurfaces()
            owner.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try require(browser.commandEnabled(#selector(BrowserViewController.openSelection(_:)))
                && !browser.commandEnabled(#selector(BrowserViewController.trashSelection(_:)))
                && browser.commandEnabled(#selector(BrowserViewController.selectAllBrowserFiles(_:))), "Remote selection or local-mutation boundary differs")
            browser.openSelection(nil)
            try await wait { owner.rows.cache.retainedCount == 2 && !owner.hasPendingPages }
            browser.goBack(nil)
            try await wait { owner.rows.cache.retainedCount == 3 && !owner.hasPendingPages }
            window.makeFirstResponder(owner.rows.table)
            let menu = BrowserMenus.menu(.go, target: browser)
            try require(menu.items.first(where: { $0.action == #selector(BrowserViewController.showSMBConnections(_:)) })?.keyEquivalent == "k",
                "Connect command is not in the shared shortcut registry")
            browser.showSMBConnections(nil)
            guard let form = ApplicationSMBConnections.shared.verificationWindow else { throw UIVerification.Failure(message: "Ordinary Connect routing missing") }
            try await wait { !form.model.managing }
            try require(form.model.address.isEmpty && !form.model.rememberServer && !form.model.rememberPassword, "First-use connection choices changed")
            await ApplicationSMBConnections.shared.closeAndDrain()
            var recordings: [NativeMotionRecorder.Report] = []
            if ProcessInfo.processInfo.arguments.contains("--record-smb-ui") {
                window.title = "SMB browser · generated review"
                window.setContentSize(NSSize(width: 900, height: 560))
                window.center(); window.makeKeyAndOrderFront(nil)
                recordings.append(try await NativeMotionRecorder.record(window: window, root: root, label: "remote-solid") {
                    browser.settings.navigationStyle = .solid; browser.updateMaterialSurfaces()
                })
                recordings.append(try await NativeMotionRecorder.record(window: window, root: root, label: "remote-glass") {
                    browser.settings.navigationStyle = .glass; browser.updateMaterialSurfaces()
                })
            }
            // Recording uses a compact window. Restore a two-pane-sized
            // canvas before exercising the ordinary minimum-size guard.
            window.setContentSize(NSSize(width: 1140, height: 760))
            workspace.view.layoutSubtreeIfNeeded()
            try require(browser.commandEnabled(#selector(BrowserViewController.disconnectSMBConnection(_:))), "Disconnect missing for live tab")
            var historyCalls = 0
            browser.smbClosedUploadNotices[tab] = .init(message: "Generated upload needs review.", showHistory: { [weak browser, weak window] settings, ownerWindow in
                if let browser, let window, settings === browser.settings && ownerWindow === window { historyCalls += 1 }
            })
            browser.disconnectSMBConnection(nil)
            try require(workspace.splitActive(at: .trailing), "Closing-connection pane split failed")
            let destination = workspace.activeBrowser; destination.permitsBackgroundVerification = true
            try require(workspace.moveTab(tab, from: browser, into: destination, before: nil), "Closing tab did not move with its owner")
            try await wait { owner.drain != nil && destination.smbTabs[tab] == nil }
            try require(owner.drain?.actualExit == true && owner.drain?.pipeDrained == true && owner.drain?.ownerReleased == true
                && activity.activeCount == 0 && destination.status.stringValue.contains("Generated upload needs review"), "Disconnect presentation or actual ownership did not follow the moved tab")
            let repeated = await owner.close().value
            try require(repeated.actualExit && repeated.ownerReleased, "Repeated close changed completed ownership")
            try require(browser.smbClosedUploadNotices[tab] == nil && destination.smbClosedUploadNotices[tab] != nil,
                "Closed Upload Outcomes ownership did not follow the moved tab")
            destination.showSMBUploadOutcomes(nil)
            try require(historyCalls == 1, "Moved Upload Outcomes used stale window or settings ownership")
            return ["passed": true, "ordinaryConnectEnabled": SMBConnectionFeature.ordinaryEnabled, "networkConnections": 0,
                "networkSecurityQualified": false, "protocolFixtureOnly": true, "keychainAccesses": 0, "personalCatalogs": 0,
                "glassSolidSharedHeader": true, "folderAndBack": true, "serverContextCaption": true,
                "connectShortcutAndDefaults": true, "disconnectMovesAndDrains": true,
                "liveConnectionProfileReplacementRefused": true,
                "recordings": try recordings.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        } catch {
            _ = await owner.close().value; await ApplicationSMBConnections.shared.closeAndDrain(); throw error
        }
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Generated SMB UI did not settle")
    }
}
#endif
