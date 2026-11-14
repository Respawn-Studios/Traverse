#if DEBUG
import AppKit
import ExplorerCore
import StorageAnalysis

@MainActor
enum ProjectCompositionVerification {
    static func run(root: URL) async throws -> [String: Any] {
        try InterfaceSizingVerification.admit(root)
        let source = root.appendingPathComponent("source/Files")
        let offline = root.appendingPathComponent("source/Recorded source offline")
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("cache/ProjectCatalogs"),
            sessionByteLimit: 8 << 20, poolByteLimit: 8 << 20, preserveAfterClose: true)
        let gate = FileActivityGate()
        let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: gate)
        let session = try scanner.startPaged(root: source, storage: storage, retainingAccess: "Generated project composition")
        let deadline = Task { try await Task.sleep(for: .seconds(8)); session.cancel() }
        defer { deadline.cancel() }
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates { if update.workerDrained { terminal = update } }
        await session.waitUntilDrained()
        guard let result = terminal?.result else { throw UIVerification.Failure(message: "Generated project scan did not seal") }
        let summary = try await result.summary(), projects = try await result.groups(.projects)
        guard summary.complete, let outer = projects.groups.first(where: { $0.rawName == Data("Project".utf8) }),
              let nested = projects.groups.first(where: { $0.rawName == Data("Nested".utf8) }),
              let target = projects.attributionSlices(scopeName: "Generated").first(where: { $0.title == "Project" })?.storedTarget else {
            throw UIVerification.Failure(message: "Project markers or generated nested roots were not recognized")
        }
        try UIVerification.require(outer.value.bytes.dataLogical.knownBytes == 9216 && nested.value.bytes.dataLogical.knownBytes == 1024,
            "Nested project bytes were included in the outer project")
        // The following queries receive only the sealed catalog, while their
        // original source URL is unavailable. Restore even if a check fails.
        try await Task.detached { try FileManager.default.moveItem(at: source, to: offline) }.value
        var seconds: [Double] = []
        do {
            for metric in AnalysisByteMetric.allCases {
                let began = ProcessInfo.processInfo.systemUptime
                let composition = try await result.projectComposition(target, metric: metric)
                seconds.append(ProcessInfo.processInfo.systemUptime - began)
                try UIVerification.require(composition.value == outer.value && composition.fileTypes.count <= 16 && composition.storageRoles.count <= 13,
                    "Project partitions lost their exact source scope or bounds")
                try UIVerification.require(composition.storageRoles.contains { $0.id == UInt64(AnalysisCategory.dependencies.rawValue) }
                    && composition.storageRoles.contains { $0.id == UInt64(AnalysisCategory.buildOutput.rawValue) },
                    "Project composition fell back to a directory-only hierarchy")
            }
            let drill = StorageBreakdownChartModel(); drill.configure(result)
            drill.openProject(target, title: "Project")
            try await wait { !drill.loading }
            try UIVerification.require(drill.current?.composition?.value == outer.value, "Native project selection did not open composition directly")
            drill.browseRecordedProjectFolders(); try await wait { !drill.loading }
            try UIVerification.require(drill.current?.composition == nil && drill.current?.target == target
                && drill.current?.value.value == outer.value, "Explicit folder browsing lost its selected-project filter")
            drill.close(); await result.waitUntilReadersDrained()
            try UIVerification.require(result.activeReaderCount == 0 && gate.activeCount == 0,
                "Project queries retained a real reader or scan lifetime")
        } catch {
            try await Task.detached { try FileManager.default.moveItem(at: offline, to: source) }.value
            throw error
        }
        try await Task.detached { try FileManager.default.moveItem(at: offline, to: source) }.value
        return ["passed": true, "sourceUnavailableDuringQueries": true, "nestedProjectExcluded": true,
            "metricsChecked": seconds.count, "querySeconds": seconds, "nativeCompositionThenExplicitFolders": true,
            "actualReadersDrained": true, "catalogPreservedAsEvidence": true, "personalScans": 0, "bodyReads": false]
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < limit { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(predicate(), "Project chart query did not finish")
    }
}
#endif
