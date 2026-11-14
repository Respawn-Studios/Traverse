import Darwin
import Foundation

enum ConnectionWorkspaceDisk {
    typealias File = ConnectionWorkspaceLocationFile
    static let compatibilityFence = "persistent-connections-v1.fence"
    static let graphKeys: Set<String> = ["metadata", "metadataLock", "metadataFence", "ledger", "ledgerLock",
        "bodies", "bodyLock", "bodyFence", "editors", "editorLock", "journal", "journalLock"]
    static let smbGraphKeys = graphKeys.union(["smbInPlace", "smbBodies", "smbBodyLock", "smbJournal", "smbJournalLock"])
    static func checkThread() throws { guard !Thread.isMainThread else { throw ConnectionWorkspaceFailure.busy }; try Task.checkCancellation() }
    static func missing(_ url: URL) throws -> Bool {
        var facts = stat()
        if lstat(url.path, &facts) == 0 { return false }
        guard errno == ENOENT else { throw ConnectionWorkspaceFailure.unsafe }; return true
    }
    static func requireAbsent(_ urls: [URL]) throws {
        for url in urls { guard try missing(url) else { throw ConnectionWorkspaceFailure.reviewRequired } }
    }
    static func identity(_ fd: Int32, directory: Bool, stable: Bool = false) throws -> ConnectionWorkspaceIdentity {
        var facts = stat(), volume = statfs()
        guard fstat(fd, &facts) == 0, facts.st_uid == geteuid(), facts.st_flags == 0,
              facts.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              facts.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
              directory || facts.st_nlink == 1 && facts.st_size >= 0 && facts.st_size <= 256 << 10,
              fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0
        else { throw ConnectionWorkspaceFailure.unsafe }
        let type = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard type == "apfs" else { throw ConnectionWorkspaceFailure.unsafe }
        return try .init(facts, volume: stable ? ConnectionWorkspaceVolumeIdentity.read(fd) : nil)
    }
    static func namedIdentity(_ parent: Int32, _ name: String, directory: Bool = false,
                              stable: Bool = false) throws -> ConnectionWorkspaceIdentity {
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY | O_NOFOLLOW_ANY : O_NOFOLLOW))
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(fd) }
        let actual = try identity(fd, directory: directory, stable: stable)
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              ConnectionWorkspaceIdentity(named).matchesPersisted(actual) else { throw ConnectionWorkspaceFailure.changed }
        return actual
    }
    static func openDirectory(_ path: URL) throws -> Int32 {
        guard let fd = try SMBCatalogFiles.openPool(path, create: false) else { throw ConnectionWorkspaceFailure.changed }
        do { _ = try identity(fd, directory: true); return fd } catch { Darwin.close(fd); throw error }
    }
    static func read(_ parent: Int32, _ name: String, maximum: Int) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(fd) }
        let id = try identity(fd, directory: false); var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_size <= maximum else { throw ConnectionWorkspaceFailure.unsafe }
        let before = ConnectionWorkspaceStamp(facts); var bytes = Data(count: Int(facts.st_size)), offset = 0
        while offset < bytes.count {
            let found = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if found < 0 && errno == EINTR { continue }
            guard found > 0 else { throw ConnectionWorkspaceFailure.changed }; offset += found
        }
        guard fstat(fd, &facts) == 0, ConnectionWorkspaceStamp(facts) == before,
              try namedIdentity(parent, name) == id else { throw ConnectionWorkspaceFailure.changed }; return bytes
    }
    static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ConnectionWorkspaceFailure.durabilityUncertain }
    }
    static func allocatorRefusal(_ id: UUID) -> Data { Data("MEXCONNECTIONWORKSPACE1 \(id.uuidString)\n".utf8) }
    static func fence(_ id: UUID) -> Data { Data("MEXPERSISTENTCONNECTIONS1 \(id.uuidString)\n".utf8) }
    static func establishLegacyFence(pool: Int32, lock: Int32, activation: UUID) throws {
        // This is the ACTUAL pool.lock previously acquired by the frozen old
        // allocator, not a new advisory lock. Old lockPool requires size==0.
        var facts = stat()
        guard fstat(lock, &facts) == 0, facts.st_size == 0,
              try identity(lock, directory: false) == namedIdentity(pool, "pool.lock") else { throw ConnectionWorkspaceFailure.changed }
        try DownloadDisk.writeAll(lock, allocatorRefusal(activation))
        guard fsync(lock) == 0, fcntl(lock, F_FULLFSYNC) == 0 else { throw ConnectionWorkspaceFailure.durabilityUncertain }
        try sync(pool)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.allocatorRefusalWritten)
        #endif
        let fd = openat(pool, compatibilityFence, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.reviewRequired }; defer { Darwin.close(fd) }
        try DownloadDisk.writeAll(fd, fence(activation)); try sync(fd); try sync(pool)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.compatibilityFenceWritten)
        #endif
    }
    static func validateLegacyFence(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord) throws {
        guard let activation = record.activationID else { throw ConnectionWorkspaceFailure.reviewRequired }
        let pool = try openDirectory(paths.earlier); defer { Darwin.close(pool) }
        let stable = record.format >= 3
        guard try record.earlier?.matchesPersisted(identity(pool, directory: true, stable: stable)) == true,
              try record.earlierLock?.matchesPersisted(namedIdentity(pool, "pool.lock", stable: stable)) == true,
              try read(pool, "pool.lock", maximum: 128) == allocatorRefusal(activation),
              try read(pool, compatibilityFence, maximum: 128) == fence(activation),
              Set(try DownloadDisk.names(pool, maximum: 2)) == ["pool.lock", compatibilityFence]
        else { throw ConnectionWorkspaceFailure.reviewRequired }
        try requireAbsent(paths.earlierSiblings)
    }
    static func graphIdentity(_ paths: ConnectionWorkspacePaths, stable: Bool = false,
                              includingSMB: Bool = false) throws -> [String: ConnectionWorkspaceIdentity] {
        var result: [String: ConnectionWorkspaceIdentity] = [:]
        let specifications = [(paths.graph[0], "metadata", "metadataLock", SFTPSharedBudgetTransaction.metadataFence, "metadataFence"),
            (paths.graph[1], "ledger", "ledgerLock", "", ""),
            (paths.graph[2], "bodies", "bodyLock", SFTPSharedBudgetTransaction.bodyFence, "bodyFence"),
            (paths.graph[3], "editors", "editorLock", "", ""), (paths.graph[4], "journal", "journalLock", "", "")]
        for (path, key, lockKey, fence, fenceKey) in specifications {
            let fd = try openDirectory(path); defer { Darwin.close(fd) }
            result[key] = try identity(fd, directory: true, stable: stable)
            result[lockKey] = try namedIdentity(fd, key == "metadata" || key == "bodies" ? "pool.lock" : "owner.lock", stable: stable)
            if !fence.isEmpty { result[fenceKey] = try namedIdentity(fd, fence, stable: stable) }
        }
        if includingSMB {
            let root = try openDirectory(paths.smbInPlaceRoot); defer { Darwin.close(root) }
            guard Set(try DownloadDisk.names(root, maximum: 2)) == ["bodies", "journal"] else {
                throw ConnectionWorkspaceFailure.changed
            }
            result["smbInPlace"] = try identity(root, directory: true, stable: stable)
            let bodies = try openDirectory(paths.smbInPlaceBodies); defer { Darwin.close(bodies) }
            result["smbBodies"] = try identity(bodies, directory: true, stable: stable)
            result["smbBodyLock"] = try namedIdentity(bodies, "pool.lock", stable: stable)
            let journal = try openDirectory(paths.smbInPlaceJournal); defer { Darwin.close(journal) }
            result["smbJournal"] = try identity(journal, directory: true, stable: stable)
            result["smbJournalLock"] = try namedIdentity(journal, "owner.lock", stable: stable)
        }
        return result
    }
    static func validateGraphIdentity(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord) throws {
        guard (record.isActive || (record.format == 2 || record.format == 3) && record.phase == .repairing),
              record.locationDigest == paths.locationDigest,
              let budget = record.budgetID else { throw ConnectionWorkspaceFailure.changed }
        let observed = try graphIdentity(paths, stable: record.format >= 3, includingSMB: record.format == 4)
        guard Set(observed.keys) == Set(record.graph.keys),
              record.graph.allSatisfy({ entry in
                  observed[entry.key].map { entry.value.matchesPersisted($0) } == true
              }) else {
            throw ConnectionWorkspaceFailure.changed
        }
        let metadata = try openDirectory(paths.metadata); defer { Darwin.close(metadata) }
        let bodies = try openDirectory(paths.graph[2]); defer { Darwin.close(bodies) }
        guard try SFTPSharedBudgetTransaction.readFence(metadata, name: SFTPSharedBudgetTransaction.metadataFence, prefix: "MEXSHAREDMETA1") == budget,
              try SFTPSharedBudgetTransaction.readFence(bodies, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == budget else { throw ConnectionWorkspaceFailure.changed }
    }
    static func validateGraph(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord, retirementAccess: SFTPRetainedMetadataAccess? = nil) throws {
        try validateGraphIdentity(paths, record: record)
        guard let budget = record.budgetID else { throw ConnectionWorkspaceFailure.changed }
        guard let ledger = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(paths.graph[1], writing: false, retainedRetirement: retirementAccess == nil ? nil : .inspectCommittedLedger) else { throw ConnectionWorkspaceFailure.changed }
        defer { ledger.close() }; try ledger.validateCurrent(); try ledger.snapshot.validate()
        guard ledger.snapshot.budgetID == budget, ledger.snapshot.poolPhase == .active else { throw ConnectionWorkspaceFailure.changed }
    }
    static func recordFootprint(_ paths: ConnectionWorkspacePaths) throws -> UInt64 {
        guard let fd = try SMBCatalogFiles.openPool(paths.record, create: false) else { return 0 }; defer { Darwin.close(fd) }
        var amount: UInt64 = 0
        for name in try DownloadDisk.names(fd, maximum: 3) {
            guard ["owner.lock", "servers.json", "pending.json"].contains(name) else { throw ConnectionWorkspaceFailure.unsafe }
            _ = try namedIdentity(fd, name)
            var facts = stat(); guard fstatat(fd, name, &facts, AT_SYMLINK_NOFOLLOW) == 0,
                facts.st_size >= 0, facts.st_size <= (name == "owner.lock" ? 0 : 8192), facts.st_blocks >= 0,
                UInt64(facts.st_blocks) <= SFTPSharedBudgetDocument.globalOverheadBytes / 512 else { throw ConnectionWorkspaceFailure.capacity }
            amount += max(UInt64(facts.st_size), UInt64(facts.st_blocks) * 512)
        }
        guard amount <= SFTPSharedBudgetDocument.globalOverheadBytes else { throw ConnectionWorkspaceFailure.capacity }; return amount
    }
    static func stamps(pool: Int32, record: SMBCatalogFiles.Record) throws -> [String: ConnectionWorkspaceStamp] {
        let fd = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(fd) }
        var result: [String: ConnectionWorkspaceStamp] = [:]
        for name in record.files.keys {
            var facts = stat(); guard fstatat(fd, name, &facts, AT_SYMLINK_NOFOLLOW) == 0 else { throw ConnectionWorkspaceFailure.changed }
            result[name] = .init(facts)
        }
        return result
    }
}
