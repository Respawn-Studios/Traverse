#if DEBUG
import Foundation

/// Experimental numeric-only comparison over the exact same sealed names and
/// metric observations. No stored classification is changed or reinterpreted.
public struct StoredClassificationAudit: Sendable {
    public let old: [StoredAnalysisValue]
    public let new: [StoredAnalysisValue]
    public let total: StoredAnalysisValue
    public let changed: StoredAnalysisValue

    static func decode(_ frames: [[String: Any]]) throws -> Self {
        guard frames.count == 1, let frame = frames.first,
              Set(frame.keys) == ["kind", "revision", "old", "new", "total", "changed"],
              frame["kind"] as? String == "classification_audit", strictInteger(frame["revision"]) == 1,
              let old = frame["old"] as? [String], let new = frame["new"] as? [String], old.count == 16, new.count == 16 else { throw StorageScanFailure.invalidOutput }
        func decode(_ value: String) throws -> StoredAnalysisValue { try .init(encoded: storedBlob(value, length: 140)) }
        let result = try Self(old: old.map(decode), new: new.map(decode),
            total: .init(encoded: storedBlob(frame["total"], length: 140)), changed: .init(encoded: storedBlob(frame["changed"], length: 140)))
        for partition in [result.old, result.new] {
            var files: UInt64 = 0, bytes = AnalysisByteSubtotals()
            for value in partition {
                let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
                guard !overflow, sum < Int64.max, value.counts.total == value.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
                files = sum; bytes.merge(value.bytes)
            }
            guard files == result.total.counts.regularFiles, bytes == result.total.bytes else { throw StorageScanFailure.invalidOutput }
        }
        guard result.total.counts.total == result.total.counts.regularFiles,
              result.changed.counts.total == result.changed.counts.regularFiles,
              result.changed.counts.regularFiles <= result.total.counts.regularFiles,
              result.old[15] == (try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))) else { throw StorageScanFailure.invalidOutput }
        for metric in AnalysisByteMetric.allCases {
            let all = result.total.bytes[metric], changed = result.changed.bytes[metric]
            guard changed.notReturnedCount <= all.notReturnedCount, changed.failedCount <= all.failedCount,
                  !changed.overflowed || all.overflowed,
                  all.overflowed || (changed.knownBytes ?? 0) <= (all.knownBytes ?? 0) else { throw StorageScanFailure.invalidOutput }
        }
        return result
    }
}
#endif
