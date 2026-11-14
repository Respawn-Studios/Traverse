import CryptoKit
import Foundation

enum SMBUploadName {
    static func safe(_ name: SMBRemoteName) -> Bool {
        let bytes = Array(name.wireUTF16)
        guard !bytes.isEmpty, bytes.count <= 510, bytes.count % 2 == 0,
              let text = String(data: name.wireUTF16, encoding: .utf16LittleEndian),
              text != ".", text != "..", !text.hasSuffix(" "), !text.hasSuffix("."),
              !text.utf16.contains(where: { $0 < 32 || [47, 58, 92, 42, 63, 34, 60, 62, 124].contains(Int($0)) }),
              !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .format && [0x061C, 0x200E, 0x200F].contains(Int($0.value))
                      || (0x202A...0x202E).contains(Int($0.value)) || (0x2066...0x2069).contains(Int($0.value))
              }) else { return false }
        return Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }) == name.wireUTF16
    }
    static func wire(_ name: SMBRemoteName) -> String {
        let b = Array(name.wireUTF16)
        return stride(from: 0, to: b.count, by: 2).map { String(format: "%04x", UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8) }.joined()
    }
    static func path(_ components: [SMBRemoteName]) -> String {
        components.isEmpty ? "-" : components.map(wire).joined(separator: ",")
    }
}

@_spi(Qualification) public enum SMBUploadFailure: Error, Sendable, Equatable {
    case invalidInput, unavailable, busy, stopped, sourceChanged, storage, stageCollision, finalCollision, reviewRequired
}

@_spi(Qualification) public struct SMBRequestedUpload: Sendable, CustomDebugStringConvertible {
    enum Source: Sendable {
        case local(URL, PinnedLocalFileSource.Stamp)
        case generatedEmpty
    }
    public let request: UUID, connection: UUID, snapshot: SMBDirectorySnapshot
    public let directory: [SMBRemoteName], name: SMBRemoteName
    let source: Source
    public let logicalBytes: UInt64
    public var debugDescription: String { "<SMB explicit upload request>" }
    public static func isSupportedName(_ name: String) -> Bool {
        guard let remote = try? SMBRemoteName(name), SMBUploadName.safe(remote) else { return false }
        return !remote.displayName.lowercased().hasPrefix(".traverse-smb-upload-")
    }
    static func fitsWorkerPath(directory: [SMBRemoteName], name: SMBRemoteName, temporaryName: String) -> Bool {
        // Match the worker's parent and full-path limits before recording a
        // stage intent. A refused path must never look like a lost CREATE ACK.
        let parentUnits = directory.reduce(0) { $0 + $1.wireUTF16.count / 2 } + max(0, directory.count - 1)
        let separator = directory.isEmpty ? 0 : 1
        return parentUnits <= 1920
            && parentUnits + separator + name.wireUTF16.count / 2 <= 2048
            && parentUnits + separator + temporaryName.utf16.count <= 2048
    }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                reviewed source: SFTPUploadSourceReview, name: String) throws {
        guard Self.isSupportedName(name) else { throw SMBUploadFailure.invalidInput }
        let remote = try SMBRemoteName(name)
        let id = UUID()
        let temporaryName = ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part"
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000", snapshot.state == .complete,
              snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max), directory.count <= 128,
              directory.allSatisfy(SMBUploadName.safe), source.logicalBytes <= 1 << 30,
              remote.displayName.lowercased() != temporaryName,
              Self.fitsWorkerPath(directory: directory, name: remote, temporaryName: temporaryName) else {
            throw SMBUploadFailure.invalidInput
        }
        self.request = id; self.connection = connection; self.snapshot = snapshot; self.directory = directory
        self.name = remote; self.source = .local(source.url, source.observation); logicalBytes = source.logicalBytes
    }
    init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
         generatedEmptyName name: String) throws {
        guard Self.isSupportedName(name) else { throw SMBUploadFailure.invalidInput }
        let remote = try SMBRemoteName(name)
        let id = UUID()
        let temporaryName = ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part"
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000", snapshot.state == .complete,
              snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max), directory.count <= 128,
              directory.allSatisfy(SMBUploadName.safe),
              remote.displayName.lowercased() != temporaryName,
              Self.fitsWorkerPath(directory: directory, name: remote, temporaryName: temporaryName) else {
            throw SMBUploadFailure.invalidInput
        }
        self.request = id; self.connection = connection; self.snapshot = snapshot; self.directory = directory
        self.name = remote; self.source = .generatedEmpty; logicalBytes = 0
    }
    func command(ordinal: UInt64, number: UInt64) -> String {
        "PREPARE_UPLOAD \(request.uuidString) \(ordinal) \(number) \(snapshot.readID.uuidString) \(snapshot.revision) \(SMBUploadName.path(directory)) \(SMBUploadName.wire(name)) \(logicalBytes)\n"
    }
}

@_spi(Qualification) public struct SMBUploadRecordSummary: Sendable, CustomDebugStringConvertible {
    public let id: UUID, server: SMBConnectionAddress, account: String
    public let directory: [SMBRemoteName], remoteName: SMBRemoteName, sourceName: String
    public let logicalBytes: UInt64, outcome: SMBUploadOutcome, active: Bool
    public let folder: SMBFolderUploadRecordSummary?
    public var temporaryName: String { ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part" }
    public var debugDescription: String { "<SMB upload summary>" }
}
@_spi(Qualification) public struct SMBFolderUploadRecordSummary: Sendable, CustomDebugStringConvertible {
    public let files: Int, folders: Int, verifiedFiles: Int, verifiedBytes: UInt64, rootAcknowledged: Bool
    public var debugDescription: String { "<SMB folder upload summary>" }
}
@_spi(Qualification) public struct SMBUploadHistorySnapshot: Sendable { public let revision: UInt64, records: [SMBUploadRecordSummary] }
@_spi(Qualification) public struct SMBCompletedUpload: Sendable, CustomDebugStringConvertible {
    public let id: UUID, logicalBytes: UInt64
    public var debugDescription: String { "<SMB completed upload>" }
}

@_spi(Qualification) public final class SMBUploadStorage: Sendable {
    let ledger: SMBUploadLedger
    public init(directory: URL) { ledger = SMBUploadLedger(directory: directory) }
    init(directory: URL, probe: @escaping @Sendable (SMBUploadLedger.Stage) throws -> Void) { ledger = SMBUploadLedger(directory: directory, probe: probe) }
    public func inspect() async throws -> SMBUploadHistorySnapshot {
        let value = try await ledger.inspect()
        return .init(revision: value.revision, records: value.records.map {
            .init(id: $0.id, server: $0.server, account: $0.account, directory: $0.directory,
                  remoteName: $0.remoteName, sourceName: $0.sourceName, logicalBytes: $0.logicalBytes,
                  outcome: value.active.contains($0.id) ? $0.outcome : $0.coldOutcome, active: value.active.contains($0.id),
                  folder: $0.folder.map {
                      .init(files: $0.files, folders: $0.folders, verifiedFiles: $0.verifiedFiles,
                            verifiedBytes: $0.verifiedBytes, rootAcknowledged: $0.rootAcknowledged)
                  })
        })
    }
    public func forget(_ id: UUID, revision: UInt64) async throws { try await ledger.forget(id, revision: revision) }
    public func recoverUncommittedLocalStage() async throws { try await ledger.recoverUncommittedStage() }
    public func close() async -> Bool { await ledger.close() }
}

/// One checked local source or sealed empty value, plus one durable metadata
/// claim. Only the serial browser executor advances publication barriers.
final class SMBUploadAttempt: @unchecked Sendable {
    private enum Source {
        case local(SFTPUploadSource), generatedEmpty
        func read(offset: UInt64, count: Int) throws -> Data {
            switch self {
            case .local(let value): return try value.readOnSessionExecutor(offset: offset, maximum: count)
            case .generatedEmpty: throw SMBUploadFailure.invalidInput
            }
        }
        func finish(cancelled: Bool) throws -> Data {
            switch self {
            case .local(let value): return try value.finishOnSessionExecutor()
            case .generatedEmpty:
                guard !cancelled else { throw SMBUploadFailure.stopped }
                return Data(SHA256.hash(data: Data()))
            }
        }
        func closeAfterDrain() throws {
            if case .local(let value) = self { try value.closeAfterDrainOnSessionExecutor() }
        }
        func stop() { if case .local(let value) = self { value.requestStop() } }
        func drain() async { if case .local(let value) = self { await value.drain() } }
    }
    let request: SMBRequestedUpload, record: SMBUploadRecord
    private let source: Source
    let ledger: SMBUploadLedger
    let progress: (@Sendable (UInt64) -> Void)?
    private let lock = NSLock()
    private var ended = false, cancelled = false, admittedValue = false, stageRequested = false, stageConfirmed = false, publicationRequested = false
    private init(request: SMBRequestedUpload, record: SMBUploadRecord, source: Source,
                 ledger: SMBUploadLedger, progress: (@Sendable (UInt64) -> Void)?) {
        self.request = request; self.record = record; self.source = source; self.ledger = ledger; self.progress = progress
    }
    static func prepare(_ request: SMBRequestedUpload, server: SMBServerDraft, storage: SMBUploadStorage,
                        excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> Self {
        let source: Source
        switch request.source {
        case .local(let url, _):
            do { source = .local(try await SFTPUploadSource.prepare(url, excluding: roots)) }
            catch let error as SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(error) }
        case .generatedEmpty: source = .generatedEmpty
        }
        var saved = false
        do {
            let sourceName: String
            switch (source, request.source) {
            case (.local(let value), .local(_, let expected)):
                guard value.snapshot.observation == expected,
                      value.snapshot.logicalBytes == request.logicalBytes else { throw SMBUploadFailure.sourceChanged }
                sourceName = value.snapshot.name
            case (.generatedEmpty, .generatedEmpty):
                guard request.logicalBytes == 0 else { throw SMBUploadFailure.invalidInput }
                sourceName = request.name.displayName
            default: throw SMBUploadFailure.invalidInput
            }
            let record = SMBUploadRecord(id: request.request, server: server.address, account: server.account,
                directory: request.directory, remoteName: request.name, sourceName: sourceName,
                logicalBytes: request.logicalBytes, outcome: .prepared, digest: nil)
            try await storage.ledger.prepare(record); saved = true
            try Task.checkCancellation()
            return .init(request: request, record: record, source: source, ledger: storage.ledger, progress: progress)
        } catch {
            await source.drain()
            if saved { _ = try? await storage.ledger.endAfterDrain(request.request, noRemoteMutation: true) }
            throw error
        }
    }
    func requestStageOnExecutor() throws {
        guard !isCancelled else { throw SMBUploadFailure.stopped }
        try ledger.requestStage(record.id); lock.withLock { stageRequested = true }
    }
    func admit() -> Bool { lock.withLock { guard !ended, !cancelled, !admittedValue else { return false }; admittedValue = true; return true } }
    var admitted: Bool { lock.withLock { admittedValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func confirmStageOnExecutor() throws {
        if lock.withLock({ stageConfirmed }) { return }
        try ledger.confirmStage(record.id); lock.withLock { stageConfirmed = true }
    }
    func readOnExecutor(offset: UInt64, count: Int) throws -> Data {
        try source.read(offset: offset, count: count)
    }
    func digestOnExecutor() throws -> Data {
        try source.finish(cancelled: isCancelled)
    }
    func requestPublicationOnExecutor(_ digest: Data) throws {
        guard try digestOnExecutor() == digest else { throw SMBUploadFailure.sourceChanged }
        try ledger.requestPublication(record.id); lock.withLock { publicationRequested = true }
    }
    func completeOnExecutor(_ digest: Data) throws -> SMBCompletedUpload {
        guard try digestOnExecutor() == digest else { throw SMBUploadFailure.sourceChanged }
        try ledger.verify(record.id, digest: digest)
        try source.closeAfterDrain(); lock.withLock { ended = true }
        return .init(id: record.id, logicalBytes: record.logicalBytes)
    }
    func collisionOnExecutor(stage: Bool) throws {
        if stage { try ledger.stageCollision(record.id) } else { try ledger.finalCollision(record.id) }
        try source.closeAfterDrain(); lock.withLock { ended = true }
    }
    func stop() { lock.withLock { cancelled = true }; source.stop() }
    var finished: Bool { lock.withLock { ended } }
    func finishAfterDrain(noRemoteMutation: Bool) async throws {
        if lock.withLock({ ended }) { return }
        await source.drain(); try await ledger.endAfterDrain(record.id, noRemoteMutation: noRemoteMutation)
        lock.withLock { ended = true }
    }
    var remoteMayHaveStarted: Bool { lock.withLock { stageRequested } }
    var publicationMayHaveStarted: Bool { lock.withLock { publicationRequested } }
}
