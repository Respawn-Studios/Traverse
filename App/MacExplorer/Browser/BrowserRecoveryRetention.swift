import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    func inspectRecoveryRetention(_ recordID: UUID? = nil) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, let engine = recoverableFileOperations,
              let controller = recoveryWindow, !controller.isClosed,
              let recordID = recordID ?? controller.selectedRecordID,
              controller.selectedRecordID == recordID,
              let summary = recoveryRecords.first(where: { $0.id == recordID }),
              let inspectionToken = operationCoordinator.beginInspection() else { return }
        let coordinator = operationCoordinator
        retentionInspectionTask?.cancel()
        let request = UUID()
        retentionInspectionID = request
        retentionRecords.removeAll { $0.id == recordID }
        recoveryWindow?.updateRetention(records: retentionRecords)
        retentionInspectionTask = Task { [weak self, weak controller] in
            defer {
                coordinator.finishInspection(inspectionToken)
                if self?.retentionInspectionID == request {
                    self?.retentionInspectionID = nil
                    self?.retentionInspectionTask = nil
                }
            }
            guard let self else { return }
            // Inspect only this selected job under its remembered roots. Opening
            // history never acquires every historical location or starts a scan.
            let access = await self.accessLifetime(for: summary.locations)
            defer { withExtendedLifetime(access) {} }
            #if DEBUG
            if let hook = self.beforeRetentionInspectionForVerification { await hook() }
            #endif
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !self.isBrowserSuspended
                    && self.retentionInspectionID == request
                    && self.recoverableFileOperations === engine
                    && self.recoveryWindow === controller
                    && controller?.isClosed == false
                    && controller?.selectedRecordID == recordID
            }
            guard isCurrent() else { return }
            do {
                let record = try await engine.retentionRecord(recordID: recordID)
                guard isCurrent() else { return }
                self.retentionRecords.removeAll { $0.id == recordID }
                self.retentionRecords.append(record)
                self.recoveryWindow?.updateRetention(records: self.retentionRecords)
            } catch {
                guard isCurrent() else { return }
                self.settings.recoveryMaintenanceStatus = "Backup verification is unavailable. Existing data was preserved."
            }
        }
    }

    func compactOperationJournal() {
        guard !isReadOnlyFileSession, let engine = recoverableFileOperations,
              canRunExclusiveFileCommand else {
            settings.recoveryMaintenanceStatus = "Wait for the current operation to finish before compacting."
            return
        }
        guard startOperationPresentation("Compacting journal metadata…") else { return }
        settings.recoveryMaintenanceStatus = "Compacting metadata…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await engine.compactJournal()
                self.settings.recoveryMaintenanceStatus = "Journal: \(FileSizeText.string(summary.databaseBytes)) · \(summary.eventCount) retained phase records. Recovery backups were kept."
            } catch {
                self.settings.recoveryMaintenanceStatus = "Compaction could not finish. Recovery records and backups were preserved."
            }
            self.finishOperationPresentation()
            self.inspectOperationRecovery()
        }
    }

    func confirmRecoveryCleanup(_ record: RecoveryRetentionRecord) {
        guard OrdinaryNativeTrashFeature.available else {
            settings.recoveryMaintenanceStatus = OrdinaryNativeTrashFeature.retirementHoldMessage
            return
        }
        if let summary = recoveryRecords.first(where: { $0.id == record.id }), summary.kind == .textRevision {
            ApplicationLocalTextEditors.shared.review(summary, from: self, in: recoveryWindow?.window)
            return
        }
        guard record.canCleanup, !isReadOnlyFileSession, canRunExclusiveFileCommand,
              let window = recoveryWindow?.window, window.attachedSheet == nil,
              let engine = recoverableFileOperations else { return }
        let alert = NSAlert()
        let grouping = recoveryRecords.first(where: { $0.id == record.id })?.kind == .selectionGroup
        alert.messageText = grouping ? "Clean up this operation’s temporary folders?" : "Move this operation’s recovery copies to Trash?"
        alert.informativeText = grouping
            ? "Traverse will check the temporary folders used for this grouping and move them to Trash. Your organized files stay where they are. This ends any remaining Undo for this operation. Folders that changed or cannot be checked will be kept."
            : "Traverse Undo and rollback will end for the entire operation. Completed changes and restored originals will stay where they are. Retained copies will be checked again before moving. Changed, missing or unproven staging will be preserved. Nothing will be permanently deleted."
                + (record.logicalBytes.map { "\n\n\(FileSizeText.string($0)) of logical data was verified. This is not a reclaimable disk-space estimate." } ?? "")
        alert.addButton(withTitle: grouping ? "Move Temporary Folders to Trash" : "Move Copies to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  self.canRunExclusiveFileCommand,
                  self.startOperationPresentation("Verifying recovery backups…") else { return }
            self.operationTask = Task { [weak self] in
                guard let self else { return }
                let lifetime = await self.accessLifetime(for: record.areas.map(\.url))
                defer { withExtendedLifetime(lifetime) {} }
                let outcome = await engine.cleanupRecovery(recordID: record.id, progress: self.operationProgressSink)
                if grouping {
                    self.completeSelectionGroupCleanup(outcome: outcome, recordID: record.id, engine: engine)
                    self.inspectRecoveryRetention()
                    return
                }
                self.lastOperationResult = outcome.result
                self.finishOperationPresentation()
                self.inspectOperationRecovery()
                self.inspectRecoveryRetention()
                self.presentOperationResult(outcome.result)
            }
        }
    }
}
