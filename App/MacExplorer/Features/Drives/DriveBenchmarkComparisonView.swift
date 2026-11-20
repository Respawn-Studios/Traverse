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

/// Four named measurements from two complete Quick Mix pairs. Sequential
/// transfers remain MB/s and random 4 KiB accesses remain operations/s.
struct DriveBenchmarkSuiteComparisonView: View {
    let comparison: DriveBenchmarkSuiteComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Mix comparison").interfaceFont(.headline)
            DriveBenchmarkComparisonSources(comparison: comparison.sequential)
            stage("Sequential · 64 MiB", write: comparison.sequential.write, read: comparison.sequential.read, random: false)
            stage("Random 4 KiB · 16 MiB", write: comparison.random4K.write, read: comparison.random4K.read, random: true)
            Text("Each stage matches the workload, test size and cache and flush settings. Compare the measured file rates and latency for each stage.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("benchmark-suite-comparison")
    }

    private func stage(_ title: String, write: DriveBenchmarkComparison.Phase,
                       read: DriveBenchmarkComparison.Phase, random: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).interfaceFont(.callout.bold())
            phase("Write + flush", write, random: random)
            Divider()
            phase("Read + verify", read, random: random)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    private func phase(_ title: String, _ value: DriveBenchmarkComparison.Phase, random: Bool) -> some View {
        let selected = random ? value.selectedIOPS : value.selectedRate
        let reference = random ? value.referenceIOPS : value.referenceRate
        let change = random ? value.iopsChangePercent : value.rateChangePercent
        let unit = random ? "IOPS" : "MB/s"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).interfaceFont(.callout)
                Spacer(minLength: 8)
                Text(change.map { ($0 > 0 ? "+" : "") + $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "Change unavailable")
                    .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Selected \(number(selected)) \(unit) · Reference \(number(reference)) \(unit)")
                .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
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
