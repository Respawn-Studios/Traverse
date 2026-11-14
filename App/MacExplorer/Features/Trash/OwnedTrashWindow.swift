import AppKit

@MainActor
private final class OwnedTrashItemsTable: NSTableView, FileColumnSizingTable {
    let columnSizing = FileColumnSizing()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerView = ColumnSizingHeaderView(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); columnSizing.fit(self) }
}

/// The list reads recorded metadata only. All Restore/Delete authority belongs
/// to the existing browser operation owner and the FileOperations engine.
@MainActor
final class OwnedTrashWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let groupsTable = NSTableView()
    private let itemsTable = OwnedTrashItemsTable()
    private let split = NSSplitViewController()
    private let detailHost = NSView()
    private let selectedHeading = label("Select a group", size: 19, weight: .semibold)
    private let date = label("", size: 12, color: .secondaryLabelColor)
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footer = label("", size: 12, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let restore = NSButton(title: "Restore Items", target: nil, action: nil)
    private let remove = NSButton(title: "Permanently Delete…", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let loadMore = NSButton(title: "Load Earlier Items", target: nil, action: nil)
    private let review = NSButton(title: "Review Operation…", target: nil, action: nil)
    private var groups: [OwnedTrashGroupPresentation] = []
    private var emptyTitle = "No recorded Trash items"
    private var offersHistoryReview = false
    private var wasPresented = false
    private var wasSizedSidebar = false
    private var selectionLocked = false
    private var isUpdating = false
    private(set) var isBusy = false
    private(set) var isOpen = false
    var onRefresh: (() -> Void)?
    var onLoadMore: (() -> Void)?
    var onRestore: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onReview: ((UUID?) -> Void)?
    var onClose: (() -> Void)?

    var selectedGroupID: UUID? { selectedGroup?.id }
    private var selectedGroup: OwnedTrashGroupPresentation? {
        groups.indices.contains(groupsTable.selectedRow) ? groups[groupsTable.selectedRow] : nil
    }

    init(settings: BrowserSettings) {
        let native = ToolWindowChrome.makeWindow(title: "Traverse Trash", size: .init(width: 1020, height: 720),
            minimumSize: .init(width: 880, height: 580), styleMask: [.titled, .closable, .resizable])
        super.init(window: native)
        native.delegate = self
        buildContent(in: native)
        ToolWindowChrome.install(in: native, settings: settings, initialContentSize: .init(width: 1020, height: 720))
        ToolWindowChrome.position(native, relativeTo: NSApp.mainWindow)
        updateSelection()
    }
    required init?(coder: NSCoder) { nil }

    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if !wasPresented { ToolWindowChrome.position(window, relativeTo: parent); wasPresented = true }
        isOpen = true
        ToolWindowCloseMotion.cancel(window)
        showWindow(nil); window.makeKeyAndOrderFront(nil)
        if !wasSizedSidebar {
            window.contentView?.layoutSubtreeIfNeeded()
            split.splitView.setPosition(240, ofDividerAt: 0)
            wasSizedSidebar = true
        }
    }
    func update(_ next: [OwnedTrashGroupPresentation], message text: String, hasMore: Bool, busy: Bool,
                emptyTitle: String = "No recorded Trash items", offersHistoryReview: Bool = false) {
        let selected = selectedGroupID
        isUpdating = true
        groups = next; self.emptyTitle = emptyTitle; self.offersHistoryReview = offersHistoryReview; groupsTable.reloadData()
        if let selected, let index = groups.firstIndex(where: { $0.id == selected }) {
            groupsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !groups.isEmpty {
            groupsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else { groupsTable.deselectAll(nil) }
        isUpdating = false
        loadMore.isHidden = !hasMore
        message.stringValue = text
        setBusy(busy)
        updateSelection()
    }
    func setBusy(_ busy: Bool, message text: String? = nil, locksSelection: Bool = false) {
        isBusy = busy
        selectionLocked = busy && locksSelection
        groupsTable.isEnabled = !selectionLocked
        if let text { message.stringValue = text }
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refresh.isEnabled = !busy; loadMore.isEnabled = !busy
        updateButtons()
    }
    private func updateButtons() {
        restore.isEnabled = !isBusy && selectedGroup?.canRestore == true
        remove.isEnabled = !isBusy && selectedGroup?.canDelete == true
        review.isHidden = selectedGroup?.needsReview != true && !offersHistoryReview
        review.isEnabled = !isBusy && (selectedGroup != nil || offersHistoryReview)
        review.title = selectedGroup == nil ? "Review History…" : "Review Operation…"
    }
    private func buildContent(in native: NSWindow) {
        let heading = label("Traverse Trash", size: 23, weight: .semibold)
        let scope = NSTextField(wrappingLabelWithString:
            "Items moved to Trash using Traverse. Files removed by other apps are managed in the Mac’s Trash.")
        scope.textColor = .secondaryLabelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = stack([heading, spacer, refresh], orientation: .horizontal)
        titleRow.alignment = .centerY
        titleRow.heightAnchor.constraint(equalTo: heading.heightAnchor).isActive = true
        refresh.target = self; refresh.action = #selector(refreshPressed(_:))
        refresh.setAccessibilityLabel("Refresh recorded Traverse Trash items")
        loadMore.target = self; loadMore.action = #selector(loadMorePressed(_:))
        restore.target = self; restore.action = #selector(restorePressed(_:))
        remove.target = self; remove.action = #selector(deletePressed(_:))
        review.target = self; review.action = #selector(reviewPressed(_:))
        remove.contentTintColor = .systemRed
        for button in [refresh, loadMore, restore, remove, review] { button.bezelStyle = .rounded }

        groupsTable.style = .sourceList; groupsTable.headerView = nil
        groupsTable.addTableColumn(NSTableColumn(identifier: .init("group")))
        groupsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        groupsTable.setAccessibilityLabel("Groups moved to Trash using Traverse")
        InterfaceMetrics.setRowHeight(groupsTable, base: 60)
        for table in [groupsTable, itemsTable] {
            table.dataSource = self; table.delegate = self
            table.backgroundColor = .clear; table.allowsMultipleSelection = false
            table.allowsColumnReordering = false
        }
        for (id, title, width) in [("name", "Name", 220.0), ("status", "Status", 170.0),
                                  ("size", "Recorded Size", 110.0), ("folder", "Original Folder", 210.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "status" ? 140 : id == "name" ? 140 : 80
            itemsTable.addTableColumn(column)
        }
        itemsTable.columnAutoresizingStyle = .noColumnAutoresizing
        itemsTable.setAccessibilityLabel("Items in the selected Trash group")
        itemsTable.selectionHighlightStyle = .none
        InterfaceMetrics.setRowHeight(itemsTable, base: 31)
        let groupsScroll = scroll(groupsTable), itemsScroll = scroll(itemsTable)
        for view in [groupsScroll, itemsScroll] {
            view.setContentHuggingPriority(.init(1), for: .vertical)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        itemsScroll.hasHorizontalScroller = true
        let groupHeading = label("Moved with Traverse", size: 12, color: .secondaryLabelColor, weight: .semibold)
        let left = stack([groupHeading, groupsScroll, loadMore], orientation: .vertical, spacing: 12)
        groupsScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        let leftHost = NSView(); pin(left, inside: leftHost, inset: 14)
        let preferredSidebar = leftHost.widthAnchor.constraint(equalToConstant: 240)
        preferredSidebar.priority = .defaultLow; preferredSidebar.isActive = true
        let leftController = NSViewController(); leftController.view = leftHost
        let leftItem = NSSplitViewItem(sidebarWithViewController: leftController)
        leftItem.minimumThickness = 180; leftItem.maximumThickness = 380; leftItem.canCollapse = false
        split.addSplitViewItem(leftItem)

        explanation.textColor = .secondaryLabelColor; explanation.maximumNumberOfLines = 0
        selectedHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let right = stack([selectedHeading, date, itemsScroll, explanation, review], orientation: .vertical, spacing: 14)
        itemsScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        itemsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        explanation.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        pin(right, inside: detailHost, inset: 20)
        let detailController = NSViewController(); detailController.view = detailHost
        let rightItem = NSSplitViewItem(viewController: detailController); rightItem.minimumThickness = 430
        split.addSplitViewItem(rightItem); split.splitView.dividerStyle = .thin
        split.view.translatesAutoresizingMaskIntoConstraints = false
        split.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 2
        let status = stack([spinner, message], orientation: .horizontal)
        status.heightAnchor.constraint(equalTo: message.heightAnchor).isActive = true
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttonSpacer = NSView(); buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = stack([footer, buttonSpacer, remove, restore], orientation: .horizontal, spacing: 10)
        actions.heightAnchor.constraint(equalTo: restore.heightAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        // Extra height belongs to the lists. Unconstrained horizontal spacers
        // otherwise let AppKit stretch the title/actions into empty rows.
        for view in [heading, titleRow, scope, groupHeading, loadMore, selectedHeading, date,
                     explanation, review, status, message, actions] {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        split.view.setContentHuggingPriority(.init(1), for: .vertical)
        let root = stack([titleRow, scope, split.view, status, divider, actions], orientation: .vertical, spacing: 14)
        let host = NSView(); pin(root, inside: host, inset: 20)
        let controller = NSViewController(); controller.view = host; controller.addChild(split)
        native.contentViewController = controller
        for view in [titleRow, scope, split.view, status, divider, actions] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        message.setAccessibilityIdentifier("owned-trash-status")
        restore.setAccessibilityIdentifier("owned-trash-restore-group")
        remove.setAccessibilityIdentifier("owned-trash-delete-group")
    }
    private func scroll(_ table: NSTableView) -> NSScrollView {
        let result = NSScrollView(); result.documentView = table
        result.hasVerticalScroller = true; result.autohidesScrollers = true
        result.drawsBackground = false; result.borderType = .noBorder
        return result
    }
    private func updateSelection() {
        selectedHeading.stringValue = selectedGroup?.title ?? (groups.isEmpty ? emptyTitle : "Select a group")
        selectedHeading.toolTip = selectedGroup?.title
        date.stringValue = selectedGroup.map { "Moved together · " + $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? ""
        explanation.stringValue = selectedGroup?.explanation
            ?? "Only successful moves recorded by Traverse appear here. Opening this window does not scan the Mac’s Trash."
        itemsTable.reloadData()
        if let selectedGroup {
            footer.stringValue = "\(selectedGroup.entries.count.formatted()) \(selectedGroup.entries.count == 1 ? "item" : "items")"
                + (selectedGroup.recordedBytes.map { " · " + FileSizeText.unsigned($0) + " recorded" } ?? "")
            restore.title = selectedGroup.entries.count == 1 ? "Restore Item" : "Restore \(selectedGroup.entries.count.formatted()) Items"
        } else { footer.stringValue = ""; restore.title = "Restore Items" }
        updateButtons()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === groupsTable ? groups.count : selectedGroup?.entries.count ?? 0
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === groupsTable && !selectionLocked }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, let changed = notification.object as? NSTableView, changed === groupsTable else { return }
        ToolContentMotion.crossfade(detailHost); updateSelection()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupsTable {
            guard groups.indices.contains(row) else { return nil }
            let value = groups[row]
            let primary = label(value.title, weight: .medium)
            let secondary = label(value.createdAt.formatted(date: .abbreviated, time: .shortened)
                + (value.needsReview ? " · Needs review" : ""), size: 11, color: .secondaryLabelColor)
            let content = stack([primary, secondary], orientation: .vertical, spacing: 4)
            let cell = NSTableCellView(); cell.textField = primary; cell.toolTip = value.title
            cell.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        guard let group = selectedGroup, group.entries.indices.contains(row) else { return nil }
        let entry = group.entries[row], id = tableColumn?.identifier.rawValue ?? "name"
        let text: String
        switch id {
        case "folder": text = entry.originalURL.deletingLastPathComponent().path
        case "size": text = entry.recordedByteCount.map(FileSizeText.unsigned) ?? "—"
        case "status": text = entry.stateTitle
        default: text = entry.originalURL.lastPathComponent
        }
        let field = label(text); field.toolTip = text
        let cell = NSTableCellView(); cell.textField = field
        if id == "name" {
            let icon = NSImageView(image: BrowserCellSymbols.image(.classify(name: text, kind: entry.isDirectory ? "directory" : "file")) ?? NSImage())
            icon.contentTintColor = entry.isDirectory ? .systemYellow : .secondaryLabelColor
            let content = stack([icon, field], orientation: .horizontal, spacing: 8)
            cell.addSubview(content)
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 18).interfaceScaled,
                icon.heightAnchor.constraint(equalToConstant: 18).interfaceScaled,
                content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        } else {
            field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        return cell
    }
    @objc private func refreshPressed(_ sender: Any?) { if !isBusy { onRefresh?() } }
    @objc private func loadMorePressed(_ sender: Any?) { if !isBusy { onLoadMore?() } }
    @objc private func restorePressed(_ sender: Any?) {
        if !isBusy, let group = selectedGroup, group.canRestore { onRestore?(group.id) }
    }
    @objc private func deletePressed(_ sender: Any?) {
        if !isBusy, let group = selectedGroup, group.canDelete { onDelete?(group.id) }
    }
    @objc private func reviewPressed(_ sender: Any?) { if !isBusy { onReview?(selectedGroupID) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { ToolWindowCloseMotion.shouldClose(sender) }
    func windowWillClose(_ notification: Notification) {
        isOpen = false; onClose?()
        groups = []; groupsTable.reloadData(); updateSelection()
    }
}
