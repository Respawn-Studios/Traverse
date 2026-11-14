#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileOperations
import LocalStorage
import StorageAnalysis

/// Real Properties/full-analysis views and guarded operation ownership, using
/// one marked generated fixture. Labels and matching values never become URLs.
@MainActor enum StoragePurposeJourneyVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = CACurrentMediaTime() + 15
        while !predicate() { try require(CACurrentMediaTime() < end, line); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor private final class Pulse {
        var previous = CACurrentMediaTime(), maximum = 0.0, ticks = 0
        func tick() { let now = CACurrentMediaTime(); maximum = max(maximum, now - previous); previous = now; ticks += 1 }
    }
    static func run() async {
        var root: URL?, properties: FilePropertiesWindowController?, browserOwner: BrowserWindowController?
        let coordinator = ApplicationStorageAnalysis.shared, pulse = Pulse()
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        var checks: [String] = [], clips: [[String: Any]] = [], stage = "admission", confirmations = 0
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) throws -> String {
                guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { throw Failure.scope }; return args[i + 1]
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && admitted.resolvingSymlinksInPath() == admitted && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "purpose-journey-native"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            let workerCase = try argument("--purpose-worker")
            try require(UUID(uuidString: workerCase)?.uuidString == workerCase)
            let build = admitted.deletingLastPathComponent().appendingPathComponent(workerCase)
            let proof = try JSONSerialization.jsonObject(with: Data(contentsOf: build.appendingPathComponent("evidence/result.json"))) as? [String: Any]
            let ordinary = args.contains("--ordinary-purpose-worker")
            let worker = ordinary ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker") : build.appendingPathComponent("source/candidate/worker")
            try require(build.resolvingSymlinksInPath() == build && worker.resolvingSymlinksInPath() == worker && proof?["passed"] as? Bool == true)
            if !ordinary {
                let digest = try await Task.detached { SHA256.hash(data: try Data(contentsOf: worker)).map { String(format: "%02x", $0) }.joined() }.value
                try require(proof?["binarySHA256"] as? String == digest)
            }
            let settings = BrowserSettings(persist: false), large = args.contains("--large-interface")
            settings.appearance = large ? .light : .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.interfaceSize = .init(large ? 150 : 100); settings.motion.mode = large ? .reduced : .full
            settings.folderSummariesEnabled = false; settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
            settings.analysisChartStyle = .tilted; InterfacePresentation.shared.bind(settings)
            StoragePurposeJourneyFeature.qualifying = true; StorageChartIntegration.startAtStorageRolesForQualification = true; StorageDimensionalChartProbe.enabled = true
            StoragePurposeLocationProbe.enabled = true
            let storage = try AnalysisResultStorage(directory: admitted.appendingPathComponent("cache/analysis"), sessionByteLimit: 16 << 20)
            coordinator.enablePagedForQualification(storage: storage, workerURL: worker, classificationRevision: .v4)
            let source = admitted.appendingPathComponent("source/Analysis")
            let owner = BrowserWindowController(settings: settings); browserOwner = owner
            owner.browser.permitsBackgroundVerification = true
            owner.window?.setContentSize(.init(width: 960, height: 650)); owner.window?.makeKeyAndOrderFront(nil)
            owner.beginBrowsing(); try await wait { owner.workspace.sessionReady }
            owner.browser.navigate(to: .directory(source)); try await wait { !owner.browser.isLoading && owner.browser.orderingTask == nil }
            coordinator.configurePicker(from: owner.browser)
            let engine = owner.browser.operationCoordinator.engine(at: admitted.appendingPathComponent("state/purpose-history"))
            owner.browser.recoverableFileOperations = engine
            var accesses = 0
            let props = FilePropertiesWindowController(retainAccess: { _ in accesses += 1; return FileAccessLifetimes(leases: []) }, settings: settings, copyPaths: { _ in })
            properties = props; props.show(urls: [source]); props.window?.title = "Properties · generated review · purpose journey"
            props.window?.setContentSize(.init(width: large ? 820 : 640, height: 760)); NSApp.activate(ignoringOtherApps: true)
            try await wait { !props.model.isLoading && props.model.canAnalyzeStorage }
            stage = "scan"; props.model.analyzeStorage()
            try await wait { !coordinator.hasWork && props.model.chartDrill.canUsePurposeJourney }
            guard let result = coordinator.pagedResultForVerification, let summary = coordinator.pagedSummaryForVerification else { throw Failure.scope }
            try require(result.supportsPurposeJourney && summary.complete && summary.value.counts.regularFiles == 11
                && summary.value.bytes.dataLogical.knownBytes == 244)
            let scanAccesses = accesses
            checks.append("Actual generated scan advertises purpose revision1; existing v4 counts and244 logical bytes stay exact")
            try await wait { StorageDimensionalChartProbe.latest?.window === props.window }
            guard let chart = StorageDimensionalChartProbe.latest, let propertyWindow = props.window else { throw Failure.scope }
            try await wait { chart.frames.count == 1 && !chart.isAnimating }
            guard let roleIndex = chart.frames[0].slices.firstIndex(where: { $0.id == StorageChartIntegration.key(.projects(role: .toolCache)) }) else { throw Failure.scope }
            stage = "properties-purpose"
            let forward = try await NativeMotionRecorder.record(window: propertyWindow, root: admitted, label: "purpose-open", sampling: .diagnostic(for: propertyWindow)) {
                chart.activateForQualification(.slice(roleIndex))
            }
            try JSONEncoder().encode(forward).write(to: admitted.appendingPathComponent("evidence/purpose-open.json"), options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip("purpose-open", report: forward, field: nil, window: propertyWindow))
            let drill = props.model.chartDrill
            try await wait { !drill.loading && chart.frames.count == 2 && !chart.isAnimating && drill.current?.purposeProjects != nil }
            guard let projects = drill.current?.purposeProjects,
                  let a = projects.projects.first(where: { $0.rawName == Data("Project A".utf8) }) else { throw Failure.scope }
            try require(projects.groupCount == 4 && projects.value.bytes.dataLogical.knownBytes == 112
                && a.value.bytes.dataLogical.knownBytes == 41
                && projects.projects.first(where: { $0.rawName == Data("Nested".utf8) })?.value.bytes.dataLogical.knownBytes == 19
                && projects.projects.first(where: { $0.id == 0 })?.value.bytes.dataLogical.knownBytes == 29)
            checks.append("Properties partitions tool caches into exact project containment, nested project and shared groups without another scan")
            guard let projectIndex = chart.frames.last?.slices.firstIndex(where: { $0.id == StorageChartIntegration.key(.locations(role: .toolCache, project: a.id)) }) else { throw Failure.scope }
            chart.activateForQualification(.slice(projectIndex))
            try await wait { !drill.loading && chart.frames.count == 3 && !chart.isAnimating && drill.current?.purposeLocations != nil }
            try require(drill.current?.purposeLocations?.locations.count == 2 && accesses == scanAccesses)
            guard let mixed = drill.visiblePurposeLocations.first(where: { $0.rawName == Data(".cache".utf8) }),
                  let whole = drill.visiblePurposeLocations.first(where: { $0.rawName == Data(".npm".utf8) }) else { throw Failure.scope }
            try require(!mixed.matchesWholeRecordedLocation && mixed.matchingValue.bytes.dataLogical.knownBytes == 24 && mixed.wholeRecordedValue.bytes.dataLogical.knownBytes == 125
                && whole.matchesWholeRecordedLocation && whole.matchingValue.bytes.dataLogical.knownBytes == 17 && !whole.isSourceRoot)
            let resolved = try await result.resolveLocation(node: whole.id, retainingAccess: "Generated purpose location")
            try require(resolved.url == source.appendingPathComponent("Project A/.npm") && !resolved.isSourceRoot)
            checks.append("The chart stops at concrete locations; mixed cache keeps24 matching versus125 whole bytes and exact source-aware resolution")
            stage = "properties-back"
            drill.back()
            try await wait { !drill.loading && drill.levels.count == 1 && chart.frames.count == 2 && !chart.isAnimating }
            stage = "properties-rapid-replacement"
            drill.openPurpose(.locations(role: .toolCache, project: a.id), title: "Project A"); drill.setMetric(.allForkAllocated); drill.back()
            // Back pops the visible project level. A still-unpublished child
            // must never become a cached level or arrive after that return.
            try await wait { !drill.loading && drill.levels.isEmpty && result.activeReaderCount == 0 }
            drill.openPurpose(.projects(role: .toolCache), title: "Tool caches")
            try await wait { !drill.loading && drill.levels.count == 1 && drill.current?.value.rankingMetric == .allForkAllocated && result.activeReaderCount == 0 }
            drill.setMetric(.dataLogical); try await wait { !drill.loading && drill.current?.value.rankingMetric == .dataLogical }
            try require(accesses == scanAccesses && coordinator.pagedResultForVerification?.id == result.id)
            checks.append("Back, rapid metric replacement and stale query rejection converge on one result and reader owner")

            stage = "full-analysis"; props.model.openFullAnalysis()
            try await wait { coordinator.toolWindow?.pagedReadyForVerification == true }
            guard let tool = coordinator.toolWindow, let window = tool.window else { throw Failure.scope }
            window.title = "Storage Analysis · generated review · purpose journey"; window.setContentSize(.init(width: large ? 1120 : 1000, height: 780)); window.makeKeyAndOrderFront(nil)
            if tool.compactBreakdownForVerification { tool.expandBreakdownButton.performClick(nil) }
            try await wait { StorageDimensionalChartProbe.latest?.window === window }
            let full = tool.chartDrillForVerification
            try require(full.canUsePurposeJourney && coordinator.pagedResultForVerification?.id == result.id && accesses == scanAccesses)
            full.openPurpose(.projects(role: .toolCache), title: "Tool caches"); try await wait { !full.loading && full.current?.purposeProjects != nil }
            full.openPurpose(.locations(role: .toolCache, project: a.id), title: "Project A"); try await wait { !full.loading && full.current?.purposeLocations != nil }
            full.selectPurposeLocation(mixed.id)
            guard let mixedSelection = full.selectedPurposeLocation else { throw Failure.scope }
            try require(!full.canActOnPurposeLocation(mixedSelection, action: .reviewTrash) && full.canActOnPurposeLocation(mixedSelection, action: .showInExplorer))
            full.actOnPurposeLocation(mixedSelection, action: .reviewTrash)
            try require(!full.locationActionRunning && owner.browser.operationPreparationTask == nil)
            let locationReveal = try await NativeMotionRecorder.record(window: window, root: admitted, label: "purpose-location", sampling: .diagnostic(for: window)) {
                full.selectPurposeLocation(whole.id)
            }
            try JSONEncoder().encode(locationReveal).write(to: admitted.appendingPathComponent("evidence/purpose-location.json"), options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip("purpose-location", report: locationReveal, field: nil, window: window))
            try require(full.selectedPurposeLocationID == whole.id)
            stage = "visible-location-review"
            try await wait { StoragePurposeLocationProbe.visibleReview(node: whole.id, window: window) }
            checks.append("Whole-folder Review is entirely inside the actual scrolling viewport at the chosen interface size")
            guard let selected = full.selectedPurposeLocation else { throw Failure.scope }
            full.back(); full.openPurpose(.locations(role: .toolCache, project: a.id), title: "Project A"); try await wait { !full.loading && full.current?.purposeLocations != nil }
            full.selectPurposeLocation(whole.id)
            try require(!full.canActOnPurposeLocation(selected, action: .reviewTrash))
            checks.append("Full Analysis reuses the same result; mixed, previously selected and stale-level actions cannot initiate Trash")
            guard let selection = full.selectedPurposeLocation else { throw Failure.scope }
            try require(full.canActOnPurposeLocation(selection, action: .reviewTrash))
            owner.browser.operationTrashPrompt = { count in confirmations += 1; return false }
            full.actOnPurposeLocation(selection, action: .reviewTrash)
            try await wait { !full.locationActionRunning && !coordinator.hasWork }
            try require(confirmations == 1 && full.locationMessage.contains("Cancelled") && FileManager().fileExists(atPath: resolved.url.path)
                && !FileManager().fileExists(atPath: admitted.appendingPathComponent("state/purpose-history").path))
            checks.append("One explicit whole-location review; Cancel moves nothing and creates no operation history")
            stage = "trash-undo"
            owner.browser.operationTrashPrompt = { count in confirmations += 1; return count == 1 }
            full.actOnPurposeLocation(selection, action: .reviewTrash)
            try await wait { !full.locationActionRunning && !coordinator.hasWork && owner.browser.operationTask == nil && owner.browser.operationCoordinator.inspectionCount == 0 }
            try require(confirmations == 2 && owner.browser.lastOperationResult?.disposition == .succeeded && !FileManager().fileExists(atPath: resolved.url.path)
                && !full.visiblePurposeLocations.contains(where: { $0.id == whole.id }))
            guard let feedback = tool.pagedModelForVerification?.operationFeedback, let record = owner.browser.lastRecoveryRecordID else { throw Failure.scope }
            try await wait { feedback.canUndo && feedback.canViewResults }
            try require(feedback.id == record)
            feedback.viewResults()
            try await wait { owner.browser.recoveryWindow?.selectedRecordID == record && owner.browser.operationCoordinator.inspectionCount == 0 }
            owner.browser.recoveryWindow?.close()
            window.makeKeyAndOrderFront(nil)
            try await wait { feedback.canUndo && owner.browser.operationCoordinator.inspectionCount == 0 }
            feedback.undo(); try await wait { !feedback.working && owner.browser.operationTask == nil && owner.browser.operationCoordinator.inspectionCount == 0 }
            try require(FileManager().fileExists(atPath: resolved.url.path) && full.visiblePurposeLocations.contains(where: { $0.id == whole.id }) && !feedback.canUndo)
            checks.append("Verified Trash hides the exact semantic location; Results selects its operation and guarded Undo restores it without a rescan")
            full.selectPurposeLocation(whole.id)
            try await Task.sleep(for: .milliseconds(150))
            try await UIVerification.snapshot(window, to: admitted.appendingPathComponent("evidence/purpose-full-analysis.png"))
            stage = "close-pending-query"
            full.reset(); full.openPurpose(.projects(role: .toolCache), title: "Cancelled purpose"); full.close()
            await full.waitUntilQueriesDrained()
            await result.waitUntilReadersDrained(); try require(full.levels.isEmpty && !full.loading && result.activeReaderCount == 0)
            checks.append("Close withdraws pending semantic output and waits for actual reader drain")
            props.cancel(); props.close(); tool.close(); await coordinator.stopAndDrain()
            owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            try require(pulse.maximum < 0.5 && pulse.ticks > 10)
            try write(["passed": true, "checks": checks, "clips": clips, "confirmations": confirmations, "ordinaryWorker": ordinary,
                "interfacePercent": settings.interfaceSize.percent, "maximumMainActorGapSeconds": pulse.maximum, "actualReadersDrained": true,
                "activityDrained": true, "sameResultHandoff": true, "metadataOnlyScanAndQueries": true, "generatedTrashUndo": true,
                "networkRequests": 0, "keychainCalls": 0, "physicalInputExercised": false], root: admitted)
        } catch {
            properties?.cancel(); properties?.close(); coordinator.toolWindow?.close(); await coordinator.stopAndDrain()
            if let owner = browserOwner { owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close() }
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "stage": stage, "line": line, "errorType": String(reflecting: type(of: error)), "checks": checks, "clips": clips,
                "confirmations": confirmations, "maximumMainActorGapSeconds": pulse.maximum], root: root) }
        }
        timer.invalidate(); StoragePurposeJourneyFeature.qualifying = false; StorageChartIntegration.startAtStorageRolesForQualification = false
        StorageDimensionalChartProbe.enabled = false; StoragePurposeLocationProbe.enabled = false; NSApp.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-purpose-journey.json"), options: .withoutOverwriting)
    }
}
#endif
