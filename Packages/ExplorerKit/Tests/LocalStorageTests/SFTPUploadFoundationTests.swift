import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

struct UploadFoundationFixture: Sendable {
    let root: URL
    var history: URL { root.appendingPathComponent("upload-history") }
    var file: URL { root.appendingPathComponent("Generated.bin") }
    init(fixed: String? = nil) throws {
        if let raw = ProcessInfo.processInfo.environment["TRAVERSE_EXCLUSIVE_UPLOAD_TEST_ROOT"] {
            let packet = URL(fileURLWithPath: raw)
            guard packet.resolvingSymlinksInPath() == packet, UUID(uuidString: packet.lastPathComponent) != nil,
                  packet.deletingLastPathComponent().lastPathComponent == "traverse-development",
                  #filePath.hasPrefix(packet.path + "/source/package/"), fixed == nil || ["crash-control", "crash-control-prepared-stage", "crash-control-prepared-rename", "crash-control-publication-stage", "crash-control-publication-rename", "crash-control-upgrade-stage", "crash-control-upgrade-rename"].contains(fixed!),
                  let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: packet.appendingPathComponent("reservation.json"))) as? [String: Any],
                  marker["packet"] as? String == "traverse-development-v1" else { throw RemoteSettingsFailure.unsafe }
            root = packet.appendingPathComponent("source/UploadFixtures/" + (fixed ?? UUID().uuidString))
            if !FileManager().fileExists(atPath: root.path) { try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            return
        }
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_UPLOAD_SOURCE"] else { throw XCTSkip("Use the bounded upload-source qualifier") }
        let base = URL(fileURLWithPath: raw)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let envelope = base.deletingLastPathComponent().deletingLastPathComponent()
        let packets = [repo.appendingPathComponent(".build/b12-upload-qualification"): "b12-upload-v1",
                       repo.appendingPathComponent(".build/b12-upload-integration"): "b12-upload-integration-v1"]
        guard base.lastPathComponent == "source", let packet = packets[envelope],
              UUID(uuidString: base.deletingLastPathComponent().lastPathComponent) != nil, base.resolvingSymlinksInPath() == base,
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: base.deletingLastPathComponent().appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["packet"] as? String == packet, fixed == nil || ["crash-control"].contains(fixed!) else { throw RemoteSettingsFailure.unsafe }
        root = base.appendingPathComponent(fixed ?? UUID().uuidString)
        if !FileManager().fileExists(atPath: root.path) { try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    func makeSource(_ bytes: Data = Data("Explicit generated source".utf8), probe: (@Sendable () throws -> Void)? = nil) async throws -> SFTPUploadSource {
        try bytes.write(to: file, options: .withoutOverwriting)
        return try await SFTPUploadSource.prepare(file, excluding: [], readProbe: probe)
    }
    func witness() async throws -> SFTPUploadSourceSnapshot { let source = try await makeSource(); let value = source.snapshot; await source.drain(); return value }
    func prepare(_ ledger: SFTPUploadLedger, source: SFTPUploadSourceSnapshot, revision: UInt64 = 0, name: String = "Draft-Notes.bin") async throws -> SFTPUploadLedgerMutation {
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        return try await ledger.prepare(host: .init(address: SFTPConnectionAddress("sftp://generated.invalid/")), account: "generated",
            key: SFTPHostKey(key), directory: "/generated", name: name, source: source, revision: revision)
    }
    func image() throws -> [String: Data] {
        guard FileManager().fileExists(atPath: history.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: history.path).map { ($0, try Data(contentsOf: history.appendingPathComponent($0))) })
    }
}
final class UploadTestGate: @unchecked Sendable {
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1)), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var main = false, returned = false
    var facts: (main: Bool, returned: Bool) { lock.withLock { (main, returned) } }
    func hold() throws {
        lock.withLock { main = main || Thread.isMainThread }; entered.continuation.yield(())
        guard release.wait(timeout: .now() + 5) == .success else { throw RemoteSettingsFailure.unavailable }
        lock.withLock { returned = true }
    }
}

final class SFTPUploadSourceTests: XCTestCase, @unchecked Sendable {
    func testExactChunksDigestAndOriginalRemainUnchanged() async throws {
        let fixture = try UploadFoundationFixture(), bytes = Data((0..<65553).map { UInt8($0 % 251) }), source = try await fixture.makeSource(bytes)
        var found = Data()
        while found.count < bytes.count { found.append(try await source.read(offset: UInt64(found.count))) }
        XCTAssertEqual(found, bytes); let digest = try await source.finishReading(); XCTAssertEqual(digest, Data(SHA256.hash(data: bytes)))
        let again = try await source.finishReading(); XCTAssertEqual(digest, again)
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes); await source.drain()
        do { _ = try await source.read(offset: 0); XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }
    }
    func testEmptySourceStillRequiresFinalValidation() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource(Data())
        XCTAssertEqual(source.snapshot.logicalBytes, 0); let data = try await source.read(offset: 0); XCTAssertTrue(data.isEmpty)
        let digest = try await source.finishReading(); XCTAssertEqual(digest, Data(SHA256.hash(data: Data()))); await source.drain()
    }
    func testWrongOffsetsBoundsAndEarlyFinishCannotContinue() async throws {
        for variant in 0..<4 {
            let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource()
            do {
                if variant == 3 { _ = try await source.finishReading() }
                else { _ = try await source.read(offset: variant == 0 ? 1 : 0, maximum: variant == 1 ? 0 : variant == 2 ? 32769 : 1) }; XCTFail()
            } catch {}
            do { _ = try await source.read(offset: 0); XCTFail() } catch {}; await source.drain()
        }
    }
    func testChangeTruncationAndSameBytesReplacementRefuse() async throws {
        for variant in 0..<3 {
            let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource(), before = try Data(contentsOf: fixture.file)
            if variant == 2 {
                try FileManager().moveItem(at: fixture.file, to: fixture.root.appendingPathComponent("retained-original")); try before.write(to: fixture.file, options: .withoutOverwriting)
            } else {
                let fd = open(fixture.file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0)
                if variant == 0 { XCTAssertEqual(pwrite(fd, [UInt8(99)], 1, 0), 1) } else { XCTAssertEqual(ftruncate(fd, 0), 0) }; close(fd)
            }
            do { _ = try await source.read(offset: 0); XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .changed) }; await source.drain()
        }
    }
    func testPostReadChangesInvalidatePublicationWitness() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource()
        _ = try await source.read(offset: 0); _ = try await source.finishReading()
        let fd = open(fixture.file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(pwrite(fd, [UInt8(99)], 1, 0), 1); close(fd)
        do { _ = try await source.finishReading(); XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .changed) }; await source.drain()
    }
    func testProtectedSymlinkAndNonRegularSourcesNeverRead() async throws {
        let fixture = try UploadFoundationFixture(); try Data([1]).write(to: fixture.file, options: .withoutOverwriting)
        let link = fixture.root.appendingPathComponent("generated-source-link"); try FileManager().createSymbolicLink(atPath: link.path, withDestinationPath: "Generated.bin")
        for (url, excluded) in [(fixture.file, [fixture.root]), (link, []), (fixture.root, [])] {
            do { _ = try await SFTPUploadSource.prepare(url, excluding: excluded); XCTFail() } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1]))
    }
    func testMalformedURLsAndOversizeWitnessRefuseWithoutLargeFixture() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.makeSource()
        for suffix in ["?body=false", "#part"] {
            let changed = try XCTUnwrap(URL(string: fixture.file.absoluteString + suffix))
            do { _ = try await SFTPUploadSource.prepare(changed, excluding: []); XCTFail() } catch {}
        }
        let badRoot = try XCTUnwrap(URL(string: fixture.root.absoluteString + "?invalid=true"))
        do { _ = try await SFTPUploadSource.prepare(fixture.file, excluding: [badRoot]); XCTFail() } catch {}
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source.snapshot)) as? [String: Any])
        var observed = try XCTUnwrap(object["observation"] as? [String: Any]); observed["size"] = (Int64(1) << 30) + 1; object["observation"] = observed
        let tooLarge = try JSONDecoder().decode(SFTPUploadSourceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try tooLarge.validate()); await source.drain()
    }
    func testCancelledReadAndDrainWaitForActualOffMainUser() async throws {
        let fixture = try UploadFoundationFixture(), gate = UploadTestGate(), source = try await fixture.makeSource(probe: { try gate.hold() })
        let reading = Task { try await source.read(offset: 0) }; var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
        reading.cancel(); let draining = Task { await source.drain() }; await Task.yield()
        XCTAssertFalse(gate.facts.returned); gate.release.signal()
        do { _ = try await reading.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }
        await draining.value; XCTAssertTrue(gate.facts.returned); XCTAssertFalse(gate.facts.main)
    }
}

final class SFTPUploadLedgerTests: XCTestCase, @unchecked Sendable {
    private func refused(_ failure: RemoteSettingsFailure, _ work: () async throws -> Void) async {
        do { try await work(); XCTFail("Expected upload history refusal") } catch { XCTAssertEqual(error as? RemoteSettingsFailure, failure) }
    }
    func testPassiveStartupCreatesNothing() async throws {
        let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history)
        let snapshot = try await store.inspect(); XCTAssertTrue(snapshot.records.isEmpty); XCTAssertEqual(snapshot.revision, 0)
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.history.path)); let closed = await store.close(); XCTAssertTrue(closed)
    }
    func testPreparedPublishingVerifiedAndExactLocalForget() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.witness(), store = SFTPUploadLedger(directory: fixture.history)
        let prepared = try await fixture.prepare(store, source: source), record = try XCTUnwrap(prepared.record)
        XCTAssertEqual(record.outcome, .prepared); XCTAssertTrue(record.temporaryPath.hasPrefix("/generated/.mac-explorer-upload-")); XCTAssertEqual(record.finalPath, "/generated/Draft-Notes.bin")
        await refused(.busy) { _ = try await store.forget(record.id, revision: 1) }; let activeClose = await store.close(); XCTAssertFalse(activeClose)
        let publishing = try await store.requestPublication(record.id); XCTAssertEqual(publishing.record?.outcome, .publicationRequested)
        let digest = Data(SHA256.hash(data: Data("Explicit generated source".utf8)))
        _ = try await store.verify(record.id, digest: digest); _ = try await store.endAfterDrain(record.id)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPUploadLedger(directory: fixture.history), saved = try await cold.inspect()
        XCTAssertTrue(saved.active.isEmpty); XCTAssertEqual(saved.records.first?.digest, digest); XCTAssertEqual(saved.records.first?.outcome, .verified)
        _ = try await cold.forget(record.id, revision: 4); let final = try await cold.inspect(); XCTAssertTrue(final.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("Explicit generated source".utf8)); _ = await cold.close()
    }
    func testExclusiveUnprovenOutcomesRemainPublicationReview() async throws {
        for publishing in [false, true] {
            let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
            let prepared = try await fixture.prepare(store, source: source), id = try XCTUnwrap(prepared.record?.id)
            if publishing { _ = try await store.requestPublication(id) }
            let ended = try await store.endAfterDrain(id)
            XCTAssertEqual(ended.record?.outcome, .reviewPublication); _ = await store.close()
            let bytes = try fixture.image(), cold = try await store.inspect(); XCTAssertTrue(cold.active.isEmpty); XCTAssertEqual(try fixture.image(), bytes)
            await refused(.busy) { _ = try await store.requestPublication(id) }; _ = await store.close()
        }
    }
    func testStaleRevisionMissingRecordAndEarlySuccessRefuse() async throws {
        let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
        let prepared = try await fixture.prepare(store, source: source), id = try XCTUnwrap(prepared.record?.id)
        await refused(.staleRevision) { _ = try await store.forget(id, revision: 0) }
        await refused(.invalidRecord) { _ = try await store.verify(id, digest: Data(repeating: 1, count: 32)) }
        await refused(.missing) { _ = try await store.forget(UUID(), revision: 1) }
        _ = try await store.endAfterDrain(id, noRemoteMutation: true); _ = await store.close()
        let cold = try await store.inspect(); XCTAssertEqual(cold.records.first?.outcome, .notStarted)
    }
    func testIndependentActiveRecordsDoNotInvalidateEachOthersCheckpoints() async throws {
        let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
        let first = try await fixture.prepare(store, source: source), a = try XCTUnwrap(first.record?.id)
        let second = try await fixture.prepare(store, source: source, revision: first.revision, name: "Second.bin"), b = try XCTUnwrap(second.record?.id)
        XCTAssertNotEqual(a, b)
        _ = try await store.requestPublication(a); _ = try await store.requestPublication(b)
        let digest = Data(repeating: 1, count: 32)
        _ = try await store.verify(b, digest: digest); _ = try await store.endAfterDrain(b)
        _ = try await store.verify(a, digest: digest); _ = try await store.endAfterDrain(a)
        let saved = try await store.inspect(); XCTAssertEqual(saved.revision, 8); XCTAssertTrue(saved.active.isEmpty)
        XCTAssertEqual(saved.records.map(\.outcome), [.verified, .verified]); _ = await store.close()
    }
    func testTwoActiveOwnersAndBoundedHistory() async throws {
        let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
        var revision: UInt64 = 0
        for index in 0..<64 {
            let prepared = try await fixture.prepare(store, source: source, revision: revision, name: "Generated-\(index).bin"), id = try XCTUnwrap(prepared.record?.id)
            revision = prepared.revision
            if index == 0 {
                let second = try await fixture.prepare(store, source: source, revision: revision, name: "Second.bin"), secondID = try XCTUnwrap(second.record?.id); revision = second.revision
                await refused(.capacity) { _ = try await fixture.prepare(store, source: source, revision: revision, name: "Third.bin") }
                let ended = try await store.endAfterDrain(secondID, noRemoteMutation: true); revision = ended.revision
                _ = try await store.forget(secondID, revision: revision); revision += 1
            }
            let ended = try await store.endAfterDrain(id, noRemoteMutation: true); revision = ended.revision
        }
        await refused(.capacity) { _ = try await fixture.prepare(store, source: source, revision: revision) }
        let saved = try await store.inspect(); XCTAssertEqual(saved.records.count, 64); XCTAssertTrue(saved.active.isEmpty); _ = await store.close()
    }
    func testCanonicalVersionUnknownFieldsAndWrongProtocolRefuseReadOnly() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.witness(), store = SFTPUploadLedger(directory: fixture.history)
        let prepared = try await fixture.prepare(store, source: source), id = try XCTUnwrap(prepared.record?.id)
        _ = try await store.endAfterDrain(id); _ = await store.close()
        let file = fixture.history.appendingPathComponent("servers.json"), original = try Data(contentsOf: file)
        for kind in ["version", "unknown", "other"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if kind == "version" { object["format"] = 99 } else if kind == "unknown" { object["unknown"] = true } else { object["protocolIdentity"] = "sftp-private-state" }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            let before = try fixture.image(); await refused(kind == "unknown" ? .invalidRecord : .incompatibleVersion) { _ = try await store.inspect() }; XCTAssertEqual(try fixture.image(), before)
        }
    }
    func testCompetingOwnerAndChangedCatalogCannotOverwrite() async throws {
        let fixture = try UploadFoundationFixture(), store = SFTPUploadLedger(directory: fixture.history), second = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
        let prepared = try await fixture.prepare(store, source: source), id = try XCTUnwrap(prepared.record?.id)
        await refused(.busy) { _ = try await second.inspect() }
        let file = fixture.history.appendingPathComponent("servers.json"), retained = fixture.root.appendingPathComponent("retained-catalog")
        try FileManager().moveItem(at: file, to: retained); try Data(contentsOf: retained).write(to: file, options: .withoutOverwriting); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let before = try fixture.image(); await refused(.unsafe) { _ = try await store.endAfterDrain(id) }; XCTAssertEqual(try fixture.image(), before)
        let closed = await store.close(); XCTAssertTrue(closed)
    }
    func testStagingAndRenameFaultsKeepConservativeColdTruth() async throws {
        for stage in [SFTPUploadLedger.Stage.stagingSynchronized, .renamed] {
            let fixture = try UploadFoundationFixture(), source = try await fixture.witness()
            let store = SFTPUploadLedger(directory: fixture.history, probe: { if $0 == stage { throw RemoteSettingsFailure.unavailable } })
            await refused(stage == .renamed ? .durabilityUncertain : .unavailable) { _ = try await fixture.prepare(store, source: source) }; _ = await store.close()
            let before = try fixture.image()
            if stage == .renamed { let cold = try await store.inspect(); XCTAssertEqual(cold.records.first?.outcome, .prepared); XCTAssertTrue(cold.active.isEmpty) }
            else {
                await refused(.recoveryRequired) { _ = try await store.inspect() }; XCTAssertEqual(try fixture.image(), before)
                let copy = fixture.root.appendingPathComponent("recovery-copy"); try FileManager().copyItem(at: fixture.history, to: copy)
                let recovering = SFTPUploadLedger(directory: copy)
                try await recovering.recoverUncommittedStage(); let restored = try await recovering.inspect(); XCTAssertTrue(restored.records.isEmpty); _ = await recovering.close()
                XCTAssertEqual(try fixture.image(), before)
            }
        }
    }
    func testLateCancelledPrepareReportsCommitAndCleanupStillDrains() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.witness(), gate = UploadTestGate()
        let store = SFTPUploadLedger(directory: fixture.history, probe: { if $0 == .stagingSynchronized, !gate.facts.returned { try gate.hold() } })
        let saving = Task { () throws -> (SFTPUploadLedgerMutation, SFTPUploadLedgerMutation) in
            let prepared = try await fixture.prepare(store, source: source), id = try XCTUnwrap(prepared.record?.id)
            let ended = try await store.endAfterDrain(id, noRemoteMutation: true); return (prepared, ended)
        }
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next(); saving.cancel(); XCTAssertFalse(gate.facts.returned); gate.release.signal()
        let result = try await saving.value; XCTAssertTrue(result.0.completedAfterCancellation); XCTAssertTrue(result.1.completedAfterCancellation)
        XCTAssertEqual(result.1.record?.outcome, .notStarted); XCTAssertFalse(gate.facts.main)
        let closed = await store.close(); XCTAssertTrue(closed)
    }
}
