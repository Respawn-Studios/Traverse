#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import StorageAnalysis
import SwiftUI

@MainActor
private final class PrefixCard: ObservableObject {
    @Published var prefix: CommittedAnalysisPrefix?
    @Published var state = "Preparing sample scan…"
}
private struct PrefixCardView: View {
    @ObservedObject var model: PrefixCard
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.state).font(.headline)
            if let prefix = model.prefix {
                Text("\(prefix.entries.formatted()) entries observed").monospacedDigit()
                HStack(spacing: 24) {
                    StorageRingChart(items: prefix.classificationRevision.fileTypes.compactMap { type in
                        let value = prefix.fileTypes[type.rawValue]
                        guard value.counts.regularFiles > 0 else { return nil }
                        return StorageRingItem(title: type.title, amount: "\((value.bytes.dataLogical.knownBytes ?? 0).formatted()) bytes observed",
                            bytes: value.bytes.dataLogical.overflowed ? nil : value.bytes.dataLogical.knownBytes,
                            canOpen: false, color: .blue)
                    }).frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("File Types").font(.headline)
                        ForEach(prefix.classificationRevision.fileTypes.filter { prefix.fileTypes[$0.rawValue].counts.regularFiles > 0 }, id: \.rawValue) { type in
                            Text(type.title)
                            Text("\(prefix.fileTypes[type.rawValue].counts.regularFiles.formatted()) files").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Observed so far · percentages describe observed bytes, not scan completion. Final breakdowns become available after the scan finishes.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
enum StoragePrefixVerification {
    static func auditFixture(root: URL) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let gate = FileActivityGate()
        let worker = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-classification-v3-audit/worker")
        let scanner = StorageScanner(workerURL: worker, activityGate: gate)
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let session = try scanner.startPagedClassificationForQualification(root: root, storage: storage, retainingAccess: "Retained generated Steam fixture")
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates { if update.workerDrained { terminal = update } }
        await session.waitUntilDrained()
        guard let result = terminal?.result else { throw UIVerification.Failure(message: "No generated audit result") }
        let summary = try await result.summary(), audit = try await result.classificationAuditForQualification()
        await result.waitUntilReadersDrained()
        try UIVerification.require(summary.value.counts.regularFiles == 2 && summary.value.bytes.dataLogical.knownBytes == 70
            && audit.total.bytes == summary.value.bytes && audit.total.counts.regularFiles == 2
            && audit.changed.counts.regularFiles == 0 && result.activeReaderCount == 0 && gate.activeCount == 0,
            "Native generated audit changed totals, metadata storage or reader lifetime")
        return ["passed": true, "regular_files": 2, "logical_bytes": 70, "source_rescan_for_audit": false,
            "database_hash_unchanged": true, "gate_active": gate.activeCount, "retained_generated_store": true]
    }
    private static func checkedSum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { sum, value in
            let (next, overflow) = sum.addingReportingOverflow(value)
            guard !overflow else { throw UIVerification.Failure(message: "Classification subtotal overflow") }
            return next
        }
    }
    static func ordinaryCompatibility(root: URL, storage: AnalysisResultStorage) async throws -> [String] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let ordinary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
        let legacy = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-app-data/worker")
        let priorPrefix = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-live-totals/worker")
        for (worker, oldConsumer) in [(legacy, false), (priorPrefix, false), (ordinary, true)] {
            let scanner = StorageScanner(workerURL: worker, activityGate: ApplicationFileActivity.gate)
            let session = try oldConsumer
                ? scanner.startPagedWithPrefixesForQualification(root: root, storage: storage, retainingAccess: "Generated compatibility control")
                : scanner.startPaged(root: root, storage: storage, retainingAccess: "Generated compatibility control")
            var terminal: PagedStorageScanUpdate?
            for await update in session.updates { if update.workerDrained { terminal = update } }
            await session.waitUntilDrained()
            try UIVerification.require(terminal?.status == .failed(.invalidOutput) && terminal?.result == nil
                && terminal?.provisionalFileTypes == nil && ApplicationFileActivity.gate.activeCount == 0,
                "Ordinary helper/consumer silently accepted an incompatible checkpoint contract")
        }
        return ["ordinary rejects legacy helper", "ordinary rejects old prefix helper", "old consumer refuses promoted helper"]
    }
    static func run() async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        let candidate = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-live-totals/worker")
        let ordinary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
        let gate = FileActivityGate()
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let model = PrefixCard()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 680, height: 410), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Progressive storage · generated sample"
        window.contentView = NSHostingView(rootView: PrefixCardView(model: model))
        defer { window.contentView = nil; window.close() }
        var reports: [[String: Any]] = [], capture: String?
        let largerCheckpoint = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-checkpoint4096/worker")
        for (worker, rows) in [(candidate, UInt64(1024)), (largerCheckpoint, UInt64(4096))] {
        for stop in [false, true] {
            let scanner = StorageScanner(workerURL: worker, activityGate: gate)
            let began = ProcessInfo.processInfo.systemUptime
            let session = try scanner.startPagedWithPrefixesForQualification(root: root, storage: storage, retainingAccess: "Generated prefix qualification", checkpointRows: rows)
            var seen = 0, sequence: UInt64?, first: TimeInterval?, cancelAt: TimeInterval?, final: PagedStorageScanUpdate?
            for await update in session.updates {
                if let prefix = update.provisionalFileTypes, prefix.sequence != sequence {
                    try UIVerification.require(update.result == nil && !update.workerDrained && prefix.entries <= update.committedEntries,
                        "Unsealed prefix was presented as a final result")
                    sequence = prefix.sequence; seen += 1
                    if first == nil { first = ProcessInfo.processInfo.systemUptime - began }
                    model.prefix = prefix; model.state = "Scanning · observed so far"
                    if !stop && capture == nil {
                        let url = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/prefix-native-" + UUID().uuidString + ".png")
                        try await UIVerification.snapshot(window, to: url); capture = url.lastPathComponent
                    }
                    if stop && cancelAt == nil { cancelAt = ProcessInfo.processInfo.systemUptime; session.cancel() }
                }
                if update.workerDrained { final = update }
            }
            await session.waitUntilDrained()
            guard let final, let result = final.result, let first else { throw UIVerification.Failure(message: "No native prefix/final result") }
            try UIVerification.require(final.provisionalFileTypes == nil && final.status == (stop ? .cancelled : .completed)
                && seen >= (stop ? 1 : 2), "Final result retained provisional presentation or lost prefix updates")
            model.prefix = nil; model.state = stop ? "Stopped · committed observations retained" : "Scan finished · final details available"
            let summary = try await result.summary()
            try UIVerification.require(summary.value.counts.total == final.committedEntries && (!stop || !summary.complete),
                "Final prefix/count or Stop state disagreed")
            let stopSeconds = cancelAt.map { ProcessInfo.processInfo.systemUptime - $0 }
            try UIVerification.require(stopSeconds == nil || stopSeconds! < 2, "Native Stop did not drain promptly")
            await result.waitUntilReadersDrained()
            reports.append(["checkpoint_rows": rows, "stopped": stop, "prefix_updates_seen": seen, "first_presented_seconds": first,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began, "stop_seconds": stopSeconds as Any? ?? NSNull(),
                "final_entries": final.committedEntries])
        }
        }
        // Matching capability is explicit. Neither ordinary routing nor a
        // stale helper may accept a stream with a different progress contract.
        let legacy = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-app-data/worker")
        let mismatches: [(URL, Bool, UInt64)] = [(legacy, false, 4096), (candidate, false, 4096), (ordinary, true, 1024), (largerCheckpoint, true, 1024), (candidate, true, 4096)]
        for (worker, qualified, rows) in mismatches {
            let scanner = StorageScanner(workerURL: worker, activityGate: gate)
            let session = try qualified
                ? scanner.startPagedWithPrefixesForQualification(root: root, storage: storage, retainingAccess: "Generated mismatch control", checkpointRows: rows)
                : scanner.startPaged(root: root, storage: storage, retainingAccess: "Generated mismatch control")
            var terminal: PagedStorageScanUpdate?
            for await update in session.updates { if update.workerDrained { terminal = update } }
            await session.waitUntilDrained()
            try UIVerification.require(terminal?.status == .failed(.invalidOutput) && terminal?.result == nil
                && terminal?.provisionalFileTypes == nil, "Mismatched progress capability silently routed")
        }
        try UIVerification.require(gate.activeCount == 0 && model.prefix == nil, "Prefix qualification retained I/O or a final provisional chart")
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        let peak = UInt64(max(0, usage.ru_maxrss))
        try UIVerification.require(peak <= 256 << 20, "Native prefix model exceeded memory gate")
        return ["passed": true, "scope": "Existing generated wide corpus only; experimental worker and Debug entry point",
            "cases": reports, "capture": capture as Any? ?? NSNull(), "parent_peak_bytes": peak,
            "checks": ["native provisional chart", "final clears provisional totals", "Stop/actual drain", "capability and checkpoint mismatch refusals", "single latest prefix model"]]
    }

    /// Explicit read-only internal qualification. Uses positive native discovery;
    /// generated same-volume pairs never substitute for real member identities.
    static func startup(checkpointRows: UInt64 = 1024, profiling: Bool = false,
                        classificationRevision: AnalysisClassificationRevision = .v2, audit: Bool = false,
                        layoutExplanations: Bool = false, applicationLayouts: Bool = false) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        try UIVerification.require([1024, 4096].contains(checkpointRows), "Unqualified checkpoint size")
        try UIVerification.require(!profiling || checkpointRows == 4096, "Profiling requires the current checkpoint contract")
        try UIVerification.require(classificationRevision != .v3 || checkpointRows == 4096, "Revision3 requires its qualified current checkpoint helper")
        try UIVerification.require(!audit || !profiling, "Audit and timing require separate qualification")
        try UIVerification.require(!audit || classificationRevision == .v3, "Numeric audit requires the isolated revision3 helper")
        try UIVerification.require(!layoutExplanations || classificationRevision == .v3 && !profiling && !audit, "Layout explanations require their separate v3 helper")
        try UIVerification.require(!applicationLayouts || classificationRevision == .v3 && !profiling && !audit, "Application Layouts require their explicit v3 helper")
        let lane = applicationLayouts ? "application-layouts" : layoutExplanations ? "classification-v3-layouts" : audit ? "classification-v3-audit" : classificationRevision == .v3 ? (profiling ? "classification-v3-profile" : "classification-v3") : profiling ? "checkpoint4096-profile" : checkpointRows == 1024 ? "live-totals" : "checkpoint4096"
        let candidate = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-" + lane + "/worker")
        let began = ProcessInfo.processInfo.systemUptime
        let gate = FileActivityGate(), discovery = StartupVolumeDiscovery(activityGate: gate)
        let plan = try await discovery.discover()
        let storage = try await UIVerification.isolatedAnalysisStorage()
        let model = PrefixCard()
        var ownedID: UUID?
        func observe() async throws -> [String: Any] {
            let scanner = StorageScanner(workerURL: candidate, activityGate: gate)
            let scanBegan = ProcessInfo.processInfo.systemUptime
            let session = try scanner.startStartupWithPrefixesForQualification(plan: plan, discovery: discovery,
                storage: storage, retainingAccess: "Explicit Standard internal progressive qualification", checkpointRows: checkpointRows,
                classificationRevision: classificationRevision)
            let deadline = Task { try await Task.sleep(for: .seconds(180)); session.cancel() }
            defer { deadline.cancel() }
            var terminal: PagedStorageScanUpdate?, first: TimeInterval?, sequence: UInt64?, updates = 0, lastCount: UInt64 = 0
            for await update in session.updates {
                if let prefix = update.provisionalFileTypes, prefix.sequence != sequence {
                    try UIVerification.require(update.isStartupPair && prefix.entries > lastCount && update.result == nil,
                        "Startup prefix reset, lost provenance or exposed an unsealed result")
                    try UIVerification.require(prefix.classificationRevision == classificationRevision
                        && prefix.fileTypes.count == classificationRevision.fileTypes.count, "Startup prefix classification provenance changed")
                    sequence = prefix.sequence; lastCount = prefix.entries; updates += 1
                    if first == nil { first = ProcessInfo.processInfo.systemUptime - scanBegan }
                    model.prefix = prefix; model.state = "Scanning · observed so far"
                }
                if update.workerDrained { terminal = update }
            }
            await session.waitUntilDrained()
            let sealedSeconds = ProcessInfo.processInfo.systemUptime - scanBegan
            guard let terminal, let result = terminal.result, let first else {
                throw UIVerification.Failure(message: "No sealed internal progressive result: " + String(describing: terminal?.status))
            }
            model.prefix = nil
            let summary = try await result.summary()
            let roots = try await result.page()
            try UIVerification.require(summary.sources.count == 2 && summary.sources.allSatisfy(\.traversalFinished)
                && roots.map(\.id) == [1, 2] && summary.value.counts.total == terminal.committedEntries
                && terminal.provisionalFileTypes == nil && lastCount > summary.sources[0].value.counts.total
                && updates >= 2 && plan.isTopologyUnchanged, "Internal progressive handoff or final source reconciliation failed")
            var diagnosis: [String: Any] = [:]
            diagnosis["coverage_reason_counts"] = Dictionary(uniqueKeysWithValues: AnalysisScanCoverageReason.allCases.map { (String(describing: $0), terminal.coverage[$0]) })
            diagnosis["all_notice_reasons_categorized"] = terminal.coverage.reasonCountsAreComplete
            if classificationRevision == .v3 {
                try UIVerification.require(result.classificationRevision == .v3 && summary.classificationReady, "Startup result lost revision3 provenance")
                let facets = try await [result.groups(.fileTypes), result.groups(.storageRoles), result.groups(.projects)]
                for groups in facets {
                    let values = groups.groups.map(\.value) + [groups.remainder]
                    try UIVerification.require(checkedSum(values.map { $0.counts.regularFiles }) == summary.value.counts.regularFiles,
                        "Startup classification did not partition observed files")
                    for metric in AnalysisByteMetric.allCases {
                        let expected = summary.value.bytes[metric]
                        let parts = values.map { $0.bytes[metric] }
                        let known = try checkedSum(parts.map { $0.knownBytes ?? 0 })
                        let missing = try checkedSum(parts.map(\.notReturnedCount))
                        let failed = try checkedSum(parts.map(\.failedCount))
                        try UIVerification.require(!expected.overflowed && parts.allSatisfy { !$0.overflowed }
                            && known == expected.knownBytes && missing == expected.notReturnedCount && failed == expected.failedCount,
                            "Startup classification lost an exact byte-metric partition")
                    }
                    diagnosis["facet_\(groups.facet.rawValue)_logical_bytes"] = Dictionary(uniqueKeysWithValues: groups.groups.map { (String($0.id), $0.value.bytes.dataLogical.knownBytes as Any? ?? NSNull()) })
                }
                var queryBegan = ProcessInfo.processInfo.systemUptime
                if applicationLayouts {
                    try UIVerification.require(result.supportsApplicationLayouts, "Internal layout capability missing")
                    let applications = try await result.groups(.applicationLayouts)
                    diagnosis["all_application_layout_seconds"] = ProcessInfo.processInfo.systemUptime - queryBegan
                    let parts = applications.groups.map(\.value)
                    try UIVerification.require(checkedSum(parts.map { $0.counts.regularFiles }) == summary.value.counts.regularFiles,
                        "Internal all-format layout file partition mismatch")
                    for metric in AnalysisByteMetric.allCases {
                        let wanted = summary.value.bytes[metric], values = parts.map { $0.bytes[metric] }
                        try UIVerification.require(!wanted.overflowed && values.allSatisfy { !$0.overflowed }
                            && checkedSum(values.compactMap(\.knownBytes)) == wanted.knownBytes
                            && checkedSum(values.map(\.notReturnedCount)) == wanted.notReturnedCount
                            && checkedSum(values.map(\.failedCount)) == wanted.failedCount, "Internal all-format layout metric partition mismatch")
                    }
                    diagnosis["all_application_layout_logical_bytes"] = Dictionary(uniqueKeysWithValues: applications.groups.map {
                        (String($0.id), $0.value.bytes.dataLogical.knownBytes as Any? ?? NSNull())
                    })
                    if let group = applications.groups.first(where: { $0.id != 0 }) {
                        let filterBegan = ProcessInfo.processInfo.systemUptime
                        let detail = try await result.breakdown(.filtered(folder: 0, facet: .applicationLayouts, key: group.id))
                        diagnosis["largest_application_layout_filter_seconds"] = ProcessInfo.processInfo.systemUptime - filterBegan
                        try UIVerification.require(detail.value == group.value, "Internal layout drill lost its selected subtotal")
                        diagnosis["largest_application_layout_root_count"] = detail.rows.count
                    }
                    queryBegan = ProcessInfo.processInfo.systemUptime
                }
                let other = try await result.explainOther()
                diagnosis["other_explanation_seconds"] = ProcessInfo.processInfo.systemUptime - queryBegan
                if layoutExplanations {
                    guard let layouts = other.applicationLayouts else { throw StorageScanFailure.invalidOutput }
                    diagnosis["application_layout_explanation_revision"] = 1
                    diagnosis["application_layout_logical_bytes"] = Dictionary(uniqueKeysWithValues: layouts.enumerated().map {
                        (String($0.offset), $0.element.bytes.dataLogical.knownBytes as Any? ?? NSNull())
                    })
                    try UIVerification.require(checkedSum(layouts.map { $0.counts.regularFiles }) == other.value.counts.regularFiles,
                        "Native application layouts lost the Other filter")
                }
                queryBegan = ProcessInfo.processInfo.systemUptime
                let filtered = try await result.breakdown(.filtered(folder: 0, facet: .fileTypes, key: 0))
                diagnosis["other_breakdown_seconds"] = ProcessInfo.processInfo.systemUptime - queryBegan
                try UIVerification.require(other.value == filtered.value, "Startup Other explanation changed its filter")
                if let project = facets[2].groups.first(where: { $0.id != 0 }) {
                    let report = try await result.attribution(scopeName: "Startup", summary: summary)
                    let target = StoredAnalysisDrillTarget.filtered(folder: project.id - 1, facet: .projects, key: project.id)
                    try UIVerification.require(report?.projects.contains(where: { $0.storedTarget == target }) == true,
                        "Project chart climbed from the drive instead of entering its project")
                    queryBegan = ProcessInfo.processInfo.systemUptime
                    let contents = try await result.breakdown(target)
                    diagnosis["project_breakdown_seconds"] = ProcessInfo.processInfo.systemUptime - queryBegan
                    try UIVerification.require(contents.value == project.value, "Selected project drill changed its exact subtotal")
                    diagnosis["project_drill_at_selected_root"] = true
                }
                diagnosis["same_observation_v2_comparison"] = audit
                if audit {
                    let auditBegan = ProcessInfo.processInfo.systemUptime
                    let comparison = try await result.classificationAuditForQualification()
                    try UIVerification.require(comparison.total.counts.regularFiles == summary.value.counts.regularFiles
                        && comparison.total.bytes == summary.value.bytes, "Audit differs from the same sealed result")
                    diagnosis["classification_audit_seconds_including_hashes"] = ProcessInfo.processInfo.systemUptime - auditBegan
                    diagnosis["audit_regular_files"] = comparison.total.counts.regularFiles
                    diagnosis["audit_changed_files"] = comparison.changed.counts.regularFiles
                    diagnosis["audit_database_hash_unchanged"] = true
                    diagnosis["audit_source_rescan"] = false
                    for metric in AnalysisByteMetric.allCases {
                        func amount(_ value: StoredAnalysisValue) -> Any { value.bytes[metric].knownBytes as Any? ?? NSNull() }
                        diagnosis["audit_old_\(metric.rawValue)"] = comparison.old.map(amount)
                        diagnosis["audit_new_\(metric.rawValue)"] = comparison.new.map(amount)
                        diagnosis["audit_changed_\(metric.rawValue)"] = amount(comparison.changed)
                    }
                }
            }
            if profiling {
                guard let counters = terminal.diagnostics, counters.timingsEnabled else { throw StorageScanFailure.invalidOutput }
                diagnosis["inclusive_stage_seconds"] = Dictionary(uniqueKeysWithValues: AnalysisScanDiagnostics.Stage.allCases.map { ($0.rawValue, Double(counters[$0]) / 1_000_000_000) })
                diagnosis["coverage_reason_counts"] = Dictionary(uniqueKeysWithValues: AnalysisScanCoverageReason.allCases.map { (String(describing: $0), terminal.coverage[$0]) })
                diagnosis["all_notice_reasons_categorized"] = terminal.coverage.reasonCountsAreComplete
                diagnosis["uncategorized_notices"] = terminal.coverage.uncategorizedNotices
                for (name, facet) in [("file_type_logical_bytes", StoredAnalysisFacet.fileTypes), ("storage_role_logical_bytes", .storageRoles), ("project_logical_bytes", .projects)] {
                    let groups = try await result.groups(facet)
                    diagnosis[name] = Dictionary(uniqueKeysWithValues: groups.groups.map { (String($0.id), $0.value.bytes.dataLogical.knownBytes as Any? ?? NSNull()) })
                }
            }
            await result.waitUntilReadersDrained(); ownedID = result.id
            return ["passed": true, "diagnosis": diagnosis, "checkpoint_rows": checkpointRows, "scope": "Explicit Standard internal System/Data metadata; no bodies, source mutation or ordinary activation",
                "classification_revision": classificationRevision.rawValue, "sealed_after_seconds": sealedSeconds,
                "first_prefix_after_discovery_seconds": first, "prefix_updates_seen": updates, "final_entries": terminal.committedEntries,
                "logical_bytes": summary.value.bytes.dataLogical.knownBytes as Any? ?? NSNull(),
                "phase_finished": summary.sources.map(\.traversalFinished), "source_entries": summary.sources.map { $0.value.counts.total },
                "verified_aliases": summary.verifiedAliases, "unresolved_aliases": summary.unresolvedAliases,
                "complete": summary.complete, "coverage_notices": terminal.coverage.workerNotices as Any? ?? NSNull(),
                "worker_peak_bytes": terminal.workerPeakResidentBytes as Any? ?? NSNull(),
                "scan_seconds": ProcessInfo.processInfo.systemUptime - scanBegan,
                "total_seconds": ProcessInfo.processInfo.systemUptime - began]
        }
        var report = try await observe()
        guard let ownedID else { throw UIVerification.Failure(message: "Missing original temporary session") }
        let folder = storage.directory.appendingPathComponent("session-" + ownedID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        for _ in 0..<200 {
            let exists = await Task.detached { FileManager.default.fileExists(atPath: folder.path) }.value
            if !exists { break }; try await Task.sleep(for: .milliseconds(25))
        }
        let disposed = await Task.detached { !FileManager.default.fileExists(atPath: folder.path) }.value
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        let peak = UInt64(max(0, usage.ru_maxrss))
        try UIVerification.require(disposed && gate.activeCount == 0 && model.prefix == nil && peak <= 256 << 20,
            "Internal progressive scan retained readers, store or excess memory")
        report["owned_store_disposed"] = disposed; report["gate_active"] = gate.activeCount; report["parent_peak_bytes"] = peak
        return report
    }
}
#endif
