import AppKit

/// A keyboard request uses the same menu and selected item as a pointer request.
/// It never relies on the cursor's position or changes a multiple selection.
@MainActor enum KeyboardContextMenu {
    struct Request {
        let menu: NSMenu
        let view: NSView
        let point: NSPoint
        func present() { menu.popUp(positioning: nil, at: point, in: view) }
    }

    static func prepare(in view: NSView, menu: NSMenu) -> Request? {
        guard let window = view.window, window.isKeyWindow, !view.isHiddenOrHasHiddenAncestor,
              window.attachedSheet == nil, !(window.firstResponder is NSTextView) else { return nil }
        let anchor: NSRect
        if let table = view as? NSTableView {
            if table.selectedRow >= 0 {
                table.scrollRowToVisible(table.selectedRow)
                anchor = table.rect(ofRow: table.selectedRow)
            } else {
                guard !(table is NSOutlineView) else { return nil }
                anchor = table.visibleRect
            }
        } else if let collection = view as? NSCollectionView {
            if let item = collection.selectionIndexPaths.sorted().first {
                collection.scrollToItems(at: [item], scrollPosition: .nearestVerticalEdge)
                guard let attributes = collection.layoutAttributesForItem(at: item) else { return nil }
                anchor = attributes.frame
            } else { anchor = collection.visibleRect }
        } else { return nil }
        let visible = view.visibleRect
        let point = NSPoint(x: max(visible.minX + 2, min(anchor.minX + 24, visible.maxX - 2)),
            y: max(visible.minY + 2, min(anchor.midY, visible.maxY - 2)))
        return .init(menu: menu, view: view, point: point)
    }
}
