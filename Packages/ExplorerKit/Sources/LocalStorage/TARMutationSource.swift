import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Two concrete byte sources for the same TAR layout. Only the original URL
/// and its pinned observation authorize mutation; the prepared spool is data.
// Immutable descriptor ownership; reads use pread, never a shared file offset.
// The producer retains this object until its single worker has drained.
internal final class TARMutationSource: @unchecked Sendable {
    let original: PinnedLocalFileSource
    let spool: TARCompressedSpoolLease?
    let security: ArchiveRewriteSourceSecurity
    let gzipHeader: GzipArchiveHeader?
    var length: UInt64 { spool?.decodedBytes ?? UInt64(original.observed.size) }

    init(_ binding: TARSourceBinding, check: @Sendable () throws -> Void) throws {
        let original = try PinnedLocalFileSource(binding.source)
        guard original.observed == binding.stamp, original.observed.size <= 1 << 30 else { throw FileOperationFailure.sourceChanged }
        self.original = original; security = try ArchiveRewriteSourceSecurity(original); spool = binding.compressed
        if let spool {
            guard spool.original.source == binding.source, spool.original.stamp == binding.stamp,
                  TARSourceBinding.isGzipFilename(binding.source.lastPathComponent),
                  spool.decodedBytes <= TARCompressedDecoder.maximumBytes,
                  UInt64(original.observed.size) <= TARCompressedDecoder.maximumBytes else { throw TARMemberEditFailure.unsupportedArchive }
            gzipHeader = try GzipArchiveHeader(original.read(0, 10, maximum: 10, check: check))
            try spool.verifyDigest(check: check)
            try withoutActuallyEscaping(check) { check in
                _ = try GzipArchiveEncoder.verify(original.descriptor, rawBytes: spool.decodedBytes,
                    encodedBytes: UInt64(original.observed.size), expected: spool.digest, check: check)
            }
        } else {
            guard binding.source.pathExtension.lowercased() == "tar" else { throw TARMemberEditFailure.unsupportedArchive }
            gzipHeader = nil
        }
        try validate()
    }
    func validate() throws {
        do { try original.validate() }
        catch ZIPArchiveFailure.changed { throw FileOperationFailure.sourceChanged }
        guard try ArchiveRewriteSourceSecurity(original) == security else { throw FileOperationFailure.sourceChanged }
        if let spool {
            try spool.validate()
            guard try spool.original.security.reobserve(original) == spool.original.security else { throw FileOperationFailure.sourceChanged }
        }
    }
    func read(_ offset: UInt64, _ count: Int, check: () throws -> Void) throws -> Data {
        guard count >= 0, count <= 66_560, offset <= length, UInt64(count) <= length - offset else { throw TARMemberEditFailure.contentMismatch }
        guard let spool else { return try original.read(offset, count, maximum: 66_560, check: check) }
        var result = Data()
        while result.count < count {
            let amount = min(65_536, count - result.count)
            result.append(try spool.read(offset + UInt64(result.count), amount, check: check))
        }
        return result
    }
    func parse(check: () throws -> Void) throws -> TARParsedDirectory {
        if spool == nil { return try TARSourceCatalog.parse(original, limits: .init(), check: check) }
        var limits = TARReadLimits(); limits.sourceBytes = TARCompressedDecoder.maximumBytes
        return try TARMetadataParser.parse(length: length, limits: limits, check: check,
            read: { try self.read($0, $1, check: check) })
    }
}

extension TARSourceBinding {
    static func isGzipFilename(_ name: String) -> Bool {
        let lower = name.lowercased(); return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
    }
    var authoredFormat: AuthoredArchiveFormat { compressed == nil ? .strictPortableTAR : .strictPortableTARGzip }
}
