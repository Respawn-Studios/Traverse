import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

/// Grouping remains a development Preview. A qualification flag grants only
/// this generated control surface; it never changes an ordinary Release build.
enum SelectionGroupFeature {
    static var available: Bool {
        if AppFeatureAvailability.allows(.selectionGrouping) { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--check-selection-group-native")
        #else
        return false
        #endif
    }
}

@MainActor
extension BrowserViewController {
    var canStartSelectionGroup: Bool {
        SelectionGroupFeature.available && canModifyCurrentFolder && canRunExclusiveFileCommand
            && recoverableFileOperations != nil && !isArchiveLocation && !isRemoteLocation
            && !(view.window?.firstResponder is NSTextView) && !inlineRename.isEditing
            && !selectionGroupDraft.isPresenting && (1...512).contains(orderedSelectedURLs.count)
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        if isArchiveLocation { currentArchive?.groupSelection(); return }
        guard canStartSelectionGroup, let parent = location.directoryURL,
              let engine = recoverableFileOperations, let host = view.window else { return }
        let context = BrowserSelectionGroupDraftController.Context(tab: activeID, visit: sessionID,
            presentation: filePresentationID, parent: parent, orderedSelection: orderedSelectedURLs)
        let preparation = UUID(), coordinator = operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { return }
        operationPreparationID = preparation
        operationPreparationTask = Task { [weak self, fileOperations] in
            guard let self else { coordinator.finishPreparation(owner: preparation); return }
            var requestID: UUID?
            defer {
                if let requestID { self.selectionGroupDraft.cancel(requestID: requestID) }
                coordinator.finishPreparation(owner: preparation)
                if self.operationPreparationID == preparation {
                    self.operationPreparationTask = nil; self.operationPreparationID = nil
                }
                self.validateNavigationButtons(); self.consumePendingDirectoryRefresh()
            }
            do {
                guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                guard try await self.prepareSelectionGroupHistory(engine: engine, host: host) else { return }
                guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                let request = self.selectionGroupDraft.reserve(context: context)
                requestID = request
                let access = await self.accessLifetime(for: [parent] + context.orderedSelection)
                defer { withExtendedLifetime(access) {} }
                guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                let selection = try await fileOperations.observeSelection(context.orderedSelection)
                guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                // The human naming interval owns no process-wide writer lane.
                // The original source observation and access stay retained here.
                coordinator.finishPreparation(owner: preparation)
                while let name = await self.selectionGroupDraft.begin(requestID: request) {
                    guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                    guard coordinator.beginPreparation(owner: preparation) else {
                        self.selectionGroupDraft.showValidationFailure("Another operation is active. Wait for it to finish, then press Return to retry this same selection.", requestID: request)
                        continue
                    }
                    let plan: SelectionGroupPlan
                    do { plan = try await engine.prepareSelectionGroup(selection: selection, name: name) }
                    catch {
                        coordinator.finishPreparation(owner: preparation)
                        guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                        // Only correctable literal-name failures retry. Changed
                        // sources never inherit the original user's selection.
                        if let failure = error as? FileOperationFailure, failure == .conflict || failure == .invalidRequest {
                            self.selectionGroupDraft.showValidationFailure(failure.userMessage, requestID: request)
                            continue
                        }
                        throw error
                    }
                    guard self.selectionGroupContextIsCurrent(context, engine: engine, host: host),
                          self.selectionGroupDraft.consume(requestID: request, context: context) else { return }
                    guard self.startOperationPresentation("Creating folder with \(plan.memberCount) selected items…", preparation: preparation) else { return }
                    self.operationTask = Task { [self] in
                        // Capturing access keeps it alive through actual outcome
                        // collection after Stop, close or volume suspension.
                        let planAccess = await self.accessLifetime(for: plan.requiredAccessRoots)
                        defer { withExtendedLifetime(access) {}; withExtendedLifetime(planAccess) {} }
                        #if DEBUG
                        if let hold = self.beforeSelectionGroupPerformForVerification { await hold() }
                        #endif
                        let result = await engine.performSelectionGroup(plan, progress: self.operationProgressSink)
                        self.completeSelectionGroup(result, engine: engine, title: "New Folder with Selection",
                            context: context, groupedFolder: plan.destination, memberCount: plan.memberCount)
                    }
                    return
                }
            } catch {
                guard !Task.isCancelled, self.selectionGroupContextIsCurrent(context, engine: engine, host: host) else { return }
                self.status.stringValue = (error as? FileOperationFailure)?.userMessage ?? "Grouping could not be prepared. No grouping job was started."
            }
        }
    }

    private func selectionGroupContextIsCurrent(_ context: BrowserSelectionGroupDraftController.Context,
        engine: RecoverableFileOperations, host: NSWindow) -> Bool {
        !Task.isCancelled && !isBrowserSuspended && !isReadOnlyFileSession && isActiveCommandPane
            && view.window === host && host.attachedSheet == nil && recoverableFileOperations === engine
            && !isLoading && !isArchiveLocation && !isRemoteLocation && !metadataSearch.isShowingResults
            && activeID == context.tab && sessionID == context.visit && filePresentationID == context.presentation
            && location.directoryURL?.standardizedFileURL == context.parent.standardizedFileURL
            && orderedSelectedURLs == context.orderedSelection
    }

    /// Only this explicit command can prepare or upgrade grouping history.
    /// Passive startup continues to call inspectExistingHistory unchanged.
    private func prepareSelectionGroupHistory(engine: RecoverableFileOperations, host: NSWindow) async throws -> Bool {
        let inspection = try await engine.inspectExistingHistory()
        switch inspection.readiness {
        case .available(catalogVersion: 7), .available(catalogVersion: 9), .available(catalogVersion: 10): return true
        default: break
        }
        guard !Task.isCancelled, !isBrowserSuspended, view.window === host, host.attachedSheet == nil,
              recoverableFileOperations === engine else { return false }
        switch inspection.readiness {
        case .absent, .available(catalogVersion: 3), .available(catalogVersion: 4): break
        default:
            status.stringValue = "Operation history needs attention before grouping. Open Operation Recovery to review it."
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Enable New Folder with Selection?"
        alert.informativeText = "Traverse will update operation history and keep a backup. Older builds may not be able to change this history. Existing operations keep their original Undo rules. The selected files will move only after you enter a proposed folder name and press Return."
        alert.addButton(withTitle: "Enable Preview"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        let prompt = OperationWindowPrompt()
        defer { withExtendedLifetime(prompt) {} }
        guard (try? await prompt.present(alert, in: host)) == .alertFirstButtonReturn,
              !Task.isCancelled, !isBrowserSuspended, view.window === host, recoverableFileOperations === engine else { return false }
        try await operationCoordinator.prepareOperationState(for: engine)
        let prepared = try await engine.recoveryRecords()
        guard !Task.isCancelled else { return false }
        switch prepared.readiness {
        case .available(catalogVersion: 7), .available(catalogVersion: 9), .available(catalogVersion: 10): return true
        case .available(catalogVersion: 3), .available(catalogVersion: 4): break
        default:
            status.stringValue = "Operation history needs attention. Grouping did not start. Review history before retrying."
            return false
        }
        let upgrade = await engine.upgradeSelectionGroupHistory()
        settings.recoveryMaintenanceStatus = upgrade.status == .succeeded && upgrade.catalogVersion == 7
            ? "New Folder with Selection is enabled. A history backup was kept."
            : "The history update could not be confirmed. Review operation history and any retained backup before retrying."
        recoveryHistoryReadiness = (try? await engine.inspectExistingHistory())?.readiness ?? .unavailable
        guard upgrade.status == .succeeded, upgrade.catalogVersion == 7 else { status.stringValue = settings.recoveryMaintenanceStatus; return false }
        return !Task.isCancelled
    }

    #if DEBUG
    /// Exercises the actual known-version admission without starting a group or
    /// exposing another production mutation entry point.
    func prepareSelectionGroupHistoryForVerification(engine: RecoverableFileOperations, host: NSWindow) async throws -> Bool {
        try await prepareSelectionGroupHistory(engine: engine, host: host)
    }
    #endif

    private func completeSelectionGroup(_ result: SelectionGroupResult, engine: RecoverableFileOperations,
        title: String, context: BrowserSelectionGroupDraftController.Context? = nil, groupedFolder: URL? = nil,
        memberCount: Int? = nil) {
        // Ordering matters: the generic setter clears stale typed history.
        lastOperationResult = nil; lastTransferContinuation = nil; continuationMoveClipboard = nil
        lastRecoveryAction = nil; lastRecoveryRecordID = result.recordID
        let trace = operationDiagnosticTrace ?? completedOperationDiagnosticTrace
        let presentation = SelectionGroupPresentation(result: result, engine: engine, title: title, diagnosticTrace: trace)
        operationHistory.selectionGroup = presentation
        finishOperationPresentation()
        recordSelectionGroupTerminal(result, trace: trace, memberCount: memberCount)
        completedOperationDiagnosticTrace = nil
        privateNames.moveReferencesChanged()
        workspace?.refreshRecoveryViews()
        if workspace == nil { inspectOperationRecovery() }
        if !isBrowserSuspended, result.authoritative, result.state == .grouped,
           let context, let groupedFolder, activeID == context.tab, sessionID == context.visit,
           location.directoryURL?.standardizedFileURL == context.parent.standardizedFileURL {
            tabs[activeIndex].state.selection = [groupedFolder]
            loadLocation()
        }
        if !isBrowserSuspended {
            status.stringValue = SelectionGroupResultDescription(result: result).summary
            operationResultsButton.isHidden = false
            operationResultsButton.isEnabled = !hasExclusiveBrowserOperation
            workspace?.browsers.values.forEach { $0.validateNavigationButtons() }
        }
        if let controller = selectionGroupWindow, controller.engine === engine, controller.recordID == result.recordID, !controller.isClosed {
            controller.updateOutcome(presentation)
            controller.showUnavailable("The action has finished. Refresh to check the item locations.")
        }
    }

    /// Fixed diagnostic vocabulary only: no URL, title, literal name or item
    /// text enters the recorder. State and actual status both constrain success.
    private func recordSelectionGroupTerminal(_ result: SelectionGroupResult, trace: UUID?, memberCount: Int?) {
        let phase: DiagnosticPhase
        if !result.authoritative || [.partial, .membersRestored, .uncertain].contains(result.state) { phase = .partial }
        else {
            switch result.status {
            case .succeeded: phase = [.grouped, .undone, .cleaned].contains(result.state) ? .completed : .finished
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed
            case .notStarted, .skipped: phase = .blocked
            }
        }
        let failure: DiagnosticErrorCode?
        if case .failed(let value) = result.status { failure = DiagnosticErrors.operation(value) } else { failure = nil }
        ApplicationDiagnostics.shared.event(.fileOperation, phase, trace: trace,
            count: memberCount.map { UInt64(max(0, $0)) }, error: failure,
            context: .init(.nativeStatus, flags: result.cancellationRequested ? [.cancellationRequested] : []),
            relatedTrace: result.recordID)
    }

    private func finishSelectionGroupWithoutDispatch(recordID: UUID, error: Error? = nil) {
        let trace = operationDiagnosticTrace
        finishOperationPresentation()
        ApplicationDiagnostics.shared.event(.fileOperation, error.map { $0 is CancellationError ? .cancelled : .failed } ?? .blocked,
            trace: trace, error: error.map { DiagnosticErrors.project($0) }, relatedTrace: recordID)
        completedOperationDiagnosticTrace = nil
    }

    /// The actual maintenance result stays its own family. It never becomes a
    /// fabricated grouping result or clears a matching review without refresh.
    func completeSelectionGroupCleanup(outcome: RecoverableOperationResult, recordID: UUID, engine: RecoverableFileOperations) {
        let trace = operationDiagnosticTrace ?? completedOperationDiagnosticTrace
        lastOperationResult = nil; lastTransferContinuation = nil; continuationMoveClipboard = nil
        lastRecoveryAction = nil; lastRecoveryRecordID = recordID
        let presentation = SelectionGroupPresentation(cleanup: outcome, recordID: recordID, engine: engine, diagnosticTrace: trace)
        operationHistory.selectionGroup = presentation
        finishOperationPresentation()
        ApplicationDiagnostics.shared.recordOperationResult(outcome.result, trace: trace)
        ApplicationDiagnostics.shared.event(.cleanup, .finished, trace: trace,
            count: UInt64(outcome.result.items.count), relatedTrace: recordID)
        completedOperationDiagnosticTrace = nil
        privateNames.moveReferencesChanged(); workspace?.refreshRecoveryViews()
        if workspace == nil { inspectOperationRecovery() }
        if !isBrowserSuspended { status.stringValue = presentation.summary; validateNavigationButtons() }
        if let controller = selectionGroupWindow, controller.engine === engine,
           controller.recordID == recordID, !controller.isClosed {
            controller.cancelInspection()
            controller.updateOutcome(presentation)
            controller.showUnavailable("Folder cleanup has finished. Checking the item locations…")
            controller.afterInspectionDrain { [weak self, weak controller] in
                guard let self, let controller, self.selectionGroupWindow === controller else { return }
                self.refreshSelectionGroupReview()
            }
        }
    }

    func showLastSelectionGroupResults() {
        guard let presentation = operationHistory.selectionGroup else { return }
        showSelectionGroupResults(recordID: presentation.recordID, engine: presentation.engine, presentation: presentation)
    }

    func showSelectionGroupResults(recordID: UUID) {
        guard let engine = recoverableFileOperations else { return }
        let presentation = operationHistory.selectionGroup.flatMap {
            $0.engine === engine && $0.recordID == recordID ? $0 : nil
        }
        showSelectionGroupResults(recordID: recordID, engine: engine, presentation: presentation)
    }

    /// Cmd-Z is explicit intent for this exact job. Fresh public review grants
    /// only the Undo it currently offers; ambiguous jobs open their typed review.
    func beginSelectionGroupUndo(recordID: UUID) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, isActiveCommandPane,
              operationTask == nil, operationPreparationTask == nil,
              canRunExclusiveFileCommand, let host = view.window, host.attachedSheet == nil,
              let engine = recoverableFileOperations else { return }
        let presentation = operationHistory.selectionGroup.flatMap {
            $0.engine === engine && $0.recordID == recordID ? $0 : nil
        }
        let roots = (recoveryRecords.first { $0.id == recordID }?.locations ?? [])
            + (presentation?.knownLocations ?? []) + (location.directoryURL.map { [$0] } ?? [])
            + rememberedFolders.compactMap(\.url)
        guard startOperationPresentation("Checking grouping before Undo…") else { return }
        let writer = operationPresentationID
        let priorReview = selectionGroupWindow.flatMap {
            $0.recordID == recordID && $0.engine === engine && !$0.isClosed ? $0 : nil
        }
        priorReview?.cancelInspection()
        priorReview?.setWorking("Checking item locations before Undo…")
        operationTask = Task { [self] in
            await priorReview?.drain()
            let access = await accessLifetime(for: roots)
            var dispatched = false
            defer {
                withExtendedLifetime(access) {}
                if !dispatched, let priorReview, selectionGroupWindow === priorReview,
                   !priorReview.isClosed, priorReview.isBusy {
                    priorReview.showUnavailable(Task.isCancelled
                        ? "Undo stopped before any items changed. Refresh the item status before retrying."
                        : "Undo did not start. Refresh the item status before retrying.")
                }
            }
            do {
                guard selectionGroupUndoIsCurrent(engine: engine, host: host, writer: writer) else { throw CancellationError() }
                let fresh = try await engine.inspectSelectionGroup(recordID: recordID, progress: operationProgressSink)
                guard selectionGroupUndoIsCurrent(engine: engine, host: host, writer: writer) else { throw CancellationError() }
                let itemAccess = await accessLifetime(for: fresh.requiredAccessRoots)
                defer { withExtendedLifetime(itemAccess) {} }
                guard selectionGroupUndoIsCurrent(engine: engine, host: host, writer: writer) else { throw CancellationError() }
                guard fresh.canUndo else {
                    finishSelectionGroupWithoutDispatch(recordID: recordID)
                    showSelectionGroupResults(recordID: recordID, engine: engine, presentation: presentation,
                        freshReview: fresh, access: FileAccessLifetimes(leases: access.leases + itemAccess.leases))
                    selectionGroupWindow?.showNotice("Undo could not start. Review the item locations and choose an available action. No items were changed.")
                    return
                }
                #if DEBUG
                if let hold = beforeSelectionGroupReviewActionForVerification { await hold() }
                #endif
                guard selectionGroupUndoIsCurrent(engine: engine, host: host, writer: writer) else { throw CancellationError() }
                dispatched = true
                let result = await engine.undoSelectionGroup(fresh, progress: operationProgressSink)
                completeSelectionGroup(result, engine: engine, title: "Undo Grouping", memberCount: fresh.items.count)
                if !isBrowserSuspended, view.window === host, recoverableFileOperations === engine,
                   result.state != .undone || !result.authoritative { showLastSelectionGroupResults() }
            } catch {
                if operationPresentationID == writer { finishSelectionGroupWithoutDispatch(recordID: recordID, error: error) }
                guard !(error is CancellationError), !Task.isCancelled, !isBrowserSuspended,
                      view.window === host, recoverableFileOperations === engine else { return }
                showSelectionGroupResults(recordID: recordID, engine: engine, presentation: presentation)
                selectionGroupWindow?.showNotice("Undo could not start. Check folder access and review the item locations. No items were changed.")
            }
        }
    }

    private func selectionGroupUndoIsCurrent(engine: RecoverableFileOperations, host: NSWindow, writer: UUID?) -> Bool {
        !Task.isCancelled && !isBrowserSuspended && !isReadOnlyFileSession && isActiveCommandPane
            && view.window === host && host.attachedSheet == nil && recoverableFileOperations === engine
            && operationPresentationID == writer
    }

    private func showSelectionGroupResults(recordID: UUID?, engine: RecoverableFileOperations,
        presentation: SelectionGroupPresentation?, freshReview: SelectionGroupReview? = nil,
        access: FileAccessLifetimes? = nil) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, view.window?.attachedSheet == nil,
              !hasExclusiveBrowserOperation, let host = view.window else { return }
        if let old = selectionGroupWindow {
            if old.recordID != recordID || old.engine !== engine || old.isClosed {
                old.close()
                guard old.inspectionTask == nil else {
                    status.stringValue = "The earlier review is stopping. Wait for it to finish, then reopen Results."
                    return
                }
                selectionGroupWindow = nil
            }
        }
        if selectionGroupWindow == nil {
            let controller = SelectionGroupResultsWindow(recordID: recordID, engine: engine, presentation: presentation,
                onAction: { [weak self] action, review, generation in self?.startSelectionGroupReviewAction(action, review: review, presentationID: generation) },
                onRefresh: { [weak self] in self?.refreshSelectionGroupReview() })
            controller.hostObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: host) { [weak controller] _ in
                MainActor.assumeIsolated { controller?.close() }
            }
            selectionGroupWindow = controller
        }
        guard let controller = selectionGroupWindow else { return }
        if let presentation { controller.updateOutcome(presentation) }
        if let window = controller.window { ToolWindowChrome.install(in: window, settings: settings) }
        if !isControlledVerification { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        if let freshReview, let access, controller.inspectionTask == nil {
            controller.update(freshReview, retaining: access)
        } else if recordID != nil { refreshSelectionGroupReview() }
    }

    private func selectionGroupReviewIsCurrent(_ controller: SelectionGroupResultsWindow, host: NSWindow) -> Bool {
        !isBrowserSuspended && !isReadOnlyFileSession && view.window === host && selectionGroupWindow === controller
            && !controller.isClosed && recoverableFileOperations === controller.engine
    }

    func refreshSelectionGroupReview() {
        guard let controller = selectionGroupWindow, let host = view.window,
              selectionGroupReviewIsCurrent(controller, host: host), let recordID = controller.recordID,
              controller.inspectionTask == nil, !controller.isBusy,
              let inspection = operationCoordinator.beginInspection() else { return }
        let coordinator = operationCoordinator, engine = controller.engine
        guard let generation = controller.beginLoading() else { coordinator.finishInspection(inspection); return }
        let roots = (recoveryRecords.first { $0.id == recordID }?.locations ?? [])
            + (controller.presentation?.knownLocations ?? []) + (location.directoryURL.map { [$0] } ?? [])
            + rememberedFolders.compactMap(\.url)
        controller.inspectionTask = Task { [weak self, controller] in
            defer { coordinator.finishInspection(inspection); controller.inspectionDidDrain() }
            guard let self else { return }
            let access = await self.accessLifetime(for: roots)
            defer { withExtendedLifetime(access) {} }
            do {
                guard !Task.isCancelled, controller.inspectionID == generation, self.selectionGroupReviewIsCurrent(controller, host: host) else { return }
                let review = try await engine.inspectSelectionGroup(recordID: recordID)
                guard !Task.isCancelled, controller.inspectionID == generation, self.selectionGroupReviewIsCurrent(controller, host: host) else { return }
                let itemAccess = await self.accessLifetime(for: review.requiredAccessRoots)
                guard !Task.isCancelled, controller.inspectionID == generation, self.selectionGroupReviewIsCurrent(controller, host: host) else { return }
                guard review.items.count <= 512 else { controller.showUnavailable("This operation exceeds the 512-item review limit. Existing files and history were kept."); return }
                controller.update(review, retaining: FileAccessLifetimes(leases: access.leases + itemAccess.leases))
            } catch {
                guard !Task.isCancelled, controller.inspectionID == generation, self.selectionGroupReviewIsCurrent(controller, host: host) else { return }
                controller.showUnavailable("Item status could not be read. Check folder access and refresh. Existing files and recovery records were kept.")
            }
        }
    }

    private static func sameSelectionGroupReview(_ left: SelectionGroupReview, _ right: SelectionGroupReview) -> Bool {
        left.recordID == right.recordID && left.revision == right.revision && left.state == right.state
            && left.problem == right.problem && left.pending == right.pending
            && left.verifiedCleanupTarget == right.verifiedCleanupTarget
            && left.actions == right.actions && left.canUndo == right.canUndo
            && left.requiredAccessRoots == right.requiredAccessRoots && left.items.count == right.items.count
            && zip(left.items, right.items).allSatisfy { pair in
                let (a, b) = pair
                return a.source == b.source && a.destination == b.destination && a.state == b.state
            }
    }

    /// The displayed opaque token remains the consent. A fresh inspection must
    /// match it; substituting a changed review never silently authorizes action.
    private func startSelectionGroupReviewAction(_ action: SelectionGroupDisposition?, review: SelectionGroupReview, presentationID: UUID) {
        guard let controller = selectionGroupWindow, let host = view.window,
              selectionGroupReviewIsCurrent(controller, host: host), controller.presentationID == presentationID,
              controller.recordID == review.recordID, controller.review?.revision == review.revision,
              !controller.isBusy, controller.inspectionTask == nil,
              action.map({ SelectionGroupResultsWindow.canOffer($0, from: review) }) ?? review.canUndo,
              operationTask == nil, operationPreparationTask == nil,
              canRunExclusiveFileCommand, host.attachedSheet == nil, controller.window?.attachedSheet == nil else { return }
        let engine = controller.engine, retainedAccess = controller.retainedAccess
        let title = action?.selectionGroupTitle ?? "Undo Grouping"
        guard startOperationPresentation(title + "…") else { return }
        let writer = operationPresentationID
        controller.setWorking("Checking item locations before \(title.lowercased())…")
        operationTask = Task { [self, controller] in
            let access = await self.accessLifetime(for: review.requiredAccessRoots)
            defer { withExtendedLifetime(access) {}; withExtendedLifetime(retainedAccess) {} }
            do {
                guard !Task.isCancelled, operationPresentationID == writer, controller.presentationID == presentationID,
                      selectionGroupReviewIsCurrent(controller, host: host) else { throw CancellationError() }
                let fresh = try await engine.inspectSelectionGroup(recordID: review.recordID, progress: operationProgressSink)
                guard !Task.isCancelled, operationPresentationID == writer, controller.presentationID == presentationID,
                      selectionGroupReviewIsCurrent(controller, host: host) else { throw CancellationError() }
                guard Self.sameSelectionGroupReview(review, fresh) else {
                    finishSelectionGroupWithoutDispatch(recordID: review.recordID)
                    controller.update(fresh, retaining: FileAccessLifetimes(leases: (retainedAccess?.leases ?? []) + access.leases))
                    controller.showNotice("Item status changed. Review the updated locations, then choose an available action again.")
                    return
                }
                #if DEBUG
                if let hold = beforeSelectionGroupReviewActionForVerification { await hold() }
                #endif
                guard !Task.isCancelled, operationPresentationID == writer, controller.presentationID == presentationID,
                      selectionGroupReviewIsCurrent(controller, host: host) else { throw CancellationError() }
                let result: SelectionGroupResult
                if let action { result = await engine.confirmSelectionGroup(review, disposition: action, progress: operationProgressSink) }
                else { result = await engine.undoSelectionGroup(review, progress: operationProgressSink) }
                // Dispatch is the boundary: never drop an actual mutation's
                // outcome just because Stop, close or navigation arrived.
                completeSelectionGroup(result, engine: engine, title: title, memberCount: review.items.count)
                if selectionGroupReviewIsCurrent(controller, host: host) { refreshSelectionGroupReview() }
            } catch {
                if operationPresentationID == writer { finishSelectionGroupWithoutDispatch(recordID: review.recordID, error: error) }
                if selectionGroupReviewIsCurrent(controller, host: host) {
                    controller.showUnavailable(error is CancellationError
                        ? "Review stopped before an action began. Refresh the item status before retrying."
                        : "Item status could not be checked. No action began. Refresh to review the item locations.")
                }
            }
        }
    }
}
