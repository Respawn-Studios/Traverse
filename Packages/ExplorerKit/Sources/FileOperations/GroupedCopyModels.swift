import Darwin
import Foundation

/// Literal UTF-8 spelling is authority; String/URL equality is not a namespace key.
internal struct GroupedCopySlot: Codable, Equatable, Sendable {
    let parent: URL
    let nameBytes: Data
    let parentIdentity: EntrySnapshot
    let volume: NativeRenameVolume
    var name: String { String(decoding: nameBytes, as: UTF8.self) }
    var url: URL { parent.appendingPathComponent(name) }
    func validate() throws {
        try OperationJournal.validateLocation(parent)
        try volume.validateRepresentation()
        guard parentIdentity.type == S_IFDIR, parentIdentity.device == volume.device,
              let name = String(data: nameBytes, encoding: .utf8), Data(name.utf8) == nameBytes,
              nameBytes.count <= Int(MAXNAMLEN) else { throw FileOperationFailure.recoveryUncertain }
        try validateName(name)
    }
}

internal struct GroupedCopyManifestMember: Codable, Sendable {
    let source: GroupedCopySlot
    let destination: GroupedCopySlot
    let sourceTree: VerifiedTree
}

internal struct GroupedCopyDeclaration: Codable, Equatable, Sendable {
    let groupOrdinal: Int
    let areaURL: URL
    let payloadName: Data
}

/// Constructed only after production receipt validation and synchronization. A cold
/// remnant scan cannot manufacture this evidence. The payload digest retains metadata.
/// A stored seal is also the exact publication intent for its immutable member slots.
internal struct GroupedCopySeal: Codable, Equatable, Sendable {
    let version: Int
    let metadataPolicy: TransferMetadataPolicy
    let receiptVersion: Int
    let areaIdentity: EntrySnapshot
    let proof: JournalStagingProof
}

internal enum GroupedCopyMemberProgress: Codable, Sendable {
    case notDeclared
    case declared(GroupedCopyDeclaration)
    case neverStaged(GroupedCopyDeclaration)
    case sealed(GroupedCopyDeclaration, GroupedCopySeal)
    case published(GroupedCopyDeclaration, GroupedCopySeal, VerifiedTree)
    case reverseIntent(GroupedCopyDeclaration, GroupedCopySeal, VerifiedTree, UUID)
    case undone(GroupedCopyDeclaration, GroupedCopySeal, VerifiedTree, UUID, VerifiedTree)

    var phase: String {
        switch self {
        case .notDeclared: "notDeclared"; case .declared: "declared"; case .neverStaged: "neverStaged"
        case .sealed: "sealed"; case .published: "published"; case .reverseIntent: "reverseIntent"; case .undone: "undone"
        }
    }
    var declaration: GroupedCopyDeclaration? {
        switch self {
        case .notDeclared: nil
        case .declared(let d), .neverStaged(let d), .sealed(let d, _), .published(let d, _, _),
             .reverseIntent(let d, _, _, _), .undone(let d, _, _, _, _): d
        }
    }
    var seal: GroupedCopySeal? {
        switch self {
        case .sealed(_, let s), .published(_, let s, _), .reverseIntent(_, let s, _, _), .undone(_, let s, _, _, _): s
        default: nil
        }
    }
    var publication: VerifiedTree? {
        switch self { case .published(_, _, let p), .reverseIntent(_, _, let p, _), .undone(_, _, let p, _, _): p; default: nil }
    }
}

internal struct GroupedCopyMember: Codable, Sendable {
    let owner: UUID
    let job: UUID
    let ordinal: Int
    let manifest: GroupedCopyManifestMember
    var progress: GroupedCopyMemberProgress
}

internal enum GroupedCopyGroupPhase: String, Codable, Sendable { case declared, sealed, settled }
internal enum GroupedCopyCreationClosure: String, Codable, Sendable { case neverCreated }

internal struct GroupedCopyCleanupIntent: Codable, Sendable {
    let id: UUID
    let before: VerifiedTree
    let parent: EntrySnapshot
}

internal enum GroupedCopyCleanup: Codable, Sendable {
    case none
    case intent(GroupedCopyCleanupIntent)
    case returned(GroupedCopyCleanupIntent, URL)
    case confirmed(GroupedCopyCleanupIntent, URL, VerifiedTree)
    var phase: String {
        switch self { case .none: "none"; case .intent: "intent"; case .returned: "returned"; case .confirmed: "confirmed" }
    }
}

internal struct GroupedCopyGroup: Codable, Sendable {
    let owner: UUID
    let job: UUID
    let ordinal: Int
    let members: [Int]
    let areaURL: URL
    let marker: Data
    var areaIdentity: EntrySnapshot?
    var phase: GroupedCopyGroupPhase
    var cleanup: GroupedCopyCleanup
    var creationClosure: GroupedCopyCreationClosure? = nil
    static let markerName = ".mac-explorer-group-v1"

    static func marker(owner: UUID, job: UUID, ordinal: Int) -> Data {
        Data("MacExplorer grouped Copy v1\n\(owner.uuidString)\n\(job.uuidString)\n\(ordinal)\n".utf8)
    }
}

internal enum GroupedCopyState: String, Codable, Sendable {
    case preparing, active, needsReview, completed, stoppedSettled, undone, cleanupReview, cleaned
    var isTerminal: Bool { [.completed, .stoppedSettled, .undone, .cleaned].contains(self) }
}

internal enum GroupedCopyReviewKind: String, Codable, Sendable { case publication, reversal, closure }
internal struct GroupedCopyReviewIntent: Codable, Sendable {
    let id: UUID
    let kind: GroupedCopyReviewKind
    let preparedRevision: Int
    let members: [Int]
    let inventoryDigest: String
}

internal struct GroupedCopyHead: Codable, Sendable {
    let protocolKind: OperationCatalogProtocol
    let protocolVersion: Int
    let owner: UUID
    let id: UUID
    let createdAt: Date
    let metadataPolicy: TransferMetadataPolicy
    let groupSize: Int
    let admittedCount: Int
    var groupCount: Int
    var revision: Int
    var state: GroupedCopyState
    var undoInvalidated: Bool
    var reviewIntent: GroupedCopyReviewIntent?
}

internal struct GroupedCopyRecord: Codable, Sendable {
    var head: GroupedCopyHead
    var groups: [GroupedCopyGroup]
    var members: [GroupedCopyMember]

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validateHead(_ h: GroupedCopyHead) throws {
        guard h.protocolKind == .groupedCopyV1, h.protocolVersion == 1, h.revision >= 0,
              h.revision < Int.max - 1, (1...16).contains(h.groupSize),
              (1...OperationJournal.maximumInputs).contains(h.admittedCount),
              h.groupCount >= 0, h.groupCount <= (h.admittedCount + h.groupSize - 1) / h.groupSize,
              h.createdAt.timeIntervalSinceReferenceDate.isFinite,
              ![.cleanupReview, .cleaned].contains(h.state) || h.undoInvalidated else { throw FileOperationFailure.recoveryUncertain }
        // Account for all member areas, group areas, source/public/private locations
        // and future native results against the existing whole-job ceilings.
        let groups = (h.admittedCount + h.groupSize - 1) / h.groupSize
        try OperationJournal.validateCapacity(steps: h.admittedCount * 2 + groups,
            areas: h.admittedCount + groups, locations: h.admittedCount * 4 + groups * 2, trashIntents: groups)
        if let review = h.reviewIntent {
            guard h.state == .needsReview, review.preparedRevision >= 0, review.preparedRevision <= h.revision,
                  review.members.count <= h.admittedCount, Set(review.members).count == review.members.count,
                  review.members.allSatisfy({ (0..<h.admittedCount).contains($0) }), isDigest(review.inventoryDigest),
                  review.kind == .closure ? review.members.isEmpty : !review.members.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        }
    }

    static func validateMember(_ m: GroupedCopyMember, head: GroupedCopyHead) throws {
        guard m.owner == head.owner, m.job == head.id, (0..<head.admittedCount).contains(m.ordinal) else { throw FileOperationFailure.recoveryUncertain }
        try m.manifest.source.validate(); try m.manifest.destination.validate()
        guard m.manifest.sourceTree.identity.type == S_IFREG,
              m.manifest.sourceTree.identity.device == m.manifest.source.parentIdentity.device,
              isDigest(m.manifest.sourceTree.digest) else { throw FileOperationFailure.recoveryUncertain }
        if let d = m.progress.declaration {
            try OperationJournal.validateLocation(d.areaURL)
            guard (0..<head.groupCount).contains(d.groupOrdinal), d.payloadName == Data("payload".utf8) else { throw FileOperationFailure.recoveryUncertain }
        }
        if let seal = m.progress.seal, let d = m.progress.declaration {
            guard seal.version == 1, seal.receiptVersion == 1, seal.metadataPolicy == head.metadataPolicy,
                  seal.areaIdentity.type == S_IFDIR, seal.areaIdentity.device == m.manifest.destination.parentIdentity.device,
                  seal.proof.nodeCount == 1, seal.proof.stepCount == 0, seal.proof.payload.identity.type == S_IFREG else { throw FileOperationFailure.recoveryUncertain }
            try seal.proof.validate(area: JournalArea(url: d.areaURL, identity: seal.areaIdentity), stepCount: 0)
            if let outcome = m.progress.publication, !seal.proof.payload.matches(outcome) { throw FileOperationFailure.recoveryUncertain }
            if case .undone(_, _, _, _, let outcome) = m.progress, !seal.proof.payload.matches(outcome) { throw FileOperationFailure.recoveryUncertain }
        }
    }

    func validate() throws {
        try Self.validateHead(head)
        guard members.count == head.admittedCount, groups.count == head.groupCount else { throw FileOperationFailure.recoveryUncertain }
        var sourceObjects = Set<String>(), sourceSlots = Set<Data>(), destinationSlots = Set<Data>(), privateSlots = Set<Data>()
        var occupiedNamespace = Set<Data>()
        var sourceNamespace = Set<Data>(), destinationNamespace = Set<Data>()
        var destinationNames = Set<String>()
        let destination = members[0].manifest.destination
        for (i, m) in members.enumerated() {
            guard m.ordinal == i else { throw FileOperationFailure.recoveryUncertain }
            try Self.validateMember(m, head: head)
            let source = m.manifest.source, target = m.manifest.destination, identity = m.manifest.sourceTree.identity
            guard OperationJournal.sameURLRepresentation(target.parent, destination.parent),
                  target.parentIdentity == destination.parentIdentity, target.volume == destination.volume,
                  sourceObjects.insert("\(identity.device):\(identity.inode)").inserted,
                  sourceSlots.insert(Self.slotKey(source)).inserted,
                  destinationSlots.insert(Self.slotKey(target)).inserted,
                  destinationNames.insert(target.name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw FileOperationFailure.recoveryUncertain }
            occupiedNamespace.insert(Self.namespaceKey(source)); occupiedNamespace.insert(Self.namespaceKey(target))
            sourceNamespace.insert(Self.namespaceKey(source)); destinationNamespace.insert(Self.namespaceKey(target))
            guard Self.namespaceKey(source) != Self.namespaceKey(target) else { throw FileOperationFailure.recoveryUncertain }
            if let d = m.progress.declaration {
                guard privateSlots.insert(Data(d.areaURL.absoluteString.utf8)).inserted else { throw FileOperationFailure.recoveryUncertain }
            }
        }
        guard sourceSlots.isDisjoint(with: destinationSlots), sourceNamespace.isDisjoint(with: destinationNamespace) else { throw FileOperationFailure.recoveryUncertain }
        var declared = Set<Int>(), areaURLs = Set<Data>()
        for (i, group) in groups.enumerated() {
            try validateGroup(at: i)
            let areaSlot = GroupedCopySlot(parent: destination.parent, nameBytes: Data(group.areaURL.lastPathComponent.utf8),
                parentIdentity: destination.parentIdentity, volume: destination.volume)
            guard areaURLs.insert(Self.namespaceKey(areaSlot)).inserted,
                  !occupiedNamespace.contains(Self.namespaceKey(areaSlot)) else { throw FileOperationFailure.recoveryUncertain }
            for ordinal in group.members {
                guard declared.insert(ordinal).inserted else { throw FileOperationFailure.recoveryUncertain }
            }
        }
        for m in members where !declared.contains(m.ordinal) {
            guard case .notDeclared = m.progress else { throw FileOperationFailure.recoveryUncertain }
        }
        if head.state == .preparing, !groups.isEmpty { throw FileOperationFailure.recoveryUncertain }
        if head.state == .cleaned {
            guard !groups.isEmpty, groups.allSatisfy({ $0.cleanup.phase == "confirmed" || $0.creationClosure == .neverCreated }) else { throw FileOperationFailure.recoveryUncertain }
        }
        if [.completed, .stoppedSettled, .undone].contains(head.state) {
            guard head.reviewIntent == nil, !head.undoInvalidated,
                  groups.allSatisfy({ $0.phase == .settled && $0.cleanup.phase == "none" }),
                  resolvedDisposition == head.state else { throw FileOperationFailure.recoveryUncertain }
        }
    }

    /// Bounded cross-row checks for one changed group; at most sixteen members.
    func validateGroup(at index: Int) throws {
        guard groups.indices.contains(index), !members.isEmpty, head.groupSize > 0,
              index * head.groupSize < members.count else { throw FileOperationFailure.recoveryUncertain }
        let group = groups[index], destination = members[0].manifest.destination
        guard group.owner == head.owner, group.job == head.id, group.ordinal == index,
              group.members == Array((index * head.groupSize)..<min((index + 1) * head.groupSize, members.count)),
              !group.members.isEmpty, group.members.count <= head.groupSize,
              group.marker == GroupedCopyGroup.marker(owner: head.owner, job: head.id, ordinal: index),
              OperationJournal.sameURLRepresentation(group.areaURL.deletingLastPathComponent(), destination.parent) else { throw FileOperationFailure.recoveryUncertain }
        try OperationJournal.validateLocation(group.areaURL)
        if let identity = group.areaIdentity {
            guard group.creationClosure == nil, identity.type == S_IFDIR, identity.device == destination.parentIdentity.device else { throw FileOperationFailure.recoveryUncertain }
        }
        if group.creationClosure != nil {
            guard group.areaIdentity == nil, group.phase == .settled, group.cleanup.phase == "none",
                  group.members.allSatisfy({ members[$0].progress.phase == "neverStaged" }) else { throw FileOperationFailure.recoveryUncertain }
        }
        var memberNames = Set<String>()
        for ordinal in group.members {
            guard let d = members[ordinal].progress.declaration, d.groupOrdinal == index,
                  OperationJournal.sameURLRepresentation(d.areaURL.deletingLastPathComponent(), group.areaURL),
                  memberNames.insert(d.areaURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  d.areaURL.lastPathComponent.lowercased() != GroupedCopyGroup.markerName else { throw FileOperationFailure.recoveryUncertain }
            if group.phase != .declared {
                guard group.areaIdentity != nil || group.creationClosure == .neverCreated,
                      members[ordinal].progress.phase != "declared" else { throw FileOperationFailure.recoveryUncertain }
            }
        }
        switch group.cleanup {
        case .none: break
        case .intent(let intent), .returned(let intent, _), .confirmed(let intent, _, _):
            guard head.undoInvalidated, [.cleanupReview, .cleaned].contains(head.state), group.phase == .settled,
                  let identity = group.areaIdentity, intent.before.identity.sameObject(as: identity),
                  intent.parent.sameObject(as: destination.parentIdentity), Self.isDigest(intent.before.digest) else { throw FileOperationFailure.recoveryUncertain }
            switch group.cleanup {
            case .returned(_, let url), .confirmed(_, let url, _): try OperationJournal.validateLocation(url)
            default: break
            }
            if case .confirmed(_, _, let after) = group.cleanup, !intent.before.matchesNativeTrashTransition(after) { throw FileOperationFailure.recoveryUncertain }
        }
    }

    /// Evidence-only reducer. Persisting this result requires the appropriate live or
    /// explicitly confirmed closure; inspection never closes a record by itself.
    var resolvedDisposition: GroupedCopyState? {
        guard head.reviewIntent == nil, members.allSatisfy({ !["declared", "reverseIntent"].contains($0.progress.phase) }) else { return nil }
        let publications = members.filter { $0.progress.publication != nil }
        if !publications.isEmpty, publications.allSatisfy({ $0.progress.phase == "undone" }) { return .undone }
        if members.allSatisfy({ $0.progress.phase == "published" }) { return .completed }
        return .stoppedSettled
    }

    static func slotKey(_ slot: GroupedCopySlot) -> Data {
        var data = Data("\(slot.parentIdentity.device):\(slot.parentIdentity.inode):".utf8)
        data.append(slot.nameBytes); return data
    }
    static func namespaceKey(_ slot: GroupedCopySlot) -> Data {
        var data = Data("\(slot.parentIdentity.device):\(slot.parentIdentity.inode):".utf8)
        data.append(Data(slot.name.precomposedStringWithCanonicalMapping.lowercased().utf8)); return data
    }
}
