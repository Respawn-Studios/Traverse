import Foundation

/// Byte ranges from the original text, including comments and unmodified
/// scalar spellings. Formatting and diagnostics use the same token boundaries.
public enum JSONTextTokens {
    public enum Kind: Equatable {
        case symbol(UInt8), value, lineComment, blockComment
    }

    public struct Token {
        public let range: Range<Int>
        public let kind: Kind
    }

    public struct Incomplete: Error {
        public let offset: Int
        public let comment: Bool
    }

    public static func next(_ input: [UInt8], cursor: inout Int, allowsComments: Bool) throws -> Token? {
        while cursor < input.count && isSpace(input[cursor]) {
            if cursor & 1023 == 0 { try Task.checkCancellation() }
            cursor += 1
        }
        guard cursor < input.count else { return nil }
        let start = cursor
        let first = input[cursor]
        cursor += 1
        if isSymbol(first) { return .init(range: start..<cursor, kind: .symbol(first)) }
        if first == 34 {
            var escaped = false
            while cursor < input.count {
                if cursor & 1023 == 0 { try Task.checkCancellation() }
                let value = input[cursor]
                cursor += 1
                if escaped { escaped = false }
                else if value == 92 { escaped = true }
                else if value == 34 { return .init(range: start..<cursor, kind: .value) }
            }
            throw Incomplete(offset: start, comment: false)
        }
        if allowsComments && first == 47 && cursor < input.count {
            if input[cursor] == 47 {
                cursor += 1
                while cursor < input.count && input[cursor] != 10 && input[cursor] != 13 {
                    if cursor & 1023 == 0 { try Task.checkCancellation() }
                    cursor += 1
                }
                return .init(range: start..<cursor, kind: .lineComment)
            }
            if input[cursor] == 42 {
                cursor += 1
                while cursor < input.count {
                    if cursor & 1023 == 0 { try Task.checkCancellation() }
                    if input[cursor] == 42 && cursor + 1 < input.count && input[cursor + 1] == 47 {
                        cursor += 2
                        return .init(range: start..<cursor, kind: .blockComment)
                    }
                    cursor += 1
                }
                throw Incomplete(offset: start, comment: true)
            }
        }
        while cursor < input.count && !isSpace(input[cursor]) && !isSymbol(input[cursor]) {
            if cursor & 1023 == 0 { try Task.checkCancellation() }
            if allowsComments && input[cursor] == 47 && cursor + 1 < input.count
                && (input[cursor + 1] == 47 || input[cursor + 1] == 42) { break }
            cursor += 1
        }
        return .init(range: start..<cursor, kind: .value)
    }

    /// A same-length strict JSON view for callers that validate with Foundation.
    public static func foundationBytes(_ input: [UInt8], allowsComments: Bool) throws -> [UInt8] {
        guard allowsComments else { return input }
        var result = input
        var cursor = 0
        while let token = try next(input, cursor: &cursor, allowsComments: true) {
            try Task.checkCancellation()
            if token.kind == .lineComment || token.kind == .blockComment {
                for index in token.range where input[index] != 10 && input[index] != 13 { result[index] = 32 }
            }
        }
        cursor = 0
        var previous: Kind?
        while let token = try next(result, cursor: &cursor, allowsComments: false) {
            try Task.checkCancellation()
            if token.kind == .symbol(44), previous == .value || previous == .symbol(125) || previous == .symbol(93) {
                var following = cursor
                if let end = try next(result, cursor: &following, allowsComments: false),
                   end.kind == .symbol(125) || end.kind == .symbol(93) { result[token.range.lowerBound] = 32 }
            }
            previous = token.kind
        }
        return result
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    private static func isSymbol(_ byte: UInt8) -> Bool {
        switch byte {
        case 123, 125, 91, 93, 44, 58: true
        default: false
        }
    }
}
