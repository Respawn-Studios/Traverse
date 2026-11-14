import Foundation

/// Complete checked member rendered as inert ASCII. It is not an extracted
/// file, prefix, access grant or executable representation. Diagnostics are
/// counts only; the display text is intentionally never in description/debug.
public struct ZIPBytePreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = ZIPTextPreview.maximumUTF8Bytes
    public let hexadecimalText: String
    public let byteCount: UInt64
    public let packedBytes: UInt64
    public var description: String { "Checked ZIP byte preview (\(byteCount) bytes)" }
    public var debugDescription: String { description }

    internal static func render(_ bytes: Data, check: () throws -> Void) throws -> String {
        guard UInt64(bytes.count) <= maximumBytes else { throw ZIPTextPreviewFailure.tooLarge }
        try check()
        let digits = Array("0123456789ABCDEF".utf8)
        let values = [UInt8](bytes)
        let rows = (values.count + 15) / 16
        var output = [UInt8](); output.reserveCapacity(rows * 78)
        for offset in stride(from: 0, to: values.count, by: 16) {
            try check()
            for shift in stride(from: 28, through: 0, by: -4) { output.append(digits[(offset >> shift) & 15]) }
            output.append(contentsOf: [32, 32])
            let count = min(16, values.count - offset)
            for column in 0..<16 {
                if column > 0 { output.append(32) }
                if column < count {
                    let value = values[offset + column]
                    output.append(digits[Int(value >> 4)]); output.append(digits[Int(value & 15)])
                } else { output.append(contentsOf: [32, 32]) }
            }
            output.append(contentsOf: [32, 32, 124])
            for column in 0..<16 {
                if column < count {
                    let value = values[offset + column]
                    output.append((32...126).contains(value) ? value : 46)
                } else { output.append(32) }
            }
            output.append(contentsOf: [124, 10])
        }
        try check()
        return String(decoding: output, as: UTF8.self)
    }
}

internal enum ZIPBytePreviewReader {
    static func read(_ selection: ZIPTextPreviewSelection, excluding roots: [URL], limits: ZIPReadLimits,
        previewLimits: ZIPTextPreviewLimits, check cancellation: @escaping () throws -> Void,
        probe: (@Sendable (ZIPArchiveReader.Stage) throws -> Void)?) throws -> ZIPBytePreview {
        try ZIPTextPreviewReader.readChecked(selection, excluding: roots, limits: limits, previewLimits: previewLimits,
            check: cancellation, probe: probe) { bytes, packed, check in
                .init(hexadecimalText: try ZIPBytePreview.render(bytes, check: check), byteCount: UInt64(bytes.count), packedBytes: packed)
            }
    }
}
