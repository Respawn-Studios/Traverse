#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import StorageAnalysis
import SwiftUI

/// Admits only the retained generated wide source, then passes the same result
/// into existing native presentation. Ordinary activation uses its shipped helper.
@MainActor
enum StorageClassificationVerification {
    static func run(ordinaryHelper: Bool = false) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        let candidate = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-classification-v3/worker")
        let ordinary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
        let selected = ordinaryHelper ? ordinary : candidate
        let older = repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-checkpoint4096/worker")
        let gate = FileActivityGate()
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 64 << 20, preserveAfterClose: true)
        var reports: [[String: Any]] = []
        let expectedRevision: AnalysisClassificationRevision = ordinaryHelper ? .v4 : .v3
        for stop in [false, true] {
            let scanner = StorageScanner(workerURL: selected, activityGate: gate)
            let session = try ordinaryHelper
                ? scanner.startPaged(root: root, storage: storage, retainingAccess: "Generated ordinary classification check")
                : scanner.startPagedClassificationForQualification(root: root, storage: storage, retainingAccess: "Generated classification revision qualification")
            var terminal: PagedStorageScanUpdate?, prefixes = 0, cancellation: TimeInterval?
            for await update in session.updates {
                if let prefix = update.provisionalFileTypes {
                    prefixes += 1
                    try UIVerification.require(prefix.fileTypes.count == expectedRevision.fileTypes.count && prefix.classificationRevision == expectedRevision
                        && prefix.attributionReport().fileTypes.count == expectedRevision.fileTypes.count, "New prefix lost exact type provenance")
                    if stop && cancellation == nil { cancellation = ProcessInfo.processInfo.systemUptime; session.cancel() }
                }
                if update.workerDrained { terminal = update }
            }
            await session.waitUntilDrained()
            guard let terminal, let result = terminal.result else { throw UIVerification.Failure(message: "New classification stream failed: " + String(describing: terminal?.status)) }
            let summary = try await result.summary()
            try UIVerification.require(prefixes > 0 && result.classificationRevision == expectedRevision
                && result.metadataPolicy == .standard && summary.value.counts.total == terminal.committedEntries
                && terminal.provisionalFileTypes == nil && gate.activeCount == 0, "Classification result/prefix or actual drain mismatch")
            if stop {
                try UIVerification.require(terminal.status == .cancelled && !summary.complete
                    && ProcessInfo.processInfo.systemUptime - cancellation! < 2, "New classification Stop exceeded drain/partial contract")
            } else {
                try UIVerification.require(summary.complete && summary.classificationReady && summary.value.counts.total == 100000,
                    "Generated full result changed its independent count")
                guard let report = try await result.attribution(scopeName: "Generated", summary: summary) else { throw StorageScanFailure.invalidOutput }
                let other = try await result.explainOther()
                let filtered = try await result.breakdown(.filtered(folder: 0, facet: .fileTypes, key: 0))
                try UIVerification.require(other.value == filtered.value && other.storageRoles.count == 13 && other.namePatterns.count == 5
                    && report.fileTypes.allSatisfy { $0.files == 0 || $0.storedTarget != nil }, "Other explanation lost its type filter")
                let browser = PagedAnalysisBrowserModel(result: result, title: "Generated classification")
                defer { browser.close() }
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: PagedAnalysisBrowser(model: browser).padding())
                defer { window.contentView = nil; window.close() }
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while browser.loading && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try UIVerification.require(!browser.loading && !browser.rows.isEmpty && browser.rows.count <= 256,
                    "Native page handoff failed or accumulated the complete result")
                browser.close(); await result.waitUntilReadersDrained()
                try UIVerification.require(result.activeReaderCount == 0, "Native handoff retained a result reader")
            }
            reports.append(["stop": stop, "prefix_updates": prefixes, "committed": terminal.committedEntries,
                "stop_seconds": cancellation.map { ProcessInfo.processInfo.systemUptime - $0 } as Any? ?? NSNull()])
        }
        for (worker, newConsumer) in [(selected, false), (older, true)] {
            let scanner = StorageScanner(workerURL: worker, activityGate: gate)
            let session = try newConsumer
                ? scanner.startPagedClassificationForQualification(root: root, storage: storage, retainingAccess: "Generated old-helper refusal")
                : scanner.startPagedWithPrefixesForQualification(root: root, storage: storage, retainingAccess: "Generated old-consumer refusal", checkpointRows: 4096)
            var last: PagedStorageScanUpdate?
            for await update in session.updates { if update.workerDrained { last = update } }
            await session.waitUntilDrained()
            try UIVerification.require(last?.status == .failed(.invalidOutput) && last?.result == nil
                && last?.provisionalFileTypes == nil && gate.activeCount == 0, "Mismatching classification contract silently accepted")
        }
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        try UIVerification.require(usage.ru_maxrss <= 256 << 20 && gate.activeCount == 0, "Native classification exceeded memory or retained work")
        return ["passed": true, "cases": reports, "parent_peak_bytes": usage.ru_maxrss, "gate_active": gate.activeCount,
            "checks": ["sixteen-type native prefix", "sealed provenance", "source-free filtered Other explanation", "same-result native paging",
                "Stop and actual drain", "old/new helper-consumer refusal"], "ordinary_activation": ordinaryHelper]
    }
}
#endif
