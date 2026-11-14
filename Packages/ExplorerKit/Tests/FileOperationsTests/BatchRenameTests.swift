import Darwin
import Foundation
import Testing
@testable import FileOperations

@Suite struct BatchRenameRuleTests {
    @Test func extensionAndLiteralReplacementContractsAreExplicit() throws {
        let input = [BatchRenameName(name: "archive.tar.gz", isDirectory: false), .init(name: ".env", isDirectory: false), .init(name: "Folder.ext", isDirectory: true)]
        #expect(try BatchRenameRule.addText(prefix: "P ", suffix: " S", preserveExtension: true).names(for: input) == ["P archive.tar S.gz", "P .env S", "P Folder.ext S"])
        #expect(try BatchRenameRule.replace(find: ".", with: "_", preserveExtension: false).names(for: input) == ["archive_tar_gz", "_env", "Folder_ext"])
        #expect(try BatchRenameRule.replace(find: "archive", with: "", preserveExtension: true).names(for: input).first == ".tar.gz")
        let unicode = [BatchRenameName(name: "日本語.txt", isDirectory: false), .init(name: "café.pdf", isDirectory: false)]
        #expect(try BatchRenameRule.numbered(base: "Report", separator: " ", start: 9, digits: 3, preserveExtension: true).names(for: unicode) == ["Report 009.txt", "Report 010.pdf"])
    }
    @Test func badRulesUnsafeNamesDuplicatesAndChainsRefuseBeforeMutation() throws {
        let input = [BatchRenameName(name: "one.txt", isDirectory: false), .init(name: "two.txt", isDirectory: false)]
        #expect(throws: BatchRenameValidation.invalidRule) { try BatchRenameRule.replace(find: "", with: "", preserveExtension: true).names(for: input) }
        for bad in ["/", ":", "\0", String(repeating: "界", count: 85)] {
            #expect(throws: BatchRenameValidation.unsafeName) { try BatchRenameRule.addText(prefix: bad, suffix: "", preserveExtension: true).names(for: input) }
        }
        #expect(throws: BatchRenameValidation.duplicateTarget) { try BatchRenameRule.replace(find: "o", with: "", preserveExtension: true).names(for: [.init(name: "o.txt", isDirectory: false), .init(name: "oo.txt", isDirectory: false)]) }
        #expect(throws: BatchRenameValidation.dependentNames) { try BatchRenameRule.replace(find: "one", with: "two", preserveExtension: true).names(for: input) }
        #expect(throws: BatchRenameValidation.duplicateTarget) { try BatchRenameRule.addText(prefix: "", suffix: "", preserveExtension: true).names(for: [.init(name: "É.txt", isDirectory: false), .init(name: "e\u{301}.txt", isDirectory: false)]) }
        #expect(throws: BatchRenameValidation.invalidRule) { try BatchRenameRule.numbered(base: "X", separator: "", start: 999_999_999, digits: 1, preserveExtension: false).names(for: input) }
        #expect(throws: BatchRenameValidation.tooManyItems) { try BatchRenameRule.addText(prefix: "", suffix: "", preserveExtension: false).names(for: Array(repeating: input[0], count: 513)) }
    }
    @Test func fullSelectionOrderAndByteNoopsRemainStable() throws {
        let input = (0..<512).map { BatchRenameName(name: "Item \($0).txt", isDirectory: false) }
        let names = try BatchRenameRule.numbered(base: "Image", separator: "-", start: 1, digits: 4, preserveExtension: true).names(for: input)
        #expect(names.first == "Image-0001.txt" && names.last == "Image-0512.txt")
        #expect(try BatchRenameRule.addText(prefix: "", suffix: "", preserveExtension: false).names(for: input) == input.map(\.name))
    }
}

private struct BatchRenameFixture {
    let root: URL, parent: URL, journal: URL
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_BATCH_RENAME_TEST_ROOT"] else { throw FileOperationFailure.invalidRequest }
        let admitted = URL(fileURLWithPath: raw), repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packet = repository.appendingPathComponent(".build/b09-batch-rename")
        guard admitted.resolvingSymlinksInPath() == admitted, admitted.lastPathComponent == "source",
              admitted.deletingLastPathComponent().deletingLastPathComponent() == packet,
              UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil,
              FileManager().fileExists(atPath: admitted.deletingLastPathComponent().appendingPathComponent("reservation.json").path) else { throw FileOperationFailure.invalidRequest }
        root = admitted.appendingPathComponent(UUID().uuidString); parent = root.appendingPathComponent("Items"); journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func file(_ name: String, bytes: String = "generated") throws -> URL {
        let source = parent.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: source, options: .withoutOverwriting); return source
    }
    func service(_ hooks: RecoveryHooks = .init()) -> RecoverableFileOperations { .init(journalDirectory: journal, hooks: hooks) }
    func plan(_ service: RecoverableFileOperations, _ sources: [URL], rule: BatchRenameRule = .addText(prefix: "New ", suffix: "", preserveExtension: true)) async throws -> BatchRenamePlan {
        try await service.prepareBatchRename(sources: sources, rule: rule, observing: service.observeSelection(sources))
    }
}
private final class BatchRenameBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func first() -> Bool { lock.withLock { count += 1; return count == 1 } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_BATCH_RENAME_TEST_ROOT"] != nil))
struct BatchRenameTests {
    @Test func filesAndFoldersHaveIndividualDurableUndoWithoutBodyChanges() async throws {
        let f = try BatchRenameFixture(), service = f.service()
        let a = try f.file("Report.txt"), folder = f.parent.appendingPathComponent("Folder")
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("generated child".utf8).write(to: folder.appendingPathComponent("child"))
        let plan = try await f.plan(service, [a, folder])
        #expect(!FileManager().fileExists(atPath: f.journal.path))
        let anchor = try DirectoryAnchor(f.parent)
        let before = try EntrySnapshot(parent: anchor.fd, name: "Report.txt")
        let result = await service.performBatchRename(plan)
        #expect(result.result.disposition == .succeeded && result.completedRecordIDs.count == 2)
        #expect(try EntrySnapshot(parent: anchor.fd, name: "New Report.txt").sameObject(as: before))
        #expect(try Data(contentsOf: plan.items[0].destination) == Data("generated".utf8))
        #expect(try await service.inspectExistingHistory().records.filter(\.canUndo).count == 2)
        try Data("edited after rename".utf8).write(to: plan.items[0].destination)
        let undo = try await service.undoBatchRename(result)
        #expect(undo.result.disposition == .succeeded && undo.remainingRecordIDs.isEmpty)
        #expect(try Data(contentsOf: a) == Data("edited after rename".utf8))
        #expect(FileManager().fileExists(atPath: folder.appendingPathComponent("child").path))
        await #expect(throws: FileOperationFailure.invalidRequest) { try await service.undoBatchRename(result) }
    }
    @Test func exactNoopsHaveNoJournalAndCaseOnlyStillUsesNativeRename() async throws {
        let f = try BatchRenameFixture(), service = f.service(), a = try f.file("Case.txt"), b = try f.file("Peer.txt")
        let noop = try await f.plan(service, [a, b], rule: .addText(prefix: "", suffix: "", preserveExtension: true))
        let none = await service.performBatchRename(noop)
        #expect(none.result.items.allSatisfy { $0.status == .skipped } && none.completedRecordIDs.isEmpty)
        #expect(!FileManager().fileExists(atPath: f.journal.path))
        let plan = try await f.plan(service, [a, b], rule: .replace(find: "Case", with: "case", preserveExtension: true))
        let result = await service.performBatchRename(plan)
        #expect(result.result.disposition == .succeeded && result.completedRecordIDs.count == 1)
        #expect(try NativeRenameEntry.observe(parent: DirectoryAnchor(f.parent), name: "Case.txt").name == "case.txt")
        #expect(try await service.undoBatchRename(result).result.disposition == .succeeded)
    }
    @Test func plansRejectAnotherEngineReplayAndChangedInputsBeforeAnyWrite() async throws {
        let f = try BatchRenameFixture(), service = f.service(), sources = [try f.file("A"), try f.file("B")]
        let plan = try await f.plan(service, sources)
        #expect(await f.service().performBatchRename(plan).result.items.first?.status == .failed(.invalidRequest))
        #expect(await service.performBatchRename(plan).result.disposition == .succeeded)
        #expect(await service.performBatchRename(plan).result.items.first?.status == .failed(.invalidRequest))
        let second = try BatchRenameFixture(), other = second.service(), input = [try second.file("A"), try second.file("B")]
        let stale = try await second.plan(other, input)
        try FileManager().moveItem(at: input[1], to: second.root.appendingPathComponent("retained"))
        try Data("replacement".utf8).write(to: input[1], options: .withoutOverwriting)
        let rejected = await other.performBatchRename(stale)
        #expect(rejected.result.items.first?.status == .failed(.sourceChanged))
        #expect(FileManager().fileExists(atPath: input[0].path) && !FileManager().fileExists(atPath: stale.items[0].destination.path))
        #expect(!FileManager().fileExists(atPath: second.journal.path))
        let restricted = RecoverableFileOperations(journalDirectory: second.journal, hooks: .init(), copyExecutionAuthorization: .generatedFixture)
        await #expect(throws: FileOperationFailure.unsupported) { try await second.plan(restricted, input) }
    }
    @Test func existingDestinationsAndLiveHistoryAreRefusedAtPreparation() async throws {
        let f = try BatchRenameFixture(), service = f.service(), sources = [try f.file("A"), try f.file("B")]
        _ = try f.file("New B", bytes: "keep existing")
        await #expect(throws: FileOperationFailure.conflict) { try await f.plan(service, sources) }
        #expect(!FileManager().fileExists(atPath: f.journal.path))
        let history = f.parent.appendingPathComponent("history")
        try FileManager().createDirectory(at: history, withIntermediateDirectories: false)
        let guarded = RecoverableFileOperations(journalDirectory: history)
        await #expect(throws: FileOperationFailure.operationHistoryProtected) { try await f.plan(guarded, [sources[0], history]) }
    }
    @Test func changedParentIsNotReboundToAnIdenticalLookingFolder() async throws {
        let f = try BatchRenameFixture(), service = f.service(), sources = [try f.file("A"), try f.file("B")]
        let plan = try await f.plan(service, sources)
        try FileManager().moveItem(at: f.parent, to: f.root.appendingPathComponent("Retained Items"))
        try FileManager().createDirectory(at: f.parent, withIntermediateDirectories: false)
        for source in sources { try Data("replacement".utf8).write(to: source, options: .withoutOverwriting) }
        #expect(await service.performBatchRename(plan).result.items.first?.status == .failed(.destinationChanged))
        #expect(!FileManager().fileExists(atPath: f.journal.path))
    }
    @Test func lateConflictKeepsCommittedPrefixAndNeverOverwrites() async throws {
        let f = try BatchRenameFixture(), barrier = BatchRenameBarrier()
        let sources = [try f.file("A"), try f.file("B"), try f.file("C")]
        var hooks = RecoveryHooks()
        hooks.afterRename = { if barrier.first() { try! Data("late existing".utf8).write(to: f.parent.appendingPathComponent("New B"), options: .withoutOverwriting) } }
        let service = f.service(hooks), plan = try await f.plan(service, sources)
        let result = await service.performBatchRename(plan)
        #expect(result.result.disposition == .partial && result.completedRecordIDs.count == 1)
        #expect(result.units[1].outcome.result.items.first?.status == .failed(.conflict) && result.units[2].outcome.result.items.first?.status == .notStarted)
        #expect(try Data(contentsOf: f.parent.appendingPathComponent("New B")) == Data("late existing".utf8))
        #expect(try await service.undoBatchRename(result).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: sources[0].path))
    }
    @Test func stopAfterFirstMutationDrainsThatCommitAndLeavesRemainderUntouched() async throws {
        let f = try BatchRenameFixture(), barrier = BatchRenameBarrier(), sources = [try f.file("A"), try f.file("B"), try f.file("C")]
        var hooks = RecoveryHooks()
        hooks.afterRename = { if barrier.first() { barrier.entered.signal(); barrier.release.wait() } }
        let service = f.service(hooks), plan = try await f.plan(service, sources)
        let task = Task { await service.performBatchRename(plan) }
        let reached = await Task.detached { barrier.waitForEntry() }.value
        #expect(reached); task.cancel()
        #expect(service.pendingWorkerCount == 1)
        barrier.release.signal(); let result = await task.value
        #expect(result.cancellationRequested && result.result.disposition == .partial && result.completedRecordIDs.count == 1)
        #expect(result.units.dropFirst().allSatisfy { $0.outcome.result.items.first?.status == .notStarted })
        #expect(service.pendingWorkerCount == 0 && FileManager().fileExists(atPath: sources[1].path))
        #expect(try await service.undoBatchRename(result).result.disposition == .succeeded)
    }
    @Test func persistenceFailureStaysReviewableAndStopsRemainingUnits() async throws {
        let f = try BatchRenameFixture(), sources = [try f.file("A"), try f.file("B")]
        let service = f.service(.init(beforeSync: { _ in throw FileOperationFailure.ioFailure })), plan = try await f.plan(service, sources)
        let result = await service.performBatchRename(plan)
        #expect(result.result.disposition == .failed && result.completedRecordIDs.isEmpty)
        #expect(result.units[1].outcome.result.items.first?.status == .notStarted)
        let id = try #require(result.units[0].outcome.recordID)
        let fresh = f.service(), history = try await fresh.recoveryRecords()
        #expect(history.records.first?.id == id && history.records.first?.canRecover == true)
        #expect(await fresh.recover(recordID: id).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: sources[0].path) && FileManager().fileExists(atPath: sources[1].path))
    }
}
