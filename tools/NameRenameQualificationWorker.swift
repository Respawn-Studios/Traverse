import Darwin
import Foundation
import CryptoKit

private final class SaveOrdinal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var current: Int { lock.withLock { value } }
}

@main struct NameRenameQualificationWorker {
    static func emit(_ value: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw FileOperationFailure.invalidRequest }
        let phase = args[1], root = URL(fileURLWithPath: args[2]), boundary = args[3]
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/test-fixtures")
        guard root.deletingLastPathComponent().path == base.path,
              root.lastPathComponent.hasPrefix("name-rename-"), UUID(uuidString: String(root.lastPathComponent.dropFirst(12))) != nil,
              base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        let marker = root.appendingPathComponent(".owned-name-rename-fixture")
        let token = Data("MacExplorer generated name-rename fixture v1\n\(root.lastPathComponent)\n".utf8)
        let source = root.appendingPathComponent("Case.txt"), target = root.appendingPathComponent("case.txt")
        let journal = root.appendingPathComponent("journal")
        let seeding = ["forward", "reverse", "complete"].contains(phase)
        if seeding {
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
            guard mkdir(root.path, 0o700) == 0 else { throw FileOperationFailure.conflict }
            try token.write(to: marker, options: .withoutOverwriting)
            try Data("generated original".utf8).write(to: source, options: .withoutOverwriting)
        } else {
            _ = try DirectoryAnchor(root, resolve: false)
            var st = stat()
            guard lstat(marker.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
                  st.st_uid == geteuid(), try Data(contentsOf: marker) == token else { throw FileOperationFailure.invalidRequest }
        }
        let counter = SaveOrdinal()
        let stop: @Sendable () -> Void = {
            try! emit(["phase": phase, "boundary": boundary, "terminationCode": "86", "pid": String(getpid())])
            _exit(86)
        }
        var hooks = RecoveryHooks()
        if seeding && phase != "complete" {
            hooks.afterIntent = { if boundary == "intent" { stop() } }
            hooks.afterRename = { if boundary == "syscall" { stop() } }
            hooks.journalHooks.beforeSaveCommit = {
                let ordinal = counter.next()
                if boundary == "sync" && ordinal == (phase == "forward" ? 3 : 2) { stop() }
            }
            hooks.journalHooks.afterSaveCommit = {
                let ordinal = counter.current
                if boundary == "prepared" && phase == "forward" && ordinal == 1 { stop() }
                if boundary == "applied" && ordinal == (phase == "forward" ? 3 : 2) { stop() }
                if boundary == "committed" && ordinal == (phase == "forward" ? 4 : 3) { stop() }
            }
        }
        let service = RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
        if phase == "legacy-migrate" {
            let page = try await service.recoveryRecords()
            guard page.refusedEntries.isEmpty, let summary = page.records.first,
                  summary.operation == "Rename (unchanged contents required)",
                  let record = try OperationJournal(journal).inspectRecord(summary.id),
                  record.version == 1, record.nameRename == nil else { throw FileOperationFailure.recoveryUncertain }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
            let target = root.appendingPathComponent("after.txt")
            let handle = try FileHandle(forWritingTo: target)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("edited old-format file".utf8)); try handle.close()
            let undo = await service.undo(recordID: summary.id)
            guard undo.result.disposition == .failed, try Data(contentsOf: target) == Data("edited old-format file".utf8),
                  !FileManager().fileExists(atPath: root.appendingPathComponent("before.txt").path) else { throw FileOperationFailure.recoveryUncertain }
            try emit(["recordID": summary.id.uuidString, "recordHash": hash, "legacyEditedUndoRefused": "true"])
            return
        }
        if phase == "forward" || phase == "complete" {
            let result = await service.perform(.rename(source: source, name: "case.txt"))
            guard result.result.disposition == .succeeded, result.recordID != nil else { throw FileOperationFailure.recoveryUncertain }
            guard phase == "complete" else { throw FileOperationFailure.recoveryUncertain }
        } else if phase == "reverse" {
            let result = await RecoverableFileOperations(journalDirectory: journal).perform(.rename(source: source, name: "case.txt"))
            guard let id = result.recordID, result.result.disposition == .succeeded else { throw FileOperationFailure.recoveryUncertain }
            let result2 = await service.undo(recordID: id)
            _ = result2
            throw FileOperationFailure.recoveryUncertain // Requested boundary must terminate.
        } else if phase == "recover" {
            let page = try await service.recoveryRecords()
            guard page.refusedEntries.isEmpty, let summary = page.records.first else { throw FileOperationFailure.recoveryUncertain }
            // External in-place edit after interruption; recovery must keep it.
            let handle = try FileHandle(forWritingTo: target)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("edited while interrupted".utf8)); try handle.close()
            if summary.state != "undone" {
                let result = summary.state == "committed" ? await service.undo(recordID: summary.id) : await service.recover(recordID: summary.id)
                guard result.result.disposition == .succeeded else { throw FileOperationFailure.recoveryUncertain }
            }
            let entry = try NativeRenameEntry.observe(parent: DirectoryAnchor(root), name: "Case.txt")
            guard entry.nameBytes == Data("Case.txt".utf8), try Data(contentsOf: source) == Data("edited while interrupted".utf8) else { throw FileOperationFailure.recoveryUncertain }
        } else if phase != "inspect" { throw FileOperationFailure.invalidRequest }
        let page = try await service.recoveryRecords()
        guard page.refusedEntries.isEmpty, let summary = page.records.first,
              let record = try OperationJournal(journal).inspectRecord(summary.id), let rename = record.nameRename else { throw FileOperationFailure.recoveryUncertain }
        let entry = try NativeRenameEntry.observe(parent: DirectoryAnchor(root), name: "Case.txt")
        try emit(["phase": phase, "boundary": boundary, "pid": String(getpid()), "recordID": summary.id.uuidString,
                  "state": record.state, "renamePhase": rename.phase.rawValue, "storedName": entry.name,
                  "canUndo": String(summary.canUndo), "canRecover": String(summary.canRecover)])
    }
}
