import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Session-only navigation identity. A row focuses an existing tab; it cannot
/// create a session, mount, credential claim or filesystem-operation URL.
struct BrowserConnectionIdentity: Hashable, Sendable {
    enum Kind: String, Sendable { case smb = "SMB", sftp = "SFTP" }
    let pane: UUID, tab: UUID, connection: UUID
    let kind: Kind
}
struct BrowserConnectedLocation: Equatable {
    let id: BrowserConnectionIdentity
    let name: String, status: String
    let location: BrowserLocation
    var savedTarget: WorkspaceConnectionBookmark? = nil
}

@MainActor extension BrowserViewController {
    @objc func disconnectCurrentConnection(_ sender: Any?) {
        guard commandEnabled(#selector(disconnectCurrentConnection(_:))) else { return }
        if isSFTPLocation { disconnectSFTPConnection(sender) }
        else if isSMBLocation { disconnectSMBConnection(sender) }
    }

    var liveConnectionLocations: [BrowserConnectedLocation] {
        tabs.compactMap { tab in
            if let owner = sftpTabs[tab.id] {
                let value = owner.session.latest
                let status = owner.isClosing ? "Disconnecting" : value.failure != nil ? "Connection unavailable"
                    : value.directoryRejection != nil ? "Folder unavailable" : value.reading ? "Loading folder" : "Connected"
                return .init(id: .init(pane: paneID, tab: tab.id, connection: owner.connectionID, kind: .sftp), name: owner.savedConnection?.title ?? owner.root.displayHint,
                    status: status, location: owner.currentBrowserLocation, savedTarget: owner.savedConnection)
            }
            if let owner = smbTabs[tab.id] {
                let value = owner.session.latest
                let status = owner.isClosing ? "Disconnecting" : value.failure != nil && value.failure != .stopped ? "Connection unavailable"
                    : value.directoryRejection != nil ? "Folder unavailable" : value.failure == .stopped ? "Reading paused" : value.snapshot?.state == .loading ? "Loading folder" : "Connected"
                return .init(id: .init(pane: paneID, tab: tab.id, connection: owner.connectionID, kind: .smb), name: owner.savedConnection?.title ?? owner.root.displayHint,
                    status: status, location: owner.currentBrowserLocation, savedTarget: owner.savedConnection)
            }
            return nil
        }
    }
    func refreshConnectedLocations(force: Bool = false) {
        let owners: [BrowserViewController]
        if let workspace {
            guard !workspace.isClosing else { return }
            owners = workspace.layout.paneIDs.compactMap { workspace.browsers[$0] }
        } else { owners = [self] }
        let values = owners.filter { !$0.isBrowserSuspended }.flatMap(\.liveConnectionLocations)
        for owner in owners where owner.isViewLoaded && !owner.isBrowserSuspended { owner.presentConnectedLocations(values, force: force) }
    }
    func presentConnectedLocations(_ values: [BrowserConnectedLocation], rebuilding: Bool = false, force: Bool = false) {
        defer { updateConnectionStatusIndicator() }
        guard isViewLoaded, !isBrowserSuspended else { return }
        let saved = savedServerLocations.snapshot.locations.filter { target in
            !values.contains { value in value.savedTarget.map {
                $0.kind == target.kind && $0.serverID == target.serverID && $0.binding == target.binding
            } ?? false }
        }
        let sameLocations = connectedLocationSnapshot == values && disconnectedServerSnapshot == saved
        if !force && !rebuilding && sameLocations { return }
        connectedLocationSnapshot = values; disconnectedServerSnapshot = saved
        let phases = Dictionary(uniqueKeysWithValues: saved.compactMap { target in
            savedServerLocations.connectingPhase(for: target).map { (target, $0) }
        })
        volumeBrowser.updateConnections(values, saved: saved, notice: savedServerLocations.snapshot.notice, progress: phases)
        let index = sidebarRoots.firstIndex { $0.title == "Servers" && $0.group }
        if sameLocations, !rebuilding, let index {
            // A phase update is presentation, not a new sidebar tree. Preserve
            // selection, expansion and any in-progress name drag.
            for node in sidebarRoots[index].children ?? [] {
                guard let target = node.serverBookmark else { continue }
                let phase = savedServerLocations.connectingPhase(for: target)
                node.detail = (target.isSFTP ? "SFTP" : "SMB") + " · " + (phase ?? "Not connected · Connect")
                let row = outline.row(forItem: node)
                guard row >= 0 else { continue }
                let visible = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
                let cell = (visible as? SidebarLocationCell)
                    ?? ((visible as? BrowserSidebarNameView)?.content as? SidebarLocationCell)
                cell?.configureConnecting(phase != nil,
                    animated: settings.motion.allows(.pages))
                cell?.setAccessibilityLabel(node.title + (node.detail.map { ", " + $0 } ?? ""))
                cell?.toolTip = node.detail
            }
            return
        }
        let observedChildren = values.map {
            SidebarNode($0.name, location: $0.location, icon: "server.rack", children: [], connectionTarget: $0.id,
                detail: $0.id.kind.rawValue + " · " + $0.status + " · Switch to its open tab")
        }
        let savedChildren = saved.map {
            SidebarNode($0.title, icon: "server.rack", children: [],
                detail: ($0.isSFTP ? "SFTP" : "SMB") + " · " + (savedServerLocations.connectingPhase(for: $0) ?? "Not connected · Connect"), serverBookmark: $0)
        }
        let children = sidebarLayoutServers(observedChildren + savedChildren, values: values, saved: saved)
        let wasUpdating = updatingSidebarSelection; updatingSidebarSelection = true
        defer { updatingSidebarSelection = wasUpdating; if !rebuilding { syncSidebarSelection() } }
        if rebuilding {
            if !children.isEmpty {
                sidebarRoots.append(sidebarLayout.bindRoot(SidebarNode("Servers", group: true, children: children), to: .servers))
            }
            return
        }
        if let index {
            let group = sidebarRoots[index]
            if children.isEmpty {
                sidebarLayout.removeRoot(.servers)
                outline.beginUpdates(); sidebarRoots.remove(at: index)
                outline.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: settings.motion.allows(.pages) ? .effectFade : [])
                outline.endUpdates()
            } else {
                group.children = children; outline.reloadItem(group, reloadChildren: true)
                sidebarLayout.restoreExpansion()
            }
        } else if !children.isEmpty {
            let group = sidebarLayout.bindRoot(SidebarNode("Servers", group: true, children: children), to: .servers)
            guard let index = try? sidebarLayout.insertionIndex(for: .servers, among: sidebarRoots) else { return }
            outline.beginUpdates(); sidebarRoots.insert(group, at: index)
            outline.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: settings.motion.allows(.pages) ? .effectFade : [])
            outline.endUpdates(); sidebarLayout.restoreExpansion()
        }
    }
    @discardableResult func focusConnectedLocation(_ identity: BrowserConnectionIdentity) -> Bool {
        let owner = workspace?.browsers[identity.pane] ?? (identity.pane == paneID ? self : nil)
        guard !isBrowserSuspended, view.window?.attachedSheet == nil, let owner,
              !owner.isBrowserSuspended, owner.view.window?.attachedSheet == nil,
              let current = owner.liveConnectionLocations.first(where: { $0.id == identity }) else { return false }
        if let workspace { guard !workspace.isClosing else { return false }; workspace.activate(owner, focus: false) }
        owner.selectTab(current.id.tab)
        if owner.location != current.location { owner.navigate(to: current.location) }
        owner.focusBrowserContent(); return true
    }
    func openSavedServer(_ bookmark: WorkspaceConnectionBookmark) {
        guard !isBrowserSuspended, view.window?.attachedSheet == nil,
              savedServerLocations.snapshot.locations.contains(bookmark) else { return }
        if let live = connectedLocationSnapshot.first(where: { value in value.savedTarget.map {
            $0.kind == bookmark.kind && $0.serverID == bookmark.serverID && $0.binding == bookmark.binding
        } ?? false }), focusConnectedLocation(live.id) { return }
        _ = startSavedServerConnection(bookmark)
    }
    @discardableResult func startSavedServerConnection(_ bookmark: WorkspaceConnectionBookmark,
        reconnect: WorkspaceReconnectTarget? = nil, allowsFormFallback: Bool = true) -> Bool {
        if let reconnect, reconnect.browser !== self || !reconnect.isCurrent || reconnect.bookmark != bookmark { return false }
        let locations = savedServerLocations
        guard locations.beginConnecting(bookmark) else { return false }
        let originTab = activeID, originVisit = sessionID
        var lastPhase: String?
        connectionService.connectSaved(in: self, savedServer: bookmark, reconnect: reconnect,
            allowsFormFallback: allowsFormFallback, phase: { [weak self, weak locations] phase in
            locations?.updateConnecting(bookmark, phase: phase)
            lastPhase = phase
            guard self?.activeID == originTab, self?.sessionID == originVisit else { return }
            self?.status.stringValue = phase
            self?.updateConnectionStatusIndicator()
        }, finished: { [weak self, weak locations] connected in
            locations?.finishConnecting(bookmark)
            self?.refreshConnectedLocations(force: true)
            self?.syncSidebarSelection()
            guard !connected, let self, reconnect?.isCurrent == true,
                  activeID == originTab, sessionID == originVisit else { return }
            if case .smb(let location) = self.location { self.loadSMBLocation(location) }
            else if case .sftp(let location) = self.location { self.loadSFTPLocation(location) }
            if !allowsFormFallback, let lastPhase {
                status.stringValue = lastPhase
                updateConnectionStatusIndicator()
            }
        })
        return true
    }
    func connectedLocationMenu(_ value: BrowserConnectedLocation) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = menu.addItem(withTitle: "Switch to Connection", action: #selector(focusConnectedMenu(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = ConnectionMenuTarget(value.id)
        item.isEnabled = !isBrowserSuspended
        for (title, action) in [("Connection Properties…", #selector(propertiesConnectedMenu(_:))),
            ("Pin Current Folder", #selector(pinConnectedMenu(_:))), ("Disconnect This Connection", #selector(disconnectConnectedMenu(_:)))] {
            let command = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            command.target = self; command.representedObject = ConnectionMenuTarget(value.id); command.isEnabled = !isBrowserSuspended
        }
        if let saved = value.savedTarget, savedServerLocations.snapshot.locations.contains(saved) {
            let open = NSMenuItem(title: "Open in New Tab", action: #selector(openSavedServerInNewTabMenu(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = SavedServerMenuTarget(saved); open.isEnabled = !isBrowserSuspended
            menu.insertItem(open, at: 1)
            menu.addItem(.separator())
            let forget = menu.addItem(withTitle: "Forget Saved Server…", action: #selector(forgetSavedServerMenu(_:)), keyEquivalent: "")
            forget.target = self; forget.representedObject = SavedServerMenuTarget(saved)
            forget.isEnabled = !isBrowserSuspended && connectionService.canManageSavedServers
        }
        return menu
    }
    func savedServerMenu(_ bookmark: WorkspaceConnectionBookmark) -> NSMenu? {
        guard savedServerLocations.snapshot.locations.contains(bookmark) else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let pending = savedServerLocations.connectingPhase(for: bookmark) != nil
        for (title, action) in [(pending ? "Cancel Connection" : "Connect", pending
            ? #selector(cancelSavedServerMenu(_:)) : #selector(connectSavedServerMenu(_:))),
            ("Open in New Tab", #selector(openSavedServerInNewTabMenu(_:))),
            ("Connection Settings…", #selector(editSavedServerMenu(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = SavedServerMenuTarget(bookmark)
            item.isEnabled = !isBrowserSuspended && (action != #selector(openSavedServerInNewTabMenu(_:)) || !pending)
        }
        menu.addItem(.separator())
        let forget = menu.addItem(withTitle: "Forget Saved Server…", action: #selector(forgetSavedServerMenu(_:)), keyEquivalent: "")
        forget.target = self; forget.representedObject = SavedServerMenuTarget(bookmark)
        forget.isEnabled = !isBrowserSuspended && !pending && connectionService.canManageSavedServers
        return menu
    }
    @objc private func openSavedServerInNewTabMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SavedServerMenuTarget,
              !isBrowserSuspended, view.window?.attachedSheet == nil,
              savedServerLocations.snapshot.locations.contains(target.bookmark) else { return }
        _ = startSavedServerConnection(target.bookmark)
    }
    @objc private func forgetSavedServerMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SavedServerMenuTarget else { return }
        connectionService.confirmForgetSavedServer(target.bookmark, in: self)
    }
    @objc private func connectSavedServerMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SavedServerMenuTarget else { return }
        openSavedServer(target.bookmark)
    }
    @objc private func editSavedServerMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SavedServerMenuTarget,
              savedServerLocations.snapshot.locations.contains(target.bookmark) else { return }
        connectionService.present(in: self, savedServer: target.bookmark)
    }
    @objc private func cancelSavedServerMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SavedServerMenuTarget,
              savedServerLocations.connectingPhase(for: target.bookmark) != nil else { return }
        connectionService.cancelSavedConnection()
    }
    @objc private func focusConnectedMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? ConnectionMenuTarget else { return }; focusConnectedLocation(value.id)
    }
    @objc private func propertiesConnectedMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? ConnectionMenuTarget, focusConnectedLocation(value.id) else { return }
        (workspace?.activeBrowser ?? self).showCurrentConnectionProperties(sender)
    }
    @objc private func pinConnectedMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? ConnectionMenuTarget, focusConnectedLocation(value.id) else { return }
        (workspace?.activeBrowser ?? self).pinCurrentConnectionFolder(sender)
    }
    @objc private func disconnectConnectedMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? ConnectionMenuTarget, focusConnectedLocation(value.id) else { return }
        let browser = workspace?.activeBrowser ?? self
        browser.disconnectCurrentConnection(sender)
    }
}

@MainActor private final class ConnectionMenuTarget: NSObject {
    let id: BrowserConnectionIdentity
    init(_ id: BrowserConnectionIdentity) { self.id = id }
}
@MainActor private final class SavedServerMenuTarget: NSObject {
    let bookmark: WorkspaceConnectionBookmark
    init(_ bookmark: WorkspaceConnectionBookmark) { self.bookmark = bookmark }
}

/// A compact network category using the same tile surface and column geometry
/// as drives. The parent supplies one scroll document for both categories.
@MainActor final class ConnectedServersView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private enum TileID: Hashable {
        case connection(BrowserConnectionIdentity), saved(WorkspaceConnectionBookmark)
    }
    private struct Entry {
        let id: TileID, source: ServerLocationTile.Source
    }
    var onOpen: ((BrowserConnectionIdentity) -> Void)?
    var onOpenSaved: ((WorkspaceConnectionBookmark) -> Void)?
    var onMenu: ((BrowserConnectionIdentity) -> NSMenu?)?
    var onSavedMenu: ((WorkspaceConnectionBookmark) -> NSMenu?)?
    var onBack: (() -> Void)? { didSet { collection.onBack = onBack } }
    var behavior = BrowserBehaviorPreferences.explorer { didSet { collection.behavior = behavior } }
    var motion = BrowserMotionPreferences() { didSet { visibleTiles.forEach { $0.motion = motion } } }
    private let heading = label("Servers", size: 15, weight: .medium)
    private let collection = VolumeCollectionView()
    private let flow = BrowserLocationFlowLayout()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private static let identifier = NSUserInterfaceItemIdentifier("ServerLocationTile")
    private(set) var values: [BrowserConnectedLocation] = []
    private(set) var saved: [WorkspaceConnectionBookmark] = []
    private var progress: [WorkspaceConnectionBookmark: String] = [:]
    private var entries: [Entry] = []
    private var notice = ""
    var itemCount: Int { entries.count + (notice.isEmpty ? 0 : 1) }
    var visibleTiles: [ServerLocationTile] { collection.visibleItems().compactMap { $0 as? ServerLocationTile } }
    nonisolated override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        collection.collectionViewLayout = flow; collection.dataSource = self; collection.delegate = self
        flow.configure(width: 300)
        collection.frame = NSRect(x: 0, y: 28, width: 300, height: 76)
        collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]; collection.register(ServerLocationTile.self, forItemWithIdentifier: Self.identifier)
        collection.setAccessibilityLabel("Saved and connected servers")
        collection.onOpenSelection = { [weak self] in
            guard let self, let index = self.collection.selectionIndexPaths.first?.item else { return }
            _ = self.open(index)
        }
        collection.onContextMenu = { [weak self] event in self?.serverMenu(for: event) }
        collection.onFocusChange = { [weak self] in self?.refreshSelectionAppearance() }
        noticeLabel.textColor = .secondaryLabelColor; InterfaceMetrics.setFont(noticeLabel, base: .systemFont(ofSize: 12))
        for child in [heading, collection, noticeLabel] { addSubview(child) }
        noticeLabel.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    func refreshSelectionAppearance() { visibleTiles.forEach { $0.refreshAppearance() } }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        flow.configure(width: width)
        return InterfaceMetrics.points(28) + flow.contentHeight(items: entries.count, width: width)
            + (notice.isEmpty ? 0 : InterfaceMetrics.points(8) + noticeHeight(width))
    }
    private func noticeHeight(_ width: CGFloat) -> CGFloat {
        max(InterfaceMetrics.points(16), noticeLabel.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)).height ?? 0)
    }
    override func layout() {
        super.layout(); flow.configure(width: bounds.width)
        heading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InterfaceMetrics.points(20))
        collection.frame = NSRect(x: 0, y: InterfaceMetrics.points(28), width: bounds.width,
            height: flow.contentHeight(items: entries.count, width: bounds.width))
        noticeLabel.frame = NSRect(x: 0, y: collection.frame.maxY + InterfaceMetrics.points(8),
            width: bounds.width, height: noticeHeight(bounds.width))
    }
    func update(_ values: [BrowserConnectedLocation], saved: [WorkspaceConnectionBookmark] = [],
                notice: String = "", progress: [WorkspaceConnectionBookmark: String] = [:]) {
        guard self.values != values || self.saved != saved || self.notice != notice || self.progress != progress else { return }
        var proposed: [Entry] = [], used = Set<TileID>()
        for value in values {
            var id = value.savedTarget.map(TileID.saved) ?? .connection(value.id)
            if !used.insert(id).inserted {
                id = .connection(value.id)
                guard used.insert(id).inserted else { continue }
            }
            proposed.append(.init(id: id, source: .connected(value)))
        }
        for value in saved where used.insert(.saved(value)).inserted {
            proposed.append(.init(id: .saved(value), source: .saved(value, progress: progress[value])))
        }
        // Connecting and disconnecting change the tile's state, not its place.
        // New servers append; explicitly removed records disappear normally.
        let previousIDs = Set(entries.map(\.id))
        let current = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
        let next = entries.compactMap { current[$0.id] } + proposed.filter { !previousIDs.contains($0.id) }
        let structural = entries.map(\.id) != next.map(\.id)
        entries = next
        self.values = values; self.saved = saved; self.notice = notice; self.progress = progress
        heading.stringValue = "Servers (\(entries.count))"
        noticeLabel.stringValue = notice; noticeLabel.isHidden = notice.isEmpty
        if structural { collection.reloadData() }
        else {
            for tile in visibleTiles {
                guard let path = collection.indexPath(for: tile) else { continue }
                configure(tile, at: path.item)
            }
        }
        needsLayout = true
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: Self.identifier, for: indexPath)
        if let tile = tile as? ServerLocationTile { configure(tile, at: indexPath.item) }
        return tile
    }
    private func configure(_ tile: ServerLocationTile, at index: Int) {
        guard let source = source(at: index) else { return }
        tile.configure(source, motion: motion)
        tile.onOpen = { [weak self, weak tile] in
            guard let self, let tile, let path = self.collection.indexPath(for: tile) else { return false }
            return self.open(path.item)
        }
    }
    private func source(at index: Int) -> ServerLocationTile.Source? {
        entries.indices.contains(index) ? entries[index].source : nil
    }
    @discardableResult private func open(_ index: Int) -> Bool {
        guard let source = source(at: index) else { return false }
        switch source {
        case .connected(let value): guard let onOpen else { return false }; onOpen(value.id)
        case .saved(let value, _): guard let onOpenSaved else { return false }; onOpenSaved(value)
        }
        return true
    }
    private func serverMenu(for event: NSEvent) -> NSMenu? {
        let point = collection.convert(event.locationInWindow, from: nil)
        guard let path = collection.indexPathForItem(at: point), let source = source(at: path.item) else { return nil }
        switch source {
        case .connected(let value): return onMenu?(value.id)
        case .saved(let value, _): return onSavedMenu?(value)
        }
    }
}
