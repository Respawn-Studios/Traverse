import Darwin
import ExplorerCore
import Foundation
import Testing
import zlib
@testable import LocalStorage

internal enum ContentZIP {
    static func deflate(_ bytes: Data) throws -> Data {
        var state = z_stream()
        return try withUnsafeMutablePointer(to: &state) { stream in
            guard deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPContentFailure.codecUnavailable }
            defer { _ = deflateEnd(stream) }
            let capacity = Int(compressBound(uLong(bytes.count))) + 64
            var result = Data(count: capacity)
            let status = result.withUnsafeMutableBytes { output in bytes.withUnsafeBytes { input in
                stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.pointee.avail_in = uInt(bytes.count)
                stream.pointee.next_out = output.bindMemory(to: UInt8.self).baseAddress; stream.pointee.avail_out = uInt(capacity)
                return zlib.deflate(stream, Z_FINISH)
            } }
            guard status == Z_STREAM_END else { throw ZIPContentFailure.codecUnavailable }
            result.removeLast(Int(stream.pointee.avail_out)); return result
        }
    }
    static func check(_ packed: Data, bytes: Data, crc: UInt32? = nil, method: UInt16 = 8,
                      checkpoint: () throws -> Void = {}, decoded: (UInt64) throws -> Void = { _ in }) throws {
        try ZIPContentDecoder.check(method: method, packed: UInt64(packed.count), logical: UInt64(bytes.count), expectedCRC: crc ?? ZIPMetadataParser.crc32(bytes),
            check: checkpoint, read: { offset, count in
                guard offset <= packed.count, UInt64(count) <= UInt64(packed.count) - offset else { throw ZIPContentFailure.contentMismatch }
                return Data(packed[Int(offset)..<(Int(offset) + count)])
            }, decoded: decoded)
    }
    static func member(_ name: String = "Generated.txt", bytes: Data) throws -> GeneratedZIP.Member {
        var value = GeneratedZIP.Member(name, bytes: bytes); value.method = 8; value.packed = try deflate(bytes); return value
    }
    static func records(_ bytes: Data) throws -> [ZIPPayloadRecord] {
        var result: [ZIPPayloadRecord] = []
        _ = try ZIPMetadataParser.parse(length: UInt64(bytes.count), capture: { result.append($0) }, cancelled: { false }) { offset, count in
            guard offset <= bytes.count, UInt64(count) <= UInt64(bytes.count) - offset else { throw ZIPArchiveFailure.malformed }
            return Data(bytes[Int(offset)..<(Int(offset) + count)])
        }
        return result
    }
    static func verify(_ bytes: Data, limits: ZIPContentLimits = .init()) throws -> ZIPContentReport {
        try ZIPContentVerifier.verify(records(bytes), limits: limits, check: {}, read: { offset, count in
            guard offset <= bytes.count, UInt64(count) <= UInt64(bytes.count) - offset else { throw ZIPArchiveFailure.malformed }
            return Data(bytes[Int(offset)..<(Int(offset) + count)])
        }, progress: nil)
    }
}

@Suite struct ZIPContentTests {
    @Test func storedAndDeflatedEmptyAndBufferBoundariesHaveExactCRC() throws {
        for count in [0, 1, 65_535, 65_536, 65_537, 196_609] {
            var seed: UInt64 = UInt64(count) + 1
            let bytes = Data((0..<count).map { _ in seed = seed &* 6_364_136_223_846_793_005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 32) })
            var total: UInt64 = 0
            try ContentZIP.check(ContentZIP.deflate(bytes), bytes: bytes, decoded: { total += $0 })
            #expect(total == count)
            try ContentZIP.check(bytes, bytes: bytes, method: 0)
        }
    }
    @Test func everyTruncatedPrefixAndTrailingStreamIsRefused() throws {
        let bytes = Data((0..<300).map { UInt8(truncatingIfNeeded: $0 * 53) }), packed = try ContentZIP.deflate(bytes)
        for count in 0..<packed.count {
            #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(Data(packed.prefix(count)), bytes: bytes) }
        }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(packed + Data([0]), bytes: bytes) }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(packed + packed, bytes: bytes) }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(packed, bytes: bytes, crc: 1) }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(packed, bytes: Data(bytes.dropLast())) }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(packed, bytes: bytes + Data([0])) }
        #expect(throws: ZIPContentFailure.contentMismatch) { try ContentZIP.check(Data(), bytes: Data()) }
    }
    @Test func shortInputAndCooperativeCancellationCannotBecomeSuccess() throws {
        let bytes = Data(repeating: 0x42, count: 196_609), packed = try ContentZIP.deflate(bytes)
        #expect(throws: ZIPContentFailure.contentMismatch) {
            try ZIPContentDecoder.check(method: 8, packed: UInt64(packed.count), logical: UInt64(bytes.count), expectedCRC: 0,
                check: {}, read: { _, count in Data(repeating: 0, count: max(0, count - 1)) }, decoded: { _ in })
        }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ContentZIP.check(packed, bytes: bytes, checkpoint: { checks += 1; if checks == 4 { throw CancellationError() } })
        }
        #expect(checks == 4)
        #expect(throws: ZIPContentFailure.unsupported) { try ContentZIP.check(packed, bytes: bytes, method: 99) }
    }
    @Test func localHeadersAndBodyFactsMustAgreeBeforeWholeArchiveSuccess() throws {
        let bytes = Data("Generated Unicode content 日本語".utf8)
        let archive = GeneratedZIP.bytes([try ContentZIP.member("Café.txt", bytes: bytes), .init("Empty/", mode: 0x4000, bytes: Data())])
        let checked = try ContentZIP.verify(archive)
        #expect(checked.files == 1 && checked.folders == 1 && checked.decodedBytes == bytes.count && !checked.codecVersion.isEmpty)
        for offset in [6, 8, 14, 18, 22, 30] {
            var changed = archive; changed[offset] ^= 1
            do { _ = try ContentZIP.verify(changed); Issue.record("Changed local header was accepted at \(offset)") }
            catch let problem as ZIPContentProblem { #expect(problem.reason == .metadataMismatch) }
        }
        var corrupt = archive
        let record = try #require(ContentZIP.records(archive).first)
        corrupt[30 + record.rawName.count] ^= 0xff
        do { _ = try ContentZIP.verify(corrupt); Issue.record("Corrupted compressed body was accepted") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .contentMismatch) }
    }
    @Test func limitsUnsupportedFlagsAndKindsRefuseWithoutDecoding() throws {
        let normal = GeneratedZIP.bytes([.init("one", bytes: Data("generated".utf8))])
        var limits = ZIPContentLimits(); limits.memberBytes = 3
        do { _ = try ContentZIP.verify(normal, limits: limits); Issue.record("Member limit not enforced") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .limitReached) }
        limits = .init(); limits.jobBytes = 3
        do { _ = try ContentZIP.verify(normal, limits: limits); Issue.record("Job limit not enforced") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .limitReached) }
        let expanded = GeneratedZIP.bytes([try ContentZIP.member(bytes: Data(repeating: 0, count: 2 * 1_024 * 1_024))])
        #expect(try ContentZIP.verify(expanded).decodedBytes == 2 * 1_024 * 1_024)
        limits = .init(); limits.expansionRatio = 1_000
        do { _ = try ContentZIP.verify(expanded, limits: limits); Issue.record("Original expansion bound not enforced") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .limitReached) }
        var forged = GeneratedZIP.Member("forged", bytes: Data(repeating: 0, count: 2_001)); forged.packed = Data([0])
        do { _ = try ContentZIP.verify(GeneratedZIP.bytes([forged])); Issue.record("New expansion bound not enforced") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .limitReached) }
        for flags: UInt16 in [0x0801, 0x0840, 0x2800] {
            var member = GeneratedZIP.Member("one"); member.flags = flags
            do { _ = try ContentZIP.verify(GeneratedZIP.bytes([member])); Issue.record("Unsupported flag was decoded") }
            catch let problem as ZIPContentProblem { #expect(problem.reason == .unsupported) }
        }
        for mode: UInt16 in [0xa000, 0x1000] {
            do { _ = try ContentZIP.verify(GeneratedZIP.bytes([.init("one", mode: mode)])); Issue.record("Special member was decoded") }
            catch let problem as ZIPContentProblem { #expect(problem.reason == .unsupported) }
        }
    }
    @Test func localZIP64SizesAndOverlappingMemberExtentsAreChecked() throws {
        let content = Data("generated".utf8)
        var member = GeneratedZIP.Member("one", bytes: content)
        member.extra = GeneratedZIP.le(1, 2) + GeneratedZIP.le(16, 2) + GeneratedZIP.le(UInt64(content.count), 8) + GeneratedZIP.le(UInt64(content.count), 8)
        var archive = GeneratedZIP.bytes([member])
        GeneratedZIP.put(&archive, 4, 45, 2); GeneratedZIP.put(&archive, 18, UInt64(UInt32.max), 4); GeneratedZIP.put(&archive, 22, UInt64(UInt32.max), 4)
        #expect(try ContentZIP.verify(archive).decodedBytes == content.count)
        let inner = GeneratedZIP.Member("B", bytes: Data(repeating: 0x42, count: 8))
        var outerBytes = Data(repeating: 0x41, count: 64)
        outerBytes.replaceSubrange(0..<39, with: GeneratedZIP.bytes([inner]).prefix(39))
        var overlap = GeneratedZIP.bytes([.init("A", bytes: outerBytes), inner])
        let first = try #require(ContentZIP.records(overlap).first)
        GeneratedZIP.put(&overlap, Int(first.centralOffset) + 47 + 42, 31, 4)
        do { _ = try ContentZIP.verify(overlap); Issue.record("Overlapping members were accepted") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .metadataMismatch) }
    }
}

private struct ContentZIPFixture {
    let root: URL, source: URL
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_CONTENT_TEST_ROOT"] else { throw ZIPArchiveFailure.unavailable }
        let admitted = URL(fileURLWithPath: path), repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard admitted.lastPathComponent == "source", admitted.resolvingSymlinksInPath() == admitted,
              admitted.deletingLastPathComponent().deletingLastPathComponent() == repository.appendingPathComponent(".build/b09-archive-content-check"),
              UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil,
              FileManager().fileExists(atPath: admitted.deletingLastPathComponent().appendingPathComponent("reservation.json").path) else { throw ZIPArchiveFailure.unavailable }
        root = admitted.appendingPathComponent(UUID().uuidString); source = root.appendingPathComponent("Generated.zip")
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false)
        try GeneratedZIP.bytes([ContentZIP.member(bytes: Data("generated body".utf8))]).write(to: source, options: .withoutOverwriting)
    }
}
private final class ContentReadBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var checking = false, blocked = false
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func visit(_ stage: ZIPArchiveReader.Stage) {
        let shouldBlock = lock.withLock {
            if stage == .checking { checking = true }
            if stage == .read, checking, !blocked { blocked = true; return true }
            return false
        }
        if shouldBlock { entered.signal(); release.wait() }
    }
}
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_CONTENT_TEST_ROOT"] != nil))
struct ZIPContentDiskTests {
    @Test func explicitCheckDoesNotMaterializeOrChangeTheSource() async throws {
        let f = try ContentZIPFixture(), before = try Data(contentsOf: f.source)
        let reader = ZIPArchiveReader(), result = try await reader.checkContents(f.source)
        #expect(result.files == 1 && result.decodedBytes == 14)
        #expect(try Data(contentsOf: f.source) == before && FileManager().contentsOfDirectory(atPath: f.root.path) == ["Generated.zip"])
        var limits = ZIPContentLimits(); limits.seconds = 0
        let bounded = ZIPArchiveReader(contentLimits: limits, probe: { _ in })
        do { _ = try await bounded.checkContents(f.source); Issue.record("Deadline did not stop a check") }
        catch let problem as ZIPContentProblem { #expect(problem.reason == .limitReached) }
    }
    @Test func changedSourceCannotBeReportedAsACorruptStableArchive() async throws {
        let f = try ContentZIPFixture()
        let reader = ZIPArchiveReader(probe: { stage in
            if stage == .checking {
                let offset = UInt64(30 + Data("Generated.txt".utf8).count)
                let handle = try FileHandle(forUpdating: f.source)
                try handle.seek(toOffset: offset)
                guard let original = try handle.read(upToCount: 1), let byte = original.first else { throw ZIPArchiveFailure.malformed }
                try handle.seek(toOffset: offset); try handle.write(contentsOf: Data([byte ^ 0xff])); try handle.close()
            }
        })
        await #expect(throws: ZIPArchiveFailure.changed) { try await reader.checkContents(f.source) }
    }
    @Test func cancelledBodyCheckRetainsActualLeaseAndRefusesOverlappingReads() async throws {
        let f = try ContentZIPFixture(), gate = FileActivityGate(), barrier = ContentReadBarrier()
        let reader = ZIPArchiveReader(activity: gate, probe: { barrier.visit($0) })
        let task = Task { try await reader.checkContents(f.source) }
        let reached = await Task.detached { barrier.wait() }.value
        #expect(reached && gate.activeCount == 1)
        task.cancel()
        #expect(gate.activeCount == 1)
        await #expect(throws: ZIPArchiveFailure.busy) { try await reader.open(f.source) }
        barrier.release.signal()
        do { _ = try await task.value; Issue.record("Cancelled check published success") }
        catch { #expect(error is CancellationError || error as? ZIPArchiveFailure == .stopped) }
        await reader.drain(); #expect(gate.activeCount == 0)
    }
}
