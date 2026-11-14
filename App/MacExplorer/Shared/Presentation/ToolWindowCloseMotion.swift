import AppKit
import QuartzCore

/// Optional exit presentation after a feature has accepted a user close.
/// Programmatic close, work draining and the window delegate remain native.
/// No screenshots, duplicate windows or file-operation ownership are retained.
@MainActor enum ToolWindowCloseMotion {
    @MainActor private final class Exit {
        weak var window: NSWindow?
        let id = UUID()
        let ignoredMouseEvents: Bool
        var observation: BrowserNotificationObservation?
        init(_ window: NSWindow) { self.window = window; ignoredMouseEvents = window.ignoresMouseEvents }
    }
    private static var exits: [ObjectIdentifier: Exit] = [:]
    static func isClosing(_ window: NSWindow) -> Bool { exits[ObjectIdentifier(window)] != nil }

    /// Used only after the feature's own pending-work/consent close guard.
    /// A false result means this owner will call ordinary close after its fade.
    static func shouldClose(_ window: NSWindow) -> Bool {
        let key = ObjectIdentifier(window)
        if exits[key] != nil { return false }
        let motion = (window.contentViewController as? ToolWindowChrome)?.motion ?? InterfacePresentation.shared.motion
        guard window.isVisible, !window.isMiniaturized, window.attachedSheet == nil, window.sheetParent == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, motion.allows(.windowClosing) else { return true }
        exits = exits.filter { $0.value.window != nil }
        let exit = Exit(window); exits[key] = exit
        exit.observation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: window) { _ in
            MainActor.assumeIsolated { cancel(window) }
        }
        window.makeFirstResponder(nil)
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20 * motion.mode.durationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish(key, id: exit.id) }
        }
        return false
    }
    /// An explicit Show during the short exit keeps the same live window.
    static func cancel(_ window: NSWindow) {
        guard let exit = exits.removeValue(forKey: ObjectIdentifier(window)) else { return }
        exit.observation = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; window.animator().alphaValue = 1
        }
        window.ignoresMouseEvents = exit.ignoredMouseEvents
    }
    static func finishIfDisabled(_ window: NSWindow, motion: BrowserMotionPreferences) {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !motion.allows(.windowClosing),
              let exit = exits[ObjectIdentifier(window)] else { return }
        finish(ObjectIdentifier(window), id: exit.id)
    }
    private static func finish(_ key: ObjectIdentifier, id: UUID) {
        guard let exit = exits[key], exit.id == id else { return }
        exits[key] = nil; exit.observation = nil
        guard let window = exit.window else { return }
        window.ignoresMouseEvents = exit.ignoredMouseEvents
        let native = window.animationBehavior
        window.animationBehavior = .none
        window.close()
        window.animationBehavior = native; window.alphaValue = 1
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
        ToolWindowCloseMotion.cancel(self)
        let native = animationBehavior
        animationBehavior = .none
        super.close()
        animationBehavior = native
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
        ToolWindowCloseMotion.cancel(self); super.makeKeyAndOrderFront(sender)
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
        ToolWindowCloseMotion.cancel(self); super.makeKeyAndOrderFront(sender)
    }
}
