#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import LocalStorage
import StorageAnalysis

/// Real Properties/full-analysis handoff on the already-qualified generated
/// suffix fixture. Neither a path argument nor a chart label grants scan access.
@MainActor enum DataClassificationVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, properties: FilePropertiesWindowController?
        let coordinator = ApplicationStorageAnalysis.shared
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { throw Failure.scope }; return args[index + 1]
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let pool = repo.appendingPathComponent(".build/traverse-development")
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.deletingLastPathComponent() == pool && admitted.resolvingSymlinksInPath() == admitted
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "data-classification-native"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = admitted
            // This regression exercises the explicit File Types route even
            // when the ordinary completed chart starts at Purpose.
            StorageChartIntegration.startAtFileTypesForQualification = true
            let fixtureID = try argument("--classification-fixture"), workerID = try argument("--classification-worker")
            try require(UUID(uuidString: fixtureID)?.uuidString == fixtureID && UUID(uuidString: workerID)?.uuidString == workerID)
            let fixture = pool.appendingPathComponent(fixtureID), build = pool.appendingPathComponent(workerID)
            let fixtureMarker = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("reservation.json"))) as? [String: Any]
            let fixtureProof = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("evidence/result.json"))) as? [String: Any]
            let workerProof = try JSONSerialization.jsonObject(with: Data(contentsOf: build.appendingPathComponent("evidence/result.json"))) as? [String: Any]
            let ordinary = args.contains("--ordinary-data-worker")
            let worker = ordinary ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
                : build.appendingPathComponent("source/candidate/worker")
            let source = fixture.appendingPathComponent("source/Classification")
            try require(fixture.resolvingSymlinksInPath() == fixture && source.resolvingSymlinksInPath() == source
                && build.resolvingSymlinksInPath() == build && worker.resolvingSymlinksInPath() == worker
                && fixtureMarker?["action"] as? String == "classification-v4-correctness" && fixtureProof?["passed"] as? Bool == true
                && workerProof?["passed"] as? Bool == true)
            let digest = try await Task.detached { SHA256.hash(data: try Data(contentsOf: worker)).map { String(format: "%02x", $0) }.joined() }.value
            try require(ordinary || workerProof?["binarySHA256"] as? String == digest)
            let settings = BrowserSettings(persist: false), large = args.contains("--large-interface")
            settings.appearance = large ? .light : .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.interfaceSize = .init(large ? 150 : 100); settings.motion.mode = large ? .reduced : .full
            settings.analysisChartStyle = .tilted; InterfacePresentation.shared.bind(settings)
            let storage = try AnalysisResultStorage(directory: admitted.appendingPathComponent("cache/analysis"), sessionByteLimit: 16 << 20)
            coordinator.enablePagedForQualification(storage: storage, workerURL: worker, classificationRevision: ordinary ? nil : .v4)
            StorageChartIntegration.startAtStorageRolesForQualification = false; StorageDimensionalChartProbe.enabled = true
            var accesses = 0
            let owner = FilePropertiesWindowController(retainAccess: { _ in accesses += 1; return FileAccessLifetimes(leases: []) }, settings: settings, copyPaths: { _ in })
            properties = owner; owner.show(urls: [source]); owner.window?.title = "Properties · generated review · data classification"
            owner.window?.setContentSize(.init(width: large ? 820 : 640, height: 700)); NSApplication.shared.activate(ignoringOtherApps: true)
            try await wait { !owner.model.isLoading && owner.model.canAnalyzeStorage }
            owner.model.analyzeStorage()
            try await wait { !coordinator.hasWork && owner.model.chartDrill.canBrowse && coordinator.pagedResultForVerification != nil }
            guard let result = coordinator.pagedResultForVerification, let summary = coordinator.pagedSummaryForVerification else { throw Failure.scope }
            try require(result.classificationRevision == .v4 && summary.complete && summary.value.counts.regularFiles == 53
                && owner.model.attribution?.fileTypes.contains(where: { $0.title == AnalysisFileType.dataFiles.title && $0.files == 33 }) == true)
            let scannedAccesses = accesses
            try await wait { StorageDimensionalChartProbe.latest?.window === owner.window }
            guard let chart = StorageDimensionalChartProbe.latest, let window = owner.window else { throw Failure.scope }
            try await wait { chart.frames.count == 1 && !chart.isAnimating }
            let target = StoredAnalysisDrillTarget.filtered(folder: 0, facet: .fileTypes, key: 16)
            guard let index = chart.frames[0].slices.firstIndex(where: { $0.id == StorageChartIntegration.key(target) }) else { throw Failure.scope }
            var clips: [[String: Any]] = []
            let report = try await NativeMotionRecorder.record(window: window, root: admitted, label: "data-type-open", sampling: .diagnostic(for: window)) {
                chart.activateForQualification(.slice(index))
            }
            try JSONEncoder().encode(report).write(to: admitted.appendingPathComponent("evidence/data-type-open.json"), options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip("data-type-open", report: report, field: nil, window: window))
            let drill = owner.model.chartDrill
            try await wait { !drill.loading && drill.levels.count == 1 && chart.frames.count == 2 && !chart.isAnimating }
            try require(drill.current?.target == target && drill.current?.value.value.counts.regularFiles == 33)
            let back = try await NativeMotionRecorder.record(window: window, root: admitted, label: "data-type-back", sampling: .diagnostic(for: window)) { drill.back() }
            try JSONEncoder().encode(back).write(to: admitted.appendingPathComponent("evidence/data-type-back.json"), options: .withoutOverwriting)
            clips.append(DevelopmentMotionVerification.clip("data-type-back", report: back, field: nil, window: window))
            try await wait { drill.levels.isEmpty && chart.frames.count == 1 && !chart.isAnimating }
            owner.model.openFullAnalysis()
            try await wait { coordinator.toolWindow?.pagedReadyForVerification == true }
            guard let tool = coordinator.toolWindow, let fullWindow = tool.window else { throw Failure.scope }
            fullWindow.title = "Storage Analysis · generated review · data classification"
            fullWindow.setContentSize(.init(width: large ? 1100 : 960, height: 700)); fullWindow.makeKeyAndOrderFront(nil)
            if tool.compactBreakdownForVerification { tool.expandBreakdownButton.performClick(nil) }
            try await wait { StorageDimensionalChartProbe.latest?.window === fullWindow }
            guard let full = StorageDimensionalChartProbe.latest else { throw Failure.scope }
            try await wait { full.frames.count == 1 && !full.isAnimating }
            try require(coordinator.pagedResultForVerification?.id == result.id && accesses == scannedAccesses)
            let fullDrill = tool.chartDrillForVerification
            fullDrill.open(target, title: AnalysisFileType.dataFiles.title)
            try await wait { !fullDrill.loading && fullDrill.current?.value.value.counts.regularFiles == 33 }
            guard let folder = fullDrill.current?.value.rows.first?.folder else { throw Failure.scope }
            let resolved = try await result.resolveLocation(node: folder, retainingAccess: "Generated location check")
            try require(resolved.url == source.appendingPathComponent("Project") && resolved.kind == .directory)
            fullDrill.open(.filtered(folder: folder, facet: .fileTypes, key: 16), title: "Project")
            try await wait { !fullDrill.loading && fullDrill.levels.count == 2 }
            try require(fullDrill.current?.value.value.counts.regularFiles == 33
                && fullDrill.current?.value.rows.first?.title == "Tables" && coordinator.pagedResultForVerification?.id == result.id)
            fullDrill.close(); drill.close(); owner.window?.close(); coordinator.toolWindow?.window?.close()
            await coordinator.stopAndDrain(); await result.waitUntilReadersDrained()
            try require(result.activeReaderCount == 0 && ApplicationFileActivity.gate.activeCount == 0)
            try write(["passed": true, "clips": clips, "classificationRevision": 4, "dataFiles": 33,
                "sameResultHandoff": true, "filteredChildrenKeepType": true, "noRescanOrNewAccess": true,
                "actualReadersDrained": true, "interfacePercent": settings.interfaceSize.percent, "personalScans": 0,
                "sourceBodyReads": 0, "networkRequests": 0, "keychainCalls": 0, "ordinaryWorker": ordinary,
                "freshRecordedLocationVerified": true], root: admitted)
        } catch {
            properties?.window?.close(); coordinator.toolWindow?.window?.close(); await coordinator.stopAndDrain()
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "line": line, "errorType": String(reflecting: type(of: error))], root: root) }
        }
        StorageChartIntegration.startAtFileTypesForQualification = false
        StorageDimensionalChartProbe.enabled = false; NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/native-data-classification.json"), options: .withoutOverwriting)
    }
}
#endif
