import AppKit
import SwiftUI

struct ToolPageNavigationItem<ID: Hashable>: Equatable {
    let id: ID
    let title: String
    let symbolName: String
    let subtitle: String?

    init(id: ID, title: String, symbolName: String, subtitle: String? = nil) {
        self.id = id; self.title = title; self.symbolName = symbolName; self.subtitle = subtitle
    }
}

/// A real native source list: keyboard selection, focus, accessibility and row
/// emphasis follow AppKit. No custom segmented-control rectangles or snapshots.
struct NativeToolPageNavigation<ID: Hashable>: NSViewRepresentable {
    @Binding var selection: ID
    let scale: CGFloat
    let items: [ToolPageNavigationItem<ID>]
    let identifier: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, items: items) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.identifier = .init(identifier)
        table.style = .sourceList
        table.backgroundColor = .clear
        table.headerView = nil
        table.focusRingType = .default
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.intercellSpacing = .init(width: 0, height: 4)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("section"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = table
        update(table, coordinator: context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.selection = $selection
        update(table, coordinator: context.coordinator)
    }
    private func update(_ table: NSTableView, coordinator: Coordinator) {
        let previouslyUpdating = coordinator.updating
        coordinator.updating = true
        defer { coordinator.updating = previouslyUpdating }
        let changed = coordinator.scale != scale || coordinator.items != items
        coordinator.scale = scale; coordinator.items = items
        table.rowHeight = ceil((items.contains { $0.subtitle != nil } ? 48 : 34) * scale)
        if changed { table.reloadData() }
        if let row = items.firstIndex(where: { $0.id == selection }), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: Binding<ID>
        var items: [ToolPageNavigationItem<ID>]
        var scale: CGFloat = 0
        var updating = false
        init(selection: Binding<ID>, items: [ToolPageNavigationItem<ID>]) {
            self.selection = selection; self.items = items
        }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            let page = items[row]
            let cell = NSTableCellView()
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)
            image.contentTintColor = .secondaryLabelColor
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
            let text = NSTextField(labelWithString: page.title)
            text.font = .systemFont(ofSize: NSFont.systemFontSize * scale)
            text.lineBreakMode = .byTruncatingTail
            text.setAccessibilityLabel(page.title)
            text.toolTip = page.title
            let labels = NSStackView(views: [text])
            labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
            if let subtitle = page.subtitle {
                let detail = NSTextField(labelWithString: subtitle)
                detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize * scale)
                detail.textColor = .secondaryLabelColor
                detail.lineBreakMode = .byTruncatingTail
                labels.addArrangedSubview(detail)
            }
            let stack = NSStackView(views: [image, labels])
            stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 9
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 18 * min(scale, 1.3)),
                image.heightAnchor.constraint(equalToConstant: 18 * min(scale, 1.3)),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = text; cell.imageView = image
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  items.indices.contains(table.selectedRow) else { return }
            let page = items[table.selectedRow].id
            guard page != selection.wrappedValue else { return }
            // End the old page's native field editor before replacing its view.
            guard table.window?.makeFirstResponder(table) != false else { return }
            selection.wrappedValue = page
        }
    }
}

/// Shared navigation geometry for Settings, Help and tools. The feature keeps
/// its own selection, work and content; this supplies only the sidebar surface.
struct ToolNavigationSidebar<Header: View, Content: View, Footer: View>: View {
    let scale: CGFloat
    var baseWidth: CGFloat = 204
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, 8).padding(.top, 18)
            content.frame(maxHeight: .infinity)
            footer.padding(.horizontal, 8).padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        // Keep common section names readable as the native row fonts enlarge.
        .frame(width: baseWidth + 104 * max(0, scale - 1))
        .background(Color.primary.opacity(0.035))
    }
}
