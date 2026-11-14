import Darwin
import CryptoKit
import ExplorerCore
import Foundation

/// An explicit result-store allowance. This does not grant source access.
public struct AnalysisResultStorage: Sendable {
    // Development full-scan envelope accepted18 October. These are temporary
    // metadata bytes, not source-data, RAM or file-operation limits.
    public static let maximumSessionBytes: UInt64 = 2 << 30
    public static let maximumPoolBytes: UInt64 = 8 << 30
    public let directory: URL
    public let sessionByteLimit: UInt64
    public let poolByteLimit: UInt64
    public let preserveAfterClose: Bool
    /// Optional durable sidecar for retained catalog tombstone reservations.
    /// The scanner pool inventory reads its canonical image without taking its
    /// lock, preserving sidecar -> pool lock order for deletion.
    public let retentionStateDirectory: URL?
    public init(directory: URL, sessionByteLimit: UInt64 = Self.maximumSessionBytes,
                poolByteLimit: UInt64 = Self.maximumPoolBytes, preserveAfterClose: Bool = false,
                retentionStateDirectory: URL? = nil) throws {
        guard directory.isFileURL, directory.host == nil || directory.host == "",
              directory.query == nil, directory.fragment == nil,
              (1 << 20...Self.maximumSessionBytes).contains(sessionByteLimit),
              sessionByteLimit <= poolByteLimit, poolByteLimit <= Self.maximumPoolBytes else { throw StorageScanFailure.resourceLimit }
        self.directory = directory; self.sessionByteLimit = sessionByteLimit
        if let state = retentionStateDirectory {
            guard state.isFileURL, state.host == nil || state.host == "", state.query == nil, state.fragment == nil,
                  state.standardizedFileURL.path == state.path, state.path != directory.path,
                  !state.path.hasPrefix(directory.path + "/"), !directory.path.hasPrefix(state.path + "/") else {
                throw StorageScanFailure.resourceLimit
            }
        }
        self.poolByteLimit = poolByteLimit; self.preserveAfterClose = preserveAfterClose
        self.retentionStateDirectory = retentionStateDirectory
    }
}

struct RetainedStoreCloseReceipt: Equatable, Sendable {
    let catalogID: UUID
    let originalSession: UUID
    let ownerDescriptorClosed: Bool
}

/// File descriptors are immutable until the last session/query releases them.
/// Actual disk work, including owned-store discard, runs on a utility worker.
final class AnalysisStoreFiles: @unchecked Sendable {
    private static let scheduledDiscards = DispatchGroup()
    // Fsynced before ordinary DB unlink. The exact inode/birth/size witness
    // prevents recovery from deleting a replaced catalog or owner lock.
    // Internal so the modeled device-change qualification exercises the exact
    // predicate used by cold recovery.
    struct OrdinaryDiscardIntent: Codable {
        let format: String, sessionChild: String
        // v2 binds recovery to a volume identity that survives a changed
        // st_dev after restart. Optional fields only decode old v1 markers;
        // they do not authorize v1 recovery without a stable volume witness.
        let volumeUUID: UUID?
        let directoryInode: UInt64?
        let directoryBirthSeconds: Int64?, directoryBirthNanos: Int64?
        let databaseDevice: UInt64?, databaseInode: UInt64
        let databaseBirthSeconds: Int64, databaseBirthNanos: Int64
        let databaseSize: Int64, databaseModifiedSeconds: Int64, databaseModifiedNanos: Int64
        let leaseDevice: UInt64?, leaseInode: UInt64
        let leaseBirthSeconds: Int64, leaseBirthNanos: Int64
        init(name: String, volume: UUID, directory: stat, database: stat, lease: stat) {
            format = "traverse-analysis-ordinary-discard-v2"; sessionChild = name
            volumeUUID = volume
            directoryInode = UInt64(directory.st_ino)
            directoryBirthSeconds = Int64(directory.st_birthtimespec.tv_sec)
            directoryBirthNanos = Int64(directory.st_birthtimespec.tv_nsec)
            databaseDevice = nil // v1 only; current-device checks use fresh descriptors.
            databaseInode = UInt64(database.st_ino)
            databaseBirthSeconds = Int64(database.st_birthtimespec.tv_sec)
            databaseBirthNanos = Int64(database.st_birthtimespec.tv_nsec)
            databaseSize = database.st_size
            databaseModifiedSeconds = Int64(database.st_mtimespec.tv_sec)
            databaseModifiedNanos = Int64(database.st_mtimespec.tv_nsec)
            leaseDevice = nil
            leaseInode = UInt64(lease.st_ino)
            leaseBirthSeconds = Int64(lease.st_birthtimespec.tv_sec)
            leaseBirthNanos = Int64(lease.st_birthtimespec.tv_nsec)
        }
        func matchesDirectory(_ value: stat, volume: UUID) -> Bool {
            format == "traverse-analysis-ordinary-discard-v2" && volumeUUID == volume
                && directoryInode == UInt64(value.st_ino)
                && directoryBirthSeconds == Int64(value.st_birthtimespec.tv_sec)
                && directoryBirthNanos == Int64(value.st_birthtimespec.tv_nsec)
        }
        func matchesDatabase(_ value: stat) -> Bool {
            databaseInode == UInt64(value.st_ino)
                && databaseBirthSeconds == Int64(value.st_birthtimespec.tv_sec)
                && databaseBirthNanos == Int64(value.st_birthtimespec.tv_nsec)
                && databaseSize == value.st_size
                && databaseModifiedSeconds == Int64(value.st_mtimespec.tv_sec)
                && databaseModifiedNanos == Int64(value.st_mtimespec.tv_nsec)
        }
        func matchesLease(_ value: stat) -> Bool {
            leaseInode == UInt64(value.st_ino)
                && leaseBirthSeconds == Int64(value.st_birthtimespec.tv_sec)
                && leaseBirthNanos == Int64(value.st_birthtimespec.tv_nsec)
        }
    }
    private static func encodeOrdinaryDiscard(_ intent: OrdinaryDiscardIntent) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(intent)
        guard !bytes.isEmpty, bytes.count <= 1024 else { throw StorageScanFailure.changed }
        return bytes
    }
    private static func ordinaryVolumeUUID(_ fd: Int32) throws -> UUID {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 40)
        guard fgetattrlist(fd, &attributes, &bytes, bytes.count, 0) == 0 else {
            throw StorageScanFailure.changed
        }
        guard let uuid = try? StartupNativeRoot.decodeVolume(Data(bytes)).value else {
            throw StorageScanFailure.changed
        }
        return uuid
    }
    static func ordinaryDiscardBytes(name: String, pool: Int32, parent: Int32,
                                     database: Int32, lease: Int32) throws -> Data {
        var poolStat = stat(), folder = stat(), db = stat(), owner = stat()
        guard fstat(database, &db) == 0, isPrivateFile(db), db.st_size > 0,
              fstat(lease, &owner) == 0, isPrivateFile(owner), owner.st_size == 0,
              fstat(pool, &poolStat) == 0, isPrivateDirectory(poolStat),
              fstat(parent, &folder) == 0, isPrivateDirectory(folder),
              folder.st_dev == poolStat.st_dev, db.st_dev == folder.st_dev,
              owner.st_dev == folder.st_dev else {
            throw StorageScanFailure.changed
        }
        let volume = try ordinaryVolumeUUID(pool)
        guard try ordinaryVolumeUUID(parent) == volume else { throw StorageScanFailure.changed }
        return try encodeOrdinaryDiscard(.init(name: name, volume: volume,
            directory: folder, database: db, lease: owner))
    }
    private static func decodeOrdinaryDiscard(_ bytes: Data, name: String) throws -> OrdinaryDiscardIntent {
        guard !bytes.isEmpty, bytes.count <= 1024,
              let intent = try? JSONDecoder().decode(OrdinaryDiscardIntent.self, from: bytes),
              (intent.format == "traverse-analysis-ordinary-discard-v1" ||
               intent.format == "traverse-analysis-ordinary-discard-v2"),
              intent.sessionChild == name,
              intent.databaseInode > 0, intent.leaseInode > 0,
              intent.databaseSize > 0,
              intent.databaseBirthSeconds > 0, intent.leaseBirthSeconds > 0,
              intent.databaseBirthNanos >= 0, intent.databaseBirthNanos < 1_000_000_000,
              intent.leaseBirthNanos >= 0, intent.leaseBirthNanos < 1_000_000_000,
              (intent.format == "traverse-analysis-ordinary-discard-v1" &&
                   intent.volumeUUID == nil && intent.directoryInode == nil &&
                   intent.directoryBirthSeconds == nil && intent.directoryBirthNanos == nil &&
                   intent.databaseDevice != nil && intent.leaseDevice != nil ||
               intent.format == "traverse-analysis-ordinary-discard-v2" &&
                   intent.volumeUUID != nil && (intent.directoryInode ?? 0) > 0 &&
                   (intent.directoryBirthSeconds ?? 0) > 0 &&
                   (0..<1_000_000_000).contains(intent.directoryBirthNanos ?? -1) &&
                   intent.databaseDevice == nil && intent.leaseDevice == nil),
              try encodeOrdinaryDiscard(intent) == bytes else { throw StorageScanFailure.changed }
        return intent
    }
    #if DEBUG
    private final class OrdinaryDiscardFault: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        func set(_ value: Bool) { lock.withLock { armed = value } }
        func consume() -> Bool { lock.withLock { let value = armed; armed = false; return value } }
    }
    private static let ordinaryDiscardFault = OrdinaryDiscardFault()
    static func setOrdinaryDiscardAfterDatabaseUnlinkFaultForQualification(_ value: Bool) {
        ordinaryDiscardFault.set(value)
    }
    static func consumeOrdinaryDiscardAfterDatabaseUnlinkFaultForQualification() -> Bool {
        ordinaryDiscardFault.consume()
    }
    #endif
    #if DEBUG
    private final class ColdOpenHook: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (UUID) -> Void)?
        func install(_ value: (@Sendable (UUID) -> Void)?) { lock.withLock { callback = value } }
        func run(_ id: UUID) { lock.withLock { callback }?(id) }
    }
    private static let coldOpenHook = ColdOpenHook()
    static func installColdOpenHookForQualification(_ value: (@Sendable (UUID) -> Void)?) {
        coldOpenHook.install(value)
    }
    #endif
    static func waitForScheduledDiscards() async {
        await withCheckedContinuation { continuation in
            scheduledDiscards.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
    let path: URL, name: String, poolURL: URL
    let pool: Int32, parent: Int32, database: Int32, lease: Int32
    let quota: UInt64
    private var seal: AnalysisStoreSeal?
    private var preserve: Bool
    private let activityGate: FileActivityGate
    private let state = NSLock()
    private var cleanable = false
    private var discardClaimed = false
    private var retainedCloseReceipt: RetainedStoreCloseReceipt?

    init(storage: AnalysisResultStorage, id: UUID, activityGate: FileActivityGate,
         admittedBy: FileActivityGate.Lease? = nil) throws {
        let activity = try activityGate.continueOrBegin(admittedBy)
        defer { withExtendedLifetime(activity) {} }
        let pool = try Self.openPool(storage.directory)
        if storage.retentionStateDirectory != nil {
            var fs = statfs()
            guard fstatfs(pool, &fs) == 0,
                  withUnsafeBytes(of: &fs.f_fstypename, { raw in
                      raw.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8))
                  }) else { close(pool); throw StorageScanFailure.unsupportedLocation }
        }
        var keep = false
        defer { if !keep { close(pool) } }
        let lock = openat(pool, "pool.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StorageScanFailure.unavailable }
        defer { close(lock) }
        var lockStat = stat(), namedLock = stat()
        guard fstat(lock, &lockStat) == 0, Self.isPrivateFile(lockStat),
              flock(lock, LOCK_EX | LOCK_NB) == 0,
              fstatat(pool, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else { throw StorageScanFailure.busy }
        let used = try Self.poolBytes(pool, retentionStateDirectory: storage.retentionStateDirectory)
        guard used <= storage.poolByteLimit - storage.sessionByteLimit else { throw StorageScanFailure.resourceLimit }
        let name = "session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard mkdirat(pool, name, 0o700) == 0 else { throw StorageScanFailure.unavailable }
        let parent = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw StorageScanFailure.unavailable }
        var keepParent = false
        defer { if !keepParent { close(parent) } }
        let database = openat(parent, "result.sqlite", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard database >= 0 else { throw StorageScanFailure.unavailable }
        let lease = openat(parent, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { close(database); throw StorageScanFailure.unavailable }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { close(database); close(lease); throw StorageScanFailure.busy }
        self.pool = pool; self.parent = parent; self.database = database; self.lease = lease
        self.name = name; self.path = storage.directory.appendingPathComponent(name).appendingPathComponent("result.sqlite")
        self.poolURL = storage.directory; quota = storage.sessionByteLimit
        preserve = storage.preserveAfterClose; self.activityGate = activityGate
        keep = true; keepParent = true
        try fresh(sealed: false)
    }

    /// Existing retained catalog, with one EX owner across processes. This
    /// constructor never creates a pool, session, database, lock or journal.
    /// A second warm/cold owner gets Busy before any SQLite open.
    init(openExisting storage: AnalysisResultStorage, id: UUID, expectedBytes: UInt64,
         expectedSHA256: String, activityGate: FileActivityGate) throws {
        let pool = try Self.openExistingPool(storage.directory)
        var keepPool = false
        defer { if !keepPool { close(pool) } }
        let poolLock = openat(pool, "pool.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard poolLock >= 0 else { throw StorageScanFailure.changed }
        defer { close(poolLock) }
        var lockStat = stat(), namedLock = stat()
        guard fstat(poolLock, &lockStat) == 0, Self.isPrivateFile(lockStat),
              flock(poolLock, LOCK_EX | LOCK_NB) == 0,
              fstatat(pool, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else { throw StorageScanFailure.busy }
        let name = "session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parent = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw StorageScanFailure.changed }
        var keepParent = false
        defer { if !keepParent { close(parent) } }
        let database = openat(parent, "result.sqlite", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard database >= 0 else { throw StorageScanFailure.changed }
        var keepDatabase = false
        defer { if !keepDatabase { close(database) } }
        let lease = openat(parent, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard lease >= 0 else { throw StorageScanFailure.changed }
        var keepLease = false
        defer { if !keepLease { close(lease) } }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? StorageScanFailure.busy : StorageScanFailure.changed
        }
        let used = try Self.poolBytes(pool, retentionStateDirectory: storage.retentionStateDirectory)
        guard used <= storage.poolByteLimit else { throw StorageScanFailure.resourceLimit }
        // The EX owner was minted while pool.lock serialized quota admission.
        // Keep that owner and its activity lease, but release the global pool
        // lock before the potentially 2 GiB digest and SQLite validation.
        guard flock(poolLock, LOCK_UN) == 0 else { throw StorageScanFailure.unavailable }
        #if DEBUG
        Self.coldOpenHook.run(id)
        #endif
        self.pool = pool; self.parent = parent; self.database = database; self.lease = lease
        self.name = name; self.path = storage.directory.appendingPathComponent(name).appendingPathComponent("result.sqlite")
        self.poolURL = storage.directory; quota = storage.sessionByteLimit
        preserve = true; self.activityGate = activityGate
        keepPool = true; keepParent = true; keepDatabase = true; keepLease = true
        do {
            try fresh(sealed: true)
            let catalog = try fingerprint(id: id)
            guard catalog.bytes == String(expectedBytes), catalog.sha256 == expectedSHA256 else {
                throw StorageScanFailure.changed
            }
            seal = try AnalysisStoreSeal(database)
            state.withLock { cleanable = true }
        } catch {
            _ = closeRetainingAndReceipt(expectedID: id) // synchronous partial-open drain
            throw error
        }
    }

    /// A pin keeps this object alive while index mutation is in flight. The
    /// preservation barrier is armed BEFORE any stage write or rename.
    func armRetentionPreservation() throws {
        try fresh(sealed: true)
        state.withLock { preserve = true }
    }
    func restoreTemporaryAfterProvenNoMutation() throws {
        try fresh(sealed: true)
        state.withLock { guard !discardClaimed else { return }; preserve = false }
    }
    func closeRetainingAndReceipt(expectedID: UUID) -> RetainedStoreCloseReceipt? {
        let exactName = "session-" + expectedID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard name == exactName else { return nil }
        if let prior = state.withLock({ retainedCloseReceipt }) { return prior }
        let ticket = state.withLock { () -> AnalysisStoreDiscard? in
            guard preserve, !discardClaimed else { return nil }
            discardClaimed = true
            return AnalysisStoreDiscard(pool: pool, parent: parent, database: database, lease: lease,
                path: path, name: name, poolURL: poolURL, quota: quota, seal: seal,
                remove: false, activityGate: activityGate)
        }
        guard let ticket else { return nil }
        ticket.finish() // closes all four held descriptors, never unlinks
        let receipt = RetainedStoreCloseReceipt(catalogID: expectedID, originalSession: expectedID,
            ownerDescriptorClosed: true)
        state.withLock { retainedCloseReceipt = receipt }
        return receipt
    }
    func fingerprint(id: UUID) throws -> RetainedAnalysisRecord.Catalog {
        try fresh(sealed: true)
        var before = stat()
        guard fstat(database, &before) == 0, before.st_size > 0,
              UInt64(before.st_size) <= quota else { throw StorageScanFailure.changed }
        let initialSeal = try AnalysisStoreSeal(database)
        var hasher = SHA256(), bytes = [UInt8](repeating: 0, count: 64 << 10)
        var offset: off_t = 0
        while offset < before.st_size {
            let count = bytes.withUnsafeMutableBytes { pread(database, $0.baseAddress, min($0.count, Int(before.st_size - offset)), offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            hasher.update(data: Data(bytes.prefix(count))); offset += off_t(count)
        }
        try fresh(sealed: true)
        guard try AnalysisStoreSeal(database) == initialSeal,
              fstat(database, &before) == 0, before.st_size == offset else { throw StorageScanFailure.changed }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return try RetainedAnalysisRecord.Catalog(catalogID: id, bytes: UInt64(offset), sha256: digest)
    }

    private static func openExistingPool(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw StorageScanFailure.changed }
        var value = stat(), fs = statfs()
        guard fstat(fd, &value) == 0, isPrivateDirectory(value), fstatfs(fd, &fs) == 0,
              fs.f_flags & UInt32(MNT_LOCAL) != 0,
              withUnsafeBytes(of: &fs.f_fstypename, { raw in
                  raw.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8))
              }) else {
            close(fd); throw StorageScanFailure.unsupportedLocation
        }
        return fd
    }

    /// Call only after the result permanently closes admission and joins every
    /// actual reader. The same verified cleanup is claimed once; uncertainty
    /// preserves names, while descriptors always close before this returns.
    func discardAndClose() { takeDiscard()?.finish() }
    private func takeDiscard() -> AnalysisStoreDiscard? {
        state.withLock {
            guard !discardClaimed else { return nil }
            discardClaimed = true
            return AnalysisStoreDiscard(pool: pool, parent: parent, database: database, lease: lease,
                path: path, name: name, poolURL: poolURL, quota: quota, seal: seal,
                remove: cleanable && !preserve, activityGate: activityGate)
        }
    }
    deinit {
        if let ticket = takeDiscard() {
            Self.scheduledDiscards.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { Self.scheduledDiscards.leave() }; ticket.finish()
            }
        }
    }

    var descriptors: [(Int32, Int32)] { [(4, parent), (5, database), (6, lease)] }
    func fresh(sealed: Bool) throws {
        guard !state.withLock({ discardClaimed }) else { throw StorageScanFailure.unavailable }
        try Self.validate(pool: pool, parent: parent, database: database, lease: lease,
            poolURL: poolURL, name: name, quota: quota, sealed: sealed)
        if sealed, let seal {
            guard try AnalysisStoreSeal(database) == seal else {
                state.withLock { cleanable = false }; throw StorageScanFailure.changed
            }
        }
    }
    func finishWriting() throws {
        try fresh(sealed: true)
        seal = try AnalysisStoreSeal(database)
        state.withLock { cleanable = true }
    }
    func preserveUncertain() { state.withLock { cleanable = false } }

    private static func openPool(_ url: URL) throws -> Int32 {
        let path = url.path, name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw StorageScanFailure.unavailable }
        var fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if fd < 0 && errno == ENOENT {
            let enclosing = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard enclosing >= 0 else { throw StorageScanFailure.unavailable }
            defer { close(enclosing) }
            guard mkdirat(enclosing, name, 0o700) == 0 || errno == EEXIST else { throw StorageScanFailure.unavailable }
            fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard fd >= 0 else { throw StorageScanFailure.unavailable }
        var value = stat(), fs = statfs()
        guard fstat(fd, &value) == 0, isPrivateDirectory(value), fstatfs(fd, &fs) == 0,
              fs.f_flags & UInt32(MNT_LOCAL) != 0 else { close(fd); throw StorageScanFailure.unsupportedLocation }
        return fd
    }
    static func isPrivateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
            && value.st_mode & 0o7777 == 0o600 && value.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED) == 0
    }
    private static func isPrivateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw StorageScanFailure.unavailable
        }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw StorageScanFailure.resourceLimit }
            result.append(name)
        }
        guard errno == 0 else { throw StorageScanFailure.unavailable }; return result
    }
    // Invoked only while the caller holds the pool's verified EX lock and an
    // activity lease. A forged, truncated or live marker refuses admission.
    private static func recoverOrdinaryDiscard(_ pool: Int32, parent: Int32,
                                               name: String, children: Set<String>) throws {
        let allowed = [Set(["discard.intent", "result.sqlite", "owner.lock"]),
                       Set(["discard.intent", "owner.lock"]), Set(["discard.intent"])]
        guard allowed.contains(children) else { throw StorageScanFailure.changed }
        var folder = stat(), namedFolder = stat()
        guard fstat(parent, &folder) == 0, isPrivateDirectory(folder),
              fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
              namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino else {
            throw StorageScanFailure.changed
        }
        var poolStat = stat()
        guard fstat(pool, &poolStat) == 0, isPrivateDirectory(poolStat),
              folder.st_dev == poolStat.st_dev else { throw StorageScanFailure.changed }
        let marker = openat(parent, "discard.intent", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard marker >= 0 else { throw StorageScanFailure.changed }
        defer { close(marker) }
        var first = stat(), last = stat(), named = stat()
        guard fstat(marker, &first) == 0, isPrivateFile(first),
              first.st_size > 0, first.st_size <= 1024 else { throw StorageScanFailure.changed }
        var bytes = Data(count: Int(first.st_size))
        let readCount = bytes.withUnsafeMutableBytes { pread(marker, $0.baseAddress, $0.count, 0) }
        guard readCount == bytes.count,
              fstat(marker, &last) == 0, last.st_dev == first.st_dev,
              last.st_ino == first.st_ino, last.st_size == first.st_size,
              last.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec,
              last.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec,
              fstatat(parent, "discard.intent", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == first.st_dev, named.st_ino == first.st_ino else {
            throw StorageScanFailure.changed
        }
        let intent = try decodeOrdinaryDiscard(bytes, name: name)
        // v1 recorded only st_dev, which can change after restart or name a
        // different volume later. Its partial requires explicit repair; never
        // guess deletion authority from an old device number.
        let volume = try ordinaryVolumeUUID(pool)
        guard try ordinaryVolumeUUID(parent) == volume,
              intent.matchesDirectory(folder, volume: volume),
              first.st_dev == folder.st_dev else { throw StorageScanFailure.changed }
        var lease: Int32 = -1
        if children.contains("owner.lock") {
            lease = openat(parent, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard lease >= 0 else { throw StorageScanFailure.changed }
            var value = stat(), namedLease = stat()
            guard fstat(lease, &value) == 0, isPrivateFile(value), value.st_size == 0,
                  intent.matchesLease(value), value.st_dev == folder.st_dev,
                  flock(lease, LOCK_EX | LOCK_NB) == 0,
                  fstatat(parent, "owner.lock", &namedLease, AT_SYMLINK_NOFOLLOW) == 0,
                  namedLease.st_dev == value.st_dev, namedLease.st_ino == value.st_ino else {
                close(lease); throw StorageScanFailure.changed
            }
        }
        defer { if lease >= 0 { close(lease) } }
        if children.contains("result.sqlite") {
            let database = openat(parent, "result.sqlite", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard database >= 0 else { throw StorageScanFailure.changed }
            defer { close(database) }
            var value = stat(), namedDatabase = stat()
            guard fstat(database, &value) == 0, isPrivateFile(value),
                  intent.matchesDatabase(value), value.st_dev == folder.st_dev,
                  fstatat(parent, "result.sqlite", &namedDatabase, AT_SYMLINK_NOFOLLOW) == 0,
                  namedDatabase.st_dev == value.st_dev, namedDatabase.st_ino == value.st_ino,
                  unlinkat(parent, "result.sqlite", 0) == 0,
                  fsync(parent) == 0 else { throw StorageScanFailure.changed }
        }
        if lease >= 0 {
            guard unlinkat(parent, "owner.lock", 0) == 0,
                  fsync(parent) == 0 else { throw StorageScanFailure.changed }
        }
        guard unlinkat(parent, "discard.intent", 0) == 0,
              fsync(parent) == 0,
              fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
              namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
              unlinkat(pool, name, AT_REMOVEDIR) == 0,
              fsync(pool) == 0 else { throw StorageScanFailure.changed }
    }
    // Earlier ordinary discard unlinked the database before the owner lock.
    // With no database, journal or other names, this old partial contains
    // only our empty lock metadata. Fsync its observed absence before deleting
    // the lock. Pool EX excludes a constructor; owner EX excludes a live result.
    private static func recoverLegacyEmptyOrdinary(_ pool: Int32, parent: Int32,
                                                   name: String) throws {
        var folder = stat(), namedFolder = stat()
        guard fstat(parent, &folder) == 0, isPrivateDirectory(folder),
              fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
              namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
              Set(try names(parent, maximum: 2)) == Set(["owner.lock"]) else {
            throw StorageScanFailure.changed
        }
        let owner = openat(parent, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard owner >= 0 else { throw StorageScanFailure.changed }
        defer { close(owner) }
        var lock = stat(), namedLock = stat()
        guard fstat(owner, &lock) == 0, isPrivateFile(lock), lock.st_size == 0,
              lock.st_dev == folder.st_dev, flock(owner, LOCK_EX | LOCK_NB) == 0,
              fstatat(parent, "owner.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lock.st_dev, namedLock.st_ino == lock.st_ino,
              fsync(parent) == 0,
              unlinkat(parent, "owner.lock", 0) == 0,
              fsync(parent) == 0,
              fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
              namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
              unlinkat(pool, name, AT_REMOVEDIR) == 0,
              fsync(pool) == 0 else { throw StorageScanFailure.changed }
    }
    private static func poolBytes(_ pool: Int32, retentionStateDirectory: URL?) throws -> UInt64 {
        var bytes: UInt64 = 0
        var retained = try retainedReservations(retentionStateDirectory)
        for name in try names(pool, maximum: 4096) where name != "pool.lock" {
            let token = name.dropFirst(8)
            guard name.hasPrefix("session-"), token.utf8.count == 32,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StorageScanFailure.changed }
            let fd = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw StorageScanFailure.changed }; defer { close(fd) }
            var folder = stat(); guard fstat(fd, &folder) == 0, isPrivateDirectory(folder) else { throw StorageScanFailure.changed }
            let children = try names(fd, maximum: 4)
            let indexed = retained.indexed.contains(name)
            if children.isEmpty && !indexed {
                // An empty unindexed directory can only be left by interrupted
                // creation or by the final ordinary rmdir after marker unlink;
                // pool EX excludes a creator still between those steps.
                var namedFolder = stat()
                guard fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
                      namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
                      unlinkat(pool, name, AT_REMOVEDIR) == 0,
                      fsync(pool) == 0 else { throw StorageScanFailure.changed }
                continue
            }
            if children.contains("discard.intent") {
                guard !indexed else { throw StorageScanFailure.changed }
                try recoverOrdinaryDiscard(pool, parent: fd, name: name,
                    children: Set(children))
                continue
            }
            if !indexed && Set(children) == Set(["owner.lock"]) {
                try recoverLegacyEmptyOrdinary(pool, parent: fd, name: name)
                continue
            }
            let tombstoned = retained.tombstones.contains(name)
            var sessionBytes: UInt64 = 0
            var sawDatabase = false, sawLease = false
            for file in children {
                if file == "result.sqlite" { sawDatabase = true }
                if file == "owner.lock" { sawLease = true }
                guard ["result.sqlite", "owner.lock", "result.sqlite-journal"].contains(file) else { throw StorageScanFailure.changed }
                var value = stat()
                guard fstatat(fd, file, &value, AT_SYMLINK_NOFOLLOW) == 0, isPrivateFile(value), value.st_size >= 0,
                      value.st_blocks >= 0, UInt64(value.st_blocks) <= AnalysisResultStorage.maximumPoolBytes / 512 else { throw StorageScanFailure.changed }
                let charged = max(UInt64(value.st_size), UInt64(value.st_blocks) * 512)
                let (sum, overflow) = sessionBytes.addingReportingOverflow(charged)
                guard !overflow else { throw StorageScanFailure.resourceLimit }; sessionBytes = sum
            }
            // Only the exact states this cleanup sequence can leave after
            // removing the database are recoverable. No non-tombstoned or
            // retention-disabled caller can treat a partial store as credit.
            let recoverablePartial = tombstoned && !sawDatabase &&
                (Set(children) == Set(["owner.lock"]) || children.isEmpty)
            guard sawDatabase && sawLease || recoverablePartial else { throw StorageScanFailure.changed }
            if recoverablePartial && sawLease {
                var remaining = stat()
                guard fstatat(fd, "owner.lock", &remaining, AT_SYMLINK_NOFOLLOW) == 0,
                      isPrivateFile(remaining), remaining.st_size == 0 else { throw StorageScanFailure.changed }
            }
            // A live owner may still grow its file after this inventory. Count
            // its full possible reservation, including a retained result with
            // readers. Independent scanner instances cannot oversubscribe the
            // pool by all observing newly empty stores at the same time.
            let lease = openat(fd, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            var leased = false
            if lease >= 0 {
                defer { close(lease) }
                var value = stat()
                guard fstat(lease, &value) == 0, isPrivateFile(value) else { throw StorageScanFailure.changed }
                if flock(lease, LOCK_EX | LOCK_NB) != 0 {
                    guard errno == EWOULDBLOCK else { throw StorageScanFailure.changed }; leased = true
                }
            } else if errno != ENOENT { throw StorageScanFailure.changed }
            // Every indexed catalog reserves its full possible session quota.
            // A visible cold catalog can become a tombstone while an unrelated
            // scanner is admitting under pool.lock; its charge must not jump.
            let indexedCharge = retained.indexed.remove(name) != nil
            let charge = indexedCharge ? max(sessionBytes, AnalysisResultStorage.maximumSessionBytes) : poolCharge(sessionBytes, leased: leased)
            let (sum, overflow) = bytes.addingReportingOverflow(charge)
            guard !overflow else { throw StorageScanFailure.resourceLimit }; bytes = sum
        }
        // Indexed evidence may name a catalog whose final unlink/sync was
        // uncertain. Keep its full reservation even if no directory is visible.
        for _ in retained.indexed {
            let (sum, overflow) = bytes.addingReportingOverflow(AnalysisResultStorage.maximumSessionBytes)
            guard !overflow else { throw StorageScanFailure.resourceLimit }; bytes = sum
        }
        return bytes
    }
    private struct RetainedReservations {
        var indexed: Set<String>
        let tombstones: Set<String>
    }
    private static func retainedReservations(_ url: URL?) throws -> RetainedReservations {
        guard let url else { return .init(indexed: [], tombstones: []) }
        let directory = try openExistingPool(url)
        defer { close(directory) }
        let base = Set(["index.json", "index.lock"])
        let entries = Set(try names(directory, maximum: 4))
        let hasIntent = entries.contains("publication.intent")
        guard entries == base || hasIntent &&
              (entries == base.union(["publication.intent"]) ||
               entries == base.union(["publication.intent", "index.stage"])) else {
            throw StorageScanFailure.changed
        }
        if entries.contains("index.stage") {
            guard try RetainedNativeIndexStore.validateStageIfPresent(directory) else {
                throw StorageScanFailure.changed
            }
        }
        let intent = hasIntent ? try RetainedNativeIndexStore.readValidatedPublicationIntent(directory) : nil
        let lock = openat(directory, "index.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let image = openat(directory, "index.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0, image >= 0 else {
            if lock >= 0 { close(lock) }; if image >= 0 { close(image) }
            throw StorageScanFailure.changed
        }
        defer { close(lock); close(image) }
        var lockStat = stat(), imageStat = stat(), named = stat()
        guard fstat(lock, &lockStat) == 0, isPrivateFile(lockStat),
              fstat(image, &imageStat) == 0, isPrivateFile(imageStat),
              imageStat.st_size > 0, imageStat.st_size <= Int64(RetainedAnalysisIndex.maximumEncodedBytes),
              fstatat(directory, "index.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == imageStat.st_dev, named.st_ino == imageStat.st_ino else { throw StorageScanFailure.changed }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Int(imageStat.st_size) {
            let count = buffer.withUnsafeMutableBytes { read(image, $0.baseAddress, min($0.count, Int(imageStat.st_size) - data.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstatat(directory, "index.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == imageStat.st_dev, named.st_ino == imageStat.st_ino else { throw StorageScanFailure.changed }
        let index = try RetainedAnalysisIndex.decodeCanonical(data)
        if let intent {
            guard let expected = intent.epoch else { throw StorageScanFailure.changed }
            if index.visibleRecords.contains(where: { $0.catalog == intent.catalog }) {
                let next = expected.addingReportingOverflow(1)
                guard !next.overflow, index.epoch == next.partialValue,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                          == intent.proposedSHA256 else { throw StorageScanFailure.changed }
            } else {
                guard index.epoch == expected,
                      !index.visibleRecords.contains(where: { $0.catalogID == intent.catalog.catalogID }),
                      index.retiring?.catalog.catalogID != intent.catalog.catalogID,
                      !index.pendingForget.contains(where: { $0.catalog.catalogID == intent.catalog.catalogID }) else {
                    throw StorageScanFailure.changed
                }
            }
        }
        // An unresolved publication intent reserves the full 2 GiB even if
        // the catalog directory has been partially removed or is absent.
        let intentName = intent.map { [$0.catalog.sessionChild] } ?? []
        let tombstones = Set(index.pendingForget.map { $0.catalog.sessionChild } +
                             (index.retiring.map { [$0.catalog.sessionChild] } ?? []) + intentName)
        return .init(indexed: Set(index.visibleRecords.map { $0.catalog.sessionChild }).union(tombstones),
                     tombstones: tombstones)
    }

    static func poolCharge(_ observed: UInt64, leased: Bool) -> UInt64 {
        // Reserve the supported maximum for a live session, including smaller
        // generated-test sessions. This conservative rule needs no new lease
        // format and still works across independent app/scanner processes.
        leased ? max(observed, AnalysisResultStorage.maximumSessionBytes) : observed
    }
    static func validate(pool: Int32, parent: Int32, database: Int32, lease: Int32,
                         poolURL: URL, name: String, quota: UInt64, sealed: Bool) throws {
        let currentPool = open(poolURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard currentPool >= 0 else { throw StorageScanFailure.changed }; defer { close(currentPool) }
        var p = stat(), current = stat(), folder = stat(), databaseStat = stat(), leaseStat = stat()
        func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
        guard fstat(pool, &p) == 0, fstat(currentPool, &current) == 0, same(p, current), isPrivateDirectory(p),
              fstat(parent, &folder) == 0, isPrivateDirectory(folder),
              fstatat(pool, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(folder, current),
              fstat(database, &databaseStat) == 0, isPrivateFile(databaseStat),
              fstatat(parent, "result.sqlite", &current, AT_SYMLINK_NOFOLLOW) == 0, same(databaseStat, current), isPrivateFile(current),
              fstat(lease, &leaseStat) == 0, isPrivateFile(leaseStat),
              fstatat(parent, "owner.lock", &current, AT_SYMLINK_NOFOLLOW) == 0, same(leaseStat, current), isPrivateFile(current),
              flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw StorageScanFailure.changed }
        var bytes: UInt64 = 0
        for entry in try names(parent, maximum: 3) {
            guard ["result.sqlite", "owner.lock"].contains(entry) || !sealed && entry == "result.sqlite-journal" else { throw StorageScanFailure.changed }
            var s = stat()
            guard fstatat(parent, entry, &s, AT_SYMLINK_NOFOLLOW) == 0, isPrivateFile(s), s.st_dev == folder.st_dev,
                  s.st_size >= 0, s.st_blocks >= 0, UInt64(s.st_blocks) <= quota / 512 else { throw StorageScanFailure.changed }
            let charged = max(UInt64(s.st_size), UInt64(s.st_blocks) * 512)
            guard charged <= quota, bytes <= quota - charged else { throw StorageScanFailure.resourceLimit }; bytes += charged
        }
    }
}

private struct AnalysisStoreSeal: Equatable, Sendable {
    let size: Int64, modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
    init(_ fd: Int32) throws {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw StorageScanFailure.unavailable }
        size = value.st_size; modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class AnalysisStoreDiscard: @unchecked Sendable {
    let pool: Int32, parent: Int32, database: Int32, lease: Int32
    let path: URL, name: String, poolURL: URL, quota: UInt64, seal: AnalysisStoreSeal?
    let remove: Bool, activityGate: FileActivityGate
    init(pool: Int32, parent: Int32, database: Int32, lease: Int32, path: URL, name: String,
         poolURL: URL, quota: UInt64, seal: AnalysisStoreSeal?, remove: Bool, activityGate: FileActivityGate) {
        self.pool = pool; self.parent = parent; self.database = database; self.lease = lease
        self.path = path; self.name = name; self.poolURL = poolURL; self.quota = quota; self.seal = seal
        self.remove = remove; self.activityGate = activityGate
    }
    func finish() {
        defer { close(database); close(lease); close(parent); close(pool) }
        guard remove, let seal, let activity = try? activityGate.begin() else { return }
        defer { withExtendedLifetime(activity) {} }
        let lock = openat(pool, "pool.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard lock >= 0 else { return }; defer { close(lock) }
        var lockStat = stat(), namedLock = stat()
        guard fstat(lock, &lockStat) == 0, AnalysisStoreFiles.isPrivateFile(lockStat),
              flock(lock, LOCK_EX | LOCK_NB) == 0,
              fstatat(pool, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else { return }
        do {
            try AnalysisStoreFiles.validate(pool: pool, parent: parent, database: database, lease: lease,
                poolURL: poolURL, name: name, quota: quota, sealed: true)
            guard try AnalysisStoreSeal(database) == seal else { return }
            let markerBytes = try AnalysisStoreFiles.ordinaryDiscardBytes(
                name: name, pool: pool, parent: parent, database: database, lease: lease)
            // Fsync the exact ordinary discard decision before the first
            // unlink. Recovery never guesses from an unmarked partial store.
            let marker = openat(parent, "discard.intent",
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard marker >= 0 else { return }
            defer { close(marker) }
            let wrote = markerBytes.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(marker, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard wrote, fsync(marker) == 0, fsync(parent) == 0 else { return }
            // No recursive removal, journal recovery, wildcard or source access.
            // Unknown/changed names or an incomplete writer preserve the store.
            guard unlinkat(parent, "result.sqlite", 0) == 0,
                  fsync(parent) == 0 else { return }
            #if DEBUG
            if AnalysisStoreFiles.consumeOrdinaryDiscardAfterDatabaseUnlinkFaultForQualification() { return }
            #endif
            guard unlinkat(parent, "owner.lock", 0) == 0,
                  fsync(parent) == 0 else { return }
            guard unlinkat(parent, "discard.intent", 0) == 0,
                  fsync(parent) == 0 else { return }
            var folder = stat(), namedFolder = stat()
            guard fstat(parent, &folder) == 0,
                  fstatat(pool, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
                  namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
                  unlinkat(pool, name, AT_REMOVEDIR) == 0 else { return }
            _ = fsync(pool)
        } catch { return }
    }
}
