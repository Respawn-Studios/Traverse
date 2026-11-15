#if DEBUG
import AppKit
import Combine
import StorageAnalysis

private final class StorageChartQueryHold: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { reached } }
    func pause() {
        lock.withLock { reached = true }
        _ = release.wait(timeout: .now() + 30)
    }
}

/// Two retained, generated sources only. Exercises the actual Properties and
/// full-analysis projection, not a second renderer or independent query owner.
@MainActor
enum StorageChartIntegrationVerification {
    static var review: FilePropertiesWindowController?
    private static func require(_ value: Bool, _ message: String) throws { try UIVerification.require(value, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func settled(_ view: StorageDimensionalChartView, depth: Int) async throws {
        try await wait("Integrated chart did not settle at depth \(depth)") { view.frames.count == depth && !view.isAnimating }
    }
    private static func propertiesScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, scroll.frame.width > 300,
           (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 80 { return scroll }
        for child in view.subviews {
            if let scroll = propertiesScroll(in: child) { return scroll }
        }
        return nil
    }
    private static func verifyPendingGroup(_ name: String, result: StorageAnalysisResult,
                                           drill: StorageBreakdownChartModel, surface: StorageDimensionalChartView,
                                           window: NSWindow, scroll: NSScrollView, sourceAccesses: () -> Int) async throws {
        try await wait("Previous stored query did not drain") { result.activeReaderCount == 0 }
        let hold = StorageChartQueryHold(), initialY = scroll.contentView.bounds.origin.y, chartSize = surface.bounds.size
        let initialAccesses = sourceAccesses(), initialWorkers = result.queryWorkerLaunchCountForQualification
        try result.installQueryReleaseHookForQualification { hold.pause() }
        defer {
            hold.release.signal()
            if result.activeReaderCount == 0 { try? result.installQueryReleaseHookForQualification(nil) }
        }
        StorageChartIntegration.groupSelectionForQualification.send((result.id, name))
        try await wait("First \(name) read did not reach its held catalog response") { hold.entered && drill.loading }
        try await wait("Pending \(name) did not retain its Properties chart") {
            surface.window === window && surface.frames.isEmpty && surface.bounds.size == chartSize
        }
        try await wait("Pending \(name) changed the Properties viewport") {
            abs(scroll.contentView.bounds.origin.y - initialY) < 2
        }
        try require(!surface.interactive && sourceAccesses() == initialAccesses,
            "Pending \(name) exposed stale chart actions or changed source authority")
        hold.release.signal()
        try await wait("Held \(name) query did not settle") { !drill.loading && result.activeReaderCount == 0 }
        try await settled(surface, depth: 1)
        try await wait("Settled \(name) changed the Properties viewport") {
            abs(scroll.contentView.bounds.origin.y - initialY) < 2
        }
        try require(surface.window === window && surface.bounds.size == chartSize && sourceAccesses() == initialAccesses
            && result.queryWorkerLaunchCountForQualification == initialWorkers + 1,
            "\(name) changed chart geometry, reacquired the source, or did not use one stored query")
    }
    private static func boundaryControls() throws {
        func frame(_ index: Int, _ bytes: UInt64?) -> StorageChartSlice {
            .init(id: "slice-\(index)", title: "Generated \(index)", amount: "observed", bytes: bytes,
                  canOpen: true, tint: .hex(0x32aaff))
        }
        var source = StorageChartFrame(id: "bounds", title: "Generated", slices: (0..<16).map { frame($0, UInt64($0)) })
        var bounded = StorageChartIntegration.bounded(source)
        try require(bounded.isValid && bounded.slices.count == 15 && bounded.slices.last?.bytes == 29
            && bounded.slices.last?.canOpen == false, "Sixteen provisional groups lost their exact bounded remainder")
        source.slices[15] = frame(15, nil); bounded = StorageChartIntegration.bounded(source)
        try require(bounded.slices.last?.bytes == nil, "Unknown remainder became zero")
        source.slices[15] = frame(15, .max); bounded = StorageChartIntegration.bounded(source)
        try require(bounded.slices.last?.bytes == nil, "Overflow remainder became a known size")
        let deck = (0..<17).map { StorageChartFrame(id: "frame-\($0)", title: "Generated", slices: [frame($0, 1)]) }
        let geometry = StorageChartGeometry(size: .init(width: 300, height: 300), style: .tilted)
        try require(!geometry.settled(deck).faces.isEmpty && geometry.settled(deck + [deck[0]]).faces.isEmpty,
            "Root plus sixteen levels was refused, or an eighteenth frame admitted")
        let view = StorageDimensionalChartView(frame: .init(x: 0, y: 0, width: 300, height: 300))
        view.update(deck, style: .tilted, reduceMotion: true, reduceTransparency: false)
        try require(view.frames.count == 17, "Native surface limit differs from query/geometry limits")
        view.update(deck + [deck[0]], style: .tilted, reduceMotion: true, reduceTransparency: false)
        try require(view.frames.isEmpty && !view.isAnimating, "Oversized native deck retained actionable state")
    }
    static func showReview(path: String) async throws {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let root = URL(fileURLWithPath: path)
        try require(root.path == repository.appendingPathComponent(".build/b06-analyzer/classification-fixture-b901d8dc2fb3434b9335bc5bbaa1edfd").path,
            "Only the retained two-file review fixture is admitted")
        StorageChartIntegration.startAtStorageRolesForQualification = true
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage)
        let properties = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) }, copyPaths: { _ in })
        review = properties; properties.show(urls: [root])
        properties.window?.title = "Mac Explorer · Properties chart integration review"
        properties.window?.setContentSize(.init(width: 580, height: 780)); NSApplication.shared.activate()
        try await wait("Review Properties metadata unavailable") { !properties.model.isLoading }
        properties.model.analyzeStorage()
        try await wait("Review generated scan unavailable") { !coordinator.hasWork && properties.model.chartDrill.canBrowse }
        try require(coordinator.pagedSummaryForVerification?.value.bytes.dataLogical.knownBytes == 70,
            "Review generated accounting changed")
        print("MAC_EXPLORER_CHART_INTEGRATION_REVIEW_READY"); fflush(stdout)
    }
    static func run(path: String, captureEvidence: Bool = true, layoutExplanations: Bool = false, applicationLayouts: Bool = false) async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let root = URL(fileURLWithPath: path), prefix = "classification-fixture-"
        let token = root.lastPathComponent.dropFirst(prefix.count)
        try require(root.path == root.standardizedFileURL.path
            && root.deletingLastPathComponent() == repository.appendingPathComponent(".build/b06-analyzer")
            && root.lastPathComponent.hasPrefix(prefix) && token.count == 32
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Generated Steam root required")
        try boundaryControls()
        let preference = try await StorageChartPreferenceVerification.run(evidence: repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018"))
        let settings = preference.settings
        StorageChartIntegration.startAtStorageRolesForQualification = true
        StorageDimensionalChartProbe.enabled = true
        StorageChartIntegration.appearance.choose(.tilted)
        defer {
            StorageChartIntegration.startAtStorageRolesForQualification = false
            StorageDimensionalChartProbe.enabled = false
        }
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage, workerURL: applicationLayouts
            ? repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-application-layouts/worker") : layoutExplanations
            ? repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-classification-v3-layouts/worker") : nil)
        var accesses = 0
        let properties = FilePropertiesWindowController(retainAccess: { _ in
            accesses += 1; return FileAccessLifetimes(leases: [])
        }, settings: settings, copyPaths: { _ in })
        defer { properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.show(urls: [root]); properties.window?.setContentSize(.init(width: 580, height: 780))
        NSApplication.shared.activate()
        try await wait("Shallow generated Properties did not finish") { !properties.model.isLoading }
        try require(properties.model.canAnalyzeStorage && !coordinator.hasWork && accesses == 1, "Opening Properties started a scan")
        properties.model.analyzeStorage()
        try await wait("Generated Properties result unavailable") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        guard let result = coordinator.pagedResultForVerification, let summary = coordinator.pagedSummaryForVerification else { throw StorageScanFailure.invalidOutput }
        try require(result.classificationRevision == (applicationLayouts || layoutExplanations ? .v3 : .v4) && summary.complete && summary.value.counts.regularFiles == 2 && summary.value.bytes.dataLogical.knownBytes == 70
            && properties.model.attribution?.categories.first(where: { $0.storedTarget == .steamLibraries })?.bytes.dataLogical.knownBytes == 70,
            "Generated source no longer matches the independent two-file oracle")
        let scanAccesses = accesses, drill = properties.model.chartDrill
        try await wait("Actual Properties did not create the native chart") { StorageDimensionalChartProbe.latest?.window === properties.window }
        guard let surface = StorageDimensionalChartProbe.latest else { throw StorageScanFailure.invalidOutput }
        let creations = StorageDimensionalChartProbe.creations
        try await settled(surface, depth: 1)
        try require(surface.frames.last?.slices.first?.id == "steam" && surface.frames.last?.slices.first?.bytes == 70,
            "Properties did not project the stored role target and amount")
        // Exercise first-load transitions in the actual Properties ScrollView;
        // the separate Layouts review starts with preloaded groups.
        guard let propertiesWindow = properties.window else { throw UIVerification.Failure(message: "Properties window missing") }
        propertiesWindow.setContentSize(.init(width: 580, height: 500))
        try await wait("Properties vertical viewport unavailable") { propertiesScroll(in: propertiesWindow.contentView) != nil }
        guard let scroll = propertiesScroll(in: propertiesWindow.contentView) else { throw UIVerification.Failure(message: "Properties viewport missing") }
        let initialOrigin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: .init(x: initialOrigin.x, y: initialOrigin.y + 80))
        if abs(scroll.contentView.bounds.origin.y - initialOrigin.y) < 20 {
            scroll.contentView.scroll(to: .init(x: initialOrigin.x, y: initialOrigin.y - 80))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        try require(abs(scroll.contentView.bounds.origin.y - initialOrigin.y) >= 20,
            "Properties fixture did not establish a nonzero viewport")
        try await Task.sleep(for: .milliseconds(50))
        try await verifyPendingGroup("Folders", result: result, drill: drill, surface: surface,
            window: propertiesWindow, scroll: scroll, sourceAccesses: { accesses })
        let workersAfterFolders = result.queryWorkerLaunchCountForQualification
        StorageChartIntegration.groupSelectionForQualification.send((result.id, "Purpose"))
        try await wait("Properties Purpose root was not restored") { surface.frames.last?.slices.first?.id == "steam" && !drill.loading }
        StorageChartIntegration.groupSelectionForQualification.send((result.id, "Folders"))
        try await wait("Cached Folders root was not restored") { surface.frames.last?.id == "folder-0" && !drill.loading }
        try require(result.queryWorkerLaunchCountForQualification == workersAfterFolders && accesses == scanAccesses,
            "Returning to Folders queried the catalog again or reacquired source access")
        let stale = StorageChartQueryHold()
        try result.installQueryReleaseHookForQualification { stale.pause() }
        defer { stale.release.signal(); if result.activeReaderCount == 0 { try? result.installQueryReleaseHookForQualification(nil) } }
        drill.open(.steamLibraries, title: "Superseded stored query")
        try await wait("Superseded query was not held") { stale.entered && drill.loading }
        drill.openRootFolder(title: "Cached folder root")
        try require(drill.current?.target == .folder(0) && !drill.loading,
            "Cached root did not replace the pending drill intent")
        stale.release.signal()
        await drill.waitUntilQueriesDrained()
        try require(drill.current?.target == .folder(0) && drill.levels.count == 1,
            "Older stored query replaced the cached folder root")
        try result.installQueryReleaseHookForQualification(nil)
        StorageChartIntegration.groupSelectionForQualification.send((result.id, "Purpose"))
        try await wait("Properties Purpose root did not return") { surface.frames.last?.slices.first?.id == "steam" && !drill.loading }
        if result.supportsApplicationLayouts {
            try await verifyPendingGroup("App Libraries", result: result, drill: drill, surface: surface,
                window: propertiesWindow, scroll: scroll, sourceAccesses: { accesses })
            let workersAfterLayouts = result.queryWorkerLaunchCountForQualification
            StorageChartIntegration.groupSelectionForQualification.send((result.id, "Purpose"))
            try await wait("Properties Purpose root did not return from Layouts") { surface.frames.last?.slices.first?.id == "steam" && !drill.loading }
            StorageChartIntegration.groupSelectionForQualification.send((result.id, "App Libraries"))
            try await wait("Cached Layouts root was not restored") { surface.frames.last?.id.contains("App Libraries") == true && !drill.loading }
            try require(result.queryWorkerLaunchCountForQualification == workersAfterLayouts && accesses == scanAccesses,
                "Returning to App Libraries queried the catalog again or reacquired source access")
            StorageChartIntegration.groupSelectionForQualification.send((result.id, "Purpose"))
            try await wait("Properties Purpose root did not return from cached Layouts") { surface.frames.last?.slices.first?.id == "steam" && !drill.loading }
        }
        try require(StorageDimensionalChartProbe.latest === surface && StorageDimensionalChartProbe.creations == creations,
            "Group switching recreated the Properties chart surface")
        let drillOrigin = scroll.contentView.bounds.origin.y
        surface.activateForQualification(.slice(0))
        try await wait("Properties Steam query") { drill.levels.count == 1 && !drill.loading }
        try await settled(surface, depth: 2)
        try await wait("Properties drill moved the viewport") { abs(scroll.contentView.bounds.origin.y - drillOrigin) < 2 }
        surface.activateForQualification(.ancestor(0))
        try await wait("Properties Back did not restore the root") { drill.levels.isEmpty && !drill.loading }
        try await settled(surface, depth: 1)
        try await wait("Properties Back moved the viewport") { abs(scroll.contentView.bounds.origin.y - drillOrigin) < 2 }
        surface.activateForQualification(.slice(0))
        try await wait("Properties Steam query after Back") { drill.levels.count == 1 && !drill.loading }
        try await settled(surface, depth: 2)
        propertiesWindow.setContentSize(.init(width: 580, height: 780))
        scroll.contentView.scroll(to: initialOrigin); scroll.reflectScrolledClipView(scroll.contentView)
        let chosenTint = surface.frames[0].slices[0].tint
        try require(surface.frames.last?.slices.max(by: { ($0.bytes ?? 0) < ($1.bytes ?? 0) })?.tint == chosenTint,
            "Integrated child did not inherit its chosen parent color")
        let captures = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018")
        let propertyCapture = captures.appendingPathComponent("integrated-properties-" + UUID().uuidString + ".png")
        if captureEvidence, let window = properties.window { try await UIVerification.snapshot(window, to: propertyCapture) }
        guard let installed = drill.current?.value.rows.first(where: { $0.hint == 1 }), let folder = installed.folder,
              let installedIndex = surface.frames.last?.slices.firstIndex(where: { $0.id == StorageChartIntegration.key(.folder(folder)) }) else {
            throw UIVerification.Failure(message: "Integrated Steam installed target unavailable")
        }
        surface.activateForQualification(.slice(installedIndex))
        try await wait("Installed games query") { drill.levels.count == 2 && !drill.loading }
        try await settled(surface, depth: 3)
        try require(drill.current?.value.rows.first?.title == "Game" && surface.frames.last?.slices.first?.bytes == 30,
            "Stored installed-game totals changed")
        surface.activateForQualification(.slice(0))
        try await wait("Third stored drill level") { drill.levels.count == 3 && !drill.loading }
        try await settled(surface, depth: 4)
        try require(StorageDimensionalChartProbe.latest === surface && StorageDimensionalChartProbe.creations == creations,
            "Drilling recreated the Properties drawing surface")
        // A single cached ancestor publication, without serial Back/query loops.
        var publications = 0
        let subscription = drill.$levels.dropFirst().sink { _ in publications += 1 }
        drill.returnToLevelCount(1)
        try require(publications == 1 && drill.levels.count == 1, "Breadcrumb return emitted intermediate levels")
        subscription.cancel()
        try await settled(surface, depth: 2)
        surface.activateForQualification(.ancestor(0))
        try await wait("Exposed parent return") { drill.levels.isEmpty }
        try await settled(surface, depth: 1)
        surface.activateForQualification(.slice(0))
        try await wait("Reopen stored Steam") { drill.levels.count == 1 && !drill.loading }
        try await settled(surface, depth: 2)
        drill.back(); try await settled(surface, depth: 1)
        drill.open(.steamLibraries, title: "Pending request")
        drill.back()
        try await wait("Back failed to reject the pending first query") { !drill.loading && result.activeReaderCount == 0 }
        try require(drill.levels.isEmpty, "Cancelled first query restored stale state")
        drill.open(.steamLibraries, title: "Steam & games")
        try await wait("Stored metric setup") { drill.levels.count == 1 && !drill.loading }
        drill.open(.folder(folder), title: installed.title)
        try await wait("Metric child setup") { drill.levels.count == 2 && !drill.loading }
        drill.setMetric(.allForkAllocated); drill.returnToLevelCount(1)
        try await wait("Metric/ancestor intent did not converge") {
            drill.levels.count == 1 && drill.current?.value.rankingMetric == .allForkAllocated && !drill.loading
        }
        drill.returnToLevelCount(-1); drill.returnToLevelCount(2)
        try require(drill.levels.count == 1, "Invalid ancestor was accepted")
        drill.setMetric(.dataLogical)
        try await wait("Logical metric restoration") { drill.current?.value.rankingMetric == .dataLogical && !drill.loading }
        try require(accesses == scanAccesses && coordinator.pagedResultForVerification?.id == result.id && !coordinator.hasWork,
            "Chart navigation/metric changes rescanned or reacquired access")
        properties.model.openFullAnalysis()
        try await wait("Same-result full analysis handoff") { coordinator.toolWindow?.pagedReadyForVerification == true }
        guard let tool = coordinator.toolWindow, let window = tool.window else { throw StorageScanFailure.invalidOutput }
        window.setContentSize(.init(width: 960, height: 800)); window.makeKeyAndOrderFront(nil)
        if tool.compactBreakdownForVerification { tool.expandBreakdownButton.performClick(nil) }
        try await wait("Full analysis chart unavailable") { StorageDimensionalChartProbe.latest?.window === window }
        guard let full = StorageDimensionalChartProbe.latest else { throw StorageScanFailure.invalidOutput }
        try await settled(full, depth: 1)
        try require(coordinator.pagedResultForVerification?.id == result.id && accesses == scanAccesses
            && full.frames.first?.slices == surface.frames.first?.slices, "Handoff changed result, targets, colors or acquired access")
        let fullDrill = tool.chartDrillForVerification
        full.activateForQualification(.slice(0))
        try await wait("Full analysis stored drill") { fullDrill.levels.count == 1 && !fullDrill.loading }
        try await settled(full, depth: 2)
        for style in StorageChartStyle.allCases {
            settings.analysisChartStyle = style
            try await wait("Shared chart style did not update") { full.style == style && surface.style == style }
            try require(coordinator.pagedResultForVerification?.id == result.id && accesses == scanAccesses && !coordinator.hasWork,
                "Presentation style launched scan work")
        }
        full.onStyle(.orbitable)
        try await wait("Pie style choice did not update settings and both windows") {
            settings.analysisChartStyle == .orbitable && full.style == .orbitable && surface.style == .orbitable
        }
        await settings.drainPreferencesForVerification()
        let savedStyle = try await Task.detached(priority: .utility) { try Data(contentsOf: preference.file) }.value
        try require(BrowserSettings(persist: false, restoredData: savedStyle).analysisChartStyle == .orbitable
            && coordinator.pagedResultForVerification?.id == result.id && accesses == scanAccesses && !coordinator.hasWork,
            "Pie selection did not persist or changed scan ownership")
        StorageChartIntegration.appearance.choose(.tilted)
        fullDrill.reset()
        var applicationChecks: [String] = []
        let applicationCapture = captures.appendingPathComponent("integrated-applications-" + UUID().uuidString + ".png")
        fullDrill.open(.filtered(folder: 0, facet: .fileTypes, key: 0), title: "Other / no recognized extension")
        try await wait("Other explanation setup") { fullDrill.levels.count == 1 && !fullDrill.loading }
        try require(fullDrill.canExplainOther && fullDrill.current?.otherExplanation == nil,
            "Other explanation must remain explicit, not another automatic query")
        fullDrill.explainOther()
        try await wait("Explicit stored Other explanation") { !fullDrill.loading && result.activeReaderCount == 0 }
        try require(fullDrill.current?.otherExplanation?.value.bytes.dataLogical.knownBytes == 70
            && fullDrill.current?.otherExplanation?.storageRoles[AnalysisCategory.steamLibrary.rawValue].bytes.dataLogical.knownBytes == 70
            && fullDrill.current?.otherExplanation?.namePatterns[AnalysisOtherNamePattern.ambiguousBinarySuffix.rawValue].bytes.dataLogical.knownBytes == 70,
            "Other explanation changed its literal 70-byte role/name-pattern oracle")
        let layouts = fullDrill.current?.otherExplanation?.applicationLayouts
        try require(!layoutExplanations || layouts != nil, "Qualified layout explanation capability is missing")
        if let layouts {
            try require(layouts[AnalysisApplicationLayout.steamInstalled.rawValue].bytes.dataLogical.knownBytes == 30
                && layouts[AnalysisApplicationLayout.steamWorkshop.rawValue].bytes.dataLogical.knownBytes == 40,
                "Native layout explanations changed the independent30/40-byte Steam oracle")
        }
        fullDrill.explainOther()
        try require(!fullDrill.loading && result.activeReaderCount == 0, "Cached explanation started duplicate stored work")
        fullDrill.setMetric(.allForkAllocated)
        try await wait("Other explanation metric update") { !fullDrill.loading }
        try require(fullDrill.current?.otherExplanation != nil && accesses == scanAccesses && !coordinator.hasWork,
            "Metric update discarded the four-metric explanation or rescanned")
        fullDrill.back()
        fullDrill.open(.filtered(folder: 0, facet: .fileTypes, key: 0), title: "Other")
        try await wait("Cancelled explanation setup") { fullDrill.levels.count == 1 && !fullDrill.loading }
        fullDrill.explainOther(); fullDrill.back()
        try await wait("Other explanation cancellation drains") { result.activeReaderCount == 0 && !fullDrill.loading }
        try require(fullDrill.levels.isEmpty, "A cancelled explanation resurrected an old chart level")
        fullDrill.open(.filtered(folder: 0, facet: .fileTypes, key: 0), title: "Other / no recognized extension")
        try await wait("Visible explanation setup") { fullDrill.levels.count == 1 && !fullDrill.loading }
        fullDrill.explainOther()
        try await wait("Visible explanation") { fullDrill.current?.otherExplanation != nil && !fullDrill.loading }
        fullDrill.setMetric(.dataLogical)
        try await wait("Displayed explanation metric") { !fullDrill.loading }
        try await settled(full, depth: 2)
        let fullCapture = captures.appendingPathComponent("integrated-full-" + UUID().uuidString + ".png")
        if captureEvidence { try await UIVerification.snapshot(window, to: fullCapture) }
        let accountingCapture = captures.appendingPathComponent("generated-startup-accounting-" + UUID().uuidString + ".png")
        window.title = "Storage Analysis · generated accounting example"
        tool.showStartupAccounting(.init(capacity: 1_000_000_000, available: 400_000_000,
            system: .init(bytes: 10_000_000), data: .init(bytes: 390_000_000)))
        try await wait("Accounting update preserves the native chart") { StorageDimensionalChartProbe.latest === full }
        try require(coordinator.pagedResultForVerification?.id == result.id && accesses == scanAccesses
            && result.activeReaderCount == 0 && !coordinator.hasWork,
            "A capacity/source-accounting update restarted scan or result work")
        if captureEvidence { try await UIVerification.snapshot(window, to: accountingCapture) }
        tool.showStartupAccounting(nil); window.title = "Storage Analysis"
        // A separate new surface must not replace the weak global probe while
        // the preceding same-surface accounting assertion is still pending.
        if applicationLayouts || result.supportsApplicationLayouts {
            guard let report = properties.model.attribution else { throw StorageScanFailure.invalidOutput }
            applicationChecks = try await StorageApplicationLayoutVerification.run(result: result, report: report, capture: captureEvidence ? applicationCapture : nil)
            try require(accesses == scanAccesses && !coordinator.hasWork, "Application Layouts started source scan/access work")
        }
        // Supersede both views with a generated wide result. Observe prefixes;
        // they may draw known bytes but must never offer a stored-result drill.
        let wide = try await StorageAnalysisScaleVerification.admittedSource("wide")
        properties.update(urls: [wide])
        try await wait("Wide shallow Properties") { !properties.model.isLoading }
        properties.window?.makeKeyAndOrderFront(nil)
        coordinator.seedStartupAccountingForVerification(.init(capacity: 1_000, available: 400,
            system: .init(bytes: 10), data: .init(bytes: 390)))
        properties.model.analyzeStorage()
        try require(properties.model.startupAccounting == nil, "New Properties request published previous startup accounting before preparation")
        var sawPrefix = false, safePrefix = true
        let scopeDeadline = ProcessInfo.processInfo.systemUptime + 15
        while coordinator.hasWork {
            try require(ProcessInfo.processInfo.systemUptime < scopeDeadline, "Generated scope replacement did not drain")
            if properties.model.attribution?.isProvisional == true {
                sawPrefix = true
                safePrefix = safePrefix && !properties.model.chartDrill.canBrowse
                    && properties.model.attribution?.fileTypes.allSatisfy({ $0.storedTarget == nil }) == true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(sawPrefix && safePrefix && coordinator.pagedSummaryForVerification?.value.counts.total == 100000
            && coordinator.pagedResultForVerification?.id != result.id && !fullDrill.canBrowse && !full.isAnimating,
            "Scope replacement retained stale chart authority or provisional drill targets")
        guard let wideResult = coordinator.pagedResultForVerification else { throw StorageScanFailure.invalidOutput }
        try require(wideResult.classificationRevision == .v4, "Replacement lost the ordinary classification revision")
        let latestDrill = properties.model.chartDrill
        try await wait("Replaced Properties chart unavailable") { StorageDimensionalChartProbe.latest?.window === properties.window }
        guard let closing = StorageDimensionalChartProbe.latest else { throw StorageScanFailure.invalidOutput }
        try await settled(closing, depth: 1)
        guard let closeIndex = closing.frames.last?.slices.firstIndex(where: \.canOpen) else { throw StorageScanFailure.invalidOutput }
        // Qualify actual native driver/deadline teardown even when an overnight
        // display is occluded/asleep. This is explicit test admission, not a
        // claim that the display composited a frame or met a cadence gate.
        closing.forceVisiblePresentationForQualification = true
        closing.activateForQualification(.slice(closeIndex))
        try await wait("Close transition setup") { latestDrill.levels.count == 1 && !latestDrill.loading }
        try await wait("Actual close-during-transition was not exercised") { closing.isTransitioning }
        latestDrill.open(.folder(0), title: "Pending at close")
        properties.close(); tool.close()
        await coordinator.stopAndDrain()
        await result.waitUntilReadersDrained(); await wideResult.waitUntilReadersDrained()
        await settings.drainPreferencesForVerification()
        try require(!closing.isAnimating && !full.isAnimating && !surface.isAnimating
            && !latestDrill.canBrowse && latestDrill.levels.isEmpty && !coordinator.hasWork
            && result.activeReaderCount == 0 && wideResult.activeReaderCount == 0 && ApplicationFileActivity.gate.activeCount == 0,
            "Integrated close retained work: drivers=\(closing.isAnimating)/\(full.isAnimating)/\(surface.isAnimating), browse=\(latestDrill.canBrowse), levels=\(latestDrill.levels.count), coordinator=\(coordinator.hasWork), readers=\(result.activeReaderCount)/\(wideResult.activeReaderCount), gate=\(ApplicationFileActivity.gate.activeCount)")
        return ["passed": true, "checks": preference.checks + applicationChecks + ["root plus sixteen levels; oversized refusal", "bounded provisional remainder; unknown/overflow",
            "actual Properties stored role targets", "three native stored drill activations", "dominant inherited color",
            "stable Properties surface", "single-publication breadcrumb return", "exposed parent callback", "Back",
            "pending first-query cancellation", "metric/ancestor arbitration", "invalid ancestor refusal", "same-handle full handoff",
            "shared three styles without rescan", "pie selection persists and updates both windows", "explicit Other explanation with exact role/name partitions", "cached explanation and four-metric update without rescan", "cancelled explanation cannot restore a level", "System/Data display preserves chart, result and access ownership", "new request refuses stale startup accounting", "provisional authority withheld", "scope replacement", "close/query/driver drain"],
            "captures": captureEvidence ? [propertyCapture.lastPathComponent, fullCapture.lastPathComponent, accountingCapture.lastPathComponent] + (applicationChecks.isEmpty ? [] : [applicationCapture.lastPathComponent]) : [], "generated_scans": 2,
            "ordinary_dimensional_chart": true,
            "close_transition_visibility_override": true, "display_cadence_exercised": false,
            "ordinary_classification_revision": result.classificationRevision.rawValue,
            "layout_explanation_capability": layouts != nil,
            "application_layout_capability": result.supportsApplicationLayouts,
            "initial_group": "Storage Roles (qualification only)", "gate_active": ApplicationFileActivity.gate.activeCount,
            "retained_generated_stores": 2, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began]
    }
}
#endif
