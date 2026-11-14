import Foundation
import SQLite3

internal struct StoredReferenceRow: Sendable {
    let revision: UInt64
    let access: Int
    let nonce: UUID
    let kind: NativeDocumentReference.Kind
    let volume: UUID
    let document: UInt32
    let hint: String
    let evidence: NativeDocumentReference?
}

extension NameIndexDatabase {
    static let referenceSchemaSQL = [
        "CREATE TABLE item_references (record INTEGER PRIMARY KEY REFERENCES records(record) ON DELETE CASCADE, revision INTEGER NOT NULL, access INTEGER NOT NULL, nonce TEXT NOT NULL, kind INTEGER NOT NULL, volume TEXT NOT NULL, document INTEGER NOT NULL, hint TEXT NOT NULL, evidence BLOB)",
        "CREATE UNIQUE INDEX active_document_reference ON item_references(volume,document)",
    ]
    var hasReferenceFormat: Bool { get throws { [2, 3, 4].contains(try scalar("PRAGMA user_version")) } }
    func pendingAccessRemovals() throws -> Int {
        try hasReferenceFormat ? scalar("SELECT count(*) FROM item_references WHERE access=1") : 0
    }

    func upgradeReferences() throws {
        guard try !hasReferenceFormat else { return }
        guard try pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
        try transaction {
            for sql in Self.referenceSchemaSQL { try exec(sql) }
            try exec("UPDATE store_header SET format=2")
            try exec("PRAGMA user_version=2")
            try boundary(.referenceUpgradeRows)
        }
        try probe?(.referenceUpgradeCommit)
    }
    func reference(_ id: RememberedItemID) throws -> StoredReferenceRow? {
        guard try hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        let query = try prepare("SELECT r.revision,r.access,r.nonce,r.kind,r.volume,r.document,r.hint,r.evidence FROM item_references r JOIN records n ON n.record=r.record WHERE n.id=? AND n.hidden=0")
        defer { sqlite3_finalize(query) }; try bind(id.rawValue.uuidString, to: query, at: 1)
        guard try step(query) else { return nil }
        return try decodeReference(query)
    }
    private func decodeReference(_ row: OpaquePointer) throws -> StoredReferenceRow {
        let revision = try positiveRevision(row, column: 0), access = try integer(row, column: 1)
        let nonceText = try text(row, column: 2), volumeText = try text(row, column: 4)
        let doc = try integer(row, column: 5), hint = try text(row, column: 6)
        guard (0...2).contains(access), let nonce = UUID(uuidString: nonceText), nonce.uuidString == nonceText,
              let kind = NativeDocumentReference.Kind(rawValue: try integer(row, column: 3)),
              let volume = UUID(uuidString: volumeText), volume.uuidString == volumeText,
              let document = UInt32(exactly: doc), document > 0,
              hint.utf8.count <= 8_192, hint.hasPrefix("/"), !hint.utf8.contains(0),
              URL(fileURLWithPath: hint).standardizedFileURL.path == hint else { throw NameStoreFailure.unsafe }
        let evidence: NativeDocumentReference?
        if access == 2 {
            guard sqlite3_column_type(row, 7) == SQLITE_NULL else { throw NameStoreFailure.unsafe }
            evidence = nil
        } else {
            guard sqlite3_column_type(row, 7) == SQLITE_BLOB else { throw NameStoreFailure.unsafe }
            let count = Int(sqlite3_column_bytes(row, 7))
            guard (1...131_072).contains(count), let pointer = sqlite3_column_blob(row, 7) else { throw NameStoreFailure.unsafe }
            evidence = try NativeDocumentReference(data: Data(bytes: pointer, count: count))
            guard let evidence, evidence.kind == kind, evidence.volume == volume,
                  evidence.document == document, evidence.path == hint else { throw NameStoreFailure.unsafe }
        }
        return StoredReferenceRow(revision: revision, access: access, nonce: nonce, kind: kind,
            volume: volume, document: document, hint: hint, evidence: evidence)
    }
    func validateReferences() throws {
        let query = try prepare("SELECT revision,access,nonce,kind,volume,document,hint,evidence FROM item_references")
        defer { sqlite3_finalize(query) }; var count = 0
        while try step(query) {
            count += 1; guard count <= NameStoreFormat.maximumRecords else { throw NameStoreFailure.unsafe }
            _ = try autoreleasepool { try decodeReference(query) }
        }
    }
    func referenceCollision(_ evidence: NativeDocumentReference, excluding id: RememberedItemID?) throws -> RememberedItemID? {
        let query = try prepare("SELECT n.id FROM item_references r JOIN records n ON n.record=r.record WHERE r.volume=? AND r.document=? AND n.hidden=0 AND n.id<>? LIMIT 1")
        defer { sqlite3_finalize(query) }; try bind(evidence.volume.uuidString, to: query, at: 1)
        try check(sqlite3_bind_int64(query, 2, Int64(evidence.document))); try bind(id?.rawValue.uuidString ?? "", to: query, at: 3)
        guard try step(query) else { return nil }
        guard let uuid = UUID(uuidString: try text(query, column: 0)) else { throw NameStoreFailure.unsafe }
        return RememberedItemID(uuid)
    }
    /// Exact active bindings only. The document pair uses the existing unique
    /// index; a path hint is a conservative ambiguity check, not identity.
    func activeReference(volume: UUID, document: UInt32) throws -> Bool {
        guard try hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        let query = try prepare("SELECT 1 FROM item_references r JOIN records n ON n.record=r.record WHERE r.volume=? AND r.document=? AND r.access=0 AND n.hidden=0 LIMIT 1")
        defer { sqlite3_finalize(query) }
        try bind(volume.uuidString, to: query, at: 1)
        try check(sqlite3_bind_int64(query, 2, Int64(document)))
        return try step(query)
    }
    func activeReferenceHint(_ path: String) throws -> Bool {
        guard try hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        let query = try prepare("SELECT 1 FROM item_references r JOIN records n ON n.record=r.record WHERE r.hint=? AND r.access=0 AND n.hidden=0 LIMIT 1")
        defer { sqlite3_finalize(query) }
        try bind(path, to: query, at: 1)
        return try step(query)
    }
    func saveReference(_ id: RememberedItemID, evidence: NativeDocumentReference, expected: UInt64?, nonce: UUID,
                       preservingMoveHandoffs: Bool = false) throws {
        let previous = try reference(id)
        guard previous?.revision == expected else { throw RememberedReferenceFailure.stale }
        if let collision = try referenceCollision(evidence, excluding: id) { throw RememberedReferenceFailure.alreadyRemembered(collision) }
        let revision = (previous?.revision ?? 0)
        guard revision < UInt64(Int64.max) else { throw NameIndexFailure.resourceLimit }
        let query = try prepare("INSERT INTO item_references(record,revision,access,nonce,kind,volume,document,hint,evidence) SELECT record,?,0,?,?,?,?,?,? FROM records WHERE id=? AND hidden=0 ON CONFLICT(record) DO UPDATE SET revision=excluded.revision,access=0,nonce=excluded.nonce,kind=excluded.kind,volume=excluded.volume,document=excluded.document,hint=excluded.hint,evidence=excluded.evidence")
        defer { sqlite3_finalize(query) }
        try check(sqlite3_bind_int64(query, 1, Int64(revision + 1))); try bind(nonce.uuidString, to: query, at: 2)
        try check(sqlite3_bind_int(query, 3, Int32(evidence.kind.rawValue))); try bind(evidence.volume.uuidString, to: query, at: 4)
        try check(sqlite3_bind_int64(query, 5, Int64(evidence.document))); try bind(evidence.path, to: query, at: 6)
        try bind(evidence.encoded(), to: query, at: 7); try bind(id.rawValue.uuidString, to: query, at: 8)
        _ = try step(query); guard sqlite3_changes(db) == 1 else { throw NameIndexFailure.missingRecord }
        if !preservingMoveHandoffs, try hasMoveFormat { try deleteMoveHandoffs(id) }
        try boundary(.referenceRows)
    }
    func disableReference(_ id: RememberedItemID, expected: UInt64, nonce: UUID) throws {
        guard expected < UInt64(Int64.max) else { throw NameIndexFailure.resourceLimit }
        try transaction {
            let query = try prepare("UPDATE item_references SET access=1,revision=revision+1,nonce=? WHERE record=(SELECT record FROM records WHERE id=? AND hidden=0) AND revision=? AND access=0")
            defer { sqlite3_finalize(query) }; try bind(nonce.uuidString, to: query, at: 1)
            try bind(id.rawValue.uuidString, to: query, at: 2); try check(sqlite3_bind_int64(query, 3, Int64(expected)))
            _ = try step(query); guard sqlite3_changes(db) == 1 else { throw RememberedReferenceFailure.stale }
            try boundary(.accessFenceRows)
        }
        try probe?(.accessFenceCommit)
    }
    func purgeDisabledReferences(_ id: RememberedItemID? = nil) throws {
        repeat {
        try transaction {
            let query = try prepare(id == nil ? "UPDATE item_references SET evidence=NULL,access=2 WHERE record IN (SELECT record FROM item_references WHERE access=1 LIMIT 256)"
                : "UPDATE item_references SET evidence=NULL,access=2 WHERE access=1 AND record=(SELECT record FROM records WHERE id=?)")
            defer { sqlite3_finalize(query) }
            if let id { try bind(id.rawValue.uuidString, to: query, at: 1) }
            _ = try step(query); try boundary(.accessPurgeRows)
            if try hasMoveFormat { try purgeDisabledMoveHandoffs() }
        }
        try probe?(.accessPurgeCommit)
        } while try id == nil && pendingAccessRemovals() > 0
    }
}
