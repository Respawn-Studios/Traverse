import AppKit
import ExplorerCore
import Combine

/// Existing sidebar composition, persistence and native drag integration.
@MainActor extension BrowserViewController {
    func connectSidebarLayout() {
        var previous = sidebarLayoutOwner.preferences
        sidebarLayoutOwner.$preferences.dropFirst().sink { [weak self] next in
            let orderingChanged = !previous.hasSameOrdering(as: next)
            previous = next
            Task { @MainActor [weak self] in
                guard let self else { return }
                if orderingChanged { rebuildSidebar(coalescingLocalLayoutPublication: true) }
                else { sidebarLayout.restoreExpansion() }
            }
        }.store(in: &subscriptions)
        sidebarLayoutOwner.$status.sink { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !isBrowserSuspended, !value.isEmpty, sidebarLayoutOwner.status == value else { return }
                status.stringValue = value
            }
        }.store(in: &subscriptions)
        sidebarLayoutOwner.restoreIfNeeded()
        // Run AFTER dragDrop.configureDestinationViews, which currently replaces
        // the registered list. Preserve every existing file/archive drag type.
        var types = outline.registeredDraggedTypes
        if !types.contains(BrowserSidebarLayoutDragCoordinator.pasteboardType) {
            types.append(BrowserSidebarLayoutDragCoordinator.pasteboardType)
        }
        outline.registerForDraggedTypes(types)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.onSidebarLayoutMenu = { [weak self] node, existing in
            self?.sidebarLayout.drag.appendAlternatives(to: existing, for: node) ?? existing
        }
        // Preserve BrowserDragDrop's existing exit callback, including its
        // transfer admission/focus cleanup, and add only expansion reconciliation.
        let existingExit = outline.onFileDragExited
        outline.onFileDragExited = { [weak self] in
            existingExit?(); self?.sidebarLayout.restoreExpansion()
        }
    }

    func sidebarLayoutPlaces(_ nodes: [SidebarNode]) -> [SidebarNode] {
        guard nodes.count == SidebarPlace.allCases.count || nodes.isEmpty else { return nodes }
        return sidebarLayoutRows(zip(nodes, SidebarPlace.allCases).map {
            .init(node: $0.0, id: .stored(.place($0.1)))
        }, in: .places)
    }
    func sidebarLayoutFolderPins(_ root: SidebarNode) -> SidebarNode {
        sidebarLayout.bindRoot(root, to: .pinnedFolders)
        let children = root.children ?? []
        let values = children.compactMap { node -> BrowserSidebarLayoutAdapter.Row? in
            pinnedSidebar.id(for: node).map { .init(node: node, id: .folderPin($0)) }
        }
        guard values.count == children.count else { return root }
        root.children = sidebarLayoutRows(values, in: .pinnedFolders)
        return root
    }
    func sidebarLayoutConnectionPins(_ root: SidebarNode) -> SidebarNode {
        sidebarLayout.bindRoot(root, to: .pinnedConnections)
        let children = root.children ?? []
        let values = children.compactMap { node -> BrowserSidebarLayoutAdapter.Row? in
            node.remotePin.map { .init(node: node, id: .connectionPin($0)) }
        }
        guard values.count == children.count else { return root }
        root.children = sidebarLayoutRows(values, in: .pinnedConnections)
        return root
    }
    func sidebarLayoutRemembered(_ root: SidebarNode) -> SidebarNode {
        sidebarLayout.bindRoot(root, to: .rememberedFolders)
        let known = Set(folderAccess.locations.filter(\.isRemembered).map(\.id))
        let children = root.children ?? []
        let values = children.compactMap { node -> BrowserSidebarLayoutAdapter.Row? in
            guard let id = rememberedFolderSidebar.referenceID(for: node),
                  let reference = rememberedFolders.first(where: { $0.id == id }) else { return nil }
            return .init(node: node, id: BrowserSidebarLayoutAdapter.referenceID(reference, rememberedIDs: known))
        }
        guard values.count == children.count else { return root }
        root.children = sidebarLayoutRows(values, in: .rememberedFolders)
        return root
    }
    func sidebarLayoutVolumes(_ nodes: [SidebarNode]) -> [SidebarNode] {
        guard nodes.count == volumes.count else { return nodes }
        let cached = operationCoordinator.drives.volumes
        return sidebarLayoutRows(zip(nodes, volumes).map {
            .init(node: $0.0, id: BrowserSidebarLayoutAdapter.volumeID($0.1, cached: cached))
        }, in: .locations)
    }
    func sidebarLayoutServers(_ nodes: [SidebarNode], values: [BrowserConnectedLocation], saved: [WorkspaceConnectionBookmark] = []) -> [SidebarNode] {
        guard nodes.count == values.count + saved.count else { return nodes }
        let identities = BrowserSidebarLayoutAdapter.serverRowIDs(live: values, saved: saved)
        return sidebarLayoutRows(zip(nodes, identities).map { .init(node: $0.0, id: $0.1) }, in: .servers)
    }
    private func sidebarLayoutRows(_ values: [BrowserSidebarLayoutAdapter.Row], in section: SidebarLayoutSection) -> [SidebarNode] {
        do { return try sidebarLayout.bindRows(values, in: section) }
        catch {
            // Render the existing observations honestly, with reordering
            // unavailable, rather than hiding rows or inventing an identity.
            status.stringValue = "Sidebar ordering is unavailable for this observation. Existing rows remain visible."
            return values.map(\.node)
        }
    }
    func sidebarLayoutOrderRoots() {
        do { sidebarRoots = try sidebarLayout.orderedRoots(sidebarRoots) }
        catch { status.stringValue = "Sidebar category order could not be applied. Existing rows remain visible." }
    }
    func sidebarLayoutView(_ existing: NSView, for node: SidebarNode) -> NSView {
        guard sidebarLayout.subject(for: node) != nil else { return existing }
        return BrowserSidebarNameView(content: existing, node: node, outline: outline,
                                      coordinator: sidebarLayout.drag)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? SidebarNode else { return nil }
        return sidebarLayout.drag.pasteboardWriter(for: node, in: outlineView)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        sidebarLayout.drag.willBegin(session, outline: outlineView, items: draggedItems)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        sidebarLayout.drag.ended(session)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        sidebarLayout.disclosureChanged(node, expanded: true)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        sidebarLayout.disclosureChanged(node, expanded: false)
    }

    /// `nil` alone means an ordinary file/archive drag may use the existing
    /// destination path. An invalid internal drag returns `.some([])`/false.
    func sidebarLayoutValidateDrop(_ info: any NSDraggingInfo, outline: NSOutlineView,
                                   item: Any?, childIndex: Int) -> NSDragOperation? {
        guard sidebarLayout.drag.containsInternalType(info) else { return nil }
        return sidebarLayout.drag.validate(info, outline: outline, proposedItem: item, childIndex: childIndex)
    }
    func sidebarLayoutAcceptDrop(_ info: any NSDraggingInfo, outline: NSOutlineView,
                                 item: Any?, childIndex: Int) -> Bool? {
        guard sidebarLayout.drag.containsInternalType(info) else { return nil }
        return sidebarLayout.drag.accept(info, outline: outline, item: item, childIndex: childIndex)
    }
}
