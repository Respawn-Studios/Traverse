import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// This owner moves with its tab. Reattaching the same controller reparents its
/// view and retains the connection, generation and bounded native page cache.
@MainActor final class SMBTabController {
    let session: SMBBrowserSession
    let connectedAt = Date()
    let rows = SMBRemoteRowsView(frame: .zero)
    let downloads: SMBDownloadStorage?
    let textReads: SMBTextReadStorage?
    let uploads: SMBUploadStorage?
    let remoteActions: SMBActionStorage?
    let showUploadHistory: RemoteUploadHistoryAction?
    private(set) var operationNotice: ConnectionOperationNotice?
    var uploadNotice: String? {
        get { operationNotice?.message }
        set { operationNotice = newValue.map { .init(message: $0, needsAttention: false) } }
    }
    func showTransferOutcome(_ text: String, needsAttention: Bool = false, showsUploadHistory: Bool = true) {
        operationNotice = text.isEmpty ? nil : .init(message: text, needsAttention: needsAttention, showsUploadHistory: showsUploadHistory)
        if isVisible { browser?.renderCurrentSMBStatus() }
    }
    func clearTransferOutcome() { operationNotice = nil }
    var reviewsUploads: Bool { presentation?.effectiveTransferPreference == .cautious }
    private(set) var references: SMBDirectoryReferences
    private weak var browser: BrowserViewController?
    private var desired: SMBBrowserLocation?, admitted: SMBBrowserLocation?, readID: UUID?
    private var timedRead: (id: UUID, began: ContinuousClock.Instant)?
    private(set) var lastDirectoryListingMilliseconds: Double?
    private(set) var lastDirectoryListingAt: Date?
    private var diagnosticRead: (read: UUID, trace: UUID)?, lastDiagnosticRead: UUID?
    private var lastFolderUploadDiagnostic: SMBFolderUploadDiagnostic?
    private var navigationTask: Task<Void, Never>?, pageTask: Task<Void, Never>?, updatesTask: Task<Void, Never>?
    private var sourceObservation: RemoteSourceObservationLease?
    private var sourceRestoration: Task<Void, Never>?
    private var pageDemand = SMBDirectoryPageDemand(), sort: SMBDirectorySort = .name, descending = false, closed = false
    private let connectionTitle: String?
    private(set) var savedConnection: WorkspaceConnectionBookmark?
    let presentation: SMBServerDraft?
    func adoptSavedTarget(_ target: WorkspaceConnectionBookmark) {
        guard !closed, !target.isSFTP else { return }; savedConnection = target
    }
    private var closing: Task<SMBBrowserDrainResult, Never>?
    var hasPendingPages: Bool { pageTask != nil || pageDemand.hasQueued }
    private(set) var drain: SMBBrowserDrainResult?
    var connectionID: UUID { session.id }
    var root: SMBBrowserLocation {
        let value = references.root
        return .init(connectionID: value.connectionID, directoryID: value.directoryID,
            displayHint: connectionTitle.map { "\($0) · \(value.displayHint)" } ?? value.displayHint)
    }
    var isClosing: Bool { closed }
    var loadedNameQuery: String { rows.findQuery }
    func setLoadedNameQuery(_ value: String) {
        guard !rows.findQuery.utf8.elementsEqual(value.utf8) else { return }
        // Retire demand bookkeeping, not the active connection RPC.
        pageDemand.clear(); rows.setFindQuery(value)
        browser?.inlineRename.selectionDidChange()
        if isVisible { browser?.renderSMBStatus(session.latest) }
    }
    func navigationComponents(_ value: SMBBrowserLocation) -> [SMBRemoteName]? {
        guard !closed else { return nil }; return references.resolve(value)
    }
    var currentBrowserLocation: BrowserLocation { .smb(desired ?? root) }
    var sealedFileAction: (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName], row: SMBDirectoryObservation)? {
        guard sourceObservation == nil, !closed, isVisible, desired == admitted, !hasPendingPages, remoteActions != nil,
              session.allowsSelectedActions, session.latest.idle, session.latest.failure == nil,
              session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete, snapshot.readID == readID,
              snapshot == session.latest.snapshot, let desired, let components = references.resolve(desired),
              let row = rows.selectedObservation else { return nil }
        return (snapshot, components, row)
    }
    /// Move admission is independent of Upload storage and works in an empty
    /// destination. This is current metadata, never a selection or access grant.
    var clipboardDestination: (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName])? {
        guard sourceObservation == nil, !closed, isVisible, desired == admitted, !hasPendingPages,
              remoteActions != nil, session.allowsSelectedActions, session.latest.idle,
              session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete, snapshot.readID == readID,
              snapshot == session.latest.snapshot, let desired, let components = references.resolve(desired) else { return nil }
        return (snapshot, components)
    }
    func captureClipboardSource(_ operation: TransferClipboardFeedback.Intent) -> SMBClipboardSource? {
        guard let browser, !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand,
              browser.hasFileCommandFocus, browser.view.window?.attachedSheet == nil,
              let captured = sealedFileAction,
              !captured.row.isDirectory || SMBRemoteActionFeature.directoriesAvailable,
              !captured.row.isReparsePoint,
              captured.row.attributes & 0x450 == (captured.row.isDirectory ? 0x10 : 0),
              let object = captured.row.objectID, object > 0, object != UInt64.max,
              let parent = captured.row.parentID, parent > 0, parent != UInt64.max, parent != object else { return nil }
        if operation == .copy {
            let probe = captured.row.name.displayName.caseInsensitiveCompare("Copy") == .orderedSame ? "Copy 2" : "Copy"
            guard SMBRemoteActionFeature.copiesAvailable, !captured.row.isDirectory,
                  (try? SMBSelectedActionRequest(connection: connectionID, snapshot: captured.snapshot,
                    directory: captured.components, observation: captured.row,
                    copyTo: captured.components, as: probe)) != nil else { return nil }
        } else if !RemoteClipboardFeature.movesAvailable || !SMBRemoteActionFeature.movesAvailable { return nil }
        return .init(owner: self, directory: captured.components, row: captured.row)
    }

    func reobserveClipboardSource(_ source: SMBClipboardSource, preparation: UUID,
        operation: TransferClipboardFeedback.Intent = .move,
        current: @MainActor () -> Bool) async throws -> (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName], row: SMBDirectoryObservation) {
        guard source.belongs(to: self),
              (operation == .copy ? SMBRemoteActionFeature.copiesAvailable && !source.row.isDirectory : SMBRemoteActionFeature.movesAvailable),
              !source.row.isDirectory || SMBRemoteActionFeature.directoriesAvailable,
              remoteActions != nil, session.allowsSelectedActions, sourceObservation == nil,
              sourceRestoration == nil, navigationTask == nil, !hasPendingPages,
              session.latest.idle, session.latest.failure == nil, let browser,
              browser.operationCoordinator.preparationOwner == preparation, current(), !closed else {
            throw RemoteSourceObservationFailure.stale
        }
        let lease = RemoteSourceObservationLease(preparation: preparation)
        sourceObservation = lease
        lease.armDeadline { [weak self, weak lease] in
            guard let self, let lease, self.sourceObservation === lease, lease.started, !self.closed else { return }
            self.session.stopReading()
        }
        defer { lease.finishWaiting() }
        func check() throws {
            try lease.check()
            guard sourceObservation === lease, self.browser === browser, !closed,
                  navigationTask == nil, !hasPendingPages,
                  browser.operationCoordinator.preparationOwner == preparation, current() else {
                throw RemoteSourceObservationFailure.stale
            }
            guard session.latest.failure == nil else { throw RemoteSourceObservationFailure.unavailable }
        }
        do {
            try check(); lease.started = true
            let read = try await session.navigate(components: source.directory)
            try check()
            var snapshot: SMBDirectorySnapshot
            while true {
                try check()
                let update = session.latest
                guard update.directoryRejection == nil else { throw RemoteSourceObservationFailure.unavailable }
                if let value = update.snapshot, value.readID == read {
                    if value.state == .complete, update.idle { snapshot = value; break }
                    guard value.state == .loading || value.state == .complete else { throw RemoteSourceObservationFailure.incomplete }
                }
                try await Task.sleep(for: .milliseconds(25)); try check()
            }
            var offset: Int64 = 0
            for _ in 0..<RemoteSourceObservationLease.maximumPages where offset < snapshot.count {
                try check()
                let page = try await session.page(offset: offset, sort: .name, descending: false)
                try check()
                guard page.request.snapshot == snapshot, page.request.offset == offset,
                      session.latest.snapshot == snapshot, session.latest.idle,
                      !page.entries.isEmpty, page.entries.count <= 256,
                      Int64(page.entries.count) <= snapshot.count - offset else { throw RemoteSourceObservationFailure.stale }
                // UNIQUE(read,wire) is enforced by the existing catalog. The
                // local row ordinal is intentionally not treated as identity.
                if let row = page.entries.first(where: { $0.name == source.row.name }) {
                    guard source.matches(row) else { throw RemoteSourceObservationFailure.changed }
                    try check()
                    return (snapshot, source.directory, row)
                }
                offset += Int64(page.entries.count)
            }
            throw offset < snapshot.count ? RemoteSourceObservationFailure.incomplete : .changed
        } catch {
            if sourceObservation === lease, lease.started, !closed {
                lease.stopRequested = true; session.stopReading()
            }
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= lease.deadline { throw RemoteSourceObservationFailure.deadline }
            throw error as? RemoteSourceObservationFailure ?? .unavailable
        }
    }

    /// The action owner invokes this in finally. Do not restore a captured path
    /// over a newer choice or let the hidden source read publish into the table.
    func restoreAfterClipboardSourceObservation() {
        guard let lease = sourceObservation, sourceRestoration == nil else { return }
        lease.finishWaiting()
        admitted = nil; readID = nil; timedRead = nil; pageDemand.clear()
        sourceRestoration = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if sourceObservation === lease { sourceObservation = nil }; sourceRestoration = nil }
            while !closed, sourceObservation === lease {
                let update = session.latest
                let available = browser?.operationCoordinator.activeOwner == nil && browser?.operationCoordinator.preparationOwner == nil
                if (update.idle || update.failure != nil) && available {
                    sourceObservation = nil
                    guard isVisible, let browser, let desired else { return }
                    if update.failure != nil {
                        rows.disconnected("The connection is unavailable. Reconnect explicitly to try again.")
                        browser.renderSMBStatus(update)
                        return
                    }
                    attach(to: browser, location: desired, refresh: true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
    }
    var selectedDownload: SMBDownloadSelection? {
        guard session.allowsSelectedDownloads, downloads != nil else { return nil }
        return selectedBodyObservation
    }
    var selectedTextRead: SMBDownloadSelection? {
        guard session.allowsTextRead, textReads != nil, let value = selectedBodyObservation,
              value.logicalBytes <= UInt64(TextDocumentValue.maximumBytes) else { return nil }
        return value
    }
    var sealedEditorSelection: SMBDownloadSelection? {
        guard session.allowsInPlaceTextEdit, let value = selectedBodyObservation,
              value.logicalBytes <= UInt64(TextDocumentValue.maximumBytes) else { return nil }
        return value
    }
    private var selectedBodyObservation: SMBDownloadSelection? {
        guard sourceObservation == nil, !closed, isVisible, desired == admitted, !hasPendingPages,
              session.latest.idle, session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete, snapshot.readID == readID,
              snapshot == session.latest.snapshot, let observation = rows.selectedObservation else { return nil }
        return try? .init(connection: session.id, snapshot: snapshot, observation: observation)
    }
    var uploadDestination: (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName])? {
        guard !closed, isVisible, desired == admitted, !hasPendingPages,
              session.allowsSelectedUploads || session.allowsFolderUploads, uploads != nil, session.latest.idle,
              session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete,
              snapshot.readID == readID, snapshot == session.latest.snapshot,
              let desired, let path = references.resolve(desired) else { return nil }
        return (snapshot, path)
    }
    func hasObservedUploadName(_ name: String, in snapshot: SMBDirectorySnapshot,
                               directory: [SMBRemoteName]) -> Bool {
        guard let current = uploadDestination, current.snapshot == snapshot,
              current.components == directory, let name = try? SMBRemoteName(name) else { return false }
        return rows.hasLoadedName(name, in: snapshot)
    }
    var uploadDestinationDescription: String {
        let folder = desired?.displayHint ?? root.displayHint
        return [presentation?.name, folder].compactMap { $0 }.joined(separator: " › ")
    }
    func refreshAfterUpload() {
        guard !closed, let browser, let desired else { return }
        attach(to: browser, location: desired, refresh: true)
    }
    func moveDestinationSuggestions(excluding current: [SMBRemoteName]) -> [RemoteMoveDestinationModel.Suggestion] {
        references.recentPaths().filter { $0 != current && !$0.isEmpty }.compactMap { path in
            guard let destination = try? SMBMoveDestination(components: path) else { return nil }
            return .init(title: destination.path, path: destination.path)
        }
    }
    func invalidateMovedDescendants(directory: [SMBRemoteName], name: SMBRemoteName) {
        references.invalidateDescendants(of: directory + [name])
    }
    var selectedFolderDownload: SMBFolderDownloadSelection? {
        guard session.latest.idle else { return nil }; return folderSelectionIncludingPreparation
    }
    var sealedBatchDownload: SMBDownloadBatchPlan? {
        guard !closed, isVisible, desired == admitted, !hasPendingPages,
              session.allowsSelectedDownloads, downloads != nil, session.latest.idle,
              session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete,
              snapshot.readID == readID, snapshot == session.latest.snapshot else { return nil }
        return rows.selectedDownloadBatch(connection: session.id)
    }
    var folderSelectionIncludingPreparation: SMBFolderDownloadSelection? {
        guard !closed, isVisible, desired == admitted, !hasPendingPages, session.allowsFolderDownloads, downloads != nil,
              session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete, snapshot.readID == readID,
              snapshot == session.latest.snapshot, let observation = rows.selectedObservation else { return nil }
        return try? .init(connection: session.id, snapshot: snapshot, observation: observation)
    }
    var selectedItemObservation: RemoteItemObservation? {
        guard !closed, isVisible, desired == admitted, let admitted,
              let snapshot = rows.cache.snapshot, snapshot.readID == readID, snapshot == session.latest.snapshot,
              session.latest.failure == nil || session.latest.failure == .stopped,
              let row = rows.selectedObservation, let path = references.resolve(admitted),
              let share = try? SMBRemoteName(references.root.displayHint) else { return nil }
        return try? .init(smb:row,directory:path,share:share,listingComplete:snapshot.state == .complete)
    }
    var folderSizeAction: RemoteFolderSizeAction? {
        guard !closed, isVisible, desired == admitted,
              session.allowsFolderSizeSummary,
              session.latest.failure == nil, session.latest.directoryRejection == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete,
              snapshot.readID == readID, snapshot == session.latest.snapshot,
              let row = rows.selectedObservation,
              let selection = try? SMBFolderSizeSelection(connection: session.id, snapshot: snapshot, observation: row) else { return nil }
        let location = admitted, revision = rows.selectionRevision, session = session
        return .init(cacheKey: .smb(connection: session.id, snapshot: snapshot, observation: row.id), isCurrent: { [weak self] in
            guard let self, !closed, isVisible, desired == location, admitted == location,
                  rows.selectionRevision == revision, rows.selectedObservation == row,
                  rows.cache.snapshot == snapshot, session.latest.snapshot == snapshot,
                  session.latest.failure == nil, session.latest.directoryRejection == nil else { return false }
            return true
        }, isReady: { [weak self] in
            guard let self else { return false }; return !hasPendingPages && session.latest.idle
        }, calculate: { try await session.summarizeSelectedFolder(selection) })
    }
    init(session: SMBBrowserSession, share: SMBRemoteName, title: String? = nil, savedConnection: WorkspaceConnectionBookmark? = nil, downloads: SMBDownloadStorage? = nil,
         textReads: SMBTextReadStorage? = nil,
         presentation: SMBServerDraft? = nil, uploads: SMBUploadStorage? = nil, actions: SMBActionStorage? = nil,
         showUploadHistory: RemoteUploadHistoryAction? = nil) {
        self.savedConnection = savedConnection
        self.presentation = presentation
        self.remoteActions = session.allowsSelectedActions ? actions : nil
        connectionTitle = title.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)) }
        self.session = session; references = SMBDirectoryReferences(connectionID: session.id, share: share)
        self.downloads = session.allowsSelectedDownloads ? downloads : nil
        // Viewing has its own selected-body grant. A held public Download
        // must not remove an independently admitted private text view.
        self.textReads = session.allowsTextRead ? textReads ?? downloads.map(SMBTextReadStorage.init(sharing:)) : nil
        self.uploads = session.allowsSelectedUploads || session.allowsFolderUploads ? uploads : nil
        self.showUploadHistory = showUploadHistory
        rows.downloadsAvailable = self.downloads != nil
        rows.uploadsAvailable = self.uploads != nil
        rows.folderUploadsAvailable = self.uploads != nil && SMBFolderUploadFeature.available && session.allowsFolderUploads
        SMBBrowserLifetimes.shared.register(session)
        rows.onPage = { [weak self] in self?.requestPage($0) }
        rows.onRefresh = { [weak self] in guard let self, self.isVisible else { return }; self.browser?.refresh(nil) }
        rows.onStop = { [weak self] in self?.session.stopReading() }
        rows.onBack = { [weak self] in guard let self, self.isVisible else { return }; self.browser?.goBack(nil) }
        rows.onUp = { [weak self] in guard let self, self.isVisible else { return }; self.browser?.goUp(nil) }
        rows.onHome = { [weak self] in guard let self, self.isVisible else { return }; self.browser?.navigate(to: .smb(self.root)) }
        rows.onDisconnect = { [weak self] in self?.browser?.disconnectSMBConnection(nil) }
        rows.onProperties = { [weak self] in self?.browser?.showProperties(nil) }
        rows.onCopyName = { [weak self] in self?.browser?.copyNames(nil) }
        rows.onCopyPath = { [weak self] in self?.browser?.copyPath(nil) }
        rows.canInspect = { [weak self] in self?.selectedItemObservation != nil }
        rows.canCopyName = { [weak self] in self?.selectedItemObservation?.copyName != nil }
        rows.canCopyPath = { [weak self] in self?.selectedItemObservation?.copyPath != nil }
        if self.textReads != nil {
            rows.onViewText = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self else { return }
                browser.viewTextInTraverse(nil)
            }
            rows.viewTextAllowed = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self else { return false }
                return ApplicationRemoteTextViews.shared.canOpen(from: browser)
            }
        }
        if session.allowsInPlaceTextEdit, RemoteTextEditorFeature.smbAvailable {
            rows.onEditText = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self else { return }
                browser.editTextInTraverse(nil)
            }
            rows.editTextAllowed = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self else { return false }
                return ApplicationRemoteTextEditors.shared.canOpen(from: browser)
            }
        }
        if self.textReads != nil || session.allowsInPlaceTextEdit && RemoteTextEditorFeature.smbAvailable {
            rows.onNativeTextOpen = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self else { return }
                if ApplicationRemoteTextEditors.shared.canOpen(from: browser) {
                    ApplicationRemoteTextEditors.shared.open(from: browser)
                } else { ApplicationRemoteTextViews.shared.open(from: browser) }
            }
            rows.nativeOpenAllowed = { [weak self] in
                guard let self, let browser, browser.smbTabs[browser.activeID] === self,
                      let row = rows.selectedObservation,
                      ApplicationRemoteTextEditors.shared.canOpen(from: browser)
                        || ApplicationRemoteTextViews.shared.canOpen(from: browser) else { return false }
                return browser.settings.editorPreferences.route(forFilename: row.name.displayName,
                    command: .ordinaryOpen, editorAvailable: true) == .traverse
            }
            rows.openingAppearanceForEntry = { [weak self] row in
                guard let self, let browser, !closed, session.latest.failure == nil else { return .ordinary }
                return .remoteText(name: row.name.displayName, regular: !row.isDirectory && !row.isReparsePoint,
                    bytes: row.logicalBytes, maximumBytes: UInt64(TextDocumentValue.maximumBytes),
                    preferences: browser.settings.editorPreferences,
                    allowsEditing: session.allowsInPlaceTextEdit && RemoteTextEditorFeature.smbAvailable,
                    allowsViewing: self.textReads != nil)
            }
        }
        if remoteActions != nil {
            rows.onRename = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.request(.rename, from: self) }
            rows.onDelete = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.request(.delete, from: self) }
            if SMBRemoteActionFeature.movesAvailable {
                rows.onMove = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.request(.move, from: self) }
            }
            if SMBRemoteActionFeature.copiesAvailable {
                rows.onCopy = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.requestCopy(from: self) }
                rows.onDuplicate = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.requestCopy(from: self, duplicate: true) }
                rows.copyAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbFileActions.canCopy(from: self) }
            }
        }
        rows.fileActionsAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbFileActions.canRequest(from: self) }
        rows.table.nameClickRenameEnabled = { [weak self] in
            guard let self, let browser else { return false }
            return browser.settings.renamesSelectedNameOnClick && browser.smbFileActions.canRequest(from: self)
        }
        rows.table.onNameClickRename = { [weak self] in guard let self, let browser else { return }; browser.smbFileActions.request(.rename, from: self) }
        if self.uploads != nil {
            if SMBUploadFeature.newItemsAvailable {
                rows.onNewFile = { [weak self] in guard let self, let browser else { return }; browser.smbNewItems.request(.textFile, from: self) }
                rows.newFileAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbNewItems.canRequest(.textFile, from: self) }
                if session.allowsFolderUploads && SMBFolderUploadFeature.available {
                    rows.onNewFolder = { [weak self] in guard let self, let browser else { return }; browser.smbNewItems.request(.folder, from: self) }
                    rows.newFolderAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbNewItems.canRequest(.folder, from: self) }
                }
            }
            rows.onUpload = { [weak self] in guard let self, let browser else { return }; browser.smbUpload.request(from: self) }
            rows.uploadAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbUpload.canRequest(from: self) }
            rows.onUploadHistory = { [weak self] in
                guard let self, let browser else { return }
                self.showUploadHistory?(browser.settings, browser.view.window)
            }
            if SMBUploadFeature.dropAvailable {
                rows.onDropPreview = { [weak self] info in
                    guard let self, let browser else { return false }
                    return browser.smbUpload.previewDrop(info, owner: self)
                }
                rows.onDropFiles = { [weak self] info in
                    guard let self, let browser else { return false }
                    return browser.smbUpload.acceptDrop(info, owner: self)
                }
            }
            if SMBUploadFeature.pasteAvailable {
                rows.onPaste = { [weak self] in
                    guard let self, let browser else { return }
                    _ = browser.smbUpload.pasteClipboard(to: self)
                }
                rows.pasteAllowed = { [weak self] in
                    guard let self, let browser else { return false }
                    return browser.smbUpload.canPasteClipboard(to: self)
                }
                rows.table.onPaste = rows.onPaste; rows.table.pasteAllowed = rows.pasteAllowed
            }
        }
        if self.downloads != nil {
            if RemoteDownloadDrag.smbAvailable {
                rows.onDownloadDragWriter = { [weak self] row in
                    guard let self, let browser else { return nil }; return browser.smbDownload.dragWriter(from: self, row: row)
                }
                rows.onDownloadDragBegan = { [weak self] session, indexes in
                    guard let self, let browser else { return }; browser.smbDownload.dragBegan(from: self, session: session, rows: indexes)
                }
                rows.onDownloadDragEnded = { [weak self] session in self?.browser?.smbDownload.dragEnded(session: session) }
            }
            rows.onDownload = { [weak self] in guard let self, let browser else { return }; browser.smbDownload.request(from: self, toPane: false) }
            rows.onDownloadToPane = { [weak self] in guard let self, let browser else { return }; browser.smbDownload.request(from: self, toPane: true) }
            rows.downloadAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbDownload.canRequest(from: self) }
            rows.paneDownloadAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.smbDownload.canRequest(from: self, toPane: true) }
        }
        rows.table.onShortcut = { [weak self] in self?.browser?.routeBrowserShortcut($0) ?? false }
        rows.table.onFocus = { [weak self] in
            guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false)
        }
        rows.table.marquee?.onBegin = { [weak self] in guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false) }
        rows.onSort = { [weak self] sort, descending in
            guard let self else { return }; self.sort = sort; self.descending = descending
            self.pageDemand.clear()
            self.rows.invalidatePages(); self.requestPage(0)
        }
        rows.onOpen = { [weak self] item in
            guard let self, let admitted, let path = self.references.resolve(admitted), item.isDirectory, !item.isReparsePoint,
                  let next = try? self.references.location(for: path + [item.name]) else { return }
            self.browser?.navigate(to: .smb(next))
        }
        let updates = session.updates
        updatesTask = Task { [weak self] in for await update in updates { guard let self else { break }; self.observe(update) } }
    }
    isolated deinit { updatesTask?.cancel(); navigationTask?.cancel(); pageTask?.cancel(); sourceRestoration?.cancel() }
    func attach(to browser: BrowserViewController, location: SMBBrowserLocation, refresh: Bool = false) {
        browser.configureRemoteClipboard(on: self)
        rows.table.behavior = browser.settings.behavior
        self.browser = browser
        rows.configure(glass: browser.contentSurface?.isGlassEnabled == true, motion: browser.settings.motion.allows(.sortIndicators), mode: browser.settings.motion.mode)
        guard !closed, references.resolve(location) != nil else {
            rows.disconnected(closed && drain == nil ? "Closing connection… Waiting for its local work to finish."
                : drain?.ownerReleased == false ? "Connection closure needs attention. Its local data remains protected."
                : "Connection closed. Connect to Server to browse again.")
            browser.renderSMBStatus(session.latest); return
        }
        if desired != location { rows.setFindQuery(""); uploadNotice = nil }
        desired = location
        guard sourceObservation == nil else { return }
        if admitted == location, !refresh { observe(session.latest); return }
        rows.loading(); browser.renderSMBStatus(session.latest)
        guard navigationTask == nil else { return }
        navigationTask = Task { [weak self] in
            guard let self else { return }; defer { self.navigationTask = nil }
            while !self.closed, let desired = self.desired, let path = self.references.resolve(desired) {
                let diagnostic = ApplicationDiagnostics.shared.begin(.remoteBrowse)
                do {
                    let began = ContinuousClock.now
                    let id = try await self.session.navigate(components: path)
                    diagnosticRead = (id, diagnostic)
                    timedRead = (id, began)
                    ApplicationDiagnostics.shared.event(.remoteBrowse, .admitted, trace: diagnostic)
                    self.admitted = desired; self.readID = id
                    if self.desired == desired { self.observe(self.session.latest); return }
                } catch {
                    ApplicationDiagnostics.shared.event(.remoteBrowse, error is CancellationError ? .cancelled : .failed,
                        trace: diagnostic, error: DiagnosticErrors.project(error))
                    if self.desired != desired { continue }
                    self.rows.disconnected("This directory could not be read. The connection status is shown below.")
                    if self.isVisible { self.browser?.renderSMBStatus(self.session.latest) }; return
                }
            }
        }
    }
    func parent(of location: SMBBrowserLocation) -> SMBBrowserLocation? {
        guard let value = try? references.parent(of: location) else { return nil }
        return value == references.root ? root : value
    }
    func directoryLocation(components: [SMBRemoteName]) throws -> SMBBrowserLocation {
        components.isEmpty ? root : try references.location(for: components)
    }
    func bookmark(for location: SMBBrowserLocation) -> WorkspaceConnectionBookmark? {
        guard let savedConnection, let path = references.resolve(location) else { return nil }
        return try? savedConnection.directory(path.map(\.wireUTF16))
    }
    private var isVisible: Bool {
        guard let browser, browser.smbTabs[browser.activeID] === self, case .smb(let value) = browser.location else { return false }
        return value.connectionID == connectionID && value == desired
    }
    func breadcrumbs(for location: SMBBrowserLocation) -> [(String, BrowserLocation)] {
        guard let path = references.resolve(location) else { return [(location.displayHint, .smb(location))] }
        var result: [(String, BrowserLocation)] = [(root.displayHint, .smb(root))]
        for count in 1...max(1, path.count) where count <= path.count {
            if let value = try? references.location(for: Array(path.prefix(count))) { result.append((value.displayHint, .smb(value))) }
        }
        return result
    }
    private func observe(_ update: SMBBrowserUpdate) {
        defer { browser?.listedItemPropertiesController?.refreshFolderSizeAvailability() }
        if update.failure != nil { ApplicationRemoteTextEditors.shared.connectionWillClose(connectionID) }
        if update.failure != nil { browser?.clearRemoteClipboard(for: self) }
        if let diagnostic = update.folderUploadDiagnostic, diagnostic != lastFolderUploadDiagnostic {
            lastFolderUploadDiagnostic = diagnostic
            RemoteTransferDiagnostics.folderFailure(diagnostic, trace: browser?.operationDiagnosticTrace ?? session.id)
        }
        browser?.refreshConnectedLocations()
        if let snapshot = update.snapshot, snapshot.state == .complete || snapshot.state != .loading && update.idle, lastDiagnosticRead != snapshot.readID {
            lastDiagnosticRead = snapshot.readID
            ApplicationDiagnostics.shared.event(.remoteBrowse, update.directoryRejection != nil ? .blocked : snapshot.state == .complete ? .completed : snapshot.state == .stopped ? .cancelled : .partial,
                trace: diagnosticRead?.read == snapshot.readID ? diagnosticRead?.trace : snapshot.readID,
                count: UInt64(max(0,snapshot.count)), error: update.directoryRejection.map { DiagnosticErrors.project($0) } ?? update.failure.map { DiagnosticErrors.project($0) })
        }
        if let failure = update.failure, failure != .stopped, (update.snapshot?.count ?? 0) == 0 {
            rows.disconnected("The connection is unavailable. Reconnect explicitly to try again.")
            if isVisible { browser?.renderSMBStatus(update) }; return
        }
        guard !closed, desired == admitted, let snapshot = update.snapshot, snapshot.readID == readID else {
            if let failure = update.failure, failure != .stopped { rows.disconnected("Connection unavailable · \(failure.rawValue). Connect again explicitly.") }
            return
        }
        if let timing = timedRead, timing.id == snapshot.readID, snapshot.state != .loading {
            timedRead = nil
            if snapshot.state == .complete, update.failure == nil, update.directoryRejection == nil {
                let elapsed = timing.began.duration(to: ContinuousClock.now).components
                lastDirectoryListingMilliseconds = max(0, Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
                lastDirectoryListingAt = Date()
            }
        }
        if let rejection = update.directoryRejection {
            pageDemand.clear()
            rows.directoryRejected(rejection, canGoUp: admitted.flatMap { parent(of: $0) } != nil, canGoHome: admitted != root)
            if isVisible { browser?.renderSMBStatus(update) }; return
        }
        if rows.cache.snapshot != snapshot { pageDemand.clear() }
        rows.observe(snapshot)
        if isVisible { browser?.renderSMBStatus(update) }
    }
    private func requestPage(_ offset: Int64) {
        guard sourceObservation == nil, !closed, session.latest.directoryRejection == nil, let snapshot = rows.cache.snapshot,
              pageTask != nil || session.latest.idle || snapshot.state == .loading,
              let key = try? SMBDirectoryPageDemand.Key(snapshot: snapshot, offset: offset, sort: sort, descending: descending) else { return }
        pageDemand.request(key, alreadyCached: rows.cache.entry(at: offset) != nil)
        guard pageTask == nil, pageDemand.hasQueued else { return }
        pageTask = Task { [weak self] in
            guard let self else { return }; defer {
                self.pageTask = nil; self.browser?.listedItemPropertiesController?.refreshFolderSizeAvailability()
            }
            var findDebounced = false
            while !self.closed, let key = self.pageDemand.take() {
                defer { self.pageDemand.finish(key) }
                let read = self.readID, sort = key.sort, descending = key.descending
                let query = self.rows.findRequest
                @MainActor func current() -> Bool {
                    !self.closed && read == self.readID && self.desired == self.admitted
                        && sort == self.sort && descending == self.descending
                        && self.rows.cache.snapshot == key.snapshot && self.rows.findRequest == query
                }
                do {
                    var find = self.rows.cache.find
                    if let query, find?.query != query {
                        if !findDebounced { try await Task.sleep(for: .milliseconds(150)); findDebounced = true }
                        guard current() else { continue }
                        findDebounced = false
                        let result = try await ApplicationDiagnostics.shared.remoteMetadata(.remoteDirectoryFind, count: { UInt64(clamping: $0.count) }) {
                            try await self.session.find(query)
                        }
                        guard current(), result.snapshot == key.snapshot else {
                            if current() { self.observe(self.session.latest) }; continue
                        }
                        try self.rows.acceptFind(result); find = result
                    } else { findDebounced = false }
                    guard current(), key.offset < (find?.count ?? key.snapshot.count), self.rows.cache.entry(at: key.offset) == nil else { continue }
                    let page = try await self.session.page(offset: key.offset, sort: sort, descending: descending, find: find)
                    guard current(), page.request.snapshot == key.snapshot else { continue }
                    try self.rows.accept(page)
                    if self.isVisible { self.browser?.renderSMBStatus(self.session.latest) }
                } catch is RemoteDirectoryFindFailure {
                    if current(), let query { self.pageDemand.clear(); self.rows.failFind(query) }
                    if self.isVisible { self.browser?.renderSMBStatus(self.session.latest) }
                } catch SMBDirectoryFailure.stale {
                    self.observe(self.session.latest)
                } catch {
                    ApplicationDiagnostics.shared.event(.remoteBrowse, .failed, error: DiagnosticErrors.project(error))
                    if self.isVisible { self.browser?.renderSMBStatus(self.session.latest) }
                }
                if self.isVisible { self.browser?.renderSMBStatus(self.session.latest) }
            }
        }
    }
    @discardableResult func close() -> Task<SMBBrowserDrainResult, Never> {
        ApplicationRemoteTextEditors.shared.connectionWillClose(connectionID)
        browser?.clearRemoteClipboard(for: self)
        if let closing { return closing }
        closed = true; references.close()
        timedRead = nil
        pageDemand.clear()
        updatesTask?.cancel(); navigationTask?.cancel(); pageTask?.cancel()
        sourceObservation?.finishWaiting(); sourceRestoration?.cancel()
        rows.onPage = nil; rows.onOpen = nil; rows.onSort = nil
        rows.onRefresh = nil; rows.onStop = nil; rows.onBack = nil; rows.onUp = nil
        rows.onHome = nil
        rows.onViewText = nil; rows.viewTextAllowed = nil; rows.nativeOpenAllowed = nil; rows.openingAppearanceForEntry = nil
        rows.onEditText = nil; rows.editTextAllowed = nil; rows.onNativeTextOpen = nil
        rows.onDisconnect = nil; rows.table.onShortcut = nil; rows.table.onFocus = nil
        rows.onProperties = nil; rows.onCopyName = nil; rows.onCopyPath = nil
        rows.onRename = nil; rows.onMove = nil; rows.onDelete = nil; rows.fileActionsAllowed = nil
        rows.onCopy = nil; rows.onDuplicate = nil; rows.copyAllowed = nil
        rows.canInspect = nil; rows.canCopyName = nil; rows.canCopyPath = nil
        rows.onDownload = nil; rows.onDownloadToPane = nil; rows.downloadAllowed = nil; rows.paneDownloadAllowed = nil
        rows.onDownloadDragWriter = nil; rows.onDownloadDragBegan = nil; rows.onDownloadDragEnded = nil
        rows.onUpload = nil; rows.uploadAllowed = nil; rows.onUploadHistory = nil
        rows.onNewFile = nil; rows.onNewFolder = nil; rows.newFileAllowed = nil; rows.newFolderAllowed = nil
        rows.onDropPreview = nil; rows.onDropFiles = nil
        rows.onCopyFile = nil; rows.copyFileAllowed = nil; rows.table.onCopy = nil; rows.table.copyAllowed = nil
        rows.onPaste = nil; rows.pasteAllowed = nil; rows.table.onPaste = nil; rows.table.pasteAllowed = nil
        let pending = SMBBrowserLifetimes.shared.close(session)
        closing = pending
        Task {
            let result = await pending.value; self.drain = result
            self.browser?.finishSMBDisconnect(self, result: result)
            if result.ownerReleased { self.browser = nil }
        }
        return pending
    }
}
