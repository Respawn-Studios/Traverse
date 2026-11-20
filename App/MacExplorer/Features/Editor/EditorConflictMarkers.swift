import Foundation

/// Complete conflict blocks in the already loaded LF buffer. The parser
/// accepts matching Git marker widths and an optional diff3 base. Malformed
/// and nested blocks never offer a replacement.
struct EditorConflictMarkers: Sendable {
    enum Resolution: Int, CaseIterable, Sendable {
        case current, incoming, both, base

        var title: String {
            switch self {
            case .current: "Keep Current Section"
            case .incoming: "Keep Incoming Section"
            case .both: "Keep Both Sections"
            case .base: "Keep Base Section"
            }
        }
    }

    struct Block: Equatable, Sendable {
        let range: NSRange
        let current: NSRange
        let base: NSRange?
        let incoming: NSRange

        func replacement(_ choice: Resolution, in input: NSString) -> String? {
            switch choice {
            case .current: input.substring(with: current)
            case .incoming: input.substring(with: incoming)
            case .both: input.substring(with: current) + input.substring(with: incoming)
            case .base: base.map { input.substring(with: $0) }
            }
        }
    }

    private(set) var blocks: [Block] = []

    func block(containing selection: NSRange) -> Block? {
        guard selection.length >= 0 else { return nil }
        return blocks.first {
            NSLocationInRange(selection.location, $0.range) && selection.length <= NSMaxRange($0.range) - selection.location
        }
    }

    func destination(from offset: Int, toward direction: EditorJumpDirection) -> Int? {
        let current = block(containing: .init(location: offset, length: 0))?.range.location ?? offset
        let target = switch direction {
        case .next: blocks.first { $0.range.location > current } ?? blocks.first
        case .previous: blocks.last { $0.range.location < current } ?? blocks.last
        }
        return target?.range.location == offset ? nil : target?.range.location
    }

    private enum Marker: UInt16 {
        case start = 60, end = 62, separator = 61, base = 124
    }

    private struct Candidate {
        let width: Int
        let opening: NSRange
        var base: NSRange?
        var separator: NSRange?
        var nested = 0
        var valid = true

        func finish(_ closing: NSRange) -> Block? {
            guard valid, let separator else { return nil }
            let currentEnd = base?.location ?? separator.location
            return .init(range: .init(location: opening.location, length: NSMaxRange(closing) - opening.location),
                current: .init(location: NSMaxRange(opening), length: currentEnd - NSMaxRange(opening)),
                base: base.map { .init(location: NSMaxRange($0), length: separator.location - NSMaxRange($0)) },
                incoming: .init(location: NSMaxRange(separator), length: closing.location - NSMaxRange(separator)))
        }
    }

    static func scan(_ text: String, index: EditorLineIndex, cancelled: @Sendable () -> Bool = { Task.isCancelled }) -> Self {
        guard text.contains("<<<<<<<"), index.matches(text) else { return .init() }
        let input = text as NSString
        var result = Self()
        var candidate: Candidate?
        for line in index.starts.indices {
            if line.isMultiple(of: 64), cancelled() { return .init() }
            let start = index.starts[line]
            let next = line + 1 < index.starts.count ? index.starts[line + 1] : input.length
            let end = line + 1 < index.starts.count ? next - 1 : next
            guard end - start >= 7, let marker = Marker(rawValue: input.character(at: start)) else { continue }
            var markerEnd = start + 1
            while markerEnd < end, input.character(at: markerEnd) == marker.rawValue { markerEnd += 1 }
            let width = markerEnd - start
            guard width >= 7, markerEnd == end || (marker != .separator && input.character(at: markerEnd) == 32) else { continue }
            let range = NSRange(location: start, length: next - start)

            if marker == .start {
                if candidate == nil { candidate = .init(width: width, opening: range) }
                else { candidate?.nested += 1; candidate?.valid = false }
                continue
            }
            guard var block = candidate else { continue }
            if block.nested > 0 {
                if marker == .end { block.nested -= 1 }
            } else if marker == .end {
                if width == block.width, let complete = block.finish(range) {
                    result.blocks.append(complete)
                    if result.blocks.count == 256 { break }
                }
                candidate = nil
                continue
            } else if width != block.width {
                block.valid = false
            } else if marker == .base, block.base == nil, block.separator == nil {
                block.base = range
            } else if marker == .separator, block.separator == nil {
                block.separator = range
            } else { block.valid = false }
            candidate = block
        }
        return result
    }
}
