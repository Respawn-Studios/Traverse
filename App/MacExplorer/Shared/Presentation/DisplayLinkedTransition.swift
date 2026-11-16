import AppKit
import QuartzCore

/// A short transition of real native layout. Unlike an implicit layer animation,
/// each frame updates the geometry AppKit uses for layout and hit testing.
@MainActor
final class DisplayLinkedTransition {
    @MainActor private final class Tick: NSObject {
        weak var owner: DisplayLinkedTransition?
        @objc func update(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(link)
        }
    }
    private let tick = Tick()
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var firstFrameDeadline: Task<Void, Never>?
    private var began: CFTimeInterval?
    private var duration = 0.0
    private var update: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?
    var isAnimating: Bool { link != nil }

    init() { tick.owner = self }
    isolated deinit { link?.invalidate(); firstFrameDeadline?.cancel() }

    func animate(in window: NSWindow, duration: TimeInterval, startsOnFirstFrame: Bool = false,
                 update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void = {}) {
        cancel()
        guard duration.isFinite, duration > 0, window.isVisible else {
            update(1); completion(); return
        }
        self.window = window; self.duration = duration
        began = startsOnFirstFrame ? nil : CACurrentMediaTime()
        self.update = update; self.completion = completion
        let link = window.displayLink(target: tick, selector: #selector(Tick.update(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        self.link = link
        update(0)
        // The initial layout can synchronously cancel or replace this transition.
        if self.link === link {
            link.add(to: .main, forMode: .common)
            if startsOnFirstFrame {
                // An ordered window outside every display receives no native
                // ticks. It must not remain invisible or retain an entrance.
                firstFrameDeadline = Task { @MainActor [weak self, weak link] in
                    do { try await Task.sleep(for: .seconds(duration + 0.2)) } catch { return }
                    guard let self, let link, self.link === link else { return }
                    self.finish()
                }
            }
        }
    }

    func cancel() {
        link?.invalidate(); link = nil; window = nil
        firstFrameDeadline?.cancel(); firstFrameDeadline = nil
        update = nil; completion = nil; began = nil
    }

    private func advance(_ link: CADisplayLink) {
        guard self.link === link else { return }
        guard let window, window.isVisible else { finish(); return }
        // A newly ordered window may do its first native layout before a frame
        // can be delivered. That work must not consume its entrance transition.
        if began == nil { began = link.targetTimestamp }
        let progress = min(1, max(0, (link.targetTimestamp - (began ?? link.targetTimestamp)) / duration))
        let eased = progress * progress * (3 - 2 * progress)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        update?(CGFloat(eased))
        CATransaction.commit()
        // Layout may cancel or retarget while the update is running.
        if self.link === link, progress >= 1 { finish() }
    }

    private func finish() {
        let completion = completion
        cancel()
        completion?()
    }
}
