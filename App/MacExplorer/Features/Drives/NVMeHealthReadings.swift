import LocalStorage
import SwiftUI

/// Presentation only. Every value belongs to the health check's capture time;
/// opening or expanding this view cannot start another hardware request.
struct NVMeHealthReadings: View {
    let value: NVMeHealthMeasurements
    var showsOverview = true
    @State private var showCounters = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
              if showsOverview {
                reading("Temperature", temperature,
                    help: "The drive's composite temperature, which can combine several components. This is not necessarily a particular sensor's temperature.")
                reading("Spare capacity", value.availableSparePercent.map { "\($0)%" } ?? "Not reported",
                    help: "The drive's normalized remaining spare capacity. This is different from free file space.\(spareThreshold)")
                reading("Endurance used", value.percentageUsed == 255 ? "255% or more" : "\(value.percentageUsed)%",
                    help: "The manufacturer's estimate of endurance already used. It can exceed 100% without declaring a failure and is not a prediction of remaining life.")
              }
                reading("Data read", dataSize(.dataUnitsRead), help: dataHelp(.dataUnitsRead))
                reading("Data written", dataSize(.dataUnitsWritten), help: dataHelp(.dataUnitsWritten))
                reading("Power-on time", "\(value[.powerOnHours]) hours",
                    help: "Reported powered-on hours; some low-power states are not included.")
                reading("Media/data errors", String(value[.mediaErrors]),
                    help: "Unrecovered data-integrity errors reported by the controller. A zero count does not guarantee reliability.")
            }
            DisclosureGroup("More drive readings", isExpanded: $showCounters) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    reading("Power cycles", String(value[.powerCycles]), help: "The controller's reported power-cycle count.")
                    reading("Unsafe shutdowns", String(value[.unsafeShutdowns]),
                        help: "Times the drive lost power without receiving its normal shutdown notification.")
                    reading("Controller busy", "\(value[.controllerBusyMinutes]) minutes",
                        help: "Reported time with outstanding input/output commands. This is not elapsed app scan time.")
                    reading("Read commands", String(value[.hostReadCommands]), help: "Completed host read commands reported by the drive.")
                    reading("Write commands", String(value[.hostWriteCommands]), help: "Completed host write commands reported by the drive.")
                    reading("Error-log entries", String(value[.errorLogEntries]),
                        help: "The controller's lifetime error-log entry count. Entries are not all media failures; Traverse does not read their contents here.")
                }
            }.interfaceFont(.callout)
        }
    }

    private var temperature: String {
        value.temperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(0)))) °C" } ?? "Not reported"
    }
    private var spareThreshold: String {
        value.spareThresholdPercent.map { " Its reported warning threshold is \($0)%." } ?? ""
    }
    private func dataSize(_ kind: NVMeHealthCounterKind) -> String {
        let units = value[kind]
        guard units != 0 else { return "Not reported" }
        // NVMe rounds this counter up in units of512,000 bytes. Keep the exact
        // UInt128 counter in the model; only this human-readable label rounds.
        if units <= UInt128(Int64.max) / 512_000 {
            return "≈ \(FileSizeText.string(Int64(units * 512_000)))"
        }
        let bytes = Double(units) * 512_000
        return "≈ \(bytes.formatted(.number.notation(.scientific).precision(.significantDigits(4)))) bytes"
    }
    private func dataHelp(_ kind: NVMeHealthCounterKind) -> String {
        value[kind] == 0 ? "The drive did not report this lifetime total."
            : "Reported counter: \(value[kind]). Each unit represents 1,000 groups of 512 bytes, rounded up by the drive. The displayed size is approximate and excludes metadata."
    }
    @ViewBuilder private func reading(_ title: String, _ text: String, help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).help(help)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).help(help)
        }.interfaceFont(.callout)
    }
}
