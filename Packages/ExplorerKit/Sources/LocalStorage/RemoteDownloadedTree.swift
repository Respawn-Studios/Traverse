import CryptoKit
import Foundation

/// One tree and one spool share the existing pool. No member can publish or
/// claim its own child lease. Serial events are validated before a body append.
final class RemoteDownloadedTree: @unchecked Sendable {
    private let source: DownloadTreeSource
    let manifest: DownloadTreeManifest
    var request: UUID { source.request }
    func matches(_ value: SFTPPreparedFolderDownload) -> Bool { source.matches(value) }
    func matches(_ value: SMBPreparedFolderDownload) -> Bool { source.matches(value) }
    private let spool: RemoteDownloadSpool, state = NSLock()
    private var hashes: [Data?], next = 0, current: Int?, memberBytes: UInt64 = 0, totalBytes: UInt64 = 0
    private var hash = SHA256(), failed = false, finishing = false
    private var sealed: DownloadTreeManifest.Sealed?
    var id: UUID { spool.id }
    var receivedBytes: UInt64 { state.withLock { totalBytes } }
    init(directory: URL, source: DownloadTreeSource, hooks: DownloadIOHooks) throws {
        self.source = source; manifest = try source.localManifest(); hashes = Array(repeating: nil, count: manifest.nodes.count)
        spool = try .init(directory: directory, request: source.request, expectedBytes: manifest.logicalBytes, tree: true, hooks: hooks)
    }
    func beginMember(request: UUID, ordinal: Int) throws {
        try state.withLock {
            do {
                while next < manifest.nodes.count, manifest.nodes[next].directory { next += 1 }
                guard !failed, !finishing, current == nil, request == self.request,
                      ordinal == next, ordinal < manifest.nodes.count else { throw RemoteDownloadStorageFailure.changed }
                current = ordinal; memberBytes = 0; hash = SHA256()
            } catch { failed = true; throw error }
        }
    }
    func appendOnSessionExecutor(request: UUID, ordinal: Int, offset: UInt64, bytes: Data) throws {
        try state.withLock {
            do {
                guard !failed, !finishing, current == ordinal, request == self.request,
                      offset == memberBytes, let size = manifest.nodes[ordinal].size,
                      memberBytes <= size, UInt64(bytes.count) <= size - memberBytes else { throw RemoteDownloadStorageFailure.changed }
                try spool.appendOnSessionExecutor(request: request, offset: totalBytes, bytes: bytes)
                hash.update(data: bytes); memberBytes += UInt64(bytes.count); totalBytes += UInt64(bytes.count)
            } catch { failed = true; throw error }
        }
    }
    func endMember(request: UUID, ordinal: Int, receivedBytes: UInt64) throws {
        try state.withLock {
            do {
                guard !failed, !finishing, request == self.request, current == ordinal,
                      receivedBytes == memberBytes, memberBytes == manifest.nodes[ordinal].size else {
                    throw RemoteDownloadStorageFailure.incomplete
                }
                hashes[ordinal] = Data(hash.finalize()); current = nil; next += 1
            } catch { failed = true; throw error }
        }
    }
    func seal(request: UUID, receivedBytes: UInt64, receivedFiles: Int) async throws {
        let value = try state.withLock {
            guard !failed, !finishing, current == nil, request == self.request,
                  receivedBytes == totalBytes, receivedBytes == manifest.logicalBytes,
                  receivedFiles == manifest.files else { throw RemoteDownloadStorageFailure.incomplete }
            finishing = true
            return try manifest.sealed(hashes: hashes)
        }
        do {
            _ = try await spool.seal(request: request, receivedBytes: receivedBytes, manifest: value.1)
            state.withLock { sealed = value.0 }
        } catch { state.withLock { failed = true }; throw error }
    }
    func claimPublicationOnWorker() throws -> (DownloadPublicationLease, DownloadTreeManifest.Sealed) {
        try state.withLock {
            guard !failed, let sealed else { throw RemoteDownloadStorageFailure.incomplete }
            return (try spool.claimPublicationOnWorker(), sealed)
        }
    }
    @discardableResult func abandon() async -> Bool { await spool.abandon() }
    func removeAfterDrain() async throws { try await spool.removeAfterDrain() }
}

extension RemoteDownloadStore {
    func reserveTree(_ prepared: SFTPPreparedFolderDownload) async throws -> RemoteDownloadedTree {
        let tree = try await executor.perform { [directory, hooks] in try RemoteDownloadedTree(directory: directory, source: .sftp(prepared), hooks: hooks) }
        if Task.isCancelled { await tree.abandon(); throw CancellationError() }; return tree
    }
}

extension RemoteDownloadStore {
    func reserveTree(_ prepared: SMBPreparedFolderDownload) async throws -> RemoteDownloadedTree {
        let tree = try await executor.perform { [directory, hooks] in try RemoteDownloadedTree(directory: directory, source: .smb(prepared), hooks: hooks) }
        if Task.isCancelled { await tree.abandon(); throw CancellationError() }; return tree
    }
}
