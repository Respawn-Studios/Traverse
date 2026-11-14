import CoreServices
import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import XCTest
import zlib
@_spi(ArchiveProduction) @_spi(Qualification) @testable import FileOperations
@testable import LocalStorage

private struct PublicTARTreeFixture {
    let root: URL, source: URL, parent: URL, journal: URL, cache: URL
    let compressed: Bool

    init(compressed: Bool = false, marked: Bool = true) throws {
        root = try LocalStorageTestFixtures.directory()
        self.compressed = compressed
        source = root.appendingPathComponent(compressed ? "Generated.tar.gz" : "Generated.tar")
        parent = root.appendingPathComponent("Destination", isDirectory: true)
        journal = root.appendingPathComponent("history", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let bytes = Self.archive()
        try (compressed ? Self.gzip(bytes) : bytes).write(to: source, options: .withoutOverwriting)
        if marked {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "Generated TAR tree test",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var archive = source
            try archive.setResourceValues(values)
        }
    }

    func engine(publicTree: Bool, hooks: RecoveryHooks = .init()) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks,
            tarTreePublicExtractionPolicy: publicTree ? .sourceQualification : .held)
    }

    func selection(folder: Bool = false) async throws -> (TARExtractionSelection, TARCompressedPreparationPool?) {
        let pool = compressed ? TARCompressedPreparationPool(cacheDirectory: cache, activity: FileActivityGate()) : nil
        let reader = TARArchiveReader(compressedPool: pool)
        let session = try await (compressed ? reader.prepareCompressed(source, publicQuarantineSource: true) : reader.open(source))
        let selected: TARExtractionSelection
        if folder {
            let page = try await session.page(in: session.root)
            let item = try XCTUnwrap(page.items.first(where: { $0.name == "Folder" }))
            selected = try await session.selectionForExtraction([item.id])
        } else { selected = try await session.selectionForWholeExtraction() }
        await session.close()
        return (selected, pool)
    }

    func plan(_ engine: RecoverableFileOperations, _ selection: TARExtractionSelection,
        name: String = "Public", directly: Bool = false) async throws -> ArchiveExtractionPlan {
        try await engine.prepareTARExtraction(source: source, parent: parent, name: name,
            observing: engine.observeSelection([source]), members: selection,
            directly: directly, publicQuarantineTreeV16: true)
    }

    func preparedPlan(_ engine: RecoverableFileOperations, folder: Bool = false,
        name: String = "Public", directly: Bool = false) async throws
        -> (ArchiveExtractionPlan, TARCompressedPreparationPool?) {
        let (selection, pool) = try await selection(folder: folder)
        return (try await plan(engine, selection, name: name, directly: directly), pool)
    }

    private static func archive() -> Data {
        func member(_ path: String, data: Data, directory: Bool = false) -> Data {
            var header = Data(repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) {
                header.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
            }
            put(path, at: 0)
            put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
            put(String(format: "%011o", data.count) + "\0", at: 124)
            put("00000000000\0", at: 136)
            for index in 148..<156 { header[index] = 32 }
            header[156] = directory ? 53 : 48
            put("ustar\0", at: 257); put("00", at: 263)
            put(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), at: 148)
            var result = header
            result.append(data)
            result.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
            return result
        }
        var result = member("Folder/Report.txt", data: Data("Fixture".utf8))
        result.append(member("Empty/", data: Data(), directory: true))
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    private static func gzip(_ input: Data) throws -> Data {
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
}

final class TARPublicTreeV16Tests: XCTestCase, @unchecked Sendable {
    func testMarkedPlainTreeNeedsOwnGateAndColdUndoChecksEveryNode() async throws {
        let f = try PublicTARTreeFixture()
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        let (selection, _) = try await f.selection()
        do { _ = try await f.plan(f.engine(publicTree: false), selection); XCTFail("held TAR tree was admitted") }
        catch {}
        let engine = f.engine(publicTree: true), plan = try await f.plan(engine, selection)
        let made = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .tarExtraction(sourceMarked: true))
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.nodeCount, 4)
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.requiresEveryNode, true)
        } else { XCTFail("TAR tree did not retain its typed purpose") }
        let typed = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(typed.version, 16)
        XCTAssertEqual(typed.purpose, "tarTree")
        XCTAssertEqual(typed.state, "committed")
        XCTAssertTrue(typed.requiresPublicQuarantine)
        for path in ["", "Folder", "Folder/Report.txt", "Empty"] {
            let url = path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path)
            XCTAssertNotNil(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        }
        let enabled = try await f.engine(publicTree: true).inspectExistingHistory()
        XCTAssertTrue(enabled.records.contains { $0.id == id && $0.canUndo })
        let held = try await f.engine(publicTree: false).inspectExistingHistory()
        XCTAssertFalse(held.records.first(where: { $0.id == id })?.canUndo ?? true)
        let cold = f.engine(publicTree: true)
        let inverse = await cold.undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
        let after = try await cold.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(after.state, "undone")
        XCTAssertEqual(after.purpose, typed.purpose)
        XCTAssertEqual(after.requiresPublicQuarantine, typed.requiresPublicQuarantine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testMarkedCompressedSelectedFolderRetainsOriginalProofAndRetiresSpool() async throws {
        let f = try PublicTARTreeFixture(compressed: true)
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        let engine = f.engine(publicTree: true)
        let (plan, pool) = try await f.preparedPlan(engine, folder: true, name: "Selected", directly: true)
        let made = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Report.txt")), Data("Fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent("Folder").path))
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .tarExtraction(sourceMarked: true))
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.nodeCount, 2)
        } else { XCTFail("compressed TAR folder used the wrong history purpose") }
        let drained = await pool?.closeAndDrain()
        XCTAssertEqual(drained, true)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testCompressedProofContractsCannotCrossIntoTheOtherProducer() async throws {
        let f = try PublicTARTreeFixture(compressed: true)
        let pool = TARCompressedPreparationPool(cacheDirectory: f.cache, activity: FileActivityGate())
        do {
            let reader = TARArchiveReader(compressedPool: pool)
            let session = try await reader.prepareCompressed(f.source)
            let selection = try await session.selectionForWholeExtraction()
            await session.close()
            XCTAssertThrowsError(try PreparedTARDirectory(f.source, selection: selection,
                check: {}, publicQuarantineTree: true)) { error in
                XCTAssertEqual(error as? FileOperationFailure, .sourceChanged)
            }
        }
        do {
            let reader = TARArchiveReader(compressedPool: pool)
            let session = try await reader.prepareCompressed(f.source, publicQuarantineSource: true)
            let selection = try await session.selectionForWholeExtraction()
            await session.close()
            XCTAssertThrowsError(try PreparedTARDirectory(f.source, selection: selection,
                check: {})) { error in
                XCTAssertEqual(error as? FileOperationFailure, .sourceChanged)
            }
        }
        let drained = await pool.closeAndDrain()
        XCTAssertTrue(drained)
    }

    func testUnmarkedPlainAndCompressedTreesRetainSourceFact() async throws {
        for compressed in [false, true] {
            let f = try PublicTARTreeFixture(compressed: compressed, marked: false)
            let engine = f.engine(publicTree: true)
            let (plan, pool) = try await f.preparedPlan(engine)
            let made = await engine.performArchiveExtraction(plan)
            let id = try XCTUnwrap(made.recordID)
            XCTAssertEqual(made.result.disposition, .succeeded)
            if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
                f.journal, id: id, cancellation: .init()) {
                XCTAssertEqual(record.producedTreeV16, .tarExtraction(sourceMarked: false))
                XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.requiresEveryNode, false)
            } else { XCTFail("unmarked TAR source fact missing") }
            if let pool { let drained = await pool.closeAndDrain(); XCTAssertTrue(drained) }
            let inverse = await f.engine(publicTree: true).undo(recordID: id)
            XCTAssertEqual(inverse.result.disposition, .succeeded)
        }
    }

    func testLostDescendantMarkRefusesPublication() async throws {
        let f = try PublicTARTreeFixture()
        let (selection, _) = try await f.selection()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .receiptsChecked {
                guard removexattr(payload.appendingPathComponent("Folder/Report.txt").path,
                    "com.apple.quarantine", 0) == 0 else { throw FileOperationFailure.ioFailure }
            }
        }
        let failing = f.engine(publicTree: true, hooks: hooks)
        let withheld = try await f.plan(failing, selection)
        let refused = await failing.performArchiveExtraction(withheld)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: withheld.destination.path))
    }

    func testColdUndoRefusesLostDescendantMarkWithoutRemovingOutput() async throws {
        let f = try PublicTARTreeFixture()
        let engine = f.engine(publicTree: true)
        let (plan, _) = try await f.preparedPlan(engine)
        let made = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        let child = plan.destination.appendingPathComponent("Folder/Report.txt")
        XCTAssertEqual(removexattr(child.path, "com.apple.quarantine", 0), 0)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertNotEqual(inverse.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: child), Data("Fixture".utf8))
    }

    func testCompressedOriginalMarkChangeBeforePublicationRefusesWithoutOutput() async throws {
        let f = try PublicTARTreeFixture(compressed: true)
        let engine = f.engine(publicTree: true)
        let (plan, pool) = try await f.preparedPlan(engine)
        XCTAssertEqual(removexattr(f.source.path, "com.apple.quarantine", 0), 0)
        let refused = await engine.performArchiveExtraction(plan)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        if let pool { let drained = await pool.closeAndDrain(); XCTAssertTrue(drained) }
    }
}
