#if DEBUG
import AppKit
import ExplorerCore

@MainActor enum WorkspaceNetworkMotionVerification {
    struct Outcome {
        let controller: BrowserWindowController
        let clips: [[String: Any]]
        let checks: [String: Any]
    }
    static func run(root: URL, settings: BrowserSettings) async throws -> Outcome {
        let require = WorkspaceNetworkVerification.require
        let owner = BrowserWindowController(settings: settings)
        guard let window = owner.window else { throw WorkspaceNetworkVerification.Failure.scope }
        let workspace = owner.workspace, snapshot = try WorkspaceNetworkVerification.sample(root: root)
        window.title = "Saved network layouts · generated review · motion audit"
        window.setContentSize(.init(width: 1120, height: min(740, (NSScreen.main?.visibleFrame.height ?? 900)-60)))
        window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        try WorkspaceNetworkVerification.configure(workspace, root: root, snapshot: snapshot)
        try await WorkspaceNetworkVerification.wait { workspace.browsers.values.allSatisfy { !$0.isLoading } }
        var clips: [[String: Any]] = []
        let browser = workspace.activeBrowser
        for index in 0..<3 {
            try await Task.sleep(for: .milliseconds(300))
            let target = browser.tabs.first(where: { $0.id != browser.activeID })!.id
            let label = "workspace-saved-tab-\(index)"
            // Browser navigation updates the normal document title. Restore
            // the generated-only capture marker before every scoped recording.
            window.title = "Saved network layouts · generated review · motion audit"
            try require(window.frame.width <= 1152 && window.frame.height <= 800, #line)
            let movie = try await NativeMotionRecorder.record(window: window, root: root, label: label,
                sampling: .diagnostic(for: window)) { browser.selectTab(target) }
            try JSONEncoder().encode(movie).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip(label, report: movie, field: nil, window: window))
            try require(browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty, #line)
            let card = WorkspaceNetworkVerification.descendants(browser.view).first { $0.identifier?.rawValue == "workspace-network-card" }
            try require(card != nil && browser.canvasTransition == nil, #line)
        }
        var layout = snapshot.layout
        let third = UUID(), fourth = UUID()
        try layout.split(snapshot.panes[0].id, inserting: third, at: .bottom)
        try layout.split(snapshot.panes[1].id, inserting: fourth, at: .bottom)
        let four = PaneWorkspaceSnapshot(layout: layout, activePane: fourth, panes: snapshot.panes + [
            .init(id: third, tabs: snapshot.panes[1].tabs, viewMode: "Details"),
            .init(id: fourth, tabs: snapshot.panes[0].tabs, viewMode: "Details")])
        try WorkspaceNetworkVerification.configure(workspace, root: root, snapshot: four)
        for pane in workspace.browsers.values {
            if let remote = pane.tabs.first(where: { $0.location.isRemote }) { pane.selectTab(remote.id) }
        }
        try await Task.sleep(for: .milliseconds(350)); window.contentView?.layoutSubtreeIfNeeded()
        var scrollable = 0
        for pane in workspace.browsers.values {
            guard let button = WorkspaceNetworkVerification.connectButton(in: pane),
                  let scroll = WorkspaceNetworkVerification.descendants(pane.view).compactMap({ $0 as? NSScrollView })
                    .first(where: { $0.documentView?.subviews.contains { $0.identifier?.rawValue == "workspace-network-card" } == true }),
                  let canvas = scroll.documentView else { throw WorkspaceNetworkVerification.Failure.scope }
            button.scrollToVisible(button.bounds.insetBy(dx: -5, dy: -5)); window.contentView?.layoutSubtreeIfNeeded()
            let actual = button.convert(button.bounds, to: canvas)
            try require(canvas.bounds.insetBy(dx: -1, dy: -1).contains(actual)
                && scroll.contentView.bounds.height <= canvas.bounds.height+1, #line)
            if canvas.bounds.height > scroll.contentView.bounds.height+1 { scrollable += 1 }
        }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/workspace-four-panes.png"))
        return .init(controller: owner, clips: clips, checks: ["disconnectedCards": true, "fourPaneButtonsReachable": true,
            "smallPanesScroll": scrollable, "interfacePercent": settings.interfaceSize.percent,
            "networkRequests": 0, "keychainCalls": 0, "privateFileReads": 0])
    }
}
#endif
