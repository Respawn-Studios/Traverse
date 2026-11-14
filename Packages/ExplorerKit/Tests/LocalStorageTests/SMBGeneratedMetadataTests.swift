import Foundation
import ExplorerCore
import Testing
@testable import LocalStorage

struct SMBGeneratedMetadataTests {
    @Test func metadataQueriesRetainTheActualEnumeratedUnicodeSpelling() throws {
        let decomposed = "Cafe\u{301} 文件.txt"
        let observed = ["Read me.txt", decomposed, "Folder"]
        #expect(decomposed == SMBGeneratedFixtureNames.regular[1])
        #expect(Data(decomposed.utf8) != Data(SMBGeneratedFixtureNames.regular[1].utf8))
        let nativeLookup = Set(observed.map { Data($0.utf8) })
        let queries = try SMBGeneratedFixtureNames.regularProbeNames(in: observed)
        #expect(queries.allSatisfy { nativeLookup.contains(Data($0.utf8)) })
        #expect(queries.map { Data($0.utf8) } == Array(observed.prefix(2)).map { Data($0.utf8) })
    }
    @Test func ambiguousMissingAndOversizedObservationsCannotSelectAProbe() throws {
        for names in [
            ["Read me.txt", "Café 文件.txt", "Cafe\u{301} 文件.txt"],
            ["Read me.txt", "Read me.txt", "Café 文件.txt"],
            ["Café 文件.txt"], Array(repeating: "Other", count: 65)
        ] {
            #expect(throws: SMBConnectionProblem.invalidResult) {
                try SMBGeneratedFixtureNames.regularProbeNames(in: names)
            }
        }
    }
    @Test func composedNamesRemainExactAndOrderingComesFromTheFixtureContract() throws {
        let expected = SMBGeneratedFixtureNames.regular
        let chosen = try SMBGeneratedFixtureNames.regularProbeNames(in: ["Folder", expected[1], expected[0]])
        #expect(chosen.map { Data($0.utf8) } == expected.map { Data($0.utf8) })
    }
}
