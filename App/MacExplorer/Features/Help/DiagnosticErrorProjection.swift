import ExplorerCore
import FileOperations
import Foundation
@_spi(Qualification) import LocalStorage
import StorageAnalysis
import FileMemory
#if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
import DirectUpdates
#endif

/// Stable codes, never NSError.userInfo, descriptions, paths or server text.
enum DiagnosticErrors {
    static func remoteMetadata(_ error: Error) -> DiagnosticErrorCode? {
        if let failure = error as? RemoteFolderSizeFailure {
            let values: [RemoteFolderSizeFailure] = [.stale,.denied,.changed,.unsupported,.limit,.deadline,.connectionLost,.unavailable,.invalidInput]
            return values.firstIndex(of: failure).map { .init(domain: .network, code: Int64(1701 + $0)) }
        }
        if let failure = error as? RemoteDirectoryFindFailure {
            let values: [RemoteDirectoryFindFailure] = [.invalidInput,.stale,.unavailable]
            return values.firstIndex(of: failure).map { .init(domain: .network, code: Int64(1711 + $0)) }
        }
        return nil
    }
    static func remoteFileAction(_ record: SFTPRemoteActionRecord) -> DiagnosticErrorCode? {
        if record.outcome == .needsReview { return .init(domain: .network, code: 1305) }
        if record.outcome == .prepared { return .init(domain: .network, code: 1306) }
        guard let refusal = record.refusal else { return nil }
        let code: Int64 = switch refusal {
        case .targetExists: 1301; case .sourceChanged: 1302; case .denied: 1303; case .unavailable: 1304; case .busy: 1307; case .notEmpty: 1308
        }
        return .init(domain: .network, code: code)
    }
    static func remoteEditorSave(_ boundary: RemoteTextSaveBoundary,
        protocolKind: ExplorerConnectionProtocol = .sftp) -> (phase: DiagnosticPhase, error: DiagnosticErrorCode?) {
        let failureBase: Int64 = protocolKind == .smb ? 1861 : 1131
        return switch boundary {
        case .captured: (.preparing, nil)
        case .awaitingPermit: (.waiting, nil)
        case .permitAcquired: (.admitted, nil)
        case .remoteSaveCalled: (.committing, nil)
        case .remoteResultReceived: (.verifying, nil)
        case .saved: (.completed, nil)
        case .unchanged: (.finished, nil)
        case .captureCancelled: (.cancelled, nil)
        case .captureFailed: (.failed, .init(domain: .network, code: failureBase + 3))
        case .refused(.sftp(let reason)): (.blocked, remoteEditorRefusal(reason))
        case .refused(.smb(let reason)): (.blocked, smbEditorRefusal(reason))
        case .resultNeedsReview: (.interrupted, .init(domain: .network, code: failureBase))
        case .failedBeforeRemoteResult: (.failed, .init(domain: .network, code: failureBase + 1))
        case .resultApplyFailed: (.interrupted, .init(domain: .network, code: failureBase + 2))
        }
    }
    private static func remoteEditorRefusal(_ reason: SFTPInPlaceRefusalReason) -> DiagnosticErrorCode {
        let code: Int64
        switch reason {
        case .sessionUnavailable: code = 1101
        case .stagingFailed: code = 1102
        case .stagingCapacity: code = 1103
        case .stagingBusy: code = 1104
        case .disconnected: code = 1105
        case .browserEditorBusy: code = 1106
        case .browserFolderBusy: code = 1107
        case .browserDownloadBusy: code = 1108
        case .browserUploadBusy: code = 1109
        case .browserNavigationBusy: code = 1110
        case .workerReadBusy: code = 1111
        case .workerAttemptBusy: code = 1112
        case .workerReleaseBusy: code = 1113
        case .workerBaselineCapacity: code = 1114
        case .workerSettingsBusy: code = 1115
        case .workerSettingsUnsupported: code = 1116
        }
        return .init(domain: .network, code: code)
    }
    private static func smbEditorRefusal(_ reason: SMBInPlaceRefusalReason) -> DiagnosticErrorCode {
        let code: Int64
        switch reason {
        case .sessionUnavailable: code = 1851
        case .unsupportedSource: code = 1852
        case .changed: code = 1853
        case .stagingCapacity: code = 1854
        case .stagingBusy: code = 1855
        case .stagingFailed: code = 1856
        case .browserBusy: code = 1857
        case .disconnected: code = 1858
        }
        return .init(domain: .network, code: code)
    }
    static func milliseconds(_ seconds: TimeInterval) -> UInt64? {
        guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return nil }
        return UInt64(seconds * 1000)
    }
    static func causes(_ error: Error) -> [DiagnosticErrorCode] {
        causes(error, depth: 0)
    }
    private static func causes(_ error: Error, depth: Int) -> [DiagnosticErrorCode] {
        guard depth < 3 else { return [] }
        if let value = SFTPInPlaceOpenDiagnostic.project(error) { return value.cause.map { [$0] } ?? [] }
        if let value = error as? SFTPDownloadBatchInterruption { return [project(value.cause)] + Array(causes(value.cause, depth: depth + 1).prefix(2)) }
        if let value = error as? SMBDownloadBatchInterruption { return [project(value.cause)] + Array(causes(value.cause, depth: depth + 1).prefix(2)) }
        if let value = error as? SFTPUploadBatchInterruption { return [project(value.cause)] + Array(causes(value.cause, depth: depth + 1).prefix(2)) }
        if error is SFTPUploadOpenRefusal {
            return [.init(domain: .network, code: 615), .init(domain: .network, code: 704)]
        }
        if let value = error as? SMBUploadGroupInterruption { return [project(value.cause)] + Array(causes(value.cause, depth: depth + 1).prefix(2)) }
        if let value = error as? SFTPFolderUploadInterruption {
            let flags = (value.rootMayExist ? 1 : 0) | (value.rootAcknowledged ? 2 : 0)
            return [.init(domain: .network, code: 21 + Int64(value.phase)),
                    .init(domain: .network, code: 701 + Int64(value.status)),
                    .init(domain: .network, code: 61 + Int64(flags))]
        }
        if let value = error as? SFTPUploadInterruption {
            // Only closed protocol stage and numerical status; never server text.
            return [.init(domain: .network, code: 601 + Int64(value.phase.rawValue)),
                    .init(domain: .network, code: 701 + Int64(value.status))]
        }
        var result: [DiagnosticErrorCode] = []
        var current: NSError? = error as NSError
        // Inspect only the documented underlying-error link, never its message,
        // domain text, paths or the remainder of userInfo. Cycles are bounded.
        for _ in 0..<3 {
            guard let underlying = current?.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            result.append(project(underlying)); current = underlying as NSError
        }
        return result
    }
    static func scanPhase(_ status: StorageScanStatus) -> DiagnosticPhase {
        switch status {
        case .preparing: .preparing; case .scanning: .reading; case .completed: .completed
        case .partial: .partial; case .cancelled: .cancelled; case .failed: .failed
        }
    }
    /// Only the fixed caught category reaches persistence; no Error, domain
    /// string, userInfo, path or description crosses this adapter.
    static func operationCaughtFailure(_ value: OperationDiagnosticFailure) -> DiagnosticErrorCode {
        switch value {
        case .operation(let failure): operation(failure)
        case .capacity(let reason): localEditorCapacity(reason)
        case .sqlite(let code): .init(domain: .sqlite, code: Int64(code))
        case .malformedValue: .init(domain: .operation, code: 301)
        case .changedWitness: .init(domain: .operation, code: 302)
        case .invalidTransition: .init(domain: .operation, code: 303)
        case .valueQuota: .init(domain: .operation, code: 304)
        case .cancelled: .init(domain: .operation, code: 305)
        case .other: .init(domain: .unknown, code: 0)
        }
    }
    /// Numeric extension of the existing diagnostic schema. Older readers can
    /// still decode domain/code, nativeStatus, causes and relatedTrace; no new
    /// persisted enum value or private error text is needed.
    static func operationBoundary(_ checkpoint: OperationDiagnosticCheckpoint?) -> DiagnosticErrorCode? {
        let code: Int64
        switch checkpoint {
        case .copyMetadataComparison?: code = 601
        case .copyReceiptCardinality?: code = 602
        case .copyReceiptValidation?: code = 603
        case .downloadStageMark?: code = 501
        case .downloadTransitionShape?: code = 502
        case .downloadSourceMark?: code = 503
        case .downloadSourceProvenance?: code = 504
        case .downloadStageProvenance?: code = 505
        case .downloadMarkReplace?: code = 506
        case .downloadStageRecheck?: code = 507
        case .downloadSourceRecheck?: code = 508
        case .downloadProvenanceRecheck?: code = 509
        case .downloadAdoptionPathBinding?: code = 510
        case .downloadAdoptionRawQuarantine?: code = 511
        case .downloadAdoptionProvenance?: code = 512
        case .downloadAdoptionPublicProperties?: code = 513
        case .downloadAdoptionAdmission?: code = 520
        case .downloadAdoptionArea?: code = 521
        case .downloadAdoptionIntent?: code = 522
        case .downloadAdoptionMove?: code = 523
        case .downloadAdoptionStage?: code = 524
        case .downloadAdoptionPublication?: code = 525
        case .downloadAdoptionCommit?: code = 526
        case .nativeTrashReturnedParent?: code = 401
        case .nativeTrashReturnedIdentity?: code = 402
        case .nativeTrashTreeRead?: code = 403
        case .nativeTrashParentValidation?: code = 404
        case .nativeTrashFingerprint?: code = 405
        case .nativeTrashInversePreflight?: code = 406
        case .nativeTrashInversePostWalk?: code = 407
        case .nativeTrashInverseTransition?: code = 408
        case .nativeTrashInverseSync?: code = 409
        case .nativeTrashInverseJournal?: code = 410
        case .nativeTrashInverseObservedChange?: code = 411
        case .nativeTrashDeletePreflight?: code = 412
        case .nativeTrashDeleteStageRename?: code = 413
        case .nativeTrashDeleteStagePostWalk?: code = 414
        case .nativeTrashDeleteStageTransition?: code = 415
        case .nativeTrashDeleteStageJournal?: code = 416
        case .nativeTrashDeleteUnlink?: code = 417
        case .textManifestLocation?: code = 321
        case .textManifestArea?: code = 322
        case .textManifestBinding?: code = 323
        case .textManifestSlot?: code = 324
        case .textManifestRead?: code = 325
        case .textManifestBaseline?: code = 326
        case .textRecordStart?, .textRecordAdmission?, .textRecordProjection?,
             .textRecordHead?, .textRecordTransaction?, .textRecordSQLite?, nil: return nil
        }
        return .init(domain: .operation, code: code)
    }
    /// Preserve execution order for the primary failure, with one count per
    /// closed category. No item name, location or native error text is retained.
    static func operationFailures(_ result: FileOperationResult) -> [(failure: FileOperationFailure, count: UInt64)] {
        var order: [FileOperationFailure] = [], counts: [FileOperationFailure: UInt64] = [:]
        for item in result.items {
            guard case .failed(let failure) = item.status else { continue }
            if counts[failure] == nil { order.append(failure) }
            counts[failure, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }
    static func operation(_ value: FileOperationFailure) -> DiagnosticErrorCode {
        let code: Int64
        switch value {
        case .invalidRequest: code = 1
        case .conflict: code = 2
        case .sourceChanged: code = 3
        case .destinationChanged: code = 4
        case .accessDenied: code = 5
        case .notFound: code = 6
        case .copyContentMismatch: code = 7
        case .copyMetadataMismatch: code = 8
        case .copyOwnershipMismatch: code = 9
        case .operationHistoryProtected: code = 10
        case .protectedLocation: code = 11
        case .crossVolumeMoveUnsupported: code = 12
        case .unsupported: code = 13
        case .unavailable: code = 14
        case .outOfSpace: code = 15
        case .quotaExceeded: code = 16
        case .ioFailure: code = 17
        case .recoveryUncertain: code = 18
        case .undoEndedByCheckpoint: code = 19
        case .textUndoCapacityReached: code = 20
        case .legacyTextHistoryRequiresReview: code = 21
        case .fatTransferDestinationUnsupported: code = 22
        }
        return .init(domain: .operation, code: code)
    }
    /// Stable, closed editor-capacity codes. No paths, user text or native
    /// descriptions are admitted through this diagnostic projection.
    static func localEditorCapacity(_ value: LocalTextCapacityReason) -> DiagnosticErrorCode {
        let code: Int64
        switch value {
        case .checkpointRequired: code = 201
        case .unfinishedPreparation: code = 202
        case .unknownNativePrefix: code = 203
        case .pendingMaintenance: code = 204
        case .sourceChanged: code = 205
        case .storeCapacity: code = 206
        case .upgradeRequired: code = 207
        case .metadataUnavailable: code = 208
        case .stalePlan: code = 209
        case .nothingToCheckpoint: code = 210
        case .legacyHistoryRequiresReview: code = 211
        }
        return .init(domain: .operation, code: code)
    }
    static func project(_ error: Error) -> DiagnosticErrorCode {
        project(error, depth:0)
    }
    private static func project(_ error: Error, depth: Int) -> DiagnosticErrorCode {
        guard depth < 3 else { return .init(domain:.unknown,code:0) }
        if let value = remoteMetadata(error) { return value }
        if let value = SFTPInPlaceOpenDiagnostic.project(error) { return value.error }
        if let value = error as? ConnectionWorkspaceFailure {
            let all: [ConnectionWorkspaceFailure] = [.busy, .cancelled, .reviewRequired, .changed, .unsafe, .capacity, .durabilityUncertain]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 1401))
        }
        if let value = error as? RemoteSettingsFailure {
            let all: [RemoteSettingsFailure] = [.unsafe, .unavailable, .busy, .cancelled, .notOpen, .staleRevision, .invalidRecord,
                .incompatibleVersion, .recoveryRequired, .durabilityUncertain, .capacity, .missing]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 1421))
        }
        if let error = error as? FileOperationFailure { return operation(error) }
        if let value = error as? DiagnosticExportFailure {
            let all: [DiagnosticExportFailure] = [.empty,.alreadyExists,.invalidDestination,.changed,.accessDenied,.cancelled,.capacity,.io]
            return .init(domain:.diagnostics,code:Int64((all.firstIndex(of:value) ?? -1)+1))
        }
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        if let value = error as? PrivateUpdateFailure {
            let all: [PrivateUpdateFailure] = [.invalidInput,.authentication,.unavailable,.denied,.cancelled,.redirected,.capacity,.busy,.changed,.rateLimited]
            return .init(domain:.updater,code:Int64((all.firstIndex(of:value) ?? -1)+101))
        }
        #endif
        if let value = error as? SFTPConnectionFailure { return project(value.cause,depth:depth+1) }
        if let value = error as? SFTPDownloadBatchInterruption { return project(value.cause,depth:depth+1) }
        if let value = error as? SMBDownloadBatchInterruption { return project(value.cause,depth:depth+1) }
        if let value = error as? SMBDownloadBatchIssue {
            let all: [SMBDownloadBatchIssue] = [.invalidSelection,.duplicateSelection,.duplicateName,.tooLarge]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 871))
        }
        if let value = error as? SFTPDownloadBatchIssue {
            let all: [SFTPDownloadBatchIssue] = [.invalidSelection,.duplicateSelection,.duplicateName,.tooLarge]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 861))
        }
        if let value = error as? SFTPUploadBatchInterruption { return project(value.cause,depth:depth+1) }
        if error is SFTPUploadOpenRefusal { return .init(domain: .network, code: 517) }
        if let value = error as? SMBUploadGroupInterruption { return project(value.cause,depth:depth+1) }
        if let value = error as? SMBUploadGroupIssue {
            let all: [SMBUploadGroupIssue] = [.invalidSelection,.duplicateNames,.overlappingSources,.tooLarge,.historyFull,.historyBusy]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 471))
        }
        if let value = error as? SFTPUploadBatchIssue {
            let all: [SFTPUploadBatchIssue] = [.invalidSelection,.overlappingSources,.duplicateNames,.tooLarge,.historyFull]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 851))
        }
        if let value = error as? SFTPDirectoryRejection { return .init(domain: .network, code: 801 + Int64(value.rawValue - 2)) }
        if let value = error as? SMBDirectoryRejection {
            let all: [SMBDirectoryRejection] = [.denied,.missing,.unavailable]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 811))
        }
        if let value = error as? SMBBrowserFailure {
            let all: [SMBBrowserFailure] = [.invalidInput,.invalidOutput,.busy,.stopped,.unavailable,.authentication,.denied,.security,.storage,.quota,.deadline,.containment,.remote]
            return .init(domain:.network,code:Int64((all.firstIndex(of:value) ?? -1)+101))
        }
        if let value = error as? SFTPBrowserFailure {
            let all: [SFTPBrowserFailure] = [.invalidInput,.busy,.stopped,.stale,.unavailable,.remote,.storage,.denied,.deadline,.security]
            return .init(domain:.network,code:Int64((all.firstIndex(of:value) ?? -1)+201))
        }
        if let value = error as? SFTPSessionFailure {
            let all: [SFTPSessionFailure] = [.busy,.input,.unavailable,.stopped,.deadline,.exited,.output,.remote,
                .authentication,.security,.denied,.storage,.sourceChanged,.keyInput,.keyPassphrase,.keyUnsupported,.keyChanged,.forwardDenied,
                .certificateExpired,.certificateNotYetValid]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 301))
        }
        if let value = error as? SFTPDownloadStorageIssue {
            let all: [SFTPDownloadStorageIssue] = [.full,.busy,.changed,.unavailable]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 401))
        }
        if let value = error as? SMBDownloadStorageIssue {
            let all: [SMBDownloadStorageIssue] = [.full,.busy,.changed,.unavailable]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 421))
        }
        if let value = error as? SMBUploadFailure {
            let all: [SMBUploadFailure] = [.invalidInput, .unavailable, .busy, .stopped, .sourceChanged,
                .storage, .stageCollision, .finalCollision, .reviewRequired]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 461))
        }
        if let value = error as? SFTPUploadLocalIssue {
            let all: [SFTPUploadLocalIssue] = [.sourceUnavailable,.unsupportedSource,.additionalFork,.sourceChanged,
                .historyUnavailable,.historyFull,.busy,.stopped]
            return .init(domain: .network, code: Int64((all.firstIndex(of: value) ?? -1) + 451))
        }
        if let value = error as? SFTPUploadInterruption {
            return .init(domain: .network, code: 501 + Int64(value.cause.rawValue))
        }
        if let value = error as? SFTPFolderUploadInterruption {
            return .init(domain: .network, code: 1 + Int64(value.cause.rawValue))
        }
        if let value = error as? LocalStorageError {
            let code: Int64
            switch value { case .accessDenied:code=1;case .notFound:code=2;case .notDirectory:code=3;case .unavailable:code=4;case .busy:code=5;case .other:code=6 }
            return .init(domain:.access,code:code)
        }
        if let value = error as? StorageScanFailure {
            let all: [StorageScanFailure] = [.busy,.accessDenied,.unavailable,.unsupportedLocation,.changed,.workerUnavailable,.workerFailed,.invalidOutput,.resourceLimit]
            return .init(domain:.scanner,code:Int64((all.firstIndex(of:value) ?? -1)+1))
        }
        if let value = error as? ZIPCreationFailure {
            let values: [ZIPCreationFailure] = [.unsupportedSource, .limitOrPrivacy, .resourceFork,
                .sourceChanged, .contentMismatch, .codecUnavailable]
            return .init(domain: .archive, code: 201 + Int64(values.firstIndex(of: value) ?? -1))
        }
        if let value = error as? TARCreationFailure {
            let values: [TARCreationFailure] = [.unsupportedSource, .limitReached, .sourceChanged, .contentMismatch]
            return .init(domain: .archive, code: 211 + Int64(values.firstIndex(of: value) ?? -1))
        }
        if let value = error as? ZIPExtractionFailure {
            let values: [ZIPExtractionFailure] = [.quarantinedOrUncertain, .unsupportedSource, .destinationChanged]
            return .init(domain: .archive, code: 221 + Int64(values.firstIndex(of: value) ?? -1))
        }
        if let value = error as? ZIPMemberNewEntryFailure {
            let values: [ZIPMemberNewEntryFailure] = [.invalidSelection, .invalidName, .invalidOutputName, .nameConflict,
                .unsupportedArchive, .unsupportedSecurity, .sourceChanged, .contentMismatch, .limitReached]
            return .init(domain: .archive, code: 231 + Int64(values.firstIndex(of: value) ?? -1))
        }
        if let value = error as? BatchRenameValidation {
            let values: [BatchRenameValidation] = [.invalidRule, .unsafeName, .duplicateTarget, .dependentNames, .tooManyItems]
            return .init(domain: .archive, code: 251 + Int64(values.firstIndex(of: value) ?? -1))
        }
        if let problem = error as? ZIPContentProblem { return project(problem.reason) }
        if let value = error as? ZIPContentFailure {
            let all: [ZIPContentFailure] = [.unsupported, .metadataMismatch, .contentMismatch, .limitReached, .codecUnavailable]
            return .init(domain: .archive, code: 261 + Int64(all.firstIndex(of: value) ?? -1))
        }
        if let value = error as? ZIPArchiveFailure {
            let all: [ZIPArchiveFailure] = [.malformed,.unsupported,.unsafeName,.ambiguousNames,.unsupportedEncoding,.limited,.unavailable,.changed,.stopped,.busy,.closed,.invalidFolder,.invalidFilter]
            return .init(domain:.archive,code:Int64((all.firstIndex(of:value) ?? -1)+1))
        }
        if let value = error as? TARArchiveFailure {
            let all: [TARArchiveFailure] = [.malformed,.unsupported,.compressed,.unsafeName,.ambiguousNames,
                .limited,.unavailable,.changed,.stopped,.busy,.closed,.invalidSelection]
            return .init(domain:.archive,code:Int64((all.firstIndex(of:value) ?? -1)+101))
        }
        if let value = error as? ZIPMemberRenameFailure {
            let all: [ZIPMemberRenameFailure] = [.invalidMember, .invalidName, .ambiguousName, .unsupportedArchive,
                .unsupportedSecurity, .sourceChanged, .contentMismatch, .limitReached]
            return .init(domain: .archive, code: Int64((all.firstIndex(of: value) ?? -1) + 121))
        }
        if let value = error as? ZIPMemberRemovalFailure {
            let all: [ZIPMemberRemovalFailure] = [.invalidSelection, .invalidOutputName, .unsupportedArchive,
                .unsupportedSecurity, .sourceChanged, .contentMismatch, .limitReached]
            return .init(domain: .archive, code: Int64((all.firstIndex(of: value) ?? -1) + 141))
        }
        if let value = error as? ZIPMemberAdditionFailure {
            let all: [ZIPMemberAdditionFailure] = [.invalidSelection, .invalidOutputName, .nameConflict, .unsupportedArchive,
                .unsupportedSource, .sourceChanged, .contentMismatch, .limitReached]
            return .init(domain: .archive, code: Int64((all.firstIndex(of: value) ?? -1) + 161))
        }
        if let value = error as? NameStoreFailure {
            let all: [NameStoreFailure] = [.busy,.unsafe,.changed,.unavailable,.unsupported,.recoveryRequired,.initializationIncomplete,.indexUpdateRequired,.forgetPending,.continuityUpdateRequired,.uncertainCommit,.readOnly,.invalidRequest,.quota,.closed,.referenceUpdateRequired]
            return .init(domain:.privateStore,code:Int64((all.firstIndex(of:value) ?? -1)+1))
        }
        if let value = error as? NameExportFailure {
            let all: [NameExportFailure] = [.stalePreview,.tooLarge,.empty,.invalidDestination,.unsupportedDestination,.destinationChanged,
                .alreadyExists,.accessDenied,.cancelled,.writeFailed,.synchronizationFailed]
            return .init(domain:.privateStore,code:Int64((all.firstIndex(of:value) ?? -1)+301))
        }
        if let value = error as? NameImportFailure {
            let all: [NameImportFailure] = [.invalidDocument,.unsupportedVersion,.tooLarge,.quota,.stalePreview,.cancelled,
                .inaccessibleFile,.changedFile,.unsupportedFile,.storageUnavailable]
            return .init(domain:.privateStore,code:Int64((all.firstIndex(of:value) ?? -1)+401))
        }
        if let value = error as? RememberedReferenceFailure {
            let code: Int64
            switch value {
            case .unsupported:code=101;case .unavailable:code=102;case .accessNeeded:code=103;case .changed:code=104
            case .stale:code=105;case .capacity:code=106;case .cancelled:code=107;case .followingRequired:code=108;case .alreadyRemembered:code=109
            }
            return .init(domain:.privateStore,code:code)
        }
        if let value = error as? StateDirectoryPreparationError {
            let code: Int64
            switch value { case .invalidLocation:code=1;case .unavailable:code=2;case .unsafeState:code=3;case .changed:code=4;case .busy:code=5;case .requiresBackgroundWorker:code=6 }
            return .init(domain:.privateStore,code:code+200)
        }
        let value = error as NSError
        switch value.domain {
        case NSPOSIXErrorDomain: return .init(domain: .posix, code: Int64(value.code))
        case NSCocoaErrorDomain: return .init(domain: .cocoa, code: Int64(value.code))
        case NSURLErrorDomain: return .init(domain: .network, code: Int64(value.code))
        case "SUSparkleErrorDomain": return .init(domain: .sparkle, code: Int64(value.code))
        case NSOSStatusErrorDomain: return .init(domain: .security, code: Int64(value.code))
        case "Traverse.PrivateUpdate", "Traverse.Update": return .init(domain:.updater,code:Int64(value.code))
        default: return .init(domain: .unknown, code: 0)
        }
    }
}

@MainActor extension ApplicationDiagnostics {
    func recordOperationError(_ error: Error) {
        guard recorder != nil else { return }
        event(.fileOperation, .failed, error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
    }
    func recordOperationResult(_ result: FileOperationResult, trace: UUID?) {
        guard recorder != nil else { return }
        let id = trace ?? currentTrace ?? UUID()
        let phase: DiagnosticPhase
        switch result.disposition {
        case .succeeded: phase = .completed
        case .partial: phase = .partial
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        let failures = DiagnosticErrors.operationFailures(result)
        event(.fileOperation, phase, trace: id,
              level: phase == .partial ? .warning : nil, count: UInt64(result.items.count),
              error: failures.first.map { DiagnosticErrors.operation($0.failure) }, context: .init(.queueTerminal),
              causes: failures.isEmpty ? nil : failures.dropFirst().prefix(3).map { DiagnosticErrors.operation($0.failure) })
        for (error, count) in failures {
            event(.fileOperation, .failed, trace: id, count: count, error: DiagnosticErrors.operation(error))
        }
    }
}
