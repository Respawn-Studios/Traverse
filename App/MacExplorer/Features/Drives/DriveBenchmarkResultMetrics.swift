import LocalStorage
import SwiftUI

struct DriveBenchmarkResultMetrics: View {
    let result: DriveBenchmarkResult
    var body: some View {
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
                Text(milliseconds(result.writeLatency.medianMilliseconds)).monospacedDigit()
                Text(milliseconds(result.readLatency.medianMilliseconds)).monospacedDigit()
            }
            GridRow {
                Text("95th percentile")
                Text(milliseconds(result.writeLatency.p95Milliseconds)).monospacedDigit()
                Text(milliseconds(result.readLatency.p95Milliseconds)).monospacedDigit()
            }
            GridRow {
                Text("99th percentile")
                Text(milliseconds(result.writeLatency.p99Milliseconds)).monospacedDigit()
                Text(milliseconds(result.readLatency.p99Milliseconds)).monospacedDigit()
            }
            GridRow {
                Text("Measured phase")
                Text(seconds(result.writeSeconds + result.flushSeconds)).monospacedDigit()
                Text(seconds(result.readSeconds)).monospacedDigit()
            }
        }.interfaceFont(.callout)
    }
    private func rate(_ count: Int, _ elapsed: Double) -> String {
        guard count > 0, elapsed > 0 else { return "—" }
        return (Double(count) / elapsed).formatted(.number.precision(.fractionLength(0)))
    }
    private func milliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3))) + " ms"
    }
    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) + " s" }
}
