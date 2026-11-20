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
    let selection: NSRange?
    let ranges: [NSRange]
    let isComplete: Bool
    let highlightRanges: [NSRange]
    let utf16Length: Int
    var description: String { "<editor find observation>" }
    var debugDescription: String { description }

    init(text: String, query: String, options: EditorFindOptions, ranges: [NSRange], isComplete: Bool, selection: NSRange? = nil) {
        self.text = text; self.query = query; self.options = options
        self.selection = selection
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
    let edit: EditorIndentationReplacement
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

    static func excerpt(for range: NSRange, in source: NSString, lines: EditorLineIndex)
        -> (line: Int, text: String, highlight: NSRange?)? {
        guard range.location >= 0, range.location <= source.length, range.length >= 0,
              range.length <= source.length - range.location,
              let location = lines.location(at: range.location), let start = lines.start(ofLine: location.line) else { return nil }
        let end = lines.start(ofLine: location.line + 1).map { max(start, $0 - 1) } ?? source.length
        var from = max(start, range.location - 60), to = min(end, range.location + min(range.length, 80) + 80)
        // A snippet keeps the source line short and complete at its Unicode edges.
        if from > 0, from < source.length, (0xDC00...0xDFFF).contains(source.character(at: from)) { from -= 1 }
        if to > 0, to < source.length, (0xDC00...0xDFFF).contains(source.character(at: to)) { to += 1 }
        let prefix = from > start ? "…" : ""
        let raw = source.substring(with: .init(location: from, length: max(0, to - from)))
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var highlight: NSRange?
        if !content.isEmpty {
            let visible = (raw as NSString).range(of: content, options: .literal)
            if visible.location != NSNotFound {
                let absolute = NSRange(location: from + visible.location, length: visible.length)
                let overlap = NSIntersectionRange(absolute, range)
                if overlap.length > 0 {
                    highlight = NSRange(location: prefix.utf16.count + overlap.location - absolute.location, length: overlap.length)
                }
            }
        }
        return (location.line, prefix + content + (to < end ? "…" : ""), highlight)
    }

    static func search(text: String, query: String, options: EditorFindOptions, within selection: NSRange? = nil,
                       matchLimit: Int = maximumMatches,
                       cancelled: @Sendable () -> Bool = { false }) -> EditorFindSearchResult {
        guard text.utf8.count <= TextDocumentValue.maximumBytes else { return .refused(.documentTooLarge) }
        guard query.utf8.count <= maximumQueryBytes else { return .refused(.queryTooLong) }
        guard matchLimit > 0, matchLimit <= maximumMatches else { return .refused(.invalidRanges) }
        if cancelled() { return .refused(.cancelled) }
        let source = text as NSString
        guard let scope = searchRange(selection, in: source) else { return .refused(.invalidRanges) }
        do {
            let outcome = try matchingRanges(in: source, query: query, options: options, scopes: [scope],
                limit: matchLimit, cancelled: cancelled)
            return .matches(.init(text: text, query: query, options: options, ranges: outcome.ranges,
                isComplete: outcome.complete, selection: selection))
        } catch { return .refused(error) }
    }

    /// Reuse Unicode, word-boundary and result-limit rules when a review
    /// admits several separate line ranges of a single captured text.
    static func matchingRanges(in source: NSString, query: String, options: EditorFindOptions, scopes: [NSRange],
                               limit: Int, cancelled: @Sendable () -> Bool) throws(EditorFindFailure)
        -> (ranges: [NSRange], complete: Bool) {
        guard !query.isEmpty else { return ([], true) }
        guard query.utf8.count <= maximumQueryBytes else { throw .queryTooLong }
        guard (1...maximumMatches).contains(limit) else { throw .invalidRanges }
        let compare: String.CompareOptions = options.matchesCase ? [] : [.caseInsensitive]
        let needsStart = options.matchMode == .startsWord || options.matchMode == .wholeWord
        let needsEnd = options.matchMode == .endsWord || options.matchMode == .wholeWord
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(256, limit))
        var iterations = 0, priorEnd = 0
        for scope in scopes {
            guard scope.location >= priorEnd, scope.location <= source.length,
                  scope.length >= 0, scope.length <= source.length - scope.location,
                  scalarBoundary(scope.location, in: source), scalarBoundary(NSMaxRange(scope), in: source) else {
                throw .invalidRanges
            }
            let upperBound = NSMaxRange(scope)
            priorEnd = upperBound
            var cursor = scope.location
            while cursor < upperBound {
                if iterations % 256 == 0 && cancelled() { throw .cancelled }
                iterations += 1
                let found = source.range(of: query, options: compare,
                    range: .init(location: cursor, length: upperBound - cursor))
                if found.location == NSNotFound { break }
                guard found.length > 0, found.location >= cursor, found.location <= upperBound,
                      found.length <= upperBound - found.location, scalarBoundary(found.location, in: source),
                      scalarBoundary(NSMaxRange(found), in: source) else { throw .invalidRanges }
                cursor = NSMaxRange(found)
                if (needsStart && wordBefore(found.location, in: source)) || (needsEnd && wordAt(cursor, in: source)) {
                    // Rejected candidates must not skip overlapping words.
                    let first = source.character(at: found.location)
                    cursor = found.location + ((0xD800...0xDBFF).contains(first) ? 2 : 1)
                    continue
                }
                if ranges.count == limit { return (ranges, false) }
                ranges.append(found)
            }
        }
        if cancelled() { throw .cancelled }
        return (ranges, true)
    }

    static func replace(_ matches: EditorFindMatches, with supplied: String,
                        format: TextDocumentFormat, only index: Int? = nil,
                        cancelled: @Sendable () -> Bool = { false }) -> EditorFindReplacementResult {
        guard matches.isComplete else { return .refused(.tooManyMatches) }
        guard matches.text.utf8.count <= TextDocumentValue.maximumBytes,
              matches.ranges.count <= maximumMatches else { return .refused(.documentTooLarge) }
        if cancelled() { return .refused(.cancelled) }
        let source = matches.text as NSString
        guard let scope = searchRange(matches.selection, in: source) else { return .refused(.invalidRanges) }
        let upperBound = NSMaxRange(scope)
        let ranges: [NSRange]
        if let index {
            guard matches.ranges.indices.contains(index) else { return .refused(.invalidRanges) }
            ranges = [matches.ranges[index]]
        } else { ranges = matches.ranges }
        guard !ranges.isEmpty else { return .unchanged }
        guard supplied.utf8.count <= TextDocumentValue.maximumBytes else { return .refused(.documentTooLarge) }
        let replacement = supplied.replacingOccurrences(of: "\r\n", with: "\n")
        var end = scope.location, removedBytes = 0
        for (ordinal, range) in ranges.enumerated() {
            if ordinal % 256 == 0 && cancelled() { return .refused(.cancelled) }
            guard range.location >= end, range.length > 0,
                  range.location <= upperBound, range.length <= upperBound - range.location,
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
            let first = ranges[0].location
            let span = NSRange(location: first, length: end - first)
            let selection = NSRange(location: first, length: replacement.utf16.count)
            let edit: EditorIndentationReplacement
            if Range(span, in: matches.text) != nil, value.text.utf16.elementsEqual(proposed.utf16) {
                let inserted = NSRange(location: first, length: value.utf16Count - first - (source.length - end))
                edit = .init(range: span, text: (value.text as NSString).substring(with: inserted), selection: selection)
            } else {
                // A scalar match can split a composed character. The native
                // edit admission can still use the validated whole value.
                edit = .init(range: .init(location: 0, length: source.length), text: value.text, selection: selection)
            }
            return .replace(.init(original: matches.text, value: value, count: ranges.count, edit: edit))
        } catch let reason as TextDocumentFailure { return .invalidText(reason) }
        catch { return .refused(.invalidRanges) }
    }

    private static func searchRange(_ selection: NSRange?, in source: NSString) -> NSRange? {
        guard let selection else { return .init(location: 0, length: source.length) }
        guard selection.location >= 0, selection.length > 0, selection.location <= source.length,
              selection.length <= source.length - selection.location, scalarBoundary(selection.location, in: source),
              scalarBoundary(NSMaxRange(selection), in: source) else { return nil }
        return selection
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
