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
                    Text(rate(.operationsPerSecond, writing: true)).monospacedDigit()
                    Text(rate(.operationsPerSecond, writing: false)).monospacedDigit()
                }
                GridRow {
                    Text("Transfer rate").help("Completed megabytes divided by the whole measured phase. Write includes the final flush.")
                    Text(rate(.megabytesPerSecond, writing: true) + " MB/s").monospacedDigit()
                    Text(rate(.megabytesPerSecond, writing: false) + " MB/s").monospacedDigit()
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
    private func rate(_ metric: DriveBenchmarkMetric, writing: Bool) -> String {
        metric.displayValue(metric.completedRate(result, writing: writing),
            fractionalDigits: metric == .megabytesPerSecond ? 1 : 0)
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
