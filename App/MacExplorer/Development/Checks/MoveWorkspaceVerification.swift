#if DEBUG
import AppKit
import ExplorerCore
import FileMemory
import FileOperations

@MainActor enum MoveWorkspaceVerification {
    static func run(root: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-move-continuity", isDirectory: true)
        try UIVerification.require(root.deletingLastPathComponent() == expected && UUID(uuidString: root.lastPathComponent) != nil
            && root.resolvingSymlinksInPath() == root && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Move/workspace review requires its admitted generated packet")
        let settings = browser.settings
        settings.newTabDestination = .currentFolder // This fixture exercises folder loading and pane transfers.
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.showsHiddenFiles = true
        browser.permitsBackgroundVerification = true
        guard let workspace = browser.workspace, let window = browser.view.window else {
            throw UIVerification.Failure(message: "Review workspace is missing")
        }
        window.title = "Mac Explorer · B07.4 generated workspace review"
        window.setContentSize(NSSize(width: 1200, height: 820))
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        var checks: [String] = []
        try UIVerification.require(workspace.paneHosts.values.allSatisfy { !$0.showsFocusOutline }, "Single-pane outline remained")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen") { window.makeKeyAndOrderFront(nil) }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("native-single.png"))
        let firstID = browser.activeID
        browser.newTab(nil)
        try UIVerification.require(browser.overlay.isHidden,
            "A new tab briefly exposes the full Loading folder overlay before any slow-load threshold")
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        let newID = browser.activeID
        try UIVerification.require(newID != firstID && browser.tabs.count == 2, "New tab did not appear")
        // Hold only presentation state after the real generated listing drains:
        // long reads still announce progress, while errors bypass the delay.
        let entries = browser.displayedEntries
        browser.displayedEntries = []; browser.isLoading = true
        browser.beginFolderLoadingFeedback(); browser.refreshStatus()
        try UIVerification.require(browser.overlay.isHidden, "Loading announcement was not delayed")
        try await wait { !browser.overlay.isHidden }
        try UIVerification.require(browser.overlayTitle.stringValue == "Loading folder…", "Long load lost its progress announcement")
        browser.beginFolderLoadingFeedback(); browser.loadError = "Generated access error"; browser.refreshStatus()
        try UIVerification.require(!browser.overlay.isHidden && browser.overlayTitle.stringValue == "Unable to load this folder",
            "Access error was delayed with loading feedback")
        browser.loadError = nil; browser.isLoading = false; browser.displayedEntries = entries; browser.refreshStatus()
        checks.append("Short tab loads avoid the full loading flash; long loads and immediate access errors remain visible")
        browser.closeTab(id: newID)
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        try UIVerification.require(browser.tabs.count == 1, "Tab closure did not revoke the closed tab")
        checks.append("New/closed tabs retain immediate model ownership; single-pane outline absent")
        try UIVerification.require(workspace.splitActive(at: .trailing), "Review split refused")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true
        try await wait { !peer.isLoading && peer.orderingTask == nil }
        try UIVerification.require(workspace.paneHosts.values.filter(\.showsFocusOutline).count == 1, "Split focus outline is inconsistent")
        let draft = "Unfinished generated address"
        peer.focusLocation(nil); peer.pathField.stringValue = draft
        let editor = peer.pathField.currentEditor()
        settings.paneFocus = PaneFocusPreferences(style: .custom, thickness: 3, caption: true, red: 0.94, green: 0.55, blue: 0.21)
        try UIVerification.require(workspace.paneHosts.values.allSatisfy { $0.focusPreferences == settings.paneFocus }
            && peer.pathField.stringValue == draft && peer.pathField.currentEditor() === editor,
            "Live focus preferences changed the address draft or editor")
        let restored = try BrowserSettings(persist: false, restoredData: settings.encodedSnapshot())
        try UIVerification.require(restored.paneFocus == settings.paneFocus, "Focus preferences did not round-trip")
        window.makeFirstResponder(peer.table)
        peer.cancelLocationEditing()
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("native-split.png"))
        let host = try requireHost(workspace, peer.paneID)
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        try UIVerification.require(host.hitTest(point) !== host.subviews.first(where: { String(describing: type(of: $0)).contains("Outline") }),
            "Focus outline intercepted content input")
        workspace.activate(browser)
        try UIVerification.require(workspace.paneHosts[browser.paneID]?.showsFocusOutline == true
            && workspace.paneHosts[peer.paneID]?.showsFocusOutline == false, "Focus did not move between panes")
        try UIVerification.require(workspace.closeActivePane(), "Pane closure failed")
        try UIVerification.require(workspace.browsers.count == 1 && workspace.paneHosts.values.allSatisfy { !$0.showsFocusOutline },
            "Closing a pane left an outline or a stale pane")
        try await wait { !workspace.hasPaneTransitionForVerification }
        // Interrupt one reveal with another layout change. Visual snapshots
        // must drain without leaving live content transparent or intercepting input.
        try UIVerification.require(workspace.splitActive(at: .bottom), "Rapid split refused")
        try UIVerification.require(workspace.closeActivePane(), "Rapid close refused")
        try await wait { !workspace.hasPaneTransitionForVerification }
        try UIVerification.require(workspace.paneHosts.values.allSatisfy { $0.alphaValue == 1 },
            "Interrupted pane animation left transparent content")
        let animates = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for edge in [PaneDropEdge.leading, .trailing, .top, .bottom] {
            let current = workspace.activeBrowser
            current.newTab(nil)
            try await wait { !current.isLoading && current.orderingTask == nil }
            let moving = current.activeID
            let oldHost = try requireHost(workspace, current.paneID)
            let center = oldHost.convert(NSPoint(x: oldHost.bounds.midX, y: oldHost.bounds.midY), to: workspace.paneTreeHost)
            let drop = NSRect(x: center.x + 37, y: center.y - 29, width: 180, height: 32)
            let button = current.tabStrip.selectionButton(for: moving)
            let sourcePoint = button.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: workspace.paneTreeHost) }
            try UIVerification.require(workspace.moveTab(moving, from: current, beside: current, edge: edge, dropFrame: drop),
                "Directional tab reveal refused")
            let arriving = workspace.activeBrowser
            arriving.permitsBackgroundVerification = true
            if animates {
                let origin = workspace.paneTransitionOriginForVerification
                try UIVerification.require(origin?.edge == edge && origin?.dropFrame == drop
                    && sourcePoint.map { origin?.tab.rect.contains($0) == true } == true,
                    "Pane reveal lost its original tab or actual drop footprint")
                try UIVerification.require(workspace.paneHosts[arriving.paneID]?.layer?.mask != nil,
                    "Arriving pane did not receive its curved reveal")
            }
            try await wait { !workspace.hasPaneTransitionForVerification && !arriving.isLoading && arriving.orderingTask == nil }
            try UIVerification.require(workspace.paneHosts.values.allSatisfy { $0.alphaValue == 1 && $0.layer?.mask == nil },
                "Directional reveal retained a live-view mask")
            try UIVerification.require(workspace.closeActivePane(), "Directional test pane did not close")
            try await wait { !workspace.hasPaneTransitionForVerification }
        }
        checks.append("Split/close/focus ownership, live custom thickness/color/caption and durable preference round-trip pass")
        checks.append("Interrupted directional pane transitions drain; live contents retain full opacity")
        checks.append(animates ? "Four directional curved reveals retain source-tab/drop geometry and drain every live mask"
            : "Motion was skipped for the active visibility/accessibility setting; four layout directions still settle")
        checks.append("Noninteractive focus/transition surfaces preserve address editing and content input")
        settings.paneFocus = .init()
        // Shared material composition: master Solid and independent regions
        // remain authoritative, then restore the selected connected direction.
        settings.navigationStyle = .solid
        for pane in workspace.browsers.values { pane.updateMaterialSurfaces() }
        try UIVerification.require(workspace.activeBrowser.navigationSurface?.isUsingOpaqueSurface == true,
            "Solid style did not retain its opaque fallback")
        settings.navigationStyle = .glass
        for pane in workspace.browsers.values { pane.updateMaterialSurfaces() }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("native-connected.png"))
        checks.append("Shared native backdrop preserves Solid/region fallback; no file-content translucency was enabled")
        if review {
            // Keep two panes and a spare tab for human motion/focus acceptance.
            showReview(workspace: workspace, window: window, root: root)
        }
        return ["passed": true, "checks": checks, "review": review,
            "notExercised": ["Physical tab/pane animation acceptance", "Cross-drive signed-app handoff", "System accessibility setting changes"]]
    }
    static func showReview(workspace: BrowserWorkspaceController, window: NSWindow, root: URL) {
        workspace.activeBrowser.newTab(nil)
        _ = workspace.splitActive(at: .trailing)
        for pane in workspace.browsers.values { pane.permitsBackgroundVerification = true }
        window.title = "B07.4 generated Source · " + String(root.lastPathComponent.prefix(8))
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private static func requireHost(_ workspace: BrowserWorkspaceController, _ id: UUID) throws -> PaneHostView {
        guard let host = workspace.paneHosts[id] else { throw UIVerification.Failure(message: "Missing pane") }; return host
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Generated workspace did not settle")
    }
}
#endif
