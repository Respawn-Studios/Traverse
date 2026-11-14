import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StoredAnalysisPageTests {
    private func row(_ id: UInt64, _ bytes: [UInt8]) -> [String: Any] {
        ["id": String(id), "name": Data(bytes).base64EncodedString(), "type": 0,
         "payload": Data(repeating: 0, count: 52).base64EncodedString(), "value": NSNull()]
    }
    private func end(_ count: Int, parent: UInt64 = 0, cursor: UInt64 = 0, previous: [UInt8] = []) -> [String: Any] {
        ["kind": "end", "count": count, "order": "raw_name", "parent": String(parent),
         "after": String(cursor), "after_name": Data(previous).base64EncodedString()]
    }
    @Test func filenameOrderKeepsNonUTF8AndNonmonotonicIDs() throws {
        let values = [row(9, [65]), row(2, [97]), row(7, [97, 255]), row(1, [255])]
        let decoded = try StoredAnalysisPage.decode([["kind": "rows", "rows": values], end(4)], parent: 0, cursor: 0, order: .rawName)
        #expect(decoded.map(\.id) == [9, 2, 7, 1])
        #expect(decoded.last?.rawName == Data([255]))
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([["kind": "rows", "rows": values], ["kind": "end", "count": 4]], parent: 0, cursor: 0, order: .ordinal) }
    }
    @Test func cursorContextAndPreviousNameAreRequired() throws {
        let rows: [String: Any] = ["kind": "rows", "rows": [row(3, [98])]]
        _ = try StoredAnalysisPage.decode([rows, end(1, parent: 1, cursor: 2, previous: [97])], parent: 1, cursor: 2, order: .rawName)
        for bad in [end(1, parent: 9, cursor: 2, previous: [97]), end(1, parent: 1, cursor: 8, previous: [97]),
                    end(1, parent: 1, cursor: 2), end(1, parent: 1, cursor: 2, previous: [98]),
                    end(1, parent: 1, cursor: 2, previous: [99]), end(1, parent: 1, cursor: 2, previous: [47])] {
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([rows, bad], parent: 1, cursor: 2, order: .rawName) }
        }
    }
    @Test func duplicatesReorderingTruncationAndOversizedFramesRefuse() {
        for values in [[row(1, [98]), row(2, [97])], [row(1, [97]), row(1, [98])],
                       [row(1, [97]), row(2, [97])], [row(1, [46])], [row(0, [97])], [row(1, [0])]] {
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([["kind": "rows", "rows": values], end(values.count)], parent: 0, cursor: 0, order: .rawName) }
        }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([["kind": "rows", "rows": [row(1, [97])]]], parent: 0, cursor: 0, order: .rawName) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([end(0), end(0)], parent: 0, cursor: 0, order: .rawName) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([["kind": "rows", "rows": (1...65).map { row(UInt64($0), [UInt8($0 + 48)]) }], end(65)], parent: 0, cursor: 0, order: .rawName) }
    }
    @Test func oldOrdinalContractStillWorks() throws {
        let rows: [String: Any] = ["kind": "rows", "rows": [row(3, [122]), row(4, [97])]]
        _ = try StoredAnalysisPage.decode([rows, ["kind": "end", "count": 2]], parent: 1, cursor: 2, order: .ordinal)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisPage.decode([rows, end(2)], parent: 1, cursor: 2, order: .rawName) }
    }
}
