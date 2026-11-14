import Foundation
import FileOperations
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Closed adapters for the actual remote document owners. This is only the
/// native editor's presentation vocabulary; it cannot mint a file handle,
/// rebuild authority from a path, retry a write or reinterpret durable records.
enum RemoteEditableTextBackend: Sendable {
    case sftp(SFTPInPlaceDocumentSession)
    case smb(SMBInPlaceDocumentSession)

    enum SaveResult: Sendable {
        case saved(generation: UUID), refusedBeforeSubmission(Refusal), needsReview
    }
    enum CloseResult: Sendable {
        case readyToCloseBuffer, closedUnusedCopyRemoved, closedVersionsRetained
        case disconnectedRecoveryRetained, pending, needsReview
    }
    enum Refusal: Equatable, Sendable {
        case sftp(SFTPInPlaceRefusalReason)
        case smb(SMBInPlaceRefusalReason)

        var needsVersionManagement: Bool {
            switch self {
            case .sftp(let reason): reason == .stagingCapacity
            case .smb(let reason): reason == .stagingCapacity
            }
        }
        /// This result follows a staged pair and a durable unsubmitted outcome.
        /// Early admission/resource failures do not imply a retained capture.
        var offersCapturedVersionReview: Bool {
            switch self {
            case .smb(.changed): true
            default: false
            }
        }
        var diagnosticLabel: String {
            switch self {
            case .sftp(let reason): reason.rawValue
            case .smb(let reason): "smb." + reason.rawValue
            }
        }
        var requiresReopen: Bool {
            switch self {
            case .smb(.changed), .smb(.unsupportedSource): true
            default: false
            }
        }
        var presentation: (status: String, explanation: String) {
            switch self {
            case .sftp(let reason):
                switch reason {
                case .stagingCapacity:
                    ("Saved versions are full", "The working space for saved versions is full. Save a local text copy before closing this editor. Manage Saved Versions to remove copies of closed documents you no longer need. Your text is kept.")
                case .workerBaselineCapacity:
                    ("Too many open editors", "Close another editor on this connection, then try Save again. Your text is kept.")
                case .stagingBusy, .browserEditorBusy, .browserFolderBusy, .browserDownloadBusy,
                     .browserUploadBusy, .browserNavigationBusy, .workerReadBusy, .workerAttemptBusy,
                     .workerReleaseBusy, .workerSettingsBusy:
                    ("Not saved · connection busy", "This connection is finishing another task. Try Save again in a moment. Your text is kept.")
                case .sessionUnavailable, .disconnected:
                    ("Not saved · connection unavailable", "This connection cannot save now. Save a local text copy before reconnecting. Your text is kept.")
                case .workerSettingsUnsupported:
                    ("Saved versions need attention", "These saved versions need a compatible version of Traverse. Save a local text copy to keep this edit.")
                case .stagingFailed:
                    ("Not saved · preparation failed", "The edit could not be prepared for Save. Your text is kept.")
                }
            case .smb(let reason):
                switch reason {
                case .sessionUnavailable, .disconnected:
                    ("Not saved · connection unavailable", "This connection cannot save now. Save a local text copy before reconnecting. Your text is kept.")
                case .unsupportedSource:
                    ("Not saved · unsupported file", "This file cannot be updated with the server's available identity and access checks. Save a local text copy to keep this edit.")
                case .changed:
                    ("Not saved · server file changed", "The server file no longer matches the version you opened. Your edit is kept. Review the retained versions or save a local text copy before opening the current file again.")
                case .stagingCapacity:
                    ("Saved versions are full", "Saved-version space is full. Save a local text copy before closing this editor. Your text is kept.")
                case .stagingBusy, .browserBusy:
                    ("Not saved · connection busy", "This connection is finishing another task. Try Save again in a moment. Your text is kept.")
                case .stagingFailed:
                    ("Not saved · preparation failed", "The edit could not be prepared for Save. Your text is kept.")
                }
            }
        }
    }

    var protocolName: String { switch self { case .sftp: "SFTP"; case .smb: "SMB" } }
    var protocolKind: ExplorerConnectionProtocol { switch self { case .sftp: .sftp; case .smb: .smb } }
    func nativeBufferDidInstall() {
        switch self {
        case .sftp(let document): document.nativeBufferDidInstall()
        case .smb(let document): document.nativeBufferDidInstall()
        }
    }
    func save(contents: TextDocumentValue, generation: UUID) async -> SaveResult {
        switch self {
        case .sftp(let document):
            switch await document.save(contents: contents, generation: generation) {
            case .saved(let receipt): .saved(generation: receipt.generation)
            case .refusedBeforeSubmission(let reason): .refusedBeforeSubmission(.sftp(reason))
            case .needsReview, .savedRemotelyRecoveryNeedsAttention: .needsReview
            }
        case .smb(let document):
            switch await document.save(contents: contents, generation: generation) {
            case .saved(let receipt): .saved(generation: receipt.generation)
            case .refusedBeforeSubmission(let reason): .refusedBeforeSubmission(.smb(reason))
            case .needsReview, .savedRemotelyRecoveryNeedsAttention: .needsReview
            }
        }
    }
    #if TRAVERSE_SFTP_EDITOR_QA
    func smbSaveDiagnosticCheckpoint(for generation: UUID) async -> UInt8? {
        guard case .smb(let document) = self else { return nil }
        return await document.diagnosticCheckpoint(for: generation)
    }
    #endif
    func stopAndDrain() async -> Bool {
        switch self {
        case .sftp(let document): await document.stopAndDrain().localResourcesEnded
        case .smb(let document): await document.stopAndDrain().ownerReleased
        }
    }
    func recoveryChoicesAfterExplicitRequest() async throws -> [RemoteRetainedTextChoice] {
        switch self {
        case .sftp(let document): try await document.recoveryChoicesAfterExplicitRequest().map(RemoteRetainedTextChoice.sftp)
        case .smb(let document): try await document.recoveryChoicesAfterExplicitRequest().map(RemoteRetainedTextChoice.smb)
        }
    }
    func closeAfterExplicitBufferDecision() async -> CloseResult {
        switch self {
        case .sftp(let document): Self.closeResult(await document.closeAfterExplicitBufferDecision())
        case .smb(let document): Self.closeResult(await document.closeAfterExplicitBufferDecision())
        }
    }
    func nativeBufferDidClose() async -> CloseResult {
        switch self {
        case .sftp(let document): Self.closeResult(await document.nativeBufferDidClose())
        case .smb(let document): Self.closeResult(await document.nativeBufferDidClose())
        }
    }
    private static func closeResult(_ result: SMBInPlaceCloseResult) -> CloseResult {
        switch result {
        case .readyToCloseBuffer: .readyToCloseBuffer
        case .closedUnusedCopyRemoved: .closedUnusedCopyRemoved
        case .closedVersionsRetained: .closedVersionsRetained
        case .disconnectedRecoveryRetained: .disconnectedRecoveryRetained
        case .pending: .pending
        case .needsReview: .needsReview
        }
    }
    private static func closeResult(_ result: SFTPInPlaceCloseResult) -> CloseResult {
        switch result {
        case .readyToCloseBuffer: .readyToCloseBuffer
        case .closedUnusedCopyRemoved: .closedUnusedCopyRemoved
        case .closedVersionsRetained: .closedVersionsRetained
        case .disconnectedRecoveryRetained: .disconnectedRecoveryRetained
        case .pending: .pending
        case .needsReview: .needsReview
        }
    }
}
