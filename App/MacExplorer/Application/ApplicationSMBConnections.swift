import AppKit
import Combine
import ExplorerCore
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage

enum SMBConnectionFeature {
    static var ordinaryEnabled: Bool {
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") != nil { return false }
        #endif
        return true
    }
}

/// Network readers keep their own lifetime. Their only local writes are under
/// registered, removal-protected profile roots; unrelated disk quiescence must
/// not wait for a connection which is deliberately still open.
enum ApplicationSMBActivity { static let gate = FileActivityGate(maximumActivities: 8) }

/// An explicit saved-server click belongs to this browser visit. Network work
/// can finish later, but cannot attach its result to a different tab or visit.
struct SavedServerClickTarget: Sendable {
    let tabID: UUID, visitID: UUID
    @MainActor func isCurrent(in browser: BrowserViewController) -> Bool {
        !browser.isBrowserSuspended && browser.view.window != nil
            && browser.activeID == tabID && browser.sessionID == visitID
    }
}

@MainActor private final class SavedConnectCompletion {
    private let callback: @MainActor (Bool) -> Void
    private(set) var completed = false
    init(_ callback: @escaping @MainActor (Bool) -> Void) { self.callback = callback }
    func finish(_ connected: Bool) {
        guard !completed else { return }
        completed = true; callback(connected)
    }
}

/// One explicit setup/management owner for the app profile. It retains pending
/// Connect/remember/cleanup work through real drain, including when Quit arrives.
#if DEBUG
@MainActor enum GateAConnectionObservation {
    case beforePrepare([URL]), admitted(ConnectionWorkspaceAdmission), submitted
    case refused(ConnectionWorkspaceFailure?)
}
#endif
@MainActor final class ApplicationSMBConnections {
    private static let profiles = NSHashTable<ApplicationSMBConnections>.weakObjects()
    static let shared = ApplicationSMBConnections()
    static var protectedStorageLocations: [URL] { profiles.allObjects.flatMap { [$0.profileRoot, $0.runtimeRoot, $0.smbEditorRoot,
        $0.earlierRoot, $0.locationRecordRoot, $0.downloadRoot, $0.uploadRoot].compactMap { $0 } } }
    private let directory: URL?
    private var profileRoot: URL?
    private let workspace: ConnectionWorkspace?
    private let workspaceLayout: ApplicationStorageLayout?
    private var earlierRoot: URL?
    private var locationRecordRoot: URL?
    private var runtimeRoot: URL?
    private var smbEditorRoot: URL?
    private var downloadRoot: URL?
    private var uploadRoot: URL?
    private let passwords: SMBPasswordVault
    private let sftpPasswords: SFTPPasswordVault
    private let sftpEnabled: Bool
    private var sftp: ApplicationSFTPConnections?
    private var smbDownloads: SMBDownloadStorage?
    private var smbUploads: SMBUploadStorage?
    private var smbActions: SMBActionStorage?
    private var smbEditorStorage: SMBInPlaceWorkingCopyStorage?
    private var coordinator: SMBConnectionCoordinator?
    private var storage: SMBTemporaryStorage?
    private var window: SMBConnectWindowController?
    private var storageWindow: SMBConnectionStorageWindow?
    private var preparing: Task<Void, Never>?
    private var savedConnecting: Task<Void, Never>?
    private var savedPreparing = false
    private var savedProgress: AnyCancellable?
    private var savedCompletion: AnyCancellable?
    private var savedFinish: SavedConnectCompletion?
    private var savedGeneration = UUID()
    private var savedCancelRequested = false
    private var preparation: PrivateStateDirectorySequence?
    private weak var target: BrowserViewController?
    private var layoutTarget: WorkspaceReconnectTarget?
    private var pendingRouteForSaving: SFTPRouteDescription?
    private var generation = UUID(), shuttingDown = false
    private var metadataTasks: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
    var gateAObservation: ((GateAConnectionObservation) -> Void)?
    private var gateANoFocus = false
    var gateAHasStorage: Bool { storage != nil }
    var gateAHasCoordinator: Bool { coordinator != nil }
    func gateAWaitForSetup() async {
        while let pending = preparing ?? savedConnecting { await pending.value }
    }
    // The caller must first validate the exact bounded GateA runtime marker.
    // Inert alternate construction only; admission still comes from workspace.
    init(gateAQualificationLayout layout: ApplicationStorageLayout,
         passwords: SMBPasswordVault, sftpPasswords: SFTPPasswordVault) {
        directory = layout.stateDirectory; profileRoot = layout.stateDirectory
        workspaceLayout = layout; workspace = try? ConnectionWorkspace(layout: layout)
        smbEditorRoot = layout.smbInPlaceRecoveryDirectory
        self.passwords = passwords; self.sftpPasswords = sftpPasswords
        sftpEnabled = false; gateANoFocus = true
        Self.profiles.add(self)
    }
    var pendingMetadataCountForVerification: Int { metadataTasks.count }
    #endif
    func connectionMetadataAccess(isSFTP: Bool) -> ConnectionMetadataAccess? {
        guard !shuttingDown else { return nil }
        if isSFTP { return sftp.map { .sftp($0.remembered) } }
        return coordinator.map { .smb($0) }
    }
    func retainConnectionMetadataWork(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !shuttingDown, metadataTasks.count < 8 else { return nil }
        let id = UUID()
        let task = Task<Void, Never> { [self] in await operation(); metadataTasks[id] = nil }
        metadataTasks[id] = task; return task
    }
    func presentRouteForSaving(_ route: SFTPRouteDescription, in browser: BrowserViewController) {
        guard !shuttingDown, preparing == nil else { return }
        pendingRouteForSaving = route
        present(in: browser)
        guard let window, !window.model.busy else { return }
        pendingRouteForSaving = nil; window.model.prefillUnsavedRoute(route)
        window.present(relativeTo: browser.view.window)
    }
    init(directory: URL? = nil, passwords: SMBPasswordVault? = nil,
         sftpPasswords: SFTPPasswordVault? = nil, sftpEnabled: Bool = SFTPConnectionFeature.ordinaryEnabled) {
        let direct = AppFeatureAvailability.policy.edition == .directPublic
        self.directory = directory; self.profileRoot = directory
        self.passwords = passwords ?? (direct ? .directLoginKeychain() : .loginKeychain())
        self.sftpPasswords = sftpPasswords ?? (direct ? .directLoginKeychain() : .loginKeychain())
        self.sftpEnabled = sftpEnabled
        // Inert owner composition. No activation, filesystem or credentials
        // access occurs when the global Saved Versions entry is installed.
        let selected: ApplicationStorageLayout?
        if let directory {
            selected = try? ApplicationStorageLayout(developmentState: directory,
                legacyAnalysis: directory.appendingPathComponent("unused-analysis-layout", isDirectory: true))
        } else {
            selected = AppStorageLocations.layout
        }
        workspaceLayout = selected; workspace = selected.flatMap { try? ConnectionWorkspace(layout: $0) }
        smbEditorRoot = selected?.smbInPlaceRecoveryDirectory
        // Passive saved-server discovery is now available before Connect. Keep
        // that same private state root protected before the first read too.
        profileRoot = selected?.stateDirectory ?? directory
        Self.profiles.add(self)
    }
    func present(in browser: BrowserViewController, offscreen: Bool = false,
                 reconnect: WorkspaceReconnectTarget? = nil, savedServer: WorkspaceConnectionBookmark? = nil) {
        ApplicationDiagnostics.shared.event(.connect, .requested, context: .init(.connectionPresentation))
        guard !savedPreparing else {
            browser.status.stringValue = "A saved connection is still preparing."
            return
        }
        guard !shuttingDown, !browser.operationCoordinator.drives.isBusy else {
            browser.status.stringValue = "Connection setup is waiting for the current work to finish."
            ApplicationDiagnostics.shared.event(.connect, .blocked, context: .init(.connectionPresentation))
            return
        }
        guard preparing == nil || window != nil else {
            browser.status.stringValue = "Connection activity is opening. Try again in a moment."
            return
        }
        if let window, window.window?.isVisible == true || preparing != nil || window.model.busy {
            if (reconnect != nil || savedServer != nil), preparing == nil, !window.model.unavailable {
                window.window?.close(); self.window = nil
            } else {
                if preparing == nil, !window.model.unavailable, layoutTarget == nil { target = browser }
                window.present(relativeTo: browser.view.window, offscreen: offscreen)
                if window.model.storageNeedsReview && preparing == nil {
                    startPreparing(window, in: browser, reconnect: reconnect, savedServer: savedServer)
                }
                return
            }
        }
        guard reconnect == nil || reconnect?.isCurrent == true else { browser.status.stringValue = WorkspaceReconnectFailure.stale.message; return }
        layoutTarget = reconnect; target = browser
        let controller = makeConnectWindow(in: browser, reconnect: reconnect)
        window = controller
        controller.didClose = { [weak self, weak controller] in
            guard let self, self.window === controller else { return }; self.preparing?.cancel()
        }
        controller.present(relativeTo: browser.view.window, offscreen: offscreen)
        ApplicationDiagnostics.shared.event(.connect, .presenting, context: .init(.connectionPresentation))
        startPreparing(controller, in: browser, reconnect: reconnect, savedServer: savedServer)
    }
    /// Only an explicit saved-server click reaches this path. The fresh settings
    /// read is metadata-only; the existing coordinator queries a saved secret
    /// only after endpoint preparation and, for SFTP, host verification.
    func connectSaved(in browser: BrowserViewController, savedServer bookmark: WorkspaceConnectionBookmark,
                      reconnect: WorkspaceReconnectTarget? = nil,
                      allowsFormFallback: Bool = true,
                      phase: @escaping @MainActor (String) -> Void,
                      finished: @escaping @MainActor (Bool) -> Void) {
        guard !shuttingDown, !browser.isBrowserSuspended, browser.view.window != nil,
              !browser.operationCoordinator.drives.isBusy, browser.view.window?.attachedSheet == nil,
              savedConnecting == nil, savedFinish?.completed != false,
              preparing == nil, window?.model.busy != true,
              reconnect == nil || (reconnect?.browser === browser && reconnect?.bookmark == bookmark && reconnect?.isCurrent == true),
              (try? bookmark.validate()) != nil else { finished(false); return }
        if window?.window?.isVisible == true {
            if allowsFormFallback { present(in: browser, reconnect: reconnect, savedServer: bookmark) }
            else { phase("Finish or close the open connection window, then reconnect.") }
            finished(false); return
        }
        savedGeneration = UUID(); let token = savedGeneration
        savedCancelRequested = false
        let completion = SavedConnectCompletion(finished)
        savedFinish = completion
        let click = SavedServerClickTarget(tabID: browser.activeID, visitID: browser.sessionID)
        savedPreparing = true
        phase("Connecting…")
        savedConnecting = Task { [weak self, weak browser] in
            guard let self, let browser else { completion.finish(false); return }
            defer {
                if savedGeneration == token {
                    savedConnecting = nil; savedPreparing = false
                    if window?.model.busy != true {
                        completion.finish(false)
                        if savedFinish === completion { savedFinish = nil }
                    }
                }
            }
            do {
                try await prepareConnectionServices(in: browser)
                try Task.checkCancellation()
                guard !shuttingDown, savedGeneration == token, click.isCurrent(in: browser),
                      reconnect?.isCurrent ?? true else {
                    completion.finish(false); return
                }
                guard let coordinator else { throw SMBBrowserFailure.stopped }
                let smbSnapshot = try await coordinator.inspect()
                let sftpSnapshot: SFTPSettingsSnapshot?
                if bookmark.isSFTP {
                    guard let sftp else { throw SFTPSessionFailure.stopped }
                    sftpSnapshot = try await sftp.remembered.inspect()
                } else { sftpSnapshot = nil }
                guard click.isCurrent(in: browser), reconnect?.isCurrent ?? true else { completion.finish(false); return }
                guard Self.canConnectSaved(bookmark, smb: smbSnapshot, sftp: sftpSnapshot) else {
                    savedPreparing = false
                    if allowsFormFallback { present(in: browser, reconnect: reconnect, savedServer: bookmark) }
                    else { phase("Sign-in details are needed. Open Connect to Server to continue.") }
                    completion.finish(false); return
                }
                let controller = makeConnectWindow(in: browser, reconnect: reconnect, savedBookmark: bookmark, savedClick: click)
                layoutTarget = reconnect; target = browser; window = controller
                installSFTP(on: controller, reconnect: reconnect, savedBookmark: bookmark, savedClick: click)
                controller.model.replaceServers(Self.choices(smbSnapshot))
                controller.model.replaceSFTPServers(SFTPConnectSavedChoices.values(sftpSnapshot))
                if bookmark.isSFTP { controller.model.connectionProtocol = .sftp }
                controller.model.selectWorkspaceLocation(bookmark, reopeningTab: reconnect != nil)
                // Reconnect is a read of an existing record, not an incidental
                // rewrite of saved settings or a new Keychain item.
                controller.model.rememberServer = false
                controller.model.rememberPassword = false
                guard !controller.model.workspaceBlocked else {
                    if allowsFormFallback { controller.present(relativeTo: browser.view.window) }
                    else { phase("Saved connection details changed. Open Connect to Server to review them."); window = nil }
                    completion.finish(false); return
                }
                savedProgress = controller.model.$message.sink { message in
                    if !message.isEmpty { phase(message) }
                }
                controller.model.connect()
                guard controller.model.busy else {
                    savedProgress = nil
                    controller.model.rememberServer = true
                    if allowsFormFallback { controller.present(relativeTo: browser.view.window) }
                    else { phase("Sign-in needs attention. Open Connect to Server to continue."); window = nil }
                    completion.finish(false); return
                }
                savedCompletion = controller.model.$busy.dropFirst().filter { !$0 }.prefix(1).sink { [weak self, weak browser, weak controller] _ in
                    Task { @MainActor in
                        guard let self, let browser, let controller, self.savedGeneration == token,
                              self.window === controller else {
                            completion.finish(false)
                            if self?.savedFinish === completion { self?.savedFinish = nil }
                            return
                        }
                        self.savedProgress = nil; self.savedCompletion = nil
                        let connected = controller.model.connected
                        if connected { self.window = nil }
                        else if !self.savedCancelRequested, click.isCurrent(in: browser), reconnect?.isCurrent ?? true {
                            controller.model.rememberServer = true
                            if controller.model.needsPasswordEntry {
                                controller.model.revealPasswordAfterSavedFailure()
                                controller.model.jumpHost.revealPasswordAfterSavedFailure()
                            }
                            if bookmark.isSFTP, let kind = self.sftp?.deferredHostReview {
                                controller.model.showDeferredHostReview(kind)
                            }
                            if allowsFormFallback { controller.present(relativeTo: browser.view.window) }
                            else {
                                phase("Connection needs attention. Open Connect to Server to review sign-in or server identity.")
                                self.window = nil
                            }
                        } else { self.window = nil }
                        completion.finish(connected)
                        if self.savedFinish === completion { self.savedFinish = nil }
                    }
                }
            } catch {
                guard savedGeneration == token, !shuttingDown, !Task.isCancelled,
                      click.isCurrent(in: browser), reconnect?.isCurrent ?? true else { completion.finish(false); return }
                savedPreparing = false
                if allowsFormFallback { present(in: browser, reconnect: reconnect, savedServer: bookmark) }
                else { phase("Connection could not be prepared. Open Connect to Server to review it.") }
                completion.finish(false)
            }
        }
    }
    func cancelSavedConnection() {
        savedCancelRequested = true
        savedConnecting?.cancel()
        if let window, window.window?.isVisible != true, window.model.busy { window.model.cancel() }
    }
    private static func canConnectSaved(_ bookmark: WorkspaceConnectionBookmark,
                                        smb: SMBServerSnapshot?, sftp: SFTPSettingsSnapshot?) -> Bool {
        switch bookmark.kind {
        case .smbServer:
            guard let server = smb?.visibleServers.first(where: { $0.id == bookmark.serverID }),
                  WorkspaceConnectionBinding.smb(server.details) == bookmark.binding else { return false }
            return smb?.credentials.contains { $0.reference.id == server.credentialID && $0.state == .ready } == true
        case .sftpServer:
            guard let server = sftp?.visibleServers.first(where: { $0.id == bookmark.serverID }),
                  WorkspaceConnectionBinding.sftp(server.details) == bookmark.binding else { return false }
            if server.usesServerPrompts { return true }
            if let method = server.keyAuthentication {
                return method.reference != nil && (!method.requiresCertificate || method.certificate != nil)
            }
            return sftp?.credentials.contains { $0.reference.id == server.credentialID && $0.state == .ready } == true
        case .sftpRoute:
            guard let route = sftp?.visibleRoutes.first(where: { $0.id == bookmark.serverID }),
                  WorkspaceConnectionBinding.route(route.details) == bookmark.binding else { return false }
            func ready(_ signIn: SFTPRouteSignIn, credentialID: UUID?, keyAccess: SFTPKeyAccessReference?) -> Bool {
                switch signIn {
                case .password: return sftp?.credentials.contains { $0.reference.id == credentialID && $0.state == .ready } == true
                case .keyFile: return keyAccess != nil
                case .serverPrompts: return true
                case .keyFileAndServerPrompts: return keyAccess != nil
                }
            }
            return ready(route.jump.signIn, credentialID: route.jump.credentialID, keyAccess: route.jump.keyAccess)
                && ready(route.destination.signIn, credentialID: route.destination.credentialID, keyAccess: route.destination.keyAccess)
        }
    }
    private func startPreparing(_ controller: SMBConnectWindowController, in browser: BrowserViewController,
                                reconnect: WorkspaceReconnectTarget?, savedServer: WorkspaceConnectionBookmark?) {
        guard preparing == nil, !shuttingDown, !controller.model.busy else { return }
        generation = UUID(); let token = generation; controller.model.managing = true
        preparing = Task { [weak self, weak browser, weak controller] in
            guard let self, let browser, let controller else { return }
            defer { if generation == token { preparing = nil }; controller.model.managing = false }
            do {
                try await prepareConnectionServices(in: browser)
                try Task.checkCancellation()
                guard !shuttingDown, generation == token, controller.window?.isVisible == true else { return }
                installSFTP(on: controller, reconnect: reconnect)
                controller.model.showConnectionStorageIssue("")
            } catch {
                guard !Task.isCancelled, !shuttingDown, generation == token, controller.window?.isVisible == true else { return }
                #if DEBUG
                gateAObservation?(.refused(error as? ConnectionWorkspaceFailure))
                #endif
                ApplicationDiagnostics.shared.event(.connect, .failed, error: DiagnosticErrors.project(error),
                    context: .init(.connectionWorkspacePreparation), causes: DiagnosticErrors.causes(error))
                controller.model.showConnectionStorageIssue("Connection setup needs attention. Your saved servers, files and versions are preserved. Review to continue.")
                browser.status.stringValue = "Connection setup needs review. Open Connect to Server for details."
            }
            // Saved settings are independent of transfer-workspace admission.
            // One unavailable protocol cannot hide the other protocol's rows.
            let saved = browser.savedServerLocations
            saved.refresh(); await saved.work?.value
            guard !Task.isCancelled, !shuttingDown, generation == token, controller.window?.isVisible == true else { return }
            controller.model.replaceServers(saved.snapshot.smbChoices)
            controller.model.replaceSFTPServers(saved.snapshot.sftpChoices)
            if let selected = reconnect?.bookmark ?? savedServer {
                controller.model.selectWorkspaceLocation(selected, reopeningTab: reconnect != nil)
                controller.setSidebarVisible(true, animated: false)
            } else if !saved.snapshot.locations.isEmpty { controller.setSidebarVisible(true) }
            if let route = pendingRouteForSaving { controller.model.prefillUnsavedRoute(route); pendingRouteForSaving = nil }
        }
    }

    private func prepareConnectionServices(in browser: BrowserViewController, reviewOnly: Bool = false) async throws {
        guard coordinator == nil else { return }
        #if TRAVERSE_SFTP_EDITOR_QA
        // Both review visits keep browser snapshots in memory. An explicit
        // Connect still uses this signed case's admitted connection workspace.
        let browserRoot = GeneratedSandboxReview.containerReviewRequested
            ? workspaceLayout?.stateDirectory : browser.developmentStateDirectory
        #else
        let browserRoot = browser.developmentStateDirectory
        #endif
        guard let root = directory ?? browserRoot,
              workspace != nil, let selected = workspaceLayout else { throw SMBBrowserFailure.storage }
        profileRoot = root; runtimeRoot = selected.persistentConnectionWorkspaceDirectory
        smbEditorRoot = selected.smbInPlaceRecoveryDirectory
        earlierRoot = selected.smbDirectory; locationRecordRoot = selected.connectionWorkspaceRecordDirectory
        downloadRoot = selected.ordinaryRemoteDownloadDirectory
        uploadRoot = root.appendingPathComponent("sftp-upload-history")
        #if DEBUG
        gateAObservation?(.beforePrepare(Self.protectedStorageLocations))
        #endif
        let admitted = try await prepareCurrentConnectionWorkspace(in: browser, reviewOnly: reviewOnly)
        try Task.checkCancellation()
        #if DEBUG
        gateAObservation?(.admitted(admitted))
        #endif
        guard !shuttingDown, !browser.isBrowserSuspended, !browser.operationCoordinator.drives.isBusy else { throw SMBBrowserFailure.stopped }
        let storage = admitted.metadataStorage
        let preparedState = try AppStoragePreparation.owner(for: root)
        let preparedCoordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage,
            servers: SMBSavedServerStore(directory: root.appendingPathComponent("smb-servers")),
            passwords: passwords, activity: ApplicationSMBActivity.gate,
            selectedDownloads: SMBDownloadFeature.available, textReads: RemoteTextViewFeature.smbAvailable,
            folderDownloads: SMBFolderDownloadFeature.available,
            freshUploads: SMBUploadFeature.available, folderUploads: SMBFolderUploadFeature.available)
        let bodies = selected.ordinaryRemoteDownloadDirectory
        // Construction is inert. Keep explicit review/discard of earlier
        // copies available even while new download publication is held.
        let publicDownload = RemoteDownloadPublicationFeature.qualifiesSMBPublicQuarantineDownload
        let publicGroups = RemoteDownloadPublicationFeature.qualifiesPublicQuarantineGroupDownload
        let smbGroups = publicGroups && (!GeneratedSandboxReview.publicSelectionDownloadAdmitted
            || GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted)
        let sftpGroups = publicGroups && (!GeneratedSandboxReview.publicSelectionDownloadAdmitted
            || GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted)
        let preparedDownloads: SMBDownloadStorage
        if smbGroups {
            preparedDownloads = try SMBDownloadStorage(directory: bodies, publicQuarantinePolicy: .sourceQualification,
                selectedGroupPublicQuarantinePolicy: .sourceQualification)
        } else {
            preparedDownloads = try publicDownload
                ? SMBDownloadStorage(directory: bodies, publicQuarantinePolicy: .sourceQualification)
                : SMBDownloadStorage(directory: bodies)
        }
        var preparedSFTP: ApplicationSFTPConnections?
        if sftpEnabled {
            let downloads: SFTPDownloadStorage
            if sftpGroups {
                downloads = try SFTPDownloadStorage(directory: bodies, publicQuarantinePolicy: .sourceQualification,
                    selectedGroupPublicQuarantinePolicy: .sourceQualification)
            } else {
                downloads = try RemoteDownloadPublicationFeature.qualifiesPublicQuarantineDownload
                    ? SFTPDownloadStorage(directory: bodies, publicQuarantinePolicy: .sourceQualification)
                    : SFTPDownloadStorage(directory: bodies)
            }
            preparedSFTP = try ApplicationSFTPConnections(root: root, storage: storage,
                downloads: downloads,
                uploads: SFTPUploadStorage(directory: root.appendingPathComponent("sftp-upload-history")), passwords: sftpPasswords)
        }
        self.storage = storage; preparation = preparedState; coordinator = preparedCoordinator
        smbDownloads = preparedDownloads
        smbUploads = SMBUploadFeature.available ? SMBUploadStorage(directory: root.appendingPathComponent("smb-upload-history")) : nil
        smbActions = SMBRemoteActionFeature.available ? SMBActionStorage(directory: root.appendingPathComponent("smb-file-action-history")) : nil
        sftp = preparedSFTP
    }
    private func finishSMBSetupAfterFailure(_ original: Error, in browser: BrowserViewController,
        workspace: ConnectionWorkspace) async throws -> ConnectionWorkspaceAdmission {
        let choice = try? await workspace.smbInPlaceUpgradeChoiceAfterExplicitRequest()
        try Task.checkCancellation()
        let candidate = window?.window
        let parent = candidate?.isVisible == true ? candidate : browser.view.window
        guard let choice, let parent, parent.isVisible, parent.attachedSheet == nil else { throw original }
        let alert = NSAlert(); alert.messageText = "Finish saved versions setup?"
        alert.informativeText = "A previous setup stopped before it finished. Finish setting up saved versions to edit files on this connection. No server file is changed by this setup."
        alert.addButton(withTitle: "Finish Setup"); alert.addButton(withTitle: "Cancel")
        let reply = try await smbSetupResponse(to: alert, in: parent)
        guard reply == .alertFirstButtonReturn else { throw CancellationError() }
        return try await workspace.resumeSMBInPlaceUpgrade(choice)
    }
    private func smbSetupResponse(to alert: NSAlert, in parent: NSWindow) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        let reply = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in
                if parent.attachedSheet === alert.window { parent.endSheet(alert.window, returnCode: .cancel) }
            }
        }
        try Task.checkCancellation(); return reply
    }
    private func confirmSMBEditorSetup(in browser: BrowserViewController) async throws -> Bool {
        let candidate = window?.window
        let parent = candidate?.isVisible == true ? candidate : browser.view.window
        guard let parent, parent.isVisible, parent.attachedSheet == nil else { throw SMBBrowserFailure.busy }
        let alert = NSAlert(); alert.messageText = "Enable server file editing?"
        alert.informativeText = "Traverse will keep local before/edited versions when you Save server files. This updates your saved connection data; older Traverse builds may no longer open it. You can browse and transfer without enabling editing."
        alert.addButton(withTitle: "Enable Editing")
        alert.addButton(withTitle: "Browse Without Editing")
        alert.addButton(withTitle: "Cancel")
        switch try await smbSetupResponse(to: alert, in: parent) {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: throw CancellationError()
        }
    }
    private func adoptConnectionWorkspace(_ admission: ConnectionWorkspaceAdmission) async {
        let updated = admission.metadataStorage
        // Bookkeeping of an actual committed upgrade cannot be skipped by
        // cancellation. These owners are inert until the later Connect call.
        storage = updated
        await storageWindow?.closeAndDrain(); storageWindow = nil
        await sftp?.adoptMetadataStorage(updated)
        ApplicationRemoteSavedVersions.shared.workspaceDidChange()
    }
    private func prepareCurrentConnectionWorkspace(in browser: BrowserViewController,
        reviewOnly: Bool = false) async throws -> ConnectionWorkspaceAdmission {
        guard let workspace else { throw SMBBrowserFailure.storage }
        do { return try await (reviewOnly ? workspace.admitExistingForReview() : workspace.prepareForConnect()) }
        catch {
            guard !reviewOnly, RemoteTextEditorFeature.smbAvailable else { throw error }
            let admission = try await finishSMBSetupAfterFailure(error, in: browser, workspace: workspace)
            await adoptConnectionWorkspace(admission)
            return admission
        }
    }
    /// A separate explicit Edit preparation, never part of ordinary browsing.
    /// A committed graph is adopted even if Cancel arrives before authentication.
    private func prepareSMBEditorStorage(in browser: BrowserViewController,
        current: ConnectionWorkspaceAdmission) async throws -> SMBInPlaceWorkingCopyStorage? {
        if let smbEditorStorage { return smbEditorStorage }
        guard let workspace else { throw SMBBrowserFailure.storage }
        if !current.supportsSMBInPlaceEdits {
            guard try await confirmSMBEditorSetup(in: browser) else { return nil }
        }
        let admission: ConnectionWorkspaceAdmission
        do { admission = try await workspace.prepareSMBInPlaceEdits() }
        catch ConnectionWorkspaceFailure.busy { throw SMBBrowserFailure.busy }
        catch { admission = try await finishSMBSetupAfterFailure(error, in: browser, workspace: workspace) }
        await adoptConnectionWorkspace(admission)
        let updated = admission.metadataStorage
        let policy: SMBOriginalSaveAttributePolicy
        if RemoteTextEditorFeature.smbOriginalSaveV3Available {
            policy = .creationApproximationQualification
        } else if GeneratedSandboxReview.smbOriginalSaveV2Admitted {
            policy = .sourceQualification
        } else {
            policy = .exactV1
        }
        let preparation = Task.detached(priority: .utility) {
            try SMBInPlaceWorkingCopyStorage(metadataStorage: updated, originalSaveAttributePolicy: policy)
        }
        let prepared = try await withTaskCancellationHandler { try await preparation.value }
            onCancel: { preparation.cancel() }
        smbEditorStorage = prepared
        return prepared
    }
    private func makeConnectWindow(in browser: BrowserViewController, reconnect: WorkspaceReconnectTarget?,
                                   savedBookmark: WorkspaceConnectionBookmark? = nil,
                                   savedClick: SavedServerClickTarget? = nil) -> SMBConnectWindowController {
        let controller = SMBConnectWindowController(settings: browser.settings) { [weak self] submission, phase in
            guard let self, let coordinator = self.coordinator, let browser = target, !shuttingDown, !browser.isBrowserSuspended,
                  browser.view.window != nil, !browser.operationCoordinator.drives.isBusy else { throw SMBBrowserFailure.stopped }
            #if DEBUG
            gateAObservation?(.submitted)
            #endif
            phase("Preparing connection…")
            guard savedClick?.isCurrent(in: browser) ?? true else { throw WorkspaceReconnectFailure.stale }
            let currentWorkspace = try await prepareCurrentConnectionWorkspace(in: browser); try Task.checkCancellation()
            guard let storage else { throw SMBBrowserFailure.stopped }
            try await preparation?.prepare(); try Task.checkCancellation()
            do { try await storage.prepareSharedOriginalStorageForConnect() }
            catch is CancellationError { throw CancellationError() }
            catch { throw SMBBrowserFailure.storage }
            try Task.checkCancellation()
            guard savedClick?.isCurrent(in: browser) ?? true else { throw WorkspaceReconnectFailure.stale }
            let draft = try SMBServerDraft(name: submission.name, address: submission.address,
                account: submission.account, domain: submission.domain, security: submission.security,
                transferPreference: submission.transferPreference)
            if let reconnect { try reconnect.validate(submission, snapshot: try await coordinator.inspect()) }
            if let savedBookmark { try Self.validateSaved(savedBookmark, draft: draft, id: submission.editingServer,
                snapshot: try await coordinator.inspect()) }
            let editorEligible = RemoteTextEditorFeature.smbAvailable && draft.security == .encrypted
                && draft.effectiveTransferPreference != .readOnly
            let editorReservation = editorEligible ? ApplicationRemoteTextEditors.shared.reserveSMBPreparedConnection() : nil
            defer { ApplicationRemoteTextEditors.shared.releasePreparedConnection(editorReservation) }
            let editorStorage = editorReservation != nil
                ? try await prepareSMBEditorStorage(in: browser, current: currentWorkspace) : nil
            try Task.checkCancellation()
            let result = try await coordinator.connect(draft, typedPassword: submission.password, savedServerID: submission.editingServer,
                rememberServer: submission.rememberServer, rememberPassword: submission.rememberPassword,
                inPlaceTextEdits: editorStorage != nil, metadataStorage: self.storage)
            if let editorStorage {
                do {
                    try Task.checkCancellation()
                    try ApplicationRemoteTextEditors.shared.registerPrepared(session: result.session, storage: editorStorage,
                        reservation: editorReservation)
                } catch {
                    let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                    if !ended { throw WorkspaceReconnectFailure.closureUncertain }; throw error
                }
            }
            let snapshot = try? await coordinator.inspect()
            browser.savedServerLocations.refresh()
            if let reconnect {
                do { try reconnect.validate(submission, snapshot: snapshot) }
                catch {
                    let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                    if !ended { throw WorkspaceReconnectFailure.closureUncertain }; throw error
                }
            }
            if let savedBookmark {
                do { try Self.validateSaved(savedBookmark, draft: draft, id: submission.editingServer, snapshot: snapshot) }
                catch {
                    let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                    if !ended { throw WorkspaceReconnectFailure.closureUncertain }; throw error
                }
            }
            if let savedClick, !savedClick.isCurrent(in: browser) {
                let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                if !ended { throw WorkspaceReconnectFailure.closureUncertain }
                throw WorkspaceReconnectFailure.stale
            }
            let savedConnection: WorkspaceConnectionBookmark?
            if WorkspaceNetworkFeature.available, let id = result.remembering.serverID ?? submission.editingServer,
               let saved = snapshot?.visibleServers.first(where: { $0.id == id }),
               WorkspaceConnectionBinding.smb(saved.details) == WorkspaceConnectionBinding.smb(draft) {
                savedConnection = try? .init(kind: .smbServer, serverID: id, binding: WorkspaceConnectionBinding.smb(draft), title: saved.details.name)
            } else { savedConnection = nil }
            func status(_ value: SMBRememberingStatus) -> SMBConnectSavedOutcome.Status {
                switch value { case .notRequested: .notRequested; case .complete: .saved; case .incomplete: .incomplete }
            }
            return SMBConnectSavedOutcome(server: status(result.remembering.server), password: status(result.remembering.password), open: { [self, browser] in
                let owner = SMBTabController(session: result.session, share: submission.address.share,
                    title: submission.name, savedConnection: savedConnection,
                    downloads: SMBDownloadFeature.available ? self.smbDownloads : nil,
                    textReads: RemoteTextViewFeature.smbAvailable ? self.smbDownloads.map(SMBTextReadStorage.init(sharing:)) : nil,
                    presentation: draft, uploads: self.smbUploads, actions: self.smbActions, showUploadHistory: { [weak self] settings, owner in
                        self?.showStorage(settings: settings, owner: owner, forceSMB: true)
                    })
                browser.installSMBTab(owner, reconnect: reconnect, initialComponents: reconnect == nil ? submission.address.components : [])
                if editorEligible && editorReservation == nil {
                    owner.showTransferOutcome("Connected for browsing and transfers. Close another editing connection, then reconnect to enable the editor.", showsUploadHistory: false)
                }
            }, discard: { await ApplicationRemoteTextEditors.shared.discardUnopened(result.session) }, canOpen: {
                !self.shuttingDown && !browser.isBrowserSuspended && browser.view.window != nil
                    && (reconnect?.isCurrent ?? true) && (savedClick?.isCurrent(in: browser) ?? true)
            })
        }
        #if DEBUG
        controller.gateANoFocus = gateANoFocus
        #endif
        controller.model.smbUploadAvailable = SMBUploadFeature.available
        controller.model.onForgetServer = { [weak self, weak controller] id in self?.confirmForget(id, controller: controller) }
        controller.model.onForgetPassword = { [weak self, weak controller] in self?.confirmForgetPassword(controller) }
        controller.model.onStorage = { [weak self, weak controller, weak browser] in
            guard let self, let controller, let browser else { return }
            if controller.model.storageNeedsReview { self.presentEarlierStorageReview(in: browser, reconnect: reconnect) }
            else { self.showStorage(settings: browser.settings, owner: controller.window) }
        }
        return controller
    }
    private static func validateSaved(_ bookmark: WorkspaceConnectionBookmark, draft: SMBServerDraft,
                                      id: UUID?, snapshot: SMBServerSnapshot?) throws {
        guard bookmark.kind == .smbServer, id == bookmark.serverID,
              WorkspaceConnectionBinding.smb(draft) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
        guard let server = snapshot?.visibleServers.first(where: { $0.id == bookmark.serverID }) else {
            throw WorkspaceReconnectFailure.unavailable
        }
        guard WorkspaceConnectionBinding.smb(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
    }
    private func installSFTP(on controller: SMBConnectWindowController, reconnect: WorkspaceReconnectTarget?,
                             savedBookmark: WorkspaceConnectionBookmark? = nil,
                             savedClick: SavedServerClickTarget? = nil) {
        sftp?.install(on: controller, target: { [weak self] in self?.target }, reconnect: reconnect,
            savedBookmark: savedBookmark, savedClick: savedClick, prepare: { [weak self] in
            guard let self, !self.shuttingDown, let browser = self.target else { throw SFTPSessionFailure.stopped }
            _ = try await self.prepareCurrentConnectionWorkspace(in: browser); try Task.checkCancellation()
            guard let storage = self.storage else { throw SFTPSessionFailure.stopped }
            try await self.preparation?.prepare(); try Task.checkCancellation()
            do { try await storage.prepareSharedOriginalStorageForConnect() }
            catch is CancellationError { throw CancellationError() }
            catch { throw SFTPSessionFailure.storage }
            try Task.checkCancellation()
        })
    }
    private func presentEarlierStorageReview(in browser: BrowserViewController, reconnect: WorkspaceReconnectTarget?) {
        guard !shuttingDown, let workspace else { return }
        _ = retainConnectionMetadataWork { [weak self, weak browser, workspace] in
            guard let self, let browser else { return }
            do {
                if let choice = try? await workspace.legacyIdentityChoiceAfterExplicitRequest() {
                    guard !Task.isCancelled, !self.shuttingDown else { return }
                    self.presentLegacyIdentityReview(choice, workspace: workspace, in: browser, reconnect: reconnect)
                    return
                }
                let state = try await workspace.inspect().state
                guard !Task.isCancelled, !self.shuttingDown else { return }
                if state == .activeCompatibilityNeedsReview || state == .interruptedRepairNeedsReview {
                    let choice = try await workspace.repairChoiceAfterExplicitRequest()
                    guard !Task.isCancelled, !self.shuttingDown else { return }
                    self.presentConnectionStorageRepair(choice, workspace: workspace, in: browser, reconnect: reconnect)
                } else { self.presentEarlierMetadataReview(in: browser, reconnect: reconnect) }
            } catch {
                ApplicationDiagnostics.shared.event(.connect, .failed, error: DiagnosticErrors.project(error),
                    context: .init(.connectionWorkspaceReview), causes: DiagnosticErrors.causes(error))
                browser.status.stringValue = "Connection storage needs separate review. Your saved servers and versions are preserved."
                if let parent = self.window?.window, parent.attachedSheet == nil {
                    let alert = NSAlert(); alert.messageText = "Connection storage could not be verified"
                    alert.informativeText = "Existing data has been kept. You can review Saved Versions without connecting, and App Logs includes details for support."
                    alert.addButton(withTitle: "Review Saved Versions…"); alert.addButton(withTitle: "Keep for Later")
                    alert.beginSheetModal(for: parent) { response in
                        if response == .alertFirstButtonReturn { ApplicationRemoteSavedVersions.shared.showSavedVersions(nil) }
                    }
                }
            }
        }
    }
    private func presentLegacyIdentityReview(_ choice: ConnectionWorkspaceRebindChoice, workspace: ConnectionWorkspace,
                                           in browser: BrowserViewController, reconnect: WorkspaceReconnectTarget?) {
        guard !shuttingDown, let parent = window?.window ?? browser.view.window, parent.attachedSheet == nil else { return }
        let controller = window
        let alert = NSAlert()
        alert.messageText = choice.action == .resume ? "Finish restoring connection access?" : "Restore saved connection access?"
        alert.informativeText = "Traverse has checked that your saved connection folders are still in place. Restore access to use them again. Your files, saved servers and local versions stay in place. Unfinished downloads remain kept for review; they are not resumed or marked as saved. This does not connect to a server."
        alert.addButton(withTitle: "Restore Access"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { [weak self, weak browser, weak controller] response in
            guard response == .alertFirstButtonReturn, let self, let browser, !self.shuttingDown else { return }
            controller?.model.managing = true
            let work = self.retainConnectionMetadataWork { [weak self, weak browser, weak controller, workspace, choice] in
                guard let self, let browser else { return }
                defer { if self.window !== controller || self.preparing == nil { controller?.model.managing = false } }
                ApplicationDiagnostics.shared.event(.connect, .committing, count: UInt64(choice.observedObjectCount), context: .init(.connectionWorkspaceReview))
                do {
                    try await workspace.reconcileLegacyIdentity(choice)
                    ApplicationDiagnostics.shared.event(.connect, .completed, context: .init(.connectionWorkspaceReview))
                    guard !Task.isCancelled, !self.shuttingDown, self.window === controller,
                          let controller, controller.window?.isVisible == true else { return }
                    self.startPreparing(controller, in: browser, reconnect: reconnect, savedServer: nil)
                } catch {
                    ApplicationDiagnostics.shared.event(.connect, .failed, error: DiagnosticErrors.project(error),
                        context: .init(.connectionWorkspaceReview), causes: DiagnosticErrors.causes(error))
                    if self.window === controller {
                        controller?.model.showConnectionStorageIssue("Restoring connection access could not be confirmed. Your saved data stays protected. Review again before connecting.")
                    }
                }
            }
            if work == nil {
                controller?.model.managing = false
                controller?.model.showConnectionStorageIssue("Another connection review is finishing. Try Review again when it finishes.")
            }
        }
    }
    private func presentConnectionStorageRepair(_ choice: ConnectionWorkspaceRepairChoice, workspace: ConnectionWorkspace,
                                                in browser: BrowserViewController, reconnect: WorkspaceReconnectTarget?) {
        guard !shuttingDown, let parent = browser.view.window else { return }
        let resume = choice.action == .resume
        let alert = NSAlert()
        alert.messageText = resume ? "Resume connection storage repair?" : "Repair connection storage?"
        alert.informativeText = resume
            ? "A storage repair was interrupted. Resume checks the saved repair and current storage before continuing. Saved versions and connection history stay preserved."
            : "Traverse can restore connection storage after the system removed an empty cache. Saved versions and connection history stay preserved. Close active connections and Saved Versions readers first."
        alert.addButton(withTitle: resume ? "Resume Connection Storage Repair" : "Repair Connection Storage")
        alert.addButton(withTitle: "Keep Existing Data")
        alert.beginSheetModal(for: parent) { [weak self, weak browser, workspace, choice] response in
            guard response == .alertFirstButtonReturn, let self, let browser, !self.shuttingDown else { return }
            _ = self.retainConnectionMetadataWork { [weak self, weak browser, workspace, choice] in
                guard let self, let browser else { return }
                do {
                    try await workspace.repairConnectionStorage(choice)
                    guard !Task.isCancelled, !self.shuttingDown, let parent = browser.view.window else { return }
                    let done = NSAlert(); done.messageText = "Connection storage repaired"
                    done.informativeText = "Saved versions and connection history are preserved. You can retry the connection."
                    done.addButton(withTitle: "Retry Connect"); done.addButton(withTitle: "Done")
                    done.beginSheetModal(for: parent) { [weak self, weak browser] response in
                        guard response == .alertFirstButtonReturn, let self, let browser, !self.shuttingDown else { return }
                        self.present(in: browser, reconnect: reconnect)
                    }
                } catch { browser.status.stringValue = "Storage repair did not finish. Existing data is preserved. Review again to check whether Resume is available." }
            }
        }
    }
    private func presentEarlierMetadataReview(in browser: BrowserViewController, reconnect: WorkspaceReconnectTarget?) {
        guard !shuttingDown, let parent = browser.view.window, let workspace else { return }
        let alert = NSAlert(); alert.messageText = "Review earlier connection storage"
        alert.informativeText = "Traverse preserved the earlier storage. Review can identify recognized inactive connection metadata for explicit removal. Saved versions, download bodies, active or unfamiliar data require retention and cannot be removed here."
        alert.addButton(withTitle: "Review Earlier Metadata"); alert.addButton(withTitle: "Keep Existing Data")
        alert.beginSheetModal(for: parent) { [weak self, weak browser] response in
            guard response == .alertFirstButtonReturn, let self, let browser, !self.shuttingDown else { return }
            _ = self.retainConnectionMetadataWork { [weak self, weak browser, workspace] in
                guard let self, let browser else { return }
                do {
                    let choices = try await workspace.earlierMetadataChoicesAfterExplicitRequest()
                    guard !Task.isCancelled, !self.shuttingDown, !choices.isEmpty, let parent = browser.view.window else {
                        browser.status.stringValue = "Earlier storage is active, unfamiliar, or needs separate review. It was preserved."; return
                    }
                    let confirm = NSAlert(); confirm.messageText = "Discard earlier inactive connection metadata?"
                    confirm.informativeText = "This removes \(choices.count) recognized inactive metadata record(s). Each is checked again before removal. Saved versions, downloaded files and uncertain data stay preserved."
                    confirm.addButton(withTitle: "Discard Metadata and Retry Connect"); confirm.addButton(withTitle: "Keep Existing Data")
                    confirm.beginSheetModal(for: parent) { [weak self, weak browser, workspace, choices] response in
                        guard response == .alertFirstButtonReturn, let self, let browser, !self.shuttingDown else { return }
                        _ = self.retainConnectionMetadataWork { [weak self, weak browser, workspace, choices] in
                            guard let self, let browser else { return }
                            do {
                                for choice in choices { try Task.checkCancellation(); try await workspace.discardEarlierMetadata(choice) }
                                guard !Task.isCancelled, !self.shuttingDown else { return }
                                self.present(in: browser, reconnect: reconnect)
                            } catch { browser.status.stringValue = "Earlier metadata changed or remains in use. Remaining data is preserved for review." }
                        }
                    }
                } catch { browser.status.stringValue = "Earlier connection storage needs separate review. Existing data is preserved." }
            }
        }
    }
    static func choices(_ snapshot: SMBServerSnapshot?) -> [SMBConnectServerChoice] {
        guard let snapshot else { return [] }
        return snapshot.visibleServers.map { server in
            SMBConnectServerChoice(id: server.id, name: server.details.name, address: server.details.address,
                account: server.details.account, domain: server.details.domain, security: server.details.security,
                hasSavedPassword: snapshot.credentials.contains { $0.reference.id == server.credentialID && $0.state == .ready },
                transferPreference: server.details.effectiveTransferPreference)
        }
    }
    private func confirmForget(_ id: UUID, controller: SMBConnectWindowController?) {
        if let controller, controller.model.connectionProtocol == .sftp { sftp?.confirmForget(id, controller: controller); return }
        guard preparing == nil, !shuttingDown, let controller, let parent = controller.window, !controller.model.unavailable, let coordinator else { return }
        let alert = NSAlert(); alert.messageText = "Forget this saved server?"
        alert.informativeText = "This removes saved connection details. Open connections stay open. Saved layouts may keep their own folder names; they cannot reconnect to a forgotten server."
        alert.addButton(withTitle: "Forget Server"); alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Also remove its saved password from Keychain"
        alert.beginSheetModal(for: parent) { [weak self, weak controller] response in
            guard response == .alertFirstButtonReturn, let self, let controller else { return }
            guard !self.shuttingDown, self.preparing == nil, !controller.model.unavailable else { return }
            let remove = alert.suppressionButton?.state == .on
            controller.model.managing = true
            preparing = Task {
                defer { self.preparing = nil; controller.model.managing = false }
                let outcome = await coordinator.forget(.server(id, removePassword: remove))
                let notice = outcome.server == .complete && (outcome.password != .incomplete)
                    ? "Saved server forgotten." : "Forgetting is incomplete. Review Connection Storage; saved data was preserved where necessary."
                let snapshot = try? await coordinator.inspect()
                self.target?.savedServerLocations.refresh()
                controller.model.replaceServers(Self.choices(snapshot), notice: notice)
            }
        }
    }

    /// Sidebar/This Mac use the same exact saved-record and credential cleanup
    /// owners as Connect. Opening this confirmation never connects or reads a password.
    var canManageSavedServers: Bool {
        !shuttingDown && preparing == nil && !savedPreparing && savedConnecting == nil && window?.model.busy != true
    }
    func confirmForgetSavedServer(_ bookmark: WorkspaceConnectionBookmark, in browser: BrowserViewController) {
        guard canManageSavedServers,
              !browser.isBrowserSuspended, let parent = browser.view.window, parent.isVisible,
              parent.attachedSheet == nil, browser.savedServerLocations.snapshot.locations.contains(bookmark) else { return }
        let diagnostics = ApplicationDiagnostics.shared, trace = ApplicationDiagnostics.shared.begin(.forget)
        diagnostics.event(.forget, .presenting, trace: trace, context: .init(.savedServerForget))
        let alert = NSAlert()
        alert.messageText = "Forget “\(bookmark.title)”?"
        alert.informativeText = "Remove its saved connection details from Traverse. Open connections stay open. Saved layouts and folder pins may keep their names, but cannot reconnect using these forgotten details."
        alert.addButton(withTitle: "Forget Server"); alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also remove its saved password from Keychain"
        alert.beginSheetModal(for: parent) { [weak self, weak browser] response in
            guard response == .alertFirstButtonReturn else {
                diagnostics.event(.forget, .cancelled, trace: trace, context: .init(.savedServerForget)); return
            }
            guard let self, let browser,
                  self.canManageSavedServers, !browser.isBrowserSuspended,
                  browser.savedServerLocations.snapshot.locations.contains(bookmark) else {
                diagnostics.event(.forget, .blocked, trace: trace, context: .init(.savedServerForget)); return
            }
            let removePasswords = alert.suppressionButton?.state == .on
            self.preparing = Task { [self, browser] in
                defer { preparing = nil }
                do {
                    diagnostics.event(.forget, .preparing, trace: trace, context: .init(.savedServerForget))
                    try Task.checkCancellation()
                    guard !shuttingDown else { return }
                    guard let root = profileRoot else { throw SMBBrowserFailure.storage }
                    let complete: Bool
                    let failure: DiagnosticErrorCode?
                    switch bookmark.kind {
                    case .smbServer:
                        let remembered = SMBServerRemembering(store: .init(directory: root.appendingPathComponent("smb-servers")), vault: passwords)
                        guard let server = try await remembered.inspect()?.visibleServers.first(where: { $0.id == bookmark.serverID }),
                              WorkspaceConnectionBinding.smb(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
                        let outcome = await remembered.forget(server: server, removePassword: removePasswords)
                        complete = outcome.server == .complete && outcome.password != .incomplete
                        failure = outcome.storeFailure.map { DiagnosticErrors.project($0) } ?? outcome.passwordFailure.map { DiagnosticErrors.project($0) }
                    case .sftpServer:
                        let remembered = sftp?.remembered ?? SFTPRememberedState(settings: .init(directory: root.appendingPathComponent("sftp-servers")), passwords: sftpPasswords)
                        guard let server = try await remembered.inspect()?.visibleServers.first(where: { $0.id == bookmark.serverID }),
                              WorkspaceConnectionBinding.sftp(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
                        let outcome = await remembered.forget(server: server, removePassword: removePasswords)
                        complete = outcome.server == .complete && outcome.password != .incomplete
                        failure = outcome.settingsFailure.map { DiagnosticErrors.project($0) } ?? outcome.passwordFailure.map { DiagnosticErrors.project($0) }
                    case .sftpRoute:
                        let remembered = sftp?.remembered ?? SFTPRememberedState(settings: .init(directory: root.appendingPathComponent("sftp-servers")), passwords: sftpPasswords)
                        guard let route = try await remembered.inspect()?.visibleRoutes.first(where: { $0.id == bookmark.serverID }),
                              WorkspaceConnectionBinding.route(route.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
                        let outcome = await remembered.forget(route: route, removePasswords: removePasswords)
                        complete = outcome.server == .complete && outcome.password != .incomplete
                        failure = outcome.settingsFailure.map { DiagnosticErrors.project($0) } ?? outcome.passwordFailure.map { DiagnosticErrors.project($0) }
                    }
                    browser.savedServerLocations.refresh()
                    browser.status.stringValue = complete ? "Saved server forgotten. Open connections remain available."
                        : "Some saved details need review. Open Connection Activity; retained data is protected."
                    diagnostics.event(.forget, complete ? .completed : .partial, trace: trace,
                        error: failure, context: .init(.savedServerForget))
                } catch {
                    browser.status.stringValue = "Saved details changed or could not be removed. Refresh the server list and try again."
                    diagnostics.event(.forget, Task.isCancelled ? .cancelled : .failed, trace: trace,
                        error: DiagnosticErrors.project(error), context: .init(.savedServerForget))
                }
            }
        }
    }
    private func confirmForgetPassword(_ controller: SMBConnectWindowController?) {
        if let controller, controller.model.connectionProtocol == .sftp { sftp?.confirmForgetPassword(controller); return }
        guard preparing == nil, !shuttingDown, let controller, let parent = controller.window, !controller.model.unavailable, let coordinator,
              let address = try? SMBConnectionAddress(controller.model.address),
              let draft = try? SMBServerDraft(name: "Connection", address: address, account: controller.model.account,
                domain: controller.model.domain, security: controller.model.security) else { return }
        let alert = NSAlert(); alert.messageText = "Forget the saved password for these details?"
        alert.informativeText = "This removes this app’s saved password for the displayed server, share, account and domain. Open connections remain open."
        alert.addButton(withTitle: "Forget Password"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { [weak self, weak controller] response in
            guard response == .alertFirstButtonReturn, let self, let controller else { return }
            guard !self.shuttingDown, self.preparing == nil, !controller.model.unavailable else { return }
            controller.model.managing = true
            preparing = Task {
                defer { self.preparing = nil; controller.model.managing = false }
                let outcome = await coordinator.forgetPasswords(for: draft)
                let snapshot = try? await coordinator.inspect()
                controller.model.replaceServers(Self.choices(snapshot), notice: outcome.password == .complete
                    ? "Saved password forgotten." : "Password removal is incomplete. Review Connection Storage.")
            }
        }
    }
    /// Explicit offline review shares the normal owners without presenting a
    /// Connect form, submitting authentication or reading a saved password.
    func presentActivity(in browser: BrowserViewController, isSFTP: Bool) {
        guard !shuttingDown, !browser.isBrowserSuspended, !browser.operationCoordinator.drives.isBusy,
              !isSFTP || sftpEnabled else { return }
        guard preparing == nil, !savedPreparing, savedConnecting == nil, window?.model.busy != true else {
            browser.status.stringValue = "Connection setup is finishing. Open activity when it completes."
            return
        }
        let trace = ApplicationDiagnostics.shared.begin(.recovery)
        generation = UUID(); let token = generation
        let previousStatus = browser.status.stringValue
        let pendingStatus = "Opening connection activity…"
        browser.status.stringValue = pendingStatus
        preparing = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            defer {
                if generation == token { preparing = nil }
                if browser.status.stringValue == pendingStatus { browser.status.stringValue = previousStatus }
            }
            do {
                try await prepareConnectionServices(in: browser, reviewOnly: true)
                try Task.checkCancellation()
                guard !shuttingDown, generation == token, !browser.isBrowserSuspended,
                      browser.view.window != nil else { return }
                // The synchronous presentation follows completed preparation;
                // its controller retains its own read-only inspection work.
                preparing = nil
                if isSFTP { sftp?.showStorage(settings: browser.settings, owner: browser.view.window) }
                else { showStorage(settings: browser.settings, owner: browser.view.window, forceSMB: true) }
                ApplicationDiagnostics.shared.event(.recovery, .presenting, trace: trace,
                    context: .init(.connectionWorkspaceReview))
            } catch {
                guard !Task.isCancelled, !shuttingDown, generation == token else { return }
                browser.status.stringValue = "Connection activity needs attention. Open Connect to Server to review access."
                ApplicationDiagnostics.shared.event(.recovery, .failed, trace: trace,
                    error: DiagnosticErrors.project(error), context: .init(.connectionWorkspaceReview))
            }
        }
    }
    private func showStorage(settings: BrowserSettings, owner: NSWindow?, forceSMB: Bool = false) {
        if !forceSMB, window?.model.connectionProtocol == .sftp { sftp?.showStorage(settings: settings, owner: owner); return }
        guard !shuttingDown, preparing == nil, let coordinator, let storage else { return }
        if let storageWindow { storageWindow.present(relativeTo: owner); return }
        let controller = SMBConnectionStorageWindow(settings: settings, coordinator: coordinator, storage: storage,
            downloads: smbDownloads, uploads: smbUploads, actions: smbActions)
        storageWindow = controller; controller.present(relativeTo: owner)
    }
    /// D5 UI dependency: the SAME inert profile owner is available at startup,
    /// even when no connection window/editor has ever been opened.
    @discardableResult func installPersistentSavedVersionsLoader() -> Bool {
        guard let workspace else { return false }
        return ApplicationRemoteSavedVersions.shared.install(loader: .init(
            load: { [workspace] in try await workspace.recoveryChoicesAfterExplicitRequest() },
            listing: { [workspace] in try await workspace.recoveryListingAfterExplicitRequest() },
            documents: { [workspace] in try await workspace.retainedDocumentsAfterExplicitRequest() },
            removeDocument: { [workspace] choice in try await workspace.removeRetainedDocument(choice) },
            smbLoad: { [workspace] in try await workspace.smbRecoveryChoicesAfterExplicitRequest() },
            stopAndDrain: { [workspace] in await workspace.stopAndDrain() }))
    }
    func closeAndDrain() async {
        shuttingDown = true; generation = UUID()
        let completion = savedFinish
        savedGeneration = UUID(); let saved = savedConnecting; saved?.cancel()
        savedProgress = nil; savedCompletion = nil
        let metadata = Array(metadataTasks.values); metadata.forEach { $0.cancel() }
        for task in metadata { await task.value }
        await RemoteConnectionPinsRegistry.flushAll()
        let pending = preparing; pending?.cancel()
        window?.model.cancel()
        // Cancel a host review before awaiting the parent Connect task, which
        // is intentionally suspended until that actual review finishes.
        _ = await sftp?.closeAndDrain()
        await window?.model.cancelAndDrain(); await pending?.value; await saved?.value; preparing = nil; savedConnecting = nil
        completion?.finish(false); if savedFinish === completion { savedFinish = nil }
        await storageWindow?.closeAndDrain(); storageWindow = nil
        await coordinator?.drain(); _ = await smbUploads?.close()
        if await smbActions?.close() == false {
            ApplicationDiagnostics.shared.event(.fileOperation, .interrupted,
                error: .init(domain: .network, code: 1506), context: .init(.queueTerminal))
        }
        await workspace?.stopAndDrain(); window?.close(); window = nil
    }
    func resumeAfterCancelledTermination() { shuttingDown = false; sftp?.resume(); SFTPWorkerSession.resumeAdmissions() }
    #if DEBUG
    var verificationWindow: SMBConnectWindowController? { window }
    var verificationSFTPTrust: SFTPTrustWindowController? { sftp?.verificationTrust }
    var verificationSFTPInteractive: SFTPInteractiveWindowController? { sftp?.verificationInteractive }
    var verificationSFTPStorage: SFTPConnectionStorageWindow? { sftp?.verificationStorage }
    var verificationSFTPRemembered: SFTPRememberedState? { sftp?.remembered }
    var verificationCertificateConnectionPending: Bool {
        preparing != nil || savedConnecting != nil || window?.model.busy == true
    }
    #elseif TRAVERSE_SFTP_EDITOR_QA
    /// Read-only access to the ordinary Connect owner for the exact counted
    /// selection visit. No alternate transport, storage or credential adapter.
    var verificationWindow: SMBConnectWindowController? {
        GeneratedSandboxReview.publicSelectionDownloadAdmitted || GeneratedSandboxReview.certificateConnectionAdmitted ? window : nil
    }
    var verificationSFTPTrust: SFTPTrustWindowController? {
        GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted || GeneratedSandboxReview.certificateConnectionAdmitted ? sftp?.verificationTrust : nil
    }
    var verificationSFTPInteractive: SFTPInteractiveWindowController? {
        GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted ? sftp?.verificationInteractive : nil
    }
    var verificationSFTPRemembered: SFTPRememberedState? {
        GeneratedSandboxReview.certificateConnectionAdmitted ? sftp?.remembered : nil
    }
    var verificationCertificateConnectionPending: Bool {
        GeneratedSandboxReview.certificateConnectionAdmitted
            && (preparing != nil || savedConnecting != nil || window?.model.busy == true)
    }
    #endif
}

@MainActor extension BrowserViewController {
    @objc func showSMBConnections(_ sender: Any?) {
        guard SMBConnectionFeature.ordinaryEnabled, !isBrowserSuspended else { return }
        connectionService.present(in: self)
    }
}
