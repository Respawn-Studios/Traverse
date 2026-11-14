import Darwin
import Foundation

/// Observe native creation metadata, never a bundle's possibly inherited mark.
/// This lazy value is first used on an operation worker. It writes no contents,
/// retains no file, and supplies no exception when observation is unavailable.
internal enum NativeProcessSecurityOrigin {
    static let current: SecurityAttribute? = try? sample(in: FileManager.default.temporaryDirectory)

    internal static func sample(in directory: URL) throws -> SecurityAttribute? {
        let parent = try DirectoryAnchor(directory)
        var root = stat()
        guard fstat(parent.fd, &root) == 0, root.st_uid == geteuid(), root.st_mode & 0o022 == 0 else {
            throw FileOperationFailure.accessDenied
        }
        let name = ".traverse-origin-" + UUID().uuidString
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw posixFailure() }
        let privateFD = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard privateFD >= 0 else { throw posixFailure() }; defer { close(privateFD) }
        let privateIdentity = try EntrySnapshot(fd: privateFD)
        var privateRoot = stat()
        guard fstat(privateFD, &privateRoot) == 0, privateRoot.st_uid == geteuid(),
              privateRoot.st_mode & 0o077 == 0,
              try EntrySnapshot(parent: parent.fd, name: name).sameObject(as: privateIdentity) else {
            throw FileOperationFailure.sourceChanged
        }
        let fd = openat(privateFD, "origin", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        var created = stat()
        guard fstat(fd, &created) == 0, created.st_uid == geteuid(), created.st_size == 0,
              created.st_mode & S_IFMT == S_IFREG, created.st_mode & 0o077 == 0, created.st_nlink == 1 else {
            throw FileOperationFailure.sourceChanged
        }
        let identity = try EntrySnapshot(fd: fd)
        try parent.validate()
        guard try EntrySnapshot(parent: privateFD, name: "origin") == identity else {
            throw FileOperationFailure.sourceChanged
        }
        // The only removal here is this exclusive empty app-owned observation.
        // An uncertain entry is retained; no guessed path is cleaned afterward.
        guard unlinkat(privateFD, "origin", 0) == 0 else { throw posixFailure() }
        let value = try CopySecurity.read(fd).provenance
        try parent.validate()
        guard try EntrySnapshot(fd: fd).sameObject(as: identity),
              try EntrySnapshot(parent: parent.fd, name: name).sameObject(as: privateIdentity) else {
            throw FileOperationFailure.sourceChanged
        }
        // The kernel refuses a nonempty/replaced directory; never recurse here.
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw posixFailure() }
        return value.flatMap { $0.length > 0 ? $0 : nil }
    }
}
