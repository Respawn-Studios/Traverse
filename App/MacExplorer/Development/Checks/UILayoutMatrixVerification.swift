import AppKit

#if DEBUG
@MainActor
extension UIVerification {
    static func verifyLayoutMatrix(_ browser: BrowserViewController, output: URL) async throws {
        guard let window = browser.view.window, browser.isVerificationSession else {
            throw Failure(message: "Layout matrix requires an owned verification window")
        }
        let originalFrame = window.frame, originalAppearance = NSApp.appearance
        let originalStyle = browser.settings.navigationStyle
        let originalTabs = browser.tabs, originalID = browser.activeID
        let originalRoots = browser.sidebarRoots
        let originalSidebarWidth = browser.splitController.splitViewItems.first?.viewController.view.frame.width ?? 180
        defer {
            browser.settings.navigationStyle = originalStyle
            NSApp.appearance = originalAppearance
            window.setFrame(originalFrame, display: false)
            browser.sidebarRoots = originalRoots; browser.outline.reloadData()
            for group in originalRoots where group.group { browser.outline.expandItem(group) }
            browser.tabs = originalTabs; browser.activeID = originalID; browser.loadLocation()
            browser.splitController.splitView.setPosition(originalSidebarWidth, ofDividerAt: 0)
        }
        browser.navigate(to: .computer)
        try await settled(browser)
        // Use the real group-row implementation for a third, longer label,
        // without creating a remembered access grant or probing a real folder.
        browser.sidebarRoots.append(SidebarNode("Remembered Folders", group: true,
            children: [SidebarNode("Generated reference", location: .computer, children: [])]))
        browser.outline.reloadData()
        for group in browser.sidebarRoots where group.group { browser.outline.expandItem(group) }
        func disclosureButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap { disclosureButton(in: $0) }.first
        }
        guard let group = browser.sidebarRoots.first(where: \.group) else {
            throw Failure(message: "Layout matrix has no native disclosure group")
        }
        var disclosureActivations = 0
        for expectedExpanded in [false, true] {
            guard let rowView = browser.outline.rowView(atRow: browser.outline.row(forItem: group), makeIfNecessary: true),
                  let button = disclosureButton(in: rowView), button.isEnabled else {
                throw Failure(message: "Native group disclosure cannot be activated")
            }
            button.performClick(nil)
            try await waitUntil("Native sidebar disclosure action") { browser.outline.isItemExpanded(group) == expectedExpanded }
            disclosureActivations += 1
        }
        var cases: [[String: Any]] = []
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for style in NavigationStyle.allCases {
                for (width, sidebarWidth) in [(CGFloat(820), CGFloat(180)), (1140, 240), (1600, 300)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    browser.settings.navigationStyle = style
                    window.setContentSize(NSSize(width: width, height: 760))
                    browser.splitController.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                    await Task.yield()
                    window.contentView?.layoutSubtreeIfNeeded()
                    for expanded in [true, false] {
                        for group in browser.sidebarRoots where group.group {
                            if expanded { browser.outline.expandItem(group) }
                            else { browser.outline.collapseItem(group) }
                        }
                        window.contentView?.layoutSubtreeIfNeeded()
                        let name = "\(theme)-\(style.rawValue.lowercased())-\(Int(width))-\(expanded ? "expanded" : "collapsed")"
                        let directory = output.appendingPathComponent(name, isDirectory: true)
                        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
                        try await verifySidebarLayout(browser, output: directory)
                        try require(browser.tabStrip.activeTabIsVisible && browser.tabStrip.addButton.frame.maxX <= browser.tabStrip.bounds.maxX + 1,
                                    "Layout matrix hid the active tab or adjacent add control")
                        try require(browser.pathField.superview?.bounds.height == 28,
                                    "Layout matrix changed the address surface height")
                        let actualSidebarWidth = browser.splitController.splitViewItems.first?.viewController.view.frame.width ?? 0
                        try require(abs(actualSidebarWidth - sidebarWidth) <= 1,
                                    "Layout matrix did not exercise its requested sidebar width")
                        try requireControlledWindowsHidden("layout matrix")
                        cases.append(["name": name, "contentWidth": Double(browser.view.bounds.width),
                            "sidebarWidth": Double(actualSidebarWidth),
                            "expanded": expanded, "groupCount": browser.sidebarRoots.filter(\.group).count])
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "cases": cases,
            "nativeDisclosureActivations": disclosureActivations,
            "captureMethod": "App-owned native Light/Dark, Solid/Glass, window/sidebar sizes and disclosure glyphs",
            "notExercised": ["WindowServer transparency", "Physical native controls", "VoiceOver", "Changed system accessibility preferences"]],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("layout-matrix.json"), options: .atomic)
    }
}
#endif
