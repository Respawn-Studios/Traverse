import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    var canContinueRemainingTransfer: Bool {
        !isBrowserSuspended && !isReadOnlyFileSession && canRunExclusiveFileCommand
            && recoverableFileOperations != nil && lastTransferContinuation != nil
            && view.window?.attachedSheet == nil
    }

    @objc func continueRemainingTransfer(_ sender: Any?) {
        guard canContinueRemainingTransfer, let continuation = lastTransferContinuation,
              let engine = recoverableFileOperations else { return }
        let conflicts = settings.conflictPreferences
        let tab = activeID, visit = sessionID
        // Keep the original clipboard generation/URLs. Only the operation's
        // expected sources narrow to engine-approved remaining units. Retained
        // merge-container outcomes still prevent physical-root completion.
        let oldClipboard = continuationMoveClipboard.map {
            MoveClipboardContext(changeCount: $0.changeCount, sources: $0.sources,
                                 operationSources: continuation.remainingSources, revision: $0.revision)
        }
        guard startOperationPresentation("Checking remaining items…") else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            let access = await self.accessLifetime(for: continuation.remainingSources + [continuation.destinationDirectory])
            defer { withExtendedLifetime(access) {} }
            do {
                let plan = try await engine.prepareContinuation(continuation, progress: self.operationProgressSink)
                let proposed = conflicts.choices(for: plan.conflicts)
                var resolutions = proposed.automatic
                if !proposed.asking.isEmpty {
                    guard !Task.isCancelled, let choices = await self.chooseTransferConflicts(proposed.asking) else {
                        self.finishOperationPresentation()
                        self.status.stringValue = "Continuation cancelled before making changes."
                        return
                    }
                    resolutions.merge(choices) { _, explicit in explicit }
                }
                guard !Task.isCancelled else {
                    self.finishOperationPresentation()
                    self.status.stringValue = "Continuation cancelled before making changes."
                    return
                }
                let savedNames = await self.privateNames.prepareMoveNames(plan: plan, choices: resolutions, engine: engine)
                let outcome = await engine.perform(savedNames?.plan ?? plan, resolutions: resolutions, progress: self.operationProgressSink)
                await self.privateNames.finishMoveNames(savedNames, engine: engine, result: outcome)
                self.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit,
                                                     moveClipboard: oldClipboard)
            } catch {
                self.finishOperationPresentation()
                if let failure = error as? FileOperationFailure,
                   [.invalidRequest, .sourceChanged, .destinationChanged, .recoveryUncertain].contains(failure),
                   self.lastTransferContinuation?.id == continuation.id {
                    self.lastTransferContinuation = nil
                    self.continuationMoveClipboard = nil
                }
                if !(error is CancellationError) { self.showOperationError(error) }
            }
        }
    }
}
