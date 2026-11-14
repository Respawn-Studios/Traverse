import Foundation
import Testing
import ExplorerCore
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

private struct SelectedZIPFixture {
    let root: URL, source: URL, parent: URL, journal: URL
    static let members: [GeneratedZIP.Member] = [.init("Alpha/Keep.txt"), .init("Alpha/Deep/Nested.txt"),
        .init("Alpha/Empty/", mode: 0x4000, bytes: Data()), .init("Other.txt"), .init("Alphabet/Ignore.txt"),
        .init("Empty/", mode: 0x4000, bytes: Data())]
    init(_ bytes: Data = GeneratedZIP.bytes(members)) throws {
        let admitted = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_SELECTED_TEST_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(admitted.lastPathComponent == "source" && admitted.resolvingSymlinksInPath() == admitted
            && admitted.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-selected-extraction")
            && UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil
            && FileManager().fileExists(atPath: admitted.deletingLastPathComponent().appendingPathComponent("reservation.json").path))
        root = admitted.appendingPathComponent(UUID().uuidString); source = root.appendingPathComponent("Generated.zip")
        parent = root.appendingPathComponent("Destination"); journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true)
        try bytes.write(to: source, options: .withoutOverwriting)
    }
    func engine() -> RecoverableFileOperations { .init(journalDirectory: journal) }
    func selection(_ session: ZIPArchiveSession, _ paths: Set<String>) async throws -> ZIPExtractionSelection {
        var pending = [session.root], ids = Set<ZIPItemID>()
        while let folder = pending.popLast() {
            let page = try await session.page(in: folder)
            for item in page.items {
                if paths.contains(item.path) { ids.insert(item.id) }
                if let child = item.folder { pending.append(child) }
            }
        }
        #expect(ids.count == paths.count)
        return try await session.selectionForExtraction(ids)
    }
    func plan(_ engine: RecoverableFileOperations, _ selected: ZIPExtractionSelection, name: String = "Extracted") async throws -> ArchiveExtractionPlan {
        try await engine.prepareZIPExtraction(source: source, parent: parent, name: name,
            observing: engine.observeSelection([source]), members: selected)
    }
}
private final class SelectedZIPBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var used = false
    func once() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_SELECTED_TEST_ROOT"] != nil))
struct ZIPSelectedExtractionTests {
    @Test func selectedProductionStopRetainsActualLeaseUntilWriteWorkerExits() async throws {
        let f = try SelectedZIPFixture(), session = try await ZIPArchiveReader().open(f.source)
        let selected = try await f.selection(session, ["Alpha"]), gate = FileActivityGate(), barrier = SelectedZIPBarrier()
        let engine = RecoverableFileOperations(journalDirectory: f.journal, activity: { try gate.begin() })
        let hooks = ZIPProductionHooks(beforeWrite: { _ in if barrier.once() { barrier.entered.signal(); barrier.release.wait() } })
        let plan = try await engine.prepareArchiveExtraction(source: f.source, parent: f.parent, name: "Selected Stop",
            observing: engine.observeSelection([f.source])) { check in
                try PreparedZIPDirectory(f.source, selection: selected, check: check, hooks: hooks)
            }
        let task = Task { await engine.performArchiveExtraction(plan) }
        #expect(await Task.detached { barrier.wait() }.value)
        task.cancel()
        #expect(gate.activeCount == 1)
        barrier.release.signal(); let result = await task.value
        #expect(result.result.cancellationRequested && result.result.disposition != .succeeded && gate.activeCount == 0)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        #expect(try await engine.inspectExistingHistory().records.count == 1)
        await session.close()
    }
    @Test func nestedFilePreservesOnlyItsAncestorsAndHasColdUndo() async throws {
        let f = try SelectedZIPFixture(), sourceBytes = try Data(contentsOf: f.source), session = try await ZIPArchiveReader().open(f.source)
        let selected = try await f.selection(session, ["Alpha/Deep/Nested.txt"]), engine = f.engine()
        let plan = try await f.plan(engine, selected)
        #expect(selected.count == 1 && selected.displayNames == ["Alpha/Deep/Nested.txt"])
        #expect(plan.files == 1 && plan.folders == 2 && plan.logicalBytes == 9)
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(try String(contentsOf: plan.destination.appendingPathComponent("Alpha/Deep/Nested.txt"), encoding: .utf8) == "generated")
        #expect(!FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Alpha/Keep.txt").path))
        #expect(!FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Other.txt").path))
        #expect(await f.engine().undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        #expect(try Data(contentsOf: f.source) == sourceBytes)
        await session.close()
    }
    @Test func selectedParentSubsumesChildAndDoesNotMatchSimilarSibling() async throws {
        let f = try SelectedZIPFixture(), session = try await ZIPArchiveReader().open(f.source)
        let selected = try await f.selection(session, ["Alpha", "Alpha/Keep.txt"]), engine = f.engine()
        #expect(selected.count == 1 && selected.displayNames == ["Alpha"])
        let plan = try await f.plan(engine, selected), result = await engine.performArchiveExtraction(plan)
        #expect(plan.files == 2 && plan.folders == 3 && result.result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Alpha/Empty").path))
        #expect(!FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Alphabet").path))
        await session.close()
    }
    @Test func disjointNestedAndEmptySelectionsHaveExactFolderTotals() async throws {
        let f = try SelectedZIPFixture(), session = try await ZIPArchiveReader().open(f.source)
        let chosen = try await f.selection(session, ["Alpha/Deep/Nested.txt", "Empty"]), engine = f.engine()
        let plan = try await f.plan(engine, chosen)
        #expect(chosen.count == 2 && plan.files == 1 && plan.folders == 3)
        #expect(await engine.performArchiveExtraction(plan).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Empty").path))
        await session.close()
    }
    @Test func otherSessionClosedUnboundAndForgedSelectionsRefuse() async throws {
        let f = try SelectedZIPFixture(), reader = ZIPArchiveReader(), a = try await reader.open(f.source), b = try await reader.open(f.source)
        let item = try #require(try await a.page(in: a.root).items.first)
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await b.selectionForExtraction([item.id]) }
        let unbound = ZIPArchiveSession(try GeneratedZIP.parse(Data(contentsOf: f.source)))
        let unboundItem = try #require(try await unbound.page(in: unbound.root).items.first)
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await unbound.selectionForExtraction([unboundItem.id]) }
        let valid = try await f.selection(a, ["Other.txt"])
        let forged = ZIPExtractionSelection(source: valid.source, stamp: valid.stamp, roots: [.init(path: "../escape", kind: .file)])
        await #expect(throws: (any Error).self) { try await f.plan(f.engine(), forged) }
        let wrongKind = ZIPExtractionSelection(source: valid.source, stamp: valid.stamp, roots: [.init(path: "Other.txt", kind: .directory)])
        await #expect(throws: (any Error).self) { try await f.plan(f.engine(), wrongKind) }
        await a.close()
        await #expect(throws: ZIPArchiveFailure.closed) { try await a.selectionForExtraction([item.id]) }
        await b.close(); await unbound.close()
        #expect(!FileManager().fileExists(atPath: f.journal.path))
    }
    @Test func replacedChangedAndWrongSourceTokensCannotRenewConsent() async throws {
        for replacement in [true, false] {
            let f = try SelectedZIPFixture(), session = try await ZIPArchiveReader().open(f.source), selected = try await f.selection(session, ["Other.txt"])
            var changed = try Data(contentsOf: f.source); changed[35] ^= 1
            if replacement {
                try FileManager().moveItem(at: f.source, to: f.root.appendingPathComponent("Retained.zip"))
                try changed.write(to: f.source, options: .withoutOverwriting)
            } else { try changed.write(to: f.source) }
            await #expect(throws: FileOperationFailure.sourceChanged) { try await f.plan(f.engine(), selected) }
            #expect(!FileManager().fileExists(atPath: f.journal.path)); await session.close()
        }
        let first = try SelectedZIPFixture(), second = try SelectedZIPFixture(), session = try await ZIPArchiveReader().open(first.source)
        let selected = try await first.selection(session, ["Other.txt"])
        await #expect(throws: FileOperationFailure.sourceChanged) { try await second.plan(second.engine(), selected) }
        await session.close()
    }
    @Test func unselectedBodyIsNotDecodedButEveryStructuralRecordIsChecked() async throws {
        let sentinel = Data("unique-unselected-payload".utf8)
        var bytes = GeneratedZIP.bytes([.init("Keep.txt"), .init("Omit.bin", bytes: sentinel)])
        bytes[try #require(bytes.range(of: sentinel)).lowerBound] ^= 1
        let f = try SelectedZIPFixture(bytes), session = try await ZIPArchiveReader().open(f.source), selected = try await f.selection(session, ["Keep.txt"])
        let engine = f.engine(), plan = try await f.plan(engine, selected)
        #expect(await engine.performArchiveExtraction(plan).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Omit.bin").path))
        #expect(throws: (any Error).self) { try ContentZIP.verify(bytes) }
        await session.close()
        var unsupported = GeneratedZIP.Member("Unsupported.bin"); unsupported.method = 99
        let bad = try SelectedZIPFixture(GeneratedZIP.bytes([.init("Keep.txt"), unsupported]))
        let badSession = try await ZIPArchiveReader().open(bad.source), good = try await bad.selection(badSession, ["Keep.txt"])
        await #expect(throws: (any Error).self) { try await bad.plan(bad.engine(), good) }
        #expect(!FileManager().fileExists(atPath: bad.journal.path)); await badSession.close()
    }
}
