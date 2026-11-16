import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import LocalStorage

struct TARReaderTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = [(UInt64, Int)](), mainThread = false, held = false
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        init(holdFirstRead: Bool = false) { held = holdFirstRead }
        func probe(_ stage: TARArchiveReader.Stage, _ offset: UInt64, _ count: Int) throws {
            let pause = lock.withLock {
                mainThread = mainThread || Thread.isMainThread
                guard case .metadata = stage else { return false }
                reads.append((offset, count))
                if held { held = false; return true }
                return false
            }
            if pause {
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw TARArchiveFailure.unavailable }
            }
        }
        var observations: (reads: [(UInt64, Int)], mainThread: Bool) { lock.withLock { (reads, mainThread) } }
        func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    }
    private actor QueryGate {
        private var waiting = false
        private var start: CheckedContinuation<Void, Never>?, release: CheckedContinuation<Void, Never>?
        func wait() async {
            waiting = true; start?.resume(); start = nil
            await withCheckedContinuation { release = $0 }
        }
        func awaitStart() async {
            if !waiting { await withCheckedContinuation { start = $0 } }
        }
        func resume() { release?.resume(); release = nil }
    }

    @Test func metadataOnlyOffMainReaderAndSessionContracts() async throws {
        let bytes = try TARReaderTestFixture.bytes(), source = try TARReaderTestFixture.write(bytes)
        let activity = FileActivityGate(), trace = Trace()
        let reader = TARArchiveReader(activity: activity, probe: trace.probe)
        let session = try await reader.open(source)
        #expect(activity.activeCount == 0)
        #expect(session.summary.files == 4 && session.summary.folders == 2 && session.summary.logicalBytes == 65_592)
        let facts = trace.observations
        #expect(!facts.mainThread && !facts.reads.isEmpty)
        #expect(facts.reads.reduce(0) { $0 + $1.1 } == session.summary.metadataBytes)
        for (offset, count) in facts.reads {
            for row in TARReaderTestFixture.rows(.ustar) where row.kind == "file" && row.bytes > 0 {
                #expect(offset + UInt64(count) <= row.dataOffset || offset >= row.dataOffset + row.bytes)
            }
        }
        let first = try await session.page(in: session.root)
        #expect(first.items.map(\.name) == ["Folder", "Note.txt"])
        #expect(first.breadcrumbs.count == 1 && !first.hasNext)
        let folder = try #require(first.items.first)
        let folderID = try #require(folder.folder)
        let children = try await session.page(in: folderID)
        #expect(children.items.count == 4 && children.items.first?.name == "Empty")
        #expect(children.breadcrumbs.count == 2)
        let found = try await session.searchNames("nOtE")
        #expect(found.items.map(\.path) == ["Note.txt"])
        for field in TARArchiveOrder.Field.allCases {
            for descending in [false, true] {
                let page = try await session.page(in: session.root, sorting: .init(field, descending: descending))
                #expect(Set(page.items.map(\.id)) == Set(first.items.map(\.id)))
                #expect(page.items.first?.folder != nil)
            }
        }
        let member = try #require(children.items.first { $0.name == "Member.bin" })
        let selection = try await session.selectionForExtraction([folder.id, member.id])
        #expect(selection.count == 1 && selection.displayNames == ["Folder"])
        #expect(!selection.description.contains(source.path))
        let location = try await session.location(of: member.id)
        let located = try await session.page(in: location.folder, offset: location.offset)
        #expect(location.folder == folderID && location.offset == 0)
        #expect(located.items.contains { $0.id == member.id })

        let foreign = try await TARArchiveReader().open(source)
        await #expect(throws: TARArchiveFailure.invalidSelection) { _ = try await foreign.page(in: session.root) }
        await #expect(throws: TARArchiveFailure.invalidSelection) { _ = try await foreign.selectionForExtraction([member.id]) }
        await #expect(throws: TARArchiveFailure.limited) { _ = try await session.page(in: session.root, offset: -1) }
        await #expect(throws: TARArchiveFailure.limited) { _ = try await session.searchNames(String(repeating: "x", count: 129)) }
        let end = try await session.page(in: session.root, offset: Int.max)
        #expect(end.items.isEmpty && end.offset == 2)
        let gate = QueryGate()
        let query = Task { await gate.wait(); return try await session.searchNames("member") }
        await gate.awaitStart(); query.cancel(); await gate.resume()
        await #expect(throws: CancellationError.self) { _ = try await query.value }
        await foreign.close(); await session.close()
        await #expect(throws: TARArchiveFailure.closed) { _ = try await session.page(in: session.root) }
        await reader.drain()
        #expect(activity.activeCount == 0)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func largeCatalogPaginatesWithoutDuplicateIdentities() async throws {
        var bytes = Data()
        for index in 0..<19_999 {
            bytes += try TARReaderTestFixture.member(String(format: "f%05d.txt", index), body: Data())
        }
        let source = try TARReaderTestFixture.write(TARReaderTestFixture.terminated(bytes))
        let session = try await TARArchiveReader().open(source)
        var offset = 0, seen = Set<TARItemID>()
        while true {
            let page = try await session.page(in: session.root, offset: offset)
            #expect(page.items.count <= 256 && page.offset == offset && page.total == 19_999)
            for item in page.items { #expect(seen.insert(item.id).inserted) }
            offset += page.items.count
            if !page.hasNext { break }
            try #require(!page.items.isEmpty)
        }
        #expect(seen.count == 19_999)
        await session.close()
    }

    @Test func linksAndSpecialEntriesCannotAuthorizeExtraction() async throws {
        let source = try TARReaderTestFixture.write(TARReaderTestFixture.bytes(.rootAndLinks))
        let session = try await TARArchiveReader().open(source)
        let page = try await session.page(in: session.root)
        #expect(session.summary.blockedMembers == 3)
        for item in page.items where item.kind != .file && item.kind != .directory {
            await #expect(throws: TARArchiveFailure.unsupported) { _ = try await session.selectionForExtraction([item.id]) }
        }
        await session.close()
    }

    private final class Held: Sendable {}
    private final class WeakHeld: @unchecked Sendable { weak var value: Held?; init(_ value: Held) { self.value = value } }
    @Test func cancellationKeepsAccessAndActivityUntilNativeReadDrainsThenReaderReopens() async throws {
        let source = try TARReaderTestFixture.write(TARReaderTestFixture.bytes())
        let trace = Trace(holdFirstRead: true), activity = FileActivityGate()
        let reader = TARArchiveReader(activity: activity, probe: trace.probe)
        var retained: Held? = Held()
        let weak = WeakHeld(try #require(retained))
        var operation: Task<TARArchiveSession, Error>? = Task { [lifetime = retained!] in
            try await reader.open(source, retaining: lifetime)
        }
        retained = nil
        let entered = await Task.detached { trace.waitForEntry() }.value
        defer { trace.release.signal() }
        try #require(entered)
        #expect(activity.activeCount == 1 && weak.value != nil)
        await #expect(throws: TARArchiveFailure.busy) { _ = try await reader.open(source) }
        let token = try #require(activity.closeAdmission())
        operation?.cancel()
        #expect(activity.activeCount == 1 && !activity.ownsDrainedAdmission(token))
        trace.release.signal()
        if let active = operation {
            await #expect(throws: TARArchiveFailure.stopped) { _ = try await active.value }
        }
        operation = nil
        await reader.drain()
        #expect(weak.value == nil)
        #expect(await activity.waitUntilDrained(token))
        #expect(activity.activeCount == 0)
        #expect(activity.reopen(token))
        let reopened = try await reader.open(source)
        await reopened.close(); await reader.drain()
    }

    @Test func changedExcludedSymlinkedCompressedAndExpiredSourcesRefuse() async throws {
        let source = try TARReaderTestFixture.write(TARReaderTestFixture.bytes())
        let reader = TARArchiveReader(probe: { stage, _, _ in
            if case .parsed = stage {
                guard chmod(source.path, 0o640) == 0 else { throw TARArchiveFailure.unavailable }
            }
        })
        await #expect(throws: TARArchiveFailure.changed) { _ = try await reader.open(source) }
        let link = source.deletingLastPathComponent().appendingPathComponent("Link.tar")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: TARArchiveFailure.unavailable) { _ = try await TARArchiveReader().open(link) }
        let excluded = TARArchiveReader(excludedRoots: [source.deletingLastPathComponent()])
        await #expect(throws: TARArchiveFailure.unavailable) { _ = try await excluded.open(source) }
        let compressed = source.deletingLastPathComponent().appendingPathComponent("Compressed.tar.gz")
        try (Data([0x1f, 0x8b]) + Data(repeating: 0, count: 8)).write(to: compressed, options: .withoutOverwriting)
        await #expect(throws: TARArchiveFailure.compressed) { _ = try await TARArchiveReader().open(compressed) }
        var limits = TARReadLimits(); limits.seconds = 0
        let expired = TARArchiveReader(limits: limits, probe: { _, _, _ in })
        await #expect(throws: TARArchiveFailure.limited) { _ = try await expired.open(source) }
    }
}
