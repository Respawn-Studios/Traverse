import Foundation

/// YAML lexical hints, not a schema/parser. No tag construction, alias/anchor
/// resolution, merge processing, interpolation or external-resource loading.
enum EditorYAMLSyntax {
    private struct Block {
        let base: Int
        var contentIndent: Int?
    }
    static func color(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var cursor = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&cursor) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }
    private static func separation(_ offset: Int, _ c: EditorLexicalCursor) -> Bool {
        offset >= c.units.count || EditorLexicalCursor.white(c.units[offset]) || [44, 91, 93, 123, 125].contains(c.units[offset])
    }
    private static func mappingColon(_ offset: Int, _ c: EditorLexicalCursor) -> Bool {
        c.at(offset, 58) && separation(offset + 1, c)
    }
    /// A valid block header's marker/options end; trailing whitespace/comment
    /// is scanned separately. No unbounded regex/backtracking or header storage.
    private static func blockHeader(_ c: inout EditorLexicalCursor) throws -> (end: Int, indent: Int?)? {
        var next = c.index + 1, indentation: Int?, chomp = false
        while next < c.units.count {
            let unit = c.units[next]
            if (unit == 43 || unit == 45) && !chomp { chomp = true }
            else if (49...57).contains(unit) && indentation == nil { indentation = Int(unit - 48) }
            else { break }
            next += 1; try c.poll()
        }
        let end = next
        next = try c.horizontalEnd(next)
        guard next == c.units.count || c.at(next, 10) || c.at(next, 13) || c.at(next, 35) && next > end else { return nil }
        return (end, indentation)
    }
    private static func scan(_ c: inout EditorLexicalCursor) throws -> TextSyntaxResult {
        if c.cancelled() { throw EditorLexicalStop.cancelled }
        var lineStart = true, lineOffset = 0, lineIndent = 0, scalarBase = 0, keyIndent = 0
        var scalarStart = true, flowDepth = 0
        var quotedFlowColon: Int?
        var block: Block?
        let literals: Set<String> = ["true", "True", "TRUE", "false", "False", "FALSE", "null", "Null", "NULL", "~"]
        while c.index < c.units.count {
            if lineStart {
                lineOffset = c.index
                var content = c.index
                while content < c.units.count && c.units[content] == 32 { content += 1; try c.poll() }
                lineIndent = content - c.index; scalarBase = lineIndent; keyIndent = lineIndent
                let blank = content == c.units.count || c.at(content, 10) || c.at(content, 13)
                if var active = block {
                    if !blank && active.contentIndent == nil && lineIndent > active.base { active.contentIndent = lineIndent }
                    if blank || lineIndent > active.base && lineIndent >= (active.contentIndent ?? Int.max) {
                        let start = c.index
                        while c.index < c.units.count && !c.at(c.index, 10) { try c.advance() }
                        if c.at(c.index, 10) { try c.advance() }
                        try c.emit(start, .string); block = active; continue
                    }
                    block = nil
                }
                lineStart = false; scalarStart = true
                if content > c.index { try c.advance(content - c.index); continue }
            }
            let start = c.index, unit = c.units[c.index]
            if unit == 10 || unit == 13 {
                try c.advance(); lineStart = true; continue
            }
            if EditorLexicalCursor.horizontal(unit) { try c.advance(); continue }
            if start == lineOffset, flowDepth == 0, unit == 45 || unit == 46,
               c.at(start + 1, unit), c.at(start + 2, unit),
               start + 3 == c.units.count || EditorLexicalCursor.white(c.units[start + 3]) {
                try c.advance(3); try c.emit(start, .keyword); continue
            }
            if unit == 35 && (start == 0 || EditorLexicalCursor.white(c.units[start - 1])) {
                while c.index < c.units.count && !c.at(c.index, 10) { try c.advance() }
                try c.emit(start, .comment); continue
            }
            if unit == 34 || unit == 39 {
                try c.advance()
                while c.index < c.units.count {
                    if unit == 34 && c.at(c.index, 92) { try c.advance(min(2, c.units.count - c.index)) }
                    else if unit == 39 && c.at(c.index, 39) && c.at(c.index + 1, 39) { try c.advance(2) }
                    else if c.at(c.index, unit) { try c.advance(); break }
                    else { try c.advance() }
                }
                let after = try c.horizontalEnd(c.index)
                // YAML 1.2.2 section 7.4.2: quoted (JSON-like) flow keys
                // may have an adjacent value. Record this exact delimiter;
                // plain scalars/URLs retain their separation-based rule.
                let adjacentKey = flowDepth > 0 && c.at(after, 58)
                let key = mappingColon(after, c) || adjacentKey
                quotedFlowColon = adjacentKey ? after : nil
                if key { keyIndent = start - lineOffset }
                try c.emit(start, key ? .property : .string); scalarStart = false; continue
            }
            if flowDepth == 0 && scalarStart && (unit == 124 || unit == 62), let header = try blockHeader(&c) {
                try c.advance(header.end - c.index)
                try c.emit(start, .punctuation)
                block = .init(base: scalarBase, contentIndent: header.indent.map { scalarBase + $0 })
                scalarStart = false; continue
            }
            if [44, 91, 93, 123, 125].contains(unit) || mappingColon(start, c) || quotedFlowColon == start
                || (unit == 45 || unit == 63) && scalarStart && separation(start + 1, c) {
                try c.advance(); try c.emit(start, .punctuation)
                quotedFlowColon = nil
                if unit == 91 || unit == 123 { flowDepth += 1 }
                if unit == 93 || unit == 125 { flowDepth = max(0, flowDepth - 1) }
                if unit == 58 { scalarBase = keyIndent }
                scalarStart = unit != 93 && unit != 125; continue
            }
            // Plain scalar/key: # is ordinary content unless separated by
            // whitespace; colons in URLs and words remain inside the lexeme.
            var significantEnd = start
            while c.index < c.units.count {
                let next = c.units[c.index]
                if next == 10 || next == 13 || flowDepth > 0 && [44, 91, 93, 123, 125].contains(next)
                    || mappingColon(c.index, c)
                    || next == 35 && (c.index == start || EditorLexicalCursor.white(c.units[c.index - 1])) { break }
                try c.advance()
                if !EditorLexicalCursor.horizontal(next) { significantEnd = c.index }
            }
            if c.index == start { try c.advance(); scalarStart = false; continue }
            if mappingColon(c.index, c) {
                keyIndent = start - lineOffset
                try c.emit(start, .property, end: significantEnd)
            } else if significantEnd > start {
                if significantEnd - start <= 5 && literals.contains(String(decoding: c.units[start..<significantEnd], as: UTF16.self)) {
                    try c.emit(start, .literal, end: significantEnd)
                } else if try c.decimal(start, significantEnd) { try c.emit(start, .number, end: significantEnd) }
            }
            scalarStart = false
        }
        return c.finish()
    }
}
