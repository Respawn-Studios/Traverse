import Foundation

public enum DriveBenchmarkWorkload: String, CaseIterable, Sendable {
    case sequential, random4K
    public var blockBytes: Int { self == .sequential ? 1 << 20 : 4 << 10 }
}

/// Only sequential transfers vary their block size. Random access remains
/// the separately named 4 KiB, one-operation-at-a-time workload.
public enum DriveSequentialBlockSize: Int, CaseIterable, Hashable, Sendable {
    case kib256 = 262_144, mib1 = 1_048_576, mib4 = 4_194_304
    public var bytes: Int { rawValue }
    public var title: String {
        switch self { case .kib256: "256 KiB"; case .mib1: "1 MiB"; case .mib4: "4 MiB" }
    }
}

/// A per-file request, never a global cache clear or a cold-device promise.
public enum DriveBenchmarkCacheMode: String, CaseIterable, Hashable, Sendable {
    case normal, tryNoCache
}

/// Latencies cover the completed block's I/O calls, excluding guards and byte
/// verification. Throughput/IOPS use whole phase wall time, including those costs.
public struct DriveBenchmarkLatency: Sendable {
    /// Fixed, bounded counts of completed block calls. A bucket includes its
    /// lower bound and excludes its upper bound; the final bucket has no upper
    /// bound. Raw block timings are not retained in the result.
    public struct Distribution: Sendable {
        public struct Bucket: Sendable {
            public let lowerBoundMilliseconds: Double
            public let upperBoundMilliseconds: Double?
            public let count: Int
        }
        public let buckets: [Bucket]
    }

    private static let bucketUpperBoundsMilliseconds: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8, 16]
    public let operations: Int
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let distribution: Distribution?
    init(_ seconds: [Double]) {
        operations = seconds.count
        guard !seconds.isEmpty else {
            medianMilliseconds = 0; p95Milliseconds = 0; p99Milliseconds = 0
            distribution = nil
            return
        }
        guard seconds.allSatisfy({ $0.isFinite && $0 >= 0 && ($0 * 1_000).isFinite }) else {
            medianMilliseconds = .nan; p95Milliseconds = .nan; p99Milliseconds = .nan
            distribution = nil
            return
        }
        let values = seconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            return values[min(values.count - 1, max(0, Int(ceil(Double(values.count) * fraction)) - 1))] * 1_000
        }
        medianMilliseconds = percentile(0.5)
        p95Milliseconds = percentile(0.95)
        p99Milliseconds = percentile(0.99)
        var counts = Array(repeating: 0, count: Self.bucketUpperBoundsMilliseconds.count + 1)
        for value in values {
            let milliseconds = value * 1_000
            let index = Self.bucketUpperBoundsMilliseconds.firstIndex(where: { milliseconds < $0 })
                ?? Self.bucketUpperBoundsMilliseconds.count
            counts[index] += 1
        }
        distribution = .init(buckets: counts.indices.map { index in
            Distribution.Bucket(
                lowerBoundMilliseconds: index == 0 ? 0 : Self.bucketUpperBoundsMilliseconds[index - 1],
                upperBoundMilliseconds: index < Self.bucketUpperBoundsMilliseconds.count
                    ? Self.bucketUpperBoundsMilliseconds[index] : nil,
                count: counts[index])
        })
    }
}

public struct DriveBenchmarkSample: Sendable {
    public let phase: DriveBenchmarkProgress.Phase
    public let elapsedSeconds: Double
    public let megabytesPerSecond: Double
    public init(phase: DriveBenchmarkProgress.Phase, elapsedSeconds: Double, megabytesPerSecond: Double) {
        self.phase = phase; self.elapsedSeconds = elapsedSeconds; self.megabytesPerSecond = megabytesPerSecond
    }
}

/// A deliberately small clipboard projection of a generated-file workload.
/// It has no selection/device identity, recovery path, health data or raw error
/// text. Missing/invalid timings remain unavailable rather than becoming zero.
public struct DriveBenchmarkReport: Sendable, Encodable {
    public enum Failure: Error { case invalidDate }
    public enum Outcome: String, Sendable, Encodable { case completed, partial, failed }
    public struct Latency: Sendable, Encodable {
        public let medianMilliseconds, p95Milliseconds, p99Milliseconds: Double
    }
    public struct Phase: Sendable, Encodable {
        public let completedBytes: Int64
        public let elapsedSeconds: Double?
        public let completedOperations: Int
        /// Decimal MB/s, and completed blocks divided by whole phase time.
        public let megabytesPerSecond, operationsPerSecond: Double?
        public let ioLatency: Latency?
    }
    public struct Sample: Sendable, Encodable {
        public let phase: String
        public let elapsedSeconds, megabytesPerSecond: Double
    }
    public let schemaVersion = 2
    public let measurement = "generated-file-workload"
    public let recordedAt: Date
    public let outcome: Outcome
    /// A fixed engine code; never a localized/raw error description.
    public let failureCode: String?
    public let workload: String
    public let blockBytes: Int
    public let cacheMode: String
    public let preparationBytesWritten: Int64
    public let preparationSeconds, writeSeconds, flushSeconds: Double?
    public let writeAndFlush, readAndVerify: Phase
    public let cacheBypassRequest, flushAcknowledgment: String
    public let cleanupNeeded: Bool
    public let performanceSamples: [Sample]
    public let semantics = "Generated-file measurements, not calibrated device performance. MB is 1,000,000 bytes. Phase rates include validation; write includes flush. I/O latency covers block calls only. Flush is an OS acknowledgment, not proof of hardware persistence."

    public init(result: DriveBenchmarkResult, recordedAt: Date) throws {
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidDate }
        self.recordedAt = recordedAt
        switch result.outcome { case .completed: outcome = .completed; case .cancelled: outcome = .partial; case .failed: outcome = .failed }
        failureCode = result.failure?.rawValue
        workload = result.workload.rawValue; blockBytes = result.blockBytes
        cacheMode = result.cacheMode.rawValue
        preparationBytesWritten = result.preparationBytesWritten
        preparationSeconds = Self.duration(result.preparationSeconds)
        let writing = Self.duration(result.writeSeconds), flushing = Self.duration(result.flushSeconds)
        writeSeconds = writing; flushSeconds = flushing
        let writeElapsed = writing.flatMap { writing in flushing.flatMap { Self.duration(writing + $0) } }
        writeAndFlush = Self.phase(bytes: result.bytesWritten, seconds: writeElapsed, latency: result.writeLatency, completed: outcome == .completed)
        readAndVerify = Self.phase(bytes: result.bytesRead, seconds: Self.duration(result.readSeconds), latency: result.readLatency, completed: outcome == .completed)
        cacheBypassRequest = result.cacheBypass.rawValue; flushAcknowledgment = result.flush.rawValue
        cleanupNeeded = result.scratchURL != nil
        performanceSamples = outcome == .completed ? result.samples.lazy.filter {
            $0.elapsedSeconds.isFinite && $0.elapsedSeconds >= 0 && $0.megabytesPerSecond.isFinite && $0.megabytesPerSecond >= 0
        }.prefix(600).map { Sample(phase: $0.phase.rawValue, elapsedSeconds: $0.elapsedSeconds, megabytesPerSecond: $0.megabytesPerSecond) } : []
    }
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    public var summary: String {
        let date = ISO8601DateFormatter().string(from: recordedAt)
        var lines = ["Traverse file benchmark", "Recorded: \(date)",
            "Outcome: \(outcome == .completed ? "Completed" : outcome == .partial ? "Partial (stopped)" : "Failed")",
            "Workload: \(workload == DriveBenchmarkWorkload.random4K.rawValue ? "Random 4 KiB" : "Sequential") · \(blockBytes) bytes per block · one outstanding I/O",
            "Preparation: \(preparationBytesWritten) bytes · \(Self.seconds(preparationSeconds)) (outside measured phases)",
            "Write + flush: \(writeAndFlush.completedBytes) bytes · \(Self.seconds(writeAndFlush.elapsedSeconds))",
            "Read + verify: \(readAndVerify.completedBytes) bytes · \(Self.seconds(readAndVerify.elapsedSeconds))",
            "Flush: \(Self.seconds(flushSeconds)) · \(flushDescription)",
            "Filesystem cache: \(cacheMode == DriveBenchmarkCacheMode.normal.rawValue ? "normal policy; bypass not requested" : cacheBypassRequest == "enabled" ? "no-cache requested for the test file" : cacheBypassRequest == "unavailable" ? "no-cache request unavailable" : "no-cache request not reached")",
            "Cleanup needed: \(cleanupNeeded ? "Yes — inspect the result in Traverse" : "No")"]
        if let failureCode { lines.append("Failure code: " + failureCode) }
        if outcome == .completed {
            for (title, phase) in [("Write + flush", writeAndFlush), ("Read + verify", readAndVerify)] {
                lines.append("\(title): \(Self.number(phase.megabytesPerSecond)) MB/s · \(Self.number(phase.operationsPerSecond)) operations/s · \(phase.completedOperations) completed operations")
                if let latency = phase.ioLatency {
                    lines.append("\(title) I/O latency: median \(Self.number(latency.medianMilliseconds)) ms · p95 \(Self.number(latency.p95Milliseconds)) ms · p99 \(Self.number(latency.p99Milliseconds)) ms")
                }
            }
        } else { lines.append("Partial/failed observations do not report aggregate speed or latency results.") }
        lines.append(semantics)
        return lines.joined(separator: "\n")
    }
    private static func duration(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
    private var flushDescription: String {
        switch flushAcknowledgment {
        case "fullSync": "OS acknowledged a full flush request"
        case "fileSyncOnly": "filesystem flush acknowledged; full flush unavailable"
        case "failed": "flush failed"
        default: "not completed"
        }
    }
    private static func phase(bytes: Int64, seconds: Double?, latency: DriveBenchmarkLatency, completed: Bool) -> Phase {
        func rate(_ amount: Double) -> Double? {
            guard completed, amount.isFinite, amount > 0, let seconds, seconds > 0 else { return nil }
            let value = amount / seconds; return value.isFinite ? value : nil
        }
        let values = [latency.medianMilliseconds, latency.p95Milliseconds, latency.p99Milliseconds]
        let ioLatency = completed && latency.operations > 0 && values.allSatisfy({ $0.isFinite && $0 >= 0 })
            ? Latency(medianMilliseconds: values[0], p95Milliseconds: values[1], p99Milliseconds: values[2]) : nil
        return Phase(completedBytes: bytes, elapsedSeconds: seconds, completedOperations: latency.operations,
            megabytesPerSecond: rate(Double(bytes) / 1_000_000), operationsPerSecond: rate(Double(latency.operations)), ioLatency: ioLatency)
    }
    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "Unavailable"
    }
    private static func seconds(_ value: Double?) -> String { value.map { number($0) + " s" } ?? "Time unavailable" }
}
