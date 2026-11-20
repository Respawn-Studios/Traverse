import Foundation

enum EditorTOMLOutline {
    typealias Entry = EditorDocumentOutline.Entry

    static func read(_ source: NSString, lines: EditorLineIndex, tokens: [TextSyntaxToken],
                     cancelled: () -> Bool) -> (entries: [Entry], limited: Bool) {
        var opaque: [Int: TextSyntaxToken] = [:]
        for (index, token) in tokens.enumerated() {
            if index.isMultiple(of: 128), cancelled() { return ([], true) }
            if token.kind == .string || token.kind == .comment { opaque[token.range.location] = token }
        }
        var entries: [Entry] = [], closes: [UInt16] = []
        var offset = 0, hasTable = false, startsLine = true
        var untilPoll = 0
        while offset < source.length {
            if offset >= untilPoll {
                if cancelled() { return ([], true) }
                untilPoll = offset + 256
            }
            let unit = source.character(at: offset)
            if unit == 10 {
                startsLine = true
            } else if !EditorLexicalCursor.horizontal(unit) {
                if startsLine, closes.isEmpty,
                   let statement = Statement(source, at: offset, opaque: opaque),
                   let location = lines.location(at: offset) {
                    if entries.count == EditorDocumentOutline.maximumEntries { return (entries, true) }
                    if statement.kind == .heading { hasTable = true }
                    entries.append(.init(title: EditorDocumentOutline.title(source, start: statement.keyRange.location,
                        length: statement.keyRange.length), line: location.line, offset: offset,
                        depth: statement.kind == .property && hasTable ? 1 : 0, kind: statement.kind))
                    offset = statement.end
                    startsLine = false
                    continue
                }
                startsLine = false
                if let token = opaque[offset] {
                    offset = NSMaxRange(token.range)
                    continue
                }
                switch unit {
                case 91, 123:
                    guard closes.count < 64 else { return (entries, true) }
                    closes.append(unit == 91 ? 93 : 125)
                case 93, 125:
                    guard closes.popLast() == unit else { return (entries, true) }
                default: break
                }
            }
            offset += 1
        }
        return (entries, !closes.isEmpty)
    }

    private struct Statement {
        let keyRange: NSRange
        let kind: Entry.Kind
        let end: Int

        init?(_ source: NSString, at start: Int, opaque: [Int: TextSyntaxToken]) {
            let limit = min(source.length, start + 1_024)
            func character(_ offset: Int) -> UInt16? { offset < limit ? source.character(at: offset) : nil }
            func spaces(after offset: Int) -> Int {
                var end = offset
                while character(end).map(EditorLexicalCursor.horizontal) == true { end += 1 }
                return end
            }
            func keyUnit(_ unit: UInt16) -> Bool {
                unit == 45 || unit == 95 || (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit)
            }
            func componentEnd(_ offset: Int) -> Int? {
                if let quote = character(offset), quote == 34 || quote == 39 {
                    guard let token = opaque[offset], token.kind == .string, token.range.length >= 2 else { return nil }
                    let end = NSMaxRange(token.range)
                    guard end <= limit, character(end - 1) == quote,
                          !(character(offset + 1) == quote && character(offset + 2) == quote),
                          source.range(of: "\n", options: .literal, range: token.range).location == NSNotFound,
                          source.range(of: "\r", options: .literal, range: token.range).location == NSNotFound else { return nil }
                    return end
                }
                var end = offset
                while character(end).map(keyUnit) == true { end += 1 }
                return end > offset ? end : nil
            }

            let brackets = character(start) == 91 ? (character(start + 1) == 91 ? 2 : 1) : 0
            let keyStart = spaces(after: start + brackets)
            var component = keyStart, keyEnd: Int
            var delimiter: Int
            while true {
                guard let next = componentEnd(component) else { return nil }
                keyEnd = next
                delimiter = spaces(after: next)
                if character(delimiter) != 46 { break }
                component = spaces(after: delimiter + 1)
            }
            keyRange = NSRange(location: keyStart, length: keyEnd - keyStart)
            if brackets == 0 {
                guard character(delimiter) == 61 else { return nil }
                kind = .property
                end = delimiter + 1
            } else {
                guard character(delimiter) == 93, brackets == 1 || character(delimiter + 1) == 93 else { return nil }
                let tail = spaces(after: delimiter + brackets)
                guard tail == source.length || character(tail).map({ [10, 13, 35].contains($0) }) == true else { return nil }
                kind = .heading
                end = delimiter + brackets
            }
        }
    }
}
