import Darwin
import Foundation
import Testing
@testable import FileOperations

private struct DuplicateFixture {
    let root: URL, parent: URL, journal: URL
    init() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["MAC_EXPLORER_DUPLICATE_TEST_ROOT"])
        let base = URL(fileURLWithPath: raw)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(base.lastPathComponent == "source" && base.resolvingSymlinksInPath() == base
            && base.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-duplicate")
            && UUID(uuidString: base.deletingLastPathComponent().lastPathComponent) != nil
            && FileManager().fileExists(atPath: base.deletingLastPathComponent().appendingPathComponent("reservation.json").path))
        root = base.appendingPathComponent(UUID().uuidString); parent = root.appendingPathComponent("Items")
        journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true)
    }
    func file(_ name: String, text: String = "generated") throws -> URL {
        let url = parent.appendingPathComponent(name); try Data(text.utf8).write(to: url, options: .withoutOverwriting); return url
    }
    func engine(_ hooks: RecoveryHooks = .init(), activity: (@Sendable () throws -> any Sendable)? = nil) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks, activity: activity)
    }
    func plan(_ engine: RecoverableFileOperations, _ sources: [URL]) async throws -> TransferPlan {
        try await engine.prepareTransfer(sources: sources, destinationDirectory: parent, move: false,
            observing: engine.observeSelection(sources))
    }
    func choices(_ plan: TransferPlan) -> [UUID: TransferConflictResolution] {
        Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .keepBoth) })
    }
}

private final class DuplicateCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
private func waitForDuplicate(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_DUPLICATE_TEST_ROOT"] != nil))
struct DuplicateTests {
    @Test func peersKeepNumberedNamesExtensionsPackagesUnicodeAndColdUndo() async throws {
        let f = try DuplicateFixture(), engine = f.engine()
        let first = try f.file("Café 日本語.txt"), second = try f.file("Café 日本語 (1).txt", text: "existing")
        let folder = f.parent.appendingPathComponent("Photos"), package = f.parent.appendingPathComponent("Example.app")
        for url in [folder, package] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: url.appendingPathComponent("Nested"))
        }
        let plan = try await f.plan(engine, [first, second, folder, package])
        #expect(plan.conflicts.count == 4 && plan.conflicts.allSatisfy { !$0.canMerge && !$0.canReplace })
        let result = await engine.perform(plan, resolutions: f.choices(plan))
        #expect(result.result.disposition == .succeeded)
        #expect(result.result.items.compactMap(\.destination?.lastPathComponent) == ["Café 日本語 (2).txt", "Café 日本語 (1) (1).txt", "Photos (1)", "Example (1).app"])
        #expect(try String(contentsOf: first, encoding: .utf8) == "generated")
        #expect(try String(contentsOf: second, encoding: .utf8) == "existing")
        #expect(try await f.engine().inspectExistingHistory().records.count == 1)
        #expect(await f.engine().undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(Set(try FileManager().contentsOfDirectory(atPath: f.parent.path).filter { !$0.hasPrefix(".mac-explorer-recovery-") }) == Set([first.lastPathComponent, second.lastPathComponent, "Photos", "Example.app"]))
    }
    @Test func changedSelectionAndOccupiedPublicationNeverOverwrite() async throws {
        let f = try DuplicateFixture(), engine = f.engine(), source = try f.file("Report.txt")
        let stale = try await f.plan(engine, [source])
        try Data("changed".utf8).write(to: source)
        let refused = await engine.perform(stale, resolutions: f.choices(stale))
        #expect(refused.result.disposition != .succeeded && refused.recordID == nil)
        let raced = try DuplicateFixture(), item = try raced.file("Report.txt")
        var hooks = RecoveryHooks()
        hooks.beforeCommit = { try! Data("new occupant".utf8).write(to: raced.parent.appendingPathComponent("Report (1).txt"), options: .withoutOverwriting) }
        let service = raced.engine(hooks), plan = try await raced.plan(service, [item])
        let result = await service.perform(plan, resolutions: raced.choices(plan))
        #expect(result.result.disposition != .succeeded)
        #expect(try String(contentsOf: raced.parent.appendingPathComponent("Report (1).txt"), encoding: .utf8) == "new occupant")
        #expect(try String(contentsOf: item, encoding: .utf8) == "generated")
    }
    @Test func editedDuplicateMakesUndoRefuseAndOriginalSurvives() async throws {
        let f = try DuplicateFixture(), engine = f.engine(), source = try f.file("Original.txt")
        let plan = try await f.plan(engine, [source]), result = await engine.perform(plan, resolutions: f.choices(plan))
        let copied = try #require(result.result.items.first?.destination)
        try Data("later edit".utf8).write(to: copied)
        #expect(await f.engine().undo(recordID: try #require(result.recordID)).result.disposition != .succeeded)
        #expect(try String(contentsOf: copied, encoding: .utf8) == "later edit")
        #expect(try String(contentsOf: source, encoding: .utf8) == "generated")
    }
    @Test func repeatedCommandsAllocateFreshSiblingsAndDoNotFollowSourceLink() async throws {
        let f = try DuplicateFixture(), engine = f.engine(), source = try f.file("Original.txt")
        let link = f.parent.appendingPathComponent("Alias")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: source)
        var records: [UUID] = []
        for _ in 1...3 {
            let plan = try await f.plan(engine, [source, link]), result = await engine.perform(plan, resolutions: f.choices(plan))
            #expect(result.result.disposition == .succeeded); records.append(try #require(result.recordID))
        }
        #expect(try FileManager().destinationOfSymbolicLink(atPath: f.parent.appendingPathComponent("Alias (3)").path) == source.path)
        for id in records.reversed() { #expect(await engine.undo(recordID: id).result.disposition == .succeeded) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "generated")
    }
    @Test func stopAfterCommittedFirstItemRetainsOriginalsAndExactPartialUndo() async throws {
        let f = try DuplicateFixture(), a = try f.file("A"), b = try f.file("B"), barrier = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0), count = DuplicateCounter()
        var hooks = RecoveryHooks(); hooks.afterRename = { if count.next() == 1 { entered.signal(); barrier.wait() } }
        let engine = f.engine(hooks), plan = try await f.plan(engine, [a, b])
        let task = Task { await engine.perform(plan, resolutions: f.choices(plan)) }
        #expect(await Task.detached { waitForDuplicate(entered) }.value)
        task.cancel(); barrier.signal()
        let result = await task.value
        #expect(result.result.cancellationRequested && result.result.items.filter { $0.status == .succeeded }.count == 1)
        #expect(try String(contentsOf: a, encoding: .utf8) == "generated" && String(contentsOf: b, encoding: .utf8) == "generated")
        #expect(await f.engine().undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: f.parent.appendingPathComponent("A (1)").path))
    }
    @Test func parentRenameAndProtectedHistoryRefuse() async throws {
        let f = try DuplicateFixture(), engine = f.engine(), item = try f.file("A")
        let plan = try await f.plan(engine, [item])
        try FileManager().moveItem(at: f.parent, to: f.root.appendingPathComponent("Moved"))
        #expect(await engine.perform(plan, resolutions: f.choices(plan)).result.disposition != .succeeded)
        let protected = try DuplicateFixture(), forbidden = try protected.file("History")
        let guarded = RecoverableFileOperations(journalDirectory: protected.journal, protecting: [forbidden])
        await #expect(throws: (any Error).self) { try await protected.plan(guarded, [forbidden]) }
    }
}
