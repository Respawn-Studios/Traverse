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
    let bzip2BlockSize: Int32?
    var length: UInt64 { spool?.decodedBytes ?? UInt64(original.observed.size) }

    init(_ binding: TARSourceBinding, check: @Sendable () throws -> Void) throws {
        let original = try PinnedLocalFileSource(binding.source)
        guard original.observed == binding.stamp, original.observed.size <= 1 << 30 else { throw FileOperationFailure.sourceChanged }
        self.original = original; security = try ArchiveRewriteSourceSecurity(original); spool = binding.compressed
        if let spool {
            guard spool.original.source == binding.source, spool.original.stamp == binding.stamp,
                  TARCompressedCodec.filename(binding.source.lastPathComponent) == spool.original.codec,
                  spool.decodedBytes <= TARCompressedDecoder.maximumBytes,
                  UInt64(original.observed.size) <= TARCompressedDecoder.maximumBytes else { throw TARMemberEditFailure.unsupportedArchive }
            if spool.original.codec == .gzip {
                gzipHeader = try GzipArchiveHeader(original.read(0,
                    min(GzipArchiveHeader.maximumBytes, Int(original.observed.size)), maximum: GzipArchiveHeader.maximumBytes, check: check))
                bzip2BlockSize = nil
            } else {
                let header = try original.read(0, 4, maximum: 4, check: check)
                guard TARCompressedCodec.bzip2.accepts(header) else { throw TARMemberEditFailure.unsupportedArchive }
                gzipHeader = nil; bzip2BlockSize = Int32(header[3] - 48)
            }
            try spool.verifyDigest(check: check)
            try withoutActuallyEscaping(check) { check in
                _ = try CompressedArchiveEncoder.verify(original.descriptor, codec: spool.original.codec, rawBytes: spool.decodedBytes,
                    encodedBytes: UInt64(original.observed.size), expected: spool.digest, check: check)
            }
        } else {
            guard binding.source.pathExtension.lowercased() == "tar" else { throw TARMemberEditFailure.unsupportedArchive }
            gzipHeader = nil
            bzip2BlockSize = nil
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
    var formatName: String {
        switch compressed?.original.codec { case .gzip: "TAR.gz"; case .bzip2: "TAR.bz2"; case nil: "TAR" }
    }
    var authoredFormat: AuthoredArchiveFormat { compressed?.original.codec.authoredFormat ?? .strictPortableTAR }
}
