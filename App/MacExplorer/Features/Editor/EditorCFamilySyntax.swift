import Foundation

/// Lexical presentation for C-family source, not compilation, preprocessing or
/// resource loading. The shared cursor owns UTF-16, token and cancellation bounds.
enum EditorCFamilySyntax {
    static func color(_ units: [UInt16], language: TextSyntaxLanguage,
                      cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var cursor = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&cursor, cpp: language == .cpp || language == .objectiveCPP) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }

    private static let keywords: Set<String> = [
        "alignas", "alignof", "asm", "auto", "break", "case", "catch", "class", "concept", "const",
        "consteval", "constexpr", "constinit", "const_cast", "continue", "co_await", "co_return", "co_yield",
        "decltype", "default", "delete", "do", "dynamic_cast", "else", "enum", "explicit", "export", "extern",
        "for", "friend", "goto", "if", "inline", "mutable", "namespace", "new", "noexcept", "operator",
        "private", "protected", "public", "register", "reinterpret_cast", "requires", "restrict", "return",
        "sizeof", "static", "static_assert", "static_cast", "struct", "switch", "template", "this", "thread_local",
        "throw", "try", "typedef", "typeid", "typename", "union", "using", "virtual", "volatile", "while",
        "_Alignas", "_Alignof", "_Atomic", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local"
    ]
    private static let objectKeywords: Set<String> = [
        "interface", "implementation", "end", "protocol", "property", "synthesize", "dynamic", "class",
        "public", "protected", "private", "package", "selector", "encode", "synchronized", "autoreleasepool",
        "try", "catch", "finally", "throw", "optional", "required", "available", "import", "compatibility_alias"
    ]
    private static let typeWords: Set<String> = [
        "void", "bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int", "long", "short",
        "signed", "unsigned", "wchar_t", "size_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t",
        "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "_Bool", "_Complex", "_Imaginary",
        "id", "Class", "SEL", "BOOL", "NSInteger", "NSUInteger", "CGFloat", "instancetype", "std", "string",
        "string_view", "vector", "array", "optional", "unique_ptr", "shared_ptr"
    ]
    private static let literalWords: Set<String> = ["true", "false", "nullptr", "NULL", "nil", "Nil", "YES", "NO"]
    private static func identifier(_ unit: UInt16) -> Bool {
        unit == 95 || (65...90).contains(unit) || (97...122).contains(unit) || unit >= 128
    }
    private static func newline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }

    /// The C++ raw delimiter is bounded to16 basic characters. A false prefix
    /// consumes nothing; incomplete valid raw strings remain one visible token.
    private static func string(_ c: inout EditorLexicalCursor, cpp: Bool) throws -> Bool {
        let start = c.index
        var quote = start
        if c.at(quote, 64) { quote += 1 } // Objective-C @"..."; useful in headers too
        else if c.at(quote, 76) || c.at(quote, 85) { quote += 1 }
        else if c.at(quote, 117) {
            quote += 1
            if c.at(quote, 56) { quote += 1 }
        }
        if cpp && c.at(quote, 82) && c.at(quote + 1, 34) {
            let delimiterStart = quote + 2
            var opening = delimiterStart
            while opening < c.units.count && opening - delimiterStart <= 16 && !c.at(opening, 40) {
                let unit = c.units[opening]
                guard (33...126).contains(unit), unit != 41, unit != 92 else { return false }
                opening += 1
            }
            guard opening - delimiterStart <= 16, c.at(opening, 40) else { return false }
            let delimiter = Array(c.units[delimiterStart..<opening])
            try c.advance(opening - start + 1)
            while c.index < c.units.count {
                if c.at(c.index, 41), c.at(c.index + delimiter.count + 1, 34),
                   delimiter.indices.allSatisfy({ c.at(c.index + 1 + $0, delimiter[$0]) }) {
                    try c.advance(delimiter.count + 2); break
                }
                try c.advance()
            }
            try c.emit(start, .string); return true
        }
        guard c.at(quote, 34) || c.at(quote, 39), !c.at(start, 64) || c.at(quote, 34) else { return false }
        let closing = c.units[quote]
        try c.advance(quote - start + 1)
        while c.index < c.units.count {
            if newline(c.units[c.index]) { break }
            if c.at(c.index, 92) {
                try c.advance()
                if c.index < c.units.count {
                    if c.at(c.index, 13) && c.at(c.index + 1, 10) { try c.advance(2) }
                    else { try c.advance() }
                }
            } else if c.at(c.index, closing) { try c.advance(); break }
            else { try c.advance() }
        }
        try c.emit(start, .string); return true
    }

    private static func scan(_ c: inout EditorLexicalCursor, cpp: Bool) throws -> TextSyntaxResult {
        if c.cancelled() { throw EditorLexicalStop.cancelled }
        var lineStart = true, headerExpected = false
        while c.index < c.units.count {
            let start = c.index, unit = c.units[start]
            // A physical line continuation keeps the current directive/code
            // context. It changes no document text or UTF-16 offsets.
            if unit == 92 && c.at(start + 1, 10) { try c.advance(2); continue }
            if unit == 92 && c.at(start + 1, 13) && c.at(start + 2, 10) { try c.advance(3); continue }
            if EditorLexicalCursor.white(unit) {
                if newline(unit) { lineStart = true; headerExpected = false }
                try c.advance(); continue
            }
            if lineStart && unit == 35 {
                try c.advance()
                while c.index < c.units.count && EditorLexicalCursor.horizontal(c.units[c.index]) { try c.advance() }
                let word = c.index
                while c.index < c.units.count && identifier(c.units[c.index]) { try c.advance() }
                let directive = c.index - word < 32 ? String(decoding: c.units[word..<c.index], as: UTF16.self) : ""
                headerExpected = ["include", "include_next", "import"].contains(directive)
                try c.emit(start, .keyword); lineStart = false; continue
            }
            if unit == 47 && c.at(start + 1, 47) {
                try c.advance(2)
                while c.index < c.units.count && !newline(c.units[c.index]) {
                    if c.at(c.index, 92) && c.at(c.index + 1, 10) { try c.advance(2) }
                    else if c.at(c.index, 92) && c.at(c.index + 1, 13) && c.at(c.index + 2, 10) { try c.advance(3) }
                    else { try c.advance() }
                }
                try c.emit(start, .comment); continue
            }
            if unit == 47 && c.at(start + 1, 42) {
                try c.advance(2)
                while c.index < c.units.count {
                    if c.at(c.index, 42) && c.at(c.index + 1, 47) { try c.advance(2); break }
                    if newline(c.units[c.index]) { lineStart = true; headerExpected = false }
                    try c.advance()
                }
                try c.emit(start, .comment); continue
            }
            if headerExpected && unit == 60 {
                try c.advance()
                while c.index < c.units.count && !newline(c.units[c.index]) && !c.at(c.index, 62) { try c.advance() }
                if c.at(c.index, 62) { try c.advance() }
                try c.emit(start, .string); headerExpected = false; lineStart = false; continue
            }
            if try string(&c, cpp: cpp) { headerExpected = false; lineStart = false; continue }
            headerExpected = false; lineStart = false
            if unit == 64 && start + 1 < c.units.count && identifier(c.units[start + 1]) {
                try c.advance(); let word = c.index
                while c.index < c.units.count && identifier(c.units[c.index]) { try c.advance() }
                if c.index - word < 64, objectKeywords.contains(String(decoding: c.units[word..<c.index], as: UTF16.self)) {
                    try c.emit(start, .keyword)
                }
                continue
            }
            if identifier(unit) {
                try c.advance()
                while c.index < c.units.count && (identifier(c.units[c.index]) || EditorLexicalCursor.digit(c.units[c.index])) { try c.advance() }
                let length = c.index - start
                if length <= 128 {
                    let word = String(decoding: c.units[start..<c.index], as: UTF16.self)
                    if literalWords.contains(word) { try c.emit(start, .literal) }
                    else if keywords.contains(word) { try c.emit(start, .keyword) }
                    else if typeWords.contains(word) || (65...90).contains(unit) { try c.emit(start, .type) }
                    else {
                        let after = try c.horizontalEnd(c.index)
                        if c.at(after, 40) { try c.emit(start, .function) }
                    }
                }
                continue
            }
            if EditorLexicalCursor.digit(unit) || unit == 46 && start + 1 < c.units.count && EditorLexicalCursor.digit(c.units[start + 1]) {
                try c.advance()
                while c.index < c.units.count {
                    let next = c.units[c.index], prior = c.units[c.index - 1]
                    if identifier(next) || EditorLexicalCursor.digit(next) || next == 46
                        || cpp && next == 39 && c.index + 1 < c.units.count && (identifier(c.units[c.index + 1]) || EditorLexicalCursor.digit(c.units[c.index + 1]))
                        || (next == 43 || next == 45) && [69, 101, 80, 112].contains(prior) { try c.advance() }
                    else { break }
                }
                try c.emit(start, .number); continue
            }
            try c.advance()
            if [35, 40, 41, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 63, 91, 93, 123, 124, 125, 126, 38, 33, 37, 94].contains(unit) {
                try c.emit(start, .punctuation)
            }
        }
        return c.finish()
    }
}
