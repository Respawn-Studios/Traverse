import AppKit
import ExplorerCore
import StorageAnalysis

@MainActor
extension BrowserViewController {
    func performAnalysisLocationAction(_ action: StoredLocationAction, location: ResolvedAnalysisLocation) -> String {
        guard !isBrowserSuspended, let window = view.window, window.isVisible, window.attachedSheet == nil else {
            return "The original browser is unavailable. Reopen Storage Analysis from a browser window."
        }
        switch action {
        case .showInExplorer:
            guard canOpenBrowserTab else { return "Close a tab before opening this location." }
            let directory = location.isSourceRoot ? location.url : location.url.deletingLastPathComponent()
            var tab = BrowserTab(location: .directory(directory))
            if !location.isSourceRoot { tab.state.selection = [location.url] }
            saveViewState(); tabs.append(tab); activeID = tab.id
            workspace?.activate(self, focus: false)
            window.makeKeyAndOrderFront(nil); loadLocation(); focusBrowserContent()
            return "Opened the recorded location in a new Explorer tab."
        case .properties:
            propertiesController.show(urls: [location.url], relativeTo: window)
            return "Opened Properties for the recorded item."
        case .copyPath:
            let publication = clipboardWriter(location.url.path, [])
            if case .text = publication { return "Path copied." }
            return "The clipboard could not be updated."
        case .reviewTrash:
            return "Review selected cleanup from the full Storage Analysis window."
        }
    }
}
