import Foundation

/// Share the lexical bracket rules between explicit bracket navigation and
/// the prepared outline. String, comment and property tokens own their text.
enum EditorDelimiterWalk {
    struct Pair: Sendable {
        let opening: Int
        let closing: Int
        let openingUnit: UInt16
        let insideExpression: Bool
    }

    struct MatchIndex: Sendable {
        private let counterparts: [Int: Int]

        init(_ pairs: [Pair]) {
            var values: [Int: Int] = [:]
            values.reserveCapacity(pairs.count * 2)
            for pair in pairs {
                values[pair.opening] = pair.closing
                values[pair.closing] = pair.opening
            }
            counterparts = values
        }

        func matchingOffsets(at selection: NSRange) -> (Int, Int)? {
            guard selection.location >= 0, (0...1).contains(selection.length) else { return nil }
            if let other = counterparts[selection.location] { return (selection.location, other) }
            let preceding = selection.location - 1
            guard selection.length == 0, preceding >= 0, let other = counterparts[preceding] else { return nil }
            return (preceding, other)
        }
    }

    struct Capture: Sendable {
        let pairs: [Pair]
        let matches: MatchIndex
    }

    enum Completion { case complete, stopped, cancelled, depthLimit }

    private struct Opening {
        let offset: Int
        let unit: UInt16
        let expected: UInt16
        let insideExpression: Bool
    }

    static func capture(in source: String, syntax: TextSyntaxResult, cancelled: () -> Bool) -> Capture? {
        let input = source as NSString
        guard input.length <= 131_072, case .tokens(let tokens) = syntax else { return nil }
        var captured: [Pair] = []
        let result = pairs(in: input, tokens: tokens, cancelled: cancelled) { pair in
            guard captured.count < 8_192 else { return false }
            captured.append(pair)
            return true
        }
        guard case .complete = result else { return nil }
        return .init(pairs: captured, matches: .init(captured))
    }

    static func pairs(in input: NSString, tokens: [TextSyntaxToken], cancelled: () -> Bool,
                      visit: (Pair) -> Bool) -> Completion {
        var ignored = tokens.lazy.filter { $0.kind == .comment || $0.kind == .string || $0.kind == .property }.makeIterator()
        var hidden = ignored.next()
        var stack: [Opening] = []
        var cursor = 0, nextCheck = 0
        while cursor < input.length {
            if cursor >= nextCheck {
                if cancelled() { return .cancelled }
                nextCheck = cursor + 256
            }
            if let token = hidden, token.range.location == cursor {
                cursor = NSMaxRange(token.range)
                hidden = ignored.next()
                continue
            }
            let offset = cursor
            cursor += 1
            let unit = input.character(at: offset)
            switch unit {
            case 40, 91, 123:
                guard stack.count < 256 else { return .depthLimit }
                let insideExpression = stack.last.map { $0.insideExpression || $0.unit != 123 } ?? false
                stack.append(.init(offset: offset, unit: unit, expected: unit == 40 ? 41 : unit == 91 ? 93 : 125,
                    insideExpression: insideExpression))
            case 41, 93, 125:
                guard let open = stack.popLast(), unit == open.expected else {
                    stack.removeAll(keepingCapacity: true)
                    continue
                }
                if !visit(.init(opening: open.offset, closing: offset, openingUnit: open.unit,
                               insideExpression: open.insideExpression)) { return .stopped }
            default: continue
            }
        }
        return .complete
    }
}
