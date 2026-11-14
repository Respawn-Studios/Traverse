import Foundation

/// One cached local UI selection. The concrete transfer owner observes the file
/// again; this object supplies neither a native reference nor write authority.
@MainActor final class LocalPaneFileSelection {
    weak var browser: BrowserViewController?
    let url: URL, tab: UUID, visit: UUID, directory: URL
    let isFolder: Bool
    init(browser: BrowserViewController, url: URL, directory: URL, isFolder: Bool = false) {
        self.browser = browser; self.url = url; self.directory = directory; self.isFolder = isFolder
        tab = browser.activeID; visit = browser.sessionID
    }
    var isCurrent: Bool {
        guard let browser, !browser.isBrowserSuspended, !browser.isOfflineCurrentFolder, !browser.isReadOnlyFileSession,
              !browser.metadataSearch.isShowingResults, browser.activeID == tab, browser.sessionID == visit,
              browser.location.directoryURL == directory, browser.workspace?.browsers[browser.paneID] === browser,
              browser.orderedSelectedURLs(upTo: 2) == [url], let index = browser.rowsByURL[url],
              browser.displayedEntries.indices.contains(index) else { return false }
        return browser.displayedEntries[index].kind == (isFolder ? .directory : .file)
    }
    func acquireAccess() async -> FileAccessLifetimes {
        guard isCurrent, let browser else { return .init(leases: []) }
        return await browser.accessLifetime(for: [url])
    }
}
