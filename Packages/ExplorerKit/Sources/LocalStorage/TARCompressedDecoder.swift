import BoundedArchiveCodecs
import Foundation

/// The reviewed C codec owns only a synchronous descriptor-to-descriptor
/// transform. Source admission, destination ownership and publication remain
/// with the concrete compressed-TAR preparation owner.
internal enum TARCompressedDecoder {
    static let maximumBytes: UInt64 = 128 << 20
    static let maximumMembers: UInt32 = 128

    struct Outcome: Sendable {
        let compressedBytes: UInt64
        let decodedBytes: UInt64
        let members: UInt64
        let peakCodecHeap: UInt64
    }

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var timedOut = false
        private var allocationLimited = false
        private let deadline: TimeInterval

        init(seconds: TimeInterval = 60) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
        func stop() { lock.withLock { stopped = true } }
        func limitAllocation() { lock.withLock { allocationLimited = true } }
        func poll() -> Int32 {
            lock.withLock {
                if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true }
                return stopped || timedOut || allocationLimited ? 1 : 0
            }
        }
        var failure: TARArchiveFailure { lock.withLock { timedOut || allocationLimited ? .limited : .stopped } }
    }

    static func expand(input: Int32, output: Int32, codec: TARCompressedCodec = .gzip, cancellation: Cancellation) throws -> Outcome {
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        let expand = codec == .gzip ? tr_gzip_expand_fd : tr_bzip2_expand_fd
        let result = expand(input, output, maximumBytes, maximumBytes, maximumMembers,
            { raw in
                guard let raw else { return 1 }
                return Unmanaged<Cancellation>.fromOpaque(raw).takeUnretainedValue().poll()
            }, context)
        withExtendedLifetime(cancellation) { }
        switch result.status {
        case 0:
            guard result.heap_remaining_bytes == 0, result.members > 0,
                  result.members <= UInt64(maximumMembers), result.read_bytes == result.consumed_bytes,
                  result.read_bytes <= maximumBytes, result.written_bytes <= maximumBytes else {
                throw TARArchiveFailure.unavailable
            }
            return .init(compressedBytes: result.consumed_bytes, decodedBytes: result.written_bytes,
                members: result.members, peakCodecHeap: result.heap_peak_bytes)
        case 2, 3: throw TARArchiveFailure.malformed
        case 4, 9: throw TARArchiveFailure.limited
        case 5: throw cancellation.failure
        case 7, 8: throw TARArchiveFailure.changed
        default: throw TARArchiveFailure.unavailable
        }
    }
}
