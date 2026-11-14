import Foundation
import Testing
@testable import ExplorerCore

@Test func folderNameLookupPrioritizesFamiliarLocationsAndKeepsDistinctParents() throws {
    let request = try FolderNameRequest(text: "Downloads")
    var ranking = FolderNameSuggestionRanking(request: request, visits: ["/Volumes/Workspace/Downloads": 900])
    let locations: [FolderNameLocation] = [
        .init(name: "Downloads", url: URL(fileURLWithPath: "/Volumes/Workspace/Downloads"), source: .index),
        .init(name: "Downloads", url: URL(fileURLWithPath: "/Users/Example/Downloads"), source: .familiar),
        .init(name: "Downloads", url: URL(fileURLWithPath: "/Users/Example/Downloads"), source: .index),
        .init(name: "Older Downloads", url: URL(fileURLWithPath: "/Archive/Older Downloads"), source: .index)
    ]
    locations.forEach { ranking.consider($0) }
    #expect(ranking.suggestions.count == 3)
    #expect(ranking.suggestions[0].url.path == "/Users/Example/Downloads")
    #expect(ranking.suggestions[0].source == .familiar)
    #expect(ranking.suggestions[1].url.path == "/Volumes/Workspace/Downloads")
    #expect(Set(ranking.suggestions.map(\.id)).count == 3)
    #expect(ranking.suggestions[0].completedText == "/Users/Example/Downloads/")
    for spelling in ["downloads", "down", "DOWN"] {
        var folded = FolderNameSuggestionRanking(request: try FolderNameRequest(text: spelling))
        (locations + [.init(name: "downloads", url: URL(fileURLWithPath: "/Indexed/lowercase/downloads"), source: .index)])
            .forEach { folded.consider($0) }
        #expect(folded.suggestions.first?.source == .familiar)
    }
}

@Test func folderNameCompletionGhostIsNameOnlyButAcceptsAnExplicitPath() throws {
    var ranking = FolderNameSuggestionRanking(request: try FolderNameRequest(text: "Down"))
    ranking.consider(.init(name: "Downloads", url: URL(fileURLWithPath: "/Users/Example/Downloads"), source: .familiar))
    let suggestion = try #require(ranking.suggestions.first)
    #expect(suggestion.ghostSuffix(after: "Down") == "loads/")
    #expect(suggestion.completedText.hasPrefix("/Users/Example/"))
    #expect(suggestion.ghostSuffix(after: "/Down") == nil)
    var drive = FolderNameSuggestionRanking(request: try FolderNameRequest(text: "Workspace"))
    drive.consider(.init(name: "Workspace", url: URL(fileURLWithPath: "/Volumes/Workspace"), source: .volume))
    #expect(drive.suggestions.first?.completedText == "/Volumes/Workspace/")
    for text in ["", "/Workspace/", "a/b", "~/Down", "sftp:host", ".", "..", "a\0b", "a\nb"] {
        #expect(throws: AddressCompletionError.self) { try FolderNameRequest(text: text) }
    }
}

@Test func folderNameRankingIsBoundedAndRejectsCredentialHints() throws {
    var a = FolderNameSuggestionRanking(request: try FolderNameRequest(text: "Folder"), limit: 4), b = a
    let locations = (0..<100).map { FolderNameLocation(name: "Folder", url: URL(fileURLWithPath: "/Generated/\($0)/Folder"), source: .index) }
    locations.forEach { a.consider($0) }; locations.reversed().forEach { b.consider($0) }
    #expect(a.suggestions == b.suggestions && a.suggestions.count == 4)
    a.consider(.init(name: "Folder", url: URL(fileURLWithPath: "/Users/Example/.ssh/Folder"), source: .familiar))
    #expect(!a.suggestions.contains { $0.url.path.contains(".ssh") })
}
