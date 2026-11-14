import Darwin
import Foundation

private final class GuardedTrashCrashGate: @unchecked Sendable {
    let boundary: String
    private let lock = NSLock()
    private var moved = false, commits = 0
    init(_ boundary: String) { self.boundary = boundary }
    func nativeReturned() { lock.withLock { moved = true } }
    func committed() {
        let crash = lock.withLock { () -> Bool in
            guard moved else { return false }; commits += 1
            return boundary == "validated" && commits == 2
        }
        if crash { _exit(86) }
    }
}

@main struct GuardedTrashProcessWorker {
    static func emit(_ value: [String: String]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
        FileHandle.standardOutput.write(Data([10]))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["intent", "native", "validated"].contains(args[3]),
              ["run", "inspect", "recover"].contains(args[1]) else { throw FileOperationFailure.invalidRequest }
        let root = URL(fileURLWithPath: args[2]), phase = args[1], boundary = args[3]
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/test-fixtures")
        guard root.deletingLastPathComponent().path == base.path, root.lastPathComponent.hasPrefix("guarded-crash-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(14))) != nil,
              base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        let marker = root.appendingPathComponent(".owned-guarded-trash"), source = root.appendingPathComponent("Selected.txt")
        let token = Data("Generated guarded Trash process fixture v1\n\(root.lastPathComponent)\n".utf8)
        if phase == "run" {
            guard mkdir(root.path,0o700) == 0 else { throw FileOperationFailure.conflict }
            try token.write(to: marker, options: .withoutOverwriting); guard chmod(marker.path,0o600) == 0 else { throw posixFailure() }
            try Data("Generated process interruption data".utf8).write(to: source,options: .withoutOverwriting)
        } else {
            _ = try DirectoryAnchor(root,resolve:false)
            guard try Data(contentsOf: marker) == token else { throw FileOperationFailure.invalidRequest }
        }
        let journal = root.appendingPathComponent("journal")
        if phase == "run" {
            let gate = GuardedTrashCrashGate(boundary)
            let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(afterCommitBeforeAcknowledgement: { gate.committed() }))
            let legacy = LocalFileOperations(trash: { url in
                if boundary == "intent" { _exit(86) }
                var returned: NSURL?
                try FileManager().trashItem(at:url,resultingItemURL:&returned)
                guard let target = returned as URL? else { throw FileOperationFailure.recoveryUncertain }
                // This generated returned location is evidence, not authority
                // for the cold recovery process to adopt an unrecorded target.
                try Data(target.path.utf8).write(to:root.appendingPathComponent("native-returned.txt"),options:.withoutOverwriting)
                if boundary == "native" { _exit(86) }
                gate.nativeReturned(); return target
            })
            let engine = RecoverableFileOperations(journalDirectory:journal,hooks:hooks,legacy:legacy)
            let selection = try await engine.prepareGuardedTrash([source],protecting:[])
            _ = await engine.performGuardedTrash(selection)
            throw FileOperationFailure.invalidRequest // every requested boundary must fire
        }
        let engine = RecoverableFileOperations(journalDirectory:journal)
        let history = try await engine.inspectExistingHistory()
        guard history.records.count == 1, let record = history.records.first else { throw FileOperationFailure.recoveryUncertain }
        var result = ["pid":String(getpid()),"recordID":record.id.uuidString,"state":record.state,
                      "sourcePresent":FileManager().fileExists(atPath:source.path) ? "true" : "false",
                      "unfinished":String(history.unfinishedCount),"canUndo":String(record.canUndo),"canRecover":String(record.canRecover)]
        if phase == "recover" {
            guard boundary != "native" else { throw FileOperationFailure.invalidRequest }
            let restored = await engine.recover(recordID:record.id)
            result["disposition"] = restored.result.disposition.rawValue
            result["sourcePresent"] = FileManager().fileExists(atPath:source.path) ? "true" : "false"
        }
        try emit(result)
    }
}
