import AppKit

/// Transient presentation only. The operation engine owns work, cancellation and recovery.
struct OperationProgressPresentation {
    var phaseTitle: String
    var percentage: Double?
    var summary: String
    var sourcePath: String?
    var destinationPath: String?
    var currentItem: String?
    var completedText: String?
    var remainingText: String?
    var speedText: String?
    var samples: [Double]
    var stopping: Bool
    var terminal: Bool
    var queueSummary: String?

    init(phaseTitle: String, percentage: Double? = nil, summary: String,
         sourcePath: String? = nil, destinationPath: String? = nil, currentItem: String? = nil,
         completedText: String? = nil, remainingText: String? = nil, speedText: String? = nil,
         samples: [Double] = [], stopping: Bool = false, terminal: Bool = false, queueSummary: String? = nil) {
        self.phaseTitle = phaseTitle
        self.percentage = percentage
        self.summary = summary
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.currentItem = currentItem
        self.completedText = completedText
        self.remainingText = remainingText
        self.speedText = speedText
        self.samples = samples
        self.stopping = stopping
        self.terminal = terminal
        self.queueSummary = queueSummary
    }

    var boundedPercentage: Double? {
        guard let percentage, percentage.isFinite else { return nil }
        return min(1, max(0, percentage))
    }

    var percentageText: String {
        boundedPercentage.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "—"
    }
}

/// The same compact control can live in navigation or the footer.
@MainActor
final class OperationProgressButton: NSButton {
    var motion = BrowserMotionPreferences()
    var presentation: OperationProgressPresentation? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
            isEnabled = presentation != nil
            setAccessibilityLabel(presentation.map { "File operation: \($0.phaseTitle)" } ?? "File operations")
            setAccessibilityValue(presentation.map { "\($0.percentageText). \($0.summary)" })
            if let presentation {
                hoverDetails?.presentation = presentation
            } else {
                dismissHoverInspection()
            }
        }
    }
    var onInspect: (() -> Void)?
    var onQueue: (() -> Void)? { didSet { hoverDetails?.onQueue = onQueue } }
    var inspectionIsPinned = false { didSet { if inspectionIsPinned { dismissHoverInspection() } } }
    weak var hoverHost: NSView?
    weak var hoverBottomAnchor: NSView?
    var hoverBottomInset: CGFloat = 0 {
        didSet { if oldValue != hoverBottomInset { dismissHoverInspection() } }
    }

    private var hoverTracking: NSTrackingArea?
    private var hoverCard: OperationProgressCardSurface?
    private var hoverDetails: OperationProgressDetailsView?
    private var hoverTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    #if DEBUG
    var isHoverInspectionVisible: Bool { hoverCard?.superview != nil }
    var hoverInspectionSize: NSSize? { hoverCard?.frame.size }
    var hoverInspectionWindow: NSWindow? { hoverDetails?.window }
    var hoverInspectionView: NSView? { hoverDetails }
    var hoverInspectionFrameInHost: NSRect? { hoverCard?.frame }
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(inspect(_:))
        isEnabled = false
        setAccessibilityHelp("Open operation details. The percentage describes the named phase. Stop is available in the details panel.")
        NotificationCenter.default.addObserver(self, selector: #selector(contextBecameInactive(_:)),
                                              name: NSApplication.didResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize {
        let text = presentation.map { $0.phaseTitle + ($0.queueSummary.map { " · " + $0 } ?? "") } ?? "Operations"
        let width = (text as NSString).size(withAttributes: [.font: InterfaceMetrics.font(11)]).width
        return NSSize(width: min(240, max(100, width + 45)), height: 34)
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissHoverInspection()
        if let window {
            for name in [NSWindow.didResignMainNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            for name in [NSWindow.didResignMainNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(contextBecameInactive(_:)),
                                                      name: name, object: newWindow)
            }
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        dismissHoverInspection()
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        dismissalTask?.cancel()
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.showHoverInspection()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = nil
        scheduleHoverDismissal()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty && [UInt16(36), 49, 76].contains(event.keyCode) {
            inspect(nil)
        } else if event.keyCode == 53 {
            dismissHoverInspection()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        inspect(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        if isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let diameter: CGFloat = min(30, max(0, bounds.height - 4))
        let circle = NSRect(x: 3, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        let track = NSBezierPath(ovalIn: circle.insetBy(dx: 2, dy: 2))
        track.lineWidth = 2.5
        NSColor.separatorColor.setStroke()
        track.stroke()
        if let fraction = presentation.boundedPercentage, fraction > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: diameter / 2 - 2,
                          startAngle: 90, endAngle: 90 - CGFloat(fraction) * 360, clockwise: true)
            (presentation.stopping ? NSColor.secondaryLabelColor : NSColor.controlAccentColor).setStroke()
            arc.stroke()
        }
        let percent = presentation.percentageText as NSString
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.labelColor
        ]
        let size = percent.size(withAttributes: percentAttributes)
        percent.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                     withAttributes: percentAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: InterfaceMetrics.font(11), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let textHeight = InterfaceMetrics.font(11).boundingRectForFont.height + 2
        let title = presentation.phaseTitle + (presentation.queueSummary.map { " · " + $0 } ?? "")
        (title as NSString).draw(in: NSRect(x: circle.maxX + 6, y: bounds.midY - textHeight / 2,
            width: max(0, bounds.width - circle.maxX - 10), height: textHeight), withAttributes: titleAttributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    func dismissHoverInspection() {
        hoverTask?.cancel()
        hoverTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        if let window, ownsHoverResponder(window.firstResponder) { window.makeFirstResponder(self) }
        hoverCard?.removeFromSuperview()
        hoverCard = nil
        hoverDetails = nil
    }

    func ownsHoverResponder(_ responder: NSResponder?) -> Bool {
        guard let card = hoverCard else { return false }
        let view = responder as? NSView
        let field = (view as? NSTextView)?.delegate as? NSView
        return view?.isDescendant(of: card) == true || field?.isDescendant(of: card) == true
    }

    @objc private func inspect(_ sender: Any?) {
        guard presentation != nil else { return }
        dismissHoverInspection()
        onInspect?()
    }

    @objc nonisolated private func contextBecameInactive(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.dismissHoverInspection() }
    }

    private func showHoverInspection() {
        guard let presentation, !inspectionIsPinned, let host = hoverHost, let anchor = hoverBottomAnchor,
              window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        if hoverCard != nil { return }
        dismissHoverInspection()
        let details = OperationProgressDetailsView(frame: NSRect(origin: .zero, size: OperationProgressDetailsView.cardSize))
        details.presentation = presentation
        details.onQueue = onQueue
        details.onClose = { [weak self] in self?.dismissHoverInspection() }
        details.onHoverEnter = { [weak self] in self?.dismissalTask?.cancel() }
        details.onHoverExit = { [weak self] in self?.scheduleHoverDismissal() }
        // Hosting inside the browser avoids NSPopover's first-responder change
        // during an informational hover. It also stays within this window.
        let card = OperationProgressCardSurface(frame: .zero)
        card.setAccessibilityLabel("File operation hover details")
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        let controlRect = convert(bounds, to: host)
        let contentRect = anchor.convert(anchor.bounds, to: host)
        let nearTop = host.isFlipped ? controlRect.midY < contentRect.midY : controlRect.midY > contentRect.midY
        let vertical = nearTop
            ? card.topAnchor.constraint(equalTo: anchor.topAnchor, constant: 8)
            : card.bottomAnchor.constraint(equalTo: anchor.bottomAnchor, constant: -8 - hoverBottomInset)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: OperationProgressDetailsView.cardSize.width),
            card.heightAnchor.constraint(equalToConstant: OperationProgressDetailsView.cardSize.height),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            vertical
        ])
        pin(details, inside: card)
        hoverCard = card
        hoverDetails = details
        host.layoutSubtreeIfNeeded()
        if motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.alphaValue = motion.mode.initialOpacity(0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16 * motion.mode.durationScale
                card.animator().alphaValue = 1
            }
        }
    }

    private func scheduleHoverDismissal() {
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            if !self.containsPointer(), self.hoverDetails?.containsPointer() != true { self.dismissHoverInspection() }
        }
    }

    private func containsPointer() -> Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }
}

/// Compact content shared by transient hover and persistent in-window inspection.
/// Hover is informational. Stop is shown only when its host supplies that action.
@MainActor
final class OperationProgressDetailsView: NSView {
    static let cardSize = NSSize(width: 380, height: 250)
    var presentation: OperationProgressPresentation? { didSet { updatePresentation() } }
    var onStop: (() -> Void)? { didSet { updatePresentation() } }
    var onQueue: (() -> Void)? { didSet { updatePresentation() } }
    var onClose: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?

    private let heading = label("Operation details", size: 13, weight: .semibold)
    private let summaryField = label("", size: 11, color: .secondaryLabelColor)
    private let sourceField = label("", size: 11)
    private let destinationField = label("", size: 11)
    private let itemField = label("", size: 11)
    private let completedField = label("", size: 11)
    private let remainingField = label("", size: 11)
    private let speedField = label("", size: 11)
    private let graph = OperationThroughputGraph(frame: .zero)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let queueButton = NSButton(title: "Queue", target: nil, action: nil)
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summaryField.maximumNumberOfLines = 2
        summaryField.lineBreakMode = .byWordWrapping
        summaryField.heightAnchor.constraint(equalToConstant: 27).isActive = true
        for field in [sourceField, destinationField, itemField] { field.isSelectable = true }
        let paths = stack([detailRow("From", sourceField, accessibilityTitle: "Source"),
                           detailRow("To", destinationField, accessibilityTitle: "Destination"),
                           detailRow("Item", itemField, accessibilityTitle: "Current item")],
                          orientation: .vertical, spacing: 3)
        for row in paths.arrangedSubviews { row.widthAnchor.constraint(equalTo: paths.widthAnchor).isActive = true }
        let completed = detailRow("Done", completedField, accessibilityTitle: "Completed in this phase")
        let remaining = detailRow("Left", remainingField, accessibilityTitle: "Remaining in this phase")
        graph.heightAnchor.constraint(equalToConstant: 50).isActive = true
        graph.setAccessibilityLabel("Recent logical copy speed history")
        graph.toolTip = "Recent logical copy bytes per second, up to 60 seconds. This is not physical disk throughput."
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: 11)
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.setAccessibilityHelp("Request that this operation stop at a safe boundary. Completed changes may remain.")
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        queueButton.bezelStyle = .rounded; queueButton.controlSize = .small
        queueButton.font = .systemFont(ofSize: 11); queueButton.target = self
        queueButton.action = #selector(inspectQueue(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = stack([heading, spacer, queueButton, stopButton, closeButton], orientation: .horizontal, spacing: 6)
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        speedField.textColor = .secondaryLabelColor
        speedField.setAccessibilityLabel("Logical copy speed")
        let content = stack([header, summaryField, paths, completed, remaining, speedField, graph], orientation: .vertical, spacing: 4)
        for child in content.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        pin(content, inside: self, inset: 12)
        updatePresentation()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.cardSize }
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func focusPrimaryAction() {
        if let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let button = stopButton.isEnabled && !stopButton.isHidden ? stopButton : closeButton
        _ = button.scrollToVisible(button.bounds)
        window?.makeFirstResponder(button)
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    fileprivate func containsPointer() -> Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    private func detailRow(_ title: String, _ value: NSTextField, accessibilityTitle: String) -> NSView {
        let name = label(title, size: 11, color: .secondaryLabelColor)
        name.widthAnchor.constraint(equalToConstant: 38).isActive = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = stack([name, value], orientation: .horizontal, spacing: 6)
        value.setAccessibilityLabel(accessibilityTitle)
        return row
    }

    private func updatePresentation() {
        heading.stringValue = presentation.map { "\($0.phaseTitle)  \($0.percentageText)" } ?? "Operation details"
        summaryField.stringValue = (presentation?.summary ?? "No active operation")
            + (presentation?.queueSummary.map { " · " + $0 } ?? "")
        sourceField.stringValue = presentation?.sourcePath ?? "—"
        destinationField.stringValue = presentation?.destinationPath ?? "—"
        itemField.stringValue = presentation?.currentItem ?? "—"
        completedField.stringValue = presentation?.completedText ?? "—"
        remainingField.stringValue = presentation?.remainingText ?? "Not measured"
        speedField.stringValue = presentation?.speedText ?? "Recent copy speed · logical bytes/s"
        for field in [sourceField, destinationField, itemField] { field.toolTip = field.stringValue }
        graph.samples = presentation?.samples ?? []
        graph.setAccessibilityValue(presentation?.speedText ?? "Copy speed not measured")
        stopButton.isHidden = onStop == nil || presentation?.terminal != false
        stopButton.isEnabled = presentation?.stopping == false && presentation?.terminal == false
        stopButton.title = presentation?.stopping == true ? "Stopping…" : "Stop"
        queueButton.isHidden = onQueue == nil
    }

    @objc private func stop(_ sender: Any?) {
        guard presentation?.stopping == false, presentation?.terminal == false else { return }
        onStop?()
    }

    @objc private func close(_ sender: Any?) { onClose?() }
    @objc private func inspectQueue(_ sender: Any?) { onQueue?() }
}

/// Persistent inspection stays inside the explorer without consuming a full-width row.
@MainActor
final class OperationProgressCardSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pinned file operation details")
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateLayer() {
        super.updateLayer()
        // Operation text must stay readable above arbitrary folder content.
        // Semantic opaque colors avoid inheriting a translucent experimental canvas.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}

@MainActor
private final class OperationThroughputGraph: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let plot = bounds.insetBy(dx: 8, dy: 8)
        NSColor.separatorColor.setStroke()
        for fraction: CGFloat in [0, 0.5, 1] {
            let grid = NSBezierPath()
            grid.lineWidth = 0.5
            grid.move(to: NSPoint(x: plot.minX, y: plot.minY + plot.height * fraction))
            grid.line(to: NSPoint(x: plot.maxX, y: plot.minY + plot.height * fraction))
            grid.stroke()
        }
        let values = samples.suffix(240).map { $0.isFinite ? max(0, $0) : 0 }
        guard values.count > 1, let maximum = values.max(), maximum > 0 else {
            let text = (values.count > 1 ? "0 bytes/s" : "Waiting for copy samples") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: InterfaceMetrics.font(10), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        let line = NSBezierPath()
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: plot.minY + plot.height * CGFloat(value / maximum))
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
        fill.close()
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        fill.fill()
        line.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }
}
