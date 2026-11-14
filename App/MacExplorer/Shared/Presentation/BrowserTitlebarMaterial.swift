import AppKit

/// Uses the existing navigation material behind the public full-size titlebar.
/// Native toolbar/traffic-light hit testing stays above this passive backdrop.
@MainActor
final class BrowserTitlebarMaterial: NSView {
    let surface = NavigationGlassSurface(contentView: NSView())
    override init(frame: NSRect) {
        super.init(frame: frame)
        pin(surface, inside: self)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
