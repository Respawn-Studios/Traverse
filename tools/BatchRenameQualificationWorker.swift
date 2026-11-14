import Darwin
import Foundation

private final class BatchOrdinal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var current: Int { lock.withLock { value } }
}

@main struct BatchRenameQualificationWorker {
    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw FileOperationFailure.invalidRequest }
        let phase = args[1], boundary = args[3], root = URL(fileURLWithPath: args[2])
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repository.appendingPathComponent(".build/b09-batch-rename"),
              UUID(uuidString: root.lastPathComponent) != nil, root.resolvingSymlinksInPath() == root,
              FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path) else { throw FileOperationFailure.invalidRequest }
        let source = root.appendingPathComponent("source"), parent = source.appendingPathComponent("Items"), journal = source.appendingPathComponent("journal")
        let marker = source.appendingPathComponent(".owned-batch-rename"), token = Data("Generated batch Rename fixture v1\n\(root.lastPathComponent)\n".utf8)
        let names = ["A.txt", "B.txt", "C.txt"], seeding = ["forward", "reverse"].contains(phase)
        if seeding {
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try token.write(to: marker, options: .withoutOverwriting)
            for name in names { try Data("Generated \(name)\n".utf8).write(to: parent.appendingPathComponent(name), options: .withoutOverwriting) }
        } else { guard try Data(contentsOf: marker) == token else { throw FileOperationFailure.invalidRequest } }
        let saves = BatchOrdinal(), syscalls = BatchOrdinal()
        let stop: @Sendable () -> Void = {
            try! emit(["pid": getpid(), "phase": phase, "boundary": boundary, "saves": saves.current, "syscalls": syscalls.current])
            _exit(86)
        }
        var hooks = RecoveryHooks()
        hooks.afterRename = { if syscalls.next() == 2 && boundary == "second-syscall" { stop() } }
        hooks.journalHooks.beforeSaveCommit = { _ = saves.next() }
        hooks.journalHooks.afterSaveCommit = {
            let ordinal = saves.current
            if boundary == "first-commit", ordinal == (phase == "forward" ? 4 : 3) { stop() }
            if boundary == "second-intent", ordinal == 6 { stop() }
            if boundary == "second-commit", ordinal == 8 { stop() }
        }
        if seeding {
            let service = RecoverableFileOperations(journalDirectory: journal, hooks: phase == "forward" ? hooks : .init())
            let urls = names.map { parent.appendingPathComponent($0) }
            let plan = try await service.prepareBatchRename(sources: urls,
                rule: .addText(prefix: "New ", suffix: "", preserveExtension: true), observing: service.observeSelection(urls))
            let batch = await service.performBatchRename(plan)
            guard phase == "reverse", batch.result.disposition == .succeeded else { throw FileOperationFailure.recoveryUncertain }
            let reverse = RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
            for id in batch.completedRecordIDs.reversed() { _ = await reverse.undo(recordID: id) }
            throw FileOperationFailure.recoveryUncertain
        }
        let service = RecoverableFileOperations(journalDirectory: journal)
        if phase == "recover" {
            let page = try await service.recoveryRecords()
            guard page.refusedEntries.isEmpty else { throw FileOperationFailure.recoveryUncertain }
            for record in page.records where record.state != "undone" {
                let restored = record.canUndo ? await service.undo(recordID: record.id) : await service.recover(recordID: record.id)
                guard restored.result.disposition == .succeeded else { throw FileOperationFailure.recoveryUncertain }
            }
            for name in names {
                guard try Data(contentsOf: parent.appendingPathComponent(name)) == Data("Generated \(name)\n".utf8),
                      !FileManager().fileExists(atPath: parent.appendingPathComponent("New " + name).path) else { throw FileOperationFailure.recoveryUncertain }
            }
        } else if phase != "inspect" { throw FileOperationFailure.invalidRequest }
        let page = try await service.inspectExistingHistory()
        guard page.refusedEntries.isEmpty, !page.records.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        let actual = try FileManager().contentsOfDirectory(atPath: parent.path).sorted()
        if phase == "recover" { guard actual == names, page.records.allSatisfy({ $0.state == "undone" }) else { throw FileOperationFailure.recoveryUncertain } }
        try emit(["pid": getpid(), "phase": phase, "names": actual, "states": page.records.map(\.state), "records": page.records.map { $0.id.uuidString },
            "readiness": String(describing: page.readiness)])
    }
}
