import Foundation

/// Opt-in, operation-local measurements. Fixed buckets contain no paths, SQL or data.
/// Save, compareEncode and rowScanSQL are inclusive; nested buckets must not be summed.
internal final class JournalMetrics: @unchecked Sendable {
    enum Stage: String, Sendable { case save, validation, compareEncode, encoding, sizeScan, rowScanSQL, rowSQL, commit }
    enum Counter: String, Sendable { case epochRecordReads, fullAuditJobs, sqlPayloadReads, sqlPayloadBytes, epochPeakCachedRecords, scopeNativeHeaderRows, scopeNativeHeaderBytes, sqlJSONHeadProjectionBytesUpperBound, validatedRows, comparedRows, encodedRows, encodedBytes, rowScanCandidates, writtenRows }
    struct Timing: Codable, Sendable { var calls: Int64 = 0; var seconds: Double = 0 }
    struct Snapshot: Codable, Sendable {
        let stages: [String: Timing]
        let counters: [String: Int64]
        let nesting: String

        init(stages: [String: Timing], counters: [String: Int64],
             nesting: String = "save includes its buckets; compareEncode includes changed-row validation and encoding; rowScanSQL includes rowSQL; encoding also includes heads; commit includes initial schema transaction. Do not sum inclusive buckets.") {
            self.stages = stages
            self.counters = counters
            self.nesting = nesting
        }
    }
    private let lock = NSLock()
    private var stages: [String: Timing] = [:]
    private var counters: [String: Int64] = [:]

    func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func finish(_ stage: Stage, since start: UInt64) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        lock.withLock {
            stages[stage.rawValue, default: Timing()].calls += 1
            stages[stage.rawValue, default: Timing()].seconds += elapsed
        }
    }
    func add(_ counter: Counter, _ value: Int) {
        lock.withLock { counters[counter.rawValue, default: 0] += Int64(value) }
    }
    func maximum(_ counter:Counter,_ value:Int) {lock.withLock{counters[counter.rawValue]=max(counters[counter.rawValue] ?? 0,Int64(value))}}
    var snapshot: Snapshot { lock.withLock { Snapshot(stages: stages, counters: counters) } }
}

internal func measureJournal<T>(_ metrics: JournalMetrics?, _ stage: JournalMetrics.Stage,
                               _ body: () throws -> T) rethrows -> T {
    guard let metrics else { return try body() }
    let start = metrics.start()
    defer { metrics.finish(stage, since: start) }
    return try body()
}
