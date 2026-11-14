import Foundation

/// The ten lifetime counters named by Apple's public512-byte SMART structure.
/// Their order matches its bytes32...191, not a vendor-specific attribute table.
public enum NVMeHealthCounterKind: Int, CaseIterable, Sendable {
    case dataUnitsRead, dataUnitsWritten, hostReadCommands, hostWriteCommands
    case controllerBusyMinutes, powerCycles, powerOnHours, unsafeShutdowns
    case mediaErrors, errorLogEntries
}

/// Copied measurements from the same explicit read as the warning byte. This is
/// not a health score, remaining-life prediction or historical polling series.
public struct NVMeHealthMeasurements: Equatable, Sendable {
    public let temperatureKelvin: UInt16
    public let availableSpare: UInt8
    public let spareThreshold: UInt8
    public let percentageUsed: UInt8
    private let counters: [UInt128]

    public init?(temperatureKelvin: UInt16, availableSpare: UInt8, spareThreshold: UInt8,
                 percentageUsed: UInt8, counters: [UInt128]) {
        guard counters.count == NVMeHealthCounterKind.allCases.count else { return nil }
        self.temperatureKelvin = temperatureKelvin
        self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold
        self.percentageUsed = percentageUsed
        self.counters = counters
    }

    /// NVMe uses zero for a temperature that is not reported. Invalid normalized
    /// spare percentages are also absent, rather than silently clamped to100%.
    public var temperatureCelsius: Double? { temperatureKelvin == 0 ? nil : Double(temperatureKelvin) - 273.15 }
    public var availableSparePercent: UInt8? { availableSpare <= 100 ? availableSpare : nil }
    public var spareThresholdPercent: UInt8? { spareThreshold <= 100 ? spareThreshold : nil }
    public subscript(_ kind: NVMeHealthCounterKind) -> UInt128 { counters[kind.rawValue] }
}
