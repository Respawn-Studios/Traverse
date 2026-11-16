import AppKit
import Darwin
import FileOperations
import Combine
import ExplorerCore
@_spi(Qualification) import LocalStorage

@main
enum MacExplorerApplication {
    @MainActor
    static func main() {
        // An exact generated Release image cannot enter an ordinary profile
        // after a malformed relaunch, changed Info, or missing fixture root.
        if GeneratedArchiveDriveReview.requested {
            guard let selection = GeneratedArchiveDriveReview.selection,
                  GeneratedArchiveDriveReview.consumePhasePermit(selection) else {
                fputs("TRAVERSE_ARCHIVE_DRIVE_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
                Darwin.exit(71)
            }
        }
        if GeneratedDriveImageReview.requested {
            guard let selection = GeneratedDriveImageReview.selection,
                  GeneratedDriveImageReview.consumePhasePermit(selection) else {
                fputs("TRAVERSE_DRIVE_IMAGE_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
                Darwin.exit(71)
            }
        }
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION && !MAC_EXPLORER_DISTRIBUTION
        // Children use the same isolated, signed qualification image. Their
        // exact private case and parent witness are checked by each child.
        let gateBChildArguments = CommandLine.arguments
        if gateBChildArguments.contains("--sftp-inplace-v1-pipe-child")
            || gateBChildArguments.contains("--gateb-owner-pin-child")
            || gateBChildArguments.contains("--gateb-removal-child") {
            guard Bundle.main.object(forInfoDictionaryKey: "TraverseVerificationOnly") as? Bool == true,
                  Bundle.main.object(forInfoDictionaryKey: "TraverseGateBQualificationOnly") as? Bool == true else {
                fputs("TRAVERSE_GATEB_CHILD_IMAGE_REFUSED\n", stderr)
                Darwin.exit(71)
            }
        }
        // Exact generated children return before NSApplication or any profile.
        // Any malformed child request still exits without ordinary launch.
        if CommandLine.arguments.contains("--sftp-inplace-v1-pipe-child") {
            GateBGeneratedInPlacePipeChild.runOrExit()
        }
        if CommandLine.arguments.contains("--gateb-owner-pin-child") {
            GateBGeneratedOwnerPinChild.runOrExit()
        }
        if CommandLine.arguments.contains("--gateb-removal-child") {
            GateBGeneratedRemovalChild.runOrExit()
        }
        #endif
        // A GateB qualification image cannot become an ordinary profile even
        // if relaunched without its reviewed command. Malformed GateB flags
        // refuse before NSApplication and before any App owner is constructed.
        let gateBArguments = CommandLine.arguments
        let gateBRequested = gateBArguments.dropFirst().contains {
            $0.hasPrefix("--check-security-remote-close") || $0.hasPrefix("--gateb-")
                || $0.hasPrefix("--sftp-inplace-v1-pipe-child")
        }
        if gateBRequested || Bundle.main.object(forInfoDictionaryKey: "TraverseGateBQualificationOnly") as? Bool == true {
            #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION && !MAC_EXPLORER_DISTRIBUTION
            guard gateBRequested, gateBArguments.count == 3,
                  gateBArguments[1] == "--verify-ui",
                  gateBArguments[2] == "--check-security-remote-close",
                  Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  Bundle.main.object(forInfoDictionaryKey: "TraverseVerificationOnly") as? Bool == true,
                  Bundle.main.object(forInfoDictionaryKey: "TraverseGateBQualificationOnly") as? Bool == true,
                  let root = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                  !root.isEmpty else {
                fputs("TRAVERSE_GATEB_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
                Darwin.exit(71)
            }
            #else
            fputs("TRAVERSE_GATEB_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
            Darwin.exit(71)
            #endif
        }
        #if DEBUG
        // Lexical GateA launch refusals occur before NSApplication/delegate
        // construction. Filesystem/case/image admission remains later and is
        // not described as complete pre-App startup isolation.
        let gateAArguments = ProcessInfo.processInfo.arguments
        if gateAArguments.contains("--check-security-connection-workspace") {
            let checks = gateAArguments.filter { $0.hasPrefix("--check-") }
            let phaseIndex = gateAArguments.firstIndex(of: "--gate-a-phase")
            let phase = phaseIndex.flatMap { $0 + 1 < gateAArguments.count ? gateAArguments[$0 + 1] : nil }
            guard gateAArguments.filter({ $0 == "--verify-ui" }).count == 1,
                  gateAArguments.filter({ $0 == "--check-security-connection-workspace" }).count == 1,
                  gateAArguments.filter({ $0 == "--gate-a-phase" }).count == 1,
                  checks == ["--check-security-connection-workspace"],
                  !gateAArguments.contains(where: { $0.hasPrefix("--show-") }),
                  let phase, ["prepare", "cold", "refusal"].contains(phase),
                  let root = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"], !root.isEmpty else {
                fputs("TRAVERSE_GATEA_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
                return
            }
        }
        // Isolated native-inspection copies cannot fall through into an ordinary
        // profile if the inspection tool relaunches them after a timed-out run.
        if Bundle.main.object(forInfoDictionaryKey: "TraverseVerificationOnly") as? Bool == true,
           !ProcessInfo.processInfo.arguments.contains("--verify-ui") {
            fputs("TRAVERSE_ISOLATED_REVIEW_REQUIRES_VERIFICATION\n", stderr)
            return
        }
        let nativeRoute = ProcessInfo.processInfo.arguments.contains("--check-trash-app-route-native")
        if (nativeRoute && !ProcessInfo.processInfo.arguments.contains("--verify-ui"))
            || (Bundle.main.bundleURL.lastPathComponent == "Traverse Qualification.app" && !nativeRoute) {
            fputs("TRAVERSE_NATIVE_TRASH_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
            return
        }
        #endif
        #if MAC_EXPLORER_DIRECT_ACCESS_QUALIFICATION
        // Until the full generated state/upgrade adapter is qualified, this
        // experimental configuration cannot create NSApplication or load an
        // ordinary profile, even if someone launches its bundle accidentally.
        fputs("TRAVERSE_LOCAL_USER_QUALIFICATION_ONLY\n", stderr)
        #else
        #if MAC_EXPLORER_DISTRIBUTION && TRAVERSE_LOCAL_USER_DIRECT
        guard DirectPublicEditionIdentity.matches(identifier: Bundle.main.bundleIdentifier,
                info: Bundle.main.infoDictionary ?? [:]), AppStorageLocations.layout != nil else {
            fputs("TRAVERSE_DIRECT_EDITION_IDENTITY_REFUSED\n", stderr)
            Darwin.exit(71)
        }
        #endif
        let application = TraverseApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
        #endif
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let folderDefaults: ApplicationFolderDefaults
    #if DEBUG
    private var folderTerminationEventForVerification: (@MainActor () -> Void)?
    #endif
    override init() { folderDefaults = .shared; super.init() }
    #if DEBUG
    init(folderDefaultsForVerification owner: ApplicationFolderDefaults, isolated: Bool = true,
         terminationEvent: @escaping @MainActor () -> Void) {
        folderDefaults = owner; super.init()
        isolatedConnectionFormVerification = isolated
        folderTerminationEventForVerification = terminationEvent
    }
    #endif
    private func requestTermination(_ sender: NSApplication) {
        #if DEBUG
        // Closed event observation only; it supplies no callback/outcome/grant
        // to the folder request. Actual owner drain occurs before this event.
        if let folderTerminationEventForVerification { folderTerminationEventForVerification(); return }
        #endif
        sender.terminate(nil)
    }
    private func folderDefaultTerminationReply(_ sender: NSApplication) -> NSApplication.TerminateReply? {
        guard folderDefaults.needsTerminationDrain else { return nil }
        guard !isFlushingForTermination else { return .terminateCancel }
        isFlushingForTermination = true
        Task { @MainActor in
            let ready = await folderDefaults.prepareForTermination()
            isFlushingForTermination = false
            if ready { requestTermination(sender) }
            else { resumeTerminationPreparations() }
        }
        return .terminateCancel
    }
    private var browserWindow: BrowserWindowController?
    private func resumeTerminationPreparations() {
        folderDefaults.resumeAfterCancelledTermination()
        ApplicationDriveDetails.shared.resumeHealthMonitoring()
    }
    private var isFlushingForTermination = false
    private var terminationReady = false
    private let incomingFolders = IncomingFolderOpening()
    private var incomingFolderService: IncomingFolderService?
    private var startupTask: Task<Void, Never>?
    #if DEBUG
    private var isolatedConnectionFormVerification = false
    private var refusedQualificationLaunch = false
    private var didFinishForIncomingVerification = false
    private(set) var incomingBeforeDidFinishForVerification = false
    var incomingForSystemVerification: IncomingFolderOpening { incomingFolders }
    func attachIncomingForSystemVerification(_ controller: BrowserWindowController) {
        browserWindow = controller; incomingFolders.attach(controller)
    }
    #endif

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        !GeneratedDriveImageReview.requested
    }

    #if TRAVERSE_SFTP_EDITOR_QA
    private func containerReviewStartupAccepted() async -> Bool {
        guard GeneratedSandboxReview.containerReviewRequested else { return true }
        let counted = await GeneratedSandboxReview.accountContainerReview(phase: "launch")
        if Task.isCancelled {
            startupTask = nil
            return false
        }
        guard counted else {
            // Do not let ordinary startup or a Connect begin after a partial
            // or denied count. Clear this task before termination can join it.
            startupTask = nil
            NSApplication.shared.terminate(nil)
            return false
        }
        return true
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if TRAVERSE_DRIVE_IMAGE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        guard let selection = GeneratedDriveImageReview.selection else {
            fputs("TRAVERSE_DRIVE_IMAGE_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        Task { @MainActor in await SignedDriveImageVerification.run(selection: selection) }
        #else
        #if TRAVERSE_ARCHIVE_DRIVE_QA
        guard let selection = GeneratedArchiveDriveReview.selection else {
            fputs("TRAVERSE_ARCHIVE_DRIVE_QUALIFICATION_LAUNCH_REFUSED\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        Task { @MainActor in
            switch selection.phase {
            case .archiveWarm, .archiveCold:
                await OperationAccessRecoverySignedVerification.runAuthoredArchives(selection: selection)
            case .driveReadOnly:
                await OperationAccessRecoverySignedVerification.runPassiveDriveInspection(selection: selection)
            }
        }
        #else
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.ownedTrashRequested {
            guard let phase = GeneratedSandboxReview.ownedTrashPhase else {
                fputs("TRAVERSE_OWNED_TRASH_QA admission=refused\n", stderr)
                NSApplication.shared.terminate(nil)
                return
            }
            if phase == .bootstrap {
                // A new sandbox Data inode cannot be host-bound until macOS
                // creates this exact case's first container on launch.
                fputs("TRAVERSE_OWNED_TRASH_QA phase=bootstrap admission=accepted mutation=false\n", stderr)
                NSApplication.shared.terminate(nil)
                return
            } else {
                Task {
                    let counted = await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "launch")
                    if !counted { NSApplication.shared.terminate(nil) }
                }
            }
        }
        if GeneratedSandboxReview.v7DownloadAdmitted || GeneratedSandboxReview.privateMarkProbeAdmitted {
            Task {
                let counted = await GeneratedSandboxReview.accountV7Container(phase: "launch")
                if counted, GeneratedSandboxReview.privateMarkProbeAdmitted {
                    GeneratedPrivateMarkProbe.start()
                }
            }
        }
        #endif
        #if DEBUG
        didFinishForIncomingVerification = true
        if !SandboxQualificationLaunch.permits(
            hasCaseMarker: Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") != nil,
            arguments: ProcessInfo.processInfo.arguments) {
            refusedQualificationLaunch = true
            print("MAC_EXPLORER_QUALIFICATION_LAUNCH_REFUSED")
            NSApplication.shared.terminate(nil)
            return
        }
        let verification = ProcessInfo.processInfo.arguments.contains("--verify-ui")
        #if TRAVERSE_GATEB_NATIVE_QUALIFICATION && !MAC_EXPLORER_DISTRIBUTION
        if ProcessInfo.processInfo.arguments.contains("--check-security-remote-close") {
            isolatedConnectionFormVerification = true
            Task { await GateBApplicationEntryVerification.run() }
            return
        }
        #endif
        // Route requested GateA even without --verify-ui; Scope then refuses
        // malformed inputs before any GateA owner/storage is constructed.
        if ProcessInfo.processInfo.arguments.contains("--check-security-connection-workspace") {
            isolatedConnectionFormVerification = true
            Task { await GateAApplicationVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-trash-app-route-generated") {
            isolatedConnectionFormVerification = true
            Task { await GeneratedTrashAppRouteVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-trash-provenance-offline") {
            isolatedConnectionFormVerification = true
            Task { await NativeTrashProvenanceOfflineVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-trash-app-route-native") {
            isolatedConnectionFormVerification = true
            Task { await NativeTrashBrowserRouteVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-analysis-session-reuse") {
            isolatedConnectionFormVerification = true
            AnalysisReuseVerification.launch()
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-analysis-persistence") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await AnalysisReuseVerification.runPersistence() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-editor-preferences") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await EditorPreferencesVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-drive-benchmark-native") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await DriveDetailsVerification.runBenchmark() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sidebar-layout") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SidebarLayoutVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-explorer-pointer") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ExplorerPointerVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-help-motion") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await HelpMotionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-folder-default-composition") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await FolderDefaultCompositionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-editor-line-commands") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await EditorLineCommandVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-local-editor") {
            Task { @MainActor in await LocalTextEditorVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-editor-retirement-native") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await EditorRetirementVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-summary-hover")
            && ProcessInfo.processInfo.arguments.contains("--hover-readability") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await FolderSummaryHoverVerification.runFocused() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-drive-storage-status") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await DriveStorageStatusVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-unified-selection") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await UnifiedSelectionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-properties-capacity") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await PropertiesCapacityVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-purpose-journey") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await StoragePurposeJourneyVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-drop-worker") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPDropWorkerVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-drop-upload") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPDropUploadVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-worker-directory-recovery") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPWorkerDirectoryRecoveryVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-selection-gestures") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SelectionGestureVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-connection-fields") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ConnectionFieldsVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-selection-preview") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SelectionPreviewVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-directory-recovery") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPDirectoryRecoveryVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-clipboard-diagnostics") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ClipboardAdmissionDiagnosticsVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-remote-properties") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await RemoteItemPropertiesVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-connection-navigation") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ConnectionNavigationVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-settings-sidebar") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SettingsNavigationVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-drag-diagnostics") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await DragReadinessDiagnosticsVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-setup-access-diagnostics") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SetupAccessDiagnosticsVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-smb-open-recovery") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SMBOpenRecoveryVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-smb-folder-download") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SMBFolderDownloadVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-smb-selected-download") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SMBSelectedDownloadVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-chart-overview") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ChartOverviewVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-workspace-input") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await WorkspaceInputAcceptance.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-setup-lifetime") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SetupLifetimeVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-network-workspace-route") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await WorkspaceRouteConnectionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-network-workspace-smb") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await WorkspaceSMBConnectionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-network-workspace-connection") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await WorkspaceNetworkConnectionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-network-workspaces") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await WorkspaceNetworkVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-search-provider-admission") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SearchProviderAdmissionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-upload-preview") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPFolderUploadPreviewVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-auth-transfer") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPTransferAuthenticationVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-routed-upload") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPRoutedUploadVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-open-routing") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ArchiveOpenRoutingVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-inline-archives") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await InlineArchiveVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-inline-archive-motion") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await InlineArchiveMotionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-tar-preview-native") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await TARPreviewNativeVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-selection-group-native") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SelectionGroupNativeVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-airdrop-native") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await B13AirDropVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-tar-archive") {
            isolatedConnectionFormVerification=true
            Task{@MainActor in await TARArchiveVerification.run()};return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await ArchiveCreationVerification.runRenameCopy() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-download") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPFolderDownloadVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-review") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPFolderPreviewVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-transfer-diagnostics") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await TransferDiagnosticsVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-data-classification") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await DataClassificationVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-jump-connection") {
            Task { @MainActor in await SFTPJumpConnectionVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-saved-route") {
            isolatedConnectionFormVerification = true
            Task { @MainActor in await SFTPSavedRouteVerification.run() }; return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-interactive-connection") {
            isolatedConnectionFormVerification = true
            Task { await SFTPInteractiveConnectionVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-key-connection") {
            isolatedConnectionFormVerification = true
            Task { await SFTPKeyConnectionVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-development-motion") {
            isolatedConnectionFormVerification = true
            Task { await DevelopmentMotionVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-help-diagnostics") {
            isolatedConnectionFormVerification = true
            Task { await HelpDiagnosticsVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-recovery-access") {
            isolatedConnectionFormVerification = true
            Task { await RecoveryAccessQualification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-operation-access") {
            isolatedConnectionFormVerification = true
            Task { await OperationAccessRecoveryVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-file-workflow-system") {
            isolatedConnectionFormVerification = true
            Task { await FileWorkflowSystemVerification.run(delegate: self) }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-incoming-system") {
            isolatedConnectionFormVerification = true
            Task { await IncomingSystemVerification.run(delegate: self) }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-pane-destination") {
            isolatedConnectionFormVerification = true
            Task { await ArchivePaneDestinationVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-result-completion") {
            isolatedConnectionFormVerification = true
            Task { await ResultQueryCompletionVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-largest-files-ui") {
            isolatedConnectionFormVerification = true
            Task { await LargestFilesVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-search-progress") {
            isolatedConnectionFormVerification = true
            Task { await SearchProgressVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-member-drag") {
            isolatedConnectionFormVerification = true
            Task { await ArchiveMemberDragVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-promise-export") {
            isolatedConnectionFormVerification = true
            Task { await ArchivePromiseExportVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-promise-gesture") {
            isolatedConnectionFormVerification = true
            Task { await ArchivePromiseGestureVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-sorting") {
            isolatedConnectionFormVerification = true
            Task { await ArchiveSortingVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-browser-tasks") {
            isolatedConnectionFormVerification = true
            Task { await BrowserTaskVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-header-hover") {
            isolatedConnectionFormVerification = true
            Task { await HeaderHoverVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-properties-storage") {
            isolatedConnectionFormVerification = true
            Task { await PropertiesStorageVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-folder-opener") {
            isolatedConnectionFormVerification = true
            Task { await FolderOpeningVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-byte-preview") {
            isolatedConnectionFormVerification = true
            Task { await ArchiveBytePreviewVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-filename-copy") {
            isolatedConnectionFormVerification = true
            Task { await FilenameCopyVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-inline-preview-owner") {
            isolatedConnectionFormVerification = true
            Task { await InlinePreviewLifetimeVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-private-labels") {
            isolatedConnectionFormVerification = true
            Task { await PrivateLabelAdditionVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-archive-search") {
            isolatedConnectionFormVerification = true
            Task { await ArchiveNameSearchVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-search-scale") {
            isolatedConnectionFormVerification = true
            Task { await SearchScaleVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-queue-priority") {
            isolatedConnectionFormVerification = true
            Task { await QueuePriorityVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-profile-workspaces-ui") {
            isolatedConnectionFormVerification = true
            Task { await ProfileWorkspaceUIVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-profile-workspaces-storage") {
            isolatedConnectionFormVerification = true
            Task { await ProfileWorkspaceStorageVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-command-finder") {
            isolatedConnectionFormVerification = true
            Task { await CommandFinderVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-browser-accessibility") {
            isolatedConnectionFormVerification = true
            Task { await BrowserAccessibilityVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-onboarding-access") {
            isolatedConnectionFormVerification = true
            Task { await OnboardingAccessVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-access-patch") {
            isolatedConnectionFormVerification = true
            Task { await AccessPatchVerification.run() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-upload-ui") {
            isolatedConnectionFormVerification = true
            Task { await SFTPUploadVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-download-ui") {
            isolatedConnectionFormVerification = true
            Task { await SFTPDownloadVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-lifetime-standalone") {
            isolatedConnectionFormVerification = true
            Task { await SFTPLifetimeVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-connect-standalone") {
            isolatedConnectionFormVerification = true
            Task { await SFTPConnectVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-smb-connect-standalone") {
            // Form-only diagnostics instantiate no browser/history/credential
            // owner and use in-memory settings. No ordinary routing changes.
            isolatedConnectionFormVerification = true
            Task { await SMBConnectVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-trust-standalone") {
            isolatedConnectionFormVerification = true
            Task { await SFTPTrustVerification.runStandalone() }
            return
        }
        if verification && ProcessInfo.processInfo.arguments.contains("--check-sftp-live-standalone") {
            isolatedConnectionFormVerification = true
            Task { await SFTPLiveTrustVerification.runStandalone() }
            return
        }
        #else
        let verification = false
        #endif
        SystemShortcutSnapshot.shared.refresh()
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.containerReviewRequested {
            startupTask = Task { [weak self] in
                guard let self, await self.containerReviewStartupAccepted(), !Task.isCancelled else { return }
                defer { self.startupTask = nil }
                // Both QA visits avoid reading preferences or restoring a saved
                // workspace. Their transient settings do not rewrite either.
                let settings = BrowserSettings(persist: false, skipDiskRead: true)
                settings.startupMode = .computer
                self.finishLaunching(settings: settings, verification: verification)
            }
            return
        }
        #endif
        #if DEBUG
        let portableStartup = AppStorageLocations.isPortable && (!verification
            || ProcessInfo.processInfo.arguments.contains("--check-portable-storage")
            || ProcessInfo.processInfo.arguments.contains("--check-sandbox-foundation"))
        #else
        let portableStartup = AppStorageLocations.isPortable
        #endif
        if portableStartup {
            startupTask = Task { [weak self] in
                await BrowsingHome.prepare()
                guard !Task.isCancelled else { return }
                let settings = await BrowserSettings.loadPortable()
                guard let self else { return }
                defer { self.startupTask = nil }
                guard !Task.isCancelled else { return }
                self.finishLaunching(settings: settings, verification: verification)
            }
            return
        }
        startupTask = Task { [weak self] in
            await BrowsingHome.prepare()
            guard let self, !Task.isCancelled else { return }
            defer { self.startupTask = nil }
            self.finishLaunching(settings: BrowserSettings(persist: !verification), verification: verification)
        }
        #endif
        #endif
    }

    private func finishLaunching(settings: BrowserSettings, verification: Bool) {
        // Install only the owned read-only loader. This constructs no storage
        // and performs no startup discovery/body read or connection activation.
        #if TRAVERSE_SFTP_EDITOR_QA
        let containerReviewVisit = GeneratedSandboxReview.containerReviewRequested
        #else
        let containerReviewVisit = false
        #endif
        if !verification && (!containerReviewVisit || GeneratedSandboxReview.smbOriginalSaveReviewAdmitted) {
            ApplicationSMBConnections.shared.installPersistentSavedVersionsLoader()
        }
        if !verification && !containerReviewVisit {
            ApplicationDiagnostics.shared.start(settings: settings)
        }
        #if TRAVERSE_SFTP_EDITOR_QA
        // Use the product recorder in this explicitly admitted local review,
        // within its existing container ceiling. Retained segments from an
        // earlier review must fit too; 8 KiB rejected the existing 17 KiB log.
        // Remote/read-only routes stay unchanged.
        if !verification && GeneratedSandboxReview.localDirectoryReviewAdmitted
            && !GeneratedSandboxReview.retainedEditorReadOnlyAdmitted,
           let limits = try? DiagnosticHistoryLimits(bytes: 64 << 10, segmentBytes: 32 << 10) {
            ApplicationDiagnostics.shared.start(settings: settings, limits: limits)
        }
        #endif
        if !verification && !containerReviewVisit { ApplicationUpdates.shared.start(settings: settings) }
        InterfacePresentation.shared.bind(settings)
        StorageChartIntegration.configure(settings: settings)
        let controller = BrowserWindowController(settings: settings)
        browserWindow = controller
        if !verification && !containerReviewVisit {
            ApplicationCrashReports.shared.start(settings: settings, browser: controller.browser)
        }
        incomingFolders.attach(controller)
        if !verification, IncomingFolderService.available {
            let service = IncomingFolderService { [weak self] urls in
                guard let self else { return }
                self.incomingFolders.receive(urls)
                self.browserWindow?.showWindow(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            incomingFolderService = service
            NSApplication.shared.servicesProvider = service
        }
        NSApplication.shared.mainMenu = BrowserMenus.applicationMenu(target: controller.browser)
        #if DEBUG
        let controlled = verification && ProcessInfo.processInfo.arguments.contains("--offscreen")
        if !controlled {
            controller.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            // The native hierarchy is still laid out/renderable. Controlled
            // verification must not activate the app or order a window on screen.
            controller.window?.contentView?.layoutSubtreeIfNeeded()
        }
        #else
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        #if DEBUG
        // This separate diagnostic installs begin-completion guards first.
        if !ProcessInfo.processInfo.arguments.contains("--verify-grouped-copy-responsiveness")
            && !ProcessInfo.processInfo.arguments.contains("--check-sandbox-foundation") { controller.beginBrowsing() }
        #else
        controller.beginBrowsing()
        #endif
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.zipOneFileAccessAdmitted {
            Task { await OperationAccessRecoverySignedVerification.run(controller: controller,
                incoming: incomingFolders) }
        }
        if GeneratedSandboxReview.driveHealthReadAdmitted {
            Task { await DriveHealthSignedVerification.run() }
        }
        if GeneratedSandboxReview.archivePublicAccessAdmitted {
            Task { await OperationAccessRecoverySignedVerification.runArchives(controller: controller,
                incoming: incomingFolders) }
        }
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            Task { await OperationAccessRecoverySignedVerification.runRemoteDownloads(controller: controller,
                incoming: incomingFolders, isSMB: GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted) }
        }
        if GeneratedSandboxReview.certificateConnectionAdmitted {
            Task { await SFTPKeyConnectionVerification.runCertificates(controller: controller,
                incoming: incomingFolders) }
        }
        if GeneratedSandboxReview.archivePromiseAdmitted {
            Task { await OperationAccessRecoverySignedVerification.runArchivePromises(controller: controller,
                incoming: incomingFolders) }
        }
        if GeneratedSandboxReview.archiveInternalAdmitted {
            Task { await OperationAccessRecoverySignedVerification.runArchiveClipboard(controller: controller,
                incoming: incomingFolders) }
        }
        if GeneratedSandboxReview.retainedEditorRetirementV5Admitted {
            Task { await OperationAccessRecoverySignedVerification.runRetainedEditorRetirement(controller: controller) }
        }
        if GeneratedSandboxReview.retainedEditorReadOnlyAdmitted {
            Task { await OperationAccessRecoverySignedVerification.runRetainedEditorReadOnly(controller: controller) }
        }
        #endif
        #if DEBUG
        if verification {
            Task { await UIVerification.run(windowController: controller) }
        }
        #endif
        if !verification && !containerReviewVisit && !settings.initialSetupCompleted {
            TraverseSetupController.shared.show(from: controller.browser)
        }
        if !verification && !containerReviewVisit {
            ApplicationCommunitySupport.shared.configure(browser: controller.browser)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if GeneratedDriveImageReview.requested { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-ui") && ProcessInfo.processInfo.arguments.contains("--offscreen") {
            print("MAC_EXPLORER_CONTROLLED_REOPEN_IGNORED")
            return false
        }
        #endif
        if browserWindow?.window?.isVisible != true {
            browserWindow?.showWindow(nil)
            browserWindow?.resumeBrowsing()
        }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        browserWindow?.invalidatePendingSearchOpen()
    }
    func application(_ application:NSApplication, open urls:[URL]) {
        if GeneratedDriveImageReview.requested { return }
        #if DEBUG
        if !didFinishForIncomingVerification { incomingBeforeDidFinishForVerification = true }
        #endif
        incomingFolders.receive(urls)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if GeneratedDriveImageReview.requested { return }
        #if DEBUG
        // A sealed qualification process never starts ordinary update/shortcut
        // activation work, including activation before the runner task executes.
        if ProcessInfo.processInfo.arguments.contains("--check-analysis-session-reuse") { return }
        #endif
        #if DEBUG
        if refusedQualificationLaunch { return }
        #endif
        SystemShortcutSnapshot.shared.refresh()
        ApplicationUpdates.shared.becameActive()
    }

    /// An editor can outlive its Explorer window. Explicit View Results may
    /// reopen the existing workspace, using only its identical history engine.
    /// It never creates a second history or changes the captured operation ID.
    func revealEditorRecoveryHost(for engine: RecoverableFileOperations) -> BrowserViewController? {
        guard !isFlushingForTermination, !terminationReady, let controller = browserWindow else { return nil }
        let browsers = [controller.browser] + Array(controller.workspace.browsers.values)
        guard let browser = browsers.first(where: { $0.recoverableFileOperations === engine }) else { return nil }
        controller.showWindow(nil); controller.resumeBrowsing()
        return browser.isBrowserSuspended ? nil : browser
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if TRAVERSE_DRIVE_IMAGE_QA
        // This role has no ordinary health, benchmark, sharing or browser
        // owner to tear down. A submitted APFS child must finish first.
        let operations = ApplicationOperationCoordinator.shared
        return operations.activeOwner == nil && !operations.drives.isBusy
            && ApplicationFileActivity.gate.activeCount == 0 ? .terminateNow : .terminateCancel
        #else
        #if DEBUG
        // A utility may automatically quit hidden apps. Keep a bounded,
        // explicitly requested offscreen check alive until it writes its result;
        // the runner still owns its timeout and the check can terminate itself.
        // Normal app launches and native Quit commands retain their usual path.
        if ProcessInfo.processInfo.arguments.contains("--verify-ui"),
           ProcessInfo.processInfo.arguments.contains("--offscreen"),
           let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == 0x61657674, event.eventID == 0x71756974 { // aevt/quit
            fputs("MAC_EXPLORER_CONTROLLED_EXTERNAL_QUIT_DEFERRED\n", stderr)
            return .terminateCancel
        }
        if AnalysisReuseVerification.isRunning {
            AnalysisReuseVerification.requestShutdown()
            return .terminateCancel
        }
        #endif
        ApplicationDriveDetails.shared.pauseHealthMonitoring()
        folderDefaults.beginTermination()
        if ApplicationDriveDetails.shared.hasPendingHealthCheck {
            if ApplicationDriveDetails.shared.isAutomaticHealthCheck {
                guard !isFlushingForTermination else { return .terminateCancel }
                isFlushingForTermination = true
                ApplicationDriveDetails.shared.stopHealthCheck()
                Task { @MainActor in
                    await ApplicationDriveDetails.shared.drainHealth()
                    isFlushingForTermination = false
                    guard !ApplicationDriveDetails.shared.hasPendingHealthCheck else {
                        resumeTerminationPreparations()
                        browserWindow?.browser.status.stringValue = "The drive health reader is still closing. Quit has been deferred."
                        return
                    }
                    requestTermination(sender)
                }
                return .terminateCancel
            }
            resumeTerminationPreparations()
            ApplicationDriveDetails.shared.stopHealthCheck(interrupt: true)
            ApplicationDriveDetails.shared.window?.makeKeyAndOrderFront(nil)
            browserWindow?.browser.status.stringValue = "Stopping the hardware health check. Quit again when its process has finished closing."
            return .terminateCancel
        }
        if ApplicationDriveBenchmark.shared.hasPendingWork {
            resumeTerminationPreparations()
            ApplicationDriveBenchmark.shared.reveal()
            browserWindow?.browser.status.stringValue = "Stop the benchmark and let its test file finish closing before quitting."
            return .terminateCancel
        }
        if ApplicationNativeSharing.hasActiveHandoff {
            ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
            resumeTerminationPreparations()
            browserWindow?.resumeBrowsing()
            browserWindow?.showWindow(nil)
            ApplicationNativeSharing.explainPendingSharing(from: browserWindow?.browser)
            return .terminateCancel
        }
        #if DEBUG
        if isolatedConnectionFormVerification || refusedQualificationLaunch {
            if let pending = folderDefaultTerminationReply(sender) { return pending }
            return .terminateNow
        }
        #endif
        if let startupTask {
            guard !isFlushingForTermination else { return .terminateCancel }
            isFlushingForTermination = true
            startupTask.cancel()
            Task {
                await startupTask.value
                guard await folderDefaults.prepareForTermination() else {
                    isFlushingForTermination = false; resumeTerminationPreparations(); return
                }
                await incomingFolders.closeAndDrain()
                terminationReady = true
                requestTermination(sender)
            }
            return .terminateCancel
        }
        if ApplicationPrivateNames.shared.isSaving {
            ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
            resumeTerminationPreparations()
            return .terminateCancel
        }
        if let draft = ApplicationUpdates.unsavedNamesWindow {
            ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
            resumeTerminationPreparations()
            draft.makeKeyAndOrderFront(nil)
            browserWindow?.browser.status.stringValue = "Save or cancel your Names & Labels changes before quitting or restarting to update."
            return .terminateCancel
        }
        if ApplicationRemoteTextEditors.shared.hasManagedDocuments || ApplicationLocalTextEditors.shared.hasManagedDocuments {
            guard !isFlushingForTermination else { return .terminateCancel }
            isFlushingForTermination = true
            Task { @MainActor in
                let remoteReady = await ApplicationRemoteTextEditors.shared.prepareForTermination()
                let ready: Bool
                if remoteReady { ready = await ApplicationLocalTextEditors.shared.prepareForTermination() } else { ready = false }
                isFlushingForTermination = false
                if ready { requestTermination(sender) }
                else { ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination(); resumeTerminationPreparations() }
            }
            return .terminateCancel
        }
        if let pending = folderDefaultTerminationReply(sender) { return pending }
        guard let controller = browserWindow else { return .terminateNow }
        let browser = controller.browser
        if browser.hasPendingFileOperation {
            ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
            resumeTerminationPreparations()
            ApplicationDiagnostics.shared.event(.shutdown,.blocked)
            browserWindow?.showWindow(nil)
            browser.explainPendingOperation()
            return .terminateCancel
        }
        if terminationReady { return .terminateNow }
        guard !isFlushingForTermination else { return .terminateCancel }
        isFlushingForTermination = true
        controller.suspendBrowsing()
        Task {
            do { try ApplicationCompressedArchives.shared.prepareForQuiescence() }
            catch {
                isFlushingForTermination = false
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations(); controller.resumeBrowsing()
                browser.status.stringValue = "A temporary archive copy is still closing. Quit has been deferred."
                return
            }
            defer { if !terminationReady { ApplicationCompressedArchives.shared.resumeAfterQuiescence() } }
            guard await drainNativeSharingForTermination(controller) else { return }
            await SelectionGroupResultsWindow.closeAllAndDrain()
            await browser.operationPreparationTask?.value
            for pane in controller.workspace.browsers.values { await pane.operationPreparationTask?.value }
            guard await ApplicationUpdates.shared.prepareWorkspaceForRestart(controller) else {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false
                controller.resumeBrowsing()
                browser.status.stringValue = "The update restart was deferred because your windows could not be saved. Your files are unchanged."
                return
            }
            await incomingFolders.closeAndDrain()
            await ApplicationSMBConnections.shared.closeAndDrain()
            guard await SMBBrowserLifetimes.shared.closeAndDrain() else {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false
                ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume()
                controller.resumeBrowsing()
                browser.status.stringValue = "An SMB worker is still closing. Its resources remain retained; quitting has been deferred."
                return
            }
            guard await ApplicationSFTPFilePromises.shared.closeAndDrain() else {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false; ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume(); controller.resumeBrowsing()
                browser.status.stringValue = "A file promised from SFTP is still closing. Its resources remain retained; quitting has been deferred."
                return
            }
            guard await SFTPBrowserLifetimes.shared.closeAndDrain() else {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false; ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume(); controller.resumeBrowsing()
                browser.status.stringValue = "An SFTP worker is still closing. Its resources remain retained; quitting has been deferred."; return
            }
            guard await SFTPWorkerSession.pauseAndDrainOwned() else {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false; ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume(); controller.resumeBrowsing()
                browser.status.stringValue = "An SFTP setup worker is still closing. Its resources remain retained; quitting has been deferred."; return
            }
            await ApplicationStorageAnalysis.shared.stopAndDrain(shuttingDown: true)
            await ApplicationArchiveExports.shared.closeAndDrain()
            await ApplicationZIPBrowser.shared.stopAndDrain()
            await ApplicationTARBrowser.shared.closeAndDrain()
            await ArchiveTabCatalogPool.shared.closeAndDrain()
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            await ApplicationArchiveCreation.shared.closeAndDrain()
            guard await ApplicationCompressedArchives.shared.closeAndDrain() else {
                isFlushingForTermination = false
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                ApplicationStorageAnalysis.shared.resumeAfterCancelledTermination()
                ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume(); controller.resumeBrowsing()
                browser.status.stringValue = "A temporary archive copy could not be closed. Quit has been deferred."
                return
            }
            await ApplicationNotices.shared.closeAndDrain()
            await ApplicationNotices.projectLicense.closeAndDrain()
            await ApplicationBatchRename.shared.closeAndDrain()
            if DriveDetailsFeature.ordinaryEnabled { await ApplicationDriveDetails.shared.closeAndDrain() }
            if DriveManagementFeature.ordinaryEnabled { await ApplicationDriveManagement.shared.closeAndDrain() }
            await browser.operationCoordinator.drives.drainProtection()
            await controller.flushSession()
            if browser.hasPendingFileOperation {
                ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                resumeTerminationPreparations()
                isFlushingForTermination = false
                ApplicationStorageAnalysis.shared.resumeAfterCancelledTermination()
                ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                incomingFolders.resume()
                controller.resumeBrowsing()
                browser.explainPendingOperation()
            } else {
                guard await ApplicationUpdates.shared.closeAndDrain() else {
                    ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
                    resumeTerminationPreparations()
                    isFlushingForTermination = false
                    ApplicationUpdates.shared.resumeAfterCancelledTermination()
                    ApplicationStorageAnalysis.shared.resumeAfterCancelledTermination()
                    ApplicationSMBConnections.shared.resumeAfterCancelledTermination()
                    incomingFolders.resume(); controller.resumeBrowsing()
                    browser.status.stringValue = "An update connection is still closing. Quit has been deferred until it finishes."
                    return
                }
                await ApplicationPrivateNames.shared.close()
                await ApplicationDiagnostics.shared.closeAndDrain()
                #if TRAVERSE_SFTP_EDITOR_QA
                if GeneratedSandboxReview.containerReviewRequested {
                    // Quit still completes; the host refuses a missing or
                    // unsuccessful post-drain count as acceptance evidence.
                    _ = await GeneratedSandboxReview.accountContainerReview(phase: "after")
                }
                #endif
                terminationReady = true
                requestTermination(sender)
            }
        }
        // Return to the normal event loop before awaiting Swift actor work.
        // terminateLater can enter a nested loop while the caller is itself a
        // MainActor task, starving the task that must flush and reply.
        return .terminateCancel
        #endif
    }

    /// A slow native file check may outlive cancellation. Its actual owner stays
    /// charged; defer Quit and restore browsing rather than wait with a frozen
    /// workspace or manufacture a finished sharing lifetime.
    func drainNativeSharingForTermination(_ controller: BrowserWindowController,
                                         maximumWait: Duration = .seconds(2)) async -> Bool {
        let drained = await ApplicationNativeSharing.cancelPreparationsAndDrain(maximumWait: maximumWait)
        guard drained && !ApplicationNativeSharing.hasActiveHandoff else {
            ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
            resumeTerminationPreparations()
            isFlushingForTermination = false
            controller.resumeBrowsing()
            controller.showWindow(nil)
            if ApplicationNativeSharing.hasActiveHandoff {
                ApplicationNativeSharing.explainPendingSharing(from: controller.browser)
            } else {
                controller.browser.status.stringValue = ApplicationNativeSharing.pendingPreparationMessage
            }
            ApplicationDiagnostics.shared.event(.shutdown, .blocked)
            return false
        }
        return true
    }
}

@MainActor
final class BrowserWindow: NSWindow {
    var titlebarMaterial: BrowserTitlebarMaterial?
    weak var browser: BrowserViewController?
    weak var workspace: BrowserWorkspaceController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            workspace?.activatePane(at: event.locationInWindow)
            (workspace?.activeBrowser ?? browser)?.folderSummary.cancel()
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let browser {
            BrowserShortcutMenus.refresh(NSApplication.shared.mainMenu, browser: browser)
            if !(firstResponder is NSTextView), event.isARepeat, let shortcut = BrowserShortcut(event),
               let action = browser.settings.shortcutMap.resolve(shortcut,
                    fileSurface: firstResponder === browser.activeFileView || firstResponder === browser.volumeBrowser.collectionView),
               !action.allowsRepeat { return true }
        }
        // Native menu user overrides and normal responder editing get priority.
        if super.performKeyEquivalent(with: event) { return true }
        return browser?.handleExplorerShortcut(event) == true
    }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let workspace: BrowserWorkspaceController
    let isWorkspacePresentation: Bool
    var browser: BrowserViewController { workspace.activeBrowser }
    private var subscriptions: Set<AnyCancellable> = []

    init(settings: BrowserSettings) {
        workspace = BrowserWorkspaceController(settings: settings)
        #if DEBUG
        // Existing component regressions keep their standalone browser harness;
        // the new substantial suite exercises the actual workspace composition.
        let arguments = ProcessInfo.processInfo.arguments
        isWorkspacePresentation = !arguments.contains("--verify-ui")
            || arguments.contains("--check-editor-preferences")
            || arguments.contains("--check-connection-navigation")
            || arguments.contains("--check-substantial") || arguments.contains("--check-chrome")
            || arguments.contains("--check-address")
            || arguments.contains("--check-move-workspace")
            || arguments.contains("--check-private-move-members")
            || arguments.contains("--check-private-management")
            || arguments.contains("--check-private-import")
            || arguments.contains("--check-private-import-scale")
            || arguments.contains("--check-launch-profiles")
            || arguments.contains("--check-profile-workspaces-ui")
            || arguments.contains("--check-queue-priority")
            || arguments.contains("--check-search-provider-admission")
            || arguments.contains("--check-search-progress")
            || arguments.contains("--check-search-scale")
            || arguments.contains("--check-incoming-system")
            || arguments.contains("--check-archive-pane-destination")
            || arguments.contains("--check-archive-search")
            || arguments.contains("--check-inline-archives")
            || arguments.contains("--check-inline-archive-motion")
            || arguments.contains("--check-tar-preview-native")
            || arguments.contains("--check-tar-archive")
            || arguments.contains("--check-selection-group-native")
            || arguments.contains("--check-airdrop-native")
            || arguments.contains("--check-private-labels")
            || arguments.contains("--check-archive-member-drag")
            || arguments.contains("--check-archive-promise-export")
            || arguments.contains("--check-archive-promise-gesture")
            || arguments.contains("--check-archive-sorting")
            || arguments.contains("--clipboard-copy-members")
            || arguments.contains("--check-browser-tasks")
            || arguments.contains("--check-development-motion")
            || arguments.contains("--check-header-hover")
            || arguments.contains("--check-properties-storage")
            || arguments.contains("--check-purpose-journey")
            || arguments.contains("--check-folder-opener")
            || arguments.contains("--check-archive-byte-preview")
            || arguments.contains("--check-filename-copy")
            || arguments.contains("--check-inline-preview-owner")
            || arguments.contains("--check-folder-views")
            || arguments.contains("--check-tab-motion")
            || arguments.contains("--check-tester-repairs")
            || arguments.contains("--check-tool-windows")
            || arguments.contains("--check-smb-browser")
            || arguments.contains("--check-smb-connect-live")
            || arguments.contains("--check-smb-browser-ui")
            || arguments.contains("--check-smb-selected-download")
            || arguments.contains("--check-smb-folder-download")
            || arguments.contains("--check-sftp-live-standalone")
            || arguments.contains("--check-sftp-download-ui")
            || arguments.contains("--check-sftp-upload-ui")
            || arguments.contains("--check-sftp-auth-transfer")
            || arguments.contains("--check-sftp-routed-upload")
            || arguments.contains("--check-sftp-folder-download")
            || arguments.contains("--check-sftp-folder-review")
            || arguments.contains("--check-transfer-diagnostics")
            || arguments.contains("--check-data-classification")
            || arguments.contains("--check-network-workspaces")
            || arguments.contains("--check-network-workspace-connection")
            || arguments.contains("--check-network-workspace-smb")
            || arguments.contains("--check-network-workspace-route")
            || arguments.contains("--check-setup-lifetime")
            || arguments.contains("--check-workspace-input")
            || arguments.contains("--check-incoming-folders")
            || arguments.contains("--check-quick-profiles")
            || arguments.contains("--check-pane-transfers")
            || arguments.contains("--check-motion-modes")
            || arguments.contains("--render-tool-window")
            || arguments.contains("--show-browser-repair-review")
            || arguments.contains("--verify-grouped-copy-queue")
            || arguments.contains("--verify-grouped-copy-responsiveness")
        #else
        isWorkspacePresentation = true
        #endif
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Traverse"
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingMode = .disallowed
        // Tab restoration is explicitly governed by our local opt-in store.
        window.isRestorable = false
        window.disableSnapshotRestoration()
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = settings.navigationStyle == .glass && settings.glassNavigation
        window.titlebarSeparatorStyle = .none
        window.contentViewController = isWorkspacePresentation ? workspace : workspace.primaryBrowser
        window.workspace = isWorkspacePresentation ? workspace : nil
        window.browser = workspace.activeBrowser
        super.init(window: window)
        window.delegate = self
        workspace.onActiveBrowserChanged = { [weak self, weak window] browser in
            window?.browser = browser
            window?.title = "\(browser.location.displayName) — Traverse"
            self?.retargetMenus(to: browser)
        }
        let toolbar = NSToolbar(identifier: "MacExplorer.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = []
        window.toolbar = toolbar
        if let root = window.contentView {
            let backdrop = BrowserTitlebarMaterial()
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(backdrop, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: root.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
            ])
            backdrop.surface.isGlassEnabled = settings.navigationStyle == .glass && settings.glassNavigation
            window.titlebarMaterial = backdrop
        }
        settings.$showsCommandRow.removeDuplicates().sink { [weak window] visible in
            window?.toolbar?.isVisible = visible
            window?.titleVisibility = visible ? .hidden : .visible
        }.store(in: &subscriptions)
        settings.$motion.removeDuplicates().sink { [weak window] value in
            window?.animationBehavior = value.mode == .full && value.allows(.windows)
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .default : .none
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak window, weak settings] _ in
                guard let settings else { return }
                window?.animationBehavior = settings.motion.mode == .full && settings.motion.allows(.windows)
                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .default : .none
            }.store(in: &subscriptions)
        window.setContentSize(NSSize(width: 1140, height: 760))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func beginBrowsing() {
        if isWorkspacePresentation { workspace.begin() } else { browser.begin() }
    }
    func suspendBrowsing() {
        if isWorkspacePresentation { workspace.suspendWorkspace() } else { browser.suspendBrowser() }
    }
    func resumeBrowsing() {
        if isWorkspacePresentation { workspace.resumeWorkspace() } else { browser.resumeBrowser() }
    }
    func flushSession() async {
        if isWorkspacePresentation { await workspace.flushSession(closingTools: true) } else { await browser.flushBrowserSession() }
        _ = await browser.pinsController.flush()
        _ = await browser.sidebarLayoutOwner.flush()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !browser.hasPendingFileOperation else {
            browser.explainPendingOperation()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { suspendBrowsing() }

    func windowDidResignKey(_ notification: Notification) { invalidatePendingSearchOpen() }

    /// A pending result validation cannot regain authority merely because focus
    /// returns before its worker completes.
    func invalidatePendingSearchOpen() {
        for browser in workspace.browsers.values { browser.metadataSearch.openContextWillChange() }
    }

    private func retargetMenus(to browser: BrowserViewController) {
        NSApplication.shared.mainMenu = BrowserMenus.applicationMenu(target: browser)
        for item in window?.toolbar?.items ?? [] {
            guard let item = item as? NSMenuToolbarItem else { continue }
            let kind: BrowserMenus.Kind?
            switch item.itemIdentifier.rawValue {
            case "fileMenu": kind = .file
            case "viewMenu": kind = .view
            case "goMenu": kind = .go
            case "settingsMenu": kind = .settings
            case "helpMenu": kind = .help
            default: kind = nil
            }
            if let kind { item.menu = BrowserMenus.menu(kind, target: browser) }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("fileMenu"), .space, .init("viewMenu"), .space, .init("goMenu"), .space,
         .init("settingsMenu"), .space, .init("helpMenu"), .flexibleSpace, .init("appName")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let kind: BrowserMenus.Kind
        switch identifier.rawValue {
        case "fileMenu": kind = .file
        case "viewMenu": kind = .view
        case "goMenu": kind = .go
        case "settingsMenu": kind = .settings
        case "helpMenu": kind = .help
        case "appName":
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Traverse"
            item.view = label("Traverse", size: 12, color: .secondaryLabelColor)
            return item
        default: return nil
        }
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = kind.rawValue
        item.title = kind.rawValue
        item.menu = BrowserMenus.menu(kind, target: browser)
        item.isBordered = false
        item.showsIndicator = false
        item.isNavigational = true
        return item
    }
}
