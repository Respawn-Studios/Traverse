import Foundation
import LocalStorage

enum DriveBenchmarkPreset: String, CaseIterable {
    case selected, quickMix
}

/// A small session-only result history. No paths, serial numbers or file data
/// are persisted or included in diagnostics by the benchmark presentation.
struct DriveBenchmarkRun: Identifiable {
    let id = UUID()
    let date: Date
    let volumeName: String
    let fileSystemID: Int64
    let result: DriveBenchmarkResult
    let healthSamples: [DriveHealthTrendPoint]
    var suiteID: UUID? = nil
    /// Fast runs can start within the same second. Keep human-readable times
    /// distinct without exposing an internal record identifier.
    var displayTimestamp: String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3)))
    }
}

/// The history still owns individual runs. A suite groups only runs that
/// survived in this session's bounded history; comparisons use each run's
/// existing exact-match rules.
struct DriveBenchmarkSuite {
    let sequential: DriveBenchmarkRun
    let random4K: DriveBenchmarkRun?

    func report() throws -> DriveBenchmarkSuiteReport {
        let first = try DriveBenchmarkReport(result: sequential.result, recordedAt: sequential.date)
        let second = try random4K.map { try DriveBenchmarkReport(result: $0.result, recordedAt: $0.date) }
        return try DriveBenchmarkSuiteReport(sequential: first, random4K: second)
    }
}
