import Foundation
import ExplorerCore

/// SFTP and SMB regular-file publication use the qualified macOS contract.
/// Other Download routes retain their independent holds. Browsing, uploads, private editor
/// reads and review of existing recovery data have their own owners and gates.
enum RemoteDownloadPublicationFeature {
    private static let reviewedPublicSelectionAdoptionEnabled = true
    /// Presentation only. Respect the effective feature result, including the
    /// separately admitted generated QA path, without changing its authority.
    static func versionHoldExplanation(featureAvailable: Bool) -> String? {
        guard !featureAvailable, !AppFeatureAvailability.allows(.serverDownloads) else { return nil }
        return "Downloading server files is not available in this version of Traverse."
    }

    /// Only the exact generated, case-bound QA launch reaches the same-inode
    /// v7 experiment. Its engine still requires the complete received mark.
    static var qualifiesSingleFileAdoption: Bool { GeneratedSandboxReview.v7DownloadAdmitted }
    private static var ordinaryPublicQuarantineAvailable: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        return false
        #else
        return AppFeatureAvailability.allows(.serverSingleFileDownloads)
        #endif
    }
    static var qualifiesPublicQuarantineDownload: Bool {
        GeneratedSandboxReview.publicQuarantineDownloadAdmitted
            || GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted || ordinaryPublicQuarantineAvailable
    }
    /// The signed SMB review is separate from the SFTP review. Neither
    /// review role enables another protocol or broadens group publication.
    static var qualifiesSMBPublicQuarantineDownload: Bool {
        GeneratedSandboxReview.smbPublicQuarantineDownloadAdmitted
            || GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted || ordinaryPublicQuarantineAvailable
    }
    static var singleFileReviewAdmitted: Bool {
        qualifiesSingleFileAdoption || GeneratedSandboxReview.publicQuarantineDownloadAdmitted
            || GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
    }
    static var singleFileAvailable: Bool {
        available || singleFileReviewAdmitted || ordinaryPublicQuarantineAvailable
    }
    static var smbSingleFileAvailable: Bool {
        available || ordinaryPublicQuarantineAvailable || GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted
    }

    /// A sealed selection of regular files uses independent v14 publications.
    /// It grants no directory, external-promise or atomic-group operation.
    static var qualifiesPublicQuarantineGroupDownload: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.publicSelectionDownloadAdmitted
        #else
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--verify-ui") && (args.contains("--check-sftp-download-ui") && args.contains("--batch-flow")
            || args.contains("--check-smb-selected-download")
                && args.contains(where: { ["group-preflight", "group-success", "group-stop", "group-review"].contains($0) })) {
            return true
        }
        #endif
        return reviewedPublicSelectionAdoptionEnabled && AppFeatureAvailability.allows(.serverGroupDownloads)
        #endif
    }
    static var groupAvailable: Bool { available || qualifiesPublicQuarantineGroupDownload }

    /// Source qualification uses the ordinary folder receiver and publication
    /// owner. Only the separate counted remote-selection route enables v16 in
    /// signed QA; ordinary editions additionally need their shared capability.
    static var qualifiesPublicQuarantineFolderDownload: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.publicSelectionDownloadAdmitted
        #else
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--verify-ui") && args.contains("--public-tree-candidate") { return true }
        #endif
        return reviewedPublicSelectionAdoptionEnabled && AppFeatureAvailability.allows(.serverDownloads)
        #endif
    }
    static var folderAvailable: Bool { available || qualifiesPublicQuarantineFolderDownload }

    static func folderCompletionMessage(succeeded: Bool, stagingRemoved: Bool) -> String {
        guard succeeded else { return "Download needs review. Open Results for details." }
        return "Folder downloaded." + (stagingRemoved ? "" : " Temporary download needs review.")
    }

    static var available: Bool {
        #if MAC_EXPLORER_DISTRIBUTION
        return false
        #else
        return Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil
        #endif
    }
}
