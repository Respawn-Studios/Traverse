import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Only LocalStorage's sealed requested-file owner can construct this adapter.
/// Native views never receive its source or destination descriptors.
private final class DownloadedFileProducer: ArchiveFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    private let source: DownloadPublicationLease
    convenience init(_ file: RemoteDownloadedFile) throws { self.init(try file.claimPublicationOnWorker()) }
    init(_ source: DownloadPublicationLease) {
        self.source = source
        preview = .init(files: 1, folders: 0, logicalBytes: source.logicalBytes, longestPathBytes: 0)
    }
    func validate(check: @Sendable () throws -> Void) throws {
        try withSource(check: check) { descriptor, url in
            // Reuse the qualified exact-mark inheritance boundary. No archive
            // parser or source-body read is involved in this metadata check.
            _ = try ZIPSourceSecurity.extractionWitness(descriptor, url: url, allowingInheritance: true)
        }
    }
    func produce(into destination: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try withSource(check: check) { descriptor, url in
            try check()
            var before = stat()
            guard fstat(destination, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
                  before.st_nlink == 1, before.st_size == 0 else { throw FileOperationFailure.destinationChanged }
            let security = try ZIPSourceSecurity.extractionWitness(descriptor, url: url, allowingInheritance: true)
            let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(destination)
            var offset: UInt64 = 0, hash = SHA256()
            while offset < source.logicalBytes {
                try check(); let count = Int(min(65536, source.logicalBytes - offset)); var data = Data(count: count)
                let found = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
                if found < 0, errno == EINTR { continue }
                guard found == count else { throw FileOperationFailure.sourceChanged }
                try data.withUnsafeBytes { buffer in
                    var at = 0
                    while at < buffer.count {
                        try check(); let written = pwrite(destination, buffer.baseAddress!.advanced(by: at), buffer.count - at, off_t(offset) + off_t(at))
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw Self.failure(written == 0 ? EIO : errno) }; at += written
                    }
                }
                hash.update(data: data); offset += UInt64(found); progress(UInt64(found), 0)
            }
            guard Data(hash.finalize()) == source.digest else { throw FileOperationFailure.copyContentMismatch }
            guard fchmod(destination, 0o644) == 0 else { throw Self.failure(errno) }
            try security.applyToDownloadedFile(from: descriptor, to: destination, stageAtCreation: stageAtCreation)
            var after = stat()
            guard fstat(destination, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  after.st_nlink == 1, after.st_size >= 0, UInt64(after.st_size) == source.logicalBytes else { throw FileOperationFailure.destinationChanged }
            try check(); progress(0, 1)
            return .init(relative: "", device: after.st_dev, inode: after.st_ino, kind: after.st_mode & S_IFMT,
                birthSeconds: after.st_birthtimespec.tv_sec, birthNanoseconds: after.st_birthtimespec.tv_nsec,
                changedSeconds: after.st_ctimespec.tv_sec, changedNanoseconds: after.st_ctimespec.tv_nsec,
                size: after.st_size, contentSHA256: source.digest)
        }
    }
    func finished() { source.release() }
    private func withSource<T>(check: () throws -> Void, _ body: (Int32, URL) throws -> T) throws -> T {
        do { return try source.withSource(check: check, body) }
        catch let error as FileOperationFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch is ZIPExtractionFailure { throw FileOperationFailure.copyMetadataMismatch }
        catch { throw FileOperationFailure.sourceChanged }
    }
    private static func failure(_ code: Int32) -> FileOperationFailure {
        switch code { case ENOSPC: .outOfSpace; case EDQUOT: .quotaExceeded; case EACCES, EPERM: .accessDenied
        case ENOENT: .notFound; default: .ioFailure }
    }
}

/// Candidate producer for the held v14 route. It uses the same sealed source
/// lease and byte digest, but creates a fresh public-marked stage instead of
/// transferring an opaque source xattr value to that different object.
private final class PublicQuarantineDownloadedFileProducer: PublicQuarantineReceivedFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    private let source: DownloadPublicationLease
    convenience init(_ file: RemoteDownloadedFile) throws {
        self.init(try file.claimPublicQuarantinePublicationOnWorker())
    }
    convenience init(_ file: SMBDownloadedFile) throws {
        self.init(try file.claimPublicQuarantinePublicationOnWorker())
    }
    init(_ source: DownloadPublicationLease) {
        self.source = source
        preview = .init(files: 1, folders: 0, logicalBytes: source.logicalBytes, longestPathBytes: 0)
    }
    func validate(check: @Sendable () throws -> Void) throws {
        try withSource(check: check) { descriptor, url in
            _ = try OSManagedQuarantineCandidate.observeMarkedSource(descriptor, at: url)
        }
    }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        throw FileOperationFailure.unsupported
    }
    func producePublicQuarantined(into destination: Int32, at stageURL: URL,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try withSource(check: check) { descriptor, url in
            try check()
            let sourceMark = try OSManagedQuarantineCandidate.observeMarkedSource(descriptor, at: url)
            let stageMark = try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(destination, at: stageURL)
            var before = stat()
            guard fstat(destination, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == geteuid(), before.st_nlink == 1,
                  before.st_size == 0 else { throw FileOperationFailure.destinationChanged }
            var offset: UInt64 = 0, hash = SHA256()
            while offset < source.logicalBytes {
                try check()
                let count = Int(min(65536, source.logicalBytes - offset))
                var data = Data(count: count)
                let found = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
                if found < 0, errno == EINTR { continue }
                guard found == count else { throw FileOperationFailure.sourceChanged }
                try data.withUnsafeBytes { buffer in
                    var at = 0
                    while at < buffer.count {
                        try check()
                        let written = pwrite(destination, buffer.baseAddress!.advanced(by: at),
                            buffer.count - at, off_t(offset) + off_t(at))
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw Self.failure(written == 0 ? EIO : errno) }
                        at += written
                    }
                }
                hash.update(data: data); offset += UInt64(found); progress(UInt64(found), 0)
            }
            guard Data(hash.finalize()) == source.digest else { throw FileOperationFailure.copyContentMismatch }
            guard fchmod(destination, 0o644) == 0 else { throw Self.failure(errno) }
            try sourceMark.require(descriptor, at: url)
            try stageMark.require(destination, at: stageURL)
            var after = stat()
            guard fstat(destination, &after) == 0, after.st_dev == before.st_dev,
                  after.st_ino == before.st_ino, after.st_nlink == 1,
                  after.st_size >= 0, UInt64(after.st_size) == source.logicalBytes else {
                throw FileOperationFailure.destinationChanged
            }
            try check(); progress(0, 1)
            return .init(relative: "", device: after.st_dev, inode: after.st_ino,
                kind: after.st_mode & S_IFMT, birthSeconds: after.st_birthtimespec.tv_sec,
                birthNanoseconds: after.st_birthtimespec.tv_nsec,
                changedSeconds: after.st_ctimespec.tv_sec, changedNanoseconds: after.st_ctimespec.tv_nsec,
                size: after.st_size, contentSHA256: source.digest, publicQuarantineV1: true)
        }
    }
    func finished() { source.release() }
    private func withSource<T>(check: () throws -> Void, _ body: (Int32, URL) throws -> T) throws -> T {
        do { return try source.withSource(check: check, body) }
        catch let error as FileOperationFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw FileOperationFailure.sourceChanged }
    }
    private static func failure(_ code: Int32) -> FileOperationFailure {
        switch code { case ENOSPC: .outOfSpace; case EDQUOT: .quotaExceeded
        case EACCES, EPERM: .accessDenied; case ENOENT: .notFound; default: .ioFailure }
    }
}

extension RemoteDownloadedFile {
    /// Source-only public-mark candidate. The engine's held default rejects
    /// this before a source lease or journal record is created.
    func preparePublicQuarantineCandidate(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection? = nil) async throws -> ReceivedFilePlan {
        try await operations.prepareReceivedFile(parent: parent, name: name,
            observing: destination, publicQuarantineV1: true) { [self] check in
            try check(); return try PublicQuarantineDownloadedFileProducer(self)
        }
    }
    /// Source qualification only. Ordinary UI continues to use the held copy
    /// publication path until separately reviewed signed-sandbox evidence.
    func prepareAdoption(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection? = nil) async throws -> AdoptedReceivedFilePlan {
        try await operations.prepareReceivedFileAdoption(parent: parent, name: name, observing: destination) { [self] in
            try claimPublicationOnWorker()
        }
    }
    func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection? = nil) async throws -> ReceivedFilePlan {
        try await operations.prepareReceivedFile(parent: parent, name: name, observing: destination) { [self] check in
            try check(); return try DownloadedFileProducer(self)
        }
    }
}

extension SMBDownloadedFile {
    func preparePublicQuarantineCandidate(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection? = nil) async throws -> ReceivedFilePlan {
        try await operations.prepareReceivedFile(parent: parent, name: name,
            observing: destination, publicQuarantineV1: true) { [self] check in
            try check(); return try PublicQuarantineDownloadedFileProducer(self)
        }
    }
    func prepareAdoption(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection? = nil) async throws -> AdoptedReceivedFilePlan {
        try await operations.prepareReceivedFileAdoption(parent: parent, name: name, observing: destination) { [self] in
            try claimPublicationOnWorker()
        }
    }
    func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection? = nil) async throws -> ReceivedFilePlan {
        try await operations.prepareReceivedFile(parent: parent, name: name, observing: destination) { [self] check in
            try check(); return try DownloadedFileProducer(claimPublicationOnWorker())
        }
    }
}
