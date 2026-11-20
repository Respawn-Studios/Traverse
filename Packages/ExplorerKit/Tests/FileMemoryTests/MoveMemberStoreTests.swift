import Foundation
import SQLite3
import Testing
@testable import FileMemory
@testable import FileOperations

private struct MemberStoreCase {
    let fixture: MoveFixture, source: URL, folder: URL
    let store: PersistentNameStore, item: RememberedItemID
    let engine: RecoverableFileOperations, admission: MoveReferenceAdmission
    init() async throws {
        fixture = try MoveFixture(entries: 48)
        folder = fixture.source.appendingPathComponent("Project")
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        source = folder.appendingPathComponent("Document.txt")
        try Data("Generated member store data".utf8).write(to: source, options: .withoutOverwriting)
        let first = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
            first: AuthoredNames(nickname: "Orion"), source: source, allowDocumentFollowing: true)
        item = try await first.firstItemID(); await first.close()
        store = try await PersistentNameStore.open(directory: fixture.catalog, action: .upgradeMoveMembers)
        engine = RecoverableFileOperations(journalDirectory: fixture.history)
        let plan = try await engine.prepareTransfer(sources: [folder], destinationDirectory: fixture.destination, move: true)
        admission = try await engine.observingMoveReferences(plan, candidates: [source])
    }
}

@Suite(.serialized) struct MoveMemberStoreTests {
    @Test func b074cLostReceiptCanRetireAfterFullyGuardedUndo() async throws {
        let c = try await MemberStoreCase(), ticket = try #require(c.admission.tickets.first)
        let row = try await c.store.prepareMoveHandoff(c.item, ticket: ticket)
        try #require((await c.engine.perform(c.admission.plan)).result.disposition == .succeeded)
        // Intentionally discard the returned bridge, as a crash can do.
        await #expect(throws: (any Error).self) { _ = try await c.engine.inspectRestoredMoveOriginal(ticket) }
        try #require((await c.engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        let original = try await c.engine.inspectRestoredMoveOriginal(ticket)
        try await c.store.retireUnstartedMove(row, evidence: original)
        #expect(try await c.store.pendingMoveHandoff(for: c.item) == nil)
        #expect(try referenceDisplay(await c.store.resolveReference(c.item)).location?.path == c.source.path)
        await c.store.close()
        try c.fixture.receipt(["noForwardGuessWithoutReceipt": true, "guardedUndoRestoresOriginalBinding": true])
    }

    @Test(arguments: [false, true]) func b074cV3RootAssociationSurvivesExplicitMemberUpgrade(applied: Bool) async throws {
        let f = try MoveFixture(), source = try f.file()
        let first = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "Existing root"), source: source, allowDocumentFollowing: true)
        let id = try await first.firstItemID(); await first.close()
        let old = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first), encoded = try ticket.encoded()
        let handle = try await old.prepareMoveHandoff(id, ticket: ticket)
        try #require((await engine.perform(plan)).result.disposition == .succeeded)
        if applied { _ = try await old.applyMoveHandoff(handle, evidence: engine.inspectMoveReference(ticket, direction: .forward)) }
        await old.close()
        let upgraded = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveMembers)
        let row = try #require(await upgraded.moveHandoffs(for: ticket.operationID).first)
        #expect(try row.ticket.encoded() == encoded && row.receipt == nil)
        _ = try await upgraded.applyMoveHandoff(row, evidence: engine.inspectMoveReference(ticket, direction: .forward))
        let undo = try await upgraded.prepareMoveUndo(row, evidence: engine.inspectMoveReference(ticket, direction: .forward))
        try #require((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        _ = try await upgraded.applyMoveHandoff(undo, evidence: engine.inspectMoveReference(ticket, direction: .undo))
        #expect(try referenceDisplay(await upgraded.resolveReference(id)).location?.path == source.path)
        await upgraded.close()
        try f.receipt(["v3TicketAndAssociationPreservedInV4": true, "previouslyApplied": applied])
    }

    @Test(arguments: [false, true]) func b074cCommonFollowingFlowAndMergedReplacement(merge: Bool) async throws {
        let c = try await MemberStoreCase()
        var oldTarget: URL?, oldTargetID: RememberedItemID?
        if merge {
            let targetFolder = c.fixture.destination.appendingPathComponent("Project")
            try FileManager().createDirectory(at: targetFolder, withIntermediateDirectories: false)
            let target = targetFolder.appendingPathComponent("Document.txt")
            try Data("Existing destination description".utf8).write(to: target, options: .withoutOverwriting)
            oldTarget = target
            oldTargetID = try await c.store.apply(c.store.prepareRemembering(AuthoredNames(nickname: "Destination only"),
                source: target, allowDocumentFollowing: true))
        }
        let plan = try await c.engine.prepareTransfer(sources: [c.folder], destinationDirectory: c.fixture.destination, move: true)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.canMerge ? TransferConflictResolution.merge : .replace) })
        let prepared = try await c.store.prepareMoveFollowing(plan, resolutions: choices, engine: c.engine)
        #expect(prepared.handoffs.count == 1 && !prepared.coverageLimited)
        let files = await c.engine.perform(prepared.plan, resolutions: choices)
        try #require(files.result.disposition == .succeeded)
        let report = await c.store.finishMoveFollowing(prepared, result: files, engine: c.engine)
        #expect(report.applied == 1 && report.unresolved.isEmpty && report.storageFailure == nil)
        #expect(try referenceDisplay(await c.store.resolveReference(c.item)).location?.path
            == c.fixture.destination.appendingPathComponent("Project/Document.txt").path)
        if let oldTargetID {
            #expect(try referenceDisplay(await c.store.resolveReference(oldTargetID)).availability != .available)
        }
        let operation = try #require(files.recordID)
        let row = try #require(await c.store.moveHandoffs(for: operation).first)
        let inverse = try await c.store.prepareMoveUndo(row,
            evidence: c.engine.inspectMoveReference(row.ticket, direction: .forward, receipt: row.receipt))
        try #require((await c.engine.undo(recordID: row.ticket.operationID)).result.disposition == .succeeded)
        _ = try await c.store.applyMoveHandoff(inverse,
            evidence: c.engine.inspectMoveReference(row.ticket, direction: .undo, receipt: inverse.receipt))
        #expect(try referenceDisplay(await c.store.resolveReference(c.item)).location?.path == c.source.path)
        if let oldTarget, let oldTargetID {
            #expect(try referenceDisplay(await c.store.resolveReference(oldTargetID)).location?.path == oldTarget.path)
        }
        await c.store.close()
        try c.fixture.receipt(["commonFacadeMoveUndo": true, "mergeReplacement": merge])
    }

    @Test func b074cReceiptReopensBeforeApplicationAndColdUndoKeepsNames() async throws {
        let c = try await MemberStoreCase(), ticket = try #require(c.admission.tickets.first)
        let handle = try await c.store.prepareMoveHandoff(c.item, ticket: ticket)
        let moved = await c.engine.perform(c.admission.plan)
        let receipt = try #require(moved.referenceReceipts.first)
        _ = try await c.store.retainMoveReceipt(handle, receipt: receipt)
        await c.store.close()
        let reopened = try await PersistentNameStore.open(directory: c.fixture.catalog, action: .edit)
        let pending = try #require(await reopened.pendingMoveHandoff(for: c.item))
        #expect(pending.receipt == receipt)
        _ = try await reopened.applyMoveHandoff(pending,
            evidence: c.engine.inspectMoveReference(ticket, direction: .forward, receipt: pending.receipt))
        let snapshot = try await reopened.snapshot(c.item)
        _ = try await reopened.apply(reopened.prepareEdit(snapshot, names: AuthoredNames(nickname: "Edited after Move")))
        await reopened.close()
        let cold = try await PersistentNameStore.open(directory: c.fixture.catalog, action: .edit)
        let row = try #require(await cold.moveHandoffs(for: ticket.operationID).first)
        let inverse = try await cold.prepareMoveUndo(row,
            evidence: c.engine.inspectMoveReference(ticket, direction: .forward, receipt: row.receipt))
        try #require((await c.engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        _ = try await cold.applyMoveHandoff(inverse,
            evidence: c.engine.inspectMoveReference(ticket, direction: .undo, receipt: inverse.receipt))
        #expect(try referenceDisplay(await cold.resolveReference(c.item)).location?.path == c.source.path)
        let names = try await cold.snapshot(c.item)
        var nickname: String?
        #expect(names.publish { nickname = $0.names.nickname })
        #expect(nickname == "Edited after Move")
        await cold.close()
        try c.fixture.receipt(["receiptSurvivesBeforeApply": true, "coldUndoKeepsAuthoredEdit": true])
    }

    @Test(arguments: [NameStoreBoundary.memberReceiptRows, .memberReceiptCommit])
    func b074cReceiptFailureReopensWithoutInventingEvidence(boundary: NameStoreBoundary) async throws {
        let c = try await MemberStoreCase(), ticket = try #require(c.admission.tickets.first)
        let handle = try await c.store.prepareMoveHandoff(c.item, ticket: ticket)
        let moved = await c.engine.perform(c.admission.plan), receipt = try #require(moved.referenceReceipts.first)
        await c.store.memberProbe { if $0 == boundary { throw NameStoreFailure.unsafe } }
        await #expect(throws: (any Error).self) { _ = try await c.store.retainMoveReceipt(handle, receipt: receipt) }
        await c.store.close()
        let reopened = try await PersistentNameStore.open(directory: c.fixture.catalog, action: .recover)
        let pending = try #require(await reopened.pendingMoveHandoff(for: c.item))
        if boundary == .memberReceiptRows {
            #expect(pending.receipt == nil)
            await #expect(throws: (any Error).self) {
                _ = try await c.engine.inspectMoveReference(ticket, direction: .forward, receipt: pending.receipt)
            }
            #expect(try referenceDisplay(await reopened.resolveReference(c.item)).availability != .available)
        } else {
            #expect(pending.receipt == receipt)
            _ = try await reopened.applyMoveHandoff(pending,
                evidence: c.engine.inspectMoveReference(ticket, direction: .forward, receipt: pending.receipt))
        }
        var nickname: String?
        #expect(try await reopened.snapshot(c.item).publish { nickname = $0.names.nickname })
        #expect(nickname == "Orion")
        await reopened.close()
        try c.fixture.receipt(["failureBoundarySafeAfterReopen": true, "receiptMayBeAbsent": boundary == .memberReceiptRows])
    }

    @Test(arguments: [0, 1, 2], [false, true]) func b074cPrivacyInvalidatesLateReceipt(action: Int, stored: Bool) async throws {
        let c = try await MemberStoreCase(), ticket = try #require(c.admission.tickets.first)
        var handle = try await c.store.prepareMoveHandoff(c.item, ticket: ticket)
        let moved = await c.engine.perform(c.admission.plan), receipt = try #require(moved.referenceReceipts.first)
        if stored { handle = try await c.store.retainMoveReceipt(handle, receipt: receipt) }
        switch action {
        case 0: #expect(try await c.store.finishForget(c.store.prepareForget(c.item)) == .forgotten)
        case 1: #expect(try await c.store.finishRemoveAccess(c.store.prepareRemoveAccess(c.item)) == .removed)
        default:
            let other = try c.fixture.file("Relinked.txt")
            _ = try await c.store.apply(c.store.prepareRelink(c.item, source: other, allowDocumentFollowing: true))
        }
        await #expect(throws: RememberedReferenceFailure.stale) { _ = try await c.store.retainMoveReceipt(handle, receipt: receipt) }
        #expect(try await c.store.memberReceiptCount() == 0)
        await c.store.close()
        try c.fixture.receipt(["privacyDefeatsDelayedMemberReceipt": true])
    }

    @Test func b074cIndexedCandidateBoundaryAndCapacity() async throws {
        let c = try await MemberStoreCase()
        let sibling = try c.fixture.file("Sibling.txt")
        _ = try await c.store.apply(c.store.prepareRemembering(AuthoredNames(nickname: "Sibling"), source: sibling, allowDocumentFollowing: true))
        let candidates = try await c.store.moveCandidateIDs(beneath: [c.folder])
        #expect(candidates.ids == [c.item] && !candidates.limited)
        let bounded = try await c.store.moveCandidateIDs(beneath: [c.fixture.source], limit: 1)
        #expect(bounded.ids.count == 1 && bounded.limited)
        let plans = try await c.store.memberQueryPlan(c.folder)
        #expect(plans.contains { $0.hasPrefix("SEARCH r ") && $0.contains("INDEX references_by_hint") },
                "Expected a bounded search through the hint index. Plan: \(plans)")
        #expect(!plans.contains { $0.contains("SCAN r") })
        await c.store.close()
        try c.fixture.receipt(["componentScopedIndexedDiscovery": true, "boundedCandidateCoverage": true])
    }
}

extension PersistentNameStore {
    fileprivate func memberProbe(_ value: NameStoreProbe?) { database.probe = value }
    fileprivate func memberReceiptCount() throws -> Int { try database.scalar("SELECT count(*) FROM move_member_receipts") }
    fileprivate func memberQueryPlan(_ root: URL) throws -> [String] {
        let query = try database.prepare("EXPLAIN QUERY PLAN SELECT n.id FROM item_references r INDEXED BY references_by_hint JOIN records n ON n.record=r.record WHERE r.access=0 AND n.hidden=0 AND r.hint>=? AND r.hint<? ORDER BY r.hint,r.record LIMIT 128")
        defer { sqlite3_finalize(query) }
        try database.bind(root.path + "/", to: query, at: 1); try database.bind(root.path + "0", to: query, at: 2)
        var rows: [String] = []; while try database.step(query) { rows.append(try database.text(query, column: 3)) }; return rows
    }
}
