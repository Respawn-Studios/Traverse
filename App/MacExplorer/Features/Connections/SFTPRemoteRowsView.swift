import AppKit
@_spi(Qualification) import LocalStorage

/// Exact remote observations. A gated native drag offers one file promise or
/// an in-process selected group; it never exposes a local file URL or reads a
/// remote body during the gesture.
@MainActor final class SFTPRemoteRowsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let table = RemoteFileTableView(), scroll = NSScrollView()
    let message = NSTextField(wrappingLabelWithString: "Preparing directory…")
    private(set) var cache = SFTPDirectoryPageCache()
    private(set) var lastPageSort: SFTPStoredSort?, lastPageDescending: Bool?
    var onPage: ((UInt64) -> Void)?, onOpen: ((SFTPStoredRow) -> Void)?, onSort: ((SFTPStoredSort, Bool) -> Void)?
    var onRefresh: (() -> Void)?, onStop: (() -> Void)?, onDisconnect: (() -> Void)?, onBack: (() -> Void)?, onUp: (() -> Void)?
    var onHome: (() -> Void)?
    var onPromiseWriter: ((Int) -> (any NSPasteboardWriting)?)? { didSet {
        table.setDraggingSourceOperationMask(onPromiseWriter != nil && SFTPFilePromiseFeature.externalAvailable ? .copy : [], forLocal: false)
        table.setDraggingSourceOperationMask(onPromiseWriter != nil && SFTPFilePromiseFeature.internalAvailable ? .copy : [], forLocal: true)
    } }
    var onPromiseDidBegin: ((NSDraggingSession, IndexSet) -> Void)?, onPromiseDidEnd: ((NSDraggingSession, NSDragOperation) -> Void)?
    var onDropPreview: ((NSDraggingInfo) -> Int?)?, onDropFiles: ((NSDraggingInfo) -> Bool)?
    private let dropHighlight = RemoteUploadDropHighlightView(frame: .zero)
    var onProperties: (() -> Void)?, onCopyName: (() -> Void)?, onCopyPath: (() -> Void)?
    var canInspect: (() -> Bool)?, canCopyName: (() -> Bool)?, canCopyPath: (() -> Bool)?
    var onSelectionChanged: (() -> Void)?
    var onCut: (() -> Void)? { didSet { cutItem?.isHidden = onCut == nil } }
    var onCopyFile: (() -> Void)? { didSet { copyFileItem?.isHidden = onCopyFile == nil } }
    var copyFileAllowed: (() -> Bool)?
    private var copyFileItem: NSMenuItem?
    var cutAllowed: (() -> Bool)?, cutAppearanceForEntry: ((SFTPWorkerEntry) -> Bool)?
    private var cutItem: NSMenuItem?
    var onEditText: (() -> Void)? { didSet {
        editItem?.isHidden = onEditText == nil
        updateCapabilityLabel()
    } }
    var editTextAllowed: (() -> Bool)?, nativeOpenAllowed: (() -> Bool)?
    var onNativeTextOpen: (() -> Void)?
    var onViewText: (() -> Void)? { didSet { viewTextItem?.isHidden = onViewText == nil; updateCapabilityLabel() } }
    var viewTextAllowed: (() -> Bool)?
    var openingAppearanceForEntry: ((SFTPWorkerEntry) -> FileOpeningAppearance)?
    var selectedObservation: SFTPStoredRow? { available && table.numberOfSelectedRows == 1 ? cached(table.selectedRow) : nil }
    var onDownload: (() -> Void)? { didSet {
        downloadItem?.isHidden = onDownload == nil
        updateCapabilityLabel()
    } }
    var onDownloadToPane: (() -> Void)? { didSet { paneItem?.isHidden = onDownloadToPane == nil } }
    var downloadAllowed: (() -> Bool)?, paneDownloadAllowed: (() -> Bool)?
    var onUpload: (() -> Void)? { didSet { uploadItem?.isHidden = onUpload == nil; updateCapabilityLabel() } }
    var onUploadFolder: (() -> Void)? { didSet { folderUploadItem?.isHidden = onUploadFolder == nil; updateCapabilityLabel() } }
    var folderUploadAllowed: (() -> Bool)?
    var onUploadHistory: (() -> Void)? { didSet { historyItem?.isHidden = onUploadHistory == nil; outcomeButton.isHidden = onUploadHistory == nil } }
    var uploadAllowed: (() -> Bool)?
    var onPaste: (() -> Void)? { didSet { pasteItem?.isHidden = onPaste == nil } }
    var pasteAllowed: (() -> Bool)?
    private var pasteItem: NSMenuItem?
    var onNewFile: (() -> Void)? { didSet { newFileItem?.isHidden = onNewFile == nil } }
    var newFileAllowed: (() -> Bool)?
    var onNewFolder: (() -> Void)? { didSet { newFolderItem?.isHidden = onNewFolder == nil; updateCapabilityLabel() } }
    var onRename: (() -> Void)? { didSet { renameItem?.isHidden = onRename == nil } }
    var onServerCopy: (() -> Void)? { didSet { serverCopyItem?.isHidden = onServerCopy == nil; updateCapabilityLabel() } }
    var onDuplicate: (() -> Void)? { didSet { duplicateItem?.isHidden = onDuplicate == nil } }
    var serverCopyAllowed: (() -> Bool)?
    private var serverCopyItem: NSMenuItem?, duplicateItem: NSMenuItem?
    var onMove: (() -> Void)? { didSet { moveItem?.isHidden = onMove == nil; updateCapabilityLabel() } }
    var onDeletePermanently: (() -> Void)? { didSet { deleteItem?.isHidden = onDeletePermanently == nil } }
    var onActionHistory: (() -> Void)? { didSet { actionHistoryItem?.isHidden = onActionHistory == nil } }
    var newFolderAllowed: (() -> Bool)?, renameAllowed: (() -> Bool)?, deleteAllowed: (() -> Bool)?
    var renameExplanation: (() -> String?)?
    var moveAllowed: (() -> Bool)?, moveExplanation: (() -> String?)?
    var allowsDirectoryMove = false { didSet { updateCapabilityLabel() } }
    var allowsDirectoryRename = false { didSet {
        renameItem?.toolTip = renameToolTip
        updateCapabilityLabel()
    } }
    private var renameToolTip: String {
        allowsDirectoryRename
            ? "Give the selected file or folder a new name in this server folder."
            : "Give the selected file a new name in this server folder."
    }
    var allowsEmptyDirectoryDelete = false { didSet {
        deleteItem?.toolTip = deletionToolTip
        updateCapabilityLabel()
    } }
    private var deletionToolTip: String {
        allowsEmptyDirectoryDelete
            ? "Delete one file or empty folder after confirmation. Remote Trash and Undo are not available."
            : "Delete one file after confirmation. Remote Trash and Undo are not available."
    }
    private var newFileItem: NSMenuItem?, newFolderItem: NSMenuItem?, renameItem: NSMenuItem?, moveItem: NSMenuItem?, deleteItem: NSMenuItem?, actionHistoryItem: NSMenuItem?
    private var downloadItem: NSMenuItem?, paneItem: NSMenuItem?
    private var editItem: NSMenuItem?, viewTextItem: NSMenuItem?, capabilityItem: NSMenuItem?
    private var uploadItem: NSMenuItem?, folderUploadItem: NSMenuItem?, historyItem: NSMenuItem?
    private let outcome = NSTextField(wrappingLabelWithString: ""), outcomeButton = NSButton(title: "Upload Outcomes…", target: nil, action: nil)
    private let outcomeRow = NSStackView()
    private var scrollObservation: BrowserNotificationObservation?, selectedIDs: Set<UInt64> = [], updating = false
    private(set) var findQuery = ""
    private(set) var findRequest: RemoteDirectoryFindQuery?
    private(set) var selectionRevision = UUID()
    private var findFailure = false
    private var available = true, paused = false
    private var retryAllowed = false
    private let recoveryActions = NSStackView()
    private let homeButton = NSButton(title: "Home", target: nil, action: nil)
    private let upButton = NSButton(title: "Up", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    var canOpenSelectedFolder: Bool { available && table.numberOfSelectedRows == 1 && cached(table.selectedRow)?.entry.isDirectory == true }
    private var canEditSelectedText: Bool {
        guard let row = selectedObservation, row.entry.isDirectory == false, onEditText != nil else { return false }
        return editTextAllowed?() == true
    }
    private var canViewSelectedText: Bool {
        available && selectedObservation != nil && onViewText != nil && viewTextAllowed?() == true
    }
    var canOpenSelectedItem: Bool {
        canOpenSelectedFolder || (canEditSelectedText || canViewSelectedText) && nativeOpenAllowed?() == true
    }
    var selectedDownload: SFTPDownloadSelection? {
        guard available, table.numberOfSelectedRows == 1, cache.snapshot?.state == .complete, let generation = cache.generation, let row = cached(table.selectedRow) else { return nil }
        return try? .init(generation: generation, row: row)
    }
    var selectedDownloadBatch: SFTPDownloadBatchPlan? {
        guard available, (2...16).contains(table.numberOfSelectedRows), let snapshot = cache.snapshot,
              snapshot.state == .complete, let generation = cache.generation else { return nil }
        let rows = table.selectedRowIndexes.compactMap(cached)
        guard rows.count == table.numberOfSelectedRows else { return nil }
        return try? .init(generation: generation, snapshot: snapshot,
            selections: rows.map { try .init(generation: generation, row: $0) })
    }
    var folderDownloadsAvailable = false { didSet { updateCapabilityLabel() } }
    var selectedFolderDownload: SFTPFolderDownloadSelection? {
        guard available, table.numberOfSelectedRows == 1, let snapshot = cache.snapshot, snapshot.state == .complete,
              let generation = cache.generation, let row = cached(table.selectedRow) else { return nil }
        return try? .init(generation: generation, snapshot: snapshot, row: row)
    }
    func openSelectedItem() { openSelected(nil) }
    private func cached(_ row: Int) -> SFTPStoredRow? {
        guard row >= 0 else { return nil }
        if !findQuery.isEmpty, cache.find?.query != findRequest { return nil }
        return cache.entry(at: UInt64(row))
    }
    private var loadedRows: IndexSet {
        if !findQuery.isEmpty, cache.find?.query != findRequest { return [] }
        return IndexSet(cache.loadedEntries.compactMap { Int(exactly: $0.offset) })
    }
    /// Positive cache knowledge only; absence is still checked by the server.
    func hasLoadedName(_ name: SFTPRemoteName) -> Bool {
        cache.loadedEntries.contains { $0.row.entry.name.wireUTF8 == name.wireUTF8 }
    }
    func suggestedNewName(_ original: String) -> String {
        FilenamePrompt.suggestedName(original) { candidate in
            guard let name = try? SFTPRemoteName(Data(candidate.utf8)) else { return true }
            return hasLoadedName(name)
        }
    }
    func inlineFilenameAnchor() -> (view: NSView, rect: NSRect, label: NSTextField)? {
        guard selectedObservation != nil else { return nil }
        return NativeFilenameAnchor.selected(in: table)
    }
    func selectCreatedEmptyFile(named name: SFTPRemoteName) -> Bool {
        guard available, cache.snapshot?.state == .complete, findQuery.isEmpty,
              let value = cache.loadedEntries.first(where: {
                  $0.row.entry.name.wireUTF8 == name.wireUTF8 && $0.row.entry.logicalBytes == 0
                      && $0.row.entry.permissions.map { $0 & 0o170000 == 0o100000 } == true
              }), let row = Int(exactly: value.offset) else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row); return true
    }
    func selectAllLoaded() { table.selectRowIndexes(loadedRows, byExtendingSelection: false) }
    func setFindQuery(_ value: String) {
        guard !findQuery.utf8.elementsEqual(value.utf8), value.isEmpty || (try? RemoteDirectoryFindQuery(text: value)) != nil else { return }
        selectionRevision = UUID()
        findQuery = value; invalidatePages(); requestVisiblePage()
    }
    func acceptFind(_ result: SFTPDirectoryFindResult) throws {
        guard result.query == findRequest else { throw RemoteDirectoryFindFailure.stale }
        try cache.setFindResult(result); findFailure = false; reload(); requestVisiblePage()
    }
    func failFind(_ query: RemoteDirectoryFindQuery) {
        guard findRequest == query else { return }; findFailure = true; reload()
    }
    var findStatusText: String? {
        guard !findQuery.isEmpty, let snapshot = cache.snapshot else { return nil }
        if findFailure { return "Search unavailable · Refresh this folder or try another name" }
        guard let result = cache.find, result.query == findRequest else {
            return snapshot.state == .complete ? "Finding names among \(snapshot.count.formatted()) items…"
                : "Finding names · \(snapshot.count.formatted()) observed so far…"
        }
        let matches = result.count == 1 ? "1 match" : "\(result.count.formatted()) matches"
        if snapshot.state == .complete { return matches + " · \(snapshot.count.formatted()) items in this folder" }
        let state = paused || snapshot.state == .stopped ? "Reading paused" : snapshot.state == .loading ? "Reading…" : "Partial listing"
        return matches + " among \(snapshot.count.formatted()) observed · " + state
    }
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        available ? IndexSet(loadedRows.filter { proposed.contains($0) }) : []
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { available && cached(row) != nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (key, title, width) in [("name", "Name", 350.0), ("modified", "Date Modified", 170.0), ("kind", "Kind", 100.0), ("size", "Size", 110.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width
            if key != "kind" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }; table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.headerView = FileTableHeaderView(frame: .init(x: 0, y: 0, width: 800, height: 28))
        table.dataSource = self; table.delegate = self; InterfaceMetrics.setRowHeight(table, base: 25); table.allowsMultipleSelection = true; table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(openSelected(_:)); table.onOpen = { [weak self] in self?.openSelected(nil) }
        table.onBack = { [weak self] in self?.onBack?() }; table.onUp = { [weak self] in self?.onUp?() }
        table.setAccessibilityLabel("SFTP directory. Open folders, inspect items and use available file actions.")
        let menu = NSMenu()
        for (title,action) in [("Properties…",#selector(properties(_:))),("Copy Name",#selector(copyName(_:))),("Copy Server Path",#selector(copyPath(_:)))] {
            menu.addItem(withTitle:title,action:action,keyEquivalent:"").target = self
        }
        editItem = menu.addItem(withTitle: "Edit in Traverse", action: #selector(editText(_:)), keyEquivalent: "")
        editItem?.target = self; editItem?.isHidden = true
        editItem?.toolTip = "Edit this text file on the connected server. Save checks whether it changed."
        viewTextItem = menu.addItem(withTitle: "View in Traverse", action: #selector(viewText(_:)), keyEquivalent: "")
        viewTextItem?.target = self; viewTextItem?.isHidden = true
        viewTextItem?.toolTip = "Read a captured text snapshot without changing the server file."
        menu.addItem(.separator())
        cutItem = menu.addItem(withTitle: "Cut", action: #selector(cutFile(_:)), keyEquivalent: "")
        cutItem?.target = self; cutItem?.isHidden = true
        copyFileItem = menu.addItem(withTitle: "Copy", action: #selector(copyFile(_:)), keyEquivalent: "")
        copyFileItem?.target = self; copyFileItem?.isHidden = true
        copyFileItem?.toolTip = "Copy this file, then paste into a folder on this connection."
        pasteItem = menu.addItem(withTitle: "Paste", action: #selector(pasteFiles(_:)), keyEquivalent: "")
        pasteItem?.target = self; pasteItem?.isHidden = true
        pasteItem?.toolTip = "Paste copied local items, or move a cut item within this connection."
        newFileItem = menu.addItem(withTitle: FilenamePrompt.newFileTitle + "…", action: #selector(newFile(_:)), keyEquivalent: "")
        newFileItem?.target = self; newFileItem?.isHidden = true
        newFolderItem = menu.addItem(withTitle: "New Folder…", action: #selector(newFolder(_:)), keyEquivalent: "")
        renameItem = menu.addItem(withTitle: "Rename…", action: #selector(rename(_:)), keyEquivalent: "")
        serverCopyItem = menu.addItem(withTitle: "Copy To…", action: #selector(copyOnServer(_:)), keyEquivalent: "")
        duplicateItem = menu.addItem(withTitle: "Duplicate", action: #selector(duplicateOnServer(_:)), keyEquivalent: "")
        for item in [serverCopyItem, duplicateItem] {
            item?.target = self; item?.isHidden = true
            item?.toolTip = "Copy the selected file on this server. The original and existing destination names are kept."
        }
        moveItem = menu.addItem(withTitle: "Move To…", action: #selector(move(_:)), keyEquivalent: "")
        deleteItem = menu.addItem(withTitle: "Delete Permanently…", action: #selector(deletePermanently(_:)), keyEquivalent: "")
        actionHistoryItem = menu.addItem(withTitle: "File Action History…", action: #selector(actionHistory(_:)), keyEquivalent: "")
        for item in [newFolderItem, renameItem, moveItem, deleteItem, actionHistoryItem] { item?.target = self; item?.isHidden = true }
        renameItem?.toolTip = renameToolTip
        moveItem?.toolTip = moveToolTip
        deleteItem?.toolTip = deletionToolTip
        uploadItem = menu.addItem(withTitle: "Upload File Here…", action: #selector(upload(_:)), keyEquivalent: "")
        folderUploadItem = menu.addItem(withTitle: "Upload Folder Here…", action: #selector(uploadFolder(_:)), keyEquivalent: "")
        historyItem = menu.addItem(withTitle: "Upload Outcomes…", action: #selector(uploadHistory(_:)), keyEquivalent: "")
        for item in [uploadItem, folderUploadItem, historyItem] { item?.target = self; item?.isHidden = true }
        downloadItem = menu.addItem(withTitle: "Download…", action: #selector(download(_:)), keyEquivalent: "")
        paneItem = menu.addItem(withTitle: "Download to Other Pane…", action: #selector(downloadToPane(_:)), keyEquivalent: "")
        for item in [downloadItem, paneItem] { item?.target = self; item?.isHidden = true }
        downloadItem?.toolTip = "Download a file, 2–16 selected files (up to 1 GiB together), or a supported folder after review. Existing destinations are preserved."
        for (title, action) in [("Open", #selector(openSelected(_:))), ("Refresh", #selector(refresh(_:))),
            ("Stop Reading", #selector(stop(_:))), ("Disconnect This Tab", #selector(disconnect(_:)))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        menu.addItem(.separator())
        capabilityItem = menu.addItem(withTitle: "Existing names are preserved · no remote Trash", action: nil, keyEquivalent: "")
        table.menu = menu
        table.contextMenuProvider = { [weak self] in self?.contextMenu() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        outcome.font = .systemFont(ofSize: 11); outcome.textColor = .secondaryLabelColor; outcome.maximumNumberOfLines = 3
        outcomeButton.target = self; outcomeButton.action = #selector(uploadHistory(_:)); outcomeButton.bezelStyle = .rounded
        outcomeRow.orientation = .horizontal; outcomeRow.spacing = 10; outcomeRow.addArrangedSubview(outcome); outcomeRow.addArrangedSubview(outcomeButton); outcomeRow.isHidden = true
        let content = NSStackView(views: [scroll, outcomeRow]); content.orientation = .vertical; content.spacing = 8; content.alignment = .leading
        pin(content, inside: self); scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -16).isActive = true; content.alignment = .trailing
        outcomeRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -12).isActive = true
        message.textColor = .secondaryLabelColor; message.alignment = .center; message.maximumNumberOfLines = 4
        for (button, action, identifier) in [(homeButton, #selector(goHome(_:)), "sftp-recovery-home"),
            (upButton, #selector(goUp(_:)), "sftp-recovery-up"), (retryButton, #selector(retryFolder(_:)), "sftp-recovery-retry")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.identifier = .init(identifier)
            recoveryActions.addArrangedSubview(button)
        }
        recoveryActions.orientation = .horizontal; recoveryActions.spacing = 8; recoveryActions.isHidden = true
        let notice = NSStackView(views: [message, recoveryActions]); notice.orientation = .vertical; notice.alignment = .centerX; notice.spacing = 12
        notice.translatesAutoresizingMaskIntoConstraints = false; addSubview(notice)
        NSLayoutConstraint.activate([notice.centerXAnchor.constraint(equalTo: centerXAnchor), notice.centerYAnchor.constraint(equalTo: centerYAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40), message.widthAnchor.constraint(lessThanOrEqualToConstant: 460)])
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObservation = BrowserNotificationObservation(name: NSView.boundsDidChangeNotification, object: scroll.contentView) { [weak self] _ in MainActor.assumeIsolated { self?.requestVisiblePage() } }
        table.marquee = TableMarqueeSelection(table: table, scroll: scroll, parent: self,
            revision: { [weak table] in table?.marqueeRevision ?? 0 },
            pointerBehavior: { [weak table] in table?.behavior ?? .mac },
            eligibleRows: { [weak self] proposed in guard let self, self.available else { return [] }; return IndexSet(self.loadedRows.filter { proposed.contains($0) }) })
        registerForDraggedTypes([.fileURL])
        dropHighlight.isHidden = true; dropHighlight.autoresizingMask = [.width, .height]; dropHighlight.frame = bounds
        addSubview(dropHighlight)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); table.columnSizing.fit(table); table.marquee?.layout() }
    private func openFolderDropTarget(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard available, cache.snapshot?.state == .complete,
              scroll.contentView.convert(scroll.contentView.bounds, to: self).contains(point) else { return false }
        let row = table.row(at: table.convert(sender.draggingLocation, from: nil))
        if row >= 0 {
            guard let observed = cached(row), observed.entry.isDirectory != true else { return false }
        }
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard openFolderDropTarget(sender), let count = onDropPreview?(sender) else { dropHighlight.isHidden = true; return [] }
        dropHighlight.caption = "Upload \(count) \(count == 1 ? "item" : "items") into this folder"
        dropHighlight.isHidden = false; return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { openFolderDropTarget(sender) && onDropPreview?(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        guard openFolderDropTarget(sender) else { return false }; return onDropFiles?(sender) ?? false
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight.isHidden = true }
    func showUploadOutcome(_ text: String) {
        let entering = outcomeRow.isHidden && !text.isEmpty
        outcome.stringValue = text; outcomeRow.isHidden = text.isEmpty
        if entering { ToolContentMotion.reveal(outcomeRow) }
    }
    #if DEBUG
    var outcomeVisibleForVerification: Bool { !outcomeRow.isHidden && outcomeRow.bounds.height >= 18 }
    var recoveryVisibleForVerification: Bool { retryAllowed && !recoveryActions.isHidden }
    #endif
    private func updateCapabilityLabel() {
        capabilityItem?.title = onNewFolder == nil ? "Existing names are preserved · no remote Trash" : "Server deletion is permanent · no remote Undo"
        outcomeButton.title = onNewFolder == nil ? "Upload Outcomes…" : "Connection Activity…"
        var capabilities = "SFTP directory. Browse folders and file information."
        if onUploadFolder != nil {
            capabilities += " Upload new files and folders; existing names are preserved."
        } else if onUpload != nil {
            capabilities += " Upload new files; existing names are preserved."
        }
        if folderDownloadsAvailable {
            capabilities += " Download selected files or review a folder before downloading."
        } else if onDownload != nil {
            capabilities += " Download selected files."
        }
        if onEditText != nil { capabilities += " Open supported text files in Traverse; Save checks for server changes." }
        if onViewText != nil { capabilities += " View a read-only snapshot of supported text." }
        if onServerCopy != nil { capabilities += " Copy or duplicate one file within this server; existing names are kept." }
        if onMove != nil {
            capabilities += " Move a \(allowsDirectoryMove ? "file or folder" : "file") to another server folder after checking the destination; concurrent server changes can affect the result."
        }
        if onNewFolder != nil {
            let rename = allowsDirectoryRename ? "a file or folder" : "a file"
            capabilities += allowsEmptyDirectoryDelete
                ? " Create a folder, rename \(rename), or permanently delete a file or empty folder after confirmation."
                : " Create a folder, rename \(rename), or permanently delete a file after confirmation."
        }
        capabilities += " Remote Trash and Undo are unavailable."
        table.setAccessibilityLabel(capabilities)
    }
    func configure(glass: Bool, motion: Bool, mode: BrowserMotionMode) {
        if let header = table.headerView as? FileTableHeaderView { header.usesGlass = glass; header.motionEnabled = motion; header.motionMode = mode }
        table.backgroundColor = glass ? .clear : .controlBackgroundColor; table.usesAlternatingRowBackgroundColors = !glass
        scroll.drawsBackground = !glass; scroll.contentView.drawsBackground = !glass; scroll.backgroundColor = .controlBackgroundColor
    }
    func loading() { dropHighlight.isHidden = true; available = true; paused = false; retryAllowed = false; recoveryActions.isHidden = true; cache.clear(); selectedIDs = []; reload(); message.stringValue = "Loading folder…"; message.isHidden = false }
    func disconnected(_ text: String, retainingObservedRows: Bool = false) {
        dropHighlight.isHidden = true
        available = false; retryAllowed = false; recoveryActions.isHidden = true; if !retainingObservedRows { cache.clear() }; table.reloadData(); message.stringValue = text; message.isHidden = retainingObservedRows && (cache.snapshot?.count ?? 0) > 0
    }
    func directoryRejected(_ reason: SFTPDirectoryRejection, canGoUp: Bool) {
        dropHighlight.isHidden = true
        available = false; retryAllowed = true; paused = true; cache.clear(); selectedIDs = []; table.deselectAll(nil); table.reloadData()
        message.stringValue = switch reason {
        case .denied: "Your account can’t open this folder. Try Home or another folder."
        case .missing: "This folder could not be found. Try Home or another folder."
        case .unavailable: "The server couldn’t open this folder. Try another folder or retry."
        }
        message.isHidden = false; upButton.isHidden = !canGoUp; homeButton.isEnabled = onHome != nil
        recoveryActions.isHidden = false
    }
    func directoryChanged(confirmedRename: Bool, canGoUp: Bool) {
        directoryRejected(.missing, canGoUp: canGoUp)
        message.stringValue = confirmedRename
            ? "This folder moved or changed name. Go Up or choose Home, or refresh to check this location again."
            : "This server folder may have changed. Choose Home or refresh before continuing."
    }
    func observe(_ update: SFTPBrowserUpdate) {
        guard let generation = update.generation, let snapshot = update.snapshot else { return }
        let changed = cache.generation != generation || cache.snapshot != snapshot
        guard cache.observe(generation, snapshot: snapshot) else { return }; paused = update.paused; available = update.failure == nil
        if changed { selectedIDs = []; findRequest = try? .init(text: findQuery); findFailure = false }
        retryAllowed = false; recoveryActions.isHidden = true
        reload(); message.isHidden = snapshot.count > 0
        message.stringValue = update.failure != nil ? "Connection unavailable. Connect again explicitly." : paused ? "Reading paused · observed items only" : snapshot.state == .loading ? "Reading directory metadata…" : "This folder is empty"
        updateFindNotice(); requestVisiblePage()
    }
    func accept(_ page: SFTPStoredPage, sort: SFTPStoredSort, descending: Bool) throws {
        guard cache.observe(page.generation, snapshot: page.snapshot) else { throw SFTPBrowserFailure.stale }
        try cache.accept(page, sort: sort, descending: descending); lastPageSort = sort; lastPageDescending = descending; reload(); requestVisiblePage()
    }
    func invalidatePages() {
        let id = cache.generation, snapshot = cache.snapshot; cache.clear()
        if let id, let snapshot { cache.observe(id, snapshot: snapshot) }
        findRequest = try? .init(text: findQuery); findFailure = false; selectedIDs = []; reload()
    }
    /// Repaint cached rows only. No catalog page or file body is requested.
    func refreshOpeningPresentation() {
        let offsets = loadedRows
        guard !offsets.isEmpty, let name = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
        table.reloadData(forRowIndexes: offsets, columnIndexes: IndexSet(integer: name))
    }
    private func reload() {
        updating = true; defer { updating = false }
        table.reloadData()
        let keep = IndexSet(loadedRows.filter { cached($0).map { selectedIDs.contains($0.observation) } == true })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        selectedIDs = Set(keep.compactMap { cached($0)?.observation })
        updateFindNotice()
    }
    private func updateFindNotice() {
        guard available else { return }
        guard !findQuery.isEmpty else {
            message.isHidden = (cache.snapshot?.count ?? 0) > 0
            if !message.isHidden { message.stringValue = cache.snapshot?.state == .complete ? "This folder is empty" : "Reading directory metadata…" }
            return
        }
        message.stringValue = findStatusText ?? "Waiting for directory metadata…"
        if cache.find?.count == 0, cache.find?.query == findRequest {
            message.stringValue = cache.snapshot?.state == .complete ? "No matching names in this folder" : "No matches among \(cache.snapshot?.count.formatted() ?? "0") observed names · Listing is incomplete"
        }
        message.isHidden = cache.find?.query == findRequest && (cache.find?.count ?? 0) > 0
            && (!findFailure || cache.retainedCount > 0)
    }
    func requestVisiblePage() {
        guard available, cache.snapshot != nil, !findFailure else { return }
        if !findQuery.isEmpty, cache.find?.query != findRequest { onPage?(0); return }
        // Demand at most the two intersecting pages that fit this view's
        // existing 512-observation cache. A cached leading row does not imply
        // the rest of the viewport is loaded. One request is emitted per turn.
        let count = table.numberOfRows
        guard count > 0 else { return }
        let range = table.rows(in: table.visibleRect)
        let first = range.location == NSNotFound ? 0 : min(count - 1, max(0, range.location))
        let length = range.location == NSNotFound ? 1 : max(1, min(512, range.length))
        let last = first + min(length - 1, count - first - 1)
        let page = first / 256 * 256
        var offsets = [page]
        if last / 256 > first / 256 { offsets.append(page + 256) }
        for offset in offsets {
            if cached(offset) == nil { onPage?(UInt64(offset)); return }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if !findQuery.isEmpty, cache.find?.query != findRequest { return 0 }
        return Int(min(UInt64(Int.max), cache.displayCount))
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let key = column?.identifier.rawValue else { return nil }
        let text: String
        let entry = cached(row)?.entry
        if let value = entry {
            switch key {
            case "name": text = value.name.displayName
            case "kind":
                if value.isDirectory == true { text = "Folder" }
                else if let permissions = value.permissions {
                    text = permissions & 0o170000 == 0o120000 ? "Link · unavailable"
                        : FileKindText.string(name: value.name.displayName,
                            kind: permissions & 0o170000 == 0o100000 ? "file" : "other")
                } else { text = "Unknown item" }
            case "size":
                text = value.isDirectory == true ? "—" : value.logicalBytes.map(FileSizeText.unsigned) ?? "—"
            case "modified": text = value.modifiedSeconds.map { Date(timeIntervalSince1970: Double($0)).formatted(date: .abbreviated, time: .shortened) } ?? "—"
            default: return nil
            }
        } else { text = key == "name" ? "…" : "" }
        let role = key == "name" ? entry.map { value in
            let kind = value.isDirectory == true ? "directory"
                : value.permissions.map { $0 & 0o170000 == 0o120000 ? "symbolicLink"
                    : $0 & 0o170000 == 0o100000 ? "file" : "other" } ?? "other"
            return FileIconRole.classify(name: value.name.displayName, kind: kind)
        } : nil
        let opening = key == "name" && available
            ? entry.flatMap { openingAppearanceForEntry?($0) } ?? .ordinary : .ordinary
        return FileTableCell.remote(in: tableView, column: key, text: text, role: role, opening: opening,
            cut: key == "name" && entry.flatMap { cutAppearanceForEntry?($0) } == true)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating { selectionRevision = UUID(); selectedIDs = Set(table.selectedRowIndexes.compactMap { cached($0)?.observation }); onSelectionChanged?() }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        selectionRevision = UUID()
        tableView.headerView?.needsDisplay = true
        guard let value = tableView.sortDescriptors.first else { return }
        let sort: SFTPStoredSort
        switch value.key { case "name": sort = .name; case "size": sort = .size; case "modified": sort = .modified; default: return }
        onSort?(sort, !value.ascending)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === table else { return nil }; return onPromiseWriter?(row)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard tableView === table else { return }; onPromiseDidBegin?(session, rowIndexes)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard tableView === table else { return }; onPromiseDidEnd?(session, operation)
    }
    @objc private func openSelected(_ sender: Any?) {
        guard !(sender is NSTableView && table.clickedRow < 0), canOpenSelectedItem,
              let row = cached(table.selectedRow) else { return }
        if row.entry.isDirectory == true { onOpen?(row) }
        else if nativeOpenAllowed?() == true {
            if let onNativeTextOpen { onNativeTextOpen() } else { editText(nil) }
        }
    }
    @objc private func editText(_ sender: Any?) {
        guard canEditSelectedText else { return }
        onEditText?()
    }
    @objc private func viewText(_ sender: Any?) {
        guard canViewSelectedText else { return }; onViewText?()
    }
    @objc private func refresh(_ sender: Any?) { onRefresh?() }
    @objc private func goHome(_ sender: Any?) { if retryAllowed { onHome?() } }
    @objc private func goUp(_ sender: Any?) { if retryAllowed && !upButton.isHidden { onUp?() } }
    @objc private func retryFolder(_ sender: Any?) { if retryAllowed { onRefresh?() } }
    @objc private func stop(_ sender: Any?) { onStop?() }
    @objc private func disconnect(_ sender: Any?) { onDisconnect?() }
    @objc private func download(_ sender: Any?) { if selectedDownload != nil || selectedDownloadBatch != nil || folderDownloadsAvailable && selectedFolderDownload != nil { onDownload?() } }
    @objc private func downloadToPane(_ sender: Any?) { if selectedDownload != nil || selectedDownloadBatch != nil || folderDownloadsAvailable && selectedFolderDownload != nil { onDownloadToPane?() } }
    @objc private func upload(_ sender: Any?) { if uploadAllowed?() == true { onUpload?() } }
    @objc private func uploadFolder(_ sender: Any?) { if folderUploadAllowed?() == true { onUploadFolder?() } }
    @objc private func uploadHistory(_ sender: Any?) { onUploadHistory?() }
    @objc private func pasteFiles(_ sender: Any?) { if pasteAllowed?() == true { onPaste?() } }
    @objc private func newFile(_ sender: Any?) { if newFileAllowed?() == true { onNewFile?() } }
    @objc private func newFolder(_ sender: Any?) { if newFolderAllowed?() == true { onNewFolder?() } }
    @objc private func rename(_ sender: Any?) { if renameAllowed?() == true { onRename?() } }
    @objc private func copyOnServer(_ sender: Any?) { if serverCopyAllowed?() == true { onServerCopy?() } }
    @objc private func duplicateOnServer(_ sender: Any?) { if serverCopyAllowed?() == true { onDuplicate?() } }
    @objc private func move(_ sender: Any?) { if moveAllowed?() == true { onMove?() } }
    @objc private func deletePermanently(_ sender: Any?) { if deleteAllowed?() == true { onDeletePermanently?() } }
    @objc private func actionHistory(_ sender: Any?) { onActionHistory?() }
    @objc private func properties(_ sender: Any?) { if canInspect?() == true { onProperties?() } }
    @objc private func copyFile(_ sender: Any?) { if copyFileAllowed?() == true { onCopyFile?() } }
    @objc private func cutFile(_ sender: Any?) { if cutAllowed?() == true { onCut?() } }
    @objc private func copyName(_ sender: Any?) { if canCopyName?() == true { onCopyName?() } }
    @objc private func copyPath(_ sender: Any?) { if canCopyPath?() == true { onCopyPath?() } }
    private func contextMenu() -> NSMenu {
        let groups: [[Selector]] = table.numberOfSelectedRows > 0 ? [
            [#selector(openSelected(_:)), #selector(viewText(_:)), #selector(editText(_:))],
            [#selector(download(_:)), #selector(downloadToPane(_:))],
            [#selector(rename(_:)), #selector(duplicateOnServer(_:)), #selector(copyOnServer(_:)), #selector(move(_:)), #selector(deletePermanently(_:))],
            [#selector(cutFile(_:)), #selector(copyFile(_:)), #selector(copyPath(_:)), #selector(copyName(_:))],
            [#selector(properties(_:))]
        ] : [
            [#selector(newFolder(_:)), #selector(newFile(_:))],
            [#selector(pasteFiles(_:)), #selector(upload(_:)), #selector(uploadFolder(_:))],
            [#selector(refresh(_:)), #selector(stop(_:))],
            [#selector(uploadHistory(_:))]
        ]
        return NativeContextMenu.arrange(table.menu, groups: groups, allows: validateMenuItem,
            alwaysShow: [#selector(pasteFiles(_:))])
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(rename(_:)) { item.toolTip = renameExplanation?() ?? renameToolTip }
        if item.action == #selector(move(_:)) {
            item.toolTip = moveExplanation?() ?? moveToolTip
        }
        return switch item.action {
        case #selector(properties(_:)): onProperties != nil && canInspect?() == true
        case #selector(copyFile(_:)): onCopyFile != nil && copyFileAllowed?() == true
        case #selector(cutFile(_:)): onCut != nil && cutAllowed?() == true
        case #selector(copyName(_:)): onCopyName != nil && canCopyName?() == true
        case #selector(copyPath(_:)): onCopyPath != nil && canCopyPath?() == true
        case #selector(editText(_:)): canEditSelectedText
        case #selector(viewText(_:)): canViewSelectedText
        case #selector(openSelected(_:)): canOpenSelectedItem
        case #selector(refresh(_:)): (available || retryAllowed) && onRefresh != nil
        case #selector(stop(_:)): available && !paused && cache.snapshot?.state == .loading && onStop != nil
        case #selector(disconnect(_:)): onDisconnect != nil
        case #selector(download(_:)): onDownload != nil && (selectedDownload != nil || selectedDownloadBatch != nil || folderDownloadsAvailable && selectedFolderDownload != nil) && downloadAllowed?() != false
        case #selector(downloadToPane(_:)): onDownloadToPane != nil && (selectedDownload != nil || selectedDownloadBatch != nil || folderDownloadsAvailable && selectedFolderDownload != nil) && paneDownloadAllowed?() != false
        case #selector(upload(_:)): onUpload != nil && uploadAllowed?() == true
        case #selector(uploadFolder(_:)): onUploadFolder != nil && folderUploadAllowed?() == true
        case #selector(uploadHistory(_:)): onUploadHistory != nil
        case #selector(pasteFiles(_:)): onPaste != nil && pasteAllowed?() == true
        case #selector(newFile(_:)): onNewFile != nil && newFileAllowed?() == true
        case #selector(newFolder(_:)): onNewFolder != nil && newFolderAllowed?() == true
        case #selector(rename(_:)): onRename != nil && renameAllowed?() == true
        case #selector(copyOnServer(_:)): onServerCopy != nil && serverCopyAllowed?() == true
        case #selector(duplicateOnServer(_:)): onDuplicate != nil && serverCopyAllowed?() == true
        case #selector(move(_:)): onMove != nil && moveAllowed?() == true
        case #selector(deletePermanently(_:)): onDeletePermanently != nil && deleteAllowed?() == true
        case #selector(actionHistory(_:)): onActionHistory != nil
        default: false
        }
    }
    private var moveToolTip: String {
        "Move this item after checking its destination. Concurrent server changes can affect the result; remote Undo is unavailable."
    }
}
