import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class FolderUploadCrashPoint: @unchecked Sendable {
    let mode: String, receipt: URL, expectedCommit: Int, exitCode: Int32
    private let lock = NSLock(); private var commits = 0
    init(mode: String, receipt: URL) {
        self.mode = mode; self.receipt = receipt
        let phases = ["prepared", "publication", "root", "progress", "final", "upgrade"], phase = phases.firstIndex(where: { mode.hasPrefix($0 + "-") })!
        expectedCommit = phase == 5 ? 1 : phase + 1; exitCode = Int32(81 + phase * 2 + (mode.hasSuffix("rename") ? 1 : 0))
    }
    func observe(_ stage: SFTPUploadLedger.Stage) throws {
        let count = lock.withLock { if stage == .stagingWritten { commits += 1 }; return commits }
        guard count == expectedCommit, stage == (mode.hasSuffix("stage") ? .stagingSynchronized : .renamed) else { return }
        let fd = open(receipt.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RemoteSettingsFailure.unavailable }
        let bytes = Array("\(mode):\(count):\(stage.rawValue)\n".utf8)
        guard write(fd, bytes, bytes.count) == bytes.count, fsync(fd) == 0 else { close(fd); throw RemoteSettingsFailure.unavailable }; close(fd)
        let parent = open(receipt.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0, fsync(parent) == 0 else { if parent >= 0 { close(parent) }; throw RemoteSettingsFailure.unavailable }; close(parent)
        _exit(exitCode)
    }
}

/// Real child exits. The orchestration invokes these two tests individually;
/// ordinary contracts never skip them and never mistake a caught error for a crash.
final class SFTPFolderUploadCrashTests: XCTestCase, @unchecked Sendable {
    private func mode() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["TRAVERSE_FOLDER_UPLOAD_CRASH"] else { throw XCTSkip("Use the bounded actual-process H qualifier") }
        guard ["prepared", "publication", "root", "progress", "final", "upgrade"].flatMap({ [$0 + "-stage", $0 + "-rename"] }).contains(value) else { throw RemoteSettingsFailure.unsafe }; return value
    }
    func testActualCrashBoundary() async throws {
        let mode = try mode(), f = try FolderUploadFixture(fixed: "h-crash-" + mode); try f.file("Member", Data([1,2,3]))
        let source = try await f.prepare(), snapshot = source.snapshot; await source.drain()
        if mode.hasPrefix("upgrade-") {
            let file = try await SFTPUploadSource.prepare(f.tree.appendingPathComponent("Member"), excluding: []), ledger = SFTPUploadLedger(directory: f.history)
            let value = try await ledger.prepare(host: .init(address: SFTPConnectionAddress("sftp://generated.invalid/")), account: "generated", key: f.key(), directory: "/generated", name: "Previous File", source: file.snapshot, revision: 0)
            _ = try await ledger.endAfterDrain(try XCTUnwrap(value.record?.id), noRemoteMutation: true); _ = await ledger.close(); await file.drain()
            try Data(contentsOf: f.history.appendingPathComponent("servers.json")).write(to: f.root.appendingPathComponent("v2-before.json"), options: .withoutOverwriting)
        }
        let point = FolderUploadCrashPoint(mode: mode, receipt: f.root.appendingPathComponent("actual-crash-boundary.txt"))
        let ledger = SFTPUploadLedger(directory: f.history, probe: { try point.observe($0) }), before = try await ledger.inspect()
        let id = try await f.remember(ledger, snapshot, revision: before.revision); _ = try await ledger.requestPublication(id)
        try await Task.detached {
            try ledger.acknowledgeFolderRootOnSessionExecutor(id)
            try ledger.checkpointFolderOnSessionExecutor(id, files: 1, bytes: 3)
            try ledger.verifyFolderOnSessionExecutor(id, digest: Data(repeating: 7, count: 32), files: 1, bytes: 3)
        }.value
        XCTFail("Actual crash boundary not reached")
    }
    func testPassiveColdInspection() async throws {
        let mode = try mode(), f = try FolderUploadFixture(fixed: "h-crash-" + mode), before = try f.image()
        XCTAssertTrue(FileManager().fileExists(atPath: f.root.appendingPathComponent("actual-crash-boundary.txt").path))
        let ledger = SFTPUploadLedger(directory: f.history)
        if mode.hasSuffix("stage") {
            do { _ = try await ledger.inspect(); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
            XCTAssertNotNil(before["pending.json"])
            if mode.hasPrefix("upgrade-") { XCTAssertEqual(before["servers.json"], try Data(contentsOf: f.root.appendingPathComponent("v2-before.json"))) }
        } else {
            let snapshot = try await ledger.inspect(); XCTAssertTrue(snapshot.active.isEmpty)
            XCTAssertEqual(snapshot.records.count, mode.hasPrefix("upgrade-") ? 2 : 1)
            let record = try XCTUnwrap(snapshot.records.last); XCTAssertEqual(record.publication, .exclusiveFreshFolder)
            XCTAssertTrue(record.source.isFolder)
            if mode.hasPrefix("prepared-") || mode.hasPrefix("upgrade-") { XCTAssertEqual(record.outcome, .prepared); XCTAssertEqual(record.folderProgress, .init()) }
            else if mode.hasPrefix("final-") { XCTAssertEqual(record.outcome, .verified); XCTAssertEqual(record.digest?.count, 32) }
            else { XCTAssertEqual(record.outcome, .publicationRequested); XCTAssertNil(record.digest) }
            if mode.hasPrefix("root-") || mode.hasPrefix("progress-") || mode.hasPrefix("final-") { XCTAssertEqual(record.folderProgress?.rootAcknowledged, true) }
            if mode.hasPrefix("progress-") || mode.hasPrefix("final-") { XCTAssertEqual(record.folderProgress?.verifiedFiles, 1); XCTAssertEqual(record.folderProgress?.verifiedBytes, 3) }
        }
        XCTAssertEqual(try f.image(), before); let closed = await ledger.close(); XCTAssertTrue(closed)
    }
}
