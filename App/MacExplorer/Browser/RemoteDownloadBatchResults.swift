import AppKit
import FileOperations

/// Transient presentation of independent, durable one-file operations. This is
/// deliberately not an atomic group journal or an all-files Undo capability.
@MainActor struct RemoteDownloadBatchPresentation {
    struct Item {
        let id: UUID, destination: URL
        var outcome: RecoverableOperationResult?
        var undone = false, undoNeedsReview = false
        var result: FileOperationOutcome {
            let status: FileOperationStatus
            if let outcome {
                if outcome.result.disposition == .succeeded { status = .succeeded }
                else if let failed = outcome.result.items.first(where: { if case .failed = $0.status { true } else { false } }) {
                    status = failed.status
                } else { status = outcome.result.disposition == .cancelled ? .cancelled : .failed(.recoveryUncertain) }
            } else { status = .notStarted }
            return .init(source: nil, destination: destination, status: status,
                recoveryURLs: outcome?.result.items.flatMap(\.recoveryURLs) ?? [], itemID: id)
        }
    }
    let id = UUID(), parent: URL, engine: RecoverableFileOperations
    var items: [Item]
    var notice = "", stopped = false, retainedStaging = false
    init(files: [(id: UUID, name: String)], parent: URL, engine: RecoverableFileOperations) {
        self.parent = parent; self.engine = engine
        items = files.map { .init(id: $0.id, destination: parent.appendingPathComponent($0.name)) }
    }
    mutating func record(_ outcome: RecoverableOperationResult, index: Int, stagingRemoved: Bool) {
        guard items.indices.contains(index) else { preconditionFailure("Bounded batch outcome index") }
        items[index].outcome = outcome; retainedStaging = retainedStaging || !stagingRemoved
    }
    var result: FileOperationResult { .init(items: items.map(\.result), cancellationRequested: stopped) }
    var completed: Int { items.filter { $0.outcome?.result.disposition == .succeeded }.count }
    var summary: String {
        let count = completed
        if items.contains(where: \.undoNeedsReview) {
            return "\(count) files downloaded · Undo needs review. Open Results for details."
        }
        let undone = items.filter(\.undone).count
        if undone > 0 {
            return "\(count) files downloaded · \(undone) undone."
        }
        if count == items.count {
            return "\(count) files downloaded." + (retainedStaging ? " Temporary downloads need review." : "")
        }
        let prefix = count == 0 ? "No files were added locally." : "\(count) of \(items.count) files downloaded."
        let reason = notice.isEmpty ? "The remaining files were not published. View Results; existing items were kept." : notice
        return prefix + " " + reason
    }
    func record(for item: FileOperationOutcome) -> (id: UUID, undo: Bool)? {
        guard let itemID = item.itemID, let entry = items.first(where: { $0.id == itemID }),
              let result = entry.outcome, let id = result.recordID else { return nil }
        return (id, result.result.disposition == .succeeded && !entry.undone && !entry.undoNeedsReview)
    }
    mutating func recordUndo(_ outcome: RecoverableOperationResult?, recordID: UUID) {
        guard let index = items.firstIndex(where: { $0.outcome?.recordID == recordID }) else { return }
        items[index].undone = outcome?.result.disposition == .succeeded
        items[index].undoNeedsReview = !items[index].undone
        if !items[index].undone { notice = "Undo needs review. Open the selected recorded operation before trying again." }
    }
    func describe(_ item: FileOperationOutcome) -> (title: String, details: String, needsAttention: Bool) {
        if let entry = items.first(where: { $0.id == item.itemID }) {
            if entry.undone { return ("Undone", "This file's recorded Undo completed. Its local download was removed; the server file is unchanged.\n\nEarlier destination: " + entry.destination.path, false) }
            if entry.undoNeedsReview { return ("Undo needs review", "Undo was not confirmed. View the recorded operation and its reported locations before trying again.", true) }
        }
        return (OperationResultDescription.title(for: item), OperationResultDescription.details(for: item), OperationResultsView.needsAttention(item))
    }
}

@MainActor extension BrowserViewController {
    func showRemoteDownloadBatchResults(_ batch: RemoteDownloadBatchPresentation) {
        guard canInspectLastOperationResult, let host = view.window, host.attachedSheet == nil,
              operationHistory.downloadBatch?.id == batch.id, recoverableFileOperations === batch.engine else { return }
        let alert = NSAlert(); alert.messageText = "Downloaded files"
        alert.informativeText = batch.summary + "\nUndo removes the selected local copy. Files on the server stay unchanged."
        enum Requested { case review(UUID), undo(UUID) }
        var requested: Requested?
        let current: @MainActor () -> Bool = { [weak self, weak host] in
            guard let self, let host else { return false }
            return !self.isBrowserSuspended && self.view.window === host && self.operationHistory.downloadBatch?.id == batch.id
                && self.recoverableFileOperations === batch.engine && self.canRunExclusiveFileCommand
        }
        let choose: @MainActor (Requested) -> Void = { [weak host, weak alert] request in
            guard let host, let alert, current(), host.attachedSheet === alert.window else { return }
            requested = request; host.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        let resultView = OperationResultsView(result: batch.result,
            canReveal: { [weak self, weak host] in
                guard let self, let host else { return false }; return !self.isBrowserSuspended && self.view.window === host
            }, acquireRevealAccess: { [weak self, weak host] url in
                guard let self, let host, !self.isBrowserSuspended, self.view.window === host else { return nil }
                return await self.accessLifetime(for: [url])
            },
            describeItem: batch.describe,
            actions: [
                .init(title: "Undo Selected File", available: { item in current() && batch.record(for: item)?.undo == true },
                    perform: { item in if let record = batch.record(for: item), record.undo { choose(.undo(record.id)) } }),
                .init(title: "Details…", available: { item in current() && batch.record(for: item) != nil },
                    perform: { item in if let record = batch.record(for: item) { choose(.review(record.id)) } })
            ]) { [weak self] text in
                _ = self?.clipboardWriter(text, []); self?.synchronizeTransferClipboard()
            }
        resultView.setFrameSize(.init(width: 700, height: 410))
        alert.accessoryView = resultView; alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: host) { [weak self, weak host, alert] _ in
            // Keep the alert controller, not just its sheet window, through
            // AppKit's asynchronous presentation and completion lifecycle.
            withExtendedLifetime(alert) {}
            guard let requested else { return }
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, !self.isBrowserSuspended, self.view.window === host, host.attachedSheet == nil,
                      self.operationHistory.downloadBatch?.id == batch.id, self.recoverableFileOperations === batch.engine,
                      self.canRunExclusiveFileCommand else { return }
                switch requested {
                case .review(let id): self.openOperationRecovery(recordID: id)
                case .undo(let id):
                    let completed: (RecoverableOperationResult?) -> Void = { [weak self] outcome in
                        guard let self, !self.isBrowserSuspended, self.recoverableFileOperations === batch.engine else { return }
                        var updated = batch; updated.recordUndo(outcome, recordID: id)
                        self.lastOperationResult = updated.result; self.operationHistory.downloadBatch = updated
                        self.lastRecoveryRecordID = nil; self.lastRecoveryAction = nil
                        self.status.stringValue = updated.summary; self.operationResultsButton.isHidden = false
                        if updated.items.contains(where: \.undoNeedsReview) { self.showRemoteDownloadBatchResults(updated) }
                    }
                    self.openOperationRecovery(recordID: id, presentingWindow: false, onUnavailable: {
                        guard self.operationHistory.downloadBatch?.id == batch.id else { return }; completed(nil)
                    }) { [weak self] record in
                        guard let self, record.id == id, record.operation == "Download",
                              self.operationHistory.downloadBatch?.id == batch.id, self.recoverableFileOperations === batch.engine else { return }
                        guard record.canUndo else { completed(nil); return }
                        self.startRecoveryOperation(record, rollback: false, presentsResult: false) { completed($0) }
                    }
                }
            }
        }
    }
}
