import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

enum SFTPConnectionFeature {
    static var ordinaryEnabled: Bool {
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") != nil { return false }
        #endif
        return true
    }
}

/// Concrete SFTP half of the shared Connect window. Its root is registered by
/// the parent profile before initialization; the remote catalog pool is shared.
@MainActor final class ApplicationSFTPConnections {
    let remembered: SFTPRememberedState
    private var coordinator: SFTPConnectionCoordinator
    private let trust = SFTPSetupTrust()
    private let prompts = SFTPSetupInteractive()
    private var storage: SMBTemporaryStorage
    private let downloads: SFTPDownloadStorage
    private let uploads: SFTPUploadStorage
    private let newText: SFTPTextEditStorage
    private let remoteActions: SFTPRemoteActionStore
    private let root: URL
    private var storageWindow: SFTPConnectionStorageWindow?
    private var management: Task<Void, Never>?
    private var shuttingDown = false
    private(set) var deferredHostReview: SFTPHostChallenge.Kind?
    init(root: URL, storage: SMBTemporaryStorage, downloads: SFTPDownloadStorage, uploads: SFTPUploadStorage, passwords: SFTPPasswordVault) throws {
        self.storage = storage; self.root = root
        self.downloads = downloads
        self.uploads = uploads
        newText = try SFTPTextEditStorage(directory: root.appendingPathComponent("sftp-new-text-sources", isDirectory: true))
        remoteActions = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let state = SFTPRememberedState(settings: .init(directory: root.appendingPathComponent("sftp-servers")), passwords: passwords)
        remembered = state
        coordinator = Self.makeCoordinator(storage: storage, remembered: state)
    }
    private static func makeCoordinator(storage: SMBTemporaryStorage, remembered: SFTPRememberedState) -> SFTPConnectionCoordinator {
        .init(bundleURL: Bundle.main.bundleURL, storage: storage, remembered: remembered,
            activity: ApplicationSMBActivity.gate, requestedDownloads: SFTPDownloadFeature.available,
            requestedFolderDownloads: SFTPFolderDownloadFeature.available,
            requestedTextReads: RemoteTextViewFeature.available)
    }
    /// Only after a committed, explicit workspace upgrade. Keep the remembered
    /// servers and vault; retire the old metadata consumers before replacing
    /// their exact witness. No live connection is moved to another authority.
    func adoptMetadataStorage(_ updated: SMBTemporaryStorage) async {
        let pending = management; pending?.cancel(); await pending?.value
        await storageWindow?.closeAndDrain(); storageWindow = nil
        await coordinator.drain()
        storage = updated; coordinator = Self.makeCoordinator(storage: updated, remembered: remembered)
    }
    func install(on controller: SMBConnectWindowController, target: @escaping @MainActor () -> BrowserViewController?,
                 reconnect: WorkspaceReconnectTarget? = nil,
                 savedBookmark: WorkspaceConnectionBookmark? = nil,
                 savedClick: SavedServerClickTarget? = nil,
                 prepare: @escaping @MainActor () async throws -> Void) {
        controller.window?.setContentSize(.init(width: 600, height: 580))
        controller.model.freshUploadAvailable = SFTPUploadFeature.available
        controller.model.sftpHandler = { [weak self, weak controller] submission, phase in
            guard let self, let controller, let browser = target(), !shuttingDown, !browser.isBrowserSuspended,
                  browser.view.window != nil, !browser.operationCoordinator.drives.isBusy else { throw SFTPSessionFailure.stopped }
            guard savedClick?.isCurrent(in: browser) ?? true else { throw WorkspaceReconnectFailure.stale }
            deferredHostReview = nil
            phase("Preparing encrypted SFTP connection…"); try await prepare(); try Task.checkCancellation()
            guard savedClick?.isCurrent(in: browser) ?? true else { throw WorkspaceReconnectFailure.stale }
            if let reconnect { try reconnect.validate(submission, snapshot: try await remembered.inspect()) }
            if let savedBookmark { try Self.validateSaved(savedBookmark, submission: submission,
                snapshot: try await remembered.inspect()) }
            let editorEligible = canRequestEditor(for: submission)
            let editorReservation = editorEligible
                ? ApplicationRemoteTextEditors.shared.reservePreparedConnection() : nil
            defer { ApplicationRemoteTextEditors.shared.releasePreparedConnection(editorReservation) }
            let editorCandidate = editorReservation != nil
            try prompts.beginConnection()
            let result: SFTPConnectionOutcome
            do {
            if let route = submission.route {
                guard let jumpAuthentication = submission.jumpAuthentication,
                      !submission.freshFolderUploads || SFTPRoutedFolderUploadFeature.available && SFTPFolderUploadFeature.available,
                      !submission.freshUploads || SFTPRoutedUploadFeature.available && SFTPUploadFeature.available else { throw SFTPSessionFailure.input }
                result = try await coordinator.connectRoute(route, jumpAuthentication: jumpAuthentication,
                    destinationAuthentication: submission.authentication ?? .password(submission.password),
                    savedRouteID: submission.editingRoute, remember: submission.rememberServer,
                    rememberJumpPassword: submission.rememberJumpPassword, rememberDestinationPassword: submission.rememberPassword,
                    configuration: submission.configuration, profileAlias: submission.profileAlias,
                    serverPrompts: { @MainActor [weak self, weak controller] _, session, challenge in
                        guard let self, let controller else { return nil }
                        return await prompts.review(session, challenge: challenge, settings: browser.settings,
                            owner: controller.window?.isVisible == true ? controller.window : browser.view.window)
                    }, review: { @MainActor [weak self, weak controller] role, session in
                        guard let self, let controller else { return false }
                        if role == .destination, !(await prompts.dismissAuthenticated()) { return false }
                        let outcome = await trust.reviewSavedRoute(session, role: role, route: route,
                            routeID: submission.editingRoute, remembered: remembered,
                            allowsInteractiveReview: controller.window?.isVisible == true,
                            settings: browser.settings,
                            owner: controller.window?.isVisible == true ? controller.window : browser.view.window)
                        if !outcome.verified, controller.window?.isVisible != true, !Task.isCancelled {
                            deferredHostReview = session.review.kind
                        }
                        return outcome.verified
                    }, downloads: SFTPRoutedDownloadFeature.available && SFTPFolderDownloadFeature.available,
                    textReads: RemoteTextViewFeature.available,
                    freshUploads: submission.freshUploads, freshFolderUploads: submission.freshFolderUploads,
                    remoteActions: SFTPRemoteActionFeature.routedAvailable && submission.freshUploads,
                    guardedInPlaceEditing: editorCandidate)
            } else {
            result = try await coordinator.connect(submission.draft, authentication: submission.authentication ?? .password(submission.password),
                savedServerID: submission.editingServer, rememberServer: submission.rememberServer, rememberPassword: submission.rememberPassword,
                freshUploads: SFTPUploadFeature.available && submission.freshUploads,
                freshFolderUploads: SFTPFolderUploadFeature.available && submission.freshUploads && submission.freshFolderUploads,
                profileFeatures: SFTPProfileFeature.available,
                configuration: submission.configuration, profileAlias: submission.profileAlias,
                serverPrompts: { @MainActor [weak self,weak controller] session,challenge in
                    guard let self,let controller else { return nil }
                    return await prompts.review(session,challenge:challenge,settings:browser.settings,
                        owner: controller.window?.isVisible == true ? controller.window : browser.view.window)
                },
                remoteActions: SFTPRemoteActionFeature.available && submission.freshUploads, guardedInPlaceEditing: editorCandidate,
                review: { @MainActor [weak self, weak controller] session, state in
                    guard let self, let controller else { return .init(verified: false) }
                    let outcome = await trust.review(session, remembered: state, address: submission.draft.address,
                        rememberServer: submission.rememberServer,
                        allowsInteractiveReview: controller.window?.isVisible == true,
                        settings: browser.settings,
                        owner: controller.window?.isVisible == true ? controller.window : browser.view.window)
                    if !outcome.verified, controller.window?.isVisible != true, !Task.isCancelled {
                        deferredHostReview = session.review.kind
                    }
                    return outcome
                })
            }
            guard await prompts.dismissAuthenticated() else {
                let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                if !ended { throw WorkspaceReconnectFailure.closureUncertain }
                throw SFTPSessionFailure.stopped
            }
            } catch { _ = await prompts.closeAndDrain(); throw error }
            guard result.session.allowsInPlaceEditing == editorCandidate else {
                let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                if !ended { throw WorkspaceReconnectFailure.closureUncertain }
                throw SFTPSessionFailure.input
            }
            if editorCandidate {
                do {
                    try Task.checkCancellation()
                    // The same admitted ConnectionWorkspace metadata storage
                    // backs both browsing and editor recovery. Constructor I/O
                    // stays off MainActor and precedes the Connect open closure.
                    let metadataStorage = storage
                    let preparation = Task.detached(priority: .utility) {
                        try SFTPInPlaceWorkingCopyStorage(metadataStorage: metadataStorage)
                    }
                    let workingCopy = try await withTaskCancellationHandler {
                        try await preparation.value
                    } onCancel: { preparation.cancel() }
                    try Task.checkCancellation()
                    try ApplicationRemoteTextEditors.shared.registerPrepared(session: result.session, storage: workingCopy,
                        reservation: editorReservation)
                } catch {
                    let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                    if !ended { throw WorkspaceReconnectFailure.closureUncertain }
                    throw error
                }
            }
            let preferenceRequest = SFTPConnectionPreferenceSave.Request(draft: submission.draft, route: submission.route,
                defaultDirectory: submission.defaultDirectory, transferPreference: submission.transferPreference,
                rememberServer: submission.rememberServer, editingServer: submission.editingServer, editingRoute: submission.editingRoute)
            let preferences = await SFTPConnectionPreferenceSave.persist(preferenceRequest,
                serverID: result.remembering.serverID, routeID: result.remembering.routeID,
                state: remembered, snapshot: try? await remembered.inspect())
            let snapshot = preferences.snapshot
            browser.savedServerLocations.refresh()
            if let reconnect {
                do { try reconnect.validate(submission, snapshot: snapshot) }
                catch {
                    let ended = await ApplicationRemoteTextEditors.shared.discardUnopened(result.session)
                    if !ended { throw WorkspaceReconnectFailure.closureUncertain }; throw error
                }
            }
            if let savedBookmark {
                do { try Self.validateSaved(savedBookmark, submission: submission, snapshot: snapshot) }
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
            if WorkspaceNetworkFeature.available, let id = result.remembering.routeID ?? submission.editingRoute,
               let route = submission.route, let saved = snapshot?.visibleRoutes.first(where: { $0.id == id }),
               WorkspaceConnectionBinding.route(saved.details) == WorkspaceConnectionBinding.route(route) {
                savedConnection = try? .init(kind: .sftpRoute, serverID: id, binding: WorkspaceConnectionBinding.route(route),
                    title: saved.details.destination.name,
                    relativeToHome: submission.defaultDirectory.map { $0.root == .home } ?? (route.destination.address.components == nil))
            } else if WorkspaceNetworkFeature.available, submission.route == nil,
               let id = result.remembering.serverID ?? submission.editingServer,
               let saved = snapshot?.visibleServers.first(where: { $0.id == id }),
               WorkspaceConnectionBinding.sftp(saved.details) == WorkspaceConnectionBinding.sftp(submission.draft) {
                savedConnection = try? .init(kind: .sftpServer, serverID: id, binding: WorkspaceConnectionBinding.sftp(submission.draft),
                    title: saved.details.name,
                    relativeToHome: submission.defaultDirectory.map { $0.root == .home } ?? (submission.draft.address.components == nil))
            } else { savedConnection = nil }
            func status(_ value: SFTPRememberingStatus) -> SMBConnectSavedOutcome.Status {
                switch value { case .notRequested: .notRequested; case .complete: .saved; case .incomplete: .incomplete }
            }
            return .init(server: preferences.confirmed ? status(result.remembering.server) : .incomplete, password: status(result.remembering.password), host: status(result.remembering.host), keyAccess: status(result.remembering.keyAccess), open: { [self, browser] in
                browser.installSFTPTab(.init(session: result.session, address: submission.draft.address, title: submission.draft.name,
                    downloads: SFTPDownloadFeature.available ? self.downloads : nil, uploads: result.session.allowsFreshUploads ? self.uploads : nil,
                    remoteActions: self.remoteActions,
                    textReads: RemoteTextViewFeature.available ? SFTPTextReadStorage(sharing: self.downloads) : nil,
                    newTextStorage: self.newText,
                    reviewsUploads: submission.reviewsUploads,
                    showUploadHistory: { [weak self] settings, owner in self?.showStorage(settings: settings, owner: owner) },
                    savedConnection: savedConnection, routeLabel: submission.route.map { "via " + $0.jump.address.host },
                    defaultDirectory: submission.defaultDirectory, presentation: submission.draft, routeDescription: submission.route,
                    signIn: submission.authentication?.metadataSignIn ?? .password,
                    requiresUserCertificate: submission.authentication?.metadataRequiresCertificate ?? false,
                    transferPreference: submission.transferPreference,
                    editorCapacityLimited: editorEligible && !editorCandidate), reconnect: reconnect)
            }, discard: { await ApplicationRemoteTextEditors.shared.discardUnopened(result.session) }, canOpen: {
                !self.shuttingDown && !browser.isBrowserSuspended && browser.view.window != nil
                    && (reconnect?.isCurrent ?? true) && (savedClick?.isCurrent(in: browser) ?? true)
            })
        }
    }
    private static func validateSaved(_ bookmark: WorkspaceConnectionBookmark,
                                      submission: SFTPConnectSubmission, snapshot: SFTPSettingsSnapshot?) throws {
        switch bookmark.kind {
        case .smbServer: throw WorkspaceReconnectFailure.changed
        case .sftpServer:
            guard submission.route == nil, submission.editingServer == bookmark.serverID,
                  WorkspaceConnectionBinding.sftp(submission.draft) == bookmark.binding else {
                throw WorkspaceReconnectFailure.changed
            }
            guard let server = snapshot?.visibleServers.first(where: { $0.id == bookmark.serverID }) else {
                throw WorkspaceReconnectFailure.unavailable
            }
            guard WorkspaceConnectionBinding.sftp(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
        case .sftpRoute:
            guard let route = submission.route, submission.editingRoute == bookmark.serverID,
                  WorkspaceConnectionBinding.route(route) == bookmark.binding else {
                throw WorkspaceReconnectFailure.changed
            }
            guard let saved = snapshot?.visibleRoutes.first(where: { $0.id == bookmark.serverID }) else {
                throw WorkspaceReconnectFailure.unavailable
            }
            guard WorkspaceConnectionBinding.route(saved.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
        }
    }
    private func canRequestEditor(for submission: SFTPConnectSubmission) -> Bool {
        guard RemoteTextEditorFeature.available, submission.route == nil || RemoteTextEditorFeature.routedAvailable,
              submission.transferPreference == .normal,
              !submission.reviewsUploads, submission.freshUploads,
              SFTPUploadFeature.available, SFTPProfileFeature.available else { return false }
        return true
    }
    func refresh(_ model: SMBConnectModel) async {
        SavedServerLocations.refreshExisting(directory: root)
        do {
            let snapshot = try await remembered.inspect()
            guard !Task.isCancelled, !shuttingDown else { return }
            model.replaceSFTPServers(SFTPConnectSavedChoices.values(snapshot))
        } catch {
            guard !Task.isCancelled, !shuttingDown else { return }
            model.replaceSFTPServers([], notice: "Saved SFTP trust/details need review. Open Connection Storage; they have not been reset or recovered automatically.")
        }
    }
    func confirmForget(_ id: UUID, controller: SMBConnectWindowController) {
        if controller.model.sftpServers.first(where: { $0.id == id })?.route != nil {
            confirm("Forget this saved jump connection?", detail: "This removes the route, its verified identities and remembered key-file access. Open connections stay open. Saved layouts may keep their own folder names; they cannot reconnect to this forgotten connection.",
                button: "Forget Connection", controller: controller, passwordChoice: true) { [self] remove in
                    await remembered.forget(.route(id, removePasswords: remove))
                }
            return
        }
        confirm("Forget this saved SFTP server?", detail: "This removes connection details and remembered key-file access. The verified key and open connections stay. Saved layouts may keep their own folder names; they cannot reconnect to this forgotten server.",
            button: "Forget Server", controller: controller, passwordChoice: true) { [self] remove in
                await remembered.forget(.server(id, removePassword: remove))
            }
    }
    func confirmForgetPassword(_ controller: SMBConnectWindowController) {
        guard let address = try? SFTPConnectionAddress(controller.model.address),
              let request = try? SFTPConnectionRequest(address: address, account: controller.model.account) else { return }
        confirm("Forget saved SFTP passwords for these details?", detail: "This removes this app’s saved passwords for the exact host, port and account, across its recorded server keys. Open connections stay open.",
            button: "Forget Password", controller: controller) { [self] _ in await remembered.forgetPasswords(for: request) }
    }
    private func confirm(_ title: String, detail: String, button: String, controller: SMBConnectWindowController,
                         passwordChoice: Bool = false, action: @escaping @MainActor (Bool) async -> SFTPRememberingOutcome) {
        guard !shuttingDown, management == nil, !controller.model.unavailable, let parent = controller.window else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = passwordChoice; alert.suppressionButton?.title = "Also remove this connection’s saved passwords from Keychain"
        alert.beginSheetModal(for: parent) { [weak self, weak controller] response in
            guard response == .alertFirstButtonReturn, let self, let controller, !self.shuttingDown,
                  self.management == nil, !controller.model.unavailable else { return }
            controller.model.managing = true
            self.management = Task {
                defer { self.management = nil; controller.model.managing = false }
                let outcome = await action(alert.suppressionButton?.state == .on)
                await self.refresh(controller.model)
                controller.model.replaceSFTPServers(controller.model.sftpServers, notice:
                    outcome.server != .incomplete && outcome.password != .incomplete ? "Selected saved details forgotten."
                    : "Forgetting is incomplete. Review Connection Storage; exact cleanup records remain available.")
            }
        }
    }
    func showStorage(settings: BrowserSettings, owner: NSWindow?) {
        guard !shuttingDown, management == nil else { return }
        if let storageWindow { storageWindow.present(relativeTo: owner); return }
        let window = SFTPConnectionStorageWindow(settings: settings, remembered: remembered, storage: storage, downloads: downloads,
            uploads: uploads, remoteActions: remoteActions)
        storageWindow = window; window.present(relativeTo: owner)
    }
    func closeAndDrain() async -> Bool {
        shuttingDown = true; let pending = management; pending?.cancel()
        let ended = await trust.closeAndDrain(); let promptsEnded = await prompts.closeAndDrain(); await pending?.value
        await storageWindow?.closeAndDrain(); storageWindow = nil
        await coordinator.drain(); let uploadWriterEnded = await uploads.close(), actionWriterEnded = await remoteActions.close()
        return ended && promptsEnded && uploadWriterEnded && actionWriterEnded
    }
    func resume() { shuttingDown = false }
    #if DEBUG
    var verificationTrust: SFTPTrustWindowController? { trust.controller }
    var verificationInteractive: SFTPInteractiveWindowController? { prompts.controller }
    var verificationStorage: SFTPConnectionStorageWindow? { storageWindow }
    #elseif TRAVERSE_SFTP_EDITOR_QA
    var verificationTrust: SFTPTrustWindowController? {
        GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted || GeneratedSandboxReview.certificateConnectionAdmitted ? trust.controller : nil
    }
    var verificationInteractive: SFTPInteractiveWindowController? {
        GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted ? prompts.controller : nil
    }
    #endif
}
