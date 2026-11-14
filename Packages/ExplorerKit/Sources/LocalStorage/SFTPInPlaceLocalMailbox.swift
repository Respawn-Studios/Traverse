import Foundation

/// Closed concrete local work; the real serial process owner joins every task.
enum SFTPInPlaceLocalOperation: Sendable {
    case begin(SFTPOriginalReadJob, UInt64), header(SFTPOriginalReadJob, Data), chunk(SFTPOriginalReadJob, Data)
    case accept(SFTPOriginalReadJob, Data), admit(SFTPOriginalReadJob, Data), abandon(SFTPOriginalReadJob)
    case rejectBeforeBody(SFTPOriginalReadJob, SFTPInPlacePrebodyRejection)
    case prepare(SFTPInPlaceBaseline, SFTPEditedTextSnapshot, UUID, SFTPVerifiedSessionContext, SFTPInPlaceJournal, UInt64)
    case journalRevision(SFTPInPlaceJournal), finishAttempt(SFTPInPlaceAttempt), continuation(SFTPInPlaceAttempt)
    case releaseCommand(SFTPInPlaceRelease), finishRelease(SFTPInPlaceRelease)
    #if DEBUG
    var stage: SFTPOriginalLocalStage {
        switch self {
        case .begin: .begin; case .header: .header; case .chunk: .chunk; case .accept: .seal; case .admit: .admission
        case .rejectBeforeBody: .drain
        case .prepare: .preparation; case .journalRevision: .journal; case .abandon, .finishAttempt: .drain
        case .continuation: .continuation; case .releaseCommand, .finishRelease: .release
        }
    }
    #endif
    fileprivate func run() async throws -> SFTPInPlaceLocalReply {
        switch self {
        case .begin(let job, let revision): return .bytes(try await job.beginCommand(catalogRevision: revision))
        case .header(let job, let data): try await job.header(data); return .ended
        case .chunk(let job, let data): try await job.chunk(data); return .ended
        case .accept(let job, let data): return .bytes(try await job.acceptance(data))
        case .admit(let job, let data): return .baseline(try await job.admittedInPlace(data))
        case .abandon(let job): await job.abandonAfterActualTransportDrain(); return .ended
        case .rejectBeforeBody(let job, let proof): try await job.rejectBeforeBody(proof); return .ended
        case .prepare(let baseline, let snapshot, let session, let context, let journal, let revision):
            return .attempt(try await SFTPInPlaceAttempt.prepare(baseline: baseline, snapshot: snapshot, session: session, context: context, journal: journal, revision: revision))
        case .journalRevision(let journal): return .revision(try await journal.inspect().revision)
        case .finishAttempt(let attempt): await attempt.finishLocalAfterOperationReturned(); return .ended
        case .continuation(let attempt): return .baseline(try await attempt.continuationAfterLocalDrain())
        case .releaseCommand(let release): return .bytes(try await release.command())
        case .finishRelease(let release): return .closed(await release.finishAfterLocalDrain())
        }
    }
}
enum SFTPInPlaceLocalReply: Sendable {
    case bytes(Data), baseline(SFTPInPlaceBaseline), attempt(SFTPInPlaceAttempt), revision(UInt64), ended, closed(SFTPInPlaceCloseResult)
}

/// The serial owner blocks only its own off-main queue. The body task uses
/// independent bounded executors and is actually awaited by an uncancelled
/// observer before any reply is signalled. Cancellation is never a completion.
final class SFTPInPlaceLocalMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var task: Task<SFTPInPlaceLocalReply, Error>?
    private var observer: Task<Void, Never>?
    private var result: Result<SFTPInPlaceLocalReply, Error>?
    private var stopped = false
    #if DEBUG
    struct Observation: Sendable { let stopped: Bool, returned: Bool }
    var observation: Observation {
        condition.lock(); defer { condition.unlock() }
        return .init(stopped: stopped, returned: result != nil)
    }
    #endif

    init(_ operation: SFTPInPlaceLocalOperation, probe: (@Sendable () throws -> Void)? = nil) {
        let work = Task.detached(priority: .utility) {
            try probe?(); try Task.checkCancellation()
            return try await operation.run()
        }
        task = work
        observer = Task.detached(priority: .utility) { [self] in
            let completed: Result<SFTPInPlaceLocalReply, Error>
            do { completed = .success(try await work.value) }
            catch { completed = .failure(error) }
            complete(completed)
        }
    }
    private func complete(_ completed: Result<SFTPInPlaceLocalReply, Error>) {
        condition.lock(); defer { condition.unlock() }
        result = completed; condition.broadcast()
    }
    func requestStop() {
        condition.lock(); stopped = true; let work = task; condition.unlock()
        work?.cancel()
    }
    func joinedOnSessionExecutor() throws -> SFTPInPlaceLocalReply {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        condition.lock()
        while result == nil { condition.wait() }
        let completed = result!
        // The awaited body task has actually returned. The observer performs
        // no body work after the signal and retains itself through its return.
        task = nil; observer = nil
        condition.unlock()
        return try completed.get()
    }
}
