import AppKit
import ExplorerCore

/// One selection owner for the leading gutter and empty table body. Native row
/// file dragging stays with the table; the overlay never participates in hit testing.
@MainActor final class TableMarqueeSelection: NSObject {
    private weak var table: NSTableView?, scroll: NSScrollView?, parent: NSView?
    private let revision: () -> UInt64
    private let pointerBehavior: () -> BrowserBehaviorPreferences
    private let eligibleRows: (IndexSet) -> IndexSet
    private let margin = TableSelectionMargin(), overlay = TableSelectionOverlay()
    private var observations: [BrowserNotificationObservation] = []
    private var timer: Timer?, lastEvent: NSEvent?
    private var pointerInWindow: NSPoint?
    private var origin: NSPoint?, initial = IndexSet(), modifiers: NSEvent.ModifierFlags = []
    private var admittedRevision: UInt64 = 0
    private(set) var active = false
    private var armed = false
    #if DEBUG
    private(set) var gestureBegins = 0, liveSelectionChanges = 0
    private(set) var nonEmptyBandUpdates = 0
    private(set) var lastBandSize = NSSize.zero
    #endif
    var onBegin: (() -> Void)?

    convenience init(table: FileTableView, scroll: NSScrollView, parent: NSView) {
        self.init(table: table, scroll: scroll, parent: parent,
                  revision: { [weak table] in table?.marqueeRevision ?? 0 },
                  pointerBehavior: { [weak table] in table?.behavior ?? .mac })
    }
    init(table: NSTableView, scroll: NSScrollView, parent: NSView,
         revision: @escaping () -> UInt64, pointerBehavior: @escaping () -> BrowserBehaviorPreferences = { .mac },
         eligibleRows: @escaping (IndexSet) -> IndexSet = { $0 }) {
        self.revision = revision; self.pointerBehavior = pointerBehavior; self.eligibleRows = eligibleRows
        self.table = table; self.scroll = scroll; self.parent = parent
        super.init()
        margin.owner = self; margin.toolTip = "Drag here to select rows. Shift adds; Command toggles."
        margin.setAccessibilityElement(false); overlay.setAccessibilityElement(false)
        parent.addSubview(margin); parent.addSubview(overlay)
        layout(); bindWindow()
    }
    isolated deinit { timer?.invalidate() }

    static func selection(base: IndexSet, intersected: IndexSet, modifiers: NSEvent.ModifierFlags) -> IndexSet {
        if modifiers.contains(.shift) { return base.union(intersected) }
        if modifiers.contains(.command) { return base.symmetricDifference(intersected) }
        return intersected
    }
    static func band(origin: NSPoint, current: NSPoint, clip: NSRect, minimumWidth: CGFloat) -> NSRect? {
        guard [origin.x,origin.y,current.x,current.y,clip.minX,clip.minY,clip.width,clip.height,minimumWidth].allSatisfy(\.isFinite),
              clip.width > 0, clip.height > 0, minimumWidth > 0 else { return nil }
        // A gutter origin clamps to the body; an empty-body origin keeps its
        // actual horizontal position in either direction. Vertical drags still
        // have a small visible width, rather than intersecting to null.
        let startX = min(clip.maxX,max(clip.minX,origin.x)), endX = min(clip.maxX,max(clip.minX,current.x))
        let width = min(clip.width,max(minimumWidth,abs(endX-startX)))
        let left = min(clip.maxX-width,max(clip.minX,min(startX,endX)))
        let rect = NSRect(x:left,y:min(origin.y,current.y),width:width,height:max(1,abs(origin.y-current.y))).intersection(clip)
        return rect.isNull || rect.isEmpty ? nil : rect
    }
    func layout() {
        let hint = pointerBehavior().controlClickTogglesSelection
            ? "Drag here to select rows. Shift adds; Control or Command toggles."
            : "Drag here to select rows. Shift adds; Command toggles."
        if margin.toolTip != hint { margin.toolTip = hint }
        guard let parent, let scroll else { return }
        let body = scroll.contentView.convert(scroll.contentView.bounds, to: parent)
        let width = max(0, scroll.frame.minX - parent.bounds.minX)
        margin.frame = NSRect(x: parent.bounds.minX, y: body.minY, width: width, height: body.height)
        overlay.frame = parent.bounds
        if active { update() }
    }
    func setVisible(_ visible: Bool) {
        if !visible { cancel(restore: false) }
        margin.isHidden = !visible; overlay.isHidden = !visible
    }
    func bindWindow() {
        observations.removeAll()
        guard let window = margin.window else { cancel(restore: false); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observations.append(BrowserNotificationObservation(name: name, object: window) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(restore: true) }
            })
        }
    }
    private var current: Bool {
        guard let table, let scroll else { return false }
        return !scroll.isHiddenOrHasHiddenAncestor && !margin.isHiddenOrHasHiddenAncestor
            && table.window === margin.window && margin.window != nil && revision() == admittedRevision
    }
    /// Thin native responder adapters call this before a table's private mouse
    /// tracker. Only empty space and the gutter are consumed; real rows remain
    /// native file-drag/click inputs.
    func begin(with event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, let table, event.window === table.window,
              !margin.isHiddenOrHasHiddenAncestor, table.currentEditor() == nil else { return false }
        let initialModifiers = BrowserPointerSelection.modifiers(event.modifierFlags, behavior: pointerBehavior())
        // Mac Control-primary remains a context request; do not arm the empty
        // body/gutter marquee before AppKit sees it.
        guard !initialModifiers.contains(.control) else { return false }
        finish(restore:false)
        let point = table.convert(event.locationInWindow,from:nil)
        let gutter = margin.bounds.contains(margin.convert(event.locationInWindow,from:nil))
        let clip = scroll?.contentView
        let body = clip.map { $0.bounds.contains($0.convert(event.locationInWindow,from:nil)) } ?? false
        guard gutter || (body && table.row(at:point) < 0) else { return false }
        origin = point; initial = table.selectedRowIndexes; armed = true
        modifiers = initialModifiers.intersection(.deviceIndependentFlagsMask); admittedRevision = revision()
        lastEvent = event; pointerInWindow = event.locationInWindow
        onBegin?()
        guard current else { finish(restore:false); return false }
        margin.window?.makeFirstResponder(margin)
        return current
    }
    func drag(with event: NSEvent) {
        guard armed, current, let origin, let table, event.window === table.window else { cancel(restore:false); return }
        let point = table.convert(event.locationInWindow,from:nil)
        if !active {
            guard hypot(point.x-origin.x,point.y-origin.y) >= 3 else { return }
            guard current else { cancel(restore:false); return }
            active = true
            #if DEBUG
            gestureBegins += 1
            #endif
            startAutoscroll()
        }
        capture(event); update()
    }
    func end(with event: NSEvent) {
        guard armed else { return }
        if active { capture(event); update() }
        else if current, !modifiers.contains(.shift), !modifiers.contains(.command), table?.allowsEmptySelection == true { table?.deselectAll(nil) }
        finish(restore:false)
    }
    private func capture(_ event: NSEvent) {
        guard event.window === table?.window else { return }
        pointerInWindow = event.locationInWindow; lastEvent = event
        modifiers = BrowserPointerSelection.modifiers(event.modifierFlags, behavior: pointerBehavior()).intersection(.deviceIndependentFlagsMask)
    }
    private func startAutoscroll() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.active, self.current, let event = self.lastEvent, let table = self.table else { self.cancel(restore: false); return }
                if table.autoscroll(with: event) { self.update() }
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func update() {
        guard active, current, let origin, let pointerInWindow, let table, let scroll else { return }
        let point = table.convert(pointerInWindow, from: nil)
        let low = min(origin.y, point.y), high = max(origin.y, point.y)
        let rows = table.rows(in: NSRect(x: 0, y: low, width: max(1, table.bounds.width), height: max(1, high - low)))
        let matches: IndexSet = rows.location == NSNotFound || rows.length == 0 || rows.location >= table.numberOfRows ? []
            : IndexSet(integersIn: rows.location..<min(table.numberOfRows, rows.location + rows.length))
        let selected = eligibleRows(Self.selection(base: initial, intersected: matches, modifiers: modifiers))
        if selected != table.selectedRowIndexes {
            #if DEBUG
            liveSelectionChanges += 1
            #endif
            table.selectRowIndexes(selected, byExtendingSelection: false)
        }
        guard active, current else { return } // Selection callbacks can replace the listing.
        let a = table.convert(origin, to: overlay), b = table.convert(point, to: overlay)
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: overlay)
        overlay.rectangle = Self.band(origin:a,current:b,clip:clip,minimumWidth:max(12,margin.bounds.width))
        #if DEBUG
        if let rectangle = overlay.rectangle { nonEmptyBandUpdates += 1; lastBandSize = rectangle.size }
        #endif
    }
    func cancel(restore: Bool) {
        finish(restore: restore)
    }
    private func finish(restore: Bool) {
        let restoreRows = restore && active && current
        active = false; armed = false; timer?.invalidate(); timer = nil
        overlay.rectangle = nil
        if restoreRows, let table { table.selectRowIndexes(initial, byExtendingSelection: false) }
        origin = nil; initial = []; lastEvent = nil; pointerInWindow = nil
        if margin.window?.firstResponder === margin { margin.window?.makeFirstResponder(table) }
    }
    #if DEBUG
    var verificationState: (active: Bool, timer: Bool, rectangle: NSRect?, margin: NSView, draws: Int) { (active,timer != nil,overlay.rectangle,margin,overlay.visibleDraws) }
    var verificationGeometry: [String: Any] {
        var value: [String: Any] = [:]
        let window = overlay.window
        value["active"] = active
        value["draws"] = overlay.visibleDraws
        value["overlayAttached"] = window != nil
        value["sameWindow"] = window === table?.window
        value["windowVisible"] = window?.isVisible == true
        value["windowOcclusionVisible"] = window?.occlusionState.contains(NSWindow.OcclusionState.visible) == true
        value["overlayHidden"] = overlay.isHiddenOrHasHiddenAncestor
        value["overlayFrame"] = NSStringFromRect(overlay.frame)
        value["overlayBounds"] = NSStringFromRect(overlay.bounds)
        value["overlayVisibleRect"] = NSStringFromRect(overlay.visibleRect)
        value["parentBounds"] = parent.map { NSStringFromRect($0.bounds) } ?? "unattached"
        value["marginFrame"] = NSStringFromRect(margin.frame)
        value["scrollClipBounds"] = scroll.map { NSStringFromRect($0.contentView.bounds) } ?? "unattached"
        value["band"] = overlay.rectangle.map { NSStringFromRect($0) } ?? "absent"
        return value
    }
    static func rasterForVerification() throws -> (Data,Bool,[String:Double]) {
        enum RasterFailure: Error { case unavailable }
        let sample = TableSelectionOverlay(frame:.init(x:0,y:0,width:80,height:80))
        sample.appearance = NSAppearance(named:.darkAqua)
        sample.rectangle = .init(x:10,y:10,width:40,height:40)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80,pixelsHigh:80,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:rep) else { throw RasterFailure.unavailable }
        sample.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); sample.bounds.fill(); sample.draw(sample.bounds); NSGraphicsContext.restoreGraphicsState()
        }
        // Bitmap rows and AppKit drawing use opposite vertical origins. The
        // middle row lies inside this band in either coordinate convention.
        guard let a = rep.colorAt(x:2,y:2)?.usingColorSpace(.deviceRGB), let b = rep.colorAt(x:20,y:40)?.usingColorSpace(.deviceRGB),
              let edge = rep.colorAt(x:10,y:40)?.usingColorSpace(.deviceRGB),
              let data = rep.representation(using:.png,properties:[:]) else { throw RasterFailure.unavailable }
        func difference(_ color: NSColor) -> Double { Double(max(abs(a.redComponent-color.redComponent),max(abs(a.greenComponent-color.greenComponent),abs(a.blueComponent-color.blueComponent)))) }
        let fill = difference(b), stroke = difference(edge)
        return (data,max(fill,stroke) > 0.02 && sample.hitTest(.init(x:20,y:20)) == nil,["fillContrast":fill,"strokeContrast":stroke])
    }
    #endif
}

@MainActor private final class TableSelectionMargin: NSView {
    weak var owner: TableMarqueeSelection?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.bindWindow() }
    override func mouseDown(with event: NSEvent) { if owner?.begin(with:event) != true { super.mouseDown(with:event) } }
    override func mouseDragged(with event: NSEvent) { owner?.drag(with:event) }
    override func mouseUp(with event: NSEvent) { owner?.end(with:event) }
    override func cancelOperation(_ sender: Any?) { owner?.cancel(restore: true) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.cancel(restore: true) } else { super.keyDown(with: event) }
    }
}
@MainActor private final class TableSelectionOverlay: NSView {
    var rectangle: NSRect? { didSet { needsDisplay = true } }
    #if DEBUG
    private(set) var visibleDraws = 0
    #endif
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let rectangle, !rectangle.isNull, !rectangle.isEmpty else { return }
        #if DEBUG
        visibleDraws += 1
        #endif
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill(); rectangle.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1; outline.stroke()
    }
}
