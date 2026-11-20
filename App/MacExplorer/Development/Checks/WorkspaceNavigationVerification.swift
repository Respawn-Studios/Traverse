#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

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
    static func run(in testRoot: URL, settings inheritedSettings: BrowserSettings? = nil,
                    gitOnly: Bool = false, gitIndexOnly: Bool = false) async throws -> Outcome {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Workspace verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("workspace-navigation-\(UUID().uuidString)", isDirectory: true)
        let firstFolder = owned.appendingPathComponent("Folder A", isDirectory: true)
        let secondFolder = owned.appendingPathComponent("Folder B", isDirectory: true)
        let alternateFolder = owned.appendingPathComponent("Folder C", isDirectory: true)
        let firstFile = firstFolder.appendingPathComponent("alpha Café.txt")
        let secondFile = secondFolder.appendingPathComponent("beta.txt")
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-workspace-navigation-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try manager.createDirectory(at: firstFolder, withIntermediateDirectories: false)
            try manager.createDirectory(at: secondFolder, withIntermediateDirectories: false)
            try manager.createDirectory(at: alternateFolder, withIntermediateDirectories: false)
            try Data("generated workspace A".utf8).write(to: firstFile, options: .withoutOverwriting)
            try Data("generated workspace B".utf8).write(to: secondFile, options: .withoutOverwriting)
            try Data("generated hidden item".utf8).write(to: firstFolder.appendingPathComponent(".Hidden"),
                options: .withoutOverwriting)
        }.value
        let settings = inheritedSettings ?? BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false
        let recordsMotion = ProcessInfo.processInfo.arguments.contains("pane-motion")
            && !ProcessInfo.processInfo.arguments.contains("--offscreen")
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        let sampleVolumes = [
            VolumeInfo(url: firstFolder, name: "Sample Storage", kind: .internalDisk,
                       totalBytes: 100_000_000_000, availableBytes: 62_000_000_000),
            VolumeInfo(url: secondFolder, name: "Sample External", kind: .externalDisk,
                       totalBytes: 32_000_000_000, availableBytes: 18_000_000_000)
        ]
        if recordsMotion {
            primary.volumes = sampleVolumes
            primary.readVolumesForVerification = { sampleVolumes }
        }
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
        let contentSize = NSSize(width: 1400, height: 900)
        let window = BrowserWindow(contentRect: NSRect(origin: NSPoint(x: 50, y: 50), size: contentSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.workspace = workspace
        window.acceptsMouseMovedEvents = true
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
        let visibleFilterQualification = (gitOnly || ProcessInfo.processInfo.arguments.contains("--check-substantial")
            || ProcessInfo.processInfo.arguments.contains("pane-motion"))
            && !ProcessInfo.processInfo.arguments.contains("--offscreen")
        if visibleFilterQualification { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        var clips: [[String: Any]] = []
        func prepareMotionFrame() -> () -> Void {
            let originalFrame = window.frame
            let contentSize = NSSize(width: 1120, height: 740)
            guard recordsMotion, window.contentRect(forFrameRect: originalFrame).size != contentSize else { return {} }
            window.setContentSize(contentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            return {
                window.setFrame(originalFrame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        func record(_ label: String, field: NSView? = nil, comparisonPane: NSView? = nil, includeBackdrop: Bool = false,
                    settled: (() throws -> Void)? = nil, action: @MainActor () throws -> Void) async throws {
            guard recordsMotion else { try action(); return }
            try require(workspace.browsers.values.allSatisfy { $0.volumes == sampleVolumes && $0.readVolumesForVerification != nil },
                        "Workspace capture has observations outside the generated volume fixture")
            // Keep the wide functional control intact. Only the recorded
            // action uses this compact, admitted WindowServer canvas.
            let restoreFrame = prepareMotionFrame()
            defer { restoreFrame() }
            let fieldPresent = field.map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? false
            window.title = "Panes · generated review · motion audit"
            // Keep the established pane contrast clips composited over their
            // generated backdrop. Fixed-window clips also cover child-window
            // changes such as dismissing the compact filter during a close.
            let backdrop = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.title = "Panes backdrop · generated review · motion audit"
            backdrop.isReleasedWhenClosed = false; backdrop.isRestorable = false
            backdrop.backgroundColor = .systemIndigo; backdrop.isOpaque = true; backdrop.ignoresMouseEvents = true
            backdrop.order(.below, relativeTo: window.windowNumber)
            defer { backdrop.close() }
            var actionMilliseconds: Double = 0
            let movie = try await NativeMotionRecorder.record(window: window, over: includeBackdrop ? backdrop : nil, root: testRoot, label: label,
                sampling: .diagnostic(for: window, preRollMilliseconds: 260), includingChildWindows: false, fixedWindow: !includeBackdrop) {
                let began = CACurrentMediaTime()
                try action()
                actionMilliseconds = (CACurrentMediaTime() - began) * 1000
            }
            try JSONEncoder().encode(movie).write(to: testRoot.appendingPathComponent("evidence/\(label).json"),
                options: .withoutOverwriting)
            var clip = DevelopmentMotionVerification.clip(label, report: movie, field: field, window: window)
            clip["actionMilliseconds"] = actionMilliseconds
            if field != nil { clip["fieldPresentBeforeAction"] = fieldPresent }
            if let comparisonPane, let region = DevelopmentMotionVerification.visibleRegion(of: comparisonPane, in: window, report: movie) {
                // Use the body, away from divider, native focus ring and title.
                let control = NSRect(x: region.minX.rounded(.up) + 24, y: region.minY.rounded(.up) + 115,
                    width: min(220, region.width.rounded(.down) - 48), height: min(125, region.height.rounded(.down) - 140))
                try require(!control.isEmpty && region.contains(control), "Stable pane crop did not fit its view")
                clip["paneBodyRegion"] = [Int(control.minX), Int(control.minY), Int(control.width), Int(control.height)]
            } else if comparisonPane != nil {
                throw UIVerification.Failure(message: "The comparison pane was outside the recording")
            }
            clips.append(clip)
            try settled?()
        }
        workspace.startBrowser(primary)
        try await waitUntil("Initial generated pane listing") { primary.rowsByURL[firstFile] != nil && !primary.isLoading && primary.orderingTask == nil }
        if gitOnly {
            primary.recoverableFileOperations = RecoverableFileOperations(
                journalDirectory: owned.appendingPathComponent("comparison-history", isDirectory: true))
            return .init(checks: try await GitBrowserVerification.run(in: workspace, window: window, owned: owned,
                indexOnly: gitIndexOnly), clips: [])
        }
        var checks: [String] = []
        checks.append("The real pane is constructed at 400 by 220 before content is pinned; early native layout fills its inset and subsequent ancestor layout preserves containment, with numeric observations retained")
        try require(workspace.browsers.count == 1 && !workspace.preview.isEnabled, "Workspace did not start with one pane and preview off")
        try require(workspace.paneHosts.values.allSatisfy { !$0.showsFocusOutline },
                    "A single-pane workspace must not draw an active-pane outline")
        if recordsMotion && settings.motion.allows(.panes) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            var collapseProbe: Task<[String: Double], Error>?
            let expandedWidth = workspace.sidebarHost.frame.width
            let menu = BrowserMenus.menu(.view, target: primary)
            let toggle = #selector(BrowserViewController.toggleSidebar(_:))
            guard let command = menu.items.first(where: { $0.action == toggle }),
                  let sidebar = workspace.sidebarHost.subviews.first else {
                throw UIVerification.Failure(message: "Sidebar view command or live content is unavailable")
            }
            try await record("sidebar-collapse") {
                try require(primary.validateMenuItem(command) && command.title == "Hide Sidebar"
                    && NSApp.sendAction(toggle, to: primary, from: command), "View menu refused animated Sidebar collapse")
                let began = CACurrentMediaTime()
                collapseProbe = Task { @MainActor in
                    try await Task.sleep(for: .milliseconds(50))
                    return ["elapsed": CACurrentMediaTime() - began,
                        "width": Double(workspace.sidebarHost.frame.width),
                        "contentWidth": Double(sidebar.frame.width), "contentX": Double(sidebar.frame.minX),
                        "alpha": Double(workspace.sidebarRestoreButton.alphaValue),
                        "animating": workspace.hasSidebarAnimationForVerification ? 1 : 0]
                }
                try require(workspace.hasSidebarAnimationForVerification
                    && !workspace.sidebarRestoreButton.isHidden && workspace.sidebarRestoreButton.alphaValue < 0.1,
                    "Sidebar restore button appeared fully opaque before its collapse transition")
            }
            guard let collapseProbe else { throw UIVerification.Failure(message: "Sidebar progress probe did not start") }
            let observed = try await collapseProbe.value
            try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
                .write(to: testRoot.appendingPathComponent("evidence/sidebar-progress.json"), options: .withoutOverwriting)
            try require(observed["animating"] == 1 && (observed["width"] ?? 0) > 1
                && (observed["width"] ?? expandedWidth) < expandedWidth - 1,
                "Sidebar geometry jumped to its final width instead of traversing intermediate frames")
            try require(abs((observed["contentWidth"] ?? 0) - expandedWidth) < 1
                && (observed["contentX"] ?? 0) < -1 && workspace.sidebarHost.clipsToBounds,
                "Sidebar content reflowed or did not slide inside its clipped viewport")
            try require(workspace.isSidebarCollapsed && !workspace.sidebarRestoreButton.isHidden
                && workspace.sidebarRestoreButton.alphaValue == 1, "Collapsed sidebar did not settle its restore button")
            try await record("sidebar-expand") {
                let restore = workspace.sidebarRestoreButton
                // Start the recorder at action dispatch. performClick can run
                // native highlight tracking before returning to the probe.
                try require(restore.isEnabled && restore.action.map {
                    NSApp.sendAction($0, to: restore.target, from: restore)
                } == true, "Footer button refused animated Sidebar restore")
                try require(workspace.hasSidebarAnimationForVerification
                    && !workspace.sidebarRestoreButton.isHidden && workspace.sidebarRestoreButton.alphaValue > 0.9,
                    "Sidebar restore button vanished before expansion completed")
            }
            try require(!workspace.isSidebarCollapsed && workspace.sidebarRestoreButton.isHidden,
                "Expanded sidebar retained its restore button")
            workspace.setSidebarCollapsed(true)
            try await Task.sleep(for: .milliseconds(45))
            let interruptedWidth = workspace.sidebarHost.frame.width
            workspace.setSidebarCollapsed(false)
            try require(abs(workspace.sidebarHost.frame.width - interruptedWidth) < 1,
                "Retargeting a moving sidebar jumped to the previous destination")
            try await waitUntil("Sidebar retargeting") { !workspace.hasSidebarAnimationForVerification }
            try require(abs(workspace.sidebarHost.frame.width - expandedWidth) < 1 && workspace.sidebarRestoreButton.isHidden,
                "Sidebar retargeting did not restore its original width")
            checks.append("View menu and footer restore slide the same live sidebar at expanded width inside its viewport; the footer button fades with the divider")
        }
        guard let singleName = primary.table.tableColumn(withIdentifier: .init("name")),
              let singleDate = primary.table.tableColumn(withIdentifier: .init("modified")) else {
            throw UIVerification.Failure(message: "Single-pane column control is unavailable")
        }
        let singlePaneColumns = (viewport: primary.folderScroll.contentSize.width,
            name: singleName.width, date: singleDate.width, scale: InterfaceMetrics.scale)
        let paneMotion = visibleFilterQualification && settings.motion.allows(.panes)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try require(NativeForegroundSnapshot.fits([.init(width: 740, height: 950), .init(width: 740, height: 950)], scale: 2)
            && !NativeForegroundSnapshot.fits([.init(width: 1480, height: 950), .init(width: 740, height: 950)], scale: 2)
            && !NativeForegroundSnapshot.fits([.init(width: 2880, height: 1620)], scale: 2),
            "Pane image budget must count the affected native pixels across the whole swap")
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
        var hoverTarget: NSButton?
        var hoverEvents: [String] = []
        var recordingHover = false
        let hoverMonitor = recordsMotion ? NSEvent.addLocalMonitorForEvents(matching: [.mouseEntered, .mouseExited, .mouseMoved]) { event in
            MainActor.assumeIsolated {
                if recordingHover, event.window === window, hoverEvents.count < 24 {
                    let local = workspace.paneTreeHost.convert(event.locationInWindow, from: nil)
                    let isDividerArea = event.type != .mouseMoved && event.trackingArea?.owner is WorkspaceDividerControls
                    hoverEvents.append("\(event.type.rawValue)/divider=\(isDividerArea)/inside=\(workspace.paneTreeHost.bounds.contains(local))")
                }
            }
            return event
        } : nil
        defer { if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) } }
        // Keep one geometry and the same native control through hover and retirement.
        do {
            let restoreFrame = prepareMotionFrame()
            defer { recordingHover = false; restoreFrame() }
            func hoverState() -> String {
                "key=\(window.isKeyWindow) alpha=\(hoverTarget?.superview?.alphaValue ?? -1) nativeEvents=\(hoverEvents)"
            }
            try await record("pane-divider-hover", settled: {
                let visible = hoverTarget.map { target in
                    !target.isHiddenOrHasHiddenAncestor && (target.superview?.alphaValue ?? 0) > 0.95 && target.window === window
                } == true
                print("PANE_DIVIDER_HOVER_SETTLED \(visible) \(hoverState())")
                try require(visible, "The native divider button disappeared during the recorded hover. " + hoverState())
            }) {
                recordingHover = true
                let button = try dividerButton(.swap, split: workspace.layout.rootID, in: workspace, sendingWindowEvent: !recordsMotion)
                hoverTarget = button
                let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                if recordsMotion { workspace.updatePaneDividerHover(at: center) }
                else { sendDividerMouseMove(to: center, in: workspace, window: window) }
                try require(workspace.isPaneDividerButton(at: center), "Moving onto a displayed divider control dismissed it")
            }
            if recordsMotion {
                try await record("pane-divider-retirement", settled: {
                    try require(hoverTarget?.isHiddenOrHasHiddenAncestor == true, "Divider retirement did not hide its native control")
                }) {
                    guard let button = hoverTarget, button.window === window, !button.isHiddenOrHasHiddenAncestor,
                          (button.superview?.alphaValue ?? 0) > 0.95 else {
                        throw UIVerification.Failure(message: "The divider control was unavailable before the recorded retirement. " + hoverState())
                    }
                    let center = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let away = workspace.paneTreeHost.convert(.init(x: 40, y: workspace.paneTreeHost.bounds.midY), to: nil)
                    workspace.updatePaneDividerHover(at: away)
                    try require(!workspace.isPaneDividerButton(at: center), "Leaving the divider retained its old click target")
                }
            }
        }
        workspace.dismissPaneDividerControls()
        checks.append("Actual side-by-side native tables retain readable Name columns at100/150%, shrink default metadata first, scroll constrained columns, and retain native synthetic header resize choices; physical pointer input is not exercised")
        try await capture(workspace, window: window, owned: owned, name: "two-panes")
        workspace.activate(primary)
        primary.setFileSelection([])
        try require(!primary.commandEnabled(BrowserCommand.compareFolders.selector),
                    "Two visits to the same folder enabled Compare Folders")
        primary.navigate(to: .directory(secondFolder))
        try await waitUntil("Independent primary navigation") { primary.rowsByURL[secondFile] != nil && !primary.isLoading && primary.orderingTask == nil }
        try require(peer.location == .directory(firstFolder) && peer.tabs[peer.activeIndex].filter == "alpha", "One pane's navigation/filter changed another")
        primary.setFileSelection([secondFile]); primary.focusBrowserContent()
        let swapped = [peer.paneID, primary.paneID]
        let originals = workspace.layout.paneIDs
        let paneLocations = workspace.browsers.mapValues(\.location)
        let paneVisits = workspace.browsers.mapValues(\.sessionID)
        let paneTabIDs = workspace.browsers.mapValues { $0.tabs.map(\.id) }
        let rootSplit = workspace.layout.rootID
        try await record("pane-swap-columns") {
            let responder = window.firstResponder
            try pressDivider(.swap, split: rootSplit, in: workspace)
            try require(workspace.layout.paneIDs == swapped && workspace.activeBrowser === primary
                && window.firstResponder === responder && primary.orderedSelectedURLs == [secondFile]
                && workspace.browsers.mapValues(\.location) == paneLocations
                && workspace.browsers.mapValues(\.sessionID) == paneVisits
                && workspace.browsers.mapValues({ $0.tabs.map(\.id) }) == paneTabIDs,
                "The divider swap rebuilt a visit, dropped selection or changed focus")
            if paneMotion {
                try require(workspace.paneTransitionCapturedForVerification == Set(swapped), "The swap did not capture exactly its two sides")
            } else if !settings.motion.allows(.panes) {
                try require(!workspace.hasPaneTransitionForVerification, "Motion Off captured a swap")
            }
        }
        try verifyGeometry(workspace, stage: "swapped columns")
        let viewMenu = BrowserMenus.menu(.view, target: primary)
        guard let menuSwap = viewMenu.items.first(where: { $0.action == BrowserCommand.swapPaneSides.selector }),
              primary.validateMenuItem(menuSwap), NSApp.sendAction(BrowserCommand.swapPaneSides.selector, to: primary, from: menuSwap) else {
            throw UIVerification.Failure(message: "Native View menu could not swap the active pane at its own divider")
        }
        try require(workspace.layout.paneIDs == originals, "Swapping back did not recover the original pane order")
        guard let nativeSplit = workspace.paneHosts[primary.paneID]?.superview as? NSSplitView else {
            throw UIVerification.Failure(message: "Swapped leaves lost their native split owner")
        }
        nativeSplit.setPosition(nativeSplit.bounds.width * 0.57, ofDividerAt: 0)
        try require(workspace.canPerformDividerAction(.balance), "The native divider could not resize after swapping")
        try await record("pane-balance-columns") { try pressDivider(.balance, split: rootSplit, in: workspace) }
        try require(!workspace.canPerformDividerAction(.balance) && workspace.layout.paneIDs == originals,
                    "Balance changed pane order or left the split unbalanced")
        checks.append("Native divider controls leave a resize corridor, retain tabs, visits, selection and first responder through Swap, and balance a manually resized split. View exposes the same swap command.")
        let originalLayout = workspace.layout
        try await record("pane-stack") {
            let responder = window.firstResponder
            try pressDivider(.rotate, split: rootSplit, in: workspace)
            guard case .split(.rows, 0.5, let first, let second)? = workspace.layout.node(rootSplit)?.content else {
                throw UIVerification.Failure(message: "Stack Panes did not orient the existing native divider")
            }
            try require([first, second] == originals && nativeSplit.isVertical == false
                && workspace.activeBrowser === primary && window.firstResponder === responder
                && primary.orderedSelectedURLs == [secondFile] && workspace.browsers.mapValues(\.location) == paneLocations
                && workspace.browsers.mapValues(\.sessionID) == paneVisits
                && workspace.browsers.mapValues({ $0.tabs.map(\.id) }) == paneTabIDs,
                "Stack Panes replaced a tab, visit, selection or first responder")
            if paneMotion {
                try require(workspace.paneTransitionCapturedForVerification == Set(originals),
                    "The direction change did not capture exactly its affected panes")
            } else if !settings.motion.allows(.panes) {
                try require(!workspace.hasPaneTransitionForVerification, "Motion Off captured a direction change")
            }
            try verifyGeometry(workspace, stage: "rotated rows")
        }
        try await record("pane-side-by-side") {
            guard let rotate = viewMenu.items.first(where: { $0.action == BrowserCommand.rotatePaneSplit.selector }),
                  primary.validateMenuItem(rotate), NSApp.sendAction(BrowserCommand.rotatePaneSplit.selector, to: primary, from: rotate) else {
                throw UIVerification.Failure(message: "Native View menu could not change the existing pane direction")
            }
            try require(workspace.layout == originalLayout && nativeSplit.isVertical,
                        "Changing direction twice did not restore the previous arrangement")
        }
        if !recordsMotion {
            peer.setFileSelection([])
            try pressDivider(.compare, split: rootSplit, in: workspace)
            guard let fromDivider = workspace.folderComparisonWindow else {
                throw UIVerification.Failure(message: "The divider did not open Folder Comparison")
            }
            try require(fromDivider.session.left == secondFolder && fromDivider.session.right == firstFolder,
                "Divider Compare used the selected file or a different pane")
            _ = try await comparisonResult(fromDivider)
            fromDivider.close()
            if visibleFilterQualification { window.makeKeyAndOrderFront(nil) }
            primary.setFileSelection([])
            let context = BrowserMenus.fileContextMenu(target: primary)
            let compare = try startComparison(in: context, from: primary, left: secondFolder, right: firstFolder)
            defer { compare.close() }
            let report = try await comparisonResult(compare)
            try require(report.rows.map(\.difference) == [.onlyOnRight, .onlyOnLeft],
                        "The comparison did not use the two current pane folders")
            compare.close()
            try require(workspace.folderComparisonWindow == nil, "Closed comparison stayed attached to the workspace")
            if visibleFilterQualification { window.makeKeyAndOrderFront(nil) }
            checks.append("The divider compares the two displayed local folders with a file still selected. The native background context menu uses the same report and closes cleanly.")
            try await verifyLinkedNavigation(workspace, first: primary, second: peer, owned: owned)
            checks.append("Linked pane navigation follows matching folders in both directions, preserves Back/Forward, leaves a missing peer alone, and stays attached to its tabs through a swap. Unlink and tab switching end the link.")
        }
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
        if paneMotion && settings.motion.allows(.tabContent) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try require(!workspace.hasPaneTransitionForVerification
                && [primary, peer].allSatisfy { $0.canvasTransition?.visit == $0.sessionID && $0.canvasTransition?.image != nil },
                "Moving between existing panes did not animate only the two replaced tab canvases")
        }
        primary.tabStrip.invalidateManagementInteraction()
        try require(workspace.moveTab(history.id, from: peer, into: primary, before: spare.id),
                    "Whole-preview fixture could not restore its exact source tab for remaining edge checks")
        try await waitUntil("Restored whole-preview fixture visits") {
            !primary.isLoading && primary.orderingTask == nil && !peer.isLoading && peer.orderingTask == nil
        }
        if recordsMotion {
            try await waitUntil("Preceding tab move settled before recording the edge drop") {
                !workspace.hasPaneTransitionForVerification
                    && workspace.browsers.values.allSatisfy { $0.canvasTransition == nil }
            }
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
        try await record("pane-split-neighbour", comparisonPane: untouched, includeBackdrop: true) {
            let untouchedFrame = untouched.convert(untouched.bounds, to: workspace.paneTreeHost)
            authenticated.draggingLocation = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.minY + 8), to: nil)
            try require(host.performDragOperation(authenticated), "Authenticated edge drop failed")
            if paneMotion {
                try require(untouched.convert(untouched.bounds, to: workspace.paneTreeHost) == untouchedFrame
                    && workspace.paneTransitionFramesForVerification[primary.paneID] == nil
                    && workspace.paneTransitionCapturedForVerification == [peer.paneID],
                    "An in-place split captured or moved a neighbouring pane")
                if settings.motion.allows(.tabContent) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    try require(primary.canvasTransition?.visit == primary.sessionID
                        && primary.canvasTransition?.image != nil,
                        "Moving the active tab replaced the stationary source without its normal content transition")
                }
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

        guard let rowSplit = workspace.layout.parent(of: moved.paneID)?.id else {
            throw UIVerification.Failure(message: "Transferred pane has no row divider")
        }
        let beforeRows = workspace.layout.paneIDs
        let beforeRefusal = workspace.layout
        try require(!workspace.canPerformDividerAction(.rotate, split: rowSplit)
            && !workspace.performDividerAction(.rotate, split: rowSplit) && workspace.layout == beforeRefusal,
            "The nested divider rotated into a width that could not hold both panes")
        try await record("pane-swap-rows", comparisonPane: untouched) {
            let stableFrame = untouched.convert(untouched.bounds, to: workspace.paneTreeHost)
            let parent = untouched.superview
            try pressDivider(.swap, split: rowSplit, in: workspace)
            try require(workspace.layout.paneIDs == [primary.paneID, moved.paneID, peer.paneID]
                && workspace.activeBrowser === moved && untouched.superview === parent
                && untouched.convert(untouched.bounds, to: workspace.paneTreeHost) == stableFrame,
                "Row swap moved or detached its unrelated pane")
            if paneMotion {
                try require(workspace.paneTransitionCapturedForVerification == [peer.paneID, moved.paneID],
                            "Row swap captured an unrelated pane")
            }
        }
        try require(workspace.performDividerAction(.swap, split: rowSplit) && workspace.layout.paneIDs == beforeRows,
                    "Rows did not return to their previous layout")
        checks.append("Stacked divider control swaps only its adjacent row panes, preserves the active browser, and leaves the independent side untouched")
        checks.append("The divider and native View change between stacked and side-by-side panes in place, retain exact visits and focus, and refuse a nested split with insufficient room")

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
        try await record("pane-split-unaffected", field: peer.navigationSurface,
                         comparisonPane: workspace.paneHosts[primary.paneID], includeBackdrop: true) {
            guard let stable = workspace.paneHosts[primary.paneID] else {
                throw UIVerification.Failure(message: "Unchanged pane disappeared before fourth split")
            }
            let before = stable.convert(stable.bounds, to: workspace.paneTreeHost), visit = primary.sessionID
            let stableParent = stable.superview
            let peerParent = workspace.paneHosts[peer.paneID]?.superview
            let fractions = Dictionary(uniqueKeysWithValues: workspace.layout.nodes.compactMap { node -> (UUID, Double)? in
                if case .split(_, let fraction, _, _) = node.content { return (node.id, fraction) }
                return nil
            })
            try require(workspace.splitActive(at: .top), "Fourth pane stretch failed in a sufficiently sized workspace")
            workspace.activeBrowser.permitsBackgroundVerification = true
            fourthVisitBeforeLoading = workspace.activeBrowser.sessionID
            try require(stable.superview === stableParent && workspace.paneHosts[peer.paneID]?.superview === peerParent,
                "Splitting another branch detached an unchanged native pane")
            for (id, expectedFraction) in fractions {
                if case .split(_, let fraction, _, _)? = workspace.layout.node(id)?.content {
                    try require(fraction == expectedFraction, "Native tree reconciliation persisted a transient divider fraction")
                }
            }
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
        let destinations = LocalPaneDestination.available(from: fourthPane)
        try require(destinations.count >= 2, "Multiple eligible native pane destinations were not offered")
        let choice = LocalPaneDestination.choose(destinations, from: fourthPane, in: fourthPane.table, title: "Choose a Pane") {
            menu, _ in menu.performActionForItem(at: 1)
        }
        try require(choice == destinations[1], "The shared menu selected a different destination")
        var staleDestinations = destinations
        let staleDestination = destinations[1]
        staleDestinations[1] = .init(pane: staleDestination.pane, tab: staleDestination.tab,
                                     visit: UUID(), directory: staleDestination.directory, title: staleDestination.title)
        let refused = LocalPaneDestination.choose(staleDestinations, from: fourthPane, in: fourthPane.table, title: "Choose a Pane") {
            menu, _ in menu.performActionForItem(at: 1)
        }
        var singleOpenedMenu = false
        let direct = LocalPaneDestination.choose([destinations[0]], from: fourthPane, in: fourthPane.table, title: "Choose a Pane") {
            _, _ in singleOpenedMenu = true
        }
        try require(refused == nil && !singleOpenedMenu && direct == destinations[0],
                    "Stale or single-pane destinations missed their native selection policy")
        checks.append("Shared Download to Pane uses a native menu for multiple choices, refuses stale visits, and bypasses the menu for one choice")
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
        if !recordsMotion {
            let browser = workspace.activeBrowser
            let previousEngine = browser.recoverableFileOperations
            defer { browser.recoverableFileOperations = previousEngine }
            if visibleFilterQualification {
                browser.recoverableFileOperations = RecoverableFileOperations(
                    journalDirectory: owned.appendingPathComponent("comparison-history", isDirectory: true))
            }
            browser.navigate(to: .directory(owned))
            try await waitUntil("Generated comparison selection") {
                !browser.isLoading && browser.orderingTask == nil
                    && browser.rowsByURL[firstFolder] != nil && browser.rowsByURL[secondFolder] != nil
            }
            browser.setFileSelection([firstFolder, secondFolder])
            browser.fileSelectionDidChange()
            let selected = browser.orderedSelectedURLs
            try require(Set(selected) == [firstFolder, secondFolder], "Both comparison fixture folders must be selected")
            let menu = BrowserMenus.menu(.file, target: browser)
            let compare = try startComparison(in: menu, from: browser, left: selected[0], right: selected[1])
            defer { compare.close() }
            let report = try await comparisonResult(compare)
            let expected: [FolderComparisonReport.Difference] = selected[0] == firstFolder
                ? [.onlyOnLeft, .onlyOnRight] : [.onlyOnRight, .onlyOnLeft]
            try require(report.rows.map(\.difference) == expected,
                        "The File menu compared different folders than the displayed selection")
            compare.session.refresh()
            compare.session.stop()
            try await waitUntil("Comparison cancellation") { !compare.session.isReading }
            if case .stopped = compare.session.state {} else {
                throw UIVerification.Failure(message: "Stopped comparison presented a stale result")
            }
            compare.session.setHidden(true)
            let hidden = try await comparisonResult(compare)
            try require(hidden.rows.first?.relativePath == ".Hidden", "Showing hidden items did not refresh the same pair")
            if let comparisonWindow = compare.window {
                try await UIVerification.snapshot(comparisonWindow, to: owned.appendingPathComponent("folder-comparison.png"))
                let previousBinding = InterfacePresentation.shared.settings
                let previousSize = settings.interfaceSize
                defer {
                    settings.interfaceSize = previousSize
                    if let previousBinding { InterfacePresentation.shared.bind(previousBinding) }
                }
                InterfacePresentation.shared.bind(settings)
                settings.interfaceSize = InterfaceSize(150)
                comparisonWindow.setContentSize(.init(width: 620, height: 480))
                try await UIVerification.snapshot(comparisonWindow, to: owned.appendingPathComponent("folder-comparison-enlarged.png"))
                if visibleFilterQualification {
                    try await waitUntil("Comparison window owns the menu") {
                        comparisonWindow.isKeyWindow && ToolWindowMenuOwnership.owns(compare)
                    }
                    let commands = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items ?? []
                    let close = commands.first { $0.action == #selector(NSWindow.performClose(_:)) }
                    try require(commands.contains { $0.title == "Refresh" && $0.target === compare }
                        && close?.target === comparisonWindow
                        && !commands.contains { $0.target is BrowserViewController },
                        "The key comparison window's File actions differ: \(commands.map(\.title))")
                    guard let row = hidden.rows.firstIndex(where: { $0.relativePath == firstFile.lastPathComponent }),
                          let hiddenRow = hidden.rows.firstIndex(where: { $0.relativePath == ".Hidden" }),
                          let reverseRow = hidden.rows.firstIndex(where: { $0.relativePath == secondFile.lastPathComponent }),
                          let copy = commands.first(where: { $0.title == "Copy Missing Files" }),
                          let reviewCopy = commands.first(where: { $0.title == "Review Copy…" }), let copyAction = reviewCopy.action,
                          let open = commands.first(where: { $0.title == "Open Text Diff" }), let action = open.action else {
                        throw UIVerification.Failure(message: "Folder text review did not expose its native row and action")
                    }
                    try require(!compare.validateMenuItem(open) && !compare.validateMenuItem(copy) && !compare.validateMenuItem(reviewCopy),
                                "A comparison file action enabled before selecting a file")
                    try await verifyFolderPathFilter(compare, in: comparisonWindow, report: hidden, first: row,
                                                     second: reverseRow, owned: owned)
                    guard let table = UIVerification.nativeTables(in: comparisonWindow.contentView).first else {
                        throw UIVerification.Failure(message: "Closing the folder filter did not restore its native table")
                    }
                    checks.append("Folder Comparison filters the captured report by ordinary typed path and direction. Hidden selections lose Copy authority, Down selects a visible row and Escape restores the table at enlarged size.")
                    try await UIVerification.clickRow(row, in: table)
                    try require(compare.validateMenuItem(open) && NSApp.sendAction(action, to: compare, from: open),
                        "The selected folder difference did not open the shared text viewer")
                    guard let diff = workspace.textComparisonWindow else { throw UIVerification.Failure(message: "Folder Text Diff window was missing") }
                    try await waitUntil("Folder text diff is prepared and visible") { !diff.hasWorkForVerification && diff.window?.isKeyWindow == true }
                    let onLeft = selected[0] == firstFolder
                    try require(diff.beforeSurface.textView.string == (onLeft ? "generated workspace A" : "")
                        && diff.currentSurface.textView.string == (onLeft ? "" : "generated workspace A")
                        && diff.planForVerification?.changedLineCounts?.removed == (onLeft ? 1 : 0)
                        && diff.planForVerification?.changedLineCounts?.added == (onLeft ? 0 : 1),
                        "The folder comparison showed different text or counted the absent file as a line")
                    await diff.closeAndDrain()
                    comparisonWindow.makeKeyAndOrderFront(nil)
                    checks.append("One-sided file rows open exact read-only text and line counts from the folder comparison’s native File menu")
                    let originalSelection = compare.session.selectedRows
                    try await UIVerification.verifyDiffSearch(in: comparisonWindow, workspace: workspace,
                        query: "generated workspace B", expectedPath: secondFile.lastPathComponent, files: 3,
                        expectedSide: onLeft ? .current : .before)
                    try require(compare.session.selectedRows == originalSelection, "Search across folder diffs changed the originating selection")
                    checks.append("Find Across Diffs searches the displayed local folder comparison and opens the matching side and line without moving the report selection")
                    try require(compare.validateMenuItem(copy) && copy.title == (onLeft ? "Copy to Right" : "Copy to Left"),
                                "The selected row did not offer its missing destination")
                    table.selectRowIndexes(IndexSet([row, reverseRow]), byExtendingSelection: false)
                    try await waitUntil("Native table selects the opposite pair") { compare.session.selectedRows == [row, reverseRow] }
                    try require(!compare.validateMenuItem(copy) && !compare.validateMenuItem(reviewCopy)
                        && !compare.validateMenuItem(open), "Mixed copy directions or text pairs were not refused")
                    table.selectRowIndexes(IndexSet([row, hiddenRow]), byExtendingSelection: false)
                    try await waitUntil("Native table selects the same-direction pair") { compare.session.selectedRows == [row, hiddenRow] }
                    try require(compare.validateMenuItem(copy)
                        && copy.title == (onLeft ? "Copy 2 to Right" : "Copy 2 to Left"),
                        "The two selected files did not offer a single copy to their missing destination")
                    try await UIVerification.snapshot(comparisonWindow, to: owned.appendingPathComponent("folder-comparison-copy-150.png"))
                    try require(compare.validateMenuItem(reviewCopy) && NSApp.sendAction(copyAction, to: compare, from: reviewCopy),
                        "The native comparison Copy review did not route")
                    try await waitUntil("Copy review opens before starting the transfer") {
                        comparisonWindow.attachedSheet != nil && !compare.session.isCopying
                    }
                    guard let firstReview = comparisonWindow.attachedSheet, let reviewContent = firstReview.contentView else {
                        throw UIVerification.Failure(message: "Copy review had no native sheet")
                    }
                    func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }
                    let names = views(in: reviewContent).compactMap { ($0 as? NSTextView)?.string }
                    let labels = views(in: reviewContent).compactMap { ($0 as? NSTextField)?.stringValue }
                    try require(names.contains { $0.contains(firstFile.lastPathComponent) && $0.contains(".Hidden") }
                        && labels.contains { $0.contains(firstFolder.path) && $0.contains(secondFolder.path) },
                        "Copy review did not show both selected names and the exact folders")
                    comparisonWindow.endSheet(firstReview, returnCode: .alertSecondButtonReturn)
                    try await waitUntil("Cancel keeps both files eligible for the same copy") {
                        comparisonWindow.isKeyWindow && comparisonWindow.attachedSheet == nil && compare.session.selectedCopy?.sources.count == 2
                    }
                    try require(NSApp.sendAction(copyAction, to: compare, from: reviewCopy), "Copy review did not reopen after Cancel")
                    try await waitUntil("Copy review is ready to confirm") { comparisonWindow.attachedSheet != nil }
                    guard let confirmed = comparisonWindow.attachedSheet else {
                        throw UIVerification.Failure(message: "Missing confirmed Copy review sheet")
                    }
                    comparisonWindow.endSheet(confirmed, returnCode: .alertFirstButtonReturn)
                    try await waitUntil("Comparison Copy and automatic refresh") {
                        !compare.session.isCopying && !compare.session.isReading &&
                            compare.session.notice == "Copy complete. Undo is available."
                    }
                    let refreshed = try await comparisonResult(compare)
                    try require(refreshed.matchingFiles == 2 && !refreshed.rows.contains(where: {
                        $0.relativePath == firstFile.lastPathComponent || $0.relativePath == ".Hidden"
                    }), "The refreshed comparison still reported a copied file as missing")
                    let delivered = secondFolder.appendingPathComponent(firstFile.lastPathComponent)
                    let deliveredHidden = secondFolder.appendingPathComponent(".Hidden")
                    let sameBytes = try await Task.detached {
                        try Data(contentsOf: delivered) == Data(contentsOf: firstFile)
                            && Data(contentsOf: deliveredHidden) == Data("generated hidden item".utf8)
                    }.value
                    try require(sameBytes, "The comparison copy did not deliver both files' exact original bytes")
                    checks.append("The native directional copy review lists the selected group before submission, Cancel leaves it available, and one confirmation copies both files with Undo.")
                    guard let missing = refreshed.rows.first(where: { $0.relativePath == secondFile.lastPathComponent }) else {
                        throw UIVerification.Failure(message: "The refreshed comparison model lost the remaining file")
                    }
                    try await waitUntil("Refreshed folder comparison table") {
                        UIVerification.nativeTables(in: comparisonWindow.contentView).first?.numberOfRows == refreshed.rows.count
                    }
                    guard let metadataTable = UIVerification.nativeTables(in: comparisonWindow.contentView).first else {
                        throw UIVerification.Failure(message: "The refreshed comparison table did not persist")
                    }
                    try await UIVerification.clickRow(missing.id, in: metadataTable)
                    let byteReviewName = "A same metadata.txt"
                    try await Task.detached {
                        let a = firstFolder.appendingPathComponent(byteReviewName)
                        let b = secondFolder.appendingPathComponent(byteReviewName)
                        let changedAt = Date(timeIntervalSince1970: 1_701_000_000)
                        try Data("left".utf8).write(to: a, options: .withoutOverwriting)
                        try Data("rght".utf8).write(to: b, options: .withoutOverwriting)
                        for url in [a, b] {
                            try FileManager().setAttributes([.modificationDate: changedAt], ofItemAtPath: url.path)
                        }
                    }.value
                    guard let check = commands.first(where: { $0.title == "Check Contents" }), let checkAction = check.action else {
                        throw UIVerification.Failure(message: "Compare Folders did not expose the native content check")
                    }
                    try require(compare.validateMenuItem(check) && NSApp.sendAction(checkAction, to: compare, from: check),
                        "Check Contents did not use the ordinary window command")
                    try require(compare.session.isReading && compare.session.displayedReport?.rows.map(\.id) == refreshed.rows.map(\.id)
                        && compare.session.selectedRows == [missing.id] && !compare.validateMenuItem(copy) && !compare.validateMenuItem(open),
                        "Check Contents hid its previous report or allowed stale actions while reading")
                    compare.session.stop()
                    let earlier = try await comparisonResult(compare)
                    try require(earlier.contentReview == nil && compare.session.selectedRows == [missing.id]
                        && compare.session.notice == "Content check stopped. Showing the earlier comparison."
                        && UIVerification.nativeTables(in: comparisonWindow.contentView).first === metadataTable,
                        "Stopping the content check lost the earlier table or selection")
                    try require(NSApp.sendAction(checkAction, to: compare, from: check),
                        "The stopped content check could not be started again")
                    let verified = try await comparisonResult(compare)
                    try require(verified.contentReview?.matches == 2 && verified.contentReview?.differences == 1
                        && verified.contentReview?.unchecked == 0
                        && verified.rows.count == 2
                        && verified.rows.contains(where: { $0.relativePath == byteReviewName && $0.difference == .differentContents })
                        && verified.rows.contains(where: { $0.relativePath == secondFile.lastPathComponent
                            && $0.difference == (onLeft ? .onlyOnRight : .onlyOnLeft)
                            && $0.id != missing.id && compare.session.selectedRows == [$0.id] }),
                        "The content review did not isolate the changed pair from matches and private recovery areas")
                    comparisonWindow.contentView?.layoutSubtreeIfNeeded()
                    guard let resultTable = UIVerification.nativeTables(in: comparisonWindow.contentView).first,
                          let scroll = resultTable.enclosingScrollView else {
                        throw UIVerification.Failure(message: "Content review did not have a native table")
                    }
                    let viewport = scroll.contentView.bounds.width
                    let rightEdge = resultTable.rect(ofColumn: 3).maxX
                    let nameWidth = resultTable.rect(ofColumn: 0).width
                    try require(resultTable === metadataTable && resultTable.numberOfColumns == 4 && rightEdge <= viewport + 1 && nameWidth >= 140,
                        "Content comparison columns did not fit at 150 percent: edge \(rightEdge), viewport \(viewport), name \(nameWidth)")
                    try await UIVerification.snapshot(comparisonWindow, to: owned.appendingPathComponent("folder-comparison-contents-150.png"))
                    guard let pairRow = verified.rows.first(where: { $0.relativePath == byteReviewName }) else {
                        throw UIVerification.Failure(message: "Folder comparison lost the two-sided editor test row")
                    }
                    try await UIVerification.clickRow(pairRow.id, in: resultTable)
                    try await verifyComparisonEditorOpen(compare, in: comparisonWindow,
                        files: selected.map { $0.appendingPathComponent(byteReviewName) },
                        contents: onLeft ? ["left", "rght"] : ["rght", "left"])
                    checks.append("Folder Compare opens both checked file versions in the native editor, keeps an already open draft and refuses a replaced file from the same report.")
                    let uncheckedName = "Larger than the content limit.txt"
                    try await Task.detached {
                        let bytes = Data(repeating: 0x58, count: (1 << 20) + 1)
                        for folder in [firstFolder, secondFolder] {
                            let url = folder.appendingPathComponent(uncheckedName)
                            try bytes.write(to: url, options: .withoutOverwriting)
                            try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_701_000_000)],
                                                            ofItemAtPath: url.path)
                        }
                    }.value
                    try require(compare.validateMenuItem(check) && NSApp.sendAction(checkAction, to: compare, from: check),
                                "The native content check did not start")
                    browser.setFileSelection([firstFolder, alternateFolder])
                    browser.fileSelectionDidChange()
                    try require(browser.canCompareFolders, "The alternate comparison pair could not be selected")
                    browser.compareFolders(nil)
                    try require(workspace.folderComparisonWindow === compare && compare.session.isReading
                        && compare.session.notice == FolderComparisonSession.otherPairBusyMessage
                        && compare.session.left == selected[0] && compare.session.right == selected[1],
                        "Requesting different folders silently reused or changed the active comparison")
                    browser.setFileSelection([firstFolder, secondFolder])
                    browser.fileSelectionDidChange()
                    let incomplete = try await comparisonResult(compare)
                    try require(incomplete.contentReview?.unchecked == 1 && incomplete.differenceCount == 2
                        && incomplete.rows.contains(where: { $0.relativePath == uncheckedName && $0.contents == .unchecked }),
                        "The native report hid a file whose contents were left unchecked")
                    compare.session.setFilter(.unchecked)
                    try await waitUntil("Unchecked content filter") {
                        !compare.session.isFiltering && compare.session.visibleRows.map(\.relativePath) == [uncheckedName]
                    }
                    try await UIVerification.snapshot(comparisonWindow, to: owned.appendingPathComponent("folder-comparison-incomplete-150.png"))
                    checks.append("An incomplete content check shows the unchecked path at enlarged size and a new folder pair receives explicit feedback while the original read drains")
                    compare.close()
                    window.makeKeyAndOrderFront(nil)
                    browser.focusBrowserContent()
                    try await waitUntil("Comparison Copy available to native Undo") { browser.canUndoFileOperation }
                    browser.undoFileOperation(nil)
                    await browser.operationPreparationTask?.value
                    await browser.operationTask?.value
                    let undone = await Task.detached {
                        !FileManager().fileExists(atPath: delivered.path) && !FileManager().fileExists(atPath: deliveredHidden.path)
                            && (try? Data(contentsOf: firstFile)) == Data("generated workspace A".utf8)
                            && (try? Data(contentsOf: secondFile)) == Data("generated workspace B".utf8)
                    }.value
                    try require(undone, "Undo did not remove only the two comparison copies")
                    checks.append("Same-folder Folder Comparison Copy uses one ordinary queue job, refreshes the report and preserves sources and their peer through native Undo")
                    checks.append("Check Contents keeps the native table and selection through Stop and successful reread, detects different bytes for equal metadata and fits at enlarged size")
                }
            }
            try require(browser.selectedURLs == [firstFolder, secondFolder], "Comparison changed the browser's folder selection")
            checks.append("The native File menu compares two selected folders in display order; hidden items refresh in place and Stop discards a pending result")
            compare.close()
            if visibleFilterQualification {
                window.makeKeyAndOrderFront(nil)
                browser.focusBrowserContent()
                try await waitUntil("Comparison Undo refreshes the visible browser") {
                    window.isKeyWindow && browser.nameSelection.canPresent
                }
                try await verifyNameSelection(browser, window: window, first: firstFolder, second: secondFolder)
                checks.append("Select by Name uses native sheet focus and Return for Replace, Add and Remove; no matches and Cancel preserve selection")
                try await verifyPaneTextComparison(workspace, window: window, left: firstFile, right: secondFile, owned: owned)
                checks.append("One selected text file in each local pane opens the exact diff. A single selection can compare or select its matching name from the divider or menus. Selection preserves the native source responder, refuses an occupied peer, and works for binary rows and folders in Icons.")
                checks += try await GitBrowserVerification.run(in: workspace, window: window, owned: owned)
            }
        }
        return .init(checks: checks, clips: clips)
    }

    private static func verifyPaneTextComparison(_ workspace: BrowserWorkspaceController, window: NSWindow,
                                                 left: URL, right: URL, owned: URL) async throws {
        let source = workspace.activeBrowser, originalFrame = window.frame
        window.setContentSize(.init(width: 1120, height: 740))
        defer { window.setFrame(originalFrame, display: true) }
        workspace.view.layoutSubtreeIfNeeded()
        try require(workspace.splitActive(at: .trailing), "The generated text comparison could not open a second pane")
        let peer = workspace.activeBrowser
        defer { workspace.activate(peer); _ = workspace.closeActivePane() }
        source.navigate(to: .directory(left.deletingLastPathComponent()))
        peer.navigate(to: .directory(right.deletingLastPathComponent()))
        try await waitUntil("Both generated text comparison panes") {
            !source.isLoading && !peer.isLoading && source.rowsByURL[left] != nil && peer.rowsByURL[right] != nil
        }
        peer.setFileSelection([right]); peer.fileSelectionDidChange()
        workspace.activate(source)
        source.setFileSelection([left]); source.fileSelectionDidChange(); source.focusBrowserContent()
        let action = #selector(BrowserViewController.compareTextFiles(_:))
        guard let item = BrowserMenus.commandItem(action, in: BrowserMenus.menu(.file, target: source)) else {
            throw UIVerification.Failure(message: "The native browser File menu omitted text comparison")
        }
        try require(source.validateMenuItem(item) && item.title == "Compare Text with Other Pane…"
            && NSApp.sendAction(action, to: source, from: item), "The local pane selection did not use the native compare action")
        guard let comparison = workspace.textComparisonWindow, let diffWindow = comparison.window else {
            throw UIVerification.Failure(message: "The local pane comparison did not present its shared viewer")
        }
        try await waitUntil("Native local pane text comparison") { !comparison.hasWorkForVerification && diffWindow.isKeyWindow }
        try require(comparison.planForVerification?.before.encoded == Data("generated workspace A".utf8)
            && comparison.planForVerification?.current.encoded == Data("generated workspace B".utf8)
            && !comparison.beforeSurface.textView.isEditable && !comparison.currentSurface.textView.isEditable
            && source.selectedURLs == [left] && peer.selectedURLs == [right],
            "Pane comparison selected the wrong file or changed a browser selection")
        try await UIVerification.snapshot(diffWindow, to: owned.appendingPathComponent("text-comparison-from-panes.png"))
        await comparison.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        workspace.activate(peer)
        guard let divider = workspace.layout.parent(of: peer.paneID)?.id else {
            throw UIVerification.Failure(message: "The local pair has no divider")
        }
        try pressDivider(.compareText, split: divider, in: workspace)
        guard let fromDivider = workspace.textComparisonWindow else {
            throw UIVerification.Failure(message: "The divider did not present the shared text comparison")
        }
        try await waitUntil("The divider uses the displayed pane order") {
            !fromDivider.hasWorkForVerification && fromDivider.window?.isKeyWindow == true
        }
        try require(fromDivider.planForVerification?.before.encoded == Data("generated workspace A".utf8)
            && fromDivider.planForVerification?.current.encoded == Data("generated workspace B".utf8)
            && workspace.activeBrowser === peer && source.selectedURLs == [left] && peer.selectedURLs == [right],
            "Divider text comparison used focus order or moved the selections")
        await fromDivider.closeAndDrain()
        workspace.activate(source)
        window.makeKeyAndOrderFront(nil); source.focusBrowserContent()
        let previousCompare = try dividerButton(.compareText, split: divider, in: workspace)
        let swap = try dividerButton(.swap, split: divider, in: workspace)
        let swapCenter = swap.convert(.init(x: swap.bounds.midX, y: swap.bounds.midY), to: nil)
        peer.setFileSelection([]); peer.fileSelectionDidChange()
        try require(previousCompare.isHidden && workspace.isPaneDividerButton(at: swapCenter),
                    "A stationary divider shelf kept Compare Text after its selection changed, or moved Swap")
        if let retired = previousCompare.action { _ = NSApp.sendAction(retired, to: previousCompare.target, from: previousCompare) }
        try require(!source.validateMenuItem(item) && !workspace.canPerformDividerAction(.compareText, split: divider)
                    && workspace.textComparisonWindow == nil,
                    "An empty peer selection or a closed diff retained command authority")
        peer.setFileSelection([right]); peer.fileSelectionDidChange()
        try require(!previousCompare.isHidden && workspace.isPaneDividerButton(at: swapCenter),
                    "The stationary shelf did not offer the text comparison again")
        workspace.dismissPaneDividerControls()
        peer.setFileSelection([]); peer.fileSelectionDidChange()

        let matching = right.deletingLastPathComponent().appendingPathComponent(left.lastPathComponent)
        let expected = Data("matching filename, different bytes\n".utf8)
        try await Task.detached { try expected.write(to: matching, options: .withoutOverwriting) }.value
        peer.refresh(nil)
        try await waitUntil("Same-name text in the unselected pane") {
            !peer.isLoading && peer.orderingTask == nil && peer.rowsByURL[matching] != nil
                && workspace.canPerformDividerAction(.compareMatchingText, split: divider)
        }
        let offered = try dividerButton(.compareMatchingText, split: divider, in: workspace)
        try require(offered.toolTip == "Compare Text with Matching Filename" && peer.selectedURLs.isEmpty,
            "Same-name comparison presented a selected peer")
        try pressDivider(.compareMatchingText, split: divider, in: workspace)
        guard let sameName = workspace.textComparisonWindow else {
            throw UIVerification.Failure(message: "The divider did not present the same-name comparison")
        }
        try await waitUntil("Same-name native text comparison") {
            !sameName.hasWorkForVerification && sameName.window?.isKeyWindow == true
        }
        try require(sameName.planForVerification?.before.encoded == Data("generated workspace A".utf8)
            && sameName.planForVerification?.current.encoded == expected && sameName.labels.right == matching.path
            && source.selectedURLs == [left] && peer.selectedURLs.isEmpty,
            "The same-name comparison altered selection or opened an unrelated file")
        await sameName.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        source.focusBrowserContent()
        try require(source.validateMenuItem(item) && NSApp.sendAction(action, to: source, from: item),
            "The File command did not offer the same-name comparison from the keyboard")
        guard let native = workspace.textComparisonWindow else { throw UIVerification.Failure(message: "No File comparison") }
        try await waitUntil("Menu opens the matching text file") { !native.hasWorkForVerification && native.window?.isKeyWindow == true }
        try require(native.planForVerification?.current.encoded == expected && peer.selectedURLs.isEmpty,
            "File and the divider chose different same-name files")
        await native.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        source.focusBrowserContent()
        let view = BrowserMenus.menu(.view, target: source)
        guard let select = BrowserMenus.commandItem(BrowserCommand.selectMatchingPaneItem.selector, in: view),
              let reveal = select.action, let sourceFocus = window.firstResponder else {
            throw UIVerification.Failure(message: "The generated source lost its responder or matching-item command")
        }
        try require(source.validateMenuItem(select) && NSApp.sendAction(reveal, to: source, from: select)
            && source.selectedURLs == [left] && peer.selectedURLs == [matching] && workspace.activeBrowser === source
            && window.firstResponder === sourceFocus,
            "Select Matching Item did not select the exact counterpart and preserve source focus")
        try require(!source.validateMenuItem(select) && !workspace.performDividerAction(.selectMatch, split: divider),
            "A selected peer retained authority to replace its own selection")
        peer.setFileSelection([]); peer.fileSelectionDidChange()

        let binarySource = left.deletingLastPathComponent().appendingPathComponent("Generated Match.bin")
        let binaryTarget = right.deletingLastPathComponent().appendingPathComponent(binarySource.lastPathComponent)
        let folderSource = left.deletingLastPathComponent().appendingPathComponent("Generated Match Folder", isDirectory: true)
        let folderTarget = right.deletingLastPathComponent().appendingPathComponent(folderSource.lastPathComponent, isDirectory: true)
        try await Task.detached {
            try Data([0, 1]).write(to: binarySource, options: .withoutOverwriting)
            try Data([0, 2]).write(to: binaryTarget, options: .withoutOverwriting)
            for directory in [folderSource, folderTarget] { try FileManager().createDirectory(at: directory, withIntermediateDirectories: false) }
        }.value
        source.refresh(nil); peer.refresh(nil)
        try await waitUntil("Matching binary entries are visible in both panes") {
            !source.isLoading && !peer.isLoading && source.orderingTask == nil && peer.orderingTask == nil
                && source.rowsByURL[binarySource] != nil && peer.rowsByURL[binaryTarget] != nil
                && source.rowsByURL[folderSource] != nil && peer.rowsByURL[folderTarget] != nil
        }
        source.setFileSelection([binarySource]); source.fileSelectionDidChange(); source.focusBrowserContent()
        try pressDivider(.selectMatch, split: divider, in: workspace)
        try require(source.selectedURLs == [binarySource] && peer.selectedURLs == [binaryTarget]
            && workspace.activeBrowser === source && workspace.textComparisonWindow == nil && window.firstResponder === sourceFocus,
            "The binary name selection opened a comparison or moved source focus")
        let peerViewMode = peer.effectiveViewMode
        peer.setPaneViewMode(.icons)
        peer.setFileSelection([]); peer.fileSelectionDidChange()
        source.setFileSelection([folderSource]); source.fileSelectionDidChange()
        try pressDivider(.selectMatch, split: divider, in: workspace)
        try require(peer.usesFileIcons && peer.selectedURLs == [folderTarget] && source.selectedURLs == [folderSource]
            && window.firstResponder === sourceFocus, "The matching folder did not select its exact icon")
        peer.setPaneViewMode(peerViewMode)
        source.setFileSelection([left]); source.fileSelectionDidChange()
        peer.setFileSelection([]); peer.fileSelectionDidChange()
        peer.navigate(to: .directory(left.deletingLastPathComponent()))
        try await waitUntil("Peer visit no longer offers a different same-name file") {
            !peer.isLoading && peer.rowsByURL[left] != nil && !source.validateMenuItem(item)
        }
        try require(!workspace.canPerformDividerAction(.compareMatchingText, split: divider) && workspace.textComparisonWindow == nil,
            "A changed peer offered its identical file as a comparison")
    }

    private static func verifyFolderPathFilter(_ comparison: FolderComparisonWindow, in window: NSWindow,
                                               report: FolderComparisonReport, first: Int, second: Int, owned: URL) async throws {
        let session = comparison.session
        guard let table = UIVerification.nativeTables(in: window.contentView).first else {
            throw UIVerification.Failure(message: "Folder comparison has no native table to filter")
        }
        try await UIVerification.clickRow(first, in: table)
        try require(session.selectedRows == [first] && session.selectedCopy != nil, "Folder filter had no original selection to preserve")
        let command = UIVerification.key("f", code: 3, flags: .command, window: window)
        try require(NSApp.mainMenu?.performKeyEquivalent(with: command) == true, "Folder path filter was unavailable from the keyboard")
        try await waitUntil("Folder comparison's native filter field") {
            session.pathFilterID != nil && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        for letter in "beta" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
        try await waitUntil("Path filter and native rows") {
            session.pathQuery == "beta" && !session.isFiltering && session.visibleRows.map(\.id) == [second]
                && UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == 1
        }
        try require(session.selectedRows.isEmpty && session.selectedCopy == nil && session.selectedText == nil
            && session.displayedReport?.rows.count == report.rows.count, "Filtering gave an invisible row action authority or changed the report")
        window.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: window))
        try await waitUntil("Down selects the filtered path") { session.selectedRows == [second] && session.selectedCopy != nil }
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("folder-comparison-path-filter-150.png"))
        session.setFilter(report.rows[second].difference == .onlyOnLeft ? .right : .left)
        try await waitUntil("Direction and path both constrain the result") { !session.isFiltering && session.visibleRows.isEmpty }
        try require(session.pathQuery == "beta" && session.selectedCopy == nil, "Changing direction discarded the query or retained Copy")
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await waitUntil("Escape clears the path and keeps the chosen direction") {
            session.pathFilterID == nil && session.pathQuery.isEmpty && !session.isFiltering && session.visibleRows.map(\.id).contains(first)
        }
        session.setFilter(.all)
        try await waitUntil("Folder comparison returns to the full list") {
            !session.isFiltering && session.visibleRows.count == report.rows.count
                && UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == report.rows.count
        }
        try await waitUntil("Closed folder filter releases its native field editor") {
            (window.firstResponder as? NSTextView)?.isFieldEditor != true
        }
    }

    private static func verifyComparisonEditorOpen(_ comparison: FolderComparisonWindow, in window: NSWindow,
                                                   files: [URL], contents: [String]) async throws {
        guard let left = UIVerification.menuItem("File", "Open Left File in Editor"),
              let right = UIVerification.menuItem("File", "Open Right File in Editor"),
              let leftAction = left.action else { throw UIVerification.Failure(message: "Folder editor commands are missing") }
        let editors = ApplicationLocalTextEditors.shared
        let initialSelection = comparison.session.selectedRows
        for (index, item) in [left, right].enumerated() {
            guard let action = item.action else { throw UIVerification.Failure(message: "Folder editor action missing") }
            let file = files[index]
            try require(comparison.validateMenuItem(item) && NSApp.sendAction(action, to: comparison, from: item),
                "The comparison could not open the requested side")
            try await waitUntil("The selected side is ready in its native editor") {
                guard let editor = editors.documentForVerification(at: file) else { return false }
                return !editor.hasPendingFileWork && editor.window.window?.isKeyWindow == true
            }
            guard let editor = editors.documentForVerification(at: file), let native = editor.window.window else {
                throw UIVerification.Failure(message: "The requested file did not open")
            }
            let text = editor.window.surface.textView
            try require(text.string == contents[index] && text.isEditable, "Folder Compare opened the wrong side or a snapshot")
            if index == 0 {
                text.breakUndoCoalescing()
                text.insertText(" draft", replacementRange: .init(location: text.string.utf16.count, length: 0))
                text.breakUndoCoalescing()
                window.makeKeyAndOrderFront(nil)
                try require(NSApp.sendAction(action, to: comparison, from: item), "Reopen did not use the same side")
                try await waitUntil("Existing draft raised from comparison") { native.isKeyWindow }
                try require(editors.documentForVerification(at: file) === editor && text.string == contents[index] + " draft",
                    "Reopening a compared side replaced its existing draft")
                text.undoManager?.undo()
                try await waitUntil("Draft Undo restores the original bytes") { !editor.isDirty }
            }
            editor.requestClose()
            try await waitUntil("The generated editor closed") { editors.documentForVerification(at: file) == nil }
            window.makeKeyAndOrderFront(nil)
        }
        let unchanged = try await Task.detached {
            try zip(files, contents).allSatisfy { try Data(contentsOf: $0.0) == Data($0.1.utf8) }
        }.value
        try require(unchanged && initialSelection == comparison.session.selectedRows,
            "Opening from Compare changed the generated originals or lost the report selection")
        let replacement = Data("new!".utf8)
        try await Task.detached { try replacement.write(to: files[0], options: .atomic) }.value
        try require(NSApp.sendAction(leftAction, to: comparison, from: left), "The stale-row open did not route")
        try await waitUntil("The report requires refresh before opening a replacement") {
            !comparison.session.isPreparingEditor && comparison.session.notice?.contains("selected file changed") == true
        }
        let stillReplacement = try await Task.detached { try Data(contentsOf: files[0]) == replacement }.value
        try require(editors.documentForVerification(at: files[0]) == nil && stillReplacement,
            "A replaced file was admitted or changed")
    }

    private static func startComparison(in menu: NSMenu, from browser: BrowserViewController,
                                        left: URL, right: URL) throws -> FolderComparisonWindow {
        let action = BrowserCommand.compareFolders.selector
        guard let item = BrowserMenus.commandItem(action, in: menu) else {
            throw UIVerification.Failure(message: "The \(menu.title) menu did not show Compare Folders")
        }
        try require(browser.validateMenuItem(item) && NSApp.sendAction(action, to: browser, from: item),
                    "The \(menu.title) menu could not invoke Compare Folders")
        guard let comparison = browser.workspace?.folderComparisonWindow else {
            throw UIVerification.Failure(message: "The folder comparison did not open")
        }
        try require(comparison.session.left.path == left.path && comparison.session.right.path == right.path,
                    "The comparison changed the folders’ displayed order")
        return comparison
    }

    private static func comparisonResult(_ comparison: FolderComparisonWindow) async throws -> FolderComparisonReport {
        try await waitUntil("Folder comparison") { !comparison.session.isReading }
        if case .result(let report) = comparison.session.state { return report }
        throw UIVerification.Failure(message: "Folder comparison did not produce its expected report")
    }

    private static func verifyNameSelection(_ browser: BrowserViewController, window: NSWindow,
                                            first: URL, second: URL) async throws {
        let location = browser.location
        let listed = browser.displayedEntries
        func run(_ text: String, mode: NameSelectionPrompt.Mode, expected: Set<URL>, cancel: Bool = false) async throws {
            let action = BrowserCommand.selectByName.selector
            let menu = BrowserMenus.fileContextMenu(target: browser)
            guard let item = BrowserMenus.commandItem(action, in: menu), browser.validateMenuItem(item),
                  NSApp.sendAction(action, to: browser, from: item) else {
                throw UIVerification.Failure(message: "The native context menu did not invoke Select by Name")
            }
            try await UIVerification.completeNameSelection(in: window, text: text, mode: mode, cancel: cancel)
            try await waitUntil("Select by Name completed") { browser.nameSelection.canPresent }
            try require(browser.selectedURLs == expected && browser.location == location
                && browser.displayedEntries == listed, "Select by Name changed the folder view or matched unexpected items")
        }
        try await run("Folder A", mode: .replace, expected: [first])
        try await run("Folder*B", mode: .add, expected: [first, second])
        try await run("Folder B", mode: .remove, expected: [first])
        try await run("*.never-matches", mode: .replace, expected: [first])
        try require(browser.status.stringValue == "No names match in this view.",
                    "An empty match result did not explain the unchanged selection")
        try await run("Folder B", mode: .replace, expected: [first], cancel: true)
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

    private static func verifyLinkedNavigation(_ workspace: BrowserWorkspaceController, first: BrowserViewController,
                                               second: BrowserViewController, owned: URL) async throws {
        let root = owned.appendingPathComponent("Linked Navigation", isDirectory: true)
        let left = root.appendingPathComponent("Left", isDirectory: true)
        let right = root.appendingPathComponent("Right", isDirectory: true)
        let leftChild = left.appendingPathComponent("Sources Café", isDirectory: true)
        let rightChild = right.appendingPathComponent("Sources Café", isDirectory: true)
        let unmatched = left.appendingPathComponent("Only Here", isDirectory: true)
        try await Task.detached {
            for path in [leftChild, rightChild, unmatched] {
                try FileManager().createDirectory(at: path, withIntermediateDirectories: true)
            }
        }.value
        let priorLeft = first.activeID, priorRight = second.activeID
        workspace.activate(first)
        try require(first.openNewTab(at: .directory(left)), "Could not open the left linked-navigation fixture")
        let firstTab = first.activeID
        workspace.activate(second)
        try require(second.openNewTab(at: .directory(right)), "Could not open the right linked-navigation fixture")
        let secondTab = second.activeID
        let split = workspace.layout.rootID
        let startingOrder = workspace.layout.paneIDs
        func settled(_ browser: BrowserViewController, _ directory: URL) -> Bool {
            browser.location == .directory(directory) && !browser.isLoading && browser.orderingTask == nil && browser.loadError == nil
        }
        workspace.activate(first)
        try await waitUntil("Linked fixture roots") { settled(first, left) && settled(second, right) }
        try pressDivider(.link, split: split, in: workspace)
        try await waitUntil("Linked navigation roots approved") {
            first.status.stringValue == "Pane navigation linked for these folders."
        }
        first.navigate(to: .directory(leftChild))
        try await waitUntil("Linked pane follows first visit") { settled(first, leftChild) && settled(second, rightChild) }
        try require(workspace.activeBrowser === first && first.activeID == firstTab && second.activeID == secondTab,
                    "Linked navigation changed the active tab or browser")
        first.goBack(nil)
        try await waitUntil("Linked pane follows Back") { settled(first, left) && settled(second, right) }
        first.goForward(nil)
        try await waitUntil("Linked pane follows Forward") { settled(first, leftChild) && settled(second, rightChild) }
        let peerVisit = second.sessionID
        first.navigate(to: .directory(unmatched))
        try await waitUntil("Missing linked subfolder reported") {
            settled(first, unmatched) && first.status.stringValue.contains("Matching folder unavailable")
        }
        try require(settled(second, rightChild) && second.sessionID == peerVisit,
                    "Missing counterpart changed the linked tab")
        workspace.activate(second)
        second.goBack(nil)
        try await waitUntil("Linked navigation followed the other direction") { settled(first, left) && settled(second, right) }
        try pressDivider(.swap, split: split, in: workspace)
        try require(workspace.layout.paneIDs == Array(startingOrder.reversed()) && workspace.folderNavigation.isLinked(split),
                    "Swap lost the link between its original tabs")
        second.navigate(to: .directory(rightChild))
        try await waitUntil("Swapped linked pane follows") { settled(first, leftChild) && settled(second, rightChild) }
        let viewMenu = BrowserMenus.menu(.view, target: second)
        let selector = BrowserCommand.linkPaneNavigation.selector
        guard let item = viewMenu.items.first(where: { $0.action == selector }),
              second.validateMenuItem(item), item.state == .on,
              NSApp.sendAction(selector, to: second, from: item) else {
            throw UIVerification.Failure(message: "Linked navigation was unavailable through the checked native View menu")
        }
        try require(!workspace.folderNavigation.isLinked(split), "View menu did not unlink the tabs")
        second.goBack(nil)
        try await waitUntil("Unlinked pane retained its visit") { settled(second, right) && settled(first, leftChild) }
        try pressDivider(.swap, split: split, in: workspace)
        try require(workspace.layout.paneIDs == startingOrder, "Linked fixture did not restore the original pane order")
        try pressDivider(.link, split: split, in: workspace)
        try await waitUntil("Link restored for current visits") { second.status.stringValue == "Pane navigation linked for these folders." }
        second.selectTab(priorRight)
        try require(!workspace.folderNavigation.isLinked(split), "Changing the linked tab did not remove the old link")
        second.closeTab(id: secondTab)
        workspace.activate(first)
        first.selectTab(priorLeft)
        first.closeTab(id: firstTab)
        try await waitUntil("Linked navigation restored the original tabs") {
            first.activeID == priorLeft && second.activeID == priorRight && !first.isLoading && !second.isLoading
                && first.orderingTask == nil && second.orderingTask == nil
        }
    }

    private static func dividerButton(_ action: WorkspaceDividerAction, split: UUID, in workspace: BrowserWorkspaceController,
                                      sendingWindowEvent: Bool = true) throws -> NSButton {
        let tree = workspace.paneTreeHost
        guard let controls = tree.subviews.compactMap({ $0 as? WorkspaceDividerControls }).first,
              let divider = controls.dividers(nil, nil).first(where: { $0.id == split }), let window = tree.window else {
            throw UIVerification.Failure(message: "Expected divider or native controls are missing")
        }
        let middle = NSPoint(x: divider.line.midX, y: divider.line.midY)
        let hover = tree.convert(middle, to: nil)
        if sendingWindowEvent { sendDividerMouseMove(to: hover, in: workspace, window: window) }
        else { workspace.updatePaneDividerHover(at: hover) }
        try require(!workspace.isPaneDividerButton(at: hover), "Divider hover controls cover the native resize corridor")
        let candidates = controls.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        guard let button = candidates.first(where: {
            $0.accessibilityLabel() == divider.title(for: action) && !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled
        }) else {
            throw UIVerification.Failure(message: "Divider \(action.title) did not have its enabled native control.")
        }
        let windowPoint = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitPoint = tree.superview?.convert(windowPoint, from: nil) ?? middle
        try require(controls.button(at: windowPoint) === button && tree.hitTest(hitPoint) === button,
                    "Divider \(action.title) did not own its native hit target")
        return button
    }

    private static func sendDividerMouseMove(to point: NSPoint, in workspace: BrowserWorkspaceController, window: NSWindow) {
        if window.isKeyWindow, let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(move)
        } else { workspace.updatePaneDividerHover(at: point) }
    }

    static func pressDivider(_ action: WorkspaceDividerAction, split: UUID, in workspace: BrowserWorkspaceController) throws {
        let button = try dividerButton(action, split: split, in: workspace)
        guard let selector = button.action, NSApp.sendAction(selector, to: button.target, from: button) else {
            throw UIVerification.Failure(message: "The divider button did not dispatch its native action")
        }
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
