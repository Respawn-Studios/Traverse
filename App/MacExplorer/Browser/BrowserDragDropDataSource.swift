import AppKit
import ExplorerCore

/// Native callbacks only negotiate/admit; the shared engine performs mutations.
@MainActor
extension BrowserViewController {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        dragDrop.pasteboardWriter(for: row)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragDrop.willBegin(session, rows: rowIndexes)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragDrop.ended(session)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dragDrop.validateDrop(info, row: row, operation: dropOperation)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        dragDrop.acceptDrop(info, row: row, operation: dropOperation)
    }
}

/// No automatic expansion or spring-loaded navigation during file drags.
@MainActor
final class BrowserSidebarOutlineView: NSOutlineView {
    var onLocationMenu: ((BrowserLocation) -> NSMenu?)?
    var onRemotePinMenu: ((UUID) -> NSMenu?)?
    var onConnectionMenu: ((BrowserConnectionIdentity) -> NSMenu?)?
    var onSavedServerMenu: ((WorkspaceConnectionBookmark) -> NSMenu?)?
    var onSidebarLayoutMenu: ((SidebarNode, NSMenu?) -> NSMenu?)?
    var onFileDragExited: (() -> Void)?
    private(set) var isFileDragActive = false
    private weak var hoveredItem: SidebarNode?
    private weak var contextItem: SidebarNode?
    private var pointerTracking: NSTrackingArea?
    private var menuObservations: [BrowserNotificationObservation] = []
    private var windowObservations: [BrowserNotificationObservation] = []
    private var isTrackingContextMenu = false
    private var isDispatchingContextClick = false
    private var layoutInsertionY: CGFloat?
    #if DEBUG
    var isTrackingContextMenuForVerification: Bool { isTrackingContextMenu }
    #endif

    func showLayoutInsertion(at y: CGFloat?) {
        guard layoutInsertionY != y else { return }
        layoutInsertionY = y; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let y = layoutInsertionY else { return }
        let color = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : .controlAccentColor
        color.setStroke(); color.setFill()
        let line = NSBezierPath()
        line.move(to: .init(x: bounds.minX + 12, y: y))
        line.line(to: .init(x: bounds.maxX - 5, y: y))
        line.lineWidth = 2; line.stroke()
        NSBezierPath(ovalIn: .init(x: bounds.minX + 8, y: y - 3, width: 6, height: 6)).fill()
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        guard identifier == NSOutlineView.showHideButtonIdentifier || identifier == NSOutlineView.disclosureButtonIdentifier,
              let button = view as? NSButton else { return view }
        if button is SidebarCategoryDisclosureButton { return button }
        return SidebarCategoryDisclosureButton(native: button)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard row >= 0, row < numberOfRows, frame.height > 0 else { return frame }
        frame.origin.y = rect(ofRow: row).midY - frame.height / 2
        return frame
    }

    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if !isFileDragActive, index >= 0, let node = item(atRow: index) as? SidebarNode,
           node.group, isExpandable(node) {
            performNameClick(node, clickCount: event.clickCount)
            return
        }
        super.mouseDown(with: event)
    }

    func performNameClick(_ node: SidebarNode, clickCount: Int) {
        let index = row(forItem: node)
        guard !isFileDragActive, index >= 0 else { return }
        if node.group {
            guard clickCount == 1, isExpandable(node) else { return }
            if isItemExpanded(node) { collapseItem(node) } else { expandItem(node) }
        } else if delegate?.outlineView?(self, shouldSelectItem: node) != false {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTracking = area
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hoveredItem = nil
        if !isTrackingContextMenu { clearContextHighlight() }
        refreshPointerRows()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservations.removeAll()
        if window == nil { clearPointerHighlights() }
        else if let window {
            windowObservations = [
                BrowserNotificationObservation(name: NSWindow.didBecomeKeyNotification, object: window) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshSelectionFocus() }
                },
                BrowserNotificationObservation(name: NSWindow.didResignKeyNotification, object: window) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hoveredItem = nil
                        if !self.isTrackingContextMenu { self.clearContextHighlight() }
                        self.refreshPointerRows()
                        self.refreshSelectionFocus()
                    }
                },
                BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: window) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clearPointerHighlights() }
                }
            ]
        }
        refreshSelectionFocus()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.refreshSelectionFocus() } }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.refreshSelectionFocus() } }
        return accepted
    }
    private func refreshSelectionFocus() {
        let emphasized = BrowserSelectionFocus.isEmphasized(in: self)
        enumerateAvailableRowViews { row, _ in row.isEmphasized = emphasized; row.needsDisplay = true }
    }
    override func reloadData() { clearPointerHighlights(); super.reloadData() }
    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        clearPointerHighlights(); super.reloadItem(item, reloadChildren: reloadChildren)
    }
    override func reloadItem(_ item: Any?) { clearPointerHighlights(); super.reloadItem(item) }

    func configurePointerRow(_ row: BrowserSidebarRowView, item: SidebarNode) {
        row.isEmphasized = BrowserSelectionFocus.isEmphasized(in: self)
        row.showsHoverOutline = !isFileDragActive && item === hoveredItem
        row.showsContextHighlight = !isFileDragActive && item === contextItem
    }
    private func updateHover(at point: NSPoint) {
        guard !isFileDragActive, !isTrackingContextMenu else { return }
        let index = row(at: point)
        let node = index >= 0 ? item(atRow: index) as? SidebarNode : nil
        let eligible = index >= 0 && (rowView(atRow: index, makeIfNecessary: false) as? BrowserSidebarRowView)?.acceptsPointerFeedback == true
        let next = eligible ? node : nil
        guard next !== hoveredItem else { return }
        hoveredItem = next
        refreshPointerRows()
    }
    private func refreshPointerRows() {
        enumerateAvailableRowViews { row, index in
            guard let row = row as? BrowserSidebarRowView, let item = self.item(atRow: index) as? SidebarNode else { return }
            self.configurePointerRow(row, item: item)
        }
    }
    private func clearContextHighlight() {
        contextItem = nil; isTrackingContextMenu = false; menuObservations.removeAll()
    }
    private func clearPointerHighlights() {
        hoveredItem = nil; clearContextHighlight(); refreshPointerRows()
    }
    override func rightMouseDown(with event: NSEvent) {
        // NSView's contextual-menu tracking is synchronous. Its notifications
        // can name the app menu bar rather than this returned context menu.
        // Bracket the native dispatch without replacing menu tracking/actions.
        isDispatchingContextClick = true
        defer { isDispatchingContextClick = false; clearPointerHighlights() }
        super.rightMouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        clearPointerHighlights()
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SidebarNode else { return nil }
        return contextMenu(for: node)
    }
    func selectedContextMenu() -> NSMenu? {
        guard selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode else { return nil }
        clearPointerHighlights()
        return contextMenu(for: node)
    }
    private func contextMenu(for node: SidebarNode) -> NSMenu? {
        let candidate: NSMenu?
        if let id = node.connectionTarget { candidate = onConnectionMenu?(id) }
        else if let saved = node.serverBookmark { candidate = onSavedServerMenu?(saved) }
        else if let id = node.remotePin { candidate = onRemotePinMenu?(id) }
        else if let location = node.location { candidate = onLocationMenu?(location) }
        else { candidate = nil }
        guard let menu = onSidebarLayoutMenu?(node, candidate) ?? candidate else { return nil }
        contextItem = isDispatchingContextClick ? node : nil
        hoveredItem = nil
        isTrackingContextMenu = isDispatchingContextClick
        menuObservations = [
            BrowserNotificationObservation(name: NSMenu.didBeginTrackingNotification, object: menu) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.contextItem = node
                    self?.isTrackingContextMenu = true
                    self?.refreshPointerRows()
                }
            },
            BrowserNotificationObservation(name: NSMenu.didEndTrackingNotification, object: menu) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearPointerHighlights() }
            }
        ]
        refreshPointerRows()
        if let window, window.isVisible {
            if !NSApplication.shared.isActive { NSApplication.shared.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
        return menu
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDragActive = true
        clearPointerHighlights() // Native drop targeting owns the destination cue.
        return super.draggingEntered(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isFileDragActive = false
        showLayoutInsertion(at: nil)
        super.draggingExited(sender)
        onFileDragExited?()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isFileDragActive = false
        showLayoutInsertion(at: nil)
        // Optional destination callback: NSOutlineView need not implement it.
        onFileDragExited?()
    }
    func finishSidebarLayoutDrag() {
        // A cancelled local reorder need not receive a destination-ended
        // callback. Its source callback must release pointer/disclosure state.
        isFileDragActive = false
        showLayoutInsertion(at: nil)
        clearPointerHighlights()
        onFileDragExited?()
    }
}

/// Decoration only: native selection, focus, disclosure and drop drawing remain
/// owned by NSTableRowView. No extra hit-test or accessibility element is added.
@MainActor
final class BrowserSidebarRowView: NSTableRowView {
    /// Cached by the delegate from presentation-only selectability metadata.
    var acceptsPointerFeedback = false
    var showsHoverOutline = false { didSet { if oldValue != showsHoverOutline { needsDisplay = true } } }
    var showsContextHighlight = false { didSet { if oldValue != showsContextHighlight { needsDisplay = true } } }
    private var highlightPath: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if showsContextHighlight { drawContextHighlight() }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        if showsContextHighlight { drawContextHighlight() }
        else { super.drawSelection(in: dirtyRect) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsHoverOutline || showsContextHighlight {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            (contrast ? NSColor.labelColor : NSColor.controlAccentColor.withAlphaComponent(showsContextHighlight ? 0.85 : 0.55)).setStroke()
            let path = highlightPath; path.lineWidth = contrast ? 2 : 1; path.stroke()
        }
    }
    private func drawContextHighlight() {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.72).setFill()
        highlightPath.fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
extension BrowserViewController {
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let layout = sidebarLayoutValidateDrop(info, outline: outlineView, item: item, childIndex: index) { return layout }
        if (item as? SidebarNode)?.acceptsFolderPins == true {
            let operation = pinDrop.validate(info, target: item)
            if !operation.isEmpty { outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            return operation
        }
        guard index == NSOutlineViewDropOnItemIndex,
              let destination = dragDrop.sidebarDestination(for: item) else { return [] }
        let operation = dragDrop.validateDestinationDrop(info, destination: destination)
        if !operation.isEmpty { outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if let layout = sidebarLayoutAcceptDrop(info, outline: outlineView, item: item, childIndex: index) { return layout }
        if (item as? SidebarNode)?.acceptsFolderPins == true { return pinDrop.accept(info, target: item) }
        guard index == NSOutlineViewDropOnItemIndex,
              let destination = dragDrop.sidebarDestination(for: item) else { return false }
        return dragDrop.acceptDestinationDrop(info, destination: destination)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // AppKit may otherwise expand a hovered disclosure during a native drag.
        sidebarLayout.applyingExpansion || (outlineView as? BrowserSidebarOutlineView)?.isFileDragActive != true
    }
}
