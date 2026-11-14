#if DEBUG
import AppKit
import FileMemory

@MainActor enum PrivateNamesManagementVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-continuity-management", isDirectory: true)
        try UIVerification.require(root.deletingLastPathComponent() == expected && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Management QA needs an admitted isolated root")
        let source = root.appendingPathComponent("source/Report.txt"), target = root.appendingPathComponent("destination")
        let settings = browser.settings
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        let owner = ApplicationPrivateNames(directory: root.appendingPathComponent("names"), settings: settings)
        browser.privateNames = owner
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        await owner.refreshManagement()
        try UIVerification.require(owner.management == nil
            && !FileManager().fileExists(atPath: root.appendingPathComponent("names").path), "Passive Privacy inspection created a catalog")
        _ = try await owner.save(AuthoredNames(nickname: "Generated Orion", alternateNames: ["Quarterly report"], labels: ["finance", "checked"]),
            source: source, id: nil, revision: nil, access: nil, allowFollowing: true)
        await owner.refreshManagement()
        try UIVerification.require(owner.management?.savedItems == 1 && owner.management?.labels == 2, "Management counts lost saved fields")
        var pageVisibility: [BrowserSettingsView.Page: Int] = [:]
        var view = browser.makeSettingsView(initialPage: .privacy)
        view.onPageVisibilityForVerification = { page, visible in if visible { pageVisibility[page, default: 0] += 1 } }
        let window = BrowserSettingsWindow.make(view)
        window.title = "Privacy & Search · generated management review"
        if !browser.isControlledVerification { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { pageVisibility[.privacy, default: 0] > 0 }
        func tabs() -> NSSegmentedControl? {
            var pending = [window.contentView?.superview].compactMap { $0 }, count = 0
            while let next = pending.popLast(), count < 512 {
                count += 1
                if let control = next as? NSSegmentedControl, control.segmentCount == 6,
                   control.label(forSegment: 0) == "General", control.label(forSegment: 4) == "Privacy" { return control }
                pending.append(contentsOf: next.subviews)
            }
            return nil
        }
        for (index, page) in [(0, BrowserSettingsView.Page.general), (1, .appearance), (2, .keyboard), (3, .operations), (4, .privacy)] {
            guard let control = tabs(), let action = control.action else { throw UIVerification.Failure(message: "Settings pages overflowed or lost native actions") }
            let before = pageVisibility[page, default: 0]
            control.selectedSegment = index
            try UIVerification.require(control.sendAction(action, to: control.target), "Native Settings page action failed")
            try await wait { pageVisibility[page, default: 0] > before }
            try UIVerification.require(control.bounds.width > 400 && control.bounds.width < BrowserSettingsWindow.contentSize.width - 80,
                "Five-page Settings header does not fit its native allocation")
        }
        let preview = try await owner.prepareNameExport(locations: false)
        try UIVerification.require(preview.recordCount == 1 && !preview.includesLocations, "Native export preview included paths by default")
        let exported = await owner.publishNameExport(preview, to: target.appendingPathComponent("saved-names.json"), cancellation: .init())
        try UIVerification.require(exported == .saved(bytes: preview.encodedBytes, records: 1), "Native export failed")
        let optional = try await owner.prepareNameExport(locations: true)
        owner.cancelNameExport(optional)
        try UIVerification.require(await owner.publishNameExport(optional, to: target.appendingPathComponent("cancelled.json"), cancellation: .init()) == .notCreated(.stalePreview),
            "Cancelled native export published")
        settings.navigationStyle = .solid; settings.appearance = .light
        try await wait { (window.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true }
        settings.navigationStyle = .glass; settings.appearance = .dark
        try await wait { (window.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == false
            && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        try await Task.sleep(for: .milliseconds(240))
        window.contentView?.layoutSubtreeIfNeeded()
        if window.isVisible {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("privacy-native.png"))
        } else {
            try await UIVerification.snapshot(window, to: root.appendingPathComponent("privacy-native.png"))
        }
        // Native alert presentation is separate from the owner call. This tests
        // the ordinary owner used by the Settings confirmation action.
        let result = try await owner.forgetAllNames()
        try await wait { owner.management?.savedItems == 0 }
        try UIVerification.require(result == .forgotten && owner.management?.savedItems == 0 && !owner.pendingForgetAll,
            "Native Forget All did not finish its drain")
        try UIVerification.require(FileManager().fileExists(atPath: source.path)
            && FileManager().fileExists(atPath: target.appendingPathComponent("saved-names.json").path), "Forget changed source/export files")
        window.close(); await owner.close()
        return ["passed": true, "metadataOnly": true, "personalCatalogOpened": false,
            "checks": ["Passive Privacy inspection creates nothing", "Actual five-page native Settings and Glass/Solid updates",
                "Numeric counts and declared page/allocation reporting", "Native owner export/default paths excluded/cancel",
                "Native owner Forget All and actual drain preserve original/external export"],
            "notExercised": ["Physical Save-panel/Forget-confirmation clicks", "Time Machine restore", "Power loss"]]
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native management presentation did not settle")
    }
}
#endif
