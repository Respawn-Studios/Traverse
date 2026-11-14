import Darwin
import Foundation

/// Every live shared owner reserves one slot. Dropping a lifetime owner
/// without explicit close retains its actual SH descriptor until process exit.
private final class SFTPOriginalLeaseQuarantine: @unchecked Sendable {
    static let shared = SFTPOriginalLeaseQuarantine()
    private let lock = NSLock()
    private var reservations = 0
    private var held: [Int32] = []
    func reserve() throws {
        try lock.withLock {
            guard reservations < 256 else { throw SFTPTextFailure.busy }
            reservations += 1
        }
    }
    func release() { lock.withLock { precondition(reservations > 0); reservations -= 1 } }
    func retain(_ descriptor: Int32) {
        lock.withLock {
            precondition(held.count < reservations && reservations <= 256)
            held.append(descriptor)
        }
    }
}

/// Owns the actual body pool EX lock, not a caller assertion or duplicated
/// flock descriptor. A duplicate directory fd only pins the same directory.
final class SFTPOriginalBodyPoolExclusive {
    private let pool: Int32, lease: Int32, identity: DownloadDisk.Identity, lockIdentity: DownloadDisk.Identity
    init(pool: Int32) throws {
        let copy = dup(pool); guard copy >= 0 else { throw SFTPTextFailure.changed }
        var keep = false; defer { if !keep { Darwin.close(copy) } }
        let lease = try SMBCatalogFiles.lockPool(pool, create: false)
        do {
            self.pool = copy; self.lease = lease; identity = try DownloadDisk.identity(pool)
            lockIdentity = try DownloadDisk.identity(lease); keep = true
        } catch { Darwin.close(lease); throw error }
    }
    func validate(pool: Int32) throws {
        var named = stat()
        guard try DownloadDisk.identity(pool) == identity, try DownloadDisk.identity(self.pool) == identity,
              try DownloadDisk.identity(lease) == lockIdentity,
              fstatat(pool, "pool.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              DownloadDisk.Identity(named) == lockIdentity else { throw SFTPTextFailure.changed }
    }
    deinit { Darwin.close(lease); Darwin.close(pool) }
}

extension DownloadDisk {
    /// Constructor always performs a real SH acquisition. Inventory accepts
    /// this owned type without ever probing/upgrading its lock to EX.
    final class SharedOriginalLease: @unchecked Sendable {
        private let lock = NSLock(), descriptor: Int32, identity: Identity
        private var closed = false
        private init(descriptor: Int32, identity: Identity) { self.descriptor = descriptor; self.identity = identity }
        static func acquire(folder: Int32, expected: Identity) throws -> SharedOriginalLease {
            try SFTPOriginalLeaseQuarantine.shared.reserve()
            var quotaTransferred = false
            defer { if !quotaTransferred { SFTPOriginalLeaseQuarantine.shared.release() } }
            let fd = openat(folder, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw SFTPTextFailure.changed }
            var keep = false; defer { if !keep { Darwin.close(fd) } }
            var facts = stat()
            guard fstat(fd, &facts) == 0, DownloadDisk.privateFile(facts), facts.st_size == 0,
                  try DownloadDisk.identity(fd) == expected else { throw SFTPTextFailure.changed }
            if flock(fd, LOCK_SH | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK { throw SFTPTextFailure.busy }; throw SFTPTextFailure.changed
            }
            keep = true; quotaTransferred = true; return .init(descriptor: fd, identity: expected)
        }
        func validateShared(expected: Identity) throws {
            try lock.withLock {
                var facts = stat()
                guard !closed, identity == expected, fstat(descriptor, &facts) == 0, DownloadDisk.privateFile(facts), facts.st_size == 0,
                      try DownloadDisk.identity(descriptor) == identity else { throw SFTPTextFailure.changed }
                // Never convert this descriptor to EX. The buffer closes its
                // SH before guarded deletion obtains an independent owner EX.
            }
        }
        func closeAfterDrain() -> Bool {
            lock.withLock {
                if !closed {
                    Darwin.close(descriptor); closed = true
                    SFTPOriginalLeaseQuarantine.shared.release()
                }
                return true
            }
        }
        deinit { if !closed { SFTPOriginalLeaseQuarantine.shared.retain(descriptor) } }
    }
    /// A lifetime owner SH does not count as a cold read. A genuine reader
    /// owns owner SH + payload EX. Owner EX writers/retirement do not count.
    static func activeOriginalPayloadReaders(_ pool: Int32, records: [Record]) throws -> Int {
        var count = 0
        for record in records {
            guard record.files["payload"] != nil else { continue }
            let folder = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard folder >= 0 else { throw SFTPTextFailure.changed }; defer { Darwin.close(folder) }
            guard try identity(folder) == record.folder, let expected = record.files["owner.lock"] else { throw SFTPTextFailure.changed }
            let owner: SharedOriginalLease
            do { owner = try SharedOriginalLease.acquire(folder: folder, expected: expected) }
            catch SFTPTextFailure.busy { continue }
            defer { _ = owner.closeAfterDrain() }
            let payload = openat(folder, "payload", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard payload >= 0 else { throw SFTPTextFailure.changed }; defer { Darwin.close(payload) }
            guard try identity(payload) == record.files["payload"] else { throw SFTPTextFailure.changed }
            if flock(payload, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw SFTPTextFailure.changed }; count += 1
            }
        }
        return count
    }
}
