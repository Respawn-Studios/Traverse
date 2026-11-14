import Foundation

/// A tiny bridge to the application's existing single-mutation coordinator.
/// It queues at most four editor intents and never starts a second filesystem
/// writer. A cancelled waiter is removed; an admitted owner stays held until
/// its real worker returns and explicitly calls finish.
@MainActor
final class EditorMutationAdmission {
    enum Failure: Error { case unavailable, closed }
    private struct Waiting {
        let id: UUID
        let continuation: CheckedContinuation<UUID, any Error>
    }
    private let begin: (UUID) -> Bool
    private let end: (UUID) -> Void
    private var waiting: [Waiting] = []
    private var active: UUID?
    private var closed = false

    init(begin: @escaping (UUID) -> Bool, end: @escaping (UUID) -> Void) {
        self.begin = begin; self.end = end
    }
    var waitingCount: Int { waiting.count }
    var hasActiveOwner: Bool { active != nil }

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard waiting.count < 4 else { throw Failure.unavailable }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                waiting.append(.init(id: id, continuation: continuation))
                workDidChange()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        }
    }
    func finish(_ id: UUID) {
        precondition(active == id, "Only the admitted editor worker can finish")
        active = nil
        end(id)
        workDidChange()
    }
    func workDidChange() {
        guard !closed, active == nil, let first = waiting.first else { return }
        guard begin(first.id) else { return }
        waiting.removeFirst(); active = first.id
        first.continuation.resume(returning: first.id)
    }
    /// Closing an admission queue never claims an active worker has drained.
    /// The application must wait for hasActiveOwner=false before termination.
    func closeWaiters() {
        closed = true
        let cancelled = waiting; waiting = []
        for item in cancelled { item.continuation.resume(throwing: CancellationError()) }
    }
    func resumeAfterCancelledTermination() {
        closed = false; workDidChange()
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let item = waiting.remove(at: index)
        item.continuation.resume(throwing: CancellationError())
        workDidChange()
    }
}
