import Foundation

/// A single folder/drive name, distinct from an absolute or tilde path. No shell
/// expansion, relative-path inference or automatic correction of absolute paths.
public struct FolderNameRequest: Sendable, Equatable {
    public let text: String
    public let showsHidden: Bool
    public let symbolTolerant: Bool
    public init(text: String, showsHidden: Bool = false, symbolTolerant: Bool = true) throws {
        guard !text.isEmpty, text.utf8.count <= 255, !text.contains("/"), !text.contains(":"),
              !text.hasPrefix("~"), !text.contains("\n"), !text.contains("\r"), !text.utf8.contains(0),
              text != ".", text != ".." else { throw AddressCompletionError.invalidPath }
        self.text = text; self.showsHidden = showsHidden || text.hasPrefix(".")
        self.symbolTolerant = symbolTolerant
    }
    public func match(_ name: String) -> AddressSuggestion.Match? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              showsHidden || !name.hasPrefix(".") else { return nil }
        if name.hasPrefix(text) { return .prefix }
        let query = AddressSuggestionRanking.fold(text), candidate = AddressSuggestionRanking.fold(name)
        if candidate.hasPrefix(query) { return .foldedPrefix }
        if candidate.contains(query) { return .contains }
        if symbolTolerant {
            let normalized = FilenameMatching.folded(name, symbolTolerant: true)
            let normalizedQuery = FilenameMatching.folded(text, symbolTolerant: true)
            if normalized.hasPrefix(normalizedQuery) { return .foldedPrefix }
            if normalized.contains(normalizedQuery) { return .contains }
        }
        if (3...64).contains(query.count), candidate.count <= 66,
           AddressSuggestionRanking.distance(query, candidate, maximum: query.count < 6 ? 1 : 2) != nil { return .approximate }
        return nil
    }
}

/// A lexical hint, not evidence that it exists or is accessible. Readers must
/// freshly observe it before ranking. Native volume IDs remain separate.
public struct FolderNameLocation: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let source: AddressSuggestion.Source
    public init(name: String, url: URL, source: AddressSuggestion.Source) {
        self.name = name; self.url = url; self.source = source
    }
}

public struct FolderNameSuggestionRanking: Sendable {
    public private(set) var suggestions: [AddressSuggestion] = []
    private let request: FolderNameRequest
    private let limit: Int
    private let visits: [String: Int]
    public init(request: FolderNameRequest, limit: Int = 8, visits: [String: Int] = [:]) {
        self.request = request; self.limit = min(12, max(1, limit)); self.visits = visits
    }
    public mutating func consider(_ location: FolderNameLocation) {
        guard location.url.isFileURL, location.url.host == nil || location.url.host == "" || location.url.host == "localhost",
              location.url.user == nil, location.url.password == nil, location.url.query == nil, location.url.fragment == nil,
              location.url.standardizedFileURL.path == location.url.path,
              !AutomaticMetadataPolicy.excludes(location.url), let match = request.match(location.name) else { return }
        let url = location.url
        let candidate = AddressSuggestion(name: location.name, completedText: url.path == "/" ? "/" : url.path + "/", url: url,
            match: match, visitCount: max(0, min(1_000_000, visits[url.path] ?? 0)), source: location.source)
        if let old = suggestions.firstIndex(where: { $0.id == candidate.id }) {
            guard precedes(candidate, suggestions[old]) else { return }; suggestions.remove(at: old)
        }
        let index = suggestions.firstIndex { precedes(candidate, $0) } ?? suggestions.endIndex
        if index < limit { suggestions.insert(candidate, at: index) }
        if suggestions.count > limit { suggestions.removeLast() }
    }
    private func precedes(_ a: AddressSuggestion, _ b: AddressSuggestion) -> Bool {
        // Familiar exact names, notably the user's Downloads, win independently
        // of visit ranking. Other paths remain distinguishable by URL identity.
        let query = FilenameMatching.folded(request.text, symbolTolerant: request.symbolTolerant)
        let ae = FilenameMatching.folded(a.name, symbolTolerant: request.symbolTolerant) == query
        let be = FilenameMatching.folded(b.name, symbolTolerant: request.symbolTolerant) == query
        if ae != be { return ae }
        func tier(_ match: AddressSuggestion.Match) -> Int {
            switch match { case .prefix, .foldedPrefix: 0; case .contains: 1; case .approximate: 2 }
        }
        if tier(a.match) != tier(b.match) { return tier(a.match) < tier(b.match) }
        if a.source != b.source { return a.source.rawValue < b.source.rawValue }
        if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
        if a.match != b.match { return a.match.rawValue < b.match.rawValue }
        let an = AddressSuggestionRanking.fold(a.name), bn = AddressSuggestionRanking.fold(b.name)
        if an != bn { return an < bn }
        return a.url.path.utf8.lexicographicallyPrecedes(b.url.path.utf8)
    }
}
