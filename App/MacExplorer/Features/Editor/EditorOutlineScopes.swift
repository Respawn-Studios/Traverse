import Foundation

/// Scope ends are known before presentation. Indentation is useful for
/// organizing the outline, but does not establish where a code block ends.
enum EditorOutlineScopes {
    typealias Entry = EditorDocumentOutline.Entry
    typealias Scope = EditorDocumentOutline.Scope

    static func build(entries: [Entry], source: NSString, lines: EditorLineIndex, tokens: [TextSyntaxToken],
                      language: TextSyntaxLanguage, preparedPairs: [EditorDelimiterWalk.Pair]?, cancelled: () -> Bool) -> [Scope] {
        guard !entries.isEmpty, !cancelled() else { return [] }
        switch language {
        case .markdown, .ini: return sectionScopes(entries, end: source.length)
        case .json, .jsonc, .swift, .rust: break
        default: return []
        }
        let json = language == .json || language == .jsonc
        let propertyOwners = json ? propertyBraces(entries, source: source, tokens: tokens, cancelled: cancelled) : [:]
        // The outline entry always points to the declaration keyword.
        let declarations = json ? [:] : Dictionary(grouping: entries) { $0.signatureLine ?? $0.line }
        let swiftParameters = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.parametersOffset.map { ($0, entry) }
        })
        let comments = swiftParameters.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: tokens.lazy.filter { $0.kind == .comment }
            .map { ($0.range.location, NSMaxRange($0.range)) })
        var swiftBodies: [Int: Entry] = [:]
        var scopes: [Int: (opening: Int, scope: Scope)] = [:]
        func record(_ pair: EditorDelimiterWalk.Pair) {
            if pair.openingUnit == 40, !pair.insideExpression, let entry = swiftParameters[pair.opening],
               let opening = swiftBody(after: pair.closing, startingAt: entry.offset, in: source, comments: comments) {
                swiftBodies[opening] = entry
            }
            let owner: Entry?
            if json {
                owner = propertyOwners[pair.opening]
            } else if pair.openingUnit == 123, !pair.insideExpression,
                      let line = lines.location(at: pair.opening)?.line {
                owner = swiftBodies[pair.opening] ?? declarations[line]?.last { entry in
                    let length = pair.opening - entry.offset
                    guard (1...2_048).contains(length) else { return false }
                    let header = source.substring(with: .init(location: entry.offset, length: length))
                    let word = header.prefix { !$0.isWhitespace }
                    return !header.contains(";") && !["typealias", "associatedtype", "type"].contains(word)
                }
            } else { owner = nil }
            if let owner, scopes[owner.offset].map({ pair.opening < $0.opening }) ?? true {
                scopes[owner.offset] = (pair.opening, Scope(entry: owner, end: pair.closing + 1))
            }
        }
        if let preparedPairs {
            for pair in preparedPairs {
                if cancelled() { return [] }
                record(pair)
            }
        } else {
            let completion = EditorDelimiterWalk.pairs(in: source, tokens: tokens, cancelled: cancelled) { pair in
                record(pair)
                return true
            }
            guard case .complete = completion else { return [] }
        }
        return scopes.values.map(\.scope).sorted { $0.entry.offset < $1.entry.offset }
    }

    /// A complete parameter pair already came from the shared delimiter walk.
    /// Admit the following brace only across trivia and a simple Swift tail.
    private static func swiftBody(after parameters: Int, startingAt declaration: Int, in source: NSString,
                                  comments: [Int: Int]) -> Int? {
        let limit = min(source.length, declaration + 2_048)
        var cursor = parameters + 1
        func unit(_ offset: Int = 0) -> UInt16? {
            cursor + offset < limit ? source.character(at: cursor + offset) : nil
        }
        func skipTrivia() {
            while let next = unit() {
                if EditorLexicalCursor.white(next) { cursor += 1 }
                else if let end = comments[cursor], end <= limit { cursor = end }
                else { return }
            }
        }
        func nameUnit(_ unit: UInt16) -> Bool { unit != 45 && EditorLexicalCursor.name(unit) }
        func take(_ word: String) -> Bool {
            let count = word.utf16.count
            guard cursor + count <= limit,
                  source.substring(with: NSRange(location: cursor, length: count)) == word,
                  unit(count).map({ nameUnit($0) || EditorLexicalCursor.digit($0) }) != true else { return false }
            cursor += count
            skipTrivia()
            return true
        }
        func qualifiedType() -> Bool {
            repeat {
                guard unit().map(nameUnit) == true else { return false }
                while let next = unit(), nameUnit(next) || EditorLexicalCursor.digit(next) { cursor += 1 }
                if unit() != 46 { return true }
                cursor += 1
            } while true
        }
        skipTrivia()
        _ = take("async")
        if !take("throws") { _ = take("rethrows") }
        if unit() == 45, unit(1) == 62 {
            cursor += 2
            skipTrivia()
            if !take("some") { _ = take("any") }
            guard qualifiedType() else { return nil }
            if unit() == 63 || unit() == 33 { cursor += 1 }
            skipTrivia()
        }
        return unit() == 123 ? cursor : nil
    }

    static func sectionScopes(_ entries: [Entry], end: Int) -> [Scope] {
        var active: [Entry] = []
        var scopes: [Scope] = []
        for heading in entries where heading.kind == .heading {
            while let prior = active.last, prior.depth >= heading.depth {
                scopes.append(Scope(entry: active.removeLast(), end: heading.offset))
            }
            active.append(heading)
        }
        for heading in active { scopes.append(Scope(entry: heading, end: end + 1)) }
        return scopes.sorted { $0.entry.offset < $1.entry.offset }
    }

    private static func propertyBraces(_ entries: [Entry], source: NSString, tokens: [TextSyntaxToken],
                                       cancelled: () -> Bool) -> [Int: Entry] {
        let properties = Dictionary(uniqueKeysWithValues: entries.map { ($0.offset, $0) })
        var owner: Entry?
        var sawColon = false
        var braces: [Int: Entry] = [:]
        for (index, token) in tokens.enumerated() {
            if index.isMultiple(of: 128), cancelled() { return [:] }
            if token.kind == .comment { continue }
            if token.kind == .property {
                owner = properties[token.range.location]; sawColon = false
                continue
            }
            guard let pending = owner else { continue }
            if token.kind == .punctuation {
                let mark = source.character(at: token.range.location)
                if mark == 58, !sawColon { sawColon = true; continue }
                if sawColon, mark == 91 || mark == 123 { braces[token.range.location] = pending }
            }
            owner = nil
        }
        return braces
    }
}
