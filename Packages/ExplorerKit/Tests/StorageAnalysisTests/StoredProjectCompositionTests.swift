import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StoredProjectCompositionTests {
    private func value(_ files: UInt64, _ bytes: UInt64) -> String {
        var data = Data(repeating: 0, count: 140)
        func put(_ number: UInt64, _ offset: Int) {
            for i in 0..<8 { data[offset + i] = UInt8(truncatingIfNeeded: number >> ((7 - i) * 8)) }
        }
        put(files, 0)
        for offset in [40, 65, 90, 115] { put(bytes, offset) }
        return data.base64EncodedString()
    }
    private var target: StoredAnalysisDrillTarget { .filtered(folder: 9, facet: .projects, key: 10) }
    private func frame() -> [String: Any] {
        ["kind": "project-composition", "revision": 1, "classification_revision": 3, "metric": 0,
         "parent": "9", "project": "10", "value": value(2, 16),
         "file_types": [["key": "2", "value": value(1, 7)], ["key": "14", "value": value(1, 9)]],
         "roles": [["key": "1", "value": value(2, 16)]]]
    }
    @Test func twoPartitionsKeepExactScopeAndOfferSemanticLeaves() throws {
        let read = try StoredProjectComposition.decode([frame()], target: target, metric: .dataLogical)
        #expect(read.value.counts.regularFiles == 2)
        #expect(read.value.bytes.dataLogical.knownBytes == 16)
        #expect(read.fileTypes.count == 2 && read.storageRoles.count == 1)
        #expect(read.slices(.storageRoles).allSatisfy { $0.storedTarget == nil })
        #expect(read.slices(.projects).isEmpty)
        #expect(read.overview.filter == target)
    }
    @Test func foreignContractsAndInventedSubtotalsAreRefused() {
        for (key, wrong): (String, Any) in [("revision", 2), ("classification_revision", 2), ("metric", true), ("parent", "10"), ("project", "11")] {
            var data = frame(); data[key] = wrong
            #expect(throws: StorageScanFailure.self) { try StoredProjectComposition.decode([data], target: target, metric: .dataLogical) }
        }
        for bad: [[String: Any]] in [[[:]], [["key": "999", "value": value(2, 16)]], [["key": "1", "value": value(1, 16)]],
                                     [["key": "1", "value": value(2, 17)]], [["key": "1", "value": value(1, 8)], ["key": "1", "value": value(1, 8)]]] {
            var data = frame(); data["roles"] = bad
            #expect(throws: StorageScanFailure.self) { try StoredProjectComposition.decode([data], target: target, metric: .dataLogical) }
        }
        #expect(throws: StorageScanFailure.self) {
            try StoredProjectComposition.decode([frame()], target: .folder(9), metric: .dataLogical)
        }
    }
}
