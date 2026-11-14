import Darwin
import Foundation
import XCTest
import zlib
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@testable import LocalStorage

final class TARCompressedPreparationTests: XCTestCase {
    func testRetainedPlainAndPreparedCatalogsRejectReplacedOriginalWithoutRepreparing() async throws {
        for compressed in [false, true] {
            let (compressedURL, cache) = try fixture()
            let source = compressed ? compressedURL : cache.deletingLastPathComponent().appendingPathComponent("Generated.tar")
            if !compressed { try archive().write(to: source, options: .withoutOverwriting) }
            let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: FileActivityGate())
            let reader = TARArchiveReader(compressedPool: pool)
            let session = try await (compressed ? reader.prepareCompressed(source) : reader.open(source))
            let current = await session.matchesCurrentSourceObservation()
            XCTAssertTrue(current)
            let usage = pool.usage.entryCount
            let replacement = source.deletingLastPathComponent().appendingPathComponent("Replacement")
            try (compressed ? gzip(archive(body: Data("new body".utf8))) : archive(body: Data("new body".utf8)))
                .write(to: replacement, options: .withoutOverwriting)
            XCTAssertEqual(rename(replacement.path, source.path), 0)
            let replaced = await session.matchesCurrentSourceObservation()
            XCTAssertFalse(replaced)
            XCTAssertEqual(pool.usage.entryCount, usage, "Freshness must not decode another spool")
            await session.close()
            let closed = await session.matchesCurrentSourceObservation()
            XCTAssertFalse(closed)
            let drained = await pool.closeAndDrain()
            XCTAssertTrue(drained)
        }
    }
    func testAllocatedBlockCeilingIsExactlyOneHundredTwentyEightMiBPerSpool() {
        let boundary = Int64(TARCompressedDecoder.maximumBytes / 512)
        XCTAssertEqual(TARCompressedSpoolStorage.admittedAllocation(blocks: boundary), TARCompressedDecoder.maximumBytes)
        XCTAssertNil(TARCompressedSpoolStorage.admittedAllocation(blocks: boundary + 1))
        XCTAssertNil(TARCompressedSpoolStorage.admittedAllocation(blocks: -1))
        XCTAssertEqual(TARCompressedDecoder.maximumBytes * 4, 512 << 20)
    }
    private final class PreparationBarrier: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func wait() {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        func awaitEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    }
    private func fixture(body: Data = Data("hello".utf8)) throws -> (URL, URL) {
        let root = try LocalStorageTestFixtures.directory()
        let inputURL = root.appendingPathComponent("Generated.tar.gz")
        try gzip(archive(body: body)).write(to: inputURL, options: .withoutOverwriting)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        return (inputURL, cache)
    }
    private func archive(body: Data = Data("hello".utf8)) -> Data {
        var header = Data(repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            header.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
        }
        put("Generated.txt", at: 0)
        put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
        put(String(format: "%011o", body.count) + "\0", at: 124); put("00000000000\0", at: 136)
        for offset in 148..<156 { header[offset] = 32 }
        header[156] = 48; put("ustar\0", at: 257); put("00", at: 263)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148)
        var bytes = header
        bytes.append(body); bytes.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        bytes.append(Data(repeating: 0, count: 1024))
        return bytes
    }
    private func gzip(_ input: Data) throws -> Data {
        var stream = z_stream(), output = Data()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TARArchiveFailure.unavailable
        }
        defer { deflateEnd(&stream) }
        let chunk = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 4096)
        defer { chunk.deallocate() }
        try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(bytes.count)
            repeat {
                stream.next_out = chunk.baseAddress; stream.avail_out = 4096
                let status = deflate(&stream, Z_FINISH)
                guard status == Z_OK || status == Z_STREAM_END else { throw TARArchiveFailure.unavailable }
                output.append(contentsOf: chunk.prefix(4096 - Int(stream.avail_out)))
                if status == Z_STREAM_END { break }
            } while true
            stream.next_in = nil; stream.next_out = nil
        }
        return output
    }
    func testBoundedCodecCreatesOnlySealedPrivateTARAndOriginalStaysExact() throws {
        let (inputURL, cache) = try fixture()
        let input = try Data(contentsOf: inputURL)
        let storage = try TARCompressedSpoolStorage(directory: cache)
        try storage.requireNoOrphans()
        let source = try PinnedLocalFileSource(inputURL)
        let security = try ZIPSourceSecurity.extractionWitness(source.descriptor, url: source.url, allowingInheritance: true)
        let proof = TARCompressedOriginalProof(source: source.url, stamp: source.observed, security: .exact(security))
        let prepared = try storage.prepare(proof, excluding: [], cancellation: .init(), progress: { _, _, _ in })
        defer { close(prepared.descriptor) }
        XCTAssertEqual(prepared.decodedBytes, 2048)
        XCTAssertEqual(prepared.catalog.summary.files, 1)
        XCTAssertEqual(try TARCompressedSpoolLease.Stamp(prepared.descriptor), prepared.stamp)
        XCTAssertEqual(try Data(contentsOf: inputURL), input)
        try storage.requireNoOrphans()
    }

    func testExplicitPreparationBindsOriginalAndReleasesAfterSessionAndSelectionClose() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        do {
            _ = try await reader.open(inputURL)
            XCTFail("Plain TAR open must not decode a compressed source")
        } catch TARArchiveFailure.compressed { }
        let session = try await reader.prepareCompressed(inputURL)
        XCTAssertTrue(session.isCompressed)
        XCTAssertEqual(session.summary.files, 1)
        XCTAssertEqual(session.compressedPreparation?.compressedBytes, UInt64(try Data(contentsOf: inputURL).count))
        XCTAssertEqual(session.compressedPreparation?.decodedTARBytes, 2048)
        XCTAssertEqual(session.compressedPreparation?.memberLogicalBytes, 5)
        let page = try await session.page(in: session.root)
        XCTAssertEqual(page.items.map(\.name), ["Generated.txt"])
        var selection: TARExtractionSelection? = try await session.selectionForWholeExtraction()
        let producer = try PreparedTARDirectory(inputURL, selection: selection!, check: {})
        try producer.validate(check: {})
        await session.close()
        XCTAssertEqual(pool.usage.entryCount, 1)
        producer.finished()
        selection = nil
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pool.usage.entryCount, 0)
        XCTAssertEqual(pool.usage.reservedBytes, 0)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testPreparedSelectedTextAndHexPreviewRetainLeaseAfterSessionClose() async throws {
        let (inputURL, cache) = try fixture()
        let original = try Data(contentsOf: inputURL)
        let gate = FileActivityGate(), pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(inputURL)
        let page = try await session.page(in: session.root)
        var selected: TARTextPreviewSelection? = try await session.selectionForTextPreview(XCTUnwrap(page.items.first?.id))
        await session.close()
        XCTAssertEqual(pool.usage.entryCount, 1)
        let text = try await reader.previewText(XCTUnwrap(selected))
        XCTAssertEqual(text.text, "hello")
        XCTAssertEqual(text.utf8Bytes, 5)
        let bytes = try await reader.previewBytes(XCTUnwrap(selected))
        XCTAssertEqual(bytes.byteCount, 5)
        XCTAssertTrue(bytes.hexadecimalText.contains("68 65 6C 6C 6F"))
        XCTAssertTrue(bytes.hexadecimalText.contains("|hello"))
        XCTAssertEqual(try Data(contentsOf: inputURL), original)
        selected = nil
        await reader.drain()
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pool.usage.entryCount, 0)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testPreparedPreviewRefusesOversizeForgedAndChangedSources() async throws {
        do {
            let (inputURL, cache) = try fixture(body: Data(repeating: 0x41,
                count: Int(TARTextPreview.maximumUTF8Bytes) + 1))
            let gate = FileActivityGate(), pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
            let reader = TARArchiveReader(activity: gate, compressedPool: pool)
            let session = try await reader.prepareCompressed(inputURL)
            let page = try await session.page(in: session.root)
            do {
                _ = try await session.selectionForTextPreview(XCTUnwrap(page.items.first?.id))
                XCTFail("Oversize member became previewable")
            } catch {
                XCTAssertEqual(error as? TARTextPreviewFailure, .tooLarge)
            }
            await session.close()
            let drained = await pool.closeAndDrain()
            XCTAssertTrue(drained)
            XCTAssertEqual(gate.activeCount, 0)
        }
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate(), pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(inputURL)
        let page = try await session.page(in: session.root)
        var selected: TARTextPreviewSelection? = try await session.selectionForTextPreview(XCTUnwrap(page.items.first?.id))
        do {
            var witness = selected!.binding.witness; witness[0] ^= 1
            let forgedBinding = TARSourceBinding(source: selected!.binding.source, stamp: selected!.binding.stamp,
                witness: witness, compressed: selected!.binding.compressed)
            let forged = TARTextPreviewSelection(binding: forgedBinding, record: selected!.record)
            do { _ = try await reader.previewText(forged); XCTFail("Forged witness became previewable") }
            catch { XCTAssertEqual(error as? TARArchiveFailure, .changed) }
            let record = selected!.record
            let falseRecord = TARRecord(ordinal: record.ordinal, path: "Other.txt", kind: record.kind,
                headerOffset: record.headerOffset, dataOffset: record.dataOffset, bytes: record.bytes)
            do { _ = try await reader.previewBytes(.init(binding: selected!.binding, record: falseRecord))
                XCTFail("Forged record became previewable") }
            catch { XCTAssertEqual(error as? TARArchiveFailure, .changed) }
        }
        var changed = try Data(contentsOf: inputURL); changed[0] ^= 1
        try changed.write(to: inputURL)
        do { _ = try await reader.previewText(XCTUnwrap(selected)); XCTFail("Changed original became previewable") }
        catch { XCTAssertEqual(error as? TARArchiveFailure, .changed) }
        await session.close(); selected = nil
        await reader.drain()
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testPreparedPreviewCancellationWhilePayloadReadIsHeldPublishesNothing() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate(), pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(inputURL)
        let page = try await session.page(in: session.root)
        var selected: TARTextPreviewSelection? = try await session.selectionForTextPreview(XCTUnwrap(page.items.first?.id))
        await session.close()
        let barrier = PreparationBarrier()
        do {
            let choice = try XCTUnwrap(selected)
            let worker = Task.detached { () throws -> TARTextPreview in
                try TARTextPreviewReader.readChecked(choice, excluding: [], limits: .init(),
                    previewLimits: .init(), check: { try Task.checkCancellation() },
                    probe: { stage, _, _ in
                        if case .previewPayload = stage { barrier.wait() }
                    }, transform: { bytes, check in try TARTextPreview.decode(bytes, check: check) })
            }
            let entered = await Task.detached { barrier.awaitEntry() }.value
            XCTAssertTrue(entered)
            worker.cancel(); barrier.release.signal()
            do { _ = try await worker.value; XCTFail("Cancelled preview returned content") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        selected = nil
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pool.usage.entryCount, 0)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testTrailingGzipGarbageRefusesPreparationAndReleasesReservation() async throws {
        let (inputURL, cache) = try fixture()
        var bytes = try Data(contentsOf: inputURL); bytes.append(0x55)
        try bytes.write(to: inputURL)
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        do {
            _ = try await reader.prepareCompressed(inputURL)
            XCTFail("Trailing data must not become a partial catalog")
        } catch TARArchiveFailure.malformed { }
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pool.usage.entryCount, 0)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testChangedOriginalRefusesPreparedExtraction() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(inputURL)
        var selection: TARExtractionSelection? = try await session.selectionForWholeExtraction()
        var bytes = try Data(contentsOf: inputURL); bytes[16] ^= 1
        try bytes.write(to: inputURL)
        XCTAssertThrowsError(try PreparedTARDirectory(inputURL, selection: selection!, check: {}))
        await session.close(); selection = nil
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
    }

    func testQuiescenceClosesCacheRootAndFreshPreparationReopensIt() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let first = try await reader.prepareCompressed(inputURL)
        await first.close()
        try pool.prepareForQuiescence()
        let drained = await pool.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(gate.activeCount, 0)
        XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: cache.path), [])
        pool.resumeAfterQuiescence()
        let second = try await reader.prepareCompressed(inputURL)
        XCTAssertEqual(second.summary.files, 1)
        await second.close()
        let closed = await pool.closeAndDrain()
        XCTAssertTrue(closed)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testTwoReadersShareOneChargedPreparationUntilBothRelease() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let firstReader = TARArchiveReader(activity: gate, compressedPool: pool)
        let secondReader = TARArchiveReader(activity: gate, compressedPool: pool)
        async let first = firstReader.prepareCompressed(inputURL)
        async let second = secondReader.prepareCompressed(inputURL)
        let (a, b) = try await (first, second)
        XCTAssertEqual(pool.usage.entryCount, 1)
        XCTAssertEqual(pool.usage.reservedBytes, 128 << 20)
        await a.close()
        XCTAssertEqual(b.summary.files, 1)
        await b.close()
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pool.usage.entryCount, 0)
    }

    func testCompressedExtractionUsesOriginalSourceAndUndoAfterSpoolRetires() async throws {
        let (inputURL, cache) = try fixture()
        let root = inputURL.deletingLastPathComponent()
        let parent = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"))
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(inputURL)
        var selection: TARExtractionSelection? = try await session.selectionForWholeExtraction()
        let plan = try await engine.prepareTARExtraction(source: inputURL, parent: parent, name: "Extracted",
            observing: engine.observeSelection([inputURL]), members: selection!)
        XCTAssertEqual(plan.source, inputURL)
        await session.close(); selection = nil
        let outcome = await engine.performArchiveExtraction(plan)
        XCTAssertTrue(outcome.result.disposition == .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Generated.txt")), Data("hello".utf8))
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained, "The operation must release its private spool after it finishes")
        XCTAssertEqual(gate.activeCount, 0)
        let record = try XCTUnwrap(outcome.recordID)
        let undo = await engine.undo(recordID: record)
        XCTAssertTrue(undo.result.disposition == .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        XCTAssertEqual(try Data(contentsOf: inputURL), try gzip(archive()))
    }

    func testCompressedMarkedTARPublishesOriginalMark() async throws {
        let (source, cache) = try fixture()
        let mark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(mark.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        let root = source.deletingLastPathComponent()
        let parent = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
        let gate = FileActivityGate()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate)
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let session = try await reader.prepareCompressed(source)
        var selected: TARExtractionSelection? = try await session.selectionForWholeExtraction()
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"))
        let plan = try await engine.prepareTARExtraction(source: source, parent: parent, name: "Extracted",
            observing: engine.observeSelection([source]), members: selected!)
        await session.close(); selected = nil
        let result = await engine.performArchiveExtraction(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        for target in [plan.destination, plan.destination.appendingPathComponent("Generated.txt")] {
            var actual = Data(count: mark.count)
            XCTAssertEqual(actual.withUnsafeMutableBytes { getxattr(target.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, 0) }, mark.count)
            XCTAssertEqual(actual, mark)
        }
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
    }

    func testMarkedTARRejectsChangedMarkBeforeFirstReceipt() async throws {
        let mark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        let changed = Data("0082;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        for tamper in [false, true] {
            let root = try LocalStorageTestFixtures.directory()
            let source = root.appendingPathComponent("Generated.tar")
            let parent = root.appendingPathComponent("Destination", isDirectory: true)
            try archive().write(to: source, options: .withoutOverwriting)
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
            XCTAssertEqual(mark.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
            let reader = TARArchiveReader(), session = try await reader.open(source)
            let selected = try await session.selectionForWholeExtraction()
            var hooks = TARProductionHooks()
            if tamper {
                hooks.afterSecurityWriteBeforeReceipt = { name, descriptor in
                    guard name == "Generated.txt", changed.withUnsafeBytes({ fsetxattr(descriptor,
                        "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE) }) == 0 else {
                        throw FileOperationFailure.ioFailure
                    }
                }
            }
            let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"))
            let productionHooks = hooks
            let plan = try await engine.prepareArchiveExtraction(source: source, parent: parent, name: "Extracted",
                observing: engine.observeSelection([source]), format: .tar) { check in
                try PreparedTARDirectory(source, selection: selected, check: check, hooks: productionHooks)
            }
            await session.close()
            let result = await engine.performArchiveExtraction(plan)
            if tamper {
                XCTAssertNotEqual(result.result.disposition, .succeeded)
                XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
                let record = try await engine.retentionRecord(recordID: XCTUnwrap(result.recordID))
                XCTAssertEqual(record.state, "needsReview")
                XCTAssertFalse(record.canCleanup)
            } else {
                XCTAssertEqual(result.result.disposition, .succeeded)
                for target in [plan.destination, plan.destination.appendingPathComponent("Generated.txt")] {
                    var actual = Data(count: mark.count)
                    XCTAssertEqual(actual.withUnsafeMutableBytes { getxattr(target.path, "com.apple.quarantine",
                        $0.baseAddress, $0.count, 0, 0) }, mark.count)
                    XCTAssertEqual(actual, mark)
                }
            }
            var original = Data(count: mark.count)
            XCTAssertEqual(original.withUnsafeMutableBytes { getxattr(source.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, 0) }, mark.count)
            XCTAssertEqual(original, mark)
        }
    }

    func testCancelledWaiterKeepsActivityUntilBlockedWorkerActuallyReturns() async throws {
        let (inputURL, cache) = try fixture()
        let gate = FileActivityGate()
        let barrier = PreparationBarrier()
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: gate,
            beforeDecode: { barrier.wait() })
        let reader = TARArchiveReader(activity: gate, compressedPool: pool)
        let task = Task { try await reader.prepareCompressed(inputURL) }
        let entered = await Task.detached { barrier.awaitEntry() }.value
        XCTAssertTrue(entered)
        defer { barrier.release.signal() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation returned a catalog") }
        catch TARArchiveFailure.stopped { }
        XCTAssertGreaterThan(gate.activeCount, 0, "Cancellation must not release the blocked worker")
        XCTAssertEqual(pool.usage.entryCount, 1)
        barrier.release.signal()
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(gate.activeCount, 0)
        XCTAssertEqual(pool.usage.entryCount, 0)
    }
    func testReplacedCacheRootRefusesSpoolWriteWithoutTouchingReplacement() throws {
        let (inputURL, cache) = try fixture()
        let storage = try TARCompressedSpoolStorage(directory: cache)
        try storage.requireNoOrphans()
        let source = try PinnedLocalFileSource(inputURL)
        let security = try ZIPSourceSecurity.extractionWitness(source.descriptor, url: source.url,
                                                                 allowingInheritance: true)
        let proof = TARCompressedOriginalProof(source: source.url, stamp: source.observed, security: .exact(security))
        let moved = cache.deletingLastPathComponent().appendingPathComponent("moved-cache", isDirectory: true)
        try FileManager().moveItem(at: cache, to: moved)
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try storage.prepare(proof, excluding: [], cancellation: .init(),
                                                 progress: { _, _, _ in })) { error in
            XCTAssertEqual(error as? TARArchiveFailure, .changed)
        }
        XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: cache.path), [])
        XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: moved.path), [])
        XCTAssertTrue(storage.closeRoot())
    }
}
