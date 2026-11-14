import CoreFoundation
import Foundation

/// Query identity only. Neither target grants access or authorizes mutation.
public enum StoredPurposeJourneyTarget: Hashable, Sendable {
    case projects(role: AnalysisCategory)
    case locations(role: AnalysisCategory, project: UInt64)
    public var role: AnalysisCategory {
        switch self { case .projects(let role), .locations(let role, _): role }
    }
}

public struct StoredPurposeProjects: Sendable {
    public let role: AnalysisCategory
    public let metric: AnalysisByteMetric
    public let value: StoredAnalysisValue
    public let projects: [StoredAnalysisGroup]
    public let remainder: StoredAnalysisValue
    public let groupCount: UInt64
    public var overview: StoredAnalysisBreakdown { .init(rankingMetric: metric, value: value, rows: [], remainder: value, filter: nil) }

    public func slices(scopeName: String) -> [AnalysisAttributionSlice] {
        var slices = projects.map { project in
            var slice = AnalysisAttributionSlice(title: project.id == 0 ? "Shared or outside projects"
                : project.rawName.isEmpty ? scopeName : String(data: project.rawName, encoding: .utf8) ?? "Project name cannot be displayed",
                explanation: project.id == 0 ? "No recognized project folder contains these recorded files. This does not establish who owns or uses them."
                    : "Recorded \(role.title.lowercased()) inside this project folder, including its cache locations. Active use and whether these files are needed are unknown.",
                bytes: project.value.bytes, files: project.value.counts.regularFiles, folder: nil)
            slice.purposeTarget = .locations(role: role, project: project.id)
            return slice
        }
        if remainder.counts.regularFiles > 0 {
            slices.append(.init(title: "Other projects", explanation: "All remaining project groups, included in the recorded total. Choose a smaller scan to inspect them individually.",
                bytes: remainder.bytes, files: remainder.counts.regularFiles, folder: nil))
        }
        return slices
    }

    static func decode(_ frames: [[String: Any]], role: AnalysisCategory, metric: AnalysisByteMetric) throws -> Self {
        let decoded = try PurposeJourneyDecoder.decode(frames, target: .projects(role: role), metric: metric)
        return .init(role: role, metric: metric, value: decoded.total,
            projects: decoded.rows.map { .init(id: $0.id, rawName: $0.name, value: $0.value) }, remainder: decoded.remainder, groupCount: decoded.groupCount)
    }
}

public struct StoredPurposeLocation: Identifiable, Sendable {
    /// Exact directory ID in this result, not a path or a project/group ID.
    public let id: UInt64
    public let rawName: Data
    public let matchingValue: StoredAnalysisValue
    public let wholeRecordedValue: StoredAnalysisValue
    /// Observed matching regular files equal the entire recorded location.
    /// Coverage, active use, access and a current operation still need checks.
    public let matchesWholeRecordedLocation: Bool
    public let isSourceRoot: Bool
    public let displaySource: UInt64
    public let displayPath: [Data]
    public let displayPathIsTruncated: Bool
    public func title(scopeName: String) -> String {
        rawName.isEmpty ? scopeName : String(data: rawName, encoding: .utf8) ?? "Name cannot be displayed"
    }
    /// A bounded recorded label; never feed it to a filesystem operation.
    public func recordedPath(scopeName: String) -> String {
        let source = displaySource == 0 ? scopeName : displaySource == 1 ? "Data" : "System"
        let parts = displayPath.map { String(data: $0, encoding: .utf8) ?? "Name cannot be displayed" }
        return ([source] + (displayPathIsTruncated ? ["…"] : []) + parts).joined(separator: " / ")
    }
}

public struct StoredPurposeLocations: Sendable {
    public let role: AnalysisCategory
    public let project: UInt64
    public let metric: AnalysisByteMetric
    public let value: StoredAnalysisValue
    public let locations: [StoredPurposeLocation]
    public let remainder: StoredAnalysisValue
    public let groupCount: UInt64
    public var overview: StoredAnalysisBreakdown { .init(rankingMetric: metric, value: value, rows: [], remainder: value, filter: nil) }
    static func decode(_ frames: [[String: Any]], role: AnalysisCategory, project: UInt64, metric: AnalysisByteMetric, startup: Bool = false) throws -> Self {
        let decoded = try PurposeJourneyDecoder.decode(frames, target: .locations(role: role, project: project), metric: metric, startup: startup)
        return .init(role: role, project: project, metric: metric, value: decoded.total,
            locations: try decoded.rows.map { row in
                guard let whole = row.whole, let matches = row.matches, let source = row.displaySource, let path = row.displayPath, let truncated = row.truncated else { throw StorageScanFailure.invalidOutput }
                return .init(id: row.id, rawName: row.name, matchingValue: row.value, wholeRecordedValue: whole, matchesWholeRecordedLocation: matches,
                    isSourceRoot: row.id == (startup ? source : 0), displaySource: source, displayPath: path, displayPathIsTruncated: truncated)
            }, remainder: decoded.remainder, groupCount: decoded.groupCount)
    }
}

private enum PurposeJourneyDecoder {
    struct Row { let id: UInt64, name: Data, value: StoredAnalysisValue, whole: StoredAnalysisValue?, matches: Bool?, displaySource: UInt64?, displayPath: [Data]?, truncated: Bool? }
    struct Decoded { let total: StoredAnalysisValue, rows: [Row], remainder: StoredAnalysisValue, groupCount: UInt64 }
    static func regular(_ value: StoredAnalysisValue) -> Bool { value.counts.total == value.counts.regularFiles }
    static func decode(_ frames: [[String: Any]], target: StoredPurposeJourneyTarget, metric: AnalysisByteMetric, startup: Bool = false) throws -> Decoded {
        let project: UInt64?, kind: String
        switch target {
        case .projects: project = nil; kind = "purpose-projects"
        case .locations(_, let key):
            guard key < Int64.max else { throw StorageScanFailure.invalidOutput }; project = key; kind = "purpose-locations"
        }
        guard frames.count == 1, let frame = frames.first, frame["kind"] as? String == kind,
              strictInteger(frame["revision"]) == 1, frame["basis"] as? String == "project-namespace-v1",
              strictInteger(frame["classification_revision"]) == 4, strictInteger(frame["role"]) == target.role.rawValue,
              strictInteger(frame["metric"]) == metric.rawValue,
              let encodedRows = frame["rows"] as? [[String: Any]], encodedRows.count <= 12,
              Set(frame.keys) == Set(["kind", "revision", "basis", "classification_revision", "role", "metric", "value", "rows", "remainder", "total_groups"] + (project == nil ? [] : ["project"])) else {
            throw StorageScanFailure.invalidOutput
        }
        if let project { guard try storedNumber(frame["project"]) == project else { throw StorageScanFailure.invalidOutput } }
        let total = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        let remainder = try StoredAnalysisValue(encoded: storedBlob(frame["remainder"], length: 140))
        let count = try storedNumber(frame["total_groups"])
        guard regular(total), regular(remainder), count < Int64.max, count >= encodedRows.count,
              remainder.counts.regularFiles > 0 ? count > encodedRows.count : count == encodedRows.count else { throw StorageScanFailure.invalidOutput }
        var rows: [Row] = [], ids = Set<UInt64>(), files = remainder.counts.regularFiles, bytes = remainder.bytes
        for encoded in encodedRows {
            guard Set(encoded.keys) == Set(["key", "name", "value"] + (project == nil ? [] : ["whole_value", "whole_recorded_match", "display_source", "display_path", "display_truncated"])) else { throw StorageScanFailure.invalidOutput }
            let id = try storedNumber(encoded["key"]), name = try storedBlob(encoded["name"])
            let value = try StoredAnalysisValue(encoded: storedBlob(encoded["value"], length: 140))
            guard id < Int64.max, ids.insert(id).inserted, regular(value), value.counts.regularFiles > 0,
                  name.count <= 255, !name.contains(0), !name.contains(47), name != Data([46]), name != Data([46, 46]),
                  !name.isEmpty || id == 0 || project == nil && id == 1,
                  project != nil || id != 0 || name.isEmpty else { throw StorageScanFailure.invalidOutput }
            let whole: StoredAnalysisValue?, matches: Bool?, displaySource: UInt64?, displayPath: [Data]?, truncated: Bool?
            if project != nil {
                let observed = try StoredAnalysisValue(encoded: storedBlob(encoded["whole_value"], length: 140))
                guard let boolean = encoded["whole_recorded_match"] as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(),
                      value.counts.regularFiles <= observed.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
                let expected = observed.counts.regularFiles == value.counts.regularFiles && observed.bytes == value.bytes
                    && observed.counts.symbolicLinks == 0 && observed.counts.other == 0 && observed.counts.unknown == 0
                guard boolean.boolValue == expected else { throw StorageScanFailure.invalidOutput }
                guard let source = strictInteger(encoded["display_source"]), startup ? [1, 2].contains(source) : source == 0,
                      let path = encoded["display_path"] as? [String], path.count <= 6,
                      let clipped = encoded["display_truncated"] as? NSNumber, CFGetTypeID(clipped) == CFBooleanGetTypeID(),
                      !clipped.boolValue || path.count == 6 else { throw StorageScanFailure.invalidOutput }
                let components = try path.map { text -> Data in
                    let part = try storedBlob(text)
                    guard !part.isEmpty, part.count <= 255, !part.contains(0), !part.contains(47), part != Data([46]), part != Data([46, 46]) else { throw StorageScanFailure.invalidOutput }; return part
                }
                if id == UInt64(source) {
                    guard components.isEmpty, !clipped.boolValue else { throw StorageScanFailure.invalidOutput }
                } else { guard components.last == name, !components.isEmpty else { throw StorageScanFailure.invalidOutput } }
                whole = observed; matches = expected
                displaySource = UInt64(source); displayPath = components; truncated = clipped.boolValue
            } else { whole = nil; matches = nil; displaySource = nil; displayPath = nil; truncated = nil }
            if let old = rows.last {
                let a = old.value.bytes[metric], b = value.bytes[metric]
                let ordered = a.overflowed != b.overflowed ? !a.overflowed
                    : a.knownBytes != b.knownBytes ? (a.knownBytes ?? 0) > (b.knownBytes ?? 0) : old.id < id
                guard ordered else { throw StorageScanFailure.invalidOutput }
            }
            let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
            guard !overflow, sum <= total.counts.regularFiles else { throw StorageScanFailure.invalidOutput }; files = sum
            bytes.merge(value.bytes); rows.append(.init(id: id, name: name, value: value, whole: whole, matches: matches, displaySource: displaySource, displayPath: displayPath, truncated: truncated))
        }
        guard files == total.counts.regularFiles, bytes == total.bytes else { throw StorageScanFailure.invalidOutput }
        return .init(total: total, rows: rows, remainder: remainder, groupCount: count)
    }
}

extension StorageAnalysisResult {
    public func purposeProjects(_ role: AnalysisCategory, metric: AnalysisByteMetric = .dataLogical) async throws -> StoredPurposeProjects {
        guard supportsPurposeJourney else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("purpose-projects-v1", cursor: UInt64(metric.rawValue), facet: 4, filterKey: UInt64(role.rawValue)), role: role, metric: metric)
    }
    public func purposeLocations(role: AnalysisCategory, project: UInt64, metric: AnalysisByteMetric = .dataLogical) async throws -> StoredPurposeLocations {
        guard supportsPurposeJourney, project < Int64.max else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("purpose-locations-v1", parent: project, cursor: UInt64(metric.rawValue), facet: 4, filterKey: UInt64(role.rawValue)), role: role, project: project, metric: metric, startup: isStartupPairForQueries)
    }
}
