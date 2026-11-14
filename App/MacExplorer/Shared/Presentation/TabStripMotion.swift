import AppKit
import QuartzCore

@MainActor
private final class RetiredTabPicture: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// A bounded presentation lifetime, independent of tab identity and native drag
/// ownership. Additive layer offsets survive unrelated native layout passes.
@MainActor
final class TabStripMotion {
    private var layers: [(CALayer, CAShapeLayer?)] = []
    private var settlement: Task<Void, Never>?
    private var retiring: [UUID: (NSView, Task<Void, Never>)] = [:]
    var mode = BrowserMotionMode.full { didSet { if mode != oldValue { finish() } } }
    private var duration: Double { 0.30 * mode.durationScale }
    var isAnimating: Bool { !layers.isEmpty || !retiring.isEmpty }
    var retiringCount: Int { retiring.count }

    func visualFrame(of view: NSView) -> NSRect {
        guard let layer = view.layer, let visible = layer.presentation() else { return view.frame }
        return view.frame.offsetBy(dx: visible.position.x - layer.position.x, dy: visible.position.y - layer.position.y)
    }
    func beginLayout() { finishLive() }
    func place(_ view: NSView, from previous: NSRect, entering: Bool = false) {
        guard let layer = view.layer, view.frame.width > 1 else { return }
        let offset = entering ? CGPoint(x: 12 * mode.distanceScale, y: -2 * mode.distanceScale)
            : CGPoint(x: previous.minX - view.frame.minX, y: previous.minY - view.frame.minY)
        if !entering && abs(offset.x) < 0.1 && abs(offset.y) < 0.1 { return }
        let movement = CABasicAnimation(keyPath: "position"); movement.isAdditive = true
        movement.fromValue = NSValue(point: offset); movement.toValue = NSValue(point: .zero)
        movement.duration = duration; movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.68, 0.2, 1)
        layer.add(movement, forKey: "tabPosition")
        var ownedMask: CAShapeLayer?
        if entering {
            let alpha = CABasicAnimation(keyPath: "opacity"); alpha.fromValue = 0; alpha.toValue = 1
            alpha.duration = duration * 0.88; alpha.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(alpha, forKey: "tabOpacity")
            if mode == .full, layer.mask == nil {
                let mask = CAShapeLayer(); mask.frame = view.bounds; mask.fillColor = NSColor.black.cgColor
                let full = CGPath(rect: view.bounds, transform: nil)
                mask.path = full
                let reveal = CABasicAnimation(keyPath: "path")
                reveal.fromValue = CGPath(rect: NSRect(x: 0, y: 0, width: 4, height: view.bounds.height), transform: nil)
                reveal.toValue = full; reveal.duration = duration
                reveal.timingFunction = movement.timingFunction
                CATransaction.begin(); CATransaction.setDisableActions(true); layer.mask = mask; CATransaction.commit()
                mask.add(reveal, forKey: "tabReveal"); ownedMask = mask
            }
        }
        layers.append((layer, ownedMask))
    }
    func endLayout() {
        guard !layers.isEmpty else { return }
        settlement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds((self?.duration ?? 0) + 0.01)) } catch { return }
            self?.finishLive()
        }
    }
    func retire(_ item: NSView, in parent: NSView, visible: NSRect) {
        let frame = item.superview?.convert(visualFrame(of: item), to: parent) ?? item.convert(item.bounds, to: parent)
        guard !frame.intersection(visible).isEmpty, retiring.count < 8, item.bounds.width > 1,
              let rep = item.bitmapImageRepForCachingDisplay(in: item.bounds) else { return }
        item.cacheDisplay(in: item.bounds, to: rep)
        let image = NSImage(size: item.bounds.size); image.addRepresentation(rep)
        // Retain the old viewport for this short picture lifetime. Shrinking
        // the live scroll view must neither cut it off nor expose hidden tabs.
        let clip = RetiredTabPicture(frame: visible); clip.wantsLayer = true; clip.layer?.masksToBounds = true
        let ghost = RetiredTabPicture(frame: frame.offsetBy(dx: -visible.minX, dy: -visible.minY))
        ghost.image = image; ghost.imageScaling = .scaleNone; ghost.imageAlignment = .alignLeft
        ghost.wantsLayer = true; clip.addSubview(ghost); parent.addSubview(clip, positioned: .above, relativeTo: nil)
        let key = UUID()
        if let layer = ghost.layer {
            if mode == .full {
                let mask = CAShapeLayer(); mask.frame = ghost.bounds; mask.fillColor = NSColor.black.cgColor
                let end = NSRect(x: ghost.bounds.midX - 1, y: 0, width: 2, height: ghost.bounds.height)
                mask.path = CGPath(rect: end, transform: nil)
                let collapse = CABasicAnimation(keyPath: "path")
                collapse.fromValue = CGPath(rect: ghost.bounds, transform: nil); collapse.toValue = mask.path
                collapse.duration = duration * 0.88; collapse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.mask = mask; mask.add(collapse, forKey: "tabRetirement")
            }
            let alpha = CABasicAnimation(keyPath: "opacity"); alpha.fromValue = 1; alpha.toValue = 0
            alpha.duration = duration * 0.88; layer.opacity = 0; layer.add(alpha, forKey: "tabRetirementFade")
        }
        let task = Task { @MainActor [weak self, weak clip] in
            do { try await Task.sleep(for: .seconds((self?.duration ?? 0) * 0.88 + 0.02)) } catch { return }
            clip?.removeFromSuperview(); self?.retiring.removeValue(forKey: key)
        }
        retiring[key] = (clip, task)
    }
    private func finishLive() {
        settlement?.cancel(); settlement = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (layer, mask) in layers {
            layer.removeAnimation(forKey: "tabPosition"); layer.removeAnimation(forKey: "tabOpacity")
            if let mask, layer.mask === mask { mask.removeAllAnimations(); layer.mask = nil }
        }
        CATransaction.commit(); layers.removeAll()
    }
    func finish() {
        finishLive()
        for (view, task) in retiring.values { task.cancel(); view.removeFromSuperview() }
        retiring.removeAll()
    }
}
