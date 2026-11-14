import Foundation
import Testing
@testable import FileMemory

/// The oracle scans original records. It never uses stored keys, query lanes,
/// index projection, match reasons or candidate code from the implementation.
private func oracleFold(_ text: String, tolerant: Bool) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    if !tolerant { return folded }
    var parts: [String] = [], current = ""
    for character in folded {
        if character == " " || character == "-" || character == "_" {
            if !current.isEmpty { parts.append(current); current = "" }
        } else { current.append(character) }
    }
    if !current.isEmpty { parts.append(current) }
    let leading = folded.first.map { $0 == " " || $0 == "-" || $0 == "_" } ?? false
    let trailing = folded.last.map { $0 == " " || $0 == "-" || $0 == "_" } ?? false
    if parts.isEmpty { return " " }
    return (leading ? " " : "") + parts.joined(separator: " ") + (trailing ? " " : "")
}

private func oracleMatches(_ value: String, _ request: RememberedNameQuery) -> Bool {
    if oracleFold(value, tolerant: false) == oracleFold(request.text, tolerant: false) { return true }
    if request.match == .exact { return false }
    let candidate = oracleFold(value, tolerant: request.separatorTolerant)
    let needle = oracleFold(request.text, tolerant: request.separatorTolerant)
    if candidate.utf8.starts(with: needle.utf8) { return true }
    let words = candidate.split(whereSeparator: \.isWhitespace)
    return needle.split(whereSeparator: \.isWhitespace).allSatisfy { part in
        words.contains { $0.utf8.starts(with: part.utf8) }
    }
}

@Test func nameIndexMatchesIndependentOriginalRecordOracle() async throws {
    let index = try SessionNameIndex()
    let bases = ["Résumé", "Nomad-DB", "Nomad__DB", "C++", ".NET", "日本語", "👩‍💻", "Re\u{301}sume\u{301}", "Alpha", "100%", "a/b", "quote'", "*", "Build"]
    var source: [(RememberedItemID, AuthoredNames)] = []
    for i in 0..<280 {
        let base = bases[i % bases.count]
        let names = try AuthoredNames(nickname: "\(base) \(i)",
            alternateNames: ["Annual \(base) Release", "Alternate_\(i)"], labels: [i % 2 == 0 ? "Work" : "Personal", base])
        let capture = try await index.prepareNew(names)
        source.append((try await index.apply(capture), names))
    }
    for text in ["resume", "Nomad DB", "C++", ".NET", "日本", "👩", "100%", "a/b", "*", "annual rel", "release annual", "work", "absent", "Alternate 12"] {
        for exact in [false, true] {
            for tolerant in [false, true] {
                let request = try RememberedNameQuery(text: text, match: exact ? .exact : .prefixAndWords,
                    separatorTolerant: tolerant, pageSize: 13)
                var expected: [RememberedItemID: Set<String>] = [:]
                for (id, names) in source {
                    let values: [(RememberedNameField, [String])] = [(.nickname, names.nickname.map { [$0] } ?? []),
                        (.alternateName, names.alternateNames), (.label, names.labels)]
                    for (field, fields) in values {
                        for (ordinal, value) in fields.enumerated() where oracleMatches(value, request) {
                            expected[id, default: []].insert("\(field.rawValue):\(ordinal)")
                        }
                    }
                }
                var page = try await index.query(request)
                var actual: [RememberedItemID: Set<String>] = [:]
                while true {
                    #expect(page.coverage == .complete)
                    for match in page.matches {
                        #expect(actual[match.item.id] == nil)
                        actual[match.item.id] = Set(match.reasons.map { "\($0.field.rawValue):\($0.ordinal)" })
                    }
                    guard let next = page.next else { break }
                    page = try await index.nextPage(next)
                }
                #expect(actual == expected)
            }
        }
    }
    await index.close()
}
