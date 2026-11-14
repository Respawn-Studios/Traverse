import ExplorerCore
import FileOperations
import Foundation

/// Distribution keeps these actions held while the selected native macOS
/// contract is qualified. A changed raw mark is not an ordering of protection.
enum OrdinaryNativeTrashFeature {
    static var available: Bool {
        if GeneratedSandboxReview.publicationOnlyReviewAdmitted { return false }
        if GeneratedSandboxReview.nativeTARCreateAdmitted { return false }
        // The selected native profile keeps older inverse UI held. Editor V5
        // retirement and Analyzer have their own narrower gates.
        if NativeLocalProtectionPolicy.selectedNativeTrashAdopted { return false }
        // The counted local review's ordinary UI and older inverse stay held.
        // Its exact retained-editor fixture has a separate engine selector.
        if GeneratedSandboxReview.localFileReviewAdmitted { return false }
        #if MAC_EXPLORER_DISTRIBUTION && !DEBUG && !TRAVERSE_SFTP_EDITOR_QA
        return false
        #else
        return true
        #endif
    }
    static let moveHoldMessage = "Move to Trash is unavailable in this beta. Use Finder for this item."
    static let recoveryHoldMessage = "Restore this item in Finder for this beta. You can still review its Traverse history."
    static let retirementHoldMessage = "Moving retained copies to Trash is unavailable in this beta. Your copies and history remain available."
}

/// The selected local contract can be adopted without granting the broader
/// owned-Trash, recovery-copy retirement, or historical inverse routes.
enum NativeLocalProtectionPolicy {
    // Independently qualified: signed file/folder Trash, cold Undo and mixed
    // cold Restore; authored ZIP Create/Copy and cold Undo. Native TAR Create
    // and public marking of new authored stages have separate policy gates.
    // Historical Trash inverses, editor V5 retirement and Delete keep separate gates.
    private static var eligibleEdition: Bool {
        #if MAC_EXPLORER_DISTRIBUTION && (TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER) && !DEBUG && !TRAVERSE_SFTP_EDITOR_QA
        return AppFeatureAvailability.policy.edition.isDeveloperID
        #elseif !MAC_EXPLORER_DISTRIBUTION && !DEBUG && !TRAVERSE_SFTP_EDITOR_QA
        return OwnedTrashFeature.previewIdentity
        #else
        return false
        #endif
    }

    static var selectedNativeTrashAdopted: Bool {
        eligibleEdition && AppFeatureAvailability.allows(.localTrashAndRestore)
    }

    /// Signed retained-editor V5 has its own adoption bit and requires the
    /// selected native-directory Trash profile. It grants no older inverse,
    /// recovery-copy maintenance or Delete authority.
    private static let retainedEditorNativeDirectoryV5Accepted = true
    static var retainedEditorNativeDirectoryV5Adopted: Bool {
        // The local-user state namespace has no qualified retained-editor
        // retirement history. Keep this narrower route on the scoped editions.
        retainedEditorNativeDirectoryV5Accepted && AppFeatureAvailability.policy.edition.isScopedDirect
            && selectedNativeTrashAdopted
    }

    static var editorVersionRetirementAvailable: Bool {
        if GeneratedSandboxReview.retainedEditorReadOnlyAdmitted { return false }
        return retainedEditorNativeDirectoryV5Adopted || OrdinaryNativeTrashFeature.available
    }

    static func localTextRetirementPolicy(ordinaryHistory: Bool) -> LocalTextRetirementPolicy {
        if GeneratedSandboxReview.retainedEditorReadOnlyAdmitted { return .held }
        if AppFeatureAvailability.policy.edition == .directPublic { return .held }
        if ordinaryHistory && (retainedEditorNativeDirectoryV5Adopted
            || GeneratedSandboxReview.retainedEditorRetirementV5Admitted) { return .nativeDirectoryV12 }
        return .legacyVerifiedPaths
    }

    static var trashPolicy: NativeTrashMutationPolicy {
        if GeneratedSandboxReview.retainedEditorReadOnlyAdmitted { return .held }
        if GeneratedSandboxReview.nativeTARCreateAdmitted { return .held }
        if GeneratedSandboxReview.localDirectoryReviewAdmitted { return .regularFilesAndDirectories }
        if GeneratedSandboxReview.localFileReviewAdmitted { return .regularFilesOnly }
        if selectedNativeTrashAdopted { return .regularFilesAndDirectories }
        if OrdinaryNativeTrashFeature.available { return .existingVerifiedPaths }
        return .held
    }

    static var regularFileTrashAvailable: Bool { trashPolicy != .held }

    /// Fresh selected Analyzer cleanup only. This does not admit retained-copy
    /// retirement, historical inverses or owned-Trash Delete.
    static var analyzerSelectedTrashAvailable: Bool {
        switch trashPolicy {
        case .existingVerifiedPaths: OrdinaryNativeTrashFeature.available
        case .regularFilesAndDirectories: selectedNativeTrashAdopted
        case .regularFilesOnly, .held: false
        }
    }

    static var narrowNativeTrashSelected: Bool {
        switch trashPolicy {
        case .regularFilesOnly, .regularFilesAndDirectories: true
        case .held, .existingVerifiedPaths: false
        }
    }

    static var authoredZIPCreateCopyAvailable: Bool {
        GeneratedSandboxReview.nativeAuthoredCreateAdmitted
            || eligibleEdition && AppFeatureAvailability.allows(.authoredZIPChanges)
    }

    static var nativeTARCreateAvailable: Bool {
        eligibleEdition && AppFeatureAvailability.allows(.tarCreation)
    }

    static var nativeAuthoredCreatePublicMarkAvailable: Bool {
        eligibleEdition && (AppFeatureAvailability.allows(.authoredZIPChanges)
            || AppFeatureAvailability.allows(.tarCreation))
    }

    static var authoredZIPOriginalUpdateAvailable: Bool {
        eligibleEdition && AppFeatureAvailability.allows(.authoredZIPChanges)
            && authoredZIPCreateCopyAvailable
    }

    static func permitsTrashRecovery(_ record: OperationRecoveryRecord) -> Bool {
        guard record.kind == .ordinary && record.operation == "Move to Trash" else { return true }
        switch trashPolicy {
        case .held: return false
        case .regularFilesOnly: return record.nativeRegularFileTrashContract
        case .regularFilesAndDirectories:
            return record.nativeRegularFileTrashContract || record.nativeDirectoryTrashContract
        case .existingVerifiedPaths: return true
        }
    }
}

/// The native irreversible action needs its own signed generated acceptance.
/// The accepted native C/D round trip is enabled only for the private Preview.
/// Distribution builds retain their existing policy.
enum OwnedTrashFeature {
    // Signed345C passed folder/file Trash, cold Restore, confirmed group Delete
    // and cold outcomes. Current-source packaging/install remain separate.
    private static let releasePreviewAdditiveRootAccepted = true

    fileprivate static var previewIdentity: Bool {
        #if DEBUG || TRAVERSE_SFTP_EDITOR_QA || MAC_EXPLORER_DISTRIBUTION
        false
        #else
        Bundle.main.bundleIdentifier == DevelopmentReviewProfile.identifier
            && Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == DevelopmentReviewProfile.channel
            && AppStorageLocations.layout != nil
        #endif
    }
    private static var releasePreviewIdentity: Bool {
        releasePreviewAdditiveRootAccepted && previewIdentity
    }

    static func releasePreviewAdditiveRootEnabled(at directory: URL) -> Bool {
        guard !NativeLocalProtectionPolicy.selectedNativeTrashAdopted,
              releasePreviewIdentity, let state = AppStorageLocations.stateDirectory else { return false }
        let journal = state.appendingPathComponent("operation-recovery", isDirectory: true)
        return directory.standardizedFileURL == journal.standardizedFileURL
    }

    static var ordinaryEnabled: Bool {
        #if DEBUG
        true
        #elseif TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.ownedTrashFeatureAdmitted
        #else
        releasePreviewIdentity
        #endif
    }

    static var runtimeReady: Bool {
        #if DEBUG
        true
        #elseif TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.ownedTrashRuntimeReady
        #else
        releasePreviewIdentity
        #endif
    }

    static var canMutate: Bool {
        #if DEBUG
        true
        #elseif TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.ownedTrashPhase == .resolve && runtimeReady
        #else
        releasePreviewIdentity
        #endif
    }

    /// Browsing is passive. A narrow native Trash profile can inspect its own
    /// committed groups without admitting the older owned-Trash Delete flow.
    static var browseAvailable: Bool { ordinaryEnabled || NativeLocalProtectionPolicy.narrowNativeTrashSelected }
    static var browseReady: Bool { runtimeReady || NativeLocalProtectionPolicy.narrowNativeTrashSelected }

    static func permitsRestore(_ group: OwnedTrashGroup) -> Bool {
        guard group.canRestoreWholeGroup, let record = group.recoveryRecord,
              record.kind == .ordinary, record.operation == "Move to Trash",
              NativeLocalProtectionPolicy.permitsTrashRecovery(record) else { return false }
        return canMutate || NativeLocalProtectionPolicy.narrowNativeTrashSelected
    }

    static var canPermanentlyDelete: Bool {
        canMutate && NativeLocalProtectionPolicy.trashPolicy == .existingVerifiedPaths
    }
    static func permitsDelete(_ group: OwnedTrashGroup) -> Bool {
        canPermanentlyDelete && group.canDeleteWholeGroup
    }
}
