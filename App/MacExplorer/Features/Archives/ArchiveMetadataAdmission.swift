import Foundation

/// Bounds source-directory opening across concrete ZIP and TAR owners. The
/// operation retains its slot until its real asynchronous return, including
/// cancellation; reader implementations still own their off-main I/O queues.
actor ArchiveMetadataAdmission {
    static let shared = ArchiveMetadataAdmission()
    enum Failure: Error, Equatable { case busy }
    struct Activity: Equatable, Sendable { let active: Int; let pending: Int }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var active: UUID?
    private var pending = [Waiter]()
    var activity: Activity { Activity(active: active == nil ? 0 : 1, pending: pending.count) }

    func withAdmission<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let ticket = try await acquire()
        defer { release(ticket) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if active == nil { active = id; return id }
        guard pending.count < 8 else { throw Failure.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // Only a waiting continuation may be removed. An admitted reader
            // retains ownership until withAdmission's operation actually ends.
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ ticket: UUID) {
        precondition(active == ticket)
        if pending.isEmpty { active = nil }
        else {
            let next = pending.removeFirst(); active = next.id
            next.continuation.resume(returning: next.id)
        }
    }
}
