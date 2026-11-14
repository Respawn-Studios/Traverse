import Foundation

/// Shared local admission; a staged snapshot holds a user until actual cleanup.
final class SFTPOriginalBaselineLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false, closing = false, users = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func checkAvailable() throws {
        try lock.withLock { guard !claimed, !closing else { throw SFTPTextFailure.closed } }
    }
    func use() throws -> SFTPOriginalBaselineUse {
        try lock.withLock {
            guard !claimed, !closing else { throw SFTPTextFailure.closed }
            guard users < 8 else { throw SFTPTextFailure.busy }
            users += 1; return .init(owner: self)
        }
    }
    func claim() throws {
        try lock.withLock { guard !claimed, !closing else { throw SFTPTextFailure.closed }; claimed = true }
    }
    func beginUnusedClose() throws {
        try lock.withLock { guard !claimed else { throw SFTPTextFailure.busy }; closing = true }
    }
    fileprivate func releaseUser() {
        let done = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(users > 0); users -= 1
            guard users == 0 else { return [] }; let result = waiters; waiters.removeAll(); return result
        }
        done.forEach { $0.resume() }
    }
    func joinUsers() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if users == 0 { return true }; waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
}
final class SFTPOriginalBaselineUse: @unchecked Sendable {
    private let owner: SFTPOriginalBaselineLifetime, lock = NSLock()
    private var ended = false
    fileprivate init(owner: SFTPOriginalBaselineLifetime) { self.owner = owner }
    func release() { if lock.withLock({ if ended { return false }; ended = true; return true }) { owner.releaseUser() } }
    deinit { release() }
}

enum SFTPOriginalWorkerRetirement: Sendable, Equatable { case acknowledged, sessionInvalidated }
enum SFTPOriginalUnusedCloseResult: Sendable, Equatable {
    case pending, needsReview, closedUnusedCopyRemoved(SFTPOriginalWorkerRetirement)
}

/// One opaque release request. Only the concrete parent decoder may feed189;
/// the ordinary UI never supplies a callback, token, path or close receipt.
final class SFTPOriginalUnusedClose: @unchecked Sendable {
    let request = UUID()
    private let session: UUID, token: UUID, revision: UInt64, editorID: UUID
    private let reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog
    private let lifetime: SFTPOriginalBaselineLifetime, lock = NSLock()
    private var preparation: Task<Data, Error>?, cleanup: Task<SFTPOriginalUnusedCloseResult, Never>?
    private var preparationID: UUID?, cleanupID: UUID?
    private var issued = false, retirement: SFTPOriginalWorkerRetirement?, completed: SFTPOriginalUnusedCloseResult?
    private var bufferClosed = false
    private var protocolFailed = false
    init(session: UUID, token: UUID, revision: UInt64, editorID: UUID,
         reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog, lifetime: SFTPOriginalBaselineLifetime) {
        self.session = session; self.token = token; self.revision = revision; self.editorID = editorID
        self.reference = reference; self.catalog = catalog; self.lifetime = lifetime
    }
    /// Command48 payload only. Envelope/session/sequence stay in the sole owner.
    func command() async throws -> Data {
        let current = lock.withLock { () -> (Task<Data, Error>, UUID) in
            if let preparation, let preparationID { return (preparation, preparationID) }
            let id = UUID()
            let work = Task { [catalog, editorID, reference, request, token, revision, lifetime] in
                await lifetime.joinUsers()
                try await catalog.releasePending(editorID, reference: reference)
                var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(token))
                SFTPWire.number(revision, bytes: 8, into: &bytes); return bytes
            }
            preparation = work; preparationID = id; return (work, id)
        }
        do {
            let bytes = try await current.0.value
            try Task.checkCancellation(); lock.withLock { issued = true }; return bytes
        }
        catch { lock.withLock { if preparationID == current.1 { preparation = nil; preparationID = nil } }; throw error }
    }
    func observedReleaseOnSessionExecutor(_ payload: Data, session actual: UUID) throws {
        try lock.withLock {
            guard issued, completed == nil, retirement == nil, !protocolFailed else { throw SFTPProtocolFailure.phase }
            do {
                guard actual == session else { throw SFTPProtocolFailure.invalidOutput }
                var cursor = SFTPCursor(payload)
                guard try cursor.token() == request, try cursor.token() == token,
                      try cursor.number(8) == revision else { throw SFTPProtocolFailure.invalidOutput }
                let result = try cursor.number(1)
                guard cursor.finished, result == 1 || result == 2 else { throw SFTPProtocolFailure.invalidOutput }
                retirement = .acknowledged
            } catch { protocolFailed = true; throw error }
        }
    }
    /// Not a protocol terminal or a timer: only the actual process owner can
    /// pass its real child-exit+IPC-EOF observation at this internal seam.
    func afterActualSessionDrain(_ end: SFTPWorkerClose, session actual: UUID) throws {
        try lock.withLock {
            guard actual == session, end.localResourcesEnded else { throw SFTPTextFailure.busy }
            if retirement == nil { retirement = .sessionInvalidated }
        }
    }
    /// Only the document owner calls this after AppKit's terminal buffer close
    /// (or when no App buffer was ever installed) and its pin has drained.
    func markActualBufferClosed() { lock.withLock { bufferClosed = true } }
    var readyForActualBufferClose: Bool { lock.withLock { retirement != nil && issued && !protocolFailed } }
    func finishAfterLocalDrain() async -> SFTPOriginalUnusedCloseResult {
        if lock.withLock({ retirement == .sessionInvalidated && !issued }) {
            // Durable local intent only; no command is written after session end.
            do { _ = try await command() } catch { return .needsReview }
        }
        let current = lock.withLock { () -> (SFTPOriginalUnusedCloseResult?, Task<SFTPOriginalUnusedCloseResult, Never>?, UUID?) in
            if let completed { return (completed, nil, nil) }
            guard let retirement, issued, bufferClosed else { return (.pending, nil, nil) }
            if let cleanup, let cleanupID { return (nil, cleanup, cleanupID) }
            let id = UUID()
            let work = Task { [lifetime, catalog, editorID, reference] in
                await lifetime.joinUsers()
                do { try await catalog.removeUnusedAfterDrain(editorID, reference: reference); return SFTPOriginalUnusedCloseResult.closedUnusedCopyRemoved(retirement) }
                catch { return .needsReview }
            }
            cleanup = work; cleanupID = id; return (nil, work, id)
        }
        if let immediate = current.0 { return immediate }
        guard let task = current.1, let id = current.2 else { return .pending }
        let result = await task.value
        lock.withLock {
            guard cleanupID == id else { return }
            if case .closedUnusedCopyRemoved = result { completed = result }
            // Safe failure creates no permanently cached false terminal.
            cleanup = nil; cleanupID = nil
        }
        return result
    }
}
