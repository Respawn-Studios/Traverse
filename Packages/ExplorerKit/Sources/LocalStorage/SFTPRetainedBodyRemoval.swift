import CryptoKit
import Darwin
import Foundation

/// The only partial namespace accepted is the exact monotone unlink prefix
/// captured BEFORE mutation in the canonical ledger's durable intent.
enum SFTPRetainedBodyRemoval {
    static let order = ["payload", "owner.lock", "session.meta"]
    static func inspect(pool: Int32, body: SFTPRetainedBodyIntent, hash: Bool) throws -> Int32? {
        let name = "download-" + body.reference.id.uuidString
        let fd = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if fd < 0 {
            guard errno == ENOENT else { throw SFTPSharedBudgetFailure.unsafe }
            return nil
        }
        var keep = false; defer { if !keep { Darwin.close(fd) } }
        var directory = stat()
        guard fstat(fd, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o7777 == 0o700, directory.st_uid == geteuid(),
              body.folder.matches(try DownloadDisk.identity(fd)) else { throw SFTPSharedBudgetFailure.stale }
        var linked = stat()
        guard fstatat(pool, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              body.folder.matches(DownloadDisk.Identity(linked)) else { throw SFTPSharedBudgetFailure.stale }
        let names = try DownloadDisk.names(fd, maximum: 3), present = Set(names)
        guard let first = order.firstIndex(where: { present.contains($0) }) ?? (present.isEmpty ? order.count : nil),
              present == Set(order.dropFirst(first)) else { throw SFTPSharedBudgetFailure.unsafe }
        for file in names {
            guard fstatat(fd, file, &linked, AT_SYMLINK_NOFOLLOW) == 0, DownloadDisk.privateFile(linked),
                  body.files[file]?.matches(DownloadDisk.Identity(linked)) == true,
                  Int64(linked.st_dev) == body.folder.device,
                  linked.st_size <= (file == "payload" ? Int64(body.reference.logicalBytes) : file == "owner.lock" ? 0 : 2048) else { throw SFTPSharedBudgetFailure.stale }
        }
        if present.contains("session.meta") {
            let marker = openat(fd, "session.meta", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard marker >= 0 else { throw SFTPSharedBudgetFailure.unsafe }; defer { Darwin.close(marker) }
            var bytes = Data(count: body.marker.count); let count = bytes.count
            var markerFacts = stat()
            guard fstat(marker, &markerFacts) == 0, markerFacts.st_size == count, body.files["session.meta"]?.matches(try DownloadDisk.identity(marker)) == true,
                  bytes.withUnsafeMutableBytes({ pread(marker, $0.baseAddress, count, 0) }) == count,
                  bytes == body.marker else { throw SFTPSharedBudgetFailure.stale }
        }
        if hash && present.contains("payload") { try checkDigest(folder: fd, body: body) }
        keep = true; return fd
    }
    static func checkDigest(folder: Int32, body: SFTPRetainedBodyIntent) throws {
        let payload = openat(folder, "payload", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard payload >= 0 else { throw SFTPSharedBudgetFailure.unsafe }; defer { Darwin.close(payload) }
        let before = try DownloadDisk.stamp(payload)
        guard body.files["payload"]?.matches(before.identity) == true, before.size == Int64(body.reference.logicalBytes) else { throw SFTPSharedBudgetFailure.stale }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < body.reference.logicalBytes {
            try Task.checkCancellation()
            var bytes = Data(count: Int(min(32768, body.reference.logicalBytes - offset))); let count = bytes.count
            let found = bytes.withUnsafeMutableBytes { pread(payload, $0.baseAddress, count, off_t(offset)) }
            if found < 0 && errno == EINTR { continue }
            guard found == count else { throw SFTPSharedBudgetFailure.unsafe }
            hash.update(data: bytes); offset += UInt64(found)
        }
        guard Data(hash.finalize()) == body.reference.digest, try DownloadDisk.stamp(payload) == before else { throw SFTPSharedBudgetFailure.stale }
    }
    /// Called only through removeOriginalBody with the held catalog authority.
    /// Missing lease is accepted only AFTER this exact intent's unlink prefix
    /// proves payload+lease were already removed. No new lease is fabricated.
    static func remove(pool: Int32, body: SFTPRetainedBodyIntent, heldLease: Int32?) throws {
        guard let folder = try inspect(pool: pool, body: body, hash: true) else {
            guard fsync(pool) == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }; return
        }
        defer { Darwin.close(folder) }
        let present = Set(try DownloadDisk.names(folder, maximum: 3))
        if present.contains("owner.lock") {
            guard let heldLease, body.files["owner.lock"]?.matches(try DownloadDisk.identity(heldLease)) == true,
                  flock(heldLease, LOCK_EX | LOCK_NB) == 0 else { throw SFTPSharedBudgetFailure.busy }
        } else { guard !present.contains("payload") else { throw SFTPSharedBudgetFailure.unsafe } }
        var payloadLease: Int32 = -1
        defer { if payloadLease >= 0 { Darwin.close(payloadLease) } }
        if present.contains("payload") {
            payloadLease = openat(folder, "payload", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard payloadLease >= 0,
                  body.files["payload"]?.matches(try DownloadDisk.identity(payloadLease)) == true,
                  flock(payloadLease, LOCK_EX | LOCK_NB) == 0 else { throw SFTPSharedBudgetFailure.busy }
        }
        for file in order where present.contains(file) {
            try Task.checkCancellation()
            var facts = stat()
            guard fstatat(folder, file, &facts, AT_SYMLINK_NOFOLLOW) == 0, DownloadDisk.privateFile(facts),
                  body.files[file]?.matches(DownloadDisk.Identity(facts)) == true,
                  unlinkat(folder, file, 0) == 0 else { throw SFTPSharedBudgetFailure.stale }
            #if DEBUG
            try SFTPRetainedRemovalQualification.shared.reach(file == "payload" ? .payloadUnlinked : file == "owner.lock" ? .leaseUnlinked : .markerUnlinked)
            #endif
            guard fsync(folder) == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }
        }
        var linked = stat()
        guard fstatat(pool, "download-" + body.reference.id.uuidString, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              body.folder.matches(DownloadDisk.Identity(linked)),
              unlinkat(pool, "download-" + body.reference.id.uuidString, AT_REMOVEDIR) == 0 else { throw SFTPSharedBudgetFailure.stale }
        #if DEBUG
        try SFTPRetainedRemovalQualification.shared.reach(.folderRemoved)
        #endif
        guard fsync(pool) == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }
        #if DEBUG
        try SFTPRetainedRemovalQualification.shared.reach(.directorySynchronized)
        #endif
    }
    static func inventory(pool: Int32, document: SFTPSharedBudgetDocument) throws -> [DownloadDisk.Record] {
        let pending = document.retirements ?? []
        var result: [DownloadDisk.Record] = []
        let maximum = document.format == 3 ? SFTPSharedBudgetDocument.expandedBodySlots + 2 : 10
        for name in try DownloadDisk.names(pool, maximum: maximum) where name != "pool.lock" && name != SFTPSharedBudgetTransaction.bodyFence {
            if let intent = pending.first(where: { $0.bodies.contains(where: { "download-" + $0.reference.id.uuidString == name }) }),
               let body = intent.bodies.first(where: { "download-" + $0.reference.id.uuidString == name }) {
                guard intent.stage == .deleting else { throw SFTPSharedBudgetFailure.stale }
                if let fd = try inspect(pool: pool, body: body, hash: false) {
                    defer { Darwin.close(fd) }
                    if Set(try DownloadDisk.names(fd, maximum: 3)) == Set(order) { result.append(try DownloadDisk.record(pool, name: name)) }
                }
            } else { result.append(try DownloadDisk.record(pool, name: name)) }
        }
        return result
    }
}
