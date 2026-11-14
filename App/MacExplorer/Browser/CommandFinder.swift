import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor
extension BrowserViewController {
    @objc func findCommand(_ sender: Any?) { commandFinder.present() }
}

/// Discovery only. All execution returns to the original browser's existing
/// admission and typed selector after the panel has relinquished key status.
@MainActor
final class CommandFinderController: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static weak var visible: CommandFinderController?
    private weak var browser: BrowserViewController?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private struct Context {
        let pane: UUID, tab: UUID, visit: UUID, presentation: UUID
        let selectedCount: Int, rows: IndexSet
        let items: Set<IndexPath>
        let urls: [URL]
        let smb: SMBDirectoryObservation?
        let sftp: SFTPStoredRow?
    }
    private var context: Context?
    private var closeObservation: BrowserNotificationObservation?
    private var dismissing = false
    private(set) var window: NSPanel?
    let query = NSSearchField()
    let table = NSTableView()
    let status = label("↑ ↓ to choose · Return to run · Esc to close", size: 11, color: .secondaryLabelColor)
    private var catalog: [BrowserCommandSearch.Entry] = []
    private(set) var matches: [BrowserCommandSearch.Entry] = []
    #if DEBUG
    var dispatchForVerification: ((BrowserCommand) -> Void)?
    private(set) var dispatchedForVerification: [BrowserCommand] = []
    #endif

    init(browser: BrowserViewController) { self.browser = browser; super.init() }

    func present() {
        guard let browser, let parent = browser.view.window, parent.isVisible,
              NSApp.keyWindow === parent, parent.attachedSheet == nil,
              NSApp.modalWindow == nil, !browser.isBrowserSuspended, browser.isActiveCommandPane else { return }
        Self.visible?.dismiss(restoringFocus: false)
        sourceWindow = parent; sourceResponder = parent.firstResponder
        context = snapshot(browser)
        browser.synchronizeTransferClipboard()
        var omitted: Set<BrowserCommand> = [.findCommand, .renamePin, .removePin, .pinUp, .pinDown]
        if !DriveBenchmarkFeature.available { omitted.insert(.driveBenchmark) }
        catalog = BrowserCommand.allCases.filter { $0.tabIndex == nil && !omitted.contains($0) && $0.isPresentedInBuild }.map { action in
            .init(command: action, shortcut: browser.settings.shortcutMap.shortcuts(for: action).map(\.display).joined(separator: " · "),
                enabled: browser.commandEnabled(action.selector, synchronizingClipboard: false))
        }
        let panel = makePanel(settings: browser.settings)
        window = panel; panel.delegate = self
        closeObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: parent) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        Self.visible = self
        query.stringValue = ""; updateMatches()
        CommandDiscoveryPresentation.position(panel, relativeTo: parent)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(query)
        animateEntrance(panel)
    }

    private func animateEntrance(_ panel: NSPanel) {
        guard let browser else { return }
        CommandDiscoveryPresentation.animateEntrance(panel, motion: browser.settings.motion)
    }

    #if DEBUG
    func replayEntranceForVerification() { if let window { animateEntrance(window) } }
    #endif

    private func makePanel(settings: BrowserSettings) -> NSPanel {
        query.delegate = self; query.target = self; query.action = #selector(searchChanged(_:))
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activateSelection(_:))
        return CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
            scope: "Actions in the active pane", settings: settings)
    }

    func updateMatches() {
        do {
            matches = try BrowserCommandSearch.matches(query.stringValue, entries: catalog)
            status.stringValue = matches.isEmpty ? "No matching commands. Try an action such as Split, Storage or Names." : "↑ ↓ to choose · Return to run · Esc to close"
        } catch {
            matches = []; status.stringValue = "Try a shorter command or shortcut."
        }
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === query, (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    // NSSearchField sends its search action during native typing and when its
    // clear button is used. Search is discovery; only Return/double-click runs.
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
        let index = min(max(0, table.selectedRow + delta), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
    }
    @objc func activateSelection(_ sender: Any?) {
        guard window?.isKeyWindow == true, (query.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              matches.indices.contains(table.selectedRow) else { return }
        let entry = matches[table.selectedRow]
        guard entry.enabled else { status.stringValue = "This command is unavailable in the current pane or selection."; return }
        guard let browser, let parent = sourceWindow, let context, isCurrent(context, browser: browser, parent: parent) else {
            status.stringValue = "The active pane changed. Close this panel and open Find a Command again."; return
        }
        // Close Tab and responder-sensitive file actions must see the browser,
        // never the discovery panel, as the key window at the execution boundary.
        dismiss(restoringFocus: true)
        guard NSApp.keyWindow === parent, isCurrent(context, browser: browser, parent: parent),
              browser.commandEnabled(entry.command.selector) else { return }
        #if DEBUG
        dispatchedForVerification.append(entry.command)
        if let dispatchForVerification { dispatchForVerification(entry.command); return }
        #endif
        let item = NSMenuItem(title: entry.title, action: entry.command.selector, keyEquivalent: "")
        item.target = browser
        if let index = [BrowserCommand.details, .list, .icons].firstIndex(of: entry.command) { item.tag = index }
        NSApp.sendAction(entry.command.selector, to: browser, from: item)
    }

    func dismiss(restoringFocus: Bool) {
        guard !dismissing else { return }
        dismissing = true
        let parent = sourceWindow, responder = sourceResponder
        let wasKey = window?.isKeyWindow == true
        window?.delegate = nil; window?.orderOut(nil); window?.close(); window = nil
        closeObservation = nil; query.stringValue = ""; matches = []; catalog = []; table.reloadData()
        context = nil; sourceWindow = nil; sourceResponder = nil
        if Self.visible === self { Self.visible = nil }
        if restoringFocus, wasKey, let parent, parent.isVisible, parent.attachedSheet == nil, browser?.isBrowserSuspended == false {
            parent.makeKeyAndOrderFront(nil)
            if let responder, (responder as? NSView)?.window === parent { parent.makeFirstResponder(responder) }
            else { browser?.focusBrowserContent() }
        }
        dismissing = false
    }
    func windowWillClose(_ notification: Notification) { dismiss(restoringFocus: true) }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoringFocus: false) }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let value = matches[row]
        return CommandDiscoveryPresentation.row(title: value.title, category: value.category,
            shortcut: value.shortcut, enabled: value.enabled)
    }
    private func snapshot(_ browser: BrowserViewController) -> Context {
        let smb = browser.smbTabs[browser.activeID]?.rows
        let sftp = browser.sftpTabs[browser.activeID]?.rows
        return Context(pane: browser.paneID, tab: browser.activeID, visit: browser.sessionID, presentation: browser.filePresentationID,
            selectedCount: browser.selectedItemCount, rows: browser.table.selectedRowIndexes,
            items: browser.showsComputerVolumes ? browser.volumeBrowser.collectionView.selectionIndexPaths : browser.iconBrowser.collectionView.selectionIndexPaths,
            urls: browser.orderedSelectedURLs(upTo: 1_025),
            smb: smb.flatMap { $0.cache.entry(at: Int64($0.table.selectedRow)) },
            sftp: sftp.flatMap { $0.table.selectedRow >= 0 ? $0.cache.entry(at: UInt64($0.table.selectedRow)) : nil })
    }
    private func isCurrent(_ context: Context, browser: BrowserViewController, parent: NSWindow) -> Bool {
        let now = snapshot(browser)
        return browser.view.window === parent && parent.isVisible && parent.attachedSheet == nil
            && !browser.isBrowserSuspended && browser.isActiveCommandPane
            && now.pane == context.pane && now.tab == context.tab && now.visit == context.visit
            && now.presentation == context.presentation && now.rows == context.rows && now.items == context.items
            && now.selectedCount == context.selectedCount && now.urls == context.urls
            && now.smb == context.smb && now.sftp == context.sftp
    }
}
