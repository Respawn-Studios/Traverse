#if DEBUG
import CryptoKit
import Darwin
import Foundation
import FileOperations

// Independent generated-export ORACLE only. No backend counters, remote read,
// file-operation receipt, access grant or mutable storage authority is supplied.
// Captured directory identities precede publication. All filesystem syscalls
// and bounded bytes are handled inside explicit detached worker tasks.
struct GateAGeneratedExportOracle: Sendable {
    struct DirectoryIdentity: Equatable, Sendable {
        let device: Int64, inode: UInt64, owner: UInt32, mode: UInt32
        let birthSeconds: Int64, birthNanos: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino)
            owner = value.st_uid; mode = UInt32(value.st_mode)
            birthSeconds = Int64(value.st_birthtimespec.tv_sec)
            birthNanos = Int64(value.st_birthtimespec.tv_nsec)
        }
    }
    private struct Failure: Error, Sendable { let stage: String }
    private let root: URL
    private let rootIdentity: DirectoryIdentity, stateIdentity: DirectoryIdentity, exportIdentity: DirectoryIdentity
    private let expectedCount: Int
    private static let fileName = "Generated Retained Copy.txt"
    private static func requireWorkerThread() throws {
        guard !Thread.isMainThread else { throw Failure(stage: "oracle-worker-thread") }
    }
    private static func directory(_ fd: Int32) throws -> DirectoryIdentity {
        var value = stat()
        guard fd >= 0, fstat(fd, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o700 else { throw Failure(stage: "oracle-private-directory") }
        return .init(value)
    }
    private static func child(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(stage: "oracle-parent-open") }
        do { _ = try directory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }
    private static func requireName(_ parent: Int32, _ name: String, identity: DirectoryIdentity) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              DirectoryIdentity(named) == identity else { throw Failure(stage: "oracle-parent-name-replaced") }
    }
    static func capture(root: URL, expectedRoot: DirectoryIdentity, expectedByteCount: Int) async throws -> Self {
        try await Task.detached {
            try requireWorkerThread()
            guard expectedByteCount >= 0,
                  expectedByteCount <= TextDocumentValue.maximumBytes else { throw Failure(stage: "oracle-byte-bound") }
            let anchor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure(stage: "oracle-root-open") }
            defer { Darwin.close(anchor) }
            let observedRoot = try directory(anchor)
            guard observedRoot == expectedRoot else { throw Failure(stage: "oracle-root-not-admitted") }
            let state = try child(anchor, "state"); defer { Darwin.close(state) }
            let exports = try child(state, "Exports"); defer { Darwin.close(exports) }
            let stateID = try directory(state), exportID = try directory(exports)
            try requireName(anchor, "state", identity: stateID)
            try requireName(state, "Exports", identity: exportID)
            // The chooser has created only the exact parent; an existing leaf
            // refuses rather than becoming an overwrite/readback candidate.
            var leaf = stat()
            guard fstatat(exports, fileName, &leaf, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw Failure(stage: "oracle-export-already-exists") }
            return Self(root: root, rootIdentity: observedRoot, stateIdentity: stateID,
                exportIdentity: exportID, expectedCount: expectedByteCount)
        }.value
    }
    func readExact() async throws -> Data {
        try await Task.detached { [self] in
            try Self.requireWorkerThread()
            guard (0...TextDocumentValue.maximumBytes).contains(expectedCount) else { throw Failure(stage: "oracle-byte-bound") }
            let anchor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure(stage: "oracle-root-open") }
            defer { Darwin.close(anchor) }
            guard try Self.directory(anchor) == rootIdentity else { throw Failure(stage: "oracle-root-replaced") }
            let state = try Self.child(anchor, "state"); defer { Darwin.close(state) }
            let exports = try Self.child(state, "Exports"); defer { Darwin.close(exports) }
            guard try Self.directory(state) == stateIdentity,
                  try Self.directory(exports) == exportIdentity else { throw Failure(stage: "oracle-parent-replaced") }
            try Self.requireName(anchor, "state", identity: stateIdentity)
            try Self.requireName(state, "Exports", identity: exportIdentity)
            func allowed(_ value: stat) -> Bool {
                value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                    && value.st_uid == geteuid() && value.st_nlink == 1
                    && value.st_mode & 0o7777 == 0o644
                    && value.st_size == Int64(expectedCount)
            }
            func same(_ a: stat, _ b: stat) -> Bool {
                a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
                    && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size
                    && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec
                    && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec
                    && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
                    && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
                    && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
                    && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
            }
            var named = stat()
            guard fstatat(exports, Self.fileName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  allowed(named) else { throw Failure(stage: "oracle-export-kind-owner-mode-size") }
            let fd = openat(exports, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure(stage: "oracle-export-open") }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, allowed(before), same(named, before) else { throw Failure(stage: "oracle-export-replaced-before-read") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var bytes = Data()
            while let chunk = try handle.read(upToCount: min(32768, expectedCount + 1 - bytes.count)), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= expectedCount else { throw Failure(stage: "oracle-export-grew") }
            }
            var after = stat(), current = stat()
            guard bytes.count == expectedCount, fstat(fd, &after) == 0,
                  allowed(after), same(before, after),
                  fstatat(exports, Self.fileName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  allowed(current), same(after, current) else { throw Failure(stage: "oracle-export-unstable-read") }
            try Self.requireName(anchor, "state", identity: stateIdentity)
            try Self.requireName(state, "Exports", identity: exportIdentity)
            guard try Self.directory(anchor) == rootIdentity,
                  try Self.directory(state) == stateIdentity,
                  try Self.directory(exports) == exportIdentity else { throw Failure(stage: "oracle-parent-changed-during-read") }
            let currentRoot = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard currentRoot >= 0 else { throw Failure(stage: "oracle-root-name-changed") }
            defer { Darwin.close(currentRoot) }
            guard try Self.directory(currentRoot) == rootIdentity else { throw Failure(stage: "oracle-root-name-changed") }
            return bytes
        }.value
    }
}
#endif
