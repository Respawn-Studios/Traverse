import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPFolderUploadAttemptTests: XCTestCase, @unchecked Sendable {
    private func destination(_ f: FolderUploadFixture, generation: UUID) throws -> SFTPUploadDestination {
        .init(session: UUID(), generation: generation, revision: 1, directory: "/generated",
            context: .init(host: "generated.invalid", port: 22, requestedScopeID: 0, account: "generated", key: try f.key(), previous: nil, permitsRememberingHost: false))
    }
    func testUnsentClaimIsNotReplayAuthorityAndDiscardReleasesActiveHistory() async throws {
        let f = try FolderUploadFixture(); try f.file("Member", Data([1]))
        let review = try await SFTPFolderUploadSourceReview.inspect(f.tree, excluding: []), generation = UUID(), destination = try destination(f, generation: generation)
        let request = try SFTPRequestedFolderUpload(generation: generation, reviewed: review, name: "New Folder"), storage = SFTPUploadStorage(directory: f.history)
        let attempt = try await SFTPFolderUploadAttempt.prepare(request, destination: destination, storage: storage, excluding: [])
        XCTAssertThrowsError(try attempt.validate(session: UUID(), context: destination.context))
        let wrong = SFTPVerifiedSessionContext(host: "different.invalid", port: 22, requestedScopeID: 0, account: "generated", key: try f.key(), previous: nil, permitsRememberingHost: false)
        XCTAssertThrowsError(try attempt.validate(session: destination.session, context: wrong))
        try attempt.validate(session: destination.session, context: destination.context)
        await attempt.discardUnsent(); await attempt.discardUnsent()
        let cold = try await storage.inspect(); XCTAssertTrue(cold.records.allSatisfy { !$0.active }); XCTAssertEqual(cold.records.first?.outcome, .notStarted)
        let closed = await storage.close(); XCTAssertTrue(closed); XCTAssertEqual(try Data(contentsOf: f.tree.appendingPathComponent("Member")), Data([1]))
    }
    func testSameSizeNestedReplacementAfterReviewRefusesBeforeHistoryOrBody() async throws {
        let f = try FolderUploadFixture(); try f.folder("Nested"); try f.file("Nested/Member", Data([1]))
        let review = try await SFTPFolderUploadSourceReview.inspect(f.tree, excluding: []), generation = UUID(), destination = try destination(f, generation: generation)
        try FileManager().moveItem(at: f.tree.appendingPathComponent("Nested/Member"), to: f.root.appendingPathComponent("Retained Member")); try f.file("Nested/Member", Data([1]))
        let storage = SFTPUploadStorage(directory: f.history)
        do { let attempt = try await SFTPFolderUploadAttempt.prepare(.init(generation: generation, reviewed: review, name: "New Folder"), destination: destination, storage: storage, excluding: []); await attempt.discardUnsent(); XCTFail() }
        catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .changed) }
        let records = try await storage.inspect(); XCTAssertTrue(records.records.isEmpty); XCTAssertFalse(FileManager().fileExists(atPath: f.history.path)); _ = await storage.close()
    }
    func testFolderAttemptCannotSubstituteDirectOrDifferentRouteForSameTarget() async throws {
        for binding in [Data?.none, Data(repeating: 11, count: 32)] {
            let f = try FolderUploadFixture(); try f.file("Member", Data([1]))
            let review = try await SFTPFolderUploadSourceReview.inspect(f.tree, excluding: []), generation = UUID()
            let context = SFTPVerifiedSessionContext(host: "generated.invalid", port: 22, requestedScopeID: 0, account: "generated", key: try f.key(), previous: nil, permitsRememberingHost: false, routeKeyBinding: binding)
            let destination = SFTPUploadDestination(session: UUID(), generation: generation, revision: 1, directory: "/generated", context: context)
            let storage = SFTPUploadStorage(directory: f.history)
            let attempt = try await SFTPFolderUploadAttempt.prepare(.init(generation: generation, reviewed: review, name: "New Folder"), destination: destination, storage: storage, excluding: [])
            XCTAssertNoThrow(try attempt.validate(session: destination.session, context: context))
            for replacement in [Data?.none, Data(repeating: 11, count: 32), Data(repeating: 12, count: 32)] where replacement != binding {
                var changed = context; changed.routeKeyBinding = replacement
                XCTAssertThrowsError(try attempt.validate(session: destination.session, context: changed))
            }
            await attempt.discardUnsent(); _ = await storage.close()
            XCTAssertEqual(try Data(contentsOf: f.tree.appendingPathComponent("Member")), Data([1]))
        }
    }
    func testActualSourceBarriersAndSixteenFileCheckpoints() async throws {
        final class Commits: @unchecked Sendable { let lock = NSLock(); var count = 0; func note(_ stage: SFTPUploadLedger.Stage) { if stage == .stagingWritten { lock.withLock { count += 1 } } } }
        let f = try FolderUploadFixture(); for index in 0..<17 { try f.file(String(format: "%03d", index), Data()) }
        let review = try await SFTPFolderUploadSourceReview.inspect(f.tree, excluding: []), generation = UUID(), destination = try destination(f, generation: generation), commits = Commits()
        let storage = SFTPUploadStorage(directory: f.history, probe: { commits.note($0) })
        let attempt = try await SFTPFolderUploadAttempt.prepare(.init(generation: generation, reviewed: review, name: "New Folder"), destination: destination, storage: storage, excluding: [], clock: { 0 })
        let result = try await Task.detached {
            try attempt.takeForWorker(); try attempt.requestCreationOnSessionExecutor()
            XCTAssertThrowsError(try attempt.readOnSessionExecutor(node: 1, offset: 0, count: 1))
            try attempt.acknowledgeRootOnSessionExecutor()
            let empty = Data(SHA256.hash(data: Data()))
            for index in 1...17 { try attempt.permitFileOnSessionExecutor(node: index, digest: empty); try attempt.checkpointOnSessionExecutor(node: index, files: index, bytes: 0) }
            var hash = SHA256(); hash.update(data: attempt.selection.manifest.encoded); for _ in 0..<17 { hash.update(data: empty) }; let digest = Data(hash.finalize())
            try attempt.permitFinalOnSessionExecutor(digest: digest)
            return try attempt.finishOnSessionExecutor(.init(selection: attempt.selection, digest: digest))
        }.value
        XCTAssertEqual(result.files, 17); XCTAssertEqual(result.logicalBytes, 0)
        // Prepared, creation intent, root,16 files, last file, final, drain.
        XCTAssertEqual(commits.lock.withLock { commits.count }, 7)
        let saved = try await storage.inspect(); XCTAssertEqual(saved.records.first?.outcome, .verified); XCTAssertTrue(saved.records.allSatisfy { !$0.active }); _ = await storage.close()
    }
}

private actor FolderUploadTransport: SFTPDirectoryTransport {
    nonisolated let allowsFreshUploads = true
    nonisolated let allowsFreshFolderUploads: Bool
    private let generation = UUID(), hold: Bool
    private var waiting: CheckedContinuation<Void, Never>?, closeWait: CheckedContinuation<Void, Never>?
    private var ended = false
    private(set) var calls = 0, closes = 0, returned = false
    init(allowed: Bool = true, hold: Bool = false) { allowsFreshFolderUploads = allowed; self.hold = hold }
    private var snapshot: SFTPStoredSnapshot { .init(read: 1, revision: 1, count: 0, folders: 0, state: .complete) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) { (generation, snapshot) }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { snapshot }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? { nil }
    func uploadFolder(_ request: SFTPRequestedFolderUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage, excluding roots: [URL], progress: (@Sendable (UInt64, Int) -> Void)?) async throws -> SFTPCompletedFolderUpload {
        calls += 1; if hold { await withCheckedContinuation { waiting = $0 } }; returned = true
        guard !ended, generation == request.generation else { throw SFTPBrowserFailure.stopped }
        return .init(id: UUID(), files: 0, folders: 0, logicalBytes: 0)
    }
    func close() async -> SFTPWorkerClose {
        closes += 1; ended = true; let release = waiting; waiting = nil; release?.resume()
        if hold { await withCheckedContinuation { closeWait = $0 } }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
    func releaseActualClose() { let release = closeWait; closeWait = nil; release?.resume() }
}
final class SFTPFolderUploadPumpTests: XCTestCase, @unchecked Sendable {
    private func eventually(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await predicate()) { guard ContinuousClock.now < end else { throw SFTPBrowserFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
    }
    private func ready(_ transport: FolderUploadTransport) async throws -> (SFTPBrowserSession, SFTPRequestedFolderUpload, SFTPUploadStorage) {
        let f = try FolderUploadFixture(), review = try await SFTPFolderUploadSourceReview.inspect(f.tree, excluding: [])
        let session = SFTPBrowserSession(id: UUID(), transport: transport), generation = try await session.navigate(pathUTF8: Data(".".utf8))
        return (session, try .init(generation: generation, reviewed: review, name: "New Folder"), .init(directory: f.history))
    }
    func testFileOnlyConsentRefusesFolderWithoutTransportOrHistory() async throws {
        let transport = FolderUploadTransport(allowed: false), (session, request, storage) = try await ready(transport)
        XCTAssertTrue(session.allowsFreshUploads); XCTAssertFalse(session.allowsFreshFolderUploads)
        do { _ = try await session.uploadFolder(request, storage: storage, excluding: []); XCTFail() } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.calls, history = try await storage.inspect(); XCTAssertEqual(calls, 0); XCTAssertTrue(history.records.isEmpty); _ = await session.close(); _ = await storage.close()
    }
    func testActiveFolderSerializesNavigationAndCancellationWaitsActualClose() async throws {
        let transport = FolderUploadTransport(hold: true), (session, request, storage) = try await ready(transport)
        let uploading = Task { try await session.uploadFolder(request, storage: storage, excluding: []) }; try await eventually { await transport.calls == 1 }
        let navigation = Task { try await session.navigate(pathUTF8: Data("/other".utf8)) }
        try await eventually { await session.queueState.navigation }
        navigation.cancel(); do { _ = try await navigation.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stopped) }
        do { _ = try await session.uploadFolder(request, storage: storage, excluding: []); XCTFail() } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        uploading.cancel(); try await eventually { let closes = await transport.closes, returned = await transport.returned; return closes == 1 && returned }
        await transport.releaseActualClose()
        do { _ = try await uploading.value; XCTFail() } catch {}
        let result = await session.close(); XCTAssertTrue(result.actualExit && result.ipcEOF); _ = await storage.close()
    }
}
