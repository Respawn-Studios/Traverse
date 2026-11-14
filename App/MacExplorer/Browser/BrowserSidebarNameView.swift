import AppKit

/// The existing name/cell is the drag surface. A short click keeps its normal
/// navigation/disclosure behavior; holding or dragging lifts the same row.
@MainActor
final class BrowserSidebarNameView: NSView {
    let content: NSView
    private weak var node: SidebarNode?
    private weak var coordinator: BrowserSidebarLayoutDragCoordinator?
    private weak var outline: BrowserSidebarOutlineView?
    private var press: NSEvent?
    private var hold: Timer?
    private var started = false

    init(content: NSView, node: SidebarNode, outline: BrowserSidebarOutlineView,
         coordinator: BrowserSidebarLayoutDragCoordinator) {
        self.content = content; self.node = node
        self.outline = outline; self.coordinator = coordinator
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        var constraints = [content.leadingAnchor.constraint(equalTo: leadingAnchor),
                           content.trailingAnchor.constraint(equalTo: trailingAnchor)]
        if content is NSTextField {
            // A stretched label draws its baseline near the top while the
            // native disclosure is centered in the taller section row.
            constraints.append(content.centerYAnchor.constraint(equalTo: centerYAnchor))
        } else {
            constraints += [content.topAnchor.constraint(equalTo: topAnchor),
                            content.bottomAnchor.constraint(equalTo: bottomAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(false)
        toolTip = "Hold the name and drag to reorder. Control-click for Move Up and Move Down."
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let candidate = ancestor, candidate !== self {
            if candidate is NSButton { return hit } // disclosure and Eject stay independent
            ancestor = candidate.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        cancelPress()
        guard let outline, let node, outline.row(forItem: node) >= 0 else { return }
        press = event; started = false
        window?.makeFirstResponder(outline)
        let timer = Timer(timeInterval: 0.30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let event = self.press,
                      NSEvent.pressedMouseButtons & 1 != 0 else { return }
                self.beginDrag(event)
            }
        }
        hold = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, !started else { return }
        let a = press.locationInWindow, b = event.locationInWindow
        if hypot(a.x - b.x, a.y - b.y) >= 4 { beginDrag(event) }
    }
    private func beginDrag(_ event: NSEvent) {
        guard !started, press != nil, let node, let outline, let coordinator else { return }
        hold?.invalidate(); hold = nil
        started = coordinator.beginNameDrag(node: node, outline: outline, event: event)
    }
    override func mouseUp(with event: NSEvent) {
        let clicked = press != nil && !started
        cancelPress()
        guard clicked, let node, let outline,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        outline.performNameClick(node, clickCount: event.clickCount)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPress() }
    }
    private func cancelPress() {
        hold?.invalidate(); hold = nil; press = nil; started = false
    }
}
