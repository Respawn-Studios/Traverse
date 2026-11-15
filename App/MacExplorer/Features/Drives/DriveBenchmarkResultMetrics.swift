import LocalStorage
import SwiftUI

struct DriveBenchmarkResultMetrics: View {
    let result: DriveBenchmarkResult
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Measurement").foregroundStyle(.secondary)
                    Text("Write").foregroundStyle(.secondary)
                    Text("Read & verify").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Completed operations")
                    Text(result.writeLatency.operations.formatted()).monospacedDigit()
                    Text(result.readLatency.operations.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Operations / second").help("Completed blocks divided by the whole measured phase, including validation. Write includes the final flush.")
                    Text(rate(result.writeLatency.operations, result.writeSeconds + result.flushSeconds)).monospacedDigit()
                    Text(rate(result.readLatency.operations, result.readSeconds)).monospacedDigit()
                }
                GridRow {
                    Text("Median I/O latency")
                    Text(milliseconds(result.writeLatency.medianMilliseconds, operations: result.writeLatency.operations)).monospacedDigit()
                    Text(milliseconds(result.readLatency.medianMilliseconds, operations: result.readLatency.operations)).monospacedDigit()
                }
                GridRow {
                    Text("95th percentile")
                    Text(milliseconds(result.writeLatency.p95Milliseconds, operations: result.writeLatency.operations)).monospacedDigit()
                    Text(milliseconds(result.readLatency.p95Milliseconds, operations: result.readLatency.operations)).monospacedDigit()
                }
                GridRow {
                    Text("99th percentile")
                    Text(milliseconds(result.writeLatency.p99Milliseconds, operations: result.writeLatency.operations)).monospacedDigit()
                    Text(milliseconds(result.readLatency.p99Milliseconds, operations: result.readLatency.operations)).monospacedDigit()
                }
                GridRow {
                    Text("Observed phase")
                    Text(seconds(result.writeSeconds + result.flushSeconds)).monospacedDigit()
                    Text(seconds(result.readSeconds)).monospacedDigit()
                }
            }
            DriveBenchmarkLatencyHistogram(result: result)
        }.interfaceFont(.callout)
    }
    private func rate(_ count: Int, _ elapsed: Double) -> String {
        guard result.outcome == .completed, count > 0, elapsed.isFinite, elapsed > 0 else { return "—" }
        let value = Double(count) / elapsed
        return value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
    }
    private func milliseconds(_ value: Double, operations: Int) -> String {
        guard result.outcome == .completed, operations > 0, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(3))) + " ms"
    }
    private func seconds(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(3))) + " s"
    }
}
