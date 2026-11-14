import Foundation
import LocalStorage

/// Session-only comparison of like workloads. This projects existing results;
/// it cannot run a workload, inspect a device, or infer a drive health score.
struct DriveBenchmarkComparison {
    struct Phase {
        let selectedRate: Double?, referenceRate: Double?
        let selectedIOPS: Double?, referenceIOPS: Double?
        let selectedP95: Double, referenceP95: Double

        var rateChangePercent: Double? {
            guard let selectedRate, let referenceRate, referenceRate > 0 else { return nil }
            let change = (selectedRate / referenceRate - 1) * 100
            return change.isFinite ? change : nil
        }
    }
    let selected: DriveBenchmarkRun, reference: DriveBenchmarkRun
    let write: Phase, read: Phase

    init?(selected: DriveBenchmarkRun, reference: DriveBenchmarkRun) {
        let current = selected.result, prior = reference.result
        guard selected.id != reference.id, selected.fileSystemID == reference.fileSystemID,
              current.outcome == .completed, prior.outcome == .completed,
              current.workload == prior.workload, current.blockBytes == prior.blockBytes,
              current.bytesWritten > 0, current.bytesRead > 0,
              current.bytesWritten == prior.bytesWritten, current.bytesRead == prior.bytesRead,
              current.preparationBytesWritten == prior.preparationBytesWritten,
              current.cacheBypass == prior.cacheBypass, current.flush == prior.flush else { return nil }
        self.selected = selected; self.reference = reference
        write = Self.phase(current.bytesWritten, current.writeSeconds + current.flushSeconds, current.writeLatency,
                           prior.bytesWritten, prior.writeSeconds + prior.flushSeconds, prior.writeLatency)
        read = Self.phase(current.bytesRead, current.readSeconds, current.readLatency,
                          prior.bytesRead, prior.readSeconds, prior.readLatency)
    }

    private static func phase(_ bytes: Int64, _ seconds: Double, _ latency: DriveBenchmarkLatency,
                              _ priorBytes: Int64, _ priorSeconds: Double, _ priorLatency: DriveBenchmarkLatency) -> Phase {
        .init(selectedRate: rate(Double(bytes) / 1_000_000, seconds),
              referenceRate: rate(Double(priorBytes) / 1_000_000, priorSeconds),
              selectedIOPS: rate(Double(latency.operations), seconds),
              referenceIOPS: rate(Double(priorLatency.operations), priorSeconds),
              selectedP95: latency.p95Milliseconds, referenceP95: priorLatency.p95Milliseconds)
    }
    private static func rate(_ amount: Double, _ elapsed: Double) -> Double? {
        guard amount.isFinite, amount > 0, elapsed.isFinite, elapsed > 0 else { return nil }
        let value = amount / elapsed
        return value.isFinite ? value : nil
    }
}
