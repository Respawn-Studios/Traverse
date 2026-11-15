import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Concrete encodings for one emitted TAR stream. For compression, a sparse view
/// retains only the actual emitted metadata, never member bodies. The existing
/// parser checks this view and a fresh bounded inflate checks every raw byte.
internal final class TAROutputStream {
    enum Failure: Error, Equatable { case limit, mismatch }
    enum Encoding {
        case plain, gzip(Int32), bzip2(Int32)
        var codec: TARCompressedCodec? {
            switch self { case .plain: nil; case .gzip: .gzip; case .bzip2: .bzip2 }
        }
    }
    private struct Metadata { let offset: UInt64; let bytes: Data; var end: UInt64 { offset + UInt64(bytes.count) } }
    private let writer: ZIPFileEncoder
    private let rawLimit: UInt64
    private var encoder: CompressedArchiveEncoder?
    private let encoding: Encoding
    private var metadata: [Metadata] = []
    private var metadataBytes = 0
    private var rawHash = SHA256()
    private var completed: ZIPInputStamp?
    private var validated = false
    private var retired = false
    private var decoderPeakHeap: UInt64 = 0
    private let preservedGzipHeader: GzipArchiveHeader?
    private(set) var count: UInt64 = 0
    var encodedCount: UInt64 { writer.count }
    var digest: Data { writer.digest() }
    var peakCodecHeap: UInt64 { max(encoder?.peakCodecHeap ?? 0, decoderPeakHeap) }

    init(_ descriptor: Int32, encoding: Encoding = .plain, gzipHeader: GzipArchiveHeader? = nil, hooks: ZIPCreationHooks,
        check: @escaping @Sendable () throws -> Void) throws {
        writer = ZIPFileEncoder(descriptor, hooks: hooks)
        self.encoding = encoding
        preservedGzipHeader = gzipHeader
        switch encoding {
        case .plain: rawLimit = min(1 << 30, hooks.maximumEncodedBytes)
        case .gzip(let level), .bzip2(let level):
            rawLimit = TARCompressedDecoder.maximumBytes
            let stageWriter = writer
            encoder = try CompressedArchiveEncoder(maximumRaw: rawLimit,
                maximumEncoded: min(TARCompressedDecoder.maximumBytes, hooks.maximumEncodedBytes), level: level,
                codec: encoding.codec!, header: gzipHeader,
                check: check, output: { try stageWriter.write($0, check: check) })
        }
    }
    func write(_ bytes: Data, metadata retainMetadata: Bool = false,
        check: @Sendable () throws -> Void) throws {
        try check()
        guard !retired, completed == nil, UInt64(bytes.count) <= rawLimit - count else { throw Failure.limit }
        if let encoder {
            if retainMetadata, !bytes.isEmpty {
                guard bytes.count <= (32 << 20) - metadataBytes, metadata.count < 60_000 else { throw Failure.limit }
                metadata.append(.init(offset: count, bytes: bytes)); metadataBytes += bytes.count
            }
            try encoder.write(bytes); rawHash.update(data: bytes)
        } else { try writer.write(bytes, check: check) }
        count += UInt64(bytes.count)
    }
    func finish(check: @Sendable () throws -> Void) throws {
        try check(); guard !retired, completed == nil else { throw Failure.mismatch }
        try encoder?.finish(rawBytes: count, encodedBytes: { writer.count })
        completed = try ZIPInputStamp(writer.descriptor)
        guard completed?.size == Int64(encodedCount) else { throw FileOperationFailure.destinationChanged }
    }
    func verify(check: @escaping @Sendable () throws -> Void) throws -> TARParsedDirectory {
        guard !retired, !validated, let completed, try ZIPInputStamp(writer.descriptor) == completed else { throw Failure.mismatch }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < encodedCount {
            let amount = Int(min(65_536, encodedCount - offset))
            hash.update(data: try read(offset, amount, check: check)); offset += UInt64(amount)
        }
        guard Data(hash.finalize()) == digest else { throw Failure.mismatch }
        if let codec = encoding.codec {
            if let preservedGzipHeader {
                guard try GzipArchiveHeader(read(0, min(GzipArchiveHeader.maximumBytes, Int(encodedCount)), check: check)) == preservedGzipHeader else { throw Failure.mismatch }
            }
            if case .bzip2(let block) = encoding {
                guard try read(0, 4, check: check) == Data([66, 90, 104, UInt8(48 + block)]) else { throw Failure.mismatch }
            }
            decoderPeakHeap = try CompressedArchiveEncoder.verify(writer.descriptor, codec: codec, rawBytes: count,
                encodedBytes: encodedCount, expected: Data(rawHash.finalize()), check: check)
        }
        var limits = TARReadLimits(); limits.sourceBytes = rawLimit
        let parsed: TARParsedDirectory
        do {
            parsed = try TARMetadataParser.parse(length: count, limits: limits, check: check, read: {
                if self.encoding.codec == nil { return try self.read($0, $1, check: check) }
                return try self.readMetadata($0, $1, check: check)
            })
            _ = try TARCatalogBuilder.build(parsed, check: check)
        } catch { try check(); throw Failure.mismatch }
        guard try ZIPInputStamp(writer.descriptor) == completed else { throw FileOperationFailure.destinationChanged }
        validated = true; return parsed
    }
    func retire() { retired = true; encoder = nil }
    private func readMetadata(_ offset: UInt64, _ amount: Int, check: () throws -> Void) throws -> Data {
        try check()
        guard amount >= 0, amount <= 65_536, offset <= count, UInt64(amount) <= count - offset else { throw Failure.mismatch }
        if amount == 0 { return Data() }
        var low = 0, high = metadata.count
        while low < high {
            let middle = (low + high) / 2
            if metadata[middle].end <= offset { low = middle + 1 } else { high = middle }
        }
        var result = Data(), cursor = offset, index = low
        while result.count < amount {
            try check()
            guard metadata.indices.contains(index), metadata[index].offset <= cursor, cursor < metadata[index].end else { throw Failure.mismatch }
            let slice = metadata[index], begin = Int(cursor - slice.offset)
            let available = min(amount - result.count, slice.bytes.count - begin)
            result.append(slice.bytes[begin..<(begin + available)])
            cursor += UInt64(available); index += 1
        }
        return result
    }
    private func read(_ offset: UInt64, _ amount: Int, check: () throws -> Void) throws -> Data {
        guard amount >= 0, amount <= 65_536, offset <= encodedCount, UInt64(amount) <= encodedCount - offset else { throw Failure.mismatch }
        var data = Data(count: amount)
        try data.withUnsafeMutableBytes { buffer in
            var completed = 0
            while completed < amount {
                try check()
                let value = pread(writer.descriptor, buffer.baseAddress!.advanced(by: completed), amount - completed, off_t(offset) + off_t(completed))
                if value < 0, errno == EINTR { continue }
                guard value > 0 else { throw Failure.mismatch }; completed += value
            }
        }
        return data
    }
}
