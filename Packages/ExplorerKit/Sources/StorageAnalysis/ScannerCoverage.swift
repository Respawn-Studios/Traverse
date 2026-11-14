import Foundation

/// Bounded explanations of the worker's observed coverage gaps. These are
/// notices, not counts of unique omitted files or estimates of missing bytes.
public enum AnalysisScanCoverageReason: Int, CaseIterable, Sendable {
    case scopeBoundary, policyExclusion, accessDenied, directoryQueueLimit
    case entryLimit, depthLimit, pathLimit, changed, materializationDeferred
    case missingMetadata, unavailable, temporaryStorageLimit
}

/// Contains fixed categories and counters only, never a pathname. The worker
/// emits at most 100 detailed notices; retain the total separately so a sampled
/// explanation is never presented as an exhaustive omission inventory.
public struct AnalysisScanCoverage: Equatable, Sendable {
    private var counts = [UInt64](repeating: 0, count: AnalysisScanCoverageReason.allCases.count)
    public private(set) var reportedNotices: UInt64 = 0
    public private(set) var workerNotices: UInt64?
    public private(set) var terminalReason: AnalysisScanCoverageReason?
    /// True when the terminal counters account for every worker notice.
    public private(set) var reasonCountsAreComplete = false
    public private(set) var uncategorizedNotices: UInt64 = 0

    public init() {}

    /// Reconstructs the exact validated terminal counters for a dated read
    /// view. A recorded catalog cannot grant a new scan or file action.
    init(retained value: RetainedAnalysisRecord.Coverage) throws {
        try value.validate()
        guard value.reasonCounts.count == Self.reasonCount,
              let reported = UInt64(value.reportedNotices),
              let worker = UInt64(value.workerNotices),
              let uncategorized = UInt64(value.uncategorizedNotices) else {
            throw RetainedAnalysisFailure.invalid
        }
        let parsed = value.reasonCounts.compactMap(UInt64.init)
        guard parsed.count == Self.reasonCount else { throw RetainedAnalysisFailure.invalid }
        counts = parsed
        reportedNotices = reported
        workerNotices = worker
        uncategorizedNotices = uncategorized
        reasonCountsAreComplete = value.reasonCountsAreComplete
        terminalReason = value.terminalReason.flatMap(AnalysisScanCoverageReason.init(rawValue:))
    }

    private static var reasonCount: Int { AnalysisScanCoverageReason.allCases.count }

    public subscript(reason: AnalysisScanCoverageReason) -> UInt64 { counts[reason.rawValue] }
    public var omittedDetails: UInt64? { workerNotices.map { $0 - min($0, reportedNotices) } }
    public var hasExplanation: Bool { reportedNotices > 0 || terminalReason != nil || uncategorizedNotices > 0 || counts.contains(where: { $0 > 0 }) }

    mutating func record(code: String, error: Int32) {
        counts[Self.reason(code: code, error: error).rawValue] += 1
        reportedNotices += 1
    }

    mutating func finish(reason: String, errors: UInt64) {
        workerNotices = errors
        terminalReason = reason == "complete" || reason == "cancelled" ? nil : Self.reason(code: reason, error: 0)
    }

    mutating func finish(reason: String, errors: UInt64, diagnostics: AnalysisScanDiagnostics) throws {
        var deficits: UInt64 = 0
        for (sampled, all) in zip(counts, diagnostics.reasonCounts) where sampled > all {
            let sum = deficits.addingReportingOverflow(sampled - all)
            guard !sum.overflow else { throw StorageScanFailure.invalidOutput }; deficits = sum.partialValue
        }
        guard reportedNotices <= errors, deficits <= diagnostics.uncategorizedNotices else { throw StorageScanFailure.invalidOutput }
        finish(reason: reason, errors: errors)
        counts = diagnostics.reasonCounts
        uncategorizedNotices = diagnostics.uncategorizedNotices
        reasonCountsAreComplete = diagnostics.uncategorizedNotices == 0
    }

    static func reason(code: String, error: Int32) -> AnalysisScanCoverageReason {
        switch code {
        case "boundary_excluded": return .scopeBoundary
        case "policy_excluded": return .policyExclusion
        case "queue_limit": return .directoryQueueLimit
        case "entry_limit": return .entryLimit
        case "depth_limit": return .depthLimit
        case "path_limit": return .pathLimit
        case "store_quota": return .temporaryStorageLimit
        case "directory_changed", "object_changed", "root_changed", "root_replaced", "topology_changed": return .changed
        case "materialization_denied": return .materializationDeferred
        case "missing_fields", "missing_identity": return .missingMetadata
        default:
            // POSIX EACCES and EPERM describe denial; they cannot identify
            // whether TCC, an ACL, POSIX permissions or another rule caused it.
            return error == 13 || error == 1 ? .accessDenied : .unavailable
        }
    }

    static func gap(code: String, error: Int32) -> AnalysisCoverageGap {
        switch reason(code: code, error: error) {
        case .scopeBoundary: return .boundaryExcluded
        case .directoryQueueLimit, .entryLimit, .depthLimit, .pathLimit, .temporaryStorageLimit: return .truncated
        case .changed: return .changing
        case .accessDenied: return .enumerationFailed(code: error)
        default: return .unavailable
        }
    }
}
