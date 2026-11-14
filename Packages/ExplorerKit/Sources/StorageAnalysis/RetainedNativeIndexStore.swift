import Darwin
import CryptoKit
import ExplorerCore
import Foundation

/// A fsynced publication decision, created before an ordinary store is
/// preserved. It owns exact cleanup evidence if the canonical rename fails.
struct RetainedPublicationIntent: Codable, Equatable, Sendable {
    let format: String, expectedEpoch: String
    let catalog: RetainedAnalysisRecord.Catalog
    let proposedSHA256: String
    init(record: RetainedAnalysisRecord, proposed: Data, expectedEpoch: UInt64) {
        format = "traverse-retained-publication-intent-v1"
        self.expectedEpoch = String(expectedEpoch)
        catalog = record.catalog
        proposedSHA256 = SHA256.hash(data: proposed).map { String(format: "%02x", $0) }.joined()
    }
    var epoch: UInt64? {
        guard let value = UInt64(expectedEpoch), String(value) == expectedEpoch else { return nil }
        return value
    }
    func validate() throws {
        try catalog.validate()
        guard format == "traverse-retained-publication-intent-v1", epoch != nil,
              proposedSHA256.utf8.count == 64,
              proposedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StorageScanFailure.changed
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count > 0, bytes.count <= 4096 else { throw StorageScanFailure.changed }
        return bytes
    }
    static func decodeCanonical(_ bytes: Data) throws -> Self {
        guard bytes.count > 0, bytes.count <= 4096 else { throw StorageScanFailure.changed }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard try value.encoded() == bytes else { throw StorageScanFailure.changed }
        return value
    }
}
struct RetainedPreparedPublication: Sendable {
    let intent: RetainedPublicationIntent
    let device: dev_t, inode: ino_t
    let bytes: Data
}
enum RetainedPublicationPreparation: Sendable {
    case prepared(RetainedPreparedPublication)
    case notCommitted(current: RetainedAnalysisIndex)
    case indeterminate
}

#if DEBUG
enum RetainedIndexFault: Equatable, Sendable { case afterStageCreate, afterRename, afterDatabaseUnlink }
#endif

/// Inactive, generated-only native format2 index. All blocking filesystem work
/// runs on this private utility queue. The caller must not hold pool.lock while
/// calling this store: destructive work takes index.lock then pool.lock.
final class RetainedNativeIndexStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "MacExplorer.RetainedIndex", qos: .utility)
    #if DEBUG
    private var injectedFault: RetainedIndexFault?
    func setFaultForQualification(_ fault: RetainedIndexFault?) async {
        await withCheckedContinuation { continuation in
            queue.async { self.injectedFault = fault; continuation.resume() }
        }
    }
    #endif
    init(directory: URL) { self.directory = directory }

    func bootstrap() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.bootstrapSync() }) }
        }
    }
    func load() async throws -> RetainedAnalysisIndex {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.loadSync() }) }
        }
    }
    /// Explicit recovery only. The staged image was never renamed while this
    /// lock was held. Discarding it does not certify a prior publication; a
    /// new controller must load current canonical truth after this returns.
    func recoverInterruptedStage() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.recoverInterruptedStageSync() }) }
        }
    }
    func commit(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64) async -> RetainedCommitOutcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.commitSync(proposed, expectedEpoch: expectedEpoch)) }
        }
    }
    func preparePublication(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64,
                            record: RetainedAnalysisRecord) async -> RetainedPublicationPreparation {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.preparePublicationSync(
                proposed, expectedEpoch: expectedEpoch, record: record)) }
        }
    }
    func commitPreparedPublication(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64,
                                   receipt: RetainedPreparedPublication) async -> RetainedCommitOutcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.commitPreparedPublicationSync(
                proposed, expectedEpoch: expectedEpoch, receipt: receipt)) }
        }
    }
    func recoverInterruptedPublication(poolURL: URL, quota: UInt64,
                                       activityGate: FileActivityGate,
                                       admittedBy: FileActivityGate.Lease? = nil) async throws -> RetainedAnalysisIndex {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result {
                try self.recoverInterruptedPublicationSync(poolURL: poolURL,
                    quota: quota, activityGate: activityGate, admittedBy: admittedBy)
            }) }
        }
    }

    func cleanup(_ catalog: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64,
                 poolURL: URL, quota: UInt64, activityGate: FileActivityGate) async -> RetainedCleanupReceipt {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.cleanupSync(catalog, expectedEpoch: expectedEpoch,
                    poolURL: poolURL, quota: quota, activityGate: activityGate))
            }
        }
    }
    private func cleanupSync(_ catalog: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64,
                             poolURL: URL, quota: UInt64, activityGate: FileActivityGate,
                             orphanIntent: RetainedPublicationIntent? = nil,
                             admittedBy: FileActivityGate.Lease? = nil) -> RetainedCleanupReceipt {
        var dbRemoved = false, lockRemoved = false, directoryRemoved = false
        do {
            try catalog.validate()
            let activity = try activityGate.continueOrBegin(admittedBy)
            defer { withExtendedLifetime(activity) {} }
            let indexFD = try Self.openPrivateDirectory(directory)
            defer { close(indexFD) }
            let indexLock = try Self.openLock(indexFD, operation: LOCK_EX)
            defer { close(indexLock) }
            let stagePresent = orphanIntent != nil ? try Self.validateStageIfPresent(indexFD) : false
            let index = try read(indexFD, allowStage: stagePresent, allowIntent: orphanIntent != nil)
            if let orphanIntent {
                let observed = try Self.readIntentReceipt(indexFD)
                guard observed.intent == orphanIntent, orphanIntent.catalog == catalog,
                      orphanIntent.epoch == expectedEpoch, index.epoch == expectedEpoch,
                      !index.visibleRecords.contains(where: { $0.catalogID == catalog.catalogID }),
                      index.retiring?.catalog.catalogID != catalog.catalogID,
                      !index.pendingForget.contains(where: { $0.catalog.catalogID == catalog.catalogID }) else {
                    return .deferred
                }
            } else {
                guard index.epoch == expectedEpoch,
                      index.retiring?.catalog == catalog || index.pendingForget.contains(where: { $0.catalog == catalog }) else {
                    return .deferred
                }
            }
            let pool = try Self.openPrivateDirectory(poolURL)
            defer { close(pool) }
            let poolLock = openat(pool, "pool.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard poolLock >= 0 else { return .deferred }
            defer { close(poolLock) }
            var lockStat = stat(), namedLock = stat()
            guard fstat(poolLock, &lockStat) == 0, Self.privateFile(lockStat),
                  flock(poolLock, LOCK_EX | LOCK_NB) == 0,
                  fstatat(pool, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
                  namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else { return .deferred }
            let name = catalog.sessionChild
            let parent = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            if parent < 0 {
                guard errno == ENOENT, fsync(pool) == 0 else { return .deferred }
                return .verifiedAbsent(catalog)
            }
            defer { close(parent) }
            var parentStat = stat(), namedParent = stat()
            guard fstat(parent, &parentStat) == 0, parentStat.st_mode & S_IFMT == S_IFDIR,
                  parentStat.st_uid == geteuid(), parentStat.st_mode & 0o7777 == 0o700,
                  fstatat(pool, name, &namedParent, AT_SYMLINK_NOFOLLOW) == 0,
                  namedParent.st_dev == parentStat.st_dev, namedParent.st_ino == parentStat.st_ino else { return .deferred }
            let children = try Self.names(parent)
            // These are the only post-unlink states produced by our ordered
            // cleanup. The durable tombstone was checked above; owner.lock is
            // empty, private and exclusively acquired before exact removal.
            if children == Set(["owner.lock"]) {
                let lease = openat(parent, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                guard lease >= 0 else { return .deferred }
                defer { close(lease) }
                var value = stat(), named = stat()
                guard fstat(lease, &value) == 0, Self.privateFile(value), value.st_size == 0,
                      flock(lease, LOCK_EX | LOCK_NB) == 0,
                      fstatat(parent, "owner.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_dev == value.st_dev, named.st_ino == value.st_ino else { return .deferred }
                guard fsync(parent) == 0,
                      unlinkat(parent, "owner.lock", 0) == 0 else { return .deferred }
                lockRemoved = true
                guard fsync(parent) == 0 else { return .partialUncertain(catalog, databaseRemoved: true, lockRemoved: true, directoryRemoved: false) }
            } else if !children.isEmpty && children != Set(["result.sqlite", "owner.lock"]) {
                return .partialUncertain(catalog, databaseRemoved: false, lockRemoved: false, directoryRemoved: false)
            }
            if children.isEmpty || lockRemoved {
                guard fstatat(pool, name, &namedParent, AT_SYMLINK_NOFOLLOW) == 0,
                      namedParent.st_dev == parentStat.st_dev,
                      namedParent.st_ino == parentStat.st_ino,
                      unlinkat(pool, name, AT_REMOVEDIR) == 0 else {
                    return .partialUncertain(catalog, databaseRemoved: true, lockRemoved: lockRemoved, directoryRemoved: false)
                }
                directoryRemoved = true
                guard fsync(pool) == 0 else {
                    return .partialUncertain(catalog, databaseRemoved: true, lockRemoved: lockRemoved, directoryRemoved: true)
                }
                return .removed(catalog)
            }
            let database = openat(parent, "result.sqlite", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            let lease = openat(parent, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard database >= 0, lease >= 0 else {
                if database >= 0 { close(database) }; if lease >= 0 { close(lease) }
                return .partialUncertain(catalog, databaseRemoved: database < 0, lockRemoved: lease < 0, directoryRemoved: false)
            }
            defer { close(database); close(lease) }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { return .deferred }
            try AnalysisStoreFiles.validate(pool: pool, parent: parent, database: database, lease: lease,
                poolURL: poolURL, name: name, quota: quota, sealed: true)
            let observedDigest = try Self.digest(database, quota: quota)
            guard observedDigest == catalog.sha256,
                  let expectedBytes = UInt64(catalog.bytes) else { return .deferred }
            var before = stat()
            guard fstat(database, &before) == 0, before.st_size >= 0,
                  UInt64(before.st_size) == expectedBytes else { return .deferred }
            guard unlinkat(parent, "result.sqlite", 0) == 0 else { return .deferred }
            dbRemoved = true
            #if DEBUG
            if injectedFault == .afterDatabaseUnlink {
                return .partialUncertain(catalog, databaseRemoved: true, lockRemoved: false, directoryRemoved: false)
            }
            #endif
            guard fsync(parent) == 0 else { return .partialUncertain(catalog, databaseRemoved: dbRemoved, lockRemoved: lockRemoved, directoryRemoved: directoryRemoved) }
            guard unlinkat(parent, "owner.lock", 0) == 0 else { return .partialUncertain(catalog, databaseRemoved: dbRemoved, lockRemoved: lockRemoved, directoryRemoved: directoryRemoved) }
            lockRemoved = true
            guard fsync(parent) == 0 else { return .partialUncertain(catalog, databaseRemoved: dbRemoved, lockRemoved: lockRemoved, directoryRemoved: directoryRemoved) }
            guard fstatat(pool, name, &namedParent, AT_SYMLINK_NOFOLLOW) == 0,
                  namedParent.st_dev == parentStat.st_dev,
                  namedParent.st_ino == parentStat.st_ino,
                  unlinkat(pool, name, AT_REMOVEDIR) == 0 else {
                return .partialUncertain(catalog, databaseRemoved: dbRemoved,
                    lockRemoved: lockRemoved, directoryRemoved: directoryRemoved)
            }
            directoryRemoved = true
            guard fsync(pool) == 0 else { return .partialUncertain(catalog, databaseRemoved: dbRemoved, lockRemoved: lockRemoved, directoryRemoved: directoryRemoved) }
            return .removed(catalog)
        } catch {
            return dbRemoved || lockRemoved || directoryRemoved
                ? .partialUncertain(catalog, databaseRemoved: dbRemoved, lockRemoved: lockRemoved, directoryRemoved: directoryRemoved)
                : .deferred
        }
    }
    private func recoverInterruptedPublicationSync(poolURL: URL, quota: UInt64,
                                                   activityGate: FileActivityGate,
                                                   admittedBy: FileActivityGate.Lease?) throws -> RetainedAnalysisIndex {
        let activity = try activityGate.continueOrBegin(admittedBy)
        defer { withExtendedLifetime(activity) {} }
        let intent: RetainedPublicationIntent
        // A committed canonical image already owns the catalog. Only its
        // extra intent needs removal, and a lingering stage is inconsistent.
        do {
            let fd = try Self.openPrivateDirectory(directory)
            defer { close(fd) }
            let lock = try Self.openLock(fd, operation: LOCK_EX)
            defer { close(lock) }
            let stage = try Self.validateStageIfPresent(fd)
            let current = try read(fd, allowStage: stage, allowIntent: true)
            intent = try Self.readIntentReceipt(fd).intent
            if current.visibleRecords.contains(where: { $0.catalog == intent.catalog }) {
                guard let expected = intent.epoch else { throw StorageScanFailure.changed }
                let next = expected.addingReportingOverflow(1)
                let currentBytes = try current.encoded()
                guard !next.overflow, current.epoch == next.partialValue,
                      SHA256.hash(data: currentBytes).map({ String(format: "%02x", $0) }).joined()
                          == intent.proposedSHA256,
                      !stage, unlinkat(fd, "publication.intent", 0) == 0,
                      fsync(fd) == 0 else { throw StorageScanFailure.changed }
                return try read(fd)
            }
            guard current.epoch == intent.epoch,
                  !current.visibleRecords.contains(where: { $0.catalogID == intent.catalog.catalogID }),
                  current.retiring?.catalog.catalogID != intent.catalog.catalogID,
                  !current.pendingForget.contains(where: { $0.catalog.catalogID == intent.catalog.catalogID }) else {
                throw StorageScanFailure.changed
            }
        }
        // The fsynced intent remains the deletion authority across every
        // failure boundary; the regular tombstone path cannot own this catalog.
        guard let expected = intent.epoch else { throw StorageScanFailure.changed }
        let removed = cleanupSync(intent.catalog, expectedEpoch: expected,
            poolURL: poolURL, quota: quota, activityGate: activityGate,
            orphanIntent: intent, admittedBy: activity)
        switch removed {
        case .removed(let catalog), .verifiedAbsent(let catalog):
            guard catalog == intent.catalog else { throw StorageScanFailure.changed }
        case .partialUncertain, .deferred, .indeterminate: throw StorageScanFailure.changed
        }
        let fd = try Self.openPrivateDirectory(directory)
        defer { close(fd) }
        let lock = try Self.openLock(fd, operation: LOCK_EX)
        defer { close(lock) }
        let stage = try Self.validateStageIfPresent(fd)
        let current = try read(fd, allowStage: stage, allowIntent: true)
        guard try Self.readIntentReceipt(fd).intent == intent,
              current.epoch == intent.epoch,
              !current.visibleRecords.contains(where: { $0.catalogID == intent.catalog.catalogID }) else {
            throw StorageScanFailure.changed
        }
        let pool = try Self.openPrivateDirectory(poolURL)
        defer { close(pool) }
        let poolLock = openat(pool, "pool.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard poolLock >= 0 else { throw StorageScanFailure.changed }
        defer { close(poolLock) }
        var lockFacts = stat(), namedLock = stat()
        guard fstat(poolLock, &lockFacts) == 0, Self.privateFile(lockFacts),
              flock(poolLock, LOCK_EX | LOCK_NB) == 0,
              fstatat(pool, "pool.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockFacts.st_dev, namedLock.st_ino == lockFacts.st_ino,
              fstatat(pool, intent.catalog.sessionChild, &namedLock, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT, fsync(pool) == 0 else { throw StorageScanFailure.changed }
        if stage {
            guard unlinkat(fd, "index.stage", 0) == 0,
                  fsync(fd) == 0 else { throw StorageScanFailure.changed }
        }
        guard unlinkat(fd, "publication.intent", 0) == 0,
              fsync(fd) == 0 else { throw StorageScanFailure.changed }
        return try read(fd)
    }
    private static func digest(_ fd: Int32, quota: UInt64) throws -> String {
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_size > 0,
              UInt64(before.st_size) <= quota else { throw StorageScanFailure.changed }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 << 10), offset: off_t = 0
        while offset < before.st_size {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, min($0.count, Int(before.st_size - offset)), offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            hasher.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw StorageScanFailure.changed }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readValidatedPublicationIntent(_ fd: Int32) throws -> RetainedPublicationIntent {
        try readIntentReceipt(fd).intent
    }
    static func validateStageIfPresent(_ fd: Int32) throws -> Bool {
        guard try names(fd).contains("index.stage") else { return false }
        let stage = openat(fd, "index.stage", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard stage >= 0 else { throw StorageScanFailure.changed }
        defer { close(stage) }
        var value = stat(), named = stat()
        guard fstat(stage, &value) == 0, privateFile(value), value.st_size >= 0,
              value.st_size <= Int64(RetainedAnalysisIndex.maximumEncodedBytes),
              fstatat(fd, "index.stage", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino else {
            throw StorageScanFailure.changed
        }
        return true
    }
    private static func readIntentReceipt(_ fd: Int32) throws -> RetainedPreparedPublication {
        let file = openat(fd, "publication.intent", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw StorageScanFailure.changed }
        defer { close(file) }
        var first = stat(), last = stat(), named = stat()
        guard fstat(file, &first) == 0, privateFile(first),
              first.st_size > 0, first.st_size <= 4096,
              fstatat(fd, "publication.intent", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == first.st_dev, named.st_ino == first.st_ino else {
            throw StorageScanFailure.changed
        }
        var bytes = Data(count: Int(first.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                pread(file, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            offset += count
        }
        guard fstat(file, &last) == 0, last.st_dev == first.st_dev,
              last.st_ino == first.st_ino, last.st_size == first.st_size,
              last.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec,
              last.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec,
              fstatat(fd, "publication.intent", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == first.st_dev, named.st_ino == first.st_ino else {
            throw StorageScanFailure.changed
        }
        return .init(intent: try RetainedPublicationIntent.decodeCanonical(bytes),
            device: first.st_dev, inode: first.st_ino, bytes: bytes)
    }
    private func bootstrapSync() throws {
        guard directory.isFileURL, directory.standardizedFileURL.path == directory.path,
              directory.lastPathComponent == "retained-analysis" else { throw StorageScanFailure.changed }
        let parent = try Self.openPrivateDirectory(directory.deletingLastPathComponent())
        defer { close(parent) }
        if mkdirat(parent, "retained-analysis", 0o700) != 0 && errno != EEXIST { throw StorageScanFailure.unavailable }
        let fd = try Self.openPrivateDirectory(directory)
        defer { close(fd) }
        let existing = try Self.names(fd)
        if existing == Set(["index.json", "index.lock"]) { _ = try read(fd); return }
        guard existing.isEmpty else { throw StorageScanFailure.changed }
        let lock = openat(fd, "index.lock", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw StorageScanFailure.changed }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StorageScanFailure.busy }
        let image = openat(fd, "index.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard image >= 0 else { throw StorageScanFailure.changed }
        defer { close(image) }
        try Self.writeAll(try RetainedAnalysisIndex().encoded(), to: image)
        guard fsync(image) == 0, fsync(fd) == 0, fsync(parent) == 0 else { throw StorageScanFailure.unavailable }
        _ = try read(fd)
    }
    private func loadSync() throws -> RetainedAnalysisIndex {
        let fd = try Self.openPrivateDirectory(directory)
        defer { close(fd) }
        let lock = try Self.openLock(fd, operation: LOCK_SH)
        defer { close(lock) }
        return try read(fd)
    }
    private func recoverInterruptedStageSync() throws {
        let fd = try Self.openPrivateDirectory(directory)
        defer { close(fd) }
        let lock = try Self.openLock(fd, operation: LOCK_EX)
        defer { close(lock) }
        guard try Self.names(fd) == Set(["index.json", "index.lock", "index.stage"]) else {
            throw StorageScanFailure.changed
        }
        let stage = openat(fd, "index.stage", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard stage >= 0 else { throw StorageScanFailure.changed }
        defer { close(stage) }
        var value = stat(), named = stat()
        guard fstat(stage, &value) == 0, Self.privateFile(value), value.st_size >= 0,
              value.st_size <= Int64(RetainedAnalysisIndex.maximumEncodedBytes),
              fstatat(fd, "index.stage", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino else { throw StorageScanFailure.changed }
        _ = try read(fd, allowStage: true)
        guard unlinkat(fd, "index.stage", 0) == 0,
              fsync(fd) == 0 else { throw StorageScanFailure.unavailable }
        _ = try read(fd)
    }
    private func preparePublicationSync(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64,
                                        record: RetainedAnalysisRecord) -> RetainedPublicationPreparation {
        do {
            let fd = try Self.openPrivateDirectory(directory)
            defer { close(fd) }
            let lock = try Self.openLock(fd, operation: LOCK_EX)
            defer { close(lock) }
            let current = try read(fd)
            guard current.epoch == expectedEpoch, try Self.allowed(current: current, proposed: proposed),
                  proposed.visibleRecords.contains(record),
                  !current.visibleRecords.contains(where: { $0.catalogID == record.catalogID }),
                  current.pendingForget.allSatisfy({ $0.catalog.catalogID != record.catalogID }),
                  current.retiring?.catalog.catalogID != record.catalogID else {
                return .notCommitted(current: current)
            }
            let intent = RetainedPublicationIntent(record: record,
                proposed: try proposed.encoded(), expectedEpoch: expectedEpoch)
            let bytes = try intent.encoded()
            let file = openat(fd, "publication.intent",
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard file >= 0 else { return .indeterminate }
            defer { close(file) }
            try Self.writeAll(bytes, to: file)
            guard fsync(file) == 0, fsync(fd) == 0 else { return .indeterminate }
            var facts = stat(), named = stat()
            guard fstat(file, &facts) == 0, Self.privateFile(facts),
                  facts.st_size == Int64(bytes.count),
                  fstatat(fd, "publication.intent", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == facts.st_dev, named.st_ino == facts.st_ino else { return .indeterminate }
            return .prepared(.init(intent: intent, device: facts.st_dev,
                inode: facts.st_ino, bytes: bytes))
        } catch { return .indeterminate }
    }
    private func commitPreparedPublicationSync(_ proposed: RetainedAnalysisIndex,
                                               expectedEpoch: UInt64,
                                               receipt: RetainedPreparedPublication) -> RetainedCommitOutcome {
        do {
            let fd = try Self.openPrivateDirectory(directory)
            defer { close(fd) }
            let lock = try Self.openLock(fd, operation: LOCK_EX)
            defer { close(lock) }
            let current = try read(fd, allowIntent: true)
            let observed = try Self.readIntentReceipt(fd)
            let bytes = try proposed.encoded()
            guard observed.device == receipt.device, observed.inode == receipt.inode,
                  observed.bytes == receipt.bytes, observed.intent == receipt.intent,
                  receipt.intent.epoch == expectedEpoch,
                  receipt.intent.proposedSHA256 == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(),
                  proposed.visibleRecords.contains(where: { $0.catalog == receipt.intent.catalog }),
                  current.epoch == expectedEpoch,
                  try Self.allowed(current: current, proposed: proposed) else { return .indeterminate }
            // From stage creation onward, no error attests absence of mutation.
            let stage = openat(fd, "index.stage", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard stage >= 0 else { return .indeterminate }
            defer { close(stage) }
            #if DEBUG
            if injectedFault == .afterStageCreate { return .indeterminate }
            #endif
            try Self.writeAll(bytes, to: stage)
            guard fsync(stage) == 0, renameat(fd, "index.stage", fd, "index.json") == 0 else {
                return .indeterminate
            }
            #if DEBUG
            if injectedFault == .afterRename { return .indeterminate }
            #endif
            guard fsync(fd) == 0,
                  try read(fd, allowIntent: true).encoded() == bytes,
                  unlinkat(fd, "publication.intent", 0) == 0,
                  fsync(fd) == 0,
                  try read(fd).encoded() == bytes else { return .indeterminate }
            return .committed
        } catch { return .indeterminate }
    }
    private func commitSync(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64) -> RetainedCommitOutcome {
        do {
            let fd = try Self.openPrivateDirectory(directory)
            defer { close(fd) }
            let lock = try Self.openLock(fd, operation: LOCK_EX)
            defer { close(lock) }
            let current = try read(fd)
            guard current.epoch == expectedEpoch, try Self.allowed(current: current, proposed: proposed) else {
                return .notCommitted(current: current)
            }
            // Every new visible catalog must have a durable publication
            // intent before its store can be preserved. Generic transitions
            // may only move already known catalog identities.
            let known = Set(current.visibleRecords.map(\.catalogID) +
                current.pendingForget.map { $0.catalog.catalogID } +
                (current.retiring.map { [$0.catalog.catalogID] } ?? []))
            guard proposed.visibleRecords.allSatisfy({ known.contains($0.catalogID) }) else {
                return .indeterminate
            }
            let bytes = try proposed.encoded()
            // From this O_EXCL stage creation onward, even a cancellation or
            // error cannot attest absence of native mutation.
            let stage = openat(fd, "index.stage", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard stage >= 0 else { return .indeterminate }
            var written = false
            defer { close(stage) }
            #if DEBUG
            if injectedFault == .afterStageCreate { return .indeterminate }
            #endif
            do {
                try Self.writeAll(bytes, to: stage)
                guard fsync(stage) == 0 else { return .indeterminate }
                written = true
            } catch { return .indeterminate }
            guard written, renameat(fd, "index.stage", fd, "index.json") == 0 else { return .indeterminate }
            #if DEBUG
            if injectedFault == .afterRename { return .indeterminate }
            #endif
            guard fsync(fd) == 0 else { return .indeterminate }
            let observed = try read(fd).encoded()
            guard observed == bytes else { return .indeterminate }
            return .committed
        } catch { return .indeterminate }
    }
    private func read(_ fd: Int32, allowStage: Bool = false,
                      allowIntent: Bool = false) throws -> RetainedAnalysisIndex {
        var expected = Set(["index.json", "index.lock"])
        if allowStage { expected.insert("index.stage") }
        if allowIntent { expected.insert("publication.intent") }
        guard try Self.names(fd) == expected else { throw StorageScanFailure.changed }
        let image = openat(fd, "index.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard image >= 0 else { throw StorageScanFailure.changed }
        defer { close(image) }
        var first = stat(), named = stat(), last = stat()
        guard fstat(image, &first) == 0, Self.privateFile(first),
              first.st_size > 0, first.st_size <= Int64(RetainedAnalysisIndex.maximumEncodedBytes),
              fstatat(fd, "index.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == first.st_dev, named.st_ino == first.st_ino else { throw StorageScanFailure.changed }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < Int(first.st_size) {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(image, $0.baseAddress, min($0.count, Int(first.st_size) - bytes.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(image, &last) == 0, last.st_dev == first.st_dev, last.st_ino == first.st_ino,
              last.st_size == first.st_size, last.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec,
              last.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec,
              fstatat(fd, "index.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == first.st_dev, named.st_ino == first.st_ino else { throw StorageScanFailure.changed }
        return try RetainedAnalysisIndex.decodeCanonical(bytes)
    }
    private static func allowed(current: RetainedAnalysisIndex, proposed: RetainedAnalysisIndex) throws -> Bool {
        let wanted = try proposed.encoded()
        let epoch = current.epoch
        for record in proposed.visibleRecords {
            if let candidate = try? current.publishing(record, expectedEpoch: epoch),
               let image = try? candidate.encoded(), image == wanted { return true }
            for old in current.visibleRecords {
                if let candidate = try? current.replacing(old.catalogID, with: record, expectedEpoch: epoch),
                   let image = try? candidate.encoded(), image == wanted { return true }
            }
        }
        let ids = current.visibleRecords.map(\.catalogID)
        for id in ids {
            if let candidate = try? current.beginningForget([id], expectedEpoch: epoch),
               let image = try? candidate.encoded(), image == wanted { return true }
        }
        if let candidate = try? current.beginningForgetAll(expectedEpoch: epoch),
           let image = try? candidate.encoded(), image == wanted { return true }
        if let retiring = current.retiring,
           let candidate = try? current.acknowledgingRetirement(retiring.catalog, expectedEpoch: epoch),
           let image = try? candidate.encoded(), image == wanted { return true }
        for pending in current.pendingForget {
            if let candidate = try? current.acknowledgingForget(pending.catalog, expectedEpoch: epoch),
               let image = try? candidate.encoded(), image == wanted { return true }
        }
        return false
    }
    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw StorageScanFailure.changed }
        var value = stat(), fs = statfs()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o700,
              fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              withUnsafeBytes(of: &fs.f_fstypename, { raw in
                  raw.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8))
              }) else { close(fd); throw StorageScanFailure.unsupportedLocation }
        return fd
    }
    private static func openLock(_ fd: Int32, operation: Int32) throws -> Int32 {
        let lock = openat(fd, "index.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard lock >= 0 else { throw StorageScanFailure.changed }
        var value = stat(), named = stat()
        guard fstat(lock, &value) == 0, privateFile(value), flock(lock, operation | LOCK_NB) == 0,
              fstatat(fd, "index.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino else {
            close(lock); throw StorageScanFailure.busy
        }
        return lock
    }
    private static func privateFile(_ value: stat) -> Bool { AnalysisStoreFiles.isPrivateFile(value) }
    private static func names(_ fd: Int32) throws -> Set<String> {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw StorageScanFailure.changed }
        defer { closedir(dir) }
        var values = Set<String>(); errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard values.count < 4, values.insert(name).inserted else { throw StorageScanFailure.changed }
        }
        guard errno == 0 else { throw StorageScanFailure.changed }
        return values
    }
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw StorageScanFailure.changed }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageScanFailure.unavailable }
                offset += count
            }
        }
    }
}
