import AppKit
import ExplorerCore

/// Ephemeral naming UI only. The proposal is never a file row, location,
/// operation plan, access grant or saved workspace value.
@MainActor
final class BrowserSelectionGroupDraftController: NSObject, NSTextFieldDelegate {
    struct Context: Equatable {
        let tab: UUID
        let visit: UUID
        let presentation: UUID
        let parent: URL
        let orderedSelection: [URL]
    }

    private struct Request {
        let id: UUID
        let context: Context
        var awaitingValidation = false
        var validationMessage: String?
    }
    private struct Session {
        let id: UUID
        let continuation: CheckedContinuation<String?, Never>
    }

    weak var browser: BrowserViewController?
    private var request: Request?
    private var session: Session?
    private var observations = [BrowserNotificationObservation]()
    private var keyMonitor: Any?
    private weak var scroll: NSScrollView?
    private weak var accessoryBody: NSStackView?
    private var accessorySurface: NavigationGlassSurface?
    private var accessoryContext: Context?
    private var accessoryWidth: NSLayoutConstraint?
    private var accessory: SelectionGroupDraftAccessory?
    private var changingFocus = false
    var isEditing: Bool { session != nil }
    var isPresenting: Bool { request != nil }
    var field: NSTextField? { accessory?.nameField }

    init(browser: BrowserViewController) { self.browser = browser }

    /// Reserve before any asynchronous observation/access work. Callers retain
    /// their own opaque observations; this controller retains only UI context.
    @discardableResult
    func reserve(context: Context) -> UUID {
        cancel()
        let id = UUID()
        guard admissible(context), current(context), let window = browser?.view.window else { return id }
        request = Request(id: id, context: context)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
            observe(name, object: window, requestID: id)
        }
        observe(NSApplication.didResignActiveNotification, object: NSApplication.shared, requestID: id)
        observe(InterfacePresentation.didChange, object: InterfacePresentation.shared, requestID: id)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window, self.request?.id == id, event.window === window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                self.cancelDraft(nil)
                return true
            }
            return consumed ? nil : event
        }
        return id
    }

    /// Each Enter returns one literal answer. Keep the accessory while the
    /// caller checks it; showValidationFailure + begin reuses this same field.
    /// Successful caller preparation must still consume the exact request.
    func begin(requestID: UUID, initialName: String = "New Folder with Items") async -> String? {
        guard let request, request.id == requestID, session == nil else { return nil }
        guard current(request.context) else { cancel(requestID: requestID); return nil }
        guard !request.awaitingValidation || request.validationMessage != nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, self.request?.id == requestID,
                      self.request.map({ current($0.context) }) == true,
                      let window = browser?.view.window else { continuation.resume(returning: nil); return }
                if accessory == nil, !install(initialName: initialName) {
                    cancel(requestID: requestID); continuation.resume(returning: nil); return
                }
                guard let accessory else { cancel(requestID: requestID); continuation.resume(returning: nil); return }
                self.request?.awaitingValidation = false
                session = Session(id: requestID, continuation: continuation)
                accessory.nameField.isEditable = true
                accessory.nameField.isEnabled = true
                accessory.show(message: self.request?.validationMessage, checking: false)
                changingFocus = true
                let focused = window.makeFirstResponder(accessory.nameField)
                if focused { accessory.nameField.selectText(nil) }
                changingFocus = false
                if !focused { cancel(requestID: requestID) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: requestID) }
        }
    }

    /// Present an engine/name validation explanation without changing the
    /// literal input, selection, request identity or opening another prompt.
    /// Then call begin(requestID:) again to await the corrected answer.
    func showValidationFailure(_ message: String, requestID: UUID) {
        guard var request, request.id == requestID else { return }
        guard current(request.context) else { cancel(requestID: requestID); return }
        guard request.awaitingValidation else { return }
        request.validationMessage = String(message.prefix(300))
        self.request = request
        accessory?.show(message: request.validationMessage, checking: false)
    }

    /// One-shot fence immediately before operation admission. Accepted Enter
    /// alone does not survive navigation, cancellation or a replaced context.
    func consume(requestID: UUID, context: Context) -> Bool {
        guard let request, request.id == requestID else { return false }
        let accepted = !Task.isCancelled && request.awaitingValidation && request.validationMessage == nil
            && request.context == context && current(context)
        cancel(requestID: requestID)
        return accepted
    }

    /// Navigation, tab/pane, view/filter and source-presentation hooks call
    /// this even for away-and-back transitions that later compare equal.
    func contextChanged() { cancel() }

    func selectionDidChange() {
        guard let request else { return }
        if !current(request.context) { cancel() }
    }

    func cancel(requestID: UUID) {
        guard request?.id == requestID else { return }
        cancel()
    }

    func cancel() {
        let continuation = session?.continuation
        // Revoke before ending native editing; its notifications can reenter.
        request = nil; session = nil; observations = []
        removeKeyMonitor()
        removeAccessory(restoreFocus: false)
        continuation?.resume(returning: nil)
    }

    private func observe(_ name: Notification.Name, object: Any, requestID: UUID) {
        observations.append(BrowserNotificationObservation(name: name, object: object) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(requestID: requestID) }
        })
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func admissible(_ context: Context) -> Bool {
        guard context.parent.isFileURL, context.parent.path.hasPrefix("/"), (1...512).contains(context.orderedSelection.count),
              Set(context.orderedSelection).count == context.orderedSelection.count else { return false }
        return context.orderedSelection.allSatisfy {
            $0.isFileURL && $0.deletingLastPathComponent().standardizedFileURL == context.parent.standardizedFileURL
        }
    }

    private func current(_ context: Context) -> Bool {
        guard let browser, let parent = browser.location.directoryURL else { return false }
        return !browser.isBrowserSuspended && browser.isActiveCommandPane && !browser.isReadOnlyFileSession
            && !browser.isLoading && !browser.metadataSearch.isShowingResults && browser.view.window?.attachedSheet == nil
            && browser.activeID == context.tab && browser.sessionID == context.visit
            && browser.filePresentationID == context.presentation
            && parent.standardizedFileURL == context.parent.standardizedFileURL
            && browser.orderedSelectedURLs == context.orderedSelection
    }

    private func install(initialName: String) -> Bool {
        guard let browser, let request, current(request.context), let body = browser.paneBody,
              let position = body.arrangedSubviews.firstIndex(where: { $0 === browser.splitController.view }) else { return false }
        let scroll = browser.activeFileScrollView
        guard scroll.window === browser.view.window else { return false }
        let offset = browser.currentScrollOffset
        let accessory = SelectionGroupDraftAccessory(name: initialName, count: request.context.orderedSelection.count)
        accessory.nameField.delegate = self
        accessory.cancelButton.target = self; accessory.cancelButton.action = #selector(cancelDraft(_:))
        let surface = NavigationGlassSurface(contentView: accessory,
            isGlassEnabled: browser.settings.navigationStyle == .glass && browser.settings.glassNavigation)
        self.scroll = scroll; accessoryBody = body; accessorySurface = surface
        accessoryContext = request.context; self.accessory = accessory
        body.insertArrangedSubview(surface, at: position)
        let width = surface.widthAnchor.constraint(equalTo: body.widthAnchor)
        width.isActive = true; accessoryWidth = width
        accessory.heightAnchor.constraint(equalToConstant: 76).interfaceScaled.isActive = true
        browser.view.layoutSubtreeIfNeeded()
        browser.restoreFileScrollOffset(offset)
        InterfacePresentation.shared.register(accessory)
        if browser.settings.motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.alphaValue = browser.settings.motion.mode.initialOpacity(0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14 * browser.settings.motion.mode.durationScale
                surface.animator().alphaValue = 1
            }
        }
        return true
    }

    private func removeAccessory(restoreFocus: Bool) {
        guard let accessory else { return }
        self.accessory = nil
        let preserveScroll = browser.flatMap { browser -> Double? in
            guard let context = accessoryContext, browser.activeID == context.tab,
                  browser.sessionID == context.visit, browser.filePresentationID == context.presentation,
                  browser.activeFileScrollView === scroll else { return nil }
            return browser.currentScrollOffset
        }
        accessory.nameField.delegate = nil
        if let editor = accessory.nameField.currentEditor(), accessory.window?.firstResponder === editor {
            changingFocus = true
            accessory.window?.makeFirstResponder(restoreFocus ? browser?.activeFileView : nil)
            changingFocus = false
        }
        accessoryWidth?.isActive = false
        if let surface = accessorySurface {
            accessoryBody?.removeArrangedSubview(surface); surface.removeFromSuperview()
        }
        accessorySurface = nil; accessoryBody = nil; accessoryContext = nil; accessoryWidth = nil; scroll = nil
        browser?.view.layoutSubtreeIfNeeded()
        if let preserveScroll { browser?.restoreFileScrollOffset(preserveScroll) }
    }

    private static func literalNameProblem(_ value: String) -> String? {
        if value.isEmpty { return "Enter a folder name." }
        if value == "." || value == ".." { return "Choose a different folder name." }
        if value.utf8.count > 255 { return "This folder name is too long. Use at most 255 UTF-8 bytes." }
        if value.contains("/") || value.contains("\\") || value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || [0x061c, 0x200e, 0x200f].contains($0.value)
                || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }) { return "Use a name without path separators or control characters." }
        return nil
    }

    private func accept(_ value: String) {
        guard let session, var request, session.id == request.id, current(request.context), let accessory else { cancel(); return }
        if let problem = Self.literalNameProblem(value) {
            request.validationMessage = problem; self.request = request
            accessory.show(message: problem, checking: false); return
        }
        self.session = nil
        request.awaitingValidation = true; request.validationMessage = nil; self.request = request
        accessory.nameField.stringValue = value
        changingFocus = true
        accessory.window?.makeFirstResponder(browser?.activeFileView)
        changingFocus = false
        accessory.nameField.isEditable = false
        accessory.show(message: nil, checking: true)
        session.continuation.resume(returning: value)
    }

    @objc private func cancelDraft(_ sender: Any?) {
        let continuation = session?.continuation
        request = nil; session = nil; observations = []
        removeKeyMonitor()
        removeAccessory(restoreFocus: true)
        continuation?.resume(returning: nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === field else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:": accept(textView.string); return true
        case "cancelOperation:": cancelDraft(nil); return true
        default: return false // Native text selection, Copy/Paste and Undo remain native.
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field, notification.object as? NSTextField === field, let request, session?.id == request.id else { return }
        self.request?.validationMessage = nil
        accessory?.show(message: nil, checking: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !changingFocus else { return }
        cancel()
    }
}

/// A temporary native accessory band, never a document/data-source member.
/// A pane-local stack strip reserves space without manufacturing a file row,
/// replacing the scroll document or changing its native content insets.
@MainActor
private final class SelectionGroupDraftAccessory: NSView {
    let nameField: NSTextField
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let help = NSTextField(wrappingLabelWithString: "")
    private let count: Int

    init(name: String, count: Int) {
        self.count = count; nameField = NSTextField(string: name)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Proposed folder, not created") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameField.cell?.isScrollable = true
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.focusRingType = .exterior
        nameField.setAccessibilityLabel("Proposed folder name")
        nameField.setAccessibilityHelp("Not created yet. Press Return to submit the name, or Escape to cancel. The original selected items stay in place until the grouping job starts.")
        InterfaceMetrics.setFont(nameField, base: .systemFont(ofSize: 13))
        InterfaceMetrics.setFont(cancelButton, base: .systemFont(ofSize: 12))
        let countLabel = NSTextField(labelWithString: "Not created yet · \(count) item\(count == 1 ? "" : "s")")
        countLabel.textColor = .secondaryLabelColor; countLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        InterfaceMetrics.setFont(countLabel, base: .systemFont(ofSize: 11))
        help.maximumNumberOfLines = 2
        InterfaceMetrics.setFont(help, base: .systemFont(ofSize: 11))
        let minimumName = nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).interfaceScaled
        minimumName.priority = .defaultHigh; minimumName.isActive = true
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).interfaceScaled.isActive = true
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, nameField, countLabel, cancelButton])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = InterfaceMetrics.points(8)
        let stack = NSStackView(views: [row, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = InterfaceMetrics.points(4)
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).interfaceScaled,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).interfaceScaled,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22).interfaceScaled,
            icon.heightAnchor.constraint(equalToConstant: 22).interfaceScaled,
        ])
        show(message: nil, checking: false)
    }

    required init?(coder: NSCoder) { nil }

    func show(message: String?, checking: Bool) {
        help.stringValue = message ?? (checking ? "Checking the proposed name… No folder has been created." : "Return submits the proposed name for \(count) selected item\(count == 1 ? "" : "s"). Escape cancels.")
        help.textColor = message == nil ? .secondaryLabelColor : .systemRed
        help.toolTip = help.stringValue
        nameField.toolTip = help.stringValue
    }

    override func draw(_ dirtyRect: NSRect) {
        // The shared NavigationGlassSurface owns Glass/Solid and accessibility.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
