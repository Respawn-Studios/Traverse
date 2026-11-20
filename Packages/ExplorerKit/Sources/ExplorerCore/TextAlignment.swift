/// Bounded comparison of interned line or grapheme identities. Matching the
/// identities and mapping the resulting spans to text remain the caller's job.
public enum TextAlignment {
    public static let maximumLineCount = 16_384

    public struct Span: Equatable, Sendable {
        public let left: Range<Int>
        public let right: Range<Int>

        public init(left: Range<Int>, right: Range<Int>) {
            self.left = left
            self.right = right
        }
    }

    public static func lines(_ left: [Int], _ right: [Int], cancelled: @Sendable () -> Bool) throws
        -> (spans: [Span], grouped: Bool) {
        try check(cancelled)
        guard left.count <= maximumLineCount, right.count <= maximumLineCount else {
            return ([.init(left: left.indices, right: right.indices)], true)
        }
        var budget = 1 << 20
        return try align(left, right, budget: &budget, maximumChanges: 256, allowsSparseLines: true, cancelled: cancelled)
    }

    public static func inline(_ left: [Int], _ right: [Int], remainingCells: inout Int, cancelled: @Sendable () -> Bool) throws
        -> (spans: [Span], grouped: Bool) {
        try check(cancelled)
        let limit = max(0, min(16_384, remainingCells))
        var budget = limit
        let result = try align(left, right, budget: &budget, maximumChanges: 64, cancelled: cancelled)
        remainingCells -= limit - budget
        return result
    }

    /// Use the same bounded alignment for document lines and for exact text
    /// units within confidently paired replacement lines.
    private static func align(_ left: [Int], _ right: [Int], budget: inout Int, maximumChanges: Int,
                              allowsSparseLines: Bool = false,
                              cancelled: @Sendable () -> Bool) throws -> (spans: [Span], grouped: Bool) {
        var prefix = 0, leftEnd = left.count, rightEnd = right.count
        while prefix < leftEnd, prefix < rightEnd, left[prefix] == right[prefix] { prefix += 1 }
        while leftEnd > prefix, rightEnd > prefix, left[leftEnd - 1] == right[rightEnd - 1] {
            leftEnd -= 1; rightEnd -= 1
        }
        let rows = leftEnd - prefix, columns = rightEnd - prefix
        guard rows != 0 || columns != 0 else { return ([], false) }
        let broad = Span(left: prefix..<leftEnd, right: prefix..<rightEnd)
        if rows == 0 || columns == 0 { return ([broad], false) }
        if rows > budget / columns {
            if allowsSparseLines, let changes = try sparseChanges(left, right, within: broad, cancelled: cancelled) {
                return (changes, false)
            }
            return ([broad], true)
        }
        budget -= rows * columns
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
        var i = 0, j = 0, changes: [Span] = []
        while i < rows || j < columns {
            try check(cancelled)
            if i < rows, j < columns, directions[i * columns + j] == 2 { i += 1; j += 1; continue }
            let startI = i, startJ = j
            repeat {
                if j == columns || i < rows && directions[i * columns + j] == 0 { i += 1 }
                else { j += 1 }
            } while (i < rows || j < columns) && !(i < rows && j < columns && directions[i * columns + j] == 2)
            changes.append(.init(left: (prefix + startI)..<(prefix + i), right: (prefix + startJ)..<(prefix + j)))
            if changes.count > maximumChanges { return ([broad], true) }
        }
        return (changes, false)
    }

    private struct SparseReach {
        var before: Int
        var after: Int
        let removed: Bool
    }

    /// Myers' furthest-reaching paths for a trimmed, nonempty line range. The
    /// frontier grows with inserted and removed lines, so two distant small
    /// edits can stay exact even when a full comparison grid would be too large.
    private static func sparseChanges(_ left: [Int], _ right: [Int], within span: Span,
                                      cancelled: @Sendable () -> Bool) throws -> [Span]? {
        let rows = span.left.count, columns = span.right.count
        let maximumEdits = 128
        guard abs(rows - columns) <= maximumEdits else { return nil }
        var remaining = 1 << 20
        var trace: [[SparseReach?]] = [[.init(before: 0, after: 0, removed: false)]]
        for edits in 1...min(maximumEdits, rows + columns) {
            try check(cancelled)
            let previous = trace[edits - 1]
            var frontier = [SparseReach?](repeating: nil, count: edits + 1)
            // Slot s represents the diagonal 2s - edits. A removal reaches
            // this slot from s-1 and an insertion reaches it from s.
            for slot in frontier.indices {
                guard remaining > 0 else { return nil }
                remaining -= 1
                var candidate: SparseReach?
                if slot > 0, let last = previous[slot - 1], last.before < rows {
                    candidate = .init(before: last.before + 1, after: last.after, removed: true)
                }
                if slot < previous.count, let last = previous[slot], (last.after < columns),
                   last.before > (candidate?.before ?? -1) {
                    candidate = .init(before: last.before, after: last.after + 1, removed: false)
                }
                guard var reach = candidate else { continue }
                while reach.before < rows, reach.after < columns {
                    guard remaining > 0 else { return nil }
                    remaining -= 1
                    if remaining.isMultiple(of: 256) { try check(cancelled) }
                    guard left[span.left.lowerBound + reach.before] == right[span.right.lowerBound + reach.after] else { break }
                    reach.before += 1; reach.after += 1
                }
                frontier[slot] = reach
                if reach.before == rows && reach.after == columns {
                    try check(cancelled)
                    trace.append(frontier)
                    return sparseSpans(trace, endingAt: slot, within: span)
                }
            }
            trace.append(frontier)
        }
        return nil
    }

    private static func sparseSpans(_ trace: [[SparseReach?]], endingAt end: Int, within span: Span) -> [Span]? {
        var slot = end, reversed: [Span] = []
        for edits in (1..<trace.count).reversed() {
            guard let reach = trace[edits][slot] else { return nil }
            if reach.removed { slot -= 1 }
            guard let previous = trace[edits - 1][slot] else { return nil }
            let left = span.left.lowerBound + previous.before
            let right = span.right.lowerBound + previous.after
            let leftEnd = left + (reach.removed ? 1 : 0)
            let rightEnd = right + (reach.removed ? 0 : 1)
            if let next = reversed.last, leftEnd == next.left.lowerBound, rightEnd == next.right.lowerBound {
                reversed[reversed.count - 1] = .init(left: left..<next.left.upperBound, right: right..<next.right.upperBound)
            } else {
                reversed.append(.init(left: left..<leftEnd, right: right..<rightEnd))
            }
        }
        return reversed.reversed()
    }

    private static func check(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
}
