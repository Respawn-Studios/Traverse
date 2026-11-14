import Foundation
import LocalStorage

/// Bounded in-memory samples from the currently selected physical drive only.
struct DriveHealthTrendPoint: Identifiable, Sendable {
    let id = UUID()
    let capturedAt: Date
    let temperature: Double?
    let warning: UInt8
    let kind: DriveHealthKind
    let sparePercent: UInt8?
    let enduranceUsedPercent: UInt8?
    let requestedIntervalSeconds: Int
    let samplingGapBefore: Bool
    let temperatureSegment: UUID

    /// Copies only fields from one clean, verified report. Unavailable reads
    /// are interruptions, never zero-temperature or warning-free samples.
    init?(report: DriveHealthReport, requestedIntervalSeconds: Int,
          previous: Self?, interrupted: Bool) {
        guard report.nativeCleanupConfirmed,
              case .warning(let kind, let warning, let date) = report.outcome,
              date.timeIntervalSince1970.isFinite else { return nil }
        capturedAt = date; self.kind = kind; self.warning = warning
        temperature = report.nvmeMeasurements?.temperatureCelsius
        sparePercent = report.nvmeMeasurements?.availableSparePercent
        enduranceUsedPercent = report.nvmeMeasurements?.percentageUsed
        self.requestedIntervalSeconds = [1, 2, 5, 10, 30, 60].contains(requestedIntervalSeconds) ? requestedIntervalSeconds : 1
        if let previous {
            let elapsed = date.timeIntervalSince(previous.capturedAt)
            let expected = Double(max(self.requestedIntervalSeconds, previous.requestedIntervalSeconds))
            // This marks a missing sampling interval, not a device failure or
            // a claim that its hardware counters should change each second.
            samplingGapBefore = interrupted || elapsed < 0 || elapsed > max(3, expected * 2.5)
            temperatureSegment = samplingGapBefore || temperature == nil || previous.temperature == nil || kind != previous.kind
                ? UUID() : previous.temperatureSegment
        } else { samplingGapBefore = false; temperatureSegment = UUID() }
    }

    var warningText: String {
        let source = kind == .ata ? "ATA threshold" : "NVMe critical"
        return source + (warning == 0 ? " · No warning reported" : " · Warning " + String(format: "0x%02X", warning))
    }
}
