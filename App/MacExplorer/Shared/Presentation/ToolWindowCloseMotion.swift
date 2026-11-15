import AppKit
import QuartzCore

/// Optional exit presentation after a feature has accepted a user close.
/// Programmatic close, work draining and the window delegate remain native.
/// No screenshots, duplicate windows or file-operation ownership are retained.
@MainActor enum ToolWindowCloseMotion {
    private enum ExitKind { case native, accepted }
    @MainActor private final class Exit {
        weak var window: NSWindow?
        let id: UUID
        let kind: ExitKind
        let motion: BrowserMotionPreferences
        let ignoredMouseEvents: Bool
        var observation: BrowserNotificationObservation?
        var acceptedContinuation: CheckedContinuation<Bool, Never>?
        var prepared = false
        init(_ window: NSWindow, id: UUID = UUID(), kind: ExitKind, motion: BrowserMotionPreferences,
             continuation: CheckedContinuation<Bool, Never>? = nil) {
            self.window = window; self.id = id; self.kind = kind; self.motion = motion
            ignoredMouseEvents = window.ignoresMouseEvents; acceptedContinuation = continuation
        }
    }
    private static var exits: [ObjectIdentifier: Exit] = [:]
    static func isClosing(_ window: NSWindow) -> Bool { exits[ObjectIdentifier(window)] != nil }

    private static func motion(for window: NSWindow) -> BrowserMotionPreferences {
        (window.contentViewController as? ToolWindowChrome)?.motion ?? InterfacePresentation.shared.motion
    }
    private static func mayAnimate(_ window: NSWindow, motion: BrowserMotionPreferences) -> Bool {
        window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible)
            && !window.isMiniaturized && window.attachedSheet == nil && window.sheetParent == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && motion.allows(.windowClosing)
    }
    private static func pruneStale() {
        for stale in exits.filter({ $0.value.window == nil }).keys { cancel(stale) }
    }
    private static func start(_ window: NSWindow, exit: Exit) {
        let key = ObjectIdentifier(window)
        exits[key] = exit
        exit.observation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: window) { _ in
            MainActor.assumeIsolated { cancel(window) }
        }
        // A document has already made its close decision before the accepted
        // gate. Resigning its editor here could commit text after that decision.
        if case .native = exit.kind { window.makeFirstResponder(nil) }
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20 * exit.motion.mode.durationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish(key, id: exit.id) }
        }
    }
    /// Used only after the feature's own pending-work/consent close guard.
    /// A false result means this owner will call ordinary close after its fade.
    static func shouldClose(_ window: NSWindow) -> Bool {
        pruneStale()
        let key = ObjectIdentifier(window)
        if exits[key] != nil { return false }
        let motion = motion(for: window)
        guard mayAnimate(window, motion: motion) else { return true }
        start(window, exit: Exit(window, kind: .native, motion: motion))
        return false
    }
    /// An accepted document retains its own buffer, access and worker until
    /// this visual gate returns. No native close or document callback happens
    /// here; the owner calls its synchronous finishClose after a final recheck.
    static func prepareAcceptedClose(_ window: NSWindow) async -> Bool {
        pruneStale()
        let key = ObjectIdentifier(window)
        guard !Task.isCancelled, exits[key] == nil else { return false }
        let motion = motion(for: window)
        guard mayAnimate(window, motion: motion) else { return !Task.isCancelled }
        let id = UUID()
        return await withTaskCancellationHandler {
            let completed = await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                start(window, exit: Exit(window, id: id, kind: .accepted, motion: motion,
                    continuation: continuation))
            }
            if Task.isCancelled { cancel(key, id: id); return false }
            guard completed, let exit = exits[key], exit.id == id,
                  exit.prepared, case .accepted = exit.kind else { return false }
            return true
        } onCancel: {
            Task { @MainActor in cancel(id: id) }
        }
    }
    /// An explicit Show during the short exit keeps the same live window.
    static func cancel(_ window: NSWindow) {
        cancel(ObjectIdentifier(window))
    }
    private static func cancel(id: UUID) {
        guard let key = exits.first(where: { $0.value.id == id })?.key else { return }
        cancel(key, id: id)
    }
    private static func cancel(_ key: ObjectIdentifier, id: UUID? = nil) {
        guard let exit = exits[key], id == nil || exit.id == id else { return }
        exits[key] = nil
        exit.observation = nil
        if let window = exit.window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; window.animator().alphaValue = 1
            }
            window.ignoresMouseEvents = exit.ignoredMouseEvents
        }
        exit.acceptedContinuation?.resume(returning: false); exit.acceptedContinuation = nil
    }
    /// Keep the accepted window noninteractive until its owner immediately
    /// performs the synchronous native close. A nil result is the old path.
    static func consumeAcceptedClose(_ window: NSWindow) -> Bool? {
        let key = ObjectIdentifier(window)
        guard let exit = exits[key], exit.prepared, case .accepted = exit.kind else { return nil }
        exits[key] = nil; exit.observation = nil
        return exit.ignoredMouseEvents
    }
    static func finishIfDisabled(_ window: NSWindow, motion: BrowserMotionPreferences) {
        guard let exit = exits[ObjectIdentifier(window)],
              NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || motion.mode != exit.motion.mode || motion.windowClosing != exit.motion.windowClosing else { return }
        finish(ObjectIdentifier(window), id: exit.id)
    }
    private static func finish(_ key: ObjectIdentifier, id: UUID) {
        guard let exit = exits[key], exit.id == id else { return }
        guard let window = exit.window else { cancel(key, id: id); return }
        switch exit.kind {
        case .accepted:
            guard !exit.prepared else { return }
            exit.prepared = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; window.animator().alphaValue = 0
            }
            exit.acceptedContinuation?.resume(returning: true); exit.acceptedContinuation = nil
        case .native:
            exits[key] = nil; exit.observation = nil
            window.ignoresMouseEvents = exit.ignoredMouseEvents
            let native = window.animationBehavior
            window.animationBehavior = .none
            window.close()
            window.animationBehavior = native; window.alphaValue = 1
        }
    }
}

/// Ordinary tool windows share the accepted-user-close boundary. AppKit still
/// consults the feature delegate first; direct close() remains immediate for
/// programmatic teardown and actual work draining.
@MainActor class ToolMotionWindow: NSWindow {
    private var userClose = false
    /// The feature already accepted and drained this close. Its owner may need
    /// the actual willClose callback before retiring a document or file pin.
    /// Bypass both a reentrant user-close fade and AppKit's implicit animation.
    func closeImmediatelyAfterFeatureAcceptance() {
        let acceptedMouseEvents = ToolWindowCloseMotion.consumeAcceptedClose(self)
        if acceptedMouseEvents == nil { ToolWindowCloseMotion.cancel(self) }
        let native = animationBehavior
        animationBehavior = .none
        super.close()
        animationBehavior = native
        if let acceptedMouseEvents { ignoresMouseEvents = acceptedMouseEvents }
        alphaValue = 1
    }
    override func performClose(_ sender: Any?) {
        userClose = true; defer { userClose = false }
        super.performClose(sender)
    }
    override func close() {
        if userClose && !ToolWindowCloseMotion.shouldClose(self) { return }
        let native = animationBehavior
        if userClose { animationBehavior = .none }
        super.close(); animationBehavior = native
    }
    override func sendEvent(_ event: NSEvent) {
        guard !ToolWindowCloseMotion.isClosing(self) else { return }
        super.sendEvent(event)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let wasVisible = isVisible
        ToolWindowCloseMotion.cancel(self); super.makeKeyAndOrderFront(sender)
        ToolContentMotion.revealWindowIfNewlyShown(self, wasVisible: wasVisible)
    }
}

@MainActor final class ToolMotionPanel: NSPanel {
    private var userClose = false
    override func performClose(_ sender: Any?) {
        userClose = true; defer { userClose = false }
        super.performClose(sender)
    }
    override func close() {
        if userClose && !ToolWindowCloseMotion.shouldClose(self) { return }
        let native = animationBehavior
        if userClose { animationBehavior = .none }
        super.close(); animationBehavior = native
    }
    override func sendEvent(_ event: NSEvent) {
        guard !ToolWindowCloseMotion.isClosing(self) else { return }
        super.sendEvent(event)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let wasVisible = isVisible
        ToolWindowCloseMotion.cancel(self); super.makeKeyAndOrderFront(sender)
        ToolContentMotion.revealWindowIfNewlyShown(self, wasVisible: wasVisible)
    }
}
