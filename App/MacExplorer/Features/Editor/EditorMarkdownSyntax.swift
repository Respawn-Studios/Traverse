import Foundation

/// Lightweight Markdown source colors, not a renderer or a complete CommonMark
/// parser. One forward pass handles headings, fences, code and link punctuation.
enum EditorMarkdownSyntax {
    static func color(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var c = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&c) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }
    private static func scan(_ c: inout EditorLexicalCursor) throws -> TextSyntaxResult {
        if c.cancelled() { throw EditorLexicalStop.cancelled }
        var fence: (unit: UInt16, length: Int)?
        while c.index < c.units.count {
            let line = c.index
            var end = line
            while end < c.units.count && c.units[end] != 10 { end += 1; try c.poll() }
            var content = line
            while content < end && content - line < 3 && c.units[content] == 32 { content += 1 }
            let marker = content < end ? c.units[content] : 0
            var run = content
            if marker == 96 || marker == 126 {
                while run < end && c.units[run] == marker { run += 1; try c.poll() }
            }
            if let active = fence {
                var tail = run
                while tail < end && EditorLexicalCursor.horizontal(c.units[tail]) { tail += 1; try c.poll() }
                let closing = marker == active.unit && run - content >= active.length && tail == end
                try c.advance(end - line); try c.emit(line, closing ? .punctuation : .string)
                if closing { fence = nil }
            } else if run - content >= 3 {
                fence = (marker, run - content)
                try c.advance(end - line); try c.emit(content, .punctuation)
            } else {
                var hashes = content
                while hashes < end && c.units[hashes] == 35 && hashes - content < 7 { hashes += 1 }
                if (1...6).contains(hashes - content) && (hashes == end || EditorLexicalCursor.horizontal(c.units[hashes])) {
                    try c.advance(end - line); try c.emit(content, .keyword)
                } else {
                    try inline(until: end, cursor: &c)
                }
            }
            if c.index < c.units.count { try c.advance() } // LF
        }
        return c.finish()
    }
    private static func inline(until end: Int, cursor c: inout EditorLexicalCursor) throws {
        while c.index < end {
            let start = c.index, u = c.units[start]
            if u == 92 { try c.advance(min(2, end - start)) }
            else if u == 96 {
                while c.index < end && c.units[c.index] == 96 { try c.advance() }
                let width = c.index - start
                while c.index < end {
                    if c.units[c.index] != 96 { try c.advance(); continue }
                    let closing = c.index
                    while c.index < end && c.units[c.index] == 96 { try c.advance() }
                    if c.index - closing == width { break }
                }
                try c.emit(start, .string)
            } else if u == 40 && start > 0 && c.units[start - 1] == 93 {
                try c.advance(); try c.emit(start, .punctuation)
                let destination = c.index
                while c.index < end && c.units[c.index] != 41 {
                    try c.advance(c.units[c.index] == 92 ? min(2, end - c.index) : 1)
                }
                try c.emit(destination, .string)
                if c.index < end { let closing = c.index; try c.advance(); try c.emit(closing, .punctuation) }
            } else {
                try c.advance()
                if [35, 42, 95, 91, 93, 33, 62].contains(u) { try c.emit(start, .punctuation) }
            }
        }
    }
}
