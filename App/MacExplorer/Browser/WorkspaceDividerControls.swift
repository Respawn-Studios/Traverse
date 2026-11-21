import AppKit
import ExplorerCore

enum WorkspaceDividerAction: CaseIterable {
    case swap, balance, rotate, compare, compareText, compareMatchingText, selectMatch, link, compareGit, copy

    var command: BrowserCommand {
        switch self {
        case .swap: .swapPaneSides
        case .balance: .balancePaneSizes
        case .rotate: .rotatePaneSplit
        case .compare: .compareFolders
        case .compareText, .compareMatchingText: .compareTextFiles
        case .selectMatch: .selectMatchingPaneItem
        case .link: .linkPaneNavigation
        case .compareGit: .compareGitCheckouts
        case .copy: .copyToPane
        }
    }
    var title: String {
        switch self {
        case .compareText: "Compare Selected Text Files"
        case .compareMatchingText: "Compare Text with Matching Filename"
        default: command.title
        }
    }
    func title(isLinked: Bool) -> String {
        self == .link && isLinked ? "Unlink Pane Navigation" : title
    }

    func symbol(for axis: PaneSplitAxis, isLinked: Bool) -> String {
        switch (self, axis) {
        case (.swap, .columns): "arrow.left.arrow.right"
        case (.swap, .rows): "arrow.up.arrow.down"
        case (.balance, .columns): "rectangle.split.2x1"
        case (.balance, .rows): "rectangle.split.1x2"
        case (.rotate, .columns): "rectangle.split.1x2"
        case (.rotate, .rows): "rectangle.split.2x1"
        case (.compare, _): "doc.on.doc"
        case (.compareText, _): "doc.text"
        case (.compareMatchingText, _): "doc.text.magnifyingglass"
        case (.selectMatch, _): "scope"
        case (.link, _): isLinked ? "link.circle.fill" : "link"
        case (.compareGit, _): "arrow.triangle.branch"
        case (.copy, _): "plus.square.on.square"
        }
    }
}

@MainActor
private final class WorkspaceDividerShelf: NSView {
    var focusPreferences = PaneFocusPreferences() {
        didSet { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = CGFloat(focusPreferences.thickness)
        let radius = InterfaceMetrics.points(9)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
                                   xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        outline.fill()
        focusPreferences.color.setStroke()
        outline.lineWidth = width
        outline.stroke()
    }
}

/// One control group straddles the hovered divider. The rest of the
/// divider remains a native resize target.
@MainActor
final class WorkspaceDividerControls: NSView {
    static let revealDistance: CGFloat = 7

    struct PanePair: Equatable {
        let first: UUID
        let second: UUID
    }

    struct Divider: Equatable {
        let id: UUID
        let axis: PaneSplitAxis
        let line: NSRect
        let panes: PanePair?
        let canBalance: Bool
        let canRotate: Bool
        let pairAction: WorkspaceDividerAction?
        let canCompareGit: Bool
        let canLink: Bool
        let isLinked: Bool
        let copyDestination: LocalPaneDestination?
        var canCopy: Bool { copyDestination != nil }

        var actions: [WorkspaceDividerAction] {
            var result: [WorkspaceDividerAction] = [.swap, .balance]
            if canRotate { result.append(.rotate) }
            if let pairAction { result.append(pairAction) }
            if canLink { result.append(.link) }
            if canCompareGit { result.append(.compareGit) }
            if canCopy { result.append(.copy) }
            return result
        }

        func enables(_ action: WorkspaceDividerAction) -> Bool { action != .balance || canBalance }

        func title(for action: WorkspaceDividerAction) -> String {
            if action == .copy, let copyDestination { return "Copy to " + copyDestination.title }
            if action == .rotate { return axis == .columns ? "Stack Panes" : "Place Panes Side by Side" }
            return action.title(isLinked: isLinked)
        }

        static func distance(from line: NSRect, axis: PaneSplitAxis, to point: NSPoint) -> CGFloat? {
            switch axis {
            case .columns:
                guard (line.minY...line.maxY).contains(point.y) else { return nil }
                return abs(line.midX - point.x)
            case .rows:
                guard (line.minX...line.maxX).contains(point.x) else { return nil }
                return abs(line.midY - point.y)
            }
        }

        func distance(to point: NSPoint) -> CGFloat? { Self.distance(from: line, axis: axis, to: point) }
    }

    var dividers: (NSPoint?, UUID?) -> [Divider] = { _, _ in [] }
    var perform: (WorkspaceDividerAction, Divider) -> Void = { _, _ in }
    var motion = BrowserMotionPreferences()
    var focusPreferences: PaneFocusPreferences {
        get { shelf.focusPreferences }
        set { shelf.focusPreferences = newValue }
    }
    private var tracking: NSTrackingArea?
    private var dividerID: UUID?
    private var hoveredPoint: NSPoint?
    private var placedBounds: NSRect = .zero
    private var positioned: Divider?
    private var buttonSize: CGFloat = 0
    private let shelf = WorkspaceDividerShelf()
    private var buttons: [NSButton] = []
    private let more = NSButton()
    private(set) var overflowActions: [WorkspaceDividerAction] = []
    private var showingOverflow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        shelf.alphaValue = 0
        shelf.isHidden = true
        addSubview(shelf)
        for (index, action) in WorkspaceDividerAction.allCases.enumerated() {
            let button = makeButton(NSButton(), title: action.title, command: #selector(performAction(_:)))
            button.tag = index
            buttons.append(button)
        }
        makeButton(more, title: "More Pane Actions", command: #selector(showOverflow(_:)))
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    private func makeButton(_ button: NSButton, title: String, command: Selector) -> NSButton {
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.wantsLayer = true
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = command
        shelf.addSubview(button)
        return button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss(animated: false) }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { if !showingOverflow { dismiss() } }

    func updateHover(at windowPoint: NSPoint) {
        guard !showingOverflow, superview != nil else { return }
        let point = convert(windowPoint, from: nil)
        let held = shelf.frame.insetBy(dx: -4, dy: -4).contains(point) ? dividerID : nil
        let available = dividers(point, held)
        if let current = available.first(where: { $0.id == held }) {
            hoveredPoint = point
            position(on: current)
            return
        }
        let nearest = available.compactMap { divider in
            divider.distance(to: point).map { (divider, $0) }
        }.min { $0.1 < $1.1 }
        guard let (divider, distance) = nearest, distance <= Self.revealDistance else { dismiss(); return }
        let wasHidden = dividerID == nil
        dividerID = divider.id
        hoveredPoint = point
        position(on: divider)
        if wasHidden && dividerID != nil { setPresented(true, animated: true) }
    }

    /// Selection, a folder visit or Git discovery can change the offered
    /// actions while the pointer is stationary. Keep the same hovered segment.
    func refreshPresentation() {
        guard let dividerID, let hoveredPoint else { return }
        guard let current = dividers(hoveredPoint, dividerID).first(where: { $0.id == dividerID }) else { dismiss(); return }
        position(on: current)
    }

    private func position(on divider: Divider) {
        let size = InterfaceMetrics.points(28)
        let sizeChanged = buttonSize != size
        guard positioned != divider || sizeChanged || placedBounds != bounds else { return }
        positioned = divider; buttonSize = size
        placedBounds = bounds
        let columns = divider.axis == .columns
        let line = divider.line
        let length = columns ? line.height : line.width
        let spacing = InterfaceMetrics.points(3)
        let padding = InterfaceMetrics.points(4)
        let edgeRoom = InterfaceMetrics.points(4)
        let slots = Int(max(0, (length - 2 * (padding + edgeRoom) + spacing) / (size + spacing)))
        guard slots > 0 else {
            dismiss(animated: false); return
        }

        let actions = divider.actions
        let overflow = actions.count > slots
        let shown = actions.prefix(overflow ? slots - 1 : actions.count)
        overflowActions = Array(actions.dropFirst(shown.count))
        let count = shown.count + (overflow ? 1 : 0)
        let groupLength = CGFloat(count) * (size + spacing) - spacing + 2 * padding
        let groupWidth = size + 2 * padding
        let width = columns ? groupWidth : groupLength
        let height = columns ? groupLength : groupWidth
        let groupFrame = NSRect(x: line.midX - width / 2, y: line.midY - height / 2, width: width, height: height)
        guard bounds.contains(groupFrame) else {
            dismiss(animated: false); return
        }
        shelf.frame = groupFrame
        shelf.needsDisplay = true

        func frame(at index: Int) -> NSRect {
            let offset = padding + CGFloat(index) * (size + spacing)
            return NSRect(x: columns ? padding : offset, y: columns ? groupLength - offset - size : padding,
                          width: size, height: size)
        }
        for (index, action) in WorkspaceDividerAction.allCases.enumerated() {
            let button = buttons[index]
            button.isHidden = !shown.contains(action)
            guard let position = shown.firstIndex(of: action) else { continue }
            button.frame = frame(at: position)
            let symbol = action.symbol(for: divider.axis, isLinked: divider.isLinked)
            let title = divider.title(for: action)
            let imageIdentity = NSUserInterfaceItemIdentifier("\(symbol)-\(size)")
            if button.identifier != imageIdentity {
                button.identifier = imageIdentity
                button.image = actionImage(symbol)
            }
            if button.toolTip != title {
                button.toolTip = title
                button.setAccessibilityLabel(title)
            }
            button.isEnabled = divider.enables(action)
            button.contentTintColor = action == .link && divider.isLinked ? .controlAccentColor
                : button.isEnabled ? .labelColor : .tertiaryLabelColor
        }
        more.isHidden = !overflow
        if overflow {
            more.frame = frame(at: shown.count)
            more.contentTintColor = .labelColor
            if sizeChanged || more.image == nil { more.image = actionImage("ellipsis") }
        }
    }

    private func actionImage(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: InterfaceMetrics.points(13), weight: .semibold))
    }

    func dismiss(animated: Bool = true) {
        guard dividerID != nil || (!animated && !shelf.isHidden) else { return }
        dividerID = nil
        hoveredPoint = nil
        positioned = nil
        overflowActions = []
        setPresented(false, animated: animated)
    }

    private func setPresented(_ presented: Bool, animated: Bool) {
        if presented { shelf.isHidden = false }
        let opacity: CGFloat = presented ? 1 : 0
        let duration = animated && motion.allows(.panes) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? (presented ? 0.16 : 0.10) * motion.mode.durationScale : 0
        guard duration > 0 else {
            for button in buttons + [more] { button.layer?.removeAnimation(forKey: "dividerReveal") }
            shelf.alphaValue = opacity
            shelf.isHidden = !presented
            return
        }
        if presented && motion.mode == .full {
            let reveal = CABasicAnimation(keyPath: "transform.scale")
            reveal.fromValue = 0.86
            reveal.toValue = 1.0
            reveal.duration = duration
            reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for button in buttons + [more] where !button.isHidden { button.layer?.add(reveal, forKey: "dividerReveal") }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            shelf.animator().alphaValue = opacity
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.dividerID == nil { self.shelf.isHidden = true }
            }
        }
    }

    func button(at windowPoint: NSPoint) -> NSButton? {
        guard dividerID != nil, !shelf.isHidden else { return nil }
        let point = shelf.convert(windowPoint, from: nil)
        if !more.isHidden && more.frame.contains(point) { return more }
        return buttons.first { !$0.isHidden && $0.frame.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        button(at: superview?.convert(point, to: nil) ?? point)
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let divider = positioned, dividerID == divider.id, sender.isEnabled, !sender.isHiddenOrHasHiddenAncestor,
              buttons.indices.contains(sender.tag), buttons[sender.tag] === sender else { return }
        perform(WorkspaceDividerAction.allCases[sender.tag], divider)
    }

    @objc private func showOverflow(_ sender: NSButton) {
        guard sender === more, !more.isHiddenOrHasHiddenAncestor, let divider = positioned,
              !overflowActions.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in overflowActions {
            guard let index = WorkspaceDividerAction.allCases.firstIndex(of: action) else { continue }
            let item = NSMenuItem(title: divider.title(for: action), action: #selector(performOverflowAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = actionImage(action.symbol(for: divider.axis, isLinked: divider.isLinked))
            item.isEnabled = divider.enables(action)
            menu.addItem(item)
        }
        showingOverflow = true
        defer {
            showingOverflow = false
            if let window { updateHover(at: window.mouseLocationOutsideOfEventStream) }
        }
        menu.popUp(positioning: nil, at: .init(x: more.bounds.minX, y: more.bounds.minY), in: more)
    }

    @objc private func performOverflowAction(_ sender: NSMenuItem) {
        let actions = WorkspaceDividerAction.allCases
        guard let divider = positioned, dividerID == divider.id, actions.indices.contains(sender.tag),
              overflowActions.contains(actions[sender.tag]), divider.enables(actions[sender.tag]) else { return }
        perform(actions[sender.tag], divider)
    }
}
