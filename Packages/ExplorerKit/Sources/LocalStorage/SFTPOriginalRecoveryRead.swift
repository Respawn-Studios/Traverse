import CryptoKit
import Darwin
import Foundation
import FileOperations

/// Explicit local recovery read only. Startup loads the journal's metadata;
/// this constructor is never invoked by browse, search or automatic restore.
/// It opens only an exact journal-minted ID inside the dedicated checked pool.
final class SFTPOriginalRecoveryRead: @unchecked Sendable, CustomDebugStringConvertible {
    private let directory: URL, reference: SFTPOriginalSpoolReference
    private let executor = DownloadExecutor(), cancelled = UploadCancellation(), state = NSLock()
    private var released = false
    private let pool: Int32, folder: Int32, payload: Int32
    private let lease: DownloadDisk.SharedOriginalLease
    private let record: DownloadDisk.Record, stamp: DownloadDisk.Stamp
    var debugDescription: String { "<checked SFTP original recovery read>" }
    private init(directory: URL, reference: SFTPOriginalSpoolReference, authority: SFTPInPlaceRecoveryBodyAuthority? = nil) throws {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }; try reference.validate()
        guard let pool = try SMBCatalogFiles.openPool(directory, create: false) else { throw SFTPTextFailure.unavailable }
        var held = [pool], keep = false
        defer { if !keep { held.forEach { Darwin.close($0) } } }
        let poolLock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(poolLock) }
        try SMBCatalogFiles.validatePool(pool, at: directory)
        let budget = try SFTPSharedBudgetTransaction.readFence(pool, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1")
        // Ordinary reads refuse a partially retired pool. Only explicit
        // Remove/Resume owns the bounded partial-inventory authority.
        let inventory = try DownloadDisk.inventory(pool, originalBudgetID: budget)
        guard try DownloadDisk.activeOriginalPayloadReaders(pool, records: inventory) < 2 else { throw SFTPTextFailure.busy }
        let name = "download-" + reference.id.uuidString
        let before = try DownloadDisk.record(pool, name: name)
        guard !before.summary.isFolder, before.summary.expectedBytes == reference.logicalBytes else { throw SFTPTextFailure.busy }
        let folder = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard folder >= 0 else { throw SFTPTextFailure.changed }; held.append(folder)
        guard let leaseIdentity = before.files["owner.lock"] else { throw SFTPTextFailure.changed }
        let lease = try DownloadDisk.SharedOriginalLease.acquire(folder: folder, expected: leaseIdentity)
        defer { if !keep { _ = lease.closeAfterDrain() } }
        let actual = try DownloadDisk.record(pool, name: name, heldReadLease: lease)
        try authority?.validate(record: actual, reference: reference)
        guard actual.folder == before.folder, actual.marker == before.marker, actual.files == before.files,
              try DownloadDisk.identity(folder) == actual.folder else { throw SFTPTextFailure.changed }
        let payload = openat(folder, "payload", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard payload >= 0 else { throw SFTPTextFailure.changed }; held.append(payload)
        guard flock(payload, LOCK_EX | LOCK_NB) == 0 else { throw SFTPTextFailure.busy }
        var value = stat()
        guard fstat(payload, &value) == 0, DownloadDisk.privateFile(value), value.st_size == Int64(reference.logicalBytes),
              try DownloadDisk.identity(payload) == actual.files["payload"] else { throw SFTPTextFailure.changed }
        self.directory = directory; self.reference = reference; self.pool = pool; self.folder = folder
        self.lease = lease; self.payload = payload; self.record = actual; stamp = try DownloadDisk.stamp(payload); keep = true
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.bodyReaderOpened(directory: directory)
        #endif
    }
    static func open(directory: URL, reference: SFTPOriginalSpoolReference) async throws -> SFTPOriginalRecoveryRead {
        try await DownloadExecutor().perform { try .init(directory: directory, reference: reference) }
    }
    static func openForInPlaceRecovery(directory: URL, reference: SFTPOriginalSpoolReference, authority: SFTPInPlaceRecoveryBodyAuthority) async throws -> SFTPOriginalRecoveryRead {
        try await DownloadExecutor().perform { try .init(directory: directory, reference: reference, authority: authority) }
    }
    private func validate() throws {
        guard !released, !cancelled.cancelled else { throw SFTPTextFailure.closed }
        try SMBCatalogFiles.validatePool(pool, at: directory)
        let actual = try DownloadDisk.record(pool, name: record.name, heldReadLease: lease)
        var value = stat()
        guard actual.folder == record.folder, actual.marker == record.marker, actual.files == record.files,
              try DownloadDisk.identity(folder) == record.folder, fstat(payload, &value) == 0,
              try DownloadDisk.stamp(payload) == stamp else { throw SFTPTextFailure.changed }
    }
    func validateOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        try state.withLock { try validate() }
    }
    func read() async throws -> TextDocumentValue {
        try await withTaskCancellationHandler {
            try await executor.perform { [self] in try state.withLock {
                #if DEBUG && !SFTP_PARENT_STANDALONE
                SFTPGeneratedBackendObservation.shared.bodyRead(directory: directory)
                #endif
                #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
                try GateBReadObservation.shared.enter(directory: directory)
                #endif
                try validate(); var bytes = Data(count: Int(reference.logicalBytes)), offset = 0
                while offset < bytes.count {
                    try validate(); let count = min(32768, bytes.count - offset)
                    let found = bytes.withUnsafeMutableBytes { pread(payload, $0.baseAddress!.advanced(by: offset), count, off_t(offset)) }
                    if found < 0 && errno == EINTR { continue }
                    guard found == count else { throw SFTPTextFailure.changed }; offset += found
                }
                try validate(); guard Data(SHA256.hash(data: bytes)) == reference.digest else { throw SFTPTextFailure.changed }
                return try TextDocumentValue.original(bytes)
            } }
        } onCancel: { self.cancelled.cancel() }
    }
    func closeAndDrain() async {
        cancelled.cancel()
        await executor.drain { [self] in state.withLock {
            guard !released else { return }
            guard lease.closeAfterDrain() else { return }
            released = true; [payload, folder, pool].forEach { Darwin.close($0) }
            #if DEBUG && !SFTP_PARENT_STANDALONE
            SFTPGeneratedBackendObservation.shared.bodyReaderDrained(directory: directory)
            #endif
        } }
    }
    deinit {
        let descriptors = state.withLock { released ? [] : [payload, folder, pool] }
        if !descriptors.isEmpty { let held = lease; DispatchQueue.global(qos: .utility).async { descriptors.forEach { Darwin.close($0) }; _ = held.closeAfterDrain() } }
    }
}
