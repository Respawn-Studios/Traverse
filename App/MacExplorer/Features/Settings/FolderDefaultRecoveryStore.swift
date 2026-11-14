import Darwin
import ExplorerCore
import Foundation
import LocalStorage

// Closed generated-control boundaries. Production supplies no probe. No path,
// record or user-authored value crosses this qualification-only seam.
enum FolderDefaultStoreStage: String, CaseIterable, Sendable {
    case beforeReplace, afterTemporaryWrite, afterFileSync, afterRename
    case afterDirectorySync, beforeReadback, afterReadback
}

    // BEGIN quota3 admission
enum FolderDefaultWriteAdmissionFailure: Error, Sendable {
    case retainedTemporaryCapacity, inventoryCapacity
    case unsafeTemporaryMetadata, temporaryInventoryUnavailable
}

    // END quota3 admission
struct FolderDefaultRecoveryRecord: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Equatable, Sendable { case makeTraverse, restorePrevious }
    enum Stage: String, Codable, Equatable, Sendable {
        // Written before dispatch. A cold reader cannot distinguish no dispatch
        // from an in-flight/lost callback, so it must not infer an outcome.
        case pending, notSubmitted, matched, different, unreadable
    }
    var version = 1
    let recordID: UUID
    let traverse: FolderDefaultApplication
    let previous: FolderDefaultApplication
    let attemptID: UUID
    let direction: Direction
    var stage: Stage
    var callback: FolderDefaultCallback? = nil
    var observed: FolderDefaultApplication? = nil
    var destination: FolderDefaultApplication { direction == .makeTraverse ? traverse : previous }

    func validate() throws {
        try traverse.validate(); try previous.validate(); try observed?.validate()
        guard version == 1, FolderDefaultIdentityPolicy.acceptsRunning(traverse),
              previous.bundleIdentifier != traverse.bundleIdentifier else { throw FolderDefaultFailure.corruptStorage }
        switch stage {
        case .pending:
            guard callback == nil, observed == nil else { throw FolderDefaultFailure.corruptStorage }
        case .notSubmitted:
            guard callback == nil else { throw FolderDefaultFailure.corruptStorage }
        case .matched:
            guard callback != nil, observed?.identifies(destination) == true else { throw FolderDefaultFailure.corruptStorage }
        case .different:
            guard callback != nil, observed?.identifies(destination) != true else { throw FolderDefaultFailure.corruptStorage }
        case .unreadable:
            guard callback != nil, observed == nil else { throw FolderDefaultFailure.corruptStorage }
        }
    }
}

protocol FolderDefaultRecoveryStore: Sendable {
    func load() async throws -> FolderDefaultRecoveryRecord?
    /// Acknowledges only after file+parent synchronization and exact readback.
    func replace(expected: FolderDefaultRecoveryRecord?, with next: FolderDefaultRecoveryRecord) async throws
}

/// Dedicated bounded metadata, independent of General preference snapshots.
/// The app supplies its EXISTING state directory and its shared preparation
/// owner. No default path, personal-folder access, enumeration or broad cleanup.
final class NativeFolderDefaultRecoveryStore: FolderDefaultRecoveryStore, @unchecked Sendable {
    private struct Envelope: Codable { let version: Int; let record: FolderDefaultRecoveryRecord }
    private let queue = DispatchQueue(label: "Traverse.FolderDefault.Recovery", qos: .utility)
    private let directory: URL
    private let preparation: PrivateStateDirectorySequence
    private let activity: FileActivityGate
    private let probe: (@Sendable (FolderDefaultStoreStage) throws -> Void)?
    private var directoryIdentity: Identity? // serial worker only
    private static let fileName = "folder-opening-restore-v1.json"
    private static let maximumBytes = 32_768

    init(directory: URL, preparation: PrivateStateDirectorySequence, activity: FileActivityGate,
         probe: (@Sendable (FolderDefaultStoreStage) throws -> Void)? = nil) {
        self.directory = directory; self.preparation = preparation; self.activity = activity
        self.probe = probe
    }
    func load() async throws -> FolderDefaultRecoveryRecord? {
        // Passive inspection does not create the state directory or a file.
        try await perform { [self] in
            guard let fd = try openDirectory(allowMissing: true) else { return nil }
            defer { close(fd) }
            return try Self.readRecord(in: fd)
        }
    }
    func replace(expected: FolderDefaultRecoveryRecord?, with next: FolderDefaultRecoveryRecord) async throws {
        try next.validate()
        // This explicit write path is reached only after the user's consent.
        try await preparation.prepare()
        try await perform { [self] in
            guard let fd = try openDirectory(allowMissing: false) else { throw FolderDefaultFailure.unsafeStorage }
            defer { close(fd) }
            try probe?(.beforeReplace)
            guard try Self.readRecord(in: fd) == expected else { throw FolderDefaultFailure.changed }
            let bytes = try JSONEncoder().encode(Envelope(version: 1, record: next))
            guard bytes.count <= Self.maximumBytes else { throw FolderDefaultFailure.corruptStorage }
    // BEGIN quota3 admission
            try Self.admitTemporaryCapacity(in: fd, canonicalAlreadyPresent: expected != nil)
            // Inventory adds work between observation and allocation. Preserve
            // the exact canonical comparison immediately before the write too.
            guard try Self.readRecord(in: fd) == expected else { throw FolderDefaultFailure.changed }
    // END quota3 admission
            let name = ".folder-opening-\(UUID().uuidString).pending"
            let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw FolderDefaultFailure.unavailable }
            var published = false
            defer {
                close(output)
                if !published { _ = unlinkat(fd, name, 0) } // only this call's exclusive temporary file
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw FolderDefaultFailure.unavailable }
                    offset += count
                }
            }
            try probe?(.afterTemporaryWrite)
            guard fsync(output) == 0, fcntl(output, F_FULLFSYNC) == 0 else { throw FolderDefaultFailure.unavailable }
            try probe?(.afterFileSync)
            guard renameat(fd, name, fd, Self.fileName) == 0 else { throw FolderDefaultFailure.unavailable }
            published = true
            try probe?(.afterRename)
            guard fsync(fd) == 0 else { throw FolderDefaultFailure.unavailable }
            try probe?(.afterDirectorySync)
            try probe?(.beforeReadback)
            guard try Self.readBytes(in: fd) == bytes,
                  try Self.readRecord(in: fd) == next else { throw FolderDefaultFailure.unavailable }
            try probe?(.afterReadback)
            // The pathname must still name our pinned directory. An error after
            // rename is unconfirmed storage, and the caller must NOT submit.
            guard let fresh = try openDirectory(allowMissing: false, acquireLock: false) else { throw FolderDefaultFailure.changed }
            close(fresh)
        }
    }
    // BEGIN quota3 admission
    // These are write admission ceilings, not a passive-load health gate.
    private static let maximumTemporaryEntries = 3
    private static let maximumTemporaryBytes: Int64 = 65_536
    private static let maximumInventoryEntries = 64
    private static func admitTemporaryCapacity(in directory: Int32, canonicalAlreadyPresent: Bool) throws {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw FolderDefaultWriteAdmissionFailure.temporaryInventoryUnavailable }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate); throw FolderDefaultWriteAdmissionFailure.temporaryInventoryUnavailable
        }
        defer { closedir(stream) }
        var visited = 0, temporaryCount = 0
        var temporaryBytes: Int64 = 0
        let prefix = ".folder-opening-", suffix = ".pending"
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FolderDefaultWriteAdmissionFailure.temporaryInventoryUnavailable }
                break
            }
            let name: String? = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                guard let end = raw.firstIndex(of: 0) else { return nil }
                return String(decoding: raw[..<end], as: UTF8.self)
            }
            guard let name else { throw FolderDefaultWriteAdmissionFailure.unsafeTemporaryMetadata }
            if name == "." || name == ".." { continue }
            visited += 1
            guard visited <= Self.maximumInventoryEntries else { throw FolderDefaultWriteAdmissionFailure.inventoryCapacity }
            guard name.hasPrefix(prefix) else { continue }
            guard name.hasSuffix(suffix) else { throw FolderDefaultWriteAdmissionFailure.unsafeTemporaryMetadata }
            let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard UUID(uuidString: token)?.uuidString == token else { throw FolderDefaultWriteAdmissionFailure.unsafeTemporaryMetadata }
            var facts = stat()
            guard fstatat(directory, name, &facts, AT_SYMLINK_NOFOLLOW) == 0,
                  facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(), facts.st_nlink == 1,
                  facts.st_mode & 0o077 == 0, facts.st_size >= 0, facts.st_size <= Int64(Self.maximumBytes) else {
                throw FolderDefaultWriteAdmissionFailure.unsafeTemporaryMetadata
            }
            // Empty and undecodable temporary bodies are never opened. Only
            // no-follow shape/count/size facts contribute to this reservation.
            temporaryCount += 1; temporaryBytes += facts.st_size
            guard temporaryCount < Self.maximumTemporaryEntries,
                  temporaryBytes <= Self.maximumTemporaryBytes - Int64(Self.maximumBytes) else {
                throw FolderDefaultWriteAdmissionFailure.retainedTemporaryCapacity
            }
        }
        // Leave inventory room for this temporary and, on first publication,
        // the new canonical name so the later settled write can still be scanned.
        let inventoryReservation = canonicalAlreadyPresent ? 1 : 2
        guard visited + inventoryReservation <= Self.maximumInventoryEntries else {
            throw FolderDefaultWriteAdmissionFailure.inventoryCapacity
        }
        // Reserve one whole entry and maximum-size body even if this call's
        // encoded pending record is small; a later settled record may be larger.
        guard temporaryCount + 1 <= Self.maximumTemporaryEntries,
              temporaryBytes + Int64(Self.maximumBytes) <= Self.maximumTemporaryBytes else {
            throw FolderDefaultWriteAdmissionFailure.retainedTemporaryCapacity
        }
    }
    // END quota3 admission
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let result = Result {
                    let lease = try activity.begin()
                    defer { withExtendedLifetime(lease) {} }
                    return try body()
                }
                continuation.resume(with: result)
            }
        }
    }
    private func openDirectory(allowMissing: Bool, acquireLock: Bool = true) throws -> Int32? {
        let decoded = URLComponents(url: directory, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        guard directory.isFileURL, directory.baseURL == nil, directory.path.hasPrefix("/"),
              directory.path != "/", directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              let decoded, decoded.hasPrefix("/"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !decoded.split(separator: "/").contains("."), !decoded.split(separator: "/").contains(".."),
              !directory.pathComponents.contains("."), !directory.pathComponents.contains(".."),
              !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw FolderDefaultFailure.unsafeStorage }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if fd < 0 {
            if allowMissing, errno == ENOENT, directoryIdentity == nil { return nil }
            throw FolderDefaultFailure.unsafeStorage
        }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw FolderDefaultFailure.unsafeStorage }
            let identity = Identity(info)
            guard directoryIdentity == nil || directoryIdentity == identity else { throw FolderDefaultFailure.changed }
            // Cross-process cooperating writers serialize on the directory;
            // no additional lock file or unrelated state-file lock is needed.
            if acquireLock, flock(fd, LOCK_EX | LOCK_NB) != 0 { throw FolderDefaultFailure.unavailable }
            directoryIdentity = identity
            return fd
        } catch { close(fd); throw error }
    }
    private static func readRecord(in directory: Int32) throws -> FolderDefaultRecoveryRecord? {
        guard let bytes = try readBytes(in: directory) else { return nil }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1 else { throw FolderDefaultFailure.corruptStorage }
            try envelope.record.validate()
            return envelope.record
        } catch { throw FolderDefaultFailure.corruptStorage }
    }
    private static func readBytes(in directory: Int32) throws -> Data? {
        let fd = openat(directory, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw FolderDefaultFailure.unsafeStorage
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= Int64(maximumBytes) else { throw FolderDefaultFailure.unsafeStorage }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FolderDefaultFailure.unavailable }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(info) == Identity(after),
              info.st_size == after.st_size, info.st_mode == after.st_mode, info.st_uid == after.st_uid,
              info.st_nlink == after.st_nlink,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw FolderDefaultFailure.changed }
        return result
    }
    private struct Identity: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32, birthSeconds: Int, birthNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; generation = value.st_gen
            birthSeconds = value.st_birthtimespec.tv_sec; birthNanoseconds = value.st_birthtimespec.tv_nsec
        }
    }
}
