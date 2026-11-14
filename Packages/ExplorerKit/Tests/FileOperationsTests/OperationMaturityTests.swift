import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct MaturityFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("maturity-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination"); journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
    }
    func file(_ name: String, parent: URL? = nil, bytes: Data = Data("fixture".utf8)) throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try bytes.write(to: url, options: .withoutOverwriting); return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations { RecoverableFileOperations(journalDirectory: journal, hooks: hooks) }
    func remove() { try? FileManager().removeItem(at: root) }
}

private final class ProgressReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationProgress] = []
    private var mainThread = false
    func append(_ value: OperationProgress) { lock.withLock { values.append(value); mainThread = mainThread || Thread.isMainThread } }
    var snapshots: [OperationProgress] { lock.withLock { values } }
    var usedMain: Bool { lock.withLock { mainThread } }
}


private enum ProgressHandshakeFailure: Error { case copyingDeliveryTimedOut }

/// The callback may arrive before or after native Copy completes. A remembered
/// semaphore signal handles either order without timing sleeps or polling.
private final class CopyPhaseDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let delivered = DispatchSemaphore(value: 0)
    private var nativeCalls = 0
    private var observedCopy = false
    private var timedOut = false
    func observe(_ value: OperationProgress) {
        guard value.phase == .copying, value.bytesTotal == 4 * 1024 * 1024 else { return }
        let signal = lock.withLock { () -> Bool in
            guard !observedCopy else { return false }
            observedCopy = true; return true
        }
        if signal { delivered.signal() }
    }
    func afterNativeCopy() throws {
        lock.withLock { nativeCalls += 1 }
        guard delivered.wait(timeout: .now() + 15) == .success else {
            lock.withLock { timedOut = true }
            throw ProgressHandshakeFailure.copyingDeliveryTimedOut
        }
    }
    var state: (nativeCalls: Int, observedCopy: Bool, timedOut: Bool) {
        lock.withLock { (nativeCalls, observedCopy, timedOut) }
    }
}

/// Test-only deliberate slow consumer. No receipt lock is held while blocking,
/// and only the first callback waits; producer and delivery remain independent.
private final class HeldProgressConsumer: @unchecked Sendable {
    private let first = OnceGate()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    func consume() {
        guard first.take() else { return }
        entered.signal()
        if release.wait(timeout: .now() + 15) != .success { lock.withLock { timedOut = true } }
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 15) == .success }
    func releaseFirst() { release.signal() }
    var didTimeOut: Bool { lock.withLock { timedOut } }
}

@Suite(.serialized) struct OperationMaturityTests {
    @Test func progressReportsRealCopyBytesAndDurableTerminalOffMain() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let source = try fixture.file("copy", bytes: Data(repeating: 0x7e, count: 4 * 1024 * 1024))
        let receipt = ProgressReceipt()
        let delivery = CopyPhaseDeliveryGate()
        var hooks = RecoveryHooks()
        // nativeCopy has returned and updated real logical progress; the worker
        // cannot replace the Copy phase with Verifying until delivery is seen.
        hooks.copyFaults.afterNativeCopy = { _, _ in try delivery.afterNativeCopy() }
        let service = fixture.service(hooks)
        let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false, progress: receipt.append)
        let result = await service.perform(plan, progress: { value in
            receipt.append(value)
            delivery.observe(value)
        })
        let handshake = delivery.state
        #expect(handshake.nativeCalls == 1)
        #expect(handshake.observedCopy)
        #expect(!handshake.timedOut)
        #expect(result.result.disposition == .succeeded)
        #expect(!receipt.usedMain)
        let values = receipt.snapshots
        #expect(values.allSatisfy { $0.jobID == plan.jobID })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
        #expect(values.contains { $0.phase == .copying && $0.bytesTotal == 4 * 1024 * 1024 })
        #expect(values.last?.isTerminal == true)
        #expect(values.last?.fractionCompleted == 1)
        #expect(try await service.recoveryRecords().records.first?.canUndo == true)
        #expect(values.filter { $0.phase != .copying }.allSatisfy { $0.bytesPerSecond == nil })
    }

    @Test func slowProgressConsumerHasOnlyOneCoalescedPendingSnapshot() throws {
        let receipt = ProgressReceipt()
        let expectedVerificationBytes: Int64 = 8 * 1024 * 1024
        let consumer = HeldProgressConsumer()
        defer { consumer.releaseFirst() }
        let reporter = OperationProgressReporter { value in receipt.append(value); consumer.consume() }
        reporter.begin(.verifying, bytes: expectedVerificationBytes)
        try #require(consumer.waitUntilEntered(), "First off-main progress callback must enter the explicit hold.")
        // begin(force:true) bypasses the rate throttle, but deliberately retains
        // only one pending value. The held callback cannot consume this burst.
        for index in 1...1024 {
            reporter.begin(.copying, index: index, count: 1024, bytes: 4 * 1024 * 1024)
            reporter.advance(bytes: 4 * 1024 * 1024)
        }
        reporter.begin(.verifying, index: 1024, count: 1024, bytes: expectedVerificationBytes)
        consumer.releaseFirst()
        reporter.flush()
        let coalesced = receipt.snapshots
        #expect(!consumer.didTimeOut)
        #expect(coalesced.count == 2)
        #expect(coalesced.first?.phase == .verifying)
        #expect(coalesced.first?.itemIndex == nil)
        #expect(coalesced.last?.phase == .verifying)
        #expect(coalesced.last?.itemIndex == 1024)
        #expect(coalesced.last?.bytesTotal == expectedVerificationBytes)
        #expect(!coalesced.contains { $0.phase == .copying })
        // A separately requested terminal is observed after the burst drains;
        // finish synchronizes delivery and retains its existing public contract.
        reporter.finish(success: false)
        #expect(receipt.snapshots.count == 3)
        #expect(receipt.snapshots.count <= 6)
        #expect(receipt.snapshots.last?.isTerminal == true)
        #expect(receipt.snapshots.last?.fractionCompleted == nil)
        #expect(!receipt.usedMain)
        let values = receipt.snapshots
        #expect(values.allSatisfy { $0.jobID == reporter.jobID })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    }

    @Test func stopAfterRenameDrainsReplaceAndLeavesRemainingInputNotStarted() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let first = try fixture.file("first"), second = try fixture.file("second")
        _ = try fixture.file("first", parent: fixture.destination, bytes: Data("old".utf8))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = OnceGate()
        let receipt = ProgressReceipt()
        let service = fixture.service(RecoveryHooks(afterRename: { if once.take() { entered.signal(); release.wait() } }))
        let plan = try await service.prepareTransfer(sources: [first, second], destinationDirectory: fixture.destination, move: true)
        let task = Task { await service.perform(plan, resolutions: [plan.conflicts[0].id: .replace], progress: receipt.append) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        task.cancel()
        for _ in 0..<100 where !receipt.snapshots.contains(where: { $0.phase == .stopping }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(receipt.snapshots.contains { $0.phase == .stopping && $0.cancellationRequested })
        release.signal()
        let result = await task.value
        #expect(result.result.disposition == .partial)
        #expect(result.result.items.contains { $0.source == first && $0.status == .succeeded })
        #expect(result.result.items.contains { $0.source == second && $0.status == .notStarted })
        #expect(try String(contentsOf: fixture.destination.appendingPathComponent("first"), encoding: .utf8) == "fixture")
        #expect(FileManager().fileExists(atPath: second.path))
        #expect(receipt.snapshots.last?.fractionCompleted == nil)
        #expect(try await service.recoveryRecords().records.first?.canUndo == true)
        #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(try String(contentsOf: fixture.destination.appendingPathComponent("first"), encoding: .utf8) == "old")
    }

    @Test func stopImmediatelyAfterUndoRenameDrainsAndExplicitRecoveryCompletes() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let first = try fixture.file("first"), second = try fixture.file("second")
        let originals = try [first, second].map { try verifiedTree($0, cancellation: OperationCancellation()) }
        let moved = await fixture.service().perform(.move(sources: [first, second], destinationDirectory: fixture.destination))
        try #require(moved.result.disposition == .succeeded)
        let id = try #require(moved.recordID)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = OnceGate()
        let receipt = ProgressReceipt()
        let service = fixture.service(RecoveryHooks(afterRename: {
            if once.take() { entered.signal(); _ = release.wait(timeout: .now() + 15) }
        }))
        let task = Task { await service.undo(recordID: id, progress: receipt.append) }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 15) == .success) }
        }
        task.cancel()
        for _ in 0..<100 where !receipt.snapshots.contains(where: { $0.phase == .stopping }) { try await Task.sleep(for: .milliseconds(5)) }
        release.signal()
        let stopped = await task.value
        try #require(reached, "Undo must reach its first completed rename before Stop.")
        #expect(stopped.result.disposition == .partial)
        #expect(stopped.result.cancellationRequested)
        #expect(stopped.result.items.map(\.status) == [.succeeded, .cancelled, .notStarted])
        #expect(stopped.result.items.last?.destination?.path == first.path)
        #expect(receipt.snapshots.contains { $0.phase == .stopping })
        #expect(receipt.snapshots.last?.isTerminal == true)
        #expect(receipt.snapshots.last?.fractionCompleted == nil)
        #expect(originals[1].matches(try verifiedTree(second, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: first.path))
        #expect(originals[0].matches(try verifiedTree(fixture.destination.appendingPathComponent("first"), cancellation: OperationCancellation())))
        let durable = try readMaturityRecord(fixture.journal, id: id)
        #expect(durable.state == "needsReview")
        #expect(durable.steps.map(\.undone) == [false, true])
        #expect(durable.steps.allSatisfy { $0.after != nil })
        let review = try await fixture.service().recoveryRecords()
        #expect(review.records.first?.canRecover == true)
        #expect(review.unfinishedCount == 1)
        let recovered = await fixture.service().recover(recordID: id)
        #expect(recovered.result.disposition == .succeeded)
        #expect(recovered.result.items.count == 1)
        for (url, original) in zip([first, second], originals) {
            #expect(original.matches(try verifiedTree(url, cancellation: OperationCancellation())))
        }
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        let finished = try readMaturityRecord(fixture.journal, id: id)
        #expect(finished.state == "undone")
        #expect(finished.steps.allSatisfy { $0.undone })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
                   "Real cross-volume Stop requires marked private temporary fixtures."))
    func stopAfterCrossVolumePublicationDrainsSourceRetentionAndKeepsUndo() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let temporary = try MaturityTemporaryRoot()
        defer { do { try temporary.remove() } catch { Issue.record("Owned cross-volume Stop fixture cleanup refused; preserved for review.") } }
        let localAnchor = try DirectoryAnchor(fixture.source, resolve: false)
        try #require(localAnchor.identity.device != temporary.identity.device,
                     "This qualification requires genuinely different st_dev values.")
        let first = try fixture.file("first", bytes: Data(repeating: 0x53, count: 1_048_576))
        let second = try fixture.file("second")
        let original = try verifiedTree(first, cancellation: OperationCancellation())
        let untouched = try verifiedTree(second, cancellation: OperationCancellation())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = OnceGate()
        let receipt = ProgressReceipt()
        let service = fixture.service(RecoveryHooks(afterRename: {
            if once.take() { entered.signal(); _ = release.wait(timeout: .now() + 15) }
        }))
        let task = Task { await service.perform(.move(sources: [first, second], destinationDirectory: temporary.url), progress: receipt.append) }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 15) == .success) }
        }
        // At this hook the destination was published; source retirement has not begun.
        let sourcePresentAtPublication = FileManager().fileExists(atPath: first.path)
        let target = temporary.url.appendingPathComponent("first")
        let destinationPresentAtPublication = FileManager().fileExists(atPath: target.path)
        task.cancel()
        for _ in 0..<100 where !receipt.snapshots.contains(where: { $0.phase == .stopping }) { try await Task.sleep(for: .milliseconds(5)) }
        release.signal()
        let stopped = await task.value
        try #require(reached, "Cross-volume Move must publish before Stop.")
        #expect(sourcePresentAtPublication && destinationPresentAtPublication)
        #expect(stopped.result.disposition == .partial)
        #expect(stopped.result.cancellationRequested)
        #expect(stopped.result.items.map(\.status) == [.succeeded, .notStarted])
        #expect(stopped.result.items[0].source?.path == first.path)
        #expect(stopped.result.items[1].source?.path == second.path)
        #expect(receipt.snapshots.contains { $0.phase == .stopping })
        #expect(receipt.snapshots.last?.isTerminal == true)
        #expect(receipt.snapshots.last?.fractionCompleted == nil)
        #expect(!FileManager().fileExists(atPath: first.path))
        #expect(untouched.matches(try verifiedTree(second, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: temporary.url.appendingPathComponent("second").path))
        #expect(try verifiedTree(target, cancellation: OperationCancellation()).digest == original.digest)
        let id = try #require(stopped.recordID)
        let durable = try readMaturityRecord(fixture.journal, id: id)
        #expect(durable.state == "committed")
        #expect(durable.steps.count == 2)
        #expect(durable.steps.allSatisfy { $0.after != nil && !$0.undone })
        let retirement = try #require(durable.steps.first { $0.source.path == first.path })
        #expect(original.matches(try verifiedTree(retirement.destination, cancellation: OperationCancellation())))
        #expect(try await fixture.service().recoveryRecords().records.first?.canUndo == true)
        let undone = await fixture.service().undo(recordID: id)
        #expect(undone.result.disposition == .succeeded)
        #expect(original.matches(try verifiedTree(first, cancellation: OperationCancellation())))
        #expect(untouched.matches(try verifiedTree(second, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: target.path))
        #expect(try readMaturityRecord(fixture.journal, id: id).state == "undone")
    }

    @Test func stopBeforePublicationPreservesSourceAndSurfacesStagingReview() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let source = try fixture.file("staged")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let service = fixture.service(RecoveryHooks(beforeCommit: { entered.signal(); release.wait() }))
        let task = Task { await service.perform(.copy(sources: [source], destinationDirectory: fixture.destination)) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        task.cancel(); release.signal()
        let result = await task.value
        #expect(result.result.disposition == .cancelled)
        #expect(FileManager().fileExists(atPath: source.path))
        #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("staged").path))
        let review = try await service.recoveryRecords()
        #expect(review.records.first?.state == "needsReview")
        #expect(review.unfinishedCount == 1)
        #expect(review.records.first?.canUndo == false)
        #expect(review.records.first?.locations.contains { FileManager().fileExists(atPath: $0.appendingPathComponent("payload").path) } == true)
    }

    @Test func stopDuringKnownTrashDrainsResultAndKeepsCompletedItemUndoable() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let first = try fixture.file("first"), second = try fixture.file("second")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let adapter = LocalFileOperations(trash: { source in
            let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
            try FileManager().moveItem(at: source, to: target)
            entered.signal(); release.wait()
            return target
        })
        let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(), legacy: adapter)
        let task = Task { await service.perform(.trash(sources: [first, second])) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        task.cancel(); release.signal()
        let result = await task.value
        #expect(result.result.items.map(\.status) == [.succeeded, .notStarted])
        #expect(result.result.cancellationRequested)
        #expect(try await service.recoveryRecords().records.first?.canUndo == true)
        #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(FileManager().fileExists(atPath: first.path)); #expect(FileManager().fileExists(atPath: second.path))
    }

    @Test func boundedWorkerAdmissionRejectsSeventeenthAndCancelledWaiterNeverRuns() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let service = fixture.service()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = Task { try await service.worker { _ in entered.signal(); release.wait(); return 1 } }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        let ran = OnceGate()
        var waiting: [Task<Int, Error>] = []
        for index in 1..<16 {
            waiting.append(Task { try await service.worker { _ in _ = ran.take(); return index } })
        }
        while service.pendingWorkerCount < 16 { try await Task.sleep(for: .milliseconds(1)) }
        do { _ = try await service.worker { _ in 17 }; Issue.record("admitted beyond bounded queue") }
        catch { #expect(error as? FileOperationFailure == .unavailable) }
        waiting.forEach { $0.cancel() }
        release.signal(); #expect(try await first.value == 1)
        for task in waiting { do { _ = try await task.value; Issue.record("cancelled waiter executed") } catch { #expect(error is CancellationError) } }
        #expect(ran.take())
    }

    @Test func resolvesSkipsBeforeAdmissionAndRefusesOversizedTopLevelBatch() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let service = fixture.service()
        let source = try fixture.file("one")
        do {
            _ = try await service.prepareTransfer(sources: Array(repeating: source, count: 1025), destinationDirectory: fixture.destination, move: true)
            Issue.record("oversized input accepted")
        } catch { #expect(error as? FileOperationFailure == .invalidRequest) }
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
        let existing = try fixture.file("one", parent: fixture.destination)
        let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: true)
        let result = await service.perform(plan, resolutions: [plan.conflicts[0].id: .skip])
        #expect(result.result.items.map(\.status) == [.skipped]); #expect(result.recordID == nil)
        #expect(FileManager().fileExists(atPath: existing.path))
    }

    @Test func admits1024MovesAndMoreThan512DurableSteps() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let sources = try (0..<1024).map { try fixture.file("item-\($0)") }
        let service = fixture.service()
        let started = ContinuousClock.now
        let result = await service.perform(.move(sources: sources, destinationDirectory: fixture.destination))
        #expect(result.result.items.count == 1024)
        #expect(result.result.disposition == .succeeded)
        let store = try OperationJournal(fixture.journal)
        let record = try #require(store.inspect().records.first)
        #expect(record.steps.count == 1024); #expect(record.state == "committed")
        #expect(sources.allSatisfy { !FileManager().fileExists(atPath: $0.path) })
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).filter { !$0.hasPrefix(".") }.count == 1024)
        print("Maturity generated fixture: 1024 moves / 1024 durable steps completed in \(started.duration(to: .now))")
    }

    @Test func verifiesAndMovesTreeAboveTenThousandDescendants() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let tree = fixture.source.appendingPathComponent("tree")
        try FileManager().createDirectory(at: tree, withIntermediateDirectories: false)
        for index in 0..<10_001 { _ = try fixture.file("f\(index)", parent: tree, bytes: Data()) }
        let started = ContinuousClock.now
        let result = await fixture.service().perform(.move(sources: [tree], destinationDirectory: fixture.destination))
        #expect(result.result.disposition == .succeeded)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.appendingPathComponent("tree").path).count == 10_001)
        print("Maturity generated fixture: 10002-node verified move completed in \(started.duration(to: .now))")
    }

    @Test func copiesTreeAboveTenThousandDescendants() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let tree = fixture.source.appendingPathComponent("copy-tree")
        try FileManager().createDirectory(at: tree, withIntermediateDirectories: false)
        for index in 0..<10_001 { _ = try fixture.file("f\(index)", parent: tree, bytes: Data()) }
        let started = ContinuousClock.now
        let result = await fixture.service().perform(.copy(sources: [tree], destinationDirectory: fixture.destination))
        #expect(result.result.disposition == .succeeded)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.appendingPathComponent("copy-tree").path).count == 10_001)
        #expect(try FileManager().contentsOfDirectory(atPath: tree.path).count == 10_001)
        print("Maturity generated fixture: 10002-node verified copy completed in \(started.duration(to: .now))")
    }

    @Test func nativeDataCallbackMeasuresBytesAndCopyRefusesSourceGrowth() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let source = try fixture.file("growing", bytes: Data(repeating: 0x43, count: 8 * 1024 * 1024))
        let observed = ByteReceipt()
        let once = OnceGate()
        let failure = await Task.detached { () -> FileOperationFailure? in
            do {
                let from = try DirectoryAnchor(fixture.source), to = try DirectoryAnchor(fixture.destination)
                try copyVerifiedNode(sourceParent: from.fd, sourceName: source.lastPathComponent,
                    destinationParent: to.fd, destinationName: "payload", originalDevice: from.identity.device,
                    cancellation: OperationCancellation(), onDataProgress: { count in
                        observed.append(count)
                        if count > 0, once.take() {
                            let fd = open(source.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                            if fd >= 0 { var byte: UInt8 = 0x42; _ = write(fd, &byte, 1); close(fd) }
                        }
                    })
                return nil
            } catch { return error as? FileOperationFailure }
        }.value
        #expect(failure == .sourceChanged)
        #expect(observed.values.contains { $0 > 0 })
        #expect(zip(observed.values, observed.values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(try Data(contentsOf: source).count == 8 * 1024 * 1024 + 1)
        #expect(FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("payload").path))
    }

    @Test func sourceGrowthAfterAdmissionIsRefusedBeforePublication() async throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let tree = fixture.source.appendingPathComponent("tree")
        try FileManager().createDirectory(at: tree, withIntermediateDirectories: false)
        _ = try fixture.file("first", parent: tree)
        let service = fixture.service(RecoveryHooks(afterAdmission: {
            try! Data("new fixture".utf8).write(to: tree.appendingPathComponent("new"), options: .withoutOverwriting)
        }))
        let result = await service.perform(.copy(sources: [tree], destinationDirectory: fixture.destination))
        #expect(result.result.disposition == .failed)
        #expect(result.result.items.contains { $0.status == .failed(.sourceChanged) })
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try FileManager().contentsOfDirectory(atPath: tree.path).count == 2)
    }

    @Test func sharedTraversalBudgetRefusesNode50001() throws {
        let fixture = try MaturityFixture(); defer { fixture.remove() }
        let file = try fixture.file("node")
        let parent = try DirectoryAnchor(fixture.source)
        let snapshot = try EntrySnapshot(parent: parent.fd, name: file.lastPathComponent)
        let budget = TraversalBudget()
        for _ in 0..<50_000 { try budget.consume(snapshot, depth: 0) }
        #expect(budget.remaining == 0)
        #expect(throws: FileOperationFailure.unsupported) { try budget.consume(snapshot, depth: 0) }
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func take() -> Bool { lock.withLock { defer { available = false }; return available } }
}

private final class ByteReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int64] = []
    func append(_ value: Int64) { lock.withLock { stored.append(value) } }
    var values: [Int64] { lock.withLock { stored } }
}

private func readMaturityRecord(_ directory: URL, id: UUID) throws -> JournalRecord {
    let journal = try OperationJournal(directory)
    let record = try journal.inspectRecord(id)
    return try #require(record)
}

/// Only this freshly created, marked private temporary root can be removed by the test.
private struct MaturityTemporaryRoot: Sendable {
    let url: URL
    let identity: EntrySnapshot
    private let parentIdentity: EntrySnapshot
    private let markerData: Data
    private let markerName = ".mac-explorer-owned-maturity-fixture"
    init() throws {
        let parent = try DirectoryAnchor(URL(fileURLWithPath: "/private/tmp", isDirectory: true), resolve: false)
        parentIdentity = parent.identity
        let id = UUID()
        let name = "mac-explorer-maturity-cross-volume-" + id.uuidString
        url = parent.url.appendingPathComponent(name, isDirectory: true)
        markerData = Data("MacExplorer owned Stop fixture v1\n\(id.uuidString)\n".utf8)
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw FileOperationFailure.ioFailure }
        let root = try DirectoryAnchor(url, resolve: false)
        identity = root.identity
        let fd = openat(root.fd, markerName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOperationFailure.ioFailure }
        defer { close(fd) }
        guard markerData.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == markerData.count,
              fsync(fd) == 0 else { throw FileOperationFailure.ioFailure }
        try syncDirectory(root); try syncDirectory(parent)
    }
    func remove() throws {
        guard url.deletingLastPathComponent().path == "/private/tmp",
              url.lastPathComponent.hasPrefix("mac-explorer-maturity-cross-volume-"),
              UUID(uuidString: String(url.lastPathComponent.dropFirst("mac-explorer-maturity-cross-volume-".count))) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        let root = try DirectoryAnchor(url, resolve: false)
        guard parent.identity.sameObject(as: parentIdentity), root.identity.sameObject(as: identity),
              try OperationJournal.read(name: markerName, anchor: root) == markerData else { throw FileOperationFailure.sourceChanged }
        try parent.validate(); try root.validate()
        try FileManager().removeItem(at: url)
    }
}
