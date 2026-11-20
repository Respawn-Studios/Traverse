import CryptoKit
import ExplorerCore
import Foundation
import FileOperations

/// Two immutable text observations. Loading the source and granting access are
/// separate from preparing the read-only presentation.
struct EditorComparisonCapture: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Side: Sendable {
        let text: String
        let format: TextDocumentFormat
        let language: TextSyntaxLanguage
        let editor: EditorBufferIdentity?

        init(text: String, format: TextDocumentFormat, language: TextSyntaxLanguage, editor: EditorBufferIdentity? = nil) {
            self.text = text
            self.format = format
            self.language = language
            self.editor = editor
        }
    }
    let left: Side
    let right: Side

    init(left: Side, right: Side) {
        self.left = left
        self.right = right
    }

    init(baseline: String, current: String, format: TextDocumentFormat, language: TextSyntaxLanguage,
         currentEditor: EditorBufferIdentity? = nil) {
        left = .init(text: baseline, format: format, language: language)
        right = .init(text: current, format: format, language: language, editor: currentEditor)
    }

    init(documents: TextComparisonDocuments, leftLanguage: TextSyntaxLanguage, rightLanguage: TextSyntaxLanguage) {
        left = .init(text: documents.left.text, format: documents.left.format, language: leftLanguage)
        right = .init(text: documents.right.text, format: documents.right.format, language: rightLanguage)
    }
    var description: String { "<captured editor comparison>" }
    var debugDescription: String { description }
}

struct EditorComparisonChange: Equatable, Sendable {
    /// Zero-based line spans, including an empty span for an insertion/deletion.
    let beforeLines: Range<Int>
    let currentLines: Range<Int>
    let beforeRange: NSRange
    let currentRange: NSRange

    var beforeLineLabel: String { Self.lineLabel(beforeLines) }
    var currentLineLabel: String { Self.lineLabel(currentLines) }

    private static func lineLabel(_ value: Range<Int>) -> String {
        if value.isEmpty { return "near line \(value.lowerBound + 1)" }
        return value.count == 1 ? "line \(value.lowerBound + 1)" : "lines \(value.lowerBound + 1)–\(value.upperBound)"
    }
}

struct EditorComparisonApplication: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let editor: EditorBufferIdentity
    let expectedTarget: String
    let targetRange: NSRange
    let source: String
    let sourceRange: NSRange

    var description: String { "<selected comparison change>" }
    var debugDescription: String { description }
}

struct EditorSavedTextBaseline: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let text: String
    var description: String { "<editor saved baseline>" }
    var debugDescription: String { description }
}

struct EditorUnsavedLineChanges: Sendable {
    enum Kind: Sendable { case added, changed, removed }
    struct Mark: Equatable, Sendable {
        let kind: Kind
        let lines: Range<Int>
        let change: EditorComparisonChange
    }
    let baselineID: UUID
    let marks: [Mark]

    func kind(at line: Int) -> Kind? { mark(at: line)?.kind }

    func mark(at line: Int) -> Mark? {
        // At most 256 hunk starts. Query visible logical lines without
        // allocating a marker for every line in a changed range.
        var low = 0, high = marks.count
        while low < high {
            let middle = low + (high - low) / 2
            if marks[middle].lines.lowerBound <= line { low = middle + 1 }
            else { high = middle }
        }
        guard low > 0, marks[low - 1].lines.contains(line) else { return nil }
        return marks[low - 1]
    }

    func line(from current: Int, toward direction: EditorJumpDirection) -> Int? {
        let target: Int?
        switch direction {
        case .next: target = marks.first { $0.lines.lowerBound > current }?.lines.lowerBound ?? marks.first?.lines.lowerBound
        case .previous: target = marks.last { $0.lines.lowerBound < current }?.lines.lowerBound ?? marks.last?.lines.lowerBound
        }
        return target != current ? target : nil
    }
}

enum EditorComparisonWhitespace: Int, CaseIterable, Sendable {
    case exact, trailing, spacing

    var title: String {
        switch self {
        case .exact: "Show All Whitespace"
        case .trailing: "Ignore Trailing Spaces and Tabs"
        case .spacing: "Ignore Indentation and Repeated Spacing"
        }
    }

    var summary: String {
        switch self {
        case .exact: ""
        case .trailing: "Trailing spaces hidden"
        case .spacing: "Indent and spacing changes hidden"
        }
    }
}

struct EditorComparisonPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Side: Sendable { case before, current }
    typealias SourceEditors = (before: EditorBufferIdentity?, current: EditorBufferIdentity?)
    struct Snapshot: Sendable, Equatable {
        private let before: Data
        private let current: Data

        init(_ before: TextDocumentValue, _ current: TextDocumentValue) {
            self.before = Data(SHA256.hash(data: before.encoded))
            self.current = Data(SHA256.hash(data: current.encoded))
        }
    }

    let before: TextDocumentValue
    let current: TextDocumentValue
    let snapshot: Snapshot
    let beforeIndex: EditorLineIndex
    let currentIndex: EditorLineIndex
    let beforeSyntax: TextSyntaxResult
    let currentSyntax: TextSyntaxResult
    let sourceEditors: SourceEditors
    let changes: [EditorComparisonChange]
    let beforeDetails: [NSRange]
    let currentDetails: [NSRange]
    let whitespace: EditorComparisonWhitespace
    let exactTextMatches: Bool
    /// A truthful broad changed region when a fine-grained diff would cost too
    /// much. Equal prefix/suffix lines still remain outside that region.
    let grouped: Bool

    func application(of index: Int, to side: Side) -> EditorComparisonApplication? {
        guard !grouped, whitespace == .exact, changes.indices.contains(index) else { return nil }
        let change = changes[index]
        let target = side == .before ? (sourceEditors.before, before.text, change.beforeRange)
            : (sourceEditors.current, current.text, change.currentRange)
        guard let identity = target.0 else { return nil }
        let donor = side == .before ? (current.text, change.currentRange) : (before.text, change.beforeRange)
        guard target.2.length > 0 || donor.1.length > 0 else { return nil }
        return .init(editor: identity, expectedTarget: target.1, targetRange: target.2, source: donor.0, sourceRange: donor.1)
    }

    /// Finds a matching unchanged logical line without walking preceding hunks
    /// on each scroll event. Lines with no counterpart stay next to the gap.
    func correspondingLine(_ line: Int, from side: Side) -> Int? {
        guard !grouped else { return nil }
        let source = side == .before ? beforeIndex : currentIndex
        let target = side == .before ? currentIndex : beforeIndex
        guard source.starts.indices.contains(line) else { return nil }
        func ranges(_ change: EditorComparisonChange) -> (from: Range<Int>, to: Range<Int>) {
            side == .before ? (change.beforeLines, change.currentLines) : (change.currentLines, change.beforeLines)
        }
        var lower = 0, upper = changes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges(changes[middle]).from.lowerBound <= line { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return min(line, target.starts.count - 1) }
        let (from, to) = ranges(changes[lower - 1])
        let matchesChange = from.contains(line)
        let mapped = matchesChange ? to.lowerBound + min(line - from.lowerBound, max(0, to.count - 1))
            : to.upperBound + line - from.upperBound
        return min(mapped, target.starts.count - 1)
    }

    var changedLineCounts: (added: Int, removed: Int)? {
        guard !grouped else { return nil }
        func count(_ range: Range<Int>, in index: EditorLineIndex) -> Int {
            let lines = index.contentLineCount
            return min(range.upperBound, lines) - min(range.lowerBound, lines)
        }
        return changes.reduce(into: (added: 0, removed: 0)) {
            $0.added += count($1.currentLines, in: currentIndex)
            $0.removed += count($1.beforeLines, in: beforeIndex)
        }
    }
    var description: String { "<editor comparison plan>" }
    var debugDescription: String { description }
}

enum EditorTextComparison {
    /// At most 1 MiB of direction cells, two short LCS rows and interned line
    /// bytes. Comparison is off-main and cancellable; it never shells out to diff.
    static func prepare(_ capture: EditorComparisonCapture,
                        whitespace: EditorComparisonWhitespace = .exact,
                        cancelled: @Sendable () -> Bool) throws -> EditorComparisonPlan {
        try check(cancelled)
        let before = try TextDocumentValue.edited(capture.left.text, format: capture.left.format)
        let current = try TextDocumentValue.edited(capture.right.text, format: capture.right.format)
        let beforeIndex = EditorLineIndex(before.text), currentIndex = EditorLineIndex(current.text)
        let beforeSyntax = TextSyntax.color(before, language: capture.left.language, cancelled: cancelled)
        let currentSyntax = TextSyntax.color(current, language: capture.right.language, cancelled: cancelled)
        return try compare(before: before, current: current, snapshot: .init(before, current),
            beforeIndex: beforeIndex, currentIndex: currentIndex,
            beforeSyntax: beforeSyntax, currentSyntax: currentSyntax, sourceEditors: (capture.left.editor, capture.right.editor),
            whitespace: whitespace, cancelled: cancelled)
    }

    static func realign(_ plan: EditorComparisonPlan, whitespace: EditorComparisonWhitespace,
                        cancelled: @Sendable () -> Bool) throws -> EditorComparisonPlan {
        try compare(before: plan.before, current: plan.current, snapshot: plan.snapshot,
            beforeIndex: plan.beforeIndex, currentIndex: plan.currentIndex,
            beforeSyntax: plan.beforeSyntax, currentSyntax: plan.currentSyntax, sourceEditors: plan.sourceEditors,
            whitespace: whitespace, cancelled: cancelled)
    }

    static func unsavedLines(from baseline: EditorSavedTextBaseline, to current: String, index: EditorLineIndex,
                             cancelled: @Sendable () -> Bool) throws -> EditorUnsavedLineChanges {
        try check(cancelled)
        guard !baseline.text.utf8.elementsEqual(current.utf8) else { return .init(baselineID: baseline.id, marks: []) }
        let savedIndex = EditorLineIndex(baseline.text)
        let alignment = try alignLines(baseline.text, savedIndex, current, index, whitespace: .exact, cancelled: cancelled)
        // The detailed viewer can explain a grouped region. The ruler uses
        // exact logical lines, so it leaves a coarse result unmarked.
        let marks: [EditorUnsavedLineChanges.Mark] = alignment.grouped ? [] : alignment.spans.map { span in
            let change = EditorComparisonChange(beforeLines: span.left, currentLines: span.right,
                beforeRange: textRange(span.left, in: savedIndex), currentRange: textRange(span.right, in: index))
            if span.right.isEmpty {
                let gap = min(index.starts.count - 1, span.right.lowerBound)
                return .init(kind: .removed, lines: gap..<(gap + 1), change: change)
            }
            return .init(kind: span.left.isEmpty ? .added : .changed, lines: span.right, change: change)
        }
        return .init(baselineID: baseline.id, marks: marks)
    }

    enum CommittedLine: Equatable, Sendable { case exact(Int), changed, ambiguous, limited }

    /// Unlike linked scrolling, line history may use only a proven unchanged
    /// line. Repeated text in a changed buffer can have several valid matches.
    static func committedLine(_ line: Int, in working: String, comparedWith committed: String,
                              cancelled: @Sendable () -> Bool) throws -> CommittedLine {
        try check(cancelled)
        let current = EditorLineIndex(working), base = EditorLineIndex(committed)
        guard let start = current.start(ofLine: line), start < current.length else { return .changed }
        if committed.utf16.elementsEqual(working.utf16) { return .exact(line) }
        let alignment = try alignLines(committed, base, working, current, whitespace: .exact, cancelled: cancelled)
        guard !alignment.grouped else { return .limited }
        let row = line - 1
        let previous = alignment.spans.last { $0.right.lowerBound <= row }
        guard previous?.right.contains(row) != true else { return .changed }
        let mapped = previous.map { $0.left.upperBound + row - $0.right.upperBound } ?? row
        guard base.starts.indices.contains(mapped), base.starts[mapped] < base.length else { return .changed }
        let left = committed as NSString, right = working as NSString
        let lineRange = textRange(mapped..<(mapped + 1), in: base)
        let expected = left.substring(with: lineRange)
        guard right.substring(with: textRange(row..<(row + 1), in: current)).utf16.elementsEqual(expected.utf16) else {
            return .changed
        }
        func isUnique(_ source: NSString, index: EditorLineIndex) throws -> Bool {
            var found = false
            for offset in index.starts.indices where index.starts[offset] < index.length {
                if offset.isMultiple(of: 128) { try check(cancelled) }
                let range = textRange(offset..<(offset + 1), in: index)
                if range.length == lineRange.length && source.substring(with: range).utf16.elementsEqual(expected.utf16) {
                    if found { return false }
                    found = true
                }
            }
            return found
        }
        return try isUnique(left, index: base) && isUnique(right, index: current) ? .exact(mapped + 1) : .ambiguous
    }

    private static func compare(before: TextDocumentValue, current: TextDocumentValue, snapshot: EditorComparisonPlan.Snapshot,
                                beforeIndex: EditorLineIndex, currentIndex: EditorLineIndex,
                                beforeSyntax: TextSyntaxResult, currentSyntax: TextSyntaxResult,
                                sourceEditors: EditorComparisonPlan.SourceEditors,
                                whitespace: EditorComparisonWhitespace, cancelled: @Sendable () -> Bool) throws -> EditorComparisonPlan {
        try check(cancelled)
        let exactTextMatches = before.text.utf8.elementsEqual(current.text.utf8)

        func change(_ beforeLines: Range<Int>, _ currentLines: Range<Int>) -> EditorComparisonChange {
            .init(beforeLines: beforeLines, currentLines: currentLines,
                beforeRange: textRange(beforeLines, in: beforeIndex), currentRange: textRange(currentLines, in: currentIndex))
        }
        func result(_ changes: [EditorComparisonChange], grouped: Bool = false,
                    details: (before: [NSRange], current: [NSRange]) = ([], [])) -> EditorComparisonPlan {
            .init(before: before, current: current, snapshot: snapshot, beforeIndex: beforeIndex, currentIndex: currentIndex,
                beforeSyntax: beforeSyntax, currentSyntax: currentSyntax, sourceEditors: sourceEditors, changes: changes,
                beforeDetails: details.before, currentDetails: details.current, whitespace: whitespace,
                exactTextMatches: exactTextMatches, grouped: grouped)
        }
        if exactTextMatches { return result([]) }
        let alignment = try alignLines(before.text, beforeIndex, current.text, currentIndex,
            whitespace: whitespace, cancelled: cancelled)
        let changes = alignment.spans.map { change($0.left, $0.right) }
        if alignment.grouped { return result(changes, grouped: true) }
        let details = try inlineDetails(alignment.spans, left: before.text as NSString, right: current.text as NSString,
            leftIndex: beforeIndex, rightIndex: currentIndex, whitespace: whitespace, cancelled: cancelled)
        return result(changes, details: details)
    }

    /// Text search needs the same line alignment without syntax tokens or
    /// word-level accents for all the files in a multi-file review.
    static func searchableRanges(in before: String, index beforeIndex: EditorLineIndex,
                                 and current: String, index currentIndex: EditorLineIndex,
                                 whitespace: EditorComparisonWhitespace, cancelled: @Sendable () -> Bool) throws
        -> (before: [NSRange], current: [NSRange])? {
        if before.utf8.elementsEqual(current.utf8) { return ([], []) }
        let alignment = try alignLines(before, beforeIndex, current, currentIndex,
            whitespace: whitespace, cancelled: cancelled)
        guard !alignment.grouped else { return nil }
        return (alignment.spans.map { textRange($0.left, in: beforeIndex) }.filter { $0.length > 0 },
                alignment.spans.map { textRange($0.right, in: currentIndex) }.filter { $0.length > 0 })
    }

    private static func textRange(_ lines: Range<Int>, in index: EditorLineIndex) -> NSRange {
        let lower = lines.lowerBound < index.starts.count ? index.starts[lines.lowerBound] : index.length
        let upper = lines.upperBound < index.starts.count ? index.starts[lines.upperBound] : index.length
        return .init(location: lower, length: upper - lower)
    }

    private static func alignLines(_ before: String, _ beforeIndex: EditorLineIndex,
                                   _ current: String, _ currentIndex: EditorLineIndex,
                                   whitespace: EditorComparisonWhitespace, cancelled: @Sendable () -> Bool) throws
        -> (spans: [AlignedSpan], grouped: Bool) {
        // Pathological tiny-line documents stay reviewable without allocating
        // a dictionary/one object for every newline. This is a coarse comparison,
        // explicitly labelled in the UI, rather than a guessed detailed diff.
        guard beforeIndex.starts.count <= TextAlignment.maximumLineCount,
              currentIndex.starts.count <= TextAlignment.maximumLineCount else {
            return ([.init(left: 0..<beforeIndex.starts.count, right: 0..<currentIndex.starts.count)], true)
        }
        var identifiers: [Data: Int] = [:]
        func tokens(_ text: String, _ index: EditorLineIndex) throws -> [Int] {
            let source = text as NSString
            var values: [Int] = []; values.reserveCapacity(index.starts.count)
            for line in index.starts.indices {
                if line.isMultiple(of: 64) { try check(cancelled) }
                // Data equality preserves NFC/NFD spelling and final-newline
                // changes; Swift String equality intentionally normalizes them.
                let key = lineKey(source.substring(with: textRange(line..<(line + 1), in: index)), whitespace: whitespace)
                let id: Int
                if let existing = identifiers[key] { id = existing }
                else { id = identifiers.count; identifiers[key] = id }
                values.append(id)
            }
            return values
        }
        let left = try tokens(before, beforeIndex), right = try tokens(current, currentIndex)
        return try TextAlignment.lines(left, right, cancelled: cancelled)
    }

    private static func lineKey(_ line: String, whitespace: EditorComparisonWhitespace) -> Data {
        guard whitespace != .exact else { return Data(line.utf8) }
        let endsInNewline = line.last == "\n"
        let body = endsInNewline ? line.dropLast() : line[...]
        var key = Data(capacity: line.utf8.count)
        visitGraphemes(body, whitespace: whitespace) { character, _ in key.append(contentsOf: String(character).utf8) }
        if endsInNewline { key.append(10) }
        return key
    }

    /// Map comparison characters back to whole, unmodified source graphemes.
    private static func visitGraphemes(_ line: Substring, whitespace: EditorComparisonWhitespace,
                                      _ visit: (Character, NSRange) -> Void) {
        func isSpace(_ value: Character) -> Bool { value == " " || value == "\t" }
        let end: String.Index
        if whitespace == .exact { end = line.endIndex }
        else if let last = line.lastIndex(where: { !isSpace($0) }) { end = line.index(after: last) }
        else { end = line.startIndex }
        var index = line.startIndex
        if whitespace == .spacing { index = line[..<end].firstIndex(where: { !isSpace($0) }) ?? end }
        var offset = line[..<index].utf16.count
        while index < end {
            let character = line[index]
            var next = line.index(after: index)
            let collapse = whitespace == .spacing && isSpace(character)
            if collapse {
                while next < end, isSpace(line[next]) { line.formIndex(after: &next) }
            }
            let length = line[index..<next].utf16.count
            visit(collapse ? " " : character, .init(location: offset, length: length))
            offset += length
            index = next
        }
    }

    private typealias AlignedSpan = TextAlignment.Span

    private static func inlineDetails(_ spans: [AlignedSpan], left: NSString, right: NSString,
                                      leftIndex: EditorLineIndex, rightIndex: EditorLineIndex,
                                      whitespace: EditorComparisonWhitespace,
                                      cancelled: @Sendable () -> Bool) throws -> (before: [NSRange], current: [NSRange]) {
        var before: [NSRange] = [], current: [NSRange] = []
        var remainingUnits = 32_768, remainingCells = 262_144
        func body(_ line: Int, _ text: NSString, _ index: EditorLineIndex) -> NSRange {
            let start = index.starts[line]
            let end = line + 1 < index.starts.count ? index.starts[line + 1] - 1 : text.length
            return .init(location: start, length: end - start)
        }
        for span in spans where span.left.count == span.right.count {
            for (first, second) in zip(span.left, span.right) {
                try check(cancelled)
                let a = body(first, left, leftIndex), b = body(second, right, rightIndex)
                guard a.length <= 1_024, b.length <= 1_024, a.length + b.length > 0 else { continue }
                guard a.length + b.length <= remainingUnits, remainingCells > 0 else { return (before, current) }
                remainingUnits -= a.length + b.length
                var keys: [Data: Int] = [:]
                func graphemes(_ line: String, offset: Int) -> (units: [Int], offsets: [Int]) {
                    var units: [Int] = [], offsets: [Int] = []
                    visitGraphemes(line[...], whitespace: whitespace) { character, range in
                        let key = Data(String(character).utf8)
                        let id = keys[key] ?? keys.count
                        keys[key] = id
                        if offsets.isEmpty { offsets.append(offset + range.location) }
                        units.append(id)
                        offsets.append(offset + NSMaxRange(range))
                    }
                    return (units, offsets)
                }
                let lhs = graphemes(left.substring(with: a), offset: a.location)
                let rhs = graphemes(right.substring(with: b), offset: b.location)
                let detail = try TextAlignment.inline(lhs.units, rhs.units, remainingCells: &remainingCells, cancelled: cancelled)
                guard !detail.grouped else { continue }
                guard before.count + detail.spans.count <= 1_024, current.count + detail.spans.count <= 1_024 else {
                    return (before, current)
                }
                for part in detail.spans {
                    if !part.left.isEmpty {
                        let start = lhs.offsets[part.left.lowerBound]
                        before.append(.init(location: start, length: lhs.offsets[part.left.upperBound] - start))
                    }
                    if !part.right.isEmpty {
                        let start = rhs.offsets[part.right.lowerBound]
                        current.append(.init(location: start, length: rhs.offsets[part.right.upperBound] - start))
                    }
                }
            }
        }
        return (before, current)
    }

    private static func check(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
}
