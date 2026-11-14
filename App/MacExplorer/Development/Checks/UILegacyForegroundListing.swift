#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyForegroundListing(_ context: UILegacyWorkflowContext) async throws -> Int {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let metadata = context.admitted.fixture.metadata
        let state = context.admitted.state
            state.checks += try await InteractiveQualification.run(window: windowController.window!, fixtureRoot: root, evidenceRoot: output)
            try require(browser.location == .computer && !browser.volumes.isEmpty, "Mounted-volume overview did not load")
            try require(windowController.window?.toolbar?.isVisible == true, "Header menus must default to visible")
            try require(browser.computerScroll.bounds.height > 250 && browser.outline.visibleRect.height > 250,
                        "Mounted-volume browser region collapsed")
            try await snapshot(windowController.window!, to: output.appendingPathComponent("01-this-mac.png"))
            let chrome = try verifyWindowLayout(windowController)
            try verifyRenderedTabs(browser)
            try await verifyDriveInteractions(browser, fixture: root, output: output)
            state.checks.append("Compact native menu header, connected tabs and address layout")
            state.checks.append("Compact drives: native click/double-click, keyboard, copy, selection and accessible Open")

            browser.navigate(to: .directory(root))
            try await settled(browser)
            let plainCount = metadata?["plainFileCount"] as? Int ?? 0
            try require(browser.rawEntries.count == plainCount + 7, "Visible fixture count is incorrect")
            try require(browser.rawEntries.filter { $0.kind == .symbolicLink }.count == 2, "Links must remain links")
            try require(browser.rawEntries.contains { $0.name == "Example.app" && $0.kind == .package }, "Package must remain opaque")
            try require(browser.folderScroll.contentView.bounds.height > 250 && browser.table.rows(in: browser.table.visibleRect).length > 3,
                        "File table must render visible rows")
            try require(abs(browser.currentScrollOffset) < 1 && browser.folderScroll.contentView.bounds.origin.y <= -browser.folderScroll.contentView.contentInsets.top + 1,
                        "First table row is obscured by the native header")
            state.measurements = ["plainFileCount": plainCount, "visibleEntries": browser.displayedEntries.count,
                            "topChromeHeight": chrome,
                            "firstRowsMilliseconds": browser.firstRowsMilliseconds ?? -1,
                            "enumerationMilliseconds": browser.enumerationMilliseconds ?? -1,
                            "completeDisplayMilliseconds": browser.completeDisplayMilliseconds ?? -1]
            state.measurements["tableLayout"] = ["scrollInsetTop": browser.folderScroll.contentInsets.top,
                                           "clipInsetTop": browser.folderScroll.contentView.contentInsets.top,
                                           "clipBounds": NSStringFromRect(browser.folderScroll.contentView.bounds),
                                           "headerFrame": NSStringFromRect(browser.table.headerView?.frame ?? .zero),
                                           "firstRowFrame": NSStringFromRect(browser.table.rect(ofRow: 0))]
            try await snapshot(windowController.window!, to: output.appendingPathComponent("02-details.png"))
            state.checks.append("Shallow metadata listing, Unicode, packages, links and count")
        return plainCount
    }

    static func legacyForegroundFilter(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let output = context.admitted.fixture.output
        let state = context.admitted.state
        let clipboard = context.clipboard, privatePasteboard = context.privatePasteboard
            let unicode = "Résumé"
            browser.folderFilter.selectScope(0)
            browser.focusBrowserContent()
            browser.filterField.stringValue = unicode
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
            try await settled(browser)
            try require(browser.displayedEntries.count == 1 && browser.displayedEntries[0].name.contains(unicode), "Filename filter failed")
            try await snapshot(windowController.window!, to: output.appendingPathComponent("03-filter.png"))
            browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            browser.copyPath(nil)
            try require(clipboard.text == browser.displayedEntries[0].url.path, "Copy Path used the wrong item")
            browser.copyFileURLs(nil)
            try require(clipboard.urls == [browser.displayedEntries[0].url], "Copy file URLs used the wrong item")
            try require(BrowserClipboard.write(clipboard.text, urls: [], to: privatePasteboard)
                        && privatePasteboard.string(forType: .string) == clipboard.text, "Native path serialization failed")
            try require(BrowserClipboard.write(nil, urls: clipboard.urls, to: privatePasteboard), "Native file-reference serialization failed")
            let pasted = privatePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
            try require(pasted?.map { $0 as URL } == clipboard.urls, "Native file references did not round-trip")
            state.checks.append("Filename filter, copy routing and native private-pasteboard serialization")
            browser.filterField.stringValue = ""
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
            try await settled(browser)
    }

    static func legacyForegroundPartialRows(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let state = context.admitted.state
            // Model a delayed final batch deterministically. Saved selections
            // can arrive after enough earlier rows already fill the viewport.
            let fullListing = browser.rawEntries
            let pendingURL = fullListing.last!.url
            browser.tabs[browser.activeIndex].state = NavigationState(selection: [pendingURL])
            browser.restoringScroll = true
            browser.isLoading = true
            browser.rawEntries = Array(fullListing.filter { $0.url != pendingURL }.prefix(256))
            browser.requestOrdering()
            try await waitUntil("Controlled partial listing") { browser.orderingTask == nil }
            browser.saveViewState()
            try require(browser.tabs[browser.activeIndex].state.selection.contains(pendingURL),
                        "Partial viewport erased an item waiting in a later batch")
            browser.rawEntries = fullListing
            browser.isLoading = false
            browser.requestOrdering()
            try await settled(browser)
            try require(browser.selectedURLs.contains(pendingURL), "Final batch did not restore the pending selection")
            browser.table.deselectAll(nil)
            state.checks.append("Controlled partial batches preserve unresolved history selection")
    }

}
#endif
