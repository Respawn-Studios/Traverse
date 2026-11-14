import Foundation
import SQLite3

/// One non-main owner accesses this connection. The persistent initializer accepts
/// only an already-verified catalog lease; statements never escape that owner.
internal final class NameIndexDatabase: @unchecked Sendable {
    internal var db: OpaquePointer?
    internal static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    internal var probe: NameStoreProbe?
    internal var commitUncertain = false
    internal var qualificationFlushBeforeBoundary = false

    init(catalog: OwnedNameCatalog, action: NameStoreOpenAction, creating: Bool = false, vfs: String? = nil) throws {
        try openPersistent(catalog, action: action, creating: creating, vfs: vfs)
    }

    init() throws {
        let code = sqlite3_open_v2(":memory:", &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw NameIndexFailure.storage(code)
        }
        do {
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 32_768)
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16_384)
            try exec("PRAGMA trusted_schema=OFF")
            try exec("PRAGMA foreign_keys=ON")
            try exec("PRAGMA temp_store=MEMORY")
            try exec("PRAGMA page_size=4096")
            try exec("PRAGMA max_page_count=131072")
            guard try scalar("PRAGMA foreign_keys") == 1,
                  try scalar("PRAGMA page_size") == 4_096,
                  try scalar("PRAGMA max_page_count") == 131_072 else {
                throw NameIndexFailure.storage(SQLITE_ERROR)
            }
            try createSchema()
        } catch { close(); throw error }
    }

    deinit { close() }
    func close() { if let db { sqlite3_close(db) }; db = nil }

    func revision(_ id: RememberedItemID) throws -> UInt64? {
        let statement = try prepare("SELECT revision FROM records WHERE id=? AND hidden=0")
        defer { sqlite3_finalize(statement) }
        try bind(id.rawValue.uuidString, to: statement, at: 1)
        guard try step(statement) else { return nil }
        return try positiveRevision(statement, column: 0)
    }

    func save(id: RememberedItemID, names: AuthoredNames, expected: UInt64?,
              failAfterNames: Bool = false, nonce: UUID = UUID(), withinTransaction: Bool = false) throws {
        let fields = try NameProjection.fields(names)
        let sortKey = Data(RememberedNameNormalization.key(
            names.nickname ?? names.alternateNames.first ?? names.labels[0]).utf8)
        let body = { [self] in
            let number: Int64
            if let expected {
                guard expected < UInt64(Int64.max) else { throw NameIndexFailure.resourceLimit }
                let update = try prepare("UPDATE records SET revision=revision+1, sort_key=?, nonce=? WHERE id=? AND revision=? AND hidden=0")
                defer { sqlite3_finalize(update) }
                try bind(sortKey, to: update, at: 1)
                try bind(nonce.uuidString, to: update, at: 2)
                try bind(id.rawValue.uuidString, to: update, at: 3)
                try check(sqlite3_bind_int64(update, 4, Int64(expected)))
                _ = try step(update)
                guard sqlite3_changes(db) == 1 else { throw NameIndexFailure.staleEdit }
                number = try recordNumber(id)
                try deleteNames(number)
            } else {
                let insert = try prepare("INSERT INTO records(id,revision,sort_key,nonce,hidden) VALUES(?,1,?,?,0)")
                defer { sqlite3_finalize(insert) }
                try bind(id.rawValue.uuidString, to: insert, at: 1)
                try bind(sortKey, to: insert, at: 2)
                try bind(nonce.uuidString, to: insert, at: 3)
                _ = try step(insert)
                number = sqlite3_last_insert_rowid(db)
            }
            let insertName = try prepare("INSERT INTO names VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(insertName) }
            let insertKey = try prepare("INSERT INTO name_keys VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(insertKey) }
            for field in fields {
                sqlite3_reset(insertName); sqlite3_clear_bindings(insertName)
                try check(sqlite3_bind_int64(insertName, 1, number))
                try check(sqlite3_bind_int(insertName, 2, Int32(field.field.rawValue)))
                try check(sqlite3_bind_int(insertName, 3, Int32(field.ordinal)))
                try bind(field.original, to: insertName, at: 4)
                try bind(Data(field.literal.utf8), to: insertName, at: 5)
                try bind(Data(field.tolerant.utf8), to: insertName, at: 6)
                _ = try step(insertName)
                if failAfterNames { throw NameIndexFailure.storage(SQLITE_FULL) }
                for (variant, key, words) in [(0, field.literal, field.literalWords), (1, field.tolerant, field.tolerantWords)] {
                    for (shape, keys) in [(0, [key]), (1, words)] {
                        for value in keys {
                            sqlite3_reset(insertKey); sqlite3_clear_bindings(insertKey)
                            try check(sqlite3_bind_int(insertKey, 1, Int32(variant)))
                            try check(sqlite3_bind_int(insertKey, 2, Int32(shape)))
                            try bind(Data(value.utf8), to: insertKey, at: 3)
                            try check(sqlite3_bind_int64(insertKey, 4, number))
                            try check(sqlite3_bind_int(insertKey, 5, Int32(field.field.rawValue)))
                            try check(sqlite3_bind_int(insertKey, 6, Int32(field.ordinal)))
                            _ = try step(insertKey)
                        }
                    }
                }
            }
            try boundary(.saveRows)
        }
        if withinTransaction { try body() } else { try transaction(body) }
    }

    func remove(_ id: RememberedItemID) throws {
        try transaction {
            let statement = try prepare("DELETE FROM records WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try bind(id.rawValue.uuidString, to: statement, at: 1)
            _ = try step(statement)
        }
    }

    func snapshot(_ id: RememberedItemID) throws -> RememberedNamesSnapshot {
        let statement = try prepare("SELECT r.revision,n.field,n.original,n.ordinal FROM records AS r JOIN names AS n ON n.record=r.record WHERE r.id=? AND r.hidden=0 ORDER BY n.field,n.ordinal")
        defer { sqlite3_finalize(statement) }
        try bind(id.rawValue.uuidString, to: statement, at: 1)
        var revision: UInt64?
        var nickname: String?
        var alternates: [String] = [], labels: [String] = []
        while try step(statement) {
            let loadedRevision = try positiveRevision(statement, column: 0)
            guard revision == nil || revision == loadedRevision else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
            revision = loadedRevision
            let ordinal = try integer(statement, column: 3)
            guard (0..<16).contains(ordinal) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
            let value = try text(statement, column: 2)
            switch sqlite3_column_int(statement, 1) {
            case 0:
                guard nickname == nil, ordinal == 0 else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
                nickname = value
            case 1:
                guard ordinal == alternates.count else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
                alternates.append(value)
            case 2:
                guard ordinal == labels.count else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
                labels.append(value)
            default: throw NameIndexFailure.storage(SQLITE_CORRUPT)
            }
        }
        guard let revision else { throw NameIndexFailure.missingRecord }
        return RememberedNamesSnapshot(id: id, revision: revision,
            names: try AuthoredNames(nickname: nickname, alternateNames: alternates, labels: labels))
    }

    struct Hit {
        let id: RememberedItemID
        let field: RememberedNameField
        let ordinal: Int
        let original: String
        let literal: String
        let tolerant: String
        let sortKey: Data
    }

    struct Lane {
        let variant: Int
        let shape: Int
        let key: Data
        let equality: Bool
        let fields: Set<RememberedNameField>
        var sql: String {
            "SELECT r.id,n.field,n.ordinal,n.original,n.literal,n.tolerant,r.sort_key FROM name_keys AS k JOIN names AS n ON n.record=k.record AND n.field=k.field AND n.ordinal=k.ordinal JOIN records AS r ON r.record=k.record WHERE k.variant=? AND k.shape=? AND k.value "
            + (equality ? "=?" : ">=? AND k.value<?")
            + " AND r.hidden=0 AND k.field IN (?,?,?) ORDER BY k.value,k.record,k.field,k.ordinal LIMIT ?"
        }
    }

    func enumerate(_ lane: Lane, limit: Int, visit: (Hit) throws -> Bool) throws {
        let statement = try prepare(lane.sql)
        defer { sqlite3_finalize(statement) }
        try bindLane(lane, limit: limit, statement: statement)
        while try step(statement) {
            guard let uuid = UUID(uuidString: try text(statement, column: 0)),
                  let field = RememberedNameField(rawValue: Int(sqlite3_column_int(statement, 1))) else {
                throw NameIndexFailure.storage(SQLITE_CORRUPT)
            }
            let hit = Hit(id: RememberedItemID(uuid), field: field, ordinal: try integer(statement, column: 2),
                original: try text(statement, column: 3), literal: try utf8(statement, column: 4),
                tolerant: try utf8(statement, column: 5), sortKey: try blob(statement, column: 6))
            if try !visit(hit) { break }
        }
    }

    private static let probeSQL = "SELECT 1 FROM name_keys AS k WHERE k.variant=? AND k.shape=? AND k.value>=? AND k.value<? AND k.field IN (?,?,?) LIMIT ?"

    func queryPlan(_ lane: Lane, probe: Bool = false) throws -> [String] {
        let statement = try prepare("EXPLAIN QUERY PLAN " + (probe ? Self.probeSQL : lane.sql))
        defer { sqlite3_finalize(statement) }
        try bindLane(lane, limit: 64, statement: statement)
        var result: [String] = []
        while try step(statement) { result.append(try text(statement, column: 3)) }
        return result
    }

    /// A bounded selectivity probe, not COUNT(*) over an entire word range.
    /// Its actual returned postings are charged to the same query budget.
    func probe(_ lane: Lane, limit: Int) throws -> Int {
        let statement = try prepare(Self.probeSQL)
        defer { sqlite3_finalize(statement) }
        try bindLane(lane, limit: limit, statement: statement)
        var count = 0
        while try step(statement) { count += 1 }
        return count
    }

    func installProgress(_ state: NameQueryExecution?) {
        if let state {
            sqlite3_progress_handler(db, 1_000, { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<NameQueryExecution>.fromOpaque(pointer).takeUnretainedValue().advance() ? 0 : 1
            }, Unmanaged.passUnretained(state).toOpaque())
        } else { sqlite3_progress_handler(db, 0, nil, nil) }
    }

    struct Statistics: Sendable {
        let records: Int
        let names: Int
        let postings: Int
        let bytes: Int
        let sqliteVersion: String
    }
    func statistics() throws -> Statistics {
        try Statistics(records: scalar("SELECT count(*) FROM records"), names: scalar("SELECT count(*) FROM names"),
            postings: scalar("SELECT count(*) FROM name_keys"),
            bytes: scalar("PRAGMA page_count") * scalar("PRAGMA page_size"), sqliteVersion: String(cString: sqlite3_libversion()))
    }

    private func recordNumber(_ id: RememberedItemID) throws -> Int64 {
        let statement = try prepare("SELECT record FROM records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.rawValue.uuidString, to: statement, at: 1)
        guard try step(statement) else { throw NameIndexFailure.missingRecord }
        return sqlite3_column_int64(statement, 0)
    }
    private func deleteNames(_ number: Int64) throws {
        let statement = try prepare("DELETE FROM names WHERE record=?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, number))
        _ = try step(statement)
    }
    internal func transaction(beforeCommit: (() throws -> Void)? = nil, _ body: () throws -> Void) throws {
        commitUncertain = false
        try exec("BEGIN")
        var committing = false
        do { try body(); try beforeCommit?(); committing = true; try exec("COMMIT") }
        catch {
            // A failed COMMIT or failed rollback cannot be advertised as the
            // previous value surviving. The owner suspends writes until reopen.
            var rolledBack = false
            if sqlite3_get_autocommit(db) == 0 {
                do { try exec("ROLLBACK"); rolledBack = sqlite3_get_autocommit(db) != 0 } catch { }
            }
            commitUncertain = committing || !rolledBack
            throw error
        }
    }
    private func bindLane(_ lane: Lane, limit: Int, statement: OpaquePointer) throws {
        try check(sqlite3_bind_int(statement, 1, Int32(lane.variant)))
        try check(sqlite3_bind_int(statement, 2, Int32(lane.shape)))
        try bind(lane.key, to: statement, at: 3)
        var position: Int32 = 4
        if !lane.equality {
            try bind(RememberedNameNormalization.upperBound(lane.key), to: statement, at: position)
            position += 1
        }
        for field in RememberedNameField.allCases {
            try check(sqlite3_bind_int(statement, position, fieldsValue(lane, field)))
            position += 1
        }
        try check(sqlite3_bind_int(statement, position, Int32(limit)))
    }
    private func fieldsValue(_ lane: Lane, _ field: RememberedNameField) -> Int32 {
        lane.fields.contains(field) ? Int32(field.rawValue) : -1
    }
    internal func exec(_ sql: String) throws {
        guard db != nil else { throw NameIndexFailure.closed }
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }
    internal func prepare(_ sql: String) throws -> OpaquePointer {
        guard db != nil else { throw NameIndexFailure.closed }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw NameIndexFailure.storage(code)
        }
        return statement
    }
    internal func step(_ statement: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw NameIndexFailure.storage(code) }
        return false
    }
    internal func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw NameIndexFailure.storage(code) }
    }
    internal func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try value.withCString { try check(sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transient)) }
    }
    internal func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        try value.withUnsafeBytes { try check(sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient)) }
    }
    internal func integer(_ statement: OpaquePointer, column: Int32) throws -> Int {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        return Int(sqlite3_column_int64(statement, column))
    }
    internal func positiveRevision(_ statement: OpaquePointer, column: Int32) throws -> UInt64 {
        let value = try integer(statement, column: column)
        guard value > 0 else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        return UInt64(value)
    }
    internal func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard (1...8_192).contains(count),
              let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8),
              !value.utf8.contains(0) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        return value
    }
    internal func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let pointer = sqlite3_column_blob(statement, column) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard (1...2_048).contains(count) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        return Data(bytes: pointer, count: count)
    }
    internal func utf8(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard let value = String(data: try blob(statement, column: column), encoding: .utf8) else {
            throw NameIndexFailure.storage(SQLITE_CORRUPT)
        }
        return value
    }
    internal func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try step(statement) else { throw NameIndexFailure.storage(SQLITE_CORRUPT) }
        return try integer(statement, column: 0)
    }
}

/// Progress callbacks and traversal run synchronously on the same actor. Only
/// the separate cancellation token is shared with a requesting thread.
internal final class NameQueryExecution {
    let cancellation: RememberedNameCancellation
    private let deadline: UInt64
    private let maximumInstructions: Int
    private(set) var instructions = 0
    private(set) var coverage: RememberedNameCoverage?
    init(budget: RememberedNameQueryBudget, cancellation: RememberedNameCancellation) {
        self.cancellation = cancellation
        maximumInstructions = budget.maximumVMInstructions
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budget.maximumDuration * 1_000_000_000)
    }
    func advance() -> Bool {
        instructions += 1_000
        if instructions >= maximumInstructions { coverage = .workLimit; return false }
        return check()
    }
    func check() -> Bool {
        if cancellation.isCancelled { return false }
        if DispatchTime.now().uptimeNanoseconds >= deadline { coverage = .timeLimit; return false }
        return coverage == nil
    }
}
