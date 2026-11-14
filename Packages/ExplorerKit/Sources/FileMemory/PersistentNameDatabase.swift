import Foundation
import SQLite3

extension NameIndexDatabase {
    func boundary(_ stage: NameStoreBoundary) throws {
        if qualificationFlushBeforeBoundary { try check(sqlite3_db_cacheflush(db)) }
        try probe?(stage)
    }
    // Fixed, versioned SQL, shared by the memory reference and persistent lane.
    // No FTS shadows, source bodies or user-supplied SQL. Native-reference rows
    // are defined separately, under the same fixed-schema writer.
    static let legacySchemaSQL = [
        "CREATE TABLE records (record INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL, sort_key BLOB NOT NULL, nonce TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE names (record INTEGER NOT NULL REFERENCES records(record) ON DELETE CASCADE, field INTEGER NOT NULL, ordinal INTEGER NOT NULL, original TEXT NOT NULL, literal BLOB NOT NULL, tolerant BLOB NOT NULL, PRIMARY KEY(record,field,ordinal)) WITHOUT ROWID",
        "CREATE TABLE name_keys (variant INTEGER NOT NULL, shape INTEGER NOT NULL, value BLOB NOT NULL, record INTEGER NOT NULL, field INTEGER NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY(variant,shape,value,record,field,ordinal), FOREIGN KEY(record,field,ordinal) REFERENCES names(record,field,ordinal) ON DELETE CASCADE) WITHOUT ROWID",
        "CREATE INDEX keys_by_name ON name_keys(record,field,ordinal)",
        "CREATE TABLE store_header (singleton INTEGER PRIMARY KEY CHECK(singleton=1), store_id TEXT NOT NULL, format INTEGER NOT NULL, normalization INTEGER NOT NULL, runtime TEXT NOT NULL, all_pending INTEGER NOT NULL, epoch INTEGER NOT NULL)",
        "CREATE TABLE revocations (item TEXT PRIMARY KEY, completed INTEGER NOT NULL) WITHOUT ROWID",
    ]
    static var schemaSQL: [String] { legacySchemaSQL + referenceSchemaSQL }

    func createSchema() throws { for sql in Self.schemaSQL { try exec(sql) } }

    func openPersistent(_ catalog: OwnedNameCatalog, action: NameStoreOpenAction, creating: Bool, vfs: String?) throws {
        try catalog.validate()
        try catalog.validateHeader(creating: creating)
        if action != .recover, try catalog.needsRecovery() { throw NameStoreFailure.recoveryRequired }
        let flags = (action == .readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(catalog.path, &db, flags, vfs)
        guard code == SQLITE_OK else {
            close(); throw NameIndexFailure.storage(code)
        }
        do {
            sqlite3_extended_result_codes(db, 1)
            sqlite3_busy_timeout(db, 0)
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 262_144)
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16_384)
            try exec("PRAGMA trusted_schema=OFF")
            try exec("PRAGMA foreign_keys=ON")
            try exec("PRAGMA temp_store=MEMORY")
            try exec("PRAGMA cache_size=-2048")
            try exec("PRAGMA mmap_size=0")
            // Do not change any persistent setting of an unknown catalog.
            if !creating { _ = try validateFormat(catalog) }
            if action == .readOnly {
                try exec("PRAGMA query_only=ON")
            } else {
                // An explicit recovery open is the only path permitted to let
                // native SQLite replay a hot rollback journal.
                let journal = try prepare("PRAGMA journal_mode=DELETE")
                defer { sqlite3_finalize(journal) }
                guard try step(journal), try text(journal, column: 0) == "delete" else { throw NameStoreFailure.unsupported }
                try exec("PRAGMA synchronous=EXTRA")
                try exec("PRAGMA fullfsync=ON")
                try exec("PRAGMA secure_delete=ON")
                try exec("PRAGMA page_size=4096")
                try exec("PRAGMA max_page_count=131072")
                guard try scalar("PRAGMA synchronous") == 3, try scalar("PRAGMA fullfsync") == 1,
                      try scalar("PRAGMA secure_delete") == 1, try scalar("PRAGMA max_page_count") == 131_072 else {
                    throw NameStoreFailure.unsupported
                }
            }
            guard try scalar("PRAGMA foreign_keys") == 1, try scalar("PRAGMA trusted_schema") == 0,
                  try scalar("PRAGMA temp_store") == 2, try scalar("PRAGMA cache_size") == -2_048 else {
                throw NameStoreFailure.unsupported
            }
            try catalog.validate()
        } catch { close(); throw error }
    }

    func initialize(_ catalog: OwnedNameCatalog, first: AuthoredNames, reference: NativeDocumentReference? = nil) throws {
        try transaction { try initializeRows(catalog, first: first, reference: reference) }
    }
    func initializeRows(_ catalog: OwnedNameCatalog, first: AuthoredNames, reference: NativeDocumentReference? = nil) throws {
        try createSchema()
        try exec("PRAGMA application_id=\(NameStoreFormat.applicationID)")
        try exec("PRAGMA user_version=\(NameStoreFormat.schema)")
        let statement = try prepare("INSERT INTO store_header VALUES(1,?,?,?,?,0,0)")
        defer { sqlite3_finalize(statement) }
        try bind(catalog.storeID.uuidString, to: statement, at: 1)
        try check(sqlite3_bind_int(statement, 2, Int32(NameStoreFormat.schema)))
        try check(sqlite3_bind_int(statement, 3, Int32(RememberedNameNormalization.version)))
        try bind(NameStoreFormat.runtime, to: statement, at: 4)
        _ = try step(statement)
        try save(id: catalog.firstID, names: first, expected: nil, nonce: catalog.firstNonce, withinTransaction: true)
        if let reference { try saveReference(catalog.firstID, evidence: reference, expected: nil, nonce: catalog.firstNonce) }
    }

    struct Header {
        let compatible: Bool
        let allPending: Bool
    }
    func validateFormat(_ catalog: OwnedNameCatalog) throws -> Header {
        let version = try scalar("PRAGMA user_version")
        guard try scalar("PRAGMA application_id") == NameStoreFormat.applicationID,
              [1, 2, NameStoreFormat.moveSchema, NameStoreFormat.memberSchema].contains(version) else { throw NameStoreFailure.unsupported }
        let expectedSchema = version == 1 ? Self.legacySchemaSQL : version == 2 ? Self.schemaSQL
            : Self.schemaSQL + Self.moveSchemaSQL + (version == NameStoreFormat.memberSchema ? Self.memberSchemaSQL : [])
        let schema = try prepare("SELECT sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
        defer { sqlite3_finalize(schema) }
        var actual: [String] = []
        while try step(schema) {
            actual.append(try text(schema, column: 0))
            guard actual.count <= expectedSchema.count else { throw NameStoreFailure.unsupported }
        }
        guard actual.sorted() == expectedSchema.sorted() else { throw NameStoreFailure.unsupported }
        let header = try prepare("SELECT singleton,store_id,format,normalization,runtime,all_pending,epoch FROM store_header")
        defer { sqlite3_finalize(header) }
        guard try step(header), try integer(header, column: 0) == 1,
              try text(header, column: 1) == catalog.storeID.uuidString,
              try integer(header, column: 2) == version else { throw NameStoreFailure.unsafe }
        let normalization = try integer(header, column: 3), runtime = try text(header, column: 4)
        let pending = try integer(header, column: 5), epoch = try integer(header, column: 6)
        guard (pending == 0 || pending == 1), epoch >= 0, !(try step(header)) else { throw NameStoreFailure.unsafe }
        return Header(compatible: normalization == RememberedNameNormalization.version && runtime == NameStoreFormat.runtime,
                      allPending: pending == 1)
    }

    /// Once per held lease, never per returned row/window. Streaming validation
    /// keeps only one item's authored fields and projections live at a time.
    func validateRows(verifyIndex: Bool, cancellation: RememberedNameCancellation = .init()) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        let integrity = try prepare("PRAGMA quick_check(1)")
        defer { sqlite3_finalize(integrity) }
        guard try step(integrity), try text(integrity, column: 0) == "ok", !(try step(integrity)) else { throw NameStoreFailure.unsafe }
        let foreign = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreign) }
        guard try !step(foreign) else { throw NameStoreFailure.unsafe }
        let records = try prepare("SELECT record,id,revision,sort_key,nonce,hidden FROM records ORDER BY record")
        defer { sqlite3_finalize(records) }
        let names = try prepare("SELECT field,ordinal,original,literal,tolerant FROM names WHERE record=? ORDER BY field,ordinal")
        defer { sqlite3_finalize(names) }
        let keys = try prepare("SELECT variant,shape,value,field,ordinal FROM name_keys WHERE record=? ORDER BY field,ordinal,variant,shape,value")
        defer { sqlite3_finalize(keys) }
        var count = 0
        while try step(records) {
            try autoreleasepool {
            if cancellation.isCancelled { throw NameIndexFailure.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NameIndexFailure.resourceLimit }
            count += 1
            guard count <= NameStoreFormat.maximumRecords, try integer(records, column: 0) > 0,
                  let uuid = UUID(uuidString: try text(records, column: 1)),
                  try text(records, column: 1) == uuid.uuidString,
                  UUID(uuidString: try text(records, column: 4)) != nil else { throw NameStoreFailure.unsafe }
            _ = try positiveRevision(records, column: 2)
            let hidden = try integer(records, column: 5)
            guard hidden == 0 || hidden == 1 else { throw NameStoreFailure.unsafe }
            let number = sqlite3_column_int64(records, 0)
            sqlite3_reset(names); sqlite3_clear_bindings(names)
            try check(sqlite3_bind_int64(names, 1, number))
            var nickname: String?, alternates: [String] = [], labels: [String] = []
            var loaded: [(RememberedNameField, Int, String, String)] = []
            while try step(names) {
                guard let field = RememberedNameField(rawValue: try integer(names, column: 0)) else { throw NameStoreFailure.unsafe }
                let ordinal = try integer(names, column: 1), original = try text(names, column: 2)
                switch field {
                case .nickname:
                    guard ordinal == 0, nickname == nil else { throw NameStoreFailure.unsafe }; nickname = original
                case .alternateName:
                    guard ordinal == alternates.count, ordinal < 16 else { throw NameStoreFailure.unsafe }; alternates.append(original)
                case .label:
                    guard ordinal == labels.count, ordinal < 16 else { throw NameStoreFailure.unsafe }; labels.append(original)
                }
                loaded.append((field, ordinal, try utf8(names, column: 3), try utf8(names, column: 4)))
            }
            let authored = try AuthoredNames(nickname: nickname, alternateNames: alternates, labels: labels)
            guard authored.nickname == nickname, authored.alternateNames == alternates, authored.labels == labels else { throw NameStoreFailure.unsafe }
            if verifyIndex {
                let projection = try NameProjection.fields(authored)
                guard projection.count == loaded.count else { throw NameStoreFailure.unsafe }
                let sort = Data(RememberedNameNormalization.key(nickname ?? alternates.first ?? labels[0]).utf8)
                guard try blob(records, column: 3) == sort else { throw NameStoreFailure.unsafe }
                var expected = Set<StoredKey>()
                for (index, field) in projection.enumerated() {
                    let row = loaded[index]
                    guard row.0 == field.field, row.1 == field.ordinal, row.2 == field.literal, row.3 == field.tolerant else { throw NameStoreFailure.unsafe }
                    for (variant, key, words) in [(0, field.literal, field.literalWords), (1, field.tolerant, field.tolerantWords)] {
                        expected.insert(StoredKey(variant: variant, shape: 0, key: Data(key.utf8), field: field.field.rawValue, ordinal: field.ordinal))
                        for word in words { expected.insert(StoredKey(variant: variant, shape: 1, key: Data(word.utf8), field: field.field.rawValue, ordinal: field.ordinal)) }
                    }
                }
                sqlite3_reset(keys); sqlite3_clear_bindings(keys)
                try check(sqlite3_bind_int64(keys, 1, number))
                var actual = Set<StoredKey>()
                while try step(keys) {
                    guard actual.count < 1_024 else { throw NameStoreFailure.unsafe }
                    let key = try StoredKey(variant: integer(keys, column: 0), shape: integer(keys, column: 1),
                        key: blob(keys, column: 2), field: integer(keys, column: 3), ordinal: integer(keys, column: 4))
                    guard actual.insert(key).inserted else { throw NameStoreFailure.unsafe }
                }
                guard actual == expected else { throw NameStoreFailure.unsafe }
            }
            }
        }
        let revocations = try prepare("SELECT item,completed FROM revocations")
        defer { sqlite3_finalize(revocations) }
        var fences = 0
        while try step(revocations) {
            fences += 1
            guard fences <= 200_001 else { throw NameIndexFailure.resourceLimit }
            let id = try text(revocations, column: 0), completed = try integer(revocations, column: 1)
            guard id == "*" || UUID(uuidString: id)?.uuidString == id, completed == 0 || completed == 1 else { throw NameStoreFailure.unsafe }
        }
        // Hidden rows must have durable revocation authority; completed fences
        // must have no surviving authored text. No reconstruction from names.
        guard try scalar("SELECT count(*) FROM records WHERE hidden=1 AND NOT EXISTS(SELECT 1 FROM revocations WHERE item=records.id AND completed=0)") == 0,
              try scalar("SELECT count(*) FROM records JOIN revocations ON item=id WHERE completed=1") == 0,
              try scalar("SELECT count(*) FROM records JOIN revocations ON item=id WHERE completed=0 AND hidden=0") == 0 else { throw NameStoreFailure.unsafe }
        guard try scalar("SELECT all_pending FROM store_header") == scalar("SELECT count(*) FROM revocations WHERE item='*' AND completed=0") else {
            throw NameStoreFailure.unsafe
        }
        if try hasReferenceFormat { try validateReferences() }
        if try hasMoveFormat { try validateMoveHandoffs() }
    }

    private struct StoredKey: Hashable {
        let variant: Int, shape: Int, key: Data, field: Int, ordinal: Int
    }

    func matchesFirstCommit(_ catalog: OwnedNameCatalog) throws -> Bool {
        let statement = try prepare("SELECT nonce,revision FROM records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(catalog.firstID.rawValue.uuidString, to: statement, at: 1)
        guard try step(statement) else { return false }
        return try text(statement, column: 0) == catalog.firstNonce.uuidString && positiveRevision(statement, column: 1) == 1
    }

    func pendingForgetCount() throws -> Int { try scalar("SELECT count(*) FROM revocations WHERE completed=0") }
    func hasAllFence() throws -> Bool { try scalar("SELECT all_pending FROM store_header") == 1 }
    func hasMutation(_ id: RememberedItemID, nonce: UUID) throws -> Bool {
        let row = try prepare("SELECT nonce FROM records WHERE id=? AND hidden=0")
        defer { sqlite3_finalize(row) }; try bind(id.rawValue.uuidString, to: row, at: 1)
        return try step(row) && text(row, column: 0) == nonce.uuidString
    }

    func revoke(_ id: RememberedItemID?) throws {
        try transaction {
            let key = id?.rawValue.uuidString ?? "*"
            let statement = try prepare("INSERT INTO revocations(item,completed) VALUES(?,0) ON CONFLICT(item) DO UPDATE SET completed=0")
            defer { sqlite3_finalize(statement) }; try bind(key, to: statement, at: 1); _ = try step(statement)
            if let id {
                let hide = try prepare("UPDATE records SET hidden=1 WHERE id=?")
                defer { sqlite3_finalize(hide) }; try bind(id.rawValue.uuidString, to: hide, at: 1); _ = try step(hide)
            } else {
                guard try scalar("SELECT epoch FROM store_header") < Int.max else { throw NameIndexFailure.resourceLimit }
                try exec("UPDATE store_header SET all_pending=1")
            }
            try boundary(.revocationRows)
        }
        try probe?(.revocationCommit)
    }

    /// Each chunk is fully synchronized by the same native connection policy.
    /// A global fence stays committed throughout Forget All, including on Stop.
    func purgePending(cancellation: RememberedNameCancellation) throws {
        while try pendingForgetCount() > 0 {
            if cancellation.isCancelled { throw NameIndexFailure.cancelled }
            let next = try prepare("SELECT item FROM revocations WHERE completed=0 ORDER BY item LIMIT 1")
            defer { sqlite3_finalize(next) }
            guard try step(next) else { throw NameStoreFailure.unsafe }
            let item = try text(next, column: 0)
            try transaction {
                if item == "*" {
                    try exec("DELETE FROM records WHERE record IN (SELECT record FROM records ORDER BY record LIMIT 256)")
                } else {
                    let remove = try prepare("DELETE FROM records WHERE id=?")
                    defer { sqlite3_finalize(remove) }; try bind(item, to: remove, at: 1); _ = try step(remove)
                }
                try boundary(.purgeRows)
                if try item != "*" || scalar("SELECT EXISTS(SELECT 1 FROM records LIMIT 1)") == 0 {
                    let done = try prepare("UPDATE revocations SET completed=1 WHERE item=?")
                    defer { sqlite3_finalize(done) }; try bind(item, to: done, at: 1); _ = try step(done)
                    if item == "*" {
                        try exec("UPDATE store_header SET all_pending=0,epoch=epoch+1 WHERE epoch<9223372036854775807")
                        guard sqlite3_changes(db) == 1 else { throw NameIndexFailure.resourceLimit }
                    }
                }
            }
            try probe?(.purgeCommit)
        }
    }

    func updateIndex() throws {
        // Explicit only; uses the authoritative saved fields, no source reads.
        // Per-record transactions preserve bounded rollback size. The header is
        // changed last, so interruption leaves search withheld until rechecked.
        let ids = try prepare("SELECT id FROM records ORDER BY record")
        defer { sqlite3_finalize(ids) }
        while try step(ids) {
            guard let uuid = UUID(uuidString: try text(ids, column: 0)) else { throw NameStoreFailure.unsafe }
            let id = RememberedItemID(uuid)
            let hidden = try prepare("SELECT hidden FROM records WHERE id=?")
            defer { sqlite3_finalize(hidden) }; try bind(id.rawValue.uuidString, to: hidden, at: 1); _ = try step(hidden)
            if try integer(hidden, column: 0) != 0 { continue }
            let snapshot = try snapshot(id)
            // Reprojection is not a user edit: retain revision and mutation ID.
            let nonceRow = try prepare("SELECT nonce FROM records WHERE id=?")
            defer { sqlite3_finalize(nonceRow) }; try bind(id.rawValue.uuidString, to: nonceRow, at: 1); _ = try step(nonceRow)
            guard let nonce = UUID(uuidString: try text(nonceRow, column: 0)) else { throw NameStoreFailure.unsafe }
            try transaction {
                try save(id: id, names: snapshot.names, expected: snapshot.revision, nonce: nonce, withinTransaction: true)
                let restore = try prepare("UPDATE records SET revision=? WHERE id=?")
                defer { sqlite3_finalize(restore) }
                try check(sqlite3_bind_int64(restore, 1, Int64(snapshot.revision)))
                try bind(id.rawValue.uuidString, to: restore, at: 2); _ = try step(restore)
                try probe?(.indexRows)
            }
        }
        try transaction {
            let header = try prepare("UPDATE store_header SET normalization=?,runtime=?")
            defer { sqlite3_finalize(header) }
            try check(sqlite3_bind_int(header, 1, Int32(RememberedNameNormalization.version)))
            try bind(NameStoreFormat.runtime, to: header, at: 2); _ = try step(header)
        }
    }
}
