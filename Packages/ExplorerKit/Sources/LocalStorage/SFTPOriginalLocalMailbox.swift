import Foundation

#if DEBUG
enum SFTPOriginalLocalStage: String, Sendable {
    case begin, header, chunk, seal, admission, preparation, journal, drain, continuation, release
}
#endif

/// Closed local work vocabulary. No caller-supplied producer, raw file URL or
/// IPC callback can execute while the one process queue is waiting.
enum SFTPOriginalLocalOperation: Sendable {
    case begin(SFTPOriginalReadJob, UInt64)
    case header(SFTPOriginalReadJob, Data), chunk(SFTPOriginalReadJob, Data)
    case accept(SFTPOriginalReadJob, Data), admit(SFTPOriginalReadJob, Data)
    case abandonReadAfterTransportDrain(SFTPOriginalReadJob)
    case prepare(SFTPOriginalBaseline, SFTPEditedTextSnapshot, UUID, SFTPVerifiedSessionContext, SFTPOriginalJournal, UInt64)
    case journalRevision(SFTPOriginalJournal)
    case endAttemptAfterTransportDrain(SFTPOriginalAttempt)
    case continuation(SFTPOriginalAttempt)
    case releaseCommand(SFTPOriginalUnusedClose)
    case finishUnusedClose(SFTPOriginalUnusedClose)
    case retainedReleaseCommand(SFTPOriginalRetainedClose)
    case finishRetainedClose(SFTPOriginalRetainedClose)

    #if DEBUG
    var stage: SFTPOriginalLocalStage {
        switch self {
        case .begin: .begin; case .header: .header; case .chunk: .chunk; case .accept: .seal
        case .admit: .admission; case .prepare: .preparation; case .journalRevision: .journal
        case .abandonReadAfterTransportDrain, .endAttemptAfterTransportDrain: .drain
        case .continuation: .continuation
        case .releaseCommand, .finishUnusedClose, .retainedReleaseCommand, .finishRetainedClose: .release
        }
    }
    #endif

    fileprivate func run() async throws -> SFTPOriginalLocalReply {
        switch self {
        case .begin(let job, let revision): return .bytes(try await job.beginCommand(catalogRevision: revision))
        case .header(let job, let payload): try await job.header(payload); return .ended
        case .chunk(let job, let payload): try await job.chunk(payload); return .ended
        case .accept(let job, let payload): return .bytes(try await job.acceptance(payload))
        case .admit(let job, let payload): return .baseline(try await job.admitted(payload))
        case .abandonReadAfterTransportDrain(let job): await job.abandonAfterActualTransportDrain(); return .ended
        case .prepare(let baseline, let snapshot, let session, let context, let journal, let revision):
            return .attempt(try await SFTPOriginalAttempt.prepare(baseline: baseline, snapshot: snapshot,
                session: session, context: context, journal: journal, journalRevision: revision))
        case .journalRevision(let journal): return .revision(try await journal.inspect().revision)
        case .endAttemptAfterTransportDrain(let attempt): await attempt.afterActualTransportDrain(); return .ended
        case .continuation(let attempt): return .baseline(try await attempt.continuationAfterActualDrain())
        case .releaseCommand(let close): return .bytes(try await close.command())
        case .finishUnusedClose(let close): return .unusedClose(await close.finishAfterLocalDrain())
        case .retainedReleaseCommand(let close): return .bytes(try await close.command())
        case .finishRetainedClose(let close): return .retainedClose(await close.finishAfterLocalDrain())
        }
    }
}
enum SFTPOriginalLocalReply: Sendable {
    case bytes(Data), baseline(SFTPOriginalBaseline), attempt(SFTPOriginalAttempt), revision(UInt64), ended
    case unusedClose(SFTPOriginalUnusedCloseResult), retainedClose(SFTPOriginalRetainedCloseResult)
}

/// The serial owner blocks only its own off-main queue. The body task uses
/// independent bounded executors and is actually awaited by an uncancelled
/// observer before any reply is signalled. Cancellation is never a completion.
final class SFTPOriginalLocalMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var task: Task<SFTPOriginalLocalReply, Error>?
    private var observer: Task<Void, Never>?
    private var result: Result<SFTPOriginalLocalReply, Error>?
    private var stopped = false
    #if DEBUG
    struct Observation: Sendable { let stopped: Bool, returned: Bool }
    var observation: Observation {
        condition.lock(); defer { condition.unlock() }
        return .init(stopped: stopped, returned: result != nil)
    }
    #endif

    init(_ operation: SFTPOriginalLocalOperation, probe: (@Sendable () throws -> Void)? = nil) {
        let work = Task.detached(priority: .utility) {
            try probe?(); try Task.checkCancellation()
            return try await operation.run()
        }
        task = work
        observer = Task.detached(priority: .utility) { [self] in
            let completed: Result<SFTPOriginalLocalReply, Error>
            do { completed = .success(try await work.value) }
            catch { completed = .failure(error) }
            complete(completed)
        }
    }
    private func complete(_ completed: Result<SFTPOriginalLocalReply, Error>) {
        condition.lock(); defer { condition.unlock() }
        result = completed; condition.broadcast()
    }
    func requestStop() {
        condition.lock(); stopped = true; let work = task; condition.unlock()
        work?.cancel()
    }
    func joinedOnSessionExecutor() throws -> SFTPOriginalLocalReply {
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
