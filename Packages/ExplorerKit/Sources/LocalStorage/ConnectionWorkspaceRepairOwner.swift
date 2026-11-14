import Foundation

/// Register the actual detached work before its first metadata/lock operation.
/// Stop cancels and joins it. A new explicit operation is allowed after drain.
final class ConnectionWorkspaceRepairOwner: @unchecked Sendable {
    enum Value: Sendable { case choice(ConnectionWorkspaceRepairChoice), rebind(ConnectionWorkspaceRebindChoice), done }
    private let lock = NSLock()
    private var active: (UUID, Task<Value, Error>)?
    private var drainers = 0
    func perform(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let (id, task) = try lock.withLock { () throws -> (UUID, Task<Value, Error>) in
            guard active == nil, drainers == 0 else { throw ConnectionWorkspaceFailure.busy }
            let id = UUID(), task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try work() }
            active = (id, task); return (id, task)
        }
        defer { lock.withLock { if active?.0 == id { active = nil } } }
        return try await withTaskCancellationHandler {
            let result = try await task.value; try Task.checkCancellation(); return result
        } onCancel: { task.cancel() }
    }
    func stopAndDrain() async {
        let held = lock.withLock { drainers += 1; return active }
        held?.1.cancel(); if let held { _ = try? await held.1.value }
        lock.withLock { if active?.0 == held?.0 { active = nil }; drainers -= 1 }
    }
}
