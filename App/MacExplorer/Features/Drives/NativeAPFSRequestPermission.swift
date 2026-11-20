import ExplorerCore
import Foundation

/// Add and Format share the same submission boundary. The native callback marks
/// submission synchronously; a delayed UI update cannot reopen cancellation.
/// Every mutable field is protected by this short bookkeeping lock.
final class NativeAPFSRequestPermission: @unchecked Sendable {
    private let lock = NSLock()
    private let activity: FileActivityGate
    private var enabled = false
    private var submitted = false
    private var token: FileActivityGate.DrainToken?
    private var protectionCurrent: (@Sendable () -> Bool)?

    init(activity: FileActivityGate = ApplicationFileActivity.gate) { self.activity = activity }

    var wasSubmitted: Bool { lock.withLock { submitted } }
    var allowed: Bool {
        let state = lock.withLock { (enabled, token, protectionCurrent) }
        guard state.0 else { return false }
        guard let token = state.1 else { return true }
        return activity.ownsDrainedAdmission(token) && state.2?() == true
    }
    func start() {
        lock.withLock { enabled = true; submitted = false; token = nil; protectionCurrent = nil }
    }
    func requireDrained(_ token: FileActivityGate.DrainToken,
                        protectionCurrent: @escaping @Sendable () -> Bool) {
        lock.withLock { self.token = token; self.protectionCurrent = protectionCurrent }
    }
    func markSubmitted() { lock.withLock { submitted = true } }
    @discardableResult
    func cancelBeforeSubmission() -> Bool {
        lock.withLock {
            guard !submitted else { return false }
            enabled = false; token = nil; protectionCurrent = nil
            return true
        }
    }
    /// Only an idle review or the actual request's terminal owner resets this.
    func reset() {
        lock.withLock { enabled = false; submitted = false; token = nil; protectionCurrent = nil }
    }
}
