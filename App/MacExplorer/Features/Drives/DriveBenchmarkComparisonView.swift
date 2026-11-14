import SwiftUI

struct DriveBenchmarkComparisonView: View {
    let comparison: DriveBenchmarkComparison
    @ObservedObject var settings: BrowserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((comparison.selected.result.workload == .random4K ? "Random 4 KiB" : "Sequential")
                 + " · " + FileSizeText.string(comparison.selected.result.bytesWritten))
                .interfaceFont(.headline)
            Text("Selected: " + comparison.selected.displayTimestamp)
                .interfaceFont(.caption).foregroundStyle(.secondary)
            AdaptiveToolColumns(settings: settings, minimumWidth: 560) {
                phase("Write & flush", comparison.write)
            } trailing: {
                phase("Read & verify", comparison.read)
            }
            Text("Same volume, workload, test size and cache/flush settings. Other activity, caches and temperature can still affect the result.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("benchmark-comparison")
    }
    private func phase(_ title: String, _ value: DriveBenchmarkComparison.Phase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).interfaceFont(.headline)
                Spacer(minLength: 8)
                if let change = value.rateChangePercent {
                    Text((change > 0 ? "+" : "") + change.formatted(.number.precision(.fractionLength(1))) + "% rate")
                        .interfaceFont(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Change in measured transfer rate relative to the reference run. This is not a drive health score.")
                }
            }
            rateBar("Selected", value.selectedRate, maximum: max(value.selectedRate ?? 0, value.referenceRate ?? 0), accent: true)
            rateBar("Reference", value.referenceRate, maximum: max(value.selectedRate ?? 0, value.referenceRate ?? 0), accent: false)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Selected")
                    Text("Reference")
                }.foregroundStyle(.secondary)
                GridRow {
                    Text("Operations/s")
                    Text(number(value.selectedIOPS, precision: 0))
                    Text(number(value.referenceIOPS, precision: 0))
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
    private func rateBar(_ title: String, _ value: Double?, maximum: Double, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(number(value, precision: 1) + " MB/s").monospacedDigit()
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
        .accessibilityLabel(title + " transfer rate")
        .accessibilityValue(number(value, precision: 1) + " megabytes per second")
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
