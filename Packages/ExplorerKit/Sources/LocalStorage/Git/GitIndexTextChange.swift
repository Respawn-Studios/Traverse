import CryptoKit
import ExplorerCore
import FileOperations
import Foundation

/// A reviewed pair of line spans, bound to both displayed text versions.
public struct GitIndexTextChange: Equatable, Sendable {
    private let span: TextAlignment.Span
    private let beforeDigest: SHA256.Digest
    private let afterDigest: SHA256.Digest

    public static func supports(_ document: TextDocumentValue) -> Bool {
        document.format.lineEnding == .lf && !document.format.bom && document.lines <= TextAlignment.maximumLineCount
    }

    public init(before: TextDocumentValue, after: TextDocumentValue, beforeLines: Range<Int>, afterLines: Range<Int>) throws {
        guard Self.supports(before), Self.supports(after) else { throw GitIndexEditFailure.unsupportedTextChange }
        span = .init(left: beforeLines, right: afterLines)
        beforeDigest = SHA256.hash(data: before.encoded)
        afterDigest = SHA256.hash(data: after.encoded)
    }

    func applying(to before: Data, comparedWith after: Data, reversed: Bool = false, check: () throws -> Void) throws -> Data {
        try check()
        guard SHA256.hash(data: before) == beforeDigest, SHA256.hash(data: after) == afterDigest else {
            throw GitInspectionFailure.changed
        }
        var identifiers: [Data: Int] = [:]
        func lines(_ data: Data) throws -> (starts: [Data.Index], tokens: [Int]) {
            var starts = [data.startIndex], tokens: [Int] = []
            for offset in data.indices where data[offset] == 10 { starts.append(offset + 1) }
            for i in starts.indices {
                if i.isMultiple(of: 64) { try check() }
                let end = i + 1 < starts.count ? starts[i + 1] : data.endIndex
                let line = data[starts[i]..<end]
                let nextIdentifier = identifiers.count
                let token = identifiers[line, default: nextIdentifier]
                identifiers[line] = token
                tokens.append(token)
            }
            starts.append(data.endIndex)
            return (starts, tokens)
        }
        let left = try lines(before), right = try lines(after)
        let alignment = try TextAlignment.lines(left.tokens, right.tokens, cancelled: { Task.isCancelled })
        guard !alignment.grouped, alignment.spans.contains(span) else { throw GitIndexEditFailure.unsupportedTextChange }
        let beforeRange = left.starts[span.left.lowerBound]..<left.starts[span.left.upperBound]
        let afterRange = right.starts[span.right.lowerBound]..<right.starts[span.right.upperBound]
        var result = reversed ? after : before
        if reversed { result.replaceSubrange(afterRange, with: before[beforeRange]) }
        else { result.replaceSubrange(beforeRange, with: after[afterRange]) }
        _ = try TextDocumentValue.original(result)
        try check()
        return result
    }
}
