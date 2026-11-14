import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum SFTPSharedBudgetFailure: Error, Sendable { case unsafe, busy, capacity, recoveryRequired, ownerEnded, stale, referenced }

/// One actual metadata pool and its closed sibling roots. No path can be
/// selected by an editor, copied from a journal or supplied by a body producer.
struct SFTPSharedBudgetLayout: Sendable, Equatable, CustomDebugStringConvertible {
    let storage: SMBTemporaryStorage
    var metadata: URL { storage.directory }
    var ledger: URL { metadata.appendingPathExtension("original-budget") }
    var bodies: URL { metadata.appendingPathExtension("original-bodies") }
    var editors: URL { bodies.appendingPathExtension("original-editors") }
    var journal: URL { bodies.appendingPathExtension("original-journal") }
    var debugDescription: String { "<shared metadata and Original storage>" }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metadata == rhs.metadata && lhs.storage.poolByteLimit == rhs.storage.poolByteLimit
            && lhs.storage.sessionByteLimit == rhs.storage.sessionByteLimit
    }
}
enum SFTPSharedMetadataPurpose: Sendable {
    case ordinary
    case originalPending(session: UUID)
}
enum SharedMetadataKind: String, Codable, Sendable { case legacy, ordinary, original }
enum SharedMetadataPhase: String, Codable, Sendable { case allocating, live, removalPending, orphan, removed }
enum SharedBodyPhase: String, Codable, Sendable { case allocating, allocated, removalPending, removed }
enum SharedPoolPhase: String, Codable, Sendable { case migrating, active }
struct SharedMetadataCharge: Codable, Sendable, Equatable {
    let id: UUID, kind: SharedMetadataKind, session: UUID?, quota: UInt64
    var context: Data?
    var phase: SharedMetadataPhase
}
struct SharedOriginalBodyCharge: Codable, Sendable, Equatable {
    let id: UUID, owner: UUID?, expectedBytes: UInt64, reservedBytes: UInt64
    var phase: SharedBodyPhase
}
struct SFTPSharedBudgetDocument: RemoteSettingsDocument, Codable, Sendable {
    static let ownerBytes: UInt64 = 512 << 20
    static let originalMetadataBytes: UInt64 = 480 << 20
    static let originalBodyBytes: UInt64 = 30 << 20
    static let expandedBodySlots = 64
    static let ownerOverheadBytes: UInt64 = 2 << 20
    static let globalOverheadBytes: UInt64 = 2 << 20
    var format = 1, protocolIdentity = "sftp-original-shared-storage"
    var retirements: [SFTPRetainedRetirementIntent]? = nil
    var revision: UInt64 = 0
    var budgetID: UUID?
    var poolPhase = SharedPoolPhase.migrating
    var metadata: [SharedMetadataCharge] = []
    var bodies: [SharedOriginalBodyCharge] = []
    init() {}
    func validate() throws {
        guard [1, 2, 3].contains(format), protocolIdentity == "sftp-original-shared-storage", metadata.count <= 64,
              bodies.count <= (format == 3 ? Self.expandedBodySlots : 8),
              Set(metadata.map(\.id)).count == metadata.count, Set(bodies.map(\.id)).count == bodies.count,
              Set(metadata.compactMap(\.session)).count == metadata.compactMap(\.session).count,
              revision > 0, let budgetID, SFTPWire.validToken(budgetID) else { throw SFTPSharedBudgetFailure.unsafe }
        guard (format == 1 ? retirements == nil : retirements != nil) else { throw SFTPSharedBudgetFailure.unsafe }
        try SFTPRetainedRetirementIntent.validateAll(retirements ?? [], document: self)
        for item in metadata {
            guard SFTPWire.validToken(item.id), item.context == nil || item.context?.count == 32,
                  item.kind == .original ? (1 << 20...Self.originalMetadataBytes).contains(item.quota) && item.session.map(SFTPWire.validToken) == true
                    : (1 << 20...Self.ownerBytes).contains(item.quota) && item.session == nil && item.context == nil else { throw SFTPSharedBudgetFailure.unsafe }
        }
        for body in bodies {
            guard SFTPWire.validToken(body.id), body.expectedBytes <= 1 << 20,
                  body.reservedBytes == (try DownloadDisk.reservation(expectedBytes: body.expectedBytes, tree: false)),
                  body.owner == nil || metadata.contains(where: { $0.id == body.owner && $0.kind == .original && $0.context?.count == 32 }) else { throw SFTPSharedBudgetFailure.unsafe }
        }
        _ = try Self.sum(bodies.filter { $0.phase != .removed }.map(\.reservedBytes), limit: Self.originalBodyBytes)
        for owner in metadata where owner.kind == .original {
            let held = bodies.filter { $0.owner == owner.id && $0.phase != .removed }
            try Self.sum(held.map(\.reservedBytes), limit: Self.originalBodyBytes)
        }
    }
    @discardableResult static func sum(_ amounts: [UInt64], limit: UInt64) throws -> UInt64 {
        var value: UInt64 = 0
        for amount in amounts {
            guard amount <= limit, value <= limit - amount else { throw SFTPSharedBudgetFailure.capacity }
            value += amount
        }
        return value
    }
    /// Active/uncertain metadata reserves complete owner growth. Only a known
    /// exact clean metadata removal reduces Original to retained body charges.
    func globalCharge(actualBodies: [UUID: UInt64], limit: UInt64) throws -> UInt64 {
        var amounts = [Self.globalOverheadBytes]
        for owner in metadata {
            if owner.phase != .removed { amounts.append(Self.ownerBytes); continue }
            if owner.kind == .original {
                let held = bodies.filter { $0.owner == owner.id && $0.phase != .removed }
                if !held.isEmpty {
                    amounts.append(Self.ownerOverheadBytes)
                    amounts += held.map { max($0.reservedBytes, actualBodies[$0.id] ?? 0) }
                }
            }
        }
        amounts += bodies.filter { $0.owner == nil && $0.phase != .removed }.map { max($0.reservedBytes, actualBodies[$0.id] ?? 0) }
        return try Self.sum(amounts, limit: limit)
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw SFTPSharedBudgetFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let version = object?["format"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), [1, 2, 3].contains(version.intValue),
                  object?["protocolIdentity"] as? String == "sftp-original-shared-storage" else { throw SFTPSharedBudgetFailure.recoveryRequired }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw SFTPSharedBudgetFailure.unsafe }; return value
        } catch let issue as SFTPSharedBudgetFailure { throw issue }
        catch { throw SFTPSharedBudgetFailure.recoveryRequired }
    }
}

/// Liveness is separate from SMBCatalogFiles' closing lock. No lock is held
/// while acquiring the common pool lock, so finish/body admission cannot cycle.
final class SFTPSharedOwnerLiveness: @unchecked Sendable {
    private let lock = NSLock(); private var live = true
    func end() { lock.withLock { live = false } }
    func check() throws { try lock.withLock { if !live { throw SFTPSharedBudgetFailure.ownerEnded } } }
}
final class SFTPOriginalStorageOwner: @unchecked Sendable, CustomDebugStringConvertible {
    let layout: SFTPSharedBudgetLayout, budgetID: UUID, catalogID: UUID, session: UUID, contextDigest: Data
    private let live: SFTPSharedOwnerLiveness
    fileprivate init(layout: SFTPSharedBudgetLayout, budgetID: UUID, catalogID: UUID, session: UUID,
                     contextDigest: Data, live: SFTPSharedOwnerLiveness) {
        self.layout = layout; self.budgetID = budgetID; self.catalogID = catalogID; self.session = session
        self.contextDigest = contextDigest; self.live = live
    }
    var debugDescription: String { "<live Original storage owner>" }
    func validate(session: UUID, context: SFTPVerifiedSessionContext) throws {
        try live.check()
        guard self.session == session, try Self.digest(context) == contextDigest else { throw SFTPSharedBudgetFailure.stale }
    }
    func checkLive() throws { try live.check() }
    static func digest(_ context: SFTPVerifiedSessionContext) throws -> Data {
        let value = try SFTPOriginalContext(context); try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
    // Only this file's ledger-backed actual metadata binding can mint an owner.
    static func bindOnMetadataExecutor(files: SMBCatalogFiles, session: UUID,
                                       context: SFTPVerifiedSessionContext) throws -> SFTPOriginalStorageOwner {
        try files.sharedLiveness.check()
        let layout = SFTPSharedBudgetLayout(storage: files.storage)
        let transaction = try SFTPSharedBudgetTransaction.open(layout: layout, writing: true)
        defer { transaction.close() }
        let digest = try Self.digest(context)
        try transaction.bindOriginal(catalogID: files.id, session: session, context: digest, heldLease: files.lease)
        guard let budgetID = transaction.document.budgetID else { throw SFTPSharedBudgetFailure.unsafe }
        return .init(layout: layout, budgetID: budgetID, catalogID: files.id, session: session, contextDigest: digest, live: files.sharedLiveness)
    }
}

#if DEBUG
enum SFTPSharedBudgetStage: String, Sendable, Hashable {
    case metadataReserved, metadataBeforeMkdir, metadataDirectoryCreated, metadataMaterialized, metadataRemovalIntent, metadataRemoved
    case fenceWritten, ledgerWritten, bodyFenceWritten, bodyReserved, bodyBeforeMkdir, bodyDirectoryCreated, bodyMaterialized
    case bodyRemovalIntent, bodyDeleted, bodyReleased
}
final class SFTPSharedBudgetQualification: @unchecked Sendable {
    static let shared = SFTPSharedBudgetQualification()
    private let lock = NSLock(); private var callback: (@Sendable (SFTPSharedBudgetStage) throws -> Void)?
    func set(_ callback: (@Sendable (SFTPSharedBudgetStage) throws -> Void)?) { lock.withLock { self.callback = callback } }
    func reach(_ stage: SFTPSharedBudgetStage) throws { let held = lock.withLock { callback }; try held?(stage) }
}
#endif
