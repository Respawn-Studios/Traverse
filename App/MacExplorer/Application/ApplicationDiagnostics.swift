import AppKit
import Combine
import ExplorerCore
import LocalStorage
import FileOperations

private enum DiagnosticTaskTrace {
    @TaskLocal static var current: UUID?
}

/// Observes only the finite app command vocabulary. It never intercepts text,
/// keystrokes, mouse coordinates, clipboard values or password-field contents.
@objc(TraverseApplication)
@MainActor final class TraverseApplication: NSApplication {
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        let owner = ApplicationDiagnostics.shared
        guard owner.recorder?.status.recording == true else { return super.sendAction(action, to: target, from: sender) }
        let command: BrowserCommand?
        if let item = sender as? NSMenuItem { command = BrowserCommand.command(for: item) }
        else {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = (sender as? NSControl)?.tag ?? 0
            command = BrowserCommand.command(for: item)
        }
        let observesControl = sender is NSMenuItem || sender is NSButton || sender is NSSegmentedControl || sender is NSPopUpButton
        let trace = command != nil || observesControl ? owner.begin(command == nil ? .control : .browse, command: command) : nil
        let snapshot = command == nil ? nil : owner.dispatchSnapshot((target as? BrowserViewController) ?? (keyWindow as? BrowserWindow)?.browser)
        let pushed = trace.map { owner.push($0) } ?? false
        defer { if pushed { owner.pop() } }
        let dispatched: Bool
        if let trace, pushed {
            // Tasks created by an action keep only its opaque ID after the
            // synchronous responder stack has unwound. Interleaved actions
            // cannot borrow each other's trace or workflow inputs.
            dispatched = DiagnosticTaskTrace.$current.withValue(trace) { super.sendAction(action, to: target, from: sender) }
        } else { dispatched = super.sendAction(action, to: target, from: sender) }
        if let trace { owner.event(command == nil ? .control : .browse, dispatched ? .dispatched : .blocked, trace: trace, command: command, context: snapshot) }
        return dispatched
    }
}

@MainActor final class ApplicationDiagnostics {
    static let shared = ApplicationDiagnostics()
    let session = UUID()
    private(set) var recorder: DiagnosticRecorder?
    private var preference: AnyCancellable?
    private var stack: [UUID] = []
    private var commands: [UUID: BrowserCommand] = [:]
    private var build: DiagnosticBuild?
    private var runtime: DiagnosticRuntime?
    var exportMetadata: DiagnosticExportMetadata? {
        runtime.map { .init(build: build, runtime: $0) }
    }
    var currentTrace: UUID? { stack.last ?? DiagnosticTaskTrace.current }

    func dispatchSnapshot(_ browser: BrowserViewController?) -> DiagnosticContext? {
        guard let browser else { return nil }
        let coordinator = browser.operationCoordinator, queue = coordinator.transfers
        var flags: [DiagnosticStateFlag] = []
        if browser.isBrowserSuspended { flags.append(.browserSuspended) }
        if browser.isLoading { flags.append(.browserLoading) }
        if browser.view.window?.isKeyWindow != true { flags.append(.windowNotKey) }
        if browser.metadataSearch.isShowingResults { flags.append(.searchResults) }
        if browser.summaryBrowsingAccess != nil { flags.append(.retainedScope) }
        if queue.state.isPaused { flags.append(.paused) }
        if queue.state.active != nil { flags.append(.activeTransfer) }
        if coordinator.activeOwner != nil { flags.append(.exclusiveOperation) }
        if coordinator.preparationOwner != nil { flags.append(.exclusivePreparation) }
        if coordinator.copyPreviewOwner != nil { flags.append(.copyPreview) }
        if coordinator.volumeBarrierOwner != nil { flags.append(.volumeBarrier) }
        return .init(.commandDispatch, flags: flags, queueDepth: queue.state.waiting.count)
    }

    func start(settings: BrowserSettings, layout: ApplicationStorageLayout? = AppStorageLocations.layout,
               limits requestedLimits: DiagnosticHistoryLimits? = nil) {
        guard recorder == nil, let layout,
              let limits = requestedLimits ?? (try? DiagnosticHistoryLimits()),
              let preparation = try? AppStoragePreparation.owner(for: layout.cacheDirectory) else { return }
        build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(UInt64.init)
            .flatMap { try? DiagnosticBuild(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", number: $0) }
        let service = DiagnosticRecorder(directory: layout.cacheDirectory.appendingPathComponent("diagnostic-history-v1", isDirectory: true),
            limits: limits, recording: settings.diagnosticHistoryEnabled,
            prepare: { try preparation.prepareFromBackgroundThread() })
        recorder = service
        installOperationObserver(service)
        preference = settings.$diagnosticHistoryEnabled.dropFirst().sink { [weak self, weak service] enabled in
            if !enabled { self?.event(.diagnostics, .paused) }
            service?.setRecording(enabled)
            if enabled { self?.event(.diagnostics, .resumed) }
        }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let channel = Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String
        #if arch(arm64)
        let architecture = DiagnosticRuntime.Architecture.arm64
        #elseif arch(x86_64)
        let architecture = DiagnosticRuntime.Architecture.x86_64
        #else
        let architecture = DiagnosticRuntime.Architecture.unknown
        #endif
        let runtime = DiagnosticRuntime(osMajor: system.majorVersion,
            osMinor: system.minorVersion, osPatch: system.patchVersion, architecture: architecture,
            edition: channel == "developer-id" ? .developerID : (channel == "app-store" ? .appStore : .development),
            processID: ProcessInfo.processInfo.processIdentifier)
        self.runtime = runtime
        event(.application, .admitted, context: .init(.launch), runtime: runtime)
    }

    private func installOperationObserver(_ service: DiagnosticRecorder) {
        let session = self.session, build = self.build
        FileOperationDiagnostics.install { [weak service] stage in
            var familyFlags: [DiagnosticStateFlag] = []
            if let finding = stage.nativeTrashFinding {
                switch finding {
                case .complete(let nativeChanged, let osAccessAttributeChanged):
                    familyFlags = nativeChanged.map { family in
                        switch family {
                        case .rootObject: .nativeTrashRootObject
                        case .entryMetadata: .nativeTrashEntryMetadata
                        case .linkStructure: .nativeTrashLinkStructure
                        case .content: .nativeTrashContent
                        case .acl: .nativeTrashACL
                        case .quarantine: .nativeTrashQuarantine
                        case .provenance: .nativeTrashProvenance
                        case .finderInfo: .nativeTrashFinderInfo
                        case .otherXattrs: .nativeTrashOtherXattrs
                        }
                    }
                    if osAccessAttributeChanged { familyFlags.append(.nativeTrashOSAccessChanged) }
                case .unavailable: familyFlags = [.nativeTrashFamilyUnavailable]
                }
            }
            if let failure = stage.failure {
                let checkpoint: DiagnosticContext?
                switch stage.checkpoint {
                case .textRecordStart?: checkpoint = .init(.textRecordStart)
                case .textRecordAdmission?: checkpoint = .init(.textRecordAdmission)
                case .textRecordProjection?: checkpoint = .init(.textRecordProjection)
                case .textManifestLocation?, .textManifestArea?, .textManifestBinding?,
                     .textManifestSlot?, .textManifestRead?, .textManifestBaseline?:
                    checkpoint = .init(.textRecordProjection)
                case .textRecordHead?: checkpoint = .init(.textRecordHead)
                case .textRecordTransaction?: checkpoint = .init(.textRecordTransaction)
                case .textRecordSQLite?: checkpoint = .init(.textRecordSQLite)
                case .nativeTrashReturnedParent?, .nativeTrashReturnedIdentity?, .nativeTrashTreeRead?,
                     .nativeTrashParentValidation?, .nativeTrashFingerprint?,
                     .nativeTrashInversePreflight?, .nativeTrashInversePostWalk?,
                     .nativeTrashInverseTransition?, .nativeTrashInverseSync?,
                     .nativeTrashInverseJournal?, .nativeTrashInverseObservedChange?,
                     .nativeTrashDeletePreflight?, .nativeTrashDeleteStageRename?,
                     .nativeTrashDeleteStagePostWalk?, .nativeTrashDeleteStageTransition?,
                     .nativeTrashDeleteStageJournal?, .nativeTrashDeleteUnlink?:
                    checkpoint = .init(.nativeStatus, flags: familyFlags)
                case .copyMetadataComparison?, .copyReceiptCardinality?, .copyReceiptValidation?,
                     .downloadStageMark?, .downloadTransitionShape?, .downloadSourceMark?,
                     .downloadSourceProvenance?, .downloadStageProvenance?, .downloadMarkReplace?,
                     .downloadStageRecheck?, .downloadSourceRecheck?, .downloadProvenanceRecheck?,
                     .downloadAdoptionPathBinding?, .downloadAdoptionRawQuarantine?, .downloadAdoptionProvenance?,
                     .downloadAdoptionPublicProperties?, .downloadAdoptionAdmission?, .downloadAdoptionArea?,
                     .downloadAdoptionIntent?, .downloadAdoptionMove?, .downloadAdoptionStage?,
                     .downloadAdoptionPublication?, .downloadAdoptionCommit?:
                    checkpoint = .init(.nativeStatus)
                case nil: checkpoint = nil
                }
                let phase: DiagnosticPhase
                if case .cancelled = failure { phase = .cancelled } else { phase = .failed }
                let caught = DiagnosticErrors.operationCaughtFailure(failure)
                let boundary = DiagnosticErrors.operationBoundary(stage.checkpoint)
                service?.record(.init(session: session, trace: stage.jobID, action: .fileOperation,
                    phase: phase, level: .warning, error: boundary ?? caught,
                    build: build, ordinal: stage.ordinal, relatedTrace: stage.recordID,
                    context: checkpoint, causes: boundary == nil ? nil : [caught]))
                return
            }
            if stage.success == true, stage.checkpoint == .nativeTrashInverseObservedChange {
                service?.record(.init(session: session, trace: stage.jobID, action: .fileOperation,
                    phase: .verifying, level: .information,
                    error: DiagnosticErrors.operationBoundary(stage.checkpoint),
                    build: build, ordinal: stage.ordinal, relatedTrace: stage.recordID,
                    context: .init(.nativeStatus, flags: familyFlags)))
                return
            }
            let phase: DiagnosticPhase
            switch stage.phase {
            case .planning: phase = .preparing
            case .copying: phase = .transferring
            case .verifying: phase = .verifying
            case .publishing, .syncing: phase = .committing
            case .retaining: phase = .retaining
            case .stopping: phase = .draining
            case .completed: phase = stage.success == true ? .completed : .finished
            }
            service?.record(.init(session: session, trace: stage.jobID, action: .fileOperation, phase: phase,
                level: stage.success == false ? .warning : .information,
                error: stage.nativeError.map { .init(domain: .posix, code: Int64($0)) }, build: build, ordinal: stage.ordinal,
                relatedTrace: stage.recordID,
                context: stage.nativeError == nil ? nil : .init(.nativeStatus)))
        }
    }

    #if DEBUG
    func configureForVerification(_ service: DiagnosticRecorder?) {
        preference?.cancel(); preference = nil; recorder = service
        FileOperationDiagnostics.install(nil)
        if let service { installOperationObserver(service) }
    }
    #endif

    @discardableResult func begin(_ action: DiagnosticAction, command: BrowserCommand? = nil) -> UUID {
        let trace = UUID()
        if let command {
            if commands.count >= 256 { commands.removeAll(keepingCapacity: true) }
            commands[trace] = command
        }
        event(action, .requested, trace: trace, command: command)
        return trace
    }
    /// One fixed metadata checkpoint; query text, selections and remote names
    /// never enter this trace. The operation retains its existing async owner.
    func remoteMetadata<T: Sendable>(_ checkpoint: DiagnosticCheckpoint,
                                    count: (T) -> UInt64? = { _ in nil },
                                    operation: () async throws -> T) async throws -> T {
        let trace = begin(.remoteBrowse), began = ProcessInfo.processInfo.systemUptime
        event(.remoteBrowse, .reading, trace: trace, context: .init(checkpoint))
        do {
            let value = try await operation()
            event(.remoteBrowse, .completed, trace: trace, count: count(value),
                duration: DiagnosticErrors.milliseconds(ProcessInfo.processInfo.systemUptime - began), context: .init(checkpoint))
            return value
        } catch {
            event(.remoteBrowse, error is CancellationError ? .cancelled : .failed, trace: trace,
                duration: DiagnosticErrors.milliseconds(ProcessInfo.processInfo.systemUptime - began),
                error: DiagnosticErrors.remoteMetadata(error) ?? DiagnosticErrors.project(error), context: .init(checkpoint))
            throw error
        }
    }
    @discardableResult func push(_ trace: UUID) -> Bool {
        guard stack.count < 16 else { return false }
        stack.append(trace); return true
    }
    func pop() { if !stack.isEmpty { stack.removeLast() } }
    func event(_ action: DiagnosticAction, _ phase: DiagnosticPhase, trace: UUID? = nil,
               command: BrowserCommand? = nil, level: DiagnosticLevel? = nil,
               count: UInt64? = nil, duration: UInt64? = nil, error: DiagnosticErrorCode? = nil,
               context: DiagnosticContext? = nil, causes: [DiagnosticErrorCode]? = nil, runtime: DiagnosticRuntime? = nil,
               relatedTrace: UUID? = nil) {
        let correlation = trace ?? currentTrace ?? UUID()
        recorder?.record(.init(session: session, trace: correlation, action: action, phase: phase,
            level: level ?? (phase == .failed ? .error : [.blocked,.interrupted,.partial,.gap].contains(phase) ? .warning : .information),
            count: count, durationMilliseconds: duration, error: error, build: build,
            command: command ?? commands[correlation], relatedTrace: relatedTrace, context: context, causes: causes, runtime: runtime))
    }
    func flush() async { await recorder?.flush() }
    /// Wrap an app-owned workflow without giving diagnostics its inputs or
    /// output. Only the closed action/result/error projection is observable.
    func perform<T>(_ action: DiagnosticAction, outcome: (T) -> DiagnosticPhase = { _ in .completed },
                    failure: (T) -> DiagnosticErrorCode? = { _ in nil },
                    operation: () async throws -> T) async rethrows -> T {
        let trace = begin(action), began = ContinuousClock.now
        event(action, .preparing, trace: trace)
        do {
            let result = try await operation()
            let elapsed = began.duration(to: .now).components
            let milliseconds = UInt64(max(0, elapsed.seconds)) * 1000 + UInt64(max(0, elapsed.attoseconds / 1_000_000_000_000_000))
            event(action, outcome(result), trace: trace, duration: milliseconds, error: failure(result))
            return result
        } catch {
            event(action, error is CancellationError ? .cancelled : .failed, trace: trace, error: DiagnosticErrors.project(error))
            throw error
        }
    }
    func operationBinding(trace: UUID) -> DiagnosticJobBinding {
        DiagnosticJobBinding(recorder: recorder, session: session, build: build, trace: trace)
    }
    /// Snapshot the recorder before entering a serial filesystem worker. The
    /// binding accepts only closed metadata and never retains workflow inputs.
    func workflow(_ action: DiagnosticAction, trace: UUID? = nil, context: DiagnosticContext) -> DiagnosticWorkflowBinding {
        let binding = DiagnosticWorkflowBinding(recorder: recorder, session: session, build: build,
            trace: trace ?? currentTrace ?? UUID(), action: action)
        binding.event(.requested, context: context)
        return binding
    }
    func closeAndDrain() async {
        event(.shutdown, .completed)
        FileOperationDiagnostics.install(nil)
        await recorder?.closeAndDrain(); recorder = nil
        preference?.cancel(); preference = nil
    }
}

struct DiagnosticWorkflowBinding: Sendable {
    let recorder: DiagnosticRecorder?
    let session: UUID
    let build: DiagnosticBuild?
    let trace: UUID
    let action: DiagnosticAction
    private let began = ProcessInfo.processInfo.systemUptime

    init(recorder: DiagnosticRecorder?, session: UUID, build: DiagnosticBuild?, trace: UUID, action: DiagnosticAction) {
        self.recorder = recorder; self.session = session; self.build = build; self.trace = trace; self.action = action
    }

    func event(_ phase: DiagnosticPhase, context: DiagnosticContext, error: DiagnosticErrorCode? = nil,
               causes: [DiagnosticErrorCode]? = nil, count: UInt64? = nil) {
        recorder?.record(.init(session: session, trace: trace, action: action, phase: phase,
            level: phase == .failed ? .error : [.partial,.blocked,.interrupted].contains(phase) ? .warning : .information,
            count: count,
            durationMilliseconds: DiagnosticErrors.milliseconds(ProcessInfo.processInfo.systemUptime - began),
            error: error, build: build, context: context, causes: causes))
    }
}

/// This producer runs on the operation callback, ahead of UI coalescing. Its
/// projection contains only opaque work links; no URL is retained or encoded.
final class DiagnosticJobBinding: @unchecked Sendable {
    private let recorder: DiagnosticRecorder?
    private let session: UUID, trace: UUID
    private let build: DiagnosticBuild?
    private let lock = NSLock()
    private var seen = Set<UUID>()
    init(recorder: DiagnosticRecorder?, session: UUID, build: DiagnosticBuild?, trace: UUID) {
        self.recorder = recorder; self.session = session; self.build = build; self.trace = trace
    }
    func receive(_ job: UUID) {
        let first = lock.withLock { () -> Bool in
            if seen.contains(job) || seen.count >= 32 { return false }; seen.insert(job); return true
        }
        if first { recorder?.record(.init(session: session, trace: trace, action: .fileOperation,
            phase: .admitted, build: build, relatedTrace: job)) }
    }
}
