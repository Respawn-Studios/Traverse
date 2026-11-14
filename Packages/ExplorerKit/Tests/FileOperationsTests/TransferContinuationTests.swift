import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct ContinuationFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("continuation-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func file(_ path: String, destination target: Bool = false, text: String = "fixture") throws -> URL {
        let url = (target ? destination : source).appendingPathComponent(path)
        try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func remove() { try? FileManager().removeItem(at: root) }
}

private func continuationFailure(_ action: () async throws -> TransferPlan) async -> FileOperationFailure? {
    do { _ = try await action(); Issue.record("Expected continuation to refuse changed or consumed observations."); return nil }
    catch { return error as? FileOperationFailure }
}

private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}

private final class ContinuationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Generated-fixture replacement with unchanged bytes/ordinary metadata. Restoring
/// parent mtime makes VerifiedTree alone equivalent; exact descendant snapshots
/// must still reject the replacement and its parent's changed ctime.
private func replaceContinuationDescendant(_ file: URL, unit: URL, replacement: URL) throws {
    let cancellation = OperationCancellation()
    let before = try verifiedTree(unit, cancellation: cancellation)
    var parent = stat()
    guard lstat(file.deletingLastPathComponent().path, &parent) == 0 else { throw posixFailure() }
    try FileManager().copyItem(at: file, to: replacement)
    try FileManager().removeItem(at: file)
    try FileManager().moveItem(at: replacement, to: file)
    var times = [parent.st_atimespec, parent.st_mtimespec]
    guard utimensat(AT_FDCWD, file.deletingLastPathComponent().path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw posixFailure()
    }
    guard before.matches(try verifiedTree(unit, cancellation: cancellation)) else { throw FileOperationFailure.invalidRequest }
}

@Suite(.serialized) struct TransferContinuationTests {
    @Test(arguments: [false, true])
    func finalSyscallDescendantSubstitutionRemainsUncertainAndPreserved(mutateSource: Bool) async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let body = try f.file("tree/deep/body")
        let target = try f.file("tree/deep/body", destination: true, text: "original target")
        let folder = f.source.appendingPathComponent("tree")
        let targetFolder = f.destination.appendingPathComponent("tree")
        let mutationRoot = mutateSource ? folder : targetFolder
        let mutationBody = mutateSource ? body : target
        let once = ContinuationOnce()
        let service = f.service(RecoveryHooks(beforeExclusiveRename: { from, _ in
            if from == mutationRoot, once.take() {
                try replaceContinuationDescendant(mutationBody, unit: mutationRoot,
                    replacement: f.root.appendingPathComponent("replacement"))
            }
        }))
        let initial = try await service.prepareTransfer(sources: [folder], destinationDirectory: f.destination, move: true)
        let skipped = await service.perform(initial, resolutions: Dictionary(uniqueKeysWithValues: initial.conflicts.map { ($0.id, .skip) }))
        let next = try await service.prepareContinuation(try #require(skipped.continuation))
        let result = await service.perform(next, resolutions: Dictionary(uniqueKeysWithValues: next.conflicts.map { ($0.id, .replace) }))
        #expect(result.result.items.contains { $0.status == .failed(.recoveryUncertain) })
        #expect(result.continuation == nil)
        let recordID = try #require(result.recordID)
        let inspection = try await service.recoveryRecords()
        #expect(inspection.records.first { $0.id == recordID }?.state == "needsReview")
        if mutateSource {
            #expect(FileManager().fileExists(atPath: target.path))
        } else {
            #expect(FileManager().fileExists(atPath: body.path))
            #expect(result.result.items.flatMap(\.recoveryURLs).contains {
                $0.lastPathComponent == "displaced" && FileManager().fileExists(atPath: $0.appendingPathComponent("deep/body").path)
            })
        }
    }

    @Test func unchangedDirectoryContinuationAllowsRenameCtimeAndIndependentUndo() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let body = try f.file("tree/deep/body")
        let target = try f.file("tree/deep/body", destination: true, text: "original target")
        let folder = f.source.appendingPathComponent("tree")
        let service = f.service()
        let initial = try await service.prepareTransfer(sources: [folder], destinationDirectory: f.destination, move: true)
        let skipped = await service.perform(initial, resolutions: Dictionary(uniqueKeysWithValues: initial.conflicts.map { ($0.id, .skip) }))
        let next = try await service.prepareContinuation(try #require(skipped.continuation))
        let result = await service.perform(next, resolutions: Dictionary(uniqueKeysWithValues: next.conflicts.map { ($0.id, .replace) }))
        #expect(result.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: body.path))
        let undo = await service.undo(recordID: try #require(result.recordID))
        #expect(undo.result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: body.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "original target")
    }

    @Test(arguments: [false, true], [false, true])
    func originalDestinationSubtreeIsRecheckedAfterEarlierWorkAndOwnStaging(ownStaging: Bool, expandMerge: Bool) async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), body = try f.file("tree/branch/deep/body")
        _ = try f.file("first", destination: true, text: "existing first")
        let target = try f.file("tree/branch/deep/body", destination: true, text: "original target")
        let folder = f.source.appendingPathComponent("tree")
        let counter = ContinuationCounter()
        let service = f.service(RecoveryHooks(beforeSync: { payload in
            if payload.lastPathComponent == "payload", counter.next() == (ownStaging ? 2 : 1) {
                try Data("edited during transfer".utf8).write(to: target)
            }
        }))
        let initialPlan = try await service.prepareTransfer(sources: [first, folder], destinationDirectory: f.destination, move: false)
        let skipped = await service.perform(initialPlan, resolutions: Dictionary(uniqueKeysWithValues: initialPlan.conflicts.map { ($0.id, .skip) }))
        let token = try #require(skipped.continuation)
        let next = try await service.prepareContinuation(token)
        let choices = Dictionary(uniqueKeysWithValues: next.conflicts.map {
            ($0.id, expandMerge && $0.source == folder ? TransferConflictResolution.merge : .replace)
        })
        let result = await service.perform(next, resolutions: choices)
        let unit = expandMerge ? folder.appendingPathComponent("branch") : folder
        #expect(result.result.items.contains { $0.source == first && $0.status == .succeeded }, "\(result.result.items.map(\.status))")
        #expect(result.result.items.contains { $0.source == unit && $0.status == .failed(.destinationChanged) })
        #expect(result.continuation == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "edited during transfer")
        #expect(FileManager().fileExists(atPath: body.path))
    }

    @Test(arguments: [false, true], [false, true])
    func originalSourceDescendantIdentityIsRecheckedAfterEarlierWorkAndOwnStaging(ownStaging: Bool, expandMerge: Bool) async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), body = try f.file("tree/branch/deep/body")
        _ = try f.file("first", destination: true, text: "existing first")
        let target = try f.file("tree/branch/deep/body", destination: true, text: "original target")
        let folder = f.source.appendingPathComponent("tree")
        let unit = expandMerge ? folder.appendingPathComponent("branch") : folder
        let counter = ContinuationCounter()
        let service = f.service(RecoveryHooks(beforeSync: { payload in
            if payload.lastPathComponent == "payload", counter.next() == (ownStaging ? 2 : 1) {
                try replaceContinuationDescendant(body, unit: unit, replacement: f.root.appendingPathComponent("replacement"))
            }
        }))
        let initialPlan = try await service.prepareTransfer(sources: [first, folder], destinationDirectory: f.destination, move: false)
        let skipped = await service.perform(initialPlan, resolutions: Dictionary(uniqueKeysWithValues: initialPlan.conflicts.map { ($0.id, .skip) }))
        let next = try await service.prepareContinuation(try #require(skipped.continuation))
        let choices = Dictionary(uniqueKeysWithValues: next.conflicts.map {
            ($0.id, expandMerge && $0.source == folder ? TransferConflictResolution.merge : .replace)
        })
        let result = await service.perform(next, resolutions: choices)
        #expect(result.result.items.contains { $0.source == first && $0.status == .succeeded }, "\(result.result.items.map(\.status))")
        #expect(result.result.items.contains { $0.source == unit && $0.status == .failed(.sourceChanged) })
        #expect(result.continuation == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original target")
        #expect(FileManager().fileExists(atPath: body.path))
    }

    @Test func safeStopOffersOnlyNotStartedUnitsAndRefusesNewOccupant() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), remaining = try f.file("remaining")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = ContinuationOnce()
        let service = f.service(RecoveryHooks(afterRename: {
            if once.take() { entered.signal(); _ = release.wait(timeout: .now() + 15) }
        }))
        let plan = try await service.prepareTransfer(sources: [first, remaining], destinationDirectory: f.destination, move: true)
        let task = Task { await service.perform(plan) }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 15) == .success) }
        }
        task.cancel(); release.signal()
        let result = await task.value
        try #require(reached)
        let token = try #require(result.continuation)
        #expect(token.remainingSources.map(\.path) == [remaining.path])
        _ = try await service.prepareContinuation(token)
        let occupant = try f.file("remaining", destination: true, text: "new occupant")
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .destinationChanged)
        #expect(try String(contentsOf: occupant, encoding: .utf8) == "new occupant")
        #expect(FileManager().fileExists(atPath: remaining.path))
    }

    @Test func nestedMergeContinuesExactLeafAndRetainsAncestorsForIndependentUndo() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("tree/nested/a"), remaining = try f.file("tree/nested/b")
        let existing = try f.file("tree/nested/b", destination: true, text: "old")
        let tree = f.source.appendingPathComponent("tree")
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [tree], destinationDirectory: f.destination, move: true, metadataPolicy: .destinationOwnership)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.canMerge ? TransferConflictResolution.merge : .skip) })
        let original = await service.perform(plan, resolutions: choices)
        let originalID = try #require(original.recordID)
        let token = try #require(original.continuation)
        #expect(token.remainingSources.map(\.path) == [remaining.path])
        #expect(token.previousJobID == plan.jobID && token.previousRecordID == originalID)
        #expect(token.metadataPolicy == .destinationOwnership && token.isMove)
        let next = try await service.prepareContinuation(token)
        #expect(next.sources.map(\.path) == [remaining.path])
        #expect(next.conflicts.count == 1 && next.metadataPolicy == .destinationOwnership)
        let continued = await service.perform(next, resolutions: [next.conflicts[0].id: .replace])
        let nextID = try #require(continued.recordID)
        #expect(nextID != originalID && next.jobID != plan.jobID)
        #expect(continued.continuation == nil)
        let transferred = continued.result.items.filter { $0.role == .transfer }
        #expect(transferred.count == 1 && transferred.first?.status == .succeeded)
        #expect(transferred.first?.rootID == plan.entries[0].id && transferred.first?.rootSource?.path == tree.path)
        #expect(continued.result.items.filter { $0.role == .mergeContainer && $0.status == .notStarted }.count == 2)
        #expect(FileManager().fileExists(atPath: tree.appendingPathComponent("nested").path))
        // Earlier Undo remains usable even before Undoing the later job.
        #expect(await service.undo(recordID: originalID).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: first.path))
        #expect(await service.undo(recordID: nextID).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: remaining.path))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
    }

    @Test func preparingAndCancellingDoesNotClaimButPerformingClaimsAllPreparedCopies() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let source = try f.file("same"); _ = try f.file("same", destination: true, text: "old")
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: false)
        let initial = await service.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
        let token = try #require(initial.continuation)
        #expect(!FileManager().fileExists(atPath: f.journal.path))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.prepareContinuation(token)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled prepare should refuse.") } catch {}
        let first = try await service.prepareContinuation(token)
        let second = try await service.prepareContinuation(token)
        let skippedAgain = await service.perform(first, resolutions: [first.conflicts[0].id: .skip])
        let nextToken = try #require(skippedAgain.continuation)
        #expect(nextToken.id != token.id)
        let replay = await service.perform(second, resolutions: [second.conflicts[0].id: .replace])
        #expect(replay.result.disposition == .failed && replay.recordID == nil && replay.continuation == nil)
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .invalidRequest)
        let next = try await service.prepareContinuation(nextToken)
        #expect(next.conflicts.count == 1)
        #expect(try String(contentsOf: f.destination.appendingPathComponent("same"), encoding: .utf8) == "old")
    }

    @Test func originalSkippedSubtreeChangesAreRefusedEvenWhenParentIdentitySurvives() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let child = try f.file("folder/child")
        _ = try f.file("folder/old", destination: true)
        let folder = child.deletingLastPathComponent()
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [folder], destinationDirectory: f.destination, move: true)
        let outer = try #require(plan.conflicts.first { $0.source.path == folder.path })
        let skipped = await service.perform(plan, resolutions: [outer.id: .skip])
        let token = try #require(skipped.continuation)
        let unchangedParent = try DirectoryAnchor(folder, resolve: false).identity
        try Data("changed".utf8).write(to: child)
        #expect(try DirectoryAnchor(folder, resolve: false).identity.sameObject(as: unchangedParent))
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .sourceChanged)
        #expect(FileManager().fileExists(atPath: child.path))
    }

    @Test func skippedSubtreeBaselinePrecedesFirstTransferMutation() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), child = try f.file("folder/child")
        _ = try f.file("folder/old", destination: true)
        let folder = child.deletingLastPathComponent()
        let service = f.service(RecoveryHooks(beforeExclusiveRename: { from, _ in
            if from.path == first.path { try Data("edited after admission".utf8).write(to: child) }
        }))
        let plan = try await service.prepareTransfer(sources: [first, folder], destinationDirectory: f.destination, move: true)
        let outer = try #require(plan.conflicts.first { $0.source.path == folder.path })
        let result = await service.perform(plan, resolutions: [outer.id: .skip])
        let token = try #require(result.continuation)
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .sourceChanged)
    }

    @Test func changedDestinationAndPreparedPlanStalenessNeverGainNewConsent() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let source = try f.file("same"), target = try f.file("same", destination: true, text: "old")
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let initial = await service.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
        let token = try #require(initial.continuation)
        let prepared = try await service.prepareContinuation(token)
        try FileManager().removeItem(at: target)
        try Data("replacement".utf8).write(to: target, options: .withoutOverwriting)
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .destinationChanged)
        let refused = await service.perform(prepared, resolutions: [prepared.conflicts[0].id: .replace])
        #expect(refused.result.disposition == .failed && refused.recordID == nil && refused.continuation == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        #expect(FileManager().fileExists(atPath: source.path))
    }

    @Test func priorUndoAndServiceChangeInvalidateRemainingWork() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), skipped = try f.file("same")
        _ = try f.file("same", destination: true)
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [first, skipped], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
        let token = try #require(result.continuation)
        #expect(await continuationFailure { try await f.service().prepareContinuation(token) } == .invalidRequest)
        let prepared = try await service.prepareContinuation(token)
        let id = try #require(result.recordID)
        #expect(await service.undo(recordID: id).result.disposition == .succeeded)
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .recoveryUncertain)
        let refused = await service.perform(prepared, resolutions: [prepared.conflicts[0].id: .replace])
        #expect(refused.result.disposition == .failed && refused.recordID == nil)
    }

    @Test func priorCleanupIntentInvalidatesRemainingWorkWithoutTrashingFixture() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), skipped = try f.file("same")
        _ = try f.file("first", destination: true, text: "old")
        _ = try f.file("same", destination: true)
        let called = ContinuationOnce()
        let service = RecoverableFileOperations(journalDirectory: f.journal, hooks: RecoveryHooks(),
            legacy: LocalFileOperations(trash: { _ in
                _ = called.take()
                throw FileOperationFailure.unavailable
            }))
        let plan = try await service.prepareTransfer(sources: [first, skipped], destinationDirectory: f.destination, move: true)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.source.path == first.path ? TransferConflictResolution.replace : .skip) })
        let result = await service.perform(plan, resolutions: choices)
        let token = try #require(result.continuation)
        let id = try #require(result.recordID)
        let retained: URL
        do {
            let journal = try OperationJournal(f.journal)
            let stored = try journal.inspectRecord(id)
            let record = try #require(stored)
            retained = try #require(record.areas.first).url
            #expect(record.state == "committed" && record.trashIntents.isEmpty)
        }
        let cleanup = await service.cleanupRecovery(recordID: id)
        #expect(cleanup.result.disposition == .failed)
        #expect(!called.take(), "The injected native Trash seam must have been reached.")
        #expect(FileManager().fileExists(atPath: retained.path))
        do {
            let journal = try OperationJournal(f.journal)
            let stored = try journal.inspectRecord(id)
            let record = try #require(stored)
            #expect(record.state == "cleanupReview" && record.trashIntents.count == 1)
        }
        #expect(await continuationFailure { try await service.prepareContinuation(token) } == .recoveryUncertain)
        #expect(FileManager().fileExists(atPath: skipped.path))
    }

    @Test func activeFailureNeverIssuesContinuationForOtherUntouchedInputs() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let first = try f.file("first"), skipped = try f.file("same")
        _ = try f.file("same", destination: true)
        let service = f.service(RecoveryHooks(beforeExclusiveRename: { _, _ in throw FileOperationFailure.unavailable }))
        let plan = try await service.prepareTransfer(sources: [first, skipped], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
        #expect(result.continuation == nil)
        #expect(result.result.items.contains { $0.source?.path == first.path && $0.status == .failed(.unavailable) })
        #expect(FileManager().fileExists(atPath: first.path) && FileManager().fileExists(atPath: skipped.path))
    }

    @Test func cachedFilesystemDecisionRequiresNonemptyConsistentSelections() async throws {
        let f = try ContinuationFixture(); defer { f.remove() }
        let source = try f.file("a")
        let service = f.service()
        let selection = try await service.observeSelection([source])
        let destination = try await service.observeDirectory(f.destination)
        #expect(selection.sharesFileSystem(with: destination))
        let empty = selection.excluding(Set(selection.urls))
        #expect(!empty.sharesFileSystem(with: destination) && !selection.sharesFileSystem(with: empty))
        // The helper does no IO: it remains a cached policy hint after removal.
        try FileManager().removeItem(at: source)
        #expect(selection.sharesFileSystem(with: destination))
    }
}
