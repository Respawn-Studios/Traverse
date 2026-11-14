import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(ArchiveProduction) @testable import FileOperations
@_spi(Qualification) @testable import LocalStorage

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_PROCESS_ROOT"] != nil))
struct ReceivedFileInterruptionProcessTests {
    @Test func child() async throws {
        let env = ProcessInfo.processInfo.environment
        let admitted = URL(fileURLWithPath: try #require(env["MAC_EXPLORER_B12_PROCESS_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification")
            && admitted.resolvingSymlinksInPath() == admitted && UUID(uuidString: admitted.lastPathComponent) != nil
            && FileManager().fileExists(atPath: admitted.appendingPathComponent("reservation.json").path))
        let boundary = try #require(env["MAC_EXPLORER_B12_PROCESS_BOUNDARY"]), action = try #require(env["MAC_EXPLORER_B12_PROCESS_ACTION"])
        try #require(["produced", "rename", "committed", "reverse-before", "reverse-rename"].contains(boundary)
            && ["forward", "reverse", "inspect", "recover"].contains(action))
        let root = admitted.appendingPathComponent("source/Process-" + boundary), target = root.appendingPathComponent("Destination")
        let journal = root.appendingPathComponent("journal"), pool = root.appendingPathComponent("downloads"), original = root.appendingPathComponent("Generated original.bin")
        let bytes = Data((0..<65_537).map { UInt8($0 % 251) })
        if action == "forward" || action == "reverse" {
            try FileManager().createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: original, options: .withoutOverwriting)
            let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 2,
                entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: UInt64(bytes.count), modifiedSeconds: 19, permissions: 0o100644)))
            let file = try await RemoteDownloadStore(directory: pool).reserve(selection); var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + 32768)
                try await file.append(request: selection.request, offset: UInt64(offset), bytes: bytes.subdata(in: offset..<end)); offset = end
            }
            _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(bytes.count)))
            var hooks = RecoveryHooks()
            if action == "forward" {
                hooks.archiveProduction.stage = { stage, _ in if stage.rawValue == boundary { Self.crash(boundary) } }
                hooks.afterRename = { if boundary == "rename" { Self.crash(boundary) } }
            }
            let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks, protecting: [pool])
            let plan = try await file.preparePublication(using: engine, parent: target, name: "Received.bin")
            let result = await engine.performReceivedFile(plan); try #require(result.result.disposition == .succeeded)
            if action == "reverse" {
                try await file.removeAfterDrain() // Cold Undo must not need it.
                var inverse = RecoveryHooks()
                inverse.beforeRename = { if boundary == "reverse-before" { Self.crash(boundary) } }
                inverse.afterRename = { if boundary == "reverse-rename" { Self.crash(boundary) } }
                let undo = RecoverableFileOperations(journalDirectory: journal, hooks: inverse, protecting: [pool])
                _ = await undo.undo(recordID: try #require(result.recordID))
            }
            Issue.record("Requested download interruption did not occur")
        } else {
            let engine = RecoverableFileOperations(journalDirectory: journal, protecting: [pool])
            let observation = try await engine.inspectExistingHistory(), record = try #require(observation.records.first)
            try #require(observation.records.count == 1 && observation.refusedEntries.isEmpty && record.operation == "Download"
                && record.locations.allSatisfy { $0.path != pool.path && !$0.path.hasPrefix(pool.path + "/") })
            var report: [String: Any] = ["event": action, "pid": getpid(), "recordID": record.id.uuidString, "passed": true]
            if action == "recover" {
                let outcome = record.canUndo ? await engine.undo(recordID: record.id) : await engine.recover(recordID: record.id)
                let beforeIntent = boundary == "produced"
                try #require((outcome.result.disposition == .succeeded) == !beforeIntent)
                try #require(!FileManager().fileExists(atPath: target.appendingPathComponent("Received.bin").path))
                try #require(Data(SHA256.hash(data: Data(contentsOf: original))) == Data(SHA256.hash(data: bytes)))
                report["inverseSucceeded"] = outcome.result.disposition == .succeeded
                report["unpublishedStageRetainedForReview"] = beforeIntent
                report["originalUnchanged"] = true
            }
            Self.emit(report)
        }
    }
    private static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("MAC_EXPLORER_DOWNLOAD_CHILD " + String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    private static func crash(_ boundary: String) -> Never { emit(["event": "crash", "pid": getpid(), "boundary": boundary, "requestedExit": 86]); _exit(86) }
}
