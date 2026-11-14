import Foundation
import Testing
@testable import ExplorerCore

@Test func addressCompletionIsLexicalAndPreservesActualSpelling() throws {
    let home = URL(fileURLWithPath: "/Users/Example", isDirectory: true)
    let request = try AddressCompletionRequest(text: "~/Work/Caf", home: home)
    #expect(request.parent.path == "/Users/Example/Work")
    var ranking = AddressSuggestionRanking(request: request)
    for name in ["Café", "café", "Cafe Space", "Other", ".hidden", "../escape"] { ranking.consider(directoryName: name) }
    #expect(ranking.suggestions.map(\.name) == ["Café", "Cafe Space", "café"])
    #expect(ranking.suggestions[0].completedText == "~/Work/Café/")
    #expect(ranking.suggestions[0].ghostSuffix(after: request.text) == "é/")
    for text in ["Work", "~another/", "file:///Users/", "sftp://host/", "/a\n/b", "/a\0/b"] {
        #expect(throws: AddressCompletionError.self) { try AddressCompletionRequest(text: text, home: home) }
    }
    let literal = try AddressCompletionRequest(text: "/$HOME/$(touch example)/", home: home)
    #expect(literal.parent.path == "/$HOME/$(touch example)")
}

@Test func addressRankingKeepsPrefixAheadOfTyposAndHistoryNeverInventsNames() throws {
    let request = try AddressCompletionRequest(text: "/Sample/Documnts", home: URL(fileURLWithPath: "/Users/Test"))
    var ranking = AddressSuggestionRanking(request: request, visits: ["/Sample/Documents": 100, "/Sample/Absent": 1000])
    ["Documents", "Documnts old", "Other"].forEach { ranking.consider(directoryName: $0) }
    #expect(ranking.suggestions.map(\.name) == ["Documnts old", "Documents"])
    #expect(ranking.suggestions.last?.match == .approximate)
    #expect(ranking.suggestions.last?.ghostSuffix(after: request.text) == nil)
    let swap = try AddressCompletionRequest(text: "/Sample/Downlaods", home: URL(fileURLWithPath: "/Users/Test"))
    var transposition = AddressSuggestionRanking(request: swap)
    transposition.consider(directoryName: "Downloads")
    #expect(transposition.suggestions.first?.match == .approximate)
}

@Test func addressRankingHasBoundedMemoryAndDeterministicTies() throws {
    let request = try AddressCompletionRequest(text: "/Sample/", home: URL(fileURLWithPath: "/Users/Test"))
    var a = AddressSuggestionRanking(request: request, limit: 8), b = a
    let names = (0..<1000).map { String(format: "Folder %04d", $0) }
    names.forEach { a.consider(directoryName: $0) }
    names.reversed().forEach { b.consider(directoryName: $0) }
    #expect(a.suggestions == b.suggestions && a.suggestions.count == 8)
    #expect(a.suggestions.first?.name == "Folder 0000")
    var explicitHidden = AddressSuggestionRanking(request: try AddressCompletionRequest(text: "/Sample/.", home: request.parent))
    explicitHidden.consider(directoryName: ".config")
    #expect(explicitHidden.suggestions.first?.name == ".config")
}
