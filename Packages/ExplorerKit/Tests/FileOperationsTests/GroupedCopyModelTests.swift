import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

private struct GroupedModelFixture {
    let root: URL
    let journal: URL
    let source: URL
    let destination: URL
    let manifest: [GroupedCopyManifestMember]

    init(count: Int = 2, names: [String]? = nil) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-model-" + UUID().uuidString)
        journal = root.appendingPathComponent("journal")
        source = root.appendingPathComponent("sources", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("Generated grouped catalog model fixture v1".utf8).write(to: root.appendingPathComponent(".fixture-owner"))
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
        let literals = names ?? (0..<count).map { "source-\($0).dat" }
        for (index, name) in literals.enumerated() { try Data("generated member \(index)".utf8).write(to: source.appendingPathComponent(name)) }
        let from = try DirectoryAnchor(source, resolve: false), to = try DirectoryAnchor(destination, resolve: false)
        let fromVolume = try #require(try NativeRenameVolume.qualified(in: from))
        let toVolume = try #require(try NativeRenameVolume.qualified(in: to))
        manifest = try literals.map { name in
            GroupedCopyManifestMember(source: GroupedCopySlot(parent: from.url, nameBytes: Data(name.utf8), parentIdentity: from.identity, volume: fromVolume),
                destination: GroupedCopySlot(parent: to.url, nameBytes: Data(name.utf8), parentIdentity: to.identity, volume: toVolume),
                sourceTree: try verifiedTree(parent: from.fd, name: name, cancellation: OperationCancellation()))
        }
    }

    func remove() { try? FileManager().removeItem(at: root) }

    func declare(_ session: GroupedCopyEditSession) throws -> [URL] {
        let group = destination.appendingPathComponent(".owned-group", isDirectory: true)
        let areas = session.snapshot.members.map { group.appendingPathComponent("member-\($0.ordinal)", isDirectory: true) }
        try session.declareGroup(areaURL: group, memberAreaURLs: areas)
        try FileManager().createDirectory(at: group, withIntermediateDirectories: false)
        try session.recordGroupIdentity(DirectoryAnchor(group, resolve: false).identity, at: 0)
        return areas
    }

    /// Evidence fixture only: no production copy/rename/Trash is invoked by these tests.
    func seal(area: URL, policy: TransferMetadataPolicy = .strict) throws -> GroupedCopySeal {
        try FileManager().createDirectory(at: area, withIntermediateDirectories: false)
        try Data("generated sealed payload".utf8).write(to: area.appendingPathComponent("payload"))
        let parent = try DirectoryAnchor(area, resolve: false)
        let payload = try verifiedTree(parent: parent.fd, name: "payload", cancellation: OperationCancellation())
        let receipts = StagingCopyReceipts(); try receipts.completed("", payload.identity)
        let proof = try receipts.proof(parent: parent.fd, payload: payload, stepCount: 0, cancellation: OperationCancellation())
        return GroupedCopySeal(version: 1, metadataPolicy: policy, receiptVersion: 1, areaIdentity: parent.identity, proof: proof)
    }
}

private final class GroupedModelFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func enable() { lock.withLock { active = true } }
    func disable() { lock.withLock { active = false } }
    func check() throws { if lock.withLock({ active }) { throw FileOperationFailure.ioFailure } }
}

private func groupedModelDurablePhase(_ fixture: GroupedModelFixture, id: UUID) throws -> String {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(fixture.journal.appendingPathComponent(SQLiteJournalStore.name).path,
        &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let connection else { throw FileOperationFailure.ioFailure }
    defer { sqlite3_close(connection) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, "SELECT phase FROM grouped_members WHERE job=? AND ordinal=0", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw FileOperationFailure.ioFailure }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard id.uuidString.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW, let phase = sqlite3_column_text(statement, 0) else { throw FileOperationFailure.ioFailure }
    return String(cString: phase)
}

@Test func groupedCatalogRequiresExplicitUpgradeAndKeepsLiteralManifest() throws {
    let fixture = try GroupedModelFixture(names: [".hidden", "cafe\u{301}", "extensionless"]); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    #expect(throws: FileOperationFailure.unsupported) { _ = try journal.beginGroupedEdit(members: fixture.manifest) }
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifest)
    try journal.save(edit)
    guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(edit.id) else { Issue.record("Missing typed grouped record"); return }
    #expect(record.head.revision == edit.revision)
    #expect(record.members.map { $0.manifest.source.nameBytes } == fixture.manifest.map { $0.source.nameBytes })
    #expect(record.members.allSatisfy { $0.progress.phase == "notDeclared" })
    #expect(record.groups.isEmpty)
    #expect(throws: (any Error).self) { _ = try journal.openEdit(edit.id) }
    #expect(throws: (any Error).self) { _ = try journal.inspectRecord(edit.id) }
    let summary = try journal.inspectSummaries()
    #expect(summary.records.count == 1)
    #expect(!summary.records[0].canUndo && !summary.records[0].canRecover)
}

@Test func groupedColdSessionCannotInventForwardEvidence() throws {
    let fixture = try GroupedModelFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    try journal.save(live)
    let areas = try fixture.declare(live)
    let seal = try fixture.seal(area: areas[0])
    try journal.save(live)
    let cold = try #require(try journal.openGroupedEdit(live.id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordSeal(seal, member: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordNeverStaged(member: 1) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordGroupNeverCreated(0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.sealGroup(0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.close() }
    #expect(throws: FileOperationFailure.recoveryUncertain) {
        try cold.declareGroup(areaURL: fixture.destination.appendingPathComponent("another"), memberAreaURLs: [])
    }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try live.recordNeverStaged(member: 1) }
}

@Test func groupedColdPublicationRequiresExplicitReviewAndPreservesSeal() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    try journal.save(live)
    let areas = try fixture.declare(live), seal = try fixture.seal(area: areas[0])
    try live.recordSeal(seal, member: 0); try live.sealGroup(0); try journal.save(live)
    let cold = try #require(try journal.openGroupedEdit(live.id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordPublication(seal.proof.payload, member: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.settleGroup(0) }
    let intent = GroupedCopyReviewIntent(id: UUID(), kind: .publication, preparedRevision: cold.revision,
        members: [0], inventoryDigest: String(repeating: "a", count: 64))
    try cold.beginReview(intent); try journal.save(cold)
    try cold.recordPublication(seal.proof.payload, member: 0); try cold.finishReview(intent.id); try journal.save(cold)
    #expect(cold.snapshot.head.state == .completed)
    try cold.snapshot.validate()
    let loaded = try #require(try journal.openGroupedEdit(live.id))
    #expect(loaded.snapshot.members[0].progress.seal == seal)
}

@Test func groupedReverseIntentCannotBeCompletedFromColdWithoutConfirmation() throws {
    let fixture = try GroupedModelFixture(count: 2); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    try journal.save(live)
    let areas = try fixture.declare(live)
    let seals = try areas.map { try fixture.seal(area: $0) }
    for (index, seal) in seals.enumerated() { try live.recordSeal(seal, member: index) }
    try live.sealGroup(0)
    for (index, seal) in seals.enumerated() { try live.recordPublication(seal.proof.payload, member: index) }
    try live.settleGroup(0); try live.close(); try journal.save(live)
    let reverse = try #require(try journal.openGroupedEdit(live.id))
    try reverse.beginReverse(member: 1, intent: UUID()); try journal.save(reverse)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try reverse.beginReverse(member: 0, intent: UUID()) }
    let cold = try #require(try journal.openGroupedEdit(live.id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordReversal(seals[1].proof.payload, member: 1) }
    let review = GroupedCopyReviewIntent(id: UUID(), kind: .reversal, preparedRevision: cold.revision,
        members: [1], inventoryDigest: String(repeating: "b", count: 64))
    try cold.beginReview(review); try journal.save(cold)
    try cold.recordReversal(seals[1].proof.payload, member: 1); try cold.finishReview(review.id); try journal.save(cold)
    #expect(cold.snapshot.head.state == .stoppedSettled)
    try cold.beginReverse(member: 0, intent: UUID()); try journal.save(cold)
    try cold.recordReversal(seals[0].proof.payload, member: 0); try cold.close(); try journal.save(cold)
    #expect(cold.snapshot.head.state == .undone)
    try cold.snapshot.validate()
}

@Test func groupedLiveStopBeforeCreationHasExplicitClosureButColdAbsenceDoesNot() throws {
    let fixture = try GroupedModelFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    let group = fixture.destination.appendingPathComponent(".never-created", isDirectory: true)
    try live.declareGroup(areaURL: group, memberAreaURLs: [group.appendingPathComponent("a"), group.appendingPathComponent("b")])
    try journal.save(live)
    try live.recordNeverStaged(member: 0); try live.recordNeverStaged(member: 1)
    try live.recordGroupNeverCreated(0); try live.close(); try journal.save(live)
    #expect(live.snapshot.head.state == .stoppedSettled)
    #expect(!FileManager().fileExists(atPath: group.path))
    guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(live.id) else { Issue.record("Missing record"); return }
    #expect(record.groups[0].creationClosure == .neverCreated)
    try record.validate()
}

@Test func groupedModelRejectsPolicyMismatchAndPrivatePublicOverlap() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    let badArea = fixture.manifest[0].destination.url
    #expect(throws: FileOperationFailure.recoveryUncertain) {
        try live.declareGroup(areaURL: badArea, memberAreaURLs: [badArea.appendingPathComponent("member")])
    }
    let areas = try fixture.declare(live)
    let seal = try fixture.seal(area: areas[0], policy: .destinationOwnership)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try live.recordSeal(seal, member: 0) }
    #expect(live.snapshot.members[0].progress.phase == "declared")
}

@Test func groupedCleanupCandidatesDoNotBecomeOutcomesOrRetainUndo() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    let areas = try fixture.declare(live), seal = try fixture.seal(area: areas[0])
    try live.recordSeal(seal, member: 0); try live.sealGroup(0); try live.settleGroup(0); try live.close()
    try journal.save(live)
    let cleanup = try #require(try journal.openGroupedEdit(live.id))
    try cleanup.beginCleanup(); try journal.save(cleanup)
    let group = cleanup.snapshot.groups[0]
    let tree = try verifiedTree(group.areaURL, cancellation: OperationCancellation())
    let intent = GroupedCopyCleanupIntent(id: UUID(), before: tree, parent: fixture.manifest[0].destination.parentIdentity)
    try cleanup.recordCleanupIntent(intent, group: 0); try journal.save(cleanup)
    try cleanup.recordCleanupReturn(fixture.root.appendingPathComponent("known-native-return"), group: 0); try journal.save(cleanup)
    #expect(cleanup.snapshot.head.undoInvalidated)
    #expect(cleanup.snapshot.groups[0].cleanup.phase == "returned")
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cleanup.closeCleanup() }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cleanup.beginReverse(member: 0, intent: UUID()) }
    try cleanup.snapshot.validate()
    // Model-only same-object outcome fixture. No file is sent to native Trash.
    try cleanup.recordCleanupOutcome(tree, group: 0); try cleanup.closeCleanup(); try journal.save(cleanup)
    #expect(cleanup.snapshot.head.state == .cleaned)
}

@Test func groupedColdPersistedPublicationReviewRequiresFreshAction() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal); try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    let areas = try fixture.declare(live), seal = try fixture.seal(area: areas[0])
    try live.recordSeal(seal, member: 0); try live.sealGroup(0); try journal.save(live)
    let intent = GroupedCopyReviewIntent(id: UUID(), kind: .publication, preparedRevision: live.revision,
        members: [0], inventoryDigest: String(repeating: "c", count: 64))
    try live.beginReview(intent); try journal.save(live)
    let cold = try #require(try journal.openGroupedEdit(live.id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordPublication(seal.proof.payload, member: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.finishReview(intent.id) }
    let retry = try #require(try journal.openGroupedEdit(live.id))
    #expect(retry.snapshot.head.reviewIntent?.id == intent.id)
    let fresh = GroupedCopyReviewIntent(id: UUID(), kind: .publication, preparedRevision: retry.revision,
        members: [0], inventoryDigest: String(repeating: "d", count: 64))
    try retry.beginReview(fresh); try journal.save(retry)
    try retry.recordPublication(seal.proof.payload, member: 0); try retry.finishReview(fresh.id); try journal.save(retry)
    #expect(retry.snapshot.head.state == .completed)
}

@Test func groupedColdPersistedReversalReviewRequiresFreshAction() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal); try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    let areas = try fixture.declare(live), seal = try fixture.seal(area: areas[0])
    try live.recordSeal(seal, member: 0); try live.sealGroup(0)
    try live.recordPublication(seal.proof.payload, member: 0); try live.settleGroup(0); try live.close(); try journal.save(live)
    let undo = try #require(try journal.openGroupedEdit(live.id))
    try undo.beginReverse(member: 0, intent: UUID()); try journal.save(undo)
    let intent = GroupedCopyReviewIntent(id: UUID(), kind: .reversal, preparedRevision: undo.revision,
        members: [0], inventoryDigest: String(repeating: "e", count: 64))
    try undo.beginReview(intent); try journal.save(undo)
    let cold = try #require(try journal.openGroupedEdit(live.id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordReversal(seal.proof.payload, member: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.finishReview(intent.id) }
    let retry = try #require(try journal.openGroupedEdit(live.id))
    let fresh = GroupedCopyReviewIntent(id: UUID(), kind: .reversal, preparedRevision: retry.revision,
        members: [0], inventoryDigest: String(repeating: "f", count: 64))
    try retry.beginReview(fresh); try journal.save(retry)
    try retry.recordReversal(seal.proof.payload, member: 0); try retry.finishReview(fresh.id); try journal.save(retry)
    #expect(retry.snapshot.head.state == .undone)
}

@Test func groupedSimulatedRollbackFailureReopensDurableEvidenceBeforeNewAuthority() throws {
    // This is an injected rollback failure with a real uncommitted transaction,
    // not a claim of genuine device-level rollback I/O fault qualification.
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let save = GroupedModelFaultGate(), rollback = GroupedModelFaultGate()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(
        beforeSaveCommit: { try save.check() }, beforeSaveRollback: { try rollback.check() }))
    try journal.upgradeForGroupedCopy()
    let live = try journal.beginGroupedEdit(members: fixture.manifest)
    _ = try fixture.declare(live); try journal.save(live)
    try live.recordNeverStaged(member: 0)
    save.enable(); rollback.enable()
    #expect(throws: FileOperationFailure.ioFailure) { try journal.save(live) }
    save.disable(); rollback.disable()
    // Another SQLite connection sees only the committed declaration while the
    // injected failing connection would still expose its uncommitted candidate.
    #expect(try groupedModelDurablePhase(fixture, id: live.id) == "declared")
    let reopened = try #require(try journal.openGroupedEdit(live.id))
    #expect(reopened.snapshot.members[0].progress.phase == "declared")
    #expect(!live.valid)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try reopened.recordNeverStaged(member: 0) }
}

@Test func groupedFailedSaveDoesNotAdoptIdenticalReplacementDatabase() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    let held = fixture.root.appendingPathComponent("held-owned-catalog.sqlite")
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(afterSaveCommit: {
        // Owned fixture only: same bytes at a different inode are still a replacement.
        try FileManager().moveItem(at: database, to: held)
        try FileManager().copyItem(at: held, to: database)
    }))
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifest)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    #expect(!edit.valid)
    #expect(throws: (any Error).self) { _ = try journal.openGroupedEdit(edit.id) }
    #expect(try journal.inspectSummaries().refused.contains(database))
    #expect(FileManager().fileExists(atPath: held.path))
}

@Test func groupedSessionAuthorityEndsWithItsWriterAndCatalogScansHonorCancellation() throws {
    let fixture = try GroupedModelFixture(count: 1); defer { fixture.remove() }
    let edit: GroupedCopyEditSession
    do {
        let journal = try OperationJournal(fixture.journal); try journal.upgradeForGroupedCopy()
        edit = try journal.beginGroupedEdit(members: fixture.manifest); try journal.save(edit)
    }
    #expect(!edit.valid)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.close() }
    let cancellation = OperationCancellation()
    let journal = try OperationJournal(fixture.journal, cancellation: cancellation)
    _ = try journal.inspectSummaries()
    cancellation.cancel()
    #expect(throws: CancellationError.self) { _ = try journal.unfinishedCount() }
    #expect(throws: CancellationError.self) { _ = try journal.maintenance(compact: true) }
}
