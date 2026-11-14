import Foundation

// Catalog10 wraps the original complete head proof; native evidence and its
// equality remain unchanged. Sequence numbers are meaningful only in an epoch.
internal struct TextHeadReference10: Codable, Equatable, Sendable {
    let epoch: UUID
    let head: TextRevisionHeadV2
}
internal struct TextEpochStamp10: Codable, Equatable, Sendable {
    let epoch: UUID
    let generation: Int
}
internal struct TextEpochMemberSeal10: Codable, Equatable, Sendable {
    let id: UUID, revision: Int
    let prefix: RevisionDigest
    let state: LocalTextRevisionState
}
internal struct TextCheckpoint10: Codable, Equatable, Sendable {
    let id: UUID, owner: UUID, nextEpoch: UUID
    let slot: RevisionDigest
    let old: TextHeadReference10
    let oldGeneration: Int
    let maintenanceGeneration: Int
    let oldEpochDigest: RevisionDigest
    let observed: RevisionWitness
    let root: TextRevisionHeadV2
    let members: [TextEpochMemberSeal10]
    let edgesDigest: RevisionDigest
    let endedUndoCount: Int
    let baselineAdopted: Bool
    let createdAt: Date
    /// New stable slots may continue across a remount; old checkpoint rows
    /// omit this field and retain exact witness equality.
    let persistentVolume: UUID?
    func validate() throws {
        try observed.validate(); try old.head.witness.validate(); try root.witness.validate()
        if let persistentVolume {
            guard observed.volume == persistentVolume, old.head.witness.volume == persistentVolume else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        let sameHead = persistentVolume.map {
            old.head.witness.samePersistentObservation(observed, qualifiedVolume: $0)
        } ?? (observed == old.head.witness)
        guard old.epoch != nextEpoch, old.head.slot == slot, root.slot == slot,
              root.job == nil, root.sequence == 0, root.lineage != old.head.lineage,
              root.witness == observed, baselineAdopted == !sameHead,
              oldGeneration >= 0,maintenanceGeneration >= 0, (0...64).contains(members.count),
              Set(members.map(\.id)).count == members.count,
              (0...members.count).contains(endedUndoCount),
              members.allSatisfy({ (1...33).contains($0.revision) && [.committed,.undone,.notApplied].contains($0.state) }) else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}
internal struct TextEpoch10: Codable, Equatable, Sendable {
    let owner: UUID, id: UUID
    let slot: RevisionDigest
    let ordinal: Int
    let migratedFrom9: Bool
    let importedRecords: [UUID]
    let root: TextRevisionHeadV2
    let predecessor: TextCheckpoint10?
    var cut: TextCheckpoint10?
}
internal struct TextSlot10: Codable, Equatable, Sendable {
    let owner: UUID
    let slot: RevisionDigest
    var epoch: UUID, generation: Int, maintenance: Int
    var head: TextRevisionHeadV2
    var stamp: TextEpochStamp10 { .init(epoch: epoch, generation: generation) }
}
internal struct TextMember10: Codable, Equatable, Sendable {
    let id: UUID, epoch: UUID
    let slot: RevisionDigest
    let createdAt: Date
    var seal: TextEpochMemberSeal10?
    var checkpointID: UUID?
    var retirementGuard: UUID?
}
internal struct TextMutationGuard10: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case retirement, export }
    let id: UUID, job: UUID, epoch: UUID
    let slot: RevisionDigest
    let kind: Kind
    let ordinal: Int
    let sourceRevision: Int, sourcePrefix: RevisionDigest
    let admittedStamp: TextEpochStamp10
    let maintenanceGeneration: Int
    var outcome: RevisionDigest
    var closed: Bool
    var remainingAbortedBeforeNative: Bool = false
}
internal struct TextPlanning10: Sendable {
    let head: TextRevisionHeadV2?
    let settlements: [TextPreparationSettlementV3]
    let stamp: TextEpochStamp10?
    let maintenance: Int
    let records: Int, edges: Int
    let storeRefusal: LocalTextCapacityReason?
}
internal enum TextCheckpointMutationUncertain10:Error {case enteredTransaction}

public enum LocalTextCapacityReason: String, Sendable, Codable, Error {
    case checkpointRequired, unfinishedPreparation, unknownNativePrefix, pendingMaintenance
    case sourceChanged, storeCapacity, upgradeRequired, metadataUnavailable, stalePlan, nothingToCheckpoint
    case legacyHistoryRequiresReview
}
public struct LocalTextCapacityInspection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let epochID: UUID?, generation: Int
    public let activeRecords: Int, activeEdges: Int
    public let recordLimit: Int, edgeLimit: Int
    public let canSave: Bool, canCheckpoint: Bool
    public let saveRefusal: LocalTextCapacityReason?, checkpointRefusal: LocalTextCapacityReason?
    public let canSaveAdoptingExternalBaseline: Bool
    public let baselineSaveRefusal: LocalTextCapacityReason?
    public var description: String { "Local text capacity (private evidence omitted)" }
    public var debugDescription: String { description }
}
public enum LocalTextUndoDisposition: Sendable, Equatable {
    case available, unavailable, endedByRetirement, epochCapacityReached
    case endedByCheckpoint(checkpointID: UUID)
}
public struct LocalTextCheckpointReview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let checkpointID: UUID, epochID: UUID
    public let retainedRecords: Int, endedUndoCount: Int
    public let adoptsExternalBaseline: Bool
    public var description: String { "Local text checkpoint review (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextCheckpointPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let review: LocalTextCheckpointReview
    internal let engine: UUID, token: LocalTextReadToken
    internal let slot: RevisionDigest
    internal let manifestVersion: Int
    internal let stamp: TextEpochStamp10, maintenance: Int
    internal let memberPrefixes: [TextEpochMemberSeal10]
    internal let claim: TextPlanClaimV2
    public var description: String { "Local text checkpoint plan (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextCheckpointReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let checkpointID: UUID, previousEpochID: UUID, epochID: UUID
    public let endedUndoCount: Int, retainedRecords: Int
    public let baselineAdopted: Bool
    public var description: String { "Local text checkpoint receipt (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextCheckpointInspection: Sendable {
    public let receipt: LocalTextCheckpointReceipt
    public let metadataIsDurable: Bool
}
public enum LocalTextCheckpointResult: Sendable {
    case completed(LocalTextCheckpointReceipt)
    case refused(LocalTextCapacityReason)
    case uncertain(checkpointID: UUID)
}
