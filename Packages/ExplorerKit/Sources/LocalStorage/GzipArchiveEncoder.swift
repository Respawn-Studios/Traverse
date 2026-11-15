import BoundedGzip
import CryptoKit
import FileOperations
import Foundation

/// Synchronous, single-worker codec ownership. The C side has no path or file
/// authority; encoded chunks go through the existing guarded stage writer.
internal final class GzipArchiveEncoder {
    private final class Context {
        let check: @Sendable () throws -> Void
        let output: (UnsafeRawBufferPointer) throws -> Void
        var failure: Error?
        init(check: @escaping @Sendable () throws -> Void, output: @escaping (UnsafeRawBufferPointer) throws -> Void) {
            self.check = check; self.output = output
        }
        func poll() -> Int32 {
            do { try check(); return 0 } catch { failure = error; return 1 }
        }
        func consume(_ bytes: UnsafePointer<UInt8>?, _ count: UInt32) -> Int32 {
            guard count <= 65_536, count == 0 || bytes != nil else { return 0 }
            do { try output(.init(start: bytes, count: Int(count))); return 1 }
            catch { failure = error; return 0 }
        }
    }
    private let context: Context
    private var handle: OpaquePointer?
    private var finished = false
    private(set) var peakCodecHeap: UInt64 = 0

    init(maximumRaw: UInt64, maximumEncoded: UInt64, level: Int32, header: GzipArchiveHeader? = nil,
        check: @escaping @Sendable () throws -> Void,
        output: @escaping (UnsafeRawBufferPointer) throws -> Void) throws {
        let context = Context(check: check, output: output); self.context = context
        var result = tr_gzip_result()
        func create(_ header: UnsafePointer<tr_gzip_header>?) -> OpaquePointer? {
            tr_gzip_encoder_create(maximumRaw, maximumEncoded, level, header,
            { raw in raw.map { Unmanaged<Context>.fromOpaque($0).takeUnretainedValue().poll() } ?? 1 },
            { raw, bytes, count in raw.map { Unmanaged<Context>.fromOpaque($0).takeUnretainedValue().consume(bytes, count) } ?? 0 },
            Unmanaged.passUnretained(context).toOpaque(), &result)
        }
        if let header {
            let extra = header.extra ?? Data(), name = header.name ?? Data(), comment = header.comment ?? Data()
            guard extra.count <= 65_535, name.count <= GzipArchiveHeader.maximumBytes,
                  comment.count <= GzipArchiveHeader.maximumBytes else { throw TAROutputStream.Failure.limit }
            handle = extra.withUnsafeBytes { extra in name.withUnsafeBytes { name in comment.withUnsafeBytes { comment in
                var value = tr_gzip_header()
                value.modification_time = header.modificationTime; value.operating_system = header.operatingSystem
                value.text = header.text ? 1 : 0; value.header_crc = header.headerCRC ? 1 : 0
                value.has_extra = header.extra == nil ? 0 : 1; value.has_name = header.name == nil ? 0 : 1
                value.has_comment = header.comment == nil ? 0 : 1
                value.extra = extra.bindMemory(to: UInt8.self).baseAddress; value.extra_count = UInt32(extra.count)
                value.name = name.bindMemory(to: UInt8.self).baseAddress; value.name_count = UInt32(name.count)
                value.comment = comment.bindMemory(to: UInt8.self).baseAddress; value.comment_count = UInt32(comment.count)
                return withUnsafePointer(to: &value) { create($0) }
            } } }
        } else { handle = create(nil) }
        try require(result)
        guard handle != nil else { throw TAROutputStream.Failure.mismatch }
    }
    deinit { if let handle { _ = tr_gzip_encoder_destroy(handle) } }

    private func require(_ result: tr_gzip_result) throws {
        peakCodecHeap = max(peakCodecHeap, result.heap_peak_bytes)
        if let failure = context.failure { throw failure }
        guard result.status == 0 else { throw Self.failure(result.status) }
    }
    static func failure(_ status: Int32) -> Error {
        switch status {
        case 4, 9: TAROutputStream.Failure.limit
        case 5: CancellationError()
        case 7, 8: FileOperationFailure.destinationChanged
        default: TAROutputStream.Failure.mismatch
        }
    }
    func write(_ bytes: Data) throws {
        guard let handle, !finished else { throw TAROutputStream.Failure.mismatch }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(65_536, buffer.count - offset)
                try require(tr_gzip_encoder_write(handle, buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), UInt32(count)))
                offset += count
            }
        }
    }
    func finish(rawBytes: UInt64, encodedBytes: () -> UInt64) throws {
        guard let handle, !finished else { throw TAROutputStream.Failure.mismatch }
        let result = tr_gzip_encoder_finish(handle)
        try require(result)
        guard result.members == 1, result.read_bytes == rawBytes, result.consumed_bytes == rawBytes,
              result.written_bytes == encodedBytes(), result.heap_remaining_bytes == 0 else {
            throw TAROutputStream.Failure.mismatch
        }
        finished = true
    }
    static func verify(_ descriptor: Int32, rawBytes: UInt64, encodedBytes: UInt64, expected: Data,
        check: @escaping @Sendable () throws -> Void) throws -> UInt64 {
        final class Digest {
            var hash = SHA256()
            var count: UInt64 = 0
        }
        let digest = Digest()
        let context = Context(check: check, output: { bytes in
            digest.hash.update(bufferPointer: bytes); digest.count += UInt64(bytes.count)
        })
        let result = tr_gzip_consume_fd(descriptor, encodedBytes, rawBytes, 1,
            { raw in raw.map { Unmanaged<Context>.fromOpaque($0).takeUnretainedValue().poll() } ?? 1 },
            { raw, bytes, count in raw.map { Unmanaged<Context>.fromOpaque($0).takeUnretainedValue().consume(bytes, count) } ?? 0 },
            Unmanaged.passUnretained(context).toOpaque())
        withExtendedLifetime(context) {}
        if let failure = context.failure { throw failure }
        guard result.status == 0 else { throw failure(result.status) }
        guard result.members == 1, result.read_bytes == encodedBytes, result.consumed_bytes == encodedBytes,
              result.written_bytes == rawBytes, digest.count == rawBytes,
              Data(digest.hash.finalize()) == expected, result.heap_remaining_bytes == 0 else {
            throw TAROutputStream.Failure.mismatch
        }
        return result.heap_peak_bytes
    }
}
