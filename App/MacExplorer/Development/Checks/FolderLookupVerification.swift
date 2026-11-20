#if DEBUG
import AppKit
import ExplorerCore

@MainActor
private final class FilterCancelActionProbe: NSObject {
    weak var field: NSSearchField?
    weak var originalTarget: AnyObject?
    var originalAction: Selector?
    var actions = 0
    var senderIsField = false
    @objc func receive(_ sender: Any?) {
        actions += 1; senderIsField = sender as AnyObject? === field
        if let originalAction { NSApplication.shared.sendAction(originalAction, to: originalTarget, from: sender) }
    }
}

@MainActor
enum FolderLookupVerification {
    static func run(in root: URL) async throws -> [String] {
        let scope = root.appendingPathComponent("Name lookup", isDirectory: true)
        let home = scope.appendingPathComponent("Internal/Downloads", isDirectory: true)
        let external = scope.appendingPathComponent("External/Downloads", isDirectory: true)
        try await Task.detached {
            let fm = FileManager()
            for folder in [home, external.appendingPathComponent("Nested", isDirectory: true)] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("Generated metadata search fixture".utf8).write(to: external.appendingPathComponent("Nested/Project checklist.txt"), options: .withoutOverwriting)
            try Data().write(to: external.appendingPathComponent("Visible.txt"), options: .withoutOverwriting)
        }.value
        let settings = BrowserSettings(persist: false)
        let browser = BrowserViewController(settings: settings)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.permitsBackgroundVerification = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = browser
        window.contentView?.layoutSubtreeIfNeeded()
        defer { browser.suspendBrowser(); window.close() }
        try await AddressCompletionVerification.showInputWindow(window, title: "Traverse · generated folder-name lookup")
        let address = browser.addressCompletion
        address.nameLocationsForVerification = [
            .init(name: "Downloads", url: home, source: .familiar),
            .init(name: "Downloads", url: external, source: .index),
            .init(name: "Workspace", url: external.deletingLastPathComponent(), source: .volume)
        ]
        func type(_ text: String) throws -> NSTextView {
            browser.focusLocation(nil)
            guard let editor = browser.pathField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Folder-name check has no editor") }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            return editor
        }
        var editor = try type("Down")
        try await UIVerification.waitUntil("Bare folder-name suggestions") { address.suggestions.count == 2 }
        try UIVerification.require(address.suggestions[0].url == home && address.suggestions[1].url == external
            && Set(address.suggestions.map(\.id)).count == 2 && address.ghostTextForVerification == "loads/",
            "Bare folder lookup lost familiar priority, distinct parents or its name-only inline suffix")
        address.panelForVerification.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require((address.panelForVerification.contentView?.fittingSize.width ?? .infinity) <= 600
            && address.panelForVerification.frame.width <= 600,
            "Long contextual paths inflated the suggestion panel beyond its bounded width")
        try UIVerification.require(editor.string == "Down" && browser.location == .computer, "Bare-name hints edited text or navigated automatically")
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try UIVerification.require(editor.string == external.path + "/" && browser.location == .computer, "Name Tab failed to fill the explicitly selected path without navigating")
        browser.locationEntered(nil)
        try await settled(browser)
        try UIVerification.require(browser.location.directoryURL == external, "Explicit named suggestion did not navigate to its actual parent/volume")

        editor = try type("/Workspace/")
        try await UIVerification.waitUntil("Explicit mounted-drive correction") { address.suggestions.first?.source == .volume }
        try UIVerification.require(editor.string == "/Workspace/" && address.suggestions[0].url == external.deletingLastPathComponent()
            && address.ghostTextForVerification == nil, "An absolute path was rewritten or a mounted-drive correction was not labelled")
        browser.cancelLocationEditing()
        _ = try type("Downloads")
        try await UIVerification.waitUntil("Exact folder hints") { address.suggestions.count == 2 }
        let old = browser.location
        browser.locationEntered(nil)
        try UIVerification.require(browser.location == old, "Return on an unaccepted bare name invented a path")
        browser.cancelLocationEditing()
        try await Task.sleep(for: .milliseconds(120))
        try UIVerification.require(address.suggestions.isEmpty && !address.panelForVerification.isVisible, "Cancelled name lookup published a stale result")

        let unified = browser.folderFilter, search = browser.metadataSearch
        unified.selectScope(0)
        browser.focusBrowserContent()
        browser.filterField.stringValue = "Visible"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        try UIVerification.require(browser.displayedEntries.map(\.name) == ["Visible.txt"], "Filter mode stopped applying immediate loaded-item filtering: search=\(unified.displaysSearch), filter=\(browser.tabs[browser.activeIndex].filter), rows=\(browser.displayedEntries.map(\.name))")
        unified.selectScope(1)
        try UIVerification.require(unified.displaysSearch && unified.displayedField === search.queryField
            && browser.filterField.superview == nil && search.queryField.stringValue == "Visible"
            && !search.hasActiveSession && !search.isShowingResults && !search.view.isHidden,
            "Choosing Folder scope lost typed text, duplicated editors or submitted a search automatically")
        guard let draftCancel = (search.queryField.cell as? NSSearchFieldCell)?.cancelButtonCell else {
            throw UIVerification.Failure(message: "Native search draft has no Cancel cell")
        }
        draftCancel.performClick(nil)
        try await Task.sleep(for: .milliseconds(30))
        try UIVerification.require(search.queryField.stringValue.isEmpty && !search.hasActiveSession
            && !search.isShowingResults && browser.view.window?.attachedSheet == nil,
            "Native Cancel on an unsubmitted broader-search draft displayed an empty-query error or submitted work")
        search.queryField.stringValue = "Visible"
        unified.synchronize()
        try UIVerification.require(await browser.directoryObservation?.waitUntilStarted() == true,
            "Search-draft refresh check has no real generated-folder watcher")
        let draftVisit = browser.sessionID
        try await Task.detached {
            try Data().write(to: external.appendingPathComponent("Arrived while drafting.txt"), options: .withoutOverwriting)
        }.value
        try await UIVerification.waitUntil("Real folder change during search draft") { browser.directoryRefreshPending == .observedChange }
        try await Task.sleep(for: .milliseconds(260))
        try UIVerification.require(browser.sessionID == draftVisit && !search.view.isHidden
            && search.queryField.stringValue == "Visible" && !search.hasActiveSession,
            "Background directory refresh discarded an unsubmitted search draft")
        search.queryField.stringValue = "Project"
        search.submit()
        try await settled(browser)
        try UIVerification.require(search.scopePopup.indexOfSelectedItem == 0 && search.isShowingResults
            && browser.displayedEntries.map(\.name) == ["Project checklist.txt"]
            && search.queryField.superview === unified.view && !search.view.subviews.contains(where: { $0 === search.queryField }),
            "Unified explicit folder search did not find a descendant using its sole header editor")
        unified.selectScope(2)
        try UIVerification.require(search.scopePopup.indexOfSelectedItem == 1 && !search.hasActiveSession
            && search.queryField.stringValue == "Project", "Changing to This Mac submitted work or silently retained Folder scope")
        unified.selectScope(0)
        browser.focusBrowserContent()
        try await settled(browser)
        try UIVerification.require(!unified.displaysSearch && search.view.isHidden && search.queryField.superview == nil
            && unified.displayedField === browser.filterField && browser.filterField.stringValue == "Project",
            "Returning to Filter lost its query or retained a second query editor")
        browser.navigate(to: .computer); try await settled(browser)
        try UIVerification.require(unified.displaysSearch && unified.displayedField.isEnabled && search.scopePopup.indexOfSelectedItem == 1
            && !search.hasActiveSession, "This Mac still defaults to an unavailable filter instead of an idle indexed-search field")
        unified.selectScope(2)
        try UIVerification.require(unified.displayedField.isEnabled && unified.displaysSearch && search.scopePopup.indexOfSelectedItem == 1
            && !search.hasActiveSession, "This Mac cannot reveal an explicit indexed search without a folder")
        try await verifyDefaultsAndMenus(browser, folder: external, peer: home)
        return [
            "Generated bare folder names prefer familiar Downloads, distinguish duplicate parents and ghost only the name suffix",
            "Named Tab fills an explicit path; Return navigates only after acceptance; mounted-drive corrections leave absolute text literal",
            "Cancelled named completion retires its native suggestion surface without late publication",
            "Unified header preserves typed text across Filter/Folder/This Mac, searches descendants only on submit and owns one visible editor",
            "A real generated-file arrival defers directory refresh without discarding the unsubmitted broader-search draft",
            "Idle folder defaults, navigation/new tabs, draft/result preservation, real watcher refresh, settings migration and clicked-target sidebar menus pass"
        ]
    }

    private static func verifyDefaultsAndMenus(_ browser: BrowserViewController, folder: URL, peer: URL) async throws {
        let settings = browser.settings, search = browser.metadataSearch, unified = browser.folderFilter
        try UIVerification.require(settings.defaultSearchScope == .folder && settings.symbolTolerantNames,
            "Fresh preferences lost the owner-selected folder scope or bounded symbol matching default")
        browser.navigate(to: .directory(folder)); try await settled(browser)
        try UIVerification.require(unified.displaysSearch && search.scopePopup.indexOfSelectedItem == 0
            && search.view.isHidden && !search.hasActiveSession && !search.isShowingResults,
            "Opening a folder did not expose its idle explicit-submit search without pausing folder observation")
        try UIVerification.require(await browser.directoryObservation?.waitUntilStarted() == true,
            "Default folder scope lost the real generated-folder watcher")
        let idleVisit = browser.sessionID
        try await Task.detached { try Data().write(to: folder.appendingPathComponent("Idle default arrival.txt"), options: .withoutOverwriting) }.value
        try await UIVerification.waitUntil("Idle default watcher refresh") {
            browser.sessionID != idleVisit && !browser.isLoading && browser.displayedEntries.contains { $0.name == "Idle default arrival.txt" }
        }
        search.queryField.stringValue = "Project"
        settings.defaultSearchScope = .filter
        unified.synchronize()
        try UIVerification.require(unified.displaysSearch && search.queryField.stringValue == "Project"
            && search.scopePopup.indexOfSelectedItem == 0 && !search.hasActiveSession,
            "Changing defaults replaced an existing draft or submitted a query")
        search.submit(); try await settled(browser)
        let resultURLs = browser.displayedEntries.map(\.url)
        settings.defaultSearchScope = .thisMac
        unified.synchronize()
        try UIVerification.require(search.isShowingResults && browser.displayedEntries.map(\.url) == resultURLs
            && search.scopePopup.indexOfSelectedItem == 0 && search.queryField.stringValue == "Project",
            "Changing defaults replaced the active result scope, rows or query")
        browser.navigate(to: .directory(peer)); try await settled(browser)
        try UIVerification.require(unified.displaysSearch && search.scopePopup.indexOfSelectedItem == 1
            && search.queryField.stringValue.isEmpty && search.view.isHidden && !search.hasActiveSession,
            "The selected default did not apply to the next folder without auto-querying")
        settings.defaultSearchScope = .filter
        browser.newTab(nil); try await settled(browser)
        try UIVerification.require(browser.location == .computer && unified.displaysSearch && !search.hasActiveSession,
            "The default This Mac tab did not keep its idle indexed search")
        settings.newTabDestination = .currentFolder
        browser.navigate(to: .directory(peer)); try await settled(browser)
        browser.newTab(nil); try await settled(browser)
        try UIVerification.require(browser.location.directoryURL == peer && !unified.displaysSearch && !search.hasActiveSession,
            "A new current-folder tab did not adopt the configurable direct-filter default")
        settings.defaultSearchScope = .folder
        browser.navigate(to: .directory(folder)); try await settled(browser)
        let oldWriter = browser.clipboardWriter
        var copiedPath: String?, copiedURLs: [URL] = []
        browser.clipboardWriter = { text, urls in copiedPath = text; copiedURLs = urls; return .failed }
        defer { browser.clipboardWriter = oldWriter }
        let menu = browser.locationMenu(for: .directory(peer))
        try UIVerification.require(["Open", "Open in New Tab", "Copy", "Copy Path", "Paste Items Here", "Reveal in Finder", "Properties…"].allSatisfy { title in menu.items.contains { $0.title == title } },
            "A normal sidebar folder did not receive meaningful file-manager actions")
        guard let copyPath = menu.items.first(where: { $0.title == "Copy Path" }),
              let copy = menu.items.first(where: { $0.title == "Copy" }),
              let open = menu.items.first(where: { $0.title == "Open" }) else {
            throw UIVerification.Failure(message: "Sidebar target checks have no generated commands")
        }
        browser.renderFilePresentation(selection: Set(browser.displayedEntries.prefix(1).map(\.url)))
        _ = NSApplication.shared.sendAction(copyPath.action!, to: copyPath.target, from: copyPath)
        try UIVerification.require(copiedPath == peer.path && copiedURLs.isEmpty,
            "Sidebar Copy Path inherited the current file selection instead of its clicked folder")
        _ = NSApplication.shared.sendAction(copy.action!, to: copy.target, from: copy)
        try UIVerification.require(copiedURLs == [peer], "Sidebar Copy inherited another folder or file selection")
        _ = NSApplication.shared.sendAction(open.action!, to: open.target, from: open)
        try await settled(browser)
        try UIVerification.require(browser.location.directoryURL == peer, "Sidebar Open did not bind to the clicked folder")
        copiedPath = nil
        _ = NSApplication.shared.sendAction(copyPath.action!, to: copyPath.target, from: copyPath)
        try UIVerification.require(copiedPath == nil, "A menu from an old visit retained authority after navigation")
        let computer = browser.locationMenu(for: .computer)
        try UIVerification.require(["Open", "Open in New Tab", "Refresh This Mac", "Drives…"].allSatisfy { title in computer.items.contains { $0.title == title } },
            "This Mac sidebar entry still has no meaningful context menu")
        if let volume = browser.operationCoordinator.drives.volumes.first(where: { $0.url != nil }), let url = volume.url {
            let locationMenu = browser.locationMenu(for: .directory(url))
            let submenu = locationMenu.items.first { $0.title == "Drive" }?.submenu
            let direct = browser.driveMenu(for: url)
            try UIVerification.require(submenu?.items.map(\.title) == direct?.items.map(\.title)
                && (!volume.canEject || submenu?.items.contains { $0.title == "Eject when ready" } == true),
                "Sidebar drive menu lost This Mac action parity or an available guarded Eject")
        }
        // A restored visit's filter already determines row ordering. Its
        // visible editor must reveal that restriction instead of hiding it
        // behind an empty default Search Folder field.
        var filteredTab = BrowserTab(location: .directory(folder))
        filteredTab.filter = "Visible"
        browser.tabs.append(filteredTab); browser.activeID = filteredTab.id
        browser.loadLocation(); try await settled(browser)
        try UIVerification.require(browser.tabs[browser.activeIndex].filter == "Visible"
            && browser.displayedEntries.map(\.name) == ["Visible.txt"],
            "Restored-filter setup did not retain the actual row restriction")
        try UIVerification.require(!unified.displaysSearch && unified.displayedField === browser.filterField
            && unified.displayedField.stringValue == "Visible" && unified.displayedField.isEnabled,
            "Restored tab still filters rows while an empty Search Folder header hides its active filter")

        browser.navigate(to: .directory(peer)); try await settled(browser)
        try UIVerification.require(browser.tabs[browser.activeIndex].filter.isEmpty
            && unified.displaysSearch && search.scopePopup.indexOfSelectedItem == 0,
            "A new empty folder visit inherited the restored filter instead of the Search Folder default")
        browser.goBack(nil); try await settled(browser)
        try UIVerification.require(browser.tabs[browser.activeIndex].filter == "Visible"
            && !unified.displaysSearch && unified.displayedField.stringValue == "Visible"
            && browser.displayedEntries.map(\.name) == ["Visible.txt"],
            "Back hid the retained folder filter while continuing to restrict its rows")
        browser.focusBrowserContent()
        try UIVerification.require(browser.filterField.currentEditor() == nil,
            "Native cancel check still owns a field editor")
        browser.clearEmptyFolderFilter(NSSearchField())
        browser.filterField.stringValue = ""
        browser.filterField.isHidden = true
        browser.clearEmptyFolderFilter(browser.filterField)
        browser.filterField.isHidden = false
        try UIVerification.require(browser.tabs[browser.activeIndex].filter == "Visible"
            && browser.orderingTask == nil, "Hidden or unrelated Cancel action changed the retained filter")
        unified.selectScope(1)
        browser.filterField.stringValue = ""
        browser.clearEmptyFolderFilter(browser.filterField)
        try UIVerification.require(browser.tabs[browser.activeIndex].filter == "Visible"
            && browser.orderingTask == nil, "Replaced Filter action changed the current broader-search surface")
        browser.loadLocation(); try await settled(browser)
        browser.focusBrowserContent()
        guard let cancelCell = (browser.filterField.cell as? NSSearchFieldCell)?.cancelButtonCell else {
            throw UIVerification.Failure(message: "Native Filter has no cancel cell")
        }
        let cancelProbe = FilterCancelActionProbe()
        cancelProbe.field = browser.filterField
        cancelProbe.originalTarget = browser.filterField.target
        cancelProbe.originalAction = browser.filterField.action
        browser.filterField.target = cancelProbe
        browser.filterField.action = #selector(FilterCancelActionProbe.receive(_:))
        defer {
            browser.filterField.target = cancelProbe.originalTarget
            browser.filterField.action = cancelProbe.originalAction
        }
        cancelCell.performClick(nil)
        try await settled(browser)
        fputs("MAC_EXPLORER_FILTER_NATIVE_CANCEL originalTargetSet=\(cancelProbe.originalTarget != nil) originalActionSet=\(cancelProbe.originalAction != nil) actions=\(cancelProbe.actions) senderIsField=\(cancelProbe.senderIsField) fieldEmpty=\(browser.filterField.stringValue.isEmpty) modelEmpty=\(browser.tabs[browser.activeIndex].filter.isEmpty)\n", stderr)
        try UIVerification.require(browser.filterField.stringValue.isEmpty
            && browser.tabs[browser.activeIndex].filter.isEmpty
            && browser.displayedEntries.count > 1,
            "Native cancel cell cleared Filter text without clearing its retained row restriction")
        browser.clearEmptyFolderFilter(browser.filterField)
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try UIVerification.require(browser.orderingTask == nil,
            "Duplicate empty native Cancel scheduled redundant row ordering")
        browser.tabs[browser.activeIndex].filter = "Visible"
        browser.loadLocation(); try await settled(browser)
        browser.focusBrowserContent()
        let clearButton = browser.filterField.accessibilityClearButton() as? any NSAccessibilityButton
        let pressed = clearButton?.accessibilityPerformPress() ?? false
        try await settled(browser)
        fputs("MAC_EXPLORER_FILTER_AX_CANCEL available=\(clearButton != nil) pressed=\(pressed) fieldEmpty=\(browser.filterField.stringValue.isEmpty) modelEmpty=\(browser.tabs[browser.activeIndex].filter.isEmpty)\n", stderr)
        if pressed {
            try UIVerification.require(browser.filterField.stringValue.isEmpty
                && browser.tabs[browser.activeIndex].filter.isEmpty
                && browser.displayedEntries.count > 1,
                "Successful native accessibility Cancel cleared Filter text without clearing its retained row restriction")
        }
        browser.tabs[browser.activeIndex].filter = "Visible"
        browser.loadLocation(); try await settled(browser)
        let filteredID = browser.activeID
        browser.closeTab(id: filteredID); try await settled(browser)
        browser.focusBrowserContent(); browser.reopenClosedTab(nil); try await settled(browser)
        try UIVerification.require(browser.activeID != filteredID
            && browser.tabs[browser.activeIndex].filter == "Visible"
            && !unified.displaysSearch && unified.displayedField.stringValue == "Visible"
            && browser.displayedEntries.map(\.name) == ["Visible.txt"],
            "Reopening a closed filtered tab hid its retained filter or lost the row restriction")

        settings.defaultSearchScope = .thisMac; settings.symbolTolerantNames = false
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try UIVerification.require(restored.defaultSearchScope == .thisMac && !restored.symbolTolerantNames,
            "Default scope and symbol matching preferences did not survive reopening")
        let legacy = BrowserSettings(persist: false, restoredData: Data("{\"version\":12}".utf8))
        try UIVerification.require(legacy.defaultSearchScope == .folder && legacy.symbolTolerantNames,
            "Old preferences did not migrate to the selected search defaults")
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        try await UIVerification.waitUntil("Folder lookup native rows") { !browser.isLoading && browser.orderingTask == nil }
    }
}
#endif
