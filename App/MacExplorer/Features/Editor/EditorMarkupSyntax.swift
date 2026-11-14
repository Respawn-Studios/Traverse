import Foundation

/// Lexical source colors only. Declarations, entities and external references
/// are never interpreted or loaded. Embedded scripts/styles are not separately
/// highlighted; this is not a validating HTML/XML parser.
enum EditorMarkupSyntax {
    static func color(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var c = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&c) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }
    private static func matches(_ text: [UInt16], at index: Int, in c: EditorLexicalCursor) -> Bool {
        index + text.count <= c.units.count && text.indices.allSatisfy { c.units[index + $0] == text[$0] }
    }
    private static func until(_ ending: [UInt16], cursor c: inout EditorLexicalCursor) throws {
        while c.index < c.units.count {
            if matches(ending, at: c.index, in: c) { try c.advance(ending.count); return }
            try c.advance()
        }
    }
    private static func name(_ c: inout EditorLexicalCursor) throws {
        while c.index < c.units.count {
            let u = c.units[c.index]
            guard EditorLexicalCursor.name(u) || EditorLexicalCursor.digit(u) || u == 58 || u == 46 else { return }
            try c.advance()
        }
    }
    private static func scan(_ c: inout EditorLexicalCursor) throws -> TextSyntaxResult {
        if c.cancelled() { throw EditorLexicalStop.cancelled }
        var inTag = false, expectsName = false
        while c.index < c.units.count {
            let start = c.index, u = c.units[start]
            if matches([60, 33, 45, 45], at: start, in: c) {
                try c.advance(4); try until([45, 45, 62], cursor: &c); try c.emit(start, .comment)
                inTag = false; continue
            }
            if matches([60, 33, 91, 67, 68, 65, 84, 65, 91], at: start, in: c) {
                try c.advance(9); try until([93, 93, 62], cursor: &c); try c.emit(start, .string)
                inTag = false; continue
            }
            if u == 60, c.index + 1 < c.units.count,
               EditorLexicalCursor.name(c.units[start + 1]) || [47, 33, 63].contains(c.units[start + 1]) {
                try c.advance()
                if c.at(c.index, 47) || c.at(c.index, 33) || c.at(c.index, 63) { try c.advance() }
                try c.emit(start, .punctuation); inTag = true; expectsName = true; continue
            }
            if inTag {
                if u == 34 || u == 39 {
                    try c.advance()
                    while c.index < c.units.count {
                        let closed = c.units[c.index] == u
                        try c.advance(); if closed { break }
                    }
                    try c.emit(start, .string)
                } else if u == 62 || (u == 47 || u == 63) && c.at(start + 1, 62) {
                    try c.advance(u == 62 ? 1 : 2); try c.emit(start, .punctuation); inTag = false
                } else if EditorLexicalCursor.name(u) || EditorLexicalCursor.digit(u) || u == 58 {
                    try name(&c); try c.emit(start, expectsName ? .keyword : .property); expectsName = false
                } else {
                    try c.advance()
                    if u == 61 || u == 91 || u == 93 { try c.emit(start, .punctuation) }
                }
            } else if u == 38 {
                // A bounded entity-shaped lexeme, not entity expansion.
                var end = start + 1
                while end < c.units.count && end - start <= 64
                    && (EditorLexicalCursor.name(c.units[end]) || EditorLexicalCursor.digit(c.units[end]) || c.units[end] == 35) { end += 1 }
                if c.at(end, 59) { try c.advance(end - start + 1); try c.emit(start, .literal) }
                else { try c.advance() }
            } else { try c.advance() }
        }
        return c.finish()
    }
}
