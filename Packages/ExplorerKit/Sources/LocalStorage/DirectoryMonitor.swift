import Darwin
import Dispatch
import ExplorerCore
import Foundation

public enum DirectoryMonitorEvent: Sendable {
    case changed
    case invalidated
    case unavailable(LocalStorageError)
}

/// Observes one directory vnode, without polling, recursion, or content reads.
/// Membership and directory-attribute changes are observed; changes to every child's
/// contents or metadata are not guaranteed. Notifications may coalesce.
public final class DirectoryMonitor: @unchecked Sendable {
    private let starts: OperationQueue
    private let activityGate: FileActivityGate?
    private let events = DispatchQueue(label: "MacExplorer.DirectoryMonitor.Events", qos: .utility)

    public init(maximumConcurrentStarts: Int = 2, activityGate: FileActivityGate? = nil) {
        self.activityGate = activityGate
        starts = OperationQueue()
        starts.name = "MacExplorer.DirectoryMonitor.Starts"
        starts.maxConcurrentOperationCount = min(8, max(1, maximumConcurrentStarts))
        starts.qualityOfService = .utility
    }

    /// Callbacks run on a serial background queue and should return promptly.
    /// Retains access until the actual open/close worker and cancellation handler finish.
    public func observe(_ directory: URL, retaining lifetime: (any Sendable)? = nil,
                        onEvent: @escaping @Sendable (DirectoryMonitorEvent) -> Void) -> DirectoryObservation {
        let state = DirectoryObservationState(directory: directory, events: events, lifetime: lifetime,
                                              activityGate: activityGate, callback: onEvent)
        let observation = DirectoryObservation(state: state)
        starts.addOperation { state.start() }
        return observation
    }
}

public final class DirectoryObservation: @unchecked Sendable {
    private let state: DirectoryObservationState
    fileprivate init(state: DirectoryObservationState) { self.state = state }

    /// Prevents further callbacks from starting. A callback may safely cancel itself.
    /// FD closure is asynchronous; await waitUntilStopped before releasing outside access.
    public func cancel() { state.cancel() }
    /// True only after the vnode source is installed. Cancelled/failed starts return false.
    public func waitUntilStarted() async -> Bool { await state.waitUntilStarted() }
    public func waitUntilStopped() async { await state.waitUntilStopped() }
    deinit { state.cancel() }
}

private final class DirectoryObservationState: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let directory: URL
    private let events: DispatchQueue
    private var lifetime: (any Sendable)?
    private let activityGate: FileActivityGate?
    private var activity: FileActivityGate.Lease?
    private var callback: (@Sendable (DirectoryMonitorEvent) -> Void)?
    private var source: (any DispatchSourceFileSystemObject)?
    private var started = false
    private var cancelled = false
    private var stopped = false
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []

    init(directory: URL, events: DispatchQueue, lifetime: (any Sendable)?, activityGate: FileActivityGate?,
         callback: @escaping @Sendable (DirectoryMonitorEvent) -> Void) {
        self.directory = directory
        self.events = events
        self.lifetime = lifetime
        self.activityGate = activityGate
        self.callback = callback
    }

    func start() {
        lock.lock()
        guard !cancelled, !stopped else { lock.unlock(); return }
        started = true
        lock.unlock()
        do { activity = try activityGate?.begin() }
        catch { fail(.busy); return }
        guard directory.isFileURL else { fail(.unavailable); return }
        // O_DIRECTORY and NONBLOCK avoid opening a FIFO as a blocking data stream.
        let fd = directory.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_EVTONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { fail(monitorError(errno)); return }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            let error = monitorError(errno)
            close(fd)
            fail(error)
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            close(fd)
            fail(.notDirectory)
            return
        }
        lock.lock()
        guard !cancelled, !stopped else { lock.unlock(); close(fd); finish(); return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: events)
        self.source = source
        source.setEventHandler { [weak self] in self?.receive() }
        // The source retains state until close completes, even when the observation is dropped.
        source.setCancelHandler { [self] in close(fd); finish() }
        source.activate()
        ready = true
        let continuations = startWaiters
        startWaiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: true) }
    }

    private func receive() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !stopped, let source else { return }
        let flags = source.data
        if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
            callback?(.invalidated)
            cancel()
        } else if !flags.intersection([.write, .attrib]).isEmpty {
            callback?(.changed)
        }
    }

    private func fail(_ error: LocalStorageError) {
        // Keep every callback on the same background queue, including open failures.
        events.async { [self] in
            lock.lock()
            if !cancelled, !stopped { callback?(.unavailable(error)) }
            lock.unlock()
            finish()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let source = source
        let canFinish = !started
        lock.unlock()
        if let source { source.cancel() }
        else if canFinish { finish() }
        // If opening, the worker rejects its stale result and closes before finishing.
    }

    private func finish() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        source = nil
        callback = nil
        lifetime = nil
        activity = nil
        let continuations = waiters
        let pendingStarts = startWaiters
        waiters.removeAll()
        startWaiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume() }
        for continuation in pendingStarts { continuation.resume(returning: false) }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled || stopped { lock.unlock(); continuation.resume(returning: false) }
            else if ready { lock.unlock(); continuation.resume(returning: true) }
            else { startWaiters.append(continuation); lock.unlock() }
        }
    }
}

private func monitorError(_ code: Int32) -> LocalStorageError {
    switch code {
    case EACCES, EPERM: .accessDenied
    case ENOENT: .notFound
    case ENOTDIR: .notDirectory
    default: .unavailable
    }
}
