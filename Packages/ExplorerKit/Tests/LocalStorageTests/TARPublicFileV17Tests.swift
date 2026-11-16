import CoreServices
import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import XCTest
import zlib
@_spi(ArchiveProduction) @_spi(ArchiveFixtureOperations) @_spi(Qualification) @testable import FileOperations
@testable import LocalStorage

private struct PublicTARFileFixture {
    let root: URL, source: URL, parent: URL, journal: URL, cache: URL
    let compressed: Bool

    init(compressed: Bool = false, marked: Bool = true, signedFixture: Bool = false,
         body: Data = Data("Fixture".utf8)) throws {
        root = try LocalStorageTestFixtures.directory()
        self.compressed = compressed
        let fixture = root.appendingPathComponent("source/Operation Root", isDirectory: true)
        let input = signedFixture ? fixture : root
        source = input.appendingPathComponent(compressed ? "Generated.tar.gz" : "Generated.tar")
        parent = input.appendingPathComponent("Destination", isDirectory: true)
        journal = signedFixture ? root.appendingPathComponent("source/Library/operation-recovery", isDirectory: true)
            : root.appendingPathComponent("history", isDirectory: true)
        cache = signedFixture ? root.appendingPathComponent("source/Library/cache", isDirectory: true)
            : root.appendingPathComponent("cache", isDirectory: true)
        if signedFixture {
            for path in [root.appendingPathComponent("source", isDirectory: true), fixture,
                         root.appendingPathComponent("source/Library", isDirectory: true)] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let bytes = Self.archive(body: body)
        try (compressed ? Self.gzip(bytes) : bytes).write(to: source, options: .withoutOverwriting)
        if marked {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "Generated TAR file test",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var archive = source
            try archive.setResourceValues(values)
        }
    }

    func engine(publicFile: Bool, hooks: RecoveryHooks = .init()) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks,
            tarOneFilePublicExtractionPolicy: publicFile ? .sourceQualification : .held)
    }
    func signedEngine(_ phase: ArchiveFixturePhase) throws -> RecoverableFileOperations {
        let baselineBytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard baselineBytes > 0 else { throw FileOperationFailure.invalidRequest }
        return .init(journalDirectory: journal, protecting: [], activity: nil,
            tarOneFilePublicExtractionPolicy: .sourceQualification, tarTreePublicExtractionPolicy: .held,
            archiveFixtureRoot: root.appendingPathComponent("source/Operation Root", isDirectory: true),
            archiveFixturePhase: phase, archiveFixtureOperations: .publicTARExtraction,
            archiveFixtureBaselineBytes: UInt64(baselineBytes))
    }

    func plan(_ engine: RecoverableFileOperations, name: String = "Report.txt", signed: Bool = false) async throws
        -> (ReceivedFilePlan, TARCompressedPreparationPool?) {
        let pool = compressed ? TARCompressedPreparationPool(cacheDirectory: cache, activity: FileActivityGate()) : nil
        let reader = TARArchiveReader(compressedPool: pool)
        let session = try await (compressed ? reader.prepareCompressed(source, publicQuarantineSource: true) : reader.open(source))
        let page = try await session.page(in: session.root)
        let item = try XCTUnwrap(page.items.first(where: { $0.name == "Generated.txt" }))
        let selection = try await session.selectionForExtraction([item.id])
        let observed = try await (signed
            ? engine.checkTARPromiseDestination(source: source, parent: parent, name: name)
            : engine.checkReceivedFileDestination(parent: parent, name: name))
        let plan: ReceivedFilePlan
        do {
            plan = try await engine.prepareTARFilePublicExtraction(selection, parent: parent, name: name,
                observing: observed)
        } catch {
            await session.close()
            _ = await pool?.closeAndDrain()
            throw error
        }
        await session.close()
        return (plan, pool)
    }

    private static func archive(body: Data) -> Data {
        var header = Data(repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            header.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
        }
        put("Generated.txt", at: 0)
        put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
        put(String(format: "%011o", body.count) + "\0", at: 124); put("00000000000\0", at: 136)
        for index in 148..<156 { header[index] = 32 }
        header[156] = 48; put("ustar\0", at: 257); put("00", at: 263)
        put(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), at: 148)
        var bytes = header
        bytes.append(body)
        bytes.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        bytes.append(Data(repeating: 0, count: 1024))
        return bytes
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

final class TARPublicFileV17Tests: XCTestCase, @unchecked Sendable {
    func testSignedPromiseProfileRejectsCompressedOversizeBeforePublication() async throws {
        let f = try PublicTARFileFixture(compressed: true, signedFixture: true,
            body: Data(repeating: 0x41, count: (1 << 20) + 1))
        XCTAssertLessThan(try Data(contentsOf: f.source).count, 1 << 20)
        let warm = try f.signedEngine(.warmForward)
        do {
            _ = try await f.plan(warm, signed: true)
            XCTFail("oversized compressed member entered signed promise plan")
        } catch {
            XCTAssertEqual(error as? FileOperationFailure, .unsupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.parent.appendingPathComponent("Report.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
    }

    func testSignedPromiseProfileAdmitsOnlyGeneratedFileAndColdUndo() async throws {
        let f = try PublicTARFileFixture(signedFixture: true)
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        let warm = try f.signedEngine(.warmForward)
        do {
            _ = try await warm.checkReceivedFileDestination(parent: f.parent, name: "Report.txt")
            XCTFail("generic receiver preflight entered signed promise fixture")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let outside = f.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        do {
            _ = try await warm.checkTARPromiseDestination(source: f.source, parent: outside, name: "Report.txt")
            XCTFail("signed promise preflight escaped fixture")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .invalidRequest) }
        let (plan, _) = try await f.plan(warm, signed: true)
        XCTAssertEqual(plan.destination, f.parent.appendingPathComponent("Report.txt"))
        let made = await warm.performReceivedFile(plan)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
        XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        let catalog = try await warm.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(catalog.version, 17)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
        let cold = try f.signedEngine(.coldInverse)
        do {
            _ = try await cold.checkTARPromiseDestination(source: f.source, parent: f.parent, name: "Other.txt")
            XCTFail("cold promise preflight admitted new work")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let undone = await cold.undo(recordID: id)
        XCTAssertEqual(undone.result.disposition, .succeeded, "\(undone.result.items.map(\.status))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testMarkedPlainFileNeedsOwnGateAndColdUndo() async throws {
        let f = try PublicTARFileFixture()
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        let held = f.engine(publicFile: false)
        let reader = TARArchiveReader(), session = try await reader.open(f.source)
        let page = try await session.page(in: session.root)
        let member = try XCTUnwrap(page.items.first)
        let selection = try await session.selectionForExtraction([member.id])
        let observed = try await held.checkReceivedFileDestination(parent: f.parent, name: "Report.txt")
        do {
            _ = try await held.prepareTARFilePublicExtraction(selection, parent: f.parent,
                name: "Report.txt", observing: observed)
            XCTFail("held TAR file was admitted")
        } catch {}
        await session.close()
        let engine = f.engine(publicFile: true)
        let (plan, _) = try await f.plan(engine)
        let made = await engine.performReceivedFile(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
        XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        if case .publicTARExtractionFileV17(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.version, 17)
            XCTAssertEqual(record.operation, "Extract TAR")
            XCTAssertEqual(record.steps.first?.publicTARExtractionMarkRequired, true)
            XCTAssertNil(record.steps.first?.publicZIPExtractionMarkRequired)
        } else { XCTFail("TAR file used the wrong history protocol") }
        let typed = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(typed.recordID, id)
        XCTAssertEqual(typed.version, 17)
        XCTAssertEqual(typed.purpose, "tarFile")
        XCTAssertEqual(typed.state, "committed")
        XCTAssertTrue(typed.requiresPublicQuarantine)
        XCTAssertEqual(try JSONDecoder().decode(GeneratedPublicCatalogObservation.self,
            from: JSONEncoder().encode(typed)), typed)
        do {
            _ = try await engine.inspectGeneratedPublicCatalog(recordID: UUID())
            XCTFail("Unknown catalog ID was disclosed")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .notFound) }
        let enabled = try await f.engine(publicFile: true).inspectExistingHistory()
        XCTAssertTrue(enabled.records.contains { $0.id == id && $0.canUndo })
        let disabled = try await f.engine(publicFile: false).inspectExistingHistory()
        XCTAssertFalse(disabled.records.first(where: { $0.id == id })?.canUndo ?? true)
        let retention = try await engine.retentionRecord(recordID: id)
        XCTAssertFalse(retention.canCleanup)
        let cold = f.engine(publicFile: true)
        let inverse = await cold.undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
        let after = try await cold.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(after.state, "undone")
        XCTAssertEqual(after.version, typed.version)
        XCTAssertEqual(after.purpose, typed.purpose)
        XCTAssertEqual(after.requiresPublicQuarantine, typed.requiresPublicQuarantine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testMarkedCompressedFileUsesOriginalAndRetiresSpoolBeforeColdUndo() async throws {
        let f = try PublicTARFileFixture(compressed: true)
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        let engine = f.engine(publicFile: true)
        let (plan, pool) = try await f.plan(engine)
        let made = await engine.performReceivedFile(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        if case .publicTARExtractionFileV17(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.steps.first?.publicTARExtractionMarkRequired, true)
        } else { XCTFail("compressed TAR file used the wrong history protocol") }
        let drained = await pool?.closeAndDrain()
        XCTAssertEqual(drained, true)
        let inverse = await f.engine(publicFile: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testUnmarkedPlainAndCompressedFilesRetainFalseMarkRequirement() async throws {
        for compressed in [false, true] {
            let f = try PublicTARFileFixture(compressed: compressed, marked: false)
            let engine = f.engine(publicFile: true)
            let (plan, pool) = try await f.plan(engine)
            let made = await engine.performReceivedFile(plan)
            let id = try XCTUnwrap(made.recordID)
            XCTAssertEqual(made.result.disposition, .succeeded)
            if case .publicTARExtractionFileV17(let record) = try OperationHistoryInspector.record(
                f.journal, id: id, cancellation: .init()) {
                XCTAssertEqual(record.steps.first?.publicTARExtractionMarkRequired, false)
            } else { XCTFail("unmarked TAR file used the wrong history protocol") }
            if let pool { let drained = await pool.closeAndDrain(); XCTAssertTrue(drained) }
            let inverse = await f.engine(publicFile: true).undo(recordID: id)
            XCTAssertEqual(inverse.result.disposition, .succeeded)
        }
    }

    func testStageMarkLossRefusesBeforePublication() async throws {
        let f = try PublicTARFileFixture()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .receiptsChecked {
                guard removexattr(payload.path, "com.apple.quarantine", 0) == 0 else {
                    throw FileOperationFailure.ioFailure
                }
            }
        }
        let engine = f.engine(publicFile: true, hooks: hooks)
        let (plan, _) = try await f.plan(engine)
        let refused = await engine.performReceivedFile(plan)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testColdUndoRefusesLostMarkAndPreservesOutput() async throws {
        let f = try PublicTARFileFixture(), engine = f.engine(publicFile: true)
        let (plan, _) = try await f.plan(engine)
        let made = await engine.performReceivedFile(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        XCTAssertEqual(removexattr(plan.destination.path, "com.apple.quarantine", 0), 0)
        let inverse = await f.engine(publicFile: true).undo(recordID: id)
        XCTAssertNotEqual(inverse.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
    }

    func testInterruptedPublicationKeepsDirectRecoveryHeld() async throws {
        let f = try PublicTARFileFixture()
        let destination = f.parent.appendingPathComponent("Report.txt")
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            if url == destination { throw FileOperationFailure.ioFailure }
        }
        let engine = f.engine(publicFile: true, hooks: hooks)
        let (plan, _) = try await f.plan(engine)
        let interrupted = await engine.performReceivedFile(plan)
        let id = try XCTUnwrap(interrupted.recordID)
        XCTAssertNotEqual(interrupted.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), Data("Fixture".utf8))

        let cold = f.engine(publicFile: true)
        let before = try await cold.inspectExistingHistory()
        XCTAssertEqual(before.records.first(where: { $0.id == id })?.state, "needsReview")
        XCTAssertFalse(before.records.first(where: { $0.id == id })?.canRecover ?? true)
        let recovery = await cold.recover(recordID: id)
        XCTAssertEqual(recovery.result.items.first?.status, .failed(.unsupported))
        XCTAssertEqual(try Data(contentsOf: destination), Data("Fixture".utf8))
        let after = try await cold.inspectExistingHistory()
        XCTAssertEqual(after.records.first(where: { $0.id == id })?.state, "needsReview")
    }

    func testCompressedOriginalMarkChangeBeforePublicationRefuses() async throws {
        let f = try PublicTARFileFixture(compressed: true)
        let engine = f.engine(publicFile: true)
        let (plan, pool) = try await f.plan(engine)
        XCTAssertEqual(removexattr(f.source.path, "com.apple.quarantine", 0), 0)
        let refused = await engine.performReceivedFile(plan)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        let drained = await pool?.closeAndDrain()
        XCTAssertEqual(drained, true)
    }
}
