import Darwin
import Foundation

/// One worker owns the budget and SQLite callback; it never escapes the inspection.
internal final class OperationHistoryReadBudget {
    private let cancellation: OperationCancellation
    private let deadline: TimeInterval
    private let maximumCallbacks: Int
    private var callbacks = 0
    private(set) var exhausted = false

    init(cancellation: OperationCancellation, seconds: TimeInterval = 3, maximumCallbacks: Int = 5_000) {
        self.cancellation = cancellation
        deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        self.maximumCallbacks = max(0, maximumCallbacks)
    }
    func check() throws {
        try cancellation.check()
        if exhausted || ProcessInfo.processInfo.systemUptime >= deadline {
            exhausted = true; throw FileOperationFailure.unavailable
        }
    }
    func advance() -> Bool {
        callbacks += 1
        if callbacks > maximumCallbacks { exhausted = true; return false }
        do { try check(); return true } catch { return false }
    }
}

internal struct OperationHistoryInspectionHooks: Sendable {
    var beforeStoreOpen: (@Sendable () throws -> Void)?
    var beforeFinalValidation: (@Sendable () throws -> Void)?
}

private enum HistoryInspectionRefusal: Error { case entryLimit }

/// Existing private history only. Results are display hints, never mutation authority.
internal enum OperationHistoryInspector {
    /// Selected immutable record for passive backup/recovery inspection. No
    /// writable journal is constructed; physical backup verification follows
    /// after the catalog lease has drained and mutation revalidates separately.
    static func record(_ directory: URL, id: UUID, cancellation: OperationCancellation,
                       selectionHistory: SelectionGroupHistoryIdentity? = nil) throws -> OperationCatalogRecord {
        guard let value = try recordIfPresent(directory, id: id, cancellation: cancellation, selectionHistory: selectionHistory) else {
            throw FileOperationFailure.notFound
        }
        return value
    }

    static func recordIfPresent(_ directory:URL,id:UUID,cancellation:OperationCancellation,
        selectionHistory:SelectionGroupHistoryIdentity? = nil) throws -> OperationCatalogRecord? {
        if let selectionHistory {
            return try selectedHistoryRecord10(directory,id:id,cancellation:cancellation,selectionHistory:selectionHistory)
        }
        return try textRead10(directory,cancellation:cancellation) {store in
            return try store.catalogRecord(id)
        } ?? nil
    }

    private static func selectedHistoryRecord10(_ directory: URL, id: UUID, cancellation: OperationCancellation,
                                selectionHistory: SelectionGroupHistoryIdentity? = nil) throws -> OperationCatalogRecord? {
        try selectionHistory?.validate(directory)
        let inspection = try inspect(directory, cancellation: cancellation)
        if inspection.readiness == .absent {
            guard selectionHistory == nil else { throw FileOperationFailure.sourceChanged }
            return nil
        }
        guard case .available = inspection.readiness else { throw FileOperationFailure.unavailable }
        let anchor = try DirectoryAnchor(directory, resolve: false)
        let marker = ".mac-explorer-journal-v1"
        let fd = openat(anchor.fd, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        var st = stat(), root = stat()
        guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, st.st_nlink == 1,
              fstat(anchor.fd, &root) == 0, root.st_uid == geteuid(), root.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw FileOperationFailure.unavailable }
        let ownerIdentity = try EntrySnapshot(fd: fd)
        guard let text = String(data: try OperationJournal.read(name: marker, anchor: anchor), encoding: .utf8),
              let owner = UUID(uuidString: text) else { throw FileOperationFailure.recoveryUncertain }
        func snapshot() throws -> [String: EntrySnapshot] {
            let names = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: 16_384)
            return try Dictionary(uniqueKeysWithValues: names.map { ($0, try EntrySnapshot(parent: anchor.fd, name: $0)) })
        }
        let before = try snapshot()
        guard before[marker] == ownerIdentity else { throw FileOperationFailure.sourceChanged }
        try selectionHistory?.validateOpened(anchor: anchor, markerFD: fd, owner: owner,
            database: EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name))
        let store = try SQLiteJournalStore(readOnly: anchor, owner: owner, budget: OperationHistoryReadBudget(cancellation: cancellation))
        if let selectionHistory {
            try selectionHistory.validateOpened(anchor: anchor, markerFD: fd, owner: owner, database: store.fileIdentity)
            guard [7, 9, 10].contains(store.inspectedCatalogVersion) else { throw FileOperationFailure.recoveryUncertain }
            try store.validateCatalog(cancellation: cancellation)
        }
        let record = try store.catalogRecord(id)
        try store.validateFiles(); try anchor.validate(); try cancellation.check()
        guard try snapshot() == before, try EntrySnapshot(fd: fd) == ownerIdentity else { throw FileOperationFailure.sourceChanged }
        try selectionHistory?.validateOpened(anchor: anchor, markerFD: fd, owner: owner, database: store.fileIdentity)
        return record
    }

    static func inspect(_ directory: URL, after: UUID? = nil, limit: Int = 64,
                        cancellation: OperationCancellation,
                        hooks: OperationHistoryInspectionHooks = .init(),
                        budget suppliedBudget: OperationHistoryReadBudget? = nil,
                        maximumEntries: Int = 16_384,
                        allowDownloadAdoptionUndoHint: Bool = false,
                        allowNativeOriginalUpdateUndoHint: Bool = false,
        allowNativeTARUpdateUndoHint: Bool = false,
        allowNativeTARGzipUpdateUndoHint: Bool = false,
        allowNativeTARBzip2UpdateUndoHint: Bool = false,
                        allowPublicDownloadUndoHint: Bool = false,
                        allowPublicZIPExtractionUndoHint: Bool = false,
                        allowPublicTARExtractionUndoHint: Bool = false,
                        allowReceivedFolderUndoHint: Bool = false,
                        allowZIPTreeUndoHint: Bool = false,
                        allowTARTreeUndoHint: Bool = false) throws -> OperationRecoveryInspection {
        guard directory.isFileURL, directory == directory.standardizedFileURL, (1...128).contains(limit),
              (1...16_384).contains(maximumEntries) else {
            throw FileOperationFailure.invalidRequest
        }
        let budget = suppliedBudget ?? OperationHistoryReadBudget(cancellation: cancellation)
        func result(_ readiness: OperationHistoryReadiness, refused: [URL] = [], legacy: Bool = false) -> OperationRecoveryInspection {
            OperationRecoveryInspection(records: [], refusedEntries: refused, nextCursor: nil, unfinishedCount: 0,
                readiness: readiness, legacyArchivesPresent: legacy,
                unfinishedCountIsComplete: readiness == .absent)
        }
        try cancellation.check()
        let anchor: DirectoryAnchor
        do { anchor = try DirectoryAnchor(directory, resolve: false) }
        catch FileOperationFailure.notFound { return result(.absent) }
        catch { try cancellation.check(); return result(.unavailable, refused: [directory]) }
        let ownerName = ".mac-explorer-journal-v1"
        let database = SQLiteJournalStore.name
        let fixed: Set<String> = [ownerName, ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2", database, database + "-journal"]
        var lease: Int32 = -1
        defer { if lease >= 0 { close(lease) } }
        var original: [String: EntrySnapshot]?
        func snapshot() throws -> [String: EntrySnapshot] {
            try budget.check(); try anchor.validate()
            var st = stat()
            guard fstat(anchor.fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else {
                throw FileOperationFailure.accessDenied
            }
            let names: [String]
            do { names = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: maximumEntries) }
            catch FileOperationFailure.unsupported { throw HistoryInspectionRefusal.entryLimit }
            var rows: [String: EntrySnapshot] = [:]
            for name in names { try budget.check(); rows[name] = try EntrySnapshot(parent: anchor.fd, name: name) }
            return rows
        }
        func unchanged() throws {
            try budget.check(); try anchor.validate()
            guard let original, try snapshot() == original else { throw FileOperationFailure.sourceChanged }
            if lease >= 0 {
                guard try EntrySnapshot(fd: lease) == original[ownerName],
                      flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw FileOperationFailure.sourceChanged }
            }
        }
        do {
            original = try snapshot()
            guard let entries = original else { throw FileOperationFailure.recoveryUncertain }
            let extras = entries.keys.filter { !fixed.contains($0) }
            let legacy = extras.contains { legacyName($0) }
            let refused = extras.filter { !legacyName($0) }.sorted().prefix(128).map { directory.appendingPathComponent($0) }
            guard refused.isEmpty else { return result(.unavailable, refused: refused, legacy: legacy) }
            for (name, entry) in entries {
                guard entry.type == S_IFREG, entry.mode & 0o077 == 0 else {
                    return result(.unavailable, refused: [directory.appendingPathComponent(name)], legacy: legacy)
                }
                let fd = openat(anchor.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw posixFailure() }
                defer { close(fd) }
                var st = stat()
                guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_nlink == 1,
                      try EntrySnapshot(fd: fd) == entry else { throw FileOperationFailure.sourceChanged }
            }
            guard let ownerEntry = entries[ownerName], ownerEntry.size <= 128 else {
                return result(entries.isEmpty ? .initializationIncomplete : .unavailable, refused: entries.isEmpty ? [] : [directory])
            }
            lease = openat(anchor.fd, ownerName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lease >= 0 else { throw posixFailure() }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
                return result(.busy, legacy: legacy)
            }
            try unchanged()
            let ownerBytes = try OperationJournal.read(name: ownerName, anchor: anchor)
            guard let text = String(data: ownerBytes, encoding: .utf8), let owner = UUID(uuidString: text) else {
                return result(.unavailable, refused: [directory.appendingPathComponent(ownerName)], legacy: legacy)
            }
            guard entries[database] != nil else {
                try unchanged(); return result(legacy ? .legacyImportRequired : .initializationIncomplete, legacy: legacy)
            }
            for token in [".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2"] {
                guard let entry = entries[token], entry.size <= 128 else {
                    return result(.initializationIncomplete, legacy: legacy)
                }
                guard try OperationJournal.read(name: token, anchor: anchor) == Data(owner.uuidString.utf8) else {
                    return result(.unavailable, refused: [directory.appendingPathComponent(token)], legacy: legacy)
                }
            }
            if let journal = entries[database + "-journal"] {
                let fd = openat(anchor.fd, database + "-journal", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
                var bytes = [UInt8](repeating: 0, count: 8)
                let n = pread(fd, &bytes, bytes.count, 0)
                guard n >= 0, try EntrySnapshot(fd: fd) == journal else { throw FileOperationFailure.sourceChanged }
                if n == 8 && bytes == [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7] {
                    try unchanged(); return result(.recoveryRequired, legacy: legacy)
                }
                guard n == 0 || (n == 8 && bytes.allSatisfy { $0 == 0 }) else {
                    return result(.unavailable, refused: [directory.appendingPathComponent(database + "-journal")], legacy: legacy)
                }
            }
            try hooks.beforeStoreOpen?(); try unchanged()
            let store = try SQLiteJournalStore(readOnly: anchor, owner: owner, budget: budget)
            let page = try store.summaries(after: after, limit: limit, excluding: [],
                allowDownloadAdoptionUndoHint: allowDownloadAdoptionUndoHint,
                allowNativeOriginalUpdateUndoHint: allowNativeOriginalUpdateUndoHint,
                allowNativeTARUpdateUndoHint: allowNativeTARUpdateUndoHint,
                allowNativeTARGzipUpdateUndoHint: allowNativeTARGzipUpdateUndoHint,
                allowNativeTARBzip2UpdateUndoHint: allowNativeTARBzip2UpdateUndoHint,
                allowPublicDownloadUndoHint: allowPublicDownloadUndoHint,
                allowPublicZIPExtractionUndoHint: allowPublicZIPExtractionUndoHint,
                allowPublicTARExtractionUndoHint: allowPublicTARExtractionUndoHint,
                allowReceivedFolderUndoHint: allowReceivedFolderUndoHint,
                allowZIPTreeUndoHint: allowZIPTreeUndoHint,
                allowTARTreeUndoHint: allowTARTreeUndoHint)
            let unfinished = try store.unfinishedCount(cancellation: cancellation)
            try hooks.beforeFinalValidation?(); try unchanged(); try store.validateFiles()
            return OperationRecoveryInspection(records: page.records, refusedEntries: [], nextCursor: page.next,
                unfinishedCount: unfinished, readiness: .available(catalogVersion: store.inspectedCatalogVersion),
                legacyArchivesPresent: legacy)
        } catch {
            if error is CancellationError { throw error }
            try cancellation.check()
            if budget.exhausted || error is HistoryInspectionRefusal { return result(.inspectionLimited) }
            if let original, (try? snapshot()) != original { return result(.changed, refused: [directory]) }
            return result(.unavailable, refused: [directory])
        }
    }

    private static func legacyName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 48 && bytes[36] == 45 && name.hasSuffix(".json")
            && UUID(uuidString: String(name.prefix(36))) != nil
            && bytes[37..<43].allSatisfy { (48...57).contains($0) }
    }
}

/// A bounded QA projection of one already validated, committed public
/// production record. `requiresPublicQuarantine` is the journaled requirement,
/// not a fresh observation of an output after Undo. Callers separately inspect
/// the generated output through their selected folder access.
@_spi(Qualification) public struct GeneratedPublicCatalogObservation: Codable, Equatable, Sendable {
    public let recordID: UUID
    public let version: Int
    public let purpose: String
    public let state: String
    public let requiresPublicQuarantine: Bool
}

extension RecoverableFileOperations {
    /// Reads one exact ID through the existing validated, read-only catalog
    /// inspector. This neither enumerates history nor constructs a writer.
    @_spi(Qualification) public func inspectGeneratedPublicCatalog(recordID: UUID) async throws
        -> GeneratedPublicCatalogObservation {
        try await worker { cancellation in
            let catalog = try OperationHistoryInspector.record(self.directory, id: recordID,
                cancellation: cancellation)
            guard let record = catalog.legacy, record.id == recordID,
                  ["committed", "undone"].contains(record.state), record.steps.count == 1 else {
                throw FileOperationFailure.unsupported
            }
            let purpose: String
            let markRequired: Bool
            switch catalog {
            case .receivedPublicDownloadV14:
                purpose = "receivedFile"; markRequired = true
            case .publicZIPExtractionFileV15:
                guard let required = record.steps[0].publicZIPExtractionMarkRequired else {
                    throw FileOperationFailure.recoveryUncertain
                }
                purpose = "zipFile"; markRequired = required
            case .publicProducedTreeV16:
                guard let value = record.producedTreeV16 else { throw FileOperationFailure.recoveryUncertain }
                switch value {
                case .receivedFolder: purpose = "receivedFolder"
                case .zipExtraction: purpose = "zipTree"
                case .tarExtraction: purpose = "tarTree"
                }
                markRequired = value.requiresMarkOnEveryNode
            case .publicTARExtractionFileV17:
                guard let required = record.steps[0].publicTARExtractionMarkRequired else {
                    throw FileOperationFailure.recoveryUncertain
                }
                purpose = "tarFile"; markRequired = required
            default:
                throw FileOperationFailure.unsupported
            }
            return GeneratedPublicCatalogObservation(recordID: recordID, version: record.version,
                purpose: purpose, state: record.state, requiresPublicQuarantine: markRequired)
        }
    }
}
