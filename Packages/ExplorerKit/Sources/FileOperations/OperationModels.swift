import Foundation

public enum FileOperationRequest: Sendable {
    case createFolder(parent: URL, name: String)
    case rename(source: URL, name: String)
    case copy(sources: [URL], destinationDirectory: URL)
    case move(sources: [URL], destinationDirectory: URL)
    case moveObserved(selection: FileOperationSelection, destinationDirectory: URL)
    case trash(sources: [URL])
}

/// Opaque local object observations, including directory/root guards. Not a permission grant.
public struct FileOperationSelection: Sendable {
    public let urls: [URL]
    internal let identities: [EntrySnapshot]
    /// Observed filesystem membership for lifecycle coordination only. These
    /// numbers confer no mutation authority and must not be persisted as identity.
    public var observedFileSystemIDs: Set<Int64> { Set(identities.map { Int64($0.device) }) }

    /// Compare a recorded location with a fresh engine observation without
    /// exposing a constructor for operation identities or granting authority.
    public func matchesObject(at url: URL, device: UInt64, inode: UInt64) -> Bool {
        guard let index = urls.firstIndex(of: url), index < identities.count else { return false }
        let value = identities[index]
        return UInt64(UInt32(bitPattern: value.device)) == device && value.inode == inode
    }

    /// Combine source and destination observations without replacing either consent token.
    public func combining(_ other: FileOperationSelection) -> FileOperationSelection {
        FileOperationSelection(urls: urls + other.urls, identities: identities + other.identities)
    }

    /// Uses cached observations only; callers must still revalidate before moving.
    public func sharesFileSystem(with other: FileOperationSelection) -> Bool {
        guard !urls.isEmpty, !other.urls.isEmpty, urls.count == identities.count,
              other.urls.count == other.identities.count, let device = identities.first?.device else { return false }
        return identities.allSatisfy { $0.device == device } && other.identities.allSatisfy { $0.device == device }
    }

    /// Removes skipped inputs while preserving the remaining observations from Cut.
    public func excluding(_ skipped: Set<URL>) -> FileOperationSelection {
        let retained = zip(urls, identities).filter { !skipped.contains($0.0) }
        return FileOperationSelection(urls: retained.map { $0.0 }, identities: retained.map { $0.1 })
    }
}

public enum FileOperationFailure: String, Error, Sendable {
    case invalidRequest, conflict, sourceChanged, destinationChanged, accessDenied, notFound
    case copyContentMismatch, copyMetadataMismatch, copyOwnershipMismatch
    case operationHistoryProtected, protectedLocation
    case undoEndedByCheckpoint, textUndoCapacityReached, legacyTextHistoryRequiresReview
    case crossVolumeMoveUnsupported, unsupported, unavailable, outOfSpace, quotaExceeded, ioFailure, recoveryUncertain

    public var userMessage: String {
        switch self {
        case .invalidRequest: "This request contains an unsafe name, location, or selection."
        case .operationHistoryProtected: "This request overlaps Mac Explorer’s live operation history. Choose a different item or destination."
        case .protectedLocation: "This selection overlaps protected application or analysis data. Choose a smaller item or a different location."
        case .conflict: "An item already exists at the destination. Nothing was replaced."
        case .sourceChanged: "An observed item changed before or during this operation. Review the reported locations."
        case .destinationChanged: "The destination changed during this operation."
        case .copyContentMismatch: "The copy could not be verified. Your original was kept."
        case .copyOwnershipMismatch: "The native copy has different owner or group metadata. Choose Native owner/group in Paste with Options to allow this difference explicitly."
        case .copyMetadataMismatch: "The copy’s file details could not be verified. Your original was kept."
        case .accessDenied: "Access was denied."
        case .notFound: "An item or location could not be found."
        case .crossVolumeMoveUnsupported: "Moving between volumes is not supported yet. The source was preserved."
        case .undoEndedByCheckpoint: "File Undo for this version ended when a new Undo section was started."
        case .textUndoCapacityReached: "File Undo cannot add another change in this Undo section. Starting a new section ends its remaining file Undo."
        case .legacyTextHistoryRequiresReview: "This document has older text history whose volume identity needs review before another Save. Its saved versions remain protected."
        case .unsupported: "This item or filesystem operation is not supported."
        case .unavailable: "A required location is unavailable."
        case .outOfSpace: "A required volume has insufficient free space. Review any reported recovery locations."
        case .quotaExceeded: "The storage quota was exceeded. Review any reported recovery locations."
        case .ioFailure: "The filesystem operation failed. Review any reported recovery locations."
        case .recoveryUncertain: "Traverse needs to check where this item ended up. Review the recorded locations before trying again."
        }
    }
}

public enum FileOperationStatus: Equatable, Sendable {
    case succeeded
    /// The caller explicitly chose to leave this source and destination untouched.
    case skipped
    /// This input was never attempted because the batch stopped or admission failed.
    case notStarted
    case cancelled
    case failed(FileOperationFailure)
}

public enum FileOperationOutcomeRole: String, Sendable {
    /// One resolved transfer unit, or an ordinary create/rename/Trash operation.
    case transfer
    /// Retiring a merged source folder after child transfers. Its status does not
    /// describe whether that folder's children were already moved.
    case mergeContainer
    /// Admission, persistence or other job-level reporting, not another input item.
    case job
}

public struct FileOperationOutcome: Sendable {
    public let source: URL?
    public let destination: URL?
    public let status: FileOperationStatus
    /// Job-owned staging locations or known changed locations requiring review. Never silently deleted.
    public let recoveryURLs: [URL]
    public let role: FileOperationOutcomeRole
    /// Stable within the prepared transfer; independent of its recovery record ID.
    public let itemID: UUID?
    public let rootID: UUID?
    public let rootSource: URL?

    public init(source: URL?, destination: URL?, status: FileOperationStatus, recoveryURLs: [URL],
                role: FileOperationOutcomeRole = .transfer, itemID: UUID? = nil,
                rootID: UUID? = nil, rootSource: URL? = nil) {
        self.source = source; self.destination = destination; self.status = status
        self.recoveryURLs = recoveryURLs; self.role = role; self.itemID = itemID
        self.rootID = rootID; self.rootSource = rootSource
    }
}

public enum FileOperationDisposition: String, Sendable {
    case succeeded, partial, cancelled, failed
}

public struct FileOperationResult: Sendable {
    public let items: [FileOperationOutcome]
    public let cancellationRequested: Bool

    public init(items: [FileOperationOutcome], cancellationRequested: Bool) {
        self.items = items
        self.cancellationRequested = cancellationRequested
    }

    public var disposition: FileOperationDisposition {
        let successes = items.filter { $0.status == .succeeded }.count
        if !items.isEmpty && items.allSatisfy({ $0.status == .succeeded || $0.status == .skipped }) { return .succeeded }
        if successes > 0 { return .partial }
        if items.contains(where: { if case .failed = $0.status { true } else { false } }) { return .failed }
        return .cancelled
    }
}

internal extension FileOperationRequest {
    var sources: [URL] {
        switch self {
        case .copy(let sources, _), .move(let sources, _), .trash(let sources): sources
        case .moveObserved(let selection, _): selection.urls
        case .rename(let source, _): [source]
        case .createFolder: []
        }
    }
}
