import CryptoKit
import Foundation
import FileOperations

/// Live K/L authority. Opaque to the UI; closing the UI does not manufacture
/// remote completion or permit replay after a disconnect/reconnect.
final class SFTPOriginalBaseline: @unchecked Sendable, CustomDebugStringConvertible {
    let session: UUID, token: UUID, revision: UInt64, context: SFTPVerifiedSessionContext
    let contents: TextDocumentValue
    let storageOwner: SFTPOriginalStorageOwner
    let lifetimePin: SFTPOriginalLifetimePin
    fileprivate let path: String, uid: UInt32, gid: UInt32, mode: UInt32, digest: Data
    fileprivate let retainedReference: SFTPOriginalSpoolReference, origin: SFTPTextOrigin, bodyDirectory: URL
    private let lock = NSLock()
    private let lifetime = SFTPOriginalBaselineLifetime()
    private var unusedClose: SFTPOriginalUnusedClose?
    private var retainedClose: SFTPOriginalRetainedClose?
    let catalog: SFTPOriginalEditorCatalog, editorID: UUID
    private let mayDiscardUnused: Bool
    var debugDescription: String { "<live SFTP original baseline>" }
    fileprivate init(session: UUID, token: UUID, revision: UInt64, context: SFTPVerifiedSessionContext,
        contents: TextDocumentValue, origin: SFTPTextOrigin, bodyDirectory: URL, path: String,
        uid: UInt32, gid: UInt32, mode: UInt32, digest: Data, retainedReference: SFTPOriginalSpoolReference,
        catalog: SFTPOriginalEditorCatalog, editorID: UUID, storageOwner: SFTPOriginalStorageOwner,
        lifetimePin: SFTPOriginalLifetimePin, mayDiscardUnused: Bool = true) {
        self.session = session; self.token = token; self.revision = revision; self.context = context; self.contents = contents
        self.origin = origin; self.bodyDirectory = bodyDirectory; self.path = path; self.uid = uid; self.gid = gid
        self.catalog = catalog; self.editorID = editorID; self.mayDiscardUnused = mayDiscardUnused
        self.storageOwner = storageOwner; self.lifetimePin = lifetimePin
        self.mode = mode; self.digest = digest; self.retainedReference = retainedReference
    }
    func stagingAuthority(in directory: URL) throws -> (origin: SFTPTextOrigin, binding: SFTPOriginalStageBinding, owner: SFTPOriginalStorageOwner) {
        try lock.withLock {
            try storageOwner.validate(session: session, context: context)
            try lifetime.checkAvailable()
            guard directory == bodyDirectory else { throw SFTPTextFailure.closed }
            return (origin, SFTPOriginalStageBinding(self), storageOwner)
        }
    }
    func beginLocalUse() throws -> SFTPOriginalBaselineUse {
        try storageOwner.validate(session: session, context: context); return try lifetime.use()
    }
    func beginUnusedClose() throws -> SFTPOriginalUnusedClose {
        try lock.withLock {
            guard mayDiscardUnused else { throw SFTPTextFailure.unsupported }
            if let unusedClose { return unusedClose }
            try lifetime.beginUnusedClose()
            let close = SFTPOriginalUnusedClose(session: session, token: token, revision: revision, editorID: editorID,
                reference: retainedReference, catalog: catalog, lifetime: lifetime)
            unusedClose = close; return close
        }
    }
    /// A successful successor is historical data. Retiring its live token
    /// cannot authorize the unused-initial-copy deletion path.
    func beginRetainedClose() throws -> SFTPOriginalRetainedClose {
        try lock.withLock {
            guard !mayDiscardUnused else { throw SFTPTextFailure.unsupported }
            if let retainedClose { return retainedClose }
            try lifetime.beginUnusedClose()
            let close = SFTPOriginalRetainedClose(session: session, token: token, revision: revision,
                editorID: editorID, reference: retainedReference, catalog: catalog, lifetime: lifetime)
            retainedClose = close; return close
        }
    }
    var retainsSuccessfulVersions: Bool { !mayDiscardUnused }
    fileprivate func editedReference(_ snapshot: SFTPEditedTextSnapshot, session: UUID, context: SFTPVerifiedSessionContext) throws -> SFTPOriginalSpoolReference {
        try storageOwner.validate(session: session, context: context)
        try origin.validate(session: session, context: context); try lifetime.checkAvailable()
        return try snapshot.originalReference(context: context, session: session, directory: bodyDirectory, binding: SFTPOriginalStageBinding(self))
    }
    fileprivate func openBeforeBody() async throws -> SFTPOriginalRecoveryRead {
        let held = try await SFTPOriginalRecoveryRead.open(directory: bodyDirectory, reference: retainedReference)
        do {
            guard try await held.read() == contents else { throw SFTPTextFailure.changed }; return held
        } catch { await held.closeAndDrain(); throw error }
    }
    fileprivate func claim(session: UUID, context: SFTPVerifiedSessionContext) throws {
        try storageOwner.validate(session: session, context: context)
        try origin.validate(session: session, context: context)
        guard revision < UInt64.max else { throw SFTPTextFailure.closed }; try lifetime.claim()
    }
}
struct SFTPOriginalStageBinding: Sendable, Equatable, CustomDebugStringConvertible {
    private let session: UUID, token: UUID, revision: UInt64, targetDigest: Data, baselineDigest: Data
    fileprivate init(_ baseline: SFTPOriginalBaseline) {
        session = baseline.session; token = baseline.token; revision = baseline.revision
        targetDigest = Data(SHA256.hash(data: Data(baseline.path.utf8))); baselineDigest = baseline.digest
    }
    var debugDescription: String { "<sealed SFTP original stage binding>" }
}
/// Only the actual unadmitted read job can mint this exact cleanup proof. It
/// cannot exempt an admitted baseline, Save/recovery reference or foreign job.
struct SFTPOriginalUnadmittedReadProof: Sendable {
    let editorID: UUID, session: UUID, path: String
    private let request: UUID, bodyID: UUID, expectedBytes: UInt64, context: SFTPOriginalContext
    fileprivate init(editorID: UUID, session: UUID, request: UUID, bodyID: UUID,
                     expectedBytes: UInt64, context: SFTPOriginalContext, path: String) {
        self.editorID = editorID; self.session = session; self.request = request; self.bodyID = bodyID
        self.expectedBytes = expectedBytes; self.context = context; self.path = path
    }
    func validate(record: SFTPOriginalEditorRecord, body: UUID) throws {
        guard record.id == editorID, record.session == session, record.request == request, body == bodyID,
              record.expectedBytes == expectedBytes, record.context == context,
              record.journals.isEmpty, record.recovery.isEmpty else { throw SFTPSharedBudgetFailure.referenced }
        switch record.phase {
        case .receiving:
            guard record.bodyID == nil, record.body == nil, record.path == nil else { throw SFTPSharedBudgetFailure.referenced }
        case .bodyAttached, .readyToAccept, .unadmittedRemovalPending:
            guard record.bodyID == bodyID, record.path == path else { throw SFTPSharedBudgetFailure.referenced }
        default: throw SFTPSharedBudgetFailure.referenced
        }
    }
}
#if DEBUG
enum SFTPOriginalDecodeStage: Sendable, Equatable { case beforeDecode, afterDecode, callerHandoff }
#endif

enum SFTPTextReadStrategy: Sendable { case replacement, inPlaceV1 }
/// Only the actual read job, after sealed independent bytes +193, can mint it.
struct SFTPInPlaceReceivedBody: Sendable {
    let session: UUID, token: UUID, revision: UInt64, context: SFTPVerifiedSessionContext, contents: TextDocumentValue
    let origin: SFTPTextOrigin, directory: URL, path: String, modified: UInt32, uid: UInt32, gid: UInt32, mode: UInt32, digest: Data
    let reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog, editorID: UUID, owner: SFTPOriginalStorageOwner
    let lifetimePin: SFTPOriginalLifetimePin
    fileprivate init(session: UUID, token: UUID, context: SFTPVerifiedSessionContext, contents: TextDocumentValue,
        origin: SFTPTextOrigin, directory: URL, path: String, modified: UInt32, uid: UInt32, gid: UInt32, mode: UInt32, digest: Data,
        reference: SFTPOriginalSpoolReference, catalog: SFTPOriginalEditorCatalog, editorID: UUID,
        owner: SFTPOriginalStorageOwner, lifetimePin: SFTPOriginalLifetimePin) {
        self.session = session; self.token = token; revision = 1; self.context = context; self.contents = contents; self.origin = origin
        self.directory = directory; self.path = path; self.modified = modified; self.uid = uid; self.gid = gid; self.mode = mode; self.digest = digest
        self.reference = reference; self.catalog = catalog; self.editorID = editorID; self.owner = owner
        self.lifetimePin = lifetimePin
    }
}

/// One explicit selected read. The existing serial process owner dispatches
/// events here; this object does not create a socket, SSH task or second writer.
actor SFTPOriginalReadJob {
    let selection: SFTPDownloadSelection
    private let session: UUID, context: SFTPVerifiedSessionContext, directory: URL
    private let catalog: SFTPOriginalEditorCatalog, editorID: UUID
    private let storageOwner: SFTPOriginalStorageOwner
    private let strategy: SFTPTextReadStrategy
    private let executor = DownloadExecutor()
    private var file: RemoteDownloadedFile?, path: String?, uid: UInt32 = 0, gid: UInt32 = 0, mode: UInt32 = 0, modifiedSeconds: UInt32 = 0
    private var decodedContents: TextDocumentValue?, checkedReference: SFTPOriginalSpoolReference?
    private var checkedPin: SFTPOriginalLifetimePin?
    private var decodingTask: Task<Data, Error>?, unusedCleanup: Task<Void, Never>?
    private var rejectedCatalogRevision: UInt64?
    private var acceptanceReturned = false
    private var headerWaiters: [CheckedContinuation<Void, Never>] = []
    private let headerAllocationFence = OriginalHeaderAllocationFence()
    // Actor-owned proof of this exact returned constructor's completed removal.
    // Never reset the monotonic allocation fence or infer this from absence.
    private var headerRemovedBeforeAttachment = false
    #if DEBUG
    private var decodeProbe: (@Sendable (SFTPOriginalDecodeStage) throws -> Void)?
    var cleanupRequestedForQualification: Bool { finished }
    private var decodeResultReady = false
    var decodeResultReadyForQualification: Bool { decodeResultReady }
    var acceptanceReturnedForQualification: Bool { acceptanceReturned }
    func setDecodeProbeForQualification(_ probe: @escaping @Sendable (SFTPOriginalDecodeStage) throws -> Void) { decodeProbe = probe }
    private var headerInvocations = 0, headerExits = 0, allocationSubmissions = 0, allocationCompletions = 0
    private var chunkInvocations = 0, noBodySettlementAttempts = 0
    func setHeaderPostMkdirFaultForQualification(_ fault: @escaping @Sendable () throws -> Void) throws {
        guard !headerPending, headerInvocations == 0, !finished else { throw SFTPTextFailure.closed }
        try headerAllocationFence.setPostMkdirFaultForQualification(fault)
    }
    var headerStateForQualification: (pending: Bool, entered: Int, exited: Int, submitted: Int, allocated: Int, waiters: Int, bodyMayRemain: Bool, chunks: Int, settlements: Int, removedBeforeAttachment: Bool) {
        (headerPending, headerInvocations, headerExits, allocationSubmissions, allocationCompletions, headerWaiters.count,
         headerAllocationFence.mayHaveCreatedSpool, chunkInvocations, noBodySettlementAttempts, headerRemovedBeforeAttachment)
    }
    #endif
    private var sealed: Data?, accepting = false, finished = false, begun = false, headerPending = false, admitting = false
    init(session: UUID, selection: SFTPDownloadSelection, context: SFTPVerifiedSessionContext, directory: URL,
         catalog: SFTPOriginalEditorCatalog, storageOwner: SFTPOriginalStorageOwner, editorID: UUID = UUID(), strategy: SFTPTextReadStrategy = .replacement) throws {
        guard SFTPWire.validToken(session), selection.logicalBytes <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        try storageOwner.validate(session: session, context: context)
        guard catalog.validatesBudget(storageOwner), directory == storageOwner.layout.bodies,
              SFTPWire.validToken(editorID) else { throw SFTPTextFailure.changed }
        self.session = session; self.selection = selection; self.context = context; self.directory = directory
        self.catalog = catalog; self.editorID = editorID
        self.storageOwner = storageOwner; self.strategy = strategy
    }
    func beginCommand(catalogRevision: UInt64) async throws -> Data {
        guard catalogRevision > 0, catalogRevision <= UInt64(Int64.max), file == nil, !finished, !begun else { throw SFTPTextFailure.closed }
        begun = true
        try await catalog.begin(id: editorID, session: session, request: selection.request, context: context, expectedBytes: selection.logicalBytes)
        rejectedCatalogRevision = catalogRevision
        var bytes = SFTPWire.token(selection.request); bytes.append(SFTPWire.token(selection.generation))
        SFTPWire.number(catalogRevision, bytes: 8, into: &bytes); SFTPWire.number(selection.row.observation, bytes: 8, into: &bytes)
        return bytes
    }
    /// Payload of actual event180; private paths never become descriptions/logs.
    func header(_ payload: Data) async throws {
        guard file == nil, !finished, begun, !headerPending else { throw SFTPProtocolFailure.invalidOutput }
        headerPending = true
        #if DEBUG
        headerInvocations += 1
        #endif
        defer {
            headerPending = false
            #if DEBUG
            headerExits += 1
            #endif
            let ended = headerWaiters; headerWaiters.removeAll()
            ended.forEach { $0.resume() }
        }
        var c = SFTPCursor(payload)
        let request = try c.token(), generation = try c.token()
        guard request == selection.request, generation == selection.generation else { throw SFTPProtocolFailure.invalidOutput }
        let size = try c.number(8), modified = try c.number(4), permissions = try c.number(4)
        let owner = try c.number(4), group = try c.number(4), actualPath = try c.text(cap: 8192)
        guard c.finished, size == selection.logicalBytes, modified == selection.row.entry.modifiedSeconds.map({ UInt64($0) }),
              permissions == selection.row.entry.permissions.map({ UInt64($0) }), permissions & 0o170000 == 0o100000,
              permissions & 0o7000 == 0, actualPath.hasPrefix("/"), !actualPath.hasSuffix("/"),
              actualPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              actualPath.split(separator: "/").count <= 127,
              actualPath.split(separator: "/").last.map({ Data($0.utf8) }) == selection.row.entry.name.wireUTF8 else { throw SFTPProtocolFailure.invalidOutput }
        uid = UInt32(owner); gid = UInt32(group); mode = UInt32(permissions); modifiedSeconds = UInt32(modified); path = actualPath
        #if DEBUG
        allocationSubmissions += 1
        #endif
        let created = try await executor.perform { [directory, selection, headerAllocationFence, storageOwner] in
            try RemoteDownloadedFile(directory: directory, selection: selection, hooks: .init(), originalText: true,
                originalHeaderAllocation: headerAllocationFence, originalOwner: storageOwner)
        }
        #if DEBUG
        allocationCompletions += 1
        #endif
        guard !finished else {
            do {
                let proof = try unadmittedProof(bodyID: created.id)
                try await created.removeAfterDrain(originalReadProof: proof)
                headerRemovedBeforeAttachment = true
            }
            catch { _ = await created.abandon() }
            throw SFTPTextFailure.closed
        }
        do { try await catalog.attach(editorID, bodyID: created.id, path: actualPath) }
        catch {
            // Attachment can have committed despite a late/uncertain error.
            // Keep the copy and intent rather than deleting a possible reference.
            _ = await created.abandon(); throw error
        }
        guard !finished else { _ = await created.abandon(); throw SFTPTextFailure.closed }
        file = created
    }
    func chunk(_ payload: Data) async throws {
        #if DEBUG
        chunkInvocations += 1
        #endif
        guard let file, !accepting, !finished else { throw SFTPProtocolFailure.invalidOutput }
        var c = SFTPCursor(payload); guard try c.token() == selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let offset = try c.number(8), bytes = try c.field(cap: 32768)
        guard c.finished, !bytes.isEmpty else { throw SFTPProtocolFailure.invalidOutput }
        try await file.append(request: selection.request, offset: offset, bytes: bytes)
    }
    /// Actual file hash/seal must complete before returning AcceptBaseline41.
    /// The retained parent writer must still recheck its own cancellation,
    /// lifetime and live session immediately before writing this returned Ack.
    /// This cooperative return boundary cannot revoke bytes already written.
    func acceptance(_ payload: Data) async throws -> Data {
        guard let file, !accepting, !finished else { throw SFTPProtocolFailure.invalidOutput }
        var c = SFTPCursor(payload); guard try c.token() == selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let digest = try c.take(32), size = try c.number(8)
        guard c.finished, size == selection.logicalBytes else { throw SFTPProtocolFailure.invalidOutput }
        accepting = true
        let work = Task { try await self.decodeAndRetain(file: file, digest: digest, size: size) }; decodingTask = work
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            #if DEBUG
            decodeResultReady = true
            let probe = decodeProbe
            try await executor.perform { if let probe { try probe(.callerHandoff) } }
            #endif
            // Cancelling an already-completed unstructured work task does not
            // invalidate its successful value. Check the actual caller here.
            try Task.checkCancellation()
            guard !finished else { throw SFTPTextFailure.closed }
            acceptanceReturned = true; return result
        } catch {
            work.cancel(); _ = try? await work.value
            await discardUnadmittedAfterLocalDrain(file)
            throw error
        }
    }
    private func decodeAndRetain(file: RemoteDownloadedFile, digest: Data, size: UInt64) async throws -> Data {
        var lease: SFTPTextReadLease?
        do {
            try Task.checkCancellation()
            let actual = try await file.seal(.init(selection: selection, receivedBytes: size))
            guard actual == digest else { throw SFTPTextFailure.changed }
            try Task.checkCancellation()
            let source = try await SFTPTextReadLease.mint(file, origin: .init(session: session, selection: selection, context: context)); lease = source
            #if DEBUG
            let probe = decodeProbe
            source.readProbe = { if let probe { try probe(.beforeDecode) } }
            #endif
            let contents = try await source.read()
            #if DEBUG
            try await executor.perform { if let probe { try probe(.afterDecode) } }
            #endif
            try Task.checkCancellation()
            let reference = try await source.retainOriginalReference()
            await source.closeAndDrain(); lease = nil
            // This is a closed retained body, not an active ordinary read
            // lease. Check actual cold recovery readability before Accept41.
            let cold = try await SFTPOriginalRecoveryRead.open(directory: directory, reference: reference)
            do {
                let recovered = try await cold.read(); await cold.closeAndDrain()
                guard recovered == contents else { throw SFTPTextFailure.changed }
            } catch { await cold.closeAndDrain(); throw error }
            try Task.checkCancellation()
            guard !finished else { throw SFTPTextFailure.closed }
            let pin = try await catalog.readyAndPin(editorID, reference: reference, storageOwner: storageOwner)
            checkedPin = pin
            try Task.checkCancellation(); guard !finished else { throw SFTPTextFailure.closed }
            decodedContents = contents; checkedReference = reference; sealed = actual
            var bytes = SFTPWire.token(selection.request); bytes.append(actual); return bytes
        } catch {
            if let lease { await lease.closeAndDrain() }
            await discardUnadmittedAfterLocalDrain(file)
            throw error
        }
    }

    func admitted(_ payload: Data) async throws -> SFTPOriginalBaseline {
        guard strategy == .replacement else { throw SFTPProtocolFailure.phase }
        guard file != nil, let path, let sealed, accepting, acceptanceReturned, !finished, !admitting else { throw SFTPProtocolFailure.invalidOutput }
        var c = SFTPCursor(payload); guard try c.token() == selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let token = try c.token(), revision = try c.number(8), digest = try c.take(32)
        guard c.finished, revision == 1, digest == sealed else { throw SFTPProtocolFailure.invalidOutput }
        guard let contents = decodedContents, let reference = checkedReference,
              let pin = checkedPin, reference.digest == digest else { throw SFTPProtocolFailure.invalidOutput }
        admitting = true
        do {
            try await catalog.admitted(editorID)
            try Task.checkCancellation(); guard !finished else { throw SFTPTextFailure.closed }
        } catch { admitting = false; await catalog.retainForRecovery(editorID); throw error }
        finished = true; self.file = nil; checkedPin = nil
        return .init(session: session, token: token, revision: revision, context: context, contents: contents,
            origin: .init(session: session, selection: selection, context: context), bodyDirectory: directory,
            path: path, uid: uid, gid: gid, mode: mode, digest: digest, retainedReference: reference, catalog: catalog, editorID: editorID,
            storageOwner: storageOwner, lifetimePin: pin)
    }

    /// New193 proves retained authenticated RW admission. No Source6 baseline
    /// or187 publication fact is reinterpreted by this independent authority.
    func admittedInPlace(_ payload: Data) async throws -> SFTPInPlaceBaseline {
        guard strategy == .inPlaceV1, file != nil, let path, let sealed, accepting, acceptanceReturned, !finished, !admitting else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload); guard try c.token() == selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let token = try c.token(), revision = try c.number(8), digest = try c.take(32)
        guard revision == 1, digest == sealed, try c.number(1) == 1, try c.boolean(), try c.boolean(), c.finished,
              let contents = decodedContents, let reference = checkedReference,
              let pin = checkedPin, reference.digest == digest else { throw SFTPProtocolFailure.invalidOutput }
        admitting = true
        do { try await catalog.admitted(editorID); try Task.checkCancellation(); guard !finished else { throw SFTPTextFailure.closed } }
        catch { admitting = false; await catalog.retainForRecovery(editorID); throw error }
        finished = true; file = nil; checkedPin = nil
        let received = SFTPInPlaceReceivedBody(session: session, token: token, context: context, contents: contents,
            origin: .init(session: session, selection: selection, context: context), directory: directory, path: path,
            modified: modifiedSeconds, uid: uid, gid: gid, mode: mode, digest: digest, reference: reference,
            catalog: catalog, editorID: editorID, owner: storageOwner, lifetimePin: pin)
        return .init(received)
    }

    private func discardUnadmittedAfterLocalDrain(_ file: RemoteDownloadedFile, afterTransportDrain: Bool = false) async {
        guard !admitting, !acceptanceReturned || afterTransportDrain else { return }
        if let unusedCleanup { await unusedCleanup.value; return }
        if checkedPin != nil {
            // Ready committed and the owner SH may be live. There is no
            // admitted buffer to discard, but deletion cannot be inferred from
            // cancellation. Retain the exact charged body for explicit review.
            finished = true; self.file = nil
            _ = await file.abandon(); await catalog.retainForRecovery(editorID)
            return
        }
        guard let proof = try? unadmittedProof(bodyID: file.id) else { _ = await file.abandon(); return }
        finished = true; self.file = nil; decodedContents = nil; checkedReference = nil; sealed = nil
        let work = Task { [executor, directory, catalog, editorID, storageOwner] in
            await executor.drain {}
            var removed = false
            do { try await file.removeAfterDrain(originalReadProof: proof); removed = true }
            catch {
                _ = await file.abandon()
                do {
                    try await executor.perform {
                        try RemoteDownloadStore(directory: directory).discardIncompleteOnOriginalExecutor(file.id, owner: storageOwner, readProof: proof)
                    }
                    removed = true
                } catch { /* Retained exact copy stays visible and charged. */ }
            }
            if removed { try? await catalog.removedFailedRead(editorID, bodyID: file.id) }
        }
        unusedCleanup = work; await work.value
    }
    private func unadmittedProof(bodyID: UUID) throws -> SFTPOriginalUnadmittedReadProof {
        guard !admitting, !acceptanceReturned, let path else { throw SFTPSharedBudgetFailure.referenced }
        return .init(editorID: editorID, session: session, request: selection.request, bodyID: bodyID,
            expectedBytes: selection.logicalBytes, context: try SFTPOriginalContext(context), path: path)
    }
    /// Decoder-created201 proves only this request's new subsystem closed.
    /// It never proves the SSH transport, sibling editors or their bodies ended.
    func rejectBeforeBody(_ proof: SFTPInPlacePrebodyRejection) async throws {
        guard strategy == .inPlaceV1, begun, !finished, !headerPending,
              file == nil, path == nil, decodedContents == nil, checkedReference == nil,
              sealed == nil, !accepting, !acceptanceReturned, !admitting,
              !headerAllocationFence.mayHaveCreatedSpool, decodingTask == nil, unusedCleanup == nil,
              proof.request == selection.request, proof.generation == selection.generation,
              proof.revision == rejectedCatalogRevision, proof.observation == selection.row.observation else { throw SFTPTextFailure.changed }
        await executor.drain {}
        try Task.checkCancellation()
        try await catalog.rejectedBeforeBody(editorID, session: session, request: selection.request,
            context: context, expectedBytes: selection.logicalBytes)
        finished = true
    }
    func abandonAfterActualTransportDrain() async {
        finished = true
        // DownloadExecutor drain alone does not join the separate awaited
        // catalog attachment. Join the entire actual header invocation first.
        if headerPending {
            await withCheckedContinuation { headerWaiters.append($0) }
        }
        if let decodingTask { decodingTask.cancel(); _ = try? await decodingTask.value }
        if let file {
            if acceptanceReturned {
                // Lost admission notices cannot erase the durable checked text.
                _ = await file.abandon(); await catalog.retainForRecovery(editorID); self.file = nil
            } else { await discardUnadmittedAfterLocalDrain(file, afterTransportDrain: true) }
        }
        if let unusedCleanup { await unusedCleanup.value }
        await executor.drain {}
        if let checkedPin { _ = await checkedPin.closeAndDrain(); self.checkedPin = nil }
        if begun, file == nil, !headerPending, (!headerAllocationFence.mayHaveCreatedSpool || headerRemovedBeforeAttachment), !acceptanceReturned, !admitting {
            #if DEBUG
            noBodySettlementAttempts += 1
            #endif
            await catalog.abandonedBeforeBody(editorID)
        }
        if !admitting { decodedContents = nil; checkedReference = nil }
    }

}

/// One sealed edited source, one actual journal and the existing serial writer.
/// Generic upload URL admission is unchanged. There is no fresh-upload receipt.
final class SFTPOriginalAttempt: @unchecked Sendable, CustomDebugStringConvertible {
    let record: SFTPOriginalRecord
    private let beforeBody: SFTPOriginalRecoveryRead
    private let source: SFTPUploadSource, snapshot: SFTPEditedTextSnapshot, baseline: SFTPOriginalBaseline, journal: SFTPOriginalJournal
    private let lock = NSLock()
    private var drained = false, terminal = false, continuationTaken = false, sent = false
    private var nextBaseline: (UUID, UInt64)?
    private var finishing: Task<Void, Never>?
    var debugDescription: String { "<SFTP original Save attempt>" }
    private init(record: SFTPOriginalRecord, beforeBody: SFTPOriginalRecoveryRead, source: SFTPUploadSource, snapshot: SFTPEditedTextSnapshot,
                 baseline: SFTPOriginalBaseline, journal: SFTPOriginalJournal) {
        self.record = record; self.beforeBody = beforeBody; self.source = source; self.snapshot = snapshot; self.baseline = baseline; self.journal = journal
    }
    static func prepare(baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
        session: UUID, context: SFTPVerifiedSessionContext, journal: SFTPOriginalJournal, journalRevision: UInt64) async throws -> SFTPOriginalAttempt {
        guard journal.matchesBudget(baseline.storageOwner.layout) else { throw SFTPSharedBudgetFailure.unsafe }
        let localUse = try baseline.beginLocalUse(); defer { localUse.release() }
        let edited = try baseline.editedReference(snapshot, session: session, context: context)
        let previous = baseline.retainedReference
        guard previous.digest == baseline.digest, let slash = baseline.path.lastIndex(of: "/") else { throw SFTPTextFailure.changed }
        let parent = slash == baseline.path.startIndex ? "/" : String(baseline.path[..<slash])
        let record = SFTPOriginalRecord(id: UUID(), editorGeneration: snapshot.editorGeneration, session: session,
            baselineToken: baseline.token, baselineRevision: baseline.revision, context: try SFTPOriginalContext(context),
            originalParent: parent, originalName: Data(baseline.path[baseline.path.index(after: slash)...].utf8),
            baseline: previous, edited: edited, uid: baseline.uid, gid: baseline.gid, mode: baseline.mode)
        try record.validate()
        // Claim and unused-close are one local linearization point, before any
        // await. A failed durable preparation remains retained for review.
        try baseline.claim(session: session, context: context)
        snapshot.notePublicationRequested()
        try await baseline.catalog.linkSave(baseline.editorID, record: record)
        let before = try await baseline.openBeforeBody()
        var heldSource: SFTPUploadSource?
        do {
            let source = try await SFTPUploadSource.prepare(snapshot); heldSource = source
            // Local durable failure can be uncertain. Copies remain retained;
            // no-mutation release requires the actual body job's later drain.
            snapshot.notePublicationRequested()
            try await journal.prepare(record, revision: journalRevision)
            return .init(record: record, beforeBody: before, source: source, snapshot: snapshot, baseline: baseline, journal: journal)
        } catch {
            if let heldSource { await heldSource.drain() }
            await before.closeAndDrain(); await journal.endAfterActualDrain(record.id); throw error
        }
    }

    func command() throws -> Data {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal, !sent else { throw SFTPTextFailure.closed }; sent = true
            var bytes = SFTPWire.token(record.id); bytes.append(SFTPWire.token(record.baselineToken))
            SFTPWire.number(record.baselineRevision, bytes: 8, into: &bytes); bytes.append(SFTPWire.token(record.id))
            bytes.append(SFTPWire.token(record.editorGeneration)); SFTPWire.number(record.edited.logicalBytes, bytes: 8, into: &bytes)
            bytes.append(record.edited.digest); return bytes
        }
    }
    func readOnSessionExecutor(_ payload: Data) throws -> Data {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal else { throw SFTPTextFailure.closed }
            var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let offset = try c.number(8), count = try c.number(4)
            guard c.finished, (1...32768).contains(count) else { throw SFTPProtocolFailure.invalidOutput }
            let bytes = try source.readOnSessionExecutor(offset: offset, maximum: Int(count))
            guard UInt64(bytes.count) == count else { throw SFTPTextFailure.changed }
            var reply = SFTPWire.token(record.id); SFTPWire.number(offset, bytes: 8, into: &reply); try SFTPWire.field(bytes, into: &reply); return reply
        }
    }
    func permitOnSessionExecutor(_ payload: Data) throws -> Data {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal else { throw SFTPTextFailure.closed }
            var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let edge = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            let roles = try c.take(32), digest = try c.take(32)
            guard c.finished, digest == record.edited.digest else { throw SFTPProtocolFailure.invalidOutput }
            try beforeBody.validateOnSessionExecutor()
            try source.validateEditedCreationOnSessionExecutor()
            if edge == 0 {
                guard roles == Data(repeating: 0, count: 32), requested == 0, acknowledged == 0,
                      try source.finishOnSessionExecutor() == digest else { throw SFTPTextFailure.changed }
                try journal.verifyStreamOnSessionExecutor(record.id, digest: digest)
            } else {
                guard let parsed = SFTPOriginalEdge(rawValue: UInt8(edge)) else { throw SFTPProtocolFailure.invalidOutput }
                try journal.requestEdgeOnSessionExecutor(record.id, edge: parsed, rolesDigest: roles,
                    requested: UInt8(requested), acknowledged: UInt8(acknowledged))
            }
            try beforeBody.validateOnSessionExecutor()
            try source.validateEditedCreationOnSessionExecutor()
            return payload
        }
    }
    func observedOnSessionExecutor(_ payload: Data) throws {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal else { throw SFTPTextFailure.closed }
            var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let raw = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            guard c.finished, let edge = SFTPOriginalEdge(rawValue: UInt8(raw)) else { throw SFTPProtocolFailure.invalidOutput }
            try journal.observeEdgeOnSessionExecutor(record.id, edge: edge, requested: UInt8(requested), acknowledged: UInt8(acknowledged))
        }
    }
    /// Called for187 only. This is a correlated observation, not a UI Saved
    /// receipt until the enclosing worker has also actually drained/returned.
    func completedOnSessionExecutor(_ payload: Data) throws {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal else { throw SFTPTextFailure.closed }
            var c = SFTPCursor(payload)
            let request = try c.token(), generation = try c.token()
            guard request == record.id, generation == record.editorGeneration else { throw SFTPProtocolFailure.invalidOutput }
            let next = try c.token(); let revision = try c.number(8), size = try c.number(8), digest = try c.take(32)
            let observedSize = try c.number(8); _ = try c.number(4)
            let mode = try c.number(4), uid = try c.number(4), gid = try c.number(4)
            let requested = try c.number(1), acknowledged = try c.number(1)
            let shutdown = try c.boolean(), aliases = try c.boolean(), previous = try c.boolean()
            guard shutdown, aliases, previous, c.finished, revision == record.baselineRevision + 1,
                  size == record.edited.logicalBytes, observedSize == size, digest == record.edited.digest,
                  mode == record.mode, uid == record.uid, gid == record.gid else { throw SFTPProtocolFailure.invalidOutput }
            try beforeBody.validateOnSessionExecutor()
            try source.validateEditedCreationOnSessionExecutor()
            try journal.finishObservedOnSessionExecutor(record.id, digest: digest, requested: UInt8(requested), acknowledged: UInt8(acknowledged))
            nextBaseline = (next, revision); terminal = true
        }
    }
    func interruptedOnSessionExecutor(_ payload: Data) throws -> SFTPOriginalInterruption {
        try lock.withLock {
            guard !drained, finishing == nil, !terminal else { throw SFTPTextFailure.closed }
            var c = SFTPCursor(payload); guard try c.token() == record.id else { throw SFTPProtocolFailure.invalidOutput }
            let phase = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            let cause = try c.number(1), wire = try c.number(1), status = try c.number(4)
            guard c.finished, phase <= 12, cause <= 4, wire <= 10, cause == 0 || wire == 0 && status == 0,
                  cause == 0 && wire == 6 || status == 0 else { throw SFTPProtocolFailure.invalidOutput }
            try journal.validateInterruptionOnSessionExecutor(record.id, requested: UInt8(requested), acknowledged: UInt8(acknowledged))
            terminal = true
            return .init(phase: UInt8(phase), cause: UInt8(cause), wireCause: UInt8(wire), status: UInt32(status),
                requested: UInt8(requested), acknowledged: UInt8(acknowledged))
        }
    }
    func continuationAfterActualDrain() async throws -> SFTPOriginalBaseline {
        let next = try lock.withLock { () throws -> (UUID, UInt64, TextDocumentValue) in
            guard drained, terminal, !continuationTaken, let nextBaseline else { throw SFTPTextFailure.closed }
            let contents = try snapshot.originalContinuationContents()
            continuationTaken = true
            return (nextBaseline.0, nextBaseline.1, contents)
        }
        let pin = try await baseline.catalog.continuedAndPin(baseline.editorID,
            reference: record.edited, storageOwner: baseline.storageOwner)
        return .init(session: record.session, token: next.0, revision: next.1, context: baseline.context,
            contents: next.2, origin: baseline.origin, bodyDirectory: baseline.bodyDirectory,
            path: baseline.path, uid: record.uid, gid: record.gid, mode: record.mode,
            digest: record.edited.digest, retainedReference: record.edited, catalog: baseline.catalog, editorID: baseline.editorID,
            storageOwner: baseline.storageOwner, lifetimePin: pin, mayDiscardUnused: false)
    }
    func requestStop() { source.requestStop() }
    /// Cancellation alone is never permission to call this. The real process
    /// owner invokes it only after its body/network work and callbacks finish.
    func afterActualTransportDrain() async {
        let work = lock.withLock { () -> Task<Void, Never> in
            if let finishing { return finishing }
            let work = Task { await self.finishAfterActualTransportDrain() }; finishing = work; return work
        }
        await work.value
    }
    private func finishAfterActualTransportDrain() async {
        await source.drain(); await beforeBody.closeAndDrain()
        await journal.endAfterActualDrain(record.id)
        if let current = try? await journal.inspect(), let saved = current.records.first(where: { $0.id == record.id }), saved.requested == 0 {
            snapshot.noteNoRemoteMutationAfterDrain()
        }
        _ = await snapshot.closeAndDrain()
        lock.withLock { drained = true }
    }

}

struct SFTPOriginalInterruption: Error, Sendable, CustomDebugStringConvertible {
    let phase: UInt8, cause: UInt8, wireCause: UInt8, status: UInt32, requested: UInt8, acknowledged: UInt8
    var debugDescription: String { "<SFTP original Save requires review>" }
}
