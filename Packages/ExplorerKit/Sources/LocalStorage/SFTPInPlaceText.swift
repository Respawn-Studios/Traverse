import CryptoKit
import Foundation
import FileOperations

/// This concrete authority can be minted only by the real193 read job or a
/// checked197 successor. Location text, a journal row and a new connection do
/// not grant access to the retained remote handle.
final class SFTPInPlaceBaseline: @unchecked Sendable, CustomDebugStringConvertible {
    let session: UUID, token: UUID, revision: UInt64, context: SFTPVerifiedSessionContext
    let contents: TextDocumentValue, storageOwner: SFTPOriginalStorageOwner
    fileprivate let path: String, modified: UInt32, uid: UInt32, gid: UInt32, mode: UInt32, digest: Data
    fileprivate let reference: SFTPOriginalSpoolReference, origin: SFTPTextOrigin, directory: URL
    let catalog: SFTPOriginalEditorCatalog, editorID: UUID
    let lifetimePin: SFTPOriginalLifetimePin
    private let lifetime = SFTPOriginalBaselineLifetime(), lock = NSLock()
    private let historical: Bool
    private var closing: SFTPInPlaceRelease?
    var debugDescription: String { "<live retained-handle in-place baseline>" }
    convenience init(_ received: SFTPInPlaceReceivedBody) {
        self.init(session: received.session, token: received.token, revision: received.revision, context: received.context,
            contents: received.contents, origin: received.origin, directory: received.directory, path: received.path,
            modified: received.modified, uid: received.uid, gid: received.gid, mode: received.mode, digest: received.digest, reference: received.reference,
            catalog: received.catalog, editorID: received.editorID, owner: received.owner,
            lifetimePin: received.lifetimePin, historical: false)
    }
    private init(session: UUID, token: UUID, revision: UInt64, context: SFTPVerifiedSessionContext, contents: TextDocumentValue,
        origin: SFTPTextOrigin, directory: URL, path: String, modified: UInt32, uid: UInt32, gid: UInt32, mode: UInt32, digest: Data,
        reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog, editorID: UUID,
        owner: SFTPOriginalStorageOwner, lifetimePin: SFTPOriginalLifetimePin, historical: Bool) {
        self.session = session; self.token = token; self.revision = revision; self.context = context; self.contents = contents
        self.origin = origin; self.directory = directory; self.path = path; self.modified = modified; self.uid = uid; self.gid = gid; self.mode = mode
        self.digest = digest; self.reference = reference; self.catalog = catalog; self.editorID = editorID
        storageOwner = owner; self.lifetimePin = lifetimePin; self.historical = historical
    }
    func beginLocalUse() throws -> SFTPOriginalBaselineUse {
        try storageOwner.validate(session: session, context: context); return try lifetime.use()
    }
    func stagingAuthority(in directory: URL) throws -> (origin: SFTPTextOrigin, binding: SFTPInPlaceStageBinding, owner: SFTPOriginalStorageOwner) {
        try lock.withLock {
            try storageOwner.validate(session: session, context: context); try lifetime.checkAvailable()
            guard directory == self.directory else { throw SFTPTextFailure.changed }; return (origin, .init(self), storageOwner)
        }
    }
    fileprivate func edited(_ snapshot: SFTPEditedTextSnapshot, session: UUID, context: SFTPVerifiedSessionContext) throws -> SFTPOriginalSpoolReference {
        try storageOwner.validate(session: session, context: context); try origin.validate(session: session, context: context); try lifetime.checkAvailable()
        return try snapshot.inPlaceReference(context: context, session: session, directory: directory, binding: .init(self))
    }
    fileprivate func claim(session: UUID, context: SFTPVerifiedSessionContext) throws {
        try storageOwner.validate(session: session, context: context); try origin.validate(session: session, context: context)
        guard revision < UInt64.max else { throw SFTPTextFailure.closed }; try lifetime.claim()
    }
    fileprivate func beforeRead() async throws -> SFTPOriginalRecoveryRead {
        let before = try await SFTPOriginalRecoveryRead.open(directory: directory, reference: reference)
        do { guard try await before.read() == contents else { throw SFTPTextFailure.changed }; return before }
        catch { await before.closeAndDrain(); throw error }
    }
    fileprivate func successor(token: UUID, revision: UInt64, modified: UInt32,
        contents: TextDocumentValue, reference: SFTPOriginalSpoolReference,
        lifetimePin: SFTPOriginalLifetimePin) throws -> SFTPInPlaceBaseline {
        guard revision == self.revision + 1 else { throw SFTPTextFailure.changed }
        return SFTPInPlaceBaseline(session: session, token: token, revision: revision, context: context, contents: contents,
            origin: origin, directory: directory, path: path, modified: modified, uid: uid, gid: gid, mode: mode, digest: reference.digest,
            reference: reference, catalog: catalog, editorID: editorID, owner: storageOwner,
            lifetimePin: lifetimePin, historical: true)
    }
    func beginClose() throws -> SFTPInPlaceRelease {
        try lock.withLock {
            if let closing { return closing }; try lifetime.beginUnusedClose()
            let base: SFTPOriginalBaselineClose
            if historical {
                base = .retained(.init(session: session, token: token, revision: revision, editorID: editorID,
                    reference: reference, catalog: catalog, lifetime: lifetime))
            } else {
                base = .unused(.init(session: session, token: token, revision: revision, editorID: editorID,
                    reference: reference, catalog: catalog, lifetime: lifetime))
            }
            let release = SFTPInPlaceRelease(base); closing = release; return release
        }
    }
}
struct SFTPInPlaceStageBinding: Sendable, Equatable, CustomDebugStringConvertible {
    private let session: UUID, token: UUID, revision: UInt64, path: Data, baseline: Data
    fileprivate init(_ value: SFTPInPlaceBaseline) {
        session = value.session; token = value.token; revision = value.revision; path = Data(SHA256.hash(data: Data(value.path.utf8))); baseline = value.digest
    }
    var debugDescription: String { "<in-place sealed generation binding>" }
}
/// Local retirement is shared; the NEW typed199 must additionally prove actual
/// remote CLOSE ACK + retained channel shutdown before local unused removal.
final class SFTPInPlaceRelease: Sendable {
    private let base: SFTPOriginalBaselineClose
    fileprivate init(_ base: SFTPOriginalBaselineClose) { self.base = base }
    var readyForActualBufferClose: Bool {
        switch base { case .unused(let v): v.readyForActualBufferClose; case .retained: false }
    }
    func markActualBufferClosed() {
        if case .unused(let v) = base { v.markActualBufferClosed() }
    }
    func command() async throws -> Data {
        switch base { case .unused(let v): return try await v.command(); case .retained(let v): return try await v.command() }
    }
    func observedOnSessionExecutor(_ payload: Data, session: UUID) throws {
        var c = SFTPCursor(payload); _ = try c.token(); _ = try c.token(); _ = try c.number(8)
        let result = try c.number(1)
        guard (result == 1 || result == 2), try c.boolean(), try c.boolean(), c.finished else { throw SFTPProtocolFailure.invalidOutput }
        let correlated = payload.prefix(41)
        switch base {
        case .unused(let v): try v.observedReleaseOnSessionExecutor(Data(correlated), session: session)
        case .retained(let v): try v.observedReleaseOnSessionExecutor(Data(correlated), session: session)
        }
    }
    func afterActualSessionDrain(_ end: SFTPWorkerClose, session: UUID) throws {
        switch base { case .unused(let v): try v.afterActualSessionDrain(end, session: session); case .retained(let v): try v.afterActualSessionDrain(end, session: session) }
    }
    func finishAfterLocalDrain() async -> SFTPInPlaceCloseResult {
        switch base {
        case .unused(let v):
            switch await v.finishAfterLocalDrain() { case .closedUnusedCopyRemoved: .closedUnusedCopyRemoved; case .pending: .pending; case .needsReview: .needsReview }
        case .retained(let v):
            switch await v.finishAfterLocalDrain() { case .closedVersionsRetained: .closedVersionsRetained; case .pending: .pending; case .needsReview: .needsReview }
        }
    }
}

final class SFTPInPlaceAttempt: @unchecked Sendable, CustomDebugStringConvertible {
    let record: SFTPInPlaceRecord
    private let before: SFTPOriginalRecoveryRead, source: SFTPUploadSource, snapshot: SFTPEditedTextSnapshot
    private let baseline: SFTPInPlaceBaseline, journal: SFTPInPlaceJournal
    private let lock = NSLock()
    private var sent = false, terminal = false, drained = false, continued = false
    private var next: (UUID, UInt64, UInt32)?, finishing: Task<Void, Never>?
    var debugDescription: String { "<guarded in-place Save attempt>" }
    private init(_ record: SFTPInPlaceRecord, before: SFTPOriginalRecoveryRead, source: SFTPUploadSource,
        snapshot: SFTPEditedTextSnapshot, baseline: SFTPInPlaceBaseline, journal: SFTPInPlaceJournal) {
        self.record = record; self.before = before; self.source = source; self.snapshot = snapshot; self.baseline = baseline; self.journal = journal
    }
    static func prepare(baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot, session: UUID,
        context: SFTPVerifiedSessionContext, journal: SFTPInPlaceJournal, revision: UInt64) async throws -> SFTPInPlaceAttempt {
        guard journal.layout == baseline.storageOwner.layout else { throw SFTPSharedBudgetFailure.stale }
        let use = try baseline.beginLocalUse(); defer { use.release() }
        let edited = try baseline.edited(snapshot, session: session, context: context)
        let record = SFTPInPlaceRecord(id: UUID(), editorGeneration: snapshot.editorGeneration, session: session,
            baselineToken: baseline.token, baselineRevision: baseline.revision, context: try .init(context), path: baseline.path,
            baseline: baseline.reference, edited: edited, baselineModified: baseline.modified, uid: baseline.uid, gid: baseline.gid, mode: baseline.mode)
        try record.validate()
        // Both bodies are independent private sealed files (single-link checks
        // in DownloadDisk), not remote aliases or a backup hardlink. Link the
        // durable reference graph before acquiring either active body lease.
        try baseline.claim(session: session, context: context); snapshot.notePublicationRequested()
        try await baseline.catalog.linkInPlaceSave(baseline.editorID, record: record)
        let before = try await baseline.beforeRead(); var held: SFTPUploadSource?
        do {
            let source = try await SFTPUploadSource.prepare(snapshot); held = source
            try await journal.prepare(record, revision: revision)
            return .init(record, before: before, source: source, snapshot: snapshot, baseline: baseline, journal: journal)
        } catch { if let held { await held.drain() }; await before.closeAndDrain(); await journal.endAfterActualDrain(record.id); throw error }
    }
    func command() throws -> Data {
        try lock.withLock {
            guard !sent, !terminal, !drained, finishing == nil else { throw SFTPTextFailure.closed }; sent = true
            var payload = SFTPWire.token(record.id); payload.append(SFTPWire.token(record.baselineToken)); SFTPWire.number(record.baselineRevision, bytes: 8, into: &payload)
            payload.append(SFTPWire.token(record.editorGeneration)); SFTPWire.number(record.edited.logicalBytes, bytes: 8, into: &payload); payload.append(record.edited.digest); return payload
        }
    }
    private func available() throws { guard sent, !terminal, !drained, finishing == nil else { throw SFTPTextFailure.closed } }
    func sourceOnSessionExecutor(_ payload: Data) throws -> Data {
        try lock.withLock {
            try available(); var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let offset = try c.number(8), count = try c.number(4); guard c.finished, (1...32768).contains(count) else { throw SFTPProtocolFailure.invalidOutput }
            let bytes = try source.readOnSessionExecutor(offset: offset, maximum: Int(count)); guard bytes.count == Int(count) else { throw SFTPTextFailure.changed }
            var reply = SFTPWire.token(record.id); SFTPWire.number(offset, bytes: 8, into: &reply); try SFTPWire.field(bytes, into: &reply); return reply
        }
    }
    func permitOnSessionExecutor(_ payload: Data) throws -> Data {
        try lock.withLock {
            try available(); var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let step = try SFTPInPlaceStep(cursor: &c); guard try c.take(32) == record.edited.digest, c.finished else { throw SFTPProtocolFailure.invalidOutput }
            try before.validateOnSessionExecutor(); try source.validateEditedCreationOnSessionExecutor()
            if step.kind == .source { guard try source.finishOnSessionExecutor() == record.edited.digest else { throw SFTPTextFailure.changed } }
            try journal.requestOnSessionExecutor(record.id, step: step)
            try before.validateOnSessionExecutor(); try source.validateEditedCreationOnSessionExecutor(); return payload
        }
    }
    func observedOnSessionExecutor(_ payload: Data) throws {
        try lock.withLock {
            try available(); var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let step = try SFTPInPlaceStep(cursor: &c); guard c.finished else { throw SFTPProtocolFailure.invalidOutput }
            try journal.observeOnSessionExecutor(record.id, step: step)
        }
    }
    ///197 proves this Save operation returned with the handle STILL retained.
    /// It does not claim channel shutdown, namespace publication or remote CAS.
    func completedOnSessionExecutor(_ payload: Data) throws {
        try lock.withLock {
            try available(); var c = SFTPCursor(payload)
            guard try c.token() == record.id, try c.token() == record.editorGeneration else { throw SFTPProtocolFailure.invalidOutput }
            let token = try c.token(), revision = try c.number(8), size = try c.number(8), digest = try c.take(32)
            let actualSize = try c.number(8), modified = try c.number(4)
            let mode = try c.number(4), uid = try c.number(4), gid = try c.number(4), requested = try c.number(1), acknowledged = try c.number(1)
            let expected = try record.plan
            guard revision == record.baselineRevision + 1, size == record.edited.logicalBytes, actualSize == size, digest == record.edited.digest,
                  mode == record.mode, uid == record.uid, gid == record.gid, requested == UInt64(expected.count), acknowledged == UInt64(expected.count),
                  try c.boolean(), try c.boolean(), try c.boolean(), try c.boolean(), c.finished else { throw SFTPProtocolFailure.invalidOutput }
            try before.validateOnSessionExecutor(); try source.validateEditedCreationOnSessionExecutor(); try journal.finishOnSessionExecutor(record.id)
            next = (token, revision, UInt32(modified)); terminal = true
        }
    }
    func interruptedOnSessionExecutor(_ payload: Data) throws -> SFTPInPlaceInterruption {
        try lock.withLock {
            try available(); var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let phase = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1), cause = try c.number(1), status = try c.number(4)
            guard c.finished, let typedPhase = SFTPInPlaceFailurePhase(rawValue: UInt8(phase)),
                  let typedCause = SFTPInPlaceFailureCause(rawValue: UInt8(cause)), cause == 6 || status == 0 else { throw SFTPProtocolFailure.invalidOutput }
            let durable = try journal.interruptionOnSessionExecutor(record.id, requested: requested, acknowledged: acknowledged); terminal = true
            return .init(recordID: record.id, facts: .init(phase: typedPhase, cause: typedCause, status: UInt32(status),
                requestedSteps: durable.requested, acknowledgedSteps: durable.acknowledged, remoteBytesMayHaveChanged: durable.mutates))
        }
    }
    func continuationAfterLocalDrain() async throws -> SFTPInPlaceBaseline {
        let result = try lock.withLock { () throws -> (UUID, UInt64, UInt32, TextDocumentValue) in
            guard drained, terminal, !continued, let next else { throw SFTPTextFailure.closed }; continued = true
            return (next.0, next.1, next.2, try snapshot.inPlaceContinuationContents())
        }
        let pin = try await baseline.catalog.continuedAndPin(baseline.editorID,
            reference: record.edited, storageOwner: baseline.storageOwner)
        do {
            return try baseline.successor(token: result.0, revision: result.1, modified: result.2,
                contents: result.3, reference: record.edited, lifetimePin: pin)
        } catch { _ = await pin.closeAndDrain(); throw error }
    }
    func requestStop() { source.requestStop() }
    /// Invoked after strict197 (serial operation returned), or after actual
    /// child exit+EOF. Never called just because cancellation was requested.
    func finishLocalAfterOperationReturned() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let finishing { return finishing }
            let task = Task { await self.source.drain(); await self.before.closeAndDrain(); await self.journal.endAfterActualDrain(self.record.id)
                _ = await self.snapshot.closeAndDrain(); self.lock.withLock { self.drained = true } }
            finishing = task; return task
        }
        await task.value
    }
}
@_spi(Qualification) public enum SFTPInPlaceFailurePhase: UInt8, Sendable {
    case admission, source, baseline, writing, truncating, syncing, handleReadback, locationReadback, release
}
@_spi(Qualification) public enum SFTPInPlaceFailureCause: UInt8, Sendable {
    case input, io, deadline, stopped, truncated, protocolViolation, status, conflict, unsupportedSync, verification, sourceChanged
}
/// Closed metadata facts for presentation/recovery. They grant NO retry, write,
/// rollback, deletion, reattachment or new-owner authority.
@_spi(Qualification) public struct SFTPInPlaceReviewFacts: Sendable {
    public let phase: SFTPInPlaceFailurePhase, cause: SFTPInPlaceFailureCause, status: UInt32
    public let requestedSteps: Int, acknowledgedSteps: Int, remoteBytesMayHaveChanged: Bool
}
struct SFTPInPlaceInterruption: Error, Sendable, CustomDebugStringConvertible {
    let recordID: UUID, facts: SFTPInPlaceReviewFacts
    var debugDescription: String { "<in-place Save needs recovery review>" }
}
