import Foundation
import FileOperations

/// Immutable already-open buffers. A comparison does not reread a file, query a
/// server, infer the current disk contents or authorize any editing operation.
struct EditorComparisonCapture: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let baseline: String
    let current: String
    let format: TextDocumentFormat
    let language: TextSyntaxLanguage
    var description: String { "<captured editor comparison>" }
    var debugDescription: String { description }
}

struct EditorComparisonChange: Equatable, Sendable {
    /// Zero-based line spans, including an empty span for an insertion/deletion.
    let beforeLines: Range<Int>
    let currentLines: Range<Int>
    let beforeRange: NSRange
    let currentRange: NSRange
}

struct EditorComparisonPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let before: TextDocumentValue
    let current: TextDocumentValue
    let beforeIndex: EditorLineIndex
    let currentIndex: EditorLineIndex
    let beforeSyntax: TextSyntaxResult
    let currentSyntax: TextSyntaxResult
    let changes: [EditorComparisonChange]
    /// A truthful broad changed region when a fine-grained diff would cost too
    /// much. Equal prefix/suffix lines still remain outside that region.
    let grouped: Bool
    var description: String { "<editor comparison plan>" }
    var debugDescription: String { description }
}

enum EditorTextComparison {
    /// At most 1 MiB of direction cells, two short LCS rows and interned line
    /// bytes. Comparison is off-main and cancellable; it never shells out to diff.
    static func prepare(_ capture: EditorComparisonCapture,
                        cancelled: @Sendable () -> Bool) throws -> EditorComparisonPlan {
        try check(cancelled)
        let before = try TextDocumentValue.edited(capture.baseline, format: capture.format)
        let current = try TextDocumentValue.edited(capture.current, format: capture.format)
        let beforeIndex = EditorLineIndex(before.text), currentIndex = EditorLineIndex(current.text)
        let beforeSyntax = TextSyntax.color(before, language: capture.language, cancelled: cancelled)
        let currentSyntax = TextSyntax.color(current, language: capture.language, cancelled: cancelled)
        try check(cancelled)

        func range(_ lines: Range<Int>, _ index: EditorLineIndex) -> NSRange {
            let lower = lines.lowerBound < index.starts.count ? index.starts[lines.lowerBound] : index.length
            let upper = lines.upperBound < index.starts.count ? index.starts[lines.upperBound] : index.length
            return .init(location: lower, length: upper - lower)
        }
        func change(_ beforeLines: Range<Int>, _ currentLines: Range<Int>) -> EditorComparisonChange {
            .init(beforeLines: beforeLines, currentLines: currentLines,
                beforeRange: range(beforeLines, beforeIndex), currentRange: range(currentLines, currentIndex))
        }
        func result(_ changes: [EditorComparisonChange], grouped: Bool = false) -> EditorComparisonPlan {
            .init(before: before, current: current, beforeIndex: beforeIndex, currentIndex: currentIndex,
                beforeSyntax: beforeSyntax, currentSyntax: currentSyntax, changes: changes, grouped: grouped)
        }
        if before.text.utf8.elementsEqual(current.text.utf8) { return result([]) }

        // Pathological tiny-line documents stay reviewable without allocating
        // a dictionary/one object for every newline. This is a coarse comparison,
        // explicitly labelled in the UI, rather than a guessed detailed diff.
        guard beforeIndex.starts.count <= 16_384, currentIndex.starts.count <= 16_384 else {
            return result([change(0..<beforeIndex.starts.count, 0..<currentIndex.starts.count)], grouped: true)
        }
        var identifiers: [Data: Int] = [:]
        func tokens(_ value: TextDocumentValue, _ index: EditorLineIndex) throws -> [Int] {
            let source = value.text as NSString
            var values: [Int] = []; values.reserveCapacity(index.starts.count)
            for line in index.starts.indices {
                if line.isMultiple(of: 64) { try check(cancelled) }
                // Data equality preserves NFC/NFD spelling and final-newline
                // changes; Swift String equality intentionally normalizes them.
                let key = Data(source.substring(with: range(line..<(line + 1), index)).utf8)
                let id: Int
                if let existing = identifiers[key] { id = existing }
                else { id = identifiers.count; identifiers[key] = id }
                values.append(id)
            }
            return values
        }
        let left = try tokens(before, beforeIndex), right = try tokens(current, currentIndex)
        var prefix = 0, leftEnd = left.count, rightEnd = right.count
        while prefix < leftEnd, prefix < rightEnd, left[prefix] == right[prefix] { prefix += 1 }
        while leftEnd > prefix, rightEnd > prefix, left[leftEnd - 1] == right[rightEnd - 1] {
            leftEnd -= 1; rightEnd -= 1
        }
        let rows = leftEnd - prefix, columns = rightEnd - prefix
        if rows == 0 || columns == 0 { return result([change(prefix..<leftEnd, prefix..<rightEnd)]) }
        guard rows <= 1_048_576 / columns else {
            return result([change(prefix..<leftEnd, prefix..<rightEnd)], grouped: true)
        }
        var directions = [UInt8](repeating: 0, count: rows * columns)
        var next = [Int](repeating: 0, count: columns + 1)
        var row = next
        for i in (0..<rows).reversed() {
            try check(cancelled)
            row[columns] = 0
            for j in (0..<columns).reversed() {
                if left[prefix + i] == right[prefix + j] {
                    row[j] = next[j + 1] + 1; directions[i * columns + j] = 2
                } else if next[j] >= row[j + 1] {
                    row[j] = next[j]; directions[i * columns + j] = 0
                } else {
                    row[j] = row[j + 1]; directions[i * columns + j] = 1
                }
            }
            swap(&row, &next)
        }
        var i = 0, j = 0, changes: [EditorComparisonChange] = []
        while i < rows || j < columns {
            try check(cancelled)
            if i < rows, j < columns, directions[i * columns + j] == 2 { i += 1; j += 1; continue }
            let startI = i, startJ = j
            repeat {
                if j == columns || i < rows && directions[i * columns + j] == 0 { i += 1 }
                else { j += 1 }
            } while (i < rows || j < columns) && !(i < rows && j < columns && directions[i * columns + j] == 2)
            changes.append(change((prefix + startI)..<(prefix + i), (prefix + startJ)..<(prefix + j)))
            if changes.count > 256 { return result([change(prefix..<leftEnd, prefix..<rightEnd)], grouped: true) }
        }
        return result(changes)
    }

    private static func check(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
}
