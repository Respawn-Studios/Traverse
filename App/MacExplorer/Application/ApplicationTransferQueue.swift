import AppKit
import Combine
import FileOperations
import LocalStorage

/// Session-only execution ownership. The value queue decides ordering; this
/// object retains observations, access and the worker until it has drained.
@MainActor
final class ApplicationTransferQueue: ObservableObject {
    @Published private(set) var revision = UUID()
    private unowned let coordinator: ApplicationOperationCoordinator
    private var queue = SerialTransferQueue(maximumOutstandingJobs: 16)
    private var jobs: [UUID: QueuedTransferJob] = [:]
    private var preparingAdmissions = Set<UUID>()
    private var worker: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var mailbox: OperationProgressMailbox?
    private var progressState = OperationProgressState()
    private(set) var activePresentation: OperationProgressPresentation?
    private(set) var results: [QueuedTransferResult] = []
    private(set) var reviewResultID: UUID?
    private let maximumRetainedSources = 4_096
    #if DEBUG
    var beforeAdmissionObservationReturnsForVerification: (@MainActor (UUID) async -> Void)?
    var progressForVerification: (@Sendable (OperationProgress) -> Void)?
    func copyExecutionForVerification(_ id: UUID) -> (request: CopyExecutionRequest, decision: TransferExecutionDecision?)? {
        guard let job = jobs[id] else { return nil }
        return (job.copyExecution, job.executionDecision)
    }
    #endif

    init(coordinator: ApplicationOperationCoordinator) { self.coordinator = coordinator }

    var state: SerialTransferQueue.State { queue.snapshot }
    var hasOutstandingWork: Bool { state.outstandingCount > 0 }
    var isIdleForCopyPreview: Bool { !hasOutstandingWork && preparingAdmissions.isEmpty && worker == nil && progressTask == nil }
    var isIdleForVolumeAction: Bool { state.active == nil && preparingAdmissions.isEmpty && worker == nil && progressTask == nil }
    func volumeJobs(affecting devices: Set<Int64>) -> [DriveJobSummary] {
        var summaries = jobs.values.filter { job in
            guard let observation = job.observation, observation.urls.contains(job.destination),
                  job.sources.allSatisfy({ observation.urls.contains($0) }) else { return true }
            return !observation.observedFileSystemIDs.isDisjoint(with: devices)
        }.map { DriveJobSummary(id: $0.id, title: $0.title, detail: $0.destination.path) }
        for id in preparingAdmissions where jobs[id] == nil {
            summaries.append(DriveJobSummary(id: id, title: "Finishing cancelled preparation", detail: "Waiting for its filesystem worker."))
        }
        return summaries.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    var canRunExclusiveCommand: Bool {
        coordinator.copyPreviewOwner == nil && state.active == nil && (state.waiting.isEmpty || state.isPaused)
    }
    var canAdmit: Bool { coordinator.volumeBarrierOwner == nil && coordinator.copyPreviewOwner == nil && coordinator.activeOwner == nil && coordinator.preparationOwner == nil && state.canReserve }
    var canResume: Bool {
        coordinator.copyPreviewOwner == nil && coordinator.activeOwner == nil && coordinator.preparationOwner == nil && state.active?.stopRequested != true
    }
    var canInspectResults: Bool { coordinator.copyPreviewOwner == nil && state.active == nil && coordinator.activeOwner == nil && coordinator.preparationOwner == nil }
    var canInspect: Bool { hasOutstandingWork || !results.isEmpty }
    var activeOrigin: BrowserViewController? { state.active.flatMap { jobs[$0.id]?.origin } }
    var reviewResult: QueuedTransferResult? { results.first { $0.id == reviewResultID } }
    var pausedSummary: String {
        if let id = reviewResultID, let result = results.first(where: { $0.id == id }) {
            return "Review: \(result.title) · \(OperationResultDescription(result: result.outcome.result).summary)"
        }
        return "The queue is paused. Resume when ready."
    }
    var presentation: OperationProgressPresentation? {
        if var current = activePresentation {
            let waiting = state.waiting.count
            var notes: [String] = []
            if reviewResult != nil { notes.append("Needs attention · queue paused") }
            if waiting > 0 { notes.append("\(waiting) waiting") }
            current.queueSummary = notes.isEmpty ? nil : notes.joined(separator: " · ")
            return current
        }
        guard hasOutstandingWork || (state.isPaused && !results.isEmpty) else { return nil }
        let preparing = state.waiting.first?.phase == .preparing
        let preparation = state.waiting.first.flatMap { jobs[$0.id]?.preparationStage }
        return OperationProgressPresentation(
            phaseTitle: reviewResult != nil ? "Needs attention" : (state.isPaused ? "Queue paused" : (preparing ? "Preparing" : "Waiting")),
            summary: state.isPaused ? pausedSummary
                : (preparing ? preparation?.message : nil) ?? "Waiting for this transfer's turn.",
            terminal: true, queueSummary: "\(state.waiting.count) waiting")
    }

    @discardableResult
    func enqueue(sources: [URL], destination: URL, move: Bool, title: String,
                 origin: BrowserViewController, engine: RecoverableFileOperations,
                 observation: FileOperationSelection? = nil,
                 retaining access: FileAccessLifetimes? = nil,
                 clipboard: MoveClipboardContext? = nil,
                 metadataPolicy: TransferMetadataPolicy, copyExecution: CopyExecutionRequest = .standard,
                 chooseMetadata: Bool = false,
                 duplicate: Bool = false,
                 requireVacantDestination: Bool = false,
                 validateAdmission: (@Sendable () async throws -> Void)? = nil) -> UUID? {
        guard canAdmit, !sources.isEmpty, sources.count <= 1_024,
              sources.allSatisfy({ $0.isFileURL }), destination.isFileURL,
              jobs.values.reduce(0, { $0 + $1.sources.count }) + sources.count <= maximumRetainedSources else { return nil }
        guard !duplicate || (!move && clipboard == nil && !chooseMetadata && metadataPolicy == .strict
            && copyExecution == .standard && sources.allSatisfy({ $0.deletingLastPathComponent() == destination })) else { return nil }
        guard (sources + [destination]).allSatisfy({ coordinator.drives.offlineVolume(containing: $0) == nil }) else {
            origin.status.stringValue = "A captured drive is unmounted or disconnected. Mount it before adding this transfer."
            return nil
        }
        let fullyObserved = observation.map { value in value.urls.contains(destination) && sources.allSatisfy { value.urls.contains($0) } } == true
        guard coordinator.drives.admitNewWork(fileSystemIDs: fullyObserved ? observation?.observedFileSystemIDs : nil) else {
            origin.status.stringValue = "Eject is pending. Cancel Eject in Drives before adding work on that device."
            return nil
        }
        let id = UUID()
        guard queue.reserve(id) else { return nil }
        let job = QueuedTransferJob(id: id, sources: sources, destination: destination,
            move: move, title: title, origin: origin, engine: engine, clipboard: clipboard,
            metadataPolicy: metadataPolicy, copyExecution: move ? .standard : copyExecution, observation: observation,
            access: access, duplicate: duplicate, requireVacantDestination: requireVacantDestination)
        jobs[id] = job
        recordQueue(job, phase: .admitted, checkpoint: .queueAdmission)
        changed()
        // Admission uses the independent local observation worker. The serial
        // recoverable mutation worker may be occupied by another transfer.
        let observer = origin.fileOperations
        let folderAccess = origin.folderAccess
        preparingAdmissions.insert(id)
        job.preparation = Task { [weak self, weak job, incomingAccess = job.access] in
            guard let self else { return }
            defer { self.preparingAdmissions.remove(id); self.changed() }
            guard let job else { return }
            defer { withExtendedLifetime(incomingAccess) {} }
            do {
                self.updatePreparation(job, stage: .access)
                let lease = await retainQueuedAccess(folderAccess, for: sources + [destination])
                defer { withExtendedLifetime(lease) {} }
                guard self.isWaiting(job), !Task.isCancelled else { return }
                job.access = FileAccessLifetimes(leases: (job.access?.leases ?? []) + lease.leases)
                if let validateAdmission {
                    try await validateAdmission()
                    guard self.isWaiting(job), !Task.isCancelled else { return }
                }
                let missingSources = sources.filter { job.observation?.urls.contains($0) != true }
                if !missingSources.isEmpty {
                    self.updatePreparation(job, stage: .sources)
                    let sourceObservation = try await observer.observeSelection(missingSources)
                    guard self.isWaiting(job), !Task.isCancelled else { return }
                    job.observation = job.observation.map { $0.combining(sourceObservation) } ?? sourceObservation
                }
                if job.observation?.urls.contains(destination) != true {
                    self.updatePreparation(job, stage: .destination)
                    let destinationObservation = try await observer.observeDirectory(destination)
                    guard self.isWaiting(job), !Task.isCancelled else { return }
                    job.observation = job.observation.map { $0.combining(destinationObservation) } ?? destinationObservation
                }
                #if DEBUG
                if let hook = self.beforeAdmissionObservationReturnsForVerification { await hook(id) }
                #endif
                job.chooseMetadata = chooseMetadata
                guard self.isWaiting(job), !Task.isCancelled, self.queue.markReady(id) else { return }
                self.recordQueue(job, phase: .waiting, checkpoint: .queueReady)
                job.preparation = nil
                self.changed()
                self.startIfPossible()
            } catch {
                guard self.isWaiting(job), !Task.isCancelled else { return }
                self.failAdmission(job, error: error)
            }
        }
        return id
    }

    private func updatePreparation(_ job: QueuedTransferJob, stage: QueuedTransferPreparation) {
        job.preparationStage = stage
        recordQueue(job, phase: stage.diagnosticPhase, checkpoint: stage.checkpoint)
        changed()
    }

    private func recordQueue(_ job: QueuedTransferJob, phase: DiagnosticPhase, checkpoint: DiagnosticCheckpoint) {
        var flags: [DiagnosticStateFlag] = []
        if state.isPaused { flags.append(.paused) }
        if state.active != nil { flags.append(.activeTransfer) }
        if coordinator.activeOwner != nil { flags.append(.exclusiveOperation) }
        if coordinator.preparationOwner != nil { flags.append(.exclusivePreparation) }
        if coordinator.volumeBarrierOwner != nil { flags.append(.volumeBarrier) }
        if coordinator.copyPreviewOwner != nil { flags.append(.copyPreview) }
        if job.sources.allSatisfy({ job.observation?.urls.contains($0) == true }) { flags.append(.sourceObserved) }
        if job.observation?.urls.contains(job.destination) == true { flags.append(.destinationObserved) }
        if job.access != nil { flags.append(.retainedScope) }
        ApplicationDiagnostics.shared.event(.queue, phase, trace: job.diagnosticTrace, count: UInt64(job.sources.count),
            context: .init(checkpoint, flags: flags, queueDepth: state.waiting.count, preparingAdmissions: preparingAdmissions.count))
    }

    @discardableResult
    func cancelWaiting(_ id: UUID) -> Bool {
        guard queue.cancelWaiting(id), let job = jobs.removeValue(forKey: id) else { return false }
        ApplicationDiagnostics.shared.event(.queue, .cancelled, trace: job.diagnosticTrace)
        job.preparation?.cancel()
        job.preparation = nil
        job.access = nil
        changed()
        startIfPossible()
        return true
    }

    func cancelAllWaiting() {
        for entry in state.waiting {
            guard queue.cancelWaiting(entry.id), let job = jobs.removeValue(forKey: entry.id) else { continue }
            job.preparation?.cancel(); job.preparation = nil; job.access = nil
        }
        changed()
    }

    func pause() { queue.pause(); changed() }

    @discardableResult
    func moveWaiting(_ id: UUID, offset: Int, expectedOrder: [UUID]) -> Bool {
        guard jobs[id] != nil, queue.moveWaiting(id, offset: offset, expectedOrder: expectedOrder) else { return false }
        changed(); startIfPossible(); return true
    }

    @discardableResult
    func resume() -> Bool {
        guard canResume, queue.resume() else { return false }
        reviewResultID = nil
        changed()
        startIfPossible()
        return true
    }

    @discardableResult
    func stopActive(expectedID: UUID? = nil) -> Bool {
        guard let id = state.active?.id, expectedID == nil || expectedID == id, queue.requestStop(id) else { return false }
        ApplicationDiagnostics.shared.event(.queue, .draining, trace: jobs[id]?.diagnosticTrace)
        activePresentation?.stopping = true
        activePresentation?.phaseTitle = "Stopping"
        activePresentation?.summary = "Stopping — finishing the current safe step. The queue is paused."
        changed()
        jobs[id]?.prompt.cancel()
        worker?.cancel()
        return true
    }

    func startIfPossible() {
        guard coordinator.volumeBarrierOwner == nil, coordinator.copyPreviewOwner == nil, coordinator.activeOwner == nil, coordinator.preparationOwner == nil, worker == nil,
              let id = queue.startNext(), let job = jobs[id], let observation = job.observation else { return }
        recordQueue(job, phase: .dispatched, checkpoint: .queueStart)
        progressState = OperationProgressState()
        activePresentation = OperationProgressPresentation(phaseTitle: "Planning", summary: job.title,
            sourcePath: job.sources.count == 1 ? job.sources.first?.path : "\(job.sources.count) captured items",
            destinationPath: job.destination.path)
        let mailbox = OperationProgressMailbox()
        self.mailbox = mailbox
        progressTask = Task { [weak self] in
            for await update in mailbox.stream {
                guard let self, self.state.active?.id == id else { break }
                if let value = self.progressState.receive(update, stopping: self.state.active?.stopRequested == true) {
                    self.activePresentation = value
                    self.updateDock(job)
                    self.changed()
                }
            }
        }
        changed()
        let diagnosticBinding = ApplicationDiagnostics.shared.operationBinding(trace: job.diagnosticTrace)
        worker = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            let verificationSink = self.progressForVerification
            let sink: @Sendable (OperationProgress) -> Void = { diagnosticBinding.receive($0.jobID); mailbox.send($0); verificationSink?($0) }
            #else
            let sink: @Sendable (OperationProgress) -> Void = { diagnosticBinding.receive($0.jobID); mailbox.send($0) }
            #endif
            var names: PrivateMoveBatch?
            do {
                if job.chooseMetadata {
                    job.isAwaitingChoices = true
                    self.changed()
                    let policy: TransferMetadataPolicy?
                    if let prompt = job.metadataPrompt { policy = await prompt(job.metadataPolicy) }
                    else if let window = job.window {
                        let (alert, values) = makeTransferOptionsAlert(metadata: job.metadataPolicy, conflicts: job.conflictPreferences)
                        if try await job.prompt.present(alert, in: window) == .alertFirstButtonReturn {
                            let selected = values(); policy = selected.0; job.conflictPreferences = selected.1
                        } else { policy = nil }
                    } else { throw FileOperationFailure.unavailable }
                    job.isAwaitingChoices = false
                    guard !Task.isCancelled, let policy else { self.complete(job, outcome: self.stopped(job)); return }
                    job.metadataPolicy = policy
                }
                try Task.checkCancellation()
                self.recordQueue(job, phase: .preparing, checkpoint: .queuePlan)
                let plan = try await job.engine.prepareTransfer(sources: job.sources,
                    destinationDirectory: job.destination, move: job.move, observing: observation,
                    metadataPolicy: job.metadataPolicy, copyExecution: job.copyExecution,
                    requireVacantDestination: job.requireVacantDestination, progress: sink)
                job.executionDecision = plan.executionDecision
                self.changed()
                if job.move, let clipboard = job.clipboard {
                    // Clipboard URLs preserve a browsed alias, while guarded
                    // engine outcomes use physical source paths. Keep the native
                    // generation/references and use only the validated plan for
                    // deciding whether that captured Move was fully consumed.
                    job.clipboard = MoveClipboardContext(changeCount: clipboard.changeCount,
                        sources: clipboard.sources, operationSources: plan.sources, revision: clipboard.revision)
                }
                var choices: [UUID: TransferConflictResolution] = [:]
                let conflictChoices = job.duplicate ? (automatic: try DuplicateChoices.resolutions(for: plan), asking: [])
                    : job.conflictPreferences.choices(for: plan.conflicts)
                choices = conflictChoices.automatic
                if !conflictChoices.asking.isEmpty {
                    guard !Task.isCancelled else { self.complete(job, outcome: self.stopped(job)); return }
                    job.isAwaitingChoices = true
                    self.changed()
                    let answer: [UUID: TransferConflictResolution]?
                    if let prompt = job.conflictPrompt { answer = await prompt(conflictChoices.asking) }
                    else if let window = job.window {
                        let (alert, resolutions) = makeTransferConflictAlert(conflictChoices.asking)
                        answer = try await job.prompt.present(alert, in: window) == .alertFirstButtonReturn ? resolutions() : nil
                    } else { throw FileOperationFailure.unavailable }
                    job.isAwaitingChoices = false
                    guard !Task.isCancelled, let answer else { self.complete(job, outcome: self.stopped(job)); return }
                    choices.merge(answer) { _, explicit in explicit }
                }
                guard !Task.isCancelled else { self.complete(job, outcome: self.stopped(job)); return }
                self.recordQueue(job, phase: .preparing, checkpoint: .queueStatePreparation)
                try await self.coordinator.prepareOperationState(for: job.engine)
                try Task.checkCancellation()
                names = await job.privateNames.prepareMoveNames(plan: plan, choices: choices, engine: job.engine)
                try Task.checkCancellation()
                self.recordQueue(job, phase: .transferring, checkpoint: .queueMutation)
                let outcome = await job.engine.perform(names?.plan ?? plan, resolutions: choices, progress: sink)
                await job.privateNames.finishMoveNames(names, engine: job.engine, result: outcome)
                // Terminal progress is presentation only. This point is reached
                // only after the serial engine has returned and drained.
                self.complete(job, outcome: outcome)
            } catch {
                await job.privateNames.finishMoveNames(names, engine: job.engine)
                ApplicationDiagnostics.shared.event(.queue, error is CancellationError ? .cancelled : .failed,
                    trace: job.diagnosticTrace, error: DiagnosticErrors.project(error),
                    context: .init(.queueTerminal), causes: DiagnosticErrors.causes(error))
                if let stateError = error as? StateDirectoryPreparationError { job.preparationMessage = stateError.errorDescription }
                let outcome = Task.isCancelled || error is CancellationError ? self.stopped(job)
                    : self.failed(job, error: error)
                self.complete(job, outcome: outcome)
            }
        }
    }

    private func complete(_ job: QueuedTransferJob, outcome: RecoverableOperationResult) {
        guard state.active?.id == job.id, jobs[job.id] === job else { return }
        let wasStopped = state.active?.stopRequested == true || outcome.result.cancellationRequested
        let disposition: SerialTransferQueue.Disposition = wasStopped ? .cancelled
            : (outcome.result.disposition == .succeeded ? .succeeded : .needsReview)
        guard queue.finish(job.id, disposition: disposition) else { return }
        if disposition != .succeeded, reviewResultID == nil { reviewResultID = job.id }
        mailbox?.finish(); mailbox = nil
        progressTask?.cancel(); progressTask = nil
        activePresentation = nil
        worker = nil
        coordinator.dock.restore()
        jobs.removeValue(forKey: job.id)
        job.access = nil
        record(job, outcome: outcome)
        job.clipboardState.consumeCompletedMove(job.clipboard, after: outcome.result)
        changed()
        var refreshed: BrowserViewController?
        if let origin = job.origin, !origin.isBrowserSuspended,
           origin.activeID == job.tabID, origin.sessionID == job.visitID, origin.location.directoryURL != nil {
            let destinations = outcome.result.items.compactMap { $0.status == .succeeded ? $0.destination : nil }
            let visibleDestinations = destinations.filter { $0.deletingLastPathComponent().path == origin.location.directoryURL?.path }
            origin.saveViewState()
            if !visibleDestinations.isEmpty { origin.tabs[origin.activeIndex].state.selection = Set(visibleDestinations) }
            origin.loadLocation(preservingVisibleRows: true)
            refreshed = origin
        }
        coordinator.reloadLocalDirectories(affectedBy: outcome.result, includingSources: job.move, excluding: refreshed)
        let host = promptBrowser(for: job)
        if state.waiting.isEmpty || state.isPaused {
            if let workspace = host?.workspace { workspace.refreshRecoveryViews() }
            else { host?.inspectOperationRecovery() }
        }
        host?.presentQueuedTransferResult(job.id)
        startIfPossible()
    }

    private func failAdmission(_ job: QueuedTransferJob, error: Error) {
        guard queue.cancelWaiting(job.id), jobs.removeValue(forKey: job.id) != nil else { return }
        queue.pause()
        if reviewResultID == nil { reviewResultID = job.id }
        job.preparation = nil
        job.access = nil
        let outcome = failed(job, error: error)
        record(job, outcome: outcome)
        changed()
        promptBrowser(for: job)?.presentQueuedTransferResult(job.id)
    }

    private func record(_ job: QueuedTransferJob, outcome: RecoverableOperationResult) {
        recordQueue(job, phase: .finished, checkpoint: .queueTerminal)
        ApplicationDiagnostics.shared.recordOperationResult(outcome.result, trace: job.diagnosticTrace)
        job.history.lastResult = outcome.result
        job.history.diagnosticTrace = job.diagnosticTrace
        job.history.continuation = outcome.continuation
        job.history.moveClipboard = job.clipboard
        job.history.recoveryRecordID = outcome.recordID
        results.append(QueuedTransferResult(id: job.id, title: job.title, sources: job.sources,
            destination: job.destination, originDescription: job.originDescription,
            outcome: outcome, clipboard: job.clipboard, engine: job.engine,
            copyExecution: job.copyExecution, executionDecision: job.executionDecision,
            preparationMessage: job.preparationMessage, diagnosticTrace: job.diagnosticTrace))
        // Keep recent per-job results without retaining unbounded path arrays.
        while results.count > 16 || (results.count > 1 && results.reduce(0, { $0 + $1.outcome.result.items.count }) > 32_768) {
            guard let index = results.firstIndex(where: { $0.id != reviewResultID }) else { break }
            results.remove(at: index)
        }
    }

    private func failed(_ job: QueuedTransferJob, error: Error) -> RecoverableOperationResult {
        let failure = error as? FileOperationFailure ?? .ioFailure
        return RecoverableOperationResult(result: FileOperationResult(items:
            job.sources.map { FileOperationOutcome(source: $0,
                destination: job.destination.appendingPathComponent($0.lastPathComponent), status: .notStarted, recoveryURLs: []) }
            + [FileOperationOutcome(source: nil, destination: job.destination,
                status: .failed(failure), recoveryURLs: [], role: .job)], cancellationRequested: false), recordID: nil)
    }

    private func stopped(_ job: QueuedTransferJob) -> RecoverableOperationResult {
        RecoverableOperationResult(result: FileOperationResult(items: job.sources.map {
            FileOperationOutcome(source: $0, destination: job.destination.appendingPathComponent($0.lastPathComponent),
                status: .notStarted, recoveryURLs: [])
        }, cancellationRequested: true), recordID: nil)
    }

    private func isWaiting(_ job: QueuedTransferJob) -> Bool {
        jobs[job.id] === job && state.waiting.contains { $0.id == job.id }
    }

    private func promptBrowser(for job: QueuedTransferJob) -> BrowserViewController? {
        if let origin = job.origin, !origin.isBrowserSuspended { return origin }
        guard let host = (job.window as? BrowserWindow)?.workspace?.activeBrowser, !host.isBrowserSuspended else { return nil }
        return host
    }

    private func updateDock(_ job: QueuedTransferJob) {
        if let activePresentation {
            coordinator.dock.update(activePresentation, enabled: job.settings.showsDockProgress && !job.isVerification)
        }
    }

    private func changed() { revision = UUID(); coordinator.drives.workDidChange() }

    func waitingDescription(_ id: UUID) -> (title: String, detail: String)? {
        guard let job = jobs[id] else { return nil }
        let verb = job.move ? "Move" : "Copy"
        let item = job.sources.count == 1 ? job.sources[0].lastPathComponent : "\(job.sources.count) items"
        return ("\(verb) \(item)", "\(copyExecutionDescription(request: job.copyExecution, decision: job.executionDecision)) · \(job.destination.path)")
    }

    func showResult(_ id: UUID, in browser: BrowserViewController) {
        guard let result = results.first(where: { $0.id == id }), !browser.isBrowserSuspended,
              canInspectResults, browser.view.window?.attachedSheet == nil else { return }
        browser.lastOperationResult = result.outcome.result
        browser.lastTransferContinuation = result.engine === browser.recoverableFileOperations ? result.outcome.continuation : nil
        browser.continuationMoveClipboard = result.clipboard
        browser.lastRecoveryRecordID = result.outcome.recordID
        browser.showOperationResultSheet(result.outcome.result, queuedResult: result)
    }
}

/// Preparation is observational. A slow OS/disk request remains cancellable
/// without releasing its access or admitting file changes before it drains.
private enum QueuedTransferPreparation {
    case access, sources, destination
    var diagnosticPhase: LocalStorage.DiagnosticPhase {
        switch self { case .access: .resolving; case .sources: .preparing; case .destination: .verifying }
    }
    var checkpoint: DiagnosticCheckpoint {
        switch self { case .access: .queueAccess; case .sources: .queueSources; case .destination: .queueDestination }
    }
    var message: String {
        let step: String
        switch self {
        case .access: step = "Checking selected folder access with macOS."
        case .sources: step = "Checking source files before this transfer starts."
        case .destination: step = "Checking the destination folder before this transfer starts."
        }
        return step + " If macOS or the disk is busy, you can cancel this waiting transfer from Queue."
    }
}

@MainActor
private final class QueuedTransferJob {
    let id: UUID
    let diagnosticTrace: UUID
    let sources: [URL]
    let destination: URL
    let move: Bool
    let duplicate: Bool
    let requireVacantDestination: Bool
    let title: String
    let originDescription: String
    weak var origin: BrowserViewController?
    weak var window: NSWindow?
    let tabID: UUID
    let visitID: UUID
    let engine: RecoverableFileOperations
    let history: BrowserOperationHistory
    let clipboardState: BrowserClipboardState
    var clipboard: MoveClipboardContext?
    let settings: BrowserSettings
    let privateNames: ApplicationPrivateNames
    var conflictPreferences: TransferConflictPreferences
    let isVerification: Bool
    let conflictPrompt: (([TransferConflict]) async -> [UUID: TransferConflictResolution]?)?
    let metadataPrompt: ((TransferMetadataPolicy) async -> TransferMetadataPolicy?)?
    let prompt = TransferQueuePrompt()
    var metadataPolicy: TransferMetadataPolicy
    let copyExecution: CopyExecutionRequest
    var executionDecision: TransferExecutionDecision?
    var observation: FileOperationSelection?
    var access: FileAccessLifetimes?
    var preparation: Task<Void, Never>?
    fileprivate var preparationStage = QueuedTransferPreparation.access
    var preparationMessage: String?
    var isAwaitingChoices = false
    var chooseMetadata = false

    init(id: UUID, sources: [URL], destination: URL, move: Bool, title: String,
         origin: BrowserViewController, engine: RecoverableFileOperations, clipboard: MoveClipboardContext?,
         metadataPolicy: TransferMetadataPolicy, copyExecution: CopyExecutionRequest,
         observation: FileOperationSelection?, access: FileAccessLifetimes?, duplicate: Bool, requireVacantDestination: Bool) {
        diagnosticTrace = ApplicationDiagnostics.shared.currentTrace ?? ApplicationDiagnostics.shared.begin(move ? .move : .copy)
        self.id = id; self.sources = sources; self.destination = destination; self.move = move; self.title = title
        self.duplicate = duplicate
        self.requireVacantDestination = requireVacantDestination
        // Paste is invoked from the destination pane. Its current folder is
        // not evidence of where the captured clipboard sources came from.
        let parents = Set(sources.map { $0.deletingLastPathComponent() })
        if parents.count == 1, let parent = parents.first {
            originDescription = parent.path == "/" ? "/" : parent.lastPathComponent
        } else { originDescription = "\(parents.count) source folders" }
        self.origin = origin; window = origin.view.window; tabID = origin.activeID; visitID = origin.sessionID
        self.engine = engine; history = origin.operationHistory; clipboardState = origin.clipboardState
        self.clipboard = clipboard; settings = origin.settings; isVerification = origin.isVerificationSession
        privateNames = origin.privateNames
        conflictPreferences = origin.settings.conflictPreferences
        conflictPrompt = origin.transferConflictPrompt; metadataPrompt = origin.transferMetadataPrompt
        self.metadataPolicy = metadataPolicy
        self.copyExecution = copyExecution
        self.observation = observation; self.access = access
    }
}

struct QueuedTransferResult: Identifiable {
    let id: UUID
    let title: String
    let sources: [URL]
    let destination: URL
    let originDescription: String
    let outcome: RecoverableOperationResult
    let clipboard: MoveClipboardContext?
    let engine: RecoverableFileOperations
    let copyExecution: CopyExecutionRequest
    let executionDecision: TransferExecutionDecision?
    var preparationMessage: String? = nil
    var diagnosticTrace: UUID? = nil

    var contextDescription: String {
        let source = sources.count == 1 ? sources[0].path : "\(sources.count) captured sources"
        let preparation = preparationMessage.map { "\n\($0)" } ?? ""
        return "\(title) · From \(originDescription)\n\(copyExecutionDescription(request: copyExecution, decision: executionDecision, completed: true))\(preparation)\nSource: \(source)\nDestination: \(destination.path)"
    }
}

func copyExecutionDescription(request: CopyExecutionRequest, decision: TransferExecutionDecision?, completed: Bool = false) -> String {
    guard let decision else {
        if completed { return request == .previewIfAvailable ? "Preview requested · no execution path selected" : "Standard transfer · preparation did not finish" }
        return request == .previewIfAvailable ? "Preview requested · checking eligibility" : "Standard transfer"
    }
    switch decision {
    case .groupedCopy(let maximum): return "Preview Copy · up to \(maximum) files per group"
    case .standard(let reason):
        switch reason {
        case .previewOff: return "Standard transfer"
        case .qualificationPending: return "Standard Copy · preview qualification pending"
        case .move: return "Standard Move"
        case .unsupportedInput: return "Standard Copy · this job contains unsupported preview items"
        case .destinationConflict: return "Standard Copy · destination choices required"
        case .unqualifiedLocation: return "Standard Copy · preview unavailable for this job"
        case .continuation: return "Standard Copy · continuing known remaining items"
        case .outsidePreviewLimits: return "Standard Copy · outside preview eligibility"
        case .historyUnavailable: return "Standard Copy · preview history unavailable"
        }
    }
}

@MainActor
private func retainQueuedAccess(_ controller: FolderAccessController, for urls: [URL]) async -> FileAccessLifetimes {
    var leases: [FolderAccessLease] = []
    for url in urls {
        guard !Task.isCancelled else { break }
        if leases.contains(where: { url.path == $0.url.path || url.path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }) { continue }
        if let lease = await controller.acquireAccess(to: url) { leases.append(lease) }
    }
    return FileAccessLifetimes(leases: leases)
}
