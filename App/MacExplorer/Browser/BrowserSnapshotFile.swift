import Darwin
import Foundation

/// Private, bounded UI snapshots. Callers serialize work off the main actor.
/// Directory descriptors prevent path redirection; rechecks reject observed
/// replacement. Existing-target rename/unlink is not a hostile-writer CAS.
struct BrowserSnapshotFile: Sendable {
    let directory: URL
    let name: String
    let maximumBytes: Int
    var requiresPrivateDurability = false
    /// New strict catalogs can require the existing coordination inode. A read
    /// must not silently operate without it or repair it during passive launch.
    var requiresExistingWriterLock = false
    enum Failure: Error { case unsafePath, invalidDocument, oversized, writerBusy }
    enum ExpectedVersion: Sendable { case absent, bytes(Data) }
    enum WriteBoundary { case staged, validated, published, synchronized }

    func read(expectDocumentInExistingDirectory: Bool = false) throws -> Data? {
        guard let parent = try openParent(create: false) else { return nil }
        let lease = try requiresPrivateDurability ? FileLock.acquire(in: parent, name: name + ".writer-lock", exclusive: false, create: false) : nil
        defer { withExtendedLifetime(lease) {} }
        let result = try observe(in: parent)
        guard result == nil || !requiresExistingWriterLock || lease != nil else { throw Failure.unsafePath }
        guard result != nil || !expectDocumentInExistingDirectory else { throw Failure.invalidDocument }
        try parent.revalidate()
        try lease?.validate()
        return result?.data
    }

    func write(_ data: Data, replacing expected: ExpectedVersion? = nil,
               checkpoint: (WriteBoundary) throws -> Void = { _ in }, validating validate: (Data) throws -> Void) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.oversized }
        try validate(data)
        guard let parent = try openParent(create: true) else { throw Failure.unsafePath }
        let lease = try requiresPrivateDurability ? FileLock.acquire(in: parent, name: name + ".writer-lock", exclusive: true, create: !requiresExistingWriterLock) : nil
        defer { withExtendedLifetime(lease) {} }
        guard !requiresExistingWriterLock || lease != nil else { throw Failure.unsafePath }
        let original = try observe(in: parent)
        switch (expected, original?.data) {
        case (nil, _), (.absent?, nil): break
        case let (.bytes(previous)?, current?) where previous == current: break
        default: throw Failure.unsafePath
        }
        if let original { try validate(original.data) }
        try revalidate(original, in: parent)
        let temporary = ".snapshot-\(UUID().uuidString).tmp"
        let fd = openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafePath }
        defer { close(fd) }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { throw Failure.unsafePath }
        defer {
            var current = stat()
            if fstatat(parent.fd, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
               Self.sameIdentity(current, identity) { _ = unlinkat(parent.fd, temporary, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unsafePath }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.unsafePath }
        try checkpoint(.staged)
        // Validate the current document as well as its identity/content. A newer
        // or invalid document is never intentionally overwritten.
        if let current = try observe(in: parent) { try validate(current.data) }
        try revalidate(original, in: parent)
        var currentTemporary = stat()
        guard fstatat(parent.fd, temporary, &currentTemporary, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameIdentity(currentTemporary, identity) else { throw Failure.unsafePath }
        try checkpoint(.validated)
        try lease?.validate()
        let result: Int32
        if original == nil {
            // An unexpected arrival must not be silently replaced.
            result = renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_EXCL))
        } else {
            result = renameat(parent.fd, temporary, parent.fd, name)
        }
        guard result == 0 else { throw Failure.unsafePath }
        try checkpoint(.published)
        if requiresPrivateDurability {
            try Self.synchronizeDirectory(parent.fd)
            try parent.revalidate()
            guard try observe(in: parent)?.data == data else { throw Failure.unsafePath }
        }
        try checkpoint(.synchronized)
        try lease?.validate()
    }

    /// A bounded UI-state session lease, separate from the short data-file
    /// transaction lock. Acquire/validate/release only on the storage worker.
    /// The inode stays in place; unlinking it would defeat cooperative locking.
    final class LifetimeLease: @unchecked Sendable {
        fileprivate let lock: FileLock
        fileprivate init(_ lock: FileLock) { self.lock = lock }
        func validate() throws { try lock.validate() }
    }
    func acquireMutationLease(create: Bool = false) throws -> LifetimeLease? {
        guard requiresPrivateDurability else { throw Failure.unsafePath }
        guard let parent = try openParent(create: create),
              let lock = try FileLock.acquire(in: parent, name: name + ".mutation-lock", exclusive: true, create: create) else { return nil }
        return LifetimeLease(lock)
    }
    func acquireLifetimeLease(_ id: UUID, create: Bool = false, creatingInventory: Bool = false) throws -> LifetimeLease? {
        guard requiresPrivateDurability else { throw Failure.unsafePath }
        guard let parent = try openParent(create: create),
              let inventory = try FileLock.acquire(in: parent, name: name + ".session-inventory.lock", exclusive: true, create: creatingInventory) else { return nil }
        defer { withExtendedLifetime(inventory) {} }
        if create { try boundLifetimeInventory(in: parent) }
        guard let lock = try FileLock.acquire(in: parent, name: name + ".session-" + id.uuidString + ".lock",
            exclusive: true, create: create) else { return nil }
        return LifetimeLease(lock)
    }

    /// Only after the record is durably removed. Every cooperating acquisition
    /// takes the same inventory gate, so no incoming owner can retain the old
    /// inode while a new owner opens a replacement at this name.
    func retireLifetimeLease(_ lease: LifetimeLease) throws {
        guard requiresPrivateDurability, let parent = try openParent(create: false) else { throw Failure.unsafePath }
        let lock = lease.lock
        guard lock.name.hasPrefix(name + ".session-"), lock.name.hasSuffix(".lock") else { throw Failure.unsafePath }
        var expected = stat(), actual = stat()
        guard fstat(parent.fd, &expected) == 0, fstat(lock.parent.fd, &actual) == 0,
              Self.sameIdentity(expected, actual),
              let inventory = try FileLock.acquire(in: parent, name: name + ".session-inventory.lock", exclusive: true, create: false) else { throw Failure.unsafePath }
        defer { withExtendedLifetime(inventory) {} }
        try inventory.validate(); try lease.validate()
        guard unlinkat(parent.fd, lock.name, 0) == 0 else { throw Failure.unsafePath }
        try Self.synchronizeDirectory(parent.fd); try parent.revalidate(); try inventory.validate()
    }

    private func boundLifetimeInventory(in parent: Parent) throws {
        let fd = openat(parent.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        guard let stream = fdopendir(fd) else { close(fd); throw Failure.unsafePath }
        defer { closedir(stream) }
        var count = 0, inspected = 0
        errno = 0
        while let entry = readdir(stream) {
            inspected += 1
            guard inspected <= 256 else { throw Failure.oversized }
            let value = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if value.hasPrefix(name + ".session-"), value != name + ".session-inventory.lock" { count += 1 }
            guard count < 64 else { throw Failure.oversized }
            errno = 0
        }
        guard errno == 0 else { throw Failure.unsafePath }
        try parent.revalidate()
    }

    func forget(validating validate: (Data) throws -> Void) throws {
        // Strong private catalogs use an acknowledged empty document instead
        // of an uncoordinated unlink that could erase another owner's edit.
        guard !requiresPrivateDurability else { throw Failure.unsafePath }
        guard let parent = try openParent(create: false), let original = try observe(in: parent) else { return }
        try validate(original.data)
        try revalidate(original, in: parent)
        guard unlinkat(parent.fd, name, 0) == 0 else { throw Failure.unsafePath }
    }

    private struct Observation {
        let data: Data
        let metadata: stat
    }

    private func observe(in parent: Parent) throws -> Observation? {
        let fd = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw Failure.invalidDocument }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              !requiresPrivateDurability || (before.st_uid == geteuid() && before.st_nlink == 1 && before.st_mode & 0o077 == 0),
              before.st_size > 0, before.st_size <= maximumBytes,
              let data = try handle.read(upToCount: maximumBytes + 1), data.count == Int(before.st_size),
              fstat(fd, &after) == 0, Self.sameVersion(before, after),
              fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameVersion(after, named) else { throw Failure.invalidDocument }
        return Observation(data: data, metadata: after)
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        let readable = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard readable >= 0 else { throw Failure.unsafePath }
        defer { close(readable) }
        var original = stat(), opened = stat()
        guard fstat(descriptor, &original) == 0, fstat(readable, &opened) == 0,
              sameIdentity(original, opened), fsync(readable) == 0 else { throw Failure.unsafePath }
    }

    private func revalidate(_ original: Observation?, in parent: Parent) throws {
        try parent.revalidate()
        let current = try observe(in: parent)
        switch (original, current) {
        case (nil, nil): break
        case let (original?, current?):
            guard Self.sameVersion(original.metadata, current.metadata), original.data == current.data else { throw Failure.unsafePath }
        default: throw Failure.unsafePath
        }
        try parent.revalidate()
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }
    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Cooperating app instances share one persistent, private inode. Readers
    /// never create it; removal checks refuse while an edit holds the lock.
    /// This is not an exclusion boundary against a hostile same-user writer.
    fileprivate final class FileLock {
        let parent: Parent
        let name: String
        let descriptor: Int32
        let identity: stat
        private init(parent: Parent, name: String, descriptor: Int32, identity: stat) {
            self.parent = parent; self.name = name; self.descriptor = descriptor; self.identity = identity
        }
        deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        static func acquire(in parent: Parent, name: String, exclusive: Bool, create: Bool) throws -> FileLock? {
            guard name.utf8.count <= 255 else { throw Failure.unsafePath }
            var descriptor: Int32
            if create {
                descriptor = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if descriptor < 0 && errno == EEXIST { descriptor = openat(parent.fd, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
            } else { descriptor = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
            if descriptor < 0 && errno == ENOENT && !create { return nil }
            guard descriptor >= 0 else { throw Failure.unsafePath }
            var kept = false
            defer { if !kept { close(descriptor) } }
            var identity = stat()
            guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
                  identity.st_uid == geteuid(), identity.st_nlink == 1, identity.st_size == 0, identity.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
            guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.writerBusy }
                throw Failure.unsafePath
            }
            let lease = FileLock(parent: parent, name: name, descriptor: descriptor, identity: identity)
            kept = true
            try lease.validate()
            return lease
        }
        func validate() throws {
            try parent.revalidate()
            var held = stat(), named = stat()
            guard fstat(descriptor, &held) == 0,
                  fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  BrowserSnapshotFile.sameIdentity(identity, held), BrowserSnapshotFile.sameIdentity(held, named),
                  held.st_uid == geteuid(), held.st_nlink == 1, held.st_size == 0, held.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        }
    }

    /// Retain each parent so every original link can be checked without resolving
    /// a mutable absolute path. Cleanup also stays in the opened owned directory.
    fileprivate final class Parent {
        struct Link { let parent: Int32; let name: String; let identity: stat }
        var descriptors: [Int32] = []
        var links: [Link] = []
        var requiresPrivate = false
        var fd: Int32 { descriptors.last! }
        deinit { for descriptor in descriptors.reversed() { close(descriptor) } }
        func revalidate() throws {
            for link in links {
                var current = stat()
                guard fstatat(link.parent, link.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      BrowserSnapshotFile.sameIdentity(current, link.identity) else { throw Failure.unsafePath }
            }
            if requiresPrivate {
                var identity = stat()
                guard fstat(fd, &identity) == 0, identity.st_uid == geteuid(), identity.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
            }
        }
    }

    private func openParent(create: Bool) throws -> Parent? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0),
              directory.standardizedFileURL.path != "/", !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), maximumBytes > 0, maximumBytes <= 4_194_304 else {
            throw Failure.unsafePath
        }
        let parent = Parent()
        let root = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unsafePath }
        parent.descriptors.append(root)
        for part in directory.standardizedFileURL.pathComponents.dropFirst() {
            var next = openat(parent.fd, part, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(parent.fd, part, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath }
                if requiresPrivateDurability { try Self.synchronizeDirectory(parent.fd) }
                next = openat(parent.fd, part, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Failure.unsafePath }
            var identity = stat()
            guard fstat(next, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR else {
                close(next); throw Failure.unsafePath
            }
            parent.links.append(.init(parent: parent.fd, name: part, identity: identity))
            parent.descriptors.append(next)
        }
        parent.requiresPrivate = requiresPrivateDurability
        try parent.revalidate()
        return parent
    }
}
