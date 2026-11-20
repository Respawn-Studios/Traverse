import Foundation

/// Named C-family definitions with recognizable headers. The lexical tokens
/// and matched delimiters already exclude comments and strings.
enum EditorCFamilyOutline {
    struct Declaration {
        let name: String
        let kind: EditorDocumentOutline.Entry.Kind
        let line: Int
        let indent: Int
    }

    static let languages: Set<TextSyntaxLanguage> = [.c, .cpp, .objectiveC, .objectiveCPP]

    private static let typeKeywords: Set<String> = ["struct", "union", "enum", "class", "namespace"]
    private static let objectiveKeywords: Set<String> = ["@interface", "@implementation", "@protocol"]
    private static let specifiers: Set<String> = ["static", "inline", "extern", "constexpr", "consteval", "const", "volatile",
        "virtual", "register", "friend", "explicit", "mutable", "restrict", "_Noreturn"]
    private static let statementWords: Set<String> = ["if", "else", "while", "for", "switch", "case", "return", "throw",
        "co_return", "co_yield", "new", "delete", "using", "typedef", "goto", "do", "catch", "sizeof"]
    private static let qualifiers: Set<String> = ["const", "volatile", "noexcept", "override", "final", "&", "&&"]

    static func declaration(for token: TextSyntaxToken, in source: NSString, lines: EditorLineIndex,
                            language: TextSyntaxLanguage, pairs: EditorDelimiterWalk.MatchIndex?) -> Declaration? {
        switch token.kind {
        case .keyword, .function, .type: break
        default: return nil
        }
        let offset = token.range.location
        guard token.range.length <= 128, let location = lines.location(at: offset), location.column <= 257 else { return nil }
        let start = offset + 1 - location.column
        // A continued directive line does not introduce an ordinary definition.
        guard start < 2 || source.character(at: start - 2) != 92 else { return nil }
        let word = source.substring(with: token.range)
        let prefix = source.substring(with: .init(location: start, length: offset - start))
        let indent = prefix.utf16.prefix { $0 == 9 || $0 == 32 }.count
        let end = NSMaxRange(token.range)
        let cpp = language == .cpp || language == .objectiveCPP
        let objective = language == .objectiveC || language == .objectiveCPP
        if token.kind == .keyword {
            guard typeKeywords.contains(word) || objective && objectiveKeywords.contains(word),
                  let name = typeName(word, after: end, in: source, prefix: prefix, cpp: cpp) else { return nil }
            return .init(name: name, kind: .type, line: location.line, indent: indent)
        }
        guard !statementWords.contains(word), identifier(in: word[...]) == word[...], hasReturnType(prefix),
              let opening = afterSpace(end, in: source), source.character(at: opening) == 40,
              let match = pairs?.matchingOffsets(at: .init(location: opening, length: 1)), match.1 > opening,
              match.1 - opening <= 2_048, lines.location(at: match.1)?.line == location.line,
              hasBody(after: match.1 + 1, in: source, cpp: cpp) else { return nil }
        return .init(name: word, kind: .function, line: location.line, indent: indent)
    }

    private static func typeName(_ word: String, after offset: Int, in source: NSString, prefix: String, cpp: Bool) -> String? {
        let modifiers = prefix.split(whereSeparator: \.isWhitespace)
        guard modifiers.isEmpty || (word == "namespace" ? cpp && modifiers == ["inline"] : modifiers == ["typedef"]),
              offset < source.length, [9, 32].contains(source.character(at: offset)) else { return nil }
        let bounds = source.lineRange(for: .init(location: offset, length: 0))
        let available = min(256, NSMaxRange(bounds) - offset)
        var tail = source.substring(with: .init(location: offset, length: available))[...].drop(while: horizontal)
        if cpp && word == "enum", let scope = identifier(in: tail), scope == "class" || scope == "struct" {
            tail = tail[scope.endIndex...].drop(while: horizontal)
        }
        guard let name = identifier(in: tail), !statementWords.contains(String(name)), !typeKeywords.contains(String(name)) else { return nil }
        tail = tail[name.endIndex...]
        if objectiveKeywords.contains(word) {
            let next = tail.drop(while: horizontal).first
            return next == nil || next == ":" || next == "(" || next == "<" || next == "{" || next?.isNewline == true
                ? String(name) : nil
        }
        guard cpp || word != "class" && word != "namespace" else { return nil }
        var suffix = tail.drop(while: horizontal)
        if cpp, let qualifier = identifier(in: suffix), qualifier == "final" {
            suffix = suffix[qualifier.endIndex...].drop(while: horizontal)
        }
        if cpp, suffix.first == ":", word != "namespace", let brace = suffix.firstIndex(of: "{") {
            // A simple base list or underlying enum type, excluding members,
            // initializers and anything hidden by a lexical string or comment.
            let bases = suffix[suffix.index(after: suffix.startIndex)..<brace]
            guard !bases.trimmingCharacters(in: .whitespaces).isEmpty,
                  bases.allSatisfy({ $0.isLetter || $0.isNumber || horizontal($0) || "_:,<>&*".contains($0) }) else { return nil }
            return String(name)
        }
        let nameEnd = offset + available - tail.utf16.count
        return hasBody(after: nameEnd, in: source, cpp: cpp) ? String(name) : nil
    }

    private static func hasReturnType(_ prefix: String) -> Bool {
        let words = prefix.split { $0.isWhitespace || $0 == "*" || $0 == "&" }
        return !words.isEmpty && words.contains { !specifiers.contains(String($0)) }
            && words.allSatisfy { word in
                let names = word.split(separator: ":")
                return !names.isEmpty && names.allSatisfy { name in
                    identifier(in: name) == name && !statementWords.contains(String(name))
                }
            }
    }

    private static func hasBody(after offset: Int, in source: NSString, cpp: Bool) -> Bool {
        guard offset < source.length else { return false }
        let tail = source.substring(with: .init(location: offset, length: min(256, source.length - offset)))
        let header = tail.prefix { !$0.isNewline }
        let qualifiersOnly: (Substring) -> Bool = { text in
            let words = text.split(whereSeparator: horizontal)
            return words.isEmpty || (cpp && words.allSatisfy { qualifiers.contains(String($0)) })
        }
        if let brace = header.firstIndex(of: "{") { return qualifiersOnly(header[..<brace]) }
        guard qualifiersOnly(header), tail.count > header.count else { return false }
        let next = tail.dropFirst(header.count + 1).drop(while: horizontal)
        return next.first == "{"
    }

    private static func afterSpace(_ start: Int, in source: NSString) -> Int? {
        let limit = min(source.length, start + 256)
        var offset = start
        while offset < limit, [9, 32].contains(source.character(at: offset)) { offset += 1 }
        return offset < limit ? offset : nil
    }

    private static func identifier(in tail: Substring) -> Substring? {
        guard let first = tail.unicodeScalars.first, first == "_" || first.properties.isXIDStart else { return nil }
        let scalars = tail.unicodeScalars.prefix { $0 == "_" || $0.properties.isXIDContinue }
        return tail[..<scalars.endIndex]
    }

    private static func horizontal(_ value: Character) -> Bool { value == " " || value == "\t" }
}
