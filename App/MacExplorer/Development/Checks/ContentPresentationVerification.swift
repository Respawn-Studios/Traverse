import AppKit
import ExplorerCore

#if DEBUG
private final class PresentationDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    var isHeld: Bool { lock.withLock { continuation != nil } }
    var isFinished: Bool { lock.withLock { finished } }
    func hold() async {
        await withCheckedContinuation { pending in lock.withLock { continuation = pending } }
        lock.withLock { finished = true }
    }
    func release() {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume()
    }
}

@MainActor
extension UIVerification {
    /// Verify shared routing with real native surfaces and injected discovery /
    /// sharing. No preview panel, external application, recipient or file mutation.
    static func verifyContentPresentationRouting(_ browser: BrowserViewController, fixture: URL,
                                                 output: URL) async throws -> [String] {
        let originalTabs = browser.tabs, originalID = browser.activeID
        let originalMode = browser.settings.viewMode
        let originalPaneMode = browser.paneViewMode
        let originalBackground = browser.permitsBackgroundVerification
        let coordinator = browser.openAndShare
        let originalHooks = coordinator.hooks, originalVerification = coordinator.permitsVerification
        var shareCompletion: (@MainActor @Sendable (Error?) -> Void)?
        let gate = PresentationDiscoveryGate()
        browser.permitsBackgroundVerification = true
        coordinator.permitsVerification = true
        defer {
            gate.release(); shareCompletion?(nil)
            coordinator.windowWillClose(); coordinator.hooks = originalHooks
            coordinator.permitsVerification = originalVerification
            browser.tabs = originalTabs; browser.activeID = originalID
            browser.settings.viewMode = originalMode; browser.paneViewMode = originalPaneMode
            browser.applyDisplayPreferences()
            browser.permitsBackgroundVerification = originalBackground
            browser.loadLocation()
        }
        func mode(_ value: BrowserViewMode) {
            browser.setPaneViewMode(value)
            // Preference observers may deliver on the next run-loop turn for
            // a single-pane host. Settle the real presentation before checks.
            browser.applyDisplayPreferences()
            browser.view.layoutSubtreeIfNeeded()
        }
        func selectFiles(_ urls: Set<URL>) {
            browser.setFileSelection(urls)
            browser.fileSelectionDidChange()
        }
        mode(.details)
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        guard let selected = browser.displayedEntries.first(where: { $0.name.contains("Résumé") }),
              let other = browser.displayedEntries.first(where: { $0.kind == .file && $0.url != selected.url }) else {
            throw Failure(message: "Shared presentation fixture requires two regular files")
        }
        selectFiles([selected.url]); browser.focusBrowserContent()
        let visit = browser.sessionID, oldPresentation = browser.filePresentationID
        mode(.icons)
        try await waitUntil("Icons native layout for shared routing") { !browser.iconBrowser.visibleItems.isEmpty }
        try require(browser.sessionID == visit && browser.filePresentationID != oldPresentation
            && browser.activeFileView === browser.iconBrowser.collectionView
            && browser.activeFileScrollView === browser.iconBrowser.scrollView
            && browser.orderedSelectedURLs == [selected.url]
            && browser.view.window?.firstResponder === browser.iconBrowser.collectionView,
            "View switch lost selection, visit, presentation identity or native focus")
        // Deliberately diverge the hidden table. Commands must follow Icons.
        if let row = browser.rowsByURL[other.url] {
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try require(browser.selectedURLs == [selected.url] && browser.quickLookSelection == [selected.url]
            && browser.tabs[browser.activeIndex].state.selection == [selected.url],
            "A hidden table selection replaced the active Icons command selection")
        let hiddenSelection = browser.table.selectedRowIndexes
        selectFiles([browser.displayedEntries[0].url])
        browser.revealFile(browser.displayedEntries[0].url)
        browser.focusBrowserContent()
        browser.iconBrowser.collectionView.layoutSubtreeIfNeeded()
        let forwarded = browser.quickLook.previewPanel(nil, handle: key(String(UnicodeScalar(0xF703)!), code: 124,
            flags: [], window: browser.view.window!))
        try JSONSerialization.data(withJSONObject: ["handled": forwarded,
            "firstResponderIsGrid": browser.view.window?.firstResponder === browser.iconBrowser.collectionView,
            "windowIsKey": browser.view.window?.isKeyWindow == true,
            "selectedRowsAfter": browser.orderedSelectedURLs.compactMap { browser.rowsByURL[$0] },
            "hiddenTableUnchanged": browser.table.selectedRowIndexes == hiddenSelection],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-arrow-routing.json"), options: .atomic)
        try require(forwarded
            && browser.selectedURLs == [browser.displayedEntries[1].url]
            && browser.table.selectedRowIndexes == hiddenSelection,
            "Quick Look arrow forwarding did not target the active grid exclusively")
        selectFiles([selected.url])
        guard let anchor = browser.activeFileSelectionAnchor(for: [selected.url]) else {
            throw Failure(message: "Active Icons filename has no native sharing anchor")
        }
        try require(anchor.view === browser.iconBrowser.collectionView && !anchor.rect.isEmpty
            && anchor.rect.intersects(anchor.view.visibleRect), "Sharing anchor belongs to a hidden surface")

        browser.tabs[browser.activeIndex].sort = DirectorySort(field: .name, ascending: false,
                                                             foldersFirst: browser.settings.foldersFirst)
        browser.requestOrdering(); try await settled(browser)
        try require(browser.iconBrowser.itemCount == browser.displayedEntries.count
            && browser.orderedSelectedURLs == [selected.url], "Sorted Icons discarded active selection")
        browser.restoreFileScrollOffset(128)
        let scroll = browser.currentScrollOffset
        browser.saveViewState()
        let sourceTab = browser.activeID, sourceSort = browser.tabs[browser.activeIndex].sort
        browser.newTab(nil)
        browser.navigate(to: .directory(fixture.appendingPathComponent("Empty Folder", isDirectory: true)))
        try await settled(browser)
        browser.selectTab(sourceTab); try await settled(browser)
        try require(browser.usesFileIcons && browser.selectedURLs == [selected.url]
            && browser.tabs[browser.activeIndex].sort == sourceSort
            && abs(browser.currentScrollOffset - scroll) < 2,
            "Returning to an Icons tab lost its selection, sort or native scroll offset")
        browser.folderFilter.selectScope(0)
        browser.focusBrowserContent()
        browser.filterField.stringValue = "Résumé"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        try require(browser.iconBrowser.itemCount == 1 && browser.displayedEntries.first?.url == selected.url,
                    "Shared filename filtering did not update Icons")
        browser.filterField.stringValue = ""
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        if browser.displayedEntries.count > 128 {
            browser.iconBrowser.collectionView.selectAll(nil)
            browser.fileSelectionDidChange()
            let orders = browser.iconBrowser.fullSelectionOrderCount
            browser.refreshStatus()
            _ = browser.commandEnabled(#selector(BrowserViewController.copyFileURLs(_:)))
            _ = browser.commandEnabled(#selector(BrowserViewController.openSelection(_:)))
            _ = browser.fileResponderCommandEnabled(#selector(FileTableView.cut(_:)))
            try require(!browser.canOpenWithSelection && !browser.canShareSelection
                && browser.dragDrop.pasteboardWriter(for: selected.url) == nil
                && browser.iconBrowser.fullSelectionOrderCount == orders,
                "Oversized Icons selection triggered full ordering before drag/menu admission limits")
            let previewOrders = browser.iconBrowser.fullSelectionOrderCount
            _ = browser.commandEnabled(#selector(BrowserViewController.showQuickLook(_:)))
            if browser.selectedItemCount > QuickLookSelectionReader.maximumItems {
                try require(browser.iconBrowser.fullSelectionOrderCount == previewOrders,
                            "Quick Look sorted the full selection beyond its independent preview limit")
            }
        }
        selectFiles([selected.url])
        coordinator.hooks.discover = { _ in await gate.hold(); return [] }
        let menu = coordinator.makeOpenWithMenu()
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Held Icons Open With discovery") { gate.isHeld }
        let menuPresentation = browser.filePresentationID
        mode(.list)
        // Cancellation withdraws the old menu immediately, but the held reader
        // remains tracked until it actually returns. "Preparing" includes that
        // drain; it must not disappear just because the presentation changed.
        try require(browser.filePresentationID != menuPresentation && coordinator.verificationState.preparing
            && browser.orderedSelectedURLs == [selected.url] && browser.iconBrowser.itemCount == 0,
            "View switch failed: changed=\(browser.filePresentationID != menuPresentation), preparing=\(coordinator.verificationState.preparing), selectionMatches=\(browser.orderedSelectedURLs == [selected.url]), iconCount=\(browser.iconBrowser.itemCount), effectiveMode=\(browser.effectiveViewMode)")
        gate.release()
        try await waitUntil("Stale presentation discovery drained") {
            gate.isFinished && !coordinator.verificationState.preparing
        }
        try require(!menu.items.contains(where: { $0.title == "Other…" }),
                    "Stale Icons discovery populated the List view's native menu")
        mode(.icons)
        var shared: [URL] = []
        coordinator.hooks.share = { urls, completion in shared = urls; shareCompletion = completion }
        coordinator.shareSelection()
        try await waitUntil("Injected Icons Share admission") { shareCompletion != nil }
        try require(shared == [selected.url] && coordinator.verificationState.shareAccessRetained,
                    "Shared Share command lost its Icons selection or access lifetime")
        mode(.details)
        try require(coordinator.verificationState.sharing && coordinator.verificationState.shareAccessRetained,
                    "Switching file presentation released a chosen sharing service's access")
        shareCompletion?(nil); shareCompletion = nil
        try await waitUntil("Injected sharing completion releases access") { !coordinator.verificationState.sharing }
        try require(browser.orderedSelectedURLs == [selected.url]
            && browser.activeFileView === browser.table && browser.quickLook.hasReleasedSession,
            "Returning to Details lost selection or retained a stale preview session")
        let checks = [
            "Details/List/Icons share selection, filename filter, sort, tab scroll restoration and native focus without mirroring hidden table selection",
            "Quick Look selection and native Share geometry follow the active file surface",
            "Presentation changes invalidate stale Open With preparation while chosen sharing services retain captured items/access until completion"
        ]
        try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks,
            "notExercised": ["Quick Look panel delivery", "Physical native menus", "External application handoff", "Native sharing picker or recipient delivery"]],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("content-presentation-verification.json"), options: .atomic)
        return checks
    }
}
#endif
