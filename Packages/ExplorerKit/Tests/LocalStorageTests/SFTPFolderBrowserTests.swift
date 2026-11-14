import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private actor FolderTransport: SFTPDirectoryTransport {
    nonisolated let allowsRequestedDownloads = true
    nonisolated let allowsRequestedFolderDownloads: Bool
    let holdPrepare: Bool, holdReceive: Bool, holdClose: Bool
    private var generation = UUID(), loaded = false, ended = false, closeReleased = false, active = 0
    private var waitingPrepare: CheckedContinuation<Void, Never>?, waitingReceive: CheckedContinuation<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var prepares = 0, receives = 0, releases = 0, closes = 0, maximum = 0
    init(allowsFolders: Bool = true, holdPrepare: Bool = false, holdReceive: Bool = false, holdClose: Bool = false) {
        allowsRequestedFolderDownloads = allowsFolders; self.holdPrepare = holdPrepare; self.holdReceive = holdReceive; self.holdClose = holdClose
    }
    var snapshot: SFTPStoredSnapshot { .init(read: 7, revision: loaded ? 9 : 0, count: loaded ? 1 : 0, folders: loaded ? 1 : 0, state: loaded ? .complete : .loading) }
    private func begin() { active += 1; maximum = max(maximum, active) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        begin(); defer { active -= 1 }; generation = UUID(); loaded = false; return (generation, snapshot)
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot {
        begin(); defer { active -= 1 }; guard !ended, generation == self.generation else { throw SFTPBrowserFailure.stopped }; loaded = true; return snapshot
    }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
        begin(); defer { active -= 1 }; guard !ended, generation == self.generation else { throw SFTPBrowserFailure.stopped }
        return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: 0, rows: [try row()])
    }
    func row() throws -> SFTPStoredRow {
        .init(observation: 2, entry: .init(name: try SFTPRemoteName(Data("Generated".utf8)), logicalBytes: 4096, modifiedSeconds: 19, permissions: 0o040755))
    }
    func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection, progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload {
        begin(); defer { active -= 1 }; prepares += 1
        if holdPrepare { await withCheckedContinuation { waitingPrepare = $0 } }
        guard !ended else { throw SFTPBrowserFailure.stopped }
        return try .init(selection: selection, manifest: FolderFixture.manifest())
    }
    func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws {
        begin(); defer { active -= 1 }; releases += 1; guard !ended else { throw SFTPBrowserFailure.stopped }
    }
    func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPFolderDownloadReceipt {
        begin(); defer { active -= 1 }; receives += 1
        if holdReceive { await withCheckedContinuation { waitingReceive = $0 } }
        guard !ended else { throw SFTPBrowserFailure.stopped }
        for (ordinal, node) in prepared.manifest.nodes.enumerated() where !node.directory {
            try tree.beginMember(request: prepared.selection.request, ordinal: ordinal)
            if node.size == 7 {
                try await Task.detached { try tree.appendOnSessionExecutor(request: prepared.selection.request, ordinal: ordinal, offset: 0, bytes: Data("Fixture".utf8)) }.value
            }
            try tree.endMember(request: prepared.selection.request, ordinal: ordinal, receivedBytes: node.size!)
        }
        return .init(request: prepared.selection.request, bytes: 7, files: 2)
    }
    func releaseClose() { closeReleased = true; let waiters = closeWaiters; closeWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func close() async -> SFTPWorkerClose {
        if !ended {
            closes += 1; ended = true; let prepare = waitingPrepare, receive = waitingReceive
            waitingPrepare = nil; waitingReceive = nil; prepare?.resume(); receive?.resume()
        }
        if holdClose && !closeReleased { await withCheckedContinuation { closeWaiters.append($0) } }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
}
private final class FolderReturned: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func finish() { lock.withLock { value = true } }; var ended: Bool { lock.withLock { value } }
}

final class SFTPFolderBrowserTests: XCTestCase, @unchecked Sendable {
    private func eventually(_ check: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await check()) { guard ContinuousClock.now < end else { throw SFTPBrowserFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
    }
    private func ready(_ transport: FolderTransport) async throws -> (SFTPBrowserSession, SFTPFolderDownloadSelection) {
        let session = SFTPBrowserSession(id: UUID(), transport: transport), generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        return (session, try await .init(generation: generation, snapshot: transport.snapshot, row: transport.row()))
    }
    func testReviewReadsNoBodiesBlocksNavigationAndReleasesWithoutDisconnect() async throws {
        let f = try FolderFixture(), transport = FolderTransport(), (session, selected) = try await ready(transport)
        let prepared = try await session.prepareFolderDownload(selected)
        let storage = try SFTPDownloadStorage(directory: f.pool), inventory = try await storage.inspect(), bodies = await transport.receives
        XCTAssertTrue(inventory.isEmpty); XCTAssertEqual(bodies, 0); XCTAssertFalse(FileManager().fileExists(atPath: f.pool.path))
        do { _ = try await session.navigate(pathUTF8: Data("/Other".utf8)); XCTFail() } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        try await session.releaseFolderDownload(prepared)
        let page = try await session.page(offset: 0), releases = await transport.releases, closes = await transport.closes
        XCTAssertEqual(page.rows.count, 1); XCTAssertEqual(releases, 1); XCTAssertEqual(closes, 0)
        _ = await session.close()
    }
    func testFinalDownloadReceivesOneLeaseAndThenBrowsingResumes() async throws {
        let f = try FolderFixture(), transport = FolderTransport(), (session, selected) = try await ready(transport)
        let prepared = try await session.prepareFolderDownload(selected), storage = try SFTPDownloadStorage(directory: f.pool)
        let received = try await session.downloadFolder(prepared, storage: storage), records = try await storage.inspect()
        XCTAssertEqual(received.logicalBytes, 7); XCTAssertEqual(records.count, 1); XCTAssertTrue(records[0].active)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 1)
        await received.retainForReview(); try await storage.discardIncomplete(received.id)
        _ = await session.close(); let maximum = await transport.maximum; XCTAssertEqual(maximum, 1)
    }
    func testMetadataOnlyConnectionCannotPrepareOrAllocateFolderBodyStorage() async throws {
        let f = try FolderFixture(), transport = FolderTransport(allowsFolders: false), (session, selected) = try await ready(transport)
        do { _ = try await session.prepareFolderDownload(selected); XCTFail() } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.prepares; XCTAssertEqual(calls, 0); XCTAssertFalse(FileManager().fileExists(atPath: f.pool.path)); _ = await session.close()
    }
    func testStopDuringDiscoveryWaitsForActualCloseAndCreatesNoBodyLease() async throws {
        let f = try FolderFixture(), transport = FolderTransport(holdPrepare: true, holdClose: true), (session, selected) = try await ready(transport), returned = FolderReturned()
        let task = Task { defer { returned.finish() }; return try await session.prepareFolderDownload(selected) }
        try await eventually { await transport.prepares == 1 }; task.cancel(); try await eventually { await transport.closes == 1 }
        await Task.yield(); XCTAssertFalse(returned.ended); XCTAssertFalse(FileManager().fileExists(atPath: f.pool.path))
        await transport.releaseClose(); do { _ = try await task.value; XCTFail() } catch {}
        let drain = await session.close(); XCTAssertTrue(drain.localResourcesEnded)
    }
    func testStopDuringReceiptRetainsActiveLeaseUntilActualDrain() async throws {
        let f = try FolderFixture(), transport = FolderTransport(holdReceive: true, holdClose: true), (session, selected) = try await ready(transport)
        let prepared = try await session.prepareFolderDownload(selected), storage = try SFTPDownloadStorage(directory: f.pool), returned = FolderReturned()
        let task = Task { defer { returned.finish() }; return try await session.downloadFolder(prepared, storage: storage) }
        try await eventually { await transport.receives == 1 }; task.cancel(); try await eventually { await transport.closes == 1 }
        await Task.yield(); XCTAssertFalse(returned.ended); let active = try await storage.inspect(); XCTAssertTrue(active[0].active)
        await transport.releaseClose(); do { _ = try await task.value; XCTFail() } catch {}
        let drain = await session.close(), ended = try await storage.inspect(); XCTAssertTrue(drain.localResourcesEnded); XCTAssertFalse(ended[0].active)
        try await storage.discardIncomplete(ended[0].id)
    }
}
