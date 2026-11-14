import AppKit
import FileOperations

/// Native, virtualized review of one captured job. This controller has no
/// filesystem authority; only explicit callbacks can request an engine action.
@MainActor
final class GroupedCopyRecoveryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let recordID: UUID
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = label("Reading copied-file evidence…")
    private let message = label("Opening this review does not change files.", size: 12, color: .secondaryLabelColor)
    private var actionButtons: [CopyRecoveryAction: NSButton] = [:]
    private let undoButton = NSButton()
    private let refreshButton = NSButton()
    private let onAction: (CopyRecoveryAction, GroupedCopyRecoveryReview, UUID) -> Void
    private let onUndo: (GroupedCopyRecoveryReview, UUID) -> Void
    private let onRefresh: () -> Void
    var onClose: (() -> Void)?
    var hostObservation: BrowserNotificationObservation?
    var inspectionTask: Task<Void, Never>?
    private(set) var inspectionID = UUID()
    private(set) var presentationID = UUID()
    private(set) var review: GroupedCopyRecoveryReview?
    private(set) var retainedAccess: FileAccessLifetimes?
    private(set) var isClosed = false
    private(set) var isBusy = false

    init(recordID: UUID,
         onAction: @escaping (CopyRecoveryAction, GroupedCopyRecoveryReview, UUID) -> Void,
         onUndo: @escaping (GroupedCopyRecoveryReview, UUID) -> Void,
         onRefresh: @escaping () -> Void) {
        self.recordID = recordID; self.onAction = onAction; self.onUndo = onUndo; self.onRefresh = onRefresh
        let window = ToolWindowChrome.makeWindow(title: "Review Copied Files",
            size: .init(width: 1120, height: 680), minimumSize: .init(width: 960, height: 560),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window)
        window.delegate = self
        for (id, title, width) in [("source", "Source", 280.0), ("destination", "Destination", 280.0),
                                    ("state", "Status", 220.0), ("protection", "Why it is preserved", 280.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = 120; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        InterfaceMetrics.setRowHeight(table, base: 28); table.allowsMultipleSelection = false
        table.style = .plain; table.backgroundColor = .controlBackgroundColor
        table.headerView = GroupedCopyRecoveryHeaderView(frame: table.headerView?.frame
            ?? NSRect(x: 0, y: 0, width: 0, height: 28))
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Copied files and recovery evidence")
        let listing = NSScrollView()
        listing.documentView = table
        listing.hasVerticalScroller = true; listing.hasHorizontalScroller = true
        listing.drawsBackground = true; listing.backgroundColor = .controlBackgroundColor
        listing.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        detail.isEditable = false; detail.isSelectable = true; detail.isRichText = false
        detail.font = .systemFont(ofSize: 12); detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detail.setAccessibilityLabel("Selected copied-file paths and protection details")
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true
        details.heightAnchor.constraint(equalToConstant: 120).isActive = true
        var actions: [NSView] = []
        for action in CopyRecoveryAction.allCases {
            let button = NSButton(title: action.title, target: self, action: #selector(confirmSelected(_:)))
            button.identifier = .init(action.rawValue); button.bezelStyle = .rounded
            button.setAccessibilityLabel(action.title)
            button.isEnabled = false; actionButtons[action] = button; actions.append(button)
        }
        undoButton.title = "Undo Verified Copies"; undoButton.bezelStyle = .rounded
        undoButton.target = self; undoButton.action = #selector(undoSelected(_:)); undoButton.isEnabled = false
        undoButton.toolTip = "Recheck unchanged copied files and return them to this job’s recovery folders."
        actions.append(undoButton)
        refreshButton.title = "Refresh Review"; refreshButton.bezelStyle = .rounded
        refreshButton.target = self; refreshButton.action = #selector(refresh(_:))
        refreshButton.keyEquivalent = "r"; refreshButton.keyEquivalentModifierMask = .command
        let close = NSButton(title: "Close", target: self, action: #selector(closeReview(_:)))
        close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let explanation = label("Confirmation records what has already completed. It does not copy, move or delete files. Undo checks each copied file before returning it to recovery. Uncertain files stay preserved.", size: 12, color: .secondaryLabelColor)
        explanation.maximumNumberOfLines = 3; explanation.cell?.wraps = true
        message.maximumNumberOfLines = 3; message.cell?.wraps = true
        for button in actions + [refreshButton, close] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        func flexibleSpace() -> NSView {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return spacer
        }
        let actionRow = stack(actions + [flexibleSpace()], orientation: .horizontal, spacing: 8)
        let navigation = stack([refreshButton, flexibleSpace(), close], orientation: .horizontal, spacing: 8)
        let layout = stack([summary, message, listing, details, explanation, actionRow, navigation],
            orientation: .vertical, spacing: 10)
        layout.alignment = .leading
        guard let content = window.contentView else { return }
        pin(layout, inside: content, inset: 16)
        for view in [summary, message, listing, details, explanation, actionRow, navigation] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        window.initialFirstResponder = table
        ToolWindowChrome.install(in: window)
        ToolWindowChrome.position(window, relativeTo: NSApplication.shared.keyWindow)
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func beginLoading() -> UUID {
        inspectionTask?.cancel(); inspectionTask = nil
        inspectionID = UUID(); presentationID = UUID()
        isBusy = true; review = nil; retainedAccess = nil
        summary.stringValue = "Reading copied-file evidence…"
        message.stringValue = "Reading current evidence. No recovery action has started."
        table.reloadData(); detail.string = "Reading current evidence…"
        updateActions(); return inspectionID
    }

    func update(_ review: GroupedCopyRecoveryReview, retaining access: FileAccessLifetimes) {
        guard !isClosed, review.recordID == recordID, review.items.count <= 1024 else {
            showUnavailable("This review could not be displayed safely. Existing files remain preserved."); return
        }
        let selectedID = selectedItem?.id
        self.review = review; retainedAccess = access; presentationID = UUID(); isBusy = false
        summary.stringValue = "\(review.items.count) copied-file item\(review.items.count == 1 ? "" : "s") · \(Self.jobStatus(review.state))"
        message.stringValue = review.availableActions.isEmpty && !review.canUndo
            ? "No recovery action is currently safe. Read the item details; changed or uncertain data remains preserved."
            : "Choose an available action explicitly. Every action rechecks current evidence before it can proceed."
        table.reloadData()
        if let selectedID, let row = review.items.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !review.items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateDetail(); updateActions()
    }

    func showUnavailable(_ text: String) {
        inspectionTask?.cancel(); inspectionTask = nil; inspectionID = UUID()
        review = nil; retainedAccess = nil; presentationID = UUID(); isBusy = false
        summary.stringValue = "Copied-file review unavailable"; message.stringValue = text
        table.reloadData(); detail.string = text; updateActions()
    }

    func setWorking(_ text: String) {
        isBusy = true; message.stringValue = text; updateActions()
    }
    func showNotice(_ text: String) { message.stringValue = text }

    func windowWillClose(_ notification: Notification) {
        isClosed = true; inspectionID = UUID(); presentationID = UUID()
        inspectionTask?.cancel(); inspectionTask = nil
        hostObservation = nil
        review = nil; retainedAccess = nil; onClose?()
    }

    private var selectedItem: CopyRecoveryItem? {
        guard let review, review.items.indices.contains(table.selectedRow) else { return nil }
        return review.items[table.selectedRow]
    }
    func numberOfRows(in tableView: NSTableView) -> Int { review?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let review, review.items.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let item = review.items[row]
        let text: String
        switch identifier.rawValue {
        case "source": text = item.source.path
        case "destination": text = item.destination.path
        case "state": text = item.state.description
        default: text = Self.protectionText(item)
        }
        let cell: NSTableCellView
        if let reused = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = text; cell.toolTip = text
        cell.textField?.setAccessibilityLabel(text)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail(); ToolContentMotion.reveal(detail)
    }
    private func updateDetail() {
        guard let item = selectedItem else { detail.string = "Select an item to read its full paths and current evidence."; return }
        detail.string = "Source: \(item.source.path)\nDestination: \(item.destination.path)\n\n\(item.state.description)\n\(Self.protectionText(item))"
    }
    private func updateActions() {
        for (action, button) in actionButtons { button.isEnabled = !isClosed && !isBusy && review?.availableActions.contains(action) == true }
        undoButton.isEnabled = !isClosed && !isBusy && review?.canUndo == true
        refreshButton.isEnabled = !isClosed && !isBusy
    }
    @objc private func confirmSelected(_ sender: NSButton) {
        guard !isBusy, !isClosed, let action = sender.identifier.flatMap({ CopyRecoveryAction(rawValue: $0.rawValue) }),
              let review, review.availableActions.contains(action) else { return }
        onAction(action, review, presentationID)
    }
    @objc private func undoSelected(_ sender: Any?) {
        guard !isBusy, !isClosed, let review, review.canUndo else { return }
        onUndo(review, presentationID)
    }
    @objc private func refresh(_ sender: Any?) { guard !isBusy, !isClosed else { return }; onRefresh() }
    @objc private func closeReview(_ sender: Any?) { window?.performClose(sender) }
    override func cancelOperation(_ sender: Any?) { close() }

    static func protectionText(_ item: CopyRecoveryItem) -> String {
        guard let reason = item.protectionReason else {
            switch item.state {
            case .notStarted: return "This item was never started. This review will not copy it."
            case .neverStaged: return "No copy was created for this item."
            case .retainedCopy: return "A verified copy is kept in this job’s recovery folder."
            case .copyNeedsConfirmation: return "The copied file matches this job, but completion still needs confirmation."
            case .undoPending: return "The copied file is still at its destination. Undo can recheck it and try again."
            case .undoNeedsConfirmation: return "The file is back in this job’s recovery folder. Undo still needs confirmation."
            case .copied: return "The copied file still matches the completed copy."
            case .undone: return "The file remains in this job’s recovery folder after Undo."
            case .protected: return "Current evidence is incomplete or uncertain. The data remains preserved."
            }
        }
        switch reason {
        case "unsealed": return "The copy was interrupted before it could be verified. It stays preserved and cannot be used or removed by this review."
        case "parent": return "The destination folder changed or cannot be checked."
        case "group": return "A recorded recovery folder is missing, changed or unavailable."
        case "marker": return "This recovery folder can no longer be verified as belonging to this job."
        case "inventory": return "The recovery folder contains missing, changed or unexpected entries."
        case "memberArea": return "This file’s recovery folder changed or cannot be checked."
        case "slots": return "The file’s destination and recovery location do not show one verified outcome."
        case "cleanup": return "Cleanup ended Undo or its Trash result still needs review. Use Operation Recovery to inspect retained locations."
        default: return "Current evidence cannot safely establish this item’s outcome. The data remains preserved."
        }
    }
    private static func jobStatus(_ state: String) -> String {
        switch state {
        case "completed": "Copy complete"
        case "stoppedSettled": "Stopped and accounted for"
        case "undone": "Undo complete"
        case "cleaned": "Recovery copies moved to Trash"
        case "cleanupReview": "Cleanup needs review"
        default: "Recovery evidence needs review"
        }
    }

    #if DEBUG
    var verificationRows: Int { table.numberOfRows }
    var verificationEnabledActions: [CopyRecoveryAction] { actionButtons.filter { $0.value.isEnabled }.map(\.key) }
    var verificationCanUndo: Bool { undoButton.isEnabled }
    var verificationDetail: String { detail.string }
    var verificationVisibleRowRange: NSRange { table.rows(in: table.visibleRect) }
    var verificationHasCompactButtons: Bool {
        (Array(actionButtons.values) + [undoButton, refreshButton]).allSatisfy {
            abs($0.frame.width - $0.intrinsicContentSize.width) <= 2
        }
    }
    var verificationHeaderHidesScrolledRows: Bool {
        guard let scroll = table.enclosingScrollView, let header = table.headerView else { return false }
        let headerFrame = header.convert(header.bounds, to: scroll)
        let visibleHeader = header.convert(header.visibleRect, to: scroll)
        let rowsFrame = scroll.contentView.convert(scroll.contentView.bounds, to: scroll)
        // Current AppKit floats the header above the rows even with zero insets.
        // Require an opaque native header to cover the entire overlap instead
        // of requiring a frame separation the runtime does not provide.
        let overlap = NSIntersectionRect(headerFrame, rowsFrame)
        let covered = NSIntersectionRect(visibleHeader, overlap)
        return table.style == .plain && header is GroupedCopyRecoveryHeaderView && header.isOpaque
            && headerFrame.height > 0 && rowsFrame.height >= table.rowHeight
            && (overlap.isEmpty || (covered.width >= overlap.width - 1 && covered.height >= overlap.height - 1))
    }
    var verificationGeometryDescription: String {
        let widths = (Array(actionButtons.values) + [undoButton, refreshButton]).map {
            "\($0.title): frame=\($0.frame.width), intrinsic=\($0.intrinsicContentSize.width)"
        }.sorted().joined(separator: "; ")
        guard let scroll = table.enclosingScrollView, let header = table.headerView else { return widths + "; no header" }
        return widths + "; header=" + NSStringFromRect(header.convert(header.bounds, to: scroll))
            + "; visibleHeader=" + NSStringFromRect(header.convert(header.visibleRect, to: scroll))
            + "; rows=" + NSStringFromRect(scroll.contentView.convert(scroll.contentView.bounds, to: scroll))
            + "; scrollInsets=\(scroll.contentInsets), scrollAutoInsets=\(scroll.automaticallyAdjustsContentInsets)"
            + "; clipInsets=\(scroll.contentView.contentInsets), clipAutoInsets=\(scroll.contentView.automaticallyAdjustsContentInsets)"
    }
    func verificationSelect(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    func verificationActivate(_ action: CopyRecoveryAction) { actionButtons[action]?.performClick(nil) }
    func verificationUndo() { undoButton.performClick(nil) }
    #endif
}

/// Keep AppKit's header sizing, column interaction and horizontal scrolling.
/// Its floating material must not reveal a scrolled file row behind the labels.
@MainActor
private final class GroupedCopyRecoveryHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath.fill(dirtyRect)
        super.draw(dirtyRect)
    }
}
