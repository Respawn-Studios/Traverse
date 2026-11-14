import AppKit
import ExplorerCore
import LocalStorage

#if DEBUG
@MainActor
private final class VolumeStartupBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { isOpen = true; continuation?.resume(); continuation = nil }
}

@MainActor
extension UIVerification {
    static func verifyTabManagement(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String] {
        try await verifyColdStartVolumeHandoff(fixture: fixture)
        try await verifyPaneVolumeSharing(fixture: fixture)
        try await verifyPaneTabCloseControls()
        let originalTabs = browser.tabs, originalID = browser.activeID, originalClosed = browser.closedTabs
        let originalBackground = browser.permitsBackgroundVerification
        browser.permitsBackgroundVerification = true
        defer {
            browser.operationPreparationTask = nil
            browser.tabs = originalTabs; browser.activeID = originalID; browser.closedTabs = originalClosed
            browser.permitsBackgroundVerification = originalBackground
            browser.loadLocation()
        }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        browser.folderFilter.selectScope(0)
        browser.focusBrowserContent()
        browser.filterField.stringValue = "Résumé"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        try require(browser.displayedEntries.count == 1, "Tab fixture filter failed")
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser.saveViewState()
        let source = browser.tabs[browser.activeIndex]
        browser.duplicateTab(id: source.id)
        try await settled(browser)
        let duplicate = browser.tabs[browser.activeIndex]
        try require(duplicate.id != source.id && duplicate.location == source.location
            && duplicate.filter == source.filter && duplicate.sort == source.sort
            && duplicate.state.selection == source.state.selection && !duplicate.canGoBack && !duplicate.canGoForward,
            "Duplicate did not preserve current view state with independent identity/history")
        let visit = browser.sessionID, selected = browser.selectedURLs
        browser.moveTab(id: duplicate.id, before: source.id)
        try require(browser.activeID == duplicate.id && browser.sessionID == visit && browser.selectedURLs == selected
            && browser.tabs.firstIndex(where: { $0.id == duplicate.id })! < browser.tabs.firstIndex(where: { $0.id == source.id })!,
            "Reordering changed the active visit, selection or insertion order")
        browser.tabs[browser.activeIndex].filter = "independent duplicate filter"
        try require(browser.tabs.first(where: { $0.id == source.id })?.filter == "Résumé",
                    "Duplicate shares future filter state")
        // Restore the visible filter before closing, as a real edit would do.
        browser.tabs[browser.activeIndex].filter = "Résumé"
        browser.closeTab(id: duplicate.id)
        try await settled(browser)
        try require(browser.closedTabs.last?.filter == "Résumé", "Close did not retain its current state")
        browser.reopenClosedTab()
        try await settled(browser)
        let reopened = browser.tabs[browser.activeIndex]
        try require(reopened.id != duplicate.id && reopened.id != source.id && reopened.location == source.location
            && reopened.filter == "Résumé" && reopened.state.selection == source.state.selection && !reopened.canGoBack,
            "Reopened tab reused identity, history, or lost its current state")
        let beforeBusy = browser.tabs.map(\.id), closedBeforeBusy = browser.closedTabs.count
        browser.operationPreparationTask = Task {}
        browser.duplicateTab(id: browser.activeID)
        browser.closeTab(id: browser.activeID)
        browser.reopenClosedTab()
        browser.moveTab(id: browser.activeID, before: nil)
        try require(browser.tabs.map(\.id) == beforeBusy && browser.closedTabs.count == closedBeforeBusy,
                    "Tab management changed operation ownership while busy")
        browser.operationPreparationTask = nil
        browser.closedTabs.removeAll()
        for _ in 0..<12 {
            let tab = BrowserTab(location: .computer)
            browser.tabs.append(tab)
            browser.closeTab(id: tab.id)
        }
        try require(browser.closedTabs.count == 10, "Closed-tab history exceeded its session bound")
        if browser.view.window?.isVisible == true {
            browser.focusLocation(nil)
            let editingIDs = browser.tabs.map(\.id)
            let intercepted = browser.handleExplorerShortcut(key("t", code: 17, flags: [.control, .shift], window: browser.view.window!))
            try require(!intercepted && browser.tabs.map(\.id) == editingIDs,
                        "Reopen Control alias intercepted a native text editor")
        }
        browser.focusBrowserContent()
        let file = BrowserMenus.menu(.file, target: browser)
        let reopen = BrowserMenus.commandItem(#selector(BrowserViewController.reopenClosedTab(_:)), in: file)
        try require(file.items.count <= 36 && file.item(withTitle: "Tabs")?.submenu != nil
            && file.item(withTitle: "Archives")?.submenu != nil, "File menu exceeds its compact native layout")
        try require(reopen?.keyEquivalent == "t" && reopen?.keyEquivalentModifierMask == [.command, .shift],
            "Reopen Closed Tab is absent from native command menus")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("tabs-management.png"))
        let report: [String: Any] = ["passed": true, "mode": "controlled-native-tab-management",
            "closedHistoryLimit": 10, "persistentClosedHistory": false,
            "notExercised": ["Physical tab dragging", "Physical tab context menu", "Native keyboard event delivery"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("tabs-management.json"), options: .atomic)
        return ["Tab duplication and reopening preserve current view state with independent identity/history",
                "Tab reorder retains its visit/selection, closed history stays bounded, busy writes and native text editing remain protected"]
    }

    private enum ColdStartVolumeCase: CaseIterable, Equatable {
        case beforePeerReferences, afterPeerReferences, inFlightRead, failureRetry
    }

    private static func verifyColdStartVolumeHandoff(fixture: URL) async throws {
        for scenario in ColdStartVolumeCase.allCases {
            try await verifyColdStartVolumeHandoff(fixture: fixture, scenario: scenario)
        }
    }

    private static func verifyColdStartVolumeHandoff(fixture: URL, scenario: ColdStartVolumeCase) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        let tab = BrowserTab(location: .directory(fixture))
        primary.tabs = [tab]; primary.activeID = tab.id
        let known = [VolumeInfo(url: fixture, name: "Generated bootstrap location", kind: .externalDisk)]
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.contentViewController = workspace; window.setContentSize(NSSize(width: 1300, height: 780))
        let originalBarrier = VolumeStartupBarrier(), peerBarrier = VolumeStartupBarrier(), readBarrier = VolumeStartupBarrier()
        var finished: Set<UUID> = [], reads = 0, activeReads = 0, maximumActiveReads = 0
        if scenario == .afterPeerReferences || scenario == .inFlightRead || scenario == .failureRetry { peerBarrier.release() }
        if scenario == .inFlightRead || scenario == .failureRetry { originalBarrier.release() }
        workspace.willStartBrowserForVerification = { browser in
            browser.permitsBackgroundVerification = true
            let isOriginal = browser === primary
            let barrier = isOriginal ? originalBarrier : peerBarrier
            let id = browser.paneID
            browser.beforeBeginReferencesForVerification = { await barrier.wait() }
            browser.didFinishBeginForVerification = { finished.insert(id) }
            browser.readVolumesForVerification = {
                reads += 1; activeReads += 1; maximumActiveReads = max(maximumActiveReads, activeReads)
                defer { activeReads -= 1 }
                if (scenario == .afterPeerReferences || scenario == .inFlightRead) && isOriginal { await readBarrier.wait() }
                if scenario == .failureRetry && reads == 1 { throw Failure(message: "Generated initial observation failure") }
                return known
            }
        }
        defer {
            workspace.isClosing = true
            originalBarrier.release(); peerBarrier.release(); readBarrier.release()
            workspace.willStartBrowserForVerification = nil
            for browser in workspace.browsers.values { browser.suspendBrowser() }
            window.close()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.startBrowser(primary)
        try await waitForVolumeStartup("Original begin barrier did not enter") { originalBarrier.entered }
        if scenario == .inFlightRead {
            try await waitForVolumeStartup("Initial controlled volume read did not enter") { readBarrier.entered }
        }
        if scenario == .failureRetry {
            try await waitForVolumeStartup("Failed bootstrap did not finish") {
                finished.contains(primary.paneID) && reads == 1 && !workspace.hasInitialVolumeBootstrapForVerification
            }
            try require(primary.volumes.isEmpty && initialVolumeHint(in: primary) != nil,
                        "Failed cold-start discovery had no honest Locations-unavailable retry hint")
            primary.rebuildSidebar()
            try require(initialVolumeHint(in: primary) != nil, "Sidebar rebuild discarded failed startup observation hint")
            for _ in 0..<3 { workspace.requestInitialVolumeObservationIfNeeded() }
            try require(reads == 1, "Failed initial observation automatically retried instead of requiring explicit retry")
        }
        try require(workspace.splitActive(at: .trailing), "Cold-start handoff fixture could not split")
        let peer = workspace.activeBrowser
        try await waitForVolumeStartup("Peer begin barrier did not enter") { peerBarrier.entered }
        if scenario != .beforePeerReferences {
            try await waitForVolumeStartup("Peer reference startup did not finish") { finished.contains(peer.paneID) }
        }
        if scenario == .afterPeerReferences {
            try await waitForVolumeStartup("Peer startup did not claim initial observation for the held primary") { readBarrier.entered }
        }
        workspace.activate(primary)
        try require(workspace.closeActivePane(), "Cold-start original primary could not retire")
        if scenario == .afterPeerReferences || scenario == .inFlightRead {
            try require(reads == 1 && activeReads == 1,
                        "Retirement started another bootstrap read before the old read settled")
        }
        peerBarrier.release(); originalBarrier.release(); readBarrier.release()
        try await waitForVolumeStartup("Controlled cold-start tasks did not finish") {
            finished.contains(primary.paneID) && finished.contains(peer.paneID) && !workspace.hasInitialVolumeBootstrapForVerification
        }
        if scenario == .failureRetry {
            try require(reads == 1 && initialVolumeHint(in: peer) != nil,
                        "Failed initial observation retried on pane handoff or lost its active retry hint")
            try await settled(peer)
            let computer = BrowserTab(location: .computer)
            peer.tabs = [computer]; peer.activeID = computer.id
            peer.updateNavigation(); peer.updateFilePresentationVisibility()
            guard let refresh = peer.navigationButtons.first(where: { $0.1 == #selector(BrowserViewController.refresh(_:)) })?.0,
                  refresh.isEnabled else { throw Failure(message: "Explicit This Mac Refresh control was unavailable") }
            refresh.performClick(nil)
            try await waitForVolumeStartup("Explicit native Refresh did not recover initial observation") {
                reads == 2 && peer.volumes == known && !peer.isLoading
            }
            try require(initialVolumeHint(in: peer) == nil && maximumActiveReads == 1,
                        "Successful explicit retry retained the unavailable hint or overlapped bootstrap workers")
        } else {
            let expected = scenario == .afterPeerReferences || scenario == .inFlightRead ? 2 : 1
            try require(reads == expected && maximumActiveReads == 1 && peer.volumes == known
                        && peer.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.count == 1,
                        "Retiring the original primary during remembered-reference startup left survivor Locations unobserved")
        }
    }

    private static func initialVolumeHint(in browser: BrowserViewController) -> SidebarNode? {
        browser.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.first(where: {
            $0.title.hasPrefix("Locations unavailable") && $0.location == nil && $0.children?.isEmpty == true
        })
    }

    private static func waitForVolumeStartup(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(condition(), message)
    }

    private static func verifyPaneVolumeSharing(fixture: URL) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        let tab = BrowserTab(location: .directory(fixture))
        primary.tabs = [tab]; primary.activeID = tab.id
        let known = [VolumeInfo(url: fixture, name: "Generated mounted location", kind: .externalDisk)]
        primary.volumes = known
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 1300, height: 780))
        defer {
            workspace.isClosing = true
            for browser in workspace.browsers.values { browser.suspendBrowser() }
            window.close()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        primary.rebuildSidebar()
        try require(workspace.splitActive(at: .trailing), "Volume-sharing fixture failed to split")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true
        try await settled(peer)
        try require(peer.volumes == known && peer.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.map(\.title) == known.map(\.name),
                    "Directory split lost known mounted Locations when the active sidebar changed panes")
        // Both completions still pass their independent browser token guards:
        // a primary request started first, then a peer request observed unmount.
        // Deliver the peer completion first and the older primary completion
        // last through the real attached workspace request/result seam.
        let earlierPrimaryToken = UUID(), newerPeerToken = UUID()
        primary.volumeSessionID = earlierPrimaryToken
        peer.volumeSessionID = newerPeerToken
        guard let earlierRequest = workspace.beginVolumeRefresh(from: primary),
              let newerRequest = workspace.beginVolumeRefresh(from: peer) else {
            throw Failure(message: "Attached pane request tickets were unavailable")
        }
        try require(workspace.completeVolumeRefresh(.success([]), from: peer, ticket: newerRequest),
                    "Newer peer volume result was refused")
        try require(primary.volumes.isEmpty, "Newer peer unmount observation did not publish")
        try require(primary.volumeSessionID == earlierPrimaryToken && peer.volumeSessionID == newerPeerToken,
                    "Controlled request-order fixture unexpectedly invalidated a browser token")
        try require(!workspace.completeVolumeRefresh(.success(known), from: primary, ticket: earlierRequest)
                    && primary.volumes.isEmpty && peer.volumes.isEmpty
                    && peer.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.isEmpty == true,
                    "Older primary refresh completion re-added mounted Locations after newer peer unmount observation")
        try require(!workspace.completeVolumeRefresh(.failure("Generated stale error"), from: primary, ticket: earlierRequest),
                    "Older primary error retained publication authority after newer success")
        // Success with an empty snapshot represents unmount, not unknown data.
        guard let emptyRequest = workspace.beginVolumeRefresh(from: primary) else { throw Failure(message: "Empty observation could not start") }
        try require(workspace.completeVolumeRefresh(.success([]), from: primary, ticket: emptyRequest), "Empty observation was refused")
        try require(peer.volumes.isEmpty && peer.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.isEmpty == true,
                    "Successful empty volume observation did not clear other pane Locations")
        guard let restoredRequest = workspace.beginVolumeRefresh(from: primary) else { throw Failure(message: "Restored observation could not start") }
        try require(workspace.completeVolumeRefresh(.success(known), from: primary, ticket: restoredRequest), "Restored observation was refused")
        workspace.activate(primary)
        try require(workspace.closeActivePane(), "Volume-sharing origin could not retire")
        try require(workspace.splitActive(at: .bottom), "Volume-sharing survivor could not split")
        let later = workspace.activeBrowser
        later.permitsBackgroundVerification = true
        try await settled(later)
        try require(later.volumes == known && later.sidebarRoots.first(where: { $0.title == "Locations" })?.children?.count == 1,
                    "Known Locations snapshot vanished after its original pane retired")
        try verifyVolumeTerminalOrdering(workspace, computer: peer, source: later, known: known)
    }

    /// The real async refresh delegates to this exact request/result seam.
    /// Deliver controlled results without making a volume query or mounting data.
    private static func verifyVolumeTerminalOrdering(_ workspace: BrowserWorkspaceController,
                                                     computer: BrowserViewController,
                                                     source: BrowserViewController, known: [VolumeInfo]) throws {
        let tab = BrowserTab(location: .computer)
        computer.tabs = [tab]; computer.activeID = tab.id
        computer.updateNavigation(); computer.updateFilePresentationVisibility()
        computer.isLoading = true; computer.loadError = nil
        source.isLoading = true
        let directoryError = source.loadError
        guard let old = workspace.beginVolumeRefresh(from: computer),
              let newest = workspace.beginVolumeRefresh(from: source) else {
            throw Failure(message: "Controlled terminal-order requests could not start")
        }
        try require(!workspace.completeVolumeRefresh(.success([]), from: computer, ticket: old)
                    && computer.isLoading && computer.loadError == nil && computer.volumes == known,
                    "Old completion changed source data or ended a loader while newer shared observation was pending")
        try require(!workspace.completeVolumeRefresh(.success([]), from: computer, ticket: newest),
                    "Another browser used the latest owner's ticket")
        let message = "Generated newest volume observation failure"
        try require(workspace.completeVolumeRefresh(.failure(message), from: source, ticket: newest)
                    && !computer.isLoading && computer.loadError == message && computer.volumes == known
                    && source.isLoading && source.loadError == directoryError,
                    "Newest volume failure did not end waiting This Mac views with retained cache, or changed directory listing state")
        try require(!workspace.completeVolumeRefresh(.failure("Generated older error"), from: computer, ticket: old)
                    && !workspace.completeVolumeRefresh(.success([]), from: computer, ticket: old)
                    && computer.loadError == message && computer.volumes == known,
                    "Old error/success replaced the newer shared failure/cache")
        source.isLoading = false
        computer.volumeBrowser.setSelection(Set(known.map(\.url)))
        let selected = computer.volumeBrowser.selectedURLs
        guard let recovery = workspace.beginVolumeRefresh(from: source) else { throw Failure(message: "Recovery observation could not start") }
        try require(computer.isLoading && computer.loadError == nil && computer.overlay.isHidden
                    && computer.volumeBrowser.selectedURLs == selected && !selected.isEmpty,
                    "Refresh retry did not clear the prior error overlay and show pending state with valid selection retained")
        try require(workspace.completeVolumeRefresh(.success(known), from: source, ticket: recovery)
                    && !computer.isLoading && computer.loadError == nil && computer.volumeBrowser.selectedURLs == selected,
                    "Newest successful observation did not clear the prior shared volume error")
        try require(!workspace.completeVolumeRefresh(.failure("Generated duplicate completion"), from: source, ticket: recovery)
                    && computer.loadError == nil, "Consumed request ticket accepted a duplicate completion")
        try require(!workspace.cancelVolumeRefresh(from: source, ticket: recovery) && computer.loadError == nil,
                    "Cancellation of a consumed ticket changed the accepted success")

        computer.isLoading = true
        guard let oldCancelled = workspace.beginVolumeRefresh(from: computer),
              let latestCancelled = workspace.beginVolumeRefresh(from: source) else {
            throw Failure(message: "Cancellation-order observations could not start")
        }
        try require(!workspace.cancelVolumeRefresh(from: computer, ticket: oldCancelled) && computer.isLoading,
                    "An older cancellation terminated a newer shared observation")
        try require(workspace.cancelVolumeRefresh(from: source, ticket: latestCancelled)
                    && !computer.isLoading && computer.loadError?.contains("interrupted") == true,
                    "Latest cancellation left an older This Mac loader waiting")
        try require(!workspace.completeVolumeRefresh(.success([]), from: source, ticket: latestCancelled)
                    && !workspace.completeVolumeRefresh(.success([]), from: computer, ticket: oldCancelled)
                    && computer.volumes == known,
                    "Cancelled or older result regained publication authority")
        guard let resumed = workspace.beginVolumeRefresh(from: source) else { throw Failure(message: "Post-cancellation observation could not start") }
        try require(workspace.completeVolumeRefresh(.success(known), from: source, ticket: resumed),
                    "Normal Refresh-equivalent could not recover from shared cancellation")

        // Retire the latest query owner while another pane is still waiting on
        // its older request. Neither stale completion may revive authority.
        computer.isLoading = true
        guard let waiting = workspace.beginVolumeRefresh(from: computer),
              let retiring = workspace.beginVolumeRefresh(from: source) else {
            throw Failure(message: "Retirement observation could not start")
        }
        workspace.activate(source)
        try require(workspace.closeActivePane() && workspace.browsers[source.paneID] == nil
                    && !computer.isLoading && computer.loadError?.contains("interrupted") == true
                    && computer.volumes == known,
                    "Latest volume owner retirement left an older This Mac loader waiting indefinitely or lost retained cache")
        try require(!workspace.completeVolumeRefresh(.success([]), from: source, ticket: retiring)
                    && !workspace.completeVolumeRefresh(.success([]), from: computer, ticket: waiting)
                    && computer.loadError?.contains("interrupted") == true && computer.volumes == known,
                    "Retired or older completion revived authority after latest-owner teardown")
        guard let closing = workspace.beginVolumeRefresh(from: computer) else { throw Failure(message: "Window-close observation could not start") }
        workspace.isClosing = true
        try require(!workspace.completeVolumeRefresh(.success([]), from: computer, ticket: closing)
                    && workspace.beginVolumeRefresh(from: computer) == nil && computer.volumes == known,
                    "Closing workspace retained volume request/result authority")
    }

    /// Drive the real close NSButton after the same pane activation performed
    /// by BrowserWindow.sendEvent, rather than calling closeTab directly.
    private static func verifyPaneTabCloseControls() async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        let first = BrowserTab(location: .computer), second = BrowserTab(location: .computer)
        primary.tabs = [first, second]; primary.activeID = first.id
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.workspace = workspace
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 1300, height: 780))
        defer {
            workspace.isClosing = true
            for browser in workspace.browsers.values { browser.suspendBrowser() }
            window.close()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        primary.loadLocation()
        try await settled(primary)
        try require(workspace.splitActive(at: .trailing), "Close-control fixture failed to split: tree=\(workspace.paneTreeHost.bounds.size), canChange=\(workspace.canChangePaneLayout), status=\(primary.status.stringValue)")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true
        try await settled(peer)
        // A background listing completion refreshes availability while its pane
        // is inactive. The next click must activate and close in one gesture.
        primary.validateNavigationButtons()
        guard let close = primary.tabStrip.closeButton(for: second.id) else {
            throw Failure(message: "Inactive pane has no native close control")
        }
        let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        workspace.activatePane(at: point)
        close.performClick(nil)
        try require(!primary.tabs.contains(where: { $0.id == second.id }) && primary.activeID == first.id,
                    "First close-button click after inactive-pane focus did not close its background tab")
        primary.tabs.append(second); primary.tabStrip.update(tabs: primary.tabs, activeID: first.id)
        workspace.activate(peer)
        primary.validateNavigationButtons()
        workspace.activatePane(at: point)
        primary.tabStrip.closeButton(for: first.id)?.performClick(nil)
        try await settled(primary)
        try require(primary.tabs.map(\.id) == [second.id] && primary.activeID == second.id,
                    "First close-button click after pane focus did not close the selected tab")
        let count = workspace.browsers.count
        primary.operationPreparationTask = Task {}
        primary.validateNavigationButtons()
        primary.tabStrip.closeButton(for: second.id)?.performClick(nil)
        try require(primary.tabs.map(\.id) == [second.id] && workspace.browsers.count == count,
                    "Native close control bypassed operation preparation")
        primary.operationPreparationTask = nil
        primary.validateNavigationButtons()
        primary.tabStrip.closeButton(for: second.id)?.performClick(nil)
        try require(workspace.browsers[primary.paneID] == nil && workspace.activeBrowser.closedTabs.last != nil,
                    "Native last-tab Close did not collapse the pane and retain Reopen history")
    }
}
#endif
