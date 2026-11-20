import Foundation

enum EditorINISyntax {
    static func color(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var cursor = EditorLexicalCursor(units, cancelled: cancellation)
            do {
                while cursor.index < units.count {
                    let start = try cursor.horizontalEnd(cursor.index)
                    cursor.index = start
                    while cursor.index < units.count, !cursor.at(cursor.index, 10), !cursor.at(cursor.index, 13) {
                        try cursor.advance()
                    }
                    try colorLine(from: start, through: cursor.index, cursor: &cursor)
                    if cursor.index < units.count { try cursor.advance() }
                }
                return cursor.finish()
            } catch let stop as EditorLexicalStop {
                return stop.result
            } catch {
                return .plain(.cancelled)
            }
        }
    }

    private static func colorLine(from start: Int, through end: Int, cursor: inout EditorLexicalCursor) throws {
        guard start < end else { return }
        if cursor.at(start, 35) || cursor.at(start, 59) {
            try cursor.emit(start, .comment, end: end)
            return
        }
        var tail = end
        while tail > start, EditorLexicalCursor.horizontal(cursor.units[tail - 1]) {
            tail -= 1
            try cursor.poll()
        }
        if tail - start > 2, cursor.at(start, 91), cursor.at(tail - 1, 93) {
            try cursor.emit(start, .keyword, end: tail)
            return
        }
        var delimiter = start
        while delimiter < tail, !cursor.at(delimiter, 61), !cursor.at(delimiter, 58) {
            delimiter += 1
            try cursor.poll()
        }
        guard delimiter > start, delimiter < tail else { return }
        var keyEnd = delimiter
        while keyEnd > start, EditorLexicalCursor.horizontal(cursor.units[keyEnd - 1]) {
            keyEnd -= 1
            try cursor.poll()
        }
        guard keyEnd > start else { return }
        try cursor.emit(start, .property, end: keyEnd)
        try cursor.emit(delimiter, .punctuation, end: delimiter + 1)
        let value = try cursor.horizontalEnd(delimiter + 1)
        guard value < tail else { return }
        let quote = cursor.units[value]
        if tail - value >= 2, (quote == 34 || quote == 39), cursor.at(tail - 1, quote) {
            try cursor.emit(value, .string, end: tail)
        } else if try cursor.decimal(value, tail) {
            try cursor.emit(value, .number, end: tail)
        } else if tail - value <= 5 {
            let word = String(decoding: cursor.units[value..<tail], as: UTF16.self).lowercased()
            if ["true", "false", "yes", "no", "on", "off"].contains(word) {
                try cursor.emit(value, .literal, end: tail)
            }
        }
    }
}
