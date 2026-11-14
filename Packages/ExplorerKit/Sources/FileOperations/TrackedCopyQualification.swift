#if DEBUG
import Darwin
import Foundation

extension RecoverableFileOperations {
    /// Signed-app qualification only. The ordinary engine remains unchanged
    /// until this path passes its native gate and the candidate is adopted.
    public static func generatedTrackedCopySession(in root: URL) throws -> RecoverableFileOperations {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let base = repo.appendingPathComponent(".build/b07-move-continuity", isDirectory: true)
        guard root.deletingLastPathComponent().path == base.path,
              UUID(uuidString: root.lastPathComponent) != nil else { throw FileOperationFailure.invalidRequest }
        let anchor = try DirectoryAnchor(root, resolve: false)
        let fd = openat(anchor.fd, "reservation.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        var entry = stat(), parent = stat()
        guard fstat(fd, &entry) == 0, fstat(anchor.fd, &parent) == 0,
              entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1,
              entry.st_size > 0, entry.st_size <= 1024, entry.st_uid == geteuid(), parent.st_uid == geteuid(),
              entry.st_mode & 0o077 == 0, parent.st_mode & 0o077 == 0 else { throw FileOperationFailure.invalidRequest }
        return RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history", isDirectory: true),
            hooks: RecoveryHooks(copyFaults: CopyFaultHooks(afterNativeCopy: { source, destination in
                try preserveCopiedDocumentTracking(source: source, destination: destination)
            })), protecting: [root.appendingPathComponent("state/private-names", isDirectory: true)])
    }
}
#endif
