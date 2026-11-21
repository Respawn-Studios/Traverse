import AppKit

struct EditorFoldIndex: Sendable {
    struct Block: Equatable, Sendable {
        let line: Int
        let opening: NSRange
        let hidden: NSRange
        let separator: Int

        func hidesSelectionEdge(_ selection: NSRange) -> Bool {
            let low = hidden.location, high = NSMaxRange(hidden)
            return (low < selection.location && selection.location < high)
                || (low < NSMaxRange(selection) && NSMaxRange(selection) < high)
        }
    }

    let byLine: [Int: Block]
    let topLevel: [Block]

    init(_ pairs: [EditorDelimiterWalk.Pair], scopes: [EditorDocumentOutline.Scope], lines: EditorLineIndex, text: String) {
        let source = text as NSString
        var values: [Int: Block] = [:]
        for pair in pairs where pair.openingUnit == 123 || pair.openingUnit == 91 {
            guard let first = lines.location(at: pair.opening), let last = lines.location(at: pair.closing),
                  first.line < last.line, let nextLine = lines.start(ofLine: first.line + 1) else { continue }
            let closingLine = pair.closing + 1 - last.column
            let leading = NSRange(location: closingLine, length: pair.closing - closingLine)
            let indentedClose = source.substring(with: leading).utf16.allSatisfy { $0 == 9 || $0 == 32 }
            let start = pair.opening + 1
            let end = indentedClose ? closingLine : pair.closing
            guard end - start > 1 else { continue }
            let block = Block(line: first.line, opening: .init(location: pair.opening, length: 1),
                hidden: .init(location: start, length: end - start),
                separator: nextLine - 1)
            if values[first.line].map({ $0.hidden.length < block.hidden.length }) ?? true {
                values[first.line] = block
            }
        }
        for scope in scopes {
            guard let header = scope.contentStartsAfterLine,
                  let body = lines.start(ofLine: header + 1), body > 1,
                  let followingLine = lines.location(at: min(scope.end, source.length)) else { continue }
            let end = scope.end >= source.length ? source.length : scope.end + 1 - followingLine.column
            guard end > body else { continue }
            let opening = source.rangeOfComposedCharacterSequence(at: body - 2)
            let line = scope.entry.line
            let block = Block(line: line, opening: opening,
                hidden: .init(location: body - 1, length: end - body + 1), separator: body - 1)
            if values[line].map({ $0.hidden.length < block.hidden.length }) ?? true { values[line] = block }
        }
        byLine = values
        topLevel = Self.outerBlocks(values.values)
    }

    static func outerBlocks(_ blocks: some Sequence<Block>) -> [Block] {
        var outer: [Block] = []
        for block in blocks.sorted(by: {
            $0.hidden.location == $1.hidden.location ? $0.hidden.length > $1.hidden.length
                : $0.hidden.location < $1.hidden.location
        }) {
            if outer.last.map({ NSMaxRange($0.hidden) <= block.hidden.location }) ?? true { outer.append(block) }
        }
        return outer
    }

    func block(for selection: NSRange, on line: Int) -> Block? {
        if let block = byLine[line] { return block }
        return byLine.values.filter {
            $0.hidden.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.hidden)
        }.min { $0.hidden.length < $1.hidden.length }
    }
}

/// Fold only the layout. Selected text, Find, Save and Undo retain
/// the original storage and the same UTF-16 offsets.
@MainActor
final class EditorCodeFolding: NSObject, @MainActor NSLayoutManagerDelegate {
    private static let maximumActive = 128
    private var folded: [Int: EditorFoldIndex.Block] = [:]
    private var visible: [EditorFoldIndex.Block] = []
    private weak var layout: NSLayoutManager?

    init(layout: NSLayoutManager?) { self.layout = layout }

    var hasFolds: Bool { !folded.isEmpty }
    var visibleOpenings: [NSRange] { visible.map(\.opening) }
    func isFolded(on line: Int) -> Bool { folded[line] != nil }
    func canToggle(on line: Int) -> Bool { isFolded(on: line) || folded.count < Self.maximumActive }

    func canFoldAny(_ blocks: [EditorFoldIndex.Block]) -> Bool {
        folded.count < Self.maximumActive && blocks.contains { !isFolded(on: $0.line) }
    }

    func foldable(_ blocks: [EditorFoldIndex.Block]) -> [EditorFoldIndex.Block] {
        Array(blocks.lazy.filter { !self.isFolded(on: $0.line) }.prefix(Self.maximumActive - folded.count))
    }

    func fold(_ blocks: [EditorFoldIndex.Block]) {
        for block in foldable(blocks) { folded[block.line] = block }
        updateLayout()
    }

    func toggle(_ block: EditorFoldIndex.Block) {
        guard canToggle(on: block.line) else { return }
        if folded.removeValue(forKey: block.line) == nil { folded[block.line] = block }
        updateLayout()
    }

    func unfoldAll() {
        guard !folded.isEmpty else { return }
        folded.removeAll()
        updateLayout()
    }

    func reveal(_ range: NSRange, explicitly: Bool) -> Bool {
        guard !folded.isEmpty else { return false }
        let retaining = folded.filter { _, block in
            let hidden = block.hidden
            if explicitly {
                return range.length == 0 ? !NSLocationInRange(range.location, hidden)
                    : NSIntersectionRange(range, hidden).length == 0
            }
            return !block.hidesSelectionEdge(range)
        }
        guard retaining.count != folded.count else { return false }
        folded = retaining
        updateLayout()
        return true
    }

    private func updateLayout() {
        let outer = EditorFoldIndex.outerBlocks(folded.values)
        let changed = Set(visible.map(\.hidden)).symmetricDifference(outer.map(\.hidden))
        visible = outer
        guard let layout, let length = layout.textStorage?.length, !changed.isEmpty else { return }
        let start = changed.map(\.location).min() ?? 0
        let end = min(length, changed.map(NSMaxRange).max() ?? 0)
        if end > start {
            layout.invalidateGlyphs(forCharacterRange: .init(location: start, length: end - start),
                                    changeInLength: 0, actualCharacterRange: nil)
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard !visible.isEmpty, range.length > 0,
              let first = visible.firstIndex(where: { NSMaxRange($0.hidden) > characterIndexes[0] }),
              visible[first].hidden.location <= characterIndexes[range.length - 1] else { return 0 }
        var propertyValues = Array(UnsafeBufferPointer(start: properties, count: range.length))
        var block = first
        for index in propertyValues.indices {
            let offset = characterIndexes[index]
            while block < visible.count && NSMaxRange(visible[block].hidden) <= offset { block += 1 }
            guard block < visible.count, offset >= visible[block].hidden.location,
                  offset != visible[block].separator else { continue }
            propertyValues[index] = .null
        }
        propertyValues.withUnsafeBufferPointer { propertyValues in
            guard let properties = propertyValues.baseAddress else { return }
            layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: range)
        }
        return range.length
    }

    static func drawOpenings(_ openings: [NSRange], text: NSTextView, dirtyRect: NSRect) {
        guard !openings.isEmpty, let font = text.font, let viewport = EditorTextViewport(text, drawing: dirtyRect) else { return }
        let marker = "…" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let width = marker.size(withAttributes: attributes).width
        let right = text.visibleRect.maxX
        for opening in viewport.visibleRanges(in: openings) {
            let glyphs = viewport.visibleGlyphs(for: opening)
            guard glyphs.length > 0 else { continue }
            let bounds = viewport.layout.boundingRect(forGlyphRange: glyphs, in: viewport.container)
            let used = viewport.layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let x = bounds.maxX + 4 + viewport.origin.x
            guard used.maxX <= bounds.maxX + viewport.container.lineFragmentPadding + 1,
                  x + width < right else { continue }
            marker.draw(at: .init(x: x, y: bounds.minY + viewport.origin.y), withAttributes: attributes)
        }
    }
}
