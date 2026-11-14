import CryptoKit
import Darwin
import Foundation

public enum SSHSelectedFileFailure: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidSelection, unavailable, changed, capacity, unsupported, permissions, stopped, busy
    public var description: String { "<selected SSH file unavailable>" }
    public var debugDescription: String { description }
}

struct SSHSelectedAccessHooks: Sendable {
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
}

final class SSHReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
}

/// A stamp belongs to this exact observed file, never a claim that a pathname
/// is a stable document identity or that a bookmark proves permission.
struct SSHSelectedFileStamp: Sendable, Equatable {
    let device: dev_t, inode: ino_t, size: off_t, mode: mode_t, links: nlink_t, owner: uid_t, flags: UInt32
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ facts: stat) {
        device = facts.st_dev; inode = facts.st_ino; size = facts.st_size; mode = facts.st_mode
        links = facts.st_nlink; owner = facts.st_uid; flags = facts.st_flags
        modifiedSeconds = facts.st_mtimespec.tv_sec; modifiedNanos = facts.st_mtimespec.tv_nsec
        changedSeconds = facts.st_ctimespec.tv_sec; changedNanos = facts.st_ctimespec.tv_nsec
    }
}

/// Concrete explicit SSH configuration/key access only. No discovery, writes,
/// private-key default probing, environment expansion or remote file hydration.
enum SSHSelectedFile {
    static func validLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.utf8.contains(0) && !name.contains("/")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func path(_ url: URL) throws -> String {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.path == url.standardizedFileURL.path,
              !url.path.utf8.contains(0), url.query == nil, url.fragment == nil else {
            throw SSHSelectedFileFailure.invalidSelection
        }
        return url.path
    }
    static func local(_ descriptor: Int32) throws {
        var facts = statfs()
        guard fstatfs(descriptor, &facts) == 0 else { throw SSHSelectedFileFailure.unavailable }
        guard facts.f_flags & UInt32(MNT_LOCAL) != 0 else { throw SSHSelectedFileFailure.unsupported }
    }
    static func directory(_ url: URL) throws -> Int32 {
        let fd = open(try path(url), O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw SSHSelectedFileFailure.unavailable }
        do { try local(fd); return fd } catch { close(fd); throw error }
    }
    static func read(_ descriptor: Int32, maximum: Int, privateKey: Bool,
                     check: () throws -> Void) throws -> (Data, SSHSelectedFileStamp) {
        guard !Thread.isMainThread, (1...(256 << 10)).contains(maximum) else { throw SSHSelectedFileFailure.busy }
        try check(); try local(descriptor)
        var facts = stat()
        guard fstat(descriptor, &facts) == 0 else { throw SSHSelectedFileFailure.unavailable }
        let stamp = SSHSelectedFileStamp(facts)
        guard facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_flags & UInt32(SF_DATALESS) == 0 else { throw SSHSelectedFileFailure.unsupported }
        guard facts.st_size >= 0, facts.st_size <= maximum else { throw SSHSelectedFileFailure.capacity }
        guard facts.st_mode & (S_IWGRP | S_IWOTH) == 0,
              !privateKey || facts.st_mode & (S_IRWXG | S_IRWXO) == 0 else { throw SSHSelectedFileFailure.permissions }
        var data = Data(), offset: Int64 = 0
        while offset < facts.st_size {
            try check()
            var bytes = [UInt8](repeating: 0, count: min(8192, Int(facts.st_size - offset)))
            let count = pread(descriptor, &bytes, bytes.count, offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SSHSelectedFileFailure.changed }
            data.append(contentsOf: bytes.prefix(count)); offset += Int64(count)
        }
        var extra: UInt8 = 0
        guard pread(descriptor, &extra, 1, offset) == 0, fstat(descriptor, &facts) == 0,
              SSHSelectedFileStamp(facts) == stamp else { throw SSHSelectedFileFailure.changed }
        try check(); return (data, stamp)
    }
    /// Reuses the same actual file/scope checks for explicitly selected identity
    /// inputs. Callers establish host review before entering this serial read.
    static func read(file: URL, accessRoot: URL?, maximum: Int, privateKey: Bool,
                     check: () throws -> Void, hooks: SSHSelectedAccessHooks = .init()) throws -> Data {
        guard !Thread.isMainThread else { throw SSHSelectedFileFailure.busy }
        try check()
        let active = hooks.start(accessRoot ?? file)
        defer { if active { hooks.stop(accessRoot ?? file) } }
        let descriptor = open(try path(file), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw SSHSelectedFileFailure.unavailable }
        defer { close(descriptor) }
        return try read(descriptor, maximum: maximum, privateKey: privateKey, check: check).0
    }
    /// A deliberately granted directory authorizes one fixed direct child.
    /// Reopening that child on each connection follows atomic certificate
    /// replacement without changing the authority or traversing a new path.
    static func read(leaf: String, in directoryURL: URL, maximum: Int,
                     check: () throws -> Void, hooks: SSHSelectedAccessHooks = .init()) throws -> Data {
        guard !Thread.isMainThread else { throw SSHSelectedFileFailure.busy }
        guard validLeaf(leaf) else { throw SSHSelectedFileFailure.invalidSelection }
        try check()
        let active = hooks.start(directoryURL)
        defer { if active { hooks.stop(directoryURL) } }
        let root = try directory(directoryURL)
        defer { close(root) }
        let descriptor = try openRelative(leaf, root: root)
        defer { close(descriptor) }
        let (body, stamp) = try read(descriptor, maximum: maximum, privateKey: false, check: check)
        var current = stat()
        guard fstatat(root, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SSHSelectedFileStamp(current) == stamp else { throw SSHSelectedFileFailure.changed }
        try check()
        return body
    }
    static func openRelative(_ relative: String, root: Int32, directory: Bool = false) throws -> Int32 {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) && $0.utf8.count <= 255 }) else {
            throw SSHSelectedFileFailure.invalidSelection
        }
        let fd = openat(root, relative, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw SSHSelectedFileFailure.unavailable }; return fd
    }
}
