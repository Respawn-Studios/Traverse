import CryptoKit
import Foundation

@_spi(Qualification) public struct SFTPFolderUploadSourceReview: Sendable, CustomDebugStringConvertible {
    public let name: String, files: Int, folders: Int, logicalBytes: UInt64
    let url: URL, snapshot: SFTPFolderUploadSourceSnapshot
    public var debugDescription: String { "<SFTP reviewed local folder>" }
    public static func inspect(_ url: URL, excluding roots: [URL]) async throws -> Self {
        do {
            let source = try await SFTPFolderUploadSource.prepare(url, excluding: roots), snapshot = source.snapshot
            await source.drain(); try Task.checkCancellation()
            return .init(name: snapshot.name, files: snapshot.files, folders: snapshot.folders, logicalBytes: snapshot.logicalBytes, url: url, snapshot: snapshot)
        } catch let failure as SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(failure) }
    }
}
@_spi(Qualification) public struct SFTPRequestedFolderUpload: Sendable, CustomDebugStringConvertible {
    public let generation: UUID, name: SFTPRemoteName
    let source: SFTPFolderUploadSourceReview
    public init(generation: UUID, reviewed source: SFTPFolderUploadSourceReview, name: String) throws {
        guard SFTPWire.validToken(generation) else { throw SFTPProtocolFailure.invalidInput }
        let name = try SFTPRemoteName(Data(name.utf8)); guard name.wireUTF8.count <= 255 else { throw SFTPProtocolFailure.invalidInput }
        self.generation = generation; self.name = name; self.source = source
    }
    public var debugDescription: String { "<SFTP explicit folder upload request>" }
}
@_spi(Qualification) public struct SFTPCompletedFolderUpload: Sendable, CustomDebugStringConvertible {
    public let id: UUID, files: Int, folders: Int, logicalBytes: UInt64
    public var debugDescription: String { "<SFTP completed folder upload>" }
}

/// One live source/history claim; it cannot be reconstructed from cold history.
/// Source access, durable root intent, per-member proof and actual drain have
/// distinct barriers. No remote path is ever deletion/retry authority.
final class SFTPFolderUploadAttempt: @unchecked Sendable {
    let selection: SFTPFolderUploadSelection, record: SFTPUploadRecord
    private let source: SFTPFolderUploadSource, ledger: SFTPUploadLedger, expectedSession: UUID
    private let expectedRouteBinding: Data?
    private let clock: @Sendable () -> TimeInterval
    private enum Ownership { case pending, worker, ended }
    private let lock = NSLock(); private var ownership = Ownership.pending
    private var rootAcknowledged = false, verifiedFiles = 0, verifiedBytes: UInt64 = 0, pendingVerifiedNode: Int?
    private var checkpointFiles = 0, checkpointTime: TimeInterval, permittedDigest: Data?
    private init(destination: SFTPUploadDestination, source: SFTPFolderUploadSource, ledger: SFTPUploadLedger, record: SFTPUploadRecord, clock: @escaping @Sendable () -> TimeInterval) throws {
        guard record.source == .folder(source.snapshot), record.outcome == .prepared, record.publication == .exclusiveFreshFolder else { throw SFTPSessionFailure.input }
        selection = try .init(request: record.id, generation: destination.generation, revision: destination.revision, directory: destination.directory,
            name: SFTPRemoteName(Data(record.remoteName.utf8)), manifest: source.manifest)
        expectedSession = destination.session; expectedRouteBinding = destination.context.routeKeyBinding
        self.source = source; self.ledger = ledger; self.record = record; self.clock = clock; checkpointTime = clock()
    }
    static func prepare(_ request: SFTPRequestedFolderUpload, destination: SFTPUploadDestination, storage: SFTPUploadStorage, excluding roots: [URL],
                        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws -> Self {
        guard request.generation == destination.generation else { throw SFTPProtocolFailure.stale }
        let source = try await SFTPFolderUploadSource.prepare(request.source.url, excluding: roots)
        var saved: SFTPUploadRecord?
        do {
            try Task.checkCancellation()
            guard source.snapshot.inventoryDigest == request.source.snapshot.inventoryDigest,
                  Data(source.snapshot.name.utf8) == Data(request.source.snapshot.name.utf8) else { throw SFTPUploadSourceFailure.changed }
            for index in 0..<3 {
                let snapshot = try await storage.ledger.inspect()
                do {
                    let value = try await storage.ledger.prepareFolder(host: .init(canonicalHost: destination.context.host, port: destination.context.port, interfaceScope: destination.context.requestedScopeID),
                        account: destination.context.account, key: destination.context.key, directory: destination.directory,
                        name: String(decoding: request.name.wireUTF8, as: UTF8.self), source: source.snapshot, revision: snapshot.revision)
                    saved = value.record; guard !value.completedAfterCancellation, !Task.isCancelled else { throw CancellationError() }; break
                } catch RemoteSettingsFailure.staleRevision where index < 2 { try Task.checkCancellation() }
            }
            guard let saved else { throw RemoteSettingsFailure.unavailable }
            return try Self(destination: destination, source: source, ledger: storage.ledger, record: saved, clock: clock)
        } catch {
            await source.drain(); if let saved { _ = try? await storage.ledger.endAfterDrain(saved.id, noRemoteMutation: true) }; throw error
        }
    }
    func validate(session: UUID, context: SFTPVerifiedSessionContext) throws {
        guard session == expectedSession, context.host == record.host.host, context.port == record.host.port,
              context.requestedScopeID == record.host.interfaceScope, Data(context.account.utf8) == Data(record.account.utf8),
              Data(SHA256.hash(data: context.key.bytes)) == record.hostKeyDigest,
              context.routeKeyBinding == expectedRouteBinding else { throw SFTPSessionFailure.security }
    }
    func takeForWorker() throws { try lock.withLock { guard ownership == .pending else { throw SFTPSessionFailure.input }; ownership = .worker } }
    private func requireWorker() throws { guard !Thread.isMainThread, lock.withLock({ ownership == .worker }) else { throw SFTPSessionFailure.input } }
    func requestCreationOnSessionExecutor() throws {
        try requireWorker(); try source.validateBeforeMutationOnSessionExecutor()
        _ = try ledger.requestPublicationOnSessionExecutor(record.id); try source.revalidateOnSessionExecutor()
        try ledger.requireFolderCreationRequestedOnSessionExecutor(record.id, manifestDigest: selection.manifest.digest)
    }
    func manifestOnSessionExecutor(offset: Int, count: Int) throws -> Data {
        try requireWorker(); let encoded = selection.manifest.encoded
        guard (1...32768).contains(count), count <= encoded.count, offset >= 0, offset <= encoded.count - count else { throw SFTPSessionFailure.input }
        return encoded.subdata(in: offset..<(offset + count))
    }
    func acknowledgeRootOnSessionExecutor() throws {
        try requireWorker(); guard !rootAcknowledged else { throw SFTPSessionFailure.output }
        try ledger.acknowledgeFolderRootOnSessionExecutor(record.id); rootAcknowledged = true; checkpointTime = clock()
    }
    func readOnSessionExecutor(node: Int, offset: UInt64, count: Int) throws -> Data {
        try requireWorker(); guard rootAcknowledged, pendingVerifiedNode == nil else { throw SFTPSessionFailure.output }
        return try source.readOnSessionExecutor(node: node, offset: offset, maximum: count)
    }
    func permitFileOnSessionExecutor(node: Int, digest: Data) throws {
        try requireWorker(); guard rootAcknowledged, pendingVerifiedNode == nil else { throw SFTPSessionFailure.output }
        try source.finishFileOnSessionExecutor(node: node, digest: digest); pendingVerifiedNode = node
    }
    func checkpointOnSessionExecutor(node: Int, files: Int, bytes: UInt64) throws {
        try requireWorker(); guard rootAcknowledged, pendingVerifiedNode == node, node < selection.manifest.nodes.count,
              files == verifiedFiles + 1, bytes == verifiedBytes + selection.manifest.nodes[node].size else { throw SFTPSessionFailure.output }
        pendingVerifiedNode = nil; verifiedFiles = files; verifiedBytes = bytes
        let now = clock()
        if files - checkpointFiles >= 16 || now - checkpointTime >= 0.25 || files == selection.manifest.files {
            try ledger.checkpointFolderOnSessionExecutor(record.id, files: files, bytes: bytes); checkpointFiles = files; checkpointTime = now
        }
    }
    func permitFinalOnSessionExecutor(digest: Data) throws {
        try requireWorker(); guard rootAcknowledged, pendingVerifiedNode == nil, verifiedFiles == selection.manifest.files,
              verifiedBytes == selection.manifest.logicalBytes else { throw SFTPSessionFailure.output }
        try ledger.requireFolderCreationRequestedOnSessionExecutor(record.id, manifestDigest: selection.manifest.digest)
        guard try source.finishOnSessionExecutor() == digest else { throw SFTPSessionFailure.sourceChanged }; permittedDigest = digest
    }
    func finishOnSessionExecutor(_ receipt: SFTPFolderUploadReceipt) throws -> SFTPCompletedFolderUpload {
        try requireWorker(); guard receipt.selection == selection, permittedDigest == receipt.digest,
              try source.finishOnSessionExecutor() == receipt.digest else { throw SFTPSessionFailure.sourceChanged }
        try ledger.verifyFolderOnSessionExecutor(record.id, digest: receipt.digest, files: verifiedFiles, bytes: verifiedBytes)
        try source.closeAfterDrainOnSessionExecutor(); _ = try ledger.endAfterDrainOnSessionExecutor(record.id)
        lock.withLock { ownership = .ended }; return .init(id: record.id, files: selection.manifest.files, folders: selection.manifest.folders, logicalBytes: selection.manifest.logicalBytes)
    }
    func requestStop() { source.requestStop() }
    func endAfterActualDrainOnSessionExecutor(noRemoteMutation: Bool) {
        guard lock.withLock({ ownership == .worker }) else { return }
        _ = try? source.closeAfterDrainOnSessionExecutor(); _ = try? ledger.endAfterDrainOnSessionExecutor(record.id, noRemoteMutation: noRemoteMutation)
        lock.withLock { ownership = .ended }
    }
    func discardUnsent() async {
        let release = lock.withLock { if ownership == .pending { ownership = .ended; return true }; return false }
        guard release else { return }; await source.drain(); _ = try? await ledger.endAfterDrain(record.id, noRemoteMutation: true)
    }
    deinit {
        if lock.withLock({ ownership == .pending }) {
            let source = source, ledger = ledger, id = record.id
            Task { await source.drain(); _ = try? await ledger.endAfterDrain(id, noRemoteMutation: true) }
        }
    }
}
