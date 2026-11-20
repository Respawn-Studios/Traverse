import AppKit

/// Read-only line and character shading, clipped by the text viewport. It is
/// independent from syntax and Find, so neither overwrites the other's colors.
@MainActor enum EditorComparisonBackground {
    enum Accent {
        case removed, inserted
        var color: NSColor { self == .removed ? .systemRed : .systemGreen }
        var sign: String { self == .removed ? "−" : "+" }
        var identifier: String { self == .removed ? "diff-excerpt-removed" : "diff-excerpt-inserted" }
    }

    @MainActor struct Tint {
        let accent: Accent
        let row: NSColor
        let inline: NSColor
        let contrast: Bool

        init(_ accent: Accent, appearance: NSAppearance) {
            self.accent = accent
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            row = accent.color.withAlphaComponent(contrast ? 0.32 : (dark ? 0.23 : 0.16))
            inline = accent.color.withAlphaComponent(contrast ? 0.62 : (dark ? 0.43 : 0.35))
        }

        func fill(_ rect: NSRect, clippedTo dirtyRect: NSRect) {
            row.setFill(); rect.intersection(dirtyRect).fill()
            accent.color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: contrast ? 3 : 2, height: rect.height).intersection(dirtyRect).fill()
        }
    }

    static func draw(_ ranges: [NSRange], details: [NSRange], accent: Accent?, text: NSTextView, dirtyRect: NSRect) {
        guard let accent, !ranges.isEmpty, let viewport = EditorTextViewport(text, drawing: dirtyRect) else { return }
        let tint = Tint(accent, appearance: text.effectiveAppearance)
        func shade(_ fragment: NSRect) {
            let line = NSRect(x: 0, y: viewport.origin.y + fragment.minY, width: text.bounds.width, height: max(1, fragment.height))
            guard line.intersects(dirtyRect) else { return }
            tint.fill(line, clippedTo: dirtyRect)
            // Put the sign in the text inset, leaving the text and its
            // existing syntax, selection and line-number drawing untouched.
            NSColor.labelColor.withAlphaComponent(tint.contrast ? 1 : 0.76).setFill()
            let y = floor(line.midY)
            NSRect(x: 4, y: y, width: 5, height: 1).intersection(dirtyRect).fill()
            if accent == .inserted {
                NSRect(x: 6, y: y - 2, width: 1, height: 5).intersection(dirtyRect).fill()
            }
        }
        for range in viewport.visibleRanges(in: ranges) {
            let glyphs = viewport.visibleGlyphs(for: range)
            guard glyphs.length > 0 else { continue }
            viewport.layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in shade(fragment) }
        }
        tint.inline.setFill()
        for range in viewport.visibleRanges(in: details) {
            viewport.forEachVisibleBox(in: range) { rect in
                guard rect.intersects(dirtyRect) else { return }
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}
