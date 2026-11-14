import Foundation

/// Lexical presentation for build files. Does not expand Make variables, parse
/// embedded shells, load includes or execute instructions. Reuses the common
/// UTF-16 cursor, cancellation and token bounds of every native editor.
enum EditorBuildSyntax {
    private struct HereDocument {
        let delimiter: [UInt16]
        let stripsTabs: Bool
    }
    private static let instructions: Set<String> = [
        "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK",
        "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"
    ]
    private static let directives: Set<String> = [
        "define", "endef", "undefine", "ifdef", "ifndef", "ifeq", "ifneq", "else", "endif",
        "include", "-include", "sinclude", "override", "export", "unexport", "private", "vpath"
    ]
    static func color(_ units: [UInt16], language: TextSyntaxLanguage,
                      cancelled: @Sendable () -> Bool) -> TextSyntaxResult {
        withoutActuallyEscaping(cancelled) { cancellation in
            var c = EditorLexicalCursor(units, cancelled: cancellation)
            do { return try scan(&c, docker: language == .dockerfile) }
            catch let stop as EditorLexicalStop { return stop.result }
            catch { return .plain(.cancelled) }
        }
    }
    private static func wordEnd(_ c: inout EditorLexicalCursor, from start: Int, end: Int) throws -> Int {
        var next = start
        while next < end && (EditorLexicalCursor.name(c.units[next]) || EditorLexicalCursor.digit(c.units[next]) || c.at(next, 46)) {
            next += 1; try c.poll()
        }
        return next
    }
    private static func scan(_ c: inout EditorLexicalCursor, docker: Bool) throws -> TextSyntaxResult {
        var continuation = false, escape: UInt16 = 92, parserDirectives = true
        var hereDocuments: [HereDocument] = [], recipePrefix: UInt16 = 9
        while c.index < c.units.count {
            let line = c.index
            var end = line
            while end < c.units.count && !c.at(end, 10) && !c.at(end, 13) { end += 1; try c.poll() }
            let first = min(try c.horizontalEnd(line), end)
            if let here = hereDocuments.first {
                var content = line
                if here.stripsTabs { while content < end && c.at(content, 9) { content += 1; try c.poll() } }
                let terminator = c.units[content..<end].elementsEqual(here.delimiter)
                try c.advance(end - c.index)
                try c.emit(line, terminator ? .punctuation : .string)
                if terminator { hereDocuments.removeFirst() }
            } else if first < end && c.at(first, 35) {
                // Docker comments are whole-line only, even in a continued
                // instruction. A # in a RUN argument is not a Docker comment.
                if docker && parserDirectives {
                    let directive = String(decoding: c.units[(first + 1)..<end], as: UTF16.self)
                        .trimmingCharacters(in: .whitespaces)
                    let pair = directive.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if pair.count == 2 && pair[0].lowercased() == "escape", pair[1] == "`" || pair[1] == "\\" {
                        escape = pair[1] == "`" ? 96 : 92
                    } else if pair.count != 2 || !["syntax", "check"].contains(pair[0].lowercased()) { parserDirectives = false }
                }
                try c.advance(end - c.index); try c.emit(first, .comment)
            } else if first < end {
                parserDirectives = false
                let recipe = !docker && c.at(line, recipePrefix)
                let firstEnd = try wordEnd(&c, from: first, end: end)
                let word = String(decoding: c.units[first..<firstEnd], as: UTF16.self)
                try c.advance(first - c.index)
                if docker && !continuation && instructions.contains(word.uppercased()) || !docker && !recipe && directives.contains(word) {
                    try c.advance(firstEnd - c.index); try c.emit(first, .keyword)
                } else if !docker && !recipe && !continuation {
                    // Simple literal assignments and rule targets; computed
                    // names/expansion stay with the ordinary variable lexer.
                    let after = min(try c.horizontalEnd(firstEnd), end)
                    let assignment = c.at(after, 61) || [58, 63, 43, 33].contains(after < end ? c.units[after] : 0) && c.at(after + 1, 61)
                    if firstEnd > first && (assignment || c.at(after, 58)) {
                        try c.advance(firstEnd - c.index); try c.emit(first, assignment ? .property : .function)
                    }
                    if word == ".RECIPEPREFIX", assignment {
                        var value = after
                        while value < end && [58, 61, 63, 43, 33, 32, 9].contains(c.units[value]) { value += 1; try c.poll() }
                        recipePrefix = value < end ? c.units[value] : 9
                    }
                }
                while c.index < end {
                    let start = c.index, unit = c.units[start]
                    if !docker && unit == 35 {
                        try c.advance(end - start); try c.emit(start, .comment)
                    } else if unit == 92 && !docker {
                        try c.advance(min(2, end - start)) // escaped # is ordinary content
                    } else if unit == 34 || unit == 39 {
                        try c.advance()
                        while c.index < end {
                            if c.at(c.index, 92) { try c.advance(min(2, end - c.index)) }
                            else if c.at(c.index, unit) { try c.advance(); break }
                            else { try c.advance() }
                        }
                        try c.emit(start, .string)
                    } else if unit == 36 {
                        try c.advance()
                        if c.at(c.index, 40) || c.at(c.index, 123) {
                            let opening = c.units[c.index], closing: UInt16 = opening == 40 ? 41 : 125
                            var depth = 0
                            repeat {
                                if c.at(c.index, opening) { depth += 1 }
                                if c.at(c.index, closing) { depth -= 1 }
                                try c.advance()
                            } while c.index < end && depth > 0
                        } else if !docker && c.index < end {
                            try c.advance() // Make's $@, $<, $$ and single-letter variables
                        } else {
                            let finish = try wordEnd(&c, from: c.index, end: end)
                            try c.advance(finish - c.index)
                        }
                        try c.emit(start, .property)
                    } else if docker && unit == 60 && c.at(start + 1, 60) {
                        var next = start + 2
                        let strip = c.at(next, 45)
                        if strip { next += 1 }
                        let quote: UInt16? = c.at(next, 34) ? 34 : c.at(next, 39) ? 39 : nil
                        if quote != nil { next += 1 }
                        let name = next
                        while next < end && next - name <= 128 && (EditorLexicalCursor.name(c.units[next]) || EditorLexicalCursor.digit(c.units[next])) {
                            next += 1; try c.poll()
                        }
                        if next > name && next - name <= 128 && (quote == nil || c.at(next, quote!)) && hereDocuments.count < 8 {
                            hereDocuments.append(.init(delimiter: Array(c.units[name..<next]), stripsTabs: strip))
                            if quote != nil { next += 1 }
                            try c.advance(next - start); try c.emit(start, .punctuation)
                        } else { try c.advance() }
                    } else if docker && unit == 45 && c.at(start + 1, 45) {
                        try c.advance(2)
                        while c.index < end && !EditorLexicalCursor.horizontal(c.units[c.index]) && !c.at(c.index, 61) { try c.advance() }
                        try c.emit(start, .property)
                    } else if EditorLexicalCursor.name(unit) || EditorLexicalCursor.digit(unit) {
                        let finish = try wordEnd(&c, from: start, end: end)
                        try c.advance(max(1, finish - start))
                        let after = min(try c.horizontalEnd(c.index), end)
                        if c.at(after, 61) { try c.emit(start, .property) }
                        else if try c.decimal(start, c.index) { try c.emit(start, .number) }
                    } else if [58, 61, 91, 93, 44, 59].contains(unit) {
                        try c.advance(); try c.emit(start, .punctuation)
                    } else { try c.advance() }
                }
                var tail = end
                while tail > first && EditorLexicalCursor.horizontal(c.units[tail - 1]) { tail -= 1; try c.poll() }
                var escapes = 0
                while tail > first && c.units[tail - 1] == escape { escapes += 1; tail -= 1; try c.poll() }
                continuation = escapes % 2 == 1
            } else { parserDirectives = false }
            if c.at(c.index, 13) { try c.advance() }
            if c.at(c.index, 10) { try c.advance() }
        }
        return c.finish()
    }
}
