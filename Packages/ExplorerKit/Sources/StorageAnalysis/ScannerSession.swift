import Darwin
import ExplorerCore
import Foundation

public enum StorageScanFailure: Error, Equatable, Sendable {
    case busy, accessDenied, unavailable, unsupportedLocation, changed
    case workerUnavailable, workerFailed, invalidOutput, resourceLimit
}

public enum StorageScanStatus: Equatable, Sendable {
    case preparing, scanning, completed, partial, cancelled, failed(StorageScanFailure)
}

public struct StorageScanUpdate: Sendable {
    public let session: UUID
    public let status: StorageScanStatus
    public let progress: StorageAnalysisProgress?
    public let snapshot: StorageAnalysisSnapshot?
    public let elapsed: TimeInterval
    public let workerPeakResidentBytes: UInt64?
    public let coverage: AnalysisScanCoverage
    /// True only after the owned child is reaped, pipes closed and model sealed.
    public let workerDrained: Bool
}

/// Cancellation invalidates demand, not an I/O lease. A caller can hide its UI
/// immediately, while waitUntilDrained still represents the actual worker.
public final class StorageScanSession: Sendable {
    public let id: UUID
    public let updates: AsyncStream<StorageScanUpdate>
    private let control: ScannerProcessControl
    fileprivate init(id: UUID, updates: AsyncStream<StorageScanUpdate>, control: ScannerProcessControl) {
        self.id = id; self.updates = updates; self.control = control
    }
    public func cancel() { control.cancel() }
    public func waitUntilDrained() async { await control.waitUntilDrained() }
    deinit { control.cancel() }
}

/// One bounded utility worker, shared by explicit analysis and hover callers.
/// The app's coordinator chooses priority and retains access; this module owns
/// native lifetime, decoding and accounting. It never requests an access grant.
public final class StorageScanner: @unchecked Sendable {
    let workerURL: URL
    let activityGate: FileActivityGate
    let queue: OperationQueue
    let lock = NSLock()
    var occupied = false
    #if DEBUG
    private var pagedDiagnostic: [String: String] = [:]
    private var refreshHistoryGap = false
    public func invalidateNextRefreshHistoryForQualification() { lock.withLock { refreshHistoryGap = true } }
    func takeRefreshHistoryGapForQualification() -> Bool {
        lock.withLock { let value = refreshHistoryGap; refreshHistoryGap = false; return value }
    }
    public var qualificationPagedDiagnostic: [String: String] { lock.withLock { pagedDiagnostic } }
    func notePagedDiagnostic(_ key: String, _ value: String) { lock.withLock { pagedDiagnostic[key] = value } }

    /// Existing collector over one admitted recorded root: no traversal,
    /// helper launch, catalog publication, or source-body access.
    func inspectRefreshEventsForQualification(record: RetainedAnalysisRecord, root: URL,
                                             retainingAccess: any Sendable) async throws -> [String: String] {
        try lock.withLock {
            guard !occupied else { throw StorageScanFailure.busy }
            occupied = true
        }
        let control = ScannerProcessControl(), retention = ScannerAccessRetention(retainingAccess)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    let result = Result<[String: String], Error> {
                        guard !control.cancelled else { throw CancellationError() }
                        try record.validate()
                        guard record.complete, record.metadataPolicy == AnalysisMetadataPolicy.standard.rawValue,
                              case .single(let expected) = record.scope,
                              root.standardizedFileURL.path == expected.locator,
                              let checkpoint = record.refreshCheckpoint else { throw StorageScanFailure.unsupportedLocation }
                        let activity = try activityGate.begin()
                        defer { withExtendedLifetime(activity) {} }
                        let descriptor = root.withUnsafeFileSystemRepresentation { path in
                            path.map { open($0, O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
                        }
                        guard descriptor >= 0 else { throw StorageScanFailure.accessDenied }
                        defer { close(descriptor) }
                        guard try RetainedAnalysisRecord.Root.capture(root, descriptor: descriptor) == expected else {
                            throw StorageScanFailure.changed
                        }
                        let events = try AnalysisRefreshEvents(root: root, descriptor: descriptor, previous: checkpoint,
                            cancelled: { control.cancelled })
                        defer { events.close() }
                        _ = try events.dirtyDirectories()
                        let values = events.finishQualificationDiagnostics()
                        guard !control.cancelled else { throw CancellationError() }
                        guard try RetainedAnalysisRecord.Root.capture(root, descriptor: descriptor) == expected else {
                            throw StorageScanFailure.changed
                        }
                        return values
                    }
                    retention.release()
                    lock.withLock {
                        if case .success(let values) = result { pagedDiagnostic = values }
                        occupied = false
                    }
                    control.finished()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { control.cancel() }
    }
    #endif

    public init(workerURL: URL, activityGate: FileActivityGate) {
        self.workerURL = workerURL; self.activityGate = activityGate
        queue = OperationQueue()
        queue.name = "MacExplorer.StorageAnalysis"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    /// root must be an explicit selected scope, or an app-admitted automatic
    /// scope. retainedAccess must hold the original scope-bearing grant objects.
    public func start(root: URL, retainingAccess: any Sendable) throws -> StorageScanSession {
        try lock.withLock {
            guard !occupied else { throw StorageScanFailure.busy }
            occupied = true
        }
        let id = UUID(), control = ScannerProcessControl()
        let retention = ScannerAccessRetention(retainingAccess)
        let pair = AsyncStream<StorageScanUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { @Sendable _ in control.cancel() }
        let session = StorageScanSession(id: id, updates: pair.stream, control: control)
        queue.addOperation { [self] in
            defer {
                retention.release()
                lock.withLock { occupied = false }
                control.finished()
                pair.continuation.finish()
            }
            execute(root: root, id: id, control: control, output: pair.continuation)
        }
        return session
    }

    private func execute(root: URL, id: UUID, control: ScannerProcessControl,
                         output: AsyncStream<StorageScanUpdate>.Continuation) {
        let began = ProcessInfo.processInfo.systemUptime
        var coverage = AnalysisScanCoverage()
        func update(_ status: StorageScanStatus, progress: StorageAnalysisProgress? = nil,
                    snapshot: StorageAnalysisSnapshot? = nil, peak: UInt64? = nil, drained: Bool = false) {
            output.yield(.init(session: id, status: status, progress: progress, snapshot: snapshot,
                elapsed: ProcessInfo.processInfo.systemUptime - began, workerPeakResidentBytes: peak,
                coverage: coverage, workerDrained: drained))
        }
        update(.preparing)
        var activity: FileActivityGate.Lease?
        var rootFD: Int32 = -1
        var model: StorageAnalysisAccumulator?
        var terminal: ScannerTerminal?
        var failure: StorageScanFailure?
        var progressCadence = ProgressCadence(interval: 0.25, startingAt: began)
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let policyEstablished = previousPolicy >= 0
            && setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
            && getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        defer {
            if rootFD >= 0 { close(rootFD) }
            if previousPolicy >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
            withExtendedLifetime(activity) {}
        }
        do {
            guard policyEstablished else { throw StorageScanFailure.unsupportedLocation }
            guard !control.cancelled else { throw CancellationError() }
            activity = try activityGate.begin()
            let admitted = try openRoot(root)
            rootFD = admitted.fd
            model = StorageAnalysisAccumulator(rootIdentity: admitted.identity)
            let decoder = ScannerProtocolDecoder(session: id, root: admitted.identity)
            guard !control.cancelled else { throw CancellationError() }
            let pipes = try launch(rootFD: rootFD, identity: admitted.identity, id: id, control: control)
            close(rootFD); rootFD = -1
            let exitStatus = try ScannerWorkerProcess.drain(pipes: pipes, control: control, onPoll: {
                if progressCadence.shouldPublish(at: ProcessInfo.processInfo.systemUptime) {
                    update(.scanning, progress: model?.progress)
                }
            }, onRejected: { error in
                failure = error as? StorageScanFailure ?? .invalidOutput
            }) { data in
                switch try decoder.consume(data) {
                case .header: break
                case .records(let rows):
                    for row in rows {
                        switch model?.consume(row) {
                        case .accepted: break
                        case .resourceLimited: throw StorageScanFailure.resourceLimit
                        default: throw StorageScanFailure.invalidOutput
                        }
                    }
                case .issue(let code, let error):
                    coverage.record(code: code, error: error)
                    _ = model?.recordCoverageGap(AnalysisScanCoverage.gap(code: code, error: error))
                case .terminal(let value):
                    terminal = value
                    coverage.finish(reason: value.reason, errors: value.errors)
                }
            }
            try decoder.finish()
            guard let terminal, (terminal.complete && exitStatus == 0) || (!terminal.complete && exitStatus != 0) else {
                throw StorageScanFailure.invalidOutput
            }
        } catch {
            if !control.cancelled, !(error is CancellationError), failure == nil {
                if let value = error as? StorageScanFailure { failure = value }
                else if error is FileActivityError { failure = .busy }
                else { failure = .invalidOutput }
            }
        }
        // The shared worker pump owns reaping and both pipe ends after launch.
        if rootFD >= 0 { close(rootFD); rootFD = -1 }
        if previousPolicy >= 0,
           setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy) != 0
            || (previousPolicy >= 0 && getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) != previousPolicy) {
            failure = .unsupportedLocation
        }
        let completion: AnalysisInputCompletion
        let status: StorageScanStatus
        if control.cancelled && failure == nil { completion = .cancelled; status = .cancelled }
        else if let failure { completion = .failed(.unavailable); status = .failed(failure) }
        else if terminal?.complete == true { completion = .completed; status = .completed }
        else { completion = .failed(.unavailable); status = .partial }
        let snapshot = model?.finish(completion)
        if terminal?.complete == true, let terminal, let snapshot {
            let counts = snapshot.root.counts
            let actualCounts = [counts.regularFiles, counts.directories, counts.symbolicLinks, counts.other + counts.unknown]
            let metrics: [AnalysisByteMetric] = [.dataLogical, .allForkLogical, .dataAllocated, .allForkAllocated]
            if actualCounts != terminal.kindCounts || snapshot.distinctObjects.knownObjectCount != terminal.objectCount
                || metrics.map({ snapshot.root.namespaceSubtotals[$0].knownBytes }) != terminal.namespaceTotals.map(Optional.some)
                || metrics.map({ snapshot.distinctObjects.byteSubtotals[$0].knownBytes }) != terminal.objectTotals.map(Optional.some) {
                update(.failed(.invalidOutput), progress: model?.progress, snapshot: snapshot, peak: terminal.peakResidentBytes, drained: true)
                return
            }
        }
        // A model can detect missing/changed accounting even if a worker asserts
        // complete. Keep that result partial rather than upgrading its coverage.
        let finalStatus = status == .completed && snapshot?.isComplete != true ? StorageScanStatus.partial : status
        update(finalStatus, progress: model?.progress, snapshot: snapshot, peak: terminal?.peakResidentBytes, drained: true)
    }

    func openRoot(_ url: URL, metadataPolicy: AnalysisMetadataPolicy = .standard) throws -> (fd: Int32, identity: AnalysisObjectIdentity) {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !StorageAnalysisPolicy.excludes(url, policy: metadataPolicy) else { throw StorageScanFailure.unsupportedLocation }
        let original = url.withUnsafeFileSystemRepresentation { value in
            value.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
        }
        guard original >= 0 else {
            throw errno == EACCES || errno == EPERM ? StorageScanFailure.accessDenied : .unavailable
        }
        defer { close(original) }
        var metadata = stat(), filesystem = statfs()
        guard fstat(original, &metadata) == 0, fstatfs(original, &filesystem) == 0 else { throw StorageScanFailure.unavailable }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StorageScanFailure.unsupportedLocation }
        let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 10)
        guard duplicate >= 0 else { throw StorageScanFailure.unavailable }
        return (duplicate, .init(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: metadata.st_ino))
    }

    private func launch(rootFD: Int32, identity: AnalysisObjectIdentity, id: UUID,
                        control: ScannerProcessControl) throws -> (stdout: Int32, stderr: Int32) {
        try ScannerWorkerProcess.launch(workerURL: workerURL, descriptors: [(3, rootFD)],
            arguments: ["--root-fd", "3", "--expected-dev", String(identity.device),
                "--expected-ino", String(identity.inode), "--session", id.uuidString], control: control)
    }
}

/// Constructed before enqueue and touched only by its one operation afterward.
/// Explicit release precedes the public drain acknowledgement even if the
/// operation queue retains its completed closure for longer.
private final class ScannerAccessRetention: @unchecked Sendable {
    private var value: (any Sendable)?
    init(_ value: any Sendable) { self.value = value }
    func release() { value = nil }
}

/// Signal/reap share one short lock so a stale PID can never be signalled after
/// this owner has reaped it. No blocking wait or filesystem work holds the lock.
final class ScannerProcessControl: @unchecked Sendable {
    let lock = NSLock()
    private var pid: pid_t?
    private var cancellationRequested = false
    private var cancellationTime: TimeInterval?
    private var escalated = false
    private var lastStatus: Int32?
    #if DEBUG
    var qualificationExit: Int32? { lock.withLock { lastStatus } }
    var qualificationEscalated: Bool { lock.withLock { escalated } }
    #endif
    private var drained = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var cancelled: Bool { lock.withLock { cancellationRequested } }
    func attach(_ value: pid_t) {
        lock.withLock {
            precondition(pid == nil && !drained)
            pid = value
            if cancellationRequested { _ = kill(value, SIGTERM) }
        }
    }
    func cancel() {
        lock.withLock {
            cancellationRequested = true
            if cancellationTime == nil { cancellationTime = ProcessInfo.processInfo.systemUptime }
            if let pid { _ = kill(pid, SIGTERM) }
        }
    }
    func escalateIfNeeded() {
        lock.withLock {
            guard let pid, let cancellationTime, !escalated,
                  ProcessInfo.processInfo.systemUptime - cancellationTime >= 2 else { return }
            // The child is read-only, still owned and not yet reaped. Force
            // termination releases no lease until waitpid and EOF confirm exit.
            escalated = true
            _ = kill(pid, SIGKILL)
        }
    }
    func reapIfExited() -> Int32? {
        lock.withLock {
            guard let pid else { return nil }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result < 0, errno == ECHILD { self.pid = nil; return -1 }
            guard result == pid else { return nil }
            self.pid = nil; lastStatus = status
            return status
        }
    }
    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if drained { return true }
                waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    func finished() {
        let continuations = lock.withLock {
            precondition(pid == nil)
            drained = true
            let result = waiters; waiters.removeAll(); return result
        }
        continuations.forEach { $0.resume() }
    }
}
