import ExplorerCore
import FileOperations
import Foundation
import LocalStorage
import Search

/// Match only the admitted text, then retain result locations and excerpts.
/// Query and snippet values never enter saved state or diagnostics.
enum EditorProjectTextSearch {
    static let maximumMatches = 300
    enum Query: Sendable {
        case text(String, EditorFindOptions)
        case declarations(FilenameMatching.NavigationQuery)

        var progressLabel: String {
            switch self {
            case .text: "Searching text…"
            case .declarations: "Finding declarations…"
            }
        }
    }

    struct Match: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let entry: FileEntry
        let line: Int
        let preview: String
        let highlight: NSRange?
        let destination: EditorFileJump.Destination
        var description: String { "<project text match>" }
        var debugDescription: String { description }
    }

    struct Report: Sendable {
        let matches: [Match]
        let searched: Int
        let skipped: Int
        let matchesLimited: Bool
    }

    static func languages(declarationsOnly: Bool) -> [TextSyntaxLanguage] {
        Set(fileTypes(declarationsOnly: declarationsOnly).map { EditorOpeningSupport.syntax(for: $0.fileExtension) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func fileTypes(declarationsOnly: Bool) -> [EditorOpeningSupport.FileType] {
        EditorOpeningSupport.fileTypes.filter { type in
            !declarationsOnly || EditorDocumentOutline.declarationLanguages.contains(EditorOpeningSupport.syntax(for: type.fileExtension))
        }
    }

    static func metadataRequest(for query: Query, language: TextSyntaxLanguage? = nil) throws -> SearchRequest {
        let declarationsOnly: Bool
        if case .declarations = query { declarationsOnly = true } else { declarationsOnly = false }
        let types = fileTypes(declarationsOnly: declarationsOnly).filter {
            language == nil || EditorOpeningSupport.syntax(for: $0.fileExtension) == language
        }
        let filenames = try SearchRequest.FilenameAllowlist(names: types.flatMap(\.filenames), extensions: types.map(\.fileExtension))
        return try SearchRequest(filename: "", kind: .file, byteRange: 1...Int64(TextDocumentValue.maximumBytes),
            filenameAllowlist: filenames)
    }

    static func find(_ batch: LocalProjectTextBatch, query: Query, remainingMatches: Int) throws -> Report {
        var matches: [Match] = []
        var searched = 0, skipped = batch.skipped
        var matchesLimited = false
        for file in batch.files {
            try Task.checkCancellation()
            let remaining = remainingMatches - matches.count
            guard remaining > 0 else { matchesLimited = true; break }
            let limit = min(remaining, 30)
            if case .declarations(let name) = query {
                let found = try declarations(in: file, matching: name, limit: limit)
                if found.complete { searched += 1 } else { skipped += 1 }
                matchesLimited = matchesLimited || found.limitedResults
                matches += found.matches
                continue
            }
            guard case .text(let textQuery, let options) = query else { continue }
            let text = file.contents.text
            let outcome = EditorFindPlan.search(text: text, query: textQuery, options: options,
                matchLimit: limit, cancelled: { Task.isCancelled })
            guard case .matches(let result) = outcome else {
                try Task.checkCancellation()
                skipped += 1
                continue
            }
            searched += 1
            if !result.isComplete { matchesLimited = true }
            let lines = EditorLineIndex(text), source = text as NSString
            for range in result.ranges {
                try Task.checkCancellation()
                guard let hit = EditorFindPlan.excerpt(for: range, in: source, lines: lines), range.length <= 8_192 else {
                    matchesLimited = true
                    continue
                }
                matches.append(.init(entry: file.entry, line: hit.line, preview: hit.text, highlight: hit.highlight,
                    destination: .match(.init(range: range, expected: source.substring(with: range)))))
            }
        }
        return .init(matches: matches, searched: searched, skipped: skipped, matchesLimited: matchesLimited)
    }

    private static func declarations(in file: LocalProjectTextBatch.File, matching query: FilenameMatching.NavigationQuery,
                                     limit: Int) throws -> (matches: [Match], complete: Bool, limitedResults: Bool) {
        let language = EditorOpeningSupport.syntax(for: EditorOpeningSupport.key(forFilename: file.entry.name))
        let text = file.contents.text
        let syntax = TextSyntax.color(file.contents, language: language, cancelled: { Task.isCancelled })
        try Task.checkCancellation()
        let delimiters = EditorCFamilyOutline.languages.contains(language)
            ? EditorDelimiterWalk.capture(in: text, syntax: syntax, cancelled: { Task.isCancelled }) : nil
        let outline = EditorDocumentOutline.prepare(text: text, syntax: syntax, language: language,
            lines: EditorLineIndex(text), preparedDelimiters: delimiters, cancelled: { Task.isCancelled })
        try Task.checkCancellation()
        guard outline.availability == .ready else { return ([], false, false) }
        let entries = outline.entries.filter { $0.kind.isDeclaration && query.rank(in: $0.title) != nil }
        return (entries.prefix(limit).map { entry in
            .init(entry: file.entry, line: entry.line, preview: entry.title, highlight: nil, destination: .declaration(entry, language))
        }, true, entries.count > limit)
    }
}
