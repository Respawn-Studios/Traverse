import Foundation

/// Two exact partitions of one recorded project. No child-folder hierarchy or
/// new source authority; nested project observations stay with their own key.
public struct StoredProjectComposition: Sendable {
    public let target: StoredAnalysisDrillTarget
    public let metric: AnalysisByteMetric
    public let value: StoredAnalysisValue
    public let fileTypes: [StoredAnalysisGroup]
    public let storageRoles: [StoredAnalysisGroup]
    public var overview: StoredAnalysisBreakdown {
        .init(rankingMetric: metric, value: value, rows: [], remainder: value, filter: target)
    }
    public func slices(_ facet: StoredAnalysisFacet) -> [AnalysisAttributionSlice] {
        guard facet == .fileTypes || facet == .storageRoles else { return [] }
        let rows = facet == .fileTypes ? fileTypes : storageRoles
        return rows.map { group in
            let title = facet == .fileTypes ? AnalysisFileType(rawValue: Int(group.id))!.title
                : group.id == 0 ? "Other project files" : AnalysisCategory(rawValue: Int(group.id))!.title
            let explanation = facet == .fileTypes ? AnalysisFileType(rawValue: Int(group.id))!.explanation
                : AnalysisCategory(rawValue: Int(group.id))!.explanation
            return .init(title: title, explanation: explanation, bytes: group.value.bytes,
                files: group.value.counts.regularFiles, folder: nil)
        }
    }
    static func decode(_ frames: [[String: Any]], target: StoredAnalysisDrillTarget, metric: AnalysisByteMetric,
                       classificationRevision: AnalysisClassificationRevision = .v3) throws -> Self {
        guard classificationRevision.supportsApplicationRules, case .filtered(let folder, .projects, let project) = target,
              project < UInt64(Int64.max),
              (project == 0 && folder == 0) || (project > 0 && folder < UInt64(Int64.max) && project == folder + 1),
              frames.count == 1, let frame = frames.first,
              frame["kind"] as? String == "project-composition", strictInteger(frame["revision"]) == 1,
              strictInteger(frame["classification_revision"]) == classificationRevision.rawValue, strictInteger(frame["metric"]) == metric.rawValue,
              try storedNumber(frame["parent"]) == folder, try storedNumber(frame["project"]) == project else { throw StorageScanFailure.invalidOutput }
        let total = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        func partition(_ key: String, maximum: Int) throws -> [StoredAnalysisGroup] {
            guard let rows = frame[key] as? [[String: Any]], rows.count <= maximum else { throw StorageScanFailure.invalidOutput }
            var ids = Set<UInt64>(), groups: [StoredAnalysisGroup] = [], count: UInt64 = 0, bytes = AnalysisByteSubtotals()
            for row in rows {
                let id = try storedNumber(row["key"])
                let value = try StoredAnalysisValue(encoded: storedBlob(row["value"], length: 140))
                let (next, overflow) = count.addingReportingOverflow(value.counts.regularFiles)
                guard id < maximum, ids.insert(id).inserted, !overflow, value.counts.regularFiles > 0,
                      value.counts.total == value.counts.regularFiles, next <= total.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
                count = next; bytes.merge(value.bytes)
                groups.append(.init(id: id, rawName: Data(), value: value))
            }
            guard count == total.counts.regularFiles, total.counts.total == count, bytes == total.bytes else { throw StorageScanFailure.invalidOutput }
            return groups
        }
        return try .init(target: target, metric: metric, value: total,
            fileTypes: partition("file_types", maximum: classificationRevision.fileTypes.count),
            storageRoles: partition("roles", maximum: AnalysisCategory.allCases.count))
    }
}

extension StorageAnalysisResult {
    public func projectComposition(_ target: StoredAnalysisDrillTarget, metric: AnalysisByteMetric = .dataLogical) async throws -> StoredProjectComposition {
        guard classificationRevision.supportsApplicationRules, case .filtered(let folder, .projects, let key) = target,
              folder < Int64.max, key < Int64.max,
              (key == 0 && folder == 0) || (key > 0 && key == folder + 1) else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("project-composition-v1", parent: folder, cursor: UInt64(metric.rawValue), facet: 5, filterKey: key),
            target: target, metric: metric, classificationRevision: classificationRevision)
    }
}
