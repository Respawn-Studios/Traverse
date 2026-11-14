import Foundation
import ExplorerCore

/// Nonblocking ingress and exactly one background file owner. A failed logger
/// never changes the file-operation result or bypasses its durability checks.
public final class DiagnosticRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Traverse.DiagnosticHistory", qos: .utility)
    private let lock = NSLock()
    private let directory: URL
    private let limits: DiagnosticHistoryLimits
    private let prepare: (@Sendable () throws -> Void)?
    private let probe: (@Sendable (DiagnosticStorageStage) throws -> Void)?
    private var pending: [DiagnosticEvent] = []
    private var scheduled = false
    private var recording: Bool
    private var closed = false
    private var dropped: UInt64 = 0
    private var failure: DiagnosticHistoryFailure?
    private var files: OwnedDiagnosticFiles? // Serial queue only.
    private var recordedDropped: UInt64 = 0 // Serial queue only.

    public init(directory: URL, limits: DiagnosticHistoryLimits,
                recording: Bool, prepare: (@Sendable () throws -> Void)? = nil) {
        self.directory = directory; self.limits = limits; self.recording = recording
        self.prepare = prepare; probe = nil
    }
    init(directory: URL, limits: DiagnosticHistoryLimits, recording: Bool,
         probe: @escaping @Sendable (DiagnosticStorageStage) throws -> Void) {
        self.directory = directory; self.limits = limits; self.recording = recording
        self.probe = probe; prepare = nil
    }

    public var status: DiagnosticHistoryStatus {
        lock.withLock { .init(recording: recording && !closed && failure == nil,
                             pending: pending.count, dropped: dropped, failure: failure) }
    }

    public func record(_ event: DiagnosticEvent) {
        let submit = lock.withLock { () -> Bool in
            guard recording, !closed else { return false }
            guard failure == nil, event.isValid, pending.count < limits.pendingEvents else {
                if dropped < UInt64.max { dropped += 1 }; return false
            }
            pending.append(event)
            if scheduled { return false }
            scheduled = true; return true
        }
        if submit { queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in drain() } }
    }

    public func setRecording(_ enabled: Bool) {
        lock.withLock { if !closed { recording = enabled } }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain(); do { try files?.synchronize() } catch { note(error, lost: 0) }
                continuation.resume()
            }
        }
    }

    public func page(before: DiagnosticHistoryCursor? = nil, limit: Int = 128,
                     errorsOnly: Bool = false, scope: DiagnosticLogScope = .all,
                     cancellation: DiagnosticExportCancellation = .init()) async throws -> DiagnosticHistoryPage {
        guard (1...256).contains(limit) else { throw DiagnosticHistoryFailure.invalidInput }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                drain()
                do {
                    guard !lock.withLock({ closed }) else { throw DiagnosticHistoryFailure.unavailable }
                    try cancellation.check()
                    // Merely opening history while recording is disabled does
                    // not create a new diagnostic directory.
                    if files == nil && !FileManager.default.fileExists(atPath: directory.path) {
                        continuation.resume(returning: .init(events: [], next: nil, incomplete: false)); return
                    }
                    let owner = try open()
                    try owner.expire(now: Date())
                    let correlation = try DiagnosticCorrelation.collect(scope: scope, cancellation: cancellation) {
                        try owner.page(before: $0, limit: 256, errorsOnly: false)
                    }
                    let result = try correlation.page(before: before, limit: limit, cancellation: cancellation) {
                        try owner.page(before: $0, limit: $1, errorsOnly: errorsOnly, traces: $2)
                    }
                    continuation.resume(returning: result)
                } catch is CancellationError { continuation.resume(throwing: CancellationError()) }
                  catch { continuation.resume(throwing: Self.failure(error)) }
            }
        }
    }

    public func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if lock.withLock({ closed }) { continuation.resume(throwing: DiagnosticHistoryFailure.unavailable); return }
                lock.withLock { pending.removeAll(); scheduled = false }
                do {
                    if files != nil || FileManager.default.fileExists(atPath: directory.path) { try open().clear() }
                    lock.withLock { dropped = 0; failure = nil }; recordedDropped = 0
                    continuation.resume()
                } catch { note(error, lost: 0); continuation.resume(throwing: Self.failure(error)) }
            }
        }
    }

    public func closeAndDrain() async {
        lock.withLock { closed = true }
        await withCheckedContinuation { continuation in
            queue.async { [self] in drain(); files = nil; continuation.resume() }
        }
    }

    public func export(to destination: URL, retainingAccess: any Sendable,
                       cancellation: DiagnosticExportCancellation = .init(),
                       scope: DiagnosticLogScope = .all,
                       metadata: DiagnosticExportMetadata? = nil) async -> DiagnosticExportOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                defer { withExtendedLifetime(retainingAccess) {} }
                guard !lock.withLock({ closed }) else { continuation.resume(returning: .notCreated(.io)); return }
                drain()
                do {
                    try cancellation.check()
                    let owner = try open()
                    try owner.expire(now: Date())
                    let correlation = try DiagnosticCorrelation.collect(scope: scope, cancellation: cancellation) {
                        try owner.page(before: $0, limit: 256, errorsOnly: false)
                    }
                    guard correlation.hasEvents else { continuation.resume(returning: .notCreated(.empty)); return }
                    let outcome = DiagnosticExport.write(to: destination, protected: directory,
                        maximumBytes: limits.bytes, cancellation: cancellation, scope: scope, metadata: metadata) { cursor in
                            try correlation.page(before: cursor, limit: 256, cancellation: cancellation) {
                                try owner.page(before: $0, limit: $1, errorsOnly: false, traces: $2)
                            }
                        }
                    continuation.resume(returning: outcome)
                } catch is CancellationError { continuation.resume(returning: .notCreated(.cancelled)) }
                  catch DiagnosticHistoryFailure.capacity { continuation.resume(returning: .notCreated(.capacity)) }
                  catch { continuation.resume(returning: .notCreated(.io)) }
            }
        }
    }

    private func open() throws -> OwnedDiagnosticFiles {
        if let files { return files }
        try prepare?()
        let owner = try OwnedDiagnosticFiles(directory: directory, limits: limits, probe: probe)
        files = owner; return owner
    }
    private func drain() {
        let snapshot = lock.withLock { () -> ([DiagnosticEvent], UInt64) in
            let values = pending; pending.removeAll(keepingCapacity: true); scheduled = false
            return (values, dropped)
        }
        var events = snapshot.0
        guard !events.isEmpty else { return }
        if snapshot.1 > recordedDropped, let first = events.first {
            events.append(.init(session: first.session, trace: UUID(), action: .historyGap, phase: .gap,
                level: .warning, count: snapshot.1 - recordedDropped, build: first.build))
        }
        do { try open().append(events, now: Date()); recordedDropped = snapshot.1 }
        catch { note(error, lost: events.count) }
    }
    private func note(_ error: Error, lost: Int) {
        lock.withLock {
            failure = Self.failure(error)
            let (value, overflow) = dropped.addingReportingOverflow(UInt64(lost))
            dropped = overflow ? .max : value
        }
    }
    private static func failure(_ error: Error) -> DiagnosticHistoryFailure {
        error as? DiagnosticHistoryFailure ?? .unavailable
    }
}
