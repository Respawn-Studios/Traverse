import CryptoKit
import Foundation

/// Preparation failed before an upload command crossed into the worker. The
/// browse pump may preserve this still read-only connection after that refusal.
struct SFTPUploadAdmissionFailure: Error { let cause: any Error }

@_spi(Qualification) public enum SFTPUploadLocalIssue: String, Error, Sendable {
    case sourceUnavailable, unsupportedSource, additionalFork, sourceChanged, historyUnavailable, historyFull, busy, stopped
    init(_ source: SFTPUploadSourceFailure) {
        switch source {
        case .unavailable: self = .sourceUnavailable
        case .unsupported: self = .unsupportedSource
        case .unsupportedMetadata: self = .additionalFork
        case .changed: self = .sourceChanged
        case .busy: self = .busy
        case .stopped: self = .stopped
        }
    }
    init(_ history: RemoteSettingsFailure) {
        switch history { case .capacity: self = .historyFull; case .busy: self = .busy; case .cancelled: self = .stopped; default: self = .historyUnavailable }
    }
}

@_spi(Qualification) public struct SFTPRequestedUpload: Sendable, CustomDebugStringConvertible {
    public let generation: UUID, source: URL, name: SFTPRemoteName
    let expectedSource: PinnedLocalFileSource.Stamp?
    public init(generation: UUID, source: URL, name: String) throws {
        guard SFTPWire.validToken(generation), source.isFileURL, source.query == nil, source.fragment == nil,
              source.path == source.standardizedFileURL.path else { throw SFTPSessionFailure.input }
        let parsed = try SFTPRemoteName(Data(name.utf8))
        guard parsed.wireUTF8.count <= 255 else { throw SFTPSessionFailure.input }
        self.generation = generation; self.source = source; self.name = parsed; expectedSource = nil
    }
    public init(generation: UUID, reviewed source: SFTPUploadSourceReview, name: String) throws {
        let value = try Self(generation: generation, source: source.url, name: name)
        self.generation = value.generation; self.source = value.source; self.name = value.name; expectedSource = source.observation
    }
    public var debugDescription: String { "<SFTP explicit upload request>" }
}

/// Metadata-only preview. Admission reopens/rechecks this observation before
/// any remote command; neither this value nor the preview grants file access.
@_spi(Qualification) public struct SFTPUploadSourceReview: Sendable, CustomDebugStringConvertible {
    public let name: String, logicalBytes: UInt64
    let url: URL, observation: PinnedLocalFileSource.Stamp
    public var debugDescription: String { "<SFTP reviewed local source>" }
    public static func inspect(_ url: URL, excluding roots: [URL]) async throws -> Self {
        do {
            let source = try await SFTPUploadSource.prepare(url, excluding: roots)
            let snapshot = source.snapshot; await source.drain()
            try Task.checkCancellation()
            return .init(name: snapshot.name, logicalBytes: snapshot.logicalBytes, url: url, observation: snapshot.observation)
        } catch let failure as SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(failure) }
    }
}

@_spi(Qualification) public struct SFTPUploadRecordSummary: Sendable {
    public let id: UUID, host: String, port: UInt16, account: String
    public let sourceName: String, remoteName: SFTPRemoteName, directoryUTF8: Data, logicalBytes: UInt64
    public let outcome: SFTPUploadOutcome, active: Bool
    public let publication: SFTPUploadPublication
    public var folder: SFTPFolderUploadRecordSummary? = nil
}
@_spi(Qualification) public struct SFTPFolderUploadRecordSummary: Sendable {
    public let files: Int, folders: Int, rootAcknowledged: Bool, verifiedFiles: Int, verifiedBytes: UInt64
}
@_spi(Qualification) public struct SFTPUploadHistorySnapshot: Sendable {
    public let revision: UInt64, records: [SFTPUploadRecordSummary]
}
@_spi(Qualification) public struct SFTPCompletedUpload: Sendable, CustomDebugStringConvertible {
    public let id: UUID, logicalBytes: UInt64
    public var debugDescription: String { "<SFTP completed upload>" }
}

/// Passive construction/inspection create nothing. Records contain names and
/// server/account metadata, never bodies, passwords or reusable access grants.
@_spi(Qualification) public final class SFTPUploadStorage: Sendable {
    let ledger: SFTPUploadLedger
    public init(directory: URL) { ledger = .init(directory: directory) }
    init(directory: URL, probe: @escaping @Sendable (SFTPUploadLedger.Stage) throws -> Void) { ledger = .init(directory: directory, probe: probe) }
    public func inspect() async throws -> SFTPUploadHistorySnapshot {
        let saved = try await ledger.inspect()
        return .init(revision: saved.revision, records: try saved.records.map { record in
            .init(id: record.id, host: record.host.host, port: record.host.port, account: record.account,
                sourceName: try SFTPRemoteName(Data(record.source.name.utf8)).displayName,
                remoteName: try SFTPRemoteName(Data(record.remoteName.utf8)), directoryUTF8: Data(record.remoteDirectory.utf8),
                logicalBytes: record.source.logicalBytes, outcome: record.outcome, active: saved.active.contains(record.id), publication: record.publicationKind,
                folder: {
                    guard case .folder(let source) = record.source, let progress = record.folderProgress else { return nil }
                    return .init(files: source.files, folders: source.folders, rootAcknowledged: progress.rootAcknowledged,
                        verifiedFiles: progress.verifiedFiles, verifiedBytes: progress.verifiedBytes)
                }())
        })
    }
    /// Explicit local Forget only. No remote request, retry or deletion.
    public func forget(_ id: UUID, revision: UInt64) async throws { _ = try await ledger.forget(id, revision: revision) }
    public func recoverUncommittedLocalStage() async throws { try await ledger.recoverUncommittedStage() }
    public func close() async -> Bool { await ledger.close() }
}

struct SFTPUploadDestination: Sendable {
    let session: UUID, generation: UUID, revision: UInt64, directory: String
    let context: SFTPVerifiedSessionContext
}

/// An active claim exists only in memory after its Prepared record is durable.
/// It cannot be reconstructed from a saved summary or used by another session.
final class SFTPUploadAttempt: @unchecked Sendable {
    let selection: SFTPUploadSelection, record: SFTPUploadRecord
    private let expectedSession: UUID, source: SFTPUploadSource, ledger: SFTPUploadLedger
    private let expectedRouteBinding: Data?
    private let editedSnapshot: SFTPEditedTextSnapshot?
    private enum Ownership { case pending, worker, ended }
    private let lock = NSLock(); private var ownership = Ownership.pending
    private init(destination: SFTPUploadDestination, source: SFTPUploadSource, ledger: SFTPUploadLedger, record: SFTPUploadRecord,
                 editedSnapshot: SFTPEditedTextSnapshot? = nil) throws {
        guard record.source == .file(source.snapshot), record.outcome == .prepared, record.publicationKind == .exclusiveFinal else { throw SFTPSessionFailure.input }
        selection = try .init(request: record.id, generation: destination.generation, revision: destination.revision,
            directory: destination.directory, name: SFTPRemoteName(Data(record.remoteName.utf8)), logicalBytes: source.snapshot.logicalBytes)
        expectedSession = destination.session; expectedRouteBinding = destination.context.routeKeyBinding
        self.source = source; self.ledger = ledger; self.record = record; self.editedSnapshot = editedSnapshot
    }
    static func prepare(_ request: SFTPRequestedUpload, destination: SFTPUploadDestination, storage: SFTPUploadStorage,
                        excluding roots: [URL]) async throws -> SFTPUploadAttempt {
        guard request.generation == destination.generation else { throw SFTPProtocolFailure.stale }
        let source = try await SFTPUploadSource.prepare(request.source, excluding: roots)
        return try await prepareCaptured(source, expected: request.expectedSource, name: request.name,
            destination: destination, storage: storage)
    }
    static func prepare(_ request: SFTPRequestedEditedTextUpload, destination: SFTPUploadDestination,
                        storage: SFTPUploadStorage) async throws -> SFTPUploadAttempt {
        guard request.destinationGeneration == destination.generation else { throw SFTPProtocolFailure.stale }
        try request.snapshot.validate(destination: destination)
        let source = try await SFTPUploadSource.prepare(request.snapshot)
        return try await prepareCaptured(source, expected: nil, name: request.name, destination: destination,
            storage: storage, editedSnapshot: request.snapshot)
    }
    private static func prepareCaptured(_ source: SFTPUploadSource, expected: PinnedLocalFileSource.Stamp?,
        name: SFTPRemoteName, destination: SFTPUploadDestination, storage: SFTPUploadStorage,
        editedSnapshot: SFTPEditedTextSnapshot? = nil) async throws -> SFTPUploadAttempt {
        var saved: SFTPUploadRecord?
        do {
            try Task.checkCancellation()
            if let expected, expected != source.snapshot.observation { throw SFTPUploadSourceFailure.changed }
            // Only a pre-mutation local revision collision is retried. A failed
            // durable write or remote request is never retried here.
            for index in 0..<3 {
                let snapshot = try await storage.ledger.inspect()
                do {
                    let value = try await storage.ledger.prepare(host: .init(canonicalHost: destination.context.host, port: destination.context.port, interfaceScope: destination.context.requestedScopeID),
                        account: destination.context.account, key: destination.context.key, directory: destination.directory,
                        name: String(decoding: name.wireUTF8, as: UTF8.self), source: source.snapshot, revision: snapshot.revision)
                    saved = value.record
                    guard !value.completedAfterCancellation, !Task.isCancelled else { throw CancellationError() }
                    break
                } catch RemoteSettingsFailure.staleRevision where index < 2 { try Task.checkCancellation() }
            }
            guard let saved else { throw RemoteSettingsFailure.unavailable }
            return try .init(destination: destination, source: source, ledger: storage.ledger, record: saved, editedSnapshot: editedSnapshot)
        } catch {
            await source.drain()
            if let saved { _ = try? await storage.ledger.endAfterDrain(saved.id, noRemoteMutation: true) }
            throw error
        }
    }
    func validate(session: UUID, context: SFTPVerifiedSessionContext) throws {
        guard session == expectedSession, context.host == record.host.host, context.port == record.host.port,
              context.requestedScopeID == record.host.interfaceScope, Data(context.account.utf8) == Data(record.account.utf8),
              Data(SHA256.hash(data: context.key.bytes)) == record.hostKeyDigest,
              context.routeKeyBinding == expectedRouteBinding else { throw SFTPSessionFailure.security }
    }
    func takeForWorker() throws {
        try lock.withLock { guard ownership == .pending else { throw SFTPSessionFailure.input }; ownership = .worker }
    }
    func requestStop() { source.requestStop() }
    func readOnSessionExecutor(offset: UInt64, count: Int) throws -> Data { try source.readOnSessionExecutor(offset: offset, maximum: count) }
    func requestCreationOnSessionExecutor() throws {
        guard lock.withLock({ ownership == .worker }) else { throw SFTPSessionFailure.input }
        if editedSnapshot != nil { try source.validateEditedCreationOnSessionExecutor() }
        _ = try ledger.requestPublicationOnSessionExecutor(record.id)
        editedSnapshot?.notePublicationRequested()
        if editedSnapshot != nil { try source.validateEditedCreationOnSessionExecutor() }
    }
    func permitPublicationOnSessionExecutor(digest: Data) throws {
        guard try source.finishOnSessionExecutor() == digest else { throw SFTPSessionFailure.sourceChanged }
        try ledger.requireCreationRequestedOnSessionExecutor(record.id)
        guard try source.finishOnSessionExecutor() == digest else { throw SFTPSessionFailure.sourceChanged }
    }
    func finishOnSessionExecutor(_ receipt: SFTPUploadReceipt) throws -> SFTPCompletedUpload {
        guard receipt.selection == selection, try source.finishOnSessionExecutor() == receipt.digest else { throw SFTPSessionFailure.sourceChanged }
        _ = try ledger.verifyOnSessionExecutor(record.id, digest: receipt.digest)
        try source.closeAfterDrainOnSessionExecutor(); _ = try ledger.endAfterDrainOnSessionExecutor(record.id)
        lock.withLock { ownership = .ended }
        return .init(id: record.id, logicalBytes: selection.logicalBytes)
    }
    /// The worker has returned its typed, clean-channel first-OPEN refusal.
    /// Finish the source and durable notStarted transition before the session
    /// may accept another request. A local save failure remains a hard error.
    func finishRefusedOpenOnSessionExecutor() throws {
        guard lock.withLock({ ownership == .worker }) else { throw SFTPSessionFailure.input }
        try source.closeAfterDrainOnSessionExecutor()
        _ = try ledger.endAfterDrainOnSessionExecutor(record.id, noRemoteMutation: true)
        editedSnapshot?.noteNoRemoteMutationAfterDrain()
        lock.withLock { ownership = .ended }
    }
    /// Only after the process owner proves actual source users/child/IPC drain.
    /// A failed local outcome save still leaves its conservative durable prefix.
    func endAfterActualDrainOnSessionExecutor(noRemoteMutation: Bool) {
        guard lock.withLock({ ownership == .worker }) else { return }
        if noRemoteMutation { editedSnapshot?.noteNoRemoteMutationAfterDrain() }
        _ = try? source.closeAfterDrainOnSessionExecutor()
        _ = try? ledger.endAfterDrainOnSessionExecutor(record.id, noRemoteMutation: noRemoteMutation)
        lock.withLock { ownership = .ended }
    }
    func discardUnsent() async {
        let release = lock.withLock { if ownership == .pending { ownership = .ended; return true }; return false }
        guard release else { return }; await source.drain(); _ = try? await ledger.endAfterDrain(record.id, noRemoteMutation: true)
    }
    deinit {
        let unsent = lock.withLock { ownership == .pending }
        if unsent {
            let source = source, ledger = ledger, id = record.id
            Task { await source.drain(); _ = try? await ledger.endAfterDrain(id, noRemoteMutation: true) }
        }
    }
}
