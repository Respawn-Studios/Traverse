import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Produces only from the sealed private receipt. It issues no remote request,
/// opens no user source and writes only engine-supplied fresh descriptors.
private final class DownloadedDirectoryProducer: PublicQuarantineTreeProducerV16, Sendable {
    let preview: ArchiveProductionPreview
    let publicProducedTreeV16: PublicProducedTreePurposeV16?
    private let source: DownloadPublicationLease, manifest: DownloadTreeManifest.Sealed
    init(_ tree: RemoteDownloadedTree, publicQuarantineTreeV16: Bool = false) throws {
        (source, manifest) = try tree.claimPublicationOnWorker()
        publicProducedTreeV16 = publicQuarantineTreeV16 ? .receivedFolder : nil
        preview = .init(files: tree.manifest.files, folders: tree.manifest.folders,
            logicalBytes: tree.manifest.logicalBytes, longestPathBytes: tree.manifest.longestPathBytes)
    }
    func validate(check: @Sendable () throws -> Void) throws {
        try source.withSource(check: check) { descriptor, url in
            if publicProducedTreeV16 != nil { _ = try OSManagedQuarantineCandidate.observeMarkedSource(descriptor, at: url) }
            else { _ = try ZIPSourceSecurity.extractionWitness(descriptor, url: url, allowingInheritance: true) }
        }
    }
    func produce(in directory: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        try produce(in: directory, privateStage: nil, check: check, progress: progress)
    }
    func produce(in directory: Int32, at privateStage: URL, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        guard publicProducedTreeV16 == .receivedFolder else { throw FileOperationFailure.invalidRequest }
        return try produce(in: directory, privateStage: privateStage, check: check, progress: progress)
    }
    private func produce(in directory: Int32, privateStage: URL?, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        try source.withSource(check: check) { payload, url in
            try check()
            var facts = stat()
            guard fstat(directory, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR, facts.st_uid == geteuid(),
                  try DownloadDisk.names(directory, maximum: 1).isEmpty else { throw FileOperationFailure.destinationChanged }
            let security = privateStage == nil
                ? try ZIPSourceSecurity.extractionWitness(payload, url: url, allowingInheritance: true) : nil
            if privateStage != nil { _ = try OSManagedQuarantineCandidate.observeMarkedSource(payload, at: url) }
            let rootMark = try privateStage.map { try OSManagedQuarantineCandidate.prepareReceivedTreeNode(directory, at: $0) }
            guard fchmod(directory, 0o755) == 0 else { throw Self.failure(errno) }
            try security?.apply(to: directory)
            if let privateStage { try rootMark?.require(directory, at: privateStage) }
            var identities: [Data: DownloadDisk.Identity] = [Data(): try DownloadDisk.identity(directory)]
            for record in manifest.nodes.dropFirst() {
                try check()
                let node = record.node, parts = node.components, name = String(decoding: parts.last!, as: UTF8.self)
                let created = try withNode(directory, parts: Array(parts.dropLast()), identities: identities, directory: true, check: check) { parent in
                    let output: Int32
                    if node.directory {
                        guard mkdirat(parent, name, 0o700) == 0 else { throw Self.failure(errno) }
                        output = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    } else {
                        output = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    }
                    guard output >= 0 else { throw Self.failure(errno) }; defer { close(output) }
                    let identity = try DownloadDisk.identity(output)
                    let nodeURL = privateStage.map { $0.appendingPathComponent(node.relative, isDirectory: node.directory) }
                    let mark = try nodeURL.map { try OSManagedQuarantineCandidate.prepareReceivedTreeNode(output, at: $0) }
                    if !node.directory {
                        guard let size = node.size, let expectedHash = record.sha256 else { throw FileOperationFailure.sourceChanged }
                        var offset: UInt64 = 0, hash = SHA256()
                        while offset < size {
                            try check(); let count = Int(min(65_536, size - offset)); var data = Data(count: count)
                            let found = data.withUnsafeMutableBytes { pread(payload, $0.baseAddress, count, off_t(record.offset + offset)) }
                            if found < 0, errno == EINTR { continue }
                            guard found == count else { throw FileOperationFailure.sourceChanged }
                            try data.withUnsafeBytes { buffer in
                                var at = 0
                                while at < count {
                                    try check(); let written = pwrite(output, buffer.baseAddress!.advanced(by: at), count - at, off_t(offset) + off_t(at))
                                    if written < 0, errno == EINTR { continue }
                                    guard written > 0 else { throw Self.failure(written == 0 ? EIO : errno) }; at += written
                                }
                            }
                            hash.update(data: data); offset += UInt64(found); progress(UInt64(found), 0)
                        }
                        guard Data(hash.finalize()) == expectedHash else { throw FileOperationFailure.copyContentMismatch }
                    }
                    guard fchmod(output, node.directory ? 0o755 : 0o644) == 0 else { throw Self.failure(errno) }
                    try security?.apply(to: output)
                    if let nodeURL { try mark?.require(output, at: nodeURL) }
                    guard try DownloadDisk.identity(output) == identity else { throw FileOperationFailure.destinationChanged }
                    progress(0, 1); return identity
                }
                identities[DownloadTreeManifest.pathKey(parts)] = created
            }
            // Directory ctimes change while children are created. Capture all
            // final receipts after construction, retaining every created ID.
            return try manifest.nodes.map { record in
                try withNode(directory, parts: record.node.components, identities: identities,
                    directory: record.node.directory, check: check) { descriptor in
                    var s = stat(); guard fstat(descriptor, &s) == 0, s.st_uid == geteuid(),
                          s.st_mode & S_IFMT == (record.node.directory ? S_IFDIR : S_IFREG),
                          record.node.directory || s.st_nlink == 1 else { throw FileOperationFailure.destinationChanged }
                    if let privateStage {
                        let nodeURL = record.node.relative.isEmpty ? privateStage
                            : privateStage.appendingPathComponent(record.node.relative, isDirectory: record.node.directory)
                        _ = try OSManagedQuarantineCandidate.observeMarkedSource(descriptor, at: nodeURL)
                    }
                    return .init(relative: record.node.relative, device: s.st_dev, inode: s.st_ino, kind: s.st_mode & S_IFMT,
                        birthSeconds: s.st_birthtimespec.tv_sec, birthNanoseconds: s.st_birthtimespec.tv_nsec,
                        changedSeconds: s.st_ctimespec.tv_sec, changedNanoseconds: s.st_ctimespec.tv_nsec,
                        size: s.st_size, contentSHA256: record.sha256)
                }
            }
        }
    }
    private func withNode<T>(_ root: Int32, parts: [Data], identities: [Data: DownloadDisk.Identity], directory: Bool,
        check: @Sendable () throws -> Void, body: (Int32) throws -> T) throws -> T {
        var held = dup(root)
        guard held >= 0 else { throw Self.failure(errno) }; defer { close(held) }
        guard try DownloadDisk.identity(held) == identities[Data()] else { throw FileOperationFailure.destinationChanged }
        for (index, part) in parts.enumerated() {
            try check()
            let options = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (index < parts.count - 1 || directory ? O_DIRECTORY : 0)
            let next = openat(held, String(decoding: part, as: UTF8.self), options)
            guard next >= 0 else { throw Self.failure(errno) }
            close(held); held = next
            guard try DownloadDisk.identity(held) == identities[DownloadTreeManifest.pathKey(Array(parts.prefix(index + 1)))] else {
                throw FileOperationFailure.destinationChanged
            }
        }
        try check(); return try body(held)
    }
    func finished() { source.release() }
    private static func failure(_ code: Int32) -> FileOperationFailure {
        switch code { case ENOSPC: .outOfSpace; case EDQUOT: .quotaExceeded; case EACCES, EPERM: .accessDenied
        case EEXIST: .conflict; case ENOENT: .notFound; default: .ioFailure }
    }
}

extension RemoteDownloadedTree {
    func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection,
        publicQuarantineTreeV16: Bool = false) async throws -> ReceivedDirectoryPlan {
        try await operations.prepareReceivedDirectory(parent: parent, name: name, observing: destination,
            publicQuarantineTreeV16: publicQuarantineTreeV16) { [self] check in
            try check(); return try DownloadedDirectoryProducer(self, publicQuarantineTreeV16: publicQuarantineTreeV16)
        }
    }
}

@_spi(Qualification) public final class SFTPReceivedFolderDownload: Sendable {
    private let tree: RemoteDownloadedTree
    public var id: UUID { tree.id }
    public var logicalBytes: UInt64 { tree.manifest.logicalBytes }
    init(_ tree: RemoteDownloadedTree) { self.tree = tree }
    public func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection,
        publicQuarantineTreeV16: Bool = false) async throws -> ReceivedDirectoryPlan {
        try await tree.preparePublication(using: operations, parent: parent, name: name,
            observing: destination, publicQuarantineTreeV16: publicQuarantineTreeV16)
    }
    public func finishPublication(_ result: RecoverableOperationResult) async -> Bool {
        if result.recordID != nil, result.result.disposition == .succeeded {
            do { try await tree.removeAfterDrain(); return true } catch {}
        }
        await tree.abandon(); return false
    }
    public func retainForReview() async { await tree.abandon() }
}
