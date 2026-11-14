import Foundation

enum EditorLineCommand: Equatable, Sendable {
    case duplicateSelectedLines, moveLinesUp, moveLinesDown
    case toggleLineComment(EditorLineCommentStyle)
    case formatJSON(EditorJSONFormat, allowsComments: Bool = false)
    case sortSelectedLines(descending: Bool)
    case trimTrailingWhitespace
    case surroundSelection(EditorSurroundingPair)
}

enum EditorLineCommentStyle: String, Sendable {
    case slash = "//", hash = "#", dash = "--"
}

/// Uses the existing Foundation-only range/text/selection proposal. The caller
/// retains the exact original snapshot, generation, native admission and Undo.
enum EditorLineCommandPlan: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Refusal: Equatable, Sendable { case invalidSelection, nonCanonicalText, tooLarge, cannotFormatJSON }
    case unchanged
    case select(NSRange)
    case refused(Refusal)
    case replace(EditorIndentationReplacement)
    var description: String { "<editor line command plan>" }
    var debugDescription: String { description }
}

/// Pure LF-buffer operations. No AppKit, FileOperations, file URL, I/O, attributes,
/// document format mutation or secondary Undo implementation.
enum EditorLineCommands {
    static func plan(_ command: EditorLineCommand, text: String, selection: NSRange,
                     maximumBytes: Int) -> EditorLineCommandPlan {
        let currentBytes = text.utf8.count
        guard maximumBytes >= 0, currentBytes <= maximumBytes else { return .refused(.tooLarge) }
        let input = text as NSString
        // Subtraction precedes addition, including for NSNotFound / Int.max.
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= input.length,
              selection.length <= input.length - selection.location else { return .refused(.invalidSelection) }
        let selectionEnd = selection.location + selection.length
        func scalarBoundary(_ offset: Int, in source: NSString) -> Bool {
            guard offset > 0, offset < source.length else { return true }
            return !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
                     && (0xDC00...0xDFFF).contains(source.character(at: offset)))
        }
        guard scalarBoundary(selection.location, in: input), scalarBoundary(selectionEnd, in: input) else {
            return .refused(.invalidSelection)
        }
        // Opened documents and native CRLF paste are already canonicalized by
        // the owner / insertText. Normalizing here would invalidate native offsets.
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0, 13, 0x85, 0x2028, 0x2029: return .refused(.nonCanonicalText)
            default: break
            }
        }

        let index = EditorLineIndex(text)
        // Ending at the following line's start excludes that line. A caret at
        // EOF after a final LF addresses the real trailing empty logical line.
        let lastOffset = selection.length == 0 ? selection.location : selectionEnd - 1
        guard let firstLocation = index.location(at: selection.location),
              let lastLocation = index.location(at: lastOffset) else { return .refused(.invalidSelection) }
        let first = firstLocation.line - 1, last = lastLocation.line - 1
        let blockStart = index.starts[first]
        func hasFollowingLine(_ line: Int) -> Bool { line + 1 < index.starts.count }
        func contentEnd(_ line: Int) -> Int {
            hasFollowingLine(line) ? index.starts[line + 1] - 1 : input.length
        }
        func fullEnd(_ line: Int) -> Int {
            hasFollowingLine(line) ? index.starts[line + 1] : input.length
        }
        let bodyRange = NSRange(location: blockStart, length: contentEnd(last) - blockStart)
        let blockEnd = fullEnd(last)
        let bodyUnits = bodyRange.length
        let relativeStart = selection.location - blockStart
        let relativeEnd = selectionEnd - blockStart
        func movedSelection(start: Int, trailingLF: Bool) -> NSRange {
            let capacity = bodyUnits + (trailingLF ? 1 : 0)
            let lower = min(relativeStart, capacity), upper = min(relativeEnd, capacity)
            return NSRange(location: start + lower, length: upper - lower)
        }
        func propose(range: NSRange, replacement: String, resultSelection: NSRange) -> EditorLineCommandPlan {
            let old = input.substring(with: range)
            // Canonically equivalent Unicode is insufficient: line movement
            // must retain the actual code units and may swap NFC/NFD spellings.
            let identical = replacement.utf16.elementsEqual(old.utf16)
            let added = replacement.utf8.count, removed = old.utf8.count
            guard added <= maximumBytes, currentBytes - removed <= maximumBytes - added else {
                return .refused(.tooLarge)
            }
            let resultLength = input.length - range.length + replacement.utf16.count
            guard resultSelection.location >= 0, resultSelection.length >= 0,
                  resultSelection.location <= resultLength,
                  resultSelection.length <= resultLength - resultSelection.location else {
                return .refused(.invalidSelection)
            }
            // The resulting selection lies inside this one replacement. Check
            // its endpoints in that local UTF-16 coordinate space as well.
            let local = resultSelection.location - range.location
            let chunk = replacement as NSString
            guard local >= 0, local <= chunk.length,
                  resultSelection.length <= chunk.length - local,
                  scalarBoundary(local, in: chunk),
                  scalarBoundary(local + resultSelection.length, in: chunk) else {
                return .refused(.invalidSelection)
            }
            if identical { return resultSelection == selection ? .unchanged : .select(resultSelection) }
            return .replace(.init(range: range, text: replacement, selection: resultSelection))
        }

        switch command {
        case .surroundSelection(let pair):
            guard selection.length > 0 else { return .unchanged }
            let selected = input.substring(with: selection)
            return propose(range: selection, replacement: pair.open + selected + pair.close,
                resultSelection: .init(location: selection.location + pair.open.utf16.count, length: selection.length))
        case .formatJSON(let style, let allowsComments):
            return EditorJSONFormatting.plan(style, text: text, selection: selection, maximumBytes: maximumBytes,
                                             allowsComments: allowsComments)
        case .sortSelectedLines(let descending):
            guard first < last else { return .unchanged }
            // Natural ordering keeps item2 before item10. Equal sort keys retain
            // their original order and exact spelling; nothing is deduplicated.
            let lines = (first...last).map { line in
                (line, input.substring(with: .init(location: index.starts[line],
                    length: contentEnd(line) - index.starts[line])))
            }
            let locale = Locale.current
            let ordered = lines.sorted { lhs, rhs in
                let order = lhs.1.compare(rhs.1, options: [.numeric, .caseInsensitive], locale: locale)
                if order == .orderedSame { return lhs.0 < rhs.0 }
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
            let replacement = ordered.map(\.1).joined(separator: "\n") + (hasFollowingLine(last) ? "\n" : "")
            return propose(range: .init(location: blockStart, length: blockEnd - blockStart),
                replacement: replacement, resultSelection: .init(location: blockStart, length: replacement.utf16.count))
        case .trimTrailingWhitespace:
            // This is an explicit document command, never a Save side effect.
            // Preserve newlines and nonbreaking/other Unicode whitespace.
            var removed: [NSRange] = []
            for line in index.starts.indices {
                let end = contentEnd(line)
                var start = end
                while start > index.starts[line], [9, 32].contains(input.character(at: start - 1)) { start -= 1 }
                if start < end { removed.append(.init(location: start, length: end - start)) }
            }
            guard !removed.isEmpty else { return .unchanged }
            var replacement = "", cursor = 0
            for range in removed {
                replacement += input.substring(with: .init(location: cursor, length: range.location - cursor))
                cursor = NSMaxRange(range)
            }
            replacement += input.substring(from: cursor)
            func mapped(_ offset: Int) -> Int {
                offset - removed.reduce(0) { total, range in
                    total + max(0, min(range.length, offset - range.location))
                }
            }
            let lower = mapped(selection.location), upper = mapped(selectionEnd)
            return propose(range: .init(location: 0, length: input.length), replacement: replacement,
                resultSelection: .init(location: lower, length: upper - lower))
        case .toggleLineComment(let style):
            let prefix = style.rawValue, prefixLength = prefix.utf16.count
            struct Line {
                let start: Int, end: Int, insertion: Int, isBlank: Bool, isCommented: Bool
            }
            let lines = (first...last).map { line -> Line in
                let start = index.starts[line], end = contentEnd(line)
                var insertion = start
                while insertion < end && [9, 32].contains(input.character(at: insertion)) { insertion += 1 }
                let commented = end - insertion >= prefixLength
                    && input.substring(with: .init(location: insertion, length: prefixLength)) == prefix
                return .init(start: start, end: fullEnd(line), insertion: insertion,
                    isBlank: insertion == end, isCommented: commented)
            }
            let meaningful = lines.filter { !$0.isBlank }
            if meaningful.isEmpty && selection.length > 0 { return .unchanged }
            let removes = !meaningful.isEmpty && meaningful.allSatisfy(\.isCommented)
            var replacement = "", newCaret = selection.location, growth = 0
            for line in lines {
                // Keep blank selected lines intact. A lone caret on a blank
                // line can still insert a comment ready for typing.
                guard !line.isBlank || selection.length == 0 else {
                    replacement += input.substring(with: .init(location: line.start, length: line.end - line.start))
                    continue
                }
                let removed: Int
                let inserted: String
                if removes {
                    removed = prefixLength + (line.insertion + prefixLength < line.end
                        && input.character(at: line.insertion + prefixLength) == 32 ? 1 : 0)
                    inserted = ""
                } else {
                    removed = 0; inserted = prefix + " "
                    guard inserted.utf8.count <= maximumBytes - currentBytes - growth else { return .refused(.tooLarge) }
                    growth += inserted.utf8.count
                }
                replacement += input.substring(with: .init(location: line.start, length: line.insertion - line.start))
                    + inserted + input.substring(with: .init(location: line.insertion + removed, length: line.end - line.insertion - removed))
                if selection.length == 0, selection.location >= line.insertion {
                    newCaret = max(line.insertion, selection.location - removed) + inserted.utf16.count
                }
            }
            let resultSelection = selection.length == 0 ? NSRange(location: newCaret, length: 0)
                : NSRange(location: blockStart, length: replacement.utf16.count)
            return propose(range: .init(location: blockStart, length: blockEnd - blockStart),
                replacement: replacement, resultSelection: resultSelection)

        case .duplicateSelectedLines:
            // Count growth before constructing the copy. Every duplicate adds
            // one LF plus the selected block's body, even at unterminated EOF.
            guard let swiftBody = Range(bodyRange, in: text) else { return .refused(.invalidSelection) }
            let bodyBytes = text[swiftBody].utf8.count
            let remaining = maximumBytes - currentBytes
            guard remaining >= 1, bodyBytes <= remaining - 1 else { return .refused(.tooLarge) }
            let body = input.substring(with: bodyRange)
            let terminated = hasFollowingLine(last)
            let inserted = terminated ? body + "\n" : "\n" + body
            let newStart = blockEnd + (terminated ? 0 : 1)
            return propose(range: .init(location: blockEnd, length: 0), replacement: inserted,
                resultSelection: movedSelection(start: newStart, trailingLF: terminated))

        case .moveLinesUp:
            guard first > 0 else { return .unchanged }
            let previous = first - 1, previousStart = index.starts[previous]
            let before = input.substring(with: .init(location: previousStart, length: contentEnd(previous) - previousStart))
            let body = input.substring(with: bodyRange)
            // Keep the region's final LF only if a further line follows it.
            // The swapped previous line supplies the selected block's new LF.
            let replacement = body + "\n" + before + (hasFollowingLine(last) ? "\n" : "")
            return propose(range: .init(location: previousStart, length: blockEnd - previousStart),
                replacement: replacement, resultSelection: movedSelection(start: previousStart, trailingLF: true))

        case .moveLinesDown:
            guard hasFollowingLine(last) else { return .unchanged }
            let following = last + 1, followingStart = index.starts[following]
            let after = input.substring(with: .init(location: followingStart, length: contentEnd(following) - followingStart))
            let body = input.substring(with: bodyRange)
            let terminated = hasFollowingLine(following)
            let replacement = after + "\n" + body + (terminated ? "\n" : "")
            let newStart = blockStart + after.utf16.count + 1
            return propose(range: .init(location: blockStart, length: fullEnd(following) - blockStart),
                replacement: replacement, resultSelection: movedSelection(start: newStart, trailingLF: terminated))
        }
    }
}
