import Foundation
import Testing
@testable import ExplorerCore

@Test func boundedSeparatorMatchingPreservesPunctuationAndOptOut() throws {
    for name in ["Project_Checklist", "Project---Checklist", "Project _- Checklist"] {
        #expect(FilenameMatching.contains(name, query: "project checklist", symbolTolerant: true))
        #expect(!FilenameMatching.contains(name, query: "project checklist", symbolTolerant: false))
        #expect(try FolderNameRequest(text: "project checklist").match(name) == .foldedPrefix)
    }
    #expect(FilenameMatching.contains("C++", query: "C+", symbolTolerant: true))
    for (name, query) in [("a.b", "a b"), ("user@host", "user host"), ("C++", "C  "), ("a#b", "a b")] {
        #expect(!FilenameMatching.contains(name, query: query, symbolTolerant: true))
    }
    #expect(FilenameMatching.folded("Café _- NOTES", symbolTolerant: true) == "cafe notes")
    #expect(FilenameMatching.indexedLiteralFragment("project checklist", symbolTolerant: true) == "checklist")
    #expect(FilenameMatching.indexedLiteralFragment("project checklist", symbolTolerant: false) == "project checklist")
    #expect(!FilenameMatching.indexedLiteralFragment("x\" OR name == '*", symbolTolerant: true).contains("\""))
}

@Test func pathCompletionMatchesAlternateSeparatorsWithoutRewritingOrGhosting() throws {
    let home = URL(fileURLWithPath: "/Users/Generated")
    var ranking = AddressSuggestionRanking(request: try AddressCompletionRequest(text: "/Generated/project check", home: home))
    ranking.consider(directoryName: "project_checklist")
    let suggestion = try #require(ranking.suggestions.first)
    #expect(suggestion.completedText == "/Generated/project_checklist/")
    #expect(suggestion.ghostSuffix(after: "/Generated/project check") == nil)
    var literal = AddressSuggestionRanking(request: try AddressCompletionRequest(text: "/Generated/project checklist", home: home,
                                                                                 symbolTolerant: false))
    literal.consider(directoryName: "project____checklist")
    #expect(literal.suggestions.isEmpty)
}
