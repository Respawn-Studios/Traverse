import Foundation

/// A presented recovery choice is separate from permission to replay a transfer.
public enum CopyRecoveryAction: String, Sendable, CaseIterable {
    case confirmCopies, confirmUndo, finishReview

    public var title: String {
        switch self {
        case .confirmCopies: "Confirm Verified Copies"
        case .confirmUndo: "Confirm Completed Undo"
        case .finishReview: "Finish Recovery Review"
        }
    }
}

public enum CopyRecoveryItemState: String, Sendable {
    case notStarted, neverStaged, retainedCopy, copyNeedsConfirmation, copied
    case undoPending, undoNeedsConfirmation, undone, protected

    public var description: String {
        switch self {
        case .notStarted: "Not started"
        case .neverStaged: "Not staged"
        case .retainedCopy: "Verified copy retained"
        case .copyNeedsConfirmation: "Copy visible · confirmation needed"
        case .copied: "Copy complete"
        case .undoPending: "Undo pending · copy still visible"
        case .undoNeedsConfirmation: "Undo observed · confirmation needed"
        case .undone: "Undone"
        case .protected: "Needs review · preserved"
        }
    }
}

public struct CopyRecoveryItem: Identifiable, Sendable {
    public let id: Int
    public let source: URL
    public let destination: URL
    public let state: CopyRecoveryItemState
    public let protectionReason: String?
}

/// Only the owning engine can construct this one-attempt consent context. Opening
/// a review observes files; performing its explicit action rechecks everything.
public struct GroupedCopyRecoveryReview: Sendable {
    public let recordID: UUID
    public let revision: Int
    public let state: String
    public let items: [CopyRecoveryItem]
    public let availableActions: [CopyRecoveryAction]
    public let canUndo: Bool

    internal let owner: UUID
    internal let session: UUID
    internal let inventoryDigest: String
    internal let publicationMembers: [Int]
    internal let reversalMembers: [Int]
    internal let use: ContinuationUse
}
