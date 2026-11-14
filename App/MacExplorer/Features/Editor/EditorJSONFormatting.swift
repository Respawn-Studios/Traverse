import Foundation

enum EditorJSONFormat: Equatable, Sendable {
    case indented(EditorIndentationPreferences), compact
}

/// Foundation validates a disposable view of the syntax; it never serializes
/// the object graph. Output copies original token/comment bytes, preserving
/// duplicate keys, order, escapes, numeric spellings and JSONC trailing commas.
enum EditorJSONFormatting {
    static func plan(_ style: EditorJSONFormat, text: String, selection: NSRange,
                     maximumBytes: Int, allowsComments: Bool = false) -> EditorLineCommandPlan {
        guard maximumBytes >= 0, text.utf8.count <= maximumBytes else { return .refused(.tooLarge) }
        let length = text.utf16.count
        guard selection.location >= 0, selection.length >= 0, selection.location <= length,
              selection.length <= length - selection.location,
              let selected = Range(selection, in: text) else { return .refused(.invalidSelection) }
        let lower = text.utf8.distance(from: text.utf8.startIndex, to: selected.lowerBound)
        let upper = text.utf8.distance(from: text.utf8.startIndex, to: selected.upperBound)
        let pretty: Bool, indent: [UInt8]
        switch style {
        case .compact: pretty = false; indent = []
        case .indented(let value):
            guard value.isValid else { return .refused(.invalidSelection) }
            pretty = true
            indent = value.insertion == .tabs ? [9] : Array(repeating: 32, count: value.columns)
        }
        guard !Task.isCancelled else { return .unchanged }
        let input = Array(text.utf8)
        do {
            let validation = try validatedSyntax(input, allowsComments: allowsComments)
            try autoreleasepool { _ = try JSONSerialization.jsonObject(with: Data(validation), options: [.fragmentsAllowed]) }
        } catch is CancellationError { return .unchanged }
        catch { return .refused(.cannotFormatJSON) }
        guard !Task.isCancelled else { return .unchanged }
        var output: [UInt8] = []; output.reserveCapacity(min(maximumBytes, input.count))
        var cursor = 0, previousEnd = 0, depth = 0
        var pending = Spacing.none, previous: Kind?
        var selectedLower: Int?, selectedUpper: Int?
        func append(_ bytes: ArraySlice<UInt8>) throws {
            guard bytes.count <= maximumBytes - output.count else { throw TooLarge() }
            output.append(contentsOf: bytes)
        }
        func byte(_ value: UInt8) throws {
            guard output.count < maximumBytes else { throw TooLarge() }
            output.append(value)
        }
        func spacing(_ value: Spacing) throws {
            guard !output.isEmpty else { return }
            if value == .line {
                let amount = depth * indent.count
                guard amount < maximumBytes - output.count else { throw TooLarge() }
                try byte(10)
                for _ in 0..<depth { try append(indent[...]) }
            } else if value == .space { try byte(32) }
        }
        do {
            while let token = try next(input, cursor: &cursor, allowsComments: allowsComments) {
                try Task.checkCancellation()
                let startsLine = input[previousEnd..<token.range.lowerBound].contains { $0 == 10 || $0 == 13 }
                var separation = pending
                switch token.kind {
                case .symbol(let value) where value == 125 || value == 93:
                    depth -= 1
                    guard depth >= 0 else { return .refused(.cannotFormatJSON) }
                    if pretty, previous != .symbol(value == 125 ? 123 : 91) { separation = .line }
                    else if pretty { separation = .none }
                case .lineComment, .blockComment:
                    if pretty && (startsLine || pending == .line) { separation = .line }
                    else if pending != .line { separation = .space }
                default:
                    if pretty, previous == .blockComment, startsLine { separation = .line }
                }
                try spacing(separation)
                if selectedLower == nil, lower < token.range.lowerBound { selectedLower = output.count }
                if selectedUpper == nil, upper < token.range.lowerBound { selectedUpper = output.count }
                if selectedLower == nil, token.range.contains(lower) || lower == token.range.upperBound {
                    selectedLower = output.count + lower - token.range.lowerBound
                }
                if selectedUpper == nil, token.range.contains(upper) || upper == token.range.upperBound {
                    selectedUpper = output.count + upper - token.range.lowerBound
                }
                try append(input[token.range])
                switch token.kind {
                case .symbol(123), .symbol(91):
                    depth += 1
                    guard depth <= 512 else { return .refused(.cannotFormatJSON) }
                    pending = pretty ? .line : .none
                case .symbol(44): pending = pretty ? .line : .none
                case .symbol(58): pending = pretty ? .space : .none
                case .lineComment: pending = .line // Required even for Compact: don't swallow the next token.
                case .blockComment: pending = pretty ? .space : .none
                default: pending = .none
                }
                previous = token.kind; previousEnd = token.range.upperBound
            }
            if pretty && input.last == 10 { try byte(10) }
        } catch is CancellationError { return .unchanged }
        catch is InvalidSyntax { return .refused(.cannotFormatJSON) }
        catch { return .refused(.tooLarge) }
        if lower == input.count { selectedLower = output.count }
        if upper == input.count { selectedUpper = output.count }
        guard !Task.isCancelled else { return .unchanged }
        let formatted = String(decoding: output, as: UTF8.self)
        if formatted.utf16.elementsEqual(text.utf16) { return .unchanged }
        let location = String(decoding: output.prefix(selectedLower ?? output.count), as: UTF8.self).utf16.count
        let end = String(decoding: output.prefix(selectedUpper ?? output.count), as: UTF8.self).utf16.count
        return .replace(.init(range: .init(location: 0, length: text.utf16.count), text: formatted,
                              selection: .init(location: location, length: max(0, end - location))))
    }

    private enum Kind: Equatable { case symbol(UInt8), value, lineComment, blockComment }
    private enum Spacing { case none, space, line }
    private struct Token { let range: Range<Int>, kind: Kind }
    private struct TooLarge: Error {}
    private struct InvalidSyntax: Error {}
    private static func space(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    private static func symbol(_ byte: UInt8) -> Bool {
        switch byte { case 123, 125, 91, 93, 44, 58: true; default: false }
    }

    /// Incremental lexical view; it never builds a second object/token graph.
    private static func next(_ input: [UInt8], cursor: inout Int, allowsComments: Bool) throws -> Token? {
        while cursor < input.count && space(input[cursor]) {
            if cursor & 1023 == 0 { try Task.checkCancellation() }
            cursor += 1
        }
        guard cursor < input.count else { return nil }
        let start = cursor, first = input[cursor]; cursor += 1
        if symbol(first) { return Token(range: start..<cursor, kind: .symbol(first)) }
        if first == 34 {
            var escaped = false
            while cursor < input.count {
                if cursor & 1023 == 0 { try Task.checkCancellation() }
                let value = input[cursor]; cursor += 1
                if escaped { escaped = false }
                else if value == 92 { escaped = true }
                else if value == 34 { return Token(range: start..<cursor, kind: .value) }
            }
            throw InvalidSyntax()
        }
        if allowsComments && first == 47 && cursor < input.count {
            if input[cursor] == 47 {
                cursor += 1
                while cursor < input.count && input[cursor] != 10 && input[cursor] != 13 {
                    if cursor & 1023 == 0 { try Task.checkCancellation() }; cursor += 1
                }
                return Token(range: start..<cursor, kind: .lineComment)
            }
            if input[cursor] == 42 {
                cursor += 1
                while cursor < input.count {
                    if cursor & 1023 == 0 { try Task.checkCancellation() }
                    if input[cursor] == 42 && cursor + 1 < input.count && input[cursor + 1] == 47 {
                        cursor += 2; return Token(range: start..<cursor, kind: .blockComment)
                    }
                    cursor += 1
                }
                throw InvalidSyntax()
            }
        }
        while cursor < input.count && !space(input[cursor]) && !symbol(input[cursor]) {
            if cursor & 1023 == 0 { try Task.checkCancellation() }
            if allowsComments && input[cursor] == 47 && cursor + 1 < input.count
                && (input[cursor + 1] == 47 || input[cursor + 1] == 42) { break }
            cursor += 1
        }
        return Token(range: start..<cursor, kind: .value)
    }

    private static func validatedSyntax(_ input: [UInt8], allowsComments: Bool) throws -> [UInt8] {
        guard allowsComments else { return input }
        var result = input, cursor = 0
        while let token = try next(input, cursor: &cursor, allowsComments: true) {
            if token.kind == .lineComment || token.kind == .blockComment {
                for index in token.range where input[index] != 10 && input[index] != 13 { result[index] = 32 }
            }
        }
        cursor = 0
        var previous: Kind?
        while let token = try next(result, cursor: &cursor, allowsComments: false) {
            if token.kind == .symbol(44), previous == .value || previous == .symbol(125) || previous == .symbol(93) {
                var following = cursor
                if let end = try next(result, cursor: &following, allowsComments: false),
                   end.kind == .symbol(125) || end.kind == .symbol(93) { result[token.range.lowerBound] = 32 }
            }
            previous = token.kind
        }
        return result
    }
}
