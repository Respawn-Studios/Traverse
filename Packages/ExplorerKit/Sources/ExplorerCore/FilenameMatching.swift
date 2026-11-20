import Foundation

/// Search spelling only. Never rewrites a path, filename, extension or operation
/// target. Keep punctuation with common filename meaning (., +, @, #) literal.
public enum FilenameMatching {
    /// Ranking for an explicit navigation picker. Keep shorter name shortcuts
    /// behind literal results and keep operation targets tied to observed URLs.
    public struct NavigationQuery: Equatable, Sendable {
        public enum Rank: Int, CaseIterable, Sendable { case exact, stem, prefix, contains, initials }

        private let key: String
        private let canMatchInitials: Bool
        private let symbolTolerant: Bool

        public init(_ query: String, symbolTolerant: Bool = false) {
            key = FilenameMatching.folded(query, symbolTolerant: symbolTolerant)
            canMatchInitials = (2...32).contains(key.count) && key.allSatisfy { $0.isLetter || $0.isNumber }
            self.symbolTolerant = symbolTolerant
        }

        public func rank(in name: String, isFilename: Bool = false) -> Rank? {
            guard !key.isEmpty else { return .exact }
            let folded = FilenameMatching.folded(name, symbolTolerant: symbolTolerant)
            if folded == key { return .exact }
            let stem = isFilename ? (name as NSString).deletingPathExtension : name
            if stem != name, FilenameMatching.folded(stem, symbolTolerant: symbolTolerant) == key { return .stem }
            if folded.hasPrefix(key) { return .prefix }
            if folded.contains(key) { return .contains }
            guard canMatchInitials else { return nil }
            return FilenameMatching.folded(Self.initials(of: stem), symbolTolerant: false).hasPrefix(key) ? .initials : nil
        }

        private static func initials(of name: String) -> String {
            var initials = "", previous: Character?
            for index in name.indices {
                let value = name[index]
                defer { previous = value }
                guard value.isLetter || value.isNumber else { continue }
                if let previous, previous.isLetter || previous.isNumber {
                    let next = name.index(after: index)
                    let startsWord = value.isUppercase && (previous.isLowercase || next < name.endIndex && name[next].isLowercase)
                    guard startsWord || value.isNumber != previous.isNumber else { continue }
                }
                initials.append(value)
            }
            return initials
        }
    }

    /// A literal fragment, or an anchored name pattern with '*' wildcards.
    /// Literal runs are searched in order, with no recursive matching or regex.
    public struct SelectionPattern: Sendable {
        private let prefix: String?
        private let suffix: String?
        private let fragments: [String]

        public init?(_ text: String) {
            guard !text.isEmpty, text.utf8.count <= 255,
                  !text.utf8.contains(0), !text.contains(where: \.isNewline) else { return nil }
            var literals = text.split(separator: "*").map { FilenameMatching.folded(String($0), symbolTolerant: false) }
            guard !literals.contains(where: \.isEmpty) else { return nil }
            if text.contains("*") {
                prefix = text.first == "*" ? nil : literals.removeFirst()
                suffix = text.last == "*" ? nil : literals.removeLast()
            } else {
                prefix = nil
                suffix = nil
            }
            fragments = literals
        }

        public func matches(_ name: String) -> Bool {
            let value = FilenameMatching.folded(name, symbolTolerant: false)
            var first = value.startIndex
            var end = value.endIndex
            if let prefix {
                guard let range = value.range(of: prefix, options: [.anchored, .literal]) else { return false }
                first = range.upperBound
            }
            if let suffix {
                guard let range = value.range(of: suffix, options: [.anchored, .backwards, .literal],
                                              range: first..<end) else { return false }
                end = range.lowerBound
            }
            for fragment in fragments {
                guard let range = value.range(of: fragment, options: .literal, range: first..<end) else { return false }
                first = range.upperBound
            }
            return true
        }
    }

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
