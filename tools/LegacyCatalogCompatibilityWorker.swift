import CryptoKit
import Darwin
import Foundation
import SQLite3

// Shared helpers deliberately use only the pinned schema-3 production API.
// Both executables compile this exact frozen source; only the old binary gets @main.
internal enum CatalogFixture {
    static let markerName = ".owned-grouped-catalog-fixture"
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func directory(_ url: URL) throws {
        guard url.path == url.standardizedFileURL.path, url.resolvingSymlinksInPath().path == url.path else {
            throw FileOperationFailure.invalidRequest
        }
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
              s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else { throw FileOperationFailure.accessDenied }
    }
    static func read(_ url: URL, maximum: Int = 67_108_864) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.ioFailure }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid(),
              s.st_nlink == 1, s.st_mode & 0o077 == 0, s.st_size >= 0,
              s.st_size <= maximum else { throw FileOperationFailure.accessDenied }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw FileOperationFailure.ioFailure }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw FileOperationFailure.unsupported }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, s.st_dev == after.st_dev, s.st_ino == after.st_ino,
              s.st_size == after.st_size, s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw FileOperationFailure.sourceChanged }
        return data
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw FileOperationFailure.ioFailure }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw FileOperationFailure.ioFailure }
    }
    static func makeDirectory(_ url: URL) throws {
        try directory(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o700) == 0 else { throw FileOperationFailure.invalidRequest }
        try directory(url)
    }
    static func root(_ argument: String, create: Bool = false) throws -> URL {
        let run = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard ProcessInfo.processInfo.environment["MAC_EXPLORER_GROUPED_CATALOG_RUN_ROOT"] == run.path,
              UUID(uuidString: run.lastPathComponent) != nil,
              run.deletingLastPathComponent().lastPathComponent == "grouped-catalog-qualification",
              run.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build" else {
            throw FileOperationFailure.invalidRequest
        }
        try directory(run)
        guard try read(run.appendingPathComponent(".qualification-owner"), maximum: 256) ==
                Data("MacExplorer grouped catalog qualification v1\n\(run.lastPathComponent)\n".utf8) else {
            throw FileOperationFailure.invalidRequest
        }
        let fixtures = run.appendingPathComponent("fixtures")
        try directory(fixtures)
        let root = URL(fileURLWithPath: argument)
        guard root.path == argument, root.deletingLastPathComponent().path == fixtures.path,
              root.lastPathComponent.hasPrefix("catalog-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(8))) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        let token = Data("MacExplorer generated grouped catalog fixture v1\n\(root.lastPathComponent)\n".utf8)
        if create { try makeDirectory(root); try write(token, to: root.appendingPathComponent(markerName)) }
        try directory(root)
        guard try read(root.appendingPathComponent(markerName), maximum: 256) == token else {
            throw FileOperationFailure.invalidRequest
        }
        return root
    }
    // Bounded private-fixture walk. Paths/contents never appear in receipts.
    static func fingerprint(_ root: URL, excluding: Set<String> = []) throws -> String {
        var rows: [String] = [], count = 0, bytes = 0
        func walk(_ url: URL, _ relative: String, _ depth: Int) throws {
            guard depth <= 16, count < 512 else { throw FileOperationFailure.unsupported }
            count += 1
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
                throw FileOperationFailure.accessDenied
            }
            let kind = s.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { throw FileOperationFailure.unsupported }
            rows.append("\(relative)|\(s.st_dev)|\(s.st_ino)|\(s.st_mode)|\(s.st_size)|\(s.st_mtimespec.tv_sec)|\(s.st_mtimespec.tv_nsec)")
            if kind == S_IFDIR {
                try directory(url)
                let children = try FileManager().contentsOfDirectory(atPath: url.path).sorted()
                guard children.count <= 512 else { throw FileOperationFailure.unsupported }
                for child in children {
                    if relative.isEmpty && excluding.contains(child) { continue }
                    try validateName(child)
                    try walk(url.appendingPathComponent(child), relative.isEmpty ? child : relative + "/" + child, depth + 1)
                }
            } else {
                let data = try read(url); bytes += data.count
                guard bytes <= 134_217_728 else { throw FileOperationFailure.unsupported }
                rows.append(digest(data))
            }
        }
        try walk(root, "", 0)
        return digest(Data(rows.joined(separator: "\n").utf8))
    }
    static func sql(_ root: URL, query: String) throws -> [[String]] {
        let url = root.appendingPathComponent("journal/operations-v2.sqlite")
        _ = try read(url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FileOperationFailure.recoveryUncertain
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = [], decodedBytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, rows.count < 65_536 else { throw FileOperationFailure.recoveryUncertain }
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                let count = Int(sqlite3_column_bytes(statement, column))
                decodedBytes += count
                guard count <= 67_108_864, decodedBytes <= 134_217_728 else { throw FileOperationFailure.unsupported }
                row.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "<NULL>")
            }
            rows.append(row)
        }
        return rows
    }
    static func schema(_ root: URL) throws -> Int {
        let pragma = try sql(root, query: "PRAGMA user_version")
        let metadata = try sql(root, query: "SELECT value FROM metadata WHERE key='version'")
        guard let text = pragma.first?.first, let value = Int(text), metadata == [[text]] else {
            throw FileOperationFailure.recoveryUncertain
        }
        return value
    }
    static func legacyRows(_ root: URL) throws -> String {
        var tables: [[[String]]] = []
        for query in [
            "SELECT id,revision,created_at,state,hex(head),checksum,bytes FROM jobs ORDER BY id",
            "SELECT job,ordinal,hex(payload),checksum FROM steps ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM areas ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM locations ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM trash_intents ORDER BY job,ordinal",
            "SELECT job,revision,state FROM events ORDER BY job,revision",
            "SELECT job,revision,digest,last_name FROM legacy_imports ORDER BY job"
        ] { tables.append(try sql(root, query: query)) }
        return digest(try encode(tables))
    }
    static func legacyEvidence(_ root: URL) throws -> String {
        let journal = root.appendingPathComponent("journal")
        try directory(journal)
        let names = try FileManager().contentsOfDirectory(atPath: journal.path).filter { $0.hasSuffix(".json") }.sorted()
        guard names.count <= 32 else { throw FileOperationFailure.unsupported }
        var values: [String: String] = [:]
        for name in names { try validateName(name); values[name] = digest(try read(journal.appendingPathComponent(name), maximum: 4_194_304)) }
        return digest(try encode(values))
    }
    static func manifest(_ root: URL) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: read(root.appendingPathComponent("seed.json"), maximum: 16_384))
    }
}

#if LEGACY_CATALOG_WORKER
@main
#endif
internal enum LegacyCatalogCompatibilityWorker {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw FileOperationFailure.invalidRequest }
        let phase = arguments[1]
        guard ["seed-empty", "seed-mixed", "old-reader"].contains(phase) else { throw FileOperationFailure.invalidRequest }
        let root = try CatalogFixture.root(arguments[2], create: phase != "old-reader")
        let journalURL = root.appendingPathComponent("journal")
        if phase == "old-reader" {
            let before = try CatalogFixture.fingerprint(root)
            let service = RecoverableFileOperations(journalDirectory: journalURL)
            let page = try await service.recoveryRecords()
            let folder = await service.perform(.createFolder(parent: root.appendingPathComponent("destination"), name: "refused-folder"))
            let copy = await service.perform(.copy(sources: [root.appendingPathComponent("source/refusal.txt")],
                                                   destinationDirectory: root.appendingPathComponent("destination")))
            guard page.records.isEmpty, !page.refusedEntries.isEmpty,
                  folder.result.disposition == .failed, folder.recordID == nil,
                  copy.result.disposition == .failed, copy.recordID == nil,
                  try CatalogFixture.fingerprint(root) == before else { throw FileOperationFailure.recoveryUncertain }
            try CatalogFixture.emit(["pid": getpid(), "oldReaderRefused": true, "newFolderRefused": true,
                                     "copyRefused": true, "namespaceAndJournalUnchanged": true, "fingerprint": before])
            return
        }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try CatalogFixture.makeDirectory(source); try CatalogFixture.makeDirectory(destination)
        try CatalogFixture.write(Data("generated refusal fixture".utf8), to: source.appendingPathComponent("refusal.txt"))
        var manifest: [String: String] = [:]
        if phase == "seed-mixed" {
            try CatalogFixture.write(Data("generated Copy fixture".utf8), to: source.appendingPathComponent("copy.txt"))
            try CatalogFixture.write(Data("generated Rename fixture".utf8), to: source.appendingPathComponent("before.txt"))
            let service = RecoverableFileOperations(journalDirectory: journalURL)
            let copy = await service.perform(.copy(sources: [source.appendingPathComponent("copy.txt")], destinationDirectory: destination))
            let rename = await service.perform(.rename(source: source.appendingPathComponent("before.txt"), name: "after.txt"))
            guard copy.result.disposition == .succeeded, rename.result.disposition == .succeeded,
                  let copyID = copy.recordID, let renameID = rename.recordID else { throw FileOperationFailure.recoveryUncertain }
            let journal = try OperationJournal(journalURL)
            guard let first = try journal.inspectRecord(copyID), first.version == 1, first.operation == "Copy",
                  let second = try journal.inspectRecord(renameID), second.version == 2, second.nameRename != nil else {
                throw FileOperationFailure.recoveryUncertain
            }
            manifest[copyID.uuidString] = CatalogFixture.digest(try CatalogFixture.encode(first))
            manifest[renameID.uuidString] = CatalogFixture.digest(try CatalogFixture.encode(second))
        } else {
            try OperationJournal(journalURL).validateWritableCatalog()
        }
        if phase == "seed-mixed" {
            // A genuine legacy JSON revision at the pre-staging boundary. Import
            // it with the old production reader, then retain the original bytes.
            let owner = try { () throws -> UUID in try OperationJournal(journalURL).owner }()
            let id = UUID()
            var evidence = JournalRecord(version: 1, owner: owner, id: id, operation: "Copy")
            evidence.locations = [source, destination]
            try CatalogFixture.write(CatalogFixture.encode(evidence),
                to: journalURL.appendingPathComponent("\(id.uuidString)-000000.json"))
            guard let imported = try OperationJournal(journalURL).inspectRecord(id), imported.version == 1 else {
                throw FileOperationFailure.recoveryUncertain
            }
            manifest[id.uuidString] = CatalogFixture.digest(try CatalogFixture.encode(imported))
        }
        guard try CatalogFixture.schema(root) == 3 else { throw FileOperationFailure.recoveryUncertain }
        manifest["legacyRows"] = try CatalogFixture.legacyRows(root)
        manifest["legacyJSON"] = try CatalogFixture.legacyEvidence(root)
        try CatalogFixture.write(CatalogFixture.encode(manifest), to: root.appendingPathComponent("seed.json"))
        try CatalogFixture.emit(["pid": getpid(), "schema": 3, "legacyRecordCount": manifest.count - 2,
                                 "legacyRowsHash": manifest["legacyRows"]!])
    }
}
