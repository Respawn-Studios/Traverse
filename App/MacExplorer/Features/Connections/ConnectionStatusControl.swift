import AppKit
import QuartzCore

enum ConnectionIndicatorPhase: Int {
    case disconnected = 1, connecting = 2, connected = 3
    case attention = 4
    var activeBars: Int { self == .attention ? 2 : rawValue }
    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .attention: "Needs attention"
        }
    }
}

/// A fixed native hit target with pointer-responsive bars. Session observations
/// supply the values; presentation never starts probes, reads or authentication.
@MainActor final class ConnectionStatusControl: NSButton {
    private let bars = (0..<3).map { _ in CALayer() }
    private var phase: ConnectionIndicatorPhase?
    private var motion = BrowserMotionPreferences()
    private var interfaceScale: CGFloat = 1
    private var tracking: NSTrackingArea?
    private var pointer: NSPoint?
    private var hover: Task<Void, Never>?
    private var popover: NSPopover?
    private var windowObservation: BrowserNotificationObservation?
    private var detail = ""
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var reconnect: (() -> Void)?
    init(reconnect: @escaping () -> Void) {
        self.reconnect = reconnect
        super.init(frame: .zero)
        title = ""; isBordered = false; bezelStyle = .recessed
        target = self; action = #selector(activate(_:))
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        for bar in bars { bar.cornerRadius = 2; layer?.addSublayer(bar) }
        setAccessibilityLabel("Connection status")
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .init(width: 33 * interfaceScale, height: 24 * interfaceScale) }
    func configure(_ next: ConnectionIndicatorPhase?, detail: String, motion: BrowserMotionPreferences) {
        let changed = phase != next
        self.motion = motion; phase = next; isHidden = next == nil
        if interfaceScale != InterfaceMetrics.scale {
            interfaceScale = InterfaceMetrics.scale; invalidateIntrinsicContentSize(); needsLayout = true
            dismissDetails()
        }
        self.detail = detail
        detailLabel.font = InterfaceMetrics.font(12)
        detailLabel.textColor = .labelColor
        detailLabel.attributedStringValue = formattedDetails(detail)
        if let content = popover?.contentViewController { content.preferredContentSize = content.view.fittingSize }
        // Native tooltip delay is intentionally avoided: the owned, non-key
        // popover appears promptly without changing global tooltip preferences.
        toolTip = nil
        setAccessibilityValue(next?.title)
        setAccessibilityHelp(detail)
        if next == nil { dismissDetails() }
        CATransaction.begin()
        CATransaction.setDisableActions(!changed || !animates)
        CATransaction.setAnimationDuration(0.18 * motion.mode.durationScale)
        let color: NSColor = switch next {
        case .connected: .systemGreen
        case .connecting, .attention: .systemYellow
        case .disconnected: .systemRed
        case nil: .secondaryLabelColor
        }
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = color.cgColor
            bar.opacity = index < (next?.activeBars ?? 0) ? 1 : 0.18
            if !animates { bar.removeAllAnimations(); bar.transform = CATransform3DIdentity }
        }
        CATransaction.commit()
        arrangeBars(animated: changed)
    }
    override func layout() { super.layout(); arrangeBars(animated: false) }
    private var animates: Bool {
        motion.allows(.connectionStatus) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private func arrangeBars(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || !animates)
        CATransaction.setAnimationDuration(0.13 * motion.mode.durationScale)
        for (index, bar) in bars.enumerated() {
            let height = CGFloat(6 + index * 4) * interfaceScale
            let x = bounds.midX - 10 * interfaceScale + CGFloat(index) * 7 * interfaceScale
            let flipped = layer?.isGeometryFlipped == true
            let bottom = flipped ? bounds.midY + 7 * interfaceScale - height : bounds.midY - 7 * interfaceScale
            var frame = NSRect(x: x, y: bottom, width: 5 * interfaceScale, height: height)
            if animates, var pointer {
                if isFlipped != flipped { pointer.y = bounds.maxY - pointer.y }
                // Trim and lift around a small circular pointer exclusion. The
                // pointer's actual vertical position chooses which end recedes.
                let dx = frame.midX - pointer.x
                let radius: CGFloat = 8 * interfaceScale
                if abs(dx) < radius {
                    let reach = sqrt(radius * radius - dx * dx)
                    let below = max(0, pointer.y - reach - frame.minY)
                    let above = max(0, frame.maxY - pointer.y - reach)
                    let strength = CGFloat(motion.mode.distanceScale)
                    let targetHeight = max(3 * interfaceScale, max(below, above))
                    let newHeight = height + (targetHeight - height) * strength
                    if above > below { frame.origin.y += (height - newHeight) + strength * 2 * interfaceScale }
                    else { frame.origin.y -= strength * 2 * interfaceScale }
                    frame.size.height = newHeight
                }
            }
            bar.frame = frame
        }
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil); arrangeBars(animated: true)
        hover?.cancel()
        hover = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, pointer != nil, window?.isKeyWindow == true, !isHidden else { return }
            presentDetails()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil); arrangeBars(animated: true)
    }
    override func mouseExited(with event: NSEvent) {
        pointer = nil; arrangeBars(animated: true); dismissDetails()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservation = window.map { window in
            BrowserNotificationObservation(name: NSWindow.didResignKeyNotification, object: window) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointer = nil; self?.dismissDetails(); self?.arrangeBars(animated: false) }
            }
        }
        if window == nil { pointer = nil; dismissDetails(); for bar in bars { bar.removeAllAnimations() } }
    }
    private func presentDetails() {
        guard popover == nil, !detail.isEmpty, phase != nil else { return }
        let content = NSViewController()
        detailLabel.preferredMaxLayoutWidth = min(380, 320 * InterfaceMetrics.scale) - 28
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(); host.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            detailLabel.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            host.widthAnchor.constraint(equalToConstant: min(380, 320 * InterfaceMetrics.scale))
        ])
        content.view = host
        content.preferredContentSize = host.fittingSize
        let popover = NSPopover(); popover.contentViewController = content
        popover.behavior = .transient; popover.animates = animates
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
    private func formattedDetails(_ detail: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3 * InterfaceMetrics.scale
        let value = NSMutableAttributedString(string: detail, attributes: [
            .font: InterfaceMetrics.font(12), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let labels = ["Folder", "Security", "Access", "Items", "Latest directory read",
                      "Latest complete listing", "Connected", "Status"]
        var offset = 0
        for (index, line) in detail.components(separatedBy: "\n").enumerated() {
            let range = NSRange(location: offset, length: line.utf16.count)
            if index < 2 {
                let heading = NSMutableParagraphStyle()
                heading.lineSpacing = paragraph.lineSpacing
                heading.paragraphSpacing = (index == 0 ? 3 : 6) * InterfaceMetrics.scale
                value.addAttributes([.font: InterfaceMetrics.font(index == 0 ? 13 : 12,
                    weight: index == 0 ? .semibold : .medium), .paragraphStyle: heading], range: range)
            } else if let label = labels.first(where: { line.hasPrefix($0 + ":") }) {
                value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                    range: NSRange(location: offset, length: label.utf16.count + 1))
            } else {
                value.addAttributes([.font: InterfaceMetrics.font(11),
                    .foregroundColor: NSColor.secondaryLabelColor], range: range)
            }
            offset += range.length + 1
        }
        return value
    }
    private func dismissDetails() {
        hover?.cancel(); hover = nil; popover?.close(); popover = nil
        detailLabel.removeFromSuperview()
    }
    @objc private func activate(_ sender: Any?) {
        dismissDetails()
        if animates {
            for (index, bar) in bars.enumerated() {
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                animation.values = [1, 0.55, 1.3, 0.9, 1]
                animation.keyTimes = [0, 0.22, 0.5, 0.78, 1]
                animation.duration = 0.38 * motion.mode.durationScale
                animation.beginTime = CACurrentMediaTime() + Double(index) * 0.035 * motion.mode.durationScale
                bar.add(animation, forKey: "connection-click")
            }
        }
        if phase == .disconnected { reconnect?() }
    }
    #if DEBUG
    var displayedDetailsForVerification: String { detail }
    var phaseForVerification: ConnectionIndicatorPhase? { phase }
    var detailsVisibleForVerification: Bool { popover?.isShown == true }
    var detailsWindowForVerification: NSWindow? { popover?.contentViewController?.view.window }
    #endif
}
