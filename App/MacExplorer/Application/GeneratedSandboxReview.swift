import AppKit
import Foundation
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage
import CryptoKit
import Darwin

/// The existing compiled Release review identity. This is feature visibility
/// only; every operation still needs its normal access, helper and engine rules.
/// A plist or environment value cannot enable it in a shipping binary.
enum GeneratedSandboxReview {
    #if TRAVERSE_SFTP_EDITOR_QA
    private static let containerReviewCase = "9309F6A1-E7A3-45C2-A864-0CBF02880D63"
    private static let nativeTARCreateCase = "6A779858-0820-4B75-80B9-FD71778F11B4"
    private static let driveHealthLiveModifier = "--qualify-drive-health-live-two-read"
    private static let driveHealthExternalModifier = "--qualify-drive-health-external-unsupported"
    private static let retainedEditorReadOnlyModifier = "--qualify-retained-editor-v5-readonly-fixture"
    private static let retainedEditorReadOnlyFixture = "CD86EA57-99A3-41C9-9292-1B71881ED627"
    private enum DriveHealthReviewMode: Equatable { case live, externalUnsupported }
    @MainActor private static var driveHealthReviewRequestsAdmitted = 0
    @MainActor private static var driveHealthReviewArmConsumed = false
    @MainActor private static var driveHealthReviewMode: DriveHealthReviewMode?
    @MainActor private static var driveHealthLiveAutomaticArmed = false
    @MainActor private static var driveHealthReviewSelected: ManagedVolume?
    #endif
    private enum ContainerReviewRoute {
        case metadata, remoteCut, localFiles, localDirectories, nativeTARCreate
        case receivedFile, smbReceivedFile, smbEditor, smbEditorV3, zipOneFileExtraction, zipOneFileAccess, driveHealth, archivePublicAccess, archivePublicContinuation, archivePublicRepairedContinuation, sftpSelectionDownload, smbSelectionDownload, certificateConnection, archivePromise, archiveInternal
    }
    enum OwnedTrashPhase: String, CaseIterable {
        case bootstrap, warm, resolve, cold
    }

    static var admitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              let id = UUID(uuidString: text), id.uuidString == text,
              Bundle.main.bundleIdentifier == "local.macexplorer.sandbox.remote-editor." + text.replacingOccurrences(of: "-", with: "").lowercased(),
              Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "qualification",
              Bundle.main.object(forInfoDictionaryKey: "MacExplorerStorageMode") as? String == "portable" else { return false }
        return true
        #else
        return false
        #endif
    }

    /// The signed review image has editor rights without Download authority.
    /// The host's exact outer-container audit binds the generated Data inode
    /// before this QA command is accepted. The app verifies that identity
    /// again on every count. Ordinary distribution images omit this route.
    private static func dataIdentityDigest(arguments expected: [String]) -> String? {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard admitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else { return nil }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == expected.count + 2,
              Array(arguments.prefix(expected.count)) == expected,
              arguments[expected.count] == "--qualify-v7-data-root",
              expected.contains(identifier) else { return nil }
        let digest = arguments[expected.count + 1]
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return digest
        #else
        return nil
        #endif
    }

    private static var v7DownloadDigest: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else { return nil }
        return dataIdentityDigest(arguments: ["--qualify-v7-download-case", identifier,
            "--qualify-v7-stop-on-adoption", "2"])
    }
    private static var privateMarkProbeDigest: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else { return nil }
        return dataIdentityDigest(arguments: ["--qualify-v7-private-mark-case", identifier])
    }
    /// Each review visit is intercepted before ordinary startup. The exact
    /// parser below refuses mixed, malformed or unbound QA commands.
    static var containerReviewRequested: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        CommandLine.arguments.dropFirst().contains {
            $0.hasPrefix("--qualify-metadata-") || $0.hasPrefix("--qualify-remote-cut-")
                || $0.hasPrefix("--qualify-local-files-")
                || $0.hasPrefix("--qualify-local-directories-")
                || $0.hasPrefix("--qualify-native-tar-create-")
                || $0.hasPrefix("--qualify-received-file-")
                || $0.hasPrefix("--qualify-smb-received-file-")
                || $0.hasPrefix("--qualify-smb-editor-")
                || $0.hasPrefix("--qualify-zip-one-file-")
                || $0.hasPrefix("--qualify-drive-health-")
                || $0.hasPrefix("--qualify-archive-public-access-")
                || $0.hasPrefix("--qualify-archive-public-continuation-")
                || $0.hasPrefix("--qualify-archive-public-repaired-continuation-")
                || $0.hasPrefix("--qualify-sftp-selection-download-")
                || $0.hasPrefix("--qualify-smb-selection-download-")
                || $0.hasPrefix("--qualify-certificate-connection-")
                || $0.hasPrefix("--qualify-archive-promise-")
                || $0.hasPrefix("--qualify-archive-internal-")
        }
        #else
        false
        #endif
    }
    private static var containerReviewSelection: (route: ContainerReviewRoute, digest: String, fixtureID: String?)? {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard admitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              identifier == containerReviewCase || identifier == nativeTARCreateCase else { return nil }
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Exact archive/health continuations do not select a route or grant
        // fixture access. The external selector is an opaque path+volume hash.
        let continuesArchivePrefix = arguments.count == 7
            && arguments[6] == "--qualify-archive-internal-continue-prefix-four"
        let checksDriveHealthLive = arguments.count == 7 && arguments[6] == driveHealthLiveModifier
        let checksDriveHealthExternal = arguments.count == 8 && arguments[6] == driveHealthExternalModifier
            && arguments[7].utf8.count == 64
            && arguments[7].utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        guard ([4, 6].contains(arguments.count) || continuesArchivePrefix || checksDriveHealthLive
                || checksDriveHealthExternal),
              arguments[1] == identifier else { return nil }
        let route: ContainerReviewRoute
        switch (arguments[0], arguments[2]) {
        case ("--qualify-metadata-container-case", "--qualify-metadata-data-root"):
            route = .metadata
        case ("--qualify-remote-cut-container-case", "--qualify-remote-cut-data-root"):
            route = .remoteCut
        case ("--qualify-local-files-container-case", "--qualify-local-files-data-root"):
            route = .localFiles
        case ("--qualify-local-directories-container-case", "--qualify-local-directories-data-root"):
            route = .localDirectories
        case ("--qualify-native-tar-create-container-case", "--qualify-native-tar-create-data-root"):
            route = .nativeTARCreate
        case ("--qualify-received-file-container-case", "--qualify-received-file-data-root"):
            route = .receivedFile
        case ("--qualify-smb-received-file-container-case", "--qualify-smb-received-file-data-root"):
            route = .smbReceivedFile
        case ("--qualify-smb-editor-container-case", "--qualify-smb-editor-data-root"):
            route = .smbEditor
        case ("--qualify-smb-editor-v3-container-case", "--qualify-smb-editor-v3-data-root"):
            route = .smbEditorV3
        case ("--qualify-zip-one-file-container-case", "--qualify-zip-one-file-data-root"):
            route = .zipOneFileExtraction
        case ("--qualify-zip-one-file-access-container-case", "--qualify-zip-one-file-access-data-root"):
            route = .zipOneFileAccess
        case ("--qualify-drive-health-container-case", "--qualify-drive-health-data-root"):
            route = .driveHealth
        case ("--qualify-archive-public-access-container-case", "--qualify-archive-public-access-data-root"):
            route = .archivePublicAccess
        case ("--qualify-archive-public-continuation-container-case", "--qualify-archive-public-continuation-data-root"):
            route = .archivePublicContinuation
        case ("--qualify-archive-public-repaired-continuation-container-case", "--qualify-archive-public-repaired-continuation-data-root"):
            route = .archivePublicRepairedContinuation
        case ("--qualify-sftp-selection-download-container-case", "--qualify-sftp-selection-download-data-root"):
            route = .sftpSelectionDownload
        case ("--qualify-smb-selection-download-container-case", "--qualify-smb-selection-download-data-root"):
            route = .smbSelectionDownload
        case ("--qualify-certificate-connection-container-case", "--qualify-certificate-connection-data-root"):
            route = .certificateConnection
        case ("--qualify-archive-promise-container-case", "--qualify-archive-promise-data-root"):
            route = .archivePromise
        case ("--qualify-archive-internal-container-case", "--qualify-archive-internal-data-root"):
            route = .archiveInternal
        default: return nil
        }
        // The new case cannot select any retained visit; the old case cannot
        // select TAR Create, even if an exact command is supplied.
        guard (route == .nativeTARCreate) == (identifier == nativeTARCreateCase) else { return nil }
        let digest = arguments[3]
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        let fixtureID: String?
        switch route {
        case .archiveInternal:
            guard (arguments.count == 6 || continuesArchivePrefix),
                  arguments[4] == "--qualify-fixture",
                  UUID(uuidString: arguments[5])?.uuidString == arguments[5] else { return nil }
            fixtureID = arguments[5]
        case .driveHealth:
            guard (arguments.count == 6 || checksDriveHealthLive || checksDriveHealthExternal),
                  arguments[4] == "--qualify-fixture",
                  UUID(uuidString: arguments[5])?.uuidString == arguments[5] else { return nil }
            fixtureID = arguments[5]
        case .sftpSelectionDownload, .smbSelectionDownload, .certificateConnection, .archivePromise:
            // One fixture/attempt identity survives relaunch without selecting
            // another retained review's singleton history. This grants no URL
            // access; each role still obtains its actual system authority.
            guard arguments.count == 6, arguments[4] == "--qualify-fixture",
                  UUID(uuidString: arguments[5])?.uuidString == arguments[5] else { return nil }
            fixtureID = arguments[5]
        case .localDirectories where arguments.count == 6:
            // The separate read-only selector binds the spent warm attempt to
            // its one generated fixture. The four-argument review is unchanged.
            guard (arguments[4] == "--qualify-retained-editor-v5-fixture"
                    || (arguments[4] == retainedEditorReadOnlyModifier
                        && arguments[5] == retainedEditorReadOnlyFixture)),
                  UUID(uuidString: arguments[5])?.uuidString == arguments[5] else { return nil }
            fixtureID = arguments[5]
        default:
            guard arguments.count == 4 else { return nil }
            fixtureID = nil
        }
        return (route, digest, fixtureID)
        #else
        nil
        #endif
    }
    static var reviewFixtureID: String? { containerReviewSelection?.fixtureID }
    /// An intent restriction for generated callbacks, never folder authority.
    static var reviewFixtureRoot: URL? {
        guard let fixture = reviewFixtureID else { return nil }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent(".build/traverse-development", isDirectory: true)
            .appendingPathComponent(fixture, isDirectory: true)
    }
    /// Explicit, bounded private-state chains for the counted review roles.
    /// The ordinary single-leaf owner intentionally does not create ancestors.
    @MainActor static func prepareFixtureStateDirectory() async throws -> URL {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard let selection = containerReviewSelection, let fixture = selection.fixtureID,
              let state = AppStorageLocations.stateDirectory else { throw StateDirectoryPreparationError.unavailable }
        let name: String
        switch selection.route {
        case .localDirectories where retainedEditorRetirementV5Admitted || retainedEditorReadOnlyAdmitted:
            name = "retained-editor-v5-qa"
        case .certificateConnection: name = "certificate-connection-qa"
        case .driveHealth: name = "drive-health-qa"
        case .archivePromise: name = "archive-promise-qa"
        case .archiveInternal: name = "archive-internal-qa"
        case .sftpSelectionDownload: name = "received-selection-sftp-qa"
        case .smbSelectionDownload: name = "received-selection-smb-qa"
        default: throw StateDirectoryPreparationError.unavailable
        }
        try await AppStoragePreparation.owner(for: state).prepare()
        let namespace = state.appendingPathComponent(name, isDirectory: true)
        let directory = namespace.appendingPathComponent(fixture, isDirectory: true)
        try await PrivateStateDirectorySequence(directories: [namespace, directory],
            activity: ApplicationFileActivity.gate).prepare()
        return directory
        #else
        throw StateDirectoryPreparationError.unavailable
        #endif
    }
    /// The prospective signed Copy review reuses the existing exact remote
    /// route. Older compiled Cut/Paste receipts do not qualify this new image.
    static var conditionalServerCopyAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .remoteCut
        #else
        false
        #endif
    }
    /// A prepared, case-bound native review only. Ordinary Preview/private beta
    /// keep the held Download policy until the replacement contract is accepted.
    static var publicQuarantineDownloadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .receivedFile
        #else
        false
        #endif
    }

    /// SMB selected-file Download has its own counted QA role. The SFTP role
    /// and ordinary SMB product gates cannot select this candidate.
    static var smbPublicQuarantineDownloadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .smbReceivedFile
        #else
        false
        #endif
    }

    /// The original-file SMB Save candidate is independent of received-file
    /// Downloads. Only this counted, explicitly selected review uses v2.
    static var smbOriginalSaveV2Admitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .smbEditor
        #else
        false
        #endif
    }
    /// A separate proposed metadata contract. The older v2 command and
    /// ordinary app defaults cannot opt into this review by implication.
    static var smbOriginalSaveV3Admitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .smbEditorV3
        #else
        false
        #endif
    }
    static var smbOriginalSaveReviewAdmitted: Bool {
        smbOriginalSaveV2Admitted || smbOriginalSaveV3Admitted
    }
    /// Only this counted command can compose the held v15 one-file ZIP route.
    /// A product image lacks the QA compilation condition and exact command.
    static var zipOneFileExtractionAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .zipOneFileExtraction
            || containerReviewSelection?.route == .zipOneFileAccess
        #else
        false
        #endif
    }
    /// A separate counted route exercises actual OS-delivered folder access
    /// for one fresh v15 output and its cold Browser Undo.
    static var zipOneFileAccessAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .zipOneFileAccess
        #else
        false
        #endif
    }
    /// Read-only Drives UI review. Exact packaging, helper rights and one
    /// selected device remain independent gates; this grants no file command.
    static var driveHealthReadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .driveHealth
        #else
        false
        #endif
    }
    /// The existing signed one-read mode stays unchanged. Only its exact
    /// seven-argument continuation may expose a bounded Live review.
    static var driveHealthLiveReadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .driveHealth
            && CommandLine.arguments.last == driveHealthLiveModifier
        #else
        false
        #endif
    }
    /// A later signed visit binds one already observed external mount without
    /// placing its path or device identifier in process arguments or logs.
    static var driveHealthExternalSelectorDigest: String? {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard containerReviewSelection?.route == .driveHealth else { return nil }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 8, arguments[6] == driveHealthExternalModifier else { return nil }
        return arguments[7]
        #else
        return nil
        #endif
    }
    static func driveHealthExternalSelectorMatches(_ selected: ManagedVolume) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard let expected = driveHealthExternalSelectorDigest,
              selected.deviceKind == .externalDisk, selected.isInternal == false,
              let url = selected.url, url.isFileURL,
              let fileSystemID = selected.fileSystemID,
              let mediaID = selected.mediaID, mediaID != 0,
              let wholeID = selected.group, wholeID != 0 else { return false }
        let text = url.path + ":" + String(fileSystemID)
        let actual = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return actual == expected
        #else
        return false
        #endif
    }
    /// The QA visit first verifies the ordinary selected root and its Details
    /// observation. The launch modifier alone cannot initiate device work.
    @MainActor static func armDriveHealthLiveReview(for selected: ManagedVolume) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard driveHealthLiveReadAdmitted, !driveHealthReviewArmConsumed, driveHealthReviewMode == nil,
              driveHealthReviewSelected == nil, driveHealthReviewRequestsAdmitted == 0,
              selected.isInternal == true,
              selected.deviceKind == .internalDisk, selected.url?.path == "/",
              selected.mediaID != nil else { return false }
        driveHealthReviewArmConsumed = true
        driveHealthReviewMode = .live
        driveHealthReviewSelected = selected
        return true
        #else
        return false
        #endif
    }
    @MainActor static func armDriveHealthExternalReview(for selected: ManagedVolume) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard driveHealthExternalSelectorMatches(selected), !driveHealthReviewArmConsumed,
              driveHealthReviewMode == nil, driveHealthReviewSelected == nil,
              driveHealthReviewRequestsAdmitted == 0 else { return false }
        driveHealthReviewArmConsumed = true
        driveHealthReviewMode = .externalUnsupported
        driveHealthReviewSelected = selected
        return true
        #else
        return false
        #endif
    }
    /// The verifier advances only after the manual service reply is settled
    /// and qualified. A launch flag or manual start cannot authorize polling.
    @MainActor static func armDriveHealthLiveAutomaticRead(for selected: ManagedVolume) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard driveHealthLiveReadAdmitted, driveHealthReviewMode == .live,
              driveHealthReviewSelected == selected,
              driveHealthReviewRequestsAdmitted == 1, !driveHealthLiveAutomaticArmed else { return false }
        driveHealthLiveAutomaticArmed = true
        return true
        #else
        return false
        #endif
    }
    @MainActor static func disarmDriveHealthReview() {
        #if TRAVERSE_SFTP_EDITOR_QA
        // The one arm and its spent request slots never reset in this process.
        driveHealthReviewSelected = nil
        driveHealthReviewMode = nil
        driveHealthLiveAutomaticArmed = false
        #endif
    }
    /// Exact process-wide caps are claimed before native scheduling. An
    /// admitted failure consumes its slot; neither mode has a retry path.
    @MainActor static func claimDriveHealthReviewRequest(for selected: ManagedVolume, automatic: Bool) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        if admitted && !driveHealthReadAdmitted { return false }
        switch driveHealthReviewMode {
        case .live:
            guard driveHealthLiveReadAdmitted, driveHealthReviewSelected == selected,
                  driveHealthReviewRequestsAdmitted < 2,
                  ((driveHealthReviewRequestsAdmitted == 0 && !automatic)
                    || (driveHealthReviewRequestsAdmitted == 1 && automatic && driveHealthLiveAutomaticArmed)) else { return false }
        case .externalUnsupported:
            guard driveHealthExternalSelectorMatches(selected), driveHealthReviewSelected == selected,
                  driveHealthReviewRequestsAdmitted == 0, !automatic else { return false }
        case nil:
            // Retain the original six-argument one-read route. The exact
            // continuations must arm their selected attachment first.
            return !driveHealthLiveReadAdmitted && driveHealthExternalSelectorDigest == nil
        }
        driveHealthReviewRequestsAdmitted += 1
        #endif
        return true
    }
    /// A counted, metadata-only certificate connection journey. It selects no
    /// Download, upload, editor, archive, Trash or device-operation candidate.
    static var certificateConnectionAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .certificateConnection
        #else
        false
        #endif
    }
    static var archivePromiseAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .archivePromise
        #else
        false
        #endif
    }
    static var archiveInternalAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .archiveInternal
        #else
        false
        #endif
    }
    /// One counted local archive review; it grants no server Download,
    /// authored ZIP mutation, Trash, external drag or device operation.
    static var archivePublicAccessAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .archivePublicAccess || containerReviewSelection?.route == .archivePublicContinuation
            || containerReviewSelection?.route == .archivePublicRepairedContinuation
        #else
        false
        #endif
    }
    static var archivePublicContinuationAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .archivePublicContinuation
            || containerReviewSelection?.route == .archivePublicRepairedContinuation
        #else
        false
        #endif
    }
    static var archivePublicRepairedContinuationAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .archivePublicRepairedContinuation
        #else
        false
        #endif
    }
    /// The two received-selection roles are separate from each other and from
    /// archive extraction. They configure real read-only protocol sessions.
    static var sftpPublicSelectionDownloadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .sftpSelectionDownload
        #else
        false
        #endif
    }
    static var smbPublicSelectionDownloadAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .smbSelectionDownload
        #else
        false
        #endif
    }
    static var publicSelectionDownloadAdmitted: Bool {
        sftpPublicSelectionDownloadAdmitted || smbPublicSelectionDownloadAdmitted
    }
    static var publicationOnlyReviewAdmitted: Bool {
        archivePublicAccessAdmitted || publicSelectionDownloadAdmitted || archivePromiseAdmitted
    }
    /// Local acceptance uses the normal operation engine and folder chooser.
    /// The count is not a grant to a folder or permission to start a Download.
    static var localFileReviewAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .localFiles || containerReviewSelection?.route == .localDirectories
        #else
        false
        #endif
    }
    /// A distinct visit admits the versioned directory/mixed contract. The
    /// earlier localFiles command keeps its regular-file-only policy.
    static var localDirectoryReviewAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .localDirectories
        #else
        false
        #endif
    }
    /// Exact signed fixture admission only; no ordinary or older local visit
    /// gains retirement authority from the directory Trash policy alone.
    static var retainedEditorRetirementV5Admitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard containerReviewSelection?.route == .localDirectories,
              containerReviewSelection?.fixtureID != nil else { return false }
        return CommandLine.arguments.dropFirst().dropFirst(4).first == "--qualify-retained-editor-v5-fixture"
        #else
        false
        #endif
    }
    /// The spent warm attempt can be inspected once without selecting its
    /// mutation route or widening any other local-directory review.
    static var retainedEditorReadOnlyAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard containerReviewSelection?.route == .localDirectories,
              containerReviewSelection?.fixtureID == retainedEditorReadOnlyFixture else { return false }
        return CommandLine.arguments.dropFirst().dropFirst(4).first == retainedEditorReadOnlyModifier
        #else
        false
        #endif
    }
    /// The generated document must live below the same Data inode accepted by
    /// the signed launch count. This is an identity check, not a folder grant.
    static var retainedEditorBoundDataRoot: URL? {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard retainedEditorRetirementV5Admitted || retainedEditorReadOnlyAdmitted else { return nil }
        return GeneratedV7ContainerCount.boundDataRoot()
        #else
        return nil
        #endif
    }
    /// A separate signed visit selects only the native-stage TAR Create
    /// candidate. The older ZIP and local-files commands cannot select it.
    static var nativeTARCreateAdmitted: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        containerReviewSelection?.route == .nativeTARCreate
        #else
        false
        #endif
    }
    static var nativeAuthoredCreateAdmitted: Bool {
        containerReviewSelection?.route == .localFiles
            || ownedTrashFeatureAdmitted && !additiveRootTrashCaseAdmitted
    }
    /// Only the newly sealed local-files review selects the v13 candidate.
    /// Earlier immutable artifacts/receipts do not acquire Update coverage.
    static var nativeAuthoredOriginalUpdateAdmitted: Bool {
        containerReviewSelection?.route == .localFiles
    }
    static var ownedTrashRequested: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--qualify-owned-trash-") }
    }
    /// A distinct, compile-gated future case. The existing 8E B case and its
    /// argv shape cannot select the additive-root directory engine.
    private static var additiveRootTrashPhase: OwnedTrashPhase? {
        #if TRAVERSE_SFTP_EDITOR_QA && TRAVERSE_OWNED_TRASH_ROOT_ADD_QA
        guard admitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              identifier == "345C4751-4E71-437A-BE8B-6CF18527F77D" else { return nil }
        let arguments = Array(CommandLine.arguments.dropFirst())
        for phase in OwnedTrashPhase.allCases {
            let prefix = ["--qualify-owned-trash-additive-root-case", identifier,
                          "--qualify-owned-trash-phase", phase.rawValue]
            if phase == .bootstrap, arguments == prefix { return phase }
            if phase != .bootstrap, dataIdentityDigest(arguments: prefix) != nil { return phase }
        }
        #endif
        return nil
    }
    /// Constructor selection uses immutable launch identity. Container-count
    /// readiness remains a separate gate before every mutation.
    static var additiveRootTrashCaseAdmitted: Bool {
        guard let phase = additiveRootTrashPhase else { return false }
        return phase != .bootstrap
    }
    static var ownedTrashPhase: OwnedTrashPhase? {
        #if TRAVERSE_SFTP_EDITOR_QA
        if let phase = additiveRootTrashPhase { return phase }
        guard admitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else {
            return nil
        }
        #if TRAVERSE_OWNED_TRASH_ROOT_ADD_QA
        // The fresh directory case accepts only its separate C/D command.
        // Keep the older A/B command bound to its existing case.
        if identifier == "345C4751-4E71-437A-BE8B-6CF18527F77D" { return nil }
        #endif
        let arguments = Array(CommandLine.arguments.dropFirst())
        for phase in OwnedTrashPhase.allCases {
            let prefix = ["--qualify-owned-trash-case", identifier,
                          "--qualify-owned-trash-phase", phase.rawValue]
            if phase == .bootstrap, arguments == prefix { return phase }
            if phase != .bootstrap, dataIdentityDigest(arguments: prefix) != nil { return phase }
        }
        #endif
        return nil
    }
    private static var ownedTrashDataIdentityDigest: String? {
        if additiveRootTrashCaseAdmitted,
           let phase = additiveRootTrashPhase,
           let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String {
            return dataIdentityDigest(arguments: ["--qualify-owned-trash-additive-root-case", identifier,
                "--qualify-owned-trash-phase", phase.rawValue])
        }
        guard let phase = ownedTrashPhase, phase != .bootstrap,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else {
            return nil
        }
        return dataIdentityDigest(arguments: ["--qualify-owned-trash-case", identifier,
            "--qualify-owned-trash-phase", phase.rawValue])
    }
    static var ownedTrashFeatureAdmitted: Bool {
        ownedTrashDataIdentityDigest != nil
    }
    static var ownedTrashRuntimeReady: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        ownedTrashFeatureAdmitted && GeneratedV7ContainerCount.ownedTrashLaunchAccepted
        #else
        false
        #endif
    }
    static func ownedTrashGroupAllowed(_ urls: [URL]) -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard ownedTrashFeatureAdmitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              urls.count == 2 else { return false }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/traverse-development/" + identifier + "/source/Operation Root", isDirectory: true)
        let names = Set(urls.map(\.lastPathComponent))
        let groupA: Set<String> = ["Trash-A1.txt", "Trash-A2.txt"]
        let groupB: Set<String> = ["Trash-B1.txt", "Trash-B2.txt"]
        let groupC: Set<String> = ["Trash-C1", "Trash-C2.txt"]
        let groupD: Set<String> = ["Trash-D1", "Trash-D2.txt"]
        let admittedGroup = additiveRootTrashCaseAdmitted
            ? (names == groupC || names == groupD) : (names == groupA || names == groupB)
        return admittedGroup && urls.allSatisfy {
            $0.isFileURL && $0.deletingLastPathComponent().standardizedFileURL.path == root.path
        }
        #else
        return false
        #endif
    }
    static func ownedTrashSourceAllowed(_ urls: [URL]) -> Bool {
        ownedTrashPhase == .warm && ownedTrashRuntimeReady && ownedTrashGroupAllowed(urls)
    }
    static var v7DataIdentityDigest: String? { v7DownloadDigest ?? privateMarkProbeDigest }
    static var v7DownloadAdmitted: Bool { v7DownloadDigest != nil }
    static var privateMarkProbeAdmitted: Bool { privateMarkProbeDigest != nil }

    /// The app counts its exact generated container from inside the sandbox.
    /// A failed or partial count permanently closes this launch's Download
    /// qualification, including later requests in the same process.
    static func accountV7Container(phase: String) async -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard v7DownloadAdmitted || privateMarkProbeAdmitted else { return false }
        let (result, verified) = await Task.detached(priority: .utility) {
            GeneratedV7ContainerCount.measureAndAccept(reservingBytes: phase == "before" ? 8 * 1_024 * 1_024 : 0)
        }.value
        GeneratedV7ContainerCount.report(result, phase: phase, verified: verified)
        return verified
        #else
        return false
        #endif
    }

    /// Case-bound visits share one launch/after container count. Local operations
    /// still need the ordinary engine and an actual user-selected folder grant.
    static func accountContainerReview(phase: String) async -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard let selection = containerReviewSelection, ["launch", "after"].contains(phase),
              !v7DownloadAdmitted, !privateMarkProbeAdmitted, !ownedTrashRequested else { return false }
        let (result, verified) = await Task.detached(priority: .utility) {
            GeneratedV7ContainerCount.measureAndAccept(reservingBytes: 0)
        }.value
        let route: GeneratedV7ContainerCount.Route
        switch selection.route {
        case .metadata: route = .metadata
        case .remoteCut: route = .remoteCut
        case .localFiles: route = .localFiles
        case .localDirectories: route = .localDirectories
        case .nativeTARCreate: route = .nativeTARCreate
        case .receivedFile: route = .receivedFile
        case .smbReceivedFile: route = .smbReceivedFile
        case .smbEditor: route = .smbEditor
        case .smbEditorV3: route = .smbEditorV3
        case .zipOneFileExtraction: route = .zipOneFileExtraction
        case .zipOneFileAccess: route = .zipOneFileAccess
        case .driveHealth: route = .driveHealth
        case .archivePublicAccess: route = .archivePublicAccess
        case .archivePublicContinuation: route = .archivePublicContinuation
        case .archivePublicRepairedContinuation: route = .archivePublicRepairedContinuation
        case .sftpSelectionDownload: route = .sftpSelectionDownload
        case .smbSelectionDownload: route = .smbSelectionDownload
        case .certificateConnection: route = .certificateConnection
        case .archivePromise: route = .archivePromise
        case .archiveInternal: route = .archiveInternal
        }
        GeneratedV7ContainerCount.report(result, phase: phase, verified: verified, route: route)
        return verified
        #else
        return false
        #endif
    }

    /// Reuses the exact bounded sandbox walker for a distinct Trash case.
    /// Bootstrap has no Data identity yet and cannot admit this count.
    static func accountOwnedTrashContainer(phase: String) async -> Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard ownedTrashDataIdentityDigest != nil,
              ["launch", "before", "after"].contains(phase),
              phase == "launch" || (ownedTrashRuntimeReady &&
                  (ownedTrashPhase == .warm || ownedTrashPhase == .resolve)) else { return false }
        let (result, verified) = await Task.detached(priority: .utility) {
            GeneratedV7ContainerCount.measureAndAccept(reservingBytes: phase == "before" ? 8 * 1_024 * 1_024 : 0)
        }.value
        GeneratedV7ContainerCount.recordOwnedTrashCount(phase: phase, verified: verified)
        GeneratedV7ContainerCount.report(result, phase: phase, verified: verified, route: .ownedTrash)
        return verified
        #else
        return false
        #endif
    }

    static func stopOwnedTrashQualification() {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard ownedTrashRequested else { return }
        GeneratedV7ContainerCount.stopOwnedTrash()
        fputs("TRAVERSE_OWNED_TRASH_QA admission=stopped\n", stderr)
        #endif
    }

    fileprivate static var countedDataIdentityDigest: String? {
        v7DataIdentityDigest ?? ownedTrashDataIdentityDigest ?? containerReviewSelection?.digest
    }
}

#if DEBUG || TRAVERSE_SFTP_EDITOR_QA
/// Reuses the existing native ZIP checkpoint for one complete generated
/// Save/Restore flow. Normal app compositions never select this callback.
final class GeneratedZIPRetainedCheckpoint: @unchecked Sendable {
    static let shared = GeneratedZIPRetainedCheckpoint(updatesBeforeInterruption: 3)
    private let lock = NSLock()
    private var remaining: Int?

    init(updatesBeforeInterruption: Int? = nil) { remaining = updatesBeforeInterruption }

    #if DEBUG
    /// The ordinary editor check explicitly selects its interrupted mutation.
    /// Earlier successful saves and close checks can share the same engine.
    func armNextUpdate() -> Bool {
        lock.withLock {
            guard remaining == nil else { return false }
            remaining = 1
            return true
        }
    }
    #endif
    func afterRetainedOriginal() throws {
        let stop = lock.withLock {
            guard let remaining else { return false }
            self.remaining = max(0, remaining - 1)
            return self.remaining == 0
        }
        if stop { throw FileOperationFailure.ioFailure }
    }
    var hasStopped: Bool { lock.withLock { remaining == 0 } }
}
#endif

#if TRAVERSE_SFTP_EDITOR_QA
private enum GeneratedV7ContainerCount {
    enum Route {
        case v7, ownedTrash, metadata, remoteCut, localFiles, localDirectories, nativeTARCreate
        case receivedFile, smbReceivedFile, smbEditor, smbEditorV3, zipOneFileExtraction, zipOneFileAccess, driveHealth, archivePublicAccess, archivePublicContinuation, archivePublicRepairedContinuation, sftpSelectionDownload, smbSelectionDownload, certificateConnection, archivePromise, archiveInternal
    }
    private static let maximumEntries = 1_024
    private static let maximumBytes: UInt64 = 64 * 1_024 * 1_024
    // The independent host audit requires the exact outer tree to fit inside
    // these reserves. Its count excludes only the positively bound Data inode.
    private static let outerReservedEntries = 16
    private static let outerReservedBytes: UInt64 = 8 * 1_024 * 1_024
    private static let dataMaximumEntries = maximumEntries - outerReservedEntries
    private static let dataMaximumBytes = maximumBytes - outerReservedBytes

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var failed = false
        var ownedTrashLaunchAccepted = false
    }
    private static let state = State()

    static var ownedTrashLaunchAccepted: Bool {
        state.lock.withLock { state.ownedTrashLaunchAccepted && !state.failed }
    }
    static func recordOwnedTrashCount(phase: String, verified: Bool) {
        state.lock.withLock {
            if phase == "launch" || !verified {
                state.ownedTrashLaunchAccepted = verified && !state.failed
            }
        }
    }
    static func stopOwnedTrash() {
        state.lock.withLock { state.failed = true; state.ownedTrashLaunchAccepted = false }
    }

    enum Scope: String, Sendable { case none, whole, data }
    private enum CountFailure: String, Error {
        case identity, access, entryType, enumeration, changed, entryLimit, byteLimit, deadline
    }
    private struct ScanFailure: Error {
        let reason: CountFailure
        let stage: String
        let code: Int32
    }
    struct Scan: Sendable {
        let complete: Bool
        let entries: Int
        let chargedBytes: UInt64
        let error: String
        let stage: String
        let code: Int32
        let device: dev_t
        let inode: ino_t
    }
    struct Result: Sendable {
        let scope: Scope
        let scan: Scan
        let dataIdentitySHA256: String
        let parentFailureStage: String
        let parentErrno: Int32
        var complete: Bool { scope != .none && scan.complete }
    }

    static func measureAndAccept(reservingBytes: UInt64) -> (Result, Bool) {
        state.lock.withLock {
            let result = measure()
            let entryCap = result.scope == .data ? dataMaximumEntries : maximumEntries
            let byteCap = result.scope == .data ? dataMaximumBytes : maximumBytes
            if !result.complete || reservingBytes > byteCap || result.scan.entries > entryCap ||
                result.scan.chargedBytes > byteCap - reservingBytes { state.failed = true }
            return (result, !state.failed)
        }
    }

    static func report(_ result: Result, phase: String, verified: Bool, route: Route = .v7) {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String ?? ""
        let digest = SHA256.hash(data: Data(identifier.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let safePhase = ["launch", "before", "after"].contains(phase) ? phase : "invalid"
        let entryCap = result.scope == .data ? dataMaximumEntries : maximumEntries
        let byteCap = result.scope == .data ? dataMaximumBytes : maximumBytes
        let reserve: UInt64 = safePhase == "before" ? 8 * 1_024 * 1_024 : 0
        let label: String
        switch route {
        case .v7: label = "TRAVERSE_V7_CONTAINER"
        case .ownedTrash: label = "TRAVERSE_OWNED_TRASH_CONTAINER"
        case .metadata: label = "TRAVERSE_METADATA_CONTAINER"
        case .remoteCut: label = "TRAVERSE_REMOTE_CUT_CONTAINER"
        case .localFiles: label = "TRAVERSE_LOCAL_FILES_CONTAINER"
        case .localDirectories: label = "TRAVERSE_LOCAL_DIRECTORIES_CONTAINER"
        case .nativeTARCreate: label = "TRAVERSE_NATIVE_TAR_CREATE_CONTAINER"
        case .receivedFile: label = "TRAVERSE_RECEIVED_FILE_CONTAINER"
        case .smbReceivedFile: label = "TRAVERSE_SMB_RECEIVED_FILE_CONTAINER"
        case .smbEditor: label = "TRAVERSE_SMB_EDITOR_CONTAINER"
        case .smbEditorV3: label = "TRAVERSE_SMB_EDITOR_V3_CONTAINER"
        case .zipOneFileExtraction: label = "TRAVERSE_ZIP_ONE_FILE_CONTAINER"
        case .zipOneFileAccess: label = "TRAVERSE_ZIP_ONE_FILE_ACCESS_CONTAINER"
        case .driveHealth: label = "TRAVERSE_DRIVE_HEALTH_CONTAINER"
        case .archivePublicAccess, .archivePublicContinuation, .archivePublicRepairedContinuation: label = "TRAVERSE_ARCHIVE_PUBLIC_ACCESS_CONTAINER"
        case .sftpSelectionDownload: label = "TRAVERSE_SFTP_SELECTION_DOWNLOAD_CONTAINER"
        case .smbSelectionDownload: label = "TRAVERSE_SMB_SELECTION_DOWNLOAD_CONTAINER"
        case .certificateConnection: label = "TRAVERSE_CERTIFICATE_CONNECTION_CONTAINER"
        case .archivePromise: label = "TRAVERSE_ARCHIVE_PROMISE_CONTAINER"
        case .archiveInternal: label = "TRAVERSE_ARCHIVE_INTERNAL_CONTAINER"
        }
        let line = "\(label) phase=\(safePhase) case=\(digest) scope=\(result.scope.rawValue) coverage=\(result.complete) appCountAccepted=\(verified) fullContainerVerified=\(verified && result.scope == .whole) pairedOuterRequired=\(result.scope == .data) entries=\(result.scan.entries) charged=\(result.scan.chargedBytes) entryCap=\(entryCap) byteCap=\(byteCap) entriesWithinLimit=\(result.scan.entries <= entryCap) bytesWithinLimit=\(result.scan.chargedBytes <= byteCap) beforeHeadroom=\(result.scan.chargedBytes <= byteCap - reserve) error=\(result.scan.error) failureStage=\(result.scan.stage) errno=\(result.scan.code) parentFailureStage=\(result.parentFailureStage) parentErrno=\(result.parentErrno) dataIdentitySHA256=\(result.dataIdentitySHA256)\n"
        fputs(line, stderr)
    }

    private static func identityDigest(_ identifier: String, _ facts: stat) -> String {
        let text = "\(identifier):\(facts.st_dev):\(facts.st_ino)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func boundDataRoot() -> URL? {
        guard let identifier = Bundle.main.bundleIdentifier,
              let expected = GeneratedSandboxReview.countedDataIdentityDigest else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let container = home.deletingLastPathComponent()
        guard home.lastPathComponent == "Data", container.lastPathComponent == identifier,
              container.deletingLastPathComponent().lastPathComponent == "Containers",
              container.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library" else { return nil }
        var facts = stat(), pinned = stat()
        guard lstat(home.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_uid == geteuid(), identityDigest(identifier, facts) == expected else { return nil }
        let fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &pinned) == 0, pinned.st_dev == facts.st_dev,
              pinned.st_ino == facts.st_ino, pinned.st_uid == facts.st_uid else { return nil }
        return home
    }

    private static func failed(_ reason: CountFailure, _ stage: String, _ code: Int32 = 0,
                               dataIdentitySHA256: String = "none",
                               parentFailureStage: String = "none", parentErrno: Int32 = 0) -> Result {
        Result(scope: .none,
               scan: Scan(complete: false, entries: 0, chargedBytes: 0,
                          error: reason.rawValue, stage: stage, code: code, device: 0, inode: 0),
               dataIdentitySHA256: dataIdentitySHA256,
               parentFailureStage: parentFailureStage, parentErrno: parentErrno)
    }

    private static func measure() -> Result {
        // One deadline covers the outer attempt, Data, and any eligible full
        // Data rescan. A retry never buys another three seconds or reuses a
        // partial entry/byte total.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let identifier = Bundle.main.bundleIdentifier,
              let expectedDataIdentity = GeneratedSandboxReview.countedDataIdentityDigest else {
            return failed(.identity, "commandIdentity")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let container = home.deletingLastPathComponent()
        guard home.lastPathComponent == "Data", container.lastPathComponent == identifier,
              container.deletingLastPathComponent().lastPathComponent == "Containers",
              container.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library" else {
            return failed(.identity, "homeIdentity")
        }
        var dataBefore = stat()
        guard lstat(home.path, &dataBefore) == 0 else {
            return failed(.access, "dataLstat", errno)
        }
        guard dataBefore.st_mode & S_IFMT == S_IFDIR,
              dataBefore.st_uid == geteuid() else { return failed(.identity, "dataIdentity") }
        let dataIdentity = identityDigest(identifier, dataBefore)
        guard dataIdentity == expectedDataIdentity else {
            return failed(.identity, "dataBinding", dataIdentitySHA256: dataIdentity)
        }
        let pinnedData = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard pinnedData >= 0 else {
            return failed(.access, "dataPinOpen", errno, dataIdentitySHA256: dataIdentity)
        }
        defer { close(pinnedData) }
        func sameDataInode(_ candidate: stat) -> Bool {
            candidate.st_dev == dataBefore.st_dev && candidate.st_ino == dataBefore.st_ino &&
            candidate.st_birthtimespec.tv_sec == dataBefore.st_birthtimespec.tv_sec &&
            candidate.st_birthtimespec.tv_nsec == dataBefore.st_birthtimespec.tv_nsec &&
            candidate.st_mode == dataBefore.st_mode && candidate.st_uid == geteuid() &&
            candidate.st_gid == dataBefore.st_gid && candidate.st_flags == dataBefore.st_flags
        }
        func dataBindingFailure(parentStage: String = "none", parentCode: Int32 = 0) -> Result? {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return failed(.deadline, "dataDeadline", dataIdentitySHA256: dataIdentity,
                              parentFailureStage: parentStage, parentErrno: parentCode)
            }
            var named = stat(), pinned = stat()
            guard lstat(home.path, &named) == 0 else {
                return failed(.access, "dataRecheck", errno, dataIdentitySHA256: dataIdentity,
                              parentFailureStage: parentStage, parentErrno: parentCode)
            }
            guard fstat(pinnedData, &pinned) == 0 else {
                return failed(.access, "dataPinRecheck", errno, dataIdentitySHA256: dataIdentity,
                              parentFailureStage: parentStage, parentErrno: parentCode)
            }
            guard sameDataInode(named), sameDataInode(pinned) else {
                return failed(.changed, "dataBindingChanged", dataIdentitySHA256: dataIdentity,
                              parentFailureStage: parentStage, parentErrno: parentCode)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return failed(.deadline, "dataDeadline", dataIdentitySHA256: dataIdentity,
                              parentFailureStage: parentStage, parentErrno: parentCode)
            }
            return nil
        }
        if let failure = dataBindingFailure() { return failure }

        let whole = scan(container, prefix: "parent", maximumEntries: maximumEntries,
                         maximumBytes: maximumBytes, deadline: deadline)
        if whole.complete {
            if let failure = dataBindingFailure() { return failure }
            return Result(scope: .whole, scan: whole, dataIdentitySHA256: dataIdentity,
                          parentFailureStage: "none", parentErrno: 0)
        }

        // Only an actual access denial at the outer root admits disjoint Data
        // counting. All other partial scans remain failed for this launch.
        guard whole.error == CountFailure.access.rawValue,
              (whole.stage == "parentLstat" || whole.stage == "parentOpen"),
              (whole.code == EPERM || whole.code == EACCES) else {
            return Result(scope: .none, scan: whole, dataIdentitySHA256: dataIdentity,
                          parentFailureStage: whole.stage, parentErrno: whole.code)
        }
        var data = scan(home, prefix: "data", maximumEntries: dataMaximumEntries,
                        maximumBytes: dataMaximumBytes, deadline: deadline)
        let timestampRace = data.error == CountFailure.changed.rawValue && [
            "dataDirectoryChanged", "dataChildTimestampChanged", "dataRootChanged"
        ].contains(data.stage)
        if timestampRace {
            if let failure = dataBindingFailure(parentStage: whole.stage, parentCode: whole.code) { return failure }
            data = scan(home, prefix: "data", maximumEntries: dataMaximumEntries,
                        maximumBytes: dataMaximumBytes, deadline: deadline)
        }
        guard data.complete else {
            return Result(scope: .none, scan: data, dataIdentitySHA256: dataIdentity,
                          parentFailureStage: whole.stage, parentErrno: whole.code)
        }
        guard data.device == dataBefore.st_dev, data.inode == dataBefore.st_ino else {
            return failed(.changed, "dataBindingChanged", dataIdentitySHA256: dataIdentity,
                          parentFailureStage: whole.stage, parentErrno: whole.code)
        }
        if let failure = dataBindingFailure(parentStage: whole.stage, parentCode: whole.code) { return failure }
        return Result(scope: .data, scan: data, dataIdentitySHA256: dataIdentity,
                      parentFailureStage: whole.stage, parentErrno: whole.code)
    }

    private static func scan(_ url: URL, prefix: String, maximumEntries: Int,
                             maximumBytes: UInt64, deadline: TimeInterval) -> Scan {
        var entries = 0
        var charged: UInt64 = 0
        var pathFacts = stat()
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ScanFailure(reason: .deadline, stage: prefix + "Deadline", code: 0)
            }
            guard lstat(url.path, &pathFacts) == 0 else {
                throw ScanFailure(reason: .access, stage: prefix + "Lstat", code: errno)
            }
            guard pathFacts.st_mode & S_IFMT == S_IFDIR, pathFacts.st_uid == geteuid() else {
                throw ScanFailure(reason: .access, stage: prefix + "Identity", code: 0)
            }
            let root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard root >= 0 else {
                throw ScanFailure(reason: .access, stage: prefix + "Open", code: errno)
            }
            defer { close(root) }
            var rootFacts = stat()
            guard fstat(root, &rootFacts) == 0 else {
                throw ScanFailure(reason: .access, stage: prefix + "RootFD", code: errno)
            }
            func sameObject(_ a: stat, _ b: stat) -> Bool {
                a.st_dev == b.st_dev && a.st_ino == b.st_ino &&
                a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec &&
                a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec &&
                a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid &&
                a.st_flags == b.st_flags
            }
            func sameTimestamps(_ a: stat, _ b: stat) -> Bool {
                a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
                a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
            }
            guard sameObject(pathFacts, rootFacts) else {
                throw ScanFailure(reason: .changed, stage: prefix + "RootIdentity", code: 0)
            }
            func consume(_ facts: stat) throws {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw ScanFailure(reason: .deadline, stage: prefix + "Deadline", code: 0)
                }
                guard facts.st_uid == geteuid() else {
                    throw ScanFailure(reason: .access, stage: prefix + "Owner", code: 0)
                }
                let kind = facts.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else {
                    throw ScanFailure(reason: .entryType, stage: prefix + "EntryType", code: 0)
                }
                entries += 1
                guard entries <= maximumEntries else {
                    throw ScanFailure(reason: .entryLimit, stage: prefix + "EntryLimit", code: 0)
                }
                guard facts.st_size >= 0, facts.st_blocks >= 0,
                      UInt64(facts.st_blocks) <= UInt64.max / 512 else {
                    throw ScanFailure(reason: .enumeration, stage: prefix + "EntrySize", code: 0)
                }
                let size = max(UInt64(facts.st_size), UInt64(facts.st_blocks) * 512)
                guard size <= maximumBytes - min(charged, maximumBytes) else {
                    throw ScanFailure(reason: .byteLimit, stage: prefix + "ByteLimit", code: 0)
                }
                charged += size
            }
            func visit(_ directory: Int32, depth: Int) throws {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw ScanFailure(reason: .deadline, stage: prefix + "Deadline", code: 0)
                }
                guard depth <= 64 else {
                    throw ScanFailure(reason: .entryLimit, stage: prefix + "Depth", code: 0)
                }
                var before = stat()
                guard fstat(directory, &before) == 0 else {
                    throw ScanFailure(reason: .access, stage: prefix + "DirectoryFD", code: errno)
                }
                try consume(before)
                let enumerationFD = dup(directory)
                guard enumerationFD >= 0 else {
                    throw ScanFailure(reason: .access, stage: prefix + "EnumerationFD", code: errno)
                }
                guard let stream = fdopendir(enumerationFD) else {
                    let code = errno
                    close(enumerationFD)
                    throw ScanFailure(reason: .enumeration, stage: prefix + "OpenDirectory", code: code)
                }
                defer { closedir(stream) }
                while true {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw ScanFailure(reason: .deadline, stage: prefix + "Deadline", code: 0)
                    }
                    errno = 0
                    guard let entry = readdir(stream) else {
                        if errno != 0 {
                            throw ScanFailure(reason: .enumeration, stage: prefix + "ReadDirectory", code: errno)
                        }
                        break
                    }
                    guard let name = withUnsafePointer(to: entry.pointee.d_name, {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
                    }) else {
                        throw ScanFailure(reason: .enumeration, stage: prefix + "EntryName", code: 0)
                    }
                    if name == "." || name == ".." { continue }
                    var facts = stat()
                    guard fstatat(directory, name, &facts, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw ScanFailure(reason: .changed, stage: prefix + "EntryStat", code: errno)
                    }
                    if facts.st_mode & S_IFMT == S_IFDIR {
                        let child = openat(directory, name,
                                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                        guard child >= 0 else {
                            throw ScanFailure(reason: .changed, stage: prefix + "ChildOpen", code: errno)
                        }
                        do {
                            defer { close(child) }
                            var opened = stat()
                            guard fstat(child, &opened) == 0 else {
                                throw ScanFailure(reason: .changed, stage: prefix + "ChildFD", code: errno)
                            }
                            guard sameObject(facts, opened) else {
                                throw ScanFailure(reason: .changed, stage: prefix + "ChildIdentityChanged", code: 0)
                            }
                            guard sameTimestamps(facts, opened) else {
                                throw ScanFailure(reason: .changed, stage: prefix + "ChildTimestampChanged", code: 0)
                            }
                            try visit(child, depth: depth + 1)
                        }
                    } else { try consume(facts) }
                }
                var after = stat()
                guard fstat(directory, &after) == 0 else {
                    throw ScanFailure(reason: .changed, stage: prefix + "DirectoryRecheck", code: errno)
                }
                guard sameObject(before, after) else {
                    throw ScanFailure(reason: .changed, stage: prefix + "DirectoryIdentityChanged", code: 0)
                }
                guard sameTimestamps(before, after) else {
                    throw ScanFailure(reason: .changed, stage: prefix + "DirectoryChanged", code: 0)
                }
            }
            try visit(root, depth: 0)
            var finalRoot = stat()
            guard fstat(root, &finalRoot) == 0 else {
                throw ScanFailure(reason: .changed, stage: prefix + "RootRecheck", code: errno)
            }
            guard sameObject(pathFacts, finalRoot) else {
                throw ScanFailure(reason: .changed, stage: prefix + "RootIdentityChanged", code: 0)
            }
            guard sameTimestamps(pathFacts, finalRoot) else {
                throw ScanFailure(reason: .changed, stage: prefix + "RootChanged", code: 0)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ScanFailure(reason: .deadline, stage: prefix + "Deadline", code: 0)
            }
            return Scan(complete: true, entries: entries, chargedBytes: charged,
                        error: "none", stage: "none", code: 0,
                        device: pathFacts.st_dev, inode: pathFacts.st_ino)
        } catch let failure as ScanFailure {
            return Scan(complete: false, entries: entries, chargedBytes: charged,
                        error: failure.reason.rawValue, stage: failure.stage, code: failure.code,
                        device: pathFacts.st_dev, inode: pathFacts.st_ino)
        } catch {
            return Scan(complete: false, entries: entries, chargedBytes: charged,
                        error: "unexpected", stage: prefix + "Unexpected", code: 0,
                        device: pathFacts.st_dev, inode: pathFacts.st_ino)
        }
    }
}


/// One bounded stop checkpoint in the generated signed image. It is invoked on
/// the FileOperations worker after the second adopted payload reaches the
/// private recovery area and before the public rename can begin.
final class GeneratedV7Checkpoint: @unchecked Sendable {
    static let shared = GeneratedV7Checkpoint()
    private let lock = NSLock()
    private var moves = 0
    private var bodyRequests = 0
    private init() {}

    func recordBodyRequest() throws {
        let count = try lock.withLock { () throws -> Int in
            guard bodyRequests < 3 else { throw FileOperationFailure.unavailable }
            bodyRequests += 1
            return bodyRequests
        }
        fputs("TRAVERSE_V7_BODY_REQUEST ordinal=\(count)\n", stderr)
    }

    func afterMove(cancelled: @escaping @Sendable () -> Bool) throws {
        let ordinal = lock.withLock { moves += 1; return moves }
        guard ordinal == 2 else { return }
        fputs("TRAVERSE_V7_PRIVATE_RENAME_STOP_READY\n", stderr)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancelled() {
                fputs("TRAVERSE_V7_PRIVATE_RENAME_STOP_OBSERVED\n", stderr)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        fputs("TRAVERSE_V7_PRIVATE_RENAME_STOP_TIMED_OUT\n", stderr)
        throw FileOperationFailure.unavailable
    }
}
#endif

#if TRAVERSE_SFTP_EDITOR_QA
/// A separate, exact-command signed QA flow. The panel grants only the fresh
/// generated external parent; this flow never constructs a network session.
@MainActor
enum GeneratedPrivateMarkProbe {
    private static let destinationName = "Generated.bin"

    static func start() {
        guard GeneratedSandboxReview.privateMarkProbeAdmitted,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String else { return }
        let exactRoot = URL(fileURLWithPath:
            "/private/tmp/traverse-v7-private-mark-" + identifier.lowercased(), isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the generated private mark probe folder"
        panel.message = "Select only this case’s generated folder under /private/tmp. The probe keeps its file private for review."
        panel.prompt = "Use Generated Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = exactRoot
        panel.begin { response in
            guard response == .OK, let selected = panel.url else {
                fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=folderSelection accepted=false\n", stderr)
                return
            }
            Task { await run(selected) }
        }
    }

    private static func run(_ selected: URL) async {
        guard let layout = AppStorageLocations.layout,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              GeneratedSandboxReview.privateMarkProbeAdmitted,
              await GeneratedSandboxReview.accountV7Container(phase: "before") else {
            fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=admission accepted=false\n", stderr)
            return
        }
        let scoped = selected.startAccessingSecurityScopedResource()
        defer {
            if scoped { selected.stopAccessingSecurityScopedResource() }
            withExtendedLifetime(selected) {}
        }
        do {
            let canonical = try await Task.detached(priority: .utility) {
                try verifyGeneratedParent(selected, caseID: identifier)
            }.value
            try await AppStoragePreparation.owner(for: layout.stateDirectory).prepare()
            try await AppStoragePreparation.preparePortableCache()
            let journal = layout.stateDirectory.appendingPathComponent("private-mark-probe-recovery", isDirectory: true)
            let engine = RecoverableFileOperations(journalDirectory: journal,
                qualifyingPrivateMarkProbe: report,
                protecting: [layout.stateDirectory, layout.cacheDirectory],
                activity: ApplicationFileActivity.beginOperation)
            let storage = try SFTPDownloadStorage(directory: layout.ordinaryRemoteDownloadDirectory)
            let observed = try await storage.checkAdoptionDestination(using: engine,
                parent: canonical, name: destinationName)
            guard try await storage.inspect().isEmpty else { throw FileOperationFailure.unavailable }
            try await Task.detached(priority: .utility) {
                try claimSingleAttempt(in: layout.stateDirectory, journal: journal, caseID: identifier)
            }.value
            let received = try await storage.makeGeneratedPrivateMarkProbeSource()
            do {
                let nativeMark = try await received.hasExpectedV7NativeMark()
                fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=source native0086=\(nativeMark)\n", stderr)
                guard nativeMark else { throw FileOperationFailure.copyMetadataMismatch }
                let plan = try await received.prepareAdoption(using: engine, parent: canonical,
                    name: destinationName, observing: observed)
                let result = await engine.performReceivedFile(plan)
                _ = await received.finishAdoption(result)
                fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=privateStop record=\(result.recordID?.uuidString ?? "none") disposition=\(result.result.disposition) publicRename=false\n", stderr)
            } catch {
                await received.retainForReview()
                throw error
            }
        } catch {
            // Error descriptions may contain private paths; expose only a
            // fixed stage and a closed failure type.
            fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=setup accepted=false failure=\(error is CancellationError ? "cancelled" : "refused")\n", stderr)
        }
        _ = await GeneratedSandboxReview.accountV7Container(phase: "after")
    }

    nonisolated private static func report(_ result: DownloadPrivateMarkProbeResult) {
        let state: String
        let code: Int32
        switch result {
        case .unchanged: state = "unchanged"; code = 0
        case .unexpectedMark: state = "unexpectedMark"; code = 0
        case .preconditionFailed: state = "preconditionFailed"; code = 0
        case .replaceDenied(let value): state = "replaceDenied"; code = value
        case .restored: state = "restored"; code = 0
        case .postcheckFailed: state = "postcheckFailed"; code = 0
        }
        fputs("TRAVERSE_PRIVATE_MARK_PROBE stage=privateMark result=\(state) errno=\(code) publicRename=false\n", stderr)
    }

    nonisolated private static func verifyGeneratedParent(_ selected: URL, caseID: String) throws -> URL {
        let expected = "/private/tmp/traverse-v7-private-mark-" + caseID.lowercased()
        let alias = "/tmp/traverse-v7-private-mark-" + caseID.lowercased()
        guard selected.isFileURL, [expected, alias].contains(selected.standardizedFileURL.path),
              selected.resolvingSymlinksInPath().path == expected else {
            throw FileOperationFailure.invalidRequest
        }
        var linked = stat(), pinned = stat()
        guard lstat(expected, &linked) == 0, linked.st_mode & S_IFMT == S_IFDIR,
              linked.st_mode & 0o7777 == 0o700, linked.st_uid == geteuid() else {
            throw FileOperationFailure.destinationChanged
        }
        let directory = open(expected, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileOperationFailure.accessDenied }
        defer { close(directory) }
        guard fstat(directory, &pinned) == 0, pinned.st_dev == linked.st_dev,
              pinned.st_ino == linked.st_ino,
              pinned.st_birthtimespec.tv_sec == linked.st_birthtimespec.tv_sec,
              pinned.st_birthtimespec.tv_nsec == linked.st_birthtimespec.tv_nsec else {
            throw FileOperationFailure.destinationChanged
        }
        let marker = openat(directory, ".traverse-private-mark-owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard marker >= 0 else { throw FileOperationFailure.destinationChanged }
        defer { close(marker) }
        let exact = Data("MEX-PRIVATE-MARK-PROBE1\n\(caseID)\n".utf8)
        var markerFacts = stat()
        guard fstat(marker, &markerFacts) == 0, markerFacts.st_mode & S_IFMT == S_IFREG,
              markerFacts.st_mode & 0o7777 == 0o600, markerFacts.st_uid == geteuid(),
              markerFacts.st_nlink == 1, markerFacts.st_size == exact.count else {
            throw FileOperationFailure.destinationChanged
        }
        var bytes = Data(count: exact.count)
        let readCount = bytes.withUnsafeMutableBytes { read(marker, $0.baseAddress, exact.count) }
        guard readCount == exact.count, bytes == exact else { throw FileOperationFailure.destinationChanged }
        return URL(fileURLWithPath: expected, isDirectory: true)
    }

    /// A durable exclusive marker refuses a second fixture or an old journal
    /// in this case, including a second process launched with the same command.
    nonisolated private static func claimSingleAttempt(in state: URL, journal: URL, caseID: String) throws {
        var prior = stat()
        guard lstat(journal.path, &prior) != 0, errno == ENOENT else {
            throw FileOperationFailure.unavailable
        }
        let directory = open(state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileOperationFailure.unavailable }
        defer { close(directory) }
        let marker = openat(directory, "private-mark-probe-attempted",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard marker >= 0 else { throw FileOperationFailure.unavailable }
        defer { close(marker) }
        let bytes = Data("MEX-PRIVATE-MARK-ATTEMPT1\n\(caseID)\n".utf8)
        guard bytes.withUnsafeBytes({ write(marker, $0.baseAddress, bytes.count) }) == bytes.count,
              fsync(marker) == 0, fsync(directory) == 0 else { throw FileOperationFailure.ioFailure }
    }
}
#endif
