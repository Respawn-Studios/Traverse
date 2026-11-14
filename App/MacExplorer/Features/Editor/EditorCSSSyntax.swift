import Foundation

/// CSS lexical presentation. SCSS/Less extensions use this CSS subset; no
/// preprocessor interpolation, variable expansion, imports or URL resolution.
enum EditorCSSSyntax {
    static func color(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        // The cursor is strictly local to this synchronous call. Preserve the
        // public nonescaping cancellation API without retaining its callback.
        withoutActuallyEscaping(cancelled) { cancellation in
            var cursor = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&cursor) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }

    private static func escape(_ c: inout EditorLexicalCursor) throws {
        try c.advance() // backslash
        guard c.index < c.units.count else { return }
        func hex(_ unit: UInt16) -> Bool {
            EditorLexicalCursor.digit(unit) || (65...70).contains(unit) || (97...102).contains(unit)
        }
        if hex(c.units[c.index]) {
            var count = 0
            while c.index < c.units.count && count < 6 && hex(c.units[c.index]) {
                try c.advance(); count += 1
            }
            if c.index < c.units.count && EditorLexicalCursor.white(c.units[c.index]) { try c.advance() }
        } else { try c.advance() }
    }

    private static func name(_ c: inout EditorLexicalCursor) throws {
        while c.index < c.units.count {
            let unit = c.units[c.index]
            if unit == 92 { try escape(&c) }
            else if EditorLexicalCursor.name(unit) || EditorLexicalCursor.digit(unit) { try c.advance() }
            else { break }
        }
    }

    /// Distinguish ordinary declarations from nested type:pseudo selectors.
    /// This lookahead visits a statement once, with the same cancellation bound.
    /// Custom-property brace token streams intentionally have no semantic model.
    private static func declaration(after colon: Int, cursor c: inout EditorLexicalCursor) throws -> Bool {
        var next = colon + 1, quote: UInt16 = 0, comment = false, parentheses = 0
        while next < c.units.count {
            let unit = c.units[next]
            if comment {
                if unit == 42 && c.at(next + 1, 47) { comment = false; next += 1; try c.poll() }
            } else if quote != 0 {
                if unit == 92 && next + 1 < c.units.count { next += 1; try c.poll() }
                else if unit == quote || unit == 10 { quote = 0 }
            } else if unit == 47 && c.at(next + 1, 42) { comment = true; next += 1; try c.poll() }
            else if unit == 34 || unit == 39 { quote = unit }
            else if unit == 92 && next + 1 < c.units.count { next += 1; try c.poll() }
            else if unit == 40 || unit == 91 { parentheses += 1 }
            else if unit == 41 || unit == 93 { parentheses = max(0, parentheses - 1) }
            else if parentheses == 0 {
                if unit == 123 { return false }
                if unit == 59 || unit == 125 { return true }
            }
            next += 1; try c.poll()
        }
        return true // an incomplete declaration remains useful while typing
    }

    private static func scan(_ c: inout EditorLexicalCursor) throws -> TextSyntaxResult {
        if c.cancelled() { throw EditorLexicalStop.cancelled }
        var declarationBlocks: [Bool] = []
        var first = true, value = false, propertyColon = false, nextBlockDeclarations = true
        let ruleContainers: Set<String> = ["media", "supports", "container", "layer", "scope", "document", "starting-style", "keyframes", "-webkit-keyframes"]
        while c.index < c.units.count {
            let start = c.index, unit = c.units[c.index]
            if EditorLexicalCursor.white(unit) { try c.advance(); continue }
            if unit == 47 && c.at(c.index + 1, 42) {
                try c.advance(2)
                while c.index < c.units.count {
                    if c.at(c.index, 42) && c.at(c.index + 1, 47) { try c.advance(2); break }
                    try c.advance()
                }
                try c.emit(start, .comment); continue
            }
            if unit == 34 || unit == 39 {
                try c.advance()
                while c.index < c.units.count {
                    if c.units[c.index] == 10 || c.units[c.index] == 13 { break }
                    if c.units[c.index] == 92 { try escape(&c) }
                    else if c.units[c.index] == unit { try c.advance(); break }
                    else { try c.advance() }
                }
                try c.emit(start, .string); first = false; continue
            }
            // Hashes are selectors or value lexemes in CSS, never comments.
            if unit == 35 {
                try c.advance(); try name(&c)
                try c.emit(start, value ? .literal : .type); first = false; continue
            }
            if unit == 64 {
                try c.advance(); let word = c.index; try name(&c)
                if c.index - word <= 32 {
                    nextBlockDeclarations = !ruleContainers.contains(String(decoding: c.units[word..<c.index], as: UTF16.self).lowercased())
                } else { nextBlockDeclarations = true }
                try c.emit(start, .keyword); first = false; continue
            }
            let signedNumber = (unit == 43 || unit == 45) && (c.index + 1 < c.units.count && EditorLexicalCursor.digit(c.units[c.index + 1]) || c.at(c.index + 1, 46) && c.index + 2 < c.units.count && EditorLexicalCursor.digit(c.units[c.index + 2]))
            if EditorLexicalCursor.digit(unit) || signedNumber || unit == 46 && c.index + 1 < c.units.count && EditorLexicalCursor.digit(c.units[c.index + 1]) {
                if unit == 43 || unit == 45 { try c.advance() }
                while c.index < c.units.count && EditorLexicalCursor.digit(c.units[c.index]) { try c.advance() }
                if c.at(c.index, 46) && c.index + 1 < c.units.count && EditorLexicalCursor.digit(c.units[c.index + 1]) {
                    try c.advance()
                    while c.index < c.units.count && EditorLexicalCursor.digit(c.units[c.index]) { try c.advance() }
                }
                var exponent = c.index + 1
                if c.at(exponent, 43) || c.at(exponent, 45) { exponent += 1 }
                if (c.at(c.index, 69) || c.at(c.index, 101)) && exponent < c.units.count && EditorLexicalCursor.digit(c.units[exponent]) {
                    try c.advance(exponent - c.index)
                    while c.index < c.units.count && EditorLexicalCursor.digit(c.units[c.index]) { try c.advance() }
                }
                // CSS dimensions/percentages are one lexeme (12px, .5em).
                try name(&c)
                if c.at(c.index, 37) { try c.advance() }
                try c.emit(start, .number); first = false; continue
            }
            if EditorLexicalCursor.name(unit) || unit == 92 {
                try name(&c)
                let after = try c.horizontalEnd(c.index)
                let inDeclarations = declarationBlocks.last == true
                var property = false
                if first && inDeclarations && c.at(after, 58) {
                    property = try declaration(after: after, cursor: &c)
                }
                propertyColon = property
                let kind: TextSyntaxToken.Kind = property ? .property : value ? (c.at(after, 40) ? .function : .literal) : .type
                let url = c.index - start == 3 && [85, 117].contains(c.units[start])
                    && [82, 114].contains(c.units[start + 1]) && [76, 108].contains(c.units[start + 2])
                try c.emit(start, kind); first = false
                if value && url && c.at(c.index, 40) {
                    let opening = c.index
                    try c.advance(); try c.emit(opening, .punctuation)
                    while c.index < c.units.count && EditorLexicalCursor.white(c.units[c.index]) { try c.advance() }
                    if !c.at(c.index, 34) && !c.at(c.index, 39) {
                        // An unquoted URL is one opaque lexical value. Delimiters
                        // inside it cannot start comments or declarations. This
                        // never parses a URL or invokes any resource operation.
                        let body = c.index
                        while c.index < c.units.count && !c.at(c.index, 41) {
                            if c.at(c.index, 92) { try escape(&c) } else { try c.advance() }
                        }
                        try c.emit(body, .string)
                    }
                }
                continue
            }
            try c.advance()
            if unit == 123 {
                try c.emit(start, .punctuation)
                declarationBlocks.append(nextBlockDeclarations)
                first = true; value = false; propertyColon = false; nextBlockDeclarations = true
            } else if unit == 125 {
                try c.emit(start, .punctuation)
                if !declarationBlocks.isEmpty { declarationBlocks.removeLast() }
                first = true; value = false; propertyColon = false; nextBlockDeclarations = true
            } else if unit == 59 {
                try c.emit(start, .punctuation)
                first = true; value = false; propertyColon = false; nextBlockDeclarations = true
            } else {
                if [40, 41, 44, 58, 91, 93, 61, 62, 43, 126, 46, 38, 42, 124].contains(unit) { try c.emit(start, .punctuation) }
                if unit == 58 && propertyColon { value = true; propertyColon = false }
                // Selector prefixes do not consume a potential declaration name.
                if ![46, 38, 42].contains(unit) { first = false }
            }
        }
        return c.finish()
    }
}
