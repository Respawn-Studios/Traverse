import Foundation

/// Separate from ordinary tree-record dependencies. Never grants cold resumption.
internal struct GroupedCopyContinuationRecord: Sendable {
    let owner: UUID
    let id: UUID
    let revision: Int
    let memberOrdinals: [Int]
}

extension RecoverableFileOperations {
    internal func groupedContinuation(plan: TransferPlan, admission: GroupedCopyAdmission,
                                     record: GroupedCopyRecord) -> TransferContinuation? {
        guard record.head.state == .stoppedSettled, !record.head.undoInvalidated,
              record.head.reviewIntent == nil, record.members.count == plan.entries.count else { return nil }
        let ordinals = record.members.filter { $0.progress.phase == "notDeclared" }.map(\.ordinal)
        guard !ordinals.isEmpty else { return nil }
        let units = ordinals.map { ordinal -> ContinuationUnit in
            let tree = admission.members[ordinal].sourceTree
            return ContinuationUnit(entry: plan.entries[ordinal],
                source: ContinuationGuard(tree: tree, identities: ["": tree.identity]), destination: nil)
        }
        let roots = Dictionary(uniqueKeysWithValues: ordinals.map { ordinal in
            let entry = plan.entries[ordinal]
            return (entry.id, ContinuationRoot(id: entry.id, source: entry.source))
        })
        return TransferContinuation(id: UUID(), previousJobID: plan.jobID, previousRecordID: record.head.id,
            remainingSources: units.map { $0.entry.source }, destinationDirectory: plan.destinationDirectory,
            isMove: false, metadataPolicy: plan.metadataPolicy, session: continuationSession, units: units,
            records: [], containers: [], roots: roots, use: ContinuationUse(),
            groupedRecords: [GroupedCopyContinuationRecord(owner: record.head.owner, id: record.head.id,
                revision: record.head.revision, memberOrdinals: ordinals)])
    }

    internal func validateGroupedContinuationDependencies(_ token: TransferContinuation, journal: OperationJournal?,
                                                          cancellation: OperationCancellation) throws {
        guard token.records.count + token.groupedRecords.count <= OperationJournal.maximumInputs else { throw FileOperationFailure.unsupported }
        for dependency in token.groupedRecords {
            try cancellation.check()
            guard let journal, case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(dependency.id),
                  record.head.owner == dependency.owner, record.head.revision == dependency.revision,
                  record.head.state == .stoppedSettled, !record.head.undoInvalidated, record.head.reviewIntent == nil,
                  !dependency.memberOrdinals.isEmpty, dependency.memberOrdinals.count <= OperationJournal.maximumInputs,
                  Set(dependency.memberOrdinals).count == dependency.memberOrdinals.count,
                  dependency.memberOrdinals.allSatisfy({ record.members.indices.contains($0) && record.members[$0].progress.phase == "notDeclared" }) else { throw FileOperationFailure.recoveryUncertain }
            let observed = try GroupedCopyFilesystemEvidence.inspect(record, cancellation: cancellation)
            guard try GroupedCopyRecoveryClassifier.classify(record, observed: observed).fullyAccounted else { throw FileOperationFailure.recoveryUncertain }
            // Original admitted guards remain authoritative even after a later
            // ordinary continuation narrows this set to its still-untouched tail.
            for unit in token.units {
                guard let ordinal = dependency.memberOrdinals.first(where: {
                    OperationJournal.sameURLRepresentation(record.members[$0].manifest.source.url, unit.entry.source)
                    && OperationJournal.sameURLRepresentation(record.members[$0].manifest.destination.url, unit.entry.destination)
                }) else { throw FileOperationFailure.recoveryUncertain }
                let manifest = record.members[ordinal].manifest
                guard manifest.sourceTree == unit.source.tree,
                      unit.source.identities == ["": manifest.sourceTree.identity], unit.destination == nil,
                      unit.entry.sourceIdentity == manifest.sourceTree.identity,
                      unit.entry.sourceParent.sameObject(as: manifest.source.parentIdentity),
                      unit.entry.destinationParent.sameObject(as: manifest.destination.parentIdentity),
                      unit.entry.destinationIdentity == nil, unit.entry.children == nil,
                      token.metadataPolicy == record.head.metadataPolicy, !token.isMove else { throw FileOperationFailure.recoveryUncertain }
            }
        }
    }
}
