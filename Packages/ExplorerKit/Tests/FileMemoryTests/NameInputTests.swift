import Foundation
import Testing
@testable import FileMemory

@Test func nameInputPreservesAuthoredValuesAndBoundsEveryField() throws {
    let value = try AuthoredNames(nickname: "  Résumé 👩‍💻  ", alternateNames: ["C++", "C++", "C#"], labels: ["work", "Work"])
    #expect(value.nickname == "Résumé 👩‍💻")
    #expect(value.alternateNames == ["C++", "C#"])
    #expect(value.labels == ["work", "Work"])
    #expect(try AuthoredNames(nickname: String(repeating: "é", count: 256)).nickname != nil)
    #expect(throws: NameIndexFailure.invalidInput) { try AuthoredNames(nickname: String(repeating: "é", count: 257)) }
    #expect(throws: NameIndexFailure.invalidInput) { try AuthoredNames(alternateNames: Array(repeating: "n", count: 17)) }
    #expect(throws: NameIndexFailure.invalidInput) { try AuthoredNames(labels: Array(repeating: "n", count: 17)) }
    #expect(throws: NameIndexFailure.invalidInput) { try AuthoredNames(labels: [String(repeating: "a", count: 129)]) }
    #expect(throws: NameIndexFailure.emptyInput) { try AuthoredNames(nickname: "  ") }
    #expect(throws: NameIndexFailure.emptyInput) { try AuthoredNames(labels: [""]) }
    for control in ["\0", "\n", "\r", "\t", "\u{85}", "\u{2028}", "\u{2029}"] {
        #expect(throws: NameIndexFailure.invalidInput) { try AuthoredNames(nickname: "a" + control + "b") }
    }
    let tooManyWords = (0..<65).map { "w\($0)" }.joined(separator: " ")
    #expect(throws: NameIndexFailure.projectionLimit) { try AuthoredNames(nickname: tooManyWords) }
    let fields = try NameProjection.fields(value)
    #expect(fields.count == 5) // Nickname must not hide the aliases/labels.
}

@Test func nameNormalizationKeepsMeaningfulPunctuationAndVersionedUnicode() throws {
    #expect(RememberedNameNormalization.version == 1)
    #expect(RememberedNameNormalization.key("Re\u{301}sume\u{301}") == "resume")
    #expect(RememberedNameNormalization.key("RÉSUMÉ") == "resume")
    #expect(RememberedNameNormalization.key("Straße") == RememberedNameNormalization.key("STRASSE"))
    #expect(RememberedNameNormalization.key("ΟΣ") == RememberedNameNormalization.key("ος"))
    #expect(RememberedNameNormalization.key("Nomad__-DB", separatorTolerant: true) == "nomad db")
    #expect(RememberedNameNormalization.key("Nomad__-DB") == "nomad__-db")
    for value in ["C++", "C#", ".NET", "name@example", "100%", "a/b", "*", "?", "👩‍💻", "日本語"] {
        #expect(RememberedNameNormalization.key(value).utf8.count > 0)
        #expect(RememberedNameNormalization.key(value, separatorTolerant: true) == RememberedNameNormalization.key(value))
    }
    #expect(RememberedNameNormalization.words("build build C++").count == 2)
    for text in ["é", "日本語", "👩", "z", "\u{10FFFF}"] {
        let bytes = Data(text.utf8)
        let upper = RememberedNameNormalization.upperBound(bytes)
        #expect(bytes.lexicographicallyPrecedes(upper))
        #expect(Data((text + " child").utf8).lexicographicallyPrecedes(upper))
    }
}

@Test func nameQueryCannotSmugglePredicatesOrRelaxInputLimits() throws {
    let query = try RememberedNameQuery(text: " ' OR 1=1; -- ", separatorTolerant: false)
    #expect(query.text == "' OR 1=1; --")
    #expect(try RememberedNameQuery(text: "archive/2026").text == "archive/2026")
    #expect(throws: NameIndexFailure.invalidQuery) { try RememberedNameQuery(text: "\n") }
    #expect(throws: NameIndexFailure.invalidQuery) { try RememberedNameQuery(text: "  ") }
    #expect(throws: NameIndexFailure.invalidQuery) { try RememberedNameQuery(text: "---") }
    #expect(try RememberedNameQuery(text: "---", match: .exact).text == "---")
    #expect(throws: NameIndexFailure.invalidQuery) { try RememberedNameQuery(text: String(repeating: "x", count: 513)) }
    #expect(throws: NameIndexFailure.invalidQuery) { try RememberedNameQuery(text: "x", fields: []) }
    #expect(throws: NameIndexFailure.invalidPageSize) { try RememberedNameQuery(text: "x", pageSize: 257) }
    #expect(throws: NameIndexFailure.invalidQuery) {
        try RememberedNameQuery(text: (0..<17).map { "word\($0)" }.joined(separator: " "))
    }
}
