import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class UploadCrashPoint: @unchecked Sendable {
    private let lock = NSLock(); private var commits = 0
    let mode: String, receipt: URL
    init(mode: String, receipt: URL) { self.mode = mode; self.receipt = receipt }
    func observe(_ stage: SFTPUploadLedger.Stage) throws {
        let commit = lock.withLock { if stage == .stagingWritten { commits += 1 }; return commits }
        let wanted = mode.hasPrefix("publication-") ? 2 : 1
        guard commit == wanted, stage == (mode.hasSuffix("stage") ? .stagingSynchronized : .renamed) else { return }
        // Generated-only proof before a real child-process exit. No history
        // recovery/remote request occurs in this callback.
        let fd = open(receipt.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RemoteSettingsFailure.unavailable }
        let bytes = Array("\(mode):\(commit):\(stage.rawValue)\n".utf8)
        guard write(fd, bytes, bytes.count) == bytes.count, fsync(fd) == 0 else { close(fd); throw RemoteSettingsFailure.unavailable }; close(fd)
        let parent = open(receipt.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0, fsync(parent) == 0 else { if parent >= 0 { close(parent) }; throw RemoteSettingsFailure.unavailable }; close(parent)
        _exit(mode.hasPrefix("upgrade-") ? (mode.hasSuffix("stage") ? 75 : 76) : mode.hasPrefix("publication-") ? (mode.hasSuffix("stage") ? 73 : 74) : (mode.hasSuffix("stage") ? 71 : 72))
    }
}

/// Invoked only by the process qualifier, separately from the ordinary18
/// controls. These are real process exits, not caught Swift exceptions.
final class SFTPUploadCrashControlTests: XCTestCase, @unchecked Sendable {
    private func mode() throws -> String {
        guard let mode = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_UPLOAD_CRASH"],
              ["prepared-stage", "prepared-rename", "publication-stage", "publication-rename", "upgrade-stage", "upgrade-rename"].contains(mode) else { throw XCTSkip("Use the isolated process qualifier") }; return mode
    }
    private func fixture(_ mode: String) throws -> UploadFoundationFixture {
        try UploadFoundationFixture(fixed: ProcessInfo.processInfo.environment["TRAVERSE_EXCLUSIVE_UPLOAD_TEST_ROOT"] == nil ? "crash-control" : "crash-control-" + mode)
    }
    func testCrashBoundary() async throws {
        let mode = try mode(), fixture = try fixture(mode), source = try await fixture.witness()
        if mode.hasPrefix("upgrade-") {
            let old = SFTPUploadLedger(directory: fixture.history)
            let prepared = try await fixture.prepare(old, source: source)
            _ = try await old.endAfterDrain(try XCTUnwrap(prepared.record?.id), noRemoteMutation: true); _ = await old.close()
            let file = fixture.history.appendingPathComponent("servers.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var records = try XCTUnwrap(object["records"] as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "publication") }; object["records"] = records; object["format"] = 1
            var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
            try bytes.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            try bytes.write(to: fixture.root.appendingPathComponent("legacy-before.json"), options: .withoutOverwriting)
        }
        let point = UploadCrashPoint(mode: mode, receipt: fixture.root.appendingPathComponent("actual-crash-boundary.txt"))
        let ledger = SFTPUploadLedger(directory: fixture.history, probe: { try point.observe($0) })
        let before = try await ledger.inspect()
        let prepared = try await fixture.prepare(ledger, source: source, revision: before.revision), id = try XCTUnwrap(prepared.record?.id)
        _ = try await ledger.requestPublication(id)
        XCTFail("The requested real process boundary was not reached")
    }
    func testColdInspection() async throws {
        let mode = try mode(), fixture = try fixture(mode), before = try fixture.image()
        XCTAssertTrue(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("actual-crash-boundary.txt").path))
        let ledger = SFTPUploadLedger(directory: fixture.history)
        if mode.hasSuffix("stage") {
            do { _ = try await ledger.inspect(); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
            XCTAssertNotNil(before["pending.json"])
            if mode.hasPrefix("upgrade-") { XCTAssertEqual(before["servers.json"], try Data(contentsOf: fixture.root.appendingPathComponent("legacy-before.json"))) }
        } else {
            let snapshot = try await ledger.inspect(); XCTAssertEqual(snapshot.records.count, mode.hasPrefix("upgrade-") ? 2 : 1); XCTAssertTrue(snapshot.active.isEmpty)
            if mode.hasPrefix("upgrade-") {
                XCTAssertEqual(snapshot.records[0].publicationKind, .legacyStagedRename); XCTAssertEqual(snapshot.records[0].outcome, .notStarted)
                XCTAssertEqual(snapshot.records[1].publicationKind, .exclusiveFinal); XCTAssertEqual(snapshot.records[1].outcome, .prepared)
            } else { XCTAssertEqual(snapshot.records.first?.outcome, mode.hasPrefix("publication-") ? .publicationRequested : .prepared) }
            XCTAssertNil(snapshot.records.first?.digest); XCTAssertNil(before["pending.json"])
        }
        XCTAssertEqual(try fixture.image(), before); let closed = await ledger.close(); XCTAssertTrue(closed)
    }
}
