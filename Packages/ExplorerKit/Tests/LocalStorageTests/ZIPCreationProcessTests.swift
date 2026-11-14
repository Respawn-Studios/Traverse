import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FileOperations
@testable import LocalStorage

/// Driven only in separate test processes by the admitted packet wrapper.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_CREATION_PROCESS_ROOT"] != nil))
struct ZIPCreationProcessTests {
    @Test func child() async throws {
        let env = ProcessInfo.processInfo.environment
        let admitted = URL(fileURLWithPath: try #require(env["MAC_EXPLORER_ZIP_CREATION_PROCESS_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-zip-creation")
            && admitted.resolvingSymlinksInPath() == admitted && UUID(uuidString: admitted.lastPathComponent) != nil
            && FileManager().fileExists(atPath: admitted.appendingPathComponent("reservation.json").path))
        let root = admitted.appendingPathComponent("source/Process"), input = root.appendingPathComponent("Input.txt")
        let parent = root.appendingPathComponent("Destination"), journal = root.appendingPathComponent("journal")
        let action = try #require(env["MAC_EXPLORER_ZIP_CREATION_PROCESS_ACTION"])
        let boundary = try #require(env["MAC_EXPLORER_ZIP_CREATION_PROCESS_BOUNDARY"])
        let beforeIntent = ["payloadCreated", "produced", "synced"].contains(boundary)
        if action == "forward" || action == "reverse" {
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("generated process source".utf8).write(to: input, options: .withoutOverwriting)
            var hooks = RecoveryHooks()
            if action == "forward" {
                hooks.archiveProduction.stage = { stage, _ in if stage.rawValue == boundary { Self.crash(boundary) } }
                hooks.afterIntent = { if boundary == "intent" { Self.crash(boundary) } }
                hooks.afterRename = { if boundary == "rename" { Self.crash(boundary) } }
            }
            let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
            let selection = try await engine.observeSelection([input])
            let plan = try await engine.prepareZIPCreation(sources: [input], parent: parent, name: "Created.zip", observing: selection)
            let result = await engine.performArchiveCreation(plan)
            try #require(result.result.disposition == .succeeded)
            if action == "reverse" {
                var reverse = RecoveryHooks()
                reverse.beforeRename = { if boundary == "reverse-before" { Self.crash(boundary) } }
                reverse.afterRename = { if boundary == "reverse-rename" { Self.crash(boundary) } }
                let cold = RecoverableFileOperations(journalDirectory: journal, hooks: reverse)
                _ = await cold.undo(recordID: try #require(result.recordID))
            }
            Issue.record("Requested creation interruption did not occur")
        } else {
            let engine = RecoverableFileOperations(journalDirectory: journal)
            let inspection = try await engine.inspectExistingHistory(), record = try #require(inspection.records.first)
            try #require(inspection.records.count == 1 && inspection.refusedEntries.isEmpty && record.operation == "Create ZIP")
            var report: [String: Any] = ["event": action, "pid": getpid(), "recordID": record.id.uuidString, "passed": true]
            if action == "recover" {
                let recovered = record.canUndo ? await engine.undo(recordID: record.id) : await engine.recover(recordID: record.id)
                try #require((recovered.result.disposition == .succeeded) == !beforeIntent)
                let retained = try await engine.retentionRecord(recordID: record.id)
                try #require(retained.canCleanup == !beforeIntent)
                try #require(!FileManager().fileExists(atPath: parent.appendingPathComponent("Created.zip").path))
                let expected = Data("generated process source".utf8)
                try #require(Data(SHA256.hash(data: Data(contentsOf: input))) == Data(SHA256.hash(data: expected)))
                report["recoverSucceeded"] = recovered.result.disposition == .succeeded
                report["cleanupQualified"] = retained.canCleanup
                report["sourceUnchanged"] = true
            } else { try #require(action == "inspect") }
            Self.emit(report)
        }
    }
    private static func emit(_ report: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MAC_EXPLORER_ARCHIVE_CHILD " + String(decoding: bytes, as: UTF8.self)); fflush(stdout)
    }
    private static func crash(_ boundary: String) -> Never {
        emit(["event": "crash", "boundary": boundary, "pid": getpid(), "exit": 86]); _exit(86)
    }
}
