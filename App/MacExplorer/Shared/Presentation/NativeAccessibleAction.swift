import AppKit

/// Custom accessibility selectors do not receive NSControl's normal tracking
/// eligibility automatically. Keep that native boundary shared and synchronous.
@MainActor enum NativeAccessibleAction {
    static func canInvoke(_ view: NSView, enabled: Bool = true) -> Bool {
        enabled && !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true
            && view.window?.attachedSheet == nil
    }
    static func activateWindow(_ view: NSView) -> Bool {
        guard canInvoke(view), let window = view.window else { return false }
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps:true) }
        return true
    }
}

@MainActor extension BrowserViewController {
    /// Explicit AT interaction with a visible pane has the same pane/focus
    /// destination as a pointer interaction, before selection or command dispatch.
    func prepareAccessibleBrowsingInteraction() -> Bool {
        guard !isBrowserSuspended, let view = viewIfLoaded, NativeAccessibleAction.canInvoke(view) else { return false }
        if let workspace, workspace.browsers[paneID] !== self { return false }
        guard NativeAccessibleAction.activateWindow(view) else { return false }
        if let workspace { workspace.activate(self) } else { focusBrowserContent() }
        return hasFileCommandFocus
    }
}
