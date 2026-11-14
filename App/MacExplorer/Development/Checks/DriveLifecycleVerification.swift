import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

#if DEBUG
/// No native drive mutations: deterministic backend responses exercise the real
/// application owner, queue, activity barrier and observed generated transfers.
@MainActor
enum DriveLifecycleVerification {
    static func run(in root: URL) async throws -> [String] {
        let operations = ApplicationOperationCoordinator.shared
        let original = operations.drives
        let backend = Backend()
        let drives = ApplicationVolumeCoordinator(operations: operations, backend: backend)
        operations.drives = drives
        let gate = ApplicationFileActivity.gate
        defer { backend.finishAll(); drives.cancel(); operations.drives = original }
        try require(operations.canBeginVolumeBarrier && !gate.isClosed, "Drive checks require idle owners")
        drives.startDiscovery()
        await drives.drainProtection()
        let target = ManagedVolume(id: UUID(), name: "Generated drive", url: root, isInternal: false,
            canMount: false, canUnmount: true, canEject: true, fileSystemID: 999, group: 999)
        backend.emit([target])
        try await until { drives.volumes == [target] }

        let activation = UUID()
        try require(operations.beginCopyPreview(owner: activation), "Drive activation exclusion requires an otherwise idle owner")
        drives.request(target, action: .eject, policy: .requireCancel)
        let refusedDuringActivation = !drives.isBusy
        operations.finishCopyPreview(owner: activation)
        if drives.isBusy { drives.cancel(); try await until { !drives.isBusy } }
        try require(refusedDuringActivation, "Drive preparation started inside the fully idle Copy-preview activation interval")

        backend.holdPreparation = true
        drives.request(target, action: .eject, policy: .requireCancel)
        try await until { backend.hasHeldPreparation }
        drives.setProtection(.keepMounted, for: target)
        try require(drives.protectionLevel(for: target) == .none, "A protection edit raced an admitted drive preparation")
        let reverseActivation = UUID()
        let admittedDuringPreparation = operations.beginCopyPreview(owner: reverseActivation)
        if admittedDuringPreparation { operations.finishCopyPreview(owner: reverseActivation) }
        try require(!admittedDuringPreparation, "Copy-preview activation started while drive metadata preparation was running")
        drives.cancel()
        try require(drives.isPreparing && drives.isBusy && !drives.canCancel && backend.performed == 0,
                    "Cancelled preparation pretended the actual metadata worker had finished")
        backend.releasePreparation()
        try await until { !drives.isBusy }
        try require(drives.pending == nil && backend.performed == 0 && drives.message == "Drive check cancelled.",
                    "A late cancelled preparation submitted a drive request")
        backend.holdPreparation = false

        // Cancellation stops intent, never pretends a retained worker finished.
        let navigation = BrowserViewController(settings: BrowserSettings(persist: false))
        let originalLocation = navigation.location
        var retained: FileActivityGate.Lease? = try gate.begin()
        drives.request(target, action: .eject, policy: .requireCancel)
        try await until { gate.isClosed && drives.pending?.intent.phase == .draining }
        try require(backend.performed == 0 && gate.activeCount > 0, "Drive submitted before actual worker drain")
        navigation.navigate(to: .directory(root))
        try require(navigation.location == originalLocation && !navigation.isViewLoaded
            && !navigation.commandEnabled(#selector(BrowserViewController.goComputer(_:)))
            && navigation.commandEnabled(#selector(BrowserViewController.showDriveControls(_:))),
                    "Drive quiescence allowed stale navigation or hid its cancellation controls")
        drives.cancel()
        try require(!gate.isClosed && retained != nil && drives.pending == nil, "Cancel eject lost worker or admission ownership")
        retained = nil
        try await until { gate.activeCount == 0 }

        // No Swift cancellation can withdraw a request submitted to the OS.
        drives.request(target, action: .eject, policy: .requireCancel)
        try await until { drives.pending?.intent.phase == .submitted && backend.performed == 1 }
        drives.cancel()
        try require(drives.pending != nil && gate.isClosed && !drives.canCancel,
                    "Submitted native request lost ownership on cancellation")
        try require(!drives.admitNewWork(fileSystemIDs: [999]), "Native request admitted new affected work")
        backend.finishNext(.init(unmounted: false, ejected: false, failure: .busy))
        try await until { drives.pending == nil && !gate.isClosed }
        try require(drives.message.contains("in use"), "OS Busy was not explained honestly")

        // Waiting intent freezes affected/unknown admission, not unrelated facts.
        let exclusive = UUID()
        try require(operations.begin(owner: exclusive), "Could not hold exclusive owner for drive admission check")
        drives.request(target, action: .eject, policy: .requireCancel)
        try await until { drives.pending != nil && !drives.isPreparing }
        try require(!drives.admitNewWork(fileSystemIDs: nil) && !drives.admitNewWork(fileSystemIDs: [999])
                    && drives.admitNewWork(fileSystemIDs: [555]), "Default pending-eject admission is incorrect")
        drives.cancel()
        drives.request(target, action: .eject, policy: .cancelEject)
        try await until { drives.pending != nil && !drives.isPreparing }
        try require(drives.admitNewWork(fileSystemIDs: [999]) && drives.pending == nil,
                    "Alternative policy did not cancel pending eject before new work")
        operations.finish(owner: exclusive)

        // Real queued generated Copy must finish before the fake native action.
        let owned = root.appendingPathComponent("drive-queue-" + UUID().uuidString, isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        let file = source.appendingPathComponent("Generated.txt")
        try await Task.detached {
            try FileManager().createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("generated-drive-queue".utf8).write(to: file, options: .withoutOverwriting)
        }.value
        let settings = BrowserSettings(persist: false)
        let browser = BrowserViewController(settings: settings)
        browser.permitsBackgroundVerification = true
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal"),
                                               activity: ApplicationFileActivity.beginOperation)
        let observer = LocalFileOperations(activity: ApplicationFileActivity.beginOperation)
        let sourceFacts = try await observer.observeSelection([file])
        let destinationFacts = try await observer.observeDirectory(destination)
        let facts = sourceFacts.combining(destinationFacts)
        let device = try requireValue(facts.observedFileSystemIDs.first)
        let queuedTarget = ManagedVolume(id: target.id, name: "Generated queue drive", url: root, isInternal: false,
            canMount: false, canUnmount: true, canEject: true, fileSystemID: device, group: 1000)
        backend.emit([queuedTarget])
        try await until { drives.volumes == [queuedTarget] }
        operations.transfers.pause()
        let id = try requireValue(operations.transfers.enqueue(sources: [file], destination: destination,
            move: false, title: "Generated drive Copy", origin: browser, engine: engine,
            observation: facts, metadataPolicy: .strict))
        try await until { operations.transfers.state.waiting.contains { $0.id == id && $0.phase == .ready } }
        drives.request(queuedTarget, action: .eject, policy: .requireCancel)
        try await until { drives.pending?.intent.phase == .waiting && drives.jobs.contains { $0.id == id } }
        try require(!gate.isClosed && backend.performed == 1, "Waiting eject blocked the captured transfer")
        _ = operations.transfers.resume()
        try await until { drives.pending?.intent.phase == .submitted && backend.performed == 2 }
        let copied = try await Task.detached { try Data(contentsOf: destination.appendingPathComponent("Generated.txt")) }.value
        try require(copied == Data("generated-drive-queue".utf8), "Eject preceded the committed generated Copy")
        backend.finishNext(.init(unmounted: true, ejected: true))
        try await until { drives.pending == nil && !gate.isClosed }
        try require(backend.drainedAtEverySubmission, "Native backend saw an undrained activity gate")
        let beforeForce = backend.prepared
        drives.request(queuedTarget, action: .forceUnmountAndEject, policy: .requireCancel)
        try require(backend.prepared == beforeForce && !drives.isBusy, "Unqualified advanced force was submitted")
        drives.request(queuedTarget, action: .eject, policy: .requireCancel)
        try await until { drives.pending?.intent.phase == .submitted && backend.performed == 3 }
        backend.finishNext(.init(unmounted: true, ejected: false, failure: .stillAttached))
        try await until { !drives.isBusy && !gate.isClosed }
        try require(drives.message.hasPrefix("Unmounted; eject did not finish.") && drives.message.contains("still attached"),
                    "Partial device removal was incorrectly described as Ejected")
        let reconnected = ManagedVolume(id: UUID(), name: "Generated reconnected drive", url: root, isInternal: nil,
            canMount: false, canUnmount: false, canEject: false, fileSystemID: device, group: nil, deviceKind: .unknown, mediaID: 12345)
        backend.emit([reconnected])
        try await until { drives.volumes == [reconnected] }
        try require(drives.offlineVolume(containing: root) != nil, "Reconnection silently adopted old tab paths")
        drives.acknowledgeNavigation(to: root)
        try require(drives.offlineVolume(containing: root) == nil,
                    "Explicit browsing required an unrelated device-removal capability")
        return ["driveDiscoveryIsReadOnly", "driveActivationMutualExclusion", "drivePreparationCancellationDrains", "driveActualWorkerDrain", "driveQuiescenceStopsStaleNavigation", "driveCancelBeforeSubmission", "driveSubmittedOwnership",
                "driveBusyExplanation", "driveNewWorkPolicies", "driveCapturedQueueFinishesFirst", "driveForceRemainsUnavailable", "drivePartialEjectIsHonest", "driveExplicitReconnectDoesNotRequireEjectCapability"]
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    private static func until(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: "Drive fixture did not settle within ten seconds at check \(line)")
    }
    private static func requireValue<T>(_ value: T?) throws -> T {
        guard let value else { throw UIVerification.Failure(message: "Missing generated drive observation") }; return value
    }

    private final class Backend: VolumeLifecycleManaging, @unchecked Sendable {
        let updates: AsyncStream<[ManagedVolume]>
        private let output: AsyncStream<[ManagedVolume]>.Continuation
        private let lock = NSLock()
        private var pending: [CheckedContinuation<VolumeActionResult, Never>] = []
        private var preparedCount = 0
        private var performedCount = 0
        private var allDrained = true
        private var hold = false
        private var preparation: (PreparedVolumeAction, CheckedContinuation<PreparedVolumeAction, Never>)?
        var holdPreparation: Bool { get { lock.withLock { hold } } set { lock.withLock { hold = newValue } } }
        var hasHeldPreparation: Bool { lock.withLock { preparation != nil } }
        var prepared: Int { lock.withLock { preparedCount } }
        var performed: Int { lock.withLock { performedCount } }
        var drainedAtEverySubmission: Bool { lock.withLock { allDrained } }
        init() { (updates, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
        func emit(_ values: [ManagedVolume]) { output.yield(values) }
        func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) async throws -> PreparedVolumeAction {
            try removalProtection.validate(target: target, action: action, members: [target])
            let plan = PreparedVolumeAction(target: target, affected: [target], action: action, protecting: locations)
            return await withCheckedContinuation { continuation in
                let held = lock.withLock {
                    preparedCount += 1
                    if hold { preparation = (plan, continuation) }
                    return hold
                }
                if !held { continuation.resume(returning: plan) }
            }
        }
        func releasePreparation() {
            let held = lock.withLock { let held = preparation; preparation = nil; return held }
            if let held { held.1.resume(returning: held.0) }
        }
        func perform(_ prepared: PreparedVolumeAction) async -> VolumeActionResult {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    performedCount += 1
                    allDrained = allDrained && ApplicationFileActivity.gate.isClosed && ApplicationFileActivity.gate.activeCount == 0
                    pending.append(continuation)
                }
            }
        }
        func finishNext(_ result: VolumeActionResult) {
            let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            continuation?.resume(returning: result)
        }
        func finishAll() {
            releasePreparation()
            let all = lock.withLock { let all = pending; pending.removeAll(); return all }
            all.forEach { $0.resume(returning: .init(unmounted: false, ejected: false, failure: .unavailable)) }
        }
    }
}
#endif
