import AppKit
import ExplorerCore
import QuartzCore

/// Tabs share their active surface with the address row below. Window chrome
/// remains system-owned; only this browser's tab presentation is custom.
@MainActor
final class TabStripView: NSView, NSDraggingSource, NSMenuDelegate {
    var drawsSolidBackground = true { didSet { needsDisplay = true } }
    var isGlassEnabled = false {
        didSet { for item in items { item.isGlassEnabled = isGlassEnabled }; needsDisplay = true }
    }
    private let scroll = NSScrollView()
    private let document = NSView()
    let addButton = ActionButton(title: "", image: symbol("plus", "New tab"), action: {})
    let profileButton = ActionButton(title: "", image: symbol("square.stack.3d.up", "Workspace profile"), action: {})
    private var profileName: String?, profileDetail = ""
    private let previous = ActionButton(title: "", image: symbol("chevron.left", "Scroll tabs left"), action: {})
    private let next = ActionButton(title: "", image: symbol("chevron.right", "Scroll tabs right"), action: {})
    private var items: [BrowserTabView] = []
    private var activeID: UUID?
    private var revealActive = false
    private var previousWidth: CGFloat = -1
    private(set) var isOverflowing = false
    private static let tabDragType = NSPasteboard.PasteboardType("local.macexplorer.browser-tab")
    private var activeDragID: UUID?
    private var activeDragSequence: Int?
    private var dragFrameRelativeToPointer: NSRect?
    private var insertionBefore: UUID?
    private var hasInsertion = false
    private var insertionX: CGFloat?
    private var insertionSourceID: UUID?
    private weak var insertionSource: TabStripView?
    private var insertionSequence: Int?
    private var insertionIsLocal = false
    private var tabWidth: CGFloat = 196
    private var animateNextLayout = false
    var motionEnabled = true { didSet { if !motionEnabled { motion.finish() } } }
    var motionMode: BrowserMotionMode {
        get { motion.mode }
        set { motion.mode = newValue }
    }
    private var enteringTabIDs = Set<UUID>()
    private let motion = TabStripMotion()
    #if DEBUG
    var hasMotionForVerification: Bool { motion.isAnimating }
    var retiringPicturesForVerification: Int { motion.retiringCount }
    #endif
    private weak var managementMenu: NSMenu?
    private weak var managementWindow: NSWindow?
    private var managementMenuID = UUID()

    var ownsManagementMenuContext: Bool {
        guard managementMenu != nil, let managementWindow, window === managementWindow else { return false }
        return managementWindow.isVisible && NSApplication.shared.isActive
            && NSApplication.shared.mainWindow === managementWindow
    }

    var onSelect: ((UUID) -> Void)?
    var onAccessibleActivation: ((UUID) -> Bool)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onDuplicate: ((UUID) -> Void)?
    var onReopenClosed: (() -> Void)?
    var onMove: ((UUID, UUID?) -> Void)?
    var onReceiveTab: ((TabStripView, UUID, UUID?) -> Bool)?
    var canReceiveTab: ((TabStripView, UUID) -> Bool)?
    var canDragTab: ((UUID) -> Bool)?
    var canManageTabs: (() -> Bool)?
    var canCreateTab: (() -> Bool)?
    var canReopenClosed: (() -> Bool)?
    var onDragMoved: ((TabStripView, NSPoint, NSRect?) -> Void)?
    var onDragEnded: (() -> Void)?
    var onRouteTabDrag: ((NSDraggingInfo, WorkspaceTabDropPhase) -> NSDragOperation)?
    var onRouteTabDragExit: ((NSDraggingInfo?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.wantsLayer = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        for button in [addButton, previous, next] {
            button.isBordered = false
            button.bezelStyle = .recessed
            addSubview(button)
        }
        addButton.toolTip = "New Tab (⌘T / Ctrl+T)"
        addButton.setAccessibilityLabel("New tab")
        profileButton.isHidden = true; profileButton.wantsLayer = true
        profileButton.bezelStyle = .recessed; profileButton.isBordered = true
        InterfaceMetrics.setFont(profileButton, base: .systemFont(ofSize: 11)); profileButton.imagePosition = .imageLeading
        profileButton.cell?.lineBreakMode = .byTruncatingTail
        addSubview(profileButton)
        previous.setAccessibilityLabel("Scroll tabs left")
        next.setAccessibilityLabel("Scroll tabs right")
        addButton.actionHandler = { [weak self] in
            guard let self, self.creationAllowed else { return }
            self.onNew?()
        }
        previous.actionHandler = { [weak self] in self?.scrollTabs(direction: -1) }
        next.actionHandler = { [weak self] in self?.scrollTabs(direction: 1) }
        setAccessibilityLabel("Browser tabs")
        registerForDraggedTypes([Self.tabDragType])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if drawsSolidBackground {
            NSColor.windowBackgroundColor.setFill()
            bounds.intersection(dirtyRect).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if let insertionX {
            NSColor.controlAccentColor.setFill()
            NSRect(x: insertionX - 1, y: 3, width: 2, height: max(0, bounds.height - 6)).fill()
        }
    }

    func update(tabs: [BrowserTab], activeID: UUID) {
        if let activeDragID, !tabs.contains(where: { $0.id == activeDragID }) { invalidateManagementInteraction() }
        let oldIDs = items.map(\.id)
        let existing = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items where !tabs.contains(where: { $0.id == item.id }) {
            if motionEnabled && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                motion.retire(item, in: self, visible: scroll.convert(scroll.bounds, to: self))
            }
            item.removeFromSuperview() // input/drag authority ends immediately
        }
        if !oldIDs.isEmpty { enteringTabIDs.formUnion(tabs.map(\.id).filter { existing[$0] == nil }) }
        items = tabs.map { tab in
            let item = existing[tab.id] ?? BrowserTabView(id: tab.id)
            item.isGlassEnabled = isGlassEnabled
            item.configure(tab: tab, selected: tab.id == activeID)
            item.choose.actionHandler = { [weak self] in self?.onSelect?(tab.id) }
            item.close.actionHandler = { [weak self] in self?.motion.finish(); self?.onClose?(tab.id) }
            item.choose.onMiddleClick = { [weak self] in self?.motion.finish(); self?.onClose?(tab.id) }
            item.choose.onInteraction = { [weak self] in self?.motion.finish() }
            item.choose.onAccessibleActivation = { [weak self, weak item] in
                guard let self, let item, self.items.contains(where:{$0 === item && $0.id == tab.id}) else { return false }
                return self.onAccessibleActivation?(tab.id) ?? true
            }
            item.choose.onBeginDrag = { [weak self, weak item] event in
                guard let item else { return }
                self?.beginTabDrag(id: tab.id, view: item, event: event)
            }
            item.choose.onMoveLeft = { [weak self] in self?.moveTab(tab.id, direction: -1) ?? false }
            item.choose.onMoveRight = { [weak self] in self?.moveTab(tab.id, direction: 1) ?? false }
            item.choose.onDuplicate = { [weak self] in
                guard let self, self.managementAllowed else { return false }
                self.onDuplicate?(tab.id); return self.onDuplicate != nil
            }
            item.choose.onContextMenu = { [weak self] in self?.contextMenu(for: tab.id) }
            item.onContextMenu = { [weak self] in self?.contextMenu(for: tab.id) }
            if item.superview == nil { document.addSubview(item) }
            return item
        }
        revealActive = revealActive || self.activeID != activeID || oldIDs != tabs.map(\.id)
        if !oldIDs.isEmpty && oldIDs != tabs.map(\.id) { animateNextLayout = true }
        self.activeID = activeID
        refreshManagementAvailability()
        needsLayout = true
        needsDisplay = true
    }

    func refreshManagementAvailability() {
        for item in items { item.close.isEnabled = managementAllowed }
        addButton.isEnabled = creationAllowed
    }

    private var managementAllowed: Bool { canManageTabs?() ?? true }
    private var creationAllowed: Bool { canCreateTab?() ?? managementAllowed }

    func setProfile(name: String?, detail: String, action: @escaping () -> Void) {
        profileButton.actionHandler = action
        guard name != profileName || detail != profileDetail else { return }
        let changed = name != profileName, entering = profileName == nil && name != nil
        profileName = name; profileDetail = detail
        profileButton.setAccessibilityLabel(name.map { "Profile \($0). \(detail). Open profile switcher." } ?? "Workspace profiles")
        profileButton.toolTip = name.map { "\($0) · \(detail)" }
        if changed { previousWidth = -1; needsLayout = true }
        if name == nil { profileButton.isHidden = true; profileButton.layer?.removeAllAnimations() }
        else if entering && motionEnabled && motionMode != .off && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = motionMode.initialOpacity(0.4); animation.toValue = 1
            animation.duration = 0.16 * motionMode.durationScale
            profileButton.layer?.add(animation, forKey: "profile-entrance")
        }
    }

    override func layout() {
        super.layout()
        let resized = previousWidth != bounds.width
        previousWidth = bounds.width
        let oldFrames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, motion.visualFrame(of: $0)) })
        let oldAddFrame = motion.visualFrame(of: addButton)
        if resized || !motionEnabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { motion.finish() }
        profileButton.isHidden = profileName == nil || bounds.width < 280
        let title = bounds.width < 420 ? "" : profileName ?? ""
        if profileButton.title != title { profileButton.title = title }
        let profileWidth = profileButton.isHidden ? 0 : min(164, max(title.isEmpty ? 28 : 68, profileButton.intrinsicContentSize.width))
        let reserved = profileWidth > 0 ? profileWidth + 8 : 0
        let available = max(0, bounds.width - 24 - reserved)
        profileButton.frame = NSRect(x: max(0, bounds.width - profileWidth - 6), y: 5, width: profileWidth, height: max(26, bounds.height - 10))
        let width = min(InterfaceMetrics.points(196), max(InterfaceMetrics.points(144), (available - 36) / CGFloat(max(1, items.count))))
        tabWidth = width
        let externalGap = hasInsertion && !insertionIsLocal ? width : 0
        let total = width * CGFloat(items.count) + externalGap
        isOverflowing = total + 36 > available
        let controls: CGFloat = isOverflowing ? 40 : 0
        let viewport = min(total, max(0, available - 36 - controls))
        let x: CGFloat = isOverflowing ? 32 : 12
        scroll.frame = NSRect(x: x, y: 0, width: viewport, height: bounds.height)
        document.frame = NSRect(x: 0, y: 0, width: max(total, viewport), height: bounds.height)
        var arranged = items
        if hasInsertion, insertionIsLocal, let id = insertionSourceID,
           let moving = arranged.first(where: { $0.id == id }) {
            arranged.removeAll { $0.id == id }
            let index = insertionBefore.flatMap { before in arranged.firstIndex { $0.id == before } } ?? arranged.count
            arranged.insert(moving, at: index)
        }
        let gapIndex = insertionBefore.flatMap { before in arranged.firstIndex { $0.id == before } } ?? arranged.count
        let animate = motionEnabled && animateNextLayout && !resized && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate { motion.beginLayout() }
        for (index, item) in arranged.enumerated() {
            let offset = externalGap > 0 && index >= gapIndex ? externalGap : 0
            item.frame = NSRect(x: CGFloat(index) * width + offset, y: 0, width: width, height: max(0, bounds.height - 2))
            item.alphaValue = item.id == activeDragID ? 0.3 : 1
            if animate { motion.place(item, from: oldFrames[item.id] ?? item.frame, entering: enteringTabIDs.contains(item.id)) }
        }
        if hasInsertion {
            let index = insertionIsLocal ? arranged.firstIndex(where: { $0.id == insertionSourceID }) ?? gapIndex : gapIndex
            insertionX = convert(NSPoint(x: CGFloat(index) * width, y: 0), from: document).x
        }
        previous.isHidden = !isOverflowing
        next.isHidden = !isOverflowing
        previous.frame = NSRect(x: 10, y: 5, width: 20, height: max(26, bounds.height - 10))
        next.frame = NSRect(x: scroll.frame.maxX + 2, y: 5, width: 20, height: max(26, bounds.height - 10))
        addButton.frame = NSRect(x: scroll.frame.maxX + (isOverflowing ? 24 : 4), y: 5, width: 28, height: max(26, bounds.height - 10))
        if animate { motion.place(addButton, from: oldAddFrame); motion.endLayout() }
        animateNextLayout = false; enteringTabIDs.removeAll()
        if revealActive || resized, let active = items.first(where: { $0.id == activeID }) {
            active.scrollToVisible(active.bounds)
            revealActive = false
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func selectionButton(for id: UUID) -> NSButton? { items.first { $0.id == id }?.choose }
    func closeButton(for id: UUID) -> NSButton? { items.first { $0.id == id }?.close }
    var activeTabFrame: NSRect? { items.first { $0.id == activeID }.map { $0.convert($0.bounds, to: self) } }
    var lastTabFrame: NSRect? { items.last.map { $0.convert($0.bounds, to: self) } }
    /// Presentation-only capture. Identity and drop authority still come from
    /// the live drag session; an image cannot authenticate or commit a move.
    func paneTransitionFrame(for id: UUID, in parent: NSView) -> WorkspacePaneTransition.Frame? {
        guard window === parent.window, let item = items.first(where: { $0.id == id }),
              !item.isHiddenOrHasHiddenAncestor, item.bounds.width > 1,
              let rep = item.bitmapImageRepForCachingDisplay(in: item.bounds) else { return nil }
        item.cacheDisplay(in: item.bounds, to: rep)
        let image = NSImage(size: item.bounds.size); image.addRepresentation(rep)
        return .init(rect: item.convert(item.bounds, to: parent), image: image)
    }
    var activeTabIsVisible: Bool {
        guard let active = items.first(where: { $0.id == activeID }) else { return false }
        return scroll.contentView.bounds.contains(active.frame)
    }

    /// Local tab identity is authenticated by the actual dragging source and
    /// retained ID. Pasteboard strings never grant authority to another app.
    private func beginTabDrag(id: UUID, view: NSView, event: NSEvent) {
        guard managementAllowed, items.count > 1 || canDragTab?(id) == true,
              items.contains(where: { $0.id == id }) else { return }
        motion.finish()
        activeDragID = id
        needsLayout = true
        if let window {
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            dragFrameRelativeToPointer = frame.offsetBy(dx: -pointer.x, dy: -pointer.y)
        }
        let writer = NSPasteboardItem()
        writer.setString(id.uuidString, forType: Self.tabDragType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: view.bounds.size)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(view.convert(view.bounds, to: self), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        activeDragSequence = session.draggingSequenceNumber
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    static var tabDragPasteboardType: NSPasteboard.PasteboardType { tabDragType }

    /// Only a live native source with a retained tab and exact drag sequence
    /// grants authority. The pasteboard string is a consistency check only.
    static func authenticatedDrag(_ info: NSDraggingInfo) -> (strip: TabStripView, tabID: UUID)? {
        guard let source = info.draggingSource as? TabStripView,
              source.managementAllowed, let id = source.activeDragID,
              source.activeDragSequence == info.draggingSequenceNumber,
              source.items.contains(where: { $0.id == id }),
              info.draggingSourceOperationMask.contains(.move),
              info.draggingPasteboard.string(forType: tabDragType) == id.uuidString else { return nil }
        return (source, id)
    }

    var liveTabDrag: (id: UUID, sequence: Int)? {
        guard managementAllowed, let activeDragID, let activeDragSequence,
              items.contains(where: { $0.id == activeDragID }) else { return nil }
        return (activeDragID, activeDragSequence)
    }

    static func dragFootprint(_ info: NSDraggingInfo, in window: NSWindow) -> NSRect? {
        guard let drag = authenticatedDrag(info), info.draggingDestinationWindow === window,
              drag.strip.window === window, let relative = drag.strip.dragFrameRelativeToPointer else { return nil }
        let pointer = window.convertPoint(toScreen: info.draggingLocation)
        return window.convertFromScreen(relative.offsetBy(dx: pointer.x, dy: pointer.y))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication && managementAllowed ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard activeDragSequence == session.draggingSequenceNumber else { return }
        invalidateManagementInteraction()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard activeDragSequence == session.draggingSequenceNumber else { return }
        updateDragPreview(at: screenPoint)
    }

    private func updateDragPreview(at screenPoint: NSPoint) {
        guard let activeDragID, items.contains(where: { $0.id == activeDragID }) else { return }
        onDragMoved?(self, screenPoint, dragFrameRelativeToPointer.map { $0.offsetBy(dx: screenPoint.x, dy: screenPoint.y) })
    }

    func invalidateManagementInteraction() {
        motion.finish()
        activeDragID = nil; activeDragSequence = nil; dragFrameRelativeToPointer = nil; clearInsertion()
        needsLayout = true
        onDragEnded?()
        managementMenu = nil; managementWindow = nil; managementMenuID = UUID()
    }

    #if DEBUG
    /// Seeds only the authenticated source registry for controlled native callback
    /// tests. It never creates a dragging session or writes a pasteboard.
    func registerTabDragForVerification(id: UUID, sequence: Int, previewRelativeToPointer: NSRect? = nil) -> NSPasteboard.PasteboardType? {
        guard managementAllowed, items.contains(where: { $0.id == id }) else { return nil }
        activeDragID = id; activeDragSequence = sequence
        dragFrameRelativeToPointer = previewRelativeToPointer
        return Self.tabDragType
    }
    func moveTabDragForVerification(to point: NSPoint) { updateDragPreview(at: point) }
    var hasInsertionPreviewForVerification: Bool { hasInsertion }
    #endif

    /// A retained native source footprint may overlap a destination while its
    /// pointer is just outside it. Prefer the actual pointer whenever possible;
    /// the nearest point of a positive-area overlap resolves corners stably.
    /// AppKit still chooses which registered destination receives callbacks.
    static func dragPoint(_ info: NSDraggingInfo, in view: NSView, region: NSRect) -> NSPoint? {
        guard let drag = authenticatedDrag(info) else { return nil }
        let pointer = view.convert(info.draggingLocation, from: nil)
        if region.contains(pointer) { return pointer }
        guard let window = view.window, info.draggingDestinationWindow === window,
              let relative = drag.strip.dragFrameRelativeToPointer else { return nil }
        let screenPointer = window.convertPoint(toScreen: info.draggingLocation)
        let footprint = view.convert(window.convertFromScreen(relative.offsetBy(dx: screenPointer.x, dy: screenPointer.y)), from: nil)
        return overlapPoint(pointer: pointer, footprint: footprint, region: region)
    }

    static func overlapPoint(pointer: NSPoint, footprint: NSRect, region: NSRect) -> NSPoint? {
        let overlap = footprint.intersection(region)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
        let insetX = min(0.5, overlap.width / 2), insetY = min(0.5, overlap.height / 2)
        return NSPoint(x: min(overlap.maxX - insetX, max(overlap.minX + insetX, pointer.x)),
                       y: min(overlap.maxY - insetY, max(overlap.minY + insetY, pointer.y)))
    }

    private func updateInsertion(_ info: NSDraggingInfo, routedPoint: NSPoint? = nil) -> NSDragOperation {
        guard let drag = Self.authenticatedDrag(info),
              drag.strip === self ? managementAllowed : canReceiveTab?(drag.strip, drag.tabID) == true else {
            clearInsertion(); return []
        }
        guard let point = routedPoint ?? Self.dragPoint(info, in: self, region: scroll.frame) else { clearInsertion(); return [] }
        let documentPoint = document.convert(point, from: self)
        let candidates = drag.strip === self ? items.filter { $0.id != drag.tabID } : items
        let before = candidates.enumerated().first { documentPoint.x < (CGFloat($0.offset) + 0.5) * tabWidth }?.element
        let changed = !hasInsertion || insertionBefore != before?.id || insertionSourceID != drag.tabID
        insertionBefore = before?.id
        hasInsertion = true
        insertionSourceID = drag.tabID
        insertionSource = drag.strip
        insertionSequence = info.draggingSequenceNumber
        insertionIsLocal = drag.strip === self
        if changed { animateNextLayout = true; needsLayout = true; layoutSubtreeIfNeeded() }
        needsDisplay = true
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onRouteTabDrag?(sender, .update) ?? updateInsertion(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onRouteTabDrag?(sender, .update) ?? updateInsertion(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let onRouteTabDragExit { onRouteTabDragExit(sender) } else { clearInsertion() }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(onRouteTabDrag?(sender, .prepare) ?? updateInsertion(sender)).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onRouteTabDrag { return !onRouteTabDrag(sender, .perform).isEmpty }
        return commitInsertion(sender)
    }

    func showRoutedInsertion(_ info: NSDraggingInfo, at windowPoint: NSPoint, commit: Bool) -> NSDragOperation {
        let point = convert(windowPoint, from: nil)
        if commit { return commitInsertion(info, routedPoint: point) ? .move : [] }
        return updateInsertion(info, routedPoint: point)
    }

    private func commitInsertion(_ sender: NSDraggingInfo, routedPoint: NSPoint? = nil) -> Bool {
        guard !updateInsertion(sender, routedPoint: routedPoint).isEmpty,
              let drag = Self.authenticatedDrag(sender), hasInsertion else { return false }
        let before = insertionBefore
        clearInsertion()
        if drag.strip === self {
            guard let onMove else { return false }
            onMove(drag.tabID, before)
            return true
        }
        return onReceiveTab?(drag.strip, drag.tabID, before) ?? false
    }

    private func clearInsertion() {
        if hasInsertion { animateNextLayout = true; needsLayout = true }
        insertionBefore = nil; hasInsertion = false; insertionSourceID = nil; insertionIsLocal = false
        insertionSource = nil; insertionSequence = nil
        insertionX = nil; needsDisplay = true
    }

    func clearDropPreview() { clearInsertion() }

    func clearDropPreview(matching source: TabStripView, sequence: Int) {
        if insertionSource === source && insertionSequence == sequence { clearInsertion() }
    }

    /// This source notification can only revoke the visual insertion preview.
    /// Destination callbacks still authenticate and negotiate every drop.
    func clearInsertionUnlessOverlapping(pointer screenPoint: NSPoint, footprint screenFrame: NSRect?) {
        guard hasInsertion, let window else { return }
        let pointer = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if scroll.frame.contains(pointer) { return }
        if let screenFrame,
           Self.overlapPoint(pointer: pointer, footprint: convert(window.convertFromScreen(screenFrame), from: nil),
                             region: scroll.frame) != nil { return }
        clearInsertion()
    }

    @discardableResult
    private func moveTab(_ id: UUID, direction: Int) -> Bool {
        guard managementAllowed, let index = items.firstIndex(where: { $0.id == id }), let onMove else { return false }
        if direction < 0 {
            guard index > 0 else { return false }
            onMove(id, items[index - 1].id)
        } else {
            guard index + 1 < items.count else { return false }
            onMove(id, index + 2 < items.count ? items[index + 2].id : nil)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu(for: nil) }

    func contextMenu(for id: UUID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = id?.uuidString; item.isEnabled = enabled
            menu.addItem(item)
        }
        if let id, let index = items.firstIndex(where: { $0.id == id }) {
            add("Duplicate Tab", #selector(duplicateContextTab(_:)), enabled: managementAllowed && onDuplicate != nil)
            add("Move Tab Left", #selector(moveContextTabLeft(_:)), enabled: managementAllowed && index > 0 && onMove != nil)
            add("Move Tab Right", #selector(moveContextTabRight(_:)), enabled: managementAllowed && index + 1 < items.count && onMove != nil)
            add("Close Tab", #selector(closeContextTab(_:)), enabled: managementAllowed && onClose != nil)
            menu.addItem(.separator())
        } else { add("New Tab", #selector(newContextTab(_:)), enabled: creationAllowed) }
        add("Reopen Closed Tab", #selector(reopenContextTab(_:)), enabled: managementAllowed && (canReopenClosed?() ?? false))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let window, window.isVisible, NSApplication.shared.isActive,
              NSApplication.shared.mainWindow === window else { return }
        managementMenu = menu; managementWindow = window; managementMenuID = UUID()
        for item in menu.items where !item.isSeparatorItem {
            let id = contextID(item)
            let index = id.flatMap { id in items.firstIndex { $0.id == id } }
            switch item.action {
            case #selector(duplicateContextTab(_:)): item.isEnabled = managementAllowed && index != nil && onDuplicate != nil
            case #selector(moveContextTabLeft(_:)): item.isEnabled = managementAllowed && (index ?? 0) > 0 && onMove != nil
            case #selector(moveContextTabRight(_:)): item.isEnabled = managementAllowed && index.map { $0 + 1 < items.count } == true && onMove != nil
            case #selector(closeContextTab(_:)): item.isEnabled = managementAllowed && index != nil && onClose != nil
            case #selector(reopenContextTab(_:)): item.isEnabled = managementAllowed && (canReopenClosed?() ?? false)
            case #selector(newContextTab(_:)): item.isEnabled = creationAllowed
            default: item.isEnabled = managementAllowed
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        let revision = managementMenuID
        // AppKit may send the selected action after menuDidClose. Its one
        // synchronous dispatch keeps the original browser window authority.
        Task { @MainActor [weak self, weak menu] in
            guard let self, let menu, self.managementMenu === menu, self.managementMenuID == revision else { return }
            self.managementMenu = nil; self.managementWindow = nil
        }
    }

    private func contextID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
    }
    @objc private func duplicateContextTab(_ sender: NSMenuItem) {
        if managementAllowed, let id = contextID(sender) { onDuplicate?(id) }
    }
    @objc private func moveContextTabLeft(_ sender: NSMenuItem) { if let id = contextID(sender) { moveTab(id, direction: -1) } }
    @objc private func moveContextTabRight(_ sender: NSMenuItem) { if let id = contextID(sender) { moveTab(id, direction: 1) } }
    @objc private func closeContextTab(_ sender: NSMenuItem) {
        if managementAllowed, let id = contextID(sender) { onClose?(id) }
    }
    @objc private func reopenContextTab(_ sender: NSMenuItem) { if managementAllowed { onReopenClosed?() } }
    @objc private func newContextTab(_ sender: NSMenuItem) { if creationAllowed { onNew?() } }

    private func scrollTabs(direction: CGFloat) {
        let clip = scroll.contentView
        let maximum = max(0, document.bounds.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(maximum, max(0, clip.bounds.minX + direction * clip.bounds.width * 0.75)), y: 0))
        scroll.reflectScrolledClipView(clip)
    }
}

@MainActor
final class TabSelectionButton: ActionButton {
    var onInteraction: (() -> Void)?
    var onAccessibleActivation: (() -> Bool)?
    var onMiddleClick: (() -> Void)?
    var onBeginDrag: ((NSEvent) -> Void)?
    var onMoveLeft: (() -> Bool)?
    var onMoveRight: (() -> Bool)?
    var onDuplicate: (() -> Bool)?
    var onContextMenu: (() -> NSMenu?)?

    override func accessibilityPerformPress() -> Bool {
        // The tab exposes a radio-button role, with explicit selection state.
        // Supply that role's standard press through the same selection action
        // as a pointer click, including finishing an in-progress strip reveal.
        guard let action, target != nil, prepareAccessibleInteraction() else { return false }
        return NSApplication.shared.sendAction(action, to: target, from: self)
    }
    private func prepareAccessibleInteraction() -> Bool {
        guard NativeAccessibleAction.canInvoke(self,enabled:isEnabled), NativeAccessibleAction.activateWindow(self),
              onAccessibleActivation?() != false else { return false }
        onInteraction?(); return true
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        guard event.type == .leftMouseDown, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        // Native event tracking is confined to this app's tab. Filesystem work
        // and tab navigation do not occur until a click or drop is committed.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { performClick(nil); return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                onBeginDrag?(next); return
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == [.command, .shift] {
            if event.keyCode == 123 { _ = onMoveLeft?(); return }
            if event.keyCode == 124 { _ = onMoveRight?(); return }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }

    @objc func accessibleMoveLeft(_ action: NSAccessibilityCustomAction) -> Bool {
        guard prepareAccessibleInteraction() else { return false }; return onMoveLeft?() ?? false
    }
    @objc func accessibleMoveRight(_ action: NSAccessibilityCustomAction) -> Bool {
        guard prepareAccessibleInteraction() else { return false }; return onMoveRight?() ?? false
    }
    @objc func accessibleDuplicate(_ action: NSAccessibilityCustomAction) -> Bool {
        guard prepareAccessibleInteraction() else { return false }; return onDuplicate?() ?? false
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() } else { super.otherMouseUp(with: event) }
    }
}

@MainActor
private final class BrowserTabView: NSView {
    let id: UUID
    let choose = TabSelectionButton(title: "", action: {})
    let close = ActionButton(title: "", image: symbol("xmark", "Close tab"), action: {})
    private var selected = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    var onContextMenu: (() -> NSMenu?)?
    var isGlassEnabled = false { didSet { needsDisplay = true } }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        choose.isBordered = false
        choose.alignment = .left
        // Tabs can be created after the browser's initial sizing pass (new
        // tabs and split panes). Tag the base once so they inherit the current
        // size immediately and later preference changes never scale twice.
        InterfaceMetrics.setFont(choose, base: .systemFont(ofSize: 12))
        choose.setAccessibilityRole(.radioButton)
        choose.setAccessibilityHelp("Choose tab. Command-Shift-Left or Right moves this tab.")
        choose.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Move Tab Left", target: choose, selector: #selector(TabSelectionButton.accessibleMoveLeft(_:))),
            NSAccessibilityCustomAction(name: "Move Tab Right", target: choose, selector: #selector(TabSelectionButton.accessibleMoveRight(_:))),
            NSAccessibilityCustomAction(name: "Duplicate Tab", target: choose, selector: #selector(TabSelectionButton.accessibleDuplicate(_:)))
        ])
        if let cell = choose.cell as? NSButtonCell { cell.lineBreakMode = .byTruncatingTail }
        close.isBordered = false
        close.bezelStyle = .recessed
        close.image = close.image?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        addSubview(choose)
        addSubview(close)
    }

    required init?(coder: NSCoder) { nil }

    func configure(tab: BrowserTab, selected: Bool) {
        self.selected = selected
        choose.title = tab.location.displayName
        choose.image = symbol(tab.location == .computer ? "desktopcomputer" : tab.location.isArchive ? "archivebox" : "folder.fill", "")
        choose.imagePosition = .imageLeading
        choose.contentTintColor = .labelColor
        choose.setAccessibilityLabel("Tab: \(tab.location.displayName)")
        choose.setAccessibilityValue(selected ? 1 : 0)
        choose.toolTip = tab.location.directoryURL?.path ?? tab.location.displayName
        close.setAccessibilityLabel("Close \(tab.location.displayName) tab")
        close.toolTip = "Close Tab (⌘W / Ctrl+W)"
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        choose.frame = NSRect(x: 12, y: 3, width: max(0, bounds.width - 48), height: max(28, bounds.height - 6))
        close.frame = NSRect(x: bounds.width - 31, y: 6, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected || hovering else { return }
        let path = NSBezierPath()
        let r: CGFloat = 7
        let right = bounds.width - 0.5
        let top = bounds.height - 0.5
        path.move(to: NSPoint(x: 0.5, y: 0))
        path.line(to: NSPoint(x: 0.5, y: top - r))
        path.curve(to: NSPoint(x: r + 0.5, y: top), controlPoint1: NSPoint(x: 0.5, y: top), controlPoint2: NSPoint(x: 0.5, y: top))
        path.line(to: NSPoint(x: right - r, y: top))
        path.curve(to: NSPoint(x: right, y: top - r), controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
        path.line(to: NSPoint(x: right, y: 0))
        let translucent = BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: isGlassEnabled,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let selectedColor = translucent ? NSColor.controlBackgroundColor.withAlphaComponent(0.22) : .controlBackgroundColor
        (selected ? selectedColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).setFill()
        path.fill()
        if selected {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { choose.performClick(nil) }
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { close.performClick(nil) } else { super.otherMouseUp(with: event) }
    }
}
