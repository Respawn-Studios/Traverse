/// Product availability, independent of file authority or a server's permissions.
/// Every command must still pass its existing session, access and integrity checks.
/// Build numbers identify artifacts; they never select a product feature set.
public struct ProductCapabilities: Sendable, Equatable {
    public enum Edition: Sendable, Equatable {
        case development, preview, privateBeta, publicRelease, directPublic, appStore, unrecognized

        public var isScopedDirect: Bool { self == .privateBeta || self == .publicRelease }
        public var isDeveloperID: Bool { isScopedDirect || self == .directPublic }
    }

    public enum Feature: String, Sendable, CaseIterable {
        case serverActions, serverDirectoryActions, serverMove, serverCut
        case serverDropUpload, serverFolderUpload, serverPasteUpload, routedUpload
        case routedEditor, smbOriginalTextEditing, archiveTabs, tarBrowsing, archiveTextPreview, tarCreation
        case selectionGrouping, airDrop, fileBenchmarks, driveHealth, driveHealthLiveUpdates, apfsVolumeCreation
        case authoredZIPChanges, localTrashAndRestore
        case serverSingleFileDownloads, serverGroupDownloads, serverDownloads
        case archiveSingleFileExtraction, archiveExtraction, archiveMemberChanges, nativeTrash
        case archiveZIPTreeExtraction, archiveTARTreeExtraction, archiveTARSingleFileExtraction
        case archiveInternalTransfers, archiveExternalPromises
    }

    public enum Hold: Sendable, Equatable {
        case fileProtection, hardwareQualification, storeQualification, unknownEdition
    }

    public enum Availability: Sendable, Equatable {
        case available
        case held(Hold)
        public var isAvailable: Bool { self == .available }
    }

    public let edition: Edition
    public init(edition: Edition) { self.edition = edition }

    public func availability(of feature: Feature) -> Availability {
        guard edition != .unrecognized else { return .held(.unknownEdition) }
        if edition == .directPublic {
            // This composition has its own storage and updater identities.
            // The existing route owners still validate every mutation and
            // download; product availability alone is never file authority.
            switch feature {
            case .driveHealth, .driveHealthLiveUpdates, .archiveExternalPromises:
                // Reach the ordinary flows in the local-review-only candidate.
                // Signed service/device and archive publication owners retain
                // authority. Developer ID Live also requires fresh opt-in.
                return .available
            case .archiveMemberChanges:
                // The direct TAR workbench uses its separately qualified native
                // owner. Product availability does not grant file authority.
                return .available
            case .apfsVolumeCreation:
                return .held(.hardwareQualification)
            case .archiveExtraction, .nativeTrash:
                return .held(.fileProtection)
            default:
                return .available
            }
        }
        switch feature {
        case .serverSingleFileDownloads, .archiveSingleFileExtraction,
             .archiveZIPTreeExtraction, .archiveTARTreeExtraction, .archiveTARSingleFileExtraction,
             .authoredZIPChanges, .localTrashAndRestore, .archiveExternalPromises,
             .serverGroupDownloads, .serverDownloads, .archiveInternalTransfers:
            // Only a concrete qualified publication owner can use these paths.
            // Groups, folders and internal archive copies retain their qualified owners.
            return edition == .appStore ? .held(.storeQualification) : .available
        case .archiveExtraction, .archiveMemberChanges, .nativeTrash:
            // The existing Preview experiments remain separate from production
            // publication. A UI availability change cannot qualify their engines.
            return edition == .development || edition == .preview
                ? .available : .held(.fileProtection)
        case .driveHealth, .driveHealthLiveUpdates:
            // Signed internal manual-to-Live integration is qualified. Concrete
            // owners retain service/attachment checks, beta opt-in and internal-
            // only automatic sampling. Installed/device coverage stays separate.
            return edition == .development || edition == .preview || edition.isScopedDirect
                ? .available : .held(.hardwareQualification)
        case .apfsVolumeCreation:
            // The App's operation admission additionally requires a freshly
            // observed disk image. Physical storage and signed editions remain
            // separate qualifications; this is never sandbox/device authority.
            return edition == .development ? .available : .held(.hardwareQualification)
        case .tarCreation:
            return edition == .development || edition == .preview || edition.isScopedDirect
                ? .available : .held(.fileProtection)
        case .serverActions, .serverDirectoryActions, .serverMove, .serverCut,
             .serverDropUpload, .serverFolderUpload, .serverPasteUpload, .routedUpload,
             .routedEditor, .smbOriginalTextEditing, .fileBenchmarks, .selectionGrouping:
            return edition == .appStore ? .held(.storeQualification) : .available
        case .archiveTabs, .tarBrowsing, .archiveTextPreview, .airDrop:
            return .available
        }
    }

    public func allows(_ feature: Feature) -> Bool { availability(of: feature).isAvailable }
}
