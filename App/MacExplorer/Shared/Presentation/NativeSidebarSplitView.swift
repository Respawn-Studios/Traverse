import AppKit
import ExplorerCore
import QuartzCore

/// One native divider for a sidebar and its matching content. The tree and its
/// controllers stay installed while collapsed; presentation never rebuilds them.
@MainActor
final class NativeSidebarSplitView: NSSplitView, NSSplitViewDelegate {
    private(set) var sidebarWidth: CGFloat = 200
    private(set) var isSidebarCollapsed = false
    var remainingMinimum: (() -> CGFloat)?
    var canCollapse: (() -> Bool)?
    var onToggleRequested: (() -> Void)?
    var onWidthChanged: (() -> Void)?
    var onCollapsedChanged: (() -> Void)?
    var onPresentationChanged: (() -> Void)?
    var motion = BrowserMotionPreferences()
    private var positioning = false
    private let transition = DisplayLinkedTransition()
    private var sidebarContentConstraints: (width: NSLayoutConstraint, trailing: NSLayoutConstraint)?
    var isAnimating: Bool { transition.isAnimating }
    var snapshot: PaneWorkspaceSnapshot.Sidebar {
        .init(isCollapsed: isSidebarCollapsed, expandedWidth: Double(sidebarWidth))
    }
    var reservedWidth: CGFloat { isSidebarCollapsed ? 0 : sidebarWidth + dividerThickness }
    var collapsedFraction: CGFloat { 1 - min(1, max(0, sidebarPosition / max(1, expandedPosition))) }

    /// Retarget from the current live divider, keeping native blur and text live.
    private(set) var sidebarPosition: CGFloat = 200 {
        didSet { layoutSidebar() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 500))
        isVertical = true; dividerStyle = .thin; delegate = self
        setAccessibilityLabel("Sidebar and file panes")
    }
    required init?(coder: NSCoder) { nil }

    private var maximumSidebarWidth: CGFloat {
        max(0, min(340, bounds.width - dividerThickness - (remainingMinimum?() ?? 400)))
    }
    private var expandedPosition: CGFloat { min(sidebarWidth, maximumSidebarWidth) }

    /// The split owns the moving viewport. Keep the active tree at its expanded
    /// width, so rows slide out whole instead of rewrapping on each tick.
    /// Reduced motion lets the viewport do most of the clipping while its
    /// text moves a shorter distance.
    func installSidebarContent(_ content: NSView?) {
        guard let host = arrangedSubviews.first, host.subviews.first !== content else { return }
        if let constraints = sidebarContentConstraints {
            NSLayoutConstraint.deactivate([constraints.width, constraints.trailing])
        }
        sidebarContentConstraints = nil
        host.subviews.forEach { $0.removeFromSuperview() }
        guard let content else { return }
        host.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        let width = content.widthAnchor.constraint(equalToConstant: expandedPosition)
        let trailing = content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        NSLayoutConstraint.activate([width, trailing,
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        sidebarContentConstraints = (width, trailing)
    }

    func restore(_ value: PaneWorkspaceSnapshot.Sidebar?) {
        let value = value ?? .init()
        sidebarWidth = CGFloat(value.expandedWidth)
        isSidebarCollapsed = value.isCollapsed
        finishAnimation()
    }

    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard isSidebarCollapsed != collapsed else { return }
        let start = sidebarPosition
        isSidebarCollapsed = collapsed
        // Update minimum-size/focus/footer ownership before the first frame.
        // Expansion may grow the window before claiming space from the panes.
        onCollapsedChanged?()
        let target: CGFloat = collapsed ? 0 : expandedPosition
        guard animated, motion.allows(.panes), let window, window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishAnimation(); return
        }
        subviews.first?.isHidden = false
        transition.animate(in: window, duration: motion.mode.paneDuration(closing: true), startsOnFirstFrame: true,
                           update: { [weak self] progress in
            self?.sidebarPosition = start + (target - start) * progress
        }, completion: { [weak self] in
            self?.finishAnimation()
        })
    }

    /// Resize, close, a native drag or a motion-policy change settles the current
    /// requested state and invalidates older animation completions.
    func finishAnimation() {
        transition.cancel()
        let target: CGFloat = isSidebarCollapsed ? 0 : expandedPosition
        sidebarPosition = target
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // AppKit can request another layout at the same size during a frame.
        // Only a real allocation change interrupts the requested transition.
        if isAnimating {
            if oldSize != bounds.size { finishAnimation() }
            else { layoutSidebar() }
        } else { sidebarPosition = isSidebarCollapsed ? 0 : expandedPosition }
    }

    private func layoutSidebar() {
        guard subviews.count == 2, !positioning else { return }
        positioning = true
        defer { positioning = false }
        let available = maximumSidebarWidth
        let width = min(available, max(0, sidebarPosition))
        let expanded = min(sidebarWidth, available)
        if let constraints = sidebarContentConstraints {
            let retainedWidth = max(0, expanded - width) * (1 - motion.mode.distanceScale)
            if constraints.width.constant != expanded { constraints.width.constant = expanded }
            if constraints.trailing.constant != retainedWidth { constraints.trailing.constant = retainedWidth }
        }
        let divider = width > 0 ? dividerThickness : 0
        subviews[0].isHidden = isSidebarCollapsed && !isAnimating && width == 0
        subviews[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        subviews[1].frame = NSRect(x: width + divider, y: 0,
            width: max(0, bounds.width - width - divider), height: bounds.height)
        onPresentationChanged?()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        finishAnimation()
        // AppKit retired the double-click-collapse delegate in macOS 10.15.
        // Hit testing already routes only the native divider here.
        if event.clickCount == 2, canCollapse?() == true { onToggleRequested?(); return }
        super.mouseDown(with: event)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === subviews.first && canCollapse?() == true
    }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        isSidebarCollapsed && !isAnimating
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(180, proposedMinimumPosition)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(maximumSidebarWidth, proposedMaximumPosition)
    }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard !isSidebarCollapsed else { return .zero }
        return proposedEffectiveRect.union(drawnRect.insetBy(dx: -3, dy: 0)).intersection(bounds)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !positioning, !isAnimating, subviews.count == 2 else { return }
        let collapsed = isSubviewCollapsed(subviews[0])
        if collapsed != isSidebarCollapsed {
            isSidebarCollapsed = collapsed
            onCollapsedChanged?()
        }
        if !collapsed {
            sidebarWidth = min(340, max(180, subviews[0].frame.width))
            sidebarPosition = min(sidebarWidth, maximumSidebarWidth)
        } else { sidebarPosition = 0 }
        onWidthChanged?()
    }
}
