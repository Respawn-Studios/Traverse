import AppKit
import ExplorerCore

#if DEBUG
@MainActor
extension UIVerification {
    static func verifyCompactFolderFilter(_ browser: BrowserViewController, fixture: URL,
        output: URL) async throws -> [String: Any] {
        guard browser.isVerificationSession, fixture.isFileURL,
              fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL,
              fixture.deletingLastPathComponent().lastPathComponent == "fixtures",
              fixture.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build",
              let workspace = browser.workspace, let window = browser.view.window else {
            throw Failure(message: "Folder-filter verification requires the generated native workspace")
        }
        let owned = fixture.deletingLastPathComponent().appendingPathComponent("chrome-filter-" + UUID().uuidString, isDirectory: true)
        try await createFilterFixture(owned)
        let originalTabs = browser.tabs, originalID = browser.activeID
        let size = window.contentView!.bounds.size
        defer {
            browser.folderFilter.contextWillChange()
            browser.tabs = originalTabs; browser.activeID = originalID; browser.loadLocation()
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
        }
        browser.navigate(to: .directory(owned)); try await settled(browser)
        browser.folderFilter.selectScope(0)
        browser.focusBrowserContent()
        window.setContentSize(workspace.minimumWorkspaceSize)
        window.contentView?.layoutSubtreeIfNeeded()
        try verifyCompactFilterGeometry(browser)
        let compactPathWidth = (browser.pathField.superview as? AddressSurfaceView)?.bounds.width ?? 0
        try require(compactPathWidth >= 190, "400-point compact pane did not release useful address width")
        let controller = browser.folderFilter
        let field = browser.filterField
        field.stringValue = ""
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settled(browser)
        let before = controller.button.image
        field.stringValue = "Match"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settled(browser)
        try require(browser.tabs[browser.activeIndex].filter == "Match"
            && browser.displayedEntries.map(\.name) == ["Match.txt"]
            && controller.button.image !== before && controller.button.accessibilityValue() as? String == "Match",
            "Compact filter lost actual row filtering/model or its visible accessible active cue")
        // Same instance/value and no navigation session change on allocation.
        let visit = browser.sessionID
        window.setContentSize(NSSize(width: 1400, height: max(size.height, 760)))
        window.contentView?.layoutSubtreeIfNeeded()
        try require(!controller.isCompact && field.superview === controller.view
            && browser.sessionID == visit && field.stringValue == "Match", "Wide allocation reset or duplicated the local filter")
        window.setContentSize(workspace.minimumWorkspaceSize)
        window.contentView?.layoutSubtreeIfNeeded()
        try verifyCompactFilterGeometry(browser)
        let visiblePopup = window.isVisible
        if visiblePopup {
            try require(NSApp.isActive && window.isKeyWindow,
                "Foreground filter qualification lost the app's key window; hidden-window fallback is inapplicable")
        }
        if visiblePopup { try await verifyVisibleFilterEditor(browser, folder: owned, window: window) }
        else {
            controller.button.performClick(nil)
            try require(!controller.isPresented && field.currentEditor() == nil,
                "Hidden-anchor verification manufactured a native popup/editor")
        }
        // Honest disabled states: no active icon/value despite a saved filter.
        browser.navigate(to: .computer); try await settled(browser)
        try require(!field.isEnabled && controller.button.isEnabled && controller.displaysSearch
            && browser.metadataSearch.scopePopup.indexOfSelectedItem == 1
            && !browser.metadataSearch.hasActiveSession
            && browser.commandEnabled(#selector(BrowserViewController.focusFilter(_:))),
            "This Mac failed to offer an idle indexed-search field instead of an unavailable folder filter")
        browser.navigate(to: .directory(owned)); try await settled(browser)
        browser.showMetadataSearch(nil)
        try require(!controller.isPresented && !browser.metadataSearch.isShowingResults,
            "Revealing explicit search automatically searched or left a competing filter popup")
        browser.metadataSearch.queryField.stringValue = "Match"
        browser.metadataSearch.scopePopup.selectItem(at: 0)
        browser.metadataSearch.submit() // explicit, bounded generated-root search
        try require(browser.metadataSearch.isShowingResults && !field.isEnabled && controller.button.isEnabled
            && controller.displaysSearch && controller.displayedField === browser.metadataSearch.queryField
            && field.superview == nil,
            "Unified search failed to replace the local filter with its single query field")
        browser.metadataSearch.cancel(); try await settled(browser)
        window.contentView?.layoutSubtreeIfNeeded()
        try await snapshot(window, to: output.appendingPathComponent("folder-filter-compact.png"))
        return ["case": "compact-folder-filter", "compactAddressWidth": compactPathWidth,
            "thresholdPaneWidth": BrowserLocalFilterController.compactThreshold,
            "sameNativeSearchField": field === browser.filterField,
            "visibleNativePopoverEditorCases": visiblePopup,
            "physicalKeyboardIMEExercised": false,
            "notExercised": visiblePopup ? ["Physical keyboard, IME candidate UI and VoiceOver"]
                : ["Native popup/editor in a visible anchor", "Physical keyboard, IME candidate UI and VoiceOver"]]
    }

    private static func createFilterFixture(_ owned: URL) async throws {
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-folder-filter-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            for name in ["Match.txt", "Other.txt"] {
                try Data().write(to: owned.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }.value
    }
    private static func verifyCompactFilterGeometry(_ browser: BrowserViewController) throws {
        let filter = browser.folderFilter
        guard let window = browser.view.window, let address = browser.pathField.superview else {
            throw Failure(message: "Compact filter has no native address/window")
        }
        // The 400-point pane contract belongs to PaneHostView. Its existing
        // one-point border on each side leaves 398 points for browser content.
        let paneWidth = browser.workspace?.paneHosts[browser.paneID]?.bounds.width ?? browser.view.bounds.width
        try require(paneWidth >= 399.5 && browser.view.bounds.width < BrowserLocalFilterController.compactThreshold
            && filter.isCompact && filter.view.bounds.width <= 25 && !filter.button.isHidden,
            "Compact filter allocation: paneWidth=\(browser.view.bounds.width), compact=\(filter.isCompact), filterWidth=\(filter.view.bounds.width), hidden=\(filter.button.isHidden), editor=\(browser.filterField.currentEditor() != nil), popup=\(filter.isPresented)")
        let point = filter.button.convert(NSPoint(x: filter.button.bounds.midX, y: filter.button.bounds.midY), to: nil)
        let hit = window.contentView!.hitTest(window.contentView!.convert(point, from: nil))
        let accessible = NSAccessibility.unignoredDescendant(of: filter.button) as? any NSAccessibilityProtocol
        try require((hit === filter.button || hit?.isDescendant(of: filter.button) == true)
            && window.contentView!.bounds.contains(window.contentView!.convert(filter.button.bounds, from: filter.button))
            && accessible?.accessibilityRole() == .button
            && accessible?.accessibilityLabel() == "Filter this folder"
            && address.bounds.width >= 190,
            "Compact native filter geometry: hit=\(hit === filter.button || hit?.isDescendant(of: filter.button) == true), contained=\(window.contentView!.bounds.contains(window.contentView!.convert(filter.button.bounds, from: filter.button))), role=\(accessible?.accessibilityRole()?.rawValue ?? "none"), label=\(accessible?.accessibilityLabel() ?? "none"), directLabel=\(filter.button.accessibilityLabel() ?? "none"), addressWidth=\(address.bounds.width)")
    }

    /// This branch requires the actual visible native NSPopover and field
    /// editor; no fake hidden-window presenter substitutes for it.
    private static func verifyVisibleFilterEditor(_ browser: BrowserViewController,
        folder: URL, window: NSWindow) async throws {
        let controller = browser.folderFilter
        let field = browser.filterField
        let originalProfile = browser.settings.keyboardProfile
        defer { browser.settings.keyboardProfile = originalProfile }
        browser.settings.keyboardProfile = .explorer
        controller.button.performClick(nil)
        try await waitUntil("Native compact filter popup") { controller.isPresented && field.currentEditor() is NSTextView }
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure(message: "Native filter editor missing") }
        let popupWindow = field.window
        try require(popupWindow !== window && editor.string == browser.tabs[browser.activeIndex].filter,
            "Compact filter did not move the original native field into its real popup")
        let menu = BrowserMenus.menu(.view, target: browser)
        try require(menu.performKeyEquivalent(with: key("f", code: 3, flags: .command, window: popupWindow!))
            && field.currentEditor() === editor && editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length),
            "Existing Command-F did not select the same canonical native filter")
        editor.insertText("Match", replacementRange: editor.selectedRange())
        try await settled(browser)
        let visit = browser.sessionID
        // Widening while an editor lives must not reparent, reset or navigate.
        window.setContentSize(NSSize(width: 1400, height: max(window.contentView!.bounds.height, 760)))
        window.contentView?.layoutSubtreeIfNeeded()
        try require(controller.isCompact && controller.isPresented && field.currentEditor() === editor
            && field.window === popupWindow && field.stringValue == "Match" && browser.sessionID == visit,
            "Resize moved a live native popup editor or reset its value/session")
        // Native close retains the clicked target. No delayed focus restoration.
        window.makeFirstResponder(browser.outline)
        controller.dismiss()
        try await waitUntil("Native filter close/inline allocation") { !controller.isPresented && !controller.isCompact }
        try require(window.firstResponder === browser.outline && field.superview === controller.view
            && field.stringValue == "Match", "Click-away close stole focus or discarded the filter")
        browser.focusFilter(nil)
        guard let inlineEditor = field.currentEditor() as? NSTextView else { throw Failure(message: "Inline native filter editor missing") }
        // This exercises NSTextInputClient marked text, not a physical IME.
        inlineEditor.setMarkedText("नम", selectedRange: NSRange(location: 2, length: 0), replacementRange: inlineEditor.selectedRange())
        window.setContentSize(browser.workspace!.minimumWorkspaceSize)
        window.contentView?.layoutSubtreeIfNeeded()
        try require(!controller.isCompact && field.currentEditor() === inlineEditor && inlineEditor.hasMarkedText(),
            "Narrowing reparented/cancelled native marked text")
        inlineEditor.unmarkText()
        window.makeFirstResponder(browser.activeFileView)
        try await waitUntil("Deferred compact allocation") { controller.isCompact }
        // Real application-queue delivery reaches the popover-scoped existing
        // F6/Shift-F6/F4 mappings; never call the monitor as a fake shortcut.
        for backwards in [false, true] {
            browser.focusFilter(nil)
            try await waitUntil("Native filter before focus cycle") { controller.isPresented && field.currentEditor() != nil }
            guard let popup = field.window else { throw Failure(message: "Popover command window missing") }
            NSApp.postEvent(key(String(UnicodeScalar(0xF709)!), code: 97,
                flags: backwards ? .shift : [], window: popup), atStart: false)
            try await waitUntil("Popover native F6 command") { !controller.isPresented }
            try require(window.firstResponder === (backwards ? browser.pathControl : browser.activeFileView),
                "Popover F6 did not preserve the existing browser focus order")
        }
        browser.focusFilter(nil)
        try await waitUntil("Native filter before F4") { controller.isPresented && field.currentEditor() != nil }
        guard let functionWindow = field.window else { throw Failure(message: "F4 popover window missing") }
        NSApp.postEvent(key(String(UnicodeScalar(0xF707)!), code: 118, flags: [], window: functionWindow), atStart: false)
        try await waitUntil("Popover native F4 command") { !controller.isPresented && browser.pathField.currentEditor() is NSTextView }
        try require(browser.pathField.stringValue == folder.path, "Popover F4 did not open canonical location editing")
        browser.cancelLocationEditing()
        // Escape keeps the existing clear-filter contract through native text.
        browser.focusFilter(nil)
        try await waitUntil("Second native filter popup") { controller.isPresented && field.currentEditor() is NSTextView }
        guard let escapeEditor = field.currentEditor() as? NSTextView, let escapeWindow = field.window else {
            throw Failure(message: "Escape filter editor missing")
        }
        escapeEditor.keyDown(with: key("\u{1b}", code: 53, flags: [], window: escapeWindow))
        try await waitUntil("Native filter Escape") { !controller.isPresented && browser.tabs[browser.activeIndex].filter.isEmpty }
        try require(field.stringValue.isEmpty && window.firstResponder === browser.activeFileView,
            "Escape did not clear the filter and return content focus")
        browser.focusFilter(nil)
        try await waitUntil("Native filter before tab change") { controller.isPresented && field.currentEditor() != nil }
        guard let oldEditor = field.currentEditor() as? NSTextView else { throw Failure(message: "Old filter editor missing") }
        oldEditor.insertText("Match", replacementRange: oldEditor.selectedRange())
        try await settled(browser)
        let previous = browser.activeID
        browser.newTab(nil); try await settled(browser)
        try await waitUntil("Old tab's native filter dismissal") { !controller.isPresented }
        try require(!controller.isPresented && !controller.hasPopoverCommandsForVerification
            && browser.activeID != previous && browser.tabs[browser.activeIndex].filter.isEmpty
            && browser.tabs.first(where: { $0.id == previous })?.filter == "Match",
            "Filter tab transition: presented=\(controller.isPresented), commands=\(controller.hasPopoverCommandsForVerification), changed=\(browser.activeID != previous), newFilterEmpty=\(browser.tabs[browser.activeIndex].filter.isEmpty), oldFilterMatch=\(browser.tabs.first(where: { $0.id == previous })?.filter == "Match")")
        // SDK native notifications carry NSFieldEditor; an obsolete editor
        // cannot publish into the new tab even though the same control is reused.
        field.stringValue = "Stale generated filter"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
            object: field, userInfo: ["NSFieldEditor": oldEditor]))
        try require(browser.tabs[browser.activeIndex].filter.isEmpty,
            "A retired native field editor wrote into the new tab")
        browser.focusFilter(nil)
        try await waitUntil("Fresh native filter after stale notification") { controller.isPresented && field.currentEditor() is NSTextView }
        try require(field.stringValue.isEmpty, "Fresh filter opened obsolete editor text instead of the current model")
        controller.dismiss()
        try await waitUntil("Fresh filter closed") { !controller.isPresented }
        browser.selectTab(previous); try await settled(browser)
        browser.focusFilter(nil)
        try await waitUntil("Native filter before visit change") { controller.isPresented }
        browser.navigate(to: .directory(folder)); try await settled(browser)
        try await waitUntil("Old visit's native filter dismissal") { !controller.isPresented }
        try require(!controller.isPresented, "New visit retained an old filter popup")
    }

    static func verifyCompactFilterInFourPanes(_ workspace: BrowserWorkspaceController,
        window: NSWindow, owned: URL) async throws {
        guard workspace.activeBrowser.isVerificationSession, workspace.browsers.count == 4,
              let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              owned.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              owned.lastPathComponent.hasPrefix("workspace-navigation-"),
              UUID(uuidString: String(owned.lastPathComponent.dropFirst("workspace-navigation-".count))) != nil,
              owned.standardizedFileURL == owned.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(message: "Compact filter requires the real generated four-pane workspace")
        }
        let folder = owned.appendingPathComponent("folder-filter", isDirectory: true)
        try await createFilterFixture(folder)
        let active = workspace.activeBrowser, size = window.contentView!.bounds.size
        for browser in workspace.browsers.values { browser.saveViewState() }
        let originals = workspace.browsers.mapValues { ($0.tabs, $0.activeID) }
        defer {
            for browser in workspace.browsers.values { browser.folderFilter.contextWillChange() }
            workspace.activate(active, focus: false)
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
        }
        func restore() async throws {
            for browser in workspace.browsers.values {
                browser.folderFilter.contextWillChange()
                if let original = originals[browser.paneID] {
                    browser.tabs = original.0; browser.activeID = original.1; browser.loadLocation()
                    try await settled(browser)
                }
            }
        }
        do {
            window.setContentSize(workspace.minimumWorkspaceSize)
            window.contentView?.layoutSubtreeIfNeeded()
            for browser in workspace.browsers.values {
                workspace.activate(browser, focus: false)
                browser.navigate(to: .directory(folder)); try await settled(browser)
                browser.folderFilter.selectScope(0)
                browser.focusBrowserContent()
                try verifyCompactFilterGeometry(browser)
                browser.filterField.stringValue = "Match"
                browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
                try await settled(browser)
                try require(browser.displayedEntries.map(\.name) == ["Match.txt"] && browser.tabs[browser.activeIndex].filter == "Match",
                    "Compact filter targeted a different pane's value or ordering session")
                guard let actionPeer = workspace.browsers.values.first(where: { $0 !== browser }) else {
                    throw Failure(message: "No independent peer for inactive Cancel action check")
                }
                workspace.activate(actionPeer, focus: false)
                browser.filterField.stringValue = ""
                browser.clearEmptyFolderFilter(browser.filterField)
                try require(browser.tabs[browser.activeIndex].filter == "Match" && browser.orderingTask == nil,
                    "Inactive pane's empty Filter action changed its retained filter")
                browser.filterField.stringValue = "Match"
                workspace.activate(browser, focus: false)
                if window.isVisible && NSApp.isActive {
                    browser.focusFilter(nil)
                    try await waitUntil("Four-pane native filter popup") { browser.folderFilter.isPresented }
                    guard let peer = workspace.browsers.values.first(where: { $0 !== browser }) else {
                        throw Failure(message: "No independent peer for filter lifetime check")
                    }
                    // This Mac uses the volume collection, not activeFileView.
                    // The arbitrary independent peer can retain either surface.
                    let expectedResponder: NSView = peer.showsComputerVolumes
                        ? peer.volumeBrowser.collectionView : peer.activeFileView
                    func focusFacts(_ stage: String) -> String {
                        let actual = window.firstResponder
                        let facts: [String: Any] = ["stage": stage,
                            "peerIsThisMac": peer.showsComputerVolumes,
                            "peerIsActive": workspace.activeBrowser === peer,
                            "windowKey": window.isKeyWindow, "applicationActive": NSApp.isActive,
                            "popoverShown": browser.folderFilter.isPresented,
                            "popoverRetained": browser.folderFilter.hasPopoverForVerification,
                            "expectedClass": String(describing: type(of: expectedResponder)),
                            "expectedIdentity": String(describing: ObjectIdentifier(expectedResponder)),
                            "actualClass": actual.map { String(describing: type(of: $0)) } ?? "nil",
                            "actualIdentity": actual.map { String(describing: ObjectIdentifier($0)) } ?? "nil"]
                        guard let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) else { return stage }
                        return String(decoding: data, as: UTF8.self)
                    }
                    workspace.activate(peer)
                    try require(workspace.activeBrowser === peer && window.firstResponder === expectedResponder,
                        "New pane never established its native content focus: " + focusFacts("after-activation"))
                    try await waitUntil("Inactive pane filter close callback drained") {
                        !browser.folderFilter.isPresented && !browser.folderFilter.hasPopoverForVerification
                    }
                    try require(workspace.activeBrowser === peer && window.firstResponder === expectedResponder,
                        "Old filter close stole established native content focus: " + focusFacts("after-close"))
                }
            }
            try await snapshot(window, to: owned.appendingPathComponent("four-panes-compact-folder-filter.png"))
            try await restore()
        } catch {
            try await restore()
            throw error
        }
    }
}
#endif
