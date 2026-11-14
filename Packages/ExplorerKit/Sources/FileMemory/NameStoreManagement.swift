import Darwin
import Foundation
import SQLite3

/// Numeric observations only. Stored bindings are not a fresh availability scan.
public struct NameStoreManagement: Sendable, Equatable {
    public let savedItems: Int
    public let nicknames: Int
    public let alternateNames: Int
    public let labels: Int
    public let storedReferences: Int
    public let accessRemoved: Int
    public let pendingAccessRemovals: Int
    public let pendingForget: Int
    public let pendingMoveHandoffs: Int
    public let databaseLogicalBytes: Int64
    public let databaseAllocatedBytes: Int64
    public let journalLogicalBytes: Int64
    public let journalAllocatedBytes: Int64
    public let sqlitePageBytes: Int64
    public let sqliteFreePageBytes: Int64
    /// Pages assigned to derived search tables/indexes; unavailable on systems
    /// without SQLite's read-only dbstat facility. Not separately reclaimable.
    public let derivedIndexPageBytes: Int64?
}

extension PersistentNameStore {
    public func management() throws -> NameStoreManagement {
        try requireOpen()
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try catalog.validate()
        let files = try catalog.managementBytes()
        func count(_ sql: String) throws -> Int { try database.scalar(sql) }
        let hasReferences = try database.hasReferenceFormat
        let hasMoves = try database.hasMoveFormat
        let pageSize = try count("PRAGMA page_size")
        var indexBytes: Int64?
        if sqlite3_compileoption_used("ENABLE_DBSTAT_VTAB") != 0 {
            indexBytes = Int64(try count("SELECT coalesce(sum(pgsize),0) FROM dbstat WHERE name IN ('name_keys','keys_by_name')"))
        }
        let result = try NameStoreManagement(
            savedItems: count("SELECT count(*) FROM records WHERE hidden=0"),
            nicknames: count("SELECT count(*) FROM names JOIN records USING(record) WHERE hidden=0 AND field=0"),
            alternateNames: count("SELECT count(*) FROM names JOIN records USING(record) WHERE hidden=0 AND field=1"),
            labels: count("SELECT count(*) FROM names JOIN records USING(record) WHERE hidden=0 AND field=2"),
            storedReferences: hasReferences ? count("SELECT count(*) FROM item_references JOIN records USING(record) WHERE hidden=0") : 0,
            accessRemoved: hasReferences ? count("SELECT count(*) FROM item_references JOIN records USING(record) WHERE hidden=0 AND access=2") : 0,
            pendingAccessRemovals: hasReferences ? database.pendingAccessRemovals() : 0,
            pendingForget: database.pendingForgetCount(),
            pendingMoveHandoffs: hasMoves ? count("SELECT count(*) FROM move_handoffs WHERE phase IN (0,2)") : 0,
            databaseLogicalBytes: files.database.0, databaseAllocatedBytes: files.database.1,
            journalLogicalBytes: files.journal.0, journalAllocatedBytes: files.journal.1,
            sqlitePageBytes: Int64(count("PRAGMA page_count")) * Int64(pageSize),
            sqliteFreePageBytes: Int64(count("PRAGMA freelist_count")) * Int64(pageSize),
            derivedIndexPageBytes: indexBytes)
        try catalog.validate(); return result
    }
}
