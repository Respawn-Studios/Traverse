import CryptoKit
import Darwin
import Foundation
import FileOperations

@_spi(Qualification) public enum SFTPTextFailure: String, Error, Sendable {
    case unsupported, changed, closed, busy, stopped, unavailable, full
    init(_ issue: RemoteDownloadStorageFailure) {
        switch issue {
        case .capacity, .io(ENOSPC), .io(EDQUOT): self = .full
        case .changed, .unsafe: self = .changed
        case .busy: self = .busy
        default: self = .unavailable
        }
    }
}

/// A private text-read admission uses the already prepared received-file pool.
/// This type exposes no binary publication or local destination operation.
@_spi(Qualification) public final class SFTPTextReadStorage: Sendable {
    let downloads: SFTPDownloadStorage
    public init(sharing downloads: SFTPDownloadStorage) { self.downloads = downloads }
}

/// The private body has either been removed after all users drained or kept
/// under its existing pool record for explicit review. No body path escapes.
@_spi(Qualification) public enum SFTPTextReadCloseOutcome: Sendable, Equatable {
    case removed
    case retainedForReview(UUID)
}

/// Captured by the concrete authenticated worker, never supplied by a view.
struct SFTPTextOrigin: Sendable {
    let session: UUID, selection: SFTPDownloadSelection, context: SFTPVerifiedSessionContext
    func validate(session: UUID, context: SFTPVerifiedSessionContext) throws {
        guard self.session == session, self.context.host == context.host,
              self.context.port == context.port, self.context.requestedScopeID == context.requestedScopeID,
              Data(self.context.account.utf8) == Data(context.account.utf8),
              self.context.key.bytes == context.key.bytes,
              self.context.routeKeyBinding == context.routeKeyBinding else { throw SFTPSessionFailure.security }
    }
}

/// The new-empty case has no downloaded document to impersonate. Its only
/// authority is the current authenticated upload destination and one sealed,
/// zero-byte private source owned by SFTPTextEditStorage.
private enum SFTPTextSnapshotOrigin: Sendable {
    case downloaded(SFTPTextOrigin)
    case generatedEmpty(session: UUID, destinationGeneration: UUID)

    func requireDownloaded(session: UUID, context: SFTPVerifiedSessionContext) throws {
        guard case .downloaded(let origin) = self else { throw SFTPTextFailure.unsupported }
        try origin.validate(session: session, context: context)
    }
    func validate(destination: SFTPUploadDestination) throws {
        switch self {
        case .downloaded(let origin):
            try origin.validate(session: destination.session, context: destination.context)
        case .generatedEmpty(let session, let generation):
            guard session == destination.session, generation == destination.generation else {
                throw SFTPSessionFailure.security
            }
        }
    }
    var sourceName: String {
        switch self {
        case .downloaded: "Edited snapshot"
        case .generatedEmpty: "New empty text file"
        }
    }
    var isGeneratedEmpty: Bool {
        if case .generatedEmpty = self { true } else { false }
    }
}

/// An exact checked received copy; no source URL, descriptor or remote write token.
@_spi(Qualification) public final class SFTPTextReadLease: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let file: RemoteDownloadedFile, source: DownloadPublicationLease
    private let executor = DownloadExecutor(), state = NSLock(), closeLock = NSLock(), cancellation = UploadCancellation()
    private var closed = false, decoded = false, originalRetained = false
    private var closing: Task<SFTPTextReadCloseOutcome, Never>?
    let origin: SFTPTextOrigin
    #if DEBUG
    var readProbe: (@Sendable () throws -> Void)?
    var closeRequestedForTesting: Bool { cancellation.cancelled }
    #endif
    public var description: String { "<checked SFTP text lease>" }
    public var debugDescription: String { description }
    private init(file: RemoteDownloadedFile, source: DownloadPublicationLease, origin: SFTPTextOrigin) {
        self.file = file; self.source = source; self.origin = origin
    }
    static func mint(_ file: RemoteDownloadedFile, origin: SFTPTextOrigin) async throws -> SFTPTextReadLease {
        guard file.selection == origin.selection, file.selection.logicalBytes <= UInt64(TextDocumentValue.maximumBytes) else { throw SFTPTextFailure.unsupported }
        return try await DownloadExecutor().perform {
            try .init(file: file, source: file.claimPublicationOnWorker(), origin: origin)
        }
    }
    public func read() async throws -> TextDocumentValue {
        do { return try await withTaskCancellationHandler {
            let result = try await executor.perform { [self] in
                try state.withLock {
                    guard !closed else { throw SFTPTextFailure.closed }
                    try check()
                    #if DEBUG
                    try readProbe?()
                    #endif
                    try check()
                    let value = try source.withSource(check: { try self.check() }) { descriptor, _ in
                        guard source.logicalBytes <= UInt64(TextDocumentValue.maximumBytes) else { throw SFTPTextFailure.unsupported }
                        var data = Data(count: Int(source.logicalBytes)), offset = 0
                        while offset < data.count {
                            try check()
                            let count = min(32768, data.count - offset)
                            let found = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: offset), count, off_t(offset)) }
                            if found < 0 && errno == EINTR { continue }
                            guard found == count else { throw SFTPTextFailure.changed }; offset += found
                        }
                        guard Data(SHA256.hash(data: data)) == source.digest else { throw SFTPTextFailure.changed }
                        try check(); return try TextDocumentValue.original(data)
                    }
                    try check(); decoded = true; return value
                }
            }
            try check(); return result
        } onCancel: { self.cancellation.cancel() }
        } catch let issue as RemoteDownloadStorageFailure { throw SFTPTextFailure(issue) }
        catch is CancellationError { throw SFTPTextFailure.stopped }
    }
    func captureOrigin() async throws -> SFTPTextOrigin {
        try await executor.perform { [self] in
            try state.withLock {
                guard !closed, decoded else { throw SFTPTextFailure.closed }; try check(); return origin
            }
        }
    }
    // Internal original-Save authority keeps this exact checked body. There is
    // no URL handoff, generic cache exception or implicit startup body read.
    func retainOriginalReference() async throws -> SFTPOriginalSpoolReference {
        try await executor.perform { [self] in try state.withLock {
            guard !closed, decoded else { throw SFTPTextFailure.closed }; try check()
            try source.withSource(check: { try self.check() }) { _, _ in () }
            originalRetained = true
            return .init(id: file.id, logicalBytes: source.logicalBytes, digest: source.digest)
        } }
    }
    private func check() throws { if cancellation.cancelled { throw SFTPTextFailure.stopped } }
    public func closeAndDrain() async { _ = await finishClose() }
    /// A current-server viewer needs the actual after-drain cleanup result.
    /// Existing original-editor owners keep their unchanged void close API.
    public func closeForViewer() async -> SFTPTextReadCloseOutcome { await finishClose() }
    private func finishClose() async -> SFTPTextReadCloseOutcome {
        let task = closeLock.withLock { () -> Task<SFTPTextReadCloseOutcome, Never> in
            if let closing { return closing }
            let task = Task<SFTPTextReadCloseOutcome, Never> { [self] in
                cancellation.cancel()
                await executor.drain { [self] in state.withLock { closed = true; source.release() } }
                if state.withLock({ originalRetained }) {
                    _ = await file.abandon(); return .retainedForReview(file.id)
                }
                do { try await file.removeAfterDrain(); return .removed }
                catch { _ = await file.abandon(); return .retainedForReview(file.id) }
            }
            closing = task; return task
        }
        return await task.value
    }
    deinit { source.release() }
}

/// Explicit edited captures only. Two retained snapshots, each <=1MiB, share
/// the real pool lock and rounded quota; no automatic draft/startup body read.
@_spi(Qualification) public final class SFTPTextEditStorage: Sendable {
    private let directory: URL, executor = DownloadExecutor(), hooks: DownloadIOHooks
    private let originalText: Bool
    private let reviewStore: RemoteDownloadStore
    public init(directory: URL) throws {
        reviewStore = try RemoteDownloadStore(directory: directory); self.directory = directory; hooks = .init(); originalText = false
    }
    init(directory: URL, hooks: DownloadIOHooks, reviewStore: RemoteDownloadStore? = nil) throws {
        let actual: RemoteDownloadStore
        if let reviewStore { actual = reviewStore } else { actual = try RemoteDownloadStore(directory: directory) }
        guard actual.directory == directory else { throw SFTPTextFailure.changed }
        self.reviewStore = actual; self.directory = directory; self.hooks = hooks; originalText = false
    }
    init(originalDirectory: URL) throws {
        reviewStore = try RemoteDownloadStore(directory: originalDirectory); directory = originalDirectory; hooks = .init(); originalText = true
    }
    public func stage(contents: TextDocumentValue, editorGeneration: UUID,
                      from source: SFTPTextReadLease) async throws -> SFTPEditedTextSnapshot {
        guard !originalText else { throw SFTPTextFailure.unsupported }
        let cancellation = UploadCancellation()
        do { return try await withTaskCancellationHandler {
            let result = try await stageCaptured(contents: contents, editorGeneration: editorGeneration,
                from: source, cancellation: cancellation)
            if cancellation.cancelled { _ = await result.closeAndDrain(); throw SFTPTextFailure.stopped }
            return result
        } onCancel: { cancellation.cancel() }
        } catch let issue as RemoteDownloadStorageFailure { throw SFTPTextFailure(issue) }
        catch is CancellationError { throw SFTPTextFailure.stopped }
    }
    /// Explicit Remote New Text File source. No caller URL or downloaded
    /// document can enter this factory; the normal upload attempt still checks
    /// the authenticated session and current destination generation.
    public func stageGeneratedEmpty(session: UUID, destinationGeneration: UUID) async throws -> SFTPEditedTextSnapshot {
        guard !originalText, SFTPWire.validToken(session), SFTPWire.validToken(destinationGeneration) else {
            throw SFTPTextFailure.unsupported
        }
        let cancellation = UploadCancellation()
        do {
            return try await withTaskCancellationHandler {
                let empty = try TextDocumentValue.original(Data())
                let snapshot = try await stageCaptured(contents: empty, editorGeneration: UUID(),
                    origin: .generatedEmpty(session: session, destinationGeneration: destinationGeneration),
                    cancellation: cancellation)
                if cancellation.cancelled { _ = await snapshot.closeAndDrain(); throw SFTPTextFailure.stopped }
                return snapshot
            } onCancel: { cancellation.cancel() }
        } catch let issue as RemoteDownloadStorageFailure { throw SFTPTextFailure(issue) }
        catch is CancellationError { throw SFTPTextFailure.stopped }
    }
    /// Experimental original-only producer. A closed ordinary read lease or
    /// arbitrary URL cannot mint this sealed origin or choose another pool.
    func stageOriginal(contents: TextDocumentValue, editorGeneration: UUID,
                       from baseline: SFTPOriginalBaseline) async throws -> SFTPEditedTextSnapshot {
        guard originalText else { throw SFTPTextFailure.unsupported }
        let localUse = try baseline.beginLocalUse()
        let cancellation = UploadCancellation()
        do {
            let authority = try baseline.stagingAuthority(in: directory)
            return try await withTaskCancellationHandler {
            let result = try await stageCaptured(contents: contents, editorGeneration: editorGeneration, origin: .downloaded(authority.origin),
                cancellation: cancellation, binding: authority.binding, originalUse: localUse, originalOwner: authority.owner)
            if cancellation.cancelled { _ = await result.closeAndDrain(); throw SFTPTextFailure.stopped }; return result
        } onCancel: { cancellation.cancel() }
        } catch let issue as RemoteDownloadStorageFailure { localUse.release(); throw SFTPTextFailure(issue) }
        catch is CancellationError { localUse.release(); throw SFTPTextFailure.stopped }
        catch { localUse.release(); throw error }
    }
    func stageInPlace(contents: TextDocumentValue, editorGeneration: UUID, from baseline: SFTPInPlaceBaseline) async throws -> SFTPEditedTextSnapshot {
        guard originalText else { throw SFTPTextFailure.unsupported }
        let localUse = try baseline.beginLocalUse(), cancellation = UploadCancellation()
        do {
            let authority = try baseline.stagingAuthority(in: directory)
            return try await withTaskCancellationHandler {
                let result = try await stageCaptured(contents: contents, editorGeneration: editorGeneration, origin: .downloaded(authority.origin),
                    cancellation: cancellation, inPlaceBinding: authority.binding, originalUse: localUse, originalOwner: authority.owner)
                if cancellation.cancelled { _ = await result.closeAndDrain(); throw SFTPTextFailure.stopped }; return result
            } onCancel: { cancellation.cancel() }
        } catch { localUse.release(); throw error }
    }
    private func stageCaptured(contents: TextDocumentValue, editorGeneration: UUID,
        from source: SFTPTextReadLease, cancellation: UploadCancellation) async throws -> SFTPEditedTextSnapshot {
        let origin = try await source.captureOrigin()
        return try await stageCaptured(contents: contents, editorGeneration: editorGeneration, origin: .downloaded(origin), cancellation: cancellation)
    }
    private func stageCaptured(contents: TextDocumentValue, editorGeneration: UUID,
        origin: SFTPTextSnapshotOrigin, cancellation: UploadCancellation, binding: SFTPOriginalStageBinding? = nil, inPlaceBinding: SFTPInPlaceStageBinding? = nil,
        originalUse: SFTPOriginalBaselineUse? = nil, originalOwner: SFTPOriginalStorageOwner? = nil) async throws -> SFTPEditedTextSnapshot {
        guard !cancellation.cancelled else { throw SFTPTextFailure.stopped }
        guard SFTPWire.validToken(editorGeneration) else { throw SFTPTextFailure.unsupported }
        let request = UUID()
        let spool = try await executor.perform { [directory, hooks, originalText] in
            guard !cancellation.cancelled else { throw SFTPTextFailure.stopped }
            guard try TextDocumentValue.original(contents.encoded) == contents else { throw SFTPTextFailure.changed }
            return try RemoteDownloadSpool(directory: directory, request: request,
                expectedBytes: UInt64(contents.encoded.count), tree: false, hooks: hooks, editedText: !originalText,
                originalText: originalText, originalOwner: originalOwner)
        }
        do {
            try await executor.perform {
                var offset = 0
                while offset < contents.encoded.count {
                    guard !cancellation.cancelled else { throw SFTPTextFailure.stopped }
                    let end = min(offset + 32768, contents.encoded.count)
                    try spool.appendOnSessionExecutor(request: request, offset: UInt64(offset), bytes: contents.encoded.subdata(in: offset..<end))
                    offset = end
                }
            }
            let digest = try await spool.seal(request: request, receivedBytes: UInt64(contents.encoded.count))
            guard !cancellation.cancelled else { throw SFTPTextFailure.stopped }
            return .init(spool: spool, reviewStore: reviewStore, origin: origin,
                         editorGeneration: editorGeneration, logicalBytes: UInt64(contents.encoded.count), digest: digest,
                         originalPool: originalText ? directory : nil, originalContents: originalText ? contents : nil, originalBinding: binding, inPlaceBinding: inPlaceBinding, originalUse: originalUse)
        } catch {
            do { try await spool.removeAfterDrain() } catch { _ = await spool.abandon() }
            throw error
        }
    }
}

@_spi(Qualification) public final class SFTPEditedTextSnapshot: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let editorGeneration: UUID, logicalBytes: UInt64
    private let spool: RemoteDownloadSpool, reviewStore: RemoteDownloadStore, origin: SFTPTextSnapshotOrigin, digest: Data
    private let originalPool: URL?, originalContents: TextDocumentValue?, originalBinding: SFTPOriginalStageBinding?
    private let inPlaceBinding: SFTPInPlaceStageBinding?
    private let originalUse: SFTPOriginalBaselineUse?
    let cancellation = UploadCancellation()
    private let state = NSLock()
    private var claimed = false, closed = false, publicationRequested = false, retained = false, users = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closing: Task<Bool, Never>?, discarding: Task<Bool, Never>?
    private var discardID: UUID?, discarded = false
    private var discardAttempts = 0, discardJoins = 0
    var discardStateForQualification: (pending: Bool, attempts: Int, joins: Int) {
        state.withLock { (discarding != nil, discardAttempts, discardJoins) }
    }
    public var retainedForReview: Bool { state.withLock { retained } }
    func notePublicationRequested() { state.withLock { publicationRequested = true } }
    func noteNoRemoteMutationAfterDrain() { state.withLock { publicationRequested = false } }
    var uploadSourceName: String { origin.sourceName }
    public var description: String { "<sealed SFTP edited text snapshot>" }
    public var debugDescription: String { description }
    fileprivate init(spool: RemoteDownloadSpool, reviewStore: RemoteDownloadStore, origin: SFTPTextSnapshotOrigin,
                     editorGeneration: UUID, logicalBytes: UInt64, digest: Data, originalPool: URL? = nil, originalContents: TextDocumentValue? = nil, originalBinding: SFTPOriginalStageBinding? = nil, inPlaceBinding: SFTPInPlaceStageBinding? = nil, originalUse: SFTPOriginalBaselineUse? = nil) {
        self.spool = spool; self.reviewStore = reviewStore; self.origin = origin; self.editorGeneration = editorGeneration
        self.logicalBytes = logicalBytes; self.digest = digest; self.originalPool = originalPool; self.originalContents = originalContents; self.originalBinding = originalBinding; self.inPlaceBinding = inPlaceBinding; self.originalUse = originalUse
    }
    func originalContinuationContents() throws -> TextDocumentValue {
        try state.withLock {
            guard closed, retained, users == 0, originalBinding != nil, let originalContents else { throw SFTPTextFailure.closed }; return originalContents
        }
    }
    func originalReference(context: SFTPVerifiedSessionContext, session: UUID, directory: URL, binding: SFTPOriginalStageBinding) throws -> SFTPOriginalSpoolReference {
        try origin.requireDownloaded(session: session, context: context)
        return try state.withLock {
            guard !closed, !claimed else { throw SFTPTextFailure.closed }
            guard originalPool == directory, originalContents != nil, originalBinding == binding else { throw SFTPSessionFailure.security }
            return .init(id: spool.id, logicalBytes: logicalBytes, digest: digest)
        }
    }
    func inPlaceReference(context: SFTPVerifiedSessionContext, session: UUID, directory: URL, binding: SFTPInPlaceStageBinding) throws -> SFTPOriginalSpoolReference {
        try origin.requireDownloaded(session: session, context: context)
        return try state.withLock {
            guard !closed, !claimed, originalBinding == nil, inPlaceBinding == binding, originalPool == directory, originalContents != nil else { throw SFTPTextFailure.closed }
            return .init(id: spool.id, logicalBytes: logicalBytes, digest: digest)
        }
    }
    func inPlaceContinuationContents() throws -> TextDocumentValue {
        try state.withLock {
            guard closed, retained, users == 0, originalBinding == nil, inPlaceBinding != nil, let originalContents else { throw SFTPTextFailure.closed }; return originalContents
        }
    }
    func validate(destination: SFTPUploadDestination) throws {
        try origin.validate(destination: destination)
        try state.withLock { guard !closed, !claimed else { throw SFTPTextFailure.closed } }
    }
    func claimPinnedSource() throws -> (PinnedLocalFileSource, DownloadPublicationLease, Data) {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        try state.withLock {
            guard !closed, !claimed, !cancellation.cancelled else { throw SFTPTextFailure.closed }
            claimed = true; users = 1
        }
        do {
            let lease = try spool.claimPublicationOnWorker()
            do {
                guard lease.logicalBytes == logicalBytes, lease.digest == digest else { throw SFTPTextFailure.changed }
                let pinned = try lease.withSource(check: { if self.cancellation.cancelled { throw SFTPTextFailure.stopped } }) { _, url in
                    try PinnedLocalFileSource(url)
                }
                return (pinned, lease, digest)
            } catch { lease.release(); throw error }
        } catch { sourceEndedAfterDrain(); throw error }
    }
    func sourceEndedAfterDrain() {
        let done = state.withLock { () -> [CheckedContinuation<Void, Never>] in
            users = 0; let result = waiters; waiters.removeAll(); return result
        }
        done.forEach { $0.resume() }
    }
    public func closeAndDrain() async -> Bool {
        let work = state.withLock { () -> Task<Bool, Never> in
            if let closing { return closing }
            closed = true
            let work = Task { await self.cleanupAfterUsers() }; closing = work; return work
        }
        return await work.value
    }
    private func cleanupAfterUsers() async -> Bool {
        defer { originalUse?.release() }
        cancellation.cancel()
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { () -> Bool in
                closed = true
                if users == 0 { return true }; waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
        // A generated empty source contains no user-authored body and has no
        // remote recovery authority. Its upload ledger retains any uncertain
        // publication outcome independently of this local spool.
        let disposableEmpty = origin.isGeneratedEmpty && logicalBytes == 0
            && digest == Data(SHA256.hash(data: Data()))
        if state.withLock({ publicationRequested && !(disposableEmpty && claimed && users == 0) }) {
            let released = await spool.abandon()
            state.withLock { retained = released }; return false
        }
        do { try await spool.removeAfterDrain(); return true }
        catch { _ = await spool.abandon(); return false }
    }
    /// Explicit review discard only, after actual users and private descriptors drain.
    public func discardRetainedAfterReview() async -> Bool {
        let current: (task: Task<Bool, Never>, id: UUID)? = state.withLock {
            // Refusing an ineligible review creates no task and poisons no later action.
            guard closed, retained, users == 0, !discarded else { return nil }
            if let discarding, let discardID {
                discardJoins += 1; return (discarding, discardID)
            }
            let id = UUID()
            let work = Task { () -> Bool in
                do {
                    if self.originalPool != nil { try await self.spool.discardRetainedOriginalAfterReview() }
                    else { try await self.reviewStore.discardIncomplete(self.spool.id) }
                    return true
                }
                catch { return false }
            }
            discarding = work; discardID = id; discardAttempts += 1
            return (work, id)
        }
        guard let current else { return state.withLock { discarded } }
        let result = await current.task.value
        state.withLock {
            // An older waiter must not clear a newer explicitly reviewed retry.
            guard discardID == current.id else { return }
            if result { retained = false; discarded = true }
            discarding = nil; discardID = nil
        }
        return result
    }

}

@_spi(Qualification) public struct SFTPRequestedEditedTextUpload: Sendable, CustomDebugStringConvertible {
    public let destinationGeneration: UUID, name: SFTPRemoteName
    let snapshot: SFTPEditedTextSnapshot
    public var debugDescription: String { "<SFTP edited text fresh upload request>" }
    public init(destinationGeneration: UUID, snapshot: SFTPEditedTextSnapshot, name: String) throws {
        let parsed = try SFTPRemoteName(Data(name.utf8))
        guard SFTPWire.validToken(destinationGeneration), parsed.wireUTF8.count <= 255 else { throw SFTPTextFailure.unsupported }
        self.destinationGeneration = destinationGeneration; self.snapshot = snapshot; self.name = parsed
    }
}
@_spi(Qualification) public struct SFTPTextFreshCopyReceipt: Sendable, CustomDebugStringConvertible {
    public let editorGeneration: UUID, uploadID: UUID
    public var debugDescription: String { "<SFTP acknowledged fresh text copy>" }
    init(_ completion: SFTPCompletedUpload, snapshot: SFTPEditedTextSnapshot) throws {
        guard completion.logicalBytes == snapshot.logicalBytes else { throw SFTPTextFailure.changed }
        editorGeneration = snapshot.editorGeneration; uploadID = completion.id
    }
}
