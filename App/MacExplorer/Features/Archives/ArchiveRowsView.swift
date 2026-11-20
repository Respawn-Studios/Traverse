import AppKit
import ExplorerCore
import LocalStorage
import SwiftUI

/// A bounded page of virtual members. It deliberately has no local URL or
/// file-operation adapter: every action goes back through the archive owner.
@MainActor struct ArchiveRowsView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    @ObservedObject var settings: BrowserSettings
    var clipboard: ArchiveWindowClipboard? = nil

    func makeNSView(context: Context) -> ArchiveMetadataRows {
        let rows = ArchiveMetadataRows()
        rows.bindActions(to: model)
        clipboard?.bind(rows)
        rows.memberDragSource = ArchiveMemberDragSource(model: model,table: rows.table)
        rows.table.memberDragSource = rows.memberDragSource
        #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
            model.rowsForVerification = rows
        #endif
        return rows
    }

    func updateNSView(_ rows: ArchiveMetadataRows, context: Context) {
        rows.table.behavior = settings.behavior
        rows.configure(glass: settings.navigationStyle == .glass, motion: settings.motion,
            order:ArchiveOrderingActivation.available ? model.ordering : nil)
        rows.setExternalExportsReady(model.externalExportReady)
        rows.observe(model.visibleItems, selection: model.selection, showsLocation: model.isSearchResults)
    }

    static func dismantleNSView(_ rows: ArchiveMetadataRows, coordinator: ()) {
        rows.onSelection = nil
        rows.onOpen = nil
        rows.onPreview = nil
        rows.onEditText = nil; rows.canEditText = nil
        rows.onPreviewBytes = nil
        rows.onProperties = nil; rows.canShowProperties = nil
        rows.onExtract = nil
        rows.onRenameCopy = nil
        rows.onRemoveCopy = nil
        rows.onDuplicate = nil
        rows.onAddCopy = nil; rows.canAddCopy = nil
        rows.onRenameOriginal = nil; rows.onRemoveOriginal = nil; rows.onAddOriginal = nil
        rows.onNewFolder = nil; rows.canNewFolder = nil
        rows.onGroup = nil; rows.canGroup = nil
        rows.onNewFile = nil
        rows.onCut = nil; rows.onCopyMembers = nil; rows.canCaptureClipboard = nil; rows.isCut = nil
        rows.onPaste = nil; rows.canPaste = nil
        rows.table.onCut = nil; rows.table.onCopy = nil; rows.table.onPaste = nil; rows.table.commandValidation = nil
        rows.table.memberCommandTarget = nil; rows.table.memberCommands = [:]
        rows.table.onRename = nil; rows.table.nameClickRenameEnabled = nil
        rows.table.retireNameSelection()
        rows.table.keyboardContextSettings = nil
        rows.table.onForward = nil; rows.table.onRefresh = nil
        rows.embeddedShortcut = nil
        rows.onAddFiles = nil; rows.canAddFiles = nil
        rows.canPreview = nil
        rows.canExtract = nil
        rows.canRenameCopy = nil
        rows.canRemoveCopy = nil
        rows.canDuplicate = nil
        rows.onShowInArchive = nil; rows.canShowInArchive = nil
        rows.onOrder = nil; rows.canOrder = nil
        rows.onBack = nil
        rows.onUp = nil
        rows.memberDragSource?.retire(); rows.memberDragSource = nil; rows.table.memberDragSource = nil
        rows.table.marquee?.cancel(restore:false);rows.table.marquee=nil
    }
}

@MainActor final class ArchiveMetadataRows: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let table = ArchiveMetadataTable()
    private let scroll = NSScrollView()
    var fileScrollView: NSScrollView { scroll }
    /// Embedded navigation uses its browser's single tab/folder transition.
    var animatesNewRows = true
    private var items: [ZIPArchiveItem] = []
    private var updating = false
    private var revealGeneration = UUID()
    private var showsLocation = false
    private var ordering: ZIPArchiveOrder?
    #if DEBUG
    var rowIDsForVerification: [ZIPItemID] { items.map(\.id) }
    #endif
    var onSelection: ((Set<ZIPItemID>) -> Void)?
    var onOpen: ((Set<ZIPItemID>) -> Void)?
    var onPreview: ((Set<ZIPItemID>) -> Void)?
    var onEditText: ((Set<ZIPItemID>) -> Void)?
    var canEditText: ((Set<ZIPItemID>) -> Bool)?
    var onPreviewBytes: ((Set<ZIPItemID>) -> Void)?
    var onProperties: ((Set<ZIPItemID>) -> Void)?
    var canShowProperties: ((Set<ZIPItemID>) -> Bool)?
    var onCompareText: (() -> Void)?
    var canCompareText: (() -> Bool)?
    var onExtract: ((Set<ZIPItemID>) -> Void)?
    var onRenameCopy: ((Set<ZIPItemID>) -> Void)?
    var onRemoveCopy: ((Set<ZIPItemID>) -> Void)?
    var onDuplicate: ((Set<ZIPItemID>) -> Void)?
    var onAddCopy: (() -> Void)?
    var onRenameOriginal: ((Set<ZIPItemID>) -> Void)?
    var onRemoveOriginal: ((Set<ZIPItemID>) -> Void)?
    var onAddOriginal: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onGroup: (() -> Void)?
    var canGroup: (() -> Bool)?
    var onNewFile: (() -> Void)?
    var canNewFolder: (() -> Bool)?
    var onCut: (() -> Void)?
    var onCopyMembers: (() -> Void)?
    var canCaptureClipboard: ((TransferClipboardFeedback.Intent) -> Bool)?
    var isCut: ((ZIPItemID) -> Bool)?
    var onPaste: (() -> Void)?
    var canPaste: (() -> Bool)?
    var canAddCopy: (() -> Bool)?
    var onAddFiles: ((LocalFileDropSource, ZIPFolderID?) -> Bool)?
    var canAddFiles: ((ZIPFolderID?) -> Bool)?
    private var acceptedFileDrop: LocalFileDropKey?
    var canPreview: ((Set<ZIPItemID>) -> Bool)?
    var canExtract: ((Set<ZIPItemID>) -> Bool)?
    var canRenameCopy: ((Set<ZIPItemID>) -> Bool)?
    var canRemoveCopy: ((Set<ZIPItemID>) -> Bool)?
    var canDuplicate: ((Set<ZIPItemID>) -> Bool)?
    var onShowInArchive: (() -> Void)?
    var canShowInArchive: (() -> Bool)?
    var onOrder: ((ZIPArchiveOrder) -> Bool)?
    var canOrder: (() -> Bool)?
    var onBack: (() -> Void)?
    var onUp: (() -> Void)?
    var embeddedShortcut: ((NSEvent) -> Bool)? {
        didSet { table.embeddedShortcut = embeddedShortcut }
    }
    var memberDragSource: ArchiveMemberDragSource?

    /// Embedded and standalone archive views share these model callbacks.
    /// Row views do not infer filesystem authority.
    func bindActions(to model: ArchiveBrowserModel) {
        table.keyboardContextSettings = model.settings
        table.allowsNameSelection = { [weak model] in model?.allowsVisibleNameSelection == true }
        table.reportNameSelection = { [weak model] in model?.reportNameSelection($0) }
        table.nameClickRenameEnabled = { [weak model] in
            guard let model else { return false }
            return model.settings.renamesSelectedNameOnClick && model.selection.count == 1
                && model.canRenameMemberInCopy
        }
        table.onRename = { [weak model] in
            guard let model, model.canRenameMemberInCopy else { return }
            model.renameMemberInCopy(model.selection, updateOriginal: ZIPOriginalUpdateFeature.available)
        }
        self.onSelection = { [weak model] ids in
            if let model, model.selection != ids { model.selection = ids }
        }
        self.onOpen = { [weak model] in model?.openSelection($0) }
        self.onPreview = { [weak model] in model?.previewSelection($0) }
        self.onEditText = { [weak model] in model?.editTextSelection($0) }
        self.onCompareText = { [weak model, weak self] in model?.compareSelectedText(relativeTo: self?.window) }
        self.canCompareText = { [weak model] in model?.canCompareSelectedText == true }
        self.onPreviewBytes = { [weak model] in model?.previewSelection($0, mode: .hexadecimal) }
        self.onProperties = { [weak model, weak self] in model?.showMemberProperties($0, relativeTo: self?.window) }
        self.canShowProperties = { [weak model] in model?.observedMember($0) != nil }
        self.onExtract = { [weak model] in model?.reviewExtraction($0) }
        self.onRenameCopy = { [weak model] in model?.renameMemberInCopy($0) }
        self.onRemoveCopy = { [weak model] in model?.removeMembersInCopy($0) }
        self.onDuplicate = { [weak model] in
            model?.duplicateMembers($0, updateOriginal: ZIPOriginalUpdateFeature.available)
        }
        self.onAddCopy = { [weak model] in model?.addMembersInCopy(); return }
        self.onRenameOriginal = { [weak model] in model?.renameMemberInCopy($0, updateOriginal: true) }
        self.onRemoveOriginal = { [weak model] in model?.removeMembersInCopy($0, updateOriginal: true) }
        self.onAddOriginal = { [weak model] in model?.addMembersInCopy(updateOriginal: true); return }
        self.onNewFolder = { [weak model] in _ = model?.createFolderInZIP(updateOriginal: ZIPOriginalUpdateFeature.available) }
        self.onNewFile = { [weak model] in _ = model?.createFileInZIP(updateOriginal: ZIPOriginalUpdateFeature.available) }
        self.canNewFolder = { [weak model] in model?.canCreateFolderInZIP == true }
        self.onGroup = { [weak model] in model?.groupSelection(updateOriginal: ZIPOriginalUpdateFeature.available) }
        self.canGroup = { [weak model] in model?.canGroupSelection == true }
        self.canAddCopy = { [weak model] in model?.canAddMembersInCopy == true }
        self.onAddFiles = { [weak model] in model?.addMembersInCopy($0, to: $1, updateOriginal: ZIPOriginalUpdateFeature.available) == true }
        self.canAddFiles = { [weak model] in model?.canAddLocalFiles(to: $0) == true }
        self.canPreview = { [weak model] in model?.canPreviewSelection($0) == true }
        self.canEditText = { [weak model] in model?.canEditTextSelection($0) == true }
        self.canExtract = { [weak model] in model?.canExtractSelection($0) == true }
        self.canRenameCopy = { [weak model] in model?.canRenameMemberInCopy($0) == true }
        self.canRemoveCopy = { [weak model] in model?.canRemoveMembersInCopy($0) == true }
        self.canDuplicate = { [weak model] in model?.canDuplicateMembers($0) == true }
        self.onShowInArchive = { [weak model] in model?.showInArchive() }
        self.canShowInArchive = { [weak model] in model?.canShowInArchive == true }
        self.onOrder = { [weak model] in model?.order(by:$0) == true }
        self.canOrder = { [weak model] in model?.canOrder == true }
        self.onBack = { [weak model] in model?.back() }
        self.onUp = { [weak model] in model?.up() }
        table.onForward = { [weak model] in model?.forward() }
        table.onRefresh = { [weak model] in model?.refresh() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Set this before installing the delegate. SwiftUI's automatic row-height
        // invalidation reentered AppKit's span cache during preview/page changes.
        table.usesAutomaticRowHeights = false
        InterfaceMetrics.setRowHeight(table, base: 26)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (key, title, width) in [
            ("name", "Name", 300.0), ("size", "Size", 90.0), ("modified", "Date Modified", 172.0),
            ("packed", "Packed", 100.0), ("method", "Method", 100.0), ("location", "Location", 230.0),
        ] {
            let column = NSTableColumn(identifier: .init(key))
            column.title = title
            column.width = width
            column.minWidth = key == "name" ? 200 : key == "location" ? 140 : 70
            column.isHidden = key == "location"
            table.addTableColumn(column)
        }
        table.headerView = FileTableHeaderView(frame: .init(x: 0, y: 0, width: 800, height: 28))
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let move = ZIPOriginalUpdateFeature.available
        var dropTypes: [NSPasteboard.PasteboardType] = ZIPMemberAdditionFeature.available ? [.fileURL] : []
        if move { dropTypes.append(ArchiveMemberDragSource.pasteboardType) }
        if !dropTypes.isEmpty { table.registerForDraggedTypes(dropTypes) }
        table.setDraggingSourceOperationMask(move ? [.copy, .move] : .copy, forLocal: true)
        // Native promises are enabled only after selected metadata/source access
        // are ready; the synchronous writer never waits on an archive actor.
        table.setDraggingSourceOperationMask([],forLocal: false)
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onOpen = { [weak self] in self?.openSelected(nil) }
        table.onPreview = { [weak self] in self?.previewSelected(nil) }
        table.onBack = { [weak self] in self?.onBack?() }
        table.onUp = { [weak self] in self?.onUp?() }
        table.setAccessibilityLabel(
            "Archive members. Names and recorded sizes only. Open folders or explicitly preview a selected member.")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Folder", action: #selector(openFolder(_:)), keyEquivalent: "").target = self
        if ZIPTextEditorFeature.available {
            menu.addItem(withTitle: "Edit in Traverse", action: #selector(editTextSelected(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Compare Text Files…", action: #selector(compareTextSelected(_:)), keyEquivalent: "").target = self
        if ZIPTextPreviewFeature.available {
            menu.addItem(withTitle: "Preview Text", action: #selector(previewSelected(_:)), keyEquivalent: "").target =
                self
        }
        if ZIPBytePreviewFeature.available {
            menu.addItem(withTitle: "Preview as Hex", action: #selector(previewBytesSelected(_:)), keyEquivalent: "").target = self
        }
        if SelectedArchiveExtractionActivation.available {
            menu.addItem(withTitle: "Extract Selected…", action: #selector(extractSelected(_:)), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "Show in Archive", action: #selector(showInArchive(_:)), keyEquivalent: "").target = self
        if ZIPMemberCreationFeature.available {
            menu.addItem(withTitle: "Create File in ZIP…", action: #selector(createZIPFile(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New Folder in ZIP…", action: #selector(createZIPFolder(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New Folder with Selection…", action: #selector(groupZIPSelection(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Properties…", action: #selector(showMemberProperties(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cut", action: #selector(cutMembers(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyMembers(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste", action: #selector(pasteItems(_:)), keyEquivalent: "").target = self
        if ZIPOriginalUpdateFeature.available {
            menu.addItem(withTitle: "Rename in ZIP…", action: #selector(renameOriginal(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Remove from ZIP…", action: #selector(removeOriginal(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Add to ZIP…", action: #selector(addOriginal(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        if ZIPMemberRenameFeature.available {
            menu.addItem(withTitle: "Duplicate…", action: #selector(duplicateMembers(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Rename in ZIP Copy…", action: #selector(renameCopy(_:)), keyEquivalent: "").target = self
        }
        if ZIPMemberRemovalFeature.available {
            menu.addItem(withTitle: "Remove from ZIP Copy…", action: #selector(removeCopy(_:)), keyEquivalent: "").target = self
        }
        if ZIPMemberAdditionFeature.available {
            menu.addItem(withTitle: "Add to ZIP Copy…", action: #selector(addCopy(_:)), keyEquivalent: "").target = self
        }
        if ArchiveOrderingActivation.available {
            let sorts = NSMenu(title:"Sort By")
            for field in ZIPArchiveOrder.Field.allCases {
                let item = sorts.addItem(withTitle:Self.title(field),action:#selector(orderBy(_:)),keyEquivalent:"")
                item.target = self; item.representedObject = field.rawValue
            }
            sorts.addItem(.separator())
            sorts.addItem(withTitle:"Descending Order",action:#selector(reverseOrder(_:)),keyEquivalent:"").target = self
            menu.addItem(.separator())
            let container = menu.addItem(withTitle:"Sort By",action:nil,keyEquivalent:""); container.submenu = sorts
            (table.headerView as? FileTableHeaderView)?.columnMenu = sorts
        }
        table.menu = menu
        table.memberCommandTarget = self
        table.memberCommands = [
            .newFolder: #selector(createZIPFolder(_:)), .newTextFile: #selector(createZIPFile(_:)),
            .newFolderWithSelection: #selector(groupZIPSelection(_:)), .duplicate: #selector(duplicateMembers(_:)),
            .rename: move ? #selector(renameOriginal(_:)) : #selector(renameCopy(_:)),
            .trash: #selector(removeOriginal(_:)), .properties: #selector(showMemberProperties(_:)),
            .editText: #selector(editTextSelected(_:)), .compareTextFiles: #selector(compareTextSelected(_:))]
        table.contextMenuProvider = { [weak self] in self?.contextMenu() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints=false;addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12).interfaceScaled,
            scroll.trailingAnchor.constraint(equalTo:trailingAnchor),scroll.topAnchor.constraint(equalTo:topAnchor),scroll.bottomAnchor.constraint(equalTo:bottomAnchor)])
        table.marquee=TableMarqueeSelection(table:table,scroll:scroll,parent:self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); table.columnSizing.fit(table) }

    func configure(glass: Bool, motion: BrowserMotionPreferences, order: ZIPArchiveOrder?) {
        if let header = table.headerView as? FileTableHeaderView {
            if header.usesGlass != glass { header.usesGlass = glass }
            header.motionEnabled = motion.allows(.sortIndicators)
            header.motionMode = motion.mode
        }
        table.backgroundColor = glass ? .clear : .controlBackgroundColor
        table.usesAlternatingRowBackgroundColors = !glass
        scroll.drawsBackground = !glass
        scroll.contentView.drawsBackground = !glass
        scroll.backgroundColor = .controlBackgroundColor
        presentOrder(order)
    }
    func setExternalExportsReady(_ ready: Bool) {
        table.setDraggingSourceOperationMask(ready && ArchivePromiseExportFeature.available ? .copy : [], forLocal: false)
    }
    private static func title(_ field: ZIPArchiveOrder.Field) -> String {
        switch field {
        case .name: "Name"; case .logical: "Size"; case .modified: "Date Modified"
        case .packed: "Packed Size"; case .method: "Compression Method"
        }
    }
    private static func columnKey(_ field: ZIPArchiveOrder.Field) -> String { field == .logical ? "size" : field.rawValue }
    private static func field(_ key: String?) -> ZIPArchiveOrder.Field? { key == "size" ? .logical : key.flatMap { ZIPArchiveOrder.Field(rawValue:$0) } }
    private func presentOrder(_ order: ZIPArchiveOrder?) {
        let wasUpdating = updating; updating = true; defer { updating = wasUpdating }
        ordering = order
        for column in table.tableColumns {
            let field = Self.field(column.identifier.rawValue)
            let desired = order != nil && field != nil
            if desired && column.sortDescriptorPrototype == nil {
                column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue,
                    ascending: field != .logical && field != .packed && field != .modified)
            } else if !desired && column.sortDescriptorPrototype != nil { column.sortDescriptorPrototype = nil }
        }
        let descriptors = order.map { [NSSortDescriptor(key:Self.columnKey($0.field),ascending:!$0.descending)] } ?? []
        if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors; table.headerView?.needsDisplay = true }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !updating, let descriptor = tableView.sortDescriptors.first, let field = Self.field(descriptor.key) else { return }
        let next = ZIPArchiveOrder(field,descending:!descriptor.ascending)
        presentOrder(onOrder?(next) == true ? next : ordering)
        tableView.headerView?.needsDisplay = true
    }
    @objc private func orderBy(_ sender: NSMenuItem) {
        guard canOrder?() == true, let raw = sender.representedObject as? String, let field = ZIPArchiveOrder.Field(rawValue:raw) else { return }
        let descending = ordering?.field == field ? ordering?.descending ?? false : field == .logical || field == .packed || field == .modified
        let next = ZIPArchiveOrder(field,descending:descending)
        if onOrder?(next) == true { presentOrder(next) }
    }
    @objc private func reverseOrder(_ sender: NSMenuItem) {
        guard canOrder?() == true, let ordering else { return }
        let next = ZIPArchiveOrder(ordering.field,descending:!ordering.descending)
        if onOrder?(next) == true { presentOrder(next) }
    }

    func observe(_ page: [ZIPArchiveItem], selection: Set<ZIPItemID>, showsLocation: Bool) {
        updating = true
        defer { updating = false }
        // Items in a session are immutable. Progress/selection changes must not
        // invalidate native row geometry or rebuild the page.
        if items.map(\.id) != page.map(\.id) || self.showsLocation != showsLocation {
            self.showsLocation = showsLocation
            table.tableColumns.first { $0.identifier.rawValue == "location" }?.isHidden = !showsLocation
            items = page
            table.installNameSelectionPage(page.map(\.name))
            table.reloadData()
            revealGeneration = UUID()
            let token = revealGeneration
            Task { @MainActor [weak self] in
                guard let self, token == self.revealGeneration, self.animatesNewRows else { return }
                self.table.layoutSubtreeIfNeeded()
                let visible = self.table.rows(in: self.table.visibleRect)
                if visible.location != NSNotFound {
                    for row in visible.location..<min(visible.upperBound, self.items.count) {
                        if let view = self.table.rowView(atRow: row, makeIfNecessary: false) { ToolContentMotion.reveal(view) }
                    }
                }
            }
        }
        let indexes = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    var selectedIDs: Set<ZIPItemID> {
        Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
    }

    private var singleFolder: Bool {
        selectedIDs.count == 1 && items.contains { selectedIDs.contains($0.id) && $0.folder != nil }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let key = tableColumn?.identifier else { return nil }
        let item = items[row]
        if key.rawValue == "name" {
            let cell = tableView.makeView(withIdentifier: key, owner: nil) as? ArchiveNameCell ?? ArchiveNameCell()
            cell.identifier = key
            cell.configure(item, isCut: isCut?(item.id) == true)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: key, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = key
        if cell.textField == nil {
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.textColor = .secondaryLabelColor
            InterfaceMetrics.setFont(field, base: key.rawValue == "location" ? .systemFont(ofSize: NSFont.systemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.toolTip = nil
        switch key.rawValue {
        case "location":
            let parent = (item.path as NSString).deletingLastPathComponent
            cell.textField?.stringValue = parent.isEmpty ? "Archive" : parent
            cell.toolTip = item.path
        case "size": cell.textField?.stringValue = ArchiveBrowserModel.size(item.logicalBytes)
        case "modified":
            cell.textField?.stringValue = item.modification?.displayText ?? "—"
            cell.toolTip = item.modification?.explanation
        case "packed": cell.textField?.stringValue = ArchiveBrowserModel.size(item.packedBytes)
        case "method": cell.textField?.stringValue = item.methodName
        default: return nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating { onSelection?(selectedIDs) }
    }
    private func addFolder(at row: Int, operation: NSTableView.DropOperation) -> ZIPFolderID? {
        operation == .on && items.indices.contains(row) ? items[row].folder : nil
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let folder = addFolder(at: row, operation: operation)
        if let source = info.draggingSource as? ArchiveMetadataTable {
            guard source === table, let folder,
                  let offer = ArchiveMemberDragSource.capture(info, for: .moveWithinArchive),
                  offer.model?.canMoveMembers(offer.ids, into: folder) == true else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return .move
        }
        guard ZIPMemberAdditionFeature.available, canAddFiles?(folder) == true,
              let source = BrowserDragDropController.captureLocalFileDropSource(info), source.key != acceptedFileDrop else { return [] }
        tableView.setDropRow(folder == nil ? -1 : row, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        let folder = addFolder(at: row, operation: operation)
        if let source = info.draggingSource as? ArchiveMetadataTable {
            guard source === table, let folder,
                  let offer = ArchiveMemberDragSource.capture(info, for: .moveWithinArchive),
                  let model = offer.model, model.canMoveMembers(offer.ids, into: folder) else { return false }
            return ArchiveMemberDragSource.admit(offer) { model.moveMembers(offer, into: folder) }
        }
        guard ZIPMemberAdditionFeature.available, canAddFiles?(folder) == true,
              let source = BrowserDragDropController.captureLocalFileDropSource(info), source.key != acceptedFileDrop,
              onAddFiles?(source, folder) == true else { return false }
        acceptedFileDrop = source.key
        return true
    }
    func tableView(_ tableView: NSTableView,pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(row), selectedIDs.contains(items[row].id) else { return nil }
        return memberDragSource?.writer(ids: selectedIDs, item: items[row])
    }
    func tableView(_ tableView: NSTableView,draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,forRowIndexes rowIndexes: IndexSet) {
        guard rowIndexes.allSatisfy({ items.indices.contains($0) }) else { return }
        memberDragSource?.begin(sequence: session.draggingSequenceNumber,ids: Set(rowIndexes.map { items[$0].id }),board: session.draggingPasteboard)
    }
    func tableView(_ tableView: NSTableView,draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,operation: NSDragOperation) {
        #if DEBUG
        table.lastDragEndPointForVerification = [screenPoint.x,screenPoint.y]
        table.lastDragEndOperationForVerification = operation.rawValue
        #endif
        memberDragSource?.end(sequence: session.draggingSequenceNumber, operation: operation, point: screenPoint)
    }

    @objc private func openSelected(_ sender: Any?) {
        if sender is NSTableView, table.clickedRow < 0 { return }
        onOpen?(selectedIDs)
    }
    @objc private func openFolder(_ sender: Any?) { if singleFolder { onOpen?(selectedIDs) } }
    @objc private func previewSelected(_ sender: Any?) {
        if canPreview?(selectedIDs) == true { onPreview?(selectedIDs) }
    }
    @objc private func editTextSelected(_ sender: Any?) {
        if canEditText?(selectedIDs) == true { onEditText?(selectedIDs) }
    }
    @objc private func compareTextSelected(_ sender: Any?) {
        if canCompareText?() == true { onCompareText?() }
    }
    @objc private func previewBytesSelected(_ sender: Any?) {
        if ZIPBytePreviewFeature.available, canPreview?(selectedIDs) == true { onPreviewBytes?(selectedIDs) }
    }
    @objc private func extractSelected(_ sender: Any?) {
        if canExtract?(selectedIDs) == true { onExtract?(selectedIDs) }
    }
    @objc private func showMemberProperties(_ sender: Any?) {
        if canShowProperties?(selectedIDs) == true { onProperties?(selectedIDs) }
    }
    @objc private func showInArchive(_ sender: Any?) { if canShowInArchive?() == true { onShowInArchive?() } }
    @objc private func renameCopy(_ sender: Any?) {
        if canRenameCopy?(selectedIDs) == true { onRenameCopy?(selectedIDs) }
    }
    @objc private func renameOriginal(_ sender: Any?) {
        if ZIPOriginalUpdateFeature.available && canRenameCopy?(selectedIDs) == true { onRenameOriginal?(selectedIDs) }
    }
    @objc private func removeOriginal(_ sender: Any?) {
        if ZIPOriginalUpdateFeature.available && canRemoveCopy?(selectedIDs) == true { onRemoveOriginal?(selectedIDs) }
    }
    @objc private func addOriginal(_ sender: Any?) {
        if ZIPOriginalUpdateFeature.available && canAddCopy?() == true { onAddOriginal?() }
    }
    @objc private func createZIPFolder(_ sender: Any?) {
        if ZIPMemberCreationFeature.available && canNewFolder?() == true { onNewFolder?() }
    }
    @objc private func groupZIPSelection(_ sender: Any?) {
        if canGroup?() == true { onGroup?() }
    }
    @objc private func createZIPFile(_ sender: Any?) {
        if ZIPMemberCreationFeature.available && canNewFolder?() == true { onNewFile?() }
    }
    @objc private func cutMembers(_ sender: Any?) { if canCaptureClipboard?(.move) == true { onCut?() } }
    @objc private func copyMembers(_ sender: Any?) { if canCaptureClipboard?(.copy) == true { onCopyMembers?() } }
    @objc private func pasteItems(_ sender: Any?) { if canPaste?() == true { onPaste?() } }
    @objc private func removeCopy(_ sender: Any?) {
        if canRemoveCopy?(selectedIDs) == true { onRemoveCopy?(selectedIDs) }
    }
    @objc private func duplicateMembers(_ sender: Any?) {
        if canDuplicate?(selectedIDs) == true { onDuplicate?(selectedIDs) }
    }
    @objc private func addCopy(_ sender: Any?) { if canAddCopy?() == true { onAddCopy?() } }
    private func contextMenu() -> NSMenu {
        let selected = !selectedIDs.isEmpty
        let groups: [[Selector]] = selected ? [
            [#selector(openFolder(_:)), #selector(editTextSelected(_:)), #selector(compareTextSelected(_:)),
             #selector(previewSelected(_:)), #selector(previewBytesSelected(_:))],
            [#selector(extractSelected(_:)), #selector(showMemberProperties(_:))],
            [#selector(groupZIPSelection(_:))],
            [#selector(cutMembers(_:)), #selector(copyMembers(_:)), #selector(duplicateMembers(_:)), #selector(renameOriginal(_:)), #selector(removeOriginal(_:))],
            [#selector(showInArchive(_:))]
        ] : [[#selector(createZIPFile(_:)), #selector(createZIPFolder(_:))],
             [#selector(pasteItems(_:)), #selector(addOriginal(_:)), #selector(addCopy(_:))]]
        let menu = NativeContextMenu.arrange(table.menu, groups: groups, allows: validateMenuItem)
        if selected {
            let copy = NativeContextMenu.arrange(table.menu,
                groups: [[#selector(renameCopy(_:)), #selector(removeCopy(_:))]], allows: validateMenuItem)
            if !copy.items.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let item = menu.addItem(withTitle: "Save a ZIP Copy", action: nil, keyEquivalent: ""); item.submenu = copy
            }
        } else if let sort = table.menu?.items.first(where: { $0.submenu != nil }), let item = sort.copy() as? NSMenuItem {
            if !menu.items.isEmpty { menu.addItem(.separator()) }; menu.addItem(item)
        }
        return menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(createZIPFolder(_:)): return ZIPMemberCreationFeature.available && onNewFolder != nil && canNewFolder?() == true
        case #selector(groupZIPSelection(_:)): return onGroup != nil && canGroup?() == true
        case #selector(createZIPFile(_:)): return ZIPMemberCreationFeature.available && onNewFile != nil && canNewFolder?() == true
        case #selector(cutMembers(_:)): return onCut != nil && canCaptureClipboard?(.move) == true
        case #selector(copyMembers(_:)): return onCopyMembers != nil && canCaptureClipboard?(.copy) == true
        case #selector(pasteItems(_:)): return onPaste != nil && canPaste?() == true
        case #selector(openFolder(_:)): return singleFolder
        case #selector(previewSelected(_:)):
            let ids = selectedIDs
            menuItem.title = ArchivePreviewMode.preferred(for: items.first { ids.contains($0.id) }?.name).commandTitle
            return canPreview?(ids) == true
        case #selector(editTextSelected(_:)): return canEditText?(selectedIDs) == true
        case #selector(compareTextSelected(_:)): return canCompareText?() == true
        case #selector(previewBytesSelected(_:)): return ZIPBytePreviewFeature.available && canPreview?(selectedIDs) == true
        case #selector(extractSelected(_:)): return canExtract?(selectedIDs) == true
        case #selector(showMemberProperties(_:)): return onProperties != nil && canShowProperties?(selectedIDs) == true
        case #selector(showInArchive(_:)): return canShowInArchive?() == true
        case #selector(renameCopy(_:)): return canRenameCopy?(selectedIDs) == true
        case #selector(renameOriginal(_:)): return ZIPOriginalUpdateFeature.available && onRenameOriginal != nil && canRenameCopy?(selectedIDs) == true
        case #selector(removeOriginal(_:)): return ZIPOriginalUpdateFeature.available && onRemoveOriginal != nil && canRemoveCopy?(selectedIDs) == true
        case #selector(addOriginal(_:)): return ZIPOriginalUpdateFeature.available && onAddOriginal != nil && canAddCopy?() == true
        case #selector(removeCopy(_:)): return canRemoveCopy?(selectedIDs) == true
        case #selector(duplicateMembers(_:)): return onDuplicate != nil && canDuplicate?(selectedIDs) == true
        case #selector(addCopy(_:)): return canAddCopy?() == true
        case #selector(orderBy(_:)):
            menuItem.state = (menuItem.representedObject as? String) == ordering?.field.rawValue ? .on : .off
            return canOrder?() == true
        case #selector(reverseOrder(_:)):
            menuItem.state = ordering?.descending == true ? .on : .off
            return canOrder?() == true
        default: return false
        }
    }
}

@MainActor private final class ArchiveNameCell: NSTableCellView {
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingMiddle
        InterfaceMetrics.setFont(label, base: .systemFont(ofSize: NSFont.systemFontSize))
        symbol.imageScaling = .scaleProportionallyDown
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted member")
        lock.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [symbol, label, lock])
        stack.spacing = 7
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label; imageView = symbol
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 16).interfaceScaled,
            symbol.heightAnchor.constraint(equalToConstant: 16).interfaceScaled,
            lock.widthAnchor.constraint(equalToConstant: 12),
            lock.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ item: ZIPArchiveItem, isCut: Bool) {
        label.stringValue = item.name
        let kind = item.kind == .directory ? "directory" : item.kind == .symbolicLink ? "symbolicLink" : "file"
        let role = FileIconRole.classify(name: item.name, kind: kind)
        symbol.image = BrowserCellSymbols.image(role)
        symbol.contentTintColor = FileOpeningSymbol.tint(.ordinary, directory: item.kind == .directory)
        lock.isHidden = !item.isEncrypted
        alphaValue = isCut ? 0.55 : 1
        toolTip = item.path + (item.isEncrypted ? " · Encrypted; names only" : "")
    }
}

/// Both standalone archive windows update menu ownership after native focus
/// changes. Embedded tabs keep their browser's existing command route.
@MainActor class ArchiveKeyboardWindow: ToolMotionWindow {
    weak var shortcutSettings: BrowserSettings?
    var focusArchiveSearch: (() -> Void)?
    func focusArchiveSearchField(identifier: String) {
        guard let contentView else { return }
        var pending = [contentView], count = 0
        while let view = pending.popLast(), count < 4096 {
            count += 1
            if let field = view as? NSTextField, field.isEnabled,
               field.identifier?.rawValue == identifier || field.accessibilityIdentifier() == identifier {
                if makeFirstResponder(field) { field.selectText(nil) }
                return
            }
            pending.append(contentsOf: view.subviews)
        }
    }
    override func becomeKey() {
        super.becomeKey()
        BrowserShortcutMenus.refreshMainMenuForCurrentFocus()
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { BrowserShortcutMenus.refreshMainMenuForCurrentFocus() }
        return accepted
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        BrowserShortcutMenus.refreshMainMenuForCurrentFocus()
        if let table = firstResponder as? ArchiveMetadataTable,
           table.routeStandaloneKeyEquivalent(event) { return true }
        if (firstResponder as? NSTextView)?.hasMarkedText() != true,
           let settings = shortcutSettings, let shortcut = BrowserShortcut(event),
           settings.shortcutMap.resolve(shortcut, fileSurface: false) == .filter,
           !SystemShortcutSnapshot.shared.conflicts(event),
           !BrowserShortcutMenus.hasUserOverride(.filter, in: NSApp.mainMenu) {
            if !event.isARepeat { focusArchiveSearch?() }
            return true
        }
        if event.isARepeat, let table = firstResponder as? ArchiveMetadataTable,
           let settings = table.keyboardContextSettings, KeyboardContextMenu.matches(event, settings: settings) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class ArchiveMetadataTable: FileTableView {
    private struct NameRow: Sendable { let row: Int; let name: String }
    private let nameSelection = NameSelectionRequest()
    private var nameRows: [NameRow] = []
    private var namePage = UUID()
    var allowsNameSelection: (() -> Bool)?
    var reportNameSelection: ((String) -> Void)?
    weak var memberDragSource: ArchiveMemberDragSource?
    weak var keyboardContextSettings: BrowserSettings?
    var onForward: (() -> Void)?, onRefresh: (() -> Void)?
    weak var memberCommandTarget: NSView?
    var memberCommands: [BrowserCommand: Selector] = [:]

    func installNameSelectionPage(_ names: [String]) {
        nameSelection.cancel()
        namePage = UUID()
        nameRows = names.enumerated().map { .init(row: $0.offset, name: $0.element) }
    }

    func retireNameSelection() {
        installNameSelectionPage([])
        allowsNameSelection = nil
        reportNameSelection = nil
    }

    func cancelNameSelection() { nameSelection.cancel() }

    var canSelectByName: Bool {
        nameSelection.isIdle && !nameRows.isEmpty && allowsNameSelection?() == true
            && window?.isKeyWindow == true && window?.attachedSheet == nil && window?.firstResponder === self
    }

    @objc func selectByName(_ sender: Any?) {
        guard canSelectByName, let parent = window else { return }
        let revision = namePage
        let selection = selectedRowIndexes
        nameSelection.present(in: parent, scope: "Select from the names on this archive page.",
            entries: nameRows, selected: Set(selection), name: { $0.name }, id: { $0.row },
            isCurrent: { [weak self, weak parent] in
                guard let self, let parent else { return false }
                return window === parent && parent.isKeyWindow && parent.firstResponder === self
                    && allowsNameSelection?() == true && namePage == revision && selectedRowIndexes == selection
            }) { [weak self] next in
                guard let self else { return }
                if let next { selectRowIndexes(IndexSet(next), byExtendingSelection: false) }
                else { reportNameSelection?("No names match on this archive page.") }
            }
    }

    private func memberCommandItem(_ command: BrowserCommand) -> NSMenuItem? {
        guard let action = memberCommands[command], let target = memberCommandTarget else { return nil }
        return menu?.items.first { $0.action == action && ($0.target as AnyObject?) === target }
    }
    func memberCommandEnabled(_ action: Selector?) -> Bool {
        guard let action, let command = memberCommands.keys.first(where: { $0.selector == action }),
              let item = memberCommandItem(command), let owner = memberCommandTarget as? NSMenuItemValidation else { return false }
        return owner.validateMenuItem(item)
    }
    private func performMemberCommand(_ command: BrowserCommand) -> Bool {
        guard memberCommands[command] != nil else { return false }
        if let item = memberCommandItem(command), let owner = memberCommandTarget as? NSMenuItemValidation,
           owner.validateMenuItem(item), let action = item.action {
            NSApp.sendAction(action, to: memberCommandTarget, from: item)
        }
        // A disabled archive action must not fall through to the browser.
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); installShortcutRouting()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder); installShortcutRouting()
    }
    private func installShortcutRouting() {
        // An unbound key goes straight to NSTableView. It must not revive
        // FileTableView's preset fallback after a custom binding was cleared.
        onShortcut = { [weak self] event in
            guard let self else { return false }
            if let embeddedShortcut { return embeddedShortcut(event) }
            return routeStandaloneShortcut(event)
        }
    }
    private func routeStandaloneShortcut(_ event: NSEvent) -> Bool {
        guard window is ArchiveKeyboardWindow, window?.isKeyWindow == true, window?.firstResponder === self,
              let settings = keyboardContextSettings, let shortcut = BrowserShortcut(event),
              !SystemShortcutSnapshot.shared.conflicts(event),
              let action = settings.shortcutMap.resolve(shortcut, fileSurface: true),
              !BrowserShortcutMenus.hasUserOverride(action, in: NSApp.mainMenu) else { return false }
        if !event.isARepeat || action.allowsRepeat {
            switch action {
            case .copy: if commandValidation?(#selector(BrowserViewController.copyFileURLs(_:))) == true { onCopy?() }
            case .cut: if commandValidation?(#selector(BrowserViewController.cutFileURLs(_:))) == true { onCut?() }
            case .paste: if commandValidation?(#selector(BrowserViewController.pasteFileURLs(_:))) == true { onPaste?() }
            case .open: onOpen?()
            case .rename: onRename?()
            case .quickLook: onPreview?()
            case .back: onBack?()
            case .forward: onForward?()
            case .up: onUp?()
            case .refresh: onRefresh?()
            case .filter: (window as? ArchiveKeyboardWindow)?.focusArchiveSearch?()
            case .selectAll: selectAll(nil)
            case .selectByName: selectByName(nil)
            case .selectionMenu: showKeyboardContextMenu(nil)
            default: return performMemberCommand(action)
            }
        }
        return true
    }

    /// The main menu belongs to the browser window. Handle supported archive
    /// equivalents before AppKit can send them to that browser owner.
    func routeStandaloneKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let settings = keyboardContextSettings, let key = BrowserShortcut(event),
              let action = settings.shortcutMap.resolve(key, fileSurface: true),
              [.copy, .cut, .paste, .open, .rename, .quickLook, .back, .forward, .up, .refresh,
               .selectAll, .selectByName, .selectionMenu].contains(action) || memberCommands[action] != nil else { return false }
        return routeStandaloneShortcut(event)
    }

    private var canShowKeyboardContextMenu: Bool {
        window is ArchiveKeyboardWindow && embeddedShortcut == nil && keyboardContextSettings != nil
            && window?.firstResponder === self && KeyboardContextMenu.canPresent(in: self)
    }

    @objc func showKeyboardContextMenu(_ sender: Any?) {
        guard canShowKeyboardContextMenu, let menu = contextMenuProvider?() ?? menu else { return }
        KeyboardContextMenu.prepare(in: self, menu: menu)?.present()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectByName(_:)) { return canSelectByName }
        if item.action == #selector(showKeyboardContextMenu(_:)) {
            return canShowKeyboardContextMenu && (contextMenuProvider != nil || menu != nil)
        }
        return super.validateMenuItem(item)
    }
    #if DEBUG
    private(set) var mouseDownsForVerification = 0
    private(set) var lastMouseRowForVerification = -1
    private(set) var lastMousePointForVerification: [Double] = []
    private(set) var dragHitCallsForVerification = 0
    private(set) var lastDragHitForVerification = false
    var lastDragEndPointForVerification: [Double] = []
    var lastDragEndOperationForVerification: UInt = 0
    override func mouseDown(with event: NSEvent) {
        mouseDownsForVerification += 1
        let point = convert(event.locationInWindow,from:nil)
        lastMouseRowForVerification = row(at:point)
        lastMousePointForVerification = [point.x,point.y]
        super.mouseDown(with:event)
    }
    override func canDragRows(with rowIndexes: IndexSet,at mouseDownPoint: NSPoint) -> Bool {
        let result = super.canDragRows(with:rowIndexes,at:mouseDownPoint)
        dragHitCallsForVerification += 1; lastDragHitForVerification = result
        return result
    }
    #endif
    var onPreview: (() -> Void)?
    var onUp: (() -> Void)?
    var embeddedShortcut: ((NSEvent) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        if BrowserPointerSelection.isSelectionAlias(event, in: self, behavior: behavior,
            isEditingText: currentEditor() != nil) { return nil }
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 {
            if !selectedRowIndexes.contains(index) {
                selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        return super.menu(for: event)
    }
}
