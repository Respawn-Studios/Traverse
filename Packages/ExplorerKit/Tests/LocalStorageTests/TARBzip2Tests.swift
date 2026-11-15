import BoundedArchiveCodecs
import CoreServices
import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing

struct TARBzip2Tests {
    @Test(arguments: [Int32(1), 6, 9], [0, 65_537, 1_300_001])
    func codecChunkAndBlockBoundariesAgreeWithSystemReader(block: Int32, count: Int) throws {
        let root = try LocalStorageTestFixtures.directory(), url = root.appendingPathComponent("Generated.bz2")
        var state: UInt32 = 1
        let raw = Data((0..<count).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: state >> 24) })
        var encoded = Data()
        let encoder = try CompressedArchiveEncoder(maximumRaw: 4 << 20, maximumEncoded: 4 << 20,
            level: block, codec: .bzip2, check: {}, output: { encoded.append(contentsOf: $0) })
        try encoder.write(raw); try encoder.finish(rawBytes: UInt64(raw.count), encodedBytes: { UInt64(encoded.count) })
        #expect(encoder.peakCodecHeap > 0 && encoder.peakCodecHeap <= 8 << 20)
        try encoded.write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); try #require(fd >= 0); defer { close(fd) }
        let peak = try CompressedArchiveEncoder.verify(fd, codec: .bzip2, rawBytes: UInt64(raw.count),
            encodedBytes: UInt64(encoded.count), expected: Data(SHA256.hash(data: raw)), check: {})
        #expect(peak > 0 && peak <= 4 << 20)
        #expect(try TARTestFixture.decodedBzip2(url) == raw)
    }

    @Test(arguments: [1, 2, 6, 9])
    func textSaveRebindPreservesImportedBlockAndIndependentInversePolicy(block: Int) async throws {
        let f = try TARTestFixture(pax: true), source = try f.bzip2Source(block: block)
        let before = try Data(contentsOf: source), history = f.root.appendingPathComponent("history")
        let cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
        let reader = TARArchiveReader(compressedPool: pool), session = try await reader.prepareCompressed(source)
        func flow() async throws {
        let document = try await reader.openTextForEdit(session.selectionForTextPreview(atPath: "data.json"))
        #expect(document.formatName == "TAR.bz2")
        let engine = RecoverableFileOperations(journalDirectory: history, authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
        let text = try TextDocumentValue.edited("{\"bzip2\":true}\n", format: document.contents.format)
        let plan = try await engine.prepareTARMemberTextReplacementOriginal(document, contents: text,
            observing: try await engine.observeSelection([source]))
        let result = await engine.performArchiveOriginalUpdate(plan), id = try #require(result.recordID)
        #expect(result.result.disposition == .succeeded)
        let after = try Data(contentsOf: source)
        #expect(after[3] == UInt8(48 + block))
        let rebound = try await reader.reopenTextForEdit(document, expecting: text)
        #expect(rebound.contents.encoded == text.encoded)
        for wrong in [RecoverableFileOperations(journalDirectory: history,
            authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage),
            RecoverableFileOperations(journalDirectory: history, authoredTAROriginalUpdatePolicy: .developmentNativeStage),
            RecoverableFileOperations(journalDirectory: history, tarBzip2CreationPolicy: .developmentNativeCreate)] {
            #expect(try await wrong.inspectExistingHistory().records.first { $0.id == id }?.canUndo == false)
            #expect(await wrong.undo(recordID: id).result.disposition != .succeeded)
            #expect(try Data(contentsOf: source) == after)
        }
        let cold = RecoverableFileOperations(journalDirectory: history, authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
        let row = try #require(try await cold.inspectExistingHistory().records.first { $0.id == id })
        #expect(row.operation == "Update TAR.bz2" && row.originalArchiveFormatName == "TAR.bz2")
        #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
        #expect(try Data(contentsOf: source) == before)
        withExtendedLifetime(rebound) {}
        }
        do { try await flow() }
        catch { await session.close(); _ = await pool.closeAndDrain(); throw error }
        await session.close(); #expect(await pool.closeAndDrain())
    }

    @Test func changedSourceAndWrongCodecCannotPublishPreparedBytes() async throws {
        let f = try TARTestFixture(), source = try f.bzip2Source(), cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init()), reader = TARArchiveReader(compressedPool: pool)
        let session = try await reader.prepareCompressed(source)
        func flow() async throws {
        let root = try await session.destinationForMemberChanges(session.root)
        let engine = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
        let plan = try await engine.prepareTARMemberMutationOriginal(.newFile(root, name: "Never.txt"),
            observing: try await engine.observeSelection([source]))
        var bytes = try Data(contentsOf: source); bytes[4] ^= 1; try bytes.write(to: source)
        #expect(await engine.performArchiveOriginalUpdate(plan).result.disposition != .succeeded)
        #expect(try Data(contentsOf: source) == bytes)
        let disguised = f.root.appendingPathComponent("Disguised.tar.gz")
        try bytes.write(to: disguised, options: .withoutOverwriting)
        await #expect(throws: TARArchiveFailure.malformed) { try await reader.prepareCompressed(disguised) }
        }
        do { try await flow() }
        catch { await session.close(); _ = await pool.closeAndDrain(); throw error }
        await session.close(); #expect(await pool.closeAndDrain())
    }

    @Test func retainedOriginalHasExplicitBzip2RestoreAndKeepsItsNativeProtection() async throws {
        let f = try TARTestFixture(pax: true), source = try f.bzip2Source(), cache = f.root.appendingPathComponent("cache")
        var properties = URLResourceValues()
        properties.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Generated bzip2 source",
            kLSQuarantineTimeStampKey as String: Date(), kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var target = source; try target.setResourceValues(properties)
        let before = try Data(contentsOf: source), history = f.root.appendingPathComponent("history")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init()), reader = TARArchiveReader(compressedPool: pool)
        let session = try await reader.prepareCompressed(source)
        func flow() async throws {
            let document = try await reader.openTextForEdit(session.selectionForTextPreview(atPath: "data.json"))
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { stage, _ in
                if stage == .originalRetained { throw FileOperationFailure.ioFailure }
            }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
                nativeAuthoredUpdatePublicMarkPolicy: .sourceQualification,
                authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
            let text = try TextDocumentValue.edited("{\"retained\":true}\n", format: document.contents.format)
            let plan = try await engine.prepareTARMemberTextReplacementOriginal(document, contents: text,
                observing: try await engine.observeSelection([source]))
            let result = await engine.performArchiveOriginalUpdate(plan), id = try #require(result.recordID)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: source.path))
            let wrong = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(try await wrong.inspectExistingHistory().records.first { $0.id == id }?.canRestoreOriginalArchive == false)
            let cold = RecoverableFileOperations(journalDirectory: history, authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
            let row = try #require(try await cold.inspectExistingHistory().records.first { $0.id == id })
            #expect(row.canRestoreOriginalArchive && !row.canRecover && !row.canUndo && row.originalArchiveFormatName == "TAR.bz2")
            #expect(await cold.recover(recordID: id).result.disposition != .succeeded)
            #expect(await cold.restoreInterruptedOriginalArchive(recordID: id).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
            #expect(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey])
                .quarantineProperties?[kLSQuarantineAgentNameKey as String] as? String == "Generated bzip2 source")
        }
        do { try await flow() }
        catch { await session.close(); _ = await pool.closeAndDrain(); throw error }
        await session.close(); #expect(await pool.closeAndDrain())
    }

    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var requested = false
        func request() { lock.withLock { requested = true } }
        func check() throws { if lock.withLock({ requested }) { throw CancellationError() } }
    }
    @Test func stopAndOutputQuotaProduceNoCompletion() throws {
        let stop = Stop()
        var bytes = Data()
        let encoder = try CompressedArchiveEncoder(maximumRaw: 2 << 20, maximumEncoded: 2 << 20,
            level: 9, codec: .bzip2, check: stop.check, output: { bytes.append(contentsOf: $0) })
        try encoder.write(Data(repeating: 65, count: 1 << 20))
        stop.request()
        #expect(throws: CancellationError.self) { try encoder.finish(rawBytes: 1 << 20, encodedBytes: { UInt64(bytes.count) }) }
        let limited = try CompressedArchiveEncoder(maximumRaw: 1024, maximumEncoded: 1,
            level: 6, codec: .bzip2, check: {}, output: { _ in })
        #expect(throws: TAROutputStream.Failure.limit) { try limited.finish(rawBytes: 0, encodedBytes: { 0 }) }
    }
    @Test func malformedAndStoppedDecodersReleaseEveryChargedAllocation() throws {
        let f = try TARTestFixture(), source = try f.bzip2Source(block: 9), good = try Data(contentsOf: source)
        var corrupt = good; corrupt[corrupt.count - 5] ^= 1
        for (index, bytes) in [Data(), Data(good.prefix(3)), Data(good.dropLast()), corrupt, good + good, good + Data([0])].enumerated() {
            let url = f.root.appendingPathComponent("Invalid-\(index).bz2")
            try bytes.write(to: url, options: .withoutOverwriting)
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); try #require(fd >= 0); defer { close(fd) }
            let result = tr_bzip2_consume_fd(fd, 1 << 20, 1 << 20, 1, nil, { _, _, _ in 1 }, nil)
            #expect(result.status != 0 && result.heap_remaining_bytes == 0 && result.heap_peak_bytes <= 4 << 20)
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); try #require(fd >= 0); defer { close(fd) }
        let limit = tr_bzip2_consume_fd(fd, 1 << 20, 1, 1, nil, { _, _, _ in 1 }, nil)
        let refused = tr_bzip2_consume_fd(fd, 1 << 20, 1 << 20, 1, nil, { _, _, _ in 0 }, nil)
        #expect(limit.status == 4 && limit.heap_remaining_bytes == 0)
        #expect(refused.status == 6 && refused.heap_remaining_bytes == 0)
        final class Polls { var count = 0 }
        let polls = Polls()
        let stopped = tr_bzip2_consume_fd(fd, 1 << 20, 1 << 20, 1, { raw in
            guard let raw else { return 1 }
            let polls = Unmanaged<Polls>.fromOpaque(raw).takeUnretainedValue()
            polls.count += 1; return polls.count >= 3 ? 1 : 0
        }, { _, _, _ in 1 }, Unmanaged.passUnretained(polls).toOpaque())
        withExtendedLifetime(polls) {}
        #expect(stopped.status == 5 && stopped.heap_remaining_bytes == 0)
    }
    @Test func preparationResetsConcatenatedStreamsWithUnreadInputButRewriteRefuses() async throws {
        var state: UInt32 = 7
        let body = Data((0..<90_017).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: state >> 24) })
        let f = try TARTestFixture(rawMembers: TARTestFixture.member("Large.bin", body: body))
        var combined = Data()
        for raw in [Data(f.bytes.prefix(40_013)), Data(), Data(f.bytes.dropFirst(40_013))] {
            var stream = Data()
            let encoder = try CompressedArchiveEncoder(maximumRaw: 1 << 20, maximumEncoded: 1 << 20,
                level: 1, codec: .bzip2, check: {}, output: { stream.append(contentsOf: $0) })
            try encoder.write(raw); try encoder.finish(rawBytes: UInt64(raw.count), encodedBytes: { UInt64(stream.count) })
            combined.append(stream)
        }
        let source = f.root.appendingPathComponent("Concatenated.tar.bz2"), output = f.root.appendingPathComponent("Decoded.tar")
        try combined.write(to: source, options: .withoutOverwriting)
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let decoded = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(input >= 0 && decoded >= 0); defer { close(input); close(decoded) }
        let outcome = try TARCompressedDecoder.expand(input: input, output: decoded, codec: .bzip2, cancellation: .init())
        #expect(outcome.members == 3 && outcome.compressedBytes == combined.count && outcome.peakCodecHeap <= 4 << 20)
        #expect(try Data(contentsOf: output) == f.bytes)
        #expect(try TARTestFixture.decodedBzip2(source) == f.bytes)
        let cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init()), reader = TARArchiveReader(compressedPool: pool)
        let session = try await reader.prepareCompressed(source)
        #expect(session.summary.logicalBytes == body.count && session.summary.files == 1)
        func refuse() async throws {
            let root = try await session.destinationForMemberChanges(session.root)
            let engine = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
                authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
            await #expect(throws: (any Error).self) {
                try await engine.prepareTARMemberMutationOriginal(.newFile(root, name: "New.txt"),
                    observing: engine.observeSelection([source]))
            }
        }
        do { try await refuse() }
        catch { await session.close(); _ = await pool.closeAndDrain(); throw error }
        await session.close(); #expect(await pool.closeAndDrain())
        #expect(try Data(contentsOf: source) == combined)
    }
}
