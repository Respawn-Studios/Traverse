import AppKit
import ExplorerCore
import QuartzCore

@MainActor
private final class PaneTransitionClip: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Presentation only: live views reach their final layout immediately. Images
/// cannot receive events or retain a retired browser's drag/session authority.
@MainActor
final class WorkspacePaneTransition: NSView {
    struct Frame {
        let rect: NSRect
        let image: NSImage
    }
    struct Origin {
        let tab: Frame
        /// In pane-tree coordinates, separate from the original source tab.
        let dropFrame: NSRect?
        let edge: PaneDropEdge
    }
    struct Rearrangement {
        enum Kind: Equatable { case swap, direction }

        let kind: Kind
        let sides: [UUID]
        let foregroundSide: UUID
        let axis: PaneSplitAxis
        let bounds: NSRect
    }
    var origin: Origin?
    var arrivingPaneID: UUID?
    var rearrangement: Rearrangement?
    var mode = BrowserMotionMode.full
    private(set) var frames: [UUID: Frame] = [:]
    #if DEBUG
    private(set) var capturedForVerification = Set<UUID>()
    #endif
    private var masks: [(CALayer, CAShapeLayer)] = []
    private var incomingFades: [CALayer] = []
    private static let incomingFadeKey = "traverse.paneRearrangementIncoming"
    private var completion: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func capture<View: NSView>(_ hosts: [UUID: View], in parent: NSView, foreground: (UUID) -> [NSView]) {
        // Only the panes taking part consume image memory. A wide workspace
        // can still animate a smaller nested split at native resolution.
        guard mode != .off, parent.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              NativeForegroundSnapshot.fits(hosts.values.map(\.bounds.size), scale: parent.window?.backingScaleFactor ?? 1) else { return }
        for (id, host) in hosts {
            guard let image = NativeForegroundSnapshot.capture(in: host, views: foreground(id)) else { continue }
            frames[id] = Frame(rect: host.convert(host.bounds, to: parent), image: image)
            #if DEBUG
            capturedForVerification.insert(id)
            #endif
        }
    }

    func play(to hosts: [UUID: PaneHostView], in parent: NSView, rearrangementTargets: [UUID: NSView] = [:],
              liveRearrangementForeground: [NSView] = [], completion: @escaping () -> Void) {
        guard mode != .off, !frames.isEmpty, parent.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { completion(); return }
        self.completion = completion
        frame = parent.bounds; autoresizingMask = [.width, .height]
        wantsLayer = true; layer?.isOpaque = false; layer?.backgroundColor = NSColor.clear.cgColor
        if let rearrangement {
            playRearrangement(rearrangement, to: rearrangementTargets, in: parent, liveForeground: liveRearrangementForeground)
            return
        }
        let final = hosts.mapValues { $0.convert($0.bounds, to: parent) }
        let closing = frames.keys.contains { hosts[$0] == nil }
        let duration = mode.paneDuration(closing: closing)
        // Do not dissolve a still pane merely because its neighbour changed.
        // Its native material and current contents can remain on screen.
        frames = frames.filter { final[$0.key] != $0.value.rect }
        if frames.isEmpty, origin == nil { finish(); return }
        // Survivors keep the calm frame motion. An arriving pane uses a curved
        // reveal from the tab/drop position; neither path scales live text.
        var targets: [(PaneTransitionClip, NSRect)] = []
        for (id, from) in frames {
            let clip = makePicture(from, at: from.rect)
            addSubview(clip)
            if let destination = final[id] { targets.append((clip, destination)) }
            else {
                let survivor = final.values.max { a, b in
                    a.intersection(from.rect).width * a.intersection(from.rect).height
                        < b.intersection(from.rect).width * b.intersection(from.rect).height
                } ?? from.rect
                targets.append((clip, Self.collapsed(from.rect, toward: survivor)))
                let end = NSPoint(x: min(max(survivor.midX, from.rect.minX), from.rect.maxX) - from.rect.minX,
                                  y: min(max(survivor.midY, from.rect.minY), from.rect.maxY) - from.rect.minY)
                if mode == .full {
                    animateMask(on: clip.layer, bounds: clip.bounds, seed: end, direction: .zero,
                                duration: duration, closing: true)
                }
            }
        }
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        // Crop natural-size text instead of stretching it. Existing images
        // follow the moving divider, then dissolve into the live final layout.
        // New content is revealed underneath, without snapshotting an empty
        // newly created pane before its listing arrives.
        if mode == .full, let origin, let arrivingPaneID, let host = hosts[arrivingPaneID], let destination = final[arrivingPaneID] {
            let start = origin.dropFrame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? edgePoint(origin.edge, in: destination)
            let seed = host.convert(start, from: parent)
            let source = NSPoint(x: origin.tab.rect.midX, y: origin.tab.rect.midY)
            let vector = NSPoint(x: start.x - source.x, y: start.y - source.y)
            animateMask(on: host.layer, bounds: host.bounds, seed: seed, direction: vector, duration: duration)
            addTabTrail(origin, toward: destination, duration: duration)
        }
        for (clip, _) in targets {
            let dissolve = CAKeyframeAnimation(keyPath: "opacity")
            dissolve.values = mode == .full ? [1, 1, 0] : [0.65, 0.4, 0]; dissolve.keyTimes = [0, 0.46, 1]
            dissolve.duration = duration; dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.layer?.opacity = 0
            clip.layer?.add(dissolve, forKey: "paneDissolve")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.65, 0.2, 1)
            for (clip, destination) in targets { clip.animator().frame = destination }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    private func makePicture(_ sample: Frame, at rect: NSRect) -> PaneTransitionClip {
        let clip = PaneTransitionClip(frame: rect)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.isOpaque = false
        let image = NSImageView(frame: NSRect(origin: .zero, size: sample.rect.size))
        image.image = sample.image
        image.imageScaling = .scaleNone
        image.imageAlignment = .alignTopLeft
        clip.addSubview(image)
        return clip
    }

    private func playRearrangement(_ rearrangement: Rearrangement, to destinations: [UUID: NSView],
                                   in parent: NSView, liveForeground: [NSView]) {
        guard rearrangement.sides.count == 2,
              rearrangement.sides.allSatisfy({ frames[$0] != nil && destinations[$0] != nil }) else {
            finish()
            return
        }
        let full = mode == .full
        let duration = mode.paneDuration(closing: false)
        let stage = PaneTransitionClip(frame: rearrangement.bounds)
        stage.wantsLayer = true
        stage.layer?.masksToBounds = true
        addSubview(stage)
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        let order = rearrangement.sides.filter { $0 != rearrangement.foregroundSide } + [rearrangement.foregroundSide]
        var targets: [(PaneTransitionClip, NSRect)] = []
        for id in order {
            guard let sample = frames[id], let target = destinations[id] else { continue }
            let clip = makePicture(sample, at: stage.convert(sample.rect, from: parent))
            stage.addSubview(clip)
            if full {
                let direction: CGFloat = id == rearrangement.sides.first ? 1 : -1
                let arc = rearrangement.kind == .swap ? direction : 0
                animateCard(clip, axis: rearrangement.axis, direction: arc, duration: duration)
                targets.append((clip, target.convert(target.bounds, to: stage)))
            }
            if full, let layer = clip.layer {
                layer.opacity = 0
                layer.add(keyframes("opacity", values: [1, 0.96, 0.9, 0],
                    at: [0, 0.25, 0.70, 1], duration: duration), forKey: "paneRearrangementOutgoing")
            }
        }
        // Fade the live foreground in as the moving snapshots reach it.
        // Glass and AppKit responders stay in the settled hierarchy.
        for view in liveForeground where !view.isHiddenOrHasHiddenAncestor {
            guard let layer = view.layer else { continue }
            layer.add(keyframes("opacity", values: [0, 0, layer.opacity],
                at: [0, full ? 0.67 : 0.15, 1], duration: duration), forKey: Self.incomingFadeKey)
            incomingFades.append(layer)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.1, 0.24, 1)
            for (clip, destination) in targets { clip.animator().frame = destination }
            if !full { stage.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    private func animateCard(_ clip: NSView, axis: PaneSplitAxis, direction: CGFloat, duration: TimeInterval) {
        guard let layer = clip.layer else { return }
        if direction != 0 {
            let distance = min(42, (axis == .columns ? clip.bounds.height : clip.bounds.width) * 0.10)
            let offset = axis == .columns ? "transform.translation.y" : "transform.translation.x"
            layer.add(keyframes(offset, values: [0, direction * distance, 0], at: [0, 0.47, 1], duration: duration),
                      forKey: "paneSwapArc")
            layer.add(keyframes("transform.rotation.z", values: [0, direction * 0.063, 0],
                                at: [0, 0.47, 1], duration: duration), forKey: "paneSwapTilt")
        }
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = NSColor.windowBackgroundColor
            color = (background.blended(withFraction: 0.12, of: .labelColor) ?? background)
                .withAlphaComponent(0.72).cgColor
        }
        layer.add(keyframes("backgroundColor", values: [NSColor.clear.cgColor, color, color, NSColor.clear.cgColor],
                            at: [0, 0.19, 0.72, 1], duration: duration), forKey: "paneRearrangementPlate")
        layer.add(keyframes("cornerRadius", values: [0, 12, 12, 0], at: [0, 0.19, 0.72, 1], duration: duration),
                  forKey: "paneRearrangementCorners")
    }

    private func keyframes(_ path: String, values: [Any], at times: [NSNumber], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        return animation
    }

    /// Four quadratic segments in every keyframe make interpolation continuous.
    /// Only the clipping boundary bends; file rows and tab glyphs never warp.
    private func animateMask(on layer: CALayer?, bounds: NSRect, seed raw: NSPoint, direction: NSPoint,
                             duration: Double, closing: Bool = false) {
        guard let layer, layer.mask == nil, bounds.width > 1, bounds.height > 1 else { return }
        let seed = NSPoint(x: min(max(raw.x, bounds.minX), bounds.maxX), y: min(max(raw.y, bounds.minY), bounds.maxY))
        let length = max(1, hypot(direction.x, direction.y))
        let bend = NSPoint(x: direction.x / length * 22, y: direction.y / length * 22)
        let initial = curvedRect(center: seed, size: NSSize(width: 10, height: 24), bend: .zero)
        let middle = curvedRect(center: NSPoint(x: seed.x * 0.32 + bounds.midX * 0.68,
                                               y: seed.y * 0.32 + bounds.midY * 0.68),
                                size: NSSize(width: bounds.width * 0.56, height: bounds.height * 0.66), bend: bend)
        let full = curvedRect(center: NSPoint(x: bounds.midX, y: bounds.midY), size: bounds.size, bend: .zero)
        let mask = CAShapeLayer(); mask.frame = bounds; mask.fillColor = NSColor.black.cgColor
        mask.path = closing ? initial : full
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = closing ? [full, middle, initial] : [initial, middle, full]
        animation.keyTimes = [0, 0.42, 1]; animation.duration = duration
        animation.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.26, 0.05, 0.2, 1),
                                     CAMediaTimingFunction(controlPoints: 0.22, 0.6, 0.2, 1)]
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.mask = mask; CATransaction.commit()
        mask.add(animation, forKey: "paneReveal"); masks.append((layer, mask))
    }

    private func curvedRect(center: NSPoint, size: NSSize, bend: NSPoint) -> CGPath {
        let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        let path = CGMutablePath(); path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: center.x + bend.x, y: rect.minY - abs(bend.y)))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX + abs(bend.x), y: center.y + bend.y))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: center.x + bend.x, y: rect.maxY + abs(bend.y)))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX - abs(bend.x), y: center.y + bend.y))
        path.closeSubpath(); return path
    }

    private func edgePoint(_ edge: PaneDropEdge, in rect: NSRect) -> NSPoint {
        switch edge {
        case .leading: return NSPoint(x: rect.minX, y: rect.midY)
        case .trailing: return NSPoint(x: rect.maxX, y: rect.midY)
        case .top: return NSPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return NSPoint(x: rect.midX, y: rect.minY)
        }
    }

    private func addTabTrail(_ origin: Origin, toward destination: NSRect, duration: Double) {
        var start = origin.dropFrame ?? origin.tab.rect
        if start.width < 1 || start.height < 1 {
            start = NSRect(x: start.midX - origin.tab.rect.width / 2, y: start.midY - origin.tab.rect.height / 2,
                           width: origin.tab.rect.width, height: origin.tab.rect.height)
        }
        let ghost = PaneTransitionClip(frame: start); ghost.wantsLayer = true
        let image = NSImageView(frame: ghost.bounds); image.image = origin.tab.image
        image.imageScaling = .scaleNone; image.imageAlignment = .alignTopLeft
        ghost.addSubview(image); addSubview(ghost)
        guard let layer = ghost.layer else { return }
        let beginning = CGPoint(x: start.midX, y: start.midY)
        let end = CGPoint(x: min(max(start.midX, destination.minX + start.width / 2), destination.maxX - start.width / 2),
                          y: destination.maxY - start.height / 2 - 4)
        let source = CGPoint(x: origin.tab.rect.midX, y: origin.tab.rect.midY)
        let path = CGMutablePath(); path.move(to: beginning)
        path.addQuadCurve(to: end, control: CGPoint(x: beginning.x + (end.x - source.x) * 0.25,
                                                  y: beginning.y + (end.y - source.y) * 0.25))
        let travel = CAKeyframeAnimation(keyPath: "position"); travel.path = path; travel.duration = duration * 0.72
        travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.75, 0.65, 0]
        fade.keyTimes = [0, 0.22, 1]; fade.duration = duration * 0.72
        layer.position = end; layer.opacity = 0
        layer.add(travel, forKey: "tabArrival"); layer.add(fade, forKey: "tabArrivalFade")
    }
    private static func collapsed(_ rect: NSRect, toward destination: NSRect) -> NSRect {
        let dx = destination.midX - rect.midX, dy = destination.midY - rect.midY
        if abs(dx) >= abs(dy) {
            return NSRect(x: dx >= 0 ? rect.maxX - 1 : rect.minX, y: rect.minY, width: 1, height: rect.height)
        }
        return NSRect(x: rect.minX, y: dy >= 0 ? rect.maxY - 1 : rect.minY, width: rect.width, height: 1)
    }
    func finish() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (layer, mask) in masks {
            mask.removeAllAnimations()
            if layer.mask === mask { layer.mask = nil }
        }
        CATransaction.commit(); masks.removeAll()
        for layer in incomingFades { layer.removeAnimation(forKey: Self.incomingFadeKey) }
        incomingFades.removeAll()
        layer?.removeAllAnimations()
        removeFromSuperview(); subviews.forEach { $0.removeFromSuperview() }; frames.removeAll(); origin = nil; rearrangement = nil
        let action = completion; completion = nil; action?()
    }
}
