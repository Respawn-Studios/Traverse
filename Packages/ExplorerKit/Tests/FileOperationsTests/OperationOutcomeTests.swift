import Foundation
@testable import FileOperations
import Testing

private struct OutcomeFixture {
    let root: URL
    let source: URL
    let destination: URL
    let nested: URL
    let targetNested: URL
    let journal: URL

    init(conflict: Bool = false, empty: Bool = false) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("outcomes-" + UUID().uuidString)
        source = root.appendingPathComponent("source/tree")
        destination = root.appendingPathComponent("destination")
        nested = source.appendingPathComponent("nested")
        targetNested = destination.appendingPathComponent("tree/nested")
        journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager().createDirectory(at: targetNested, withIntermediateDirectories: true)
        if !empty {
            try Data("first".utf8).write(to: nested.appendingPathComponent("a"), options: .withoutOverwriting)
            try Data("second".utf8).write(to: nested.appendingPathComponent("b"), options: .withoutOverwriting)
        }
        if conflict { try Data("existing".utf8).write(to: targetNested.appendingPathComponent("b"), options: .withoutOverwriting) }
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func choices(_ plan: TransferPlan) -> [UUID: TransferConflictResolution] {
        Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.canMerge ? .merge : .skip) })
    }
    func exists(_ name: String, target: Bool = false) -> Bool {
        FileManager().fileExists(atPath: (target ? targetNested : nested).appendingPathComponent(name).path)
    }
    func remove() { try? FileManager().removeItem(at: root) }
}

private final class OutcomeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}

@Suite(.serialized) struct OperationOutcomeTests {
    @Test func nestedPartialMergeGroupsLeavesWithoutInventingUntouchedRoot() async throws {
        let f = try OutcomeFixture(conflict: true); defer { f.remove() }
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: f.choices(plan))
        let transfers = result.result.items.filter { $0.role == .transfer }
        let containers = result.result.items.filter { $0.role == .mergeContainer }
        #expect(result.result.disposition == .partial)
        #expect(transfers.count == 2)
        #expect(transfers.contains { $0.source?.lastPathComponent == "a" && $0.status == .succeeded })
        #expect(transfers.contains { $0.source?.lastPathComponent == "b" && $0.status == .skipped })
        #expect(containers.count == 2)
        #expect(containers.allSatisfy { $0.status == .failed(.conflict) })
        #expect(result.result.items.allSatisfy { $0.rootID == plan.entries[0].id && $0.rootSource?.path == f.source.path })
        #expect(Set(result.result.items.compactMap(\.itemID)).count == result.result.items.count)
        #expect(!f.exists("a") && f.exists("a", target: true) && f.exists("b"))
        #expect(try String(contentsOf: f.targetNested.appendingPathComponent("b"), encoding: .utf8) == "existing")
        let id = try #require(result.recordID)
        #expect(await service.undo(recordID: id).result.disposition == .succeeded)
        #expect(f.exists("a") && f.exists("b") && !f.exists("a", target: true))
    }

    @Test func stopAfterLeafMoveReportsPendingLeavesAndContainerRetirementsSeparately() async throws {
        let f = try OutcomeFixture(); defer { f.remove() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = OutcomeOnce()
        let service = f.service(RecoveryHooks(afterRename: {
            if once.take() { entered.signal(); _ = release.wait(timeout: .now() + 15) }
        }))
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let task = Task { await service.perform(plan, resolutions: f.choices(plan)) }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 15) == .success) }
        }
        task.cancel(); release.signal()
        let result = await task.value
        try #require(reached)
        let transfers = result.result.items.filter { $0.role == .transfer }
        #expect(result.result.cancellationRequested)
        #expect(result.result.disposition == .partial)
        #expect(transfers.count == 2)
        #expect(transfers.filter { $0.status == .succeeded }.count == 1)
        #expect(transfers.filter { $0.status == .notStarted }.count == 1)
        #expect(transfers.allSatisfy { $0.source?.deletingLastPathComponent().path == f.nested.path })
        let containers = result.result.items.filter { $0.role == .mergeContainer }
        #expect(containers.count == 2 && containers.allSatisfy { $0.status == .notStarted })
        let id = try #require(result.recordID)
        #expect(await f.service().undo(recordID: id).result.disposition == .succeeded)
        #expect(f.exists("a") && f.exists("b"))
    }

    @Test func failedContainerRetirementDoesNotEraseCompletedChildResults() async throws {
        let f = try OutcomeFixture(); defer { f.remove() }
        let service = f.service(RecoveryHooks(beforeExclusiveRename: { source, _ in
            if source.path == f.nested.path { throw FileOperationFailure.unavailable }
        }))
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: f.choices(plan))
        let transfers = result.result.items.filter { $0.role == .transfer }
        #expect(transfers.count == 2 && transfers.allSatisfy { $0.status == .succeeded })
        #expect(result.result.items.contains { $0.role == .mergeContainer && $0.source?.path == f.nested.path && $0.status == .failed(.unavailable) })
        #expect(result.result.items.contains { $0.role == .mergeContainer && $0.source?.path == f.source.path && $0.status == .notStarted })
        #expect(!result.result.items.contains { $0.role == .job })
        #expect(!f.exists("a") && !f.exists("b") && f.exists("a", target: true) && f.exists("b", target: true))
        let id = try #require(result.recordID)
        #expect(await f.service().recover(recordID: id).result.disposition == .succeeded)
        #expect(f.exists("a") && f.exists("b"))
    }

    @Test func journalFailureReportsJobFailureAndExactResolvedUnits() async throws {
        let f = try OutcomeFixture(); defer { f.remove() }
        let service = f.service(RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: { throw FileOperationFailure.outOfSpace })))
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: f.choices(plan))
        let jobs = result.result.items.filter { $0.role == .job }
        #expect(jobs.count == 1 && jobs.first?.status == .failed(.outOfSpace))
        #expect(jobs.first?.itemID == nil && jobs.first?.rootID == nil)
        let transfers = result.result.items.filter { $0.role == .transfer }
        #expect(transfers.count == 2 && transfers.allSatisfy { $0.status == .notStarted })
        #expect(transfers.allSatisfy { $0.source?.deletingLastPathComponent().path == f.nested.path })
        #expect(result.result.items.filter { $0.role == .mergeContainer }.count == 2)
        #expect(f.exists("a") && f.exists("b") && !f.exists("a", target: true) && !f.exists("b", target: true))
    }

    @Test func incompleteResolutionReportsOnlyUnattemptedOriginalInput() async throws {
        let f = try OutcomeFixture(conflict: true); defer { f.remove() }
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.filter(\.canMerge).map { ($0.id, TransferConflictResolution.merge) })
        let result = await service.perform(plan, resolutions: choices)
        #expect(result.recordID == nil)
        #expect(result.result.items.count == 2)
        #expect(result.result.items.contains { $0.role == .job && $0.status == .failed(.conflict) })
        #expect(result.result.items.contains { $0.role == .transfer && $0.source?.path == f.source.path && $0.itemID == plan.entries[0].id && $0.status == .notStarted })
        #expect(f.exists("a") && f.exists("b") && !f.exists("a", target: true))
    }

    @Test func emptyMergedMoveReportsOnlyRetiredFoldersAndCanUndo() async throws {
        let f = try OutcomeFixture(empty: true); defer { f.remove() }
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: true)
        let result = await service.perform(plan, resolutions: f.choices(plan))
        #expect(result.result.disposition == .succeeded)
        #expect(result.result.items.count == 2)
        #expect(result.result.items.allSatisfy { $0.role == .mergeContainer && $0.status == .succeeded })
        #expect(!FileManager().fileExists(atPath: f.source.path))
        let id = try #require(result.recordID)
        #expect(await service.undo(recordID: id).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: f.nested.path))
    }
}
