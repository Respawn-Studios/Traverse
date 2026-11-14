import Foundation
#if canImport(FileOperations)
import FileOperations
#endif

enum TextSyntaxLanguage: String, Codable, Equatable, Sendable, CaseIterable {
    case plain, swift, python, json, jsonc, javascript, typescript, rust, shell, sql, toml, css, yaml, html, xml, markdown, dockerfile, makefile
    case c, cpp, objectiveC, objectiveCPP
    var title: String {
        switch self {
        case .plain: "Plain Text"
        case .swift: "Swift"
        case .python: "Python"
        case .json: "JSON"
        case .jsonc: "JSON with Comments"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .rust: "Rust"
        case .shell: "Shell"
        case .sql: "SQL"
        case .toml: "TOML"
        case .css: "CSS"
        case .yaml: "YAML"
        case .html: "HTML"
        case .xml: "XML"
        case .markdown: "Markdown"
        case .dockerfile: "Dockerfile"
        case .makefile: "Makefile"
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .objectiveCPP: "Objective-C++"
        }
    }
    static func inferred(extension value: String) -> Self {
        switch value.lowercased() {
        case "swift": .swift
        case "py", "pyw": .python
        case "json": .json
        case "jsonc": .jsonc
        case "js", "mjs", "cjs", "jsx": .javascript
        case "ts", "mts", "cts", "tsx": .typescript
        case "rs": .rust
        case "sh", "bash", "zsh": .shell
        case "sql": .sql
        case "toml": .toml
        case "css", "scss", "less": .css
        case "yml", "yaml": .yaml
        case "htm", "html": .html
        case "xml": .xml
        case "md", "markdown": .markdown
        case "dockerfile", "containerfile": .dockerfile
        case "mk", "mak": .makefile
        case "c", "h": .c
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx": .cpp
        case "m": .objectiveC
        case "mm": .objectiveCPP
        default: .plain
        }
    }
    /// Only already-open editor text is inspected, on the existing preparation
    /// queue. Ambiguous input stays plain. No inference renames or saves a file.
    static func detected(in text: String, cancelled: @Sendable () -> Bool = { false }) -> Self? {
        guard !cancelled() else { return nil }
        let first = text.prefix(512).split(maxSplits: 1, omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }).first
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.hasPrefix("#!") {
            var words = first.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !words.isEmpty else { return nil }
            var command = (words.removeFirst() as NSString).lastPathComponent
            if command == "env" {
                if words.first == "-S" { words.removeFirst() }
                guard let interpreter = words.first, !interpreter.hasPrefix("-") else { return nil }
                command = (interpreter as NSString).lastPathComponent
            }
            if command == "python" || (command.hasPrefix("python") && !command.dropFirst(6).isEmpty
                && command.utf8.dropFirst(6).allSatisfy({ (48...57).contains($0) || $0 == 46 })) { return .python }
            if ["sh", "bash", "zsh", "ksh", "fish"].contains(command) { return .shell }
            if ["node", "nodejs", "bun"].contains(command) { return .javascript }
            return nil
        }
        let prefix = text.prefix(512).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<?xml ") || prefix.hasPrefix("<?xml\t") || prefix.hasPrefix("<?xml\n") || prefix.hasPrefix("<?xml\r") { return .xml }
        if prefix.hasPrefix("<!doctype html>") || prefix.hasPrefix("<!doctype html ") { return .html }
        guard !cancelled(), text.utf8.count <= 32 * 1024,
              let first = prefix.first, first == "{" || first == "[",
              let bytes = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes), !cancelled(),
              value is [String: Any] || value is [Any] else { return nil }
        return .json
    }
    var lineCommentStyle: EditorLineCommentStyle? {
        switch self {
        case .swift, .jsonc, .javascript, .typescript, .rust, .c, .cpp, .objectiveC, .objectiveCPP: .slash
        case .python, .shell, .toml, .yaml, .dockerfile, .makefile: .hash
        case .sql: .dash
        // Do not insert invalid line comments into strict JSON or markup.
        case .plain, .json, .css, .html, .xml, .markdown: nil
        }
    }
}
struct TextSyntaxToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case keyword, property, string, number, literal, punctuation, type, function, comment }
    let range: NSRange
    let kind: Kind
}
enum TextSyntaxResult: Sendable {
    enum Fallback: Sendable { case tokenBudget, commentNesting, cancelled }
    case tokens([TextSyntaxToken])
    case plain(Fallback)
}

// Presentation only. The loop consumes UTF-16 code units, so its ranges can be
// applied directly to NSTextStorage without byte/grapheme index conversions.
// It never executes/validates source or mutates text/Undo/document state.
enum TextSyntax {
    static let maximumTokens = 65_536
    static let maximumCommentNesting = 32
    static func color(_ value: TextDocumentValue, language: TextSyntaxLanguage,
                      cancelled: @Sendable () -> Bool = { false }) -> TextSyntaxResult {
        if cancelled() { return .plain(.cancelled) }
        if case .plain = language { return .tokens([]) }
        let units = Array(value.text.utf16)
        if language == .json || language == .jsonc { return colorJSON(units, cancelled: cancelled) }
        if language == .css { return EditorCSSSyntax.color(units, cancelled: cancelled) }
        if language == .yaml { return EditorYAMLSyntax.color(units, cancelled: cancelled) }
        if language == .html || language == .xml { return EditorMarkupSyntax.color(units, cancelled: cancelled) }
        if language == .markdown { return EditorMarkdownSyntax.color(units, cancelled: cancelled) }
        if [.c, .cpp, .objectiveC, .objectiveCPP].contains(language) {
            return EditorCFamilySyntax.color(units, language: language, cancelled: cancelled)
        }
        if language == .dockerfile || language == .makefile {
            return EditorBuildSyntax.color(units, language: language, cancelled: cancelled)
        }
        var tokens: [TextSyntaxToken] = []
        tokens.reserveCapacity(min(2048, units.count / 4))
        var index = 0, consumed = 0
        func letter(_ unit: UInt16) -> Bool { unit == 95 || (65...90).contains(unit) || (97...122).contains(unit) || unit >= 128 }
        func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
        func at(_ offset: Int, _ unit: UInt16) -> Bool { offset < units.count && units[offset] == unit }
        func advance(_ count: Int = 1) -> Bool {
            index += count; consumed += count
            if consumed >= 256 { consumed = 0; return !cancelled() }
            return true
        }
        func append(_ start: Int, _ kind: TextSyntaxToken.Kind) -> Bool {
            guard tokens.count < maximumTokens else { return false }
            tokens.append(.init(range: NSRange(location: start, length: index - start), kind: kind))
            return true
        }
        let keywords: Set<String>
        switch language {
        case .swift: keywords = ["actor", "async", "await", "break", "case", "catch", "class", "continue", "defer", "do", "else", "enum", "false", "for", "func", "guard", "if", "import", "in", "let", "nil", "private", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "while"]
        case .python: keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .json, .jsonc: keywords = ["true", "false", "null"]
        case .javascript, .typescript: keywords = ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"]
        case .rust: keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .shell: keywords = ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "until", "while"]
        case .sql: keywords = ["all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check", "column", "commit", "constraint", "create", "cross", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "except", "exists", "false", "foreign", "from", "full", "group", "having", "if", "in", "index", "inner", "insert", "intersect", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary", "references", "returning", "right", "rollback", "select", "set", "table", "then", "true", "union", "unique", "update", "using", "values", "view", "when", "where", "with"]
        case .toml: keywords = ["true", "false", "inf", "nan"]
        case .plain, .css, .yaml, .html, .xml, .markdown, .dockerfile, .makefile, .c, .cpp, .objectiveC, .objectiveCPP: keywords = []
        }
        let literalWords = literals(for: language), typeWords = types(for: language)
        let slashComments = [.swift, .javascript, .typescript, .rust].contains(language)
        let nestedComments = [.swift, .rust, .sql].contains(language)
        let singleQuotes = [.python, .javascript, .typescript, .shell, .sql, .toml].contains(language)
        while index < units.count {
            let start = index, unit = units[index]
            // A Rust lifetime is not a quoted string. Raw/character literals
            // are handled before the general identifier and quote branches.
            if language == .rust && (unit == 114 || (unit == 98 || unit == 99) && at(index + 1, 114)) {
                var opening = index + (unit == 114 ? 1 : 2), hashes = 0
                while at(opening, 35) && hashes < 256 { opening += 1; hashes += 1 }
                if hashes < 256 && at(opening, 34) {
                    if !advance(opening - index + 1) { return .plain(.cancelled) }
                    while index < units.count {
                        if at(index, 34) && (0..<hashes).allSatisfy({ at(index + 1 + $0, 35) }) {
                            if !advance(hashes + 1) { return .plain(.cancelled) }
                            break
                        }
                        if !advance() { return .plain(.cancelled) }
                    }
                    if !append(start, .string) { return .plain(.tokenBudget) }
                    continue
                }
            }
            if language == .sql && unit == 36 {
                var end = index + 1
                while end < units.count && end - index <= 128 && (letter(units[end]) || digit(units[end])) { end += 1 }
                if end - index <= 128 && at(end, 36) {
                    let delimiter = Array(units[index...end])
                    if !advance(delimiter.count) { return .plain(.cancelled) }
                    while index < units.count {
                        if index + delimiter.count <= units.count && delimiter.indices.allSatisfy({ units[index + $0] == delimiter[$0] }) {
                            if !advance(delimiter.count) { return .plain(.cancelled) }
                            break
                        }
                        if !advance() { return .plain(.cancelled) }
                    }
                    if !append(start, .string) { return .plain(.tokenBudget) }
                    continue
                }
            }
            if language == .rust && unit == 39 {
                var end = index + 1
                if at(end, 92) {
                    end += 1
                    if at(end, 117) && at(end + 1, 123) {
                        end += 2
                        while end < units.count && end - index <= 16 && units[end] != 125 { end += 1 }
                        if at(end, 125) { end += 1 }
                    } else if at(end, 120) { end += 3 }
                    else { end += 1 }
                } else if end < units.count {
                    end += (0xD800...0xDBFF).contains(units[end]) && end + 1 < units.count ? 2 : 1
                }
                if at(end, 39) {
                    if !advance(end - index + 1) { return .plain(.cancelled) }
                    if !append(start, .string) { return .plain(.tokenBudget) }
                    continue
                }
            }
            let hashComment = unit == 35 && ([.python, .toml].contains(language)
                || language == .shell && (index == 0 || [9, 10, 32, 59].contains(units[index - 1])))
            if hashComment || slashComments && unit == 47 && at(index + 1, 47)
                || language == .sql && unit == 45 && at(index + 1, 45) {
                while index < units.count && units[index] != 10 {
                    if !advance() { return .plain(.cancelled) }
                }
                if !append(start, .comment) { return .plain(.tokenBudget) }
            } else if (slashComments || language == .sql) && unit == 47 && at(index + 1, 42) {
                var depth = 1
                if !advance(2) { return .plain(.cancelled) }
                while index < units.count && depth > 0 {
                    if nestedComments && at(index, 47) && at(index + 1, 42) {
                        depth += 1
                        if depth > maximumCommentNesting { return .plain(.commentNesting) }
                        if !advance(2) { return .plain(.cancelled) }
                    } else if at(index, 42) && at(index + 1, 47) {
                        depth -= 1
                        if !advance(2) { return .plain(.cancelled) }
                    } else if !advance() { return .plain(.cancelled) }
                }
                if !append(start, .comment) { return .plain(.tokenBudget) }
            } else if unit == 34 || singleQuotes && unit == 39
                || [.javascript, .typescript, .shell].contains(language) && unit == 96 {
                let quote = unit
                let triple = [.swift, .python, .toml].contains(language) && at(index + 1, quote) && at(index + 2, quote)
                let literal = language == .toml && quote == 39 || language == .shell && quote == 39
                let doubled = language == .sql
                if !advance(triple ? 3 : 1) { return .plain(.cancelled) }
                while index < units.count {
                    if units[index] == 92 && !literal && !doubled {
                        if !advance(min(2, units.count - index)) { return .plain(.cancelled) }
                    } else if doubled && units[index] == quote && at(index + 1, quote) {
                        if !advance(2) { return .plain(.cancelled) }
                    } else if !triple && quote != 96 && units[index] == 10 && ![.sql, .shell].contains(language) {
                        break
                    } else if units[index] == quote && (!triple || at(index + 1, quote) && at(index + 2, quote)) {
                        if !advance(triple ? 3 : 1) { return .plain(.cancelled) }
                        break
                    } else if !advance() { return .plain(.cancelled) }
                }
                var after = index
                while after < units.count && [9, 10, 32].contains(units[after]) {
                    after += 1
                    if after % 256 == 0 && cancelled() { return .plain(.cancelled) }
                }
                let property = language == .json && after < units.count && units[after] == 58
                if !append(start, property || language == .sql && quote == 34 ? .property : .string) { return .plain(.tokenBudget) }
            } else if letter(unit) {
                if !advance() { return .plain(.cancelled) }
                while index < units.count && (letter(units[index]) || digit(units[index])) {
                    if !advance() { return .plain(.cancelled) }
                }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                let normalized = language == .sql ? word.lowercased() : word
                let kind: TextSyntaxToken.Kind?
                if literalWords.contains(normalized) { kind = .literal }
                else if keywords.contains(normalized) { kind = .keyword }
                else if typeWords.contains(word) { kind = .type }
                else {
                    var after = index
                    while after < units.count && [9, 32].contains(units[after]) {
                        after += 1
                        if after % 256 == 0 && cancelled() { return .plain(.cancelled) }
                    }
                    kind = at(after, 40) ? .function : nil
                }
                if let kind, !append(start, kind) { return .plain(.tokenBudget) }
            } else if digit(unit) || unit == 45 && index + 1 < units.count && digit(units[index + 1]) {
                if !advance() { return .plain(.cancelled) }
                while index < units.count && (digit(units[index]) || [46, 43, 45, 69, 101, 88, 120].contains(units[index])) {
                    if !advance() { return .plain(.cancelled) }
                }
                if !append(start, .number) { return .plain(.tokenBudget) }
            } else if !advance() { return .plain(.cancelled) }
        }
        return cancelled() ? .plain(.cancelled) : .tokens(tokens)
    }

    private static func literals(for language: TextSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift: ["true", "false", "nil"]
        case .python: ["True", "False", "None"]
        case .javascript, .typescript: ["true", "false", "null", "undefined"]
        case .rust: ["true", "false"]
        case .sql: ["true", "false", "null"]
        case .toml: ["true", "false", "inf", "nan"]
        case .json, .jsonc: ["true", "false", "null"]
        case .plain, .shell, .css, .yaml, .html, .xml, .markdown, .dockerfile, .makefile, .c, .cpp, .objectiveC, .objectiveCPP: []
        }
    }
    private static func types(for language: TextSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift: ["String", "Bool", "Int", "UInt", "Int64", "Double", "Float", "Data", "URL", "UUID", "Date", "Array", "Set", "Dictionary", "Optional", "Result", "Void", "Any", "Error"]
        case .python: ["str", "bool", "int", "float", "bytes", "list", "tuple", "dict", "set", "object"]
        case .javascript, .typescript: ["string", "boolean", "number", "bigint", "symbol", "unknown", "never", "Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "Error"]
        case .rust: ["str", "String", "bool", "char", "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "Vec", "Option", "Result", "Self"]
        default: []
        }
    }

    /// JSON/JSONC lexical presentation, not validation. Each code unit is
    /// consumed once apart from bounded token/trivia lookahead. Incomplete
    /// edits remain visible; malformed bare words/numbers receive no role.
    private static func colorJSON(_ units: [UInt16], cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        var tokens: [TextSyntaxToken] = []
        tokens.reserveCapacity(min(2048, units.count / 4))
        var index = 0, consumed = 0
        func at(_ offset: Int, _ unit: UInt16) -> Bool { offset < units.count && units[offset] == unit }
        func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
        func white(_ unit: UInt16) -> Bool { [9, 10, 13, 32].contains(unit) }
        func boundary(_ unit: UInt16) -> Bool { white(unit) || [34, 44, 58, 91, 93, 123, 125, 47].contains(unit) }
        func advance(_ count: Int = 1) -> Bool {
            index += count; consumed += count
            if consumed >= 256 { consumed = 0; return !cancelled() }
            return true
        }
        func append(_ start: Int, _ kind: TextSyntaxToken.Kind) -> Bool {
            guard tokens.count < maximumTokens else { return false }
            tokens.append(.init(range: .init(location: start, length: index - start), kind: kind))
            return true
        }
        // A JSONC key can be separated from its colon by comments. Look ahead
        // without consuming the comments' own tokens; each skipped unit is
        // visited at most once here and once by the main pass.
        func followedByColon(_ start: Int) -> Bool? {
            var cursor = start, checked = 0
            func step(_ count: Int = 1) -> Bool {
                cursor += count; checked += count
                if checked >= 256 { checked = 0; return !cancelled() }
                return true
            }
            while cursor < units.count {
                if white(units[cursor]) {
                    if !step() { return nil }
                } else if at(cursor, 47) && (at(cursor + 1, 47) || at(cursor + 1, 42)) {
                    let block = at(cursor + 1, 42)
                    if !step(2) { return nil }
                    while cursor < units.count {
                        if block && at(cursor, 42) && at(cursor + 1, 47) {
                            if !step(2) { return nil }; break
                        }
                        if !block && (at(cursor, 10) || at(cursor, 13)) { break }
                        if !step() { return nil }
                    }
                } else { return at(cursor, 58) }
            }
            return false
        }
        while index < units.count {
            let start = index, unit = units[index]
            if white(unit) {
                if !advance() { return .plain(.cancelled) }
            } else if [44, 58, 91, 93, 123, 125].contains(unit) {
                if !advance() { return .plain(.cancelled) }
                if !append(start, .punctuation) { return .plain(.tokenBudget) }
            } else if unit == 47 && (at(index + 1, 47) || at(index + 1, 42)) {
                let block = at(index + 1, 42)
                if !advance(2) { return .plain(.cancelled) }
                while index < units.count {
                    if block && at(index, 42) && at(index + 1, 47) {
                        if !advance(2) { return .plain(.cancelled) }; break
                    }
                    if !block && (units[index] == 10 || units[index] == 13) { break }
                    if !advance() { return .plain(.cancelled) }
                }
                if !append(start, .comment) { return .plain(.tokenBudget) }
            } else if unit == 34 {
                if !advance() { return .plain(.cancelled) }
                var closed = false
                while index < units.count {
                    if units[index] == 10 || units[index] == 13 { break }
                    if units[index] == 92 {
                        // Escaped quotes/backslashes stay inside their string.
                        if !advance(min(2, units.count - index)) { return .plain(.cancelled) }
                    } else if units[index] == 34 {
                        if !advance() { return .plain(.cancelled) }; closed = true; break
                    } else if !advance() { return .plain(.cancelled) }
                }
                guard let property = closed ? followedByColon(index) : false else { return .plain(.cancelled) }
                if !append(start, property ? .property : .string) { return .plain(.tokenBudget) }
            } else {
                // Consume an entire bare lexeme before deciding its role, so
                // 01, 1e+, trueish or a partial edit cannot look like a valid
                // number/literal prefix followed by unrelated colored text.
                if !advance() { return .plain(.cancelled) }
                while index < units.count && !boundary(units[index]) {
                    if !advance() { return .plain(.cancelled) }
                }
                let word = units[start..<index]
                if word.elementsEqual([116, 114, 117, 101])
                    || word.elementsEqual([102, 97, 108, 115, 101])
                    || word.elementsEqual([110, 117, 108, 108]) {
                    if !append(start, .literal) { return .plain(.tokenBudget) }
                } else if digit(unit) || unit == 45 {
                    // Strict lexical JSON number grammar; no regex or parser
                    // recursion. Cancellation remains bounded even for one
                    // pathological 1MiB numeric lexeme.
                    var cursor = start, valid = true, checked = 0
                    func step() -> Bool {
                        cursor += 1; checked += 1
                        if checked >= 256 { checked = 0; return !cancelled() }
                        return true
                    }
                    if at(cursor, 45), !step() { return .plain(.cancelled) }
                    if at(cursor, 48) {
                        if !step() { return .plain(.cancelled) }
                    } else if cursor < index && (49...57).contains(units[cursor]) {
                        repeat { if !step() { return .plain(.cancelled) } }
                        while cursor < index && digit(units[cursor])
                    } else { valid = false }
                    if valid && cursor < index && at(cursor, 46) {
                        if !step() { return .plain(.cancelled) }
                        let first = cursor
                        while cursor < index && digit(units[cursor]) { if !step() { return .plain(.cancelled) } }
                        valid = cursor > first
                    }
                    if valid && cursor < index && (at(cursor, 69) || at(cursor, 101)) {
                        if !step() { return .plain(.cancelled) }
                        if at(cursor, 43) || at(cursor, 45) { if !step() { return .plain(.cancelled) } }
                        let first = cursor
                        while cursor < index && digit(units[cursor]) { if !step() { return .plain(.cancelled) } }
                        valid = cursor > first
                    }
                    if valid && cursor == index && !append(start, .number) { return .plain(.tokenBudget) }
                }
            }
        }
        return cancelled() ? .plain(.cancelled) : .tokens(tokens)
    }

}
