#if DEBUG
import AppKit
import ExplorerCore
import FileMemory
import SwiftUI

@MainActor
enum ToolWindowVerification {
    /// Focused controls for the 0.1.2 tester reports. No real permission picker,
    /// default-app change, personal catalog or scan is started here.
    static func testerRepairs(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = try Data(contentsOf: root.appendingPathComponent("reservation.json"))
        let reservation = try JSONSerialization.jsonObject(with: marker) as? [String: Any]
        try UIVerification.require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && reservation?["action"] as? String == "traverse-tester-repair-qualification", "Unadmitted tester qualification")
        guard let parent = browser.view.window, let workspace = browser.workspace else {
            throw UIVerification.Failure(message: "Missing real browser workspace")
        }
        browser.permitsBackgroundVerification = true
        let settings = browser.settings
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        settings.navigationStyle = .glass; settings.appearance = .dark; settings.glassFileContent = true
        let expectedGlass = BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: true,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let source = root.appendingPathComponent("source/Files")
        browser.navigate(to: .directory(source)); try await UIVerification.settled(browser)
        let priorLocation = browser.location
        var headingClicks = 0
        for group in browser.sidebarRoots where group.group && browser.outline.isExpandable(group) {
            let wasExpanded = browser.outline.isItemExpanded(group)
            for _ in 0..<2 {
                let row = browser.outline.row(forItem: group)
                let rect = browser.outline.rect(ofRow: row)
                // Far from the disclosure glyph: the heading text's area.
                let point = browser.outline.convert(.init(x: rect.minX + 100, y: rect.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: parent.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                    throw UIVerification.Failure(message: "Missing generated heading click")
                }
                let before = browser.outline.isItemExpanded(group)
                browser.outline.mouseDown(with: event)
                try UIVerification.require(browser.outline.isItemExpanded(group) != before,
                    "Clicking a sidebar heading label did not toggle its branch")
                headingClicks += 1
            }
            try UIVerification.require(browser.outline.isItemExpanded(group) == wasExpanded,
                "Sidebar heading round trip did not restore its branch")
        }
        try UIVerification.require(headingClicks >= 4 && browser.location == priorLocation,
            "Heading clicks unexpectedly navigated or no expandable headings were exercised")
        let first = browser.activeID
        browser.newTab(nil); try await UIVerification.settled(browser)
        let newTabAtComputer = browser.location == .computer
        browser.closeTab(id: browser.activeID); try await UIVerification.settled(browser)
        browser.focusBrowserContent()
        browser.duplicateCurrentTab(nil); try await UIVerification.settled(browser)
        let duplicatePreservedFolder = browser.activeID != first && browser.location == .directory(source)
        browser.closeTab(id: browser.activeID)
        var preferenceRoundTrips = true
        for destination in BrowserNewTabDestination.allCases {
            settings.newTabDestination = destination
            let reopened = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            preferenceRoundTrips = preferenceRoundTrips && reopened.newTabDestination == destination
        }
        let current = BrowserLocation.directory(source)
        let remote = BrowserLocation.smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Generated remote"))
        let destinationPolicy = BrowserNewTabDestination.currentFolder.location(current: current, home: nil) == current
            && BrowserNewTabDestination.home.location(current: current, home: source) == current
            && BrowserNewTabDestination.home.location(current: current, home: nil) == .computer
            && BrowserNewTabDestination.currentFolder.location(current: remote, home: nil) == .computer
        guard var legacy = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as? [String: Any] else {
            throw UIVerification.Failure(message: "Generated preferences did not encode an object")
        }
        legacy["version"] = 17; legacy.removeValue(forKey: "newTabDestination")
        let migrated = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: legacy))
        let legacyDefault = migrated.newTabDestination == .computer
        settings.newTabDestination = .currentFolder
        browser.newTab(nil); try await UIVerification.settled(browser)
        let currentFolderPreference = browser.location == current
        browser.closeTab(id: browser.activeID); settings.newTabDestination = .computer
        workspace.showWorkspaceSettings()
        guard let preferences = workspace.settingsWindow else { throw UIVerification.Failure(message: "Settings did not open") }
        defer { preferences.close() }
        try await Task.sleep(for: .milliseconds(250))
        let glassTitlebar = preferences.styleMask.contains(.fullSizeContentView)
            && preferences.titlebarAppearsTransparent == expectedGlass && preferences.isOpaque && !preferences.ignoresMouseEvents
        let frame = preferences.frame
        for _ in 0..<3 {
            parent.makeKeyAndOrderFront(nil); preferences.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        let stableFrame = preferences.frame == frame
        var pageFramesStable = true
        var settingsResizeReflows = false
        var visitedPages: Set<BrowserSettingsView.Page> = []
        if let host = (preferences.contentViewController as? ToolWindowChrome)?.children.first as? InterfaceHostingController<BrowserSettingsView> {
            var content = host.content
            content.onPageVisibilityForVerification = { page, visible in if visible { visitedPages.insert(page) } }
            host.content = content
            try await wait("Settings native navigation did not appear") { settingsNavigation(in: preferences) != nil && visitedPages.contains(.general) }
            for (index, page) in [(2, BrowserSettingsView.Page.keyboard), (1, .appearance), (0, .general)] {
                try selectSettingsPage(index, in: preferences)
                try await wait("Settings did not show the selected page") { visitedPages.contains(page) }
                try await Task.sleep(for: .milliseconds(100))
                pageFramesStable = pageFramesStable && preferences.frame == frame
            }
            let initialContent = host.view.bounds.size
            preferences.setFrame(.init(x: frame.minX, y: frame.minY - 60, width: frame.width + 100, height: frame.height + 60), display: true)
            try await Task.sleep(for: .milliseconds(150))
            settingsResizeReflows = preferences.styleMask.contains(.resizable)
                && host.view.bounds.width >= initialContent.width + 95 && host.view.bounds.height >= initialContent.height + 55
            preferences.setFrame(frame, display: true)
        } else { pageFramesStable = false }
        let properties = FilePropertiesWindowController(settings: settings, copyPaths: { _ in })
        properties.show(urls: [source.appendingPathComponent("Generated.txt")], relativeTo: parent)
        defer { properties.cancel(); properties.close() }
        try await wait("Generated Properties did not finish") { !properties.model.isLoading }
        let propertiesFrame = properties.window!.frame
        for urls in [[source], [source.appendingPathComponent("Generated.txt")], [source, source.appendingPathComponent("Generated.txt")]] {
            properties.update(urls: urls)
            try await wait("Generated Properties refresh did not finish") { !properties.model.isLoading }
            try await Task.sleep(for: .milliseconds(80))
            pageFramesStable = pageFramesStable && properties.window?.frame == propertiesFrame
        }
        let toolWindows = [preferences, properties.window!]
        let toolsFollowTheme = toolWindows.allSatisfy { $0.titlebarAppearsTransparent == expectedGlass
            && $0.isOpaque && $0.styleMask.contains(.fullSizeContentView) }
        properties.close(); preferences.orderOut(nil)
        let metadata = try await FilePropertiesReader().read([source.appendingPathComponent("Folder"), source])
        var observations = metadata.observations
        guard let dataIndex = observations.firstIndex(where: { $0.url == source }),
              let nativeCapacity = PropertyVolumeCapacity.observed(blocks: 2_000_000, available: 1_200_000, blockSize: 4096,
                  reportedUsed: .init(bytes: 3_000_000_000)) else {
            throw UIVerification.Failure(message: "Generated capacity report is unavailable")
        }
        // A real ordinary folder deliberately has no volume-root capacity.
        // Supply a generated two-root report at the reader/projection seam;
        // this control creates no mount or real startup-volume observation.
        observations[dataIndex].volumeCapacity = nativeCapacity
        let volumeReport = FilePropertiesReport(selectedCount: metadata.selectedCount, observations: observations)
        let fallback = StartupStorageAccounting.project(capacity: nil, available: nil,
            systemRoot: source.appendingPathComponent("Folder"), dataRoot: source, report: volumeReport)
        let unmatched = StartupStorageAccounting.project(capacity: nil, available: nil, systemRoot: source,
            dataRoot: root.appendingPathComponent("source/Not observed"), report: volumeReport)
        let shared = StartupStorageAccounting.project(capacity: 100, available: 30,
            systemRoot: source.appendingPathComponent("Folder"), dataRoot: source, report: volumeReport)
        let unavailable = StartupStorageAccounting(capacity: nil, available: nil,
            system: .init(bytes: .max), data: .init(bytes: .max))
        let capacityProjection = fallback.capacityBasis == .dataVolume && fallback.capacity == nil && fallback.available == nil
            && fallback.chartCapacity == nativeCapacity.capacity && fallback.chartAvailable == nativeCapacity.available
            && unmatched.capacityBasis == .unavailable && unmatched.chartCapacity == nil
            && shared.capacityBasis == .sharedContainer && shared.chartCapacity == 100 && shared.chartAvailable == 30
            && unavailable.capacityBasis == .unavailable && unavailable.chartCapacity == nil
        let accountingHost = NSHostingController(rootView: StartupStorageAccountingView(value:
            .init(capacity: nil, available: nil, system: nil, data: nil)).padding(16))
        accountingHost.sizingOptions = []
        let accountingWindow = NSWindow(contentViewController: accountingHost)
        accountingWindow.title = "Traverse · generated review · unavailable capacity"
        accountingWindow.setContentSize(.init(width: 580, height: 230)); accountingWindow.isReleasedWhenClosed = false
        ToolWindowChrome.install(in: accountingWindow, settings: settings)
        accountingWindow.center(); accountingWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(160))
        try await GlassVerification.captureOwnedWindow(accountingWindow, to: root.appendingPathComponent("evidence/capacity-unavailable.png"))
        accountingWindow.close()
        accountingHost.rootView = StartupStorageAccountingView(value: fallback).padding(16)
        accountingWindow.title = "Traverse · generated review · Data volume capacity"
        accountingWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(120))
        try await GlassVerification.captureOwnedWindow(accountingWindow, to: root.appendingPathComponent("evidence/capacity-data-volume.png"))
        accountingWindow.close()
        let colors: [String: Any] = ["scope": "Separate chart-finish process; see its receipt"]

        // Functional window checks and capture use separate fresh processes.
        // Closed SwiftUI tool graphs plus a capture encoder are not a fair
        // isolated browser-motion memory measurement.
        return ["passed": newTabAtComputer && duplicatePreservedFolder && glassTitlebar && stableFrame
                && preferenceRoundTrips && destinationPolicy && legacyDefault && currentFolderPreference && pageFramesStable && toolsFollowTheme && settingsResizeReflows && capacityProjection,
            "newTabAtThisMac": newTabAtComputer, "duplicatePreservesFolder": duplicatePreservedFolder,
            "settingsGlassTitlebar": glassTitlebar, "focusCyclesKeepWindowFrame": stableFrame,
            "contentChangesKeepWindowFrame": pageFramesStable, "toolsFollowTheme": toolsFollowTheme,
            "settingsResizeReflows": settingsResizeReflows, "nativeSettingsPagesVisited": visitedPages.count,
            "capacitySourcesStaySeparate": capacityProjection, "sidebarHeadingLabelClicks": headingClicks,
            "newTabPreferencesReopen": preferenceRoundTrips, "newTabDestinationPolicy": destinationPolicy,
            "legacyNewTabDefault": legacyDefault, "currentFolderNewTabChoice": currentFolderPreference,
            "chartPaletteAndGeometry": colors,
            "stageManagerAcceptance": "Not exercised; owned focus cycles only",
            "permissionRequests": 0, "personalScans": 0, "defaultAppChanges": 0]
    }
    static func browserMotion(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        try InterfaceSizingVerification.admit(root)
        guard let parent = browser.view.window else { throw UIVerification.Failure(message: "Missing motion window") }
        let settings = browser.settings, source = root.appendingPathComponent("source/Files")
        settings.navigationStyle = .glass; settings.appearance = .dark; settings.glassFileContent = true
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        browser.permitsBackgroundVerification = true
        browser.navigate(to: .directory(source)); try await UIVerification.settled(browser)
        var motionReports: [String: NativeMotionRecorder.Report] = [:]
        var arrivalAdmissions: [String: Int] = [:]
        var revealedTransitions: [String: Bool] = [:]
        var revealingBeforeFirstDisplay: [String: Bool] = [:]
        let arguments = ProcessInfo.processInfo.arguments
        let selectedMode = arguments.firstIndex(of: "--motion-mode").flatMap { index in
            arguments.indices.contains(index + 1) ? BrowserMotionMode(rawValue: arguments[index + 1]) : nil
        }
        let motionModes = selectedMode.map { [$0] } ?? BrowserMotionMode.allCases
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            parent.title = "Traverse · generated review · tester repairs"
            parent.setContentSize(.init(width: 900, height: 570)); parent.makeKeyAndOrderFront(nil)
            for mode in motionModes {
                settings.motion.mode = mode
                browser.navigate(to: .directory(source)); try await UIVerification.settled(browser)
                for (name, target) in [("folder", BrowserLocation.directory(source.appendingPathComponent("Folder"))),
                                       ("computer", BrowserLocation.computer), ("return", BrowserLocation.directory(source))] {
                    let label = "tester-\(name)-\(mode.rawValue)"
                    parent.title = "Traverse · generated review · tester repairs"
                    try JSONSerialization.data(withJSONObject: ["width": parent.frame.width, "height": parent.frame.height,
                        "visible": parent.isVisible, "windowNumberValid": parent.windowNumber > 0,
                        "titleMarked": parent.title.contains("generated review")], options: [.sortedKeys])
                        .write(to: root.appendingPathComponent("evidence/\(label)-admission.json"), options: .withoutOverwriting)
                    var presented: BrowserCanvasTransition?
                    motionReports[label] = try await NativeMotionRecorder.record(window: parent, root: root, label: label) {
                        browser.navigate(to: target)
                        presented = browser.canvasTransition
                        revealingBeforeFirstDisplay[label] = presented?.isRevealing ?? false
                    }
                    arrivalAdmissions[label] = presented?.maximumArrivingForVerification ?? 0
                    revealedTransitions[label] = presented?.isRevealing ?? false
                    try await UIVerification.settled(browser)
                    try UIVerification.require(browser.canvasTransition == nil && browser.contentSurface?.layer?.opacity != 0,
                        "A completed directory transition retained its picture or hid live content")
                }
            }
            try JSONEncoder().encode(motionReports).write(to: root.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
        }
        let arrivalCrossfadeExercised = motionReports.isEmpty || motionModes == [.off] || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (arrivalAdmissions.values.contains { $0 > 0 }
                && (browser.volumes.isEmpty || motionModes.filter { $0 != .off }.allSatisfy {
                    (arrivalAdmissions["tester-computer-\($0.rawValue)"] ?? 0) > 0
                        && revealingBeforeFirstDisplay["tester-computer-\($0.rawValue)"] == true
                }))
        // A slow drive refresh retains cached cards. Exercise the same arrival
        // callback while loading, without introducing a delayed filesystem read.
        settings.motion.mode = .full
        browser.navigate(to: .computer); try await UIVerification.settled(browser)
        browser.prepareCanvasTransition(enabled: true, directoryDirection: -1)
        let delayedRefresh = browser.canvasTransition
        delayedRefresh?.bind(to: browser.sessionID)
        browser.isLoading = true
        delayedRefresh?.reveal()
        let cachedVolumeCrossfade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || browser.volumeBrowser.tileCount == 0 || (delayedRefresh?.maximumArrivingForVerification ?? 0) > 0
        let originalClock = browser.volumeBrowser.visibleTiles.first.flatMap { delayedRefresh?.arrivalStartForVerification($0.view) }
        try await Task.sleep(for: .milliseconds(70))
        browser.renderVolumes(); browser.updateCanvasTransition()
        let refreshedClocks = browser.volumeBrowser.visibleTiles.map { delayedRefresh?.arrivalStartForVerification($0.view) }
        let reloadKeepsFadeClock = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || browser.volumeBrowser.tileCount == 0 || (originalClock != nil && !refreshedClocks.isEmpty
                && refreshedClocks.allSatisfy { clock in
                    guard let clock, let originalClock else { return false }
                    return abs(clock - originalClock) < 0.002
                })
        delayedRefresh?.finish(); browser.isLoading = false; browser.refreshStatus()
        browser.navigate(to: .directory(source)); try await UIVerification.settled(browser)
        browser.prepareCanvasTransition(enabled: true, directoryDirection: 1)
        let partialListing = browser.canvasTransition
        partialListing?.bind(to: browser.sessionID)
        browser.isLoading = true
        partialListing?.reveal()
        let loadingRowsCrossfade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (!browser.displayedEntries.isEmpty && (partialListing?.maximumArrivingForVerification ?? 0) > 0)
        partialListing?.finish(); browser.isLoading = false; browser.refreshStatus()
        // Rapid replacement and an explicit finish must remove only the
        // outgoing presentation's arrivals, without changing live opacity.
        settings.motion.mode = .full
        for _ in 0..<3 {
            browser.navigate(to: .directory(source)); try await UIVerification.settled(browser)
            browser.navigate(to: .computer)
            let held = browser.canvasTransition
            held?.finish()
            try UIVerification.require(browser.canvasTransition == nil
                && (held?.arrivingCountForVerification ?? 0) == 0,
                "A cancelled location transition retained arriving-layer animations")
        }
        return ["passed": arrivalCrossfadeExercised && cachedVolumeCrossfade && reloadKeepsFadeClock && loadingRowsCrossfade,
            "incomingCrossfadeExercised": arrivalCrossfadeExercised, "arrivalAdmissions": arrivalAdmissions,
            "revealedTransitions": revealedTransitions, "revealingBeforeFirstDisplay": revealingBeforeFirstDisplay,
            "cachedVolumesCrossfadeWhileRefreshing": cachedVolumeCrossfade, "nativeReloadKeepsArrivalClock": reloadKeepsFadeClock,
            "visibleRowsCrossfadeDuringListing": loadingRowsCrossfade, "recordedClips": motionReports.count,
            "permissionRequests": 0, "personalScans": 0, "defaultAppChanges": 0]
    }
    static func connectLayout(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        try InterfaceSizingVerification.admit(root)
        let settings = browser.settings
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.motion.mode = .full
        let original = settings.interfaceSize
        let controller = SMBConnectWindowController(settings: settings) { _, _ in
            throw UIVerification.Failure(message: "Generated layout must not connect")
        }
        guard let window = controller.window else { throw UIVerification.Failure(message: "Missing connection window") }
        window.title = "Traverse · generated review · connection layout"
        controller.present(relativeTo: browser.view.window)
        defer { controller.close(); settings.interfaceSize = original }
        settings.interfaceSize = .init(150)
        try await Task.sleep(for: .milliseconds(300))
        let initialFrame = window.frame
        controller.model.showAdvanced = true
        try await Task.sleep(for: .milliseconds(350))
        try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/connect-large-type.png"))
        var recordings: [String: NativeMotionRecorder.Report] = [:]
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            recordings["connect-sidebar"] = try await NativeMotionRecorder.record(window: window, root: root, label: "connect-sidebar") {
                controller.setSidebarVisible(true)
            }
        } else { controller.setSidebarVisible(true); try await Task.sleep(for: .milliseconds(500)) }
        try UIVerification.require(abs(window.frame.width - 826) < 1 && abs(window.frame.maxX - initialFrame.maxX) < 1,
            "Connection sidebar no longer reveals from the form's right anchor")
        window.setFrame(.init(x: window.frame.minX - 100, y: window.frame.minY, width: window.frame.width + 100, height: window.frame.height + 40), display: true)
        try await Task.sleep(for: .milliseconds(150))
        try UIVerification.require(window.styleMask.contains(.resizable) && abs(controller.model.editorWidth - 700) < 1,
            "The connection form did not follow its resized window")
        controller.setSidebarVisible(false, animated: false)
        try UIVerification.require(abs(window.frame.width - 700) < 1, "Hiding saved servers discarded the chosen form width")
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            recordings["connect-advanced"] = try await NativeMotionRecorder.record(window: window, root: root, label: "connect-advanced") {
                controller.model.showAdvanced = false
            }
        }
        try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/connect-resized.png"))
        if !recordings.isEmpty { try JSONEncoder().encode(recordings).write(to: root.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting) }
        return ["passed": true, "actualWindowResize": true, "largeType": 150, "sidebarRetainsFormWidth": true,
            "recordedClips": recordings.count, "networkRequests": 0, "keychainRequests": 0]
    }
    static func chartFinish(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        try InterfaceSizingVerification.admit(root)
        let settings = browser.settings
        settings.appearance = .dark; settings.navigationStyle = .glass
        let chart = StorageDimensionalChartView(frame: .init(x: 0, y: 0, width: 430, height: 330))
        let chartContent = NSViewController(); chartContent.view = chart
        let chartWindow = NSWindow(contentViewController: chartContent)
        chartWindow.isReleasedWhenClosed = false; chartWindow.setContentSize(.init(width: 430, height: 330))
        ToolWindowChrome.install(in: chartWindow, settings: settings)
        chartWindow.center(); chartWindow.makeKeyAndOrderFront(nil)
        let paletteFrame = StorageChartIntegration.colored([StorageDimensionalChartVerification.sampleFrames()[0]])
        for style in StorageChartStyle.allCases {
            chartWindow.title = "Traverse · generated review · \(style.title)"
            chart.update(paletteFrame, style: style, reduceMotion: true, reduceTransparency: false)
            try await Task.sleep(for: .milliseconds(100))
            try await GlassVerification.captureOwnedWindow(chartWindow, to: root.appendingPathComponent("evidence/palette-\(style.rawValue).png"))
        }
        for finish in [StorageDimensionalChartView.Finish.enamel, .mineral, .crystal] {
            chart.finish = finish
            chartWindow.title = "Traverse · generated review · \(finish.rawValue) finish"
            chart.update(paletteFrame, style: .tilted, reduceMotion: true, reduceTransparency: false)
            try await Task.sleep(for: .milliseconds(100))
            try await GlassVerification.captureOwnedWindow(chartWindow, to: root.appendingPathComponent("evidence/finish-\(finish.rawValue).png"))
        }
        chart.stopPresentation(); chartWindow.close()
        let colors = try await StorageDimensionalChartVerification.run(captureEvidence: false)
        return ["passed": true, "chart": colors, "permissionRequests": 0, "defaultAppChanges": 0]
    }
    private static var reviewControllers: [NSWindowController] = []
    private static var reviewSettings: NSWindow?
    private static var reviewOwner: ApplicationPrivateNames?

    /// Read-only display of a completed generated case. No Save/Forget/recovery
    /// is replayed. The caller reserves a new output directory in that case.
    static func render(root: URL, output: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/tool-window-presentation")
        try UIVerification.require(root.deletingLastPathComponent() == expected && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && output.deletingLastPathComponent() == root
            && output.lastPathComponent.hasPrefix("render-") && output.resolvingSymlinksInPath() == output
            && FileManager().fileExists(atPath: output.appendingPathComponent("render.json").path), "Unadmitted generated render")
        if ProcessInfo.processInfo.arguments.contains("--check-header-presentation") {
            return try await HeaderPresentationVerification.run(root: root, output: output, browser: browser, review: review)
        }
        let settings = browser.settings
        settings.appearance = .dark; settings.navigationStyle = .glass
        settings.reviewsRecoveryAtStartup = false; settings.autoRefreshFolders = false
        browser.navigate(to: .directory(root.appendingPathComponent("Files")))
        guard let browserWindow = browser.view.window, let toolbar = browserWindow.toolbar else {
            throw UIVerification.Failure(message: "Missing generated workspace toolbar")
        }
        let menuItems = toolbar.items.filter { $0 is NSMenuToolbarItem }
        try UIVerification.require(menuItems.map(\.itemIdentifier.rawValue) == ["fileMenu", "viewMenu", "goMenu", "settingsMenu", "helpMenu"]
            && menuItems.allSatisfy(\.isNavigational) && toolbar.centeredItemIdentifiers.isEmpty,
            "Main menus lost their leading navigation placement")
        NSApplication.shared.activate(ignoringOtherApps: true)
        browserWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        try await GlassVerification.captureOwnedWindow(browserWindow, to: output.appendingPathComponent("workspace-header.png"))
        let owner = ApplicationPrivateNames(directory: root.appendingPathComponent("private-names"), settings: settings)
        let library = PrivateNamesWindowController(owner: owner)
        library.show(browser: browser)
        try await wait("Read-only render did not load") { !library.model.loading && !library.model.rows.isEmpty }
        library.model.selected = library.model.rows.first?.id
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(350))
        guard let window = library.window else { throw UIVerification.Failure(message: "Missing render window") }
        try UIVerification.require(window.isOpaque && window.titlebarAppearsTransparent
            && window.backgroundColor.alphaComponent == 1 && !window.ignoresMouseEvents
            && window.standardWindowButton(.closeButton)?.isEnabled == true,
            "Native titlebar/hit region is not restored")
        try await GlassVerification.captureOwnedWindow(window, to: output.appendingPathComponent("remembered-items-window.png"))
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent("remembered-items-window.png")))
        try UIVerification.require(bitmap.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: 10) }?.alphaComponent ?? 0 > 0.99,
            "Native titlebar still contains a transparent click-through hole")
        let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        let source = root.appendingPathComponent("Files")
        let properties = FilePropertiesWindowController(settings: settings, namesOwner: owner, copyPaths: { _ in })
        properties.update(urls: [source.appendingPathComponent("Folder")])
        let analysis = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        let recovery = OperationRecoveryWindowController(onUndo: { _ in }, onRecover: { _ in }, onRefresh: {})
        let copies = GroupedCopyRecoveryWindowController(recordID: UUID(), onAction: { _, _, _ in }, onUndo: { _, _ in }, onRefresh: {})
        let pickerModel = AnalysisFolderPickerModel(initialDirectory: source, volumes: [], access: FolderAccessController(stateDirectory: nil), showsHidden: true)
        let picker = AnalysisFolderPickerController(model: pickerModel, settings: settings, style: .explorer)
        let sheet = PrivateNamesSheet(owner: owner, browser: browser, source: nil)
        var pageEvents: [BrowserSettingsView.Page: Int] = [:]
        var settingsView = BrowserSettingsView(settings: settings)
        settingsView.onPageVisibilityForVerification = { page, visible in if visible { pageEvents[page, default: 0] += 1 } }
        let preferences = BrowserSettingsWindow.make(settingsView)
        let controllers: [NSWindowController] = [library, properties, analysis, recovery, copies, picker, sheet]
        let windows = controllers.compactMap(\.window) + [preferences]
        for window in windows {
            let frame = window.frame
            let chrome = ToolWindowChrome.install(in: window, settings: settings)
            window.contentView?.layoutSubtreeIfNeeded()
            let child = chrome.children[0].view
            let content = child.convert(child.bounds, to: nil)
            try UIVerification.require(window.frame == frame && window.isOpaque && window.styleMask.contains(.fullSizeContentView)
                && chrome.children.count == 1 && chrome.surface.contentView === chrome.contentHost
                && content.width > 350 && content.height > 280
                && content.maxY <= window.contentLayoutRect.maxY + 1,
                "Glass titlebar changed native ownership, frame or safe content allocation")
        }
        settings.navigationStyle = .solid; settings.appearance = .light; settings.motion.reduceMotion = true
        try await wait("Open windows failed Solid/Light or app Reduce Motion") {
            windows.allSatisfy { ($0.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true
                && !$0.titlebarAppearsTransparent && $0.isOpaque && $0.animationBehavior == .none
                && $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }
        }
        let field = NSTextField(string: "Generated editable text")
        let fieldController = NSViewController(); fieldController.view = field
        let focusWindow = NSWindow(contentViewController: fieldController)
        focusWindow.isReleasedWhenClosed = false; focusWindow.setContentSize(.init(width: 400, height: 320))
        let focusChrome = ToolWindowChrome.install(in: focusWindow, settings: settings)
        focusWindow.makeFirstResponder(field); field.selectText(nil)
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 10, length: 4))
        settings.navigationStyle = .glass; settings.appearance = .dark; settings.motion = .init()
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        try await wait("Open windows failed Glass/Dark") {
            windows.allSatisfy { ($0.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == opaque
                && $0.titlebarAppearsTransparent == !opaque && $0.isOpaque
                && $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        }
        try UIVerification.require(field.stringValue == "Generated editable text"
            && (field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 10, length: 4)
            && focusChrome.children[0].view === field, "Glass header rebuild lost the active editor/selection")
        focusWindow.close()
        preferences.makeKeyAndOrderFront(nil)
        try await wait("Settings navigation did not materialize") { settingsNavigation(in: preferences) != nil && pageEvents[.general, default: 0] > 0 }
        for (index, page) in [(1, BrowserSettingsView.Page.appearance), (2, .keyboard), (3, .operations), (0, .general)] {
            let count = pageEvents[page, default: 0]
            try selectSettingsPage(index, in: preferences)
            try await wait("Settings page did not appear") { pageEvents[page, default: 0] > count }
            try await Task.sleep(for: .milliseconds(240))
            guard let chrome = preferences.contentViewController as? ToolWindowChrome else { throw UIVerification.Failure(message: "Missing Settings chrome") }
            try UIVerification.require(abs(chrome.children[0].view.bounds.width - BrowserSettingsWindow.contentSize.width) < 1
                && abs(chrome.children[0].view.bounds.height - BrowserSettingsWindow.contentSize.height) < 1, "Settings glass header altered page allocation")
        }
        try await GlassVerification.captureOwnedWindow(preferences, to: output.appendingPathComponent("settings-header.png"))
        if review {
            properties.show(urls: [root.appendingPathComponent("Files/Folder")], relativeTo: browser.view.window)
            let token = String(root.lastPathComponent.prefix(8))
            preferences.title = "Settings · glass header review · " + token
            library.window?.title = "Remembered Items · glass header review · " + token
            preferences.center(); preferences.makeKeyAndOrderFront(nil)
            reviewControllers = [library, properties]; reviewSettings = preferences; reviewOwner = owner
        } else { preferences.close(); library.close(); library.model.close(); await owner.close() }
        sheet.finish(); await pickerModel.cancelAndDrain()
        return ["passed": true, "generatedOnly": true, "readOnlyCatalog": true, "appearance": appearance,
                "nativeTitlebarOpaque": true, "capture": "exact owned native windows; no desktop capture", "fileMutationReplayed": false,
                "checks": ["Leading native toolbar menus", "Eight tool controllers retain opaque window hit regions and safe-area content",
                    "Live Glass/Dark and Solid/Light retain native editor selection", "App Reduce Motion disables tool opening",
                    "Four actual Settings page actions retain content allocation"]]
    }

    static func run(root: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/tool-window-presentation")
        try UIVerification.require(root.deletingLastPathComponent() == expected && UUID(uuidString: root.lastPathComponent) != nil
            && root.resolvingSymlinksInPath() == root && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Tool-window checks need the separate generated packet")
        let settings = browser.settings, source = root.appendingPathComponent("Files")
        let foreground = !ProcessInfo.processInfo.arguments.contains("--offscreen")
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        browser.permitsBackgroundVerification = true
        browser.navigate(to: .directory(source))
        let owner = ApplicationPrivateNames(directory: root.appendingPathComponent("private-names"), settings: settings)
        browser.privateNames = owner
        let report = source.appendingPathComponent("Report.txt"), folder = source.appendingPathComponent("Folder")
        let first = try await owner.save(AuthoredNames(nickname: "Generated report", labels: ["review"]), source: report,
            id: nil, revision: nil, access: nil, allowFollowing: true)
        let second = try await owner.save(AuthoredNames(nickname: "Generated folder", labels: ["local", "demo"]), source: folder,
            id: nil, revision: nil, access: nil, allowFollowing: true)
        let library = PrivateNamesWindowController(owner: owner)
        if foreground { library.show(browser: browser) }
        else {
            ToolWindowChrome.install(in: library.window!, settings: settings)
            library.model.start(browser: browser)
        }
        try await wait("Remembered Items did not load") { library.model.rows.count == 2 && !library.model.loading }
        library.model.selected = first
        let properties = FilePropertiesWindowController(settings: settings, namesOwner: owner, copyPaths: { _ in })
        properties.update(urls: [folder])
        let analysis = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        analysis.applyToolStyle(settings)
        let recovery = OperationRecoveryWindowController(onUndo: { _ in }, onRecover: { _ in }, onRefresh: {})
        let copies = GroupedCopyRecoveryWindowController(recordID: UUID(), onAction: { _, _, _ in }, onUndo: { _, _ in }, onRefresh: {})
        let pickerModel = AnalysisFolderPickerModel(initialDirectory: source, volumes: [], access: FolderAccessController(stateDirectory: nil), showsHidden: true)
        let picker = AnalysisFolderPickerController(model: pickerModel, settings: settings, style: .explorer)
        let sheet = PrivateNamesSheet(owner: owner, browser: browser, source: nil)
        var pageEvents: [BrowserSettingsView.Page: Int] = [:]
        var settingsView = BrowserSettingsView(settings: settings)
        settingsView.onPageVisibilityForVerification = { page, visible in if visible { pageEvents[page, default: 0] += 1 } }
        let preferences = BrowserSettingsWindow.make(settingsView)
        let controllers: [NSWindowController] = [properties, library, analysis, recovery, copies, picker, sheet]
        let windows = controllers.compactMap(\.window) + [preferences]
        for window in windows { ToolWindowChrome.install(in: window, settings: settings) }
        var checks: [String] = []
        for window in windows {
            guard let chrome = window.contentViewController as? ToolWindowChrome else { throw UIVerification.Failure(message: "Missing native tool material") }
            window.contentView?.layoutSubtreeIfNeeded()
            try UIVerification.require(chrome.children.count == 1 && chrome.children[0].view.isDescendant(of: chrome.surface)
                && chrome.surface.contentView === chrome.contentHost
                && chrome.view.bounds.width > 350 && chrome.view.bounds.height > 300,
                "Tool material changed controller ownership or native allocation")
        }
        checks.append("eight actual window/panel controllers retain sized content under one native material")
        settings.navigationStyle = .solid; settings.appearance = .dark
        try await wait("Open tool windows did not apply Solid/Dark") {
            windows.allSatisfy { ($0.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true
                && $0.isOpaque && $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        }
        checks.append("live Solid/Dark updates all tools without rebuilding their model")
        // A real field editor belongs to a stable control while its material is rebuilt.
        let field = NSTextField(string: "Generated editable text")
        let fieldController = NSViewController(); fieldController.view = field
        let focusWindow = NSWindow(contentViewController: fieldController)
        focusWindow.isReleasedWhenClosed = false; focusWindow.setContentSize(.init(width: 400, height: 320))
        let focusChrome = ToolWindowChrome.install(in: focusWindow, settings: settings)
        focusWindow.makeFirstResponder(field); field.selectText(nil)
        let editor = field.currentEditor() as? NSTextView
        editor?.setSelectedRange(NSRange(location: 10, length: 4))
        settings.navigationStyle = .glass; settings.appearance = .light
        let accessibilityOpaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        try await wait("Open tool windows did not apply Glass/Light") {
            windows.allSatisfy { ($0.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == accessibilityOpaque
                && $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }
        }
        try UIVerification.require(field.stringValue == "Generated editable text" && field.currentEditor() != nil
            && (field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 10, length: 4)
            && focusChrome.children[0].view === field, "Material change lost the native field editor or its selection")
        focusWindow.close()
        checks.append("Glass/Light and accessibility policy retain native content and an active field editor/selection")
        for reduced in [false, true] { for contrast in [false, true] {
            try UIVerification.require(BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: true,
                reduceTransparency: reduced, increaseContrast: contrast) == (!reduced && !contrast), "Accessibility material policy regression")
        } }
        checks.append("Reduce Transparency/Increase Contrast policy keeps opaque fallback; no system preference changes")
        // Forget is observed while the selected private detail entrance is active.
        library.model.selected = second
        await Task.yield()
        _ = try await owner.forget(second)
        try UIVerification.require(library.model.selected == nil && !library.model.rows.contains(where: { $0.id == second }),
            "Forget retained outgoing detail content during a page entrance")
        try await wait("Forget refresh did not settle") { !library.model.loading }
        library.model.selected = first
        checks.append("Forget immediately withdraws selected rows/details during entrance; no outgoing private snapshot")
        let before = library.window!.frame
        if foreground { library.show(browser: browser) }
        else { ToolWindowChrome.install(in: library.window!, settings: settings) }
        try UIVerification.require(library.window!.frame == before
            && (library.window!.contentViewController as? ToolWindowChrome)?.children.count == 1,
            "Reopen nested material controllers or moved a visible window")
        checks.append("showing an already visible window preserves its frame and single controller wrapper")
        if foreground {
            preferences.makeKeyAndOrderFront(nil)
            try await wait("Settings navigation did not materialize") { settingsNavigation(in: preferences) != nil && pageEvents[.general, default: 0] > 0 }
            for (index, page) in [(1, BrowserSettingsView.Page.appearance), (2, .keyboard), (3, .operations), (0, .general)] {
                let count = pageEvents[page, default: 0]
                try selectSettingsPage(index, in: preferences)
                try await wait("Settings page entrance did not appear") { pageEvents[page, default: 0] > count }
                try await Task.sleep(for: .milliseconds(240))
                let content = (preferences.contentViewController as? ToolWindowChrome)?.children.first?.view
                try UIVerification.require(abs((content?.bounds.width ?? 0) - BrowserSettingsWindow.contentSize.width) < 1 && abs((content?.bounds.height ?? 0) - BrowserSettingsWindow.contentSize.height) < 1,
                    "Settings page motion resized its native allocation")
            }
            checks.append("four native Settings pages reveal at fixed allocation using actual tab actions")
        }
        // Real native detail animation drains without retaining a transition tree.
        let view = analysis.scopeLabel
        if foreground { analysis.showWindow(nil) }
        ToolContentMotion.reveal(view); ToolContentMotion.reveal(view)
        try await Task.sleep(for: .milliseconds(260))
        try UIVerification.require(view.layer?.animation(forKey: "tool-content-entrance") == nil,
            "Incoming detail animation did not drain")
        checks.append("rapid native detail reveals replace one animation and drain")
        settings.appearance = .dark; settings.navigationStyle = .glass
        try await Task.sleep(for: .milliseconds(100))
        try await wait("Final remembered detail did not load") { !library.model.loading && !library.model.rows.isEmpty }
        library.model.selected = first
        try await Task.sleep(for: .milliseconds(240))
        // Generated NSView render only; does not capture another application's
        // pixels. Actual compositor/glass acceptance remains a physical review.
        if let window = library.window { try await UIVerification.snapshot(window, to: root.appendingPathComponent("remembered-items-native.png")) }
        preferences.orderOut(nil); analysis.window?.orderOut(nil)
        if review {
            reviewControllers = controllers; reviewSettings = preferences; reviewOwner = owner
            library.window?.title = "Remembered Items · generated theme review"
            library.window?.makeKeyAndOrderFront(nil)
            library.model.selected = first
            properties.window?.title = "Properties · generated theme review"
            properties.show(urls: [folder], relativeTo: browser.view.window)
            library.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            for controller in controllers { controller.window?.orderOut(nil) }
            library.model.close(); properties.cancel(); sheet.finish()
            await pickerModel.cancelAndDrain(); await owner.close()
        }
        return ["passed": true, "generatedOnly": true, "checks": checks, "foregroundPages": foreground,
                "metadataOnly": true, "operationEngineExercised": false, "personalCatalogOpened": false]
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), message)
    }
    private static func settingsNavigation(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView?.superview else { return nil }
        var pending = [root], count = 0
        while let view = pending.popLast(), count < 512 {
            count += 1
            if let table = view as? NSTableView, table.identifier?.rawValue == "settings-navigation",
               table.numberOfRows == BrowserSettingsView.Page.ordered.count { return table }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    private static func selectSettingsPage(_ index: Int, in window: NSWindow) throws {
        guard let table = settingsNavigation(in: window), (0..<table.numberOfRows).contains(index) else {
            throw UIVerification.Failure(message: "Native Settings navigation is unavailable")
        }
        let point = table.convert(.init(x: 80, y: table.rect(ofRow: index).midY), to: nil)
        func event(_ kind: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw UIVerification.Failure(message: "Native Settings click unavailable")
            }
            return event
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
        try UIVerification.require(table.selectedRow == index, "Native Settings click did not select its section")
    }

}
#endif
