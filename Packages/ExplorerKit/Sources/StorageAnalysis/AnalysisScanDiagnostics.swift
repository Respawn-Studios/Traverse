import Foundation

/// Names-free, bounded counters already emitted by the progressive worker.
/// Inclusive timing regions overlap; callers must not sum them as disjoint work.
public struct AnalysisScanDiagnostics: Sendable, Equatable {
    public enum Stage: String, CaseIterable, Sendable {
        case directoryOpen = "directory_open_ns", identity = "identity_ns", namespace = "namespace_ns"
        case bulk = "bulk_ns", parse = "parse_ns", admission = "admission_ns", commit = "commit_ns", seal = "seal_ns"
        case authority = "catalog_authority_ns", checkpoint = "checkpoint_ns", sqliteCommit = "sqlite_commit_ns"
    }
    public let timingsEnabled: Bool
    private let nanoseconds: [UInt64]
    let reasonCounts: [UInt64]
    public let uncategorizedNotices: UInt64
    public subscript(stage: Stage) -> UInt64 { nanoseconds[Stage.allCases.firstIndex(of: stage)!] }

    static func decode(_ value: Any?, errors: UInt64) throws -> Self {
        guard let frame = value as? [String: Any], let flag = frame["timings_enabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let rows = frame["notice_buckets"] as? [[String: Any]], rows.count <= 64,
              Set(frame.keys) == Set(Stage.allCases.map(\.rawValue) + ["timings_enabled", "notice_buckets", "other_notices"]) else {
            throw StorageScanFailure.invalidOutput
        }
        let enabled = flag.boolValue
        var times: [UInt64] = []
        for stage in Stage.allCases {
            let number = try storedNumber(frame[stage.rawValue])
            guard enabled || number == 0 else { throw StorageScanFailure.invalidOutput }
            times.append(number)
        }
        let other = try storedNumber(frame["other_notices"])
        var total = other, counts = Array(repeating: UInt64(0), count: AnalysisScanCoverageReason.allCases.count)
        var keys = Set<String>()
        for row in rows {
            guard Set(row.keys) == ["source", "code", "errno", "count"],
                  let source = strictInteger(row["source"]), (0...2).contains(source),
                  let code = row["code"] as? String, !code.isEmpty, code.utf8.count <= 64,
                  code.utf8.allSatisfy({ $0 == 95 || (97...122).contains($0) }),
                  let error = strictInteger(row["errno"]), (-1...255).contains(error),
                  keys.insert("\(source):\(code):\(error)").inserted else { throw StorageScanFailure.invalidOutput }
            let count = try storedNumber(row["count"])
            let next = total.addingReportingOverflow(count)
            guard count > 0, !next.overflow else { throw StorageScanFailure.invalidOutput }
            total = next.partialValue
            let index = AnalysisScanCoverage.reason(code: code, error: Int32(error)).rawValue
            let sum = counts[index].addingReportingOverflow(count)
            guard !sum.overflow else { throw StorageScanFailure.invalidOutput }
            counts[index] = sum.partialValue
        }
        guard total == errors else { throw StorageScanFailure.invalidOutput }
        return .init(timingsEnabled: enabled, nanoseconds: times, reasonCounts: counts, uncategorizedNotices: other)
    }
}
