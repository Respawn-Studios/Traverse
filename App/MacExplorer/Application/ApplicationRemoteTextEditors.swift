import AppKit
import Combine
import FileOperations
@_spi(Qualification) import LocalStorage

/// Direct normal-transfer editing passed signed sandbox and independent-server
/// Save/conflict/disconnect/cold-recovery acceptance. Routed editing uses the
/// same product policy as routed browsing and uploads at connection admission.
/// This does not publish or install a build.
/// No Info.plist or environment switch alone can enable remote editing.
@MainActor enum RemoteTextEditorFeature {
    static let ordinaryEnabled = true
    #if DEBUG
    static var qualifying = false
    static var qualifyingSMB = false
    #endif
    static var smbAvailable: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.smbOriginalSaveReviewAdmitted
        #elseif DEBUG
        qualifyingSMB || AppFeatureAvailability.allows(.smbOriginalTextEditing)
        #else
        AppFeatureAvailability.allows(.smbOriginalTextEditing)
        #endif
    }
    /// Signed v3 acceptance covers independent editor baselines across browsing,
    /// changed-source refusal and offline retained versions. QA routes stay exact.
    static var smbOriginalSaveV3Available: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.smbOriginalSaveV3Admitted
        #else
        AppFeatureAvailability.allows(.smbOriginalTextEditing)
        #endif
    }
    static var available: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        // A separately compiled ordinary Release app exercises the real UI in
        // its own sandbox. Neither shipping builds nor another QA identity can
        // activate this lane by changing preferences or process environment.
        return GeneratedSandboxReview.admitted && !GeneratedSandboxReview.publicationOnlyReviewAdmitted
        #elseif DEBUG
        return qualifying || ordinaryEnabled
        #else
        return ordinaryEnabled
        #endif
    }
    static var routedAvailable: Bool {
        available && AppFeatureAvailability.allows(.routedEditor)
    }
}

@MainActor final class ApplicationRemoteTextEditors {
    static let shared = ApplicationRemoteTextEditors()
    private struct Registration { let session: SFTPBrowserSession; let storage: SFTPInPlaceWorkingCopyStorage }
    private struct SMBRegistration { let session: SMBBrowserSession; let storage: SMBInPlaceWorkingCopyStorage }
    private struct SelectionKey: Hashable { let connection: UUID, generation: UUID, observation: UInt64 }
    private struct Entry {
        let selection: SelectionKey
        let document: RemoteTextDocumentController
        let observation: AnyCancellable
    }
    private var registrations: [UUID: Registration] = [:]
    private var smbRegistrations: [UUID: SMBRegistration] = [:]
    private var pendingConnectionReservations = Set<UUID>()
    private var documents: [UUID: Entry] = [:]
    private var opening: [UUID: (selection: SelectionKey, task: Task<Void, Never>)] = [:]
    private var failedOpenDrain: [UUID: (connection: UUID, document: RemoteEditableTextBackend)] = [:]
    private var unopenedDrains: [UUID: SFTPBrowserSession] = [:]
    private var unopenedSMBDrains: [UUID: SMBBrowserSession] = [:]
    private var fencedConnections = Set<UUID>()
    private var preparingDisconnect = Set<UUID>()
    private var directoryMutation: UUID?
    private var reviewingTermination = false, terminationPrepared = false
    var reservationCount: Int { documents.count + opening.count + failedOpenDrain.count }
    var allTextReservationCount: Int { reservationCount + ApplicationRemoteSavedVersions.shared.reservationCount + ApplicationRemoteTextViews.shared.reservationCount }
    var hasManagedDocuments: Bool { reservationCount != 0 || !unopenedDrains.isEmpty || !unopenedSMBDrains.isEmpty
        || ApplicationRemoteSavedVersions.shared.hasManagedWork || ApplicationRemoteTextViews.shared.hasManagedWork }
    func permitsSnapshotRead(on connection: UUID) -> Bool {
        !reviewingTermination && !terminationPrepared && directoryMutation == nil
            && !fencedConnections.contains(connection) && !preparingDisconnect.contains(connection)
    }
    /// Folder Rename and file Move have no universal cross-session path identity. Hold one
    /// small App admission fence while it prepares/drains, rather than guessing
    /// whether another connection's pending editor refers to the same subtree.
    var canBeginDirectoryMutation: Bool {
        directoryMutation == nil && reservationCount == 0 && unopenedDrains.isEmpty && unopenedSMBDrains.isEmpty
            && !reviewingTermination && !terminationPrepared
    }
    func beginDirectoryMutation() -> UUID? {
        guard canBeginDirectoryMutation else { return nil }
        let token = UUID(); directoryMutation = token; return token
    }
    func finishDirectoryMutation(_ token: UUID) {
        if directoryMutation == token { directoryMutation = nil }
    }
    /// Reserve editor admission before Connect suspends. A full editor pool must
    /// leave the next connection free to browse and transfer without editing.
    func reservePreparedConnection() -> UUID? {
        reservePreparedConnection(available: RemoteTextEditorFeature.available)
    }
    func reserveSMBPreparedConnection() -> UUID? {
        reservePreparedConnection(available: RemoteTextEditorFeature.smbAvailable)
    }
    private func reservePreparedConnection(available: Bool) -> UUID? {
        guard available, !reviewingTermination, !terminationPrepared,
              registrations.count + smbRegistrations.count + pendingConnectionReservations.count < 2 else { return nil }
        let reservation = UUID()
        pendingConnectionReservations.insert(reservation)
        return reservation
    }
    func releasePreparedConnection(_ reservation: UUID?) {
        if let reservation { pendingConnectionReservations.remove(reservation) }
    }
    /// Registration follows authentication and uses the exact connection's
    /// admitted working-copy storage. It cannot upgrade a transfer-only peer.
    func registerPrepared(session: SFTPBrowserSession, storage: SFTPInPlaceWorkingCopyStorage,
                          reservation: UUID?) throws {
        let hasCapacity = reservation.map { pendingConnectionReservations.contains($0) }
            ?? (registrations.count + smbRegistrations.count + pendingConnectionReservations.count < 2)
        guard RemoteTextEditorFeature.available, session.allowsInPlaceEditing,
              session.latest.failure == nil, !reviewingTermination, !terminationPrepared,
              !fencedConnections.contains(session.id), !preparingDisconnect.contains(session.id),
              hasCapacity, registrations.count + smbRegistrations.count < 2,
              registrations[session.id] == nil, smbRegistrations[session.id] == nil else { throw SFTPTextFailure.unsupported }
        registrations[session.id] = .init(session: session, storage: storage)
        releasePreparedConnection(reservation)
    }
    func registerPrepared(session: SMBBrowserSession, storage: SMBInPlaceWorkingCopyStorage,
                          reservation: UUID?) throws {
        let hasCapacity = reservation.map { pendingConnectionReservations.contains($0) }
            ?? (registrations.count + smbRegistrations.count + pendingConnectionReservations.count < 2)
        guard RemoteTextEditorFeature.smbAvailable, session.allowsInPlaceTextEdit, session.latest.failure == nil,
              !reviewingTermination, !terminationPrepared, !fencedConnections.contains(session.id),
              !preparingDisconnect.contains(session.id), hasCapacity,
              registrations.count + smbRegistrations.count < 2,
              registrations[session.id] == nil, smbRegistrations[session.id] == nil else { throw SMBBrowserFailure.unavailable }
        smbRegistrations[session.id] = .init(session: session, storage: storage)
        releasePreparedConnection(reservation)
    }
    /// The Connect form can discard an authenticated session before any tab
    /// owns it. The existing lifetime owner keeps uncertain closes for Quit.
    func discardUnopened(_ session: SFTPBrowserSession) async -> Bool {
        let firstAttempt = unopenedDrains[session.id] == nil
        unopenedDrains[session.id] = session
        connectionWillClose(session.id)
        if firstAttempt { SFTPBrowserLifetimes.shared.register(session) }
        let actual = await SFTPBrowserLifetimes.shared.close(session).value
        connectionDidDrain(session.id, actual: actual)
        return actual.localResourcesEnded
    }
    func discardUnopened(_ session: SMBBrowserSession) async -> Bool {
        let firstAttempt = unopenedSMBDrains[session.id] == nil
        unopenedSMBDrains[session.id] = session
        connectionWillClose(session.id)
        if firstAttempt { SMBBrowserLifetimes.shared.register(session) }
        let actual = await SMBBrowserLifetimes.shared.close(session).value
        connectionDidDrain(session.id, actual: actual)
        return actual.ownerReleased
    }
    #if DEBUG
    /// Only an already-capable generated session can be registered. This neither
    /// mints an opaque permit nor creates/reconfigures a connection or store.
    func registerGenerated(session: SFTPBrowserSession, storage: SFTPInPlaceWorkingCopyStorage) throws {
        guard RemoteTextEditorFeature.qualifying else { throw SFTPTextFailure.unsupported }
        try registerPrepared(session: session, storage: storage, reservation: nil)
    }
    func registerGenerated(session: SMBBrowserSession, storage: SMBInPlaceWorkingCopyStorage) throws {
        guard RemoteTextEditorFeature.qualifyingSMB else { throw SMBBrowserFailure.unavailable }
        try registerPrepared(session: session, storage: storage, reservation: nil)
    }
    var documentsForVerification: [RemoteTextDocumentController] { documents.values.map(\.document) }
    var registeredConnectionCountForVerification: Int { registrations.count + smbRegistrations.count }
    func failedOpenCountForVerification(_ connection: UUID) -> Int {
        failedOpenDrain.values.filter { $0.connection == connection }.count
    }
    /// Qualification may register only a REAL incomplete close outcome. It
    /// cannot manufacture a drained report or remove another owner's charge.
    func retainFailedOpenAfterActualCloseForVerification(_ document: SFTPInPlaceDocumentSession,
        connection: UUID) async throws {
        guard RemoteTextEditorFeature.qualifying, !reviewingTermination, !terminationPrepared,
              allTextReservationCount + ApplicationLocalTextEditors.shared.documentReservationCount < 4,
              failedOpenCountForVerification(connection) < 2 else { throw SFTPTextFailure.busy }
        let ticket = UUID()
        // Reserve before suspension and keep the exact real session even if
        // qualification setup fails. Quit/Disconnect use normal retry logic.
        failedOpenDrain[ticket] = (connection, .sftp(document))
        switch await document.closeAfterExplicitBufferDecision() {
        case .readyToCloseBuffer, .pending, .needsReview: break
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            failedOpenDrain.removeValue(forKey: ticket); throw SFTPTextFailure.changed
        }
    }
    #endif
    func canOpen(from browser: BrowserViewController) -> Bool {
        guard !reviewingTermination, !terminationPrepared, directoryMutation == nil,
              !browser.isBrowserSuspended, browser.hasFileCommandFocus,
              browser.view.window?.attachedSheet == nil, !(browser.view.window?.firstResponder is NSTextView),
              browser.recoverableFileOperations != nil else { return false }
        if browser.isSMBLocation {
            guard RemoteTextEditorFeature.smbAvailable, let owner = browser.smbTabs[browser.activeID], !owner.isClosing,
                  !fencedConnections.contains(owner.connectionID), smbRegistrations[owner.connectionID]?.session === owner.session,
                  owner.session.allowsInPlaceTextEdit, owner.sealedEditorSelection != nil else { return false }
            return true
        }
        guard RemoteTextEditorFeature.available,
              let owner = browser.sftpTabs[browser.activeID], !owner.isClosing,
              !fencedConnections.contains(owner.connectionID), registrations[owner.connectionID]?.session === owner.session,
              owner.session.allowsInPlaceEditing, owner.sealedEditorSelection != nil,
              browser.recoverableFileOperations != nil else { return false }
        return true
    }
    func open(from browser: BrowserViewController, visible: Bool = true, allowsReadOnlyFallback: Bool = false) {
        if browser.isSMBLocation { openSMB(from: browser, visible: visible); return }
        guard canOpen(from: browser), let owner = browser.sftpTabs[browser.activeID],
              let selection = owner.sealedEditorSelection, let registration = registrations[owner.connectionID],
              let interactions = ApplicationLocalTextEditors.shared.remoteInteractions(from: browser) else { return }
        let key = SelectionKey(connection: owner.connectionID, generation: selection.generation, observation: selection.row.observation)
        if let existing = documents.values.first(where: { $0.selection == key }) {
            existing.document.show(visible: visible); return
        }
        guard !opening.values.contains(where: { $0.selection == key }) else { return }
        let connectionCount = documents.values.filter { $0.selection.connection == key.connection }.count
            + opening.values.filter { $0.selection.connection == key.connection }.count
            + failedOpenDrain.values.filter { $0.connection == key.connection }.count
        guard connectionCount < 2 else {
            browser.status.stringValue = "Close another text editor on this SFTP connection. Two captured remote documents can be open per connection."; return
        }
        guard allTextReservationCount + ApplicationLocalTextEditors.shared.documentReservationCount < 4 else {
            browser.status.stringValue = "Close another editor. Up to four local and remote text documents can be open."; return
        }
        // Strongly capture exact session/storage/selection now. Navigation after
        // the explicit command does not redirect a body read or later Save.
        let ticket = UUID(), settings = browser.settings
        let locationContext: EditorLocationContext?
        if case .sftp(let location) = owner.currentBrowserLocation,
           let directory = owner.navigationDirectory(location) {
            let path = (directory.root == .home ? "~/" : "/")
                + (directory.components + [selection.row.entry.name]).map(\.displayName).joined(separator: "/")
            locationContext = .remote(server: owner.root.displayHint, path: path)
        } else { locationContext = nil }
        ApplicationDiagnostics.shared.event(.fileOperation, .requested, trace: ticket, context: .init(.remoteEditorOpen))
        let task = Task { [self, owner, registration] in
            var readOnlyFallback = false
            defer {
                opening.removeValue(forKey: ticket)
                if readOnlyFallback, !Task.isCancelled, !owner.isClosing,
                   browser.sftpTabs[browser.activeID] === owner, owner.sealedEditorSelection == selection {
                    ApplicationRemoteTextViews.shared.open(from: browser, visible: visible)
                }
            }
            var inspection: UUID?
            var opened: SFTPInPlaceDocumentSession?
            do {
                guard let token = ApplicationOperationCoordinator.shared.beginInspection() else { throw FileOperationFailure.unavailable }
                inspection = token
                ApplicationDiagnostics.shared.event(.fileOperation, .reading, trace: ticket, context: .init(.remoteEditorOpen))
                let remote = try await registration.session.openInPlaceText(selection, storage: registration.storage)
                opened = remote
                guard !Task.isCancelled, !reviewingTermination, !terminationPrepared,
                      !fencedConnections.contains(owner.connectionID), !owner.isClosing else { throw CancellationError() }
                let value = await remote.initialContents
                guard !Task.isCancelled, !reviewingTermination, !terminationPrepared,
                      !fencedConnections.contains(owner.connectionID), !owner.isClosing else { throw CancellationError() }
                ApplicationDiagnostics.shared.event(.fileOperation, .preparing, trace: ticket,
                    context: .init(.remoteEditorOpen))
                installDocument(backend: .sftp(remote), contents: value, key: key,
                    displayName: selection.row.entry.name.displayName, location: locationContext,
                    interactions: interactions, settings: settings, trace: ticket, visible: visible) { [weak owner] in
                    guard let owner, !owner.isClosing, case .sftp(let location) = owner.currentBrowserLocation else { return }
                    owner.refreshAfterUpload(at: location)
                }
            } catch {
                ApplicationDiagnostics.shared.event(.fileOperation, error is CancellationError ? .cancelled : .failed,
                    trace: ticket, error: DiagnosticErrors.project(error), context: .init(.remoteEditorOpen),
                    causes: DiagnosticErrors.causes(error))
                // No visible buffer was installed. Explicit cancelled open can
                // close its unused document; incomplete close remains retained.
                if let opened {
                    switch await opened.closeAfterExplicitBufferDecision() {
                    case .readyToCloseBuffer, .pending, .needsReview: failedOpenDrain[ticket] = (owner.connectionID, .sftp(opened))
                    case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained: break
                    }
                }
                if let refusal = error as? SFTPInPlaceEditRefusal {
                    readOnlyFallback = allowsReadOnlyFallback && refusal.reason == .syncUnavailable
                        && !refusal.localCleanupNeedsReview && owner.textReads != nil
                        && ApplicationRemoteTextViews.shared.canOpen(from: browser)
                    let reason: String
                    switch refusal.reason {
                    case .syncUnavailable: reason = "This server does not support the sync required for editing."
                    case .readWriteDenied: reason = "The server denied write access to this file."
                    }
                    browser.status.stringValue = reason + (refusal.localCleanupNeedsReview
                        ? " Local preparation needs review and remains protected. Browsing stays available."
                        : " Browsing and other open editors stay available. The file was not opened for editing.")
                } else {
                    browser.status.stringValue = owner.session.latest.failure == nil
                        ? "This file could not be opened for editing. The server file was not edited."
                        : "Connection stopped while opening this file. Disconnect, then connect again."
                    browser.status.toolTip = "The server file was not edited. Details are recorded in App Logs; retained local copies stay protected."
                }
            }
            if let inspection { ApplicationOperationCoordinator.shared.finishInspection(inspection) }
        }
        opening[ticket] = (key, task)
    }
    /// Both protocols use one native document, preference observer and close
    /// reservation. Concrete browser/session owners retain their own authority.
    private func installDocument(backend: RemoteEditableTextBackend, contents: TextDocumentValue,
        key: SelectionKey, displayName: String, location: EditorLocationContext?,
        interactions: RemoteEditorInteractions, settings: BrowserSettings, trace: UUID, visible: Bool,
        refreshAfterLastClose: @escaping @MainActor () -> Void) {
        let document = RemoteTextDocumentController(backend: backend, contents: contents, connectionID: key.connection,
            displayName: displayName, locationContext: location, interactions: interactions, installChrome: { native in
                native.isRestorable = false; ToolWindowChrome.install(in: native, settings: settings)
            })
        document.window.bindKeyboardBehavior(to: settings)
        let observation = settings.$editorPreferences.removeDuplicates().sink { [weak document] value in
            document?.applyPreferences(value, pointSize: CGFloat(value.basePointSize) * InterfaceMetrics.scale)
            if let document { InterfaceMetrics.setFont(document.window.surface.textView,
                base: .monospacedSystemFont(ofSize: CGFloat(value.basePointSize), weight: .regular)) }
        }
        documents[document.id] = .init(selection: key, document: document, observation: observation)
        let documentID = document.id, protocolKind = backend.protocolKind
        document.manageSavedVersions = { ApplicationRemoteSavedVersions.shared.showSavedVersions(nil) }
        document.observedSaveBoundary = { generation, boundary in
            let event = DiagnosticErrors.remoteEditorSave(boundary, protocolKind: protocolKind)
            ApplicationDiagnostics.shared.event(.fileOperation, event.phase, trace: generation,
                error: event.error, context: .init(.remoteEditorSave), relatedTrace: documentID)
        }
        document.didClose = { [weak self] id in
            guard let self else { return }; documents.removeValue(forKey: id)
            guard !documents.values.contains(where: { $0.selection.connection == key.connection }),
                  !opening.values.contains(where: { $0.selection.connection == key.connection }) else { return }
            refreshAfterLastClose()
        }
        InterfacePresentation.shared.register(document.window.surface); document.show(visible: visible)
        ApplicationDiagnostics.shared.event(.fileOperation, .completed, trace: trace,
            context: .init(.remoteEditorOpen), relatedTrace: documentID)
    }
    private func openSMB(from browser: BrowserViewController, visible: Bool) {
        guard canOpen(from: browser), let owner = browser.smbTabs[browser.activeID],
              let selection = owner.sealedEditorSelection, let registration = smbRegistrations[owner.connectionID],
              let interactions = ApplicationLocalTextEditors.shared.remoteInteractions(from: browser) else { return }
        let key = SelectionKey(connection: owner.connectionID, generation: selection.snapshot.readID,
            observation: UInt64(selection.observation.id))
        if let existing = documents.values.first(where: { $0.selection == key }) { existing.document.show(visible: visible); return }
        guard !opening.values.contains(where: { $0.selection == key }) else { return }
        let count = documents.values.filter { $0.selection.connection == key.connection }.count
            + opening.values.filter { $0.selection.connection == key.connection }.count
            + failedOpenDrain.values.filter { $0.connection == key.connection }.count
        guard count < 2, allTextReservationCount + ApplicationLocalTextEditors.shared.documentReservationCount < 4 else {
            browser.status.stringValue = "Close another editor before opening this file. Up to two documents per connection and four text windows can be open."
            return
        }
        let context: EditorLocationContext?
        if case .smb(let location) = owner.currentBrowserLocation, let directory = owner.navigationComponents(location) {
            context = .remote(server: owner.root.displayHint,
                path: "/" + (directory + [selection.observation.name]).map(\.displayName).joined(separator: "/"))
        } else { context = nil }
        let ticket = UUID(), settings = browser.settings
        ApplicationDiagnostics.shared.event(.fileOperation, .requested, trace: ticket, context: .init(.remoteEditorOpen))
        let task = Task { [self, owner, registration] in
            var inspection: UUID?, opened: SMBInPlaceDocumentSession?
            defer {
                opening.removeValue(forKey: ticket)
                if let inspection { ApplicationOperationCoordinator.shared.finishInspection(inspection) }
            }
            do {
                guard let token = ApplicationOperationCoordinator.shared.beginInspection() else { throw FileOperationFailure.unavailable }
                inspection = token
                ApplicationDiagnostics.shared.event(.fileOperation, .reading, trace: ticket, context: .init(.remoteEditorOpen))
                let remote = try await registration.session.openInPlaceText(selected: selection, storage: registration.storage)
                opened = remote
                guard !Task.isCancelled, !reviewingTermination, !terminationPrepared,
                      !fencedConnections.contains(owner.connectionID), !owner.isClosing else { throw CancellationError() }
                let value = await remote.initialContents
                guard !Task.isCancelled, !reviewingTermination, !terminationPrepared,
                      !fencedConnections.contains(owner.connectionID), !owner.isClosing else { throw CancellationError() }
                ApplicationDiagnostics.shared.event(.fileOperation, .preparing, trace: ticket, context: .init(.remoteEditorOpen))
                installDocument(backend: .smb(remote), contents: value, key: key,
                    displayName: selection.observation.name.displayName, location: context,
                    interactions: interactions, settings: settings, trace: ticket, visible: visible) { [weak owner] in
                    guard let owner, !owner.isClosing else { return }; owner.refreshAfterUpload()
                }
            } catch {
                ApplicationDiagnostics.shared.event(.fileOperation, error is CancellationError ? .cancelled : .failed,
                    trace: ticket, error: DiagnosticErrors.project(error), context: .init(.remoteEditorOpen),
                    causes: DiagnosticErrors.causes(error))
                if let opened {
                    switch await opened.closeAfterExplicitBufferDecision() {
                    case .readyToCloseBuffer, .pending, .needsReview: failedOpenDrain[ticket] = (owner.connectionID, .smb(opened))
                    case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained: break
                    }
                }
                browser.status.stringValue = owner.session.latest.failure == nil
                    ? "This file could not be opened for editing. Its server contents were not edited."
                    : "Connection stopped while opening this file. Existing local versions stay protected."
            }
        }
        opening[ticket] = (key, task)
    }
    /// All callers, including forced tab teardown, fence admission immediately.
    func connectionWillClose(_ connection: UUID) {
        fencedConnections.insert(connection)
        ApplicationRemoteTextViews.shared.connectionWillClose(connection)
        for value in opening.values where value.selection.connection == connection { value.task.cancel() }
        for entry in documents.values where entry.document.connectionID == connection { entry.document.connectionWillClose() }
    }
    func prepareForDisconnect(_ owner: SFTPTabController) async -> Bool {
        await prepareForDisconnect(connection: owner.connectionID,
            isTerminal: { owner.session.latest.failure != nil || owner.isClosing })
    }
    func prepareForDisconnect(_ owner: SMBTabController) async -> Bool {
        await prepareForDisconnect(connection: owner.connectionID,
            isTerminal: { owner.session.latest.failure != nil || owner.isClosing })
    }
    private func prepareForDisconnect(connection: UUID, isTerminal: () -> Bool) async -> Bool {
        // A failed worker already fenced new Edit admission. It must still be
        // possible to drain that exact connection while its local text windows
        // stay owned for review. A separate reservation blocks duplicate UI
        // Disconnect tasks without confusing this terminal fence with one.
        let terminal = isTerminal()
        guard !preparingDisconnect.contains(connection),
              !fencedConnections.contains(connection) || terminal else { return false }
        preparingDisconnect.insert(connection)
        defer { preparingDisconnect.remove(connection) }
        let hadFence = fencedConnections.contains(connection)
        fencedConnections.insert(connection)
        await ApplicationRemoteTextViews.shared.cancelPendingReadsAndDrain(on: connection)
        func restoreHealthyFence() {
            if !hadFence && !isTerminal() {
                fencedConnections.remove(connection)
            }
        }
        let pending = opening.values.filter { $0.selection.connection == connection }.map(\.task)
        pending.forEach { $0.cancel() }; for task in pending { await task.value }
        // Forced teardown and fatal transport failure use the existing local
        // recovery ownership. They do not demand a second remote body read or
        // discard a visible buffer before closing the failed worker.
        if isTerminal() { return true }
        for entry in Array(documents.values) where entry.document.connectionID == connection {
            let closed = await entry.document.closeForTermination()
            if isTerminal() { return true }
            guard closed else { restoreHealthyFence(); return false }
        }
        // Only this concrete connection participates in its Disconnect. Other
        // connections retain their real failed-open holders independently.
        for (id, held) in Array(failedOpenDrain) where held.connection == connection {
            let result = await held.document.closeAfterExplicitBufferDecision()
            if isTerminal() { return true }
            switch result {
            case .readyToCloseBuffer, .pending, .needsReview: restoreHealthyFence(); return false
            case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
                failedOpenDrain.removeValue(forKey: id)
            }
        }
        guard !failedOpenDrain.values.contains(where: { $0.connection == connection }) else {
            restoreHealthyFence(); return false
        }
        return true
    }
    func prepareForTermination() async -> Bool {
        guard !reviewingTermination, !terminationPrepared else { return terminationPrepared }
        reviewingTermination = true; defer { reviewingTermination = false }
        guard await ApplicationRemoteTextViews.shared.prepareForTermination(),
              await ApplicationRemoteSavedVersions.shared.prepareForTermination() else { return false }
        let pending = opening.values.map(\.task); pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        for (id, held) in failedOpenDrain {
            switch await held.document.closeAfterExplicitBufferDecision() {
            case .readyToCloseBuffer, .pending, .needsReview: return false
            case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained: failedOpenDrain.removeValue(forKey: id)
            }
        }
        for session in Array(unopenedDrains.values) {
            guard await discardUnopened(session) else { return false }
        }
        for session in Array(unopenedSMBDrains.values) {
            guard await discardUnopened(session) else { return false }
        }
        for entry in Array(documents.values) { guard await entry.document.closeForTermination() else { return false } }
        let ready = !hasManagedDocuments
        if ready { terminationPrepared = true }
        return ready
    }
    func resumeAfterCancelledTermination() {
        terminationPrepared = false
        ApplicationRemoteTextViews.shared.resumeAfterCancelledTermination()
        ApplicationRemoteSavedVersions.shared.resumeAfterCancelledTermination()
    }
    func connectionDidDrain(_ connection: UUID, actual: SFTPWorkerClose) {
        connectionDidDrain(connection, ended: actual.localResourcesEnded)
    }
    func connectionDidDrain(_ connection: UUID, actual: SMBBrowserDrainResult) {
        connectionDidDrain(connection, ended: actual.ownerReleased)
    }
    private func connectionDidDrain(_ connection: UUID, ended: Bool) {
        guard ended else { return }
        // Displayed windows retain their own immutable document/recovery owner.
        // Registration removal cannot delete a displayed or retained version.
        registrations.removeValue(forKey: connection); smbRegistrations.removeValue(forKey: connection)
        unopenedDrains.removeValue(forKey: connection); unopenedSMBDrains.removeValue(forKey: connection)
        fencedConnections.remove(connection)
    }
}
