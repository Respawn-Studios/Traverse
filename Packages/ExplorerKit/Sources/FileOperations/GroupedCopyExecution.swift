import Darwin
import Foundation

internal enum GroupedCopyCheckpointStage: String, Codable, Sendable, CaseIterable {
    case manifestWillCommit, manifestCommitted
    case groupWillDeclare, groupDeclared, groupCreated
    case memberWillStage, memberStaged, groupWillSeal, groupSealed
    case memberWillPublish, memberPublished, memberSynced
    case groupWillRecordOutcomes, groupOutcomesRecorded
    case terminalWillCommit, terminalCommitted
}
internal struct GroupedCopyCheckpoint: Sendable {
    let stage: GroupedCopyCheckpointStage
    let jobID: UUID
    let recordID: UUID
    let groupOrdinal: Int?
    let memberOrdinal: Int?
}
internal struct GroupedCopyHooks: Sendable {
    var qualification: GroupedCopyQualification? = nil
    /// Throw to simulate failure, call cancellation.cancel() for Stop, or _exit in
    /// a fixture worker. After rename the engine drains the current safe segment.
    var checkpoint: (@Sendable (GroupedCopyCheckpoint, OperationCancellation) throws -> Void)? = nil
}

extension RecoverableFileOperations {
    internal func executeGroupedCopy(_ plan: TransferPlan, admission: GroupedCopyAdmission,
                                     resolutions: [UUID: TransferConflictResolution],
                                     cancellation: OperationCancellation) -> RecoverableOperationResult {
        var journal: OperationJournal?
        var edit: GroupedCopyEditSession?
        var acknowledged: GroupedCopyRecord?
        var activeMember: Int?
        var activeGroup: Int?
        var groupCreationAttempted = false
        var stageAttempted = Set<Int>()
        var publishedThisSession = Set<Int>()
        var failure: Error?

        func checkpoint(_ stage: GroupedCopyCheckpointStage, group: Int? = nil, member: Int? = nil) throws {
            guard let edit else { throw FileOperationFailure.recoveryUncertain }
            try hooks.groupedCopy.checkpoint?(GroupedCopyCheckpoint(stage: stage, jobID: plan.jobID,
                recordID: edit.id, groupOrdinal: group, memberOrdinal: member), cancellation)
        }
        func save() throws {
            guard let journal, let edit else { throw FileOperationFailure.recoveryUncertain }
            try journal.save(edit)
            acknowledged = edit.snapshot
        }
        func close() throws {
            guard let edit else { throw FileOperationFailure.recoveryUncertain }
            try checkpoint(.terminalWillCommit)
            try edit.close(); try save()
            try checkpoint(.terminalCommitted)
        }
        do {
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            for entry in plan.entries {
                try protection.requireEntry(entry.source); try protection.requireEntry(entry.destination)
            }
            guard !plan.isMove, plan.continuation == nil, resolutions.isEmpty,
                  admission.members.count == plan.entries.count,
                  admission.itemIDs == plan.entries.map(\.id),
                  hooks.groupedCopy.qualification != nil || admission.qualification.production != nil else { throw FileOperationFailure.invalidRequest }
            try cancellation.check()
            try admission.revalidate(journal: directory, cancellation: cancellation)
            hooks.afterAdmission?()
            try cancellation.check()
            for entry in plan.entries {
                try protection.requireEntry(entry.source); try protection.requireEntry(entry.destination)
            }
            // Production requires its original already-upgraded catalog. The
            // established fixture route retains its explicit qualification upgrade.
            let store = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation,
                existingGroupedSession: admission.qualification.production)
            journal = store
            try protection.historyOpened(store.anchor)
            if admission.qualification.production == nil { try store.upgradeForGroupedCopy() }
            try admission.revalidate(journal: directory, cancellation: cancellation)
            let session = try store.beginGroupedEdit(members: admission.members,
                groupSize: admission.qualification.groupSize, metadataPolicy: plan.metadataPolicy)
            edit = session
            try checkpoint(.manifestWillCommit); try save(); try checkpoint(.manifestCommitted)
            for start in stride(from: 0, to: admission.members.count, by: admission.qualification.groupSize) {
                try autoreleasepool(invoking: {
                    activeGroup = start / admission.qualification.groupSize
                    let groupOrdinal = activeGroup!
                    groupCreationAttempted = false
                    activeMember = nil
                    try cancellation.check()
                    try checkpoint(.groupWillDeclare, group: groupOrdinal)
                    try cancellation.check()
                    let destination = try GroupedCopyFilesystemEvidence.checkedParent(admission.members[start].destination)
                    let groupURL = destination.url.appendingPathComponent(".mac-explorer-group-" + session.id.uuidString + "-" + String(groupOrdinal), isDirectory: true)
                    let ordinals = Array(start..<min(start + admission.qualification.groupSize, admission.members.count))
                    let memberURLs = ordinals.map { groupURL.appendingPathComponent("member-" + String($0), isDirectory: true) }
                    try requireAbsent(groupURL.lastPathComponent, in: destination.fd)
                    try session.declareGroup(areaURL: groupURL, memberAreaURLs: memberURLs)
                    try save(); try checkpoint(.groupDeclared, group: groupOrdinal)
                    try cancellation.check(); try destination.validate()
                    try protection.requireEntry(parent: destination, name: groupURL.lastPathComponent)
                    groupCreationAttempted = true
                    guard mkdirat(destination.fd, groupURL.lastPathComponent, 0o700) == 0 else { throw posixFailure() }
                    let group = try DirectoryAnchor(groupURL, resolve: false)
                    try session.recordGroupIdentity(group.identity, at: groupOrdinal)
                    try OperationJournal.writeExclusive(session.snapshot.groups[groupOrdinal].marker,
                        name: GroupedCopyGroup.markerName, anchor: group)
                    try hooks.beforeSync?(groupURL); try syncDirectory(group); try syncDirectory(destination)
                    try checkpoint(.groupCreated, group: groupOrdinal)
                    for ordinal in ordinals {
                        activeMember = ordinal
                        try cancellation.check()
                        try checkpoint(.memberWillStage, group: groupOrdinal, member: ordinal)
                        try cancellation.check()
                        let member = admission.members[ordinal]
                        let source = try GroupedCopyFilesystemEvidence.checkedParent(member.source)
                        try GroupedCopyAdmission.requireResidentRegular(parent: source, name: member.source.name, expected: member.sourceTree.identity)
                        guard member.sourceTree.matches(try verifiedTree(parent: source.fd, name: member.source.name, cancellation: cancellation)) else { throw FileOperationFailure.sourceChanged }
                        try validateGroupedArea(group, recorded: session.snapshot.groups[groupOrdinal], cancellation: cancellation)
                        let publicParent = try GroupedCopyFilesystemEvidence.checkedParent(member.destination)
                        try protection.requireEntry(parent: source, name: member.source.name)
                        try protection.requireEntry(parent: publicParent, name: member.destination.name)
                        try requireAbsent(member.destination.name, in: publicParent.fd)
                        let areaURL = memberURLs[ordinal - start]
                        stageAttempted.insert(ordinal)
                        guard mkdirat(group.fd, areaURL.lastPathComponent, 0o700) == 0 else { throw posixFailure() }
                        let area = try DirectoryAnchor(areaURL, resolve: false)
                        let receipts = StagingCopyReceipts(), security = NativeCopyReceipts()
                        cancellation.progress?.begin(.copying, source: member.source.url, destination: member.destination.url,
                            index: ordinal + 1, count: admission.members.count, bytes: member.sourceTree.identity.size, items: 1)
                        try copyVerifiedNode(sourceParent: source.fd, sourceName: member.source.name, destinationParent: area.fd,
                            destinationName: "payload", originalDevice: member.sourceTree.identity.device, cancellation: cancellation,
                            faults: hooks.copyFaults, completed: { try receipts.completed($0, $1) }, securityReceipt: { try security.append($0) })
                        cancellation.progress?.begin(.verifying, source: member.source.url, destination: member.destination.url,
                            index: ordinal + 1, count: admission.members.count, bytes: member.sourceTree.identity.size * 2, items: 2)
                        let sourceComparison = CopyComparison(), payloadComparison = CopyComparison()
                        guard member.sourceTree.matches(try verifiedTree(parent: source.fd, name: member.source.name,
                            cancellation: cancellation, copyComparison: sourceComparison)) else { throw FileOperationFailure.sourceChanged }
                        let payload = try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation, copyComparison: payloadComparison)
                        try security.validate(source: sourceComparison, destination: payloadComparison, policy: plan.metadataPolicy)
                        let payloadURL = areaURL.appendingPathComponent("payload")
                        cancellation.progress?.begin(.syncing, source: member.source.url, destination: member.destination.url, items: 1)
                        try hooks.beforeSync?(payloadURL); try syncTree(payloadURL, cancellation: cancellation)
                        try syncDirectory(area); try syncDirectory(group); try syncDirectory(destination)
                        try hooks.beforeStagingProof?(session.id)
                        let proof = try receipts.proof(parent: area.fd, payload: payload, stepCount: 0, cancellation: cancellation)
                        guard payload.matches(try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation)),
                              try NativeRenameEntry.observe(parent: source, name: member.source.name).nameBytes == member.source.nameBytes else { throw FileOperationFailure.sourceChanged }
                        try source.validate(); try area.validate(); try validateGroupedArea(group, recorded: session.snapshot.groups[groupOrdinal], cancellation: cancellation)
                        try session.recordSeal(GroupedCopySeal(version: 1, metadataPolicy: plan.metadataPolicy,
                            receiptVersion: 1, areaIdentity: area.identity, proof: proof), member: ordinal)
                        try checkpoint(.memberStaged, group: groupOrdinal, member: ordinal)
                    }
                    activeMember = nil
                    try checkpoint(.groupWillSeal, group: groupOrdinal)
                    try session.sealGroup(groupOrdinal); try save()
                    try hooks.afterStagingProof?()
                    try checkpoint(.groupSealed, group: groupOrdinal)
                    for ordinal in ordinals {
                        activeMember = ordinal
                        try cancellation.check()
                        try checkpoint(.memberWillPublish, group: groupOrdinal, member: ordinal)
                        try cancellation.check()
                        guard case .sealed(let declaration, let seal) = session.snapshot.members[ordinal].progress else { throw FileOperationFailure.recoveryUncertain }
                        let member = admission.members[ordinal]
                        let source = try GroupedCopyFilesystemEvidence.checkedParent(member.source)
                        let target = try GroupedCopyFilesystemEvidence.checkedParent(member.destination)
                        let area = try DirectoryAnchor(declaration.areaURL, resolve: false)
                        guard area.identity.sameObject(as: seal.areaIdentity) else { throw FileOperationFailure.destinationChanged }
                        try validateGroupedArea(group, recorded: session.snapshot.groups[groupOrdinal], cancellation: cancellation)
                        hooks.beforeCommit?(); hooks.beforeRename?()
                        try hooks.beforeExclusiveRename?(declaration.areaURL.appendingPathComponent("payload"), member.destination.url)
                        try cancellation.check()
                        try GroupedCopyAdmission.requireResidentRegular(parent: source, name: member.source.name, expected: member.sourceTree.identity)
                        guard member.sourceTree.matches(try verifiedTree(parent: source.fd, name: member.source.name, cancellation: cancellation)),
                              try NativeRenameEntry.observe(parent: source, name: member.source.name).nameBytes == member.source.nameBytes,
                              seal.proof.payload.matches(try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation)),
                              try GroupedCopyFilesystemEvidence.children(in: area, cancellation: cancellation, limit: 2) == ["payload"] else { throw FileOperationFailure.sourceChanged }
                        let pinned = try pinEntry(parent: area.fd, name: "payload", matching: seal.proof.payload.identity)
                        defer { Darwin.close(pinned) }
                        try source.validate(); try area.validate(); try target.validate()
                        try requireAbsent(member.destination.name, in: target.fd)
                        try protection.requireEntry(parent: source, name: member.source.name)
                        try protection.requireEntry(parent: target, name: member.destination.name)
                        let segment = cancellation.segment()
                        try segment.beginMutation()
                        cancellation.progress?.begin(.publishing, source: member.source.url, destination: member.destination.url,
                            index: ordinal + 1, count: admission.members.count)
                        try exclusiveRename(from: area.fd, name: "payload", to: target.fd, name: member.destination.name)
                        publishedThisSession.insert(ordinal)
                        hooks.afterRename?()
                        try checkpoint(.memberPublished, group: groupOrdinal, member: ordinal)
                        // Stop after rename cannot interrupt synchronization/verification.
                        let draining = segment.draining()
                        cancellation.progress?.begin(.syncing, source: member.source.url, destination: member.destination.url)
                        try hooks.beforeSync?(member.destination.url)
                        try syncDirectory(area); try syncDirectory(target)
                        try area.validate(); try target.validate(); try validateGroupedArea(group, recorded: session.snapshot.groups[groupOrdinal], cancellation: draining)
                        let outcome = try verifiedTree(parent: target.fd, name: member.destination.name, cancellation: draining)
                        guard seal.proof.payload.matches(outcome), try EntrySnapshot(fd: pinned).sameObject(as: outcome.identity),
                              try NativeRenameEntry.observe(parent: target, name: member.destination.name).nameBytes == member.destination.nameBytes else { throw FileOperationFailure.recoveryUncertain }
                        try requireAbsent("payload", in: area.fd)
                        try session.recordPublication(outcome, member: ordinal)
                        try checkpoint(.memberSynced, group: groupOrdinal, member: ordinal)
                    }
                    activeMember = nil
                    try checkpoint(.groupWillRecordOutcomes, group: groupOrdinal)
                    try session.settleGroup(groupOrdinal); try save()
                    try checkpoint(.groupOutcomesRecorded, group: groupOrdinal)
                    activeGroup = nil
                })
            }
            try close()
        } catch {
            failure = error
            // No cold reopen grants forward capability. A failed/uncertain save
            // invalidates this session; leave its last durable evidence untouched.
            if let edit, edit.valid, let journal {
                do {
                    if let ordinal = activeGroup, edit.snapshot.groups.indices.contains(ordinal) {
                        let group = edit.snapshot.groups[ordinal]
                        for member in group.members where edit.snapshot.members[member].progress.phase == "declared" && !stageAttempted.contains(member) {
                            try edit.recordNeverStaged(member: member)
                        }
                        if !groupCreationAttempted, group.areaIdentity == nil {
                            try edit.recordGroupNeverCreated(ordinal)
                        } else if edit.snapshot.groups[ordinal].areaIdentity != nil,
                                  edit.snapshot.groups[ordinal].members.allSatisfy({ ["sealed", "neverStaged", "published"].contains(edit.snapshot.members[$0].progress.phase) }) {
                            if edit.snapshot.groups[ordinal].phase == .declared { try edit.sealGroup(ordinal) }
                            if edit.snapshot.groups[ordinal].phase == .sealed { try edit.settleGroup(ordinal) }
                        }
                    }
                    if error is CancellationError, edit.snapshot.groups.allSatisfy({ $0.phase == .settled }) {
                        try edit.close()
                    } else { try edit.markNeedsReview() }
                    try journal.save(edit); acknowledged = edit.snapshot
                } catch { /* Preserve the original failure and require cold inspection. */ }
            }
        }
        var items: [FileOperationOutcome] = []
        let locations = edit?.snapshot.groups.map(\.areaURL) ?? []
        for (ordinal, entry) in plan.entries.enumerated() {
            let confirmed = acknowledged?.members[ordinal].progress.publication != nil
            let status: FileOperationStatus
            if confirmed { status = .succeeded }
            else if publishedThisSession.contains(ordinal) { status = .failed(.recoveryUncertain) }
            else if ordinal == activeMember, let failure { status = operationStatus(failure) }
            else { status = .notStarted }
            items.append(FileOperationOutcome(source: entry.source, destination: entry.destination, status: status,
                recoveryURLs: status == .succeeded ? [] : locations, itemID: entry.id, rootID: entry.id, rootSource: entry.source))
        }
        if let failure, !items.contains(where: { if case .failed = $0.status { return true }; return $0.status == .cancelled }) {
            items.append(FileOperationOutcome(source: nil, destination: nil, status: operationStatus(failure), recoveryURLs: locations, role: .job))
        }
        let continuation = edit?.valid == true ? acknowledged.flatMap {
            groupedContinuation(plan: plan, admission: admission, record: $0)
        } : nil
        return RecoverableOperationResult(result: FileOperationResult(items: items, cancellationRequested: cancellation.isCancelled),
            recordID: edit?.id, continuation: continuation)
    }

    private func validateGroupedArea(_ anchor: DirectoryAnchor, recorded: GroupedCopyGroup, cancellation: OperationCancellation) throws {
        guard let identity = recorded.areaIdentity, anchor.identity.sameObject(as: identity) else { throw FileOperationFailure.recoveryUncertain }
        try anchor.validate()
        let marker = try NativeRenameEntry.observe(parent: anchor, name: GroupedCopyGroup.markerName)
        guard marker.nameBytes == Data(GroupedCopyGroup.markerName.utf8), marker.identity.size <= 256,
              try OperationJournal.read(name: GroupedCopyGroup.markerName, anchor: anchor) == recorded.marker else { throw FileOperationFailure.recoveryUncertain }
        let allowed = Set(recorded.members.map { Data(("member-" + String($0)).utf8) } + [Data(GroupedCopyGroup.markerName.utf8)])
        for name in try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: allowed.count + 1) {
            let entry = try NativeRenameEntry.observe(parent: anchor, name: name)
            guard allowed.contains(entry.nameBytes), entry.nameBytes == Data(name.utf8),
                  name == GroupedCopyGroup.markerName || entry.identity.type == S_IFDIR else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}
