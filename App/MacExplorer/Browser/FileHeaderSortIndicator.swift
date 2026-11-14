import AppKit
import QuartzCore

/// A compact symmetric chevron. A hover appears immediately, with a short
/// entrance; exit and sort ownership never wait. Native input stays intact.
@MainActor
final class FileHeaderSortIndicator {
    let containerLayer = CALayer()
    let glyphLayer = CAShapeLayer()
    private var ascending: Bool?
    private var opacity: Float = 0

    init() {
        containerLayer.isGeometryFlipped = true
        containerLayer.isOpaque = false
        glyphLayer.isOpaque = false
        containerLayer.addSublayer(glyphLayer)
        glyphLayer.fillColor = nil; glyphLayer.lineWidth = 1.25
        glyphLayer.lineCap = .round; glyphLayer.lineJoin = .round
    }
    func install(in layer: CALayer) {
        guard containerLayer.superlayer !== layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        containerLayer.removeFromSuperlayer()
        layer.addSublayer(containerLayer)
        CATransaction.commit()
    }
    func remove() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        containerLayer.removeFromSuperlayer()
        glyphLayer.removeAllAnimations()
        CATransaction.commit()
    }
    func apply(strokeColor: CGColor, contentsScale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        containerLayer.contentsScale = contentsScale
        glyphLayer.contentsScale = contentsScale
        glyphLayer.strokeColor = strokeColor
        CATransaction.commit()
    }
    // The header converts its slot to backing-layer coordinates. This owned
    // container preserves the old ornament's flipped, 16-point local space.
    func place(in glyph: NSRect) {
        if containerLayer.frame != glyph {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            containerLayer.frame = glyph
            let bounds = containerLayer.bounds
            glyphLayer.bounds = bounds
            glyphLayer.position = NSPoint(x: bounds.midX, y: bounds.midY)
            let path = CGMutablePath()
            path.move(to: .init(x: bounds.midX - 3.5, y: bounds.midY + 1.75))
            path.addLine(to: .init(x: bounds.midX, y: bounds.midY - 1.75))
            path.addLine(to: .init(x: bounds.midX + 3.5, y: bounds.midY + 1.75))
            glyphLayer.path = path
            CATransaction.commit()
        }
    }
    func present(ascending: Bool, opacity: Float, motion: Bool, mode: BrowserMotionMode = .full) {
        // The centered child stays in its allocated slot throughout a half turn.
        let layer = glyphLayer
        let oldDirection = self.ascending, oldOpacity = self.opacity
        self.ascending = ascending; self.opacity = opacity
        let angle = ascending ? 0.0 : Double.pi
        let current = layer.presentation() ?? layer
        let fromAngle = atan2(Double(current.transform.m12), Double(current.transform.m11))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1); layer.opacity = opacity
        CATransaction.commit()
        guard motion, mode != .off, oldDirection != nil else { layer.removeAllAnimations(); return }
        if opacity == 0.55, oldOpacity == 0 {
            let entrance = CABasicAnimation(keyPath:"opacity")
            entrance.fromValue = Float(0.32);entrance.toValue = opacity;entrance.duration = 0.09*mode.durationScale
            entrance.timingFunction = CAMediaTimingFunction(name:.easeOut)
            layer.add(entrance,forKey:"sortHover")
        } else if opacity != 0.55 {
            // Do not fade away a previous owner's arrow, or leave a preview
            // half transparent after it becomes the actual current sort.
            layer.removeAnimation(forKey:"sortHover")
        }
        if oldDirection != ascending, oldOpacity > 0, opacity > 0 {
            var delta = (angle - fromAngle).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = fromAngle; turn.toValue = fromAngle + delta; turn.duration = 0.14 * mode.durationScale
            turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(turn, forKey: "sortTurn")
        } else if oldDirection != ascending || opacity == 0 {
            layer.removeAnimation(forKey: "sortTurn")
        }
    }
    func finishMotion() {
        glyphLayer.removeAnimation(forKey:"sortTurn");glyphLayer.removeAnimation(forKey:"sortHover")
    }
}
