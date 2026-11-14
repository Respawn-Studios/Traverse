import CoreFoundation
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import Foundation

struct SMBInPlaceLayout: Sendable {
    let storage: SMBTemporaryStorage
    var root: URL { ApplicationStorageLayout.smbInPlaceRecoveryDirectory(metadata: storage.directory) }
    var bodies: URL { root.appendingPathComponent("bodies", isDirectory: true) }
    var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
}
/// Holds the exact v4 location SH across the first private text receive and
/// baseline validation. The reader pool separately validates its root; this
/// lease is released before the native buffer is installed.
final class SMBInPlaceOpenWitness: @unchecked Sendable {
    private let storage: SMBTemporaryStorage, executor = DownloadExecutor()
    private var lease: ConnectionWorkspaceRecordLease?
    init(_ storage: SMBTemporaryStorage) { self.storage = storage }
    func hold() async throws {
        try await executor.perform { [self] in
            guard lease == nil else { throw ConnectionWorkspaceFailure.busy }
            let admitted = try storage.beginWorkspaceTransaction()
            do { try admitted?.validateCurrent(); lease = admitted }
            catch { admitted?.close(); throw error }
        }
    }
    func release() async { await executor.drain { [self] in lease?.close(); lease = nil } }
    deinit { lease?.close() }
}
struct SMBInPlaceBodyReference: Codable, Equatable, Sendable {
    let id: UUID, logicalBytes: UInt64, digest: Data
    func validate() throws {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000",
              logicalBytes <= 1 << 20, digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
    }
}
enum SMBInPlaceRecordOutcome: String, Codable, Sendable { case prepared, mutationRequested, notStarted, needsReview, verified }
struct SMBInPlaceRecord: Codable, Equatable, Sendable {
    let id: UUID, session: UUID, editorGeneration: UUID
    let fileName: String, server: String, account: String
    let before: SMBInPlaceBodyReference, edited: SMBInPlaceBodyReference
    let baseline: SMBRemoteFileSnapshot
    /// Absent in original v1 records. Only an explicit versioned Save writes this key.
    var attributeContract: SMBOriginalEditAttributeContract? = nil
    var after: SMBRemoteFileSnapshot?
    var outcome: SMBInPlaceRecordOutcome = .prepared
    func validate() throws {
        try before.validate(); try edited.validate()
        guard [id, session, editorGeneration].allSatisfy({ $0.uuidString != "00000000-0000-0000-0000-000000000000" }),
              before.id != edited.id, baseline.editEligible, baseline.size == before.logicalBytes,
              !fileName.isEmpty, fileName.utf8.count <= 1024, server.utf8.count <= 512,
              account.utf8.count <= 512,
              attributeContract == nil || attributeContract == .archiveWriteV2
                  || attributeContract == .archiveWriteCreationApproxV3 else {
            throw RemoteSettingsFailure.invalidRecord
        }
        if let after {
            guard outcome == .verified, after.editEligible, after.size == edited.logicalBytes,
                  after.index == baseline.index, after.volumeSerial == baseline.volumeSerial,
                  (attributeContract ?? .exactV1).permitsCreationWitnesses(before: baseline, after: after),
                  (attributeContract ?? .exactV1).permitsFirstPostwrite(before: baseline.attributes,
                                                                       after: after.attributes) else {
                throw RemoteSettingsFailure.invalidRecord
            }
        } else if outcome == .verified { throw RemoteSettingsFailure.invalidRecord }
    }
}
struct SMBInPlaceJournalDocument: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "smb-original-inplace-save-v1"
    var revision: UInt64 = 0
    var records: [SMBInPlaceRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard ((format == 1 && protocolIdentity == "smb-original-inplace-save-v1"
                    && records.allSatisfy({ $0.attributeContract == nil }))
                || (format == 2 && protocolIdentity == "smb-original-inplace-save-v2"
                    && records.contains(where: { $0.attributeContract == .archiveWriteV2 })
                    && !records.contains(where: { $0.attributeContract == .archiveWriteCreationApproxV3 }))
                || (format == 3 && protocolIdentity == "smb-original-inplace-save-v3"
                    && records.contains(where: { $0.attributeContract == .archiveWriteCreationApproxV3 }))),
              records.count <= 16, Set(records.map(\.id)).count == records.count else {
            throw RemoteSettingsFailure.invalidRecord
        }
        try records.forEach { try $0.validate() }
        var references: [UUID: SMBInPlaceBodyReference] = [:]
        for record in records {
            for body in [record.before, record.edited] {
                // Each Save stages two fresh bodies. A reused ID would make
                // unrelated recovery choices share the same local authority.
                guard references[body.id] == nil else { throw RemoteSettingsFailure.invalidRecord }
                references[body.id] = body
            }
        }
        guard references.count <= 32,
              references.values.reduce(UInt64(0), { $0 + $1.logicalBytes + (64 << 10) }) <= 30 << 20 else {
            throw RemoteSettingsFailure.capacity
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let value = object?["format"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  ((value.intValue == 1 && object?["protocolIdentity"] as? String == "smb-original-inplace-save-v1")
                    || (value.intValue == 2 && object?["protocolIdentity"] as? String == "smb-original-inplace-save-v2")
                    || (value.intValue == 3 && object?["protocolIdentity"] as? String == "smb-original-inplace-save-v3")) else {
                throw RemoteSettingsFailure.incompatibleVersion
            }
            let decoded = try JSONDecoder().decode(Self.self, from: bytes)
            guard try decoded.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }
            return decoded
        } catch let issue as RemoteSettingsFailure { throw issue }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}
final class SMBInPlaceJournal: @unchecked Sendable {
    typealias File = RemoteSettingsFile<SMBInPlaceJournalDocument>
    let layout: SMBInPlaceLayout
    private let executor = UploadLocalExecutor(label: "Traverse.SMB.InPlace.Journal")
    private var owner: File?, active: UUID?, workspace: ConnectionWorkspaceRecordLease?
    init(layout: SMBInPlaceLayout) { self.layout = layout }
    private func requirePersisted(_ file: File) throws {
        try file.validateCurrent()
        let directory = try ConnectionWorkspaceDisk.openDirectory(layout.journal)
        defer { Darwin.close(directory) }
        _ = try ConnectionWorkspaceDisk.namedIdentity(directory, "servers.json", stable: true)
    }
    func inspect() async throws -> SMBInPlaceJournalDocument {
        let (value, late) = try await executor.perform { [self] in
            let workspace = try layout.storage.beginWorkspaceTransaction()
            defer { workspace?.close() }
            try workspace?.validateCurrent()
            if let owner { try requirePersisted(owner); return owner.snapshot }
            guard let file = try File.open(layout.journal, writing: false) else { throw RemoteSettingsFailure.recoveryRequired }
            defer { file.close() }; try requirePersisted(file); return file.snapshot
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }; return value
    }
    func begin() async throws {
        let (_, late) = try await executor.perform { [self] in
            guard owner == nil, active == nil else { throw RemoteSettingsFailure.busy }
            let held = try layout.storage.beginWorkspaceTransaction()
            do {
                try held?.validateCurrent()
                guard let file = try File.open(layout.journal, writing: true) else { throw RemoteSettingsFailure.unavailable }
                do { try requirePersisted(file) }
                catch { file.close(); throw error }
                owner = file; workspace = held
            } catch { held?.close(); throw error }
        }
        if late { await endAfterActualDrain(nil); throw RemoteSettingsFailure.cancelled }
    }
    func prepare(_ record: SMBInPlaceRecord) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active == nil, let owner else { throw RemoteSettingsFailure.busy }
            try workspace?.validateCurrent(); try owner.validateCurrent(); try record.validate()
            guard record.outcome == .prepared, owner.snapshot.revision < UInt64.max,
                  owner.snapshot.records.count < 16, !owner.snapshot.records.contains(where: { $0.id == record.id }) else {
                throw RemoteSettingsFailure.capacity
            }
            var next = owner.snapshot; next.revision += 1; next.records.append(record)
            if record.attributeContract == .archiveWriteCreationApproxV3 && next.format < 3 {
                next.format = 3; next.protocolIdentity = "smb-original-inplace-save-v3"
            } else if record.attributeContract == .archiveWriteV2 && next.format == 1 {
                next.format = 2; next.protocolIdentity = "smb-original-inplace-save-v2"
            }
            _ = try next.encoded(); try owner.commit(next); active = record.id
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func mutationIntentOnSessionExecutor(_ id: UUID) throws {
        try executor.synchronously { [self] in try update(id) { record in
            guard record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }
            record.outcome = .mutationRequested
        } }
    }
    func changedBeforeMutationOnSessionExecutor(_ id: UUID) throws {
        try executor.synchronously { [self] in try update(id) { record in
            guard record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }
            record.outcome = .notStarted
        } }
    }
    func verifiedOnSessionExecutor(_ id: UUID, after: SMBRemoteFileSnapshot) throws {
        try executor.synchronously { [self] in try update(id) { record in
            guard record.outcome == .mutationRequested else { throw RemoteSettingsFailure.invalidRecord }
            record.after = after; record.outcome = .verified
        } }
    }
    private func update(_ id: UUID, change: (inout SMBInPlaceRecord) throws -> Void) throws {
        guard active == id, let owner else { throw RemoteSettingsFailure.busy }
        try workspace?.validateCurrent(); try owner.validateCurrent()
        var next = owner.snapshot
        guard next.revision < UInt64.max, let index = next.records.firstIndex(where: { $0.id == id }) else {
            throw RemoteSettingsFailure.missing
        }
        try change(&next.records[index]); next.revision += 1
        _ = try next.encoded(); try owner.commit(next)
    }
    func endAfterActualDrain(_ id: UUID?) async {
        await executor.drain { [self] in
            if let id, active == id {
                try? update(id) { record in
                    if record.outcome == .mutationRequested { record.outcome = .needsReview }
                    else if record.outcome == .prepared { record.outcome = .notStarted }
                }
            }
            active = nil; owner?.close(); owner = nil; workspace?.close(); workspace = nil
        }
    }
}
struct SMBInPlaceStagedBody: Sendable {
    let reference: SMBInPlaceBodyReference, spool: RemoteDownloadSpool
}
struct SMBInPlaceStagingInterruption: Error, Sendable { let recordID: UUID? }
final class SMBInPlaceBodies: Sendable {
    let store: RemoteDownloadStore
    init(layout: SMBInPlaceLayout) throws { store = try .init(directory: layout.bodies) }
    func stage(_ bytes: Data) async throws -> SMBInPlaceStagedBody {
        guard bytes.count <= 1 << 20 else { throw RemoteDownloadStorageFailure.capacity }
        let request = UUID()
        let spool = try await store.executor.perform { [store] in
            try RemoteDownloadSpool(directory: store.directory, request: request,
                expectedBytes: UInt64(bytes.count), tree: false, hooks: store.hooks)
        }
        do {
            for offset in stride(from: 0, to: bytes.count, by: 32768) {
                let chunk = bytes.subdata(in: offset..<min(offset + 32768, bytes.count))
                try await spool.append(request: request, offset: UInt64(offset), bytes: chunk)
            }
            let digest = try await spool.seal(request: request, receivedBytes: UInt64(bytes.count))
            return .init(reference: .init(id: spool.id, logicalBytes: UInt64(bytes.count), digest: digest), spool: spool)
        } catch {
            do { try await spool.removeAfterDrain() }
            catch { _ = await spool.abandon(); throw SMBInPlaceStagingInterruption(recordID: nil) }
            throw error
        }
    }
}
/// One storage owner's original-Save metadata contract. The app's ordinary
/// initializer always selects exact v1; qualification choices are explicit.
@_spi(Qualification) public enum SMBOriginalSaveAttributePolicy: Sendable, Equatable {
    case exactV1, sourceQualification, creationApproximationQualification
    var contract: SMBOriginalEditAttributeContract {
        switch self {
        case .exactV1: return .exactV1
        case .sourceQualification: return .archiveWriteV2
        case .creationApproximationQualification: return .archiveWriteCreationApproxV3
        }
    }
}
@_spi(Qualification) public final class SMBInPlaceWorkingCopyStorage: Sendable {
    let layout: SMBInPlaceLayout, journal: SMBInPlaceJournal, bodies: SMBInPlaceBodies, textReads: SMBTextReadStorage
    let originalSaveAttributePolicy: SMBOriginalSaveAttributePolicy
    public convenience init(metadataStorage: SMBTemporaryStorage) throws {
        try self.init(metadataStorage: metadataStorage, coldRecovery: false, originalSaveAttributePolicy: .exactV1)
    }
    @_spi(Qualification) public convenience init(metadataStorage: SMBTemporaryStorage,
        originalSaveAttributePolicy: SMBOriginalSaveAttributePolicy) throws {
        try self.init(metadataStorage: metadataStorage, coldRecovery: false,
            originalSaveAttributePolicy: originalSaveAttributePolicy)
    }
    init(metadataStorage: SMBTemporaryStorage, coldRecovery: Bool,
         originalSaveAttributePolicy: SMBOriginalSaveAttributePolicy = .exactV1) throws {
        if coldRecovery {
            guard metadataStorage.workspaceWitness?.access == .coldRecovery else {
                throw ConnectionWorkspaceFailure.reviewRequired
            }
        } else { try metadataStorage.requireDurableOriginalAdmission() }
        if let witness = metadataStorage.workspaceWitness, witness.record.format != 4 {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        layout = .init(storage: metadataStorage)
        self.originalSaveAttributePolicy = originalSaveAttributePolicy
        journal = .init(layout: layout)
        bodies = try .init(layout: layout)
        textReads = .init(sharing: try SMBDownloadStorage(directory: layout.bodies))
    }
    public func recoveryChoicesAfterExplicitRequest() async throws -> [SMBInPlaceRecoveryChoice] {
        try await recoveryChoicesAfterExplicitRequest(reader: nil)
    }
    func recoveryChoicesAfterExplicitRequest(reader: SMBInPlaceRecoveryReadOwner?) async throws -> [SMBInPlaceRecoveryChoice] {
        let document = try await journal.inspect()
        let inventory = try await bodies.store.inspect()
        let expected = Set(document.records.flatMap { [$0.before.id, $0.edited.id] })
        guard inventory.count == expected.count, inventory.allSatisfy({ expected.contains($0.id) && !$0.active && !$0.isFolder }) else {
            throw RemoteSettingsFailure.recoveryRequired
        }
        for record in document.records {
            for body in [record.before, record.edited] {
                guard inventory.contains(where: { $0.id == body.id && $0.expectedBytes == body.logicalBytes }) else {
                    throw RemoteSettingsFailure.recoveryRequired
                }
            }
        }
        return document.records.map { SMBInPlaceRecoveryChoice(record: $0, layout: layout,
                                                                journalRevision: document.revision, reader: reader) }
    }
    func prepareSave(selection: SMBDownloadSelection, session: UUID, generation: UUID,
                     baseline: SMBRemoteFileSnapshot, before: TextDocumentValue,
                     edited: TextDocumentValue, server: SMBServerDraft) async throws -> SMBInPlaceEditAttempt {
        let attributeContract = originalSaveAttributePolicy.contract
        try await journal.begin()
        var originals: SMBInPlaceStagedBody?, edits: SMBInPlaceStagedBody?
        var preparedRecord: UUID?
        do {
            let existing = try await journal.inspect()
            let inventory = try await bodies.store.inspect()
            let references = existing.records.flatMap { [$0.before, $0.edited] }
            guard inventory.count == references.count,
                  inventory.allSatisfy({ item in
                      !item.active && !item.isFolder && references.contains(where: {
                          $0.id == item.id && $0.logicalBytes == item.expectedBytes
                      })
                  }) else { throw RemoteSettingsFailure.recoveryRequired }
            let oldCharge = try inventory.reduce(UInt64(0)) {
                let charge = try DownloadDisk.reservation(expectedBytes: $1.expectedBytes, tree: false)
                guard $0 <= (30 << 20) - min(charge, 30 << 20) else { throw RemoteSettingsFailure.capacity }
                return $0 + charge
            }
            let beforeCharge = try DownloadDisk.reservation(expectedBytes: UInt64(before.encoded.count), tree: false)
            let editedCharge = try DownloadDisk.reservation(expectedBytes: UInt64(edited.encoded.count), tree: false)
            guard inventory.count <= 30, oldCharge <= (30 << 20) - beforeCharge - editedCharge else {
                throw RemoteSettingsFailure.capacity
            }
            originals = try await bodies.stage(before.encoded)
            edits = try await bodies.stage(edited.encoded)
            guard let originals, let edits else { throw RemoteSettingsFailure.recoveryRequired }
            var record = SMBInPlaceRecord(id: UUID(), session: session, editorGeneration: generation,
                fileName: selection.observation.name.displayName, server: server.address.serverField,
                account: server.account, before: originals.reference, edited: edits.reference,
                baseline: baseline)
            if attributeContract != .exactV1 { record.attributeContract = attributeContract }
            let request = try SMBOriginalEditRequest(id: record.id, selection: selection, before: baseline,
                beforeDigest: originals.reference.digest, editedLength: edits.reference.logicalBytes,
                editedDigest: edits.reference.digest, attributeContract: attributeContract,
                sourceToken: selection.request)
            preparedRecord = record.id
            try await journal.prepare(record)
            let releasedBefore = await originals.spool.abandon()
            let releasedEdited = await edits.spool.abandon()
            guard releasedBefore, releasedEdited else { throw RemoteSettingsFailure.recoveryRequired }
            return .init(request: request, record: record, edited: edited.encoded, journal: journal)
        } catch {
            if let preparedRecord {
                if let originals { _ = await originals.spool.abandon() }
                if let edits { _ = await edits.spool.abandon() }
                await journal.endAfterActualDrain(preparedRecord)
                throw SMBInPlaceStagingInterruption(recordID: preparedRecord)
            }
            var cleanupUncertain = error is SMBInPlaceStagingInterruption
            if let originals {
                do { try await originals.spool.removeAfterDrain() }
                catch { _ = await originals.spool.abandon(); cleanupUncertain = true }
            }
            if let edits {
                do { try await edits.spool.removeAfterDrain() }
                catch { _ = await edits.spool.abandon(); cleanupUncertain = true }
            }
            await journal.endAfterActualDrain(nil)
            if cleanupUncertain { throw SMBInPlaceStagingInterruption(recordID: nil) }
            throw error
        }
    }
}

final class SMBInPlaceEditAttempt: @unchecked Sendable {
    let request: SMBOriginalEditRequest, record: SMBInPlaceRecord, journal: SMBInPlaceJournal
    private let edited: Data, lock = NSLock()
    private var admittedValue = false, mutationValue = false, finishedValue = false
    init(request: SMBOriginalEditRequest, record: SMBInPlaceRecord, edited: Data, journal: SMBInPlaceJournal) {
        self.request = request; self.record = record; self.edited = edited; self.journal = journal
    }
    func admit() -> Bool { lock.withLock {
        guard !admittedValue, !finishedValue else { return false }
        admittedValue = true; return true
    } }
    var admitted: Bool { lock.withLock { admittedValue } }
    var mutationRequested: Bool { lock.withLock { mutationValue } }
    var finished: Bool { lock.withLock { finishedValue } }
    func bytesOnSessionExecutor(offset: UInt64, count: Int) throws -> Data {
        guard !Thread.isMainThread, offset <= UInt64(edited.count), count > 0,
              count <= 32768, UInt64(count) <= UInt64(edited.count) - offset else {
            throw SMBTextFailure.changed
        }
        return edited.subdata(in: Int(offset)..<Int(offset)+count)
    }
    func authorizeOnSessionExecutor() throws {
        try journal.mutationIntentOnSessionExecutor(record.id)
        lock.withLock { mutationValue = true }
    }
    func changedOnSessionExecutor() throws {
        try journal.changedBeforeMutationOnSessionExecutor(record.id)
        lock.withLock { finishedValue = true }
    }
    func verifiedOnSessionExecutor(_ after: SMBRemoteFileSnapshot) throws {
        try journal.verifiedOnSessionExecutor(record.id, after: after)
        lock.withLock { finishedValue = true }
    }
    func endAfterActualDrain() async { await journal.endAfterActualDrain(record.id) }
}
