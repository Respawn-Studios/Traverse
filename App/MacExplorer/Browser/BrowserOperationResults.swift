import AppKit
import FileOperations
import LocalStorage

/// Presentation uses explicit outcome roles rather than guessing from a path or
/// treating a partially merged source container as an untouched transfer item.
struct OperationResultDescription {
    let result: FileOperationResult
    let recoveryAction: CopyRecoveryAction?
    private let hasUnconfirmedChanges: Bool
    var offersFolderAccess: Bool { result.items.contains { $0.status == .failed(.accessDenied) } }
    static let folderAccessExplanation = "Choose the containing folder or drive in Traverse to allow file changes. The source and destination may each need access. If access is still denied, check the folder’s permissions and macOS privacy settings."

    init(result: FileOperationResult, recoveryAction: CopyRecoveryAction? = nil) {
        self.result = result; self.recoveryAction = recoveryAction
        hasUnconfirmedChanges = recoveryAction == nil && result.items.contains {
            $0.role == .job && $0.status == .failed(.recoveryUncertain)
        }
    }

    var summary: String {
        if let recoveryAction { return Self.recoverySummary(recoveryAction, disposition: result.disposition) }
        if result.items.contains(where: { $0.status == .failed(.operationHistoryProtected) }),
           result.items.allSatisfy({ $0.recoveryURLs.isEmpty && ($0.status == .notStarted || $0.status == .failed(.operationHistoryProtected)) }) {
            return "Request blocked to protect Traverse’s operation history. Choose another item or destination."
        }
        let transfers = result.items.filter { $0.role == .transfer }
        let completed = transfers.filter { $0.status == .succeeded }.count
        let skipped = transfers.filter { $0.status == .skipped }.count
        let notStarted = transfers.filter { $0.status == .notStarted }.count
        let unresolved = transfers.count - completed - skipped - notStarted
        let retired = result.items.filter { $0.role == .mergeContainer && $0.status == .succeeded }.count
        var parts: [String] = []
        if !transfers.isEmpty {
            let outcome = hasUnconfirmedChanges && completed > 0 ? "changed" : "completed"
            parts.append("\(completed) of \(transfers.count) items \(outcome)")
        }
        else if retired > 0 { parts.append("\(retired) source folder\(retired == 1 ? "" : "s") retired") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if notStarted > 0 { parts.append("\(notStarted) not attempted") }
        if unresolved > 0 { parts.append("\(unresolved) need review") }
        let retained = result.items.filter(Self.isRetainedContainer).count
        if retained > 0 { parts.append("\(retained) source folder\(retained == 1 ? "" : "s") retained") }
        let uncertainFolders = result.items.filter { $0.role == .mergeContainer && $0.status != .succeeded && !Self.isRetainedContainer($0) }.count
        if uncertainFolders > 0 { parts.append("\(uncertainFolders) folder retirement\(uncertainFolders == 1 ? "" : "s") need review") }
        if result.items.contains(where: { $0.role == .job && $0.status != .succeeded }) {
            parts.append("operation needs review")
        }
        if parts.isEmpty { parts.append(result.disposition == .succeeded ? "Operation completed" : "No transfer items completed") }
        return parts.joined(separator: " · ") + "."
    }

    private static func recoverySummary(_ action: CopyRecoveryAction, disposition: FileOperationDisposition) -> String {
        if disposition == .succeeded {
            switch action {
            case .confirmCopies: return "Confirmed existing copies."
            case .confirmUndo: return "Confirmed completed Undo."
            case .finishReview: return "Recovery review finished."
            }
        }
        let operation: String
        switch action {
        case .confirmCopies: operation = "Copy confirmation"
        case .confirmUndo: operation = "Completed Undo confirmation"
        case .finishReview: operation = "Recovery review"
        }
        switch disposition {
        case .cancelled: return operation + " stopped · review required."
        case .partial: return operation + " partly recorded · review required."
        default: return operation + " needs review."
        }
    }

    private func isUnconfirmedChange(_ item: FileOperationOutcome) -> Bool {
        hasUnconfirmedChanges && item.role == .transfer && item.status == .succeeded
    }

    func itemTitle(_ item: FileOperationOutcome) -> String {
        Self.title(for: item, recoveryAction: recoveryAction, unconfirmedChange: isUnconfirmedChange(item))
    }

    func itemDetails(_ item: FileOperationOutcome) -> String {
        Self.details(for: item, recoveryAction: recoveryAction, unconfirmedChange: isUnconfirmedChange(item))
    }

    func itemNeedsAttention(_ item: FileOperationOutcome) -> Bool {
        isUnconfirmedChange(item) || Self.needsAttention(item)
    }

    static func needsAttention(_ item: FileOperationOutcome) -> Bool {
        item.status != .succeeded && item.status != .skipped
    }

    static func title(for item: FileOperationOutcome, recoveryAction: CopyRecoveryAction? = nil,
                      unconfirmedChange: Bool = false) -> String {
        if unconfirmedChange, item.role == .transfer, item.status == .succeeded { return "Changed · needs review" }
        if item.role == .job, let recoveryAction, item.status == .succeeded {
            return String(recoverySummary(recoveryAction, disposition: .succeeded).dropLast())
        }
        if item.role == .mergeContainer {
            if item.status == .succeeded { return "Source folder retired" }
            return isRetainedContainer(item) ? "Source folder retained" : "Folder needs review"
        }
        switch item.status {
        case .succeeded: return "Completed"
        case .skipped: return "Skipped"
        case .notStarted: return "Not attempted"
        case .cancelled: return "Stopped"
        case .failed(.operationHistoryProtected): return "Protected app history"
        case .failed: return "Needs review"
        }
    }

    static func details(for item: FileOperationOutcome, recoveryAction: CopyRecoveryAction? = nil,
                        unconfirmedChange: Bool = false) -> String {
        let reason: String
        if item.role == .mergeContainer && item.status != .succeeded {
            let explanation = isRetainedContainer(item)
                ? "The source folder remains. Some children may already have transferred; their results are listed separately. Retained folders may be needed for earlier Undo."
                : "Folder retirement did not finish cleanly. Review the source and reported recovery locations to determine where the folder is. Completed child transfers are listed separately."
            if item.status == .failed(.conflict) {
                reason = explanation + "\n\nThe folder still contains items that were not moved. They remain at the source."
            } else if case .failed(let failure) = item.status { reason = explanation + "\n\n" + failure.userMessage }
            else { reason = explanation }
        } else {
            switch item.status {
            case .succeeded:
                if unconfirmedChange { reason = "This item changed, but the complete result could not be confirmed. Review the reported locations without repeating the operation." }
                else if item.role == .job, let recoveryAction { reason = recoverySummary(recoveryAction, disposition: .succeeded) }
                else { reason = "Completed." }
            case .skipped: reason = "Skipped by choice. This transfer unit was left untouched."
            case .notStarted: reason = "This transfer unit was not attempted. Other items may already have completed."
            case .cancelled: reason = "Stopped before completion. Review any completed changes and retained recovery locations."
            case .failed(let failure): reason = failure.userMessage
            }
        }
        var fields = [reason]
        if item.role == .job, let recoveryAction, item.status != .succeeded {
            fields.insert(recoveryAction.title + " · review the recorded evidence before choosing another action.", at: 0)
        }
        if let source = item.source { fields.append("Source: \(source.path)") }
        if let destination = item.destination { fields.append("Destination: \(destination.path)") }
        if !item.recoveryURLs.isEmpty {
            fields.append("Recovery locations:\n" + item.recoveryURLs.map(\.path).joined(separator: "\n"))
        }
        return fields.joined(separator: "\n\n")
    }

    static func isRetainedContainer(_ item: FileOperationOutcome) -> Bool {
        item.role == .mergeContainer && (item.status == .notStarted || item.status == .skipped || item.status == .failed(.conflict))
    }
}

/// Virtualized rows keep large job reports inspectable without truncating the
/// results or creating one native control for every transferred file.
@MainActor struct OperationResultAction {
    let title: String
    let available: (FileOperationOutcome) -> Bool
    let perform: (FileOperationOutcome) -> Void
}

@MainActor
final class OperationResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let resultDescription: OperationResultDescription
    private let table = NSTableView()
    private let detail = NSTextView()
    private let attention = NSButton(checkboxWithTitle: "Show only items needing attention", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Selected Details", target: nil, action: nil)
    private let sourceButton = NSButton(title: "Reveal Source", target: nil, action: nil)
    private let destinationButton = NSButton(title: "Reveal Destination", target: nil, action: nil)
    private let logsButton = NSButton(title: "App Logs…", target: nil, action: nil)
    private let copyText: (String) -> Void
    private let showLogs: (() -> Void)?
    private let reveal: ((URL) -> Void)?
    private let canReveal: () -> Bool
    private let acquireRevealAccess: (URL) async -> FileAccessLifetimes?
    private let actions: [OperationResultAction]
    private let describeItem: ((FileOperationOutcome) -> (title: String, details: String, needsAttention: Bool))?
    private var actionButtons: [NSButton] = []
    private static let revealResolver = LocalFileSystem(maximumConcurrentReads: 1, activityGate: ApplicationFileActivity.gate)
    private var revealTask: Task<Void, Never>?
    #if DEBUG
    var beforeRevealReturnsForVerification: (@MainActor () async -> Void)?
    var resultActionFinishedForVerification: (() -> Void)?
    #endif
    private(set) var visibleItems: [FileOperationOutcome] = []

    init(result: FileOperationResult, context: String? = nil, recoveryAction: CopyRecoveryAction? = nil,
         canReveal: @escaping () -> Bool = { true },
         acquireRevealAccess: @escaping (URL) async -> FileAccessLifetimes? = { _ in nil },
         reveal: ((URL) -> Void)? = nil,
        describeItem: ((FileOperationOutcome) -> (title: String, details: String, needsAttention: Bool))? = nil,
        actions: [OperationResultAction] = [],
         showLogs: (() -> Void)? = nil,
         copyText: @escaping (String) -> Void) {
        resultDescription = OperationResultDescription(result: result, recoveryAction: recoveryAction)
        self.copyText = copyText
        self.showLogs = showLogs
        self.reveal = reveal
        self.canReveal = canReveal
        self.acquireRevealAccess = acquireRevealAccess
        self.actions = actions
        self.describeItem = describeItem
        super.init(frame: NSRect(x: 0, y: 0, width: 650, height: 370))
        for (id, title, width) in [("item", "Item", 425.0), ("result", "Result", 195.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        InterfaceMetrics.setRowHeight(table, base: 25); table.style = .plain
        table.setAccessibilityLabel("File operation results")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        attention.target = self; attention.action = #selector(toggleAttention(_:))
        attention.state = result.items.contains(where: requiresAttention) ? .on : .off
        copyButton.target = self; copyButton.action = #selector(copySelection(_:))
        sourceButton.target = self; sourceButton.action = #selector(revealSource(_:))
        destinationButton.target = self; destinationButton.action = #selector(revealDestination(_:))
        logsButton.target = self; logsButton.action = #selector(showLogsPressed(_:))
        logsButton.bezelStyle = .rounded
        logsButton.toolTip = "Review this operation’s technical steps and export its app logs for support."
        sourceButton.toolTip = "Reveal the reported source in Finder, or its nearest available parent if the source is missing or moved."
        destinationButton.toolTip = "Reveal the reported destination in Finder, or its nearest available parent if no item is available there."
        detail.isEditable = false; detail.isSelectable = true
        detail.font = .systemFont(ofSize: 12)
        detail.textContainerInset = NSSize(width: 6, height: 6)
        detail.autoresizingMask = [.width]
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false
        detail.textContainer?.widthTracksTextView = true
        detail.setAccessibilityLabel("Selected operation result details")
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        let controls = stack([attention, NSView(), copyButton], orientation: .horizontal)
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(performSelectedAction(_:)))
            button.tag = index; button.bezelStyle = .rounded; actionButtons.append(button)
        }
        var locationControls: [NSView] = [sourceButton, destinationButton, NSView()]
        if showLogs != nil { locationControls.append(logsButton) }
        let locations = stack(locationControls, orientation: .horizontal)
        let itemActions = stack(actionButtons + [NSView()], orientation: .horizontal)
        var sections: [NSView] = []
        if let context {
            let captured = label(context, size: 11, color: .secondaryLabelColor)
            captured.maximumNumberOfLines = 3; captured.lineBreakMode = .byTruncatingMiddle
            captured.toolTip = context; captured.setAccessibilityLabel("Captured transfer context")
            sections.append(captured)
        }
        sections += [controls, scroll, detailScroll, locations]
        if !actionButtons.isEmpty { sections.append(itemActions) }
        let layout = stack(sections, orientation: .vertical, spacing: 8)
        layout.alignment = .leading
        pin(layout, inside: self)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            detailScroll.heightAnchor.constraint(equalToConstant: 120),
            locations.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
        if !actionButtons.isEmpty { itemActions.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        sections.first?.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        reload()
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { revealTask?.cancel(); revealTask = nil }
    }

    static func needsAttention(_ item: FileOperationOutcome) -> Bool {
        OperationResultDescription.needsAttention(item)
    }

    private func requiresAttention(_ item: FileOperationOutcome) -> Bool {
        describeItem?(item).needsAttention ?? resultDescription.itemNeedsAttention(item)
    }

    @objc private func toggleAttention(_ sender: Any?) { reload() }

    private func reload() {
        visibleItems = attention.state == .on ? resultDescription.result.items.filter(requiresAttention) : resultDescription.result.items
        table.reloadData()
        if !visibleItems.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateDetails()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row), let tableColumn else { return nil }
        let item = visibleItems[row]
        let text = tableColumn.identifier.rawValue == "result" ? describeItem?(item).title ?? resultDescription.itemTitle(item)
            : item.source?.lastPathComponent ?? item.destination?.lastPathComponent ?? "Operation"
        let field = label(text, size: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }

    private func updateDetails() {
        revealTask?.cancel(); revealTask = nil
        let row = table.selectedRow
        detail.string = visibleItems.indices.contains(row)
            ? describeItem?(visibleItems[row]).details ?? resultDescription.itemDetails(visibleItems[row])
            : "No items to display."
        copyButton.isEnabled = visibleItems.indices.contains(row)
        let selected = visibleItems.indices.contains(row) ? visibleItems[row] : nil
        sourceButton.isEnabled = selected?.source != nil
        destinationButton.isEnabled = selected?.destination != nil
        for (button, action) in zip(actionButtons, actions) {
            button.isEnabled = selected.map(action.available) ?? false
        }
    }

    @objc private func performSelectedAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag), visibleItems.indices.contains(table.selectedRow) else { return }
        let item = visibleItems[table.selectedRow], action = actions[sender.tag]
        guard action.available(item) else { return }; action.perform(item)
    }

    @objc private func copySelection(_ sender: Any?) {
        guard visibleItems.indices.contains(table.selectedRow) else { return }
        copyText(detail.string)
    }
    @objc private func showLogsPressed(_ sender: Any?) { showLogs?() }
    @objc private func revealSource(_ sender: Any?) {
        guard visibleItems.indices.contains(table.selectedRow), let url = visibleItems[table.selectedRow].source else { return }
        revealLocation(url)
    }
    @objc private func revealDestination(_ sender: Any?) {
        guard visibleItems.indices.contains(table.selectedRow), let url = visibleItems[table.selectedRow].destination else { return }
        revealLocation(url)
    }
    private func revealLocation(_ url: URL) {
        guard canReveal() else { return }
        if let reveal { reveal(url); return }
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            do {
                let location = try await Self.revealResolver.nearestExistingLocation(to: url, acquiring: { @MainActor [weak self] in
                    guard !Task.isCancelled, self?.canDeliverReveal == true,
                          let acquire = self?.acquireRevealAccess else { throw CancellationError() }
                    let access = await acquire(url)
                    guard !Task.isCancelled, self?.canDeliverReveal == true else { throw CancellationError() }
                    return access
                })
                #if DEBUG
                if let hook = self?.beforeRevealReturnsForVerification { await hook() }
                #endif
                guard let self, !Task.isCancelled, self.canDeliverReveal else { return }
                if let location {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                    if location != url { self.detail.string += "\n\nThe reported item is unavailable. Finder was asked to reveal its nearest available parent." }
                } else { self.detail.string += "\n\nNo existing location was found within the bounded parent lookup. Nothing was changed." }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.canDeliverReveal else { return }
                let reason = (error as? LocalStorageError)?.userMessage ?? "This location could not be inspected."
                self.detail.string += "\n\n" + reason + " Nothing was changed."
            }
        }
    }
    private var canDeliverReveal: Bool { window != nil && canReveal() }
    static func availableRevealLocation(for url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> URL? {
        try await revealResolver.nearestExistingLocation(to: url, retaining: lifetime)
    }
}

@MainActor
extension BrowserViewController {
    var canInspectLastOperationResult: Bool {
        guard !isBrowserSuspended, view.window != nil, view.window?.attachedSheet == nil else { return false }
        let queue = operationCoordinator.transfers
        if queue.reviewResult != nil { return queue.canInspect }
        return !hasExclusiveBrowserOperation && queue.state.active == nil && (lastOperationResult != nil || operationHistory.selectionGroup != nil)
    }

    @objc func showLastOperationResult(_ sender: Any?) {
        guard canInspectLastOperationResult else { return }
        if operationCoordinator.transfers.reviewResult != nil {
            showTransferQueue(sender)
            return
        }
        if operationHistory.selectionGroup != nil { showLastSelectionGroupResults(); return }
        if let batch = operationHistory.downloadBatch { showRemoteDownloadBatchResults(batch); return }
        guard let result = lastOperationResult else { return }
        showOperationResultSheet(result, recoveryAction: lastRecoveryAction)
    }

    func showOperationResultSheet(_ result: FileOperationResult, queuedResult: QueuedTransferResult? = nil,
                                  recoveryAction: CopyRecoveryAction? = nil) {
        guard !isBrowserSuspended, let window = view.window, window.attachedSheet == nil else { return }
        let queue = operationCoordinator.transfers
        let reviewIDAtPresentation = queue.reviewResultID
        let actionEngine = recoverableFileOperations
        let engineMatches = queuedResult.map { $0.engine === recoverableFileOperations } ?? (recoverableFileOperations != nil)
        let continuation: TransferContinuation?
        let recordID: UUID?
        if !engineMatches { continuation = nil; recordID = nil }
        else if let queuedResult { continuation = queuedResult.outcome.continuation; recordID = queuedResult.outcome.recordID }
        else { continuation = lastTransferContinuation; recordID = lastRecoveryRecordID }
        let alert = NSAlert()
        alert.messageText = result.disposition == .cancelled ? "Operation stopped" : "Operation results"
        // Queued transfer inspections always use their captured transfer result,
        // even if a different historical confirmation was shown more recently.
        let presentedRecoveryAction: CopyRecoveryAction?
        if case .some = queuedResult { presentedRecoveryAction = nil }
        else { presentedRecoveryAction = recoveryAction }
        alert.informativeText = OperationResultDescription(result: result, recoveryAction: presentedRecoveryAction).summary
        // Capture the result's own trace. A later queued job or menu action
        // must not silently substitute its logs for this reviewed operation.
        let logTrace: UUID?
        if let queuedResult { logTrace = queuedResult.diagnosticTrace }
        else { logTrace = operationHistory.diagnosticTrace }
        let logsResponse = NSApplication.ModalResponse(rawValue: 10_099)
        let showLogs: (() -> Void)? = logTrace.map { _ in
            { [weak window, weak alert] in
                guard let window, let alert, window.attachedSheet === alert.window else { return }
                window.endSheet(alert.window, returnCode: logsResponse)
            }
        }
        let resultView = OperationResultsView(result: result, context: queuedResult?.contextDescription, recoveryAction: presentedRecoveryAction,
            canReveal: { [weak self, weak window] in
                guard let self, let window else { return false }
                return !self.isBrowserSuspended && self.view.window === window
            }, acquireRevealAccess: { [weak self, weak window] url in
                guard let self, let window, !self.isBrowserSuspended, self.view.window === window,
                      !Task.isCancelled else { return nil }
                return await self.accessLifetime(for: [url])
            }, showLogs: showLogs) { [weak self] text in
            _ = self?.clipboardWriter(text, [])
            self?.synchronizeTransferClipboard()
        }
        alert.accessoryView = resultView
        alert.addButton(withTitle: "Done")
        enum ResultAction { case continuation(UUID), recovery(UUID), resume, folderAccess(URL?), logs(UUID) }
        var actions: [NSApplication.ModalResponse: ResultAction] = [:]
        if let logTrace { actions[logsResponse] = .logs(logTrace) }
        func add(_ title: String, action: ResultAction, enabled: Bool) {
            let button = alert.addButton(withTitle: title)
            button.isEnabled = enabled
            actions[NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + alert.buttons.count - 1)] = action
        }
        if OperationResultDescription(result: result).offersFolderAccess {
            alert.informativeText += "\n\n" + OperationResultDescription.folderAccessExplanation
            add("Choose Folder Access…", action: .folderAccess(queuedResult?.destination ?? location.directoryURL),
                enabled: !isReadOnlyFileSession && canRunExclusiveFileCommand)
        }
        if let continuation {
            alert.informativeText += "\n\nContinue Remaining rechecks \(continuation.remainingSources.count) known item(s). Completed or uncertain work is not blindly retried."
            add("Continue Remaining", action: .continuation(continuation.id), enabled: canContinueRemainingTransfer)
        }
        if let recordID {
            add("Open Recovery", action: .recovery(recordID), enabled: !isReadOnlyFileSession && canRunExclusiveFileCommand)
        }
        if queue.state.isPaused {
            alert.informativeText += "\n\nResume Queue starts only waiting jobs. This reviewed job stays protected and is not retried or recovered."
            add("Resume Queue", action: .resume, enabled: queue.canResume)
        }
        alert.window.initialFirstResponder = alert.buttons.first
        alert.beginSheetModal(for: window) { [weak self, weak resultView] response in
            guard let action = actions[response] else { return }
            // AppKit can invoke the completion while the ending sheet is still
            // attached. Re-enter only after teardown, then recheck authority.
            DispatchQueue.main.async { [weak self, weak resultView] in
                #if DEBUG
                defer { resultView?.resultActionFinishedForVerification?() }
                #endif
                guard let self, !self.isBrowserSuspended, self.view.window?.attachedSheet == nil else { return }
                switch action {
                case .logs(let trace):
                    TraverseHelpController.shared.showOperationLogs(trace, from: self)
                case .folderAccess(let initial):
                    self.requestOperationFolderAccess(initialDirectory: initial)
                case .continuation(let id):
                    guard self.recoverableFileOperations === actionEngine, self.lastTransferContinuation?.id == id else { return }
                    self.continueRemainingTransfer(nil)
                case .recovery(let id):
                    guard self.recoverableFileOperations === actionEngine else { return }
                    self.openOperationRecovery(recordID: id)
                case .resume:
                    guard queue.state.isPaused, queue.reviewResultID == reviewIDAtPresentation else { return }
                    _ = queue.resume()
                }
            }
        }
    }
}
