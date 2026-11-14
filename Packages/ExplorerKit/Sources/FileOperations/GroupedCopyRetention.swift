import Darwin
import Foundation

internal enum GroupedCopyRetentionCheckpointStage: String, Codable, Sendable, CaseIterable {
    case inventoryVerified, invalidationWillCommit, invalidationCommitted
    case trashIntentWillCommit, trashIntentCommitted, nativeTrashWillEnter, nativeTrashReturned
    case returnedLocationRecorded, trashSynced, trashOutcomeWillCommit, trashOutcomeRecorded
    case cleanupTerminalWillCommit, cleanupTerminalCommitted
}
internal struct GroupedCopyRetentionCheckpoint: Sendable {
    let stage: GroupedCopyRetentionCheckpointStage
    let recordID: UUID
    let revision: Int
    let groupOrdinal: Int?
}
internal struct GroupedCopyRetentionHooks: Sendable {
    var checkpoint: (@Sendable (GroupedCopyRetentionCheckpoint, OperationCancellation) throws -> Void)? = nil
}

extension RecoverableFileOperations {
    internal func groupedRetentionRecord(_ record: GroupedCopyRecord,
        cancellation: OperationCancellation) throws -> RecoveryRetentionRecord {
        if record.head.state == .cleaned {
            let reason = "Recovery copies were already moved to Trash. Undo has ended for this operation."
            let areas = record.groups.compactMap { group -> RecoveryRetentionArea? in
                guard case .confirmed(_, let target, _) = group.cleanup else { return nil }
                return RecoveryRetentionArea(url: target, logicalBytes: nil, verified: false, protectionReason: reason)
            }
            return RecoveryRetentionRecord(id: record.head.id, operation: "copy", createdAt: record.head.createdAt,
                state: record.head.state.rawValue, areas: areas, logicalBytes: nil, canCleanup: false, protectionReason: reason)
        }
        var areas: [RecoveryRetentionArea] = []
        var reason: String?
        var bytes: Int64 = 0
        do {
            let inventory = try groupedRetentionInventory(record, cancellation: cancellation)
            for group in record.groups where group.areaIdentity != nil {
                let tree = inventory[group.ordinal]
                let logical = try groupedRetainedBytes(group, record: record)
                let (sum, overflow) = bytes.addingReportingOverflow(logical)
                guard !overflow else { throw FileOperationFailure.unsupported }
                bytes = sum
                let shownURL: URL
                if case .confirmed(_, let target, _) = group.cleanup { shownURL = target }
                else { shownURL = group.areaURL }
                areas.append(RecoveryRetentionArea(url: shownURL, logicalBytes: logical,
                    verified: tree != nil || group.cleanup.phase == "confirmed", protectionReason: nil))
            }
            if areas.isEmpty { reason = "This job has no retained recovery area." }
        } catch {
            if error is CancellationError { throw error }
            reason = "Recovery data is unfinished, changed or unavailable. It remains protected."
            areas = record.groups.filter { $0.creationClosure != .neverCreated }.map { group in
                let location: URL
                switch group.cleanup {
                case .returned(_, let target), .confirmed(_, let target, _): location = target
                default: location = group.areaURL
                }
                return RecoveryRetentionArea(url: location, logicalBytes: nil, verified: false, protectionReason: reason)
            }
        }
        return RecoveryRetentionRecord(id: record.head.id, operation: "copy", createdAt: record.head.createdAt,
            state: record.head.state.rawValue, areas: areas, logicalBytes: reason == nil ? bytes : nil,
            canCleanup: reason == nil, protectionReason: reason)
    }

    /// Called only by the existing explicitly confirmed cleanup command, under the
    /// serial worker and catalog writer lock. Unknown native outcomes never retry.
    internal func cleanupGroupedRecord(_ edit: GroupedCopyEditSession, journal: OperationJournal,
        cancellation: OperationCancellation) -> RecoverableOperationResult {
        var outcomes: [FileOperationOutcome] = []
        // A fresh refusal must still report every native target already durable
        // in this record. These locations grant no authority to retry Trash.
        var knownLocations: [URL] = edit.snapshot.groups.compactMap { group in
            switch group.cleanup {
            case .returned(_, let target), .confirmed(_, let target, _): target
            default: nil
            }
        }
        var active: Int?
        do {
            let initial = try groupedRetentionInventory(edit.snapshot, cancellation: cancellation)
            guard !edit.snapshot.groups.isEmpty,
                  edit.snapshot.groups.contains(where: { $0.areaIdentity != nil }) else { throw FileOperationFailure.invalidRequest }
            try groupedRetentionCheckpoint(.inventoryVerified, edit: edit, cancellation: cancellation)
            if !edit.snapshot.head.undoInvalidated {
                try groupedRetentionCheckpoint(.invalidationWillCommit, edit: edit, cancellation: cancellation)
                try cancellation.check()
                // Recheck the entire job after the last observer, before the
                // irreversible revocation of Undo, not just before native Trash.
                let beforeInvalidation = try groupedRetentionInventory(edit.snapshot, cancellation: cancellation)
                guard beforeInvalidation.count == initial.count else { throw FileOperationFailure.sourceChanged }
                for (ordinal, before) in initial {
                    guard let current = beforeInvalidation[ordinal], before.matches(current) else {
                        throw FileOperationFailure.sourceChanged
                    }
                }
                try edit.beginCleanup(); try journal.save(edit)
                try groupedRetentionCheckpoint(.invalidationCommitted, edit: edit, cancellation: cancellation)
            }
            for ordinal in edit.snapshot.groups.indices {
                active = ordinal
                try cancellation.check()
                let group = edit.snapshot.groups[ordinal]
                if group.creationClosure == .neverCreated || group.cleanup.phase == "confirmed" { continue }
                guard group.cleanup.phase == "none", let before = initial[ordinal] else { throw FileOperationFailure.recoveryUncertain }
                cancellation.progress?.begin(.retaining, source: group.areaURL,
                    index: ordinal + 1, count: edit.snapshot.groups.count, items: edit.snapshot.groups.count)
                let fresh = try groupedRetentionInventory(edit.snapshot, cancellation: cancellation)
                guard let current = fresh[ordinal], before.matches(current) else { throw FileOperationFailure.sourceChanged }
                let parent = try GroupedCopyFilesystemEvidence.checkedParent(edit.snapshot.members[0].manifest.destination)
                let intent = GroupedCopyCleanupIntent(id: UUID(), before: current, parent: parent.identity)
                try groupedRetentionCheckpoint(.trashIntentWillCommit, edit: edit, group: ordinal, cancellation: cancellation)
                try cancellation.check()
                try edit.recordCleanupIntent(intent, group: ordinal); try journal.save(edit)
                try groupedRetentionCheckpoint(.trashIntentCommitted, edit: edit, group: ordinal, cancellation: cancellation)
                _ = try groupedRetentionInventory(edit.snapshot, liveIntent: intent.id, cancellation: cancellation)
                try groupedRetentionCheckpoint(.nativeTrashWillEnter, edit: edit, group: ordinal, cancellation: cancellation)
                // Revalidate after the final observer, immediately before native entry.
                _ = try groupedRetentionInventory(edit.snapshot, liveIntent: intent.id, cancellation: cancellation)
                let segment = cancellation.segment()
                try segment.beginMutation()
                var returned: NSURL?
                var nativeFailure: Error?
                if let injected = hooks.retentionTrash {
                    do { returned = try injected(group.areaURL) as NSURL }
                    catch { nativeFailure = error }
                } else {
                    do { try FileManager().trashItem(at: group.areaURL, resultingItemURL: &returned) }
                    catch { nativeFailure = error }
                }
                // Capture the native returned URL before any post-call check or
                // observer can fail, including a returned location accompanying error.
                if let target = returned as URL? { knownLocations.append(target) }
                try groupedRetentionCheckpoint(.nativeTrashReturned, edit: edit, group: ordinal, cancellation: cancellation)
                if let target = returned as URL? {
                    try edit.recordCleanupReturn(target, group: ordinal)
                    try journal.save(edit)
                }
                guard nativeFailure == nil else { throw nativeFailure! }
                guard let target = returned as URL? else { throw FileOperationFailure.recoveryUncertain }
                try groupedRetentionCheckpoint(.returnedLocationRecorded, edit: edit, group: ordinal, cancellation: cancellation)
                try validateGroupedRetainedArea(edit.snapshot, group: group, at: target,
                    allowNativeTrashTransition: true, cancellation: segment)
                let after = try verifyNativeTrashResult(target, before: current, cancellation: segment)
                try parent.validate()
                try requireAbsent(group.areaURL.lastPathComponent, in: parent.fd)
                let trashParent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
                try hooks.beforeSync?(target)
                try syncTree(target, cancellation: segment)
                try syncDirectory(parent); try syncDirectory(trashParent)
                try groupedRetentionCheckpoint(.trashSynced, edit: edit, group: ordinal, cancellation: cancellation)
                try validateGroupedRetainedArea(edit.snapshot, group: group, at: target,
                    allowNativeTrashTransition: true, cancellation: segment)
                guard after.matches(try verifiedTree(target, cancellation: segment)) else { throw FileOperationFailure.sourceChanged }
                try groupedRetentionCheckpoint(.trashOutcomeWillCommit, edit: edit, group: ordinal, cancellation: cancellation)
                try validateGroupedRetainedArea(edit.snapshot, group: group, at: target,
                    allowNativeTrashTransition: true, cancellation: segment)
                guard after.matches(try verifiedTree(target, cancellation: segment)) else { throw FileOperationFailure.sourceChanged }
                try parent.validate(); try trashParent.validate()
                try requireAbsent(group.areaURL.lastPathComponent, in: parent.fd)
                try edit.recordCleanupOutcome(after, group: ordinal); try journal.save(edit)
                outcomes.append(FileOperationOutcome(source: group.areaURL, destination: target, status: .succeeded, recoveryURLs: []))
                try groupedRetentionCheckpoint(.trashOutcomeRecorded, edit: edit, group: ordinal, cancellation: cancellation)
                cancellation.progress?.advance(items: 1)
                active = nil
            }
            _ = try groupedRetentionInventory(edit.snapshot, cancellation: cancellation)
            try groupedRetentionCheckpoint(.cleanupTerminalWillCommit, edit: edit, cancellation: cancellation)
            _ = try groupedRetentionInventory(edit.snapshot, cancellation: cancellation)
            try cancellation.check()
            try edit.closeCleanup(); try journal.save(edit)
            try groupedRetentionCheckpoint(.cleanupTerminalCommitted, edit: edit, cancellation: cancellation)
            if outcomes.isEmpty { outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: .succeeded, recoveryURLs: [], role: .job)) }
        } catch {
            // Invalid sessions cannot acquire authority from an uncertain save.
            // The persisted intent/known native return remains for explicit review.
            outcomes.append(FileOperationOutcome(source: active.map { edit.snapshot.groups[$0].areaURL }, destination: nil,
                status: operationStatus(error), recoveryURLs: knownLocations, role: .job))
        }
        return RecoverableOperationResult(result: FileOperationResult(items: outcomes,
            cancellationRequested: cancellation.isCancelled), recordID: edit.id)
    }

    private func groupedRetentionInventory(_ record: GroupedCopyRecord, liveIntent: UUID? = nil,
        cancellation: OperationCancellation) throws -> [Int: VerifiedTree] {
        try record.validate()
        guard [.completed, .stoppedSettled, .undone, .cleanupReview].contains(record.head.state),
              record.head.reviewIntent == nil else { throw FileOperationFailure.recoveryUncertain }
        let observed = try GroupedCopyFilesystemEvidence.inspect(record, cancellation: cancellation)
        let parent = try GroupedCopyFilesystemEvidence.checkedParent(record.members[0].manifest.destination)
        // Cleanup invalidates the whole job, including its untouched tail. A
        // later unrelated occupant there must remain protected rather than be
        // ignored merely because no staging group was declared for that member.
        for member in record.members where member.progress.phase == "notDeclared" {
            try cancellation.check()
            guard case .absent = observed.members[member.ordinal].publicSlot else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        var result: [Int: VerifiedTree] = [:]
        for group in record.groups {
            try cancellation.check()
            if group.creationClosure == .neverCreated {
                let states = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record, observed: observed, groupOrdinal: group.ordinal)
                guard states.allSatisfy({ $0.state == .neverStaged }) else { throw FileOperationFailure.recoveryUncertain }
                continue
            }
            switch group.cleanup {
            case .none:
                let states = try GroupedCopyRecoveryClassifier.classifyRetainedGroup(record, observed: observed, groupOrdinal: group.ordinal)
                guard states.allSatisfy({ [.neverStaged, .sealedUnpublished, .confirmedPublication, .confirmedUndone].contains($0.state) }) else { throw FileOperationFailure.recoveryUncertain }
                try validateGroupedRetainedArea(record, group: group, at: group.areaURL,
                    allowNativeTrashTransition: false, cancellation: cancellation)
                result[group.ordinal] = try verifiedTree(group.areaURL, cancellation: cancellation)
            case .intent(let intent):
                guard intent.id == liveIntent else { throw FileOperationFailure.recoveryUncertain }
                try validateGroupedRetainedArea(record, group: group, at: group.areaURL,
                    allowNativeTrashTransition: false, cancellation: cancellation)
                let before = try verifiedTree(group.areaURL, cancellation: cancellation)
                guard intent.before.matches(before) else { throw FileOperationFailure.sourceChanged }
                result[group.ordinal] = before
            case .returned:
                throw FileOperationFailure.recoveryUncertain
            case .confirmed(let intent, let target, let after):
                try requireAbsent(group.areaURL.lastPathComponent, in: parent.fd)
                try validateGroupedRetainedArea(record, group: group, at: target,
                    allowNativeTrashTransition: true, cancellation: cancellation)
                guard intent.before.matchesNativeTrashTransition(after), after.matches(try verifiedTree(target, cancellation: cancellation)) else { throw FileOperationFailure.sourceChanged }
            }
        }
        try parent.validate()
        return result
    }

    /// The group fingerprint does not encode descendant inode identities. Check
    /// each original member-area and sealed payload as well, even after native Trash.
    private func validateGroupedRetainedArea(_ record: GroupedCopyRecord, group: GroupedCopyGroup,
        at root: URL, allowNativeTrashTransition: Bool, cancellation: OperationCancellation) throws {
        guard let identity = group.areaIdentity else { throw FileOperationFailure.recoveryUncertain }
        let area = try DirectoryAnchor(root, resolve: false)
        guard area.identity.sameObject(as: identity) else { throw FileOperationFailure.sourceChanged }
        let marker = try NativeRenameEntry.observe(parent: area, name: GroupedCopyGroup.markerName)
        guard marker.nameBytes == Data(GroupedCopyGroup.markerName.utf8), marker.identity.type == S_IFREG,
              marker.identity.size <= 256,
              try OperationJournal.read(name: GroupedCopyGroup.markerName, anchor: area) == group.marker else { throw FileOperationFailure.recoveryUncertain }
        var expected = [Data(GroupedCopyGroup.markerName.utf8)]
        for ordinal in group.members {
            let member = record.members[ordinal]
            guard let declaration = member.progress.declaration else { throw FileOperationFailure.recoveryUncertain }
            if case .neverStaged = member.progress { continue }
            guard member.progress.seal != nil, ["sealed", "published", "undone"].contains(member.progress.phase) else { throw FileOperationFailure.recoveryUncertain }
            expected.append(Data(declaration.areaURL.lastPathComponent.utf8))
        }
        let actual = try GroupedCopyFilesystemEvidence.children(in: area, cancellation: cancellation, limit: group.members.count + 1)
        guard actual.count == expected.count, Set(actual.map { Data($0.utf8) }) == Set(expected) else { throw FileOperationFailure.recoveryUncertain }
        // Validate every expected namespace and inode before the first payload body
        // read. A same-content replacement is not an owned retained object.
        for ordinal in group.members {
            try cancellation.check()
            let member = record.members[ordinal]
            guard let declaration = member.progress.declaration else { throw FileOperationFailure.recoveryUncertain }
            let url = root.appendingPathComponent(declaration.areaURL.lastPathComponent, isDirectory: true)
            if case .neverStaged = member.progress {
                try requireAbsent(url.lastPathComponent, in: area.fd)
                let publicParent = try GroupedCopyFilesystemEvidence.checkedParent(member.manifest.destination)
                try requireAbsent(member.manifest.destination.name, in: publicParent.fd)
                continue
            }
            guard let seal = member.progress.seal else { throw FileOperationFailure.recoveryUncertain }
            let privateArea = try DirectoryAnchor(url, resolve: false)
            guard privateArea.identity.sameObject(as: seal.areaIdentity) else { throw FileOperationFailure.sourceChanged }
            let children = try GroupedCopyFilesystemEvidence.children(in: privateArea, cancellation: cancellation, limit: 1)
            let publicParent = try GroupedCopyFilesystemEvidence.checkedParent(member.manifest.destination)
            if member.progress.phase == "published" {
                guard children.isEmpty else { throw FileOperationFailure.recoveryUncertain }
                let entry = try NativeRenameEntry.observe(parent: publicParent, name: member.manifest.destination.name)
                guard entry.nameBytes == member.manifest.destination.nameBytes,
                      entry.identity.sameObject(as: seal.proof.payload.identity) else { throw FileOperationFailure.sourceChanged }
                try GroupedCopyAdmission.requireResidentRegular(parent: publicParent, name: member.manifest.destination.name, expected: entry.identity)
            } else {
                guard children.count == 1, Data(children[0].utf8) == declaration.payloadName else { throw FileOperationFailure.recoveryUncertain }
                let payload = String(decoding: declaration.payloadName, as: UTF8.self)
                let entry = try NativeRenameEntry.observe(parent: privateArea, name: payload)
                guard entry.nameBytes == declaration.payloadName,
                      entry.identity.sameObject(as: seal.proof.payload.identity) else { throw FileOperationFailure.sourceChanged }
                try GroupedCopyAdmission.requireResidentRegular(parent: privateArea, name: payload, expected: entry.identity)
                try requireAbsent(member.manifest.destination.name, in: publicParent.fd)
            }
            try privateArea.validate(); try publicParent.validate()
        }
        for ordinal in group.members {
            try cancellation.check()
            let member = record.members[ordinal]
            if case .neverStaged = member.progress { continue }
            guard let declaration = member.progress.declaration, let seal = member.progress.seal else { throw FileOperationFailure.recoveryUncertain }
            let holder: DirectoryAnchor
            let name: String
            if member.progress.phase == "published" {
                holder = try GroupedCopyFilesystemEvidence.checkedParent(member.manifest.destination)
                name = member.manifest.destination.name
            } else {
                holder = try DirectoryAnchor(root.appendingPathComponent(declaration.areaURL.lastPathComponent, isDirectory: true), resolve: false)
                guard holder.identity.sameObject(as: seal.areaIdentity) else { throw FileOperationFailure.sourceChanged }
                name = String(decoding: declaration.payloadName, as: UTF8.self)
            }
            let entry = try NativeRenameEntry.observe(parent: holder, name: name)
            guard entry.identity.sameObject(as: seal.proof.payload.identity) else { throw FileOperationFailure.sourceChanged }
            let current = try verifiedTree(parent: holder.fd, name: name, cancellation: cancellation)
            let nodes = try snapshotTree(parent: holder.fd, name: name, cancellation: cancellation)
            let matches = allowNativeTrashTransition && member.progress.phase != "published"
                ? seal.proof.payload.matchesNativeTrashTransition(current) : seal.proof.payload.matches(current)
            guard matches, stagingIdentityDigest(nodes) == seal.proof.identityDigest else { throw FileOperationFailure.sourceChanged }
            try holder.validate()
        }
        try area.validate()
    }

    private func groupedRetainedBytes(_ group: GroupedCopyGroup, record: GroupedCopyRecord) throws -> Int64 {
        var bytes: Int64 = 0
        for ordinal in group.members {
            let member = record.members[ordinal]
            guard ["sealed", "undone"].contains(member.progress.phase), let seal = member.progress.seal else { continue }
            let (sum, overflow) = bytes.addingReportingOverflow(seal.proof.payload.identity.size)
            guard !overflow else { throw FileOperationFailure.unsupported }; bytes = sum
        }
        return bytes
    }

    private func groupedRetentionCheckpoint(_ stage: GroupedCopyRetentionCheckpointStage,
        edit: GroupedCopyEditSession, group: Int? = nil, cancellation: OperationCancellation) throws {
        try hooks.groupedRetention.checkpoint?(GroupedCopyRetentionCheckpoint(stage: stage,
            recordID: edit.id, revision: edit.revision, groupOrdinal: group), cancellation)
    }
}
