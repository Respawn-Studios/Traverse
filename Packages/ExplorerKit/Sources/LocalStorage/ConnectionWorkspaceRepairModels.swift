import CryptoKit
import Foundation

@_spi(Qualification) public enum ConnectionWorkspaceRepairAction: Sendable, Equatable { case repair, resume }

/// An explicit selection, not a URL, caller boolean or retained lock.
@_spi(Qualification) public final class ConnectionWorkspaceRepairChoice: Sendable, CustomDebugStringConvertible {
    public let action: ConnectionWorkspaceRepairAction
    let paths: ConnectionWorkspacePaths
    let location: RemoteSettingsReadIdentity
    let current: Data, pending: Data?
    let observation: ConnectionWorkspaceRepairObservation
    let parents: [String: ConnectionWorkspaceIdentity]
    init(action: ConnectionWorkspaceRepairAction, paths: ConnectionWorkspacePaths, location: RemoteSettingsReadIdentity,
         current: Data, pending: Data?, observation: ConnectionWorkspaceRepairObservation, parents: [String: ConnectionWorkspaceIdentity]) {
        self.action = action; self.paths = paths; self.location = location
        self.current = current; self.pending = pending; self.observation = observation; self.parents = parents
    }
    public var debugDescription: String { "<opaque explicit connection storage repair choice>" }
}

enum ConnectionWorkspaceRepairStage: Int, Codable, Sendable, CaseIterable {
    case intent, parentsReady, stageRecorded, allocatorFenced, markerRecorded, fullyFenced, published, complete
}
struct ConnectionWorkspaceRepairRecord: Codable, Sendable, Equatable {
    var id: UUID
    var stage = ConnectionWorkspaceRepairStage.intent
    var sourceDigest: Data
    var sourceRevision: UInt64
    var priorEarlier: ConnectionWorkspaceIdentity, priorLock: ConnectionWorkspaceIdentity
    var parentCount: Int
    var parentBefore: [String: ConnectionWorkspaceIdentity]
    var parents: [String: ConnectionWorkspaceIdentity] = [:]
    var root: ConnectionWorkspaceIdentity?, lock: ConnectionWorkspaceIdentity?, marker: ConnectionWorkspaceIdentity?
    var stageName: String { ".traverse-connection-repair-" + id.uuidString }
    func validate(record: ConnectionWorkspaceRecord) throws {
        guard (1...3).contains(parentCount) else { throw ConnectionWorkspaceFailure.reviewRequired }
        let keys = Set((0..<parentCount).map(String.init) + ["-1"])
        guard SFTPWire.validToken(id), sourceDigest.count == 32, sourceRevision >= 2,
              sourceRevision < UInt64.max - 8, (1...3).contains(parentCount),
              Set(parentBefore.keys).isSubset(of: keys), parentBefore["-1"] != nil,
              stage == .intent ? parents.isEmpty : Set(parents.keys) == keys,
              stage.rawValue < ConnectionWorkspaceRepairStage.stageRecorded.rawValue ? root == nil && lock == nil : root != nil && lock != nil,
              stage.rawValue < ConnectionWorkspaceRepairStage.markerRecorded.rawValue ? marker == nil : marker != nil,
              record.revision == sourceRevision + UInt64(stage.rawValue) + 1,
              record.phase == (stage == .complete ? .active : .repairing),
              stage == .complete ? record.earlier == root && record.earlierLock == lock : record.earlier == priorEarlier && record.earlierLock == priorLock
        else { throw ConnectionWorkspaceFailure.reviewRequired }
    }
    static func successor(_ old: ConnectionWorkspaceRecord, _ next: ConnectionWorkspaceRecord) throws -> Bool {
        guard next.format == (old.format == 3 ? 3 : 2), next.revision == old.revision + 1,
              old.activationID == next.activationID, old.budgetID == next.budgetID,
              old.locationDigest == next.locationDigest, old.graph == next.graph,
              old.legacySourceDigest == next.legacySourceDigest,
              let after = next.repair else { return false }
        if old.isActive {
            let sourceDigest = Data(SHA256.hash(data: try old.encoded()))
            return after.stage == .intent && after.sourceRevision == old.revision && after.sourceDigest == sourceDigest
                && after.priorEarlier == old.earlier && after.priorLock == old.earlierLock
                && next.earlier == old.earlier && next.earlierLock == old.earlierLock
        }
        guard (old.format == 2 || old.format == 3), old.phase == .repairing, var before = old.repair,
              after.stage.rawValue == before.stage.rawValue + 1 else { return false }
        before.stage = after.stage
        if after.stage == .parentsReady { before.parents = after.parents }
        if after.stage == .stageRecorded { before.root = after.root; before.lock = after.lock }
        if after.stage == .markerRecorded { before.marker = after.marker }
        return before == after && (after.stage == .complete
            ? next.earlier == after.root && next.earlierLock == after.lock
            : next.earlier == old.earlier && next.earlierLock == old.earlierLock)
    }
}
struct ConnectionWorkspaceRepairObservation: Sendable, Equatable {
    let ledger: RemoteSettingsReadIdentity, editors: RemoteSettingsReadIdentity, journal: RemoteSettingsReadIdentity
    let stamps: [String: ConnectionWorkspaceStamp]
}

#if DEBUG
enum ConnectionWorkspaceRepairPoint: String, Sendable, CaseIterable {
    case intentRecorded, parentsRecorded, stageRecorded, allocatorWritten, allocatorRecorded
    case markerRecorded, markerWritten, fullyFencedRecorded, published, publicationRecorded, activeRecorded
    case graphHeld, beforePublication
    case locationPendingWritten, locationPendingSynced, locationBeforeRename, locationRenamed, locationDirectorySynced
}
final class ConnectionWorkspaceRepairQualification: @unchecked Sendable {
    static let shared = ConnectionWorkspaceRepairQualification()
    private let lock = NSLock()
    private var callback: (@Sendable (ConnectionWorkspaceRepairPoint) throws -> Void)?
    func set(_ value: (@Sendable (ConnectionWorkspaceRepairPoint) throws -> Void)?) { lock.withLock { callback = value } }
    func reach(_ point: ConnectionWorkspaceRepairPoint) throws { let held = lock.withLock { callback }; try held?(point) }
}
#endif
