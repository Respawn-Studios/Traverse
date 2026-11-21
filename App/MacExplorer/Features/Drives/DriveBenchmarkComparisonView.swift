import LocalStorage
import SwiftUI

struct DriveBenchmarkComparisonView: View {
    let comparison: DriveBenchmarkComparison
    @ObservedObject var settings: BrowserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((comparison.selected.result.workload == .random4K ? "Random 4 KiB" : "Sequential")
                 + " · " + FileSizeText.string(comparison.selected.result.bytesWritten))
                .interfaceFont(.headline)
            DriveBenchmarkComparisonSources(comparison: comparison)
            AdaptiveToolColumns(settings: settings, minimumWidth: 560) {
                phase("Write & flush", comparison.write)
            } trailing: {
                phase("Read & verify", comparison.read)
            }
            Text("Both runs used the same workload, test size and cache and flush settings. File systems, background activity and temperature can affect the result.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("benchmark-comparison")
    }
    private func phase(_ title: String, _ value: DriveBenchmarkComparison.Phase) -> some View {
        let metric = comparison.metric
        let maximum = max(value.selectedRate ?? 0, value.referenceRate ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).interfaceFont(.headline)
                Spacer(minLength: 8)
                if let change = value.rateChangePercent {
                    Text((change > 0 ? "+" : "") + change.formatted(.number.precision(.fractionLength(1))) + "% rate")
                        .interfaceFont(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Change in measured \(metric.spokenUnit) relative to the reference run.")
                }
            }
            rateBar("Selected", value.selectedRate, metric: metric, maximum: maximum, accent: true)
            rateBar("Reference", value.referenceRate, metric: metric, maximum: maximum, accent: false)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Selected")
                    Text("Reference")
                }.foregroundStyle(.secondary)
                GridRow {
                    Text(metric.alternate.unit)
                    Text(metric.alternate.displayValue(value.selectedSecondaryRate, fractionalDigits: 1))
                    Text(metric.alternate.displayValue(value.referenceSecondaryRate, fractionalDigits: 1))
                }
                GridRow {
                    Text("95% I/O · ms").help("95% of completed block I/O calls took this long or less. Lower latency is faster; phase rates include additional work.")
                    Text(number(value.selectedP95, precision: 3))
                    Text(number(value.referenceP95, precision: 3))
                }
            }.interfaceFont(.caption).monospacedDigit()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }
    private func rateBar(_ title: String, _ value: Double?, metric: DriveBenchmarkMetric, maximum: Double, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(metric.displayValue(value, fractionalDigits: 1) + " " + metric.unit).monospacedDigit()
            }.interfaceFont(.callout)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(accent ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: geometry.size.width * proportion(value, maximum: maximum))
                }
            }.frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + " " + metric.rateName.lowercased())
        .accessibilityValue(metric.accessibilityValue(value, fractionalDigits: 1))
    }
    private func proportion(_ value: Double?, maximum: Double) -> Double {
        guard let value, value.isFinite, maximum.isFinite, maximum > 0 else { return 0 }
        return min(1, max(0, value / maximum))
    }
    private func number(_ value: Double?, precision: Int) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(precision)))
    }
}

/// Four named measurements from two complete Quick Mix pairs. Sequential
/// transfers remain MB/s and random 4 KiB accesses remain operations/s.
struct DriveBenchmarkSuiteComparisonView: View {
    let comparison: DriveBenchmarkSuiteComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Mix comparison").interfaceFont(.headline)
            DriveBenchmarkComparisonSources(comparison: comparison.sequential)
            stage("Sequential · 64 MiB", comparison: comparison.sequential)
            stage("Random 4 KiB · 16 MiB", comparison: comparison.random4K)
            Text("Each stage matches the workload, test size and cache and flush settings. Compare the measured file rates and latency for each stage.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("benchmark-suite-comparison")
    }

    private func stage(_ title: String, comparison: DriveBenchmarkComparison) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).interfaceFont(.callout.bold())
            phase("Write + flush", comparison.write, metric: comparison.metric)
            Divider()
            phase("Read + verify", comparison.read, metric: comparison.metric)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    private func phase(_ title: String, _ value: DriveBenchmarkComparison.Phase, metric: DriveBenchmarkMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).interfaceFont(.callout)
                Spacer(minLength: 8)
                Text(value.rateChangePercent.map { ($0 > 0 ? "+" : "") + $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "Change unavailable")
                    .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Selected \(metric.displayValue(value.selectedRate, fractionalDigits: 1)) \(metric.unit) · Reference \(metric.displayValue(value.referenceRate, fractionalDigits: 1)) \(metric.unit)")
                .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

}

private struct DriveBenchmarkComparisonSources: View {
    let comparison: DriveBenchmarkComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comparison.isSameVolume ? "Same volume" : "Different volumes").fontWeight(.semibold)
            Text("Selected · " + comparison.selected.comparisonLabel)
            Text("Reference · " + comparison.reference.comparisonLabel)
        }.interfaceFont(.caption).foregroundStyle(.secondary)
    }
}
