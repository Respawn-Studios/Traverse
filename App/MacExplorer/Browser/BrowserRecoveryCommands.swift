import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    // A grouping summary is observational, never an Undo capability. Treat a
    // newer unresolved group as a review barrier rather than skipping it and
    // undoing an unrelated older operation. The typed facade rechecks authority.
    private enum FileUndoCandidate {
        case ordinary(OperationRecoveryRecord)
        case grouping(OperationRecoveryRecord, undo: Bool)
        case textVersions(OperationRecoveryRecord)
    }
    private var nextFileUndoCandidate: FileUndoCandidate? {
        for record in recoveryRecords {
            if record.kind == .textRevision {
                if ["undone", "notApplied"].contains(record.state) { continue }
                return .textVersions(record)
            }
            if record.kind == .selectionGroup {
                if ["undone", "closedRetained", "cleaned"].contains(record.state) { continue }
                return .grouping(record, undo: record.state == "completed")
            }
            if record.canUndo { return .ordinary(record) }
        }
        return nil
    }
    var canUndoFileOperation: Bool {
        if case .ordinary(let record)? = nextFileUndoCandidate,
           !NativeLocalProtectionPolicy.permitsTrashRecovery(record) {
            return false
        }
        return !isBrowserSuspended && !isReadOnlyFileSession && hasFileCommandFocus
            && (!isSFTPLocation || !sftpFileActions.blocksImplicitUndo)
            && (!isSMBLocation || !smbFileActions.blocksImplicitUndo)
            && !(view.window?.firstResponder is NSTextView) && canRunExclusiveFileCommand
            && view.window?.attachedSheet == nil && nextFileUndoCandidate != nil
    }

    func inspectOperationRecovery(loadMore: Bool = false) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, let engine = recoverableFileOperations else { return }
        let cursor = loadMore ? recoveryNextCursor : nil
        if loadMore && cursor == nil { return }
        let inspectionWindow = view.window
        let hadWindow = inspectionWindow != nil
        guard let inspectionToken = operationCoordinator.beginInspection() else { return }
        let coordinator = operationCoordinator
        recoveryInspectionTask?.cancel()
        recoveryInspectionTask = Task { [weak self, weak inspectionWindow] in
            defer { coordinator.finishInspection(inspectionToken) }
            do {
                let inspection = try await engine.inspectExistingHistory(after: cursor)
                #if DEBUG
                if let barrier = self?.beforeRecoveryInspectionReturnsForVerification { await barrier() }
                #endif
                guard let self, !Task.isCancelled, !self.isBrowserSuspended,
                      self.recoverableFileOperations === engine, self.view.window === inspectionWindow,
                      !hadWindow || inspectionWindow != nil else { return }
                if loadMore {
                    let existing = Set(self.recoveryRecords.map(\.id))
                    self.recoveryRecords += inspection.records.filter { !existing.contains($0.id) }
                } else { self.recoveryRecords = inspection.records }
                self.recoveryRecords.sort { $0.createdAt > $1.createdAt }
                self.recoveryNextCursor = inspection.nextCursor
                self.recoveryUnfinishedCount = inspection.unfinishedCount
                self.recoveryHistoryReadiness = inspection.readiness
                self.refusedRecoveryEntries = inspection.refusedEntries
                self.recoveryWindow?.update(records: self.recoveryRecords, refusedEntries: inspection.refusedEntries,
                                             hasMore: inspection.nextCursor != nil, unfinishedCount: inspection.unfinishedCount,
                                             historyMessage: self.operationHistoryMessage,
                                             canPrepareHistory: self.operationHistoryNeedsPreparation)
                if self.recoveryWindow?.isClosed == false { self.inspectRecoveryRetention() }
                if let message = self.operationHistoryMessage { self.status.stringValue = message }
                // Startup is observational. Unfinished history stays actionable
                // in the window without interrupting every independent launch.
                self.validateNavigationButtons()
            } catch {
                guard let self, !Task.isCancelled, !self.isBrowserSuspended,
                      self.recoverableFileOperations === engine, self.view.window === inspectionWindow,
                      !hadWindow || inspectionWindow != nil else { return }
                self.status.stringValue = "Operation recovery could not be read. Existing records were preserved."
                self.recoveryHistoryReadiness = .unavailable
                self.validateNavigationButtons()
            }
        }
    }

    var hasRecoveryAttention: Bool {
        guard settings.reviewsRecoveryAtStartup, !isReadOnlyFileSession else { return false }
        if recoveryUnfinishedCount > 0 || !refusedRecoveryEntries.isEmpty { return true }
        switch recoveryHistoryReadiness {
        case .absent, .available, .busy: return false
        default: return true
        }
    }

    @objc func showOperationRecovery(_ sender: Any?) {
        prepareOperationRecovery(presentingWindow: true)
    }
    @objc func showOwnedTrash(_ sender: Any?) {
        guard OwnedTrashFeature.browseAvailable else { return }
        ownedTrash.show()
    }
    private func prepareOperationRecovery(presentingWindow: Bool) {
        guard !isReadOnlyFileSession, recoverableFileOperations != nil else { return }
        if recoveryWindow == nil {
            recoveryWindow = OperationRecoveryWindowController(
                onUndo: { [weak self] record in self?.startRecoveryOperation(record, rollback: false) },
                onRecover: { [weak self] record in self?.startRecoveryOperation(record, rollback: true) },
                onRefresh: { [weak self] in self?.inspectOperationRecovery() },
                onCleanup: { [weak self] record in self?.confirmRecoveryCleanup(record) },
                onCompact: { [weak self] in self?.compactOperationJournal() },
                onInspectRetention: { [weak self] id in self?.inspectRecoveryRetention(id) },
                onLoadMore: { [weak self] in self?.inspectOperationRecovery(loadMore: true) },
                onReviewCopiedFiles: { [weak self] record in self?.openGroupedCopyRecovery(record) },
                onPrepareHistory: { [weak self] in self?.prepareOperationHistoryForReview(host: self?.recoveryWindow?.window) },
                onReviewGrouping: { [weak self] record in self?.showSelectionGroupResults(recordID: record.id) },
                onReviewTextVersions: LocalTextEditorFeature.ordinaryEnabled ? { [weak self] record in
                    guard let self else { return }
                    ApplicationLocalTextEditors.shared.review(record, from: self, in: self.recoveryWindow?.window)
                } : nil,
                onShowLogs: { [weak self] record in
                    guard let self else { return }
                    TraverseHelpController.shared.showOperationLogs(record.id, from: self)
                })
            recoveryWindow?.onSelectedRecordChange = { [weak self] id in
                guard let controller = self?.groupedCopyRecoveryWindow, controller.recordID != id else { return }
                controller.showUnavailable("The selected operation changed. Select this job in Operation Recovery and open its review again.")
            }
            recoveryWindow?.onClose = { [weak self] in
                self?.recoveryInspectionTask?.cancel()
                self?.retentionInspectionTask?.cancel()
                self?.retentionInspectionID = nil
                self?.groupedCopyRecoveryWindow?.close()
                self?.selectionGroupWindow?.close()
            }
        }
        recoveryWindow?.beginReview()
        if let window = recoveryWindow?.window { ToolWindowChrome.install(in: window, settings: settings) }
        recoveryWindow?.update(records: recoveryRecords, refusedEntries: refusedRecoveryEntries,
                               hasMore: recoveryNextCursor != nil, unfinishedCount: recoveryUnfinishedCount,
                               historyMessage: operationHistoryMessage,
                               canPrepareHistory: operationHistoryNeedsPreparation)
        if presentingWindow && !isControlledVerification {
            recoveryWindow?.showWindow(nil)
            recoveryWindow?.window?.makeKeyAndOrderFront(nil)
        }
        inspectOperationRecovery()
    }

    @objc func undoFileOperation(_ sender: Any?) {
        guard canUndoFileOperation, let candidate = nextFileUndoCandidate else { return }
        switch candidate {
        case .ordinary(let record): startRecoveryOperation(record, rollback: false)
        case .textVersions(let record): startRecoveryOperation(record, rollback: false)
        case .grouping(let record, let undo):
            if undo { beginSelectionGroupUndo(recordID: record.id) }
            else { showSelectionGroupResults(recordID: record.id) }
        }
    }

    /// Review one captured record through the current live browser. Inspection
    /// is bounded and observational; Undo/Restore still acquire the writer lane.
    func openOperationRecovery(recordID: UUID, presentingWindow: Bool = true,
                               onUnavailable: (() -> Void)? = nil,
                               onSelected: ((OperationRecoveryRecord) -> Void)? = nil) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, canRunExclusiveFileCommand,
              view.window?.attachedSheet == nil, let engine = recoverableFileOperations else { return }
        prepareOperationRecovery(presentingWindow: presentingWindow)
        guard let controller = recoveryWindow else { return }
        controller.requestSelection(recordID: recordID)
        guard let inspectionToken = operationCoordinator.beginInspection() else { return }
        let coordinator = operationCoordinator
        recoveryInspectionTask?.cancel()
        recoveryInspectionTask = Task { [weak self, weak controller] in
            defer { coordinator.finishInspection(inspectionToken) }
            var records: [OperationRecoveryRecord] = []
            var refused: [URL] = []
            var cursor: UUID?
            do {
                // A session retains at most sixteen jobs. Bound older-history
                // lookup too; the existing Load Earlier action remains explicit.
                for _ in 0..<16 {
                    let page = try await engine.inspectExistingHistory(after: cursor)
                    guard let self, let controller, !Task.isCancelled, !self.isBrowserSuspended,
                          self.recoveryWindow === controller, self.recoverableFileOperations === engine else { return }
                    let existing = Set(records.map(\.id))
                    records += page.records.filter { !existing.contains($0.id) }
                    refused += page.refusedEntries
                    cursor = page.nextCursor
                    self.recoveryRecords = records
                    self.refusedRecoveryEntries = refused
                    self.recoveryNextCursor = cursor
                    self.recoveryUnfinishedCount = page.unfinishedCount
                    controller.update(records: records, refusedEntries: refused,
                        hasMore: cursor != nil, unfinishedCount: page.unfinishedCount)
                    if let record = records.first(where: { $0.id == recordID }) {
                        self.inspectRecoveryRetention(recordID)
                        if controller.selectedRecordID == recordID { onSelected?(record) }
                        return
                    }
                    if cursor == nil { break }
                }
                guard let self, let controller, !Task.isCancelled, !self.isBrowserSuspended,
                      self.recoveryWindow === controller, self.recoverableFileOperations === engine else { return }
                controller.showRequestedRecordUnavailable(cursor == nil
                    ? "The requested operation is unavailable in this history. Its result and reported locations remain available; no recovery action has started."
                    : "The requested operation was not found in the first 1,024 records. Use Load Earlier Operations to inspect older history. No recovery action has started.")
                onUnavailable?()
            } catch {
                guard let self, let controller, !Task.isCancelled, !self.isBrowserSuspended,
                      self.recoveryWindow === controller, self.recoverableFileOperations === engine else { return }
                controller.showRequestedRecordUnavailable("The requested operation could not be read. Existing data was preserved; no recovery action has started.")
                onUnavailable?()
            }
        }
    }

    var operationHistoryMessage: String? {
        switch recoveryHistoryReadiness {
        case .absent, .available(catalogVersion: 3), .available(catalogVersion: 4), .available(catalogVersion: 7), .available(catalogVersion: 9), .available(catalogVersion: 10): nil
        case .available: "Earlier operation history is available. It will be updated only when you choose an operation."
        case .legacyImportRequired: "Earlier operation history is preserved and needs explicit preparation before review."
        case .initializationIncomplete: "Operation history setup is incomplete. Existing data was preserved."
        case .busy: "Operation history is in use. Refresh when it is available."
        case .recoveryRequired: "Operation history needs explicit recovery before it can be reviewed."
        case .inspectionLimited: "Operation history inspection could not finish. Existing history was preserved."
        case .changed: "Operation history changed during inspection. Refresh to inspect it again."
        case .unavailable: "Operation history could not be read. Existing records were preserved."
        }
    }

    var operationHistoryNeedsPreparation: Bool {
        switch recoveryHistoryReadiness {
        case .legacyImportRequired, .initializationIncomplete, .recoveryRequired, .available(catalogVersion: 2): true
        default: false
        }
    }

    func startRecoveryOperation(_ record: OperationRecoveryRecord, rollback: Bool,
                                presentsResult: Bool = true,
                                qaOwnedTrashOriginals: [URL]? = nil,
                                onComplete: ((RecoverableOperationResult) -> Void)? = nil) {
        if !NativeLocalProtectionPolicy.permitsTrashRecovery(record) {
            status.stringValue = OrdinaryNativeTrashFeature.recoveryHoldMessage
            showOperationRecovery(nil)
            return
        }
        let qaTrash = GeneratedSandboxReview.ownedTrashRequested
        if qaTrash {
            guard GeneratedSandboxReview.ownedTrashPhase == .resolve,
                  GeneratedSandboxReview.ownedTrashRuntimeReady,
                  !rollback, record.kind == .ordinary, record.operation == "Move to Trash",
                  record.canUndo, let originals = qaOwnedTrashOriginals,
                  GeneratedSandboxReview.ownedTrashGroupAllowed(originals),
                  originals.allSatisfy({ record.locations.contains($0) }) else { return }
        }
        if record.kind == .textRevision {
            guard !isBrowserSuspended, !isReadOnlyFileSession, canRunExclusiveFileCommand,
                  let host = view.window, host.attachedSheet == nil else { return }
            guard LocalTextEditorFeature.ordinaryEnabled else {
                status.stringValue = "This saved text change needs the editor’s version review. Its recorded versions are preserved."
                showOperationRecovery(nil)
                return
            }
            ApplicationLocalTextEditors.shared.review(record, from: self, in: host)
            return
        }
        if record.kind == .selectionGroup {
            if !rollback, record.canUndo { beginSelectionGroupUndo(recordID: record.id) }
            else { showSelectionGroupResults(recordID: record.id) }
            return
        }
        if record.kind == .groupedCopy {
            guard !rollback, record.canUndo, !isBrowserSuspended, !isReadOnlyFileSession,
                  canRunExclusiveFileCommand, let host = view.window, host.attachedSheet == nil,
                  let engine = recoverableFileOperations else { return }
            // Cmd-Z and the menu capture a job without an inspector selection.
            // Select that exact job through bounded fresh inspection before
            // presenting review; opening this review does not authorize Undo.
            openOperationRecovery(recordID: record.id, onSelected: { [weak self, weak host] selected in
                guard let self, let host, !self.isBrowserSuspended, !self.isReadOnlyFileSession,
                      self.view.window === host, host.attachedSheet == nil,
                      self.recoverableFileOperations === engine, self.canRunExclusiveFileCommand,
                      selected.id == record.id, selected.kind == .groupedCopy, selected.canUndo else { return }
                self.openGroupedCopyRecovery(selected)
            })
            return
        }
        guard !isBrowserSuspended, !isReadOnlyFileSession, canRunExclusiveFileCommand,
              let host = view.window, host.attachedSheet == nil,
              let engine = recoverableFileOperations,
              rollback ? (record.canRecover || record.canRestoreOriginalZIP) : record.canUndo else { return }
        if !isControlledVerification { host.makeKeyAndOrderFront(nil) }
        let tab = activeID, visit = sessionID
        let coordinator = operationCoordinator, preparation = UUID()
        guard coordinator.beginPreparation(owner: preparation) else { return }
        operationPreparationID = preparation
        status.stringValue = "Checking folder access…"
        operationPreparationTask = Task { [weak self, weak host] in
            guard let self else { coordinator.finishPreparation(owner: preparation); return }
            defer {
                coordinator.finishPreparation(owner: preparation)
                if self.operationPreparationID == preparation {
                    self.operationPreparationID = nil; self.operationPreparationTask = nil
                }
                self.validateNavigationButtons(); self.consumePendingDirectoryRefresh()
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !self.isBrowserSuspended && self.activeID == tab && self.sessionID == visit
                    && self.view.window === host && host?.attachedSheet == nil
                    && self.recoverableFileOperations === engine && coordinator.preparationOwner == preparation
            }
            do {
                guard isCurrent(), let host else { throw CancellationError() }
                let requirement = rollback ? nil : try await engine.undoAccessRequirement(recordID: record.id)
                guard isCurrent() else { throw CancellationError() }
                var leases = await self.accessLifetime(for: record.locations).leases
                if let requirement {
                    var selectionRequired = TraverseAccessPolicy.requiresFolderSelection
                    #if DEBUG
                    selectionRequired = selectionRequired || self.requiresUndoFolderSelectionForVerification
                    #endif
                    if selectionRequired && !self.folderAccess.hasSelectedAccess(to: requirement.directory) {
                        guard isCurrent() else { throw CancellationError() }
                        let choice: FolderAccessChoice?
                        #if DEBUG
                        if self.isVerificationSession, let choose = self.undoFolderSelectionForVerification {
                            choice = await choose(requirement.directory)
                        } else {
                            choice = await self.folderAccess.chooseFolder(in: host, initialDirectory: requirement.directory,
                                remember: true, purpose: .undoFileOperation, requiredDirectory: requirement.directory)
                        }
                        #else
                        choice = await self.folderAccess.chooseFolder(in: host, initialDirectory: requirement.directory,
                            remember: true, purpose: .undoFileOperation, requiredDirectory: requirement.directory)
                        #endif
                        guard isCurrent(), let choice else { throw CancellationError() }
                        guard choice.selection.url.isFileURL,
                              choice.selection.url.standardizedFileURL.pathComponents == requirement.directory.standardizedFileURL.pathComponents else {
                            throw FileOperationFailure.accessDenied
                        }
                        leases.append(choice.lease)
                        if case .saved = choice.remembering {
                            await self.refreshRememberedFolderReferences()
                        }
                    } else {
                        let lease = await self.folderAccess.acquireAccess(to: requirement.directory)
                        guard !selectionRequired || lease != nil else { throw FileOperationFailure.accessDenied }
                        if let lease { leases.append(lease) }
                    }
                    // The chooser is an access request, not permission to act
                    // on an old history projection. Re-read the exact record.
                    guard isCurrent(), try await engine.undoAccessRequirement(recordID: record.id) == requirement else {
                        throw CancellationError()
                    }
                }
                guard isCurrent() else { throw CancellationError() }
                guard self.beginPreparedRecoveryOperation(record, rollback: rollback, engine: engine,
                    preparation: preparation, lifetime: .init(leases: leases), tab: tab, visit: visit,
                    qaTrash: qaTrash, presentsResult: presentsResult, onComplete: onComplete) else {
                    throw FileOperationFailure.unavailable
                }
            } catch {
                // No inverse was submitted. In particular, cancelling a folder
                // grant must not turn a completed operation into Needs Review.
                let cancelled = error is CancellationError
                let outcome = RecoverableOperationResult(result: FileOperationResult(items: [
                    FileOperationOutcome(source: nil, destination: nil,
                        status: cancelled ? .cancelled : .failed((error as? FileOperationFailure) ?? .unsupported), recoveryURLs: [])
                ], cancellationRequested: cancelled), recordID: record.id)
                if !self.isBrowserSuspended, self.view.window === host, self.sessionID == visit {
                    let action = rollback ? "Restore" : "Undo"
                    self.status.stringValue = cancelled ? "\(action) was not started. Your files are unchanged."
                        : "Folder access could not be prepared. No \(action) started; the recorded operation is unchanged."
                }
                onComplete?(outcome)
            }
        }
        validateNavigationButtons()
    }

    private func beginPreparedRecoveryOperation(_ record: OperationRecoveryRecord, rollback: Bool,
                                               engine: RecoverableFileOperations, preparation: UUID,
                                               lifetime: FileAccessLifetimes, tab: UUID, visit: UUID,
                                               qaTrash: Bool, presentsResult: Bool,
                                               onComplete: ((RecoverableOperationResult) -> Void)?) -> Bool {
        let title = rollback ? (record.canRestoreOriginalZIP ? "Restoring original ZIP…" : "Restoring original state…")
            : "Undoing file operation…"
        guard startOperationPresentation(title, preparation: preparation) else { return false }
        // Transfer the existing preparation to the operation without yielding.
        // The actual worker retains all scope-bearing URLs through its unwind.
        operationPreparationTask = nil; operationPreparationID = nil
        operationTask = Task { [weak self, lifetime] in
            guard let self else { return }
            defer { withExtendedLifetime(lifetime) {} }
            let archiveLocations: [URL]?
            do {
                archiveLocations = try await engine.archiveUpdateReferenceLocations(recordID: record.id)
                if let archiveLocations {
                    try await ArchiveOriginalReferences.requireUnreferenced(archiveLocations,
                        names: self.privateNames, retaining: lifetime)
                }
                if qaTrash {
                    guard await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "before") else {
                        throw FileOperationFailure.unavailable
                    }
                }
                try Task.checkCancellation()
            } catch {
                // This is an admission refusal, not a new journal mutation.
                // Complete the ordinary owner/callback even when no engine
                // action starts, so the recovery window cannot stay busy.
                let cancelled = error is CancellationError
                let outcome = RecoverableOperationResult(result: FileOperationResult(items: [
                    FileOperationOutcome(source: nil, destination: nil,
                        status: cancelled ? .cancelled : .failed((error as? FileOperationFailure) ?? .unsupported), recoveryURLs: [])
                ], cancellationRequested: cancelled), recordID: record.id)
                self.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit, presentsResult: false)
                let message = qaTrash && !cancelled ? "QA container accounting failed before Restore. No Restore action began."
                    : cancelled ? "Stopped before changing any files."
                    : (error as? ArchiveOriginalReferences.Failure)?.message
                        ?? "This operation could not be checked. Its files and saved versions remain protected."
                self.status.stringValue = message
                self.recoveryWindow?.showRequestedRecordUnavailable(message)
                onComplete?(outcome)
                return
            }
            let names = rollback ? nil : await self.privateNames.prepareMoveUndoNames(operationID: record.id, engine: engine)
            let outcome: RecoverableOperationResult
            if rollback, record.canRestoreOriginalZIP {
                outcome = await engine.restoreInterruptedOriginalZIP(recordID: record.id, progress: self.operationProgressSink)
            } else if rollback {
                outcome = await engine.recover(recordID: record.id, progress: self.operationProgressSink)
            } else {
                outcome = await engine.undo(recordID: record.id, progress: self.operationProgressSink)
            }
            var qaCounted = true
            if qaTrash {
                qaCounted = await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "after")
                if outcome.result.disposition != .succeeded {
                    GeneratedSandboxReview.stopOwnedTrashQualification()
                }
            }
            await self.privateNames.finishMoveNames(names, engine: engine)
            var v7ContainerVerified = true
            if !rollback, record.operation == "Download", GeneratedSandboxReview.v7DownloadAdmitted {
                v7ContainerVerified = await GeneratedSandboxReview.accountV7Container(phase: "after")
            }
            self.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit, presentsResult: presentsResult)
            if !v7ContainerVerified {
                self.status.stringValue = "QA container accounting is incomplete after Undo. Stop this qualification and review the recorded result."
            }
            if !qaCounted {
                self.status.stringValue = "QA container accounting is incomplete after Restore. Stop this qualification and review the recorded result."
            }
            if let original = archiveLocations?.first {
                ArchiveOriginalReferences.refresh(original, in: self.operationCoordinator)
            }
            onComplete?(outcome)
        }
        return true
    }

    /// Historical review is bound to a live pane, engine and selected record,
    /// rather than to the folder or tab that happens to be browsed now.
    func openGroupedCopyRecovery(_ record: OperationRecoveryRecord) {
        guard record.kind == .groupedCopy, !isBrowserSuspended, !isReadOnlyFileSession,
              let engine = recoverableFileOperations, let host = view.window,
              let history = recoveryWindow, history.selectedRecordID == record.id else { return }
        if let old = groupedCopyRecoveryWindow, old.recordID != record.id || old.isClosed { old.close() }
        if groupedCopyRecoveryWindow == nil {
            let controller = GroupedCopyRecoveryWindowController(recordID: record.id,
                onAction: { [weak self] action, review, generation in
                    self?.startGroupedCopyRecovery(action: action, review: review, presentationID: generation)
                }, onUndo: { [weak self] review, generation in
                    self?.startGroupedCopyRecovery(action: nil, review: review, presentationID: generation)
                }, onRefresh: { [weak self] in
                    guard let self, let controller = self.groupedCopyRecoveryWindow,
                          let record = self.recoveryRecords.first(where: { $0.id == controller.recordID }),
                          let engine = self.recoverableFileOperations, let host = self.view.window,
                          let history = self.recoveryWindow else { return }
                    self.refreshGroupedCopyRecovery(record, controller: controller, engine: engine, host: host, history: history)
                })
            controller.onClose = { [weak self, weak controller] in
                if self?.groupedCopyRecoveryWindow === controller { self?.groupedCopyRecoveryWindow = nil }
            }
            controller.hostObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: host) { [weak controller] _ in
                Task { @MainActor [weak controller] in controller?.close() }
            }
            groupedCopyRecoveryWindow = controller
        }
        guard let controller = groupedCopyRecoveryWindow else { return }
        if let window = controller.window { ToolWindowChrome.install(in: window, settings: settings) }
        if !isControlledVerification { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        if !controller.isBusy {
            refreshGroupedCopyRecovery(record, controller: controller, engine: engine, host: host, history: history)
        }
    }

    private func groupedReviewIsCurrent(_ controller: GroupedCopyRecoveryWindowController,
        engine: RecoverableFileOperations, host: NSWindow, history: OperationRecoveryWindowController) -> Bool {
        !isBrowserSuspended && !isReadOnlyFileSession && view.window === host
            && recoverableFileOperations === engine && recoveryWindow === history
            && history.selectedRecordID == controller.recordID
            && groupedCopyRecoveryWindow === controller && !controller.isClosed
    }

    private var groupedReviewAccessRoots: [URL] {
        (location.directoryURL.map { [$0] } ?? []) + rememberedFolders.compactMap(\.url)
    }

    private func refreshGroupedCopyRecovery(_ record: OperationRecoveryRecord,
        controller: GroupedCopyRecoveryWindowController, engine: RecoverableFileOperations,
        host: NSWindow, history: OperationRecoveryWindowController) {
        guard groupedReviewIsCurrent(controller, engine: engine, host: host, history: history),
              !controller.isBusy else { return }
        guard let inspectionToken = operationCoordinator.beginInspection() else { return }
        let coordinator = operationCoordinator
        let generation = controller.beginLoading()
        let roots = record.locations + groupedReviewAccessRoots
        controller.inspectionTask = Task { [weak self, weak controller] in
            defer { coordinator.finishInspection(inspectionToken) }
            guard let self, let controller else { return }
            let access = await self.accessLifetime(for: roots)
            defer { withExtendedLifetime(access) {} }
            do {
                guard !Task.isCancelled, controller.inspectionID == generation,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else { return }
                let review = try await engine.prepareGroupedRecovery(recordID: record.id)
                guard !Task.isCancelled, controller.inspectionID == generation,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else { return }
                guard review.items.count <= 1024 else {
                    controller.showUnavailable("This job exceeds the review limit. Existing files remain preserved."); return
                }
                let itemAccess = await self.accessLifetime(for: review.items.flatMap {
                    [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
                })
                guard !Task.isCancelled, controller.inspectionID == generation,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else { return }
                controller.update(review, retaining: FileAccessLifetimes(leases: access.leases + itemAccess.leases))
                controller.inspectionTask = nil
            } catch {
                guard !Task.isCancelled, controller.inspectionID == generation,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else { return }
                controller.showUnavailable("Current copied-file evidence could not be read. Check folder access and refresh the review. Existing data remains preserved.")
            }
        }
    }

    private static func sameGroupedReview(_ lhs: GroupedCopyRecoveryReview, _ rhs: GroupedCopyRecoveryReview) -> Bool {
        lhs.recordID == rhs.recordID && lhs.revision == rhs.revision && lhs.state == rhs.state
            && lhs.availableActions == rhs.availableActions && lhs.canUndo == rhs.canUndo
            && lhs.items.count == rhs.items.count && zip(lhs.items, rhs.items).allSatisfy { pair in
                let (left, right) = pair
                return left.id == right.id && left.source == right.source && left.destination == right.destination
                    && left.state == right.state && left.protectionReason == right.protectionReason
            }
    }

    /// A nil action requests a fresh guarded Undo. Confirmation consumes the
    /// displayed opaque token; a replacement inspection never grants consent.
    private func startGroupedCopyRecovery(action: CopyRecoveryAction?, review: GroupedCopyRecoveryReview,
                                          presentationID: UUID) {
        guard let controller = groupedCopyRecoveryWindow, let history = recoveryWindow,
              let engine = recoverableFileOperations, let host = view.window,
              groupedReviewIsCurrent(controller, engine: engine, host: host, history: history),
              controller.presentationID == presentationID, controller.review?.revision == review.revision,
              !controller.isBusy else { return }
        guard canRunExclusiveFileCommand, host.attachedSheet == nil, controller.window?.attachedSheet == nil else {
            controller.showNotice("Another operation or dialog is active. Finish it, then choose this action again."); return
        }
        guard action.map({ review.availableActions.contains($0) }) ?? review.canUndo else { return }
        let title = action?.title ?? "Undo Verified Copies"
        guard startOperationPresentation(title + "…") else { return }
        let writer = operationPresentationID
        let tab = activeID, visit = sessionID
        let retainedAccess = controller.retainedAccess
        controller.setWorking("Rechecking current evidence before \(title.lowercased())…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            let access = await self.accessLifetime(for: review.items.flatMap {
                [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
            })
            defer { withExtendedLifetime(access) {}; withExtendedLifetime(retainedAccess) {} }
            do {
                guard !Task.isCancelled, self.operationPresentationID == writer,
                      controller.presentationID == presentationID,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else {
                    if self.operationPresentationID == writer { self.finishOperationPresentation() }
                    if self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) {
                        controller.showUnavailable("Review stopped before an action began. Refresh to inspect current evidence.")
                    }
                    return
                }
                let fresh = try await engine.prepareGroupedRecovery(recordID: review.recordID, progress: self.operationProgressSink)
                guard !Task.isCancelled, self.operationPresentationID == writer,
                      controller.presentationID == presentationID,
                      self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else {
                    if self.operationPresentationID == writer { self.finishOperationPresentation() }
                    if self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) {
                        controller.showUnavailable("Review stopped before an action began. Refresh to inspect current evidence.")
                    }
                    return
                }
                guard Self.sameGroupedReview(review, fresh) else {
                    self.finishOperationPresentation()
                    controller.update(fresh, retaining: FileAccessLifetimes(leases: (retainedAccess?.leases ?? []) + access.leases))
                    controller.showNotice("Evidence changed. Review the updated status, then choose an available action again.")
                    return
                }
                // The engine rechecks revision, inventory and one-attempt consent
                // again inside its writer operation, including guarded Undo.
                let outcome: RecoverableOperationResult
                if let action {
                    outcome = await engine.performGroupedRecovery(action: action, from: review, progress: self.operationProgressSink)
                } else {
                    guard fresh.canUndo else { self.finishOperationPresentation(); controller.showUnavailable("Undo is no longer safe. Refresh this review."); return }
                    outcome = await engine.undo(recordID: review.recordID, progress: self.operationProgressSink)
                }
                // Once dispatched, collect the outcome even if the host retired
                // or Stop was requested while the engine drained its mutation.
                if !self.isBrowserSuspended, self.view.window === host,
                   self.recoverableFileOperations === engine, self.isActiveCommandPane {
                    self.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit, recoveryAction: action)
                } else {
                    self.lastOperationResult = outcome.result; self.lastRecoveryRecordID = outcome.recordID
                    self.lastRecoveryAction = action
                    self.lastTransferContinuation = outcome.continuation; self.continuationMoveClipboard = nil
                    if self.operationPresentationID == writer { self.finishOperationPresentation() }
                    self.workspace?.refreshRecoveryViews()
                }
                if self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history),
                   let record = self.recoveryRecords.first(where: { $0.id == review.recordID }) {
                    controller.showUnavailable("Reading the completed action’s current evidence…")
                    self.refreshGroupedCopyRecovery(record, controller: controller, engine: engine, host: host, history: history)
                }
            } catch {
                if self.operationPresentationID == writer { self.finishOperationPresentation() }
                guard self.groupedReviewIsCurrent(controller, engine: engine, host: host, history: history) else { return }
                controller.showUnavailable(error is CancellationError
                    ? "Review stopped before an action began. Refresh to inspect current evidence."
                    : "Current evidence could not be rechecked. No recovery action began. Refresh after checking folder access.")
            }
        }
    }

    func beginRecoverableOperation(_ request: FileOperationRequest, title: String, roots: [URL],
                                   observing observation: FileOperationSelection?, engine: RecoverableFileOperations,
                                   moveClipboard: MoveClipboardContext? = nil, metadataPolicy: TransferMetadataPolicy = .strict,
                                   copyExecution: CopyExecutionRequest = .standard,
                                   retaining retainedAccess: FileAccessLifetimes? = nil,
                                   guardedTrash: GuardedTrashSelection? = nil,
                                   completion: (@MainActor (RecoverableOperationResult) -> Void)? = nil,
                                   createdFolderRename: UUID? = nil) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, operationTask == nil else { return }
        if case .trash = request, !NativeLocalProtectionPolicy.regularFileTrashAvailable {
            status.stringValue = OrdinaryNativeTrashFeature.moveHoldMessage
            return
        }
        let qaTrash = GeneratedSandboxReview.ownedTrashRequested
        let releasePreviewTrash: Bool
        if case .trash = request {
            releasePreviewTrash = operationCoordinator.ownsReleasePreviewAdditiveRootEngine(engine)
        } else { releasePreviewTrash = false }
        if qaTrash {
            guard case .trash(let sources) = request,
                  GeneratedSandboxReview.ownedTrashSourceAllowed(sources) else { return }
        }
        switch request {
        case .copy(let sources, let destination), .move(let sources, let destination):
            let move: Bool
            if case .move = request { move = true } else { move = false }
            _ = operationCoordinator.transfers.enqueue(sources: sources, destination: destination, move: move,
                title: title, origin: self, engine: engine, observation: observation, retaining: retainedAccess,
                clipboard: moveClipboard, metadataPolicy: metadataPolicy, copyExecution: move ? .standard : copyExecution)
            return
        case .moveObserved(let selection, let destination):
            _ = operationCoordinator.transfers.enqueue(sources: selection.urls, destination: destination, move: true,
                title: title, origin: self, engine: engine,
                observation: observation.map { selection.combining($0) } ?? selection,
                retaining: retainedAccess, clipboard: moveClipboard, metadataPolicy: metadataPolicy)
            return
        default: break
        }
        let tab = activeID, visit = sessionID
        guard startOperationPresentation(title) else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inlineRename.creationOperationFinished(createdFolderRename) }
            let lifetime = await self.accessLifetime(for: roots)
            defer { withExtendedLifetime(lifetime) {}; withExtendedLifetime(retainedAccess) {} }
            do {
                if let guardedTrash {
                    guard case .trash(let sources) = request, sources == guardedTrash.selection.urls else {
                        throw FileOperationFailure.invalidRequest
                    }
                } else if case .rename = request {
                    // The spelling-aware engine distinguishes a case alias from
                    // another occupied entry. Legacy conflict preflight cannot.
                } else {
                    let conflicts = try await self.fileOperations.conflicts(for: request, observing: observation)
                    guard conflicts.isEmpty else {
                        self.finishOperationPresentation()
                        self.showOperationError(FileOperationFailure.conflict)
                        return
                    }
                }
                try await self.operationCoordinator.prepareOperationState(for: engine)
                try Task.checkCancellation()
                if releasePreviewTrash {
                    // v9 is selected for every Trash job in this engine, even
                    // file-only jobs. Prepare its existing catalog before native work.
                    let upgrade = await engine.upgradeLocalTextHistory()
                    guard upgrade.status == .succeeded, upgrade.catalogVersion == 10 else {
                        throw FileOperationFailure.unavailable
                    }
                    try Task.checkCancellation()
                }
                if qaTrash {
                    guard case .trash(let sources) = request,
                          GeneratedSandboxReview.ownedTrashSourceAllowed(sources) else {
                        throw FileOperationFailure.invalidRequest
                    }
                    // This fresh generated QA history must explicitly reach
                    // catalog 10 before the first native Trash call.
                    let upgrade = await engine.upgradeLocalTextHistory()
                    guard upgrade.status == .succeeded, upgrade.catalogVersion == 10 else {
                        GeneratedSandboxReview.stopOwnedTrashQualification()
                        throw FileOperationFailure.unavailable
                    }
                    fputs("TRAVERSE_OWNED_TRASH_QA catalog=10\n", stderr)
                    guard await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "before"),
                          GeneratedSandboxReview.ownedTrashSourceAllowed(sources) else {
                        throw FileOperationFailure.unavailable
                    }
                }
                let outcome: RecoverableOperationResult
                if let guardedTrash { outcome = await engine.performGuardedTrash(guardedTrash, progress: self.operationProgressSink) }
                else { outcome = await engine.perform(request, observing: observation, progress: self.operationProgressSink) }
                var qaCounted = true
                if qaTrash { qaCounted = await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "after") }
                if qaTrash, outcome.result.disposition != .succeeded {
                    GeneratedSandboxReview.stopOwnedTrashQualification()
                }
                self.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit, moveClipboard: moveClipboard,
                                                     createdFolderRename: createdFolderRename)
                if !qaCounted {
                    self.status.stringValue = "QA container accounting is incomplete after Trash. Stop this qualification and review the recorded result."
                }
                completion?(outcome)
            } catch {
                self.finishOperationPresentation()
                if !(error is CancellationError) { self.showOperationError(error) }
            }
        }
    }

    func completeRecoverablePresentation(_ outcome: RecoverableOperationResult, initiatingTab: UUID, visit: UUID,
                                        moveClipboard: MoveClipboardContext? = nil, recoveryAction: CopyRecoveryAction? = nil,
                                        presentsResult: Bool = true, createdFolderRename: UUID? = nil) {
        let result = outcome.result
        lastOperationResult = result
        lastRecoveryAction = recoveryAction
        lastTransferContinuation = outcome.continuation
        continuationMoveClipboard = moveClipboard
        lastRecoveryRecordID = outcome.recordID
        finishOperationPresentation()
        consumeMoveClipboard(moveClipboard, after: result)
        if activeID == initiatingTab, sessionID == visit, location.directoryURL != nil {
            let destinations = result.items.compactMap { $0.status == .succeeded ? $0.destination : nil }
            let rename = inlineRename.prepareCreatedFolderRefresh(createdFolderRename, result: result)
            if createdFolderRename == nil || rename != nil {
                tabs[activeIndex].state.selection = Set(destinations.filter { $0.deletingLastPathComponent().path == location.directoryURL?.path })
            }
            loadLocation(createdFolderRename: rename)
        }
        inspectOperationRecovery()
        if presentsResult { presentOperationResult(result, recoveryAction: recoveryAction) }
    }

    func chooseTransferConflicts(_ conflicts: [TransferConflict]) async -> [UUID: TransferConflictResolution]? {
        if let prompt = transferConflictPrompt { return await prompt(conflicts) }
        guard let window = view.window else { return nil }
        let (alert, resolutions) = makeTransferConflictAlert(conflicts)
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? resolutions() : nil
    }
}

@MainActor
func makeTransferConflictAlert(_ conflicts: [TransferConflict]) -> (NSAlert, () -> [UUID: TransferConflictResolution]) {
        let choices = TransferConflictChoices(conflicts: conflicts)
        let alert = NSAlert()
        alert.messageText = "Choose how to handle \(conflicts.count) existing item\(conflicts.count == 1 ? "" : "s")"
        alert.informativeText = "Skip keeps the destination. Keep Both uses a new numbered name. Replace retains the destination original for Undo. Merge combines folders and keeps unrelated destination items. Changed items stop safely. A merged move leaves skipped or changed items at the source."
        if conflicts.contains(where: { $0.destinationProtectionMessage != nil }) {
            alert.informativeText += " Traverse’s live history is protected; those destinations offer only Skip or Keep Both."
        }
        alert.accessoryView = choices
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        // Do not let automatic focus scroll a virtualized row control into
        // the middle of a newly presented list of conflicts.
        alert.window.initialFirstResponder = alert.buttons.first
        return (alert, { choices.resolutions })
}

@MainActor
private final class TransferConflictChoices: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let conflicts: [TransferConflict]
    private(set) var resolutions: [UUID: TransferConflictResolution]
    private let table = NSTableView()
    private let scroll = NSScrollView()

    init(conflicts: [TransferConflict]) {
        self.conflicts = conflicts
        resolutions = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) })
        super.init(frame: NSRect(x: 0, y: 0, width: 650, height: 390))
        for (id, title, width) in [("item", "Destination", 420.0), ("choice", "Action", 200.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.resizingMask = id == "item" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.dataSource = self; table.delegate = self; InterfaceMetrics.setRowHeight(table, base: 44)
        // Small lists should show complete native rows; larger lists scroll
        // within the existing sheet height limit.
        setFrameSize(NSSize(width: 650, height: min(390,
            76 + CGFloat(conflicts.count) * (table.rowHeight + table.intercellSpacing.height))))
        scroll.documentView = table; scroll.hasVerticalScroller = true
        let all = NSPopUpButton()
        addChoice("Set all to Skip", .skip, to: all)
        addChoice("Set all to Keep Both", .keepBoth, to: all)
        if conflicts.contains(where: \.canReplace) { addChoice("Replace eligible items; skip other conflicts", .replace, to: all) }
        if conflicts.contains(where: \.canMerge) { addChoice("Merge folders; skip other conflicts", .merge, to: all) }
        all.target = self; all.action = #selector(setAll(_:))
        let layout = stack([all, scroll], orientation: .vertical)
        layout.alignment = .leading
        scroll.widthAnchor.constraint(equalToConstant: 650).isActive = true
        pin(layout, inside: self)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        subviews.forEach { $0.layoutSubtreeIfNeeded() }
        // Inset native tables can tile wider than the scroll viewport even
        // with column autoresizing enabled. Shrink only Destination by the
        // actual overflow, preserving Action and native column minimums.
        let width = scroll.contentSize.width
        guard width.isFinite, width > 0, let destination = table.tableColumns.first else { return }
        let overflow = table.frame.width - width
        guard overflow > 0.5 else { return }
        let fitted = max(destination.minWidth, destination.width - overflow)
        if destination.width - fitted > 0.5 {
            destination.width = fitted
            table.sizeToFit()
        } else {
            scroll.hasHorizontalScroller = true
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // NSAlert sizes its accessory after attaching it. Reset only after
        // that layout, rather than retaining the clip view's interim midpoint.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: -self.scroll.contentView.contentInsets.top))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let conflict = conflicts[row]
        if tableColumn?.identifier.rawValue == "item" {
            let name = label(conflict.destination.lastPathComponent)
            name.toolTip = "From: \(conflict.source.path)\nTo: \(conflict.destination.path)"
            if let reason = conflict.destinationProtectionMessage { name.toolTip! += "\n\n" + reason }
            let path = label(conflict.destination.deletingLastPathComponent().path, size: 11, color: .secondaryLabelColor)
            path.cell?.lineBreakMode = .byTruncatingMiddle
            let row = stack([name, path], orientation: .vertical, spacing: 2)
            row.toolTip = name.toolTip
            return row
        }
        let menu = NSPopUpButton()
        addChoice("Skip", .skip, to: menu)
        addChoice("Keep Both", .keepBoth, to: menu)
        if conflict.canReplace { addChoice("Replace", .replace, to: menu) }
        if conflict.canMerge { addChoice("Merge", .merge, to: menu) }
        let resolution = resolutions[conflict.id] ?? .skip
        menu.select(menu.itemArray.first { $0.representedObject as? TransferConflictResolution == resolution })
        menu.setAccessibilityLabel("Action for \(conflict.destination.lastPathComponent)")
        menu.tag = row; menu.target = self; menu.action = #selector(change(_:))
        return menu
    }
    private func addChoice(_ title: String, _ resolution: TransferConflictResolution, to menu: NSPopUpButton) {
        menu.addItem(withTitle: title)
        menu.lastItem?.representedObject = resolution
    }
    private func permitted(_ resolution: TransferConflictResolution, for conflict: TransferConflict) -> TransferConflictResolution {
        if resolution == .replace && !conflict.canReplace || resolution == .merge && !conflict.canMerge { return .skip }
        return resolution
    }
    @objc private func change(_ sender: NSPopUpButton) {
        guard conflicts.indices.contains(sender.tag),
              let resolution = sender.selectedItem?.representedObject as? TransferConflictResolution else { return }
        let conflict = conflicts[sender.tag]
        resolutions[conflict.id] = permitted(resolution, for: conflict)
    }
    @objc private func setAll(_ sender: NSPopUpButton) {
        guard let resolution = sender.selectedItem?.representedObject as? TransferConflictResolution else { return }
        for conflict in conflicts {
            resolutions[conflict.id] = permitted(resolution, for: conflict)
        }
        table.reloadData()
    }
}
