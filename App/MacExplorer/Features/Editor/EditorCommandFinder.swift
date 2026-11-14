import AppKit

/// Discover the existing editor menu, not a parallel command implementation.
/// No file names, document text, queries or command history are persisted.
@MainActor final class EditorCommandFinder: NSObject, NSWindowDelegate,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry {
        let item: NSMenuItem
        let category: String
        let shortcut: String
        let enabled: Bool
    }
    private weak var owner: NativeTextEditorWindow?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var generation: UUID?
    private var selection: [NSValue] = []
    private var catalog: [Entry] = []
    private var closeObservation: BrowserNotificationObservation?
    private var dismissing = false
    private(set) var matches: [Entry] = []
    private(set) var window: NSPanel?
    let query = NSSearchField(), table = NSTableView()
    let status = label("↑ ↓ to choose · Return to run · Esc to close", size: 11, color: .secondaryLabelColor)

    init(owner: NativeTextEditorWindow) { self.owner = owner; super.init() }

    func present() {
        guard window == nil, let owner, let parent = owner.window,
              parent.isKeyWindow, parent.isVisible, parent.attachedSheet == nil,
              NSApp.modalWindow == nil, owner.canDiscoverCommands else { return }
        sourceWindow = parent; sourceResponder = parent.firstResponder
        generation = owner.surface.generation; selection = owner.surface.textView.selectedRanges
        catalog = owner.discoverableCommands().map { item, category in
            Entry(item: item, category: category, shortcut: Self.shortcut(item),
                  enabled: Self.isEnabled(item))
        }
        query.delegate = self; query.target = self; query.action = #selector(searchChanged(_:))
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activateSelection(_:))
        let panel = CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
            title: "Find an Editor Command", scope: "Actions in this editor",
            searchLabel: "Find an editor command", settings: owner.commandDiscoverySettings)
        window = panel; panel.delegate = self
        closeObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: parent) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        query.stringValue = ""; updateMatches()
        CommandDiscoveryPresentation.position(panel, relativeTo: parent)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(query)
        CommandDiscoveryPresentation.animateEntrance(panel,
            motion: owner.commandDiscoverySettings?.motion ?? InterfacePresentation.shared.motion)
    }

    func updateMatches() {
        let text = query.stringValue
        let terms = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace)
        if text.unicodeScalars.prefix(257).count > 256 || terms.count > 8 {
            matches = []; status.stringValue = "Try a shorter action or shortcut."
        } else {
            matches = Array(catalog.filter { entry in
                let haystack = (entry.item.title + " " + entry.category + " " + entry.shortcut).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
                return terms.allSatisfy { haystack.contains($0) }
            }.prefix(20))
            status.stringValue = matches.isEmpty ? "No matching commands. Try Find, Lines or Save."
                : "↑ ↓ to choose · Return to run · Esc to close"
        }
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0)
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === query,
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    @objc private func searchChanged(_ sender: Any?) {
        guard window?.isKeyWindow == true,
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === query, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(nil); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(restoringFocus: true); return true
        default: return false
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc func activateSelection(_ sender: Any?) {
        guard window?.isKeyWindow == true, matches.indices.contains(table.selectedRow),
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let entry = matches[table.selectedRow]
        guard entry.enabled else { status.stringValue = "This command is unavailable in the current editor."; return }
        guard let owner, let parent = sourceWindow, isCurrent(owner, parent: parent) else {
            status.stringValue = "The document changed. Close this panel and try again."; return
        }
        let responder = sourceResponder, expectedGeneration = generation, expectedSelection = selection
        dismiss(restoringFocus: true)
        // Restore the exact responder before resolving Undo/Cut/Copy/Find. Never
        // redirect a command from a vanished Find field into the document.
        guard parent.isKeyWindow, parent.isVisible, parent.attachedSheet == nil,
              owner.window === parent, owner.canDiscoverCommands,
              owner.surface.generation == expectedGeneration,
              owner.surface.textView.selectedRanges == expectedSelection,
              let responder, parent.firstResponder === responder,
              Self.isEnabled(entry.item), let action = entry.item.action else { return }
        NSApp.sendAction(action, to: entry.item.target, from: entry.item)
    }
    private func isCurrent(_ owner: NativeTextEditorWindow, parent: NSWindow) -> Bool {
        owner.window === parent && parent.isVisible && parent.attachedSheet == nil
            && owner.canDiscoverCommands && owner.surface.generation == generation
            && owner.surface.textView.selectedRanges == selection
    }
    func dismiss(restoringFocus: Bool) {
        guard !dismissing else { return }
        dismissing = true
        let parent = sourceWindow, responder = sourceResponder, wasKey = window?.isKeyWindow == true
        window?.delegate = nil; window?.orderOut(nil); window?.close(); window = nil
        closeObservation = nil; query.stringValue = ""; matches = []; catalog = []; table.reloadData()
        generation = nil; selection = []; sourceWindow = nil; sourceResponder = nil
        if restoringFocus, wasKey, let parent, parent.isVisible, parent.attachedSheet == nil,
           owner?.canDiscoverCommands == true {
            parent.makeKeyAndOrderFront(nil)
            if let responder, (responder as? NSView)?.window === parent { parent.makeFirstResponder(responder) }
        }
        dismissing = false
    }
    func windowWillClose(_ notification: Notification) { dismiss(restoringFocus: true) }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoringFocus: false) }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let entry = matches[row]
        return CommandDiscoveryPresentation.row(title: entry.item.title, category: entry.category,
            shortcut: entry.shortcut, enabled: entry.enabled)
    }
    private static func isEnabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }
        if let validation = target as? any NSMenuItemValidation { return validation.validateMenuItem(item) }
        if let validation = target as? any NSUserInterfaceValidations { return validation.validateUserInterfaceItem(item) }
        return item.isEnabled
    }
    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        let modifiers = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
            + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
        let key: String
        switch item.keyEquivalent {
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): key = "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): key = "↓"
        case "\t": key = "⇥"
        default: key = item.keyEquivalent.uppercased()
        }
        return modifiers + key
    }
}
