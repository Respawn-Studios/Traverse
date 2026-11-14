import CoreFoundation
import Foundation

extension StoredAnalysisGroups {
    /// The existing single-facet contract also backs the optional overview.
    static func decodeChartGroup(_ frame: [String: Any], facet: StoredAnalysisFacet,
                                 classificationRevision: AnalysisClassificationRevision) throws -> Self {
        guard facet != .applicationLayouts, frame["kind"] as? String == "groups",
              let values = frame["groups"] as? [[String: Any]], values.count <= 12 else { throw StorageScanFailure.invalidOutput }
        var groups: [StoredAnalysisGroup] = [], keys = Set<UInt64>()
        for value in values {
            let key = try storedNumber(value["key"])
            guard keys.insert(key).inserted, facet != .fileTypes || key < classificationRevision.fileTypes.count,
                  facet != .storageRoles || key < AnalysisCategory.allCases.count else { throw StorageScanFailure.invalidOutput }
            let name = try storedBlob(value["name"])
            guard name.count <= 255, !name.contains(0), !name.contains(47) else { throw StorageScanFailure.invalidOutput }
            groups.append(try .init(id: key, rawName: name, value: .init(encoded: storedBlob(value["value"], length: 140))))
        }
        let remainder = try StoredAnalysisValue(encoded: storedBlob(frame["remainder"], length: 140))
        let count = try storedNumber(frame["total_groups"])
        guard count >= groups.count else { throw StorageScanFailure.invalidOutput }
        return .init(facet: facet, groups: groups, remainder: remainder, groupCount: count,
                     projectCount: try storedNumber(frame["project_count"]))
    }
}

/// All-or-nothing, source-free chart partitions from one sealed read. An older
/// header uses the original queries; a declared but broken capability refuses.
struct StoredChartOverview: Sendable {
    let fileTypes: StoredAnalysisGroups
    let storageRoles: StoredAnalysisGroups?
    let projects: StoredAnalysisGroups?

    static func decode(_ frames: [[String: Any]], summary: StoredAnalysisSummary,
                       classificationRevision: AnalysisClassificationRevision) throws -> Self {
        guard classificationRevision == .v4, frames.count == 1, let frame = frames.first,
              Set(frame.keys) == ["kind", "revision", "classification_revision", "projected", "file_types", "storage_roles", "projects"],
              frame["kind"] as? String == "chart-overview", strictInteger(frame["revision"]) == 1,
              strictInteger(frame["classification_revision"]) == classificationRevision.rawValue,
              let projected = frame["projected"] as? NSNumber, CFGetTypeID(projected) == CFBooleanGetTypeID(),
              projected.boolValue == summary.classificationReady else { throw StorageScanFailure.invalidOutput }
        func partition(_ key: String, facet: StoredAnalysisFacet) throws -> StoredAnalysisGroups {
            guard let raw = frame[key] as? [String: Any],
                  Set(raw.keys) == ["kind", "groups", "remainder", "total_groups", "project_count"],
                  let rows = raw["groups"] as? [[String: Any]],
                  rows.allSatisfy({ Set($0.keys) == ["key", "name", "value"] }) else { throw StorageScanFailure.invalidOutput }
            let result = try StoredAnalysisGroups.decodeChartGroup(raw, facet: facet, classificationRevision: classificationRevision)
            guard result.groupCount < UInt64(Int64.max), result.projectCount <= UInt64(Int.max),
                  result.groups.count == min(12, result.groupCount),
                  facet != .fileTypes || result.groupCount <= classificationRevision.fileTypes.count,
                  facet != .storageRoles || result.groupCount <= AnalysisCategory.allCases.count else { throw StorageScanFailure.invalidOutput }
            var files: UInt64 = 0, bytes = AnalysisByteSubtotals()
            for value in result.groups.map(\.value) + [result.remainder] {
                guard value.counts.total == value.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
                let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
                guard !overflow, sum <= summary.value.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
                files = sum; bytes.merge(value.bytes)
            }
            guard files == summary.value.counts.regularFiles, bytes == summary.value.bytes else { throw StorageScanFailure.invalidOutput }
            if result.groupCount <= 12 {
                guard result.remainder == (try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))) else { throw StorageScanFailure.invalidOutput }
            }
            return result
        }
        let types = try partition("file_types", facet: .fileTypes)
        if !projected.boolValue {
            guard frame["storage_roles"] is NSNull, frame["projects"] is NSNull else { throw StorageScanFailure.invalidOutput }
            return .init(fileTypes: types, storageRoles: nil, projects: nil)
        }
        let roles = try partition("storage_roles", facet: .storageRoles), projects = try partition("projects", facet: .projects)
        guard types.projectCount == roles.projectCount, roles.projectCount == projects.projectCount else { throw StorageScanFailure.invalidOutput }
        return .init(fileTypes: types, storageRoles: roles, projects: projects)
    }
}
