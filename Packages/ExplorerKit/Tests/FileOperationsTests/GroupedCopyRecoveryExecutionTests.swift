import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct GroupedRecoveryFixture {
    let root: URL
    let sources: URL
    let destination: URL
    let journal: URL
    let inputs: [URL]
    let qualification: GroupedCopyQualification

    init(count: Int = 2) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let anchor = try DirectoryAnchor(root, resolve: false)
        try OperationJournal.writeExclusive(GroupedCopyQualification.marker, name: GroupedCopyQualification.markerName, anchor: anchor)
        qualification = try GroupedCopyQualification(root: root)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager().createDirectory(at: sources, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
        let sourceDirectory = sources
        inputs = (0..<count).map { sourceDirectory.appendingPathComponent("item-\($0).dat") }
        for (index, url) in inputs.enumerated() { try Data("Generated recovery payload \(index)".utf8).write(to: url) }
    }
    func remove() {
        guard root.resolvingSymlinksInPath().path == root.path,
              let anchor = try? DirectoryAnchor(root, resolve: false),
              anchor.identity.sameObject(as: qualification.identity),
              (try? OperationJournal.read(name: GroupedCopyQualification.markerName, anchor: anchor)) == GroupedCopyQualification.marker else { return }
        try? FileManager().removeItem(at: root)
    }
    func engine(_ transform: (inout RecoveryHooks) -> Void = { _ in }) -> RecoverableFileOperations {
        var hooks = RecoveryHooks(); hooks.groupedCopy.qualification = qualification; transform(&hooks)
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func record(_ id: UUID) throws -> GroupedCopyRecord {
        let store = try OperationJournal(journal)
        guard case .groupedCopyV1(let record)? = try store.inspectCatalogRecord(id) else { throw FileOperationFailure.recoveryUncertain }
        return record
    }
    func seed(publication: Bool) async throws -> UUID {
        let engine = engine { hooks in
            hooks.groupedCopy.checkpoint = { point, _ in
                if publication ? point.stage == .memberPublished : point.stage == .groupSealed { throw FileOperationFailure.ioFailure }
            }
        }
        let result = await engine.perform(.copy(sources: inputs, destinationDirectory: destination))
        return try #require(result.recordID)
    }
    func completed() async throws -> UUID {
        let result = await engine().perform(.copy(sources: inputs, destinationDirectory: destination))
        #expect(result.result.disposition == .succeeded)
        return try #require(result.recordID)
    }
}

@Test func groupedRecoveryConfirmCopiesUsesExistingObjectWithoutOriginalSource() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let publicURL = fixture.destination.appendingPathComponent(fixture.inputs[0].lastPathComponent)
    let before = try verifiedTree(publicURL, cancellation: OperationCancellation())
    try FileManager().removeItem(at: fixture.inputs[0])
    let engine = fixture.engine()
    let review = try await engine.prepareGroupedRecovery(recordID: id)
    #expect(review.availableActions == [.confirmCopies])
    let result = await engine.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(result.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .completed)
    #expect(before.matches(try verifiedTree(publicURL, cancellation: OperationCancellation())))
    let reused = await engine.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(reused.result.disposition == .failed)
}

@Test(arguments: [GroupedCopyRecoveryCheckpointStage.reviewIntentCommitted, .reviewWillSync, .reviewSynced, .reviewWillRecordOutcomes])
func groupedRecoveryInterruptedConfirmationNeedsFreshIntent(stage: GroupedCopyRecoveryCheckpointStage) async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let failing = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, _ in if point.stage == stage { throw FileOperationFailure.ioFailure } }
    }
    let review = try await failing.prepareGroupedRecovery(recordID: id)
    let result = await failing.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(result.result.disposition == .failed)
    let pending = try fixture.record(id)
    #expect(pending.head.state == .needsReview)
    #expect(pending.head.reviewIntent != nil)
    #expect(pending.members[0].progress.phase == "sealed")
    let fresh = fixture.engine()
    let renewed = try await fresh.prepareGroupedRecovery(recordID: id)
    #expect(renewed.availableActions == [.confirmCopies])
    let completed = await fresh.performGroupedRecovery(action: .confirmCopies, from: renewed)
    #expect(completed.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.reviewIntent == nil)
}

@Test func groupedRecoveryStaleInventoryAndForeignEngineCannotUseReview() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let engine = fixture.engine(), foreign = fixture.engine()
    let review = try await engine.prepareGroupedRecovery(recordID: id)
    let rejected = await foreign.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(rejected.result.disposition == .failed)
    try Data("Changed generated payload".utf8).write(to: fixture.destination.appendingPathComponent(fixture.inputs[0].lastPathComponent))
    let stale = await engine.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(stale.result.disposition == .failed)
    #expect(try fixture.record(id).members[0].progress.phase == "sealed")
}

@Test func groupedRecoveryFinishReviewRetainsUnpublishedCopies() async throws {
    let fixture = try GroupedRecoveryFixture(count: 2); defer { fixture.remove() }
    let id = try await fixture.seed(publication: false)
    let engine = fixture.engine()
    let review = try await engine.prepareGroupedRecovery(recordID: id)
    #expect(review.availableActions == [.finishReview])
    let before = try fixture.record(id)
    let result = await engine.performGroupedRecovery(action: .finishReview, from: review)
    #expect(result.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .stoppedSettled)
    for member in before.members {
        #expect(!FileManager().fileExists(atPath: member.manifest.destination.url.path))
        let declaration = try #require(member.progress.declaration)
        #expect(FileManager().fileExists(atPath: declaration.areaURL.appendingPathComponent("payload").path))
    }
}

@Test func groupedRecoveryUndoIgnoresLaterOriginalChangesAndPreservesObject() async throws {
    let fixture = try GroupedRecoveryFixture(count: 2); defer { fixture.remove() }
    let id = try await fixture.completed()
    let before = try fixture.record(id)
    try Data("Original source edited later".utf8).write(to: fixture.inputs[0])
    try FileManager().removeItem(at: fixture.inputs[1])
    let result = await fixture.engine().undo(recordID: id)
    #expect(result.result.disposition == .succeeded)
    let after = try fixture.record(id)
    #expect(after.head.state == .undone)
    for member in after.members {
        guard case .undone(let declaration, _, _, _, let restored) = member.progress else { Issue.record("Missing reverse outcome"); continue }
        #expect(before.members[member.ordinal].progress.publication?.matches(restored) == true)
        #expect(restored.matches(try verifiedTree(declaration.areaURL.appendingPathComponent("payload"), cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: member.manifest.destination.url.path))
    }
    #expect(try Data(contentsOf: fixture.inputs[0]) == Data("Original source edited later".utf8))
}

@Test func groupedRecoveryStopAfterReverseRenameDrainsOneMember() async throws {
    let fixture = try GroupedRecoveryFixture(count: 2); defer { fixture.remove() }
    let id = try await fixture.completed()
    let engine = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, cancellation in if point.stage == .reverseRenamed { cancellation.cancel() } }
    }
    let result = await engine.undo(recordID: id)
    #expect(result.result.cancellationRequested)
    let record = try fixture.record(id)
    #expect(record.head.state == .stoppedSettled)
    #expect(record.members.filter { $0.progress.phase == "undone" }.count == 1)
    #expect(record.members.filter { $0.progress.phase == "published" }.count == 1)
    let completed = await fixture.engine().undo(recordID: id)
    #expect(completed.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .undone)
}

@Test func groupedRecoveryPendingReverseNeedsFreshExplicitUndoRetry() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let failing = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, _ in if point.stage == .reverseIntentCommitted { throw FileOperationFailure.ioFailure } }
    }
    _ = await failing.undo(recordID: id)
    let old = try fixture.record(id)
    guard case .reverseIntent(_, _, _, let oldIntent) = old.members[0].progress else { Issue.record("Missing pending reverse"); return }
    let fresh = fixture.engine()
    let review = try await fresh.prepareGroupedRecovery(recordID: id)
    #expect(review.canUndo)
    #expect(!review.availableActions.contains(.confirmUndo))
    let result = await fresh.undo(recordID: id)
    #expect(result.result.disposition == .succeeded)
    guard case .undone(_, _, _, let newIntent, _) = try fixture.record(id).members[0].progress else { Issue.record("Missing retried reverse"); return }
    #expect(newIntent != oldIntent)
}

@Test func groupedRecoveryConfirmCompletedUndoDoesNotRepeatRename() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let interrupted = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, _ in if point.stage == .reverseRenamed { throw FileOperationFailure.ioFailure } }
    }
    _ = await interrupted.undo(recordID: id)
    let fresh = fixture.engine { hooks in
        hooks.beforeExclusiveRename = { _, _ in throw FileOperationFailure.ioFailure }
    }
    let review = try await fresh.prepareGroupedRecovery(recordID: id)
    #expect(review.availableActions == [.confirmUndo])
    let result = await fresh.performGroupedRecovery(action: .confirmUndo, from: review)
    #expect(result.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .undone)
}

@Test func groupedRecoveryPartialConfirmationKeepsProtectedSiblingPending() async throws {
    let fixture = try GroupedRecoveryFixture(count: 2); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let record = try fixture.record(id)
    let declaration = try #require(record.members[1].progress.declaration)
    let payload = declaration.areaURL.appendingPathComponent("payload")
    try FileManager().moveItem(at: payload, to: fixture.root.appendingPathComponent("held-original"))
    try Data("Foreign replacement in generated fixture".utf8).write(to: payload)
    let engine = fixture.engine()
    let review = try await engine.prepareGroupedRecovery(recordID: id)
    #expect(review.availableActions == [.confirmCopies])
    #expect(review.items[1].state == .protected)
    let result = await engine.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(result.result.disposition == .succeeded)
    let after = try fixture.record(id)
    #expect(after.members[0].progress.phase == "published")
    #expect(after.members[1].progress.phase == "sealed")
    #expect(after.head.state == .needsReview)
}

@Test func groupedRecoveryRevisionChangeRejectsSameInventoryReview() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let engine = fixture.engine()
    let review = try await engine.prepareGroupedRecovery(recordID: id)
    do {
        let journal = try OperationJournal(fixture.journal)
        let edit = try #require(try journal.openGroupedEdit(id))
        try edit.markNeedsReview(); try journal.save(edit)
    }
    let result = await engine.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(result.result.disposition == .failed)
    #expect(try fixture.record(id).members[0].progress.phase == "sealed")
}

private final class GroupedRecoveryCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func failOnce() throws {
        let fail = lock.withLock { let value = armed; armed = false; return value }
        if fail { throw FileOperationFailure.ioFailure }
    }
}

@Test func groupedRecoveryLostConfirmationAcknowledgementUsesColdRecordedOutcome() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.seed(publication: true)
    let gate = GroupedRecoveryCommitGate()
    let failing = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, _ in if point.stage == .reviewWillRecordOutcomes { gate.arm() } }
        hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.failOnce() }
    }
    let review = try await failing.prepareGroupedRecovery(recordID: id)
    let result = await failing.performGroupedRecovery(action: .confirmCopies, from: review)
    #expect(result.result.disposition == .failed)
    let cold = try fixture.record(id)
    #expect(cold.head.state == .completed)
    #expect(cold.members[0].progress.phase == "published")
    let fresh = try await fixture.engine().prepareGroupedRecovery(recordID: id)
    #expect(fresh.availableActions.isEmpty)
}

@Test func groupedRecoveryLostUndoAcknowledgementNeedsExplicitTerminalClosure() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let gate = GroupedRecoveryCommitGate()
    let failing = fixture.engine { hooks in
        hooks.groupedRecovery.checkpoint = { point, _ in if point.stage == .reverseWillRecordOutcome { gate.arm() } }
        hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.failOnce() }
    }
    let result = await failing.undo(recordID: id)
    #expect(result.result.disposition == .failed)
    let cold = try fixture.record(id)
    #expect(cold.head.state == .active)
    #expect(cold.members[0].progress.phase == "undone")
    let fresh = fixture.engine()
    let review = try await fresh.prepareGroupedRecovery(recordID: id)
    #expect(review.availableActions == [.finishReview])
    let completed = await fresh.performGroupedRecovery(action: .finishReview, from: review)
    #expect(completed.result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .undone)
}

private func groupedRecoveryStoppedTail(_ fixture: GroupedRecoveryFixture,
    afterRename: (@Sendable () -> Void)? = nil) async throws -> (RecoverableFileOperations, RecoverableOperationResult, TransferContinuation) {
    let engine = fixture.engine { hooks in
        hooks.groupedCopy.checkpoint = { point, cancellation in
            if point.stage == .groupOutcomesRecorded, point.groupOrdinal == 0 { cancellation.cancel() }
        }
        hooks.afterRename = afterRename
    }
    let result = await engine.perform(.copy(sources: fixture.inputs, destinationDirectory: fixture.destination))
    let token = try #require(result.continuation)
    return (engine, result, token)
}

@Test func groupedRecoveryContinuationSelectsOnlyNeverDeclaredTailAndFreshOrdinaryJob() async throws {
    let fixture = try GroupedRecoveryFixture(count: 17); defer { fixture.remove() }
    let (engine, first, token) = try await groupedRecoveryStoppedTail(fixture)
    let id = try #require(first.recordID)
    #expect(try fixture.record(id).head.state == .stoppedSettled)
    #expect(token.remainingSources == [fixture.inputs[16]])
    #expect(token.groupedRecords.count == 1 && token.groupedRecords[0].memberOrdinals == [16])
    let firstObjects = try (0..<16).map { index in
        try verifiedTree(fixture.destination.appendingPathComponent(fixture.inputs[index].lastPathComponent), cancellation: OperationCancellation())
    }
    // A newer caller selection does not replace the token's captured remaining set.
    var newerSelection = fixture.inputs
    newerSelection.removeAll(); newerSelection.append(fixture.inputs[0])
    _ = try await engine.prepareTransfer(sources: newerSelection, destinationDirectory: fixture.root, move: false)
    let prepared = try await engine.prepareContinuation(token)
    #expect(prepared.groupedCopy == nil && prepared.sources == [fixture.inputs[16]])
    let result = await engine.perform(prepared)
    #expect(result.result.disposition == .succeeded)
    let nextID = try #require(result.recordID)
    #expect(nextID != id)
    do {
        let journal = try OperationJournal(fixture.journal)
        guard case .treeV3? = try journal.inspectCatalogRecord(nextID) else { Issue.record("Continuation must use ordinary protocol"); return }
    }
    #expect(result.continuation == nil)
    for index in 0..<16 {
        #expect(firstObjects[index].matches(try verifiedTree(fixture.destination.appendingPathComponent(fixture.inputs[index].lastPathComponent), cancellation: OperationCancellation())))
    }
}

@Test(arguments: ["sourceEdit", "destinationRefill", "revision", "undo", "cleanup"])
func groupedRecoveryContinuationRejectsChangedAuthority(change: String) async throws {
    let fixture = try GroupedRecoveryFixture(count: 17); defer { fixture.remove() }
    let (engine, first, token) = try await groupedRecoveryStoppedTail(fixture)
    let id = try #require(first.recordID)
    switch change {
    case "sourceEdit": try Data("Changed tail source".utf8).write(to: fixture.inputs[16])
    case "destinationRefill": try Data("New destination occupant".utf8).write(to: fixture.destination.appendingPathComponent(fixture.inputs[16].lastPathComponent))
    case "undo":
        let undone = await engine.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded)
    case "cleanup":
        let journal = try OperationJournal(fixture.journal)
        let edit = try #require(try journal.openGroupedEdit(id))
        try edit.beginCleanup(); try journal.save(edit)
    default:
        let journal = try OperationJournal(fixture.journal)
        let edit = try #require(try journal.openGroupedEdit(id))
        try journal.save(edit)
    }
    do { _ = try await engine.prepareContinuation(token); Issue.record("Changed continuation authority was accepted") }
    catch {}
}

@Test func groupedRecoveryContinuationPreservesNativeComposedUnicodeTail() async throws {
    let fixture = try GroupedRecoveryFixture(count: 17); defer { fixture.remove() }
    let nativeName = "composed-\u{e9}.dat"
    let source = try DirectoryAnchor(fixture.sources, resolve: false)
    try exclusiveRename(from: source.fd, name: fixture.inputs[16].lastPathComponent,
                        to: source.fd, name: nativeName)
    var inputs = fixture.inputs
    inputs[16] = fixture.sources.appendingPathComponent(nativeName)
    let nativeBefore = try NativeRenameEntry.observe(parent: source, name: nativeName)
    #expect(nativeBefore.nameBytes == Data(nativeName.utf8))
    let sourceBefore = try verifiedTree(parent: source.fd, name: nativeName, cancellation: OperationCancellation())
    let engine = fixture.engine { hooks in
        hooks.groupedCopy.checkpoint = { point, cancellation in
            if point.stage == .groupOutcomesRecorded, point.groupOrdinal == 0 { cancellation.cancel() }
        }
    }
    let first = await engine.perform(.copy(sources: inputs, destinationDirectory: fixture.destination))
    let id = try #require(first.recordID)
    let token = try #require(first.continuation)
    let record = try fixture.record(id)
    #expect(record.members[16].progress.phase == "notDeclared")
    #expect(record.members[16].manifest.source.nameBytes == Data(nativeName.utf8))
    #expect(record.members[16].manifest.destination.nameBytes == Data(nativeName.utf8))
    let publishedBefore = try record.members.prefix(16).map {
        try verifiedTree($0.manifest.destination.url, cancellation: OperationCancellation())
    }
    let prepared = try await engine.prepareContinuation(token)
    #expect(prepared.groupedCopy == nil && prepared.sources == [inputs[16]])
    let continued = await engine.perform(prepared)
    #expect(continued.result.disposition == .succeeded)
    let nextID = try #require(continued.recordID)
    #expect(nextID != id && continued.continuation == nil)
    do {
        let journal = try OperationJournal(fixture.journal)
        guard case .treeV3? = try journal.inspectCatalogRecord(nextID) else {
            Issue.record("Unicode tail continuation must use ordinary protocol"); return
        }
    }
    let sourceAfter = try verifiedTree(parent: source.fd, name: nativeName, cancellation: OperationCancellation())
    #expect(sourceBefore.matches(sourceAfter))
    #expect(try NativeRenameEntry.observe(parent: source, name: nativeName).nameBytes == nativeBefore.nameBytes)
    // Ordinary Copy retains its existing URL spelling policy. Verify its exact
    // prepared destination and full payload/metadata, without rewriting the source.
    let output = try verifiedTree(prepared.entries[0].destination, cancellation: OperationCancellation())
    #expect(output.digest == sourceBefore.digest)
    #expect(!output.identity.sameObject(as: sourceBefore.identity))
    for index in 0..<16 {
        #expect(publishedBefore[index].matches(try verifiedTree(record.members[index].manifest.destination.url,
            cancellation: OperationCancellation())))
    }
}

@Test func groupedRecoveryDifferentSourceParentsWithDuplicateBasenameRefuseBeforeHistory() async throws {
    let fixture = try GroupedRecoveryFixture(count: 1); defer { fixture.remove() }
    let otherParent = fixture.root.appendingPathComponent("other-sources", isDirectory: true)
    try FileManager().createDirectory(at: otherParent, withIntermediateDirectories: false)
    let otherSource = otherParent.appendingPathComponent(fixture.inputs[0].lastPathComponent)
    try Data("Distinct generated source with the same basename".utf8).write(to: otherSource)
    let inputs = [fixture.inputs[0], otherSource]
    let before = try inputs.map { try verifiedTree($0, cancellation: OperationCancellation()) }
    #expect(!before[0].identity.sameObject(as: before[1].identity))
    let engine = fixture.engine()
    do {
        _ = try await engine.prepareTransfer(sources: inputs, destinationDirectory: fixture.destination, move: false)
        Issue.record("Different source parents cannot resolve duplicate public destination names")
    } catch let failure as FileOperationFailure {
        #expect(failure == .invalidRequest)
    }
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    let destination = try DirectoryAnchor(fixture.destination, resolve: false)
    #expect(try GroupedCopyFilesystemEvidence.children(in: destination, cancellation: OperationCancellation(), limit: 8).isEmpty)
    for index in inputs.indices {
        #expect(before[index].matches(try verifiedTree(inputs[index], cancellation: OperationCancellation())))
    }
}

private final class GroupedRecoveryContinuationPause: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func waitUntilReached() -> Bool { reached.wait(timeout: .now() + 10) == .success }
    func observeRename() {
        let pause = lock.withLock { let result = armed; armed = false; return result }
        guard pause else { return }
        reached.signal()
        _ = release.wait(timeout: .now() + 10)
    }
}

@Test func groupedRecoveryOrdinaryContinuationCarriesOriginalGroupedDependency() async throws {
    let fixture = try GroupedRecoveryFixture(count: 18); defer { fixture.remove() }
    let pause = GroupedRecoveryContinuationPause()
    let (engine, first, token) = try await groupedRecoveryStoppedTail(fixture, afterRename: { pause.observeRename() })
    let originalID = try #require(first.recordID)
    let prepared = try await engine.prepareContinuation(token)
    pause.arm()
    let task = Task { await engine.perform(prepared) }
    let reached = await Task.detached { pause.waitUntilReached() }.value
    #expect(reached)
    task.cancel(); pause.release.signal()
    let partial = await task.value
    let remaining = try #require(partial.continuation)
    #expect(remaining.remainingSources == [fixture.inputs[17]])
    #expect(remaining.groupedRecords.count == 1 && remaining.groupedRecords[0].id == originalID)
    #expect(remaining.records.count == 1)
    #expect(await engine.undo(recordID: originalID).result.disposition == .succeeded)
    do { _ = try await engine.prepareContinuation(remaining); Issue.record("Original Undo must invalidate descendant continuation") }
    catch {}
}
