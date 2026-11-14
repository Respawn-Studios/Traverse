import Foundation

public enum AddressCompletionError: Error, Sendable { case invalidPath }

/// Lexical path input only. No URL schemes, shell expressions or filesystem
/// access are evaluated here. An observation is a hint, never access authority.
public struct AddressCompletionRequest: Equatable, Sendable {
    public let text: String
    public let parent: URL
    public let component: String
    public let addressPrefix: String
    public let showsHidden: Bool
    public let symbolTolerant: Bool

    public init(text: String, home: URL, showsHidden: Bool = false, symbolTolerant: Bool = true) throws {
        guard text.utf8.count <= 8_192, !text.utf8.contains(0), !text.contains("\n"), !text.contains("\r"),
              text.hasPrefix("/") || text == "~" || text.hasPrefix("~/"), home.isFileURL else {
            throw AddressCompletionError.invalidPath
        }
        let input = text == "~" ? "~/" : text
        guard let slash = input.lastIndex(of: "/") else { throw AddressCompletionError.invalidPath }
        addressPrefix = String(input[...slash])
        component = String(input[input.index(after: slash)...])
        guard component.utf8.count <= 255 else { throw AddressCompletionError.invalidPath }
        let path = addressPrefix.hasPrefix("~/") ? home.path + String(addressPrefix.dropFirst()) : addressPrefix
        parent = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        self.text = text
        self.showsHidden = showsHidden || component.hasPrefix(".")
        self.symbolTolerant = symbolTolerant
    }

    public func completion(for name: String) -> String { addressPrefix + name + "/" }
}

public struct AddressSuggestion: Identifiable, Sendable, Equatable {
    public enum Match: Int, Sendable { case prefix, foldedPrefix, contains, approximate }
    public enum Source: Int, Sendable { case directoryLevel, familiar, volume, savedName, index }
    public var id: String { url.path }
    public let name: String
    public let completedText: String
    public let url: URL
    public let match: Match
    public let visitCount: Int
    public let source: Source

    public init(name: String, completedText: String, url: URL, match: Match, visitCount: Int = 0, source: Source = .directoryLevel) {
        self.name = name; self.completedText = completedText; self.url = url
        self.match = match; self.visitCount = visitCount; self.source = source
    }

    public func ghostSuffix(after input: String) -> String? {
        guard match != .approximate, match != .contains else { return nil }
        if completedText.hasPrefix(input), completedText != input { return String(completedText.dropFirst(input.count)) }
        // Bare-name hints display only the name suffix. Accepting one still
        // fills its explicit absolute path; the ghost never enters native text.
        guard source != .directoryLevel, name.hasPrefix(input) else { return nil }
        return String(name.dropFirst(input.count)) + "/"
    }
}

/// Streaming top-K selection: memory is bounded by visible candidates rather
/// than directory size. Locale-independent ordering also keeps tests repeatable.
public struct AddressSuggestionRanking: Sendable {
    public private(set) var suggestions: [AddressSuggestion] = []
    private let request: AddressCompletionRequest
    private let limit: Int
    private let folded: String
    private let visits: [String: Int]

    public init(request: AddressCompletionRequest, limit: Int = 8, visits: [String: Int] = [:]) {
        self.request = request; self.limit = min(12, max(1, limit))
        folded = FilenameMatching.folded(request.component, symbolTolerant: request.symbolTolerant)
        self.visits = visits
    }

    public mutating func consider(directoryName name: String) {
        guard let candidate = candidate(name), !suggestions.contains(where: { $0.name == name }) else { return }
        let index = suggestions.firstIndex { Self.precedes(candidate, $0) } ?? suggestions.endIndex
        if index < limit { suggestions.insert(candidate, at: index) }
        if suggestions.count > limit { suggestions.removeLast() }
    }

    /// A name-only prefilter lets the reader avoid native metadata calls for
    /// nonmatches and entries that cannot displace the bounded top candidates.
    public func couldEnterResults(directoryName name: String) -> Bool {
        guard let candidate = candidate(name) else { return false }
        return suggestions.count < limit || suggestions.last.map { Self.precedes(candidate, $0) } == true
    }

    private func candidate(_ name: String) -> AddressSuggestion? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              name.utf8.count <= 255, request.showsHidden || !name.hasPrefix(".") else { return nil }
        let normalized = FilenameMatching.folded(name, symbolTolerant: request.symbolTolerant)
        let match: AddressSuggestion.Match
        if name.hasPrefix(request.component) { match = .prefix }
        else if normalized.hasPrefix(folded) { match = .foldedPrefix }
        else if folded.count >= 3, folded.count <= 64, normalized.count <= 66,
                Self.distance(folded, normalized, maximum: folded.count < 6 ? 1 : 2) != nil { match = .approximate }
        else { return nil }
        let url = request.parent.appendingPathComponent(name, isDirectory: true)
        return AddressSuggestion(name: name, completedText: request.completion(for: name), url: url,
                                          match: match, visitCount: max(0, min(1_000_000, visits[url.path] ?? 0)))
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    private static func precedes(_ a: AddressSuggestion, _ b: AddressSuggestion) -> Bool {
        if a.match != b.match { return a.match.rawValue < b.match.rawValue }
        if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
        let left = fold(a.name), right = fold(b.name)
        if left != right { return left < right }
        return a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
    }
    /// Bounded optimal-string-alignment distance, including one adjacent swap.
    static func distance(_ a: String, _ b: String, maximum: Int) -> Int? {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= maximum else { return nil }
        var previous = Array(0...b.count), older = previous
        for i in 1...a.count {
            var current = [Int](repeating: maximum + 1, count: b.count + 1); current[0] = i
            let lower = max(1, i - maximum), upper = min(b.count, i + maximum)
            if lower > upper { return nil }
            for j in lower...upper {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], older[j - 2] + 1)
                }
            }
            older = previous; previous = current
        }
        return previous[b.count] <= maximum ? previous[b.count] : nil
    }
}

public enum AddressSuggestionPresentation: String, Codable, CaseIterable, Sendable {
    case both = "Dropdown and inline", dropdown = "Dropdown", inline = "Inline", off = "Off"
    public var showsDropdown: Bool { self == .both || self == .dropdown }
    public var showsInline: Bool { self == .both || self == .inline }
}
