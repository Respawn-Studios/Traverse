import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct DownloadStoreFixture {
    let root: URL
    var pool: URL { root.appendingPathComponent("downloads") }
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_SOURCE"] else {
            root = try LocalStorageTestFixtures.directory()
            return
        }
        let source = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard source.lastPathComponent == "source", source.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification"),
              UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil, source.resolvingSymlinksInPath() == source else { throw RemoteDownloadStorageFailure.unsafe }
        root = source.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func selection(size: UInt64 = 65_537) throws -> SFTPDownloadSelection {
        try .init(generation: UUID(), row: .init(observation: 2, entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)),
            logicalBytes: size, modifiedSeconds: 19, permissions: 0o100644)))
    }
    func folder(_ file: RemoteDownloadedFile) -> URL { pool.appendingPathComponent("download-" + file.id.uuidString) }
    func fill(_ file: RemoteDownloadedFile, data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 32768)
            try await file.append(request: file.selection.request, offset: UInt64(offset), bytes: data.subdata(in: offset..<end)); offset = end
        }
    }
}
final class RemoteDownloadStoreTests: XCTestCase, @unchecked Sendable {
    func testUnknownMarkerFieldsCannotBeReinterpretedForDiscard() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), file = try await store.reserve(fixture.selection(size: 0))
        let marker = fixture.folder(file).appendingPathComponent("session.meta")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]); fields["unknown"] = true
        let modified = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]); try modified.write(to: marker)
        await file.abandon(); do { try await store.discardIncomplete(file.id); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), modified)
        XCTAssertTrue(FileManager().fileExists(atPath: fixture.folder(file).appendingPathComponent("payload").path))
    }
    func testPartialWriteAndSyncFailuresKeepIncompleteFilesAndCannotPublish() async throws {
        for writeFailure in [true, false] {
            let fixture = try DownloadStoreFixture(), selection = try fixture.selection(size: 100)
            let store = try RemoteDownloadStore(directory: fixture.pool,
                hooks: .init(failWriteAfterBytes: writeFailure ? 17 : nil, failSync: !writeFailure))
            let file = try await store.reserve(selection), bytes = Data(repeating: 7, count: 100)
            if writeFailure {
                do { try await file.append(request: selection.request, offset: 0, bytes: bytes); XCTFail() }
                catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .io(ENOSPC)) }
            } else {
                try await file.append(request: selection.request, offset: 0, bytes: bytes)
                do { _ = try await file.seal(.init(selection: selection, receivedBytes: 100)); XCTFail() }
                catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .io(EIO)) }
            }
            do { _ = try await file.verifiedSource(); XCTFail() } catch {}
            await file.abandon(); let records = try await store.inspect(); XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active)
            XCTAssertEqual(try Data(contentsOf: fixture.folder(file).appendingPathComponent("payload")), Data(repeating: 7, count: writeFailure ? 17 : 100))
        }
    }
    func testPassiveInspectionCreatesNoStorage() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool)
        let initial = try await store.inspect(); XCTAssertTrue(initial.isEmpty); XCTAssertFalse(FileManager().fileExists(atPath: fixture.pool.path))
    }
    func testExactChunksSealRereadAndCleanDrainRemoveOnlyTheOwnedStore() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), selection = try fixture.selection()
        let file = try await store.reserve(selection), generated = Data((0..<65_537).map { UInt8($0 % 251) })
        try await fixture.fill(file, data: generated)
        let digest = try await file.seal(.init(selection: selection, receivedBytes: 65_537))
        XCTAssertEqual(digest, Data(SHA256.hash(data: generated)))
        let source = try await file.verifiedSource(); XCTAssertEqual(try Data(contentsOf: source), generated)
        let records = try await store.inspect(); XCTAssertEqual(records.count, 1); XCTAssertTrue(records[0].active)
        try await file.removeAfterDrain(); let empty = try await store.inspect(); XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: fixture.pool.path), ["pool.lock"])
    }
    func testZeroLengthFileNeedsReceiptAndQuarantineBeforeSealing() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), selection = try fixture.selection(size: 0)
        let file = try await store.reserve(selection)
        do { _ = try await file.verifiedSource(); XCTFail() } catch {}
        let digest = try await file.seal(.init(selection: selection, receivedBytes: 0)); XCTAssertEqual(digest, Data(SHA256.hash(data: Data())))
        let source = try await file.verifiedSource()
        XCTAssertNotNil(try source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        await file.abandon(); let records = try await store.inspect(); XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active)
        try await store.discardIncomplete(file.id)
    }
    func testWrongOffsetsRequestsSizesAndChunkBoundsCannotBeResumed() async throws {
        for variant in 0..<4 {
            let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), selection = try fixture.selection(size: 1)
            let file = try await store.reserve(selection)
            do { try await file.append(request: variant == 0 ? UUID() : selection.request, offset: variant == 1 ? 1 : 0,
                bytes: Data(repeating: 7, count: variant == 2 ? 2 : variant == 3 ? 32769 : 1)); XCTFail() } catch {}
            do { try await file.append(request: selection.request, offset: 0, bytes: Data([7])); XCTFail() } catch {}
            await file.abandon(); let records = try await store.inspect(); XCTAssertFalse(records[0].active); try await store.discardIncomplete(file.id)
        }
    }
    func testWrongOrEarlySourceReceiptNeverPublishesASealedSource() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), selection = try fixture.selection(size: 1)
        let file = try await store.reserve(selection)
        do { _ = try await file.seal(.init(selection: selection, receivedBytes: 1)); XCTFail() } catch {}
        do { _ = try await file.verifiedSource(); XCTFail() } catch {}
        await file.abandon(); XCTAssertTrue(FileManager().fileExists(atPath: fixture.folder(file).appendingPathComponent("payload").path))
    }
    func testLocalContentChangeFailsRereadAndPostSealChangesInvalidateTheSource() async throws {
        for beforeSeal in [true, false] {
            let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), selection = try fixture.selection(size: 1)
            let file = try await store.reserve(selection); try await fixture.fill(file, data: Data([7]))
            if !beforeSeal { _ = try await file.seal(.init(selection: selection, receivedBytes: 1)) }
            let url = fixture.folder(file).appendingPathComponent("payload"), fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(pwrite(fd, [UInt8(8)], 1, 0), 1); close(fd)
            if beforeSeal { do { _ = try await file.seal(.init(selection: selection, receivedBytes: 1)); XCTFail() } catch {} }
            do { _ = try await file.verifiedSource(); XCTFail() } catch {}
            await file.abandon(); XCTAssertEqual(try Data(contentsOf: url), Data([8]))
        }
    }
    func testIndependentOwnersRespectTwoActiveLeasesAndExplicitIncompleteDiscard() async throws {
        let fixture = try DownloadStoreFixture(), first = try RemoteDownloadStore(directory: fixture.pool), second = try RemoteDownloadStore(directory: fixture.pool)
        let a = try await first.reserve(fixture.selection(size: 0)), b = try await second.reserve(fixture.selection(size: 0))
        do { _ = try await second.reserve(fixture.selection(size: 0)); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .capacity) }
        do { try await first.discardIncomplete(a.id); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
        await a.abandon(); try await second.discardIncomplete(a.id)
        let c = try await second.reserve(fixture.selection(size: 0)); await b.abandon(); await c.abandon()
        try await first.discardIncomplete(b.id); try await first.discardIncomplete(c.id)
        let empty = try await first.inspect(); XCTAssertTrue(empty.isEmpty)
    }
    func testUnknownFilesPreventDiscardAndRemainUntouched() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), file = try await store.reserve(fixture.selection(size: 0))
        let unknown = fixture.folder(file).appendingPathComponent("Unrecognized.txt"); try Data("Generated unknown".utf8).write(to: unknown)
        await file.abandon()
        do { try await store.discardIncomplete(file.id); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: unknown), Data("Generated unknown".utf8))
        XCTAssertTrue(FileManager().fileExists(atPath: fixture.folder(file).appendingPathComponent("payload").path))
    }
    func testChangedOwnershipMarkerAndRenamedPoolPreventRemoval() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool), file = try await store.reserve(fixture.selection(size: 0))
        let marker = fixture.folder(file).appendingPathComponent("session.meta"); try Data("Generated invalid marker".utf8).write(to: marker)
        do { try await file.removeAfterDrain(); XCTFail() } catch {}
        await file.abandon(); do { try await store.discardIncomplete(file.id); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), Data("Generated invalid marker".utf8))
        let another = try DownloadStoreFixture(), owner = try RemoteDownloadStore(directory: another.pool), pending = try await owner.reserve(another.selection(size: 1))
        let retained = another.root.appendingPathComponent("Retained")
        try FileManager().moveItem(at: another.pool, to: retained)
        try FileManager().createDirectory(at: another.pool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try await pending.append(request: pending.selection.request, offset: 0, bytes: Data([7])); XCTFail() } catch {}
        await pending.abandon(); XCTAssertTrue(FileManager().fileExists(atPath: retained.appendingPathComponent("download-" + pending.id.uuidString).appendingPathComponent("payload").path))
    }
    func testDeinitDoesNotDeleteIncompletePayloadAndLeaseEventuallyEnds() async throws {
        let fixture = try DownloadStoreFixture(), store = try RemoteDownloadStore(directory: fixture.pool)
        var file: RemoteDownloadedFile? = try await store.reserve(fixture.selection(size: 1)); let id = try XCTUnwrap(file?.id)
        try await file?.append(request: try XCTUnwrap(file?.selection.request), offset: 0, bytes: Data([7])); file = nil
        var inactive = false
        for _ in 0..<200 {
            let records = try await store.inspect()
            if records.count == 1, !records[0].active { inactive = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(inactive); XCTAssertTrue(FileManager().fileExists(atPath: fixture.pool.appendingPathComponent("download-" + id.uuidString).appendingPathComponent("payload").path))
        try await store.discardIncomplete(id)
    }
}
