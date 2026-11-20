import AppKit

extension EditorFindHighlightColor {
    @MainActor var nativeColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .accent: .controlAccentColor
        case .purple: .systemPurple
        case .teal: .systemTeal
        case .orange: .systemOrange
        }
    }
}

/// Draw behind glyphs, after the text view's actual background. Foreground,
/// paragraph attributes and native Undo are never modified for Find styling.
@MainActor
enum EditorFindHighlights {
    static func draw(_ ranges: [NSRange], current: NSRange?, color: NSColor,
                     text: NSTextView, dirtyRect: NSRect) {
        guard !ranges.isEmpty, let viewport = EditorTextViewport(text, drawing: dirtyRect) else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        func paint(_ range: NSRange, active: Bool) {
            viewport.forEachVisibleBox(in: range) { rect in
                let box = rect.insetBy(dx: -1, dy: -0.5)
                let path = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
                color.withAlphaComponent(contrast ? 0.28 : (active ? 0.12 : 0.10)).setFill(); path.fill()
                if active || contrast {
                    color.withAlphaComponent(contrast ? 1 : 0.65).setStroke()
                    path.lineWidth = contrast ? 1.5 : 1; path.stroke()
                }
            }
        }
        for range in viewport.visibleRanges(in: ranges).prefix(4_096) { paint(range, active: false) }
        // Preserve active feedback even when an unusually large viewport has
        // more disjoint passive fills than its foreground drawing budget.
        let length = text.textStorage?.length ?? 0
        if let current, current.location >= 0, current.length > 0,
           current.location <= length, current.length <= length - current.location { paint(current, active: true) }
    }
}
