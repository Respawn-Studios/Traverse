import AppKit

/// Native selection/drag stays with AppKit. A later click on the selected name
/// schedules the existing Rename command after the double-click interval.
@MainActor final class SelectedNameClickRename {
    private var work: Task<Void, Never>?
    private var menuObservation: BrowserNotificationObservation?
    func cancel() { work?.cancel(); work = nil; menuObservation = nil }
    func begin(_ event: NSEvent, table: NSTableView, revision: UInt64,
               currentRevision: @escaping @MainActor () -> UInt64,
               enabled: Bool, action: @escaping @MainActor () -> Void) {
        cancel()
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point), column = table.column(at: point)
        guard enabled, table.currentEditor() == nil, table.numberOfSelectedRows == 1, row >= 0,
              table.selectedRow == row, table.tableColumns.indices.contains(column),
              table.tableColumns[column].identifier.rawValue == "name",
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
              let label = cell.textField else { return }
        let rect = table.convert(label.bounds, from: label)
        arm(event, in: table, rect: rect, isCurrent: { [weak table] in
            table?.selectedRow == row && table?.numberOfSelectedRows == 1 && currentRevision() == revision
                && table?.currentEditor() == nil
        }, action: action)
    }
    func begin(_ event: NSEvent, collection: NSCollectionView, enabled: Bool,
               action: @escaping @MainActor () -> Void) {
        cancel()
        guard enabled, !BrowserPointerSelection.isEditingText(in: collection), collection.selectionIndexPaths.count == 1,
              let path = collection.selectionIndexPaths.first, let item = collection.item(at: path),
              let label = item.textField else { return }
        arm(event, in: collection, rect: collection.convert(label.bounds, from: label),
            isCurrent: { [weak collection, weak item] in
                collection?.selectionIndexPaths == [path] && collection?.item(at: path) === item
                    && collection.map { !BrowserPointerSelection.isEditingText(in: $0) } == true
            }, action: action)
    }
    private func arm(_ event: NSEvent, in view: NSView, rect: NSRect,
                     isCurrent: @escaping @MainActor () -> Bool, action: @escaping @MainActor () -> Void) {
        guard event.type == .leftMouseDown, event.clickCount == 1, event.buttonNumber == 0,
              event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty,
              let window = view.window, window.isKeyWindow, window.firstResponder === view,
              rect.contains(view.convert(event.locationInWindow, from: nil)) else { return }
        menuObservation = BrowserNotificationObservation(name: NSMenu.didBeginTrackingNotification, object: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        work = Task { @MainActor [weak self, weak view, weak window] in
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            work = nil; menuObservation = nil
            guard let view, let window,
                  view.window === window, window.isKeyWindow, NSApp.isActive, window.attachedSheet == nil,
                  window.firstResponder === view, NSEvent.pressedMouseButtons & 1 == 0, isCurrent() else { return }
            action()
        }
    }
}
