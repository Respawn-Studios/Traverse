import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) @testable import LocalStorage

private final class DownloadReturnFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func finish() { lock.withLock { value = true } }
    var ended: Bool { lock.withLock { value } }
}
#if DEBUG
private final class BatchHeaderFault: @unchecked Sendable {
    private let lock = NSLock()
    private var headers = 0
    func afterSync(_ id: UUID) throws {
        let fail = lock.withLock { headers += 1; return headers == 2 }
        if fail { throw RemoteDownloadStorageFailure.unavailable }
    }
}
private final class BatchUnexpectedHeaderFault: @unchecked Sendable {
    private let lock = NSLock()
    private var headers = 0, created: UUID?
    let directory: URL
    init(directory: URL) { self.directory = directory }
    var retainedID: UUID? { lock.withLock { created } }
    func afterSync(_ id: UUID) throws {
        let inject = lock.withLock { headers += 1; if headers == 2 { created = id }; return headers == 2 }
        if inject {
            let extra = directory.appendingPathComponent("download-" + id.uuidString).appendingPathComponent("unexpected.txt")
            try Data("preserve generated unexpected content".utf8).write(to: extra, options: .withoutOverwriting)
            throw RemoteDownloadStorageFailure.unavailable
        }
    }
}
#endif
private actor DownloadBrowserTransport: SFTPDirectoryTransport {
    nonisolated let allowsRequestedDownloads: Bool
    nonisolated let sessionID = UUID()
    let holdDownload: Bool, holdPage: Bool, holdClose: Bool
    let listedRows: Int, failAtDownload: Int?
    private var heldDownload: CheckedContinuation<Void, Never>?, heldPage: CheckedContinuation<Void, Never>?
    private var generation = UUID(), count: UInt64 = 0, active = 0
    private(set) var downloads = 0, pages = 0, closes = 0, maximum = 0, opens = 0
    private var ended = false
    private var heldClose: CheckedContinuation<Void, Never>?
    init(holdDownload: Bool = false, holdPage: Bool = false, holdClose: Bool = false,
         allowsDownloads: Bool = true, listedRows: Int = 1, failAtDownload: Int? = nil) {
        self.holdDownload = holdDownload; self.holdPage = holdPage; self.holdClose = holdClose
        self.listedRows = listedRows; self.failAtDownload = failAtDownload; allowsRequestedDownloads = allowsDownloads
    }
    var snapshot: SFTPStoredSnapshot { .init(read: UInt64(opens), revision: count, count: count, folders: 0, state: count == 0 ? .loading : .complete) }
    private func begin() { active += 1; maximum = max(maximum, active) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        begin(); defer { active -= 1 }; opens += 1; generation = UUID(); count = 0; return (generation, snapshot)
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot {
        begin(); defer { active -= 1 }; guard !ended, generation == self.generation else { throw SFTPSessionFailure.stopped }; count = UInt64(listedRows); return snapshot
    }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
        begin(); defer { active -= 1 }; pages += 1
        if holdPage { await withCheckedContinuation { heldPage = $0 } }
        guard !ended, generation == self.generation else { throw SFTPSessionFailure.stopped }
        let rows = listedRows == 1 ? [Self.row] : (1...listedRows).map { Self.batchRow($0) }
        return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: 0, rows: rows)
    }
    static var row: SFTPStoredRow { .init(observation: 1, entry: .init(name: try! .init(Data("Generated.txt".utf8)), logicalBytes: 17, modifiedSeconds: 1, permissions: 0o100644)) }
    static func batchRow(_ index: Int) -> SFTPStoredRow {
        .init(observation: UInt64(index), entry: .init(name: try! .init(Data("Generated-\(index).txt".utf8)),
            logicalBytes: 17, modifiedSeconds: 1, permissions: 0o100644))
    }
    func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile, progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPDownloadReceipt {
        begin(); defer { active -= 1 }; downloads += 1
        if holdDownload { await withCheckedContinuation { heldDownload = $0 } }
        guard !ended else { throw SFTPSessionFailure.stopped }
        try await file.append(request: selection.request, offset: 0, bytes: Data(repeating: 42, count: 17)); progress?(17)
        if failAtDownload == downloads { throw SFTPSessionFailure.exited }
        return .init(selection: selection, receivedBytes: 17)
    }
    func textOrigin(_ selection: SFTPDownloadSelection) async throws -> SFTPTextOrigin {
        var key = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        let context = SFTPVerifiedSessionContext(host: "generated.invalid", port: 22, requestedScopeID: 0,
            account: "generated", key: try SFTPHostKey(key), previous: nil, permitsRememberingHost: false)
        return .init(session: sessionID, selection: selection, context: context)
    }
    func releasePage() { let old = heldPage; heldPage = nil; old?.resume() }
    func releaseDownload() { let old = heldDownload; heldDownload = nil; old?.resume() }
    func releaseClose() { let old = heldClose; heldClose = nil; old?.resume() }
    func close() async -> SFTPWorkerClose {
        closes += 1; ended = true; releasePage(); releaseDownload()
        if holdClose { await withCheckedContinuation { heldClose = $0 } }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
}

final class SFTPDownloadBrowserTests: XCTestCase, @unchecked Sendable {
    private func storage() throws -> SFTPDownloadStorage {
        if let value = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_SOURCE"] {
            return try .init(directory: URL(fileURLWithPath: value).appendingPathComponent("pump-" + UUID().uuidString))
        }
        return try .init(directory: LocalStorageTestFixtures.directory().appendingPathComponent("pump"))
    }
    private func ready(_ transport: DownloadBrowserTransport, exposedDownloads: Bool = true,
                       exposedTextReads: Bool = false) async throws -> (SFTPBrowserSession, SFTPDownloadSelection) {
        let session = SFTPBrowserSession(id: transport.sessionID, transport: transport,
            exposedDownloads: exposedDownloads, exposedFolderDownloads: exposedDownloads,
            exposedTextReads: exposedTextReads)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        return (session, try .init(generation: generation, row: DownloadBrowserTransport.row))
    }
    private func batchPlan(_ session: SFTPBrowserSession) async throws -> SFTPDownloadBatchPlan {
        let page = try await session.page(offset: 0)
        return try .init(generation: page.generation, snapshot: page.snapshot,
            selections: page.rows.map { try SFTPDownloadSelection(generation: page.generation, row: $0) })
    }
    private func eventually(_ check: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await check()) { guard ContinuousClock.now < end else { throw SFTPBrowserFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
    }
    func testSuccessSealsOnlyRequestedBodyAndRetainsForExplicitDiscard() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(), (session, selection) = try await ready(transport)
        let received = try await session.download(selection, storage: storage)
        XCTAssertEqual(received.logicalBytes, 17)
        var stores = try await storage.inspect(); XCTAssertEqual(stores.count, 1); XCTAssertTrue(stores[0].active)
        let next = try await session.page(offset: 0); XCTAssertEqual(next.rows.count, 1)
        await received.retainForReview(); stores = try await storage.inspect(); XCTAssertFalse(stores[0].active)
        try await storage.discardIncomplete(received.id); let empty = try await storage.inspect(); XCTAssertTrue(empty.isEmpty)
        _ = await session.close(); let maximum = await transport.maximum; XCTAssertEqual(maximum, 1)
    }
    func testMetadataOnlyCapabilityRefusesBeforeStagingOrTransportAndKeepsBrowseUsable() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(allowsDownloads: false), (session, selection) = try await ready(transport)
        XCTAssertFalse(session.allowsRequestedDownloads)
        do { _ = try await session.download(selection, storage: storage); XCTFail("Metadata-only connection admitted a body") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.downloads, closes = await transport.closes, files = try await storage.inspect()
        XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 0); XCTAssertTrue(files.isEmpty); XCTAssertNil(session.latest.failure)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 1)
        _ = await session.close()
    }
    func testPrivateTextExposureCannotUpgradeMetadataOnlyTransport() async throws {
        let downloads = try storage(), transport = DownloadBrowserTransport(allowsDownloads: false)
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        XCTAssertFalse(session.allowsTextRead)
        do { _ = try await session.openText(selected: selection, storage: SFTPTextReadStorage(sharing: downloads))
            XCTFail("Private text request upgraded a metadata-only worker") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.downloads, files = try await downloads.inspect()
        XCTAssertEqual(calls, 0); XCTAssertTrue(files.isEmpty)
        _ = await session.close()
    }
    func testHeldDownloadExposureRefusesBodyEvenWhenTransportCanRead() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport()
        let session = SFTPBrowserSession(id: UUID(), transport: transport,
                                         exposedDownloads: false, exposedFolderDownloads: false)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        let selection = try SFTPDownloadSelection(generation: generation, row: DownloadBrowserTransport.row)
        XCTAssertTrue(transport.allowsRequestedDownloads)
        XCTAssertFalse(session.allowsRequestedDownloads)
        XCTAssertFalse(session.allowsRequestedFolderDownloads)
        XCTAssertFalse(session.allowsTextRead)
        do { _ = try await session.download(selection, storage: storage); XCTFail("Held Download read a body") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        do { _ = try await session.openText(selected: selection, storage: SFTPTextReadStorage(sharing: storage))
            XCTFail("Unrequested private text read") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let calls = await transport.downloads, files = try await storage.inspect()
        XCTAssertEqual(calls, 0); XCTAssertTrue(files.isEmpty)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 1)
        _ = await session.close()
    }
    func testPrivateTextReadUsesSharedPoolWhileBinaryDownloadRemainsHeld() async throws {
        let downloads = try storage()
        let text = SFTPTextReadStorage(sharing: downloads)
        let transport = DownloadBrowserTransport()
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        XCTAssertTrue(session.allowsTextRead)
        XCTAssertFalse(session.allowsRequestedDownloads)
        XCTAssertFalse(session.allowsRequestedFolderDownloads)
        do { _ = try await session.download(selection, storage: downloads); XCTFail("Binary Download escaped its gate") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        do { _ = try await session.openText(selected: selection, storage: downloads); XCTFail("Legacy text read escaped binary gate") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
        let callsBefore = await transport.downloads
        XCTAssertEqual(callsBefore, 0)
        let lease = try await session.openText(selected: selection, storage: text)
        let value = try await lease.read()
        XCTAssertEqual(value.text, String(repeating: "*", count: 17))
        let held = try await downloads.inspect()
        XCTAssertEqual(held.count, 1)
        let close = await lease.closeForViewer()
        XCTAssertEqual(close, .removed)
        let after = try await downloads.inspect(), callsAfter = await transport.downloads
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(callsAfter, 1)
        _ = await session.close()
    }
    #if DEBUG
    func testPrivateTextCloseSchedulesWhileReadProbeHoldsBodyLane() async throws {
        let downloads = try storage(), text = SFTPTextReadStorage(sharing: downloads)
        let transport = DownloadBrowserTransport()
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        let lease = try await session.openText(selected: selection, storage: text)
        let entered = DownloadReturnFlag(), release = DispatchSemaphore(value: 0)
        lease.readProbe = {
            entered.finish()
            guard release.wait(timeout: .now() + 5) == .success else { throw SFTPTextFailure.stopped }
        }
        let reading = Task.detached { try await lease.read() }
        defer { release.signal() }
        try await eventually { entered.ended }
        let closing = Task.detached { await lease.closeForViewer() }
        try await eventually { lease.closeRequestedForTesting }
        release.signal()
        do { _ = try await reading.value; XCTFail("Held read completed after close was scheduled") }
        catch { XCTAssertEqual(error as? SFTPTextFailure, .stopped) }
        let outcome = await closing.value
        XCTAssertEqual(outcome, .removed)
        let remaining = try await downloads.inspect()
        XCTAssertTrue(remaining.isEmpty)
        _ = await session.close()
    }
    #endif
    func testPrivateTextCloseReportsRetainedBodyWhenOwnedCleanupRefuses() async throws {
        let downloads = try storage()
        let text = SFTPTextReadStorage(sharing: downloads)
        let transport = DownloadBrowserTransport()
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        let lease = try await session.openText(selected: selection, storage: text)
        _ = try await lease.read()
        let records = try await downloads.inspect()
        guard records.count == 1 else { return XCTFail("Expected one generated private body") }
        let id = records[0].id
        // Only this disposable test fixture gets unexpected content. Checked
        // cleanup must keep it and return an inspectable ID instead of claiming removal.
        let unexpected = downloads.store.directory.appendingPathComponent("download-" + id.uuidString)
            .appendingPathComponent("generated-unexpected.txt")
        try Data("generated fixture".utf8).write(to: unexpected, options: .withoutOverwriting)
        let close = await lease.closeForViewer()
        XCTAssertEqual(close, .retainedForReview(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
        let repeated = await lease.closeForViewer()
        XCTAssertEqual(repeated, .retainedForReview(id))
        _ = await session.close()
    }
    func testPrivateTextReadRejectsStaleAndOversizeBeforeBodyOrStorage() async throws {
        let downloads = try storage()
        let text = SFTPTextReadStorage(sharing: downloads)
        let transport = DownloadBrowserTransport()
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        do { _ = try await session.openText(selected: try .init(generation: UUID(), row: selection.row), storage: text)
            XCTFail("Stale private text read") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let huge = SFTPStoredRow(observation: selection.row.observation,
            entry: .init(name: selection.row.entry.name, logicalBytes: (1 << 20) + 1,
                modifiedSeconds: 1, permissions: 0o100644))
        do { _ = try await session.openText(selected: try .init(generation: selection.generation, row: huge), storage: text)
            XCTFail("Oversize private text read") }
        catch { XCTAssertEqual(error as? SFTPTextFailure, .unsupported) }
        let calls = await transport.downloads, files = try await downloads.inspect()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(files.isEmpty)
        _ = await session.close()
    }
    func testPrivateTextReadQueuedCancellationNeverRequestsBody() async throws {
        let downloads = try storage()
        let text = SFTPTextReadStorage(sharing: downloads)
        let transport = DownloadBrowserTransport(holdPage: true)
        let (session, selection) = try await ready(transport, exposedDownloads: false, exposedTextReads: true)
        let page = Task { try await session.page(offset: 0) }
        try await eventually { await transport.pages == 1 }
        let opening = Task { try await session.openText(selected: selection, storage: text) }
        try await eventually { await session.downloadState.queued }
        opening.cancel()
        do { _ = try await opening.value; XCTFail("Cancelled text read returned a lease") } catch {}
        await transport.releasePage(); _ = try await page.value
        let calls = await transport.downloads, files = try await downloads.inspect()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testQueuedCancelNeverReadsOrCreatesBodyAndKeepsConnection() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(holdPage: true), (session, selection) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let download = Task { try await session.download(selection, storage: storage) }; try await eventually { await session.downloadState.queued }
        download.cancel(); do { _ = try await download.value; XCTFail("Cancelled queued download returned") } catch {}
        await transport.releasePage(); _ = try await page.value
        let calls = await transport.downloads, closes = await transport.closes, files = try await storage.inspect()
        XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 0); XCTAssertTrue(files.isEmpty); XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testActiveStopDrainsTransportAndWriterBeforeReturning() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(holdDownload: true, holdClose: true), (session, selection) = try await ready(transport)
        let returned = DownloadReturnFlag()
        let download = Task { defer { returned.finish() }; return try await session.download(selection, storage: storage) }; try await eventually { await transport.downloads == 1 }
        download.cancel(); try await eventually {
            let closes = await transport.closes, active = await session.downloadState.active
            return closes == 1 && !active
        }
        await Task.yield(); XCTAssertFalse(returned.ended, "Cancellation returned before its exact transport close ended")
        await transport.releaseClose(); do { _ = try await download.value; XCTFail("Stopped download returned") } catch {}
        let ended = await session.close(); XCTAssertTrue(ended.localResourcesEnded)
        let stores = try await storage.inspect(), maximum = await transport.maximum, closes = await transport.closes
        XCTAssertEqual(stores.count, 1); XCTAssertFalse(stores[0].active); XCTAssertEqual(maximum, 1); XCTAssertEqual(closes, 1)
        try await storage.discardIncomplete(stores[0].id)
    }
    func testNavigationSupersedesQueuedSelectionWithoutReadingOrPoisoningSession() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(holdPage: true), (session, selection) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let download = Task { try await session.download(selection, storage: storage) }; try await eventually { await session.downloadState.queued }
        let navigation = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await transport.releasePage(); _ = try await page.value; _ = try await navigation.value
        do { _ = try await download.value; XCTFail("Old observation downloaded") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        try await eventually { session.latest.snapshot?.state == .complete }
        let calls = await transport.downloads, files = try await storage.inspect(); XCTAssertEqual(calls, 0); XCTAssertTrue(files.isEmpty); XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testStaleAdmissionIsReadOnlyAndSingleOutstandingDownloadBounded() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(holdDownload: true), (session, selection) = try await ready(transport)
        do { _ = try await session.download(.init(generation: UUID(), row: selection.row), storage: storage); XCTFail("Stale generation") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let download = Task { try await session.download(selection, storage: storage) }; try await eventually { await transport.downloads == 1 }
        do { _ = try await session.download(selection, storage: storage); XCTFail("Second download admitted") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        await transport.releaseDownload(); let result = try await download.value; await result.retainForReview()
        _ = await session.close(); try await storage.discardIncomplete(result.id)
    }
    func testLocalStorageRefusalNeverSendsBodyRequestOrEndsBrowseSession() async throws {
        let safe = try storage(), transport = DownloadBrowserTransport(), (session, selection) = try await ready(transport)
        let link = safe.store.directory; try FileManager.default.createSymbolicLink(at: link, withDestinationURL: link.deletingLastPathComponent())
        do { _ = try await session.download(selection, storage: safe); XCTFail("Redirected storage") }
        catch { XCTAssertEqual(error as? SFTPDownloadStorageIssue, .changed) }
        let calls = await transport.downloads; XCTAssertEqual(calls, 0); XCTAssertNil(session.latest.failure)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 1); _ = await session.close()
    }
    func testBatchReceivesSixteenUnderOneSerialJobBeforePublication() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(listedRows: 16), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session)
        let result = try await session.downloadBatch(plan, storage: storage)
        XCTAssertEqual(result.items.count, 16); XCTAssertEqual(result.logicalBytes, 16 * 17)
        XCTAssertEqual(result.items.map(\.localName), plan.items.map(\.localName))
        let stores = try await storage.inspect()
        XCTAssertEqual(stores.count, 16); XCTAssertTrue(stores.allSatisfy(\.active))
        let calls = await transport.downloads, maximum = await transport.maximum
        XCTAssertEqual(calls, 16); XCTAssertEqual(maximum, 1)
        await result.retainForReview()
        let retained = try await storage.inspect(); XCTAssertEqual(retained.count, 16)
        XCTAssertTrue(retained.allSatisfy { !$0.active })
        for item in retained { try await storage.discardIncomplete(item.id) }
        _ = await session.close()
    }
    func testPublicSelectedGroupPublishesIndependentV14FilesAndColdUndo() async throws {
        let root = try LocalStorageTestFixtures.directory(), pool = root.appendingPathComponent("downloads")
        let target = root.appendingPathComponent("Destination")
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let storage = try SFTPDownloadStorage(directory: pool, publicQuarantinePolicy: .sourceQualification,
            selectedGroupPublicQuarantinePolicy: .sourceQualification)
        let transport = DownloadBrowserTransport(listedRows: 2)
        let (session, _) = try await ready(transport), group = try await batchPlan(session)
        let received = try await session.downloadBatch(group, storage: storage)
        XCTAssertEqual(received.items.count, 2)
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"),
            protecting: [pool], receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let observed = try await engine.checkReceivedFileDestinations(parent: target,
            names: received.items.map(\.localName))
        var published: [(UUID, URL)] = []
        for item in received.items {
            let marker = pool.appendingPathComponent("download-" + item.download.id.uuidString)
                .appendingPathComponent("session.meta")
            XCTAssertEqual(try JSONDecoder().decode(DownloadDisk.Marker.self,
                from: Data(contentsOf: marker)).version, 4)
            let plan = try await item.download.preparePublicQuarantineCandidate(using: engine,
                parent: target, name: item.localName, observing: observed)
            let outcome = await engine.performReceivedFile(plan)
            XCTAssertEqual(outcome.result.disposition, .succeeded)
            let id = try XCTUnwrap(outcome.recordID)
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data(repeating: 42, count: 17))
            XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            published.append((id, plan.destination))
            let retired = await item.download.finishPublication(outcome)
            XCTAssertTrue(retired)
        }
        _ = await session.close()
        let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"),
            protecting: [pool], receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let history = try await cold.inspectExistingHistory()
        XCTAssertEqual(Set(history.records.filter { $0.canUndo }.map(\.id)), Set(published.map { $0.0 }))
        let firstUndo = await cold.undo(recordID: published[0].0)
        XCTAssertEqual(firstUndo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: published[0].1.path))
        XCTAssertTrue(FileManager().fileExists(atPath: published[1].1.path))
        let secondUndo = await cold.undo(recordID: published[1].0)
        XCTAssertEqual(secondUndo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: published[1].1.path))
    }
    func testBatchPlanRejectsDuplicateObservationUnsafeNameAndAggregateExcess() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 2, count: 3, folders: 0, state: .complete)
        let first = try SFTPDownloadSelection(generation: generation, row: DownloadBrowserTransport.batchRow(1))
        let duplicate = try SFTPDownloadSelection(generation: generation, row: DownloadBrowserTransport.batchRow(1))
        XCTAssertThrowsError(try SFTPDownloadBatchPlan(generation: generation, snapshot: snapshot, selections: [first, duplicate])) {
            XCTAssertEqual($0 as? SFTPDownloadBatchIssue, .duplicateSelection)
        }
        let unsafe = try SFTPDownloadSelection(generation: generation,
            row: .init(observation: 2, entry: .init(name: try SFTPRemoteName(Data("A:B.txt".utf8)),
                logicalBytes: 17, modifiedSeconds: 1, permissions: 0o100644)))
        XCTAssertThrowsError(try SFTPDownloadBatchPlan(generation: generation, snapshot: snapshot, selections: [first, unsafe])) {
            XCTAssertEqual($0 as? SFTPDownloadBatchIssue, .invalidSelection)
        }
        let large = try SFTPDownloadSelection(generation: generation,
            row: .init(observation: 3, entry: .init(name: try SFTPRemoteName(Data("Large.bin".utf8)),
                logicalBytes: 1 << 30, modifiedSeconds: 1, permissions: 0o100644)))
        XCTAssertThrowsError(try SFTPDownloadBatchPlan(generation: generation, snapshot: snapshot, selections: [first, large])) {
            XCTAssertEqual($0 as? SFTPDownloadBatchIssue, .tooLarge)
        }
    }
    func testBatchRejectsChangedCompleteSnapshotBeforeStorageOrBody() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(listedRows: 2), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session), observed = plan.snapshot
        let changed = SFTPStoredSnapshot(read: observed.read, revision: observed.revision + 1,
            count: observed.count, folders: observed.folders, state: .complete)
        let stale = try SFTPDownloadBatchPlan(generation: plan.generation, snapshot: changed, selections: plan.items.map(\.selection))
        do { _ = try await session.downloadBatch(stale, storage: storage); XCTFail("Changed catalog admitted") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let calls = await transport.downloads, files = try await storage.inspect()
        XCTAssertEqual(calls, 0); XCTAssertTrue(files.isEmpty); XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testBatchCapacityPreflightSendsZeroBodiesAndCreatesNoGroupSpools() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(listedRows: 16), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session)
        let other = try await storage.store.reserve(.init(generation: plan.generation, row: plan.items[0].selection.row))
        let another = try await storage.store.reserve(.init(generation: plan.generation, row: plan.items[1].selection.row))
        do { _ = try await session.downloadBatch(plan, storage: storage); XCTFail("Batch exceeded active admission") }
        catch let interruption as SFTPDownloadBatchInterruption {
            XCTAssertEqual(interruption.completedFiles, 0); XCTAssertFalse(interruption.currentMayHaveStarted)
            XCTAssertTrue(interruption.retainedFileIDs.isEmpty)
            XCTAssertEqual(interruption.cause as? SFTPDownloadStorageIssue, .full)
        }
        let calls = await transport.downloads
        XCTAssertEqual(calls, 0); XCTAssertNil(session.latest.failure)
        let stores = try await storage.inspect()
        XCTAssertEqual(stores.count, 2); XCTAssertEqual(stores.filter(\.active).count, 2)
        _ = await other.abandon(); _ = await another.abandon()
        for item in try await storage.inspect() { try await storage.discardIncomplete(item.id) }
        _ = await session.close()
    }
    #if DEBUG
    func testBatchPostMkdirFailureRemovesOnlyOwnIncompleteHeaderAndKeepsPoolUsable() async throws {
        let fault = BatchHeaderFault()
        let directory = try LocalStorageTestFixtures.directory().appendingPathComponent("downloads")
        let storage = try SFTPDownloadStorage(directory: directory,
            hooks: .init(failBatchAfterMetadataSync: { try fault.afterSync($0) }))
        let transport = DownloadBrowserTransport(listedRows: 3), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session)
        do { _ = try await session.downloadBatch(plan, storage: storage); XCTFail("Injected header fault returned") }
        catch let interruption as SFTPDownloadBatchInterruption {
            XCTAssertEqual(interruption.completedFiles, 0)
            XCTAssertFalse(interruption.currentMayHaveStarted)
            XCTAssertEqual(interruption.cause as? SFTPDownloadStorageIssue, .unavailable)
            let retained = try await storage.inspect()
            XCTAssertEqual(retained.count, 1, "Failed constructor must not leave an uninspectable namespace")
            XCTAssertEqual(interruption.retainedFileIDs, retained.map(\.id))
            XCTAssertTrue(retained.allSatisfy { !$0.active })
        }
        let bodyCalls = await transport.downloads
        XCTAssertEqual(bodyCalls, 0)
        XCTAssertNil(session.latest.failure)
        let page = try await session.page(offset: 0)
        XCTAssertEqual(page.rows.count, 3)
        let next = try await session.downloadBatch(plan, storage: storage)
        XCTAssertEqual(next.items.count, 3)
        await next.retainForReview()
        for item in try await storage.inspect() { try await storage.discardIncomplete(item.id) }
        let empty = try await storage.inspect()
        XCTAssertTrue(empty.isEmpty)
        _ = await session.close()
    }
    func testBatchPostMkdirUnexpectedContentIsPreservedAndItsIDReported() async throws {
        let directory = try LocalStorageTestFixtures.directory().appendingPathComponent("downloads")
        let fault = BatchUnexpectedHeaderFault(directory: directory)
        let storage = try SFTPDownloadStorage(directory: directory,
            hooks: .init(failBatchAfterMetadataSync: { try fault.afterSync($0) }))
        let transport = DownloadBrowserTransport(listedRows: 3), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session)
        do { _ = try await session.downloadBatch(plan, storage: storage); XCTFail("Injected unexpected header returned") }
        catch let interruption as SFTPDownloadBatchInterruption {
            XCTAssertEqual(interruption.completedFiles, 0)
            XCTAssertFalse(interruption.currentMayHaveStarted)
            XCTAssertEqual(interruption.retainedFileIDs.count, 2)
            XCTAssertEqual(interruption.retainedFileIDs.last, fault.retainedID)
        }
        let bodyCalls = await transport.downloads
        XCTAssertEqual(bodyCalls, 0)
        guard let id = fault.retainedID else { return XCTFail("Missing failed allocation ID") }
        let unfinished = directory.appendingPathComponent("download-" + id.uuidString)
        let unexpected = unfinished.appendingPathComponent("unexpected.txt")
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("preserve generated unexpected content".utf8))
        do { _ = try await storage.inspect(); XCTFail("Uncertain namespace was silently accepted") } catch {}
        // This test owns the generated fixture and removes only its injected
        // unfinished directory after proving that production left it intact.
        try FileManager().removeItem(at: unfinished)
        let earlier = try await storage.inspect()
        XCTAssertEqual(earlier.count, 1)
        XCTAssertFalse(earlier[0].active)
        try await storage.discardIncomplete(earlier[0].id)
        XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    #endif
    func testBatchSecondNetworkFailureRetainsAllWithoutPublishableSubset() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(listedRows: 3, failAtDownload: 2), (session, _) = try await ready(transport)
        let plan = try await batchPlan(session)
        do { _ = try await session.downloadBatch(plan, storage: storage); XCTFail("Failed body returned") }
        catch let interruption as SFTPDownloadBatchInterruption {
            XCTAssertEqual(interruption.completedFiles, 1); XCTAssertEqual(interruption.totalFiles, 3)
            XCTAssertEqual(interruption.completedBytes, 17); XCTAssertTrue(interruption.currentMayHaveStarted)
            XCTAssertEqual(interruption.retainedFileIDs.count, 3)
        }
        let files = try await storage.inspect()
        XCTAssertEqual(files.count, 3); XCTAssertTrue(files.allSatisfy { !$0.active })
        let calls = await transport.downloads
        XCTAssertEqual(calls, 2); XCTAssertNotNil(session.latest.failure)
        for item in files { try await storage.discardIncomplete(item.id) }
        _ = await session.close()
    }
    func testBatchStopDrainsAllReservedOwnersBeforeReturning() async throws {
        let storage = try storage(), transport = DownloadBrowserTransport(holdDownload: true, holdClose: true, listedRows: 3)
        let (session, _) = try await ready(transport)
        let plan = try await batchPlan(session), returned = DownloadReturnFlag()
        let batch = Task { defer { returned.finish() }; return try await session.downloadBatch(plan, storage: storage) }
        try await eventually { await transport.downloads == 1 }
        do { _ = try await session.page(offset: 0); XCTFail("Page entered batch") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        do { _ = try await session.navigate(pathUTF8: Data("/Next".utf8)); XCTFail("Navigation entered batch") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .busy) }
        batch.cancel()
        try await eventually { await transport.closes == 1 }
        await Task.yield(); XCTAssertFalse(returned.ended)
        await transport.releaseClose()
        do { _ = try await batch.value; XCTFail("Stopped batch returned") } catch {}
        let stores = try await storage.inspect()
        XCTAssertEqual(stores.count, 3); XCTAssertTrue(stores.allSatisfy { !$0.active })
        let calls = await transport.downloads
        XCTAssertEqual(calls, 1)
        for item in stores { try await storage.discardIncomplete(item.id) }
        _ = await session.close()
    }
}
