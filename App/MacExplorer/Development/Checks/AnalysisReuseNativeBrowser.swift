#if DEBUG
import AppKit
import ExplorerCore

/// Actual local browser/provider listing in an unshown native hierarchy. No
/// injected rows/volumes/selection. Physical pointer delivery is a separate gate.
@MainActor final class AnalysisReuseNativeBrowser {
    let browser: BrowserViewController
    let window: NSWindow
    init() {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.restoresSession = false
        settings.reviewsRecoveryAtStartup = false; settings.folderSummariesEnabled = true
        settings.showsDockProgress = false; settings.motion.mode = .off
        InterfacePresentation.shared.bind(settings)
        StorageChartIntegration.configure(settings: settings)
        browser = BrowserViewController(settings: settings)
        browser.permitsBackgroundVerification = true
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = browser
        window.acceptsMouseMovedEvents = true
    }
    func load(_ authority: AnalysisReuseFixtureAuthority) async throws -> FileEntry {
        var began = false
        browser.didFinishBeginForVerification = { began = true }
        browser.begin()
        try await UIVerification.waitUntil("reuse-browser-native-startup") { began && !self.browser.isLoading && !self.browser.volumes.isEmpty }
        browser.didFinishBeginForVerification = nil
        browser.navigate(to: .directory(authority.fixture))
        try await UIVerification.settled(browser)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let entry = browser.displayedEntries.first(where: { $0.name == "Root-0" && $0.url.standardizedFileURL.path == authority.roots[0].standardizedFileURL.path && $0.kind == .directory }) else {
            throw UIVerification.Failure(message: "reuse-native-generated-row-required")
        }
        try UIVerification.require(browser.displayedEntries.count == 5 && browser.issueCount == 0
            && browser.loadError == nil && browser.summaryBrowsingAccess != nil, "reuse-native-generated-listing-incomplete")
        return entry
    }
    func drain() async {
        browser.didFinishBeginForVerification = nil
        let listing = browser.listingTask, ordering = browser.orderingTask, sidebar = browser.sidebarTasks
        browser.suspendBrowser()
        await listing?.value; await ordering?.value
        for task in sidebar { await task.value }
        await browser.flushBrowserSession()
        browser.volumeObservers.removeAll()
        browser.settingsWindow?.close(); window.close()
    }
}
#endif
