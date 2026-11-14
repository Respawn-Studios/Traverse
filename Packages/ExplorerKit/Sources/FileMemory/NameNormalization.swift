import Foundation

/// Separate from filename matching: these keys may later persist and must have
/// an explicit version. B07.0 has no persisted keys; B07.1 must also bind the
/// Foundation/Unicode runtime when qualifying rebuild and migration behavior.
public enum RememberedNameNormalization {
    public static let version = 1

    public static func key(_ value: String, separatorTolerant: Bool = false) -> String {
        let folded = value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
        ).precomposedStringWithCanonicalMapping
        guard separatorTolerant else { return folded }
        var output = String(); output.reserveCapacity(folded.utf8.count)
        var wasSeparator = false
        for scalar in folded.unicodeScalars {
            if scalar.value == 32 || scalar.value == 45 || scalar.value == 95 {
                if !wasSeparator { output.append(" ") }
                wasSeparator = true
            } else {
                output.unicodeScalars.append(scalar); wasSeparator = false
            }
        }
        return output
    }

    /// Whitespace-delimited words, not linguistic segmentation or substring
    /// search. Punctuation/emoji stay part of the word. No inferred expansions.
    internal static func words(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { seen.insert($0).inserted }
    }

    internal static func starts(_ value: String, with prefix: String) -> Bool {
        value.utf8.starts(with: prefix.utf8)
    }

    /// BLOB range bounds avoid LIKE wildcards, ASCII NOCASE and invalid Unicode
    /// successor strings. SQLite orders these bytes using its binary BLOB order.
    internal static func upperBound(_ prefix: Data) -> Data {
        var bytes = [UInt8](prefix)
        while let last = bytes.last {
            if last < 255 { bytes[bytes.count - 1] += 1; return Data(bytes) }
            bytes.removeLast()
        }
        // Valid nonempty UTF-8 keys cannot consist entirely of 0xff.
        preconditionFailure("A normalized UTF-8 prefix must have an upper bound")
    }
}

internal struct ProjectedName {
    let field: RememberedNameField
    let ordinal: Int
    let original: String
    let literal: String
    let tolerant: String
    let literalWords: [String]
    let tolerantWords: [String]
}

internal enum NameProjection {
    static func fields(_ names: AuthoredNames) throws -> [ProjectedName] {
        let values: [(RememberedNameField, Int, String)] =
            (names.nickname.map { [(.nickname, 0, $0)] } ?? [])
            + names.alternateNames.enumerated().map { (.alternateName, $0.offset, $0.element) }
            + names.labels.enumerated().map { (.label, $0.offset, $0.element) }
        var projected: [ProjectedName] = []
        var keyCount = 0
        for (field, ordinal, original) in values {
            let literal = RememberedNameNormalization.key(original)
            let tolerant = RememberedNameNormalization.key(original, separatorTolerant: true)
            let literalWords = RememberedNameNormalization.words(literal)
            let tolerantWords = RememberedNameNormalization.words(tolerant)
            guard !literal.isEmpty, literal.utf8.count <= 2_048, tolerant.utf8.count <= 2_048,
                  literalWords.count <= 64, tolerantWords.count <= 64 else { throw NameIndexFailure.projectionLimit }
            keyCount += 2 + literalWords.count + tolerantWords.count
            guard keyCount <= 1_024 else { throw NameIndexFailure.projectionLimit }
            projected.append(ProjectedName(field: field, ordinal: ordinal, original: original,
                literal: literal, tolerant: tolerant, literalWords: literalWords, tolerantWords: tolerantWords))
        }
        return projected
    }
}
