import CryptoKit
import Foundation

/// One reviewed local folder or sealed empty root and one exact SMB catalog
/// destination. A selected local URL is reopened before root-creation intent.
@_spi(Qualification) public struct SMBRequestedFolderUpload: Sendable, CustomDebugStringConvertible {
    enum Source: Sendable { case local(SMBFolderUploadPlan), generatedEmpty }
    public let request: UUID, connection: UUID, snapshot: SMBDirectorySnapshot
    public let directory: [SMBRemoteName], name: SMBRemoteName
    let source: Source, manifest: SFTPFolderUploadManifest
    public let files: Int, folders: Int, logicalBytes: UInt64
    public var debugDescription: String { "<SMB explicit folder upload request>" }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                reviewed: SMBFolderUploadPlan, name: String) throws {
        let id = UUID()
        let temporaryName = ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part"
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              reviewed.manifest.encoded.count <= 512 << 10 else { throw SMBUploadFailure.invalidInput }
        try reviewed.validateDestination(directory: directory, name: name, temporaryName: temporaryName)
        self.request = id; self.connection = connection; self.snapshot = snapshot; self.directory = directory
        self.name = try SMBRemoteName(name); self.source = .local(reviewed); manifest = reviewed.manifest
        files = reviewed.files; folders = reviewed.folders + 1; logicalBytes = reviewed.logicalBytes
    }
    init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
         generatedEmptyName name: String) throws {
        let id = UUID()
        let temporaryName = ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part"
        let manifest = try SFTPFolderUploadManifest(nodes: [.init(kind: .directory, components: [], size: 0)])
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              directory.count <= 128, directory.allSatisfy(SMBUploadName.safe),
              manifest.encoded.count <= 512 << 10, SMBRequestedUpload.isSupportedName(name),
              let remote = try? SMBRemoteName(name),
              SMBRequestedUpload.fitsWorkerPath(directory: directory, name: remote, temporaryName: temporaryName),
              remote.displayName.lowercased() != temporaryName else { throw SMBUploadFailure.invalidInput }
        self.request = id; self.connection = connection; self.snapshot = snapshot; self.directory = directory
        self.name = remote; self.source = .generatedEmpty; self.manifest = manifest
        files = 0; folders = 1; logicalBytes = 0
    }
    func command(ordinal: UInt64, number: UInt64) -> String {
        let hex = manifest.digest.map { String(format: "%02x", $0) }.joined()
        return "PREPARE_FOLDER_UPLOAD \(request.uuidString) \(ordinal) \(number) \(snapshot.readID.uuidString) \(snapshot.revision) \(SMBUploadName.path(directory)) \(SMBUploadName.wire(name)) \(files) \(folders - 1) \(logicalBytes) \(manifest.encoded.count) \(hex)\n"
    }
}

@_spi(Qualification) public struct SMBCompletedFolderUpload: Sendable, CustomDebugStringConvertible {
    public let id: UUID, files: Int, folders: Int, logicalBytes: UInt64
    public var debugDescription: String { "<SMB completed folder upload>" }
}

/// The serial browser executor alone reads bodies and advances durable
/// barriers. An interrupted attempt is retired only after actual drain.
final class SMBFolderUploadAttempt: @unchecked Sendable {
    private enum Source {
        case local(SFTPFolderUploadSource), generatedEmpty
        func validateBeforeMutation() throws {
            if case .local(let value) = self { try value.validateBeforeMutationOnSessionExecutor() }
        }
        func revalidate() throws {
            if case .local(let value) = self { try value.revalidateOnSessionExecutor() }
        }
        func read(node: Int, offset: UInt64, count: Int) throws -> Data {
            switch self {
            case .local(let value): return try value.readOnSessionExecutor(node: node, offset: offset, maximum: count)
            case .generatedEmpty: throw SMBUploadFailure.invalidInput
            }
        }
        func finishFile(node: Int, digest: Data) throws {
            switch self {
            case .local(let value): try value.finishFileOnSessionExecutor(node: node, digest: digest)
            case .generatedEmpty: throw SMBUploadFailure.invalidInput
            }
        }
        func finish(manifest: SFTPFolderUploadManifest, cancelled: Bool) throws -> Data {
            switch self {
            case .local(let value): return try value.finishOnSessionExecutor()
            case .generatedEmpty:
                guard !cancelled else { throw SMBUploadFailure.stopped }
                return Data(SHA256.hash(data: manifest.encoded))
            }
        }
        func closeAfterDrain() throws {
            if case .local(let value) = self { try value.closeAfterDrainOnSessionExecutor() }
        }
        func stop() { if case .local(let value) = self { value.requestStop() } }
        func drain() async { if case .local(let value) = self { await value.drain() } }
    }
    let request: SMBRequestedFolderUpload, record: SMBUploadRecord
    private let source: Source
    let ledger: SMBUploadLedger
    let progress: (@Sendable (UInt64) -> Void)?
    private let lock = NSLock()
    private var ended = false, cancelled = false, admittedValue = false, stageRequested = false
    private var publicationRequested = false, rootAcknowledged = false
    private var verifiedFiles = 0, verifiedBytes: UInt64 = 0, pendingNode: Int?
    private var hash = SHA256()
    private init(request: SMBRequestedFolderUpload, record: SMBUploadRecord,
                 source: Source, ledger: SMBUploadLedger,
                 progress: (@Sendable (UInt64) -> Void)?) {
        self.request = request; self.record = record; self.source = source; self.ledger = ledger; self.progress = progress
    }
    static func prepare(_ request: SMBRequestedFolderUpload, server: SMBServerDraft, storage: SMBUploadStorage,
                        excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> Self {
        let source: Source
        switch request.source {
        case .local(let reviewed):
            do { source = .local(try await SFTPFolderUploadSource.prepare(reviewed.url, excluding: roots)) }
            catch let error as SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(error) }
        case .generatedEmpty: source = .generatedEmpty
        }
        var saved = false
        do {
            let sourceName: String
            switch (source, request.source) {
            case (.local(let value), .local(let reviewed)):
                let old = reviewed.snapshot, now = value.snapshot
                guard now.inventoryDigest == old.inventoryDigest, now.manifestDigest == old.manifestDigest,
                      Data(now.name.utf8) == Data(old.name.utf8), value.manifest == request.manifest,
                      now.files == request.files, now.folders + 1 == request.folders,
                      now.logicalBytes == request.logicalBytes else { throw SMBUploadFailure.sourceChanged }
                sourceName = now.name
            case (.generatedEmpty, .generatedEmpty):
                guard request.files == 0, request.folders == 1, request.logicalBytes == 0,
                      request.manifest.nodes.count == 1,
                      request.manifest.nodes[0].directory,
                      request.manifest.nodes[0].components.isEmpty else { throw SMBUploadFailure.invalidInput }
                sourceName = request.name.displayName
            default: throw SMBUploadFailure.invalidInput
            }
            let folder = SMBFolderUploadRecord(manifestDigest: request.manifest.digest,
                                               files: request.files, folders: request.folders)
            let record = SMBUploadRecord(id: request.request, server: server.address, account: server.account,
                directory: request.directory, remoteName: request.name, sourceName: sourceName,
                logicalBytes: request.logicalBytes, outcome: .prepared, digest: nil, folder: folder)
            try await storage.ledger.prepare(record); saved = true
            try Task.checkCancellation()
            return .init(request: request, record: record, source: source, ledger: storage.ledger, progress: progress)
        } catch {
            await source.drain()
            if saved { _ = try? await storage.ledger.endAfterDrain(request.request, noRemoteMutation: true) }
            throw error
        }
    }
    func admit() -> Bool { lock.withLock { guard !ended, !cancelled, !admittedValue else { return false }; admittedValue = true; return true } }
    var admitted: Bool { lock.withLock { admittedValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var remoteMayHaveStarted: Bool { lock.withLock { stageRequested } }
    var finished: Bool { lock.withLock { ended } }
    func manifestOnExecutor(offset: Int, count: Int) throws -> Data {
        let encoded = request.manifest.encoded
        guard !isCancelled, (1...32768).contains(count), offset >= 0,
              offset <= encoded.count - count else { throw SMBUploadFailure.invalidInput }
        return encoded.subdata(in: offset..<(offset + count))
    }
    func requestStageOnExecutor() throws {
        guard !isCancelled else { throw SMBUploadFailure.stopped }
        try source.validateBeforeMutation()
        try ledger.requestStage(record.id)
        lock.withLock { stageRequested = true }
        try source.revalidate()
    }
    func acknowledgeRootOnExecutor() throws {
        guard !isCancelled, !rootAcknowledged else { throw SMBUploadFailure.stopped }
        try ledger.confirmFolderRoot(record.id); rootAcknowledged = true
    }
    func readOnExecutor(node: Int, offset: UInt64, count: Int) throws -> Data {
        guard rootAcknowledged, pendingNode == nil, !isCancelled else { throw SMBUploadFailure.stopped }
        let bytes = try source.read(node: node, offset: offset, count: count)
        guard bytes.count == count else { throw SMBUploadFailure.sourceChanged }
        hash.update(data: bytes); return bytes
    }
    func fileDigestOnExecutor(node: Int) throws -> Data {
        guard rootAcknowledged, pendingNode == nil, !isCancelled else { throw SMBUploadFailure.stopped }
        let digest = Data(hash.finalize())
        try source.finishFile(node: node, digest: digest)
        pendingNode = node; hash = SHA256(); return digest
    }
    func checkpointOnExecutor(node: Int, files: Int, bytes: UInt64) throws {
        guard rootAcknowledged, pendingNode == node, !isCancelled,
              files == verifiedFiles + 1, node < request.manifest.nodes.count,
              bytes == verifiedBytes + request.manifest.nodes[node].size else { throw SMBUploadFailure.invalidInput }
        try ledger.checkpointFolder(record.id, files: files, bytes: bytes)
        verifiedFiles = files; verifiedBytes = bytes; pendingNode = nil
        progress?(bytes)
    }
    func requestPublicationOnExecutor(_ digest: Data) throws {
        guard rootAcknowledged, pendingNode == nil, verifiedFiles == request.files,
              verifiedBytes == request.logicalBytes,
              try source.finish(manifest: request.manifest, cancelled: isCancelled) == digest else { throw SMBUploadFailure.sourceChanged }
        try ledger.requestPublication(record.id); publicationRequested = true
    }
    func completeOnExecutor(_ digest: Data) throws -> SMBCompletedFolderUpload {
        guard publicationRequested,
              try source.finish(manifest: request.manifest, cancelled: isCancelled) == digest else { throw SMBUploadFailure.sourceChanged }
        try ledger.verify(record.id, digest: digest)
        try source.closeAfterDrain(); lock.withLock { ended = true }
        return .init(id: record.id, files: request.files, folders: request.folders, logicalBytes: request.logicalBytes)
    }
    func collisionOnExecutor(stage: Bool) throws {
        if stage { try ledger.stageCollision(record.id) } else { try ledger.finalCollision(record.id) }
        try source.closeAfterDrain(); lock.withLock { ended = true }
    }
    func stop() { lock.withLock { cancelled = true }; source.stop() }
    func finishAfterDrain(noRemoteMutation: Bool) async throws {
        if lock.withLock({ ended }) { return }
        await source.drain(); try await ledger.endAfterDrain(record.id, noRemoteMutation: noRemoteMutation)
        lock.withLock { ended = true }
    }
}
