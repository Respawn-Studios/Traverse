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
        guard !ranges.isEmpty, let layout = text.layoutManager, let container = text.textContainer else { return }
        let origin = text.textContainerOrigin
        let viewport = NSIntersectionRect(text.visibleRect, dirtyRect).offsetBy(dx: -origin.x, dy: -origin.y)
        guard !viewport.isEmpty else { return }
        let glyphs = layout.glyphRange(forBoundingRect: viewport, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0 else { return }
        var low = 0, high = ranges.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(ranges[mid]) <= characters.location { low = mid + 1 } else { high = mid }
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        func paint(_ range: NSRange, active: Bool) {
            let clipped = NSIntersectionRange(range, characters)
            guard clipped.length > 0 else { return }
            let markedGlyphs = layout.glyphRange(forCharacterRange: clipped, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: markedGlyphs,
                withinSelectedGlyphRange: .init(location: NSNotFound, length: 0), in: container) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -0.5)
                let path = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
                color.withAlphaComponent(contrast ? 0.28 : (active ? 0.12 : 0.10)).setFill(); path.fill()
                if active || contrast {
                    color.withAlphaComponent(contrast ? 1 : 0.65).setStroke()
                    path.lineWidth = contrast ? 1.5 : 1; path.stroke()
                }
            }
        }
        var drawn = 0
        while low < ranges.count && ranges[low].location < NSMaxRange(characters) && drawn < 4_096 {
            paint(ranges[low], active: false)
            low += 1; drawn += 1
        }
        // Preserve active feedback even when an unusually large viewport has
        // more disjoint passive fills than its foreground drawing budget.
        let length = text.textStorage?.length ?? 0
        if let current, current.location >= 0, current.length > 0,
           current.location <= length, current.length <= length - current.location { paint(current, active: true) }
    }
}
