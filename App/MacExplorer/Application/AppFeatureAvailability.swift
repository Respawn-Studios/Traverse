import ExplorerCore
import Foundation

/// The common presentation policy for both product packages. This is not an
/// entitlement check: operation owners and signed helpers retain that authority.
enum AppFeatureAvailability {
    static let policy = ProductCapabilities(edition: edition)

    static func allows(_ feature: ProductCapabilities.Feature) -> Bool {
        if GeneratedDriveImageReview.requested {
            return GeneratedDriveImageReview.warmAdmitted && feature == .apfsVolumeCreation
        }
        if GeneratedArchiveDriveReview.requested {
            guard GeneratedArchiveDriveReview.archiveAdmitted else { return false }
            switch feature {
            case .archiveTabs, .tarBrowsing:
                return true
            case .archiveTextPreview:
                return !GeneratedArchiveDriveReview.tarPromisesAdmitted
            case .archiveExternalPromises:
                return GeneratedArchiveDriveReview.tarPromisesForwardAdmitted
            case .archiveTARTreeExtraction, .archiveTARSingleFileExtraction:
                return GeneratedArchiveDriveReview.tarPromisesAdmitted
            case .tarCreation, .authoredZIPChanges, .archiveMemberChanges:
                return GeneratedArchiveDriveReview.archiveForwardAdmitted
            default:
                return false
            }
        }
        // This generated certificate role authenticates and lists metadata
        // only. It cannot select a product mutation/body-transfer candidate.
        if GeneratedSandboxReview.certificateConnectionAdmitted { return false }
        // This exact QA visit selects only its TAR Create capability.
        if GeneratedSandboxReview.nativeTARCreateAdmitted { return feature == .tarCreation }
        // Other signed visits cannot inherit ordinary Preview/beta TAR
        // availability through their shared private-beta presentation role.
        if GeneratedSandboxReview.admitted && feature == .tarCreation { return false }
        if GeneratedSandboxReview.archivePromiseAdmitted {
            return feature == .archiveTabs || feature == .archiveExternalPromises
        }
        if GeneratedSandboxReview.archiveInternalAdmitted {
            return feature == .archiveTabs || feature == .tarBrowsing || feature == .archiveInternalTransfers
        }
        // The counted local archive review needs browsing plus its separately
        // admitted extraction owners, never another product feature's writes.
        if GeneratedSandboxReview.archivePublicAccessAdmitted {
            switch feature {
            case .archiveTabs, .tarBrowsing, .archiveTextPreview: break
            default: return false
            }
        }
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            // Real session/body and group/folder gates stay protocol-specific.
            guard feature == .serverSingleFileDownloads else { return false }
        }
        return policy.allows(feature)
    }

    static var editionTitle: String {
        switch policy.edition {
        case .development: "Development"
        case .preview: "Local Preview"
        case .privateBeta: "Private Beta"
        case .publicRelease: "Open Source"
        case .directPublic: "Direct Edition"
        case .appStore: "App Store"
        case .unrecognized: "Review Build"
        }
    }

    private static var edition: ProductCapabilities.Edition {
        // The already-admitted generated sandbox uses the shipping presentation
        // policy. Its separate operation gates still control every QA mutation.
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.admitted { return .privateBeta }
        #endif
        let bundle = Bundle.main
        let channel = bundle.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String
        if bundle.bundleIdentifier == "local.macexplorer.preview", channel == "development-preview" {
            return .preview
        }
        if bundle.bundleIdentifier == "local.macexplorer.development", channel == nil || channel == "development" {
            return .development
        }
        #if MAC_EXPLORER_DISTRIBUTION
        if bundle.bundleIdentifier == "com.respawnstudios.traverse" {
            if channel == "app-store" { return .appStore }
            #if TRAVERSE_PRIVATE_UPDATER
            if channel == "developer-id",
               bundle.object(forInfoDictionaryKey: "MacExplorerAccessPolicy") as? String == "sandbox-selected-v1" {
                return .privateBeta
            }
            #endif
            #if TRAVERSE_PUBLIC_UPDATER
            if channel == "developer-id",
               bundle.object(forInfoDictionaryKey: "MacExplorerAccessPolicy") as? String == "sandbox-selected-v1",
               bundle.object(forInfoDictionaryKey: "TraversePublicUpdaterVersion") as? String == "2.10.0",
               bundle.object(forInfoDictionaryKey: "TraversePrivateUpdaterVersion") == nil {
                return .publicRelease
            }
            #endif
            #if TRAVERSE_PUBLIC_UPDATER && TRAVERSE_LOCAL_USER_DIRECT
            if DirectPublicEditionIdentity.matches(identifier: bundle.bundleIdentifier,
                                                  info: bundle.infoDictionary ?? [:]) {
                return .directPublic
            }
            #endif
        }
        #endif
        return .unrecognized
    }
}
