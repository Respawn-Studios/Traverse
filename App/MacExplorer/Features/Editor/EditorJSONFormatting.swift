import Foundation
import FileOperations

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
            let validation = try JSONTextTokens.foundationBytes(input, allowsComments: allowsComments)
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
            while let token = try JSONTextTokens.next(input, cursor: &cursor, allowsComments: allowsComments) {
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
        catch is JSONTextTokens.Incomplete { return .refused(.cannotFormatJSON) }
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

    private typealias Kind = JSONTextTokens.Kind
    private enum Spacing { case none, space, line }
    private struct TooLarge: Error {}
}
