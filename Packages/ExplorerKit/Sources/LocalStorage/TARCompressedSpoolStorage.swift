import CryptoKit
import Darwin
import Foundation

/// A descriptor-anchored private spool store. The caller serializes this owner
/// on its preparation worker and keeps it alive through actual retirement.
internal final class TARCompressedSpoolStorage {
    struct Prepared: Sendable {
        let descriptor: Int32
        let stamp: TARCompressedSpoolLease.Stamp
        let digest: Data
        let decodedBytes: UInt64
        let allocatedBytes: UInt64
        let catalog: TARCatalogStorage
    }
    let directory: URL
    private var root: Int32
    private(set) var uncertainCleanup = false

    init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              directory.standardizedFileURL.path == directory.path,
              !directory.path.utf8.contains(0) else { throw TARArchiveFailure.unavailable }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw TARArchiveFailure.unavailable }
        do {
            try Self.requirePrivateAPFS(fd)
            self.directory = directory; root = fd
        } catch { close(fd); throw error }
    }
    deinit { if root >= 0 { close(root) } }
    /// Called only by the pool's serial worker after every spool is retired.
    func closeRoot() -> Bool {
        guard root >= 0 else { return true }
        let held = root; root = -1
        return close(held) == 0
    }
    /// A renamed or replaced cache child cannot become the write destination.
    /// Cleanup can still use the pinned descriptor without following the path.
    private func validateRootPath() throws {
        try Self.requirePrivateAPFS(root)
        let fresh = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fresh >= 0 else { throw TARArchiveFailure.changed }
        defer { close(fresh) }
        try Self.requirePrivateAPFS(fresh)
        var held = stat(), named = stat()
        guard fstat(root, &held) == 0, fstat(fresh, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
            throw TARArchiveFailure.changed
        }
    }
    func requireFreeCapacity() throws {
        try validateRootPath()
        var facts = statfs()
        guard fstatfs(root, &facts) == 0, facts.f_bsize > 0,
              facts.f_bavail >= 0 else { throw TARArchiveFailure.unavailable }
        let free = UInt64(facts.f_bavail).multipliedReportingOverflow(by: UInt64(facts.f_bsize))
        guard !free.overflow, free.partialValue >= TARCompressedDecoder.maximumBytes + (64 << 20) else {
            throw TARArchiveFailure.limited
        }
    }

    /// Only exact UUID children with our complete durable owner marker and one
    /// bounded regular spool can be retired after a crash. Unknown arrivals are
    /// preserved and prevent new private writes.
    func requireNoOrphans() throws {
        try validateRootPath()
        let scan = dup(root)
        guard scan >= 0, let stream = fdopendir(scan) else {
            if scan >= 0 { close(scan) }
            uncertainCleanup = true
            throw TARArchiveFailure.unavailable
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names = [String]()
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < 4, UUID(uuidString: name)?.uuidString == name else {
                uncertainCleanup = true; throw TARArchiveFailure.unavailable
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else { uncertainCleanup = true; throw TARArchiveFailure.unavailable }
        for name in names {
            guard retireMarkedOrphan(name) else { uncertainCleanup = true; throw TARArchiveFailure.unavailable }
        }
        if !names.isEmpty, fsync(root) != 0 { uncertainCleanup = true; throw TARArchiveFailure.unavailable }
    }

    private func retireMarkedOrphan(_ id: String) -> Bool {
        let child = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return false }
        defer { close(child) }
        guard (try? Self.requirePrivateAPFS(child)) != nil else { return false }
        let marker = openat(child, "owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard marker >= 0 else { return false }
        defer { close(marker) }
        var facts = stat()
        guard fstat(marker, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_mode & 0o7777 == 0o600 else { return false }
        let expected = Data("Traverse.compressed-tar.v1\n\(id)\n".utf8)
        guard facts.st_size == Int64(expected.count),
              (try? Self.read(marker, offset: 0, count: expected.count, length: UInt64(expected.count), check: {})) == expected else {
            return false
        }
        guard Self.exactOrphanChildren(child) else { return false }
        let output = openat(child, "decoded.tar", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if output >= 0 {
            defer { close(output) }
            guard (try? Self.requireOwnedRegular(output, links: 1)) != nil,
                  fstat(output, &facts) == 0, facts.st_size >= 0, facts.st_blocks >= 0,
                  UInt64(facts.st_size) <= TARCompressedDecoder.maximumBytes,
                  Self.admittedAllocation(blocks: facts.st_blocks) != nil else { return false }
            var named = stat()
            guard fstatat(child, "decoded.tar", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == facts.st_dev, named.st_ino == facts.st_ino,
                  unlinkat(child, "decoded.tar", 0) == 0 else { return false }
        } else if errno != ENOENT { return false }
        var namedMarker = stat()
        guard fstatat(child, "owner", &namedMarker, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        // Compare against the still-open marker rather than trusting its name.
        var heldMarker = stat()
        guard fstat(marker, &heldMarker) == 0,
              namedMarker.st_dev == heldMarker.st_dev, namedMarker.st_ino == heldMarker.st_ino,
              unlinkat(child, "owner", 0) == 0,
              fsync(child) == 0,
              unlinkat(root, id, AT_REMOVEDIR) == 0 else { return false }
        return true
    }

    private static func exactOrphanChildren(_ child: Int32) -> Bool {
        let scan = dup(child)
        guard scan >= 0, let stream = fdopendir(scan) else {
            if scan >= 0 { close(scan) }
            return false
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var found = Set<String>()
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard name == "owner" || name == "decoded.tar", found.insert(name).inserted else { return false }
            errno = 0
        }
        return errno == 0 && found.contains("owner")
    }

    func prepare(_ proof: TARCompressedOriginalProof, excluding roots: [URL],
                 cancellation: TARCompressedDecoder.Cancellation,
                 progress: @escaping @Sendable (TARCompressedPreparationProgress.Phase, UInt64, UInt64) -> Void) throws -> Prepared {
        guard !uncertainCleanup else { throw TARArchiveFailure.unavailable }
        progress(.checkingSource, 0, 0)
        let source = try PinnedLocalFileSource(proof.source, excluding: roots)
        guard source.observed == proof.stamp else { throw TARArchiveFailure.changed }
        let originalSecurity = try proof.security.reobserve(source)
        guard originalSecurity == proof.security else { throw TARArchiveFailure.changed }
        try source.validate()
        guard source.observed.size >= 0, UInt64(source.observed.size) <= TARCompressedDecoder.maximumBytes else {
            throw TARArchiveFailure.limited
        }
        guard cancellation.poll() == 0 else { throw cancellation.failure }
        progress(.checkingRoot, 0, 0)
        try validateRootPath()

        let id = UUID().uuidString
        guard mkdirat(root, id, 0o700) == 0 else { throw TARArchiveFailure.unavailable }
        let child = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            uncertainCleanup = true
            throw TARArchiveFailure.unavailable
        }
        var output: Int32 = -1, reader: Int32 = -1, marker: Int32 = -1
        var completed = false
        defer {
            if !completed, !cleanup(child: child, id: id, output: output >= 0 ? output : reader, marker: marker) {
                uncertainCleanup = true
            }
            if marker >= 0 { close(marker) }
            if output >= 0 { close(output) }
            if !completed, reader >= 0 { close(reader) }
            close(child)
        }
        try Self.requirePrivateAPFS(child)
        marker = openat(child, "owner", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard marker >= 0 else { throw TARArchiveFailure.unavailable }
        let ownership = Data("Traverse.compressed-tar.v1\n\(id)\n".utf8)
        try Self.write(marker, ownership)
        guard fsync(marker) == 0, fsync(child) == 0, fsync(root) == 0 else { throw TARArchiveFailure.unavailable }

        output = openat(child, "decoded.tar", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw TARArchiveFailure.unavailable }
        try Self.requireOwnedRegular(output, links: 1)
        let monitor = Self.monitor(output, cancellation: cancellation, progress: { progress(.decoding, $0, $1) })
        let decoded: TARCompressedDecoder.Outcome
        progress(.decoding, 0, 0)
        do { decoded = try TARCompressedDecoder.expand(input: source.descriptor, output: output, cancellation: cancellation) }
        catch { monitor.stop(); throw error }
        monitor.stop()
        guard decoded.compressedBytes == UInt64(source.observed.size), decoded.decodedBytes <= TARCompressedDecoder.maximumBytes else {
            throw TARArchiveFailure.malformed
        }
        try source.validate()
        guard try proof.security.reobserve(source) == proof.security else {
            throw TARArchiveFailure.changed
        }

        reader = openat(child, "decoded.tar", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard reader >= 0 else { throw TARArchiveFailure.unavailable }
        try Self.requireSameRegular(output, reader, bytes: decoded.decodedBytes, links: 1)
        var limits = TARReadLimits(); limits.sourceBytes = TARCompressedDecoder.maximumBytes
        let started = ProcessInfo.processInfo.systemUptime
        func check() throws {
            guard cancellation.poll() == 0 else { throw cancellation.failure }
            guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else { throw TARArchiveFailure.limited }
        }
        progress(.validating, decoded.decodedBytes, try Self.allocation(reader))
        let parsed = try TARMetadataParser.parse(length: decoded.decodedBytes, limits: limits,
            check: check, read: { offset, count in
                try Self.read(reader, offset: offset, count: count, length: decoded.decodedBytes, check: check)
            })
        progress(.cataloging, decoded.decodedBytes, try Self.allocation(reader))
        let catalog = try TARCatalogBuilder.build(parsed, limits: limits, check: check)
        var digest = SHA256(), offset: UInt64 = 0
        while offset < decoded.decodedBytes {
            try check()
            let count = Int(min(65_536, decoded.decodedBytes - offset))
            digest.update(data: try Self.read(reader, offset: offset, count: count, length: decoded.decodedBytes, check: check))
            offset += UInt64(count)
        }
        try Self.requireSameRegular(output, reader, bytes: decoded.decodedBytes, links: 1)
        try source.validate()
        guard try proof.security.reobserve(source) == proof.security else {
            throw TARArchiveFailure.changed
        }
        let allocatedBytes = try Self.allocation(reader)
        try validateRootPath()
        guard close(output) == 0 else { output = -1; throw TARArchiveFailure.unavailable }
        output = -1
        try Self.requireOwnedRegular(reader, links: 1)
        guard unlinkat(child, "decoded.tar", 0) == 0,
              unlinkat(child, "owner", 0) == 0,
              fsync(child) == 0,
              unlinkat(root, id, AT_REMOVEDIR) == 0,
              fsync(root) == 0 else { throw TARArchiveFailure.unavailable }
        let stamp = try TARCompressedSpoolLease.Stamp(reader)
        completed = true
        return .init(descriptor: reader, stamp: stamp, digest: Data(digest.finalize()),
            decodedBytes: decoded.decodedBytes, allocatedBytes: allocatedBytes, catalog: catalog)
    }

    private func cleanup(child: Int32, id: String, output: Int32, marker: Int32) -> Bool {
        // The UUID directory was created exclusively under the pinned root.
        // Refuse deletion if either expected child was replaced or became a link.
        for (name, descriptor) in [("decoded.tar", output), ("owner", marker)] {
            var named = stat()
            if fstatat(child, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                return false
            }
            guard named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(), named.st_nlink == 1 else { return false }
            if descriptor >= 0 {
                var held = stat()
                guard fstat(descriptor, &held) == 0, held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return false }
            }
            guard unlinkat(child, name, 0) == 0 else { return false }
        }
        guard fsync(child) == 0, unlinkat(root, id, AT_REMOVEDIR) == 0 else { return false }
        return fsync(root) == 0
    }

    private static func requirePrivateAPFS(_ fd: Int32) throws {
        var facts = stat(), volume = statfs()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o700,
              fstatfs(fd, &volume) == 0 else { throw TARArchiveFailure.unavailable }
        let type = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard type == "apfs" else { throw TARArchiveFailure.unsupported }
    }
    private static func requireOwnedRegular(_ fd: Int32, links: UInt16) throws {
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o600,
              facts.st_nlink == links, facts.st_size >= 0 else { throw TARArchiveFailure.changed }
    }
    private static func requireSameRegular(_ left: Int32, _ right: Int32, bytes: UInt64, links: UInt16) throws {
        try requireOwnedRegular(left, links: links); try requireOwnedRegular(right, links: links)
        var a = stat(), b = stat()
        guard fstat(left, &a) == 0, fstat(right, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_size >= 0,
              UInt64(a.st_size) == bytes, b.st_size == a.st_size else { throw TARArchiveFailure.changed }
    }
    /// st_blocks uses 512-byte units. Four charged spools can therefore never
    /// exceed the separate 512 MiB decoded-file allocation ceiling.
    static func admittedAllocation(blocks: Int64) -> UInt64? {
        guard blocks >= 0, UInt64(blocks) <= TARCompressedDecoder.maximumBytes / 512 else { return nil }
        return UInt64(blocks) * 512
    }
    private static func allocation(_ fd: Int32) throws -> UInt64 {
        var facts = stat()
        guard fstat(fd, &facts) == 0 else { throw TARArchiveFailure.unavailable }
        guard let bytes = admittedAllocation(blocks: facts.st_blocks) else { throw TARArchiveFailure.limited }
        return bytes
    }
    private static func read(_ fd: Int32, offset: UInt64, count: Int, length: UInt64,
                             check: () throws -> Void) throws -> Data {
        try check()
        guard count >= 0, count <= 65_536, offset <= length, UInt64(count) <= length - offset,
              offset <= UInt64(Int64.max) else { throw TARArchiveFailure.malformed }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < count {
                try check()
                let amount = pread(fd, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw TARArchiveFailure.unavailable }
                done += amount
            }
        }
        return data
    }
    private static func write(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let amount = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw TARArchiveFailure.unavailable }
                done += amount
            }
        }
    }
    private struct Monitor {
        let wake: DispatchSemaphore
        let done: DispatchGroup
        func stop() { wake.signal(); done.wait() }
    }
    private static func monitor(_ output: Int32, cancellation: TARCompressedDecoder.Cancellation,
                                progress: @escaping @Sendable (UInt64, UInt64) -> Void) -> Monitor {
        let wake = DispatchSemaphore(value: 0), done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { done.leave() }
            while wake.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                guard cancellation.poll() == 0 else { continue }
                var facts = stat()
                if fstat(output, &facts) == 0, facts.st_size >= 0 {
                    let allocated = Self.admittedAllocation(blocks: facts.st_blocks)
                    if UInt64(facts.st_size) > TARCompressedDecoder.maximumBytes || allocated == nil {
                        cancellation.limitAllocation()
                    } else if let allocated { progress(UInt64(facts.st_size), allocated) }
                }
            }
        }
        return .init(wake: wake, done: done)
    }
}
