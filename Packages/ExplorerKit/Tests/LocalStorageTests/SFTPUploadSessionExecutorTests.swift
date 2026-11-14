import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class UploadSecondCommitFault: @unchecked Sendable {
    private let lock = NSLock(); private var commits = 0
    func observe(_ stage: SFTPUploadLedger.Stage) throws {
        let ordinal = lock.withLock { if stage == .stagingWritten { commits += 1 }; return commits }
        if ordinal == 2, stage == .renamed { throw RemoteSettingsFailure.unavailable }
    }
}
final class SFTPUploadSessionExecutorTests: XCTestCase, @unchecked Sendable {
    func testSerialSessionSourceAndHistoryShareChecksAndActualDrain() async throws {
        let fixture = try UploadFoundationFixture(), bytes = Data((0..<65553).map { UInt8($0 % 251) }), source = try await fixture.makeSource(bytes)
        let ledger = SFTPUploadLedger(directory: fixture.history), prepared = try await fixture.prepare(ledger, source: source.snapshot), id = try XCTUnwrap(prepared.record?.id)
        let completed = try await Task.detached {
            var found = Data()
            while found.count < bytes.count { found.append(try source.readOnSessionExecutor(offset: UInt64(found.count), maximum: 32768)) }
            XCTAssertEqual(found, bytes)
            let digest = try source.finishOnSessionExecutor(); XCTAssertEqual(digest, Data(SHA256.hash(data: bytes)))
            _ = try ledger.requestPublicationOnSessionExecutor(id); _ = try ledger.verifyOnSessionExecutor(id, digest: digest)
            try source.closeAfterDrainOnSessionExecutor(); return try ledger.endAfterDrainOnSessionExecutor(id)
        }.value
        XCTAssertEqual(completed.record?.outcome, .verified); let snapshot = try await ledger.inspect(); XCTAssertTrue(snapshot.active.isEmpty)
        let closed = await ledger.close(); XCTAssertTrue(closed); XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    }
    @MainActor func testMainThreadCannotPerformSynchronousSourceOrHistoryIO() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource(), ledger = SFTPUploadLedger(directory: fixture.history)
        XCTAssertThrowsError(try source.readOnSessionExecutor(offset: 0, maximum: 1)) { XCTAssertEqual($0 as? SFTPUploadSourceFailure, .busy) }
        XCTAssertThrowsError(try source.finishOnSessionExecutor()) { XCTAssertEqual($0 as? SFTPUploadSourceFailure, .busy) }
        XCTAssertThrowsError(try ledger.requestPublicationOnSessionExecutor(UUID())) { XCTAssertEqual($0 as? RemoteSettingsFailure, .busy) }
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.history.path)); await source.drain(); _ = await ledger.close()
    }
    func testActualDirectReadMustReturnBeforeSourceCloseFinishes() async throws {
        let fixture = try UploadFoundationFixture(), gate = UploadTestGate(), source = try await fixture.makeSource(probe: { try gate.hold() })
        let reading = Task.detached { try source.readOnSessionExecutor(offset: 0, maximum: 32768) }
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
        source.requestStop(); let draining = Task { await source.drain() }; await Task.yield(); XCTAssertFalse(gate.facts.returned); gate.release.signal()
        do { _ = try await reading.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }
        await draining.value; XCTAssertTrue(gate.facts.returned); XCTAssertFalse(gate.facts.main)
    }
    func testPublicationSaveFailureReleasesOnlyAfterDrainAndKeepsColdPrefix() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource(), fault = UploadSecondCommitFault()
        let ledger = SFTPUploadLedger(directory: fixture.history, probe: { try fault.observe($0) })
        let prepared = try await fixture.prepare(ledger, source: source.snapshot), id = try XCTUnwrap(prepared.record?.id)
        try await Task.detached {
            do { _ = try ledger.requestPublicationOnSessionExecutor(id); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .durabilityUncertain) }
            try source.closeAfterDrainOnSessionExecutor()
            do { _ = try ledger.endAfterDrainOnSessionExecutor(id); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
        }.value
        let closed = await ledger.close(); XCTAssertTrue(closed)
        let before = try fixture.image(), snapshot = try await ledger.inspect()
        XCTAssertTrue(snapshot.active.isEmpty); XCTAssertEqual(snapshot.records.first?.outcome, .publicationRequested); XCTAssertEqual(try fixture.image(), before)
    }
    func testNonemptyAppleResourceForkRefusesBeforeSourceBodyReads() async throws {
        let fixture = try UploadFoundationFixture(), bytes = Data("Generated data fork".utf8)
        try bytes.write(to: fixture.file, options: .withoutOverwriting)
        let fd = open(fixture.file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }; let fork: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(fsetxattr(fd, "com.apple.ResourceFork", fork, fork.count, 0, 0), 0)
        do { _ = try await SFTPUploadSource.prepare(fixture.file, excluding: [], readProbe: { XCTFail("No body read admitted") }); XCTFail() }
        catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .unsupportedMetadata) }
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes); XCTAssertEqual(fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0), 4)
    }
}
