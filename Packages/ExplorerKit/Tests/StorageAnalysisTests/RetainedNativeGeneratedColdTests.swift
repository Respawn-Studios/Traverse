import Darwin
import Dispatch
import ExplorerCore
import Foundation
import Testing
@testable import StorageAnalysis

// This exact cold-reader snapshot/pause investigation uses Debug-only hooks.
// Ordinary cold App acceptance is a separate real-process flow in dev.py.
#if DEBUG
private struct GeneratedNoConsumers: RetainedApplicationConsumerDrain {
    func revokeAndJoin() async throws {}
}
private struct GeneratedRetainedAccess: RetainedFreshAccessProvider {
    let root: URL
    func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess {
        guard case .single(let saved) = record.scope,
              saved.locator == root.standardizedFileURL.path else { throw StorageScanFailure.accessDenied }
        return .single(root, UUID())
    }
}

@Suite struct RetainedNativeGeneratedColdTests {
    /// The probe is the package's small RetainedColdProbe executable target.
    /// Missing explicit helper/probe paths means this native gate is NOT EXERCISED.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil &&
                       ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_COLD_PROBE"] != nil))
    func actualSingle17CloseThenSeparateProcessColdReadAndForget() async throws {
        let env = ProcessInfo.processInfo.environment
        let helperPath = try #require(env["TRAVERSE_RETAINED_QUAL_HELPER"])
        let probePath = try #require(env["TRAVERSE_RETAINED_COLD_PROBE"])
        let helper = try helperPath.nonEmptyFileURL(), probe = try probePath.nonEmptyFileURL()
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated alpha\n".utf8))
        let gate = FileActivityGate()
        let storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helper, activityGate: gate, accessProvider: GeneratedRetainedAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helper, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        let result = try #require(terminal?.result)
        let warmSnapshot = try await RetainedNativeQualificationSnapshot.capture(result)
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        let maybeTicket = await controller.publicationTicket()
        let ticket = try #require(maybeTicket)
        let publication = await controller.publish(candidate, ticket: ticket)
        var published = false
        if case .publication(.committed(_), let allowed, let pending) = publication { published = allowed && !pending }
        #expect(published)
        let publishedIndex = try await backend.loadCanonicalIndex()
        let record = try #require(publishedIndex.visibleRecords.first)
        #expect(record.catalogID == session.id)
        // Warm App admission must return the exact completed scan result,
        // after a fresh root/helper/catalog check, and close only this catalog.
        guard case .opened(let warmHandle) = await controller.openPrevious(record.catalogID),
              let shared = await backend.result(for: warmHandle), shared === result else {
            throw StorageScanFailure.changed
        }
        let sharedSnapshot = try await RetainedNativeQualificationSnapshot.capture(shared)
        let sharedBytes = try JSONSerialization.data(withJSONObject: sharedSnapshot, options: [.sortedKeys])
        let originalBytes = try JSONSerialization.data(withJSONObject: warmSnapshot, options: [.sortedKeys])
        #expect(sharedBytes == originalBytes)
        guard case .readClosed = await controller.closeRead(record.catalogID,
            consumers: GeneratedNoConsumers()) else { throw StorageScanFailure.changed }
        let closeGate = try #require(gate.closeAdmission())
        #expect(await gate.waitUntilDrained(closeGate))
        // No App presentation consumer exists in this generated test. Exercise
        // the controller's close-only handoff while new activity is refused.
        let maybeCloseTicket = await controller.beginRevocation(.retainOnClose)
        let closeTicket = try #require(maybeCloseTicket)
        guard case .coordinationComplete = await controller.completeRevocation(closeTicket,
            consumers: GeneratedNoConsumers()) else { throw StorageScanFailure.changed }
        #expect(await controller.resumeAdmissions())
        guard case .refused(.busy) = await backend.openCatalog(record,
            expectedEpoch: publishedIndex.epoch) else { throw StorageScanFailure.changed }
        #expect(gate.reopen(closeGate))
        guard case .refused(.changed) = await backend.openCatalog(record,
            expectedEpoch: publishedIndex.epoch - 1) else { throw StorageScanFailure.changed }
        let pause = RetainedColdOpenPause()
        AnalysisStoreFiles.installColdOpenHookForQualification { id in
            guard id == record.catalogID else { return }
            pause.entered.signal()
            _ = pause.release.wait(timeout: .now() + 5)
        }
        defer {
            pause.release.signal()
            AnalysisStoreFiles.installColdOpenHookForQualification(nil)
        }
        let opening = Task { await backend.openCatalog(record, expectedEpoch: publishedIndex.epoch) }
        let entered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: pause.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard entered else { throw StorageScanFailure.changed }
        let poolLock = open(fixture.pool.appendingPathComponent("pool.lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        let ownerLock = open(fixture.pool.appendingPathComponent(record.catalog.sessionChild)
            .appendingPathComponent("owner.lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard poolLock >= 0, ownerLock >= 0 else {
            if poolLock >= 0 { close(poolLock) }; if ownerLock >= 0 { close(ownerLock) }
            throw StorageScanFailure.changed
        }
        let globalAvailable = flock(poolLock, LOCK_EX | LOCK_NB) == 0
        if globalAvailable { _ = flock(poolLock, LOCK_UN) }
        let ownerBlocked = flock(ownerLock, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
        if !ownerBlocked { _ = flock(ownerLock, LOCK_UN) }
        close(poolLock); close(ownerLock)
        #expect(globalAvailable && ownerBlocked)
        pause.release.signal()
        guard case .opened(let parentOwner) = await opening.value else { throw StorageScanFailure.changed }
        let blocked = ScannerProcessControl()
        let blockedPipes = try ScannerWorkerProcess.launch(workerURL: probe, descriptors: [],
            arguments: [source.path, fixture.pool.path, fixture.indexDirectory.path, helper.path,
                        record.catalogID.uuidString], control: blocked)
        let blockedOutput = try ScannerWorkerProcess.collect(pipes: blockedPipes, control: blocked,
            maximumBytes: 4096, deadline: 30)
        blocked.finished()
        let blockedFrame = try #require(JSONSerialization.jsonObject(with: blockedOutput) as? [String: String])
        #expect(blockedFrame["refusal"] == "busy")
        guard case .closed(let released) = await backend.closeRead(parentOwner),
              released == parentOwner else { throw StorageScanFailure.changed }
        let control = ScannerProcessControl()
        defer { control.finished() }
        let pipes = try ScannerWorkerProcess.launch(workerURL: probe, descriptors: [],
            arguments: [source.path, fixture.pool.path, fixture.indexDirectory.path, helper.path,
                        record.catalogID.uuidString], control: control)
        let output = try ScannerWorkerProcess.collect(pipes: pipes, control: control,
            maximumBytes: 64 << 10, deadline: 30)
        let frame = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(frame["resultID"] as? String == record.catalogID.uuidString)
        let coldSnapshot = try #require(frame["snapshot"] as? [String: Any])
        let warmBytes = try JSONSerialization.data(withJSONObject: warmSnapshot, options: [.sortedKeys])
        let coldBytes = try JSONSerialization.data(withJSONObject: coldSnapshot, options: [.sortedKeys])
        #expect(coldBytes == warmBytes)
        #expect(frame["traversalLaunches"] as? Int == 0)
        #expect(frame["queryLaunches"] as? Int == 5)
        let maybeRevocation = await controller.beginRevocation(.forgetAll)
        let revoke = try #require(maybeRevocation)
        let forgotten = await controller.completeRevocation(revoke, consumers: GeneratedNoConsumers())
        guard case .coordinationComplete = forgotten else { throw StorageScanFailure.changed }
        #expect((try await backend.loadCanonicalIndex()).visibleRecords.isEmpty)
        #expect((try await backend.loadCanonicalIndex()).pendingForget.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.pool.appendingPathComponent(record.catalog.sessionChild).path))
    }
}

private final class RetainedColdOpenPause: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private extension String {
    func nonEmptyFileURL() throws -> URL {
        guard !isEmpty, hasPrefix("/"), !contains("..") else { throw StorageScanFailure.unavailable }
        return URL(fileURLWithPath: self)
    }
}
#endif
