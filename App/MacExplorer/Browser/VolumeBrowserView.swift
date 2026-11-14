import AppKit
import LocalStorage
import ExplorerCore

/// A view of supplied volume observations. It never queries volumes or writes to the clipboard.
@MainActor
final class VolumeBrowserView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: ((URL) -> Void)?
    var onAccessibleActivation: (() -> Bool)?
    var onSelectionChange: (() -> Void)?
    var onCopyPath: (([URL]) -> Void)?
    var onProperties: (([URL]) -> Void)?
    var onLocationMenu: ((BrowserLocation) -> NSMenu?)?
    var onDriveMenu: ((URL) -> NSMenu?)?
    var onValidateDrop: ((NSDraggingInfo, URL) -> NSDragOperation)?
    var onAcceptDrop: ((NSDraggingInfo, URL) -> Bool)?
    var onDragExited: (() -> Void)?
    var onVisibleDestinationsChanged: (() -> Void)?
    var motion = BrowserMotionPreferences() { didSet { visibleTiles.forEach { $0.motion = motion }; connectedServers.motion = motion } }
    private var visibleBoundsObservation: BrowserNotificationObservation?
    private var dropTarget: URL?
    var contentBackgroundIsTransparent = false {
        didSet {
            let solid = !contentBackgroundIsTransparent
            // Native color assignment can enable background drawing again.
            // Apply the requested paint policy after both colors are set.
            scrollView.backgroundColor = .controlBackgroundColor
            scrollView.contentView.backgroundColor = .controlBackgroundColor
            collectionView.backgroundColors = solid ? [.controlBackgroundColor] : [.clear]
            scrollView.drawsBackground = solid
            scrollView.contentView.drawsBackground = solid
        }
    }

    var onBack: (() -> Void)? {
        get { collectionView.onBack }
        set { collectionView.onBack = newValue; connectedServers.onBack = newValue }
    }

    var onCopy: (() -> Void)? {
        get { collectionView.onCopy }
        set { collectionView.onCopy = newValue }
    }

    let collectionView = VolumeCollectionView()
    let scrollView = NSScrollView()
    let connectedServers = ConnectedServersView(frame: .zero)
    private let document = ThisMacDocumentView()
    private let heading = label("Devices and drives (0)", size: 15, weight: .medium)
    private let flow = BrowserLocationFlowLayout()
    private var volumes: [VolumeInfo] = []
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("VolumeBrowserTile")

    var behavior: BrowserBehaviorPreferences {
        get { collectionView.behavior }
        set { collectionView.behavior = newValue; connectedServers.behavior = newValue }
    }

    var explorerKeysEnabled: Bool {
        get { collectionView.explorerKeysEnabled }
        set { collectionView.explorerKeysEnabled = newValue }
    }

    var selectedURLs: [URL] {
        collectionView.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap {
            volumes.indices.contains($0.item) ? volumes[$0.item].url : nil
        }
    }

    var selectedCount: Int { selectedURLs.count }
    var tileCount: Int { volumes.count }
    var visibleTiles: [VolumeTileItem] { collectionView.visibleItems().compactMap { $0 as? VolumeTileItem } }
    var visibleDropURLs: [URL] {
        collectionView.indexPathsForVisibleItems().sorted { $0.item < $1.item }.compactMap {
            guard volumes.indices.contains($0.item), volumes[$0.item].isReadOnly != true else { return nil }
            return volumes[$0.item].url
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        flow.itemSize = NSSize(width: 300, height: 76)
        flow.scrollDirection = .vertical
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(VolumeTileItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.setAccessibilityLabel("Devices and drives")
        // The shared document lays out both grids explicitly. A width mask
        // would apply the document's resize delta a second time to this grid.
        collectionView.autoresizingMask = []
        collectionView.frame = NSRect(x: 0, y: 0, width: 300, height: 76)
        collectionView.onOpenSelection = { [weak self] in self?.openSelection() }
        collectionView.onSelectAll = { [weak self] in self?.selectAll() }
        collectionView.onFocusChange = { [weak self] in self?.updateSelectionAppearance() }
        collectionView.onContextMenu = { [weak self] event in self?.contextMenu(for: event) }
        collectionView.registerForDraggedTypes([.fileURL, ArchiveMemberDragSource.pasteboardType,
            RemoteDownloadDrag.pasteboardType])
        collectionView.onValidateFileDrop = { [weak self] info in self?.validateFileDrop(info) ?? [] }
        collectionView.onAcceptFileDrop = { [weak self] info in self?.acceptFileDrop(info) ?? false }
        collectionView.onFileDragExited = { [weak self] in
            self?.setDropTarget(nil); self?.onDragExited?()
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        visibleBoundsObservation = BrowserNotificationObservation(name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView) { [weak self] _ in
            MainActor.assumeIsolated { self?.onVisibleDestinationsChanged?() }
        }

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        document.addSubview(heading); document.addSubview(collectionView)
        document.addSubview(connectedServers); connectedServers.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let padding = InterfaceMetrics.points(12)
        let width = max(1, scrollView.contentView.bounds.width - 2 * padding)
        flow.configure(width: width)
        let headingHeight = InterfaceMetrics.points(20)
        heading.frame = NSRect(x: padding, y: InterfaceMetrics.points(10), width: width, height: headingHeight)
        let top = heading.frame.maxY + InterfaceMetrics.points(8)
        let driveHeight = flow.contentHeight(items: volumes.count, width: width)
        collectionView.frame = NSRect(x: padding, y: top, width: width, height: driveHeight)
        var end = collectionView.frame.maxY
        if !connectedServers.isHidden {
            let serverHeight = connectedServers.preferredHeight(for: width)
            connectedServers.frame = NSRect(x: padding, y: end + InterfaceMetrics.points(20), width: width, height: serverHeight)
            connectedServers.needsLayout = true
            end = connectedServers.frame.maxY
        }
        document.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width,
            height: max(scrollView.contentView.bounds.height, end + padding))
        onVisibleDestinationsChanged?()
    }
    func updateConnections(_ values: [BrowserConnectedLocation], saved: [WorkspaceConnectionBookmark] = [],
                           notice: String = "", progress: [WorkspaceConnectionBookmark: String] = [:]) {
        connectedServers.update(values, saved: saved, notice: notice, progress: progress)
        connectedServers.isHidden = connectedServers.itemCount == 0
        needsLayout = true
    }

    func update(volumes: [VolumeInfo]) {
        let retained = Set(selectedURLs)
        self.volumes = volumes
        heading.stringValue = "Devices and drives (\(volumes.count))"
        setDropTarget(nil)
        collectionView.reloadData()
        needsLayout = true
        setSelection(retained)
        onVisibleDestinationsChanged?()
    }

    func setSelection(_ urls: Set<URL>) {
        collectionView.selectionIndexPaths = Set(volumes.indices.compactMap {
            urls.contains(volumes[$0].url) ? IndexPath(item: $0, section: 0) : nil
        })
        updateSelectionAppearance()
        onSelectionChange?()
    }

    func selectAll() {
        collectionView.selectionIndexPaths = Set(volumes.indices.map { IndexPath(item: $0, section: 0) })
        updateSelectionAppearance()
        onSelectionChange?()
    }

    func openSelection() {
        let selected = selectedURLs
        guard selected.count == 1, let url = selected.first else { return }
        onOpen?(url)
    }

    func focus() { window?.makeFirstResponder(collectionView) }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        volumes.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        if let tile = item as? VolumeTileItem, volumes.indices.contains(indexPath.item) {
            tile.onOpen = { [weak self] url in self?.onOpen?(url) }
            tile.onAccessibleActivation = { [weak self, weak tile] in
                guard let self, let tile, let volume = tile.volume,
                      self.volumes.contains(where:{$0.url == volume.url}), self.collectionView.isSelectable,
                      NativeAccessibleAction.canInvoke(self) else { return false }
                return self.onAccessibleActivation?() ?? true
            }
            tile.configure(volumes[indexPath.item], emphasized: selectionIsEmphasized)
            tile.motion = motion
            tile.isDropTarget = volumes[indexPath.item].url == dropTarget
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionAppearance()
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionAppearance()
        onSelectionChange?()
    }

    private func destination(for info: NSDraggingInfo) -> URL? {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), volumes.indices.contains(path.item),
              volumes[path.item].isReadOnly != true else { return nil }
        return volumes[path.item].url
    }

    private func validateFileDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let url = destination(for: info) else { setDropTarget(nil); return [] }
        let operation = onValidateDrop?(info, url) ?? []
        setDropTarget(operation.isEmpty ? nil : url)
        return operation
    }

    private func acceptFileDrop(_ info: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil); onDragExited?() }
        guard let url = destination(for: info) else { return false }
        return onAcceptDrop?(info, url) ?? false
    }

    private func setDropTarget(_ url: URL?) {
        guard dropTarget != url else { return }
        dropTarget = url
        for tile in visibleTiles { tile.isDropTarget = tile.volume?.url == url && url != nil }
    }

    private var selectionIsEmphasized: Bool {
        window?.isKeyWindow == true && window?.firstResponder === collectionView
    }

    private func updateSelectionAppearance() {
        for item in visibleTiles { item.emphasized = selectionIsEmphasized }
        connectedServers.refreshSelectionAppearance()
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateSelectionAppearance()
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), volumes.indices.contains(path.item) else { return nil }
        if !collectionView.selectionIndexPaths.contains(path) {
            collectionView.selectionIndexPaths = [path]
            updateSelectionAppearance()
            onSelectionChange?()
        }
        if let menu = onLocationMenu?(.directory(volumes[path.item].url)) { return menu }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open", action: #selector(openContextSelection(_:)), keyEquivalent: "")
        open.target = self
        open.isEnabled = selectedCount == 1
        menu.addItem(open)
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copyContextPath(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = onCopyPath != nil
        menu.addItem(copy)
        menu.addItem(.separator())
        let properties = NSMenuItem(title: "Properties…", action: #selector(showContextProperties(_:)), keyEquivalent: "")
        properties.target = self
        properties.isEnabled = onProperties != nil
        menu.addItem(properties)
        if selectedCount == 1, let url = selectedURLs.first, let actions = onDriveMenu?(url) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
            item.submenu = actions; menu.addItem(item)
        }
        return menu
    }

    @objc private func openContextSelection(_ sender: Any?) { openSelection() }
    @objc private func copyContextPath(_ sender: Any?) { onCopyPath?(selectedURLs) }
    @objc private func showContextProperties(_ sender: Any?) { onProperties?(selectedURLs) }
}

@MainActor
final class VolumeCollectionView: NSCollectionView {
    var onShortcut: ((NSEvent) -> Bool)?
    private let pointerSelection = BrowserPointerSelection()
    var behavior = BrowserBehaviorPreferences.explorer { didSet { if behavior != oldValue { pointerSelection.cancel() } } }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: pointerSelection.begin(event, in: self, behavior: behavior,
            isEditingText: BrowserPointerSelection.isEditingText(in: self)))
    }
    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: pointerSelection.continuing(event, in: self)) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: pointerSelection.continuing(event, in: self)) }
    override func viewDidMoveToWindow() { pointerSelection.cancel(); super.viewDidMoveToWindow() }
    var explorerKeysEnabled: Bool {
        get { behavior == .explorer }
        set { behavior = newValue ? .explorer : .mac }
    }
    var onOpenSelection: (() -> Void)?
    var onBack: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onFocusChange: (() -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onValidateFileDrop: ((NSDraggingInfo) -> NSDragOperation)?
    var onAcceptFileDrop: ((NSDraggingInfo) -> Bool)?
    var onFileDragExited: (() -> Void)?

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onValidateFileDrop?(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onValidateFileDrop?(sender) ?? [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(onValidateFileDrop?(sender) ?? []).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onAcceptFileDrop?(sender) ?? false }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFileDragExited?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onFileDragExited?() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?()
            DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        pointerSelection.cancel()
        let accepted = super.resignFirstResponder()
        if accepted {
            // AppKit changes the window's first responder after this method returns.
            DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if let onShortcut {
            if onShortcut(event) { return }
            super.keyDown(with: event); return
        }
        if let action = behavior.fileAction(for: event) {
            switch action {
            case .open: onOpenSelection?(); return
            case .back: onBack?(); return
            default: break // Drive renaming/Trash/preview are separate capabilities.
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if BrowserPointerSelection.isSelectionAlias(event, in: self, behavior: behavior,
            isEditingText: BrowserPointerSelection.isEditingText(in: self)) { return nil }
        return onContextMenu?(event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() }
        else { super.selectAll(sender) }
    }
}

@MainActor
final class VolumeTileItem: NSCollectionViewItem, NSGestureRecognizerDelegate {
    var motion = BrowserMotionPreferences() { didSet { (view as? BrowserLocationTileBackground)?.motion = motion } }
    var emphasized = false { didSet { refreshAppearance() } }
    var isDropTarget = false { didSet { refreshAppearance() } }
    var onOpen: ((URL) -> Void)?
    var onAccessibleActivation: (() -> Bool)?
    private(set) var volume: VolumeInfo?
    private let driveImage = NSImageView()
    private let nameLabel = label("", size: 13, weight: .medium)
    private let capacityLabel = label("", size: 11, color: .secondaryLabelColor)
    private let usageBar = VolumeUsageBar()

    var isHovered: Bool { (view as? BrowserLocationTileBackground)?.isHovered == true }

    #if DEBUG
    func setHoveredForVerification(_ hovered: Bool) {
        (view as? BrowserLocationTileBackground)?.setHovered(hovered)
    }
    #endif

    override var isSelected: Bool { didSet { refreshAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet {
        refreshAppearance()
        #if DEBUG
        SelectionGestureEvidence.observe(kind: "volume", state: highlightState, committed: isSelected)
        #endif
    } }

    override func loadView() {
        let tile = BrowserLocationTileBackground()
        view = tile
        for child in [driveImage, nameLabel, usageBar, capacityLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.setAccessibilityElement(false)
            tile.addSubview(child)
        }
        driveImage.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        capacityLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            driveImage.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            driveImage.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            driveImage.widthAnchor.constraint(equalToConstant: 40).interfaceScaled,
            driveImage.heightAnchor.constraint(equalToConstant: 40).interfaceScaled,
            nameLabel.leadingAnchor.constraint(equalTo: driveImage.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: tile.topAnchor, constant: 11),
            usageBar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usageBar.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            usageBar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            usageBar.heightAnchor.constraint(equalToConstant: 5).interfaceScaled,
            capacityLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            capacityLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            capacityLabel.topAnchor.constraint(equalTo: usageBar.bottomAnchor, constant: 5),
            capacityLabel.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -10),
        ])
        tile.setAccessibilityElement(true)
        tile.setAccessibilityRole(.cell)
        tile.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open", target: self, selector: #selector(performAccessibleOpen(_:)))
        ])
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(openDoubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.buttonMask = 1
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delegate = self
        tile.addGestureRecognizer(doubleClick)
    }

    func configure(_ volume: VolumeInfo, emphasized: Bool) {
        _ = view
        (view as? BrowserLocationTileBackground)?.setHovered(false, animated: false)
        self.volume = volume
        self.emphasized = emphasized
        nameLabel.stringValue = volume.name
        let icon: String
        let kind: String
        switch volume.kind {
        case .internalDisk: icon = "internaldrive"; kind = "Internal disk"
        case .externalDisk: icon = "externaldrive"; kind = "External disk"
        case .network: icon = "network"; kind = "Network volume"
        case .unknown: icon = "externaldrive.badge.questionmark"; kind = "Details unavailable"
        }
        driveImage.image = symbol(icon, "Drive") ?? symbol("externaldrive", "Drive")
        let capacity: String
        if let free = volume.availableBytes, let total = volume.totalBytes, total > 0, free >= 0 {
            capacity = "\(FileSizeText.string(free)) free of \(FileSizeText.string(total))"
            usageBar.fraction = min(1, max(0, 1 - Double(free) / Double(total)))
            usageBar.isHidden = false
        } else {
            capacity = "Capacity unavailable"
            usageBar.fraction = 0
            usageBar.isHidden = true
        }
        capacityLabel.stringValue = capacity
        let access = volume.isReadOnly == true ? "Read only" : volume.isReadOnly == nil ? "Access details unavailable" : ""
        let summary = [volume.name, kind, capacity, access].filter { !$0.isEmpty }.joined(separator: ", ")
        view.setAccessibilityLabel(summary)
        view.setAccessibilityHelp("Double-click to open. Volume capacities may share underlying storage.")
        view.toolTip = "\(summary)\n\(volume.url.path)\nVolume capacities may share underlying storage."
        refreshAppearance()
    }

    private func refreshAppearance() {
        guard isViewLoaded, let tile = view as? BrowserLocationTileBackground else { return }
        let selected = displaysSelection
        tile.selected = selected
        tile.emphasized = emphasized
        tile.isDropTarget = isDropTarget
        tile.setAccessibilitySelected(isSelected)
        let foreground: NSColor = selected && emphasized ? .alternateSelectedControlTextColor
            : selected ? .unemphasizedSelectedTextColor : .labelColor
        nameLabel.textColor = foreground
        capacityLabel.textColor = selected ? foreground : .secondaryLabelColor
        driveImage.contentTintColor = selected ? foreground : .secondaryLabelColor
        usageBar.selected = selected && emphasized
        tile.needsDisplay = true
    }

    @objc func performAccessibleOpen(_ action: NSAccessibilityCustomAction) -> Bool {
        // Read the current observation, rather than capture a URL from a previous reuse.
        guard let volume, let onOpen, isViewLoaded, NativeAccessibleAction.canInvoke(view),
              NativeAccessibleAction.activateWindow(view), onAccessibleActivation?() != false else { return false }
        guard self.volume?.url == volume.url, NativeAccessibleAction.canInvoke(view) else { return false }
        onOpen(volume.url)
        return true
    }

    @objc private func openDoubleClicked(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, let volume else { return }
        onOpen?(volume.url)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        // Opening a tile must leave the collection's native selection and
        // file-drop recognizers available, including the first click of a drag.
        true
    }
}

@MainActor
final class BrowserLocationTileBackground: NSView {
    var motion = BrowserMotionPreferences() { didSet { hoverOutline.removeAnimation(forKey: "hover") } }
    var selected = false
    var emphasized = false
    var isDropTarget = false
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private let hoverOutline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverOutline.fillColor = NSColor.clear.cgColor
        hoverOutline.opacity = 0
        layer?.addSublayer(hoverOutline)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false, animated: false) }
    }

    override func layout() {
        super.layout()
        refreshHoverOutline()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshHoverOutline()
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        refreshHoverOutline()
        let destination: Float = hovered ? 1 : 0
        let previous = hoverOutline.presentation()?.opacity ?? hoverOutline.opacity
        hoverOutline.removeAnimation(forKey: "hover")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverOutline.opacity = destination
        CATransaction.commit()
        if animated && motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = previous; fade.toValue = destination; fade.duration = 0.14 * motion.mode.durationScale
            hoverOutline.add(fade, forKey: "hover")
        }
    }

    private func refreshHoverOutline() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hoverOutline.path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 5, cornerHeight: 5, transform: nil)
            hoverOutline.strokeColor = (contrast ? NSColor.labelColor : NSColor.controlAccentColor.withAlphaComponent(0.55)).cgColor
            hoverOutline.lineWidth = contrast ? 2 : 1
            CATransaction.commit()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        if selected {
            (emphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
            rect.fill()
        }
        if isDropTarget {
            NSColor.controlAccentColor.setStroke()
            rect.lineWidth = 2
            rect.stroke()
        }
    }
}

/// AppKit flow layout distributes spare row width between columns. Retain its
/// native wrapping/navigation but anchor each column at the requested spacing.
@MainActor
final class BrowserLocationFlowLayout: NSCollectionViewFlowLayout {
    func configure(width: CGFloat) {
        let size = NSSize(width: min(InterfaceMetrics.points(300), max(1, width)), height: InterfaceMetrics.points(76))
        minimumInteritemSpacing = InterfaceMetrics.points(12); minimumLineSpacing = InterfaceMetrics.points(8)
        if itemSize != size { itemSize = size; invalidateLayout() }
    }
    func contentHeight(items: Int, width: CGFloat) -> CGFloat {
        guard items > 0 else { return 1 }
        let columns = max(1, Int((max(1, width) + minimumInteritemSpacing) / (itemSize.width + minimumInteritemSpacing)))
        let rows = (items + columns - 1) / columns
        return CGFloat(rows) * (itemSize.height + minimumLineSpacing) - minimumLineSpacing
    }

    private func compact(_ original: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        let attributes = original.copy() as! NSCollectionViewLayoutAttributes
        guard attributes.representedElementCategory == .item, let indexPath = attributes.indexPath,
              let collectionView else { return attributes }
        let available = max(1, collectionView.bounds.width - sectionInset.left - sectionInset.right)
        let columns = max(1, Int((available + minimumInteritemSpacing) / (itemSize.width + minimumInteritemSpacing)))
        let column = indexPath.item % columns
        attributes.frame.origin.x = sectionInset.left + CGFloat(column) * (itemSize.width + minimumInteritemSpacing)
        attributes.frame.size.width = min(itemSize.width, available)
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: indexPath).map(compact)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Query the full row before compacting: hit testing may request a narrow
        // rectangle at the new position rather than the original justified one.
        let rowRect = NSRect(x: 0, y: rect.minY, width: collectionView?.bounds.width ?? rect.width, height: rect.height)
        return super.layoutAttributesForElements(in: rowRect).map(compact).filter { $0.frame.intersects(rect) }
    }
}

@MainActor
private final class VolumeUsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.25) : .quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let used = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * CGFloat(fraction), height: bounds.height)
        (selected ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).setFill()
        NSBezierPath(roundedRect: used, xRadius: 2, yRadius: 2).fill()
    }
}

@MainActor private final class ThisMacDocumentView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
