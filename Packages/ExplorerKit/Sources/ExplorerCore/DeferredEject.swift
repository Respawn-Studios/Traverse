import Foundation

public enum EjectNewWorkPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case requireCancel, cancelEject
    public var id: Self { self }
    public var title: String {
        switch self {
        case .requireCancel: "Require Cancel Eject before adding jobs"
        case .cancelEject: "New work cancels pending eject"
        }
    }
}

/// Session-only intent. Its caller owns device observations and actual worker
/// drain; this model cannot submit an OS action or infer that work has drained.
public struct DeferredEject: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case waiting, needsAttention, draining, submitted, finished, cancelled }
    public let id: UUID
    public let policy: EjectNewWorkPolicy
    public let cohort: Set<UUID>
    public private(set) var remaining: Set<UUID>
    public private(set) var phase: Phase

    public init(cohort: Set<UUID>, policy: EjectNewWorkPolicy, id: UUID = UUID()) {
        self.id = id; self.policy = policy; self.cohort = cohort; remaining = cohort
        phase = cohort.isEmpty ? .draining : .waiting
    }

    public mutating func update(outstanding: Set<UUID>, needsAttention: Bool) {
        guard phase == .waiting || phase == .needsAttention || phase == .draining else { return }
        remaining = cohort.intersection(outstanding)
        if needsAttention { phase = .needsAttention }
        else if phase != .needsAttention { phase = remaining.isEmpty ? .draining : .waiting }
    }

    /// Explicit review acknowledgement; merely finishing another job cannot resume eject.
    @discardableResult public mutating func resumeAfterReview() -> Bool {
        guard phase == .needsAttention else { return false }
        phase = remaining.isEmpty ? .draining : .waiting
        return true
    }

    /// Serialize this with submission. A new job never cancels an OS request.
    public mutating func admitNewWork(affected: Bool) -> Bool {
        guard affected else { return true }
        if phase == .finished || phase == .cancelled { return true }
        guard phase != .submitted, policy == .cancelEject else { return false }
        phase = .cancelled
        return true
    }

    @discardableResult public mutating func cancel() -> Bool {
        guard phase != .submitted && phase != .finished && phase != .cancelled else { return false }
        phase = .cancelled
        return true
    }

    @discardableResult public mutating func submit(afterVerifiedDrain drained: Bool) -> Bool {
        guard phase == .draining, remaining.isEmpty, drained else { return false }
        phase = .submitted
        return true
    }

    @discardableResult public mutating func complete(request: UUID) -> Bool {
        guard request == id, phase == .submitted else { return false }
        phase = .finished
        return true
    }
}
