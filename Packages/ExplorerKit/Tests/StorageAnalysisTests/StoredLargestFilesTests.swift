import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StoredLargestFilesTests {
    private func row(_ id: UInt64, _ name: Data, _ size: UInt64?, path: Data? = nil, source: Int = 0) -> [String: Any] {
        var payload = Data(repeating: 0, count: 52)
        if let size {
            for m in 0..<4 { payload[m * 13] = 1; for b in 0..<8 { payload[m * 13 + b + 1] = UInt8((size >> ((7 - b) * 8)) & 255) } }
        }
        return ["id": String(id), "name": name.base64EncodedString(), "payload": payload.base64EncodedString(),
            "path": (path ?? name).base64EncodedString(), "source": source]
    }
    private func end(_ count: Int, known: UInt64? = nil, unknown: UInt64 = 0,
                     metric: AnalysisLargestFileMetric = .logical, startup: Bool = false) -> [String: Any] {
        ["kind": "largest_end", "largest_files_revision": 1, "metric": metric.byteMetric.rawValue, "count": count,
            "rankable": String(known ?? UInt64(count)), "unknown": String(unknown), "startup": startup]
    }
    private func decode(_ rows: [[String: Any]], _ last: [String: Any],
                        metric: AnalysisLargestFileMetric = .logical, startup: Bool = false) throws -> StoredLargestFiles {
        let chunks: [[String: Any]] = stride(from: 0, to: rows.count, by: 4).map { ["kind": "largest_rows", "rows": Array(rows[$0..<min($0 + 4, rows.count)])] }
        return try .decode(chunks + [last], metric: metric, startup: startup)
    }
    @Test func unsignedTiesZeroRawNamesAndIndependentUnknownCount() throws {
        let rows = [row(8, Data([65]), .max, path: Data("First/A".utf8)),
            row(9, Data([65]), .max, path: Data("Other/A".utf8)), row(3, Data([255]), 0)]
        let result = try decode(rows, end(3, unknown: 4))
        #expect(result.files.map(\.id) == [8, 9, 3]); #expect(result.unknownSizeFileNames == 4)
        #expect(result.files[2].rawRelativePath == Data([255])); #expect(result.files[2].recordedFolder == "Analysis root")
        #expect(throws: StorageScanFailure.self) { try decode(Array(rows.reversed()), end(3)) }
        #expect(throws: StorageScanFailure.self) { try decode([rows[0], rows[0]], end(2)) }
        #expect(throws: StorageScanFailure.self) { try decode([row(1, Data([65]), 1), row(2, Data([65]), 1)], end(2)) }
        #expect(throws: StorageScanFailure.self) { try decode([row(1, Data([97]), nil)], end(1)) }
    }
    @Test func exactLimitKnownRemainderAndTruncationRefusal() throws {
        let rows = (1...32).map { row(UInt64($0), Data(String(format: "file-%03d", $0).utf8), 1) }
        #expect(try decode(rows, end(32, known: 99)).files.count == 32)
        #expect(throws: StorageScanFailure.self) { try decode(Array(rows.dropLast()), end(31, known: 99)) }
        #expect(throws: StorageScanFailure.self) { try decode(rows + [row(33, Data("z".utf8), 0)], end(33)) }
        #expect(throws: StorageScanFailure.self) { try decode([], end(0, known: .max, unknown: 1)) }
        #expect(try decode([], end(0, unknown: 5)).files.isEmpty)
    }
    @Test func sourcePathMetricAndRealJSONTypesAreBound() throws {
        let rows = [row(4, Data("file".utf8), 9, path: Data("Folder/file".utf8), source: 1)]
        let frames: [[String: Any]] = [["kind": "largest_rows", "rows": rows], end(1, metric: .allocated, startup: true)]
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: frames)) as! [[String: Any]]
        let result = try StoredLargestFiles.decode(json, metric: .allocated, startup: true)
        #expect(result.files[0].recordedFolder == "Data / Folder")
        #expect(try decode([row(4, Data("file".utf8), 9, path: Data("Folder/file".utf8), source: 2)],
            end(1, startup: true), startup: true).files[0].recordedFolder == "System / Folder")
        #expect(throws: StorageScanFailure.self) { try StoredLargestFiles.decode(json, metric: .logical, startup: true) }
        #expect(throws: StorageScanFailure.self) { try StoredLargestFiles.decode(json, metric: .allocated, startup: false) }
        for path in ["/file", "Folder/../file", "Folder//file", "Folder/other", "./file", "file/"] {
            #expect(throws: StorageScanFailure.self) { try decode([row(4, Data("file".utf8), 1, path: Data(path.utf8))], end(1)) }
        }
        for key in ["count", "metric", "largest_files_revision", "startup"] {
            var invalid = end(1); invalid[key] = key == "startup" ? 1 as Any : true as Any
            #expect(throws: StorageScanFailure.self) { try decode([row(4, Data("file".utf8), 1)], invalid) }
        }
    }
    @Test func longStoredPathsAreBoundedAndNoHelperMeansNoCapability() throws {
        let parts = Array(repeating: String(repeating: "x", count: 250), count: 32) + ["file"]
        let path = Data(parts.joined(separator: "/").utf8)
        #expect(try decode([row(3, Data("file".utf8), 1, path: path)], end(1)).files[0].rawRelativePath == path)
        #expect(throws: StorageScanFailure.self) { try decode([row(3, Data("file".utf8), 1, path: Data((Array(repeating: "x", count: 65) + ["file"]).joined(separator: "/").utf8))], end(1)) }
        let header: [String: Any] = ["schema": 11, "policy_revision": "local-metadata-v1", "classification_revision": 3, "profile": "full-result-classification-v3"]
        #expect(try AnalysisPolicyBinding(header: header, startup: false, policy: .standard, classificationRevision: .v3).largestFilesRevision == nil)
        for wrong: Any in [true, "1", 2] {
            var invalid = header; invalid["sorted_page_revision"] = 1; invalid["largest_files_revision"] = wrong
            #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: invalid, startup: false, policy: .standard, classificationRevision: .v3) }
        }
        var valid = header; valid["sorted_page_revision"] = 1; valid["largest_files_revision"] = 1
        #expect(try AnalysisPolicyBinding(header: valid, startup: false, policy: .standard, classificationRevision: .v3).largestFilesRevision == 1)
    }
    @Test func maximumResponseHasThirtyTwoExactLimitPathsWithoutWideningOtherQueries() throws {
        let parents = (["a"] + Array(repeating: String(repeating: "b", count: 255), count: 31)).joined(separator: "/")
        let rows = (0..<32).map { index -> [String: Any] in
            let name = String(repeating: "c", count: 252) + String(format: "%02d", index)
            let path = Data((parents + "/" + name).utf8)
            #expect(path.count == 8192)
            return row(UInt64(index + 1), Data(name.utf8), 1, path: path)
        }
        let result = try decode(rows, end(32))
        #expect(result.files.count == 32)
        #expect(result.files.allSatisfy { $0.rawRelativePath.count == 8192 })
        let chunks: [[String: Any]] = stride(from: 0, to: 32, by: 4).map { ["kind": "largest_rows", "rows": Array(rows[$0..<($0 + 4)])] }
        #expect(try JSONSerialization.data(withJSONObject: chunks + [end(32)]).count < 512 << 10)
        var invalid = rows[0]
        invalid["path"] = Data((parents + "/" + String(repeating: "c", count: 255)).utf8).base64EncodedString()
        #expect(throws: StorageScanFailure.self) { try decode([invalid], end(1)) }
    }
}
