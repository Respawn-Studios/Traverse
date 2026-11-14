import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct TemporaryCatalogFixture {
    let root: URL
    var pool: URL { root.appendingPathComponent("pool") }
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B10_COMPLETION_SOURCE"] else {
            throw XCTSkip("Use tools/smb_reader/qualify_runtime_storage.py for charged generated fixtures")
        }
        let base = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard base.path.hasPrefix(repo.appendingPathComponent(".build/b10-completion-qualification/").path),
              base.resolvingSymlinksInPath() == base, base.lastPathComponent == "source" else { throw SMBTemporaryStorageFailure.unsafe }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func owner(limit: UInt64 = SMBTemporaryStorage.maximumPoolBytes) throws -> SMBTemporaryCatalogPool {
        SMBTemporaryCatalogPool(storage: try SMBTemporaryStorage(directory: pool, sessionByteLimit: 2 << 20, poolByteLimit: limit))
    }
    func contents(_ url: URL) throws -> [String] { try FileManager().contentsOfDirectory(atPath: url.path).sorted() }
}

final class SMBTemporaryCatalogTests: XCTestCase, @unchecked Sendable {
    func testPassiveInspectionDoesNotCreatePoolOrUnrecognizedState() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner()
        let empty = try await owner.inspect(); XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.pool.path))
        try FileManager().createDirectory(at: fixture.pool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unknown = fixture.pool.appendingPathComponent("unowned.txt")
        try Data("Generated evidence".utf8).write(to: unknown)
        do { _ = try await owner.inspect(); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: unknown), Data("Generated evidence".utf8))
        XCTAssertEqual(try fixture.contents(fixture.pool), ["unowned.txt"])
    }
    func testLiveReservationsAreChargedAcrossIndependentOwnersAndCleanCloseReleasesThem() async throws {
        let fixture = try TemporaryCatalogFixture(), first = try fixture.owner(limit: 1 << 30), second = try fixture.owner(limit: 1 << 30)
        let a = try await first.reserve(), b = try await second.reserve()
        let live = try await first.inspect()
        XCTAssertEqual(live.count, 2); XCTAssertTrue(live.allSatisfy(\.active))
        do { _ = try await second.reserve(); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .capacity) }
        let closedA = await a.finishWithoutWorker(); XCTAssertTrue(closedA)
        let c = try await second.reserve()
        let closedB = await b.finishWithoutWorker(), closedC = await c.finishWithoutWorker()
        XCTAssertTrue(closedB); XCTAssertTrue(closedC)
        let final = try await first.inspect(); XCTAssertTrue(final.isEmpty)
        XCTAssertEqual(try fixture.contents(fixture.pool), ["pool.lock"])
    }
    func testDiscardRefusesActiveSessionThenExplicitlyRemovesAnIncompleteOwnedStore() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner(), value = try await owner.reserve()
        do { try await owner.discardIncomplete(value.id); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .busy) }
        let preserved = await Task.detached { value.files.finish(clean: false) }.value
        XCTAssertFalse(preserved)
        let incomplete = try await owner.inspect(); XCTAssertEqual(incomplete.count, 1); XCTAssertFalse(incomplete[0].active)
        let journal = value.path.deletingLastPathComponent().appendingPathComponent("catalog.sqlite-journal")
        try Data("Generated interrupted journal".utf8).write(to: journal, options: .withoutOverwriting)
        XCTAssertEqual(chmod(journal.path, 0o600), 0)
        try await owner.discardIncomplete(value.id)
        let final = try await owner.inspect(); XCTAssertTrue(final.isEmpty)
    }
    func testUnexpectedEntryPreservesWholeSessionAndNeverDeletesUnknownFile() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner(), value = try await owner.reserve()
        let unexpected = value.path.deletingLastPathComponent().appendingPathComponent("unrecognized.txt")
        let evidence = Data("Generated unknown file".utf8); try evidence.write(to: unexpected)
        let cleaned = await value.finishWithoutWorker(); XCTAssertFalse(cleaned)
        do { try await owner.discardIncomplete(value.id); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertEqual(try Data(contentsOf: unexpected), evidence)
        XCTAssertTrue(FileManager().fileExists(atPath: value.path.path))
    }
    func testReplacedCatalogAndHardLinkAreRefusedWithoutChangingEitherEntry() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner(), value = try await owner.reserve()
        let retained = fixture.root.appendingPathComponent("retained.sqlite")
        try FileManager().moveItem(at: value.path, to: retained)
        try Data("Generated replacement".utf8).write(to: value.path, options: .withoutOverwriting)
        XCTAssertEqual(chmod(value.path.path, 0o600), 0)
        let cleaned = await value.finishWithoutWorker(); XCTAssertFalse(cleaned)
        XCTAssertEqual(try Data(contentsOf: value.path), Data("Generated replacement".utf8))
        XCTAssertTrue(FileManager().fileExists(atPath: retained.path))
        let second = try await owner.reserve(), alias = fixture.root.appendingPathComponent("alias.sqlite")
        XCTAssertEqual(link(second.path.path, alias.path), 0)
        let removed = await second.finishWithoutWorker(); XCTAssertFalse(removed)
        do { try await owner.discardIncomplete(second.id); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertTrue(FileManager().fileExists(atPath: alias.path)); XCTAssertTrue(FileManager().fileExists(atPath: second.path.path))
    }
    func testRedirectedPoolAndChangedMarkerRefuseCleanup() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner(), value = try await owner.reserve()
        let retained = fixture.root.appendingPathComponent("retained-pool")
        try FileManager().moveItem(at: fixture.pool, to: retained)
        try FileManager().createSymbolicLink(at: fixture.pool, withDestinationURL: retained)
        let cleaned = await value.finishWithoutWorker(); XCTAssertFalse(cleaned)
        do { _ = try await owner.inspect(); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertTrue(FileManager().fileExists(atPath: retained.appendingPathComponent("session-" + value.id.uuidString).appendingPathComponent("catalog.sqlite").path))
        let other = try TemporaryCatalogFixture(), otherOwner = try other.owner(), otherValue = try await otherOwner.reserve()
        let marker = otherValue.path.deletingLastPathComponent().appendingPathComponent("session.meta")
        try Data("Generated incompatible marker\n".utf8).write(to: marker)
        let removed = await otherValue.finishWithoutWorker(); XCTAssertFalse(removed)
        do { try await otherOwner.discardIncomplete(otherValue.id); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertTrue(FileManager().fileExists(atPath: otherValue.path.path))
    }
    func testPendingJournalIsNotAutomaticallyRemovedOnCleanEnd() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner(), value = try await owner.reserve()
        let journal = value.path.deletingLastPathComponent().appendingPathComponent("catalog.sqlite-journal")
        try Data("Generated pending journal".utf8).write(to: journal)
        XCTAssertEqual(chmod(journal.path, 0o600), 0)
        let cleaned = await value.finishWithoutWorker(); XCTAssertFalse(cleaned)
        XCTAssertTrue(FileManager().fileExists(atPath: journal.path))
        try await owner.discardIncomplete(value.id)
        let final = try await owner.inspect(); XCTAssertTrue(final.isEmpty)
    }
    func testPrecancelAndUnusablePoolGrantNoReservation() async throws {
        let fixture = try TemporaryCatalogFixture(), owner = try fixture.owner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await owner.reserve()
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.pool.path))
        try FileManager().createDirectory(at: fixture.pool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        do { _ = try await owner.reserve(); XCTFail() } catch { XCTAssertEqual(error as? SMBTemporaryStorageFailure, .unsafe) }
        XCTAssertTrue(try fixture.contents(fixture.pool).isEmpty)
    }
}
