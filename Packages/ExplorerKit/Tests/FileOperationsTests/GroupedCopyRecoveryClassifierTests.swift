import Darwin
import Foundation
@testable import FileOperations
import Testing

/// Pure classifier inputs intentionally model independent observations. Real
/// generated objects provide identities/proofs; fixture seals are not execution
/// qualification, and synthetic placement tables never mutate those objects.
private struct GroupedClassifierFixture {
    let root: URL
    let source: URL
    let destination: URL
    let record: GroupedCopyRecord
    let seals: [GroupedCopySeal]
    private let marker: Data

    init(count: Int = 3) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-classifier-" + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        marker = Data(("MacExplorer generated classifier fixture v1:" + UUID().uuidString).utf8)
        for url in [root, source, destination] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try marker.write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        let from = try DirectoryAnchor(source, resolve: false), to = try DirectoryAnchor(destination, resolve: false)
        let fromVolume = try #require(try NativeRenameVolume.qualified(in: from))
        let toVolume = try #require(try NativeRenameVolume.qualified(in: to))
        let manifests = try (0..<count).map { ordinal -> GroupedCopyManifestMember in
            let name = "input-\(ordinal)"
            let input = from.url.appendingPathComponent(name)
            try Data("generated classifier input \(ordinal)".utf8).write(to: input, options: .withoutOverwriting)
            return GroupedCopyManifestMember(
                source: .init(parent: from.url, nameBytes: Data(name.utf8), parentIdentity: from.identity, volume: fromVolume),
                destination: .init(parent: to.url, nameBytes: Data(name.utf8), parentIdentity: to.identity, volume: toVolume),
                sourceTree: try verifiedTree(input, cancellation: OperationCancellation()))
        }
        let journal = try OperationJournal(root.appendingPathComponent("journal", isDirectory: true))
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: manifests)
        var generatedSeals: [GroupedCopySeal] = []
        for start in stride(from: 0, to: count, by: 16) {
            let group = destination.appendingPathComponent("owned-group-\(start / 16)", isDirectory: true)
            let indices = Array(start..<min(start + 16, count))
            let areas = indices.map { group.appendingPathComponent("area-\($0)", isDirectory: true) }
            try edit.declareGroup(areaURL: group, memberAreaURLs: areas)
            try FileManager().createDirectory(at: group, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let groupAnchor = try DirectoryAnchor(group, resolve: false)
            try OperationJournal.writeExclusive(edit.snapshot.groups.last!.marker,
                name: GroupedCopyGroup.markerName, anchor: groupAnchor)
            try edit.recordGroupIdentity(groupAnchor.identity, at: start / 16)
            for (ordinal, area) in zip(indices, areas) {
                try FileManager().createDirectory(at: area, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let anchor = try DirectoryAnchor(area, resolve: false)
                try OperationJournal.writeExclusive(Data("generated classifier input \(ordinal)".utf8), name: "payload", anchor: anchor)
                let tree = try verifiedTree(parent: anchor.fd, name: "payload", cancellation: OperationCancellation())
                let receipts = StagingCopyReceipts(); try receipts.completed("", tree.identity)
                let proof = try receipts.proof(parent: anchor.fd, payload: tree, stepCount: 0, cancellation: OperationCancellation())
                let seal = GroupedCopySeal(version: 1, metadataPolicy: .strict, receiptVersion: 1, areaIdentity: anchor.identity, proof: proof)
                try edit.recordSeal(seal, member: ordinal); generatedSeals.append(seal)
            }
            try edit.sealGroup(start / 16); try edit.settleGroup(start / 16)
        }
        var snapshot = edit.snapshot; snapshot.head.state = .needsReview
        try snapshot.validate()
        record = snapshot; seals = generatedSeals
    }

    func remove() {
        guard root.resolvingSymlinksInPath().path == root.path,
              (try? Data(contentsOf: root.appendingPathComponent(".fixture-owner"))) == marker else { return }
        try? FileManager().removeItem(at: root)
    }

    enum Placement: Sendable { case retained, published, both, neither, foreignPublic, unavailable, wrongDigest, wrongIdentityDigest }

    func observed(_ record: GroupedCopyRecord, placements: [Int: Placement] = [:]) -> GroupedCopyFilesystemSnapshot {
        let members = record.members.map { member -> GroupedCopyMemberObservation in
            guard let declaration = member.progress.declaration else {
                return .init(ordinal: member.ordinal, area: nil, privateSlot: nil, publicSlot: .absent)
            }
            let seal = seals[member.ordinal]
            let verified = GroupedCopyObservedSlot.verified(seal.proof.payload, identityDigest: seal.proof.identityDigest)
            let privateSlot: GroupedCopyObservedSlot, publicSlot: GroupedCopyObservedSlot
            switch placements[member.ordinal] ?? .retained {
            case .retained: privateSlot = verified; publicSlot = .absent
            case .published: privateSlot = .absent; publicSlot = verified
            case .both: privateSlot = verified; publicSlot = verified
            case .neither: privateSlot = .absent; publicSlot = .absent
            case .foreignPublic: privateSlot = .absent; publicSlot = .occupied(seal.proof.payload.identity)
            case .unavailable: privateSlot = .unavailable(.denied); publicSlot = .unavailable(.denied)
            case .wrongDigest:
                privateSlot = .absent
                publicSlot = .verified(.init(identity: seal.proof.payload.identity, digest: String(repeating: "b", count: 64), nativeTrashDigest: nil),
                    identityDigest: seal.proof.identityDigest)
            case .wrongIdentityDigest:
                privateSlot = .absent; publicSlot = .verified(seal.proof.payload, identityDigest: String(repeating: "c", count: 64))
            }
            let children: [Data]
            if case .absent = privateSlot { children = [] } else { children = [declaration.payloadName] }
            return .init(ordinal: member.ordinal, area: .present(seal.areaIdentity, children: children),
                privateSlot: privateSlot, publicSlot: publicSlot)
        }
        let groups = record.groups.map { group in
            GroupedCopyGroupObservation(ordinal: group.ordinal, area: .present(group.areaIdentity!,
                children: [Data(GroupedCopyGroup.markerName.utf8)] + group.members.map {
                    Data(record.members[$0].progress.declaration!.areaURL.lastPathComponent.utf8)
                }), marker: .matched)
        }
        let target = record.members[0].manifest.destination
        return .init(owner: record.head.owner, job: record.head.id, revision: record.head.revision,
            destinationParent: .matched(target.parentIdentity, target.volume), groups: groups,
            members: members, inventoryDigest: String(repeating: "a", count: 64))
    }

    func published(_ record: GroupedCopyRecord, member: Int) -> GroupedCopyRecord {
        var changed = record
        let declaration = record.members[member].progress.declaration!
        let seal = seals[member]
        changed.members[member].progress = .published(declaration, seal, seal.proof.payload)
        return changed
    }

    func reverseIntent(_ record: GroupedCopyRecord, member: Int) -> GroupedCopyRecord {
        var changed = record
        let declaration = record.members[member].progress.declaration!, seal = seals[member]
        changed.members[member].progress = .reverseIntent(declaration, seal, seal.proof.payload, UUID())
        return changed
    }

    func undone(_ record: GroupedCopyRecord, member: Int) -> GroupedCopyRecord {
        var changed = record
        let declaration = record.members[member].progress.declaration!, seal = seals[member]
        changed.members[member].progress = .undone(declaration, seal, seal.proof.payload, UUID(), seal.proof.payload)
        return changed
    }
}

private func groupedClassifierSnapshot(_ original: GroupedCopyFilesystemSnapshot,
    owner: UUID? = nil, job: UUID? = nil, revision: Int? = nil,
    parent: GroupedCopyObservedParent? = nil, groups: [GroupedCopyGroupObservation]? = nil,
    members: [GroupedCopyMemberObservation]? = nil, digest: String? = nil) -> GroupedCopyFilesystemSnapshot {
    .init(owner: owner ?? original.owner, job: job ?? original.job, revision: revision ?? original.revision,
        destinationParent: parent ?? original.destinationParent, groups: groups ?? original.groups,
        members: members ?? original.members, inventoryDigest: digest ?? original.inventoryDigest)
}

@Test func groupedClassifierRequiresDurableSealAndSeparateOutcome() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.record
    let original = record.members[0].progress.declaration!
    record.members[0].progress = .declared(original); record.groups[0].phase = .declared
    let observed = fixture.observed(record, placements: [0: .published, 1: .published])
    let result = try GroupedCopyRecoveryClassifier.classify(record, observed: observed)
    #expect(result.members[0].state == .protected)
    #expect(result.members[0].protectionReason == .unsealed)
    #expect(result.members[1].state == .protected) // Group publication intent is not sealed.
    #expect(result.members[2].state == .sealedUnpublished)
    #expect(result.confirmPublicationMembers.isEmpty)
    #expect(!result.fullyAccounted && !result.canFinishReview && !result.canUndo)
}

@Test func groupedClassifierOffersOnlyExactUnconfirmedSubsets() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    let record = fixture.reverseIntent(fixture.record, member: 1)
    let result = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: .published, 1: .retained, 2: .both]))
    #expect(result.members.map(\.state) == [.unconfirmedPublication, .unconfirmedReversal, .protected])
    #expect(result.confirmPublicationMembers == [0])
    #expect(result.confirmReversalMembers == [1])
    #expect(!result.fullyAccounted && !result.canFinishReview && !result.canUndo)
}

@Test(arguments: [GroupedClassifierFixture.Placement.both, .neither, .foreignPublic,
    .unavailable, .wrongDigest, .wrongIdentityDigest])
private func groupedClassifierResemblanceAndMissingSlotsSupplyNoAuthority(placement: GroupedClassifierFixture.Placement) throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    let record = fixture.published(fixture.record, member: 0)
    let result = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: placement]))
    #expect(result.members[0].state == .protected)
    #expect(result.confirmPublicationMembers.isEmpty && result.confirmReversalMembers.isEmpty)
    #expect(!result.canUndo && !result.canFinishReview)
}

@Test(arguments: [GroupedCopyState.active, .needsReview])
func groupedClassifierDurableUnfinishedUndoCanRetryExactPublicObject(state: GroupedCopyState) throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.reverseIntent(fixture.record, member: 0)
    record.head.state = state
    let result = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: .published]))
    #expect(result.members[0].state == .pendingReversal)
    #expect(result.canUndo)
    #expect(result.confirmReversalMembers.isEmpty)
    #expect(!result.fullyAccounted && !result.canFinishReview)
    let ambiguous = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: .published, 1: .published]))
    #expect(!ambiguous.canUndo) // Another unconfirmed Copy must be reviewed first.
}

@Test func groupedClassifierPersistedReviewIntentDoesNotConfirmOutcome() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.record
    record.head.reviewIntent = .init(id: UUID(), kind: .publication, preparedRevision: record.head.revision,
        members: [0], inventoryDigest: String(repeating: "a", count: 64))
    let result = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: .published]))
    #expect(result.members[0].state == .unconfirmedPublication)
    #expect(result.confirmPublicationMembers == [0])
    #expect(!result.canFinishReview && !result.canUndo)
}

@Test func groupedClassifierClosureDispositionUsesAcknowledgedFacts() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    let retained = try GroupedCopyRecoveryClassifier.classify(fixture.record, observed: fixture.observed(fixture.record))
    #expect(retained.fullyAccounted && retained.canFinishReview)
    #expect(retained.finishDisposition == .stoppedSettled)
    #expect(!retained.canUndo)
    var allPublished = fixture.record
    for ordinal in allPublished.members.indices { allPublished = fixture.published(allPublished, member: ordinal) }
    let completed = try GroupedCopyRecoveryClassifier.classify(allPublished,
        observed: fixture.observed(allPublished, placements: [0: .published, 1: .published, 2: .published]))
    #expect(completed.finishDisposition == .completed && completed.canFinishReview)
    var mixed = fixture.undone(fixture.record, member: 0)
    let undone = try GroupedCopyRecoveryClassifier.classify(mixed, observed: fixture.observed(mixed))
    #expect(undone.finishDisposition == .undone) // Retained, never-published siblings do not undo a publication.
    mixed = fixture.published(mixed, member: 1)
    let partialUndo = try GroupedCopyRecoveryClassifier.classify(mixed,
        observed: fixture.observed(mixed, placements: [1: .published]))
    #expect(partialUndo.finishDisposition == .stoppedSettled)
    #expect(!partialUndo.canUndo) // Terminal closure is still an explicit action.
    mixed.head.state = .stoppedSettled
    let closed = try GroupedCopyRecoveryClassifier.classify(mixed,
        observed: fixture.observed(mixed, placements: [1: .published]))
    #expect(closed.canUndo && !closed.canFinishReview)
}

@Test func groupedClassifierWholeGroupMarkerInventoryAndParentGuardEveryAction() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    let record = fixture.record
    let observed = fixture.observed(record, placements: [0: .published])
    let group = observed.groups[0]
    let changedMarkers: [GroupedCopyObservedMarker] = [.changed, .missing, .unavailable, .notInspected]
    for marker in changedMarkers {
        let changed = groupedClassifierSnapshot(observed,
            groups: [.init(ordinal: 0, area: group.area, marker: marker)])
        let result = try GroupedCopyRecoveryClassifier.classify(record, observed: changed)
        #expect(result.members.allSatisfy { $0.state == .protected })
        #expect(result.confirmPublicationMembers.isEmpty && !result.canFinishReview && !result.canUndo)
    }
    guard case .present(let identity, let children) = group.area else { throw FileOperationFailure.invalidRequest }
    for foreignChildren in [children + [Data("foreign".utf8)], Array(children.dropLast()), children + [children[0]]] {
        let changed = groupedClassifierSnapshot(observed,
            groups: [.init(ordinal: 0, area: .present(identity, children: foreignChildren), marker: .matched)])
        let result = try GroupedCopyRecoveryClassifier.classify(record, observed: changed)
        #expect(result.members.allSatisfy { $0.protectionReason == .inventory })
        #expect(result.confirmPublicationMembers.isEmpty)
    }
    let unavailable = try GroupedCopyRecoveryClassifier.classify(record,
        observed: groupedClassifierSnapshot(observed, parent: .unavailable(.denied)))
    #expect(unavailable.members.allSatisfy { $0.protectionReason == .parent })
    #expect(!unavailable.canFinishReview && !unavailable.canUndo)
}

@Test func groupedClassifierNeverCreatedRequiresDurablePositiveClosure() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.record
    for ordinal in record.members.indices {
        record.members[ordinal].progress = .neverStaged(record.members[ordinal].progress.declaration!)
    }
    record.groups[0].areaIdentity = nil
    record.groups[0].creationClosure = .neverCreated
    let original = fixture.observed(fixture.record)
    let members = record.members.map {
        GroupedCopyMemberObservation(ordinal: $0.ordinal, area: .unavailable(.unavailable),
            privateSlot: .unavailable(.unavailable), publicSlot: .absent)
    }
    let absent = groupedClassifierSnapshot(original,
        groups: [.init(ordinal: 0, area: .absent, marker: .notInspected)], members: members)
    let closed = try GroupedCopyRecoveryClassifier.classify(record, observed: absent)
    #expect(closed.members.allSatisfy { $0.state == .neverStaged })
    #expect(closed.canFinishReview && closed.finishDisposition == .stoppedSettled)
    var contradictoryMembers = members
    contradictoryMembers[0] = original.members[0] // Reports a present area/private object under an absent group.
    let contradictory = try GroupedCopyRecoveryClassifier.classify(record,
        observed: groupedClassifierSnapshot(absent, members: contradictoryMembers))
    #expect(contradictory.members.allSatisfy { $0.protectionReason == .inventory })
    #expect(!contradictory.fullyAccounted && !contradictory.canFinishReview)
    record.groups[0].creationClosure = nil; record.groups[0].phase = .declared
    let unknown = try GroupedCopyRecoveryClassifier.classify(record, observed: absent)
    #expect(unknown.members.allSatisfy { $0.state == .protected })
    #expect(!unknown.canFinishReview)
}

@Test func groupedClassifierNeverDeclaredTailIsNotAnObservationOfCompletion() throws {
    let fixture = try GroupedClassifierFixture(count: 17); defer { fixture.remove() }
    var record = fixture.record
    record.groups.removeLast(); record.head.groupCount = 1
    record.members[16].progress = .notDeclared
    let result = try GroupedCopyRecoveryClassifier.classify(record, observed: fixture.observed(record))
    #expect(result.members[16].state == .neverDeclared)
    #expect(result.confirmPublicationMembers.isEmpty)
    #expect(result.canFinishReview && result.finishDisposition == .stoppedSettled)
}

@Test func groupedClassifierRejectsCrossLinkedIncompleteAndStaleObservation() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    let original = fixture.observed(fixture.record)
    let invalid = [groupedClassifierSnapshot(original, owner: UUID()),
        groupedClassifierSnapshot(original, job: UUID()),
        groupedClassifierSnapshot(original, revision: original.revision + 1),
        groupedClassifierSnapshot(original, groups: []),
        groupedClassifierSnapshot(original, members: Array(original.members.dropLast())),
        groupedClassifierSnapshot(original, members: [original.members[0], original.members[0], original.members[2]]),
        groupedClassifierSnapshot(original, digest: "not-a-digest")]
    for snapshot in invalid {
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try GroupedCopyRecoveryClassifier.classify(fixture.record, observed: snapshot)
        }
    }
}

@Test(arguments: [GroupedCopyState.cleanupReview, .cleaned])
func groupedClassifierCleanupDispositionCannotRegainCopyAuthority(state: GroupedCopyState) throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.record
    record.head.undoInvalidated = true; record.head.state = state
    if state == .cleaned {
        let before = try verifiedTree(record.groups[0].areaURL, cancellation: OperationCancellation())
        let intent = GroupedCopyCleanupIntent(id: UUID(), before: before,
            parent: record.members[0].manifest.destination.parentIdentity)
        record.groups[0].cleanup = .confirmed(intent, fixture.root.appendingPathComponent("known-native-result"), before)
    }
    let result = try GroupedCopyRecoveryClassifier.classify(record,
        observed: fixture.observed(record, placements: [0: .published]))
    #expect(result.jobState == state)
    #expect(result.members.allSatisfy { $0.protectionReason == .cleanup })
    #expect(result.confirmPublicationMembers.isEmpty && result.confirmReversalMembers.isEmpty)
    #expect(!result.canUndo && !result.canFinishReview && !result.fullyAccounted)
}

@Test func groupedClassifierActualDestinationEvidenceNeedsNoOriginalSource() throws {
    let fixture = try GroupedClassifierFixture(); defer { fixture.remove() }
    var record = fixture.record
    for ordinal in record.members.indices {
        let member = record.members[ordinal], declaration = member.progress.declaration!
        let privateParent = try DirectoryAnchor(declaration.areaURL, resolve: false)
        let publicParent = try DirectoryAnchor(fixture.destination, resolve: false)
        try exclusiveRename(from: privateParent.fd, name: "payload", to: publicParent.fd,
            name: member.manifest.destination.name)
        record = fixture.published(record, member: ordinal)
        try FileManager().removeItem(at: member.manifest.source.url)
    }
    record.head.state = .completed
    let observed = try GroupedCopyFilesystemEvidence.inspect(record, cancellation: OperationCancellation())
    let result = try GroupedCopyRecoveryClassifier.classify(record, observed: observed)
    #expect(result.members.allSatisfy { $0.state == .confirmedPublication })
    #expect(result.canUndo && result.fullyAccounted)
    #expect(!result.canFinishReview)
}

@Test func groupedClassifierRetainedInspectionUsesActualCleanupRecordWithoutRestoringActions() throws {
    let fixture = try GroupedClassifierFixture(count: 17); defer { fixture.remove() }
    var record = fixture.record
    record.head.undoInvalidated = true; record.head.state = .cleanupReview
    let before = try verifiedTree(record.groups[0].areaURL, cancellation: OperationCancellation())
    let intent = GroupedCopyCleanupIntent(id: UUID(), before: before,
        parent: record.members[0].manifest.destination.parentIdentity)
    record.groups[0].cleanup = .intent(intent)
    let observed = fixture.observed(record)
    let remaining = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record, observed: observed, groupOrdinal: 1)
    #expect(remaining.map(\.ordinal) == [16])
    #expect(remaining.map(\.state) == [.sealedUnpublished])
    #expect(record.head.undoInvalidated && record.head.state == .cleanupReview)
    let ordinary = try GroupedCopyRecoveryClassifier.classify(record, observed: observed)
    #expect(!ordinary.canUndo && !ordinary.canFinishReview)
    #expect(ordinary.confirmPublicationMembers.isEmpty && ordinary.confirmReversalMembers.isEmpty)
    #expect(throws: FileOperationFailure.recoveryUncertain) {
        _ = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record, observed: observed, groupOrdinal: 0)
    }
    #expect(throws: FileOperationFailure.recoveryUncertain) {
        _ = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record,
            observed: groupedClassifierSnapshot(observed, revision: observed.revision + 1), groupOrdinal: 1)
    }
    var changedGroups = observed.groups
    changedGroups[1] = .init(ordinal: 1, area: observed.groups[1].area, marker: .changed)
    let foreign = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record,
        observed: groupedClassifierSnapshot(observed, groups: changedGroups), groupOrdinal: 1)
    #expect(foreign.allSatisfy { $0.state == .protected && $0.protectionReason == .marker })
}
