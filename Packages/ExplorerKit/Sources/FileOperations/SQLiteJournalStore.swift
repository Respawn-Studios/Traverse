import CryptoKit
import Darwin
import Foundation
import SQLite3

/// One connection, owned by OperationJournal's serial invocation and OS writer lock.
/// SQLite transactions cover metadata only; filesystem intents remain explicit.
internal final class SQLiteJournalStore {
    static let name = "operations-v2.sqlite"
    static let maximumRowBytes = 65_536
    static let maximumStoreBytes: Int64 = 1_073_741_824
    private var db: OpaquePointer?
    private let anchor: DirectoryAnchor
    private let identity: EntrySnapshot
    var fileIdentity: EntrySnapshot { identity }
    private let owner: UUID
    private let hooks: JournalStorageHooks
    private final class EditCache {
        let session: JournalEditSession
        var rows: [[Data]]
        var rowBytes: Int
        var revision: Int
        init(session: JournalEditSession, rows: [[Data]]) {
            self.session = session; self.rows = rows; revision = session.revision
            rowBytes = rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        }
    }
    private var editCache: EditCache?
    private var cachedRows: [UUID: [[Data]]] = [:]
    private var cachedRecords: [UUID: JournalRecord] = [:]
    private var epochGraphCache10:[RevisionDigest:EpochGraph10] = [:]
    private var epochCacheDataVersion10:Int64?
    private var observingTextRecordStart = false
    private var catalogVersion = 3
    private var validatedDataVersion: Int64?
    private var selectionCached: SelectionGroupRecord?
    private var selectionCachedHead: Data?

    /// OS writer lock plus SQLite data_version binds this invocation cache.
    /// External commits invalidate it; every cold connection validates all rows.
    func validateWriteCatalog(cancellation: OperationCancellation) throws {
        try validateFiles()
        let before = try integer("PRAGMA data_version")
        if validatedDataVersion == before { return }
        if catalogVersion == 10 { try validateEpochEnvelope10() }
        else { try validateCatalog(cancellation: cancellation) }
        guard try integer("PRAGMA data_version") == before else { throw FileOperationFailure.sourceChanged }
        validatedDataVersion = before; selectionCached = nil; selectionCachedHead = nil
    }

    internal var inspectedCatalogVersion: Int { catalogVersion }
    private var isReadOnlyInspection = false
    private var inspectionBudget: OperationHistoryReadBudget?
    private final class GroupedEditCache {
        let session: GroupedCopyEditSession
        var groups: [Data]
        var members: [Data]
        var bytes: Int
        var revision: Int
        init(session: GroupedCopyEditSession, groups: [Data], members: [Data]) {
            self.session = session; self.groups = groups; self.members = members
            bytes = (groups + members).reduce(0) { $0 + $1.count }; revision = session.revision
        }
    }
    private var groupedEditCache: GroupedEditCache?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private static let schema: [String] = [
        "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE jobs (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, created_at REAL NOT NULL, state TEXT NOT NULL, head BLOB NOT NULL, checksum TEXT NOT NULL, bytes INTEGER NOT NULL)",
        "CREATE INDEX jobs_order ON jobs(created_at DESC, id DESC)",
        "CREATE TABLE steps (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE areas (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE locations (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE trash_intents (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE events (job TEXT NOT NULL REFERENCES jobs(id), revision INTEGER NOT NULL, state TEXT NOT NULL, PRIMARY KEY(job, revision))",
        "CREATE TABLE legacy_imports (job TEXT PRIMARY KEY REFERENCES jobs(id), revision INTEGER NOT NULL, digest TEXT NOT NULL, last_name TEXT NOT NULL)"
    ]
    private static let tables = ["steps", "areas", "locations", "trash_intents"]
    private static let groupedSchema: [String] = [
        "CREATE TABLE job_protocols (job TEXT PRIMARY KEY REFERENCES jobs(id), kind TEXT NOT NULL, version INTEGER NOT NULL)",
        "CREATE TABLE grouped_groups (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, phase TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE grouped_members (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, group_ordinal INTEGER, phase TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE grouped_revision_heads (job TEXT NOT NULL REFERENCES jobs(id), revision INTEGER NOT NULL, head_checksum TEXT NOT NULL, PRIMARY KEY(job, revision))"
    ]

    struct Head: Codable {
        let version: Int
        let revision: Int
        let owner: UUID
        let id: UUID
        let operation: String
        let createdAt: Date
        let state: String
        let failureStage: String?
        let counts: [Int]
        let allTrashKnown: Bool
        let nameRename: JournalNameRename?
        let downloadAdoption: JournalDownloadAdoption?
        let persistentVolumes: PersistentVolumeBindings?
        let ownedTrash: JournalOwnedTrashHead?
        let producedTreeV16: PublicProducedTreePurposeV16?
        init(_ record: JournalRecord, allTrashKnown known: Bool? = nil) {
            version = record.version; revision = record.revision; owner = record.owner; id = record.id; operation = record.operation
            createdAt = record.createdAt; state = record.state; failureStage = record.failureStage
            nameRename = record.nameRename
            downloadAdoption = record.downloadAdoption
            persistentVolumes = record.persistentVolumes
            ownedTrash = record.ownedTrash
            producedTreeV16 = record.producedTreeV16
            counts = [record.steps.count, record.areas.count, record.locations.count, record.trashIntents.count]
            if let known { allTrashKnown = known }
            else {
                let knownSources = Set(record.steps.filter { $0.after != nil }.map(\.source))
                allTrashKnown = record.trashIntents.allSatisfy { knownSources.contains($0.source) }
            }
        }
    }

    init(anchor: DirectoryAnchor, owner: UUID, hooks: JournalStorageHooks, cancellation: OperationCancellation,
         expectedIdentity: EntrySnapshot? = nil, requiresGroupedCatalog: Bool = false, requiresSelectionCatalog: Bool = false) throws {
        self.anchor = anchor; self.owner = owner; self.hooks = hooks
        try anchor.validate()
        if requiresGroupedCatalog || requiresSelectionCatalog {
            guard let expectedIdentity else { throw FileOperationFailure.invalidRequest }
            let inspection = try SQLiteJournalStore(readOnly: anchor, owner: owner,
                budget: OperationHistoryReadBudget(cancellation: cancellation))
            guard (requiresSelectionCatalog ? [7, 9, 10] : [4, 7, 9, 10]).contains(inspection.inspectedCatalogVersion),
                  inspection.fileIdentity.sameObject(as: expectedIdentity) else { throw FileOperationFailure.recoveryUncertain }
            // A bounded history page and terminal-state count validate heads,
            // not every older payload. Validate all rows on this fresh session
            // before a writable connection can make any catalog change.
            try inspection.validateCatalog(cancellation: cancellation)
            try inspection.validateFiles(); try anchor.validate()
        }
        var attributes = statfs()
        guard fstatfs(anchor.fd, &attributes) == 0 else { throw posixFailure() }
        guard attributes.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileOperationFailure.unsupported
        }
        // The private creation token makes an interrupted empty-database initialization
        // distinguishable from an unrelated existing file. No pre-existing file is adopted.
        let token = ".mac-explorer-sqlite-v2"
        let existing = try Self.optionalSnapshot(Self.name, anchor: anchor)
        let tokenExists = try Self.optionalSnapshot(token, anchor: anchor) != nil
        if let expectedIdentity {
            guard let existing, existing.sameObject(as: expectedIdentity), tokenExists,
                  try Self.optionalSnapshot(".mac-explorer-sqlite-ready-v2", anchor: anchor) != nil else { throw FileOperationFailure.recoveryUncertain }
        }
        if !tokenExists {
            guard existing == nil else { throw FileOperationFailure.recoveryUncertain }
            try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: token, anchor: anchor)
        }
        guard try OperationJournal.read(name: token, anchor: anchor) == Data(owner.uuidString.utf8) else {
            throw FileOperationFailure.recoveryUncertain
        }
        if existing == nil {
            guard try Self.optionalSnapshot(".mac-explorer-sqlite-ready-v2", anchor: anchor) == nil else { throw FileOperationFailure.recoveryUncertain }
            let fd = openat(anchor.fd, Self.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixFailure() }
            close(fd); try syncDirectory(anchor)
        }
        identity = try Self.checkedFile(Self.name, anchor: anchor)
        if let expectedIdentity, !identity.sameObject(as: expectedIdentity) { throw FileOperationFailure.recoveryUncertain }
        try Self.checkSidecars(anchor)
        let path = anchor.url.appendingPathComponent(Self.name).path
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; throw Self.failure(result) }
        do {
            try validateFiles()
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(Self.maximumRowBytes))
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 100_000)
            try exec("PRAGMA trusted_schema=OFF")
            try exec("PRAGMA foreign_keys=ON")
            try exec("PRAGMA synchronous=EXTRA")
            try exec("PRAGMA fullfsync=ON")
            guard try integer("PRAGMA synchronous") == 3, try integer("PRAGMA fullfsync") == 1 else {
                throw FileOperationFailure.unsupported
            }
            try exec("PRAGMA temp_store=MEMORY")
            try exec("PRAGMA cache_size=-2048")
            let present = try texts("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name LIMIT 65")
            if present.isEmpty {
                guard try Self.optionalSnapshot(".mac-explorer-sqlite-ready-v2", anchor: anchor) == nil else {
                    throw FileOperationFailure.recoveryUncertain
                }
                try exec("PRAGMA auto_vacuum=INCREMENTAL")
                try transaction {
                    for sql in Self.schema { try exec(sql) }
                    try run("INSERT INTO metadata VALUES ('owner', ?)", [.text(owner.uuidString)])
                    try run("INSERT INTO metadata VALUES ('version', '3')")
                    try exec("PRAGMA user_version=3")
                }
            } else {
                guard try texts("SELECT value FROM metadata WHERE key='owner'") == [owner.uuidString] else { throw FileOperationFailure.recoveryUncertain }
                let metadataVersion = try texts("SELECT value FROM metadata WHERE key='version'")
                let version = try integer("PRAGMA user_version")
                guard (metadataVersion == ["2"] && version == 2) || (metadataVersion == ["3"] && version == 3) ||
                      (metadataVersion == ["4"] && version == 4) || (metadataVersion == ["7"] && version == 7) || (metadataVersion == ["9"] && version == 9) || (metadataVersion == ["10"] && version == 10) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                let expected = Self.catalogBaseSchema10(version) + ([4, 7, 9, 10].contains(version) ? Self.groupedSchema : []) + ([7, 9, 10].contains(version) ? Self.selectionSchema : []) + ([9,10].contains(version) ? Self.textSchemaV2 : []) + (version == 10 ? Self.epochSchema10 : [])
                guard Set(present) == Set(expected), present.count == expected.count else { throw FileOperationFailure.recoveryUncertain }
                catalogVersion = Int(version)
                if version == 2 {
                    // Keep the same catalog path and creation tokens. Older builds
                    // reject these versions instead of ignoring a parallel new store.
                    guard try texts("PRAGMA quick_check") == ["ok"] else { throw FileOperationFailure.recoveryUncertain }
                    try transaction {
                        try validateLegacyCatalogForUpgrade(cancellation: cancellation)
                        try run("UPDATE metadata SET value='3' WHERE key='version'")
                        try exec("PRAGMA user_version=3")
                        try hooks.beforeCatalogUpgradeCommit?()
                    }
                    try hooks.afterCatalogUpgradeCommit?()
                    catalogVersion = 3
                }
            }
            if catalogVersion != 10 { guard try texts("PRAGMA quick_check") == ["ok"] else {throw FileOperationFailure.recoveryUncertain} }
            guard try texts("PRAGMA journal_mode=DELETE") == ["delete"] else { throw FileOperationFailure.unsupported }
            let pageSize = try integer("PRAGMA page_size")
            let maximumPages = Self.maximumStoreBytes / pageSize
            let pageLimit = hooks.maximumPageCount ?? maximumPages
            guard pageLimit > 0, pageLimit <= maximumPages else { throw FileOperationFailure.invalidRequest }
            try exec("PRAGMA max_page_count=\(pageLimit)")
            if hooks.maximumPageCount != nil {
                guard try integer("PRAGMA max_page_count") == pageLimit else { throw FileOperationFailure.invalidRequest }
            }
            if try Self.optionalSnapshot(".mac-explorer-sqlite-ready-v2", anchor: anchor) == nil {
                try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: ".mac-explorer-sqlite-ready-v2", anchor: anchor)
            }
            guard try OperationJournal.read(name: ".mac-explorer-sqlite-ready-v2", anchor: anchor) == Data(owner.uuidString.utf8) else {
                throw FileOperationFailure.recoveryUncertain
            }
            try validateFiles()
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    /// Separate construction path: no creation tokens, migration, recovery,
    /// journal-mode assignment or durability settings are written here.
    init(readOnly anchor: DirectoryAnchor, owner: UUID, budget: OperationHistoryReadBudget,metrics:JournalMetrics? = nil) throws {
        self.anchor = anchor; self.owner = owner;var observations = JournalStorageHooks();observations.metrics=metrics;hooks=observations
        identity = try Self.checkedFile(Self.name, anchor: anchor)
        isReadOnlyInspection = true; inspectionBudget = budget
        try budget.check(); try anchor.validate(); try Self.checkSidecars(anchor)
        var volume = statfs()
        guard fstatfs(anchor.fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileOperationFailure.unsupported
        }
        let fd = openat(anchor.fd, Self.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 100)
        let count = pread(fd, &header, header.count, 0)
        // Reject WAL mode before SQLite can consider creating WAL/SHM files.
        guard count == 100, Array(header.prefix(16)) == Array("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1,
              try EntrySnapshot(fd: fd) == identity,
              try Self.checkedFile(Self.name, anchor: anchor) == identity else {
            throw FileOperationFailure.recoveryUncertain
        }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        let status = sqlite3_open_v2(anchor.url.appendingPathComponent(Self.name).path, &db, flags, nil)
        guard status == SQLITE_OK, sqlite3_db_readonly(db, "main") == 1 else {
            if let db { sqlite3_close(db) }; db = nil; throw Self.failure(status)
        }
        do {
            sqlite3_progress_handler(db, 1_000, { context in
                guard let context else { return 1 }
                return Unmanaged<OperationHistoryReadBudget>.fromOpaque(context).takeUnretainedValue().advance() ? 0 : 1
            }, Unmanaged.passUnretained(budget).toOpaque())
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(Self.maximumRowBytes))
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 100_000)
            try exec("PRAGMA trusted_schema=OFF")
            try exec("PRAGMA query_only=ON")
            try exec("PRAGMA temp_store=MEMORY")
            try exec("PRAGMA cache_size=-2048")
            guard try integer("PRAGMA query_only") == 1,
                  try texts("PRAGMA journal_mode") == ["delete"],
                  try texts("SELECT value FROM metadata WHERE key='owner'") == [owner.uuidString] else {
                throw FileOperationFailure.recoveryUncertain
            }
            let version = try integer("PRAGMA user_version")
            guard [2, 3, 4, 7, 9, 10].contains(version),
                  try texts("SELECT value FROM metadata WHERE key='version'") == [String(version)] else {
                throw FileOperationFailure.recoveryUncertain
            }
            let present = try texts("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name LIMIT 65")
            let expected = Self.catalogBaseSchema10(version) + ([4, 7, 9, 10].contains(version) ? Self.groupedSchema : []) + ([7, 9, 10].contains(version) ? Self.selectionSchema : []) + ([9,10].contains(version) ? Self.textSchemaV2 : []) + (version == 10 ? Self.epochSchema10 : [])
            guard present.count == expected.count, Set(present) == Set(expected),
                  try integer("SELECT count(*) FROM jobs") <= 10_000 else { throw FileOperationFailure.recoveryUncertain }
            catalogVersion = Int(version)
            try validateFiles(); if [7, 9].contains(catalogVersion) { try validateCatalog(cancellation: OperationCancellation()) }; if catalogVersion == 10 { try validateEpochEnvelope10() }; try budget.check()
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { groupedEditCache?.session.invalidate(); if let db { sqlite3_close(db) } }

    /// Validate authoritative legacy payloads before the first upgrade write.
    /// Keyset pages bound the ID list; the existing loader bounds one record and
    /// checks checksums, counts, byte accounting, latest events and semantics.
    /// No history payload or cache is rewritten or retained across iterations.
    private func validateLegacyCatalogForUpgrade(cancellation: OperationCancellation) throws {
        try cancellation.check()
        let foreignKeys = try prepare("PRAGMA foreign_key_check", [])
        defer { sqlite3_finalize(foreignKeys) }
        // Same 10,000-job ceiling already enforced by save/saveSnapshot.
        guard sqlite3_step(foreignKeys) == SQLITE_DONE,
              try integer("SELECT count(*) FROM jobs") <= 10_000 else { throw FileOperationFailure.recoveryUncertain }
        var previous: String?
        while true {
            let ids = try previous.map { try texts("SELECT id FROM jobs WHERE id > ? ORDER BY id LIMIT 64", [.text($0)]) }
                ?? texts("SELECT id FROM jobs ORDER BY id LIMIT 64")
            guard !ids.isEmpty else { break }
            for id in ids {
                try cancellation.check()
                let record = try loadedRecord(id).record
                guard record.version == 1, record.nameRename == nil else { throw FileOperationFailure.recoveryUncertain }
            }
            previous = ids.last
        }
        try cancellation.check()
    }

    func validateFiles() throws {
        try inspectionBudget?.check()
        try anchor.validate()
        let current = try Self.checkedFile(Self.name, anchor: anchor)
        guard isReadOnlyInspection ? current == identity : current.sameObject(as: identity) else { throw FileOperationFailure.recoveryUncertain }
        try Self.checkSidecars(anchor)
    }

    private static func optionalSnapshot(_ name: String, anchor: DirectoryAnchor) throws -> EntrySnapshot? {
        do { return try EntrySnapshot(parent: anchor.fd, name: name) }
        catch FileOperationFailure.notFound { return nil }
    }
    private static func checkedFile(_ name: String, anchor: DirectoryAnchor) throws -> EntrySnapshot {
        let fd = openat(anchor.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? FileOperationFailure.recoveryUncertain : posixFailure() }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixFailure() }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              value.st_size >= 0, value.st_size <= maximumStoreBytes else { throw FileOperationFailure.recoveryUncertain }
        let result = try EntrySnapshot(fd: fd)
        guard try EntrySnapshot(parent: anchor.fd, name: name).sameObject(as: result) else { throw FileOperationFailure.recoveryUncertain }
        return result
    }
    private static func checkSidecars(_ anchor: DirectoryAnchor) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            guard try optionalSnapshot(name + suffix, anchor: anchor) != nil else { continue }
            _ = try checkedFile(name + suffix, anchor: anchor)
            // This store has always used rollback journals. WAL/SHM are foreign here.
            guard suffix == "-journal" else { throw FileOperationFailure.recoveryUncertain }
            let fd = openat(anchor.fd, name + suffix, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ELOOP ? FileOperationFailure.recoveryUncertain : posixFailure() }
            defer { close(fd) }
            var header = [UInt8](repeating: 0, count: 8)
            let size = read(fd, &header, header.count)
            guard size >= 0 else { throw posixFailure() }
            // SQLite's inactive/incomplete journal starts with zero bytes; a hot
            // journal has its documented magic. Never let SQLite adopt arbitrary data.
            guard size == 0 || (size == 8 && (header.allSatisfy { $0 == 0 } || header == [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    func beginEdit(operation: String, nameRename: JournalNameRename? = nil, reservedID: UUID? = nil) throws -> JournalEditSession {
        try beginEdit(operation: operation, nameRename: nameRename, reservedID: reservedID,
                      version: nameRename == nil ? 3 : 4)
    }

    func beginArchiveUpdateEdit(protocolKind: OperationCatalogProtocol) throws -> JournalEditSession {
        guard [.archiveUpdateV5, .archiveStrictCloneV6, .archiveNativeUpdateV13, .tarNativeUpdateV18, .tarGzipNativeUpdateV19, .tarBzip2NativeUpdateV20].contains(protocolKind),
              let title = ArchiveUpdateProfile.title(version: protocolKind.version) else {
            throw FileOperationFailure.recoveryUncertain
        }
        return try beginEdit(operation: title, nameRename: nil, reservedID: nil,
                             version: protocolKind.version)
    }

    func beginDownloadAdoptionEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Download", nameRename: nil, reservedID: nil, version: 7)
    }

    func beginReceivedPublicDownloadEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Download", nameRename: nil, reservedID: nil, version: 14)
    }

    func beginPublicZIPExtractionEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Extract ZIP", nameRename: nil, reservedID: nil, version: 15)
    }

    func beginPublicTARExtractionEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Extract TAR", nameRename: nil, reservedID: nil, version: 17)
    }

    func beginProducedTreeV16Edit(purpose: PublicProducedTreePurposeV16) throws -> JournalEditSession {
        try beginEdit(operation: purpose.historyTitle, nameRename: nil, reservedID: nil,
                      version: 16, producedTreeV16: purpose)
    }

    func beginAdditiveRootTrashEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Move to Trash", nameRename: nil, reservedID: nil, version: 9)
    }

    func beginNativeTrashEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Move to Trash", nameRename: nil, reservedID: nil, version: 11)
    }

    func beginNativeDirectoryTrashEdit() throws -> JournalEditSession {
        try beginEdit(operation: "Move to Trash", nameRename: nil, reservedID: nil, version: 12)
    }

    private func beginEdit(operation: String, nameRename: JournalNameRename?, reservedID: UUID?,
                           version: Int, producedTreeV16: PublicProducedTreePurposeV16? = nil) throws -> JournalEditSession {
        try validateFiles()
        groupedEditCache?.session.invalidate(); groupedEditCache = nil
        let id = reservedID ?? UUID()
        if reservedID != nil, try catalogRecord(id) != nil { throw FileOperationFailure.recoveryUncertain }
        var record = JournalRecord(version: version, owner: owner, id: id, operation: operation)
        record.nameRename = nameRename
        record.producedTreeV16 = producedTreeV16
        record.persistentVolumes = PersistentVolumeBindings()
        let session = JournalEditSession(record, new: true)
        editCache = EditCache(session: session, rows: [[], [], [], []])
        cachedRows = [:]; cachedRecords = [:]
        return session
    }

    func openEdit(_ id: UUID) throws -> JournalEditSession? {
        try validateFiles()
        guard !(try integers("SELECT revision FROM jobs WHERE id=?", [.text(id.uuidString)])).isEmpty else { return nil }
        let loaded = try loadedRecord(id.uuidString)
        groupedEditCache?.session.invalidate(); groupedEditCache = nil
        let session = JournalEditSession(loaded.record, new: false)
        editCache = EditCache(session: session, rows: loaded.rows)
        cachedRows = [:]; cachedRecords = [:]
        return session
    }

    func save(_ session: JournalEditSession) throws {
        let measurementStart = hooks.metrics?.start()
        defer { if let measurementStart { hooks.metrics?.finish(.save, since: measurementStart) } }
        guard let cache = editCache, cache.session === session, cache.revision == session.revision else {
            throw FileOperationFailure.recoveryUncertain
        }
        let record = session.snapshot
        try measureJournal(hooks.metrics, .validation) {
            try validateFiles(); try OperationJournal.validateHeader(record)
            if [5, 6, 13, 18, 19, 20].contains(record.version) { try OperationJournal.validateArchiveUpdate(record) }
            if record.version == 7 { try OperationJournal.validateDownloadAdoption(record) }
            if record.version == 14 { try OperationJournal.validateReceivedPublicDownload(record) }
            if record.version == 15 { try OperationJournal.validatePublicZIPExtraction(record) }
            if record.version == 16 { try OperationJournal.validateProducedTreeV16(record) }
            if record.version == 17 { try OperationJournal.validatePublicTARExtraction(record) }
            try OperationJournal.validateTrashRootAddition(record)
            if [9, 11, 12].contains(record.version) && record.state == "committed" { try OwnedTrashPolicy.committed(record) }
            if [8, 10].contains(record.version) { try OwnedTrashPolicy.validate(record) }
        }
        let id = record.id.uuidString
        let revisions = try integers("SELECT revision FROM jobs WHERE id=?", [.text(id)])
        guard revisions.isEmpty ? record.revision == 0 : revisions == [Int64(record.revision - 1)] else {
            throw FileOperationFailure.recoveryUncertain
        }
        if revisions.isEmpty { guard try integer("SELECT count(*) FROM jobs") < 10_000 else { throw FileOperationFailure.unsupported } }
        let counts = [record.steps.count, record.areas.count, record.locations.count, record.trashIntents.count]
        guard zip(counts, cache.rows).allSatisfy({ $0.0 >= $0.1.count }) else { throw FileOperationFailure.recoveryUncertain }
        var updates: [(table: Int, ordinal: Int, data: Data)] = []
        var rowBytes = cache.rowBytes
        try measureJournal(hooks.metrics, .compareEncode) {
            for table in Self.tables.indices {
                for ordinal in session.changed[table].sorted() {
                    guard ordinal >= 0, ordinal < counts[table] else { throw FileOperationFailure.recoveryUncertain }
                    hooks.metrics?.add(.comparedRows, 1)
                    try measureJournal(hooks.metrics, .validation) {
                        hooks.metrics?.add(.validatedRows, 1)
                        switch table {
                        case 0: try OperationJournal.validateStep(record.steps[ordinal])
                        case 1: try OperationJournal.validateArea(record.areas[ordinal], stepCount: record.steps.count)
                        case 2: try OperationJournal.validateLocation(record.locations[ordinal])
                        default: try OperationJournal.validateTrashIntent(record.trashIntents[ordinal])
                        }
                    }
                    let data: Data
                    switch table {
                    case 0: data = try encode(record.steps[ordinal])
                    case 1: data = try encode(record.areas[ordinal])
                    case 2: data = try encode(record.locations[ordinal])
                    default: data = try encode(record.trashIntents[ordinal])
                    }
                    let old = ordinal < cache.rows[table].count ? cache.rows[table][ordinal] : nil
                    if data != old {
                        let (next, overflow) = rowBytes.addingReportingOverflow(data.count - (old?.count ?? 0))
                        guard !overflow else { throw FileOperationFailure.unsupported }
                        rowBytes = next; updates.append((table, ordinal, data))
                    }
                }
            }
        }
        let head = try encode(Head(record, allTrashKnown: session.allTrashKnown))
        let (size, overflow) = rowBytes.addingReportingOverflow(head.count)
        guard !overflow, size <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
        var committed = false
        do {
            try transaction {
                let rowMeasurementStart = hooks.metrics?.start()
                defer { if let rowMeasurementStart { hooks.metrics?.finish(.rowScanSQL, since: rowMeasurementStart) } }
                hooks.metrics?.add(.rowScanCandidates, updates.count)
                try run("INSERT INTO jobs (id,revision,created_at,state,head,checksum,bytes) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,created_at=excluded.created_at,state=excluded.state,head=excluded.head,checksum=excluded.checksum,bytes=excluded.bytes",
                        [.text(id), .int(Int64(record.revision)), .double(record.createdAt.timeIntervalSinceReferenceDate), .text(record.state), .blob(head), .text(Self.digest(head)), .int(Int64(size))])
                for update in updates {
                    hooks.metrics?.add(.writtenRows, 1)
                    try run("INSERT INTO \(Self.tables[update.table]) VALUES (?, ?, ?, ?) ON CONFLICT(job,ordinal) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum",
                            [.text(id), .int(Int64(update.ordinal)), .blob(update.data), .text(Self.digest(update.data))])
                }
                try writeLegacyProtocol(record, promotingOwnedTrash: session.ownedTrashPromotionPending)
                try run("INSERT INTO events VALUES (?, ?, ?)", [.text(id), .int(Int64(record.revision)), .text(record.state)])
                try hooks.beforeSaveCommit?()
            }
            committed = true
            try hooks.afterSaveCommit?()
            try validateFiles()
        } catch {
            // A returned COMMIT followed by a failed file guard is not a rollback.
            // Retry only if the checked durable revision still equals our old base.
            if committed || sqlite3_get_autocommit(db) == 0 || (try? integers("SELECT revision FROM jobs WHERE id=?", [.text(id)])) != revisions {
                editCache = nil
            }
            throw error
        }
        for update in updates {
            if update.ordinal == cache.rows[update.table].count { cache.rows[update.table].append(update.data) }
            else { cache.rows[update.table][update.ordinal] = update.data }
        }
        cache.rowBytes = rowBytes
        session.didCommit(); cache.revision = session.revision
    }

    func saveSnapshot(_ record: JournalRecord, imported: Bool = false, migration: (String, String)? = nil) throws {
        editCache = nil
        groupedEditCache?.session.invalidate(); groupedEditCache = nil
        let measurementStart = hooks.metrics?.start()
        defer { if let measurementStart { hooks.metrics?.finish(.save, since: measurementStart) } }
        try measureJournal(hooks.metrics, .validation) {
            try validateFiles()
            try OperationJournal.validateHeader(record)
            if [5, 6, 13, 18, 19, 20].contains(record.version) { try OperationJournal.validateArchiveUpdate(record) }
            if record.version == 7 { try OperationJournal.validateDownloadAdoption(record) }
            if record.version == 14 { try OperationJournal.validateReceivedPublicDownload(record) }
            if record.version == 15 { try OperationJournal.validatePublicZIPExtraction(record) }
            if record.version == 16 { try OperationJournal.validateProducedTreeV16(record) }
            if record.version == 17 { try OperationJournal.validatePublicTARExtraction(record) }
            try OperationJournal.validateTrashRootAddition(record)
            if [9, 11, 12].contains(record.version) && record.state == "committed" { try OwnedTrashPolicy.committed(record) }
            if [8, 10].contains(record.version) { try OwnedTrashPolicy.validate(record) }
        }
        let id = record.id.uuidString
        let revisions = try integers("SELECT revision FROM jobs WHERE id=?", [.text(id)])
        guard revisions.isEmpty ? (record.revision == 0 || imported) : revisions == [Int64(record.revision - 1)] else {
            throw FileOperationFailure.recoveryUncertain
        }
        if revisions.isEmpty { guard try integer("SELECT count(*) FROM jobs") < 10_000 else { throw FileOperationFailure.unsupported } }
        let previous: [[Data]]
        let prior: JournalRecord?
        if let cached = cachedRows[record.id] { previous = cached; prior = cachedRecords[record.id] }
        else if !revisions.isEmpty {
            previous = try Self.tables.map { try payloads(table: $0, id: id, limit: 16_384) }
            prior = try self.record(id)
        } else { previous = [[], [], [], []]; prior = nil }
        func updating<T: Encodable>(_ values: [T], _ old: [T], _ encoded: [Data],
                                    unchanged: (T, T) -> Bool, validate: (T) throws -> Void) throws -> [Data] {
            guard values.count >= old.count, old.count == encoded.count else { throw FileOperationFailure.recoveryUncertain }
            var updated = encoded
            hooks.metrics?.add(.comparedRows, values.count)
            for index in values.indices {
                if index < old.count, unchanged(values[index], old[index]) { continue }
                try measureJournal(hooks.metrics, .validation) {
                    hooks.metrics?.add(.validatedRows, 1)
                    try validate(values[index])
                }
                let data = try encode(values[index])
                if index >= old.count { updated.append(data) } else { updated[index] = data }
            }
            return updated
        }
        // Every cached row came from a successful save or a fully checked disk read.
        // Counts cannot shrink, so an unchanged staging proof's step bound stays valid.
        let rows = try measureJournal(hooks.metrics, .compareEncode) {
            try [updating(record.steps, prior?.steps ?? [], previous[0], unchanged: {
                    $0 == $1 && OperationJournal.sameURLRepresentation($0.source, $1.source) &&
                    OperationJournal.sameURLRepresentation($0.destination, $1.destination)
                 }, validate: OperationJournal.validateStep),
                 updating(record.areas, prior?.areas ?? [], previous[1], unchanged: {
                    $0 == $1 && OperationJournal.sameURLRepresentation($0.url, $1.url)
                 }, validate: { try OperationJournal.validateArea($0, stepCount: record.steps.count) }),
                 updating(record.locations, prior?.locations ?? [], previous[2],
                          unchanged: OperationJournal.sameURLRepresentation, validate: OperationJournal.validateLocation),
                 updating(record.trashIntents, prior?.trashIntents ?? [], previous[3], unchanged: {
                    $0 == $1 && OperationJournal.sameURLRepresentation($0.source, $1.source)
                 }, validate: OperationJournal.validateTrashIntent)]
        }
        let head = try encode(Head(record))
        let size = measureJournal(hooks.metrics, .sizeScan) {
            rows.reduce(head.count) { $0 + $1.reduce(0) { $0 + $1.count } }
        }
        guard size <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
        // Only appended or changed outcome/Undo rows are encoded and written.
        try transaction {
            let rowMeasurementStart = hooks.metrics?.start()
            defer { if let rowMeasurementStart { hooks.metrics?.finish(.rowScanSQL, since: rowMeasurementStart) } }
            hooks.metrics?.add(.rowScanCandidates, rows.reduce(0) { $0 + $1.count })
            try run("INSERT INTO jobs (id,revision,created_at,state,head,checksum,bytes) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,created_at=excluded.created_at,state=excluded.state,head=excluded.head,checksum=excluded.checksum,bytes=excluded.bytes",
                    [.text(id), .int(Int64(record.revision)), .double(record.createdAt.timeIntervalSinceReferenceDate), .text(record.state), .blob(head), .text(Self.digest(head)), .int(Int64(size))])
            for index in Self.tables.indices {
                for ordinal in rows[index].indices where ordinal >= previous[index].count || rows[index][ordinal] != previous[index][ordinal] {
                    let data = rows[index][ordinal]
                    hooks.metrics?.add(.writtenRows, 1)
                    try run("INSERT INTO \(Self.tables[index]) VALUES (?, ?, ?, ?) ON CONFLICT(job,ordinal) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum",
                            [.text(id), .int(Int64(ordinal)), .blob(data), .text(Self.digest(data))])
                }
            }
            try writeLegacyProtocol(record)
            try run("INSERT INTO events VALUES (?, ?, ?)", [.text(id), .int(Int64(record.revision)), .text(record.state)])
            if let migration {
                try run("INSERT INTO legacy_imports VALUES (?, ?, ?, ?)", [.text(id), .int(Int64(record.revision)), .text(migration.0), .text(migration.1)])
            }
            try hooks.beforeSaveCommit?()
        }
        // One active job cache: migration/history must never retain all job bodies.
        cachedRows = [record.id: rows]
        cachedRecords = [record.id: record]
        try validateFiles()
    }

    /// Compatibility full-record inspection is explicitly bounded to one page. Production
    /// history browsing uses summaries; mutation/recovery looks up exactly one record.
    func records(excluding: Set<UUID>) throws -> [JournalRecord] {
        let page = try summaries(after: nil, limit: 64, excluding: excluding)
        return try page.records.map { try record($0.id.uuidString) }
    }

    func recordIfPresent(_ id: UUID) throws -> JournalRecord? {
        try validateFiles()
        guard !(try integers("SELECT revision FROM jobs WHERE id=?", [.text(id.uuidString)])).isEmpty else { return nil }
        return try record(id.uuidString)
    }

    func unfinishedCount(cancellation: OperationCancellation = OperationCancellation()) throws -> Int {
        try validateFiles()
        try cancellation.check()
        if [4, 7, 9, 10].contains(catalogVersion) {
            var count = 0
            try eachJobID { id in
                try cancellation.check()
                if try catalogProtocol(id) == .textRevisionV3 {
                    if ![LocalTextRevisionState.committed, .undone, .notApplied].contains(try loadedTextRevisionV2(id).project().state) { count += 1 }
                } else if try catalogProtocol(id) == .selectionGroupV2 {
                    if try !loadSelectionGroup(id).project().isTerminal { count += 1 }
                } else if try catalogProtocol(id) == .groupedCopyV1 {
                    if try !readGroupedHead(id).head.state.isTerminal { count += 1 }
                } else if try !["committed", "undone", "cleaned", "trashDeleted"].contains(readHead(id).head.state) { count += 1 }
            }
            return count
        }
        return Int(try integer("SELECT count(*) FROM jobs WHERE state NOT IN ('committed','undone','cleaned','trashDeleted')"))
    }

    func summaries(after: UUID?, limit: Int, excluding: Set<UUID>,
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
        allowTARTreeUndoHint: Bool = false) throws -> (records: [OperationRecoveryRecord], next: UUID?) {
        try validateFiles()
        guard (1...128).contains(limit) else { throw FileOperationFailure.invalidRequest }
        let ids: [String]
        if let after {
            let date: Double
            if try catalogProtocol(after.uuidString) == .textRevisionV3 { date = try textRecordV2(after).manifest.createdAt.timeIntervalSinceReferenceDate }
            else if try catalogProtocol(after.uuidString) == .selectionGroupV2 { date = try loadSelectionGroup(after.uuidString).manifest.createdAt.timeIntervalSinceReferenceDate }
            else if try catalogProtocol(after.uuidString) == .groupedCopyV1 { date = try readGroupedHead(after.uuidString).head.createdAt.timeIntervalSinceReferenceDate }
            else { date = try readHead(after.uuidString).head.createdAt.timeIntervalSinceReferenceDate }
            ids = try texts("SELECT id FROM jobs WHERE created_at < ? OR (created_at = ? AND id < ?) ORDER BY created_at DESC,id DESC LIMIT ?",
                            [.double(date), .double(date), .text(after.uuidString), .int(Int64(limit + 1))])
        } else {
            ids = try texts("SELECT id FROM jobs ORDER BY created_at DESC,id DESC LIMIT ?", [.int(Int64(limit + 1))])
        }
        var result: [OperationRecoveryRecord] = []
        var scanned = 0
        var bytes = 0
        for id in ids.prefix(limit) {
            guard let uuid = UUID(uuidString: id) else { throw FileOperationFailure.recoveryUncertain }
            if excluding.contains(uuid) { scanned += 1; continue }
            if try catalogProtocol(id) == .textRevisionV3 {
                let record = try textRecordV2(uuid), projection = try record.project()
                let head = try? textHeadV2(slot: record.manifest.slot)
                result.append(OperationRecoveryRecord(id: record.id, operation: "Save Text", createdAt: record.manifest.createdAt,
                    state: projection.state.rawValue, locations: [record.manifest.target, record.manifest.area],
                    canUndo: try projection.canPrepareInverse && head?.job == record.id && textUndoDisposition10(record.id) == .available,
                    canRecover: false, kind: .textRevision))
                scanned += 1; continue
            }
            if try catalogProtocol(id) == .selectionGroupV2 {
                let record = try loadSelectionGroup(id), state = try record.project()
                result.append(OperationRecoveryRecord(id: record.manifest.id, operation: "New Folder with Selection",
                    createdAt: record.manifest.createdAt, state: state.pending == nil ? state.state.rawValue : "pendingReview",
                    locations: [record.manifest.parent, record.manifest.folder, record.manifest.area],
                    canUndo: false, canRecover: false, kind: .selectionGroup))
                scanned += 1; continue
            }
            if try catalogProtocol(id) == .groupedCopyV1 {
                let head = try readGroupedHead(id).head
                // This is only a bounded summary hint; Undo reclassifies the full
                // selected job. The legacy Restore action never applies to grouped Copy.
                let hasPublication = try integers("SELECT EXISTS(SELECT 1 FROM grouped_members WHERE job=? AND phase='published')", [.text(id)]).first == 1
                let canUndo = !head.undoInvalidated && [.completed, .stoppedSettled].contains(head.state) && hasPublication
                result.append(OperationRecoveryRecord(id: head.id, operation: "Copy (grouped preview)", createdAt: head.createdAt,
                    state: head.state.rawValue, locations: [], canUndo: canUndo, canRecover: false, kind: .groupedCopy))
                scanned += 1
                continue
            }
            let head = try readHead(id).head
            // A v9/v10 summary must not offer Undo or display a deletion barrier
            // from the head alone if its mandatory directory witness is missing.
            let nativeTrashRecord = [11, 12].contains(head.version) ? try loadedRecord(id).record : nil
            if [9, 10].contains(head.version) { _ = try loadedRecord(id).record }
            let encoded = try payloads(table: "locations", id: id, limit: head.counts[2])
            guard encoded.count == head.counts[2] else { throw FileOperationFailure.recoveryUncertain }
            let size = encoded.reduce(0) { $0 + $1.count }
            if scanned > 0, bytes + size > 16_777_216 { break }
            let locations = try encoded.map { try JSONDecoder().decode(URL.self, from: $0) }
            var validation = JournalRecord(version: head.version, owner: head.owner, id: head.id, operation: head.operation)
            validation.state = head.state; validation.locations = locations
            validation.nameRename = head.nameRename
            validation.downloadAdoption = head.downloadAdoption
            validation.persistentVolumes = head.persistentVolumes
            validation.ownedTrash = head.ownedTrash
            validation.producedTreeV16 = head.producedTreeV16
            try OperationJournal.validateHeader(validation)
            for location in validation.locations { try OperationJournal.validateLocation(location) }
            let operation = head.operation == "Rename" ? (head.nameRename == nil ? "Rename (unchanged contents required)" : "Rename (keeps edits)") : head.operation
            let hasAction = head.counts[0] > 0 || head.nameRename != nil
            let requiresManualTrashReview = head.operation == "Move to Trash" && head.counts[3] > 0 && !head.allTrashKnown
            // The durable rename intent precedes the actual namespace call.
            // Load/validate the complete zero-step record before offering this
            // historical hint; a summary count or disabled Restore is not proof.
            let zipReplacementNotStarted: Bool
            if [5, 6, 13, 18, 19, 20].contains(head.version), head.operation == ArchiveUpdateProfile.title(version: head.version), head.state == "needsReview",
               head.counts[0] == 0, head.counts[3] == 0 {
                let record = try loadedRecord(id).record
                zipReplacementNotStarted = record.steps.isEmpty && record.trashIntents.isEmpty
            } else { zipReplacementNotStarted = false }
            // An engine-qualified UI hint only. Load the one v7 journal record
            // to validate topology; no body or destination is opened here.
            let adoptionUndoHint: Bool
            if allowDownloadAdoptionUndoHint, head.version == 7, head.state == "committed",
               let adoption = try? loadedRecord(id).record {
                adoptionUndoHint = adoption.downloadAdoption?.adoptedStage != nil
                    && adoption.steps.count == 1 && adoption.steps[0].after != nil
                    && !adoption.steps[0].undone
            } else { adoptionUndoHint = false }
            let publicDownloadUndoHint: Bool
            if allowPublicDownloadUndoHint, head.version == 14, head.state == "committed",
               let record = try? loadedRecord(id).record {
                // Metadata-only presentation. The opted-in engine revalidates
                // the body, object and public mark when Undo is requested.
                publicDownloadUndoHint = record.steps.count == 1
                    && record.steps[0].after != nil && !record.steps[0].undone
            } else { publicDownloadUndoHint = false }
            let publicZIPExtractionUndoHint: Bool
            if allowPublicZIPExtractionUndoHint, head.version == 15, head.state == "committed",
               let record = try? loadedRecord(id).record {
                // A full v15 record load validates the one-file private-stage
                // topology and typed mark requirement. Undo reopens the object.
                publicZIPExtractionUndoHint = record.version == 15 && record.state == "committed"
                    && record.operation == "Extract ZIP"
                    && record.areas.count == 1 && record.steps.count == 1
                    && record.steps[0].before.osManagedSecurityV1 == true
                    && record.steps[0].publicZIPExtractionMarkRequired != nil
                    && record.steps[0].after?.osManagedSecurityV1 == true
                    && !record.steps[0].undone
            } else { publicZIPExtractionUndoHint = false }
            let publicTARExtractionUndoHint: Bool
            if allowPublicTARExtractionUndoHint, head.version == 17, head.state == "committed",
               let record = try? loadedRecord(id).record {
                publicTARExtractionUndoHint = record.version == 17 && record.state == "committed"
                    && record.operation == "Extract TAR"
                    && record.areas.count == 1 && record.steps.count == 1
                    && record.steps[0].before.osManagedSecurityV1 == true
                    && record.steps[0].publicTARExtractionMarkRequired != nil
                    && record.steps[0].after?.osManagedSecurityV1 == true
                    && !record.steps[0].undone
            } else { publicTARExtractionUndoHint = false }
            let publicTreeUndoHint: Bool
            if head.version == 16, head.state == "committed",
               let purpose = head.producedTreeV16,
               ({ () -> Bool in
                   switch purpose {
                   case .receivedFolder: allowReceivedFolderUndoHint
                   case .zipExtraction: allowZIPTreeUndoHint
                   case .tarExtraction: allowTARTreeUndoHint
                   }
               }()),
               let record = try? loadedRecord(id).record {
                publicTreeUndoHint = record.producedTreeV16 == purpose
                    && record.steps.count == 1 && record.areas.count == 1
                    && record.steps[0].before.identity.isDirectory
                    && record.steps[0].before.publicTreeQuarantineV16 != nil
                    && record.steps[0].after?.publicTreeQuarantineV16 != nil
                    && !record.steps[0].undone
            } else { publicTreeUndoHint = false }
            let nativeZIPRestoreHint: Bool
            if (head.version == 13 && allowNativeOriginalUpdateUndoHint) || (head.version == 18 && allowNativeTARUpdateUndoHint)
                || (head.version == 19 && allowNativeTARGzipUpdateUndoHint)
                || (head.version == 20 && allowNativeTARBzip2UpdateUndoHint),
               head.counts[0] == 1, head.counts[1] == 1,
               ["mutating", "needsReview"].contains(head.state) {
                nativeZIPRestoreHint = OperationJournal.hasRecordedNativeArchiveOriginalOnly(
                    try loadedRecord(id).record)
            } else { nativeZIPRestoreHint = false }
            result.append(OperationRecoveryRecord(id: head.id, operation: operation, createdAt: head.createdAt, state: head.state,
                locations: locations, canUndo: adoptionUndoHint || publicDownloadUndoHint || publicZIPExtractionUndoHint
                    || publicTARExtractionUndoHint || publicTreeUndoHint ||
                    ![7, 8, 10, 14, 15, 16, 17].contains(head.version) && head.state == "committed" && hasAction && head.allTrashKnown
                    && (head.version != 13 || allowNativeOriginalUpdateUndoHint)
                    && (head.version != 18 || allowNativeTARUpdateUndoHint)
                    && (head.version != 19 || allowNativeTARGzipUpdateUndoHint)
                    && (head.version != 20 || allowNativeTARBzip2UpdateUndoHint),
                canRecover: ![7, 8, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20].contains(head.version) && ["preparing", "mutating", "needsReview", "undoing"].contains(head.state) && hasAction && head.allTrashKnown,
                canRestoreOriginalZIP: nativeZIPRestoreHint,
                requiresManualTrashReview: requiresManualTrashReview,
                zipReplacementNotStarted: zipReplacementNotStarted,
                nativeTrashMarkChanged: nativeTrashRecord?.steps.contains(where: { $0.nativeTrashMarkChanged == true }) == true,
                nativeRegularFileTrashContract: head.operation == "Move to Trash" && head.version == 11 && nativeTrashRecord != nil,
                nativeDirectoryTrashContract: head.operation == "Move to Trash" && head.version == 12 && nativeTrashRecord != nil))
            scanned += 1; bytes += size
        }
        let more = scanned < ids.count
        return (result, more && scanned > 0 ? UUID(uuidString: ids[scanned - 1]) : nil)
    }

    private func readHead(_ id: String) throws -> (head: Head, data: Data, revision: Int64) {
        let statement = try prepare("SELECT revision,head,checksum,state,created_at FROM jobs WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
        let revision = sqlite3_column_int64(statement, 0)
        let data = try blob(statement, 1)
        guard Self.digest(data) == string(statement, 2) else { throw FileOperationFailure.recoveryUncertain }
        let head = try JSONDecoder().decode(Head.self, from: data)
        if [4, 7, 9, 10].contains(catalogVersion) {
            let expected = try OperationCatalogProtocol.ordinary(version: head.version)
            guard try catalogProtocol(id) == expected,
                  try integers("SELECT count(*) FROM grouped_groups WHERE job=?", [.text(id)]) == [0],
                  try integers("SELECT count(*) FROM grouped_members WHERE job=?", [.text(id)]) == [0],
                  try integers("SELECT count(*) FROM grouped_revision_heads WHERE job=?", [.text(id)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        }
        guard head.id.uuidString == id, head.owner == owner, head.counts.count == 4,
              head.revision == revision, revision >= 0, revision < Int64(Int.max - 1),
              string(statement, 3) == head.state,
              sqlite3_column_double(statement, 4) == head.createdAt.timeIntervalSinceReferenceDate,
              try integers("SELECT max(revision) FROM events WHERE job=?", [.text(id)]) == [revision],
              try texts("SELECT state FROM events WHERE job=? AND revision=?", [.text(id), .int(revision)]) == [head.state] else {
            throw FileOperationFailure.recoveryUncertain
        }
        try OperationJournal.validateCapacity(steps: head.counts[0], areas: head.counts[1], locations: head.counts[2], trashIntents: head.counts[3])
        // Summaries must not hide malformed mixed-protocol rows behind empty
        // temporary validation arrays. Full loading validates their payloads too.
        var header = JournalRecord(version: head.version, owner: head.owner, id: head.id, operation: head.operation)
        header.revision = head.revision; header.state = head.state; header.failureStage = head.failureStage
        header.nameRename = head.nameRename; header.downloadAdoption = head.downloadAdoption
        header.persistentVolumes = head.persistentVolumes
        header.ownedTrash = head.ownedTrash
        header.producedTreeV16 = head.producedTreeV16
        try OperationJournal.validateHeader(header)
        if head.version == 2 || head.version == 4 {
            guard head.counts[0] == 0, head.counts[1] == 0, head.counts[3] == 0,
                  head.nameRename != nil else { throw FileOperationFailure.recoveryUncertain }
        } else if [5, 6, 13, 18, 19, 20].contains(head.version) {
            guard head.operation == ArchiveUpdateProfile.title(version: head.version), head.nameRename == nil,
                  head.counts[0] <= ([13, 18, 19, 20].contains(head.version) ? 2 : 3), head.counts[1] <= 1,
                  head.counts[3] <= ([13, 18, 19, 20].contains(head.version) ? 0 : 1),
                  (![13, 18, 19, 20].contains(head.version) || !["cleanupReview", "cleaned"].contains(head.state)),
                  (head.counts[0] == 0 || head.counts[1] == 1) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if head.state == "committed" {
                guard head.counts[0] == 2, head.counts[1] == 1, head.counts[3] == 0 else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
            if head.state == "undone" {
                guard (1...2).contains(head.counts[0]), head.counts[1] == 1,
                      head.counts[3] == 0 else { throw FileOperationFailure.recoveryUncertain }
            }
            if head.state == "cleaned" {
                guard (2...3).contains(head.counts[0]), head.counts[1] == 1, head.counts[3] == 1 else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
        } else if [14, 15, 16, 17].contains(head.version) {
            let expectedOperation = head.version == 14 ? "Download" : head.version == 15 ? "Extract ZIP"
                : head.version == 17 ? "Extract TAR" : head.producedTreeV16?.historyTitle
            guard head.operation == expectedOperation, head.nameRename == nil,
                  head.downloadAdoption == nil, head.counts[0] <= 1,
                  head.counts[1] <= 1, head.counts[3] == 0 else {
                throw FileOperationFailure.recoveryUncertain
            }
            if ["committed", "undone"].contains(head.state) {
                guard head.counts[0] == 1, head.counts[1] == 1 else { throw FileOperationFailure.recoveryUncertain }
            }
        } else if head.version == 7 {
            guard head.operation == "Download", head.nameRename == nil,
                  head.counts[0] <= 1, head.counts[1] <= 1, head.counts[3] == 0,
                  (head.counts[0] == 0 || head.downloadAdoption?.adoptedStage != nil) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if ["committed", "undone"].contains(head.state) {
                guard head.counts[0] == 1, head.counts[1] == 1 else { throw FileOperationFailure.recoveryUncertain }
            }
        } else if head.version == 8 || head.version == 10 {
            guard head.counts[0] > 0, head.counts[0] <= OperationJournal.maximumTrashIntents,
                  head.counts[1] == 0, head.counts[3] == head.counts[0],
                  head.ownedTrash?.itemCount == head.counts[0] else { throw FileOperationFailure.recoveryUncertain }
        } else if ![1, 3, 9, 11, 12].contains(head.version) || head.nameRename != nil { throw FileOperationFailure.recoveryUncertain }
        return (head, data, revision)
    }

    private func record(_ id: String) throws -> JournalRecord { try loadedRecord(id).record }

    private func loadedRecord(_ id: String) throws -> (record: JournalRecord, rows: [[Data]]) {
        let (head, data, revision) = try readHead(id)
        try OperationJournal.validateCapacity(steps: head.counts[0], areas: head.counts[1], locations: head.counts[2], trashIntents: head.counts[3])
        var remaining = OperationJournal.maximumRecordBytes - data.count
        var rows: [[Data]] = []
        for (index, table) in Self.tables.enumerated() {
            let values = try payloads(table: table, id: id, limit: head.counts[index], maximumBytes: remaining)
            remaining -= values.reduce(0) { $0 + $1.count }
            rows.append(values)
        }
        guard rows.map(\.count) == head.counts,
              try integers("SELECT bytes FROM jobs WHERE id=?", [.text(id)]) == [Int64(OperationJournal.maximumRecordBytes - remaining)],
              try integers("SELECT max(revision) FROM events WHERE job=?", [.text(id)]) == [revision],
              try texts("SELECT state FROM events WHERE job=? AND revision=?", [.text(id), .int(revision)]) == [head.state] else {
            throw FileOperationFailure.recoveryUncertain
        }
        let decoder = JSONDecoder()
        var record = JournalRecord(version: head.version, owner: head.owner, id: head.id, operation: head.operation)
        record.createdAt = head.createdAt; record.revision = Int(revision) + 1; record.state = head.state; record.failureStage = head.failureStage
        record.nameRename = head.nameRename
        record.downloadAdoption = head.downloadAdoption
        record.persistentVolumes = head.persistentVolumes
        record.ownedTrash = head.ownedTrash
        record.producedTreeV16 = head.producedTreeV16
        record.steps = try rows[0].map { try decoder.decode(JournalStep.self, from: $0) }
        record.areas = try rows[1].map { try decoder.decode(JournalArea.self, from: $0) }
        record.locations = try rows[2].map { try decoder.decode(URL.self, from: $0) }
        record.trashIntents = try rows[3].map { try decoder.decode(JournalTrashIntent.self, from: $0) }
        try measureJournal(hooks.metrics, .validation) { try OperationJournal.validate(record, metrics: hooks.metrics) }
        return (record, rows)
    }

    private func payloads(table: String, id: String, limit: Int, maximumBytes: Int = OperationJournal.maximumRecordBytes) throws -> [Data] {
        let statement = try prepare("SELECT ordinal,payload,checksum FROM \(table) WHERE job=? ORDER BY ordinal LIMIT ?", [.text(id), .int(Int64(limit + 1))])
        defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        var bytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Self.failure(status) }
            guard result.count < limit, sqlite3_column_int64(statement, 0) == Int64(result.count) else { throw FileOperationFailure.recoveryUncertain }
            let data = try blob(statement, 1)
            guard Self.digest(data) == string(statement, 2) else { throw FileOperationFailure.recoveryUncertain }
            bytes += data.count
            guard bytes <= maximumBytes else { throw FileOperationFailure.recoveryUncertain }
            result.append(data)
        }
        return result
    }

    func legacyImports() throws -> [String: (revision: Int, digest: String, name: String)] {
        let statement = try prepare("SELECT job,revision,digest,last_name FROM legacy_imports LIMIT 10001")
        defer { sqlite3_finalize(statement) }
        var result: [String: (Int, String, String)] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, result.count < 10_000 else { throw FileOperationFailure.recoveryUncertain }
            result[string(statement, 0)] = (Int(sqlite3_column_int64(statement, 1)), string(statement, 2), string(statement, 3))
        }
        return result
    }

    func reserve(estimatedBytes: Int) throws {
        try validateFiles()
        guard estimatedBytes >= 0, estimatedBytes <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
        let pageSize = try integer("PRAGMA page_size")
        let used = (try integer("PRAGMA page_count") - integer("PRAGMA freelist_count")) * pageSize
        // Conservative metadata headroom, not a filesystem space guarantee.
        guard used + Int64(estimatedBytes) * 3 + 1_048_576 < min(Self.maximumStoreBytes, try integer("PRAGMA max_page_count") * pageSize) else { throw FileOperationFailure.unsupported }
        var fs = statfs()
        guard fstatfs(anchor.fd, &fs) == 0 else { throw posixFailure() }
        guard UInt64(fs.f_bavail) * UInt64(fs.f_bsize) >= UInt64(estimatedBytes) * 3 + 1_048_576 else { throw FileOperationFailure.outOfSpace }
    }

    func durabilityConfiguration() throws -> (synchronous: Int64, fullFSync: Int64) {
        (try integer("PRAGMA synchronous"), try integer("PRAGMA fullfsync"))
    }

    struct MaintenanceSummary: Sendable {
        let databaseBytes: Int64
        let eventCount: Int64
        let freePages: Int64
    }
    func maintenance(compact: Bool, cancellation: OperationCancellation = OperationCancellation()) throws -> MaintenanceSummary {
        if [9,10].contains(catalogVersion), try integer("SELECT count(*) FROM job_protocols WHERE kind='textRevisionV3'") > 0 {
            throw FileOperationFailure.unsupported
        }
        if [7, 9, 10].contains(catalogVersion), try integer("SELECT count(*) FROM job_protocols WHERE kind='selectionGroupV2'") > 0 {
            throw FileOperationFailure.unsupported
        }

        try validateFiles()
        try cancellation.check()
        if compact {
            if [4, 7, 9, 10].contains(catalogVersion) { try validateCatalog(cancellation: cancellation) }
            // Events summarize phases only. Complete latest rows remain authoritative.
            // No legacy evidence, retained object, area or recovery row is deleted.
            try transaction {
                try exec("DELETE FROM events WHERE revision < (SELECT revision FROM jobs WHERE jobs.id=events.job) AND job IN (SELECT id FROM jobs WHERE state IN ('committed','undone','cleaned'))")
                if [4, 7, 9, 10].contains(catalogVersion) {
                    try exec("DELETE FROM events WHERE revision < (SELECT revision FROM jobs WHERE jobs.id=events.job) AND job IN (SELECT job FROM job_protocols WHERE kind='groupedCopyV1') AND job IN (SELECT id FROM jobs WHERE state IN ('completed','stoppedSettled','undone','cleaned'))")
                    try exec("DELETE FROM grouped_revision_heads WHERE revision < (SELECT revision FROM jobs WHERE jobs.id=grouped_revision_heads.job) AND job IN (SELECT id FROM jobs WHERE state IN ('completed','stoppedSettled','undone','cleaned'))")
                }
            }
            try exec("PRAGMA incremental_vacuum(256)")
            try validateFiles()
        }
        return MaintenanceSummary(databaseBytes: try integer("PRAGMA page_count") * integer("PRAGMA page_size"),
                                  eventCount: try integer("SELECT count(*) FROM events"), freePages: try integer("PRAGMA freelist_count"))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try measureJournal(hooks.metrics, .encoding) { try encoder.encode(value) }
        hooks.metrics?.add(.encodedRows, 1)
        hooks.metrics?.add(.encodedBytes, data.count)
        guard data.count <= Self.maximumRowBytes else { throw FileOperationFailure.unsupported }
        return data
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum Value { case text(String), int(Int64), double(Double), blob(Data), null }
    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        try inspectionBudget?.check()
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw observedFailure(status) }
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
                case .int(let integer): result = sqlite3_bind_int64(statement, index, integer)
                case .double(let number): result = sqlite3_bind_double(statement, index, number)
                case .blob(let bytes): result = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(bytes.count), transient) }
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw Self.failure(result) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        guard !isReadOnlyInspection else { throw FileOperationFailure.invalidRequest }
        let measurementStart = hooks.metrics?.start()
        defer { if let measurementStart { hooks.metrics?.finish(.rowSQL, since: measurementStart) } }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw observedFailure(result) }
    }
    private func exec(_ sql: String) throws {
        if isReadOnlyInspection {
            guard ["PRAGMA trusted_schema=OFF", "PRAGMA query_only=ON", "PRAGMA temp_store=MEMORY",
                   "PRAGMA cache_size=-2048"].contains(sql) else { throw FileOperationFailure.invalidRequest }
        }
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw observedFailure(result) }
    }
    private func observedFailure(_ code: Int32) -> FileOperationFailure {
        hooks.observedSQLiteFailureCode?(code)
        if observingTextRecordStart, code != SQLITE_OK { FileOperationDiagnostics.sqliteFailure(code) }
        return Self.failure(code)
    }
    private func transaction(_ action: () throws -> Void) throws {
        guard !isReadOnlyInspection else { throw FileOperationFailure.invalidRequest }
        try validateFiles(); try exec("BEGIN IMMEDIATE")
        do {
            try action(); try validateFiles()
            try measureJournal(hooks.metrics, .commit) { try exec("COMMIT") }
            // Test-only lost acknowledgement: the transaction committed, but its caller
            // receives an error through exactly the transaction-failure path.
            try hooks.afterCommitBeforeAcknowledgement?()
        } catch {
            let original = error
            do { try hooks.beforeSaveRollback?(); try exec("ROLLBACK") } catch { /* Preserve the original save failure. */ }
            throw original
        }
    }
    private func texts(_ sql: String, _ values: [Value] = []) throws -> [String] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Self.failure(status) }
            result.append(string(statement, 0))
        }
    }
    private func integers(_ sql: String, _ values: [Value] = []) throws -> [Int64] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [Int64] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Self.failure(status) }
            result.append(sqlite3_column_int64(statement, 0))
        }
    }
    private func integer(_ sql: String) throws -> Int64 {
        guard let value = try integers(sql).first else { throw FileOperationFailure.recoveryUncertain }; return value
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        let count = sqlite3_column_bytes(statement, column)
        guard count >= 0, count <= Self.maximumRowBytes, let pointer = sqlite3_column_blob(statement, column) else { throw FileOperationFailure.recoveryUncertain }
        hooks.metrics?.add(.sqlPayloadReads,1);hooks.metrics?.add(.sqlPayloadBytes,Int(count))
        return Data(bytes: pointer, count: Int(count))
    }
    /// Explicit opt-in migration only. OperationJournal owns the writer lock and
    /// reopens this connection cold before returning successful upgrade authority.
    func upgradeForGroupedCopy(cancellation: OperationCancellation) throws {
        try validateFiles()
        guard editCache == nil, groupedEditCache == nil else { throw FileOperationFailure.unavailable }
        if [4, 7, 9, 10].contains(catalogVersion) { try validateCatalog(cancellation: cancellation); return }
        guard catalogVersion == 3 else { throw FileOperationFailure.recoveryUncertain }
        try validateCatalog(cancellation: cancellation)
        try transaction {
            for sql in Self.groupedSchema { try exec(sql) }
            try eachJobID { id in
                try cancellation.check()
                let record = try loadedRecord(id).record
                let kind = try OperationCatalogProtocol.ordinary(version: record.version)
                try run("INSERT INTO job_protocols VALUES (?, ?, ?)", [.text(id), .text(kind.rawValue), .int(Int64(kind.version))])
            }
            try run("UPDATE metadata SET value='4' WHERE key='version'")
            try exec("PRAGMA user_version=4")
            try hooks.beforeCatalogUpgradeCommit?()
        }
        catalogVersion = 4
        try hooks.afterCatalogUpgradeCommit?()
    }

    private func eachJobID(_ body: (String) throws -> Void) throws {
        guard try integer("SELECT count(*) FROM jobs") <= 10_000 else { throw FileOperationFailure.recoveryUncertain }
        var previous: String?
        while true {
            let ids = try previous.map { try texts("SELECT id FROM jobs WHERE id > ? ORDER BY id LIMIT 64", [.text($0)]) }
                ?? texts("SELECT id FROM jobs ORDER BY id LIMIT 64")
            guard !ids.isEmpty else { return }
            for id in ids {
                guard UUID(uuidString: id)?.uuidString == id else { throw FileOperationFailure.recoveryUncertain }
                try body(id)
            }
            previous = ids.last
        }
    }

    func validateCatalog(cancellation: OperationCancellation) throws {
        try validateFiles(); try cancellation.check()
        guard try texts("PRAGMA quick_check") == ["ok"] else { throw FileOperationFailure.recoveryUncertain }
        let foreign = try prepare("PRAGMA foreign_key_check", [])
        defer { sqlite3_finalize(foreign) }
        guard sqlite3_step(foreign) == SQLITE_DONE else { throw FileOperationFailure.recoveryUncertain }
        if [4, 7, 9, 10].contains(catalogVersion) {
            guard try integer("SELECT count(*) FROM job_protocols") == integer("SELECT count(*) FROM jobs") else { throw FileOperationFailure.recoveryUncertain }
        }
        try eachJobID { id in
            hooks.metrics?.add(.fullAuditJobs,1)
            try cancellation.check()
            _ = try catalogRecord(UUID(uuidString: id)!)
        }
        if catalogVersion == 9 { _ = try legacyTextGraph9() }
        if catalogVersion == 10 { try validateEpochCatalog10(cancellation:cancellation) }
        try cancellation.check()
    }

    private func catalogProtocol(_ id: String) throws -> OperationCatalogProtocol {
        if ![4, 7, 9, 10].contains(catalogVersion) { return .treeV1 }
        let statement = try prepare("SELECT kind,version FROM job_protocols WHERE job=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let kind = OperationCatalogProtocol(rawValue: string(statement, 0)),
              sqlite3_column_int64(statement, 1) == Int64(kind.version), sqlite3_step(statement) == SQLITE_DONE else { throw FileOperationFailure.recoveryUncertain }
        return kind
    }

    private func writeLegacyProtocol(_ record: JournalRecord, promotingOwnedTrash: Bool = false) throws {
        guard [4, 7, 9, 10].contains(catalogVersion) else { return }
        let kind = try OperationCatalogProtocol.ordinary(version: record.version)
        let existing = try texts("SELECT kind FROM job_protocols WHERE job=?", [.text(record.id.uuidString)])
        if promotingOwnedTrash {
            let from: OperationCatalogProtocol = record.version == 10 ? .treeTrashRootAddV9 : .treeV3
            guard [8, 10].contains(record.version), existing == [from.rawValue] else {
                throw FileOperationFailure.recoveryUncertain
            }
            try run("UPDATE job_protocols SET kind=?,version=? WHERE job=? AND kind=? AND version=?",
                    [.text(kind.rawValue), .int(Int64(kind.version)), .text(record.id.uuidString),
                     .text(from.rawValue), .int(Int64(from.version))])
            guard sqlite3_changes(db) == 1 else { throw FileOperationFailure.recoveryUncertain }
            return
        }
        if [8, 10].contains(record.version) && existing.isEmpty { throw FileOperationFailure.recoveryUncertain }
        guard existing.isEmpty || existing == [kind.rawValue] else { throw FileOperationFailure.recoveryUncertain }
        try run("INSERT INTO job_protocols VALUES (?, ?, ?) ON CONFLICT(job) DO NOTHING",
                [.text(record.id.uuidString), .text(kind.rawValue), .int(Int64(kind.version))])
    }

    func catalogRecord(_ id: UUID) throws -> OperationCatalogRecord? {
        try validateFiles()
        guard sqlite3_get_autocommit(db) != 0 else { throw FileOperationFailure.recoveryUncertain }
        guard !(try integers("SELECT revision FROM jobs WHERE id=?", [.text(id.uuidString)])).isEmpty else { return nil }
        if try catalogProtocol(id.uuidString) == .textRevisionV3 { return .textRevisionV3(try textRecordV2(id)) }
        if [9,10].contains(catalogVersion) {
            for table in ["text_revision_events", "text_revision_heads", "text_revision_exports"] {
                guard try integers("SELECT count(*) FROM \(table) WHERE job=?", [.text(id.uuidString)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
            }
        }
        if catalogVersion == 10 {
            guard try integers("SELECT text_slot10 IS NULL FROM jobs WHERE id=?",[.text(id.uuidString)]) == [1] else {throw FileOperationFailure.recoveryUncertain}
            for table in ["text_members10","text_epoch_edges10","text_mutation_guards10"] {
                guard try integers("SELECT count(*) FROM \(table) WHERE job=?",[.text(id.uuidString)]) == [0] else {throw FileOperationFailure.recoveryUncertain}
            }
        }
        if try catalogProtocol(id.uuidString) == .selectionGroupV2 { return .selectionGroupV2(try loadSelectionGroup(id.uuidString)) }
        if [7, 9, 10].contains(catalogVersion) {
            guard try integers("SELECT count(*) FROM selection_members WHERE job=?", [.text(id.uuidString)]) == [0],
                  try integers("SELECT count(*) FROM selection_events WHERE job=?", [.text(id.uuidString)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        }
        if try catalogProtocol(id.uuidString) == .groupedCopyV1 { return .groupedCopyV1(try loadedGroupedRecord(id.uuidString).record) }
        let record = try loadedRecord(id.uuidString).record
        switch record.version {
        case 1: return .treeV1(record)
        case 2: return .nameRenameV2(record)
        case 3: return .treeV3(record)
        case 4: return .nameRenameV4(record)
        case 5: return .archiveUpdateV5(record)
        case 6: return .archiveStrictCloneV6(record)
        case 7: return .downloadAdoptionV7(record)
        case 8: return .ownedTrashV8(record)
        case 9: return .treeTrashRootAddV9(record)
        case 10: return .ownedTrashRootAddDeleteV10(record)
        case 11: return .treeNativeTrashV11(record)
        case 12: return .treeNativeTrashV12(record)
        case 13: return .archiveNativeUpdateV13(record)
        case 14: return .receivedPublicDownloadV14(record)
        case 15: return .publicZIPExtractionFileV15(record)
        case 16: return .publicProducedTreeV16(record)
        case 17: return .publicTARExtractionFileV17(record)
        case 18: return .tarNativeUpdateV18(record)
        case 19: return .tarGzipNativeUpdateV19(record)
        case 20: return .tarBzip2NativeUpdateV20(record)
        default: throw FileOperationFailure.recoveryUncertain
        }
    }

    func beginGroupedEdit(members: [GroupedCopyManifestMember], groupSize: Int,
                          metadataPolicy: TransferMetadataPolicy) throws -> GroupedCopyEditSession {
        try validateFiles()
        guard [4, 7, 9, 10].contains(catalogVersion) else { throw FileOperationFailure.unsupported }
        guard sqlite3_get_autocommit(db) != 0 else { throw FileOperationFailure.recoveryUncertain }
        let id = UUID()
        let head = GroupedCopyHead(protocolKind: .groupedCopyV1, protocolVersion: 1, owner: owner, id: id,
            createdAt: Date(), metadataPolicy: metadataPolicy, groupSize: groupSize, admittedCount: members.count,
            groupCount: 0, revision: 0, state: .preparing, undoInvalidated: false, reviewIntent: nil)
        let record = GroupedCopyRecord(head: head, groups: [], members: members.enumerated().map {
            GroupedCopyMember(owner: owner, job: id, ordinal: $0.offset, manifest: $0.element, progress: .notDeclared)
        })
        try record.validate()
        var estimate = 16_384 + members.count * 4096 + ((members.count + groupSize - 1) / groupSize) * 1024
        for member in members {
            let pathBytes = member.source.url.path.utf8.count + member.destination.url.path.utf8.count
            guard pathBytes <= Self.maximumRowBytes else { throw FileOperationFailure.unsupported }
            let (next, overflow) = estimate.addingReportingOverflow(pathBytes * 8)
            guard !overflow, next <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
            estimate = next
        }
        try reserve(estimatedBytes: estimate)
        let session = GroupedCopyEditSession(record, new: true)
        groupedEditCache?.session.invalidate()
        groupedEditCache = GroupedEditCache(session: session, groups: [], members: [])
        editCache = nil; cachedRows = [:]; cachedRecords = [:]
        return session
    }

    func openGroupedEdit(_ id: UUID) throws -> GroupedCopyEditSession? {
        try validateFiles()
        guard [4, 7, 9, 10].contains(catalogVersion) else { throw FileOperationFailure.unsupported }
        guard sqlite3_get_autocommit(db) != 0 else { throw FileOperationFailure.recoveryUncertain }
        guard !(try integers("SELECT revision FROM jobs WHERE id=?", [.text(id.uuidString)])).isEmpty else { return nil }
        let loaded = try loadedGroupedRecord(id.uuidString)
        let session = GroupedCopyEditSession(loaded.record, new: false)
        groupedEditCache?.session.invalidate()
        groupedEditCache = GroupedEditCache(session: session, groups: loaded.groups, members: loaded.members)
        editCache = nil; cachedRows = [:]; cachedRecords = [:]
        return session
    }

    func save(_ session: GroupedCopyEditSession) throws {
        let started = hooks.metrics?.start()
        defer { if let started { hooks.metrics?.finish(.save, since: started) } }
        do { try saveGrouped(session) }
        catch {
            // Even a pre-commit failure retires grouped authority. No caller can
            // confuse its in-memory filesystem observations with a committed subset.
            session.invalidate()
            if groupedEditCache?.session === session { groupedEditCache = nil }
            throw error
        }
    }

    private func saveGrouped(_ session: GroupedCopyEditSession) throws {
        guard [4, 7, 9, 10].contains(catalogVersion), session.valid, let cache = groupedEditCache,
              cache.session === session, cache.revision == session.revision else { throw FileOperationFailure.recoveryUncertain }
        try validateFiles()
        let record = session.snapshot, id = session.id.uuidString
        try GroupedCopyRecord.validateHead(record.head)
        let revisions = try integers("SELECT revision FROM jobs WHERE id=?", [.text(id)])
        guard revisions.isEmpty ? session.revision == 0 : revisions == [Int64(session.revision - 1)],
              record.groups.count == record.head.groupCount, record.members.count == record.head.admittedCount,
              record.groups.count >= cache.groups.count, record.members.count >= cache.members.count else { throw FileOperationFailure.recoveryUncertain }
        if revisions.isEmpty {
            guard try integer("SELECT count(*) FROM jobs") < 10_000 else { throw FileOperationFailure.unsupported }
        } else { guard try catalogProtocol(id) == .groupedCopyV1 else { throw FileOperationFailure.recoveryUncertain } }
        var groupChanges: [(Int, Data)] = [], memberChanges: [(Int, Data)] = []
        var bytes = cache.bytes
        for index in session.changedGroups.sorted() {
            guard record.groups.indices.contains(index) else { throw FileOperationFailure.recoveryUncertain }
            hooks.metrics?.add(.comparedRows, 1); hooks.metrics?.add(.validatedRows, 1)
            try record.validateGroup(at: index)
            let encoded = try encode(record.groups[index])
            let prior = index < cache.groups.count ? cache.groups[index] : nil
            if encoded != prior { bytes += encoded.count - (prior?.count ?? 0); groupChanges.append((index, encoded)) }
        }
        for index in session.changedMembers.sorted() {
            guard record.members.indices.contains(index) else { throw FileOperationFailure.recoveryUncertain }
            hooks.metrics?.add(.comparedRows, 1); hooks.metrics?.add(.validatedRows, 1)
            try GroupedCopyRecord.validateMember(record.members[index], head: record.head)
            let encoded = try encode(record.members[index])
            let prior = index < cache.members.count ? cache.members[index] : nil
            if encoded != prior { bytes += encoded.count - (prior?.count ?? 0); memberChanges.append((index, encoded)) }
        }
        let head = try encode(record.head), checksum = Self.digest(head)
        let (size, overflow) = bytes.addingReportingOverflow(head.count)
        guard !overflow, size <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
        try transaction {
            try run("INSERT INTO jobs (id,revision,created_at,state,head,checksum,bytes) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,created_at=excluded.created_at,state=excluded.state,head=excluded.head,checksum=excluded.checksum,bytes=excluded.bytes",
                [.text(id), .int(Int64(session.revision)), .double(record.head.createdAt.timeIntervalSinceReferenceDate), .text(record.head.state.rawValue), .blob(head), .text(checksum), .int(Int64(size))])
            try run("INSERT INTO job_protocols VALUES (?, ?, 1) ON CONFLICT(job) DO NOTHING", [.text(id), .text(OperationCatalogProtocol.groupedCopyV1.rawValue)])
            hooks.metrics?.add(.rowScanCandidates, groupChanges.count + memberChanges.count)
            for (index, data) in groupChanges {
                hooks.metrics?.add(.writtenRows, 1)
                try run("INSERT INTO grouped_groups VALUES (?, ?, ?, ?, ?) ON CONFLICT(job,ordinal) DO UPDATE SET phase=excluded.phase,payload=excluded.payload,checksum=excluded.checksum",
                    [.text(id), .int(Int64(index)), .text(record.groups[index].phase.rawValue + ":" + record.groups[index].cleanup.phase), .blob(data), .text(Self.digest(data))])
            }
            for (index, data) in memberChanges {
                hooks.metrics?.add(.writtenRows, 1)
                let member = record.members[index]
                try run("INSERT INTO grouped_members VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(job,ordinal) DO UPDATE SET group_ordinal=excluded.group_ordinal,phase=excluded.phase,payload=excluded.payload,checksum=excluded.checksum",
                    [.text(id), .int(Int64(index)), member.progress.declaration.map { .int(Int64($0.groupOrdinal)) } ?? .null,
                     .text(member.progress.phase), .blob(data), .text(Self.digest(data))])
            }
            try run("INSERT INTO events VALUES (?, ?, ?)", [.text(id), .int(Int64(session.revision)), .text(record.head.state.rawValue)])
            try run("INSERT INTO grouped_revision_heads VALUES (?, ?, ?)", [.text(id), .int(Int64(session.revision)), .text(checksum)])
            try hooks.beforeSaveCommit?()
        }
        try hooks.afterSaveCommit?(); try validateFiles()
        for (index, data) in groupChanges {
            if index == cache.groups.count { cache.groups.append(data) } else { cache.groups[index] = data }
        }
        for (index, data) in memberChanges {
            if index == cache.members.count { cache.members.append(data) } else { cache.members[index] = data }
        }
        cache.bytes = bytes; session.didCommit(); cache.revision = session.revision
    }

    private func readGroupedHead(_ id: String) throws -> (head: GroupedCopyHead, data: Data, bytes: Int) {
        guard [4, 7, 9, 10].contains(catalogVersion), try catalogProtocol(id) == .groupedCopyV1 else { throw FileOperationFailure.recoveryUncertain }
        let statement = try prepare("SELECT revision,head,checksum,state,created_at,bytes FROM jobs WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
        let data = try blob(statement, 1), checksum = Self.digest(data)
        guard checksum == string(statement, 2) else { throw FileOperationFailure.recoveryUncertain }
        let head = try JSONDecoder().decode(GroupedCopyHead.self, from: data)
        try GroupedCopyRecord.validateHead(head)
        let revision = Int64(head.revision), bytes = sqlite3_column_int64(statement, 5)
        guard head.owner == owner, head.id.uuidString == id, sqlite3_column_int64(statement, 0) == revision,
              string(statement, 3) == head.state.rawValue, sqlite3_column_double(statement, 4) == head.createdAt.timeIntervalSinceReferenceDate,
              bytes >= Int64(data.count), bytes <= Int64(OperationJournal.maximumRecordBytes),
              try integers("SELECT max(revision) FROM events WHERE job=?", [.text(id)]) == [revision],
              try texts("SELECT state FROM events WHERE job=? AND revision=?", [.text(id), .int(revision)]) == [head.state.rawValue],
              try integers("SELECT max(revision) FROM grouped_revision_heads WHERE job=?", [.text(id)]) == [revision],
              try texts("SELECT head_checksum FROM grouped_revision_heads WHERE job=? AND revision=?", [.text(id), .int(revision)]) == [checksum],
              try integers("SELECT count(*) FROM grouped_groups WHERE job=?", [.text(id)]) == [Int64(head.groupCount)],
              try integers("SELECT count(*) FROM grouped_members WHERE job=?", [.text(id)]) == [Int64(head.admittedCount)] else { throw FileOperationFailure.recoveryUncertain }
        for table in Self.tables {
            guard try integers("SELECT count(*) FROM \(table) WHERE job=?", [.text(id)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        }
        guard try integers("SELECT count(*) FROM legacy_imports WHERE job=?", [.text(id)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        return (head, data, Int(bytes))
    }

    private func loadedGroupedRecord(_ id: String) throws -> (record: GroupedCopyRecord, groups: [Data], members: [Data]) {
        let loaded = try readGroupedHead(id)
        var remaining = OperationJournal.maximumRecordBytes - loaded.data.count
        let groupData = try payloads(table: "grouped_groups", id: id, limit: loaded.head.groupCount, maximumBytes: remaining)
        remaining -= groupData.reduce(0) { $0 + $1.count }
        let memberData = try payloads(table: "grouped_members", id: id, limit: loaded.head.admittedCount, maximumBytes: remaining)
        remaining -= memberData.reduce(0) { $0 + $1.count }
        guard OperationJournal.maximumRecordBytes - remaining == loaded.bytes else { throw FileOperationFailure.recoveryUncertain }
        let decoder = JSONDecoder()
        var record = GroupedCopyRecord(head: loaded.head,
            groups: try groupData.map { try decoder.decode(GroupedCopyGroup.self, from: $0) },
            members: try memberData.map { try decoder.decode(GroupedCopyMember.self, from: $0) })
        try record.validate()
        for group in record.groups {
            guard try texts("SELECT phase FROM grouped_groups WHERE job=? AND ordinal=?", [.text(id), .int(Int64(group.ordinal))]) == [group.phase.rawValue + ":" + group.cleanup.phase] else { throw FileOperationFailure.recoveryUncertain }
        }
        for member in record.members {
            let statement = try prepare("SELECT group_ordinal,phase FROM grouped_members WHERE job=? AND ordinal=?", [.text(id), .int(Int64(member.ordinal))])
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, string(statement, 1) == member.progress.phase else { throw FileOperationFailure.recoveryUncertain }
            if let declaration = member.progress.declaration {
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_int64(statement, 0) == Int64(declaration.groupOrdinal) else { throw FileOperationFailure.recoveryUncertain }
            } else { guard sqlite3_column_type(statement, 0) == SQLITE_NULL else { throw FileOperationFailure.recoveryUncertain } }
        }
        hooks.metrics?.add(.validatedRows, groupData.count + memberData.count)
        record.head.revision += 1
        return (record, groupData, memberData)
    }

    internal static func failure(_ code: Int32) -> FileOperationFailure {
        switch code & 0xff {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_SCHEMA, SQLITE_CONSTRAINT: .recoveryUncertain
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CANTOPEN: .unavailable
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH: .accessDenied
        case SQLITE_FULL: .outOfSpace
        default: .ioFailure
        }
    }
}

extension SQLiteJournalStore {
    private static let selectionSchema = [
        "CREATE TABLE selection_members (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE selection_events (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))"
    ]
    private struct SelectionHead: Codable {
        let protocolKind: OperationCatalogProtocol
        let version: Int
        let manifest: SelectionGroupManifest
        let members: Int
        let events: Int
        let state: SelectionGroupState
    }
    private func selectionHead(_ record: SelectionGroupRecord) throws -> Data {
        let m = record.manifest
        let thin = SelectionGroupManifest(owner: m.owner, id: m.id, createdAt: m.createdAt, parent: m.parent,
            parentIdentity: m.parentIdentity, volume: m.volume, folderName: m.folderName, areaName: m.areaName, members: [])
        return try encode(SelectionHead(protocolKind: .selectionGroupV2, version: 2, manifest: thin,
            members: m.members.count, events: record.events.count, state: record.project().state))
    }
    func loadSelectionGroup(_ id: String) throws -> SelectionGroupRecord {
        guard [7, 9, 10].contains(catalogVersion), try catalogProtocol(id) == .selectionGroupV2 else { throw FileOperationFailure.recoveryUncertain }
        let query = try prepare("SELECT revision,head,checksum,state,created_at,bytes FROM jobs WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
        let headBytes = try blob(query, 1), head = try JSONDecoder().decode(SelectionHead.self, from: headBytes)
        guard try headBytes == encode(head), Self.digest(headBytes) == string(query, 2),
              head.protocolKind == .selectionGroupV2, head.version == 2, head.manifest.owner == owner,
              head.manifest.id.uuidString == id, head.manifest.members.isEmpty,
              (1...512).contains(head.members), (0...(4 * head.members + 32)).contains(head.events),
              sqlite3_column_int64(query, 0) == Int64(head.events + 1),
              string(query, 3) == head.state.rawValue,
              sqlite3_column_double(query, 4) == head.manifest.createdAt.timeIntervalSinceReferenceDate else { throw FileOperationFailure.recoveryUncertain }
        let members = try payloads(table: "selection_members", id: id, limit: head.members)
        let events = try payloads(table: "selection_events", id: id, limit: head.events)
        guard members.count == head.members, events.count == head.events,
              Int64(headBytes.count + (members + events).reduce(0, { $0 + $1.count })) == sqlite3_column_int64(query, 5),
              try integers("SELECT count(*) FROM events WHERE job=?", [.text(id)]) == [Int64(head.events + 1)],
              try texts("SELECT state FROM events WHERE job=? AND revision=?", [.text(id), .int(Int64(head.events + 1))]) == [head.state.rawValue] else { throw FileOperationFailure.recoveryUncertain }
        for table in Self.tables + ["grouped_groups", "grouped_members", "grouped_revision_heads", "legacy_imports"] {
            guard try integers("SELECT count(*) FROM \(table) WHERE job=?", [.text(id)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        }
        let m = head.manifest
        let record = SelectionGroupRecord(manifest: SelectionGroupManifest(owner: m.owner, id: m.id,
            createdAt: m.createdAt, parent: m.parent, parentIdentity: m.parentIdentity, volume: m.volume,
            folderName: m.folderName, areaName: m.areaName,
            members: try members.map { try JSONDecoder().decode(NativeRenameEntry.self, from: $0) }),
            events: try events.map { try JSONDecoder().decode(SelectionGroupEvent.self, from: $0) })
        guard try record.project().state == head.state, try selectionHead(record) == headBytes else { throw FileOperationFailure.recoveryUncertain }
        for (value, bytes) in zip(record.manifest.members, members) { guard try encode(value) == bytes else { throw FileOperationFailure.recoveryUncertain } }
        for (value, bytes) in zip(record.events, events) { guard try encode(value) == bytes else { throw FileOperationFailure.recoveryUncertain } }
        return record
    }
    func beginSelectionGroup(_ manifest: SelectionGroupManifest) throws -> SelectionGroupRecord {
        try validateWriteCatalog(cancellation: OperationCancellation())
        guard [7, 9, 10].contains(catalogVersion), manifest.owner == owner, editCache == nil, groupedEditCache == nil,
              try integer("SELECT count(*) FROM jobs") < 10_000 else { throw FileOperationFailure.recoveryUncertain }
        let record = SelectionGroupRecord(manifest: manifest, events: []); _ = try record.project()
        let head = try selectionHead(record), rows = try manifest.members.map { try encode($0) }
        try reserveSelectionCapacity(record)
        try transaction {
            try run("INSERT INTO jobs (id,revision,created_at,state,head,checksum,bytes) VALUES (?,1,?,?,?,?,?)", [.text(manifest.id.uuidString),
                .double(manifest.createdAt.timeIntervalSinceReferenceDate), .text("preparing"), .blob(head), .text(Self.digest(head)),
                .int(Int64(head.count + rows.reduce(0, { $0 + $1.count })))])
            try run("INSERT INTO job_protocols VALUES (?,'selectionGroupV2',2)", [.text(manifest.id.uuidString)])
            for (ordinal, row) in rows.enumerated() {
                try run("INSERT INTO selection_members VALUES (?,?,?,?)", [.text(manifest.id.uuidString), .int(Int64(ordinal)), .blob(row), .text(Self.digest(row))])
            }
            try run("INSERT INTO events VALUES (?,1,'preparing')", [.text(manifest.id.uuidString)])
            try hooks.beforeSaveCommit?()
        }
        try hooks.afterSaveCommit?()
        selectionCached = record; selectionCachedHead = head
        return record
    }
    func reserveSelectionCapacity(_ record: SelectionGroupRecord) throws {
        _ = try record.project()
        let immutable = try record.manifest.members.reduce(0) { try $0 + encode($1).count }
        let remaining = record.maximumEvents - record.events.count
        let estimate = immutable + 2 * Self.maximumRowBytes + remaining * SelectionGroupRecord.maximumEventBytes
        guard estimate <= OperationJournal.maximumRecordBytes else { throw FileOperationFailure.unsupported }
        try reserve(estimatedBytes: estimate)
    }
    func appendSelectionGroup(_ old: SelectionGroupRecord, _ event: SelectionGroupEvent) throws -> SelectionGroupRecord {
        try validateWriteCatalog(cancellation: OperationCancellation())
        if selectionCached != old {
            guard try loadSelectionGroup(old.manifest.id.uuidString) == old else { throw FileOperationFailure.sourceChanged }
            selectionCached = old; selectionCachedHead = try selectionHead(old)
        }
        let next = try old.appending(event), head = try selectionHead(next), payload = try encode(event), previousHead = try selectionHead(old)
        guard payload.count <= SelectionGroupRecord.maximumEventBytes else { throw FileOperationFailure.unsupported }
        try transaction {
            guard try integer("PRAGMA data_version") == validatedDataVersion,
                  try texts("SELECT checksum FROM jobs WHERE id=? AND revision=?", [.text(old.manifest.id.uuidString), .int(Int64(old.revision))]) == [Self.digest(previousHead)] else { throw FileOperationFailure.sourceChanged }
            try run("INSERT INTO selection_events VALUES (?,?,?,?)", [.text(old.manifest.id.uuidString), .int(Int64(old.events.count)), .blob(payload), .text(Self.digest(payload))])
            try run("UPDATE jobs SET revision=?,state=?,head=?,checksum=?,bytes=bytes+? WHERE id=? AND revision=?",
                [.int(Int64(next.revision)), .text(try next.project().state.rawValue), .blob(head), .text(Self.digest(head)),
                 .int(Int64(payload.count + head.count - previousHead.count)), .text(old.manifest.id.uuidString), .int(Int64(old.revision))])
            guard sqlite3_changes(db) == 1 else { throw FileOperationFailure.recoveryUncertain }
            try run("INSERT INTO events VALUES (?,?,?)", [.text(old.manifest.id.uuidString), .int(Int64(next.revision)), .text(try next.project().state.rawValue)])
            try hooks.beforeSaveCommit?()
        }
        try hooks.afterSaveCommit?()
        selectionCached = next; selectionCachedHead = head
        return next
    }

    /// Explicit caller action under the original writer lock. Backup is a fresh
    /// private sibling directory with the original owner/tokens and exact DB bytes.
    func upgradeForSelectionGroup(backup: URL, cancellation: OperationCancellation) throws {
        guard [3,4].contains(catalogVersion), editCache == nil, groupedEditCache == nil,
              sqlite3_get_autocommit(db) != 0, backup.deletingLastPathComponent() == anchor.url.deletingLastPathComponent() else { throw FileOperationFailure.invalidRequest }
        try validateCatalog(cancellation: cancellation)
        let parent = try DirectoryAnchor(backup.deletingLastPathComponent(), resolve: false)
        try validateName(backup.lastPathComponent)
        guard mkdirat(parent.fd, backup.lastPathComponent, 0o700) == 0 else { throw posixFailure() }
        let target = try DirectoryAnchor(backup, resolve: false)
        for token in [".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2"] {
            try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: token, anchor: target)
        }
        // A recoverable old catalog also needs every imported legacy revision.
        // These are bounded private history metadata, never selected item bodies.
        var legacyBytes = 0, legacyFiles = 0
        for (id, evidence) in try legacyImports().sorted(by: { $0.key < $1.key }) {
            guard UUID(uuidString: id)?.uuidString == id, evidence.revision >= 0, evidence.revision < 16_384 else { throw FileOperationFailure.unsupported }
            for revision in 0...evidence.revision {
                try cancellation.check()
                legacyFiles += 1
                guard legacyFiles <= 16_384 else { throw FileOperationFailure.unsupported }
                let name = "\(id)-\(String(format: "%06d", revision)).json"
                let original = try EntrySnapshot(parent: anchor.fd, name: name)
                guard original.type == S_IFREG else { throw FileOperationFailure.recoveryUncertain }
                let data = try OperationJournal.read(name: name, anchor: anchor)
                legacyBytes += data.count
                guard legacyBytes <= OperationJournal.maximumRecordBytes,
                      try EntrySnapshot(parent: anchor.fd, name: name) == original else { throw FileOperationFailure.sourceChanged }
                try OperationJournal.writeExclusive(data, name: name, anchor: target)
                guard try EntrySnapshot(parent: anchor.fd, name: name) == original,
                      try OperationJournal.read(name: name, anchor: target) == data else { throw FileOperationFailure.sourceChanged }
            }
        }
        let before = try Self.checkedFile(Self.name, anchor: anchor)
        let sourceFD = openat(anchor.fd, Self.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw posixFailure() }; defer { close(sourceFD) }
        let targetFD = openat(target.fd, Self.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard targetFD >= 0 else { throw posixFailure() }; defer { close(targetFD) }
        guard try EntrySnapshot(fd: sourceFD) == before, before.size >= 0, before.size <= Self.maximumStoreBytes else { throw FileOperationFailure.recoveryUncertain }
        var buffer = [UInt8](repeating: 0, count: 16_384), offset: Int64 = 0
        while offset < before.size {
            try cancellation.check()
            let count = pread(sourceFD, &buffer, min(buffer.count, Int(before.size-offset)), off_t(offset))
            guard count > 0 else { throw posixFailure() }
            try buffer.withUnsafeBytes { raw in
                var written = 0
                while written < count {
                    let amount = write(targetFD, raw.baseAddress!.advanced(by: written), count-written)
                    guard amount > 0 else { throw posixFailure() }; written += amount
                }
            }
            offset += Int64(count)
        }
        guard fsync(targetFD) == 0, fcntl(targetFD, F_FULLFSYNC) == 0,
              try EntrySnapshot(fd: sourceFD) == before, try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.recoveryUncertain }
        try syncDirectory(target); try syncDirectory(parent)
        let cold = try SQLiteJournalStore(readOnly: target, owner: owner, budget: OperationHistoryReadBudget(cancellation: cancellation))
        try cold.validateCatalog(cancellation: cancellation)
        guard cold.inspectedCatalogVersion == catalogVersion else { throw FileOperationFailure.recoveryUncertain }
        // Exercise directory-level legacy custody, beyond passive SQLite summaries.
        do {
            let backupJournal = try OperationJournal(backup, cancellation: cancellation)
            try backupJournal.validateWritableCatalog()
            let inspection = try backupJournal.inspectSummaries()
            guard inspection.refused.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        }
        guard try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.sourceChanged }
        try syncDirectory(target); try syncDirectory(parent)
        try transaction {
            if catalogVersion == 3 {
                for sql in Self.groupedSchema { try exec(sql) }
                try eachJobID { id in
                    let record = try loadedRecord(id).record
                    let kind = try OperationCatalogProtocol.ordinary(version: record.version)
                    try run("INSERT INTO job_protocols VALUES (?,?,?)", [.text(id), .text(kind.rawValue), .int(Int64(kind.version))])
                }
            }
            for sql in Self.selectionSchema { try exec(sql) }
            try run("UPDATE metadata SET value='7' WHERE key='version'"); try exec("PRAGMA user_version=7")
            try hooks.beforeCatalogUpgradeCommit?()
        }
        catalogVersion = 7; try hooks.afterCatalogUpgradeCommit?()
    }
}

// Same-file extension appended to the copied SQLiteJournalStore. One existing
// connection, owner lock and failure state; no editor database is introduced.
extension SQLiteJournalStore {
    private static let textSchemaV2 = [
        "CREATE TABLE text_revision_events (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))",
        "CREATE TABLE text_revision_heads (slot TEXT NOT NULL, ordinal INTEGER NOT NULL, job TEXT NOT NULL REFERENCES jobs(id), payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(slot, ordinal))",
        "CREATE TABLE text_revision_exports (job TEXT NOT NULL REFERENCES jobs(id), ordinal INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(job, ordinal))"
    ]

    private func loadedTextRevisionV2(_ id: String) throws -> TextRevisionRecordV2 {
        hooks.metrics?.add(.epochRecordReads, 1)
        guard [9,10].contains(catalogVersion), try catalogProtocol(id) == .textRevisionV3 else { throw FileOperationFailure.recoveryUncertain }
        let statement = try prepare("SELECT revision,head,checksum,state,created_at,bytes FROM jobs WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
        let head = try blob(statement, 1), value = try textDecoded(TextRevisionRecordV2.self, head)
        let projection = try value.project()
        guard value.manifest.owner == owner, value.id.uuidString == id,
              sqlite3_column_int64(statement, 0) == Int64(value.revision),
              string(statement, 2) == Self.digest(head), string(statement, 3) == projection.state.rawValue,
              sqlite3_column_double(statement, 4) == value.manifest.createdAt.timeIntervalSinceReferenceDate else { throw FileOperationFailure.recoveryUncertain }
        let rows = try payloads(table: "text_revision_events", id: id, limit: value.events.count)
        guard rows == (try value.events.map { try textEncoded($0) }),
              sqlite3_column_int64(statement, 5) == Int64(head.count + rows.reduce(0, { $0 + $1.count })),
              try integers("SELECT count(*) FROM events WHERE job=?", [.text(id)]) == [Int64(value.revision)] else { throw FileOperationFailure.recoveryUncertain }
        let expectedStates = try (0...value.events.count).map {
            try TextRevisionRecordV2(manifest: value.manifest, events: Array(value.events.prefix($0))).project().state.rawValue
        }
        guard try texts("SELECT state FROM events WHERE job=? ORDER BY revision LIMIT 34", [.text(id)]) == expectedStates,
              try integers("SELECT min(revision) FROM events WHERE job=?", [.text(id)]) == [1],
              try integers("SELECT max(revision) FROM events WHERE job=?", [.text(id)]) == [Int64(value.revision)] else { throw FileOperationFailure.recoveryUncertain }
        for table in Self.tables + ["grouped_groups", "grouped_members", "grouped_revision_heads", "selection_members", "selection_events", "legacy_imports"] {
            guard try integers("SELECT count(*) FROM \(table) WHERE job=?", [.text(id)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        }
        return value
    }

    private struct TextGraphV2 {
        var records: [UUID: TextRevisionRecordV2] = [:]
        var heads: [RevisionDigest: TextRevisionHeadV2] = [:]
    }
    private func legacyTextGraph9() throws -> TextGraphV2 {
        guard catalogVersion == 9 else { throw FileOperationFailure.unsupported }
        let ids = try texts("SELECT job FROM job_protocols WHERE kind='textRevisionV3' ORDER BY job LIMIT 65")
        guard ids.count <= 64 else { throw FileOperationFailure.unsupported }
        var graph = TextGraphV2()
        for id in ids {
            let value = try loadedTextRevisionV2(id); graph.records[value.id] = value
        }
        for table in ["text_revision_events", "text_revision_heads", "text_revision_exports"] {
            guard try integer("SELECT count(*) FROM \(table) AS t LEFT JOIN job_protocols AS p ON p.job=t.job WHERE p.kind IS NULL OR p.kind!='textRevisionV3' OR p.version!=3") == 0 else { throw FileOperationFailure.recoveryUncertain }
        }
        let query = try prepare("SELECT slot,ordinal,job,payload,checksum FROM text_revision_heads ORDER BY slot,ordinal LIMIT 129")
        defer { sqlite3_finalize(query) }
        var transitions = 0, appliedByJob: [UUID: Int] = [:], baselinesByJob: [UUID: Int] = [:]
        var knownHeads: [RevisionDigest: [Int: TextRevisionHeadV2]] = [:]
        var lineages: [RevisionDigest: Set<UUID>] = [:]
        while true {
            let status = sqlite3_step(query); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, transitions < 128 else { throw FileOperationFailure.recoveryUncertain }
            let data = try blob(query, 3), transition = try textDecoded(TextRevisionHeadEdgeV3.self, data)
            guard string(query, 0) == transition.slot.hex, sqlite3_column_int64(query, 1) == Int64(transition.ordinal),
                  string(query, 2) == transition.job.uuidString, string(query, 4) == Self.digest(data),
                  let record = graph.records[transition.job] else { throw FileOperationFailure.recoveryUncertain }
            try transition.validate(record: record)
            if let previous = graph.heads[transition.slot] { guard transition.before == previous else { throw FileOperationFailure.recoveryUncertain } }
            else {
                guard transition.ordinal == 0, transition.before.sequence == 0, transition.before.job == nil else { throw FileOperationFailure.recoveryUncertain }
                knownHeads[transition.slot, default: [:]][0] = transition.before
                lineages[transition.slot, default: []].insert(transition.before.lineage)
            }
            switch transition {
            case .native:
                appliedByJob[transition.job, default: 0] += 1
            case .baseline:
                guard !lineages[transition.slot, default: []].contains(transition.after.lineage) else { throw FileOperationFailure.recoveryUncertain }
                lineages[transition.slot, default: []].insert(transition.after.lineage)
                baselinesByJob[transition.job, default: 0] += 1
            }
            knownHeads[transition.slot, default: [:]][transition.after.sequence] = transition.after
            graph.heads[transition.slot] = transition.after; transitions += 1
        }
        for record in graph.records.values {
            if record.manifest.base.sequence > 0 {
                guard knownHeads[record.manifest.slot]?[record.manifest.base.sequence] == record.manifest.base else { throw FileOperationFailure.recoveryUncertain }
            } else { guard record.manifest.base.job == nil else { throw FileOperationFailure.recoveryUncertain } }
            let count = record.events.reduce(0) { count, value in if case .applied = value { count + 1 } else { count } }
            guard appliedByJob[record.id, default: 0] == count else { throw FileOperationFailure.recoveryUncertain }
            guard baselinesByJob[record.id, default: 0] == (record.manifest.baseline == nil ? 0 : 1) else { throw FileOperationFailure.recoveryUncertain }
            if let head = try record.project().retirement?.head {
                guard knownHeads[record.manifest.slot]?[head.sequence] == head else { throw FileOperationFailure.recoveryUncertain }
            }
            let exports = try textExportsV2(record.id)
            for item in exports {
                try validateTextExportV2(item, record: record)
            }
        }
        return graph
    }

    private func legacyTextHead9(slot:RevisionDigest,allowing job:UUID? = nil) throws -> TextRevisionHeadV2? {
        let graph = try legacyTextGraph9()
        for record in graph.records.values where record.manifest.slot == slot && record.id != job {
            guard [.committed,.undone,.notApplied].contains(try record.project().state) else { throw FileOperationFailure.recoveryUncertain }
        }
        return graph.heads[slot]
    }
}
extension SQLiteJournalStore {
    /// Explicit caller action under the original writer lock. Backup is a fresh
    /// private sibling directory with the original owner/tokens and exact DB bytes.
    func upgradeForTextV2(backup: URL, cancellation: OperationCancellation) throws {
        guard [3,4,7].contains(catalogVersion), editCache == nil, groupedEditCache == nil,
              sqlite3_get_autocommit(db) != 0, backup.deletingLastPathComponent() == anchor.url.deletingLastPathComponent() else { throw FileOperationFailure.invalidRequest }
        try validateCatalog(cancellation: cancellation)
        let parent = try DirectoryAnchor(backup.deletingLastPathComponent(), resolve: false)
        try validateName(backup.lastPathComponent)
        guard mkdirat(parent.fd, backup.lastPathComponent, 0o700) == 0 else { throw posixFailure() }
        let target = try DirectoryAnchor(backup, resolve: false)
        for token in [".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2"] {
            try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: token, anchor: target)
        }
        // A recoverable old catalog also needs every imported legacy revision.
        // These are bounded private history metadata, never selected item bodies.
        var legacyBytes = 0, legacyFiles = 0
        for (id, evidence) in try legacyImports().sorted(by: { $0.key < $1.key }) {
            guard UUID(uuidString: id)?.uuidString == id, evidence.revision >= 0, evidence.revision < 16_384 else { throw FileOperationFailure.unsupported }
            for revision in 0...evidence.revision {
                try cancellation.check()
                legacyFiles += 1
                guard legacyFiles <= 16_384 else { throw FileOperationFailure.unsupported }
                let name = "\(id)-\(String(format: "%06d", revision)).json"
                let original = try EntrySnapshot(parent: anchor.fd, name: name)
                guard original.type == S_IFREG else { throw FileOperationFailure.recoveryUncertain }
                let data = try OperationJournal.read(name: name, anchor: anchor)
                legacyBytes += data.count
                guard legacyBytes <= OperationJournal.maximumRecordBytes,
                      try EntrySnapshot(parent: anchor.fd, name: name) == original else { throw FileOperationFailure.sourceChanged }
                try OperationJournal.writeExclusive(data, name: name, anchor: target)
                guard try EntrySnapshot(parent: anchor.fd, name: name) == original,
                      try OperationJournal.read(name: name, anchor: target) == data else { throw FileOperationFailure.sourceChanged }
            }
        }
        let before = try Self.checkedFile(Self.name, anchor: anchor)
        let sourceFD = openat(anchor.fd, Self.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw posixFailure() }; defer { close(sourceFD) }
        let targetFD = openat(target.fd, Self.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard targetFD >= 0 else { throw posixFailure() }; defer { close(targetFD) }
        guard try EntrySnapshot(fd: sourceFD) == before, before.size >= 0, before.size <= Self.maximumStoreBytes else { throw FileOperationFailure.recoveryUncertain }
        var buffer = [UInt8](repeating: 0, count: 16_384), offset: Int64 = 0
        while offset < before.size {
            try cancellation.check()
            let count = pread(sourceFD, &buffer, min(buffer.count, Int(before.size-offset)), off_t(offset))
            guard count > 0 else { throw posixFailure() }
            try buffer.withUnsafeBytes { raw in
                var written = 0
                while written < count {
                    let amount = write(targetFD, raw.baseAddress!.advanced(by: written), count-written)
                    guard amount > 0 else { throw posixFailure() }; written += amount
                }
            }
            offset += Int64(count)
        }
        guard fsync(targetFD) == 0, fcntl(targetFD, F_FULLFSYNC) == 0,
              try EntrySnapshot(fd: sourceFD) == before, try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.recoveryUncertain }
        try syncDirectory(target); try syncDirectory(parent)
        let cold = try SQLiteJournalStore(readOnly: target, owner: owner, budget: OperationHistoryReadBudget(cancellation: cancellation))
        try cold.validateCatalog(cancellation: cancellation)
        guard cold.inspectedCatalogVersion == catalogVersion else { throw FileOperationFailure.recoveryUncertain }
        // Exercise directory-level legacy custody, beyond passive SQLite summaries.
        do {
            let backupJournal = try OperationJournal(backup, cancellation: cancellation)
            try backupJournal.validateWritableCatalog()
            let inspection = try backupJournal.inspectSummaries()
            guard inspection.refused.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        }
        guard try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.sourceChanged }
        try syncDirectory(target); try syncDirectory(parent)
        try transaction {
            if catalogVersion == 3 {
                for sql in Self.groupedSchema { try exec(sql) }
                try eachJobID { id in
                    let record = try loadedRecord(id).record
                    let kind = try OperationCatalogProtocol.ordinary(version: record.version)
                    try run("INSERT INTO job_protocols VALUES (?,?,?)", [.text(id), .text(kind.rawValue), .int(Int64(kind.version))])
                }
            }
            if catalogVersion != 7 { for sql in Self.selectionSchema { try exec(sql) } }
            for sql in Self.textSchemaV2 { try exec(sql) }
            try run("UPDATE metadata SET value='9' WHERE key='version'"); try exec("PRAGMA user_version=9")
            try hooks.beforeCatalogUpgradeCommit?()
        }
        catalogVersion = 9; try hooks.afterCatalogUpgradeCommit?()
    }
}

extension SQLiteJournalStore {
    func upgradeForEpoch10(backup: URL, cancellation: OperationCancellation) throws {
        guard catalogVersion == 9, editCache == nil, groupedEditCache == nil,
              sqlite3_get_autocommit(db) != 0, backup.deletingLastPathComponent() == anchor.url.deletingLastPathComponent() else { throw FileOperationFailure.invalidRequest }
        try validateCatalog(cancellation: cancellation)
        let parent = try DirectoryAnchor(backup.deletingLastPathComponent(), resolve: false)
        try validateName(backup.lastPathComponent)
        guard mkdirat(parent.fd, backup.lastPathComponent, 0o700) == 0 else { throw posixFailure() }
        let target = try DirectoryAnchor(backup, resolve: false)
        for token in [".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2"] {
            try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: token, anchor: target)
        }
        // A recoverable old catalog also needs every imported legacy revision.
        // These are bounded private history metadata, never selected item bodies.
        var legacyBytes = 0, legacyFiles = 0
        for (id, evidence) in try legacyImports().sorted(by: { $0.key < $1.key }) {
            guard UUID(uuidString: id)?.uuidString == id, evidence.revision >= 0, evidence.revision < 16_384 else { throw FileOperationFailure.unsupported }
            for revision in 0...evidence.revision {
                try cancellation.check()
                legacyFiles += 1
                guard legacyFiles <= 16_384 else { throw FileOperationFailure.unsupported }
                let name = "\(id)-\(String(format: "%06d", revision)).json"
                let original = try EntrySnapshot(parent: anchor.fd, name: name)
                guard original.type == S_IFREG else { throw FileOperationFailure.recoveryUncertain }
                let data = try OperationJournal.read(name: name, anchor: anchor)
                legacyBytes += data.count
                guard legacyBytes <= OperationJournal.maximumRecordBytes,
                      try EntrySnapshot(parent: anchor.fd, name: name) == original else { throw FileOperationFailure.sourceChanged }
                try OperationJournal.writeExclusive(data, name: name, anchor: target)
                guard try EntrySnapshot(parent: anchor.fd, name: name) == original,
                      try OperationJournal.read(name: name, anchor: target) == data else { throw FileOperationFailure.sourceChanged }
            }
        }
        let before = try Self.checkedFile(Self.name, anchor: anchor)
        let sourceFD = openat(anchor.fd, Self.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw posixFailure() }; defer { close(sourceFD) }
        let targetFD = openat(target.fd, Self.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard targetFD >= 0 else { throw posixFailure() }; defer { close(targetFD) }
        guard try EntrySnapshot(fd: sourceFD) == before, before.size >= 0, before.size <= Self.maximumStoreBytes else { throw FileOperationFailure.recoveryUncertain }
        var buffer = [UInt8](repeating: 0, count: 16_384), offset: Int64 = 0
        while offset < before.size {
            try cancellation.check()
            let count = pread(sourceFD, &buffer, min(buffer.count, Int(before.size-offset)), off_t(offset))
            guard count > 0 else { throw posixFailure() }
            try buffer.withUnsafeBytes { raw in
                var written = 0
                while written < count {
                    let amount = write(targetFD, raw.baseAddress!.advanced(by: written), count-written)
                    guard amount > 0 else { throw posixFailure() }; written += amount
                }
            }
            offset += Int64(count)
        }
        guard fsync(targetFD) == 0, fcntl(targetFD, F_FULLFSYNC) == 0,
              try EntrySnapshot(fd: sourceFD) == before, try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.recoveryUncertain }
        try syncDirectory(target); try syncDirectory(parent)
        let cold = try SQLiteJournalStore(readOnly: target, owner: owner, budget: OperationHistoryReadBudget(cancellation: cancellation))
        try cold.validateCatalog(cancellation: cancellation)
        guard cold.inspectedCatalogVersion == catalogVersion else { throw FileOperationFailure.recoveryUncertain }
        // Exercise directory-level legacy custody, beyond passive SQLite summaries.
        do {
            let backupJournal = try OperationJournal(backup, cancellation: cancellation)
            try backupJournal.validateWritableCatalog()
            let inspection = try backupJournal.inspectSummaries()
            guard inspection.refused.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        }
        guard try Self.checkedFile(Self.name, anchor: anchor) == before else { throw FileOperationFailure.sourceChanged }
        try syncDirectory(target); try syncDirectory(parent)
        let legacy = try legacyTextGraph9()
        try transaction {
            try exec("ALTER TABLE jobs ADD COLUMN text_slot10 TEXT")
            for sql in Self.epochSchema10 { try exec(sql) }
            let groups = Dictionary(grouping:legacy.records.values,by:{$0.manifest.slot})
            for (key,records) in groups {
                let first = records.sorted{$0.manifest.createdAt<$1.manifest.createdAt}.first!
                let rawEdges = try prepare("SELECT payload,checksum FROM text_revision_heads WHERE slot=? ORDER BY ordinal LIMIT 129",[.text(key.hex)])
                var edges:[TextRevisionHeadEdgeV3] = []
                while sqlite3_step(rawEdges) == SQLITE_ROW {
                    let bytes = try blob(rawEdges,0)
                    guard string(rawEdges,1) == Self.digest(bytes),edges.count<128 else {sqlite3_finalize(rawEdges);throw FileOperationFailure.recoveryUncertain}
                    edges.append(try textDecoded(TextRevisionHeadEdgeV3.self,bytes))
                }
                sqlite3_finalize(rawEdges)
                let root = edges.first?.before ?? first.manifest.baseline?.before ?? first.manifest.base
                let epoch = TextEpoch10(owner:owner,id:UUID(),slot:key,ordinal:0,migratedFrom9:true,importedRecords:records.map(\.id).sorted{$0.uuidString<$1.uuidString},root:root,predecessor:nil,cut:nil)
                var slot = TextSlot10(owner:owner,slot:key,epoch:epoch.id,generation:0,maintenance:0,head:legacy.heads[key] ?? root)
                try writeSlot10(slot);try writeEpoch10(epoch)
                for record in records {
                    try run("UPDATE jobs SET text_slot10=? WHERE id=?",[.text(key.hex),.text(record.id.uuidString)])
                    guard sqlite3_changes(db)==1 else {throw FileOperationFailure.recoveryUncertain}
                    var member = TextMember10(id:record.id,epoch:epoch.id,slot:key,createdAt:record.manifest.createdAt,seal:nil,checkpointID:nil,retirementGuard:nil)
                    if let index = record.events.firstIndex(where:{
                        switch $0 { case .retirementIntent,.retirementIntentRootMetadataV4,
                            .retirementIntentNativeDirectoryV5: true; default: false }
                    }) {
                        let value = TextMutationGuard10(id:UUID(),job:record.id,epoch:epoch.id,slot:key,kind:.retirement,ordinal:0,
                            sourceRevision:index+1,sourcePrefix:try record.prefix(at:index+1),admittedStamp:slot.stamp,maintenanceGeneration:slot.maintenance,
                            outcome:try record.prefix,closed:try record.project().retirementConfirmed)
                        member.retirementGuard=value.id
                        try writeMember10(member);try writeGuard10(value);slot.maintenance += 1
                    } else {try writeMember10(member)}
                    for export in try textExportsV2(record.id) {
                        let value=TextMutationGuard10(id:export.id,job:record.id,epoch:epoch.id,slot:key,kind:.export,ordinal:export.ordinal,
                            sourceRevision:record.revision,sourcePrefix:try record.prefix,admittedStamp:slot.stamp,maintenanceGeneration:slot.maintenance,
                            outcome:.bytes(try textEncoded(export)),closed:export.states == [.verified,.verified])
                        try writeGuard10(value);slot.maintenance += 1
                    }
                }
                for edge in edges {try insertEdge10(edge,epoch:epoch.id)}
                try writeSlot10(slot)
            }
            try run("UPDATE metadata SET value='10' WHERE key='version'");try exec("PRAGMA user_version=10")
            try hooks.beforeCatalogUpgradeCommit?()
        }
        catalogVersion = 10;try hooks.afterCatalogUpgradeCommit?()
    }

    private func validateEpochEnvelope10() throws {
        try validateFiles()
        guard catalogVersion == 10,try integer("PRAGMA user_version") == 10,
              try texts("SELECT value FROM metadata WHERE key='version'") == ["10"],
              try texts("SELECT value FROM metadata WHERE key='owner'") == [owner.uuidString],
              try integer("SELECT count(*) FROM jobs") <= 10_000 else {throw FileOperationFailure.recoveryUncertain}
        try validateRoutingHeaderEnvelope10()
    }
}
// Concatenated into SQLiteJournalStore.swift: one existing connection/lease.
extension SQLiteJournalStore {
    internal var epochCachedRecordCount10:Int {epochGraphCache10.values.reduce(0){$0+$1.records.count}}
    private static let epochSchema10 = [
        "CREATE INDEX jobs_text_slot10 ON jobs(text_slot10,id) WHERE text_slot10 IS NOT NULL",
        "CREATE TABLE text_slots10 (slot TEXT PRIMARY KEY, epoch TEXT NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL)",
        "CREATE TABLE text_epochs10 (slot TEXT NOT NULL REFERENCES text_slots10(slot), epoch TEXT NOT NULL, ordinal INTEGER NOT NULL, checkpoint TEXT UNIQUE, payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(slot,epoch), UNIQUE(slot,ordinal))",
        "CREATE TABLE text_members10 (job TEXT PRIMARY KEY REFERENCES jobs(id), slot TEXT NOT NULL, epoch TEXT NOT NULL, created_at REAL NOT NULL, retirement_guard TEXT, payload BLOB NOT NULL, checksum TEXT NOT NULL, FOREIGN KEY(slot,epoch) REFERENCES text_epochs10(slot,epoch))",
        "CREATE INDEX text_members10_epoch ON text_members10(slot,epoch,job)",
        "CREATE INDEX text_members10_page ON text_members10(slot,created_at DESC,job)",
        "CREATE INDEX text_members10_retirement ON text_members10(slot,retirement_guard)",
        "CREATE TABLE text_epoch_edges10 (slot TEXT NOT NULL, epoch TEXT NOT NULL, ordinal INTEGER NOT NULL, job TEXT NOT NULL REFERENCES text_members10(job), payload BLOB NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(slot,epoch,ordinal), FOREIGN KEY(slot,epoch) REFERENCES text_epochs10(slot,epoch))",
        "CREATE TABLE text_mutation_guards10 (id TEXT PRIMARY KEY, job TEXT NOT NULL REFERENCES text_members10(job), slot TEXT NOT NULL, epoch TEXT NOT NULL, kind TEXT NOT NULL, ordinal INTEGER NOT NULL, closed INTEGER NOT NULL, payload BLOB NOT NULL, checksum TEXT NOT NULL, UNIQUE(job,kind,ordinal), FOREIGN KEY(slot,epoch) REFERENCES text_epochs10(slot,epoch))",
        "CREATE INDEX text_mutation_guards10_slot ON text_mutation_guards10(slot,id)"
    ]
    private struct EpochGraph10 {
        let slot: TextSlot10, epoch: TextEpoch10
        var records: [UUID:TextRevisionRecordV2]
        let edges: [TextRevisionHeadEdgeV3]
    }
    private static func catalogBaseSchema10(_ version:Int64) -> [String] {
        guard version == 10 else {return schema}
        return schema.map {sql in
            if sql.hasPrefix("CREATE TABLE jobs (") {return String(sql.dropLast())+", text_slot10 TEXT)"}
            return sql
        }
    }
    private func epochValue10<T: Codable>(_ type:T.Type, sql:String, bindings:[Value]) throws -> T? {
        let query = try prepare(sql, bindings); defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
        let bytes = try blob(query,0)
        guard string(query,1) == Self.digest(bytes), sqlite3_step(query) == SQLITE_DONE else { throw FileOperationFailure.recoveryUncertain }
        return try textDecoded(type,bytes)
    }
    private func slot10(_ slot:RevisionDigest) throws -> TextSlot10? {
        let value = try epochValue10(TextSlot10.self,sql:"SELECT payload,checksum FROM text_slots10 WHERE slot=?",bindings:[.text(slot.hex)])
        if let value {
            guard value.owner == owner, value.slot == slot, value.generation >= 0, value.maintenance >= 0,
                  value.head.slot == slot, (0...128).contains(value.head.sequence),
                  try texts("SELECT epoch FROM text_slots10 WHERE slot=?",[.text(slot.hex)]) == [value.epoch.uuidString] else { throw FileOperationFailure.recoveryUncertain }
        }
        return value
    }
    private func epoch10(_ slot:RevisionDigest,_ id:UUID,checkingLinks:Bool=true) throws -> TextEpoch10 {
        guard let value = try epochValue10(TextEpoch10.self,sql:"SELECT payload,checksum FROM text_epochs10 WHERE slot=? AND epoch=?",bindings:[.text(slot.hex),.text(id.uuidString)]),
              value.slot == slot, value.id == id, value.owner == owner, value.ordinal >= 0,
              value.root.slot == slot, value.root.job == nil, value.root.sequence == 0 else { throw FileOperationFailure.recoveryUncertain }
        guard !value.migratedFrom9 || value.ordinal == 0 else {throw FileOperationFailure.recoveryUncertain}
        guard value.importedRecords.count <= 64,Set(value.importedRecords).count == value.importedRecords.count,
              value.migratedFrom9 ? !value.importedRecords.isEmpty:value.importedRecords.isEmpty else {throw FileOperationFailure.recoveryUncertain}
        guard try integers("SELECT ordinal FROM text_epochs10 WHERE slot=? AND epoch=? AND coalesce(checkpoint,'')=?",[.text(slot.hex),.text(id.uuidString),.text(value.cut?.id.uuidString ?? "")]) == [Int64(value.ordinal)] else {throw FileOperationFailure.recoveryUncertain}
        if let cut = value.cut { try cut.validate(); guard cut.old.epoch == id,cut.slot == slot,cut.owner == owner else { throw FileOperationFailure.recoveryUncertain } }
        else {guard try slot10(slot)?.epoch == id else {throw FileOperationFailure.recoveryUncertain}}
        if let previous = value.predecessor {
            try previous.validate()
            guard value.ordinal > 0, previous.nextEpoch == id, previous.root == value.root, previous.slot == slot,
                  previous.owner == owner else { throw FileOperationFailure.recoveryUncertain }
        } else { guard value.ordinal == 0 else { throw FileOperationFailure.recoveryUncertain } }
        if checkingLinks {
            if let previous=value.predecessor {
                let prior=try epoch10(slot,previous.old.epoch,checkingLinks:false)
                guard prior.cut == previous,prior.ordinal+1 == value.ordinal else {throw FileOperationFailure.recoveryUncertain}
                let unsealed=TextEpoch10(owner:prior.owner,id:prior.id,slot:prior.slot,ordinal:prior.ordinal,migratedFrom9:prior.migratedFrom9,
                    importedRecords:prior.importedRecords,root:prior.root,predecessor:prior.predecessor,cut:nil)
                guard RevisionDigest.bytes(try textEncoded(unsealed)) == previous.oldEpochDigest else {throw FileOperationFailure.recoveryUncertain}
            }
            if let cut=value.cut {
                let next=try epoch10(slot,cut.nextEpoch,checkingLinks:false)
                guard next.predecessor == cut,next.ordinal == value.ordinal+1,next.root == cut.root else {throw FileOperationFailure.recoveryUncertain}
            }
        }
        return value
    }
    private func member10(_ id:UUID) throws -> TextMember10 {
        guard let value = try epochValue10(TextMember10.self,sql:"SELECT payload,checksum FROM text_members10 WHERE job=?",bindings:[.text(id.uuidString)]),value.id == id else { throw FileOperationFailure.recoveryUncertain }
        guard try texts("SELECT slot FROM text_members10 WHERE job=? AND epoch=? AND created_at=?",[.text(id.uuidString),.text(value.epoch.uuidString),.double(value.createdAt.timeIntervalSinceReferenceDate)]) == [value.slot.hex],
              try texts("SELECT text_slot10 FROM jobs WHERE id=?",[.text(id.uuidString)]) == [value.slot.hex],
              try texts("SELECT coalesce(retirement_guard,'') FROM text_members10 WHERE job=?",[.text(id.uuidString)]) == [value.retirementGuard?.uuidString ?? ""] else { throw FileOperationFailure.recoveryUncertain }
        return value
    }
    private func writeSlot10(_ value:TextSlot10) throws {
        let bytes = try encode(value)
        try run("INSERT INTO text_slots10 VALUES (?,?,?,?) ON CONFLICT(slot) DO UPDATE SET epoch=excluded.epoch,payload=excluded.payload,checksum=excluded.checksum",[.text(value.slot.hex),.text(value.epoch.uuidString),.blob(bytes),.text(Self.digest(bytes))])
    }
    private func writeEpoch10(_ value:TextEpoch10) throws {
        let bytes = try encode(value)
        try run("INSERT INTO text_epochs10 VALUES (?,?,?,?,?,?) ON CONFLICT(slot,epoch) DO UPDATE SET checkpoint=excluded.checkpoint,payload=excluded.payload,checksum=excluded.checksum",[.text(value.slot.hex),.text(value.id.uuidString),.int(Int64(value.ordinal)),value.cut.map{.text($0.id.uuidString)} ?? .null,.blob(bytes),.text(Self.digest(bytes))])
    }
    private func writeMember10(_ value:TextMember10) throws {
        let bytes = try encode(value)
        try run("INSERT INTO text_members10 VALUES (?,?,?,?,?,?,?) ON CONFLICT(job) DO UPDATE SET retirement_guard=excluded.retirement_guard,payload=excluded.payload,checksum=excluded.checksum",[.text(value.id.uuidString),.text(value.slot.hex),.text(value.epoch.uuidString),.double(value.createdAt.timeIntervalSinceReferenceDate),.text(value.retirementGuard?.uuidString ?? ""),.blob(bytes),.text(Self.digest(bytes))])
    }
    private func writeGuard10(_ value:TextMutationGuard10) throws {
        let bytes = try encode(value)
        try run("INSERT INTO text_mutation_guards10 VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET closed=excluded.closed,payload=excluded.payload,checksum=excluded.checksum",[.text(value.id.uuidString),.text(value.job.uuidString),.text(value.slot.hex),.text(value.epoch.uuidString),.text(value.kind.rawValue),.int(Int64(value.ordinal)),.int(value.closed ? 1:0),.blob(bytes),.text(Self.digest(bytes))])
    }
    private func guard10(_ id:UUID) throws -> TextMutationGuard10 {
        guard let value = try epochValue10(TextMutationGuard10.self,sql:"SELECT payload,checksum FROM text_mutation_guards10 WHERE id=?",bindings:[.text(id.uuidString)]),value.id == id,
              try integers("SELECT count(*) FROM text_mutation_guards10 WHERE id=? AND job=? AND slot=? AND epoch=? AND kind=? AND ordinal=? AND closed=?",[.text(id.uuidString),.text(value.job.uuidString),.text(value.slot.hex),.text(value.epoch.uuidString),.text(value.kind.rawValue),.int(Int64(value.ordinal)),.int(value.closed ? 1:0)]) == [1] else { throw FileOperationFailure.recoveryUncertain }
        guard (1...33).contains(value.sourceRevision),value.admittedStamp.generation >= 0,value.maintenanceGeneration >= 0,
              value.kind == .export ? (0..<10_000).contains(value.ordinal):value.ordinal == 0 else {throw FileOperationFailure.recoveryUncertain}
        return value
    }
    private func validateMember10(_ record:TextRevisionRecordV2) throws -> TextMember10 {
        let member = try member10(record.id), epoch = try epoch10(member.slot,member.epoch)
        guard member.slot == record.manifest.slot, member.createdAt == record.manifest.createdAt else { throw FileOperationFailure.recoveryUncertain }
        if let cut = epoch.cut {
            guard let seal = member.seal, member.checkpointID == cut.id,
                  cut.members.contains(seal), seal.id == record.id, seal.revision <= record.revision,
                  try record.prefix(at:seal.revision) == seal.prefix else { throw FileOperationFailure.recoveryUncertain }
            // Seal the ENTIRE durable prefix. Only the existing bounded retirement
            // suffix may advance after closure; no later native event is legal.
            for event in record.events.dropFirst(seal.revision-1) {
                switch event { case .retirementIntent,.retirementIntentRootMetadataV4,
                    .retirementIntentNativeDirectoryV5,.retirementReturned,
                    .retirementConfirmed,.retirementConfirmedRootMetadataV4,
                    .retirementConfirmedNativeDirectoryV5: break
                default: throw FileOperationFailure.recoveryUncertain }
            }
            let atCut = TextRevisionRecordV2(manifest:record.manifest,events:Array(record.events.prefix(seal.revision-1)))
            guard try atCut.project().state == seal.state else { throw FileOperationFailure.recoveryUncertain }
        } else { guard member.seal == nil,member.checkpointID == nil else { throw FileOperationFailure.recoveryUncertain } }
        let state = try record.project()
        // An archived selected record still proves each of its own native/base
        // links on access. Other archived jobs are decoded only for a referenced
        // complete head, or by explicit full audit.
        if epoch.cut != nil {
            let query = try prepare("SELECT ordinal,payload,checksum FROM text_epoch_edges10 WHERE job=? ORDER BY ordinal LIMIT 4",[.text(record.id.uuidString)])
            defer {sqlite3_finalize(query)}
            var applied=0,baselines=0,seen=0
            while true {
                let status=sqlite3_step(query);if status == SQLITE_DONE {break}
                guard status == SQLITE_ROW,seen<3 else {throw FileOperationFailure.recoveryUncertain}
                seen += 1
                let bytes=try blob(query,1),edge=try textDecoded(TextRevisionHeadEdgeV3.self,bytes)
                guard string(query,2) == Self.digest(bytes),Int(sqlite3_column_int64(query,0)) == edge.ordinal,
                      try integers("SELECT count(*) FROM text_epoch_edges10 WHERE job=? AND slot=? AND epoch=? AND ordinal=?",[.text(record.id.uuidString),.text(member.slot.hex),.text(member.epoch.uuidString),.int(Int64(edge.ordinal))]) == [1] else {throw FileOperationFailure.recoveryUncertain}
                try edge.validate(record:record)
                switch edge {case .native:applied += 1;case .baseline:baselines += 1}
            }
            guard applied == record.events.filter({if case .applied = $0{return true};return false}).count,
                  baselines == (record.manifest.baseline == nil ? 0:1) else {throw FileOperationFailure.recoveryUncertain}
            if !legacyPreparationRoot10(record,epoch:epoch) {try validateHeadReference10(.init(epoch:member.epoch,head:record.manifest.base),slot:member.slot)}
        }
        if let retirement = state.retirement {
            if let seal = member.seal,record.events.dropFirst(seal.revision-1).contains(where:{
                switch $0 { case .retirementIntent,.retirementIntentRootMetadataV4,
                    .retirementIntentNativeDirectoryV5: true; default: false }
            }) {
                guard retirement.headEpoch != nil else {throw FileOperationFailure.recoveryUncertain}
            }
            guard let id = member.retirementGuard else { throw FileOperationFailure.recoveryUncertain }
            let guardValue = try guard10(id)
            guard guardValue.kind == .retirement,guardValue.job == record.id,guardValue.epoch == member.epoch,
                  guardValue.slot == member.slot,guardValue.outcome == (try record.prefix),
                  guardValue.closed == state.retirementConfirmed,
                  guardValue.sourceRevision < record.revision,
                  try record.prefix(at:guardValue.sourceRevision) == guardValue.sourcePrefix else { throw FileOperationFailure.recoveryUncertain }
            guard guardValue.admittedStamp.epoch == (retirement.headEpoch ?? member.epoch) else {throw FileOperationFailure.recoveryUncertain}
            if let head = retirement.head {
                let reference = TextHeadReference10(epoch:retirement.headEpoch ?? member.epoch,head:head)
                if retirement.headEpoch == nil { guard epoch.ordinal == 0 else { throw FileOperationFailure.recoveryUncertain } }
                try validateHeadReference10(reference,slot:member.slot)
            }
        } else { guard member.retirementGuard == nil else { throw FileOperationFailure.recoveryUncertain } }
        return member
    }
    private func validateHeadReference10(_ reference:TextHeadReference10,slot:RevisionDigest) throws {
        let epoch = try epoch10(slot,reference.epoch)
        if reference.head == epoch.root { return }
        guard reference.head.slot == slot, reference.head.sequence > 0,
              let edge = try epochValue10(TextRevisionHeadEdgeV3.self,sql:"SELECT payload,checksum FROM text_epoch_edges10 WHERE slot=? AND epoch=? AND ordinal=?",bindings:[.text(slot.hex),.text(reference.epoch.uuidString),.int(Int64(reference.head.sequence-1))]),edge.after == reference.head else { throw FileOperationFailure.recoveryUncertain }
        let record = try loadedTextRevisionV2(edge.job.uuidString),member = try member10(record.id)
        guard member.epoch == reference.epoch,member.slot == slot else { throw FileOperationFailure.recoveryUncertain }
        try edge.validate(record:record)
        if let seal = member.seal {
            guard try record.prefix(at:seal.revision) == seal.prefix else { throw FileOperationFailure.recoveryUncertain }
            for event in record.events.dropFirst(seal.revision-1) {
                switch event { case .retirementIntent,.retirementIntentRootMetadataV4,
                    .retirementIntentNativeDirectoryV5,.retirementReturned,
                    .retirementConfirmed,.retirementConfirmedRootMetadataV4,
                    .retirementConfirmedNativeDirectoryV5: break
                default: throw FileOperationFailure.recoveryUncertain }
            }
        }
    }
    private func legacyPreparationRoot10(_ record:TextRevisionRecordV2,epoch:TextEpoch10) -> Bool {
        epoch.migratedFrom9 && epoch.ordinal == 0 && epoch.importedRecords.contains(record.id) && record.manifest.baseline == nil
            && record.manifest.base.sequence == 0 && record.manifest.base.job == nil
            && !record.events.contains(where:{if case .applied = $0{return true};return false})
    }
    private func graph10(_ key:RevisionDigest) throws -> EpochGraph10? {
        guard catalogVersion == 10 else { throw LocalTextCapacityReason.upgradeRequired }
        // Membership is a bidirectional selected-scope fact, including when no
        // slot/member appears present. A missing index cannot hide native intent.
        try validateSelectedScopeRelations10(key)
        let dataVersion=try integer("PRAGMA data_version")
        if epochCacheDataVersion10 != dataVersion {
            try validateRoutingHeaderEnvelope10();epochGraphCache10.removeAll();epochCacheDataVersion10=dataVersion
        }
        if let cached=epochGraphCache10[key] {return cached}
        guard let slot = try slot10(key) else {
            guard try integers("SELECT count(*) FROM text_members10 WHERE slot=?",[.text(key.hex)]) == [0],
                  try integers("SELECT count(*) FROM text_epochs10 WHERE slot=?",[.text(key.hex)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
            return nil
        }
        let epoch = try epoch10(key,slot.epoch)
        guard epoch.cut == nil,try texts("SELECT epoch FROM text_slots10 WHERE slot=?",[.text(key.hex)]) == [epoch.id.uuidString],
              try integers("SELECT count(*) FROM text_epochs10 WHERE slot=? AND ordinal>?",[.text(key.hex),.int(Int64(epoch.ordinal))]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        if let previous = epoch.predecessor {
            let prior = try epoch10(key,previous.old.epoch)
            guard prior.cut == previous,prior.ordinal+1 == epoch.ordinal else { throw FileOperationFailure.recoveryUncertain }
            let unsealed = TextEpoch10(owner:prior.owner,id:prior.id,slot:prior.slot,ordinal:prior.ordinal,migratedFrom9:prior.migratedFrom9,importedRecords:prior.importedRecords,root:prior.root,predecessor:prior.predecessor,cut:nil)
            guard RevisionDigest.bytes(try textEncoded(unsealed)) == previous.oldEpochDigest else { throw FileOperationFailure.recoveryUncertain }
        }
        let ids = try texts("SELECT job FROM text_members10 WHERE slot=? AND epoch=? ORDER BY job LIMIT 65",[.text(key.hex),.text(epoch.id.uuidString)])
        guard ids.count <= 64 else { throw FileOperationFailure.recoveryUncertain }
        var records:[UUID:TextRevisionRecordV2] = [:]
        for id in ids {
            let value = try loadedTextRevisionV2(id);_ = try validateMember10(value);records[value.id] = value
        }
        let query = try prepare("SELECT ordinal,job,payload,checksum FROM text_epoch_edges10 WHERE slot=? AND epoch=? ORDER BY ordinal LIMIT 129",[.text(key.hex),.text(epoch.id.uuidString)])
        defer { sqlite3_finalize(query) }
        var edges:[TextRevisionHeadEdgeV3] = [],head = epoch.root,known = [0:epoch.root]
        var applied:[UUID:Int] = [:],baselines:[UUID:Int] = [:],lineages:Set<UUID> = [head.lineage]
        while true {
            let status = sqlite3_step(query);if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,edges.count < 128 else { throw FileOperationFailure.recoveryUncertain }
            let data = try blob(query,2),edge = try textDecoded(TextRevisionHeadEdgeV3.self,data)
            guard string(query,3) == Self.digest(data),Int(sqlite3_column_int64(query,0)) == edges.count,
                  string(query,1) == edge.job.uuidString,edge.ordinal == edges.count,edge.before == head,
                  let record = records[edge.job] else { throw FileOperationFailure.recoveryUncertain }
            try edge.validate(record:record)
            switch edge { case .native: applied[edge.job,default:0] += 1
            case .baseline:
                guard lineages.insert(edge.after.lineage).inserted else { throw FileOperationFailure.recoveryUncertain }
                baselines[edge.job,default:0] += 1 }
            head = edge.after;known[head.sequence] = head;edges.append(edge)
        }
        guard head == slot.head else { throw FileOperationFailure.recoveryUncertain }
        for record in records.values {
            guard known[record.manifest.base.sequence] == record.manifest.base || legacyPreparationRoot10(record,epoch:epoch),
                  applied[record.id,default:0] == record.events.filter({if case .applied = $0{return true};return false}).count,
                  baselines[record.id,default:0] == (record.manifest.baseline == nil ? 0:1) else { throw FileOperationFailure.recoveryUncertain }
        }
        let result=EpochGraph10(slot:slot,epoch:epoch,records:records,edges:edges)
        epochGraphCache10.removeAll(keepingCapacity:true);epochGraphCache10[key]=result
        hooks.metrics?.maximum(.epochPeakCachedRecords,epochCachedRecordCount10);return result
    }
    private func updateGraphCache10(slot:TextSlot10,record:TextRevisionRecordV2?=nil,edge:TextRevisionHeadEdgeV3?=nil,newEpoch:TextEpoch10?=nil,admittingNewRecord:Bool=false) {
        if let previous=epochGraphCache10[slot.slot],previous.epoch.id == slot.epoch {
            var records=previous.records;if let record,records[record.id] != nil || edge != nil || admittingNewRecord {records[record.id]=record}
            epochGraphCache10[slot.slot] = .init(slot:slot,epoch:previous.epoch,records:records,edges:previous.edges+[edge].compactMap{$0})
        } else if let newEpoch,let record,newEpoch.id == slot.epoch {
            epochGraphCache10.removeAll(keepingCapacity:true)
            epochGraphCache10[slot.slot] = .init(slot:slot,epoch:newEpoch,records:[record.id:record],edges:[edge].compactMap{$0})
        } else {epochGraphCache10.removeValue(forKey:slot.slot)}
        hooks.metrics?.maximum(.epochPeakCachedRecords,epochCachedRecordCount10)
    }
    func textHeadV2(slot:RevisionDigest,allowing job:UUID? = nil) throws -> TextRevisionHeadV2? {
        if catalogVersion == 9 { return try legacyTextHead9(slot:slot,allowing:job) }
        guard let graph = try graph10(slot) else { return nil }
        for record in graph.records.values where record.id != job {
            guard [.committed,.undone,.notApplied].contains(try record.project().state) else { throw FileOperationFailure.recoveryUncertain }
        }
        return graph.slot.head
    }
    func textSavePlanningV3(slot:RevisionDigest) throws -> TextPlanning10 {
        let storeRefusal=try storeAdmissionReason10(estimatedBytes:1_048_576,newJob:true)
        guard let graph = try graph10(slot) else { return .init(head:nil,settlements:[],stamp:nil,maintenance:0,records:0,edges:0,storeRefusal:storeRefusal) }
        var settlements:[TextPreparationSettlementV3] = []
        for record in graph.records.values {
            let value = try record.project()
            if [.committed,.undone,.notApplied].contains(value.state) { continue }
            guard [.preparing,.prepared,.undoPrepared].contains(value.state),value.intent == nil,
                  record.events.count < TextRevisionRecordV2.maximumEvents else { throw LocalTextCapacityReason.unknownNativePrefix }
            settlements.append(.init(id:record.id,prefix:try record.prefix))
        }
        return .init(head:graph.slot.head,settlements:settlements.sorted{$0.id.uuidString<$1.id.uuidString},stamp:graph.slot.stamp,
                     maintenance:graph.slot.maintenance,records:graph.records.count,edges:graph.edges.count,storeRefusal:storeRefusal)
    }
    /// Path rows are only a conflict fence. The selected graph, original
    /// parent identity, current device and descriptor-qualified UUID must all
    /// agree before a v3 slot can continue under its existing strict rules.
    func textSelectedSlotV4(target: URL, parent: EntrySnapshot, witness: RevisionWitness) throws -> TextSlotSelectionV4 {
        guard target.isFileURL, target == target.standardizedFileURL else { throw FileOperationFailure.invalidRequest }
        let stable = try textRevisionSlotV4(target: target, parent: parent, volume: witness.volume)
        let older = try textRevisionSlotV2(target: target, parent: parent)
        let rows = try texts("SELECT coalesce(j.text_slot10,'') FROM jobs j JOIN job_protocols p ON p.job=j.id WHERE p.kind='textRevisionV3' AND json_extract(CAST(j.head AS TEXT),'$.manifest.version')=3 AND json_extract(CAST(j.head AS TEXT),'$.manifest.target')=? ORDER BY j.id",
            [.text(target.absoluteString)])
        guard !rows.isEmpty else { return .init(slot: stable, manifestVersion: 4) }
        guard catalogVersion == 10, rows.allSatisfy({ $0 == older.hex }),
              try graph10(stable) == nil, let graph = try graph10(older),
              graph.slot.head.witness.device == witness.device,
              graph.slot.head.witness.volume == witness.volume,
              try graph.records.values.allSatisfy({ record in
                  let state = try record.project().state
                  return record.manifest.version == 3 && record.manifest.target == target &&
                      record.manifest.parent.sameObject(as: parent) && record.manifest.read.volume == witness.volume &&
                      record.manifest.read.device == witness.device &&
                      [.committed, .undone, .notApplied, .preparing, .prepared, .undoPrepared].contains(state)
              }) else { throw FileOperationFailure.legacyTextHistoryRequiresReview }
        return .init(slot: older, manifestVersion: 3)
    }
    private func storeAdmissionReason10(estimatedBytes:Int,newJob:Bool) throws -> LocalTextCapacityReason? {
        if newJob,try integer("SELECT count(*) FROM jobs") >= 10_000 {return .storeCapacity}
        do {try reserve(estimatedBytes:estimatedBytes);return nil}
        catch let failure as FileOperationFailure where [.unsupported,.outOfSpace,.quotaExceeded].contains(failure) {return .storeCapacity}
    }
    func requireTextPublication10() throws {
        guard catalogVersion == 10 else {throw LocalTextCapacityReason.upgradeRequired}
        if let reason=try storeAdmissionReason10(estimatedBytes:1_048_576,newJob:true) {throw reason}
    }
    func textRecordV2(_ id:UUID) throws -> TextRevisionRecordV2 {
        let value = try loadedTextRevisionV2(id.uuidString)
        if catalogVersion == 10 {_ = try validateMember10(value)}
        return value
    }
    func textUndoDisposition10(_ id:UUID) throws -> LocalTextUndoDisposition {
        let record = try textRecordV2(id)
        if catalogVersion == 10,let checkpoint = try member10(id).checkpointID { return .endedByCheckpoint(checkpointID:checkpoint) }
        let state = try record.project()
        if state.retirement != nil { return .endedByRetirement }
        guard state.canPrepareInverse else {return .unavailable}
        if catalogVersion == 10 {
            guard let graph=try graph10(record.manifest.slot),graph.slot.head.job == id,
                  try graph.records.values.allSatisfy({[.committed,.undone,.notApplied].contains(try $0.project().state)}) else {return .unavailable}
            if graph.edges.count >= 128 {return .epochCapacityReached}
        }
        return .available
    }
    func textStamp10(slot:RevisionDigest) throws -> TextEpochStamp10? { try slot10(slot)?.stamp }
    func reserveTextV2(slot:RevisionDigest,newJob:Bool = true,edges:Int = 1) throws {
        try validateWriteCatalog(cancellation:OperationCancellation())
        guard catalogVersion == 10,!isReadOnlyInspection else { throw LocalTextCapacityReason.upgradeRequired }
        let graph = try graph10(slot)
        guard try integer("SELECT count(*) FROM jobs") <= (newJob ? 9_999:10_000) else { throw LocalTextCapacityReason.storeCapacity }
        if newJob && (graph?.records.count ?? 0) >= 64 || (graph?.edges.count ?? 0)+edges > 128 { throw LocalTextCapacityReason.checkpointRequired }
        try reserve(estimatedBytes:1_048_576)
    }
    private func writeTextRecord10(_ old:TextRevisionRecordV2,_ value:TextRevisionRecordV2,event:TextRevisionEventV2) throws {
        let oldHead = try encode(old),head = try encode(value),row = try encode(event)
        guard try texts("SELECT checksum FROM jobs WHERE id=? AND revision=?",[.text(old.id.uuidString),.int(Int64(old.revision))]) == [Self.digest(oldHead)] else { throw FileOperationFailure.sourceChanged }
        try run("INSERT INTO text_revision_events VALUES (?,?,?,?)",[.text(old.id.uuidString),.int(Int64(old.events.count)),.blob(row),.text(Self.digest(row))])
        try run("UPDATE jobs SET revision=?,state=?,head=?,checksum=?,bytes=bytes+? WHERE id=? AND revision=?",[.int(Int64(value.revision)),.text(try value.project().state.rawValue),.blob(head),.text(Self.digest(head)),.int(Int64(head.count-oldHead.count+row.count)),.text(value.id.uuidString),.int(Int64(old.revision))])
        guard sqlite3_changes(db) == 1 else { throw FileOperationFailure.recoveryUncertain }
        try run("INSERT INTO events VALUES (?,?,?)",[.text(value.id.uuidString),.int(Int64(value.revision)),.text(try value.project().state.rawValue)])
    }
    private func insertEdge10(_ edge:TextRevisionHeadEdgeV3,epoch:UUID) throws {
        let bytes = try encode(edge)
        try run("INSERT INTO text_epoch_edges10 VALUES (?,?,?,?,?,?)",[.text(edge.slot.hex),.text(epoch.uuidString),.int(Int64(edge.ordinal)),.text(edge.job.uuidString),.blob(bytes),.text(Self.digest(bytes))])
    }
    func beginTextV2(_ manifest:TextRevisionManifestV2) throws -> TextRevisionRecordV2 {
        observingTextRecordStart = true
        defer { observingTextRecordStart = false }
        do {
            try reserveTextV2(slot:manifest.slot,edges:manifest.baseline == nil ? 1:2)
            guard manifest.owner == owner,try integers("SELECT count(*) FROM jobs WHERE id=?",[.text(manifest.id.uuidString)]) == [0] else { throw FileOperationFailure.invalidRequest }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textRecordAdmission, error)
            throw error
        }
        let record = TextRevisionRecordV2(manifest:manifest,events:[])
        let initialPrefix: RevisionDigest, bytes: Data
        do {
            _ = try record.project(); initialPrefix = try record.prefix; bytes = try encode(record)
        } catch {
            FileOperationDiagnostics.caughtFailure(.textRecordProjection, error)
            throw error
        }
        let expected = manifest.baseline?.before ?? manifest.base
        var slot: TextSlot10?
        do {
            slot = try slot10(manifest.slot)
            guard slot?.head ?? expected == expected else { throw FileOperationFailure.sourceChanged }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textRecordHead, error)
            throw error
        }
        let newEpoch = TextEpoch10(owner:owner,id:UUID(),slot:manifest.slot,ordinal:0,migratedFrom9:false,importedRecords:[],root:expected,predecessor:nil,cut:nil)
        do { try transaction {
            if slot == nil {
                slot = TextSlot10(owner:owner,slot:manifest.slot,epoch:newEpoch.id,generation:0,maintenance:0,head:expected)
                try writeSlot10(slot!);try writeEpoch10(newEpoch)
            }
            guard var current = slot else { throw FileOperationFailure.recoveryUncertain }
            try run("INSERT INTO jobs (id,revision,created_at,state,head,checksum,bytes,text_slot10) VALUES (?,1,?,?,?,?,?,?)",[.text(record.id.uuidString),.double(manifest.createdAt.timeIntervalSinceReferenceDate),.text("preparing"),.blob(bytes),.text(Self.digest(bytes)),.int(Int64(bytes.count)),.text(manifest.slot.hex)])
            try run("INSERT INTO job_protocols VALUES (?,'textRevisionV3',3)",[.text(record.id.uuidString)])
            try run("INSERT INTO events VALUES (?,1,'preparing')",[.text(record.id.uuidString)])
            try writeMember10(.init(id:record.id,epoch:current.epoch,slot:manifest.slot,createdAt:manifest.createdAt,seal:nil,checkpointID:nil,retirementGuard:nil))
            if let baseline = manifest.baseline {
                let edge = TextRevisionHeadEdgeV3.baseline(job:record.id,prefix:try record.prefix,change:baseline)
                try edge.validate(record:record);try insertEdge10(edge,epoch:current.epoch);current.head = edge.after
            }
            current.generation += 1;try writeSlot10(current);slot=current
            try hooks.beforeSaveCommit?()
        } } catch {
            FileOperationDiagnostics.caughtFailure(.textRecordTransaction, error)
            throw error
        }
        if let slot {updateGraphCache10(slot:slot,record:record,edge:manifest.baseline.map{.baseline(job:record.id,prefix:initialPrefix,change:$0)},newEpoch:newEpoch,admittingNewRecord:true)}
        try hooks.afterSaveCommit?();return record
    }
    func appendTextV2(_ old:TextRevisionRecordV2,event:TextRevisionEventV2,transition:TextRevisionTransitionV2? = nil) throws -> TextRevisionRecordV2 {
        try validateWriteCatalog(cancellation:OperationCancellation())
        guard try textRecordV2(old.id) == old,var slot = try slot10(old.manifest.slot) else { throw FileOperationFailure.sourceChanged }
        var member = try member10(old.id)
        let value = try old.appending(event)
        var retirement = false
        switch event { case .retirementIntent,.retirementIntentRootMetadataV4,
            .retirementIntentNativeDirectoryV5,.retirementReturned,
            .retirementConfirmed,.retirementConfirmedRootMetadataV4,
            .retirementConfirmedNativeDirectoryV5: retirement = true
        default:guard member.epoch == slot.epoch,member.checkpointID == nil else { throw FileOperationFailure.undoEndedByCheckpoint } }
        if case .applied = event {
            guard let transition,transition.before == slot.head,transition.ordinal < 128 else { throw FileOperationFailure.sourceChanged }
            try transition.validate(record:value)
        } else if transition != nil { throw FileOperationFailure.invalidRequest }
        var mutation:TextMutationGuard10?
        if retirement {
            let retirementIntent:TextRetirementIntentV3? = switch event {
            case .retirementIntent(let intent), .retirementIntentRootMetadataV4(let intent),
                 .retirementIntentNativeDirectoryV5(let intent): intent
            default: nil
            }
            if let intent = retirementIntent {
                try admitGuard10(slot:member.slot)
                guard intent.head == slot.head,intent.headEpoch == slot.epoch else { throw FileOperationFailure.sourceChanged }
                mutation = .init(id:UUID(),job:old.id,epoch:member.epoch,slot:member.slot,kind:.retirement,ordinal:0,sourceRevision:old.revision,sourcePrefix:try old.prefix,
                    admittedStamp:slot.stamp,maintenanceGeneration:slot.maintenance,outcome:try value.prefix,closed:false)
                member.retirementGuard = mutation!.id
            } else {
                guard let id = member.retirementGuard else { throw FileOperationFailure.recoveryUncertain }
                var current = try guard10(id);current.outcome = try value.prefix;current.closed = try value.project().retirementConfirmed;mutation = current
            }
        }
        try transaction {
            try writeTextRecord10(old,value,event:event)
            if let transition { try insertEdge10(.native(transition),epoch:member.epoch);slot.head = transition.after }
            if let mutation { try writeGuard10(mutation);try writeMember10(member);slot.maintenance += 1 }
            else { slot.generation += 1 }
            try writeSlot10(slot);try hooks.beforeSaveCommit?()
        }
        updateGraphCache10(slot:slot,record:value,edge:transition.map{.native($0)})
        try hooks.afterSaveCommit?();return value
    }
    private func admitGuard10(slot:RevisionDigest) throws {
        guard try integer("SELECT count(*) FROM text_mutation_guards10") < 20_000,
              try integers("SELECT count(*) FROM text_mutation_guards10 WHERE slot=? AND closed=0",[.text(slot.hex)]).first! < 64 else { throw LocalTextCapacityReason.storeCapacity }
    }
}

// Same-file storage extension, appended after EpochStorage.swift.
extension SQLiteJournalStore {
    func textDocumentRevisionsV3(slot:RevisionDigest,after:UUID?,limit:Int)
        throws -> (records:[TextRevisionRecordV2],head:TextRevisionHeadV2?,next:UUID?) {
        guard catalogVersion == 10,(1...64).contains(limit) else { throw FileOperationFailure.invalidRequest }
        var bindings:[Value] = [.text(slot.hex)]
        var condition = ""
        if let after {
            let member = try member10(after)
            guard member.slot == slot else { throw FileOperationFailure.invalidRequest }
            condition = " AND (created_at<? OR (created_at=? AND job>?))"
            bindings += [.double(member.createdAt.timeIntervalSinceReferenceDate),.double(member.createdAt.timeIntervalSinceReferenceDate),.text(after.uuidString)]
        }
        let ids = try texts("SELECT job FROM text_members10 WHERE slot=?"+condition+" ORDER BY created_at DESC,job LIMIT \(limit+1)",bindings)
        let page = try ids.prefix(limit).map { try textRecordV2(UUID(uuidString:$0)!) }
        return (page,try slot10(slot)?.head,ids.count > limit ? page.last?.id:nil)
    }
    func textExportsV2(_ id:UUID,after:Int? = nil,limit:Int = 64) throws -> [TextRecoveryExportV2] {
        guard (1...64).contains(limit) else { throw FileOperationFailure.invalidRequest }
        let query = try prepare("SELECT ordinal,payload,checksum FROM text_revision_exports WHERE job=? AND ordinal>? ORDER BY ordinal LIMIT \(limit)",[.text(id.uuidString),.int(Int64(after ?? -1))])
        defer { sqlite3_finalize(query) }
        let record = try loadedTextRevisionV2(id.uuidString)
        var result:[TextRecoveryExportV2] = []
        while true {
            let status = sqlite3_step(query);if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw FileOperationFailure.recoveryUncertain }
            let bytes = try blob(query,1),value = try textDecoded(TextRecoveryExportV2.self,bytes)
            guard value.job == id,value.ordinal == Int(sqlite3_column_int64(query,0)),string(query,2) == Self.digest(bytes) else { throw FileOperationFailure.recoveryUncertain }
            try validateTextExportV2(value,record:record)
            if catalogVersion == 10 {
                let member = try member10(id),guardValue = try guard10(value.id)
                guard guardValue.job == id,guardValue.epoch == member.epoch,guardValue.slot == member.slot,
                      guardValue.kind == .export,guardValue.ordinal == value.ordinal,
                      guardValue.outcome == RevisionDigest.bytes(bytes),
                      guardValue.sourceRevision <= record.revision,
                      try record.prefix(at:guardValue.sourceRevision) == guardValue.sourcePrefix,
                      guardValue.closed == (value.states == [.verified,.verified] || guardValue.remainingAbortedBeforeNative),
                      !guardValue.remainingAbortedBeforeNative || (!value.states.contains(.publicationUnconfirmed) && value.states.contains(.notAttempted)) else { throw FileOperationFailure.recoveryUncertain }
            }
            result.append(value)
        }
        return result
    }
    func textNextExportOrdinal10(_ id:UUID) throws -> Int {
        guard catalogVersion == 10,try integer("SELECT count(*) FROM text_revision_exports") < 10_000 else { throw LocalTextCapacityReason.storeCapacity }
        let count = try integers("SELECT count(*) FROM text_revision_exports WHERE job=?",[.text(id.uuidString)])[0]
        if count > 0 { guard try integers("SELECT max(ordinal) FROM text_revision_exports WHERE job=?",[.text(id.uuidString)]) == [count-1] else { throw FileOperationFailure.recoveryUncertain } }
        return Int(count)
    }
    func writeTextExportV2(_ value:TextRecoveryExportV2,replacing old:TextRecoveryExportV2?) throws {
        try validateWriteCatalog(cancellation:OperationCancellation());try value.validate()
        let record = try textRecordV2(value.job),member = try member10(value.job)
        guard var slot = try slot10(member.slot) else { throw FileOperationFailure.recoveryUncertain }
        try validateTextExportV2(value,record:record)
        var guardValue:TextMutationGuard10
        if let old {
            guard try textExportsV2(value.job,after:value.ordinal-1,limit:1).first == old,
                  value.id == old.id,value.names == old.names,value.expected == old.expected,
                  value.attemptID == old.attemptID,value.direction == old.direction,
                  value.destination == old.destination,value.parent == old.parent,value.sources == old.sources,
                  value.states != old.states else { throw FileOperationFailure.sourceChanged }
            let changed = value.states.indices.filter{value.states[$0] != old.states[$0]}
            guard changed.count == 1,let index = changed.first else { throw FileOperationFailure.sourceChanged }
            if old.states[index] == .notAttempted {
                guard value.states[index] == .publicationUnconfirmed,value.completed == old.completed else { throw FileOperationFailure.sourceChanged }
            } else {
                guard old.states[index] == .publicationUnconfirmed,value.states[index] == .verified,
                      value.completed.count == old.completed.count+1,Array(value.completed.dropLast()) == old.completed else { throw FileOperationFailure.sourceChanged }
            }
            guardValue = try guard10(value.id)
            guard !guardValue.closed,!guardValue.remainingAbortedBeforeNative else { throw FileOperationFailure.sourceChanged }
            guardValue.outcome = .bytes(try textEncoded(value));guardValue.closed = value.states == [.verified,.verified]
        } else {
            guard value.ordinal == (try textNextExportOrdinal10(value.job)),value.completed.isEmpty,
                  value.states == [.notAttempted,.notAttempted] else { throw FileOperationFailure.invalidRequest }
            try admitGuard10(slot:member.slot)
            guardValue = .init(id:value.id,job:value.job,epoch:member.epoch,slot:member.slot,kind:.export,ordinal:value.ordinal,
                               sourceRevision:record.revision,sourcePrefix:try record.prefix,admittedStamp:slot.stamp,
                               maintenanceGeneration:slot.maintenance,outcome:.bytes(try textEncoded(value)),closed:false)
        }
        try reserve(estimatedBytes:131_072)
        let bytes = try encode(value)
        try transaction {
            try run("INSERT INTO text_revision_exports VALUES (?,?,?,?) ON CONFLICT(job,ordinal) DO UPDATE SET payload=excluded.payload,checksum=excluded.checksum",[.text(value.job.uuidString),.int(Int64(value.ordinal)),.blob(bytes),.text(Self.digest(bytes))])
            try writeGuard10(guardValue);slot.maintenance += 1;try writeSlot10(slot);try hooks.beforeSaveCommit?()
        }
        updateGraphCache10(slot:slot);try hooks.afterSaveCommit?()
    }
    func abortTextExportBeforeNative10(_ value:TextRecoveryExportV2) throws {
        guard !value.states.contains(.publicationUnconfirmed),value.states.contains(.notAttempted),
              try textExportsV2(value.job,after:value.ordinal-1,limit:1).first == value else { throw FileOperationFailure.recoveryUncertain }
        var guardValue = try guard10(value.id)
        guard !guardValue.closed,let slotValue = try slot10(guardValue.slot) else { throw FileOperationFailure.recoveryUncertain }
        var slot = slotValue;guardValue.remainingAbortedBeforeNative = true;guardValue.closed = true
        try transaction {try writeGuard10(guardValue);slot.maintenance += 1;try writeSlot10(slot);try hooks.beforeSaveCommit?()}
        updateGraphCache10(slot:slot);try hooks.afterSaveCommit?()
    }
    private func validateTextExportV2(_ item:TextRecoveryExportV2,record:TextRevisionRecordV2) throws {
        try item.validate()
        guard item.job == record.id,let attempt = try record.project().attempts.first(where:{$0.preparation.id == item.attemptID}),
              let custody = attempt.custody,item.direction == attempt.preparation.direction,
              item.sources == [attempt.preparation.directory(in:record).appendingPathComponent("before"),attempt.preparation.directory(in:record).appendingPathComponent("submitted")],
              item.expected == [custody.before.copy,custody.submitted.edited] else { throw FileOperationFailure.recoveryUncertain }
    }
    private func validateGuardRelations10(slot:RevisionDigest,requireClosed:Bool) throws {
        // Headers are at most 1KiB. Indexed forward + reverse checks must agree;
        // an advisory count never clears a pending or missing relation.
        // jobs.head is an independent durable mirror. Losing the guard and its
        // event-index entry together cannot hide an intent still present there.
        try validateRoutingHeaderEnvelope10()
        try validateSelectedScopeRelations10(slot)
        guard try integers("SELECT count(*) FROM text_members10 AS m INDEXED BY text_members10_epoch CROSS JOIN jobs AS j ON j.id=m.job WHERE m.slot=? AND (json_array_length(CAST(j.head AS TEXT),'$.events')!=j.revision-1 OR (SELECT count(*) FROM text_revision_events e WHERE e.job=m.job)!=j.revision-1 OR (SELECT count(*) FROM events e WHERE e.job=m.job)!=j.revision OR (j.revision>1 AND ((SELECT min(ordinal) FROM text_revision_events e WHERE e.job=m.job)!=0 OR (SELECT max(ordinal) FROM text_revision_events e WHERE e.job=m.job)!=j.revision-2 OR json_extract(CAST(j.head AS TEXT),'$.events[#-1]')!=(SELECT json(CAST(e.payload AS TEXT)) FROM text_revision_events e WHERE e.job=m.job AND e.ordinal=j.revision-2))))",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_members10 AS m INDEXED BY text_members10_epoch CROSS JOIN jobs AS j ON j.id=m.job WHERE m.slot=? AND (m.retirement_guard IS NULL OR m.retirement_guard='') AND EXISTS (SELECT 1 FROM json_each(CAST(j.head AS TEXT),'$.events') e WHERE json_type(e.value,'$.retirementIntent') IS NOT NULL OR json_type(e.value,'$.retirementIntentRootMetadataV4') IS NOT NULL OR json_type(e.value,'$.retirementIntentNativeDirectoryV5') IS NOT NULL)",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_members10 AS m INDEXED BY text_members10_epoch CROSS JOIN text_revision_events AS e ON e.job=m.job WHERE m.slot=? AND json_type(CAST(m.payload AS TEXT),'$.seal')='object' AND e.ordinal>=json_extract(CAST(m.payload AS TEXT),'$.seal.revision')-1 AND json_type(CAST(e.payload AS TEXT),'$.retirementIntent') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementIntentRootMetadataV4') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementIntentNativeDirectoryV5') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementReturned') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementConfirmed') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementConfirmedRootMetadataV4') IS NULL AND json_type(CAST(e.payload AS TEXT),'$.retirementConfirmedNativeDirectoryV5') IS NULL",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_members10 m LEFT JOIN text_mutation_guards10 g ON g.id=m.retirement_guard WHERE m.slot=? AND m.retirement_guard!='' AND (g.id IS NULL OR g.kind!='retirement' OR g.job!=m.job OR g.slot!=m.slot OR g.epoch!=m.epoch)",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_members10 AS m INDEXED BY text_members10_epoch CROSS JOIN text_revision_events AS e ON e.job=m.job WHERE m.slot=? AND (json_type(CAST(e.payload AS TEXT),'$.retirementIntent') IS NOT NULL OR json_type(CAST(e.payload AS TEXT),'$.retirementIntentRootMetadataV4') IS NOT NULL OR json_type(CAST(e.payload AS TEXT),'$.retirementIntentNativeDirectoryV5') IS NOT NULL) AND (m.retirement_guard IS NULL OR m.retirement_guard='')",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_revision_exports x JOIN text_members10 m ON m.job=x.job LEFT JOIN text_mutation_guards10 g ON g.job=x.job AND g.kind='export' AND g.ordinal=x.ordinal WHERE m.slot=? AND (g.id IS NULL OR g.slot!=m.slot OR g.epoch!=m.epoch)",[.text(slot.hex)]) == [0] else { throw FileOperationFailure.recoveryUncertain }
        try observeScopeHeaders10(slot)
        var previousMember=""
        while true {
            let ids=try texts("SELECT job FROM text_members10 WHERE slot=? AND job>? ORDER BY job LIMIT 64",[.text(slot.hex),.text(previousMember)])
            if ids.isEmpty {break}
            for id in ids {
                guard let uuid=UUID(uuidString:id) else {throw FileOperationFailure.recoveryUncertain}
                let member=try member10(uuid),epoch=try epoch10(slot,member.epoch)
                if let cut=epoch.cut {
                    guard let seal=member.seal,cut.members.contains(seal),member.checkpointID==cut.id else {throw FileOperationFailure.recoveryUncertain}
                } else {guard member.seal==nil,member.checkpointID==nil else {throw FileOperationFailure.recoveryUncertain}}
            }
            previousMember=ids.last!
        }
        var previous = "",seen = 0
        while true {
            let ids = try texts("SELECT id FROM text_mutation_guards10 WHERE slot=? AND id>? ORDER BY id LIMIT 64",[.text(slot.hex),.text(previous)])
            if ids.isEmpty { break }
            for id in ids {
                seen += 1;guard seen <= 20_000,let uuid = UUID(uuidString:id) else { throw FileOperationFailure.recoveryUncertain }
                let value = try guard10(uuid),member = try member10(value.job)
                guard member.slot == slot,member.epoch == value.epoch,try textEncoded(value).count <= 1024 else { throw FileOperationFailure.recoveryUncertain }
                guard let current=try slot10(slot),value.admittedStamp.generation <= current.generation,
                      value.maintenanceGeneration >= 0,value.maintenanceGeneration <= current.maintenance else {throw FileOperationFailure.recoveryUncertain}
                _ = try epoch10(slot,value.admittedStamp.epoch)
                let expected:[String]
                if value.kind == .retirement {
                    guard member.retirementGuard == value.id else { throw FileOperationFailure.recoveryUncertain }
                    expected = try texts("SELECT checksum FROM jobs WHERE id=?",[.text(value.job.uuidString)])
                    let phase=try integers("SELECT CASE WHEN json_type(CAST(head AS TEXT),'$.events[#-1].retirementConfirmed')='object' OR json_type(CAST(head AS TEXT),'$.events[#-1].retirementConfirmedRootMetadataV4')='object' OR json_type(CAST(head AS TEXT),'$.events[#-1].retirementConfirmedNativeDirectoryV5')='object' THEN 1 ELSE 0 END FROM jobs WHERE id=?",[.text(value.job.uuidString)])
                    guard phase == [value.closed ? 1:0],!value.remainingAbortedBeforeNative else {throw FileOperationFailure.recoveryUncertain}
                } else {
                    guard member.retirementGuard != value.id else { throw FileOperationFailure.recoveryUncertain }
                    expected = try texts("SELECT checksum FROM text_revision_exports WHERE job=? AND ordinal=?",[.text(value.job.uuidString),.int(Int64(value.ordinal))])
                    let phase=try texts("SELECT json_extract(CAST(payload AS TEXT),'$.states[0]') FROM text_revision_exports WHERE job=? AND ordinal=?",[.text(value.job.uuidString),.int(Int64(value.ordinal))])
                    let second=try texts("SELECT json_extract(CAST(payload AS TEXT),'$.states[1]') FROM text_revision_exports WHERE job=? AND ordinal=?",[.text(value.job.uuidString),.int(Int64(value.ordinal))])
                    guard phase.count == 1,second.count == 1 else {throw FileOperationFailure.recoveryUncertain}
                    let allVerified=phase == ["verified"] && second == ["verified"]
                    let noIntent=(phase == ["verified"] || phase == ["notAttempted"]) && second == ["notAttempted"]
                    guard !value.remainingAbortedBeforeNative || noIntent,
                          value.closed == (allVerified || value.remainingAbortedBeforeNative) else {throw FileOperationFailure.recoveryUncertain}
                }
                guard expected == [value.outcome.hex] else { throw FileOperationFailure.recoveryUncertain }
                if requireClosed && !value.closed { throw LocalTextCapacityReason.pendingMaintenance }
            }
            previous = ids.last!
        }
    }
    func checkpointPreparation10(slot:RevisionDigest) throws -> (planning:TextPlanning10,members:[TextEpochMemberSeal10],ended:Int) {
        if let reason=try storeAdmissionReason10(estimatedBytes:524_288,newJob:false) {throw reason}
        let planning = try textSavePlanningV3(slot:slot)
        guard let graph = try graph10(slot),!graph.records.isEmpty || !graph.edges.isEmpty else { throw LocalTextCapacityReason.nothingToCheckpoint }
        try validateGuardRelations10(slot:slot,requireClosed:true)
        let members = try graph.records.values.sorted{$0.id.uuidString<$1.id.uuidString}.map {
            TextEpochMemberSeal10(id:$0.id,revision:$0.revision,prefix:try $0.prefix,state:try $0.project().state)
        }
        let settlements=Set(planning.settlements.map(\.id))
        let ended = try graph.records.values.filter {record in
            let value=settlements.contains(record.id) ? try record.appending(.stoppedBeforeEntry):record
            return try value.project().canPrepareInverse && value.manifest.base.lineage == graph.slot.head.lineage
        }.count
        return (planning,members,ended)
    }
    func performCheckpoint10(_ plan:LocalTextCheckpointPlan,mutationEntry:() -> Void,validateSource:() throws -> Void) throws -> TextCheckpoint10 {
        try validateWriteCatalog(cancellation:OperationCancellation())
        let prepared = try checkpointPreparation10(slot:plan.slot)
        guard prepared.planning.stamp == plan.stamp,prepared.planning.maintenance == plan.maintenance,
              prepared.members == plan.memberPrefixes,let graph = try graph10(plan.slot) else { throw LocalTextCapacityReason.stalePlan }
        let sameHead = plan.manifestVersion == 4
            ? graph.slot.head.witness.samePersistentObservation(plan.token.witness, qualifiedVolume: plan.token.witness.volume)
            : graph.slot.head.witness == plan.token.witness
        guard plan.review.adoptsExternalBaseline || sameHead else { throw LocalTextCapacityReason.sourceChanged }
        try reserve(estimatedBytes:524_288)
        var records = graph.records
        for settlement in prepared.planning.settlements {
            guard let old = records[settlement.id],try old.prefix == settlement.prefix,try old.project().intent == nil else { throw FileOperationFailure.recoveryUncertain }
            records[old.id] = try old.appending(.stoppedBeforeEntry)
        }
        let members = try records.values.sorted{$0.id.uuidString<$1.id.uuidString}.map {
            TextEpochMemberSeal10(id:$0.id,revision:$0.revision,prefix:try $0.prefix,state:try $0.project().state)
        }
        let root = TextRevisionHeadV2(slot:graph.slot.slot,lineage:UUID(),sequence:0,job:nil,witness:plan.token.witness)
        let cut = TextCheckpoint10(id:plan.review.checkpointID,owner:owner,nextEpoch:UUID(),slot:graph.slot.slot,
            old:.init(epoch:graph.epoch.id,head:graph.slot.head),oldGeneration:graph.slot.generation,maintenanceGeneration:graph.slot.maintenance,
            oldEpochDigest:.bytes(try textEncoded(graph.epoch)),observed:plan.token.witness,root:root,
            members:members,edgesDigest:.bytes(try textEncoded(graph.edges)),endedUndoCount:prepared.ended,
            baselineAdopted:!sameHead,createdAt:Date(),
            persistentVolume:plan.manifestVersion == 4 ? plan.token.witness.volume : nil)
        try cut.validate()
        var closed = graph.epoch;closed.cut = cut
        let next = TextEpoch10(owner:owner,id:cut.nextEpoch,slot:cut.slot,ordinal:closed.ordinal+1,migratedFrom9:false,importedRecords:[],root:root,predecessor:cut,cut:nil)
        var slot = graph.slot;slot.epoch = next.id;slot.generation += 1;slot.head = root
        mutationEntry()
        do {
            try transaction {
                for settlement in prepared.planning.settlements {
                    guard let old = graph.records[settlement.id],let value = records[settlement.id] else { throw FileOperationFailure.recoveryUncertain }
                    try writeTextRecord10(old,value,event:.stoppedBeforeEntry)
                }
                for seal in members {
                    var member = try member10(seal.id);member.seal = seal;member.checkpointID = cut.id;try writeMember10(member)
                }
                try writeEpoch10(closed);try writeEpoch10(next);try writeSlot10(slot)
                try hooks.beforeTextCheckpointCommit?();try validateSource()
            }
            epochGraphCache10.removeValue(forKey:slot.slot)
            try hooks.afterTextCheckpointCommit?()
        } catch {
            epochGraphCache10.removeValue(forKey:slot.slot)
            throw TextCheckpointMutationUncertain10.enteredTransaction
        }
        return cut
    }
    func checkpoint10(_ id:UUID) throws -> TextCheckpoint10? {
        guard catalogVersion == 10 else { throw LocalTextCapacityReason.upgradeRequired }
        guard let epoch = try epochValue10(TextEpoch10.self,sql:"SELECT payload,checksum FROM text_epochs10 WHERE checkpoint=?",bindings:[.text(id.uuidString)]) else { return nil }
        guard let cut = epoch.cut,cut.id == id else { throw FileOperationFailure.recoveryUncertain }
        _ = try epoch10(cut.slot,cut.old.epoch)
        let next = try epoch10(cut.slot,cut.nextEpoch)
        guard next.predecessor == cut,next.ordinal == epoch.ordinal+1 else { throw FileOperationFailure.recoveryUncertain }
        return cut
    }
    func confirmCheckpoint10(_ expected:TextCheckpoint10) throws -> TextCheckpoint10 {
        guard let authoritative=try checkpoint10(expected.id),authoritative == expected,
              let slot=try slot10(expected.slot),slot.epoch == expected.nextEpoch,
              slot.generation == expected.oldGeneration+1,slot.maintenance == expected.maintenanceGeneration,
              slot.head == expected.root,let graph=try graph10(expected.slot),
              graph.records.isEmpty,graph.edges.isEmpty,graph.epoch.predecessor == expected else {throw FileOperationFailure.recoveryUncertain}
        let old=try epoch10(expected.slot,expected.old.epoch)
        try validateClosedEpoch10(old,cut:expected,cancellation:OperationCancellation())
        try validateGuardRelations10(slot:expected.slot,requireClosed:true)
        return authoritative
    }
    func validateEpochCatalog10(cancellation:OperationCancellation) throws {
        try validateRoutingHeaderEnvelope10()
        guard try integer("SELECT count(*) FROM text_members10") == integer("SELECT count(*) FROM job_protocols WHERE kind='textRevisionV3'"),
              try integer("SELECT count(*) FROM jobs j JOIN job_protocols p ON p.job=j.id WHERE p.kind!='textRevisionV3' AND j.text_slot10 IS NOT NULL") == 0,
              try integer("SELECT count(*) FROM jobs AS j INDEXED BY jobs_text_slot10 LEFT JOIN text_members10 m ON m.job=j.id WHERE j.text_slot10 IS NOT NULL AND (m.job IS NULL OR m.slot!=j.text_slot10)") == 0,
              try integer("SELECT count(*) FROM text_slots10") <= 10_000,
              try integer("SELECT count(*) FROM text_mutation_guards10") <= 20_000,
              try integer("SELECT count(*) FROM text_revision_exports") <= 10_000 else { throw FileOperationFailure.recoveryUncertain }
        for key in try texts("SELECT slot FROM text_slots10 ORDER BY slot LIMIT 10001") {
            try cancellation.check();let slot = try RevisionDigest(key)
            _ = try graph10(slot);try validateGuardRelations10(slot:slot,requireClosed:false)
            for id in try texts("SELECT epoch FROM text_epochs10 WHERE slot=? ORDER BY ordinal LIMIT 10001",[.text(key)]) {
                guard let uuid=UUID(uuidString:id) else {throw FileOperationFailure.recoveryUncertain}
                let epoch=try epoch10(slot,uuid)
                if let cut=epoch.cut {
                    guard try checkpoint10(cut.id) == cut else {throw FileOperationFailure.recoveryUncertain}
                    try validateClosedEpoch10(epoch,cut:cut,cancellation:cancellation)
                }
            }
        }
        try eachJobID { id in
            if try catalogProtocol(id) == .textRevisionV3 {
                let record = try textRecordV2(UUID(uuidString:id)!)
                var after:Int?
                while true {let page = try textExportsV2(record.id,after:after);if page.isEmpty {break};after = page.last!.ordinal}
            }
        }
        guard try integer("SELECT count(*) FROM text_revision_heads old LEFT JOIN text_members10 m ON m.job=old.job LEFT JOIN text_epochs10 ep ON ep.slot=m.slot AND ep.epoch=m.epoch LEFT JOIN text_epoch_edges10 e ON e.slot=m.slot AND e.epoch=m.epoch AND e.ordinal=old.ordinal WHERE m.job IS NULL OR ep.ordinal!=0 OR old.slot!=m.slot OR e.job!=old.job OR e.payload!=old.payload OR e.checksum!=old.checksum") == 0 else {throw FileOperationFailure.recoveryUncertain}
    }
    private func validateClosedEpoch10(_ epoch:TextEpoch10,cut:TextCheckpoint10,cancellation:OperationCancellation) throws {
        epochGraphCache10.removeAll(keepingCapacity:true)
        let ids=try texts("SELECT job FROM text_members10 WHERE slot=? AND epoch=? ORDER BY job LIMIT 65",[.text(epoch.slot.hex),.text(epoch.id.uuidString)])
        guard ids == cut.members.map({$0.id.uuidString}).sorted(),ids.count <= 64 else {throw FileOperationFailure.recoveryUncertain}
        var records:[UUID:TextRevisionRecordV2]=[:]
        for id in ids {try cancellation.check();let record=try textRecordV2(UUID(uuidString:id)!);records[record.id]=record}
        let query=try prepare("SELECT ordinal,job,payload,checksum FROM text_epoch_edges10 WHERE slot=? AND epoch=? ORDER BY ordinal LIMIT 129",[.text(epoch.slot.hex),.text(epoch.id.uuidString)])
        defer {sqlite3_finalize(query)}
        var edges:[TextRevisionHeadEdgeV3]=[],head=epoch.root,known=[0:epoch.root]
        var native:[UUID:Int]=[:],baselines:[UUID:Int]=[:],lineages:Set<UUID>=[head.lineage]
        while true {
            let status=sqlite3_step(query);if status == SQLITE_DONE {break}
            guard status == SQLITE_ROW,edges.count < 128 else {throw FileOperationFailure.recoveryUncertain}
            let bytes=try blob(query,2),edge=try textDecoded(TextRevisionHeadEdgeV3.self,bytes)
            guard string(query,3) == Self.digest(bytes),Int(sqlite3_column_int64(query,0)) == edges.count,
                  string(query,1) == edge.job.uuidString,edge.before == head,let record=records[edge.job] else {throw FileOperationFailure.recoveryUncertain}
            try edge.validate(record:record)
            switch edge {case .native:native[edge.job,default:0] += 1
            case .baseline:
                guard lineages.insert(edge.after.lineage).inserted else {throw FileOperationFailure.recoveryUncertain}
                baselines[edge.job,default:0] += 1}
            edges.append(edge);head=edge.after;known[head.sequence]=head
        }
        guard head == cut.old.head,RevisionDigest.bytes(try textEncoded(edges)) == cut.edgesDigest else {throw FileOperationFailure.recoveryUncertain}
        for record in records.values {
            guard known[record.manifest.base.sequence] == record.manifest.base || legacyPreparationRoot10(record,epoch:epoch),
                  native[record.id,default:0] == record.events.filter({if case .applied = $0{return true};return false}).count,
                  baselines[record.id,default:0] == (record.manifest.baseline == nil ? 0:1) else {throw FileOperationFailure.recoveryUncertain}
        }
    }
}

// Appended into the same SQLite file. These are private phase headers, not a
// second record projection or native proof. Selected full record validation and
// explicit full audit still use the original native validators.
extension SQLiteJournalStore {
    private struct TextScopeManifestHeader10:Decodable {let id:UUID,slot:RevisionDigest}
    private struct TextScopeRecordHeader10:Decodable {
        let manifest:TextScopeManifestHeader10
        let events:[TextScopeEventHeader10]
    }
    private struct TextScopeEventHeader10:Decodable {
        private struct Key:CodingKey {
            let stringValue:String
            var intValue:Int? {nil}
            init?(stringValue:String) {self.stringValue=stringValue}
            init?(intValue:Int) {return nil}
        }
        let kind:String
        init(from decoder:any Decoder) throws {
            let values=try decoder.container(keyedBy:Key.self)
            guard values.allKeys.count==1,let key=values.allKeys.first,
                  ["preparation","ready","custody","intent","applied","stoppedBeforeEntry","uncertain",
                   "retirementIntent","retirementIntentRootMetadataV4","retirementIntentNativeDirectoryV5",
                   "retirementReturned","retirementConfirmed","retirementConfirmedRootMetadataV4",
                   "retirementConfirmedNativeDirectoryV5"].contains(key.stringValue) else {throw FileOperationFailure.recoveryUncertain}
            kind=key.stringValue
        }
    }
    private func validateRoutingHeaderEnvelope10() throws {
        // Unknown routing cannot be used to infer a safe unrelated document.
        // This examines fixed headers only, never another job's native JSON.
        guard try integer("SELECT count(*) FROM jobs") == integer("SELECT count(*) FROM job_protocols"),
              try integer("SELECT count(*) FROM jobs j JOIN job_protocols p ON p.job=j.id WHERE p.kind='textRevisionV3' AND (j.text_slot10 IS NULL OR length(j.text_slot10)!=64 OR j.text_slot10 GLOB '*[^0-9a-f]*')") == 0 else {throw FileOperationFailure.recoveryUncertain}
    }
    private func validateSelectedScopeRelations10(_ slot:RevisionDigest) throws {
        guard try integers("SELECT count(*) FROM jobs AS j INDEXED BY jobs_text_slot10 LEFT JOIN text_members10 AS m ON m.job=j.id WHERE j.text_slot10=? AND (m.job IS NULL OR m.slot!=j.text_slot10)",[.text(slot.hex)]) == [0],
              try integers("SELECT count(*) FROM text_members10 m LEFT JOIN jobs j ON j.id=m.job WHERE m.slot=? AND (j.id IS NULL OR j.text_slot10 IS NULL OR j.text_slot10!=m.slot)",[.text(slot.hex)]) == [0] else {throw FileOperationFailure.recoveryUncertain}
    }
    private func observeScopeHeaders10(_ slot:RevisionDigest) throws {
        let query=try prepare("SELECT j.id,j.revision,j.head,j.checksum,j.text_slot10 FROM jobs AS j INDEXED BY jobs_text_slot10 WHERE j.text_slot10=? ORDER BY j.id",[.text(slot.hex)])
        defer {sqlite3_finalize(query)}
        var rows=0,bytes=0
        while true {
            let status=sqlite3_step(query);if status == SQLITE_DONE {break}
            guard status == SQLITE_ROW,rows<10_000,let id=UUID(uuidString:string(query,0)) else {throw FileOperationFailure.recoveryUncertain}
            let member=try member10(id)
            guard member.slot == slot,string(query,4)==slot.hex else {throw FileOperationFailure.recoveryUncertain}
            let data=try blob(query,2)
            guard string(query,3)==Self.digest(data) else {throw FileOperationFailure.recoveryUncertain}
            let header=try JSONDecoder().decode(TextScopeRecordHeader10.self,from:data)
            guard header.manifest.id==id,header.manifest.slot==slot,header.events.count<=32,
                  Int(sqlite3_column_int64(query,1))==header.events.count+1 else {throw FileOperationFailure.recoveryUncertain}
            rows += 1;bytes += data.count
        }
        hooks.metrics?.add(.scopeNativeHeaderRows,rows);hooks.metrics?.add(.scopeNativeHeaderBytes,bytes)
        // SQL phase expressions below consume these same selected operands.
        // This is a conservative processing charge, explicitly not OS I/O.
        hooks.metrics?.add(.sqlJSONHeadProjectionBytesUpperBound,bytes*4)
    }
    func textScopeQueryPlan10(slot:RevisionDigest) throws -> [String] {
        let query=try prepare("EXPLAIN QUERY PLAN SELECT j.id FROM jobs AS j INDEXED BY jobs_text_slot10 LEFT JOIN text_members10 AS m ON m.job=j.id WHERE j.text_slot10=? AND (m.job IS NULL OR m.slot!=j.text_slot10)",[.text(slot.hex)])
        defer {sqlite3_finalize(query)}
        var result:[String]=[]
        while true {
            let status=sqlite3_step(query);if status == SQLITE_DONE {break}
            guard status == SQLITE_ROW,result.count<16 else {throw FileOperationFailure.recoveryUncertain}
            result.append(string(query,3))
        }
        return result
    }
}
