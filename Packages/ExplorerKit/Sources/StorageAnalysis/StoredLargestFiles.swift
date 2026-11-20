import CoreFoundation
import Foundation

public enum AnalysisLargestFileMetric: Int, CaseIterable, Sendable {
    case logical, allocated
    public var title: String { self == .logical ? "Logical file size" : "Allocated data + resource forks" }
    var byteMetric: AnalysisByteMetric { self == .logical ? .dataLogical : .allForkAllocated }
    var order: StoredAnalysisSortOrder { self == .logical ? .logicalDescending : .allocatedDescending }
}

/// Stored metadata, never an URL, access grant or current-file identity proof.
public struct StoredLargestFile: Identifiable, Sendable {
    public let row: StoredAnalysisRow
    public let rawRelativePath: Data
    public let source: UInt64
    public var id: UInt64 { row.id }
    public var recordedFolder: String {
        let folder = rawRelativePath.split(separator: 47).dropLast().map { Data($0) }
        let path = String(data: folder.reduce(into: Data()) { value, part in
            if !value.isEmpty { value.append(47) }; value.append(part)
        }, encoding: .utf8) ?? "Folder name cannot be displayed as UTF-8"
        let sourceName = source == 1 ? "Data" : source == 2 ? "System" : "Analysis root"
        return path.isEmpty ? sourceName : sourceName + " / " + path
    }
}

public struct StoredLargestFiles: Sendable {
    public let metric: AnalysisLargestFileMetric
    public let files: [StoredLargestFile]
    public let rankableFileNames: UInt64
    public let unknownSizeFileNames: UInt64
    public let isStartupPair: Bool

    static func decode(_ frames: [[String: Any]], metric: AnalysisLargestFileMetric, startup: Bool, maximumPathComponents: Int = 64) throws -> Self {
        guard [64,128].contains(maximumPathComponents), (1...9).contains(frames.count), let end = frames.last,
              Set(end.keys) == ["kind", "largest_files_revision", "metric", "count", "rankable", "unknown", "startup"],
              end["kind"] as? String == "largest_end", strictInteger(end["largest_files_revision"]) == 1,
              strictInteger(end["metric"]) == metric.byteMetric.rawValue,
              let flag = end["startup"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue == startup,
              let count = strictInteger(end["count"]), (0...32).contains(count) else { throw StorageScanFailure.invalidOutput }
        let known = try storedNumber(end["rankable"]), unknown = try storedNumber(end["unknown"])
        let (total, overflow) = known.addingReportingOverflow(unknown)
        guard !overflow, total < Int64.max, UInt64(count) == min(32, known) else { throw StorageScanFailure.invalidOutput }
        var files: [StoredLargestFile] = [], ids = Set<UInt64>(), locations = Set<Data>()
        for frame in frames.dropLast() {
            guard Set(frame.keys) == ["kind", "rows"], frame["kind"] as? String == "largest_rows",
                  let rows = frame["rows"] as? [[String: Any]], (1...4).contains(rows.count), files.count + rows.count <= count else {
                throw StorageScanFailure.invalidOutput
            }
            for encoded in rows {
                guard Set(encoded.keys) == ["id", "name", "payload", "source", "path"] else { throw StorageScanFailure.invalidOutput }
                let id = try storedNumber(encoded["id"]), name = try storedBlob(encoded["name"])
                guard id > (startup ? 2 : 0), id < Int64.max, ids.insert(id).inserted, StoredAnalysisPage.validName(name),
                      let source = strictInteger(encoded["source"]), startup ? (1...2).contains(source) : source == 0,
                      let pathText = encoded["path"] as? String, pathText.utf8.count <= 10_924,
                      let path = Data(base64Encoded: pathText), path.base64EncodedString() == pathText,
                      !path.isEmpty, path.count <= 8192, path.first != 47, path.last != 47, !path.contains(0) else {
                    throw StorageScanFailure.invalidOutput
                }
                let components = path.split(separator: 47, omittingEmptySubsequences: false)
                guard components.count <= maximumPathComponents, let basename = components.last, basename.elementsEqual(name),
                      components.allSatisfy({ StoredAnalysisPage.validName(Data($0)) }) else { throw StorageScanFailure.invalidOutput }
                var location = Data([UInt8(source)]); location.append(path)
                guard locations.insert(location).inserted else { throw StorageScanFailure.invalidOutput }
                let value = try StoredAnalysisValue(kind: 0, payload: storedBlob(encoded["payload"], length: 52))
                let size = value.bytes[metric.byteMetric]
                guard size.knownBytes != nil, !size.overflowed, size.notReturnedCount == 0, size.failedCount == 0 else {
                    throw StorageScanFailure.invalidOutput
                }
                let row = StoredAnalysisRow(id: id, rawName: name, kind: .regularFile, value: value)
                if let previous = files.last {
                    guard metric.order.precedes(metric.order.key(previous.row), metric.order.key(row)) else { throw StorageScanFailure.invalidOutput }
                }
                files.append(.init(row: row, rawRelativePath: path, source: UInt64(source)))
            }
        }
        guard files.count == count else { throw StorageScanFailure.invalidOutput }
        return .init(metric: metric, files: files, rankableFileNames: known, unknownSizeFileNames: unknown, isStartupPair: startup)
    }
}

extension StorageAnalysisResult {
    public var supportsLargestFiles: Bool { largestFilesRevision == 1 }
    public func largestFiles(metric: AnalysisLargestFileMetric = .logical) async throws -> StoredLargestFiles {
        guard supportsLargestFiles else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("largest-files", facet: metric.rawValue), metric: metric, startup: isStartupPairForQueries,
            maximumPathComponents: maximumPathComponentsForQueries)
    }
}
