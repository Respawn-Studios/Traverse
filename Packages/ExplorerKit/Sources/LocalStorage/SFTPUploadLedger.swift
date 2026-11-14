import CoreFoundation
import CryptoKit
import Foundation

@_spi(Qualification) public enum SFTPUploadOutcome: String, Sendable, Codable {
    case prepared, publicationRequested, verified, reviewTemporary, reviewPublication, notStarted
}
@_spi(Qualification) public enum SFTPUploadPublication: String, Sendable, Codable {
    case legacyStagedRename, exclusiveFinal, exclusiveFreshFolder
}
struct SFTPUploadRecord: Sendable, Equatable, Codable, CustomDebugStringConvertible {
    let id: UUID, host: SFTPHostIdentity, account: String, hostKeyDigest: Data
    let remoteDirectory: String, remoteName: String, source: SFTPUploadRecordedSource
    var outcome: SFTPUploadOutcome, digest: Data?
    // nil is the exact v1 encoding, never silently reinterpreted as a G upload.
    var publication: SFTPUploadPublication? = nil
    var folderProgress: SFTPFolderUploadProgress? = nil
    var publicationKind: SFTPUploadPublication { publication ?? .legacyStagedRename }
    var debugDescription: String { "<SFTP upload record>" }
    var temporaryName: String { ".mac-explorer-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "") + ".part" }
    var temporaryPath: String { (remoteDirectory == "/" ? "" : remoteDirectory) + "/" + temporaryName }
    var finalPath: String { (remoteDirectory == "/" ? "" : remoteDirectory) + "/" + remoteName }
    func validate() throws {
        try host.validate(); try source.validate()
        guard id.uuidString != "00000000-0000-0000-0000-000000000000", hostKeyDigest.count == 32,
              !account.isEmpty, account.utf8.count <= 256, !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              remoteDirectory.hasPrefix("/"), remoteDirectory.utf8.count <= 8192, !remoteDirectory.utf8.contains(0),
              remoteDirectory == "/" || !remoteDirectory.hasSuffix("/") && remoteDirectory.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              remoteDirectory.split(separator: "/").count <= 127,
              !remoteName.isEmpty, remoteName.utf8.count <= 255, remoteName != ".", remoteName != "..", !remoteName.contains("/"), !remoteName.utf8.contains(0),
              finalPath.utf8.count <= 8192, temporaryPath.utf8.count <= 8192, Data(remoteName.utf8) != Data(temporaryName.utf8),
              outcome == .verified ? digest?.count == 32 : digest == nil else { throw RemoteSettingsFailure.invalidRecord }
        if case .folder(let source) = source {
            guard publication == .exclusiveFreshFolder, let progress = folderProgress,
                  (0...source.files).contains(progress.verifiedFiles), progress.verifiedBytes <= source.logicalBytes,
                  progress.rootAcknowledged || progress.verifiedFiles == 0 && progress.verifiedBytes == 0,
                  outcome != .reviewTemporary,
                  outcome != .prepared && outcome != .notStarted || progress == .init(),
                  outcome != .verified || progress.rootAcknowledged && progress.verifiedFiles == source.files && progress.verifiedBytes == source.logicalBytes else { throw RemoteSettingsFailure.invalidRecord }
        } else { guard publication != .exclusiveFreshFolder, folderProgress == nil else { throw RemoteSettingsFailure.invalidRecord } }
    }
}
struct SFTPUploadLedgerSnapshot: Sendable {
    let revision: UInt64, records: [SFTPUploadRecord], active: Set<UUID>
}
struct SFTPUploadLedgerMutation: Sendable {
    let revision: UInt64, record: SFTPUploadRecord?, completedAfterCancellation: Bool
}

private struct SFTPUploadLedgerDocument: Sendable, Codable, RemoteSettingsDocument {
    var format = 2, protocolIdentity = "sftp-upload-history"
    var revision: UInt64 = 0
    var records: [SFTPUploadRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard (1...3).contains(format), protocolIdentity == "sftp-upload-history", records.count <= 64,
              records.allSatisfy({ format == 1 ? $0.publication == nil : $0.publication != nil }),
              format == 3 || records.allSatisfy({ !$0.source.isFolder }),
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw RemoteSettingsFailure.invalidRecord }
            guard (1...3).contains(number.intValue),
                  object?["protocolIdentity"] as? String == "sftp-upload-history" else { throw RemoteSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }; return value
        } catch let failure as RemoteSettingsFailure { throw failure }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}

/// Private local outcomes, never authority to retry/delete a remote path.
/// The existing descriptor-anchored FULLFSYNC file primitive is reused in its
/// own namespace. Saved servers and the file-operation journal do not change.
final class SFTPUploadLedger: @unchecked Sendable {
    typealias Stage = RemoteSettingsFile<SFTPSettingsSnapshot>.Stage
    private typealias File = RemoteSettingsFile<SFTPUploadLedgerDocument>
    private let directory: URL
    private let executor = UploadLocalExecutor(label: "MacExplorer.SFTP.Upload.History")
    private let probe: (@Sendable (Stage) throws -> Void)?
    private var owner: File?, active = Set<UUID>()
    init(directory: URL, probe: (@Sendable (Stage) throws -> Void)? = nil) { self.directory = directory; self.probe = probe }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }
    func inspect() async throws -> SFTPUploadLedgerSnapshot {
        let (value, late) = try await executor.perform { [self] in
            if let owner { try owner.validateCurrent(); return SFTPUploadLedgerSnapshot(revision: owner.snapshot.revision, records: owner.snapshot.records, active: active) }
            guard let file = try File.open(directory, writing: false) else { return .init(revision: 0, records: [], active: []) }
            defer { file.close() }; return .init(revision: file.snapshot.revision, records: file.snapshot.records, active: [])
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }; return value
    }
    func prepare(host: SFTPHostIdentity, account: String, key: SFTPHostKey, directory: String,
                 name: String, source: SFTPUploadSourceSnapshot, revision: UInt64) async throws -> SFTPUploadLedgerMutation {
        let record = SFTPUploadRecord(id: UUID(), host: host, account: account, hostKeyDigest: Data(SHA256.hash(data: key.bytes)),
            remoteDirectory: directory, remoteName: name, source: .file(source), outcome: .prepared, digest: nil, publication: .exclusiveFinal)
        try record.validate()
        return try await mutate(revision: revision) { [self] document in
            guard document.records.count < 64, active.count < 2 else { throw RemoteSettingsFailure.capacity }
            if document.format == 1 {
                // Only explicit preparation upgrades; passive inspection does
                // not rewrite old canonical bytes or take writer authority.
                document.format = 2
                for index in document.records.indices { document.records[index].publication = .legacyStagedRename }
            }
            document.records.append(record); return record
        } afterCommit: { [self] in active.insert(record.id) }
    }
    func prepareFolder(host: SFTPHostIdentity, account: String, key: SFTPHostKey, directory: String,
                       name: String, source: SFTPFolderUploadSourceSnapshot, revision: UInt64) async throws -> SFTPUploadLedgerMutation {
        let record = SFTPUploadRecord(id: UUID(), host: host, account: account, hostKeyDigest: Data(SHA256.hash(data: key.bytes)),
            remoteDirectory: directory, remoteName: name, source: .folder(source), outcome: .prepared, digest: nil,
            publication: .exclusiveFreshFolder, folderProgress: .init())
        try record.validate()
        return try await mutate(revision: revision) { [self] document in
            guard document.records.count < 64, active.count < 2 else { throw RemoteSettingsFailure.capacity }
            if document.format == 1 { for index in document.records.indices { document.records[index].publication = .legacyStagedRename } }
            document.format = 3; document.records.append(record); return record
        } afterCommit: { [self] in active.insert(record.id) }
    }
    func requireFolderCreationRequestedOnSessionExecutor(_ id: UUID, manifestDigest: Data) throws {
        try executor.synchronously { [self] in
            guard active.contains(id), let owner else { throw RemoteSettingsFailure.busy }; try owner.validateCurrent()
            guard let record = owner.snapshot.records.first(where: { $0.id == id }),
                  case .folder(let source) = record.source, source.manifestDigest == manifestDigest,
                  record.publicationKind == .exclusiveFreshFolder, record.outcome == .publicationRequested else { throw RemoteSettingsFailure.invalidRecord }
        }
    }
    func acknowledgeFolderRootOnSessionExecutor(_ id: UUID) throws {
        _ = try executor.synchronously { [self] in try updateOnExecutor(id) { record in
            guard record.publicationKind == .exclusiveFreshFolder, record.outcome == .publicationRequested,
                  record.folderProgress == .init() else { throw RemoteSettingsFailure.invalidRecord }
            record.folderProgress = .init(rootAcknowledged: true)
        } }
    }
    func checkpointFolderOnSessionExecutor(_ id: UUID, files: Int, bytes: UInt64) throws {
        _ = try executor.synchronously { [self] in try updateOnExecutor(id) { record in
            guard case .folder(let source) = record.source, record.outcome == .publicationRequested,
                  let old = record.folderProgress, old.rootAcknowledged,
                  files > old.verifiedFiles, files <= source.files, bytes >= old.verifiedBytes, bytes <= source.logicalBytes else { throw RemoteSettingsFailure.invalidRecord }
            record.folderProgress = .init(rootAcknowledged: true, verifiedFiles: files, verifiedBytes: bytes)
        } }
    }
    func verifyFolderOnSessionExecutor(_ id: UUID, digest: Data, files: Int, bytes: UInt64) throws {
        _ = try executor.synchronously { [self] in try updateOnExecutor(id) { record in
            guard case .folder(let source) = record.source, record.outcome == .publicationRequested,
                  record.folderProgress?.rootAcknowledged == true, files == source.files,
                  bytes == source.logicalBytes, digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
            record.folderProgress = .init(rootAcknowledged: true, verifiedFiles: files, verifiedBytes: bytes)
            record.outcome = .verified; record.digest = digest
        } }
    }
    /// Must finish successfully before the owner sends any G Upload command.
    func requestPublication(_ id: UUID) async throws -> SFTPUploadLedgerMutation {
        try await update(id) { record in
            guard record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }; record.outcome = .publicationRequested
        }
    }
    func requestPublicationOnSessionExecutor(_ id: UUID) throws -> SFTPUploadLedgerMutation {
        let value = try executor.synchronously { [self] in try updateOnExecutor(id) { record in
            guard record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }; record.outcome = .publicationRequested
        } }
        return .init(revision: value.0, record: value.1, completedAfterCancellation: false)
    }
    /// The late complete-source authorization must observe the earlier durable
    /// creation barrier. It must never create that barrier after remote OPEN.
    func requireCreationRequestedOnSessionExecutor(_ id: UUID) throws {
        try executor.synchronously { [self] in
            guard active.contains(id), let owner else { throw RemoteSettingsFailure.busy }
            try owner.validateCurrent()
            guard let record = owner.snapshot.records.first(where: { $0.id == id }),
                  record.publicationKind == .exclusiveFinal, !record.source.isFolder, record.outcome == .publicationRequested else { throw RemoteSettingsFailure.invalidRecord }
        }
    }
    /// Only the transaction owner may use its checked source/worker receipt.
    /// A recorded result is not an inode/CAS or remote power-loss guarantee.
    func verify(_ id: UUID, digest: Data) async throws -> SFTPUploadLedgerMutation {
        try await update(id) { record in
            guard record.outcome == .publicationRequested, !record.source.isFolder, digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
            record.outcome = .verified; record.digest = digest
        }
    }
    func verifyOnSessionExecutor(_ id: UUID, digest: Data) throws -> SFTPUploadLedgerMutation {
        let value = try executor.synchronously { [self] in try updateOnExecutor(id) { record in
            guard record.outcome == .publicationRequested, !record.source.isFolder, digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
            record.outcome = .verified; record.digest = digest
        } }
        return .init(revision: value.0, record: value.1, completedAfterCancellation: false)
    }
    /// Invoke only after every actual worker/source user has drained. A failed
    /// save keeps its durable conservative prefix and releases no remote data.
    func endAfterDrain(_ id: UUID, noRemoteMutation: Bool = false) async throws -> SFTPUploadLedgerMutation {
        let request = UploadCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in executor.enqueueDrain { [self] in
                let result = Result { () throws -> SFTPUploadLedgerMutation in
                    let (next, record) = try endOnExecutor(id, noRemoteMutation: noRemoteMutation)
                    return .init(revision: next, record: record, completedAfterCancellation: request.cancelled)
                }
                continuation.resume(with: result)
            } }
        } onCancel: { request.cancel() }
    }
    func endAfterDrainOnSessionExecutor(_ id: UUID, noRemoteMutation: Bool = false) throws -> SFTPUploadLedgerMutation {
        let value = try executor.synchronously(cleanup: true) { [self] in try endOnExecutor(id, noRemoteMutation: noRemoteMutation) }
        return .init(revision: value.0, record: value.1, completedAfterCancellation: false)
    }
    private func endOnExecutor(_ id: UUID, noRemoteMutation: Bool) throws -> (UInt64, SFTPUploadRecord?) {
        defer { active.remove(id) }
        return try updateOnExecutor(id) { record in
            switch record.outcome {
            case .prepared: record.outcome = noRemoteMutation ? .notStarted : record.publicationKind != .legacyStagedRename ? .reviewPublication : .reviewTemporary
            case .publicationRequested:
                guard !noRemoteMutation || record.publicationKind != .legacyStagedRename else { throw RemoteSettingsFailure.invalidRecord }
                record.outcome = noRemoteMutation ? .notStarted : .reviewPublication
            case .verified: guard !noRemoteMutation else { throw RemoteSettingsFailure.invalidRecord }
            default: throw RemoteSettingsFailure.invalidRecord
            }
        }
    }
    /// Explicit local record removal. No remote operation is performed.
    func forget(_ id: UUID, revision: UInt64) async throws -> SFTPUploadLedgerMutation {
        try await mutate(revision: revision) { [self] document in
            guard !active.contains(id) else { throw RemoteSettingsFailure.busy }
            guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            document.records.remove(at: index); return nil
        }
    }
    private func update(_ id: UUID,
                        change: @escaping @Sendable (inout SFTPUploadRecord) throws -> Void) async throws -> SFTPUploadLedgerMutation {
        let (value, late) = try await executor.perform { [self] in try updateOnExecutor(id, change: change) }
        return .init(revision: value.0, record: value.1, completedAfterCancellation: late)
    }
    private func updateOnExecutor(_ id: UUID, change: (inout SFTPUploadRecord) throws -> Void) throws -> (UInt64, SFTPUploadRecord?) {
        try changeOnExecutor(revision: nil) { [self] document in
            guard active.contains(id) else { throw RemoteSettingsFailure.busy }
            guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            try change(&document.records[index]); return document.records[index]
        }
    }
    private func mutate(revision: UInt64?, change: @escaping @Sendable (inout SFTPUploadLedgerDocument) throws -> SFTPUploadRecord?,
                        afterCommit: @escaping @Sendable () -> Void = {}) async throws -> SFTPUploadLedgerMutation {
        let (result, late) = try await executor.perform { [self] in
            let result = try changeOnExecutor(revision: revision, change: change); afterCommit(); return result
        }
        return .init(revision: result.0, record: result.1, completedAfterCancellation: late)
    }
    private func changeOnExecutor(revision: UInt64?, change: (inout SFTPUploadLedgerDocument) throws -> SFTPUploadRecord?) throws -> (UInt64, SFTPUploadRecord?) {
        if owner == nil {
            let callback: File.Probe?
            if let observer = probe {
                callback = { stage in
                    guard let mapped = Stage(rawValue: stage.rawValue) else { throw RemoteSettingsFailure.invalidRecord }; try observer(mapped)
                }
            } else { callback = nil }
            owner = try File.open(directory, writing: true, probe: callback)
        }
        guard let owner else { throw RemoteSettingsFailure.unavailable }; try owner.validateCurrent()
        if let revision { guard owner.snapshot.revision == revision else { throw RemoteSettingsFailure.staleRevision } }
        var next = owner.snapshot; let record = try change(&next)
        guard next.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }; next.revision += 1
        try owner.commit(next); return (next.revision, record)
    }
    /// Explicit recovery may discard only the uncommitted local stage. An
    /// existing durable prefix stays conservative; no network effect follows.
    func recoverUncommittedStage() async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.isEmpty else { throw RemoteSettingsFailure.busy }; owner?.close(); owner = nil
            owner = try File.open(directory, writing: true, discardStage: true)
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func close() async -> Bool {
        await withCheckedContinuation { continuation in executor.enqueueDrain { [self] in
            guard active.isEmpty else { continuation.resume(returning: false); return }
            owner?.close(); owner = nil; continuation.resume(returning: true)
        } }
    }
}
