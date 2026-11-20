import Foundation

/// In-memory presentation metadata, computed on the editor preparation lane.
/// Offsets use the same UTF-16 coordinate space as AppKit. No file authority.
struct EditorLineIndex: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let starts: [Int]
    let length: Int
    private let source: String
    var description: String { "<editor line index>" }
    var debugDescription: String { description }
    init(_ text: String) {
        var values = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { values.append(offset) }
        }
        starts = values; length = offset; source = text
    }
    func matches(_ text: String) -> Bool { source == text }

    /// Omit the empty caret position after a terminal newline.
    var contentLineCount: Int { starts.count - (starts.last == length ? 1 : 0) }

    func contentRange(at line: Int) -> NSRange? {
        guard (0..<contentLineCount).contains(line) else { return nil }
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return .init(location: start, length: end - start)
    }
    func start(ofLine line: Int) -> Int? {
        guard line > 0, line <= starts.count else { return nil }
        return starts[line - 1]
    }

    func offset(at address: EditorLineAddress) -> Int? {
        guard let start = start(ofLine: address.line), address.column > 0 else { return nil }
        let end = address.line < starts.count ? starts[address.line] - 1 : length
        guard address.column - 1 <= end - start else { return nil }
        let offset = start + address.column - 1
        // A UTF-16 column can land inside a composed character. Keep the
        // caret on a real display boundary, without extending the line.
        return offset < end ? (source as NSString).rangeOfComposedCharacterSequence(at: offset).location : offset
    }
    func location(at offset: Int) -> (line: Int, column: Int)? {
        guard offset >= 0, offset <= length else { return nil }
        var low = 0, high = starts.count
        while low < high {
            let mid = low + (high - low) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        let row = max(0, low - 1)
        return (row + 1, offset - starts[row] + 1)
    }
}

struct EditorLineBookmarks {
    static let maximumCount = 128
    private var offsets = Set<Int>()

    func contains(_ offset: Int) -> Bool { offsets.contains(offset) }

    func lines(in index: EditorLineIndex) -> [Int] {
        offsets.sorted().compactMap { index.location(at: $0)?.line }
    }

    @discardableResult mutating func toggle(_ offset: Int) -> Bool {
        if offsets.remove(offset) != nil { return true }
        guard offsets.count < Self.maximumCount else { return false }
        offsets.insert(offset)
        return true
    }

    mutating func followEdit(in editedRange: NSRange, delta: Int, length: Int) {
        guard !offsets.isEmpty else { return }
        let replaced = editedRange.length - delta
        let previousLength = length - delta
        let start = editedRange.location
        let end = start + replaced
        // The native callback describes the span after processing. Rebase
        // against the length of the replaced span in the previous text.
        guard replaced >= 0, end <= previousLength,
              !(start == 0 && replaced > 0 && end == previousLength) else {
            offsets.removeAll()
            return
        }
        offsets = Set(offsets.map { offset in
            if offset < start { return offset }
            let moved = offset >= end ? offset + delta : start
            return max(0, min(moved, length))
        })
    }

    mutating func align(to index: EditorLineIndex) {
        if !offsets.isEmpty { offsets = Set(lines(in: index).compactMap(index.start(ofLine:))) }
    }
}

struct EditorLineAddress: Equatable, Sendable {
    let line: Int
    let column: Int

    init(line: Int, column: Int = 1) {
        self.line = line
        self.column = column
    }

    static func parse(_ input: String, in index: EditorLineIndex) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.prefix(65).count <= 64 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let line = EditorLineNumber.parse(String(parts[0]), maximum: index.starts.count) else { return nil }
        let column = parts.count == 1 ? 1 : EditorLineNumber.parse(String(parts[1]), maximum: index.length + 1)
        guard let column else { return nil }
        let address = Self(line: line, column: column)
        return index.offset(at: address) == nil ? nil : address
    }
}

enum EditorLineNumber {
    static func parse(_ input: String, maximum: Int) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 20,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let line = Int(value), line > 0, line <= maximum else { return nil }
        return line
    }

}
