import AppKit

/// An opaque nonce is the entire pasteboard payload. IDs, paths, bookmarks,
/// labels and connection data remain in this live coordinator's memory.
@MainActor
final class BrowserSidebarLayoutDragCoordinator: NSObject, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.respawnstudios.traverse.sidebar-layout-reorder.v1")
    private weak var adapter: BrowserSidebarLayoutAdapter?
    private weak var sourceOutline: NSOutlineView?
    private weak var nativeSource: NSObject?
    private weak var session: NSDraggingSession?
    private var ticket: Ticket?
    #if DEBUG
    // Attached only by the generated-home verifier; no ordinary logging.
    var qualificationObserver: ((String, Bool?) -> Void)?
    #endif
    private struct Ticket {
        let nonce: UUID
        let subject: BrowserSidebarLayoutAdapter.Subject
        let fence: BrowserSidebarLayoutAdapter.Fence
    }
    private final class MenuRequest: NSObject {
        enum Command { case move(BrowserSidebarLayoutAdapter.Target), toggle(SidebarLayoutSection), reset }
        let subject: BrowserSidebarLayoutAdapter.Subject
        let fence: BrowserSidebarLayoutAdapter.Fence
        let command: Command
        init(subject: BrowserSidebarLayoutAdapter.Subject, fence: BrowserSidebarLayoutAdapter.Fence, command: Command) {
            self.subject = subject; self.fence = fence; self.command = command
        }
    }
    init(adapter: BrowserSidebarLayoutAdapter) { self.adapter = adapter }
    var isDragging: Bool { session != nil }
    func invalidate() {
        (sourceOutline as? BrowserSidebarOutlineView)?.showLayoutInsertion(at: nil)
        ticket = nil
        if session == nil { sourceOutline = nil; nativeSource = nil }
        // Revoke a drop immediately, but keep its native session until AppKit
        // sends the matching end callback so final expansion cleanup still runs.
    }

    func containsInternalType(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [Self.pasteboardType]) != nil
    }
    func pasteboardWriter(for node: SidebarNode, in outline: NSOutlineView) -> NSPasteboardItem? {
        guard session == nil, let adapter, adapter.outline === outline, adapter.isActive,
              let subject = adapter.subject(for: node), let fence = adapter.fence() else { return nil }
        invalidate()
        let nonce = UUID()
        ticket = .init(nonce: nonce, subject: subject, fence: fence)
        sourceOutline = outline
        let writer = NSPasteboardItem()
        writer.setData(Data(nonce.uuidString.utf8), forType: Self.pasteboardType)
        return writer
    }

    /// Standard NSOutlineView data-source source callback. Never trust a nonce
    /// without the actual outline source and native session sequence as well.
    func willBegin(_ native: NSDraggingSession, outline: NSOutlineView, items: [Any]) {
        guard items.count == 1, let node = items[0] as? SidebarNode, let adapter, let ticket,
              sourceOutline === outline, adapter.subject(for: node) == ticket.subject,
              adapter.fence() == ticket.fence else { invalidate(); return }
        session = native; nativeSource = outline
        native.animatesToStartingPositionsOnCancelOrFail = adapter.animatesReordering
        setGhost(on: native, node: node, outline: outline)
        #if DEBUG
        qualificationObserver?("outline-start", nil)
        #endif
    }
    func ended(_ native: NSDraggingSession) {
        #if DEBUG
        qualificationObserver?("session-end", session === native)
        #endif
        guard session === native else { return }
        // Cancellation/end has no metadata or filesystem side effects.
        session = nil
        (sourceOutline as? BrowserSidebarOutlineView)?.finishSidebarLayoutDrag()
        invalidate()
        adapter?.restoreExpansion()
        #if DEBUG
        qualificationObserver?("session-restored", nil)
        #endif
    }

    /// Both a held name and a normal short drag use one native session. The
    /// preview retains the visible expanded branch rather than collapsing it.
    @discardableResult
    func beginNameDrag(node: SidebarNode, outline: NSOutlineView, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let writer = pasteboardWriter(for: node, in: outline),
              let preview = ghost(for: node, outline: outline) else { invalidate(); return false }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(preview.frame, contents: preview.image)
        let native = outline.beginDraggingSession(with: [item], event: event, source: self)
        session = native; sourceOutline = outline; nativeSource = self
        native.animatesToStartingPositionsOnCancelOrFail = adapter?.animatesReordering ?? false
        #if DEBUG
        qualificationObserver?("name-start", nil)
        #endif
        return true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended(session) }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func ghost(for node: SidebarNode, outline: NSOutlineView) -> (frame: NSRect, image: NSImage)? {
        let index = outline.row(forItem: node)
        guard index >= 0 else { return nil }
        var last = index
        if outline.isItemExpanded(node) {
            for row in (index + 1)..<outline.numberOfRows {
                var parent = outline.parent(forItem: outline.item(atRow: row))
                var descendant = false
                for _ in 0..<64 {
                    guard let current = parent else { break }
                    if (current as? SidebarNode) === node { descendant = true; break }
                    parent = outline.parent(forItem: current)
                }
                guard descendant else { break }
                last = row
            }
        }
        var frame = outline.rect(ofRow: index).union(outline.rect(ofRow: last)).intersection(outline.visibleRect)
        guard !frame.isEmpty else { return nil }
        let scale = max(1, outline.window?.backingScaleFactor ?? 1)
        frame.size.width = min(frame.width, 2048)
        frame.size.height = min(frame.height, floor(8 * 1024 * 1024 / (frame.width * scale * scale * 4)))
        guard frame.width > 0, frame.height > 0 else { return nil }
        var rows: [(NSRect, NSBitmapImageRep)] = []
        for row in index...last {
            let rowFrame = outline.rect(ofRow: row)
            guard rowFrame.intersects(frame), let view = outline.rowView(atRow: row, makeIfNecessary: false),
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rows.append((rowFrame.offsetBy(dx: -frame.minX, dy: -frame.minY), bitmap))
        }
        guard !rows.isEmpty else { return nil }
        let image = NSImage(size: frame.size, flipped: true) { _ in
            let card = NSBezierPath(roundedRect: NSRect(origin: .zero, size: frame.size).insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.90).setFill(); card.fill()
            for (rect, bitmap) in rows { bitmap.draw(in: rect) }
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke(); card.lineWidth = 1; card.stroke()
            return true
        }
        return (frame, image)
    }
    private func setGhost(on native: NSDraggingSession, node: SidebarNode, outline: NSOutlineView) {
        guard let preview = ghost(for: node, outline: outline) else { return }
        native.enumerateDraggingItems(options: [], for: outline, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(preview.frame, contents: preview.image)
        }
    }

    private func authenticated(_ info: any NSDraggingInfo, outline: NSOutlineView) -> Ticket? {
        guard let adapter, adapter.isActive, let ticket, let session, let nativeSource,
              adapter.outline === outline, sourceOutline === outline,
              (info.draggingSource as? NSObject) === nativeSource,
              session.draggingSequenceNumber == info.draggingSequenceNumber,
              adapter.fence() == ticket.fence,
              info.draggingSourceOperationMask.contains(.move),
              let items = info.draggingPasteboard.pasteboardItems, items.count == 1,
              Set(items[0].types) == Set([Self.pasteboardType]),
              let data = items[0].data(forType: Self.pasteboardType), data.count == 36,
              String(data: data, encoding: .utf8) == ticket.nonce.uuidString else { return nil }
        return ticket
    }

    /// Internal types are consumed even when refused. The caller MUST NOT let a
    /// refused internal drag fall through to pin/fileURL/transfer admission.
    func validate(_ info: any NSDraggingInfo, outline: NSOutlineView,
                  proposedItem: Any?, childIndex: Int) -> NSDragOperation {
        guard let ticket = authenticated(info, outline: outline),
              let target = target(for: ticket.subject, outline: outline, point: outline.convert(info.draggingLocation, from: nil)),
              adapter?.canMove(ticket.subject, to: target.value, captured: ticket.fence) == true else {
            (outline as? BrowserSidebarOutlineView)?.showLayoutInsertion(at: nil)
            return []
        }
        outline.setDropItem(target.parent, dropChildIndex: target.index)
        (outline as? BrowserSidebarOutlineView)?.showLayoutInsertion(at: target.y)
        return .move
    }
    func accept(_ info: any NSDraggingInfo, outline: NSOutlineView, item: Any?, childIndex: Int) -> Bool {
        #if DEBUG
        qualificationObserver?("accept-begin", nil)
        #endif
        guard let ticket = authenticated(info, outline: outline),
              let target = target(for: ticket.subject, outline: outline, point: outline.convert(info.draggingLocation, from: nil)) else {
            #if DEBUG
            qualificationObserver?("accept-rejected", false)
            #endif
            return false
        }
        defer { invalidate() }
        let accepted = adapter?.move(ticket.subject, to: target.value, captured: ticket.fence) == true
        #if DEBUG
        qualificationObserver?("accept-complete", accepted)
        #endif
        return accepted
    }
    private struct DropTarget { let value: BrowserSidebarLayoutAdapter.Target; let parent: SidebarNode?; let index: Int; let y: CGFloat }
    private func target(for subject: BrowserSidebarLayoutAdapter.Subject, outline: NSOutlineView,
                        point: NSPoint) -> DropTarget? {
        guard let adapter, point.x >= outline.bounds.minX, point.x <= outline.bounds.maxX else { return nil }
        func branchFrame(_ node: SidebarNode) -> NSRect? {
            let row = outline.row(forItem: node)
            guard row >= 0 else { return nil }
            var frame = outline.rect(ofRow: row)
            for childRow in (row + 1)..<outline.numberOfRows {
                var parent = outline.parent(forItem: outline.item(atRow: childRow)), found = false
                for _ in 0..<64 {
                    guard let current = parent else { break }
                    if (current as? SidebarNode) === node { found = true; break }
                    parent = outline.parent(forItem: current)
                }
                guard found else { break }
                frame = frame.union(outline.rect(ofRow: childRow))
            }
            return frame
        }
        switch subject {
        case .category:
            let sections = adapter.visibleSections
            for (index, section) in sections.enumerated() {
                guard let node = adapter.root(for: section), let frame = branchFrame(node) else { continue }
                if point.y < frame.midY {
                    return .init(value: .category(section), parent: nil, index: index, y: frame.minY)
                }
            }
            guard let last = sections.last.flatMap(adapter.root), let frame = branchFrame(last) else { return nil }
            return .init(value: .category(nil), parent: nil, index: sections.count, y: frame.maxY)
        case .row(let section, _):
            guard let root = adapter.root(for: section) else { return nil }
            let order = adapter.rowOrder(in: section)
            let rootRow = outline.row(forItem: root)
            guard rootRow >= 0, outline.isItemExpanded(root), let children = root.children, children.count == order.count,
                  let last = children.last.flatMap(branchFrame),
                  point.y >= outline.rect(ofRow: rootRow).minY,
                  point.y <= last.maxY + InterfaceMetrics.points(12) else { return nil }
            for (index, child) in children.enumerated() {
                guard let frame = branchFrame(child) else { continue }
                if point.y < frame.midY {
                    return .init(value: .row(section, order[index]), parent: root, index: index, y: frame.minY)
                }
            }
            return .init(value: .row(section, nil), parent: root, index: order.count, y: last.maxY)
        }
    }

    func appendAlternatives(to existing: NSMenu?, for node: SidebarNode) -> NSMenu? {
        guard let adapter, let subject = adapter.subject(for: node), let fence = adapter.fence() else { return existing }
        let root = existing ?? NSMenu()
        root.autoenablesItems = false
        let menu: NSMenu
        if !root.items.isEmpty {
            menu = NSMenu(title: "Arrange Sidebar"); menu.autoenablesItems = false
            let arrange = NSMenuItem(title: "Arrange Sidebar", action: nil, keyEquivalent: "")
            arrange.submenu = menu; root.addItem(.separator()); root.addItem(arrange)
        } else { menu = root }
        let position: Int?, count: Int
        let targets: [BrowserSidebarLayoutAdapter.Target]
        switch subject {
        case .category(let section):
            position = fence.roots.firstIndex(of: section); count = fence.roots.count
            targets = fence.roots.map { .category($0) } + [.category(nil)]
        case .row(let section, let id):
            let order = adapter.rowOrder(in: section)
            position = order.firstIndex(of: id); count = order.count
            targets = order.map { .row(section, $0) } + [.row(section, nil)]
        }
        if let position {
            for (title, destination, enabled) in [
                ("Move Up", targets[max(0, position - 1)], position > 0),
                ("Move Down", targets[min(count, position + 2)], position + 1 < count)
            ] {
                let entry = menu.addItem(withTitle: title, action: #selector(runMenu(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = MenuRequest(subject: subject, fence: fence, command: .move(destination))
                entry.isEnabled = enabled && adapter.canMove(subject, to: destination, captured: fence)
            }
        }
        if case .category(let section) = subject, section.canCollapse {
            let title = adapter.owner.preferences.collapsed.contains(section) ? "Expand Category" : "Collapse Category"
            let entry = menu.addItem(withTitle: title, action: #selector(runMenu(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = MenuRequest(subject: subject, fence: fence, command: .toggle(section))
            entry.isEnabled = adapter.isActive && adapter.owner.canEdit
        }
        if case .category = subject {
            menu.addItem(.separator())
            let entry = menu.addItem(withTitle: "Reset Sidebar Layout", action: #selector(runMenu(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = MenuRequest(subject: subject, fence: fence, command: .reset)
            entry.isEnabled = adapter.isActive && adapter.owner.canEdit
            entry.toolTip = "Restore category, Places and saved drive/folder positions. Pins and their order stay as you arranged them. No files are changed."
        }
        return root
    }
    @objc private func runMenu(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? MenuRequest, let adapter,
              adapter.fence() == request.fence else { return }
        switch request.command {
        case .move(let target): _ = adapter.move(request.subject, to: target, captured: request.fence)
        case .toggle(let section): _ = adapter.toggleDisclosure(section, captured: request.fence)
        case .reset: _ = adapter.reset(captured: request.fence)
        }
    }
    func showAlternatives(for node: SidebarNode, from handle: NSView) {
        guard let menu = appendAlternatives(to: nil, for: node) else { return }
        menu.popUp(positioning: nil, at: .init(x: 0, y: handle.bounds.maxY), in: handle)
    }
}
