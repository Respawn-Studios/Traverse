import Darwin
#if !SFTP_PARENT_STANDALONE
import ExplorerCore
#endif
import Foundation

/// One concrete local read source, confined to its reader/operation worker.
/// Explicit ZIP, TAR and SFTP consumers share no-follow/privacy/residency checks.
internal final class PinnedLocalFileSource {
    internal struct Stamp: Equatable, Sendable, Codable {
        let device: Int32, inode: UInt64, generation: UInt32, size: Int64
        let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
        let mode: UInt16, flags: UInt32
    }
    let url: URL
    let descriptor: Int32
    private let metadata: Int32
    let observed: Stamp
    init(_ url: URL, excluding roots: [URL] = []) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.path == url.standardizedFileURL.path,
              !url.path.utf8.contains(0), !AutomaticMetadataPolicy.excludes(url),
              !url.pathComponents.contains(where: { ["cloudstorage", "mobile documents"].contains($0.lowercased()) }),
              !roots.contains(where: { $0.path == "/" || url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else { throw ZIPArchiveFailure.unavailable }
        let metadata = Darwin.open(url.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard metadata >= 0 else { throw ZIPArchiveFailure.unavailable }
        var accepted = false; defer { if !accepted { close(metadata) } }
        let observed = try Self.stamp(metadata)
        var filesystem = statfs()
        guard fstatfs(metadata, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ZIPArchiveFailure.unsupported }
        let facts = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard facts.isUbiquitousItem != true else { throw ZIPArchiveFailure.unavailable }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw ZIPArchiveFailure.unavailable }
        defer { if !accepted { close(descriptor) } }
        guard try Self.stamp(descriptor) == observed else { throw ZIPArchiveFailure.changed }
        try Self.validate(url, descriptor: descriptor, metadata: metadata, observed: observed)
        self.url = url; self.metadata = metadata; self.descriptor = descriptor; self.observed = observed
        accepted = true
    }
    deinit { close(descriptor); close(metadata) }
    func read(_ offset: UInt64, _ count: Int, maximum: Int, check: () throws -> Void) throws -> Data {
        try check()
        guard count >= 0, count <= maximum, offset <= UInt64(observed.size),
              UInt64(count) <= UInt64(observed.size) - offset, offset <= UInt64(Int64.max) else { throw ZIPArchiveFailure.malformed }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < count {
                try check()
                let amount = pread(descriptor, bytes.baseAddress!.advanced(by: completed), min(65_536, count - completed), off_t(offset) + off_t(completed))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw ZIPArchiveFailure.unavailable }
                completed += amount
            }
        }
        return data
    }
    func validate() throws {
        try Self.validate(url, descriptor: descriptor, metadata: metadata, observed: observed)
    }
    /// Cache freshness only. This opens a no-follow metadata descriptor and
    /// reads no file bytes; operation preparation still revalidates separately.
    static func matchesCurrentObservation(at url: URL, observed: Stamp) throws -> Bool {
        try Task.checkCancellation()
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let matches = try stamp(descriptor) == observed
        try Task.checkCancellation()
        return matches
    }
    /// Shared by retained ZIP and TAR catalogs. Only one bounded metadata
    /// probe is submitted by each serial presentation pump; cancellation joins it.
    static func isCurrentObservation(at url: URL, observed: Stamp) async -> Bool {
        let probe = Task.detached(priority: .userInitiated) {
            try matchesCurrentObservation(at: url, observed: observed)
        }
        return await withTaskCancellationHandler {
            (try? await probe.value) ?? false
        } onCancel: { probe.cancel() }
    }
    private static func validate(_ url: URL, descriptor: Int32, metadata: Int32, observed: Stamp) throws {
        guard try Self.stamp(descriptor) == observed, try Self.stamp(metadata) == observed else { throw ZIPArchiveFailure.changed }
        let fresh = Darwin.open(url.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fresh >= 0 else { throw ZIPArchiveFailure.changed }; defer { close(fresh) }
        guard try Self.stamp(fresh) == observed else { throw ZIPArchiveFailure.changed }
    }
    private static func stamp(_ descriptor: Int32) throws -> Stamp {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size >= 0, value.st_flags & UInt32(SF_DATALESS) == 0 else { throw ZIPArchiveFailure.unsupported }
        return .init(device: value.st_dev, inode: value.st_ino, generation: value.st_gen, size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec, mode: value.st_mode, flags: value.st_flags)
    }
}

// Preserve archive callers and their existing failure contract. This is a
// concrete local descriptor owner, not a universal provider/source interface.
internal typealias ZIPSourceFile = PinnedLocalFileSource
