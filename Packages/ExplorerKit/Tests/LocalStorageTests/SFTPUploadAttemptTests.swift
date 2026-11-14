import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class UploadAccessCounts: @unchecked Sendable {
    private let lock = NSLock(); private var starts = 0, stops = 0, main = false
    var value: (starts: Int, stops: Int, main: Bool) { lock.withLock { (starts, stops, main) } }
    var hooks: UploadSourceAccessHooks { .init(start: { [self] _ in lock.withLock { starts += 1; main = main || Thread.isMainThread }; return true },
        stop: { [self] _ in lock.withLock { stops += 1; main = main || Thread.isMainThread } }) }
}
private final class UploadThirdCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var commits = 0
    func inspect(_ stage: SFTPUploadLedger.Stage) throws {
        guard stage == .beforeRename else { return }
        let ordinal = lock.withLock { commits += 1; return commits }
        if ordinal == 3 { throw RemoteSettingsFailure.unavailable }
    }
}
final class SFTPUploadAttemptTests: XCTestCase, @unchecked Sendable {
    private func context(host: String = "generated.example", port: UInt16 = 22, account: String = "generated", scope: UInt32 = 0, keyByte: UInt8 = 1, routeBinding: Data? = nil) throws -> SFTPVerifiedSessionContext {
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: keyByte, count: 32), into: &key)
        return .init(host: host, port: port, requestedScopeID: scope, account: account, key: try SFTPHostKey(key), previous: nil, permitsRememberingHost: false, routeKeyBinding: routeBinding)
    }
    private func attempt(_ fixture: UploadFoundationFixture, storage: SFTPUploadStorage, session: UUID, generation: UUID, bytes: Data = Data([1, 2, 3]), routeBinding: Data? = nil) async throws -> SFTPUploadAttempt {
        try bytes.write(to: fixture.file, options: .withoutOverwriting)
        return try await .prepare(.init(generation: generation, source: fixture.file, name: "Draft.bin"),
            destination: .init(session: session, generation: generation, revision: 1, directory: "/generated", context: context(routeBinding: routeBinding)), storage: storage, excluding: [])
    }
    func testUnsentDiscardEndsOnlyTheLocalClaimWithoutRemoteAuthority() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history)
        let value = try await attempt(fixture, storage: storage, session: UUID(), generation: UUID())
        let prepared = try await storage.inspect(); XCTAssertEqual(prepared.records.first?.outcome, .prepared); XCTAssertEqual(prepared.records.first?.active, true)
        await value.discardUnsent(); await value.discardUnsent()
        let ended = try await storage.inspect(); XCTAssertEqual(ended.records.first?.outcome, .notStarted); XCTAssertEqual(ended.records.first?.active, false)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3])); let closed = await storage.close(); XCTAssertTrue(closed)
    }
    func testAttemptCannotCrossSessionHostKeyPortAccountOrScope() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history), session = UUID()
        let value = try await attempt(fixture, storage: storage, session: session, generation: UUID())
        XCTAssertNoThrow(try value.validate(session: session, context: context()))
        XCTAssertThrowsError(try value.validate(session: UUID(), context: context()))
        for changed in [try context(host: "other.example"), try context(port: 23), try context(account: "other"), try context(scope: 1), try context(keyByte: 2)] {
            XCTAssertThrowsError(try value.validate(session: session, context: changed))
        }
        await value.discardUnsent(); _ = await storage.close()
    }
    func testTransferredOwnershipSurvivesCallerDiscardAndVerifiedEndIsDurable() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history)
        let value = try await attempt(fixture, storage: storage, session: UUID(), generation: UUID())
        try value.takeForWorker(); await value.discardUnsent()
        let owned = try await storage.inspect(); XCTAssertEqual(owned.records.first?.active, true)
        let digest = try await Task.detached {
            try value.requestCreationOnSessionExecutor()
            let body = try value.readOnSessionExecutor(offset: 0, count: 3); XCTAssertEqual(body, Data([1, 2, 3]))
            let digest = Data(SHA256.hash(data: body)); try value.permitPublicationOnSessionExecutor(digest: digest); return digest
        }.value
        let publishing = try await storage.inspect(); XCTAssertEqual(publishing.records.first?.outcome, .publicationRequested)
        let result = try await Task.detached { try value.finishOnSessionExecutor(.init(selection: value.selection, digest: digest)) }.value
        XCTAssertEqual(result.id, value.record.id); XCTAssertEqual(result.logicalBytes, 3)
        _ = await storage.close(); let cold = try await storage.inspect(); XCTAssertEqual(cold.records.first?.outcome, .verified); XCTAssertEqual(cold.records.first?.active, false)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3]))
    }
    func testCleanFirstOpenRefusalEndsPinnedSourceWithDurableNotStarted() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history)
        let value = try await attempt(fixture, storage: storage, session: UUID(), generation: UUID())
        try value.takeForWorker()
        try await Task.detached {
            try value.requestCreationOnSessionExecutor()
            try value.finishRefusedOpenOnSessionExecutor()
        }.value
        await value.discardUnsent()
        let live = try await storage.inspect()
        XCTAssertEqual(live.records.first?.outcome, .notStarted)
        XCTAssertEqual(live.records.first?.active, false)
        _ = await storage.close()
        let cold = try await storage.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .notStarted)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3]))
    }
    func testFirstOpenRefusalCannotBecomeHealthyWhenNotStartedSaveFails() async throws {
        let fixture = try UploadFoundationFixture(), fault = UploadThirdCommitFault()
        let storage = SFTPUploadStorage(directory: fixture.history, probe: { try fault.inspect($0) })
        let value = try await attempt(fixture, storage: storage, session: UUID(), generation: UUID())
        try value.takeForWorker()
        try await Task.detached { try value.requestCreationOnSessionExecutor() }.value
        let committed = fixture.history.appendingPathComponent("servers.json")
        let durablePrefix = try Data(contentsOf: committed)
        do {
            try await Task.detached { try value.finishRefusedOpenOnSessionExecutor() }.value
            XCTFail("A failed durable outcome save cannot release a healthy refusal")
        } catch {
            XCTAssertEqual(error as? RemoteSettingsFailure, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: committed), durablePrefix)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3]))
        await value.discardUnsent() // Worker ownership was not released as an unsent attempt.
        XCTAssertEqual(try Data(contentsOf: committed), durablePrefix)
        _ = await storage.close()
    }
    func testAttemptRetainsExactDirectOrRoutedAuthorityUntilWorkerAdmission() async throws {
        for binding in [Data?.none, Data(repeating: 11, count: 32)] {
            let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history), session = UUID()
            let value = try await attempt(fixture, storage: storage, session: session, generation: UUID(), routeBinding: binding)
            XCTAssertNoThrow(try value.validate(session: session, context: context(routeBinding: binding)))
            for replacement in [Data?.none, Data(repeating: 11, count: 32), Data(repeating: 12, count: 32)] where replacement != binding {
                XCTAssertThrowsError(try value.validate(session: session, context: context(routeBinding: replacement)), "A copied target identity must not change the retained route")
            }
            await value.discardUnsent(); _ = await storage.close()
            XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3]))
        }
    }
    func testChangedSourceCannotObtainPublicationPermission() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history)
        let value = try await attempt(fixture, storage: storage, session: UUID(), generation: UUID()); try value.takeForWorker()
        _ = try await Task.detached { try value.readOnSessionExecutor(offset: 0, count: 3) }.value
        let fd = open(fixture.file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(pwrite(fd, [UInt8(9)], 1, 0), 1); close(fd)
        try await Task.detached {
            XCTAssertThrowsError(try value.permitPublicationOnSessionExecutor(digest: Data(SHA256.hash(data: Data([1, 2, 3])))))
            value.endAfterActualDrainOnSessionExecutor(noRemoteMutation: false)
        }.value
        let saved = try await storage.inspect(); XCTAssertEqual(saved.records.first?.outcome, .reviewPublication); XCTAssertEqual(saved.records.first?.active, false); _ = await storage.close()
    }
    func testAccessLeaseStaysUntilActualHeldSourceUserAndCloseDrain() async throws {
        let fixture = try UploadFoundationFixture(), counts = UploadAccessCounts(), gate = UploadTestGate()
        try Data([1, 2, 3]).write(to: fixture.file, options: .withoutOverwriting)
        let source = try await SFTPUploadSource.prepare(fixture.file, excluding: [], readProbe: { try gate.hold() }, accessHooks: counts.hooks)
        XCTAssertEqual(counts.value.starts, 1); XCTAssertEqual(counts.value.stops, 0)
        let reading = Task.detached { try source.readOnSessionExecutor(offset: 0, maximum: 3) }
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next(); source.requestStop()
        let draining = Task { await source.drain() }; XCTAssertEqual(counts.value.stops, 0); gate.release.signal()
        do { _ = try await reading.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }
        await draining.value; await source.drain(); XCTAssertEqual(counts.value.stops, 1); XCTAssertFalse(counts.value.main)
    }
    func testFailedSourceCaptureReleasesItsExactAccessLease() async throws {
        let fixture = try UploadFoundationFixture(), counts = UploadAccessCounts()
        do { _ = try await SFTPUploadSource.prepare(fixture.file, excluding: [], accessHooks: counts.hooks); XCTFail() } catch {}
        XCTAssertEqual(counts.value.starts, 1); XCTAssertEqual(counts.value.stops, 1); XCTAssertFalse(counts.value.main)
    }
    func testUploadCapabilityCannotBeAdmittedWithoutPagedDownloadMode() async throws {
        let peer = SFTPPeerConfiguration(host: "generated.example", port: 22, numericHost: "127.0.0.1", scopeID: 0,
            bundle: Bundle.main.bundleURL, allowsFreshUploads: true)
        do { _ = try await SFTPWorkerSession.begin(peer: peer, account: "generated", activity: FileActivityGate(), pool: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SFTPSessionFailure, .input) }
    }
    func testMetadataReviewIsBoundToTheSubsequentSourceObservation() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history), generation = UUID()
        try Data([1, 2, 3]).write(to: fixture.file, options: .withoutOverwriting)
        let review = try await SFTPUploadSourceReview.inspect(fixture.file, excluding: [])
        XCTAssertEqual(review.logicalBytes, 3); XCTAssertEqual(review.name, "Generated.bin")
        let request = try SFTPRequestedUpload(generation: generation, reviewed: review, name: "Draft.bin")
        let value = try await SFTPUploadAttempt.prepare(request, destination: .init(session: UUID(), generation: generation, revision: 1, directory: "/generated", context: context()), storage: storage, excluding: [])
        await value.discardUnsent(); _ = await storage.close()
    }
    func testChangedAfterReviewRefusesBeforeCreatingAnyIntent() async throws {
        let fixture = try UploadFoundationFixture(), storage = SFTPUploadStorage(directory: fixture.history), generation = UUID()
        try Data([1, 2, 3]).write(to: fixture.file, options: .withoutOverwriting)
        let review = try await SFTPUploadSourceReview.inspect(fixture.file, excluding: [])
        try Data([4, 5, 6, 7]).write(to: fixture.file)
        do {
            _ = try await SFTPUploadAttempt.prepare(.init(generation: generation, reviewed: review, name: "Draft.bin"),
                destination: .init(session: UUID(), generation: generation, revision: 1, directory: "/generated", context: context()), storage: storage, excluding: [])
            XCTFail("Changed source admitted")
        } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .changed) }
        let empty = try await storage.inspect(); XCTAssertTrue(empty.records.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.history.path))
        _ = await storage.close()
    }

    func testGeneratedEmptyUploadUsesSealedPrivateSourceAndVerifiedColdHistory() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let stageRoot = root.appendingPathComponent("private-empty-source")
        let editStorage = try SFTPTextEditStorage(directory: stageRoot)
        let uploadStorage = SFTPUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let session = UUID(), generation = UUID()
        let snapshot = try await editStorage.stageGeneratedEmpty(session: session,
            destinationGeneration: generation)
        let destinations = try FileManager().contentsOfDirectory(atPath: stageRoot.path)
            .filter { $0.hasPrefix("download-") }
        XCTAssertEqual(destinations.count, 1)
        let payload = stageRoot.appendingPathComponent(try XCTUnwrap(destinations.first))
            .appendingPathComponent("payload")
        XCTAssertEqual(try Data(contentsOf: payload), Data())
        do {
            _ = try await SFTPUploadSource.prepare(payload, excluding: [root])
            XCTFail("Ordinary Upload admitted the private source")
        } catch let failure as SFTPUploadSourceFailure {
            XCTAssertEqual(failure, .unavailable)
        } catch {
            XCTFail("Unexpected ordinary Upload admission failure: \(error)")
        }
        let destination = SFTPUploadDestination(session: session, generation: generation,
            revision: 1, directory: "/generated", context: try context())
        XCTAssertThrowsError(try snapshot.validate(destination: .init(session: UUID(),
            generation: generation, revision: 1, directory: "/generated", context: try context())))
        XCTAssertThrowsError(try snapshot.validate(destination: .init(session: session,
            generation: UUID(), revision: 1, directory: "/generated", context: try context())))
        let request = try SFTPRequestedEditedTextUpload(destinationGeneration: generation,
            snapshot: snapshot, name: "New.txt")
        let attempt = try await SFTPUploadAttempt.prepare(request, destination: destination,
            storage: uploadStorage)
        let prepared = try await uploadStorage.inspect()
        XCTAssertEqual(prepared.records.first?.sourceName, "New empty text file")
        XCTAssertEqual(prepared.records.first?.logicalBytes, 0)
        try attempt.takeForWorker()
        let digest = Data(SHA256.hash(data: Data()))
        let completed = try await Task.detached {
            try attempt.requestCreationOnSessionExecutor()
            try attempt.permitPublicationOnSessionExecutor(digest: digest)
            return try attempt.finishOnSessionExecutor(.init(selection: attempt.selection, digest: digest))
        }.value
        XCTAssertEqual(completed.logicalBytes, 0)
        let removed = await snapshot.closeAndDrain()
        XCTAssertTrue(removed)
        let remaining = try await RemoteDownloadStore(directory: stageRoot).inspect()
        XCTAssertTrue(remaining.isEmpty)
        _ = await uploadStorage.close()
        let cold = try await uploadStorage.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .verified)
        XCTAssertEqual(cold.records.first?.publication, .exclusiveFinal)
        XCTAssertEqual(cold.records.first?.active, false)
    }

    func testGeneratedEmptyUploadRemovesStageAfterDrainWithoutChangingUncertainHistory() async throws {
        for possibleMutation in [false, true] {
            let root = try LocalStorageTestFixtures.directory()
            let stageRoot = root.appendingPathComponent("private-empty-source")
            let editStorage = try SFTPTextEditStorage(directory: stageRoot)
            let uploadStorage = SFTPUploadStorage(directory: root.appendingPathComponent("upload-history"))
            let session = UUID(), generation = UUID()
            let snapshot = try await editStorage.stageGeneratedEmpty(session: session,
                destinationGeneration: generation)
            let request = try SFTPRequestedEditedTextUpload(destinationGeneration: generation,
                snapshot: snapshot, name: "New.txt")
            let attempt = try await SFTPUploadAttempt.prepare(request,
                destination: .init(session: session, generation: generation, revision: 1,
                    directory: "/generated", context: try context()), storage: uploadStorage)
            try attempt.takeForWorker()
            try await Task.detached {
                try attempt.requestCreationOnSessionExecutor()
                attempt.endAfterActualDrainOnSessionExecutor(noRemoteMutation: !possibleMutation)
            }.value
            let removed = await snapshot.closeAndDrain()
            XCTAssertTrue(removed)
            XCTAssertFalse(snapshot.retainedForReview)
            let stage = try await RemoteDownloadStore(directory: stageRoot).inspect()
            XCTAssertTrue(stage.isEmpty)
            _ = await uploadStorage.close()
            let cold = try await uploadStorage.inspect()
            XCTAssertEqual(cold.records.first?.outcome,
                possibleMutation ? .reviewPublication : .notStarted)
        }
    }

    func testDownloadedTextSnapshotsRetainUncertainPublicationEvenWhenEmpty() async throws {
        for bytes in [Data(), Data("ordinary text\n".utf8)] {
            let root = try LocalStorageTestFixtures.directory()
            let receivedRoot = root.appendingPathComponent("received")
            let stageRoot = root.appendingPathComponent("edited")
            let uploadStorage = SFTPUploadStorage(directory: root.appendingPathComponent("upload-history"))
            let session = UUID(), generation = UUID(), verifiedContext = try context()
            let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
                entry: .init(name: SFTPRemoteName(Data("Source.txt".utf8)),
                    logicalBytes: UInt64(bytes.count), modifiedSeconds: 7, permissions: 0o100600)))
            let downloaded = try await RemoteDownloadStore(directory: receivedRoot).reserve(selection)
            if !bytes.isEmpty {
                try await downloaded.append(request: selection.request, offset: 0, bytes: bytes)
            }
            _ = try await downloaded.seal(.init(selection: selection, receivedBytes: UInt64(bytes.count)))
            let lease = try await SFTPTextReadLease.mint(downloaded,
                origin: .init(session: session, selection: selection, context: verifiedContext))
            let contents = try await lease.read()
            let snapshot = try await SFTPTextEditStorage(directory: stageRoot).stage(
                contents: contents, editorGeneration: UUID(), from: lease)
            await lease.closeAndDrain()
            let request = try SFTPRequestedEditedTextUpload(destinationGeneration: generation,
                snapshot: snapshot, name: "Copy.txt")
            let attempt = try await SFTPUploadAttempt.prepare(request,
                destination: .init(session: session, generation: generation, revision: 1,
                    directory: "/generated", context: verifiedContext), storage: uploadStorage)
            try attempt.takeForWorker()
            try await Task.detached {
                try attempt.requestCreationOnSessionExecutor()
                attempt.endAfterActualDrainOnSessionExecutor(noRemoteMutation: false)
            }.value
            let removed = await snapshot.closeAndDrain()
            XCTAssertFalse(removed)
            XCTAssertTrue(snapshot.retainedForReview)
            let retainedStage = try await RemoteDownloadStore(directory: stageRoot).inspect()
            XCTAssertEqual(retainedStage.count, 1)
            _ = await uploadStorage.close()
            let cold = try await uploadStorage.inspect()
            XCTAssertEqual(cold.records.first?.outcome, .reviewPublication)
            let discarded = await snapshot.discardRetainedAfterReview()
            XCTAssertTrue(discarded)
            let remainingStage = try await RemoteDownloadStore(directory: stageRoot).inspect()
            XCTAssertTrue(remainingStage.isEmpty)
        }
    }
}
