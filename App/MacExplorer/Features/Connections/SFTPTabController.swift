import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

typealias SFTPUploadHistoryAction = RemoteUploadHistoryAction

@MainActor final class SFTPTabController {
    static let maximumEditorSourceBytes: UInt64 = 1 << 20
    let session: SFTPBrowserSession, rows = SFTPRemoteRowsView(frame: .zero)
    let connectedAt = Date()
    let downloads: SFTPDownloadStorage?
    let textReads: SFTPTextReadStorage?
    let uploads: SFTPUploadStorage?
    let remoteActions: SFTPRemoteActionStore?
    let newTextStorage: SFTPTextEditStorage?
    let showUploadHistory: SFTPUploadHistoryAction?
    let reviewsUploads: Bool
    /// Presentation only; the authenticated session remains the capability owner.
    let editorCapacityLimited: Bool
    let routeLabel: String?
    private(set) var references: SFTPDirectoryReferences
    let initialComponents: [SFTPRemoteName]
    private(set) var savedConnection: WorkspaceConnectionBookmark?
    private weak var browser: BrowserViewController?
    private var desired: SFTPBrowserLocation?, admitted: SFTPBrowserLocation?, readID: UUID?
    private var observationRevision = UUID()
    private var invalidatedDirectory: (prefix: SFTPDefaultDirectory, confirmedRename: Bool)?
    private var diagnosticRead: (read: UUID, trace: UUID)?, lastDiagnosticRead: UUID?
    private var navigation: Task<Void, Never>?, pageTask: Task<Void, Never>?, updates: Task<Void, Never>?
    private var sourceObservation: RemoteSourceObservationLease?
    private var sourceRestoration: Task<Void, Never>?
    private var queuedOffset: UInt64?, sort = SFTPStoredSort.name, descending = false
    private(set) var operationNotice: ConnectionOperationNotice?
    var transferNotice: String? { operationNotice?.message }
    private(set) var isClosing = false, drain: SFTPWorkerClose?
    private var closing: Task<SFTPWorkerClose, Never>?
    var connectionID: UUID { session.id }
    var hasPendingPages: Bool { pageTask != nil || queuedOffset != nil }
    #if DEBUG
    var navigationAdmittedForVerification: Bool {
        !isClosing && navigation == nil && desired != nil && desired == admitted
            && readID != nil && rows.cache.generation == readID && session.latest.generation == readID
            && rows.cache.snapshot != nil && rows.cache.snapshot == session.latest.snapshot
            && session.latest.failure == nil && !hasPendingPages
    }
    #endif
    var root: SFTPBrowserLocation { references.root }
    var currentBrowserLocation: BrowserLocation { .sftp(desired ?? root) }
    let address: SFTPConnectionAddress
    let presentation: SFTPServerDraft?
    let routeDescription: SFTPRouteDescription?
    /// Direct connections have native empty-folder acceptance. Routed actions
    /// keep their existing file-only scope until that composition is qualified.
    let allowsEmptyDirectoryDelete: Bool
    let allowsDirectoryRename: Bool
    let allowsFileMove: Bool
    let allowsDirectoryMove: Bool
    let allowsServerCopy: Bool
    let signIn: SFTPRouteSignIn
    let requiresUserCertificate: Bool
    /// Original visible choice for metadata-only Save Details; never a live
    /// worker policy setter or proof that an upload/edit capability was admitted.
    let transferPreference: SFTPTransferPreference?
    func adoptSavedTarget(_ target: WorkspaceConnectionBookmark) {
        guard !isClosing, target.isSFTP else { return }; savedConnection = target
    }
    var loadedNameQuery: String { rows.findQuery }
    func setLoadedNameQuery(_ value: String) {
        guard !rows.findQuery.utf8.elementsEqual(value.utf8) else { return }
        queuedOffset = nil; rows.setFindQuery(value)
        browser?.inlineRename.selectionDidChange()
        if isVisible { browser?.renderSFTPStatus(session.latest) }
    }
    func navigationDirectory(_ value: SFTPBrowserLocation) -> SFTPDefaultDirectory? {
        guard !isClosing, let path = references.resolve(value), let home = references.isHomeRelative(value) else { return nil }
        return try? .init(root: home ? .home : .server, components: path)
    }
    var selectedItemObservation: RemoteItemObservation? {
        guard !isClosing, isVisible, desired == admitted, let admitted, let snapshot = rows.cache.snapshot,
              rows.cache.generation == readID, session.latest.generation == readID, session.latest.snapshot == snapshot,
              session.latest.failure == nil, let row = rows.selectedObservation,
              let path = references.resolve(admitted), let wire = references.pathUTF8(for:admitted) else { return nil }
        return try? .init(sftp:row,directory:path,homeRelative:wire.first == 46,listingComplete:snapshot.state == .complete)
    }
    var folderSizeAction: RemoteFolderSizeAction? {
        guard !isClosing, isVisible, desired == admitted,
              session.allowsFolderSizeSummary, session.latest.failure == nil,
              let snapshot = rows.cache.snapshot, snapshot.state == .complete,
              let generation = rows.cache.generation, generation == readID,
              session.latest.generation == generation, session.latest.snapshot == snapshot,
              let row = rows.selectedObservation,
              let selection = try? SFTPFolderSizeSelection(generation: generation, snapshot: snapshot, row: row) else { return nil }
        let location = admitted, revision = rows.selectionRevision, session = session
        return .init(cacheKey: .sftp(connection: session.id, generation: generation, snapshot: snapshot, observation: row.observation), isCurrent: { [weak self] in
            guard let self, !isClosing, isVisible, desired == location, admitted == location,
                  rows.selectionRevision == revision, rows.selectedObservation == row,
                  rows.cache.generation == generation, rows.cache.snapshot == snapshot,
                  session.latest.generation == generation, session.latest.snapshot == snapshot,
                  session.latest.failure == nil else { return false }
            return true
        }, isReady: { [weak self] in
            guard let self else { return false }; return !hasPendingPages && !session.latest.reading
        }, calculate: { try await session.summarizeSelectedFolder(selection) })
    }
    /// One observed regular-file selection only. No URL/path constructor and
    /// no use of whatever selection becomes visible after the explicit command.
    var sealedEditorSelection: SFTPDownloadSelection? {
        guard !isClosing, isVisible, desired == admitted, let snapshot = rows.cache.snapshot,
              snapshot.state == .complete, session.latest.failure == nil,
              rows.cache.generation == readID, session.latest.generation == readID,
              session.latest.snapshot == snapshot, !hasPendingPages,
              let selection = rows.selectedDownload, selection.logicalBytes <= Self.maximumEditorSourceBytes else { return nil }
        return selection
    }
    var sealedBatchDownload: SFTPDownloadBatchPlan? {
        guard !isClosing, isVisible, desired == admitted, let snapshot = rows.cache.snapshot,
              snapshot.state == .complete, session.latest.failure == nil,
              rows.cache.generation == readID, session.latest.generation == readID,
              session.latest.snapshot == snapshot, !hasPendingPages else { return nil }
        return rows.selectedDownloadBatch
    }
    var sealedActionSnapshot: (generation: UUID, snapshot: SFTPStoredSnapshot)? {
        guard sourceObservation == nil, !isClosing, isVisible, desired == admitted, let snapshot = rows.cache.snapshot,
              snapshot.state == .complete, session.latest.failure == nil,
              let generation = readID, rows.cache.generation == generation, session.latest.generation == generation,
              session.latest.snapshot == snapshot, !hasPendingPages else { return nil }
        return (generation, snapshot)
    }
    func captureClipboardSource(_ operation: TransferClipboardFeedback.Intent) -> SFTPClipboardSource? {
        guard let browser, !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand,
              browser.hasFileCommandFocus, browser.view.window?.attachedSheet == nil,
              routeDescription == nil, remoteActions != nil, session.allowsRemoteActions,
              ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation,
              let captured = sealedActionSnapshot, let desired,
              let directory = navigationDirectory(desired), let row = rows.selectedObservation else { return nil }
        if operation == .copy {
            guard RemoteClipboardFeature.sftpCopyAvailable, allowsServerCopy, row.entry.isDirectory == false,
                  let root = try? SFTPDefaultDirectory(root: .server),
                  let probeName = try? SFTPRemoteName(Data(row.entry.name.displayName == "Copy" ? "Copy 2".utf8 : "Copy".utf8)),
                  (try? SFTPRemoteActionIntent.copyFile(generation: captured.generation,
                    snapshot: captured.snapshot, row: row, destinationDirectory: root, newName: probeName)) != nil else { return nil }
        } else {
            guard RemoteClipboardFeature.movesAvailable, directory.root == .server,
                  row.entry.isDirectory == true ? allowsDirectoryMove : allowsFileMove,
                  (try? SFTPRemoteActionIntent.deleteFilePermanently(generation: captured.generation,
                    snapshot: captured.snapshot, row: row)) != nil
                    || (try? SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: captured.generation,
                        snapshot: captured.snapshot, row: row)) != nil else { return nil }
        }
        return .init(owner: self, directory: directory, row: row)
    }

    /// Reopens only metadata through this exact authenticated owner. The hidden
    /// read never changes desired/admitted/readID or feeds its pages to rows.
    func reobserveClipboardSource(_ source: SFTPClipboardSource, preparation: UUID,
        operation: TransferClipboardFeedback.Intent = .move,
        current: @MainActor () -> Bool) async throws -> (generation: UUID, snapshot: SFTPStoredSnapshot, row: SFTPStoredRow) {
        guard source.belongs(to: self), (operation == .copy || source.directory.root == .server), routeDescription == nil,
              remoteActions != nil, session.allowsRemoteActions,
              (operation == .copy ? RemoteClipboardFeature.sftpCopyAvailable
                && allowsServerCopy && source.row.entry.isDirectory == false
                : source.row.entry.isDirectory == true ? allowsDirectoryMove : allowsFileMove),
              sourceObservation == nil, sourceRestoration == nil, navigation == nil, !hasPendingPages,
              !session.latest.reading, let browser,
              browser.operationCoordinator.preparationOwner == preparation, current(), !isClosing else {
            throw RemoteSourceObservationFailure.stale
        }
        let lease = RemoteSourceObservationLease(preparation: preparation)
        sourceObservation = lease
        lease.armDeadline { [weak self, weak lease] in
            guard let self, let lease, self.sourceObservation === lease, lease.started, !self.isClosing else { return }
            self.session.stopReading()
        }
        defer { lease.finishWaiting() }
        func check() throws {
            try lease.check()
            guard sourceObservation === lease, self.browser === browser, !isClosing,
                  navigation == nil, !hasPendingPages,
                  browser.operationCoordinator.preparationOwner == preparation, current() else {
                throw RemoteSourceObservationFailure.stale
            }
            guard session.latest.failure == nil else { throw RemoteSourceObservationFailure.unavailable }
        }
        do {
            try check(); lease.started = true
            let generation = try await session.navigate(pathUTF8: source.directory.pathUTF8)
            try check()
            var snapshot: SFTPStoredSnapshot
            while true {
                try check()
                let update = session.latest
                guard update.directoryRejection == nil else { throw RemoteSourceObservationFailure.unavailable }
                // navigate resumes before the pump publishes its new snapshot.
                // Keep this valid pre-publication interval inside the same
                // bounded observation instead of rejecting the previous value.
                if update.generation == generation, let value = update.snapshot {
                    if value.state == .complete, !update.reading { snapshot = value; break }
                    guard value.state == .loading, !update.paused else { throw RemoteSourceObservationFailure.incomplete }
                }
                try await Task.sleep(for: .milliseconds(25)); try check()
            }
            var offset: UInt64 = 0
            for _ in 0..<RemoteSourceObservationLease.maximumPages where offset < snapshot.count {
                try check()
                let page = try await session.page(offset: offset, sort: .name, descending: false)
                try check()
                guard page.generation == generation, page.snapshot == snapshot, page.offset == offset,
                      session.latest.generation == generation, session.latest.snapshot == snapshot,
                      !page.rows.isEmpty, page.rows.count <= 256,
                      UInt64(page.rows.count) <= snapshot.count - offset else { throw RemoteSourceObservationFailure.stale }
                // The existing catalog enforces UNIQUE(read,name); observation
                // ordinals are not sorted offsets and are never reused here.
                if let row = page.rows.first(where: { $0.entry.name == source.row.entry.name }) {
                    guard row.entry == source.row.entry else { throw RemoteSourceObservationFailure.changed }
                    try check()
                    return (generation, snapshot, row)
                }
                offset += UInt64(page.rows.count)
            }
            throw offset < snapshot.count ? RemoteSourceObservationFailure.incomplete : .changed
        } catch {
            if sourceObservation === lease, lease.started, !isClosing {
                lease.stopRequested = true; session.stopReading()
            }
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= lease.deadline { throw RemoteSourceObservationFailure.deadline }
            throw error as? RemoteSourceObservationFailure ?? .unavailable
        }
    }

    /// Called by the action owner's finally path, after mutation or refusal.
    /// Keep suppression through actual read pause/drain and coordinator release;
    /// then reread the user's current choice, never the earlier Paste location.
    func restoreAfterClipboardSourceObservation() {
        guard let lease = sourceObservation, sourceRestoration == nil else { return }
        lease.finishWaiting()
        observationRevision = UUID(); admitted = nil; readID = nil; queuedOffset = nil
        sourceRestoration = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if sourceObservation === lease { sourceObservation = nil }; sourceRestoration = nil }
            while !isClosing, sourceObservation === lease {
                let update = session.latest
                let readEnded = !update.reading && (!lease.stopRequested || update.paused || update.failure != nil)
                let available = browser?.operationCoordinator.activeOwner == nil && browser?.operationCoordinator.preparationOwner == nil
                if readEnded && available {
                    sourceObservation = nil
                    guard isVisible, let browser, let desired else { return }
                    if update.failure != nil {
                        rows.disconnected("The connection is unavailable. Connect again to continue.")
                        browser.renderSFTPStatus(update)
                        return
                    }
                    attach(to: browser, location: desired, refresh: true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
    }
    init(session: SFTPBrowserSession, address: SFTPConnectionAddress, title: String, downloads: SFTPDownloadStorage? = nil,
         uploads: SFTPUploadStorage? = nil, remoteActions: SFTPRemoteActionStore? = nil,
         textReads: SFTPTextReadStorage? = nil,
         newTextStorage: SFTPTextEditStorage? = nil,
         reviewsUploads: Bool = true, showUploadHistory: SFTPUploadHistoryAction? = nil,
         savedConnection: WorkspaceConnectionBookmark? = nil, routeLabel: String? = nil,
         defaultDirectory: SFTPDefaultDirectory? = nil, presentation: SFTPServerDraft? = nil,
         routeDescription: SFTPRouteDescription? = nil, signIn: SFTPRouteSignIn = .password,
         requiresUserCertificate: Bool = false,
         transferPreference: SFTPTransferPreference? = nil, editorCapacityLimited: Bool = false) {
        self.address = address
        self.presentation = presentation; self.routeDescription = routeDescription
        self.signIn = signIn; self.requiresUserCertificate = requiresUserCertificate
        self.transferPreference = transferPreference
        self.savedConnection = savedConnection
        self.newTextStorage = session.allowsFreshUploads ? newTextStorage : nil
        self.session = session; initialComponents = defaultDirectory?.components ?? address.components ?? []
        self.downloads = session.allowsRequestedDownloads ? downloads : nil
        self.textReads = session.allowsTextRead ? textReads : nil
        rows.folderDownloadsAvailable = session.allowsRequestedFolderDownloads
        self.uploads = session.allowsFreshUploads ? uploads : nil
        self.remoteActions = session.allowsRemoteActions && SFTPRemoteActionFeature.available ? remoteActions : nil
        allowsEmptyDirectoryDelete = self.remoteActions != nil && routeDescription == nil
            && SFTPRemoteActionFeature.emptyDirectoryDeleteAvailable
        allowsDirectoryRename = self.remoteActions != nil && routeDescription == nil
            && SFTPRemoteActionFeature.directoryRenameAvailable
        allowsFileMove = self.remoteActions != nil && routeDescription == nil && SFTPRemoteActionFeature.fileMoveAvailable
        allowsDirectoryMove = self.remoteActions != nil && routeDescription == nil && SFTPRemoteActionFeature.directoryMoveAvailable
        allowsServerCopy = self.remoteActions != nil && routeDescription == nil
            && SFTPRemoteActionFeature.copiesAvailable && session.allowsServerCopy
        rows.allowsDirectoryMove = allowsDirectoryMove
        rows.allowsEmptyDirectoryDelete = allowsEmptyDirectoryDelete
        rows.allowsDirectoryRename = allowsDirectoryRename
        self.showUploadHistory = showUploadHistory
        self.reviewsUploads = reviewsUploads
        self.editorCapacityLimited = editorCapacityLimited
        self.routeLabel = routeLabel
        references = .init(connectionID: session.id,
            home: defaultDirectory.map { $0.root == .home } ?? (address.components == nil), title: title)
        SFTPBrowserLifetimes.shared.register(session)
        rows.onPage = { [weak self] in self?.requestPage($0) }; rows.onRefresh = { [weak self] in self?.browser?.refresh(nil) }
        rows.onStop = { [weak self] in self?.session.stopReading() }; rows.onDisconnect = { [weak self] in self?.browser?.disconnectSFTPConnection(nil) }
        rows.onBack = { [weak self] in self?.browser?.goBack(nil) }; rows.onUp = { [weak self] in self?.browser?.goUp(nil) }
        rows.onHome = { [weak self] in guard let self, !isClosing else { return }; browser?.navigate(to: .sftp(references.homeRoot)) }
        rows.onProperties = { [weak self] in self?.browser?.showProperties(nil) }
        rows.onCopyName = { [weak self] in self?.browser?.copyNames(nil) }
        rows.onCopyPath = { [weak self] in self?.browser?.copyPath(nil) }
        rows.canInspect = { [weak self] in self?.selectedItemObservation != nil }
        rows.canCopyName = { [weak self] in self?.selectedItemObservation?.copyName != nil }
        rows.canCopyPath = { [weak self] in self?.selectedItemObservation?.copyPath != nil }
        if self.remoteActions != nil {
            rows.onNewFolder = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.request(.newFolder, from: self) }
            rows.onRename = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.requestRename(from: self) }
            rows.onDeletePermanently = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.requestDelete(from: self) }
            rows.newFolderAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFileActions.canRequest(.newFolder, from: self) }
            rows.renameAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFileActions.canRename(from: self) }
            rows.renameExplanation = { [weak self] in guard let self, let browser else { return nil }; return browser.sftpFileActions.renameExplanation(from: self) }
            if allowsFileMove || allowsDirectoryMove {
                rows.onMove = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.requestMove(from: self) }
                rows.moveAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFileActions.canMove(from: self) }
                rows.moveExplanation = { [weak self] in guard let self, let browser else { return nil }; return browser.sftpFileActions.moveExplanation(from: self) }
            }
            if allowsServerCopy {
                rows.onServerCopy = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.requestCopy(from: self) }
                rows.onDuplicate = { [weak self] in guard let self, let browser else { return }; browser.sftpFileActions.requestCopy(from: self, duplicate: true) }
                rows.serverCopyAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFileActions.canCopy(from: self) }
            }
            rows.deleteAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFileActions.canDelete(from: self) }
            if showUploadHistory != nil {
                rows.onActionHistory = { [weak self] in guard let self, let browser else { return }; self.showUploadHistory?(browser.settings, browser.view.window) }
            }
        }
        if session.allowsInPlaceEditing {
            rows.onEditText = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self else { return }
                browser.editTextInTraverse(nil)
            }
            rows.editTextAllowed = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self else { return false }
                return ApplicationRemoteTextEditors.shared.canOpen(from: browser)
            }
        }
        if self.textReads != nil {
            rows.onViewText = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self else { return }
                browser.viewTextInTraverse(nil)
            }
            rows.viewTextAllowed = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self else { return false }
                return ApplicationRemoteTextViews.shared.canOpen(from: browser)
            }
        }
        if session.allowsInPlaceEditing || self.textReads != nil {
            rows.openingAppearanceForEntry = { [weak self] entry in
                guard let self, let browser, !isClosing, session.latest.failure == nil else { return .ordinary }
                return Self.openingAppearance(for: entry, preferences: browser.settings.editorPreferences,
                    allowsEditing: session.allowsInPlaceEditing && !editorCapacityLimited,
                    allowsViewing: self.textReads != nil)
            }
            rows.nativeOpenAllowed = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self,
                      let row = self.rows.selectedObservation,
                      ApplicationRemoteTextEditors.shared.canOpen(from: browser)
                        || ApplicationRemoteTextViews.shared.canOpen(from: browser) else { return false }
                return browser.settings.editorPreferences.route(forFilename: row.entry.name.displayName,
                    command: .ordinaryOpen,
                    editorAvailable: RemoteTextEditorFeature.available || RemoteTextViewFeature.available) == .traverse
            }
            rows.onNativeTextOpen = { [weak self] in
                guard let self, let browser, browser.sftpTabs[browser.activeID] === self else { return }
                if ApplicationRemoteTextEditors.shared.canOpen(from: browser) {
                    ApplicationRemoteTextEditors.shared.open(from: browser, allowsReadOnlyFallback: true)
                } else { ApplicationRemoteTextViews.shared.open(from: browser) }
            }
        }
        if self.newTextStorage != nil {
            rows.onNewFile = { [weak self] in guard let self, let browser else { return }; browser.sftpNewFile.request(from: self) }
            rows.newFileAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpNewFile.canRequest(from: self) }
        }
        if self.uploads != nil {
            if SFTPDropUploadFeature.available {
                rows.onPaste = { [weak self] in guard let self, let browser else { return }; _ = browser.sftpDropUpload.pasteClipboard(to: self) }
                rows.pasteAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpDropUpload.canPasteClipboard(to: self) }
                rows.table.onPaste = rows.onPaste; rows.table.pasteAllowed = rows.pasteAllowed
            }
            rows.onDropPreview = { [weak self] info in guard let self, let browser else { return nil }; return browser.sftpDropUpload.preview(info, owner: self) }
            rows.onDropFiles = { [weak self] info in guard let self, let browser else { return false }; return browser.sftpDropUpload.accept(info, owner: self) }
            rows.onUpload = { [weak self] in guard let self else { return }; browser?.sftpUpload.request(from: self) }
            rows.uploadAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpUpload.canRequest(from: self) }
            if session.allowsFreshFolderUploads && SFTPFolderUploadFeature.available {
                rows.onUploadFolder = { [weak self] in guard let self else { return }; browser?.sftpFolderUpload.request(from: self) }
                rows.folderUploadAllowed = { [weak self] in guard let self, let browser else { return false }; return browser.sftpFolderUpload.canRequest(from: self) }
            }
            rows.onUploadHistory = { [weak self] in guard let self, let browser else { return }; self.showUploadHistory?(browser.settings, browser.view.window) }
        }
        if self.downloads != nil {
            if SFTPFilePromiseFeature.available {
                rows.onPromiseWriter = { [weak self] row in
                    guard let self, let browser else { return nil }
                    return browser.sftpDownload.promiseWriter(from: self, row: row)
                }
                rows.onPromiseDidBegin = { [weak self] session, indexes in
                    guard let self, let browser else { return }
                    browser.sftpDownload.promiseBegan(from: self, session: session, rows: indexes)
                }
                rows.onPromiseDidEnd = { [weak self] session, operation in
                    self?.browser?.sftpDownload.promiseEnded(session: session, operation: operation)
                }
            }
            rows.onDownload = { [weak self] in
                guard let self, let browser else { return }
                if self.rows.selectedDownloadBatch != nil { browser.remoteBatchDownload.request(from: self, toPane: false) }
                else if self.rows.selectedFolderDownload != nil { browser.sftpFolderDownload.request(from: self, toPane: false) }
                else { browser.sftpDownload.request(from: self, toPane: false) }
            }
            rows.onDownloadToPane = { [weak self] in
                guard let self, let browser else { return }
                if self.rows.selectedDownloadBatch != nil { browser.remoteBatchDownload.request(from: self, toPane: true) }
                else if self.rows.selectedFolderDownload != nil { browser.sftpFolderDownload.request(from: self, toPane: true) }
                else { browser.sftpDownload.request(from: self, toPane: true) }
            }
            rows.downloadAllowed = { [weak self] in
                guard let self, let browser else { return false }
                if self.rows.selectedDownloadBatch != nil { return browser.remoteBatchDownload.canRequest(from: self) }
                return self.rows.selectedFolderDownload != nil ? browser.sftpFolderDownload.canRequest(from: self) : browser.sftpDownload.canRequest(from: self)
            }
            rows.paneDownloadAllowed = { [weak self] in
                guard let self, let browser else { return false }
                if self.rows.selectedDownloadBatch != nil { return browser.remoteBatchDownload.canRequest(from: self, toPane: true) }
                return self.rows.selectedFolderDownload != nil ? browser.sftpFolderDownload.canRequest(from: self, toPane: true) : browser.sftpDownload.canRequest(from: self, toPane: true)
            }
        }
        rows.table.onShortcut = { [weak self] in self?.browser?.routeBrowserShortcut($0) ?? false }
        rows.table.onFocus = { [weak self] in guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false) }
        rows.table.marquee?.onBegin = { [weak self] in guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false) }
        rows.onSort = { [weak self] sort, descending in guard let self else { return }; self.sort = sort; self.descending = descending; rows.invalidatePages(); requestPage(0) }
        rows.onOpen = { [weak self] row in
            guard let self, !isClosing, session.latest.failure == nil, let admitted, let path = references.resolve(admitted),
                  let relative = references.isHomeRelative(admitted), row.entry.isDirectory == true,
                  let next = try? references.location(for: path + [row.entry.name], relativeToHome: relative) else { return }; browser?.navigate(to: .sftp(next))
        }
        let stream = session.updates
        updates = Task { [weak self] in for await value in stream { guard let self else { break }; observe(value) } }
    }
    isolated deinit { updates?.cancel(); navigation?.cancel(); pageTask?.cancel(); sourceRestoration?.cancel() }
    /// Filename and already-loaded metadata guide the cue. Actual Open still
    /// seals the selected observation and checks editor admission separately.
    static func openingAppearance(for entry: SFTPWorkerEntry, preferences: EditorPreferences,
                                  allowsEditing: Bool, allowsViewing: Bool = false) -> FileOpeningAppearance {
        let regular = entry.permissions.map { $0 & 0o170000 == 0o100000 } == true
        return .remoteText(name: entry.name.displayName, regular: regular, bytes: entry.logicalBytes,
            maximumBytes: maximumEditorSourceBytes, preferences: preferences,
            allowsEditing: allowsEditing && RemoteTextEditorFeature.available,
            allowsViewing: allowsViewing && RemoteTextViewFeature.available)
    }
    private var isVisible: Bool {
        guard let browser, let desired else { return false }; return browser.sftpTabs[browser.activeID] === self && browser.location == .sftp(desired)
    }
    func attach(to browser: BrowserViewController, location: SFTPBrowserLocation, refresh: Bool) {
        browser.configureRemoteClipboard(on: self)
        rows.onSelectionChanged = { [weak browser] in browser?.inlineRename.selectionDidChange() }
        rows.table.nameClickRenameEnabled = { [weak browser] in browser?.settings.renamesSelectedNameOnClick == true }
        rows.table.onNameClickRename = { [weak self, weak browser] in guard let self, let browser else { return }; browser.sftpFileActions.requestRename(from: self) }
        rows.table.behavior = browser.settings.behavior
        self.browser = browser; rows.configure(glass: browser.contentSurface?.isGlassEnabled == true, motion: browser.settings.motion.allows(.sortIndicators), mode: browser.settings.motion.mode)
        guard !isClosing, references.resolve(location) != nil else { rows.disconnected("Connection closed. Connect explicitly to browse again."); return }
        if desired != location {
            rows.setFindQuery("")
            clearTransferOutcome()
        }
        desired = location
        guard sourceObservation == nil else { return }
        if refresh { invalidatedDirectory = nil }
        if isInvalidated(location) { showInvalidatedDirectory(location); return }
        if admitted == location && !refresh { observe(session.latest); return }; rows.loading()
        guard navigation == nil else { return }
        navigation = Task { [weak self] in
            guard let self else { return }; defer { navigation = nil }
            while !isClosing, let desired = self.desired, let path = references.pathUTF8(for: desired) {
                let revision = observationRevision
                let diagnostic = ApplicationDiagnostics.shared.begin(.remoteBrowse)
                do {
                    let id = try await session.navigate(pathUTF8: path)
                    guard !isClosing else { return }
                    // A Move may invalidate this read while it is suspended.
                    // Never admit its old result; reread the still-chosen path.
                    if revision != observationRevision {
                        if isInvalidated(desired) { showInvalidatedDirectory(desired); return }
                        continue
                    }
                    if isInvalidated(desired) {
                        if self.desired != desired { continue }
                        showInvalidatedDirectory(desired); return
                    }
                    admitted = desired; readID = id
                    diagnosticRead = (id, diagnostic)
                    ApplicationDiagnostics.shared.event(.remoteBrowse, .admitted, trace: diagnostic)
                    if self.desired == desired { observe(session.latest); return }
                } catch {
                    ApplicationDiagnostics.shared.event(.remoteBrowse, error is CancellationError ? .cancelled : .failed,
                        trace: diagnostic, error: DiagnosticErrors.project(error))
                    if self.desired != desired || revision != observationRevision && session.latest.failure == nil { continue }
                    admitted = nil; readID = nil
                    if let rejection = error as? SFTPDirectoryRejection { rows.directoryRejected(rejection, canGoUp: parent(of: desired) != nil) }
                    else { rows.disconnected("The connection is unavailable. Connect again to continue.") }
                    self.browser?.renderSFTPStatus(session.latest); return
                }
            }
        }
    }
    func parent(of value: SFTPBrowserLocation) -> SFTPBrowserLocation? { try? references.parent(of: value) }
    /// Keep the result attached to this directory through its post-action
    /// metadata refresh. Moving to another folder clears the old notice.
    func showTransferOutcome(_ text: String, needsAttention: Bool = false, showsUploadHistory: Bool = true) {
        operationNotice = text.isEmpty ? nil : .init(message: text, needsAttention: needsAttention, showsUploadHistory: showsUploadHistory)
        rows.showUploadOutcome(showsUploadHistory ? text : "")
        if isVisible { browser?.renderCurrentSFTPStatus() }
    }
    func clearTransferOutcome() { operationNotice = nil; rows.showUploadOutcome("") }
    func refreshAfterUpload() {
        let visible = isVisible; admitted = nil
        if visible, let browser, let desired { attach(to: browser, location: desired, refresh: true) }
    }
    func refreshAfterUpload(at location: SFTPBrowserLocation) {
        // A queued navigation may have completed after the batch. Do not clear
        // its newer admission or refresh whichever folder happens to be visible.
        if admitted == location { admitted = nil }
        guard desired == location, isVisible, navigation == nil, let browser else { return }
        attach(to: browser, location: location, refresh: true)
    }
    /// Negative observation hint only. Home-relative aliases are refreshed
    /// conservatively because another connection cannot certify their mapping.
    func refreshAfterFileMove(source: Data, destination: Data) {
        guard !isClosing, invalidatedDirectory == nil, let desired, let directory = navigationDirectory(desired),
              directory.root == .home || directory.pathUTF8 == source || directory.pathUTF8 == destination else { return }
        observationRevision = UUID(); admitted = nil; readID = nil; queuedOffset = nil
        // Do not queue navigation into another pane's active transfer. Its next
        // explicit refresh/activation will obtain a new snapshot instead.
        guard browser?.hasExclusiveBrowserOperation == false, navigation == nil,
              !session.latest.reading, !hasPendingPages, session.latest.failure == nil else { return }
        refreshAfterUpload(at: desired)
    }
    /// A negative cache hint from a checked action in a matching connection.
    /// It cannot resolve a path or grant authority, and never retargets a tab.
    func invalidateObservedDirectory(_ prefix: SFTPDefaultDirectory, confirmedRename: Bool) {
        guard let desired, let current = navigationDirectory(desired), current.root == prefix.root,
              current.components.starts(with: prefix.components) else { return }
        invalidatedDirectory = (prefix, confirmedRename)
        observationRevision = UUID(); admitted = nil; readID = nil; queuedOffset = nil; pageTask?.cancel()
        showInvalidatedDirectory(desired)
    }
    private func isInvalidated(_ location: SFTPBrowserLocation) -> Bool {
        guard let invalidatedDirectory, let current = navigationDirectory(location) else { return false }
        return current.root == invalidatedDirectory.prefix.root
            && current.components.starts(with: invalidatedDirectory.prefix.components)
    }
    private func showInvalidatedDirectory(_ location: SFTPBrowserLocation) {
        rows.directoryChanged(confirmedRename: invalidatedDirectory?.confirmedRename == true,
            canGoUp: parent(of: location) != nil)
    }
    func directoryLocation(components: [SFTPRemoteName], relativeToHome: Bool? = nil) throws -> SFTPBrowserLocation { try references.location(for: components, relativeToHome: relativeToHome) }
    func bookmark(for location: SFTPBrowserLocation) -> WorkspaceConnectionBookmark? {
        guard let savedConnection, let path = references.resolve(location), let relative = references.isHomeRelative(location) else { return nil }
        return try? .init(kind: savedConnection.kind, serverID: savedConnection.serverID, binding: savedConnection.binding,
            title: savedConnection.title, components: path.map(\.wireUTF8), relativeToHome: relative)
    }
    func breadcrumbs(for value: SFTPBrowserLocation) -> [(String, BrowserLocation)] {
        guard let path = references.resolve(value), let relative = references.isHomeRelative(value), let base = references.baseRoot(for: value) else { return [(value.displayHint, .sftp(value))] }
        var result = [(base.displayHint, BrowserLocation.sftp(base))]
        for count in 1...max(1, path.count) where count <= path.count {
            if let item = try? references.location(for: Array(path.prefix(count)), relativeToHome: relative) { result.append((item.displayHint, .sftp(item))) }
        }; return result
    }
    func transferDestination(for value: SFTPBrowserLocation) -> String {
        let path = breadcrumbs(for: value).map(\.0).joined(separator: " › ")
        return routeLabel.map { path + " · " + $0 } ?? path
    }
    private func observe(_ update: SFTPBrowserUpdate) {
        defer { browser?.listedItemPropertiesController?.refreshFolderSizeAvailability() }
        if update.failure != nil { browser?.clearRemoteClipboard(for: self) }
        if update.failure != nil, update.directoryRejection == nil {
            ApplicationRemoteTextEditors.shared.connectionWillClose(connectionID)
        }
        browser?.refreshConnectedLocations()
        if let id = update.generation, let snapshot = update.snapshot, snapshot.state != .loading, lastDiagnosticRead != id {
            lastDiagnosticRead = id
            ApplicationDiagnostics.shared.event(.remoteBrowse, snapshot.state == .complete ? .completed : snapshot.state == .stopped ? .cancelled : .partial,
                trace: diagnosticRead?.read == id ? diagnosticRead?.trace : id,
                count: snapshot.count, error: update.failure.map { DiagnosticErrors.project($0) })
        }
        guard !isClosing, desired == admitted, update.generation == readID else { return }
        rows.observe(update); if isVisible { browser?.renderSFTPStatus(update) }
    }
    private func requestPage(_ offset: UInt64) {
        guard sourceObservation == nil, !isClosing, session.latest.failure == nil else { return }; queuedOffset = offset
        guard pageTask == nil else { return }
        pageTask = Task { [weak self] in
            guard let self else { return }; defer {
                pageTask = nil; browser?.listedItemPropertiesController?.refreshFolderSizeAvailability()
            }
            var findDebounced = false
            while !isClosing, let offset = queuedOffset {
                queuedOffset = nil
                guard let snapshot = rows.cache.snapshot, desired == admitted else { continue }
                let id = readID, order = sort, reverse = descending
                let query = rows.findRequest
                @MainActor func current() -> Bool {
                    !isClosing && id == readID && desired == admitted && order == sort && reverse == descending
                        && rows.cache.snapshot == snapshot && rows.findRequest == query
                }
                do {
                    var find = rows.cache.find
                    if let query, find?.query != query {
                        if !findDebounced { try await Task.sleep(for: .milliseconds(150)); findDebounced = true }
                        // Retired snapshots/keystrokes keep the completed
                        // debounce, so the latest queued context can proceed
                        // without waiting once per ingestion batch.
                        guard current() else { continue }
                        findDebounced = false
                        let result = try await ApplicationDiagnostics.shared.remoteMetadata(.remoteDirectoryFind, count: { $0.count }) {
                            try await session.find(query)
                        }
                        guard current(), result.generation == id, result.snapshot == snapshot else {
                            if current() { observe(session.latest) }; continue
                        }
                        try rows.acceptFind(result); find = result
                    } else { findDebounced = false }
                    guard current(), offset < (find?.count ?? snapshot.count), rows.cache.entry(at: offset) == nil else { continue }
                    // Typing replaces only queued intent. The active metadata
                    // RPC owns this task until return; never cancel it to Find.
                    let page = try await session.page(offset: offset, sort: order, descending: reverse, find: find)
                    guard current(), page.generation == id, page.snapshot == snapshot else { continue }
                    try rows.accept(page, sort: order, descending: reverse)
                    if isVisible { browser?.renderSFTPStatus(session.latest) }
                } catch is RemoteDirectoryFindFailure {
                    if current(), let query { queuedOffset = nil; rows.failFind(query) }
                    if isVisible { browser?.renderSFTPStatus(session.latest) }
                } catch {
                    ApplicationDiagnostics.shared.event(.remoteBrowse, .failed, error: DiagnosticErrors.project(error))
                    if !isClosing, id == readID { observe(session.latest) }
                }
                if isVisible { browser?.renderSFTPStatus(session.latest) }
            }
        }
    }
    @discardableResult func close() -> Task<SFTPWorkerClose, Never> {
        browser?.clearRemoteClipboard(for: self)
        if let closing { return closing }; ApplicationRemoteTextEditors.shared.connectionWillClose(connectionID); isClosing = true; references.close(); queuedOffset = nil
        updates?.cancel(); navigation?.cancel(); pageTask?.cancel()
        sourceObservation?.finishWaiting(); sourceRestoration?.cancel()
        rows.onPage = nil; rows.onOpen = nil; rows.onSort = nil; rows.onRefresh = nil; rows.onStop = nil; rows.onDisconnect = nil
        rows.onBack = nil; rows.onUp = nil; rows.onHome = nil; rows.table.onShortcut = nil; rows.table.onFocus = nil
        rows.onServerCopy = nil; rows.onDuplicate = nil; rows.serverCopyAllowed = nil
        rows.onProperties = nil; rows.onCopyName = nil; rows.onCopyPath = nil
        rows.canInspect = nil; rows.canCopyName = nil; rows.canCopyPath = nil
        rows.onEditText = nil; rows.editTextAllowed = nil; rows.nativeOpenAllowed = nil; rows.openingAppearanceForEntry = nil
        rows.onViewText = nil; rows.viewTextAllowed = nil; rows.onNativeTextOpen = nil
        rows.onDownload = nil; rows.onDownloadToPane = nil
        rows.downloadAllowed = nil; rows.paneDownloadAllowed = nil
        rows.onUpload = nil; rows.uploadAllowed = nil
        rows.onUploadFolder = nil; rows.folderUploadAllowed = nil; rows.onUploadHistory = nil
        rows.onDropPreview = nil; rows.onDropFiles = nil
        rows.onCopyFile = nil; rows.copyFileAllowed = nil; rows.table.onCopy = nil; rows.table.copyAllowed = nil
        rows.onPaste = nil; rows.pasteAllowed = nil; rows.table.onPaste = nil; rows.table.pasteAllowed = nil
        if let browser, browser.sftpTabs[browser.activeID] === self { browser.inlineRename.cancel() }
        rows.onSelectionChanged = nil
        rows.onNewFile = nil; rows.newFileAllowed = nil
        rows.table.onNameClickRename = nil; rows.table.nameClickRenameEnabled = nil
        rows.onNewFolder = nil; rows.onRename = nil; rows.onMove = nil; rows.onDeletePermanently = nil; rows.onActionHistory = nil
        rows.newFolderAllowed = nil; rows.renameAllowed = nil; rows.renameExplanation = nil; rows.moveAllowed = nil; rows.moveExplanation = nil; rows.deleteAllowed = nil
        let draining = SFTPBrowserLifetimes.shared.close(session)
        let task = Task { [self] in
            let value = await draining.value; drain = value
            ApplicationRemoteTextEditors.shared.connectionDidDrain(connectionID, actual: value)
            if !value.localResourcesEnded {
                closing = nil
                rows.onDisconnect = { [weak self] in _ = self?.close() }
            }
            browser?.finishSFTPDisconnect(self, result: value); if value.localResourcesEnded { browser = nil }
            return value
        }
        closing = task
        return task
    }
}
