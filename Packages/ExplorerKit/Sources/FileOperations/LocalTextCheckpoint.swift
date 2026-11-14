import Foundation

extension LocalTextCapacityInspection {
    internal static var unavailable10:Self {
        .init(epochID:nil,generation:0,activeRecords:0,activeEdges:0,recordLimit:64,edgeLimit:128,
              canSave:false,canCheckpoint:false,saveRefusal:.metadataUnavailable,checkpointRefusal:.metadataUnavailable,
              canSaveAdoptingExternalBaseline:false,baselineSaveRefusal:.metadataUnavailable)
    }
}
extension TextCheckpoint10 {
    var receipt:LocalTextCheckpointReceipt {
        .init(checkpointID:id,previousEpochID:old.epoch,epochID:nextEpoch,endedUndoCount:endedUndoCount,
              retainedRecords:members.count,baselineAdopted:baselineAdopted)
    }
}
public struct LocalTextRecoveryExportPage:Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    public let exports:[LocalTextRecoveryExportInspection]
    public let nextOrdinal:Int?
    public var description:String {"Local text export page (private observations omitted)"}
    public var debugDescription:String {description}
}
extension RecoverableFileOperations {
    internal func textRequireHistory10(cancellation:OperationCancellation) throws {
        guard try OperationHistoryInspector.textRead10(directory,cancellation:cancellation,{store in
            try store.requireTextPublication10();return true
        }) == true else {throw LocalTextCapacityReason.upgradeRequired}
    }
    public func inspectLocalTextWriteCapacity(from token:LocalTextReadToken) async throws -> LocalTextCapacityInspection {
        guard token.engine == continuationSession else {throw FileOperationFailure.invalidRequest}
        return try await worker { cancellation in
            try withoutMaterialization {
                do {
                    guard let value = try OperationHistoryInspector.textRead10(self.directory,cancellation:cancellation,{store -> LocalTextCapacityInspection in
                        let choice = try store.textSelectedSlotV4(target:token.url,parent:token.parent,witness:token.witness)
                        let planning = try store.textSavePlanningV3(slot:choice.slot)
                        var checkpointRefusal:LocalTextCapacityReason?
                        do {_ = try store.checkpointPreparation10(slot:choice.slot)}
                        catch {checkpointRefusal = error as? LocalTextCapacityReason ?? .metadataUnavailable}
                        let changed=planning.head.map { head in
                            choice.manifestVersion == 4
                                ? !head.witness.samePersistentObservation(token.witness, qualifiedVolume: token.witness.volume)
                                : head.witness != token.witness
                        } ?? false
                        if changed {checkpointRefusal = .sourceChanged}
                        let full=planning.records >= 64 || planning.edges >= 128
                        let saveRefusal:LocalTextCapacityReason? = changed ? .sourceChanged:planning.storeRefusal ?? (full ? .checkpointRequired:nil)
                        let baselineRefusal:LocalTextCapacityReason? = planning.storeRefusal ?? (planning.records >= 64 || planning.edges+(changed ? 2:1)>128 ? .checkpointRequired:nil)
                        return .init(epochID:planning.stamp?.epoch,generation:planning.stamp?.generation ?? 0,
                            activeRecords:planning.records,activeEdges:planning.edges,recordLimit:64,edgeLimit:128,
                            canSave:saveRefusal == nil,canCheckpoint:checkpointRefusal == nil,
                            saveRefusal:saveRefusal,checkpointRefusal:checkpointRefusal,
                            canSaveAdoptingExternalBaseline:baselineRefusal == nil,baselineSaveRefusal:baselineRefusal)
                    }) else {return .unavailable10}
                    return value
                } catch {
                    let reason = error as? LocalTextCapacityReason ??
                        ((error as? FileOperationFailure) == .legacyTextHistoryRequiresReview ? .legacyHistoryRequiresReview : .metadataUnavailable)
                    return .init(epochID:nil,generation:0,activeRecords:0,activeEdges:0,recordLimit:64,edgeLimit:128,
                        canSave:false,canCheckpoint:false,saveRefusal:reason,checkpointRefusal:reason,
                        canSaveAdoptingExternalBaseline:false,baselineSaveRefusal:reason)
                }
            }
        }
    }
    public func prepareLocalTextCheckpoint(from token:LocalTextReadToken) async throws -> LocalTextCheckpointPlan {
        try await prepareCheckpoint10(from:token,adoptingExternalBaseline:false)
    }
    public func prepareLocalTextCheckpointAdoptingExternalBaseline(from token:LocalTextReadToken) async throws -> LocalTextCheckpointPlan {
        try await prepareCheckpoint10(from:token,adoptingExternalBaseline:true)
    }
    private func prepareCheckpoint10(from token:LocalTextReadToken,adoptingExternalBaseline:Bool) async throws -> LocalTextCheckpointPlan {
        guard token.engine == continuationSession else {throw FileOperationFailure.invalidRequest}
        return try await worker {cancellation in
            try withoutMaterialization {
                try self.textRequireSource(token.url,cancellation:cancellation)
                let file = try TextPinnedFileV2(token.url,cancellation:cancellation)
                guard file.parent.identity.sameObject(as:token.parent),file.witness == token.witness else {throw LocalTextCapacityReason.sourceChanged}
                guard let selected = try OperationHistoryInspector.textRead10(self.directory,cancellation:cancellation,{store in
                    let choice = try store.textSelectedSlotV4(target:token.url,parent:token.parent,witness:token.witness)
                    return (choice,try store.checkpointPreparation10(slot:choice.slot))
                }) else {throw LocalTextCapacityReason.nothingToCheckpoint}
                let (choice,value) = selected
                guard
                      let stamp = value.planning.stamp,let head = value.planning.head else {throw LocalTextCapacityReason.nothingToCheckpoint}
                let sameHead = choice.manifestVersion == 4
                    ? head.witness.samePersistentObservation(token.witness, qualifiedVolume: file.volume)
                    : head.witness == token.witness
                guard adoptingExternalBaseline || sameHead else {throw LocalTextCapacityReason.sourceChanged}
                return .init(review:.init(checkpointID:UUID(),epochID:stamp.epoch,retainedRecords:value.members.count,
                    endedUndoCount:value.ended,adoptsExternalBaseline:!sameHead),
                    engine:self.continuationSession,token:token,slot:choice.slot,manifestVersion:choice.manifestVersion,
                    stamp:stamp,maintenance:value.planning.maintenance,
                    memberPrefixes:value.members,claim:TextPlanClaimV2())
            }
        }
    }
    public func performLocalTextCheckpoint(_ plan:LocalTextCheckpointPlan) async -> LocalTextCheckpointResult {
        do {
            return try await worker {cancellation in
                try withoutMaterialization {
                    guard plan.engine == self.continuationSession,plan.claim.claim() else {throw LocalTextCapacityReason.stalePlan}
                    try self.textRequireSource(plan.token.url,cancellation:cancellation)
                    let file = try TextPinnedFileV2(plan.token.url,cancellation:cancellation)
                    guard file.parent.identity.sameObject(as:plan.token.parent),file.witness == plan.token.witness else {throw LocalTextCapacityReason.sourceChanged}
                    let journal = try OperationJournal(self.directory,hooks:self.hooks.journalHooks,cancellation:cancellation)
                    let choice = try journal.textSelectedSlotV4(target:file.url,parent:file.parent.identity,witness:file.witness)
                    guard choice.slot == plan.slot, choice.manifestVersion == plan.manifestVersion else {throw LocalTextCapacityReason.stalePlan}
                    var mutationEntered=false
                    do {
                        try self.hooks.textEditor.boundary?("beforeCheckpoint",plan.review.checkpointID)
                        // The closure owns transaction entry and reconciliation.
                        // Once called, missing readback is never negative proof.
                        let cut = try journal.performCheckpoint10(plan,mutationEntry:{mutationEntered=true},validateSource:{try file.validate(cancellation:cancellation)})
                        try self.hooks.textEditor.boundary?("afterCheckpoint",cut.id)
                        let authoritative = try journal.confirmCheckpoint10(cut)
                        try file.validate(cancellation:cancellation.draining())
                        return .completed(authoritative.receipt)
                    } catch {
                        // Even an exact authoritative readback does not turn this
                        // failed acknowledgement into a completed live request.
                        return mutationEntered ? .uncertain(checkpointID:plan.review.checkpointID):.refused(error as? LocalTextCapacityReason ?? .metadataUnavailable)
                    }
                }
            }
        } catch {
            return .refused(error as? LocalTextCapacityReason ?? .metadataUnavailable)
        }
    }
    public func inspectLocalTextCheckpoint(checkpointID:UUID) async throws -> LocalTextCheckpointInspection {
        try await worker {cancellation in
            guard let cut = try OperationHistoryInspector.textRead10(self.directory,cancellation:cancellation,{try $0.checkpoint10(checkpointID)}) ?? nil else {throw FileOperationFailure.notFound}
            return .init(receipt:cut.receipt,metadataIsDurable:true)
        }
    }
    public func inspectLocalTextRecoveryExportPage(recordID:UUID,afterOrdinal:Int? = nil,limit:Int = 64) async throws -> LocalTextRecoveryExportPage {
        guard (1...64).contains(limit),afterOrdinal.map({(-1..<10_000).contains($0)}) ?? true else {throw FileOperationFailure.invalidRequest}
        return try await worker {cancellation in
            guard let values = try OperationHistoryInspector.textRead10(self.directory,cancellation:cancellation,{store in
                _ = try store.textRecordV2(recordID)
                return try store.textExportsV2(recordID,after:afterOrdinal,limit:limit)
            }) else {throw FileOperationFailure.notFound}
            let inspections = values.map{LocalTextRecoveryExportInspection(exportID:$0.id,recordID:recordID,attemptID:$0.attemptID,
                direction:$0.direction,outcomes:self.textExportOutcomes($0))}
            return .init(exports:inspections,nextOrdinal:values.count == limit ? values.last?.ordinal:nil)
        }
    }
    /// Explicit expensive audit; ordinary selected operations do not imply it.
    public func auditLocalTextHistory() async throws {
        try await worker {cancellation in
            guard try OperationHistoryInspector.textRead10(self.directory,cancellation:cancellation,seconds:60,maximumCallbacks:500_000,{store in
                try store.validateCatalog(cancellation:cancellation);return true
            }) == true else {throw FileOperationFailure.notFound}
        }
    }
}
