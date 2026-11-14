import CryptoKit
import FileOperations
import Foundation
import Darwin

/// Concrete SMB receipt binding around the shared spool. It cannot reinterpret
/// an SFTP selection or create a second body-storage budget.
final class SMBDownloadedFile: Sendable {
    let selection: SMBDownloadSelection
    private let spool: RemoteDownloadSpool
    var id: UUID { spool.id }
    init(directory: URL, selection: SMBDownloadSelection, hooks: DownloadIOHooks,
         batchAdmission: Bool = false, batchAllocation: BatchDownloadAllocationFence? = nil,
         publicQuarantineCandidate: Bool = false) throws {
        self.selection = selection
        spool = try .init(directory: directory, request: selection.request, expectedBytes: selection.logicalBytes,
            tree: false, hooks: hooks, batchAdmission: batchAdmission, batchAllocation: batchAllocation,
            publicQuarantineCandidate: publicQuarantineCandidate)
    }
    func appendOnSessionExecutor(request: UUID, offset: UInt64, bytes: Data) throws {
        try spool.appendOnSessionExecutor(request: request, offset: offset, bytes: bytes)
    }
    func append(request: UUID, offset: UInt64, bytes: Data) async throws { try await spool.append(request: request, offset: offset, bytes: bytes) }
    func seal(_ receipt: SMBDownloadReceipt) async throws -> Data {
        guard receipt.selection == selection else { throw RemoteDownloadStorageFailure.changed }
        return try await spool.seal(request: selection.request, receivedBytes: receipt.receivedBytes)
    }
    func verifiedSource() async throws -> URL { try await spool.verifiedSource() }
    @discardableResult func abandon() async -> Bool { await spool.abandon() }
    func adoptionShellRetired(for job: UUID?) -> Bool { spool.adoptionShellRetired(for: job) }
    func claimPublicationOnWorker() throws -> DownloadPublicationLease { try spool.claimPublicationOnWorker() }
    func claimPublicQuarantinePublicationOnWorker() throws -> DownloadPublicationLease {
        try spool.claimPublicationOnWorker(publicQuarantineV1: true)
    }
    func removeAfterDrain() async throws { try await spool.removeAfterDrain() }
}

@_spi(Qualification) public enum SMBTextFailure: String, Error, Sendable {
    case unsupported, changed, closed, busy, stopped, unavailable, full, reviewRequired
    init(_ issue: RemoteDownloadStorageFailure) {
        switch issue {
        case .capacity, .io(ENOSPC), .io(EDQUOT): self = .full
        case .changed, .unsafe: self = .changed
        case .busy: self = .busy
        default: self = .unavailable
        }
    }
}

/// Uses the existing received-body pool without granting binary publication.
@_spi(Qualification) public final class SMBTextReadStorage: Sendable {
    let downloads: SMBDownloadStorage
    public init(sharing downloads: SMBDownloadStorage) { self.downloads = downloads }
}

@_spi(Qualification) public enum SMBTextReadCloseOutcome: Sendable, Equatable {
    case removed
    case retainedForReview(UUID)
}

/// The worker completed selected-file postcheck and CLOSE before local sealing.
/// This is a viewing receipt, not a remote Save baseline or write token.
@_spi(Qualification) public struct SMBTextReadReceipt: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: SMBDownloadSelection
    public let receivedBytes: UInt64
    let digest: Data
    let sourceSnapshot: SMBRemoteFileSnapshot?
    public var description: String { "<checked SMB text receipt>" }
    public var debugDescription: String { description }
    init(_ checked: SMBDownloadReceipt, digest: Data) throws {
        guard checked.receivedBytes == checked.selection.logicalBytes,
              checked.receivedBytes <= UInt64(TextDocumentValue.maximumBytes), digest.count == 32 else {
            throw SMBTextFailure.changed
        }
        selection = checked.selection; receivedBytes = checked.receivedBytes; self.digest = digest
        sourceSnapshot = checked.sourceSnapshot
    }
}

/// A private bounded UTF-8 view. No URL, descriptor, Save, or publication API escapes.
@_spi(Qualification) public final class SMBTextReadLease: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let receipt: SMBTextReadReceipt
    private let file: SMBDownloadedFile, source: DownloadPublicationLease
    private let executor = DownloadExecutor(), state = NSLock(), closeLock = NSLock(), cancellation = UploadCancellation()
    private var closed = false
    private var closing: Task<SMBTextReadCloseOutcome, Never>?
    public var description: String { "<checked SMB text lease>" }
    public var debugDescription: String { description }
    private init(file: SMBDownloadedFile, source: DownloadPublicationLease, receipt: SMBTextReadReceipt) {
        self.file = file; self.source = source; self.receipt = receipt
    }
    static func mint(_ file: SMBDownloadedFile, checked: SMBDownloadReceipt, digest: Data) async throws -> SMBTextReadLease {
        guard file.selection == checked.selection else { throw SMBTextFailure.changed }
        let receipt = try SMBTextReadReceipt(checked, digest: digest)
        return try await DownloadExecutor().perform {
            let source = try file.claimPublicationOnWorker()
            guard source.logicalBytes == receipt.receivedBytes, source.digest == receipt.digest else {
                source.release(); throw SMBTextFailure.changed
            }
            return .init(file: file, source: source, receipt: receipt)
        }
    }
    public func read() async throws -> TextDocumentValue {
        do { return try await withTaskCancellationHandler {
            let value = try await executor.perform { [self] in
                try state.withLock {
                    guard !closed else { throw SMBTextFailure.closed }
                    try check()
                    let value = try source.withSource(check: { try self.check() }) { descriptor, _ in
                        guard source.logicalBytes == receipt.receivedBytes else { throw SMBTextFailure.changed }
                        var data = Data(count: Int(source.logicalBytes)), offset = 0
                        while offset < data.count {
                            try check()
                            let count = min(32768, data.count - offset)
                            let found = data.withUnsafeMutableBytes {
                                pread(descriptor, $0.baseAddress!.advanced(by: offset), count, off_t(offset))
                            }
                            if found < 0 && errno == EINTR { continue }
                            guard found == count else { throw SMBTextFailure.changed }
                            offset += found
                        }
                        guard Data(SHA256.hash(data: data)) == receipt.digest else { throw SMBTextFailure.changed }
                        try check(); return try TextDocumentValue.original(data)
                    }
                    try check(); return value
                }
            }
            try check(); return value
        } onCancel: { self.cancellation.cancel() }
        } catch let issue as RemoteDownloadStorageFailure { throw SMBTextFailure(issue) }
        catch is CancellationError { throw SMBTextFailure.stopped }
    }
    private func check() throws { if cancellation.cancelled { throw SMBTextFailure.stopped } }
    public func closeAndDrain() async { _ = await closeForViewer() }
    public func closeForViewer() async -> SMBTextReadCloseOutcome {
        let task = closeLock.withLock { () -> Task<SMBTextReadCloseOutcome, Never> in
            if let closing { return closing }
            let task = Task<SMBTextReadCloseOutcome, Never> { [self] in
                cancellation.cancel()
                await executor.drain { [self] in state.withLock { closed = true; source.release() } }
                do { try await file.removeAfterDrain(); return .removed }
                catch { _ = await file.abandon(); return .retainedForReview(file.id) }
            }
            closing = task; return task
        }
        return await task.value
    }
    deinit { source.release() }
}

extension RemoteDownloadStore {
    func reserve(_ selection: SMBDownloadSelection) async throws -> SMBDownloadedFile {
        let file = try await executor.perform { [directory, hooks] in try SMBDownloadedFile(directory: directory, selection: selection, hooks: hooks) }
        if Task.isCancelled { await file.abandon(); throw CancellationError() }; return file
    }
    func reservePublicQuarantineCandidate(_ selection: SMBDownloadSelection) async throws -> SMBDownloadedFile {
        let file = try await executor.perform { [directory, hooks] in
            try SMBDownloadedFile(directory: directory, selection: selection, hooks: hooks,
                publicQuarantineCandidate: true)
        }
        if Task.isCancelled { await file.abandon(); throw CancellationError() }; return file
    }

    /// One SMB group owns all spools before its first worker PREPARE. Shared
    /// spool admission rechecks the unchanged 64-record/2GiB+128KiB budget
    /// and holds each exact-owned lock throughout reception/publication.
    func reserveBatch(_ plan: SMBDownloadBatchPlan,
                      publicQuarantineV1: Bool = false) async throws -> [SMBDownloadedFile] {
        var files: [SMBDownloadedFile] = [], failedAllocation: UUID?
        do {
            try Task.checkCancellation()
            try await executor.perform { [directory] in
                let records: [DownloadDisk.Record]
                if let pool = try SMBCatalogFiles.openPool(directory, create: false) {
                    defer { close(pool) }
                    let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(lock) }
                    try SMBCatalogFiles.validatePool(pool, at: directory)
                    records = try DownloadDisk.inventory(pool)
                } else { records = [] }
                guard records.count <= 64 - plan.items.count,
                      records.filter(\.summary.active).count <= 16 - plan.items.count else {
                    throw RemoteDownloadStorageFailure.capacity
                }
                var reserved: UInt64 = 0
                for item in plan.items {
                    let bytes = try DownloadDisk.reservation(expectedBytes: item.selection.logicalBytes, tree: false)
                    guard bytes <= Self.maximumPoolBytes - reserved else { throw RemoteDownloadStorageFailure.capacity }
                    reserved += bytes
                }
                let charged = try DownloadDisk.admissionCharge(records)
                guard charged <= Self.maximumPoolBytes - reserved else { throw RemoteDownloadStorageFailure.capacity }
            }
            for item in plan.items {
                try Task.checkCancellation()
                let fence = BatchDownloadAllocationFence()
                let file: SMBDownloadedFile
                do {
                    file = try await executor.perform { [directory, hooks] in
                        try SMBDownloadedFile(directory: directory, selection: item.selection, hooks: hooks,
                                              batchAdmission: true, batchAllocation: fence,
                                              publicQuarantineCandidate: publicQuarantineV1)
                    }
                } catch {
                    failedAllocation = fence.retainedID
                    throw error
                }
                files.append(file)
            }
            try Task.checkCancellation()
            return files
        } catch {
            for file in files { _ = await file.abandon() }
            throw RemoteDownloadBatchReservationFailure(cause: error,
                retainedFileIDs: files.map(\.id) + [failedAllocation].compactMap { $0 })
        }
    }
}
