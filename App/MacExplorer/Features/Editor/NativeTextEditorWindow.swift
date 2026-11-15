import AppKit
import Combine
#if canImport(FileOperations)
import FileOperations
#endif

/// Standard nil-target actions must continue following the focused responder,
/// which may be a document or a Find field rather than this window controller.
@objc private protocol NativeTextUndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

struct EditorTextCopyResult { let id: UUID; let title: String }

/// Native presentation only. The document owner supplies semantic commands and
/// installs the app's shared tool chrome; this class has no file I/O authority.
@MainActor
final class NativeTextEditorWindow: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    enum SaveAnnouncement {
        case saved(newerEditsRemain: Bool), notSaved, conflict, historyNeedsReview, needsReview, stopped

        var message: String {
            switch self {
            case .saved(false): String(localized: "Saved.")
            case .saved(true): String(localized: "Captured text saved. Newer edits remain unsaved.")
            case .notSaved: String(localized: "Not saved. Your text remains in the editor.")
            case .conflict: String(localized: "Not saved. The file changed. Reload or save a copy.")
            case .historyNeedsReview: String(localized: "Not saved. Review saved versions. Your text remains in the editor.")
            case .needsReview: String(localized: "Save needs review. Keep this text and review the result.")
            case .stopped: String(localized: "Save stopped. Your text remains in the editor.")
            }
        }
    }
    let surface = NativeTextEditorSurface(frame: .zero)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let saveAsButton = NSButton(title: "Save As…", target: nil, action: nil)
    let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    let recoveryButton = NSButton(title: "Review Versions…", target: nil, action: nil)
    let beforeSaveButton = NSButton(title: "Before Save", target: nil, action: nil)
    let editedSaveButton = NSButton(title: "Edited Text", target: nil, action: nil)
    var onRefusedVersion: ((RemoteRetainedTextChoice.Version) -> Void)?
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let textCopyButton = NSButton(title: "Save a Text Copy…", target: nil, action: nil)
    let textCopyResultsButton = NSButton(title: "Copy Results…", target: nil, action: nil)
    let wrapping = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    let language = NSPopUpButton()
    private let status = NSTextField(labelWithString: "Ready")
    private let position = NSTextField(labelWithString: "Ln 1, Col 1")
    private let format = NSTextField(labelWithString: "UTF-8 · LF")
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let locationRow = NSStackView()
    private let locationIcon = NSImageView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let recoveryActions = NSStackView()
    private let refusedActions = NSStackView()
    private let copyActions = NSStackView()
    private let commandBar = NSStackView()
    private var closing = false
    private var acceptedCloseEditable: Bool?
    private var hasPresentedEditor = false
    let openSearchID = UUID()
    private var openSearchPresented = false
    private var openSearchName: String
    private var openSearchContext = ""
    private var openSearchStorage: EditorOpenSearch?
    var openSearch: EditorOpenSearch {
        if let openSearchStorage { return openSearchStorage }
        let search = EditorOpenSearch(owner: self); openSearchStorage = search
        return search
    }
    var retainPresentationDuringClose = false
    private var ownMenu: NSMenu?
    private var keyboardObservation: AnyCancellable?
    private weak var keyboardSettings: BrowserSettings?
    private var usesControlAliases = false
    private var lineNavigation: EditorLineNavigationDialog?
    private var comparison: EditorComparisonWindow?
    private var comparisonBlocked = true
    var captureComparison: (@MainActor () -> EditorComparisonCapture?)?
    private var commandFinderStorage: EditorCommandFinder?
    var commandFinder: EditorCommandFinder {
        if let commandFinderStorage { return commandFinderStorage }
        let finder = EditorCommandFinder(owner: self); commandFinderStorage = finder
        return finder
    }
    private var copyResults: [EditorTextCopyResult] = []
    private var readOnlyPresentation = false
    private var consumedSaveAnnouncement: UUID?

    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onTextCopy: (() -> Void)?
    var onTextCopyResults: ((UUID?) -> Void)?
    var onReload: (() -> Void)?
    var onRecovery: (() -> Void)?
    var onStop: (() -> Void)?
    var onLanguage: ((TextSyntaxLanguage) -> Void)?
    var onWrapping: (() -> Void)?
    var saveAsMenuTitle: String?
    var recoveryMenuTitle: String?
    var shouldClose: (() -> Bool)?
    var didClose: (() -> Void)?

    init(displayName: String, installChrome: (NSWindow) -> Void) {
        openSearchName = displayName
        let window = ToolWindowChrome.makeWindow(title: displayName + " — Traverse", size: .init(width: 920, height: 650),
            minimumSize: .init(width: 720, height: 440))
        super.init(window: window)
        window.delegate = self
        surface.setAccessibilityLabel("Text editor")
        for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton, textCopyButton, textCopyResultsButton, beforeSaveButton, editedSaveButton] {
            button.bezelStyle = .rounded; button.target = self
        }
        saveButton.action = #selector(saveDocument(_:))
        saveAsButton.action = #selector(saveDocumentAs(_:))
        reloadButton.action = #selector(reloadDocument(_:))
        recoveryButton.action = #selector(reviewVersions(_:))
        beforeSaveButton.action = #selector(reviewBeforeSave(_:))
        editedSaveButton.action = #selector(reviewEditedSave(_:))
        beforeSaveButton.setAccessibilityIdentifier("editor-refused-before")
        editedSaveButton.setAccessibilityIdentifier("editor-refused-edited")
        beforeSaveButton.toolTip = "Review the retained starting text for this unsubmitted Save."
        editedSaveButton.toolTip = "Review the exact text captured for this unsubmitted Save, including when you typed afterward."
        beforeSaveButton.isHidden = true; editedSaveButton.isHidden = true
        stopButton.action = #selector(stopDocumentWork(_:))
        textCopyButton.action = #selector(saveTextCopy(_:))
        textCopyResultsButton.action = #selector(showTextCopyResults(_:))
        saveButton.setAccessibilityIdentifier("editor-save")
        saveAsButton.setAccessibilityIdentifier("editor-save-as")
        reloadButton.setAccessibilityIdentifier("editor-reload")
        recoveryButton.setAccessibilityIdentifier("editor-versions")
        stopButton.setAccessibilityIdentifier("editor-stop")
        textCopyButton.setAccessibilityIdentifier("editor-save-text-copy")
        textCopyResultsButton.setAccessibilityIdentifier("editor-text-copy-results")
        wrapping.state = .on; wrapping.target = self; wrapping.action = #selector(toggleWrap(_:))
        language.addItems(withTitles: TextSyntaxLanguage.allCases.map(\.title))
        language.target = self; language.action = #selector(changeLanguage(_:))
        language.setAccessibilityLabel("Syntax language")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = commandBar
        for view in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton, spacer] {
            toolbar.addArrangedSubview(view)
        }
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.distribution = .fill; toolbar.alignment = .centerY
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.maximumNumberOfLines = 1; locationLabel.isSelectable = true
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.setAccessibilityIdentifier("editor-location")
        locationLabel.setAccessibilityLabel("Editing location")
        locationIcon.contentTintColor = .secondaryLabelColor
        locationIcon.setAccessibilityElement(false)
        locationIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        locationIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        locationRow.addArrangedSubview(locationIcon); locationRow.addArrangedSubview(locationLabel)
        locationRow.orientation = .horizontal; locationRow.spacing = 6; locationRow.alignment = .centerY
        locationRow.isHidden = true
        banner.maximumNumberOfLines = 6; banner.textColor = .secondaryLabelColor
        banner.font = .systemFont(ofSize: 12); banner.isSelectable = true; banner.isHidden = true
        // Two native rows keep the complete labels available at minimum width
        // and larger interface sizes, without squeezing four actions together.
        refusedActions.addArrangedSubview(beforeSaveButton); refusedActions.addArrangedSubview(editedSaveButton)
        copyActions.addArrangedSubview(textCopyButton); copyActions.addArrangedSubview(textCopyResultsButton)
        for row in [refusedActions, copyActions] {
            row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
            recoveryActions.addArrangedSubview(row)
        }
        refusedActions.isHidden = true; copyActions.isHidden = true
        recoveryActions.orientation = .vertical; recoveryActions.spacing = 8; recoveryActions.alignment = .leading
        recoveryActions.isHidden = true
        textCopyButton.isHidden = true; textCopyButton.isEnabled = false
        textCopyResultsButton.isHidden = true; textCopyResultsButton.isEnabled = false
        let statusSpacer = NSView(); statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [status, statusSpacer, position, format, wrapping, language])
        bottom.orientation = .horizontal; bottom.spacing = 14; bottom.alignment = .centerY
        for label in [status, position, format] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let separator = NSBox(); separator.boxType = .separator
        let layout = NSStackView(views: [toolbar, locationRow, banner, recoveryActions, surface, separator, bottom])
        layout.orientation = .vertical; layout.spacing = 10; layout.alignment = .leading
        layout.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { preconditionFailure("Native editor content") }
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        for view in [toolbar, locationRow, banner, recoveryActions, surface, separator, bottom] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.onCaret = { [weak self] value in
            self?.position.stringValue = value.map { "Ln \($0.line), Col \($0.column)" } ?? "Updating position…"
        }
        surface.lineCommands.onNotice = { [weak self] notice in
            self?.status.stringValue = notice.message
            self?.status.toolTip = notice.message
            self?.status.textColor = .labelColor
        }
        stopButton.isHidden = true; recoveryButton.isHidden = true
        installChrome(window)
        ToolWindowChrome.position(window, relativeTo: NSApp.keyWindow ?? NSApp.mainWindow)
    }
    required init?(coder: NSCoder) { nil }

    /// Presentation only; the document owner still supplies the copy action.
    func configureLocalCopyPresentation() {
        saveAsButton.title = "Save Local Copy…"
        saveAsMenuTitle = saveAsButton.title
        saveAsButton.toolTip = "Create a new text file on your Mac. The server file stays unchanged."
    }

    /// Only the remote document owner can offer exact refused-capture reads.
    func configureRefusedReview(available: Bool, enabled: Bool) {
        let available = available && !readOnlyPresentation
        for button in [beforeSaveButton, editedSaveButton] {
            button.isHidden = !available; button.isEnabled = available && enabled
        }
        refusedActions.isHidden = !available
        recoveryActions.isHidden = !available && copyActions.isHidden
        if available && recoveryButton.title == "Review Versions…" { recoveryButton.title = "All Saved Versions…" }
    }

    /// Immutable current-server snapshots have no writing or export handlers.
    /// Keep the native Find, selection, syntax and line-navigation surface.
    func configureReadOnlyPresentation() {
        readOnlyPresentation = true
        surface.textView.isEditable = false
        commandBar.isHidden = true
        for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton,
                       textCopyButton, textCopyResultsButton] {
            button.isHidden = true; button.isEnabled = false
        }
    }

    /// Native menu equivalents remain scoped to this key editor window. The
    /// existing Explorer/Custom behavior decides whether Control aliases exist;
    /// no global monitor or rewriting of text input is involved.
    func bindKeyboardBehavior(to settings: BrowserSettings) {
        keyboardSettings = settings
        synchronizeKeyboardBehavior()
        keyboardObservation = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeKeyboardBehavior() }
        }
    }
    private func synchronizeKeyboardBehavior() {
        let enabled = keyboardSettings?.behavior.controlAliasesEnabled == true
        guard usesControlAliases != enabled else { return }
        usesControlAliases = enabled
        if EditorMenuOwnership.owns(self), window?.isKeyWindow == true {
            ownMenu = EditorMenuOwnership.claim(self) { makeMenu(base: $0) }
        }
    }

    enum Group {
        case local, connection(UUID)
        var identifier: NSWindow.TabbingIdentifier {
            switch self {
            case .local: .init("Traverse.Editor.Local")
            case .connection(let id): .init("Traverse.Editor.Connection." + id.uuidString)
            }
        }
    }
    /// AppKit owns the tab bar, drag-out and window layout. This changes only
    /// presentation: every document keeps its own buffer, Save and close owner.
    func presentEditor(in group: Group, arrangement: EditorWindowArrangement) {
        guard !closing, let window else { return }
        if !hasPresentedEditor {
            window.tabbingIdentifier = group.identifier
            // Explicit grouping avoids pulling a window into a different Space
            // or a group with an attached sheet. System mode stays user-owned.
            window.tabbingMode = arrangement == .system ? .automatic : .disallowed
            if arrangement == .tabs, let existing = NSApp.orderedWindows.first(where: {
                $0 !== window && $0.tabbingIdentifier == group.identifier && $0.isVisible
                    && $0.isOnActiveSpace && !$0.isMiniaturized && $0.attachedSheet == nil
            }) {
                existing.addTabbedWindow(window, ordered: .above)
            }
            hasPresentedEditor = true
        }
        // Joining a native tab group changes the content geometry before the
        // new window becomes key. Settle that geometry before NSTextView's
        // first-responder caret asks TextKit to lay out the document.
        window.contentView?.layoutSubtreeIfNeeded()
        showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    override func showWindow(_ sender: Any?) {
        openSearchPresented = true
        super.showWindow(sender)
    }
    var canSearchOpenBuffer: Bool {
        openSearchPresented && !closing && window != nil && window?.attachedSheet == nil
            && !surface.textView.hasMarkedText()
    }
    static func openSearchDocuments(preferred: NativeTextEditorWindow) -> [NativeTextEditorWindow] {
        var seen = Set<UUID>()
        return ([preferred] + (NSApp.orderedWindows + NSApp.windows).compactMap {
            $0.windowController as? NativeTextEditorWindow
        }).filter { $0.canSearchOpenBuffer && seen.insert($0.openSearchID).inserted }
    }
    func captureOpenSearchBuffer() -> EditorOpenSearch.Buffer? {
        guard canSearchOpenBuffer else { return nil }
        return .init(id: openSearchID, generation: surface.generation, name: openSearchName,
            context: openSearchContext, text: surface.textView.string)
    }
    func revealOpenSearchMatch(_ range: NSRange, generation: UUID) -> Bool {
        guard canSearchOpenBuffer, surface.generation == generation,
              Range(range, in: surface.textView.string) != nil, let window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface.textView)
        surface.textView.setSelectedRange(range); surface.textView.scrollRangeToVisible(range)
        return true
    }

    /// Owners call once after accepting an actual terminal Save result. Hidden
    /// completions are consumed, never queued for a later focus/tab change.
    func announceSaveResult(_ result: SaveAnnouncement, attempt: UUID) {
        guard consumedSaveAnnouncement != attempt else { return }
        consumedSaveAnnouncement = attempt
        guard !closing, !readOnlyPresentation, NSWorkspace.shared.isVoiceOverEnabled,
              NSApp.isActive, let window, NSApp.keyWindow === window, window.isKeyWindow,
              window.isVisible, window.isOnActiveSpace, !window.isMiniaturized,
              window.occlusionState.contains(.visible), window.attachedSheet == nil,
              window.tabGroup.map({ $0.selectedWindow === window }) ?? true,
              !surface.isHiddenOrHasHiddenAncestor else { return }
        // AppKit requires the application element for announcement requests.
        // No focus, layout or selection notification accompanies the result.
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: result.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func update(displayName: String, dirty: Bool, status message: String,
                documentFormat: TextDocumentFormat, canSave: Bool, working: Bool,
                canReload: Bool, needsRecovery: Bool, explanation: String? = nil,
                canReviewVersions: Bool? = nil,
                canSaveTextCopy: Bool = false, hasTextCopyRecovery: Bool = false, canViewTextCopyResults: Bool = false,
                textCopyResults: [EditorTextCopyResult] = [], location: EditorLocationContext? = nil) {
        window?.title = displayName + " — Traverse"
        openSearchName = displayName; openSearchContext = location?.label ?? ""
        window?.tab.title = displayName
        window?.isDocumentEdited = dirty
        locationRow.isHidden = location == nil
        locationLabel.stringValue = location?.label ?? ""
        locationLabel.toolTip = location?.detail
        locationIcon.image = location.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        status.stringValue = message
        status.toolTip = message
        // An unconfirmed Save needs the same readable contrast as the text;
        // it must not look like routine background status on a glass surface.
        status.textColor = needsRecovery ? .labelColor : .secondaryLabelColor
        banner.textColor = needsRecovery ? .labelColor : .secondaryLabelColor
        format.stringValue = (documentFormat.bom ? "UTF-8 BOM" : "UTF-8")
            + (documentFormat.lineEnding == .crlf ? " · CRLF" : " · LF")
        saveButton.isEnabled = !readOnlyPresentation && canSave
        comparisonBlocked = readOnlyPresentation || working
        saveAsButton.isEnabled = !readOnlyPresentation && !working && !needsRecovery
        reloadButton.isEnabled = !readOnlyPresentation && canReload
        let reviewAvailable = canReviewVersions ?? needsRecovery
        recoveryButton.isHidden = !reviewAvailable; recoveryButton.isEnabled = reviewAvailable && !working
        stopButton.isHidden = !working; stopButton.isEnabled = working
        banner.stringValue = explanation ?? ""; banner.isHidden = explanation == nil
        textCopyButton.isEnabled = canSaveTextCopy
        textCopyButton.isHidden = !hasTextCopyRecovery
        textCopyResultsButton.isEnabled = canViewTextCopyResults
        copyResults = Array(textCopyResults.prefix(9))
        textCopyResultsButton.isHidden = copyResults.isEmpty
        copyActions.isHidden = !hasTextCopyRecovery && copyResults.isEmpty
        recoveryActions.isHidden = copyActions.isHidden && refusedActions.isHidden
        if readOnlyPresentation {
            for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton,
                           textCopyButton, textCopyResultsButton] {
                button.isHidden = true; button.isEnabled = false
            }
            recoveryActions.isHidden = true
        }
        // NSMenu.update validates that menu's own items, not all children.
        // Keep nested File commands current even before the user opens it.
        for root in ownMenu?.items ?? [] { root.submenu?.update() }
        ownMenu?.update()
    }
    /// Defaults update presentation only. Per-window Wrap/Syntax choices remain
    /// session overrides; the controller decides whether a new default applies.
    func applyEditorPreferences(_ value: EditorPreferences, pointSize: CGFloat,
                                applyWrapping: Bool = true) {
        if applyWrapping {
            wrapping.state = value.wrapsLines ? .on : .off
        }
        surface.applyEditorPreferences(value, pointSize: pointSize, applyWrapping: applyWrapping)
    }
    func selectLanguage(_ value: TextSyntaxLanguage) {
        if language.titleOfSelectedItem != value.title { surface.lineCommands.inputDidChange() }
        surface.textView.indentationLanguage = value
        let index = TextSyntaxLanguage.allCases.firstIndex(of: value) ?? 0
        language.selectItem(at: index)
    }
    func finishClose() {
        closing = true
        commandFinderStorage?.dismiss(restoringFocus: false)
        openSearchStorage?.dismiss(restoringFocus: false)
        cancelLineNavigation()
        _ = window?.makeFirstResponder(nil)
        // The document owner has already accepted the close and drained its
        // work. It needs the synchronous native didClose acknowledgement before
        // retiring the visible buffer. A second user-close/fade would defer that
        // acknowledgement and incorrectly trigger failed-close recovery.
        if let tool = window as? ToolMotionWindow {
            tool.closeImmediatelyAfterFeatureAcceptance()
        } else if let window {
            let native = window.animationBehavior
            window.animationBehavior = .none; window.close(); window.animationBehavior = native
        }
        acceptedCloseEditable = nil
    }
    /// Called only after the document owner has accepted Close and drained its
    /// work. The actual native close remains synchronous in finishClose().
    func prepareAcceptedClose() async -> Bool {
        guard !closing, acceptedCloseEditable == nil, let window else { return false }
        acceptedCloseEditable = surface.textView.isEditable
        closing = true; surface.textView.isEditable = false
        let prepared = await ToolWindowCloseMotion.prepareAcceptedClose(window)
        guard prepared, self.window === window else {
            restoreAcceptedClosePresentation(for: window)
            return false
        }
        return true
    }
    func cancelAcceptedClosePreparation() {
        restoreAcceptedClosePresentation(for: window)
    }
    private func restoreAcceptedClosePresentation(for window: NSWindow?) {
        if let window { ToolWindowCloseMotion.cancel(window) }
        if let acceptedCloseEditable { surface.textView.isEditable = acceptedCloseEditable }
        acceptedCloseEditable = nil; closing = false
    }
    /// Document owners join captured-text CPU work before releasing their own
    /// buffers. No file-access lifetime or Save operation belongs to this view.
    func closeComparisonAndDrain() async {
        await openSearchStorage?.closeAndDrain()
        guard let held = comparison else { return }
        await held.closeAndDrain()
        if comparison === held { comparison = nil }
    }
    #if DEBUG
    var comparisonForVerification: EditorComparisonWindow? { comparison }
    #endif
    /// A failed post-close local retirement reopens the same native surface,
    /// including its actual Undo history, in recovery-only mode.
    func reopenAfterFailedClose() {
        cancelAcceptedClosePreparation()
        retainPresentationDuringClose = false
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The accepted visual gate blocks input, but only finishClose may
        // perform the native close after the document owner's final recheck.
        guard acceptedCloseEditable == nil else { return false }
        return closing || shouldClose?() == true
    }
    func windowWillClose(_ notification: Notification) {
        openSearchPresented = false
        commandFinderStorage?.dismiss(restoringFocus: false)
        openSearchStorage?.dismiss(restoringFocus: false)
        cancelLineNavigation()
        if !retainPresentationDuringClose { surface.clearPrivatePresentation() }
        releaseOwnedMenu()
        didClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        synchronizeKeyboardBehavior()
        guard !EditorMenuOwnership.owns(self) else { return }
        ownMenu = EditorMenuOwnership.claim(self) { makeMenu(base: $0) }
    }
    func windowDidResignKey(_ notification: Notification) {
        surface.lineCommands.inputDidChange(); releaseOwnedMenu()
    }
    func windowWillBeginSheet(_ notification: Notification) { surface.lineCommands.inputDidChange() }
    private func releaseOwnedMenu() {
        EditorMenuOwnership.release(self)
        ownMenu = nil
    }
    private func makeMenu(base: NSMenu?) -> NSMenu {
        let menu = NSMenu()
        if let applicationItem = base?.items.first?.copy() as? NSMenuItem { menu.addItem(applicationItem) }
        @discardableResult
        func section(_ title: String, _ entries: [(String, Selector, String, NSEvent.ModifierFlags, AnyObject?)]) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for (label, action, key, modifiers, target) in entries {
                let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers; item.target = target; submenu.addItem(item)
            }
            root.submenu = submenu; menu.addItem(root)
            return submenu
        }
        section("File", [
            ("Save", #selector(saveDocument(_:)), "s", .command, self),
            (saveAsMenuTitle ?? "Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift], self),
            ("Save a Text Copy…", #selector(saveTextCopy(_:)), "", .command, self),
            ("Copy Results…", #selector(showTextCopyResults(_:)), "", .command, self),
            ("Reload from File…", #selector(reloadDocument(_:)), "", .command, self),
            ("Compare Changes…", #selector(compareChanges(_:)), "", .command, self),
            (recoveryMenuTitle ?? "Review Retained Versions…", #selector(reviewVersions(_:)), "", .command, self),
            ("Close", #selector(NSWindow.performClose(_:)), "w", .command, nil)
        ])
        let edit = section("Edit", [
            ("Undo Typing", #selector(NativeTextUndoActions.undo(_:)), "z", .command, nil),
            ("Redo Typing", #selector(NativeTextUndoActions.redo(_:)), "z", [.command, .shift], nil),
            ("Cut", #selector(NSText.cut(_:)), "x", .command, nil),
            ("Copy", #selector(NSText.copy(_:)), "c", .command, nil),
            ("Paste", #selector(NSText.paste(_:)), "v", .command, nil),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command, nil),
            ("Go to Line…", #selector(showGoToLine(_:)), "g", .control, self)
        ])
        let findItems: [(String, NSTextFinder.Action, String, NSEvent.ModifierFlags)] = [
            ("Find…", .showFindInterface, "f", .command),
            ("Find Next", .nextMatch, "g", .command),
            ("Find Previous", .previousMatch, "G", [.command, .shift]),
            ("Replace…", .showReplaceInterface, "f", [.command, .option]),
            ("Use Selection for Find", .setSearchString, "e", .command)
        ]
        for (title, action, key, modifiers) in findItems {
            let item = NSMenuItem(title: title, action: #selector(performFind(_:)), keyEquivalent: key)
            item.tag = action.rawValue; item.keyEquivalentModifierMask = modifiers
            // Target the owning key window, including while a Find field is
            // first responder. Retained items cannot act on a closed editor.
            item.target = self
            edit.insertItem(item, at: edit.numberOfItems - 1)
        }
        let openFind = NSMenuItem(title: "Find in Open Editors…", action: #selector(findInOpenEditors(_:)), keyEquivalent: "f")
        openFind.keyEquivalentModifierMask = [.command, .shift]; openFind.target = self
        edit.insertItem(openFind, at: edit.numberOfItems - 1)
        edit.addItem(.separator())
        for (tag, title, key, modifiers) in [
            (0, "Duplicate Lines", "D", NSEvent.ModifierFlags([.command, .shift])),
            (1, "Move Lines Up", String(UnicodeScalar(NSUpArrowFunctionKey)!), NSEvent.ModifierFlags.option),
            (2, "Move Lines Down", String(UnicodeScalar(NSDownArrowFunctionKey)!), NSEvent.ModifierFlags.option),
            (3, "Toggle Line Comment", "/", NSEvent.ModifierFlags.command),
            (4, "Format JSON", "F", NSEvent.ModifierFlags([.option, .shift])),
            (5, "Compact JSON", "", NSEvent.ModifierFlags([])),
            (6, "Sort Lines Ascending", "", NSEvent.ModifierFlags([])),
            (7, "Sort Lines Descending", "", NSEvent.ModifierFlags([])),
            (8, "Trim Trailing Whitespace", "", NSEvent.ModifierFlags([]))
        ] {
            let item = NSMenuItem(title: title, action: #selector(performLineCommand(_:)), keyEquivalent: key)
            item.tag = tag; item.keyEquivalentModifierMask = modifiers; item.target = self
            edit.addItem(item)
        }
        let surround = NSMenuItem(title: "Surround Selection", action: nil, keyEquivalent: "")
        let surroundMenu = NSMenu(title: surround.title)
        for pair in EditorSurroundingPair.allCases {
            let item = NSMenuItem(title: pair.title, action: #selector(surroundSelection(_:)), keyEquivalent: "")
            item.tag = pair.rawValue; item.target = self
            surroundMenu.addItem(item)
        }
        surround.submenu = surroundMenu; edit.addItem(surround)
        if let window {
            let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            item.submenu = NativeWindowMenu.make(tabbedWindow: window)
            menu.addItem(item)
        }
        if let help = base?.items.last, help.title == "Help", let copy = help.copy() as? NSMenuItem {
            // Help must discover the key editor's own commands rather than
            // forwarding into the browser beneath it.
            for item in copy.submenu?.items ?? [] where item.action == #selector(BrowserViewController.findCommand(_:)) {
                item.action = #selector(findEditorCommand(_:)); item.target = self
            }
            menu.addItem(copy)
        }
        if usesControlAliases {
            let basic: Set<String> = ["Save", saveAsMenuTitle ?? "Save As…", "Close", "Undo Typing", "Redo Typing", "Cut", "Copy", "Paste", "Select All", "Find…", "Find in Open Editors…", "Toggle Line Comment"]
            for parent in menu.items where ["File", "Edit"].contains(parent.title) {
                guard let submenu = parent.submenu else { continue }
                for item in submenu.items where basic.contains(item.title) && item.keyEquivalentModifierMask.contains(.command) {
                    guard let alias = item.copy() as? NSMenuItem else { continue }
                    alias.keyEquivalentModifierMask.remove(.command); alias.keyEquivalentModifierMask.insert(.control)
                    alias.isHidden = true; alias.allowsKeyEquivalentWhenHidden = true
                    submenu.addItem(alias)
                    if item.title == "Redo Typing", let redo = alias.copy() as? NSMenuItem {
                        redo.keyEquivalent = "y"; redo.keyEquivalentModifierMask = .control; submenu.addItem(redo)
                    }
                }
                if parent.title == "Edit" {
                    let replace = NSMenuItem(title: "Replace…", action: #selector(performFind(_:)), keyEquivalent: "h")
                    replace.keyEquivalentModifierMask = .control; replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
                    replace.target = self; replace.isHidden = true; replace.allowsKeyEquivalentWhenHidden = true
                    submenu.addItem(replace)
                }
            }
        }
        return menu
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !closing, window?.isKeyWindow == true else { return false }
        switch item.action {
        case #selector(saveDocument(_:)): return saveButton.isEnabled
        case #selector(saveDocumentAs(_:)): return saveAsButton.isEnabled
        case #selector(saveTextCopy(_:)): return !textCopyButton.isHidden && textCopyButton.isEnabled
        case #selector(showTextCopyResults(_:)): return !textCopyResultsButton.isHidden && textCopyResultsButton.isEnabled
        case #selector(reloadDocument(_:)): return reloadButton.isEnabled
        case #selector(reviewVersions(_:)): return !recoveryButton.isHidden && recoveryButton.isEnabled
        case #selector(compareChanges(_:)): return canCompare
        case #selector(stopDocumentWork(_:)): return !stopButton.isHidden && stopButton.isEnabled
        case #selector(findEditorCommand(_:)): return canDiscoverCommands
        case #selector(findInOpenEditors(_:)): return canDiscoverCommands && canSearchOpenBuffer
        case #selector(showGoToLine(_:)): return surface.canGoToLine && window?.attachedSheet == nil
        case #selector(performFind(_:)): return !closing && window?.isVisible == true && window?.attachedSheet == nil
        case #selector(performLineCommand(_:)):
            return !closing && surface.lineCommands.canPerform && (item.tag != 3 || lineCommentStyle != nil)
                && (![4, 5].contains(item.tag) || supportsJSONFormatting)
        case #selector(surroundSelection(_:)):
            return !closing && surface.lineCommands.canPerform && surface.textView.selectedRange().length > 0
                && EditorSurroundingPair(rawValue: item.tag) != nil
        default: return true
        }
    }
    var canDiscoverCommands: Bool {
        !closing && window?.isVisible == true && window?.attachedSheet == nil
    }
    private var canCompare: Bool {
        !closing && !comparisonBlocked && captureComparison != nil && window?.isVisible == true
            && window?.attachedSheet == nil && !surface.textView.hasMarkedText()
    }
    @objc func compareChanges(_ sender: Any?) {
        guard window?.isKeyWindow == true, canCompare, let parent = window,
              let captureComparison, let settings = commandDiscoverySettings else { return }
        if let comparison, !comparison.closed { comparison.present(); return }
        let held = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: surface.textView.font?.pointSize ?? 13, capture: captureComparison)
        comparison = held
        held.didClose = { [weak self, weak held] in
            if self?.comparison === held { self?.comparison = nil }
        }
        held.present()
    }
    var commandDiscoverySettings: BrowserSettings? { keyboardSettings ?? InterfacePresentation.shared.settings }
    func discoverableCommands() -> [(NSMenuItem, String)] {
        guard let ownMenu else { return [] }
        func commands(in menu: NSMenu, category: String, depth: Int) -> [(NSMenuItem, String)] {
            guard depth < 4 else { return [] }
            return menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.flatMap { item in
                if let submenu = item.submenu {
                    return commands(in: submenu, category: category + " › " + item.title, depth: depth + 1)
                }
                return item.action == nil ? [] : [(item, category)]
            }
        }
        return ownMenu.items.filter { ["File", "Edit", "Window"].contains($0.title) }.flatMap { section in
            section.submenu.map { commands(in: $0, category: section.title, depth: 0) } ?? []
        }
    }
    @objc func findEditorCommand(_ sender: Any?) { if !closing { commandFinder.present() } }
    @objc func findInOpenEditors(_ sender: Any?) { if !closing { openSearch.present() } }
    @objc private func surroundSelection(_ sender: NSMenuItem) {
        guard !closing, surface.lineCommands.canPerform, surface.textView.selectedRange().length > 0,
              let pair = EditorSurroundingPair(rawValue: sender.tag) else { return }
        surface.lineCommands.perform(.surroundSelection(pair))
    }
    @objc private func performLineCommand(_ sender: NSMenuItem) {
        guard !closing, surface.lineCommands.canPerform else { return }
        let command: EditorLineCommand
        switch sender.tag {
        case 0: command = .duplicateSelectedLines
        case 1: command = .moveLinesUp
        case 2: command = .moveLinesDown
        case 3:
            guard let style = lineCommentStyle else { return }
            command = .toggleLineComment(style)
        case 4, 5:
            guard supportsJSONFormatting else { return }
            command = .formatJSON(sender.tag == 5 ? .compact : .indented(surface.indentationPreferences),
                                  allowsComments: selectedSyntaxLanguage == .jsonc)
        case 6, 7: command = .sortSelectedLines(descending: sender.tag == 7)
        case 8: command = .trimTrailingWhitespace
        default: return
        }
        surface.lineCommands.perform(command)
    }
    private var selectedSyntaxLanguage: TextSyntaxLanguage? {
        let languages = TextSyntaxLanguage.allCases
        guard languages.indices.contains(language.indexOfSelectedItem) else { return nil }
        return languages[language.indexOfSelectedItem]
    }
    private var lineCommentStyle: EditorLineCommentStyle? { selectedSyntaxLanguage?.lineCommentStyle }
    private var supportsJSONFormatting: Bool {
        selectedSyntaxLanguage == .json || selectedSyntaxLanguage == .jsonc
    }
    @objc private func performFind(_ sender: NSMenuItem) {
        guard window?.isKeyWindow == true, window?.isVisible == true, !closing, window?.attachedSheet == nil,
              let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        surface.find.perform(action)
    }
    @objc private func saveDocument(_ sender: Any?) { if !closing && window?.isKeyWindow == true && saveButton.isEnabled { onSave?() } }
    @objc private func saveDocumentAs(_ sender: Any?) { if !closing && window?.isKeyWindow == true && saveAsButton.isEnabled { onSaveAs?() } }
    @objc private func saveTextCopy(_ sender: Any?) { if !closing && window?.isKeyWindow == true && !textCopyButton.isHidden && textCopyButton.isEnabled { onTextCopy?() } }
    @objc private func showTextCopyResults(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true, !textCopyResultsButton.isHidden, textCopyResultsButton.isEnabled else { return }
        guard copyResults.count > 1 else { onTextCopyResults?(copyResults.first?.id); return }
        let menu = NSMenu()
        for result in copyResults {
            let item = NSMenuItem(title: result.title, action: #selector(showExactTextCopyResult(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = result.id.uuidString; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .init(x: 0, y: textCopyResultsButton.bounds.height), in: textCopyResultsButton)
    }
    @objc private func showExactTextCopyResult(_ sender: NSMenuItem) {
        guard !closing, window?.isKeyWindow == true, textCopyResultsButton.isEnabled,
              let raw = sender.representedObject as? String, let record = UUID(uuidString: raw),
              copyResults.contains(where: { $0.id == record }) else { return }
        onTextCopyResults?(record)
    }
    @objc private func reloadDocument(_ sender: Any?) { if !closing && window?.isKeyWindow == true && reloadButton.isEnabled { onReload?() } }
    @objc private func reviewBeforeSave(_ sender: Any?) {
        if !closing && window?.isKeyWindow == true && beforeSaveButton.isEnabled { onRefusedVersion?(.before) }
    }
    @objc private func reviewEditedSave(_ sender: Any?) {
        if !closing && window?.isKeyWindow == true && editedSaveButton.isEnabled { onRefusedVersion?(.edited) }
    }
    @objc private func reviewVersions(_ sender: Any?) { if !closing && window?.isKeyWindow == true && recoveryButton.isEnabled { onRecovery?() } }
    @objc private func stopDocumentWork(_ sender: Any?) { if !closing && window?.isKeyWindow == true && stopButton.isEnabled { onStop?() } }
    @objc private func showGoToLine(_ sender: Any?) {
        guard !closing, let window, window.isKeyWindow, window.attachedSheet == nil,
              lineNavigation == nil, surface.canGoToLine, let index = surface.lineIndex else { return }
        let generation = surface.generation
        let current = index.location(at: surface.textView.selectedRange().location)?.line ?? 1
        let dialog = EditorLineNavigationDialog(current: current, maximum: index.starts.count)
        lineNavigation = dialog
        dialog.alert.beginSheetModal(for: window) { [weak self, weak dialog] response in
            guard let self, let dialog, self.lineNavigation === dialog else { return }
            self.lineNavigation = nil
            guard response == .alertFirstButtonReturn, self.window?.isVisible == true, !self.closing,
                  let line = dialog.line else { return }
            if !self.surface.goToLine(line, generation: generation) {
                self.status.stringValue = "The text changed. Open Go to Line again."
            }
        }
    }
    private func cancelLineNavigation() {
        guard let dialog = lineNavigation else { return }
        lineNavigation = nil
        if window?.attachedSheet === dialog.alert.window {
            window?.endSheet(dialog.alert.window, returnCode: .alertSecondButtonReturn)
        }
    }
    @objc private func toggleWrap(_ sender: Any?) { surface.setWrapping(wrapping.state == .on); onWrapping?() }
    @objc private func changeLanguage(_ sender: Any?) {
        let values = TextSyntaxLanguage.allCases
        guard values.indices.contains(language.indexOfSelectedItem) else { return }
        surface.lineCommands.inputDidChange()
        surface.textView.indentationLanguage = values[language.indexOfSelectedItem]
        onLanguage?(values[language.indexOfSelectedItem])
    }
}

@MainActor
private final class EditorLineNavigationDialog: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    private let field: NSTextField
    private let maximum: Int
    var line: Int? { EditorLineNumber.parse(field.stringValue, maximum: maximum) }
    init(current: Int, maximum: Int) {
        self.maximum = maximum
        field = NSTextField(string: String(current))
        super.init()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number from 1 to \(maximum.formatted())."
        alert.addButton(withTitle: "Go"); alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        field.frame = .init(x: 0, y: 0, width: 260, height: 24)
        field.drawsBackground = false
        field.setAccessibilityLabel("Line number")
        field.delegate = self
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        validate()
    }
    func controlTextDidChange(_ notification: Notification) { validate() }
    private func validate() { alert.buttons[0].isEnabled = line != nil }
}
