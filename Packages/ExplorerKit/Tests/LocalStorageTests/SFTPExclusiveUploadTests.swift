import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class CreationFault: @unchecked Sendable {
    private let lock = NSLock(); private var writes = 0
    let stage: SFTPUploadLedger.Stage
    init(_ stage: SFTPUploadLedger.Stage) { self.stage = stage }
    func observe(_ value: SFTPUploadLedger.Stage) throws {
        let count = lock.withLock { if value == .stagingWritten { writes += 1 }; return writes }
        if count == 2 && value == stage { throw RemoteSettingsFailure.unavailable }
    }
}

final class SFTPExclusiveUploadTests: XCTestCase, @unchecked Sendable {
    private func canonical(_ value: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10); return bytes
    }
    private func seedLegacy(_ fixture: UploadFoundationFixture) async throws -> (UUID, SFTPUploadSourceSnapshot, Data) {
        let ledger = SFTPUploadLedger(directory: fixture.history), source = try await fixture.witness()
        let value = try await fixture.prepare(ledger, source: source), id = try XCTUnwrap(value.record?.id)
        _ = try await ledger.endAfterDrain(id, noRemoteMutation: true); _ = await ledger.close()
        let file = fixture.history.appendingPathComponent("servers.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "publication") }
        object["format"] = 1; object["records"] = records
        let legacy = try canonical(object); try legacy.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        return (id, source, legacy)
    }
    func testPassiveV1InspectionKeepsExactBytesAndLegacyMeaning() async throws {
        let fixture = try UploadFoundationFixture(), (id, _, original) = try await seedLegacy(fixture)
        let before = try fixture.image(), ledger = SFTPUploadLedger(directory: fixture.history)
        let value = try await ledger.inspect(); XCTAssertEqual(value.records.first?.id, id)
        XCTAssertEqual(value.records.first?.publicationKind, .legacyStagedRename); XCTAssertTrue(value.active.isEmpty)
        XCTAssertEqual(try fixture.image(), before); XCTAssertEqual(before["servers.json"], original); _ = await ledger.close()
    }
    func testExplicitPreparationUpgradesAtomicallyWithoutReinterpretingOldRecords() async throws {
        let fixture = try UploadFoundationFixture(), (id, source, _) = try await seedLegacy(fixture)
        let ledger = SFTPUploadLedger(directory: fixture.history), prior = try await ledger.inspect()
        let next = try await fixture.prepare(ledger, source: source, revision: prior.revision, name: "New.bin")
        let snapshot = try await ledger.inspect()
        XCTAssertEqual(snapshot.records.first(where: { $0.id == id })?.publication, .legacyStagedRename)
        XCTAssertEqual(next.record?.publication, .exclusiveFinal)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.history.appendingPathComponent("servers.json"))) as? [String: Any])
        XCTAssertEqual(object["format"] as? Int, 2)
        _ = try await ledger.endAfterDrain(try XCTUnwrap(next.record?.id), noRemoteMutation: true); _ = await ledger.close()
        let cold = try await ledger.inspect(); XCTAssertEqual(cold.records.count, 2); XCTAssertTrue(cold.active.isEmpty); _ = await ledger.close()
    }
    func testInterruptedUpgradeKeepsOldDurableRecordsAndRequiresExplicitRecovery() async throws {
        let fixture = try UploadFoundationFixture(), (_, source, original) = try await seedLegacy(fixture)
        let ledger = SFTPUploadLedger(directory: fixture.history, probe: { if $0 == .stagingSynchronized { throw RemoteSettingsFailure.unavailable } })
        let before = try await ledger.inspect()
        do { _ = try await fixture.prepare(ledger, source: source, revision: before.revision, name: "New.bin"); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .unavailable) }
        _ = await ledger.close(); let failed = try fixture.image(); XCTAssertEqual(failed["servers.json"], original); XCTAssertNotNil(failed["pending.json"])
        do { _ = try await ledger.inspect(); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
        XCTAssertEqual(try fixture.image(), failed)
        try await ledger.recoverUncommittedStage(); let recovered = try await ledger.inspect()
        XCTAssertEqual(recovered.records.count, 1); XCTAssertEqual(recovered.records.first?.publicationKind, .legacyStagedRename)
        XCTAssertEqual(try Data(contentsOf: fixture.history.appendingPathComponent("servers.json")), original); _ = await ledger.close()
    }
    func testDurableCreationBarrierPrecedesCompleteSourceAuthorization() async throws {
        let fixture = try UploadFoundationFixture(), source = try await fixture.witness(), ledger = SFTPUploadLedger(directory: fixture.history)
        let value = try await fixture.prepare(ledger, source: source), id = try XCTUnwrap(value.record?.id)
        try await Task.detached {
            XCTAssertThrowsError(try ledger.requireCreationRequestedOnSessionExecutor(id))
            _ = try ledger.requestPublicationOnSessionExecutor(id)
            try ledger.requireCreationRequestedOnSessionExecutor(id)
        }.value
        let snapshot = try await ledger.inspect(); XCTAssertEqual(snapshot.records.first?.outcome, .publicationRequested)
        let end = try await ledger.endAfterDrain(id, noRemoteMutation: true)
        XCTAssertEqual(end.record?.outcome, .notStarted); _ = await ledger.close()
    }
    func testBothCreationBarrierFailureBoundariesRetainConservativeColdTruth() async throws {
        for stage in [SFTPUploadLedger.Stage.stagingSynchronized, .renamed] {
            let fixture = try UploadFoundationFixture(), source = try await fixture.witness(), fault = CreationFault(stage)
            let ledger = SFTPUploadLedger(directory: fixture.history, probe: { try fault.observe($0) })
            let value = try await fixture.prepare(ledger, source: source), id = try XCTUnwrap(value.record?.id)
            do { _ = try await ledger.requestPublication(id); XCTFail() }
            catch { XCTAssertEqual(error as? RemoteSettingsFailure, stage == .renamed ? .durabilityUncertain : .unavailable) }
            // This control sends no remote request at all. Saving a marker is
            // not evidence that any server mutation happened.
            _ = try? await ledger.endAfterDrain(id, noRemoteMutation: true); _ = await ledger.close()
            let before = try fixture.image()
            if stage == .stagingSynchronized {
                do { _ = try await ledger.inspect(); XCTFail() } catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
            } else {
                let cold = try await ledger.inspect(); XCTAssertTrue(cold.active.isEmpty)
                XCTAssertTrue([.publicationRequested, .notStarted].contains(cold.records.first!.outcome))
            }
            XCTAssertEqual(try fixture.image(), before); _ = await ledger.close()
        }
    }
}
