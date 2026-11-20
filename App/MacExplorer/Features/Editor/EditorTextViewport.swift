import AppKit

@MainActor struct EditorTextViewport {
    let layout: NSLayoutManager
    let container: NSTextContainer
    let origin: NSPoint
    let glyphs: NSRange
    let characters: NSRange

    init?(_ text: NSTextView, drawing dirtyRect: NSRect) {
        guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let origin = text.textContainerOrigin
        let viewport = text.visibleRect.intersection(dirtyRect).offsetBy(dx: -origin.x, dy: -origin.y)
        guard !viewport.isEmpty else { return nil }
        let glyphs = layout.glyphRange(forBoundingRect: viewport, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0 else { return nil }
        self.layout = layout
        self.container = container
        self.origin = origin
        self.glyphs = glyphs
        self.characters = characters
    }

    /// Both Find hits and change spans arrive sorted and disjoint. Search for
    /// the first visible range without visiting offscreen marks or laying them out.
    func visibleRanges(in ranges: [NSRange]) -> ArraySlice<NSRange> {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(ranges[middle]) <= characters.location { lower = middle + 1 }
            else { upper = middle }
        }
        return ranges[lower...].prefix { $0.location < NSMaxRange(characters) }
    }

    func visibleGlyphs(for range: NSRange) -> NSRange {
        let clipped = NSIntersectionRange(range, characters)
        guard clipped.length > 0 else { return .init(location: 0, length: 0) }
        return NSIntersectionRange(layout.glyphRange(forCharacterRange: clipped, actualCharacterRange: nil), glyphs)
    }

    func forEachVisibleBox(in range: NSRange, _ paint: @escaping (NSRect) -> Void) {
        let marked = visibleGlyphs(for: range)
        guard marked.length > 0 else { return }
        layout.enumerateEnclosingRects(forGlyphRange: marked,
            withinSelectedGlyphRange: .init(location: NSNotFound, length: 0), in: container) { rect, _ in
            paint(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
    }
}

/// Guides use the same visible TextKit fragments as Find and diff highlights.
/// Painting inspects leading whitespace in those fragments only.
@MainActor enum EditorIndentGuides {
    private static let maximumIndentColumns = 64

    static func rectangles(in text: EditorCodeTextView, dirtyRect: NSRect) -> [NSRect] {
        guard text.showsIndentGuides, text.indentationLanguage != .plain, !text.hasMarkedText(),
              let viewport = EditorTextViewport(text, drawing: dirtyRect),
              let source = text.textStorage?.mutableString,
              let interval = text.defaultParagraphStyle?.defaultTabInterval, interval.isFinite, interval > 0 else { return [] }
        let columns = text.indentationPreferences.columns
        let inset = min(2, interval / CGFloat(columns) / 3)
        let scale = max(1, text.window?.backingScaleFactor ?? 1)
        let clip = text.visibleRect.intersection(dirtyRect)
        var result: [NSRect] = []
        viewport.layout.enumerateLineFragments(forGlyphRange: viewport.glyphs) { fragment, _, _, glyphs, _ in
            let characters = viewport.layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let first = characters.location
            guard characters.length > 0, first < source.length,
                  first == 0 || source.character(at: first - 1) == 10 else { return }
            var cursor = first, depth = 0
            let end = min(source.length, NSMaxRange(characters))
            while cursor < end && depth < maximumIndentColumns {
                let unit = source.character(at: cursor)
                if unit == 32 { depth += 1 }
                else if unit == 9 { depth += columns - depth % columns }
                else { break }
                cursor += 1
            }
            let levels = min(depth, maximumIndentColumns) / columns
            guard levels > 0 else { return }
            let whitespace = viewport.layout.glyphRange(forCharacterRange: .init(location: first, length: cursor - first),
                                                       actualCharacterRange: nil)
            let span = viewport.layout.boundingRect(forGlyphRange: whitespace, in: viewport.container)
            for level in 1...levels {
                let x = span.minX + CGFloat(level) * interval - inset
                guard x < span.maxX else { break }
                let aligned = floor((viewport.origin.x + x) * scale) / scale
                let rect = NSRect(x: aligned, y: viewport.origin.y + fragment.minY, width: 1 / scale, height: fragment.height)
                    .intersection(clip)
                if !rect.isEmpty { result.append(rect) }
            }
        }
        return result
    }

    static func draw(in text: EditorCodeTextView, dirtyRect: NSRect) {
        let marks = rectangles(in: text, dirtyRect: dirtyRect)
        guard !marks.isEmpty else { return }
        let emphasis: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.43 : 0.23
        NSColor.labelColor.withAlphaComponent(emphasis).setFill()
        let path = NSBezierPath()
        for mark in marks { path.appendRect(mark) }
        path.fill()
    }
}

/// Paint native whitespace positions without substituting glyphs. Tabs and
/// hard line breaks keep their original advances, including in wrapped text.
@MainActor enum EditorWhitespaceMarks {
    struct Mark {
        enum Kind { case space, tab, lineBreak }
        let kind: Kind
        let cell: NSRect
    }

    static func visible(in text: EditorCodeTextView, dirtyRect: NSRect) -> [Mark] {
        guard text.showsWhitespaceMarks, !text.hasMarkedText(),
              let viewport = EditorTextViewport(text, drawing: dirtyRect),
              let source = text.textStorage?.mutableString, let font = text.font else { return [] }
        let width = (" " as NSString).size(withAttributes: [.font: font]).width
        let clip = text.visibleRect.intersection(dirtyRect)
        var result: [Mark] = []
        viewport.layout.enumerateLineFragments(forGlyphRange: viewport.glyphs) { fragment, _, _, glyphs, stop in
            let visible = NSIntersectionRange(viewport.glyphs, glyphs)
            for glyph in visible.location..<NSMaxRange(visible) {
                // Bound paint work even for zero-width or hostile line layouts.
                if glyph - viewport.glyphs.location >= 24_000 { stop.pointee = true; break }
                let index = viewport.layout.characterIndexForGlyph(at: glyph)
                guard index < source.length else { continue }
                let kind: Mark.Kind
                switch source.character(at: index) {
                case 9: kind = .tab
                case 10: kind = .lineBreak
                case 32: kind = .space
                default: continue
                }
                let position = viewport.layout.location(forGlyphAt: glyph).x
                let advance = glyph + 1 < NSMaxRange(glyphs) && kind != .lineBreak
                    ? viewport.layout.location(forGlyphAt: glyph + 1).x - position : width
                let cell = NSRect(x: viewport.origin.x + fragment.minX + position,
                    y: viewport.origin.y + fragment.minY, width: min(advance, width), height: fragment.height)
                if cell.width >= 2, cell.intersects(clip) { result.append(.init(kind: kind, cell: cell)) }
            }
        }
        return result
    }

    static func draw(in text: EditorCodeTextView, dirtyRect: NSRect) {
        let marks = visible(in: text, dirtyRect: dirtyRect)
        guard !marks.isEmpty else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = NSColor.labelColor.withAlphaComponent(contrast ? 0.63 : 0.38)
        let dots = NSBezierPath(), strokes = NSBezierPath()
        strokes.lineWidth = contrast ? 1.25 : 1
        strokes.lineCapStyle = .round
        strokes.lineJoinStyle = .round
        for mark in marks {
            let cell = mark.cell, y = cell.midY
            switch mark.kind {
            case .space:
                let radius = min(1.25, cell.width * 0.12)
                dots.appendOval(in: .init(x: cell.midX - radius, y: y - radius, width: radius * 2, height: radius * 2))
            case .tab:
                let tail = cell.minX + cell.width * 0.18, head = cell.maxX - cell.width * 0.18
                let arm = cell.width * 0.25
                strokes.move(to: .init(x: tail, y: y)); strokes.line(to: .init(x: head, y: y))
                strokes.move(to: .init(x: head - arm, y: y - arm)); strokes.line(to: .init(x: head, y: y))
                strokes.line(to: .init(x: head - arm, y: y + arm))
            case .lineBreak:
                let left = cell.minX + cell.width * 0.18, right = cell.maxX - cell.width * 0.18
                let arm = cell.width * 0.20
                strokes.move(to: .init(x: right, y: y - arm * 2)); strokes.line(to: .init(x: right, y: y))
                strokes.line(to: .init(x: left, y: y))
                strokes.move(to: .init(x: left + arm, y: y - arm)); strokes.line(to: .init(x: left, y: y))
                strokes.line(to: .init(x: left + arm, y: y + arm))
            }
        }
        color.setFill(); dots.fill()
        color.setStroke(); strokes.stroke()
    }
}

/// A viewport position in logical text, independent of font size and wrapping.
struct EditorScrollAnchor: Equatable {
    let line: Int
    let column: Int
    let fragmentProgress: CGFloat
}

extension NativeTextEditorSurface {
    func scrollAnchor() -> EditorScrollAnchor? {
        guard let lines = lineIndex, let layout = textView.layoutManager, let container = textView.textContainer,
              textView.visibleRect.height > 0 else { return nil }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        let extra = layout.extraLineFragmentRect
        if lines.starts.last == lines.length, layout.extraLineFragmentTextContainer === container,
           extra.height > 0, y >= extra.minY {
            return .init(line: lines.starts.count - 1, column: 0, fragmentProgress: min(1, (y - extra.minY) / extra.height))
        }
        guard lines.length > 0 else { return .init(line: 0, column: 0, fragmentProgress: 0) }
        let glyph = layout.glyphIndex(for: .init(x: container.lineFragmentPadding, y: max(0, y)), in: container)
        guard glyph != NSNotFound else { return nil }
        var glyphs = NSRange()
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        guard fragment.height > 0, glyphs.length > 0,
              let location = lines.location(at: layout.characterIndexForGlyph(at: glyphs.location)) else { return nil }
        return .init(line: location.line - 1, column: location.column - 1,
                     fragmentProgress: min(1, (y - fragment.minY) / fragment.height))
    }

    func scroll(to anchor: EditorScrollAnchor, horizontalOffset: CGFloat? = nil) {
        guard let lines = lineIndex, lines.starts.indices.contains(anchor.line),
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let start = lines.starts[anchor.line]
        let end = lines.start(ofLine: anchor.line + 2) ?? lines.length
        let offset = start + min(max(0, anchor.column), max(0, end - start - 1))
        let clip = scrollView.contentView
        func origin(at fragment: NSRect) -> NSPoint {
            let y = fragment.minY + fragment.height * anchor.fragmentProgress + textView.textContainerOrigin.y
            return .init(x: horizontalOffset ?? clip.bounds.minX,
                         y: clip.convert(.init(x: 0, y: y), from: textView).y)
        }
        let fragment: NSRect
        if offset == lines.length {
            if lines.length > 0, layout.extraLineFragmentTextContainer !== container {
                layout.ensureLayout(forCharacterRange: .init(location: lines.length - 1, length: 1))
            }
            fragment = layout.extraLineFragmentTextContainer === container ? layout.extraLineFragmentRect : .zero
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: .init(location: offset, length: 1), actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let target = NSRect(origin: origin(at: first), size: clip.bounds.size)
            // A distant fragment can be the last one laid out. Give TextKit a
            // viewport below it before the clip view clamps to that partial height.
            if !target.isEmpty, clip.constrainBoundsRect(target).minY < target.minY - 0.25 {
                layout.ensureLayout(forBoundingRect: .init(x: 0, y: first.minY,
                    width: target.width, height: target.height + first.height), in: container)
                fragment = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            } else {
                fragment = first
            }
        }
        restoreViewportOrigin(origin(at: fragment))
    }

    func restoreViewportOrigin(_ origin: NSPoint) {
        let clip = scrollView.contentView
        let bounds = NSRect(origin: origin, size: clip.bounds.size)
        let target = clip.constrainBoundsRect(bounds).origin
        guard abs(clip.bounds.minX - target.x) >= 0.25 || abs(clip.bounds.minY - target.y) >= 0.25 else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }
}
