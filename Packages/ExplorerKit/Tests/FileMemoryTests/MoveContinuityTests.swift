import Darwin
import Foundation
import Testing
@testable import FileMemory
@testable import FileOperations

extension PersistentNameStore {
    fileprivate func moveProbe(_ probe: NameStoreProbe?) { database.probe = probe }
    fileprivate func handoffCount() throws -> Int { try database.scalar("SELECT count(*) FROM move_handoffs") }
    fileprivate func holdMoveCapture(_ body: @escaping @Sendable () -> Void) { referenceReader.qualificationHold = body }
}

private func moveStore(_ fixture: MoveFixture, source: URL) async throws -> (PersistentNameStore, RememberedItemID) {
    let first = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Orion", alternateNames: ["Working report"], labels: ["private"]),
        source: source, allowDocumentFollowing: true)
    let id = try await first.firstItemID()
    await first.close()
    let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .upgradeMoveContinuity)
    return (store, id)
}

private func moveLocation(_ store: PersistentNameStore, _ id: RememberedItemID) async throws -> URL? {
    try referenceDisplay(await store.resolveReference(id)).location
}

private final class MoveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class MoveCaptureHold: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); _ = release.wait(timeout: .now() + 10) }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

@Suite(.serialized) struct MoveContinuityTests {
    @Test func b074UntrackedAndSymbolicCopiesKeepExistingBehavior() async throws {
        let f = try MoveFixture(), source = try f.file()
        let link = f.source.appendingPathComponent("Link")
        try FileManager().createSymbolicLink(atPath: link.path, withDestinationPath: source.lastPathComponent)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source, link], destinationDirectory: f.destination, move: false)
        let copied = await engine.perform(plan)
        try #require(copied.result.disposition == .succeeded)
        #expect(try Data(contentsOf: f.destination.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        #expect(try FileManager().destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("Link").path) == source.lastPathComponent)
        let record = try #require(copied.recordID)
        #expect((await engine.undo(recordID: record)).result.disposition == .succeeded)
        try f.receipt(["untrackedAndSymbolicCopyUndo": true])
    }

    @Test(arguments: [NameStoreBoundary.moveReferenceRows, .moveReferenceCommit])
    func b074UnstartedRetirementFailureReopensSafely(stage: NameStoreBoundary) async throws {
        let f = try MoveFixture(), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
        let proof = try await engine.inspectUnstartedMove(ticket)
        await store.moveProbe { if $0 == stage { throw NameStoreFailure.unsafe } }
        do { try await store.retireUnstartedMove(handoff, evidence: proof); Issue.record("Expected deletion boundary fault") } catch {}
        await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog, action: .recover)
        if let pending = try await reopened.pendingMoveHandoff(for: id) {
            #expect(stage == .moveReferenceRows)
            try await reopened.retireUnstartedMove(pending, evidence: engine.inspectUnstartedMove(ticket))
        } else { #expect(stage == .moveReferenceCommit) }
        #expect(try await moveLocation(reopened, id)?.path == source.path)
        await reopened.close()
        try f.receipt(["unstartedRetirementFailureReopens": true])
    }
    @Test func b074UnstartedReconciliationPreservesCurrentNames() async throws {
        let f = try MoveFixture(), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let pending = try await store.prepareMoveHandoff(id, ticket: ticket)
        #expect(try await store.pendingMoveHandoff(for: id)?.id == pending.id)
        let latest = try await store.snapshot(id)
        _ = try await store.apply(store.prepareEdit(latest, names: AuthoredNames(nickname: "Edited while waiting")))
        let proof = try await engine.inspectUnstartedMove(ticket)
        try await store.retireUnstartedMove(pending, evidence: proof)
        #expect(try await store.pendingMoveHandoff(for: id) == nil)
        #expect(try await moveLocation(store, id)?.path == source.path)
        #expect(try await store.snapshot(id).revision == latest.revision + 1)
        await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog)
        #expect(try await reopened.pendingMoveHandoff(for: id) == nil)
        #expect(try await moveLocation(reopened, id)?.path == source.path)
        await reopened.close()
        try f.receipt(["originalVerifiedWithoutStartingMove": true, "currentNamesRetained": true])
    }

    @Test func b074UnstartedProofRefusesExistingOperationRecords() async throws {
        let f = try MoveFixture(), source = try f.file()
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let moved = await engine.perform(plan)
        try #require(moved.result.disposition == .succeeded)
        do { _ = try await engine.inspectUnstartedMove(ticket); Issue.record("Committed Move appeared unstarted") } catch {}
        let record = try #require(moved.recordID)
        _ = await engine.undo(recordID: record)
        do { _ = try await engine.inspectUnstartedMove(ticket); Issue.record("Existing undone record appeared absent") } catch {}
        try f.receipt(["existingOperationRefusesNoMoveProof": true])
    }

    @Test func b074HandoffPagingIncludesMoreThanOnePage() async throws {
        let f = try MoveFixture(bytes: 4 * 1_024 * 1_024, entries: 192)
        let sources = try (0..<130).map { try f.file("Item-\($0).txt") }
        let (store, firstID) = try await moveStore(f, source: sources[0])
        var ids = [firstID]
        for source in sources.dropFirst() {
            let edit = try await store.prepareRemembering(AuthoredNames(nickname: source.lastPathComponent), source: source, allowDocumentFollowing: true)
            ids.append(try await store.apply(edit))
        }
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: sources, destinationDirectory: f.destination, move: true)
        let tickets = try engine.moveReferenceTickets(for: plan)
        for (id, ticket) in zip(ids, tickets) { _ = try await store.prepareMoveHandoff(id, ticket: ticket) }
        let operation = try #require(tickets.first?.operationID)
        let first = try await store.moveHandoffs(for: operation, limit: 128)
        let second = try await store.moveHandoffs(for: operation, limit: 128, after: first.last?.id)
        #expect(first.count == 128 && second.count == 2)
        #expect(Set((first + second).map(\.itemID)) == Set(ids))
        #expect(try await store.pendingMoveHandoff(for: ids.last!) != nil)
        await store.close()
        try f.receipt(["all130RootsPageWithoutDuplication": true])
    }
    @Test func b074ContinuedMoveReservesItsOwnHistoryRecord() async throws {
        let f = try MoveFixture(entries: 24), source = try f.file()
        let existing = f.destination.appendingPathComponent(source.lastPathComponent)
        try Data("Existing generated destination".utf8).write(to: existing, options: .withoutOverwriting)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let first = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let skipped = await engine.perform(first, resolutions: Dictionary(uniqueKeysWithValues: first.conflicts.map { ($0.id, .skip) }))
        let next = try await engine.prepareContinuation(try #require(skipped.continuation))
        let choices = Dictionary(uniqueKeysWithValues: next.conflicts.map { ($0.id, TransferConflictResolution.keepBoth) })
        let continuedTicket = try #require(engine.moveReferenceTickets(for: next, resolutions: choices).first)
        let moved = await engine.perform(next, resolutions: choices)
        try #require(moved.result.disposition == .succeeded)
        let recordID = try #require(moved.recordID)
        #expect(recordID == continuedTicket.operationID)
        let undone = await engine.undo(recordID: recordID)
        #expect(undone.result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: source.path))
        #expect(try Data(contentsOf: existing) == Data("Existing generated destination".utf8))
        try f.receipt(["continuedMoveHasIndependentReservation": true, "undoRestoresSource": true])
    }
    @Test func b074ForgetWinsWhileNativeHandoffIsHeld() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(entries: 32), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let handle = try await store.prepareMoveHandoff(id, ticket: ticket)
        try #require((await engine.perform(plan)).result.disposition == .succeeded)
        let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
        let hold = MoveCaptureHold()
        await store.holdMoveCapture { hold.hold() }
        let applying = Task { try await store.applyMoveHandoff(handle, evidence: proof) }
        defer { hold.release.signal() }
        let entered = await Task.detached { hold.waitForEntry() }.value
        try #require(entered)
        let revocation = try store.prepareForget(id)
        let forgetting = Task { try await store.finishForget(revocation) }
        hold.release.signal()
        await #expect(throws: (any Error).self) { _ = try await applying.value }
        #expect(try await forgetting.value == .forgotten)
        #expect(try await store.handoffCount() == 0)
        #expect(try await store.pendingMoveHandoffs().isEmpty)
        await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog)
        #expect(try await reopened.pendingMoveHandoffs().isEmpty)
        await #expect(throws: NameIndexFailure.missingRecord) { _ = try await reopened.snapshot(id) }
        await reopened.close()
        #expect((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
    }
    @Test func b074RetainedDescendantNeverBecomesAnOpenResult() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture()
        let folder = f.source.appendingPathComponent("Project")
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("child.txt")
        try Data("Generated remembered descendant".utf8).write(to: child, options: .withoutOverwriting)
        let (store, id) = try await moveStore(f, source: child)
        // Exercise the separate, not-yet-adopted descendant scope. There is no
        // root handoff, so the old bookmark must not open a retained original.
        let engine = RecoverableFileOperations(journalDirectory: f.history, hooks: RecoveryHooks(copyFaults: CopyFaultHooks(afterNativeCopy: {
            try preserveCopiedDocumentTracking(source: $0, destination: $1)
        })))
        // Same-volume folder rename has no retained copy; explicitly staged
        // recovery-layout admission is independently denied without a body read.
        let privateArea = f.root.appendingPathComponent(".mac-explorer-recovery-" + UUID().uuidString)
        try FileManager().createDirectory(at: privateArea, withIntermediateDirectories: false)
        let plan = try await engine.prepareTransfer(sources: [folder], destinationDirectory: privateArea, move: true)
        let result = await engine.perform(plan)
        try #require(result.result.disposition == .succeeded)
        #expect(try referenceDisplay(await store.resolveReference(id)).availability != .available)
        await #expect(throws: RememberedReferenceFailure.unsupported) { _ = try await store.withVerifiedReference(id) { _ in true } }
        let operationID = try #require(result.recordID)
        try #require((await engine.undo(recordID: operationID)).result.disposition == .succeeded)
        #expect(try referenceDisplay(await store.resolveReference(id)).availability == .available)
        await store.close()
    }

    @Test(arguments: [false, true]) func b074StagedTrackingFailurePreservesSource(unrelatedMismatch: Bool) async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        _ = try await NativeDocumentReferenceReader(activity: nil).capture(source, scope: .readOnly,
            allowDocumentFollowing: true, cancellation: .init())
        // Copy always takes the native staging lane, even on one volume.
        let engine = RecoverableFileOperations(journalDirectory: f.history, hooks: RecoveryHooks(copyFaults: CopyFaultHooks(afterNativeCopy: { a, b in
            if !unrelatedMismatch { throw FileOperationFailure.ioFailure }
            try preserveCopiedDocumentTracking(source: a, destination: b)
            var value = stat(); guard fstat(b, &value) == 0 else { throw FileOperationFailure.ioFailure }
            guard fchflags(b, value.st_flags | UInt32(UF_NODUMP)) == 0 else { throw FileOperationFailure.ioFailure }
        })))
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: false)
        let result = await engine.perform(plan)
        #expect(result.result.disposition != .succeeded)
        #expect(result.result.items.contains { $0.status == .failed(unrelatedMismatch ? .copyMetadataMismatch : .ioFailure) })
        #expect(FileManager().fileExists(atPath: source.path))
        #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent(source.lastPathComponent).path))
        var info = stat(); #expect(lstat(source.path, &info) == 0); #expect(info.st_flags == UInt32(UF_TRACKED))
    }
    @Test func b074SuccessOutcomeBeforeFailedCommitIsNotEvidence() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file(), counter = MoveOnce()
        let engine = RecoverableFileOperations(journalDirectory: f.history,
            hooks: RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: {
                if counter.next() == 4 { throw FileOperationFailure.ioFailure }
            })))
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let result = await engine.perform(plan)
        #expect(result.result.items.contains { $0.status == .succeeded })
        #expect(result.result.disposition != .succeeded)
        await #expect(throws: (any Error).self) { _ = try await engine.inspectMoveReference(ticket, direction: .forward) }
    }

    @Test func b074PartialCommittedJobFollowsButChangedParentRefusesEvidence() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), a = try f.file("a.txt"), b = try f.file("b.txt")
        try Data("Generated existing target".utf8).write(to: f.destination.appendingPathComponent("b.txt"), options: .withoutOverwriting)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [a,b], destinationDirectory: f.destination, move: true)
        let both = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.keepBoth) })
        let ticket = try #require(engine.moveReferenceTickets(for: plan, resolutions: both).first)
        let skip = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.skip) })
        _ = await engine.perform(plan, resolutions: skip)
        #expect(try await engine.inspectMoveReference(ticket, direction: .forward).location.lastPathComponent == "a.txt")
        #expect(FileManager().fileExists(atPath: b.path))
        // A separate one-item Move proves a replacement parent cannot be
        // accepted just because the file's own identity is still the same.
        let third = f.root.appendingPathComponent("third")
        try FileManager().createDirectory(at: third, withIntermediateDirectories: false)
        let next = try await engine.prepareTransfer(sources: [b], destinationDirectory: third, move: true)
        let parentTicket = try #require(engine.moveReferenceTickets(for: next).first)
        try #require((await engine.perform(next)).result.disposition == .succeeded)
        let held = f.root.appendingPathComponent("old-third")
        try FileManager().moveItem(at: third, to: held)
        try FileManager().createDirectory(at: third, withIntermediateDirectories: false)
        try FileManager().moveItem(at: held.appendingPathComponent("b.txt"), to: third.appendingPathComponent("b.txt"))
        await #expect(throws: (any Error).self) { _ = try await engine.inspectMoveReference(parentTicket, direction: .forward) }
    }

    @Test func b074ReservedIDNeverAdoptsExistingHistory() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        try {
            let journal = try OperationJournal(f.history)
            let unrelated = try journal.beginEdit(operation: "Copy", reservedID: ticket.operationID)
            try journal.save(unrelated)
        }()
        #expect((await engine.perform(plan)).result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: source.path))
        let inspection = try await engine.inspectExistingHistory()
        #expect(inspection.records.first { $0.id == ticket.operationID }?.operation == "Copy")
    }
    @Test func b074PrivateMoveUndoKeepsLaterNames() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
        #expect(!FileManager().fileExists(atPath: f.history.path))
        #expect(try await store.pendingMoveHandoffs() == [handoff])
        #expect(try referenceDisplay(await store.resolveReference(id)).availability == .needsReconciliation)
        await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.withVerifiedReference(id) { _ in true } }
        await #expect(throws: NameStoreFailure.busy) { _ = try await store.prepareMoveHandoff(id, ticket: ticket) }
        let result = await engine.perform(plan)
        try #require(result.result.disposition == .succeeded)
        let forward = try await engine.inspectMoveReference(ticket, direction: .forward)
        #expect(try await store.applyMoveHandoff(handoff, evidence: forward, allowDocumentFollowing: true) == .applied)
        #expect(try await moveLocation(store, id) == forward.location)
        #expect(try await store.pendingMoveHandoffs().isEmpty)
        #expect(try await store.applyMoveHandoff(handoff, evidence: forward) == .alreadyApplied)
        let current = try await store.snapshot(id)
        let edit = try await store.prepareEdit(current, names: AuthoredNames(nickname: "Updated Orion", labels: ["later edit"]))
        _ = try await store.apply(edit)
        let inverse = try await store.prepareMoveUndo(handoff, evidence: forward)
        #expect(inverse.direction == .undo)
        let undone = await engine.undo(recordID: ticket.operationID)
        try #require(undone.result.disposition == .succeeded)
        let proof = try await engine.inspectMoveReference(ticket, direction: .undo)
        #expect(try await store.applyMoveHandoff(inverse, evidence: proof) == .applied)
        #expect(try await moveLocation(store, id) == source)
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Updated Orion")
        #expect(try await store.applyMoveHandoff(inverse, evidence: proof) == .alreadyApplied)
        await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.applyMoveHandoff(handoff, evidence: forward) }
        await store.close()
        let cold = try await PersistentNameStore.open(directory: f.catalog)
        #expect(try storedSnapshot(await cold.snapshot(id)).names.labels == ["later edit"])
        #expect(try await moveLocation(cold, id) == source)
        await cold.close()
        try f.receipt(["move": true, "undo": true, "newerNamesKept": true, "duplicateNoOp": true, "coldReopen": true])
    }

    @Test(arguments: [0, 1, 2]) func b074PrivacyAndRelinkWin(action: Int) async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
        let result = await engine.perform(plan)
        try #require(result.result.disposition == .succeeded)
        let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
        switch action {
        case 0: #expect(try await store.finishForget(store.prepareForget(id)) == .forgotten)
        case 1: #expect(try await store.finishRemoveAccess(store.prepareRemoveAccess(id)) == .removed)
        default:
            let other = try f.file("Relinked.txt")
            let relink = try await store.prepareRelink(id, source: other, allowDocumentFollowing: true)
            _ = try await store.apply(relink)
        }
        await #expect(throws: RememberedReferenceFailure.stale) {
            _ = try await store.applyMoveHandoff(handoff, evidence: proof, allowDocumentFollowing: true)
        }
        #expect(try await store.handoffCount() == 0)
        #expect(try await store.pendingMoveHandoffs().isEmpty)
        await store.close()
    }

    @Test(arguments: [false, true]) func b074PrivateFailureAndLostAcknowledgement(afterCommit: Bool) async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
        let result = await engine.perform(plan)
        try #require(result.result.disposition == .succeeded)
        let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
        await store.moveProbe { boundary in
            if boundary == (afterCommit ? .moveReferenceCommit : .moveReferenceRows) { throw NameStoreFailure.unavailable }
        }
        await #expect(throws: (any Error).self) { _ = try await store.applyMoveHandoff(handoff, evidence: proof, allowDocumentFollowing: true) }
        await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog, action: .recover)
        #expect(try storedSnapshot(await reopened.snapshot(id)).names.nickname == "Orion")
        let fresh = try await engine.inspectMoveReference(ticket, direction: .forward)
        #expect(try await reopened.applyMoveHandoff(handoff, evidence: fresh, allowDocumentFollowing: true)
                == (afterCommit ? .alreadyApplied : .applied))
        #expect(try await moveLocation(reopened, id) == proof.location)
        await reopened.close()
        #expect((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
    }

    @Test func b074ReservationAndEvidenceRefusals() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let other = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        #expect(try MoveReferenceTicket(encoded: ticket.encoded()) == ticket)
        await #expect(throws: (any Error).self) { _ = try await engine.inspectMoveReference(ticket, direction: .forward) }
        #expect((await other.perform(plan)).result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: source.path))
        let result = await engine.perform(plan)
        try #require(result.result.disposition == .succeeded)
        #expect((await engine.perform(plan)).result.disposition == .failed)
        let destination = f.destination.appendingPathComponent(source.lastPathComponent)
        let retained = f.root.appendingPathComponent("held-target")
        try FileManager().moveItem(at: destination, to: retained)
        try Data("Different generated object".utf8).write(to: destination, options: .withoutOverwriting)
        await #expect(throws: (any Error).self) { _ = try await engine.inspectMoveReference(ticket, direction: .forward) }
        #expect((await engine.undo(recordID: ticket.operationID)).result.disposition != .succeeded)
    }

    @Test func b074KeepBothAndCopyBoundary() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        try Data("Existing generated conflict".utf8).write(to: f.destination.appendingPathComponent(source.lastPathComponent), options: .withoutOverwriting)
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let copy = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: false)
        #expect(try engine.moveReferenceTickets(for: copy).isEmpty)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.keepBoth) })
        #expect(try engine.moveReferenceTickets(for: plan).isEmpty)
        #expect(try engine.moveReferenceTickets(for: plan, resolutions: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .replace) })).count == 1)
        let ticket = try #require(engine.moveReferenceTickets(for: plan, resolutions: choices).first)
        try #require((await engine.perform(plan, resolutions: choices)).result.disposition == .succeeded)
        let evidence = try await engine.inspectMoveReference(ticket, direction: .forward)
        #expect(evidence.location.lastPathComponent == "Document (1).txt")
        #expect((await engine.undo(recordID: ticket.operationID)).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: f.destination.appendingPathComponent("Document.txt").path))
    }

    @Test func b074SequentialMovesUndoAndCopyIsolation() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture(), source = try f.file()
        let third = f.root.appendingPathComponent("third")
        try FileManager().createDirectory(at: third, withIntermediateDirectories: false)
        let (store, id) = try await moveStore(f, source: source)
        let engine = RecoverableFileOperations(journalDirectory: f.history, hooks: RecoveryHooks(copyFaults: CopyFaultHooks(afterNativeCopy: {
            try preserveCopiedDocumentTracking(source: $0, destination: $1)
        })))
        var handles: [RememberedMoveHandoff] = [], current = source
        for destination in [f.destination, third] {
            let plan = try await engine.prepareTransfer(sources: [current], destinationDirectory: destination, move: true)
            let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
            let handle = try await store.prepareMoveHandoff(id, ticket: ticket)
            try #require((await engine.perform(plan)).result.disposition == .succeeded)
            let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
            _ = try await store.applyMoveHandoff(handle, evidence: proof)
            handles.append(handle); current = proof.location
        }
        let copy = try await engine.prepareTransfer(sources: [current], destinationDirectory: f.source, move: false)
        #expect(try engine.moveReferenceTickets(for: copy).isEmpty)
        try #require((await engine.perform(copy)).result.disposition == .succeeded)
        #expect(try await store.lookup(source: source) == nil)
        // Move the generated independent Copy away so it cannot occupy Undo's original name.
        try FileManager().moveItem(at: source, to: f.root.appendingPathComponent("independent-copy.txt"))
        for handle in handles.reversed() {
            let proof = try await engine.inspectMoveReference(handle.ticket, direction: .forward)
            let inverse = try await store.prepareMoveUndo(handle, evidence: proof)
            try #require((await engine.undo(recordID: handle.ticket.operationID)).result.disposition == .succeeded)
            _ = try await store.applyMoveHandoff(inverse, evidence: engine.inspectMoveReference(handle.ticket, direction: .undo))
        }
        #expect(try await moveLocation(store, id) == source)
        await store.close()
    }
    @Test func b074TrackingAndUndoCompatibilityProbe() async throws {
        guard MoveFixture.enabled else { return }
        let f = try MoveFixture()
        let source = try f.file()
        let reader = NativeDocumentReferenceReader(activity: nil)
        _ = try await reader.capture(source, scope: .readOnly, allowDocumentFollowing: true, cancellation: .init())
        let engine = RecoverableFileOperations(journalDirectory: f.history)
        let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
        #expect(ticket.operationID != plan.jobID)
        let result = await engine.perform(plan)
        #expect(result.recordID == ticket.operationID)
        #expect(result.result.disposition == .succeeded)
        let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
        _ = try await reader.capture(proof.location, scope: .readOnly, allowDocumentFollowing: true, cancellation: .init())
        let undo = await engine.undo(recordID: ticket.operationID)
        #expect(undo.result.disposition == .succeeded)
        _ = try await engine.inspectMoveReference(ticket, direction: .undo)
        try f.receipt(["trackingKeptUndo": undo.result.disposition == .succeeded, "reservedID": result.recordID == ticket.operationID])
    }
}
