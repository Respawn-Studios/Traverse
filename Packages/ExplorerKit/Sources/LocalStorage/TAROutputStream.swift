import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Two concrete encodings for one emitted TAR stream. For gzip, a sparse view
/// retains only the actual emitted metadata, never member bodies. The existing
/// parser checks this view and a fresh bounded inflate checks every raw byte.
internal final class TAROutputStream {
    enum Failure: Error, Equatable { case limit, mismatch }
    enum Encoding { case plain, gzip(Int32) }
    private struct Metadata { let offset: UInt64; let bytes: Data; var end: UInt64 { offset + UInt64(bytes.count) } }
    private let writer: ZIPFileEncoder
    private let rawLimit: UInt64
    private var gzip: GzipArchiveEncoder?
    private var metadata: [Metadata] = []
    private var metadataBytes = 0
    private var rawHash = SHA256()
    private var completed: ZIPInputStamp?
    private var validated = false
    private var retired = false
    private var decoderPeakHeap: UInt64 = 0
    private(set) var count: UInt64 = 0
    var encodedCount: UInt64 { writer.count }
    var digest: Data { writer.digest() }
    var peakCodecHeap: UInt64 { max(gzip?.peakCodecHeap ?? 0, decoderPeakHeap) }

    init(_ descriptor: Int32, encoding: Encoding = .plain, hooks: ZIPCreationHooks,
        check: @escaping @Sendable () throws -> Void) throws {
        writer = ZIPFileEncoder(descriptor, hooks: hooks)
        switch encoding {
        case .plain: rawLimit = min(1 << 30, hooks.maximumEncodedBytes)
        case .gzip(let level):
            rawLimit = TARCompressedDecoder.maximumBytes
            let stageWriter = writer
            gzip = try GzipArchiveEncoder(maximumRaw: rawLimit,
                maximumEncoded: min(TARCompressedDecoder.maximumBytes, hooks.maximumEncodedBytes), level: level,
                check: check, output: { try stageWriter.write($0, check: check) })
        }
    }
    func write(_ bytes: Data, metadata retainMetadata: Bool = false,
        check: @Sendable () throws -> Void) throws {
        try check()
        guard !retired, completed == nil, UInt64(bytes.count) <= rawLimit - count else { throw Failure.limit }
        if let gzip {
            if retainMetadata, !bytes.isEmpty {
                guard bytes.count <= (32 << 20) - metadataBytes, metadata.count < 60_000 else { throw Failure.limit }
                metadata.append(.init(offset: count, bytes: bytes)); metadataBytes += bytes.count
            }
            try gzip.write(bytes); rawHash.update(data: bytes)
        } else { try writer.write(bytes, check: check) }
        count += UInt64(bytes.count)
    }
    func finish(check: @Sendable () throws -> Void) throws {
        try check(); guard !retired, completed == nil else { throw Failure.mismatch }
        try gzip?.finish(rawBytes: count, encodedBytes: { writer.count })
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
        if gzip != nil {
            decoderPeakHeap = try GzipArchiveEncoder.verify(writer.descriptor, rawBytes: count,
                encodedBytes: encodedCount, expected: Data(rawHash.finalize()), check: check)
        }
        var limits = TARReadLimits(); limits.sourceBytes = rawLimit
        let parsed: TARParsedDirectory
        do {
            parsed = try TARMetadataParser.parse(length: count, limits: limits, check: check, read: {
                if self.gzip == nil { return try self.read($0, $1, check: check) }
                return try self.readMetadata($0, $1, check: check)
            })
            _ = try TARCatalogBuilder.build(parsed, check: check)
        } catch { try check(); throw Failure.mismatch }
        guard try ZIPInputStamp(writer.descriptor) == completed else { throw FileOperationFailure.destinationChanged }
        validated = true; return parsed
    }
    func retire() { retired = true; gzip = nil }
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
