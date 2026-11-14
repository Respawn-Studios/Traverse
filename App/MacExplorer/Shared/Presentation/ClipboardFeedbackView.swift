import AppKit

/// One finite attention cue per clipboard generation, shared when a pane footer moves.
@MainActor
final class ClipboardAttention {
    private(set) var presented = false
    func consume() -> Bool {
        guard !presented else { return false }
        presented = true
        return true
    }
}

/// A compact, keyboard-accessible status label. Details contain only the exact
/// file references captured for the live clipboard generation, never file bodies.
@MainActor
final class ClipboardFeedbackView: NSView, NSPopoverDelegate {
    var liveFeedback: (() -> TransferClipboardFeedback?)?
    var onDismiss: ((UUID) -> Bool)?
    private let statusLabel = label("", size: 12, color: .secondaryLabelColor)
    private let dismissButton = ClipboardDismissButton()
    private var hovered = false
    var stringValue: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    var lineBreakMode: NSLineBreakMode {
        get { statusLabel.lineBreakMode }
        set { statusLabel.lineBreakMode = newValue }
    }
    private var feedback: TransferClipboardFeedback?
    private var tracking: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var detailsPopover: NSPopover?
    private var detailsClickMonitor: Any?
    private var detailsPinned = false
    private(set) var attentionCount = 0
    private(set) var detailLines: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.image = symbol("xmark", "Dismiss Clipboard Feedback")
        dismissButton.imagePosition = .imageOnly
        dismissButton.bezelStyle = .recessed
        dismissButton.isBordered = false
        dismissButton.controlSize = .small
        // F6 focuses the whole inspector. Its accessible popover action supplies
        // keyboard dismissal without introducing another footer focus stop.
        dismissButton.refusesFirstResponder = true
        dismissButton.target = self
        dismissButton.action = #selector(dismissCurrentFeedback(_:))
        dismissButton.toolTip = "Dismiss app feedback and Cut intent. Keep the system clipboard."
        dismissButton.setAccessibilityLabel("Dismiss Clipboard Feedback")
        dismissButton.setAccessibilityHelp("Remove this app's feedback and Cut marking without changing the system clipboard.")
        dismissButton.isHidden = true
        addSubview(statusLabel); addSubview(dismissButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 22),
            dismissButton.heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        focusRingType = .exterior
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityHelp("Inspect clipboard items and their source locations. Press Space or Return for details. Press Delete to dismiss app feedback without changing the system clipboard.")
        NotificationCenter.default.addObserver(self, selector: #selector(applicationPresentationChanged(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let detailsClickMonitor { NSEvent.removeMonitor(detailsClickMonitor) }
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: statusLabel.intrinsicContentSize.width + 26, height: 22)
    }
    override var acceptsFirstResponder: Bool { !isHidden && feedback != nil }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateDismissVisibility(focused: accepted)
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        Task { @MainActor [weak self] in self?.updateDismissVisibility() }
        return accepted
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === statusLabel ? self : target
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }

    func update(_ value: TransferClipboardFeedback?) {
        let previousLines = detailLines
        if feedback?.id != value?.id {
            closeDetails()
            layer?.removeAnimation(forKey: "clipboardAttention")
        }
        feedback = value
        stringValue = value?.message ?? ""
        statusLabel.textColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .labelColor : .secondaryLabelColor
        isHidden = value == nil
        detailLines = value?.detailLines ?? []
        toolTip = value.map { $0.message + "\nHover or click to inspect items and source locations." }
        setAccessibilityLabel(stringValue)
        if value == nil { closeDetails() }
        else if detailsPopover?.isShown == true && detailLines != previousLines { rebuildDetails() }
        updateDismissVisibility()
        presentAttentionIfVisible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeDetails() }
        else { presentAttentionIfVisible() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            if let window { NotificationCenter.default.removeObserver(self, name: name, object: window) }
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowPresentationChanged(_:)),
                                                       name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        presentAttentionIfVisible()
    }

    @objc private func windowPresentationChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        presentAttentionIfVisible()
    }

    @objc private func applicationPresentationChanged(_ notification: Notification) {
        presentAttentionIfVisible()
    }

    private func presentAttentionIfVisible() {
        guard NSApplication.shared.isActive, let window, window.isKeyWindow,
              window.isVisible, window.occlusionState.contains(.visible), !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, let feedback, feedback.attention.consume() else { return }
        attentionCount += 1
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: feedback.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, 0.45, 1]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.7
        pulse.repeatCount = 2
        layer?.add(pulse, forKey: "clipboardAttention")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateDismissVisibility()
        closeTask?.cancel()
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.showDetails(pinned: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateDismissVisibility()
        hoverTask?.cancel()
        scheduleClose()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTask?.cancel(); closeTask?.cancel()
        if detailsPopover?.isShown == true && detailsPinned { closeDetails() }
        else { showDetails(pinned: true) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeDetails(); return }
        if [51, 117].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            dismissCurrentFeedback(nil)
            return
        }
        if event.keyCode == 36 || event.keyCode == 49 { showDetails(pinned: true); return }
        super.keyDown(with: event)
    }

    var ownsDetailsFocus: Bool {
        guard let content = detailsPopover?.contentViewController?.view,
              let responder = content.window?.firstResponder as? NSView else { return false }
        return responder === content || responder.isDescendant(of: content)
    }

    override func accessibilityPerformPress() -> Bool { showDetails(pinned: true); return feedback != nil }

    private func updateDismissVisibility(focused: Bool = false) {
        let responder = window?.firstResponder as? NSView
        dismissButton.isHidden = feedback == nil || !(hovered || focused || detailsPopover?.isShown == true || responder === self
            || responder?.isDescendant(of: self) == true)
    }

    @objc private func dismissCurrentFeedback(_ sender: Any?) {
        guard let id = feedback?.id else { return }
        dismissFeedback(id: id)
    }

    private func dismissFeedback(id: UUID) {
        let current = liveFeedback?()
        guard current?.id == id else { update(current); return }
        guard onDismiss?(id) == true else { update(liveFeedback?()); return }
        closeDetails()
        update(liveFeedback?())
    }

    /// Revalidate at inspection time, so an overwritten clipboard cannot expose stale details.
    @discardableResult
    func refreshDetails() -> Bool {
        guard let current = liveFeedback?(), current.id == feedback?.id else {
            update(nil)
            return false
        }
        update(current)
        return true
    }

    func showDetails(pinned: Bool = false) {
        guard refreshDetails(), window != nil, !isHiddenOrHasHiddenAncestor else { return }
        closeTask?.cancel()
        detailsPinned = pinned || detailsPinned
        if detailsPopover?.isShown == true { return }
        let popover = NSPopover()
        popover.delegate = self
        // A transient popover can consume the first outside click to close itself.
        // Let the owning window's native control receive that same click, so ×
        // dismisses intent immediately rather than requiring a second click.
        popover.behavior = .semitransient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = makeDetailsController()
        detailsPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        guard popover.isShown else { return }
        // Semi-transient closing conditions are platform-defined. Explicitly
        // close on click-away, returning the original event to its own target.
        // The anchor handles its own toggle/×; card controls keep native focus.
        detailsClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let popover = self.detailsPopover, popover.isShown else { return event }
            if event.window === popover.contentViewController?.view.window { return event }
            if event.window === self.window,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { return event }
            self.closeDetails()
            return event
        }
        updateDismissVisibility()
    }

    func closeDetails() {
        hoverTask?.cancel(); hoverTask = nil
        closeTask?.cancel(); closeTask = nil
        removeDetailsClickMonitor()
        detailsPopover?.close(); detailsPopover = nil
        detailsPinned = false
        updateDismissVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === detailsPopover else { return }
        removeDetailsClickMonitor()
        detailsPopover = nil
        detailsPinned = false
        updateDismissVisibility()
    }

    private func removeDetailsClickMonitor() {
        if let detailsClickMonitor { NSEvent.removeMonitor(detailsClickMonitor) }
        detailsClickMonitor = nil
    }

    private func scheduleClose() {
        guard !detailsPinned else { return }
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            self?.closeDetails()
        }
    }

    private func rebuildDetails() { detailsPopover?.contentViewController = makeDetailsController() }

    #if DEBUG
    var detailsAreShownForVerification: Bool { detailsPopover?.isShown == true }
    func detailsControllerForVerification() -> NSViewController? {
        guard refreshDetails() else { return nil }
        return makeDetailsController()
    }
    #endif

    private func makeDetailsController() -> NSViewController {
        let controller = NSViewController()
        let body = ClipboardDetailsBody()
        body.onEntered = { [weak self] in self?.closeTask?.cancel() }
        body.onExited = { [weak self] in self?.scheduleClose() }
        let title = label(feedback?.message ?? "Clipboard", size: 13, weight: .semibold)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 352, height: 100))
        text.string = detailLines.joined(separator: "\n\n")
        text.font = .systemFont(ofSize: 11)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 352, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(detailLines.joined(separator: "\n"))
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let detailHeight = CGFloat(min(270, max(64, detailLines.count * 47)))
        scroll.widthAnchor.constraint(equalToConstant: 352).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: detailHeight).isActive = true
        title.widthAnchor.constraint(equalToConstant: 352).isActive = true
        title.lineBreakMode = .byTruncatingTail
        let row = stack([title, scroll], orientation: .vertical, spacing: 10)
        if let id = feedback?.id {
            let dismiss = ActionButton(title: "Dismiss Clipboard Feedback", action: { [weak self] in self?.dismissFeedback(id: id) })
            dismiss.setAccessibilityHelp("Remove app feedback and Cut marking. The system clipboard remains unchanged.")
            row.addArrangedSubview(dismiss)
        }
        row.alignment = .leading
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        pin(row, inside: body)
        controller.view = body
        controller.preferredContentSize = NSSize(width: 380, height: 88 + detailHeight)
        return controller
    }
}

/// This borderless image has no bezel extending beyond its hit target. AppKit's
/// standard small-button alignment insets otherwise turn a 22 pt alignment rect
/// into a 25 pt frame, clipping the compact footer's native hit area.
@MainActor
private final class ClipboardDismissButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
}

@MainActor
private final class ClipboardDetailsBody: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
}
