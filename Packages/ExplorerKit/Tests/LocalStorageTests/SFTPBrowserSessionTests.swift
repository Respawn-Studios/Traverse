import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private actor BrowseTransport: SFTPDirectoryTransport {
    private let holdAt: Int, failAt: Int, failure: SFTPSessionFailure
    private var active = 0, maximum = 0, reads = 0, queries = 0, opens = 0, closes = 0
    private var hold: CheckedContinuation<Void, Never>?, ended = false
    private let failIdle: Bool, holdIdle: Bool, uncertainClose: Bool
    private let rejectedPath: String?
    private var idleChecks = 0, idleHold: CheckedContinuation<Void, Never>?
    private var remoteActionCalls = 0
    private var observedActionDirectoryCalls = 0
    nonisolated let allowsRemoteActions: Bool
    nonisolated let allowsServerCopy: Bool
    nonisolated let allowsFolderSizeSummary: Bool
    private var sizeRequests = 0, sizeHold: CheckedContinuation<Void, Never>?
    var sizeCount: Int { sizeRequests }
    var actionCount: Int { remoteActionCalls }
    var observedDirectoryCount: Int { observedActionDirectoryCalls }
    func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory {
        observedActionDirectoryCalls += 1
        guard intent.generation == generation, intent.snapshot == snapshot else { throw SFTPBrowserFailure.stale }
        return try .observedCanonicalServerPath("/generated/\u{202e}Child")
    }
    func performRemoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult {
        remoteActionCalls += 1
        throw SFTPBrowserFailure.unavailable
    }
    private var generation = UUID(), snapshot = SFTPStoredSnapshot(read: 0, revision: 0, count: 0, folders: 0, state: .loading)
    init(holdAt: Int = 1, failAt: Int = 0, failure: SFTPSessionFailure = .remote, failIdle: Bool = false, holdIdle: Bool = false, uncertainClose: Bool = false, rejectedPath: String? = nil, remoteActions: Bool = false, serverCopy: Bool = false, folderSizes: Bool = false) {
        self.holdAt = holdAt; self.failAt = failAt; self.failure = failure; self.failIdle = failIdle; self.holdIdle = holdIdle; self.uncertainClose = uncertainClose
        self.rejectedPath = rejectedPath; self.allowsRemoteActions = remoteActions; self.allowsServerCopy = serverCopy
        self.allowsFolderSizeSummary = folderSizes
    }
    var idleCount: Int { idleChecks }
    func checkIdle() async throws {
        begin(); defer { active -= 1 }; idleChecks += 1
        if holdIdle { await withCheckedContinuation { idleHold = $0 } }
        guard !ended else { throw SFTPSessionFailure.stopped }
        if failIdle { throw failure }
    }
    var facts: (active: Int, maximum: Int, reads: Int, pages: Int, opens: Int, closes: Int) { (active, maximum, reads, queries, opens, closes) }
    private func begin() { active += 1; maximum = max(maximum, active) }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        begin(); defer { active -= 1 }; guard !ended else { throw SFTPSessionFailure.stopped }; opens += 1
        if path == rejectedPath { throw SFTPDirectoryRejection.denied }
        generation = UUID()
        snapshot = .init(read: UInt64(opens), revision: 0, count: 0, folders: 0, state: .loading); return (generation, snapshot)
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot {
        begin(); defer { active -= 1 }; reads += 1
        if reads == holdAt { await withCheckedContinuation { hold = $0 } }
        guard !ended else { throw SFTPSessionFailure.stopped }
        if reads == failAt { throw failure }
        guard generation == self.generation else { throw SFTPBrowserFailure.stale }
        snapshot = .init(read: snapshot.read, revision: snapshot.revision + 1, count: 2, folders: allowsFolderSizeSummary ? 1 : 0, state: snapshot.count == 0 ? .loading : .complete)
        return snapshot
    }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
        begin(); defer { active -= 1 }; queries += 1
        guard !ended, generation == self.generation, snapshot == self.snapshot else { throw SFTPSessionFailure.output }
        let rows: [SFTPStoredRow] = (0..<2).map { index in
            let permissions: UInt32 = allowsFolderSizeSummary && index == 0 ? 0o040755 : 0o100644
            let entry = SFTPWorkerEntry(name: try! SFTPRemoteName(Data("Generated \(index)".utf8)),
                logicalBytes: UInt64(index), modifiedSeconds: nil, permissions: permissions)
            return .init(observation: UInt64(index + 1), entry: entry)
        }
        return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: offset, rows: rows)
    }
    func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        begin(); defer { active -= 1 }; sizeRequests += 1
        guard selection.generation == generation, selection.snapshot == snapshot else { throw RemoteFolderSizeFailure.stale }
        if sizeRequests == 1 { throw RemoteFolderSizeFailure.denied }
        await withCheckedContinuation { sizeHold = $0 }
        return try .init(logicalBytes: 8 << 30, files: 1, folders: 0, excludedLinks: 0)
    }
    func releaseSize() { let held = sizeHold; sizeHold = nil; held?.resume() }
    func release() { let pending = hold; hold = nil; pending?.resume() }
    func close() async -> SFTPWorkerClose {
        closes += 1; ended = true; release(); releaseIdle(); releaseSize()
        if uncertainClose && closes == 1 { return .init(actualExit: false, exitStatus: nil, ipcEOF: false, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: false) }
        return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
    func releaseIdle() { let pending = idleHold; idleHold = nil; pending?.resume() }
}

final class SFTPBrowserSessionTests: XCTestCase, @unchecked Sendable {
    func testObservedActionDirectoryPreservesCanonicalBytesAndRejectsStaleProbe() async throws {
        let transport = BrowseTransport(holdAt: 0, remoteActions: true, serverCopy: true)
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        let snapshot = try XCTUnwrap(session.latest.snapshot)
        let row = try SFTPStoredRow(observation: 1, entry: .init(name: .init(Data("file.txt".utf8)),
            logicalBytes: 1, modifiedSeconds: 2, permissions: 0o100644))
        let probe = try SFTPRemoteActionIntent.copyFile(generation: generation, snapshot: snapshot,
            row: row, destinationDirectory: .init(root: .server), newName: .init(Data("copy.txt".utf8)))
        let observed = try await session.observedActionDirectory(for: probe)
        XCTAssertEqual(observed.root, .server)
        XCTAssertEqual(observed.pathUTF8, Data("/generated/\u{202e}Child".utf8))
        XCTAssertThrowsError(try SFTPDefaultDirectory.observedCanonicalServerPath("relative/file.txt"))
        XCTAssertThrowsError(try SFTPDefaultDirectory.observedCanonicalServerPath("/generated/../file.txt"))
        XCTAssertThrowsError(try SFTPDefaultDirectory.observedCanonicalServerPath("/generated//file.txt"))
        let observedCount = await transport.observedDirectoryCount
        let actionCount = await transport.actionCount
        XCTAssertEqual(observedCount, 1)
        XCTAssertEqual(actionCount, 0)
        _ = try await session.navigate(pathUTF8: Data("/next".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        do { _ = try await session.observedActionDirectory(for: probe); XCTFail("Stale probe accepted") }
        catch { XCTAssertEqual(error as? SFTPBrowserFailure, .stale) }
        let countAfterStale = await transport.observedDirectoryCount
        XCTAssertEqual(countAfterStale, 1)
        _ = await session.close()
    }
    func testFolderSizeDenialAndCallerCancellationDrainWithoutDisconnectingNavigation() async throws {
        let transport = BrowseTransport(holdAt: 0, folderSizes: true)
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        let page = try await session.page(offset: 0)
        let selection = try SFTPFolderSizeSelection(generation: generation, snapshot: page.snapshot, row: XCTUnwrap(page.rows.first))
        do { _ = try await session.summarizeSelectedFolder(selection); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteFolderSizeFailure, .denied) }
        XCTAssertNil(session.latest.failure)
        let measurement = Task { try await session.summarizeSelectedFolder(selection) }
        try await eventually { await transport.sizeCount == 2 }
        measurement.cancel()
        let navigation = Task { try await session.navigate(pathUTF8: Data("/next".utf8)) }
        await transport.releaseSize()
        do { _ = try await measurement.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let next = try await navigation.value
        try await eventually { session.latest.generation == next && session.latest.snapshot?.state == .complete }
        XCTAssertNil(session.latest.failure)
        let facts = await transport.facts; XCTAssertEqual(facts.closes, 0); XCTAssertEqual(facts.maximum, 1)
        let drain = await session.close(); XCTAssertTrue(drain.localResourcesEnded)
    }
    func testFindRefusalDoesNotStopTheSessionOrHideItsObservedSnapshot() async throws {
        let transport = BrowseTransport(holdAt: 0), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        let original = session.latest.snapshot
        do { _ = try await session.find(.init(text: "Generated")); XCTFail("This transport has no catalog Find") }
        catch { XCTAssertEqual(error as? RemoteDirectoryFindFailure, .unavailable) }
        XCTAssertNil(session.latest.failure); XCTAssertEqual(session.latest.snapshot, original)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 2)
        let facts = await transport.facts; XCTAssertEqual(facts.closes, 0); XCTAssertEqual(facts.maximum, 1)
        _ = await session.close()
    }
    func testCancelledQueuedRemoteActionNeverReachesTransportOrStore() async throws {
        let transport = BrowseTransport(holdAt: 0, holdIdle: true, remoteActions: true)
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually {
            let idleCount = await transport.idleCount
            return session.latest.snapshot?.state == .complete && idleCount == 1
        }
        let snapshot = try XCTUnwrap(session.latest.snapshot)
        let intent = try SFTPRemoteActionIntent.newFolder(generation: generation, snapshot: snapshot,
                                                          name: .init(Data("Generated Folder".utf8)))
        let root = try LocalStorageTestFixtures.directory()
        let store = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let action = Task { try await session.performRemoteAction(intent, store: store) }
        try await Task.sleep(for: .milliseconds(10))
        action.cancel()
        await failure(.stopped) { _ = try await action.value }
        let actionCount = await transport.actionCount
        let history = try await store.inspect()
        XCTAssertEqual(actionCount, 0)
        XCTAssertTrue(history.records.isEmpty)
        await transport.releaseIdle()
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
        let storeClosed = await store.close()
        XCTAssertTrue(storeClosed)
    }
    func testAccountHomeAndServerRootStayDistinctThroughChildrenParentsAndEviction() throws {
        var references = SFTPDirectoryReferences(connectionID: UUID(), home: false, title: "Generated server")
        let part = try SFTPRemoteName(Data("Café".utf8))
        let absolute = try references.location(for: [part])
        let relative = try references.location(for: [part], relativeToHome: true)
        XCTAssertNotEqual(absolute, relative)
        XCTAssertEqual(references.pathUTF8(for: absolute), Data("/Café".utf8))
        XCTAssertEqual(references.pathUTF8(for: relative), Data("./Café".utf8))
        XCTAssertEqual(references.baseRoot(for: absolute), references.serverRoot)
        XCTAssertEqual(references.baseRoot(for: relative), references.homeRoot)
        XCTAssertEqual(try references.parent(of: absolute), references.serverRoot)
        XCTAssertEqual(try references.parent(of: relative), references.homeRoot)
        XCTAssertNil(references.pathUTF8(for: .init(connectionID: UUID(), directoryID: relative.directoryID, displayHint: "Foreign")))
        for index in 0..<1100 { _ = try references.location(for: [SFTPRemoteName(Data("Item \(index)".utf8))]) }
        XCTAssertNil(references.resolve(relative)); XCTAssertNil(references.resolve(absolute))
        XCTAssertEqual(references.pathUTF8(for: references.homeRoot), Data(".".utf8))
        XCTAssertEqual(references.pathUTF8(for: references.serverRoot), Data("/".utf8))
        references.close(); XCTAssertNil(references.pathUTF8(for: references.homeRoot)); XCTAssertNil(references.pathUTF8(for: references.serverRoot))
    }
    func testRefusedNavigationRevokesOldPageAuthorityAndRecoversWithoutReconnect() async throws {
        let transport = BrowseTransport(holdAt: 0, rejectedPath: "/root")
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        let first = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.snapshot?.state == .complete }
        _ = try await session.page(offset: 0)
        do { _ = try await session.navigate(pathUTF8: Data("/root".utf8)); XCTFail("Denied folder was accepted") }
        catch { XCTAssertEqual(error as? SFTPDirectoryRejection, .denied) }
        XCTAssertNil(session.latest.generation); XCTAssertNil(session.latest.snapshot); XCTAssertNil(session.latest.failure)
        XCTAssertEqual(session.latest.directoryRejection, .denied)
        await failure(.unavailable) { _ = try await session.page(offset: 0) }
        let next = try await session.navigate(pathUTF8: Data("/".utf8)); XCTAssertNotEqual(first, next)
        try await eventually { session.latest.snapshot?.state == .complete }
        XCTAssertNil(session.latest.directoryRejection)
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
        let facts = await transport.facts; XCTAssertEqual(facts.opens, 3); XCTAssertEqual(facts.closes, 1); XCTAssertEqual(facts.maximum, 1)
    }
    func testDeniedInitialDirectoryCanNavigateToHomeWithoutNewConnection() async throws {
        let transport = BrowseTransport(holdAt: 0, rejectedPath: "/root")
        let session = SFTPBrowserSession(id: UUID(), transport: transport)
        do { _ = try await session.navigate(pathUTF8: Data("/root".utf8)); XCTFail("Denied folder was accepted") }
        catch { XCTAssertEqual(error as? SFTPDirectoryRejection, .denied) }
        do {
            _ = try await session.navigate(pathUTF8: Data(".".utf8))
            try await eventually { session.latest.snapshot?.state == .complete }
            XCTAssertEqual(session.latest.snapshot?.count, 2)
        } catch { XCTFail("A refused folder poisoned the authenticated session: \(type(of: error))") }
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
        let facts = await transport.facts
        XCTAssertEqual(facts.opens, 2); XCTAssertEqual(facts.closes, 1); XCTAssertEqual(facts.maximum, 1)
    }
    func testUncertainCloseCanRetryActualTransportInsteadOfCachingFailureForever() async {
        let transport = BrowseTransport(holdAt: 0, uncertainClose: true), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let first = await session.close(); XCTAssertFalse(first.localResourcesEnded)
        let second = await session.close(); XCTAssertTrue(second.localResourcesEnded)
        let facts = await transport.facts; XCTAssertEqual(facts.closes, 2)
    }
    func testPageWakesIdleWaitWithoutWaitingForTimerAndCloseDrainsIt() async throws {
        let transport = BrowseTransport(holdAt: 0), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { session.latest.snapshot?.state == .complete }
        try await Task.sleep(for: .milliseconds(10))
        let began = ContinuousClock.now
        _ = try await session.page(offset: 0)
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(200))
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1); XCTAssertEqual(facts.closes, 1); XCTAssertEqual(facts.active, 0)
    }
    func testHeldIdleProbeSerializesPagesAndCloseDrainsEveryWaiter() async throws {
        let transport = BrowseTransport(holdAt: 0, holdIdle: true), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { await transport.idleCount == 1 }
        let page = Task { try await session.page(offset: 0) }
        try await Task.sleep(for: .milliseconds(10))
        let before = await transport.facts; XCTAssertEqual(before.pages, 0); XCTAssertEqual(before.active, 1)
        _ = await session.close()
        do { _ = try await page.value; XCTFail("Closed idle probe published a page") } catch {}
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1); XCTAssertEqual(facts.active, 0); XCTAssertEqual(facts.closes, 1)
    }
    func testIdleLossPublishesFailureAndPreservesObservedPrefixWithoutAnotherClick() async throws {
        let transport = BrowseTransport(holdAt: 0, failIdle: true), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { session.latest.failure == .remote }
        XCTAssertEqual(session.latest.snapshot?.count, 2); XCTAssertEqual(session.latest.snapshot?.state, .complete)
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1)
        _ = await session.close()
    }
    private func eventually(_ body: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await body()) { guard ContinuousClock.now < deadline else { XCTFail("Bounded generated wait expired"); throw SFTPBrowserFailure.unavailable }; try await Task.sleep(for: .milliseconds(1)) }
    }
    private func failure(_ expected: SFTPBrowserFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected guarded browser refusal") } catch { XCTAssertEqual(error as? SFTPBrowserFailure, expected) }
    }
    func testSerialPrefixPausePagesAndActualClose() async throws {
        let transport = BrowseTransport(), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let generation = try await session.navigate(pathUTF8: Data(".".utf8))
        try await eventually { await transport.facts.reads == 1 }
        session.stopReading(); try await eventually { session.latest.paused }; XCTAssertTrue(session.latest.reading)
        await transport.release(); try await eventually { session.latest.snapshot?.count == 2 && !session.latest.reading }
        XCTAssertEqual(session.latest.generation, generation); XCTAssertEqual(session.latest.snapshot?.state, .loading)
        let page = try await session.page(offset: 0); XCTAssertEqual(page.rows.count, 2)
        await failure(.invalidInput) { _ = try await session.page(offset: UInt64.max) }
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded); _ = await session.close()
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1); XCTAssertEqual(facts.active, 0); XCTAssertEqual(facts.closes, 1); XCTAssertEqual(facts.pages, 1)
    }
    func testPendingNavigationSupersedesOldPagesWithoutOverlappingNativeWork() async throws {
        let transport = BrowseTransport(holdAt: 2), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let first = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { await transport.facts.reads == 2 }
        let page = Task { try await session.page(offset: 0) }; try await eventually { await session.queueState.pages == 1 }
        let next = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await transport.release(); let second = try await next.value
        XCTAssertNotEqual(first, second); await failure(.stale) { _ = try await page.value }
        try await eventually { session.latest.generation == second && session.latest.snapshot?.state == .complete }
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1); XCTAssertEqual(facts.pages, 0); XCTAssertEqual(facts.opens, 2)
        _ = await session.close()
    }
    func testQueuedCancellationDrainsItsRequestWithoutDisconnectingOrQuerying() async throws {
        let transport = BrowseTransport(holdAt: 2), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { await transport.facts.reads == 2 }
        let page = Task { try await session.page(offset: 0) }; try await eventually { await session.queueState.pages == 1 }
        page.cancel(); try await eventually { await session.queueState.pages == 0 }; await failure(.stopped) { _ = try await page.value }
        await transport.release(); try await eventually { session.latest.snapshot?.state == .complete }
        XCTAssertNil(session.latest.failure); let rows = try await session.page(offset: 0); XCTAssertEqual(rows.rows.count, 2)
        let facts = await transport.facts; XCTAssertEqual(facts.maximum, 1); XCTAssertEqual(facts.pages, 1); XCTAssertEqual(facts.closes, 0)
        _ = await session.close()
    }
    func testPageAndNavigationAdmissionAreBoundedAndCloseFinishesEveryWaiter() async throws {
        let transport = BrowseTransport(holdAt: 2), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { await transport.facts.reads == 2 }
        let pages = (0..<4).map { _ in Task { try await session.page(offset: 0) } }; try await eventually { await session.queueState.pages == 4 }
        await failure(.busy) { _ = try await session.page(offset: 0) }
        let nav = Task { try await session.navigate(pathUTF8: Data("/Next".utf8)) }; try await eventually { await session.queueState.navigation }
        await failure(.busy) { _ = try await session.navigate(pathUTF8: Data("/Other".utf8)) }
        let closed = await session.close(); XCTAssertTrue(closed.localResourcesEnded)
        for page in pages { await failure(.stopped) { _ = try await page.value } }; await failure(.stopped) { _ = try await nav.value }
        let facts = await transport.facts; XCTAssertEqual(facts.active, 0); XCTAssertEqual(facts.closes, 1); XCTAssertEqual(facts.pages, 0)
    }
    func testFailureRetainsObservedPrefixAndNeverReconnectsAutomatically() async throws {
        let transport = BrowseTransport(holdAt: 0, failAt: 2), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { session.latest.failure == .remote }
        XCTAssertEqual(session.latest.snapshot?.count, 2)
        await failure(.stopped) { _ = try await session.navigate(pathUTF8: Data("/Retry".utf8)) }
        let facts = await transport.facts; XCTAssertEqual(facts.opens, 1); XCTAssertEqual(facts.maximum, 1); _ = await session.close()
    }
    func testStorageFailureRetainsItsCauseAndObservedPrefix() async throws {
        let transport = BrowseTransport(holdAt: 0, failAt: 2, failure: .storage), session = SFTPBrowserSession(id: UUID(), transport: transport)
        _ = try await session.navigate(pathUTF8: Data(".".utf8)); try await eventually { session.latest.failure != nil }
        XCTAssertEqual(session.latest.failure?.rawValue, "storage"); XCTAssertEqual(session.latest.snapshot?.count, 2)
        _ = await session.close()
    }
    func testVerifiedAccountMatchingUsesExactUTF8RatherThanCanonicalStringEquality() throws {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes); try SFTPWire.field(Data(repeating: 1, count: 32), into: &bytes)
        let context = SFTPVerifiedSessionContext(host: "generated.invalid", port: 22, requestedScopeID: 0, account: "Café",
            key: try SFTPHostKey(bytes), previous: nil, permitsRememberingHost: false)
        XCTAssertTrue(context.matches(try .init(address: .init("generated.invalid"), account: "Café")))
        XCTAssertFalse(context.matches(try .init(address: .init("generated.invalid"), account: "Cafe\u{301}")))
    }
    func testInvalidPathsRefuseBeforeTransportAndTerminalReasonsStayDistinct() async throws {
        let transport = BrowseTransport(), session = SFTPBrowserSession(id: UUID(), transport: transport)
        for path in ["", "../private", "/a/../b", "/a//b", "./a/.", "relative", "/a\0b"] {
            await failure(.invalidInput) { _ = try await session.navigate(pathUTF8: Data(path.utf8)) }
        }
        let facts = await transport.facts; XCTAssertEqual(facts.opens, 0); _ = await session.close()
        XCTAssertEqual(SFTPSessionFailure.terminal(5), .authentication); XCTAssertEqual(SFTPSessionFailure.terminal(6), .security)
        XCTAssertEqual(SFTPSessionFailure.terminal(8), .denied); XCTAssertEqual(SFTPSessionFailure.terminal(9), .storage)
    }
    func testPageCacheRetainsTwoPagesAndRejectsStaleContradictoryObservations() throws {
        let id = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 3, count: 1024, folders: 0, state: .complete)
        func page(_ offset: UInt64) throws -> SFTPStoredPage {
            .init(request: UUID(), generation: id, snapshot: snapshot, offset: offset, rows: try (0..<256).map { index in
                .init(observation: offset + UInt64(index), entry: .init(name: try .init(Data("Row \(offset + UInt64(index))".utf8)), logicalBytes: nil, modifiedSeconds: nil, permissions: nil))
            })
        }
        var cache = SFTPDirectoryPageCache(); XCTAssertTrue(cache.observe(id, snapshot: snapshot))
        try cache.accept(page(0), sort: .name, descending: false); try cache.accept(page(256), sort: .name, descending: false)
        try cache.accept(page(512), sort: .name, descending: false); XCTAssertEqual(cache.retainedCount, 512); XCTAssertNil(cache.entry(at: 0))
        let conflicting = SFTPStoredPage(request: UUID(), generation: id, snapshot: snapshot, offset: 512, rows: [
            .init(observation: 512, entry: .init(name: try .init(Data("Changed observation".utf8)), logicalBytes: nil, modifiedSeconds: nil, permissions: nil))])
        XCTAssertThrowsError(try cache.accept(conflicting, sort: .name, descending: false)); XCTAssertEqual(cache.retainedCount, 512)
        let older = SFTPStoredSnapshot(read: 1, revision: 2, count: 1024, folders: 0, state: .loading)
        XCTAssertFalse(cache.observe(id, snapshot: older)); XCTAssertEqual(cache.retainedCount, 512)
        let other = UUID(); cache.observe(other, snapshot: snapshot); XCTAssertThrowsError(try cache.accept(page(0), sort: .name, descending: false))
        cache.clear(); XCTAssertNil(cache.snapshot)
    }
    func testRemoteReferencesAreExactBoundedAndNeverPersistAccessOrLocalURLs() throws {
        let connection = UUID(); var home = SFTPDirectoryReferences(connectionID: connection, home: true, title: "Generated Home")
        let nfc = try SFTPRemoteName(Data("Café".utf8)), nfd = try SFTPRemoteName(Data("Cafe\u{301}".utf8))
        let first = try home.location(for: [nfc]), second = try home.location(for: [nfd]); XCTAssertNotEqual(first, second)
        XCTAssertEqual(home.pathUTF8(for: first), Data("./Café".utf8)); XCTAssertEqual(try home.parent(of: first), home.root)
        let local = BrowserLocation.sftp(first); XCTAssertNil(local.directoryURL); XCTAssertNil(local.parent); XCTAssertTrue(local.isRemote)
        let tab = BrowserTab(location: local); XCTAssertThrowsError(try WorkspaceSession.captureLaunchTemplate([tab], activeID: tab.id))
        for index in 0..<1100 { _ = try home.location(for: [SFTPRemoteName(Data("Name \(index)".utf8))]) }
        XCTAssertNil(home.resolve(first)); XCTAssertNotNil(home.resolve(home.root)); home.close(); XCTAssertNil(home.pathUTF8(for: home.root))
        var root = SFTPDirectoryReferences(connectionID: UUID(), home: false, title: "Generated Root")
        let value = try root.location(for: [SFTPRemoteName(Data("a\\b".utf8))]); XCTAssertEqual(root.pathUTF8(for: value), Data("/a\\b".utf8))
    }
}
