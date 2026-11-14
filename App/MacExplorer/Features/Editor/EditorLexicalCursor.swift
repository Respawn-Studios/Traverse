import Foundation

/// Shared mechanics for the presentation-only language passes. Offsets are
/// canonical UTF-16 units; every scan retains the same token/cancellation bounds.
enum EditorLexicalStop: Error {
    case cancelled, tokenBudget
    var result: TextSyntaxResult {
        switch self {
        case .cancelled: .plain(.cancelled)
        case .tokenBudget: .plain(.tokenBudget)
        }
    }
}

struct EditorLexicalCursor {
    let units: [UInt16]
    let cancelled: @Sendable () -> Bool
    var index = 0
    private var checked = 0
    private(set) var tokens: [TextSyntaxToken] = []

    init(_ units: [UInt16], cancelled: @escaping @Sendable () -> Bool) {
        self.units = units; self.cancelled = cancelled
        tokens.reserveCapacity(min(2048, units.count / 4))
    }
    func at(_ offset: Int, _ unit: UInt16) -> Bool {
        offset >= 0 && offset < units.count && units[offset] == unit
    }
    static func horizontal(_ unit: UInt16) -> Bool { unit == 9 || unit == 32 }
    static func white(_ unit: UInt16) -> Bool { horizontal(unit) || unit == 10 || unit == 13 }
    static func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    static func name(_ unit: UInt16) -> Bool {
        unit == 95 || unit == 45 || (65...90).contains(unit) || (97...122).contains(unit) || unit >= 128
    }
    mutating func poll(_ amount: Int = 1) throws {
        checked += amount
        if checked >= 256 {
            checked = 0
            if cancelled() { throw EditorLexicalStop.cancelled }
        }
    }
    mutating func advance(_ amount: Int = 1) throws {
        index += amount
        try poll(amount)
    }
    mutating func emit(_ start: Int, _ kind: TextSyntaxToken.Kind, end: Int? = nil) throws {
        let finish = end ?? index
        guard finish > start else { return }
        guard tokens.count < TextSyntax.maximumTokens else { throw EditorLexicalStop.tokenBudget }
        tokens.append(.init(range: .init(location: start, length: finish - start), kind: kind))
    }
    mutating func horizontalEnd(_ start: Int) throws -> Int {
        var end = start
        while end < units.count && Self.horizontal(units[end]) { end += 1; try poll() }
        return end
    }
    func finish() -> TextSyntaxResult { cancelled() ? .plain(.cancelled) : .tokens(tokens) }

    /// Complete simple decimal lexemes only; no valid-looking prefix on 12oops,
    /// dates, units or incomplete exponents. A second linear pass is bounded.
    mutating func decimal(_ start: Int, _ end: Int) throws -> Bool {
        var next = start
        if at(next, 43) || at(next, 45) { next += 1; try poll() }
        let integer = next
        while next < end && Self.digit(units[next]) { next += 1; try poll() }
        guard next > integer else { return false }
        if next < end && at(next, 46) {
            next += 1; try poll()
            let fraction = next
            while next < end && Self.digit(units[next]) { next += 1; try poll() }
            guard next > fraction else { return false }
        }
        if next < end && (at(next, 69) || at(next, 101)) {
            next += 1; try poll()
            if next < end && (at(next, 43) || at(next, 45)) { next += 1; try poll() }
            let exponent = next
            while next < end && Self.digit(units[next]) { next += 1; try poll() }
            guard next > exponent else { return false }
        }
        return next == end
    }
}
