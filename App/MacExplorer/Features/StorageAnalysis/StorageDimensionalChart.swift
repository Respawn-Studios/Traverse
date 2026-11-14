import AppKit
import QuartzCore
import SwiftUI

/// Shared native drawing surface. The caller owns loaded totals and navigation;
/// this module owns only finite geometry, pointer arbitration and presentation.
struct StorageDimensionalChart: NSViewRepresentable {
    let frames: [StorageChartFrame]
    var scopeIdentity: UUID? = nil
    var style = StorageChartStyle.tilted
    var interactive = true
    var reduceMotion = false
    var reduceTransparency = false
    var motionMode = BrowserMotionMode.full
    var onOpen: (Int) -> Void = { _ in }
    var onReturn: (Int) -> Void = { _ in }
    var onStyle: (StorageChartStyle) -> Void = { _ in }
    func makeNSView(context: Context) -> StorageDimensionalChartView {
        let view = StorageDimensionalChartView()
        #if DEBUG
        StorageDimensionalChartProbe.created(view)
        #endif
        return view
    }
    func updateNSView(_ view: StorageDimensionalChartView, context: Context) {
        view.onOpen = onOpen; view.onReturn = onReturn; view.onStyle = onStyle; view.interactive = interactive
        view.update(frames, style: style, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, scopeIdentity: scopeIdentity, motionMode: motionMode)
    }
    static func dismantleNSView(_ view: StorageDimensionalChartView, coordinator: ()) { view.stopPresentation() }
}

@MainActor
final class StorageDimensionalChartView: NSView {
    var onOpen: (Int) -> Void = { _ in }
    var onReturn: (Int) -> Void = { _ in }
    var onStyle: (StorageChartStyle) -> Void = { _ in }
    var interactive = true { didSet { if interactive != oldValue { refreshAccessibility() } } }
    private(set) var frames: [StorageChartFrame] = []
    private(set) var style = StorageChartStyle.tilted
    private(set) var camera = StorageChartCamera()
    private var reduceMotion = false, reduceTransparency = false
    private var motionMode = BrowserMotionMode.full
    private var transition: StorageChartTransition?
    private var link: CADisplayLink?
    private var settlement: Timer?
    private var settlementGeneration = UUID()
    private var screenSleepObservation: BrowserNotificationObservation?
    private var tracking: NSTrackingArea?
    private var hold: Timer?
    private var pointer: (point: CGPoint, hit: StorageChartHit?, camera: StorageChartCamera, dragged: Bool, held: Bool)?
    private var hover: StorageChartHit?, presentedHover: StorageChartHit?
    private var keyboardSelection: Int?
    private var accessibilityGeneration = UUID()
    private var scopeIdentity: UUID?
    private var segmentElements: [StorageChartAccessibilityElement] = []
    private var emphasis = 0.0, lastTick = 0.0
    private var hitScene = StorageChartScene(), hitSize = CGSize.zero
    private var gradients: [StorageChartTint: CGGradient] = [:]
    private struct WallPaint: Hashable { let tint: StorageChartTint; let shade: Double }
    private var wallGradients: [WallPaint: CGGradient] = [:]
    private var finishGradients: [String: CGGradient] = [:]
    enum Finish: String { case enamel, mineral, crystal }
    // Paint studies share exact geometry and interactions; enamel is the default.
    var finish = Finish.enamel { didSet { needsDisplay = true } }
    private(set) var ticks = 0, draws = 0
    private(set) var intervals: [Double] = [], drawTimes: [Double] = []
    var isAnimating: Bool { link != nil || settlement != nil }
    var isTransitioning: Bool { transition != nil }
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Storage breakdown")
        setAccessibilityHelp("Arrow keys inspect segments. Return or Space opens details; Escape returns one level. Tab moves to the other controls.")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic chart only") }

    func update(_ value: [StorageChartFrame], style: StorageChartStyle, reduceMotion: Bool, reduceTransparency: Bool,
                scopeIdentity: UUID? = nil, motionMode: BrowserMotionMode = .full) {
        let reduceMotion = reduceMotion || motionMode == .off
        guard value.count <= 17, value.allSatisfy(\.isValid) else { stopPresentation(); frames = []; hitScene = .init(); refreshAccessibility(); needsDisplay = true; return }
        let old = frames, sourceChanged = self.scopeIdentity != scopeIdentity
        let changed = old.map(\.id) != value.map(\.id) || sourceChanged, dataChanged = old != value || sourceChanged
        let appearanceChanged = self.style != style || self.reduceMotion != reduceMotion || self.reduceTransparency != reduceTransparency || self.motionMode != motionMode
        guard dataChanged || appearanceChanged else { return }
        cancelSettlement()
        if dataChanged { hold?.invalidate(); hold = nil; pointer = nil }
        self.scopeIdentity = scopeIdentity
        self.style = style; self.reduceMotion = reduceMotion; self.reduceTransparency = reduceTransparency
        self.motionMode = motionMode
        if changed, !old.isEmpty, !value.isEmpty, !reduceMotion, !appearanceChanged, hasVisiblePresentationWindow {
            let direction: StorageChartTransition.Direction?, selected: Int?
            if !sourceChanged, value.count == old.count + 1, Array(value.dropLast()).map(\.id) == old.map(\.id) {
                direction = .forward; selected = old.last?.slices.firstIndex { $0.id == value.last?.id }
            } else if !sourceChanged, value.count < old.count, Array(old.prefix(value.count)).map(\.id) == value.map(\.id) {
                direction = .back; selected = value.last?.slices.firstIndex { $0.id == old[value.count].id }
            } else { direction = nil; selected = nil }
            if let direction, let selected {
                transition = .init(direction: direction, from: old, to: value, selected: selected, start: CACurrentMediaTime(),
                                   duration: (direction == .forward ? 0.64 : 0.50) * motionMode.durationScale, initialHover: presentedHover)
            } else { transition = nil }
        } else if dataChanged || appearanceChanged || reduceMotion { transition = nil }
        let selectedID = keyboardSelection.flatMap { old.last?.slices.indices.contains($0) == true ? old.last?.slices[$0].id : nil }
        frames = value; hover = nil
        keyboardSelection = !changed ? selectedID.flatMap { id in value.last?.slices.firstIndex(where: { $0.id == id && ($0.bytes ?? 0) > 0 }) } : nil
        if transition == nil { presentedHover = nil; emphasis = 0 }
        hitSize = .zero; gradients.removeAll(keepingCapacity: true); wallGradients.removeAll(keepingCapacity: true)
        refreshAccessibility()
        if let keyboardSelection, transition == nil { setHover(.slice(keyboardSelection)) }
        needsDisplay = true; wakeIfNeeded()
    }
    private var geometry: StorageChartGeometry {
        .init(size: bounds.size, style: style, camera: camera, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
            motionScale: motionMode.distanceScale)
    }
    private func seatedHit(_ point: CGPoint) -> StorageChartHit? {
        seatedScene().hit(point)
    }
    private func seatedScene() -> StorageChartScene {
        if hitSize != bounds.size { hitScene = geometry.settled(frames); hitSize = bounds.size }
        return hitScene
    }
    private func setHover(_ value: StorageChartHit?) {
        guard value != hover else { return }
        #if DEBUG
        if value != nil && StorageDimensionalChartProbe.enabled { StorageDimensionalChartProbe.hoverCount += 1 }
        #endif
        hover = value
        cancelSettlement()
        if reduceMotion { presentedHover = value; emphasis = value == nil ? 0 : 1 }
        else if presentedHover == nil || emphasis <= 0.003 {
            presentedHover = value; emphasis = 0
        }
        // Keep one presented target: lower the outgoing pose before raising
        // the latest request. Retargeting never resets a visible slice's lift.
        switch value {
        case .slice(let index) where frames.last?.slices.indices.contains(index) == true:
            let slice = frames.last!.slices[index]; toolTip = slice.title + " · " + slice.amount
        case .ancestor(let index) where frames.indices.contains(index): toolTip = "Return to " + frames[index].title
        default: toolTip = nil
        }
        needsDisplay = true; wakeIfNeeded()
    }
    private func wakeIfNeeded() {
        guard transition != nil || presentedHover != hover || abs(emphasis - (hover == nil ? 0 : 1)) > 0.003 else { haltDriver(); cancelSettlement(); return }
        guard hasVisiblePresentationWindow else { stopPresentation(); return }
        scheduleSettlement()
        guard link == nil else { return }
        lastTick = 0
        let driver = displayLink(target: self, selector: #selector(step(_:)))
        driver.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        #if DEBUG
        driver.isPaused = displayClockPausedForQualification
        #endif
        link = driver; driver.add(to: .main, forMode: .common)
    }
    private var hasVisiblePresentationWindow: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        #if DEBUG
        if forceVisiblePresentationForQualification { return true }
        #endif
        return window.occlusionState.contains(.visible)
    }
    private func cancelSettlement() {
        settlement?.invalidate(); settlement = nil; settlementGeneration = UUID()
    }
    private func scheduleSettlement() {
        guard settlement == nil else { return }
        let generation = settlementGeneration
        let hoverPhases = presentedHover != nil && hover != nil && presentedHover != hover ? 2.0 : 1.0
        let remaining = transition.map { max(0, $0.start + $0.duration - CACurrentMediaTime()) + 0.12 }
            ?? (0.45 * hoverPhases * motionMode.durationScale)
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settlementGeneration == generation else { return }
                // A finite state deadline, not a second rendering clock. The
                // display may stop refreshing while the run loop still works.
                self.transition = nil; self.emphasis = self.hover == nil ? 0 : 1
                self.presentedHover = self.hover
                self.updateAccessibilityAvailability()
                self.haltDriver(); self.cancelSettlement(); self.needsDisplay = true
                #if DEBUG
                self.settlementCountForQualification += 1
                #endif
            }
        }
        settlement = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func haltDriver() { link?.invalidate(); link = nil; lastTick = 0 }
    func stopPresentation() {
        haltDriver(); cancelSettlement(); hold?.invalidate(); hold = nil; pointer = nil
        transition = nil; hover = nil; presentedHover = nil; emphasis = 0; keyboardSelection = nil
        for element in segmentElements { element.setAccessibilityFocused(false) }
        updateAccessibilityAvailability()
        needsDisplay = true
    }
    @objc private func step(_ driver: CADisplayLink) {
        guard hasVisiblePresentationWindow else { stopPresentation(); return }
        let now = CACurrentMediaTime(), delta = lastTick == 0 ? 1.0 / 60 : now - lastTick
        if lastTick != 0, intervals.count < 2048 { intervals.append(delta) }
        lastTick = now; ticks += 1
        if var active = transition {
            active.progress = min(1, (now - active.start) / active.duration)
            if active.progress >= 1 { transition = nil; presentedHover = nil; emphasis = 0; updateAccessibilityAvailability() }
            else { transition = active }
        } else {
            let target = presentedHover == hover && hover != nil ? 1.0 : 0.0
            emphasis += (target - emphasis) * min(1, delta / max(0.001, 0.065 * motionMode.durationScale))
            if abs(emphasis - target) <= 0.003 {
                emphasis = target
                if target == 0 { presentedHover = hover }
            }
        }
        needsDisplay = true; wakeIfNeeded()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window); NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window) }
        screenSleepObservation = nil
        if window !== newWindow { stopPresentation() }; super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            screenSleepObservation = BrowserNotificationObservation(center: NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.screensDidSleepNotification) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopPresentation() }
                }
        }
    }
    @objc private func windowClosing(_ notification: Notification) { stopPresentation() }
    @objc private func visibilityChanged(_ notification: Notification) { if !hasVisiblePresentationWindow { stopPresentation() } }
    override func viewDidHide() { stopPresentation(); super.viewDidHide() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { guard transition == nil else { return }; clearKeyboardSelection(); setHover(seatedHit(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { if pointer == nil && keyboardSelection == nil { setHover(nil) } }
    override func mouseDown(with event: NSEvent) {
        guard interactive, transition == nil else { return }
        clearKeyboardSelection()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pointer = (point, seatedHit(point), camera, false, false)
        hold?.invalidate()
        hold = Timer.scheduledTimer(withTimeInterval: 0.48, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var pointer = self.pointer, !pointer.dragged else { return }
                pointer.held = true; self.pointer = pointer; self.showStyles(at: pointer.point)
            }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard var pointer else { return }
        let point = convert(event.locationInWindow, from: nil), dx = point.x - pointer.point.x, dy = point.y - pointer.point.y
        if hypot(dx, dy) > 4 { pointer.dragged = true; hold?.invalidate(); hold = nil }
        self.pointer = pointer
        if pointer.dragged, style == .orbitable {
            camera = .init(pitch: pointer.camera.pitch + dy * 0.35, yaw: pointer.camera.yaw + dx * 0.45).bounded
            hitSize = .zero; needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) {
        hold?.invalidate(); hold = nil
        let old = pointer; pointer = nil
        guard transition == nil, let old, !old.dragged, !old.held, let hit = old.hit,
              seatedHit(convert(event.locationInWindow, from: nil)) == hit else { return }
        activate(hit)
    }
    private func activate(_ hit: StorageChartHit) {
        guard interactive, transition == nil else { return }
        switch hit {
        case .slice(let index):
            if frames.last?.slices.indices.contains(index) == true, frames.last!.slices[index].canOpen {
                #if DEBUG
                if StorageDimensionalChartProbe.enabled { StorageDimensionalChartProbe.clickCount += 1 }
                #endif
                onOpen(index)
            }
        case .ancestor(let index): if index < frames.count - 1 { onReturn(index) }
        }
    }
    override func rightMouseDown(with event: NSEvent) { showStyles(at: convert(event.locationInWindow, from: nil)) }
    private func showStyles(at point: CGPoint) {
        guard transition == nil else { return }
        hold?.invalidate(); hold = nil; pointer = nil
        let menu = NSMenu(title: "Chart style")
        for (index, style) in StorageChartStyle.allCases.enumerated() {
            let item = NSMenuItem(title: style.title, action: #selector(choseStyle(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.state = style == self.style ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }
    @objc private func choseStyle(_ sender: NSMenuItem) { guard StorageChartStyle.allCases.indices.contains(sender.tag) else { return }; onStyle(StorageChartStyle.allCases[sender.tag]) }
    override func cancelOperation(_ sender: Any?) { if interactive, frames.count > 1, transition == nil { onReturn(frames.count - 2) } }

    private func clearKeyboardSelection() {
        guard keyboardSelection != nil else { return }
        keyboardSelection = nil
        for element in segmentElements { element.setAccessibilityFocused(false) }
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool {
        clearKeyboardSelection(); setHover(nil)
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        let reserved = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard reserved.isEmpty, window?.firstResponder === self, !isHiddenOrHasHiddenAncestor,
              window?.isVisible == true else { super.keyDown(with: event); return }
        guard transition == nil else { return }
        let visible = StorageRingLayout(bytes: frames.last?.slices.map(\.bytes) ?? []).segments.map(\.index)
        switch event.keyCode {
        case 123, 124, 125, 126, 115, 119:
            guard !visible.isEmpty else { return }
            let previous = keyboardSelection.flatMap { visible.firstIndex(of: $0) }
            let index: Int
            switch event.keyCode {
            case 115: index = 0
            case 119: index = visible.count - 1
            case 123, 126: index = previous.map { ($0 + visible.count - 1) % visible.count } ?? visible.count - 1
            default: index = previous.map { ($0 + 1) % visible.count } ?? 0
            }
            keyboardSelection = visible[index]; setHover(.slice(visible[index]))
            for element in segmentElements { element.setAccessibilityFocused(element.index == keyboardSelection) }
            if let element = segmentElements.first(where: { $0.index == keyboardSelection }) {
                NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
            }
        case 36, 76, 49:
            if let keyboardSelection { activate(.slice(keyboardSelection)) }
        case 53: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }
    private func refreshAccessibility() {
        accessibilityGeneration = UUID(); segmentElements = []
        if let current = frames.last {
            for segment in StorageRingLayout(bytes: current.slices.map(\.bytes)).segments {
                let slice = current.slices[segment.index]
                let element = StorageChartAccessibilityElement(owner: self, generation: accessibilityGeneration,
                    sliceID: slice.id, index: segment.index)
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(interactive && slice.canOpen ? .button : .staticText)
                element.setAccessibilityLabel(slice.title)
                element.setAccessibilityValue(slice.amount + String(format: " · %.1f%% of observed bytes", segment.fraction * 100))
                element.setAccessibilityHelp(interactive && slice.canOpen ? "Open this segment's breakdown." : "Observed values; no deeper breakdown is available.")
                segmentElements.append(element)
            }
        }
        setAccessibilityChildren(segmentElements)
        updateAccessibilityAvailability()
        setAccessibilityLabel("Storage breakdown · " + (frames.last?.title ?? "No segments"))
        setAccessibilityValue("\(segmentElements.count) visible segments")
        setAccessibilityCustomActions(frames.count > 1 && interactive
            ? [NSAccessibilityCustomAction(name: "Go back one level", target: self, selector: #selector(accessibleBack(_:)))] : [])
    }
    private func updateAccessibilityAvailability() {
        for element in segmentElements {
            element.setAccessibilityEnabled(element.accessibilityRole() != .button || (interactive && transition == nil))
        }
    }
    func segmentAccessibilityFrame(generation: UUID, sliceID: String, index: Int) -> NSRect {
        guard generation == accessibilityGeneration, let current = frames.last, current.slices.indices.contains(index),
              current.slices[index].id == sliceID, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return .zero }
        let rect = seatedScene().faces.filter { $0.hit == .slice(index) }.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !rect.isNull, !rect.isEmpty else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
    func pressAccessibilitySegment(generation: UUID, sliceID: String, index: Int) -> Bool {
        guard generation == accessibilityGeneration, transition == nil, interactive, window?.isVisible == true,
              !isHiddenOrHasHiddenAncestor, let current = frames.last, current.slices.indices.contains(index),
              current.slices[index].id == sliceID, (current.slices[index].bytes ?? 0) > 0, current.slices[index].canOpen else { return false }
        activate(.slice(index)); return true
    }
    @objc private func accessibleBack(_ action: NSAccessibilityCustomAction) -> Bool {
        guard interactive, transition == nil, window?.isVisible == true, !isHiddenOrHasHiddenAncestor, frames.count > 1 else { return false }
        onReturn(frames.count - 2); return true
    }

    private func gradient(_ tint: StorageChartTint) -> CGGradient {
        if let existing = gradients[tint] { return existing }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ factor: Double) -> CGColor { .init(red: min(1, tint.red * factor), green: min(1, tint.green * factor), blue: min(1, tint.blue * factor), alpha: 1) }
        let result = CGGradient(colorsSpace: space, colors: [color(1.04), color(0.94), color(0.79)] as CFArray, locations: [0, 0.48, 1])!
        if gradients.count < 128 { gradients[tint] = result }
        return result
    }
    private func wallGradient(_ face: StorageChartFace) -> CGGradient {
        let key = WallPaint(tint: face.tint, shade: face.shade)
        if let value = wallGradients[key] { return value }
        func color(_ factor: Double) -> CGColor {
            .init(red: face.tint.red * factor, green: face.tint.green * factor, blue: face.tint.blue * factor, alpha: 1)
        }
        let value = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color(min(0.92, face.shade * 1.20)), color(face.shade * 0.77)] as CFArray, locations: [0, 1])!
        if wallGradients.count < 128 { wallGradients[key] = value }
        return value
    }
    private func opticalGradient(rim: Bool, contrast: Bool) -> CGGradient {
        let key = finish.rawValue + (rim ? "rim" : "gloss") + (contrast ? "contrast" : "normal")
        if let value = finishGradients[key] { return value }
        let strength: CGFloat = finish == .mineral ? 0.04 : finish == .crystal ? 0.30 : 0.17
        let colors = rim ? [
            NSColor.white.withAlphaComponent(contrast ? 0.75 : finish == .crystal ? 0.82 : finish == .mineral ? 0.28 : 0.58).cgColor,
            NSColor.white.withAlphaComponent(0.05).cgColor,
            NSColor.black.withAlphaComponent(contrast ? 0.32 : 0.16).cgColor] : [
            NSColor.white.withAlphaComponent(strength).cgColor,
            NSColor.white.withAlphaComponent(0.015).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor]
        let value = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
            locations: [0, rim ? 0.54 : 0.47, 1])!
        finishGradients[key] = value // At most 12 fixed, non-data cache entries.
        return value
    }
    private var reflectedBand: CGGradient {
        let key = finish.rawValue + "band"
        if let value = finishGradients[key] { return value }
        let peak: CGFloat = finish == .mineral ? 0.02 : finish == .crystal ? 0.28 : 0.20
        let value = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.white.withAlphaComponent(peak).cgColor, NSColor.white.withAlphaComponent(0.03).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.29, 0.36, 0.40, 0.47])!
        finishGradients[key] = value // Three additional fixed finish entries.
        return value
    }
    private func finishTop(_ face: StorageChartFace, in context: CGContext) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        guard style != .flat else { return }
        context.saveGState(); context.setAlpha(face.alpha)
        context.addPath(face.path); context.clip()
        if !reduceTransparency && !contrast {
            // One screen-space reflection, rather than a white stripe repeated
            // independently on every data mark. No idle shimmer/display timer.
            context.saveGState(); context.scaleBy(x: 1, y: 0.55)
            let light = CGPoint(x: bounds.width * 0.28, y: bounds.height * 0.29)
            context.drawRadialGradient(opticalGradient(rim: false, contrast: false),
                startCenter: light, startRadius: 0, endCenter: light,
                endRadius: max(bounds.width, bounds.height) * 0.72, options: [.drawsAfterEndLocation])
            context.restoreGState()
            context.drawLinearGradient(reflectedBand, start: .init(x: bounds.width * 0.15, y: bounds.height * 0.05),
                end: .init(x: bounds.width * 0.85, y: bounds.height * 0.78), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // A directional bevel stays inside the true top. It neither enlarges
        // hit regions nor draws tessellation edges across the sidewall.
        context.addPath(face.path); context.setLineWidth(finish == .crystal ? 2.4 : finish == .mineral ? 1.1 : 1.8)
        context.replacePathWithStrokedPath(); context.clip()
        context.drawLinearGradient(opticalGradient(rim: true, contrast: contrast),
            start: .init(x: bounds.width * 0.14, y: bounds.height * 0.12),
            end: .init(x: bounds.width * 0.8, y: bounds.height * 0.8), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    private func paint(_ scene: StorageChartScene, context: CGContext) {
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        // Composite a continuous sidewall once. Blending each tessellated
        // polygon separately exposes shared antialiased edges as dark stripes.
        // Overlap only internal same-slice tessellation seams. Expanding a
        // complete polygon also paints beyond logical slice boundaries and
        // can cover a compact neighboring slice or its intended gap.
        var sideOpacity: Double?
        func endSides() {
            guard sideOpacity != nil else { return }
            context.endTransparencyLayer(); context.restoreGState(); sideOpacity = nil
        }
        for face in scene.faces {
            if face.surface == .top { endSides() }
            else if sideOpacity != face.alpha {
                endSides(); context.saveGState()
                context.setAlpha(face.alpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setAlpha(1); sideOpacity = face.alpha
            }
            // An empty CGPath adds no current path; clipping it does not
            // suppress drawing. Honor fully hidden coverage explicitly.
            if face.visibleCoverage?.isEmpty == true { continue }
            // Clip ORIGINAL painting once, including its original finish and
            // boundary strokes. Never paint/stroke a visibility fragment.
            context.saveGState()
            if let coverage = face.visibleCoverage { context.addPath(coverage); context.clip() }
            if face.surface == .top {
                context.saveGState(); context.setAlpha(face.alpha)
                context.addPath(face.path); context.clip()
                context.drawLinearGradient(gradient(face.tint), start: .init(x: 0, y: bounds.height * 0.1), end: .init(x: bounds.width, y: bounds.height * 0.8), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
                finishTop(face, in: context)
            } else {
                var coverages = [face.path]
                if let seam = face.internalSideSeams {
                    coverages.append(seam.copy(strokingWithWidth: 1 / max(1, abs(context.ctm.a)),
                        lineCap: .butt, lineJoin: .round, miterLimit: 2))
                }
                // Separate clips preserve their winding. Combining a quad and
                // its oppositely wound stroked outline can punch edge holes.
                for coverage in coverages {
                    context.saveGState(); context.addPath(coverage); context.clip()
                    context.drawLinearGradient(wallGradient(face), start: .init(x: 0, y: bounds.height * 0.37),
                        end: .init(x: 0, y: bounds.height * 0.83), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.restoreGState()
                }
            }
            if face.surface == .top {
                context.saveGState(); context.setAlpha(face.alpha)
                context.setStrokeColor(NSColor.labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.14).cgColor); context.setLineWidth(0.55)
                context.addPath(face.path); context.strokePath(); context.restoreGState()
            }
            context.restoreGState()
        }
        endSides()
    }
    override func draw(_ dirtyRect: NSRect) {
        let began = CACurrentMediaTime()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scene = transition.map { geometry.transition($0) } ?? geometry.settled(frames, hover: presentedHover, emphasis: emphasis)
        paint(scene, context: context)
        if transition == nil, let keyboardSelection, window?.firstResponder === self {
            context.saveGState(); context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); context.setLineWidth(2.5)
            // Focus can reach the next slice while the outgoing slice lowers.
            // Its outline follows the same coverage as the still-seated fill.
            for face in scene.faces where face.hit == .slice(keyboardSelection) && face.surface == .top {
                if face.visibleCoverage?.isEmpty == true { continue }
                context.saveGState()
                if let coverage = face.visibleCoverage { context.addPath(coverage); context.clip() }
                context.addPath(face.path); context.strokePath(); context.restoreGState()
            }
            context.restoreGState()
        }
        if transition == nil, case .slice(let index) = presentedHover, let current = frames.last, current.slices.indices.contains(index) {
            let slice = current.slices[index]
            let fraction = StorageRingLayout(bytes: current.slices.map(\.bytes)).segments.first { $0.index == index }?.fraction ?? 0
            let text = String(format: "%.1f%%", fraction * 100) + "\n" + slice.title + "\n" + slice.amount
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: InterfaceMetrics.font(bounds.width < 300 ? 9 : 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            let width = min(bounds.width * 0.38, 150), height = 46.0
            (text as NSString).draw(in: .init(x: bounds.midX - width / 2, y: bounds.height * 0.37 - height / 2, width: width, height: height), withAttributes: attributes)
        }
        draws += 1; if drawTimes.count < 2048 { drawTimes.append(CACurrentMediaTime() - began) }
        wakeIfNeeded()
    }
    #if DEBUG
    var forceVisiblePresentationForQualification = false
    private var displayClockPausedForQualification = false
    private(set) var settlementCountForQualification = 0
    var presentedHoverForQualification: StorageChartHit? { presentedHover }
    var hoverEmphasisForQualification: Double { emphasis }
    var keyboardSelectionForQualification: Int? { keyboardSelection }
    func pauseDisplayClockForQualification() { displayClockPausedForQualification = true; link?.isPaused = true }
    func rasterForQualification(_ scene: StorageChartScene) -> [UInt8] {
        let width = max(1, Int(bounds.width)), height = max(1, Int(bounds.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { paint(scene, context: context) }
        }
        return bytes
    }
    func hoverForQualification(_ hit: StorageChartHit?) { setHover(hit) }
    func hitForQualification(_ point: CGPoint) -> StorageChartHit? { seatedHit(point) }
    func activateForQualification(_ hit: StorageChartHit) { activate(hit) }
    func sceneForQualification() -> StorageChartScene { geometry.settled(frames) }
    #endif
}
