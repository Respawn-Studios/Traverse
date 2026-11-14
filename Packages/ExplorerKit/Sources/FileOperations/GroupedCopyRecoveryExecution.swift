import Darwin
import Foundation

internal enum GroupedCopyRecoveryCheckpointStage: String, Codable, Sendable, CaseIterable {
    case reviewPrepared, reviewIntentWillCommit, reviewIntentCommitted
    case reviewWillSync, reviewSynced, reviewWillRecordOutcomes, reviewOutcomesRecorded
    case reverseIntentWillCommit, reverseIntentCommitted, reverseWillRename, reverseRenamed
    case reverseSynced, reverseWillRecordOutcome, reverseOutcomeRecorded
    case reverseTerminalWillCommit, reverseTerminalCommitted
}
internal struct GroupedCopyRecoveryCheckpoint: Sendable {
    let stage: GroupedCopyRecoveryCheckpointStage
    let recordID: UUID
    let revision: Int
    let action: CopyRecoveryAction?
    let memberOrdinal: Int?
}
internal struct GroupedCopyRecoveryHooks: Sendable {
    var checkpoint: (@Sendable (GroupedCopyRecoveryCheckpoint, OperationCancellation) throws -> Void)? = nil
}

extension RecoverableFileOperations {
    public func prepareGroupedRecovery(recordID: UUID,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> GroupedCopyRecoveryReview {
        let reporter = OperationProgressReporter(callback: progress)
        do {
            let review = try await worker(progress: reporter) { cancellation in
                reporter.begin(.verifying)
                guard case .groupedCopyV1(let record) = try OperationHistoryInspector.record(self.directory, id: recordID, cancellation: cancellation) else {
                    throw FileOperationFailure.unsupported
                }
                let observed = try GroupedCopyFilesystemEvidence.inspect(record, cancellation: cancellation)
                let classified = try GroupedCopyRecoveryClassifier.classify(record, observed: observed)
                var actions: [CopyRecoveryAction] = []
                if !classified.confirmPublicationMembers.isEmpty { actions.append(.confirmCopies) }
                if !classified.confirmReversalMembers.isEmpty { actions.append(.confirmUndo) }
                if classified.canFinishReview { actions.append(.finishReview) }
                let items = classified.members.map { member in
                    let manifest = record.members[member.ordinal].manifest
                    return CopyRecoveryItem(id: member.ordinal, source: manifest.source.url, destination: manifest.destination.url,
                        state: Self.groupedItemState(member.state), protectionReason: member.protectionReason?.rawValue)
                }
                let result = GroupedCopyRecoveryReview(recordID: recordID, revision: record.head.revision,
                    state: record.head.state.rawValue, items: items, availableActions: actions, canUndo: classified.canUndo,
                    owner: record.head.owner, session: self.continuationSession, inventoryDigest: observed.inventoryDigest,
                    publicationMembers: classified.confirmPublicationMembers, reversalMembers: classified.confirmReversalMembers,
                    use: ContinuationUse())
                try self.groupedRecoveryCheckpoint(.reviewPrepared, record: record, action: nil, cancellation: cancellation)
                return result
            }
            reporter.flush(); return review
        } catch { reporter.finish(success: false); throw error }
    }

    public func performGroupedRecovery(action: CopyRecoveryAction, from review: GroupedCopyRecoveryReview,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                guard review.session == self.continuationSession, review.availableActions.contains(action) else { throw FileOperationFailure.invalidRequest }
                try review.use.claim()
                reporter.begin(.verifying)
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                guard let edit = try journal.openGroupedEdit(review.recordID), edit.snapshot.head.owner == review.owner,
                      edit.revision == review.revision else { throw FileOperationFailure.recoveryUncertain }
                let before = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                guard before.inventoryDigest == review.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                let classified = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: before)
                let members: [Int]
                let kind: GroupedCopyReviewKind
                switch action {
                case .confirmCopies:
                    members = review.publicationMembers; kind = .publication
                    guard !members.isEmpty, members == classified.confirmPublicationMembers else { throw FileOperationFailure.recoveryUncertain }
                case .confirmUndo:
                    members = review.reversalMembers; kind = .reversal
                    guard !members.isEmpty, members == classified.confirmReversalMembers else { throw FileOperationFailure.recoveryUncertain }
                case .finishReview:
                    members = []; kind = .closure
                    guard classified.canFinishReview else { throw FileOperationFailure.recoveryUncertain }
                }
                let intent = GroupedCopyReviewIntent(id: UUID(), kind: kind, preparedRevision: edit.revision,
                    members: members, inventoryDigest: before.inventoryDigest)
                try self.groupedRecoveryCheckpoint(.reviewIntentWillCommit, record: edit.snapshot, action: action, cancellation: cancellation)
                try cancellation.check()
                try edit.beginReview(intent); try journal.save(edit)
                try self.groupedRecoveryCheckpoint(.reviewIntentCommitted, record: edit.snapshot, action: action, cancellation: cancellation)
                let intended = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                guard intended.inventoryDigest == before.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                try self.groupedRecoveryCheckpoint(.reviewWillSync, record: edit.snapshot, action: action, cancellation: cancellation)
                reporter.begin(.syncing)
                try self.syncGroupedEvidence(edit.snapshot, observed: intended, cancellation: cancellation)
                try self.groupedRecoveryCheckpoint(.reviewSynced, record: edit.snapshot, action: action, cancellation: cancellation)
                let after = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                guard after.inventoryDigest == before.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                _ = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: after)
                try self.groupedRecoveryCheckpoint(.reviewWillRecordOutcomes, record: edit.snapshot, action: action, cancellation: cancellation)
                // Fault observers may change inventory: the final scan is after the
                // last pre-commit hook, before any outcome is accepted in memory.
                let final = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                guard final.inventoryDigest == before.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                for ordinal in members {
                    switch action {
                    case .confirmCopies:
                        guard case .verified(let tree, _) = final.members[ordinal].publicSlot else { throw FileOperationFailure.recoveryUncertain }
                        try edit.recordPublication(tree, member: ordinal)
                    case .confirmUndo:
                        guard case .verified(let tree, _)? = final.members[ordinal].privateSlot else { throw FileOperationFailure.recoveryUncertain }
                        try edit.recordReversal(tree, member: ordinal)
                    case .finishReview: break
                    }
                }
                try edit.finishReview(intent.id)
                let resolved = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: final)
                // A sealed fact elsewhere may still be observed public/unconfirmed,
                // or protected. A partial confirmation must not close that work.
                if !resolved.fullyAccounted { try edit.markNeedsReview() }
                try journal.save(edit)
                try self.groupedRecoveryCheckpoint(.reviewOutcomesRecorded, record: edit.snapshot, action: action, cancellation: cancellation)
                let outcomes = members.map { ordinal -> FileOperationOutcome in
                    let member = edit.snapshot.members[ordinal]
                    return FileOperationOutcome(source: member.manifest.source.url, destination: member.manifest.destination.url,
                        status: .succeeded, recoveryURLs: [], role: .job)
                }
                return RecoverableOperationResult(result: FileOperationResult(items: outcomes.isEmpty
                    ? [FileOperationOutcome(source: nil, destination: nil, status: .succeeded, recoveryURLs: [], role: .job)] : outcomes,
                    cancellationRequested: cancellation.isCancelled), recordID: edit.id)
            }
        } catch {
            result = RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: nil, destination: nil,
                status: operationStatus(error), recoveryURLs: [], role: .job)], cancellationRequested: error is CancellationError), recordID: review.recordID)
        }
        reporter.finish(success: result.result.disposition == .succeeded)
        return result
    }

    internal func reverseGroupedCopy(_ edit: GroupedCopyEditSession, journal: OperationJournal,
                                     cancellation: OperationCancellation) -> RecoverableOperationResult {
        var outcomes: [FileOperationOutcome] = []
        var acknowledged = Set<Int>()
        var reversed = Set<Int>()
        var selected: [Int] = []
        var active: Int?
        var began = false
        do {
            let initial = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
            let classification = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: initial)
            guard classification.canUndo else { throw FileOperationFailure.recoveryUncertain }
            selected = classification.members.filter { [.confirmedPublication, .pendingReversal].contains($0.state) }.map(\.ordinal)
            // An interrupted reverse intent is resolved first; never create a second
            // unresolved intent while an earlier member still needs a guarded retry.
            selected.sort { a, b in
                let pendingA = classification.members[a].state == .pendingReversal
                let pendingB = classification.members[b].state == .pendingReversal
                return pendingA != pendingB ? pendingA : a > b
            }
            for ordinal in selected {
                active = ordinal
                try cancellation.check()
                let before = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                let checked = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: before)
                guard checked.fullyAccounted || checked.canUndo else { throw FileOperationFailure.recoveryUncertain }
                guard [.confirmedPublication, .pendingReversal].contains(checked.members[ordinal].state) else { throw FileOperationFailure.recoveryUncertain }
                let member = edit.snapshot.members[ordinal]
                guard let declaration = member.progress.declaration, let seal = member.progress.seal else { throw FileOperationFailure.recoveryUncertain }
                let intent = UUID()
                try groupedRecoveryCheckpoint(.reverseIntentWillCommit, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                try cancellation.check()
                if case .reverseIntent(_, _, _, let prior) = member.progress {
                    try edit.beginReverseRetry(member: ordinal, priorIntent: prior, intent: intent,
                        preparedRevision: edit.revision, priorReviewID: edit.snapshot.head.reviewIntent?.id)
                } else { try edit.beginReverse(member: ordinal, intent: intent) }
                began = true
                try journal.save(edit)
                try groupedRecoveryCheckpoint(.reverseIntentCommitted, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                try groupedRecoveryCheckpoint(.reverseWillRename, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                hooks.beforeRename?()
                try hooks.beforeExclusiveRename?(member.manifest.destination.url, declaration.areaURL.appendingPathComponent("payload"))
                let intended = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation)
                guard intended.inventoryDigest == before.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                let source = try GroupedCopyFilesystemEvidence.checkedParent(member.manifest.destination)
                let target = try DirectoryAnchor(declaration.areaURL, resolve: false)
                guard target.identity.sameObject(as: seal.areaIdentity),
                      seal.proof.payload.matches(try verifiedTree(parent: source.fd, name: member.manifest.destination.name, cancellation: cancellation)),
                      try NativeRenameEntry.observe(parent: source, name: member.manifest.destination.name).nameBytes == member.manifest.destination.nameBytes else { throw FileOperationFailure.sourceChanged }
                try requireAbsent("payload", in: target.fd)
                let pinned = try pinEntry(parent: source.fd, name: member.manifest.destination.name, matching: seal.proof.payload.identity)
                defer { Darwin.close(pinned) }
                try source.validate(); try target.validate()
                let segment = cancellation.segment(); try segment.beginMutation()
                cancellation.progress?.begin(.publishing, source: member.manifest.destination.url, destination: declaration.areaURL.appendingPathComponent("payload"))
                try exclusiveRename(from: source.fd, name: member.manifest.destination.name, to: target.fd, name: "payload")
                reversed.insert(ordinal)
                hooks.afterRename?()
                try groupedRecoveryCheckpoint(.reverseRenamed, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                let draining = segment.draining()
                try hooks.beforeSync?(declaration.areaURL.appendingPathComponent("payload"))
                try syncDirectory(source); try syncDirectory(target)
                try source.validate(); try target.validate()
                let after = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: draining)
                let afterClassification = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: after)
                guard afterClassification.members[ordinal].state == .unconfirmedReversal,
                      afterClassification.members.allSatisfy({ $0.ordinal == ordinal || [.neverDeclared, .neverStaged, .sealedUnpublished, .confirmedPublication, .confirmedUndone].contains($0.state) }),
                      case .verified(let restored, _)? = after.members[ordinal].privateSlot,
                      try EntrySnapshot(fd: pinned).sameObject(as: restored.identity) else { throw FileOperationFailure.recoveryUncertain }
                try groupedRecoveryCheckpoint(.reverseSynced, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                try groupedRecoveryCheckpoint(.reverseWillRecordOutcome, record: edit.snapshot, member: ordinal, cancellation: cancellation)
                let final = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: draining)
                guard final.inventoryDigest == after.inventoryDigest else { throw FileOperationFailure.recoveryUncertain }
                try edit.recordReversal(restored, member: ordinal); try journal.save(edit)
                acknowledged.insert(ordinal)
                outcomes.append(FileOperationOutcome(source: member.manifest.destination.url,
                    destination: declaration.areaURL.appendingPathComponent("payload"), status: .succeeded, recoveryURLs: []))
                try groupedRecoveryCheckpoint(.reverseOutcomeRecorded, record: edit.snapshot, member: ordinal, cancellation: cancellation)
            }
            active = nil
            try groupedRecoveryCheckpoint(.reverseTerminalWillCommit, record: edit.snapshot, cancellation: cancellation)
            let final = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation.draining())
            guard try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: final).fullyAccounted else { throw FileOperationFailure.recoveryUncertain }
            try edit.close(); try journal.save(edit)
            try groupedRecoveryCheckpoint(.reverseTerminalCommitted, record: edit.snapshot, cancellation: cancellation)
        } catch {
            if edit.valid, began {
                do {
                    if error is CancellationError {
                        let actual = try GroupedCopyFilesystemEvidence.inspect(edit.snapshot, cancellation: cancellation.draining())
                        let checked = try GroupedCopyRecoveryClassifier.classify(edit.snapshot, observed: actual)
                        if checked.fullyAccounted { try edit.close() } else { try edit.markNeedsReview() }
                    } else { try edit.markNeedsReview() }
                    try journal.save(edit)
                } catch { /* No cold retry or inferred outcome. */ }
            }
            let remaining = selected.filter { !acknowledged.contains($0) }
            for ordinal in remaining {
                let member = edit.snapshot.members[ordinal]
                outcomes.append(FileOperationOutcome(source: member.manifest.destination.url,
                    destination: member.progress.declaration?.areaURL.appendingPathComponent("payload"),
                    status: reversed.contains(ordinal) ? .failed(.recoveryUncertain) : (ordinal == active ? operationStatus(error) : .notStarted), recoveryURLs: edit.snapshot.groups.map(\.areaURL)))
            }
            if active.map({ !remaining.contains($0) }) ?? true {
                outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error),
                    recoveryURLs: edit.snapshot.groups.map(\.areaURL), role: .job))
            }
        }
        return RecoverableOperationResult(result: FileOperationResult(items: outcomes,
            cancellationRequested: cancellation.isCancelled), recordID: edit.id)
    }

    internal func groupedRecoveryCheckpoint(_ stage: GroupedCopyRecoveryCheckpointStage, record: GroupedCopyRecord,
        action: CopyRecoveryAction? = nil, member: Int? = nil, cancellation: OperationCancellation) throws {
        try hooks.groupedRecovery.checkpoint?(GroupedCopyRecoveryCheckpoint(stage: stage, recordID: record.head.id,
            revision: record.head.revision, action: action, memberOrdinal: member), cancellation)
    }

    private func syncGroupedEvidence(_ record: GroupedCopyRecord, observed: GroupedCopyFilesystemSnapshot,
                                     cancellation: OperationCancellation) throws {
        let target = try GroupedCopyFilesystemEvidence.checkedParent(record.members[0].manifest.destination)
        for member in record.members {
            try cancellation.check()
            let observation = observed.members[member.ordinal]
            if case .verified = observation.publicSlot {
                try hooks.beforeSync?(member.manifest.destination.url)
                try syncTree(member.manifest.destination.url, cancellation: cancellation)
            }
            if let declaration = member.progress.declaration, case .present? = observation.area {
                let area = try DirectoryAnchor(declaration.areaURL, resolve: false)
                guard let seal = member.progress.seal, area.identity.sameObject(as: seal.areaIdentity) else { continue }
                if case .verified? = observation.privateSlot {
                    let url = declaration.areaURL.appendingPathComponent("payload")
                    try hooks.beforeSync?(url); try syncTree(url, cancellation: cancellation)
                }
                try syncDirectory(area); try area.validate()
            }
        }
        for group in record.groups {
            try cancellation.check()
            guard case .present = observed.groups[group.ordinal].area else { continue }
            let area = try DirectoryAnchor(group.areaURL, resolve: false)
            guard let identity = group.areaIdentity, area.identity.sameObject(as: identity) else { throw FileOperationFailure.recoveryUncertain }
            try syncDirectory(area); try area.validate()
        }
        try syncDirectory(target); try target.validate()
    }

    private static func groupedItemState(_ state: GroupedCopyRecoveryMemberState) -> CopyRecoveryItemState {
        switch state {
        case .neverDeclared: .notStarted
        case .neverStaged: .neverStaged
        case .sealedUnpublished: .retainedCopy
        case .unconfirmedPublication: .copyNeedsConfirmation
        case .confirmedPublication: .copied
        case .pendingReversal: .undoPending
        case .unconfirmedReversal: .undoNeedsConfirmation
        case .confirmedUndone: .undone
        case .protected: .protected
        }
    }
}
