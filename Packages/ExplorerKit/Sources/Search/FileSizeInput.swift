import Foundation

/// Explicit metadata-filter input, separate from the literal filename grammar.
/// Conversion is exact: an inclusive bound must never be rounded to another byte.
public enum FileSizeInput {
    public enum Failure: Error, Equatable, Sendable {
        case invalidFormat, unknownUnit, fractionalByte, tooLarge, negativeValue
    }

    public static func bytes(_ raw: String) throws -> Int64? {
        guard raw.utf8.prefix(65).count <= 64,
              !raw.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { throw Failure.invalidFormat }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        let input = Array(text.utf8)
        var offset = 0
        let negative = input[0] == 45
        if input[0] == 43 || negative { offset += 1 }
        var whole: UInt64 = 0
        var digits = 0
        while offset < input.count, (48...57).contains(input[offset]) {
            let next = whole.multipliedReportingOverflow(by: 10)
            let sum = next.partialValue.addingReportingOverflow(UInt64(input[offset] - 48))
            guard !next.overflow, !sum.overflow, sum.partialValue <= UInt64(Int64.max) else { throw Failure.tooLarge }
            whole = sum.partialValue; digits += 1; offset += 1
        }
        var fraction: UInt64 = 0
        var denominator: UInt64 = 1
        if offset < input.count, input[offset] == 46 {
            offset += 1
            var fractionDigits = 0
            while offset < input.count, (48...57).contains(input[offset]) {
                guard fractionDigits < 12 else { throw Failure.invalidFormat }
                fraction = fraction * 10 + UInt64(input[offset] - 48)
                denominator *= 10; fractionDigits += 1; offset += 1
            }
            guard fractionDigits > 0 else { throw Failure.invalidFormat }
            digits += fractionDigits
        }
        guard digits > 0 else { throw Failure.invalidFormat }
        let suffix = String(decoding: input[offset...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard suffix.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { throw Failure.unknownUnit }
        let unit = suffix.uppercased()
        let multiplier: UInt64
        switch unit {
        case "", "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        case "KIB": multiplier = 1_024
        case "MIB": multiplier = 1_048_576
        case "GIB": multiplier = 1_073_741_824
        case "TIB": multiplier = 1_099_511_627_776
        default: throw Failure.unknownUnit
        }
        // Cancel common factors before multiplication, avoiding overflow from
        // an otherwise representable fractional bound near Int64.max.
        var a = multiplier, b = denominator
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let divisor = denominator / a
        guard fraction.isMultiple(of: divisor) else { throw Failure.fractionalByte }
        let fractionalBytes = (fraction / divisor) * (multiplier / a)
        let base = whole.multipliedReportingOverflow(by: multiplier)
        let total = base.partialValue.addingReportingOverflow(fractionalBytes)
        guard !base.overflow, !total.overflow, total.partialValue <= UInt64(Int64.max) else { throw Failure.tooLarge }
        guard !negative || total.partialValue == 0 else { throw Failure.negativeValue }
        return Int64(total.partialValue)
    }
}
