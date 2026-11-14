import CryptoKit
import Darwin
import Foundation

/// Explicit repair only. The caller holds location EX and the complete
/// unchanged persistent graph owner for the entire mutation/publication.
enum ConnectionWorkspaceRepairDisk {
    typealias File = ConnectionWorkspaceLocationFile
    static func parentIdentities(_ paths: ConnectionWorkspacePaths,
                                 stable: Bool = false) throws -> [String: ConnectionWorkspaceIdentity] {
        guard (1...3).contains(paths.repairPreparation.count), let first = paths.repairPreparation.first else { throw ConnectionWorkspaceFailure.unsafe }
        let anchor = Darwin.open(first.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard anchor >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(anchor) }
        var result: [String: ConnectionWorkspaceIdentity] = ["-1": try parentIdentity(anchor, stable: stable)], missingSeen = false
        for (index, path) in paths.repairPreparation.enumerated() {
            let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            if fd < 0 {
                guard errno == ENOENT else { throw ConnectionWorkspaceFailure.unsafe }; missingSeen = true; continue
            }
            defer { Darwin.close(fd) }
            guard !missingSeen else { throw ConnectionWorkspaceFailure.changed }
            result[String(index)] = try parentIdentity(fd, stable: stable)
        }
        return result
    }
    private static func parentIdentity(_ fd: Int32, stable: Bool = false) throws -> ConnectionWorkspaceIdentity {
        var facts = stat(), volume = statfs()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR, facts.st_uid == geteuid(),
              facts.st_mode & 0o022 == 0, facts.st_flags == 0, fstatfs(fd, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ConnectionWorkspaceFailure.unsafe }
        let type = withUnsafePointer(to: &volume.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        guard type == "apfs" else { throw ConnectionWorkspaceFailure.unsafe }
        return try .init(facts, volume: stable ? ConnectionWorkspaceVolumeIdentity.read(fd) : nil)
    }
    private static func matches(_ stored: [String: ConnectionWorkspaceIdentity],
                                _ current: [String: ConnectionWorkspaceIdentity]) -> Bool {
        Set(stored.keys) == Set(current.keys) && stored.allSatisfy { entry in
            current[entry.key].map { entry.value.matchesPersisted($0) } == true
        }
    }
    static func eligible(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord) throws -> [String: ConnectionWorkspaceIdentity] {
        guard record.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
        try ConnectionWorkspaceDisk.requireAbsent([paths.earlier] + paths.earlierSiblings)
        return try parentIdentities(paths, stable: record.format == 3)
    }
    static func validateState(_ paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord,
                              heldStageLock: Int32? = nil) throws {
        guard (record.format == 2 || record.format == 3), let repair = record.repair else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        try repair.validate(record: record)
        try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings)
        if repair.stage == .intent {
            guard heldStageLock == nil else { throw ConnectionWorkspaceFailure.changed }
            guard try matches(repair.parentBefore,
                              parentIdentities(paths, stable: record.format == 3)) else { throw ConnectionWorkspaceFailure.changed }
            try ConnectionWorkspaceDisk.requireAbsent([paths.earlier, stageURL(paths, repair)])
            return
        }
        guard try matches(repair.parents,
                          parentIdentities(paths, stable: record.format == 3)) else { throw ConnectionWorkspaceFailure.changed }
        if repair.stage == .parentsReady {
            guard heldStageLock == nil else { throw ConnectionWorkspaceFailure.changed }
            try ConnectionWorkspaceDisk.requireAbsent([paths.earlier, stageURL(paths, repair)]); return
        }
        let location = try locate(paths, repair)
        let published = location.path == paths.earlier.path
        if repair.stage.rawValue < ConnectionWorkspaceRepairStage.fullyFenced.rawValue, published { throw ConnectionWorkspaceFailure.changed }
        if repair.stage.rawValue >= ConnectionWorkspaceRepairStage.published.rawValue, !published { throw ConnectionWorkspaceFailure.changed }
        let pool = try ConnectionWorkspaceDisk.openDirectory(location); defer { Darwin.close(pool) }
        let lock: Int32
        if let heldStageLock {
            guard try repair.lock?.matchesPersisted(ConnectionWorkspaceDisk.identity(heldStageLock, directory: false,
                                                                                      stable: record.format == 3)) == true,
                  try repair.lock?.matchesPersisted(ConnectionWorkspaceDisk.namedIdentity(pool, "pool.lock",
                                                                                           stable: record.format == 3)) == true else {
                throw ConnectionWorkspaceFailure.changed
            }
            lock = heldStageLock
        } else {
            lock = try heldLock(pool, repair: repair)
        }
        defer { if heldStageLock == nil { Darwin.close(lock) } }
        try validateFiles(pool, lock: lock, repair: repair, activation: record.activationID)
    }
    static func repair(_ paths: ConnectionWorkspacePaths, file: File, choice: ConnectionWorkspaceRepairChoice,
                       preparation: PrivateStateDirectorySequence) throws {
        try ConnectionWorkspaceDisk.checkThread(); try file.validateRepairCurrent()
        guard choice.paths == paths, try file.repairReadIdentity() == choice.location,
              try file.snapshot.encoded() == choice.current, try file.pending?.encoded() == choice.pending else { throw ConnectionWorkspaceFailure.changed }
        let graph = try ConnectionWorkspaceRepairGraph.open(paths: paths, record: file.snapshot)
        defer { graph.close() }
        func save(_ next: ConnectionWorkspaceRecord) throws {
            try graph.validateCurrent(); try file.validateCurrent(); try commit(next, file: file)
        }
        guard graph.observation == choice.observation else { throw ConnectionWorkspaceFailure.changed }
        #if DEBUG
        try ConnectionWorkspaceRepairQualification.shared.reach(.graphHeld)
        #endif
        try Task.checkCancellation()
        if let pending = file.pending {
            guard choice.action == .resume else { throw ConnectionWorkspaceFailure.changed }
            try validateState(paths, record: pending); try graph.validateCurrent(); try file.promoteExactRepairPending()
        }
        if choice.action == .repair {
            let before = try eligible(paths, record: file.snapshot)
            guard before == choice.parents, let oldRoot = file.snapshot.earlier, let oldLock = file.snapshot.earlierLock else { throw ConnectionWorkspaceFailure.changed }
            var next = file.snapshot
            let repair = ConnectionWorkspaceRepairRecord(id: UUID(), sourceDigest: Data(SHA256.hash(data: try next.encoded())),
                sourceRevision: next.revision, priorEarlier: oldRoot, priorLock: oldLock,
                parentCount: paths.repairPreparation.count, parentBefore: before)
            if next.format != 3 {
                next.format = 2; next.protocolIdentity = "traverse-persistent-connections-v2"
            }
            next.phase = .repairing
            next.revision += 1; next.repair = repair; try save(next)
            #if DEBUG
            try ConnectionWorkspaceRepairQualification.shared.reach(.intentRecorded)
            #endif
        } else {
            guard (file.snapshot.format == 2 || file.snapshot.format == 3),
                  file.snapshot.repair != nil else { throw ConnectionWorkspaceFailure.reviewRequired }
        }
        for _ in 0..<8 {
            try Task.checkCancellation(); try file.validateCurrent(); try graph.validateCurrent()
            var next = file.snapshot
            guard var repair = next.repair else { throw ConnectionWorkspaceFailure.reviewRequired }
            try validateState(paths, record: next)
            if repair.stage == .complete { return }
            if repair.stage == .intent {
                // Only the configured finite profile chain can create parents.
                // An unrecorded partial from a previous attempt is not adopted.
                try preparation.prepareFromBackgroundThread()
                repair.parents = try parentIdentities(paths, stable: next.format == 3)
                guard repair.parents.count == repair.parentCount + 1 else { throw ConnectionWorkspaceFailure.changed }
                repair.stage = .parentsReady; next.repair = repair; next.revision += 1; try save(next)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.parentsRecorded)
                #endif
                continue
            }
            let parent = try openParent(paths, repair); defer { Darwin.close(parent) }
            if repair.stage == .parentsReady {
                try ConnectionWorkspaceDisk.requireAbsent([paths.earlier, stageURL(paths, repair)])
                guard mkdirat(parent, repair.stageName, 0o700) == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
                let pool = openat(parent, repair.stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                guard pool >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(pool) }
                let lock = openat(pool, "pool.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ConnectionWorkspaceFailure.busy }
                repair.root = try ConnectionWorkspaceDisk.identity(pool, directory: true, stable: next.format == 3)
                repair.lock = try ConnectionWorkspaceDisk.identity(lock, directory: false, stable: next.format == 3)
                try ConnectionWorkspaceDisk.sync(lock); try ConnectionWorkspaceDisk.sync(pool); try ConnectionWorkspaceDisk.sync(parent)
                repair.stage = .stageRecorded; next.repair = repair; next.revision += 1; try save(next)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.stageRecorded)
                #endif
                continue
            }
            let location = try locate(paths, repair)
            let pool = try ConnectionWorkspaceDisk.openDirectory(location); defer { Darwin.close(pool) }
            let lock = try heldLock(pool, repair: repair); defer { Darwin.close(lock) }
            guard let activation = next.activationID else { throw ConnectionWorkspaceFailure.changed }
            try validateFiles(pool, lock: lock, repair: repair, activation: activation)
            if repair.stage == .stageRecorded {
                try completeOwnedFile(lock, expected: ConnectionWorkspaceDisk.allocatorRefusal(activation))
                try ConnectionWorkspaceDisk.sync(pool)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.allocatorWritten)
                #endif
                repair.stage = .allocatorFenced
            } else if repair.stage == .allocatorFenced {
                let marker = openat(pool, ConnectionWorkspaceDisk.compatibilityFence, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard marker >= 0 else { throw ConnectionWorkspaceFailure.reviewRequired }; defer { Darwin.close(marker) }
                repair.marker = try ConnectionWorkspaceDisk.identity(marker, directory: false, stable: next.format == 3)
                try ConnectionWorkspaceDisk.sync(marker); try ConnectionWorkspaceDisk.sync(pool)
                repair.stage = .markerRecorded
            } else if repair.stage == .markerRecorded {
                let marker = openat(pool, ConnectionWorkspaceDisk.compatibilityFence, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard marker >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(marker) }
                guard try repair.marker?.matchesPersisted(ConnectionWorkspaceDisk.identity(marker, directory: false,
                                                                                            stable: next.format == 3)) == true else {
                    throw ConnectionWorkspaceFailure.changed
                }
                try completeOwnedFile(marker, expected: ConnectionWorkspaceDisk.fence(activation))
                try ConnectionWorkspaceDisk.sync(pool); try ConnectionWorkspaceDisk.sync(parent)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.markerWritten)
                #endif
                repair.stage = .fullyFenced
            } else if repair.stage == .fullyFenced {
                try verifyParent(paths, parent: parent, repair: repair)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.beforePublication)
                #endif
                try Task.checkCancellation(); try graph.validateCurrent(); try file.validateCurrent()
                if location.path != paths.earlier.path {
                    try ConnectionWorkspaceDisk.requireAbsent([paths.earlier] + paths.earlierSiblings)
                    try ConnectionWorkspaceDisk.sync(pool); try ConnectionWorkspaceDisk.sync(parent)
                    try verifyParent(paths, parent: parent, repair: repair); try Task.checkCancellation()
                    guard renameatx_np(parent, repair.stageName, parent, paths.earlier.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
                }
                try ConnectionWorkspaceDisk.sync(parent)
                #if DEBUG
                try ConnectionWorkspaceRepairQualification.shared.reach(.published)
                #endif
                repair.stage = .published
            } else if repair.stage == .published {
                next.earlier = repair.root; next.earlierLock = repair.lock; next.phase = .active; repair.stage = .complete
            } else { throw ConnectionWorkspaceFailure.reviewRequired }
            next.repair = repair; next.revision += 1
            // The staged pool EX remains held across validation and the
            // durable location commit. A second flock here would conflict
            // with our own real owner descriptor.
            try validateState(paths, record: next, heldStageLock: lock)
            try save(next)
            #if DEBUG
            switch repair.stage {
            case .allocatorFenced: try ConnectionWorkspaceRepairQualification.shared.reach(.allocatorRecorded)
            case .markerRecorded: try ConnectionWorkspaceRepairQualification.shared.reach(.markerRecorded)
            case .fullyFenced: try ConnectionWorkspaceRepairQualification.shared.reach(.fullyFencedRecorded)
            case .published: try ConnectionWorkspaceRepairQualification.shared.reach(.publicationRecorded)
            case .complete: try ConnectionWorkspaceRepairQualification.shared.reach(.activeRecorded)
            default: break
            }
            #endif
        }
        guard file.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
    }
    private static func commit(_ next: ConnectionWorkspaceRecord, file: File) throws {
        guard try ConnectionWorkspaceRepairRecord.successor(file.snapshot, next) else { throw ConnectionWorkspaceFailure.changed }
        try file.commit(next)
    }
    private static func stageURL(_ paths: ConnectionWorkspacePaths, _ repair: ConnectionWorkspaceRepairRecord) -> URL {
        paths.earlier.deletingLastPathComponent().appendingPathComponent(repair.stageName, isDirectory: true)
    }
    private static func locate(_ paths: ConnectionWorkspacePaths, _ repair: ConnectionWorkspaceRepairRecord) throws -> URL {
        let stage = stageURL(paths, repair), stageMissing = try ConnectionWorkspaceDisk.missing(stage), finalMissing = try ConnectionWorkspaceDisk.missing(paths.earlier)
        guard stageMissing != finalMissing else { throw ConnectionWorkspaceFailure.reviewRequired }
        let selected = stageMissing ? paths.earlier : stage
        let fd = try ConnectionWorkspaceDisk.openDirectory(selected); defer { Darwin.close(fd) }
        guard try repair.root?.matchesPersisted(ConnectionWorkspaceDisk.identity(fd, directory: true,
                                                                                  stable: repair.root?.volume != nil)) == true else {
            throw ConnectionWorkspaceFailure.changed
        }
        return selected
    }
    private static func openParent(_ paths: ConnectionWorkspacePaths, _ repair: ConnectionWorkspaceRepairRecord) throws -> Int32 {
        guard try matches(repair.parents,
                          parentIdentities(paths, stable: repair.parentBefore["-1"]?.volume != nil)) else {
            throw ConnectionWorkspaceFailure.changed
        }
        let fd = Darwin.open(paths.earlier.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }
        do { try verifyParent(paths, parent: fd, repair: repair); return fd } catch { Darwin.close(fd); throw error }
    }
    private static func verifyParent(_ paths: ConnectionWorkspacePaths, parent: Int32, repair: ConnectionWorkspaceRepairRecord) throws {
        let stable = repair.parentBefore["-1"]?.volume != nil
        guard try matches(repair.parents, parentIdentities(paths, stable: stable)),
              try repair.parents[String(repair.parentCount - 1)]?.matchesPersisted(parentIdentity(parent, stable: stable)) == true else {
            throw ConnectionWorkspaceFailure.changed
        }
    }
    private static func heldLock(_ pool: Int32, repair: ConnectionWorkspaceRepairRecord) throws -> Int32 {
        let stable = repair.root?.volume != nil
        guard try repair.root?.matchesPersisted(ConnectionWorkspaceDisk.identity(pool, directory: true,
                                                                                  stable: stable)) == true else {
            throw ConnectionWorkspaceFailure.changed
        }
        let fd = openat(pool, "pool.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }
        do {
            let actual = try ConnectionWorkspaceDisk.identity(fd, directory: false, stable: stable)
            guard repair.lock?.matchesPersisted(actual) == true,
                  try ConnectionWorkspaceDisk.namedIdentity(pool, "pool.lock", stable: stable) == actual else {
                throw ConnectionWorkspaceFailure.changed
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConnectionWorkspaceFailure.busy }; return fd
        } catch { Darwin.close(fd); throw error }
    }
    private static func validateFiles(_ pool: Int32, lock: Int32, repair: ConnectionWorkspaceRepairRecord, activation: UUID?) throws {
        guard let activation else { throw ConnectionWorkspaceFailure.changed }
        let hasMarker = repair.stage.rawValue >= ConnectionWorkspaceRepairStage.markerRecorded.rawValue
        guard Set(try DownloadDisk.names(pool, maximum: 3)) == (hasMarker ? Set(["pool.lock", ConnectionWorkspaceDisk.compatibilityFence]) : Set(["pool.lock"])) else { throw ConnectionWorkspaceFailure.reviewRequired }
        let actual = try ConnectionWorkspaceDisk.read(pool, "pool.lock", maximum: 128), expected = ConnectionWorkspaceDisk.allocatorRefusal(activation)
        guard repair.stage == .stageRecorded ? expected.starts(with: actual) : actual == expected else { throw ConnectionWorkspaceFailure.changed }
        if hasMarker {
            guard try repair.marker?.matchesPersisted(ConnectionWorkspaceDisk.namedIdentity(pool,
                ConnectionWorkspaceDisk.compatibilityFence, stable: repair.marker?.volume != nil)) == true else {
                throw ConnectionWorkspaceFailure.changed
            }
            let actual = try ConnectionWorkspaceDisk.read(pool, ConnectionWorkspaceDisk.compatibilityFence, maximum: 128), expected = ConnectionWorkspaceDisk.fence(activation)
            guard repair.stage == .markerRecorded ? expected.starts(with: actual) : actual == expected else { throw ConnectionWorkspaceFailure.changed }
        }
        _ = lock // The exact actual allocator fd remains exclusively held.
    }
    private static func completeOwnedFile(_ fd: Int32, expected: Data) throws {
        var offset = 0
        while offset < expected.count {
            try Task.checkCancellation()
            let found = expected.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if found < 0 && errno == EINTR { continue }
            guard found > 0 else { throw ConnectionWorkspaceFailure.durabilityUncertain }; offset += found
        }
        guard ftruncate(fd, off_t(expected.count)) == 0, fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw ConnectionWorkspaceFailure.durabilityUncertain }
    }
}
