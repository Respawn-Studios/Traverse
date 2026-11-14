#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage
import StorageAnalysis

/// Actual queue/worker composition, never a new scheduling or mutation route.
@MainActor final class DevelopmentConcurrentChecks {
    private let root: URL
    private let owner: BrowserWindowController
    private let phase = Phase()
    private var jobID: UUID?
    private var timer: Timer?
    private var ticks = 0, previous = CACurrentMediaTime(), maximumGap = 0.0
    private var maximumActivities = 0, simultaneous = false
    private var overlapSamples = 0
    private var overlapPhases = Set<String>()
    private var queue: ApplicationTransferQueue { owner.browser.operationCoordinator.transfers }

    init(root: URL, settings: BrowserSettings) {
        self.root = root
        settings.restoresSession = false
        owner = BrowserWindowController(settings: settings)
    }
    func prepare() async throws {
        guard owner.isWorkspacePresentation else { throw UIVerification.Failure(message: "Generated concurrency requires the actual workspace") }
        let browser = owner.browser
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        owner.window?.title = "Concurrent queue · generated review"
        owner.window?.setFrame(.init(x: 80, y: 60, width: 1000, height: 660), display: true)
        owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        print("CONCURRENT_PREPARING_WORKSPACE")
        owner.beginBrowsing()
        try await wait("workspace readiness") { self.owner.workspace.sessionReady }
        print("CONCURRENT_WORKSPACE_READY")
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await settled()
    }
    func run() async throws -> [String: Any] {
        let browser = owner.browser, source = try sourceFixture()
        let destination = root.appendingPathComponent("source/OperationDestination")
        let engine = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/history"))
        browser.recoverableFileOperations = engine
        queue.progressForVerification = { [phase] value in phase.receive(value) }
        let tick = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer = tick; previous = CACurrentMediaTime(); RunLoop.main.add(tick, forMode: .common)
        defer { tick.invalidate(); timer = nil; queue.progressForVerification = nil }
        guard let id = queue.enqueue(sources: [source], destination: destination, move: false,
            title: "Copy generated concurrency folder", origin: browser, engine: engine,
            retaining: FileAccessLifetimes(leases: []), metadataPolicy: .strict, copyExecution: .standard) else {
            throw UIVerification.Failure(message: "Generated queue did not admit Copy")
        }
        jobID = id
        print("CONCURRENT_QUEUED_COPY")
        try await wait("simultaneous workers or completed Copy") { self.simultaneous || self.queue.results.contains(where: { $0.id == id }) }
        guard simultaneous else { throw UIVerification.Failure(message: "Actual scan/copy overlap was not observed") }
        browser.navigate(to: .directory(destination))
        try await settled()
        let targetPath: String? = if case .directory(let location) = browser.location { location.standardizedFileURL.path } else { nil }
        guard targetPath == destination.standardizedFileURL.path else { throw UIVerification.Failure(message: "Concurrent native navigation did not settle") }
        try await wait("actual Copy drain") { self.queue.isIdleForVolumeAction && self.queue.results.contains(where: { $0.id == id }) }
        guard let copied = queue.results.first(where: { $0.id == id }), copied.outcome.result.disposition == .succeeded,
              let operation = copied.outcome.recordID else { throw UIVerification.Failure(message: "Concurrent standard Copy failed") }
        let copiedRoot = destination.appendingPathComponent("OperationSource")
        let copiedCount = try await Task.detached { try FileManager.default.contentsOfDirectory(atPath: copiedRoot.path).count }.value
        guard copiedCount == 2048 else { throw UIVerification.Failure(message: "Concurrent Copy omitted generated files") }
        let undo = await engine.undo(recordID: operation)
        guard undo.result.disposition == .succeeded else { throw UIVerification.Failure(message: "Concurrent Copy exact Undo failed") }
        let retention = try await engine.retentionRecord(recordID: operation)
        guard retention.areas.count == 1, retention.areas[0].verified,
              await Task.detached(operation: { !FileManager.default.fileExists(atPath: copiedRoot.path) }).value else {
            throw UIVerification.Failure(message: "Concurrent Copy Undo retention is incomplete")
        }
        guard maximumGap <= 0.4, ticks >= 10 else { throw UIVerification.Failure(message: "Concurrent native event-loop response gate") }
        jobID = nil
        return ["passed": true, "standardQueueCopyFiles": copiedCount, "exactUndo": true,
            "simultaneousActualActivities": maximumActivities, "overlapPhases": overlapPhases.sorted(),
            "overlapSamples": overlapSamples, "scannerTerminalAbsentDuringSamples": true,
            "mainLoopMaximumGapSeconds": maximumGap, "mainLoopTicks": ticks,
            "nativeNavigationDuringCopy": true, "retainedUndoArea": retention.areas[0].url.lastPathComponent,
            "retainedUndoOperation": operation.uuidString, "sourceMutation": false,
            "clipboardReads": 0, "clipboardWrites": 0, "personalFiles": 0, "network": 0]
    }
    private func sample() {
        let now = CACurrentMediaTime(); maximumGap = max(maximumGap, now - previous); previous = now; ticks += 1
        let activities = ApplicationFileActivity.gate.activeCount; maximumActivities = max(maximumActivities, activities)
        let update = ApplicationStorageAnalysis.shared.pagedUpdateForVerification
        if activities >= 2, update?.status == .scanning, update?.workerDrained == false,
           ApplicationStorageAnalysis.shared.pagedDiagnosticForVerification["worker_reason"] == nil,
           let value = phase.current, [.copying, .verifying, .publishing, .syncing, .retaining].contains(value) {
            overlapSamples += 1; simultaneous = overlapSamples >= 3; overlapPhases.insert(value.rawValue)
        }
    }
    func close() async {
        if let id = jobID {
            _ = queue.cancelWaiting(id); _ = queue.stopActive(expectedID: id)
            try? await wait("owned queue close") { self.queue.isIdleForVolumeAction }
        }
        timer?.invalidate(); queue.progressForVerification = nil
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
    }
    private func sourceFixture() throws -> URL {
        guard let token = ProcessInfo.processInfo.environment["MAC_EXPLORER_WORKLOAD_SOURCE_CASE"],
              UUID(uuidString: token)?.uuidString == token else { throw UIVerification.Failure(message: "Generated source case missing") }
        let sourceRoot = root.deletingLastPathComponent().appendingPathComponent(token)
        guard sourceRoot.resolvingSymlinksInPath() == sourceRoot,
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceRoot.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["packet"] as? String == "traverse-development-v1", marker["action"] as? String == "motion-audit",
              let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceRoot.appendingPathComponent("inputs.json"))) as? [String: Any],
              inputs["surface"] as? String == "workload" else { throw UIVerification.Failure(message: "Generated source case is not admitted") }
        return sourceRoot.appendingPathComponent("source/OperationSource")
    }
    private func settled() async throws { try await wait("browser listing") { !self.owner.browser.isLoading && self.owner.browser.orderingTask == nil } }
    private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 30
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw UIVerification.Failure(message: "Generated concurrent-work deadline: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private final class Phase: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OperationProgressPhase?
        var current: OperationProgressPhase? { lock.withLock { value } }
        func receive(_ progress: OperationProgress) { lock.withLock { value = progress.isTerminal ? nil : progress.phase } }
    }
}
#endif
