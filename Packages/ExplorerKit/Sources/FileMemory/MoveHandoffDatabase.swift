import FileOperations
import Foundation
import SQLite3

internal struct MoveHandoffRow: Sendable {
    let id: UUID
    let item: RememberedItemID
    let phase: Int // pending Move, applied Move, pending Undo, applied Undo
    let expected: UInt64
    let nonce: UUID
    let ticket: MoveReferenceTicket
    let original: NativeDocumentReference
    var receipt: MoveReferenceReceipt? = nil
}

extension NameIndexDatabase {
    static let moveSchemaSQL = [
        "CREATE TABLE move_handoffs (id TEXT PRIMARY KEY, record INTEGER NOT NULL REFERENCES records(record) ON DELETE CASCADE, operation TEXT NOT NULL, unit TEXT NOT NULL, phase INTEGER NOT NULL, expected INTEGER NOT NULL, nonce TEXT NOT NULL, ticket BLOB NOT NULL, original BLOB NOT NULL, UNIQUE(record,operation,unit))",
        "CREATE INDEX handoffs_by_operation ON move_handoffs(operation,phase)",
        "CREATE UNIQUE INDEX pending_handoff_by_item ON move_handoffs(record) WHERE phase IN (0,2)",
    ]
    var hasMoveFormat: Bool { get throws { [NameStoreFormat.moveSchema, NameStoreFormat.memberSchema].contains(try scalar("PRAGMA user_version")) } }
    func upgradeMoveContinuity() throws {
        guard try !hasMoveFormat else { return }
        guard try hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        guard try pendingForgetCount() == 0, try pendingAccessRemovals() == 0 else { throw NameStoreFailure.forgetPending }
        try transaction {
            for sql in Self.moveSchemaSQL { try exec(sql) }
            try exec("UPDATE store_header SET format=3")
            try exec("PRAGMA user_version=3")
            try boundary(.moveUpgradeRows)
        }
        try probe?(.moveUpgradeCommit)
    }
    private static let handoffColumns = "h.id,n.id,h.phase,h.expected,h.nonce,h.operation,h.unit,h.ticket,h.original"
    private func handoffSelection() throws -> (columns: String, joins: String) {
        try hasMemberFormat ? (Self.handoffColumns + ",w.receipt", " LEFT JOIN move_member_receipts w ON w.handoff=h.id")
            : (Self.handoffColumns + ",NULL", "")
    }
    func moveHandoff(_ id: UUID) throws -> MoveHandoffRow? {
        guard try hasMoveFormat else { throw NameStoreFailure.continuityUpdateRequired }
        let selection = try handoffSelection()
        let query = try prepare("SELECT \(selection.columns) FROM move_handoffs h JOIN records n ON n.record=h.record" + selection.joins + " WHERE h.id=? AND n.hidden=0")
        defer { sqlite3_finalize(query) }; try bind(id.uuidString, to: query, at: 1)
        return try step(query) ? decodeHandoff(query) : nil
    }
    func hasPendingMoveHandoff(_ id: RememberedItemID) throws -> Bool {
        guard try hasMoveFormat else { return false }
        let query = try prepare("SELECT EXISTS(SELECT 1 FROM move_handoffs h JOIN records n ON n.record=h.record WHERE n.id=? AND h.phase IN (0,2))")
        defer { sqlite3_finalize(query) }; try bind(id.rawValue.uuidString, to: query, at: 1)
        guard try step(query) else { throw NameStoreFailure.unsafe }
        return try integer(query, column: 0) != 0
    }
    private func decodeHandoff(_ query: OpaquePointer) throws -> MoveHandoffRow {
        let idText = try text(query, column: 0), itemText = try text(query, column: 1)
        let nonceText = try text(query, column: 4)
        guard let id = UUID(uuidString: idText), id.uuidString == idText,
              let item = UUID(uuidString: itemText), item.uuidString == itemText,
              let nonce = UUID(uuidString: nonceText), nonce.uuidString == nonceText else { throw NameStoreFailure.unsafe }
        let phase = try integer(query, column: 2), expected = try positiveRevision(query, column: 3)
        guard (0...3).contains(phase) else { throw NameStoreFailure.unsafe }
        let ticketData = try moveBlob(query, column: 7, limit: 32_768)
        let originalData = try moveBlob(query, column: 8, limit: 131_072)
        let ticket = try MoveReferenceTicket(encoded: ticketData), original = try NativeDocumentReference(data: originalData)
        guard try text(query, column: 5) == ticket.operationID.uuidString,
              try text(query, column: 6) == ticket.unitID.uuidString, original.path == ticket.source.path else {
            throw NameStoreFailure.unsafe
        }
        let receipt: MoveReferenceReceipt?
        if sqlite3_column_type(query, 9) == SQLITE_NULL { receipt = nil }
        else {
            receipt = try MoveReferenceReceipt(encoded: moveBlob(query, column: 9, limit: 65_536))
            guard receipt?.ticket == ticket else { throw NameStoreFailure.unsafe }
        }
        if ticket.isMember {
            guard try hasMemberFormat, phase == 0 || receipt != nil else { throw NameStoreFailure.unsafe }
        }
        return MoveHandoffRow(id: id, item: RememberedItemID(item), phase: phase,
                              expected: expected, nonce: nonce, ticket: ticket, original: original, receipt: receipt)
    }
    private func moveBlob(_ query: OpaquePointer, column: Int32, limit: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(query, column))
        guard sqlite3_column_type(query, column) == SQLITE_BLOB, (1...limit).contains(count),
              let pointer = sqlite3_column_blob(query, column) else { throw NameStoreFailure.unsafe }
        return Data(bytes: pointer, count: count)
    }
    func insertMoveHandoff(_ row: MoveHandoffRow) throws {
        guard try scalar("SELECT count(*) FROM move_handoffs") < NameStoreFormat.maximumRecords else { throw NameStoreFailure.quota }
        let query = try prepare("INSERT INTO move_handoffs(id,record,operation,unit,phase,expected,nonce,ticket,original) SELECT ?,record,?,?,0,?,?,?,? FROM records WHERE id=? AND hidden=0")
        defer { sqlite3_finalize(query) }
        try bind(row.id.uuidString, to: query, at: 1)
        try bind(row.ticket.operationID.uuidString, to: query, at: 2)
        try bind(row.ticket.unitID.uuidString, to: query, at: 3)
        try check(sqlite3_bind_int64(query, 4, Int64(row.expected)))
        try bind(row.nonce.uuidString, to: query, at: 5)
        try bind(row.ticket.encoded(), to: query, at: 6)
        try bind(row.original.encoded(), to: query, at: 7)
        try bind(row.item.rawValue.uuidString, to: query, at: 8)
        _ = try step(query); guard sqlite3_changes(db) == 1 else { throw RememberedReferenceFailure.stale }
    }
    func advanceMoveHandoff(_ row: MoveHandoffRow, to phase: Int, expected: UInt64, nonce: UUID) throws {
        let query = try prepare("UPDATE move_handoffs SET phase=?,expected=?,nonce=? WHERE id=? AND phase=? AND expected=? AND nonce=?")
        defer { sqlite3_finalize(query) }
        try check(sqlite3_bind_int(query, 1, Int32(phase)))
        try check(sqlite3_bind_int64(query, 2, Int64(expected)))
        try bind(nonce.uuidString, to: query, at: 3); try bind(row.id.uuidString, to: query, at: 4)
        try check(sqlite3_bind_int(query, 5, Int32(row.phase))); try check(sqlite3_bind_int64(query, 6, Int64(row.expected)))
        try bind(row.nonce.uuidString, to: query, at: 7)
        _ = try step(query); guard sqlite3_changes(db) == 1 else { throw RememberedReferenceFailure.stale }
    }
    func validateMoveHandoffs() throws {
        let selection = try handoffSelection()
        let query = try prepare("SELECT \(selection.columns) FROM move_handoffs h JOIN records n ON n.record=h.record" + selection.joins)
        defer { sqlite3_finalize(query) }; var count = 0
        while try step(query) {
            count += 1; guard count <= NameStoreFormat.maximumRecords else { throw NameStoreFailure.quota }
            _ = try autoreleasepool { try decodeHandoff(query) }
        }
    }
    func deleteMoveHandoffs(_ id: RememberedItemID) throws {
        let query = try prepare("DELETE FROM move_handoffs WHERE record=(SELECT record FROM records WHERE id=?)")
        defer { sqlite3_finalize(query) }; try bind(id.rawValue.uuidString, to: query, at: 1); _ = try step(query)
    }
    func purgeDisabledMoveHandoffs() throws {
        try exec("DELETE FROM move_handoffs WHERE record IN (SELECT record FROM item_references WHERE access<>0)")
    }
    func pendingMoveHandoffIDs(limit: Int, item: RememberedItemID? = nil) throws -> [UUID] {
        guard try hasMoveFormat, (1...128).contains(limit) else { throw NameStoreFailure.invalidRequest }
        let query = try prepare("SELECT h.id FROM move_handoffs h JOIN records n ON n.record=h.record JOIN item_references r ON r.record=n.record WHERE n.hidden=0 AND r.access=0 AND h.phase IN (0,2)" + (item == nil ? "" : " AND n.id=?") + " ORDER BY h.id LIMIT ?")
        defer { sqlite3_finalize(query) }
        if let item { try bind(item.rawValue.uuidString, to: query, at: 1) }
        try check(sqlite3_bind_int(query, item == nil ? 1 : 2, Int32(limit)))
        var ids: [UUID] = []
        while try step(query) {
            guard let id = UUID(uuidString: try text(query, column: 0)) else { throw NameStoreFailure.unsafe }; ids.append(id)
        }
        return ids
    }
    func moveHandoffIDs(operation: UUID, limit: Int, after: UUID?) throws -> [UUID] {
        guard try hasMoveFormat, (1...128).contains(limit) else { throw NameStoreFailure.invalidRequest }
        let query = try prepare("SELECT h.id FROM move_handoffs h JOIN records n ON n.record=h.record JOIN item_references r ON r.record=n.record WHERE h.operation=? AND n.hidden=0 AND r.access=0 AND h.id>? ORDER BY h.id LIMIT ?")
        defer { sqlite3_finalize(query) }; try bind(operation.uuidString, to: query, at: 1)
        try bind(after?.uuidString ?? "", to: query, at: 2)
        try check(sqlite3_bind_int(query, 3, Int32(limit)))
        var ids: [UUID] = []
        while try step(query) {
            guard let id = UUID(uuidString: try text(query, column: 0)) else { throw NameStoreFailure.unsafe }; ids.append(id)
        }
        return ids
    }
    func deleteUnstartedMove(_ row: MoveHandoffRow) throws {
        let query = try prepare("DELETE FROM move_handoffs WHERE id=? AND phase=0 AND expected=? AND nonce=?")
        defer { sqlite3_finalize(query) }; try bind(row.id.uuidString, to: query, at: 1)
        try check(sqlite3_bind_int64(query, 2, Int64(row.expected))); try bind(row.nonce.uuidString, to: query, at: 3)
        _ = try step(query); guard sqlite3_changes(db) == 1 else { throw RememberedReferenceFailure.stale }
    }
}
