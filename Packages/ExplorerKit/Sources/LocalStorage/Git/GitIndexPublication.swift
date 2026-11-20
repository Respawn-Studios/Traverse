import Darwin
import FileOperations
import Foundation

struct GitIndexSnapshot: Equatable, Sendable {
    static let maximumBytes = 16 << 20
    let entry: EntrySnapshot?
    let permissions: mode_t?
    let bytes: Data?

    init(_ metadata: DirectoryAnchor, check: () throws -> Void) throws {
        let observed = try metadata.gitEntry("index")
        if let observed, observed.st_nlink != 1 { throw GitIndexEditFailure.unsupportedIndex }
        entry = observed.map(EntrySnapshot.init)
        permissions = observed.map { $0.st_mode & 0o777 }
        bytes = try metadata.gitReadOptional("index", maximum: Self.maximumBytes, check: check)
        try metadata.validate()
        guard try metadata.gitEntry("index").map(EntrySnapshot.init) == entry,
              (bytes == nil) == (entry == nil) else { throw GitInspectionFailure.changed }
    }
}

/// Use the same exclusive lock as native Git. A cancelled or refused edit
/// may release only that lock, and only while its name still refers to it.
final class GitIndexPublication {
    private let metadata: DirectoryAnchor
    private let fd: Int32
    private let identity: EntrySnapshot
    private var prepared: EntrySnapshot?
    private var published = false

    init(in metadata: DirectoryAnchor) throws {
        try metadata.validate()
        let fd = openat(metadata.fd, "index.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw errno == EEXIST ? GitIndexEditFailure.indexLocked : .writeDenied }
        do { identity = try EntrySnapshot(fd: fd) }
        catch { close(fd); throw GitIndexEditFailure.uncertain }
        self.metadata = metadata
        self.fd = fd
    }

    deinit {
        if !published, (try? ownsLock()) == true { _ = unlinkat(metadata.fd, "index.lock", 0) }
        close(fd)
    }

    func write(_ bytes: Data, permissions: mode_t?, check: () throws -> Void) throws {
        try check()
        if let permissions, fchmod(fd, permissions) != 0 { throw GitIndexEditFailure.writeDenied }
        prepared = try Self.writeVerified(bytes, to: fd, onUnverified: .uncertain, check: check)
    }

    func publish(replacing expected: EntrySnapshot?, check: () throws -> Void) throws {
        try check()
        try metadata.validate()
        guard let prepared, let lock = try metadata.gitEntry("index.lock"),
              lock.st_nlink == 1, EntrySnapshot(lock) == prepared else { throw GitIndexEditFailure.uncertain }
        let destination = try metadata.gitEntry("index")
        guard destination.map(EntrySnapshot.init) == expected, (destination?.st_nlink ?? 1) == 1 else {
            throw GitInspectionFailure.changed
        }
        let result: Int32
        if expected == nil {
            result = renameatx_np(metadata.fd, "index.lock", metadata.fd, "index", UInt32(RENAME_EXCL))
            if result != 0, errno == EEXIST { throw GitInspectionFailure.changed }
        } else {
            result = renameat(metadata.fd, "index.lock", metadata.fd, "index")
        }
        guard result == 0 else { throw GitIndexEditFailure.writeDenied }
        published = true
        // The rename is the commit point. An interrupted caller retains the
        // outcome, and a sync failure must never be retried as a fresh write.
        guard fsync(metadata.fd) == 0 else { throw GitIndexEditFailure.uncertain }
    }

    private func ownsLock() throws -> Bool {
        try metadata.gitEntry("index.lock").map { identity.sameObject(as: EntrySnapshot($0)) } ?? false
    }

    /// Verify the exact descriptor contents while the file still has its
    /// temporary name. Object identity alone cannot establish those bytes.
    fileprivate static func writeVerified(_ bytes: Data, to fd: Int32, onUnverified failure: GitIndexEditFailure,
                                          check: () throws -> Void) throws -> EntrySnapshot {
        try writeAll(bytes, to: fd, check: check)
        do {
            let written = try EntrySnapshot(fd: fd)
            guard try boundedRegularFileBytes(fd, maximumBytes: bytes.count, checkCancellation: check) == bytes,
                  try EntrySnapshot(fd: fd) == written else { throw failure }
            return written
        } catch is FileOperationFailure { throw failure }
    }

    private static func writeAll(_ bytes: Data, to fd: Int32, check: () throws -> Void) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try check()
                let amount = Darwin.write(fd, address.advanced(by: offset), min(256 << 10, buffer.count - offset))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw GitIndexEditFailure.writeDenied }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw GitIndexEditFailure.writeDenied }
    }
}

struct GitLooseBlob {
    static let maximumBytes = 9 << 20
    let object: GitObjectID
    let compressed: Data
    let verifiedExisting: Data?

    var prefix: String { String(object.hex.prefix(2)) }
    var name: String { String(object.hex.dropFirst(2)) }

    func publish(in objects: DirectoryAnchor, check: () throws -> Void) throws {
        try check()
        try objects.validate()
        if try objects.gitEntry(prefix) == nil,
           mkdirat(objects.fd, prefix, 0o755) != 0, errno != EEXIST { throw GitIndexEditFailure.writeDenied }
        let fan = try objects.gitDirectory(prefix)
        if try acceptExisting(in: fan, check: check) { return }

        let temporary = ".traverse-object-" + UUID().uuidString
        let fd = openat(fan.fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o444)
        guard fd >= 0 else { throw GitIndexEditFailure.writeDenied }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0 else { throw GitIndexEditFailure.objectChanged }
        let identity = EntrySnapshot(initial)
        defer {
            if let entry = try? fan.gitEntry(temporary), identity.sameObject(as: EntrySnapshot(entry)) {
                _ = unlinkat(fan.fd, temporary, 0)
            }
        }
        let written = try GitIndexPublication.writeVerified(compressed, to: fd, onUnverified: .objectChanged, check: check)
        try check()
        try fan.validate()
        guard let entry = try fan.gitEntry(temporary), entry.st_nlink == 1,
              EntrySnapshot(entry) == written, entry.st_mode == initial.st_mode else { throw GitIndexEditFailure.objectChanged }
        if renameatx_np(fan.fd, temporary, fan.fd, name, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST, try acceptExisting(in: fan, check: check) else {
                throw GitIndexEditFailure.writeDenied
            }
        }
        guard fsync(fan.fd) == 0, fsync(objects.fd) == 0 else { throw GitIndexEditFailure.writeDenied }
    }

    func isPresent(in objects: DirectoryAnchor, check: () throws -> Void) throws -> Bool {
        try acceptExisting(in: objects.gitDirectory(prefix), check: check)
    }

    private func acceptExisting(in fan: DirectoryAnchor, check: () throws -> Void) throws -> Bool {
        guard let current = try fan.gitReadOptional(name, maximum: Self.maximumBytes, check: check) else { return false }
        guard current == compressed || current == verifiedExisting else { throw GitIndexEditFailure.objectChanged }
        return true
    }
}
