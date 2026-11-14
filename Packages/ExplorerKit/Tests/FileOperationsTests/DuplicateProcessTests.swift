import Darwin
import Foundation
import Testing
@testable import FileOperations

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_DUPLICATE_PROCESS_ROOT"] != nil))
struct DuplicateProcessTests {
    @Test func child() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["MAC_EXPLORER_DUPLICATE_PROCESS_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-duplicate")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path))
        let parent = root.appendingPathComponent("source/Items"), journal = root.appendingPathComponent("source/journal")
        let action = try #require(env["MAC_EXPLORER_DUPLICATE_PROCESS_ACTION"])
        let boundary = try #require(env["MAC_EXPLORER_DUPLICATE_PROCESS_BOUNDARY"])
        let names = ["A.txt", "B.txt"], sources = names.map { parent.appendingPathComponent($0) }
        if action == "forward" || action == "reverse" {
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
            for source in sources { try Data("generated \(source.lastPathComponent)".utf8).write(to: source, options: .withoutOverwriting) }
            var hooks = RecoveryHooks()
            if action == "forward" {
                hooks.afterIntent = { if boundary == "intent" { Self.crash(boundary) } }
                hooks.afterRename = { if boundary == "rename" { Self.crash(boundary) } }
            }
            let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
            let plan = try await engine.prepareTransfer(sources: sources, destinationDirectory: parent, move: false)
            let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.keepBoth) })
            let result = await engine.perform(plan, resolutions: choices)
            try #require(result.result.disposition == .succeeded)
            if boundary == "committed" { Self.crash(boundary) }
            if action == "reverse" {
                var reverse = RecoveryHooks()
                reverse.beforeRename = { if boundary == "reverse-before" { Self.crash(boundary) } }
                reverse.afterRename = { if boundary == "reverse-rename" { Self.crash(boundary) } }
                _ = await RecoverableFileOperations(journalDirectory: journal, hooks: reverse).undo(recordID: try #require(result.recordID))
            }
            Issue.record("Requested Duplicate interruption did not occur")
        } else {
            let engine = RecoverableFileOperations(journalDirectory: journal)
            let inspection = try await engine.inspectExistingHistory(), record = try #require(inspection.records.first)
            try #require(inspection.records.count == 1 && inspection.refusedEntries.isEmpty && record.operation == "Copy")
            if action == "recover" {
                let result = record.canUndo ? await engine.undo(recordID: record.id) : await engine.recover(recordID: record.id)
                try #require(result.result.disposition == .succeeded)
                for source in sources {
                    try #require(Data(contentsOf: source) == Data("generated \(source.lastPathComponent)".utf8))
                    try #require(!FileManager().fileExists(atPath: parent.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (1).txt").path))
                }
            } else { try #require(action == "inspect") }
            Self.emit(["event": action, "pid": getpid(), "recordID": record.id.uuidString, "passed": true])
        }
    }
    private static func emit(_ value: [String: Any]) {
        print("MAC_EXPLORER_DUPLICATE_CHILD " + String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
    }
    private static func crash(_ boundary: String) -> Never { emit(["event": "crash", "pid": getpid(), "boundary": boundary]); _exit(86) }
}
