import Darwin
import Foundation
@testable import FileOperations
import Testing

/// Retained, generated-only roots. No test cleans or empties real Trash.
private struct GuardedTrashFixture {
    let root: URL, source: URL, retained: URL, protected: URL, journal: URL
    init() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        let old = try FileManager().contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("guarded-trash-") }
        // This packet retains its tiny failures/successes. Refuse exhaustion.
        guard old.count < 128 else { throw FileOperationFailure.quotaExceeded }
        var pending = old, entries = 0, logical: Int64 = 0, allocated: Int64 = 0
        while let path = pending.popLast() {
            var value = stat()
            guard lstat(path.path, &value) == 0, value.st_uid == geteuid() else { throw FileOperationFailure.invalidRequest }
            entries += 1; allocated += Int64(value.st_blocks) * 512
            if value.st_mode & S_IFMT == S_IFREG { logical += value.st_size }
            guard entries <= 2048 - 32, logical <= (16 << 20) - (64 << 10), allocated <= (32 << 20) - (512 << 10) else {
                throw FileOperationFailure.quotaExceeded
            }
            if value.st_mode & S_IFMT == S_IFDIR {
                pending += try FileManager().contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            }
        }
        root = base.appendingPathComponent("guarded-trash-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); retained = root.appendingPathComponent("retained")
        protected = root.appendingPathComponent("protected"); journal = root.appendingPathComponent("journal")
        for url in [root, source, retained, protected] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    func file(_ name: String = "generated.txt", in parent: URL? = nil) throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data("Generated selected Trash qualification".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func engine(trash: (@Sendable (URL) throws -> URL?)? = nil, hooks: RecoveryHooks = .init(),
                nativeTrashPolicy: NativeTrashMutationPolicy = .existingVerifiedPaths) -> RecoverableFileOperations {
        let target = retained
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks,
            legacy: LocalFileOperations(trash: trash ?? { url in
                let destination = target.appendingPathComponent(url.lastPathComponent)
                try FileManager().moveItem(at: url, to: destination); return destination
            }), nativeTrashPolicy: nativeTrashPolicy)
    }
}

@Suite(.serialized)
struct GuardedTrashTests {
    @Test func heldAndFileOnlyPoliciesRefuseGuardedCleanupBeforeHistoryOrNativeCall() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let ordinary = fixture.engine()
        let reviewed = try await ordinary.prepareGuardedTrash([file], protecting: [])
        for policy in [NativeTrashMutationPolicy.held, .regularFilesOnly] {
            let narrowed = RecoverableFileOperations(journalDirectory: fixture.journal,
                hooks: .init(), legacy: LocalFileOperations(trash: { _ in
                    throw FileOperationFailure.invalidRequest
                }), nativeTrashPolicy: policy)
            await #expect(throws: FileOperationFailure.unsupported) {
                try await narrowed.prepareGuardedTrash([file], protecting: [])
            }
            let refused = await narrowed.performGuardedTrash(reviewed)
            #expect(refused.recordID == nil && refused.result.disposition == .failed)
            #expect(refused.result.items.first?.status == .failed(.unsupported))
            #expect(FileManager().fileExists(atPath: file.path))
            #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        }
    }

    @Test(arguments: [false, true])
    func nativeFileAndFolderPolicyUsesExistingJournalAndColdUndo(_ folder: Bool) async throws {
        let fixture = try GuardedTrashFixture()
        let source: URL
        if folder {
            _ = try fixture.file("child.txt")
            source = fixture.source
        } else { source = try fixture.file() }
        let engine = fixture.engine(nativeTrashPolicy: .regularFilesAndDirectories)
        let reviewed = try await engine.prepareGuardedTrash([source], protecting: [fixture.protected])
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        let moved = await engine.performGuardedTrash(reviewed)
        #expect(moved.result.disposition == .succeeded)
        let id = try #require(moved.recordID)
        let target = try #require(moved.result.items.first?.destination)
        let record = try #require(try OperationJournal(fixture.journal).inspectRecord(id))
        #expect(record.version == (folder ? 12 : 11))
        #expect(record.steps.count == 1 && record.trashIntents.count == 1)
        #expect(record.steps.first?.source.path == source.path && record.steps.first?.destination.path == target.path)
        let summary = try #require(try await engine.inspectExistingHistory().records.first { $0.id == id })
        #expect(folder ? summary.nativeDirectoryTrashContract : summary.nativeRegularFileTrashContract)
        #expect(summary.canUndo)
        #expect(!FileManager().fileExists(atPath: source.path) && FileManager().fileExists(atPath: target.path))
        let cold = fixture.engine(nativeTrashPolicy: .regularFilesAndDirectories)
        #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
        let restored = folder ? source.appendingPathComponent("child.txt") : source
        #expect(try Data(contentsOf: restored) == Data("Generated selected Trash qualification".utf8))
        #expect(!FileManager().fileExists(atPath: target.path))
        let repeated = await engine.performGuardedTrash(reviewed)
        #expect(repeated.recordID == nil && repeated.result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: source.path))
    }

    @Test(arguments: [false, true])
    func guardedTrashRechecksAChildsProviderStatusAfterReview(_ narrow: Bool) async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let engine = fixture.engine(nativeTrashPolicy: narrow ? .regularFilesAndDirectories : .existingVerifiedPaths)
        let reviewed = try await engine.prepareGuardedTrash([fixture.source], protecting: [])
        let marker = Data([1])
        #expect(marker.withUnsafeBytes { setxattr(file.path, "com.apple.fileprovider.test", $0.baseAddress, marker.count, 0, 0) } == 0)
        let result = await engine.performGuardedTrash(reviewed)
        #expect(result.result.disposition == .failed && result.recordID == nil)
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        #expect(FileManager().fileExists(atPath: file.path))
    }

    @Test func guardedTrashRetainsTheNativeTargetAfterJournalFull() async throws {
        let fixture = try GuardedTrashFixture(), source = try fixture.file()
        let gate = GuardedJournalFault()
        let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: {
            if gate.enabled { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        }))
        let target = fixture.retained.appendingPathComponent("returned-name.txt")
        let engine = fixture.engine(trash: { url in
            try FileManager().moveItem(at: url, to: target); gate.enable(); return target
        }, hooks: hooks)
        let reviewed = try await engine.prepareGuardedTrash([source], protecting: [])
        let result = await engine.performGuardedTrash(reviewed)
        #expect(result.result.disposition == .partial)
        #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
        #expect(result.result.items.flatMap(\.recoveryURLs).contains(target))
        #expect(FileManager().fileExists(atPath: target.path) && !FileManager().fileExists(atPath: source.path))
        let id = try #require(result.recordID)
        let observed = try OperationJournal(fixture.journal).inspectRecord(id)
        let record = try #require(observed)
        #expect(record.trashIntents.count == 1 && record.steps.isEmpty)
        #expect(!record.locations.contains(target))
    }
    @Test func guardedTrashPreservesTheCallersDescendantExclusions() async throws {
        let fixture = try GuardedTrashFixture(), engine = fixture.engine()
        _ = try fixture.file("private-metadata-only.txt")
        await #expect(throws: FileOperationFailure.unsupported) {
            try await engine.prepareGuardedTrash([fixture.source], protecting: [], excluding: {
                $0.lastPathComponent == "private-metadata-only.txt"
            })
        }
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    }
    @Test func guardedTrashStopKeepsTheNativeSegmentAliveUntilDrained() async throws {
        let fixture = try GuardedTrashFixture(), first = try fixture.file("one.txt"), second = try fixture.file("two.txt")
        let hold = TrashCallHold(); defer { hold.release.signal() }
        let target = fixture.retained
        let engine = fixture.engine(trash: { url in
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            hold.markEntered()
            guard hold.release.wait(timeout: .now() + 5) == .success else { throw FileOperationFailure.unavailable }
            let to = target.appendingPathComponent(url.lastPathComponent)
            try FileManager().moveItem(at: url, to: to); return to
        })
        let reviewed = try await engine.prepareGuardedTrash([first, second], protecting: [])
        let task = Task { await engine.performGuardedTrash(reviewed) }
        for _ in 0..<1000 {
            if hold.entered { break }; try await Task.sleep(for: .milliseconds(1))
        }
        #expect(hold.entered); task.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.pendingWorkerCount == 1)
        hold.release.signal()
        let result = await task.value
        #expect(result.result.items.first(where: { $0.source == first })?.status == .succeeded)
        #expect(result.result.items.first(where: { $0.source == second })?.status == .notStarted)
        #expect(engine.pendingWorkerCount == 0)
        #expect(await engine.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: first.path) && FileManager().fileExists(atPath: second.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_GUARDED_TRASH"] == "1"))
    func guardedTrashNativeReturnedLocationAndUndo() async throws {
        let fixture = try GuardedTrashFixture()
        _ = try fixture.file()
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal)
        let reviewed = try await engine.prepareGuardedTrash([fixture.source], protecting: [fixture.protected])
        let moved = await engine.performGuardedTrash(reviewed)
        #expect(moved.result.disposition == .succeeded)
        let returned = try #require(moved.result.items.first(where: { $0.source?.path == fixture.source.path })?.destination)
        #expect(returned != fixture.source)
        #expect(FileManager().fileExists(atPath: returned.path))
        #expect(await engine.undo(recordID: try #require(moved.recordID)).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: fixture.source.path))
        #expect(!FileManager().fileExists(atPath: returned.path))
    }
    @Test func guardedTrashPreparationIsMetadataOnlyAndCancelCreatesNoHistory() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let engine = fixture.engine()
        var query = try #require(URLComponents(url: file, resolvingAgainstBaseURL: false))
        query.query = "not-a-file-path"
        var fragment = try #require(URLComponents(url: file, resolvingAgainstBaseURL: false))
        fragment.fragment = "not-a-file-path"
        let malformed = [URL(fileURLWithPath: file.path + "\u{0}suffix"), try #require(query.url), try #require(fragment.url)]
        for url in malformed {
            await #expect(throws: FileOperationFailure.invalidRequest) { try await engine.prepareGuardedTrash([url], protecting: []) }
        }
        let prepared = try await engine.prepareGuardedTrash([file], protecting: [fixture.protected])
        #expect(prepared.selection.urls == [file]); #expect(prepared.observedItems == 1)
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        #expect(try Data(contentsOf: file) == Data("Generated selected Trash qualification".utf8))
        let policy = try await engine.worker { _ in
            let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            let inside = try withoutMaterialization { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }
            let after = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            return (before, inside, after)
        }
        #expect(policy.0 == policy.2); #expect(policy.1 == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    @Test func guardedTrashKeepsExistingUndoAndIsSingleUse() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let engine = fixture.engine()
        let prepared = try await engine.prepareGuardedTrash([file], protecting: [fixture.protected])
        let moved = await engine.performGuardedTrash(prepared)
        #expect(moved.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: file.path))
        let undone = await engine.undo(recordID: try #require(moved.recordID))
        #expect(undone.result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: file.path))
        let second = await engine.performGuardedTrash(prepared)
        #expect(second.recordID == nil); #expect(second.result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: file.path))
    }

    @Test func guardedTrashRejectsWrongEngineAndReplacedObject() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let engine = fixture.engine()
        let prepared = try await engine.prepareGuardedTrash([file], protecting: [fixture.protected])
        let wrong = await fixture.engine().performGuardedTrash(prepared)
        #expect(wrong.recordID == nil); #expect(wrong.result.disposition == .failed)
        try FileManager().moveItem(at: file, to: fixture.retained.appendingPathComponent("original.txt"))
        _ = try fixture.file()
        let changed = await engine.performGuardedTrash(prepared)
        #expect(changed.recordID == nil); #expect(changed.result.disposition == .failed)
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        #expect(FileManager().fileExists(atPath: file.path))
    }

    @Test func guardedTrashRejectsReplacedParentAndOverlaps() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let engine = fixture.engine()
        await #expect(throws: FileOperationFailure.invalidRequest) {
            try await engine.prepareGuardedTrash([fixture.source, file], protecting: [])
        }
        let prepared = try await engine.prepareGuardedTrash([file], protecting: [])
        try FileManager().moveItem(at: fixture.source, to: fixture.retained.appendingPathComponent("old-source"))
        try FileManager().createDirectory(at: fixture.source, withIntermediateDirectories: false)
        _ = try fixture.file()
        let changed = await engine.performGuardedTrash(prepared)
        #expect(changed.recordID == nil); #expect(changed.result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: file.path))
    }

    @Test func guardedTrashProtectsAncestorsDescendantsMissingHistoryAndMetadataLinks() async throws {
        let fixture = try GuardedTrashFixture(), protected = try fixture.file(in: fixture.protected)
        let engine = fixture.engine()
        for source in [fixture.root, fixture.protected, protected] {
            await #expect(throws: source == fixture.root ? FileOperationFailure.operationHistoryProtected : .protectedLocation) {
                try await engine.prepareGuardedTrash([source], protecting: [fixture.protected])
            }
        }
        let history = fixture.source.appendingPathComponent("history")
        let childEngine = RecoverableFileOperations(journalDirectory: history)
        await #expect(throws: FileOperationFailure.operationHistoryProtected) {
            try await childEngine.prepareGuardedTrash([fixture.source], protecting: [])
        }
        let alias = fixture.source.appendingPathComponent("alias")
        try FileManager().linkItem(at: protected, to: alias)
        await #expect(throws: FileOperationFailure.protectedLocation) {
            try await engine.prepareGuardedTrash([fixture.source], protecting: [fixture.protected])
        }
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    }

    @Test func guardedTrashRejectsUnsupportedDescendantsAndCloudHints() async throws {
        let fixture = try GuardedTrashFixture(), engine = fixture.engine()
        let fifo = fixture.source.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: FileOperationFailure.unsupported) {
            try await engine.prepareGuardedTrash([fixture.source], protecting: [])
        }
        let file = try fixture.file(in: fixture.retained)
        let bytes = Data([1])
        let rc = bytes.withUnsafeBytes { setxattr(file.path, "com.apple.fileprovider.test", $0.baseAddress, bytes.count, 0, 0) }
        #expect(rc == 0)
        await #expect(throws: FileOperationFailure.unsupported) {
            try await engine.prepareGuardedTrash([file], protecting: [])
        }
        for flags in [UInt32(SF_DATALESS), UInt32(SF_FIRMLINK)] {
            var value = stat(); value.st_mode = S_IFREG | 0o600; value.st_flags = flags
            #expect(throws: FileOperationFailure.unsupported) { try GuardedTrashPolicy.requireMaterialized(value) }
        }
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    }

    @Test func guardedTrashFolderWithSymlinkAndNativeFailure() async throws {
        let fixture = try GuardedTrashFixture(), file = try fixture.file()
        let link = fixture.source.appendingPathComponent("link")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: fixture.protected.appendingPathComponent("not-read"))
        let engine = fixture.engine()
        let prepared = try await engine.prepareGuardedTrash([fixture.source], protecting: [fixture.protected])
        #expect(prepared.observedItems == 3)
        let moved = await engine.performGuardedTrash(prepared)
        #expect(moved.result.disposition == .succeeded)
        #expect(await engine.undo(recordID: try #require(moved.recordID)).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: file.path))
        let failing = fixture.engine(trash: { _ in throw FileOperationFailure.accessDenied })
        let review = try await failing.prepareGuardedTrash([file], protecting: [])
        let failure = await failing.performGuardedTrash(review)
        #expect(failure.result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: file.path))
        #expect(failure.recordID != nil)
    }
}

private final class TrashCallHold: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasEntered = false
    var entered: Bool { lock.withLock { hasEntered } }
    func markEntered() { lock.withLock { hasEntered = true } }
}
private final class GuardedJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool { lock.withLock { value } }
    func enable() { lock.withLock { value = true } }
}
