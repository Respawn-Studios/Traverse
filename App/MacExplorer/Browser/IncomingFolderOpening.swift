import AppKit
import ExplorerCore

private struct IncomingFolderProbeResult: Sendable {
    let url: URL
    let access: FolderAccessLease
}

private final class IncomingFolderProbe: Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.IncomingFolderProbe", qos: .userInitiated)
    private let activity: FileActivityGate
    #if DEBUG
        private let beforeRead: (@Sendable () -> Void)?
        init(activity: FileActivityGate, beforeRead: (@Sendable () -> Void)? = nil) {
            self.activity = activity
            self.beforeRead = beforeRead
        }
    #else
        init(activity: FileActivityGate) { self.activity = activity }
    #endif
    enum Failure: Error { case unsupportedFolder }
    func inspect(_ url: URL) async throws -> IncomingFolderProbeResult {
        let activity = try activity.begin()
        #if DEBUG
            let beforeRead = beforeRead
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                defer { withExtendedLifetime(activity) {} }
                do {
                    #if DEBUG
                        beforeRead?()
                    #endif
                    let access = FolderAccessLease(url: url, backend: SystemFolderAccessBackend())
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
                    ])
                    guard values.isDirectory == true, values.isPackage != true,
                        values.isSymbolicLink != true, values.isAliasFile != true
                    else { throw Failure.unsupportedFolder }
                    continuation.resume(returning: IncomingFolderProbeResult(url: url, access: access))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Bounded cold/warm application-open delivery. No default-handler changes,
/// bookmarks, remembrance, scan or file operation are performed here.
@MainActor final class IncomingFolderOpening {
    private let probe: IncomingFolderProbe
    private weak var controller: BrowserWindowController?
    private var pending: [URL] = []
    private var activeURL: URL?
    private var work: Task<Void, Never>?
    private var closed = false
    private(set) var receivedExplicitRequest = false
    private(set) var lastNotice: String?
    private(set) var openedCount = 0
    #if DEBUG
        var beforePublication: (@MainActor () async -> Void)?
        init(activity: FileActivityGate = ApplicationFileActivity.gate, beforeRead: (@Sendable () -> Void)? = nil) {
            probe = IncomingFolderProbe(activity: activity, beforeRead: beforeRead)
        }
    #else
        init() { probe = IncomingFolderProbe(activity: ApplicationFileActivity.gate) }
    #endif
    func attach(_ controller: BrowserWindowController) {
        self.controller = controller
        if receivedExplicitRequest { controller.workspace.hasIncomingFolderRequest = true }
        schedule()
    }
    func receive(_ urls: [URL]) {
        guard !closed else { return }
        do {
            let accepted = try IncomingFolderURLs.admit(urls)
            var keys = Set((pending + (activeURL.map { [$0] } ?? [])).map { $0.standardizedFileURL.path })
            let fresh = accepted.filter { keys.insert($0.standardizedFileURL.path).inserted }
            guard pending.count + fresh.count + (activeURL == nil ? 0 : 1) <= IncomingFolderURLs.maximumBatch else {
                throw IncomingFolderURLs.Failure.batchLimit
            }
            pending += fresh
            receivedExplicitRequest = true
            controller?.workspace.hasIncomingFolderRequest = true
            if let controller, controller.workspace.isClosing {
                controller.resumeBrowsing()
            }
            schedule()
        } catch {
            notice(
                "Open up to 16 local folders at a time. Files, packages, links and other URL types are not opened by this request."
            )
        }
    }
    func closeAndDrain() async {
        closed = true
        pending.removeAll()
        work?.cancel()
        await work?.value
    }
    func resume() {
        closed = false
        schedule()
    }
    private func notice(_ value: String) {
        lastNotice = value
        controller?.browser.status.stringValue = value
    }
    private func schedule() {
        guard !closed, work == nil, controller != nil, !pending.isEmpty else { return }
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.work = nil }
            guard let controller = self.controller else { return }
            await controller.workspace.startupTask?.value
            while !self.closed, !Task.isCancelled, !self.pending.isEmpty {
                let url = self.pending.removeFirst()
                let browser = controller.browser
                self.activeURL = url
                defer { self.activeURL = nil }
                guard self.canPublish(in: browser), browser.tabs.count < 32 else {
                    self.notice(
                        "The folder request could not open while this window is busy or full. Open it again when ready."
                    )
                    self.pending.removeAll()
                    return
                }
                let visit = browser.sessionID
                let pane = browser.paneID
                let tab = browser.activeID
                do {
                    let result = try await self.probe.inspect(url)
                    #if DEBUG
                        if let beforePublication = self.beforePublication { await beforePublication() }
                    #endif
                    guard !self.closed, !Task.isCancelled, self.canPublish(in: browser), controller.browser === browser,
                        browser.paneID == pane, browser.activeID == tab, browser.sessionID == visit
                    else {
                        self.notice(
                            "The folder request was cancelled because browsing changed. Open it again when ready.")
                        continue
                    }
                    guard browser.folderAccess.acceptOpenedFolder(result.url, retaining: result.access) else {
                        self.notice(
                            "This session has reached its incoming-folder access limit. Choose the folder explicitly to continue."
                        )
                        continue
                    }
                    browser.saveViewState()
                    if let same = browser.tabs.first(where: {
                        $0.location.directoryURL?.standardizedFileURL.path == result.url.standardizedFileURL.path
                    }) {
                        browser.selectTab(same.id)
                    } else if browser.tabs.count == 1, browser.location == .computer,
                        controller.workspace.browsers.count == 1
                    {
                        browser.navigate(to: .directory(result.url))
                    } else {
                        let fresh = BrowserTab(location: .directory(result.url))
                        browser.tabs.append(fresh)
                        browser.activeID = fresh.id
                        browser.loadLocation(animatingTab: true)
                    }
                    self.openedCount += 1
                    withExtendedLifetime(result.access) {}
                    if !browser.isControlledVerification {
                        controller.showWindow(nil)
                        controller.window?.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    browser.focusBrowserContent()
                } catch {
                    self.notice(
                        "The requested folder is unavailable, is a package or link, or access was denied. Choose a folder to grant access if needed."
                    )
                }
            }
        }
    }
    private func canPublish(in browser: BrowserViewController) -> Bool {
        browser.canOpenBrowserTab && !browser.hasExclusiveBrowserOperation && browser.cutPreparationTask == nil
            && browser.workspace?.isClosing != true && !browser.operationCoordinator.drives.isBusy
    }
    #if DEBUG
        func waitForVerification() async { while let work { await work.value } }
    #endif
}
