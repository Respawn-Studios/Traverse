import AppKit
import ExplorerCore
import LocalStorage

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { displayedEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedEntries.indices.contains(row), let tableColumn else { return nil }
        let entry = displayedEntries[row]
        let key = tableColumn.identifier.rawValue
        let opening = key == "name" ? fileOpeningAppearance(entry) : .ordinary
        let cell = FileTableCell.view(in: tableView, column: key)
        let text: String
        switch key {
        case "name":
            text = settings.showsFileExtensions || entry.kind == .directory ? entry.name : (entry.name as NSString).deletingPathExtension
            let icon = FileIconRole.classify(name: entry.name, kind: entry.kind.rawValue)
            cell.imageView?.image = FileOpeningSymbol.image(role: icon, appearance: opening)
            cell.imageView?.contentTintColor = FileOpeningSymbol.tint(opening, directory: entry.kind == .directory)
        case "modified": text = entry.modifiedAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "created": text = entry.createdAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "accessed": text = entry.accessedAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "extension": text = entry.filenameExtension ?? "—"
        case "kind":
            text = FileKindText.string(name: entry.name, kind: entry.kind.rawValue)
        case "size": text = entry.byteCount.map(FileSizeText.string) ?? "—"
        case "searchParent": text = entry.url.deletingLastPathComponent().path
        case "searchReason": text = metadataSearch.savedNames.reason(entry.url)
        default: text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = key == "name" ? .labelColor : .secondaryLabelColor
        cell.textField?.alignment = key == "size" ? .right : .left
        let isCut = cutURLs.contains(entry.url)
        (cell as? FileNameCellView)?.showCutMarker(isCut)
        cell.toolTip = (key == "name" ? (metadataSearch.isShowingResults ? entry.url.path : entry.name) : text) + (isCut ? " — Cut: ready to move when pasted" : "")
        if metadataSearch.isShowingResults, key == "name" { cell.toolTip = entry.url.path + "\n" + metadataSearch.savedNames.reason(entry.url) }
        if key == "name", entry.kind == .directory, settings.folderSummariesEnabled, !metadataSearch.isShowingResults {
            cell.toolTip = nil // The progressive summary owns this folder's hover presentation.
        }
        if let explanation = opening.explanation { cell.toolTip = (cell.toolTip ?? text) + "\n" + explanation }
        cell.setAccessibilityHelp(opening.explanation)
        cell.setAccessibilityLabel(text + (isCut ? ", cut, ready to move" : "") + (opening.explanation.map { ", " + $0 } ?? ""))
        cell.alphaValue = isCut ? 0.5 : 1
        return cell
    }

    static let dateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .short
        return value
    }()

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !usesFileIcons else { return }
        fileSelectionDidChange()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updatingSortIndicators else { return }
        guard let descriptor = tableView.sortDescriptors.first, let field = SortField(rawValue: descriptor.key ?? "name") else { return }
        saveViewState()
        tabs[activeIndex].sort.field = field
        tabs[activeIndex].sort.ascending = descriptor.ascending
        markFolderViewOverride()
        tableView.headerView?.needsDisplay = true
        requestOrdering()
        recordBrowserSession()
    }
}

extension BrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func rebuildSidebar(coalescingLocalLayoutPublication: Bool = false) {
        if coalescingLocalLayoutPublication && sidebarLayout.canSkipMatchingLocalProjectionNotification() { return }
        sidebarLayout.beginRebuild()
        let wasUpdating = updatingSidebarSelection
        updatingSidebarSelection = true
        defer { updatingSidebarSelection = wasUpdating; syncSidebarSelection(); dragDrop.destinationsChanged() }
        for task in sidebarTasks { task.cancel() }
        sidebarTasks = []
        let unorderedFavorites = BrowsingHome.url.map { home in [
            SidebarNode("Home", location: .directory(home), icon: "house"),
            SidebarNode("Desktop", location: .directory(home.appendingPathComponent("Desktop", isDirectory: true)), icon: "menubar.dock.rectangle"),
            SidebarNode("Documents", location: .directory(home.appendingPathComponent("Documents", isDirectory: true)), icon: "doc"),
            SidebarNode("Downloads", location: .directory(home.appendingPathComponent("Downloads", isDirectory: true)), icon: "arrow.down.circle")
        ] } ?? []
        let favorites = sidebarLayoutPlaces(unorderedFavorites)
        let remembered = sidebarLayoutRemembered(rememberedFolderSidebar.group(for: rememberedFolders))
        sidebarRoots = [
            sidebarLayout.bindRoot(SidebarNode("This Mac", location: .computer, icon: "desktopcomputer", children: []), to: .computer),
            sidebarLayout.bindRoot(SidebarNode("Places", group: true, children: favorites), to: .places)
        ]
        let pinned = sidebarLayoutFolderPins(pinnedSidebar.group(controller: pinsController))
        if pinned.children?.isEmpty == false { sidebarRoots.append(pinned) }
        let remotePinned = sidebarLayoutConnectionPins(remotePinsGroup())
        if remotePinned.children?.isEmpty == false { sidebarRoots.append(remotePinned) }
        sidebarRoots.append(sidebarLayout.bindRoot(SidebarNode("Locations", group: true, children: []), to: .locations))
        presentConnectedLocations(connectedLocationSnapshot, rebuilding: true)
        if !rememberedFolders.isEmpty { sidebarRoots.append(remembered) }
        updateSidebarVolumes()
        workspace?.applyInitialVolumeObservationHint(to: self)
        sidebarLayoutOrderRoots()
        outline.reloadData()
        sidebarLayout.restoreExpansion()
    }

    func updateSidebarVolumes() {
        guard let group = sidebarRoots.first(where: { $0.title == "Locations" }) else { return }
        let wasUpdating = updatingSidebarSelection
        updatingSidebarSelection = true
        defer { updatingSidebarSelection = wasUpdating; syncSidebarSelection(); dragDrop.destinationsChanged() }
        let observedNodes = volumes.map { volume in
            SidebarNode(volume.name, location: .directory(volume.url),
                        icon: volume.kind == .network ? "network" : volume.kind == .internalDisk ? "internaldrive" : "externaldrive")
        }
        group.children = sidebarLayoutVolumes(observedNodes)
        outline.reloadItem(group, reloadChildren: true)
        sidebarLayout.restoreExpansion()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarNode else { return sidebarRoots.count }
        return item.children?.count ?? 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return sidebarRoots[index] }
        if node.children == nil { loadSidebarChildren(node) }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if node.group { return !(node.children?.isEmpty ?? true) }
        guard node.location?.directoryURL != nil else { return false }
        return node.children == nil || !(node.children?.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode)?.group ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        sidebarLayout.applyingExpansion || !sidebarLayout.drag.isDragging
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? SidebarNode else { return nil }
        let row = BrowserSidebarRowView()
        row.acceptsPointerFeedback = self.outlineView(outlineView, shouldSelectItem: node)
        (outlineView as? BrowserSidebarOutlineView)?.configurePointerRow(row, item: node)
        return row
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // Section breathing room and the native disclosure share the same
        // row midpoint. Item rows retain their familiar compact density.
        (item as? SidebarNode)?.group == true ? InterfaceMetrics.points(24) : outlineView.rowHeight
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.location != nil || node.connectionTarget != nil || node.serverBookmark != nil
            || node.remotePin != nil || rememberedFolderSidebar.referenceID(for: node) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.group {
            return sidebarLayoutView(label(node.title, size: 11, color: .secondaryLabelColor, weight: .semibold), for: node)
        }
        let id = NSUserInterfaceItemIdentifier("sidebar.location")
        let cell: SidebarLocationCell
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarLocationCell { cell = reused }
        else { cell = SidebarLocationCell(frame: .zero); cell.identifier = id }
        let drive = node.location?.directoryURL.flatMap { root in
            operationCoordinator.drives.volumes.first { $0.url?.standardizedFileURL == root.standardizedFileURL }
        }
        let visible = drive.map { settings.showsSidebarEject && ($0.deviceKind == .externalDisk || $0.deviceKind == .diskImage) && !isSidebarEjectHidden(for: $0) } ?? false
        cell.configureEject(visible: visible, enabled: drive?.canEject == true && !operationCoordinator.drives.isBusy, action: { [weak self] in
            guard let self, let drive else { return }
            self.operationCoordinator.drives.request(drive, action: .eject, policy: self.settings.ejectNewWorkPolicy)
            self.driveStatus.show()
        })
        cell.eject.toolTip = drive?.canEject == true ? "Eject " + node.title + " after its accepted transfers finish"
            : "Eject is not available for this drive. Open Drives to see its supported actions."
        cell.eject.setAccessibilityLabel("Eject " + node.title)
        cell.eject.setAccessibilityHelp(cell.eject.toolTip)
        cell.imageView?.image = symbol(node.icon, node.title)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.configureConnecting(node.serverBookmark.map { savedServerLocations.connectingPhase(for: $0) != nil } ?? false,
            animated: settings.motion.allows(.pages))
        cell.textField?.stringValue = node.title
        if let id = pinnedSidebar.id(for: node) {
            let state = pinsController.availability[id] == .unavailable ? "Unavailable; select to retry" : "Path shortcut; access checked when opened"
            cell.setAccessibilityLabel(node.title + ", " + state)
            cell.toolTip = state
        } else {
            cell.setAccessibilityLabel(node.title + (node.detail.map { ", " + $0 } ?? ""))
            cell.toolTip = node.detail ?? (node.location == nil ? node.title : nil)
        }
        return sidebarLayoutView(cell, for: node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSidebarSelection, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        if let connection = node.connectionTarget { focusConnectedLocation(connection); return }
        if let saved = node.serverBookmark { openSavedServer(saved); return }
        if let id = node.remotePin { openRemotePin(id); return }
        if let id = rememberedFolderSidebar.referenceID(for: node) {
            openRememberedFolderReference(id)
            return
        }
        guard let location = node.location else { return }
        navigate(to: location)
    }

    func syncSidebarSelection() {
        guard !updatingSidebarSelection else { return }
        updatingSidebarSelection = true
        defer { updatingSidebarSelection = false }
        func matches(_ node: SidebarNode) -> Bool {
            if let id = node.remotePin, let pin = remotePins.collection.pins.first(where: { $0.id == id }), let target = currentRemoteBookmark {
                return pin.target.kind == target.kind && pin.target.serverID == target.serverID
                    && pin.target.binding == target.binding && pin.target.relativeToHome == target.relativeToHome && pin.target.components == target.components
            }
            if node.location == location { return true }
            guard let id = rememberedFolderSidebar.referenceID(for: node),
                  let reference = rememberedFolders.first(where: { $0.id == id }),
                  case .resolvedUnverified = reference.state, let url = reference.url else { return false }
            return location == .directory(url)
        }
        if let selected = outline.item(atRow: outline.selectedRow) as? SidebarNode, matches(selected) { return }
        if let row = (0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? SidebarNode).map(matches) ?? false
        }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
    }

    func loadSidebarChildren(_ node: SidebarNode) {
        guard !node.loading, let url = node.location?.directoryURL else { node.children = []; return }
        guard !isBrowserSuspended, operationCoordinator.drives.offlineVolume(containing: url) == nil else {
            node.children = [SidebarNode("Drive unavailable", icon: "eject", children: [])]
            return
        }
        node.loading = true
        node.children = [SidebarNode("Loading…", icon: "clock", children: [])]
        let hidden = settings.showsHiddenFiles
        let task = Task { [weak self, weak node, fileSystem, ordering] in
            var folders: [FileEntry] = []
            var partial = false
            do {
                let lease = await self?.folderAccess.acquireAccess(to: url)
                guard !Task.isCancelled else { return }
                for try await event in fileSystem.entries(in: url, showHidden: hidden, retaining: lease) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .batch(let entries): folders.append(contentsOf: entries.filter { $0.kind == .directory })
                    case .finished(let issues): partial = !issues.isEmpty
                    }
                }
                let ordered = try await ordering.order(folders, sort: DirectorySort(), filter: "")
                guard let self, let node, !Task.isCancelled else { return }
                node.children = ordered.entries.map { SidebarNode($0.name, location: .directory($0.url)) }
                if partial { node.children?.append(SidebarNode("Some details unavailable", icon: "exclamationmark.circle", children: [])) }
                node.loading = false
                self.updatingSidebarSelection = true
                self.outline.reloadItem(node, reloadChildren: true)
                self.updatingSidebarSelection = false
                self.syncSidebarSelection()
                self.dragDrop.destinationsChanged()
            } catch {
                guard let self, let node, !Task.isCancelled else { return }
                node.children = [SidebarNode(self.message(for: error), icon: "exclamationmark.circle", children: [])]
                node.loading = false
                self.updatingSidebarSelection = true
                self.outline.reloadItem(node, reloadChildren: true)
                self.updatingSidebarSelection = false
                self.syncSidebarSelection()
                self.dragDrop.destinationsChanged()
            }
        }
        node.task = task
        sidebarTasks.append(task)
    }
}
