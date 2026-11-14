import Darwin
import Foundation

protocol RemoteSettingsDocument: Sendable {
    init()
    func encoded() throws -> Data
    static func decode(_ data: Data) throws -> Self
}

@_spi(Qualification) public enum RemoteSettingsFailure: Error, Sendable, Equatable {
    case unsafe, unavailable, busy, cancelled, notOpen, staleRevision, invalidRecord
    case incompatibleVersion, recoveryRequired, durabilityUncertain, capacity, missing
}

/// Exact, private metadata namespace. Called only on the saved-server queue.
/// It is not a hostile-same-user race-proof filesystem transaction primitive.
final class RemoteSettingsFile<Document: RemoteSettingsDocument>: @unchecked Sendable {
    static var maximumBytes: Int { 256 * 1024 }
    enum Stage: String, Sendable { case stagingWritten, stagingSynchronized, beforeRename, renamed, directorySynchronized }
    typealias Probe = @Sendable (Stage) throws -> Void
    private let location: URL
    private let parent: Int32
    private let directory: Int32
    private let lease: Int32
    private let parentID: Identity
    private let directoryID: Identity
    private let leaseID: Identity?
    private var catalogID: Identity?
    private var catalogBytes: Data?
    private(set) var snapshot: Document
    private var closed = false
    private var retainedStage: (Identity, Data)?
    private var retainedStageAccess: SFTPRetainedMetadataStageAccess?
    private var poisoned = false
    private let writing: Bool
    private let probe: Probe?

    private init(location: URL, parent: Int32, directory: Int32, lease: Int32, writing: Bool, probe: Probe?) throws {
        self.location = location; self.parent = parent; self.directory = directory; self.lease = lease
        self.writing = writing; self.probe = probe
        parentID = try Self.identity(parent, directory: true, privateMode: false)
        directoryID = try Self.identity(directory, directory: true)
        leaseID = lease >= 0 ? try Self.identity(lease, directory: false, maximum: 0) : nil
        snapshot = Document()
    }
    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true
        if lease >= 0 { _ = flock(lease, LOCK_UN); Darwin.close(lease) }
        Darwin.close(directory); Darwin.close(parent)
    }

    /// Missing passive state returns nil. Only explicit writes create one leaf;
    /// no ancestor repair, chmod, implicit recovery or startup file creation.
    static func open(_ url: URL, writing: Bool, discardStage: Bool = false, probe: Probe? = nil,
        retainedRetirement: SFTPRetainedMetadataStageAccess? = nil) throws -> RemoteSettingsFile? {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", url.standardizedFileURL.path == url.path,
              !url.path.utf8.contains(0), url.lastPathComponent != ".", url.lastPathComponent != ".." else { throw RemoteSettingsFailure.unsafe }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if parent < 0 {
            if !writing && errno == ENOENT { return nil }
            throw RemoteSettingsFailure.unavailable
        }
        var directory: Int32 = -1, lease: Int32 = -1, transferred = false
        do {
            _ = try identity(parent, directory: true, privateMode: false)
            var filesystem = statfs()
            guard fstatfs(parent, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw RemoteSettingsFailure.unsafe }
            let type = withUnsafePointer(to: &filesystem.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            guard type == "apfs" else { throw RemoteSettingsFailure.unsafe }
            directory = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            if directory < 0 && errno == ENOENT {
                if !writing { Darwin.close(parent); return nil }
                guard mkdirat(parent, url.lastPathComponent, 0o700) == 0 else { throw RemoteSettingsFailure.unsafe }
                directory = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard directory >= 0 else { throw RemoteSettingsFailure.unsafe }
            _ = try identity(directory, directory: true)
            let names = try entries(directory)
            guard names.isSubset(of: ["owner.lock", "servers.json", "pending.json"]) else { throw RemoteSettingsFailure.unsafe }
            guard names.isEmpty || names.contains("owner.lock") else { throw RemoteSettingsFailure.unsafe }
            if writing {
                lease = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                if lease < 0 && errno == EEXIST { lease = openat(directory, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                guard lease >= 0 else { throw RemoteSettingsFailure.unsafe }
            } else if names.contains("owner.lock") {
                lease = openat(directory, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard lease >= 0 else { throw RemoteSettingsFailure.unsafe }
            } else if !names.isEmpty { throw RemoteSettingsFailure.unsafe }
            if lease >= 0 {
                _ = try identity(lease, directory: false, maximum: 0)
                guard flock(lease, (writing ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw RemoteSettingsFailure.busy }
            }
            let owner = try RemoteSettingsFile(location: url, parent: parent, directory: directory, lease: lease, writing: writing, probe: probe)
            // Descriptor ownership transfers only after the initializer succeeds.
            transferred = true
            do {
                try owner.load(discardStage: discardStage, retainedRetirement: retainedRetirement)
                if writing {
                    guard fsync(owner.lease) == 0, fsync(owner.directory) == 0, fsync(owner.parent) == 0 else { throw RemoteSettingsFailure.unavailable }
                }
                return owner
            } catch { owner.close(); throw error }
        } catch {
            if !transferred {
                if lease >= 0 { Darwin.close(lease) }
                if directory >= 0 { Darwin.close(directory) }
                Darwin.close(parent)
            }
            throw error
        }
    }

    private func load(discardStage: Bool, retainedRetirement: SFTPRetainedMetadataStageAccess?) throws {
        try validateNamespace()
        let current = try readCatalog()
        snapshot = try current.map { try Document.decode($0.1) } ?? Document()
        catalogID = current?.0; catalogBytes = current?.1
        if try Self.entries(directory).contains("pending.json") {
            guard (writing && discardStage) || retainedRetirement != nil else { throw RemoteSettingsFailure.recoveryRequired }
            let pending = openat(directory, "pending.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard pending >= 0 else { throw RemoteSettingsFailure.unsafe }
            defer { Darwin.close(pending) }
            let id = try Self.identity(pending, directory: false)
            try validateNamespace(); try sameFile("pending.json", id: id)
            if let retainedRetirement {
                var facts = stat(); guard fstat(pending, &facts) == 0, facts.st_size <= Self.maximumBytes else { throw RemoteSettingsFailure.unsafe }
                var bytes = Data(count: Int(facts.st_size)); let count = bytes.count
                guard bytes.withUnsafeMutableBytes({ pread(pending, $0.baseAddress, count, 0) }) == count else { throw RemoteSettingsFailure.unavailable }
                try retainedRetirement.authority.validate(snapshot, prefix: bytes)
                retainedStage = (id, bytes); retainedStageAccess = retainedRetirement

            } else {
                guard unlinkat(directory, "pending.json", 0) == 0, fsync(directory) == 0 else { throw RemoteSettingsFailure.unavailable }
            }
        }
        try validateCurrent()
    }

    func validateCurrent() throws {
        guard !closed, !poisoned else { throw RemoteSettingsFailure.recoveryRequired }
        try validateNamespace()
        if let (id, bytes) = retainedStage {
            try sameFile("pending.json", id: id)
            let fd = openat(directory, "pending.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw RemoteSettingsFailure.unsafe }; defer { Darwin.close(fd) }
            var actual = Data(count: bytes.count); let count = actual.count
            var facts = stat()
            guard fstat(fd, &facts) == 0, facts.st_size == count,
                  actual.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, count, 0) }) == count, actual == bytes else { throw RemoteSettingsFailure.unsafe }
        } else { guard !(try Self.entries(directory)).contains("pending.json") else { throw RemoteSettingsFailure.recoveryRequired } }
        let current = try readCatalog()
        guard current?.0 == catalogID, current?.1 == catalogBytes else { throw RemoteSettingsFailure.unsafe }
    }

    /// Called only after the selected committed intent, metadata owner and ALL
    /// body retirement leases have been freshly re-proved by the removal owner.
    func retireRetainedStageForExplicitResume(selectedEditor: UUID) throws {
        guard let (id, bytes) = retainedStage else { return }
        guard writing, let access = retainedStageAccess, access.permitsStageRetirement else { throw RemoteSettingsFailure.recoveryRequired }
        try validateCurrent(); try access.authority.validate(snapshot, prefix: bytes, selectedEditor: selectedEditor)
        try sameFile("pending.json", id: id)
        guard unlinkat(directory, "pending.json", 0) == 0 else { throw RemoteSettingsFailure.unavailable }
        guard fsync(directory) == 0 else { poisoned = true; throw RemoteSettingsFailure.durabilityUncertain }
        retainedStage = nil; retainedStageAccess = nil
    }
    func commit(_ next: Document) throws {
        guard retainedStage == nil else { throw RemoteSettingsFailure.recoveryRequired }
        guard writing else { throw RemoteSettingsFailure.notOpen }
        let data = try next.encoded(); try validateCurrent()
        let stage = openat(directory, "pending.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard stage >= 0 else { throw RemoteSettingsFailure.recoveryRequired }
        defer { Darwin.close(stage) }
        var renamed = false
        do {
            let stageID = try Self.identity(stage, directory: false)
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(stage, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw RemoteSettingsFailure.unavailable }; written += count
                }
            }
            try probe?(.stagingWritten)
            guard fsync(stage) == 0, fcntl(stage, F_FULLFSYNC) == 0 else { throw RemoteSettingsFailure.unavailable }
            try probe?(.stagingSynchronized)
            try validateNamespace(); try sameFile("pending.json", id: stageID)
            let current = try readCatalog()
            guard current?.0 == catalogID, current?.1 == catalogBytes else { throw RemoteSettingsFailure.unsafe }
            try probe?(.beforeRename)
            let result = catalogID == nil
                ? renameatx_np(directory, "pending.json", directory, "servers.json", UInt32(RENAME_EXCL))
                : renameat(directory, "pending.json", directory, "servers.json")
            guard result == 0 else { throw RemoteSettingsFailure.unavailable }; renamed = true
            try probe?(.renamed)
            guard fsync(directory) == 0 else { throw RemoteSettingsFailure.durabilityUncertain }
            try probe?(.directorySynchronized)
            try validateNamespace(); try sameFile("servers.json", id: stageID)
            let saved = try readCatalog()
            guard saved?.1 == data else { throw RemoteSettingsFailure.unsafe }
            catalogID = saved?.0; catalogBytes = data; snapshot = next
        } catch {
            poisoned = true // Only explicit close/reopen/recovery may clear this.
            if renamed { throw RemoteSettingsFailure.durabilityUncertain }
            throw error
        }
    }

    private func validateNamespace() throws {
        let fresh = Darwin.open(location.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fresh >= 0 else { throw RemoteSettingsFailure.unsafe }; defer { Darwin.close(fresh) }
        guard try Self.identity(fresh, directory: true, privateMode: false) == parentID else { throw RemoteSettingsFailure.unsafe }
        let leaf = openat(fresh, location.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard leaf >= 0 else { throw RemoteSettingsFailure.unsafe }; defer { Darwin.close(leaf) }
        guard try Self.identity(leaf, directory: true) == directoryID else { throw RemoteSettingsFailure.unsafe }
        guard (try Self.entries(leaf)).isSubset(of: ["owner.lock", "servers.json", "pending.json"]) else { throw RemoteSettingsFailure.unsafe }
        if let leaseID { try sameFile("owner.lock", id: leaseID) }
    }
    private func sameFile(_ name: String, id: Identity) throws {
        let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RemoteSettingsFailure.unsafe }; defer { Darwin.close(fd) }
        guard try Self.identity(fd, directory: false, maximum: name == "owner.lock" ? 0 : Self.maximumBytes) == id else { throw RemoteSettingsFailure.unsafe }
    }
    private func readCatalog() throws -> (Identity, Data)? {
        let fd = openat(directory, "servers.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw RemoteSettingsFailure.unsafe }; defer { Darwin.close(fd) }
        let id = try Self.identity(fd, directory: false)
        var facts = stat(); guard fstat(fd, &facts) == 0 else { throw RemoteSettingsFailure.unavailable }
        var data = Data(count: Int(facts.st_size)); var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RemoteSettingsFailure.unavailable }; offset += count
        }
        var after = stat(); guard fstat(fd, &after) == 0,
            facts.st_size == after.st_size,
            facts.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, facts.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            facts.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, facts.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            try Self.identity(fd, directory: false) == id else { throw RemoteSettingsFailure.unsafe }
        try sameFile("servers.json", id: id)
        return (id, data)
    }
    /// Opaque read-only identity witness. No path/body or mutation authority.
    /// Reopening an equal-byte replacement is distinguishable from the exact
    /// private owner that originally issued a recovery choice.
    func recoveryReadIdentity() throws -> RemoteSettingsReadIdentity {
        try validateCurrent()
        var values: [UInt64] = []
        for item in [Optional(parentID), Optional(directoryID), leaseID, catalogID] {
            guard let item else { values.append(0); continue }; values.append(1)
            values.append(UInt64(truncatingIfNeeded: item.device)); values.append(item.inode)
            values.append(UInt64(item.generation)); values.append(UInt64(truncatingIfNeeded: item.birth)); values.append(UInt64(truncatingIfNeeded: item.nanos))
        }
        return .init(values: values)
    }
    private struct Identity: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32, birth: Int, nanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; generation = value.st_gen
            birth = value.st_birthtimespec.tv_sec; nanos = value.st_birthtimespec.tv_nsec
        }
    }
    private static func identity(_ fd: Int32, directory: Bool, privateMode: Bool = true, maximum: Int = maximumBytes) throws -> Identity {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw RemoteSettingsFailure.unavailable }
        guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), value.st_uid == geteuid(), value.st_mode & 0o022 == 0 else { throw RemoteSettingsFailure.unsafe }
        if !directory { guard value.st_nlink == 1, value.st_size >= 0, value.st_size <= maximum, value.st_flags == 0 else { throw RemoteSettingsFailure.unsafe } }
        if privateMode {
            guard value.st_mode & 0o777 == (directory ? 0o700 : 0o600) else { throw RemoteSettingsFailure.unsafe }
            errno = 0
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?
                errno = 0
                guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw RemoteSettingsFailure.unsafe }
            } else { guard errno == ENOENT else { throw RemoteSettingsFailure.unsafe } }
        }
        return Identity(value)
    }
    private static func entries(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd); guard copy >= 0 else { throw RemoteSettingsFailure.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw RemoteSettingsFailure.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var names = Set<String>(); errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.insert(name) }
            guard names.count <= 3 else { throw RemoteSettingsFailure.unsafe }; errno = 0
        }
        guard errno == 0 else { throw RemoteSettingsFailure.unavailable }; return names
    }
}

struct RemoteSettingsReadIdentity: Equatable, Sendable {
    fileprivate let values: [UInt64]
    init(values: [UInt64]) { self.values = values }
}
