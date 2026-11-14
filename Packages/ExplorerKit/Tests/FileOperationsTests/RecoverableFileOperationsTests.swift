import Darwin
import Foundation
@_spi(ArchiveProduction) @_spi(ApplicationOwnership) @testable import FileOperations
import Testing

private struct RecoveryFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        let base = try FileOperationTestFixtures.base()
        root = base.appendingPathComponent("recovery-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
    }
    func file(_ name: String, in parent: URL? = nil, text: String = "original") throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func remove() { try? FileManager().removeItem(at: root) }
}

private func setGeneratedTrashAttribute(_ bytes: Data, name: String, at url: URL) throws {
    let result = bytes.withUnsafeBytes {
        setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    guard result == 0 else { throw FileOperationFailure.ioFailure }
}

@Test func distributionTrashHoldRefusesBeforeSourceOrJournalMutation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("held.txt", text: "generated held source")
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            nativeTrashPolicy: .held)
    let result = await engine.perform(.trash(sources: [source]))
    #expect(result.result.disposition != .succeeded)
    #expect(result.recordID == nil)
    #expect(try Data(contentsOf: source) == Data("generated held source".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
}

@Test func distributionTrashHoldRefusesGuardedRouteBeforeSourceOrJournalMutation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("guarded-held.txt", text: "generated guarded source")
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            nativeTrashPolicy: .held)
    await #expect(throws: FileOperationFailure.unsupported) {
        try await engine.prepareGuardedTrash([source], protecting: [])
    }
    let ordinary = RecoverableFileOperations(journalDirectory: fixture.journal,
                                              nativeTrashPolicy: .existingVerifiedPaths)
    let reviewed = try await ordinary.prepareGuardedTrash([source], protecting: [])
    let result = await engine.performGuardedTrash(reviewed)
    #expect(result.result.disposition != .succeeded)
    #expect(result.result.items.first?.status == .failed(.unsupported))
    #expect(result.recordID == nil)
    #expect(try Data(contentsOf: source) == Data("generated guarded source".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
}

@Test func distributionTrashHoldKeepsOlderHistoryReadableAndRefusesInverse() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = try fixture.file("older.txt", text: "generated older source")
    let target = fixture.destination.appendingPathComponent("older.txt")
    let forward = context.service()
    #expect(await forward.upgradeLocalTextHistory().status == .succeeded)
    let moved = await forward.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let recordID = try #require(moved.recordID)
    let held = RecoverableFileOperations(journalDirectory: context.journal, protecting: [context.state],
                                          nativeTrashPolicy: .held)
    let inspection = try await held.inspectExistingHistory()
    #expect(inspection.records.contains { $0.id == recordID })
    #expect(inspection.records.first(where: { $0.id == recordID })?.nativeRegularFileTrashContract == false)
    #expect((await held.undo(recordID: recordID)).result.disposition != .succeeded)
    #expect((await held.recover(recordID: recordID)).result.disposition != .succeeded)
    #expect((await held.cleanupRecovery(recordID: recordID)).result.disposition != .succeeded)
    for policy in [NativeTrashMutationPolicy.regularFilesOnly, .regularFilesAndDirectories] {
        let narrow = RecoverableFileOperations(journalDirectory: context.journal, protecting: [context.state],
                                               nativeTrashPolicy: policy)
        #expect((try await narrow.inspectExistingHistory()).records.contains { $0.id == recordID })
        let olderGroup = try #require(try await narrow.inspectOwnedTrash().groups.first { $0.id == recordID })
        #expect(!olderGroup.canRestoreWholeGroup && !olderGroup.canDeleteWholeGroup)
        #expect((await narrow.undo(recordID: recordID)).result.disposition != .succeeded)
        #expect((await narrow.recover(recordID: recordID)).result.disposition != .succeeded)
        #expect((await narrow.cleanupRecovery(recordID: recordID)).result.disposition != .succeeded)
        do { _ = try await narrow.prepareOwnedTrashDeletion(recordID: recordID)
            Issue.record("narrow Trash must not prepare older permanent Delete") }
        catch { }
    }
    #expect(try Data(contentsOf: target) == Data("generated older source".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try OperationJournal(context.journal).inspectRecord(recordID)?.state == "committed")
}

@Test func regularFileTrashPolicyRefusesDirectoryAndMixedSelectionBeforeJournal() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let file = try fixture.file("ordinary.txt", text: "generated regular source")
    let folder = fixture.source.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    _ = try fixture.file("child.txt", in: folder, text: "generated folder child")
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, nativeTrashPolicy: .regularFilesOnly)
    for sources in [[folder], [file, folder]] {
        let result = await engine.perform(.trash(sources: sources))
        #expect(result.result.disposition != .succeeded)
        #expect(result.recordID == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }
    #expect(try Data(contentsOf: file) == Data("generated regular source".utf8))
    #expect(try Data(contentsOf: folder.appendingPathComponent("child.txt")) == Data("generated folder child".utf8))
}

private struct GeneratedOwnedTrashContext {
    let journal: URL
    let state: URL
    let destination: URL
    init(_ fixture: RecoveryFixture) throws {
        state = fixture.root.appendingPathComponent("private-state", isDirectory: true)
        journal = state.appendingPathComponent("operation-recovery", isDirectory: true)
        destination = fixture.destination
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        var hooks = hooks
        #if DEBUG
        // This fixture exercises the previously admitted owned-Trash v3
        // deletion path. Native v11 has its own Trash/Undo tests below.
        if hooks.nativeTrashQualificationMode == nil { hooks.nativeTrashQualificationMode = .strict }
        #endif
        let destination = destination
        let legacy = LocalFileOperations(trash: { source in
            let returned = destination.appendingPathComponent(source.lastPathComponent,
                                                              isDirectory: source.hasDirectoryPath)
            try FileManager.default.moveItem(at: source, to: returned)
            return returned
        })
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks, legacy: legacy,
                                         protecting: [state])
    }
    func coldService() -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, protecting: [state])
    }
}

private final class GeneratedPostRenameSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var renamed = false
    private var fired = false
    func didRename() { lock.withLock { renamed = true } }
    func beforeSaveCommit() throws {
        let fail = lock.withLock { () -> Bool in
            guard renamed, !fired else { return false }
            fired = true
            return true
        }
        if fail { throw FileOperationFailure.ioFailure }
    }
}

@Test func ownedTrashWholeGroupDeleteIsDurableAndKeepsForeignLinkTarget() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let file = try fixture.file("one", text: "generated one")
    let outside = try fixture.file("outside", text: "preserved")
    let folder = fixture.source.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let nested = try fixture.file("nested", in: folder, text: "generated nested")
    try FileManager.default.linkItem(at: nested, to: folder.appendingPathComponent("nested-hardlink"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside-link"),
                                               withDestinationURL: outside)
    let service = context.service()
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [file, folder]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let page = try await service.inspectOwnedTrash()
    let group = try #require(page.groups.first { $0.id == id })
    #expect(group.entries.count == 2 && group.canRestoreWholeGroup && group.canDeleteWholeGroup)
    #expect(group.entries.first?.recordedByteCount == UInt64(Data("generated one".utf8).count))
    #expect(group.entries.last?.isDirectory == true && group.entries.last?.recordedByteCount == nil)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let result = await service.permanentlyDeleteOwnedTrash(plan)
    #expect(result.result.disposition == .succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("one").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("folder").path))
    #expect(try Data(contentsOf: outside) == Data("preserved".utf8))
    let cold = try await context.coldService().inspectOwnedTrash()
    let completed = try #require(cold.groups.first { $0.id == id })
    #expect(completed.confirmedDeletionCount == 2 && !completed.canRestoreWholeGroup && !completed.canDeleteWholeGroup)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 8)
    #expect((await service.undo(recordID: id)).result.disposition != .succeeded)
    #expect((await service.permanentlyDeleteOwnedTrash(plan)).result.disposition != .succeeded)
}

@Test func ownedTrashChangedPreflightPreservesUndoAndReturnedItem() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let file = try fixture.file("changed", text: "generated original")
    let service = context.service()
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [file]))
    let id = try #require(moved.recordID)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let returned = fixture.destination.appendingPathComponent("changed")
    try Data("changed after preparation".utf8).write(to: returned)
    let result = await service.permanentlyDeleteOwnedTrash(plan)
    #expect(result.result.disposition != .succeeded)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 3)
    #expect(FileManager.default.fileExists(atPath: returned.path))
    #expect(try await service.inspectOwnedTrash().groups.first?.canRestoreWholeGroup == true)
}

@Test func ownedTrashInterruptedUnlinkStaysReviewOnlyAfterColdOpen() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let folder = fixture.source.appendingPathComponent("interrupted", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    _ = try fixture.file("one", in: folder)
    _ = try fixture.file("two", in: folder)
    var hooks = RecoveryHooks()
    hooks.afterOwnedTrashUnlink = { count in if count == 1 { throw CancellationError() } }
    let service = context.service(hooks)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [folder]))
    let id = try #require(moved.recordID)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let result = await service.permanentlyDeleteOwnedTrash(plan)
    #expect(result.result.disposition != .succeeded)
    let cold = try await context.coldService().inspectOwnedTrash()
    let group = try #require(cold.groups.first { $0.id == id })
    #expect(group.reviewRequired && !group.canRestoreWholeGroup && !group.canDeleteWholeGroup)
    #expect(group.entries.first?.state == .uncertain)
    let record: JournalRecord
    do {
        let journal = try OperationJournal(context.journal)
        let inspected = try journal.inspectRecord(id)
        record = try #require(inspected)
    }
    #expect(record.version == 8 && record.state == "trashDeleteReview")
    #expect(record.steps.first?.ownedTrashStageURL != nil)
    #expect((await service.undo(recordID: id)).result.disposition != .succeeded)
    #expect((await service.recover(recordID: id)).result.disposition != .succeeded)
    do { _ = try await service.prepareOwnedTrashDeletion(recordID: id); Issue.record("v8 must not retry") }
    catch { }
}

@Test func ownedTrashLegacyCatalogCannotPreparePermanentDelete() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let file = try fixture.file("legacy")
    let service = context.service()
    let moved = await service.perform(.trash(sources: [file]))
    let id = try #require(moved.recordID)
    #expect(try await service.inspectOwnedTrash().groups.isEmpty)
    do { _ = try await service.prepareOwnedTrashDeletion(recordID: id); Issue.record("catalog 3 must refuse") }
    catch { }
    #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("legacy").path))
}

@Test func ownedTrashProtectedReturnedLocationRefusesBeforeUndoInvalidation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let file = try fixture.file("protected")
    let state = context.state
    let legacy = LocalFileOperations(trash: { source in
        let returned = state.appendingPathComponent("returned-protected")
        try FileManager.default.moveItem(at: source, to: returned)
        return returned
    })
    var olderHooks = RecoveryHooks()
    #if DEBUG
    olderHooks.nativeTrashQualificationMode = .strict
    #endif
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: olderHooks,
                                            legacy: legacy, protecting: [context.state])
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [file]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let outcome = await service.permanentlyDeleteOwnedTrash(plan)
    #expect(outcome.result.disposition != .succeeded)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 3)
    #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("returned-protected").path))
}

@Test func ownedTrashWholeJobRestoreRefusesOccupiedOriginalWithoutDeletingEitherItem() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let original = try fixture.file("occupied")
    let service = context.service()
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [original]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    _ = try fixture.file("occupied", text: "new occupant")
    let restored = await service.undo(recordID: id)
    #expect(restored.result.disposition != .succeeded)
    #expect(try Data(contentsOf: original) == Data("new occupant".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("occupied").path))
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.state == "needsReview")
}

@Test func ownedTrashCancellationDrainsCurrentItemAndKeepsRemainingRecorded() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let first = try fixture.file("first")
    let second = try fixture.file("second")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var hooks = RecoveryHooks()
    hooks.afterOwnedTrashUnlink = { count in
        if count == 1 {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw FileOperationFailure.unavailable }
        }
    }
    let service = context.service(hooks)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [first, second]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let task = Task { await service.permanentlyDeleteOwnedTrash(plan) }
    #expect(await waitForRecoveryGate(entered))
    task.cancel(); release.signal()
    let result = await task.value
    #expect(result.result.cancellationRequested)
    #expect(result.result.items.map(\.status) == [.succeeded, .notStarted])
    let record: JournalRecord
    do {
        let journal = try OperationJournal(context.journal)
        let inspected = try journal.inspectRecord(id)
        record = try #require(inspected)
    }
    #expect(record.version == 8 && record.state == "trashDeleteReview")
    #expect(record.ownedTrash?.confirmedCount == 1 && record.ownedTrash?.retainedCount == 1)
    #expect(!FileManager.default.fileExists(atPath: context.destination.appendingPathComponent("first").path))
    #expect(FileManager.default.fileExists(atPath: context.destination.appendingPathComponent("second").path))
    let cold = try await context.coldService().inspectOwnedTrash()
    #expect(cold.groups.first?.reviewRequired == true)
}

@Test func ownedTrashStagedChildReplacementIsPreservedForReview() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let folder = fixture.source.appendingPathComponent("replace-child", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    _ = try fixture.file("one", in: folder)
    _ = try fixture.file("two", in: folder)
    let destination = context.destination
    var hooks = RecoveryHooks()
    hooks.afterOwnedTrashUnlink = { count in
        guard count == 1 else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        guard let stageName = names.first(where: { $0.hasPrefix(".traverse-owned-trash-delete-") }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let foreign = destination.appendingPathComponent(stageName)
            .appendingPathComponent("payload/one")
        try FileManager.default.removeItem(at: foreign)
        try Data("foreign generated child".utf8).write(to: foreign, options: .withoutOverwriting)
    }
    let service = context.service(hooks)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [folder]))
    let id = try #require(moved.recordID)
    let plan = try await service.prepareOwnedTrashDeletion(recordID: id)
    let result = await service.permanentlyDeleteOwnedTrash(plan)
    #expect(result.result.disposition != .succeeded)
    let record: JournalRecord
    do {
        let journal = try OperationJournal(context.journal)
        let inspected = try journal.inspectRecord(id)
        record = try #require(inspected)
    }
    let stage = try #require(record.steps.first?.ownedTrashStageURL)
    let foreign = stage.appendingPathComponent("one")
    #expect(try Data(contentsOf: foreign) == Data("foreign generated child".utf8))
    #expect(record.steps.first?.ownedTrashDeletion == .uncertain)
}

#if DEBUG
// This exercises the Debug-only synthetic metadata hook. Production Trash and
// Undo coverage below still compile and run in the optimized configuration.
@Test func ordinaryTrashCannotInheritRetainedTextDirectoryModeFromDebugHook() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("saved-version", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("generated.txt", in: source)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    var hooks = RecoveryHooks()
    hooks.nativeTrashQualificationMode = .retainedTextDirectoryRootNativeMetadata
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    final class Findings: @unchecked Sendable {
        let lock = NSLock(); var values: [NativeTrashFamilyFinding] = []
        func append(_ finding: NativeTrashFamilyFinding) { lock.withLock { values.append(finding) } }
        var snapshot: [NativeTrashFamilyFinding] { lock.withLock { values } }
    }
    let findings = Findings()
    FileOperationDiagnostics.install { event in
        if event.checkpoint == .nativeTrashFingerprint, let value = event.nativeTrashFinding {
            findings.append(value)
        }
    }
    defer { FileOperationDiagnostics.install(nil) }
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy)
    let result = await service.perform(.trash(sources: [source]), progress: { _ in })
    #expect(findings.snapshot.contains(.complete(nativeChanged: [.quarantine], osAccessAttributeChanged: true)))
    #expect(result.result.disposition == .partial)
    let id = try #require(result.recordID)
    #expect(try OperationJournal(fixture.journal).inspectRecord(id)?.state == "needsReview")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func additiveRootDirectoryCandidateRecordsWitnessAndColdUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("Additive.txt", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    let second = fixture.source.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    _ = try fixture.file("OtherChild.txt", in: second, text: "other generated body")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("One.txt", in: source, text: "generated body")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty", isDirectory: true),
                                            withIntermediateDirectories: false)
    let mark = Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: mark, osAccess: Data(repeating: 0x5A, count: 72))
    let restoredMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0086;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8),
        osAccess: Data(repeating: 0xA5, count: 72))
    let destination = fixture.destination
    let legacy = LocalFileOperations(trash: { supplied in
        let returned = destination.appendingPathComponent(supplied.lastPathComponent,
            isDirectory: supplied.hasDirectoryPath)
        try FileManager.default.moveItem(at: supplied, to: returned)
        return returned
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks, legacy: legacy,
                                            protecting: [context.state],
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let result = await service.perform(.trash(sources: [source, second]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let record = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(record.steps.count == 2)
    let step = try #require(record.steps.first { $0.source == source })
    let after = try #require(step.after)
    let proof = try #require(step.nativeTrashRootAddition)
    #expect(record.version == 9 && record.state == "committed")
    #expect(proof.beforeRootQuarantine == nil && proof.afterRootQuarantine.length > 0)
    #expect(proof.validatesAdditiveRoot(before: step.before, after: after))
    var missingWitness = record
    missingWitness.steps[0].nativeTrashRootAddition = nil
    do { try OperationJournal.validate(missingWitness); Issue.record("v9 must require the forward witness") }
    catch { }
    #expect(try await service.inspectOwnedTrash().groups.first?.canRestoreWholeGroup == true)
    var inverseHooks = hooks
    inverseHooks.nativeTrashInverseRestoredSyntheticRootMetadata = restoredMetadata
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: inverseHooks,
                                         protecting: [context.state],
                                         nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
    let undone = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(undone.state == "undone" && undone.steps.allSatisfy(\.undone))
    let restoredStep = try #require(undone.steps.first { $0.source == source })
    let actualRestored = try verifiedTree(source, cancellation: OperationCancellation(),
        nativeTrashSyntheticRootMetadata: restoredMetadata)
    #expect(restoredStep.after == actualRestored)
    #expect(restoredStep.after != proof.after)
    #expect(restoredStep.after?.identity.sameObject(as: after.identity) == true)
    let coldView = try await cold.recoveryRecords()
    #expect(coldView.records.first { $0.id == id }?.canUndo == false)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("One.txt").path))
    #expect(try Data(contentsOf: source.appendingPathComponent("One.txt")) == Data("generated body".utf8))
    #expect(try Data(contentsOf: second.appendingPathComponent("OtherChild.txt")) == Data("other generated body".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test func additiveRootDirectoryInversePreservesOriginalSlotCollision() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("Collision", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("Collision", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("Child.txt", in: source, text: "owned generated body")
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    hooks.nativeTrashInverseRestoredSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0086;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
        legacy: legacy, protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let sentinel = try fixture.file("Sentinel.txt", in: source, text: "collision stays")
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
        protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect((await cold.undo(recordID: id)).result.disposition != .succeeded)
    #expect(try Data(contentsOf: sentinel) == Data("collision stays".utf8))
    #expect(try Data(contentsOf: target.appendingPathComponent("Child.txt")) == Data("owned generated body".utf8))
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.state == "needsReview")
}

@Test func additiveRootDirectoryInverseJournalFailureAfterRenameRequiresReview() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("JournalFault", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("JournalFault", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("Child.txt", in: source, text: "retained generated body")
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    hooks.nativeTrashInverseRestoredSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0086;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8),
        osAccess: Data(repeating: 0xA5, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
        legacy: legacy, protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let fault = GeneratedPostRenameSaveFault()
    var inverseHooks = hooks
    inverseHooks.afterRename = { fault.didRename() }
    inverseHooks.journalHooks.beforeSaveCommit = { try fault.beforeSaveCommit() }
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: inverseHooks,
        protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    let undone = await cold.undo(recordID: id)
    #expect(undone.result.disposition != .succeeded)
    #expect(undone.result.items.contains { $0.role == .job && $0.status != .succeeded })
    #expect(undone.result.items.contains { $0.role == .transfer && $0.destination == source
        && $0.status == .failed(.recoveryUncertain) })
    #expect(!undone.result.items.contains { $0.destination == source && $0.status == .notStarted })
    #expect(try Data(contentsOf: source.appendingPathComponent("Child.txt")) == Data("retained generated body".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let durable = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(durable.state == "needsReview")
    #expect((await RecoverableFileOperations(journalDirectory: context.journal,
        protecting: [context.state]).undo(recordID: id)).result.disposition != .succeeded)
}

@Test func additiveRootDirectoryCandidateDeletePreservesWitnessAcrossColdBarrier() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("DeleteCandidate", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("One.txt", in: source)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks, legacy: legacy,
                                            protecting: [context.state],
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
                                         protecting: [context.state])
    let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
    #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition == .succeeded)
    let deletion = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(deletion.version == 10 && deletion.state == "trashDeleted")
    #expect(deletion.steps.first?.nativeTrashRootAddition != nil)
    var missing = deletion
    missing.steps[0].nativeTrashRootAddition = nil
    do { try OperationJournal.validate(missing); Issue.record("v10 must require the original forward witness") }
    catch { }
    var missingOrigin = deletion
    missingOrigin.ownedTrash?.sourceVersion = nil
    do { try OperationJournal.validate(missingOrigin); Issue.record("v10 must retain its v9 origin fence") }
    catch { }
    let reopened = RecoverableFileOperations(journalDirectory: context.journal, protecting: [context.state])
    let group = try #require(try await reopened.inspectOwnedTrash().groups.first { $0.id == id })
    #expect(group.confirmedDeletionCount == 1 && group.reviewRequired == false)
    #expect((await reopened.undo(recordID: id)).result.disposition != .succeeded)
}

@Test func additiveRootDirectoryDeleteSavesProvenRootStageImageBeforeUnlink() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("StageRewrite", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("StageRewrite", isDirectory: true)
    let second = fixture.source.appendingPathComponent("SecondStage", isDirectory: true)
    let secondTarget = fixture.destination.appendingPathComponent("SecondStage", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    _ = try fixture.file("Child.txt", in: source, text: "generated payload")
    _ = try fixture.file("OtherChild.txt", in: second, text: "second generated payload")
    let mark = Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: mark, osAccess: Data(repeating: 0x5A, count: 72))
    let destination = fixture.destination
    let legacy = LocalFileOperations(trash: { supplied in
        let returned = destination.appendingPathComponent(supplied.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: supplied, to: returned)
        return returned
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
        legacy: legacy, protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [source, second]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    var deleteHooks = hooks
    deleteHooks.nativeTrashDeleteStagedSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0086;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8),
        osAccess: Data(repeating: 0xA5, count: 72))
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: deleteHooks,
        protecting: [context.state])
    let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
    #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition == .succeeded)
    let deletion = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(deletion.steps.count == 2)
    #expect(deletion.version == 10 && deletion.state == "trashDeleted")
    for step in deletion.steps {
        let proof = try #require(step.nativeTrashRootAddition)
        #expect(step.ownedTrashDeletion == .deleteConfirmed)
        #expect(step.after != proof.after && step.after?.identity.sameObject(as: proof.after.identity) == true)
        #expect(proof.validatesAdditiveRoot(before: step.before, after: proof.after))
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: secondTarget.path))
    let reopened = RecoverableFileOperations(journalDirectory: context.journal, protecting: [context.state])
    let group = try #require(try await reopened.inspectOwnedTrash().groups.first { $0.id == id })
    #expect(group.confirmedDeletionCount == 2 && !group.reviewRequired)
}

@Test func additiveRootDirectoryDeleteRefusesOtherFamilyOrChangedDescendantBeforeUnlink() async throws {
    for changedDescendant in [false, true] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let context = try GeneratedOwnedTrashContext(fixture)
        let source = fixture.source.appendingPathComponent("RefusedStage", isDirectory: true)
        let target = fixture.destination.appendingPathComponent("RefusedStage", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try fixture.file("Child.txt", in: source, text: "original generated payload")
        let mark = Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
        let access = Data(repeating: 0x5A, count: 72)
        var hooks = RecoveryHooks()
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: mark, osAccess: access)
        let legacy = LocalFileOperations(trash: { supplied in
            try FileManager.default.moveItem(at: supplied, to: target)
            return target
        })
        let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
            legacy: legacy, protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
        #expect(await service.upgradeLocalTextHistory().status == .succeeded)
        let moved = await service.perform(.trash(sources: [source]))
        #expect(moved.result.disposition == .succeeded)
        let id = try #require(moved.recordID)
        var deleteHooks = hooks
        if changedDescendant {
            deleteHooks.nativeTrashDeleteAfterStageRename = { stage in
                try Data("changed generated payload".utf8).write(
                    to: stage.appendingPathComponent("Child.txt"))
            }
        } else {
            deleteHooks.nativeTrashDeleteStagedSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
                quarantine: mark, osAccess: access, other: Data("other family".utf8))
        }
        let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: deleteHooks,
            protecting: [context.state])
        let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
        #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition != .succeeded)
        let review = try #require(try OperationJournal(context.journal).inspectRecord(id))
        #expect(review.version == 10 && review.state == "trashDeleteReview")
        #expect(review.steps.first?.ownedTrashDeletion == .uncertain)
        let stage = try #require(review.steps.first?.ownedTrashStageURL)
        let body = try Data(contentsOf: stage.appendingPathComponent("Child.txt"))
        #expect(body == Data((changedDescendant ? "changed generated payload" : "original generated payload").utf8))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Test func additiveRootDirectoryDeleteJournalFailureRetainsPrivatePayload() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("StageJournalFault", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("StageJournalFault", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("Child.txt", in: source, text: "retained generated payload")
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
        legacy: legacy, protecting: [context.state], nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let fault = GeneratedPostRenameSaveFault()
    var deleteHooks = hooks
    deleteHooks.nativeTrashDeleteStagedSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0086;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8),
        osAccess: Data(repeating: 0xA5, count: 72))
    deleteHooks.nativeTrashDeleteAfterStageRename = { _ in fault.didRename() }
    deleteHooks.journalHooks.beforeSaveCommit = { try fault.beforeSaveCommit() }
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: deleteHooks,
        protecting: [context.state])
    let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
    #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition != .succeeded)
    let review = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(review.version == 10 && review.state == "trashDeleteReview")
    #expect(review.steps.first?.ownedTrashDeletion == .uncertain)
    let stage = try #require(review.steps.first?.ownedTrashStageURL)
    #expect(try Data(contentsOf: stage.appendingPathComponent("Child.txt"))
        == Data("retained generated payload".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let reopened = RecoverableFileOperations(journalDirectory: context.journal, protecting: [context.state])
    #expect((await reopened.undo(recordID: id)).result.disposition != .succeeded)
}

@Test func ownedTrashStageFamilyProofAllowsOSAccessOnlyAndRefusesRemovedMark() throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("StageFamily", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("Child.txt", in: source, text: "generated stable body")
    let mark = Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let beforeSynthetic = try NativeTrashSyntheticRootMetadata(
        quarantine: mark, osAccess: Data(repeating: 0x5A, count: 72))
    let afterSynthetic = try NativeTrashSyntheticRootMetadata(
        quarantine: mark, osAccess: Data(repeating: 0xA5, count: 72))
    let removedMark = try NativeTrashSyntheticRootMetadata(osAccess: Data(repeating: 0xA5, count: 72))
    let beforeFamilies = NativeTrashFamilyCollector()
    let before = try verifiedTree(source, cancellation: OperationCancellation(),
        nativeTrashFamilyCollector: beforeFamilies, nativeTrashSyntheticRootMetadata: beforeSynthetic)
    let afterFamilies = NativeTrashFamilyCollector()
    let after = try verifiedTree(source, cancellation: OperationCancellation(),
        nativeTrashFamilyCollector: afterFamilies, nativeTrashSyntheticRootMetadata: afterSynthetic)
    let prior = try #require(beforeFamilies.snapshot())
    let later = try #require(afterFamilies.snapshot())
    #expect(prior.permitsOwnedTrashStagingRootSecurityRewrite(comparedWith: later,
        before: before, staged: after))
    let removedFamilies = NativeTrashFamilyCollector()
    let removed = try verifiedTree(source, cancellation: OperationCancellation(),
        nativeTrashFamilyCollector: removedFamilies, nativeTrashSyntheticRootMetadata: removedMark)
    let withoutMark = try #require(removedFamilies.snapshot())
    #expect(!prior.permitsOwnedTrashStagingRootSecurityRewrite(
        comparedWith: withoutMark, before: before, staged: removed))
}

@Test func additiveRootDirectoryCandidateRefusesChangedChildAndCountsJobSeparately() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let first = fixture.source.appendingPathComponent("First.txt", isDirectory: true)
    let second = fixture.source.appendingPathComponent("Second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    _ = try fixture.file("One.txt", in: first)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let destination = fixture.destination
    let legacy = LocalFileOperations(trash: { supplied in
        let returned = destination.appendingPathComponent(supplied.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: supplied, to: returned)
        try Data("changed generated body".utf8).write(to: returned.appendingPathComponent("One.txt"))
        return returned
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy,
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    let result = await service.perform(.trash(sources: [first, second]))
    #expect(result.result.disposition == .partial)
    #expect(result.result.items.filter { $0.role == .transfer }.count == 2)
    #expect(result.result.items.filter { $0.role == .job }.count == 1)
    #expect(result.result.items.last?.status == .notStarted)
    #expect(FileManager.default.fileExists(atPath: second.path))
    let id = try #require(result.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(record.version == 9 && record.state == "needsReview")
    #expect(record.steps.isEmpty && record.trashIntents.count == 1)
}

@Test func additiveRootProofRejectsPreexistingOrRemovedRootMarkWithoutXattrWrites() throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("Marked", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let old = try NativeTrashSyntheticRootMetadata(quarantine: Data("0086;old".utf8))
    let rewritten = try NativeTrashSyntheticRootMetadata(quarantine: Data("0082;new".utf8),
                                                         osAccess: Data(repeating: 0x5A, count: 72))
    let removed = try NativeTrashSyntheticRootMetadata(osAccess: Data(repeating: 0x5A, count: 72))
    let priorCollector = NativeTrashFamilyCollector()
    let before = try verifiedTree(source, cancellation: OperationCancellation(),
                                  nativeTrashFamilyCollector: priorCollector,
                                  nativeTrashSyntheticRootMetadata: old)
    let prior = try #require(priorCollector.snapshot())
    let changedCollector = NativeTrashFamilyCollector()
    let after = try verifiedTree(source, cancellation: OperationCancellation(),
                                 nativeTrashFamilyCollector: changedCollector,
                                 nativeTrashSyntheticRootMetadata: rewritten)
    let changed = try #require(changedCollector.snapshot())
    let rewrite = try #require(prior.rootMetadataProof(comparedWith: changed, before: before, returned: after))
    #expect(!rewrite.validatesAdditiveRoot(before: before, after: after))
    let removedCollector = NativeTrashFamilyCollector()
    let without = try verifiedTree(source, cancellation: OperationCancellation(),
                                   nativeTrashFamilyCollector: removedCollector,
                                   nativeTrashSyntheticRootMetadata: removed)
    let later = try #require(removedCollector.snapshot())
    #expect(prior.rootMetadataProof(comparedWith: later, before: before, returned: without) == nil)

    let emptyCollector = NativeTrashFamilyCollector()
    let emptyBefore = try verifiedTree(source, cancellation: OperationCancellation(),
                                       nativeTrashFamilyCollector: emptyCollector)
    let empty = try #require(emptyCollector.snapshot())
    let valid = try #require(empty.rootMetadataProof(comparedWith: changed,
        before: emptyBefore, returned: after))
    #expect(valid.validatesAdditiveRoot(before: emptyBefore, after: after))
    for field in ["afterDescendantQuarantine", "afterDescendantOSAccess", "afterDescendantIdentity"] {
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        encoded[field] = Data(repeating: 0xFF, count: 32).base64EncodedString()
        let forged = try JSONDecoder().decode(NativeTrashRootMetadataProofV4.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        #expect(!forged.validatesAdditiveRoot(before: emptyBefore, after: after))
    }
}

@Test func additiveRootDirectoryCandidateRefusesReplacementAndExtraRootFamily() async throws {
    for changedIdentity in [true, false] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent(changedIdentity ? "Replacement" : "ExtraFamily",
                                                           isDirectory: true)
        let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try fixture.file("One.txt", in: source, text: "same generated body")
        var hooks = RecoveryHooks()
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72),
            other: changedIdentity ? nil : Data("generated extra family".utf8))
        let legacy = LocalFileOperations(trash: { supplied in
            try FileManager.default.moveItem(at: supplied, to: target)
            if changedIdentity {
                let child = target.appendingPathComponent("One.txt")
                let body = try Data(contentsOf: child)
                try FileManager.default.removeItem(at: child)
                try body.write(to: child, options: .withoutOverwriting)
            }
            return target
        })
        let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy,
                                                nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
        let result = await service.perform(.trash(sources: [source]))
        #expect(result.result.disposition == .partial)
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview" && record.steps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("One.txt").path))
    }
}

@Test func additiveRootDirectoryCandidateRechecksBeforeCallAndAfterSync() async throws {
    final class Count: @unchecked Sendable {
        let lock = NSLock(); var calls = 0
        func call() { lock.withLock { calls += 1 } }
        var callCount: Int { lock.withLock { calls } }
    }
    for postSync in [false, true] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("Changing", isDirectory: true)
        let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let child = try fixture.file("One.txt", in: source)
        let count = Count()
        var hooks = RecoveryHooks()
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        if postSync {
            hooks.beforeSync = { _ in
                try Data("changed after first verification".utf8).write(to: target.appendingPathComponent("One.txt"))
            }
        } else {
            hooks.nativeTrashBeforeSourceRecheck = {
                try Data("changed before native call".utf8).write(to: child)
            }
        }
        let legacy = LocalFileOperations(trash: { supplied in
            count.call()
            try FileManager.default.moveItem(at: supplied, to: target)
            return target
        })
        let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy,
                                                nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
        let result = await service.perform(.trash(sources: [source]))
        #expect(result.result.disposition != .succeeded)
        #expect(count.callCount == (postSync ? 1 : 0))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview" && record.steps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: postSync ? target.path : source.path))
    }
}

@Test func additiveRootDirectoryColdUndoAndDeleteRequireExactRecordedAfterImage() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("ChangedAfter", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("One.txt", in: source)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks, legacy: legacy,
                                            protecting: [context.state],
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let result = await service.perform(.trash(sources: [source]))
    let id = try #require(result.recordID)
    #expect(result.result.disposition == .succeeded)
    let cold = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks,
                                         protecting: [context.state])
    let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
    try Data("changed after commit".utf8).write(to: target.appendingPathComponent("One.txt"))
    #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition != .succeeded)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 9)
    #expect((await cold.undo(recordID: id)).result.disposition != .succeeded)
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func additiveRootDirectoryPrecallRejectsReplacedChildBeforeNativeMove() async throws {
    final class Calls: @unchecked Sendable {
        let lock = NSLock(); var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("SameBytes", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let child = try fixture.file("One.txt", in: source, text: "same generated bytes")
    let calls = Calls()
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    hooks.nativeTrashBeforeSourceRecheck = {
        let bytes = try Data(contentsOf: child)
        try FileManager.default.removeItem(at: child)
        try bytes.write(to: child, options: .withoutOverwriting)
    }
    let legacy = LocalFileOperations(trash: { supplied in
        calls.increment()
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy,
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition != .succeeded && calls.value == 0)
    #expect(FileManager.default.fileExists(atPath: child.path))
    let id = try #require(result.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(record.state == "needsReview" && record.steps.isEmpty)
}

@Test func ordinaryTrashDefaultsStayV3AndKeepTheExistingCatalog() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = try fixture.file("ordinary")
    let service = context.service()
    let publicDefault = RecoverableFileOperations(journalDirectory: context.journal,
                                                  protecting: [context.state])
    #expect(publicDefault.nativeTrashDirectoryAdmission == .strict)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let catalogBefore = try OperationJournal(context.journal).inspectionReadiness
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 3)
    let catalogAfter = try OperationJournal(context.journal).inspectionReadiness
    #expect(catalogBefore == catalogAfter)
}

@Test func additiveRootDirectoryQACompositionIsExplicitAndDefaultsStayStrict() throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let ordinary = RecoverableFileOperations(journalDirectory: fixture.journal)
    let qa = RecoverableFileOperations(qualifyingAdditiveRootDirectoryTrashAt: fixture.journal)
    #expect(ordinary.nativeTrashDirectoryAdmission == .strict)
    #expect(qa.nativeTrashDirectoryAdmission == .additiveRootOnlyCandidate)
    #expect(qa.authoredZIPMetadataPolicy == .exactSource)
    #expect(qa.downloadAdoptionPolicy == .held)
    #if !MAC_EXPLORER_DISTRIBUTION
    let preview = RecoverableFileOperations(localPreviewAdditiveRootDirectoryTrashAt: fixture.journal)
    #expect(preview.nativeTrashDirectoryAdmission == .additiveRootOnlyCandidate)
    #expect(preview.authoredZIPMetadataPolicy == .exactSource)
    #expect(preview.downloadAdoptionPolicy == .held)
    let authoredPreview = RecoverableFileOperations(localPreviewAdditiveRootDirectoryTrashAt: fixture.journal,
        authoredZIPMetadataPolicy: .nativeCreate)
    #expect(authoredPreview.authoredZIPMetadataPolicy == .nativeCreate)
    #expect(authoredPreview.nativeTrashDirectoryAdmission == .additiveRootOnlyCandidate)
    #expect(authoredPreview.downloadAdoptionPolicy == .held)
    #endif
}

@Test func additiveRootCandidateFileOnlyJobKeepsV9AndColdDeleteUsesV10() async throws {
    // The Preview SPI uses native Trash. Inject the fixture's simulated Trash
    // through the existing internal seam so every mutation stays in this root.
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = try fixture.file("Only.txt", text: "generated file-only Trash")
    let destination = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: destination)
        return destination
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            protecting: [context.state],
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let forward = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(forward.version == 9 && forward.steps.count == 1)
    #expect(forward.steps[0].nativeTrashRootAddition == nil)
    let cold = context.coldService()
    let page = try await cold.inspectOwnedTrash()
    let group = try #require(page.groups.first { $0.id == id })
    #expect(group.canRestoreWholeGroup && group.canDeleteWholeGroup)
    let plan = try await cold.prepareOwnedTrashDeletion(recordID: id)
    #expect((await cold.permanentlyDeleteOwnedTrash(plan)).result.disposition == .succeeded)
    let deletion = try #require(try OperationJournal(context.journal).inspectRecord(id))
    #expect(deletion.version == 10 && deletion.ownedTrash?.sourceVersion == 9)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func additiveRootDirectoryColdUndoAndDeleteRefuseChangedOrMissingMark() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let context = try GeneratedOwnedTrashContext(fixture)
    let source = fixture.source.appendingPathComponent("ColdMark", isDirectory: true)
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("One.txt", in: source)
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: context.journal, hooks: hooks, legacy: legacy,
                                            protecting: [context.state],
                                            nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    #expect(await service.upgradeLocalTextHistory().status == .succeeded)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    var changedHooks = RecoveryHooks()
    changedHooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: Data("0082;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
        osAccess: Data(repeating: 0x5A, count: 72))
    let changed = RecoverableFileOperations(journalDirectory: context.journal, hooks: changedHooks,
                                            protecting: [context.state])
    let plan = try await changed.prepareOwnedTrashDeletion(recordID: id)
    #expect((await changed.permanentlyDeleteOwnedTrash(plan)).result.disposition != .succeeded)
    #expect(try OperationJournal(context.journal).inspectRecord(id)?.version == 9)
    let missing = RecoverableFileOperations(journalDirectory: context.journal,
                                            protecting: [context.state])
    #expect((await missing.undo(recordID: id)).result.disposition != .succeeded)
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: source.path))
}
#endif

@Test func recoverableCopyAndUndoRetainsCopiedObject() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let service = fixture.service()
    let copied = await service.perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    #expect(copied.result.items.map(\.status) == [.succeeded])
    let id = try #require(copied.recordID)
    let inspection = try await fixture.service().recoveryRecords()
    #expect(inspection.refusedEntries.isEmpty)
    #expect(inspection.records.first?.canUndo == true)
    let reversed = await fixture.service().undo(recordID: id)
    #expect(reversed.result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: source.path))
    #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("one").path))
    #expect(try await service.recoveryRecords().records.first?.state == "undone")
}

@Test func recoverableMoveAndRenameUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let service = fixture.service()
    let moved = await service.perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(moved.result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: source.path))
    let undone = await service.undo(recordID: try #require(moved.recordID))
    #expect(undone.result.disposition == .succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    let renamed = await service.perform(.rename(source: source, name: "renamed"))
    #expect(renamed.result.disposition == .succeeded)
    #expect(await service.undo(recordID: try #require(renamed.recordID)).result.disposition == .succeeded)
}

@Test func recoverableCreateUndoRefusesAddedChildren() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let service = fixture.service()
    let created = await service.perform(.createFolder(parent: fixture.destination, name: "new"))
    #expect(created.result.disposition == .succeeded)
    _ = try fixture.file("child", in: fixture.destination.appendingPathComponent("new"))
    let undone = await service.undo(recordID: try #require(created.recordID))
    #expect(undone.result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("new/child").path))
}

@Test func explicitReplaceRestoresDisplacedOriginalOnUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one", text: "incoming")
    let target = try fixture.file("one", in: fixture.destination, text: "displaced")
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    let conflict = try #require(plan.conflicts.first)
    let result = await service.perform(plan, resolutions: [conflict.id: .replace])
    #expect(result.result.disposition == .succeeded)
    #expect(try String(contentsOf: target, encoding: .utf8) == "incoming")
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try String(contentsOf: target, encoding: .utf8) == "displaced")
}

@Test func replaceConsentRejectsChangedDestination() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let target = try fixture.file("one", in: fixture.destination)
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    try Data("changed".utf8).write(to: target)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .replace])
    #expect(result.result.disposition == .failed)
    #expect(try String(contentsOf: target, encoding: .utf8) == "changed")
}

@Test func undoRejectsEditedCopiedBytesAndPreservesBoth() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let service = fixture.service()
    let copied = await service.perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    #expect(copied.result.disposition == .succeeded)
    let target = fixture.destination.appendingPathComponent("one")
    try Data("modified".utf8).write(to: target)
    #expect(await service.undo(recordID: try #require(copied.recordID)).result.disposition == .failed)
    #expect(try String(contentsOf: target, encoding: .utf8) == "modified")
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
}

@Test func mergePreservesSiblingsAndRequiresNestedConflictChoices() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let folder = fixture.source.appendingPathComponent("folder")
    let target = fixture.destination.appendingPathComponent("folder")
    for url in [folder, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    _ = try fixture.file("new", in: folder)
    _ = try fixture.file("same", in: folder, text: "incoming")
    _ = try fixture.file("same", in: target, text: "old")
    let untouched = try fixture.file("untouched", in: target)
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [folder], destinationDirectory: fixture.destination, move: false)
    #expect(plan.conflicts.count == 2)
    let root = try #require(plan.conflicts.first(where: { $0.canMerge }))
    let leaf = try #require(plan.conflicts.first(where: { !$0.canMerge }))
    #expect(await service.perform(plan, resolutions: [root.id: .merge]).result.disposition == .failed)
    let result = await service.perform(plan, resolutions: [root.id: .merge, leaf.id: .skip])
    #expect(result.result.disposition == .succeeded)
    #expect(try String(contentsOf: untouched, encoding: .utf8) == "original")
    #expect(try String(contentsOf: target.appendingPathComponent("same"), encoding: .utf8) == "old")
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("new").path))
    #expect(FileManager().fileExists(atPath: untouched.path))
}

@Test func packageConflictsAreOpaqueAndCannotMerge() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("Thing.app")
    let target = fixture.destination.appendingPathComponent("Thing.app")
    for url in [source, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    let plan = try await fixture.service().prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    #expect(plan.conflicts.count == 1)
    #expect(plan.conflicts.first?.canMerge == false)
}

@Test func journalRejectsForeignSymlinkAndFIFOWithoutBlocking() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let service = fixture.service()
    _ = try await service.recoveryRecords()
    let foreign = fixture.journal.appendingPathComponent("foreign")
    try FileManager().createSymbolicLink(at: foreign, withDestinationURL: fixture.source)
    let fifo = fixture.journal.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let inspected = try await service.recoveryRecords()
    #expect(Set(inspected.refusedEntries.map(\.lastPathComponent)) == ["foreign", "fifo"])
}

@Test func corruptLatestJournalDoesNotFallBackToCommittedRevision() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let service = fixture.service()
    let owner: UUID
    do { owner = try OperationJournal(fixture.journal).owner }
    let id = UUID()
    var record = JournalRecord(version: 1, owner: owner, id: id, operation: "Copy")
    record.state = "committed"
    let anchor = try DirectoryAnchor(fixture.journal, resolve: false)
    try OperationJournal.writeExclusive(try JSONEncoder().encode(record), name: "\(id.uuidString)-000000.json", anchor: anchor)
    let latest = fixture.journal.appendingPathComponent("\(id.uuidString)-000001.json")
    try OperationJournal.writeExclusive(Data("broken".utf8), name: latest.lastPathComponent, anchor: anchor)
    let records = try await service.recoveryRecords()
    #expect(records.records.isEmpty)
    #expect(records.refusedEntries == [latest])
    #expect(await service.undo(recordID: id).result.disposition == .failed)
}

@Test func explicitRecoveryReconcilesUncommittedRenameAndRollsBack() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let target = fixture.destination.appendingPathComponent("one")
    var journal: OperationJournal? = try OperationJournal(fixture.journal)
    let from = try DirectoryAnchor(fixture.source)
    let to = try DirectoryAnchor(fixture.destination)
    let fingerprint = try verifiedTree(source, cancellation: OperationCancellation())
    var record = JournalRecord(version: 1, owner: journal!.owner, id: UUID(), operation: "Move")
    record.steps = [JournalStep(source: source, destination: target, sourceParent: from.identity, destinationParent: to.identity, before: fingerprint)]
    record.state = "mutating"; record.locations = [source, target]
    try journal!.saveSnapshot(&record)
    journal = nil
    try exclusiveRename(from: from.fd, name: "one", to: to.fd, name: "one")
    let service = fixture.service()
    #expect(try await service.recoveryRecords().records.first?.canRecover == true)
    #expect(await service.recover(recordID: record.id).result.disposition == .succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(!FileManager().fileExists(atPath: target.path))
}

@Test func recoveryRefusesAmbiguousOccupants() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let target = fixture.destination.appendingPathComponent("one")
    var journal: OperationJournal? = try OperationJournal(fixture.journal)
    let from = try DirectoryAnchor(fixture.source)
    let to = try DirectoryAnchor(fixture.destination)
    let fingerprint = try verifiedTree(source, cancellation: OperationCancellation())
    var record = JournalRecord(version: 1, owner: journal!.owner, id: UUID(), operation: "Move")
    record.steps = [JournalStep(source: source, destination: target, sourceParent: from.identity, destinationParent: to.identity, before: fingerprint)]
    record.state = "mutating"; record.locations = [source, target]
    try journal!.saveSnapshot(&record)
    journal = nil
    _ = try fixture.file("one", in: fixture.destination, text: "unrelated")
    #expect(await fixture.service().recover(recordID: record.id).result.disposition == .failed)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: target, encoding: .utf8) == "unrelated")
}

@Test func successfulFixtureTrashUndoRestoresExactItem() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let trash = fixture.root.appendingPathComponent("fixture-trash")
    try FileManager().createDirectory(at: trash, withIntermediateDirectories: false)
    let legacy = LocalFileOperations(trash: { source in
        let target = trash.appendingPathComponent(source.lastPathComponent)
        try FileManager().moveItem(at: source, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RECOVERY_CRASH_PHASE"] != nil,
               "Explicit subprocess crash qualification worker only."))
func recoveryCrashQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["MAC_EXPLORER_RECOVERY_CRASH_PHASE"])
    let path = try #require(environment["MAC_EXPLORER_RECOVERY_CRASH_ROOT"])
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = repository.appendingPathComponent(".build/test-fixtures")
    guard root.deletingLastPathComponent().path == base.path,
          root.lastPathComponent.hasPrefix("recovery-crash-"),
          UUID(uuidString: String(root.lastPathComponent.dropFirst("recovery-crash-".count))) != nil,
          base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
    let marker = root.appendingPathComponent(".mac-explorer-owned-recovery-crash-fixture")
    let markerData = Data("MacExplorer owned recovery crash fixture v1\n\(root.lastPathComponent)\n".utf8)
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    let item = source.appendingPathComponent("owned.txt")
    let target = destination.appendingPathComponent("owned.txt")
    if phase == "intent" || phase == "renamed" {
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        guard mkdir(root.path, 0o700) == 0 else { throw FileOperationFailure.conflict }
        try markerData.write(to: marker, options: .withoutOverwriting)
        for url in [source, destination] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("generated crash fixture".utf8).write(to: item, options: .withoutOverwriting)
    } else {
        _ = try DirectoryAnchor(root, resolve: false)
        var attributes = stat()
        guard lstat(marker.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_nlink == 1, attributes.st_uid == geteuid(), try Data(contentsOf: marker) == markerData else {
            throw FileOperationFailure.invalidRequest
        }
    }
    var hooks = RecoveryHooks()
    if phase == "intent" {
        hooks.afterIntent = {
            let summary: [String: String] = ["phase": phase, "pid": String(getpid()), "terminationCode": "86"]
            try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("termination-summary.json"), options: .withoutOverwriting)
            _exit(86)
        }
    }
    if phase == "renamed" {
        hooks.afterRename = {
            let summary: [String: String] = ["phase": phase, "pid": String(getpid()), "terminationCode": "86"]
            try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("termination-summary.json"), options: .withoutOverwriting)
            _exit(86)
        }
    }
    let service = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal"), hooks: hooks)
    if phase == "intent" || phase == "renamed" {
        _ = await service.perform(.move(sources: [item], destinationDirectory: destination))
        Issue.record("Crash worker unexpectedly returned before its requested termination boundary.")
    } else {
        let inspection = try await service.recoveryRecords()
        #expect(inspection.refusedEntries.isEmpty)
        let record = try #require(inspection.records.first)
        #expect(record.canRecover)
        if phase == "recover" {
            let outcome = await service.recover(recordID: record.id)
            #expect(outcome.result.disposition == .succeeded)
            #expect(try String(contentsOf: item, encoding: .utf8) == "generated crash fixture")
            #expect(!FileManager().fileExists(atPath: target.path))
        } else { #expect(phase == "inspect") }
        let summary: [String: String] = ["phase": phase, "pid": String(getpid()), "recordID": record.id.uuidString,
                                       "sourcePresent": String(FileManager().fileExists(atPath: item.path)),
                                       "destinationPresent": String(FileManager().fileExists(atPath: target.path))]
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]).write(to: root.appendingPathComponent("\(phase)-summary.json"), options: .withoutOverwriting)
    }
}

@Test func recoverableRenameRacePreservesSubstitutedOccupantAndReportsActualOriginal() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let held = fixture.source.appendingPathComponent("held-original")
    let service = fixture.service(RecoveryHooks(beforeRename: {
        try! FileManager().moveItem(at: source, to: held)
        try! Data("substituted".utf8).write(to: source, options: .withoutOverwriting)
    }))
    let result = await service.perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(result.result.items.map(\.status) == [.failed(.recoveryUncertain)])
    #expect(try String(contentsOf: held, encoding: .utf8) == "original")
    #expect(try String(contentsOf: fixture.destination.appendingPathComponent("one"), encoding: .utf8) == "substituted")
    let record = try #require(try await fixture.service().recoveryRecords().records.first)
    #expect(record.state == "needsReview")
    #expect(record.locations.contains(held))
    #expect(await fixture.service().recover(recordID: record.id).result.disposition == .failed)
}

@Test func undoRenameRacePreservesUnexpectedOccupantAndMarksUncertain() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let forward = await fixture.service().perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(forward.result.disposition == .succeeded)
    let target = fixture.destination.appendingPathComponent("one")
    let held = fixture.destination.appendingPathComponent("held-original")
    let undo = fixture.service(RecoveryHooks(beforeRename: {
        try! FileManager().moveItem(at: target, to: held)
        try! Data("substituted".utf8).write(to: target, options: .withoutOverwriting)
    }))
    let result = await undo.undo(recordID: try #require(forward.recordID))
    #expect(result.result.disposition == .failed)
    #expect(try String(contentsOf: source, encoding: .utf8) == "substituted")
    #expect(try String(contentsOf: held, encoding: .utf8) == "original")
    #expect(try await fixture.service().recoveryRecords().records.first?.locations.contains(held) == true)
}

@Test func conflictReplacementBetweenConsentAndCommitPreservesForeignDestination() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let target = try fixture.file("one", in: fixture.destination, text: "old")
    let held = fixture.destination.appendingPathComponent("held-old")
    let service = fixture.service(RecoveryHooks(beforeCommit: {
        try! FileManager().moveItem(at: target, to: held)
        try! Data("foreign".utf8).write(to: target, options: .withoutOverwriting)
    }))
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .replace])
    #expect(result.result.items.map(\.status) == [.failed(.destinationChanged)])
    #expect(try String(contentsOf: target, encoding: .utf8) == "foreign")
    #expect(try String(contentsOf: held, encoding: .utf8) == "old")
}

@Test func combinedCutAndDestinationObservationsRejectEitherReplacement() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let service = fixture.service()
    let cut = try await service.observeSelection([source])
    let target = try await service.observeDirectory(fixture.destination)
    let held = fixture.root.appendingPathComponent("held-destination")
    try FileManager().moveItem(at: fixture.destination, to: held)
    try FileManager().createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    let result = await service.perform(.moveObserved(selection: cut, destinationDirectory: fixture.destination), observing: target)
    #expect(result.result.items.map(\.status) == [.failed(.destinationChanged), .notStarted])
    #expect(FileManager().fileExists(atPath: source.path))
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func journalLatestSymlinkAndFIFOAreRefusedWithoutOpeningTargets() async throws {
    for fifo in [false, true] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let service = fixture.service()
        let owner: UUID
        do { owner = try OperationJournal(fixture.journal).owner }
        let id = UUID()
        let record = JournalRecord(version: 1, owner: owner, id: id, operation: "Copy")
        try OperationJournal.writeExclusive(try JSONEncoder().encode(record), name: "\(id.uuidString)-000000.json",
                                           anchor: DirectoryAnchor(fixture.journal, resolve: false))
        let latest = fixture.journal.appendingPathComponent("\(id.uuidString)-000001.json")
        if fifo { #expect(mkfifo(latest.path, 0o600) == 0) }
        else { try FileManager().createSymbolicLink(at: latest, withDestinationURL: fixture.source) }
        let inspection = try await service.recoveryRecords()
        #expect(inspection.records.isEmpty)
        #expect(inspection.refusedEntries == [latest])
    }
}

@Test func cancellationAfterDurableIntentPreservesSourceAndRecoversNoMutation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let service = fixture.service(RecoveryHooks(afterIntent: { entered.signal(); release.wait() }))
    let task = Task { await service.perform(.move(sources: [source], destinationDirectory: fixture.destination)) }
    #expect(await waitForRecoveryGate(entered))
    task.cancel(); release.signal()
    let result = await task.value
    #expect(result.result.cancellationRequested)
    #expect(result.result.items.map(\.status) == [.cancelled])
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(await fixture.service().recover(recordID: try #require(result.recordID)).result.disposition == .succeeded)
}

@Test func retainedOriginalEditBlocksReplaceUndoBeforeAnyMutation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one", text: "incoming")
    let destination = try fixture.file("one", in: fixture.destination, text: "old")
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    let replaced = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .replace])
    #expect(replaced.result.disposition == .succeeded)
    let inspection = try await service.recoveryRecords()
    let backup = try #require(inspection.records.first?.locations.first(where: { $0.lastPathComponent == "displaced" }))
    try Data("modified backup".utf8).write(to: backup)
    #expect(await service.undo(recordID: try #require(replaced.recordID)).result.disposition == .failed)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "incoming")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "modified backup")
}

private func waitForRecoveryGate(_ gate: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: gate.wait(timeout: .now() + 10) == .success) }
    }
}

@Test func movedMergedContainersRetireAndUndoRestoresTheirOriginalIdentity() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder")
    let target = fixture.destination.appendingPathComponent("folder")
    for url in [source, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    _ = try fixture.file("incoming", in: source)
    _ = try fixture.file("untouched", in: target)
    let identity = try DirectoryAnchor(source).identity
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .merge])
    #expect(result.result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(FileManager().fileExists(atPath: target.appendingPathComponent("incoming").path))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try DirectoryAnchor(source).identity.sameObject(as: identity))
    #expect(FileManager().fileExists(atPath: source.appendingPathComponent("incoming").path))
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("incoming").path))
    #expect(FileManager().fileExists(atPath: target.appendingPathComponent("untouched").path))
}

@Test func moveMergeWithSkippedChildRetainsSourceAndReportsPartial() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder")
    let target = fixture.destination.appendingPathComponent("folder")
    for url in [source, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    _ = try fixture.file("incoming", in: source)
    _ = try fixture.file("same", in: source)
    _ = try fixture.file("same", in: target, text: "old")
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
    let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.canMerge ? TransferConflictResolution.merge : .skip) })
    let result = await service.perform(plan, resolutions: choices)
    #expect(result.result.disposition == .partial)
    #expect(FileManager().fileExists(atPath: source.appendingPathComponent("same").path))
    #expect(!FileManager().fileExists(atPath: source.appendingPathComponent("incoming").path))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: source.appendingPathComponent("incoming").path))
}

@Test func emptyMoveMergeRetiresAndRestoresSourceContainer() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder")
    let target = fixture.destination.appendingPathComponent("folder")
    for url in [source, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .merge])
    #expect(result.result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: source.path))
}

@Test func corruptedStagedBytesNeverPublishEvenWhenLengthMatches() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one", text: "original")
    let service = fixture.service(RecoveryHooks(beforeCommit: {
        let areas = try! FileManager().contentsOfDirectory(at: fixture.destination, includingPropertiesForKeys: nil)
        let area = areas.first { $0.lastPathComponent.hasPrefix(".mac-explorer-recovery-") }!
        try! Data("tampered".utf8).write(to: area.appendingPathComponent("payload"))
    }))
    let result = await service.perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    #expect(result.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("one").path))
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
}

@Test func hardLinkTreeTopologyIsNotSilentlyFlattenedByCopy() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let folder = fixture.source.appendingPathComponent("folder")
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
    let file = try fixture.file("one", in: folder)
    try FileManager().linkItem(at: file, to: folder.appendingPathComponent("two"))
    let result = await fixture.service().perform(.copy(sources: [folder], destinationDirectory: fixture.destination))
    #expect(result.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("folder").path))
    #expect(try String(contentsOf: file, encoding: .utf8) == "original")
}

@Test func failedTrashWithKnownDestinationPersistsReviewLocation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let target = fixture.destination.appendingPathComponent("one")
    let legacy = LocalFileOperations(trash: { url in
        try FileManager().moveItem(at: url, to: target)
        try Data("modified after Trash".utf8).write(to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .partial)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
    let record = try #require(try await cold.inspectExistingHistory().records.first)
    #expect(record.state == "needsReview")
    #expect(record.locations.contains(target))
    #expect(record.requiresManualTrashReview)
    #expect(!record.canUndo && !record.canRecover)
    #expect(try await cold.retentionRecord(recordID: record.id).canCleanup == false)
    #expect(await cold.recover(recordID: record.id).result.disposition == .failed)
    #expect(try String(contentsOf: target, encoding: .utf8) == "modified after Trash")
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(try await cold.inspectExistingHistory().records.first?.state == "needsReview")
}

@Test func failedTrashIntentWithIntactOriginalRemainsManualReview() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("one")
    let before = try verifiedTree(source, cancellation: OperationCancellation())
    let legacy = LocalFileOperations(trash: { _ in throw FileOperationFailure.ioFailure })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    _ = await service.perform(.trash(sources: [source]))
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
    let record = try #require(try await cold.inspectExistingHistory().records.first)
    #expect(record.state == "needsReview")
    #expect(record.requiresManualTrashReview)
    #expect(!record.canUndo && !record.canRecover)
    #expect(try await cold.retentionRecord(recordID: record.id).canCleanup == false)
    #expect(await cold.undo(recordID: record.id).result.disposition == .failed)
    #expect(await cold.recover(recordID: record.id).result.disposition == .failed)
    #expect(before.matches(try verifiedTree(source, cancellation: OperationCancellation())))
    #expect(try await cold.inspectExistingHistory().records.first?.state == "needsReview")
}

@Test func mergeCopiesRefuseToFlattenHardlinkedSiblings() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder")
    let target = fixture.destination.appendingPathComponent("folder")
    for url in [source, target] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    let file = try fixture.file("one", in: source)
    try FileManager().linkItem(at: file, to: source.appendingPathComponent("two"))
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .merge])
    #expect(result.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("one").path))
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("two").path))
}

@Test func unknownSecondTrashOutcomeCannotReportWholeJobRecovered() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let one = try fixture.file("one")
    let two = try fixture.file("two")
    let legacy = LocalFileOperations(trash: { source in
        let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
        try FileManager().moveItem(at: source, to: target)
        if source.lastPathComponent == "two" { throw FileOperationFailure.ioFailure }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [one, two]))
    #expect(result.result.disposition == .partial)
    let record = try #require(try await service.recoveryRecords().records.first)
    #expect(record.state == "needsReview")
    #expect(record.requiresManualTrashReview)
    #expect(!record.canRecover)
    #expect(await service.recover(recordID: record.id).result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("one").path))
    #expect(FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("two").path))
}

@Test func nativeTrashAccessMetadataTransitionRetainsFullUndoGuard() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-access-metadata")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let before = try verifiedTree(source, cancellation: OperationCancellation())
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        // Generated bytes on a disposable owned fixture, never a real access token.
        let attribute = Data(repeating: 0, count: 72)
        guard attribute.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw FileOperationFailure.ioFailure
        }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesOnly)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let after = try verifiedTree(target, cancellation: OperationCancellation())
    #expect(before.digest != after.digest)
    #expect(before.matchesNativeTrashTransition(after))
    let committed = try #require(try await RecoverableFileOperations(journalDirectory: fixture.journal)
        .inspectExistingHistory().records.first)
    #expect(committed.state == "committed" && committed.canUndo)
    #expect(!committed.nativeTrashMarkChanged)
    #expect(committed.nativeRegularFileTrashContract)
    #expect(!committed.requiresManualTrashReview)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal, nativeTrashPolicy: .regularFilesOnly)
    #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    let restored = try verifiedTree(source, cancellation: OperationCancellation())
    #expect(after.matches(restored))
}

@Test func nativeTrashExistingQuarantineTransitionCommitsAndColdUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("marked.zip")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    try Data(repeating: 0x5A, count: 169).write(to: source, options: .withoutOverwriting)
    let originalMark = Data("0083;67000000;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let returnedMark = Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let accessMark = Data(repeating: 0x5A, count: 72)
    try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    let beforeFamilies = NativeTrashFamilyCollector()
    let before = try verifiedTree(source, cancellation: OperationCancellation(),
                                  nativeTrashFamilyCollector: beforeFamilies)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager().moveItem(at: supplied, to: target)
        try setGeneratedTrashAttribute(returnedMark, name: CopySecurity.quarantineName, at: target)
        try setGeneratedTrashAttribute(accessMark, name: "com.apple.macl", at: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesOnly)
    let result = await service.perform(.trash(sources: [source]))
    let afterFamilies = NativeTrashFamilyCollector()
    let after = try verifiedTree(target, cancellation: OperationCancellation(),
                                 nativeTrashFamilyCollector: afterFamilies)
    let observedBefore = try #require(beforeFamilies.snapshot())
    let observedAfter = try #require(afterFamilies.snapshot())
    #expect(before.identity.sameObject(as: after.identity))
    #expect(!before.matchesNativeTrashTransition(after))
    #expect(observedBefore.finding(comparedWith: observedAfter, before: before, returned: after)
            == .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: true))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let committed = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(committed.version == 11)
    #expect(committed.steps.first?.nativeTrashMarkChanged == true)
    #expect(committed.state == "committed")
    #expect(committed.steps.count == 1)
    #expect(committed.steps.first?.after == after)
    let summary = try #require(try await service.inspectExistingHistory().records.first)
    #expect(summary.nativeRegularFileTrashContract && summary.nativeTrashMarkChanged)
    let listed = try #require(try await service.inspectOwnedTrash().groups.first { $0.id == id })
    #expect(listed.entries.count == 1 && listed.canRestoreWholeGroup && !listed.canDeleteWholeGroup)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal, nativeTrashPolicy: .regularFilesOnly)
    #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
    let restored = try verifiedTree(source, cancellation: OperationCancellation())
    #expect(after.matches(restored))
    #expect(!FileManager().fileExists(atPath: target.path))
    #expect(try await cold.recoveryRecords().records.first?.state == "undone")
}

@Test func nativeDirectoryV12MixedJobKeepsOneRecordAndColdUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let file = try fixture.file("plain.txt", text: "generated mixed file")
    let folder = fixture.source.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let child = try fixture.file("child.txt", in: folder, text: "generated mixed child")
    let beforeFile = try verifiedTree(file, cancellation: OperationCancellation())
    let beforeFolder = try verifiedTree(folder, cancellation: OperationCancellation())
    let destination = fixture.destination
    let legacy = LocalFileOperations(trash: { source in
        let returned = destination.appendingPathComponent(source.lastPathComponent,
            isDirectory: source.hasDirectoryPath)
        try FileManager.default.moveItem(at: source, to: returned)
        return returned
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesAndDirectories)
    let moved = await service.perform(.trash(sources: [file, folder]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(record.version == 12 && record.steps.count == 2 && record.trashIntents.count == 2)
    #expect(record.steps.first(where: { $0.source == file })?.nativeTrashMarkChanged == false)
    #expect(record.steps.first(where: { $0.source == folder })?.nativeTrashRootAddition == nil)
    #expect(record.steps.first(where: { $0.source == folder })?.nativeTrashDirectoryDescendantIdentity?.count == 32)
    let summary = try #require(try await service.inspectExistingHistory().records.first)
    #expect(summary.nativeDirectoryTrashContract && !summary.nativeRegularFileTrashContract && summary.canUndo)
    let listed = try #require(try await service.inspectOwnedTrash().groups.first { $0.id == id })
    #expect(listed.entries.count == 2 && listed.canRestoreWholeGroup && !listed.canDeleteWholeGroup)
    let narrow = RecoverableFileOperations(journalDirectory: fixture.journal, nativeTrashPolicy: .regularFilesOnly)
    #expect((await narrow.undo(recordID: id)).result.disposition != .succeeded)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal,
                                         nativeTrashPolicy: .regularFilesAndDirectories)
    #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
    #expect(beforeFile.matches(try verifiedTree(file, cancellation: OperationCancellation())))
    #expect(beforeFolder.matches(try verifiedTree(folder, cancellation: OperationCancellation())))
    #expect(try Data(contentsOf: child) == Data("generated mixed child".utf8))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder").path))
}

@Test func nativeDirectoryV12MarkedRootWitnessIsVersionFencedAndColdUndoBounded() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("marked-folder", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("marked-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("child.txt", in: source, text: "generated marked child")
    let originalMark = Data("0086;67000001;GeneratedBefore;".utf8)
    let returnedMark = Data("0082;67000002;GeneratedAfter;".utf8)
    let restoredMark = Data("0082;67000003;GeneratedRestored;".utf8)
    try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    var forwardHooks = RecoveryHooks()
    forwardHooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: returnedMark, osAccess: Data(repeating: 0x5A, count: 72))
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: forwardHooks,
                                            legacy: legacy, nativeTrashPolicy: .regularFilesAndDirectories)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    let step = try #require(record.steps.first)
    let after = try #require(step.after)
    let proof = try #require(step.nativeTrashRootAddition)
    #expect(record.version == 12 && proof.validates(before: step.before, after: after))
    #expect(!proof.validatesAdditiveRoot(before: step.before, after: after))
    #expect(step.nativeTrashDirectoryDescendantIdentity == proof.afterDescendantIdentity)
    var missing = record
    missing.steps[0].nativeTrashRootAddition = nil
    do { try OperationJournal.validate(missing); Issue.record("v12 changed-root step must keep its witness") }
    catch { }
    var missingIdentity = record
    missingIdentity.steps[0].nativeTrashDirectoryDescendantIdentity = nil
    do { try OperationJournal.validate(missingIdentity); Issue.record("v12 directory step must bind descendant identity") }
    catch { }
    var mislabeled = record
    mislabeled.version = 9
    do { try OperationJournal.validate(mislabeled); Issue.record("v9 cannot adopt a v12 root rewrite") }
    catch { }
    var coldHooks = forwardHooks
    coldHooks.nativeTrashInverseRestoredSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
        quarantine: restoredMark, osAccess: Data(repeating: 0xA5, count: 72))
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: coldHooks,
                                         nativeTrashPolicy: .regularFilesAndDirectories)
    #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
    let undone = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(undone.state == "undone" && undone.steps.first?.undone == true)
    let restored = try verifiedTree(source, cancellation: OperationCancellation(),
                                    nativeTrashSyntheticRootMetadata: coldHooks.nativeTrashInverseRestoredSyntheticRootMetadata)
    #expect(undone.steps.first?.after == restored)
    #expect(after.identity.sameObject(as: restored.identity))
    #expect(try Data(contentsOf: source.appendingPathComponent("child.txt")) == Data("generated marked child".utf8))
}

@Test(arguments: [true, false])
func nativeDirectoryV12ColdRetrashAcceptsOnlyRootQuarantineRewrite(_ priorMarkPresent: Bool) async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("marked-folder", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("marked-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let child = try fixture.file("child.txt", in: source, text: "stable generated child")
    let originalMark = Data("0086;67000001;GeneratedBefore;".utf8)
    let firstMark = Data("0082;67000002;GeneratedFirst;".utf8)
    let secondMark = Data("0082;67000003;GeneratedSecond;".utf8)
    let access = Data(repeating: 0x5A, count: 72)
    if priorMarkPresent {
        try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    }
    try setGeneratedTrashAttribute(access, name: "com.apple.macl", at: source)
    func legacy(rewriting mark: Data) -> LocalFileOperations {
        LocalFileOperations(trash: { supplied in
            try FileManager.default.moveItem(at: supplied, to: target)
            try setGeneratedTrashAttribute(mark, name: CopySecurity.quarantineName, at: target)
            return target
        })
    }
    let first = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(),
                                          legacy: legacy(rewriting: firstMark),
                                          nativeTrashPolicy: .regularFilesAndDirectories)
    let moved = await first.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let firstID = try #require(moved.recordID)
    let firstStep = try #require(try OperationJournal(fixture.journal).inspectRecord(firstID)?.steps.first)
    let firstProof = try #require(firstStep.nativeTrashRootAddition)
    #expect((firstProof.beforeRootQuarantine != nil) == priorMarkPresent)
    #expect(firstProof.beforeOSAccess == firstProof.afterOSAccess)
    #expect(!firstProof.validates(before: firstStep.before, after: try #require(firstStep.after)))
    #expect(firstProof.validatesNativeDirectoryV12(before: firstStep.before,
        after: try #require(firstStep.after)))
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal,
                                         nativeTrashPolicy: .regularFilesAndDirectories)
    #expect(await cold.undo(recordID: firstID).result.disposition == .succeeded)
    #expect(try Data(contentsOf: child) == Data("stable generated child".utf8))
    let second = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(),
                                           legacy: legacy(rewriting: secondMark),
                                           nativeTrashPolicy: .regularFilesAndDirectories)
    let retrash = await second.perform(.trash(sources: [source]))
    #expect(retrash.result.disposition == .succeeded)
    let secondID = try #require(retrash.recordID)
    let secondStep = try #require(try OperationJournal(fixture.journal).inspectRecord(secondID)?.steps.first)
    let secondProof = try #require(secondStep.nativeTrashRootAddition)
    #expect(secondProof.beforeOSAccess == secondProof.afterOSAccess)
    #expect(secondProof.beforeRootQuarantine != nil)
    #expect(secondProof.validatesNativeDirectoryV12(before: secondStep.before,
        after: try #require(secondStep.after)))
    var older = try #require(try OperationJournal(fixture.journal).inspectRecord(secondID))
    older.version = 9
    do { try OperationJournal.validate(older); Issue.record("v9 cannot use a v12 quarantine-only root proof") }
    catch { }
}

@Test func nativeDirectoryV12ForwardRejectsSameByteChildReplacement() async throws {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    for phase in ["precall", "native-call", "post-sync"] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("folder", isDirectory: true)
        let target = fixture.destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let child = try fixture.file("child.txt", in: source, text: "same generated bytes")
        let calls = Calls()
        var hooks = RecoveryHooks()
        if phase == "precall" {
            hooks.nativeTrashBeforeSourceRecheck = {
                let bytes = try Data(contentsOf: child)
                try FileManager.default.removeItem(at: child)
                try bytes.write(to: child, options: .withoutOverwriting)
            }
        } else if phase == "post-sync" {
            hooks.beforeSync = { _ in
                let movedChild = target.appendingPathComponent("child.txt")
                let bytes = try Data(contentsOf: movedChild)
                try FileManager.default.removeItem(at: movedChild)
                try bytes.write(to: movedChild, options: .withoutOverwriting)
            }
        }
        let legacy = LocalFileOperations(trash: { supplied in
            calls.increment()
            try FileManager.default.moveItem(at: supplied, to: target)
            if phase == "native-call" {
                let movedChild = target.appendingPathComponent("child.txt")
                let bytes = try Data(contentsOf: movedChild)
                try FileManager.default.removeItem(at: movedChild)
                try bytes.write(to: movedChild, options: .withoutOverwriting)
            }
            return target
        })
        let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy,
                                                nativeTrashPolicy: .regularFilesAndDirectories)
        let result = await service.perform(.trash(sources: [source]))
        #expect(result.result.disposition != .succeeded, "\(phase)")
        #expect(calls.value == (phase == "precall" ? 0 : 1), "\(phase)")
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview" && record.steps.isEmpty, "\(phase)")
        #expect(try Data(contentsOf: phase == "precall" ? child : target.appendingPathComponent("child.txt"))
                == Data("same generated bytes".utf8), "\(phase)")
    }
}

@Test func nativeDirectoryV12ColdUndoRejectsSameByteReplacedDescendant() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("child.txt", in: source, text: "same generated bytes")
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let forward = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesAndDirectories)
    let moved = await forward.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let child = target.appendingPathComponent("child.txt")
    let bytes = try Data(contentsOf: child)
    try FileManager.default.removeItem(at: child)
    try bytes.write(to: child, options: .withoutOverwriting)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal,
                                         nativeTrashPolicy: .regularFilesAndDirectories)
    #expect((await cold.undo(recordID: id)).result.disposition != .succeeded)
    #expect(try OperationJournal(fixture.journal).inspectRecord(id)?.state == "needsReview")
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func nativeDirectoryV12InverseRejectsSameByteChildReplacementAfterRenameAndSync() async throws {
    for phase in ["after-rename", "before-sync"] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("folder", isDirectory: true)
        let target = fixture.destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try fixture.file("child.txt", in: source, text: "same generated bytes")
        let legacy = LocalFileOperations(trash: { supplied in
            try FileManager.default.moveItem(at: supplied, to: target)
            return target
        })
        let forward = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                                nativeTrashPolicy: .regularFilesAndDirectories)
        let moved = await forward.perform(.trash(sources: [source]))
        #expect(moved.result.disposition == .succeeded)
        let id = try #require(moved.recordID)
        var inverseHooks = RecoveryHooks()
        if phase == "after-rename" {
            inverseHooks.afterRename = {
                let child = source.appendingPathComponent("child.txt")
                let bytes = try! Data(contentsOf: child)
                try! FileManager.default.removeItem(at: child)
                try! bytes.write(to: child, options: .withoutOverwriting)
            }
        } else {
            inverseHooks.beforeSync = { _ in
                let child = source.appendingPathComponent("child.txt")
                let bytes = try Data(contentsOf: child)
                try FileManager.default.removeItem(at: child)
                try bytes.write(to: child, options: .withoutOverwriting)
            }
        }
        let cold = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: inverseHooks,
                                             nativeTrashPolicy: .regularFilesAndDirectories)
        #expect((await cold.undo(recordID: id)).result.disposition != .succeeded, "\(phase)")
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview" && record.steps.first?.undone == false, "\(phase)")
        #expect(try Data(contentsOf: source.appendingPathComponent("child.txt"))
                == Data("same generated bytes".utf8), "\(phase)")
        #expect(!FileManager.default.fileExists(atPath: target.path), "\(phase)")
    }
}

@Test func nativeDirectoryV12ColdUndoPreservesOriginalSlotCollision() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder", isDirectory: true)
    let target = fixture.destination.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("child.txt", in: source, text: "original generated child")
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let forward = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesAndDirectories)
    let moved = await forward.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("other.txt", in: source, text: "unrelated generated child")
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal,
                                         nativeTrashPolicy: .regularFilesAndDirectories)
    #expect((await cold.undo(recordID: id)).result.disposition != .succeeded)
    #expect(try Data(contentsOf: source.appendingPathComponent("other.txt"))
            == Data("unrelated generated child".utf8))
    #expect(try Data(contentsOf: target.appendingPathComponent("child.txt"))
            == Data("original generated child".utf8))
}

@Test func nativeDirectoryV12UncertainIntentStaysReviewOnly() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    _ = try fixture.file("child.txt", in: source, text: "generated child")
    let legacy = LocalFileOperations(trash: { _ in throw FileOperationFailure.ioFailure })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesAndDirectories)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition != .succeeded)
    let id = try #require(result.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(record.version == 12 && record.state == "needsReview")
    #expect(record.trashIntents.count == 1 && record.steps.isEmpty)
    let summary = try #require(try await service.inspectExistingHistory().records.first)
    #expect(summary.nativeDirectoryTrashContract && !summary.canRecover && !summary.canUndo)
    #expect(try await service.inspectOwnedTrash().groups.isEmpty)
    #expect((await service.recover(recordID: id)).result.disposition != .succeeded)
    #expect(try Data(contentsOf: source.appendingPathComponent("child.txt")) == Data("generated child".utf8))
}

#if DEBUG
@Test func olderTrashRecordCannotBorrowV11RootMarkRewrite() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("Legacy.txt", text: "Generated older contract bytes")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let originalMark = Data("0082;67000001;GeneratedLegacy;".utf8)
    let inverseMark = Data("0082;67000002;GeneratedInverse;".utf8)
    try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    var forwardHooks = RecoveryHooks()
    forwardHooks.nativeTrashQualificationMode = .strict
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        return target
    })
    let forward = RecoverableFileOperations(journalDirectory: fixture.journal,
        hooks: forwardHooks, legacy: legacy)
    let moved = await forward.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let id = try #require(moved.recordID)
    let before = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(before.version == 3 && before.steps.first?.nativeTrashMarkChanged == nil)
    var inverseHooks = RecoveryHooks()
    inverseHooks.afterRename = {
        try! setGeneratedTrashAttribute(inverseMark, name: CopySecurity.quarantineName, at: source)
    }
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: inverseHooks)
    let undo = await cold.undo(recordID: id)
    #expect(undo.result.disposition != .succeeded)
    #expect(try OperationJournal(fixture.journal).inspectRecord(id)?.state == "needsReview")
    #expect(try Data(contentsOf: source) == Data("Generated older contract bytes".utf8))
}
#endif

@Test(arguments: ["quarantine-only", "other-xattr", "os-access", "content", "removed-quarantine", "empty-quarantine"])
func ordinaryColdTrashUndoRequiresOnlyNonemptyRootQuarantineRewrite(_ variant: String) async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("Generated.txt", text: "Generated ordinary cold Undo bytes.\n")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let quarantineAfterTrash = Data("0083;67000001;GeneratedTrash;".utf8)
    let quarantineAfterInverse = Data("0083;67000002;GeneratedUndo;".utf8)
    let access = Data(repeating: 0x5A, count: 72)
    let original = try verifiedTree(source, cancellation: .init())
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        try setGeneratedTrashAttribute(quarantineAfterTrash, name: CopySecurity.quarantineName, at: target)
        try setGeneratedTrashAttribute(access, name: "com.apple.macl", at: target)
        return target
    })
    let forward = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            hooks: RecoveryHooks(), legacy: legacy)
    let trashed = await forward.perform(.trash(sources: [source]))
    #expect(trashed.result.disposition == .succeeded)
    let id = try #require(trashed.recordID)
    #expect(try OperationJournal(fixture.journal).inspectRecord(id)?.version == 11)
    #expect(try OperationJournal(fixture.journal).inspectRecord(id)?.steps.first?.nativeTrashMarkChanged == true)
    let trashFamilies = NativeTrashFamilyCollector()
    let trashProjection = NativeRenameSecurityProjection()
    let trashParent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
    let after = try verifiedTree(parent: trashParent.fd, name: target.lastPathComponent,
        cancellation: .init(), nativeRename: trashProjection, nativeTrashFamilyCollector: trashFamilies)
    #expect(original.identity.sameObject(as: after.identity))
    var hooks = RecoveryHooks()
    hooks.afterRename = {
        if variant == "removed-quarantine" {
            precondition(removexattr(source.path, CopySecurity.quarantineName, XATTR_NOFOLLOW) == 0)
        } else {
            try! setGeneratedTrashAttribute(variant == "empty-quarantine" ? Data() : quarantineAfterInverse,
                                             name: CopySecurity.quarantineName, at: source)
        }
        if variant == "other-xattr" {
            try! setGeneratedTrashAttribute(Data("generated unrelated metadata".utf8),
                                             name: "com.traverse.generated-other", at: source)
        } else if variant == "os-access" {
            try! setGeneratedTrashAttribute(Data(repeating: 0x6B, count: 72),
                                             name: "com.apple.macl", at: source)
        } else if variant == "content" {
            let fd = open(source.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            precondition(fd >= 0)
            let byte = Data([0x58])
            precondition(byte.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == 1)
            close(fd)
        }
    }
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    let undo = await cold.undo(recordID: id)
    let restoredFamilies = NativeTrashFamilyCollector()
    let restoredProjection = NativeRenameSecurityProjection()
    let restoredParent = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
    let restored = try verifiedTree(parent: restoredParent.fd, name: source.lastPathComponent,
        cancellation: .init(), nativeRename: restoredProjection, nativeTrashFamilyCollector: restoredFamilies)
    #expect(original.identity.sameObject(as: restored.identity))
    #expect(after.digest != restored.digest)
    let beforeFamily = try #require(trashFamilies.snapshot())
    let afterFamily = try #require(restoredFamilies.snapshot())
    let persisted = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    if variant == "quarantine-only" {
        #expect(beforeFamily.finding(comparedWith: afterFamily, before: after, returned: restored)
                == .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: false))
        #expect(!trashProjection.permitsNativeTransition(to: restoredProjection,
            before: after, after: restored, origin: nil))
        #expect(undo.result.disposition == .succeeded)
        #expect(persisted.state == "undone")
    } else {
        #expect(undo.result.items.contains { $0.status == .failed(.recoveryUncertain) })
        #expect(persisted.state == "needsReview")
    }
}

@Test(arguments: [true, false])
func nativeTrashV11ExistingAccessAcceptsQuarantineOnlyRewriteAndColdUndo(_ priorMarkPresent: Bool) async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("marked.zip", text: String(repeating: "Z", count: 169))
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let originalMark = Data("0083;67000000;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let returnedMark = Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let access = Data(repeating: 0x5A, count: 72)
    if priorMarkPresent {
        try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    }
    try setGeneratedTrashAttribute(access, name: "com.apple.macl", at: source)
    let beforeCollector = NativeTrashFamilyCollector()
    let before = try verifiedTree(source, cancellation: OperationCancellation(),
                                  nativeTrashFamilyCollector: beforeCollector)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager.default.moveItem(at: supplied, to: target)
        try setGeneratedTrashAttribute(returnedMark, name: CopySecurity.quarantineName, at: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            hooks: RecoveryHooks(), legacy: legacy,
                                            nativeTrashPolicy: .regularFilesOnly)
    let moved = await service.perform(.trash(sources: [source]))
    #expect(moved.result.disposition == .succeeded)
    let afterCollector = NativeTrashFamilyCollector()
    let after = try verifiedTree(target, cancellation: OperationCancellation(),
                                 nativeTrashFamilyCollector: afterCollector)
    let observedBefore = try #require(beforeCollector.snapshot())
    let observedAfter = try #require(afterCollector.snapshot())
    #expect(observedBefore.finding(comparedWith: observedAfter, before: before, returned: after)
        == .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: false))
    let id = try #require(moved.recordID)
    let committed = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(committed.version == 11 && committed.state == "committed")
    #expect(committed.steps.first?.nativeTrashMarkChanged == true)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal,
                                         nativeTrashPolicy: .regularFilesOnly)
    #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data(String(repeating: "Z", count: 169).utf8))
}

@Test(arguments: ["other-xattr", "body-change"])
func nativeTrashExistingQuarantineTransitionRefusesUnrelatedChanges(_ variant: String) async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("marked.zip", text: String(repeating: "Z", count: 169))
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let originalMark = Data("0083;67000000;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let returnedMark = Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager().moveItem(at: supplied, to: target)
        try setGeneratedTrashAttribute(returnedMark, name: CopySecurity.quarantineName, at: target)
        try setGeneratedTrashAttribute(Data(repeating: 0x5A, count: 72), name: "com.apple.macl", at: target)
        if variant == "other-xattr" {
            try setGeneratedTrashAttribute(Data("generated other".utf8),
                                           name: "com.traverse.generated-other", at: target)
        }
        if variant == "body-change" {
            let fd = open(target.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FileOperationFailure.ioFailure }
            defer { close(fd) }
            let update = Data([0x58])
            guard update.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == 1 else {
                throw FileOperationFailure.ioFailure
            }
        }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .partial)
    let id = try #require(result.recordID)
    let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    #expect(record.state == "needsReview")
    #expect(record.trashIntents.count == 1 && record.steps.isEmpty)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(FileManager().fileExists(atPath: target.path))
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
    #expect(try await cold.recoveryRecords().records.first?.canUndo == false)
}

@Test func nativeTrashExistingQuarantineTransitionColdUndoRefusesLateEdit() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("marked.zip", text: String(repeating: "Z", count: 169))
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let originalMark = Data("0083;67000000;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    let returnedMark = Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    try setGeneratedTrashAttribute(originalMark, name: CopySecurity.quarantineName, at: source)
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager().moveItem(at: supplied, to: target)
        try setGeneratedTrashAttribute(returnedMark, name: CopySecurity.quarantineName, at: target)
        try setGeneratedTrashAttribute(Data(repeating: 0x5A, count: 72), name: "com.apple.macl", at: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal,
                                            hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let laterMark = Data("0083;67000002;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8)
    try setGeneratedTrashAttribute(laterMark, name: CopySecurity.quarantineName, at: target)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
    #expect(await cold.undo(recordID: id).result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(FileManager().fileExists(atPath: target.path))
}

#if DEBUG
@Test func nativeTrashObservedProvenancePairUsesOrdinaryDefaultAndFullUndoGuard() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-provenance-pair", text: String(repeating: "Z", count: 169))
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let pair = try NativeTrashSyntheticRootMetadata(
        provenance: Data("generated provenance".utf8), osAccess: Data(repeating: 0x5A, count: 72))
    var hooks = RecoveryHooks()
    hooks.nativeTrashSyntheticRootMetadata = pair
    let legacy = LocalFileOperations(trash: { supplied in
        try FileManager().moveItem(at: supplied, to: target)
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let committed = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
    let virtualAfter = try verifiedTree(target, cancellation: OperationCancellation(),
                                        nativeTrashSyntheticRootMetadata: pair)
    #expect(committed.state == "committed")
    #expect(committed.steps.first?.after == virtualAfter)
    let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
    #expect(await cold.undo(recordID: id).result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: target.path))
    #expect(!FileManager().fileExists(atPath: source.path))
}
#endif

@Test func nativeTrashStillRejectsUnrelatedMetadataChanges() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("unrelated-metadata")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        let attribute = Data("changed user metadata".utf8)
        guard attribute.withUnsafeBytes({ setxattr(target.path, "com.macexplorer.unrelated-fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw FileOperationFailure.ioFailure
        }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .partial)
    let record = try #require(try await service.recoveryRecords().records.first)
    #expect(record.state == "needsReview")
    #expect(!record.canUndo)
    #expect(record.locations.contains(target))
}

@Test func nativeTrashLaterAccessMetadataEditBlocksUndo() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-access-edit")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        let attribute = Data(repeating: 0, count: 72)
        guard attribute.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else { throw FileOperationFailure.ioFailure }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let changed = Data(repeating: 1, count: 72)
    #expect(changed.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0)
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(FileManager().fileExists(atPath: target.path))
}

@Test func nativeTrashInterruptedUndoReconcilesFullPostTrashMetadata() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-access-recover")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        let attribute = Data(repeating: 0, count: 72)
        guard attribute.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else { throw FileOperationFailure.ioFailure }
        return target
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    do {
        let journal = try OperationJournal(fixture.journal)
        var record = try #require(try journal.inspect().records.first(where: { $0.id == id }))
        record.state = "undoing"; try journal.saveSnapshot(&record)
        let from = try DirectoryAnchor(fixture.destination)
        let to = try DirectoryAnchor(fixture.source)
        try exclusiveRename(from: from.fd, name: target.lastPathComponent, to: to.fd, name: source.lastPathComponent)
    }
    #expect(await service.recover(recordID: id).result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: source.path))
    #expect(!FileManager().fileExists(atPath: target.path))
}

private final class NativeTrashObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Test func nativeTrashRetriesOnlyUnstableAccessMetadataObservation() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-observation-race")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let counter = NativeTrashObservationCounter()
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        return target
    })
    let hooks = RecoveryHooks(duringNativeTrashVerification: {
        if counter.next() == 1 {
            let attribute = Data(repeating: 0, count: 72)
            precondition(attribute.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0)
        }
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .succeeded)
    #expect(counter.count == 2)
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
}

@Test func nativeTrashObservationRetryDoesNotAcceptBodyChangeOrSubstitution() async throws {
    for substitution in [false, true] {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let source = try fixture.file("native-body-race")
        let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
        let held = fixture.destination.appendingPathComponent("held-native-original")
        let counter = NativeTrashObservationCounter()
        let legacy = LocalFileOperations(trash: { source in
            try FileManager().moveItem(at: source, to: target)
            return target
        })
        let hooks = RecoveryHooks(duringNativeTrashVerification: {
            if counter.next() == 1 {
                if substitution { try! FileManager().moveItem(at: target, to: held) }
                try! Data("modified during observation".utf8).write(to: target)
            }
        })
        let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy)
        let result = await service.perform(.trash(sources: [source]))
        #expect(result.result.disposition == .partial)
        let record = try #require(try await service.recoveryRecords().records.first)
        #expect(record.state == "needsReview")
        #expect(!record.canUndo)
        #expect(try String(contentsOf: target, encoding: .utf8) == "modified during observation")
        if substitution { #expect(try String(contentsOf: held, encoding: .utf8) == "original") }
    }
}

@Test func nativeTrashUnstableObservationStopsAfterThreeAttempts() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("native-bounded-retry")
    let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
    let counter = NativeTrashObservationCounter()
    let legacy = LocalFileOperations(trash: { source in
        try FileManager().moveItem(at: source, to: target)
        return target
    })
    let hooks = RecoveryHooks(duringNativeTrashVerification: {
        let attribute = Data(repeating: UInt8(counter.next()), count: 72)
        precondition(attribute.withUnsafeBytes({ setxattr(target.path, "com.apple.macl", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0)
    })
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks, legacy: legacy)
    let result = await service.perform(.trash(sources: [source]))
    #expect(result.result.disposition == .partial)
    #expect(counter.count == 3)
    #expect(result.result.items.last?.status == .failed(.sourceChanged))
    #expect(FileManager().fileExists(atPath: target.path))
}

@Test func recoverableCreateAndUndoSyncSearchOnlyDirectoryWithoutListingAccess() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let searchOnly = fixture.destination
    #expect(chmod(searchOnly.path, 0o300) == 0)
    defer { _ = chmod(searchOnly.path, 0o700) }
    let anchor = try DirectoryAnchor(searchOnly)
    let listing = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if listing >= 0 { close(listing) }
    #expect(listing == -1)
    #expect(errno == EACCES)
    try syncDirectory(anchor)
    let service = fixture.service()
    let result = await service.perform(.createFolder(parent: searchOnly, name: "known-created-child"))
    #expect(result.result.disposition == .succeeded)
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
}

@Test func explicitAllSkipCompletesWithoutMutationOrOperationJournal() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = try fixture.file("same", text: "incoming")
    let destination = try fixture.file("same", in: fixture.destination, text: "existing")
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .skip])
    #expect(result.result.disposition == .succeeded)
    #expect(result.result.items.count == 1)
    #expect(result.result.items.first?.status == .skipped)
    #expect(result.result.items.first?.source == source)
    #expect(result.result.items.first?.destination == destination)
    #expect(result.recordID == nil)
    #expect(!result.result.cancellationRequested)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    #expect(try String(contentsOf: source, encoding: .utf8) == "incoming")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "existing")
    #expect(try await service.recoveryRecords().records.isEmpty)
}

@Test func mixedMoveAndSkipReportsBothAndJournalsOnlyMovedObject() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let skipped = try fixture.file("same", text: "skipped source")
    let existing = try fixture.file("same", in: fixture.destination, text: "existing destination")
    let moved = try fixture.file("moving", text: "moving source")
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [skipped, moved], destinationDirectory: fixture.destination, move: true)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .skip])
    #expect(result.result.disposition == .succeeded)
    #expect(result.result.items.count == 2)
    #expect(result.result.items.first(where: { $0.source == skipped })?.status == .skipped)
    #expect(result.result.items.first(where: { $0.source == moved })?.status == .succeeded)
    #expect(try String(contentsOf: skipped, encoding: .utf8) == "skipped source")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing destination")
    #expect(!FileManager().fileExists(atPath: moved.path))
    #expect(try String(contentsOf: fixture.destination.appendingPathComponent("moving"), encoding: .utf8) == "moving source")
    let id = try #require(result.recordID)
    do {
        let journal = try OperationJournal(fixture.journal)
        let record = try #require(try journal.inspect().records.first(where: { $0.id == id }))
        #expect(record.state == "committed")
        #expect(record.steps.count == 1)
        #expect(record.steps.first?.source == moved)
        #expect(!record.locations.contains(skipped))
        #expect(!record.locations.contains(existing))
    }
    #expect(await service.undo(recordID: id).result.disposition == .succeeded)
    #expect(try String(contentsOf: moved, encoding: .utf8) == "moving source")
    #expect(try String(contentsOf: skipped, encoding: .utf8) == "skipped source")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing destination")
}

@Test func skippingOuterFolderDoesNotInventNestedSkippedOutcomes() async throws {
    let fixture = try RecoveryFixture(); defer { fixture.remove() }
    let source = fixture.source.appendingPathComponent("folder")
    let destination = fixture.destination.appendingPathComponent("folder")
    for url in [source, destination] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    _ = try fixture.file("same", in: source)
    _ = try fixture.file("same", in: destination)
    let service = fixture.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
    #expect(plan.conflicts.count == 2)
    let outer = try #require(plan.conflicts.first(where: { $0.source.path == source.path }))
    let result = await service.perform(plan, resolutions: [outer.id: .skip])
    #expect(result.result.items.count == 1)
    #expect(result.result.items.first?.source?.path == source.path)
    #expect(result.result.items.first?.status == .skipped)
    #expect(result.result.disposition == .succeeded)
    #expect(result.recordID == nil)
}
