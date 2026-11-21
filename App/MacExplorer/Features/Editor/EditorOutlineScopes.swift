import Foundation

/// Scope boundaries are prepared from lexical structure before presentation.
enum EditorOutlineScopes {
    typealias Entry = EditorDocumentOutline.Entry
    typealias Scope = EditorDocumentOutline.Scope

    static func build(entries: [Entry], source: NSString, lines: EditorLineIndex, tokens: [TextSyntaxToken],
                      language: TextSyntaxLanguage, preparedPairs: [EditorDelimiterWalk.Pair]?, cancelled: () -> Bool) -> [Scope] {
        guard !entries.isEmpty, !cancelled() else { return [] }
        let cFamily = EditorCFamilyOutline.languages.contains(language)
        switch language {
        case .markdown, .ini: return sectionScopes(entries, end: source.length)
        case .yaml: return yamlScopes(entries, source: source, lines: lines, tokens: tokens, cancelled: cancelled)
        case .python:
            guard let preparedPairs else { return [] }
            return pythonScopes(entries, source: source, lines: lines, tokens: tokens, pairs: preparedPairs, cancelled: cancelled)
        case .json, .jsonc, .swift, .rust, .go: break
        case _ where cFamily: break
        default: return []
        }
        let json = language == .json || language == .jsonc
        let propertyOwners = json ? propertyBraces(entries, source: source, tokens: tokens, cancelled: cancelled) : [:]
        // The outline entry always points to the declaration keyword.
        let declarations = json || cFamily ? [:] : Dictionary(grouping: entries) { $0.signatureLine ?? $0.line }
        var knownBodies: [Int: Entry] = [:]
        if cFamily {
            for entry in entries {
                if let opening = entry.bodyOpening { knownBodies[opening] = entry }
            }
        }
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
            } else if cFamily {
                owner = pair.openingUnit == 123 ? knownBodies[pair.opening] : nil
            } else if pair.openingUnit == 123, !pair.insideExpression,
                      let line = lines.location(at: pair.opening)?.line {
                owner = swiftBodies[pair.opening] ?? declarations[line]?.last { entry in
                    let length = pair.opening - entry.offset
                    guard (1...2_048).contains(length) else { return false }
                    let header = source.substring(with: .init(location: entry.offset, length: length))
                    let word = header.prefix { !$0.isWhitespace }
                    if language == .go {
                        let last = header.split(whereSeparator: \.isWhitespace).last
                        let beginsUnnamedType = last == "struct" || last == "interface"
                        return !header.contains(";") && (entry.kind == .type ? beginsUnnamedType : !beginsUnnamedType)
                    }
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

    static func sectionScopes(_ entries: [Entry], end: Int?) -> [Scope] {
        var active: [Entry] = []
        var scopes: [Scope] = []
        for heading in entries where heading.kind == .heading {
            while let prior = active.last, prior.depth >= heading.depth {
                let prior = active.removeLast()
                scopes.append(Scope(entry: prior, end: heading.offset, contentStartsAfterLine: prior.line))
            }
            active.append(heading)
        }
        if let end {
            for heading in active { scopes.append(Scope(entry: heading, end: end + 1, contentStartsAfterLine: heading.line)) }
        }
        return scopes.sorted { $0.entry.offset < $1.entry.offset }
    }

    private static func yamlScopes(_ entries: [Entry], source: NSString, lines: EditorLineIndex,
                                   tokens: [TextSyntaxToken], cancelled: () -> Bool) -> [Scope] {
        struct Block {
            let entry: Entry
            let indent: Int
            let headerEnd: Int
            let acceptsIndentlessSequence: Bool
        }
        let keys = Dictionary(uniqueKeysWithValues: entries.map { ($0.offset, $0) })
        var headers: [Int: Block] = [:]
        for (index, key) in tokens.enumerated() where key.kind == .property {
            if cancelled() { return [] }
            guard let entry = keys[key.range.location], let line = lines.contentRange(at: entry.line - 1),
                  tokens.indices.contains(index + 1) else { continue }
            let colon = tokens[index + 1], end = NSMaxRange(line)
            guard colon.kind == .punctuation, colon.range.location < end,
                  source.character(at: colon.range.location) == 58 else { continue }
            var value = NSMaxRange(colon.range)
            while value < end, EditorLexicalCursor.horizontal(source.character(at: value)) {
                if value.isMultiple(of: 256), cancelled() { return [] }
                value += 1
            }
            let empty = value == end || source.character(at: value) == 35
            let blockScalar = value < end && [124, 62].contains(source.character(at: value))
                && tokens.indices.contains(index + 2) && tokens[index + 2].kind == .punctuation
                && tokens[index + 2].range.location == value
            guard empty || blockScalar else { continue }
            headers[entry.line - 1] = .init(entry: entry, indent: key.range.location - line.location,
                headerEnd: lines.start(ofLine: entry.line + 1) ?? source.length, acceptsIndentlessSequence: empty)
        }
        guard !headers.isEmpty else { return [] }

        var active: [Block] = [], scopes: [Scope] = []
        var lastContentEnd = 0, tokenIndex = 0
        func finishBlock() {
            let block = active.removeLast()
            if lastContentEnd > block.headerEnd {
                scopes.append(.init(entry: block.entry, end: lastContentEnd, contentStartsAfterLine: block.entry.line))
            }
        }
        for row in 0..<lines.contentLineCount {
            if cancelled() { return [] }
            guard let line = lines.contentRange(at: row) else { break }
            let start = line.location, end = NSMaxRange(line)
            let nextLine = lines.start(ofLine: row + 2) ?? source.length
            while tokenIndex < tokens.count && NSMaxRange(tokens[tokenIndex].range) <= start { tokenIndex += 1 }
            let string = tokenIndex < tokens.count && tokens[tokenIndex].kind == .string ? tokens[tokenIndex].range : nil
            if let string, string.location < start {
                lastContentEnd = nextLine
                continue
            }
            var first = start
            while first < end && source.character(at: first) == 32 {
                if first.isMultiple(of: 256), cancelled() { return [] }
                first += 1
            }
            guard first < end else { continue }
            let indicator = source.character(at: first), indent = first - start
            // The lexer distinguishes a literal '# …' line in a block scalar
            // from a comment. Trailing comments stay outside a folded value.
            guard indicator != 35 || string?.location == start else { continue }
            let sequenceItem = indicator == 45 && (first + 1 == end || EditorLexicalCursor.horizontal(source.character(at: first + 1)))
            while let block = active.last, indent <= block.indent {
                if indent == block.indent && block.acceptsIndentlessSequence && sequenceItem { break }
                finishBlock()
            }
            if let header = headers[row] { active.append(header) }
            lastContentEnd = nextLine
        }
        while !active.isEmpty { finishBlock() }
        return scopes.sorted { $0.entry.offset < $1.entry.offset }
    }

    private static func pythonScopes(_ entries: [Entry], source: NSString, lines: EditorLineIndex, tokens: [TextSyntaxToken],
                                     pairs: [EditorDelimiterWalk.Pair], cancelled: () -> Bool) -> [Scope] {
        struct Suite {
            let entry: Entry
            let indent: Int
            let headerLine: Int
            let headerEnd: Int
        }
        let declarations = Dictionary(grouping: entries, by: \.line)
        let continuation = Dictionary(uniqueKeysWithValues: pairs.map { ($0.opening, $0.closing) })
        let opaque = Dictionary(uniqueKeysWithValues: tokens.lazy.filter { $0.kind == .string || $0.kind == .comment }
            .map { ($0.range.location, $0) })
        var cursor = 0, priorEnd = 0, nextPoll = 0
        var active: [Suite] = [], scopes: [Scope] = []
        func finishSuite() {
            let suite = active.removeLast()
            if priorEnd > suite.headerEnd {
                scopes.append(.init(entry: suite.entry, end: priorEnd, contentStartsAfterLine: suite.headerLine))
            }
        }
        func sortedScopes() -> [Scope] { scopes.sorted { $0.entry.offset < $1.entry.offset } }
        func unit(at offset: Int) -> UInt16? { offset < source.length ? source.character(at: offset) : nil }
        while cursor < source.length {
            if cancelled() { return [] }
            var indent = 0
            if unit(at: cursor) == 12 { cursor += 1 }
            while let next = unit(at: cursor), EditorLexicalCursor.horizontal(next) {
                indent = next == 9 ? (indent / 8 + 1) * 8 : indent + 1
                cursor += 1
            }
            guard let first = unit(at: cursor) else { break }
            if first == 10 { cursor += 1; continue }
            if let comment = opaque[cursor], comment.kind == .comment { cursor = NSMaxRange(comment.range); continue }
            guard first != 12, let startLine = lines.location(at: cursor)?.line else { return sortedScopes() }
            while let suite = active.last, indent <= suite.indent { finishSuite() }
            var lastCode = cursor
            // A logical line can cross physical lines inside a string, a
            // matched expression, or an explicit backslash continuation.
            while let next = unit(at: cursor), next != 10 {
                if cursor >= nextPoll {
                    if cancelled() { return [] }
                    nextPoll = cursor + 256
                }
                if let token = opaque[cursor] {
                    if token.kind == .string { lastCode = NSMaxRange(token.range) - 1 }
                    cursor = NSMaxRange(token.range)
                } else if next == 92 && unit(at: cursor + 1) == 10 {
                    cursor += 2
                } else if next == 40 || next == 91 || next == 123 {
                    guard let end = continuation[cursor] else { return sortedScopes() }
                    lastCode = end
                    cursor = end + 1
                } else {
                    if next == 41 || next == 93 || next == 125 || next == 12 { return sortedScopes() }
                    if !EditorLexicalCursor.horizontal(next) { lastCode = cursor }
                    cursor += 1
                }
            }
            if unit(at: cursor) == 10 { cursor += 1 }
            priorEnd = cursor
            if let candidates = declarations[startLine], candidates.count == 1, let entry = candidates.first,
               source.character(at: lastCode) == 58, let header = lines.location(at: lastCode)?.line {
                active.append(.init(entry: entry, indent: indent, headerLine: header, headerEnd: cursor))
            }
        }
        while !active.isEmpty { finishSuite() }
        return sortedScopes()
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
