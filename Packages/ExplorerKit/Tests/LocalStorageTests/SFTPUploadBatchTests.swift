import Darwin
import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private enum BatchSources {
    private static func literalURL(parent: String, name: String) -> URL {
        // fileURLWithPath/appendingPathComponent use macOS filesystem spelling.
        // These pure remote-name controls intentionally retain the input bytes;
        // real APFS aliases are rejected by path/observed-identity checks.
        let encoded = (parent + "/" + name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "%#?")))!
        return URL(string: "file://" + encoded)!
    }
    static func file(_ name: String = "Generated.txt", parent: String = "/generated", inode: UInt64 = 1, bytes: UInt64 = 17) -> SFTPUploadBatchPlan.Root {
        .file(.init(name: name, logicalBytes: bytes, url: literalURL(parent: parent, name: name),
            observation: .init(device: 1, inode: inode, generation: 1, size: Int64(min(bytes, UInt64(Int64.max))),
                modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0, mode: 0o100644, flags: 0)))
    }
    static func folder(_ name: String = "Folder", parent: String = "/generated", inode: UInt64 = 2,
                       files: Int = 2, folders: Int = 0, bytes: UInt64 = 34) -> SFTPUploadBatchPlan.Root {
        .folder(.init(name: name, files: files, folders: folders, logicalBytes: bytes,
            url: URL(fileURLWithPath: parent).appendingPathComponent(name), snapshot: .init(id: UUID(), name: name,
                observation: .init(device: 1, inode: inode, generation: 1, size: 96, modifiedSeconds: 1, modifiedNanoseconds: 0,
                    changedSeconds: 1, changedNanoseconds: 0, mode: 0o40700, flags: 0, links: 1),
                manifestDigest: Data(repeating: 1, count: 32), inventoryDigest: Data(repeating: 2, count: 32),
                files: files, folders: folders, logicalBytes: bytes)))
    }
    static func mixed() throws -> SFTPUploadBatchPlan {
        try .init(reviewed: [file("First.txt"), folder(), file("Last.txt", inode: 3)])
    }
}

private struct BatchFixture {
    let root: URL
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_EXCLUSIVE_UPLOAD_TEST_ROOT"] else {
            root = try LocalStorageTestFixtures.directory()
            return
        }
        let packet = URL(fileURLWithPath: raw)
        guard packet.resolvingSymlinksInPath() == packet, UUID(uuidString: packet.lastPathComponent) != nil,
              packet.deletingLastPathComponent().lastPathComponent == "traverse-development", #filePath.hasPrefix(packet.path + "/source/package/"),
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: packet.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["packet"] as? String == "traverse-development-v1" else { throw RemoteSettingsFailure.unsafe }
        root = packet.appendingPathComponent("source/UploadFixtures/" + UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var storage: SFTPUploadStorage { .init(directory: root.appendingPathComponent("history")) }
}

private actor BatchTransport: SFTPDirectoryTransport {
    nonisolated let allowsFreshUploads: Bool, allowsFreshFolderUploads: Bool
    let holdAt: Int, failAt: Int, openRefusalAt: Int, admissionFailure: Bool, holdPage: Bool, holdClose: Bool
    private var generation = UUID(), ended = false, active = 0
    private var held: CheckedContinuation<Void, Never>?, pageHeld: CheckedContinuation<Void, Never>?, closeHeld: CheckedContinuation<Void, Never>?
    private(set) var events: [String] = [], uploads = 0, opens = 0, pages = 0, closes = 0, maximum = 0
    init(files: Bool = true, folders: Bool = true, holdAt: Int = 0, failAt: Int = 0, openRefusalAt: Int = 0, admission: Bool = false, holdPage: Bool = false, holdClose: Bool = false) {
        allowsFreshUploads = files; allowsFreshFolderUploads = folders; self.holdAt = holdAt; self.failAt = failAt
        self.openRefusalAt = openRefusalAt; admissionFailure = admission; self.holdPage = holdPage; self.holdClose = holdClose
    }
    var snapshot: SFTPStoredSnapshot { .init(read: UInt64(opens), revision: 1, count: 1, folders: 0, state: .complete) }
    private func begin() { active += 1; maximum = max(maximum, active) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        begin(); defer { active -= 1 }; opens += 1; events.append("navigate"); generation = UUID(); return (generation, snapshot)
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { snapshot }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
        begin(); defer { active -= 1 }; pages += 1; events.append("page")
        if holdPage { await withCheckedContinuation { pageHeld = $0 } }
        guard !ended, generation == self.generation else { throw SFTPSessionFailure.stopped }
        return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: offset, rows: [])
    }
    private func send(_ generation: UUID, snapshot: SFTPStoredSnapshot, name: String) async throws {
        begin(); defer { active -= 1 }; uploads += 1; events.append(name)
        if uploads == holdAt { await withCheckedContinuation { held = $0 } }
        guard !ended, generation == self.generation, snapshot == self.snapshot else { throw SFTPSessionFailure.stopped }
        if uploads == failAt {
            if admissionFailure { throw SFTPUploadAdmissionFailure(cause: SFTPUploadSourceFailure.changed) }
            throw SFTPSessionFailure.remote
        }
    }
    func upload(_ request: SFTPRequestedUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPCompletedUpload {
        try await send(request.generation, snapshot: snapshot, name: request.name.displayName)
        if uploads == openRefusalAt {
            throw SFTPUploadOpenRefusal(selection: try .init(request: UUID(), generation: request.generation,
                revision: snapshot.revision, directory: "/generated", name: request.name, logicalBytes: 17))
        }
        progress?(17); return .init(id: UUID(), logicalBytes: 17)
    }
    func uploadFolder(_ request: SFTPRequestedFolderUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                      excluding roots: [URL], progress: (@Sendable (UInt64, Int) -> Void)?) async throws -> SFTPCompletedFolderUpload {
        try await send(request.generation, snapshot: snapshot, name: request.name.displayName)
        progress?(34, 2); return .init(id: UUID(), files: 2, folders: 0, logicalBytes: 34)
    }
    func release() { let value = held; held = nil; value?.resume() }
    func releasePage() { let value = pageHeld; pageHeld = nil; value?.resume() }
    func releaseClose() { let value = closeHeld; closeHeld = nil; value?.resume() }
    func close() async -> SFTPWorkerClose {
        closes += 1; ended = true; release(); releasePage()
        if holdClose { await withCheckedContinuation { closeHeld = $0 } }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
}

final class SFTPUploadBatchTests: XCTestCase, @unchecked Sendable {
    private func issue(_ expected: SFTPUploadBatchIssue, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? SFTPUploadBatchIssue, expected) }
    }
    private func eventually(_ body: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await body()) { guard ContinuousClock.now < end else { throw SFTPBrowserFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
    }
    private func ready(_ transport: BatchTransport) async throws -> (SFTPBrowserSession, UUID) {
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        return (session, try await session.navigate(pathUTF8: Data(".".utf8)))
    }
    func testMixedSummaryAndExactWireNamesDoNotNormalizeUnicode() throws {
        let plan = try SFTPUploadBatchPlan(reviewed: [BatchSources.file("Café"), BatchSources.file("Cafe\u{301}", inode: 2), BatchSources.folder(inode: 3)])
        XCTAssertEqual(plan.items.count, 3); XCTAssertEqual(plan.files, 4); XCTAssertEqual(plan.folders, 1); XCTAssertEqual(plan.logicalBytes, 68)
        XCTAssertNotEqual(Data(plan.items[0].name.utf8), Data(plan.items[1].name.utf8))
        XCTAssertFalse(plan.debugDescription.contains("Caf"))
    }
    func testDuplicateNamesSourceIdentityAndAncestorOverlapRefuse() {
        issue(.duplicateNames) { _ = try SFTPUploadBatchPlan(reviewed: [BatchSources.file(), BatchSources.file(parent: "/elsewhere", inode: 2)]) }
        issue(.overlappingSources) { _ = try SFTPUploadBatchPlan(reviewed: [BatchSources.file(), BatchSources.file("Alias.txt", inode: 1)]) }
        issue(.overlappingSources) { _ = try SFTPUploadBatchPlan(reviewed: [BatchSources.folder(), BatchSources.file(parent: "/generated/Folder", inode: 3)]) }
        issue(.overlappingSources) { _ = try SFTPUploadBatchPlan(reviewed: [BatchSources.file(), BatchSources.file()]) }
    }
    func testComponentPrefixIsNotAncestorAndNamesStayLiteral() throws {
        let plan = try SFTPUploadBatchPlan(reviewed: [BatchSources.folder("Folder"), BatchSources.file("100% # ?.txt", parent: "/generated/Folder2", inode: 3)])
        XCTAssertEqual(plan.items[1].name, "100% # ?.txt")
    }
    func testAggregateBoundariesAndOverflowRefuseWithoutTrapping() throws {
        let edge = try SFTPUploadBatchPlan(reviewed: [BatchSources.folder(files: 1024, folders: 1023, bytes: 1 << 30)])
        XCTAssertEqual(edge.files + edge.folders, 2048); XCTAssertEqual(edge.logicalBytes, 1 << 30)
        for root in [BatchSources.folder(files: 1025), BatchSources.folder(files: 1024, folders: 1024), BatchSources.folder(files: Int.max),
                     BatchSources.folder(folders: Int.max), BatchSources.file(bytes: UInt64.max)] {
            issue(.tooLarge) { _ = try SFTPUploadBatchPlan(reviewed: [root]) }
        }
        issue(.tooLarge) { _ = try SFTPUploadBatchPlan(reviewed: [BatchSources.file(bytes: 1 << 30), BatchSources.file("More", inode: 2, bytes: 1)]) }
    }
    func testInputAndHistoryLimitsAreDifferentAndNeverPrune() throws {
        let roots = (0..<128).map { BatchSources.file("File \($0)", inode: UInt64($0 + 1), bytes: 0) }
        XCTAssertEqual(try SFTPUploadBatchPlan(reviewed: roots).items.count, 128)
        issue(.invalidSelection) { _ = try SFTPUploadBatchPlan(reviewed: roots + [BatchSources.file("Extra", inode: 999)]) }
        issue(.invalidSelection) { _ = try SFTPUploadBatchPlan(reviewed: []) }
        try SFTPUploadBatchPlan.requireHistoryHeadroom(roots: 64, retained: 0)
        try SFTPUploadBatchPlan.requireHistoryHeadroom(roots: 1, retained: 63)
        issue(.historyFull) { try SFTPUploadBatchPlan.requireHistoryHeadroom(roots: 2, retained: 63) }
        issue(.historyFull) { try SFTPUploadBatchPlan.requireHistoryHeadroom(roots: 65, retained: 0) }
    }
    func testMalformedURLsRefuseBeforeSourceInspection() {
        for url in [URL(string: "sftp://generated.invalid/file")!, URL(string: "file:///generated/file?query")!, URL(fileURLWithPath: "/generated/../file"), URL(fileURLWithPath: "/")] {
            issue(.invalidSelection) { try SFTPUploadBatchPlan.validateURLs([url]) }
        }
    }
    func testMetadataReviewMixedSourcesAndUnsupportedTreeLeaveHistoryAbsent() async throws {
        let fixture = try BatchFixture(), file = fixture.root.appendingPathComponent("First.txt"), folder = fixture.root.appendingPathComponent("Folder")
        try Data("Generated".utf8).write(to: file, options: .withoutOverwriting)
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("Member".utf8).write(to: folder.appendingPathComponent("Member.txt"), options: .withoutOverwriting)
        let plan = try await SFTPUploadBatchPlan.inspect([file, folder], excluding: [], allowsFolders: true)
        XCTAssertEqual(plan.files, 2); XCTAssertEqual(plan.folders, 1); XCTAssertEqual(plan.logicalBytes, 15)
        try await plan.checkHistory(fixture.storage)
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("history").path))
        try FileManager().createSymbolicLink(at: folder.appendingPathComponent("Link"), withDestinationURL: file)
        do { _ = try await SFTPUploadBatchPlan.inspect([file, folder], excluding: [], allowsFolders: true); XCTFail("Unsupported tree admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("Generated".utf8))
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("history").path))
    }
    func testMixedGroupDefersNavigationAndPagesUntilAllRootsFinish() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(holdAt: 1), (session, generation) = try await ready(transport)
        let upload = Task { try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []) }
        try await eventually { await transport.uploads == 1 }
        let page = Task { try await session.page(offset: 0) }; try await eventually { await session.queueState.pages == 1 }
        let navigate = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await transport.release(); let result = try await upload.value; XCTAssertEqual(result.completed.map(\.index), [0, 1, 2])
        _ = try await navigate.value
        do { _ = try await page.value; XCTFail("Old page survived navigation") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let events = await transport.events, maximum = await transport.maximum
        XCTAssertEqual(events, ["navigate", "First.txt", "Folder", "Last.txt", "navigate"]); XCTAssertEqual(maximum, 1)
        _ = await session.close()
    }
    func testFirstFailedRootPreservesVerifiedPrefixAndNeverSendsTail() async throws {
        for admission in [true, false] {
            let fixture = try BatchFixture(), transport = BatchTransport(failAt: 2, admission: admission), (session, generation) = try await ready(transport)
            do { _ = try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []); XCTFail("Failed root ignored") }
            catch let error as SFTPUploadBatchInterruption {
                XCTAssertEqual(error.completed.map(\.index), [0]); XCTAssertEqual(error.currentMayHaveStarted, !admission); XCTAssertEqual(error.notSubmitted, admission ? 2 : 1)
                if admission { XCTAssertEqual(error.cause as? SFTPUploadLocalIssue, .sourceChanged) }
            }
            let uploads = await transport.uploads; XCTAssertEqual(uploads, 2)
            XCTAssertEqual(session.latest.failure == nil, admission)
            if admission { _ = try await session.page(offset: 0) }
            _ = await session.close()
        }
    }
    func testFirstOpenPermissionRefusalKeepsBatchAndNextRequestAvailable() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(openRefusalAt: 1)
        let (session, generation) = try await ready(transport)
        do { _ = try await session.uploadBatch(BatchSources.mixed(), generation: generation,
            storage: fixture.storage, excluding: []); XCTFail("Expected first-open refusal") }
        catch let error as SFTPUploadBatchInterruption {
            XCTAssertTrue(error.cause is SFTPUploadOpenRefusal)
            XCTAssertFalse(error.currentMayHaveStarted)
            XCTAssertEqual(error.notSubmitted, 3)
        }
        XCTAssertNil(session.latest.failure)
        _ = try await session.page(offset: 0)
        let next = try SFTPUploadBatchPlan(reviewed: [BatchSources.file("Next.txt", inode: 4)])
        let result = try await session.uploadBatch(next, generation: generation, storage: fixture.storage, excluding: [])
        XCTAssertEqual(result.completed.count, 1)
        let calls = await transport.uploads; XCTAssertEqual(calls, 2)
        _ = await session.close()
    }
    func testStaleQueuedGroupSendsNothingAndPreservesConnection() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(holdPage: true), (session, generation) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let batch = Task { try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []) }; try await eventually { await session.uploadState.queued }
        let navigation = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await transport.releasePage(); _ = try await page.value; _ = try await navigation.value
        do { _ = try await batch.value; XCTFail("Stale batch sent") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let uploads = await transport.uploads; XCTAssertEqual(uploads, 0); XCTAssertNil(session.latest.failure)
        _ = await session.close()
    }
    func testQueuedGroupCancellationSendsNothingWithoutClosing() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(holdPage: true), (session, generation) = try await ready(transport)
        let page = Task { try await session.page(offset: 0) }; try await eventually { await transport.pages == 1 }
        let batch = Task { try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []) }; try await eventually { await session.uploadState.queued }
        batch.cancel(); do { _ = try await batch.value; XCTFail("Cancelled group") } catch {}
        let uploads = await transport.uploads, closes = await transport.closes; XCTAssertEqual(uploads, 0); XCTAssertEqual(closes, 0)
        await transport.releasePage(); _ = try await page.value; _ = await session.close()
    }
    func testActiveGroupCancellationWaitsForDrainAndKeepsPrefix() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(holdAt: 2, holdClose: true), (session, generation) = try await ready(transport)
        let done = BatchDone(), batch = Task { defer { done.finish() }; return try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []) }
        try await eventually { await transport.uploads == 2 }; batch.cancel(); try await eventually { await transport.closes == 1 }
        XCTAssertFalse(done.finished); await transport.releaseClose()
        do { _ = try await batch.value; XCTFail("Cancelled group") }
        catch let error as SFTPUploadBatchInterruption { XCTAssertEqual(error.completed.count, 1); XCTAssertTrue(error.currentMayHaveStarted); XCTAssertEqual(error.notSubmitted, 1) }
        let close = await session.close(), calls = await transport.uploads; XCTAssertTrue(close.localResourcesEnded); XCTAssertEqual(calls, 2)
    }
    func testStopOnVerifiedBoundaryCannotStartAnotherRootAndStillDrains() async throws {
        let fixture = try BatchFixture(), transport = BatchTransport(holdAt: 1, holdClose: true), (session, generation) = try await ready(transport)
        let slot = BatchTaskSlot(), done = BatchDone()
        let task = Task {
            defer { done.finish() }
            return try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: [], progress: {
                if $0.completedRoots == 1 { slot.cancel() }
            })
        }
        slot.set(task); try await eventually { await transport.uploads == 1 }; await transport.release()
        try await eventually { await transport.closes == 1 }; XCTAssertFalse(done.finished)
        let calls = await transport.uploads; XCTAssertEqual(calls, 1)
        await transport.releaseClose()
        do { _ = try await task.value; XCTFail("Boundary Stop ignored") }
        catch let value as SFTPUploadBatchInterruption {
            XCTAssertEqual(value.completed.count, 1); XCTAssertFalse(value.currentMayHaveStarted); XCTAssertEqual(value.notSubmitted, 2)
        }
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
    }
    func testReadOnlyAndFileOnlyRefuseMixedGroupBeforeAnyUpload() async throws {
        for files in [false, true] {
            let fixture = try BatchFixture(), transport = BatchTransport(files: files, folders: false), (session, generation) = try await ready(transport)
            do { _ = try await session.uploadBatch(BatchSources.mixed(), generation: generation, storage: fixture.storage, excluding: []); XCTFail("Unqualified folder upload") }
            catch { XCTAssertEqual(error as? SFTPBrowserFailure, .unavailable) }
            let calls = await transport.uploads; XCTAssertEqual(calls, 0); _ = await session.close()
        }
    }
    func testContradictoryWorkerCapabilitiesRefuseBeforeAnyChildAdmission() async throws {
        let fixture = try BatchFixture(), gate = FileActivityGate()
        let storage = try SMBTemporaryStorage(directory: fixture.root.appendingPathComponent("catalogs")), pool = SMBTemporaryCatalogPool(storage: storage)
        for upload in [false, true] {
            var peer = SFTPPeerConfiguration(host: "generated.invalid", port: 2222, numericHost: "127.0.0.1", scopeID: 0, bundle: Bundle.main.bundleURL)
            peer.allowsRequestedFolderDownloads = true; peer.allowsFreshUploads = upload; peer.allowsFreshFolderUploads = upload
            do { _ = try await SFTPWorkerSession.begin(peer: peer, account: "generated", activity: gate, pool: pool); XCTFail("Contradictory capability set launched") }
            catch { XCTAssertEqual(error as? SFTPSessionFailure, .input) }
            let retained = try await pool.inspect(); XCTAssertTrue(retained.isEmpty); XCTAssertEqual(gate.activeCount, 0)
        }
    }
    func testColdHistoryRequiresWriterCloseAfterTheSourceAttemptDrains() async throws {
        let fixture = try BatchFixture(), url = fixture.root.appendingPathComponent("Generated.txt")
        try Data("Generated source".utf8).write(to: url, options: .withoutOverwriting)
        let source = try await SFTPUploadSourceReview.inspect(url, excluding: []), generation = UUID(), storage = fixture.storage
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        let context = SFTPVerifiedSessionContext(host: "generated.invalid", port: 22, requestedScopeID: 0, account: "generated", key: try .init(key), previous: nil, permitsRememberingHost: false)
        let attempt = try await SFTPUploadAttempt.prepare(.init(generation: generation, reviewed: source, name: source.name),
            destination: .init(session: UUID(), generation: generation, revision: 1, directory: "/generated", context: context), storage: storage, excluding: [])
        await attempt.discardUnsent()
        let warm = try await storage.inspect(); XCTAssertEqual(warm.records.count, 1); XCTAssertFalse(warm.records[0].active)
        let cold = SFTPUploadStorage(directory: fixture.root.appendingPathComponent("history"))
        do { _ = try await cold.inspect(); XCTFail("Second writer acquired the live history") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .busy) }
        let closed = await storage.close(); XCTAssertTrue(closed)
        let reopened = try await cold.inspect(); XCTAssertEqual(reopened.records.map(\.id), warm.records.map(\.id)); XCTAssertFalse(reopened.records[0].active)
        _ = await cold.close()
    }
}
private final class BatchDone: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func finish() { lock.withLock { value = true } }
    var finished: Bool { lock.withLock { value } }
}
private final class BatchTaskSlot: @unchecked Sendable {
    private let lock = NSLock(); private var value: Task<SFTPUploadBatchResult, Error>?
    func set(_ task: Task<SFTPUploadBatchResult, Error>) { lock.withLock { value = task } }
    func cancel() { lock.withLock { value }?.cancel() }
}
