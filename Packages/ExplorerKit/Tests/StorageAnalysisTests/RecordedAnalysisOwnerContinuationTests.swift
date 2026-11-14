import Dispatch
import ExplorerCore
import Foundation
import Testing
@_spi(ApplicationOwnership) @testable import StorageAnalysis

#if DEBUG
// These tests use the generated native fixture and the public owner/query
// operations. The hooks pause real access, query and publication boundaries;
// no mock result or substitute storage backend is installed. A missing
// qualified helper leaves these controls NOT EXERCISED.
private let ownerHelperAvailable = ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil

private actor OwnerPause {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func park() async {
        entered = true
        let waiters = enteredWaiters; enteredWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            if entered { continuation.resume() }
            else { enteredWaiters.append(continuation) }
        }
    }
    func release() {
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

private actor OwnerAccess: RecordedAnalysisAccessProvider {
    let root: URL
    private var pauseNext: OwnerPause?
    private var denyOnce = false
    init(root: URL) { self.root = root }
    func pauseNextAdmission(at pause: OwnerPause) { pauseNext = pause }
    func denyNextAdmission() { denyOnce = true }
    func acquireSingle(recordedRoot: URL) async throws -> RecordedSingleRootAccess {
        let pause = pauseNext; pauseNext = nil
        if let pause { await pause.park() }
        guard !denyOnce else { denyOnce = false; throw StorageScanFailure.accessDenied }
        return .init(root: root, retainingAccess: UUID())
    }
    func acquireStartup() async throws -> RecordedStartupRootAccess {
        throw StorageScanFailure.unsupportedLocation
    }
}

private struct OwnerNoConsumers: RecordedAnalysisConsumerDrain, RecordedAnalysisViewConsumerDrain {
    func revokeAndJoin(catalogID: UUID) async throws {}
    func revokeAllAndJoin() async throws {}
    func revokeAndJoin(consumerID: UUID) async throws {}
}

private actor OwnerFailOnceDrain: RecordedAnalysisConsumerDrain {
    private var fail = true
    func revokeAndJoin(catalogID: UUID) async throws {
        if fail { fail = false; throw StorageScanFailure.busy }
    }
    func revokeAllAndJoin() async throws {}
}

private final class OwnerQueryPause: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}
private func ownerWaitSignal(_ signal: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: signal.wait(timeout: .now() + 5) == .success)
        }
    }
}

private final class OwnerProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RecordedAnalysisProgress] = []
    func append(_ update: RecordedAnalysisProgress) { lock.withLock { updates.append(update) } }
    var snapshot: [RecordedAnalysisProgress] { lock.withLock { updates } }
}

private actor OwnerTokenBox {
    private var token: FileActivityGate.DrainToken?
    private var waiter: CheckedContinuation<FileActivityGate.DrainToken, Never>?
    func store(_ value: FileActivityGate.DrainToken) {
        token = value; waiter?.resume(returning: value); waiter = nil
    }
    func get() async -> FileActivityGate.DrainToken {
        await withCheckedContinuation { continuation in
            if let token { continuation.resume(returning: token) }
            else { waiter = continuation }
        }
    }
}

private struct OwnerHarness {
    let fixture: RetainedFixture
    let source: URL
    let gate: FileActivityGate
    let access: OwnerAccess
    let owner: RecordedAnalysisOwner
    init(maximumActivities: Int = 4_096) throws {
        guard let path = ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"],
              path.hasPrefix("/"), !path.contains("..") else { throw StorageScanFailure.unavailable }
        let helper = URL(fileURLWithPath: path)
        let fixture = try RetainedFixture()
        let source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("one.txt"), Data("generated owner\n".utf8))
        let gate = FileActivityGate(maximumActivities: maximumActivities)
        let access = OwnerAccess(root: source)
        let scanner = StorageScanner(workerURL: helper, activityGate: gate)
        let owner = try RecordedAnalysisOwner(scanner: scanner, storage: fixture.storage(),
            workerURL: helper, activityGate: gate, accessProvider: access)
        self.fixture = fixture; self.source = source; self.gate = gate
        self.access = access; self.owner = owner
    }
    func scan(progress: OwnerProgressBox? = nil) async throws -> RecordedAnalysisPresentation {
        let outcome = await owner.scanSingle(root: source, retainingAccess: UUID(),
            onProgress: { update in progress?.append(update) })
        guard case .ready(let value) = outcome else { throw StorageScanFailure.changed }
        return value
    }
}

@Suite struct RecordedAnalysisOwnerContinuationTests {
    @Test(.enabled(if: ownerHelperAvailable))
    func admittedScanUsesTheOrdinaryProgressStreamAndTransfersExactResult() async throws {
        let h = try OwnerHarness()
        let launches = ScannerWorkerProcess.qualificationTraversalLaunchCount
        guard case .started(let admission) = await h.owner.beginRecordedSingleScan(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        var terminal: PagedStorageScanUpdate?
        for await update in admission.session.updates where update.workerDrained { terminal = update }
        let update = try #require(terminal), raw = try #require(update.result)
        #expect(ScannerWorkerProcess.qualificationTraversalLaunchCount == launches + 1)
        guard case .accepted(.ready(let ready)) = await h.owner.adoptDrainedResult(
            admission: admission, terminal: update) else { throw StorageScanFailure.changed }
        #expect(ready.metadata.catalogID == admission.session.id)
        #expect((await h.owner.resultForQualification(ready.metadata.catalogID)) === raw)
        #expect(ready.metadata.coverage.scanCoverage == update.coverage)
        guard case .ownerRetainsResult = await h.owner.abandonRecordedScan(admission: admission) else {
            throw StorageScanFailure.changed
        }
        _ = try await ready.queries.summary()
        guard case .complete = await h.owner.closeCatalog(ready.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func staleTerminalCannotPublishAnotherAdmittedScan() async throws {
        let h = try OwnerHarness()
        guard case .started(let first) = await h.owner.beginRecordedSingleScan(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        var firstTerminal: PagedStorageScanUpdate?
        for await update in first.session.updates where update.workerDrained { firstTerminal = update }
        let old = try #require(firstTerminal)
        guard case .accepted(.ready(let ready)) = await h.owner.adoptDrainedResult(
            admission: first, terminal: old) else { throw StorageScanFailure.changed }

        guard case .started(let second) = await h.owner.beginRecordedSingleScan(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        var secondTerminal: PagedStorageScanUpdate?
        for await update in second.session.updates where update.workerDrained { secondTerminal = update }
        let fresh = try #require(secondTerminal), unadopted = try #require(fresh.result)
        guard case .notAdopted(.changed) = await h.owner.adoptDrainedResult(
            admission: second, terminal: old) else { throw StorageScanFailure.changed }
        guard case .abandoned = await h.owner.abandonRecordedScan(admission: second) else {
            throw StorageScanFailure.changed
        }
        await unadopted.closeAfterRevokingApplicationConsumersAndDrain()
        guard case .ready(let inventory) = await h.owner.inspectRecorded() else {
            throw StorageScanFailure.changed
        }
        #expect(inventory.map(\.catalogID) == [ready.metadata.catalogID])
        guard case .complete = await h.owner.closeCatalog(ready.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func concurrentAbandonBeforePublicationKeepsRawResultAppOwned() async throws {
        let h = try OwnerHarness()
        guard case .started(let admission) = await h.owner.beginRecordedSingleScan(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        var terminal: PagedStorageScanUpdate?
        for await update in admission.session.updates where update.workerDrained { terminal = update }
        let update = try #require(terminal), raw = try #require(update.result)
        let before = OwnerPause(), requested = OwnerPause()
        await h.owner.installBeforeAdmittedPublicationForQualification { await before.park() }
        await h.owner.installAfterAdmittedAbandonRequestForQualification { await requested.park() }
        let adopting = Task { await h.owner.adoptDrainedResult(admission: admission, terminal: update) }
        await before.waitUntilEntered()
        let abandoning = Task { await h.owner.abandonRecordedScan(admission: admission) }
        await requested.waitUntilEntered()
        await before.release(); await requested.release()
        guard case .notAdopted(.cancelled) = await adopting.value,
              case .abandoned = await abandoning.value else { throw StorageScanFailure.changed }
        await raw.closeAfterRevokingApplicationConsumersAndDrain()
        guard case .ready(let records) = await h.owner.inspectRecorded() else { throw StorageScanFailure.changed }
        #expect(records.isEmpty)
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func concurrentAbandonDuringPublicationReportsOwnerRetainedResult() async throws {
        let h = try OwnerHarness()
        guard case .started(let admission) = await h.owner.beginRecordedSingleScan(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        var terminal: PagedStorageScanUpdate?
        for await update in admission.session.updates where update.workerDrained { terminal = update }
        let update = try #require(terminal), raw = try #require(update.result)
        let during = OwnerPause(), requested = OwnerPause()
        await h.owner.installAfterPreservationForQualification { await during.park() }
        await h.owner.installAfterAdmittedAbandonRequestForQualification { await requested.park() }
        let adopting = Task { await h.owner.adoptDrainedResult(admission: admission, terminal: update) }
        await during.waitUntilEntered()
        let abandoning = Task { await h.owner.abandonRecordedScan(admission: admission) }
        await requested.waitUntilEntered()
        await during.release(); await requested.release()
        guard case .accepted(let outcome) = await adopting.value,
              case .ownerRetainsResult = await abandoning.value else { throw StorageScanFailure.changed }
        guard case .ready(let ready) = outcome else { throw StorageScanFailure.changed }
        #expect((await h.owner.resultForQualification(ready.metadata.catalogID)) === raw)
        guard case .complete = await h.owner.closeCatalog(ready.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func oneActivityGateCoversWarmOpenCachedValidationAndColdOpen() async throws {
        let h = try OwnerHarness(maximumActivities: 1)
        // scan() publishes and then opens the warm result through the backend.
        let warm = try await h.scan()
        #expect(h.gate.activeCount == 0)
        let maybeRaw = await h.owner.resultForQualification(warm.metadata.catalogID)
        let raw = try #require(maybeRaw)
        do {
            let lease = try h.gate.begin()
            let catalog = try await raw.retainedCatalogFingerprint(admittedBy: lease)
            #expect(catalog.catalogID == warm.metadata.catalogID)
            withExtendedLifetime(lease) {}
        }
        #expect(h.gate.activeCount == 0)
        let foreign = FileActivityGate(maximumActivities: 1)
        do {
            let wrongLease = try foreign.begin()
            await #expect(throws: FileActivityError.foreignLease) {
                try await raw.retainedCatalogFingerprint(admittedBy: wrongLease)
            }
        }
        guard case .ready(let cached) = await h.owner.openRecorded(warm.metadata.catalogID) else {
            throw StorageScanFailure.changed
        }
        #expect(cached.queries.viewID != warm.queries.viewID)
        guard case .complete = await h.owner.closeCatalog(warm.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        guard case .ready(let cold) = await h.owner.openRecorded(warm.metadata.catalogID) else {
            throw StorageScanFailure.changed
        }
        _ = try await cold.queries.summary()
        #expect(h.gate.activeCount == 0)
        guard case .complete = await h.owner.closeCatalog(warm.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func twoConsumerViewsHaveDistinctAuthorityAndOneReleaseDoesNotCloseTheOther() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        guard case .ready(let second) = await h.owner.openRecorded(first.metadata.catalogID) else {
            throw StorageScanFailure.changed
        }
        let firstRead: any AnalysisStoredReadView = first.queries
        let secondRead: any AnalysisStoredReadView = second.queries
        #expect(firstRead.catalogID == secondRead.catalogID)
        #expect(firstRead.viewID != secondRead.viewID)
        _ = try await secondRead.summary()
        guard case .complete = await h.owner.releaseConsumer(catalogID: first.metadata.catalogID,
            consumerID: first.consumerID, consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        await #expect(throws: StorageScanFailure.changed) { try await firstRead.summary() }
        _ = try await secondRead.summary()
        guard case .unavailable(.busy) = await h.owner.closeIdleCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        _ = try await secondRead.summary()
        guard case .complete = await h.owner.releaseConsumer(catalogID: second.metadata.catalogID,
            consumerID: second.consumerID, consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        guard case .complete = await h.owner.closeIdleCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        await #expect(throws: StorageScanFailure.changed) { try await secondRead.summary() }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func lateNativeQueryOutcomeIsSuppressedAfterConsumerRevocation() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        let maybeRaw = await h.owner.resultForQualification(first.metadata.catalogID)
        let raw = try #require(maybeRaw)
        let pause = OwnerQueryPause()
        try raw.installQueryReleaseHookForQualification {
            pause.entered.signal()
            _ = pause.release.wait(timeout: .now() + 5)
        }
        defer { pause.release.signal(); try? raw.installQueryReleaseHookForQualification(nil) }
        let query = Task { try await first.queries.summary() }
        guard await ownerWaitSignal(pause.entered) else { throw StorageScanFailure.changed }
        let owner = h.owner, catalogID = first.metadata.catalogID, consumerID = first.consumerID
        let release = Task { await owner.releaseConsumer(catalogID: catalogID,
            consumerID: consumerID, consumers: OwnerNoConsumers()) }
        await first.queries.waitForRevocationStartForQualification()
        pause.release.signal()
        guard case .complete = await release.value else { throw StorageScanFailure.changed }
        switch await query.result {
        case .success: throw StorageScanFailure.changed
        case .failure(let error): #expect(error as? StorageScanFailure == .changed)
        }
        guard case .complete = await h.owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func releasePausedAfterJoinPreservesNewConsumerAdmission() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        let pause = OwnerPause()
        await h.owner.installAfterConsumerRevokeForQualification { await pause.park() }
        let owner = h.owner, catalogID = first.metadata.catalogID, consumerID = first.consumerID
        let release = Task { await owner.releaseConsumer(catalogID: catalogID,
            consumerID: consumerID, consumers: OwnerNoConsumers()) }
        await pause.waitUntilEntered()
        guard case .ready(let second) = await h.owner.openRecorded(first.metadata.catalogID) else {
            await pause.release(); throw StorageScanFailure.changed
        }
        await pause.release()
        guard case .complete = await release.value else { throw StorageScanFailure.changed }
        await h.owner.installAfterConsumerRevokeForQualification(nil)
        let snapshot = await h.owner.ownershipSnapshot()
        #expect(snapshot.queryViews == 1 && snapshot.ownedCatalogs == 1)
        _ = try await second.queries.summary()
        guard case .complete = await h.owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func releasePausedVsQuitCannotResurrectOwnerAndReceiptCanResumeOnlyOnce() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        let pause = OwnerPause()
        await h.owner.installAfterConsumerRevokeForQualification { await pause.park() }
        let owner = h.owner, catalogID = first.metadata.catalogID, consumerID = first.consumerID
        let release = Task { await owner.releaseConsumer(catalogID: catalogID,
            consumerID: consumerID, consumers: OwnerNoConsumers()) }
        await pause.waitUntilEntered()
        let quitting = Task { await owner.quitRetaining(consumers: OwnerNoConsumers()) }
        for _ in 0..<1_000 {
            if (await h.owner.ownershipSnapshot()).admissionsFenced { break }
            await Task.yield()
        }
        #expect((await h.owner.ownershipSnapshot()).admissionsFenced)
        await pause.release()
        _ = await release.value
        guard case .retainingQuit(let receipt) = await quitting.value else {
            throw StorageScanFailure.changed
        }
        #expect(receipt.indexKnown && receipt.nativeOwnersClosed &&
                receipt.appConsumersJoined && receipt.ownershipWorkJoined)
        let snapshot = await h.owner.ownershipSnapshot()
        #expect(snapshot.queryViews == 0 && snapshot.ownedCatalogs == 0 &&
                snapshot.activeOperations == 0 && !snapshot.controllerHasWork)
        guard case .complete = await h.owner.resumeAfterAbortedQuit(receipt) else {
            throw StorageScanFailure.changed
        }
        guard case .unavailable(.changed) = await h.owner.resumeAfterAbortedQuit(receipt) else {
            throw StorageScanFailure.changed
        }
        guard case .complete = await h.owner.forgetAll(consumers: OwnerNoConsumers()) else {
            throw StorageScanFailure.changed
        }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func concurrentAndDelayedQuitResumeCannotReuseOrClearANewerReceipt() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        guard case .retainingQuit(let original) = await h.owner.quitRetaining(
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        let pause = OwnerPause(), owner = h.owner
        await owner.installBeforeResumeAdmissionsForQualification { await pause.park() }
        let resuming = Task { await owner.resumeAfterAbortedQuit(original) }
        await pause.waitUntilEntered()
        let waiting = await owner.ownershipSnapshot()
        #expect(waiting.admissionsFenced && waiting.resumeInFlight)
        guard case .unavailable(.busy) = await owner.resumeAfterAbortedQuit(original) else {
            await pause.release(); throw StorageScanFailure.changed
        }
        guard case .unavailable(.busy) = await owner.quitRetaining(
            consumers: OwnerNoConsumers()) else { await pause.release(); throw StorageScanFailure.changed }
        await pause.release()
        guard case .complete = await resuming.value else { throw StorageScanFailure.changed }
        await owner.installBeforeResumeAdmissionsForQualification(nil)
        guard case .retainingQuit(let later) = await owner.quitRetaining(
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        #expect(original.generation != later.generation)
        guard case .unavailable(.changed) = await owner.resumeAfterAbortedQuit(original) else {
            throw StorageScanFailure.changed
        }
        #expect((await owner.ownershipSnapshot()).admissionsFenced)
        guard case .complete = await owner.resumeAfterAbortedQuit(later) else {
            throw StorageScanFailure.changed
        }
        guard case .ready(let reopened) = await owner.openRecorded(first.metadata.catalogID) else {
            throw StorageScanFailure.changed
        }
        _ = try await reopened.queries.summary()
        guard case .complete = await owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func coldOpenPausedOnFreshAccessCannotDeliverAfterQuitFence() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        guard case .complete = await h.owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        let pause = OwnerPause()
        await h.access.pauseNextAdmission(at: pause)
        let owner = h.owner, catalogID = first.metadata.catalogID
        let opening = Task { await owner.openRecorded(catalogID) }
        await pause.waitUntilEntered()
        let quitting = Task { await owner.quitRetaining(consumers: OwnerNoConsumers()) }
        for _ in 0..<1_000 {
            if (await owner.ownershipSnapshot()).admissionsFenced { break }
            await Task.yield()
        }
        #expect((await owner.ownershipSnapshot()).admissionsFenced)
        await pause.release()
        switch await opening.value {
        case .ready(_), .liveTransient(_): throw StorageScanFailure.changed
        case .unavailable(_), .needsAttention(_): break
        }
        guard case .retainingQuit(let receipt) = await quitting.value else {
            throw StorageScanFailure.changed
        }
        #expect(receipt.nativeOwnersClosed && receipt.ownershipWorkJoined)
        #expect((await owner.ownershipSnapshot()).queryViews == 0)
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func busyCloseKeepsViewsAndPendingDrainHasAnOwnedRetry() async throws {
        let h = try OwnerHarness(), first = try await h.scan()
        let pause = OwnerPause()
        await h.access.pauseNextAdmission(at: pause)
        let owner = h.owner, catalogID = first.metadata.catalogID
        let opening = Task { await owner.openRecorded(catalogID) }
        await pause.waitUntilEntered()
        guard case .unavailable(.busy) = await h.owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { await pause.release(); throw StorageScanFailure.changed }
        #expect((await h.owner.ownershipSnapshot()).queryViews == 1)
        await pause.release()
        guard case .ready(let second) = await opening.value else { throw StorageScanFailure.changed }
        _ = try await second.queries.summary()
        guard case .needsAttention(.consumerDrainPending) = await h.owner.closeCatalog(
            first.metadata.catalogID, consumers: OwnerFailOnceDrain()) else {
            throw StorageScanFailure.changed
        }
        let pending = await h.owner.ownershipSnapshot()
        #expect(pending.ownedCatalogs == 1 && pending.queryViews == 2)
        guard case .complete = await h.owner.closeCatalog(first.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        #expect((await h.owner.ownershipSnapshot()).ownedCatalogs == 0)
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func warmIdleCloseAndFreshColdOpenUseTheSameCatalogIdentity() async throws {
        let h = try OwnerHarness()
        await h.access.denyNextAdmission()
        guard case .unavailable(.accessDenied) = await h.owner.scanSingle(root: h.source,
            retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        guard case .ready(let records) = await h.owner.inspectRecorded(),
              let metadata = records.first else { throw StorageScanFailure.changed }
        guard case .complete = await h.owner.closeCatalog(metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        guard case .ready(let cold) = await h.owner.openRecorded(metadata.catalogID) else {
            throw StorageScanFailure.changed
        }
        #expect(cold.metadata.catalogID == metadata.catalogID)
        _ = try await cold.queries.summary()
        guard case .complete = await h.owner.closeCatalog(metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func provenNotCommittedPublicationReturnsLiveTransientWithActualTerminalProgress() async throws {
        let h = try OwnerHarness(), store = RetainedNativeIndexStore(directory: h.fixture.indexDirectory)
        let progress = OwnerProgressBox()
        await h.owner.installBeforePublicationIntentForQualification {
            guard let before = try? await store.load(),
                  let advanced = try? before.beginningForgetAll(expectedEpoch: before.epoch) else { return }
            _ = await store.commit(advanced, expectedEpoch: before.epoch)
        }
        let outcome = await h.owner.scanSingle(root: h.source, retainingAccess: UUID(),
            onProgress: { progress.append($0) })
        guard case .liveTransient(let transient) = outcome else { throw StorageScanFailure.changed }
        #expect(transient.terminal.workerDrained)
        #expect(!transient.terminal.isStartupPair)
        #expect(transient.terminal.committedEntries > 0)
        #expect(progress.snapshot.last(where: { $0.workerDrained })?.committedEntries ==
                transient.terminal.committedEntries)
        _ = try await transient.queries.summary()
        guard case .complete = await h.owner.closeCatalog(transient.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
        await #expect(throws: StorageScanFailure.changed) { try await transient.queries.summary() }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func pendingPinRequiresRetryBeforeCommittedCatalogDelivery() async throws {
        let h = try OwnerHarness(), gate = h.gate, tokens = OwnerTokenBox()
        await h.owner.installAfterPreservationForQualification {
            if let token = gate.closeAdmission() { await tokens.store(token) }
        }
        guard case .needsAttention(.retentionPending) = await h.owner.scanSingle(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        #expect((await h.owner.ownershipSnapshot()).unresolvedPublications == 1)
        let token = await tokens.get()
        #expect(await gate.waitUntilDrained(token))
        #expect(gate.reopen(token))
        guard case .ready(let ready) = await h.owner.retryPendingPublicationPin() else {
            throw StorageScanFailure.changed
        }
        #expect((await h.owner.ownershipSnapshot()).unresolvedPublications == 0)
        _ = try await ready.queries.summary()
        guard case .complete = await h.owner.closeCatalog(ready.metadata.catalogID,
            consumers: OwnerNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ownerHelperAvailable))
    func uncertainPublicationCannotDeliverOrClaimQuiescentQuit() async throws {
        let h = try OwnerHarness()
        await h.owner.setIndexFaultForQualification(.afterStageCreate)
        guard case .needsAttention(.indexRequiresAttention) = await h.owner.scanSingle(
            root: h.source, retainingAccess: UUID()) else { throw StorageScanFailure.changed }
        #expect((await h.owner.ownershipSnapshot()).unresolvedPublications == 1)
        guard case .needsAttention = await h.owner.retryPendingPublicationPin() else {
            throw StorageScanFailure.changed
        }
        guard case .needsAttention = await h.owner.quitRetaining(consumers: OwnerNoConsumers()) else {
            throw StorageScanFailure.changed
        }
    }
}
#endif
