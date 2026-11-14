import Foundation

/// One actual saved-result read plus one replaceable pending hover. Cancelling
/// a pointer demand suppresses its callback without pretending the reader ended.
@MainActor final class RecordedHoverLookup {
    private struct Request {
        let id = UUID()
        let owner: UUID
        let read: @MainActor () async -> FolderSummaryValue?
        let receive: @MainActor (FolderSummaryValue?) -> Void
    }
    private var active: (id: UUID, owner: UUID, task: Task<Void, Never>)?
    private var pending: Request?
    private var latest: (id: UUID, owner: UUID)?
    var hasWork: Bool { active != nil || pending != nil }

    func request(owner: UUID, read: @escaping @MainActor () async -> FolderSummaryValue?,
                 receive: @escaping @MainActor (FolderSummaryValue?) -> Void) {
        let request = Request(owner: owner, read: read, receive: receive)
        latest = (request.id, owner); pending = request; startIfIdle()
    }
    func cancel(owner: UUID) {
        if pending?.owner == owner { pending = nil }
        if latest?.owner == owner { latest = nil }
    }
    func cancelAll() {
        pending = nil; latest = nil; active?.task.cancel()
    }
    func cancelAndDrain() async {
        cancelAll()
        while let task = active?.task { await task.value }
    }
    private func startIfIdle() {
        guard active == nil, let request = pending else { return }
        pending = nil
        let task = Task { [self] in
            let value = await request.read()
            // The same task keeps ownership through the real query and release.
            guard active?.id == request.id else { return }
            active = nil
            if latest?.id == request.id, !Task.isCancelled {
                latest = nil; request.receive(value)
            }
            startIfIdle()
        }
        active = (request.id, request.owner, task)
    }
}
