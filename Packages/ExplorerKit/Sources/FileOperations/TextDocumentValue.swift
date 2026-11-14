import Foundation

// Shared bounded text value. No file URL, I/O, persistence or index authority.
public enum TextDocumentFailure: Error, Equatable, Sendable {
    case invalidUTF8, embeddedNUL, mixedLineEndings, unsupportedLineEnding
    case tooLarge, tooManyLines, lineTooLong, staleEdit, validationPending
    case saveInProgress, reviewRequired, invalidReceipt, needsDestination, closed
}

public struct TextDocumentFormat: Equatable, Sendable {
    public enum LineEnding: Equatable, Sendable { case lf, crlf }
    public let bom: Bool
    public let lineEnding: LineEnding
    public init(bom: Bool, lineEnding: LineEnding) { self.bom = bom; self.lineEnding = lineEnding }
}

public struct TextDocumentValue: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = 1_048_576
    public static let maximumLines = 20_000
    public static let maximumLineBytes = 65_536
    public let text: String                 // Canonical native editor text uses LF.
    public let encoded: Data               // Original encoding/newline profile.
    public let format: TextDocumentFormat
    public let lines: Int
    public let utf16Count: Int
    public var description: String { "<validated text document>" }
    public var debugDescription: String { description }

    private init(text: String, encoded: Data, format: TextDocumentFormat, lines: Int, utf16Count: Int) {
        self.text = text; self.encoded = encoded; self.format = format
        self.lines = lines; self.utf16Count = utf16Count
    }

    public static func original(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw TextDocumentFailure.tooLarge }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        let bytes = bom ? data.dropFirst(3) : data[...]
        guard String(data: bytes, encoding: .utf8) != nil else { throw TextDocumentFailure.invalidUTF8 }
        // Foundation's encoding initializer may consume a leading BOM. Decode
        // only after strict validation so a second literal U+FEFF is preserved.
        let source = String(decoding: bytes, as: UTF8.self)
        let canonical = try canonicalize(source, requireUniform: true)
        let value = try make(canonical.text, format: .init(bom: bom, lineEnding: canonical.crlf ? .crlf : .lf))
        guard value.encoded == data else { throw TextDocumentFailure.invalidUTF8 }
        return value
    }

    public static func edited(_ text: String, format: TextDocumentFormat) throws -> Self {
        let canonical = try canonicalize(text, requireUniform: false)
        return try make(canonical.text, format: format)
    }

    private static func canonicalize(_ text: String, requireUniform: Bool) throws -> (text: String, crlf: Bool) {
        // The native view may supply a CRLF paste into LF editor text. That
        // explicit edit conversion differs from admitting a mixed original.
        guard text.utf8.count <= maximumBytes else { throw TextDocumentFailure.tooLarge }
        let input = Array(text.utf8)
        var result: [UInt8] = []; result.reserveCapacity(input.count)
        var index = 0, lf = 0, crlf = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0 { throw TextDocumentFailure.embeddedNUL }
            if byte == 0xc2 && index + 1 < input.count && input[index + 1] == 0x85
                || byte == 0xe2 && index + 2 < input.count && input[index + 1] == 0x80
                    && (input[index + 2] == 0xa8 || input[index + 2] == 0xa9) {
                throw TextDocumentFailure.unsupportedLineEnding
            }
            if byte == 13 {
                guard index + 1 < input.count, input[index + 1] == 10 else { throw TextDocumentFailure.unsupportedLineEnding }
                crlf += 1; result.append(10); index += 2
            } else {
                if byte == 10 { lf += 1 }
                result.append(byte); index += 1
            }
        }
        guard !requireUniform || lf == 0 || crlf == 0 else { throw TextDocumentFailure.mixedLineEndings }
        return (String(decoding: result, as: UTF8.self), crlf > 0)
    }

    private static func make(_ text: String, format: TextDocumentFormat) throws -> Self {
        var encoded = Data()
        encoded.reserveCapacity(min(maximumBytes, text.utf8.count + (format.bom ? 3 : 0)))
        if format.bom { encoded.append(contentsOf: [0xef, 0xbb, 0xbf]) }
        var lines = 1, currentLine = 0
        for byte in text.utf8 {
            if byte == 10 {
                lines += 1; currentLine = 0
                guard lines <= maximumLines else { throw TextDocumentFailure.tooManyLines }
                if format.lineEnding == .crlf { encoded.append(13) }
            } else {
                currentLine += 1
                guard currentLine <= maximumLineBytes else { throw TextDocumentFailure.lineTooLong }
            }
            encoded.append(byte)
            guard encoded.count <= maximumBytes else { throw TextDocumentFailure.tooLarge }
        }
        return Self(text: text, encoded: encoded, format: format, lines: lines, utf16Count: text.utf16.count)
    }
}
