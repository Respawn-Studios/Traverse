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

/// One overlay per workspace. Controls sit beside the line so the
/// native divider remains a resize target along its full length.
@MainActor
final class WorkspaceDividerControls: NSView {
    static let revealDistance: CGFloat = 7

    struct Divider: Equatable {
        let id: UUID
        let axis: PaneSplitAxis
        let line: NSRect
        let canBalance: Bool
        let canRotate: Bool
        let pairAction: WorkspaceDividerAction?
        let canCompareGit: Bool
        let canLink: Bool
        let isLinked: Bool
        let copyDestination: LocalPaneDestination?
        var canCopy: Bool { copyDestination != nil }

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
    var perform: (WorkspaceDividerAction, UUID) -> Void = { _, _ in }
    var motion = BrowserMotionPreferences()
    private var tracking: NSTrackingArea?
    private var dividerID: UUID?
    private var anchor: CGFloat = 0
    private var positioned: Divider?
    private var buttonSize: CGFloat = 0
    private let shelf = NSView()
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        shelf.alphaValue = 0
        shelf.isHidden = true
        addSubview(shelf)
        for (index, action) in WorkspaceDividerAction.allCases.enumerated() {
            let button = NSButton()
            button.tag = index
            button.bezelStyle = .texturedRounded
            button.wantsLayer = true
            button.controlSize = .regular
            button.imagePosition = .imageOnly
            button.refusesFirstResponder = true
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.target = self
            button.action = #selector(performAction(_:))
            shelf.addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }

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
    override func mouseExited(with event: NSEvent) { dismiss() }

    func updateHover(at windowPoint: NSPoint) {
        guard superview != nil else { return }
        let point = convert(windowPoint, from: nil)
        let held = shelf.frame.insetBy(dx: -4, dy: -4).contains(point) ? dividerID : nil
        let available = dividers(point, held)
        if let current = available.first(where: { $0.id == held }) {
            position(on: current)
            return
        }
        let nearest = available.compactMap { divider in
            divider.distance(to: point).map { (divider, $0) }
        }.min { $0.1 < $1.1 }
        guard let (divider, distance) = nearest, distance <= Self.revealDistance else { dismiss(); return }
        let wasHidden = dividerID == nil
        if dividerID != divider.id {
            dividerID = divider.id
            anchor = divider.axis == .columns ? point.y : point.x
        }
        position(on: divider)
        if wasHidden { setPresented(true, animated: true) }
    }

    /// Selection, a folder visit or Git discovery can change the offered
    /// actions while the pointer is stationary. Keep the existing anchor.
    func refreshPresentation() {
        guard let dividerID else { return }
        guard let current = dividers(nil, dividerID).first(where: { $0.id == dividerID }) else { dismiss(); return }
        position(on: current)
    }

    private func position(on divider: Divider) {
        let size = InterfaceMetrics.points(28)
        let sizeChanged = buttonSize != size
        guard positioned != divider || sizeChanged else { return }
        positioned = divider; buttonSize = size
        let gap = 2 * Self.revealDistance
        let columns = divider.axis == .columns
        let line = divider.line
        let low = (columns ? line.minY : line.minX) + size / 2
        let high = (columns ? line.maxY : line.maxX) - size / 2
        let along = min(max(low, anchor), high)
        let rotationOffset = divider.canLink ? size + 3 : 0
        let leading = rotationOffset + (divider.canRotate ? size + 3 : 0)
        let afterBalance = leading + 2 * size + gap
        let afterPairAction = afterBalance + (divider.pairAction == nil ? 0 : size + 3)
        let afterGit = afterPairAction + (divider.canCompareGit ? size + 3 : 0)
        let extent = afterGit + (divider.canCopy ? size + 3 : 0)
        shelf.frame = columns
            ? NSRect(x: line.midX - gap / 2 - size - leading, y: along - size / 2, width: extent, height: size)
            : NSRect(x: along - size / 2, y: line.midY - gap / 2 - size - leading, width: size, height: extent)
        for (index, action) in WorkspaceDividerAction.allCases.enumerated() {
            let button = buttons[index]
            let offset: CGFloat = switch action {
            case .link: 0
            case .rotate: rotationOffset
            case .swap: leading
            case .balance: leading + size + gap
            case .compare, .compareText, .compareMatchingText, .selectMatch: afterBalance + 3
            case .compareGit: afterPairAction + 3
            case .copy: afterGit + 3
            }
            button.frame = NSRect(x: columns ? offset : 0, y: columns ? 0 : offset, width: size, height: size)
            let symbol = action.symbol(for: divider.axis, isLinked: divider.isLinked)
            let title = divider.title(for: action)
            if button.identifier?.rawValue != symbol || sizeChanged {
                button.identifier = NSUserInterfaceItemIdentifier(symbol)
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: InterfaceMetrics.points(13), weight: .semibold))
            }
            if button.toolTip != title {
                button.toolTip = title
                button.setAccessibilityLabel(title)
            }
            button.isEnabled = action != .balance || divider.canBalance
            button.isHidden = switch action {
            case .compare, .compareText, .compareMatchingText, .selectMatch: action != divider.pairAction
            case .compareGit: !divider.canCompareGit
            case .rotate: !divider.canRotate
            case .link: !divider.canLink
            case .copy: !divider.canCopy
            case .swap, .balance: false
            }
            button.contentTintColor = action == .link && divider.isLinked ? .controlAccentColor : nil
        }
    }

    func dismiss(animated: Bool = true) {
        guard dividerID != nil || (!animated && !shelf.isHidden) else { return }
        dividerID = nil
        positioned = nil
        setPresented(false, animated: animated)
    }

    private func setPresented(_ presented: Bool, animated: Bool) {
        if presented { shelf.isHidden = false }
        let opacity: CGFloat = presented ? 1 : 0
        let duration = animated && motion.allows(.panes) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? (presented ? 0.16 : 0.10) * motion.mode.durationScale : 0
        guard duration > 0 else {
            for button in buttons { button.layer?.removeAnimation(forKey: "dividerReveal") }
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
            for button in buttons where !button.isHidden { button.layer?.add(reveal, forKey: "dividerReveal") }
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
        return buttons.first { !$0.isHidden && $0.frame.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        button(at: superview?.convert(point, to: nil) ?? point)
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let dividerID, sender.isEnabled, !sender.isHiddenOrHasHiddenAncestor,
              buttons.indices.contains(sender.tag), buttons[sender.tag] === sender else { return }
        perform(WorkspaceDividerAction.allCases[sender.tag], dividerID)
    }
}
