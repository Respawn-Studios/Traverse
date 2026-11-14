import Darwin
import Foundation

@_spi(Qualification) public enum SMBTemporaryStorageFailure: Error, Sendable, Equatable {
    case unsafe, unavailable, busy, capacity, changed, cancelled
}

/// Temporary remote names/metadata only; no password, source URL or file body.
@_spi(Qualification) public struct SMBTemporaryStorage: Sendable {
    public static let maximumSessionBytes: UInt64 = 512 << 20
    public static let maximumPoolBytes: UInt64 = 2 << 30
    public let directory: URL
    private(set) var workspaceWitness: ConnectionWorkspaceWitness?
    public let sessionByteLimit: UInt64
    public let poolByteLimit: UInt64
    public init(directory: URL, sessionByteLimit: UInt64 = maximumSessionBytes,
                poolByteLimit: UInt64 = maximumPoolBytes) throws {
        guard directory.isFileURL, directory.host == nil || directory.host == "",
              directory.query == nil, directory.fragment == nil, directory.standardizedFileURL == directory,
              (1 << 20...Self.maximumSessionBytes).contains(sessionByteLimit),
              sessionByteLimit <= poolByteLimit, poolByteLimit <= Self.maximumPoolBytes else {
            throw SMBTemporaryStorageFailure.unsafe
        }
        self.directory = directory; self.sessionByteLimit = sessionByteLimit; self.poolByteLimit = poolByteLimit
        workspaceWitness = nil
    }
    /// Explicit Connect preparation; never called by passive workspace or
    /// Saved Versions discovery. Runs off MainActor under the existing locks.
    public func prepareSharedOriginalStorageForConnect() async throws {
        try requireDurableOriginalAdmission()
        let selected = self
        let task = Task.detached(priority: .utility) {
            try SFTPSharedBudgetTransaction.prepareForConnect(layout: .init(storage: selected))
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    init(connectionWorkspaceDirectory: URL, witness: ConnectionWorkspaceWitness) throws {
        try self.init(directory: connectionWorkspaceDirectory)
        guard connectionWorkspaceDirectory == witness.paths.metadata else { throw ConnectionWorkspaceFailure.unsafe }
        workspaceWitness = witness
    }
    // Only used while record EX and actual earlier allocator EX are held by
    // the activation implementation. reserve/admission refuses this value.
    init(unadmittedWorkspaceDirectory: URL) throws { try self.init(directory: unadmittedWorkspaceDirectory) }
}

@_spi(Qualification) public struct SMBTemporaryCatalogSummary: Sendable, Equatable {
    public let id: UUID
    public let observedBytes: UInt64
    public let active: Bool
}

/// Construction and passive inspection do not create storage or recover SQLite.
/// The private pool is bounded across independent app instances using flock.
@_spi(Qualification) public final class SMBTemporaryCatalogPool: @unchecked Sendable {
    let storage: SMBTemporaryStorage
    private let queue = DispatchQueue(label: "MacExplorer.SMB.TemporaryCatalog", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    public init(storage: SMBTemporaryStorage) { self.storage = storage }
    public func inspect() async throws -> [SMBTemporaryCatalogSummary] {
        try await perform { [storage] in
            let workspace = try storage.beginWorkspaceTransaction(); defer { workspace?.close() }
            guard let pool = try SMBCatalogFiles.openPool(storage.directory, create: false) else { return [] }
            defer { Darwin.close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
            try workspace?.validateCurrent()
            return try SMBCatalogFiles.inventory(pool, storage: storage).map(\.summary)
        }
    }
    public func reserve() async throws -> SMBTemporaryCatalog {
        let value = try await perform { [self] in try reserveOnSessionExecutor() }
        if Task.isCancelled { _ = await value.finishWithoutWorker(); throw SMBTemporaryStorageFailure.cancelled }
        return value
    }
    /// Internal SMB/SFTP owners may use their already-bounded off-main executor.
    /// Reuse the same cross-process lease/charge authority, never a second pool.
    func reserveOnSessionExecutor(purpose: SFTPSharedMetadataPurpose = .ordinary) throws -> SMBTemporaryCatalog {
        try SMBTemporaryCatalog(files: SMBCatalogFiles(storage: storage, purpose: purpose))
    }
    /// Explicit discard of an inactive owned session, including a hot journal.
    /// Does not open SQLite, recurse, follow links or delete unrecognized names.
    public func discardIncomplete(_ id: UUID) async throws {
        try await perform { [storage] in
            let workspace = try storage.beginWorkspaceTransaction(); defer { workspace?.close() }
            guard let pool = try SMBCatalogFiles.openPool(storage.directory, create: false) else { return }
            defer { Darwin.close(pool) }
            let guardFD = try SMBCatalogFiles.lockPool(pool, create: false)
            defer { Darwin.close(guardFD) }
            try workspace?.validateCurrent()
            try SMBCatalogFiles.validatePool(pool, at: storage.directory)
            let records = try SMBCatalogFiles.inventory(pool, storage: storage)
            guard let record = records.first(where: { $0.summary.id == id }) else { throw SMBTemporaryStorageFailure.changed }
            guard !record.summary.active else { throw SMBTemporaryStorageFailure.busy }
            let budget = try SFTPSharedBudgetTransaction.hasFence(pool)
                ? SFTPSharedBudgetTransaction.existing(layout: .init(storage: storage), pool: pool, guardFD: guardFD, writing: true) : nil
            defer { budget?.close() }
            try budget?.metadataRemovalIntent(id)
            try SMBCatalogFiles.remove(pool: pool, record: record)
            try budget?.metadataRemoved(id)
        }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            admission.lock()
            guard pending < 8 else { admission.unlock(); continuation.resume(throwing: SMBTemporaryStorageFailure.busy); return }
            pending += 1
            queue.async { [self] in
                let result = Result { try body() }
                admission.withLock { pending -= 1 }
                continuation.resume(with: result)
            }
            admission.unlock()
        }
    }
}

/// A reservation is retained by the session through actual helper/read drain.
/// No deinit cleanup: an unconfirmed worker/crash leaves explicit incomplete
/// storage. Release closes local descriptors; deletion needs a proven clean end.
@_spi(Qualification) public final class SMBTemporaryCatalog: @unchecked Sendable {
    let files: SMBCatalogFiles
    public var id: UUID { files.id }
    var path: URL { files.path }
    var quota: UInt64 { files.writerQuota }
    var descriptors: [Int32] { [files.directory, files.database, files.lease] }
    init(files: SMBCatalogFiles) { self.files = files }
    func finishWithoutWorker() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: self.files.finish(clean: true)) }
        }
    }
}

final class SMBCatalogFiles: @unchecked Sendable {
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    struct Record {
        let name: String, summary: SMBTemporaryCatalogSummary, directory: Identity
        let files: [String: Identity]
        let marker: Data
    }
    let storage: SMBTemporaryStorage, id: UUID, path: URL
    let writerQuota: UInt64
    let sharedLiveness = SFTPSharedOwnerLiveness()
    let pool: Int32, directory: Int32, database: Int32, lease: Int32
    private let state = NSLock()
    private var finished: Bool?
    private let name: String, directoryIdentity: Identity

    init(storage: SMBTemporaryStorage, id: UUID = UUID(), purpose: SFTPSharedMetadataPurpose = .ordinary) throws {
        let workspace = try storage.beginWorkspaceTransaction(); defer { workspace?.close() }
        self.storage = storage; self.id = id; name = "session-" + id.uuidString
        path = storage.directory.appendingPathComponent(name).appendingPathComponent("catalog.sqlite")
        guard let pool = try Self.openPool(storage.directory, create: true) else { throw SMBTemporaryStorageFailure.unavailable }
        var held: [Int32] = [pool]
        var keep = false
        defer { if !keep { held.forEach { Darwin.close($0) } } }
        let guardFD = try Self.lockPool(pool, create: true); defer { Darwin.close(guardFD) }
        try workspace?.validateCurrent()
        try Self.validatePool(pool, at: storage.directory)
        let budget = try SFTPSharedBudgetTransaction.reserveMetadata(layout: .init(storage: storage), pool: pool, guardFD: guardFD, id: id, purpose: purpose)
        defer { budget?.closeAfterConstructor() }
        writerQuota = budget?.writerQuota ?? storage.sessionByteLimit
        let existing = try Self.legacyInventory(pool, excludingSharedFence: budget != nil)
        var charged: UInt64 = 0
        for record in existing where budget == nil {
            // An active writer can grow after observation. Reserve its supported
            // maximum, not its currently empty catalog; this is cross-process.
            let bytes = record.summary.active ? max(record.summary.observedBytes, SMBTemporaryStorage.maximumSessionBytes) : record.summary.observedBytes
            guard bytes <= storage.poolByteLimit, charged <= storage.poolByteLimit - bytes else { throw SMBTemporaryStorageFailure.capacity }
            charged += bytes
        }
        let reservation = SMBTemporaryStorage.maximumSessionBytes
        guard budget != nil || (reservation <= storage.poolByteLimit && charged <= storage.poolByteLimit - reservation && existing.count < 64) else {
            throw SMBTemporaryStorageFailure.capacity
        }
        try workspace?.validateCurrent()
        try budget?.beforeMkdir()
        guard mkdirat(pool, name, 0o700) == 0 else { throw SMBTemporaryStorageFailure.unavailable }
        #if DEBUG
        if budget != nil { try SFTPSharedBudgetQualification.shared.reach(.metadataDirectoryCreated) }
        #endif
        let directory = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard directory >= 0 else { throw SMBTemporaryStorageFailure.unavailable }; held.append(directory)
        let lease = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw SMBTemporaryStorageFailure.unavailable }; held.append(lease)
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw SMBTemporaryStorageFailure.busy }
        let marker = openat(directory, "session.meta", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard marker >= 0 else { throw SMBTemporaryStorageFailure.unavailable }
        defer { Darwin.close(marker) }
        let data = Data("MEXSMBSTORE1 \(id.uuidString)\n".utf8)
        guard data.withUnsafeBytes({ Darwin.write(marker, $0.baseAddress, $0.count) }) == data.count,
              fsync(marker) == 0, fsync(directory) == 0, fsync(pool) == 0 else { throw SMBTemporaryStorageFailure.unavailable }
        let database = openat(directory, "catalog.sqlite", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard database >= 0 else { throw SMBTemporaryStorageFailure.unavailable }; held.append(database)
        var facts = stat(); guard fstat(directory, &facts) == 0 else { throw SMBTemporaryStorageFailure.unavailable }
        self.pool = pool; self.directory = directory; self.database = database; self.lease = lease; directoryIdentity = Identity(facts)
        try budget?.materialized()
        keep = true
    }
    deinit {
        sharedLiveness.end()
        if state.withLock({ finished == nil }) {
            let held = [database, lease, directory, pool]
            DispatchQueue.global(qos: .utility).async { held.forEach { Darwin.close($0) } }
        }
    }
    /// Caller must be the session executor after all actual users drained.
    /// Failure preserves remaining files; there is no recursive retry.
    @discardableResult func finish(clean: Bool) -> Bool {
        state.withLock {
            if let finished { return finished }
            sharedLiveness.end()
            defer { [database, lease, directory, pool].forEach { Darwin.close($0) } }
            guard clean else { finished = false; return false }
            do {
                let workspace = try storage.beginWorkspaceTransaction(); defer { workspace?.close() }
                let guardFD = try Self.lockPool(pool, create: false); defer { Darwin.close(guardFD) }
                try workspace?.validateCurrent()
                try Self.validatePool(pool, at: storage.directory)
                let budget = try SFTPSharedBudgetTransaction.hasFence(pool)
                    ? SFTPSharedBudgetTransaction.existing(layout: .init(storage: storage), pool: pool, guardFD: guardFD, writing: true) : nil
                defer { budget?.close() }
                let record = try Self.record(pool, name: name, heldLease: lease)
                guard record.directory == directoryIdentity,
                      let stored = record.files["catalog.sqlite"], stored == (try Self.identity(database)) else {
                    throw SMBTemporaryStorageFailure.changed
                }
                // SQLite DELETE journaling should have removed a normal journal.
                // A retained journal stays an explicit incomplete result.
                guard record.files["catalog.sqlite-journal"] == nil else { throw SMBTemporaryStorageFailure.changed }
                try budget?.metadataRemovalIntent(id)
                try Self.remove(pool: pool, record: record, heldLease: lease)
                try budget?.metadataRemoved(id)
                finished = true; return true
            } catch { finished = false; return false }
        }
    }
    static func openPool(_ url: URL, create: Bool) throws -> Int32? {
        var fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if fd < 0, errno == ENOENT {
            guard create else { return nil }
            let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0 else { throw SMBTemporaryStorageFailure.unsafe }; defer { Darwin.close(parent) }
            guard mkdirat(parent, url.lastPathComponent, 0o700) == 0 || errno == EEXIST else { throw SMBTemporaryStorageFailure.unavailable }
            fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard fd >= 0 else { throw SMBTemporaryStorageFailure.unsafe }
        var facts = stat(), volume = statfs()
        guard fstat(fd, &facts) == 0, privateDirectory(facts), fstatfs(fd, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { Darwin.close(fd); throw SMBTemporaryStorageFailure.unsafe }
        return fd
    }
    static func validatePool(_ fd: Int32, at url: URL) throws {
        guard let current = try openPool(url, create: false) else { throw SMBTemporaryStorageFailure.changed }
        defer { Darwin.close(current) }
        guard try identity(current) == identity(fd) else { throw SMBTemporaryStorageFailure.changed }
    }
    static func lockPool(_ pool: Int32, create: Bool) throws -> Int32 {
        let fd = openat(pool, "pool.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw SMBTemporaryStorageFailure.unsafe }
        var facts = stat(), named = stat()
        guard fstat(fd, &facts) == 0, privateFile(facts), facts.st_size == 0,
              fstatat(pool, "pool.lock", &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(facts) == Identity(named) else {
            Darwin.close(fd); throw SMBTemporaryStorageFailure.unsafe
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw SMBTemporaryStorageFailure.busy }
        return fd
    }
    static func inventory(_ pool: Int32, storage: SMBTemporaryStorage? = nil) throws -> [Record] {
        if try SFTPSharedBudgetTransaction.hasFence(pool) {
            guard let storage else { throw SFTPSharedBudgetFailure.recoveryRequired }
            let budget = try SFTPSharedBudgetTransaction.existing(layout: .init(storage: storage), pool: pool, guardFD: -1, writing: false)
            defer { budget.close() }
            return try legacyInventory(pool, excludingSharedFence: true)
        }
        return try legacyInventory(pool)
    }
    /// Frozen old parser semantics remain reachable only by old binaries or
    /// generated legacy controls. New fenced admission never calls this alone.
    static func legacyInventory(_ pool: Int32, excludingSharedFence: Bool = false) throws -> [Record] {
        try names(pool, maximum: excludingSharedFence ? 66 : 65)
            .filter { $0 != "pool.lock" && (!excludingSharedFence || $0 != SFTPSharedBudgetTransaction.metadataFence) }
            .map { try record(pool, name: $0) }
    }
    static func record(_ pool: Int32, name: String, heldLease: Int32? = nil) throws -> Record {
        guard name.hasPrefix("session-"), let id = UUID(uuidString: String(name.dropFirst(8))),
              name == "session-" + id.uuidString else { throw SMBTemporaryStorageFailure.unsafe }
        let directory = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard directory >= 0 else { throw SMBTemporaryStorageFailure.unsafe }; defer { Darwin.close(directory) }
        var facts = stat(), named = stat()
        guard fstat(directory, &facts) == 0, privateDirectory(facts),
              fstatat(pool, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(facts) == Identity(named) else { throw SMBTemporaryStorageFailure.changed }
        var files: [String: Identity] = [:], bytes: UInt64 = 0
        for file in try names(directory, maximum: 4) {
            guard ["catalog.sqlite", "catalog.sqlite-journal", "owner.lock", "session.meta"].contains(file),
                  fstatat(directory, file, &named, AT_SYMLINK_NOFOLLOW) == 0, privateFile(named), named.st_dev == facts.st_dev,
                  named.st_size >= 0, named.st_blocks >= 0, UInt64(named.st_blocks) <= SMBTemporaryStorage.maximumPoolBytes / 512 else {
                throw SMBTemporaryStorageFailure.unsafe
            }
            let size = max(UInt64(named.st_size), UInt64(named.st_blocks) * 512)
            guard size <= SMBTemporaryStorage.maximumSessionBytes, bytes <= SMBTemporaryStorage.maximumSessionBytes - size else {
                throw SMBTemporaryStorageFailure.capacity
            }
            bytes += size; files[file] = Identity(named)
        }
        guard files["owner.lock"] != nil, files["session.meta"] != nil else { throw SMBTemporaryStorageFailure.unsafe }
        let markerFD = openat(directory, "session.meta", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard markerFD >= 0 else { throw SMBTemporaryStorageFailure.unsafe }; defer { Darwin.close(markerFD) }
        guard try identity(markerFD) == files["session.meta"] else { throw SMBTemporaryStorageFailure.changed }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(markerFD, &buffer, buffer.count)
        let marker = Data("MEXSMBSTORE1 \(id.uuidString)\n".utf8)
        guard count == marker.count, Data(buffer.prefix(count)) == marker else { throw SMBTemporaryStorageFailure.unsafe }
        let lease = heldLease ?? openat(directory, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lease >= 0 else { throw SMBTemporaryStorageFailure.unsafe }; defer { if heldLease == nil { Darwin.close(lease) } }
        guard try identity(lease) == files["owner.lock"] else { throw SMBTemporaryStorageFailure.changed }
        var leaseStat = stat(); guard fstat(lease, &leaseStat) == 0, leaseStat.st_size == 0 else { throw SMBTemporaryStorageFailure.unsafe }
        let active: Bool
        if flock(lease, LOCK_EX | LOCK_NB) == 0 { active = heldLease != nil }
        else if errno == EWOULDBLOCK { active = true }
        else { throw SMBTemporaryStorageFailure.unavailable }
        return Record(name: name, summary: .init(id: id, observedBytes: bytes, active: active),
                      directory: Identity(facts), files: files, marker: marker)
    }
    static func remove(pool: Int32, record: Record, heldLease: Int32? = nil) throws {
        let directory = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard directory >= 0 else { throw SMBTemporaryStorageFailure.changed }; defer { Darwin.close(directory) }
        guard try identity(directory) == record.directory else { throw SMBTemporaryStorageFailure.changed }
        let lease = heldLease ?? openat(directory, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lease >= 0 else { throw SMBTemporaryStorageFailure.changed }; defer { if heldLease == nil { Darwin.close(lease) } }
        guard try identity(lease) == record.files["owner.lock"], flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            throw SMBTemporaryStorageFailure.busy
        }
        let current = try Self.record(pool, name: record.name, heldLease: lease)
        guard current.directory == record.directory, current.files == record.files, current.marker == record.marker else {
            throw SMBTemporaryStorageFailure.changed
        }
        // Exact known files only. Partial removal stays marked for explicit
        // retry; remove the ownership marker and empty folder last.
        for name in ["catalog.sqlite-journal", "catalog.sqlite", "owner.lock", "session.meta"] where record.files[name] != nil {
            var fresh = stat()
            guard fstatat(directory, name, &fresh, AT_SYMLINK_NOFOLLOW) == 0, privateFile(fresh), Identity(fresh) == record.files[name],
                  unlinkat(directory, name, 0) == 0 else { throw SMBTemporaryStorageFailure.changed }
        }
        var fresh = stat()
        guard fstatat(pool, record.name, &fresh, AT_SYMLINK_NOFOLLOW) == 0, Identity(fresh) == record.directory,
              unlinkat(pool, record.name, AT_REMOVEDIR) == 0, fsync(pool) == 0 else { throw SMBTemporaryStorageFailure.changed }
    }
    static func identity(_ fd: Int32) throws -> Identity {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw SMBTemporaryStorageFailure.unavailable }; return Identity(value)
    }
    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o7777 == 0o600
            && value.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED) == 0
    }
    private static func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }; throw SMBTemporaryStorageFailure.unavailable
        }
        defer { closedir(directory) }
        var values: [String] = []; errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard values.count < maximum else { throw SMBTemporaryStorageFailure.capacity }; values.append(name)
        }
        guard errno == 0 else { throw SMBTemporaryStorageFailure.unavailable }; return values
    }
}
