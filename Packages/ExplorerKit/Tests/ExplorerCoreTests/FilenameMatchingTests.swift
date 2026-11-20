import Foundation
import Testing
@testable import ExplorerCore

@Test func navigationNamesRankLiteralMatchesBeforeWordInitials() {
    let initials = FilenameMatching.NavigationQuery("eht")
    #expect(initials.rank(in: "EHT", isFilename: true) == .exact)
    #expect(initials.rank(in: "Eht.swift", isFilename: true) == .stem)
    #expect(initials.rank(in: "EHTNotes.swift", isFilename: true) == .prefix)
    #expect(initials.rank(in: "Open EHT Notes.swift", isFilename: true) == .contains)
    #expect(initials.rank(in: "EditorHTTPTrace.swift", isFilename: true) == .initials)
    #expect(initials.rank(in: "editor_http_trace", isFilename: true) == .initials)
    #expect(initials.rank(in: "LogHTTPEditor.swift", isFilename: true) == nil)
    #expect(initials.rank(in: "EditorHttp.txt", isFilename: true) == nil)
    #expect(FilenameMatching.NavigationQuery("cbt").rank(in: "CrèmeBrûléeTests") == .initials)
    #expect(FilenameMatching.NavigationQuery("rn2").rank(in: "ReleaseNotes2026.txt", isFilename: true) == .initials)
    #expect(FilenameMatching.NavigationQuery("c*").rank(in: "CrèmeBrûléeTests") == nil)
}

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

@Test func nameSelectionPatternsCompareLiteralNamesAndOrderedWildcards() throws {
    let fragment = try #require(FilenameMatching.SelectionPattern("Café+"))
    #expect(fragment.matches("project CAFE+ notes.txt"))
    #expect(!fragment.matches("project cafe notes.txt"))
    let suffix = try #require(FilenameMatching.SelectionPattern("*.pdf"))
    #expect(suffix.matches("Report.PDF"))
    #expect(!suffix.matches("Report.pdf.txt"))
    let ordered = try #require(FilenameMatching.SelectionPattern("draft**v*final.txt"))
    #expect(ordered.matches("Draft V2 Final.txt"))
    #expect(!ordered.matches("copy Draft V2 Final.txt"))
    #expect(!ordered.matches("Draft Final V2.txt"))
    let nonoverlapping = try #require(FilenameMatching.SelectionPattern("ab*bc"))
    #expect(nonoverlapping.matches("abbc"))
    #expect(!nonoverlapping.matches("abc"))
    #expect(FilenameMatching.SelectionPattern("*")?.matches("Document") == true)
    #expect(FilenameMatching.SelectionPattern("  ")?.matches("A  B") == true)
    #expect(FilenameMatching.SelectionPattern("") == nil)
    #expect(FilenameMatching.SelectionPattern("one\ntwo") == nil)
    #expect(FilenameMatching.SelectionPattern(String(repeating: "é", count: 128)) == nil)
}
