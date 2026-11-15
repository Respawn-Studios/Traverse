import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// Only the exact, fully consumed move clipboard may be cleared on completion.
struct MoveClipboardContext {
    let changeCount: Int
    let sources: [URL]
    let operationSources: [URL]
    let revision: UUID
}

@MainActor
extension BrowserViewController {
    var canModifyCurrentFolder: Bool {
        !isBrowserSuspended && !isOfflineCurrentFolder && !isReadOnlyFileSession && !metadataSearch.isShowingResults && location.directoryURL != nil && operationTask == nil && operationPreparationTask == nil
            && cutPreparationTask == nil && !isLoading && view.window?.attachedSheet == nil
            && operationCoordinator.activeOwner == nil && operationCoordinator.preparationOwner == nil
            && operationCoordinator.transfers.canRunExclusiveCommand
            && hasFileCommandFocus
    }

    var canTrashCurrentSelection: Bool {
        if isArchiveLocation {
            // The Delete command here rewrites the checked ZIP. It never
            // submits a system Trash request or uses that feature's policy.
            return ZIPOriginalUpdateFeature.available && hasFileCommandFocus && !isBrowserSuspended
                && view.window?.attachedSheet == nil && !(view.window?.firstResponder is NSTextView)
                && currentArchive?.canRemoveFromCopy == true
        }
        return canModifyCurrentFolder && currentTrashSelectionSupported
    }

    /// The kind/policy check is also used after our own preparation has reserved
    /// the command. Requiring an idle browser again would reject that reservation.
    private var currentTrashSelectionSupported: Bool {
        guard !orderedSelectedURLs.isEmpty else { return false }
        switch NativeLocalProtectionPolicy.trashPolicy {
        case .held: return false
        case .existingVerifiedPaths: return true
        case .regularFilesOnly:
            return orderedSelectedURLs.allSatisfy { url in
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
                return displayedEntries[row].kind == .file
            }
        case .regularFilesAndDirectories:
            return orderedSelectedURLs.allSatisfy { url in
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
                let kind = displayedEntries[row].kind
                return kind == .file || kind == .directory
            }
        }
    }

    var hasFileCommandFocus: Bool {
        guard isActiveCommandPane else { return false }
        #if DEBUG
        if isVerificationSession && permitsBackgroundVerification { return true }
        #endif
        guard let window = view.window else { return false }
        return NSApplication.shared.keyWindow === window
    }


    func clearCutSelection() {
        let selected = selectedURLs
        clipboardState.clear()
        renderTransferFeedback()
        reloadFileRows(preserving: selected)
    }

    func reloadFileRows(preserving selection: Set<URL>) {
        let previous = updatingSelection
        updatingSelection = true
        refreshFilePresentation(selection: selection, scrollOffset: currentScrollOffset)
        updatingSelection = previous
    }

    @objc func cutFileURLs(_ sender: Any?) {
        if isArchiveLocation { captureArchiveClipboard(.move); return }
        if isRemoteLocation { cutRemoteSelection(); return }
        guard canPrepareTransferClipboard, !orderedSelectedURLs.isEmpty else { return }
        let urls = orderedSelectedURLs
        clearCutSelection()
        let revision = clipboardRevision
        let tab = activeID, visit = sessionID
        let state = clipboardState
        let board = transferPasteboard
        let feedbackID = transferFeedback?.id
        let pasteboardChange = board.changeCount
        cutPreparationTask = Task { [weak self, fileOperations] in
            guard let self else { return }
            let lifetime = await self.accessLifetime(for: urls)
            defer {
                withExtendedLifetime(lifetime) {}
                if self.clipboardState === state, self.clipboardRevision == revision { self.cutPreparationTask = nil }
            }
            do {
                let selection = try await fileOperations.observeSelection(urls)
                let stillCurrent = {
                    !Task.isCancelled && !self.isBrowserSuspended && self.activeID == tab && self.sessionID == visit
                        && self.clipboardState === state && self.transferPasteboard === board
                        && self.clipboardRevision == revision && self.transferFeedback?.id == feedbackID
                }
                guard board.changeCount == pasteboardChange, stillCurrent() else { return }
                let publication = self.clipboardWriter(nil, selection.urls)
                let publishedGeneration: Int?
                switch publication {
                case .files(let receipt):
                    publishedGeneration = receipt.urls == selection.urls && receipt.isCurrent(on: board) ? receipt.changeCount : nil
                case .unownedFiles(let proof):
                    publishedGeneration = selection.urls.count > 1024 && proof.isCurrent(on: board) ? proof.changeCount : nil
                case .text, .failed:
                    publishedGeneration = nil
                }
                @MainActor func refusePublication() {
                    // A writer/native read may have installed a newer Copy.
                    guard stillCurrent() else { return }
                    self.clearCutSelection()
                    self.status.stringValue = "The file references could not be placed on the clipboard. Try again."
                }
                guard stillCurrent() else { return }
                guard let publishedGeneration else { refusePublication(); return }
                // Cut always decodes native references; publication is provenance,
                // never an owned Copy cache or source/access observation.
                guard let capture = BrowserClipboard.readFiles(from: board, isCurrent: stillCurrent),
                      capture.urls == selection.urls, capture.changeCount == publishedGeneration,
                      capture.isCurrent(on: board) else { refusePublication(); return }
                // Last native IPC has returned; fence local context before install.
                guard stillCurrent() else { return }
                self.pendingCut = selection
                self.pendingCutChangeCount = capture.changeCount
                self.cutURLs = Set(urls)
                self.transferFeedback = TransferClipboardFeedback(intent: .move, urls: selection.urls,
                    changeCount: capture.changeCount)
                state.beginObservation()
                self.reloadFileRows(preserving: self.selectedURLs)
                self.renderTransferFeedback()
            } catch {
                if !Task.isCancelled { self.showOperationError(error) }
            }
        }
    }

    @objc func pasteFileURLs(_ sender: Any?) {
        if pasteScopedItem() { return }
        if isArchiveLocation { pasteLocalCopiesIntoArchive(); return }
        if isSFTPLocation, let owner = sftpTabs[activeID] { _ = sftpDropUpload.pasteClipboard(to: owner); return }
        if isSMBLocation, let owner = smbTabs[activeID] { _ = smbUpload.pasteClipboard(to: owner); return }
        guard canAdmitTransfer, let destination = location.directoryURL else { return }
        pasteFiles(into: destination)
    }

    @objc func pasteWithOptions(_ sender: Any?) {
        guard canAdmitTransfer, recoverableFileOperations != nil,
              !(view.window?.firstResponder is NSTextView), let destination = location.directoryURL else { return }
        pasteFiles(into: destination, chooseMetadata: true)
    }

    /// Finder's explicit Move Copied Items command observes clipboard sources
    /// before execution; text editing continues through the native responder.
    @objc func moveCopiedFiles(_ sender: Any?) {
        guard canAdmitTransfer, !(view.window?.firstResponder is NSTextView),
              let destination = location.directoryURL else { return }
        pasteFiles(into: destination, forceMove: true)
    }

    var selectedFolderURL: URL? {
        guard selectedItemCount == 1, let url = orderedSelectedURLs.first,
              let row = rowsByURL[url], displayedEntries.indices.contains(row), displayedEntries[row].kind == .directory else { return nil }
        return url
    }

    @objc func pasteIntoSelection(_ sender: Any?) {
        guard canAdmitTransfer, let destination = selectedFolderURL else { return }
        pasteFiles(into: destination)
    }

    func pasteFiles(into destination: URL, forceMove: Bool = false, chooseMetadata: Bool = false) {
        let diagnostic = ApplicationDiagnostics.shared.workflow(.browse, context: .init(.clipboardCapture))
        guard !hasScopedItemPasteboardType else {
            diagnostic.event(.blocked, context: .init(.clipboardCapture))
            status.stringValue = "Paste this item in another folder in its original server tab."
            return
        }
        guard canAdmitTransfer else {
            let state = ApplicationDiagnostics.shared.dispatchSnapshot(self)
            diagnostic.event(.blocked, context: .init(.queueAdmission, flags: (state?.flags ?? []) + [.queueUnavailable],
                queueDepth: state?.queueDepth.map(Int.init)))
            return
        }
        synchronizeTransferClipboard()
        guard let capture = clipboardState.readFiles(allowOwnedCopy: !forceMove && pendingCut == nil) else {
            status.stringValue = "The clipboard changed. Choose Paste or Move Copied Items again."
            diagnostic.event(.blocked, context: .init(.clipboardCapture, flags: [.clipboardChanged]))
            return
        }
        let urls = capture.urls
        guard !urls.isEmpty else {
            status.stringValue = "Copy files or folders before pasting here."
            diagnostic.event(.blocked, context: .init(.clipboardCapture, flags: [.clipboardEmpty]), count: 0)
            return
        }
        diagnostic.event(.completed, context: .init(.clipboardCapture), count: UInt64(urls.count))
        let pasteboardChange = capture.changeCount
        let cut = pendingCutChangeCount == pasteboardChange && pendingCut?.urls == urls ? pendingCut : nil
        if cut == nil && pendingCut != nil { clearCutSelection() }
        let tab = activeID, visit = sessionID
        let revision = clipboardRevision
        let metadata = settings.transferMetadata.policy
        let copyExecution = settings.copyExecutionRequest
        if let engine = recoverableFileOperations {
            guard capture.isCurrent(on: transferPasteboard) else {
                diagnostic.event(.blocked, context: .init(.clipboardCapture, flags: [.clipboardChanged]))
                return
            }
            let move = forceMove || cut != nil
            let context = move ? MoveClipboardContext(changeCount: pasteboardChange,
                sources: urls, operationSources: cut?.urls ?? urls, revision: revision) : nil
            let admitted = operationCoordinator.transfers.enqueue(sources: urls, destination: destination,
                move: move, title: move ? "Moving items…" : "Copying items…", origin: self, engine: engine,
                observation: cut, clipboard: context, metadataPolicy: metadata,
                copyExecution: move ? .standard : copyExecution, chooseMetadata: chooseMetadata)
            status.stringValue = admitted == nil ? "The transfer queue is full or another command is active."
                : "\(move ? "Move" : "Copy") added to the queue."
            diagnostic.event(admitted == nil ? .blocked : .admitted,
                context: .init(.queueAdmission, flags: admitted == nil ? [.queueUnavailable] : [],
                    queueDepth: operationCoordinator.transfers.state.waiting.count), count: UInt64(urls.count))
            return
        }
        prepareOperation(observing: [destination], directory: true) { browser, observation, preparedAccess in
            guard capture.isCurrent(on: browser.transferPasteboard) else {
                browser.status.stringValue = "The clipboard changed. Choose Paste or Move Copied Items again."
                diagnostic.event(.blocked, context: .init(.clipboardCapture, flags: [.clipboardChanged]))
                return
            }
            let policy: TransferMetadataPolicy
            if chooseMetadata {
                guard let chosen = await browser.chooseTransferMetadata(default: metadata) else { return }
                policy = chosen
            } else { policy = metadata }
            let moveSelection: FileOperationSelection?
            if forceMove && cut == nil {
                do {
                    let lifetime = await browser.accessLifetime(for: urls)
                    defer { withExtendedLifetime(lifetime) {} }
                    moveSelection = try await browser.fileOperations.observeSelection(urls)
                } catch { browser.showOperationError(error); return }
            } else { moveSelection = cut }
            guard !Task.isCancelled, !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                  capture.isCurrent(on: browser.transferPasteboard) else { return }
            let request: FileOperationRequest = moveSelection.map { .moveObserved(selection: $0, destinationDirectory: destination) }
                ?? .copy(sources: urls, destinationDirectory: destination)
            browser.beginFileOperation(request, title: moveSelection == nil ? "Copying items…" : "Moving items…",
                                       roots: urls + [destination], observing: observation,
                                       moveClipboard: moveSelection.map { MoveClipboardContext(changeCount: pasteboardChange,
                                           sources: urls, operationSources: $0.urls, revision: revision) }, metadataPolicy: policy,
                                       copyExecution: moveSelection == nil ? copyExecution : .standard,
                                       retaining: preparedAccess)
        }
    }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        guard !isMetadataAccessQualification else { return }
        guard let url = selectedFolderURL else { return }
        newTab(nil)
        navigate(to: .directory(url))
        focusBrowserContent()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard !isMetadataAccessQualification else { return }
        let urls = orderedSelectedURLs.isEmpty ? location.directoryURL.map { [$0] } ?? [] : orderedSelectedURLs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func openContainingFolder(_ sender: Any?) {
        guard metadataSearch.isShowingResults, orderedSelectedURLs.count == 1,
              let selected = orderedSelectedURLs.first else { return }
        // Opening the parent is an ordinary fresh navigation; the search hint
        // grants no access, mutation or launch authority over the old result.
        navigate(to: .directory(selected.deletingLastPathComponent()))
        tabs[activeIndex].state.selection = [selected]
        focusBrowserContent()
    }

    var canCreateTextFile: Bool {
        if isArchiveLocation { return currentArchive?.canCreateFile == true }
        return LocalTextEditorFeature.ordinaryEnabled && canModifyCurrentFolder && recoverableFileOperations != nil
            && ApplicationLocalTextEditors.shared.documentReservationCount
                + ApplicationRemoteTextEditors.shared.allTextReservationCount < 4
    }

    @objc func createTextFile(_ sender: Any?) {
        if isArchiveLocation { currentArchive?.createFile(); return }
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpNewFile.request(from: owner); return }
        if isSMBLocation, let owner = smbTabs[activeID] { smbNewItems.request(.textFile, from: owner); return }
        guard canCreateTextFile else { return }
        ApplicationLocalTextEditors.shared.createTextFile(from: self)
    }

    @objc func createFolder(_ sender: Any?) {
        if isArchiveLocation { currentArchive?.createFolder(); return }
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpFileActions.request(.newFolder, from: owner); return }
        if isSMBLocation, let owner = smbTabs[activeID] { smbNewItems.request(.folder, from: owner); return }
        guard canModifyCurrentFolder, let parent = location.directoryURL else { return }
        let named = (sender as? NSMenuItem)?.representedObject as? String == "named-local-folder"
        let tab = activeID, visit = sessionID, presentation = filePresentationID
        let rename = named ? nil : inlineRename.reserveCreatedFolder(in: parent)
        prepareOperation(observing: [parent], directory: true, onFinish: { [weak self] in
            self?.inlineRename.creationPreparationFinished(rename)
        }) { browser, observation, preparedAccess in
            let name: String
            if named {
                guard let chosen = await browser.promptForName(title: "New Folder", initial: "New Folder") else { return }
                name = chosen
            } else {
                do { name = try await LocalAvailableName.available(in: parent, preferredName: "New Folder") }
                catch { if !Task.isCancelled { browser.showOperationError(error) }; return }
                guard !Task.isCancelled, browser.location.directoryURL == parent,
                      browser.activeID == tab, browser.sessionID == visit, browser.filePresentationID == presentation,
                      rename == nil || browser.inlineRename.canAdmitCreatedFolder(rename) else { return }
            }
            browser.beginFileOperation(.createFolder(parent: parent, name: name), title: "Creating folder…", roots: [parent],
                                       observing: observation, retaining: preparedAccess, createdFolderRename: rename)
        }
        if operationPreparationTask == nil { inlineRename.creationPreparationFinished(rename) }
    }

    @objc func renameSelection(_ sender: Any?) {
        renameCurrentSelection(requiringContentFocus: false)
    }

    func renameCreatedFolderSelection() {
        renameCurrentSelection(requiringContentFocus: true)
    }

    private func renameCurrentSelection(requiringContentFocus: Bool) {
        if isSMBLocation, let owner = smbTabs[activeID] { smbFileActions.request(.rename, from: owner); return }
        if isArchiveLocation { currentArchive?.renameSelection(); return }
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpFileActions.requestRename(from: owner); return }
        guard canModifyCurrentFolder, orderedSelectedURLs.count == 1, let source = orderedSelectedURLs.first else { return }
        let entry = rowsByURL[source].flatMap { row in displayedEntries.indices.contains(row) ? displayedEntries[row] : nil }
        // Foundation may normalize URL path components. The listing retains the
        // stored filename bytes, including intentional Unicode spelling changes.
        let name = entry?.name ?? source.lastPathComponent
        let ordinaryFile = entry?.kind == .file
        let tab = activeID, visit = sessionID, presentation = filePresentationID
        let requestID = inlineRename.reserve(source: source, requiresContentFocus: requiringContentFocus)
        prepareOperation(observing: [source], onFinish: { [weak self] in self?.inlineRename.cancel(requestID: requestID) }) { browser, observation, preparedAccess in
            let answer: String?
            if let prompt = browser.operationNamePrompt { answer = await prompt("Rename", name) }
            else { answer = await browser.inlineRename.begin(source: source, name: name, ordinaryFile: ordinaryFile, requestID: requestID) }
            guard let name = answer,
                  !Task.isCancelled, !browser.isBrowserSuspended, browser.isActiveCommandPane,
                  browser.activeID == tab, browser.sessionID == visit, browser.filePresentationID == presentation,
                  browser.selectedURLs == [source], !browser.metadataSearch.isShowingResults,
                  browser.inlineRename.consume(requestID: requestID, source: source) else { return }
            browser.beginFileOperation(.rename(source: source, name: name), title: "Renaming item…", roots: [source],
                                       observing: observation, retaining: preparedAccess)
        }
    }

    var trashCommandTitle: String {
        if isArchiveLocation && ZIPOriginalUpdateFeature.available { return "Remove from ZIP…" }
        if isArchiveLocation || isRemoteLocation { return "Move to Trash…" }
        return settings.asksBeforeMovingToTrash ? "Move to Trash…" : "Move to Trash"
    }

    @objc func trashSelection(_ sender: Any?) {
        if isArchiveLocation {
            if canTrashCurrentSelection { currentArchive?.removeSelection() }
            return
        }
        guard canTrashCurrentSelection else {
            status.stringValue = OrdinaryNativeTrashFeature.moveHoldMessage
            return
        }
        if GeneratedSandboxReview.ownedTrashRequested,
           !GeneratedSandboxReview.ownedTrashSourceAllowed(orderedSelectedURLs) { return }
        let urls = orderedSelectedURLs
        let tab = activeID, visit = sessionID, originalLocation = location
        // The gesture captures its confirmation policy. A controlled caller's
        // explicit override remains authoritative even when the default is direct.
        let asksBeforeMoving = settings.asksBeforeMovingToTrash
        let injectedPrompt = operationTrashPrompt
        prepareOperation(observing: urls) { browser, observation, preparedAccess in
            guard let preparation = browser.operationPreparationID else { return }
            let confirmed: Bool
            if let injectedPrompt { confirmed = await injectedPrompt(urls.count) }
            else if !asksBeforeMoving { confirmed = true }
            else if let window = browser.view.window {
                let alert = NSAlert()
                alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to Trash?" : "Move \(urls.count) items to Trash?"
                alert.informativeText = "You can restore them from the system Trash."
                alert.addButton(withTitle: "Move to Trash")
                alert.addButton(withTitle: "Cancel")
                confirmed = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
            } else { confirmed = false }
            guard confirmed else { return }
            guard !Task.isCancelled, !browser.isBrowserSuspended, !browser.isReadOnlyFileSession,
                  !browser.isOfflineCurrentFolder, !browser.metadataSearch.isShowingResults, !browser.isLoading,
                  browser.operationTask == nil, browser.activeID == tab, browser.sessionID == visit,
                  browser.location == originalLocation, browser.isActiveCommandPane,
                  browser.operationPreparationID == preparation,
                  browser.operationCoordinator.preparationOwner == preparation,
                  browser.orderedSelectedURLs == urls, browser.currentTrashSelectionSupported else {
                browser.status.stringValue = "The selection changed. Nothing was moved to Trash."
                return
            }
            browser.beginFileOperation(.trash(sources: urls), title: "Moving items to Trash…", roots: urls,
                                       observing: observation, retaining: preparedAccess)
        }
    }

    /// Observe before asking the user, and retain access through both the prompt
    /// and execution. A replacement occupant must never inherit that consent.
    func prepareOperation(observing urls: [URL], directory: Bool = false,
                          onFinish: (@MainActor () -> Void)? = nil,
                          action: @escaping @MainActor (BrowserViewController, FileOperationSelection, FileAccessLifetimes) async -> Void) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, operationPreparationTask == nil, operationTask == nil else { return }
        let preparationID = UUID()
        guard operationCoordinator.beginPreparation(owner: preparationID) else { return }
        operationPreparationID = preparationID
        let tab = activeID
        let visit = sessionID
        operationPreparationTask = Task { [weak self, fileOperations] in
            guard let self else { return }
            let lifetime = await self.accessLifetime(for: urls)
            defer {
                withExtendedLifetime(lifetime) {}
                self.operationPreparationTask = nil
                self.operationPreparationID = nil
                self.operationCoordinator.finishPreparation(owner: preparationID)
                onFinish?()
                self.consumePendingDirectoryRefresh()
            }
            do {
                let observation: FileOperationSelection
                if directory { observation = try await fileOperations.observeDirectory(urls[0]) }
                else { observation = try await fileOperations.observeSelection(urls) }
                guard !Task.isCancelled, !self.isBrowserSuspended, self.activeID == tab, self.sessionID == visit else { return }
                await action(self, observation, lifetime)
            } catch {
                if !Task.isCancelled { self.showOperationError(error) }
            }
        }
    }

    @objc func cancelFileOperation(_ sender: Any?) {
        if operationCoordinator.transfers.state.active != nil {
            operationCoordinator.transfers.stopActive()
            return
        }
        if let owner = workspace?.operationBrowser, owner !== self { owner.cancelFileOperation(sender); return }
        guard operationTask != nil else { return }
        operationStopRequested = true
        operationPresentation?.phaseTitle = "Stopping"
        operationPresentation?.stopping = true
        operationPresentation?.summary = "Stopping — finishing the current safe step. Completed changes are kept."
        updateOperationProgressControls()
        operationTask?.cancel()
    }

    func promptForName(title: String, initial: String, message: String? = nil,
                       lengthLimit: FilenamePrompt.LengthLimit = .utf8Bytes(255),
                       validating validation: ((String) -> String?)? = nil) async -> String? {
        if let prompt = operationNamePrompt { return await prompt(title, initial) }
        guard let window = view.window else { return nil }
        return await FilenamePrompt(title: title, initial: initial, message: message,
            lengthLimit: lengthLimit, validation: validation).choose(in: window)
    }

    func beginFileOperation(_ request: FileOperationRequest, title: String, roots: [URL], observing observation: FileOperationSelection? = nil,
                            moveClipboard: MoveClipboardContext? = nil, metadataPolicy: TransferMetadataPolicy = .strict,
                            copyExecution: CopyExecutionRequest = .standard, retaining retainedAccess: FileAccessLifetimes? = nil,
                            createdFolderRename: UUID? = nil) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, operationTask == nil else { return }
        if GeneratedSandboxReview.ownedTrashRequested {
            guard case .trash(let sources) = request,
                  GeneratedSandboxReview.ownedTrashSourceAllowed(sources),
                  recoverableFileOperations != nil else { return }
        }
        if let recoverable = recoverableFileOperations {
            beginRecoverableOperation(request, title: title, roots: roots, observing: observation, engine: recoverable,
                                      moveClipboard: moveClipboard, metadataPolicy: metadataPolicy, copyExecution: copyExecution,
                                      retaining: retainedAccess, createdFolderRename: createdFolderRename)
            return
        }
        guard metadataPolicy == .strict else { showOperationError(FileOperationFailure.unsupported); return }
        let initiatingTab = activeID
        let initiatingVisit = sessionID
        guard startOperationPresentation(title) else { return }
        lastOperationResult = nil
        operationTask = Task { [weak self, fileOperations] in
            guard let self else { return }
            defer { self.inlineRename.creationOperationFinished(createdFolderRename) }
            let lifetime = await self.accessLifetime(for: roots)
            defer { withExtendedLifetime(lifetime) {}; withExtendedLifetime(retainedAccess) {} }
            var effective = request
            do {
                let conflicts = try await fileOperations.conflicts(for: request, observing: observation)
                if !conflicts.isEmpty {
                    guard !Task.isCancelled, await self.confirmSkipping(conflicts) else {
                        self.finishOperationPresentation()
                        self.status.stringValue = "Operation cancelled before making changes."
                        return
                    }
                    guard let filtered = self.excludingConflicts(conflicts, from: request) else {
                        self.finishOperationPresentation()
                        self.status.stringValue = "All conflicting items were skipped."
                        return
                    }
                    effective = filtered
                }
                let result = await fileOperations.perform(effective, observing: observation)
                self.lastOperationResult = result
                self.lastTransferContinuation = nil
                self.continuationMoveClipboard = nil
                self.finishOperationPresentation()
                self.consumeMoveClipboard(moveClipboard, after: result)
                self.refreshDirectoryAfterOperation(result, initiatingTab: initiatingTab, visit: initiatingVisit,
                                                    createdFolderRename: createdFolderRename)
                self.presentOperationResult(result)
            } catch {
                self.finishOperationPresentation()
                if !(error is CancellationError) { self.showOperationError(error) }
            }
        }
    }

    /// Both journaled and ordinary operations replace the listing in place.
    /// Current rows stay visible during the read; they grant no new authority.
    func refreshDirectoryAfterOperation(_ result: FileOperationResult, initiatingTab: UUID, visit: UUID,
                                        createdFolderRename: UUID? = nil) {
        guard activeID == initiatingTab, sessionID == visit, let parent = location.directoryURL else { return }
        let destinations = result.items.compactMap { $0.status == .succeeded ? $0.destination : nil }
        let rename = inlineRename.prepareCreatedFolderRefresh(createdFolderRename, result: result)
        if createdFolderRename == nil || rename != nil {
            tabs[activeIndex].state.selection = Set(destinations.filter { $0.deletingLastPathComponent().path == parent.path })
        }
        tabs[activeIndex].state.scrollOffset = currentScrollOffset
        loadLocation(preservingVisibleRows: true, createdFolderRename: rename)
    }

    func consumeMoveClipboard(_ clipboard: MoveClipboardContext?, after result: FileOperationResult) {
        // Non-Move operations have no clipboard completion to render. Reloading
        // here would revoke a pending creation editor before its owned refresh.
        guard let clipboard else { return }
        clipboardState.consumeCompletedMove(clipboard, after: result)
        renderTransferFeedback()
        reloadFileRows(preserving: selectedURLs)
    }

    func finishOperationPresentation() {
        completedOperationDiagnosticTrace = operationDiagnosticTrace
        operationDiagnosticTrace = nil
        operationTask = nil
        endOperationProgressPresentation()
        validateNavigationButtons()
        consumePendingDirectoryRefresh()
    }

    func confirmSkipping(_ conflicts: [URL]) async -> Bool {
        if let prompt = operationConflictPrompt { return await prompt(conflicts) }
        guard let window = view.window else { return false }
        let alert = NSAlert()
        alert.messageText = "\(conflicts.count) destination item\(conflicts.count == 1 ? " already exists" : "s already exist")"
        alert.informativeText = conflicts.prefix(8).map(\.lastPathComponent).joined(separator: "\n") + "\n\nSkip these items and continue? Existing items will be kept."
        alert.addButton(withTitle: "Skip Conflicting Items")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    func excludingConflicts(_ conflicts: [URL], from request: FileOperationRequest) -> FileOperationRequest? {
        let names = Set(conflicts.map(\.lastPathComponent))
        switch request {
        case .copy(let sources, let destination):
            let remaining = sources.filter { !names.contains($0.lastPathComponent) }
            return remaining.isEmpty ? nil : .copy(sources: remaining, destinationDirectory: destination)
        case .move(let sources, let destination):
            let remaining = sources.filter { !names.contains($0.lastPathComponent) }
            return remaining.isEmpty ? nil : .move(sources: remaining, destinationDirectory: destination)
        case .moveObserved(let selection, let destination):
            let excluded = Set(selection.urls.filter { names.contains($0.lastPathComponent) })
            let remaining = selection.excluding(excluded)
            return remaining.urls.isEmpty ? nil : .moveObserved(selection: remaining, destinationDirectory: destination)
        default: return nil
        }
    }

    func presentOperationResult(_ result: FileOperationResult, recoveryAction: CopyRecoveryAction? = nil) {
        let trace = completedOperationDiagnosticTrace ?? operationDiagnosticTrace
        ApplicationDiagnostics.shared.recordOperationResult(result, trace: trace)
        completedOperationDiagnosticTrace = nil
        lastOperationResult = result
        operationHistory.diagnosticTrace = trace
        lastRecoveryAction = recoveryAction
        workspace?.browsers.values.forEach { $0.validateNavigationButtons() }
        operationResultsButton.isHidden = false
        operationResultsButton.isEnabled = canInspectLastOperationResult
        status.stringValue = OperationResultDescription(result: result, recoveryAction: recoveryAction).summary
        if let presenter = operationResultPresenter { presenter(result); return }
        guard result.disposition != .succeeded else { return }
        showOperationResultSheet(result, recoveryAction: recoveryAction)
    }

    func showOperationError(_ error: Error) {
        ApplicationDiagnostics.shared.recordOperationError(error)
        let message = (error as? FileOperationFailure)?.userMessage
            ?? (error as? StateDirectoryPreparationError)?.errorDescription ?? "The request could not be completed."
        if let presenter = operationErrorPresenter { presenter(message); return }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The operation could not start"
        alert.informativeText = message
        if (error as? FileOperationFailure) == .accessDenied {
            alert.informativeText += "\n\n" + OperationResultDescription.folderAccessExplanation
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Choose Folder Access…")
            let initial = location.directoryURL
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                DispatchQueue.main.async { self?.requestOperationFolderAccess(initialDirectory: initial) }
            }
        } else { alert.beginSheetModal(for: window) }
    }

    func fileResponderCommandEnabled(_ action: Selector?) -> Bool {
        synchronizeTransferClipboard()
        switch action {
        case #selector(FileTableView.undo(_:)): return canUndoFileOperation
        case #selector(FileTableView.cut(_:)): return commandEnabled(#selector(cutFileURLs(_:)), synchronizingClipboard: false)
        case #selector(FileTableView.copy(_:)): return commandEnabled(#selector(copyFileURLs(_:)), synchronizingClipboard: false)
        case #selector(FileTableView.paste(_:)): return commandEnabled(#selector(pasteFileURLs(_:)), synchronizingClipboard: false)
        default: return true
        }
    }
}
