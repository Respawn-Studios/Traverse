import Foundation

/// The comparison and history windows serialize their own requests. A stopped
/// request owns its slot until the read really returns.
@MainActor final class GitReviewRequest {
    private var task: Task<Void, Never>?
    private var closed = false
    var isRunning: Bool { task != nil }

    isolated deinit { task?.cancel() }

    func start<Value: Sendable>(preservesOutcome: Bool = false, _ read: @escaping @MainActor () async throws -> Value,
                                accept: @escaping @MainActor (Result<Value, Error>) -> Void) {
        guard !closed, task == nil else { return }
        task = Task { [weak self] in
            let result: Result<Value, Error>
            do {
                let value = try await read()
                if !preservesOutcome { try Task.checkCancellation() }
                result = .success(value)
            } catch {
                result = .failure(!preservesOutcome && Task.isCancelled ? CancellationError() : error)
            }
            guard let self else { return }
            task = nil
            if !closed { accept(result) }
        }
    }

    func stop() { task?.cancel() }

    func close() {
        closed = true
        task?.cancel()
    }

    func closeAndDrain() async {
        close()
        await task?.value
    }
}
