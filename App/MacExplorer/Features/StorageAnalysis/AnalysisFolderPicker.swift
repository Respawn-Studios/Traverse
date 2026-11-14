import AppKit
import Combine
import ExplorerCore
import LocalStorage

@MainActor
final class AnalysisFolderPickerController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    let model: AnalysisFolderPickerModel
    private let settings: BrowserSettings
    private var style: AnalysisFolderPickerStyle
    let pathField = NSTextField()
    let filter = NSSearchField()
    let chooseButton = NSButton(title: "Choose Folder", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let back = NSButton(), forward = NSButton(), up = NSButton()
    private let selectedPath = NSTextField(labelWithString: "")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let layoutControl = NSSegmentedControl(labels: ["Explorer", "Columns"], trackingMode: .selectOne, target: nil, action: nil)
    private let remember = NSButton(checkboxWithTitle: "Remember folder access", target: nil, action: nil)
    private let contentHost = NSView()
    private var tables: [AnalysisPickerTable] = []
    private weak var parent: NSWindow?
    private var waiter: CheckedContinuation<URL?, Never>?
    private var chosen: URL?
    private var ending = false
    private var cancellationRequested = false
    private var nativeTask: Task<Void, Never>?
    private let completionService = DirectoryCompletionService(activityGate: ApplicationFileActivity.gate)
    private var completionSession: DirectoryCompletionSession?
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private let completionOwner = UUID()
    private var suggestions: [AddressSuggestion] = []
    private var suggestionIndex = 0
    private var explicitlySelectedSuggestion = false
    private let suggestionPanel = AnalysisPickerSuggestionPanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let suggestionRows = NSStackView()
    private let ghost = AddressGhostView()
    private var applyingCompletion = false
    private var hasUnsubmittedPath = false
    private var renderedContentKey = ""
    private var editorObservation: BrowserNotificationObservation?
    private var layoutObservation: AnyCancellable?
    #if DEBUG
    var tablesForVerification: [NSTableView] { tables.map(\.table) }
    var stateForVerification: String { state.stringValue }
    var styleForVerification: AnalysisFolderPickerStyle { style }
    func setStyleForVerification(_ value: AnalysisFolderPickerStyle) { style = value; render() }
    func startForVerification() { model.start() }
    #endif

    init(model: AnalysisFolderPickerModel, settings: BrowserSettings, style: AnalysisFolderPickerStyle,
         title: String = "Choose a Folder to Analyze") {
        self.model = model; self.settings = settings; self.style = style == .columns ? .columns : .explorer
        let panel = AnalysisPickerPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.minSize = NSSize(width: 740, height: 460); panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel); panel.delegate = self
        panel.locate = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.pathField); self.pathField.selectText(nil)
        }
        panel.navigate = { [weak self] key in
            guard let self, self.pathField.currentEditor() == nil, self.filter.currentEditor() == nil else { return false }
            if key == "up" { self.goUp() }
            else if key == "back" { self.goBack() }
            else { self.goForward() }
            return true
        }
        build()
        ToolWindowChrome.install(in: panel, settings: settings)
        model.onChange = { [weak self] in self?.render() }
        layoutObservation = settings.$analysisFolderPicker.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] value in
                guard let self, !self.ending, value != .system, value != self.style else { return }
                self.style = value; self.cancelCompletion(); self.render()
            }
    }
    required init?(coder: NSCoder) { nil }

    func choose(in parent: NSWindow) async -> URL? {
        self.parent = parent
        guard let window else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
                parent.beginSheet(window) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { continuation.resume(returning: nil); return }
                        self.cancelCompletion()
                        await self.model.cancelAndDrain()
                        self.waiter = nil
                        continuation.resume(returning: self.cancellationRequested ? nil : self.chosen)
                    }
                }
                model.start()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() {
        cancellationRequested = true; nativeTask?.cancel()
        if nativeTask == nil { finish(nil) }
    }

    private func finish(_ url: URL?) {
        guard !ending else { return }
        ending = true; chosen = url; cancelCompletion()
        if let window, parent?.attachedSheet === window { parent?.endSheet(window) }
        else { window?.orderOut(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func windowDidResignKey(_ notification: Notification) { cancelCompletion() }
    func windowDidResize(_ notification: Notification) { cancelCompletion() }

    private func build() {
        guard let content = window?.contentView else { return }
        // The path editor can become first responder before the first listing
        // arrives. Seed it now so render need not overwrite an active editor.
        pathField.stringValue = model.location.directoryURL?.path ?? "This Mac"
        pathField.delegate = self; pathField.placeholderString = "Enter a folder path"
        pathField.setAccessibilityIdentifier("analysis-picker-path")
        pathField.setAccessibilityHelp("Tab fills a highlighted completion; Return opens the entered path.")
        filter.delegate = self; filter.placeholderString = "Filter this level"
        filter.widthAnchor.constraint(equalToConstant: 145).isActive = true
        for (button, symbol, title, selector) in [(back, "chevron.left", "Back", #selector(goBack)),
            (forward, "chevron.right", "Forward", #selector(goForward)), (up, "arrow.up", "Parent folder", #selector(goUp))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imageScaling = .scaleProportionallyDown; button.bezelStyle = .rounded
            button.target = self; button.action = selector; button.toolTip = title
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let system = AnalysisPickerButton("Use System Picker…") { [weak self] in self?.chooseSystem() }
        let navigation = stack([back, forward, up, pathField, filter, system], orientation: .horizontal, spacing: 6)
        layoutControl.target = self; layoutControl.action = #selector(layoutChanged)
        layoutControl.setAccessibilityIdentifier("analysis-picker-layout")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = stack([label("Choose a folder to analyze", size: 15), spacer, layoutControl], orientation: .horizontal)
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 3
        sidebar.widthAnchor.constraint(equalToConstant: 144).isActive = true
        func location(_ name: String, symbol: String, target: BrowserLocation) {
            let button = AnalysisPickerButton(name) { [weak self] in self?.navigate(target) }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown
            button.alignment = .left; button.bezelStyle = .recessed; button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 140).isActive = true
            sidebar.addArrangedSubview(button)
        }
        location("This Mac", symbol: "desktopcomputer", target: .computer)
        sidebar.addArrangedSubview(label("Places", size: 11, color: .secondaryLabelColor))
        if let home = BrowsingHome.url {
            for (name, part, symbol) in [("Home", "", "house"), ("Desktop", "Desktop", "desktopcomputer"),
                ("Documents", "Documents", "doc"), ("Downloads", "Downloads", "arrow.down.circle")] {
                location(name, symbol: symbol, target: .directory(part.isEmpty ? home : home.appendingPathComponent(part, isDirectory: true)))
            }
        }
        sidebar.addArrangedSubview(label("Locations", size: 11, color: .secondaryLabelColor))
        for volume in model.volumes { location(volume.name, symbol: "externaldrive", target: .directory(volume.url)) }
        sidebar.addArrangedSubview(NSView())
        let browser = stack([sidebar, contentHost], orientation: .horizontal, spacing: 12)
        browser.alignment = .top
        sidebar.heightAnchor.constraint(equalTo: browser.heightAnchor).isActive = true
        contentHost.heightAnchor.constraint(equalTo: browser.heightAnchor).isActive = true
        browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        selectedPath.isSelectable = true; selectedPath.lineBreakMode = .byTruncatingMiddle
        selectedPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedPath.setAccessibilityIdentifier("analysis-picker-selection")
        chooseButton.target = self; chooseButton.action = #selector(confirm)
        chooseButton.keyEquivalent = "\r"; chooseButton.bezelStyle = .rounded
        chooseButton.setAccessibilityIdentifier("analysis-picker-confirm")
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.bezelStyle = .rounded
        remember.isEnabled = model.access.canRememberFolders
        let grant = AnalysisPickerButton("Grant Access…") { [weak self] in self?.chooseSystem() }
        let footer = stack([selectedPath, grant, cancelButton, chooseButton], orientation: .horizontal)
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor
        let disclaimer = NSTextField(wrappingLabelWithString: "Metadata only. Choosing a path here does not grant access; the system picker remains available. Remembering is explicit and local.")
        disclaimer.font = .systemFont(ofSize: 11); disclaimer.textColor = .secondaryLabelColor
        let body = stack([header, navigation, browser, state, remember, footer, disclaimer], orientation: .vertical, spacing: 10)
        pin(body, inside: content, inset: 16)
        for view in [header, navigation, browser, state, footer, disclaimer] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        suggestionRows.orientation = .vertical; suggestionRows.alignment = .leading; suggestionRows.spacing = 3
        let background = NSVisualEffectView(); background.material = .popover
        background.blendingMode = .withinWindow; background.state = .active
        suggestionPanel.contentView = background; suggestionPanel.isReleasedWhenClosed = false
        suggestionPanel.hasShadow = true; suggestionPanel.hidesOnDeactivate = true
        pin(suggestionRows, inside: background, inset: 6)
    }

    private func render() {
        guard !ending else { return }
        let editingPath = pathField.currentEditor() != nil
        if !editingPath && !hasUnsubmittedPath { pathField.stringValue = model.location.directoryURL?.path ?? "This Mac" }
        back.isEnabled = model.canGoBack; forward.isEnabled = model.canGoForward
        up.isEnabled = model.location.parent != nil
        layoutControl.selectedSegment = style == .columns ? 1 : 0
        let target = model.confirmationURL
        chooseButton.isEnabled = target != nil && !hasUnsubmittedPath
        selectedPath.stringValue = "Selected: " + (target?.path ?? "Choose an available folder")
        selectedPath.toolTip = target?.path
        chooseButton.setAccessibilityLabel(target.map { "Choose folder \($0.path)" } ?? "Choose Folder")
        state.stringValue = hasUnsubmittedPath
            ? "Press Return to open the edited path, or Escape to restore the current folder."
            : model.levels.last?.message ?? ""
        let contentKey = style.rawValue + "|" + filter.stringValue + "|" + model.levels.map {
            "\($0.id):\($0.entries.count):\($0.loading)"
        }.joined(separator: "|")
        // Selection alone must not replace the native table during its mouse
        // tracking loop: doing that loses double-click and keyboard continuity.
        guard contentKey != renderedContentKey else { return }
        renderedContentKey = contentKey
        tables.removeAll(); contentHost.subviews.forEach { $0.removeFromSuperview() }
        let indices = style == .columns ? Array(model.levels.indices) : model.levels.indices.suffix(1).map { $0 }
        let columns = NSStackView(); columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 0
        for index in indices {
            let level = model.levels[index]
            let query = filter.stringValue
            let entries = level.entries.filter { query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            let table = AnalysisPickerTable(entries: entries, details: style == .explorer,
                selected: model.selectedURL ?? (index + 1 < model.levels.count ? model.levels[index + 1].location.directoryURL : nil))
            table.onSelect = { [weak self] entry in
                guard let self else { return }
                if self.style == .columns { self.navigate(.directory(entry.url), appendAfter: index) }
                else { self.model.select(entry.url) }
            }
            table.onOpen = { [weak self] entry in self?.navigate(.directory(entry.url), appendAfter: index) }
            tables.append(table)
            let pane = stack([label(level.location.displayName, size: 11, color: .secondaryLabelColor), table.scroll], orientation: .vertical, spacing: 5)
            table.scroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
            columns.addArrangedSubview(pane)
            if style == .columns { pane.widthAnchor.constraint(equalToConstant: 210).isActive = true }
            else { pane.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true }
            pane.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        }
        if style == .columns {
            let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
            scroll.documentView = columns
            columns.translatesAutoresizingMaskIntoConstraints = false
            columns.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor).isActive = true
            columns.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true
            pin(scroll, inside: contentHost)
            columns.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: max(0, columns.fittingSize.width - contentHost.bounds.width), y: 0))
        } else { pin(columns, inside: contentHost) }
    }

    private func navigate(_ target: BrowserLocation, appendAfter: Int? = nil) {
        hasUnsubmittedPath = false
        cancelCompletion(); filter.stringValue = ""; window?.makeFirstResponder(nil)
        model.navigate(target, appendAfter: appendAfter)
    }
    @objc private func goBack() { hasUnsubmittedPath = false; cancelCompletion(); window?.makeFirstResponder(nil); model.goBack() }
    @objc private func goForward() { hasUnsubmittedPath = false; cancelCompletion(); window?.makeFirstResponder(nil); model.goForward() }
    @objc private func goUp() { hasUnsubmittedPath = false; cancelCompletion(); window?.makeFirstResponder(nil); model.goUp() }
    @objc private func confirm() { guard !hasUnsubmittedPath, let url = model.confirmationURL else { return }; finish(url) }
    @objc private func cancelPressed() { cancel() }
    @objc private func layoutChanged() {
        style = layoutControl.selectedSegment == 1 ? .columns : .explorer
        settings.analysisFolderPicker = style; cancelCompletion(); render()
    }

    private func chooseSystem() {
        guard nativeTask == nil, let window else { return }
        cancelCompletion()
        nativeTask = Task { [weak self] in
            guard let self else { return }
            let choice = await self.model.access.chooseFolder(in: window,
                initialDirectory: self.model.confirmationURL ?? self.model.location.directoryURL,
                remember: self.remember.state == .on)
            self.nativeTask = nil
            if self.cancellationRequested { self.finish(nil) }
            else if let choice { self.finish(choice.selection.url) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === filter { render() }
        else if field === pathField, !applyingCompletion {
            hasUnsubmittedPath = true; render(); requestCompletions()
        }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === pathField, let editor = pathField.currentEditor() as? NSTextView else { return }
        editorObservation = BrowserNotificationObservation(name: NSTextView.didChangeSelectionNotification, object: editor) { [weak self, weak editor] _ in
            MainActor.assumeIsolated {
                guard let self, let editor else { return }
                if editor.hasMarkedText() || editor.selectedRange() != NSRange(location: editor.string.utf16.count, length: 0) {
                    self.cancelCompletion()
                }
            }
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) { editorObservation = nil; cancelCompletion(); render() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pathField else { return false }
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertTab(_:)), suggestions.indices.contains(suggestionIndex),
           suggestions[suggestionIndex].match != .approximate || explicitlySelectedSuggestion { applySuggestion(); return true }
        if selector == #selector(NSResponder.moveDown(_:)), !suggestions.isEmpty {
            suggestionIndex = !explicitlySelectedSuggestion && suggestions[0].match == .approximate ? 0 : min(suggestions.count - 1, suggestionIndex + 1)
            explicitlySelectedSuggestion = true
            showSuggestions(); return true
        }
        if selector == #selector(NSResponder.moveUp(_:)), !suggestions.isEmpty {
            suggestionIndex = max(0, suggestionIndex - 1); explicitlySelectedSuggestion = true
            showSuggestions(); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if explicitlySelectedSuggestion { applySuggestion() }
            cancelCompletion()
            if model.navigate(text: pathField.stringValue) {
                hasUnsubmittedPath = false; window?.makeFirstResponder(nil); render()
            }
            else { state.stringValue = "Enter an absolute path (/ or ~/), or choose a folder suggestion before Return." }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if !suggestions.isEmpty { cancelCompletion(); return true }
            hasUnsubmittedPath = false
            pathField.stringValue = model.location.directoryURL?.path ?? "This Mac"
            window?.makeFirstResponder(nil); render(); return true
        }
        return false
    }

    private func requestCompletions() {
        cancelCompletion()
        guard settings.addressPresentation != .off, let editor = pathField.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0) else { return }
        let text = editor.string, token = completionGeneration
        completionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, self.completionGeneration == token else { return }
            if let home = BrowsingHome.completionHome(for: text),
                let request = try? AddressCompletionRequest(text: text, home: home,
                showsHidden: self.settings.showsHiddenFiles, symbolTolerant: self.settings.symbolTolerantNames) {
                let lease = await self.model.access.acquireAccess(to: request.parent)
                guard !Task.isCancelled else { return }
                let session = self.completionService.start(owner: self.completionOwner, request: request,
                    policy: .init(maximumSuggestions: self.settings.addressSuggestionLimit),
                    retaining: FileAccessLifetimes(leases: lease.map { [$0] } ?? []))
                self.completionSession = session
                do {
                    for try await result in session.results {
                        guard !Task.isCancelled, self.completionGeneration == token, self.pathField.stringValue == text else { return }
                        self.suggestions = result.suggestions; self.showSuggestions()
                    }
                } catch { /* Completion is optional; keep the exact editable input. */ }
            } else {
                self.suggestions = (self.model.levels.last?.entries ?? []).filter {
                    !text.isEmpty && $0.name.range(of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
                }.prefix(self.settings.addressSuggestionLimit).map {
                    AddressSuggestion(name: $0.name, completedText: $0.url.path + "/", url: $0.url, match: .prefix, source: .familiar)
                }
                self.showSuggestions()
            }
        }
    }

    private func showSuggestions() {
        guard !suggestions.isEmpty, let window, window.isKeyWindow else { return }
        suggestionIndex = min(suggestionIndex, suggestions.count - 1)
        suggestionRows.arrangedSubviews.forEach { suggestionRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, suggestion) in suggestions.enumerated() {
            let button = AnalysisPickerButton(suggestion.completedText) { [weak self] in
                self?.suggestionIndex = index; self?.applySuggestion()
            }
            button.alignment = .left; button.bezelStyle = .recessed
            button.state = index == suggestionIndex && (suggestion.match != .approximate || explicitlySelectedSuggestion) ? .on : .off
            suggestionRows.addArrangedSubview(button)
        }
        if settings.addressPresentation.showsDropdown {
            let frame = window.convertToScreen(pathField.convert(pathField.bounds, to: nil))
            suggestionPanel.setFrame(NSRect(x: frame.minX, y: frame.minY - CGFloat(suggestions.count * 27 + 12),
                width: max(280, frame.width), height: CGFloat(suggestions.count * 27 + 12)), display: true)
            window.addChildWindow(suggestionPanel, ordered: .above); suggestionPanel.orderFront(nil)
        }
        if settings.addressPresentation.showsInline, let editor = pathField.currentEditor() as? NSTextView,
           let suffix = suggestions[suggestionIndex].ghostSuffix(after: editor.string) {
            editor.addSubview(ghost)
            let screen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let rect = editor.convert(window.convertFromScreen(screen), from: nil)
            ghost.frame = NSRect(x: rect.minX + 1, y: rect.minY,
                width: max(0, editor.visibleRect.maxX - rect.minX - 3), height: rect.height)
            ghost.text = suffix; ghost.font = editor.font ?? .systemFont(ofSize: 13)
            ghost.isHidden = false; ghost.needsDisplay = true
        }
    }
    private func applySuggestion() {
        guard suggestions.indices.contains(suggestionIndex) else { return }
        hasUnsubmittedPath = true
        applyingCompletion = true; pathField.stringValue = suggestions[suggestionIndex].completedText
        if let editor = pathField.currentEditor() as? NSTextView { editor.string = pathField.stringValue; editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
        applyingCompletion = false; cancelCompletion(); render()
    }
    private func cancelCompletion() {
        completionGeneration = UUID(); completionTask?.cancel(); completionTask = nil
        completionSession?.cancel(); completionSession = nil; suggestions = []; suggestionIndex = 0
        explicitlySelectedSuggestion = false; ghost.removeFromSuperview()
        suggestionPanel.parent?.removeChildWindow(suggestionPanel); suggestionPanel.orderOut(nil)
    }
}

@MainActor
private final class AnalysisPickerPanel: NSPanel {
    var locate: (() -> Void)?
    var navigate: ((String) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            if event.charactersIgnoringModifiers == "l" { locate?(); return true }
            if event.keyCode == 126, navigate?("up") == true { return true }
            if event.charactersIgnoringModifiers == "[", navigate?("back") == true { return true }
            if event.charactersIgnoringModifiers == "]", navigate?("forward") == true { return true }
        }
        if flags == .option, event.keyCode == 123, navigate?("back") == true { return true }
        if flags == .option, event.keyCode == 124, navigate?("forward") == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AnalysisPickerButton: NSButton {
    private let callback: () -> Void
    init(_ title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(frame: .zero); self.title = title; target = self; action = #selector(invoke)
        bezelStyle = .rounded
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { callback() }
}

@MainActor
private final class AnalysisPickerSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AnalysisPickerTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView(), scroll = NSScrollView()
    private let entries: [FileEntry]
    var onSelect: ((FileEntry) -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    init(entries: [FileEntry], details: Bool, selected: URL?) {
        self.entries = entries
        super.init()
        for (id, title, width) in [("name", "Name", 290.0), ("modified", "Date Modified", 150.0), ("kind", "Kind", 75.0)] where details || id == "name" {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "name" ? 140 : 65; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.style = .plain
        InterfaceMetrics.setRowHeight(table, base: 27); table.target = self; table.doubleAction = #selector(open)
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        if !details { table.headerView = nil }
        table.setAccessibilityLabel(details ? "Choose a folder — details" : "Choose a folder — column")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = details
        if let selected, let row = entries.firstIndex(where: { $0.url == selected }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row], id = tableColumn?.identifier.rawValue ?? "name"
        if id == "name" {
            let image = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .systemYellow; image.imageScaling = .scaleProportionallyDown
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            image.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = label(entry.name); name.lineBreakMode = .byTruncatingMiddle
            let view = stack([image, name], orientation: .horizontal, spacing: 7)
            view.setAccessibilityLabel(entry.name); return view
        }
        return label(id == "kind" ? "Folder" : entry.modifiedAt.map { Self.date.string(from: $0) } ?? "—", size: 12, color: .secondaryLabelColor)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard entries.indices.contains(table.selectedRow) else { return }
        onSelect?(entries[table.selectedRow])
    }
    @objc private func open() { guard entries.indices.contains(table.clickedRow) else { return }; onOpen?(entries[table.clickedRow]) }
}
