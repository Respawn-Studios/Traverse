import CryptoKit
import Darwin
import Foundation

@_spi(Qualification) public enum ConnectionWorkspaceRebindAction: Sendable, Equatable {
    case reconcile, resume
}

/// An explicit, exact legacy record selection. It contains no path or content
/// authority that a caller can construct, and it never permits body deletion.
@_spi(Qualification) public final class ConnectionWorkspaceRebindChoice: Sendable, CustomDebugStringConvertible {
    public let action: ConnectionWorkspaceRebindAction
    public let observedObjectCount: Int
    let paths: ConnectionWorkspacePaths
    let location: RemoteSettingsReadIdentity
    let current: Data, pending: Data?, proposed: Data
    let observation: ConnectionWorkspaceRepairObservation
    init(action: ConnectionWorkspaceRebindAction, paths: ConnectionWorkspacePaths,
         location: RemoteSettingsReadIdentity, current: Data, pending: Data?,
         proposed: Data, observation: ConnectionWorkspaceRepairObservation, observedObjectCount: Int) {
        self.action = action; self.paths = paths; self.location = location
        self.current = current; self.pending = pending; self.proposed = proposed
        self.observation = observation; self.observedObjectCount = observedObjectCount
    }
    public var debugDescription: String { "<explicit legacy workspace identity reconciliation choice>" }
}

/// The only route that compares a legacy durable identity without its old
/// mount device number. It requires owner review, exact private objects and
/// fences, one old/new APFS volume mapping, and a clean held graph. A v2 repair
/// record or an uncertain graph remains preserved for separate review.
enum ConnectionWorkspaceRebindDisk {
    static func project(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord) throws -> ConnectionWorkspaceRecord {
        try ConnectionWorkspaceDisk.checkThread()
        guard record.format == 1, record.revision == 2, record.isActive,
              record.repair == nil, record.legacySourceDigest == nil,
              record.locationDigest == paths.locationDigest,
              let activation = record.activationID, let budget = record.budgetID,
              let earlier = record.earlier, let earlierLock = record.earlierLock,
              Set(record.graph.keys) == ConnectionWorkspaceDisk.graphKeys else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        let pool = try ConnectionWorkspaceDisk.openDirectory(paths.earlier)
        defer { Darwin.close(pool) }
        let currentEarlier = try ConnectionWorkspaceDisk.identity(pool, directory: true, stable: true)
        let currentLock = try ConnectionWorkspaceDisk.namedIdentity(pool, "pool.lock", stable: true)
        guard earlier.sameExceptDevice(currentEarlier), earlierLock.sameExceptDevice(currentLock),
              try ConnectionWorkspaceDisk.read(pool, "pool.lock", maximum: 128) == ConnectionWorkspaceDisk.allocatorRefusal(activation),
              try ConnectionWorkspaceDisk.read(pool, ConnectionWorkspaceDisk.compatibilityFence, maximum: 128) == ConnectionWorkspaceDisk.fence(activation),
              Set(try DownloadDisk.names(pool, maximum: 2)) == ["pool.lock", ConnectionWorkspaceDisk.compatibilityFence] else {
            throw ConnectionWorkspaceFailure.changed
        }
        try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings)
        let currentGraph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true)
        guard record.graph.allSatisfy({ entry in
            currentGraph[entry.key].map { entry.value.sameExceptDevice($0) } == true
        }) else {
            throw ConnectionWorkspaceFailure.changed
        }
        let oldObjects = [earlier, earlierLock] + Array(record.graph.values)
        let currentObjects = [currentEarlier, currentLock] + Array(currentGraph.values)
        guard Set(oldObjects.map(\.device)).count == 1,
              Set(currentObjects.map(\.device)).count == 1,
              Set(currentObjects.compactMap(\.volume)).count == 1,
              currentObjects.allSatisfy({ $0.volume != nil }) else { throw ConnectionWorkspaceFailure.reviewRequired }
        let metadata = try ConnectionWorkspaceDisk.openDirectory(paths.metadata)
        defer { Darwin.close(metadata) }
        let bodies = try ConnectionWorkspaceDisk.openDirectory(paths.graph[2])
        defer { Darwin.close(bodies) }
        guard try SFTPSharedBudgetTransaction.readFence(metadata, name: SFTPSharedBudgetTransaction.metadataFence,
                                                        prefix: "MEXSHAREDMETA1") == budget,
              try SFTPSharedBudgetTransaction.readFence(bodies, name: SFTPSharedBudgetTransaction.bodyFence,
                                                        prefix: "MEXSHAREDBODY1") == budget else {
            throw ConnectionWorkspaceFailure.changed
        }
        var next = record
        next.format = 3; next.protocolIdentity = "traverse-persistent-connections-v3"
        next.revision += 1; next.earlier = currentEarlier; next.earlierLock = currentLock
        next.graph = currentGraph
        next.legacySourceDigest = Data(SHA256.hash(data: try record.encoded()))
        _ = try next.encoded()
        return next
    }

    /// Structural recognition of an interrupted single-record publication.
    /// Physical evidence is separately rechecked before explicit promotion.
    static func successor(_ old: ConnectionWorkspaceRecord, _ next: ConnectionWorkspaceRecord) throws -> Bool {
        guard old.format == 1, old.revision == 2, old.isActive, old.repair == nil,
              next.format == 3, next.protocolIdentity == "traverse-persistent-connections-v3",
              next.revision == old.revision + 1, next.phase == .active, next.repair == nil,
              next.activationID == old.activationID, next.budgetID == old.budgetID,
              next.locationDigest == old.locationDigest,
              next.legacySourceDigest == Data(SHA256.hash(data: try old.encoded())),
              let before = old.earlier, let after = next.earlier,
              let beforeLock = old.earlierLock, let afterLock = next.earlierLock,
              before.sameExceptDevice(after), beforeLock.sameExceptDevice(afterLock),
              Set(old.graph.keys) == Set(next.graph.keys),
              old.graph.allSatisfy({ entry in
                  next.graph[entry.key].map { entry.value.sameExceptDevice($0) } == true
              }) else {
            return false
        }
        let oldObjects = [before, beforeLock] + Array(old.graph.values)
        let newObjects = [after, afterLock] + Array(next.graph.values)
        return Set(oldObjects.map(\.device)).count == 1 &&
            Set(newObjects.map(\.device)).count == 1 &&
            Set(newObjects.compactMap(\.volume)).count == 1
    }
}

#if DEBUG
enum ConnectionWorkspaceRebindPoint: Sendable { case beforeRename }
final class ConnectionWorkspaceRebindQualification: @unchecked Sendable {
    static let shared = ConnectionWorkspaceRebindQualification()
    private let lock = NSLock()
    private var callback: (@Sendable (ConnectionWorkspaceRebindPoint) throws -> Void)?
    func set(_ value: (@Sendable (ConnectionWorkspaceRebindPoint) throws -> Void)?) {
        lock.withLock { callback = value }
    }
    func reach(_ point: ConnectionWorkspaceRebindPoint) throws {
        let held = lock.withLock { callback }; try held?(point)
    }
}
#endif
