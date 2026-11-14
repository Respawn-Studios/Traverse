import CoreFoundation
import Foundation

@_spi(Qualification) public enum SMBActionFailure: Error, Sendable, Equatable {
    case invalidInput, caseOnlyRename, unavailable, busy, stopped, collision, destinationUnavailable, reviewRequired
    case preflightRefused(SMBActionPreflightCode)
}
@_spi(Qualification) public enum SMBActionOutcome: String, Codable, Sendable {
    case prepared, mutationRequested, confirmed, collision, notEmpty, notStarted, needsReview, stageCollision, finalCollision
}
@_spi(Qualification) public enum SMBActionOperation: String, Codable, Sendable {
    case rename, delete, renameDirectory, deleteEmptyDirectory, move, moveDirectory, copy
    var isDirectory: Bool { self == .renameDirectory || self == .deleteEmptyDirectory || self == .moveDirectory }
    var isRename: Bool { self == .rename || self == .renameDirectory }
    var isMove: Bool { self == .move || self == .moveDirectory }
    var isCopy: Bool { self == .copy }
}
@_spi(Qualification) public struct SMBSelectedActionRequest: Sendable, CustomDebugStringConvertible {
    public static let maximumCopyBytes: UInt64 = 64 << 30
    public let request: UUID, connection: UUID, snapshot: SMBDirectorySnapshot
    public let directory: [SMBRemoteName], observation: SMBDirectoryObservation
    public let operation: SMBActionOperation, target: SMBRemoteName?
    public let destinationDirectory: [SMBRemoteName]?
    public var debugDescription: String { "<selected SMB action request>" }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, renameTo name: String) throws {
        let target = try SMBRemoteName(name)
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
                      observation: observation, operation: .rename, target: target)
    }
    /// The caller must first show that SMB Delete is permanent, with no Trash
    /// or Undo promise. False cannot construct a delete request.
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, permanentlyDelete confirmed: Bool) throws {
        guard confirmed else { throw SMBActionFailure.invalidInput }
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
                      observation: observation, operation: .delete, target: nil)
    }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, renameDirectoryTo name: String) throws {
        let target = try SMBRemoteName(name)
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
                      observation: observation, operation: .renameDirectory, target: target)
    }
    /// This is permanent and succeeds only if the server confirms the directory is empty.
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, permanentlyDeleteEmptyDirectory confirmed: Bool) throws {
        guard confirmed else { throw SMBActionFailure.invalidInput }
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
                      observation: observation, operation: .deleteEmptyDirectory, target: nil)
    }
    /// Move the selected root inside this authenticated share, keeping its name.
    /// No replacement, recursive transfer, cross-share fallback or Undo is implied.
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, moveTo destination: [SMBRemoteName]) throws {
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
            observation: observation, operation: observation.isDirectory ? .moveDirectory : .move,
            target: nil, destinationDirectory: destination)
    }
    /// One selected regular file in the retained authenticated share. The
    /// destination receives data bytes and server-created metadata only.
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                observation: SMBDirectoryObservation, copyTo destination: [SMBRemoteName], as name: String) throws {
        try self.init(connection: connection, snapshot: snapshot, directory: directory,
            observation: observation, operation: .copy, target: SMBRemoteName(name),
            destinationDirectory: destination)
    }
    private init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                 observation: SMBDirectoryObservation, operation: SMBActionOperation, target: SMBRemoteName?,
                 destinationDirectory: [SMBRemoteName]? = nil) throws {
        if operation.isRename, let target, target.wireUTF16 != observation.name.wireUTF16,
           Self.sameIgnoringASCIICase(target, observation.name) { throw SMBActionFailure.caseOnlyRename }
        let parentUnits = directory.reduce(0) { $0 + $1.wireUTF16.count / 2 } + max(0, directory.count - 1)
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              observation.id > 0, observation.isDirectory == operation.isDirectory, !observation.isReparsePoint,
              !operation.isCopy || observation.logicalBytes <= Self.maximumCopyBytes,
              observation.attributes & 0x450 == (operation.isDirectory ? 0x10 : 0),
              let object = observation.objectID, let parent = observation.parentID,
              object > 0, parent > 0, object != parent, object != UInt64.max, parent != UInt64.max,
              directory.count <= 32, directory.allSatisfy(SMBUploadName.safe),
              SMBUploadName.safe(observation.name), parentUnits <= 1792,
              parentUnits + (directory.isEmpty ? 0 : 1) + observation.name.wireUTF16.count / 2 <= 2048,
              (!(operation.isRename || operation.isCopy) && target == nil) ||
              ((operation.isRename || operation.isCopy) && target != nil),
              (operation.isCopy && destinationDirectory.map {
                  SMBMoveDestination.validCopy(sourceDirectory: directory, source: observation.name,
                      destination: $0, target: target)
              } == true) || (operation.isMove && destinationDirectory.map {
                  SMBMoveDestination.validMove(sourceDirectory: directory, name: observation.name,
                      isDirectory: operation.isDirectory, destination: $0)
              } == true) || (!(operation.isMove || operation.isCopy) && destinationDirectory == nil),
              (target.map({ SMBUploadName.safe($0)
                  && (operation.isCopy || $0.wireUTF16 != observation.name.wireUTF16)
                  && (operation.isCopy || parentUnits + (directory.isEmpty ? 0 : 1) + $0.wireUTF16.count / 2 <= 2048) }) ?? !(operation.isRename || operation.isCopy))
        else { throw SMBActionFailure.invalidInput }
        request = UUID(); self.connection = connection; self.snapshot = snapshot; self.directory = directory
        self.observation = observation; self.operation = operation; self.target = target
        self.destinationDirectory = destinationDirectory
    }
    private static func sameIgnoringASCIICase(_ lhs: SMBRemoteName, _ rhs: SMBRemoteName) -> Bool {
        let left = Array(lhs.wireUTF16), right = Array(rhs.wireUTF16)
        guard left.count == right.count else { return false }
        for offset in stride(from: 0, to: left.count, by: 2) {
            let a = UInt16(left[offset]) | UInt16(left[offset + 1]) << 8
            let b = UInt16(right[offset]) | UInt16(right[offset + 1]) << 8
            func folded(_ unit: UInt16) -> UInt16 { (65...90).contains(unit) ? unit + 32 : unit }
            if folded(a) != folded(b) { return false }
        }
        return true
    }
    func command(ordinal: UInt64, number: UInt64) -> String {
        let name = operation.isCopy
            ? "\(SMBUploadName.path(destinationDirectory ?? []));\(SMBUploadName.wire(target!))"
            : destinationDirectory.map(SMBUploadName.path) ?? target.map(SMBUploadName.wire) ?? "-"
        return "PREPARE_ACTION \(request.uuidString) \(ordinal) \(number) \(snapshot.readID.uuidString) \(snapshot.revision) \(observation.id) \(operation.rawValue) \(name)\n"
    }
}

struct SMBActionRecord: Codable, Sendable, Equatable, CustomDebugStringConvertible {
    let id: UUID, server: SMBConnectionAddress, account: String
    let createdAt: Date
    let directory: [SMBRemoteName], source: SMBRemoteName, target: SMBRemoteName?
    let operation: SMBActionOperation, object: UInt64, parent: UInt64
    let destinationDirectory: [SMBRemoteName]?
    var outcome: SMBActionOutcome
    init(id: UUID, server: SMBConnectionAddress, account: String, createdAt: Date,
         directory: [SMBRemoteName], source: SMBRemoteName, target: SMBRemoteName?,
         operation: SMBActionOperation, object: UInt64, parent: UInt64, outcome: SMBActionOutcome,
         destinationDirectory: [SMBRemoteName]? = nil) {
        self.id = id; self.server = server; self.account = account; self.createdAt = createdAt
        self.directory = directory; self.source = source; self.target = target
        self.operation = operation; self.object = object; self.parent = parent
        self.outcome = outcome; self.destinationDirectory = destinationDirectory
    }
    var debugDescription: String { "<SMB action record>" }
    var coldOutcome: SMBActionOutcome {
        switch outcome { case .prepared: .notStarted; case .mutationRequested: .needsReview; default: outcome }
    }
    func validate() throws {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000",
              !account.isEmpty, account.utf8.count <= 256, !account.utf8.contains(0),
              (-62_135_596_800.0...253_402_300_799.0).contains(createdAt.timeIntervalSince1970),
              directory.count <= 32, directory.allSatisfy(SMBUploadName.safe),
              SMBUploadName.safe(source), object > 0, parent > 0, object != parent,
              object != UInt64.max, parent != UInt64.max,
              (!(operation.isRename || operation.isCopy) && target == nil) ||
              ((operation.isRename || operation.isCopy) && target.map({ SMBUploadName.safe($0) &&
                  (operation.isCopy || $0.wireUTF16 != source.wireUTF16) }) == true),
              outcome != .notEmpty || operation == .deleteEmptyDirectory,
              outcome != .collision || operation.isRename || operation.isMove || operation.isCopy,
              (outcome != .stageCollision && outcome != .finalCollision) || operation.isCopy,
              (operation.isCopy && destinationDirectory.map {
                  SMBMoveDestination.validCopy(sourceDirectory: directory, source: source,
                      destination: $0, target: target)
              } == true) || (operation.isMove && destinationDirectory.map {
                  SMBMoveDestination.validMove(sourceDirectory: directory, name: source,
                      isDirectory: operation.isDirectory, destination: $0)
              } == true) || (!(operation.isMove || operation.isCopy) && destinationDirectory == nil)
        else { throw RemoteSettingsFailure.invalidRecord }
    }
}
struct SMBActionDocument: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "smb-selected-file-actions"
    var revision: UInt64 = 0
    var records: [SMBActionRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard format == 1, protocolIdentity == "smb-selected-file-actions", records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.intValue == 1, object?["protocolIdentity"] as? String == "smb-selected-file-actions"
            else { throw RemoteSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }
            return value
        } catch let failure as RemoteSettingsFailure { throw failure }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}
struct SMBActionHistory: Sendable { let revision: UInt64, records: [SMBActionRecord], active: Set<UUID> }
/// A separate private APFS metadata directory. An active claim permits one
/// mutation intent, never an automatic remote retry or guessed success.
final class SMBActionLedger: @unchecked Sendable {
    private typealias File = RemoteSettingsFile<SMBActionDocument>
    private let directory: URL
    private let executor = UploadLocalExecutor(label: "MacExplorer.SMB.Action.History")
    private var owner: File?, active = Set<UUID>()
    init(directory: URL) { self.directory = directory }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }
    func inspect() async throws -> SMBActionHistory {
        let (value, late) = try await executor.perform { [self] in
            if let owner { try owner.validateCurrent(); return SMBActionHistory(revision: owner.snapshot.revision, records: owner.snapshot.records, active: active) }
            guard let file = try File.open(directory, writing: false) else { return .init(revision: 0, records: [], active: []) }
            defer { file.close() }
            return .init(revision: file.snapshot.revision, records: file.snapshot.records, active: [])
        }
        if late { throw RemoteSettingsFailure.cancelled }; return value
    }
    func prepare(_ record: SMBActionRecord) async throws {
        try record.validate()
        _ = try await executor.perform { [self] in
            _ = try change { document in
                guard document.records.count < 64, active.isEmpty else { throw RemoteSettingsFailure.capacity }
                document.records.append(record)
            }
            active.insert(record.id)
        }
    }
    func requestMutation(_ id: UUID) throws { try executor.synchronously { [self] in
        try update(id, from: .prepared, to: .mutationRequested)
    } }
    func confirmed(_ id: UUID) throws { try executor.synchronously { [self] in
        try update(id, from: .mutationRequested, to: .confirmed); active.remove(id)
    } }
    func collision(_ id: UUID) throws { try executor.synchronously { [self] in
        try update(id, from: .mutationRequested, to: .collision); active.remove(id)
    } }
    func copyCollision(_ id: UUID, stage: Bool) throws { try executor.synchronously { [self] in
        try update(id, from: .mutationRequested, to: stage ? .stageCollision : .finalCollision); active.remove(id)
    } }
    func notEmpty(_ id: UUID) throws { try executor.synchronously { [self] in
        try update(id, from: .mutationRequested, to: .notEmpty); active.remove(id)
    } }
    func destinationUnavailable(_ id: UUID) throws { try executor.synchronously { [self] in
        try update(id, from: .prepared, to: .notStarted); active.remove(id)
    } }
    func endAfterDrain(_ id: UUID, noMutation: Bool) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.contains(id) else { return }
            _ = try change { document in
                guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
                switch document.records[index].outcome {
                case .prepared: document.records[index].outcome = .notStarted
                case .mutationRequested: document.records[index].outcome = noMutation ? .notStarted : .needsReview
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
    func recoverUncommittedLocalStage() async throws {
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
    private func update(_ id: UUID, from: SMBActionOutcome, to: SMBActionOutcome) throws {
        _ = try change { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }),
                  document.records[index].outcome == from else { throw RemoteSettingsFailure.invalidRecord }
            document.records[index].outcome = to
        }
    }
    private func change(revision: UInt64? = nil, body: (inout SMBActionDocument) throws -> Void) throws -> UInt64 {
        if owner == nil { owner = try File.open(directory, writing: true) }
        guard let owner else { throw RemoteSettingsFailure.unavailable }
        try owner.validateCurrent()
        if let revision, owner.snapshot.revision != revision { throw RemoteSettingsFailure.staleRevision }
        var next = owner.snapshot; try body(&next)
        guard next.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }
        next.revision += 1; try owner.commit(next); return next.revision
    }
}

@_spi(Qualification) public struct SMBActionRecordSummary: Sendable, CustomDebugStringConvertible {
    public let id: UUID, server: SMBConnectionAddress, account: String
    public let createdAt: Date
    public let directory: [SMBRemoteName], source: SMBRemoteName, target: SMBRemoteName?
    public let operation: SMBActionOperation, outcome: SMBActionOutcome, active: Bool
    public let destinationDirectory: [SMBRemoteName]?
    /// Deterministic candidate leaf for review. This does not assert that the
    /// stage exists; only a finalCollision guarantees a retained owned stage.
    public var temporaryCopyName: String? {
        operation.isCopy ? ".traverse-smb-copy-\(id.uuidString.lowercased()).part" : nil
    }
    public var debugDescription: String { "<SMB action summary>" }
}
@_spi(Qualification) public struct SMBActionHistorySnapshot: Sendable {
    public let revision: UInt64, records: [SMBActionRecordSummary]
}
@_spi(Qualification) public struct SMBCompletedAction: Sendable, CustomDebugStringConvertible {
    public let id: UUID, outcome: SMBActionOutcome
    public var debugDescription: String { "<SMB completed action>" }
}
@_spi(Qualification) public final class SMBActionStorage: Sendable {
    let ledger: SMBActionLedger
    public init(directory: URL) { ledger = SMBActionLedger(directory: directory) }
    public func inspect() async throws -> SMBActionHistorySnapshot {
        let value = try await ledger.inspect()
        return .init(revision: value.revision, records: value.records.map {
            .init(id: $0.id, server: $0.server, account: $0.account, createdAt: $0.createdAt, directory: $0.directory,
                  source: $0.source, target: $0.target, operation: $0.operation,
                  outcome: value.active.contains($0.id) ? $0.outcome : $0.coldOutcome,
                  active: value.active.contains($0.id), destinationDirectory: $0.destinationDirectory)
        })
    }
    public func forget(_ id: UUID, revision: UInt64) async throws { try await ledger.forget(id, revision: revision) }
    public func recoverUncommittedLocalStage() async throws { try await ledger.recoverUncommittedLocalStage() }
    public func close() async -> Bool { await ledger.close() }
}
final class SMBActionAttempt: @unchecked Sendable {
    let request: SMBSelectedActionRequest, record: SMBActionRecord, ledger: SMBActionLedger
    let progress: (@Sendable (UInt64, UInt64) -> Void)?
    private let lock = NSLock()
    private var admittedValue = false, cancelledValue = false, requestedValue = false, finishedValue = false
    init(request: SMBSelectedActionRequest, record: SMBActionRecord, ledger: SMBActionLedger,
         progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) {
        self.request = request; self.record = record; self.ledger = ledger; self.progress = progress
    }
    func admit() -> Bool { lock.withLock {
        guard !admittedValue, !cancelledValue, !finishedValue else { return false }
        admittedValue = true; return true
    } }
    var admitted: Bool { lock.withLock { admittedValue } }
    var mutationRequested: Bool { lock.withLock { requestedValue } }
    var finished: Bool { lock.withLock { finishedValue } }
    func cancel() { lock.withLock { cancelledValue = true } }
    func readyOnExecutor() throws {
        guard !lock.withLock({ cancelledValue }) else { throw SMBActionFailure.stopped }
        try ledger.requestMutation(record.id)
        lock.withLock { requestedValue = true }
    }
    func completeOnExecutor(outcome: SMBActionOutcome) throws -> SMBCompletedAction {
        guard mutationRequested else { throw SMBActionFailure.invalidInput }
        switch outcome {
        case .confirmed: try ledger.confirmed(record.id)
        case .collision:
            guard record.operation.isRename || record.operation.isMove || record.operation.isCopy else { throw SMBActionFailure.invalidInput }
            try ledger.collision(record.id)
        case .stageCollision, .finalCollision:
            guard record.operation.isCopy else { throw SMBActionFailure.invalidInput }
            try ledger.copyCollision(record.id, stage: outcome == .stageCollision)
        case .notEmpty:
            guard record.operation == .deleteEmptyDirectory else { throw SMBActionFailure.invalidInput }
            try ledger.notEmpty(record.id)
        default: throw SMBActionFailure.invalidInput
        }
        lock.withLock { finishedValue = true }
        return .init(id: record.id, outcome: outcome)
    }
    func destinationUnavailableOnExecutor() throws {
        guard !mutationRequested, !lock.withLock({ cancelledValue }) else { throw SMBActionFailure.stopped }
        try ledger.destinationUnavailable(record.id)
        lock.withLock { finishedValue = true }
    }
}
