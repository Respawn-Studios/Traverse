import Foundation
import Testing
@testable import StorageAnalysis

private func packed(_ value: UInt64) -> Data {
    Data((0..<8).map { UInt8(truncatingIfNeeded: value >> ((7 - $0) * 8)) })
}

@Suite struct StoredAnalysisTests {
    @Test func projectChartsEnterTheSelectedProjectAndRetainItsFilter() throws {
        let zero = try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))
        let project = StoredAnalysisGroup(id: 38, rawName: Data("Nomad-DB".utf8), value: zero)
        let groups = StoredAnalysisGroups(facet: .projects, groups: [project], remainder: zero, groupCount: 1, projectCount: 1)
        let slice = try #require(groups.attributionSlices(scopeName: "Drive").first)
        #expect(slice.title == "Nomad-DB")
        #expect(slice.storedTarget == .filtered(folder: 37, facet: .projects, key: 38))
        let target = try #require(slice.storedTarget)
        let encoded = Data(repeating: 0, count: 140).base64EncodedString()
        let frame: [String: Any] = ["kind": "breakdown", "metric": 0, "filter_facet": 5, "filter_key": "38", "parent": "37",
            "value": encoded, "remainder": encoded, "rows": [[String: Any]]()]
        let breakdown = try StoredAnalysisBreakdown.decode([frame], target: target, metric: .dataLogical)
        #expect(breakdown.target(for: 101) == .filtered(folder: 101, facet: .projects, key: 38))
        for (facet, key) in [(StoredAnalysisFacet.fileTypes, UInt64(13)), (.storageRoles, 5), (.projects, 0)] {
            let group = StoredAnalysisGroup(id: key, rawName: Data(), value: zero)
            let other = StoredAnalysisGroups(facet: facet, groups: [group], remainder: zero, groupCount: 1, projectCount: 0)
            #expect(other.attributionSlices(scopeName: "Drive").first?.storedTarget == .filtered(folder: 0, facet: facet, key: key))
        }
    }
    @Test func filteredResponsesBindParentFacetKeyAndMetric() throws {
        let zero = Data(repeating: 0, count: 140).base64EncodedString()
        let target = StoredAnalysisDrillTarget.filtered(folder: 7, facet: .fileTypes, key: 0)
        let frame: [String: Any] = ["kind": "breakdown", "metric": 0, "filter_facet": 3, "filter_key": "0", "parent": "7", "value": zero, "remainder": zero, "rows": [[String: Any]]()]
        #expect(try StoredAnalysisBreakdown.decode([frame], target: target, metric: .dataLogical).filter == target)
        for (key, value) in [("parent", "8" as Any), ("filter_facet", 4 as Any), ("filter_key", "1" as Any), ("metric", true as Any)] {
            var invalid = frame; invalid[key] = value
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisBreakdown.decode([invalid], target: target, metric: .dataLogical) }
        }
        var missing = frame; missing.removeValue(forKey: "filter_key")
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisBreakdown.decode([missing], target: target, metric: .dataLogical) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisBreakdown.decode([frame], target: .folder(7), metric: .dataLogical) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisBreakdown.decode([frame], target: .filtered(folder: 7, facet: .fileTypes, key: UInt64.max), metric: .dataLogical) }
    }
    @Test func childTargetsRetainTheSelectedClassification() throws {
        let value = try StoredAnalysisValue(encoded: Data(repeating: 0, count: 140))
        for facet in StoredAnalysisFacet.allCases {
            let target = StoredAnalysisDrillTarget.filtered(folder: 7, facet: facet, key: 0)
            let breakdown = StoredAnalysisBreakdown(rankingMetric: .dataLogical, value: value, rows: [], remainder: value, filter: target)
            #expect(breakdown.target(for: 42) == .filtered(folder: 42, facet: facet, key: 0))
        }
        let plain = StoredAnalysisBreakdown(rankingMetric: .dataLogical, value: value, rows: [], remainder: value, filter: nil)
        #expect(plain.target(for: 42) == .folder(42))
    }
    @Test func storedMetricsDoNotConflateReturnedZeroMissingErrorAndOverflow() throws {
        var data = Data(repeating: 0, count: 140)
        data[7] = 3
        for metric in 0..<4 {
            let start = 40 + metric * 25
            data.replaceSubrange(start..<(start + 8), with: packed(metric == 3 ? 0 : UInt64.max))
            data[start + 15] = 1; data[start + 23] = 1
            if metric == 3 { data[start + 24] = 1 }
        }
        let value = try StoredAnalysisValue(encoded: data)
        #expect(value.counts.regularFiles == 3)
        #expect(value.bytes.dataLogical.knownBytes == UInt64.max)
        #expect(value.bytes.dataLogical.notReturnedCount == 1)
        #expect(value.bytes.dataLogical.failedCount == 1)
        #expect(value.bytes.allForkAllocated.knownBytes == nil)
        #expect(value.bytes.allForkAllocated.overflowed)
        data[64] = 1 // Nonzero byte sum cannot accompany an overflow state.
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisValue(encoded: data) }
    }

    @Test func malformedSupportAndNamespaceCountsCannotTrapOrInventAnEmptyResult() {
        var data = Data(repeating: 0, count: 140)
        data.replaceSubrange(0..<8, with: packed(UInt64.max))
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisValue(encoded: data) }
        data = Data(repeating: 0, count: 140); data[7] = 1; data[55] = 1; data[63] = 1
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisValue(encoded: data) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisValue(encoded: Data(repeating: 0, count: 139)) }
    }

    @Test func storedOwnMetadataAgreesWithAccumulatorForEachFieldStateAndKind() throws {
        for kind in 0..<5 {
            for state: UInt8 in [0, 1, 2] {
                var payload = Data()
                for _ in 0..<4 {
                    payload.append(state); payload.append(packed(state == 1 ? 0 : 0))
                    payload.append(contentsOf: state == 2 ? [0, 0, 0, 13] : [0, 0, 0, 0])
                }
                let value = try StoredAnalysisValue(kind: kind, payload: payload)
                #expect(value.counts.total == 1)
                for metric in AnalysisByteMetric.allCases {
                    #expect(value.bytes[metric].knownBytes == 0)
                    #expect(value.bytes[metric].notReturnedCount == (kind == 0 && state == 0 ? 1 : 0))
                    #expect(value.bytes[metric].failedCount == (kind == 0 && state == 2 ? 1 : 0))
                }
            }
        }
    }

    @Test func storedProtocolRejectsNoncanonicalNumbersAndBase64() throws {
        for value: Any in ["01", "-1", "+1", " 1", "18446744073709551616", 1, true, NSNull()] {
            #expect(throws: StorageScanFailure.self) { try storedNumber(value) }
        }
        #expect(try storedNumber("18446744073709551615") == UInt64.max)
        for text in ["YQ", "YQ==\n", "YR==", "not-base64"] {
            #expect(throws: StorageScanFailure.self) { try storedBlob(text) }
        }
        #expect(try storedBlob("YQ==") == Data([97]))
    }

    @Test func temporaryStorageLimitsAreSeparateFromSourceAuthority() throws {
        let directory = URL(fileURLWithPath: "/Generated/ResultPool", isDirectory: true)
        let full = try AnalysisResultStorage(directory: directory)
        #expect(full.sessionByteLimit == 2 << 30 && full.poolByteLimit == 8 << 30)
        #expect(throws: StorageScanFailure.self) { try AnalysisResultStorage(directory: directory, sessionByteLimit: (2 << 30) + 1) }
        #expect(throws: StorageScanFailure.self) { try AnalysisResultStorage(directory: directory, poolByteLimit: (8 << 30) + 1) }
        #expect(throws: StorageScanFailure.self) { try AnalysisResultStorage(directory: directory, poolByteLimit: 128 << 20) }
        #expect(throws: StorageScanFailure.self) { try AnalysisResultStorage(directory: URL(string: "https://example.com")!) }
    }
    @Test func liveStoreReservesItsFutureGrowthAndClosedFailuresStayFullyCharged() {
        #expect(AnalysisStoreFiles.poolCharge(0, leased: true) == 2 << 30)
        #expect(AnalysisStoreFiles.poolCharge(12 << 20, leased: false) == 12 << 20)
        #expect(AnalysisStoreFiles.poolCharge(600 << 20, leased: true) == 2 << 30)
        #expect(AnalysisStoreFiles.poolCharge(3 << 30, leased: true) == 3 << 30)
    }
}
