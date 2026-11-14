import Foundation

/// Store-owned incremental authority. Callers cannot mutate the snapshot or supply
/// dirty hints. A failed save retires this session until a checked cold reopen.
internal final class GroupedCopyEditSession {
    private var value: GroupedCopyRecord
    private let liveForward: Bool
    private var liveReverseMembers = Set<Int>()
    private var liveReviewID: UUID?
    private(set) var changedGroups: Set<Int>
    private(set) var changedMembers: Set<Int>
    private(set) var valid = true
    var snapshot: GroupedCopyRecord { value }
    var id: UUID { value.head.id }
    var revision: Int { value.head.revision }

    init(_ record: GroupedCopyRecord, new: Bool) {
        value = record
        liveForward = new
        changedGroups = new ? Set(record.groups.indices) : []
        changedMembers = new ? Set(record.members.indices) : []
    }

    private func requireLive() throws {
        guard valid else { throw FileOperationFailure.recoveryUncertain }
    }
    private func requireForward() throws {
        try requireLive()
        guard liveForward, [.preparing, .active].contains(value.head.state), !value.head.undoInvalidated,
              value.head.reviewIntent == nil else { throw FileOperationFailure.recoveryUncertain }
    }

    func declareGroup(areaURL: URL, memberAreaURLs: [URL]) throws {
        try requireForward()
        let ordinal = value.groups.count, start = ordinal * value.head.groupSize
        guard start < value.members.count, value.groups.last.map({ $0.phase == .settled }) ?? true else { throw FileOperationFailure.recoveryUncertain }
        let indices = Array(start..<min(start + value.head.groupSize, value.members.count))
        guard memberAreaURLs.count == indices.count,
              Set(memberAreaURLs.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }).count == indices.count,
              memberAreaURLs.allSatisfy({ $0.lastPathComponent.lowercased() != GroupedCopyGroup.markerName }),
              !value.groups.contains(where: { $0.areaURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == areaURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }),
              OperationJournal.sameURLRepresentation(areaURL.deletingLastPathComponent(), value.members[0].manifest.destination.parent),
              memberAreaURLs.allSatisfy({ OperationJournal.sameURLRepresentation($0.deletingLastPathComponent(), areaURL) }) else { throw FileOperationFailure.recoveryUncertain }
        try OperationJournal.validateLocation(areaURL)
        for url in memberAreaURLs { try OperationJournal.validateLocation(url) }
        let destination = value.members[0].manifest.destination
        let areaSlot = GroupedCopySlot(parent: destination.parent, nameBytes: Data(areaURL.lastPathComponent.utf8),
            parentIdentity: destination.parentIdentity, volume: destination.volume)
        let key = GroupedCopyRecord.namespaceKey(areaSlot)
        guard !value.members.contains(where: { GroupedCopyRecord.namespaceKey($0.manifest.source) == key || GroupedCopyRecord.namespaceKey($0.manifest.destination) == key }) else { throw FileOperationFailure.recoveryUncertain }
        let group = GroupedCopyGroup(owner: value.head.owner, job: id, ordinal: ordinal, members: indices,
            areaURL: areaURL, marker: GroupedCopyGroup.marker(owner: value.head.owner, job: id, ordinal: ordinal),
            areaIdentity: nil, phase: .declared, cleanup: .none)
        value.groups.append(group); value.head.groupCount += 1; value.head.state = .active
        changedGroups.insert(ordinal)
        for (offset, index) in indices.enumerated() {
            value.members[index].progress = .declared(GroupedCopyDeclaration(groupOrdinal: ordinal,
                areaURL: memberAreaURLs[offset], payloadName: Data("payload".utf8)))
            changedMembers.insert(index)
        }
    }

    func recordGroupIdentity(_ identity: EntrySnapshot, at ordinal: Int) throws {
        try requireForward()
        guard value.groups.indices.contains(ordinal), value.groups[ordinal].phase == .declared,
              value.groups[ordinal].areaIdentity == nil,
              identity.type == value.members[0].manifest.destination.parentIdentity.type,
              identity.device == value.members[0].manifest.destination.parentIdentity.device else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].areaIdentity = identity; changedGroups.insert(ordinal)
    }

    func recordSeal(_ seal: GroupedCopySeal, member ordinal: Int) throws {
        try requireForward()
        guard value.members.indices.contains(ordinal), case .declared(let d) = value.members[ordinal].progress,
              value.groups[d.groupOrdinal].areaIdentity != nil else { throw FileOperationFailure.recoveryUncertain }
        var candidate = value.members[ordinal]; candidate.progress = .sealed(d, seal)
        try GroupedCopyRecord.validateMember(candidate, head: value.head)
        value.members[ordinal] = candidate; changedMembers.insert(ordinal)
    }

    /// Only the executing worker's positive knowledge may call this. Cold inspection
    /// has no transition that converts an absent declared slot into never-staged.
    func recordNeverStaged(member ordinal: Int) throws {
        try requireForward()
        guard value.members.indices.contains(ordinal), case .declared(let d) = value.members[ordinal].progress else { throw FileOperationFailure.recoveryUncertain }
        value.members[ordinal].progress = .neverStaged(d); changedMembers.insert(ordinal)
    }

    /// Positive live-worker closure before mkdir. Missing areas after cold reopen
    /// cannot call this or acquire the equivalent closure through inspection.
    func recordGroupNeverCreated(_ ordinal: Int) throws {
        try requireForward()
        guard value.groups.indices.contains(ordinal), value.groups[ordinal].phase == .declared,
              value.groups[ordinal].areaIdentity == nil,
              value.groups[ordinal].members.allSatisfy({ value.members[$0].progress.phase == "neverStaged" }) else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].creationClosure = .neverCreated
        value.groups[ordinal].phase = .settled; changedGroups.insert(ordinal)
    }

    func sealGroup(_ ordinal: Int) throws {
        try requireForward()
        guard value.groups.indices.contains(ordinal), value.groups[ordinal].phase == .declared,
              value.groups[ordinal].areaIdentity != nil,
              value.groups[ordinal].members.allSatisfy({ ["sealed", "neverStaged"].contains(value.members[$0].progress.phase) }) else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].phase = .sealed; changedGroups.insert(ordinal)
    }

    func recordPublication(_ outcome: VerifiedTree, member ordinal: Int) throws {
        try requireLive()
        guard !value.head.undoInvalidated, value.members.indices.contains(ordinal),
              case .sealed(let d, let seal) = value.members[ordinal].progress,
              value.groups[d.groupOrdinal].phase != .declared,
              seal.proof.payload.matches(outcome),
              (liveForward && value.head.state == .active) ||
                (liveReviewID != nil && liveReviewID == value.head.reviewIntent?.id && value.head.reviewIntent?.kind == .publication && value.head.reviewIntent!.members.contains(ordinal)) else { throw FileOperationFailure.recoveryUncertain }
        value.members[ordinal].progress = .published(d, seal, outcome); changedMembers.insert(ordinal)
    }

    func settleGroup(_ ordinal: Int) throws {
        try requireLive()
        guard liveForward || (liveReviewID != nil && liveReviewID == value.head.reviewIntent?.id),
              value.groups.indices.contains(ordinal), value.groups[ordinal].phase == .sealed,
              value.groups[ordinal].members.allSatisfy({ ["sealed", "neverStaged", "published", "undone"].contains(value.members[$0].progress.phase) }) else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].phase = .settled; changedGroups.insert(ordinal)
    }

    func markNeedsReview() throws {
        try requireLive(); value.head.state = value.head.undoInvalidated ? .cleanupReview : .needsReview
    }

    func beginReview(_ intent: GroupedCopyReviewIntent) throws {
        try requireLive()
        guard !value.head.undoInvalidated, intent.preparedRevision == revision,
              liveReviewID == nil, value.head.reviewIntent?.id != intent.id else { throw FileOperationFailure.recoveryUncertain }
        var head = value.head; head.state = .needsReview; head.reviewIntent = intent
        try GroupedCopyRecord.validateHead(head)
        for ordinal in intent.members {
            let phase = value.members[ordinal].progress.phase
            guard (intent.kind == .publication && phase == "sealed") || (intent.kind == .reversal && phase == "reverseIntent") else { throw FileOperationFailure.recoveryUncertain }
        }
        value.head = head; liveReviewID = intent.id
    }

    func finishReview(_ id: UUID) throws {
        try requireLive()
        guard liveReviewID == id, let intent = value.head.reviewIntent, intent.id == id,
              intent.members.allSatisfy({ value.members[$0].progress.phase == (intent.kind == .publication ? "published" : "undone") }) else { throw FileOperationFailure.recoveryUncertain }
        value.head.reviewIntent = nil; liveReviewID = nil
        // Recovery closure can settle already complete durable evidence; it cannot
        // create a seal, member outcome, or never-staged fact from observations.
        for index in value.groups.indices where value.groups[index].phase != .settled {
            if value.groups[index].areaIdentity != nil,
               value.groups[index].members.allSatisfy({ ["sealed", "neverStaged", "published", "undone"].contains(value.members[$0].progress.phase) }) {
                value.groups[index].phase = .settled; changedGroups.insert(index)
            }
        }
        // The caller commits this with outcomes/closure. Any unresolved member keeps review.
        if value.groups.allSatisfy({ $0.phase == .settled }), let terminal = value.resolvedDisposition { value.head.state = terminal }
        else { value.head.state = .needsReview }
    }

    func beginReverse(member ordinal: Int, intent: UUID) throws {
        try requireLive()
        guard !value.head.undoInvalidated, value.head.reviewIntent == nil,
              ([.completed, .stoppedSettled].contains(value.head.state) || (value.head.state == .active && !liveReverseMembers.isEmpty)),
              !value.members.contains(where: { $0.progress.phase == "reverseIntent" }),
              value.members.indices.contains(ordinal), case .published(let d, let s, let p) = value.members[ordinal].progress else { throw FileOperationFailure.recoveryUncertain }
        value.members[ordinal].progress = .reverseIntent(d, s, p, intent)
        liveReverseMembers.insert(ordinal)
        value.head.state = .active; changedMembers.insert(ordinal)
    }

    /// A fresh explicit Undo retry replaces only the interrupted reverse intent.
    /// Its caller must classify and revalidate the entire selected job first.
    func beginReverseRetry(member ordinal: Int, priorIntent: UUID, intent: UUID,
                           preparedRevision: Int, priorReviewID: UUID?) throws {
        try requireLive()
        guard !value.head.undoInvalidated, preparedRevision == revision,
              [.active, .needsReview].contains(value.head.state),
              liveReviewID == nil, priorReviewID == value.head.reviewIntent?.id,
              intent != priorIntent, value.members.indices.contains(ordinal),
              !value.members.contains(where: { $0.ordinal != ordinal && $0.progress.phase == "reverseIntent" }),
              case .reverseIntent(let declaration, let seal, let publication, let existing) = value.members[ordinal].progress,
              existing == priorIntent else { throw FileOperationFailure.recoveryUncertain }
        value.members[ordinal].progress = .reverseIntent(declaration, seal, publication, intent)
        value.head.reviewIntent = nil
        value.head.state = .active
        liveReverseMembers.insert(ordinal)
        changedMembers.insert(ordinal)
    }

    func recordReversal(_ outcome: VerifiedTree, member ordinal: Int) throws {
        try requireLive()
        guard !value.head.undoInvalidated, value.members.indices.contains(ordinal),
              case .reverseIntent(let d, let s, let p, let intent) = value.members[ordinal].progress,
              s.proof.payload.matches(outcome), (value.head.state == .active && liveReverseMembers.contains(ordinal)) ||
                (liveReviewID != nil && liveReviewID == value.head.reviewIntent?.id && value.head.reviewIntent?.kind == .reversal && value.head.reviewIntent!.members.contains(ordinal)) else { throw FileOperationFailure.recoveryUncertain }
        value.members[ordinal].progress = .undone(d, s, p, intent, outcome); changedMembers.insert(ordinal)
    }

    func close() throws {
        try requireLive()
        guard liveForward || !liveReverseMembers.isEmpty,
              !value.head.undoInvalidated, value.head.reviewIntent == nil,
              [.preparing, .active].contains(value.head.state),
              value.groups.allSatisfy({ $0.phase == .settled }), let state = value.resolvedDisposition else { throw FileOperationFailure.recoveryUncertain }
        value.head.state = state
    }

    func beginCleanup() throws {
        try requireLive()
        guard [.completed, .stoppedSettled, .undone].contains(value.head.state), !value.head.undoInvalidated,
              value.head.reviewIntent == nil, value.groups.contains(where: { $0.areaIdentity != nil }) else { throw FileOperationFailure.recoveryUncertain }
        value.head.undoInvalidated = true; value.head.state = .cleanupReview
    }

    func recordCleanupIntent(_ intent: GroupedCopyCleanupIntent, group ordinal: Int) throws {
        try requireLive()
        guard value.head.state == .cleanupReview, value.head.undoInvalidated, value.groups.indices.contains(ordinal),
              value.groups[ordinal].cleanup.phase == "none", let identity = value.groups[ordinal].areaIdentity,
              intent.before.identity.sameObject(as: identity), GroupedCopyRecord.isDigest(intent.before.digest),
              intent.parent.sameObject(as: value.members[0].manifest.destination.parentIdentity) else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].cleanup = .intent(intent); changedGroups.insert(ordinal)
    }

    func recordCleanupReturn(_ url: URL, group ordinal: Int) throws {
        try requireLive(); try OperationJournal.validateLocation(url)
        guard value.head.state == .cleanupReview, value.groups.indices.contains(ordinal),
              case .intent(let intent) = value.groups[ordinal].cleanup else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].cleanup = .returned(intent, url); changedGroups.insert(ordinal)
    }

    func recordCleanupOutcome(_ outcome: VerifiedTree, group ordinal: Int) throws {
        try requireLive()
        guard value.head.state == .cleanupReview, value.groups.indices.contains(ordinal),
              case .returned(let intent, let url) = value.groups[ordinal].cleanup,
              intent.before.matchesNativeTrashTransition(outcome) else { throw FileOperationFailure.recoveryUncertain }
        value.groups[ordinal].cleanup = .confirmed(intent, url, outcome); changedGroups.insert(ordinal)
    }

    func closeCleanup() throws {
        try requireLive()
        guard value.head.state == .cleanupReview, !value.groups.isEmpty,
              value.groups.allSatisfy({ $0.cleanup.phase == "confirmed" || $0.creationClosure == .neverCreated }) else { throw FileOperationFailure.recoveryUncertain }
        value.head.state = .cleaned
    }

    func invalidate() { valid = false }
    func didCommit() {
        value.head.revision += 1; changedGroups = []; changedMembers = []
    }
}
