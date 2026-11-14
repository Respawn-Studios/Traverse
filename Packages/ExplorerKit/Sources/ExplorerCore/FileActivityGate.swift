import Foundation

public enum FileActivityError: Error, Sendable { case admissionClosed, capacity, foreignLease }

/// Per-session ownership only: admitted work remains concurrent on its own
/// executors. No filesystem call occurs while this short bookkeeping lock is held.
public final class FileActivityGate: @unchecked Sendable {
    public struct DrainToken: Equatable, Sendable { fileprivate let id: UUID }
    public final class Lease: Sendable {
        fileprivate let owner: FileActivityGate
        fileprivate init(_ owner: FileActivityGate) { self.owner = owner }
        deinit { owner.finished() }
    }
    private let lock = NSLock()
    private let maximumActivities: Int
    private var active = 0
    private var closedBy: DrainToken?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    public init(maximumActivities: Int = 4_096) { self.maximumActivities = max(1, maximumActivities) }

    public var activeCount: Int { lock.withLock { active } }
    public var isClosed: Bool { lock.withLock { closedBy != nil } }
    /// Check immediately before submitting an uncancellable native request.
    public func ownsDrainedAdmission(_ token: DrainToken) -> Bool {
        lock.withLock { closedBy == token && active == 0 }
    }

    public func begin() throws -> Lease {
        try lock.withLock {
            guard closedBy == nil else { throw FileActivityError.admissionClosed }
            guard active < maximumActivities else { throw FileActivityError.capacity }
            active += 1
            return Lease(self)
        }
    }

    /// A nested step continues the caller's actual admitted lifetime. A
    /// lease from another gate cannot grant admission here.
    public func continueOrBegin(_ admittedBy: Lease?) throws -> Lease {
        guard let admittedBy else { return try begin() }
        guard admittedBy.owner === self else { throw FileActivityError.foreignLease }
        return admittedBy
    }

    public func closeAdmission() -> DrainToken? {
        lock.withLock {
            guard closedBy == nil else { return nil }
            let token = DrainToken(id: UUID()); closedBy = token; return token
        }
    }

    /// Cancellation of the waiting task cannot release actual worker leases.
    public func waitUntilDrained(_ token: DrainToken) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                guard closedBy == token else { return false }
                if active == 0 { return true }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    @discardableResult public func reopen(_ token: DrainToken) -> Bool {
        var resumed: [CheckedContinuation<Bool, Never>] = []
        let accepted = lock.withLock {
            guard closedBy == token else { return false }
            closedBy = nil; resumed = waiters; waiters.removeAll(keepingCapacity: true); return true
        }
        resumed.forEach { $0.resume(returning: false) }
        return accepted
    }

    private func finished() {
        var resumed: [CheckedContinuation<Bool, Never>] = []
        lock.withLock {
            precondition(active > 0)
            active -= 1
            if active == 0 && closedBy != nil { resumed = waiters; waiters.removeAll(keepingCapacity: true) }
        }
        resumed.forEach { $0.resume(returning: true) }
    }
}
