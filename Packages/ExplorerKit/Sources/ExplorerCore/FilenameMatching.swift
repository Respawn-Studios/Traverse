import Foundation

/// Search spelling only. Never rewrites a path, filename, extension or operation
/// target. Keep punctuation with common filename meaning (., +, @, #) literal.
public enum FilenameMatching {
    public static func folded(_ value: String, symbolTolerant: Bool) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        guard symbolTolerant else { return folded }
        var result = String(); result.reserveCapacity(folded.utf8.count)
        var separated = false
        for character in folded {
            if character == " " || character == "-" || character == "_" {
                if !separated { result.append(" ") }
                separated = true
            } else { result.append(character); separated = false }
        }
        return result
    }

    public static func contains(_ name: String, query: String, symbolTolerant: Bool) -> Bool {
        folded(name, symbolTolerant: symbolTolerant).contains(folded(query, symbolTolerant: symbolTolerant))
    }

    /// A necessary literal fragment, never the complete query predicate. Native
    /// indexed candidates must still pass the complete filename matcher. Removing
    /// separators avoids false negatives when the index stores a different one.
    public static func indexedLiteralFragment(_ query: String, symbolTolerant: Bool) -> String {
        var separators = CharacterSet(charactersIn: "*?\\\"'")
        if symbolTolerant { separators.formUnion(CharacterSet(charactersIn: " -_")) }
        return query.components(separatedBy: separators).max { $0.count < $1.count } ?? ""
    }
}
