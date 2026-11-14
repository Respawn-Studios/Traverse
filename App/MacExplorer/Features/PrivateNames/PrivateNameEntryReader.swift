import Darwin
import ExplorerCore
import FileMemory
import Foundation
import Search

/// Selected-reference metadata only, never directory traversal or body reads.
final class PrivateNameEntryReader: @unchecked Sendable {
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending = 0
    init() { queue.name = "MacExplorer.PrivateNames.Metadata"; queue.maxConcurrentOperationCount = 2 }
    func read(_ url: URL, scope: SearchScope? = nil, includeExternal: Bool = true, showHidden: Bool = true) async throws -> FileEntry {
        try lock.withLock { guard pending < 64 else { throw RememberedReferenceFailure.capacity }; pending += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                defer { self.lock.withLock { self.pending -= 1 } }
                continuation.resume(with: Result {
                    let activity = try ApplicationFileActivity.gate.begin(); defer { withExtendedLifetime(activity) {} }
                    let visiblePath = scope.map { String(url.path.dropFirst($0.root.path.count)) } ?? url.path
                    guard !AutomaticMetadataPolicy.excludes(url), scope?.permits(url) != false,
                          showHidden || !visiblePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { throw RememberedReferenceFailure.unsupported }
                    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
                    guard fd >= 0 else { throw RememberedReferenceFailure.unavailable }; defer { Darwin.close(fd) }
                    var before = stat(), after = stat()
                    guard fstat(fd, &before) == 0, before.st_flags & UInt32(SF_DATALESS) == 0,
                          before.st_mode & S_IFMT == S_IFREG || before.st_mode & S_IFMT == S_IFDIR else { throw RememberedReferenceFailure.unsupported }
                    (url as NSURL).removeAllCachedResourceValues()
                    let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey])
                    guard values.volumeIsLocal == true, includeExternal || values.volumeIsInternal == true,
                          showHidden || before.st_flags & UInt32(UF_HIDDEN) == 0 else { throw RememberedReferenceFailure.unsupported }
                    guard values.isAliasFile != true, values.isUbiquitousItem != true, lstat(url.path, &after) == 0,
                          before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_gen == after.st_gen,
                          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw RememberedReferenceFailure.changed }
                    func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
                    let directory = before.st_mode & S_IFMT == S_IFDIR
                    return FileEntry(url: url, name: url.lastPathComponent,
                        kind: directory ? (values.isPackage == true ? .package : .directory) : .file,
                        byteCount: directory ? nil : before.st_size, modifiedAt: date(before.st_mtimespec),
                        createdAt: date(before.st_birthtimespec), accessedAt: date(before.st_atimespec))
                })
            }
        }
    }
}
