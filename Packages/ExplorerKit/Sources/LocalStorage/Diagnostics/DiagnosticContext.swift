import Foundation

/// Fixed checkpoints and state flags make exported logs useful without accepting
/// free-form messages, stack paths, OS error descriptions or user input.
public enum DiagnosticCheckpoint: String, Codable, Sendable {
    case launch, commandDispatch, helpWhatsNew, helpLogs, helpUpdates, helpSupport, helpAbout
    case crashStorage, crashRecovery, crashCapture, crashDiscard
    case queueAdmission, queueAccess, queueSources, queueDestination, queueReady, queueStart
    case queuePlan, queueStatePreparation, queueMutation, queueTerminal, queueCancel, queuePause, queueResume, nativeStatus
    case hoverAdmission, hoverDwell, hoverCancel, hoverScan, analysisAdmission, analysisTerminal
    case folderPicker, folderScope, folderBookmark, folderAccessPublication, setupPage, setupStartup, setupFinish, setupWindow
    case textRecordStart, textRecordAdmission, textRecordProjection, textRecordHead, textRecordTransaction, textRecordSQLite, editorTextCopy, remoteEditorOpen, remoteEditorSave
    case remoteFolderSize, remoteDirectoryFind
    case dragSources, dragTargets, dragWriter, dragSession
    case clipboardPublish, clipboardCapture
    case connectionPresentation, connectionWorkspacePreparation, connectionWorkspaceReview, savedServersRead, savedServerForget
    case remoteDestinationReview
    case sftpConfigurationPreparation, sftpAddressPreparation, sftpWorkerAdmission
    case sftpHostReview, sftpAuthenticationAndRemembering, sftpBrowserAdoption
    case driveBenchmark, driveHealth, newTextFile
    case ownedTrashRead, ownedTrashRestore, ownedTrashDelete
    case incomingFolderService
}

public enum DiagnosticStateFlag: String, Codable, Sendable, CaseIterable {
    case paused, activeTransfer, exclusiveOperation, exclusivePreparation, volumeBarrier, copyPreview
    case waitingForOS, cancellationRequested, sourceObserved, destinationObserved, selectedScope, retainedScope
    case browserLoading, browserSuspended, windowNotKey, mouseButtonDown, presentationChanged, visitChanged
    case summariesDisabled, searchResults, computerView, scannerBusy, policyExcluded, offline, listingIncomplete, scrolled, windowDeactivated
    case sourceNotPrepared, selectionUnavailable, selectionTooLarge, contextChanged, wrongPresentation, preparationPending
    case clipboardEmpty, clipboardChanged, clipboardPublicationFailed, queueUnavailable
    case nativeTrashRootObject, nativeTrashEntryMetadata, nativeTrashLinkStructure, nativeTrashContent, nativeTrashACL
    case nativeTrashQuarantine, nativeTrashProvenance, nativeTrashFinderInfo, nativeTrashOtherXattrs
    case nativeTrashOSAccessChanged, nativeTrashFamilyUnavailable
}

public struct DiagnosticRuntime: Codable, Sendable, Equatable {
    public enum Architecture: String, Codable, Sendable { case arm64, x86_64, unknown }
    public enum Edition: String, Codable, Sendable { case developerID, appStore, development }
    public let osMajor: UInt16
    public let osMinor: UInt16
    public let osPatch: UInt16
    public let architecture: Architecture
    public let edition: Edition
    public let processID: UInt32
    public init(osMajor: Int, osMinor: Int, osPatch: Int, architecture: Architecture, edition: Edition, processID: Int32) {
        self.osMajor = UInt16(clamping: osMajor); self.osMinor = UInt16(clamping: osMinor); self.osPatch = UInt16(clamping: osPatch)
        self.architecture = architecture; self.edition = edition; self.processID = UInt32(clamping: processID)
    }
}

/// Closed numerical worker coordinates; never a server-provided message.
public struct DiagnosticSMBFailure: Codable, Sendable, Equatable {
    public let boundary: UInt8, cause: UInt8
    public let command: UInt8?
    public let status: UInt32?
    public init(boundary: UInt8, cause: UInt8, command: UInt8?, status: UInt32?) {
        self.boundary = boundary; self.cause = cause; self.command = command; self.status = status
    }
    var isValid: Bool {
        (1...10).contains(boundary) && (1...11).contains(cause)
            && (command.map { $0 <= 18 } ?? true) && (status.map { $0 != 0 } ?? true)
            && (command == nil) == (status == nil)
    }
}

public struct DiagnosticContext: Codable, Sendable, Equatable {
    public let checkpoint: DiagnosticCheckpoint
    public let flags: [DiagnosticStateFlag]
    public let queueDepth: UInt8?
    public let preparingAdmissions: UInt8?
    /// SMB2 command counters, indexed by the protocol's fixed 0...18 command
    /// numbers. Counts only; no names, paths, payloads or server messages.
    public let smbCommandCounts: [UInt64]?
    public let smbFailure: DiagnosticSMBFailure?
    public init(_ checkpoint: DiagnosticCheckpoint, flags: [DiagnosticStateFlag] = [],
                queueDepth: Int? = nil, preparingAdmissions: Int? = nil, smbCommandCounts: [UInt64]? = nil,
                smbFailure: DiagnosticSMBFailure? = nil) {
        self.checkpoint = checkpoint
        var seen = Set<DiagnosticStateFlag>()
        self.flags = Array(flags.filter { seen.insert($0).inserted }.prefix(16))
        self.queueDepth = queueDepth.map { UInt8(clamping: max(0, min(16, $0))) }
        self.preparingAdmissions = preparingAdmissions.map { UInt8(clamping: max(0, min(16, $0))) }
        self.smbCommandCounts = smbCommandCounts
        self.smbFailure = smbFailure
    }
    var isValid: Bool {
        flags.count <= 16 && Set(flags).count == flags.count
            && (queueDepth.map { $0 <= 16 } ?? true)
            && (preparingAdmissions.map { $0 <= 16 } ?? true)
            && (smbCommandCounts.map { $0.count == 19 } ?? true)
            && (smbFailure.map(\.isValid) ?? true)
    }
}

extension DiagnosticErrorCode {
    /// Canonical symbols are computed from the closed domain/code pair. An
    /// imported JSON 'symbol' is never trusted or re-exported as supplied text.
    public var symbol: String? {
        let names: [String]
        let base: Int64
        switch domain {
        case .operation:
            if (510...513).contains(code) {
                return ["download.adoption.pathBinding", "download.adoption.rawQuarantine",
                        "download.adoption.provenance", "download.adoption.publicProperties"][Int(code - 510)]
            }
            if (520...526).contains(code) {
                return ["download.adoption.admission", "download.adoption.area", "download.adoption.intent",
                        "download.adoption.move", "download.adoption.stage", "download.adoption.publication",
                        "download.adoption.commit"][Int(code - 520)]
            }
            if (501...509).contains(code) {
                return ["download.stageMark", "download.transitionShape", "download.sourceMark",
                        "download.sourceProvenance", "download.stageProvenance", "download.markReplace",
                        "download.stageRecheck", "download.sourceRecheck", "download.provenanceRecheck"][Int(code - 501)]
            }
            if (201...211).contains(code) {
                return ["textCapacity.checkpointRequired", "textCapacity.unfinishedPreparation", "textCapacity.unknownNativePrefix",
                        "textCapacity.pendingMaintenance", "textCapacity.sourceChanged", "textCapacity.storeCapacity",
                        "textCapacity.upgradeRequired", "textCapacity.metadataUnavailable", "textCapacity.stalePlan",
                        "textCapacity.nothingToCheckpoint", "textCapacity.legacyHistoryRequiresReview"][Int(code - 201)]
            }
            if (321...326).contains(code) {
                return ["textManifest.location", "textManifest.area", "textManifest.binding",
                        "textManifest.slot", "textManifest.read", "textManifest.baseline"][Int(code - 321)]
            }
            if (401...405).contains(code) {
                return ["nativeTrash.returnedParent", "nativeTrash.returnedIdentity", "nativeTrash.treeRead",
                        "nativeTrash.parentValidation", "nativeTrash.fingerprint"][Int(code - 401)]
            }
            if (301...305).contains(code) {
                return ["textValue.malformed", "textValue.changedWitness", "textValue.invalidTransition",
                        "textValue.quota", "textRecordStart.cancelled"][Int(code - 301)]
            }
            base = 1; names = ["invalidRequest","conflict","sourceChanged","destinationChanged","accessDenied","notFound",
                "copyContentMismatch","copyMetadataMismatch","copyOwnershipMismatch","operationHistoryProtected","protectedLocation",
                "crossVolumeMoveUnsupported","unsupported","unavailable","outOfSpace","quotaExceeded","ioFailure","recoveryUncertain",
                "undoEndedByCheckpoint","textUndoCapacityReached","legacyTextHistoryRequiresReview"]
        case .access:
            base = 1; names = ["accessDenied","notFound","notDirectory","unavailable","busy","other"]
        case .scanner:
            base = 1; names = ["busy","accessDenied","unavailable","unsupportedLocation","changed","workerUnavailable","workerFailed","invalidOutput","resourceLimit"]
        case .archive:
            if (201...206).contains(code) {
                return ["zipCreate.unsupportedSource", "zipCreate.limitOrPrivacy", "zipCreate.resourceFork",
                        "zipCreate.sourceChanged", "zipCreate.contentMismatch", "zipCreate.codecUnavailable"][Int(code - 201)]
            }
            if (211...214).contains(code) {
                return ["tarCreate.unsupportedSource", "tarCreate.limitReached", "tarCreate.sourceChanged", "tarCreate.contentMismatch"][Int(code - 211)]
            }
            if (221...223).contains(code) {
                return ["zipExtract.quarantinedOrUncertain", "zipExtract.unsupportedSource", "zipExtract.destinationChanged"][Int(code - 221)]
            }
            if (231...239).contains(code) {
                return ["zipNew.invalidSelection", "zipNew.invalidName", "zipNew.invalidOutputName", "zipNew.nameConflict",
                        "zipNew.unsupportedArchive", "zipNew.unsupportedSecurity", "zipNew.sourceChanged", "zipNew.contentMismatch", "zipNew.limitReached"][Int(code - 231)]
            }
            if (251...255).contains(code) {
                return ["batchRename.invalidRule", "batchRename.unsafeName", "batchRename.duplicateTarget", "batchRename.dependentNames", "batchRename.tooManyItems"][Int(code - 251)]
            }
            if (261...265).contains(code) {
                return ["zipCheck.unsupported", "zipCheck.metadataMismatch", "zipCheck.contentMismatch",
                        "zipCheck.limitReached", "zipCheck.codecUnavailable"][Int(code - 261)]
            }
            if (161...168).contains(code) {
                return ["zipAdd.invalidSelection", "zipAdd.invalidOutputName", "zipAdd.nameConflict",
                        "zipAdd.unsupportedArchive", "zipAdd.unsupportedSource", "zipAdd.sourceChanged",
                        "zipAdd.contentMismatch", "zipAdd.limitReached"][Int(code - 161)]
            }
            if (101...112).contains(code) {
                return ["tar.malformed", "tar.unsupported", "tar.compressed", "tar.unsafeName", "tar.ambiguousNames",
                        "tar.limited", "tar.unavailable", "tar.changed", "tar.stopped", "tar.busy", "tar.closed", "tar.invalidSelection"][Int(code - 101)]
            }
            if (121...128).contains(code) {
                return ["zipRename.invalidMember", "zipRename.invalidName", "zipRename.ambiguousName",
                        "zipRename.unsupportedArchive", "zipRename.unsupportedSecurity", "zipRename.sourceChanged",
                        "zipRename.contentMismatch", "zipRename.limitReached"][Int(code - 121)]
            }
            if (141...147).contains(code) {
                return ["zipRemove.invalidSelection", "zipRemove.invalidOutputName", "zipRemove.unsupportedArchive",
                        "zipRemove.unsupportedSecurity", "zipRemove.sourceChanged", "zipRemove.contentMismatch",
                        "zipRemove.limitReached"][Int(code - 141)]
            }
            base = 1; names = ["malformed","unsupported","unsafeName","ambiguousNames","unsupportedEncoding","limited","unavailable","changed","stopped","busy","closed","invalidFolder","invalidFilter"]
        case .posix:
            return [1:"EPERM",2:"ENOENT",5:"EIO",13:"EACCES",16:"EBUSY",17:"EEXIST",18:"EXDEV",20:"ENOTDIR",
                    22:"EINVAL",24:"EMFILE",28:"ENOSPC",30:"EROFS",60:"ETIMEDOUT",69:"EDQUOT",89:"ECANCELED"][code]
        case .sqlite:
            return [1:"SQLITE_ERROR",5:"SQLITE_BUSY",8:"SQLITE_READONLY",10:"SQLITE_IOERR",11:"SQLITE_CORRUPT",
                    14:"SQLITE_CANTOPEN",17:"SQLITE_SCHEMA",19:"SQLITE_CONSTRAINT",26:"SQLITE_NOTADB"][code & 0xff]
        case .cocoa:
            return [CocoaError.fileReadNoPermission.rawValue:"fileReadNoPermission", CocoaError.fileWriteNoPermission.rawValue:"fileWriteNoPermission",
                    CocoaError.fileNoSuchFile.rawValue:"fileNoSuchFile", CocoaError.fileWriteOutOfSpace.rawValue:"fileWriteOutOfSpace",
                    CocoaError.userCancelled.rawValue:"userCancelled" ][Int(code)]
        case .network:
            if (1861...1864).contains(code) {
                return ["smb.editor.needsReview", "smb.editor.failedBeforeResult", "smb.editor.resultApplyFailed",
                        "smb.editor.captureFailed"][Int(code - 1861)]
            }
            if (1851...1858).contains(code) {
                return ["smb.editor.sessionUnavailable", "smb.editor.unsupportedSource", "smb.editor.changed",
                        "smb.editor.stagingCapacity", "smb.editor.stagingBusy", "smb.editor.stagingFailed",
                        "smb.editor.browserBusy", "smb.editor.disconnected"][Int(code - 1851)]
            }
            if code == 517 { return "sftp.upload.firstOpenPermissionRefused" }
            if (1...11).contains(code) {
                let labels = ["input","io","deadline","stopped","truncated","protocolError","status","conflict","unsupportedSync","verification","sourceChanged"]
                return "sftp.folderUpload." + labels[Int(code - 1)]
            }
            if (21...27).contains(code) {
                let labels = ["admission","negotiation","creatingDirectory","copyingFile","verifyingTree","checkingSource","shutdown"]
                return "sftp.folderUpload." + labels[Int(code - 21)]
            }
            if (61...64).contains(code) {
                return ["sftp.folderUpload.rootNotCreated","sftp.folderUpload.rootCreationUncertain","sftp.folderUpload.invalidRootState","sftp.folderUpload.rootAcknowledged"][Int(code - 61)]
            }
            if code < 0 {
                return [-999:"cancelled",-1001:"timedOut",-1003:"cannotFindHost",-1004:"cannotConnectToHost",-1005:"networkConnectionLost",
                        -1009:"notConnectedToInternet",-1012:"userCancelledAuthentication",-1013:"userAuthenticationRequired",-1200:"secureConnectionFailed"][code]
            }
            if (1701...1709).contains(code) {
                base = 1701; names = ["remote.folderSize.stale", "remote.folderSize.denied", "remote.folderSize.changed",
                    "remote.folderSize.unsupported", "remote.folderSize.limit", "remote.folderSize.deadline",
                    "remote.folderSize.connectionLost", "remote.folderSize.unavailable", "remote.folderSize.invalidInput"]
            }
            else if (1711...1713).contains(code) {
                base = 1711; names = ["remote.find.invalidInput", "remote.find.stale", "remote.find.unavailable"]
            }
            else if (1651...1658).contains(code) {
                base = 1651; names = ["smb.fileAction.copy.sourceCheck", "smb.fileAction.copy.stageOpen",
                    "smb.fileAction.copy.chunkTransfer", "smb.fileAction.copy.stageFlush",
                    "smb.fileAction.copy.publish", "smb.fileAction.copy.finalVerification",
                    "smb.fileAction.copy.completeReceived", "smb.fileAction.copy.journalConfirmed"]
            }
            else if (1641...1648).contains(code) {
                base = 1641; names = ["smb.fileAction.move.sourceCheck", "smb.fileAction.move.targetProbe",
                    "smb.fileAction.move.renameRequest", "smb.fileAction.move.targetPin",
                    "smb.fileAction.move.sourceRelease", "smb.fileAction.move.finalVerification",
                    "smb.fileAction.move.completeReceived", "smb.fileAction.move.journalConfirmed"]
            }
            else if code == 1631 { return "smb.fileAction.destinationUnavailable" }
            else if (1621...1630).contains(code) {
                base = 1621; names = ["smb.fileAction.sourceDirectory","smb.fileAction.sourceAttributes",
                    "smb.fileAction.sourceSize","smb.fileAction.sourceModifiedTime","smb.fileAction.sourceObjectID",
                    "smb.fileAction.sourceLinkCount","smb.fileAction.sourceVolumeSerial","smb.fileAction.sourceVolumeCreation",
                    "smb.fileAction.createAttributes","smb.fileAction.createModifiedTime"]
            }
            else if (1601...1618).contains(code) {
                base = 1601; names = ["smb.fileAction.invalidInput","smb.fileAction.caseOnlyRename","smb.fileAction.unavailable",
                    "smb.fileAction.busy","smb.fileAction.stopped","smb.fileAction.collision","smb.fileAction.needsReview",
                    "smb.fileAction.protocol","smb.fileAction.ipc","smb.fileAction.deadline","smb.fileAction.remote",
                    "smb.fileAction.storage","smb.fileAction.quota","smb.fileAction.close","smb.fileAction.authentication",
                    "smb.fileAction.denied","smb.fileAction.security","smb.fileAction.containment"]
            }
            else if code >= 1501 { base = 1501; names = ["smb.folderUpload.invalid","smb.folderUpload.ipc","smb.folderUpload.stopped","smb.folderUpload.deadline","smb.folderUpload.remote","smb.folderUpload.authentication","smb.folderUpload.denied","smb.folderUpload.security","smb.folderUpload.storage","smb.folderUpload.quota","smb.folderUpload.close"] }
            else if code >= 1421 { base = 1421; names = ["connection.settings.unsafe","connection.settings.unavailable","connection.settings.busy","connection.settings.cancelled","connection.settings.notOpen","connection.settings.staleRevision","connection.settings.invalidRecord","connection.settings.incompatibleVersion","connection.settings.recoveryRequired","connection.settings.durabilityUncertain","connection.settings.capacity","connection.settings.missing"] }
            else if code >= 1401 { base = 1401; names = ["connection.workspace.busy","connection.workspace.cancelled","connection.workspace.reviewRequired","connection.workspace.changed","connection.workspace.unsafe","connection.workspace.capacity","connection.workspace.durabilityUncertain"] }
            else if code >= 1301 { base = 1301; names = ["sftp.fileAction.targetExists","sftp.fileAction.sourceChanged","sftp.fileAction.denied","sftp.fileAction.unavailable","sftp.fileAction.needsReview","sftp.fileAction.notSent","sftp.fileAction.busy","sftp.fileAction.notEmpty"] }
            else if code >= 1231 { base = 1231; names = ["sftp.sharedBudget.unsafe","sftp.sharedBudget.busy","sftp.sharedBudget.capacity","sftp.sharedBudget.recoveryRequired","sftp.sharedBudget.ownerEnded","sftp.sharedBudget.stale","sftp.sharedBudget.referenced"] }
            else if code >= 1211 { base = 1211; names = ["download.storage.unsafe","download.storage.changed","download.storage.unavailable","download.storage.capacity","download.storage.busy","download.storage.incomplete","download.storage.io"] }
            else if code >= 1201 { base = 1201; names = ["download.quarantine.unsafe","download.quarantine.changed","download.quarantine.unavailable"] }
            else if code >= 1131 { base = 1131; names = ["sftp.editor.needsReview","sftp.editor.failedBeforeResult","sftp.editor.resultApplyFailed","sftp.editor.captureFailed"] }
            else if code >= 1101 { base = 1101; names = ["sftp.editor.sessionUnavailable","sftp.editor.stagingFailed","sftp.editor.stagingCapacity","sftp.editor.stagingBusy","sftp.editor.disconnected","sftp.editor.browserEditorBusy","sftp.editor.browserFolderBusy","sftp.editor.browserDownloadBusy","sftp.editor.browserUploadBusy","sftp.editor.browserNavigationBusy","sftp.editor.workerReadBusy","sftp.editor.workerAttemptBusy","sftp.editor.workerReleaseBusy","sftp.editor.workerBaselineCapacity","sftp.editor.workerSettingsBusy","sftp.editor.workerSettingsUnsupported"] }
            else if code >= 871 { base = 871; names = ["smb.downloadGroup.invalidSelection","smb.downloadGroup.duplicateSelection","smb.downloadGroup.duplicateName","smb.downloadGroup.tooLarge"] }
            else if code >= 861 { base = 861; names = ["sftp.downloadGroup.invalidSelection","sftp.downloadGroup.duplicateSelection","sftp.downloadGroup.duplicateName","sftp.downloadGroup.tooLarge"] }
            else if code >= 851 { base = 851; names = ["sftp.group.invalidSelection","sftp.group.overlappingSources","sftp.group.duplicateNames","sftp.group.tooLarge","sftp.group.historyFull"] }
            else if code >= 811 { base = 811; names = ["smb.directory.missing","smb.directory.denied","smb.directory.unavailable"] }
            else if code >= 801 { base = 801; names = ["sftp.directory.missing","sftp.directory.denied","sftp.directory.unavailable"] }
            else if code >= 701 { base = 701; names = ["sftp.status.ok","sftp.status.eof","sftp.status.noSuchFile","sftp.status.permissionDenied","sftp.status.failure","sftp.status.badMessage","sftp.status.noConnection","sftp.status.connectionLost","sftp.status.unsupported"] }
            else if code >= 601 { base = 601; names = ["sftp.upload.admission","sftp.upload.negotiation","sftp.upload.destination","sftp.upload.openingTemporary","sftp.upload.writing","sftp.upload.readback","sftp.upload.permissions","sftp.upload.syncing","sftp.upload.closing","sftp.upload.temporaryCheck","sftp.upload.authorization","sftp.upload.publishing","sftp.upload.finalReadback","sftp.upload.shutdown","sftp.upload.openingFinal"] }
            else if code >= 501 { base = 501; names = ["sftp.upload.input","sftp.upload.io","sftp.upload.deadline","sftp.upload.stopped","sftp.upload.truncated","sftp.upload.protocolError","sftp.upload.status","sftp.upload.conflict","sftp.upload.unsupportedSync","sftp.upload.verification","sftp.upload.sourceChanged"] }
            else if code >= 481 { base = 481; names = ["smb.generated.unsafe","smb.generated.unavailable","smb.generated.busy","smb.generated.capacity","smb.generated.changed","smb.generated.stopped","smb.generated.retained"] }
            else if code >= 471 { base = 471; names = ["smb.group.invalidSelection","smb.group.duplicateNames","smb.group.overlappingSources","smb.group.tooLarge","smb.group.historyFull","smb.group.historyBusy"] }
            else if code >= 461 { base = 461; names = ["smb.upload.invalidInput","smb.upload.unavailable","smb.upload.busy","smb.upload.stopped","smb.upload.sourceChanged","smb.upload.storage","smb.upload.stageCollision","smb.upload.finalCollision","smb.upload.reviewRequired"] }
            else if code >= 451 { base = 451; names = ["sftp.upload.sourceUnavailable","sftp.upload.unsupportedSource","sftp.upload.additionalFork","sftp.upload.sourceChanged","sftp.upload.historyUnavailable","sftp.upload.historyFull","sftp.upload.busy","sftp.upload.stopped"] }
            else if code >= 401 { base = 401; names = ["sftp.staging.full","sftp.staging.busy","sftp.staging.changed","sftp.staging.unavailable"] }
            else if code >= 301 { base = 301; names = ["sftp.worker.busy","sftp.worker.input","sftp.worker.unavailable","sftp.worker.stopped","sftp.worker.deadline","sftp.worker.exited","sftp.worker.output","sftp.worker.remote","sftp.worker.authentication","sftp.worker.security","sftp.worker.denied","sftp.worker.storage","sftp.worker.sourceChanged","sftp.worker.keyInput","sftp.worker.keyPassphrase","sftp.worker.keyUnsupported","sftp.worker.keyChanged","sftp.worker.forwardDenied"] }
            else if code >= 201 { base = 201; names = ["sftp.invalidInput","sftp.busy","sftp.stopped","sftp.stale","sftp.unavailable","sftp.remote","sftp.storage","sftp.denied","sftp.deadline","sftp.security"] }
            else { base = 101; names = ["smb.invalidInput","smb.invalidOutput","smb.busy","smb.stopped","smb.unavailable","smb.authentication","smb.denied","smb.security","smb.storage","smb.quota","smb.deadline","smb.containment","smb.remote"] }
        case .updater:
            if code >= 101 { base = 101; names = ["invalidInput","authentication","unavailable","denied","cancelled","redirected","capacity","busy","changed","rateLimited"] }
            else { base = 1; names = ["invalidInput","authentication","redirected","capacity","busy","cancelled","unavailable","rateLimited"] }
        case .privateStore:
            if code >= 401 { base = 401; names = ["import.invalidDocument","import.unsupportedVersion","import.tooLarge","import.quota","import.stalePreview","import.cancelled","import.inaccessibleFile","import.changedFile","import.unsupportedFile","import.storageUnavailable"] }
            else if code >= 301 { base = 301; names = ["export.stalePreview","export.tooLarge","export.empty","export.invalidDestination","export.unsupportedDestination","export.destinationChanged","export.alreadyExists","export.accessDenied","export.cancelled","export.writeFailed","export.synchronizationFailed"] }
            else if code >= 201 { base = 201; names = ["state.invalidLocation","state.unavailable","state.unsafeState","state.changed","state.busy","state.requiresBackgroundWorker"] }
            else if code >= 101 { base = 101; names = ["reference.unsupported","reference.unavailable","reference.accessNeeded","reference.changed","reference.stale","reference.capacity","reference.cancelled","reference.followingRequired","reference.alreadyRemembered"] }
            else { base = 1; names = ["busy","unsafe","changed","unavailable","unsupported","recoveryRequired","initializationIncomplete","indexUpdateRequired","forgetPending","continuityUpdateRequired","uncertainCommit","readOnly","invalidRequest","quota","closed","referenceUpdateRequired"] }
        case .diagnostics:
            base = 1; names = ["empty","alreadyExists","invalidDestination","changed","accessDenied","cancelled","capacity","io"]
        case .sparkle:
            return [1000:"SUAppcastParseError",1001:"SUNoUpdateError",1002:"SUAppcastError",1003:"SURunningFromDiskImageError",
                1005:"SURunningTranslocated",1007:"SUReleaseNotesError",2000:"SUTemporaryDirectoryError",2001:"SUDownloadError",
                3000:"SUUnarchivingError",3001:"SUSignatureError",3002:"SUValidationError",4000:"SUFileCopyFailure",
                4001:"SUAuthenticationFailure",4002:"SUMissingUpdateError",4003:"SUMissingInstallerToolError",4004:"SURelaunchError",
                4005:"SUInstallationError",4006:"SUDowngradeError",4007:"SUInstallationCanceledError",4008:"SUInstallationAuthorizeLaterError",
                4009:"SUNotValidUpdateError",4010:"SUAgentInvalidationError",4012:"SUInstallationWriteNoPermissionError",5000:"SUIncorrectAPIUsageError"][code]
        case .security:
            return [-25293:"errSecAuthFailed",-25300:"errSecItemNotFound",-25308:"errSecInteractionNotAllowed",-128:"errSecUserCanceled",-34018:"errSecMissingEntitlement"][code]
        case .benchmark:
            base = 1
            names = ["benchmark.busy", "benchmark.invalidDirectory", "benchmark.insufficientSpace", "benchmark.preparation",
                     "benchmark.write", "benchmark.read", "benchmark.verification", "benchmark.changed", "benchmark.cleanup",
                     "benchmark.timedOut", "benchmark.close"]
        case .unknown: return nil
        }
        guard code >= base, code - base < Int64(names.count) else { return nil }
        return names[Int(code - base)]
    }
    private enum CodingKeys: String, CodingKey { case domain, code, symbol }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(domain: try values.decode(DiagnosticErrorDomain.self, forKey: .domain), code: try values.decode(Int64.self, forKey: .code))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(domain, forKey: .domain); try values.encode(code, forKey: .code)
        try values.encodeIfPresent(symbol, forKey: .symbol)
    }
}
