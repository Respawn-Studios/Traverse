import Darwin
import ExplorerCore
import Foundation

public struct AnalysisTemporaryStorageObservation: Sendable {
    public enum Gap: String, CaseIterable, Sendable { case unexpectedEntry, unavailableItem, changedItem, sessionLimit, unavailableLease }
    public let exists: Bool
    public let sessions: Int
    public let openSessions: Int
    public let unheldSessions: Int
    public let files: Int
    public let logicalFileBytes: UInt64?
    public let allocatedNameBytes: UInt64?
    public let gaps: [Gap: Int]
    public let observedAt: Date
    public var isComplete: Bool { gaps.isEmpty && logicalFileBytes != nil && allocatedNameBytes != nil }
}

/// One explicit, shallow observation of the declared app-owned analysis pool.
/// Does not create it, open SQLite, read database/control bodies or discard any
/// result. Scalar observations are not quota credit or cleanup authority.
public final class AnalysisTemporaryStorageReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.AnalysisStorageInventory", qos: .utility)
    private let lock = NSLock()
    private let gate: FileActivityGate
    private var occupied = false
    private let maximumSessions: Int
    private let testHook: (@Sendable () throws -> Void)?
    #if DEBUG
    private var qualificationHook: (@Sendable () throws -> Void)?
    public func installAfterInventoryForQualification(_ hook: (@Sendable () throws -> Void)?) throws {
        try lock.withLock { guard !occupied else { throw StorageScanFailure.busy }; qualificationHook = hook }
    }
    #endif
    public init(activityGate: FileActivityGate) { gate = activityGate; maximumSessions = 4096; testHook = nil }
    init(activityGate: FileActivityGate, maximumSessions: Int, afterInventory: (@Sendable () throws -> Void)? = nil) {
        gate = activityGate; self.maximumSessions = min(4096, max(1, maximumSessions)); testHook = afterInventory
    }
    public var isBusy: Bool { lock.withLock { occupied } }

    public func read(directory: URL) async throws -> AnalysisTemporaryStorageObservation {
        guard lock.withLock({ if occupied { return false }; occupied = true; return true }) else { throw StorageScanFailure.busy }
        let control = ScannerProcessControl()
        #if DEBUG
        let hook = lock.withLock { let value = qualificationHook ?? testHook; qualificationHook = nil; return value }
        #else
        let hook = testHook
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<AnalysisTemporaryStorageObservation, Error>
                    do {
                        let activity = try gate.begin(); defer { withExtendedLifetime(activity) {} }
                        guard !control.cancelled else { throw CancellationError() }
                        let value = try Self.inspect(directory, maximumSessions: maximumSessions, cancelled: { control.cancelled }, afterInventory: hook)
                        guard !control.cancelled else { throw CancellationError() }
                        result = .success(value)
                    } catch { result = .failure(error) }
                    control.finished(); lock.withLock { occupied = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { control.cancel() }
    }

    private struct Pin: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32, birth: Int, birthNanos: Int
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; generation = value.st_gen; birth = value.st_birthtimespec.tv_sec; birthNanos = value.st_birthtimespec.tv_nsec }
    }
    private struct Totals {
        var sessions = 0, open = 0, unheld = 0, files = 0
        var logical: UInt64? = 0, allocated: UInt64? = 0
        var gaps: [AnalysisTemporaryStorageObservation.Gap: Int] = [:]
        mutating func gap(_ reason: AnalysisTemporaryStorageObservation.Gap) { gaps[reason, default: 0] += 1 }
        mutating func add(_ value: stat, file: Bool) {
            if file { files += 1; logical = logical.flatMap { let sum = $0.addingReportingOverflow(UInt64(value.st_size)); return sum.overflow ? nil : sum.partialValue } }
            let blocks = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
            allocated = blocks.overflow ? nil : allocated.flatMap { let sum = $0.addingReportingOverflow(blocks.partialValue); return sum.overflow ? nil : sum.partialValue }
        }
        func observation(exists: Bool) -> AnalysisTemporaryStorageObservation {
            .init(exists: exists, sessions: sessions, openSessions: open, unheldSessions: unheld, files: files,
                logicalFileBytes: logical, allocatedNameBytes: allocated, gaps: gaps, observedAt: Date())
        }
    }
    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
            && value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 && value.st_blocks >= 0
    }
    private static func privateFile(_ value: stat, device: Int32) -> Bool {
        AnalysisStoreFiles.isPrivateFile(value) && value.st_dev == device && value.st_size >= 0 && value.st_blocks >= 0
    }
    private static func nativeError() -> StorageScanFailure { errno == EACCES || errno == EPERM ? .accessDenied : .unavailable }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        Pin(a) == Pin(b) && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_flags == b.st_flags
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_blocks == b.st_blocks
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    /// Stream at most the fixed entry bound, resetting errno around readdir
    /// because the callback performs independent native calls.
    private static func entries(_ fd: Int32, maximum: Int, cancelled: () -> Bool, visit: (String?) throws -> Void) throws -> Bool {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard copy >= 0 else { throw nativeError() }
        guard let directory = fdopendir(copy) else { close(copy); throw nativeError() }
        defer { closedir(directory) }
        var count = 0
        while true {
            if cancelled() { throw CancellationError() }
            errno = 0
            guard let entry = readdir(directory) else { guard errno == 0 else { throw nativeError() }; return true }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) { Data(bytes: $0, count: Int(entry.pointee.d_namlen)) }
            }
            if name == Data([46]) || name == Data([46, 46]) { continue }
            guard count < maximum else { return false }; count += 1
            try visit(String(data: name, encoding: .utf8))
        }
    }
    private static func inspect(_ directory: URL, maximumSessions: Int, cancelled: () -> Bool,
                                afterInventory: (@Sendable () throws -> Void)? = nil) throws -> AnalysisTemporaryStorageObservation {
        guard directory.isFileURL, directory.host == nil || directory.host == "", directory.query == nil, directory.fragment == nil,
              directory.standardizedFileURL == directory, directory.path.utf8.count < 1024 else { throw StorageScanFailure.unsupportedLocation }
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard previous >= 0 else { throw StorageScanFailure.unsupportedLocation }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
              getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else { throw StorageScanFailure.unsupportedLocation }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if root < 0 { if errno == ENOENT { return Totals().observation(exists: false) }; throw nativeError() }
        defer { close(root) }
        var before = stat(), filesystem = statfs()
        guard fstat(root, &before) == 0, privateDirectory(before), fstatfs(root, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StorageScanFailure.unsupportedLocation }
        var namedLock = stat()
        guard fstatat(root, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0, privateFile(namedLock, device: before.st_dev) else { throw StorageScanFailure.changed }
        let poolLock = openat(root, "pool.lock", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard poolLock >= 0 else { throw nativeError() }; defer { close(poolLock) }
        var lockValue = stat(), named = stat()
        guard fstat(poolLock, &lockValue) == 0, privateFile(lockValue, device: before.st_dev), sameFile(lockValue, namedLock),
              fstatat(root, "pool.lock", &named, AT_SYMLINK_NOFOLLOW) == 0, sameFile(lockValue, named) else { throw StorageScanFailure.changed }
        guard flock(poolLock, LOCK_SH | LOCK_NB) == 0 else { throw StorageScanFailure.busy }
        var totals = Totals(); totals.add(before, file: false)
        let ended = try entries(root, maximum: maximumSessions + 1, cancelled: cancelled) { name in
            guard let name else { totals.gap(.unexpectedEntry); return }
            if name == "pool.lock" { totals.add(lockValue, file: true); return }
            let token = name.dropFirst(8)
            guard name.hasPrefix("session-"), token.utf8.count == 32,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { totals.gap(.unexpectedEntry); return }
            guard totals.sessions < maximumSessions else { totals.gap(.sessionLimit); return }
            let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard child >= 0 else { totals.gap(.unavailableItem); return }; defer { close(child) }
            var folder = stat()
            guard fstat(child, &folder) == 0, privateDirectory(folder), folder.st_dev == before.st_dev,
                  fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Pin(folder) == Pin(named) else { totals.gap(.changedItem); return }
            totals.sessions += 1; totals.add(folder, file: false)
            var foundLease = false, foundDatabase = false
            let complete = try entries(child, maximum: 4, cancelled: cancelled) { file in
                guard let file, ["result.sqlite", "owner.lock", "result.sqlite-journal"].contains(file) else { totals.gap(.unexpectedEntry); return }
                var value = stat(), after = stat()
                guard fstatat(child, file, &value, AT_SYMLINK_NOFOLLOW) == 0, privateFile(value, device: before.st_dev) else { totals.gap(.unavailableItem); return }
                if file == "result.sqlite" { foundDatabase = true }
                if file == "owner.lock" {
                    let lease = openat(child, file, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
                    if lease >= 0 {
                        defer { close(lease) }
                        guard fstat(lease, &after) == 0, sameFile(value, after) else { totals.gap(.changedItem); return }
                        if flock(lease, LOCK_EX | LOCK_NB) == 0 { totals.unheld += 1; foundLease = true }
                        else if errno == EWOULDBLOCK { totals.open += 1; foundLease = true }
                        else { totals.gap(.unavailableLease) }
                    } else { totals.gap(.unavailableLease) }
                }
                guard fstatat(child, file, &after, AT_SYMLINK_NOFOLLOW) == 0, sameFile(value, after) else { totals.gap(.changedItem); return }
                totals.add(value, file: true)
            }
            if !foundLease { totals.gap(.unavailableLease) }
            if !foundDatabase { totals.gap(.unavailableItem) }
            if !complete { totals.gap(.unexpectedEntry) }
            var final = stat()
            if fstatat(root, name, &final, AT_SYMLINK_NOFOLLOW) != 0 || !sameFile(folder, final) { totals.gap(.changedItem) }
        }
        if !ended { totals.gap(.sessionLimit) }
        try afterInventory?()
        if cancelled() { throw CancellationError() }
        let current = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard current >= 0 else { throw StorageScanFailure.changed }; defer { close(current) }
        var final = stat(), finalLock = stat(), finalFS = statfs()
        guard fstat(current, &final) == 0, privateDirectory(final), Pin(final) == Pin(before),
              fstatfs(current, &finalFS) == 0, finalFS.f_fsid.val.0 == filesystem.f_fsid.val.0, finalFS.f_fsid.val.1 == filesystem.f_fsid.val.1,
              fstatat(current, "pool.lock", &finalLock, AT_SYMLINK_NOFOLLOW) == 0, sameFile(lockValue, finalLock) else { throw StorageScanFailure.changed }
        if !sameFile(before, final) { totals.gap(.changedItem) }
        return totals.observation(exists: true)
    }
}
