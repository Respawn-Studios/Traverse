import Charts
import SwiftUI

struct DriveHealthTrend: View {
    @ObservedObject var model: ApplicationDriveDetails
    var recordedPoints: [DriveHealthTrendPoint]? = nil
    @State private var showsHistory = false
    @Environment(\.interfaceScale) private var interfaceScale
    private var points: [DriveHealthTrendPoint] { recordedPoints ?? model.healthHistory }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(recordedPoints == nil ? "Temperature" : "Temperature during test", systemImage: "waveform.path.ecg").interfaceFont(.headline)
            if points.contains(where: { $0.temperature != nil }) {
                Chart(points) { point in
                    if let temperature = point.temperature {
                        LineMark(x: .value("Time", point.capturedAt), y: .value("Temperature", temperature),
                            series: .value("Reading segment", point.temperatureSegment.uuidString))
                            .foregroundStyle(Color.accentColor).lineStyle(.init(lineWidth: 2))
                        PointMark(x: .value("Time", point.capturedAt), y: .value("Temperature", temperature))
                            .foregroundStyle(Color.accentColor).symbolSize(12)
                    }
                }.chartYScale(domain: 0...max(100, (points.compactMap(\.temperature).max() ?? 0) + 10))
                    .chartYAxisLabel("°C")
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                        }
                    }.frame(height: 140)
                    .accessibilityLabel("Selected-drive temperature, recent readings")
            } else {
                Text(recordedPoints == nil ? "A temperature trend appears when this drive supplies readings." : "No temperature readings were captured during this test.")
                    .interfaceFont(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
            }
            Text(recordedPoints == nil ? "Recent readings stay in this window. Some drive counters update less often than the selected interval." : "Recorded with this benchmark. Live SMART readings remain in the summary above.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            if points.contains(where: { $0.samplingGapBefore || $0.temperature == nil }) {
                Text("Line breaks mark intervals without temperature samples. Missing values are not estimated.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Reading history · \(points.count)", isExpanded: $showsHistory) {
                if points.isEmpty {
                    Text(recordedPoints == nil ? "No verified readings have been captured for this drive." : "No verified readings were captured during this benchmark.")
                        .interfaceFont(.callout).foregroundStyle(.secondary).padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recordedPoints == nil ? "Newest first · up to 300 readings in this session." : "Newest first · readings saved with this benchmark in this session.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(points.reversed()) { point in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(point.capturedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3))))
                                            .interfaceFont(.caption.weight(.medium)).monospacedDigit()
                                        Text(point.warningText).interfaceFont(.caption)
                                            .foregroundStyle(point.warning == 0 ? Color.secondary : Color.orange)
                                        Text("Temperature: \(temperature(point)) · Spare: \(point.sparePercent.map { "\($0)%" } ?? "Not reported") · Endurance used: \(endurance(point))")
                                            .interfaceFont(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if point.samplingGapBefore {
                                            Label("Sampling gap before this reading", systemImage: "clock.badge.exclamationmark")
                                                .interfaceFont(.caption2).foregroundStyle(.secondary)
                                                .help("A pause, unavailable reading or longer interval between verified samples. This does not establish a hardware fault.")
                                        }
                                    }.accessibilityElement(children: .combine)
                                    Divider()
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(300, max(100, CGFloat(points.count) * 100 * interfaceScale)))
                        Text("Not reported means the drive did not supply that measurement. Warnings are drive-reported status, not a remaining-life prediction.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            if recordedPoints == nil && !model.healthNotice.isEmpty { Text(model.healthNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
        }.padding(14).background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }
    private func temperature(_ point: DriveHealthTrendPoint) -> String {
        point.temperature.map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "Not reported"
    }
    private func endurance(_ point: DriveHealthTrendPoint) -> String {
        point.enduranceUsedPercent.map { "\($0)%\($0 == 255 ? "+" : "")" } ?? "Not reported"
    }
}
