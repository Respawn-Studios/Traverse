import CoreFoundation
import CryptoKit
import Foundation

@_spi(Qualification) public enum SMBUploadOutcome: String, Codable, Sendable {
    case prepared, stageRequested, stageConfirmed, publicationRequested, verified
    case notStarted, stageCollision, finalCollision, stageMayExist, reviewTemporary, reviewPublication
}

struct SMBFolderUploadRecord: Codable, Sendable, Equatable {
    let manifestDigest: Data
    let files: Int, folders: Int
    var rootAcknowledged = false
    var verifiedFiles = 0
    var verifiedBytes: UInt64 = 0
    func validate(logicalBytes: UInt64, outcome: SMBUploadOutcome) throws {
        let expectedRootAcknowledgement: Bool
        switch outcome {
        case .prepared, .stageRequested, .stageCollision, .stageMayExist, .notStarted:
            expectedRootAcknowledgement = false
        case .stageConfirmed, .publicationRequested, .verified, .reviewTemporary, .reviewPublication, .finalCollision:
            expectedRootAcknowledgement = true
        }
        guard manifestDigest.count == 32, (0...1_024).contains(files), (1...2_048).contains(folders),
              files <= 2_048 - folders, verifiedFiles >= 0, verifiedFiles <= files,
              verifiedBytes <= logicalBytes,
              rootAcknowledged || verifiedFiles == 0 && verifiedBytes == 0,
              rootAcknowledged == expectedRootAcknowledgement,
              outcome != .verified || rootAcknowledged && verifiedFiles == files && verifiedBytes == logicalBytes else {
            throw RemoteSettingsFailure.invalidRecord
        }
    }
}

struct SMBUploadRecord: Codable, Sendable, Equatable, CustomDebugStringConvertible {
    let id: UUID, server: SMBConnectionAddress, account: String
    let directory: [SMBRemoteName], remoteName: SMBRemoteName, sourceName: String, logicalBytes: UInt64
    var outcome: SMBUploadOutcome, digest: Data?
    var folder: SMBFolderUploadRecord? = nil
    var debugDescription: String { "<SMB upload record>" }
    var temporaryName: String { ".traverse-smb-upload-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part" }
    var coldOutcome: SMBUploadOutcome {
        switch outcome {
        case .prepared: .notStarted
        case .stageRequested: .stageMayExist
        case .stageConfirmed: .reviewTemporary
        case .publicationRequested: .reviewPublication
        default: outcome
        }
    }
    func validate() throws {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000",
              !account.isEmpty, account.utf8.count <= 256, !account.utf8.contains(0),
              !sourceName.isEmpty, sourceName.utf8.count <= 1024, !sourceName.utf8.contains(0),
              directory.count <= 128, logicalBytes <= 1 << 30,
              directory.allSatisfy({ SMBUploadName.safe($0) }), SMBRequestedUpload.isSupportedName(remoteName.displayName),
              remoteName.displayName.lowercased() != temporaryName,
              outcome == .verified ? digest?.count == 32 : digest == nil else { throw RemoteSettingsFailure.invalidRecord }
        try folder?.validate(logicalBytes: logicalBytes, outcome: outcome)
    }
}

struct SMBUploadDocument: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "smb-upload-history"
    var revision: UInt64 = 0
    var records: [SMBUploadRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard format == 1, protocolIdentity == "smb-upload-history", records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.intValue == 1, object?["protocolIdentity"] as? String == "smb-upload-history" else {
                throw RemoteSettingsFailure.incompatibleVersion
            }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }; return value
        } catch let failure as RemoteSettingsFailure { throw failure }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}

struct SMBUploadLedgerSnapshot: Sendable { let revision: UInt64, records: [SMBUploadRecord], active: Set<UUID> }

/// Metadata only. A record never authorizes remote retry, replacement or
/// deletion; names can be sensitive and must not be sent to diagnostics.
final class SMBUploadLedger: @unchecked Sendable {
    typealias Stage = RemoteSettingsFile<SMBUploadDocument>.Stage
    private typealias File = RemoteSettingsFile<SMBUploadDocument>
    private let directory: URL
    private let executor = UploadLocalExecutor(label: "MacExplorer.SMB.Upload.History")
    private let probe: (@Sendable (Stage) throws -> Void)?
    private var owner: File?, active = Set<UUID>()
    init(directory: URL, probe: (@Sendable (Stage) throws -> Void)? = nil) { self.directory = directory; self.probe = probe }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }
    func inspect() async throws -> SMBUploadLedgerSnapshot {
        let (value, late) = try await executor.perform { [self] in
            if let owner { try owner.validateCurrent(); return SMBUploadLedgerSnapshot(revision: owner.snapshot.revision, records: owner.snapshot.records, active: active) }
            guard let file = try File.open(directory, writing: false) else { return .init(revision: 0, records: [], active: []) }
            defer { file.close() }; return .init(revision: file.snapshot.revision, records: file.snapshot.records, active: [])
        }
        if late { throw RemoteSettingsFailure.cancelled }; return value
    }
    func prepare(_ record: SMBUploadRecord) async throws {
        try record.validate()
        _ = try await executor.perform { [self] in
            _ = try change { document in
                guard document.records.count < 64, active.isEmpty else { throw RemoteSettingsFailure.capacity }
                document.records.append(record)
            }
            active.insert(record.id)
        }
        // The append may have committed before a late cancellation. Return its
        // actual state so the caller can retire the active claim after drain.
    }
    func requestStage(_ id: UUID) throws { try executor.synchronously { [self] in try update(id, from: .prepared, to: .stageRequested) } }
    func confirmStage(_ id: UUID) throws { try executor.synchronously { [self] in try update(id, from: .stageRequested, to: .stageConfirmed) } }
    func confirmFolderRoot(_ id: UUID) throws { try executor.synchronously { [self] in
        _ = try change { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }),
                  document.records[index].outcome == .stageRequested,
                  document.records[index].folder != nil else { throw RemoteSettingsFailure.invalidRecord }
            document.records[index].outcome = .stageConfirmed
            document.records[index].folder?.rootAcknowledged = true
        }
    } }
    func checkpointFolder(_ id: UUID, files: Int, bytes: UInt64) throws { try executor.synchronously { [self] in
        _ = try change { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }),
                  document.records[index].outcome == .stageConfirmed,
                  let previous = document.records[index].folder,
                  files >= previous.verifiedFiles, files <= previous.files,
                  bytes >= previous.verifiedBytes, bytes <= document.records[index].logicalBytes else {
                throw RemoteSettingsFailure.invalidRecord
            }
            document.records[index].folder?.verifiedFiles = files
            document.records[index].folder?.verifiedBytes = bytes
        }
    } }
    func requestPublication(_ id: UUID) throws { try executor.synchronously { [self] in try update(id, from: .stageConfirmed, to: .publicationRequested) } }
    func stageCollision(_ id: UUID) throws { try executor.synchronously { [self] in try update(id, from: .stageRequested, to: .stageCollision); active.remove(id) } }
    func finalCollision(_ id: UUID) throws { try executor.synchronously { [self] in try update(id, from: .publicationRequested, to: .finalCollision); active.remove(id) } }
    func verify(_ id: UUID, digest: Data) throws { try executor.synchronously { [self] in try verifyOnQueue(id, digest: digest) } }
    private func verifyOnQueue(_ id: UUID, digest: Data) throws {
        guard digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
        _ = try change { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }),
                  document.records[index].outcome == .publicationRequested else { throw RemoteSettingsFailure.invalidRecord }
            document.records[index].outcome = .verified; document.records[index].digest = digest
        }
        active.remove(id)
    }
    func endAfterDrain(_ id: UUID, noRemoteMutation: Bool) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.contains(id) else { return }
            _ = try change { document in
                guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
                switch document.records[index].outcome {
                case .prepared: document.records[index].outcome = .notStarted
                case .stageRequested: document.records[index].outcome = noRemoteMutation ? .notStarted : .stageMayExist
                case .stageConfirmed: document.records[index].outcome = .reviewTemporary
                case .publicationRequested: document.records[index].outcome = .reviewPublication
                default: throw RemoteSettingsFailure.invalidRecord
                }
            }
            active.remove(id)
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func forget(_ id: UUID, revision: UInt64) async throws {
        let (_, late) = try await executor.perform { [self] in
            _ = try change(revision: revision) { document in
                guard !active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.busy }
                document.records.remove(at: index)
            }
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func recoverUncommittedStage() async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.isEmpty else { throw RemoteSettingsFailure.busy }
            owner?.close(); owner = try File.open(directory, writing: true, discardStage: true)
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func close() async -> Bool { await withCheckedContinuation { continuation in executor.enqueueDrain { [self] in
        guard active.isEmpty else { continuation.resume(returning: false); return }
        owner?.close(); owner = nil; continuation.resume(returning: true)
    } } }
    private func update(_ id: UUID, from: SMBUploadOutcome, to: SMBUploadOutcome) throws {
        _ = try change { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }),
                  document.records[index].outcome == from else { throw RemoteSettingsFailure.invalidRecord }
            if to == .publicationRequested, let folder = document.records[index].folder {
                guard folder.rootAcknowledged, folder.verifiedFiles == folder.files,
                      folder.verifiedBytes == document.records[index].logicalBytes else {
                    throw RemoteSettingsFailure.invalidRecord
                }
            }
            document.records[index].outcome = to
        }
    }
    private func change(revision: UInt64? = nil, body: (inout SMBUploadDocument) throws -> Void) throws -> UInt64 {
        if owner == nil { owner = try File.open(directory, writing: true, probe: probe) }
        guard let owner else { throw RemoteSettingsFailure.unavailable }
        try owner.validateCurrent()
        if let revision, owner.snapshot.revision != revision { throw RemoteSettingsFailure.staleRevision }
        var next = owner.snapshot; try body(&next)
        guard next.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }
        next.revision += 1; try owner.commit(next); return next.revision
    }
}
