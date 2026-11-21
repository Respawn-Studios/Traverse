import Foundation
import FileOperations

enum EditorJSONFormat: Equatable, Sendable {
    case indented(EditorIndentationPreferences), asWritten(EditorIndentationPreferences), compact
}

/// Foundation validates a disposable view of the syntax; it never serializes
/// the object graph. Output copies original token/comment bytes, preserving
/// duplicate keys, order, escapes, numeric spellings and JSONC trailing commas.
enum EditorJSONFormatting {
    static func repairDelimiter(in text: String, maximumBytes: Int, allowsComments: Bool) -> EditorLineCommandPlan {
        guard text.utf8.count < maximumBytes else { return .refused(.tooLarge) }
        do {
            guard let fix = try LocalJSONCheck.singleDelimiterRepair(in: text, allowsComments: allowsComments) else {
                return .refused(.noJSONDelimiterRepair)
            }
            return .replace(.init(range: .init(location: fix.offset, length: 0), text: fix.delimiter.rawValue,
                                  selection: .init(location: fix.offset + 1, length: 0)))
        } catch is CancellationError { return .unchanged }
        catch { return .refused(.noJSONDelimiterRepair) }
    }

    static func plan(_ style: EditorJSONFormat, text: String, selection: NSRange,
                     maximumBytes: Int, allowsComments: Bool = false) -> EditorLineCommandPlan {
        guard maximumBytes >= 0, text.utf8.count <= maximumBytes else { return .refused(.tooLarge) }
        let length = text.utf16.count
        guard selection.location >= 0, selection.length >= 0, selection.location <= length,
              selection.length <= length - selection.location,
              let selected = Range(selection, in: text) else { return .refused(.invalidSelection) }
        let lower = text.utf8.distance(from: text.utf8.startIndex, to: selected.lowerBound)
        let upper = text.utf8.distance(from: text.utf8.startIndex, to: selected.upperBound)
        let pretty: Bool, tolerant: Bool, indent: [UInt8]
        switch style {
        case .compact: pretty = false; tolerant = false; indent = []
        case .indented(let value), .asWritten(let value):
            guard value.isValid else { return .refused(.invalidSelection) }
            pretty = true
            tolerant = if case .asWritten = style { true } else { false }
            indent = value.insertion == .tabs ? [9] : Array(repeating: 32, count: value.columns)
        }
        guard !Task.isCancelled else { return .unchanged }
        let input = Array(text.utf8)
        if !tolerant {
            do {
                let validation = try JSONTextTokens.foundationBytes(input, allowsComments: allowsComments)
                try autoreleasepool { _ = try JSONSerialization.jsonObject(with: Data(validation), options: [.fragmentsAllowed]) }
            } catch is CancellationError { return .unchanged }
            catch { return .refused(.cannotFormatJSON) }
        }
        guard !Task.isCancelled else { return .unchanged }
        var output: [UInt8] = []; output.reserveCapacity(min(maximumBytes, input.count))
        var cursor = 0, previousEnd = 0, openers: [UInt8] = []
        var pending = Spacing.none, previous: Kind?, previousSyntax: Kind?
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
                let amount = openers.count * indent.count
                guard amount < maximumBytes - output.count else { throw TooLarge() }
                try byte(10)
                for _ in openers { try append(indent[...]) }
            } else if value == .space { try byte(32) }
        }
        do {
            while let token = try JSONTextTokens.next(input, cursor: &cursor, allowsComments: allowsComments) {
                try Task.checkCancellation()
                let originalSpacing = input[previousEnd..<token.range.lowerBound]
                let startsLine = originalSpacing.contains { $0 == 10 || $0 == 13 }
                var separation = pending
                switch token.kind {
                case .symbol(let value) where value == 125 || value == 93:
                    let opening: UInt8 = value == 125 ? 123 : 91
                    if openers.last == opening { openers.removeLast() }
                    else if !tolerant { return .refused(.cannotFormatJSON) }
                    if pretty, previous != .symbol(opening) { separation = .line }
                    else if pretty { separation = .none }
                case .lineComment, .blockComment:
                    if pretty && (startsLine || pending == .line) { separation = .line }
                    else if pending != .line { separation = .space }
                default:
                    if pretty, previous == .blockComment, startsLine { separation = .line }
                }
                if tolerant, let container = openers.last, Self.canEndValue(previousSyntax) {
                    if container == 91, token.kind == .value || token.kind == .symbol(91) || token.kind == .symbol(123) {
                        separation = .line
                    } else if container == 123, token.kind == .value, input[token.range.lowerBound] == 34,
                              try Self.followedByColon(input, after: cursor, allowsComments: allowsComments) {
                        separation = .line
                    }
                }
                // In malformed inputs, removing a separator could turn
                // two tokens such as 1 and 2 into a single number.
                if tolerant, separation == .none, !originalSpacing.isEmpty, previous == .value, token.kind == .value {
                    separation = startsLine ? .line : .space
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
                case .symbol(let value) where value == 123 || value == 91:
                    guard openers.count < 512 else { return .refused(.cannotFormatJSON) }
                    openers.append(value)
                    pending = pretty ? .line : .none
                case .symbol(44): pending = pretty ? .line : .none
                case .symbol(58): pending = pretty ? .space : .none
                case .lineComment: pending = .line // Required even for Compact: don't swallow the next token.
                case .blockComment: pending = pretty ? .space : .none
                default: pending = .none
                }
                if token.kind != .lineComment && token.kind != .blockComment { previousSyntax = token.kind }
                previous = token.kind; previousEnd = token.range.upperBound
            }
            if pretty && input.last == 10 { try byte(10) }
        } catch is CancellationError { return .unchanged }
        catch is JSONTextTokens.Incomplete {
            guard tolerant else { return .refused(.cannotFormatJSON) }
            // A partially typed string or comment has no safe token end.
            // Format the preceding tokens and keep its original tail intact.
            if selectedLower == nil { selectedLower = output.count + lower - previousEnd }
            if selectedUpper == nil { selectedUpper = output.count + upper - previousEnd }
            do { try append(input[previousEnd...]) }
            catch { return .refused(.tooLarge) }
        }
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

    private static func canEndValue(_ kind: Kind?) -> Bool {
        kind == .value || kind == .symbol(93) || kind == .symbol(125)
    }

    private static func followedByColon(_ input: [UInt8], after end: Int, allowsComments: Bool) throws -> Bool {
        var cursor = end
        do {
            while let next = try JSONTextTokens.next(input, cursor: &cursor, allowsComments: allowsComments) {
                if next.kind != .lineComment && next.kind != .blockComment { return next.kind == .symbol(58) }
            }
        } catch is JSONTextTokens.Incomplete {
            // The main pass preserves this unfinished string or comment.
            return false
        }
        return false
    }

    private enum Spacing { case none, space, line }
    private struct TooLarge: Error {}
}
