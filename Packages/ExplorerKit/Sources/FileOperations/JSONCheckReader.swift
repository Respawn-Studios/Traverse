import Foundation

struct JSONCheckLimit: Error {}

struct JSONCheckSyntax: Error {
    let offset: Int
    let message: String
}

struct JSONCheckValue: Equatable {
    enum Kind: Equatable {
        case object([Data: JSONCheckValue])
        case array([JSONCheckValue])
        case string(Data)
        case number(JSONCheckNumber)
        case boolean(Bool)
        case null
    }

    let offset: Int
    let kind: Kind

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind }

    var dictionary: [Data: Self]? {
        if case .object(let values) = kind { return values }
        return nil
    }
    var elements: [Self]? {
        if case .array(let values) = kind { return values }
        return nil
    }
    var string: Data? {
        if case .string(let value) = kind { return value }
        return nil
    }
    var number: JSONCheckNumber? {
        if case .number(let value) = kind { return value }
        return nil
    }
}

/// JSON numbers compare by value, without rounding large integers through
/// binary floating point. Coefficients have no leading or trailing zeroes.
struct JSONCheckNumber: Comparable {
    let digits: [UInt8]
    let exponent: Int
    let negative: Bool

    var isInteger: Bool { exponent >= 0 }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.negative != rhs.negative { return lhs.negative }
        let leftZero = lhs.digits.first == 48
        let rightZero = rhs.digits.first == 48
        if leftZero || rightZero { return leftZero && !rightZero }
        let leftPlace = lhs.digits.count + lhs.exponent
        let rightPlace = rhs.digits.count + rhs.exponent
        if leftPlace != rightPlace {
            return lhs.negative ? leftPlace > rightPlace : leftPlace < rightPlace
        }
        return lhs.negative ? rhs.digits.lexicographicallyPrecedes(lhs.digits)
            : lhs.digits.lexicographicallyPrecedes(rhs.digits)
    }

    init?(_ token: ArraySlice<UInt8>) throws {
        var index = token.startIndex
        func take(_ byte: UInt8) -> Bool {
            guard index < token.endIndex, token[index] == byte else { return false }
            index += 1
            return true
        }
        func readDigits() -> Range<Int> {
            let start = index
            while index < token.endIndex, (48...57).contains(token[index]) { index += 1 }
            return start..<index
        }
        let sign = take(45)
        let integer = readDigits()
        guard !integer.isEmpty, token[integer.lowerBound] != 48 || integer.count == 1 else { return nil }
        var coefficient = Array(token[integer])
        var fractionCount = 0
        if take(46) {
            let fraction = readDigits()
            guard !fraction.isEmpty else { return nil }
            fractionCount = fraction.count
            coefficient.append(contentsOf: token[fraction])
        }
        var power = 0
        if take(69) || take(101) {
            let subtract = take(45)
            if !subtract { _ = take(43) }
            let given = readDigits()
            guard !given.isEmpty else { return nil }
            for digit in token[given] {
                guard power <= 100_000 else { throw JSONCheckLimit() }
                power = power * 10 + Int(digit - 48)
            }
            if subtract { power = -power }
        }
        guard index == token.endIndex else { return nil }
        if let first = coefficient.firstIndex(where: { $0 != 48 }),
           let last = coefficient.lastIndex(where: { $0 != 48 }) {
            digits = Array(coefficient[first...last])
            exponent = power - fractionCount + coefficient.count - last - 1
            negative = sign
        } else {
            digits = [48]
            exponent = 0
            negative = false
        }
    }
}

struct JSONCheckReader {
    private let bytes: [UInt8]
    private let allowsComments: Bool
    private var cursor = 0
    private var token: JSONTextTokens.Token?
    private var nodes = 0

    init(_ bytes: [UInt8], allowsComments: Bool) {
        self.bytes = bytes
        self.allowsComments = allowsComments
    }

    mutating func read() throws -> JSONCheckValue {
        try advance()
        let value = try readValue(depth: 0)
        guard token == nil else { throw error("Unexpected text after the JSON value.") }
        return value
    }

    private var offset: Int { token?.range.lowerBound ?? bytes.count }
    private func error(_ message: String) -> JSONCheckSyntax { .init(offset: offset, message: message) }

    private mutating func advance() throws {
        try Task.checkCancellation()
        do {
            repeat {
                token = try JSONTextTokens.next(bytes, cursor: &cursor, allowsComments: allowsComments)
            } while token?.kind == .lineComment || token?.kind == .blockComment
        } catch let failure as JSONTextTokens.Incomplete {
            let message = failure.comment ? "Close the block comment with */." : "Close the string with a double quote."
            throw JSONCheckSyntax(offset: failure.offset, message: message)
        }
    }

    private mutating func consume(_ symbol: UInt8) throws -> Bool {
        guard token?.kind == .symbol(symbol) else { return false }
        try advance()
        return true
    }

    private func string(_ token: JSONTextTokens.Token) throws -> Data {
        let decoded = try? autoreleasepool {
            try JSONSerialization.jsonObject(with: Data(bytes[token.range]), options: [.fragmentsAllowed]) as? String
        }
        guard let decoded else { throw error("Check the string’s escapes and control characters.") }
        return Data(decoded.utf8)
    }

    private mutating func readValue(depth: Int) throws -> JSONCheckValue {
        nodes += 1
        guard depth <= 64, nodes <= 65_536 else { throw JSONCheckLimit() }
        guard let token else { throw error("Expected a JSON value.") }
        let kind: JSONCheckValue.Kind
        switch token.kind {
        case .symbol(123):
            try advance()
            kind = .object(try readObject(depth: depth))
        case .symbol(91):
            try advance()
            kind = .array(try readArray(depth: depth))
        case .value:
            let literal = bytes[token.range]
            if literal.first == 34 { kind = .string(try string(token)) }
            else if literal.elementsEqual("true".utf8) { kind = .boolean(true) }
            else if literal.elementsEqual("false".utf8) { kind = .boolean(false) }
            else if literal.elementsEqual("null".utf8) { kind = .null }
            else if let number = try JSONCheckNumber(literal) { kind = .number(number) }
            else { throw error("Expected a JSON string, number, true, false or null.") }
            try advance()
        default:
            throw error("Expected a JSON value.")
        }
        return .init(offset: token.range.lowerBound, kind: kind)
    }

    private mutating func readObject(depth: Int) throws -> [Data: JSONCheckValue] {
        var values: [Data: JSONCheckValue] = [:]
        if try consume(125) { return values }
        while true {
            guard let token, token.kind == .value, bytes[token.range.lowerBound] == 34 else {
                throw error("Expected a property name in double quotes.")
            }
            let name = try string(token)
            guard values[name] == nil else { throw error("A property name repeats in this object.") }
            try advance()
            guard try consume(58) else { throw error("Expected a colon after the property name.") }
            values[name] = try readValue(depth: depth + 1)
            if try consume(125) { return values }
            guard try consume(44) else { throw error("Expected a comma or a closing brace.") }
            if allowsComments, try consume(125) { return values }
        }
    }

    private mutating func readArray(depth: Int) throws -> [JSONCheckValue] {
        var values: [JSONCheckValue] = []
        if try consume(93) { return values }
        while true {
            values.append(try readValue(depth: depth + 1))
            if try consume(93) { return values }
            guard try consume(44) else { throw error("Expected a comma or a closing bracket.") }
            if allowsComments, try consume(93) { return values }
        }
    }
}
