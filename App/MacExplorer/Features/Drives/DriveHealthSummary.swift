import SwiftUI

/// The same selected-drive facts stay visible across Overview, Health and
/// Benchmark. No view appearance or disclosure performs a device query.
struct DriveHealthSummary: View {
    @ObservedObject var model: ApplicationDriveDetails
    @ObservedObject var settings: BrowserSettings
    let copyReading: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveToolColumns(settings: settings, minimumWidth: 520) {
                HStack(spacing: 10) {
                    Label("SMART", systemImage: "heart.text.clipboard").interfaceFont(.headline)
                        .help("Drive-reported health measurements, such as temperature and endurance. Availability depends on the drive and enclosure.")
                    if model.isCheckingHealth { ProgressView().controlSize(.mini).accessibilityLabel("Reading drive health") }
                    Text(model.healthIsStale ? "Previous reading" : model.health == nil && model.isCheckingHealth ? "Reading…" : model.healthTitle)
                        .interfaceFont(.caption).foregroundStyle(model.healthIsStale || model.healthWarning.map({ $0 != 0 }) == true ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .help("A dated reading from the drive. No warning reported does not predict future reliability.")
                }
            } trailing: {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Toggle("Live", isOn: Binding(get: {
                        model.canSelectLiveHealth && settings.driveHealthLiveUpdatesSelected
                    }, set: { if model.canSelectLiveHealth { settings.setDriveHealthLiveUpdates($0) } })).toggleStyle(.switch).controlSize(.small)
                        .disabled(!model.canSelectLiveHealth)
                        .help(model.healthReaderUnavailableReason ?? (DriveHealthFeature.liveUpdatesAvailable(for: model.target)
                            ? DriveHealthFeature.liveUpdatesHelp : "Live monitoring currently supports internal drives. Use Read SMART now for a single reading."))
                    Picker("Update interval", selection: $settings.driveHealthIntervalSeconds) {
                        ForEach([1, 2, 5, 10, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                    }.labelsHidden().frame(width: 76)
                        .disabled(!model.canSelectLiveHealth)
                        .accessibilityLabel("SMART update interval")
                    if model.isCheckingHealth && !model.isAutomaticHealthCheck {
                        Button { model.stopHealthCheck(interrupt: true) } label: { Image(systemName: "stop.fill") }
                            .disabled(model.healthIsStopping).help("Stop this hardware check")
                            .accessibilityLabel("Stop hardware check")
                    } else {
                        Button(action: model.checkHardwareHealth) { Image(systemName: "arrow.clockwise") }
                            .disabled(!model.canCheckHealth).help(model.healthReaderUnavailableReason ?? "Read SMART now")
                            .accessibilityLabel("Read SMART now")
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { metricCards }
                VStack(spacing: 10) { metricCards }
            }
            // A new device must never animate the previous device's numeric
            // values into its empty/loading state. Same-device readings still
            // use the shared metric card's optional number transition.
            .id(model.target?.id)
            if let date = model.lastHealthDate {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let age = max(0, context.date.timeIntervalSince(date))
                        let relative = age < 1 ? "just now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
                        Text("\(model.healthIsStale ? "Last verified reading" : "Updated") \(relative)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button("Copy SMART Reading", systemImage: "doc.on.doc", action: copyReading)
                        .help("Copies the displayed reading without device names or paths.")
                }
                .interfaceFont(.caption)
            } else {
                Text(model.healthReaderUnavailableReason ?? "SMART availability depends on the drive and enclosure.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if !model.healthNotice.isEmpty {
                Text(model.healthNotice).interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }.padding(14)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder private var metricCards: some View {
        DriveMetricCard(title: "Temperature", value: model.healthMeasurements?.temperatureCelsius.map {
            $0.formatted(.number.precision(.fractionLength(0))) + " °C"
        } ?? "—", symbol: "thermometer.medium", progress: nil, settings: settings)
            .help("The drive's composite temperature. It may combine several components rather than identify one sensor.")
        DriveMetricCard(title: "Spare capacity", value: model.healthMeasurements?.availableSparePercent.map { "\($0)%" } ?? "—",
            symbol: "externaldrive", progress: model.healthMeasurements?.availableSparePercent.map { Double($0) / 100 }, settings: settings)
            .help("The drive's remaining spare capacity. This is different from free space for your files.")
        DriveMetricCard(title: "Endurance used", value: model.healthMeasurements.map { "\($0.percentageUsed)%\($0.percentageUsed == 255 ? "+" : "")" } ?? "—",
            symbol: "gauge.with.dots.needle.50percent", progress: model.healthMeasurements.map { min(1, Double($0.percentageUsed) / 100) }, settings: settings)
            .help("The manufacturer's estimate of endurance used. It can exceed100% and does not predict remaining life.")
    }
}
