import Foundation
import CryptoKit

/// Exact directory + ZIP end structures captured from the bytes actually
/// parsed. This is ephemeral metadata, never a file-body index or access grant.
internal struct ZIPDirectoryWitness: Sendable {
    let offset: UInt64
    let bytes: UInt64
    let digest: Data
}

public enum ZIPTextPreviewFailure: Error, Equatable, Sendable {
    case unsupported, tooLarge, notText, limitReached
}

/// A session-produced snapshot witness, not a local path or file access grant.
public struct ZIPTextPreviewSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal let binding: ZIPSourceBinding
    internal let path: String
    internal let recordOffset: UInt64
    internal let centralOffset: UInt64
    internal let centralEnd: UInt64
    internal let directoryWitness: ZIPDirectoryWitness
    public var displayName: String { path.split(separator: "/").last.map(String.init) ?? "Text preview" }
    public var description: String { "Selected ZIP text member" }
    public var debugDescription: String { description }
}

/// Complete checked UTF-8 only. Diagnostics deliberately omit the body/name.
public struct ZIPTextPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumUTF8Bytes: UInt64 = 256 << 10
    public static let maximumPackedBytes: UInt64 = 1 << 20
    public let text: String
    public let utf8Bytes: UInt64
    public let packedBytes: UInt64
    public var description: String { "Checked ZIP text preview (\(utf8Bytes) UTF-8 bytes)" }
    public var debugDescription: String { description }
}

internal struct ZIPTextPreviewLimits: Sendable {
    var seconds: Double = 5
    var maximumBytes = ZIPTextPreview.maximumUTF8Bytes
    var maximumPackedBytes = ZIPTextPreview.maximumPackedBytes

    static let image = Self(seconds: 8, maximumBytes: ArchiveImagePreview.maximumSourceBytes,
        maximumPackedBytes: ArchiveImagePreview.maximumPackedBytes)
}

internal enum ZIPTextPreviewReader {
    static func read(_ selection: ZIPTextPreviewSelection, excluding roots: [URL], limits: ZIPReadLimits,
        previewLimits: ZIPTextPreviewLimits, check cancellation: @escaping () throws -> Void,
        probe: (@Sendable (ZIPArchiveReader.Stage) throws -> Void)?) throws -> ZIPTextPreview {
        try readChecked(selection, excluding: roots, limits: limits, previewLimits: previewLimits, check: cancellation, probe: probe) { bytes, packed, check in
            try check()
            let text = try validatedText(bytes)
            return .init(text: text, utf8Bytes: UInt64(bytes.count), packedBytes: packed)
        }
    }

    /// Edit admission must honor the same visible-text controls as Preview.
    static func validatedText(_ bytes: Data) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8), text.unicodeScalars.allSatisfy({ scalar in
                let value = scalar.value
                return (value >= 32 || [9, 10, 13].contains(value)) && !(0x7f...0x9f).contains(value)
                    && ![0x061c, 0x200e, 0x200f].contains(value)
                    && !(0x202a...0x202e).contains(value) && !(0x2066...0x2069).contains(value)
            }) else { throw ZIPTextPreviewFailure.notText }
        return text
    }

    /// Transform the complete verified byte sequence before the original final
    /// directory/source witness checks. No transform can skip those checks.
    static func readChecked<Output>(_ selection: ZIPTextPreviewSelection, excluding roots: [URL], limits: ZIPReadLimits,
        previewLimits: ZIPTextPreviewLimits, check cancellation: @escaping () throws -> Void,
        probe: (@Sendable (ZIPArchiveReader.Stage) throws -> Void)?,
        transform: (Data, UInt64, () throws -> Void) throws -> Output) throws -> Output {
        let began = ProcessInfo.processInfo.systemUptime
        func check() throws {
            try cancellation()
            guard ProcessInfo.processInfo.systemUptime - began < previewLimits.seconds else {
                throw ZIPTextPreviewFailure.limitReached
            }
        }
        try check()
        let source = try ZIPSourceFile(selection.binding.source, excluding: roots)
        guard source.observed == selection.binding.stamp else { throw ZIPArchiveFailure.changed }
        do {
            try probe?(.opened)
            let read: (UInt64, Int) throws -> Data = { offset, count in
                let bytes = try source.read(offset, count, maximum: max(limits.centralBytes, 65_557), check: check)
                try probe?(.read)
                return bytes
            }
            func validateDirectory() throws {
                let witness = selection.directoryWitness, length = UInt64(source.observed.size)
                guard witness.offset == selection.centralOffset, witness.digest.count == 32,
                    ZIPMetadataParser.fits(witness.offset, witness.bytes, before: length),
                    witness.offset + witness.bytes == length,
                    witness.bytes <= UInt64(max(0, limits.centralBytes)) + 65_633 else { throw ZIPArchiveFailure.changed }
                var hasher = SHA256(), offset: UInt64 = 0
                while offset < witness.bytes {
                    try check()
                    let count = Int(min(UInt64(65_536), witness.bytes-offset))
                    hasher.update(data: try read(witness.offset+offset,count)); offset += UInt64(count)
                }
                guard Data(hasher.finalize()) == witness.digest else { throw ZIPArchiveFailure.changed }
            }
            try validateDirectory()
            // The initial complete catalog qualified this exact record offset.
            // A fresh matching source stamp is mandatory; then reuse the same
            // record decoder without rebuilding an unrelated directory tree.
            let record = try ZIPMetadataParser.selectedRecord(at: selection.recordOffset,
                centralOffset: selection.centralOffset, centralEnd: selection.centralEnd,
                sourceLength: UInt64(source.observed.size), limits: limits, read: read)
            try check()
            guard record.kind == .file, record.name.utf8.elementsEqual(selection.path.utf8) else { throw ZIPArchiveFailure.changed }
            guard record.logical <= previewLimits.maximumBytes, record.packed <= previewLimits.maximumPackedBytes else {
                throw ZIPTextPreviewFailure.tooLarge
            }
            var content = ZIPContentLimits()
            content.files = 1; content.nodes = 1
            content.memberBytes = previewLimits.maximumBytes
            content.jobBytes = previewLimits.maximumBytes
            content.packedBytes = previewLimits.maximumPackedBytes
            let layout = try ZIPContentVerifier.prepare([record], limits: content, check: check, read: read)
            guard let extent = layout.extents.first else { throw ZIPArchiveFailure.changed }
            try probe?(.previewing)
            try check()
            var bytes = Data()
            bytes.reserveCapacity(Int(record.logical))
            try ZIPContentDecoder.check(method: record.method, packed: record.packed, logical: record.logical,
                expectedCRC: record.crc, check: check,
                read: { offset, count in try read(extent.payload + offset, count) }, decoded: { _ in }, consume: { chunk in
                    guard UInt64(bytes.count) <= previewLimits.maximumBytes,
                          UInt64(chunk.count) <= previewLimits.maximumBytes - UInt64(bytes.count) else {
                        throw ZIPTextPreviewFailure.tooLarge
                    }
                    bytes.append(contentsOf: chunk)
                })
            try check()
            let output = try transform(bytes, record.packed, check)
            try validateDirectory()
            try source.validate()
            return output
        } catch {
            // A failure is not permission to skip the source's final witness.
            try source.validate()
            try check()
            throw error
        }
    }
}
