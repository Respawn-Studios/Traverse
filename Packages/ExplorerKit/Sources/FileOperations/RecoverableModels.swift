import Foundation

public enum TransferConflictResolution: String, Sendable { case skip, replace, merge, keepBoth }

/// Both modes verify observed native security propagation and retain exact fingerprints
/// for later operations. Destination ownership permits only native UID/GID differences.
public enum TransferMetadataPolicy: String, Sendable { case strict, destinationOwnership }

/// App-selected authority for native Trash and its inverse. Version-fenced
/// profiles never grant an older Trash record a new inverse capability.
public enum NativeTrashMutationPolicy: Sendable, Equatable {
    case held, regularFilesOnly, regularFilesAndDirectories, existingVerifiedPaths
}

public struct TransferConflict: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let canMerge: Bool
    public internal(set) var kind: TransferConflictKind = .other
    internal var destinationHistoryProtected = false
    public var canReplace: Bool { source != destination && !destinationHistoryProtected }
    public var destinationProtectionMessage: String? {
        destinationHistoryProtected ? FileOperationFailure.operationHistoryProtected.userMessage : nil
    }
}

/// Immutable observations bind conflict consent to the objects that were shown.
public struct TransferPlan: Sendable {
    public let jobID: UUID
    internal let progressReporter: OperationProgressReporter
    public let conflicts: [TransferConflict]
    public let sources: [URL]
    public let destinationDirectory: URL
    public let isMove: Bool
    public let metadataPolicy: TransferMetadataPolicy
    public internal(set) var executionDecision: TransferExecutionDecision = .standard(.previewOff)
    internal let entries: [TransferEntry]
    internal var groupedCopy: GroupedCopyAdmission? = nil
    internal var continuation: TransferContinuation? = nil
    internal var moveReservation: MoveRecordReservation? = nil
    internal var referenceMembers: [MoveReferenceTicket] = []
}

internal struct TransferEntry: Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let sourceIdentity: EntrySnapshot
    let sourceParent: EntrySnapshot
    let destinationIdentity: EntrySnapshot?
    let destinationParent: EntrySnapshot
    let children: [TransferEntry]?
}

public enum OperationRecoveryRecordKind: String, Sendable { case ordinary, groupedCopy, selectionGroup, textRevision }

/// A read-only lead for obtaining access before a committed operation's Undo.
/// This does not grant access, pin a filesystem object, or authorize mutation.
/// Undo must reopen the record and revalidate the live destination itself.
public struct OperationUndoAccessRequirement: Sendable, Equatable {
    public let recordID: UUID
    public let directory: URL

    internal init(recordID: UUID, directory: URL) {
        self.recordID = recordID
        self.directory = directory
    }
}

public struct OperationRecoveryRecord: Identifiable, Sendable {
    public let id: UUID
    public let operation: String
    public let createdAt: Date
    public let state: String
    public let locations: [URL]
    public let canUndo: Bool
    public let canRecover: Bool
    /// V13 ZIP / v18 TAR / v19 TAR.gz: one retained-original after-image and no replacement
    /// intent. The explicit restore action still rechecks the live filesystem.
    public let canRestoreOriginalZIP: Bool
    /// Shared presentation for separately admitted ZIP and TAR original updates.
    public var canRestoreOriginalArchive: Bool { canRestoreOriginalZIP }
    public var originalArchiveFormatName: String {
        switch operation {
        case "Update TAR": "TAR"; case "Update TAR.gz": "TAR.gz"; case "Update TAR.bz2": "TAR.bz2"; default: "ZIP"
        }
    }
    /// A fully validated v11 regular-file Trash record. This is independent of
    /// whether the native mark changed; older history never gains this status.
    public let nativeRegularFileTrashContract: Bool
    /// A fully validated v12 job containing a directory. It does not grant
    /// an inverse for older v9 or uncertain Trash history.
    public let nativeDirectoryTrashContract: Bool
    /// V11 only; says that a fresh, fully verified native Trash result changed
    /// at least one root mark. The mark itself is never exposed here.
    public let nativeTrashMarkChanged: Bool
    /// A native Trash intent has no verified after-image. Locations are review
    /// leads only; this flag grants no Undo, retry, or cleanup authority.
    public let requiresManualTrashReview: Bool
    /// A validated archive job stopped before recording a replacement step.
    /// Display only: this does not observe the ZIP now or grant any action.
    public let zipReplacementNotStarted: Bool
    public let kind: OperationRecoveryRecordKind

    internal init(id: UUID, operation: String, createdAt: Date, state: String, locations: [URL],
                  canUndo: Bool, canRecover: Bool, canRestoreOriginalZIP: Bool = false,
                  requiresManualTrashReview: Bool = false,
                  kind: OperationRecoveryRecordKind = .ordinary, zipReplacementNotStarted: Bool = false,
                  nativeTrashMarkChanged: Bool = false,
                  nativeRegularFileTrashContract: Bool = false,
                  nativeDirectoryTrashContract: Bool = false) {
        self.id = id; self.operation = operation; self.createdAt = createdAt; self.state = state
        self.locations = locations; self.canUndo = canUndo; self.canRecover = canRecover
        self.canRestoreOriginalZIP = canRestoreOriginalZIP
        self.requiresManualTrashReview = requiresManualTrashReview; self.kind = kind
        self.zipReplacementNotStarted = zipReplacementNotStarted
        self.nativeTrashMarkChanged = nativeTrashMarkChanged
        self.nativeRegularFileTrashContract = nativeRegularFileTrashContract
        self.nativeDirectoryTrashContract = nativeDirectoryTrashContract
    }
}

/// Observational readiness only. No case grants authority to mutate history or files.
public enum OperationHistoryReadiness: Sendable, Equatable {
    case absent
    case available(catalogVersion: Int)
    case legacyImportRequired
    case initializationIncomplete
    case busy
    case recoveryRequired
    case inspectionLimited
    case changed
    case unavailable
}

public struct OperationRecoveryInspection: Sendable {
    public let records: [OperationRecoveryRecord]
    /// Unreadable, corrupt or foreign entries are preserved and require manual review.
    public let refusedEntries: [URL]
    public let nextCursor: UUID?
    public let unfinishedCount: Int
    public let readiness: OperationHistoryReadiness
    public let legacyArchivesPresent: Bool
    public let unfinishedCountIsComplete: Bool

    internal init(records: [OperationRecoveryRecord], refusedEntries: [URL], nextCursor: UUID?,
                  unfinishedCount: Int, readiness: OperationHistoryReadiness = .available(catalogVersion: 3),
                  legacyArchivesPresent: Bool = false, unfinishedCountIsComplete: Bool = true) {
        self.records = records; self.refusedEntries = refusedEntries; self.nextCursor = nextCursor
        self.unfinishedCount = unfinishedCount; self.readiness = readiness
        self.legacyArchivesPresent = legacyArchivesPresent
        self.unfinishedCountIsComplete = unfinishedCountIsComplete
    }
}

public struct RecoverableOperationResult: Sendable {
    public let result: FileOperationResult
    public let recordID: UUID?
    public let continuation: TransferContinuation?
    /// Sparse metadata witnesses for explicitly admitted remembered members.
    /// These grant no file access or mutation and still require fresh inspection.
    public let referenceReceipts: [MoveReferenceReceipt]

    public init(result: FileOperationResult, recordID: UUID?, continuation: TransferContinuation? = nil,
                referenceReceipts: [MoveReferenceReceipt] = []) {
        self.result = result; self.recordID = recordID; self.continuation = continuation
        self.referenceReceipts = referenceReceipts
    }
}
