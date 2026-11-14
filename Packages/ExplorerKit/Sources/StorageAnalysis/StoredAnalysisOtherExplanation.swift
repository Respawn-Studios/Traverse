import Foundation

/// Fixed literal filename buckets, not inferred file formats or deletion advice.
public enum AnalysisOtherNamePattern: Int, CaseIterable, Sendable {
    case noSuffix, dotName, trailingDot, ambiguousBinarySuffix, unrecognizedSuffix
    public var title: String {
        switch self {
        case .noSuffix: "No filename suffix"
        case .dotName: "Leading-dot name without a further suffix"
        case .trailingDot: "Filename ending in a dot"
        case .ambiguousBinarySuffix: "Ambiguous .bin / .dat suffix"
        case .unrecognizedSuffix: "Other unrecognized suffix"
        }
    }
}

public struct StoredAnalysisOtherExplanation: Sendable {
    public let folder: UInt64
    public let value: StoredAnalysisValue
    /// Independent partitions of the same Other subtotal. Never add these.
    public let storageRoles: [StoredAnalysisValue]
    public let namePatterns: [StoredAnalysisValue]
    /// Optional explanation revision1. Absent capability remains unavailable,
    /// not an empty or reinterpreted classification partition.
    public let applicationLayouts: [StoredAnalysisValue]?

    static func decode(_ frames: [[String: Any]], folder: UInt64, classificationRevision: AnalysisClassificationRevision = .v3) throws -> Self {
        guard classificationRevision.supportsApplicationRules, frames.count == 1, let frame = frames.first,
              frame["kind"] as? String == "other_explanation", strictInteger(frame["classification_revision"]) == classificationRevision.rawValue,
              try storedNumber(frame["parent"]) == folder else { throw StorageScanFailure.invalidOutput }
        let total = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        func partition(_ key: String, count: Int) throws -> [StoredAnalysisValue] {
            guard let rows = frame[key] as? [[String: Any]], rows.count == count,
                  total.counts.total == total.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
            var values: [StoredAnalysisValue] = [], bytes = AnalysisByteSubtotals(), files: UInt64 = 0
            for (id, row) in rows.enumerated() {
                guard strictInteger(row["id"]) == id else { throw StorageScanFailure.invalidOutput }
                let value = try StoredAnalysisValue(encoded: storedBlob(row["value"], length: 140))
                let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
                guard !overflow, value.counts.total == value.counts.regularFiles, sum <= total.counts.regularFiles else {
                    throw StorageScanFailure.invalidOutput
                }
                files = sum; bytes.merge(value.bytes); values.append(value)
            }
            guard files == total.counts.regularFiles, bytes == total.bytes else { throw StorageScanFailure.invalidOutput }
            return values
        }
        let layouts: [StoredAnalysisValue]?
        if frame["layout_revision"] != nil || frame["layouts"] != nil {
            guard strictInteger(frame["layout_revision"]) == 1 else { throw StorageScanFailure.invalidOutput }
            layouts = try partition("layouts", count: AnalysisApplicationLayout.allCases.count)
        } else { layouts = nil }
        return try .init(folder: folder, value: total,
            storageRoles: partition("roles", count: AnalysisCategory.allCases.count),
            namePatterns: partition("name_patterns", count: AnalysisOtherNamePattern.allCases.count), applicationLayouts: layouts)
    }
}

extension StorageAnalysisResult {
    /// Sealed metadata only, with Other retained at every selected folder.
    /// The fixed arrays do not grow with unique names or extensions.
    public func explainOther(folder: UInt64 = 0) async throws -> StoredAnalysisOtherExplanation {
        guard classificationRevision.supportsApplicationRules, folder < Int64.max else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("explain-other", parent: folder, facet: 3, filterKey: 0), folder: folder, classificationRevision: classificationRevision)
    }
}
