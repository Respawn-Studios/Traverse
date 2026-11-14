import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StoredSortedPageTests {
    private func row(_ id: UInt64, name: Data, size: UInt64?, kind: Int = 0) -> [String: Any] {
        var payload = Data(repeating: 0, count: 52)
        if let size {
            for metric in 0..<4 {
                payload[metric * 13] = 1
                for byte in 0..<8 { payload[metric * 13 + byte + 1] = UInt8((size >> ((7 - byte) * 8)) & 255) }
            }
        }
        return ["id": String(id), "name": name.base64EncodedString(), "type": kind,
                "payload": payload.base64EncodedString(), "value": NSNull()]
    }
    private func end(_ count: Int, order: StoredAnalysisSortOrder = .logicalDescending, more: Bool = false,
                     parent: UInt64 = 0, cursor: UInt64 = 0, name: Data = Data(), size: UInt64? = nil, unknown: Bool = false) -> [String: Any] {
        ["kind": "end", "count": count, "sorted_page_revision": 1, "order": order.wireName,
         "parent": String(parent), "after": String(cursor), "after_name": name.base64EncodedString(),
         "after_bytes": size.map { String($0) as Any } ?? NSNull(), "after_unknown": unknown, "has_more": more]
    }
    private func decode(_ values: [[String: Any]], _ end: [String: Any], order: StoredAnalysisSortOrder = .logicalDescending,
                        parent: UInt64 = 0, cursor: UInt64 = 0) throws -> StoredAnalysisSortedPage {
        try .decode((values.isEmpty ? [] : [["kind": "rows", "rows": values]]) + [end], parent: parent, cursor: cursor, order: order)
    }
    @Test func sizeOrderKeepsUnsignedValuesTiesZeroAndUnknownDistinct() throws {
        let values = [row(2, name: Data("a".utf8), size: .max), row(1, name: Data("z".utf8), size: .max),
            row(7, name: Data("mid".utf8), size: 9), row(4, name: Data("zero".utf8), size: 0), row(8, name: Data("unknown".utf8), size: nil)]
        #expect(try decode(values, end(5)).rows.map(\.id) == [2, 1, 7, 4, 8])
        let ascending = [values[3], values[2], values[0], values[1], values[4]]
        #expect(try decode(ascending, end(5, order: .logicalAscending), order: .logicalAscending).rows.map(\.id) == [4, 7, 2, 1, 8])
        #expect(throws: StorageScanFailure.self) { try decode(values.reversed(), end(5)) }
        #expect(throws: StorageScanFailure.self) { try decode([values[1], values[0]], end(2)) }
    }
    @Test func actualJSONNumericBooleansAndUInt64StringsRoundTrip() throws {
        let frames: [[String: Any]] = [["kind": "rows", "rows": [row(2, name: Data("a".utf8), size: 256)]], end(1)]
        let encoded = try JSONSerialization.data(withJSONObject: frames)
        let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(try StoredAnalysisSortedPage.decode(decoded, parent: 0, cursor: 0, order: .logicalDescending).rows.count == 1)
    }
    @Test func nameOrderIsLosslessAndIndependentOfIDsAndAmounts() throws {
        let values = [row(9, name: Data([65]), size: 0), row(2, name: Data([97]), size: 100), row(7, name: Data([255]), size: nil)]
        let ascending = try decode(values, end(3, order: .nameAscending), order: .nameAscending)
        #expect(ascending.rows.last?.rawName == Data([255]))
        #expect(try decode(Array(values.reversed()), end(3, order: .nameDescending), order: .nameDescending).rows.map(\.id) == [7, 2, 9])
        #expect(throws: StorageScanFailure.self) { try decode(values, end(3, order: .nameDescending), order: .nameDescending) }
        #expect(throws: StorageScanFailure.self) { try decode([row(1, name: Data([65]), size: 1), row(2, name: Data([65]), size: 1)], end(2)) }
    }
    @Test func cursorOrderParentAndRankAreBoundAndMissingIsNotZero() throws {
        let values = [row(3, name: Data("c".utf8), size: 7)]
        let valid = end(1, parent: 1, cursor: 2, name: Data("b".utf8), size: 8)
        #expect(try decode(values, valid, parent: 1, cursor: 2).rows.count == 1)
        for (key, wrong) in [("parent", "9" as Any), ("after", "4" as Any), ("order", "allocated_descending" as Any),
                             ("after_bytes", "6" as Any), ("after_bytes", NSNull() as Any), ("after_unknown", true as Any),
                             ("after_name", Data("/".utf8).base64EncodedString() as Any)] {
            var invalid = valid; invalid[key] = wrong
            #expect(throws: StorageScanFailure.self) { try decode(values, invalid, parent: 1, cursor: 2) }
        }
        #expect(throws: StorageScanFailure.self) { try decode(values, end(1, parent: 1, cursor: 2, name: Data("a".utf8), unknown: true), parent: 1, cursor: 2) }
    }
    @Test func revisionsBooleansAndStartCursorAreStrict() throws {
        let values = [row(1, name: Data([97]), size: 1)]
        for (key, wrong) in [("sorted_page_revision", true as Any), ("sorted_page_revision", 2 as Any), ("count", true as Any),
                             ("has_more", 1 as Any), ("after_unknown", 0 as Any), ("after_bytes", "0" as Any),
                             ("after_name", Data([97]).base64EncodedString() as Any), ("has_more", true as Any)] {
            var invalid = end(1); invalid[key] = wrong
            #expect(throws: StorageScanFailure.self) { try decode(values, invalid) }
        }
    }
    @Test func exactFullPageCanHaveNoSuccessorAndTruncationRefuses() throws {
        let values = (1...256).map { row(UInt64($0), name: Data(String(format: "file-%04d", $0).utf8), size: 1) }
        let chunks: [[String: Any]] = stride(from: 0, to: values.count, by: 64).map { ["kind": "rows", "rows": Array(values[$0..<($0 + 64)])] }
        #expect(try StoredAnalysisSortedPage.decode(chunks + [end(256)], parent: 0, cursor: 0, order: .logicalDescending).hasMore == false)
        #expect(try StoredAnalysisSortedPage.decode(chunks + [end(256, more: true)], parent: 0, cursor: 0, order: .logicalDescending).hasMore)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisSortedPage.decode(chunks, parent: 0, cursor: 0, order: .logicalDescending) }
        #expect(throws: StorageScanFailure.self) { try decode([row(1, name: Data([97]), size: 1), row(1, name: Data([98]), size: 0)], end(2)) }
    }
    @Test func unsupportedObjectSizesRemainUnknownAndCapabilityIsOptional() throws {
        let known = row(9, name: Data("file".utf8), size: 0), link = row(2, name: Data("link".utf8), size: 999, kind: 2)
        #expect(try decode([known, link], end(2, order: .allocatedAscending), order: .allocatedAscending).rows.map(\.id) == [9, 2])
        let header: [String: Any] = ["schema": 11, "policy_revision": "local-metadata-v1", "classification_revision": 3, "profile": "full-result-classification-v3"]
        #expect(try AnalysisPolicyBinding(header: header, startup: false, policy: .standard, classificationRevision: .v3).sortedPageRevision == nil)
        for wrong: Any in [true, "1", 2] {
            var changed = header; changed["sorted_page_revision"] = wrong
            #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: changed, startup: false, policy: .standard, classificationRevision: .v3) }
        }
    }
}
