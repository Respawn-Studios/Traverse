import AppKit
import ExplorerCore
import LocalStorage

/// The active native file surface owns selection and geometry. Commands and
/// operation admission consume this seam rather than a hidden table mirror.
@MainActor
extension BrowserViewController {
    private static let iconThumbnailReader = LocalFileSystem(maximumConcurrentReads: 2, activityGate: ApplicationFileActivity.gate)
    var usesFileIcons: Bool { presentedFileViewMode == .icons }
    var remoteTable: RemoteFileTableView? { isSMBLocation ? smbTabs[activeID]?.rows.table : isSFTPLocation ? sftpTabs[activeID]?.rows.table : nil }
    var remoteScroll: NSScrollView? { isSMBLocation ? smbTabs[activeID]?.rows.scroll : isSFTPLocation ? sftpTabs[activeID]?.rows.scroll : nil }
    var activeFileView: NSView { if isArchiveLocation { return (currentArchive?.table as NSView?) ?? archiveHost }; if isRemoteLocation { return (remoteTable as NSView?) ?? (isSFTPLocation ? sftpHost : smbHost) }; return usesFileIcons ? iconBrowser.collectionView : table }
    var activeFileScrollView: NSScrollView { if isArchiveLocation { return currentArchive?.scroll ?? folderScroll }; if isRemoteLocation { return remoteScroll ?? folderScroll }; return usesFileIcons ? iconBrowser.scrollView : folderScroll }
    var visibleFileEntries: [FileEntry] {
        guard !isRemoteLocation, !isArchiveLocation else { return [] }
        guard !showsComputerVolumes else { return [] }
        if usesFileIcons { return iconBrowser.visibleEntries }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let lower = min(displayedEntries.count, max(0, range.location))
        let upper = min(displayedEntries.count, lower + range.length)
        return Array(displayedEntries[lower..<upper])
    }
    var activeFileScrollOffset: Double {
        let clip = activeFileScrollView.contentView
        return max(0, clip.bounds.origin.y + clip.contentInsets.top)
    }

    func configureFileIconPresentation() {
        iconBrowser.openingAppearanceForEntry = { [weak self] entry in self?.fileOpeningAppearance(entry) ?? .ordinary }
        iconBrowser.gitBadgeForEntry = { [weak self] entry in self?.gitControls.badge(for: entry) }
        iconBrowser.thumbnails.load = { [weak self] entry, folder in
            guard let self, !self.isBrowserSuspended, !Task.isCancelled else { return nil }
            let access = await self.accessLifetime(for: [entry.url])
            guard !self.isBrowserSuspended, !Task.isCancelled,
                  !TraverseAccessPolicy.requiresFolderSelection || access.covers(entry.url) else { return nil }
            return try await Self.iconThumbnailReader.thumbnail(for: entry, in: folder, retaining: access)
        }
        iconBrowser.onAccessibleActivation = { [weak self] in self?.prepareAccessibleBrowsingInteraction() ?? false }
        let collection = iconBrowser.collectionView
        collection.onOpen = { [weak self] in self?.openSelection(nil) }
        collection.onBack = { [weak self] in self?.goBack(nil) }
        collection.onCopy = { [weak self] in self?.copyFileURLs(nil) }
        collection.onCut = { [weak self] in self?.cutFileURLs(nil) }
        collection.onPaste = { [weak self] in self?.pasteFileURLs(nil) }
        collection.nameClickRenameEnabled = { [weak self] in self?.settings.renamesSelectedNameOnClick == true }
        collection.onRename = { [weak self] in self?.renameSelection(nil) }
        collection.onTrash = { [weak self] in self?.trashSelection(nil) }
        collection.onQuickLook = { [weak self] in self?.showQuickLook(nil) }
        collection.onUndo = { [weak self] in self?.undoFileOperation(nil) }
        collection.quickLookController = quickLook
        collection.commandValidation = { [weak self] in self?.fileResponderCommandEnabled($0) ?? false }
        collection.behavior = settings.behavior
        collection.onContextMenu = { [weak self] _ in
            guard let self else { return nil }
            return BrowserMenus.fileContextMenu(target: self)
        }
        iconBrowser.onSelectionChange = { [weak self] in
            guard let self, self.usesFileIcons, !self.showsComputerVolumes else { return }
            self.fileSelectionDidChange()
        }
    }

    func fileSelectionDidChange() {
        folderSummary.cancel()
        guard !updatingSelection else { return }
        canvasTransition?.finish(); canvasTransition = nil
        inlineRename.selectionDidChange()
        selectionGroupDraft.selectionDidChange()
        restoringScroll = false
        metadataSearch.openContextWillChange()
        if metadataSearch.isShowingResults { metadataSearch.resultViewState.selection = selectedURLs }
        else { tabs[activeIndex].state.selection = selectedURLs }
        refreshStatus()
        recordBrowserSession()
        workspace?.selectionDidChange(in: self)
    }

    func updateFilePresentationVisibility() {
        defer { updateIconThumbnailScope() }
        archiveHost.isHidden = !isArchiveLocation
        smbHost.isHidden = !isSMBLocation; sftpHost.isHidden = !isSFTPLocation
        if isRemoteLocation || isArchiveLocation { folderScroll.isHidden = true; table.marquee?.setVisible(false); iconBrowser.isHidden = true; volumeBrowser.isHidden = true; canvasTransition?.stageIncomingForeground(); return }
        let folder = !showsComputerVolumes
        folderScroll.isHidden = !folder || usesFileIcons
        table.marquee?.setVisible(!folderScroll.isHidden)
        iconBrowser.isHidden = !folder || !usesFileIcons
        volumeBrowser.isHidden = folder
        canvasTransition?.stageIncomingForeground()
    }

    func renderFilePresentation(selection: Set<URL>, scrollOffset: Double? = nil) {
        guard !isArchiveLocation else { return }
        folderSummary.cancel()
        for column in table.tableColumns where ["searchParent", "searchReason"].contains(column.identifier.rawValue) {
            column.isHidden = !metadataSearch.isShowingResults
        }
        inlineRename.prepareForRender()
        selectionGroupDraft.contextChanged()
        let previous = updatingSelection
        updatingSelection = true
        defer { updatingSelection = previous }
        if usesFileIcons {
            updateIconThumbnailScope()
            iconBrowser.showsFullPathsInTooltips = metadataSearch.isShowingResults
            iconBrowser.update(OrderedRows(entries: displayedEntries, rowsByURL: rowsByURL), selected: selection, cut: cutURLs,
                               showsExtensions: settings.showsFileExtensions)
        } else {
            table.reloadData()
            table.selectRowIndexes(IndexSet(selection.compactMap { rowsByURL[$0] }), byExtendingSelection: false)
        }
        activeFileScrollView.layoutSubtreeIfNeeded()
        if let scrollOffset { restoreFileScrollOffset(scrollOffset) }
        gitControls.updateBadges()
    }

    func refreshFilePresentation(selection: Set<URL>, scrollOffset: Double? = nil) {
        guard !isArchiveLocation else { return }
        guard usesFileIcons else {
            renderFilePresentation(selection: selection, scrollOffset: scrollOffset)
            return
        }
        let previous = updatingSelection
        updatingSelection = true
        defer { updatingSelection = previous }
        updateIconThumbnailScope()
        iconBrowser.showsFullPathsInTooltips = metadataSearch.isShowingResults
        iconBrowser.updateAppearance(selected: selection, cut: cutURLs,
                                     showsExtensions: settings.showsFileExtensions)
        if let scrollOffset { restoreFileScrollOffset(scrollOffset) }
    }

    private func updateIconThumbnailScope() {
        let scope: FileIconThumbnails.Scope?
        if settings.showsFileThumbnails, !isBrowserSuspended, !isReadOnlyFileSession, !isLoading,
           !iconBrowser.isHidden, !metadataSearch.isShowingResults, case .directory(let folder) = location {
            scope = .init(folder: folder, visit: sessionID)
        } else { scope = nil }
        iconBrowser.updateThumbnailScope(scope)
    }

    func setFileSelection(_ urls: Set<URL>) {
        guard !isArchiveLocation, !isRemoteLocation else { return }
        if usesFileIcons { iconBrowser.setSelection(urls) }
        else { table.selectRowIndexes(IndexSet(urls.compactMap { rowsByURL[$0] }), byExtendingSelection: false) }
    }

    func selectAllFiles() {
        if isArchiveLocation { currentArchive?.selectAll(); return }
        setFileSelection(Set(displayedEntries.map(\.url)))
        if usesFileIcons { fileSelectionDidChange() }
    }

    func restoreFileScrollOffset(_ offset: Double) {
        let scroll = activeFileScrollView
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin = NSPoint(x: 0, y: max(0, offset) - clip.contentInsets.top)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func revealFile(_ url: URL) {
        if usesFileIcons { iconBrowser.reveal(url) }
        else if let row = rowsByURL[url] { table.scrollRowToVisible(row) }
    }

    func fileViewsForRenameMotion() -> [(URL, NSView)] {
        activeFileView.layoutSubtreeIfNeeded()
        if usesFileIcons {
            return iconBrowser.visibleItems.prefix(128).compactMap { item in item.entry.map { ($0.url, item.view) } }
        }
        let rows = table.rows(in: table.visibleRect)
        guard rows.location != NSNotFound, displayedEntries.indices.contains(rows.location) else { return [] }
        let end = min(displayedEntries.count, rows.location + min(rows.length, 128))
        return (rows.location..<end).compactMap { row in
            table.rowView(atRow: row, makeIfNecessary: true).map { (displayedEntries[row].url, $0) }
        }
    }

    /// Native picker geometry stays bound to the currently presented surface.
    /// This shallow layout step neither opens nor reads the selected object.
    func activeFileSelectionAnchor(for urls: [URL]) -> (view: NSView, rect: NSRect)? {
        guard !isArchiveLocation, !isRemoteLocation, !showsComputerVolumes, !urls.isEmpty else { return nil }
        if usesFileIcons {
            guard let rect = iconBrowser.selectionAnchor(for: urls) else { return nil }
            return (iconBrowser.collectionView, rect)
        }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == BrowserColumn.name.rawValue }) else { return nil }
        let rows = urls.compactMap { rowsByURL[$0] }
        guard rows.count == urls.count else { return nil }
        if !rows.contains(where: { table.rect(ofRow: $0).intersects(table.visibleRect) }), let first = rows.first {
            table.scrollRowToVisible(first)
        }
        table.layoutSubtreeIfNeeded()
        guard let row = rows.first(where: { table.rect(ofRow: $0).intersects(table.visibleRect) }) else { return nil }
        let cellFrame = table.frameOfCell(atColumn: column, row: row)
        var rect = cellFrame
        if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
           let field = cell.textField {
            let labelFrame = table.convert(field.bounds, from: field)
            let textWidth = ceil(field.attributedStringValue.size().width) + 4
            rect = NSRect(x: cellFrame.minX, y: cellFrame.minY,
                width: min(cellFrame.width, labelFrame.minX - cellFrame.minX + textWidth), height: cellFrame.height)
        }
        if !rect.intersects(table.visibleRect) { table.scrollToVisible(rect) }
        rect = rect.intersection(table.visibleRect)
        return rect.isEmpty ? nil : (table, rect)
    }
}
