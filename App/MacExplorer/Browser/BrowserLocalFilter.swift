import AppKit
import ExplorerCore

/// Native presentation only: one existing field/delegate/model, two allocations.
/// Filtering still uses the browser's existing off-main row ordering session.
@MainActor
final class BrowserLocalFilterController: NSObject, NSPopoverDelegate {
    static let compactThreshold: CGFloat = 600
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
    let button = NSButton()
    let scopeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var isCompact = false
    var focusTarget: NSView { isCompact ? button : field }
    var isPresented: Bool { popover?.isShown == true }
    #if DEBUG
    var hasPopoverCommandsForVerification: Bool { keyMonitor != nil }
    var hasPopoverForVerification: Bool { popover != nil }
    #endif
    private weak var browser: BrowserViewController?
    private var field: NSSearchField
    private var appliesDefaultOnSynchronization = true
    private var presentedArchive = false
    private var presentedArchiveScope: ArchiveSearchScope?
    var displayedField: NSSearchField { field }
    var displaysSearch: Bool { field !== browser?.filterField }
    private let content = NSViewController()
    private var fieldConstraints: [NSLayoutConstraint] = []
    private var preferredWidth: NSLayoutConstraint!
    private var minimumWidth: NSLayoutConstraint!
    private var requestedPaneWidth: CGFloat = 1140
    var prefersCompact = false { didSet { applyAllocation() } }
    private var popover: NSPopover?
    private var keyMonitor: Any?
    private var layoutTask: Task<Void, Never>?
    private var suppressTextChanges = false
    private weak var editingFieldEditor: NSTextView?
    private var editingContext: Context?
    private var popoverContext: Context?
    private let idleImage = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter this folder")
    // AppKit may expose an image-only button through its image's accessibility
    // proxy. Keep the action name stable; current filter state is its value.
    private let activeImage = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle.fill", accessibilityDescription: "Filter this folder")

    private struct Context: Equatable {
        let pane: UUID
        let tab: UUID
        let visit: UUID
        let window: ObjectIdentifier
    }

    init(browser: BrowserViewController) {
        self.browser = browser; field = browser.filterField
        super.init()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        NSLayoutConstraint.activate([
            content.view.widthAnchor.constraint(equalToConstant: 260),
            content.view.heightAnchor.constraint(equalToConstant: 46)
        ])
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        preferredWidth = view.widthAnchor.constraint(equalToConstant: 230)
        preferredWidth.priority = .defaultHigh
        minimumWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: browser.workspace == nil ? 170 : 100)
        NSLayoutConstraint.activate([preferredWidth, minimumWidth, view.heightAnchor.constraint(equalToConstant: 28)])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = idleImage
        button.isBordered = false
        button.bezelStyle = .recessed
        button.target = self; button.action = #selector(openFilter(_:))
        button.setAccessibilityLabel("Filter this folder")
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        button.isHidden = true
        scopeButton.isBordered = false
        scopeButton.setAccessibilityLabel("Filter and search scope")
        scopeButton.toolTip = "Choose Filter (loaded items), Search Folder (including subfolders), or Search This Mac (Spotlight)."
        scopeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        scopeButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        rebuildScopeMenu()
        browser.metadataSearch.onSearchMenuChanged = { [weak self] in self?.rebuildScopeMenu() }
        placeField(in: view, inset: 0)
    }
    isolated deinit {
        layoutTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        popover?.delegate = nil
        popover?.close()
    }

    private func liveContext() -> Context? {
        guard let browser, !browser.isBrowserSuspended, browser.isActiveCommandPane,
              (displaysSearch || (!browser.showsComputerVolumes && !browser.metadataSearch.isShowingResults)),
              let window = browser.view.window, view.window === window else { return nil }
        if let workspace = browser.workspace {
            guard !workspace.isClosing, workspace.browsers[browser.paneID] === browser else { return nil }
        }
        return Context(pane: browser.paneID, tab: browser.activeID, visit: browser.sessionID,
            window: ObjectIdentifier(window))
    }

    /// Called from layout with actual pane allocation. Never changes a browser
    /// minimum or computes its next mode from the resulting address width.
    func updateLayout(paneWidth: CGFloat) {
        guard paneWidth.isFinite, paneWidth > 0 else { return }
        requestedPaneWidth = paneWidth
        applyAllocation()
    }
    var preferredLayoutWidth: CGFloat { preferredWidth.constant }
    private func applyAllocation() {
        guard let browser else { return }
        let desired = prefersCompact || requestedPaneWidth < Self.compactThreshold
        // Reparenting a live editor can end native input/marked text. Pin the
        // current presentation until editing AND popup tracking have ended.
        if desired != isCompact && field.currentEditor() == nil && !isPresented && popover == nil {
            isCompact = desired
            button.isHidden = !desired
            placeField(in: desired ? content.view : view, inset: desired ? 12 : 0)
        }
        let minimum: CGFloat = isCompact ? 24 : (browser.workspace == nil ? 170 : 100)
        let preferred = isCompact ? 24 : min(230, max(minimum, requestedPaneWidth * 0.24))
        if minimumWidth.constant != minimum { minimumWidth.constant = minimum }
        if preferredWidth.constant != preferred { preferredWidth.constant = preferred }
    }
    private func placeField(in parent: NSView, inset: CGFloat) {
        guard field.superview !== parent else { return }
        NSLayoutConstraint.deactivate(fieldConstraints)
        field.removeFromSuperview()
        field.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(field)
        fieldConstraints = [
            field.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            field.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        ]
        NSLayoutConstraint.activate(fieldConstraints)
    }

    /// The address row owns exactly one visible query editor. Advanced filters
    /// may open below it, but never introduce a second competing query field.
    func showSearchField() {
        guard let browser else { return }
        replaceField(with: browser.metadataSearch.queryField)
        synchronize()
    }
    func showFilterField() {
        guard let browser else { return }
        replaceField(with: browser.filterField)
        rebuildScopeMenu()
    }
    private func replaceField(with next: NSSearchField) {
        guard field !== next else { return }
        contextWillChange()
        NSLayoutConstraint.deactivate(fieldConstraints)
        field.removeFromSuperview()
        field = next
        placeField(in: isCompact ? content.view : view, inset: isCompact ? 12 : 0)
    }
    private func rebuildScopeMenu() {
        guard let browser else { return }
        if browser.isArchiveLocation {
            rebuildArchiveScopeMenu(browser.currentArchive?.state.scope ?? browser.tabs[browser.activeIndex].archiveState?.scope ?? .folder)
            return
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: displaysSearch ? "magnifyingglass" : "line.3.horizontal.decrease", accessibilityDescription: "Filter and search scope")
        menu.addItem(header)
        for (index, title) in ["Filter this folder · loaded items only", "Search Folder · include subfolders", "Search This Mac · indexed filenames"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(scopeChosen(_:)), keyEquivalent: "")
            item.tag = index; item.target = self
            item.isEnabled = index == 2 || (index == 1 ? browser.metadataSearch.canSearchFolder : !browser.showsComputerVolumes)
            if index == 1 && !item.isEnabled { item.title = "Search Folder · open a subfolder first" }
            item.state = (displaysSearch ? browser.metadataSearch.scopePopup.indexOfSelectedItem + 1 : 0) == index ? .on : .off
            menu.addItem(item)
        }
        scopeButton.menu = menu
        let inline = menu.copy() as! NSMenu
        inline.removeItem(at: 0) // NSPopUpButton's image header is not a command
        inline.addItem(.separator())
        browser.metadataSearch.appendSearchOptions(to: inline)
        browser.filterField.searchMenuTemplate = inline
        browser.metadataSearch.queryField.searchMenuTemplate = inline
        button.menu = inline
    }
    private func rebuildArchiveScopeMenu(_ scope: ArchiveSearchScope) {
        let menu = NSMenu(); menu.autoenablesItems = false
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Archive name search scope")
        menu.addItem(header)
        for (index, title) in ["This folder in the archive", "Entire archive · recorded names"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(archiveScopeChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = (scope == .archive ? 1 : 0) == index ? .on : .off
            menu.addItem(item)
        }
        scopeButton.menu = menu
        let inline = menu.copy() as! NSMenu; inline.removeItem(at: 0)
        browser?.filterField.searchMenuTemplate = inline; button.menu = inline
        presentedArchiveScope = scope
    }
    @objc private func archiveScopeChosen(_ sender: NSMenuItem) {
        guard let browser, browser.isArchiveLocation, !browser.isBrowserSuspended, (0...1).contains(sender.tag) else { return }
        browser.currentArchive?.setScope(sender.tag == 1 ? .archive : .folder)
    }
    @objc private func scopeChosen(_ sender: NSMenuItem) { selectScope(sender.tag) }
    func selectScope(_ index: Int) {
        guard let browser, !browser.isRemoteLocation, !browser.isArchiveLocation, (0...2).contains(index), index == 2 || (index == 1 ? browser.metadataSearch.canSearchFolder : !browser.showsComputerVolumes) else { return }
        let text = field.stringValue
        if index == 0 {
            browser.metadataSearch.cancel()
            showFilterField()
            field.stringValue = text
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            synchronize(); focus()
        } else {
            browser.metadataSearch.show(scopeIndex: index - 1)
            field.stringValue = text
            synchronize(); focus()
        }
    }

    /// Navigation resets an ephemeral scope choice; preference edits alone never
    /// replace the current query, selection, results or pane's editor.
    func resetDefaultAfterNavigation() { appliesDefaultOnSynchronization = true }

    var hasUnsubmittedDraft: Bool {
        displaysSearch && browser?.metadataSearch.isShowingResults == false && !field.stringValue.isEmpty
    }

    /// Read the current model; never introduce a second filter value.
    func synchronize() {
        guard let browser else { return }
        if browser.isArchiveLocation {
            presentedArchive = true
            replaceField(with: browser.filterField)
            field.isEnabled = !browser.isBrowserSuspended; button.isEnabled = field.isEnabled
            scopeButton.isEnabled = field.isEnabled
            let scope = browser.currentArchive?.state.scope ?? browser.tabs[browser.activeIndex].archiveState?.scope ?? .folder
            if presentedArchiveScope != scope { rebuildArchiveScopeMenu(scope) }
            field.placeholderString = "Find archive names"
            field.setAccessibilityLabel("Find archive names")
            field.toolTip = scope == .archive ? "Find recorded names throughout this archive." : "Find recorded names in this archive folder. Change scope with the search menu."
            synchronizeNameFindButton(label: "Find archive names", query: browser.currentArchive?.query
                ?? browser.tabs[browser.activeIndex].archiveState?.query ?? "")
            return
        }
        if presentedArchive { presentedArchive = false; presentedArchiveScope = nil; rebuildScopeMenu() }
        if browser.isRemoteLocation {
            replaceField(with: browser.filterField)
            field.isEnabled = browser.hasLiveRemoteNavigation; button.isEnabled = field.isEnabled; scopeButton.isEnabled = false
            field.placeholderString = "Find in this folder"
            field.setAccessibilityLabel("Find names in this remote folder")
            field.toolTip = "Find file and folder names here. Case is ignored; accents and punctuation match exactly. Searches this folder only, without reading file contents."
            if field.currentEditor() == nil { field.stringValue = browser.remoteLoadedQuery }
            synchronizeNameFindButton(label: "Find names in this remote folder", query: browser.remoteLoadedQuery)
            return
        }
        if !displaysSearch { field.setAccessibilityLabel("Filter filenames in this folder") }
        scopeButton.isEnabled = true
        if appliesDefaultOnSynchronization && !browser.isBrowserSuspended {
            appliesDefaultOnSynchronization = false
            let scope: Int
            if browser.location == .computer { scope = 2 }
            // Restored tabs, Back/Forward and reopened visits retain their row
            // filter. Reveal it instead of hiding it behind an empty default
            // search editor while it continues to narrow the displayed rows.
            else if !browser.tabs[browser.activeIndex].filter.isEmpty { scope = 0 }
            else if !browser.metadataSearch.canSearchFolder { scope = 2 }
            else { scope = browser.settings.defaultSearchScope.index }
            if scope == 0 { replaceField(with: browser.filterField) }
            else {
                browser.metadataSearch.scopePopup.selectItem(at: scope - 1)
                replaceField(with: browser.metadataSearch.queryField)
            }
        }
        let enabled = !browser.isBrowserSuspended && (displaysSearch || (!browser.showsComputerVolumes && !browser.metadataSearch.isShowingResults))
        field.isEnabled = enabled
        if displaysSearch { browser.filterField.isEnabled = false }
        button.isEnabled = enabled
        let active = enabled && !field.stringValue.isEmpty
        button.image = displaysSearch ? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search filenames") : (active ? activeImage : idleImage)
        button.setAccessibilityValue(enabled ? (active ? field.stringValue : "No folder filter") : "Unavailable")
        let help: String
        if displaysSearch {
            let scope = browser.metadataSearch.scopePopup.indexOfSelectedItem == 1 ? "This Mac · Spotlight index" : "this folder and subfolders"
            help = "Search filenames in " + scope + "; Return runs the search."
            field.placeholderString = browser.metadataSearch.scopePopup.indexOfSelectedItem == 1 ? "Search This Mac" : "Search folder + subfolders"
            button.setAccessibilityLabel("Search filenames")
        }
        else if browser.metadataSearch.isShowingResults { help = "Folder filtering is unavailable in search results. Use the search controls." }
        else if browser.showsComputerVolumes { help = "Open a folder to filter its filenames." }
        else {
            help = active ? "Folder filter is active: " + field.stringValue + ". Open to edit or clear (⌘F)." : "Filter loaded filenames only (⌘F). Choose a search scope for subfolders or This Mac."
            field.placeholderString = "Filter loaded filenames"
            button.setAccessibilityLabel("Filter this folder")
        }
        button.toolTip = help
        button.setAccessibilityHelp(help)
        field.toolTip = help
        scopeButton.isEnabled = !browser.isBrowserSuspended
        rebuildScopeMenu()
        if !enabled { dismiss() }
    }

    private func synchronizeNameFindButton(label: String, query: String) {
        button.image = NSImage(systemSymbolName: query.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill",
            accessibilityDescription: label)
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(button.isEnabled ? (query.isEmpty ? "No name filter" : query) : "Unavailable")
        button.toolTip = field.toolTip
        button.setAccessibilityHelp(field.toolTip)
    }

    @objc private func openFilter(_ sender: Any?) { focus() }
    func focus() {
        guard let browser, let context = liveContext(), field.isEnabled else { return }
        if field.currentEditor() == nil {
            if !displaysSearch { field.stringValue = browser.isArchiveLocation
                ? browser.currentArchive?.query ?? browser.tabs[browser.activeIndex].archiveState?.query ?? ""
                : browser.isRemoteLocation ? browser.remoteLoadedQuery : browser.tabs[browser.activeIndex].filter }
            synchronize()
        }
        if !isCompact {
            field.window?.makeFirstResponder(field); field.selectText(nil)
            return
        }
        if let popover {
            guard popover.isShown, popoverContext == context else { return }
            field.window?.makeFirstResponder(field); field.selectText(nil)
            return
        }
        guard button.window != nil, !button.isHiddenOrHasHiddenAncestor else { return }
        placeField(in: content.view, inset: 12)
        let popup = NSPopover()
        popup.behavior = .transient
        popup.delegate = self
        popup.contentViewController = content
        popup.contentSize = NSSize(width: 260, height: 46)
        popover = popup; popoverContext = context
        popup.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        // SDK: showing against a hidden anchor does nothing. Do not invent an
        // offscreen popup/field-editor success or reveal the owner's window.
        guard popup.isShown else { popover = nil; popoverContext = nil; return }
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
        installPopoverCommands()
    }
    func dismiss() {
        removePopoverCommands()
        popover?.close()
        // Focus is deliberately left to the explicit command/click target.
        // Never restore focus asynchronously after a transient click-away.
    }
    func contextWillChange() {
        suppressTextChanges = true
        editingContext = nil; editingFieldEditor = nil
        // Finish while old UI ownership is still known; any end/commit callback
        // generated by this resignation cannot write into the next visit/tab.
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        dismiss()
        suppressTextChanges = false
    }

    func beganEditing(_ notification: Notification) {
        guard let context = liveContext(),
              let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        if isCompact { guard isPresented, popoverContext == context else { return } }
        editingContext = context; editingFieldEditor = editor
    }
    func permitsTextChange(_ notification: Notification) -> Bool {
        guard !suppressTextChanges, let browser, !browser.isBrowserSuspended,
              !browser.showsComputerVolumes, !browser.metadataSearch.isShowingResults else { return false }
        if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            return editor === editingFieldEditor && editingContext == liveContext()
        }
        // Preserve existing explicit non-editor model updates/verification.
        return field.currentEditor() == nil || editingContext == liveContext()
    }
    /// A native Cancel sends the search field's action even without an editor.
    /// Admit only the currently displayed, live Filter; editor notifications
    /// retain their separate visit-bound validation above.
    func permitsEmptyFilterAction(_ sender: NSSearchField) -> Bool {
        guard !suppressTextChanges, let browser, sender === browser.filterField,
              sender === field, !displaysSearch, sender.stringValue.isEmpty,
              sender.isEnabled, !sender.isHiddenOrHasHiddenAncestor,
              let context = liveContext(), let window = sender.window,
              window.attachedSheet == nil else { return false }
        if isCompact { guard isPresented, popoverContext == context else { return false } }
        if let editor = sender.currentEditor() as? NSTextView {
            return editor === editingFieldEditor && editingContext == context && !editor.hasMarkedText()
        }
        return true
    }
    func endedEditing(_ notification: Notification) {
        if notification.userInfo?["NSFieldEditor"] as? NSTextView === editingFieldEditor {
            editingContext = nil; editingFieldEditor = nil
        }
        scheduleAllocation()
    }
    private func scheduleAllocation() {
        layoutTask?.cancel()
        layoutTask = Task { @MainActor [weak self] in
            await Task.yield() // end-edit notification may precede editor release
            guard !Task.isCancelled else { return }
            self?.applyAllocation()
        }
    }
    func popoverWillClose(_ notification: Notification) { removePopoverCommands() }
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover = nil; popoverContext = nil
        scheduleAllocation()
    }
    private func removePopoverCommands() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    private func installPopoverCommands() {
        removePopoverCommands()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let browser = self.browser, self.isPresented,
                  event.window === self.field.window, self.popoverContext == self.liveContext(),
                  browser.settings.behavior.explorerFunctionKeysEnabled else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 97 && (flags.isEmpty || flags == .shift) {
                self.dismiss()
                browser.cycleBrowserFocus(backward: flags == .shift, startingAt: self.focusTarget)
                return nil
            }
            if event.keyCode == 118 && flags.isEmpty {
                self.dismiss(); browser.focusLocation(nil)
                return nil
            }
            // Never intercept normal text, marked text, Escape, copy/paste or
            // Control-F's native text meaning. The native field owns those.
            return event
        }
    }
}
