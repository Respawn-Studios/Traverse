import CryptoKit
import Darwin
import Foundation

internal struct TARCompressedOriginalProof: Equatable, Sendable {
    enum Security: Equatable, Sendable {
        case exact(ZIPSourceSecurity.ExtractionWitness)
        case publicProperties(OSManagedQuarantineCandidate.ExtractionSourceWitness)

        var exactDigest: Data? {
            if case .exact(let witness) = self { return witness.expectedQuarantineSHA256 }
            return nil
        }
        var publicWitness: OSManagedQuarantineCandidate.ExtractionSourceWitness? {
            if case .publicProperties(let witness) = self { return witness }
            return nil
        }
        static func observe(_ source: PinnedLocalFileSource, publicQuarantine: Bool) throws -> Self {
            if publicQuarantine {
                return .publicProperties(try OSManagedQuarantineCandidate.observeExtractionSource(
                    source.descriptor, at: source.url))
            }
            return .exact(try ZIPSourceSecurity.extractionWitness(source.descriptor, url: source.url,
                allowingInheritance: true))
        }
        func reobserve(_ source: PinnedLocalFileSource) throws -> Self {
            switch self {
            case .exact: return try Self.observe(source, publicQuarantine: false)
            case .publicProperties: return try Self.observe(source, publicQuarantine: true)
            }
        }
    }
    let source: URL
    let stamp: PinnedLocalFileSource.Stamp
    let security: Security
    let codec: TARCompressedCodec
    init(source: URL, stamp: PinnedLocalFileSource.Stamp, security: Security, codec: TARCompressedCodec = .gzip) {
        self.source = source; self.stamp = stamp; self.security = security; self.codec = codec
    }
}

/// Only an unlinked, read-only descriptor is handed to a catalog or producer.
/// The original compressed URL remains the sole source/history authority.
internal final class TARCompressedSpoolLease: @unchecked Sendable {
    struct Stamp: Equatable, Sendable {
        let device: Int32, inode: UInt64, size: Int64
        let mode: UInt16, owner: UInt32, links: UInt16, flags: UInt32
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        let changedSeconds: Int, changedNanoseconds: Int

        init(_ fd: Int32) throws {
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_size >= 0, value.st_nlink == 0,
                  value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o600 else {
                throw TARArchiveFailure.changed
            }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            mode = value.st_mode; owner = value.st_uid; links = value.st_nlink; flags = value.st_flags
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    let original: TARCompressedOriginalProof
    let decodedBytes: UInt64
    let digest: Data
    let stamp: Stamp
    private let descriptor: Int32
    private let retire: @Sendable (Int32) -> Void

    init(descriptor: Int32, original: TARCompressedOriginalProof, decodedBytes: UInt64,
         digest: Data, stamp: Stamp, retire: @escaping @Sendable (Int32) -> Void) {
        self.descriptor = descriptor; self.original = original; self.decodedBytes = decodedBytes
        self.digest = digest; self.stamp = stamp; self.retire = retire
    }
    deinit { retire(descriptor) }

    func validate() throws {
        guard try Stamp(descriptor) == stamp, UInt64(stamp.size) == decodedBytes else {
            throw TARArchiveFailure.changed
        }
    }
    func read(_ offset: UInt64, _ count: Int, check: () throws -> Void) throws -> Data {
        try check(); try validate()
        guard count >= 0, count <= 65_536, offset <= decodedBytes,
              UInt64(count) <= decodedBytes - offset, offset <= UInt64(Int64.max) else {
            throw TARArchiveFailure.malformed
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < count {
                try check()
                let amount = pread(descriptor, bytes.baseAddress!.advanced(by: completed),
                                   count - completed, off_t(offset) + off_t(completed))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw TARArchiveFailure.unavailable }
                completed += amount
            }
        }
        try validate(); return data
    }
    func verifyDigest(check: () throws -> Void) throws {
        var digest = SHA256(), offset: UInt64 = 0
        while offset < decodedBytes {
            try check()
            let size = Int(min(65_536, decodedBytes - offset))
            digest.update(data: try read(offset, size, check: check))
            offset += UInt64(size)
        }
        try validate()
        guard Data(digest.finalize()) == self.digest else { throw TARArchiveFailure.changed }
    }
}
