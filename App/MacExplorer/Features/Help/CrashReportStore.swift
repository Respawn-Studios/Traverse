import CryptoKit
import Darwin
import Foundation
import LocalStorage

/// Normal-launch storage only. The signal handler never enters Swift or this
/// store. One worker owns the lease and all reads/writes for its lifetime.
final class CrashReportStore {
    struct PendingReport {
        let data: Data
        fileprivate let directoryIdentity: stat
        fileprivate let leafVersion: stat
    }
    /// An opaque observation of the engine's fixed live leaf. It contains no
    /// report bytes or caller-selected path and is valid for one explicit
    /// discard attempt after normal recovery fails.
    struct PendingDiscardCandidate {
        fileprivate let directoryIdentity: stat
        fileprivate let leafVersion: stat
    }
    struct Record: Codable, Sendable {
        let report: CrashReport
        let nativeData: Data
        let digest: String
        let retainedAt: Date
    }
    private struct Catalog: Codable {
        var schema = 1
        var records: [Record] = []
    }
    static let maximumNativeBytes = 1 << 20
    private static let maximumRetainedBytes = 4 << 20
    private static let maximumReports = 5
    private static let pendingName = "live_report.plcrash"
    private static let cacheName = "com.plausiblelabs.crashreporter.data"
    private let file: BrowserSnapshotFile
    private let lease: BrowserSnapshotFile.LifetimeLease
    private var catalog: Catalog
    private var original: Data?
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        file = BrowserSnapshotFile(directory: directory, name: "reports-v1.json", maximumBytes: Self.maximumRetainedBytes,
            requiresPrivateDurability: true)
        guard let lease = try file.acquireMutationLease(create: true) else { throw CrashReportFailure.busy }
        self.lease = lease
        original = try file.read()
        catalog = try original.map(Self.decode) ?? Catalog()
        try lease.validate()
    }

    var reports: [CrashReport] { catalog.records.map(\.report) }

    func requireCaptureSpace() throws {
        try lease.validate()
        guard try file.read() == original else { throw CrashReportFailure.changed }
        guard catalog.records.count < Self.maximumReports,
              (original?.count ?? 0) <= Self.maximumRetainedBytes - Self.maximumNativeBytes else {
            throw CrashReportFailure.capacity
        }
    }

    /// Acknowledges an existing capture only after its complete bytes and safe
    /// projection have been durably retained. Full/invalid stores stay intact.
    func retain(_ nativeData: Data, report: CrashReport) throws {
        guard !nativeData.isEmpty, nativeData.count <= Self.maximumNativeBytes else { throw CrashReportFailure.capacity }
        let digest = Self.digest(nativeData)
        if catalog.records.contains(where: { $0.digest == digest }) { return }
        guard catalog.records.count < Self.maximumReports else { throw CrashReportFailure.capacity }
        var next = catalog
        next.records.insert(.init(report: report, nativeData: nativeData, digest: digest, retainedAt: Date()), at: 0)
        try publish(next)
    }

    func remove(_ id: UUID) throws {
        var next = catalog
        next.records.removeAll { $0.report.id == id }
        guard next.records.count < catalog.records.count else { throw CrashReportFailure.changed }
        // Replace the acknowledged catalog, including raw bytes. This is ordinary
        // local removal, not secure erasure or a change to the OS crash reports.
        try publish(next)
    }

    func validate() throws { try lease.validate() }

    /// Read only the fixed, private native leaf. An empty, oversized, linked,
    /// redirected or changing report stays in place and prevents capture setup.
    func readPending(applicationIdentifier: String) throws -> PendingReport? {
        try validate()
        let parent = try openEngineDirectory(applicationIdentifier: applicationIdentifier)
        let pending = try Self.observePending(in: parent)
        try parent.validate()
        try validate()
        return pending
    }

    /// Called only after retain() has durably acknowledged the exact native
    /// bytes. All path and byte checks precede descriptor-relative removal.
    func purgePending(_ pending: PendingReport, applicationIdentifier: String) throws {
        try validate()
        let pendingDigest = Self.digest(pending.data)
        guard let original, let durable = try file.read(), durable == original,
              catalog.records.contains(where: {
                  $0.digest == pendingDigest && $0.nativeData == pending.data
              }) else { throw CrashReportFailure.changed }
        let parent = try openEngineDirectory(applicationIdentifier: applicationIdentifier)
        guard Self.sameIdentity(parent.identity, pending.directoryIdentity),
              let current = try Self.observePending(in: parent),
              Self.sameVersion(current.leafVersion, pending.leafVersion),
              current.data == pending.data else { throw CrashReportFailure.changed }
        try parent.validate()
        try validate()
        var named = stat()
        guard fstatat(parent.fd, Self.pendingName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameVersion(named, pending.leafVersion),
              unlinkat(parent.fd, Self.pendingName, 0) == 0 else { throw CrashReportFailure.changed }
        guard fsync(parent.fd) == 0 else { throw CrashReportFailure.io }
        try parent.validate()
        try validate()
        guard fstatat(parent.fd, Self.pendingName, &named, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw CrashReportFailure.changed }
    }

    /// Inspect only the fixed leaf after failed recovery. A malformed regular
    /// file or symlink can be offered for explicit discard without opening it.
    func observeUnrecoveredPendingForDiscard(applicationIdentifier: String) throws -> PendingDiscardCandidate? {
        try validate()
        let parent = try openEngineDirectory(applicationIdentifier: applicationIdentifier)
        try parent.validate()
        var leaf = stat(), confirmed = stat()
        guard fstatat(parent.fd, Self.pendingName, &leaf, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw CrashReportFailure.invalid
        }
        guard Self.discardableLeaf(leaf) else { throw CrashReportFailure.invalid }
        try parent.validate()
        try validate()
        guard fstatat(parent.fd, Self.pendingName, &confirmed, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameVersion(leaf, confirmed) else { throw CrashReportFailure.changed }
        return PendingDiscardCandidate(directoryIdentity: parent.identity, leafVersion: confirmed)
    }

    /// The worker calls this only after a separate user confirmation. Reopen
    /// the private directory chain and prove the same leaf before unlinkat.
    /// The candidate is never a general path or a directory removal request.
    func discardUnrecoveredPending(_ candidate: PendingDiscardCandidate,
                                   applicationIdentifier: String) throws {
        try validate()
        let parent = try openEngineDirectory(applicationIdentifier: applicationIdentifier)
        guard Self.sameIdentity(parent.identity, candidate.directoryIdentity) else {
            throw CrashReportFailure.changed
        }
        var named = stat()
        guard fstatat(parent.fd, Self.pendingName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.discardableLeaf(named), Self.sameVersion(named, candidate.leafVersion) else {
            throw CrashReportFailure.changed
        }
        try parent.validate()
        try validate()
        guard fstatat(parent.fd, Self.pendingName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.discardableLeaf(named), Self.sameVersion(named, candidate.leafVersion),
              unlinkat(parent.fd, Self.pendingName, 0) == 0 else { throw CrashReportFailure.changed }
        guard fsync(parent.fd) == 0 else { throw CrashReportFailure.io }
        try parent.validate()
        try validate()
        guard fstatat(parent.fd, Self.pendingName, &named, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw CrashReportFailure.changed }
    }

    /// The library creates permissive children by default. Establish and verify
    /// the exact private descendants before handing it a base path.
    func prepareEngineDirectory(applicationIdentifier: String) throws -> URL {
        try Self.validateIdentifier(applicationIdentifier)
        let base = directory.appendingPathComponent("capture", isDirectory: true)
        let family = base.appendingPathComponent(Self.cacheName, isDirectory: true)
        let process = family.appendingPathComponent(applicationIdentifier, isDirectory: true)
        for child in [base, family, process, process.appendingPathComponent("queued_reports", isDirectory: true)] {
            let guardFile = BrowserSnapshotFile(directory: child, name: "directory-owner", maximumBytes: 1,
                requiresPrivateDurability: true)
            guard let owner = try guardFile.acquireMutationLease(create: true) else { throw CrashReportFailure.busy }
            try owner.validate()
        }
        try validate()
        return base
    }

    private static func validateIdentifier(_ value: String) throws {
        guard ["com.respawnstudios.traverse", "local.macexplorer.development",
               "local.macexplorer.preview"].contains(value) else { throw CrashReportFailure.invalid }
    }

    private func openEngineDirectory(applicationIdentifier: String) throws -> EngineDirectory {
        try Self.validateIdentifier(applicationIdentifier)
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/",
              !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else {
            throw CrashReportFailure.invalid
        }
        return try EngineDirectory(statePath: directory.path,
            children: ["capture", Self.cacheName, applicationIdentifier])
    }

    private final class EngineDirectory {
        let statePath: String
        let children: [String]
        private var descriptors: [Int32] = []
        private var identities: [stat] = []
        private var completed = false
        var fd: Int32 { descriptors.last! }
        var identity: stat { identities.last! }

        init(statePath: String, children: [String]) throws {
            self.statePath = statePath; self.children = children
            defer { if !completed { for descriptor in descriptors.reversed() { close(descriptor) } } }
            let state = open(statePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard state >= 0 else { throw CrashReportFailure.invalid }
            descriptors.append(state)
            var facts = stat()
            guard fstat(state, &facts) == 0, Self.privateDirectory(facts) else { throw CrashReportFailure.invalid }
            identities.append(facts)
            for child in children {
                let next = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw CrashReportFailure.invalid }
                descriptors.append(next)
                var opened = stat(), named = stat()
                guard fstat(next, &opened) == 0, Self.privateDirectory(opened),
                      fstatat(descriptors[descriptors.count - 2], child, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      CrashReportStore.sameIdentity(opened, named) else { throw CrashReportFailure.invalid }
                identities.append(opened)
            }
            try validate()
            completed = true
        }

        deinit { if completed { for descriptor in descriptors.reversed() { close(descriptor) } } }

        func validate() throws {
            let currentState = open(statePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard currentState >= 0 else { throw CrashReportFailure.changed }
            defer { close(currentState) }
            var current = stat()
            guard fstat(currentState, &current) == 0,
                  CrashReportStore.sameIdentity(current, identities[0]),
                  Self.privateDirectory(current) else { throw CrashReportFailure.changed }
            for index in 1..<descriptors.count {
                var held = stat(), named = stat()
                guard fstat(descriptors[index], &held) == 0,
                      fstatat(descriptors[index - 1], children[index - 1], &named, AT_SYMLINK_NOFOLLOW) == 0,
                      CrashReportStore.sameIdentity(held, identities[index]),
                      CrashReportStore.sameIdentity(held, named),
                      Self.privateDirectory(held), Self.privateDirectory(named) else {
                    throw CrashReportFailure.changed
                }
            }
        }

        private static func privateDirectory(_ value: stat) -> Bool {
            value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
        }
    }

    private static func observePending(in parent: EngineDirectory) throws -> PendingReport? {
        try parent.validate()
        let descriptor = openat(parent.fd, pendingName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CrashReportFailure.invalid
        }
        defer { close(descriptor) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o777 == 0o600,
              before.st_size > 0, before.st_size <= Int64(maximumNativeBytes) else {
            throw CrashReportFailure.invalid
        }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CrashReportFailure.changed }
                offset += count
            }
        }
        guard fstat(descriptor, &after) == 0, sameVersion(before, after),
              fstatat(parent.fd, pendingName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameVersion(after, named) else { throw CrashReportFailure.changed }
        try parent.validate()
        return PendingReport(data: bytes, directoryIdentity: parent.identity, leafVersion: after)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec
            && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
    }

    private static func discardableLeaf(_ value: stat) -> Bool {
        let kind = value.st_mode & S_IFMT
        return kind == S_IFREG || kind == S_IFLNK
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func publish(_ next: Catalog) throws {
        try lease.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(next)
        let expected: BrowserSnapshotFile.ExpectedVersion = original.map { .bytes($0) } ?? .absent
        try file.write(bytes, replacing: expected) { _ = try Self.decode($0) }
        original = bytes; catalog = next
    }

    private static func decode(_ bytes: Data) throws -> Catalog {
        let value = try JSONDecoder().decode(Catalog.self, from: bytes)
        guard value.schema == 1, value.records.count <= maximumReports,
              Set(value.records.map { $0.report.id }).count == value.records.count,
              Set(value.records.map(\.digest)).count == value.records.count else { throw CrashReportFailure.invalid }
        for record in value.records {
            try record.report.validate()
            guard !record.nativeData.isEmpty, record.nativeData.count <= maximumNativeBytes,
                  record.digest == digest(record.nativeData), record.retainedAt.timeIntervalSince1970.isFinite else {
                throw CrashReportFailure.invalid
            }
        }
        return value
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
