import Darwin
import Foundation
import CryptoKit

/// This worker intentionally uses APIs available in the baseline catalog-v2
/// implementation, so the same source can qualify both old and new engines.
@main struct RenameCompatibilityProfileWorker {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw FileOperationFailure.invalidRequest }
        let mode = args[1], root = URL(fileURLWithPath: args[2])
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base = repo.appendingPathComponent(".build/test-fixtures")
        guard root.deletingLastPathComponent().path == base.path,
              root.lastPathComponent.hasPrefix("name-rename-"), UUID(uuidString: String(root.lastPathComponent.dropFirst(12))) != nil,
              base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        let token = Data("MacExplorer generated name-rename fixture v1\n\(root.lastPathComponent)\n".utf8)
        let marker = root.appendingPathComponent(".owned-name-rename-fixture")
        if mode == "old-reader" {
            _ = try DirectoryAnchor(root, resolve: false)
            guard try Data(contentsOf: marker) == token else { throw FileOperationFailure.invalidRequest }
            let service = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal"))
            let page = try await service.recoveryRecords()
            let result = await service.perform(.createFolder(parent: root, name: "old-build-must-not-write"))
            guard !page.refusedEntries.isEmpty, page.records.isEmpty, result.result.disposition == .failed,
                  !FileManager().fileExists(atPath: root.appendingPathComponent("old-build-must-not-write").path) else { throw FileOperationFailure.recoveryUncertain }
            print("{\"oldReaderRefused\":true,\"mutationRefused\":true}")
            return
        }
        guard ["profile", "legacy-seed"].contains(mode), mkdir(root.path, 0o700) == 0 else { throw FileOperationFailure.invalidRequest }
        try token.write(to: marker, options: .withoutOverwriting)
        if mode == "legacy-seed" {
            let source = root.appendingPathComponent("before.txt")
            try Data("generated original".utf8).write(to: source, options: .withoutOverwriting)
            let journalURL = root.appendingPathComponent("journal")
            let result = await RecoverableFileOperations(journalDirectory: journalURL).perform(.rename(source: source, name: "after.txt"))
            guard result.result.disposition == .succeeded, let id = result.recordID,
                  let record = try OperationJournal(journalURL).inspectRecord(id), record.version == 1 else { throw FileOperationFailure.recoveryUncertain }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
            print("{\"recordID\":\"\(id.uuidString)\",\"recordHash\":\"\(hash)\",\"version\":1}")
            return
        }
        var rows: [[String: Any]] = []
        for (label, size, children) in [("empty-file", 0, 0), ("32MiB-file", 32 * 1024 * 1024, 0),
                                        ("128MiB-file", 128 * 1024 * 1024, 0), ("1000-child-folder", 0, 1000)] {
            for sample in 0..<3 {
                let area = root.appendingPathComponent("\(label)-\(sample)")
                try FileManager().createDirectory(at: area, withIntermediateDirectories: false)
                let source = area.appendingPathComponent("before"), target = area.appendingPathComponent("after")
                if children > 0 {
                    try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
                    for index in 0..<children { try Data().write(to: source.appendingPathComponent("child-\(index)"), options: .withoutOverwriting) }
                } else {
                    let fd = open(source.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else { throw FileOperationFailure.ioFailure }
                    close(fd)
                }
                let before = try verifiedTree(source, cancellation: OperationCancellation())
                let service = RecoverableFileOperations(journalDirectory: area.appendingPathComponent("journal"))
                let start = ProcessInfo.processInfo.systemUptime
                let result = await service.perform(.rename(source: source, name: "after"))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                guard result.result.disposition == .succeeded, let id = result.recordID,
                      before.matches(try verifiedTree(target, cancellation: OperationCancellation())) else { throw FileOperationFailure.recoveryUncertain }
                let journal = try OperationJournal(area.appendingPathComponent("journal"))
                guard let record = try journal.inspectRecord(id), record.state == "committed" else { throw FileOperationFailure.recoveryUncertain }
                rows.append(["case": label, "sample": sample, "seconds": elapsed, "recordVersion": record.version,
                             "legacyTreeSteps": record.steps.count, "payloadVerified": true])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows, "passed": true, "pid": getpid()], options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
