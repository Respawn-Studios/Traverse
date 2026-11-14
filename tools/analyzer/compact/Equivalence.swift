import Foundation

/// In-memory streams only. Canonical output crosses the same public interface
/// for the original and candidate model; no scanner or filesystem is involved.
@main
struct ModelEquivalence {
    enum Failure: Error { case invariant }
    static func require(_ value: Bool) throws { if !value { throw Failure.invariant } }
    static let root = AnalysisObjectIdentity(device: 1, inode: 1)
    static func bytes(_ n: UInt64) -> AnalysisByteObservation {
        .init(dataLogical: .returned(n), allForkLogical: .returned(n),
              dataAllocated: .returned(n), allForkAllocated: .returned(n))
    }
    static func entry(_ path: Data, _ kind: AnalysisEntryKind, _ inode: UInt64,
                      values: AnalysisByteObservation = .init(), links: UInt64 = 1) -> AnalysisEntryObservation {
        .init(relativePath: path, kind: kind, identity: .returned(.init(device: 1, inode: inode)),
              linkCount: .returned(links), flags: .returned(0), bytes: values)
    }
    static func metrics(_ values: AnalysisByteSubtotals) -> [[String]] {
        AnalysisByteMetric.allCases.map {
            let v = values[$0]
            return [v.knownBytes.map(String.init) ?? "unavailable", String(v.notReturnedCount),
                    String(v.failedCount), String(v.overflowed)]
        }
    }
    static func counts(_ v: AnalysisEntryCounts) -> [UInt64] {
        [v.regularFiles, v.directories, v.symbolicLinks, v.other, v.unknown]
    }
    static func canonical(_ v: StorageAnalysisSnapshot) -> [String: Any] {
        let d = v.distinctObjects
        return ["state": String(describing: v.inputState), "processed": v.processedRecords,
                "rejected": v.rejectedRecords, "paths": v.retainedRawPathBytes,
                "complete": v.isComplete, "issue_count": v.issueCount,
                "issues": v.issues.map { [String(describing: $0.code), String($0.folder.rawValue),
                                         $0.recordOrdinal.map(String.init) ?? "nil"] },
                "objects": [d.knownObjectCount, d.identityMissingEntries, d.observedCrossFolderHardlinkObjects,
                            d.potentialOutsideLinkObjects, d.objectsWithUnknownLinkCount],
                "object_bytes": metrics(d.byteSubtotals),
                "folders": v.folders.map { f -> [String: Any] in
                    ["id": f.id.rawValue, "parent": f.parent.map { String($0.rawValue) } ?? "nil",
                     "path": f.relativePath.base64EncodedString(), "identity": String(describing: f.identity),
                     "own": AnalysisByteMetric.allCases.map { String(describing: f.ownMetadataBytes[$0]) },
                     "counts": counts(f.counts), "bytes": metrics(f.namespaceSubtotals),
                     "issues": f.issueCount, "complete": f.isComplete]
                }]
    }
    static func encode(_ v: StorageAnalysisSnapshot) throws -> Data {
        try JSONSerialization.data(withJSONObject: canonical(v), options: [.sortedKeys])
    }
    static func progress(_ p: StorageAnalysisProgress) -> [String: Any] {
        ["state": String(describing: p.inputState), "processed": p.processedRecords,
         "rejected": p.rejectedRecords, "counts": counts(p.acceptedCounts),
         "bytes": metrics(p.namespaceSubtotals), "objects": p.knownObjectCount,
         "folders": p.folderCount, "paths": p.retainedRawPathBytes, "issues": p.issueCount]
    }
    static func run(_ seed: Int) throws -> [String: Any] {
        let limits = try AnalysisLimits(maximumRecords: seed == 0 ? 23 : 1000,
                                        maximumRetainedRawPathBytes: seed == 1 ? 64 : 8192,
                                        maximumPathBytes: 200, maximumDepth: 8,
                                        maximumDetailedIssues: seed % 3 == 0 ? 0 : 100)
        var model = StorageAnalysisAccumulator(rootIdentity: root, limits: limits)
        var admissions: [String] = []
        var snapshots: [Any] = [canonical(model.snapshot())]
        var state: UInt64 = UInt64(seed + 1)
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        func add(_ observation: AnalysisEntryObservation) { admissions.append(String(describing: model.consume(observation))) }
        add(entry(Data("a".utf8), .directory, 2))
        add(entry(Data("b".utf8), .directory, 3))
        add(entry(Data("a/nested".utf8), .directory, 4, values: bytes(9)))
        let held = model.snapshot()
        let heldBytes = try encode(held)
        // Copies made before and after compaction must keep independent values.
        var branch = model
        add(entry(Data("a/first".utf8), .regularFile, 10, values: bytes(7), links: 3))
        add(entry(Data("b/second".utf8), .regularFile, 10, values: bytes(7), links: 3))
        for index in 0..<96 {
            let n = next(), kind: AnalysisEntryKind = [.regularFile, .directory, .symbolicLink, .other, .unknown][Int(n % 5)]
            let paths = ["a/item\(index)", "b/item\(index)", "a/nested/item\(index)", "missing/item\(index)",
                         "a/first", "", "/root", "a//bad", "a/../bad", "a/./bad", "a/b/c/d/e/f/g/h/i", "a/first/child"]
            let path = paths[Int((n >> 8) % UInt64(paths.count))]
            var value = bytes(n % 83)
            if index % 7 == 0 { value.allForkLogical = .notReturned }
            if index % 11 == 0 { value.dataAllocated = .failed(code: 13) }
            if index % 13 == 0 { value.allForkAllocated = .returned(UInt64.max) }
            if index % 17 == 0 {
                add(.init(relativePath: Data(path.utf8), kind: kind, identity: .notReturned,
                          linkCount: .failed(code: 5), flags: .notReturned, bytes: value))
            } else { add(entry(Data(path.utf8), kind, UInt64(index + 30), values: value)) }
            if index == 24 || index == 48 { snapshots.append(canonical(model.snapshot())) }
            if index % 19 == 0 { admissions.append(String(model.recordCoverageGap(.changing, in: .init(rawValue: index % 9)))) }
        }
        add(entry(Data([97, 47, 255, 254]), .regularFile, 999, values: bytes(1)))
        add(entry(Data([97, 47, 0]), .regularFile, 1000, values: bytes(1)))
        let completion: AnalysisInputCompletion = [.completed, .cancelled, .failed(.disconnected)][seed % 3]
        let final = model.finish(completion)
        let encoded = try encode(final)
        try require(try encode(held) == heldBytes)
        try require(try encode(model.snapshot()) == encoded)
        try require(try encode(model.finish(.failed(.unavailable))) == encoded)
        try require(model.consume(entry(Data("late".utf8), .regularFile, 9999)) == .closed)
        try require(!model.recordCoverageGap(.unavailable))
        try require(try encode(model.snapshot()) == encoded)
        try require(branch.progress.acceptedCounts.directories == 3)
        _ = branch.finish(.cancelled)
        try require(try encode(model.snapshot()) == encoded)
        snapshots.append(canonical(final))
        return ["seed": seed, "admissions": admissions, "snapshots": snapshots,
                "progress": progress(model.progress), "branch": canonical(branch.snapshot())]
    }
    static func main() {
        do {
            let results = try (0..<32).map(run)
            let data = try JSONSerialization.data(withJSONObject: ["passed": true, "cases": results], options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
        } catch { FileHandle.standardError.write(Data("model_equivalence_failed\n".utf8)); exit(2) }
    }
}
