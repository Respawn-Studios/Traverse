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
    func start(ofLine line: Int) -> Int? {
        guard line > 0, line <= starts.count else { return nil }
        return starts[line - 1]
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

enum EditorLineNumber {
    static func parse(_ input: String, maximum: Int) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 20,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let line = Int(value), line > 0, line <= maximum else { return nil }
        return line
    }

}
