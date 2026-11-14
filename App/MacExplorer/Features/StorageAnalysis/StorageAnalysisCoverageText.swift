import Foundation
import StorageAnalysis

/// Native presentation of fixed coverage counters; no filesystem work.
enum StorageAnalysisCoverageText {
    static func guidance(_ coverage: AnalysisScanCoverage) -> String {
        if coverage[.temporaryStorageLimit] > 0 || coverage[.entryLimit] > 0 || coverage[.depthLimit] > 0 || coverage.terminalReason == .temporaryStorageLimit {
            return "A scan limit was reached. Scan a smaller folder for more detail."
        }
        if coverage[.accessDenied] > 0 { return "Some folders couldn’t be read. Review Access to check your selected locations." }
        if coverage[.materializationDeferred] > 0 { return "Online-only files weren’t downloaded. The result includes files available on this Mac." }
        if coverage[.changed] > 0 { return "Some files changed during scanning. Scan again when they’re settled for a fresh result." }
        return "Protected, excluded or unavailable items may be missing. Scan details explain what was skipped."
    }
    static func short(_ coverage: AnalysisScanCoverage) -> String? {
        let priority: [AnalysisScanCoverageReason] = [.temporaryStorageLimit, .directoryQueueLimit, .entryLimit, .depthLimit, .pathLimit,
            .accessDenied, .scopeBoundary, .policyExclusion, .changed, .materializationDeferred, .missingMetadata, .unavailable]
        let reasons = priority.filter { coverage[$0] > 0 || coverage.terminalReason == $0 }
        guard !reasons.isEmpty else { return nil }
        return "Incomplete · " + reasons.prefix(3).map(name).joined(separator: " · ")
    }

    static func details(_ coverage: AnalysisScanCoverage, root: URL?, paired: Bool = false) -> String {
        var lines = ["These are scan notices, not counts of unique missing items or missing bytes."]
        for reason in AnalysisScanCoverageReason.allCases where coverage[reason] > 0 {
            lines.append("\(name(reason)): \(coverage[reason]) notices")
        }
        if coverage.reasonCountsAreComplete {
            lines.append("These categories account for every worker notice. Notices can describe a whole skipped subtree; their counts do not measure missing bytes.")
        } else if coverage.uncategorizedNotices > 0 {
            lines.append("\(coverage.uncategorizedNotices) further notices could not be categorized.")
        } else if let omitted = coverage.omittedDetails, omitted > 0 {
            lines.append("\(omitted) additional notices have no detail; categories above are a sample.")
        }
        if let terminal = coverage.terminalReason, coverage[terminal] == 0 {
            lines.append("Worker also reported: \(name(terminal)).")
        }
        if paired {
            lines.append("System and Data are separate verified physical sources. Verified path aliases are references, not additional bytes. Other volumes and inaccessible areas remain separate; this is an interval observation, not an APFS snapshot or an inventory of all container blocks.")
        } else if root?.standardizedFileURL.path == "/" {
            lines.append("This scan covers the System volume only. User files on the separate Data volume are not included through filesystem boundaries. Choose the startup drive from This Mac for its combined System + Data analysis when available.")
        }
        lines.append("Access denials can come from macOS privacy controls, file permissions or ACLs. A scan cannot identify or override those protections.")
        return lines.joined(separator: "\n\n")
    }

    private static func name(_ reason: AnalysisScanCoverageReason) -> String {
        switch reason {
        case .scopeBoundary: return "filesystem/firmlink boundaries skipped"
        case .policyExclusion: return "privacy exclusions"
        case .accessDenied: return "access denied"
        case .directoryQueueLimit: return "directory queue limit reached"
        case .entryLimit: return "entry limit reached"
        case .depthLimit: return "depth limit reached"
        case .pathLimit: return "path limit reached"
        case .temporaryStorageLimit: return "temporary result storage limit reached"
        case .changed: return "items changed during scanning"
        case .materializationDeferred: return "online-only data deferred"
        case .missingMetadata: return "metadata unavailable"
        case .unavailable: return "other unavailable observations"
        }
    }
}
