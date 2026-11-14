import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// A cached UI selection, never filesystem authority. The upload planner
/// observes sources afresh and checks their kind against this explicit intent.
@MainActor final class LocalPaneUploadSelection {
    let id = UUID(), urls: [URL], kinds: [SFTPUploadBatchItem.Kind]
    private weak var browser: BrowserViewController?
    private let tab: UUID, visit: UUID, directory: URL
    init?(browser: BrowserViewController) {
        guard let directory = browser.location.directoryURL else { return nil }
        let urls = browser.orderedSelectedURLs(upTo: 129)
        guard (1...128).contains(urls.count), Set(urls).count == urls.count else { return nil }
        var kinds: [SFTPUploadBatchItem.Kind] = []
        for url in urls {
            guard BrowserLocation.directory(url.deletingLastPathComponent()) == .directory(directory),
                  let row = browser.rowsByURL[url], browser.displayedEntries.indices.contains(row) else { return nil }
            switch browser.displayedEntries[row].kind {
            case .file: kinds.append(.file)
            case .directory: kinds.append(.folder)
            default: return nil
            }
        }
        self.browser = browser; self.directory = directory; self.urls = urls; self.kinds = kinds
        tab = browser.activeID; visit = browser.sessionID
        guard isCurrent else { return nil }
    }
    var hasFolders: Bool { kinds.contains(.folder) }
    var isCurrent: Bool {
        guard let browser, !browser.isBrowserSuspended, !browser.isOfflineCurrentFolder, !browser.isReadOnlyFileSession,
              !browser.metadataSearch.isShowingResults, browser.activeID == tab, browser.sessionID == visit,
              browser.location.directoryURL == directory, browser.workspace?.browsers[browser.paneID] === browser,
              browser.orderedSelectedURLs(upTo: 129) == urls else { return false }
        return zip(urls, kinds).allSatisfy { url, kind in
            guard let row = browser.rowsByURL[url], browser.displayedEntries.indices.contains(row) else { return false }
            return browser.displayedEntries[row].kind == (kind == .folder ? .directory : .file)
        }
    }
    func acquireAccess() async -> FileAccessLifetimes {
        guard isCurrent, let browser else { return .init(leases: []) }
        return await browser.accessLifetime(for: urls)
    }
    func accepts(_ plan: SMBUploadGroupPlan) -> Bool {
        plan.items.count == urls.count && zip(plan.items, zip(urls, kinds)).allSatisfy { item, expected in
            item.name == expected.0.lastPathComponent && (item.kind == .folder) == (expected.1 == .folder)
        }
    }
    func accepts(_ plan: SFTPUploadBatchPlan) -> Bool {
        plan.items.count == urls.count && zip(plan.items, zip(urls, kinds)).allSatisfy { item, expected in
            item.name == expected.0.lastPathComponent && item.kind == expected.1
        }
    }
}

