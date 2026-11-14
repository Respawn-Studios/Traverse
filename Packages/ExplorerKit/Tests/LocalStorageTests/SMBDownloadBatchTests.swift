import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) @testable import LocalStorage

#if DEBUG
private final class SMBSecondHeaderFault: @unchecked Sendable {
    private let lock = NSLock()
    private var headers = 0
    func afterSync(_ id: UUID) throws {
        let fail = lock.withLock { headers += 1; return headers == 2 }
        if fail { throw RemoteDownloadStorageFailure.unavailable }
    }
}
#endif

final class SMBDownloadBatchTests: XCTestCase, @unchecked Sendable {
    private func selections(_ sizes: [UInt64], connection: UUID = UUID(),
                            snapshot: SMBDirectorySnapshot? = nil) throws -> [SMBDownloadSelection] {
        let current = snapshot ?? .init(readID: UUID(), revision: 2, count: Int64(sizes.count),
                                        folders: 0, state: .complete)
        return try sizes.enumerated().map { index, size in
            try .init(connection: connection, snapshot: current,
                observation: .init(id: Int64(index + 1), name: SMBRemoteName("Generated-\(index).bin"),
                                   attributes: 32, logicalBytes: size, modifiedFileTime: 300))
        }
    }
    private func plan(_ sizes: [UInt64]) throws -> SMBDownloadBatchPlan {
        let items = try selections(sizes)
        return try .init(connection: items[0].connection, snapshot: items[0].snapshot, selections: items)
    }
    func testPlanRequiresOneCompleteObservationAndRejectsDuplicateOrUnsafeNames() throws {
        let items = try selections([1, 2, 3]), snapshot = items[0].snapshot, connection = items[0].connection
        XCTAssertEqual(try SMBDownloadBatchPlan(connection: connection, snapshot: snapshot, selections: items).logicalBytes, 6)
        XCTAssertThrowsError(try SMBDownloadBatchPlan(connection: connection, snapshot: snapshot,
            selections: [items[0], items[0]])) { XCTAssertEqual($0 as? SMBDownloadBatchIssue, .duplicateSelection) }
        let changed = SMBDirectorySnapshot(readID: snapshot.readID, revision: snapshot.revision + 1,
                                           count: snapshot.count, folders: 0, state: .complete)
        XCTAssertThrowsError(try SMBDownloadBatchPlan(connection: connection, snapshot: changed,
            selections: Array(items.prefix(2)))) { XCTAssertEqual($0 as? SMBDownloadBatchIssue, .invalidSelection) }
        let unsafe = try SMBDownloadSelection(connection: connection, snapshot: snapshot,
            observation: .init(id: 4, name: SMBRemoteName("Unsafe:Name"), attributes: 32,
                               logicalBytes: 1, modifiedFileTime: 300))
        XCTAssertThrowsError(try SMBDownloadBatchPlan(connection: connection, snapshot: snapshot,
            selections: [items[0], unsafe])) { XCTAssertEqual($0 as? SMBDownloadBatchIssue, .invalidSelection) }
        let sameName = try SMBDownloadSelection(connection: connection, snapshot: snapshot,
            observation: .init(id: 4, name: items[0].observation.name, attributes: 32,
                               logicalBytes: 1, modifiedFileTime: 300))
        XCTAssertThrowsError(try SMBDownloadBatchPlan(connection: connection, snapshot: snapshot,
            selections: [items[0], sameName])) { XCTAssertEqual($0 as? SMBDownloadBatchIssue, .duplicateName) }
        let tooLarge = try selections([600 << 20, 600 << 20])
        XCTAssertThrowsError(try SMBDownloadBatchPlan(connection: tooLarge[0].connection,
            snapshot: tooLarge[0].snapshot, selections: tooLarge)) {
            XCTAssertEqual($0 as? SMBDownloadBatchIssue, .tooLarge)
        }
    }
    func testSixteenReservationsHoldThePoolBudgetUntilExplicitReview() async throws {
        let directory = try LocalStorageTestFixtures.directory().appendingPathComponent("downloads")
        let store = try RemoteDownloadStore(directory: directory), batch = try plan(Array(repeating: 0, count: 16))
        let files = try await store.reserveBatch(batch)
        XCTAssertEqual(files.count, 16)
        let active = try await store.inspect()
        XCTAssertEqual(active.filter(\.active).count, 16)
        do { _ = try await store.reserve(try selections([0, 0])[0]); XCTFail("Ordinary admission bypassed the group budget") }
        catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .capacity) }
        for file in files {
            do { _ = try await file.verifiedSource(); XCTFail("Unsealed source escaped") } catch {}
        }
        for file in files { _ = await file.abandon() }
        let inactive = try await store.inspect()
        XCTAssertEqual(inactive.count, 16); XCTAssertTrue(inactive.allSatisfy { !$0.active })
        for record in inactive { try await store.discardIncomplete(record.id) }
        let empty = try await store.inspect(); XCTAssertTrue(empty.isEmpty)
    }
    func testSingleFilePolicyKeepsBatchLegacyUntilExplicitPublicGroupAdmission() async throws {
        let root = try LocalStorageTestFixtures.directory(), pool = root.appendingPathComponent("downloads")
        let batch = try plan([3, 0])
        let singleOnly = try SMBDownloadStorage(directory: pool, publicQuarantinePolicy: .sourceQualification)
        let legacy = try await singleOnly.store.reserveBatch(batch,
            publicQuarantineV1: singleOnly.publicQuarantineSelectedGroupCandidate)
        XCTAssertFalse(singleOnly.publicQuarantineSelectedGroupCandidate)
        let legacyMarker = pool.appendingPathComponent("download-" + legacy[0].id.uuidString)
            .appendingPathComponent("session.meta")
        XCTAssertEqual(try JSONDecoder().decode(DownloadDisk.Marker.self,
            from: Data(contentsOf: legacyMarker)).version, 1)
        try await legacy[0].append(request: batch.items[0].selection.request, offset: 0, bytes: Data([1, 2, 3]))
        _ = try await legacy[0].seal(.init(selection: batch.items[0].selection, receivedBytes: 3))
        let target = root.appendingPathComponent("Destination")
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"),
            protecting: [pool], receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let observed = try await engine.checkReceivedFileDestinations(parent: target,
            names: batch.items.map(\.localName))
        do {
            _ = try await SMBReceivedDownload(legacy[0]).preparePublicQuarantineCandidate(using: engine,
                parent: target, name: "Legacy.bin", observing: observed)
            XCTFail("A legacy batch spool entered v14 publication")
        } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .unsafe) }
        for file in legacy { _ = await file.abandon() }
        for entry in try await singleOnly.inspect() { try await singleOnly.discardIncomplete(entry.id) }

        let groupStorage = try SMBDownloadStorage(directory: pool,
            publicQuarantinePolicy: .sourceQualification,
            selectedGroupPublicQuarantinePolicy: .sourceQualification)
        XCTAssertTrue(groupStorage.publicQuarantineSelectedGroupCandidate)
        let files = try await groupStorage.store.reserveBatch(batch,
            publicQuarantineV1: groupStorage.publicQuarantineSelectedGroupCandidate)
        let bodies = [Data([4, 5, 6]), Data()]
        var published: [(UUID, URL)] = []
        for (index, file) in files.enumerated() {
            let selection = batch.items[index].selection, body = bodies[index]
            let marker = pool.appendingPathComponent("download-" + file.id.uuidString)
                .appendingPathComponent("session.meta")
            XCTAssertEqual(try JSONDecoder().decode(DownloadDisk.Marker.self,
                from: Data(contentsOf: marker)).version, 4)
            if !body.isEmpty { try await file.append(request: selection.request, offset: 0, bytes: body) }
            _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(body.count)))
            let received = SMBReceivedDownload(file)
            do {
                _ = try await received.preparePublication(using: engine,
                    parent: target, name: "Wrong-\(index).bin", observing: observed)
                XCTFail("V4 batch spool entered legacy publication")
            } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .unsafe) }
            let plan = try await received.preparePublicQuarantineCandidate(using: engine,
                parent: target, name: batch.items[index].localName, observing: observed)
            let outcome = await engine.performReceivedFile(plan)
            XCTAssertEqual(outcome.result.disposition, .succeeded)
            published.append((try XCTUnwrap(outcome.recordID), plan.destination))
            XCTAssertEqual(try Data(contentsOf: plan.destination), body)
            XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            let retired = await received.finishPublication(outcome)
            XCTAssertTrue(retired)
        }
        let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"),
            protecting: [pool], receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let undo = await cold.undo(recordID: published[0].0)
        XCTAssertEqual(undo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: published[0].1.path))
        XCTAssertTrue(FileManager().fileExists(atPath: published[1].1.path))
    }
    func testCapacityRefusalDoesNotCreateAnyGroupSpool() async throws {
        let directory = try LocalStorageTestFixtures.directory().appendingPathComponent("downloads")
        let store = try RemoteDownloadStore(directory: directory), batch = try plan(Array(repeating: 0, count: 16))
        let outside = try await store.reserve(try selections([0, 0])[0])
        do { _ = try await store.reserveBatch(batch); XCTFail("Group exceeded the shared active budget") }
        catch let failure as RemoteDownloadBatchReservationFailure {
            XCTAssertEqual(failure.cause as? RemoteDownloadStorageFailure, .capacity)
            XCTAssertTrue(failure.retainedFileIDs.isEmpty)
        }
        let records = try await store.inspect()
        XCTAssertEqual(records.map(\.id), [outside.id])
        _ = await outside.abandon(); try await store.discardIncomplete(outside.id)
    }
    #if DEBUG
    func testSecondHeaderFaultRetainsOnlyItsCompletedPriorAllocation() async throws {
        for publicQuarantineV1 in [false, true] {
            let directory = try LocalStorageTestFixtures.directory().appendingPathComponent("downloads")
            let fault = SMBSecondHeaderFault()
            let store = try RemoteDownloadStore(directory: directory,
                hooks: .init(failBatchAfterMetadataSync: { try fault.afterSync($0) }))
            let batch = try plan([0, 0, 0])
            do {
                _ = try await store.reserveBatch(batch, publicQuarantineV1: publicQuarantineV1)
                XCTFail("Injected constructor failure returned")
            } catch let failure as RemoteDownloadBatchReservationFailure {
                XCTAssertEqual(failure.cause as? RemoteDownloadStorageFailure, .unavailable)
                let records = try await store.inspect()
                XCTAssertEqual(records.count, 1)
                XCTAssertEqual(failure.retainedFileIDs, records.map(\.id))
                XCTAssertFalse(records[0].active)
            }
            let next = try await store.reserveBatch(batch, publicQuarantineV1: publicQuarantineV1)
            XCTAssertEqual(next.count, 3)
            for file in next { _ = await file.abandon() }
            for record in try await store.inspect() { try await store.discardIncomplete(record.id) }
            let empty = try await store.inspect(); XCTAssertTrue(empty.isEmpty)
        }
    }
    #endif
}
