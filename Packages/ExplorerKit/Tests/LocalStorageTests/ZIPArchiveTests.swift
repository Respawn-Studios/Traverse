import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import LocalStorage

@Test func contentCheckUsesTheExactListedArchiveAndRefusesClosedCatalogs() async throws {
    let root = try LocalStorageTestFixtures.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Generated.zip")
    let before = GeneratedZIP.bytes([.init("Before.txt", bytes: Data("before".utf8))])
    try before.write(to: source, options: .withoutOverwriting)
    let reader = ZIPArchiveReader(), session = try await reader.open(source)
    let result = try await reader.checkContents(in: session)
    #expect(result.files == 1 && result.decodedBytes == 6)
    #expect(try Data(contentsOf: source) == before)
    try GeneratedZIP.bytes([.init("After.txt", bytes: Data("after".utf8))]).write(to: source, options: .atomic)
    enum UnexpectedRead: Error { case bytes }
    let noRead = ZIPArchiveReader(probe: { stage in if stage == .read { throw UnexpectedRead.bytes } })
    await #expect(throws: ZIPArchiveFailure.changed) { try await noRead.checkContents(in: session) }
    await session.close()
    await #expect(throws: ZIPArchiveFailure.closed) { try await noRead.checkContents(in: session) }
    let fresh = try await reader.open(source)
    #expect(try await reader.checkContents(in: fresh).decodedBytes == 5)
    await fresh.close(); await reader.drain(); await noRead.drain()
}

@Test func retainedZIPCatalogDetectsReplacementBeforeBorrowingRows() async throws {
    let root = try LocalStorageTestFixtures.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Generated.zip")
    try GeneratedZIP.bytes([.init("Before.txt")]).write(to: source, options: .withoutOverwriting)
    let reader = ZIPArchiveReader()
    let old = try await reader.open(source)
    #expect(await old.matchesCurrentSourceObservation())
    try GeneratedZIP.bytes([.init("After.txt")]).write(to: source, options: .atomic)
    #expect(await !old.matchesCurrentSourceObservation())
    let fresh = try await reader.open(source)
    #expect(await fresh.matchesCurrentSourceObservation())
    #expect(try await fresh.page(in: fresh.root).items.map(\.name) == ["After.txt"])
    try FileManager.default.removeItem(at: source)
    #expect(await !fresh.matchesCurrentSourceObservation())
    await old.close(); await fresh.close(); await reader.drain()
    #expect(await !old.matchesCurrentSourceObservation())
}

enum GeneratedZIP {
    struct Member {
        var name: Data
        var flags: UInt16 = 0x0800
        var method: UInt16 = 0
        var dosDate: UInt16 = 0, dosTime: UInt16 = 0
        var creator: UInt16 = 0x0314
        var mode: UInt16 = 0x8000
        var bytes = Data("generated".utf8)
        var packed: Data?
        var extra = Data()
        var centralExtra: Data?
        var comment = Data()
        init(_ name: String, mode: UInt16 = 0x8000, bytes: Data = Data("generated".utf8)) {
            self.name = Data(name.utf8); self.mode = mode; self.bytes = bytes
        }
    }
    static func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ count: Int) { data.replaceSubrange(offset..<(offset + count), with: le(value, count)) }
    static func bytes(_ members: [Member], comment: Data = Data(), zip64: Bool = false) -> Data {
        var local = Data(), central = Data()
        for member in members {
            let payload = member.packed ?? member.bytes
            let centralExtra = member.centralExtra ?? member.extra
            var head = Data(repeating: 0, count: 30), entry = Data(repeating: 0, count: 46)
            put(&head, 0, 0x04034b50, 4); put(&head, 4, 20, 2); put(&head, 6, UInt64(member.flags), 2)
            put(&head, 8, UInt64(member.method), 2); put(&head, 14, UInt64(ZIPMetadataParser.crc32(member.bytes)), 4)
            put(&head, 10, UInt64(member.dosTime), 2); put(&head, 12, UInt64(member.dosDate), 2)
            put(&head, 18, UInt64(payload.count), 4); put(&head, 22, UInt64(member.bytes.count), 4)
            put(&head, 26, UInt64(member.name.count), 2); put(&head, 28, UInt64(member.extra.count), 2)
            put(&entry, 0, 0x02014b50, 4); put(&entry, 4, UInt64(member.creator), 2); put(&entry, 6, 20, 2)
            put(&entry, 8, UInt64(member.flags), 2); put(&entry, 10, UInt64(member.method), 2)
            put(&entry, 12, UInt64(member.dosTime), 2); put(&entry, 14, UInt64(member.dosDate), 2)
            put(&entry, 16, UInt64(ZIPMetadataParser.crc32(member.bytes)), 4)
            put(&entry, 20, UInt64(payload.count), 4); put(&entry, 24, UInt64(member.bytes.count), 4)
            put(&entry, 28, UInt64(member.name.count), 2); put(&entry, 30, UInt64(centralExtra.count), 2)
            put(&entry, 32, UInt64(member.comment.count), 2)
            put(&entry, 38, UInt64(member.mode) << 16, 4); put(&entry, 42, UInt64(local.count), 4)
            central += entry; central += member.name; central += centralExtra; central += member.comment
            local += head; local += member.name; local += member.extra; local += payload
        }
        let centralOffset = local.count
        local += central
        if zip64 {
            var record = Data(repeating: 0, count: 56), locator = Data(repeating: 0, count: 20)
            put(&record, 0, 0x06064b50, 4); put(&record, 4, 44, 8); put(&record, 12, 45, 2); put(&record, 14, 45, 2)
            put(&record, 24, UInt64(members.count), 8); put(&record, 32, UInt64(members.count), 8)
            put(&record, 40, UInt64(central.count), 8); put(&record, 48, UInt64(centralOffset), 8)
            put(&locator, 0, 0x07064b50, 4); put(&locator, 8, UInt64(local.count), 8); put(&locator, 16, 1, 4)
            local += record; local += locator
        }
        var end = Data(repeating: 0, count: 22)
        put(&end, 0, 0x06054b50, 4); put(&end, 8, zip64 ? 65_535 : UInt64(members.count), 2)
        put(&end, 10, zip64 ? 65_535 : UInt64(members.count), 2); put(&end, 12, zip64 ? UInt64(UInt32.max) : UInt64(central.count), 4)
        put(&end, 16, zip64 ? UInt64(UInt32.max) : UInt64(centralOffset), 4); put(&end, 20, UInt64(comment.count), 2)
        return local + end + comment
    }
    static func parse(_ bytes: Data, limits: ZIPReadLimits = .init(), cancelled: () -> Bool = { false }) throws -> ZIPCatalogStorage {
        try ZIPMetadataParser.parse(length: UInt64(bytes.count), limits: limits, cancelled: cancelled) { offset, count in
            guard offset <= bytes.count, UInt64(count) <= UInt64(bytes.count) - offset else { throw ZIPArchiveFailure.malformed }
            return Data(bytes[Int(offset)..<(Int(offset) + count)])
        }
    }
}

@Suite struct ZIPArchiveTests {
    @Test func modificationDatesUseRecordedPrecisionWithoutGuessingTimeZones() async throws {
        var local = GeneratedZIP.Member("Leap Day"), unix = GeneratedZIP.Member("Before Epoch")
        var ntfs = GeneratedZIP.Member("NTFS"), invalid = GeneratedZIP.Member("Invalid Day")
        local.dosDate = (2024 - 1980) << 9 | 2 << 5 | 29
        local.dosTime = 13 << 11 | 34 << 5 | 28
        invalid.dosDate = (2023 - 1980) << 9 | 2 << 5 | 29
        let ut = GeneratedZIP.le(0x5455, 2) + GeneratedZIP.le(5, 2) + Data([1])
        unix.extra = ut + GeneratedZIP.le(UInt64(UInt32(bitPattern: -10)), 4)
        let ticks: UInt64 = (11_644_473_600 + 1_709_213_696) * 10_000_000 + 2_500_000
        ntfs.extra = GeneratedZIP.le(0x000a, 2) + GeneratedZIP.le(32, 2)
            + Data(repeating: 0, count: 4) + GeneratedZIP.le(1, 2) + GeneratedZIP.le(24, 2)
            + GeneratedZIP.le(ticks, 8) + Data(repeating: 0, count: 16)
        let catalog = ZIPArchiveSession(try GeneratedZIP.parse(GeneratedZIP.bytes([local, unix, invalid, ntfs])))
        let ascending = try await catalog.page(in: catalog.root, sorting: .init(.modified)).items
        #expect(ascending.map(\.name) == ["Before Epoch", "Leap Day", "NTFS", "Invalid Day"])
        #expect(ascending[0].modification?.date.timeIntervalSince1970 == -10)
        #expect(ascending[1].modification?.date.timeIntervalSince1970 == 1_709_213_696 && ascending[1].modification?.hasTimeZone == false)
        #expect(ascending[2].modification?.date.timeIntervalSince1970 == 1_709_213_696.25 && ascending[2].modification?.hasTimeZone == true)
        #expect(ascending[3].modification == nil)
        let descending = try await catalog.page(in: catalog.root, sorting: .init(.modified, descending: true)).items
        #expect(descending.map(\.name) == ["NTFS", "Leap Day", "Before Epoch", "Invalid Day"])
        await catalog.close()
    }

    @Test func hierarchyTotalsPagingAndOpaqueFolderLifetime() async throws {
        let data = GeneratedZIP.bytes([.init("folder/File 10.txt"), .init("folder/File 2.txt"),
            .init("folder/", mode: 0x4000, bytes: Data()), .init("Root.txt")])
        let storage = try GeneratedZIP.parse(data), catalog = ZIPArchiveSession(storage)
        #expect(catalog.summary.records == 4 && catalog.summary.files == 3 && catalog.summary.folders == 1)
        #expect(catalog.summary.logicalBytes == 27)
        let root = try await catalog.page(in: catalog.root)
        #expect(root.items.map(\.name) == ["folder", "Root.txt"] && root.items[0].logicalBytes == 18)
        let folder = try #require(root.items[0].folder), page = try await catalog.page(in: folder)
        #expect(page.items.map(\.name) == ["File 2.txt", "File 10.txt"])
        #expect(page.items[0].path == "folder/File 2.txt" && page.breadcrumbs.count == 2)
        #expect(try await catalog.page(in: folder, filter: "10").items.map(\.name) == ["File 10.txt"])
        await #expect(throws: ZIPArchiveFailure.invalidFilter) { try await catalog.page(in: folder, filter: String(repeating: "x", count: 129)) }
        let other = ZIPArchiveSession(storage)
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await other.page(in: folder) }
        await catalog.close()
        await #expect(throws: ZIPArchiveFailure.closed) { try await catalog.page(in: catalog.root) }
        await other.close()
    }
    @Test func emptyMaximumCommentsAndAmbiguousEndSignatures() throws {
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([])).summary.records == 0)
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([.init("one")], comment: Data(repeating: 65, count: 65_535))).summary.files == 1)
        let fake = GeneratedZIP.bytes([])
        #expect(throws: ZIPArchiveFailure.malformed) { try GeneratedZIP.parse(GeneratedZIP.bytes([.init("one")], comment: fake)) }
        #expect(throws: ZIPArchiveFailure.malformed) { try GeneratedZIP.parse(Data(repeating: 0, count: 21)) }
    }
    @Test func unsafeAndAmbiguousNamesNeverBecomeHierarchyEntries() throws {
        for name in ["../escape", "/absolute", "a/../b", "a/./b", "a//b", "a\\b", "C:drive", "a\0b", "a\nb", "a\u{202e}b"] {
            #expect(throws: ZIPArchiveFailure.unsafeName) { try GeneratedZIP.parse(GeneratedZIP.bytes([.init(name)])) }
        }
        for names in [["same", "same"], ["file", "file/child"], ["café/a", "cafe\u{301}/b"]] {
            #expect(throws: ZIPArchiveFailure.ambiguousNames) { try GeneratedZIP.parse(GeneratedZIP.bytes(names.map { .init($0) })) }
        }
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([.init("A"), .init("a")])).summary.caseConflicts == 1)
    }
    @Test func encodingPrecedenceAndChecksumAreExplicit() throws {
        var legacy = GeneratedZIP.Member("unused"); legacy.flags = 0; legacy.name = Data([0x63, 0x61, 0x66, 0x82])
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([legacy])).nodes[1].name == "café")
        let unicode = Data([1]) + GeneratedZIP.le(UInt64(ZIPMetadataParser.crc32(legacy.name)), 4) + Data("日本語.txt".utf8)
        legacy.extra = GeneratedZIP.le(0x7075, 2) + GeneratedZIP.le(UInt64(unicode.count), 2) + unicode
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([legacy])).nodes[1].name == "日本語.txt")
        legacy.extra[5] ^= 1
        #expect(try GeneratedZIP.parse(GeneratedZIP.bytes([legacy])).nodes[1].name == "café")
        legacy.flags = 0x0800
        #expect(throws: ZIPArchiveFailure.unsupportedEncoding) { try GeneratedZIP.parse(GeneratedZIP.bytes([legacy])) }
        #expect(ZIPMetadataParser.crc32(Data("123456789".utf8)) == 0xcbf43926)
    }
    @Test func sizeCountDepthNodeAndCancellationGatesAreBounded() throws {
        let normal = GeneratedZIP.bytes([.init("a/b/c"), .init("second")])
        var limits = ZIPReadLimits(); limits.members = 1
        #expect(throws: ZIPArchiveFailure.limited) { try GeneratedZIP.parse(normal, limits: limits) }
        limits = .init(); limits.nodes = 3
        #expect(throws: ZIPArchiveFailure.limited) { try GeneratedZIP.parse(normal, limits: limits) }
        limits = .init(); limits.depth = 2
        #expect(throws: ZIPArchiveFailure.limited) { try GeneratedZIP.parse(normal, limits: limits) }
        limits = .init(); limits.nameBytes = 2
        #expect(throws: ZIPArchiveFailure.limited) { try GeneratedZIP.parse(normal, limits: limits) }
        #expect(throws: ZIPArchiveFailure.stopped) { try GeneratedZIP.parse(normal, cancelled: { true }) }
    }
    @Test func zip64AndMemberCapabilityFactsDoNotReadPayloads() throws {
        var encrypted = GeneratedZIP.Member("locked"); encrypted.flags |= 1; encrypted.method = 99
        let source = GeneratedZIP.bytes([encrypted, .init("link", mode: 0xa000), .init("special", mode: 0x1000)], zip64: true)
        let parsed = try GeneratedZIP.parse(source)
        #expect(parsed.summary.isZIP64 && parsed.summary.encryptedMembers == 1 && parsed.summary.symbolicLinks == 1 && parsed.summary.specialMembers == 1)
        var mismatched = source; GeneratedZIP.put(&mismatched, source.count - 22 + 12, 1, 4)
        #expect(throws: ZIPArchiveFailure.malformed) { try GeneratedZIP.parse(mismatched) }
        var split = source; GeneratedZIP.put(&split, source.count - 22 + 4, 1, 2)
        #expect(throws: ZIPArchiveFailure.unsupported) { try GeneratedZIP.parse(split) }
    }
    @Test func pageBoundRemains256WithManyMembers() async throws {
        let source = GeneratedZIP.bytes((0..<600).map { .init("File \($0).txt", bytes: Data()) })
        let session = ZIPArchiveSession(try GeneratedZIP.parse(source))
        let first = try await session.page(in: session.root), second = try await session.page(in: session.root, offset: 256)
        #expect(first.items.count == 256 && first.hasNext && first.total == 600)
        #expect(second.items.count == 256 && second.offset == 256 && second.items[0].name == "File 256.txt")
        await session.close()
    }
    @Test func zip64OffsetsBeyondFourGiBAreNeverNarrowedOrMaterialized() throws {
        let centralOffset = UInt64(UInt32.max) + 1_024
        let name = Data("Large declared member".utf8)
        let logical = UInt64(UInt32.max) + 20
        let extra = GeneratedZIP.le(1, 2) + GeneratedZIP.le(24, 2) + GeneratedZIP.le(logical, 8) + GeneratedZIP.le(0, 8) + GeneratedZIP.le(0, 8)
        var central = Data(repeating: 0, count: 46)
        GeneratedZIP.put(&central, 0, 0x02014b50, 4); GeneratedZIP.put(&central, 8, 0x0800, 2)
        GeneratedZIP.put(&central, 20, UInt64(UInt32.max), 4); GeneratedZIP.put(&central, 24, UInt64(UInt32.max), 4)
        GeneratedZIP.put(&central, 28, UInt64(name.count), 2); GeneratedZIP.put(&central, 30, UInt64(extra.count), 2)
        GeneratedZIP.put(&central, 42, UInt64(UInt32.max), 4); central += name; central += extra
        let position = centralOffset + UInt64(central.count)
        var trailer = Data(repeating: 0, count: 98)
        GeneratedZIP.put(&trailer, 0, 0x06064b50, 4); GeneratedZIP.put(&trailer, 4, 44, 8)
        GeneratedZIP.put(&trailer, 24, 1, 8); GeneratedZIP.put(&trailer, 32, 1, 8)
        GeneratedZIP.put(&trailer, 40, UInt64(central.count), 8); GeneratedZIP.put(&trailer, 48, centralOffset, 8)
        GeneratedZIP.put(&trailer, 56, 0x07064b50, 4); GeneratedZIP.put(&trailer, 64, position, 8); GeneratedZIP.put(&trailer, 72, 1, 4)
        GeneratedZIP.put(&trailer, 76, 0x06054b50, 4); GeneratedZIP.put(&trailer, 84, 65535, 2); GeneratedZIP.put(&trailer, 86, 65535, 2)
        GeneratedZIP.put(&trailer, 88, UInt64(UInt32.max), 4); GeneratedZIP.put(&trailer, 92, UInt64(UInt32.max), 4)
        let length = position + UInt64(trailer.count)
        let sections: [(UInt64, Data)] = [(0, GeneratedZIP.le(0x04034b50, 4)), (centralOffset, central), (position, trailer)]
        var maximumRead = 0
        let parsed = try ZIPMetadataParser.parse(length: length, cancelled: { false }) { offset, count in
            maximumRead = max(maximumRead, count)
            guard offset <= length, UInt64(count) <= length - offset else { throw ZIPArchiveFailure.malformed }
            var value = Data(repeating: 0, count: count)
            for (start, bytes) in sections {
                let lower = max(offset, start), upper = min(offset + UInt64(count), start + UInt64(bytes.count))
                if lower < upper {
                    value.replaceSubrange(Int(lower - offset)..<Int(upper - offset), with: bytes[Int(lower - start)..<Int(upper - start)])
                }
            }
            return value
        }
        #expect(parsed.summary.logicalBytes == logical && parsed.summary.isZIP64 && maximumRead <= 65_557)
    }
    @Test func deterministicMalformedHeaderMutationHasBoundedOutcomes() throws {
        let original = GeneratedZIP.bytes([.init("Folder/Entry.txt")], zip64: true)
        var seed: UInt64 = 0xb090001
        for iteration in 0..<2_000 {
            var bytes = original
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            if iteration % 4 == 0 { bytes.removeLast(Int(seed % UInt64(bytes.count))) }
            else { bytes[Int(seed % UInt64(bytes.count))] ^= UInt8(truncatingIfNeeded: seed >> 32) }
            do {
                let result = try GeneratedZIP.parse(bytes)
                // A mutation can turn an ordinary character into a valid path
                // separator, creating more implied folders. Assert the actual
                // bounded contract rather than the original tree's shape.
                #expect(result.nodes.count <= 65 && result.summary.records == 1)
            } catch is ZIPArchiveFailure { /* Every controlled refusal is an honest outcome. */ }
        }
    }
    @Test func centralListingDoesNotPretendToVerifyCorruptedPayloadCRC() throws {
        var bytes = GeneratedZIP.bytes([.init("Entry.txt")])
        bytes[30 + "Entry.txt".utf8.count] ^= 1
        #expect(try GeneratedZIP.parse(bytes).summary.files == 1)
    }
    @Test func cachedMatchingKeepsUnicodeAndSymbolOptOutSeparate() async throws {
        let source = GeneratedZIP.bytes([.init("Café_notes-file.txt"), .init("Other")])
        let session = ZIPArchiveSession(try GeneratedZIP.parse(source))
        #expect(try await session.page(in: session.root, filter: "cafe notes file").items.count == 1)
        #expect(try await session.page(in: session.root, filter: "cafe notes file", symbolTolerant: false).items.isEmpty)
        #expect(try await session.page(in: session.root, filter: "CAFÉ_NOTES-", symbolTolerant: false).items.count == 1)
        var limits = ZIPReadLimits(); limits.searchBytes = 1
        #expect(throws: ZIPArchiveFailure.limited) { try GeneratedZIP.parse(source, limits: limits) }
        await session.close()
    }
}

private struct ZIPDiskFixture {
    let root: URL
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B09_TEST_ROOT"] else { throw ZIPArchiveFailure.unavailable }
        let base = URL(fileURLWithPath: path)
        guard base.resolvingSymlinksInPath() == base, base.path.contains("/.build/b09-zip-browser/"),
              FileManager().fileExists(atPath: base.deletingLastPathComponent().appendingPathComponent("reservation.json").path) else { throw ZIPArchiveFailure.unavailable }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func file(_ name: String = "Generated.zip") throws -> URL {
        let url = root.appendingPathComponent(name)
        try GeneratedZIP.bytes([.init("Folder/Generated.txt")]).write(to: url, options: .withoutOverwriting); return url
    }
}
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B09_TEST_ROOT"] != nil))
struct ZIPArchiveDiskTests {
    @Test func selectedArchiveReadChangesNoSourceAndMaterializesNoMembers() async throws {
        let fixture = try ZIPDiskFixture(), source = try fixture.file(), before = try Data(contentsOf: source)
        let gate = FileActivityGate(), reader = ZIPArchiveReader(activity: gate)
        let catalog = try await reader.open(source), page = try await catalog.page(in: catalog.root)
        #expect(page.items.count == 1 && catalog.summary.files == 1 && gate.activeCount == 0)
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager().fileExists(atPath: fixture.root.appendingPathComponent("Folder").path))
        await catalog.close(); await reader.drain()
    }
    @Test func realSourceReplacementAndPathRedirectionAreRefused() async throws {
        let fixture = try ZIPDiskFixture(), source = try fixture.file()
        let reader = ZIPArchiveReader { stage in
            if case .parsed = stage { try GeneratedZIP.bytes([.init("Different")]).write(to: source, options: .atomic) }
        }
        await #expect(throws: ZIPArchiveFailure.changed) { try await reader.open(source) }
        let link = fixture.root.appendingPathComponent("linked.zip")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: ZIPArchiveFailure.unavailable) { try await ZIPArchiveReader().open(link) }
        let directoryLink = fixture.root.appendingPathComponent("linked-parent")
        try FileManager().createSymbolicLink(at: directoryLink, withDestinationURL: fixture.root)
        await #expect(throws: ZIPArchiveFailure.unavailable) { try await ZIPArchiveReader().open(directoryLink.appendingPathComponent(source.lastPathComponent)) }
        let fifo = fixture.root.appendingPathComponent("fifo.zip"); #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: ZIPArchiveFailure.unsupported) { try await ZIPArchiveReader().open(fifo) }
    }
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let semaphore = DispatchSemaphore(value: 0)
        var waiting: Bool { lock.withLock { entered } }
        func hold() { lock.withLock { entered = true }; semaphore.wait() }
        func release() { semaphore.signal() }
    }
    @Test func cancelledMetadataReadRetainsActualActivityUntilDrained() async throws {
        let fixture = try ZIPDiskFixture(), source = try fixture.file(), gate = FileActivityGate(), barrier = Barrier()
        let reader = ZIPArchiveReader(activity: gate) { stage in if case .opened = stage { barrier.hold() } }
        let task = Task { try await reader.open(source) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !barrier.waiting && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        #expect(barrier.waiting && gate.activeCount == 1)
        task.cancel(); let token = try #require(gate.closeAdmission())
        #expect(!gate.ownsDrainedAdmission(token))
        await #expect(throws: ZIPArchiveFailure.busy) { try await reader.open(source) }
        barrier.release(); await #expect(throws: ZIPArchiveFailure.stopped) { try await task.value }
        #expect(await gate.waitUntilDrained(token)); await reader.drain(); #expect(gate.activeCount == 0)
        #expect(gate.reopen(token))
    }
}
