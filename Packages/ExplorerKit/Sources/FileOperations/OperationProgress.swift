import ExplorerCore
import Foundation

public enum OperationProgressPhase: String, Sendable {
    case planning, copying, verifying, publishing, syncing, retaining, stopping, completed
}

/// A phase measurement, not a fabricated overall percentage. Callbacks run off the main
/// actor and must return promptly. Intermediate snapshots may be coalesced.
public struct OperationProgress: Sendable {
    public let jobID: UUID
    public let sequence: UInt64
    public let phase: OperationProgressPhase
    public let source: URL?
    public let destination: URL?
    public let currentItem: URL?
    public let itemIndex: Int?
    public let itemCount: Int?
    public let bytesCompleted: Int64?
    public let bytesTotal: Int64?
    public let itemsCompleted: Int?
    public let itemsTotal: Int?
    public let bytesPerSecond: Double?
    public let estimatedRemainingTime: TimeInterval?
    public let isTerminal: Bool
    public let cancellationRequested: Bool
    public var fractionCompleted: Double? {
        if let total = bytesTotal, total > 0, let done = bytesCompleted { return min(1, max(0, Double(done) / Double(total))) }
        if let total = itemsTotal, total > 0, let done = itemsCompleted { return min(1, max(0, Double(done) / Double(total))) }
        return nil
    }
}

private final class ProgressSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value &+= 1; return value } }
}

internal final class OperationProgressReporter: @unchecked Sendable {
    let jobID: UUID
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "MacExplorer.OperationProgress", qos: .utility)
    private var callback: (@Sendable (OperationProgress) -> Void)?
    private var pending: OperationProgress?
    private var scheduled = false
    private let sequence: ProgressSequence
    private var phase: OperationProgressPhase = .planning
    private var source: URL?
    private var destination: URL?
    private var currentItem: URL?
    private var itemIndex: Int?
    private var itemCount: Int?
    private var bytes: Int64 = 0
    private var totalBytes: Int64?
    private var items = 0
    private var totalItems: Int?
    private var stopped = false
    private var terminal = false
    private var nativeCodes: [OperationProgressPhase: Set<Int32>] = [:]
    private let diagnosticSequence: ProgressSequence
    private var progressCadence = ProgressCadence(interval: 0.1)
    private var samples: [(Double, Int64)] = []
    init(jobID: UUID = UUID(), callback: (@Sendable (OperationProgress) -> Void)?) {
        self.jobID = jobID; self.callback = callback; sequence = ProgressSequence(); diagnosticSequence = ProgressSequence()
    }
    private init(jobID: UUID, sequence: ProgressSequence, diagnosticSequence: ProgressSequence,
                 callback: (@Sendable (OperationProgress) -> Void)?) {
        self.jobID = jobID; self.sequence = sequence; self.diagnosticSequence = diagnosticSequence; self.callback = callback
    }
    func next(callback: (@Sendable (OperationProgress) -> Void)?) -> OperationProgressReporter {
        OperationProgressReporter(jobID: jobID, sequence: sequence, diagnosticSequence: diagnosticSequence, callback: callback)
    }
    func begin(_ phase: OperationProgressPhase, source: URL? = nil, destination: URL? = nil,
               index: Int? = nil, count: Int? = nil, bytes: Int64? = nil, items: Int? = nil) {
        lock.withLock {
            guard !terminal else { return }
            self.phase = phase; self.source = source; self.destination = destination; currentItem = source
            itemIndex = index; itemCount = count; self.bytes = 0; totalBytes = bytes
            self.items = 0; totalItems = items; samples = []
            observe(phase)
            emit(force: true)
        }
    }
    /// Change phase while preserving the public item context, never expose private staging paths.
    func transition(_ phase: OperationProgressPhase) {
        lock.withLock {
            guard !terminal else { return }
            self.phase = phase; bytes = 0; totalBytes = nil; items = 0; totalItems = nil; samples = []
            observe(phase)
            emit(force: true)
        }
    }
    func visit(relative: String) {
        lock.withLock {
            guard !terminal else { return }
            currentItem = relative.isEmpty ? source : source?.appendingPathComponent(relative)
            emit(force: false)
        }
    }
    func advance(bytes: Int64 = 0, items: Int = 0) {
        lock.withLock {
            guard !terminal else { return }
            self.bytes += max(0, bytes); self.items += max(0, items)
            emit(force: false)
        }
    }
    func requestStop() { lock.withLock { guard !terminal else { return }; stopped = true; observe(.stopping); emit(force: true) } }
    func finish(success: Bool) {
        lock.withLock {
            guard !terminal else { return }
            terminal = true; phase = .completed
            observe(.completed, success: success)
            // Only a durable successful result can finish at 100%. An incomplete terminal
            // result exposes no percentage; its FileOperationResult is authoritative.
            totalBytes = nil; bytes = 0; items = success ? 1 : 0; totalItems = success ? 1 : nil
            emit(force: true)
        }
        delivery.sync {} // callbacks never execute on the caller/main actor
    }
    func flush() { delivery.sync {} }
    private func observe(_ phase: OperationProgressPhase, success: Bool? = nil) {
        FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase, success: success)
    }
    /// Bind a returned history identity to this worker, independent of UI
    /// coalescing. The ID proves no commit and grants no access or action.
    func observeHistoryRecord(_ recordID: UUID) {
        lock.withLock {
            guard !terminal else { return }
            FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase,
                recordID: recordID)
        }
    }
    /// Observe one actual caught failure without retaining the Error. The
    /// existing optional, nonthrowing sink cannot authorize or settle any work.
    func observeCaughtFailure(_ checkpoint: OperationDiagnosticCheckpoint, error: Error, recordID: UUID? = nil,
                              nativeTrashFinding: NativeTrashFamilyFinding? = nil) {
        let failure = OperationDiagnosticFailure(error: error)
        lock.withLock {
            guard !terminal else { return }
            FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase,
                checkpoint: checkpoint, failure: failure, recordID: recordID,
                nativeTrashFinding: nativeTrashFinding)
        }
    }
    /// One durable inverse observation. A true success here belongs to this
    /// step's recorded image, not to the whole operation's terminal result.
    func observeNativeTrashInverseChange(_ finding: NativeTrashFamilyFinding, recordID: UUID) {
        lock.withLock {
            guard !terminal else { return }
            FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase,
                success: true, checkpoint: .nativeTrashInverseObservedChange,
                recordID: recordID, nativeTrashFinding: finding)
        }
    }
    func observeNativeError(_ code: Int32) {
        lock.withLock {
            // Optional absence probes can be handled successfully by callers.
            // Keep their first numeric status per phase, not thousands of
            // duplicate 'errors' that would hide the actual terminal result.
            var codes = nativeCodes[phase] ?? []
            guard codes.count < 8, codes.insert(code).inserted else { return }
            nativeCodes[phase] = codes
            FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase, nativeError: code)
        }
    }
    func observeSQLiteFailure(_ code: Int32) {
        lock.withLock {
            guard !terminal else { return }
            FileOperationDiagnostics.emit(jobID: jobID, ordinal: diagnosticSequence.next(), phase: phase,
                checkpoint: .textRecordSQLite, failure: .sqlite(code))
        }
    }
    private func emit(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard progressCadence.shouldPublish(at: now, immediately: force) else { return }
        var speed: Double?
        if phase == .copying {
            samples.append((now, bytes)); samples.removeAll { now - $0.0 > 3 }
            if samples.count > 16 { samples.removeFirst(samples.count - 16) }
            if let first = samples.first, now - first.0 >= 0.2, bytes > first.1 { speed = Double(bytes - first.1) / (now - first.0) }
        }
        let eta = speed.flatMap { rate in totalBytes.map { Double(max(0, $0 - bytes)) / rate } }
        pending = OperationProgress(jobID: jobID, sequence: sequence.next(), phase: stopped && !terminal ? .stopping : phase,
            source: source, destination: destination, currentItem: currentItem, itemIndex: itemIndex, itemCount: itemCount,
            bytesCompleted: totalBytes == nil ? nil : bytes, bytesTotal: totalBytes,
            itemsCompleted: totalItems == nil ? nil : items, itemsTotal: totalItems,
            bytesPerSecond: speed, estimatedRemainingTime: eta, isTerminal: terminal, cancellationRequested: stopped)
        guard !scheduled else { return }
        scheduled = true
        delivery.async { self.drain() }
    }
    private func drain() {
        while true {
            let next: (OperationProgress, (@Sendable (OperationProgress) -> Void)?)? = lock.withLock {
                guard let value = pending else { scheduled = false; return nil }
                pending = nil; return (value, callback)
            }
            guard let (value, callback) = next else { return }
            callback?(value)
        }
    }
}

internal enum OperationLimits {
    static let maximumNodes = 50_000
    static let maximumDepth = 64
    static let maximumSubmissions = 16
}

/// One budget is shared across a resolved batch, so many small roots cannot bypass admission.
internal final class TraversalBudget {
    private(set) var nodes = 0
    private(set) var bytes: Int64 = 0
    #if DEBUG
    private let maximumObservedNodes: Int
    private let maximumObservedLogicalBytes: Int64
    init(maximumObservedNodes: Int = OperationLimits.maximumNodes, maximumObservedLogicalBytes: Int64 = Int64.max) {
        self.maximumObservedNodes = maximumObservedNodes
        self.maximumObservedLogicalBytes = maximumObservedLogicalBytes
    }
    #endif
    #if DEBUG
    var remaining: Int { max(0, min(OperationLimits.maximumNodes, maximumObservedNodes) - nodes) }
    #else
    var remaining: Int { OperationLimits.maximumNodes - nodes }
    #endif
    func consume(_ snapshot: EntrySnapshot, depth: Int) throws {
        guard depth < OperationLimits.maximumDepth, nodes < OperationLimits.maximumNodes else { throw FileOperationFailure.unsupported }
        #if DEBUG
        guard nodes < maximumObservedNodes else { throw FileOperationFailure.unsupported }
        #endif
        nodes += 1
        if snapshot.type == 0o100000 {
            let (sum, overflow) = bytes.addingReportingOverflow(max(0, snapshot.size))
            guard !overflow else { throw FileOperationFailure.unsupported }
            #if DEBUG
            // Observed logical sizes are admitted before VerifiedTree opens or
            // reads this node. Existing metadata limits remain independent.
            guard sum <= maximumObservedLogicalBytes else { throw FileOperationFailure.unsupported }
            #endif
            bytes = sum
        }
    }
}
