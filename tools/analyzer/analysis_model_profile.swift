import Foundation

/// In-memory accounting observations only. This executable does not enumerate,
/// open or read a fixture. The imported frozen helper supplies process metrics.
@main
struct AnalysisModelProfile {
    enum Failure: Error { case invalidCase, invariant(String), resources }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.invariant(message) }
    }

    static func resources(_ stage: String) throws -> [String: String] {
        var value = B06Resources(current_rss: 0, peak_rss: 0, user_ns: 0, system_ns: 0)
        guard b06_resources(&value) == 0 else { throw Failure.resources }
        return ["stage": stage, "current_rss": String(value.current_rss),
                "peak_rss": String(value.peak_rss), "user_ns": String(value.user_ns),
                "system_ns": String(value.system_ns)]
    }

    static func observation(_ path: Data, inode: UInt64,
                            kind: AnalysisEntryKind = .directory) -> AnalysisEntryObservation {
        let bytes = kind == .regularFile
            ? AnalysisByteObservation(dataLogical: .returned(64), allForkLogical: .returned(80),
                                      dataAllocated: .returned(4096), allForkAllocated: .returned(8192))
            : AnalysisByteObservation()
        return AnalysisEntryObservation(relativePath: path, kind: kind,
                                        identity: .returned(.init(device: 1, inode: inode)),
                                        linkCount: .returned(1), flags: .returned(0), bytes: bytes)
    }

    static func run(_ name: String) throws -> [String: Any] {
        var stages = [try resources("startup")]
        var accumulator: StorageAnalysisAccumulator? = StorageAnalysisAccumulator(
            rootIdentity: .init(device: 1, inode: 1))
        var accepted = 0
        var expectedPathBytes = 0
        var regularFiles = 0
        var directories = 0
        var expectedCompletion = AnalysisInputCompletion.completed

        func add(_ path: Data, kind: AnalysisEntryKind = .directory) throws {
            let result = accumulator!.consume(observation(path, inode: UInt64(accepted + 2), kind: kind))
            try require(result == .accepted, "generated observation rejected")
            accepted += 1
            expectedPathBytes += path.count
            if kind == .regularFile { regularFiles += 1 } else { directories += 1 }
        }

        switch name {
        case "ordinary":
            for index in 0..<1000 { try add(Data("d\(index)".utf8)) }
            for index in 0..<100_000 {
                try add(Data("d\(index % 1000)/f\(index)".utf8), kind: .regularFile)
            }
        case "folder-record-limit":
            for index in 0..<220_000 { try add(Data("d\(index)".utf8)) }
            let admission = accumulator!.consume(observation(Data("overflow".utf8), inode: 300_000))
            try require(admission == .resourceLimited(.records), "record ceiling did not seal input")
            expectedCompletion = .resourceLimited(.records)
        case "raw-path-limit":
            // Every component fits the native 255-byte name boundary. The
            // parent-first trunk plus leaves stays within the 64-depth model.
            var trunk = Data()
            for index in 0..<63 {
                if !trunk.isEmpty { trunk.append(47) }
                let prefix = "p\(index)-"
                trunk.append(contentsOf: (prefix + String(repeating: "a", count: 120 - prefix.utf8.count)).utf8)
                try add(trunk)
            }
            let capacity = AnalysisLimits.standard.maximumRetainedRawPathBytes
            var index = 0
            while capacity - expectedPathBytes >= trunk.count + 256 {
                var path = trunk
                path.append(47)
                let prefix = "f\(index)-"
                path.append(contentsOf: (prefix + String(repeating: "b", count: 255 - prefix.utf8.count)).utf8)
                try add(path)
                index += 1
            }
            // Fill the final remainder with distinct root children so the
            // accepted payload reaches the ceiling exactly, never above it.
            while expectedPathBytes < capacity {
                let length = min(255, capacity - expectedPathBytes)
                let prefix = "z\(index)-"
                let path: Data
                if length >= prefix.utf8.count {
                    path = Data((prefix + String(repeating: "c", count: length - prefix.utf8.count)).utf8)
                } else {
                    path = Data(repeating: 127, count: length)
                }
                try add(path)
                index += 1
            }
            let admission = accumulator!.consume(observation(Data("overflow".utf8), inode: 300_000))
            try require(admission == .resourceLimited(.retainedRawPathBytes), "raw path ceiling did not seal input")
            expectedCompletion = .resourceLimited(.retainedRawPathBytes)
        default: throw Failure.invalidCase
        }

        let progress = accumulator!.progress
        try require(progress.acceptedCounts.total == UInt64(accepted), "ingestion count mismatch")
        try require(progress.folderCount == directories + 1, "ingestion folder count mismatch")
        try require(progress.retainedRawPathBytes == expectedPathBytes, "retained raw path mismatch")
        try withExtendedLifetime(accumulator) { stages.append(try resources("ingested")) }

        var snapshot: StorageAnalysisSnapshot? = accumulator!.finish()
        try require(snapshot!.inputState == .closed(expectedCompletion), "terminal state mismatch")
        try require(snapshot!.root.counts.regularFiles == UInt64(regularFiles), "regular count mismatch")
        try require(snapshot!.root.counts.directories == UInt64(directories), "directory count mismatch")
        try require(snapshot!.folders.count == directories + 1, "snapshot folder count mismatch")
        try require(snapshot!.distinctObjects.knownObjectCount == UInt64(regularFiles), "object count mismatch")
        for (metric, unit) in zip(AnalysisByteMetric.allCases, [UInt64(64), 80, 4096, 8192]) {
            let expected = UInt64(regularFiles) * unit
            try require(snapshot!.root.namespaceSubtotals[metric].knownBytes == expected, "namespace total mismatch")
            try require(snapshot!.distinctObjects.byteSubtotals[metric].knownBytes == expected, "object total mismatch")
        }
        try require(snapshot!.isComplete == (name == "ordinary"), "completion claim mismatch")
        try require(snapshot!.issueCount == (name == "ordinary" ? 0 : 1), "issue count mismatch")
        try require(snapshot!.retainedRawPathBytes <= 64 << 20, "raw payload bound exceeded")
        try require(snapshot!.processedRecords <= 220_000, "record count bound exceeded")
        try withExtendedLifetime((accumulator, snapshot)) { stages.append(try resources("snapshot_retained")) }

        let counts: [String: Any] = ["accepted_records": accepted, "regular_files": regularFiles,
                                   "directory_entries": directories, "folder_nodes": snapshot!.folders.count,
                                   "processed_records": String(snapshot!.processedRecords),
                                   "rejected_records": String(snapshot!.rejectedRecords),
                                   "retained_raw_path_bytes": expectedPathBytes,
                                   "known_object_count": String(snapshot!.distinctObjects.knownObjectCount),
                                   "issue_count": String(snapshot!.issueCount), "is_complete": snapshot!.isComplete]
        snapshot = nil
        accumulator = nil
        stages.append(try resources("released"))
        return ["schema": 1, "case": name, "passed": true, "counts": counts, "resources": stages,
                "layout_strides": ["observation": MemoryLayout<AnalysisEntryObservation>.stride,
                                   "folder_summary": MemoryLayout<AnalysisFolderSummary>.stride,
                                   "byte_subtotals": MemoryLayout<AnalysisByteSubtotals>.stride],
                "limits": ["records": 220_000, "retained_raw_path_bytes": 64 << 20],
                "scope": "in-memory model only; no filesystem or worker lifecycle qualification",
                "memory_note": "Raw payload ceiling is not an RSS limit. Released RSS may retain allocator pages."]
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure.invalidCase }
            let record = try run(CommandLine.arguments[1])
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            let record: [String: Any] = ["schema": 1, "passed": false, "error": String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            exit(2)
        }
    }
}
