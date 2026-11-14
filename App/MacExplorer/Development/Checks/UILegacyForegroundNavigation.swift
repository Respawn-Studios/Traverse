#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyForegroundTabs(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let root = context.admitted.fixture.root
        let state = context.admitted.state
            browser.view.window?.makeFirstResponder(browser.table)
            let originalID = browser.activeID
            try require(NSApplication.shared.mainMenu?.performKeyEquivalent(with: key("t", code: 17, flags: .command, window: windowController.window!)) == true,
                        "Command-T menu mapping failed")
            try await settled(browser)
            try require(browser.tabs.count == 2 && browser.activeID != originalID, "New tab failed")
            let secondID = browser.activeID
            try require(browser.handleExplorerShortcut(key("\t", code: 48, flags: .control, window: windowController.window!))
                        && browser.activeID == originalID, "Control-Tab did not select the next tab")
            try require(browser.handleExplorerShortcut(key("\t", code: 48, flags: [.control, .shift], window: windowController.window!))
                        && browser.activeID == secondID, "Control-Shift-Tab did not select the previous tab")
            try await settled(browser)
            let sortItem = NSMenuItem()
            sortItem.tag = 3
            browser.changeSort(sortItem)
            browser.toggleAscending(nil)
            try await settled(browser)
            try require(browser.table.sortDescriptors.first?.key == "size" && browser.table.sortDescriptors.first?.ascending == false,
                        "Sort menu did not synchronize the column indicator")
            try select("Folder A", in: browser)
            browser.table.keyDown(with: key("\r", code: 36, flags: [], window: windowController.window!))
            try await settled(browser)
            try require(browser.location.directoryURL?.lastPathComponent == "Folder A", "Explorer Return must open folder")
            let optionLeft = key(String(UnicodeScalar(0xF702)!), code: 123, flags: .option, window: windowController.window!)
            try require(SystemShortcutSnapshot.supportedModifiers(Int(optionKey)) == .option
                        && SystemShortcutSnapshot.supportedModifiers(Int(optionKey) | Int(kEventKeyModifierFnMask)) == nil,
                        "System Fn-Option shortcut was projected onto unqualified Option")
            state.measurements["optionLeftContext"] = [
                "windowKey": windowController.window!.isKeyWindow,
                "commandFocus": browser.hasFileCommandFocus,
                "responderClass": windowController.window!.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none",
                "pathEditing": browser.pathField.currentEditor() != nil,
                "filterEditing": browser.folderFilter.displayedField.currentEditor() != nil,
                "backEnabled": browser.commandEnabled(#selector(BrowserViewController.goBack(_:))),
                "systemConflict": SystemShortcutSnapshot.shared.conflicts(optionLeft),
                "userMenuOverride": BrowserShortcutMenus.hasUserOverride(.back, in: NSApplication.shared.mainMenu),
                "mappedBack": BrowserShortcut(optionLeft).flatMap { browser.settings.shortcutMap.resolve($0, fileSurface: true) } == .back
            ]
            try require(windowController.window!.performKeyEquivalent(with: optionLeft),
                        "Option-Left mapping failed")
            try await settled(browser)
            try require(browser.location == .directory(root), "Back returned to wrong folder")
            try require(browser.selectedURLs.contains(root.appendingPathComponent("Folder A", isDirectory: true)), "Back lost selection")
            browser.navigate(to: .directory(root.appendingPathComponent("Empty Folder", isDirectory: true)))
            try await settled(browser)
            browser.goBack(nil)
            browser.selectTab(originalID)
            try await settled(browser)
            try require(browser.location == .directory(root) && browser.tabs.count == 2, "Tabs share location state")
            try require(browser.table.sortDescriptors.first?.key == "name", "Tab switch retained another tab's sort indicator")
            browser.selectTab(secondID)
            try await settled(browser)
            try require(browser.selectedURLs.contains(root.appendingPathComponent("Folder A", isDirectory: true)),
                        "Switching tabs during pending history restoration lost selection")
            try require(browser.table.sortDescriptors.first?.key == "size", "Tab lost its own sorting")
            browser.selectTab(originalID)
            try await settled(browser)
            state.checks.append("Native menu shortcuts, Explorer Return, tab cycling, sort and rapid history restoration")
    }

    static func legacyForegroundPathAndSidebar(_ context: UILegacyWorkflowContext, plainCount: Int) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let root = context.admitted.fixture.root
        let state = context.admitted.state
            browser.focusLocation(nil)
            try require(browser.view.window?.firstResponder is NSTextView, "Location editing did not focus text editor")
            try require(!browser.handleExplorerShortcut(key("t", code: 17, flags: .control, window: windowController.window!)),
                        "Explorer aliases must not intercept text editing")
            browser.pathField.stringValue = root.appendingPathComponent("Empty Folder", isDirectory: true).path
            browser.locationEntered(nil)
            try await settled(browser)
            try require(browser.rawEntries.isEmpty && browser.loadError == nil && browser.overlayTitle.stringValue == "This folder is empty", "Empty folder state failed")
            state.checks.append("Editable path, text-field shortcut isolation and empty folder state")

            browser.navigate(to: .directory(root))
            try await settled(browser)
            browser.settings.showsHiddenFiles = true
            try await Task.sleep(for: .milliseconds(80))
            try await settled(browser)
            try require(browser.rawEntries.count == plainCount + 9, "Hidden preference did not refresh listing")
            browser.settings.showsHiddenFiles = false
            try await Task.sleep(for: .milliseconds(80))
            try await settled(browser)
            state.checks.append("Hidden-files preference refresh")

            let lazyNode = SidebarNode("Fixture", location: .directory(root))
            browser.sidebarRoots.append(lazyNode)
            browser.outline.reloadData()
            browser.loadSidebarChildren(lazyNode)
            try await waitUntil("Lazy sidebar load") { !lazyNode.loading }
            try require(lazyNode.children?.compactMap(\.location).count == 2, "Sidebar must list immediate folders only")
            try require(lazyNode.children?.allSatisfy { $0.children == nil } == true, "Sidebar eagerly traversed descendants")
            browser.sidebarRoots.removeAll { $0 === lazyNode }
            browser.outline.reloadData()
            for node in browser.sidebarRoots where node.group { browser.outline.expandItem(node) }
            state.checks.append("Lazy sidebar excludes packages and symlink traversal")

            browser.navigate(to: .directory(root.appendingPathComponent("not-created-by-fixture", isDirectory: true)))
            try await settled(browser)
            try require(browser.loadError != nil && browser.overlayTitle.stringValue == "Unable to load this folder", "Missing folder shown as empty")
            browser.navigate(to: .directory(root.appendingPathComponent("Résumé – नमस्ते – 日本語.txt")))
            try await settled(browser)
            try require(browser.loadError != nil, "File treated as directory")
            state.checks.append("Missing/not-directory failures are distinct from empty")

            browser.navigate(to: .directory(root))
            let child = root.appendingPathComponent("Folder A/Child", isDirectory: true)
            browser.navigate(to: .directory(child))
            try await settled(browser)
            try await Task.sleep(for: .milliseconds(180))
            try require(browser.location == .directory(child) && browser.displayedEntries.map(\.name) == ["Grandchild"],
                        "Cancelled older listing repainted a newer location")
            state.checks.append("Rapid navigation rejects stale listing results")
    }

}
#endif
