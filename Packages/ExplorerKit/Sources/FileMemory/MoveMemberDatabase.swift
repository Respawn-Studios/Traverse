import FileOperations
import Foundation
import SQLite3

extension NameIndexDatabase {
    static let memberSchemaSQL = [
        "CREATE TABLE move_member_receipts (handoff TEXT PRIMARY KEY REFERENCES move_handoffs(id) ON DELETE CASCADE, receipt BLOB NOT NULL) WITHOUT ROWID",
        "CREATE INDEX references_by_hint ON item_references(hint,record) WHERE access=0",
    ]
    var hasMemberFormat: Bool { get throws { try scalar("PRAGMA user_version") == NameStoreFormat.memberSchema } }

    func upgradeMoveMembers() throws {
        guard try !hasMemberFormat else { return }
        guard try hasMoveFormat, try pendingForgetCount() == 0, try pendingAccessRemovals() == 0 else {
            throw NameStoreFailure.forgetPending
        }
        try transaction {
            for sql in Self.memberSchemaSQL { try exec(sql) }
            try exec("UPDATE store_header SET format=4")
            try exec("PRAGMA user_version=4")
            try boundary(.memberUpgradeRows)
        }
        try probe?(.memberUpgradeCommit)
    }

    func storeMemberReceipt(_ row: MoveHandoffRow, receipt: MoveReferenceReceipt) throws {
        guard try hasMemberFormat, row.phase == 0, receipt.ticket == row.ticket, row.ticket.isMember else {
            throw RememberedReferenceFailure.stale
        }
        let statement = try prepare("INSERT INTO move_member_receipts(handoff,receipt) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(row.id.uuidString, to: statement, at: 1)
        try bind(receipt.encoded(), to: statement, at: 2); _ = try step(statement)
    }

    // Two indexed ranges avoid an OR query falling back to a catalog scan.
    // IDs are opaque; saved paths select candidates and never grant access.
    func moveCandidates(root: URL, limit: Int) throws -> [RememberedItemID] {
        guard try hasMemberFormat, (1...2_049).contains(limit) else { throw NameStoreFailure.invalidRequest }
        var result: [RememberedItemID] = []
        for exact in [true, false] {
            let suffix = exact ? "r.hint=?" : "r.hint>=? AND r.hint<?"
            let query = try prepare("SELECT n.id FROM item_references r INDEXED BY references_by_hint JOIN records n ON n.record=r.record WHERE r.access=0 AND n.hidden=0 AND " + suffix + " ORDER BY r.hint,r.record LIMIT ?")
            defer { sqlite3_finalize(query) }
            let prefix = root.path == "/" ? "/" : root.path + "/"
            try bind(exact ? root.path : prefix, to: query, at: 1)
            if !exact { try bind(root.path == "/" ? "0" : root.path + "0", to: query, at: 2) }
            try check(sqlite3_bind_int(query, exact ? 2 : 3, Int32(limit - result.count)))
            while try step(query) {
                guard let id = UUID(uuidString: try text(query, column: 0)) else { throw NameStoreFailure.unsafe }
                result.append(RememberedItemID(id))
            }
            if result.count >= limit { break }
        }
        return result
    }
}

extension PersistentNameStore {
    /// Persist before native destination capture, so a later capture failure can
    /// reconcile this exact witness. Revoked/relinked rows never get recreated.
    public func retainMoveReceipt(_ handle: RememberedMoveHandoff,
                                  receipt: MoveReferenceReceipt) throws -> RememberedMoveHandoff {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireMoveWrite()
        let row = try moveRow(handle)
        guard row.ticket.isMember, row.ticket == receipt.ticket else { throw RememberedReferenceFailure.stale }
        if let existing = row.receipt {
            guard existing == receipt else { throw RememberedReferenceFailure.stale }
            return moveHandle(row, direction: handle.direction)
        }
        guard row.phase == 0, handle.direction == .forward,
              let current = try database.reference(row.item), current.access == 0,
              current.revision == row.expected else { throw RememberedReferenceFailure.stale }
        _ = try receipt.encoded()
        try moveWrite(rows: .memberReceiptRows, commit: .memberReceiptCommit) {
            try database.storeMemberReceipt(row, receipt: receipt)
        }
        guard let saved = try database.moveHandoff(row.id) else { throw RememberedReferenceFailure.stale }
        return moveHandle(saved, direction: .forward)
    }

    public func supportsMoveMembers() throws -> Bool {
        try requireOpen(); try catalog.validate(); return try database.hasMemberFormat
    }

    /// Discovery is bounded and metadata-only. Stale hints can miss candidates;
    /// callers freshly resolve every returned ID before admitting a file member.
    public func moveCandidateIDs(beneath roots: [URL], limit: Int = 2_048) throws -> (ids: [RememberedItemID], limited: Bool) {
        let lease = try activity?.begin(), use = try publication.beginDiscoveryUse()
        defer { withExtendedLifetime(lease) {}; withExtendedLifetime(use) {} }
        try requireOpen(); try catalog.validate()
        guard try database.hasMemberFormat, (1...2_048).contains(limit), roots.count <= 1_024,
              roots.allSatisfy({ $0.isFileURL && $0 == $0.standardizedFileURL && $0.path.hasPrefix("/") }) else {
            throw NameStoreFailure.invalidRequest
        }
        let cancellation = RememberedNameCancellation()
        let (token, _) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        let work = NameQueryExecution(budget: .init(), cancellation: cancellation)
        database.installProgress(work); defer { database.installProgress(nil) }
        var ids: [RememberedItemID] = [], seen = Set<RememberedItemID>(), limited = false
        for root in roots {
            guard work.check() else { throw NameIndexFailure.resourceLimit }
            let page = try database.moveCandidates(root: root, limit: limit - ids.count + 1)
            for id in page where seen.insert(id).inserted && publication.allows(id) && !references.isBlocked(id) {
                if ids.count == limit { limited = true; break }; ids.append(id)
            }
            if limited { break }
        }
        guard !cancellation.isCancelled else { throw NameIndexFailure.cancelled }
        try catalog.validate(); return (ids, limited)
    }
}
