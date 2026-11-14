import Foundation

@_spi(Qualification) public struct SMBInPlaceSavedReceipt: Sendable, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID
    public var debugDescription: String { "<checked original SMB Save>" }
    init(generation: UUID, recordID: UUID) { self.generation = generation; self.recordID = recordID }
}
@_spi(Qualification) public enum SMBInPlaceRefusalReason: String, Sendable {
    case sessionUnavailable, unsupportedSource, changed, stagingCapacity, stagingBusy, stagingFailed
    case browserBusy, disconnected
}
@_spi(Qualification) public enum SMBInPlaceSaveResult: Sendable {
    case saved(SMBInPlaceSavedReceipt)
    case refusedBeforeSubmission(SMBInPlaceRefusalReason)
    case needsReview(recordID: UUID?)
    case savedRemotelyRecoveryNeedsAttention(recordID: UUID)
}
@_spi(Qualification) public enum SMBInPlaceCloseResult: Sendable {
    case readyToCloseBuffer, closedUnusedCopyRemoved, closedVersionsRetained
    case disconnectedRecoveryRetained, pending, needsReview
}
@_spi(Qualification) public enum SMBInPlaceRecoveryVersion: Sendable, Equatable { case before, edited }
@_spi(Qualification) public enum SMBInPlaceRecoveryOutcome: Sendable, Equatable {
    case notStarted, needsReview, verified
}
