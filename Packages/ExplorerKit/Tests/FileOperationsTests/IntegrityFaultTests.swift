import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

private struct IntegrityFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let trash: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("integrity-fault-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal"); trash = root.appendingPathComponent("fixture-trash")
        for url in [root, source, destination, trash] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    func file(_ name: String = "item", in parent: URL? = nil, contents: String = "generated original") throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks(), trashOperation: (@Sendable (URL) throws -> URL)? = nil) -> RecoverableFileOperations {
        if let trashOperation { return RecoverableFileOperations(journalDirectory: journal, hooks: hooks, legacy: LocalFileOperations(trash: trashOperation)) }
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func remove() { try? FileManager().removeItem(at: root) }
}

private final class IntegrityFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func enable() { lock.withLock { enabled = true } }
    var active: Bool { lock.withLock { enabled } }
}

private func storageError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

@Suite(.serialized) struct IntegrityFaultTests {
    @Test func storageErrorClassificationKeepsQuotaFullAndUnavailableDistinct() {
        #expect(posixFailure(ENOSPC) == .outOfSpace)
        #expect(posixFailure(EDQUOT) == .quotaExceeded)
        for code in [ENODEV, ESTALE, ENXIO, ENOTCONN] { #expect(posixFailure(code) == .unavailable) }
        #expect(posixFailure(EIO) == .ioFailure)
        #expect(posixFailure(ENOENT) == .notFound)
        #expect(SQLiteJournalStore.failure(SQLITE_FULL) == .outOfSpace)
        #expect(SQLiteJournalStore.failure(SQLITE_IOERR | (3 << 8)) == .ioFailure)
        #expect(SQLiteJournalStore.failure(SQLITE_CORRUPT) == .recoveryUncertain)
    }

    @Test func cocoaStorageFailurePreservesBoundedUnderlyingPOSIXCause() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: storageError(EDQUOT)])
        #expect(operationStatus(wrapped) == .failed(.quotaExceeded))
        #expect(operationStatus(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .failed(.outOfSpace))
        var deep = storageError(ENOSPC)
        for _ in 0..<12 { deep = NSError(domain: "fixture", code: 1, userInfo: [NSUnderlyingErrorKey: deep]) }
        #expect(operationStatus(deep) == .failed(.ioFailure))
        #expect(operationStatus(NSError(domain: NSPOSIXErrorDomain, code: Int.max)) == .failed(.ioFailure))
    }

    @Test func nativeCopyErrorSurvivesSimultaneousStopAndCallbackQuit() throws {
        let cancelled = OperationCancellation(); cancelled.cancel()
        #expect(throws: FileOperationFailure.outOfSpace) {
            try validateNativeCopyResult(result: -1, error: ENOSPC, callbackError: nil, cancellation: cancelled)
        }
        #expect(throws: FileOperationFailure.quotaExceeded) {
            try validateNativeCopyResult(result: -1, error: ECANCELED, callbackError: EDQUOT, cancellation: cancelled)
        }
        #expect(throws: CancellationError.self) {
            try validateNativeCopyResult(result: -1, error: ECANCELED, callbackError: nil, cancellation: cancelled)
        }
        #expect(throws: FileOperationFailure.unsupported) {
            try validateNativeCopyResult(result: -1, error: ENOTSUP, callbackError: ENOSPC, cancellation: cancelled)
        }
    }

    @Test(arguments: [ENOSPC, EDQUOT, ENODEV]) func partialCopyFailurePreservesSourceAndProtectsUnsealedPayload(code: Int32) async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let original = try verifiedTree(source, cancellation: OperationCancellation())
        let hooks = RecoveryHooks(copyFaults: CopyFaultHooks(beforeNativeCopy: { _, destination in
            // A deterministic partial-write seam, not a claim of real disk exhaustion.
            let prefix = Data("partial".utf8)
            guard prefix.withUnsafeBytes({ write(destination, $0.baseAddress, $0.count) }) == prefix.count else { throw storageError(errno) }
            throw storageError(code)
        }))
        let result = await fixture.service(hooks).perform(.copy(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(posixFailure(code)) })
        #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("item").path))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview")
        #expect(record.steps.isEmpty)
        let area = try #require(record.areas.first)
        #expect(try Data(contentsOf: area.url.appendingPathComponent("payload")) == Data("partial".utf8))
        let inspection = try await fixture.service().retentionInspection()
        #expect(inspection.records.first { $0.id == id }?.canCleanup != true)
    }

    @Test func unavailableBeforeRenameLeavesDurableUnexecutedIntentAndOriginal() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let original = try verifiedTree(source, cancellation: OperationCancellation())
        let result = await fixture.service(RecoveryHooks(beforeExclusiveRename: { _, _ in throw storageError(ENODEV) }))
            .perform(.move(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.unavailable) })
        #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview")
        #expect(record.steps.count == 1 && record.steps[0].after == nil)
        #expect(await fixture.service().recover(recordID: id).result.disposition == .succeeded)
    }

    @Test func journalFullBeforeFirstIntentLeavesOriginalWithoutMutationRecord() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let before = try verifiedTree(source, cancellation: OperationCancellation())
        let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: { throw storageError(ENOSPC) }))
        let result = await fixture.service(hooks).perform(.move(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        #expect(before.matches(try verifiedTree(source, cancellation: OperationCancellation())))
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try await fixture.service().recoveryRecords().records.isEmpty)
    }

    @Test func stagingSyncFullDoesNotPublishOrRetireSource() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let before = try verifiedTree(source, cancellation: OperationCancellation())
        let result = await fixture.service(RecoveryHooks(beforeSync: { _ in throw storageError(ENOSPC) }))
            .perform(.copy(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        #expect(before.matches(try verifiedTree(source, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("item").path))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview" && record.steps.isEmpty)
        let area = try #require(record.areas.first)
        #expect(FileManager().fileExists(atPath: area.url.appendingPathComponent("payload").path))
        #expect(try await fixture.service().retentionRecord(recordID: id).canCleanup == false)
    }

    @Test func syncFullAfterRenamePreservesDestinationAndReopensReviewableIntent() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let original = try verifiedTree(source, cancellation: OperationCancellation())
        let gate = IntegrityFaultGate()
        let hooks = RecoveryHooks(beforeSync: { _ in if gate.active { throw storageError(ENOSPC) } }, afterRename: { gate.enable() })
        let result = await fixture.service(hooks).perform(.move(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        let target = fixture.destination.appendingPathComponent("item")
        #expect(original.matches(try verifiedTree(target, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: source.path))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "needsReview")
        #expect(record.steps.count == 1 && record.steps[0].after == nil)
        #expect(record.locations.contains(target))
        #expect(await fixture.service().recover(recordID: id).result.disposition == .succeeded)
        #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
    }

    @Test func journalFullAfterRenamePreservesLastDurableIntentAndLiveLocations() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let original = try verifiedTree(source, cancellation: OperationCancellation())
        let gate = IntegrityFaultGate()
        let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: {
            if gate.active { throw storageError(ENOSPC) }
        }), afterRename: { gate.enable() })
        let result = await fixture.service(hooks).perform(.move(sources: [source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        let target = fixture.destination.appendingPathComponent("item")
        #expect(original.matches(try verifiedTree(target, cancellation: OperationCancellation())))
        #expect(result.result.items.flatMap(\.recoveryURLs).contains(target))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "mutating")
        #expect(record.steps.count == 1 && record.steps[0].after == nil)
        #expect(await fixture.service().recover(recordID: id).result.disposition == .succeeded)
        #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
    }

    @Test func nativeTrashKnownTargetSurvivesJournalFullWithoutDurabilityClaim() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file()
        let gate = IntegrityFaultGate()
        let target = fixture.trash.appendingPathComponent("item")
        let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: { if gate.active { throw storageError(ENOSPC) } }))
        let service = fixture.service(hooks, trashOperation: { url in
            let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(fixture.trash, resolve: false)
            try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: target.lastPathComponent)
            gate.enable(); return target
        })
        let result = await service.perform(.trash(sources: [source]))
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        #expect(result.result.items.flatMap(\.recoveryURLs).contains(target))
        #expect(FileManager().fileExists(atPath: target.path))
        let id = try #require(result.recordID)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.trashIntents.count == 1)
        #expect(record.steps.isEmpty)
        #expect(!record.locations.contains(target))
    }

    @Test func retainedBackupQuotaFailurePreservesBothFilesAndReviewState() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file(contents: "incoming")
        let target = try fixture.file(in: fixture.destination, contents: "displaced")
        let service = fixture.service()
        let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
        let copied = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .replace])
        try #require(copied.result.disposition == .succeeded)
        let id = try #require(copied.recordID)
        let before = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        let area = try #require(before.areas.first)
        let backup = area.url.appendingPathComponent("displaced")
        let originalBackup = try verifiedTree(backup, cancellation: OperationCancellation())
        let failed = await fixture.service(trashOperation: { _ in throw storageError(EDQUOT) }).cleanupRecovery(recordID: id)
        #expect(failed.result.items.contains { $0.status == .failed(.quotaExceeded) })
        #expect(originalBackup.matches(try verifiedTree(backup, cancellation: OperationCancellation())))
        #expect(try String(contentsOf: target, encoding: .utf8) == "incoming")
        #expect(try String(contentsOf: source, encoding: .utf8) == "incoming")
        let reopened = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(reopened.state == "cleanupReview")
        #expect(await fixture.service().cleanupRecovery(recordID: id).result.disposition == .failed)
    }

    @Test func retainedBackupKnownTargetSurvivesOutcomeCommitFull() async throws {
        let fixture = try IntegrityFixture(); defer { fixture.remove() }
        let source = try fixture.file(contents: "incoming")
        _ = try fixture.file(in: fixture.destination, contents: "displaced")
        let plan = try await fixture.service().prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
        let copied = await fixture.service().perform(plan, resolutions: [try #require(plan.conflicts.first).id: .replace])
        try #require(copied.result.disposition == .succeeded)
        let id = try #require(copied.recordID)
        let gate = IntegrityFaultGate()
        let service = fixture.service(trashOperation: { url in
            let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(fixture.trash, resolve: false)
            let target = fixture.trash.appendingPathComponent(url.lastPathComponent)
            try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: target.lastPathComponent)
            gate.enable(); return target
        })
        let failed = await service.cleanupRecovery(recordID: id, progress: nil, journalHooks: JournalStorageHooks(beforeSaveCommit: {
            if gate.active { throw storageError(ENOSPC) }
        }))
        #expect(failed.result.items.contains { $0.status == .failed(.outOfSpace) })
        let known = failed.result.items.flatMap(\.recoveryURLs).filter { $0.deletingLastPathComponent().path == fixture.trash.path }
        #expect(known.count == 1)
        #expect(try String(contentsOf: try #require(known.first).appendingPathComponent("displaced"), encoding: .utf8) == "displaced")
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.state == "cleanupReview")
        #expect(!record.locations.contains(where: { $0.deletingLastPathComponent().path == fixture.trash.path }))
        #expect(await fixture.service().recover(recordID: id).result.disposition == .failed)
    }
}
