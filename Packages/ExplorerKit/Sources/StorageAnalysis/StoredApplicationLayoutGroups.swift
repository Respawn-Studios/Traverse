import Foundation

extension StoredAnalysisGroups {
    /// Independent optional query contract over v3 metadata. The result is a
    /// partition of observed regular-file namespace totals, not more storage.
    static func decodeApplicationLayouts(_ frames: [[String: Any]], classificationRevision: AnalysisClassificationRevision = .v3) throws -> Self {
        guard classificationRevision.supportsApplicationRules, frames.count == 1, let frame = frames.first,
              frame["kind"] as? String == "application_layouts", strictInteger(frame["layout_revision"]) == 1,
              strictInteger(frame["classification_revision"]) == classificationRevision.rawValue,
              let rows = frame["groups"] as? [[String: Any]], rows.count <= AnalysisApplicationLayout.allCases.count else { throw StorageScanFailure.invalidOutput }
        let total = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        let remainder = try StoredAnalysisValue(encoded: storedBlob(frame["remainder"], length: 140))
        let zero = try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))
        guard total.counts.total == total.counts.regularFiles, remainder == zero else {
            throw StorageScanFailure.invalidOutput
        }
        var groups: [StoredAnalysisGroup] = [], seen = Set<UInt64>()
        var bytes = remainder.bytes, files = remainder.counts.regularFiles
        for row in rows {
            let key = try storedNumber(row["key"]), name = try storedBlob(row["name"])
            let value = try StoredAnalysisValue(encoded: storedBlob(row["value"], length: 140))
            guard key < AnalysisApplicationLayout.allCases.count, seen.insert(key).inserted, name.isEmpty,
                  value.counts.total == value.counts.regularFiles, value.counts.regularFiles > 0 else { throw StorageScanFailure.invalidOutput }
            let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
            guard !overflow, sum <= total.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
            files = sum; bytes.merge(value.bytes)
            groups.append(.init(id: key, rawName: name, value: value))
        }
        let count = try storedNumber(frame["total_groups"])
        guard count <= AnalysisApplicationLayout.allCases.count,
              files == total.counts.regularFiles, bytes == total.bytes, count == groups.count,
              remainder.counts.regularFiles == 0,
              try storedNumber(frame["project_count"]) == 0 else { throw StorageScanFailure.invalidOutput }
        return .init(facet: .applicationLayouts, groups: groups, remainder: remainder, groupCount: count, projectCount: 0)
    }
}
