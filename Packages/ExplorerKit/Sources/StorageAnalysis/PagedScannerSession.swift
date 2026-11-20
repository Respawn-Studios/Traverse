import Darwin
import ExplorerCore
import Foundation

public final class PagedStorageScanSession: Sendable {
    public let id: UUID
    public let updates: AsyncStream<PagedStorageScanUpdate>
    private let control: ScannerProcessControl
    private let retainedCapture: RetainedCaptureSlot?
    init(id: UUID, updates: AsyncStream<PagedStorageScanUpdate>, control: ScannerProcessControl,
         retainedCapture: RetainedCaptureSlot?) {
        self.id = id; self.updates = updates; self.control = control; self.retainedCapture = retainedCapture
    }
    public func cancel() { control.cancel() }
    public func waitUntilDrained() async { await control.waitUntilDrained() }
    /// The terminal workerDrained flag precedes queue defer. Only this method
    /// can issue a one-shot native publication candidate after control.finished.
    func drainedRetainedCandidate() async -> RetainedDrainedCandidate? {
        guard let retainedCapture else { return nil }
        await control.waitUntilDrained()
        return retainedCapture.take()
    }
    deinit { control.cancel() }
}

extension StorageScanner {
    private struct StartupRequest: Sendable {
        let plan: StartupStoragePlan
        let discovery: StartupVolumeDiscovery
    }
    /// Explicit analysis only. Hover retains the independently bounded route.
    /// This entry point shares the scanner's single actual-worker admission.
    public func startPaged(root: URL, storage: AnalysisResultStorage, metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable) throws -> PagedStorageScanSession {
        try startResult(root: root, storage: storage, startup: nil, metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: 16384, classificationRevision: .v4)
    }
    /// Inactive native retention seam. Ordinary paged scans do not hash the
    /// helper, capture root evidence or allocate a retention candidate slot.
    func startPagedRetainedCandidate(root: URL, storage: AnalysisResultStorage,
        metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable,
        refreshBaseline: StorageAnalysisResult? = nil, updatingChanges: Bool = false) throws -> PagedStorageScanSession {
        guard storage.retentionStateDirectory != nil else { throw StorageScanFailure.unsupportedLocation }
        return try startResult(root: root, storage: storage, startup: nil, metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: 16384,
            classificationRevision: .v4, requestRetainedCapture: true, refreshBaseline: refreshBaseline, updatingChanges: updatingChanges)
    }
    #if DEBUG
    public func startPagedDataClassificationForQualification(root: URL, storage: AnalysisResultStorage,
        metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable,
        classificationRevision: AnalysisClassificationRevision = .v4) throws -> PagedStorageScanSession {
        try startResult(root: root, storage: storage, startup: nil, metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: 16384, classificationRevision: classificationRevision)
    }
    public func startPagedWithPrefixesForQualification(root: URL, storage: AnalysisResultStorage,
        metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable, checkpointRows: UInt64 = 1024) throws -> PagedStorageScanSession {
        try startResult(root: root, storage: storage, startup: nil, metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: checkpointRows)
    }
    public func startPagedClassificationForQualification(root: URL, storage: AnalysisResultStorage,
        metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable) throws -> PagedStorageScanSession {
        try startResult(root: root, storage: storage, startup: nil, metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: 4096, classificationRevision: .v3)
    }
    public func startStartupWithPrefixesForQualification(plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
        storage: AnalysisResultStorage, metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable, checkpointRows: UInt64 = 1024,
        classificationRevision: AnalysisClassificationRevision = .v2) throws -> PagedStorageScanSession {
        try startResult(root: plan.dataRoot, storage: storage, startup: .init(plan: plan, discovery: discovery),
            metadataPolicy: metadataPolicy, retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: checkpointRows, classificationRevision: classificationRevision)
    }
    #endif
    public func startStartup(plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
                             storage: AnalysisResultStorage, metadataPolicy: AnalysisMetadataPolicy = .standard, retainingAccess: any Sendable) throws -> PagedStorageScanSession {
        try startResult(root: plan.dataRoot, storage: storage, startup: .init(plan: plan, discovery: discovery), metadataPolicy: metadataPolicy,
            retainingAccess: retainingAccess, acceptsPrefixes: true, checkpointRows: 16384, classificationRevision: .v4)
    }
    func startStartupRetainedCandidate(plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
        storage: AnalysisResultStorage, metadataPolicy: AnalysisMetadataPolicy = .standard,
        retainingAccess: any Sendable) throws -> PagedStorageScanSession {
        guard storage.retentionStateDirectory != nil else { throw StorageScanFailure.unsupportedLocation }
        return try startResult(root: plan.dataRoot, storage: storage, startup: .init(plan: plan, discovery: discovery),
            metadataPolicy: metadataPolicy, retainingAccess: retainingAccess, acceptsPrefixes: true,
            checkpointRows: 16384, classificationRevision: .v4, requestRetainedCapture: true)
    }
    private func startResult(root: URL, storage: AnalysisResultStorage, startup: StartupRequest?, metadataPolicy: AnalysisMetadataPolicy, retainingAccess: any Sendable, acceptsPrefixes: Bool = false, checkpointRows: UInt64 = 1024, classificationRevision: AnalysisClassificationRevision = .v2, requestRetainedCapture: Bool = false, refreshBaseline: StorageAnalysisResult? = nil, updatingChanges: Bool = false) throws -> PagedStorageScanSession {
        _ = try AnalysisCheckpointContract(rows: checkpointRows, classification: classificationRevision)
        guard acceptsPrefixes || checkpointRows == 1024 else { throw StorageScanFailure.invalidOutput }
        try lock.withLock {
            guard !occupied else { throw StorageScanFailure.busy }; occupied = true
        }
        let id = UUID(), control = ScannerProcessControl()
        let pair = AsyncStream<PagedStorageScanUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { @Sendable _ in control.cancel() }
        let retention = PagedAccessRetention(retainingAccess)
        let retainedCapture = requestRetainedCapture ? RetainedCaptureSlot() : nil
        let session = PagedStorageScanSession(id: id, updates: pair.stream, control: control,
            retainedCapture: retainedCapture)
        queue.addOperation { [self] in
            defer {
                retention.release(); lock.withLock { occupied = false }
                control.finished(); pair.continuation.finish()
            }
            executePaged(root: root, storage: storage, startup: startup, metadataPolicy: metadataPolicy, id: id, control: control, output: pair.continuation, retainedCapture: retainedCapture, acceptsPrefixes: acceptsPrefixes, checkpointRows: checkpointRows, classificationRevision: classificationRevision, refreshBaseline: refreshBaseline, updatingChanges: updatingChanges)
        }
        return session
    }

    private func executePaged(root: URL, storage: AnalysisResultStorage, startup: StartupRequest?, metadataPolicy: AnalysisMetadataPolicy, id: UUID,
                              control: ScannerProcessControl, output: AsyncStream<PagedStorageScanUpdate>.Continuation,
                              retainedCapture: RetainedCaptureSlot?, acceptsPrefixes: Bool, checkpointRows: UInt64,
                              classificationRevision: AnalysisClassificationRevision, refreshBaseline: StorageAnalysisResult? = nil,
                              updatingChanges: Bool = false, forcedFallback: String? = nil) {
        let began = ProcessInfo.processInfo.systemUptime
        let observedFrom = retainedCapture == nil ? nil : (try? RetainedAnalysisRecord.Time(seconds: Int64(Date().timeIntervalSince1970)))
        var coverage = AnalysisScanCoverage(), committed: UInt64 = 0
        var prefix: CommittedAnalysisPrefix?
        var diagnostics: AnalysisScanDiagnostics?
        func update(_ status: StorageScanStatus, result: StorageAnalysisResult? = nil, peak: UInt64? = nil, drained: Bool = false) {
            output.yield(.init(session: id, status: status, committedEntries: committed, result: result,
                elapsed: ProcessInfo.processInfo.systemUptime - began, workerPeakResidentBytes: peak, coverage: coverage, workerDrained: drained, isStartupPair: startup != nil,
                provisionalFileTypes: result == nil && !drained ? prefix : nil, diagnostics: drained ? diagnostics : nil))
        }
        update(.preparing)
        #if DEBUG
        notePagedDiagnostic("phase", "preparing")
        #endif
        var peer: Int32 = -1, transitionRead: Int32 = -1, transitionWrite: Int32 = -1
        defer {
            if peer >= 0 { close(peer) }; if transitionRead >= 0 { close(transitionRead) }; if transitionWrite >= 0 { close(transitionWrite) }
            startup?.plan.watch.whenInvalidated(nil)
        }
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        defer { if previous >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        do {
            guard previous >= 0,
                  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
                  getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else { throw StorageScanFailure.unsupportedLocation }
            let activity = try activityGate.begin()
            defer { withExtendedLifetime(activity) {} }
            defer {
                if peer >= 0 { close(peer); peer = -1 }; if transitionWrite >= 0 { close(transitionWrite); transitionWrite = -1 }
                if transitionRead >= 0 { close(transitionRead); transitionRead = -1 }
            }
            guard !control.cancelled else { throw CancellationError() }
            let source = try openRoot(root, metadataPolicy: metadataPolicy)
            #if DEBUG
            notePagedDiagnostic("phase", "root_opened")
            #endif
            defer { close(source.fd) }
            var previousRefresh = updatingChanges && forcedFallback == nil ? refreshBaseline?.refreshCheckpoint : nil
            #if DEBUG
            if updatingChanges, takeRefreshHistoryGapForQualification(), let value = previousRefresh {
                previousRefresh = .init(catalogID: value.catalogID, eventUUID: UUID(), cursor: value.cursor,
                    originalObservedThrough: value.originalObservedThrough, reusedEntries: value.reusedEntries,
                    enumeratedDirectories: value.enumeratedDirectories, isIncremental: value.isIncremental, fallbackReason: value.fallbackReason,
                    reusedDirectories: value.reusedDirectories)
            }
            #endif
            let events = retainedCapture != nil && startup == nil && metadataPolicy == .standard
                ? try? AnalysisRefreshEvents(root: root, descriptor: source.fd, previous: previousRefresh,
                    cancelled: { control.cancelled }) : nil
            defer { events?.close() }
            var fullFallback = forcedFallback
            // Historical delivery is fenced before either kind of source
            // traversal, including a full scan that seeds a new checkpoint.
            let replayedDirty = try events?.dirtyDirectories()
            #if DEBUG
            if let events { for (key, value) in events.qualificationDiagnostics { notePagedDiagnostic(key, value) } }
            notePagedDiagnostic("refresh_direct_directories", String(replayedDirty?.filter { !$0.recursive }.count ?? 0))
            notePagedDiagnostic("refresh_recursive_directories", String(replayedDirty?.filter { $0.recursive }.count ?? 0))
            notePagedDiagnostic("refresh_recursive_root", String(replayedDirty?.contains { $0.path.isEmpty && $0.recursive } ?? false))
            notePagedDiagnostic("refresh_watch_reason", events?.fallbackReason ?? "none")
            #endif
            var dirty: [AnalysisRefreshDirtyDirectory]?
            if updatingChanges && forcedFallback == nil {
                if metadataPolicy != .standard { fullFallback = "unsupported_scope" }
                else if previousRefresh == nil { fullFallback = "baseline_missing" }
                else {
                    dirty = replayedDirty
                    if dirty == nil { fullFallback = events?.fallbackReason ?? "history_unavailable" }
                    else if dirty?.contains(where: { $0.path.isEmpty && $0.recursive }) == true { dirty = nil; fullFallback = "root_dirty" }
                }
            }
            var descriptors: [(Int32, Int32)] = [(3, source.fd)]
            var arguments = ["--full-result", "", "--result-quota", "", "--root-fd", "3", "--expected-dev", String(source.identity.device),
                "--expected-ino", String(source.identity.inode), "--session", id.uuidString]
            if let startup {
                try startup.plan.revalidateNative()
                guard source.identity == startup.plan.data.identity.object else { throw StorageScanFailure.changed }
                let system = try openRoot(startup.plan.systemRoot); peer = system.fd
                guard system.identity == startup.plan.system.identity.object else { throw StorageScanFailure.changed }
                var pipeFDs = [Int32](repeating: -1, count: 2)
                guard pipe(&pipeFDs) == 0 else { throw StorageScanFailure.workerUnavailable }
                transitionRead = pipeFDs[0]; transitionWrite = pipeFDs[1]
                guard fcntl(transitionRead, F_SETFD, FD_CLOEXEC) == 0, fcntl(transitionWrite, F_SETFD, FD_CLOEXEC) == 0,
                      fcntl(transitionWrite, F_SETNOSIGPIPE, 1) == 0 else { throw StorageScanFailure.workerUnavailable }
                descriptors += [(7, peer), (8, transitionRead)]
                arguments = ["--startup-result", "", "--result-quota", "", "--session", id.uuidString,
                    "--data-dev", String(source.identity.device), "--data-ino", String(source.identity.inode),
                    "--system-dev", String(system.identity.device), "--system-ino", String(system.identity.inode)]
                startup.plan.watch.whenInvalidated { control.cancel() }
            }
            let files = try AnalysisStoreFiles(storage: storage, id: id,
                activityGate: activityGate, admittedBy: activity)
            #if DEBUG
            notePagedDiagnostic("phase", "store_opened")
            #endif
            guard !control.cancelled else { throw CancellationError() }
            arguments[1] = files.path.path; arguments[3] = String(files.quota)
            var refreshInput: AnalysisRefreshInput?
            if let dirty, let refreshBaseline {
                do {
                    let baseline = try refreshBaseline.acquireRefreshBaseline(control: control)
                    let input = try AnalysisRefreshInput(baseline: baseline, dirty: dirty, files: files)
                    refreshInput = input
                    arguments[0] = "--refresh-result"
                    descriptors += input.descriptors
                } catch { fullFallback = "baseline_unavailable" }
            }
            defer { withExtendedLifetime(refreshInput) {} }
            var actualIncremental = false
            var refreshCapable = false
            if metadataPolicy != .standard { arguments += ["--metadata-policy", metadataPolicy.rawValue] }
            let locationSources: AnalysisLocationSourceScope
            if let startup {
                locationSources = try .init(roots: [
                    1: .init(url: startup.plan.dataRoot, descriptor: source.fd, identity: source.identity, physical: startup.plan.data.identity),
                    2: .init(url: startup.plan.systemRoot, descriptor: peer, identity: startup.plan.system.identity.object, physical: startup.plan.system.identity)
                ], policy: metadataPolicy)
            } else {
                locationSources = try .init(roots: [0: .init(url: root, descriptor: source.fd, identity: source.identity)], policy: metadataPolicy)
            }
            var sequence: UInt64 = 0, header = false, terminal: [String: Any]?, notices = 0
            var wireSchema: Int?, rowOrder = StoredAnalysisRowOrder.ordinal
            var policyBinding = AnalysisPolicyBinding.standard
            var transitions = 0
            var checkpointTransitionPending = false
            let checkpoint = try AnalysisCheckpointContract(rows: checkpointRows, classification: classificationRevision)
            var progressCadence = ProgressCadence(interval: 0.25, startingAt: began)
            // An observed bundle-file identity only. The path-based launcher
            // cannot attest the exact executable bytes under path replacement.
            let helperBefore = retainedCapture == nil ? nil : (try? RetainedHelperObservation.read(workerURL, session: id))
            let pipes = try ScannerWorkerProcess.launch(workerURL: workerURL,
                descriptors: descriptors + files.descriptors, arguments: arguments, control: control)
            #if DEBUG
            notePagedDiagnostic("phase", "pumping")
            #endif
            if transitionRead >= 0 { close(transitionRead); transitionRead = -1 }
            let status = try ScannerWorkerProcess.drain(pipes: pipes, control: control) { data in
                guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let schema = frame["schema"] as? Int, frame["session"] as? String == id.uuidString,
                      (try storedNumber(frame["seq"])) == sequence, terminal == nil,
                      let kind = frame["kind"] as? String else { throw StorageScanFailure.invalidOutput }
                sequence += 1
                if !header {
                    if acceptsPrefixes {
                        guard frame["progress_revision"] as? String == checkpoint.progressRevision,
                              checkpointRows == 1024 ? frame["checkpoint_rows"] == nil : strictInteger(frame["checkpoint_rows"]) == Int(checkpointRows) else { throw StorageScanFailure.invalidOutput }
                    } else { guard frame["progress_revision"] == nil else { throw StorageScanFailure.invalidOutput } }
                    policyBinding = try AnalysisPolicyBinding(header: frame, startup: startup != nil, policy: metadataPolicy, classificationRevision: classificationRevision)
                    guard kind == "header",
                          frame["materialization_policy"] as? String == "off",
                          (try storedNumber(frame["expected_dev"])) == source.identity.device,
                          (try storedNumber(frame["expected_ino"])) == source.identity.inode else { throw StorageScanFailure.invalidOutput }
                    if let startup { try Self.validateStartupHeader(frame, plan: startup.plan) }
                    wireSchema = schema; rowOrder = schema == (startup == nil ? 7 : 8) ? .rawName : .ordinal
                    #if DEBUG
                    notePagedDiagnostic("header_uptime", String(ProcessInfo.processInfo.systemUptime))
                    #endif
                    let advertisedRefresh = frame["incremental_refresh"] as? Bool
                    refreshCapable = advertisedRefresh != nil
                    actualIncremental = advertisedRefresh == true
                    if let reason = frame["refresh_fallback"] as? String {
                        guard AnalysisRefreshEvents.reasons.contains(reason) else { throw StorageScanFailure.invalidOutput }
                        fullFallback = reason
                    }
                    guard !actualIncremental || refreshInput != nil else { throw StorageScanFailure.invalidOutput }
                    header = true; update(.scanning); return
                }
                guard schema == wireSchema else { throw StorageScanFailure.invalidOutput }
                switch kind {
                case "committed_totals":
                    guard acceptsPrefixes else { throw StorageScanFailure.invalidOutput }
                    prefix = try CommittedAnalysisPrefix.decode(frame, session: id, policy: metadataPolicy,
                        wireSchema: schema, committed: committed, previous: prefix, checkpointRows: checkpointRows, classificationRevision: classificationRevision)
                    update(control.cancelled ? .cancelled : .scanning)
                case "phase":
                    guard startup != nil, let stage = frame["stage"] as? String,
                          ["draining_directories", "directories_drained", "sealing", "counting"].contains(stage) else { throw StorageScanFailure.invalidOutput }
                    #if DEBUG
                    notePagedDiagnostic("worker_phase", stage)
                    notePagedDiagnostic(stage + "_uptime", String(ProcessInfo.processInfo.systemUptime))
                    #endif
                case "member_transition":
                    guard let startup, transitions < 2,
                          (try storedNumber(frame["from"])) == (transitions == 0 ? 1 : 2),
                          (try storedNumber(frame["to"])) == (transitions == 0 ? 2 : 0) else { throw StorageScanFailure.invalidOutput }
                    transitions += 1
                    checkpointTransitionPending = true
                    #if DEBUG
                    notePagedDiagnostic("phase", "transition_" + String(transitions))
                    #endif
                    var answer: UInt8 = 1
                    do { try startup.discovery.revalidateDuringScan(startup.plan, scanner: control) }
                    catch { answer = 0; coverage.record(code: "topology_changed", error: 0) }
                    guard write(transitionWrite, &answer, 1) == 1 else { throw StorageScanFailure.workerFailed }
                    #if DEBUG
                    notePagedDiagnostic("phase", "pumping")
                    #endif
                case "progress":
                    let count = try storedNumber(frame["committed"])
                    guard checkpoint.acceptsProgress(count, previous: committed, crossedSource: checkpointTransitionPending) else { throw StorageScanFailure.invalidOutput }
                    checkpointTransitionPending = false
                    let first = committed == 0
                    committed = count
                    if progressCadence.shouldPublish(at: ProcessInfo.processInfo.systemUptime, immediately: first) {
                        update(control.cancelled ? .cancelled : .scanning)
                    }
                case "issue":
                    guard notices < 100, let code = frame["code"] as? String, code.utf8.count <= 64,
                          code.utf8.allSatisfy({ $0 == 95 || (97...122).contains($0) }),
                          let error = frame["errno"] as? Int32 else { throw StorageScanFailure.invalidOutput }
                    notices += 1; coverage.record(code: code, error: error)
                case "summary":
                    terminal = frame
                    #if DEBUG
                    let code = frame["reason"] as? String ?? "missing"
                    if code.utf8.count <= 64, code.utf8.allSatisfy({ $0 == 95 || (97...122).contains($0) }) { notePagedDiagnostic("worker_reason", code) }
                    #endif
                default: throw StorageScanFailure.invalidOutput
                }
            }
            try refreshInput?.baseline.validate()
            if actualIncremental, !control.cancelled, forcedFallback == nil,
               let terminal, terminal["complete"] as? Bool != true || events?.fallbackReason != nil {
                events?.close()
                files.discardAndClose()
                executePaged(root: root, storage: storage, startup: startup, metadataPolicy: metadataPolicy,
                    id: id, control: control, output: output, retainedCapture: retainedCapture,
                    acceptsPrefixes: acceptsPrefixes, checkpointRows: checkpointRows,
                    classificationRevision: classificationRevision, updatingChanges: true,
                    forcedFallback: events?.fallbackReason ?? "refresh_incomplete")
                return
            }
            guard header, let terminal, let complete = terminal["complete"] as? Bool,
                  let ready = terminal["store_ready"] as? Bool, ready,
                  let reason = terminal["reason"] as? String, reason.utf8.count <= 64,
                  status == (complete ? 0 : 2 << 8), !complete || reason == "complete" else { throw StorageScanFailure.invalidOutput }
            guard !complete || startup == nil || transitions == 2 else { throw StorageScanFailure.invalidOutput }
            let attempted = try storedNumber(terminal["entries"]), final = try storedNumber(terminal["committed_entries"])
            guard final >= committed, final <= attempted, !complete || final == attempted else { throw StorageScanFailure.invalidOutput }
            committed = final
            let errors = try storedNumber(terminal["errors"])
            if acceptsPrefixes {
                let value = try AnalysisScanDiagnostics.decode(terminal["stage_profile"], errors: errors)
                diagnostics = value; try coverage.finish(reason: reason, errors: errors, diagnostics: value)
            } else { coverage.finish(reason: reason, errors: errors) }
            try files.finishWriting()
            let watch = startup?.plan.watch
            if watch?.isChanged == true { coverage.record(code: "topology_changed", error: 0) }
            let reused = try terminal["refresh_reused_entries"].map { try storedNumber($0) } ?? 0
            let enumerated = try terminal["refresh_enumerated_directories"].map { try storedNumber($0) } ?? 0
            let reusedDirectories = try terminal["refresh_reused_directories"].map { try storedNumber($0) } ?? 0
            let borrowedEarlierObservations = actualIncremental && (reused > 0 || reusedDirectories > 0)
            var refresh = complete && refreshCapable ? events?.checkpoint(catalogID: id,
                observedThrough: borrowedEarlierObservations ? previousRefresh?.originalObservedThrough ?? Date() : Date(),
                reusedEntries: reused, enumeratedDirectories: enumerated, reusedDirectories: reusedDirectories, incremental: actualIncremental) : nil
            #if DEBUG
            if let events { for (key, value) in events.qualificationDiagnostics { notePagedDiagnostic(key, value) } }
            #endif
            if let value = refresh, !actualIncremental, let reason = fullFallback {
                refresh = .init(catalogID: value.catalogID, eventUUID: value.eventUUID, cursor: value.cursor,
                    originalObservedThrough: value.originalObservedThrough, reusedEntries: 0,
                    enumeratedDirectories: enumerated, isIncremental: false, fallbackReason: reason, reusedDirectories: 0)
            }
            if actualIncremental, refresh == nil, !control.cancelled, forcedFallback == nil {
                events?.close()
                files.discardAndClose()
                executePaged(root: root, storage: storage, startup: startup, metadataPolicy: metadataPolicy,
                    id: id, control: control, output: output, retainedCapture: retainedCapture,
                    acceptsPrefixes: acceptsPrefixes, checkpointRows: checkpointRows,
                    classificationRevision: classificationRevision, updatingChanges: true,
                    forcedFallback: events?.fallbackReason ?? "history_unavailable")
                return
            }
            let result = StorageAnalysisResult(id: id, files: files, workerURL: workerURL, activityGate: activityGate,
                rowOrder: rowOrder, policyBinding: policyBinding, locationSources: locationSources,
                scopeIsCurrent: { watch?.isChanged != true }, refreshCheckpoint: refresh,
                refreshFallbackReason: fullFallback, scanElapsed: ProcessInfo.processInfo.systemUptime - began)
            let peak = try terminal["peak_rss"].map { try storedNumber($0) }
            if let retainedCapture, !control.cancelled, reason != "cancelled", watch?.isChanged != true,
               let helperBefore, let observedFrom,
               let capture = try? RetainedScanCapture.capture(result: result, source: source.fd,
                   peer: peer >= 0 ? peer : nil, root: root, startup: startup?.plan,
                   policy: metadataPolicy, coverage: coverage, complete: complete,
                   committed: committed, began: observedFrom,
                   helperBefore: helperBefore, workerURL: workerURL) {
                try? retainedCapture.install(capture)
            }
            update(control.cancelled || reason == "cancelled" ? .cancelled : complete && watch?.isChanged != true ? .completed : .partial,
                result: result, peak: peak, drained: true)
        } catch {
            #if DEBUG
            notePagedDiagnostic("failure", String(describing: error as? StorageScanFailure ?? .workerFailed))
            notePagedDiagnostic("exit", control.qualificationExit.map(String.init) ?? "none")
            notePagedDiagnostic("escalated", String(control.qualificationEscalated))
            #endif
            // The pump also cancels its child to drain a rejected protocol.
            // Preserve that concrete failure instead of calling it user Stop.
            if let failure = error as? StorageScanFailure { update(.failed(failure), drained: true) }
            else { update(control.cancelled ? .cancelled : .failed(.workerFailed), drained: true) }
        }
    }

    private static func validateStartupHeader(_ frame: [String: Any], plan: StartupStoragePlan) throws {
        guard let sources = frame["sources"] as? [[String: Any]], sources.count == 2 else { throw StorageScanFailure.invalidOutput }
        for (index, native) in [plan.data.identity, plan.system.identity].enumerated() {
            let row = sources[index]
            guard try storedNumber(row["id"]) == UInt64(index + 1),
                  try storedNumber(row["namespace_dev"]) == native.object.device,
                  try storedNumber(row["namespace_ino"]) == native.object.inode,
                  try storedNumber(row["physical_dev"]) == UInt64(native.realDevice),
                  try storedNumber(row["physical_ino"]) == native.realInode,
                  try storedNumber(row["fsid0"]) == UInt64(UInt32(bitPattern: native.realFSID0)),
                  try storedNumber(row["fsid1"]) == UInt64(UInt32(bitPattern: native.realFSID1)) else { throw StorageScanFailure.invalidOutput }
        }
    }
}

private final class PagedAccessRetention: @unchecked Sendable {
    private var value: (any Sendable)?
    init(_ value: any Sendable) { self.value = value }
    func release() { value = nil }
}
