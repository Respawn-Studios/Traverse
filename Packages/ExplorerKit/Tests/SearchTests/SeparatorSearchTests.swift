import Foundation
import ExplorerCore
import Testing
@testable import Search

@Test func separatorSearchKeepsExactLiteralAndIndexedPrefilterASuperset() throws {
    let name = "Project__check-list.txt"
    let entry = FileEntry(url: URL(fileURLWithPath: "/Generated/" + name), name: name, kind: .file)
    #expect(try SearchRequest(filename: "project check list").matches(entry))
    #expect(try !SearchRequest(filename: "project check list", symbolTolerant: false).matches(entry))
    #expect(try !SearchRequest(filename: "Project check list.txt", filenameMatch: .exact).matches(entry))
    #expect(try SearchRequest(filename: name, filenameMatch: .exact).matches(entry))
    let normalized = SpotlightFilenamePlan.expression(try SearchRequest(filename: "project check list"))
    #expect(!normalized.contains("project check list"))
    #expect(normalized.hasPrefix("kMDItemFSName == "))
    let literal = SpotlightFilenamePlan.expression(try SearchRequest(filename: "project check list", symbolTolerant: false))
    #expect(literal.contains("project check list"))
    #expect(SpotlightFilenamePlan.expression(try SearchRequest(filename: name, filenameMatch: .exact)).contains(name))
}
