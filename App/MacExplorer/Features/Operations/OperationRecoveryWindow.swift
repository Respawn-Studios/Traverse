import AppKit
import FileOperations

/// A review surface only. All inverse filesystem work stays in the operation engine.
@MainActor
final class OperationRecoveryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = label("")
    private let selectionHeading = label("Select an operation", size: 16)
    private let selectionExplanation = NSTextField(wrappingLabelWithString: "")
    private let logsButton = NSButton(title: "App Logs…", target: nil, action: nil)
    private let filter = NSSegmentedControl(labels: ["Needs attention", "All operations"], trackingMode: .selectOne, target: nil, action: nil)
    private let detailsToggle = NSButton(checkboxWithTitle: "Details & recovery storage", target: nil, action: nil)
    private let advanced = NSStackView()
    private var allRecords: [OperationRecoveryRecord] = []
    private let undoButton = NSButton()
    private let recoverButton = NSButton()
    private let reviewCopiesButton = NSButton()
    private let cleanupButton = NSButton()
    private let loadMoreButton = NSButton()
    private let prepareHistoryButton = NSButton()
    private let onUndo: (OperationRecoveryRecord) -> Void
    private let onRecover: (OperationRecoveryRecord) -> Void
    private let onRefresh: () -> Void
    private let onCleanup: (RecoveryRetentionRecord) -> Void
    private let onCompact: () -> Void
    private let onInspectRetention: (UUID) -> Void
    private let onLoadMore: () -> Void
    private let onReviewCopiedFiles: (OperationRecoveryRecord) -> Void
    private let onPrepareHistory: () -> Void
    private let onReviewGrouping: ((OperationRecoveryRecord) -> Void)?
    private let onReviewTextVersions: ((OperationRecoveryRecord) -> Void)?
    private let onShowLogs: ((OperationRecoveryRecord) -> Void)?
    var onSelectedRecordChange: ((UUID?) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isClosed = true
    private var retention: [UUID: RecoveryRetentionRecord] = [:]
    private var records: [OperationRecoveryRecord] = []
    private var refusedEntries: [URL] = []
    private var requestedRecordID: UUID?
    private var requestedRecordMessage: String?
    private var isUpdatingSelection = false
    private var hasChosenInitialFilter = false
    private var selected: OperationRecoveryRecord? {
        records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
    }
    var selectedRecordID: UUID? { selected?.id }
    private static func holdsOrdinaryTrash(_ record: OperationRecoveryRecord) -> Bool {
        !NativeLocalProtectionPolicy.permitsTrashRecovery(record)
    }

    init(onUndo: @escaping (OperationRecoveryRecord) -> Void,
         onRecover: @escaping (OperationRecoveryRecord) -> Void, onRefresh: @escaping () -> Void,
         onCleanup: @escaping (RecoveryRetentionRecord) -> Void = { _ in }, onCompact: @escaping () -> Void = {},
         onInspectRetention: @escaping (UUID) -> Void = { _ in }, onLoadMore: @escaping () -> Void = {},
         onReviewCopiedFiles: @escaping (OperationRecoveryRecord) -> Void = { _ in },
         onPrepareHistory: @escaping () -> Void = {},
         onReviewGrouping: ((OperationRecoveryRecord) -> Void)? = nil,
         onReviewTextVersions: ((OperationRecoveryRecord) -> Void)? = nil,
         onShowLogs: ((OperationRecoveryRecord) -> Void)? = nil) {
        self.onUndo = onUndo; self.onRecover = onRecover; self.onRefresh = onRefresh
        self.onCleanup = onCleanup; self.onCompact = onCompact
        self.onInspectRetention = onInspectRetention
        self.onLoadMore = onLoadMore
        self.onReviewCopiedFiles = onReviewCopiedFiles
        self.onPrepareHistory = onPrepareHistory
        self.onReviewGrouping = onReviewGrouping
        self.onReviewTextVersions = onReviewTextVersions
        self.onShowLogs = onShowLogs
        let window = ToolWindowChrome.makeWindow(title: "Operation Recovery",
            size: .init(width: 820, height: 650), minimumSize: .init(width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window)
        window.delegate = self
        for (id, title, width) in [("when", "When", 185.0), ("operation", "Operation", 160.0), ("state", "Status", 320.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false; InterfaceMetrics.setRowHeight(table, base: 27)
        table.setAccessibilityLabel("Recoverable file operations")
        let listing = NSScrollView(); listing.documentView = table; listing.hasVerticalScroller = true
        listing.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true
        detail.isEditable = false; detail.isSelectable = true
        detail.isRichText = false; InterfaceMetrics.setFont(detail, base: .systemFont(ofSize: 12))
        detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detail.textContainerInset = NSSize(width: 8, height: 8)
        details.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let detailHeight = details.heightAnchor.constraint(equalToConstant: 130)
        detailHeight.priority = .defaultHigh; detailHeight.isActive = true
        undoButton.title = "Undo Selected"; undoButton.bezelStyle = .rounded
        undoButton.target = self; undoButton.action = #selector(undoSelected(_:))
        recoverButton.title = "Restore Original State"; recoverButton.bezelStyle = .rounded
        recoverButton.target = self; recoverButton.action = #selector(recoverSelected(_:))
        reviewCopiesButton.title = "Review Copied Files…"; reviewCopiesButton.bezelStyle = .rounded
        reviewCopiesButton.target = self; reviewCopiesButton.action = #selector(reviewCopiedFiles(_:))
        reviewCopiesButton.isHidden = true
        let refresh = ActionButton(title: "Refresh", action: onRefresh)
        let show = ActionButton(title: "Show Locations in Finder", action: { [weak self] in
            guard let self else { return }
            let locations = self.selected?.locations ?? self.refusedEntries
            guard !locations.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(Array(locations.prefix(16)))
        })
        let buttons = stack([undoButton, recoverButton, reviewCopiesButton, refresh, show], orientation: .horizontal)
        cleanupButton.title = "Move Recovery Copies to Trash…"; cleanupButton.bezelStyle = .rounded
        cleanupButton.target = self; cleanupButton.action = #selector(cleanupSelected(_:))
        let compact = ActionButton(title: "Compact Journal Metadata", action: onCompact)
        loadMoreButton.title = "Load Earlier Operations"; loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self; loadMoreButton.action = #selector(loadMore(_:))
        loadMoreButton.isHidden = true
        let maintenance = stack([cleanupButton, compact], orientation: .horizontal)
        let help = label("Recovery copies support Undo and restoration. Cleanup checks the retained copies before moving them to Trash; it ends Undo for that operation. Reported size may differ from space reclaimed.", size: 12, color: .secondaryLabelColor)
        help.maximumNumberOfLines = 2
        prepareHistoryButton.title = "Prepare History for Review…"; prepareHistoryButton.bezelStyle = .rounded
        prepareHistoryButton.target = self; prepareHistoryButton.action = #selector(prepareHistory(_:))
        prepareHistoryButton.isHidden = true
        prepareHistoryButton.setAccessibilityIdentifier("prepare-operation-history")
        filter.selectedSegment = 1; filter.target = self; filter.action = #selector(changeFilter(_:))
        filter.setAccessibilityLabel("File operation filter")
        detailsToggle.target = self; detailsToggle.action = #selector(toggleDetails(_:))
        detailsToggle.setAccessibilityIdentifier("operation-recovery-details")
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 10
        for view in [details, help, maintenance] { advanced.addArrangedSubview(view) }
        advanced.isHidden = true
        selectionHeading.font = .systemFont(ofSize: 16, weight: .semibold)
        logsButton.bezelStyle = .rounded; logsButton.target = self
        logsButton.action = #selector(showSelectedLogs(_:))
        logsButton.isHidden = onShowLogs == nil
        logsButton.toolTip = "Review the retained app logs linked to this operation. Older logs may no longer be available."
        let headingRow = stack([selectionHeading, logsButton], orientation: .horizontal, spacing: 12)
        selectionHeading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectionHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logsButton.setContentHuggingPriority(.required, for: .horizontal)
        logsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        selectionHeading.lineBreakMode = .byTruncatingTail
        selectionExplanation.textColor = .secondaryLabelColor; selectionExplanation.maximumNumberOfLines = 0
        let layout = stack([summary, filter, prepareHistoryButton, listing, loadMoreButton,
                            headingRow, selectionExplanation, buttons, detailsToggle, advanced], orientation: .vertical, spacing: 12)
        layout.alignment = .leading
        guard let content = window.contentView else { return }
        pin(layout, inside: content, inset: 16)
        for view in [summary, listing, headingRow, selectionExplanation, advanced] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        for view in [details, help] { view.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true }
        ToolWindowChrome.install(in: window)
        ToolWindowChrome.position(window, relativeTo: NSApplication.shared.mainWindow)
    }

    required init?(coder: NSCoder) { nil }
    func beginReview() { isClosed = false; if let window { ToolWindowCloseMotion.cancel(window) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { ToolWindowCloseMotion.shouldClose(sender) }
    @objc private func toggleDetails(_ sender: Any?) {
        advanced.isHidden = detailsToggle.state != .on
        if !advanced.isHidden {
            if let window, window.frame.height < 820 {
                let visible = window.screen?.visibleFrame ?? window.frame
                let height = min(820, visible.height - 24)
                var frame = window.frame
                frame.origin.y -= max(0, height - frame.height); frame.size.height = max(frame.height, height)
                frame.origin.y = max(visible.minY, frame.origin.y)
                let motion = InterfacePresentation.shared.motion
                window.setFrame(frame, display: true, animate: motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
            ToolContentMotion.reveal(advanced)
        }
    }
    private static func needsAttention(_ record: OperationRecoveryRecord) -> Bool {
        record.requiresManualTrashReview || record.canRecover || record.canRestoreOriginalZIP
            || ["needsReview", "cleanupReview", "trashDeleteReview"].contains(record.state)
    }
    @objc private func changeFilter(_ sender: Any?) {
        hasChosenInitialFilter = true
        requestedRecordID = nil; requestedRecordMessage = nil
        applyFilter(preserving: selected?.id)
        if let selected { onInspectRetention(selected.id) }
    }
    private func applyFilter(preserving selectedID: UUID?) {
        let oldUpdating = isUpdatingSelection; isUpdatingSelection = true
        defer { isUpdatingSelection = oldUpdating }
        records = filter.selectedSegment == 0 ? allRecords.filter(Self.needsAttention) : allRecords
        table.reloadData()
        if let selectedID, let row = records.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !records.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateSelection()
    }
    func windowWillClose(_ notification: Notification) { isClosed = true; onClose?() }

    /// Keep the requested job selected through asynchronous inspection. Never
    /// substitute the newest unrelated record while that job is loading.
    func requestSelection(recordID: UUID) {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        requestedRecordID = recordID
        if let record = allRecords.first(where: { $0.id == recordID }), !Self.needsAttention(record) {
            filter.selectedSegment = 1; applyFilter(preserving: recordID)
        }
        requestedRecordMessage = "Loading the requested operation. No recovery action has started."
        selectRequestedRecord()
    }

    func showRequestedRecordUnavailable(_ message: String) {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        requestedRecordMessage = message
        table.deselectAll(nil)
        updateSelection()
    }

    private func selectRequestedRecord() {
        if let id = requestedRecordID, let row = records.firstIndex(where: { $0.id == id }) {
            requestedRecordMessage = nil
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
        updateSelection()
    }

    func update(records: [OperationRecoveryRecord], refusedEntries: [URL], hasMore: Bool = false,
                unfinishedCount: Int = 0, historyMessage: String? = nil, canPrepareHistory: Bool = false) {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        let selectedID = selected?.id
        allRecords = records
        self.refusedEntries = refusedEntries
        if !hasChosenInitialFilter, !records.isEmpty || unfinishedCount > 0 || !refusedEntries.isEmpty {
            filter.selectedSegment = records.contains(where: Self.needsAttention)
                || unfinishedCount > 0 || !refusedEntries.isEmpty ? 0 : 1
            hasChosenInitialFilter = true
        }
        if let requestedRecordID, let record = records.first(where: { $0.id == requestedRecordID }), !Self.needsAttention(record) {
            filter.selectedSegment = 1
        }
        applyFilter(preserving: selectedID)
        filter.setLabel("Needs attention · \(records.filter(Self.needsAttention).count)", forSegment: 0)
        if requestedRecordID != nil { selectRequestedRecord() }
        else if let selectedID, let row = self.records.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !self.records.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        loadMoreButton.isHidden = !hasMore
        summary.stringValue = "\(records.count) recorded operation\(records.count == 1 ? "" : "s") loaded"
            + (hasMore ? " · earlier operations available" : "")
            + (unfinishedCount > 0 ? " · \(unfinishedCount) require review" : "")
            + (refusedEntries.isEmpty ? "" : " · \(refusedEntries.count) unreadable or unrecognized record\(refusedEntries.count == 1 ? " was" : "s were") preserved")
        if let historyMessage { summary.stringValue = historyMessage }
        prepareHistoryButton.isHidden = !canPrepareHistory
        updateSelection()
    }

    @objc private func prepareHistory(_ sender: Any?) { onPrepareHistory() }
    #if DEBUG
    var offersHistoryPreparationForVerification: Bool { !prepareHistoryButton.isHidden }
    #endif

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func updateRetention(records: [RecoveryRetentionRecord]) {
        retention = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        updateSelection()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        switch tableColumn?.identifier.rawValue {
        case "when": return label(record.createdAt.formatted(date: .abbreviated, time: .shortened), size: 12)
        case "operation": return label(record.kind == .selectionGroup ? "Organize Selection" : record.operation)
        default: return label(Self.statusText(record))
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        if let selected, selected.id != requestedRecordID {
            requestedRecordID = nil; requestedRecordMessage = nil
        }
        updateSelection()
        ToolContentMotion.reveal(detail)
        if let selected { onInspectRetention(selected.id) }
    }
    private func updateSelection() {
        logsButton.isEnabled = selected != nil && onShowLogs != nil
        let heldTrash = selected.map(Self.holdsOrdinaryTrash) == true
        undoButton.isEnabled = selected?.canUndo == true && !heldTrash
        let canRestoreZIP = selected?.canRestoreOriginalZIP == true
        recoverButton.isEnabled = (selected?.canRecover == true || canRestoreZIP) && !heldTrash
        recoverButton.title = canRestoreZIP ? "Restore Original ZIP" : "Restore Original State"
        let grouped = selected?.kind == .groupedCopy
        let selectionGroup = selected?.kind == .selectionGroup
        let textRevision = selected?.kind == .textRevision
        undoButton.isHidden = textRevision || selected?.canUndo != true
        recoverButton.isHidden = grouped || selectionGroup || textRevision || (selected?.canRecover != true && !canRestoreZIP)
        reviewCopiesButton.isHidden = !grouped && !selectionGroup && !textRevision
        reviewCopiesButton.title = textRevision ? "Review Saved Versions…" : selectionGroup ? "Review Grouping…" : "Review Copied Files…"
        reviewCopiesButton.isEnabled = grouped || (selectionGroup && onReviewGrouping != nil)
            || (textRevision && onReviewTextVersions != nil)
        undoButton.title = selectionGroup ? "Undo Grouping" : "Undo Selected"
        cleanupButton.title = selectionGroup ? "Clean Up Temporary Folders…" : "Move Recovery Copies to Trash…"
        let hasCleanup = !textRevision && selected.flatMap { retention[$0.id] }?.canCleanup == true
        cleanupButton.isEnabled = hasCleanup && OrdinaryNativeTrashFeature.available
        cleanupButton.isHidden = !hasCleanup
        undoButton.toolTip = heldTrash ? OrdinaryNativeTrashFeature.recoveryHoldMessage : nil
        recoverButton.toolTip = heldTrash ? OrdinaryNativeTrashFeature.recoveryHoldMessage : nil
        cleanupButton.toolTip = !OrdinaryNativeTrashFeature.available ? OrdinaryNativeTrashFeature.retirementHoldMessage : nil
        if let selected {
            selectionHeading.stringValue = selected.kind == .selectionGroup ? "Organize Selection" : selected.operation
            selectionExplanation.stringValue = Self.explanation(selected)
            detail.string = "\(selectionGroup ? "Organize Selection" : selected.operation)\n\(selected.state)\n\n"
                + selected.locations.prefix(32).map(\.path).joined(separator: "\n")
                + "\n\nRecovery rechecks the recorded items. Changed, missing or ambiguous locations are preserved for review."
            if selected.requiresManualTrashReview {
                detail.string += "\n\nThis Trash attempt has no verified result. The original may remain in place or may have moved. Listed locations are clues, not proof of an item’s current identity or contents. Traverse cannot Undo, restore, clean up, or retry this job. Use Show Locations in Finder to inspect known paths, and resolve the item manually only after you recognize and verify it. This record remains in review."
            }
            if heldTrash { detail.string += "\n\n" + OrdinaryNativeTrashFeature.recoveryHoldMessage }
            if selected.nativeTrashMarkChanged {
                detail.string += "\n\nmacOS updated security information during the move. Traverse checks that this is the same file before restoring it."
            }
            if hasCleanup && !OrdinaryNativeTrashFeature.available {
                detail.string += "\n\n" + OrdinaryNativeTrashFeature.retirementHoldMessage
            }
            if selected.zipReplacementNotStarted {
                detail.string += "\n\nNo replacement step was recorded for this job. Traverse did not rename the original ZIP or publish a replacement. This history view has not verified the ZIP’s current identity or contents. Any retained preparation files stay protected; inspect the listed locations before further changes."
            }
            if let backups = retention[selected.id] {
                detail.string += selectionGroup
                    ? "\n\nTemporary folders support Undo for this grouping. Cleanup checks these folders; your organized files are preserved."
                    : "\n\nRecovery backups: " + (backups.logicalBytes.map(FileSizeText.string) ?? "size not fully available")
                if let reason = backups.protectionReason { detail.string += "\n" + reason }
                detail.string += "\n" + backups.areas.prefix(16).map { area in
                    area.url.path + (area.verified ? " · verified" : " · protected")
                }.joined(separator: "\n")
            } else { detail.string += "\n\nBackup verification has not finished." }
        } else {
            let attentionOnly = filter.selectedSegment == 0 && requestedRecordID == nil
            selectionHeading.stringValue = !refusedEntries.isEmpty ? "Some history needs inspection"
                : attentionOnly ? "No loaded operations need attention" : "Select an operation"
            selectionExplanation.stringValue = requestedRecordMessage
                ?? (!refusedEntries.isEmpty ? "Some operation records couldn’t be read. Show their locations to inspect them."
                    : attentionOnly ? "Choose All operations to review completed actions or Undo."
                    : "Choose an operation to see its result and available actions.")
            detail.string = requestedRecordMessage ?? "Select an operation to inspect its locations and available actions."
        }
        if !refusedEntries.isEmpty {
            detail.string += "\n\nUnreadable or unrecognized records preserved for inspection:\n"
                + refusedEntries.prefix(32).map(\.path).joined(separator: "\n")
                + (refusedEntries.count > 32 ? "\nShowing the first 32 of \(refusedEntries.count) preserved paths." : "")
        }
        onSelectedRecordChange?(selected?.id)
    }
    private static func statusText(_ record: OperationRecoveryRecord) -> String {
        if record.requiresManualTrashReview { return "Trash result uncertain · inspect locations" }
        if record.zipReplacementNotStarted { return "Stopped before ZIP replacement" }
        if holdsOrdinaryTrash(record) { return "Trash history · actions held for this beta" }
        if record.canRestoreOriginalZIP { return "ZIP update interrupted" }
        if record.canRecover { return "Review interrupted operation" }
        if record.canUndo {
            return record.state == "committed"
                ? "Completed · Undo available" : "Recorded changes · Undo available"
        }
        switch record.state {
        case "committed": return "Completed"
        case "needsReview", "cleanupReview": return "Review required · inspect retained locations"
        case "trashDeleteReview": return "Permanent deletion needs review"
        case "trashDeleted": return "Trash items permanently deleted"
        case "cleaned": return "Backups moved to Trash · Undo ended"
        default: return record.state.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    private static func explanation(_ record: OperationRecoveryRecord) -> String {
        if record.requiresManualTrashReview {
            return "Traverse couldn’t verify where this item ended up. Inspect the recorded locations before making further changes. This earlier result can’t be undone automatically."
        }
        if holdsOrdinaryTrash(record) { return OrdinaryNativeTrashFeature.recoveryHoldMessage }
        if record.zipReplacementNotStarted {
            return "Traverse stopped while preparing this ZIP, before replacing the original. Any preparation files are retained for review. Inspect the recorded locations before making further changes."
        }
        if record.canRestoreOriginalZIP {
            return "The ZIP update stopped before the edited archive was put in place. Restore Original ZIP checks the retained original before returning it to its previous location. If the files changed, they stay in place for review."
        }
        if record.kind == .textRevision { return "Review the retained text versions before choosing what to keep or export." }
        if record.state == "trashDeleteReview" {
            return "Permanent deletion could not confirm every item. This group cannot be restored as a whole. Review its recorded item outcomes and locations before making further changes."
        }
        if record.state == "trashDeleted" { return "This group’s Trash copies were permanently deleted. Restore is no longer available." }
        if record.canRecover { return "This operation was interrupted. Restore Original State checks the recorded changes and keeps existing occupants." }
        if record.kind == .groupedCopy { return "Review the completed copies and any items that still need attention. The originals remain at their source." }
        if record.canUndo { return "The operation finished. Undo checks the recorded items before reversing its changes." }
        if ["needsReview", "cleanupReview"].contains(record.state) { return "Some changes couldn’t be confirmed. Retained copies and recorded locations stay available for inspection." }
        if record.state == "cleaned" { return "Recovery copies were moved to Trash. Undo is no longer available for this operation." }
        return "This operation has no available Undo or restoration action. Its recorded details remain available below."
    }
    @objc private func undoSelected(_ sender: Any?) {
        guard let selected, selected.canUndo, !Self.holdsOrdinaryTrash(selected) else { return }
        onUndo(selected)
    }
    @objc private func showSelectedLogs(_ sender: Any?) {
        guard let selected else { return }
        onShowLogs?(selected)
    }
    @objc private func reviewCopiedFiles(_ sender: Any?) {
        guard let selected else { return }
        if selected.kind == .selectionGroup { onReviewGrouping?(selected) }
        else if selected.kind == .groupedCopy { onReviewCopiedFiles(selected) }
        else if selected.kind == .textRevision { onReviewTextVersions?(selected) }
    }
    #if DEBUG
    var verificationCanReviewCopiedFiles: Bool { !reviewCopiesButton.isHidden && reviewCopiesButton.isEnabled }
    func verificationReviewCopiedFiles() { reviewCopiesButton.performClick(nil) }
    #endif
    @objc private func cleanupSelected(_ sender: Any?) {
        guard OrdinaryNativeTrashFeature.available,
              let record = selected.flatMap({ retention[$0.id] }), record.canCleanup else { return }
        onCleanup(record)
    }
    @objc private func loadMore(_ sender: Any?) { onLoadMore() }
    @objc private func recoverSelected(_ sender: Any?) {
        guard let selected, selected.canRecover || selected.canRestoreOriginalZIP,
              !Self.holdsOrdinaryTrash(selected) else { return }
        let alert = NSAlert()
        let restoringZIP = selected.canRestoreOriginalZIP
        alert.messageText = restoringZIP ? "Restore the original ZIP?" : "Restore the original state of this interrupted operation?"
        alert.informativeText = restoringZIP
            ? "Traverse checks the retained original before returning it to its previous location. Any file already there will be kept. The edited preparation copy stays available for review."
            : "Only recorded changes that can still be verified will be reversed. Existing occupants will be kept. Uncertain locations will remain for review."
        alert.addButton(withTitle: restoringZIP ? "Restore Original ZIP" : "Restore Original State")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertFirstButtonReturn { self?.onRecover(selected) }
        }
    }
}
