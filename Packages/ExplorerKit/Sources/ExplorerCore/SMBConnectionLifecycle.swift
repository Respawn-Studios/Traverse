import Foundation

public enum SMBConnectionProblem: String, Error, Equatable, Sendable {
    case busy, authentication, denied, unavailable, invalidResult, writableMount, notSMB, changed
}

/// Finite request bookkeeping only. Native code must separately prove the real
/// mount identity/read-only flags and retain actual request/reader lifetimes.
public struct SMBConnectionLifecycle: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, connecting, checkingMount, connectedReadOnly, userCancelled
        case failed(SMBConnectionProblem), outcomeUncertain, finishingClosedView, closed
    }
    public enum MountResult: Sendable { case mounted(count: Int), userCancelled, failed(SMBConnectionProblem) }
    public enum Effect: Equatable, Sendable { case none, verifySingleMount(UUID) }
    public private(set) var phase = Phase.idle
    public private(set) var requestID: UUID?
    public private(set) var address: SMBShareAddress?
    public private(set) var viewIsOpen = true
    public private(set) var nativeRequestPending = false
    public private(set) var verificationPending = false
    private var readerID: UUID?
    public var readerPending: Bool { readerID != nil }
    public var hasOutstandingWork: Bool { nativeRequestPending || verificationPending || readerPending }
    public var canConnect: Bool { viewIsOpen && !hasOutstandingWork && phase != .connectedReadOnly }
    public var canRead: Bool { viewIsOpen && phase == .connectedReadOnly && !readerPending }
    public init() {}

    @discardableResult public mutating func begin(_ address: SMBShareAddress) throws -> UUID {
        guard canConnect else { throw SMBConnectionProblem.busy }
        let id = UUID(); requestID = id; self.address = address; nativeRequestPending = true; phase = .connecting
        return id
    }
    /// Immediate submission failure cannot be turned into a later success by a
    /// duplicate callback. Native submission success alone changes nothing.
    @discardableResult public mutating func submissionFailed(_ id: UUID, problem: SMBConnectionProblem) -> Bool {
        guard requestID == id, nativeRequestPending else { return false }
        nativeRequestPending = false; phase = viewIsOpen ? .failed(problem) : .closed
        if !viewIsOpen { address = nil }; return true
    }
    public mutating func completed(_ id: UUID, result: MountResult) -> Effect {
        guard requestID == id, nativeRequestPending else { return .none }
        nativeRequestPending = false
        guard viewIsOpen else { address = nil; phase = .closed; return .none }
        switch result {
        case .mounted(count: 1): verificationPending = true; phase = .checkingMount; return .verifySingleMount(id)
        case .mounted: phase = .failed(.invalidResult)
        case .userCancelled: phase = .userCancelled
        case .failed(let problem): phase = .failed(problem)
        }
        return .none
    }
    /// This event is accepted only from the native verifier's current request.
    /// A nil problem does not itself grant access or prove mount ownership.
    @discardableResult public mutating func verified(_ id: UUID, problem: SMBConnectionProblem?) -> Bool {
        guard requestID == id, verificationPending else { return false }
        verificationPending = false
        if !viewIsOpen { address = nil; phase = .closed }
        else { phase = problem.map(Phase.failed) ?? .connectedReadOnly }
        return true
    }
    @discardableResult public mutating func deadlinePassed(_ id: UUID) -> Bool {
        guard requestID == id, nativeRequestPending else { return false }
        phase = viewIsOpen ? .outcomeUncertain : .finishingClosedView
        return true
    }
    /// Each actual read owns a distinct completion token, separate from the
    /// connection request. Sequential reads must reject duplicate old exits.
    @discardableResult public mutating func beginRead() -> UUID? {
        guard canRead, requestID != nil else { return nil }
        let id = UUID(); readerID = id; return id
    }
    /// Called by actual worker exit, never just task/stream cancellation.
    @discardableResult public mutating func readerFinished(_ id: UUID, problem: SMBConnectionProblem? = nil) -> Bool {
        guard readerID == id else { return false }; readerID = nil
        if !viewIsOpen { address = nil; phase = .closed }
        else if let problem { phase = .failed(problem) }
        return true
    }
    public mutating func closeView() {
        viewIsOpen = false
        phase = hasOutstandingWork ? .finishingClosedView : .closed
        if !hasOutstandingWork { address = nil }
    }
}
