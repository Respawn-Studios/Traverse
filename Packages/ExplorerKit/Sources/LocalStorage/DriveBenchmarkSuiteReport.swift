import Foundation

/// A clipboard projection of two individually measured generated-file runs.
/// The second run can be absent when the first fails or Stop arrives between
/// runs. Neither this report nor its nested reports contain selection identity.
public struct DriveBenchmarkSuiteReport: Sendable, Encodable {
    public enum Failure: Error { case incompatibleRuns }

    public let schemaVersion = 1
    public let measurement = "generated-file-workload-suite"
    public let preset = "quick-mix-v1"
    public let sequentialRequestedBytes: Int64 = DriveBenchmarkSize.quick.bytes
    public let random4KRequestedBytes: Int64 = DriveBenchmarkSize.compact.bytes
    public let outcome: DriveBenchmarkReport.Outcome
    public let sequential: DriveBenchmarkReport
    public let random4K: DriveBenchmarkReport?
    public let semantics = "Each run has its own preparation, measured phases, flush and guarded cleanup. Rates and I/O latency belong to their named run; no combined speed or device-health score is inferred."

    public init(sequential: DriveBenchmarkReport, random4K: DriveBenchmarkReport?) throws {
        guard sequential.workload == DriveBenchmarkWorkload.sequential.rawValue,
              sequential.blockBytes == DriveSequentialBlockSize.mib1.bytes,
              Self.bytesFit(sequential, requested: DriveBenchmarkSize.quick.bytes),
              random4K == nil || (
                  sequential.outcome == .completed &&
                  random4K?.workload == DriveBenchmarkWorkload.random4K.rawValue &&
                  random4K?.blockBytes == DriveBenchmarkWorkload.random4K.blockBytes &&
                  random4K?.cacheMode == sequential.cacheMode &&
                  random4K.map { Self.bytesFit($0, requested: DriveBenchmarkSize.compact.bytes) } == true
              ) else { throw Failure.incompatibleRuns }
        self.sequential = sequential
        self.random4K = random4K
        if let random4K {
            outcome = sequential.outcome == .completed && random4K.outcome == .completed ? .completed
                : sequential.outcome == .failed || random4K.outcome == .failed ? .failed : .partial
        } else {
            outcome = sequential.outcome == .failed ? .failed : .partial
        }
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public var metricsTable: String {
        DriveBenchmarkReport.metricsTable(for: [sequential] + (random4K.map { [$0] } ?? []))
    }

    public var summary: String {
        var lines = ["Traverse Quick Mix file benchmark",
            "Outcome: \(outcome == .completed ? "Completed" : outcome == .partial ? "Partial" : "Failed")",
            "Preset: 64 MiB sequential at 1 MiB; 16 MiB random at 4 KiB, one outstanding I/O",
            "Sequential run:", sequential.summary]
        if let random4K {
            lines.append(contentsOf: ["Random 4 KiB run:", random4K.summary])
        } else {
            lines.append("Random 4 KiB run: Not started; the preceding run did not complete or Stop was requested.")
        }
        lines.append(semantics)
        return lines.joined(separator: "\n")
    }

    private static func bytesFit(_ report: DriveBenchmarkReport, requested: Int64) -> Bool {
        let written = report.writeAndFlush.completedBytes, read = report.readAndVerify.completedBytes
        guard written >= 0, read >= 0, written <= requested, read <= requested,
              report.preparationBytesWritten >= 0, report.preparationBytesWritten <= requested else { return false }
        return report.outcome != .completed || written == requested && read == requested
    }
}
