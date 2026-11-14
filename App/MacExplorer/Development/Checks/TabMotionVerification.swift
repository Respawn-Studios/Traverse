#if DEBUG
import AppKit
import ExplorerCore

@MainActor enum TabMotionVerification {
    static func run(root: URL, output: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-move-continuity", isDirectory: true)
        try UIVerification.require(root.deletingLastPathComponent() == expected && UUID(uuidString: root.lastPathComponent) != nil
            && root.resolvingSymlinksInPath() == root && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Tab review requires its admitted generated packet")
        if output != root {
            let name = output.lastPathComponent
            try UIVerification.require(output.deletingLastPathComponent() == root && name.hasPrefix("tab-replay-")
                && UUID(uuidString: String(name.dropFirst("tab-replay-".count))) != nil
                && output.resolvingSymlinksInPath() == output
                && FileManager().fileExists(atPath: output.appendingPathComponent("replay.json").path),
                "Tab replay requires its fresh admitted output directory")
        }
        guard let window = browser.view.window else { throw UIVerification.Failure(message: "Missing native tab window") }
        browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.showsDockProgress = false
        browser.settings.glassFileContent = true
        // This suite qualifies folder-to-folder pictures/loading; the tester
        // suite separately verifies the ordinary This Mac New Tab default.
        browser.settings.newTabDestination = .currentFolder
        try verifyMotionPreferences()
        window.setContentSize(NSSize(width: 1200, height: 820))
        if !ProcessInfo.processInfo.arguments.contains("--offscreen") { window.makeKeyAndOrderFront(nil) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        browser.navigate(to: .directory(source)); try await settled(browser)
        let first = browser.activeID, firstVisit = browser.sessionID
        let tableFill = browser.table.backgroundColor, scrollFill = browser.folderScroll.drawsBackground
        let header = browser.table.headerView
        try verifyHeader(browser)
        browser.newTab(nil); window.contentView?.layoutSubtreeIfNeeded()
        let second = browser.activeID
        try UIVerification.require(second != first && browser.sessionID != firstVisit,
            "Tab arrival delayed its active identity or new visit")
        let animates = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animates {
            try UIVerification.require(browser.tabStrip.hasMotionForVerification && browser.canvasTransition != nil,
                "New tab did not begin both presentation lifetimes")
            try UIVerification.require(browser.canvasTransition?.visit == browser.sessionID
                && browser.canvasTransition?.isRevealing == false,
                "Canvas began revealing before the new visit was ready")
            try UIVerification.require(browser.canvasTransition?.layer?.backgroundColor?.alpha == 0
                && browser.canvasTransition?.layer?.isOpaque == false
                && (browser.contentSurface?.contentView.layer?.opacity ?? 1) == 1,
                "Canvas transition covered or dimmed its stable native background")
            if let bitmap = browser.canvasTransition?.image?.representations.first as? NSBitmapImageRep,
               let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) {
                try UIVerification.require(pixel.alphaComponent < 0.02,
                    "Empty canvas retained an opaque backplate in its transition picture")
            } else { throw UIVerification.Failure(message: "Missing transparent canvas sample") }
            try UIVerification.require(browser.folderScroll.drawsBackground == scrollFill
                && browser.table.backgroundColor == tableFill && browser.table.headerView === header,
                "Canvas capture changed its live header or native fills")
            if let header, let parent = browser.contentSurface?.contentView,
               let bitmap = browser.canvasTransition?.image?.representations.first as? NSBitmapImageRep {
                let rect = parent.convert(header.bounds, from: header)
                if parent.bounds.contains(NSPoint(x: rect.midX, y: rect.midY)) {
                    let x = Int((rect.midX - parent.bounds.minX) / parent.bounds.width * CGFloat(bitmap.pixelsWide))
                    let y = Int((parent.bounds.maxY - rect.midY) / parent.bounds.height * CGFloat(bitmap.pixelsHigh))
                    try UIVerification.require((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.02,
                        "The fixed native column header was included in a transition picture")
                }
            }
            try UIVerification.require(browser.canvasTransition?.hitTest(.zero) == nil,
                "Canvas picture intercepted native input")
            try await Task.sleep(for: .milliseconds(50))
            browser.updateNavigation(); browser.tabStrip.needsLayout = true; browser.tabStrip.layoutSubtreeIfNeeded()
            try UIVerification.require(browser.tabStrip.hasMotionForVerification,
                "An unrelated native layout prematurely finished tab motion")
        }
        try await settled(browser)
        browser.navigate(to: .directory(destination)); try await settled(browser)
        try verifyHeader(browser)
        browser.selectTab(first); try await settled(browser)
        try verifyHeader(browser)
        browser.newTab(nil); window.contentView?.layoutSubtreeIfNeeded()
        let closing = browser.activeID
        try await settled(browser)
        browser.closeTab(id: closing)
        try UIVerification.require(browser.activeID == second && browser.location == .directory(destination)
            && browser.tabStrip.closeButton(for: closing) == nil,
            "Active closure retained the old tab's input identity or selected the wrong destination")
        if animates { try UIVerification.require(browser.canvasTransition != nil, "Active closure omitted its canvas dissolve") }
        try await settled(browser)
        browser.newTab(nil); try await settled(browser)
        let stableID = browser.activeID, stableVisit = browser.sessionID
        browser.closeTab(id: second)
        try UIVerification.require(browser.activeID == stableID && browser.sessionID == stableVisit && browser.canvasTransition == nil,
            "Inactive closure changed the active canvas visit")
        try await settled(browser)
        browser.navigate(to: .directory(source)); try await settled(browser)
        if animates {
            let rows = browser.displayedEntries
            browser.prepareCanvasTransition(enabled: true)
            browser.displayedEntries = []; browser.isLoading = true
            try await Task.sleep(for: .milliseconds(500))
            try UIVerification.require(browser.canvasTransition == nil, "A slow destination retained its old canvas past the deadline")
            browser.displayedEntries = rows; browser.isLoading = false; browser.renderFilePresentation(selection: [])
            browser.prepareCanvasTransition(enabled: true)
            browser.loadError = "Generated tab access failure"; browser.refreshStatus()
            try UIVerification.require(browser.canvasTransition == nil, "An error remained hidden behind the previous canvas")
            try UIVerification.require((browser.contentSurface?.contentView.layer?.opacity ?? 1) == 1,
                "An interrupted canvas transition left live content transparent")
            browser.loadError = nil; browser.refreshStatus()
        }
        for _ in 0..<5 { browser.newTab(nil); browser.closeTab(id: browser.activeID) }
        try await settled(browser)
        browser.tabs.append(contentsOf: (0..<12).map { _ in BrowserTab(location: .directory(source)) })
        browser.tabStrip.update(tabs: browser.tabs, activeID: browser.activeID)
        browser.view.layoutSubtreeIfNeeded(); try await settled(browser)
        let hidden = browser.tabs.last!.id
        browser.closeTab(id: hidden)
        try UIVerification.require(browser.tabStrip.retiringPicturesForVerification == 0,
            "Closing an offscreen tab exposed a picture outside its old viewport")
        try await settled(browser)
        browser.prepareCanvasTransition(enabled: true)
        browser.suspendBrowser()
        try UIVerification.require(browser.canvasTransition == nil && !browser.tabStrip.hasMotionForVerification,
            "Suspension retained tab presentation work")
        browser.resumeBrowser(); try await settled(browser)
        browser.navigate(to: .directory(source)); try await settled(browser)
        let folder = source.appendingPathComponent("Folder")
        browser.navigate(to: .directory(folder))
        try UIVerification.require(browser.location == .directory(folder)
            && (!animates || browser.canvasTransition != nil), "Folder entry delayed identity or omitted motion")
        try await settled(browser)
        browser.goBack(nil); try await settled(browser)
        try verifyHeader(browser)
        try UIVerification.require(browser.location == .directory(source), "Folder motion changed Back history")
        browser.goForward(nil); try await settled(browser)
        browser.goUp(nil); try await settled(browser)
        try UIVerification.require(browser.location == .directory(source), "Folder motion changed Forward/Up navigation")
        browser.settings.motion.folders = false
        browser.navigate(to: .directory(folder))
        try UIVerification.require(browser.canvasTransition == nil, "Disabled folder motion still captured the canvas")
        try await settled(browser)
        browser.settings.motion = .init(reduceMotion: true)
        browser.newTab(nil); window.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require(browser.canvasTransition == nil && !browser.tabStrip.hasMotionForVerification,
            "App Reduce Motion did not bypass tab presentation")
        try await settled(browser)
        browser.settings.motion = .init()
        browser.navigate(to: .directory(source)); try await settled(browser)
        browser.settings.glassFileContent = false
        try await Task.sleep(for: .milliseconds(40)); try verifyHeader(browser)
        browser.settings.glassFileContent = true
        try await Task.sleep(for: .milliseconds(40)); try verifyHeader(browser)
        // Material changes retain the same native header and column geometry.
        try UIVerification.require(browser.table.headerView === header, "Content style replaced the interactive header")
        let columns = browser.table.tableColumns.map(\.identifier)
        browser.table.moveColumn(0, toColumn: 1); browser.table.moveColumn(1, toColumn: 0)
        try UIVerification.require(browser.table.tableColumns.map(\.identifier) == columns,
            "Glass header changed native column reordering")
        // Two different generated destinations make active-close motion clear.
        while browser.tabs.count > 1 { browser.closeTab(id: browser.tabs.last!.id) }
        browser.navigate(to: .directory(source)); try await settled(browser)
        let reviewFirst = browser.activeID
        browser.newTab(nil); try await settled(browser)
        browser.navigate(to: .directory(destination)); try await settled(browser)
        browser.selectTab(reviewFirst); try await settled(browser)
        window.title = "Generated tab motion · " + String(root.lastPathComponent.prefix(8))
        if animates {
            try await GlassVerification.captureOwnedWindow(window, to: output.appendingPathComponent("native-tabs.png"))
            guard let header = browser.table.headerView,
                  let bitmap = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent("native-tabs.png"))) else {
                throw UIVerification.Failure(message: "Missing owned-window native header capture")
            }
            let point = header.convert(NSPoint(x: header.bounds.width * 0.75, y: 3), to: nil)
            let x = Int(point.x / window.frame.width * CGFloat(bitmap.pixelsWide))
            let y = Int((window.frame.height - point.y) / window.frame.height * CGFloat(bitmap.pixelsHigh))
            let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            try UIVerification.require((color?.alphaComponent ?? 0) > 0.99
                && max(color?.redComponent ?? 0, color?.greenComponent ?? 0, color?.blueComponent ?? 0) > 0.025,
                "Actual native column-header capture contains an empty or black backing")
        } else { try await UIVerification.snapshot(window, to: output.appendingPathComponent("native-tabs.png")) }
        if review { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
        return ["passed": true, "review": review, "motionEnabled": animates,
            "checks": ["New/closed tab identity and input are immediate", "Repeated native layout preserves movement",
                "Active closure dissolves into the correct tab; inactive closure keeps its visit", "Slow/error canvas bridges drain promptly",
                "Rapid creation/closure and suspension leave no motion work", "Offscreen tab closure cannot expose hidden tab pictures",
                "Visible rows only; fixed header and live native fills stay unchanged",
                "Translucent file-content header retains a stable material through navigation",
                "Live opaque/glass content changes preserve the native header and column reordering",
                "Folder entry/Back/Forward/Up retain navigation; disabled motion captures nothing",
                "Version 15 defaults and version 16 motion preferences round-trip; per-effect switches and Reduce Motion"],
            "notExercised": ["Physical motion acceptance", "System accessibility setting changes", "Large-screen frame-time profiling"]]
    }
    private static func verifyHeader(_ browser: BrowserViewController) throws {
        guard let header = browser.table.headerView as? FileTableHeaderView else {
            throw UIVerification.Failure(message: "Missing native file header")
        }
        let workspace = NSWorkspace.shared
        let glass = BrowserMaterialPolicy.glassEnabled(style: browser.settings.navigationStyle,
            enabled: browser.settings.glassFileContent,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        try UIVerification.require(header.usesGlass == glass && header.isOpaque != glass && header.window === browser.view.window
            && header.bounds.width > 100 && header.bounds.height > 10,
            "Native header lost its material policy or allocated backing")
    }
    private static func verifyMotionPreferences() throws {
        let defaults = BrowserMotionPreferences()
        let older = BrowserSettings(persist: false, restoredData: Data("{\"version\":15}".utf8))
        try UIVerification.require(older.motion == defaults, "Existing preferences did not inherit motion defaults")
        for effect in BrowserMotionEffect.allCases {
            var selected = defaults; selected.set(false, for: effect)
            try UIVerification.require(!selected.allows(effect)
                && BrowserMotionEffect.allCases.filter { $0 != effect }.allSatisfy { selected.allows($0) },
                "An individual motion switch changed another effect")
        }
        var reduced = defaults; reduced.reduceMotion = true
        try UIVerification.require(BrowserMotionEffect.allCases.allSatisfy { !reduced.allows($0) && reduced.selected($0) },
            "Reduce Motion erased individual choices or left an effect enabled")
        let settings = BrowserSettings(persist: false)
        settings.motion = reduced; settings.motion.folders = false
        let data = try settings.encodedSnapshot()
        let restored = BrowserSettings(persist: false, restoredData: data)
        try UIVerification.require(restored.motion == settings.motion, "Motion preferences failed to round-trip")
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while browser.isLoading || browser.orderingTask != nil || browser.canvasTransition != nil || browser.tabStrip.hasMotionForVerification {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < deadline, "Generated tab presentation did not settle")
            browser.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
