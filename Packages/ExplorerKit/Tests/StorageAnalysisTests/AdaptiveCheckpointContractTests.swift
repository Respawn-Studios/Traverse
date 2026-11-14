import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct AdaptiveCheckpointContractTests {
    @Test func refreshCheckpointRejectsNoncanonicalCursorsAndUnsafeReasons() throws {
        func checkpoint(_ cursor: String, reason: String? = nil) -> AnalysisRefreshCheckpoint {
            AnalysisRefreshCheckpoint(catalogID: UUID(), eventUUID: UUID(), cursor: cursor,
                originalObservedThrough: Date(timeIntervalSince1970: 10), reusedEntries: 0,
                enumeratedDirectories: 1, isIncremental: false, fallbackReason: reason, reusedDirectories: 3)
        }
        try checkpoint("0").validate()
        try checkpoint("123", reason: "events_dropped").validate()
        for cursor in ["01", "-1", "+1", " 1", String(UInt64.max)] {
            #expect(throws: StorageScanFailure.self) { try checkpoint(cursor).validate() }
        }
        #expect(throws: StorageScanFailure.self) { try checkpoint("1", reason: "/private/name").validate() }
        let source = checkpoint("123")
        #expect(try JSONDecoder().decode(AnalysisRefreshCheckpoint.self, from: JSONEncoder().encode(source)) == source)
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        older.removeValue(forKey: "reusedDirectories")
        let decoded = try JSONDecoder().decode(AnalysisRefreshCheckpoint.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.reusedDirectories == nil && decoded.reusedEntries == 0)
    }

    @Test func refreshEventsDirtyParentsAndKeepRecursiveSubtreesWithinScope() {
        let root = Data("projects/sample".utf8)
        func normalized(_ path: String, recursive: Bool = false) -> Data? {
            AnalysisRefreshEvents.normalize(Data(path.utf8), relativeRoot: root, mount: "/Volumes/Generated", recursive: recursive)
        }
        #expect(normalized("projects/sample/a/file") == Data("a".utf8))
        #expect(normalized("projects/sample/a", recursive: true) == Data("a".utf8))
        #expect(normalized("projects/sample/new") == Data())
        #expect(normalized("projects/sample") == Data())
        #expect(normalized("projects/sample-other/file") == nil)
        #expect(normalized("projects/sample/../other") == nil)
        #expect(normalized("projects/sample/.Trashes/file") == nil)
    }

    @Test func refreshProvenanceCountsEmptyBorrowedListingsAndKeepsUnknownOlderCountsDated() {
        func checkpoint(entries: UInt64, directories: UInt64?, incremental: Bool = true) -> AnalysisRefreshCheckpoint {
            .init(catalogID: UUID(), eventUUID: UUID(), cursor: "1", originalObservedThrough: Date(),
                reusedEntries: entries, enumeratedDirectories: 1, isIncremental: incremental,
                fallbackReason: nil, reusedDirectories: directories)
        }
        #expect(!checkpoint(entries: 0, directories: 0).mayContainEarlierObservations)
        #expect(checkpoint(entries: 0, directories: 1).mayContainEarlierObservations)
        #expect(checkpoint(entries: 1, directories: 0).mayContainEarlierObservations)
        #expect(checkpoint(entries: 0, directories: nil).mayContainEarlierObservations)
        #expect(!checkpoint(entries: 0, directories: nil, incremental: false).mayContainEarlierObservations)
    }

    @Test func coalescedRefreshPlanPreservesExactListingCoverageInEveryOrder() {
        let scopes: [AnalysisRefreshDirtyDirectory] = [
            .init(path: Data("Cache/sub/deep".utf8), recursive: false),
            .init(path: Data("Cache/sub".utf8), recursive: true),
            .init(path: Data("Cache".utf8), recursive: true),
            .init(path: Data("Cache2/sub".utf8), recursive: false),
            .init(path: Data(), recursive: false)
        ]
        func orders(_ values: [AnalysisRefreshDirtyDirectory]) -> [[AnalysisRefreshDirtyDirectory]] {
            if values.isEmpty { return [[]] }
            return values.indices.flatMap { index in
                var remainder = values; let first = remainder.remove(at: index)
                return orders(remainder).map { [first] + $0 }
            }
        }
        func covers(_ scope: AnalysisRefreshDirtyDirectory, _ path: Data) -> Bool {
            if scope.path == path { return true }
            guard scope.recursive else { return false }
            if scope.path.isEmpty { return true }
            // Independent component-wise oracle; direct parent listings never
            // stand in for their children's own directory contents.
            return path.split(separator: 47).starts(with: scope.path.split(separator: 47))
        }
        let probes = ["", "Cache", "Cache/sub", "Cache/sub/deep", "Cache/sub/deep/child",
            "Cache/other", "Cache2", "Cache2/sub", "Cache2/sub/child", "CacheSibling"].map { Data($0.utf8) }
        for order in orders(scopes) {
            var plan = AnalysisRefreshDirtyPlan()
            for scope in order { plan.insert(scope.path, recursive: scope.recursive) }
            #expect(plan.count == 3 && plan.directCount == 2 && plan.recursiveCount == 1)
            #expect(plan.pathBytes == plan.directories.reduce(0) { $0 + $1.path.count })
            for path in probes {
                #expect(scopes.contains { covers($0, path) } == plan.directories.contains { covers($0, path) })
            }
        }
    }

    @Test func refreshCoalescingKeepsComponentAndByteDistinctBoundaries() {
        var plan = AnalysisRefreshDirtyPlan()
        let composed = Data("caf\u{00e9}".utf8), decomposed = Data("cafe\u{0301}".utf8)
        plan.insert(composed, recursive: true)
        plan.insert(decomposed + Data("/child".utf8), recursive: false)
        plan.insert(Data("Cache".utf8), recursive: false)
        plan.insert(Data("Cache/child".utf8), recursive: true)
        plan.insert(Data("Cache2/child".utf8), recursive: true)
        #expect(plan.count == 5)
        plan.insert(Data("Cache".utf8), recursive: true)
        #expect(plan.count == 4 && plan.directories.contains { $0.path == Data("Cache2/child".utf8) })
        plan.insert(Data(), recursive: true)
        #expect(plan.directories == [.init(path: Data(), recursive: true)] && plan.pathBytes == 0)
    }

    @Test func refreshCoalescingAvoidsRedundantBudgetUseWithoutRaisingEitherLimit() {
        var covered = AnalysisRefreshDirtyPlan()
        covered.insert(Data("Project/.build".utf8), recursive: true)
        for index in 0..<1024 {
            covered.insert(Data("Project/.build/branch\(index)".utf8), recursive: true)
            covered.insert(Data("Project/.build/branch\(index)/child".utf8), recursive: false)
        }
        #expect(covered.count == 1 && !covered.exceedsLimits)
        var wide = AnalysisRefreshDirtyPlan()
        for index in 0..<256 { wide.insert(Data("Project/Cache\(index)".utf8), recursive: true) }
        #expect(wide.count == 256 && !wide.exceedsLimits)
        wide.insert(Data("Project/one-more".utf8), recursive: true)
        #expect(wide.exceedsLimits)
        var bytes = AnalysisRefreshDirtyPlan()
        for index in 0..<200 { bytes.insert(Data((String(repeating: "segment/", count: 31) + "leaf\(index)").utf8), recursive: true) }
        #expect(bytes.count < 256 && bytes.pathBytes > 48 * 1024 && bytes.exceedsLimits)
        bytes.removeAll()
        #expect(bytes.count == 0 && bytes.pathBytes == 0 && !bytes.exceedsLimits)
    }

    private let session = UUID()
    private func header(startup: Bool = false) -> [String: Any] {
        ["schema": startup ? 16 : 15, "policy_revision": "local-metadata-v1", "classification_revision": 3,
         "profile": startup ? "startup-result-adaptive-v1" : "full-result-adaptive-v1",
         "traversal_revision": "bounded-depth-v1", "maximum_depth": 128,
         "checkpoint_revision": 1, "checkpoint_rows": 16384, "progress_revision": "committed-totals-adaptive-v1"]
    }
    @Test func profileDepthAndCheckpointVersionsCannotBeReinterpreted() throws {
        for startup in [false, true] {
            let good = header(startup: startup)
            let binding = try AnalysisPolicyBinding(header: good, startup: startup, policy: .standard, classificationRevision: .v3)
            #expect(binding.adaptiveCheckpoints && binding.maximumPathComponents == 128)
            for (key, invalid): (String, Any) in [("checkpoint_rows",4096),("checkpoint_revision",2),
                ("checkpoint_revision",true),("maximum_depth",64),("schema",startup ? 14 : 13),
                ("profile",startup ? "startup-result-depth128-v1" : "full-result-depth128-v1"),
                ("progress_revision","committed-totals-classification-v3")] {
                var bad = good; bad[key] = invalid
                #expect(throws: StorageScanFailure.self) {
                    try AnalysisPolicyBinding(header: bad, startup: startup, policy: .standard, classificationRevision: .v3)
                }
            }
            for key in ["checkpoint_rows", "checkpoint_revision", "maximum_depth", "profile", "progress_revision"] {
                var bad = good; bad.removeValue(forKey: key)
                #expect(throws: StorageScanFailure.self) {
                    try AnalysisPolicyBinding(header: bad, startup: startup, policy: .standard, classificationRevision: .v3)
                }
            }
            #expect(throws: StorageScanFailure.self) {
                try AnalysisPolicyBinding(header: good, startup: !startup, policy: .standard, classificationRevision: .v3)
            }
        }
    }
    @Test func everyReadChildRetainsItsExactCheckpointAndDepthPolicy() throws {
        let binding = try AnalysisPolicyBinding(header: header(), startup: false, policy: .standard, classificationRevision: .v3)
        let good: [String: Any] = ["kind":"policy", "revision":"local-metadata-v1", "session":session.uuidString,
            "classification_revision":3, "maximum_depth":128, "checkpoint_revision":1]
        try binding.validateQueryPrelude(good, session: session)
        for key in ["checkpoint_revision", "maximum_depth"] {
            var missing = good; missing.removeValue(forKey: key)
            #expect(throws: StorageScanFailure.self) { try binding.validateQueryPrelude(missing, session: session) }
        }
        for invalid: Any in [0, 2, true, "1"] {
            var bad = good; bad["checkpoint_revision"] = invalid
            #expect(throws: StorageScanFailure.self) { try binding.validateQueryPrelude(bad, session: session) }
        }
    }
    @Test func variableCountsAreBoundedWithoutRequiringFixedMultiples() throws {
        let contract = try AnalysisCheckpointContract(rows: 16384, classification: .v3)
        #expect(contract.acceptsProgress(4096, previous: 0, crossedSource: false))
        #expect(contract.acceptsProgress(12001, previous: 4096, crossedSource: false))
        #expect(contract.acceptsProgress(28385, previous: 12001, crossedSource: false))
        for count: UInt64 in [0,4095,4097,16384,UInt64.max] {
            #expect(!contract.acceptsProgress(count, previous: 0, crossedSource: false))
        }
        for count: UInt64 in [4095,4096,8191,20481,UInt64.max] {
            #expect(!contract.acceptsProgress(count, previous: 4096, crossedSource: false))
        }
        #expect(contract.acceptsSnapshotCount(24577))
        #expect(!contract.acceptsSnapshotCount(4095))
        #expect(!contract.acceptsSnapshotCount(UInt64(Int64.max)))
        #expect(throws: StorageScanFailure.self) { try AnalysisCheckpointContract(rows: 16384, classification: .v2) }
        #expect(throws: StorageScanFailure.self) { try AnalysisCheckpointContract(rows: 8192, classification: .v3) }
    }
    @Test func oneVerifiedSourceTransitionAllowsOnlyItsUnreportedTail() throws {
        let contract = try AnalysisCheckpointContract(rows: 16384, classification: .v3)
        #expect(contract.acceptsProgress(7096, previous: 0, crossedSource: true))
        #expect(contract.acceptsProgress(20480, previous: 0, crossedSource: true))
        #expect(!contract.acceptsProgress(20481, previous: 0, crossedSource: true))
        #expect(!contract.acceptsProgress(7096, previous: 0, crossedSource: false))
        #expect(contract.acceptsProgress(53247, previous: 20480, crossedSource: true))
        #expect(!contract.acceptsProgress(53247, previous: 20480, crossedSource: false))
        #expect(contract.acceptsProgress(53248, previous: 20480, crossedSource: true))
        #expect(!contract.acceptsProgress(53249, previous: 20480, crossedSource: true))
        #expect(!contract.acceptsProgress(20480, previous: 20480, crossedSource: true))
    }
    private func value(_ count: UInt64, bytes: UInt64) -> String {
        var data = Data(repeating: 0, count: 140)
        func put(_ value: UInt64, at offset: Int) {
            for index in 0..<8 { data[offset+index] = UInt8(truncatingIfNeeded: value >> (56-index*8)) }
        }
        put(count, at: 0)
        for metric in 0..<4 { put(bytes, at: 40+metric*25) }
        return data.base64EncodedString()
    }
    private func frame(count: UInt64 = 24577) -> [String: Any] {
        ["kind":"committed_totals", "schema":15, "prefix_revision":4, "session":session.uuidString,
         "policy_revision":"local-metadata-v1", "committed":String(count), "elapsed_ns":"300000000", "seq":"4",
         "value":value(count,bytes:456), "types":(0..<16).map { index in
             ["id":index, "value":value(index == 2 ? count : 0, bytes:index == 2 ? 456 : 0)] as [String:Any]
         }]
    }
    @Test func variablePrefixRequiresNewRevisionAndKeepsEveryMetricPartition() throws {
        let good = frame()
        let decoded = try CommittedAnalysisPrefix.decode(good, session: session, policy: .standard,
            wireSchema: 15, committed: 24577, previous: nil, checkpointRows: 16384, classificationRevision: .v3)
        #expect(decoded.entries == 24577 && decoded.value.bytes.allForkAllocated.knownBytes == 456)
        for (key, invalid): (String, Any) in [("prefix_revision",3),("schema",13),("committed","024577"),
            ("session",UUID().uuidString),("value",value(24577,bytes:457))] {
            var bad = good; bad[key] = invalid
            #expect(throws: StorageScanFailure.self) {
                try CommittedAnalysisPrefix.decode(bad, session: session, policy: .standard,
                    wireSchema: 15, committed: 24577, previous: nil, checkpointRows: 16384, classificationRevision: .v3)
            }
        }
        #expect(throws: StorageScanFailure.self) {
            try CommittedAnalysisPrefix.decode(good, session: session, policy: .standard,
                wireSchema: 15, committed: 24577, previous: nil, checkpointRows: 4096, classificationRevision: .v3)
        }
        var rollback = frame(count: 28673); rollback["value"] = value(28673,bytes:455)
        rollback["elapsed_ns"] = "600000000"; rollback["seq"] = "5"
        #expect(throws: StorageScanFailure.self) {
            try CommittedAnalysisPrefix.decode(rollback, session: session, policy: .standard,
                wireSchema: 15, committed: 28673, previous: decoded, checkpointRows: 16384, classificationRevision: .v3)
        }
    }
}
