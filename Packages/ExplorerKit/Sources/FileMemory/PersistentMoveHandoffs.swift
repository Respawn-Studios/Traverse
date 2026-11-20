import FileOperations
import Foundation

/// Opaque catalog correlation only. No authored text or native grants escape.
public struct RememberedMoveHandoff: Sendable, Equatable {
    public let id: UUID
    public let itemID: RememberedItemID
    public let ticket: MoveReferenceTicket
    public let direction: MoveReferenceDirection
    public let receipt: MoveReferenceReceipt?
    internal let catalogID: UUID
}
public enum RememberedMoveOutcome: Sendable, Equatable { case applied, alreadyApplied }

extension PersistentNameStore {
    public func supportsMoveContinuity() throws -> Bool {
        try requireOpen(); try catalog.validate(); return try database.hasMoveFormat
    }
    public func retainsMoveHandoff(_ handle: RememberedMoveHandoff) throws -> Bool {
        try requireOpen(); try catalog.validate()
        do { _ = try moveRow(handle); return true }
        catch RememberedReferenceFailure.stale { return false }
    }

    /// Explicit reconciliation after cancellation before a file record existed.
    /// Remove only this pending association; the verified original reference and
    /// every authored field remain as they are.
    public func retireUnstartedMove(_ handle: RememberedMoveHandoff, evidence: UnstartedMoveEvidence) async throws {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireMoveWrite()
        let row = try moveRow(handle)
        guard row.phase == 0, evidence.ticket == row.ticket else { throw RememberedReferenceFailure.stale }
        _ = try requireMoveReference(row)
        let use = try publication.beginReferenceUse(row.item), request = try references.begin(row.item)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        let observed = try await referenceReader.capture(row.ticket.source, scope: row.original.scope,
            moveSource: row.ticket, cancellation: request.cancellation)
        try requireMoveWrite()
        guard references.current(request), publication.allows(row.item),
              observed.reference.volume == row.original.volume, observed.reference.document == row.original.document,
              observed.reference.kind == row.original.kind else { throw RememberedReferenceFailure.stale }
        _ = try requireMoveReference(row)
        try moveWrite(rows: .moveReferenceRows, commit: .moveReferenceCommit) { try database.deleteUnstartedMove(row) }
        references.invalidate(row.item)
    }

    public func prepareMoveHandoff(_ id: RememberedItemID, ticket: MoveReferenceTicket) async throws -> RememberedMoveHandoff {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireMoveWrite()
        if ticket.isMember, try !database.hasMemberFormat { throw NameStoreFailure.continuityUpdateRequired }
        guard try !database.hasPendingMoveHandoff(id) else { throw NameStoreFailure.busy }
        guard publication.allows(id), !references.isBlocked(id), !references.hasRemoval(id),
              let previous = try database.reference(id), previous.access == 0, let stored = previous.evidence else {
            throw RememberedReferenceFailure.stale
        }
        let use = try publication.beginReferenceUse(id), request = try references.begin(id)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        let source = try await referenceReader.capture(ticket.source, scope: stored.scope,
            moveSource: ticket, cancellation: request.cancellation)
        try requireMoveWrite()
        guard references.current(request), publication.allows(id),
              try !database.hasPendingMoveHandoff(id),
              try database.reference(id)?.revision == previous.revision,
              source.reference.volume == stored.volume, source.reference.document == stored.document,
              source.reference.kind == stored.kind else { throw RememberedReferenceFailure.stale }
        let nonce = UUID()
        let row = MoveHandoffRow(id: nonce, item: id, phase: 0, expected: previous.revision,
                                nonce: nonce, ticket: ticket, original: source.reference)
        try moveWrite(rows: .moveIntentRows, commit: .moveIntentCommit) { try database.insertMoveHandoff(row) }
        references.invalidate(id)
        return moveHandle(row, direction: .forward)
    }

    /// Called before an explicit file Undo. Does not Undo files. New authored
    /// revisions are allowed; a newer reference/Relink is never overwritten.
    public func prepareMoveUndo(_ handle: RememberedMoveHandoff,
                                evidence: MoveReferenceEvidence) async throws -> RememberedMoveHandoff {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireMoveWrite()
        let row = try moveRow(handle)
        guard row.phase == 1, evidence.direction == .forward, evidence.ticket == row.ticket else {
            throw RememberedReferenceFailure.stale
        }
        let use = try publication.beginReferenceUse(row.item), request = try references.begin(row.item)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        guard let currentRow = try database.reference(row.item), currentRow.access == 0,
              let current = currentRow.evidence else { throw RememberedReferenceFailure.stale }
        let observed = try await referenceReader.capture(evidence.location, scope: current.scope,
            movedObject: evidence, cancellation: request.cancellation)
        try requireMoveWrite()
        guard references.current(request), publication.allows(row.item),
              try database.moveHandoff(row.id)?.phase == 1,
              observed.reference.volume == current.volume, observed.reference.document == current.document else {
            throw RememberedReferenceFailure.stale
        }
        guard try database.reference(row.item)?.revision == currentRow.revision else { throw RememberedReferenceFailure.stale }
        let nonce = UUID()
        try moveWrite(rows: .moveUndoIntentRows, commit: .moveUndoIntentCommit) {
            try database.advanceMoveHandoff(row, to: 2, expected: currentRow.revision, nonce: nonce)
        }
        references.invalidate(row.item)
        return moveHandle(row, direction: .undo)
    }

    /// Only opaque committed engine evidence can advance a handoff. Native
    /// capture rechecks its exact object and parent around bookmark work.
    public func applyMoveHandoff(_ handle: RememberedMoveHandoff, evidence: MoveReferenceEvidence,
                                allowDocumentFollowing: Bool = false) async throws -> RememberedMoveOutcome {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireMoveWrite()
        let row = try moveRow(handle)
        guard !row.ticket.isMember || row.receipt != nil else { throw RememberedReferenceFailure.stale }
        guard evidence.ticket == row.ticket, evidence.direction == handle.direction else { throw RememberedReferenceFailure.stale }
        let pending = handle.direction == .forward ? 0 : 2
        if row.phase == pending + 1 {
            guard let current = try database.reference(row.item), current.access == 0,
                  current.revision == row.expected, current.nonce == row.nonce else { throw RememberedReferenceFailure.stale }
            return .alreadyApplied // no native tracking or duplicate write on lost acknowledgement
        }
        guard row.phase == pending else { throw RememberedReferenceFailure.stale }
        _ = try requireMoveReference(row)
        let use = try publication.beginReferenceUse(row.item), request = try references.begin(row.item)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        let observed = try await referenceReader.capture(evidence.location, scope: row.original.scope,
            allowDocumentFollowing: allowDocumentFollowing, movedObject: evidence, cancellation: request.cancellation)
        try requireMoveWrite()
        guard references.current(request), publication.allows(row.item),
              try database.moveHandoff(row.id)?.phase == pending,
              observed.reference.kind == row.original.kind else { throw RememberedReferenceFailure.stale }
        if handle.direction == .undo {
            guard observed.reference.volume == row.original.volume, observed.reference.document == row.original.document else {
                throw RememberedReferenceFailure.stale
            }
        }
        _ = try requireMoveReference(row)
        try moveWrite(rows: .moveReferenceRows, commit: .moveReferenceCommit) {
            try database.saveReference(row.item, evidence: observed.reference, expected: row.expected,
                nonce: row.nonce, preservingMoveHandoffs: true)
            try database.advanceMoveHandoff(row, to: pending + 1, expected: row.expected + 1, nonce: row.nonce)
        }
        references.invalidate(row.item)
        return .applied
    }

    /// Passive enumeration reveals work only. The caller must explicitly ask
    /// the file engine for fresh evidence before applying any returned handle.
    public func pendingMoveHandoffs(limit: Int = 64) throws -> [RememberedMoveHandoff] {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard try !database.hasAllFence() else { return [] }
        return try database.pendingMoveHandoffIDs(limit: limit).compactMap { id in
            guard let row = try database.moveHandoff(id), publication.allows(row.item), !references.isBlocked(row.item) else { return nil }
            return moveHandle(row, direction: row.phase == 0 ? .forward : .undo)
        }
    }
    /// Indexed lookup for an explicit history operation, including its completed
    /// association after reopening. No full-catalog/path crawl is hidden in Undo.
    public func moveHandoffs(for operationID: UUID, limit: Int = 64, after: UUID? = nil) throws -> [RememberedMoveHandoff] {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard try !database.hasAllFence() else { return [] }
        return try database.moveHandoffIDs(operation: operationID, limit: limit, after: after).compactMap { id in
            guard let row = try database.moveHandoff(id), publication.allows(row.item), !references.isBlocked(row.item) else { return nil }
            return moveHandle(row, direction: row.phase < 2 ? .forward : .undo)
        }
    }
    public func pendingMoveHandoff(for item: RememberedItemID) throws -> RememberedMoveHandoff? {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard try !database.hasAllFence(), publication.allows(item), !references.isBlocked(item),
              let id = try database.pendingMoveHandoffIDs(limit: 1, item: item).first,
              let row = try database.moveHandoff(id) else { return nil }
        return moveHandle(row, direction: row.phase == 0 ? .forward : .undo)
    }
    internal func requireMoveWrite() throws {
        try requireWrite()
        guard try database.hasMoveFormat else { throw NameStoreFailure.continuityUpdateRequired }
    }
    internal func moveRow(_ handle: RememberedMoveHandoff) throws -> MoveHandoffRow {
        guard handle.catalogID == catalog.storeID, publication.allows(handle.itemID), !references.isBlocked(handle.itemID),
              !references.hasRemoval(handle.itemID), let row = try database.moveHandoff(handle.id),
              row.item == handle.itemID, row.ticket == handle.ticket else { throw RememberedReferenceFailure.stale }
        return row
    }
    private func requireMoveReference(_ row: MoveHandoffRow) throws -> NativeDocumentReference {
        guard publication.allows(row.item), !references.isBlocked(row.item), !references.hasRemoval(row.item),
              let current = try database.reference(row.item), current.access == 0,
              current.revision == row.expected, let evidence = current.evidence else { throw RememberedReferenceFailure.stale }
        return evidence
    }
    internal func moveHandle(_ row: MoveHandoffRow, direction: MoveReferenceDirection) -> RememberedMoveHandoff {
        RememberedMoveHandoff(id: row.id, itemID: row.item, ticket: row.ticket, direction: direction,
            receipt: row.receipt, catalogID: catalog.storeID)
    }
    internal func moveWrite(rows: NameStoreBoundary, commit: NameStoreBoundary, body: () throws -> Void) throws {
        var began = false, committed = false
        do {
            try publication.advance(); try catalog.beginWrite(); began = true
            try database.transaction { try body(); try database.boundary(rows) }
            committed = true
            try catalog.synchronize(); try catalog.endWrite(); began = false
            try database.probe?(commit)
        } catch {
            if committed || database.commitUncertain { suspended = true }
            if began { do { try catalog.endWrite() } catch { suspended = true } }
            if suspended { throw NameStoreFailure.uncertainCommit }; throw error
        }
    }
}
