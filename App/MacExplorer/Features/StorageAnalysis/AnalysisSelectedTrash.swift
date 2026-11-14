import AppKit
import FileOperations
import StorageAnalysis

@MainActor
extension BrowserViewController {
    /// The analyzer owns suspension and its source lease; this browser owns
    /// ordinary exclusive-command admission, review, progress and recovery.
    func reviewAnalysisTrash(_ location: ResolvedAnalysisLocation, metadataPolicy: AnalysisMetadataPolicy, protecting roots: [URL],
                             host: NSWindow?, completed: @escaping @MainActor (RecoverableFileOperations, RecoverableOperationResult) -> Void) async -> String {
        guard StoredLocationAction.reviewTrash.availableInCurrentBuild else {
            return StoredLocationAction.reviewTrash.unavailableHelp ?? OrdinaryNativeTrashFeature.moveHoldMessage
        }
        guard !location.isSourceRoot, !isBrowserSuspended, !isReadOnlyFileSession,
              operationTask == nil, operationPreparationTask == nil,
              let engine = recoverableFileOperations, let host = host ?? view.window,
              host.attachedSheet == nil else { return "This item is unavailable for selected cleanup. Show it in Explorer to inspect it." }
        let preparationID = UUID()
        guard operationCoordinator.transfers.isIdleForCopyPreview,
              operationCoordinator.beginPreparation(owner: preparationID) else {
            return "Finish or cancel queued jobs before reviewing an item for Trash."
        }
        operationPreparationID = preparationID
        let task = Task { @MainActor [self] () -> String in
            let access = await accessLifetime(for: [location.url])
            defer {
                withExtendedLifetime(access) {}
                operationPreparationID = nil; operationPreparationTask = nil
                operationCoordinator.finishPreparation(owner: preparationID)
            }
            do {
                let reviewed = try await engine.prepareGuardedTrash([location.url],
                    protecting: operationCoordinator.protectedStorageLocations + roots,
                    excluding: { StorageAnalysisPolicy.excludes($0, policy: metadataPolicy) })
                guard reviewed.selection.matchesObject(at: location.url, device: location.recordedIdentity.device,
                    inode: location.recordedIdentity.inode) else { throw FileOperationFailure.sourceChanged }
                try Task.checkCancellation()
                let confirmed: Bool
                if let prompt = operationTrashPrompt { confirmed = await prompt(reviewed.selection.urls.count) }
                else {
                    let alert = NSAlert()
                    alert.messageText = "Move “\(location.url.lastPathComponent)” to Trash?"
                    alert.informativeText = location.url.path + "\n\nA selected folder includes its current contents. Traverse verifies these items to support recoverable history and Undo. These reads are not used for search or classification. Moving to Trash may not free space until Trash is emptied."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
                    confirmed = await withTaskCancellationHandler {
                        await alert.beginSheetModal(for: host) == .alertFirstButtonReturn
                    } onCancel: {
                        Task { @MainActor in
                            if alert.window.sheetParent === host { host.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
                        }
                    }
                }
                try Task.checkCancellation()
                guard confirmed else { return "Cancelled. Nothing was moved; no operation history was created." }
                guard !isBrowserSuspended, host.isVisible else { throw CancellationError() }
                beginRecoverableOperation(.trash(sources: reviewed.selection.urls), title: "Moving selected item to Trash…",
                    roots: reviewed.selection.urls, observing: reviewed.selection, engine: engine, guardedTrash: reviewed,
                    completion: { completed(engine, $0) })
                guard let operation = operationTask else { return "The operation could not start. Nothing was moved." }
                await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
                return status.stringValue + " Refresh to update chart sizes."
            } catch is CancellationError { return "Cancelled. Any active verification has finished." }
            catch let failure as FileOperationFailure {
                if failure == .unsupported { return "This item contains unsupported, protected or online-only data, or exceeds safe verification limits. Show it in Explorer and choose a smaller ordinary local item." }
                return failure.userMessage
            } catch { return "The item could not be reviewed. Nothing was moved." }
        }
        operationPreparationTask = Task {
            await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
