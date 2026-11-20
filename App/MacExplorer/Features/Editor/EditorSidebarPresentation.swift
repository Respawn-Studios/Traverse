import AppKit
import Combine

/// The editor borrows the browser's clipped, live sidebar transition without
/// becoming a browser pane. Its existing text surface stays installed.
@MainActor final class EditorSidebarPresentation {
    let split = NativeSidebarSplitView()
    let button = NSButton(frame: .zero)
    private let text: NativeTextEditorSurface
    private var observation: AnyCancellable?
    private(set) var files: EditorFileSidebar?
    var isShown: Bool { !split.isSidebarCollapsed }
    var visit: EditorSidebarVisit? { files?.visit(shown: isShown, width: split.sidebarWidth) }

    init(text: NativeTextEditorSurface) {
        self.text = text
        let sidebar = NSView(), host = NSView()
        split.setAccessibilityLabel("Editor sidebar and text")
        split.remainingMinimum = { 380 }
        for section in [sidebar, host] { split.addArrangedSubview(section) }
        text.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            text.topAnchor.constraint(equalTo: host.topAnchor), text.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        split.restore(.init(isCollapsed: true, expandedWidth: 224))
        split.onCollapsedChanged = { [weak self] in self?.refresh() }
        split.onPresentationChanged = { [weak self] in
            guard let self, self.isShown, !self.split.isAnimating else { return }
            self.files?.updateAvailableWidth(self.split.sidebarPosition)
            self.files?.updateGitBadges()
        }
        button.bezelStyle = .recessed
        button.imagePosition = .imageOnly
        button.setAccessibilityIdentifier("editor-toggle-sidebar")
        refresh()
    }

    func install(_ files: EditorFileSidebar, settings: BrowserSettings, visit: EditorSidebarVisit?) {
        self.files = files
        files.bindOutline(to: text)
        split.installSidebarContent(files.view)
        split.canCollapse = { [weak self] in self?.canToggle == true }
        split.onToggleRequested = { [weak self] in self?.toggle() }
        observation = settings.$motion.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            split.motion = value
            if split.isAnimating { split.finishAnimation() }
        }
        let initialWidth = 224 * settings.interfaceSize.scale
        split.restore(.init(isCollapsed: !(visit?.shown ?? settings.editorPreferences.opensFileSidebar),
            expandedWidth: Double(visit?.width ?? initialWidth)))
        refresh()
    }

    var canToggle: Bool {
        files != nil && split.window?.attachedSheet == nil && !text.textView.hasMarkedText()
    }

    func toggle() {
        guard canToggle else { return }
        split.setCollapsed(isShown, animated: true)
    }

    func moveFocus() {
        guard canToggle, let files, let window = split.window else { return }
        if files.ownsFocus(window.firstResponder) {
            window.makeFirstResponder(text.textView)
        } else {
            if !isShown { split.setCollapsed(false, animated: true) }
            window.makeFirstResponder(files.outline)
        }
    }

    func showMode(_ mode: EditorSidebarMode) {
        guard canToggle, let files, let window = split.window else { return }
        files.selectMode(mode)
        if !isShown { split.setCollapsed(false, animated: true) }
        if mode == .outline { files.focusOutlineSearch() }
        else { window.makeFirstResponder(files.outline) }
    }

    func windowDidAppear() {
        files?.setVisible(isShown)
        files?.windowDidBecomeKey()
    }
    func windowWillClose() {
        split.finishAnimation(); files?.setVisible(false)
        files?.projectSearch?.dismiss(restoringFocus: false)
    }

    private func refresh() {
        let label = isShown ? "Hide Editor Sidebar" : "Show Editor Sidebar"
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.state = isShown ? .on : .off
        if !isShown, let window = split.window, files?.ownsFocus(window.firstResponder) == true {
            window.makeFirstResponder(text.textView)
        }
        files?.setVisible(isShown && split.window != nil)
        split.window?.recalculateKeyViewLoop()
    }
}
