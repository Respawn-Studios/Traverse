import Charts
import LocalStorage
import SwiftUI

extension DriveBenchmarkMetric {
    var unit: String { self == .operationsPerSecond ? "IOPS" : "MB/s" }
    var spokenUnit: String { self == .operationsPerSecond ? "operations per second" : "megabytes per second" }
    var rateName: String { self == .operationsPerSecond ? "Operation rate" : "Transfer rate" }
    var alternate: Self { self == .operationsPerSecond ? .megabytesPerSecond : .operationsPerSecond }

    func displayValue(_ value: Double?, fractionalDigits: Int = 0) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(fractionalDigits)))
    }

    func accessibilityValue(_ value: Double?, fractionalDigits: Int = 0) -> String {
        guard let value else { return "Unavailable" }
        return "\(displayValue(value, fractionalDigits: fractionalDigits)) \(spokenUnit)"
    }
}

struct DriveBenchmarkChart: View {
    let samples: [DriveBenchmarkSample]
    let workload: DriveBenchmarkWorkload
    @State private var selectedTime: Double?
    private var metric: DriveBenchmarkMetric { workload.primaryMetric }
    private var selected: DriveBenchmarkSample? {
        guard let selectedTime else { return nil }
        return samples.min { abs($0.elapsedSeconds - selectedTime) < abs($1.elapsedSeconds - selectedTime) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.rateName).interfaceFont(.headline)
            if samples.isEmpty {
                Text("The read/write curve appears during the test.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .center)
            } else {
                Chart(Array(samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Elapsed", sample.elapsedSeconds), y: .value(metric.rateName, sample.rate(for: workload)))
                        .foregroundStyle(by: .value("Operation", sample.phase == .writing ? "Write" : "Read & verify"))
                        .lineStyle(.init(lineWidth: 2))
                }
                .chartForegroundStyleScale(["Write": Color.accentColor, "Read & verify": Color.teal])
                .chartYAxisLabel(metric.unit).chartXAxisLabel("Elapsed seconds")
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXSelection(value: $selectedTime)
                .frame(height: 150)
                .accessibilityLabel("\(metric.rateName) during the file benchmark")
                if let selected {
                    Text("\(selected.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s · \(selected.phase == .writing ? "Write" : "Read & verify") · \(metric.displayValue(selected.rate(for: workload), fractionalDigits: 1)) \(metric.unit)")
                        .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(14).background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
            .onChange(of: workload) { _, _ in selectedTime = nil }
    }
}
