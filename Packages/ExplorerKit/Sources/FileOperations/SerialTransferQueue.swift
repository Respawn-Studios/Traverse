import Foundation

/// Session-only FIFO admission, explicit waiting priority and advancement. The application owns payloads,
/// access leases, workers and results. Callers serialize access to this value;
/// no filesystem work or native presentation happens inside its transitions.
public struct SerialTransferQueue: Sendable {
    public enum WaitingPhase: Equatable, Sendable { case preparing, ready }

    public struct WaitingJob: Equatable, Sendable {
        public let id: UUID
        public fileprivate(set) var phase: WaitingPhase
    }

    public struct ActiveJob: Equatable, Sendable {
        public let id: UUID
        public fileprivate(set) var stopRequested: Bool
    }

    /// A clean terminal outcome permits advancement. Stopped or unresolved work
    /// pauses later jobs until the user explicitly resumes the queue.
    public enum Disposition: Equatable, Sendable { case succeeded, cancelled, needsReview }

    public struct State: Equatable, Sendable {
        public let active: ActiveJob?
        public let waiting: [WaitingJob]
        public let isPaused: Bool
        public let outstandingCount: Int
        public let canReserve: Bool
    }

    public let maximumOutstandingJobs: Int
    private var active: ActiveJob?
    private var waiting: [WaitingJob] = []
    private var isPaused = false

    public init(maximumOutstandingJobs: Int = 16) {
        precondition(maximumOutstandingJobs > 0)
        self.maximumOutstandingJobs = maximumOutstandingJobs
    }

    public var snapshot: State {
        let count = waiting.count + (active == nil ? 0 : 1)
        return State(active: active, waiting: waiting, isPaused: isPaused,
                     outstandingCount: count, canReserve: count < maximumOutstandingJobs)
    }

    /// Reserve before asynchronous observation, preserving gesture order even
    /// when a later admission finishes preparation sooner. IDs must be fresh.
    @discardableResult
    public mutating func reserve(_ id: UUID) -> Bool {
        guard snapshot.canReserve, active?.id != id, !waiting.contains(where: { $0.id == id }) else { return false }
        waiting.append(WaitingJob(id: id, phase: .preparing))
        return true
    }

    @discardableResult
    public mutating func markReady(_ id: UUID) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        waiting[index].phase = .ready
        return true
    }

    /// A removed admission rejects late observation completion. Active work
    /// requires Stop and worker drain, and cannot be canceled through this API.
    @discardableResult
    public mutating func cancelWaiting(_ id: UUID) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        waiting.remove(at: index)
        return true
    }

    /// One explicit priority step over the exact displayed waiting order.
    /// Preparation, active ownership and pause/review state remain unchanged.
    @discardableResult
    public mutating func moveWaiting(_ id: UUID, offset: Int, expectedOrder: [UUID]) -> Bool {
        guard offset == -1 || offset == 1, expectedOrder.count == waiting.count,
              expectedOrder == waiting.map(\.id), let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard waiting.indices.contains(target) else { return false }
        let value = waiting.remove(at: index); waiting.insert(value, at: target)
        return true
    }

    public mutating func startNext() -> UUID? {
        guard active == nil, !isPaused, let head = waiting.first, head.phase == .ready else { return nil }
        waiting.removeFirst()
        active = ActiveJob(id: head.id, stopRequested: false)
        return head.id
    }

    /// Pause before requesting cancellation of the application-owned task. A
    /// successful safe-step completion after Stop must not start another job.
    @discardableResult
    public mutating func requestStop(_ id: UUID) -> Bool {
        guard active?.id == id else { return false }
        isPaused = true
        active?.stopRequested = true
        return true
    }

    /// Call only after the matching worker has returned, including its unwind.
    /// Terminal progress by itself does not establish that drain boundary.
    @discardableResult
    public mutating func finish(_ id: UUID, disposition: Disposition) -> Bool {
        guard active?.id == id else { return false }
        active = nil
        if disposition != .succeeded { isPaused = true }
        return true
    }

    public mutating func pause() { isPaused = true }

    @discardableResult
    public mutating func resume() -> Bool {
        guard active?.stopRequested != true else { return false }
        isPaused = false
        return true
    }
}
