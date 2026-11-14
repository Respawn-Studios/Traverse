import CryptoKit
import Darwin
import Foundation
import ExplorerCore

@_spi(Qualification) public enum ConnectionWorkspaceFailure: Error, Sendable, Equatable {
    case busy, cancelled, reviewRequired, changed, unsafe, capacity, durabilityUncertain
}
@_spi(Qualification) public enum ConnectionWorkspaceState: Sendable, Equatable {
    case unprepared, earlierMetadataNeedsReview, interruptedActivationNeedsReview
    case active, activeCompatibilityNeedsReview, interruptedRepairNeedsReview
}
@_spi(Qualification) public struct ConnectionWorkspaceInspection: Sendable {
    public let state: ConnectionWorkspaceState
    public let earlierInactiveMetadataCount: Int
}

/// Minted only by the location owner. A caller cannot turn a URL or a bool
/// into durable pool admission. Keeping this value holds no lock or fd.
@_spi(Qualification) public struct ConnectionWorkspaceAdmission: Sendable, CustomDebugStringConvertible {
    public let metadataStorage: SMBTemporaryStorage
    /// Presentation only. The actual Edit owner rechecks this witnessed record
    /// under its location lease before opening a recovery body or mutating.
    public var supportsSMBInPlaceEdits: Bool {
        guard let witness = metadataStorage.workspaceWitness else { return false }
        return witness.access == .connection && witness.record.isActive && witness.record.format == 4
    }
    public var debugDescription: String { "<validated persistent connection workspace admission>" }
    fileprivate init(_ storage: SMBTemporaryStorage) { metadataStorage = storage }
    static func mint(_ storage: SMBTemporaryStorage) -> Self { .init(storage) }
}

/// Selection of one recognized, inactive, nonhot earlier metadata directory.
/// No public constructor, lookup UUID, body/history path or deletion method.
@_spi(Qualification) public final class ConnectionWorkspaceEarlierMetadataChoice: @unchecked Sendable, CustomDebugStringConvertible {
    public let observedBytes: UInt64
    let paths: ConnectionWorkspacePaths, root: ConnectionWorkspaceIdentity
    let record: SMBCatalogFiles.Record, stamps: [String: ConnectionWorkspaceStamp]
    let locationIdentity: RemoteSettingsReadIdentity?
    public var debugDescription: String { "<opaque earlier inactive connection metadata choice>" }
    init(paths: ConnectionWorkspacePaths, root: ConnectionWorkspaceIdentity, record: SMBCatalogFiles.Record,
         stamps: [String: ConnectionWorkspaceStamp], locationIdentity: RemoteSettingsReadIdentity?) {
        self.paths = paths; self.root = root; self.record = record; self.stamps = stamps
        self.locationIdentity = locationIdentity; observedBytes = record.summary.observedBytes
    }
}

struct ConnectionWorkspacePaths: Sendable, Equatable {
    let earlier: URL, metadata: URL, record: URL
    let repairPreparation: [URL]
    init(_ layout: ApplicationStorageLayout) {
        earlier = layout.smbDirectory; metadata = layout.persistentConnectionWorkspaceDirectory
        record = layout.connectionWorkspaceRecordDirectory
        repairPreparation = layout.channel == .portable ? layout.cacheCreationChain : layout.stateCreationChain
    }
    /// Bind the durable record to the selected concrete profile namespace,
    /// without persisting raw filesystem paths or caller-supplied roots.
    var locationDigest: Data {
        Data(SHA256.hash(data: Data(([earlier.path, metadata.path, record.path].joined(separator: "\n") + "\n").utf8)))
    }
    var earlierSiblings: [URL] {
        let bodies = earlier.appendingPathExtension("original-bodies")
        return [earlier.appendingPathExtension("original-budget"), bodies,
                bodies.appendingPathExtension("original-editors"), bodies.appendingPathExtension("original-journal")]
    }
    var graph: [URL] {
        let bodies = metadata.appendingPathExtension("original-bodies")
        return [metadata, metadata.appendingPathExtension("original-budget"), bodies,
                bodies.appendingPathExtension("original-editors"), bodies.appendingPathExtension("original-journal")]
    }
    var smbInPlaceRoot: URL { ApplicationStorageLayout.smbInPlaceRecoveryDirectory(metadata: metadata) }
    var smbInPlaceBodies: URL { smbInPlaceRoot.appendingPathComponent("bodies", isDirectory: true) }
    var smbInPlaceJournal: URL { smbInPlaceRoot.appendingPathComponent("journal", isDirectory: true) }
}
struct ConnectionWorkspaceIdentity: Codable, Sendable, Equatable {
    let device: Int32, inode: UInt64, generation: UInt32, birth: Int, nanos: Int
    let volume: UUID?
    init(_ value: stat, volume: UUID? = nil) {
        device = value.st_dev; inode = value.st_ino; generation = value.st_gen
        birth = value.st_birthtimespec.tv_sec; nanos = value.st_birthtimespec.tv_nsec
        self.volume = volume
    }
    private init(device: Int32, inode: UInt64, generation: UInt32, birth: Int, nanos: Int, volume: UUID?) {
        self.device = device; self.inode = inode; self.generation = generation
        self.birth = birth; self.nanos = nanos; self.volume = volume
    }
    func rebased(device: Int32, volume: UUID?) -> Self {
        Self(device: device, inode: inode, generation: generation, birth: birth, nanos: nanos, volume: volume)
    }
    /// A durable v3 witness uses the persistent APFS volume UUID. A v1/v2
    /// witness still requires its original device number and never upgrades
    /// merely because its other stat fields happen to match.
    func matchesPersisted(_ current: Self) -> Bool {
        guard inode == current.inode, generation == current.generation,
              birth == current.birth, nanos == current.nanos else { return false }
        if let volume { return current.volume == volume }
        return device == current.device
    }
    func sameExceptDevice(_ current: Self) -> Bool {
        volume == nil && current.volume != nil && inode == current.inode &&
            generation == current.generation && birth == current.birth && nanos == current.nanos
    }
}
struct ConnectionWorkspaceStamp: Sendable, Equatable {
    let identity: ConnectionWorkspaceIdentity, bytes: Int64, blocks: Int64
    let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
    init(_ value: stat) {
        identity = .init(value); bytes = value.st_size; blocks = value.st_blocks
        modified = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changed = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}
enum ConnectionWorkspacePhase: String, Codable, Sendable { case preparing, active, repairing }
struct ConnectionWorkspaceRecord: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "traverse-persistent-connections-v1"
    var revision: UInt64 = 0
    var phase = ConnectionWorkspacePhase.preparing
    var activationID: UUID?, budgetID: UUID?
    var locationDigest: Data?
    var earlier: ConnectionWorkspaceIdentity?, earlierLock: ConnectionWorkspaceIdentity?
    var graph: [String: ConnectionWorkspaceIdentity] = [:]
    var repair: ConnectionWorkspaceRepairRecord?
    /// Present only after an explicit legacy reconciliation. It binds the new
    /// v3 record to the exact canonical v1 bytes that the owner reviewed.
    var legacySourceDigest: Data?
    /// Exact v3 canonical record selected for the explicit SMB Edit upgrade.
    /// Absent from all legacy/v3 records and never implies SFTP body migration.
    var smbUpgradeSourceDigest: Data?
    var isActive: Bool {
        phase == .active && (format == 1 && revision == 2 || format == 2 && revision >= 3 ||
            format == 3 && revision >= 2 || format == 4 && revision >= 3)
    }
    init() {}
    func encoded() throws -> Data {
        let legacy = format == 1 && protocolIdentity == "traverse-persistent-connections-v1" && (1...2).contains(revision) && repair == nil
            || format == 2 && protocolIdentity == "traverse-persistent-connections-v2" && revision >= 3
        let stable = format == 3 && protocolIdentity == "traverse-persistent-connections-v3" && revision >= 2
        let smbStable = format == 4 && protocolIdentity == "traverse-persistent-connections-v4" && revision >= 3
        guard legacy || stable || smbStable,
              let activationID, SFTPWire.validToken(activationID), let budgetID, SFTPWire.validToken(budgetID),
              earlier != nil, earlierLock != nil, locationDigest?.count == 32,
              phase == .preparing ? format == 1 && revision == 1 && graph.isEmpty :
                Set(graph.keys) == (smbStable ? ConnectionWorkspaceDisk.smbGraphKeys : ConnectionWorkspaceDisk.graphKeys) &&
                    (format == 1 ? isActive : format == 2 ? repair != nil && [.repairing, .active].contains(phase)
                     : smbStable ? phase == .active && repair == nil :
                       (phase == .active || phase == .repairing && repair != nil)),
              legacySourceDigest == nil || legacySourceDigest?.count == 32,
              stable || smbStable || legacySourceDigest == nil,
              smbStable ? smbUpgradeSourceDigest?.count == 32 : smbUpgradeSourceDigest == nil else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        let identities = [earlier, earlierLock].compactMap { $0 } + Array(graph.values)
        guard identities.allSatisfy({ stable || smbStable ? $0.volume != nil : $0.volume == nil }) else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        if let repair {
            let members = [repair.priorEarlier, repair.priorLock] + Array(repair.parentBefore.values) +
                Array(repair.parents.values) + [repair.root, repair.lock, repair.marker].compactMap { $0 }
            guard members.allSatisfy({ stable || smbStable ? $0.volume != nil : $0.volume == nil }) else {
                throw ConnectionWorkspaceFailure.reviewRequired
            }
        }
        if format == 2 || format == 3 && repair != nil { try repair?.validate(record: self) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= 8192 else { throw ConnectionWorkspaceFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw ConnectionWorkspaceFailure.reviewRequired }; return value
        } catch { throw ConnectionWorkspaceFailure.reviewRequired }
    }
}

#if DEBUG
enum ConnectionWorkspaceStage: String, Sendable, CaseIterable {
    case preparingRecorded, allocatorRefusalWritten, compatibilityFenceWritten
    case metadataFenceWritten, ledgerWritten, bodyFenceWritten, graphEstablished, activeRecorded
}
final class ConnectionWorkspaceQualification: @unchecked Sendable {
    static let shared = ConnectionWorkspaceQualification()
    private let lock = NSLock(); private var callback: (@Sendable (ConnectionWorkspaceStage) throws -> Void)?
    func set(_ value: (@Sendable (ConnectionWorkspaceStage) throws -> Void)?) { lock.withLock { callback = value } }
    func reach(_ stage: ConnectionWorkspaceStage) throws { let held = lock.withLock { callback }; try held?(stage) }
}
#endif
