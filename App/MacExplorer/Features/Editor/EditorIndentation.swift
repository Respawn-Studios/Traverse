import Foundation

struct EditorIndentationPreferences: Codable, Equatable, Sendable {
    enum Insertion: String, Codable, Sendable { case spaces, tabs }
    var columns: Int
    var insertion: Insertion
    var continuesIndentation: Bool

    static let fresh = Self(columns: 4, insertion: .spaces, continuesIndentation: true)
    static let legacy = Self(columns: 4, insertion: .tabs, continuesIndentation: false)
    var isValid: Bool { [2, 4, 8].contains(columns) }
}

enum EditorIndentationCommand: Sendable { case indent, outdent, newline }

struct EditorIndentationReplacement: Equatable, Sendable {
    let range: NSRange
    let text: String
    let selection: NSRange
}

enum EditorIndentationPlan: Equatable, Sendable {
    enum Refusal: Equatable, Sendable { case invalidSelection, invalidPreferences, tooLarge }
    case native
    case unchanged
    case refused(Refusal)
    case replace(EditorIndentationReplacement)
}

/// Pure editing proposal only. The caller retains native input, admission,
/// Undo and generation delivery. No plan installs attributes or changes text.
enum EditorIndentation {
    private static let braceLanguages: Set<TextSyntaxLanguage> = [
        .swift, .rust, .javascript, .typescript, .c, .cpp, .objectiveC, .objectiveCPP, .css, .go
    ]
    static let lexicalInputLimit = 65_536

    static func supportsCodeStructure(_ language: TextSyntaxLanguage) -> Bool {
        language == .python || braceLanguages.contains(language)
    }

    /// A bounded leading-space lookbehind, independent of asynchronous syntax
    /// and line indexing. Mixed whitespace and ordinary content stay native.
    static func backspaceRange(in input: NSString, selection: NSRange,
                               preferences: EditorIndentationPreferences) -> NSRange? {
        guard preferences.isValid, preferences.insertion == .spaces,
              selection.length == 0, selection.location > 0,
              selection.location <= input.length else { return nil }
        var start = selection.location
        while start > 0, input.character(at: start - 1) != 10 {
            guard selection.location - start < 1024,
                  input.character(at: start - 1) == 32 else { return nil }
            start -= 1
        }
        let columns = selection.location - start
        let remainder = columns % preferences.columns
        let count = remainder == 0 ? min(columns, preferences.columns) : remainder
        guard count > 1 else { return nil }
        return .init(location: selection.location - count, length: count)
    }

    static func plan(_ command: EditorIndentationCommand, text: String,
                     selection: NSRange, preferences: EditorIndentationPreferences,
                     maximumBytes: Int, language: TextSyntaxLanguage = .plain,
                     indentsJSONBlocks: Bool = true, indentsCodeBlocks: Bool = true) -> EditorIndentationPlan {
        guard preferences.isValid else { return .refused(.invalidPreferences) }
        let currentBytes = text.utf8.count
        guard maximumBytes >= 0, currentBytes <= maximumBytes else { return .refused(.tooLarge) }
        let input = text as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= input.length,
              selection.length <= input.length - selection.location,
              Range(selection, in: text) != nil else { return .refused(.invalidSelection) }
        func scalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < input.length else { return true }
            return !((0xD800...0xDBFF).contains(input.character(at: offset - 1))
                     && (0xDC00...0xDFFF).contains(input.character(at: offset)))
        }
        guard scalarBoundary(selection.location), scalarBoundary(NSMaxRange(selection)) else {
            return .refused(.invalidSelection)
        }

        func lineStart(_ offset: Int) -> Int {
            var start = offset
            while start > 0 && input.character(at: start - 1) != 10 { start -= 1 }
            return start
        }
        func insertion(_ inserted: String) -> EditorIndentationPlan {
            let added = inserted.utf8.count
            guard added <= maximumBytes, currentBytes <= maximumBytes - added else { return .refused(.tooLarge) }
            return .replace(.init(range: selection, text: inserted,
                                  selection: .init(location: selection.location + inserted.utf16.count, length: 0)))
        }
        let width = preferences.columns

        if case .newline = command {
            guard selection.length == 0 else { return .native }
            let start = lineStart(selection.location)
            let end = pastIndentation(in: input, from: start, to: selection.location)
            if let block = blockOpening(in: input, lineStart: start, caret: selection.location,
                    language: language, allowsJSON: indentsJSONBlocks, allowsCode: indentsCodeBlocks) {
                let baseEnd = pastIndentation(in: input, from: block.lineStart, to: selection.location)
                let prefix = input.substring(with: .init(location: block.lineStart, length: baseEnd - block.lineStart))
                let unit = preferences.insertion == .tabs ? "\t" : String(repeating: " ", count: width)
                let inner = "\n" + prefix + unit
                let after = pastIndentation(in: input, from: selection.location, to: input.length)
                let paired = after < input.length && block.closer == input.character(at: after)
                let inserted = inner + (paired ? "\n" + prefix : "")
                // Only whitespace before the closing delimiter is replaced.
                let range = NSRange(location: selection.location, length: paired ? after - selection.location : 0)
                let added = inserted.utf8.count
                guard added <= maximumBytes, currentBytes - range.length <= maximumBytes - added else {
                    return .refused(.tooLarge)
                }
                return .replace(.init(range: range, text: inserted,
                    selection: .init(location: selection.location + inner.utf16.count, length: 0)))
            }
            guard preferences.continuesIndentation, end > start else { return .native }
            // Leading spaces/tabs are ASCII, so their byte and UTF-16 counts
            // agree. Refuse before constructing a repeated oversized prefix.
            let added = end - start + 1
            guard added <= maximumBytes, currentBytes <= maximumBytes - added else { return .refused(.tooLarge) }
            return insertion("\n" + input.substring(with: .init(location: start, length: end - start)))
        }

        if selection.length == 0, case .indent = command {
            guard preferences.insertion == .spaces else { return .native }
            let start = lineStart(selection.location)
            var position = start, column = 0
            while position < selection.location {
                let unit = input.character(at: position)
                if unit == 32 { column += 1 }
                else if unit == 9 { column += width - column % width }
                else { break }
                position += 1
            }
            let count = position == selection.location ? width - column % width : width
            return insertion(String(repeating: " ", count: count))
        }

        let start = lineStart(selection.location)
        // A selection ending at the next line's start does not touch that line.
        // NSString scans code units; only complete logical-line boundaries are
        // later used to construct String ranges.
        let last = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
        var end = last
        while end < input.length && input.character(at: end) != 10 { end += 1 }
        if end < input.length { end += 1 }

        struct Line {
            let range: NSRange
            let removedPrefix: Int
        }
        var lines: [Line] = []
        var position = start, removedBytes = 0, addedBytes = 0
        let indent = preferences.insertion == .spaces ? String(repeating: " ", count: width) : "\t"
        repeat {
            var next = position
            while next < end && input.character(at: next) != 10 { next += 1 }
            if next < end { next += 1 }
            var removed = 0
            if case .outdent = command, position < next {
                if input.character(at: position) == 9 { removed = 1 }
                else {
                    while removed < width && position + removed < next
                        && input.character(at: position + removed) == 32 { removed += 1 }
                }
            }
            lines.append(.init(range: .init(location: position, length: next - position), removedPrefix: removed))
            removedBytes += removed
            if case .indent = command {
                let amount = indent.utf8.count
                guard amount <= maximumBytes - addedBytes else { return .refused(.tooLarge) }
                addedBytes += amount
            }
            position = next
        } while position < end

        if case .outdent = command, removedBytes == 0 { return .unchanged }
        guard addedBytes <= maximumBytes,
              currentBytes - removedBytes <= maximumBytes - addedBytes else { return .refused(.tooLarge) }
        let span = NSRange(location: start, length: end - start)
        guard let swiftSpan = Range(span, in: text) else { return .refused(.invalidSelection) }
        let spanBytes = text[swiftSpan].utf8.count
        var replacement = ""
        replacement.reserveCapacity(spanBytes - removedBytes + addedBytes)
        for line in lines {
            if case .indent = command { replacement += indent }
            replacement += input.substring(with: .init(location: line.range.location + line.removedPrefix,
                                                       length: line.range.length - line.removedPrefix))
        }
        let resultSelection: NSRange
        if selection.length == 0 {
            let removed = lines[0].removedPrefix
            resultSelection = .init(location: max(start, selection.location - removed), length: 0)
        } else {
            resultSelection = .init(location: start, length: replacement.utf16.count)
        }
        return .replace(.init(range: span, text: replacement, selection: resultSelection))
    }

    private static func pastIndentation(in input: NSString, from start: Int, to limit: Int) -> Int {
        var end = start
        while end < limit, isIndentation(input.character(at: end)) { end += 1 }
        return end
    }

    private static func isIndentation(_ unit: UInt16) -> Bool { unit == 9 || unit == 32 }

    private struct BlockOpening {
        let lineStart: Int
        let closer: UInt16?
    }

    private static func blockOpening(in input: NSString, lineStart: Int, caret: Int,
                                     language: TextSyntaxLanguage, allowsJSON: Bool, allowsCode: Bool) -> BlockOpening? {
        let isJSON = allowsJSON && (language == .json || language == .jsonc)
        let isCode = allowsCode && supportsCodeStructure(language)
        guard isJSON || isCode else { return nil }
        var before = caret
        while before > lineStart, isIndentation(input.character(at: before - 1)) { before -= 1 }
        guard before > lineStart else { return nil }
        let marker = before - 1
        let opener = input.character(at: marker)
        if isJSON {
            guard (opener == 123 || opener == 91), jsonCode(at: marker, in: input) else { return nil }
            return .init(lineStart: lineStart, closer: opener == 123 ? 125 : 93)
        }
        guard opener == (language == .python ? 58 : 123),
              let opaque = codeRanges(at: marker, lineStart: lineStart, in: input, language: language) else { return nil }
        if language == .python {
            guard let header = pythonHeaderStart(in: input, endingAt: marker, skipping: opaque) else { return nil }
            return .init(lineStart: header, closer: nil)
        }
        return .init(lineStart: lineStart, closer: 125)
    }

    /// Input may arrive before the debounced syntax presentation. Lex the
    /// exact bounded prefix when a structural keystroke needs context.
    static func codeRanges(at marker: Int, lineStart: Int, in input: NSString, language: TextSyntaxLanguage,
                           checkingRustCharacter: Bool = false) -> [NSRange]? {
        guard marker >= lineStart, marker < input.length, marker < lexicalInputLimit,
              case .tokens(let tokens) = TextSyntax.contextTokens(input.substring(to: marker + 1), language: language) else { return nil }
        let opaque = tokens.compactMap { token in token.kind == .string || token.kind == .comment ? token.range : nil }
        guard !opaque.contains(where: { NSLocationInRange(marker, $0) }) else { return nil }
        if [.css, .c, .cpp, .objectiveC, .objectiveCPP].contains(language),
           !tokens.contains(where: { $0.kind == .punctuation && $0.range.location == marker }) { return nil }

        let script = language == .javascript || language == .typescript
        let checksSlash = language == .swift || script
        let checksQuote = language == .rust && checkingRustCharacter
        if checksSlash || checksQuote {
            // The highlighting lexer cannot identify every bare regex or an
            // incomplete Rust character literal. Leave those keystrokes native.
            var skip = 0
            for offset in lineStart..<marker {
                let unit = input.character(at: offset)
                guard checksSlash && unit == 47 || checksQuote && unit == 39 else { continue }
                while skip < opaque.count, NSMaxRange(opaque[skip]) <= offset { skip += 1 }
                if skip < opaque.count, NSLocationInRange(offset, opaque[skip]) { continue }
                if unit == 39 || script || !isIndentation(input.character(at: offset + 1)) { return nil }
            }
        }
        return opaque
    }

    private static func pythonHeaderStart(in input: NSString, endingAt colon: Int, skipping opaque: [NSRange]) -> Int? {
        var start = 0, offset = 0, skip = 0, lastCodeOffset = -2
        var closes: [UInt16] = []
        while offset < colon {
            if skip < opaque.count, offset == opaque[skip].location {
                offset = NSMaxRange(opaque[skip])
                skip += 1
                continue
            }
            switch input.character(at: offset) {
            case 40: closes.append(41)
            case 91: closes.append(93)
            case 123: closes.append(125)
            case 41, 93, 125:
                guard closes.popLast() == input.character(at: offset) else { return nil }
            case 10 where closes.isEmpty:
                let continued = lastCodeOffset == offset - 1 && input.character(at: lastCodeOffset) == 92
                if !continued { start = offset + 1 }
            default: break
            }
            guard closes.count <= 128 else { return nil }
            lastCodeOffset = offset
            offset += 1
        }
        guard closes.isEmpty else { return nil }
        let first = pastIndentation(in: input, from: start, to: colon)
        var header = input.substring(with: .init(location: first, length: colon - first))[...]
        func nextWord() -> Substring {
            header = header.drop(while: { $0 == " " || $0 == "\t" })
            let word = header.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            header = header.dropFirst(word.count)
            return word
        }
        let keyword = nextWord()
        if keyword == "async", !["def", "for", "with"].contains(nextWord()) { return nil }
        let remainder = header.drop(while: { $0 == " " || $0 == "\t" })
        switch keyword {
        case "try", "else", "finally": return remainder.isEmpty ? start : nil
        case "except": return start
        case "class", "def", "async", "if", "elif", "for", "while", "with", "match", "case":
            return remainder.isEmpty ? nil : start
        default: return nil
        }
    }

    /// Return must retain native typing order. Bound the synchronous lexical
    /// lookbehind rather than trusting asynchronous, potentially stale syntax.
    /// Beyond this prefix budget Return still continues existing indentation.
    static func jsonCode(at target: Int, in input: NSString) -> Bool {
        guard target < lexicalInputLimit else { return false }
        enum State { case code, string, lineComment, blockComment }
        var state = State.code, position = 0
        while position < target {
            let unit = input.character(at: position)
            let next = position + 1 < input.length ? input.character(at: position + 1) : 0
            switch state {
            case .code:
                if unit == 34 { state = .string }
                else if unit == 47 && next == 47 { state = .lineComment; position += 1 }
                else if unit == 47 && next == 42 { state = .blockComment; position += 1 }
            case .string:
                if unit == 92 { position += 1 }
                else if unit == 34 { state = .code }
            case .lineComment:
                if unit == 10 { state = .code }
            case .blockComment:
                if unit == 42 && next == 47 { state = .code; position += 1 }
            }
            position += 1
        }
        return state == .code
    }
}
