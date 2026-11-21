import Foundation
import LocalStorage

/// Session-only comparison of like workloads. This projects existing results;
/// it cannot run a workload, inspect a device, or infer a drive health score.
struct DriveBenchmarkComparison {
    struct Phase {
        let selectedRate: Double?, referenceRate: Double?
        let selectedSecondaryRate: Double?, referenceSecondaryRate: Double?
        let selectedP95: Double, referenceP95: Double

        var rateChangePercent: Double? {
            guard let selectedRate, let referenceRate, referenceRate > 0 else { return nil }
            let change = (selectedRate / referenceRate - 1) * 100
            return change.isFinite ? change : nil
        }
    }
    let selected: DriveBenchmarkRun, reference: DriveBenchmarkRun
    let write: Phase, read: Phase
    let metric: DriveBenchmarkMetric
    var isSameVolume: Bool { selected.fileSystemID == reference.fileSystemID }

    var copySummary: String { "Traverse file benchmark comparison\n\n" + summaryDetails }

    fileprivate var summaryDetails: String {
        let random = selected.result.workload == .random4K
        let workload = random ? "Random 4 KiB" : "Sequential"
        let count = FileSizeText.string(selected.result.bytesWritten)
        return [
            "\(workload) · \(count)",
            "Phase\tSelected (\(metric.unit))\tReference (\(metric.unit))\tSelected P95 (ms)\tReference P95 (ms)",
            row("Write and flush", phase: write),
            row("Read and verify", phase: read)
        ].joined(separator: "\n")
    }

    private func row(_ label: String, phase: Phase) -> String {
        [label, number(phase.selectedRate, decimals: 1), number(phase.referenceRate, decimals: 1),
         number(phase.selectedP95, decimals: 3), number(phase.referenceP95, decimals: 3)].joined(separator: "\t")
    }

    private func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(decimals)))
    }

    init?(selected: DriveBenchmarkRun, reference: DriveBenchmarkRun, acrossVolumes: Bool = false) {
        let current = selected.result, prior = reference.result
        guard selected.id != reference.id, acrossVolumes || selected.fileSystemID == reference.fileSystemID,
              current.outcome == .completed, prior.outcome == .completed,
              current.workload == prior.workload, current.blockBytes == prior.blockBytes,
              current.bytesWritten > 0, current.bytesRead > 0,
              current.bytesWritten == prior.bytesWritten, current.bytesRead == prior.bytesRead,
              current.preparationBytesWritten == prior.preparationBytesWritten,
              current.cacheMode == prior.cacheMode,
              current.cacheBypass == prior.cacheBypass, current.flush == prior.flush else { return nil }
        self.selected = selected; self.reference = reference
        let primary = current.workload.primaryMetric
        metric = primary
        write = Self.phase(current, prior, metric: primary, writing: true)
        read = Self.phase(current, prior, metric: primary, writing: false)
    }

    private static func phase(_ selected: DriveBenchmarkResult, _ reference: DriveBenchmarkResult,
                              metric: DriveBenchmarkMetric, writing: Bool) -> Phase {
        .init(selectedRate: metric.completedRate(selected, writing: writing),
              referenceRate: metric.completedRate(reference, writing: writing),
              selectedSecondaryRate: metric.alternate.completedRate(selected, writing: writing),
              referenceSecondaryRate: metric.alternate.completedRate(reference, writing: writing),
              selectedP95: (writing ? selected.writeLatency : selected.readLatency).p95Milliseconds,
              referenceP95: (writing ? reference.writeLatency : reference.readLatency).p95Milliseconds)
    }
}

/// A read-only projection of two complete Quick Mix pairs. Each stage must
/// independently satisfy the same exact-match comparison as an individual
/// run; there is no aggregate rate or cross-workload comparison.
struct DriveBenchmarkSuiteComparison {
    let selected: DriveBenchmarkSuite
    let reference: DriveBenchmarkSuite
    let sequential: DriveBenchmarkComparison
    let random4K: DriveBenchmarkComparison

    var copySummary: String {
        ["Traverse Quick Mix file benchmark comparison", sequential.summaryDetails, random4K.summaryDetails]
            .joined(separator: "\n\n")
    }

    init?(selected: DriveBenchmarkSuite, reference: DriveBenchmarkSuite, acrossVolumes: Bool = false) {
        guard let selectedID = selected.sequential.suiteID,
              let referenceID = reference.sequential.suiteID,
              selectedID != referenceID,
              let selectedRandom = selected.random4K, let referenceRandom = reference.random4K,
              selectedRandom.suiteID == selectedID, referenceRandom.suiteID == referenceID,
              selected.sequential.fileSystemID == selectedRandom.fileSystemID,
              reference.sequential.fileSystemID == referenceRandom.fileSystemID,
              selected.sequential.result.workload == .sequential,
              reference.sequential.result.workload == .sequential,
              selectedRandom.result.workload == .random4K,
              referenceRandom.result.workload == .random4K,
              let sequential = DriveBenchmarkComparison(selected: selected.sequential, reference: reference.sequential, acrossVolumes: acrossVolumes),
              let random4K = DriveBenchmarkComparison(selected: selectedRandom, reference: referenceRandom, acrossVolumes: acrossVolumes) else { return nil }
        self.selected = selected
        self.reference = reference
        self.sequential = sequential
        self.random4K = random4K
    }
}
