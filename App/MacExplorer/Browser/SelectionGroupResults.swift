import AppKit
import FileOperations

/// A grouping job never becomes a generic transfer result. The originating
/// engine remains captured with its opaque result, including after navigation.
@MainActor
struct SelectionGroupPresentation {
    enum Completion {
        case grouping(SelectionGroupResult)
        case cleanup(RecoverableOperationResult, recordID: UUID)
    }
    let completion: Completion
    let engine: RecoverableFileOperations
    let title: String
    let diagnosticTrace: UUID?
    init(result: SelectionGroupResult, engine: RecoverableFileOperations, title: String, diagnosticTrace: UUID? = nil) {
        completion = .grouping(result); self.engine = engine; self.title = title; self.diagnosticTrace = diagnosticTrace
    }
    init(cleanup: RecoverableOperationResult, recordID: UUID, engine: RecoverableFileOperations, diagnosticTrace: UUID?) {
        completion = .cleanup(cleanup, recordID: recordID); self.engine = engine
        title = "Grouping Folder Cleanup"; self.diagnosticTrace = diagnosticTrace
    }
    var result: SelectionGroupResult? { if case .grouping(let value) = completion { value } else { nil } }
    var cleanupOutcome: RecoverableOperationResult? { if case .cleanup(let value, _) = completion { value } else { nil } }
    var recordID: UUID? {
        switch completion { case .grouping(let value): value.recordID; case .cleanup(_, let id): id }
    }
    var knownLocations: [URL] {
        switch completion {
        case .grouping(let value): value.knownLocations
        case .cleanup(let value, _): value.result.items.flatMap { [$0.source, $0.destination].compactMap { $0 } }
        }
    }
    var summary: String {
        switch completion {
        case .grouping(let value): SelectionGroupResultDescription(result: value).summary
        case .cleanup(let value, _):
            switch value.result.disposition {
            case .succeeded: "Recovery folder cleanup finished."
            case .partial: "Recovery folder cleanup is incomplete. Review the reported locations."
            case .cancelled: "Recovery folder cleanup stopped. Review the reported locations."
            case .failed: "Recovery folder cleanup could not finish. Review the reported locations."
            }
        }
    }
    var detail: String {
        switch completion {
        case .grouping(let value): return SelectionGroupResultDescription(result: value).detail
        case .cleanup(let value, _):
            return summary + "\n\n" + value.result.items.map {
                SelectionGroupResultDescription.status($0.status)
                    + ($0.source.map { "\nFrom: " + $0.path } ?? "")
                    + ($0.destination.map { "\nTo: " + $0.path } ?? "")
            }.joined(separator: "\n\n")
        }
    }
}

struct SelectionGroupResultDescription {
    let result: SelectionGroupResult
    var summary: String {
        guard result.authoritative else { return "Current status could not be confirmed. Review the item locations." }
        switch result.state {
        case .notStarted: return "Grouping did not start."
        case .grouped: return "Selected items were grouped in the new folder."
        case .undone: return "Grouping was undone."
        case .membersRestored: return "Items have returned. The new folder still needs attention."
        case .partial: return "Some items may have moved. Review their locations."
        case .uncertain: return "Check the item locations before choosing another action."
        case .cleaned: return "Recovery folder cleanup is complete."
        }
    }
    var detail: String {
        summary + "\nAction status: " + Self.status(result.status)
            + (result.cancellationRequested ? "\nStop was requested. Completed changes were kept." : "")
            + "\n\nReported locations include the original folder, the new folder and recovery folders. Review the item list for individual status."
    }
    static func reviewState(_ state: String) -> String {
        switch state {
        case "preparing": "Preparing"
        case "active": "In progress"
        case "completed": "Grouped"
        case "stoppedSettled": "Stopped"
        case "undoing": "Undo in progress"
        case "membersRestored": "Items returned; folder needs attention"
        case "undone": "Undone"
        case "closedRetained": "Current locations kept; Undo ended"
        case "cleanupPending": "Folder cleanup needs attention"
        case "cleaned": "Recovery folder cleanup complete"
        default: "Needs review"
        }
    }
    static func itemState(_ state: String) -> String {
        switch state {
        case "unstarted": "Not moved"
        case "grouped": "In new folder"
        case "originalConfirmed": "Original location confirmed"
        case "restored": "Returned"
        default: "Needs review"
        }
    }
    static func problem(_ problem: SelectionGroupProblem) -> String {
        switch problem {
        case .denied: "Folder access was denied."
        case .disconnectedOrUnavailable: "A required folder is disconnected or unavailable."
        case .unsupported: "This location cannot support the requested action."
        case .changed: "An item or folder changed."
        case .conflict: "An item is in the way. Nothing will be replaced."
        case .unreadable: "An item or folder could not be read."
        case .uncertain: "Current status could not be confirmed."
        }
    }
    static func status(_ status: FileOperationStatus) -> String {
        switch status {
        case .succeeded: return "Completed"
        case .skipped: return "Skipped"
        case .notStarted: return "Not started"
        case .cancelled: return "Stopped"
        case .failed(let failure): return failure.userMessage
        }
    }
}

extension SelectionGroupDisposition {
    var selectionGroupTitle: String {
        switch self {
        case .confirmObservedLocation: "Confirm Item Location"
        case .keepCurrentLocations: "Keep Current Locations"
        case .confirmCleanup: "Confirm Folder Cleanup"
        }
    }
    var selectionGroupExplanation: String {
        switch self {
        case .confirmObservedLocation: "Confirm where this item is now. The item stays in that location."
        case .keepCurrentLocations: "Keep the items where they are and end the remaining Undo for this operation. The items will not move."
        case .confirmCleanup: "Confirm that the empty recovery folder has been cleaned up. Other items are kept."
        }
    }
}

/// Virtualized native evidence view. Inspection belongs to one actual task;
/// cancellation invalidates publication but retains that task until it drains.
@MainActor
final class SelectionGroupResultsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let instances = NSHashTable<SelectionGroupResultsWindow>.weakObjects()
    static func closeAllAndDrain() async {
        let windows = instances.allObjects
        for window in windows { window.cancelInspection(); window.close() }
        for window in windows { await window.drain() }
    }
    #if DEBUG
    static var pendingInspectionCountForVerification: Int { instances.allObjects.filter { $0.inspectionTask != nil }.count }
    #endif

    let recordID: UUID?
    let engine: RecoverableFileOperations
    private let table = NSTableView()
    private struct DisplayRow: Equatable {
        let source: String, destination: String, status: String
    }
    // Pure presentation: retaining a row never retains a review token/access.
    private var displayedRows: [DisplayRow] = []
    private let detail = NSTextView()
    private let summary = label("Grouping Results")
    private let notice = label("Reading the item status does not change files.", size: 12, color: .secondaryLabelColor)
    private let outcome = label("", size: 12, color: .secondaryLabelColor)
    private let disposition = label("", size: 12)
    private var afterInspection: (() -> Void)?
    private let refreshButton = NSButton()
    private let undoButton = NSButton()
    private var buttons: [SelectionGroupDisposition: NSButton] = [:]
    private let onAction: (SelectionGroupDisposition?, SelectionGroupReview, UUID) -> Void
    private let onRefresh: () -> Void
    var onClose: (() -> Void)?
    var hostObservation: BrowserNotificationObservation?
    var inspectionTask: Task<Void, Never>?
    private(set) var inspectionID = UUID()
    private(set) var presentationID = UUID()
    private(set) var review: SelectionGroupReview?
    private(set) var presentation: SelectionGroupPresentation?
    private(set) var retainedAccess: FileAccessLifetimes?
    private(set) var isClosed = false
    private(set) var isBusy = false

    init(recordID: UUID?, engine: RecoverableFileOperations, presentation: SelectionGroupPresentation?,
         onAction: @escaping (SelectionGroupDisposition?, SelectionGroupReview, UUID) -> Void,
         onRefresh: @escaping () -> Void) {
        self.recordID = recordID; self.engine = engine; self.presentation = presentation
        self.onAction = onAction; self.onRefresh = onRefresh
        let window = ToolWindowChrome.makeWindow(
            title: (presentation?.title ?? "New Folder with Selection") + " · Results",
            size: .init(width: 980, height: 650), minimumSize: .init(width: 820, height: 540),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window)
        Self.instances.add(self)
        window.delegate = self
        for (id, title, width) in [("source", "Original location", 360.0), ("destination", "Grouped location", 360.0), ("state", "Recorded status", 200.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title
            column.width = width; column.minWidth = 120; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.style = .plain
        table.headerView = FileTableHeaderView(frame: .init(x: 0, y: 0, width: 980, height: 28))
        table.columnAutoresizingStyle = .noColumnAutoresizing
        InterfaceMetrics.setRowHeight(table, base: 28)
        table.setAccessibilityLabel("Grouping items and recovery status")
        let listing = NSScrollView(); listing.documentView = table
        listing.hasVerticalScroller = true; listing.hasHorizontalScroller = true
        listing.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        detail.isEditable = false; detail.isSelectable = true; detail.isRichText = false
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        InterfaceMetrics.setFont(detail, base: .systemFont(ofSize: 12))
        detail.setAccessibilityLabel("Selected item paths and operation details")
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true
        details.heightAnchor.constraint(equalToConstant: 130).isActive = true
        var actions: [NSView] = []
        for action in [SelectionGroupDisposition.confirmObservedLocation, .keepCurrentLocations, .confirmCleanup] {
            let button = NSButton(title: action.selectionGroupTitle, target: self, action: #selector(confirm(_:)))
            button.identifier = .init(action.rawValue); button.bezelStyle = .rounded
            button.toolTip = action.selectionGroupExplanation; button.isEnabled = false
            buttons[action] = button; actions.append(button)
        }
        undoButton.title = "Undo Grouping"; undoButton.bezelStyle = .rounded
        undoButton.target = self; undoButton.action = #selector(undo(_:)); undoButton.isEnabled = false
        undoButton.toolTip = "Restore the selected items to their original locations after checking them again. Changed items are kept."
        refreshButton.title = "Refresh Review"; refreshButton.bezelStyle = .rounded
        refreshButton.target = self; refreshButton.action = #selector(refresh(_:))
        refreshButton.keyEquivalent = "r"; refreshButton.keyEquivalentModifierMask = .command
        let close = NSButton(title: "Close", target: self, action: #selector(closeResults(_:)))
        close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let actionsRow = stack(actions, orientation: .vertical, spacing: 6)
        actionsRow.alignment = .leading
        let navigation = stack([undoButton, refreshButton, close], orientation: .horizontal, spacing: 8)
        for field in [summary, notice, outcome, disposition] { field.maximumNumberOfLines = 3; field.cell?.wraps = true }
        let explanation = label("Choose an available action below. Each action checks the items again and keeps changed or uncertain files.", size: 12, color: .secondaryLabelColor)
        explanation.maximumNumberOfLines = 2; explanation.cell?.wraps = true
        let layout = stack([summary, outcome, notice, disposition, listing, details, explanation, actionsRow, navigation], orientation: .vertical, spacing: 10)
        layout.alignment = .leading
        guard let content = window.contentView else { return }
        pin(layout, inside: content, inset: 16)
        for view in [summary, outcome, notice, disposition, listing, details, explanation, actionsRow, navigation] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        window.initialFirstResponder = table
        ToolWindowChrome.install(in: window)
        ToolWindowChrome.position(window, relativeTo: NSApplication.shared.mainWindow)
        updateOutcome(); updateActions(); updateDetail()
    }
    required init?(coder: NSCoder) { nil }

    #if DEBUG
    var undoButtonForVerification: NSButton { undoButton }
    var refreshButtonForVerification: NSButton { refreshButton }
    func buttonForVerification(_ action: SelectionGroupDisposition) -> NSButton? { buttons[action] }
    var summaryForVerification: String { summary.stringValue }
    var noticeForVerification: String { notice.stringValue }
    var outcomeForVerification: String { outcome.stringValue }
    var tableForVerification: NSTableView { table }
    var detailForVerification: NSTextView { detail }
    var dispositionForVerification: String { disposition.stringValue }
    #endif

    @discardableResult func beginLoading() -> UUID? {
        guard !isClosed, inspectionTask == nil, !isBusy, recordID != nil else { return nil }
        inspectionID = UUID(); presentationID = UUID(); isBusy = true
        review = nil; retainedAccess = nil
        notice.stringValue = "Refreshing locations. Showing the previous observation."
        updateActions(); updateDetail()
        return inspectionID
    }
    func update(_ review: SelectionGroupReview, retaining access: FileAccessLifetimes) {
        guard !isClosed, review.recordID == recordID, review.items.count <= 512 else { return }
        self.review = review; retainedAccess = access; presentationID = UUID(); isBusy = false
        summary.stringValue = "\(review.items.count) selected items · \(SelectionGroupResultDescription.reviewState(review.state))"
        notice.stringValue = review.problem.map { SelectionGroupResultDescription.problem($0) + " Review the item locations before continuing." }
            ?? "Choose an available action. Each action checks the items again before making changes."
        display(review.items.enumerated().map { index, item in
            DisplayRow(source: item.source.path, destination: item.destination.path,
                status: Self.rowStatus(review, row: index))
        })
        updateActions(); updateDetail()
    }
    func updateOutcome(_ presentation: SelectionGroupPresentation) {
        guard presentation.engine === engine, presentation.recordID == recordID else { return }
        self.presentation = presentation; updateOutcome(); updateDetail()
    }
    private func updateOutcome() {
        outcome.stringValue = presentation.map { "Last reported result: " + $0.summary }
            ?? "Earlier grouping operation. Item status is shown below."
        if review == nil, !isBusy { display(reportedRows) }
    }
    func showUnavailable(_ message: String) {
        review = nil; retainedAccess = nil; presentationID = UUID(); isBusy = false
        notice.stringValue = message; display(reportedRows); updateActions(); updateDetail()
    }
    func showNotice(_ message: String) { notice.stringValue = message }
    func setWorking(_ message: String) { isBusy = true; notice.stringValue = message; updateActions() }
    func drain() async { await inspectionTask?.value }
    func cancelInspection() {
        inspectionID = UUID(); presentationID = UUID(); inspectionTask?.cancel()
        review = nil; retainedAccess = nil; isBusy = false; updateActions()
    }
    func windowWillClose(_ notification: Notification) {
        isClosed = true; afterInspection = nil; cancelInspection(); hostObservation = nil; onClose?()
        // inspectionTask is intentionally retained until the actual reader returns.
    }
    private func updateActions() {
        for (action, button) in buttons {
            if review != nil || !isBusy { button.isHidden = review?.actions.contains(action) != true }
            button.isEnabled = !isClosed && !isBusy && review.map { Self.canOffer(action, from: $0) } == true
            if isBusy, review == nil { continue }
            if action == .confirmObservedLocation {
                switch review?.pending?.kind {
                case .publication: button.title = "Confirm New Folder Location"
                case .folderRetirement: button.title = "Confirm Empty Folder Location"
                default: button.title = action.selectionGroupTitle
                }
                button.toolTip = review?.pending.map(Self.pendingDetail) ?? "Refresh to check which location would be confirmed."
            } else if action == .confirmCleanup {
                button.toolTip = review?.verifiedCleanupTarget.map { "Confirm completed cleanup of the empty recovery folder now at: " + $0.path }
                    ?? "The recovery folder’s current location could not be confirmed. Refresh before confirming cleanup."
            }
        }
        undoButton.isEnabled = !isClosed && !isBusy && review?.canUndo == true
        refreshButton.isEnabled = !isClosed && !isBusy && inspectionTask == nil && recordID != nil
    }
    func afterInspectionDrain(_ action: @escaping () -> Void) {
        guard !isClosed else { return }
        if inspectionTask == nil { action() } else { afterInspection = action }
    }
    func inspectionDidDrain() {
        inspectionTask = nil; updateActions()
        let action = afterInspection; afterInspection = nil
        if !isClosed { action?() }
    }
    static func canOffer(_ action: SelectionGroupDisposition, from review: SelectionGroupReview) -> Bool {
        guard review.actions.contains(action) else { return false }
        switch action {
        case .keepCurrentLocations: return true
        case .confirmCleanup: return review.verifiedCleanupTarget?.isFileURL == true
        case .confirmObservedLocation:
            guard let pending = review.pending, pending.observedURL?.isFileURL == true, pending.side != nil else { return false }
            switch pending.kind {
            case .publication, .folderRetirement: return pending.memberIndex == nil
            case .memberMove, .memberReturn: return pending.memberIndex.map { review.items.indices.contains($0) } == true
            }
        }
    }
    private static func pendingTitle(_ pending: SelectionGroupPendingObservation) -> String {
        switch pending.kind {
        case .publication: "Creating the new folder"
        case .folderRetirement: "Putting the empty new folder aside"
        case .memberMove: pending.memberIndex.map { "Moving item \($0 + 1) into the new folder" } ?? "Moving a selected item into the new folder"
        case .memberReturn: pending.memberIndex.map { "Returning item \($0 + 1) to its original folder" } ?? "Returning a selected item to its original folder"
        }
    }
    private static func pendingDetail(_ pending: SelectionGroupPendingObservation) -> String {
        var text = "Awaiting confirmation: " + pendingTitle(pending)
            + "\nFrom: " + pending.from.path + "\nTo: " + pending.to.path
        if let location = pending.observedURL {
            text += "\nCurrent location: " + location.path
                + "\nConfirmation records this location. It does not move the item or folder again."
        } else {
            text += "\nCurrent location could not be confirmed."
            if let problem = pending.problem { text += " " + SelectionGroupResultDescription.problem(problem) }
        }
        return text
    }
    private static func rowStatus(_ review: SelectionGroupReview, row: Int) -> String {
        guard let pending = review.pending, pending.memberIndex == row else {
            return SelectionGroupResultDescription.itemState(review.items[row].state)
        }
        guard let side = pending.side else { return "Location not confirmed" }
        switch (pending.kind, side) {
        case (.memberMove, .source): return "At original location; confirmation needed"
        case (.memberMove, .destination): return "In new folder; confirmation needed"
        case (.memberReturn, .source): return "In new folder; return not confirmed"
        case (.memberReturn, .destination): return "Returned; confirmation needed"
        default: return "Location needs confirmation"
        }
    }
    private var reportedRows: [DisplayRow] {
        (presentation?.knownLocations ?? []).map { DisplayRow(source: $0.path, destination: "", status: "Reported location") }
    }
    private func display(_ rows: [DisplayRow]) {
        guard rows != displayedRows else { return }
        let selectedSource = displayedRows.indices.contains(table.selectedRow) ? displayedRows[table.selectedRow].source : nil
        displayedRows = rows; table.reloadData()
        if let selected = rows.firstIndex(where: { $0.source == selectedSource }) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let text: String
        guard displayedRows.indices.contains(row) else { return nil }
        let item = displayedRows[row]
        switch identifier.rawValue { case "source": text = item.source; case "destination": text = item.destination; default: text = item.status }
        let cell: NSTableCellView
        if let reused = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = identifier
            let field = label(""); field.cell?.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(field); cell.textField = field; pin(field, inside: cell, inset: 4)
        }
        cell.textField?.stringValue = text; cell.textField?.setAccessibilityLabel(text); cell.toolTip = text
        InterfacePresentation.shared.apply(in: cell)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail(); ToolContentMotion.reveal(detail)
    }
    private func updateDetail() {
        if isBusy, review == nil {
            // Keep its layout slot stable without showing or announcing an
            // earlier confirmation/cleanup location as current evidence.
            disposition.alphaValue = 0; disposition.toolTip = nil; disposition.setAccessibilityHidden(true)
            var text = "Previous observation. Checking current item locations."
            if displayedRows.indices.contains(table.selectedRow) {
                let row = displayedRows[table.selectedRow]
                text += "\n\nOriginal: " + row.source + "\nGrouped: " + row.destination + "\nRecorded status: " + row.status
            }
            detail.string = text
            return
        }
        disposition.alphaValue = 1; disposition.setAccessibilityHidden(false)
        var text = presentation.map(\.detail) ?? "Earlier grouping operation."
        var actionDetails: [String] = [], actionSummaries: [String] = []
        if let review {
            if let pending = review.pending {
                actionDetails.append(Self.pendingDetail(pending))
                actionSummaries.append(Self.pendingTitle(pending) + (pending.observedURL.map { "\nCurrent location: " + $0.path }
                    ?? "\nCurrent location could not be confirmed."))
            }
            if let target = review.verifiedCleanupTarget {
                actionDetails.append("Recovery folder now at: " + target.path + "\nConfirm Folder Cleanup records this completed cleanup.")
                actionSummaries.append("Recovery folder now at: " + target.path)
            } else if review.actions.contains(.confirmCleanup) {
                let missing = "The recovery folder’s current location could not be confirmed. Refresh before confirming cleanup."
                actionDetails.append(missing); actionSummaries.append(missing)
            }
        }
        let actionText = actionDetails.joined(separator: "\n\n")
        disposition.stringValue = actionSummaries.joined(separator: "\n")
        disposition.toolTip = actionText; disposition.isHidden = actionText.isEmpty
        if !actionText.isEmpty { text = actionText + "\n\n" + text }
        if let review, review.items.indices.contains(table.selectedRow) {
            let item = review.items[table.selectedRow]
            text += "\n\nOriginal: \(item.source.path)\nGrouped: \(item.destination.path)\nRecorded status: \(Self.rowStatus(review, row: table.selectedRow))"
        } else if let locations = presentation?.knownLocations, locations.indices.contains(table.selectedRow) {
            text += "\n\nReported location: " + locations[table.selectedRow].path
        }
        detail.string = text
    }
    @objc private func confirm(_ sender: NSButton) {
        guard !isBusy, !isClosed, let review, let raw = sender.identifier?.rawValue,
              let action = SelectionGroupDisposition(rawValue: raw), Self.canOffer(action, from: review) else { return }
        onAction(action, review, presentationID)
    }
    @objc private func undo(_ sender: Any?) {
        guard !isBusy, !isClosed, let review, review.canUndo else { return }
        onAction(nil, review, presentationID)
    }
    @objc private func refresh(_ sender: Any?) { guard !isBusy, inspectionTask == nil else { return }; onRefresh() }
    @objc private func closeResults(_ sender: Any?) { window?.performClose(sender) }
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }
}
