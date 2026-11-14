import Darwin
import Foundation

/// Pins one private, local catalog namespace. Only a background store owner may
/// use this lease. SQLite still uses Apple's native VFS; this is not a custom
/// filesystem or protection against a hostile process running as this user.
internal final class OwnedNameCatalog: @unchecked Sendable {
    static let databaseName = "names.sqlite"
    static let lockName = "owner.lock"
    static let initializationName = "initialization"
    static let readyName = "ready"
    let directory: URL
    let storeID: UUID
    let firstID: RememberedItemID
    let firstNonce: UUID
    private let marker: Data
    private let parent: Int32
    private let leaf: Int32
    private let lockFile: Int32
    private var databaseFile: Int32 = -1
    private let parentIdentity: Identity
    private let leafIdentity: Identity
    private var pins: [String: Identity] = [:]
    private var sealed: ContentStamp?
    private var released = false
    let writable: Bool

    var path: String { directory.appendingPathComponent(Self.databaseName).path }

    /// The caller has explicitly prepared this new leaf. Never adopt an empty
    /// pre-existing catalog or overwrite a prior initialization marker.
    static func create(_ directory: URL) throws -> OwnedNameCatalog {
        let opened = try openDirectories(directory)
        do {
            guard try entries(opened.leaf).isEmpty else { throw NameStoreFailure.unsafe }
            let store = UUID(), first = UUID(), nonce = UUID()
            let marker = Data("MENAMES1\n\(store.uuidString)\n\(first.uuidString)\n\(nonce.uuidString)\n".utf8)
            try createFile(Self.initializationName, data: marker, leaf: opened.leaf)
            let lock = try exclusiveFile(Self.lockName, leaf: opened.leaf)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lock); throw NameStoreFailure.busy }
            let owner = OwnedNameCatalog(directory, opened: opened, lock: lock, writable: true,
                store: store, first: first, nonce: nonce, marker: marker)
            do {
                let db = try exclusiveFile(databaseName, leaf: opened.leaf)
                owner.databaseFile = db
                owner.pins[databaseName] = try identity(db, directory: false)
                owner.pins[initializationName] = try owner.fileIdentity(initializationName)
                owner.pins[lockName] = try identity(lock, directory: false)
                try owner.synchronizeDirectories()
                try owner.validate()
                return owner
            } catch { owner.release(); throw error }
        } catch {
            // An initialized owner's release already closed these descriptors.
            // The ownership handoff below keeps this path unambiguous.
            // Before handoff only, close through the Opened owner.
            opened.closeUnlessTransferred()
            throw error
        }
    }

    static func open(_ directory: URL, writable: Bool) throws -> OwnedNameCatalog {
        let opened = try openDirectories(directory)
        do {
            let raw = try readFile(initializationName, leaf: opened.leaf, maximum: 128)
            let parts = String(data: raw, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false)
            guard let parts, parts.count == 5, parts[0] == "MENAMES1", parts[4].isEmpty,
                  let store = UUID(uuidString: String(parts[1])), let first = UUID(uuidString: String(parts[2])),
                  let nonce = UUID(uuidString: String(parts[3])),
                  raw == Data("MENAMES1\n\(store.uuidString)\n\(first.uuidString)\n\(nonce.uuidString)\n".utf8) else {
                throw NameStoreFailure.unsafe
            }
            let lock = openat(opened.leaf, lockName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard lock >= 0 else { throw NameStoreFailure.unsafe }
            do {
                _ = try identity(lock, directory: false)
                guard flock(lock, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw NameStoreFailure.busy }
            } catch { Darwin.close(lock); throw error }
            let owner = OwnedNameCatalog(directory, opened: opened, lock: lock, writable: writable,
                store: store, first: first, nonce: nonce, marker: raw)
            do {
                owner.databaseFile = openat(owner.leaf, databaseName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard owner.databaseFile >= 0 else { throw NameStoreFailure.initializationIncomplete }
                for name in [databaseName, initializationName, lockName] {
                    owner.pins[name] = try owner.fileIdentity(name)
                }
                if try entries(owner.leaf).contains(readyName) { owner.pins[readyName] = try owner.fileIdentity(readyName) }
                try owner.validate()
                return owner
            } catch { owner.release(); throw error }
        } catch { opened.closeUnlessTransferred(); throw error }
    }

    private init(_ directory: URL, opened: Opened, lock: Int32, writable: Bool,
                 store: UUID, first: UUID, nonce: UUID, marker: Data) {
        self.directory = directory; parent = opened.parent; leaf = opened.leaf; lockFile = lock
        parentIdentity = opened.parentID; leafIdentity = opened.leafID
        storeID = store; firstID = RememberedItemID(first); firstNonce = nonce; self.marker = marker
        self.writable = writable; opened.transferred = true
    }

    deinit { release() }
    func release() {
        guard !released else { return }; released = true
        if databaseFile >= 0 { Darwin.close(databaseFile) }
        Darwin.close(lockFile); Darwin.close(leaf); Darwin.close(parent)
    }

    func validate() throws {
        guard !released else { throw NameStoreFailure.closed }
        let fresh = try Self.openDirectories(directory)
        defer { fresh.closeUnlessTransferred() }
        guard fresh.parentID == parentIdentity, fresh.leafID == leafIdentity,
              try Self.identity(leaf, directory: true) == leafIdentity,
              try Self.identity(parent, directory: true, privateMode: false) == parentIdentity else { throw NameStoreFailure.changed }
        let allowed: Set<String> = [Self.databaseName, Self.lockName, Self.initializationName, Self.readyName, Self.databaseName + "-journal"]
        let children = try Self.entries(leaf)
        guard children.isSubset(of: allowed), Set(pins.keys).isSubset(of: children) else { throw NameStoreFailure.unsafe }
        for name in children {
            let current = try fileIdentity(name)
            if let pin = pins[name], current != pin { throw NameStoreFailure.changed }
        }
        guard try Self.identity(databaseFile, directory: false) == pins[Self.databaseName],
              try Self.identity(lockFile, directory: false) == pins[Self.lockName],
              try Self.readFile(Self.initializationName, leaf: leaf, maximum: 128) == marker else { throw NameStoreFailure.changed }
        if let sealed, try contentStamp() != sealed { throw NameStoreFailure.changed }
    }

    func sealReadState() throws { sealed = try contentStamp(); try validate() }
    func managementBytes() throws -> (database: (Int64, Int64), journal: (Int64, Int64)) {
        try validate()
        func measure(_ name: String, optional: Bool) throws -> (Int64, Int64) {
            var info = stat()
            guard fstatat(leaf, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if optional, errno == ENOENT { return (0, 0) }
                throw NameStoreFailure.unavailable
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_blocks >= 0,
                  info.st_blocks <= Int64.max / 512 else { throw NameStoreFailure.unsafe }
            return (info.st_size, Int64(info.st_blocks) * 512)
        }
        let value = try (measure(Self.databaseName, optional: false), measure(Self.databaseName + "-journal", optional: true))
        try validate(); return value
    }
    func beginWrite() throws { try validate(); sealed = nil }
    func endWrite() throws { try sealReadState() }
    private struct ContentStamp: Equatable {
        let size: Int64, modification: Int, modificationNanos: Int, change: Int, changeNanos: Int
    }
    private func contentStamp() throws -> ContentStamp {
        var info = stat()
        guard fstat(databaseFile, &info) == 0 else { throw NameStoreFailure.unavailable }
        return ContentStamp(size: info.st_size, modification: info.st_mtimespec.tv_sec,
            modificationNanos: info.st_mtimespec.tv_nsec, change: info.st_ctimespec.tv_sec, changeNanos: info.st_ctimespec.tv_nsec)
    }

    func isReady() throws -> Bool {
        guard try Self.entries(leaf).contains(Self.readyName) else { return false }
        let value = try Self.readFile(Self.readyName, leaf: leaf, maximum: 128)
        guard marker.starts(with: value) else { throw NameStoreFailure.unsafe }
        return value == marker
    }

    func publishReady() throws {
        guard writable else { throw NameStoreFailure.readOnly }
        try validate()
        if !(try Self.entries(leaf).contains(Self.readyName)) {
            try Self.createFile(Self.readyName, data: marker, leaf: leaf)
            pins[Self.readyName] = try fileIdentity(Self.readyName)
        } else if !(try isReady()) {
            // Only an exact prefix of our immutable initialization token can be
            // a torn, owned ready marker. Other bytes are never repaired.
            let fd = openat(leaf, Self.readyName, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw NameStoreFailure.unavailable }
            defer { Darwin.close(fd) }
            guard try Self.identity(fd, directory: false) == pins[Self.readyName] else { throw NameStoreFailure.changed }
            try Self.write(marker, to: fd); try Self.synchronize(fd)
        }
        try synchronizeDirectories(); try validate()
        guard try isReady() else { throw NameStoreFailure.initializationIncomplete }
    }

    /// Any nonzero header conservatively requires explicit SQLite recovery.
    /// A read-only inspector never deletes even an inactive journal.
    func needsRecovery() throws -> Bool {
        guard try Self.entries(leaf).contains(Self.databaseName + "-journal") else { return false }
        let fd = openat(leaf, Self.databaseName + "-journal", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }
        defer { Darwin.close(fd) }
        _ = try Self.identity(fd, directory: false)
        var bytes = [UInt8](repeating: 0, count: 8)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { throw NameStoreFailure.unavailable }
        return bytes.prefix(count).contains { $0 != 0 }
    }

    func validateHeader(creating: Bool) throws {
        var value = stat()
        guard fstat(databaseFile, &value) == 0 else { throw NameStoreFailure.unavailable }
        if creating, value.st_size == 0 { return }
        guard value.st_size >= 100 else { throw NameStoreFailure.initializationIncomplete }
        var header = [UInt8](repeating: 0, count: 100)
        guard pread(databaseFile, &header, header.count, 0) == 100,
              header.starts(with: "SQLite format 3\0".utf8) else { throw NameStoreFailure.unsafe }
        guard header[18] == 1, header[19] == 1 else { throw NameStoreFailure.unsupported }
        func number(_ offset: Int) -> Int { header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        // Ordinary name mutations never change these identifiers. Even a hot
        // journal cannot authorize an older reader to write a newer format.
        if !creating {
            guard [1, 2, NameStoreFormat.moveSchema, NameStoreFormat.memberSchema].contains(number(60)), number(68) == NameStoreFormat.applicationID else {
                throw NameStoreFailure.unsupported
            }
        }
    }

    func synchronize() throws {
        try validate(); try Self.synchronize(databaseFile); try synchronizeDirectories(); try validate()
        guard try !needsRecovery() else { throw NameStoreFailure.recoveryRequired }
    }
    private func synchronizeDirectories() throws {
        guard fsync(leaf) == 0, fsync(parent) == 0 else { throw NameStoreFailure.unavailable }
    }

    private func fileIdentity(_ name: String) throws -> Identity {
        let fd = openat(leaf, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }
        defer { Darwin.close(fd) }
        return try Self.identity(fd, directory: false)
    }

    private final class Opened {
        let parent: Int32, leaf: Int32
        let parentID: Identity, leafID: Identity
        var transferred = false
        init(parent: Int32, leaf: Int32, parentID: Identity, leafID: Identity) {
            self.parent = parent; self.leaf = leaf; self.parentID = parentID; self.leafID = leafID
        }
        func closeUnlessTransferred() { if !transferred { transferred = true; Darwin.close(leaf); Darwin.close(parent) } }
    }
    private static func openDirectories(_ url: URL) throws -> Opened {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", url.path == url.standardizedFileURL.path,
              !url.path.utf8.contains(0) else { throw NameStoreFailure.unsafe }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw NameStoreFailure.unavailable }
        do {
            let parentID = try identity(parent, directory: true, privateMode: false)
            let leaf = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard leaf >= 0 else { throw NameStoreFailure.unavailable }
            do {
                let leafID = try identity(leaf, directory: true)
                var fs = statfs()
                guard fstatfs(leaf, &fs) == 0 else { throw NameStoreFailure.unavailable }
                let type = withUnsafePointer(to: &fs.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
                guard type == "apfs", fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NameStoreFailure.unsupported }
                return Opened(parent: parent, leaf: leaf, parentID: parentID, leafID: leafID)
            } catch { Darwin.close(leaf); throw error }
        } catch { Darwin.close(parent); throw error }
    }
    private struct Identity: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32, birth: Int, nanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; generation = value.st_gen
            birth = value.st_birthtimespec.tv_sec; nanos = value.st_birthtimespec.tv_nsec
        }
    }
    private static func identity(_ fd: Int32, directory: Bool, privateMode: Bool = true) throws -> Identity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw NameStoreFailure.unavailable }
        guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), value.st_uid == geteuid(),
              value.st_mode & 0o022 == 0 else { throw NameStoreFailure.unsafe }
        if !directory {
            guard value.st_nlink == 1, value.st_size >= 0, value.st_size <= NameStoreFormat.maximumBytes else { throw NameStoreFailure.unsafe }
        }
        if privateMode {
            guard value.st_mode & 0o777 == (directory ? 0o700 : 0o600) else { throw NameStoreFailure.unsafe }
            errno = 0
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                errno = 0
                guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
                      errno == EINVAL else { throw NameStoreFailure.unsafe }
            } else {
                // Darwin reports ENOENT when the file has no extended ACL.
                // Other retrieval failures remain unsafe, never "no ACL".
                guard errno == ENOENT else { throw NameStoreFailure.unsafe }
            }
        }
        return Identity(value)
    }
    private static func entries(_ fd: Int32) throws -> Set<String> {
        // dup shares the directory offset. Rewind each independent enumeration.
        guard let stream = fdopendir(dup(fd)) else { throw NameStoreFailure.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var result = Set<String>(); errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.insert(name) }
            guard result.count <= 8 else { throw NameStoreFailure.unsafe }
            errno = 0
        }
        guard errno == 0 else { throw NameStoreFailure.unavailable }
        return result
    }
    private static func exclusiveFile(_ name: String, leaf: Int32) throws -> Int32 {
        let fd = openat(leaf, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }
        return fd
    }
    private static func createFile(_ name: String, data: Data, leaf: Int32) throws {
        let fd = try exclusiveFile(name, leaf: leaf)
        defer { Darwin.close(fd) }; try write(data, to: fd); try synchronize(fd)
    }
    private static func readFile(_ name: String, leaf: Int32, maximum: Int) throws -> Data {
        let fd = openat(leaf, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }
        defer { Darwin.close(fd) }; _ = try identity(fd, directory: false)
        var value = stat(); guard fstat(fd, &value) == 0, value.st_size <= maximum else { throw NameStoreFailure.unsafe }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw NameStoreFailure.unavailable }
        return data
    }
    private static func write(_ data: Data, to fd: Int32) throws {
        let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw NameStoreFailure.unavailable }
    }
    private static func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw NameStoreFailure.unavailable }
    }
}
