import AppKit

/// Read-only line shading, clipped by the existing text viewport. It is
/// independent from syntax and Find, so neither overwrites the other's colors.
@MainActor enum EditorComparisonBackground {
    static func draw(_ ranges: [NSRange], color: NSColor, text: NSTextView, dirtyRect: NSRect) {
        guard !ranges.isEmpty, let layout = text.layoutManager, let container = text.textContainer else { return }
        let length = text.string.utf16.count, origin = text.textContainerOrigin
        let visible = layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        func shade(_ fragment: NSRect) {
            let line = NSRect(x: 0, y: origin.y + fragment.minY, width: text.bounds.width, height: max(1, fragment.height))
            guard line.intersects(dirtyRect) else { return }
            color.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.20 : 0.10).setFill()
            line.intersection(dirtyRect).fill()
            color.withAlphaComponent(0.85).setFill()
            NSRect(x: 1, y: line.minY, width: 3, height: line.height).intersection(dirtyRect).fill()
        }
        for range in ranges where range.location >= 0 && range.location <= length && range.length <= length - range.location {
            if range.length == 0 {
                // Empty spans are insertion/deletion anchors, not changed text.
                continue
            }
            let glyphs = NSIntersectionRange(layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), visible)
            guard glyphs.length > 0 else { continue }
            layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in shade(fragment) }
        }
    }
}
