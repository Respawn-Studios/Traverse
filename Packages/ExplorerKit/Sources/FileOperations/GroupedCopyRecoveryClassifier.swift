import Foundation

internal enum GroupedCopyRecoveryMemberState: String, Hashable, Sendable {
    case neverDeclared, neverStaged, sealedUnpublished
    case unconfirmedPublication, confirmedPublication, pendingReversal
    case unconfirmedReversal, confirmedUndone, protected
}

internal enum GroupedCopyRecoveryProtectionReason: String, Sendable {
    case unsealed, parent, group, marker, inventory, memberArea, slots, cleanup
}

internal struct GroupedCopyRecoveryMemberClassification: Sendable {
    let ordinal: Int
    let state: GroupedCopyRecoveryMemberState
    let protectionReason: GroupedCopyRecoveryProtectionReason?
}

internal struct GroupedCopyRecoveryClassification: Sendable {
    let jobState: GroupedCopyState
    let members: [GroupedCopyRecoveryMemberClassification]
    let confirmPublicationMembers: [Int]
    let confirmReversalMembers: [Int]
    let canFinishReview: Bool
    let canUndo: Bool
    let fullyAccounted: Bool
    let finishDisposition: GroupedCopyState?
}

/// Pure interpretation of durable facts and a separately captured inventory.
/// Classification neither reads files nor supplies authority to perform an action.
internal enum GroupedCopyRecoveryClassifier {
    static func classify(_ record: GroupedCopyRecord, observed: GroupedCopyFilesystemSnapshot) throws -> GroupedCopyRecoveryClassification {
        try validate(record, observed: observed)
        let cleanup = record.head.undoInvalidated || [.cleanupReview, .cleaned].contains(record.head.state)
        let members = classifyMembers(record, observed: observed, ordinals: Array(record.members.indices), permitsCleanupInspection: false)
        let accounted: Set<GroupedCopyRecoveryMemberState> = [.neverDeclared, .neverStaged,
            .sealedUnpublished, .confirmedPublication, .confirmedUndone]
        let fullyAccounted = !cleanup && members.allSatisfy { accounted.contains($0.state) }
        let disposition: GroupedCopyState?
        if fullyAccounted {
            let publications = members.filter { [.confirmedPublication, .confirmedUndone].contains($0.state) }
            if !publications.isEmpty && publications.allSatisfy({ $0.state == .confirmedUndone }) { disposition = .undone }
            else if members.allSatisfy({ $0.state == .confirmedPublication }) { disposition = .completed }
            else { disposition = .stoppedSettled }
        } else { disposition = nil }
        let pendingReverse = members.contains { $0.state == .pendingReversal }
        let undoState = [.completed, .stoppedSettled].contains(record.head.state)
            || ([.active, .needsReview].contains(record.head.state) && pendingReverse)
        let safeForUndo = members.allSatisfy { accounted.contains($0.state) || $0.state == .pendingReversal }
        return .init(jobState: record.head.state, members: members,
            confirmPublicationMembers: members.filter { $0.state == .unconfirmedPublication }.map(\.ordinal),
            confirmReversalMembers: members.filter { $0.state == .unconfirmedReversal }.map(\.ordinal),
            canFinishReview: fullyAccounted && [.preparing, .active, .needsReview].contains(record.head.state),
            canUndo: !cleanup && undoState && safeForUndo
                && members.contains { [.confirmedPublication, .pendingReversal].contains($0.state) },
            fullyAccounted: fullyAccounted, finishDisposition: disposition)
    }

    /// Inspect a still-retained group during cleanup using the actual record and
    /// inventory. This returns states only; job-wide action authority stays denied.
    static func classifyRetainedGroup(_ record: GroupedCopyRecord, observed: GroupedCopyFilesystemSnapshot,
                                     groupOrdinal: Int) throws -> [GroupedCopyRecoveryMemberClassification] {
        try validate(record, observed: observed)
        guard record.groups.indices.contains(groupOrdinal), record.groups[groupOrdinal].cleanup.phase == "none",
              record.head.state != .cleaned else { throw FileOperationFailure.recoveryUncertain }
        return classifyMembers(record, observed: observed, ordinals: record.groups[groupOrdinal].members,
            permitsCleanupInspection: true)
    }

    private static func validate(_ record: GroupedCopyRecord, observed: GroupedCopyFilesystemSnapshot) throws {
        try record.validate()
        guard observed.owner == record.head.owner, observed.job == record.head.id,
              observed.revision == record.head.revision,
              GroupedCopyRecord.isDigest(observed.inventoryDigest),
              observed.groups.map(\.ordinal) == record.groups.map(\.ordinal),
              observed.members.map(\.ordinal) == record.members.map(\.ordinal),
              zip(record.members, observed.members).allSatisfy({ member, observation in
                  member.progress.declaration == nil
                    ? observation.area == nil && observation.privateSlot == nil
                    : observation.area != nil && observation.privateSlot != nil
              }) else { throw FileOperationFailure.recoveryUncertain }

    }

    private static func classifyMembers(_ record: GroupedCopyRecord, observed: GroupedCopyFilesystemSnapshot,
                                       ordinals: [Int], permitsCleanupInspection: Bool) -> [GroupedCopyRecoveryMemberClassification] {
        let cleanup = record.head.undoInvalidated || [.cleanupReview, .cleaned].contains(record.head.state)
        let parentMatches: Bool
        if case .matched(let identity, let volume) = observed.destinationParent {
            let expected = record.members[0].manifest.destination
            parentMatches = identity.sameObject(as: expected.parentIdentity) && volume == expected.volume
        } else { parentMatches = false }
        let groupReasons = record.groups.map { group in
            groupProtection(group, record: record, observed: observed)
        }
        return ordinals.map { ordinal -> GroupedCopyRecoveryMemberClassification in
            let member = record.members[ordinal]
            let observation = observed.members[member.ordinal]
            func protected(_ reason: GroupedCopyRecoveryProtectionReason) -> GroupedCopyRecoveryMemberClassification {
                .init(ordinal: member.ordinal, state: .protected, protectionReason: reason)
            }
            guard !cleanup || permitsCleanupInspection else { return protected(.cleanup) }
            guard parentMatches else { return protected(.parent) }
            guard let declaration = member.progress.declaration else {
                // This tail has no staged/publication authority. A later fresh
                // continuation must independently revalidate its source/vacancy.
                return .init(ordinal: member.ordinal, state: .neverDeclared, protectionReason: nil)
            }
            if let reason = groupReasons[declaration.groupOrdinal] { return protected(reason) }
            let group = record.groups[declaration.groupOrdinal]
            if group.creationClosure == .neverCreated {
                guard isAbsent(observation.publicSlot) else { return protected(.slots) }
                return .init(ordinal: member.ordinal, state: .neverStaged, protectionReason: nil)
            }
            switch member.progress {
            case .notDeclared: return protected(.slots) // Refused by record validation.
            case .declared: return protected(.unsealed)
            case .neverStaged:
                guard case .absent? = observation.area, isAbsent(observation.privateSlot),
                      isAbsent(observation.publicSlot) else { return protected(.slots) }
                return .init(ordinal: member.ordinal, state: .neverStaged, protectionReason: nil)
            default: break
            }
            guard let seal = member.progress.seal,
                  case .present(let identity, let children)? = observation.area,
                  identity.sameObject(as: seal.areaIdentity) else { return protected(.memberArea) }
            let privateAbsent = isAbsent(observation.privateSlot)
            let publicAbsent = isAbsent(observation.publicSlot)
            guard let privateSlot = observation.privateSlot,
                  isObservable(privateSlot), isObservable(observation.publicSlot) else { return protected(.slots) }
            let expectedChildren = privateAbsent ? [] : [declaration.payloadName]
            guard children.count == expectedChildren.count, Set(children) == Set(expectedChildren) else { return protected(.inventory) }
            let privateMatches = matches(privateSlot, seal: seal)
            let publicMatches = matches(observation.publicSlot, seal: seal)
            let state: GroupedCopyRecoveryMemberState
            switch member.progress {
            case .sealed:
                if privateMatches && publicAbsent { state = .sealedUnpublished }
                else if privateAbsent && publicMatches && group.phase != .declared { state = .unconfirmedPublication }
                else { return protected(.slots) }
            case .published:
                guard privateAbsent && publicMatches else { return protected(.slots) }
                state = .confirmedPublication
            case .reverseIntent:
                if privateAbsent && publicMatches { state = .pendingReversal }
                else if privateMatches && publicAbsent { state = .unconfirmedReversal }
                else { return protected(.slots) }
            case .undone:
                guard privateMatches && publicAbsent else { return protected(.slots) }
                state = .confirmedUndone
            default: return protected(.slots)
            }
            return .init(ordinal: member.ordinal, state: state, protectionReason: nil)
        }
    }

    private static func groupProtection(_ group: GroupedCopyGroup, record: GroupedCopyRecord,
                                        observed: GroupedCopyFilesystemSnapshot) -> GroupedCopyRecoveryProtectionReason? {
        let observation = observed.groups[group.ordinal]
        guard group.cleanup.phase == "none" else { return .cleanup }
        if group.creationClosure == .neverCreated {
            guard case .absent = observation.area, observation.marker == .notInspected else { return .group }
            // The parent is observed absent. A simultaneously reported present
            // descendant is inconsistent, even with durable non-creation proof.
            for ordinal in group.members {
                guard isUnobservedArea(observed.members[ordinal].area),
                      isUnobservedSlot(observed.members[ordinal].privateSlot) else { return .inventory }
            }
            return nil
        }
        guard let expected = group.areaIdentity, case .present(let identity, let children) = observation.area,
              identity.sameObject(as: expected) else { return .group }
        guard observation.marker == .matched else { return .marker }
        var expectedChildren = [Data(GroupedCopyGroup.markerName.utf8)]
        for ordinal in group.members {
            if case .present? = observed.members[ordinal].area,
               let declaration = record.members[ordinal].progress.declaration {
                expectedChildren.append(Data(declaration.areaURL.lastPathComponent.utf8))
            }
        }
        guard children.count == expectedChildren.count, Set(children) == Set(expectedChildren) else { return .inventory }
        return nil
    }

    private static func isAbsent(_ slot: GroupedCopyObservedSlot?) -> Bool {
        if case .absent? = slot { return true }; return false
    }
    private static func isUnobservedArea(_ area: GroupedCopyObservedArea?) -> Bool {
        switch area { case .absent?, .unavailable?: true; default: false }
    }
    private static func isUnobservedSlot(_ slot: GroupedCopyObservedSlot?) -> Bool {
        switch slot { case .absent?, .unavailable?: true; default: false }
    }
    private static func isObservable(_ slot: GroupedCopyObservedSlot) -> Bool {
        if case .unavailable = slot { return false }; return true
    }
    private static func matches(_ slot: GroupedCopyObservedSlot, seal: GroupedCopySeal) -> Bool {
        guard case .verified(let tree, let identityDigest) = slot else { return false }
        return seal.proof.payload.matches(tree) && identityDigest == seal.proof.identityDigest
    }
}
