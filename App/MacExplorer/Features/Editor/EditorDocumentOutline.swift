import Foundation

/// A bounded view of the already-open buffer's prepared syntax. Its offsets
/// use the same coordinate space as the editor's line index and native caret.
struct EditorDocumentOutline: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Availability: Equatable, Sendable { case unsupported, ready, limited }

    struct Entry: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Kind: Hashable, Sendable {
            case heading, property, type, function

            var isDeclaration: Bool { self == .type || self == .function }

            var icon: String {
                switch self {
                case .heading: "text.alignleft"
                case .property: "curlybraces"
                case .type: "square.stack.3d.up"
                case .function: "function"
                }
            }
        }
        let title: String
        let line: Int
        let offset: Int
        let depth: Int
        let kind: Kind
        let signatureLine: Int?
        let parametersOffset: Int?
        let bodyOpening: Int?

        init(title: String, line: Int, offset: Int, depth: Int, kind: Kind,
             signatureLine: Int? = nil, parametersOffset: Int? = nil, bodyOpening: Int? = nil) {
            self.title = title; self.line = line; self.offset = offset
            self.depth = depth; self.kind = kind; self.signatureLine = signatureLine
            self.parametersOffset = parametersOffset
            self.bodyOpening = bodyOpening
        }

        var description: String { "<editor outline entry>" }
        var debugDescription: String { description }
    }

    struct Scope: Equatable, Sendable {
        let entry: Entry
        let end: Int
        let contentStartsAfterLine: Int?

        init(entry: Entry, end: Int, contentStartsAfterLine: Int? = nil) {
            self.entry = entry
            self.end = end
            self.contentStartsAfterLine = contentStartsAfterLine
        }
    }

    struct Match: Sendable, CustomStringConvertible {
        let entry: Entry
        let preview: String
        var description: String { "<document declaration match>" }
    }

    static let maximumEntries = 512
    static let declarationLanguages = Set<TextSyntaxLanguage>([.swift, .python, .rust, .javascript, .typescript, .go])
        .union(EditorCFamilyOutline.languages)
    private static let maximumTitleUnits = 180
    private static let swiftTypeIntroducers: Set<String> = ["actor", "associatedtype", "class", "enum", "extension", "protocol", "struct", "typealias"]
    private static let swiftModifiers: Set<String> = ["class", "convenience", "distributed", "dynamic", "fileprivate", "final", "internal", "isolated", "mutating", "nonisolated", "nonmutating", "open", "override", "package", "private", "public", "required", "static"]
    private static let rustTypeIntroducers: Set<String> = ["enum", "impl", "mod", "struct", "trait", "type", "union"]
    private static let rustModifiers: Set<String> = ["async", "auto", "const", "default", "extern", "pub", "safe", "unsafe"]
    private static let scriptModifiers: Set<String> = ["async", "default", "export"]
    private static let typeScriptModifiers: Set<String> = ["abstract", "const", "declare"]
    private static let typeScriptIntroducers: Set<String> = ["enum", "interface", "namespace", "type"]
    let availability: Availability
    let entries: [Entry]
    let scopes: [Scope]
    var description: String { "<editor document outline>" }
    var debugDescription: String { description }

    private init(availability: Availability, entries: [Entry], scopes: [Scope] = []) {
        self.availability = availability
        self.entries = entries
        self.scopes = scopes
    }

    func scrolledScopes(at offset: Int, onLine line: Int, limit: Int = 2) -> [Entry] {
        let visible = scopes.reversed().lazy.filter {
            ($0.contentStartsAfterLine ?? $0.entry.line) < line && $0.entry.offset <= offset && offset < $0.end
        }
            .prefix(limit)
        return Array(visible.map(\.entry).reversed())
    }

    func scope(containing selection: NSRange, includesStart: Bool = true) -> Scope? {
        scopes.last { scope in
            (includesStart ? scope.entry.offset <= selection.location : scope.entry.offset < selection.location)
                && selection.location < scope.end && NSMaxRange(selection) <= scope.end
        }
    }

    func completions(startingWith prefix: String, language: TextSyntaxLanguage) -> [Entry] {
        guard availability == .ready, Self.isIdentifier(prefix, language: language) else { return [] }
        var seen = Set<[UInt16]>()
        return Array(entries.filter { entry in
            entry.kind.isDeclaration && entry.title.utf16.count > prefix.utf16.count
                && entry.title.utf16.starts(with: prefix.utf16)
                && Self.isIdentifier(entry.title, language: language)
                && seen.insert(Array(entry.title.utf16)).inserted
        }.sorted { $0.title.utf16.lexicographicallyPrecedes($1.title.utf16) }.prefix(100))
    }

    private static func isIdentifier(_ name: String, language: TextSyntaxLanguage) -> Bool {
        let script = language == .javascript || language == .typescript
        let units = name.unicodeScalars
        guard let first = units.first, first == "_" || first.properties.isXIDStart || script && first == "$" else { return false }
        return units.dropFirst().allSatisfy { isIdentifierContinuation($0, language: language) }
    }

    static func isIdentifierContinuation(_ scalar: Unicode.Scalar, language: TextSyntaxLanguage) -> Bool {
        let script = language == .javascript || language == .typescript
        return scalar == "_" || scalar.properties.isXIDContinue
            || script && (scalar == "$" || scalar.value == 0x200C || scalar.value == 0x200D)
    }

    static func prepare(text: String, syntax: TextSyntaxResult, language: TextSyntaxLanguage, lines: EditorLineIndex,
                        preparedDelimiters: EditorDelimiterWalk.Capture? = nil,
                        cancelled: @Sendable () -> Bool) -> Self {
        guard declarationLanguages.contains(language) || [.markdown, .json, .jsonc, .yaml, .ini, .toml].contains(language) else {
            return .init(availability: .unsupported, entries: [])
        }
        guard case .tokens(let tokens) = syntax else { return .init(availability: .limited, entries: []) }
        let source = text as NSString
        if language == .toml {
            let result = EditorTOMLOutline.read(source, lines: lines, tokens: tokens, cancelled: cancelled)
            let scopes = EditorOutlineScopes.sectionScopes(result.entries, end: result.limited ? nil : source.length)
            return .init(availability: result.limited ? .limited : .ready, entries: result.entries, scopes: scopes)
        }
        var entries: [Entry] = []
        var containers: [UInt16] = []
        var indents: [Int] = []
        var hasINISection = false
        let tracksCollections = language == .yaml || language == .json || language == .jsonc
        for (index, token) in tokens.enumerated() {
            if index.isMultiple(of: 128), cancelled() { return .init(availability: .limited, entries: []) }
            if tracksCollections && token.kind == .punctuation {
                let mark = source.character(at: token.range.location)
                switch mark {
                case 91, 123:
                    guard containers.count < 64 else { return .init(availability: .limited, entries: entries) }
                    containers.append(mark)
                case 93, 125:
                    let expected: UInt16 = mark == 93 ? 91 : 123
                    guard containers.popLast() == expected else { return .init(availability: .limited, entries: entries) }
                default: break
                }
                continue
            }
            let entry: Entry?
            switch language {
            case .markdown:
                entry = token.kind == .keyword ? heading(token.range, source: source, lines: lines) : nil
            case .swift, .python, .rust, .javascript, .typescript, .go:
                entry = token.kind == .keyword
                    ? declaration(token.range, source: source, lines: lines, language: language,
                                  following: tokens[(index + 1)...], indents: &indents) : nil
            case .c, .cpp, .objectiveC, .objectiveCPP:
                entry = EditorCFamilyOutline.declaration(for: token, in: source, lines: lines, language: language,
                    pairs: preparedDelimiters?.matches).map { declaration in
                    .init(title: declaration.name, line: declaration.line, offset: token.range.location,
                          depth: outlineDepth(at: declaration.indent, levels: &indents), kind: declaration.kind,
                          bodyOpening: declaration.bodyOpening)
                }
            case .yaml:
                if token.kind == .keyword { indents.removeAll(keepingCapacity: true) }
                entry = token.kind == .property && containers.isEmpty
                    ? yamlKey(token.range, source: source, lines: lines, indents: &indents) : nil
            case .ini:
                let start = token.range.location
                if let line = lines.location(at: start)?.line, token.kind == .keyword {
                    hasINISection = true
                    entry = .init(title: title(source, start: start + 1, length: token.range.length - 2),
                                  line: line, offset: start, depth: 0, kind: .heading)
                } else if let line = lines.location(at: start)?.line, token.kind == .property {
                    entry = .init(title: title(source, start: start, length: token.range.length),
                                  line: line, offset: start, depth: hasINISection ? 1 : 0, kind: .property)
                } else { entry = nil }
            case .json, .jsonc:
                if token.kind == .property, containers.last == 123, let line = lines.location(at: token.range.location)?.line {
                    let raw = title(source, start: token.range.location + 1, length: token.range.length - 2)
                    entry = .init(title: raw.isEmpty ? "Empty key" : raw, line: line, offset: token.range.location,
                                  depth: containers.count - 1, kind: .property)
                } else { entry = nil }
            default:
                entry = nil
            }
            if let entry {
                if entries.count == maximumEntries { return .init(availability: .limited, entries: entries) }
                entries.append(entry)
            }
        }
        let scopes = EditorOutlineScopes.build(entries: entries, source: source, lines: lines,
            tokens: tokens, language: language, preparedPairs: preparedDelimiters?.pairs, cancelled: cancelled)
        let limited = EditorCFamilyOutline.languages.contains(language) && preparedDelimiters == nil
        return .init(availability: limited ? .limited : .ready, entries: entries, scopes: scopes)
    }

    private static func yamlKey(_ range: NSRange, source: NSString, lines: EditorLineIndex, indents: inout [Int]) -> Entry? {
        let start = range.location, end = NSMaxRange(range)
        guard let location = lines.location(at: start), location.column <= 257, end > start,
              lines.location(at: end - 1)?.line == location.line else { return nil }
        var prefix = start + 1 - location.column
        // Only an indented block key or a compact sequence mapping key.
        // Mid-value colons, flow keys and explicit complex keys stay out.
        while prefix < start {
            let unit = source.character(at: prefix)
            if unit == 32 { prefix += 1 }
            else if unit == 45, prefix + 1 < start, source.character(at: prefix + 1) == 32 { prefix += 2 }
            else { return nil }
        }
        let first = source.character(at: start)
        let quoted = range.length >= 2 && (first == 34 || first == 39) && source.character(at: end - 1) == first
        let raw = title(source, start: start + (quoted ? 1 : 0), length: range.length - (quoted ? 2 : 0))
        let depth = outlineDepth(at: location.column - 1, levels: &indents)
        return .init(title: raw.isEmpty ? "Empty key" : raw, line: location.line, offset: start, depth: depth, kind: .property)
    }

    private static func outlineDepth(at indent: Int, levels: inout [Int]) -> Int {
        while let previous = levels.last, previous >= indent { levels.removeLast() }
        let depth = levels.count
        levels.append(indent)
        return depth
    }

    /// Recognize named declarations from bounded lexical headers.
    /// Indentation groups the rows. The lexer supplies comment and string boundaries.
    private static func declaration(_ range: NSRange, source: NSString, lines: EditorLineIndex,
                                    language: TextSyntaxLanguage, following: ArraySlice<TextSyntaxToken>,
                                    indents: inout [Int]) -> Entry? {
        guard range.length <= 16 else { return nil }
        let keyword = source.substring(with: range)
        let kind: Entry.Kind
        let unnamed = language == .swift && ["init", "deinit", "subscript"].contains(keyword)
        let script = language == .javascript || language == .typescript
        let scriptBinding = script && ["const", "let", "var"].contains(keyword)
        switch language {
        case .swift where unnamed || keyword == "func", .python where keyword == "def", .rust where keyword == "fn",
             .go where keyword == "func",
             .javascript where keyword == "function" || scriptBinding, .typescript where keyword == "function" || scriptBinding:
            kind = .function
        case .swift where swiftTypeIntroducers.contains(keyword), .python where keyword == "class",
             .rust where rustTypeIntroducers.contains(keyword), .javascript where keyword == "class",
             .go where keyword == "type",
             .typescript where keyword == "class" || typeScriptIntroducers.contains(keyword):
            kind = .type
        default: return nil
        }

        let offset = range.location
        guard let location = lines.location(at: offset), location.column <= 257 else { return nil }
        let start = offset + 1 - location.column
        let prefix = source.substring(with: .init(location: start, length: offset - start))
        let modifiers = prefix.split(whereSeparator: \.isWhitespace)
        switch language {
        case .swift:
            guard modifiers.allSatisfy({ swiftModifiers.contains(String($0))
                || $0.first == "@" && $0.dropFirst().first?.isLetter == true && $0.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } }) else { return nil }
        case .python:
            guard modifiers.isEmpty || (keyword == "def" && modifiers == ["async"]) else { return nil }
        case .rust:
            guard rustDeclarationPrefix(prefix) else { return nil }
        case .go:
            guard modifiers.isEmpty else { return nil }
        case .javascript, .typescript:
            guard modifiers.allSatisfy({ scriptModifiers.contains(String($0))
                || language == .typescript && typeScriptModifiers.contains(String($0)) }) else { return nil }
            if scriptBinding, !modifiers.isEmpty, modifiers != ["export"] { return nil }
        default: return nil
        }

        let end = NSMaxRange(range)
        let endOfLine = lines.start(ofLine: location.line + 1) ?? source.length
        let inline = source.substring(with: .init(location: end, length: min(maximumTitleUnits, endOfLine - end)))
        let firstContent = inline.drop(while: isHorizontalSpace)
        let continuesSwiftFunction = language == .swift && keyword == "func"
            && (firstContent.isEmpty || firstContent.first?.isNewline == true
                || firstContent.hasPrefix("//") || firstContent.hasPrefix("/*"))
        let candidate: String
        let candidateStart: Int
        let signatureLine: Int?
        if continuesSwiftFunction {
            guard let start = swiftFunctionName(after: end, source: source, following: following),
                  let line = lines.location(at: start)?.line, line - location.line <= 8 else { return nil }
            let nextEnd = lines.start(ofLine: line + 1) ?? source.length
            candidate = source.substring(with: .init(location: start, length: min(maximumTitleUnits, nextEnd - start)))
            candidateStart = start
            signatureLine = line
        } else {
            candidate = inline
            candidateStart = end
            signatureLine = nil
        }
        var lookahead = candidate.drop(while: isHorizontalSpace)
        let name: String
        if unnamed {
            // Swift member references can spell `init` without declaring it.
            guard keyword == "deinit" ? lookahead.first == "{" : "(?!<".contains(lookahead.first ?? " ") else { return nil }
            name = keyword
        } else if language == .rust && keyword == "impl" {
            // A complete introducing line distinguishes an implementation
            // block from an ordinary use of an opaque `impl Trait` type.
            let header = lookahead.prefix { $0 != "{" && !$0.isNewline }
            let bounds = header.range(of: " where ")
            guard lookahead.contains("{") || bounds != nil else { return nil }
            let subject = header[..<(bounds?.lowerBound ?? header.endIndex)].trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty else { return nil }
            name = (subject.first == "<" ? "impl" : "impl ") + subject
        } else {
            // A generator can write `function*` with no intervening space.
            if script, keyword == "function", lookahead.first == "*" {
                lookahead = lookahead.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            } else {
                guard continuesSwiftFunction || end < source.length && [9, 32].contains(source.character(at: end)) else { return nil }
            }
            if language == .go, keyword == "func", lookahead.first == "(" {
                guard let receiverEnd = lookahead.firstIndex(of: ")") else { return nil }
                lookahead = lookahead[lookahead.index(after: receiverEnd)...].drop(while: isHorizontalSpace)
            }
            if language == .swift && lookahead.first == "`" {
                let contents = lookahead.dropFirst()
                guard let close = contents.firstIndex(of: "`"), close != contents.startIndex else { return nil }
                name = String(contents[..<close])
            } else {
                let raw = language == .rust && lookahead.hasPrefix("r#")
                let identifier = raw ? lookahead.dropFirst(2) : lookahead
                guard let first = identifier.unicodeScalars.first,
                      first == "_" || first.properties.isXIDStart || script && first == "$" else { return nil }
                let scalars = identifier.unicodeScalars.prefix { isIdentifierContinuation($0, language: language)
                    || ["extension", "namespace"].contains(keyword) && $0 == "." }
                name = (raw ? "r#" : "") + String(scalars)
                // `class` can be a Swift method modifier.
                guard language != .swift || keyword != "class" || !["func", "var", "subscript"].contains(name) else { return nil }
                // An anonymous class can have a base class without a name.
                guard !script || keyword != "class" || name != "extends" else { return nil }
            }
        }
        var parametersOffset: Int?
        if language == .swift && keyword == "func" {
            let spelling = name.count + (lookahead.first == "`" ? 2 : 0)
            let rest = lookahead.dropFirst(spelling).drop(while: isHorizontalSpace)
            if continuesSwiftFunction, rest.first != "(", rest.first != "<" { return nil }
            if rest.first == "(" { parametersOffset = candidateStart + candidate.utf16.count - rest.utf16.count }
        }
        if language == .go && keyword == "func" {
            let rest = lookahead.dropFirst(name.count).drop(while: isHorizontalSpace)
            guard rest.first == "(" || rest.first == "[" else { return nil }
        }
        if scriptBinding {
            let afterName = end + candidate.utf16.count - lookahead.utf16.count + name.utf16.count
            guard scriptFunctionInitializer(at: afterName, through: end + candidate.utf16.count,
                in: source, tokens: following, typed: language == .typescript) else { return nil }
        }
        let indent = prefix.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { width, unit in
            unit == "\t" ? (width / 8 + 1) * 8 : width + 1
        }
        let depth = outlineDepth(at: indent, levels: &indents)
        return .init(title: name, line: location.line, offset: offset, depth: depth, kind: kind,
            signatureLine: signatureLine, parametersOffset: parametersOffset)
    }

    private static func isHorizontalSpace(_ value: Character) -> Bool { value == " " || value == "\t" }

    private static func swiftFunctionName(after offset: Int, source: NSString,
                                          following tokens: ArraySlice<TextSyntaxToken>) -> Int? {
        let limit = min(source.length, offset + 512)
        var position = offset
        func skipWhitespace() {
            while position < limit, EditorLexicalCursor.white(source.character(at: position)) { position += 1 }
        }
        skipWhitespace()
        for comment in tokens.prefix(8) {
            guard comment.kind == .comment, comment.range.location == position, NSMaxRange(comment.range) < limit else { break }
            position = NSMaxRange(comment.range)
            skipWhitespace()
        }
        return position > offset && position < limit ? position : nil
    }

    /// Recognize a direct function or arrow initializer on its introducing
    /// line. Calls, nested callbacks and type-only bindings do not add entries.
    private static func scriptFunctionInitializer(at start: Int, through limit: Int, in source: NSString,
                                                  tokens: ArraySlice<TextSyntaxToken>, typed: Bool) -> Bool {
        guard start < limit else { return false }
        let tail = source.substring(with: .init(location: start, length: limit - start))
        var remaining = tail.drop(while: isHorizontalSpace)
        if typed, remaining.first == ":" {
            guard let assignment = remaining.firstIndex(of: "="),
                  isSimpleScriptType(remaining[remaining.index(after: remaining.startIndex)..<assignment]) else { return false }
            remaining = remaining[assignment...]
        }
        guard remaining.first == "=" else { return false }
        remaining = remaining.dropFirst().drop(while: isHorizontalSpace)
        if remaining.hasPrefix("async") {
            let suffix = remaining.dropFirst(5)
            let arguments = suffix.drop(while: isHorizontalSpace)
            if suffix.first == "(" || (suffix.first.map(isHorizontalSpace) == true && !arguments.hasPrefix("=>")) {
                remaining = arguments
            }
        }
        if remaining.hasPrefix("function"), let next = remaining.dropFirst(8).first,
           next == "(" || next == "*" || isHorizontalSpace(next) {
            var header = remaining.dropFirst(8).drop(while: isHorizontalSpace)
            if header.first == "*" { header = header.dropFirst().drop(while: isHorizontalSpace) }
            let name = String(header.unicodeScalars.prefix { isIdentifierContinuation($0, language: .javascript) })
            return (name.isEmpty || isIdentifier(name, language: .javascript))
                && header.dropFirst(name.count).drop(while: isHorizontalSpace).first == "("
        }
        if remaining.first == "(" {
            let absolute = limit - remaining.utf16.count
            let arguments = String(remaining) as NSString
            let ignored = tokens.prefix(while: { $0.range.location < limit }).compactMap { token -> TextSyntaxToken? in
                guard token.range.location >= absolute, token.kind == .comment || token.kind == .string else { return nil }
                let range = NSIntersectionRange(token.range, .init(location: absolute, length: limit - absolute))
                return .init(range: .init(location: range.location - absolute, length: range.length), kind: token.kind)
            }
            var end: Int?
            _ = EditorDelimiterWalk.pairs(in: arguments, tokens: ignored, cancelled: { false }) { pair in
                guard pair.opening == 0 else { return true }
                end = pair.closing + 1
                return false
            }
            guard let end else { return false }
            let suffix = arguments.substring(from: end)
            remaining = suffix.drop(while: isHorizontalSpace)
            if typed, remaining.first == ":", let arrow = remaining.range(of: "=>") {
                let annotation = remaining[remaining.index(after: remaining.startIndex)..<arrow.lowerBound]
                guard isSimpleScriptType(annotation) else { return false }
                remaining = remaining[arrow.lowerBound...]
            }
        } else {
            let parameter = remaining.unicodeScalars.prefix { isIdentifierContinuation($0, language: .javascript) }
            let name = String(parameter)
            guard isIdentifier(name, language: .javascript) else { return false }
            remaining = remaining.dropFirst(name.count).drop(while: isHorizontalSpace)
        }
        return remaining.hasPrefix("=>")
    }

    private static func isSimpleScriptType(_ value: Substring) -> Bool {
        let type = value.trimmingCharacters(in: .whitespaces)
        guard let first = type.first, first.isLetter || first == "_" || first == "$" else { return false }
        var closes: [Character] = []
        for unit in type {
            switch unit {
            case "<": closes.append(">")
            case "[": closes.append("]")
            case ">", "]": guard closes.popLast() == unit else { return false }
            default: guard unit.isLetter || unit.isNumber || "_$. ,\t|&".contains(unit) else { return false }
            }
        }
        return closes.isEmpty
    }

    private static func rustDeclarationPrefix(_ prefix: String) -> Bool {
        var remaining = prefix.drop(while: \.isWhitespace)
        let visibility = remaining.hasPrefix("pub") ? remaining.dropFirst(3).drop(while: \.isWhitespace) : remaining
        if remaining.hasPrefix("pub"), visibility.first == "(" {
            guard let close = visibility.firstIndex(of: ")") else { return false }
            let scope = visibility[visibility.index(after: visibility.startIndex)..<close]
                .split(whereSeparator: \.isWhitespace)
            guard scope.count == 1 && ["crate", "self", "super"].contains(scope[0])
                || scope.first == "in" && scope.count > 1 && scope.dropFirst().allSatisfy({ part in
                    part.unicodeScalars.allSatisfy { $0.properties.isXIDContinue || $0 == ":" || $0 == "#" }
                }) else { return false }
            remaining = visibility[visibility.index(after: close)...]
            guard remaining.first?.isWhitespace == true else { return false }
        }
        var afterExtern = false
        for word in remaining.split(whereSeparator: \.isWhitespace) {
            guard rustModifiers.contains(String(word))
                || afterExtern && word.count > 2 && word.first == "\"" && word.last == "\"" else { return false }
            afterExtern = word == "extern"
        }
        return true
    }

    private static func heading(_ range: NSRange, source: NSString, lines: EditorLineIndex) -> Entry? {
        let start = range.location, end = NSMaxRange(range)
        var hashes = start
        while hashes < end, hashes - start < 6, source.character(at: hashes) == 35 { hashes += 1 }
        guard hashes > start, let line = lines.location(at: start)?.line else { return nil }
        let snippet = title(source, start: hashes, length: end - hashes).trimmingCharacters(in: .whitespaces)
        // A closing ATX sequence belongs to the heading syntax when separated
        // by whitespace. Keep embedded and escaped hashes in the actual name.
        let tail = snippet.reversed().prefix { $0 == "#" }.count
        let trimmed = snippet.dropLast(tail)
        let text = tail > 0 && (trimmed.isEmpty || trimmed.last?.isWhitespace == true)
            ? trimmed.trimmingCharacters(in: .whitespaces) : snippet
        return .init(title: text.isEmpty ? "Untitled heading" : text, line: line, offset: start,
                     depth: hashes - start - 1, kind: .heading)
    }

    static func title(_ source: NSString, start: Int, length: Int) -> String {
        var count = min(maximumTitleUnits, length)
        if count < length, (0xD800...0xDBFF).contains(source.character(at: start + count - 1)) { count -= 1 }
        let text = source.substring(with: .init(location: start, length: count))
        return length > count ? text + "…" : text
    }
}
