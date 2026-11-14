import Foundation
import LocalStorage

/// A small session-only result history. No paths, serial numbers or file data
/// are persisted or included in diagnostics by the benchmark presentation.
struct DriveBenchmarkRun: Identifiable {
    let id = UUID()
    let date: Date
    let volumeName: String
    let fileSystemID: Int64
    let result: DriveBenchmarkResult
    let healthSamples: [DriveHealthTrendPoint]
    /// Fast runs can start within the same second. Keep human-readable times
    /// distinct without exposing an internal record identifier.
    var displayTimestamp: String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3)))
    }
}
