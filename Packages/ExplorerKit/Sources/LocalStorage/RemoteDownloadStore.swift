import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

enum RemoteDownloadStorageFailure: Error, Equatable { case unsafe, changed, unavailable, capacity, busy, incomplete, io(Int32) }
struct RemoteDownloadBatchReservationFailure: Error, Sendable {
    let cause: any Error
    let retainedFileIDs: [UUID]
}
struct DownloadIOHooks: Sendable {
    var failWriteAfterBytes: UInt64?
    var failSync = false
    #if DEBUG
    var failBatchAfterMetadataSync: (@Sendable (UUID) throws -> Void)?
    #endif
}

/// The constructor may throw after creating its private directory. Preserve
/// that exact ID for review unless a checked removal completed under pool lock.
final class BatchDownloadAllocationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var createdID: UUID?
    var retainedID: UUID? { lock.withLock { createdID } }
    func created(_ id: UUID) { lock.withLock { createdID = id } }
    func removed(_ id: UUID) { lock.withLock { if createdID == id { createdID = nil } } }
}

/// Monotonic evidence shared with one Original header. A constructor may throw
/// after namespace creation, so its missing return value is not a no-body proof.
/// Ordinary downloads/uploads do not supply this internal fence.
final class OriginalHeaderAllocationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var possibleCreation = false
    var mayHaveCreatedSpool: Bool { lock.withLock { possibleCreation } }
    func beforeMkdir() { lock.withLock { possibleCreation = true } }
    #if DEBUG
    private var postMkdirFault: (@Sendable () throws -> Void)?
    func setPostMkdirFaultForQualification(_ fault: @escaping @Sendable () throws -> Void) throws {
        try lock.withLock {
            guard !possibleCreation, postMkdirFault == nil else { throw RemoteDownloadStorageFailure.busy }
            postMkdirFault = fault
        }
    }
    func afterMetadataSyncForQualification() throws {
        let fault = lock.withLock { postMkdirFault }; try fault?()
    }
    #endif
}

/// Concrete body store, not an index/provider. Every filesystem operation runs
/// on its private executor; construction and passive inspection create nothing.
final class RemoteDownloadStore: Sendable {
    static let maximumFileBytes: UInt64 = 1 << 30
    static let maximumPoolBytes: UInt64 = (2 << 30) + (128 << 10)
    let directory: URL
    let executor = DownloadExecutor()
    let hooks: DownloadIOHooks
    init(directory: URL, hooks: DownloadIOHooks = .init()) throws {
        guard directory.isFileURL, directory.host == nil || directory.host == "", directory.query == nil,
              directory.fragment == nil, directory == directory.standardizedFileURL else { throw RemoteDownloadStorageFailure.unsafe }
        self.directory = directory; self.hooks = hooks
    }
    func inspect() async throws -> [RemoteDownloadSummary] {
        try await executor.perform { [directory] in
            guard let pool = try SMBCatalogFiles.openPool(directory, create: false) else { return [] }
            defer { close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(lock) }
            try SMBCatalogFiles.validatePool(pool, at: directory)
            return try DownloadDisk.inventory(pool).map(\.summary)
        }
    }
    func reserve(_ selection: SFTPDownloadSelection) async throws -> RemoteDownloadedFile {
        let file = try await executor.perform { [directory, hooks] in try RemoteDownloadedFile(directory: directory, selection: selection, hooks: hooks) }
        if Task.isCancelled { await file.abandon(); throw CancellationError() }; return file
    }
    /// Source-only v14 candidate. Single-file and selected-group admission
    /// remain separate even when they use the same sealed v4 file profile.
    func reservePublicQuarantineCandidate(_ selection: SFTPDownloadSelection) async throws -> RemoteDownloadedFile {
        let file = try await executor.perform { [directory, hooks] in
            try RemoteDownloadedFile(directory: directory, selection: selection, hooks: hooks,
                publicQuarantineCandidate: true)
        }
        if Task.isCancelled { await file.abandon(); throw CancellationError() }; return file
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    /// Reserve every selected file before any network body. The ordinary
    /// two-active limit stays intact; only this sealed 2–16 file group may
    /// hold up to sixteen owned locks under the unchanged total pool budget.
    func reserveBatch(_ plan: SFTPDownloadBatchPlan,
                      requireCurrent: @Sendable () async throws -> Void,
                      publicQuarantineV1: Bool = false) async throws -> [RemoteDownloadedFile] {
        var files: [RemoteDownloadedFile] = []
        var failedAllocation: UUID?
        do {
            try await requireCurrent()
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
                try await requireCurrent(); try Task.checkCancellation()
                let fence = BatchDownloadAllocationFence()
                let file: RemoteDownloadedFile
                do {
                    file = try await executor.perform { [directory, hooks] in
                        try RemoteDownloadedFile(directory: directory, selection: item.selection, hooks: hooks,
                                                 batchAdmission: true, batchAllocation: fence,
                                                 publicQuarantineCandidate: publicQuarantineV1)
                    }
                } catch {
                    failedAllocation = fence.retainedID
                    throw error
                }
                files.append(file)
            }
            try await requireCurrent(); try Task.checkCancellation()
            return files
        } catch {
            for file in files { _ = await file.abandon() }
            throw RemoteDownloadBatchReservationFailure(cause: error,
                retainedFileIDs: files.map(\.id) + [failedAllocation].compactMap { $0 })
        }
    }
    #endif
    /// Explicit inactive-store discard only; no SQLite, recursion or body read.
    func discardIncomplete(_ id: UUID) async throws {
        try await executor.perform { [directory] in
            guard let pool = try SMBCatalogFiles.openPool(directory, create: false) else { return }
            defer { close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(lock) }
            try SMBCatalogFiles.validatePool(pool, at: directory)
            guard let record = try DownloadDisk.inventory(pool).first(where: { $0.summary.id == id }) else { throw RemoteDownloadStorageFailure.changed }
            guard !record.summary.active, record.adoption == nil else { throw RemoteDownloadStorageFailure.busy }
            try DownloadDisk.remove(pool, record: record)
        }
    }
    /// Original catalog holds its own graph executor through this exact-owned
    /// removal. No generic URL admission, MainActor I/O or nested async queue.
    func discardIncompleteOnOriginalExecutor(_ id: UUID, owner: SFTPOriginalStorageOwner,
                                             readProof: SFTPOriginalUnadmittedReadProof) throws {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        guard directory == owner.layout.bodies else { throw SFTPSharedBudgetFailure.unsafe }
        let budget = try SFTPSharedBudgetTransaction.open(layout: owner.layout, writing: true)
        defer { budget.close() }
        guard budget.document.budgetID == owner.budgetID else { throw SFTPSharedBudgetFailure.stale }
        try budget.removeOriginalBody(id, readProof: readProof)
    }
}

struct RemoteDownloadSummary: Sendable, Equatable {
    let id: UUID, expectedBytes: UInt64, observedBytes: UInt64, active: Bool
    let isFolder: Bool
    /// A durable adoption intent blocks ordinary discard even after the owner
    /// lease drains. This is pool metadata, not a body or journal inspection.
    let publicationProtected: Bool
}

final class DownloadExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.Download.Storage", qos: .utility), lock = NSLock()
    private var pending = 0
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); guard pending < 4 else { lock.unlock(); continuation.resume(throwing: RemoteDownloadStorageFailure.busy); return }
            pending += 1
            queue.async { [self] in
                let result = Result { try work() }; lock.withLock { pending -= 1 }; continuation.resume(with: result)
            }
            lock.unlock()
        }
    }
    func drain(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in queue.async { work(); continuation.resume() } }
    }
}

/// Explicit regular-file source, using the shared bounded spool mechanics.
final class RemoteDownloadedFile: Sendable {
    let selection: SFTPDownloadSelection
    private let spool: RemoteDownloadSpool
    var id: UUID { spool.id }
    init(directory: URL, selection: SFTPDownloadSelection, hooks: DownloadIOHooks, originalText: Bool = false,
         originalHeaderAllocation: OriginalHeaderAllocationFence? = nil, originalOwner: SFTPOriginalStorageOwner? = nil,
         batchAdmission: Bool = false, batchAllocation: BatchDownloadAllocationFence? = nil,
         publicQuarantineCandidate: Bool = false) throws {
        self.selection = selection
        spool = try .init(directory: directory, request: selection.request, expectedBytes: selection.logicalBytes, tree: false,
            hooks: hooks, originalText: originalText, originalHeaderAllocation: originalHeaderAllocation,
            originalOwner: originalOwner, batchAdmission: batchAdmission, batchAllocation: batchAllocation,
            publicQuarantineCandidate: publicQuarantineCandidate)
    }
    func append(request: UUID, offset: UInt64, bytes: Data) async throws { try await spool.append(request: request, offset: offset, bytes: bytes) }
    func appendOnSessionExecutor(request: UUID, offset: UInt64, bytes: Data) throws {
        try spool.appendOnSessionExecutor(request: request, offset: offset, bytes: bytes)
    }
    func seal(_ receipt: SFTPDownloadReceipt) async throws -> Data {
        guard receipt.selection == selection else { throw RemoteDownloadStorageFailure.changed }
        return try await spool.seal(request: selection.request, receivedBytes: receipt.receivedBytes)
    }
    func verifiedSource() async throws -> URL { try await spool.verifiedSource() }
    func hasExpectedV7NativeMark() async throws -> Bool { try await spool.hasExpectedV7NativeMark() }
    @discardableResult func abandon() async -> Bool { await spool.abandon() }
    func adoptionShellRetired(for job: UUID?) -> Bool { spool.adoptionShellRetired(for: job) }
    func claimPublicationOnWorker() throws -> DownloadPublicationLease { try spool.claimPublicationOnWorker() }
    func claimPublicQuarantinePublicationOnWorker() throws -> DownloadPublicationLease {
        try spool.claimPublicationOnWorker(publicQuarantineV1: true)
    }
    func removeAfterDrain(originalReadProof: SFTPOriginalUnadmittedReadProof? = nil) async throws {
        try await spool.removeAfterDrain(originalReadProof: originalReadProof)
    }
}

/// One retained writer. No raw descriptor/path escapes to a view. Failure keeps
/// its lease until the network owner explicitly drains and abandons the file.
final class RemoteDownloadSpool: @unchecked Sendable {
    let id: UUID, request: UUID, expectedBytes: UInt64
    private let tree: Bool
    private let adoptionEligible: Bool
    private let publicQuarantineCandidate: Bool
    private let root: URL, folderName: String, folderIdentity: DownloadDisk.Identity
    private let markerIdentity: DownloadDisk.Identity, markerBytes: Data
    private let pool: Int32, folder: Int32, payload: Int32, lease: Int32
    private enum QuarantineWitness: Sendable {
        case legacy(DownloadedFileQuarantine.Witness)
        case publicCandidate(OSManagedQuarantineCandidate.Witness)
        func require(_ descriptor: Int32, at url: URL) throws {
            switch self {
            case .legacy(let witness): try witness.validate(descriptor)
            case .publicCandidate(let witness): try witness.require(descriptor, at: url)
            }
        }
    }
    private let quarantine: QuarantineWitness
    private let hooks: DownloadIOHooks
    private let executor = DownloadExecutor(), state = NSLock()
    private let originalAllocation: SFTPOriginalBodyAllocation?
    private var released = false, failed = false, sealed = false, written: UInt64 = 0
    private var hash = SHA256(), sealedHash: Data?
    private var sealedStamp: DownloadDisk.Stamp?, manifestStamp: DownloadDisk.Stamp?
    private var publicationUsers = 0, abandonRequested = false
    private var adoptionMarker: DownloadAdoptionMarker?, transferred = false, retiredAdoptionJob: UUID?
    func adoptionShellRetired(for job: UUID?) -> Bool {
        state.withLock { job != nil && retiredAdoptionJob == job && transferred && adoptionMarker == nil && released }
    }

    init(directory: URL, request: UUID, expectedBytes: UInt64, tree: Bool, hooks: DownloadIOHooks,
         editedText: Bool = false, originalText: Bool = false, originalHeaderAllocation: OriginalHeaderAllocationFence? = nil,
         originalOwner: SFTPOriginalStorageOwner? = nil, batchAdmission: Bool = false,
         batchAllocation: BatchDownloadAllocationFence? = nil,
         publicQuarantineCandidate: Bool = false) throws {
        root = directory; self.request = request; self.expectedBytes = expectedBytes; self.tree = tree; self.hooks = hooks
        self.publicQuarantineCandidate = publicQuarantineCandidate
        adoptionEligible = !publicQuarantineCandidate && !tree && !editedText && !originalText && !batchAdmission && originalOwner == nil
        // A selected group may reserve marked v4 files only with the existing
        // batch fence and bounds. Text, tree and original owners stay separate.
        guard !publicQuarantineCandidate || !tree && !editedText && !originalText
            && originalOwner == nil else { throw RemoteDownloadStorageFailure.unsafe }
        guard !batchAdmission || !tree && !editedText && !originalText && originalOwner == nil else {
            throw RemoteDownloadStorageFailure.unsafe
        }
        guard (batchAllocation != nil) == batchAdmission else { throw RemoteDownloadStorageFailure.unsafe }
        guard originalHeaderAllocation == nil || originalText && !editedText && !tree else { throw RemoteDownloadStorageFailure.unsafe }
        guard expectedBytes <= RemoteDownloadStore.maximumFileBytes else { throw RemoteDownloadStorageFailure.capacity }
        let creation: SFTPSharedBodyCreation?
        if originalText {
            guard let originalOwner, directory == originalOwner.layout.bodies, !tree, !editedText else { throw SFTPSharedBudgetFailure.unsafe }
            creation = try .init(owner: originalOwner, expectedBytes: expectedBytes)
        } else {
            guard originalOwner == nil else { throw SFTPSharedBudgetFailure.unsafe }; creation = nil
        }
        defer { creation?.closeAfterConstructor() }
        originalAllocation = creation?.allocation
        id = creation?.allocation.id ?? UUID(); folderName = "download-" + id.uuidString
        guard let pool = try SMBCatalogFiles.openPool(directory, create: true) else { throw RemoteDownloadStorageFailure.unavailable }
        var held = [pool], keep = false
        defer { if !keep { held.forEach { close($0) } } }
        let lock = try SMBCatalogFiles.lockPool(pool, create: true); defer { close(lock) }
        try SMBCatalogFiles.validatePool(pool, at: directory)
        let records = try DownloadDisk.inventory(pool, originalBudgetID: originalOwner?.budgetID)
        guard !(editedText && originalText) else { throw RemoteDownloadStorageFailure.capacity }
        if editedText || originalText {
            let bodySlots = creation?.transaction.document.format == 3 ? SFTPSharedBudgetDocument.expandedBodySlots : 8
            guard !tree, expectedBytes <= 1 << 20, records.count < (originalText ? bodySlots : 2),
                  records.allSatisfy({ !$0.summary.isFolder && $0.summary.expectedBytes <= 1 << 20 }) else {
                throw RemoteDownloadStorageFailure.capacity
            }
        }
        // In-place history retains the before and each verified edited body.
        // A later Save needs one more staged body while those pins remain live.
        // The versioned shared Original budget bounds retained bodies; the
        // active-spool limit below still bounds concurrent local body work.
        guard records.count < 64, records.filter(\.summary.active).count < (originalText ? 8 : batchAdmission ? 16 : 2) else {
            throw RemoteDownloadStorageFailure.capacity
        }
        let charged = try DownloadDisk.admissionCharge(records)
        let reservation = try DownloadDisk.reservation(expectedBytes: expectedBytes, tree: tree)
        guard charged <= RemoteDownloadStore.maximumPoolBytes - reservation else { throw RemoteDownloadStorageFailure.capacity }
        if editedText || originalText {
            let allocated = records.reduce(UInt64(0)) { $0 + $1.reservedBytes }
            let limit: UInt64 = originalText ? 32 << 20 : 3 << 20
            guard reservation <= limit, allocated <= limit - reservation else { throw RemoteDownloadStorageFailure.capacity }
        }
        originalHeaderAllocation?.beforeMkdir()
        try creation?.beforeMkdir()
        guard mkdirat(pool, folderName, 0o700) == 0 else { throw RemoteDownloadStorageFailure.unavailable }
        let createdID = id, createdName = folderName
        batchAllocation?.created(createdID)
        var cleanupFolder: Int32?, cleanupIdentity: DownloadDisk.Identity?
        var createdFiles: [String: DownloadDisk.Identity] = [:]
        var finishedConstruction = false
        defer {
            if batchAdmission && !finishedConstruction,
               let cleanupFolder, let cleanupIdentity,
               (try? DownloadDisk.removeFailedBatchConstruction(pool: pool, folder: cleanupFolder,
                   name: createdName, identity: cleanupIdentity, files: createdFiles)) != nil {
                batchAllocation?.removed(createdID)
            }
        }
        #if DEBUG
        if creation != nil { try SFTPSharedBudgetQualification.shared.reach(.bodyDirectoryCreated) }
        #endif
        let folder = openat(pool, folderName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard folder >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; held.append(folder)
        cleanupFolder = folder; cleanupIdentity = try DownloadDisk.identity(folder)
        let lease = openat(folder, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; held.append(lease)
        createdFiles["owner.lock"] = try DownloadDisk.identity(lease)
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw RemoteDownloadStorageFailure.unavailable }
        let marker = openat(folder, "session.meta", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard marker >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; defer { close(marker) }
        createdFiles["session.meta"] = try DownloadDisk.identity(marker)
        let data = try DownloadDisk.encodedMarker(.init(version: originalText ? 3 : tree ? 2 : publicQuarantineCandidate ? 4 : 1, id: id,
            expectedBytes: expectedBytes, treeReservation: tree ? reservation : nil,
            originalBudget: originalOwner?.budgetID, originalOwner: originalOwner?.catalogID))
        try DownloadDisk.writeAll(marker, data)
        guard fsync(marker) == 0, fsync(folder) == 0, fsync(pool) == 0 else { throw RemoteDownloadStorageFailure.unavailable }
        #if DEBUG
        try originalHeaderAllocation?.afterMetadataSyncForQualification()
        if batchAdmission { try hooks.failBatchAfterMetadataSync?(id) }
        #endif
        let payload = openat(folder, "payload", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard payload >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; held.append(payload)
        createdFiles["payload"] = try DownloadDisk.identity(payload)
        let fileURL = directory.appendingPathComponent(folderName).appendingPathComponent("payload")
        let quarantine: QuarantineWitness = try publicQuarantineCandidate
            ? .publicCandidate(OSManagedQuarantineCandidate.prepareReceivedEmptyStage(payload, at: fileURL))
            : .legacy(DownloadedFileQuarantine.markFreshSpoolFile(payload, at: fileURL))
        self.pool = pool; self.folder = folder; self.lease = lease; self.payload = payload
        markerIdentity = try DownloadDisk.identity(marker); markerBytes = data
        folderIdentity = try DownloadDisk.identity(folder); self.quarantine = quarantine
        try creation?.materialized(bodyPool: pool, lease: lease)
        keep = true; finishedConstruction = true
    }
    private func validate(requireLive: Bool = true) throws {
        if requireLive { try originalAllocation?.checkLive() }
        guard !released else { throw RemoteDownloadStorageFailure.incomplete }
        try SMBCatalogFiles.validatePool(pool, at: root)
        var named = stat(), pinned = stat()
        guard fstatat(pool, folderName, &named, AT_SYMLINK_NOFOLLOW) == 0, DownloadDisk.Identity(named) == folderIdentity,
              fstatat(folder, "payload", &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(payload, &pinned) == 0,
              DownloadDisk.privateFile(named), DownloadDisk.Identity(named) == DownloadDisk.Identity(pinned), pinned.st_size >= 0,
              UInt64(pinned.st_size) == written else { throw RemoteDownloadStorageFailure.changed }
        let reservation = try DownloadDisk.reservation(expectedBytes: expectedBytes, tree: tree)
        guard pinned.st_blocks >= 0, UInt64(pinned.st_blocks) <= (reservation - 8_192) / 512 else { throw RemoteDownloadStorageFailure.capacity }
        let marker = openat(folder, "session.meta", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { throw RemoteDownloadStorageFailure.changed }; defer { close(marker) }
        guard fstat(marker, &pinned) == 0, DownloadDisk.privateFile(pinned), DownloadDisk.Identity(pinned) == markerIdentity,
              pinned.st_size == markerBytes.count else { throw RemoteDownloadStorageFailure.changed }
        var observed = Data(count: markerBytes.count); let count = observed.count
        guard observed.withUnsafeMutableBytes({ pread(marker, $0.baseAddress, count, 0) }) == count,
              observed == markerBytes else { throw RemoteDownloadStorageFailure.changed }
        try quarantine.require(payload, at: root.appendingPathComponent(folderName).appendingPathComponent("payload"))
        if sealed {
            guard try DownloadDisk.stamp(payload) == sealedStamp else { throw RemoteDownloadStorageFailure.changed }
            if tree {
                let fd = openat(folder, "manifest", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw RemoteDownloadStorageFailure.changed }; defer { close(fd) }
                guard try DownloadDisk.stamp(fd) == manifestStamp else { throw RemoteDownloadStorageFailure.changed }
            }
        }
    }
    func append(request: UUID, offset: UInt64, bytes: Data) async throws {
        try await executor.perform { [self] in try appendOnSessionExecutor(request: request, offset: offset, bytes: bytes) }
    }
    /// The SFTP owner's bounded off-main executor may feed the same writer
    /// directly. The state lock serializes it with seal/abandon operations.
    func appendOnSessionExecutor(request: UUID, offset: UInt64, bytes: Data) throws {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        try state.withLock {
            do {
                guard !failed, !sealed, request == self.request, offset == written, !bytes.isEmpty,
                      bytes.count <= 32768, written <= expectedBytes,
                      UInt64(bytes.count) <= expectedBytes - written else { throw RemoteDownloadStorageFailure.changed }
                try validate()
                let remaining = hooks.failWriteAfterBytes.map { $0 > written ? $0 - written : 0 }
                try DownloadDisk.writeAll(payload, bytes, maximumBytes: remaining)
                hash.update(data: bytes); written += UInt64(bytes.count); try validate()
            } catch { failed = true; throw error }
        }
    }
    /// No resumable ready marker is published. A crash is always incomplete.
    func seal(request: UUID, receivedBytes: UInt64, manifest: Data? = nil) async throws -> Data {
        try await executor.perform { [self] in
            try state.withLock {
                do {
                    guard !failed, !sealed, request == self.request, receivedBytes == written, written == expectedBytes,
                          tree == (manifest != nil) else { throw RemoteDownloadStorageFailure.incomplete }
                    try validate(); let digest = Data(hash.finalize()); var verifier = SHA256(), offset: UInt64 = 0
                    while offset < written {
                        var data = Data(count: Int(min(65536, written - offset)))
                        let count = data.count
                        let found = data.withUnsafeMutableBytes { pread(payload, $0.baseAddress, count, off_t(offset)) }
                        if found < 0, errno == EINTR { continue }
                        guard found == data.count else { throw RemoteDownloadStorageFailure.unavailable }
                        verifier.update(data: data); offset += UInt64(found)
                    }
                    guard Data(verifier.finalize()) == digest else { throw RemoteDownloadStorageFailure.changed }
                    if let manifest {
                        guard manifest.count <= 8 << 20 else { throw RemoteDownloadStorageFailure.capacity }
                        let fd = openat(folder, "manifest", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                        guard fd >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; defer { close(fd) }
                        try DownloadDisk.writeAll(fd, manifest)
                        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw RemoteDownloadStorageFailure.io(errno) }
                        manifestStamp = try DownloadDisk.stamp(fd)
                    }
                    if hooks.failSync { throw RemoteDownloadStorageFailure.io(EIO) }
                    guard fcntl(payload, F_FULLFSYNC) == 0, fsync(folder) == 0, fsync(pool) == 0 else { throw RemoteDownloadStorageFailure.io(errno) }
                    try validate(); sealedStamp = try DownloadDisk.stamp(payload); sealedHash = digest; sealed = true; return digest
                } catch { failed = true; throw error }
            }
        }
    }
    /// For the future exact-file publication adapter, not a general cache read.
    /// Retained users must finish before clean removal is offered by the owner.
    func verifiedSource() async throws -> URL {
        try await executor.perform { [self] in
            try state.withLock {
                guard sealed, !failed, sealedHash != nil else { throw RemoteDownloadStorageFailure.incomplete }
                try validate(); return root.appendingPathComponent(folderName).appendingPathComponent("payload")
            }
        }
    }
    func hasExpectedV7NativeMark() async throws -> Bool {
        try await executor.perform { [self] in
            try state.withLock {
                guard !publicQuarantineCandidate else { throw RemoteDownloadStorageFailure.unsafe }
                guard sealed, !failed, sealedHash != nil else { throw RemoteDownloadStorageFailure.incomplete }
                try validate()
                let matched = try DownloadedFileQuarantine.hasExpectedV7NativeMark(payload)
                try validate()
                return matched
            }
        }
    }
    @discardableResult func abandon() async -> Bool {
        await executor.drain { [self] in state.withLock { abandonRequested = true; if publicationUsers == 0 { release() } } }
        return state.withLock { released }
    }
    func claimPublicationOnWorker(publicQuarantineV1: Bool = false) throws -> DownloadPublicationLease {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        return try state.withLock {
            guard publicQuarantineV1 == publicQuarantineCandidate else { throw RemoteDownloadStorageFailure.unsafe }
            guard sealed, !failed, !released, !abandonRequested, publicationUsers == 0,
                  adoptionMarker == nil, let digest = sealedHash else {
                throw RemoteDownloadStorageFailure.incomplete
            }
            try validate(); publicationUsers = 1
            return DownloadPublicationLease(file: self, logicalBytes: written, digest: digest)
        }
    }
    fileprivate func withPublicationSource<T>(check: () throws -> Void, _ body: (Int32, URL) throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        return try state.withLock {
            guard publicationUsers == 1, sealed, !failed else { throw RemoteDownloadStorageFailure.incomplete }
            try check(); try validate()
            let value = try body(payload, root.appendingPathComponent(folderName).appendingPathComponent("payload"))
            try check(); try validate(); return value
        }
    }
    fileprivate func releasePublication() {
        state.withLock { publicationUsers = 0; if abandonRequested { release() } }
    }

    fileprivate func adoptionPin() throws -> DownloadAdoptionPin {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        return try state.withLock {
            guard adoptionEligible, publicationUsers == 1, sealed, !failed, !released,
                  !abandonRequested, !transferred else { throw RemoteDownloadStorageFailure.incomplete }
            try validate()
            return try DownloadAdoptionPin(duplicating: payload,
                url: root.appendingPathComponent(folderName).appendingPathComponent("payload"))
        }
    }

    fileprivate func armAdoption(job: UUID, area: UUID) throws {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        try state.withLock {
            guard adoptionEligible, publicationUsers == 1, sealed, !failed, !released,
                  !abandonRequested, !transferred, adoptionMarker == nil else { throw RemoteDownloadStorageFailure.incomplete }
            try validate()
            let marker = DownloadAdoptionMarker(job: job, spool: id, area: area)
            let poolLock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(poolLock) }
            let current = try DownloadDisk.record(pool, name: folderName, heldLease: lease)
            guard current.folder == folderIdentity, current.adoption == nil,
                  current.files["payload"] == (try DownloadDisk.identity(payload)) else { throw RemoteDownloadStorageFailure.changed }
            let fd = openat(folder, "adoption.intent", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RemoteDownloadStorageFailure.unavailable }
            defer { close(fd) }
            try DownloadDisk.writeAll(fd, marker.bytes)
            guard fcntl(fd, F_FULLFSYNC) == 0, fsync(folder) == 0, fsync(pool) == 0 else {
                throw RemoteDownloadStorageFailure.io(errno)
            }
            adoptionMarker = marker
        }
    }

    fileprivate func noteAdopted(job: UUID) {
        state.withLock { if adoptionMarker?.job == job { transferred = true } }
    }

    fileprivate func retireCommittedShell(receipt: DownloadAdoptionCommitReceipt) throws {
        guard !Thread.isMainThread else { throw RemoteDownloadStorageFailure.busy }
        try state.withLock {
            guard transferred, publicationUsers == 1, !released,
                  receipt.spool == id, let marker = adoptionMarker, marker.job == receipt.job else {
                throw RemoteDownloadStorageFailure.incomplete
            }
            let poolLock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(poolLock) }
            let record = try DownloadDisk.record(pool, name: folderName, heldLease: lease)
            guard record.folder == folderIdentity, record.adoption == marker,
                  record.files["payload"] == nil else { throw RemoteDownloadStorageFailure.changed }
            try DownloadDisk.removeAdoptedShell(pool, record: record, heldLease: lease)
            adoptionMarker = nil; retiredAdoptionJob = receipt.job
            release()
        }
    }
    /// Caller must prove all actual network/publication users drained first.
    /// This packet keeps it internal and unconnected to ordinary UI.
    func removeAfterDrain(originalReadProof: SFTPOriginalUnadmittedReadProof? = nil) async throws {
        try await executor.perform { [self] in
            try state.withLock {
                guard !released else { throw RemoteDownloadStorageFailure.incomplete }
                guard publicationUsers == 0 else { throw RemoteDownloadStorageFailure.busy }
                try validate(requireLive: false)
                if let originalAllocation {
                    try originalAllocation.removeAfterActualUsersDrain(heldLease: lease, readProof: originalReadProof)
                    release(); return
                }
                guard originalReadProof == nil else { throw SFTPSharedBudgetFailure.unsafe }
                let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { close(lock) }
                let record = try DownloadDisk.record(pool, name: folderName, heldLease: lease)
                guard record.folder == folderIdentity, record.adoption == nil,
                      record.summary.id == id, record.summary.expectedBytes == expectedBytes,
                      record.files["payload"] == (try DownloadDisk.identity(payload)) else { throw RemoteDownloadStorageFailure.changed }
                try DownloadDisk.remove(pool, record: record, heldLease: lease); release()
            }
        }
    }
    func discardRetainedOriginalAfterReview() async throws {
        try await executor.perform { [self] in
            try state.withLock {
                guard released, publicationUsers == 0, let originalAllocation else { throw SFTPSharedBudgetFailure.unsafe }
                let budget = try SFTPSharedBudgetTransaction.open(layout: originalAllocation.owner.layout, writing: true)
                defer { budget.close() }
                try budget.removeOriginalBody(id, allocation: originalAllocation)
            }
        }
    }
    private func release() {
        guard !released else { return }; released = true; [payload, lease, folder, pool].forEach { close($0) }
    }
    deinit {
        let descriptors = state.withLock { released ? [] : [payload, lease, folder, pool] }
        if !descriptors.isEmpty { DispatchQueue.global(qos: .utility).async { descriptors.forEach { close($0) } } }
    }
}

/// The concrete producer owns one lease. Its release follows actual production
/// drain (or an unused plan's destruction), never just caller cancellation.
final class DownloadPublicationLease: @unchecked Sendable {
    let logicalBytes: UInt64, digest: Data
    private let file: RemoteDownloadSpool, lock = NSLock()
    private var released = false
    fileprivate init(file: RemoteDownloadSpool, logicalBytes: UInt64, digest: Data) {
        self.file = file; self.logicalBytes = logicalBytes; self.digest = digest
    }
    func withSource<T>(check: () throws -> Void, _ body: (Int32, URL) throws -> T) throws -> T {
        try lock.withLock {
            guard !released else { throw RemoteDownloadStorageFailure.incomplete }
            return try file.withPublicationSource(check: check, body)
        }
    }
    func release() { lock.withLock { guard !released else { return }; released = true; file.releasePublication() } }
    deinit { release() }
}

extension DownloadPublicationLease: SealedDownloadAdoptionSource {
    var spoolID: UUID { file.id }
    func adoptionPin() throws -> DownloadAdoptionPin { try file.adoptionPin() }
    func armAdoption(job: UUID, area: UUID) throws { try file.armAdoption(job: job, area: area) }
    func noteAdopted(job: UUID) { file.noteAdopted(job: job) }
    func retireCommittedShell(receipt: DownloadAdoptionCommitReceipt) throws {
        try file.retireCommittedShell(receipt: receipt)
    }
    func finished() { release() }
}

enum DownloadDisk {
    /// Reserve a bounded allocation bucket rather than assuming allocated
    /// bytes equal the exact file length. The largest file still reserves
    /// 1GiB +64KiB; the shared2GiB +128KiB ceiling does not grow.
    static func reservation(expectedBytes: UInt64, tree: Bool) throws -> UInt64 {
        guard expectedBytes <= RemoteDownloadStore.maximumFileBytes else { throw RemoteDownloadStorageFailure.capacity }
        if tree { return expectedBytes + (16 << 20) }
        var payload: UInt64 = expectedBytes == 0 ? 0 : 64 << 10
        while payload < expectedBytes { payload *= 2 }
        return payload + (64 << 10)
    }
    struct Identity: Equatable { let device: dev_t, inode: ino_t, birthSeconds: Int, birthNanos: Int
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino; birthSeconds = s.st_birthtimespec.tv_sec; birthNanos = s.st_birthtimespec.tv_nsec }
    }
    struct Marker: Codable { let version: Int, id: UUID, expectedBytes: UInt64
        let treeReservation: UInt64?
        let originalBudget: UUID?, originalOwner: UUID?
        init(version: Int, id: UUID, expectedBytes: UInt64, treeReservation: UInt64? = nil,
             originalBudget: UUID? = nil, originalOwner: UUID? = nil) {
            self.version = version; self.id = id; self.expectedBytes = expectedBytes; self.treeReservation = treeReservation
            self.originalBudget = originalBudget; self.originalOwner = originalOwner
        }
    }
    static func encodedMarker(_ marker: Marker) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(marker)
    }
    struct Stamp: Equatable {
        let identity: Identity, modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int, size: Int64, mode: mode_t, flags: UInt32
    }
    static func stamp(_ fd: Int32) throws -> Stamp {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw RemoteDownloadStorageFailure.unavailable }
        return .init(identity: Identity(s), modified: s.st_mtimespec.tv_sec, modifiedNanos: s.st_mtimespec.tv_nsec,
                     changed: s.st_ctimespec.tv_sec, changedNanos: s.st_ctimespec.tv_nsec, size: s.st_size, mode: s.st_mode, flags: s.st_flags)
    }
    struct Record {
        let name: String, summary: RemoteDownloadSummary, folder: Identity, files: [String: Identity], marker: Data
        let reservedBytes: UInt64
        let adoption: DownloadAdoptionMarker?
    }
    static func admissionCharge(_ records: [Record]) throws -> UInt64 {
        var charged: UInt64 = 0
        for record in records {
            let cost = record.summary.active ? max(record.summary.observedBytes, record.reservedBytes) : record.summary.observedBytes
            guard cost <= RemoteDownloadStore.maximumPoolBytes,
                  charged <= RemoteDownloadStore.maximumPoolBytes - cost else { throw RemoteDownloadStorageFailure.capacity }
            charged += cost
        }
        return charged
    }
    static func privateFile(_ s: stat) -> Bool {
        s.st_mode & S_IFMT == S_IFREG && s.st_mode & 0o7777 == 0o600 && s.st_nlink == 1 && s.st_uid == geteuid()
            && s.st_size >= 0 && s.st_blocks >= 0 && s.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED) == 0
    }
    static func identity(_ fd: Int32) throws -> Identity {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw RemoteDownloadStorageFailure.unavailable }; return Identity(s)
    }
    static func writeAll(_ fd: Int32, _ bytes: Data, maximumBytes: UInt64? = nil) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                if let maximumBytes, UInt64(offset) >= maximumBytes { throw RemoteDownloadStorageFailure.io(ENOSPC) }
                let count = Int(min(UInt64(buffer.count - offset), maximumBytes.map { $0 - UInt64(offset) } ?? UInt64.max))
                let found = write(fd, buffer.baseAddress!.advanced(by: offset), count)
                if found < 0, errno == EINTR { continue }
                guard found > 0 else { throw RemoteDownloadStorageFailure.io(found == 0 ? EIO : errno) }; offset += found
            }
        }
    }
    static func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard copy >= 0, let directory = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw RemoteDownloadStorageFailure.unavailable }
        defer { closedir(directory) }; var result: [String] = []; errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw RemoteDownloadStorageFailure.capacity }; result.append(name)
        }
        guard errno == 0 else { throw RemoteDownloadStorageFailure.unavailable }; return result
    }
    static func inventory(_ pool: Int32, originalBudgetID: UUID? = nil) throws -> [Record] {
        let names = try names(pool, maximum: 66)
        if names.contains(SFTPSharedBudgetTransaction.bodyFence) {
            guard let originalBudgetID,
                  try SFTPSharedBudgetTransaction.readFence(pool, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == originalBudgetID else { throw RemoteDownloadStorageFailure.unsafe }
        } else if originalBudgetID != nil { throw SFTPSharedBudgetFailure.recoveryRequired }
        return try names.filter { $0 != "pool.lock" && $0 != SFTPSharedBudgetTransaction.bodyFence }.map { name in
            let value = try record(pool, name: name)
            let marker = try JSONDecoder().decode(Marker.self, from: value.marker)
            guard marker.version != 3 || marker.originalBudget == originalBudgetID else { throw RemoteDownloadStorageFailure.unsafe }
            return value
        }
    }
    /// Only a batch constructor's own, still empty namespace may be removed.
    /// Any replacement, extra entry or payload write leaves the allocation
    /// untouched and its ID available to the interruption report.
    static func removeFailedBatchConstruction(pool: Int32, folder: Int32, name: String,
                                              identity: Identity, files: [String: Identity]) throws {
        var pinned = stat(), linked = stat()
        guard fstat(folder, &pinned) == 0, pinned.st_mode & S_IFMT == S_IFDIR,
              pinned.st_mode & 0o7777 == 0o700, pinned.st_uid == geteuid(), Identity(pinned) == identity,
              fstatat(pool, name, &linked, AT_SYMLINK_NOFOLLOW) == 0, Identity(linked) == identity,
              try Set(names(folder, maximum: 4)) == Set(files.keys) else { throw RemoteDownloadStorageFailure.changed }
        for (file, expected) in files {
            guard ["owner.lock", "session.meta", "payload"].contains(file),
                  fstatat(folder, file, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  privateFile(linked), linked.st_dev == pinned.st_dev, Identity(linked) == expected,
                  (file != "payload" || linked.st_size == 0),
                  (file != "owner.lock" || linked.st_size == 0) else { throw RemoteDownloadStorageFailure.changed }
        }
        for file in ["payload", "session.meta", "owner.lock"] where files[file] != nil {
            guard fstatat(folder, file, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  privateFile(linked), Identity(linked) == files[file],
                  (file != "payload" || linked.st_size == 0),
                  (file != "owner.lock" || linked.st_size == 0),
                  unlinkat(folder, file, 0) == 0 else {
                throw RemoteDownloadStorageFailure.changed
            }
        }
        guard fstatat(pool, name, &linked, AT_SYMLINK_NOFOLLOW) == 0, Identity(linked) == identity,
              unlinkat(pool, name, AT_REMOVEDIR) == 0, fsync(pool) == 0 else {
            throw RemoteDownloadStorageFailure.changed
        }
    }
    static func record(_ pool: Int32, name: String, heldLease: Int32? = nil, heldReadLease: SharedOriginalLease? = nil) throws -> Record {
        guard name.hasPrefix("download-"), let id = UUID(uuidString: String(name.dropFirst(9))), name == "download-" + id.uuidString else { throw RemoteDownloadStorageFailure.unsafe }
        let folder = openat(pool, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0 else { throw RemoteDownloadStorageFailure.unsafe }; defer { close(folder) }
        var parent = stat(), linked = stat()
        guard fstat(folder, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o7777 == 0o700, parent.st_uid == geteuid(),
              fstatat(pool, name, &linked, AT_SYMLINK_NOFOLLOW) == 0, Identity(linked) == Identity(parent) else { throw RemoteDownloadStorageFailure.changed }
        var files: [String: Identity] = [:], bytes: UInt64 = 0, payloadBytes: UInt64?
        for file in try names(folder, maximum: 5) {
            guard ["owner.lock", "session.meta", "payload", "manifest", "adoption.intent"].contains(file), fstatat(folder, file, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  privateFile(linked), linked.st_dev == parent.st_dev, UInt64(linked.st_blocks) <= RemoteDownloadStore.maximumPoolBytes / 512 else { throw RemoteDownloadStorageFailure.unsafe }
            let size = max(UInt64(linked.st_size), UInt64(linked.st_blocks) * 512)
            guard size <= RemoteDownloadStore.maximumPoolBytes, bytes <= RemoteDownloadStore.maximumPoolBytes - size else { throw RemoteDownloadStorageFailure.capacity }
            bytes += size; files[file] = Identity(linked)
            if file == "payload" { payloadBytes = UInt64(linked.st_size) }
        }
        guard files["owner.lock"] != nil, files["session.meta"] != nil else { throw RemoteDownloadStorageFailure.unsafe }
        let markerFD = openat(folder, "session.meta", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard markerFD >= 0 else { throw RemoteDownloadStorageFailure.unsafe }; defer { close(markerFD) }
        var markerStat = stat(); guard fstat(markerFD, &markerStat) == 0, markerStat.st_size > 0, markerStat.st_size <= 2048,
              try identity(markerFD) == files["session.meta"] else { throw RemoteDownloadStorageFailure.changed }
        var marker = Data(count: Int(markerStat.st_size)); let count = marker.count
        guard marker.withUnsafeMutableBytes({ read(markerFD, $0.baseAddress, count) }) == count else { throw RemoteDownloadStorageFailure.unavailable }
        let value = try JSONDecoder().decode(Marker.self, from: marker)
        guard value.id == id, value.expectedBytes <= RemoteDownloadStore.maximumFileBytes,
              try encodedMarker(value) == marker else { throw RemoteDownloadStorageFailure.unsafe }
        let adoption: DownloadAdoptionMarker?
        if files["adoption.intent"] != nil {
            guard value.version == 1, files["manifest"] == nil else { throw RemoteDownloadStorageFailure.unsafe }
            let fd = openat(folder, "adoption.intent", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw RemoteDownloadStorageFailure.unsafe }
            defer { close(fd) }
            var facts = stat()
            guard fstat(fd, &facts) == 0, privateFile(facts), Identity(facts) == files["adoption.intent"],
                  facts.st_size > 0, facts.st_size <= 160 else { throw RemoteDownloadStorageFailure.unsafe }
            var bytes = Data(count: Int(facts.st_size)); let count = bytes.count
            guard bytes.withUnsafeMutableBytes({ read(fd, $0.baseAddress, count) }) == count,
                  let parsed = try? DownloadAdoptionMarker(bytes: bytes), parsed.spool == id else {
                throw RemoteDownloadStorageFailure.unsafe
            }
            adoption = parsed
        } else { adoption = nil }
        let reservation: UInt64
        switch value.version {
        case 1, 4:
            guard value.treeReservation == nil, value.originalBudget == nil, value.originalOwner == nil,
                  files["manifest"] == nil else { throw RemoteDownloadStorageFailure.unsafe }
            reservation = try Self.reservation(expectedBytes: value.expectedBytes, tree: false)
        case 2:
            guard value.originalBudget == nil, value.originalOwner == nil,
                  value.treeReservation == value.expectedBytes + (16 << 20) else { throw RemoteDownloadStorageFailure.unsafe }
            if files["manifest"] != nil {
                guard fstatat(folder, "manifest", &linked, AT_SYMLINK_NOFOLLOW) == 0,
                      linked.st_size <= 8 << 20 else { throw RemoteDownloadStorageFailure.capacity }
            }
            reservation = try Self.reservation(expectedBytes: value.expectedBytes, tree: true)
        case 3:
            guard value.treeReservation == nil, files["manifest"] == nil, value.expectedBytes <= 1 << 20,
                  value.originalBudget.map(SFTPWire.validToken) == true, value.originalOwner.map(SFTPWire.validToken) == true else { throw RemoteDownloadStorageFailure.unsafe }
            reservation = try Self.reservation(expectedBytes: value.expectedBytes, tree: false)
        default: throw RemoteDownloadStorageFailure.unsafe
        }
        if let payloadBytes, payloadBytes > value.expectedBytes { throw RemoteDownloadStorageFailure.changed }
        // An allocator exceeding its reservation stops the writer. Its closed,
        // bounded v1 inventory must still be visible/discardable after drain.
        // New admissions charge max(actual, reserved), never the lower value.
        let inventoryLimit = [1, 4].contains(value.version) ? RemoteDownloadStore.maximumFileBytes + (64 << 10) : reservation
        guard bytes <= inventoryLimit else { throw RemoteDownloadStorageFailure.capacity }
        if let heldReadLease {
            guard heldLease == nil, let expected = files["owner.lock"] else { throw RemoteDownloadStorageFailure.changed }
            try heldReadLease.validateShared(expected: expected)
            return Record(name: name, summary: .init(id: id, expectedBytes: value.expectedBytes, observedBytes: bytes,
                active: true, isFolder: value.version == 2, publicationProtected: adoption != nil),
                folder: Identity(parent), files: files, marker: marker, reservedBytes: reservation, adoption: adoption)
        }
        let lease = heldLease ?? openat(folder, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lease >= 0 else { throw RemoteDownloadStorageFailure.unsafe }; defer { if heldLease == nil { close(lease) } }
        var leaseStat = stat(); guard fstat(lease, &leaseStat) == 0, leaseStat.st_size == 0, try identity(lease) == files["owner.lock"] else { throw RemoteDownloadStorageFailure.changed }
        let active: Bool
        if flock(lease, LOCK_EX | LOCK_NB) == 0 { active = heldLease != nil }
        else if errno == EWOULDBLOCK { active = true }
        else { throw RemoteDownloadStorageFailure.unavailable }
        return Record(name: name, summary: .init(id: id, expectedBytes: value.expectedBytes, observedBytes: bytes,
            active: active, isFolder: value.version == 2, publicationProtected: adoption != nil),
            folder: Identity(parent), files: files, marker: marker, reservedBytes: reservation, adoption: adoption)
    }
    static func remove(_ pool: Int32, record: Record, heldLease: Int32? = nil) throws {
        guard record.adoption == nil else { throw RemoteDownloadStorageFailure.busy }
        let folder = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0 else { throw RemoteDownloadStorageFailure.changed }; defer { close(folder) }
        guard try identity(folder) == record.folder else { throw RemoteDownloadStorageFailure.changed }
        let lease = heldLease ?? openat(folder, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lease >= 0 else { throw RemoteDownloadStorageFailure.changed }; defer { if heldLease == nil { close(lease) } }
        guard try identity(lease) == record.files["owner.lock"], flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw RemoteDownloadStorageFailure.busy }
        let current = try Self.record(pool, name: record.name, heldLease: lease)
        guard current.folder == record.folder, current.files == record.files, current.marker == record.marker else { throw RemoteDownloadStorageFailure.changed }
        let marker = try JSONDecoder().decode(Marker.self, from: record.marker)
        var payloadLease: Int32 = -1
        defer { if payloadLease >= 0 { close(payloadLease) } }
        if marker.version == 3, let expected = record.files["payload"] {
            payloadLease = openat(folder, "payload", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard payloadLease >= 0, try identity(payloadLease) == expected,
                  flock(payloadLease, LOCK_EX | LOCK_NB) == 0 else { throw RemoteDownloadStorageFailure.busy }
        }
        for name in ["payload", "manifest", "owner.lock", "session.meta"] where record.files[name] != nil {
            var linked = stat(); guard fstatat(folder, name, &linked, AT_SYMLINK_NOFOLLOW) == 0, privateFile(linked),
                Identity(linked) == record.files[name], unlinkat(folder, name, 0) == 0 else { throw RemoteDownloadStorageFailure.changed }
        }
        var linked = stat(); guard fstatat(pool, record.name, &linked, AT_SYMLINK_NOFOLLOW) == 0, Identity(linked) == record.folder,
            unlinkat(pool, record.name, AT_REMOVEDIR) == 0, fsync(pool) == 0 else { throw RemoteDownloadStorageFailure.changed }
    }

    static func removeAdoptedShell(_ pool: Int32, record: Record, heldLease: Int32) throws {
        guard record.adoption != nil, record.files["payload"] == nil, record.files["manifest"] == nil,
              Set(record.files.keys) == ["owner.lock", "session.meta", "adoption.intent"] else {
            throw RemoteDownloadStorageFailure.changed
        }
        let folder = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0 else { throw RemoteDownloadStorageFailure.changed }
        defer { close(folder) }
        guard try identity(folder) == record.folder, try identity(heldLease) == record.files["owner.lock"],
              flock(heldLease, LOCK_EX | LOCK_NB) == 0 else { throw RemoteDownloadStorageFailure.changed }
        let current = try Self.record(pool, name: record.name, heldLease: heldLease)
        guard current.folder == record.folder, current.files == record.files,
              current.marker == record.marker, current.adoption == record.adoption else { throw RemoteDownloadStorageFailure.changed }
        for name in ["adoption.intent", "session.meta", "owner.lock"] {
            var linked = stat()
            guard fstatat(folder, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  privateFile(linked), Identity(linked) == record.files[name],
                  unlinkat(folder, name, 0) == 0 else { throw RemoteDownloadStorageFailure.changed }
        }
        var linked = stat()
        guard fstatat(pool, record.name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(linked) == record.folder, unlinkat(pool, record.name, AT_REMOVEDIR) == 0,
              fsync(pool) == 0 else { throw RemoteDownloadStorageFailure.changed }
    }
}
