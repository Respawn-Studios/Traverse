import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    /// Keep queued history and its captured action context together. An older
    /// clean completion must not replace the review cause in the shared UI.
    func presentQueuedTransferResult(_ id: UUID) {
        let queue = operationCoordinator.transfers
        guard let completed = queue.results.first(where: { $0.id == id }) else { return }
        let displayed = queue.reviewResult ?? completed
        lastOperationResult = displayed.outcome.result
        operationHistory.diagnosticTrace = displayed.diagnosticTrace
        lastTransferContinuation = displayed.engine === recoverableFileOperations ? displayed.outcome.continuation : nil
        continuationMoveClipboard = displayed.clipboard
        lastRecoveryRecordID = displayed.engine === recoverableFileOperations ? displayed.outcome.recordID : nil
        if let workspace { workspace.browsers.values.forEach { $0.validateNavigationButtons() } }
        else { validateNavigationButtons() }
        if let presenter = operationResultPresenter { presenter(completed.outcome.result); return }
        if completed.id != displayed.id, completed.outcome.result.disposition == .succeeded {
            let summary = OperationResultDescription(result: completed.outcome.result).summary
            status.stringValue = "Latest transfer: \(summary) · Another transfer needs attention"
        } else {
            status.stringValue = OperationResultDescription(result: displayed.outcome.result).summary
        }
        #if DEBUG
        queuedTransferStatusPresentedForVerification?(completed.id, status.stringValue)
        #endif
        // Completion records attention in the window. Only an explicit Review
        // action opens Results; conflicts still use their existing choice sheet.
    }

    var canAdmitTransfer: Bool {
        !isBrowserSuspended && !isOfflineCurrentFolder && !isReadOnlyFileSession && !metadataSearch.isShowingResults
            && location.directoryURL != nil && operationTask == nil && operationPreparationTask == nil
            && cutPreparationTask == nil && !isLoading && view.window?.attachedSheet == nil
            && hasFileCommandFocus && operationCoordinator.transfers.canAdmit
    }

    var canPrepareTransferClipboard: Bool {
        !isBrowserSuspended && !isOfflineCurrentFolder && !isReadOnlyFileSession && !metadataSearch.isShowingResults
            && location.directoryURL != nil && operationTask == nil && operationPreparationTask == nil
            && cutPreparationTask == nil && !isLoading && view.window?.attachedSheet == nil
            && hasFileCommandFocus && operationCoordinator.activeOwner == nil && operationCoordinator.preparationOwner == nil
    }

    var displayedOperationPresentation: OperationProgressPresentation? {
        operationPresentation ?? operationCoordinator.transfers.presentation
    }

    var canRunExclusiveFileCommand: Bool {
        !hasExclusiveBrowserOperation && operationCoordinator.transfers.canRunExclusiveCommand
    }
}

@MainActor
extension BrowserClipboardState {
    /// Successful Move completion retains its existing exact-generation policy.
    /// Manual app-only dismissal invalidates revision and cannot reach this path.
    func consumeCompletedMove(_ clipboard: MoveClipboardContext?, after result: FileOperationResult) {
        guard let clipboard, clipboard.revision == revision, clipboard.changeCount == pasteboard.changeCount else { return }
        let succeeded = Set(result.items.compactMap { $0.status == .succeeded ? $0.source : nil })
        let allMoved = !clipboard.operationSources.isEmpty && Set(clipboard.operationSources).isSubset(of: succeeded)
        if result.disposition != .succeeded || (!allMoved && !succeeded.isEmpty) {
            feedback?.moveAttemptIncomplete = true
        }
        guard result.disposition == .succeeded, allMoved,
              (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?
                .map({ $0 as URL }) == clipboard.sources else { return }
        pasteboard.clearContents()
        clear()
    }
}
