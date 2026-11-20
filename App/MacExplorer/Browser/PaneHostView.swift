import AppKit
import ExplorerCore

/// A pane receives only authenticated app tab drags. File URL drags continue
/// through the existing file surfaces and never create panes.
@MainActor
final class PaneHostView: NSView {
    let paneID: UUID
    weak var workspace: BrowserWorkspaceController?
    var isActive = false { didSet { updateFocus() } }
    var isSplit = false { didSet { updateFocus() } }
    private let focusOutline = PaneFocusOutlineView()
    var showsFocusOutline: Bool { !focusOutline.isHidden }
    var focusForeground: NSView { focusOutline }
    var focusPreferences = PaneFocusPreferences() { didSet { focusOutline.preferences = focusPreferences } }
    private let snap = PaneSnapOutlineView()
    private(set) var proposedEdge: PaneDropEdge?
    private var snapRevision = UUID()
    private weak var snapSource: TabStripView?
    private var snapSequence: Int?
    private var motion: BrowserMotionPreferences { workspace?.primaryBrowser.settings.motion ?? .init() }

    init(paneID: UUID, content: NSView, workspace: BrowserWorkspaceController) {
        self.paneID = paneID
        self.workspace = workspace
        // Give the already-built browser its intended allocation before its
        // constraints can solve against this host during attachment.
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        // The pane reveal clips this stable backing layer, never the text or
        // live view's geometry. Input remains at its final native allocation.
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File browser pane")
        setAccessibilityIdentifier("pane-" + paneID.uuidString)
        setAccessibilityHelp("Contains independent tabs and folder navigation. Use Focus Next Pane in the View menu to change the active pane.")
        pin(content, inside: self, inset: 1)
        addSubview(focusOutline)
        focusOutline.isHidden = true
        addSubview(snap)
        snap.isHidden = true
        registerForDraggedTypes([TabStripView.tabDragPasteboardType])
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        focusOutline.frame = bounds
        if let proposedEdge { snap.frame = Self.snapFrame(for: proposedEdge, in: bounds) }
    }

    private func updateFocus() {
        focusOutline.isHidden = !(isSplit && isActive)
        focusOutline.needsDisplay = true
    }

    static func edge(at point: NSPoint, in bounds: NSRect) -> PaneDropEdge? {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return nil }
        let distances: [(PaneDropEdge, CGFloat)] = [
            (.leading, (point.x - bounds.minX) / bounds.width),
            (.trailing, (bounds.maxX - point.x) / bounds.width),
            (.top, (bounds.maxY - point.y) / bounds.height),
            (.bottom, (point.y - bounds.minY) / bounds.height)
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= 0.24 else { return nil }
        return nearest.0
    }

    static func snapFrame(for edge: PaneDropEdge, in bounds: NSRect) -> NSRect {
        var frame = bounds.insetBy(dx: 3, dy: 3)
        switch edge {
        case .leading: frame.size.width /= 2
        case .trailing: frame.size.width /= 2; frame.origin.x += frame.width
        case .top: frame.size.height /= 2; frame.origin.y += frame.height
        case .bottom: frame.size.height /= 2
        }
        return frame
    }

    func showRoutedSnap(_ edge: PaneDropEdge, source: TabStripView, sequence: Int) {
        snapSource = source; snapSequence = sequence
        if proposedEdge != edge {
            snapRevision = UUID()
            proposedEdge = edge
            let frame = Self.snapFrame(for: edge, in: bounds)
            let wasHidden = snap.isHidden
            snap.isHidden = false
            if wasHidden || !motion.allows(.panes) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window?.isVisible != true {
                snap.frame = frame
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13 * motion.mode.durationScale
                    snap.animator().frame = frame
                }
            }
            if !motion.allows(.panes) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window?.isVisible != true {
                snap.alphaValue = 1
            } else {
                if wasHidden { snap.alphaValue = 0 }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13 * motion.mode.durationScale
                    snap.animator().alphaValue = 1
                }
            }
            snap.needsDisplay = true
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        workspace?.routeTabDrag(sender, receiver: self, phase: .update) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        workspace?.routeTabDrag(sender, receiver: self, phase: .update) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { workspace?.exitTabDrag(sender, receiver: self) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(workspace?.routeTabDrag(sender, receiver: self, phase: .prepare) ?? []).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(workspace?.routeTabDrag(sender, receiver: self, phase: .perform) ?? []).isEmpty
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearSnap() }
    func clearSnap() {
        guard proposedEdge != nil else { return }
        proposedEdge = nil // Drop authority ends before the presentation fades.
        snapSource = nil; snapSequence = nil
        snapRevision = UUID()
        let revision = snapRevision
        guard motion.allows(.panes), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window?.isVisible == true else {
            snap.isHidden = true; snap.alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.13 * motion.mode.durationScale
            snap.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.snapRevision == revision, self.proposedEdge == nil else { return }
                self.snap.isHidden = true
            }
        })
    }

    func clearSnap(matching source: TabStripView, sequence: Int) {
        if snapSource === source && snapSequence == sequence { clearSnap() }
    }

    func revokeSnapUnlessOverlapping(from source: TabStripView, sequence: Int,
                                    pointer: NSPoint, footprint: NSRect?) {
        if snapSource === source && snapSequence == sequence {
            clearSnapUnlessOverlapping(pointer: pointer, footprint: footprint)
        }
    }

    /// Source movement also reaches unregistered areas, where AppKit may no
    /// longer send destination updates. It can revoke an old preview here but
    /// cannot grant a new destination or perform a drop.
    func clearSnapUnlessOverlapping(pointer screenPoint: NSPoint, footprint screenFrame: NSRect?) {
        guard let proposedEdge, let window else { return }
        let pointer = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let point: NSPoint?
        if bounds.contains(pointer) { point = pointer }
        else if let screenFrame {
            point = TabStripView.overlapPoint(pointer: pointer,
                footprint: convert(window.convertFromScreen(screenFrame), from: nil), region: bounds)
        } else { point = nil }
        if point.flatMap({ Self.edge(at: $0, in: bounds) }) != proposedEdge { clearSnap() }
    }
}

/// Draw above opaque rows, but never participate in mouse or drag routing.
@MainActor
private final class PaneFocusOutlineView: NSView {
    var preferences = PaneFocusPreferences() { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func accessibilityChanged() { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 1
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || preferences.style == .highContrast
        let width: CGFloat = highContrast ? 3 : CGFloat(preferences.thickness)
        // A centered stroke must be inset by half its width on every edge.
        let inset = ceil(width * scale / 2) / scale
        let shape = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        (highContrast ? NSColor.labelColor : preferences.color).setStroke()
        shape.lineWidth = width
        shape.stroke()
        if preferences.caption || highContrast {
            let font = InterfaceMetrics.font(10, weight: .semibold)
            let text = "Active pane" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            let badge = NSRect(x: max(4, bounds.maxX - size.width - 18), y: 5, width: size.width + 12, height: size.height + 6)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
        }
    }
}

@MainActor
private final class PaneSnapOutlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        shape.fill()
        NSColor.controlAccentColor.setStroke()
        shape.lineWidth = 3
        shape.stroke()
    }
}
