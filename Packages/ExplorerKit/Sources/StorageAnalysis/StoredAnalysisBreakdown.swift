import Foundation

public enum StoredAnalysisDrillTarget: Hashable, Sendable {
    case folder(UInt64)
    case steamLibraries
    case filtered(folder: UInt64, facet: StoredAnalysisFacet, key: UInt64)

    fileprivate func request(classificationRevision: AnalysisClassificationRevision = .v3) throws -> (parent: UInt64, facet: Int, filterKey: UInt64?) {
        let parent: UInt64, facet: Int, filterKey: UInt64?
        switch self {
        case .folder(let id): parent = id; facet = 0; filterKey = nil
        case .steamLibraries: parent = 9; facet = 1; filterKey = nil
        case .filtered(let id, let filter, let key):
            parent = id; facet = filter.rawValue + 3; filterKey = key
            guard key < Int64.max, filter != .fileTypes || key < classificationRevision.fileTypes.count,
                  filter != .storageRoles || key < AnalysisCategory.allCases.count,
                  filter != .applicationLayouts || key < AnalysisApplicationLayout.allCases.count else { throw StorageScanFailure.invalidOutput }
        }
        guard parent < Int64.max else { throw StorageScanFailure.invalidOutput }
        return (parent, facet, filterKey)
    }
}
public struct StoredAnalysisBreakdownRow: Identifiable, Sendable {
    public let folder: UInt64?
    public let rawName: Data
    public let hint: Int
    public let value: StoredAnalysisValue
    public var id: String { folder.map { "folder-" + String($0) } ?? "direct" }
    public var title: String {
        switch hint {
        case 1: "Installed items (games or tools)"
        case 2: "Workshop"
        case 3: "Downloads / staging"
        case 4: "Shader cache"
        case 5: "Workshop items"
        case 6: "Files directly in this folder"
        default: String(data: rawName, encoding: .utf8) ?? "Name is not UTF-8"
        }
    }
    public var explanation: String {
        hint == 0 || hint == 6 ? "Stored directory/namespace observation; not exclusive physical storage or cleanup authority."
            : "Conventional directory-name hint only. Installation manifests and file bodies were not read; active use and cleanup safety are unknown."
    }
}
public struct StoredAnalysisBreakdown: Sendable {
    public let rankingMetric: AnalysisByteMetric
    public let value: StoredAnalysisValue
    public let rows: [StoredAnalysisBreakdownRow]
    public let remainder: StoredAnalysisValue
    public let filter: StoredAnalysisDrillTarget?
    public func target(for folder: UInt64) -> StoredAnalysisDrillTarget {
        if case .filtered(_, let facet, let key) = filter { return .filtered(folder: folder, facet: facet, key: key) }
        return .folder(folder)
    }
}

extension StorageAnalysisResult {
    /// Twelve ranked folders, one direct-files bucket and an exact remainder.
    /// Querying this immutable catalog never walks or opens a source again.
    public func breakdown(_ target: StoredAnalysisDrillTarget, metric: AnalysisByteMetric = .dataLogical) async throws -> StoredAnalysisBreakdown {
        if case .filtered(_, .applicationLayouts, _) = target, !supportsApplicationLayouts { throw StorageScanFailure.invalidOutput }
        let request = try target.request(classificationRevision: classificationRevision)
        let frames = try await query("breakdown", parent: request.parent, cursor: UInt64(metric.rawValue), facet: request.facet, filterKey: request.filterKey)
        return try StoredAnalysisBreakdown.decode(frames, target: target, metric: metric, classificationRevision: classificationRevision)
    }
}

extension StoredAnalysisBreakdown {
    static func decode(_ frames: [[String: Any]], target: StoredAnalysisDrillTarget, metric: AnalysisByteMetric,
                       classificationRevision: AnalysisClassificationRevision = .v3) throws -> Self {
        let (parent, facet, filterKey) = try target.request(classificationRevision: classificationRevision)
        guard frames.count == 1, let frame = frames.first, frame["kind"] as? String == "breakdown",
              strictInteger(frame["metric"]) == metric.rawValue,
              let children = frame["rows"] as? [[String: Any]], children.count <= 13 else { throw StorageScanFailure.invalidOutput }
        if let filterKey {
            guard strictInteger(frame["filter_facet"]) == facet, try storedNumber(frame["filter_key"]) == filterKey,
                  try storedNumber(frame["parent"]) == parent else { throw StorageScanFailure.invalidOutput }
        } else if frame["filter_key"] != nil || frame["filter_facet"] != nil { throw StorageScanFailure.invalidOutput }
        let total = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        let remainder = try StoredAnalysisValue(encoded: storedBlob(frame["remainder"], length: 140))
        var rows: [StoredAnalysisBreakdownRow] = [], ids = Set<String>()
        var files = remainder.counts.regularFiles, bytes = remainder.bytes
        for child in children {
            let id = child["folder"] is NSNull ? nil : try storedNumber(child["folder"])
            let name = try storedBlob(child["name"])
            guard let hint = strictInteger(child["hint"]), (0...6).contains(hint), name.count <= 255,
                  !name.contains(0), !name.contains(47), name != Data([46]), name != Data([46, 46]),
                  id == nil ? hint == 6 && name.isEmpty : id! < Int64.max else { throw StorageScanFailure.invalidOutput }
            let value = try StoredAnalysisValue(encoded: storedBlob(child["value"], length: 140))
            let row = StoredAnalysisBreakdownRow(folder: id, rawName: name, hint: hint, value: value)
            guard ids.insert(row.id).inserted else { throw StorageScanFailure.invalidOutput }
            let (sum, overflow) = files.addingReportingOverflow(value.counts.regularFiles)
            guard !overflow, sum <= total.counts.regularFiles else { throw StorageScanFailure.invalidOutput }; files = sum
            bytes.merge(value.bytes); rows.append(row)
        }
        guard files == total.counts.regularFiles, bytes == total.bytes else { throw StorageScanFailure.invalidOutput }
        return .init(rankingMetric: metric, value: total, rows: rows, remainder: remainder, filter: filterKey == nil ? nil : target)
    }
}
