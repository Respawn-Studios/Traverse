import Foundation

/// Ephemeral observations, never an access grant. Own one active generation in a
/// view and cancel it before replacing the query, scope, policy, or view itself.
public final class SearchSession: Sendable {
    public let id: UUID
    public let policyRevision: UInt64
    public let events: AsyncStream<SearchEvent>
    let state: SearchSessionState
    public var generation: SearchGeneration { SearchGeneration(sessionID: id, policyRevision: policyRevision) }

    init(roots: [URL], policy: SearchPolicy, source: SearchSource) {
        let pair = AsyncStream<SearchEvent>.makeStream()
        id = UUID()
        policyRevision = policy.revision
        events = pair.stream
        state = SearchSessionState(id: id, policy: policy, roots: roots, source: source, continuation: pair.continuation)
        pair.continuation.onTermination = { [state] _ in state.cancel() }
    }
    public func cancel() { state.cancel() }
}

/// Every publication and cancellation uses the same lock, so no batch can be
/// published after cancellation. Finite result/issue limits bound the stream's
/// retained events even when a consumer stops reading without cancelling.
final class SearchSessionState: @unchecked Sendable {
    // AsyncStream invokes onTermination synchronously from finish().
    private let lock = NSRecursiveLock()
    private let id: UUID
    let policy: SearchPolicy
    private let continuation: AsyncStream<SearchEvent>.Continuation
    private var coverage: SearchCoverage
    private var stopped = false
    private var pending: [SearchMatch] = []
    private var cancellationAction: (@Sendable () -> Void)?
    private let began = ContinuousClock.now
    private var lastProgress = Duration.zero
    private var lastProgressCounts: [Int] = []

    init(id: UUID, policy: SearchPolicy, roots: [URL], source: SearchSource,
         continuation: AsyncStream<SearchEvent>.Continuation) {
        self.id = id; self.policy = policy; self.continuation = continuation
        coverage = SearchCoverage(roots: roots, source: source)
    }
    var isStopped: Bool {
        lock.withLock {
            if !stopped {
                let elapsed = began.duration(to: .now)
                if elapsed >= .seconds(policy.maximumDuration) { finishLocked(.timedOut) }
                else { publishProgressLocked(elapsed: elapsed) }
            }
            return stopped
        }
    }
    func onCancel(_ action: @escaping @Sendable () -> Void) {
        let call = lock.withLock {
            if stopped { return true }
            cancellationAction = action
            return false
        }
        if call { action() }
    }
    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !stopped else { return nil }
            let action = cancellationAction
            finishLocked(.cancelled)
            return action
        }
        action?()
    }
    func setRoots(_ roots: [URL]) {
        lock.withLock {
            guard !stopped else { return }
            coverage.requestedRoots = roots
        }
    }
    func visit() -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            guard coverage.visitedEntries < policy.maximumVisitedEntries else {
                finishLocked(.traversalLimit); return false
            }
            coverage.visitedEntries += 1
            return true
        }
    }
    func directory() { lock.withLock { if !stopped { coverage.searchedDirectories += 1 } } }
    func issue(_ url: URL, _ reason: SearchBoundary) {
        lock.withLock {
            guard !stopped else { return }
            coverage.boundaryCounts[reason, default: 0] += 1
            if coverage.issues.count < policy.maximumIssues { coverage.issues.append(SearchIssue(url: url, reason: reason)) }
            else { coverage.omittedIssues += 1 }
        }
    }
    func match(_ entry: SearchMatch) {
        lock.withLock {
            guard !stopped else { return }
            pending.append(entry)
            coverage.matchedEntries += 1
            // The first useful row should not wait for a full batch or scan end.
            if coverage.matchedEntries == 1 || pending.count >= policy.batchSize { flushLocked() }
            if coverage.matchedEntries >= policy.maximumResults { finishLocked(.resultLimit) }
        }
    }
    func finish(_ completion: SearchCompletion = .completed) {
        lock.withLock { if !stopped { finishLocked(completion) } }
    }
    private func publishProgressLocked(elapsed: Duration) {
        guard !stopped, elapsed - lastProgress >= .milliseconds(250) else { return }
        let counts = [coverage.visitedEntries, coverage.searchedDirectories, coverage.matchedEntries,
            coverage.boundaryCounts.values.reduce(0, +)]
        guard counts != lastProgressCounts, counts.contains(where: { $0 > 0 }) else { return }
        // Deliver the already-observed small batch before its accompanying
        // counts. A slow, sparse search must not retain 127 useful rows.
        flushLocked()
        guard !stopped else { return }
        lastProgress = elapsed; lastProgressCounts = counts
        continuation.yield(SearchEvent(sessionID: id, policyRevision: policy.revision, payload: .progress(coverage)))
    }
    private func flushLocked() {
        guard !pending.isEmpty else { return }
        continuation.yield(SearchEvent(sessionID: id, policyRevision: policy.revision, payload: .batch(pending)))
        pending.removeAll(keepingCapacity: true)
    }
    private func finishLocked(_ completion: SearchCompletion) {
        flushLocked()
        stopped = true
        cancellationAction = nil
        coverage.completion = completion
        coverage.finishedAt = Date()
        continuation.yield(SearchEvent(sessionID: id, policyRevision: policy.revision, payload: .finished(coverage)))
        continuation.finish()
    }
}
