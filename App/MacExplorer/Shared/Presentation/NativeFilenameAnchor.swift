import AppKit

@MainActor enum NativeFilenameAnchor {
    static func selected(in table: NSTableView) -> (view: NSView, rect: NSRect, label: NSTextField)? {
        let row = table.selectedRow
        guard row >= 0, table.numberOfSelectedRows == 1,
              let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return nil }
        table.scrollRowToVisible(row); table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let label = cell.textField else { return nil }
        let rect = table.convert(label.bounds, from: label).intersection(table.visibleRect)
        return rect.width >= 24 && !rect.isEmpty ? (table, rect, label) : nil
    }
}
