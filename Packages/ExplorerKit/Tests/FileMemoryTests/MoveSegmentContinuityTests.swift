import Foundation
import Testing
@testable import FileMemory
@testable import FileOperations

private final class SegmentStop: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func holdOnce() {
        let first = lock.withLock { if used { return false }; used = true; return true }
        if first { entered.signal(); _ = release.wait(timeout: .now() + 10) }
    }
}

@Suite(.serialized) struct MoveSegmentContinuityTests {
    @Test func b074cStopRetiresOnlyVerifiedUntouchedIntentAndContinues() async throws {
        let f = try MoveFixture(), first = try f.file("First.txt"), second = try f.file("Second.txt")
        let initial = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "First"), source: first, allowDocumentFollowing: true, locationPolicy: .localPermissions)
        let firstID = try await initial.firstItemID(); await initial.close()
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity)
        let secondID = try await store.apply(store.prepareRemembering(AuthoredNames(nickname: "Second"),
            source: second, allowDocumentFollowing: true, locationPolicy: .localPermissions))
        let stop = SegmentStop()
        let engine = RecoverableFileOperations(journalDirectory: f.history, hooks: RecoveryHooks(afterRename: { stop.holdOnce() }))
        let plan = try await engine.prepareTransfer(sources: [first, second], destinationDirectory: f.destination, move: true)
        let tickets = try engine.moveReferenceTickets(for: plan)
        let a = try await store.prepareMoveHandoff(firstID, ticket: tickets[0])
        let b = try await store.prepareMoveHandoff(secondID, ticket: tickets[1])
        let moving = Task { await engine.perform(plan) }
        defer { stop.release.signal() }
        let reached = await Task.detached { stop.waitForEntry() }.value
        try #require(reached); moving.cancel(); stop.release.signal()
        let result = await moving.value
        _ = try await store.applyMoveHandoff(a, evidence: engine.inspectMoveReference(tickets[0], direction: .forward))
        await #expect(throws: (any Error).self) { _ = try await engine.inspectUnstartedMove(tickets[0]) }
        try await store.retireUnstartedMove(b, evidence: engine.inspectUnstartedMove(tickets[1]))
        #expect(try await store.pendingMoveHandoff(for: secondID) == nil)
        let next = try await engine.prepareContinuation(try #require(result.continuation))
        let ticket = try #require(engine.moveReferenceTickets(for: next).first)
        #expect(ticket.operationID != tickets[1].operationID)
        let retry = try await store.prepareMoveHandoff(secondID, ticket: ticket)
        try #require((await engine.perform(next)).result.disposition == .succeeded)
        _ = try await store.applyMoveHandoff(retry, evidence: engine.inspectMoveReference(ticket, direction: .forward))
        await store.close()
        try f.receipt(["committedFirstFollows": true, "untouchedIntentRetiredWithProof": true, "freshContinuationFollows": true])
    }
    @Test(arguments: [false, true]) func b074cReplaceAndContinuedRoots(continued: Bool) async throws {
        let f = try MoveFixture(), source = try f.file()
        let existing = f.destination.appendingPathComponent(source.lastPathComponent)
        try Data("Existing destination".utf8).write(to: existing, options: .withoutOverwriting)
        let first = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "Orion"), source: source, allowDocumentFollowing: true, locationPolicy: .localPermissions)
        let id = try await first.firstItemID(); await first.close()
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        var plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        if continued {
            let skipped = await engine.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
            plan = try await engine.prepareContinuation(try #require(skipped.continuation))
        }
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.replace) })
        let ticket = try #require(engine.moveReferenceTickets(for: plan, resolutions: choices).first)
        let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
        let result = await engine.perform(plan, resolutions: choices)
        try #require(result.result.disposition == .succeeded)
        _ = try await store.applyMoveHandoff(handoff, evidence: engine.inspectMoveReference(ticket, direction: .forward))
        let undo = try await store.prepareMoveUndo(handoff, evidence: engine.inspectMoveReference(ticket, direction: .forward))
        try #require((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        _ = try await store.applyMoveHandoff(undo, evidence: engine.inspectMoveReference(ticket, direction: .undo))
        #expect(try referenceDisplay(await store.resolveReference(id)).location?.path == source.path)
        #expect(try Data(contentsOf: existing) == Data("Existing destination".utf8))
        await store.close()
        try f.receipt(["replacementRootFollowsAndUndoRestoresBoth": true, "continued": continued])
    }

    @Test func b074cSkippedPeerDoesNotBlockPublishedRoot() async throws {
        let f = try MoveFixture(), source = try f.file(), skipped = try f.file("Skipped.txt")
        try Data("Existing".utf8).write(to: f.destination.appendingPathComponent(skipped.lastPathComponent), options: .withoutOverwriting)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source, skipped], destinationDirectory: f.destination, move: true)
        let choices = [plan.conflicts[0].id: TransferConflictResolution.skip]
        let tickets = try engine.moveReferenceTickets(for: plan, resolutions: choices)
        #expect(tickets.count == 1)
        let ticket = try #require(tickets.first)
        let result = await engine.perform(plan, resolutions: choices)
        #expect(result.recordID == ticket.operationID)
        #expect(try await engine.inspectMoveReference(ticket, direction: .forward).location.lastPathComponent == source.lastPathComponent)
        try #require((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        #expect(try await engine.inspectMoveReference(ticket, direction: .undo).location.path == source.path)
        #expect(FileManager().fileExists(atPath: skipped.path))
        try f.receipt(["committedPublishedSegmentIndependentOfSkippedPeer": true])
    }
}
