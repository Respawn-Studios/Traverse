#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore

@MainActor
private final class WorkspaceFixtureTabDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var draggingLocation = NSPoint.zero
    var draggingDestinationWindow: NSWindow?
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?, sequence: Int, allowed: NSDragOperation = .move) {
        draggingPasteboard = board; draggingSource = source; draggingSequenceNumber = sequence; draggingSourceOperationMask = allowed
        super.init()
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
enum WorkspaceNavigationVerification {
    struct Outcome {
        let checks: [String]
        let clips: [[String: Any]]
    }
    static func run(in testRoot: URL, settings inheritedSettings: BrowserSettings? = nil) async throws -> Outcome {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Workspace verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("workspace-navigation-\(UUID().uuidString)", isDirectory: true)
        let firstFolder = owned.appendingPathComponent("Folder A", isDirectory: true)
        let secondFolder = owned.appendingPathComponent("Folder B", isDirectory: true)
        let firstFile = firstFolder.appendingPathComponent("alpha Café.txt")
        let secondFile = secondFolder.appendingPathComponent("beta.txt")
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-workspace-navigation-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try manager.createDirectory(at: firstFolder, withIntermediateDirectories: false)
            try manager.createDirectory(at: secondFolder, withIntermediateDirectories: false)
            try Data("generated workspace A".utf8).write(to: firstFile, options: .withoutOverwriting)
            try Data("generated workspace B".utf8).write(to: secondFile, options: .withoutOverwriting)
        }.value
        let settings = inheritedSettings ?? BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        var history = BrowserTab(location: .computer)
        history.navigate(to: .directory(firstFolder))
        history.filter = "alpha"
        history.sort = DirectorySort(field: .size, ascending: false)
        history.state = NavigationState(selection: [firstFile], scrollOffset: 0)
        let spare = BrowserTab(location: .computer)
        primary.tabs = [history, spare]; primary.activeID = history.id
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        var allocationTrace: [[String: Any]] = []
        var constructedHostCount = 0
        var intendedInitialAllocation = false
        var earlyContentContained = false
        func allocationFacts(_ host: PaneHostView, _ browser: BrowserViewController, stage: String) -> [String: Any] {
            func rect(_ view: NSView?) -> [String: Double] {
                guard let view else { return [:] }
                let frame = view.frame
                return ["x": Double(frame.minX), "y": Double(frame.minY),
                        "width": Double(frame.width), "height": Double(frame.height)]
            }
            return ["stage": stage, "host": rect(host), "browser": rect(browser.view),
                    "body": rect(browser.paneBody), "navigation": rect(browser.navigationSurface),
                    "split": rect(browser.splitController.view)]
        }
        workspace.didConstructPaneHostForVerification = { host, browser in
            constructedHostCount += 1
            allocationTrace.append(allocationFacts(host, browser, stage: "constructed"))
            intendedInitialAllocation = host.bounds.size == NSSize(width: 400, height: 220)
            host.layoutSubtreeIfNeeded()
            allocationTrace.append(allocationFacts(host, browser, stage: "early-layout"))
            let frame = browser.view.frame
            let expected = host.bounds.insetBy(dx: 1, dy: 1)
            earlyContentContained = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                && expected.width > 0 && expected.height > 0
                && abs(frame.minX - expected.minX) <= 0.5 && abs(frame.minY - expected.minY) <= 0.5
                && abs(frame.width - expected.width) <= 0.5 && abs(frame.height - expected.height) <= 0.5
        }
        let recordsMotion = ProcessInfo.processInfo.arguments.contains("pane-motion")
            && !ProcessInfo.processInfo.arguments.contains("--offscreen")
        let contentSize = NSSize(width: 1400, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 50, y: 50), size: contentSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        defer {
            workspace.isClosing = true
            workspace.preview.setEnabled(false)
            for browser in workspace.browsers.values { browser.suspendBrowser() }
            window.close()
        }
        window.contentViewController = workspace
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.didConstructPaneHostForVerification = nil
        if let host = workspace.paneHosts[primary.paneID] {
            allocationTrace.append(allocationFacts(host, primary, stage: "allocated-layout"))
        }
        let allocationData = try JSONSerialization.data(withJSONObject: ["observations": allocationTrace,
            "constructedHostCount": constructedHostCount, "intendedInitialAllocation": intendedInitialAllocation,
            "earlyContentContained": earlyContentContained],
            options: [.prettyPrinted, .sortedKeys])
        try await Task.detached {
            try allocationData.write(to: owned.appendingPathComponent("pane-preallocation-geometry.json"), options: .withoutOverwriting)
        }.value
        try require(constructedHostCount == 1 && intendedInitialAllocation,
                    "The real pane was not constructed at its intended 400 by 220 allocation; numeric observations were preserved")
        try require(earlyContentContained,
                    "The real browser did not fill its initial pane inset before ancestor layout; numeric observations were preserved")
        try verifyGeometry(workspace, stage: "ancestor layout after initial pane allocation")
        // Only explicit foreground substantial qualification orders this owned
        // native window. Offscreen runs never create popup/input success claims.
        let visibleFilterQualification = (ProcessInfo.processInfo.arguments.contains("--check-substantial")
            || ProcessInfo.processInfo.arguments.contains("pane-motion"))
            && !ProcessInfo.processInfo.arguments.contains("--offscreen")
        if visibleFilterQualification { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        var clips: [[String: Any]] = []
        func record(_ label: String, action: @MainActor () throws -> Void) async throws {
            guard recordsMotion else { try action(); return }
            // Keep the wide functional control intact. Only the recorded
            // action uses this compact, admitted WindowServer canvas.
            let originalFrame = window.frame
            defer { window.setFrame(originalFrame, display: true); window.contentView?.layoutSubtreeIfNeeded() }
            window.setContentSize(NSSize(width: 1120, height: 740))
            window.contentView?.layoutSubtreeIfNeeded()
            window.title = "Panes · generated review · motion audit"
            let movie = try await NativeMotionRecorder.record(window: window, root: testRoot, label: label,
                sampling: .diagnostic(for: window), includingChildWindows: false, action: action)
            try JSONEncoder().encode(movie).write(to: testRoot.appendingPathComponent("evidence/\(label).json"),
                options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip(label, report: movie, field: nil, window: window))
        }
        workspace.startBrowser(primary)
        try await waitUntil("Initial generated pane listing") { primary.rowsByURL[firstFile] != nil && !primary.isLoading && primary.orderingTask == nil }
        var checks: [String] = []
        checks.append("The real pane is constructed at 400 by 220 before content is pinned; early native layout fills its inset and subsequent ancestor layout preserves containment, with numeric observations retained")
        try require(workspace.browsers.count == 1 && !workspace.preview.isEnabled, "Workspace did not start with one pane and preview off")
        try require(workspace.paneHosts.values.allSatisfy { !$0.showsFocusOutline },
                    "A single-pane workspace must not draw an active-pane outline")
        guard let singleName = primary.table.tableColumn(withIdentifier: .init("name")),
              let singleDate = primary.table.tableColumn(withIdentifier: .init("modified")) else {
            throw UIVerification.Failure(message: "Single-pane column control is unavailable")
        }
        let singlePaneColumns = (viewport: primary.folderScroll.contentSize.width,
            name: singleName.width, date: singleDate.width, scale: InterfaceMetrics.scale)
        let paneMotion = visibleFilterQualification && settings.motion.allows(.panes)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try await record("pane-split") {
            let didSplit = workspace.splitActive(at: .trailing)
            let geometry = "window=\(window.contentView?.bounds.size ?? .zero), workspace=\(workspace.view.bounds.size), tree=\(workspace.paneTreeHost.bounds.size), primaryHost=\(workspace.paneHosts[primary.paneID]?.bounds.size ?? .zero), screen=\(window.screen?.visibleFrame.size ?? .zero), canChange=\(workspace.canChangePaneLayout), primaryBusy=\(primary.hasPendingFileOperation), suspended=\(primary.isBrowserSuspended)"
            try require(didSplit, "Two-pane split failed in an adequately sized window: " + geometry)
            if paneMotion {
                guard let picture = workspace.paneTransitionFramesForVerification[primary.paneID]?.image,
                      let bitmap = picture.representations.first as? NSBitmapImageRep,
                      let empty = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) else {
                    throw UIVerification.Failure(message: "Native pane transition picture missing")
                }
                if primary.contentSurface?.isUsingOpaqueSurface == false {
                    try require(empty.alphaComponent < 0.02, "Pane transition captured an opaque material backplate")
                }
                try require(!workspace.paneTransitionHasOpaqueBackdropForVerification,
                    "Pane transition painted an opaque background over native material")
            }
        }
        let peer = workspace.activeBrowser
        try require(workspace.paneHosts.values.filter(\.showsFocusOutline).count == 1
                    && workspace.paneHosts[peer.paneID]?.showsFocusOutline == true,
                    "A split workspace must outline exactly its active pane")
        peer.permitsBackgroundVerification = true
        try await waitUntil("Duplicated pane listing") { peer.rowsByURL[firstFile] != nil && !peer.isLoading && peer.orderingTask == nil }
        try require(peer.paneID != primary.paneID && peer.activeID != history.id && peer.location == primary.location
                    && peer.tabs[peer.activeIndex].filter == "alpha" && !peer.tabs[peer.activeIndex].canGoBack,
                    "Split did not create an independent current visit")
        try require(peer.clipboardState === primary.clipboardState && peer.folderAccess === primary.folderAccess
                    && peer.pinsController === primary.pinsController && peer.operationHistory === primary.operationHistory,
                    "Panes did not share clipboard/access/pin/operation history owners")
        try require(!primary.hasFileCommandFocus && peer.hasFileCommandFocus, "Inactive pane retained file-command focus")
        try require(primary.sidebarSurface?.superview == nil && peer.sidebarSurface?.superview === workspace.sidebarHost
                    && peer.statusSurface?.superview === workspace.activeFooterHost, "Workspace did not host exactly the active sidebar/footer")
        try require(!workspace.canMoveTab(peer.activeID, from: peer, beside: peer.paneID, edge: .leading), "Last-tab self split was admitted")
        try exerciseResizeGeometry(workspace, window: window, stage: "two panes")
        try await verifyResponsiveColumns(workspace, window: window, owned: owned, singlePane: singlePaneColumns)
        checks.append("Actual side-by-side native tables retain readable Name columns at100/150%, shrink default metadata first, scroll constrained columns, and retain native synthetic header resize choices; physical pointer input is not exercised")
        try await capture(workspace, window: window, owned: owned, name: "two-panes")
        workspace.activate(primary)
        primary.navigate(to: .directory(secondFolder))
        try await waitUntil("Independent primary navigation") { primary.rowsByURL[secondFile] != nil && !primary.isLoading && primary.orderingTask == nil }
        try require(peer.location == .directory(firstFolder) && peer.tabs[peer.activeIndex].filter == "alpha", "One pane's navigation/filter changed another")
        primary.goBack(nil)
        try await waitUntil("Original history Back") { primary.rowsByURL[firstFile] != nil && !primary.isLoading && primary.orderingTask == nil }
        try require(primary.tabs[primary.activeIndex].canGoForward, "History fixture did not retain Forward")
        checks.append("Native panes retain independent tab/history/filter/selection visits with one shared sidebar/footer, clipboard, access controller and pin owner; inactive commands and last-tab self splits refuse")

        // RED-capable owner symptom: AppKit receives this callback on the
        // pointer-side strip, while most of the actual tab preview is still in
        // the neighboring source strip. The whole-preview winner must prevail.
        workspace.activate(primary)
        primary.tabStrip.layoutSubtreeIfNeeded(); peer.tabStrip.layoutSubtreeIfNeeded()
        let overlapBoard = NSPasteboard.withUniqueName()
        defer { overlapBoard.releaseGlobally() }
        guard let overlapType = primary.tabStrip.registerTabDragForVerification(id: history.id, sequence: 8790,
                  previewRelativeToPointer: NSRect(x: -180, y: -14, width: 196, height: 28)) else {
            throw UIVerification.Failure(message: "Whole-preview source could not register")
        }
        overlapBoard.setString(history.id.uuidString, forType: overlapType)
        let overlap = WorkspaceFixtureTabDrag(board: overlapBoard, source: primary.tabStrip, sequence: 8790)
        overlap.draggingDestinationWindow = window
        let peerBand = peer.tabStrip.convert(peer.tabStrip.bounds, to: nil)
        overlap.draggingLocation = NSPoint(x: peerBand.minX + 2, y: peerBand.midY)
        try require(peer.tabStrip.draggingUpdated(overlap) == .move
                    && primary.tabStrip.hasInsertionPreviewForVerification
                    && !peer.tabStrip.hasInsertionPreviewForVerification,
                    "Pointer-side pane stole a tab whose whole preview overlaps the adjacent source strip more")
        try require(peer.tabStrip.prepareForDragOperation(overlap), "Whole-preview source winner failed prepare re-evaluation")
        peer.tabStrip.draggingExited(overlap)
        try require(primary.tabStrip.hasInsertionPreviewForVerification,
                    "Late pointer-side exit erased the newer whole-preview winner")
        let peerIDs = peer.tabs.map(\.id)
        try require(peer.tabStrip.performDragOperation(overlap)
                    && primary.tabs.map(\.id) == [spare.id, history.id] && peer.tabs.map(\.id) == peerIDs,
                    "Routed commit moved the tab into the pointer-side pane instead of the largest-preview source strip")
        primary.tabStrip.invalidateManagementInteraction()

        let primaryBand = primary.tabStrip.convert(primary.tabStrip.bounds, to: nil)
        let boundary = (primaryBand.maxX + peerBand.minX) / 2
        let peerPointer = NSPoint(x: peerBand.minX + 2, y: peerBand.midY)
        let tieRelative = NSRect(x: boundary - 98 - peerPointer.x, y: -14, width: 196, height: 28)
        guard primary.tabStrip.registerTabDragForVerification(id: history.id, sequence: 8791,
                  previewRelativeToPointer: tieRelative) != nil else {
            throw UIVerification.Failure(message: "Equal-overlap source could not register")
        }
        let tie = WorkspaceFixtureTabDrag(board: overlapBoard, source: primary.tabStrip, sequence: 8791)
        tie.draggingDestinationWindow = window; tie.draggingLocation = peerPointer
        try require(primary.tabStrip.draggingUpdated(tie) == .move
                    && peer.tabStrip.hasInsertionPreviewForVerification && !primary.tabStrip.hasInsertionPreviewForVerification,
                    "Equal whole-preview overlap did not favor the pointer-containing strip")
        guard primary.tabStrip.registerTabDragForVerification(id: history.id, sequence: 8792,
                  previewRelativeToPointer: NSRect(x: -98, y: -14, width: 196, height: 28)) != nil else {
            throw UIVerification.Failure(message: "Stable-order overlap source could not register")
        }
        let gapTie = WorkspaceFixtureTabDrag(board: overlapBoard, source: primary.tabStrip, sequence: 8792)
        gapTie.draggingDestinationWindow = window
        gapTie.draggingLocation = NSPoint(x: boundary, y: peerBand.midY)
        try require(peer.tabStrip.draggingUpdated(gapTie) == .move
                    && primary.tabStrip.hasInsertionPreviewForVerification && !peer.tabStrip.hasInsertionPreviewForVerification,
                    "Equal overlap with pointer between strips did not use stable pane-layout order")
        // An old exit sequence must not clear the newly selected destination.
        peer.tabStrip.draggingExited(tie)
        try require(primary.tabStrip.hasInsertionPreviewForVerification,
                    "Stale exit sequence erased the current insertion preview")
        primary.tabStrip.invalidateManagementInteraction()

        guard primary.tabStrip.registerTabDragForVerification(id: history.id, sequence: 8793,
                  previewRelativeToPointer: NSRect(x: -12, y: -14, width: 196, height: 28)) != nil else {
            throw UIVerification.Failure(message: "Whole-preview peer winner could not register")
        }
        let peerWinner = WorkspaceFixtureTabDrag(board: overlapBoard, source: primary.tabStrip, sequence: 8793)
        peerWinner.draggingDestinationWindow = window
        peerWinner.draggingLocation = NSPoint(x: primaryBand.maxX - 2, y: primaryBand.midY)
        try require(primary.tabStrip.draggingUpdated(peerWinner) == .move
                    && peer.tabStrip.hasInsertionPreviewForVerification && !primary.tabStrip.hasInsertionPreviewForVerification,
                    "Whole-preview peer winner did not display its insertion gap when pointer remained in source pane")
        let staleOverlap = WorkspaceFixtureTabDrag(board: overlapBoard, source: primary.tabStrip, sequence: 8792)
        staleOverlap.draggingDestinationWindow = window; staleOverlap.draggingLocation = peerWinner.draggingLocation
        let foreignOverlap = WorkspaceFixtureTabDrag(board: overlapBoard, source: NSObject(), sequence: 8793)
        foreignOverlap.draggingDestinationWindow = window; foreignOverlap.draggingLocation = peerWinner.draggingLocation
        try require(primary.tabStrip.draggingUpdated(staleOverlap).isEmpty
                    && primary.tabStrip.draggingUpdated(foreignOverlap).isEmpty
                    && !primary.tabStrip.performDragOperation(staleOverlap)
                    && !primary.tabStrip.performDragOperation(foreignOverlap)
                    && peer.tabStrip.hasInsertionPreviewForVerification,
                    "Foreign/stale overlap gained authority or erased the valid current winner")
        primary.operationPreparationTask = Task {}
        try require(primary.tabStrip.draggingUpdated(peerWinner).isEmpty && !primary.tabStrip.prepareForDragOperation(peerWinner)
                    && !peer.tabStrip.hasInsertionPreviewForVerification,
                    "Busy file preparation retained whole-preview tab-drop authority")
        primary.operationPreparationTask = nil
        try require(primary.tabStrip.draggingUpdated(peerWinner) == .move && primary.tabStrip.prepareForDragOperation(peerWinner),
                    "Whole-preview route failed to re-evaluate after the busy guard ended")
        let heldLocation = peerWinner.draggingLocation
        peerWinner.draggingLocation = NSPoint(x: -1000, y: -1000)
        try require(!primary.tabStrip.performDragOperation(peerWinner)
                    && primary.tabs.map(\.id) == [spare.id, history.id] && peer.tabs.map(\.id) == peerIDs,
                    "Perform reused an old whole-preview destination after geometry no longer overlapped")
        peerWinner.draggingLocation = heldLocation
        try require(primary.tabStrip.prepareForDragOperation(peerWinner) && primary.tabStrip.performDragOperation(peerWinner)
                    && primary.tabs.map(\.id) == [spare.id] && peer.tabs.contains(where: { $0.id == history.id }),
                    "Whole-preview cross-pane commit did not move the exact authenticated tab")
        primary.tabStrip.invalidateManagementInteraction()
        try require(workspace.moveTab(history.id, from: peer, into: primary, before: spare.id),
                    "Whole-preview fixture could not restore its exact source tab for remaining edge checks")
        try await waitUntil("Restored whole-preview fixture visits") {
            !primary.isLoading && primary.orderingTask == nil && !peer.isLoading && peer.orderingTask == nil
        }
        checks.append("Registered callbacks route the complete native preview to its largest positive tab-band overlap; exact ties favor pointer then stable layout order; stale exits/foreign sources/busy writes refuse and prepare/perform re-evaluate exact tab identity")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard let type = primary.tabStrip.registerTabDragForVerification(id: history.id, sequence: 8801,
                  previewRelativeToPointer: NSRect(x: -180, y: -14, width: 196, height: 28)),
              let host = workspace.paneHosts[peer.paneID] else { throw UIVerification.Failure(message: "Workspace tab drag fixture could not register") }
        board.setString(history.id.uuidString, forType: type)
        let authenticated = WorkspaceFixtureTabDrag(board: board, source: primary.tabStrip, sequence: 8801)
        authenticated.draggingDestinationWindow = window
        authenticated.draggingLocation = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.maxY + 8), to: nil)
        try require(host.draggingUpdated(authenticated) == .move && host.proposedEdge == .top,
                    "Authenticated tab preview overlap outside pointer rejected a pane edge")
        authenticated.draggingLocation = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.minY + 8), to: nil)
        try require(host.draggingUpdated(authenticated) == .move && host.proposedEdge == .bottom,
                    "Authenticated bottom-edge drag did not show a snap destination")
        // A source movement callback still arrives after the pointer has left
        // every registered pane destination; it must revoke the old outline.
        primary.tabStrip.moveTabDragForVerification(to: window.convertPoint(toScreen: NSPoint(x: -500, y: -500)))
        try require(host.proposedEdge == nil, "Movement into an unregistered area retained snap authority")
        try require(host.draggingUpdated(authenticated) == .move && host.proposedEdge == .bottom,
                    "Leaving and re-entering a valid edge lost the current snap session")
        let untouched = workspace.paneHosts[primary.paneID]!
        try await record("pane-split-neighbour") {
            let untouchedFrame = untouched.convert(untouched.bounds, to: workspace.paneTreeHost)
            authenticated.draggingLocation = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.minY + 8), to: nil)
            try require(host.performDragOperation(authenticated), "Authenticated edge drop failed")
            if paneMotion {
                try require(untouched.convert(untouched.bounds, to: workspace.paneTreeHost) == untouchedFrame
                    && workspace.paneTransitionFramesForVerification[primary.paneID] == nil,
                    "Splitting another pane repainted an unchanged pane")
            }
        }
        let moved = workspace.activeBrowser
        moved.permitsBackgroundVerification = true
        try require(workspace.browsers.count == 3 && moved.tabs[0].id == history.id && moved.tabs[0].canGoBack && moved.tabs[0].canGoForward,
                    "Edge split lost exact tab identity/history")
        try require(primary.tabs.map(\.id) == [spare.id] && host.proposedEdge == nil, "Edge split lost source's remaining tab or retained a snap")
        moved.goForward(nil)
        try await waitUntil("Moved tab Forward") { moved.rowsByURL[secondFile] != nil && !moved.isLoading && moved.orderingTask == nil }
        try require(moved.location == .directory(secondFolder), "Transferred tab Forward navigated to the wrong location")
        checks.append("Authenticated native bottom-edge tab drop creates a third pane while preserving the exact tab ID and Back/Forward history, and clears the snap target")

        let fake = WorkspaceFixtureTabDrag(board: board, source: NSObject(), sequence: 8801)
        fake.draggingLocation = authenticated.draggingLocation
        try require(host.draggingUpdated(fake).isEmpty && !host.performDragOperation(fake) && host.proposedEdge == nil,
                    "A pasteboard string from a foreign source gained tab-split authority")
        let stale = WorkspaceFixtureTabDrag(board: board, source: moved.tabStrip, sequence: 8899)
        stale.draggingLocation = authenticated.draggingLocation
        try require(host.draggingUpdated(stale).isEmpty, "A stale drag sequence retained pane authority")
        for edge in PaneDropEdge.allCases {
            let rect = PaneHostView.snapFrame(for: edge, in: NSRect(x: 0, y: 0, width: 800, height: 500))
            try require(rect.width > 0 && rect.height > 0 && NSRect(x: 0, y: 0, width: 800, height: 500).contains(rect), "Snap outline escaped pane bounds")
        }
        try require(PaneHostView.edge(at: NSPoint(x: 400, y: 250), in: NSRect(x: 0, y: 0, width: 800, height: 500)) == nil,
                    "A center drop unexpectedly requested an edge split")
        checks.append("Foreign source strings, stale drag sequences and center drops have no split authority; all four edge outlines stay inside the pane")

        var fourthVisitBeforeLoading: UUID?
        try await record("pane-split-unaffected") {
            guard let stable = workspace.paneHosts[primary.paneID] else {
                throw UIVerification.Failure(message: "Unchanged pane disappeared before fourth split")
            }
            let before = stable.convert(stable.bounds, to: workspace.paneTreeHost), visit = primary.sessionID
            try require(workspace.splitActive(at: .top), "Fourth pane stretch failed in a sufficiently sized workspace")
            workspace.activeBrowser.permitsBackgroundVerification = true
            fourthVisitBeforeLoading = workspace.activeBrowser.sessionID
            if paneMotion {
                try require(stable.convert(stable.bounds, to: workspace.paneTreeHost) == before
                    && primary.sessionID == visit
                    && workspace.paneTransitionFramesForVerification[primary.paneID] == nil,
                    "Fourth split enrolled a pane whose geometry and visit were unchanged")
            }
        }
        let fourthPane = workspace.activeBrowser
        guard let fourthInitialVisit = fourthVisitBeforeLoading else {
            throw UIVerification.Failure(message: "Fourth pane's initial visit was not observed")
        }
        try await waitUntil("Fourth pane native tab presentation") {
            fourthPane.sessionID != fourthInitialVisit && fourthPane.tabStrip.selectionButton(for: fourthPane.activeID) != nil
                && !fourthPane.isLoading && fourthPane.orderingTask == nil
        }
        try exerciseResizeGeometry(workspace, window: window, stage: "four panes")
        try await capture(workspace, window: window, owned: owned, name: "four-panes")
        do {
            let fullContentSize = window.contentView?.bounds.size ?? workspace.view.bounds.size
            let progressOwner = workspace.activeBrowser
            try require(progressOwner.startOperationPresentation("Generated minimum-size layout inspection"),
                        "Four-pane geometry fixture could not reserve progress presentation")
            defer {
                progressOwner.endOperationProgressPresentation()
                window.setContentSize(fullContentSize)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            window.setContentSize(workspace.minimumWorkspaceSize)
            window.contentView?.layoutSubtreeIfNeeded()
            try verifyGeometry(workspace, stage: "four panes at exact minimum with expanded progress")
        }
        try await UIVerification.verifyWorkspaceSidebarResize(workspace, window: window)
        try await UIVerification.verifyCollapsedBreadcrumbsInFourPanes(workspace, window: window, owned: owned)
        try await UIVerification.verifyCompactFilterInFourPanes(workspace, window: window, owned: owned)
        checks.append("Four panes at exact minimum preserve native current/menu hit targets, ordered lexical ancestor navigation, stale menu rejection, full Copy Path and canonical typing for known/unknown volumes")
        checks.append("Native shared sidebar drag/collapse, View toggle and footer restore preserve expanded width, branch order, keyboard focus, four-pane/Preview minima and persisted state; full/reduced/off motion and interruption settle safely")
        let fullLayout = workspace.layout
        try require(workspace.browsers.count == 4 && !workspace.splitActive(at: .top) && workspace.layout == fullLayout,
                    "Fifth pane exceeded the validated four-pane limit")
        let busyBrowser = workspace.activeBrowser
        busyBrowser.operationPreparationTask = Task {}
        try require(!workspace.canChangePaneLayout && !workspace.closeActivePane(), "Busy operation preparation permitted pane teardown")
        busyBrowser.operationPreparationTask = nil
        checks.append("Mixed row/column composition reaches four panes; every leaf fills its allocation at initial and resized geometry with no gaps/overlaps and at least 400 by 220 points; fifth panes and busy teardown refuse")

        // Cross-strip Move of a pane's only tab must collapse that source leaf.
        let stripSource = workspace.activeBrowser
        guard let stripTarget = workspace.browsers.values.first(where: { $0 !== stripSource }),
              let movedID = stripSource.tabs.first?.id else { throw UIVerification.Failure(message: "Cross-strip fixture lacks a destination") }
        stripSource.tabStrip.layoutSubtreeIfNeeded(); stripTarget.tabStrip.layoutSubtreeIfNeeded()
        guard let crossType = stripSource.tabStrip.registerTabDragForVerification(id: movedID, sequence: 8802),
              let targetFrame = stripTarget.tabStrip.lastTabFrame else { throw UIVerification.Failure(message: "Cross-strip source could not register") }
        board.clearContents(); board.setString(movedID.uuidString, forType: crossType)
        var cross = WorkspaceFixtureTabDrag(board: board, source: stripSource.tabStrip, sequence: 8802)
        cross.draggingDestinationWindow = window
        cross.draggingLocation = stripTarget.tabStrip.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        try require(stripTarget.tabStrip.draggingUpdated(cross) == .move && stripTarget.tabStrip.hasInsertionPreviewForVerification,
                    "Cross-strip native callback did not create an insertion preview")
        stripSource.tabStrip.moveTabDragForVerification(to: window.convertPoint(toScreen: NSPoint(x: -500, y: -500)))
        try require(!stripTarget.tabStrip.hasInsertionPreviewForVerification,
                    "Source movement into an unregistered area retained cross-strip insertion presentation")
        try require(stripTarget.tabStrip.draggingUpdated(cross) == .move,
                    "Cross-strip destination did not recover after re-entry")
        stripSource.tabStrip.invalidateManagementInteraction()
        try require(!stripTarget.tabStrip.hasInsertionPreviewForVerification,
                    "Ended native source retained cross-strip insertion presentation")
        guard stripSource.tabStrip.registerTabDragForVerification(id: movedID, sequence: 8803) != nil else {
            throw UIVerification.Failure(message: "Cross-strip source could not re-register after ending")
        }
        let crossLocation = cross.draggingLocation
        cross = WorkspaceFixtureTabDrag(board: board, source: stripSource.tabStrip, sequence: 8803)
        cross.draggingDestinationWindow = window; cross.draggingLocation = crossLocation
        try require(stripTarget.tabStrip.draggingUpdated(cross) == .move && stripTarget.tabStrip.performDragOperation(cross),
                    "Authenticated cross-strip transfer failed")
        try require(workspace.browsers.count == 3 && workspace.browsers[stripSource.paneID] == nil
                    && stripTarget.tabs.contains(where: { $0.id == movedID }), "Last-tab transfer left an empty pane or lost the tab")
        try require(stripSource.tabs.count == 1 && stripSource.isBrowserSuspended && TabStripView.authenticatedDrag(cross) == nil,
                    "Retired pane lost its final valid visit or retained authenticated drag authority")
        let activeBeforeFocus = workspace.activePaneID
        workspace.focusOtherPane()
        workspace.activeBrowser.permitsBackgroundVerification = true
        try require(workspace.activePaneID != activeBeforeFocus, "Keyboard-equivalent Focus Other Pane did not change active context")
        checks.append("Authenticated cross-strip transfer preserves the tab and collapses an empty source pane; Focus Other Pane advances the command context")

        let snapshot = PaneWorkspaceSnapshot(layout: workspace.layout, activePane: workspace.activePaneID, panes: try workspace.layout.paneIDs.map { id in
            let browser = workspace.browsers[id]!
            return .init(id: id, tabs: try WorkspaceSession.capture(browser.tabs, activeID: browser.activeID), viewMode: browser.effectiveViewMode.rawValue)
        })
        workspace.preview.setEnabled(true) // Enablement alone does not read/render a body.
        workspace.restoringSession = true
        try workspace.applyRestoredSnapshot(snapshot)
        workspace.restoringSession = false
        try require(workspace.layout == snapshot.layout && Set(workspace.browsers.keys) == Set(snapshot.layout.paneIDs)
                    && workspace.activePaneID == snapshot.activePane && !workspace.preview.isEnabled,
                    "Restoration changed pane identities/active layout or restored preview consent")
        let restoredVisits = workspace.browsers.mapValues { $0.sessionID }
        for browser in workspace.browsers.values { browser.permitsBackgroundVerification = true; workspace.startBrowser(browser) }
        try await waitUntil("Restored pane listings") {
            workspace.browsers.allSatisfy { id, browser in
                browser.sessionID != restoredVisits[id] && !browser.isLoading && browser.orderingTask == nil
            }
        }
        checks.append("Native workspace restoration preserves validated pane identities/layout/active context, reuses app stores, and always resets inline preview off")

        guard let closing = workspace.browsers.values.first(where: { $0.tabs.count == 1 }) else {
            throw UIVerification.Failure(message: "Last-tab Close fixture lacks a single-tab pane")
        }
        let closedVisit = ClosedBrowserTab(closing.tabs[0])
        let closedID = closing.tabs[0].id
        let totalBeforeClose = workspace.browsers.values.reduce(0) { $0 + $1.tabs.count }
        workspace.activate(closing)
        let beforeFilterCloseSize = window.contentView!.bounds.size
        window.setContentSize(workspace.minimumWorkspaceSize)
        window.contentView?.layoutSubtreeIfNeeded()
        closing.focusFilter(nil)
        let visibleFilterClose = window.isVisible && NSApp.isActive && !closing.showsComputerVolumes
        if visibleFilterClose {
            try await UIVerification.waitUntil("Native compact filter before actual pane close") {
                closing.folderFilter.isPresented && closing.folderFilter.displayedField.currentEditor() is NSTextView
            }
        }
        try await record("pane-close-last-tab") {
            try require(workspace.closeLastTab(in: closing), "Explicit last-tab Close failed to collapse its pane")
        }
        try require(!workspace.browsers.values.contains(where: { $0.tabs.contains(where: { $0.id == closedID }) })
                    && workspace.browsers.values.reduce(0, { $0 + $1.tabs.count }) == totalBeforeClose - 1,
                    "Explicit Close Tab merged rather than closed its requested tab")
        try require(workspace.activeBrowser.closedTabs.last?.location == closedVisit.location
                    && workspace.activeBrowser.closedTabs.last?.filter == closedVisit.filter,
                    "Closed last tab lost bounded Reopen state")
        try require(closing.isBrowserSuspended && !closing.folderFilter.hasPopoverCommandsForVerification,
            "Actual pane close retained filter command authority")
        // NSPopover.close() retires an animated presentation asynchronously.
        // Command ownership ends immediately; its native window/editor must
        // then finish closing before this flow can claim complete teardown.
        try await waitUntil("Actual pane close filter presentation teardown") {
            !closing.folderFilter.isPresented && closing.folderFilter.displayedField.currentEditor() == nil
        }
        window.setContentSize(beforeFilterCloseSize); window.contentView?.layoutSubtreeIfNeeded()
        checks.append("Explicit last-tab Close collapses only its pane, removes that tab and retains its current visit in bounded Reopen history; filter popup/editor and scoped key monitoring retire with it")

        let allTabs = Set(workspace.browsers.values.flatMap { $0.tabs.map(\.id) })
        if workspace.browsers.count > 1 {
            try await record("pane-close-and-merge") {
                try require(workspace.closeActivePane(), "Close Pane failed to merge tabs")
            }
        }
        while workspace.browsers.count > 1 { try require(workspace.closeActivePane(), "Close Pane failed to merge tabs") }
        try require(Set(workspace.activeBrowser.tabs.map(\.id)) == allTabs && !workspace.closeActivePane(),
                    "Close Pane lost tabs or removed the final pane")
        window.contentMinSize = NSSize(width: 820, height: 500)
        window.setContentSize(NSSize(width: 820, height: 500))
        workspace.view.layoutSubtreeIfNeeded()
        let narrow = workspace.layout
        let narrowBefore = "window=\(window.contentView?.bounds.size ?? .zero), workspace=\(workspace.view.bounds.size), tree=\(workspace.paneTreeHost.bounds.size), minimum=\(workspace.minimumWorkspaceSize)"
        let didSplitNarrow = workspace.splitActive(at: .trailing)
        // AppKit may expand a requested window to its actual fitting size. If
        // that size legitimately fits two panes, test the next split instead.
        let admittedSecondAtActualSize = didSplitNarrow
        let refusalLayout = workspace.layout
        let rejectedAdditionalSplit = admittedSecondAtActualSize ? !workspace.splitActive(at: .trailing) : true
        let narrowAfter = "window=\(window.contentView?.bounds.size ?? .zero), workspace=\(workspace.view.bounds.size), tree=\(workspace.paneTreeHost.bounds.size), minimum=\(workspace.minimumWorkspaceSize), panes=\(workspace.layout.paneIDs.count), nodes=\(workspace.layout.nodes.count), status=\(workspace.activeBrowser.status.stringValue)"
        try require(rejectedAdditionalSplit && workspace.layout == (admittedSecondAtActualSize ? refusalLayout : narrow)
                    && !workspace.activeBrowser.status.stringValue.isEmpty,
                    "A narrow window admitted unreadable panes or gave no explanation: didSplit=\(didSplitNarrow), before {\(narrowBefore)}, after {\(narrowAfter)}")
        try await capture(workspace, window: window, owned: owned, name: "narrow-native-fitting")
        try require(!BrowserWorkspaceController.fits(minimum: NSSize(width: 1002, height: 500), in: NSSize(width: 900, height: 600)),
                    "Too-small available screen admitted minimum pane geometry")
        checks.append("Close Pane merges every tab without loss and protects the final pane; narrow or too-small available geometry refuses a split with a visible reason")
        if let bitmap = workspace.view.bitmapImageRepForCachingDisplay(in: workspace.view.bounds) {
            workspace.view.cacheDisplay(in: workspace.view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try await Task.detached { try data.write(to: owned.appendingPathComponent("workspace-native-narrow.png"), options: .withoutOverwriting) }.value
            }
        }
        return .init(checks: checks, clips: clips)
    }

    private static func capture(_ workspace: BrowserWorkspaceController, window: NSWindow, owned: URL, name: String) async throws {
        func facts(_ view: NSView?) -> [String: Any] {
            guard let view else { return ["present": false] }
            return ["present": true, "bounds": NSStringFromRect(view.bounds), "frame": NSStringFromRect(view.frame),
                    "fittingWidth": view.fittingSize.width, "fittingHeight": view.fittingSize.height, "hidden": view.isHidden]
        }
        let original = NSApplication.shared.appearance
        let originalWindow = window.appearance, originalView = workspace.view.appearance
        defer {
            NSApplication.shared.appearance = original
            window.appearance = originalWindow
            workspace.view.appearance = originalView
        }
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let explicit = NSAppearance(named: appearance)
            NSApplication.shared.appearance = explicit
            window.appearance = explicit
            workspace.view.appearance = explicit
            try await Task.sleep(for: .milliseconds(100))
            workspace.view.needsDisplay = true
            workspace.view.layoutSubtreeIfNeeded()
            for browser in workspace.browsers.values { browser.updateMaterialSurfaces() }
            try verifyGeometry(workspace, stage: name + " " + label)
            try require(workspace.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                        "Native fixture appearance did not propagate for " + label)
            let panes: [[String: Any]] = workspace.layout.paneIDs.enumerated().compactMap { index, id in
                guard let browser = workspace.browsers[id] else { return nil }
                return ["pane": index + 1, "active": workspace.activePaneID == id,
                        "host": facts(workspace.paneHosts[id]), "browser": facts(browser.view),
                        "navigationSurface": facts(browser.navigationSurface), "pathContainer": facts(browser.pathContainer),
                        "splitView": facts(browser.splitController.view), "statusSurface": facts(browser.statusSurface),
                        "paneBody": facts(browser.paneBody)]
            }
            let geometry: [String: Any] = ["appearance": label, "effectiveAppearance": workspace.view.effectiveAppearance.name.rawValue,
                "windowContent": facts(window.contentView),
                "workspace": facts(workspace.view), "paneTree": facts(workspace.paneTreeHost),
                "sidebar": facts(workspace.sidebarHost), "footer": facts(workspace.footerHost),
                "minimumWidth": workspace.minimumWorkspaceSize.width, "minimumHeight": workspace.minimumWorkspaceSize.height,
                "panes": panes, "capture": "native view cache; not WindowServer compositing"]
            let json = try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            try await Task.detached { try json.write(to: owned.appendingPathComponent(name + "-" + label + "-geometry.json"), options: .withoutOverwriting) }.value
            workspace.view.layoutSubtreeIfNeeded()
            if let bitmap = workspace.view.bitmapImageRepForCachingDisplay(in: workspace.view.bounds) {
                workspace.view.cacheDisplay(in: workspace.view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try await Task.detached { try data.write(to: owned.appendingPathComponent(name + "-" + label + ".png"), options: .withoutOverwriting) }.value
                }
            }
        }
    }
    private static func verifyResponsiveColumns(_ workspace: BrowserWorkspaceController, window: NSWindow, owned: URL,
        singlePane: (viewport: CGFloat, name: CGFloat, date: CGFloat, scale: CGFloat)) async throws {
        let browsers = Array(workspace.browsers.values), settings = workspace.activeBrowser.settings
        let previousBinding = InterfacePresentation.shared.settings, size = settings.interfaceSize
        let initial = window.contentView!.bounds.size
        let modes = browsers.map(\.effectiveViewMode), selections = browsers.map(\.selectedURLs)
        let columns = (settings.showsModifiedColumn, settings.showsKindColumn, settings.showsSizeColumn,
            settings.showsCreatedColumn, settings.showsAccessedColumn, settings.showsExtensionColumn)
        defer {
            settings.interfaceSize = size
            (settings.showsModifiedColumn, settings.showsKindColumn, settings.showsSizeColumn,
                settings.showsCreatedColumn, settings.showsAccessedColumn, settings.showsExtensionColumn) = columns
            for (browser, mode) in zip(browsers, modes) { browser.setPaneViewMode(mode); browser.applyDisplayPreferences() }
            if let previousBinding { InterfacePresentation.shared.bind(previousBinding) }
            window.setContentSize(initial); window.contentView?.layoutSubtreeIfNeeded()
        }
        InterfacePresentation.shared.bind(settings)
        settings.showsModifiedColumn = true; settings.showsKindColumn = true; settings.showsSizeColumn = true
        settings.showsCreatedColumn = false; settings.showsAccessedColumn = false; settings.showsExtensionColumn = false
        for browser in browsers { browser.setPaneViewMode(.details) }
        var observations: [[String: Any]] = [["stage": "single-pane-default", "pane": 0,
            "percent": singlePane.scale * 100, "viewport": singlePane.viewport,
            "name": singlePane.name, "date": singlePane.date]]
        var completed = false
        defer {
            if !completed {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "observations": observations],
                    options: [.prettyPrinted, .sortedKeys])
                    .write(to: owned.appendingPathComponent("columns-responsive.json"), options: .withoutOverwriting)
            }
        }
        try require(singlePane.scale > 0 && singlePane.date / singlePane.scale >= BrowserColumn.modified.width - 1,
            "Single-pane control does not have an unconstrained default Date width")
        func layout(_ percent: Int, narrow: Bool, label: String) async throws {
            settings.interfaceSize = .init(percent)
            await Task.yield()
            let minimum = workspace.minimumWorkspaceSize
            window.setContentSize(narrow ? .init(width: minimum.width + 40, height: minimum.height + 80) : initial)
            for browser in browsers { browser.applyDisplayPreferences() }
            window.contentView?.layoutSubtreeIfNeeded()
            for (index, browser) in browsers.enumerated() {
                let table = browser.table, visible = table.tableColumns.filter { !$0.isHidden }
                guard let name = visible.first(where: { $0.identifier.rawValue == "name" }),
                      let date = visible.first(where: { $0.identifier.rawValue == "modified" }) else {
                    throw UIVerification.Failure(message: "Responsive pane lost its required columns")
                }
                let viewport = browser.folderScroll.contentSize.width
                let edge = visible.reduce(CGFloat.zero) { $0 + $1.width + table.intercellSpacing.width }
                if label.hasSuffix("all-columns") {
                    try require(Set(visible.map { $0.identifier.rawValue }) == Set(BrowserColumn.allCases.map(\.rawValue)),
                        "All-column layout omitted an optional metadata column")
                }
                try require(name.width >= 180 * InterfaceMetrics.scale - 1 && table.frame.width >= edge - 1
                    && browser.folderScroll.hasHorizontalScroller && browser.selectedURLs == selections[index],
                    "Responsive pane collapsed Name, clipped optional columns, or changed selection at \(label)")
                observations.append(["stage": label, "pane": index, "percent": percent, "viewport": viewport,
                    "name": name.width, "date": date.width, "document": table.frame.width, "columnsEdge": edge,
                    "visibleColumns": visible.map { $0.identifier.rawValue }])
            }
        }
        try await layout(100, narrow: false, label: "normal-default")
        let wideDates = browsers.map { $0.table.tableColumn(withIdentifier: .init("modified"))!.width }
        try await layout(100, narrow: true, label: "narrow-default")
        for (browser, wide) in zip(browsers, wideDates) {
            let date = browser.table.tableColumn(withIdentifier: .init("modified"))!.width
            try require(wide < singlePane.date / singlePane.scale - 1 && date <= wide + 1,
                "Split pane did not let default Date yield from its single-pane control, or Date grew while narrowing")
        }
        try await layout(150, narrow: true, label: "narrow-large-default")
        try await capture(workspace, window: window, owned: owned, name: "columns-narrow-150")
        settings.showsCreatedColumn = true; settings.showsAccessedColumn = true; settings.showsExtensionColumn = true
        try await layout(150, narrow: true, label: "narrow-large-all-columns")
        try await layout(150, narrow: false, label: "wide-large-all-columns")
        settings.showsCreatedColumn = false; settings.showsAccessedColumn = false; settings.showsExtensionColumn = false
        try await layout(100, narrow: true, label: "before-native-resize")
        let table = browsers[0].table
        for key in ["name", "modified"] { try resizeHeaderColumn(table, key: key, delta: 40) }
        let chosen = ["name", "modified"].map { table.tableColumn(withIdentifier: .init($0))!.width }
        for percent in [150, 100] {
            try await layout(percent, narrow: percent == 150, label: "explicit-\(percent)")
            settings.showsModifiedColumn = false; browsers.forEach { $0.applyDisplayPreferences() }
            settings.showsModifiedColumn = true; browsers.forEach { $0.applyDisplayPreferences() }
            window.contentView?.layoutSubtreeIfNeeded()
            for (key, width) in zip(["name", "modified"], chosen) {
                try require(abs(table.tableColumn(withIdentifier: .init(key))!.width - width * InterfaceMetrics.scale) <= 1,
                    "Layout, font size or column toggle replaced the explicit native \(key) width")
            }
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "observations": observations,
            "resizeInput": "Constructed native header tracking; physical pointer NOT EXERCISED"], options: [.prettyPrinted, .sortedKeys])
            .write(to: owned.appendingPathComponent("columns-responsive.json"), options: .withoutOverwriting)
        completed = true
    }

    private static func resizeHeaderColumn(_ table: NSTableView, key: String, delta: CGFloat) throws {
        guard let header = table.headerView, let window = table.window,
              let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }) else {
            throw UIVerification.Failure(message: "Native resize has no admitted header")
        }
        let original = table.tableColumns[index].width, rect = header.headerRect(ofColumn: index)
        let start = header.convert(.init(x: rect.maxX - 1, y: rect.midY), to: nil)
        let end = NSPoint(x: start.x + delta, y: start.y), stamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ offset: Double) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: stamp + offset,
                windowNumber: window.windowNumber, context: nil, eventNumber: 946, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw UIVerification.Failure(message: "Native resize event unavailable")
            }
            return event
        }
        let move = try event(.leftMouseDragged, end, 0.02), up = try event(.leftMouseUp, end, 0.04)
        NSApp.postEvent(up, atStart: true); NSApp.postEvent(move, atStart: true)
        header.mouseDown(with: try event(.leftMouseDown, start, 0))
        for (mask, own) in [(NSEvent.EventTypeMask.leftMouseDragged, move), (.leftMouseUp, up)] {
            if let pending = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: false),
               pending.windowNumber == own.windowNumber && pending.timestamp == own.timestamp && pending.eventNumber == own.eventNumber,
               let release = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(release) }
        }
        try require(abs(table.tableColumns[index].width - original - delta) <= 2,
            "Native synthetic header tracking did not resize \(key) by its actual requested distance")
    }

    private static func exerciseResizeGeometry(_ workspace: BrowserWorkspaceController, window: NSWindow, stage: String) throws {
        try verifyGeometry(workspace, stage: stage + " after reparenting")
        let initial = window.contentView?.bounds.size ?? workspace.view.bounds.size
        let minimum = workspace.minimumWorkspaceSize
        window.setContentSize(NSSize(width: minimum.width + 40, height: minimum.height + 40))
        window.contentView?.layoutSubtreeIfNeeded()
        try verifyGeometry(workspace, stage: stage + " after shrinking")
        window.setContentSize(initial)
        window.contentView?.layoutSubtreeIfNeeded()
        try verifyGeometry(workspace, stage: stage + " after expanding")
    }

    private static func verifyGeometry(_ workspace: BrowserWorkspaceController, stage: String) throws {
        workspace.view.layoutSubtreeIfNeeded()
        let tolerance: CGFloat = 1
        func matches(_ actual: NSRect, _ expected: NSRect) -> Bool {
            abs(actual.minX - expected.minX) <= tolerance && abs(actual.minY - expected.minY) <= tolerance
                && abs(actual.width - expected.width) <= tolerance && abs(actual.height - expected.height) <= tolerance
        }
        func visit(_ id: UUID, view: NSView) throws {
            guard let node = workspace.layout.node(id) else { throw UIVerification.Failure(message: stage + ": missing layout node") }
            switch node.content {
            case .pane(let pane):
                guard let host = workspace.paneHosts[pane], let browser = workspace.browsers[pane] else {
                    throw UIVerification.Failure(message: stage + ": missing pane host")
                }
                try require(view === host && host.bounds.width + tolerance >= 400 && host.bounds.height + tolerance >= 220,
                            stage + ": unreadable or mismatched leaf, host=" + NSStringFromRect(host.frame))
                try require(matches(browser.view.frame, host.bounds.insetBy(dx: 1, dy: 1)),
                            stage + ": browser does not fill leaf, browser=" + NSStringFromRect(browser.view.frame) + ", host=" + NSStringFromRect(host.bounds))
            case .split(let axis, _, let first, let second):
                guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2 else {
                    throw UIVerification.Failure(message: stage + ": missing native split")
                }
                let a = split.arrangedSubviews[0], b = split.arrangedSubviews[1]
                let expectedA: NSRect, expectedB: NSRect
                if axis == .columns {
                    expectedA = NSRect(x: 0, y: 0, width: a.frame.width, height: split.bounds.height)
                    expectedB = NSRect(x: a.frame.maxX + split.dividerThickness, y: 0,
                                       width: split.bounds.width - a.frame.maxX - split.dividerThickness, height: split.bounds.height)
                } else {
                    expectedA = NSRect(x: 0, y: 0, width: split.bounds.width, height: a.frame.height)
                    expectedB = NSRect(x: 0, y: a.frame.maxY + split.dividerThickness,
                                       width: split.bounds.width, height: split.bounds.height - a.frame.maxY - split.dividerThickness)
                }
                try require(a.translatesAutoresizingMaskIntoConstraints && b.translatesAutoresizingMaskIntoConstraints
                            && matches(a.frame, expectedA) && matches(b.frame, expectedB),
                            stage + ": split has gaps/overlap or competing frame ownership, split=" + NSStringFromRect(split.bounds)
                                + ", first=" + NSStringFromRect(a.frame) + ", second=" + NSStringFromRect(b.frame))
                try visit(first, view: a); try visit(second, view: b)
            }
        }
        guard let root = workspace.paneTreeHost.subviews.first else { throw UIVerification.Failure(message: stage + ": no pane tree") }
        try require(matches(root.frame, workspace.paneTreeHost.bounds), stage + ": root does not fill pane tree")
        try visit(workspace.layout.rootID, view: root)
    }
    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(condition(), message)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
}
#endif
