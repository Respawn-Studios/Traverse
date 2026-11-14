import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct CommittedAnalysisPrefixTests {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func encoded(_ count: UInt64, bytes: UInt64) -> String {
        var data = Data(repeating: 0, count: 140)
        func put(_ n: UInt64, _ at: Int) { for i in 0..<8 { data[at+i] = UInt8(truncatingIfNeeded: n >> ((7-i)*8)) } }
        put(count, 0); for i in 0..<4 { put(bytes, 40+i*25) }; return data.base64EncodedString()
    }
    private func frame(count: UInt64 = 1024, bytes: UInt64 = 10, elapsed: UInt64 = 300_000_000, sequence: UInt64 = 2) -> [String: Any] {
        let value = encoded(count, bytes: bytes), zero = encoded(0, bytes: 0)
        return ["kind": "committed_totals", "schema": 9, "prefix_revision": 1, "policy_revision": AnalysisMetadataPolicy.standard.rawValue,
            "session": session.uuidString, "seq": String(sequence), "committed": String(count), "elapsed_ns": String(elapsed), "value": value,
            "types": (0..<15).map { ["id": $0, "value": $0 == 0 ? value : zero] as [String: Any] }]
    }
    private func decode(_ frame: [String: Any], count: UInt64 = 1024, previous: CommittedAnalysisPrefix? = nil) throws -> CommittedAnalysisPrefix {
        try .decode(frame, session: session, policy: .standard, wireSchema: 9, committed: count, previous: previous)
    }
    @Test func exactBoundedPartitionAndGrowingPrefix() throws {
        let first = try decode(frame())
        #expect(first.entries == 1024 && first.fileTypes.count == 15 && first.value.bytes.dataLogical.knownBytes == 10)
        let display = first.attributionReport()
        #expect(display.isProvisional && !display.isComplete && !display.hasLayoutAttribution)
        #expect(display.fileTypes.count == 15 && display.categories.isEmpty && display.projects.isEmpty)
        #expect(display.fileTypes.allSatisfy { $0.folder == nil && $0.storedTarget == nil })
        let next = try decode(frame(count: 2048, bytes: 20, elapsed: 600_000_000, sequence: 4), count: 2048, previous: first)
        #expect(next.entries == 2048 && first.entries == 1024)
    }
    @Test func sessionPolicySchemaAndRevisionCannotChange() throws {
        for (key, value) in [("session", UUID().uuidString as Any), ("policy_revision", AnalysisMetadataPolicy.applicationData.rawValue as Any),
            ("schema", 10 as Any), ("prefix_revision", 2 as Any), ("prefix_revision", true as Any), ("committed", "01024" as Any)] {
            var bad = frame(); bad[key] = value
            #expect(throws: StorageScanFailure.self) { try decode(bad) }
        }
    }
    @Test func noUncommittedTailZeroOrOversizedCount() {
        for count: UInt64 in [0, 1025, UInt64.max] {
            #expect(throws: StorageScanFailure.self) { try decode(frame(count: count), count: count) }
        }
        #expect(throws: StorageScanFailure.self) { try decode(frame(), count: 2048) }
    }
    @Test func transportDelayDoesNotWeakenEmissionRateOrSequence() throws {
        let first = try decode(frame())
        for (elapsed, sequence) in [(UInt64(549_999_999), UInt64(4)), (600_000_000, 2), (299_999_999, 3)] {
            #expect(throws: StorageScanFailure.self) { try decode(frame(count: 2048, bytes: 20, elapsed: elapsed, sequence: sequence), count: 2048, previous: first) }
        }
        #expect(throws: StorageScanFailure.self) { try decode(frame(elapsed: 249_999_999)) }
    }
    @Test func typePartitionOrderAndSizeAreExact() throws {
        for n in [14, 16] {
            var bad = frame(); bad["types"] = (0..<n).map { ["id": $0, "value": encoded(0, bytes: 0)] as [String: Any] }
            #expect(throws: StorageScanFailure.self) { try decode(bad) }
        }
        var bad = frame(), rows = bad["types"] as! [[String: Any]]
        rows[1]["id"] = 0; bad["types"] = rows
        #expect(throws: StorageScanFailure.self) { try decode(bad) }
        bad = frame(); bad["value"] = encoded(1024, bytes: 11)
        #expect(throws: StorageScanFailure.self) { try decode(bad) }
        bad = frame(); bad["value"] = String(repeating: "A", count: 1025)
        #expect(throws: StorageScanFailure.self) { try decode(bad) }
    }
    @Test func rollingBackPresentationOrLosingPriorValuesRefuses() throws {
        let first = try decode(frame())
        #expect(throws: StorageScanFailure.self) { try decode(frame(count: 2048, bytes: 9, elapsed: 600_000_000, sequence: 4), count: 2048, previous: first) }
        #expect(throws: StorageScanFailure.self) { try decode(frame(elapsed: 600_000_000, sequence: 4), previous: first) }
    }
    @Test func pairedSchemaRetainsCumulativeValuesAndRejectsReset() throws {
        func paired(_ row: [String: Any], count: UInt64, previous: CommittedAnalysisPrefix?) throws -> CommittedAnalysisPrefix {
            var row = row; row["schema"] = 10
            return try .decode(row, session: session, policy: .standard, wireSchema: 10, committed: count, previous: previous)
        }
        let data = try paired(frame(count: 99_328, bytes: 100, elapsed: 1_000_000_000), count: 99_328, previous: nil)
        let system = try paired(frame(count: 100_352, bytes: 103, elapsed: 1_300_000_000, sequence: 7), count: 100_352, previous: data)
        #expect(system.entries == 100_352 && system.value.bytes.dataLogical.knownBytes == 103)
        #expect(throws: StorageScanFailure.self) {
            try paired(frame(count: 1024, bytes: 3, elapsed: 1_300_000_000, sequence: 7), count: 1024, previous: data)
        }
        var largeCheckpoint = frame(); largeCheckpoint["prefix_revision"] = 2
        #expect(throws: StorageScanFailure.self) { try decode(largeCheckpoint) }
    }
    @Test func largerCheckpointRequiresMatchingRevisionAndCannotChangeMidstream() throws {
        var row = frame(count: 4096); row["prefix_revision"] = 2
        let first = try CommittedAnalysisPrefix.decode(row, session: session, policy: .standard,
            wireSchema: 9, committed: 4096, previous: nil, checkpointRows: 4096)
        #expect(first.checkpointRows == 4096)
        for rows: UInt64 in [512, 1024, 8192] {
            #expect(throws: StorageScanFailure.self) {
                try CommittedAnalysisPrefix.decode(row, session: session, policy: .standard,
                    wireSchema: 9, committed: 4096, previous: nil, checkpointRows: rows)
            }
        }
        let old = try decode(frame())
        row["elapsed_ns"] = "600000000"; row["seq"] = "4"
        #expect(throws: StorageScanFailure.self) {
            try CommittedAnalysisPrefix.decode(row, session: session, policy: .standard,
                wireSchema: 9, committed: 4096, previous: old, checkpointRows: 4096)
        }
        row = frame(count: 1024); row["prefix_revision"] = 2
        #expect(throws: StorageScanFailure.self) {
            try CommittedAnalysisPrefix.decode(row, session: session, policy: .standard,
                wireSchema: 9, committed: 1024, previous: nil, checkpointRows: 4096)
        }
    }
}
