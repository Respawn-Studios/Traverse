import AppKit
import ExplorerCore

@MainActor final class BrowserNameSelection {
    private weak var browser: BrowserViewController?
    private let request = NameSelectionRequest()

    init(browser: BrowserViewController) { self.browser = browser }

    private var archiveTable: ArchiveMetadataTable? {
        guard let browser, browser.isArchiveLocation,
              let owner = browser.archiveTabs[browser.activeID], owner.isPresented else { return nil }
        return owner.table as? ArchiveMetadataTable
    }

    var canPresent: Bool {
        guard let browser, browser.isViewLoaded, let window = browser.view.window else { return false }
        if let archiveTable { return browser.isActiveCommandPane && archiveTable.canSelectByName }
        return request.isIdle && canUseListing(browser) && browser.hasFileCommandFocus
            && window.attachedSheet == nil && !(window.firstResponder is NSTextView)
    }

    func cancel() { request.cancel() }

    func present() {
        guard canPresent, let browser, let parent = browser.view.window else { return }
        if let archiveTable { archiveTable.selectByName(nil); return }
        let tab = browser.activeID
        let visit = browser.sessionID
        let presentation = browser.filePresentationID
        let order = browser.orderRevision
        let selection = browser.selectedURLs
        request.present(in: parent, scope: "Select from the names in the current folder view.",
            entries: browser.displayedEntries, selected: selection, name: { $0.name }, id: { $0.url },
            isCurrent: { [weak self, weak browser, weak parent] in
                guard let self, let browser, let parent else { return false }
                return canUseListing(browser) && browser.hasFileCommandFocus && browser.view.window === parent
                    && browser.activeID == tab && browser.sessionID == visit && browser.filePresentationID == presentation
                    && browser.orderRevision == order && browser.selectedURLs == selection
            }) { [weak browser] next in
            guard let browser else { return }
            browser.focusBrowserContent()
            guard let next else {
                browser.status.stringValue = "No names match in this view."
                return
            }
            browser.updatingSelection = true
            browser.setFileSelection(next)
            browser.updatingSelection = false
            browser.fileSelectionDidChange()
        }
    }

    private func canUseListing(_ browser: BrowserViewController) -> Bool {
        !browser.isBrowserSuspended && browser.isActiveCommandPane
            && !browser.isOfflineCurrentFolder && !browser.isArchiveLocation && !browser.isRemoteLocation
            && !browser.metadataSearch.isShowingResults && browser.location.directoryURL != nil
            && !browser.isLoading && browser.orderingTask == nil && !browser.displayedEntries.isEmpty
    }
}

@MainActor extension BrowserViewController {
    @objc func selectByName(_ sender: Any?) { nameSelection.present() }
}
