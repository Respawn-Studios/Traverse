import AppKit
import FileOperations
import LocalStorage

/// One tool owner per browser. Passive history inspection, modal consent and
/// mutation retain their existing coordinator/access lifetimes independently.
@MainActor
final class BrowserOwnedTrash {
    private weak var browser: BrowserViewController?
    private weak var listedEngine: RecoverableFileOperations?
    private var tool: OwnedTrashWindow?
    private var groups: [OwnedTrashGroup] = []
    private var nextCursor: UUID?
    private var generation = UUID()
    private var inspection: Task<Void, Never>?
    private var deletionPreparation: Task<Void, Never>?
    private var actionPending = false
    private var metadataUsable = false
    private var failedGroupID: UUID?

    init(browser: BrowserViewController) { self.browser = browser }

    func show() {
        guard OwnedTrashFeature.browseReady, let browser, !browser.isBrowserSuspended, !browser.isReadOnlyFileSession,
              browser.recoverableFileOperations != nil else { return }
        if tool == nil {
            let tool = OwnedTrashWindow(settings: browser.settings)
            tool.onRefresh = { [weak self] in self?.refresh() }
            tool.onLoadMore = { [weak self] in self?.refresh(loadMore: true) }
            tool.onRestore = { [weak self] in self?.restore($0) }
            tool.onDelete = { [weak self] in self?.prepareDelete($0) }
            tool.onReview = { [weak self] in self?.review($0) }
            tool.onClose = { [weak self] in self?.didClose() }
            self.tool = tool
        }
        tool?.present(relativeTo: browser.view.window)
        if deletionPreparation != nil { return }
        if actionPending {
            tool?.setBusy(true, message: "The operation on this group is still finishing.", locksSelection: true)
            return
        }
        refresh()
    }
    func close() {
        if tool?.isOpen == true { tool?.close() }
        else { didClose() }
    }
    private func didClose() {
        generation = UUID()
        inspection?.cancel(); deletionPreparation?.cancel()
        inspection = nil; deletionPreparation = nil
        groups = []; nextCursor = nil; listedEngine = nil; metadataUsable = false; failedGroupID = nil
        // A mutation belongs to browser.operationTask and continues to retain
        // its actual worker/access through completion, even if this tool closes.
    }
    private func current(_ expected: UUID, engine: RecoverableFileOperations) -> Bool {
        generation == expected && tool?.isOpen == true && browser?.isBrowserSuspended == false
            && browser?.recoverableFileOperations === engine
    }
    func refresh(loadMore: Bool = false, resultMessage: String? = nil) {
        guard OwnedTrashFeature.browseReady, !actionPending, let browser, !browser.isBrowserSuspended, tool?.isOpen == true,
              let engine = browser.recoverableFileOperations else { return }
        if listedEngine !== engine { groups = []; nextCursor = nil }
        let cursor = loadMore ? nextCursor : nil
        if loadMore && cursor == nil { return }
        guard let lease = browser.operationCoordinator.beginInspection() else {
            metadataUsable = false
            render(message: "Finish the current file operation, then Refresh to review Trash items.", busy: false)
            return
        }
        let coordinator = browser.operationCoordinator
        let trace = ApplicationDiagnostics.shared.begin(.browse)
        ApplicationDiagnostics.shared.event(.browse, .admitted, trace: trace, context: .init(.ownedTrashRead))
        inspection?.cancel()
        generation = UUID(); let expected = generation
        metadataUsable = false
        render(message: "Loading recorded items…", busy: true, emptyTitle: "Loading recorded items…")
        inspection = Task { [weak self] in
            var finished = false
            defer {
                coordinator.finishInspection(lease)
                if !finished { ApplicationDiagnostics.shared.event(.browse, .cancelled, trace: trace, context: .init(.ownedTrashRead)) }
            }
            do {
                let value = try await engine.inspectOwnedTrash(after: cursor)
                guard let self, !Task.isCancelled, self.current(expected, engine: engine) else { return }
                if loadMore {
                    let existing = Set(self.groups.map(\.id))
                    self.groups += value.groups.filter { !existing.contains($0.id) }
                } else { self.groups = value.groups }
                self.nextCursor = value.nextCursor
                self.listedEngine = engine
                let available: Bool
                switch value.readiness { case .available, .absent: available = true; default: available = false }
                self.metadataUsable = available
                finished = true
                ApplicationDiagnostics.shared.event(.browse, available ? .completed : .failed, trace: trace,
                    error: available ? nil : DiagnosticErrors.operation(FileOperationFailure.unavailable), context: .init(.ownedTrashRead))
                let message = resultMessage ?? (!available
                    ? "Recorded items could not be fully reviewed. Existing files and history have been kept."
                    : !value.refusedEntries.isEmpty ? "Some earlier records need review. Their items have been kept."
                    : "Sizes and names were recorded when these items were moved. They are checked again before an action.")
                self.render(message: message, busy: false,
                    emptyTitle: !available ? "Recorded items unavailable"
                        : value.refusedEntries.isEmpty ? "No recorded Trash items" : "Recorded items need review",
                    offersReview: !available || !value.refusedEntries.isEmpty)
                self.inspection = nil
            } catch {
                guard let self, !Task.isCancelled, self.current(expected, engine: engine) else { return }
                self.metadataUsable = false; self.listedEngine = nil
                finished = true
                ApplicationDiagnostics.shared.event(.browse, .failed, trace: trace, error: DiagnosticErrors.project(error),
                    context: .init(.ownedTrashRead), causes: DiagnosticErrors.causes(error))
                self.render(message: "Recorded items could not be read. Existing files and history have been kept.",
                    busy: false, emptyTitle: "Recorded items unavailable", offersReview: true)
                self.inspection = nil
            }
        }
    }
    private func render(message: String, busy: Bool, emptyTitle: String = "No recorded Trash items", offersReview: Bool = false) {
        tool?.update(groups.map { Self.presentation($0, actionsEnabled: metadataUsable) }, message: message, hasMore: nextCursor != nil,
            busy: busy, emptyTitle: emptyTitle, offersHistoryReview: offersReview || failedGroupID != nil)
    }
    private static func presentation(_ group: OwnedTrashGroup, actionsEnabled: Bool) -> OwnedTrashGroupPresentation {
        .init(id: group.id, createdAt: group.createdAt, entries: group.entries.map {
            .init(id: $0.id, originalURL: $0.originalURL, isDirectory: $0.isDirectory,
                recordedByteCount: $0.recordedByteCount, stateTitle: stateTitle($0.state))
        }, canRestore: actionsEnabled && OwnedTrashFeature.permitsRestore(group),
        canDelete: actionsEnabled && OwnedTrashFeature.permitsDelete(group),
        needsReview: group.reviewRequired,
        explanation: group.reviewRequired
            ? "This group needs review. Its recorded outcomes are shown above; no additional item has been changed by opening this window."
            : group.confirmedDeletionCount == group.entries.count
                ? "These recorded items were permanently deleted. This group can no longer be restored."
                : !group.canRestoreWholeGroup && !group.canDeleteWholeGroup
                    ? "This recorded group is for review only. Restore and permanent Delete are unavailable here."
                : "Restore returns this entire group to its original folders. An occupied name or changed item stops the action for review.")
    }
    private static func stateTitle(_ state: OwnedTrashEntryState) -> String {
        switch state {
        case .retained: "Moved to Trash"
        case .deleteIntent, .uncertain: "Needs review"
        case .deleteConfirmed: "Permanently deleted"
        }
    }
    private func review(_ id: UUID?) {
        guard let browser, !browser.isBrowserSuspended else { return }
        if let failedGroupID, (id == nil || id == failedGroupID), browser.lastRecoveryRecordID == failedGroupID,
           browser.lastOperationResult != nil {
            browser.showLastOperationResult(nil)
            return
        }
        if let id { browser.openOperationRecovery(recordID: id) }
        else { browser.showOperationRecovery(nil) }
    }
    private func restore(_ id: UUID) {
        guard !actionPending, metadataUsable, let browser, !browser.isBrowserSuspended, !browser.isReadOnlyFileSession,
              browser.view.window != nil, browser.view.window?.attachedSheet == nil,
              browser.canRunExclusiveFileCommand, browser.recoverableFileOperations === listedEngine,
              let group = groups.first(where: { $0.id == id }), OwnedTrashFeature.permitsRestore(group),
              (!GeneratedSandboxReview.ownedTrashRequested ||
                  GeneratedSandboxReview.ownedTrashGroupAllowed(group.entries.map(\.originalURL))),
              let record = group.recoveryRecord else { return }
        actionPending = true
        ApplicationDiagnostics.shared.event(.fileOperation, .requested, context: .init(.ownedTrashRestore))
        tool?.setBusy(true, message: "Checking and restoring this group…", locksSelection: true)
        browser.startRecoveryOperation(record, rollback: false, presentsResult: false,
            qaOwnedTrashOriginals: GeneratedSandboxReview.ownedTrashRequested ? group.entries.map(\.originalURL) : nil) { [weak self, weak browser] outcome in
            guard let self else { return }
            self.actionPending = false
            self.failedGroupID = outcome.result.disposition == .succeeded ? nil : id
            if let browser { Self.recordResult(outcome, browser: browser) }
            if OwnedTrashFeature.browseReady {
                self.refresh(resultMessage: Self.resultMessage(outcome.result, success: "The group was restored to its original folders."))
            } else {
                self.metadataUsable = false
                self.render(message: "QA stopped after Restore. Review the recorded result and container count.", busy: false, offersReview: true)
            }
        }
        if browser.operationTask == nil {
            actionPending = false
            metadataUsable = false
            render(message: "Finish the current file work, then Refresh before restoring this group.", busy: false)
        }
    }
    private func prepareDelete(_ id: UUID) {
        guard OwnedTrashFeature.canPermanentlyDelete, !actionPending, metadataUsable, deletionPreparation == nil, let browser,
              !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand,
              let tool, tool.isOpen, let host = tool.window, host.attachedSheet == nil,
              let engine = browser.recoverableFileOperations,
              engine === listedEngine,
              let group = groups.first(where: { $0.id == id }), OwnedTrashFeature.permitsDelete(group),
              (!GeneratedSandboxReview.ownedTrashRequested ||
                  GeneratedSandboxReview.ownedTrashGroupAllowed(group.entries.map(\.originalURL))),
              let lease = browser.operationCoordinator.beginInspection() else { return }
        let coordinator = browser.operationCoordinator, expected = generation
        ApplicationDiagnostics.shared.event(.fileOperation, .requested, context: .init(.ownedTrashDelete))
        tool.setBusy(true, message: "Preparing the selected group…")
        deletionPreparation = Task { [weak self, weak host] in
            let plan: OwnedTrashDeletionPlan
            do { plan = try await engine.prepareOwnedTrashDeletion(recordID: id) }
            catch {
                coordinator.finishInspection(lease)
                guard let self, !Task.isCancelled, self.current(expected, engine: engine) else { return }
                self.deletionPreparation = nil
                self.metadataUsable = false; self.listedEngine = nil
                ApplicationDiagnostics.shared.event(.fileOperation, .failed, error: DiagnosticErrors.project(error),
                    context: .init(.ownedTrashDelete), causes: DiagnosticErrors.causes(error))
                self.render(message: (error as? FileOperationFailure)?.userMessage
                    ?? "This group could not be prepared. Its recorded items have been kept.", busy: false, offersReview: true)
                return
            }
            coordinator.finishInspection(lease)
            guard let self, let host, !Task.isCancelled, self.current(expected, engine: engine) else { return }
            guard !GeneratedSandboxReview.ownedTrashRequested ||
                  GeneratedSandboxReview.ownedTrashGroupAllowed(plan.entries.map(\.originalURL)) else {
                self.deletionPreparation = nil
                self.metadataUsable = false
                self.render(message: "This generated QA group differs from the admitted files. Nothing was deleted.", busy: false, offersReview: true)
                return
            }
            guard self.tool?.selectedGroupID == id else {
                self.deletionPreparation = nil
                self.tool?.setBusy(false, message: "The selected group changed. No item was changed.")
                return
            }
            let alert = OwnedTrashDeletionReview.make(originalURLs: plan.entries.map(\.originalURL))
            let response = await alert.beginSheetModal(for: host)
            guard !Task.isCancelled, self.current(expected, engine: engine) else { return }
            self.deletionPreparation = nil
            guard self.tool?.selectedGroupID == id else {
                self.render(message: "The selected group changed. No item was changed.", busy: false)
                return
            }
            guard response == .alertFirstButtonReturn else {
                ApplicationDiagnostics.shared.event(.fileOperation, .cancelled, context: .init(.ownedTrashDelete))
                self.render(message: "Permanent deletion cancelled. No item was changed.", busy: false)
                return
            }
            self.performDelete(plan, engine: engine)
        }
    }
    private func performDelete(_ plan: OwnedTrashDeletionPlan, engine: RecoverableFileOperations) {
        guard OwnedTrashFeature.canPermanentlyDelete, let browser, !browser.isBrowserSuspended, browser.recoverableFileOperations === engine,
              (!GeneratedSandboxReview.ownedTrashRequested ||
                  GeneratedSandboxReview.ownedTrashGroupAllowed(plan.entries.map(\.originalURL))),
              browser.canRunExclusiveFileCommand,
              browser.startOperationPresentation("Permanently deleting this Trash group…") else {
            metadataUsable = false
            render(message: "Another operation started. Refresh this group before trying again.", busy: false)
            return
        }
        actionPending = true
        tool?.setBusy(true, message: "Checking and permanently deleting this group…", locksSelection: true)
        let tab = browser.activeID, visit = browser.sessionID
        browser.operationTask = Task { [weak self, browser] in
            let lifetime = await browser.accessLifetime(for: plan.entries.flatMap { [$0.originalURL, $0.trashedURL] })
            defer { withExtendedLifetime(lifetime) {} }
            if GeneratedSandboxReview.ownedTrashRequested {
                guard await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "before"),
                      OwnedTrashFeature.canPermanentlyDelete else {
                    browser.finishOperationPresentation()
                    self?.actionPending = false
                    self?.metadataUsable = false
                    self?.render(message: "QA container accounting failed before Delete. Nothing was deleted.", busy: false, offersReview: true)
                    return
                }
            }
            let outcome = await engine.permanentlyDeleteOwnedTrash(plan, progress: browser.operationProgressSink)
            var qaCounted = true
            if GeneratedSandboxReview.ownedTrashRequested {
                qaCounted = await GeneratedSandboxReview.accountOwnedTrashContainer(phase: "after")
                if outcome.result.disposition != .succeeded {
                    GeneratedSandboxReview.stopOwnedTrashQualification()
                }
            }
            browser.completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit, presentsResult: false)
            Self.recordResult(outcome, browser: browser)
            guard let self else { return }
            self.actionPending = false
            self.failedGroupID = outcome.result.disposition == .succeeded ? nil : plan.recordID
            if qaCounted && OwnedTrashFeature.runtimeReady {
                self.refresh(resultMessage: Self.resultMessage(outcome.result,
                    success: "The group was permanently deleted. It can no longer be restored."))
            } else {
                self.metadataUsable = false
                self.render(message: "QA stopped after Delete. Review the recorded result and container count.", busy: false, offersReview: true)
            }
        }
    }
    private static func resultMessage(_ result: FileOperationResult, success: String) -> String {
        if result.disposition == .succeeded { return success }
        for item in result.items {
            if case let .failed(failure) = item.status { return failure.userMessage }
        }
        return OperationResultDescription(result: result).summary
    }
    private static func recordResult(_ outcome: RecoverableOperationResult, browser: BrowserViewController) {
        ApplicationDiagnostics.shared.recordOperationResult(outcome.result, trace: browser.completedOperationDiagnosticTrace)
        browser.completedOperationDiagnosticTrace = nil
        browser.operationResultsButton.isHidden = false
        browser.operationResultsButton.isEnabled = browser.canInspectLastOperationResult
    }
}
