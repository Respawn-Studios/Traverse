import Foundation

enum SFTPOriginalRetainedCloseResult: Sendable, Equatable {
    case pending, needsReview, closedVersionsRetained(SFTPOriginalWorkerRetirement)
}

/// Release-only close for a verified successor. Uses the same strict48/189
/// contract, joins local users and never removes a body or journal reference.
final class SFTPOriginalRetainedClose: @unchecked Sendable {
    let request = UUID()
    private let session: UUID, token: UUID, revision: UInt64, editorID: UUID
    private let reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog
    private let lifetime: SFTPOriginalBaselineLifetime, lock = NSLock()
    private var preparation: Task<Data, Error>?, cleanup: Task<SFTPOriginalRetainedCloseResult, Never>?
    private var preparationID: UUID?, cleanupID: UUID?
    private var issued = false, failed = false
    private var retirement: SFTPOriginalWorkerRetirement?, completed: SFTPOriginalRetainedCloseResult?
    init(session: UUID, token: UUID, revision: UInt64, editorID: UUID, reference: SFTPOriginalSpoolReference,
         catalog: SFTPOriginalEditorCatalog, lifetime: SFTPOriginalBaselineLifetime) {
        self.session = session; self.token = token; self.revision = revision; self.editorID = editorID
        self.reference = reference; self.catalog = catalog; self.lifetime = lifetime
    }
    func command() async throws -> Data {
        let current = lock.withLock { () -> (Task<Data, Error>, UUID) in
            if let preparation, let preparationID { return (preparation, preparationID) }
            let id = UUID()
            let work = Task { [catalog, editorID, reference, request, token, revision, lifetime] in
                await lifetime.joinUsers()
                try await catalog.retainedReleasePending(editorID, reference: reference)
                var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(token))
                SFTPWire.number(revision, bytes: 8, into: &bytes); return bytes
            }
            preparation = work; preparationID = id; return (work, id)
        }
        do {
            let bytes = try await current.0.value
            try Task.checkCancellation(); lock.withLock { issued = true }; return bytes
        } catch {
            lock.withLock { if preparationID == current.1 { preparation = nil; preparationID = nil } }; throw error
        }
    }
    func observedReleaseOnSessionExecutor(_ payload: Data, session actual: UUID) throws {
        try lock.withLock {
            guard issued, !failed, retirement == nil, completed == nil else { throw SFTPProtocolFailure.phase }
            do {
                var c = SFTPCursor(payload)
                guard actual == session, try c.token() == request, try c.token() == token,
                      try c.number(8) == revision else { throw SFTPProtocolFailure.invalidOutput }
                let result = try c.number(1)
                guard c.finished, result == 1 || result == 2 else { throw SFTPProtocolFailure.invalidOutput }
                retirement = .acknowledged
            } catch { failed = true; throw error }
        }
    }
    func afterActualSessionDrain(_ end: SFTPWorkerClose, session actual: UUID) throws {
        try lock.withLock {
            guard actual == session, end.localResourcesEnded else { throw SFTPTextFailure.busy }
            if retirement == nil { retirement = .sessionInvalidated }
        }
    }
    func finishAfterLocalDrain() async -> SFTPOriginalRetainedCloseResult {
        if lock.withLock({ retirement == .sessionInvalidated && !issued }) {
            do { _ = try await command() } catch { return .needsReview }
        }
        let current = lock.withLock { () -> (SFTPOriginalRetainedCloseResult?, Task<SFTPOriginalRetainedCloseResult, Never>?, UUID?) in
            if let completed { return (completed, nil, nil) }
            guard let retirement, issued else { return (.pending, nil, nil) }
            if let cleanup, let cleanupID { return (nil, cleanup, cleanupID) }
            let id = UUID()
            let work = Task { [lifetime, catalog, editorID, reference] in
                await lifetime.joinUsers()
                do { try await catalog.closeRetainedAfterDrain(editorID, reference: reference); return SFTPOriginalRetainedCloseResult.closedVersionsRetained(retirement) }
                catch { return .needsReview }
            }
            cleanup = work; cleanupID = id; return (nil, work, id)
        }
        if let immediate = current.0 { return immediate }
        guard let work = current.1, let id = current.2 else { return .pending }
        let result = await work.value
        lock.withLock {
            guard cleanupID == id else { return }
            if case .closedVersionsRetained = result { completed = result }
            cleanup = nil; cleanupID = nil
        }
        return result
    }
}
