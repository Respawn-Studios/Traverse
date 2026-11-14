import Charts
import LocalStorage
import SwiftUI

struct DriveBenchmarkChart: View {
    let samples: [DriveBenchmarkSample]
    @State private var selectedTime: Double?
    private var selected: DriveBenchmarkSample? {
        guard let selectedTime else { return nil }
        return samples.min { abs($0.elapsedSeconds - selectedTime) < abs($1.elapsedSeconds - selectedTime) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transfer rate").interfaceFont(.headline)
            if samples.isEmpty {
                Text("The read/write curve appears during the test.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .center)
            } else {
                Chart(Array(samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Elapsed", sample.elapsedSeconds), y: .value("Rate", sample.megabytesPerSecond))
                        .foregroundStyle(by: .value("Operation", sample.phase == .writing ? "Write" : "Read & verify"))
                        .lineStyle(.init(lineWidth: 2))
                }
                .chartForegroundStyleScale(["Write": Color.accentColor, "Read & verify": Color.teal])
                .chartYAxisLabel("MB/s").chartXAxisLabel("Elapsed seconds")
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXSelection(value: $selectedTime)
                .frame(height: 150)
                .accessibilityLabel("Measured file-workload transfer rates")
                if let selected {
                    Text("\(selected.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s · \(selected.phase == .writing ? "Write" : "Read & verify") · \(selected.megabytesPerSecond.formatted(.number.precision(.fractionLength(1)))) MB/s")
                        .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(14).background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }
}
