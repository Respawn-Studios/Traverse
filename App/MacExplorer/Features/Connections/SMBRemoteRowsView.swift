import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Remote observations have their own native surface and selection. There is
/// no local URL or direct local mutation. Internal drags retain the explicit
/// download's observed selection, destination and publication owner.
@MainActor final class SMBRemoteRowsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let table = RemoteFileTableView(), scroll = NSScrollView()
    let message = NSTextField(wrappingLabelWithString: "Connecting…")
    private let recoveryActions = NSStackView()
    private let homeButton = NSButton(title: "Share Root", target: nil, action: nil)
    private let upButton = NSButton(title: "Up", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var rejected = false
    private(set) var cache = SMBDirectoryPageCache()
    private(set) var lastPageSort: SMBDirectorySort?, lastPageDescending: Bool?
    var onPage: ((Int64) -> Void)?, onOpen: ((SMBDirectoryObservation) -> Void)?
    var onSort: ((SMBDirectorySort, Bool) -> Void)?, onRefresh: (() -> Void)?, onStop: (() -> Void)?
    var onBack: (() -> Void)?, onUp: (() -> Void)?
    var onHome: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onProperties: (() -> Void)?, onCopyName: (() -> Void)?, onCopyPath: (() -> Void)?
    var onViewText: (() -> Void)? { didSet { viewTextMenu?.isHidden = onViewText == nil } }
    var onEditText: (() -> Void)? { didSet { editTextMenu?.isHidden = onEditText == nil } }
    var editTextAllowed: (() -> Bool)?, onNativeTextOpen: (() -> Void)?
    var viewTextAllowed: (() -> Bool)?, nativeOpenAllowed: (() -> Bool)?
    var openingAppearanceForEntry: ((SMBDirectoryObservation) -> FileOpeningAppearance)?
    private var viewTextMenu: NSMenuItem?
    private var editTextMenu: NSMenuItem?
    var onRename: (() -> Void)? { didSet { updateCapabilities() } }
    var onMove: (() -> Void)? { didSet { updateCapabilities() } }
    var onCopy: (() -> Void)? { didSet { updateCapabilities() } }
    var onDuplicate: (() -> Void)? { didSet { updateCapabilities() } }
    var copyAllowed: (() -> Bool)?
    var onDelete: (() -> Void)? { didSet { updateCapabilities() } }
    var fileActionsAllowed: (() -> Bool)?
    var canInspect: (() -> Bool)?, canCopyName: (() -> Bool)?, canCopyPath: (() -> Bool)?
    var onCut: (() -> Void)? { didSet { cutMenu?.isHidden = onCut == nil; updateCapabilities() } }
    var onCopyFile: (() -> Void)? { didSet { clipboardCopyMenu?.isHidden = onCopyFile == nil; updateCapabilities() } }
    var copyFileAllowed: (() -> Bool)?
    private var clipboardCopyMenu: NSMenuItem?
    var cutAllowed: (() -> Bool)?, cutAppearanceForEntry: ((SMBDirectoryObservation) -> Bool)?
    private var cutMenu: NSMenuItem?
    var onDownload: (() -> Void)?, onDownloadToPane: (() -> Void)?
    var onDownloadDragWriter: ((Int) -> (any NSPasteboardWriting)?)? { didSet {
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setDraggingSourceOperationMask(onDownloadDragWriter != nil && RemoteDownloadDrag.smbAvailable ? .copy : [], forLocal: true)
    } }
    var onDownloadDragBegan: ((NSDraggingSession, IndexSet) -> Void)?
    var onDownloadDragEnded: ((NSDraggingSession) -> Void)?
    var downloadAllowed: (() -> Bool)?, paneDownloadAllowed: (() -> Bool)?
    var onUpload: (() -> Void)?, onUploadHistory: (() -> Void)?, uploadAllowed: (() -> Bool)?
    var onNewFile: (() -> Void)? { didSet { updateCapabilities() } }
    var onNewFolder: (() -> Void)? { didSet { updateCapabilities() } }
    var newFileAllowed: (() -> Bool)?, newFolderAllowed: (() -> Bool)?
    var onDropPreview: ((NSDraggingInfo) -> Bool)?, onDropFiles: ((NSDraggingInfo) -> Bool)?
    var onPaste: (() -> Void)? { didSet { updateCapabilities() } }
    var pasteAllowed: (() -> Bool)?
    private let dropHighlight = RemoteUploadDropHighlightView(frame: .zero)
    private var pasteMenu: NSMenuItem?
    private var uploadMenu: NSMenuItem?, uploadHistoryMenu: NSMenuItem?
    private var newFileMenu: NSMenuItem?, newFolderMenu: NSMenuItem?
    private var renameMenu: NSMenuItem?, moveMenu: NSMenuItem?, deleteMenu: NSMenuItem?
    private var copyMenu: NSMenuItem?, duplicateMenu: NSMenuItem?
    private var downloadMenu: NSMenuItem?, downloadPaneMenu: NSMenuItem?, unavailableMenu: NSMenuItem?
    var downloadsAvailable = false {
        didSet {
            downloadMenu?.isHidden = !downloadsAvailable; downloadPaneMenu?.isHidden = !downloadsAvailable
            updateCapabilities()
        }
    }
    var uploadsAvailable = false { didSet { updateCapabilities() } }
    var folderUploadsAvailable = false { didSet { updateCapabilities() } }
    private func updateCapabilities() {
        uploadMenu?.isHidden = !uploadsAvailable; uploadHistoryMenu?.isHidden = !uploadsAvailable
        uploadMenu?.title = folderUploadsAvailable ? "Upload Here…" : "Upload Files Here…"
        pasteMenu?.isHidden = onPaste == nil || (!uploadsAvailable && onCut == nil && onCopyFile == nil)
        newFileMenu?.isHidden = !uploadsAvailable || onNewFile == nil
        newFolderMenu?.isHidden = !folderUploadsAvailable || onNewFolder == nil
        let items = folderUploadsAvailable ? "files or folders" : "files"
        let actions = onRename != nil && onDelete != nil
        renameMenu?.isHidden = !actions; deleteMenu?.isHidden = !actions
        moveMenu?.isHidden = onMove == nil
        copyMenu?.isHidden = onCopy == nil; duplicateMenu?.isHidden = onDuplicate == nil
        copyMenu?.toolTip = "Copy one file up to " + FileSizeText.string(Int64(clamping: SMBSelectedActionRequest.maximumCopyBytes))
            + " within this server. The original is kept; existing names are never replaced."
        unavailableMenu?.title = actions ? "Delete is permanent · no remote Trash"
            : uploadsAvailable ? "New uploads · Existing names are kept"
            : downloadsAvailable ? "Remote files stay unchanged · Download selected files" : "Read-only browsing · file actions are unavailable"
        table.setAccessibilityLabel(uploadsAvailable ? "SMB directory. Browse folders or upload new \(items)."
            + (onPaste == nil ? "" : " Paste copied local \(items) or drop them into the empty area of this folder.")
            + (downloadsAvailable ? " Selected files can be downloaded." : "")
            + (actions ? " Eligible selected items can be renamed. Files and empty folders can be permanently deleted." : "")
            : downloadsAvailable ? "SMB directory. Folders can be opened; selected files can be downloaded."
            : "SMB directory, read only. Folders can be opened; file contents are unavailable.")
    }
    var selectedObservation: SMBDirectoryObservation? { table.numberOfSelectedRows == 1 ? cached(table.selectedRow) : nil }
    /// Positive knowledge only: a paged cache cannot establish that a name is
    /// absent. Preserve exact server spelling rather than String equivalence.
    func hasLoadedName(_ name: SMBRemoteName, in snapshot: SMBDirectorySnapshot) -> Bool {
        guard snapshot.state == .complete, cache.snapshot == snapshot else { return false }
        return cache.loadedEntries.contains { $0.row.name.wireUTF16 == name.wireUTF16 }
    }
    func suggestedNewName(_ original: String, in snapshot: SMBDirectorySnapshot) -> String {
        FilenamePrompt.suggestedName(original) { candidate in
            guard let name = try? SMBRemoteName(candidate) else { return true }
            return hasLoadedName(name, in: snapshot)
        }
    }
    func selectedDownloadBatch(connection: UUID) -> SMBDownloadBatchPlan? {
        guard downloadsAvailable, (2...16).contains(table.numberOfSelectedRows),
              let snapshot = cache.snapshot, snapshot.state == .complete else { return nil }
        let observations = table.selectedRowIndexes.compactMap(cached)
        guard observations.count == table.numberOfSelectedRows else { return nil }
        return try? .init(connection: connection, snapshot: snapshot,
                         selections: observations.map { try .init(connection: connection, snapshot: snapshot, observation: $0) })
    }
    var canOpenSelectedFolder: Bool {
        guard table.numberOfSelectedRows == 1, let item = cached(table.selectedRow) else { return false }
        return item.isDirectory && !item.isReparsePoint
    }
    func openSelectedFolder() { openSelected(nil) }
    private var scrollObservation: BrowserNotificationObservation?
    private var selectedIDs: Set<Int64> = [], updating = false
    private(set) var findQuery = ""
    private(set) var findRequest: RemoteDirectoryFindQuery?
    private(set) var selectionRevision = UUID()
    private var findFailure = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (key, title, width) in [("name", "Name", 350.0), ("modified", "Date Modified", 170.0), ("kind", "Kind", 100.0), ("size", "Size", 110.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width
            if key != "kind" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.headerView = FileTableHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
        table.dataSource = self; table.delegate = self; InterfaceMetrics.setRowHeight(table, base: 25); table.allowsMultipleSelection = true
        table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(openSelected(_:))
        table.onOpen = { [weak self] in self?.openSelected(nil) }
        table.onBack = { [weak self] in self?.onBack?() }; table.onUp = { [weak self] in self?.onUp?() }
        table.setAccessibilityLabel("SMB directory. Open folders, inspect items and use available file actions.")
        let menu = NSMenu(); menu.addItem(withTitle: "Open", action: #selector(openSelected(_:)), keyEquivalent: "").target = self
        viewTextMenu = menu.addItem(withTitle: "View in Traverse", action: #selector(viewText(_:)), keyEquivalent: "")
        viewTextMenu?.target = self; viewTextMenu?.isHidden = true
        editTextMenu = menu.addItem(withTitle: "Edit in Traverse", action: #selector(editText(_:)), keyEquivalent: "")
        editTextMenu?.target = self; editTextMenu?.isHidden = true
        downloadMenu = menu.addItem(withTitle: "Download…", action: #selector(download(_:)), keyEquivalent: "")
        downloadPaneMenu = menu.addItem(withTitle: "Download to Other Pane…", action: #selector(downloadToPane(_:)), keyEquivalent: "")
        for item in [downloadMenu, downloadPaneMenu] { item?.target = self; item?.isHidden = true }
        uploadMenu = menu.addItem(withTitle: SMBUploadFeature.commandTitle, action: #selector(upload(_:)), keyEquivalent: "")
        uploadHistoryMenu = menu.addItem(withTitle: "Upload Outcomes…", action: #selector(uploadHistory(_:)), keyEquivalent: "")
        newFolderMenu = menu.addItem(withTitle: "New Folder…", action: #selector(newFolder(_:)), keyEquivalent: "")
        newFileMenu = menu.addItem(withTitle: FilenamePrompt.newFileTitle + "…", action: #selector(newFile(_:)), keyEquivalent: "")
        for item in [newFolderMenu, newFileMenu] { item?.target = self; item?.isHidden = true }
        pasteMenu = menu.addItem(withTitle: "Paste", action: #selector(pasteFile(_:)), keyEquivalent: "")
        pasteMenu?.target = self; pasteMenu?.isHidden = true
        for item in [uploadMenu, uploadHistoryMenu] { item?.target = self; item?.isHidden = true }
        menu.addItem(withTitle:"Properties…",action:#selector(properties(_:)),keyEquivalent:"").target = self
        clipboardCopyMenu = menu.addItem(withTitle: "Copy", action: #selector(copyFile(_:)), keyEquivalent: "")
        clipboardCopyMenu?.target = self; clipboardCopyMenu?.isHidden = true
        clipboardCopyMenu?.toolTip = "Copy this file, then paste into a folder on this connection."
        menu.addItem(withTitle:"Copy Name",action:#selector(copyName(_:)),keyEquivalent:"").target = self
        menu.addItem(withTitle:"Copy Path in Share",action:#selector(copyPath(_:)),keyEquivalent:"").target = self
        cutMenu = menu.addItem(withTitle: "Cut", action: #selector(cutFile(_:)), keyEquivalent: "")
        cutMenu?.target = self; cutMenu?.isHidden = true
        renameMenu = menu.addItem(withTitle: "Rename…", action: #selector(rename(_:)), keyEquivalent: "")
        moveMenu = menu.addItem(withTitle: "Move To…", action: #selector(moveItem(_:)), keyEquivalent: "")
        copyMenu = menu.addItem(withTitle: "Copy To…", action: #selector(copyItem(_:)), keyEquivalent: "")
        duplicateMenu = menu.addItem(withTitle: "Duplicate", action: #selector(duplicateItem(_:)), keyEquivalent: "")
        deleteMenu = menu.addItem(withTitle: "Delete Permanently…", action: #selector(deleteFile(_:)), keyEquivalent: "")
        for item in [renameMenu, moveMenu, copyMenu, duplicateMenu, deleteMenu] { item?.target = self; item?.isHidden = true }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop Reading", action: #selector(stop(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Disconnect This Tab", action: #selector(disconnect(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let info = menu.addItem(withTitle: "Read-only browsing · file actions are unavailable", action: nil, keyEquivalent: ""); info.isEnabled = false
        unavailableMenu = info
        table.menu = menu
        table.contextMenuProvider = { [weak self] in self?.contextMenu() }
        registerForDraggedTypes([.fileURL])
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        dropHighlight.isHidden = true; dropHighlight.autoresizingMask = [.width, .height]; dropHighlight.frame = bounds
        addSubview(dropHighlight)
        table.marquee = TableMarqueeSelection(table: table, scroll: scroll, parent: self,
            revision: { [weak table] in table?.marqueeRevision ?? 0 },
            pointerBehavior: { [weak table] in table?.behavior ?? .mac }, eligibleRows: { [weak self] proposed in
                guard let self, !self.rejected else { return [] }; return IndexSet(self.loadedRows.filter { proposed.contains($0) }) })
        message.textColor = .secondaryLabelColor; message.alignment = .center; message.maximumNumberOfLines = 4
        message.translatesAutoresizingMaskIntoConstraints = false; addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: centerXAnchor), message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
        for (button, action, identifier) in [(homeButton, #selector(goHome(_:)), "smb-recovery-home"),
            (upButton, #selector(recoveryUp(_:)), "smb-recovery-up"), (retryButton, #selector(retry(_:)), "smb-recovery-retry")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.setAccessibilityIdentifier(identifier); recoveryActions.addArrangedSubview(button)
        }
        homeButton.toolTip = "Open the root folder of this share using the current connection."
        recoveryActions.orientation = .horizontal; recoveryActions.spacing = 8; recoveryActions.isHidden = true
        recoveryActions.translatesAutoresizingMaskIntoConstraints = false; addSubview(recoveryActions)
        NSLayoutConstraint.activate([recoveryActions.centerXAnchor.constraint(equalTo: centerXAnchor),
            recoveryActions.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 14)])
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObservation = BrowserNotificationObservation(name: NSView.boundsDidChangeNotification, object: scroll.contentView) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestVisiblePage() }
        }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); table.columnSizing.fit(table); table.marquee?.layout() }
    private func cached(_ row: Int) -> SMBDirectoryObservation? {
        guard row >= 0 else { return nil }
        if !findQuery.isEmpty, cache.find?.query != findRequest { return nil }
        return cache.entry(at: Int64(row))
    }
    private var loadedRows: IndexSet {
        if !findQuery.isEmpty, cache.find?.query != findRequest { return [] }
        return IndexSet(cache.loadedEntries.compactMap { Int(exactly: $0.offset) })
    }
    func selectAllLoaded() { table.selectRowIndexes(loadedRows, byExtendingSelection: false) }
    func setFindQuery(_ value: String) {
        guard !findQuery.utf8.elementsEqual(value.utf8), value.isEmpty || (try? RemoteDirectoryFindQuery(text: value)) != nil else { return }
        selectionRevision = UUID()
        findQuery = value; invalidatePages(); requestVisiblePage()
    }
    func acceptFind(_ result: SMBDirectoryFindResult) throws {
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
        let state = snapshot.state == .loading ? "Reading…" : snapshot.state == .stopped ? "Stopped" : "Partial listing"
        return matches + " among \(snapshot.count.formatted()) observed · " + state
    }
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        rejected ? [] : IndexSet(loadedRows.filter { proposed.contains($0) })
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rejected && cached(row) != nil }
    func configure(glass: Bool, motion: Bool, mode: BrowserMotionMode = .full) {
        (table.headerView as? FileTableHeaderView)?.usesGlass = glass
        (table.headerView as? FileTableHeaderView)?.motionEnabled = motion
        (table.headerView as? FileTableHeaderView)?.motionMode = mode
        table.backgroundColor = glass ? .clear : .controlBackgroundColor
        table.usesAlternatingRowBackgroundColors = !glass
        scroll.drawsBackground = !glass; scroll.contentView.drawsBackground = !glass
        scroll.backgroundColor = .controlBackgroundColor
    }
    func loading() { dropHighlight.isHidden = true; rejected = false; recoveryActions.isHidden = true; cache.clear(); selectedIDs = []; reload(); message.stringValue = "Reading directory metadata…"; message.isHidden = false }
    func disconnected(_ text: String) { dropHighlight.isHidden = true; rejected = false; recoveryActions.isHidden = true; cache.clear(); table.reloadData(); message.stringValue = text; message.isHidden = false }
    func directoryRejected(_ reason: SMBDirectoryRejection, canGoUp: Bool, canGoHome: Bool) {
        dropHighlight.isHidden = true; rejected = true; cache.clear(); selectedIDs = []; table.deselectAll(nil); table.reloadData()
        message.stringValue = switch reason {
        case .denied: "Your account can’t open this folder. Try another folder or retry."
        case .missing: "This folder could not be found. Try another folder or retry."
        case .unavailable: "The server couldn’t open this folder. Try another folder or retry."
        }
        message.isHidden = false; upButton.isHidden = !canGoUp; homeButton.isHidden = !canGoHome
        recoveryActions.isHidden = false
    }
    #if DEBUG
    var recoveryVisibleForVerification: Bool { rejected && !recoveryActions.isHidden }
    #endif
    func observe(_ snapshot: SMBDirectorySnapshot) {
        rejected = false; recoveryActions.isHidden = true
        if cache.snapshot != snapshot { selectedIDs = []; findRequest = try? .init(text: findQuery); findFailure = false }
        cache.observe(snapshot); reload()
        message.isHidden = snapshot.count > 0
        message.stringValue = snapshot.state == .loading ? "Reading directory metadata…" : snapshot.state == .complete ? "This folder is empty" : "Reading stopped · observed items only"
        updateFindNotice(); requestVisiblePage()
    }
    func accept(_ page: SMBDirectoryPage) throws {
        try cache.accept(page); lastPageSort = page.request.sort; lastPageDescending = page.request.descending; reload(); requestVisiblePage()
    }
    func invalidatePages() {
        let snapshot = cache.snapshot; cache.clear(); if let snapshot { cache.observe(snapshot) }
        findRequest = try? .init(text: findQuery); findFailure = false; selectedIDs = []; reload()
    }
    private func reload() {
        updating = true; defer { updating = false }
        table.reloadData()
        let keep = IndexSet(loadedRows.filter { cached($0).map { selectedIDs.contains($0.id) } == true })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        selectedIDs = Set(keep.compactMap { cached($0)?.id })
        updateFindNotice()
    }
    private func updateFindNotice() {
        guard !rejected else { return }
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
        guard !rejected, cache.snapshot != nil, !findFailure else { return }
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
            if cache.entry(at: Int64(offset)) == nil { onPage?(Int64(offset)); return }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if !findQuery.isEmpty, cache.find?.query != findRequest { return 0 }
        return Int(cache.displayCount)
    }
    @objc private func goHome(_ sender: Any?) { if rejected && !homeButton.isHidden { onHome?() } }
    @objc private func recoveryUp(_ sender: Any?) { if rejected && !upButton.isHidden { onUp?() } }
    @objc private func retry(_ sender: Any?) { if rejected { onRefresh?() } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        let item = cached(row)
        if let item {
            switch key {
            case "name": text = item.name.displayName
            case "kind": text = item.isReparsePoint ? "Link · unavailable"
                : FileKindText.string(name: item.name.displayName, kind: item.isDirectory ? "directory" : "file")
            case "size": text = item.isDirectory ? "—" : FileSizeText.unsigned(item.logicalBytes)
            case "modified":
                let seconds = Double(item.modifiedFileTime) / 10_000_000 - 11_644_473_600
                text = item.modifiedFileTime == 0 ? "—" : Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
            default: return nil
            }
        } else { text = key == "name" ? "…" : "" }
        let role = key == "name" ? item.map {
            $0.isReparsePoint ? FileIconRole.symbolicLink
                : FileIconRole.classify(name: $0.name.displayName, kind: $0.isDirectory ? "directory" : "file")
        } : nil
        let opening = key == "name" ? item.flatMap { openingAppearanceForEntry?($0) } ?? .ordinary : .ordinary
        return FileTableCell.remote(in: tableView, column: key, text: text, role: role, opening: opening,
            cut: key == "name" && item.flatMap { cutAppearanceForEntry?($0) } == true)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }; selectionRevision = UUID(); selectedIDs = Set(table.selectedRowIndexes.compactMap { cached($0)?.id })
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === table else { return nil }; return onDownloadDragWriter?(row)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard tableView === table else { return }; onDownloadDragBegan?(session, rowIndexes)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard tableView === table else { return }; onDownloadDragEnded?(session)
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        selectionRevision = UUID()
        tableView.headerView?.needsDisplay = true
        guard let value = tableView.sortDescriptors.first, let key = value.key, let sort = SMBDirectorySort(rawValue: key) else { return }
        onSort?(sort, !value.ascending)
    }
    @objc private func openSelected(_ sender: Any?) {
        if sender is NSTableView, table.clickedRow < 0 { return }
        guard table.numberOfSelectedRows == 1, table.selectedRow >= 0,
              let item = cached(table.selectedRow), !item.isReparsePoint else { return }
        if item.isDirectory { onOpen?(item) }
        else if nativeOpenAllowed?() == true {
            if let onNativeTextOpen { onNativeTextOpen() }
            else if editTextAllowed?() == true { onEditText?() }
            else if viewTextAllowed?() == true { onViewText?() }
        }
    }
    @objc private func editText(_ sender: Any?) { if editTextAllowed?() == true { onEditText?() } }
    @objc private func viewText(_ sender: Any?) { if viewTextAllowed?() == true { onViewText?() } }
    @objc private func refresh(_ sender: Any?) { onRefresh?() }
    @objc private func stop(_ sender: Any?) { onStop?() }
    @objc private func disconnect(_ sender: Any?) { onDisconnect?() }
    @objc private func properties(_ sender: Any?) { if canInspect?() == true { onProperties?() } }
    @objc private func download(_ sender: Any?) { if downloadsAvailable && downloadAllowed?() == true { onDownload?() } }
    @objc private func downloadToPane(_ sender: Any?) { if downloadsAvailable && paneDownloadAllowed?() == true { onDownloadToPane?() } }
    @objc private func copyName(_ sender: Any?) { if canCopyName?() == true { onCopyName?() } }
    @objc private func cutFile(_ sender: Any?) { if cutAllowed?() == true { onCut?() } }
    @objc private func copyPath(_ sender: Any?) { if canCopyPath?() == true { onCopyPath?() } }
    private func openFolderDropTarget(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let window, sender.draggingDestinationWindow === window, uploadsAvailable, !rejected,
              cache.snapshot?.state == .complete,
              scroll.contentView.convert(scroll.contentView.bounds, to: self).contains(point) else { return false }
        return table.row(at: table.convert(sender.draggingLocation, from: nil)) < 0
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard openFolderDropTarget(sender), onDropPreview?(sender) == true else { dropHighlight.isHidden = true; return [] }
        dropHighlight.caption = "Upload this file into the current folder"
        dropHighlight.isHidden = false
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        openFolderDropTarget(sender) && onDropPreview?(sender) == true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        guard openFolderDropTarget(sender), onDropPreview?(sender) == true else { return false }
        return onDropFiles?(sender) ?? false
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight.isHidden = true }
    @objc private func upload(_ sender: Any?) { if uploadsAvailable && uploadAllowed?() == true { onUpload?() } }
    @objc private func pasteFile(_ sender: Any?) { if pasteAllowed?() == true { onPaste?() } }
    @objc private func uploadHistory(_ sender: Any?) { onUploadHistory?() }
    @objc private func newFile(_ sender: Any?) { if uploadsAvailable && newFileAllowed?() == true { onNewFile?() } }
    @objc private func newFolder(_ sender: Any?) { if folderUploadsAvailable && newFolderAllowed?() == true { onNewFolder?() } }
    @objc private func rename(_ sender: Any?) { if fileActionsAllowed?() == true { onRename?() } }
    @objc private func moveItem(_ sender: Any?) { if fileActionsAllowed?() == true { onMove?() } }
    @objc private func copyFile(_ sender: Any?) { if copyFileAllowed?() == true { onCopyFile?() } }
    @objc private func copyItem(_ sender: Any?) { if copyAllowed?() == true { onCopy?() } }
    @objc private func duplicateItem(_ sender: Any?) { if copyAllowed?() == true { onDuplicate?() } }
    @objc private func deleteFile(_ sender: Any?) { if fileActionsAllowed?() == true { onDelete?() } }
    func inlineFilenameAnchor() -> (view: NSView, rect: NSRect, label: NSTextField)? {
        guard selectedObservation != nil else { return nil }
        return NativeFilenameAnchor.selected(in: table)
    }
    private func contextMenu() -> NSMenu {
        let groups: [[Selector]] = table.numberOfSelectedRows > 0 ? [
            [#selector(openSelected(_:)), #selector(editText(_:)), #selector(viewText(_:))],
            [#selector(download(_:)), #selector(downloadToPane(_:))],
            [#selector(cutFile(_:)), #selector(copyFile(_:)), #selector(copyPath(_:)), #selector(copyName(_:))],
            [#selector(duplicateItem(_:)), #selector(copyItem(_:)), #selector(rename(_:)), #selector(moveItem(_:)), #selector(deleteFile(_:))],
            [#selector(properties(_:))]
        ] : [
            [#selector(newFolder(_:)), #selector(newFile(_:))],
            [#selector(pasteFile(_:)), #selector(upload(_:))],
            [#selector(refresh(_:)), #selector(stop(_:))],
            [#selector(uploadHistory(_:))]
        ]
        var alwaysShow: Set<Selector> = [#selector(pasteFile(_:))]
        if onCopy != nil, selectedObservation?.isDirectory == false { alwaysShow.insert(#selector(copyItem(_:))) }
        return NativeContextMenu.arrange(table.menu, groups: groups, allows: validateMenuItem,
            alwaysShow: alwaysShow)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editText(_:)) { return onEditText != nil && editTextAllowed?() == true }
        if menuItem.action == #selector(viewText(_:)) { return onViewText != nil && viewTextAllowed?() == true }
        if menuItem.action == #selector(rename(_:)) { return onRename != nil && fileActionsAllowed?() == true }
        if menuItem.action == #selector(moveItem(_:)) { return onMove != nil && fileActionsAllowed?() == true }
        if menuItem.action == #selector(copyFile(_:)) { return onCopyFile != nil && copyFileAllowed?() == true }
        if menuItem.action == #selector(copyItem(_:)) { return onCopy != nil && copyAllowed?() == true }
        if menuItem.action == #selector(duplicateItem(_:)) { return onDuplicate != nil && copyAllowed?() == true }
        if menuItem.action == #selector(deleteFile(_:)) { return onDelete != nil && fileActionsAllowed?() == true }
        if menuItem.action == #selector(newFile(_:)) { return uploadsAvailable && onNewFile != nil && newFileAllowed?() == true }
        if menuItem.action == #selector(newFolder(_:)) { return folderUploadsAvailable && onNewFolder != nil && newFolderAllowed?() == true }
        if menuItem.action == #selector(upload(_:)) { return uploadsAvailable && onUpload != nil && uploadAllowed?() == true }
        if menuItem.action == #selector(pasteFile(_:)) { return onPaste != nil && pasteAllowed?() == true }
        if menuItem.action == #selector(cutFile(_:)) { return onCut != nil && cutAllowed?() == true }
        if menuItem.action == #selector(uploadHistory(_:)) { return onUploadHistory != nil }
        if menuItem.action == #selector(download(_:)) { return downloadsAvailable && onDownload != nil && downloadAllowed?() == true }
        if menuItem.action == #selector(downloadToPane(_:)) { return downloadsAvailable && onDownloadToPane != nil && paneDownloadAllowed?() == true }
        if menuItem.action == #selector(properties(_:)) { return onProperties != nil && canInspect?() == true }
        if menuItem.action == #selector(copyName(_:)) { return onCopyName != nil && canCopyName?() == true }
        if menuItem.action == #selector(copyPath(_:)) { return onCopyPath != nil && canCopyPath?() == true }
        if menuItem.action == #selector(refresh(_:)) { return onRefresh != nil }
        if menuItem.action == #selector(stop(_:)) { return cache.snapshot?.state == .loading && onStop != nil }
        if menuItem.action == #selector(disconnect(_:)) { return onDisconnect != nil }
        guard menuItem.action == #selector(openSelected(_:)), let item = cached(table.selectedRow) else { return false }
        let canRead = onViewText != nil && viewTextAllowed?() == true
        let canEdit = onEditText != nil && editTextAllowed?() == true
        return !item.isReparsePoint && (item.isDirectory || nativeOpenAllowed?() == true && (canRead || canEdit))
    }
}
