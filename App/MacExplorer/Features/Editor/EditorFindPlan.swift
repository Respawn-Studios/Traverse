import Foundation
#if canImport(FileOperations)
import FileOperations
#endif

enum EditorFindMatchMode: String, Equatable, Sendable, CaseIterable {
    case contains, startsWord, wholeWord, endsWord
    var title: String {
        switch self { case .contains: "Contains"; case .startsWord: "Starts a Word"; case .wholeWord: "Whole Words"; case .endsWord: "Ends a Word" }
    }
}

struct EditorFindOptions: Equatable, Sendable {
    var matchesCase = false
    var matchMode = EditorFindMatchMode.contains
    var wraps = true
}

enum EditorFindFailure: Error, Equatable, Sendable {
    case queryTooLong, documentTooLarge, tooManyMatches, invalidRanges, cancelled
}

/// An immutable, in-memory observation of the already-open editor buffer.
/// Never Codable, indexed, logged or used as authority to read a file.
struct EditorFindMatches: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let text: String
    let query: String
    let options: EditorFindOptions
    let ranges: [NSRange]
    let isComplete: Bool
    let highlightRanges: [NSRange]
    let utf16Length: Int
    var description: String { "<editor find observation>" }
    var debugDescription: String { description }

    init(text: String, query: String, options: EditorFindOptions, ranges: [NSRange], isComplete: Bool) {
        self.text = text; self.query = query; self.options = options
        self.ranges = ranges; self.isComplete = isComplete
        // Prepare adjacent fills on the same background lane as matching.
        // A dense run must not create one drawing operation per character.
        let length = text.utf16.count
        utf16Length = length
        var merged: [NSRange] = [], end = 0, valid = ranges.count <= EditorFindPlan.maximumMatches
        if valid {
            for range in ranges {
                guard range.location >= end, range.length > 0,
                      range.location <= length, range.length <= length - range.location else { valid = false; break }
                if let last = merged.last, NSMaxRange(last) == range.location {
                    merged[merged.count - 1].length += range.length
                } else { merged.append(range) }
                end = NSMaxRange(range)
            }
        }
        highlightRanges = valid ? merged : []
    }

    func nextIndex(from selection: NSRange, backwards: Bool) -> Int? {
        guard !ranges.isEmpty, selection.location >= 0, selection.length >= 0,
              selection.location <= utf16Length,
              selection.length <= utf16Length - selection.location else { return nil }
        let target = backwards ? selection.location : NSMaxRange(selection)
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].location < target { lower = middle + 1 } else { upper = middle }
        }
        if backwards { return lower > 0 ? lower - 1 : (options.wraps ? ranges.count - 1 : nil) }
        return lower < ranges.count ? lower : (options.wraps ? 0 : nil)
    }
}

enum EditorFindSearchResult: Sendable {
    case matches(EditorFindMatches)
    case refused(EditorFindFailure)
}

struct EditorFindReplacement: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let original: String
    let value: TextDocumentValue
    let count: Int
    let selection: NSRange
    var description: String { "<editor find replacement>" }
    var debugDescription: String { description }
}

enum EditorFindReplacementResult: Sendable {
    case unchanged
    case replace(EditorFindReplacement)
    case refused(EditorFindFailure)
    case invalidText(TextDocumentFailure)
}

/// Foundation owns Unicode matching. The bounded loop and replacement planner
/// own completeness and allocation checks. Neither function changes a live view.
enum EditorFindPlan {
    static let maximumQueryBytes = 4096
    // Nonoverlapping, nonempty matches cannot outnumber the bounded input bytes.
    static let maximumMatches = TextDocumentValue.maximumBytes

    static func search(text: String, query: String, options: EditorFindOptions,
                       matchLimit: Int = maximumMatches,
                       cancelled: @Sendable () -> Bool = { false }) -> EditorFindSearchResult {
        guard text.utf8.count <= TextDocumentValue.maximumBytes else { return .refused(.documentTooLarge) }
        guard query.utf8.count <= maximumQueryBytes else { return .refused(.queryTooLong) }
        guard matchLimit > 0, matchLimit <= maximumMatches else { return .refused(.invalidRanges) }
        if cancelled() { return .refused(.cancelled) }
        let source = text as NSString
        guard !query.isEmpty else {
            return .matches(.init(text: text, query: query, options: options, ranges: [], isComplete: true))
        }
        let compare: String.CompareOptions = options.matchesCase ? [] : [.caseInsensitive]
        var cursor = 0
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(256, matchLimit))
        var iterations = 0
        while cursor < source.length {
            if iterations % 256 == 0 && cancelled() { return .refused(.cancelled) }
            iterations += 1
            let found = source.range(of: query, options: compare,
                                     range: .init(location: cursor, length: source.length - cursor))
            if found.location == NSNotFound { break }
            guard found.length > 0, found.location >= cursor,
                  found.location <= source.length,
                  found.length <= source.length - found.location,
                  scalarBoundary(found.location, in: source),
                  scalarBoundary(NSMaxRange(found), in: source) else { return .refused(.invalidRanges) }
            cursor = NSMaxRange(found)
            let needsStart = options.matchMode == .startsWord || options.matchMode == .wholeWord
            let needsEnd = options.matchMode == .endsWord || options.matchMode == .wholeWord
            if (needsStart && wordBefore(found.location, in: source)) || (needsEnd && wordAt(cursor, in: source)) {
                // A rejected candidate is not an accepted nonoverlapping match.
                // Advancing to its end would skip a later valid overlapping one.
                let first = source.character(at: found.location)
                cursor = found.location + ((0xD800...0xDBFF).contains(first) ? 2 : 1)
                continue
            }
            if ranges.count == matchLimit {
                return .matches(.init(text: text, query: query, options: options,
                                      ranges: ranges, isComplete: false))
            }
            ranges.append(found)
        }
        if cancelled() { return .refused(.cancelled) }
        return .matches(.init(text: text, query: query, options: options, ranges: ranges, isComplete: true))
    }

    static func replace(_ matches: EditorFindMatches, with supplied: String,
                        format: TextDocumentFormat, only index: Int? = nil,
                        cancelled: @Sendable () -> Bool = { false }) -> EditorFindReplacementResult {
        guard matches.isComplete else { return .refused(.tooManyMatches) }
        guard matches.text.utf8.count <= TextDocumentValue.maximumBytes,
              matches.ranges.count <= maximumMatches else { return .refused(.documentTooLarge) }
        if cancelled() { return .refused(.cancelled) }
        let source = matches.text as NSString
        let ranges: [NSRange]
        if let index {
            guard matches.ranges.indices.contains(index) else { return .refused(.invalidRanges) }
            ranges = [matches.ranges[index]]
        } else { ranges = matches.ranges }
        guard !ranges.isEmpty else { return .unchanged }
        guard supplied.utf8.count <= TextDocumentValue.maximumBytes else { return .refused(.documentTooLarge) }
        let replacement = supplied.replacingOccurrences(of: "\r\n", with: "\n")
        var end = 0, removedBytes = 0
        for (ordinal, range) in ranges.enumerated() {
            if ordinal % 256 == 0 && cancelled() { return .refused(.cancelled) }
            guard range.location >= end, range.length > 0,
                  range.location <= source.length, range.length <= source.length - range.location,
                  scalarBoundary(range.location, in: source), scalarBoundary(NSMaxRange(range), in: source) else {
                return .refused(.invalidRanges)
            }
            removedBytes += source.substring(with: range).utf8.count
            end = NSMaxRange(range)
        }
        let retainedBytes = matches.text.utf8.count - removedBytes
        let added = replacement.utf8.count.multipliedReportingOverflow(by: ranges.count)
        guard !added.overflow, retainedBytes >= 0,
              added.partialValue <= TextDocumentValue.maximumBytes,
              retainedBytes <= TextDocumentValue.maximumBytes - added.partialValue else {
            return .refused(.documentTooLarge)
        }
        // Append forward once. Repeated reverse mutations can repeatedly move a
        // large suffix when a document contains many tiny matches.
        var proposed = ""
        proposed.reserveCapacity(retainedBytes + added.partialValue)
        var start = 0
        for (ordinal, range) in ranges.enumerated() {
            if ordinal % 256 == 0 && cancelled() { return .refused(.cancelled) }
            proposed += source.substring(with: .init(location: start, length: range.location - start))
            proposed += replacement
            start = NSMaxRange(range)
        }
        proposed += source.substring(from: start)
        if cancelled() { return .refused(.cancelled) }
        guard !proposed.utf16.elementsEqual(matches.text.utf16) else { return .unchanged }
        do {
            let value = try TextDocumentValue.edited(proposed, format: format)
            return .replace(.init(original: matches.text, value: value, count: ranges.count,
                                  selection: .init(location: ranges[0].location,
                                                   length: replacement.utf16.count)))
        } catch let reason as TextDocumentFailure { return .invalidText(reason) }
        catch { return .refused(.invalidRanges) }
    }

    private static func scalarBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0 && offset < source.length else { return true }
        return !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
                 && (0xDC00...0xDFFF).contains(source.character(at: offset)))
    }
    private static func wordBefore(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0 else { return false }
        let last = source.character(at: offset - 1)
        if (0xDC00...0xDFFF).contains(last), offset >= 2 {
            let first = source.character(at: offset - 2)
            if (0xD800...0xDBFF).contains(first) {
                return isWord(0x10000 + (UInt32(first) - 0xD800) * 0x400 + UInt32(last) - 0xDC00)
            }
        }
        return isWord(UInt32(last))
    }
    private static func wordAt(_ offset: Int, in source: NSString) -> Bool {
        guard offset < source.length else { return false }
        let first = source.character(at: offset)
        if (0xD800...0xDBFF).contains(first), offset + 1 < source.length {
            let last = source.character(at: offset + 1)
            if (0xDC00...0xDFFF).contains(last) {
                return isWord(0x10000 + (UInt32(first) - 0xD800) * 0x400 + UInt32(last) - 0xDC00)
            }
        }
        return isWord(UInt32(first))
    }
    private static func isWord(_ value: UInt32) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return value == 95 || CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}
