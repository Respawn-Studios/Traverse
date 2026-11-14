import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class UploadReturnFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func finish() { lock.withLock { value = true } }
    var ended: Bool { lock.withLock { value } }
}
private actor UploadBrowserTransport: SFTPDirectoryTransport {
    nonisolated let allowsRequestedDownloads = true
    nonisolated let allowsFreshUploads: Bool
    let holdUpload: Bool, holdPage: Bool, holdClose: Bool, refuseSource: Bool
    private var uploadWait: CheckedContinuation<Void, Never>?, pageWait: CheckedContinuation<Void, Never>?, closeWait: CheckedContinuation<Void, Never>?
    private var generation = UUID(), ended = false, active = 0
    private(set) var uploads = 0, pages = 0, closes = 0, maximum = 0, opens = 0
    init(allowed: Bool = true, holdUpload: Bool = false, holdPage: Bool = false, holdClose: Bool = false, refuseSource: Bool = false) {
        allowsFreshUploads = allowed; self.holdUpload = holdUpload; self.holdPage = holdPage; self.holdClose = holdClose; self.refuseSource = refuseSource
    }
    private func begin() { active += 1; maximum = max(maximum, active) }
    var snapshot: SFTPStoredSnapshot { .init(read: UInt64(opens), revision: 1, count: 1, folders: 0, state: .complete) }
    static var row: SFTPStoredRow { .init(observation: 1, entry: .init(name: try! .init(Data("Generated.txt".utf8)), logicalBytes: 17, modifiedSeconds: 1, permissions: 0o100644)) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        begin(); defer { active -= 1 }; opens += 1; generation = UUID(); return (generation, snapshot)
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { snapshot }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
        begin(); defer { active -= 1 }; pages += 1
        if holdPage { await withCheckedContinuation { pageWait = $0 } }
        guard !ended, generation == self.generation else { throw SFTPSessionFailure.stopped }
        return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: 0, rows: [Self.row])
    }
    func upload(_ request: SFTPRequestedUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPCompletedUpload {
        begin(); defer { active -= 1 }; uploads += 1
        if refuseSource { throw SFTPUploadAdmissionFailure(cause: SFTPUploadSourceFailure.unsupportedMetadata) }
        if holdUpload { await withCheckedContinuation { uploadWait = $0 } }
        guard !ended, request.generation == generation, snapshot == self.snapshot else { throw SFTPSessionFailure.stopped }
        progress?(17); return .init(id: UUID(), logicalBytes: 17)
    }
    func releasePage() { let value = pageWait; pageWait = nil; value?.resume() }
    func releaseUpload() { let value = uploadWait; uploadWait = nil; value?.resume() }
    func releaseClose() { let value = closeWait; closeWait = nil; value?.resume() }
    func close() async -> SFTPWorkerClose {
        closes += 1; ended = true; releasePage(); releaseUpload()
        if holdClose { await withCheckedContinuation { closeWait = $0 } }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
}

final class SFTPUploadBrowserTests: XCTestCase, @unchecked Sendable {
    private func resources() throws -> (SFTPUploadStorage, URL) {
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_UPLOAD_SOURCE"] else { throw XCTSkip("Requires charged generated upload root") }
        let root = URL(fileURLWithPath: text)
        return (.init(directory: root.appendingPathComponent("pump-" + UUID().uuidString)), root.appendingPathComponent("Generated.bin"))
    }
    private func ready(_ transport: UploadBrowserTransport) async throws -> (SFTPBrowserSession, SFTPRequestedUpload) {
        let (_, source) = try resources(), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        return (session, try .init(generation: generation, source: source, name: "Draft.bin"))
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await predicate()) { guard ContinuousClock.now < end else { throw SFTPBrowserFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
    }
    func testReadOnlyConnectionRefusesWithoutTransportOrHistoryCreation() async throws {
        let (storage, _) = try resources(), transport = UploadBrowserTransport(allowed: false), (session, request) = try await ready(transport)
        XCTAssertFalse(session.allowsFreshUploads)
        do { _ = try await session.upload(request, storage: storage, excluding: []); XCTFail("Read-only upload") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.uploads, history = try await storage.inspect(); XCTAssertEqual(calls, 0); XCTAssertTrue(history.records.isEmpty)
        _ = await session.close()
    }
    func testSerialUploadThenPageKeepsSameOwner() async throws {
        let (storage, _) = try resources(), transport = UploadBrowserTransport(), (session, request) = try await ready(transport)
        let value = try await session.upload(request, storage: storage, excluding: []); XCTAssertEqual(value.logicalBytes, 17)
        let page = try await session.page(offset: 0), maximum = await transport.maximum; XCTAssertEqual(page.rows.count, 1); XCTAssertEqual(maximum, 1)
        _ = await session.close()
    }
    func testQueuedCancellationNeverCallsUploadOrClosesConnection() async throws {
        let (storage, _) = try resources(), transport = UploadBrowserTransport(holdPage: true), (session, request) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let upload = Task { try await session.upload(request, storage: storage, excluding: []) }; try await eventually { await session.uploadState.queued }
        upload.cancel(); do { _ = try await upload.value; XCTFail("Queued cancellation") } catch {}
        await transport.releasePage(); _ = try await page.value
        let calls = await transport.uploads, closes = await transport.closes; XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 0); XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testActiveCancellationWaitsForActualClose() async throws {
        let (storage, _) = try resources(), transport = UploadBrowserTransport(holdUpload: true, holdClose: true), (session, request) = try await ready(transport)
        let returned = UploadReturnFlag(), upload = Task { defer { returned.finish() }; return try await session.upload(request, storage: storage, excluding: []) }
        try await eventually { await transport.uploads == 1 }; upload.cancel(); try await eventually { await transport.closes == 1 }
        XCTAssertFalse(returned.ended); await transport.releaseClose()
        do { _ = try await upload.value; XCTFail("Active cancellation") } catch {}
        let ended = await session.close(); XCTAssertTrue(ended.localResourcesEnded); let closes = await transport.closes; XCTAssertEqual(closes, 1)
    }
    func testNavigationInvalidatesQueuedUploadWithoutPoisoningSession() async throws {
        let (storage, _) = try resources(), transport = UploadBrowserTransport(holdPage: true), (session, request) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let upload = Task { try await session.upload(request, storage: storage, excluding: []) }; try await eventually { await session.uploadState.queued }
        let navigation = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await transport.releasePage(); _ = try await page.value; _ = try await navigation.value
        do { _ = try await upload.value; XCTFail("Stale queued upload") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let calls = await transport.uploads; XCTAssertEqual(calls, 0); XCTAssertNil(session.latest.failure); _ = await session.close()
    }
    func testOneTransferAtATimeAndAdmissionRefusalKeepsBrowseUsable() async throws {
        let (storage, source) = try resources(), transport = UploadBrowserTransport(holdUpload: true), (session, request) = try await ready(transport)
        let first = Task { try await session.upload(request, storage: storage, excluding: []) }; try await eventually { await transport.uploads == 1 }
        do { _ = try await session.upload(request, storage: storage, excluding: []); XCTFail("Second upload") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        let downloads = try SFTPDownloadStorage(directory: source.deletingLastPathComponent().appendingPathComponent("unused-" + UUID().uuidString))
        do { _ = try await session.download(.init(generation: request.generation, row: UploadBrowserTransport.row), storage: downloads); XCTFail("Overlapping download") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        await transport.releaseUpload(); _ = try await first.value; _ = await session.close()
        let refused = UploadBrowserTransport(refuseSource: true), (second, next) = try await ready(refused)
        do { _ = try await second.upload(next, storage: storage, excluding: []); XCTFail("Resource fork") } catch { XCTAssertEqual(error as? SFTPUploadLocalIssue, .additionalFork) }
        XCTAssertNil(second.latest.failure); _ = try await second.page(offset: 0); _ = await second.close()
    }
}
