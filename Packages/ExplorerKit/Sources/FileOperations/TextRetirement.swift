import Darwin
import Foundation

public enum LocalTextRetentionState: String, Codable, Sendable { case retained, pending, retired, unknown }
/// A new editor-retirement contract must be selected explicitly. The default
/// preserves existing Debug and generated-fixture behavior. Ordinary editions
/// select the native-directory contract only through their independent app gate.
public enum LocalTextRetirementPolicy: Sendable, Equatable {
    case held, legacyVerifiedPaths, nativeDirectoryV12
}

private enum TextRetirementContract: Sendable, Equatable { case legacyV4, nativeDirectoryV5 }

internal struct TextRetirementIntentV3: Codable, Equatable, Sendable {
    let before: VerifiedTree
    let head: TextRevisionHeadV2?
    var headEpoch: UUID? = nil
}
/// The event tag is the pre-native reader fence. Older binaries cannot decode
/// a V4 intent and therefore cannot append an older confirmation to its job.
internal struct TextRetirementConfirmationV4: Codable, Equatable, Sendable {
    let returned: URL
    let after: VerifiedTree
    let rootMetadata: NativeTrashRootMetadataProofV4?
}
/// Separate event tag prevents older readers and uncertain V4 histories from
/// inheriting the v12 native-directory metadata rule.
internal struct TextRetirementConfirmationV5: Codable, Equatable, Sendable {
    let returned: URL
    let after: VerifiedTree
    let rootMetadata: NativeTrashRootMetadataProofV4?
    /// Present only when rootMetadata binds this digest to both complete walks.
    let descendantIdentity: Data?

    func validates(before: VerifiedTree, target: URL) -> Bool {
        guard returned.baseURL == nil,
              returned.absoluteString.utf8.elementsEqual(target.absoluteString.utf8),
              before.identity.isDirectory, after.identity.isDirectory,
              before.identity.sameObject(as: after.identity) else { return false }
        if let rootMetadata {
            guard let descendantIdentity, descendantIdentity.count == 32 else { return false }
            return rootMetadata.validatesNativeDirectoryV12(before: before, after: after)
                && rootMetadata.afterDescendantIdentity == descendantIdentity
        }
        return descendantIdentity == nil && before.matchesNativeTrashTransition(after)
    }
}
public struct LocalTextRetirementPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID, review: RecoveryRetentionRecord
    internal let engine: UUID, prefix: RevisionDigest, head: TextRevisionHeadV2?, tree: VerifiedTree
    internal let claim: TextPlanClaimV2
    internal let epochStamp: TextEpochStamp10?
    public var description: String { "Local text retirement plan (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRetirementResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID, status: FileOperationStatus, retention: LocalTextRetentionState
    public let undoEnded: Bool?
    public let knownLocations: [URL]
    /// Native-reported targets without complete stored retirement proof. These
    /// observations never grant cleanup/retry authority or assert availability.
    public let unconfirmedReportedLocations: [URL]
    internal init(recordID: UUID, status: FileOperationStatus, retention: LocalTextRetentionState,
        undoEnded: Bool?, knownLocations: [URL], unconfirmedReportedLocations: [URL] = []) {
        self.recordID = recordID; self.status = status; self.retention = retention
        self.undoEnded = undoEnded; self.knownLocations = knownLocations
        self.unconfirmedReportedLocations = unconfirmedReportedLocations
    }
    public var description: String { "Local text retirement result (private locations omitted)" }
    public var debugDescription: String { description }
}

extension RecoverableFileOperations {
    private var textRetirementContract: TextRetirementContract? {
        switch (localTextRetirementPolicy, nativeTrashPolicy) {
        case (.legacyVerifiedPaths, .existingVerifiedPaths): return .legacyV4
        case (.nativeDirectoryV12, .regularFilesAndDirectories):
            guard case .strict = nativeTrashDirectoryAdmission else { return nil }
            return .nativeDirectoryV5
        default: return nil
        }
    }

    public func prepareLocalTextRetirement(recordID: UUID) async throws -> LocalTextRetirementPlan {
        try await worker { cancellation in
            guard self.textRetirementContract != nil else { throw FileOperationFailure.unsupported }
            return try withoutMaterialization {
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                let record = try journal.textRecordV2(recordID)
                let tree = try self.textRetirementInventory(record, cancellation: cancellation)
                let head = try journal.textHeadV2(slot: record.manifest.slot)
                try journal.reserveTextV2(slot:record.manifest.slot,newJob:false,edges:0)
                let review = try self.textRetentionRecord(record, cancellation: cancellation)
                guard review.canCleanup else { throw FileOperationFailure.recoveryUncertain }
                return LocalTextRetirementPlan(recordID: recordID, review: review, engine: self.continuationSession,
                    prefix: try record.prefix, head: head, tree: tree, claim: TextPlanClaimV2(),
                    epochStamp:try journal.textStamp10(slot:record.manifest.slot))
            }
        }
    }

    public func performLocalTextRetirement(_ plan: LocalTextRetirementPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> LocalTextRetirementResult {
        let reporter = OperationProgressReporter(jobID: plan.recordID, callback: progress)
        let result: LocalTextRetirementResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                guard let contract = self.textRetirementContract else { throw FileOperationFailure.unsupported }
                return try withoutMaterialization {
                    guard plan.engine == self.continuationSession, plan.claim.claim() else { throw FileOperationFailure.invalidRequest }
                    let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                    var record = try journal.textRecordV2(plan.recordID)
                    var retirementAttempted = false
                    var liveReported: [URL] = []
                    var trace = NativeRetirementTraceV4(observer:self.hooks.textEditor.retirementObserved)
                    do {
                        guard try record.prefix == plan.prefix,
                              try journal.textStamp10(slot:record.manifest.slot) == plan.epochStamp,
                              try journal.textHeadV2(slot: record.manifest.slot) == plan.head,
                              try plan.tree.matches(self.textRetirementInventory(record, cancellation: cancellation)) else { throw FileOperationFailure.sourceChanged }
                        try journal.reserveTextV2(slot:record.manifest.slot,newJob:false,edges:0); try cancellation.check()
                        cancellation.progress?.begin(.retaining, source: record.manifest.area, items: 1)
                        retirementAttempted = true
                        let intent = TextRetirementIntentV3(before: plan.tree, head: plan.head,
                            headEpoch: plan.epochStamp?.epoch)
                        let intentEvent: TextRevisionEventV2 = contract == .legacyV4
                            ? .retirementIntentRootMetadataV4(intent) : .retirementIntentNativeDirectoryV5(intent)
                        record = try journal.appendTextV2(record, event: intentEvent)
                        trace.observe(.intentCommitted)
                        let parent = try DirectoryAnchor(record.manifest.area.deletingLastPathComponent(), resolve: false)
                        let pin = try pinEntry(parent: parent.fd, name: record.manifest.area.lastPathComponent, matching: plan.tree.identity)
                        defer { close(pin) }
                        try self.hooks.textEditor.boundary?("beforeRetirementNative", record.id)
                        try cancellation.check()
                        let beforeFamiliesCollector = NativeTrashFamilyCollector()
                        guard plan.tree.matches(try self.textRetirementInventory(record, allowingIntent: true,
                                  cancellation: cancellation, nativeTrashFamilyCollector: beforeFamiliesCollector)) else {
                            throw FileOperationFailure.sourceChanged
                        }
                        guard let beforeFamilies = beforeFamiliesCollector.snapshot() else { throw FileOperationFailure.recoveryUncertain }
                        try journal.validateSelectionOwnership(); try parent.validate()
                        let segment = cancellation.segment(); try segment.beginMutation()
                        let callSource:NativeRetirementCallSourceV4=self.hooks.textEditor.retirementRawCall != nil ? .generatedOverride:self.hooks.retentionTrash != nil ? .retentionHook:.defaultFileManager
                        trace.observe(.nativeBegin,callSource:callSource)
                        let call:NativeRetirementCallV4
                        if let generated = self.hooks.textEditor.retirementRawCall {
                            call = generated(record.manifest.area)
                        } else if let trash = self.hooks.retentionTrash {
                            do { call = .init(raw:try trash(record.manifest.area) as NSURL,error:nil) }
                            catch { call = .init(raw:nil,error:error) }
                        } else {
                            var raw:NSURL?,failure:Error?
                            do { try FileManager().trashItem(at:record.manifest.area,resultingItemURL:&raw) }
                            catch { failure=error }
                            call = .init(raw:raw,error:failure)
                        }
                        // Capture raw flags before bridging. Preserve the actual
                        // private live correlation before observers/admission/write.
                        let rawFlags=call.raw.map(NativeTrashURLFlagsV4.init)
                        let observed=call.raw.map{$0 as URL}
                        if let observed {liveReported.append(observed)}
                        trace.observe(.nativeReturned,returned:call.raw != nil,nativeError:call.error != nil,error:call.error)
                        trace.observe(.rawCaptured,raw:rawFlags,bridged:observed.map{NativeTrashURLFlagsV4($0 as NSURL)},returned:call.raw != nil,nativeError:call.error != nil)
                        var target:URL?
                        if let raw=call.raw {
                            switch NativeTrashURLPolicyV4.admit(raw) {
                            case .accepted(let accepted,let rawFlags,let bridgedFlags):
                                guard plan.tree.identity.isDirectory else{throw FileOperationFailure.recoveryUncertain}
                                switch NativeTrashDirectoryPolicyV5.project(accepted) {
                                case .accepted(let directory):
                                    target=directory.url
                                    trace.observe(.representationAccepted,raw:rawFlags,bridged:bridgedFlags,directoryHintAdded:directory.directoryHintAdded)
                                case .refused(let reason):
                                    trace.observe(.representationRefused,raw:rawFlags,refusal:reason)
                                    throw FileOperationFailure.recoveryUncertain
                                }
                            case .refused(let reason,let flags):
                                trace.observe(.representationRefused,raw:flags,refusal:reason)
                                throw FileOperationFailure.recoveryUncertain
                            }
                        }
                        if let target {
                            trace.observe(.returnedProjectBegin)
                            try self.hooks.textEditor.boundary?("beforeRetirementReturnedProject",record.id)
                            // This is the unchanged canonical reducer guard; it
                            // is separate from lexical admission and not called
                            // a pure/no-filesystem API by these diagnostics.
                            let candidate=try record.appending(.retirementReturned(target))
                            trace.observe(.returnedProjectReady)
                            trace.observe(.returnedEncodingBegin)
                            let encoded=try textEncoded(candidate),decoded=try textDecoded(TextRevisionRecordV2.self,encoded)
                            guard decoded==candidate else{throw FileOperationFailure.recoveryUncertain}
                            trace.observe(.returnedEncodingReady)
                            trace.observe(.returnedCommitDispatch)
                            try self.hooks.textEditor.boundary?("beforeRetirementReturnedCommit",record.id)
                            record=try journal.appendTextV2(record,event:.retirementReturned(target))
                            trace.observe(.returnedCommitAcknowledged)
                            trace.observe(.returnedReadbackBegin)
                            let authoritative=try journal.textRecordV2(record.id)
                            try self.hooks.textEditor.boundary?("retirementReturnedReadbackAcceptance",record.id)
                            let state=try authoritative.project()
                            guard authoritative==candidate,let intent=state.retirement,
                                  (contract == .legacyV4 ? state.retirementRootMetadataV4
                                      && !state.retirementNativeDirectoryV5
                                      : state.retirementNativeDirectoryV5 && !state.retirementRootMetadataV4),
                                  intent.before==plan.tree,
                                  intent.head==plan.head,intent.headEpoch==plan.epochStamp?.epoch,
                                  let durable=state.retirementTarget,durable.baseURL==nil,
                                  durable.absoluteString.utf8.elementsEqual(target.absoluteString.utf8),
                                  !state.retirementConfirmed else{throw FileOperationFailure.recoveryUncertain}
                            record=authoritative
                            // These observations occur only after exact durable
                            // source/Intent/target binding, never as admission.
                            trace.observe(.returnedReadbackReady,
                                equalsStandardized:durable==durable.standardizedFileURL ? .yes:.no,
                                absoluteIsStandardized:durable.absoluteURL==durable.absoluteURL.standardizedFileURL ? .yes:.no,
                                returnedDurable:true,confirmedDurable:false)
                        }
                        try self.hooks.textEditor.boundary?("afterRetirementNative",record.id)
                        if let nativeFailure=call.error {throw nativeFailure}
                        guard let target else{throw FileOperationFailure.recoveryUncertain}
                        trace.observe(.firstVerificationBegin)
                        var firstRootMetadataProof: NativeTrashRootMetadataProofV4?
                        let after=try self.verifyNativeTrashResult(target,before:plan.tree,cancellation:segment,
                            requiresMaterialized:true,recordID:record.id,beforeFamilies:beforeFamilies,
                            ordinaryMode:contract == .legacyV4 ? .retainedTextDirectoryRootNativeMetadata : .strict,
                            ordinaryDirectoryAdmission:contract == .nativeDirectoryV5 ? .nativeRootMetadata : .strict,
                            verifiedRootMetadata:{ firstRootMetadataProof = $0 })
                        trace.observe(.firstVerificationReady)
                        let targetParent=try DirectoryAnchor(target.deletingLastPathComponent(),resolve:false),targetArea=try DirectoryAnchor(target,resolve:false)
                        trace.observe(.sourcePinBegin)
                        try requireAbsent(record.manifest.area.lastPathComponent,in:parent.fd)
                        guard try EntrySnapshot(fd:pin).sameObject(as:after.identity)else{throw FileOperationFailure.recoveryUncertain}
                        trace.observe(.sourcePinReady)
                        trace.observe(.synchronizationBegin)
                        try self.hooks.textEditor.boundary?("beforeRetirementSync",record.id)
                        try syncDirectory(parent);try syncDirectory(targetParent);try syncDirectory(targetArea)
                        trace.observe(.synchronizationReady)
                        try self.hooks.textEditor.boundary?("afterRetirementSync",record.id)
                        trace.observe(.secondVerificationBegin)
                        try self.hooks.textEditor.boundary?("beforeRetirementSecondVerification",record.id)
                        var finalRootMetadataProof: NativeTrashRootMetadataProofV4?
                        let final=try self.verifyNativeTrashResult(target,before:plan.tree,cancellation:segment,
                            requiresMaterialized:true,recordID:record.id,beforeFamilies:beforeFamilies,
                            ordinaryMode:contract == .legacyV4 ? .retainedTextDirectoryRootNativeMetadata : .strict,
                            ordinaryDirectoryAdmission:contract == .nativeDirectoryV5 ? .nativeRootMetadata : .strict,
                            verifiedRootMetadata:{ finalRootMetadataProof = $0 })
                        guard after.matches(final), firstRootMetadataProof == finalRootMetadataProof else {
                            throw FileOperationFailure.sourceChanged
                        }
                        trace.observe(.secondVerificationReady)
                        trace.observe(.confirmationProjectBegin)
                        let confirmationEvent: TextRevisionEventV2
                        switch contract {
                        case .legacyV4:
                            confirmationEvent = .retirementConfirmedRootMetadataV4(
                                .init(returned: target, after: final, rootMetadata: finalRootMetadataProof))
                        case .nativeDirectoryV5:
                            confirmationEvent = .retirementConfirmedNativeDirectoryV5(
                                .init(returned: target, after: final, rootMetadata: finalRootMetadataProof,
                                      descendantIdentity: finalRootMetadataProof?.afterDescendantIdentity))
                        }
                        let candidate=try record.appending(confirmationEvent);_ = try textEncoded(candidate)
                        trace.observe(.confirmationProjectReady)
                        trace.observe(.confirmationCommitDispatch)
                        try self.hooks.textEditor.boundary?("beforeRetirementConfirmationCommit",record.id)
                        record=try journal.appendTextV2(record,event:confirmationEvent)
                        trace.observe(.confirmationCommitAcknowledged)
                        trace.observe(.confirmationReadbackBegin)
                        let confirmed=try journal.textRecordV2(record.id)
                        try self.hooks.textEditor.boundary?("retirementConfirmationReadbackAcceptance",record.id)
                        guard confirmed==candidate,try confirmed.project().retirementConfirmed else{throw FileOperationFailure.recoveryUncertain}
                        record=confirmed;trace.observe(.confirmationReadbackReady,returnedDurable:true,confirmedDurable:true)
                        cancellation.progress?.advance(items:1)
                        trace.observe(.finished,returnedDurable:true,confirmedDurable:true)
                        return self.textRetirementResult(record,status:.succeeded,liveReported:liveReported)
                    } catch {
                        let failedAt=trace.lastStage
                        trace.observe(.failed,error:error,failureStage:failedAt)
                        trace.observe(.failureReadbackBegin)
                        guard let authoritative=try? journal.textRecordV2(plan.recordID)else{
                            return LocalTextRetirementResult(recordID:plan.recordID,status:.failed(.recoveryUncertain),retention:.unknown,
                                undoEnded:nil,knownLocations:[record.manifest.area]+liveReported,unconfirmedReportedLocations:liveReported)
                        }
                        let state=try authoritative.project()
                        trace.observe(.failureReadbackReady,returnedDurable:state.retirementTarget != nil,confirmedDurable:state.retirementConfirmed)
                        let status:FileOperationStatus=retirementAttempted && state.retirement != nil ? .failed(.recoveryUncertain):operationStatus(error)
                        return self.textRetirementResult(authoritative,status:status,liveReported:liveReported)
                    }
                }
            }
        } catch {
            result=LocalTextRetirementResult(recordID:plan.recordID,status:operationStatus(error),retention:.unknown,undoEnded:nil,knownLocations:[])
        }
        reporter.finish(success:result.status == .succeeded);return result
    }

    private func textRetirementResult(_ record: TextRevisionRecordV2, status: FileOperationStatus,
        liveReported: [URL] = []) -> LocalTextRetirementResult {
        guard let state = try? record.project() else {
            return LocalTextRetirementResult(recordID: record.id, status: .failed(.recoveryUncertain), retention: .unknown,
                undoEnded: nil, knownLocations: [record.manifest.area] + liveReported, unconfirmedReportedLocations: liveReported)
        }
        var reported: [URL] = []
        for url in [state.retirementTarget].compactMap({ $0 }) + liveReported where !reported.contains(url) { reported.append(url) }
        return LocalTextRetirementResult(recordID: record.id, status: status,
            retention: state.retirementConfirmed ? .retired : state.retirement == nil ? .retained : .pending,
            undoEnded: state.retirement != nil, knownLocations: [record.manifest.area] + reported,
            unconfirmedReportedLocations: state.retirementConfirmed ? [] : reported)
    }

    internal func textRetirementInventory(_ record: TextRevisionRecordV2, allowingIntent: Bool = false,
        cancellation: OperationCancellation, nativeTrashFamilyCollector: NativeTrashFamilyCollector? = nil) throws -> VerifiedTree {
        let state = try record.project()
        guard [.committed, .undone, .notApplied].contains(state.state),
              state.retirement == nil || (allowingIntent && state.retirementTarget == nil && !state.retirementConfirmed),
              record.events.count <= TextRevisionRecordV2.maximumEvents - (allowingIntent ? 2 : 3) else { throw FileOperationFailure.recoveryUncertain }
        let area = try textArea(record)
        var names = [".traverse-text-owner"]
        for attempt in state.attempts {
            try cancellation.check()
            guard attempt.ready != nil else { continue }
            let child = try textAttemptArea(record, attempt: attempt)
            names.append(child.url.lastPathComponent)
            var expected = [".traverse-text-owner"]
            if let custody = attempt.custody {
                guard try TextPinnedFileV2(child.url.appendingPathComponent("before"), cancellation: cancellation).witness == custody.before.copy,
                      try TextPinnedFileV2(child.url.appendingPathComponent("submitted"), cancellation: cancellation).witness == custody.submitted.edited else { throw FileOperationFailure.sourceChanged }
                expected += ["before", "submitted"]
            }
            guard Set(try GroupedCopyFilesystemEvidence.children(in: child, cancellation: cancellation, limit: 5)) == Set(expected) else { throw FileOperationFailure.conflict }
        }
        guard Set(try GroupedCopyFilesystemEvidence.children(in: area, cancellation: cancellation, limit: 6)) == Set(names) else { throw FileOperationFailure.conflict }
        let tree = try verifiedTree(record.manifest.area, cancellation: cancellation, requiresMaterialized: true,
            nativeTrashFamilyCollector: nativeTrashFamilyCollector)
        guard tree.identity.sameObject(as: record.manifest.areaIdentity) else { throw FileOperationFailure.sourceChanged }
        return tree
    }

    internal func textRetentionRecord(_ record: TextRevisionRecordV2, cancellation: OperationCancellation) throws -> RecoveryRetentionRecord {
        let state = try record.project()
        var reason: String?, verified = false
        if state.retirementConfirmed { reason = "Retained text versions were moved to Trash; Undo has ended." }
        else if state.retirement != nil { reason = "Retirement has an unconfirmed native boundary; retained evidence remains protected." }
        else if ![.committed, .undone, .notApplied].contains(state.state) { reason = "The Save or Undo outcome is unconfirmed; its versions remain protected." }
        else {
            do { _ = try textRetirementInventory(record, cancellation: cancellation); verified = true }
            catch is CancellationError { throw CancellationError() }
            catch { reason = "Retained files are changed, unsealed, incomplete or unavailable; they remain protected." }
        }
        let locations = [record.manifest.area] + [state.retirementTarget].compactMap { $0 }
        return RecoveryRetentionRecord(id: record.id, operation: "Save Text", createdAt: record.manifest.createdAt,
            state: state.state.rawValue, areas: locations.map { RecoveryRetentionArea(url: $0, logicalBytes: nil, verified: verified, protectionReason: reason) },
            logicalBytes: nil, canCleanup: verified, protectionReason: reason)
    }
}
