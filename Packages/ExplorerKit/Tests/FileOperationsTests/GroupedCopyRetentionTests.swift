import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct GroupedRetentionFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let fixtureTrash: URL
    let qualification: GroupedCopyQualification
    let inputs: [URL]
    init(count: Int = 17) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-retention-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try OperationJournal.writeExclusive(GroupedCopyQualification.marker,
            name: GroupedCopyQualification.markerName, anchor: DirectoryAnchor(root, resolve: false))
        qualification = try GroupedCopyQualification(root: root)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        fixtureTrash = root.appendingPathComponent("fixture-trash", isDirectory: true)
        for url in [source, destination, fixtureTrash] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let sourceDirectory = source
        inputs = (0..<count).map { sourceDirectory.appendingPathComponent("file-\($0).txt") }
        for (ordinal, input) in inputs.enumerated() {
            try Data("Generated grouped retained payload \(ordinal)".utf8).write(to: input, options: .withoutOverwriting)
        }
    }
    func remove() {
        guard root.resolvingSymlinksInPath().path == root.path,
              let anchor = try? DirectoryAnchor(root, resolve: false), anchor.identity.sameObject(as: qualification.identity),
              (try? OperationJournal.read(name: GroupedCopyQualification.markerName, anchor: anchor)) == GroupedCopyQualification.marker else { return }
        try? FileManager().removeItem(at: root)
    }
    func engine(_ configure: (inout RecoveryHooks) -> Void = { _ in }) -> RecoverableFileOperations {
        var hooks = RecoveryHooks(); hooks.groupedCopy.qualification = qualification
        let trash = fixtureTrash
        hooks.retentionTrash = { url in
            let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(trash, resolve: false)
            let name = UUID().uuidString
            try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: name)
            return trash.appendingPathComponent(name, isDirectory: true)
        }
        configure(&hooks)
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func completed() async throws -> UUID {
        let copied = await engine().perform(.copy(sources: inputs, destinationDirectory: destination))
        #expect(copied.result.disposition == .succeeded)
        return try #require(copied.recordID)
    }
    func record(_ id: UUID) throws -> GroupedCopyRecord {
        guard case .groupedCopyV1(let record)? = try OperationJournal(journal).inspectCatalogRecord(id) else {
            throw FileOperationFailure.recoveryUncertain
        }
        return record
    }
}

@Test(arguments: [1, 16, 17, 31, 33])
func groupedRetentionFixtureRelocationPreservesPublishedFilesAndEndsUndo(count: Int) async throws {
    let fixture = try GroupedRetentionFixture(count: count); defer { fixture.remove() }
    let id = try await fixture.completed()
    let engine = fixture.engine()
    let before = try fixture.record(id)
    let inspected = try await engine.retentionRecord(recordID: id)
    #expect(inspected.canCleanup && inspected.areas.count == before.groups.count)
    let cleaned = await engine.cleanupRecovery(recordID: id)
    #expect(cleaned.result.disposition == .succeeded)
    let record = try fixture.record(id)
    #expect(record.head.state == .cleaned && record.head.undoInvalidated)
    #expect(record.groups.allSatisfy { $0.cleanup.phase == "confirmed" })
    for member in before.members {
        let expected = try #require(member.progress.publication)
        #expect(expected.matches(try verifiedTree(member.manifest.destination.url, cancellation: OperationCancellation())))
        #expect(try Data(contentsOf: member.manifest.source.url) == Data(contentsOf: member.manifest.destination.url))
    }
    #expect(!(try await engine.retentionRecord(recordID: id)).canCleanup)
    #expect((await engine.undo(recordID: id)).result.disposition == .failed)
}

@Test func groupedRetentionUndonePayloadsRetainExactObjectsAndContents() async throws {
    let fixture = try GroupedRetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.completed(), engine = fixture.engine()
    #expect((await engine.undo(recordID: id)).result.disposition == .succeeded)
    let before = try fixture.record(id)
    let expectedBytes = before.members.reduce(Int64(0)) { $0 + ($1.progress.seal?.proof.payload.identity.size ?? 0) }
    let inspected = try await engine.retentionRecord(recordID: id)
    #expect(inspected.canCleanup && inspected.logicalBytes == expectedBytes)
    #expect((await engine.cleanupRecovery(recordID: id)).result.disposition == .succeeded)
    let record = try fixture.record(id)
    for group in record.groups {
        guard case .confirmed(_, let target, _) = group.cleanup else { Issue.record("Missing cleanup outcome"); continue }
        for ordinal in group.members {
            let original = before.members[ordinal]
            let declaration = try #require(original.progress.declaration)
            let seal = try #require(original.progress.seal)
            let payload = target.appendingPathComponent(declaration.areaURL.lastPathComponent, isDirectory: true).appendingPathComponent("payload")
            #expect(seal.proof.payload.matches(try verifiedTree(payload, cancellation: OperationCancellation())))
            #expect(!FileManager().fileExists(atPath: original.manifest.destination.url.path))
        }
    }
}

@Test(arguments: [GroupedCopyRetentionCheckpointStage.nativeTrashReturned, .returnedLocationRecorded, .trashSynced, .trashOutcomeRecorded])
func groupedRetentionStopsBetweenGroupsAndExplicitlyContinuesVerifiedRemaining(stage: GroupedCopyRetentionCheckpointStage) async throws {
    let fixture = try GroupedRetentionFixture(count: 33); defer { fixture.remove() }
    let id = try await fixture.completed()
    let stopping = fixture.engine { hooks in
        hooks.groupedRetention.checkpoint = { point, cancellation in
            if point.stage == stage && point.groupOrdinal == 0 { cancellation.cancel() }
        }
    }
    let first = await stopping.cleanupRecovery(recordID: id)
    #expect(first.result.cancellationRequested)
    let partial = try fixture.record(id)
    #expect(partial.head.state == .cleanupReview && partial.head.undoInvalidated)
    #expect(partial.groups.map { $0.cleanup.phase } == ["confirmed", "none", "none"])
    let fresh = fixture.engine()
    #expect((try await fresh.retentionRecord(recordID: id)).canCleanup)
    #expect((await fresh.cleanupRecovery(recordID: id)).result.disposition == .succeeded)
    #expect(try fixture.record(id).head.state == .cleaned)
}

@Test(arguments: [GroupedCopyRetentionCheckpointStage.trashIntentCommitted, .nativeTrashReturned, .returnedLocationRecorded, .trashSynced])
func groupedRetentionUnknownNativeBoundaryNeverRetries(stage: GroupedCopyRetentionCheckpointStage) async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let failing = fixture.engine { hooks in
        hooks.groupedRetention.checkpoint = { point, _ in if point.stage == stage { throw FileOperationFailure.ioFailure } }
    }
    #expect((await failing.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let before = try fixture.record(id)
    #expect(before.head.undoInvalidated && before.head.state == .cleanupReview)
    let expectedPhase = [GroupedCopyRetentionCheckpointStage.trashIntentCommitted, .nativeTrashReturned].contains(stage) ? "intent" : "returned"
    #expect(before.groups[0].cleanup.phase == expectedPhase)
    let fresh = fixture.engine { hooks in
        hooks.retentionTrash = { _ in Issue.record("Cold uncertain cleanup must not enter native Trash again"); throw FileOperationFailure.ioFailure }
    }
    let protected = try await fresh.retentionRecord(recordID: id)
    #expect(!protected.canCleanup)
    if case .returned(_, let knownTarget) = before.groups[0].cleanup {
        #expect(protected.areas.first?.url == knownTarget)
        #expect(protected.areas.first?.verified == false)
    }
    #expect((await fresh.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let after = try fixture.record(id)
    #expect(before.head.revision == after.head.revision)
    #expect(before.groups[0].cleanup.phase == after.groups[0].cleanup.phase)
}

@Test func groupedRetentionChangedLastGroupBlocksFirstTrashAndUndoInvalidation() async throws {
    let fixture = try GroupedRetentionFixture(count: 17); defer { fixture.remove() }
    let id = try await fixture.completed()
    let record = try fixture.record(id)
    let last = try #require(record.groups.last)
    try Data("Foreign generated occupant".utf8).write(to: last.areaURL.appendingPathComponent("foreign.txt"))
    let engine = fixture.engine()
    #expect(!(try await engine.retentionRecord(recordID: id)).canCleanup)
    #expect((await engine.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let after = try fixture.record(id)
    #expect(!after.head.undoInvalidated && after.head.revision == record.head.revision)
    for group in record.groups { #expect(FileManager().fileExists(atPath: group.areaURL.path)) }
}

@Test func groupedRetentionEqualContentReplacementOfPrivatePayloadIsProtected() async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed(), engine = fixture.engine()
    #expect((await engine.undo(recordID: id)).result.disposition == .succeeded)
    let record = try fixture.record(id)
    let declaration = try #require(record.members[0].progress.declaration)
    let payload = declaration.areaURL.appendingPathComponent("payload")
    let bytes = try Data(contentsOf: payload)
    let replacement = declaration.areaURL.appendingPathComponent("replacement")
    try bytes.write(to: replacement, options: .withoutOverwriting)
    try FileManager().removeItem(at: payload)
    try FileManager().moveItem(at: replacement, to: payload)
    #expect(!(try await engine.retentionRecord(recordID: id)).canCleanup)
    #expect((await engine.cleanupRecovery(recordID: id)).result.disposition == .failed)
    #expect(!((try fixture.record(id)).head.undoInvalidated))
}

@Test func groupedRetentionLostInvalidationAcknowledgementCannotEnterTrash() async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let failing = fixture.engine { hooks in
        hooks.journalHooks.afterSaveCommit = { throw FileOperationFailure.ioFailure }
        hooks.retentionTrash = { _ in Issue.record("Trash must not be entered after uncertain invalidation"); throw FileOperationFailure.ioFailure }
    }
    #expect((await failing.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let record = try fixture.record(id)
    #expect(record.head.undoInvalidated && record.groups[0].cleanup.phase == "none")
    #expect((try await fixture.engine().retentionRecord(recordID: id)).canCleanup)
    #expect((await fixture.engine().cleanupRecovery(recordID: id)).result.disposition == .succeeded)
}

// Replaces an empty retained member directory while preserving the containing
// tree's complete metadata/content digest. Only descendant identity can reject it.
private func groupedRetentionReplaceEmptyMemberArea(at group: URL, memberName: String, fixtureRoot: URL) throws {
    let groupAnchor = try DirectoryAnchor(group, resolve: false)
    let original = group.appendingPathComponent(memberName, isDirectory: true)
    let originalAnchor = try DirectoryAnchor(original, resolve: false)
    let before = try verifiedTree(group, cancellation: OperationCancellation())
    var groupStat = stat(), memberStat = stat()
    guard fstat(groupAnchor.fd, &groupStat) == 0, fstat(originalAnchor.fd, &memberStat) == 0 else {
        throw FileOperationFailure.ioFailure
    }
    let clone = fixtureRoot.appendingPathComponent("replacement-member", isDirectory: true)
    let displaced = fixtureRoot.appendingPathComponent("displaced-member", isDirectory: true)
    try FileManager().copyItem(at: original, to: clone)
    let fixtureAnchor = try DirectoryAnchor(fixtureRoot, resolve: false)
    try exclusiveRename(from: groupAnchor.fd, name: memberName, to: fixtureAnchor.fd, name: displaced.lastPathComponent)
    try exclusiveRename(from: fixtureAnchor.fd, name: clone.lastPathComponent, to: groupAnchor.fd, name: memberName)
    let replacement = try DirectoryAnchor(original, resolve: false)
    let memberFD = openat(groupAnchor.fd, memberName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard memberFD >= 0 else { throw FileOperationFailure.ioFailure }
    defer { close(memberFD) }
    let groupFD = openat(groupAnchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard groupFD >= 0 else { throw FileOperationFailure.ioFailure }
    defer { close(groupFD) }
    guard try EntrySnapshot(fd: memberFD).sameObject(as: replacement.identity),
          try EntrySnapshot(fd: groupFD).sameObject(as: groupAnchor.identity) else { throw FileOperationFailure.sourceChanged }
    var memberTimes = [memberStat.st_atimespec, memberStat.st_mtimespec]
    var groupTimes = [groupStat.st_atimespec, groupStat.st_mtimespec]
    guard futimens(memberFD, &memberTimes) == 0, futimens(groupFD, &groupTimes) == 0 else {
        throw FileOperationFailure.ioFailure
    }
    #expect(!replacement.identity.sameObject(as: originalAnchor.identity))
    #expect(before.matches(try verifiedTree(group, cancellation: OperationCancellation())))
}

@Test(arguments: [GroupedCopyRetentionCheckpointStage.trashSynced, .trashOutcomeWillCommit])
func groupedRetentionLastObserverRejectsEqualContentDescendantReplacement(stage: GroupedCopyRetentionCheckpointStage) async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let before = try fixture.record(id)
    let declaration = try #require(before.members[0].progress.declaration)
    let target = fixture.fixtureTrash.appendingPathComponent("retained-group", isDirectory: true)
    let engine = fixture.engine { hooks in
        hooks.retentionTrash = { url in
            let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(fixture.fixtureTrash, resolve: false)
            try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: target.lastPathComponent)
            return target
        }
        hooks.groupedRetention.checkpoint = { point, _ in
            if point.stage == stage {
                try groupedRetentionReplaceEmptyMemberArea(at: target, memberName: declaration.areaURL.lastPathComponent,
                    fixtureRoot: fixture.root)
            }
        }
    }
    let result = await engine.cleanupRecovery(recordID: id)
    #expect(result.result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("displaced-member").path))
    #expect(result.result.items.contains { $0.recoveryURLs.contains(target) })
    let after = try fixture.record(id)
    #expect(after.head.state == .cleanupReview && after.head.undoInvalidated)
    #expect(after.groups[0].cleanup.phase == "returned")
    #expect(before.members[0].progress.publication?.matches(try verifiedTree(before.members[0].manifest.destination.url,
        cancellation: OperationCancellation())) == true)
    let inspected = try await fixture.engine().retentionRecord(recordID: id)
    #expect(!inspected.canCleanup && inspected.areas.first?.url == target)
}

@Test func groupedRetentionTerminalObserverInventoryMutationPreventsCleanedState() async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let id = try await fixture.completed()
    let target = fixture.fixtureTrash.appendingPathComponent("retained-group", isDirectory: true)
    let engine = fixture.engine { hooks in
        hooks.retentionTrash = { url in
            let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(fixture.fixtureTrash, resolve: false)
            try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: target.lastPathComponent)
            return target
        }
        hooks.groupedRetention.checkpoint = { point, _ in
            if point.stage == .cleanupTerminalWillCommit {
                try Data("Generated late inventory occupant".utf8).write(to: target.appendingPathComponent("foreign"), options: .withoutOverwriting)
            }
        }
    }
    let result = await engine.cleanupRecovery(recordID: id)
    #expect(result.result.disposition == .partial)
    #expect(result.result.items.filter { $0.status == .succeeded }.count == 1)
    let after = try fixture.record(id)
    #expect(after.head.state == .cleanupReview && after.head.undoInvalidated)
    #expect(after.groups[0].cleanup.phase == "confirmed")
    #expect(!(try await fixture.engine().retentionRecord(recordID: id)).canCleanup)
    #expect(FileManager().fileExists(atPath: target.appendingPathComponent("foreign").path))
}

@Test func groupedRetentionDeclaredAreaWithoutDurableIdentityRemainsVisibleAndProtected() async throws {
    let fixture = try GroupedRetentionFixture(count: 1); defer { fixture.remove() }
    let engine = fixture.engine()
    let prepared = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination, move: false)
    let admission = try #require(prepared.groupedCopy)
    let id: UUID
    let area = admission.members[0].destination.parent.appendingPathComponent("declared-area", isDirectory: true)
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: admission.members)
        id = edit.id
        try edit.declareGroup(areaURL: area, memberAreaURLs: [area.appendingPathComponent("member-0", isDirectory: true)])
        try edit.markNeedsReview(); try journal.save(edit)
        // The directory exists, but no identity observation was ever committed.
        try FileManager().createDirectory(at: area, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try OperationJournal.writeExclusive(edit.snapshot.groups[0].marker,
            name: GroupedCopyGroup.markerName, anchor: DirectoryAnchor(area, resolve: false))
    }
    let before = try fixture.record(id)
    #expect(before.groups[0].areaIdentity == nil && before.groups[0].creationClosure == nil)
    let inspected = try await engine.retentionRecord(recordID: id)
    #expect(!inspected.canCleanup && inspected.logicalBytes == nil)
    #expect(inspected.areas.count == 1 && inspected.areas[0].url == area)
    #expect(inspected.areas[0].verified == false && inspected.areas[0].protectionReason != nil)
    #expect((await engine.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let after = try fixture.record(id)
    #expect(after.head.revision == before.head.revision && !after.head.undoInvalidated)
    #expect(FileManager().fileExists(atPath: area.path))
}

@Test(arguments: [FileOperationFailure.outOfSpace, .unavailable])
func groupedRetentionSyncFailurePreservesKnownNativeReturnWithoutClaimingCleanup(failure: FileOperationFailure) async throws {
    let fixture = try GroupedRetentionFixture(count: 17); defer { fixture.remove() }
    let id = try await fixture.completed()
    #expect((await fixture.engine().undo(recordID: id)).result.disposition == .succeeded)
    let original = try fixture.record(id)
    let failing = fixture.engine { hooks in
        hooks.beforeSync = { _ in throw failure }
    }
    let result = await failing.cleanupRecovery(recordID: id)
    #expect(result.result.disposition == .failed)
    #expect(result.result.items.contains { $0.status == .failed(failure) })
    let interrupted = try fixture.record(id)
    #expect(interrupted.head.state == .cleanupReview && interrupted.head.undoInvalidated)
    #expect(interrupted.groups.map { $0.cleanup.phase } == ["returned", "none"])
    guard case .returned(_, let target) = interrupted.groups[0].cleanup else {
        Issue.record("The known native return must be durable before synchronization"); return
    }
    #expect(FileManager().fileExists(atPath: target.path))
    #expect(FileManager().fileExists(atPath: original.groups[1].areaURL.path))
    let cold = fixture.engine { hooks in
        hooks.retentionTrash = { _ in Issue.record("An uncertain native result must never retry Trash"); throw FileOperationFailure.ioFailure }
    }
    let inspection = try await cold.retentionRecord(recordID: id)
    #expect(!inspection.canCleanup && inspection.areas.contains { $0.url == target && !$0.verified })
    #expect((await cold.cleanupRecovery(recordID: id)).result.disposition == .failed)
    #expect(try fixture.record(id).head.revision == interrupted.head.revision)
    for member in original.members {
        #expect(!FileManager().fileExists(atPath: member.manifest.destination.url.path))
        #expect(FileManager().fileExists(atPath: member.manifest.source.url.path))
    }
}

@Test func groupedRetentionChangedNeverDeclaredTailProtectsWholeJobBeforeInvalidation() async throws {
    let fixture = try GroupedRetentionFixture(count: 17); defer { fixture.remove() }
    let stopping = fixture.engine { hooks in
        hooks.groupedCopy.checkpoint = { point, cancellation in
            if point.stage == .groupOutcomesRecorded && point.groupOrdinal == 0 { cancellation.cancel() }
        }
    }
    let stopped = await stopping.perform(.copy(sources: fixture.inputs, destinationDirectory: fixture.destination))
    let id = try #require(stopped.recordID)
    let before = try fixture.record(id)
    #expect(before.head.state == .stoppedSettled && before.groups.count == 1)
    #expect(before.members[16].progress.phase == "notDeclared")
    let tail = before.members[16].manifest.destination.url
    try Data("Generated unrelated tail occupant".utf8).write(to: tail, options: .withoutOverwriting)
    let observed = try GroupedCopyFilesystemEvidence.inspect(before, cancellation: OperationCancellation())
    if case .occupied = observed.members[16].publicSlot {} else {
        Issue.record("The real filesystem inventory must observe the unrelated tail occupant")
    }
    let engine = fixture.engine { hooks in
        hooks.retentionTrash = { _ in Issue.record("A changed undeclared tail must protect all retained groups"); throw FileOperationFailure.ioFailure }
    }
    #expect(!(try await engine.retentionRecord(recordID: id)).canCleanup)
    #expect((await engine.cleanupRecovery(recordID: id)).result.disposition == .failed)
    let after = try fixture.record(id)
    #expect(after.head.revision == before.head.revision && !after.head.undoInvalidated)
    #expect(FileManager().fileExists(atPath: tail.path))
    #expect(FileManager().fileExists(atPath: before.groups[0].areaURL.path))
}

@Test(arguments: ["returned", "confirmed"])
func groupedRetentionFreshRefusalReportsPreviouslyRecordedNativeTargets(phase: String) async throws {
    let fixture = try GroupedRetentionFixture(count: 17); defer { fixture.remove() }
    let id = try await fixture.completed()
    let interruption = fixture.engine { hooks in
        hooks.groupedRetention.checkpoint = { point, _ in
            if point.groupOrdinal == 0 && point.stage == (phase == "returned" ? .returnedLocationRecorded : .trashOutcomeRecorded) {
                throw FileOperationFailure.ioFailure
            }
        }
    }
    let first = await interruption.cleanupRecovery(recordID: id)
    #expect(first.result.disposition != .succeeded)
    let before = try fixture.record(id)
    let known: URL
    switch before.groups[0].cleanup {
    case .returned(_, let target), .confirmed(_, let target, _): known = target
    default: Issue.record("Expected a durable native result before fresh refusal"); return
    }
    #expect(before.groups[0].cleanup.phase == phase)
    // Confirmed earlier groups normally permit explicit remaining cleanup. Make
    // a later group foreign so this attempt refuses before any new native call.
    if phase == "confirmed" {
        try Data("Generated later protected occupant".utf8).write(to: before.groups[1].areaURL.appendingPathComponent("foreign"), options: .withoutOverwriting)
    }
    let fresh = fixture.engine { hooks in
        hooks.retentionTrash = { _ in Issue.record("Fresh refusal must not re-enter Trash"); throw FileOperationFailure.ioFailure }
    }
    let inspected = try await fresh.retentionRecord(recordID: id)
    #expect(!inspected.canCleanup && inspected.areas.contains { $0.url == known })
    let refused = await fresh.cleanupRecovery(recordID: id)
    #expect(refused.result.disposition == .failed && refused.recordID == id)
    #expect(refused.result.items.contains { $0.recoveryURLs.contains(known) })
    let after = try fixture.record(id)
    #expect(after.head.revision == before.head.revision && after.groups[0].cleanup.phase == phase)
    #expect(FileManager().fileExists(atPath: known.path))
    #expect(FileManager().fileExists(atPath: before.groups[1].areaURL.path))
}

@Test(arguments: ["foreignLastGroup", "neverDeclaredTail"])
func groupedRetentionLateInventoryChangeCannotInvalidateUndo(variant: String) async throws {
    let fixture = try GroupedRetentionFixture(count: 17); defer { fixture.remove() }
    let id: UUID
    if variant == "neverDeclaredTail" {
        let stopping = fixture.engine { hooks in
            hooks.groupedCopy.checkpoint = { point, cancellation in
                if point.stage == .groupOutcomesRecorded && point.groupOrdinal == 0 { cancellation.cancel() }
            }
        }
        let stopped = await stopping.perform(.copy(sources: fixture.inputs, destinationDirectory: fixture.destination))
        id = try #require(stopped.recordID)
    } else { id = try await fixture.completed() }
    let before = try fixture.record(id)
    let changed: URL
    if variant == "neverDeclaredTail" { changed = before.members[16].manifest.destination.url }
    else { changed = try #require(before.groups.last).areaURL.appendingPathComponent("foreign", isDirectory: false) }
    if variant == "neverDeclaredTail" { #expect(before.members[16].progress.phase == "notDeclared") }
    #expect((try await fixture.engine().retentionRecord(recordID: id)).canCleanup)
    let late = fixture.engine { hooks in
        hooks.groupedRetention.checkpoint = { point, _ in
            if point.stage == .invalidationWillCommit {
                try Data("Generated late pre-invalidation occupant".utf8).write(to: changed, options: .withoutOverwriting)
            }
        }
        hooks.retentionTrash = { _ in Issue.record("Stale whole-job proof must refuse before Trash"); throw FileOperationFailure.ioFailure }
    }
    let refused = await late.cleanupRecovery(recordID: id)
    #expect(refused.result.disposition == .failed)
    let after = try fixture.record(id)
    #expect(!after.head.undoInvalidated && after.head.state == before.head.state && after.head.revision == before.head.revision)
    #expect(after.groups.map { $0.cleanup.phase } == before.groups.map { $0.cleanup.phase })
    #expect(FileManager().fileExists(atPath: changed.path))
    for group in before.groups { #expect(FileManager().fileExists(atPath: group.areaURL.path)) }
    for input in fixture.inputs { #expect(FileManager().fileExists(atPath: input.path)) }
}
