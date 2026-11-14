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
                     indentsJSONBlocks: Bool = true) -> EditorIndentationPlan {
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
            var end = start
            while end < selection.location {
                let unit = input.character(at: end)
                guard unit == 32 || unit == 9 else { break }
                end += 1
            }
            if indentsJSONBlocks && (language == .json || language == .jsonc) {
                var before = selection.location
                while before > start && [9, 32].contains(input.character(at: before - 1)) { before -= 1 }
                if before > start {
                    let opener = input.character(at: before - 1)
                    if (opener == 123 || opener == 91), jsonCode(at: before - 1, in: input) {
                        let prefix = input.substring(with: .init(location: start, length: end - start))
                        let unit = preferences.insertion == .tabs ? "\t" : String(repeating: " ", count: width)
                        let inner = "\n" + prefix + unit
                        var after = selection.location
                        while after < input.length && [9, 32].contains(input.character(at: after)) { after += 1 }
                        let paired = after < input.length && input.character(at: after) == (opener == 123 ? 125 : 93)
                        let inserted = inner + (paired ? "\n" + prefix : "")
                        // Only whitespace before the matching close is replaced;
                        // its delimiter and all other user characters stay native.
                        let range = NSRange(location: selection.location, length: paired ? after - selection.location : 0)
                        let added = inserted.utf8.count
                        guard added <= maximumBytes, currentBytes - range.length <= maximumBytes - added else {
                            return .refused(.tooLarge)
                        }
                        return .replace(.init(range: range, text: inserted,
                            selection: .init(location: selection.location + inner.utf16.count, length: 0)))
                    }
                }
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

    /// Return must retain native typing order. Bound the synchronous lexical
    /// lookbehind rather than trusting asynchronous, potentially stale syntax.
    /// Beyond this prefix budget Return still continues existing indentation.
    static func jsonCode(at target: Int, in input: NSString) -> Bool {
        guard target < 65_536 else { return false }
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
