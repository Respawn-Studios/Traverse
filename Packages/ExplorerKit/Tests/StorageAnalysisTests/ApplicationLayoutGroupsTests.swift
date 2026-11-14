import Foundation
import Testing
@testable import StorageAnalysis

private func layoutValue(_ files: UInt64, _ amounts: [UInt64], missingLast: UInt64 = 0) -> String {
    var data = Data(repeating: 0, count: 140)
    func put(_ number: UInt64, _ offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: number >> (56 - index * 8)) }
    }
    put(files, 0)
    for index in 0..<4 { put(amounts[index], 40 + index * 25) }
    put(missingLast, 123)
    return data.base64EncodedString()
}
private func layoutFrame() -> [String: Any] {
    ["kind": "application_layouts", "layout_revision": 1, "classification_revision": 3,
     "value": layoutValue(2, [8, 17, 0, 11], missingLast: 1),
     "groups": [["key": "1", "name": "", "value": layoutValue(1, [3, 7, 0, 11])],
                ["key": "0", "name": "", "value": layoutValue(1, [5, 10, 0, 0], missingLast: 1)]],
     "remainder": layoutValue(0, [0, 0, 0, 0]), "total_groups": "2", "project_count": "0"]
}

@Suite struct ApplicationLayoutGroupsTests {
    @Test func exactPartitionsKeepAllMetricsAndStoredLayoutTargets() throws {
        let groups = try StoredAnalysisGroups.decodeApplicationLayouts([layoutFrame()])
        #expect(groups.facet == .applicationLayouts && groups.groups.count == 2)
        let first = try #require(groups.attributionSlices(scopeName: "Drive").first)
        #expect(first.title == AnalysisApplicationLayout.applicationBundle.title)
        #expect(first.storedTarget == .filtered(folder: 0, facet: .applicationLayouts, key: 1))
        let zero = try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))
        let breakdown = StoredAnalysisBreakdown(rankingMetric: .dataLogical, value: zero, rows: [], remainder: zero, filter: first.storedTarget)
        #expect(breakdown.target(for: 7) == .filtered(folder: 7, facet: .applicationLayouts, key: 1))
        #expect(groups.groups[1].value.bytes[.allForkAllocated].notReturnedCount == 1)
    }
    @Test func malformedRevisionsCountsNamesKeysAndPartitionsRefuse() throws {
        for (key, value) in [("kind", "groups" as Any), ("layout_revision", true as Any), ("layout_revision", 2 as Any),
                             ("classification_revision", 2 as Any), ("project_count", "1" as Any),
                             ("total_groups", "1" as Any), ("total_groups", String(UInt64.max) as Any),
                             ("value", layoutValue(2, [8, 17, 0, 12], missingLast: 1) as Any)] {
            var invalid = layoutFrame(); invalid[key] = value
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisGroups.decodeApplicationLayouts([invalid]) }
        }
        for (key, value) in [("key", "19"), ("name", Data("untrusted label".utf8).base64EncodedString()),
                             ("value", layoutValue(0, [0, 0, 0, 0])), ("value", layoutValue(1, [3, 7, 0, 11], missingLast: 1))] {
            var invalid = layoutFrame(), rows = try #require(invalid["groups"] as? [[String: Any]])
            rows[0][key] = value; invalid["groups"] = rows
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisGroups.decodeApplicationLayouts([invalid]) }
        }
        var duplicate = layoutFrame(); let row = try #require((duplicate["groups"] as? [[String: Any]])?.first)
        duplicate["groups"] = [row, row]
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisGroups.decodeApplicationLayouts([duplicate]) }
    }
    @Test func layoutCapabilityIsExplicitOptionalAndDoesNotChangeV3OrPolicyPrelude() throws {
        for startup in [false, true] {
            var header: [String: Any] = ["schema": startup ? 12 : 11,
                "profile": startup ? "startup-result-classification-v3" : "full-result-classification-v3",
                "policy_revision": AnalysisMetadataPolicy.standard.rawValue, "classification_revision": 3]
            let old = try AnalysisPolicyBinding(header: header, startup: startup, policy: .standard, classificationRevision: .v3)
            #expect(old.applicationLayoutRevision == nil)
            header["application_layout_revision"] = 1
            let current = try AnalysisPolicyBinding(header: header, startup: startup, policy: .standard, classificationRevision: .v3)
            #expect(current.applicationLayoutRevision == 1 && current.classificationRevision == .v3)
            for bad in [true as Any, 0 as Any, 2 as Any, "1" as Any, NSNull() as Any] {
                header["application_layout_revision"] = bad
                #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: header, startup: startup, policy: .standard, classificationRevision: .v3) }
            }
        }
    }
    @Test func everyNamedLayoutRemainsReachableBeyondThePieSliceLimit() throws {
        let rows: [[String: Any]] = (0..<19).map { ["key": String($0), "name": "", "value": layoutValue(1, [1, 1, 1, 1])] }
        let frame: [String: Any] = ["kind": "application_layouts", "layout_revision": 1, "classification_revision": 3,
            "value": layoutValue(19, [19, 19, 19, 19]), "groups": rows, "total_groups": "19", "project_count": "0",
            "remainder": layoutValue(0, [0, 0, 0, 0])]
        let all = try StoredAnalysisGroups.decodeApplicationLayouts([frame])
        #expect(all.groups.count == 19 && all.attributionSlices(scopeName: "Drive").allSatisfy { $0.storedTarget != nil })
        var invalid = frame
        invalid["remainder"] = layoutValue(0, [1, 1, 1, 1]); invalid["value"] = layoutValue(19, [20, 20, 20, 20])
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisGroups.decodeApplicationLayouts([invalid]) }
    }
}
