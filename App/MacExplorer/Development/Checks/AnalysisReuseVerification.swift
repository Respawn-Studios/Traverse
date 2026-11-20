#if DEBUG
import AppKit
import Darwin
import Foundation
import ExplorerCore
import LocalStorage
import ObjectiveC
import SwiftUI
@_spi(ApplicationOwnership) import StorageAnalysis

/// Descriptor-bound I/O for the one generated persistence case. It never
/// follows a replaced fixture child into another location.
private enum PersistenceFixtureIO {
    private static func refuse(_ label: String) -> AnalysisReuseFixtureAuthority.Failure { .refused(label) }

    static func privateDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw refuse("persistence-directory-open") }
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o700 else {
            close(fd); throw refuse("persistence-directory-private")
        }
        return fd
    }

    static func read(_ url: URL, maximum: Int) throws -> Data {
        guard maximum > 0, maximum <= 8192 else { throw refuse("persistence-read-bound") }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw refuse("persistence-file-open") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o022 == 0, before.st_size >= 0,
              before.st_size <= Int64(maximum) else { throw refuse("persistence-file-bound") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Int(before.st_size) {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, min($0.count, Int(before.st_size) - data.count))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw refuse("persistence-file-read") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev,
              after.st_ino == before.st_ino, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw refuse("persistence-file-changed")
        }
        return data
    }
    static func isAbsent(_ url: URL) throws -> Bool {
        let parent = try privateDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        var facts = stat()
        return fstatat(parent, url.lastPathComponent, &facts, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    fileprivate struct NativeIdentity: Equatable, Sendable {
        let device: Int32, inode: UInt64, generation: UInt32, birth: Int, birthNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; generation = value.st_gen
            birth = value.st_birthtimespec.tv_sec; birthNanos = value.st_birthtimespec.tv_nsec
        }
    }
    fileprivate struct NativeNode: Equatable, Sendable {
        let identity: NativeIdentity, mode: UInt16, uid: UInt32, links: UInt64, size: Int64, flags: UInt32
        let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
        let linkTarget: Data?
        init(_ value: stat, linkTarget: Data? = nil) {
            identity = .init(value); mode = value.st_mode; uid = value.st_uid; links = UInt64(value.st_nlink)
            size = value.st_size; flags = value.st_flags
            modified = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changed = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
            self.linkTarget = linkTarget
        }
    }
    fileprivate struct Document: Equatable, Sendable { let node: NativeNode; let bytes: Data }
    private static func document(_ url: URL) throws -> Document {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw refuse("successful-source-document-open") }
        defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0 else { throw refuse("successful-source-document-stat") }
        let bytes = try read(url, maximum: 8192)
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              NativeNode(before) == NativeNode(after), NativeNode(before) == NativeNode(named) else {
            throw refuse("successful-source-document-changed")
        }
        return .init(node: NativeNode(before), bytes: bytes)
    }
    /// An exact successful generated tree. No old catalog is opened. The root
    /// FD stays immutable/open while its serial validation users retain it.
    final class SuccessfulSource: @unchecked Sendable {
        static let caseID = "4C00D2AC-0CB4-47C0-864B-5EAC84B644F7"
        let folder: URL
        fileprivate let descriptor: Int32
        private let identity: NativeIdentity, volume: UUID, documents: [URL: Document], original: [String: NativeNode]
        private let parents: [(URL, Int32, NativeIdentity)]
        fileprivate init(folder: URL, descriptor: Int32, identity: NativeIdentity, volume: UUID,
                         documents: [URL: Document], original: [String: NativeNode], parents: [(URL, Int32, NativeIdentity)]) {
            self.folder = folder; self.descriptor = descriptor; self.identity = identity; self.volume = volume
            self.documents = documents; self.original = original; self.parents = parents
        }
        deinit { close(descriptor); for (_, fd, _) in parents { close(fd) } }
        func validateAuthority() throws {
            for (url, fd, expected) in parents {
                var facts = stat(), named = stat()
                guard fstat(fd, &facts) == 0, lstat(url.path, &named) == 0,
                      NativeIdentity(facts) == expected, NativeIdentity(named) == expected,
                      facts.st_mode & S_IFMT == S_IFDIR, facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o700 else {
                    throw PersistenceFixtureIO.refuse("successful-source-parent-identity")
                }
            }
            var facts = stat(), named = stat()
            guard fstat(descriptor, &facts) == 0, lstat(folder.path, &named) == 0,
                  NativeIdentity(facts) == identity, NativeIdentity(named) == identity,
                  facts.st_mode & S_IFMT == S_IFDIR, facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o700,
                  let text = try folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  UUID(uuidString: text) == volume else { throw PersistenceFixtureIO.refuse("successful-source-identity") }
            for (url, expected) in documents {
                guard try PersistenceFixtureIO.document(url) == expected else { throw PersistenceFixtureIO.refuse("successful-source-authority-changed") }
            }
        }
        func validateRestored() throws {
            try validateAuthority()
            guard try PersistenceFixtureIO.inventory(descriptor) == original else { throw PersistenceFixtureIO.refuse("successful-source-old-metadata-changed") }
            try validateAuthority()
        }
        func reserveLeaf(currentCase: UUID) throws -> OwnedLeaf {
            let name = "Traverse B06 " + currentCase.uuidString + ".txt"
            try validateRestored()
            let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw PersistenceFixtureIO.refuse("successful-source-leaf-create") }
            return OwnedLeaf(name: name, descriptor: fd)
        }
    }
    /// One serial owner retains the created FD and post-fsync native stamp.
    /// Failed/uncertain sealing or cleanup never retries or unlinks by name alone.
    final class OwnedLeaf: @unchecked Sendable {
        let name: String
        private let descriptor: Int32
        private var sealed: NativeNode?
        private var cleanupAttempted = false
        fileprivate init(name: String, descriptor: Int32) { self.name = name; self.descriptor = descriptor }
        deinit { close(descriptor) }
        func write(in source: SuccessfulSource) throws {
            try source.validateAuthority()
            var facts = stat()
            guard fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
                  facts.st_uid == geteuid(), facts.st_nlink == 1, facts.st_size == 0,
                  facts.st_mode & 0o7777 == 0o600 else { throw PersistenceFixtureIO.refuse("successful-source-created-leaf") }
            try PersistenceFixtureIO.writeAll(Data([66]), to: descriptor)
            var named = stat()
            guard fsync(descriptor) == 0, fsync(source.descriptor) == 0, fstat(descriptor, &facts) == 0,
                  facts.st_size == 1, fstatat(source.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  NativeNode(facts) == NativeNode(named) else { throw PersistenceFixtureIO.refuse("successful-source-leaf-sync") }
            sealed = NativeNode(facts)
        }
        func remove(in source: SuccessfulSource) throws {
            guard !cleanupAttempted else { throw PersistenceFixtureIO.refuse("successful-source-cleanup-already-attempted") }
            cleanupAttempted = true
            try source.validateAuthority()
            var facts = stat(), named = stat(), byte: UInt8 = 0
            guard let sealed, fstat(descriptor, &facts) == 0, NativeNode(facts) == sealed,
                  facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(), facts.st_nlink == 1,
                  facts.st_mode & 0o7777 == 0o600, facts.st_size == 1,
                  fstatat(source.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  NativeNode(named) == sealed, pread(descriptor, &byte, 1, 0) == 1, byte == 66 else {
                throw PersistenceFixtureIO.refuse("successful-source-cleanup-retained")
            }
            guard unlinkat(source.descriptor, name, 0) == 0, fsync(source.descriptor) == 0 else {
                throw PersistenceFixtureIO.refuse("successful-source-cleanup-incomplete")
            }
            guard fstatat(source.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw PersistenceFixtureIO.refuse("successful-source-cleanup-not-absent")
            }
            try source.validateRestored()
        }
    }
    private static func inventory(_ root: Int32) throws -> [String: NativeNode] {
        var values: [String: NativeNode] = [:]
        let directories = Set((0..<257).map { String(format: "A%03d", $0) }
            + ["Empty", "Project", "Project/Project", "Project/Project/Empty"])
        let allowed = directories.union(["One.txt", "Project/Two.swift", "Link"])
        func walk(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth <= 3 else { throw refuse("successful-source-depth") }
            let copy = fcntl(parent, F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw refuse("successful-source-directory-copy") }
            guard let stream = fdopendir(copy) else { close(copy); throw refuse("successful-source-directory-read") }
            defer { closedir(stream) }
            rewinddir(stream)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw refuse("successful-source-directory-error") }
                    break
                }
                var bytes = entry.pointee.d_name
                let name = withUnsafePointer(to: &bytes) { $0.withMemoryRebound(to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                guard values.count < 265 else { throw refuse("successful-source-inventory-bound") }
                let path = prefix + name
                guard allowed.contains(path) else { throw refuse("successful-source-unexpected-member") }
                var facts = stat()
                guard fstatat(parent, name, &facts, AT_SYMLINK_NOFOLLOW) == 0, facts.st_uid == geteuid() else {
                    throw refuse("successful-source-member")
                }
                var target: Data?
                if facts.st_mode & S_IFMT == S_IFLNK {
                    var bytes = [CChar](repeating: 0, count: 8)
                    let count = bytes.withUnsafeMutableBufferPointer { readlinkat(parent, name, $0.baseAddress, $0.count) }
                    guard path == "Link", count == 7 else { throw refuse("successful-source-link-target") }
                    let literal = Data(bytes.prefix(7).map { UInt8(bitPattern: $0) })
                    guard literal == Data("Project".utf8) else { throw refuse("successful-source-link-target") }
                    target = literal
                }
                values[path] = NativeNode(facts, linkTarget: target)
                if facts.st_mode & S_IFMT == S_IFDIR {
                    guard directories.contains(path), facts.st_mode & 0o7777 == 0o700 else {
                        throw refuse("successful-source-member-private")
                    }
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    guard child >= 0 else { throw refuse("successful-source-member-open") }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, NativeIdentity(opened) == NativeIdentity(facts) else {
                        throw refuse("successful-source-member-changed")
                    }
                    try walk(child, prefix: path + "/", depth: depth + 1)
                }
            }
        }
        try walk(root, prefix: "", depth: 0)
        return values
    }
    static func successfulSource(beside current: URL) throws -> SuccessfulSource {
        let old = current.deletingLastPathComponent().appendingPathComponent(SuccessfulSource.caseID, isDirectory: true)
        guard old != current, old.resolvingSymlinksInPath() == old else { throw refuse("successful-source-case") }
        var transferred = false
        let caseFD = try privateDirectory(old); defer { if !transferred { close(caseFD) } }
        let sourceURL = old.appendingPathComponent("source"), sourceFD = try privateDirectory(sourceURL)
        defer { if !transferred { close(sourceFD) } }
        var caseFacts = stat(), sourceFacts = stat()
        guard fstat(caseFD, &caseFacts) == 0, fstat(sourceFD, &sourceFacts) == 0 else {
            throw refuse("successful-source-parent-stat")
        }
        var documents: [URL: Document] = [:]
        let markerURL = old.appendingPathComponent("reservation.json"), marker = try document(markerURL)
        guard let object = try JSONSerialization.jsonObject(with: marker.bytes) as? [String: String],
              object["packet"] == "traverse-development-v1", object["action"] == "native-analysis-persistence" else {
            throw refuse("successful-source-authority")
        }
        documents[markerURL] = marker
        for phase in ["seed", "reopen", "repair"] {
            let url = old.appendingPathComponent("evidence/persistence-" + phase + "-result.json")
            let data = try document(url)
            guard let receipt = try JSONSerialization.jsonObject(with: data.bytes) as? [String: Any],
                  receipt["passed"] as? Bool == true, receipt["ownerIdle"] as? Bool == true,
                  receipt["phase"] as? String == phase else { throw refuse("successful-source-receipt") }
            if phase == "reopen" {
                guard (receipt["checks"] as? [String])?.contains(where: { $0.contains("Actual Forget") }) == true else {
                    throw refuse("successful-source-forget")
                }
            }
            documents[url] = data
        }
        let seedURL = old.appendingPathComponent("evidence/persistence-seed.json")
        documents[seedURL] = try document(seedURL)
        let indexURL = old.appendingPathComponent("cache/retained-analysis/index.json"), index = try document(indexURL)
        guard let decoded = try JSONSerialization.jsonObject(with: index.bytes) as? [String: Any],
              decoded["version"] as? Int == 2, (decoded["records"] as? [Any])?.isEmpty == true,
              (decoded["pendingForget"] as? [Any])?.isEmpty == true, decoded["retiring"] == nil else {
            throw refuse("successful-source-index-not-forgotten")
        }
        documents[indexURL] = index
        let folder = old.appendingPathComponent("source/Analysis", isDirectory: true), descriptor = try privateDirectory(folder)
        var facts = stat()
        do {
            guard fstat(descriptor, &facts) == 0,
                  let text = try folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  let volume = UUID(uuidString: text) else { throw refuse("successful-source-volume") }
            let original = try inventory(descriptor)
            let directories = Set((0..<257).map { String(format: "A%03d", $0) }
                + ["Empty", "Project", "Project/Project", "Project/Project/Empty"])
            guard Set(original.keys) == directories.union(["One.txt", "Project/Two.swift", "Link"]),
                  directories.allSatisfy({ (original[$0]?.mode ?? 0) & S_IFMT == S_IFDIR }),
                  original["One.txt"]?.size == 4096, original["Project/Two.swift"]?.size == 10,
                  ["One.txt", "Project/Two.swift"].allSatisfy({ (original[$0]?.mode ?? 0) & S_IFMT == S_IFREG && original[$0]?.links == 1 }),
                  (original["Link"]?.mode ?? 0) & S_IFMT == S_IFLNK else { throw refuse("successful-source-geometry") }
            let proof = SuccessfulSource(folder: folder, descriptor: descriptor, identity: NativeIdentity(facts),
                volume: volume, documents: documents, original: original,
                parents: [(old, caseFD, NativeIdentity(caseFacts)), (sourceURL, sourceFD, NativeIdentity(sourceFacts))])
            transferred = true
            try proof.validateAuthority()
            return proof
        } catch { if !transferred { close(descriptor) }; throw error }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress?.advanced(by: written), raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw refuse("persistence-file-write") }
                written += count
            }
        }
    }

    static func writeNew(_ data: Data, to url: URL, maximum: Int = 8192) throws {
        guard !data.isEmpty, data.count <= maximum, !url.lastPathComponent.isEmpty else {
            throw refuse("persistence-write-bound")
        }
        let parent = try privateDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw refuse("persistence-file-create") }
        defer { close(fd) }
        var facts = stat(), named = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_mode & 0o7777 == 0o600 else { throw refuse("persistence-created-file") }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0, fsync(parent) == 0,
              fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == facts.st_dev, named.st_ino == facts.st_ino else {
            throw refuse("persistence-file-sync")
        }
    }

    static func seed(_ folder: URL) throws {
        let source = try privateDirectory(folder.deletingLastPathComponent())
        defer { close(source) }
        guard mkdirat(source, "Analysis", 0o700) == 0,
              fsync(source) == 0 else { throw refuse("persistence-fixture-create") }
        let analysis = try privateDirectory(folder)
        defer { close(analysis) }
        guard mkdirat(analysis, "Project", 0o700) == 0,
              mkdirat(analysis, "Empty", 0o700) == 0,
              fsync(analysis) == 0 else { throw refuse("persistence-fixture-children") }
        // Put the useful descendant after a real page boundary. Empty folders
        // keep the original byte totals and the fixture small.
        for index in 0..<257 {
            let name = String(format: "A%03d", index)
            guard mkdirat(analysis, name, 0o700) == 0 else { throw refuse("persistence-page-fixture") }
        }
        let project = try privateDirectory(folder.appendingPathComponent("Project"))
        guard mkdirat(project, "Project", 0o700) == 0, fsync(project) == 0 else {
            close(project); throw refuse("persistence-nested-fixture")
        }
        close(project)
        let nested = try privateDirectory(folder.appendingPathComponent("Project/Project"))
        guard mkdirat(nested, "Empty", 0o700) == 0, fsync(nested) == 0 else {
            close(nested); throw refuse("persistence-empty-fixture")
        }
        close(nested)
        let empty = try privateDirectory(folder.appendingPathComponent("Empty"))
        close(empty)
        guard symlinkat("Project", analysis, "Link") == 0, fsync(analysis) == 0 else {
            throw refuse("persistence-link-fixture")
        }
        try writeNew(Data("Orion\n".utf8), to: folder.appendingPathComponent("One.txt"))
        try writeNew(Data("let n = 1\n".utf8), to: folder.appendingPathComponent("Project/Two.swift"))
        try writeNew(Data([1]), to: folder.appendingPathComponent("Project/Delete-me.txt"))
    }

    static func changeGeneratedProject(_ folder: URL) throws {
        let project = try privateDirectory(folder.appendingPathComponent("Project"))
        defer { close(project) }
        let fd = openat(project, "Two.swift", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw refuse("incremental-fixture-open") }
        defer { close(fd) }
        var facts = stat(), named = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1,
              facts.st_uid == geteuid(), facts.st_size == 10,
              fstatat(project, "Two.swift", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == facts.st_dev, named.st_ino == facts.st_ino,
              try read(folder.appendingPathComponent("Project/Two.swift"), maximum: 32) == Data("let n = 1\n".utf8) else {
            throw refuse("incremental-fixture-original")
        }
        try writeAll(Data(repeating: 66, count: 20), to: fd)
        guard ftruncate(fd, 20) == 0, fsync(fd) == 0,
              fstatat(project, "Delete-me.txt", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(), named.st_nlink == 1,
              named.st_size == 1,
              try read(folder.appendingPathComponent("Project/Delete-me.txt"), maximum: 8) == Data([1]),
              unlinkat(project, "Delete-me.txt", 0) == 0 else { throw refuse("incremental-fixture-remove") }
        try writeNew(Data([2]), to: folder.appendingPathComponent("Project/Added-🧭.txt"))
        let nested = try privateDirectory(folder.appendingPathComponent("Project/Project"))
        defer { close(nested) }
        guard fstatat(nested, "Empty", &facts, AT_SYMLINK_NOFOLLOW) == 0,
              facts.st_mode & S_IFMT == S_IFDIR, facts.st_uid == geteuid(),
              fstatat(nested, "Renamed-🧭", &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              renameat(nested, "Empty", nested, "Renamed-🧭") == 0,
              fsync(nested) == 0, fsync(project) == 0 else { throw refuse("incremental-fixture-rename") }
    }

    static func changeGeneratedChild(_ folder: URL) throws {
        let parent = try privateDirectory(folder)
        defer { close(parent) }
        let fd = openat(parent, "One.txt", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw refuse("persistence-child-open") }
        defer { close(fd) }
        var facts = stat(), named = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_mode & 0o022 == 0, facts.st_size == 6,
              fstatat(parent, "One.txt", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == facts.st_dev, named.st_ino == facts.st_ino else {
            throw refuse("persistence-child-identity")
        }
        var original = [UInt8](repeating: 0, count: 6)
        guard original.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) == 6,
              original == Array("Orion\n".utf8),
              fstatat(parent, "One.txt", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == facts.st_dev, named.st_ino == facts.st_ino,
              ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            throw refuse("persistence-child-changed")
        }
        try writeAll(Data(repeating: 65, count: 4096), to: fd)
        guard fsync(fd) == 0, fsync(parent) == 0,
              fstatat(parent, "One.txt", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == facts.st_dev, named.st_ino == facts.st_ino else {
            throw refuse("persistence-child-sync")
        }
    }
}

/// The existing persistence packet supplies the one real saved row. The other
/// inventories below are display projections only and never enter an owner.
@MainActor private enum RecentAnalysisVisualQA {
    private struct EmptyTopology: DriveTopologyReading {
        func readTopology() async throws -> DriveTopologySnapshot { try .init(nodes: []) }
    }
    private final class Callbacks {
        var opened: [UUID] = []
        var refreshes = 0
    }
    private struct Projection: View {
        let inventory: RecentAnalysisInventory
        let actions: Callbacks
        var body: some View {
            RecentAnalysesSection(inventory: inventory, enabled: true,
                onRefresh: { actions.refreshes += 1 },
                onOpen: { actions.opened.append($0) })
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    private static func accessibilityValue(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard String(cString: encoding).hasPrefix("@") else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private static func accessibleButtons(in window: NSWindow) -> [(NSObject, String)] {
        var visited = Set<ObjectIdentifier>(), count = 0
        func walk(_ raw: Any, depth: Int) -> [(NSObject, String)] {
            guard depth <= 24, count < 2_048, let object = raw as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            count += 1
            var children = (accessibilityValue(object, "accessibilityChildren") as? [Any] ?? [])
                + (accessibilityValue(object, "accessibilityContents") as? [Any] ?? [])
            if let view = object as? NSView { children += view.subviews }
            let label = accessibilityValue(object, "accessibilityLabel") as? String ?? ""
            let own = accessibilityValue(object, "accessibilityRole") as? String
                == NSAccessibility.Role.button.rawValue ? [(object, label)] : []
            return own + children.flatMap { walk($0, depth: depth + 1) }
        }
        return window.contentView.map { walk($0, depth: 0) } ?? []
    }
    private static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return false }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard ["B", "c"].contains(String(cString: encoding)) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector).boolValue
    }

    static func capture(root: URL, real row: RecentAnalysis, settings: BrowserSettings) async throws -> [String] {
        try UIVerification.require(row.root.path.hasPrefix(root.path + "/source/"),
            "recent-visual-row-outside-generated-source")
        let priorSize = settings.interfaceSize
        let selectedAppearance = settings.appearance
        let priorAppearance = NSApp.appearance
        let priorKeeping = settings.analysisKeepsResults
        defer {
            settings.interfaceSize = priorSize
            settings.appearance = selectedAppearance
            NSApp.appearance = priorAppearance
            settings.analysisKeepsResults = priorKeeping
        }
        settings.driveHealthLiveUpdates = false
        settings.motion.mode = .off
        settings.interfaceSize = .standard
        // The offscreen full-page capture showed dark text on a dark background
        // while native views reported DarkAqua. Capture full-page layout in
        // Light; the leaf also exercises dark presentation.
        settings.appearance = .light
        BrowserAppearanceController.apply(.light)

        // This is the actual Drives composition and passive owner inventory,
        // with an empty generated topology so no native drive is sampled.
        let model = ApplicationDriveManagement(reader: EmptyTopology())
        var appearanceFacts = ""
        model.show(settings: settings, offscreen: true, initialPage: .analysis)
        do {
            await model.drain()
            guard case .ready(let rows) = model.recentAnalyses, rows.count == 1,
                  rows[0].id == row.id, model.health.target == nil,
                  let window = model.window else {
                throw UIVerification.Failure(message: "recent-visual-real-drive-inventory")
            }
            let scanStarts = ApplicationStorageAnalysis.shared.allScanStartsForSessionReuseVerification
            settings.analysisKeepsResults = false
            await model.drain()
            guard case .disabled = model.recentAnalyses else {
                throw UIVerification.Failure(message: "recent-drive-setting-off-must-hide-rows")
            }
            settings.analysisKeepsResults = true
            await model.drain()
            guard case .ready(let restored) = model.recentAnalyses,
                  restored.count == 1, restored[0].id == row.id else {
                throw UIVerification.Failure(message: "recent-drive-setting-on-must-restore-row")
            }
            settings.analysisKeepsResults = false
            settings.analysisKeepsResults = true
            settings.analysisKeepsResults = false
            await model.drain()
            guard case .disabled = model.recentAnalyses else {
                throw UIVerification.Failure(message: "recent-drive-latest-off-must-win")
            }
            settings.analysisKeepsResults = true
            settings.analysisKeepsResults = false
            settings.analysisKeepsResults = true
            await model.drain()
            guard case .ready(let latest) = model.recentAnalyses,
                  latest.count == 1, latest[0].id == row.id else {
                throw UIVerification.Failure(message: "recent-drive-latest-on-must-win")
            }
            try UIVerification.require(scanStarts == ApplicationStorageAnalysis.shared.allScanStartsForSessionReuseVerification,
                "recent-drive-preference-refresh-must-not-start-scanner")
            try await UIVerification.snapshot(window,
                to: root.appendingPathComponent("evidence/recent-drives-one-100.png"))
            let chrome = window.contentViewController as? ToolWindowChrome
            let name: (NSAppearance?) -> String = { $0?.name.rawValue ?? "nil" }
            var hosted: [String] = []
            func walk(_ view: NSView) {
                if String(describing: type(of: view)).contains("Hosting") && hosted.count < 12 {
                    hosted.append("\(type(of: view))=\(name(view.effectiveAppearance))")
                }
                for child in view.subviews { walk(child) }
            }
            if let content = window.contentView { walk(content) }
            appearanceFacts = "app=\(name(NSApp.effectiveAppearance)) override=\(name(NSApp.appearance)) "
                + "window=\(name(window.effectiveAppearance)) override=\(name(window.appearance)) "
                + "content=\(name(window.contentView?.effectiveAppearance)) "
                + "chromeHost=\(name(chrome?.contentHost.effectiveAppearance)) hosts=\(hosted.joined(separator: ","))"
            settings.interfaceSize = .init(150)
            try await UIVerification.snapshot(window,
                to: root.appendingPathComponent("evidence/recent-drives-one-150.png"))
        } catch {
            await model.closeAndDrain()
            throw error
        }
        await model.closeAndDrain()
        settings.appearance = selectedAppearance
        BrowserAppearanceController.apply(selectedAppearance)

        // Render the same production leaf with generated, typed states. This
        // tests copy/layout without granting any callback mutation authority.
        let secondRoot = root.appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(String(repeating: "Generated long folder ", count: 8)
                .trimmingCharacters(in: .whitespaces), isDirectory: true)
            .appendingPathComponent("Analysis", isDirectory: true)
        let second = RecentAnalysis(id: UUID(), root: secondRoot,
            observedThrough: row.observedThrough.addingTimeInterval(-3600),
            result: .partial, policy: .applicationData)
        let actions = Callbacks()
        let host = NSHostingView(rootView: InterfaceRoot(content: Projection(inventory: .loading, actions: actions)))
        let window = NSWindow(contentRect: .init(x: -12_000, y: -12_000, width: 720, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Generated Recent Analyses states"
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let states: [(String, RecentAnalysisInventory, InterfaceSize)] = [
            ("zero-100", .ready([]), .standard),
            ("one-100", .ready([row]), .standard),
            ("two-100", .ready([row, second]), .standard),
            ("two-150", .ready([row, second]), .init(150)),
            ("loading-100", .loading, .standard),
            ("disabled-100", .disabled, .standard),
            ("busy-100", .busy, .standard),
            ("unavailable-100", .unavailable, .standard),
            ("attention-100", .needsAttention, .standard),
        ]
        for (name, inventory, size) in states {
            settings.interfaceSize = size
            host.rootView = InterfaceRoot(content: Projection(inventory: inventory, actions: actions))
            try await UIVerification.snapshot(window,
                to: root.appendingPathComponent("evidence/recent-leaf-" + name + ".png"))
        }
        try UIVerification.require(actions.opened.isEmpty && actions.refreshes == 0,
            "recent-visual-render-invoked-action")
        host.rootView = InterfaceRoot(content: Projection(inventory: .ready([row, second]), actions: actions))
        try await UIVerification.waitUntil("recent-accessible-rows") {
            let labels = accessibleButtons(in: window).map(\.1)
            return labels.contains { $0.hasPrefix("Open saved analysis for \(row.root.path), Complete, Standard,") }
                && labels.contains { $0.hasPrefix("Open saved analysis for \(second.root.path), Partial, Application Data,") }
        }
        let buttons = accessibleButtons(in: window)
        guard let first = buttons.first(where: { $0.1.hasPrefix("Open saved analysis for \(row.root.path), Complete, Standard,") })?.0,
              let other = buttons.first(where: { $0.1.hasPrefix("Open saved analysis for \(second.root.path), Partial, Application Data,") })?.0 else {
            throw UIVerification.Failure(message: "recent-accessible-row-identity")
        }
        try UIVerification.require(press(first) && press(other), "recent-accessible-row-press")
        try UIVerification.require(actions.opened == [row.id, second.id] && actions.refreshes == 0,
            "recent-accessible-row-exact-id")
        return ["Actual Drives Analysis shows the one recorded row at 100% and 150% without device sampling",
            "The production Recent Analyses leaf renders zero, one, two, loading, disabled, busy, unavailable and needs-attention states from generated display inputs; screenshots require human visual review",
            "Two same-named rows expose distinct full paths, scope and state to the owned accessibility tree; accessible press dispatches their exact IDs without refresh",
            "Generated Drives appearance: \(appearanceFacts)"]
    }
}

/// Root integrates one early AppDelegate branch. This runner owns its task,
/// optional visible presentation, explicit shutdown and final real-owner drain.
@MainActor enum AnalysisReuseVerification {
    /// Every field of StoredAnalysisValue, for comparing the original baseline
    /// after a real process restart without adding a package serialization API.
    private static func signature(_ value: StoredAnalysisValue) -> [String: String] {
        var result: [String: String] = [:]
        for (index, count) in [value.counts.regularFiles, value.counts.directories, value.counts.symbolicLinks,
            value.counts.other, value.counts.unknown].enumerated() { result["c" + String(index)] = String(count) }
        for metric in AnalysisByteMetric.allCases {
            let subtotal = value.bytes[metric], prefix = "b" + String(metric.rawValue)
            result[prefix + "k"] = subtotal.knownBytes.map(String.init) ?? "unknown"
            result[prefix + "n"] = String(subtotal.notReturnedCount)
            result[prefix + "f"] = String(subtotal.failedCount)
            result[prefix + "o"] = subtotal.overflowed ? "1" : "0"
        }
        return result
    }
    private static var refreshHeaderFrames: [[String: Double]] = []
    private static func sampleRefreshHeader(_ tool: StorageAnalysisWindowController) {
        guard let native = tool.window, let content = native.contentView else { return }
        var sample = ["stateHeight": Double(tool.statusLabel.superview?.bounds.height ?? 0),
            "scopeTop": Double(content.bounds.maxY - tool.scopeLabel.convert(tool.scopeLabel.bounds, to: content).maxY),
            "summaryTop": Double(content.bounds.maxY - tool.summaryLabel.convert(tool.summaryLabel.bounds, to: content).maxY),
            "windowHeight": Double(native.frame.height)]
        if let column = tool.scopeLabel.superview as? NSStackView {
            for (index, row) in column.arrangedSubviews.enumerated() {
                sample["row\(index)Height"] = Double(row.bounds.height)
                sample["row\(index)Hidden"] = row.isHidden ? 1 : 0
            }
        }
        guard refreshHeaderFrames.count < 16, refreshHeaderFrames.last != sample else { return }
        refreshHeaderFrames.append(sample)
    }
    private final class DrainTail {
        var entered = false
        var released = false
    }
    private static var task: Task<Void, Never>?
    private static var shutdown: Task<Void, Never>?
    private static var shutdownRequested = false
    static var isRunning: Bool { task != nil }
    static func launch() {
        guard task == nil else { return }
        task = Task { @MainActor in await runProcess() }
    }
    static func requestShutdown() {
        shutdownRequested = true; task?.cancel()
        if shutdown == nil {
            shutdown = Task { @MainActor in await ApplicationStorageAnalysis.shared.stopAndDrain(shuttingDown: true) }
        }
    }
    private struct Drain: Sendable { let ownerIdle: Bool, activity: Int, windowsHidden: Bool }
    private static func drain(host: AnalysisReuseNativeBrowser?) async -> Drain {
        // An owned unstructured task does not inherit the cancelled test task's
        // cancellation. It still awaits actual cleanup rather than timeout credit.
        let final = Task { @MainActor in
            await shutdown?.value
            let owner = ApplicationStorageAnalysis.shared
            owner.pagedProjectionAdmissionForSessionReuseVerification = nil
            owner.cacheInsertionAdmissionForSessionReuseVerification = nil
            owner.chooseFolderForVerification = nil
            await owner.stopAndDrain(shuttingDown: true)
            await host?.drain()
            // The early isolated dispatch created every window in this process.
            // Close those owners before the final idempotent drain.
            for window in NSApp.windows { window.close() }
            await owner.stopAndDrain(shuttingDown: true)
            await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ApplicationFileActivity.gate.activeCount != 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return Drain(ownerIdle: !owner.hasWork && owner.activeSession == nil && owner.activePagedSession == nil,
                activity: ApplicationFileActivity.gate.activeCount, windowsHidden: !NSApp.windows.contains(where: \.isVisible))
        }
        return await final.value
    }
    private static func runProcess() async {
        let began = ProcessInfo.processInfo.systemUptime
        var authority: AnalysisReuseFixtureAuthority?, host: AnalysisReuseNativeBrowser?
        var presentation: Task<Void, Never>?, checks: [String] = [], failure: String?
        let args = ProcessInfo.processInfo.arguments, env = ProcessInfo.processInfo.environment
        let visible = args.contains("--analysis-reuse-visible")
        do {
            let state = AppStorageLocations.layout?.stateDirectory, cache = AppStorageLocations.layout?.cacheDirectory
            let variant = Bundle.main.object(forInfoDictionaryKey: "TraverseAnalysisReuseVariant") as? String
            let loaded = try await Task.detached(priority: .utility) {
                try AnalysisReuseFixtureAuthority.load(arguments: args, environment: env, bundleVariant: variant, state: state, cache: cache)
            }.value
            authority = loaded
            guard !shutdownRequested else { throw CancellationError() }
            if visible {
                presentation = Task { @MainActor in
                    let deadline = ProcessInfo.processInfo.systemUptime + 12
                    while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        if let owner = ApplicationStorageAnalysis.shared.toolWindow, !owner.isClosed {
                            owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
            }
            var nativeEntry: ExplorerCore.FileEntry?
            if loaded.selected.needsBrowser {
                let value = AnalysisReuseNativeBrowser(); host = value
                nativeEntry = try await value.load(loaded)
            }
            try UIVerification.requireControlledWindowsHidden("reuse-before-case")
            checks = try await perform(loaded, host: host, entry: nativeEntry)
            try UIVerification.requireControlledWindowsHidden("reuse-after-case")
        } catch { failure = semanticCode(error) }
        presentation?.cancel(); await presentation?.value
        let final = await drain(host: host)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var disk: AnalysisReuseFixtureAuthority.Budget?
        if let authority {
            disk = try? await Task.detached(priority: .utility) { try AnalysisReuseFixtureAuthority.auditRoot(authority.root) }.value
        }
        let expected = authority?.selected.expectedSemantic
        let semanticNegative = expected != nil && failure == expected
        let clean = final.ownerIdle && final.activity == 0 && (visible || final.windowsHidden) && disk != nil
            && ReuseHeldRelease.timeoutCountForRunner == 0
        let positive = failure == nil && expected == nil && !shutdownRequested && clean
        let acceptedNegative = semanticNegative && !shutdownRequested && clean
        let outcome = positive ? "positive-pass" : acceptedNegative ? "semantic-negative-observed" : "failure"
        let report: [String: Any] = ["schema": 1, "case": authority?.selected.rawValue ?? "refused",
            "variant": authority?.selected.variant ?? "refused", "outcome": outcome,
            "positivePassed": positive, "semanticNegativeObserved": acceptedNegative,
            "failureCode": failure ?? "none", "checks": checks, "ownerIdle": final.ownerIdle,
            "activityCount": final.activity, "scheduledDiscardJoinReturned": true,
            "queryHookTimeoutCount": ReuseHeldRelease.timeoutCountForRunner,
            "diskAuditPassed": disk != nil, "caseEntries": disk?.entries ?? -1,
            "caseLogicalBytes": disk?.logicalBytes ?? -1, "caseAllocatedBytes": disk?.allocatedBytes ?? -1,
            "visibleMode": visible, "offscreenWindowsHidden": final.windowsHidden,
            "shutdownRequested": shutdownRequested, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "peakRSSBytes": usage.ru_maxrss, "physicalInputQualified": false, "visualAcceptanceClaimed": false,
            "signedAccessQualified": false, "analysisBodyIndexing": false]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard data.count <= 16_384 else { Darwin.exit(72) }
            print("MAC_EXPLORER_ANALYSIS_REUSE " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        } catch { Darwin.exit(72) }
        task = nil
        // A semantic RED deliberately has a distinct nonzero status. The CLI
        // accepts20 only with exact case/variant/semantic failure and clean drain.
        Darwin.exit(positive ? 0 : acceptedNegative ? 20 : 1)
    }
    private static func semanticCode(_ error: Error) -> String {
        func safe(_ text: String) -> String? {
            let normalized = text.lowercased()
            return normalized.count <= 160 && !normalized.isEmpty && normalized.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            } ? normalized : nil
        }
        if let value = error as? UIVerification.Failure { return safe(value.message) ?? "control-failure" }
        // These labels originate only in the reviewed generated controls.
        // Never describe an arbitrary Error to recover an assertion label.
        if let value = error as? SessionAnalysisReuseControls.Failure, case .check(let label) = value {
            return safe(label) ?? "control-failure"
        }
        if let value = error as? AnalysisReuseFixtureAuthority.Failure, case .refused(let label) = value {
            return safe(label) ?? "control-failure"
        }
        if error is CancellationError { return "cancelled" }
        if let value = error as? NativeMotionRecorder.Failure { return "motion-" + value.rawValue }
        let value = DiagnosticErrors.project(error)
        return "caught-" + value.domain.rawValue + "-" + String(value.code)
    }

    /// One ordinary-app flow across two real process lifetimes. This extends
    /// the existing generated check; no alternate scanner or UI graph is used.
    static func runPersistence() async {
        let owner = ApplicationStorageAnalysis.shared
        var scope: URL?, properties: FilePropertiesWindowController?
        var checks: [String] = [], failure: String?, stage = "scope"
        var openIssue = "none", propertyStatus = "none"
        var clips: [[String: Any]] = []
        var refreshEvidence: [String: Any] = [:]
        var successfulSource: PersistenceFixtureIO.SuccessfulSource?
        var ownedLeaf: PersistenceFixtureIO.OwnedLeaf?
        let arguments = ProcessInfo.processInfo.arguments
        let offscreen = arguments.contains("--offscreen")
        func hideFunctionalWindows() throws {
            guard offscreen else { return }
            for window in NSApp.windows { window.orderOut(nil) }
            try UIVerification.requireControlledWindowsHidden("saved-analysis functional flow")
        }
        let phase = arguments.last ?? ""
        do {
            guard ["seed", "reopen", "repair", "events", "unchanged", "unchanged-reopen"].contains(phase),
                  !offscreen || !arguments.contains("--record-analysis-persistence"),
                  Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                throw UIVerification.Failure(message: "persistence-scope")
            }
            let root = URL(fileURLWithPath: raw)
            var repo = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { repo.deleteLastPathComponent() }
            let accepted = try await Task.detached {
                guard root.resolvingSymlinksInPath() == root,
                      root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                      UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { return false }
                let rootFD = try PersistenceFixtureIO.privateDirectory(root)
                close(rootFD)
                let marker = try PersistenceFixtureIO.read(root.appendingPathComponent("reservation.json"), maximum: 4096)
                guard let value = try JSONSerialization.jsonObject(with: marker) as? [String: Any] else { return false }
                return value["packet"] as? String == "traverse-development-v1"
                    && value["action"] as? String == "native-analysis-persistence"
            }.value
            try UIVerification.require(accepted, "persistence-private-fixture")
            scope = root
            let folder: URL
            if phase == "unchanged" || phase == "unchanged-reopen" {
                let admitted = try await Task.detached { try PersistenceFixtureIO.successfulSource(beside: root) }.value
                successfulSource = admitted; folder = admitted.folder
                refreshEvidence["sourceCase"] = PersistenceFixtureIO.SuccessfulSource.caseID
            } else { folder = root.appendingPathComponent("source/Analysis") }
            let seed = root.appendingPathComponent("evidence/persistence-seed.json")
            let settings = BrowserSettings(persist: false)
            settings.analysisKeepsResults = true
            settings.folderSummariesEnabled = false
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            if offscreen { settings.motion.mode = .off }
            InterfacePresentation.shared.bind(settings); StorageChartIntegration.configure(settings: settings)
            owner.configureScopePreferences(settings)
            owner.requiresAnalysisSelectionForVerification = false
            // Indexed retained catalogs reserve the supported 2 GiB session
            // maximum in the shared pool, even when this fixture scans less.
            let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("cache/analysis"),
                sessionByteLimit: 8 << 20, poolByteLimit: AnalysisResultStorage.maximumPoolBytes)
            owner.enablePagedForQualification(storage: storage)
            owner.enableRecordedAnalysesForQualification()
            stage = "fixture"
            if phase == "seed" {
                try await Task.detached { try PersistenceFixtureIO.seed(folder) }.value
            } else if phase == "reopen" {
                // A changed child proves that reopening displays the old dated
                // observation, without quietly refreshing source metadata.
                try await Task.detached { try PersistenceFixtureIO.changeGeneratedChild(folder) }.value
            }
            let index = root.appendingPathComponent("cache/retained-analysis/index.json")
            let interruptedStage = root.appendingPathComponent("cache/retained-analysis/index.stage")
            var canonicalBefore: Data?
            if phase == "repair" {
                canonicalBefore = try await Task.detached {
                    let value = try PersistenceFixtureIO.read(index, maximum: 8192)
                    try PersistenceFixtureIO.writeNew(Data("partial generated stage".utf8), to: interruptedStage)
                    return value
                }.value
            }
            if phase == "events" {
                stage = "refresh-events"
                let before = try await Task.detached { try PersistenceFixtureIO.read(index, maximum: 8192) }.value
                let values = try await owner.refreshEventsForVerification(root: folder, access: FolderAccessController(stateDirectory: nil))
                refreshEvidence = values.mapValues { $0 as Any }
                let after = try await Task.detached { try PersistenceFixtureIO.read(index, maximum: 8192) }.value
                try UIVerification.require(before == after && owner.allScanStartsForSessionReuseVerification == 0,
                    "event-diagnosis-preserves-index-without-source-scan")
                checks += ["Existing recorded root replays the same bounded event collector with aggregate IDs/flags only; no helper, traversal or source mutation"]
            } else {
                let controller = FilePropertiesWindowController(settings: settings, copyPaths: { _ in })
                properties = controller
                controller.show(urls: [folder])
                try hideFunctionalWindows()
                let model = controller.model
                stage = "properties-read"
                try await UIVerification.waitUntil(stage) { !model.isLoading && !owner.hasWork }
                try UIVerification.require(model.canAnalyzeStorage, "properties-real-directory")
                if phase == "unchanged" {
                    stage = "successful-source-full-baseline"
                    model.analyzeStorage()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && model.analysisValue?.isRunning == false }
                    model.openFullAnalysis()
                    try hideFunctionalWindows()
                    guard let window = owner.toolWindow else { throw UIVerification.Failure(message: "successful-source-window") }
                    try await UIVerification.waitUntil(stage) { window.pagedReadyForVerification }
                    guard let baseline = owner.pagedSummaryForVerification, baseline.complete,
                          let baselineMetadata = owner.recordedMetadataForVerification,
                          let baselineCheckpoint = baselineMetadata.refreshCheckpoint,
                          let baselineBytes = baseline.value.bytes.dataLogical.knownBytes,
                          let successfulSource else { throw UIVerification.Failure(message: "successful-source-baseline") }
                    try UIVerification.require(baselineCheckpoint.enumeratedDirectories > 0
                        && window.scopeLabel.stringValue == successfulSource.folder.path, "successful-source-full-scope")
                    stage = "successful-source-unchanged-update"
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    guard let unchanged = owner.pagedSummaryForVerification, unchanged.complete,
                          let unchangedMetadata = owner.recordedMetadataForVerification,
                          let unchangedCheckpoint = unchangedMetadata.refreshCheckpoint else {
                        throw UIVerification.Failure(message: "successful-source-unchanged-result")
                    }
                    try UIVerification.require(unchanged.value == baseline.value, "successful-source-unchanged-value")
                    if unchangedCheckpoint.isIncremental {
                        try UIVerification.require((unchangedCheckpoint.reusedDirectories ?? 0) >= 1
                            && unchangedCheckpoint.enumeratedDirectories < baselineCheckpoint.enumeratedDirectories,
                            "successful-source-unchanged-reuses-real-directories")
                    } else {
                        try UIVerification.require(unchangedCheckpoint.fallbackReason != nil
                            && unchangedCheckpoint.reusedEntries == 0 && (unchangedCheckpoint.reusedDirectories ?? 0) == 0,
                            "successful-source-unchanged-fallback-is-honest")
                    }
                    refreshEvidence["unchangedIncremental"] = unchangedCheckpoint.isIncremental
                    refreshEvidence["unchangedFallback"] = unchangedCheckpoint.fallbackReason ?? "none"
                    refreshEvidence["unchangedReusedDirectories"] = unchangedCheckpoint.reusedDirectories ?? 0
                    refreshEvidence["unchangedReusedEntries"] = unchangedCheckpoint.reusedEntries
                    refreshEvidence["unchangedEnumeratedDirectories"] = unchangedCheckpoint.enumeratedDirectories
                    refreshEvidence["baselineEnumeratedDirectories"] = baselineCheckpoint.enumeratedDirectories
                    refreshEvidence["baselineValue"] = signature(baseline.value)
                    stage = "successful-source-owned-leaf"
                    guard let caseID = UUID(uuidString: root.lastPathComponent) else {
                        throw UIVerification.Failure(message: "successful-source-current-case")
                    }
                    let leaf = try await Task.detached { try successfulSource.reserveLeaf(currentCase: caseID) }.value
                    ownedLeaf = leaf; refreshEvidence["ownedLeaf"] = leaf.name
                    try await Task.detached { try leaf.write(in: successfulSource) }.value
                    stage = "successful-source-dirty-update"
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    guard let mixed = owner.pagedSummaryForVerification, mixed.complete,
                          let metadata = owner.recordedMetadataForVerification,
                          let checkpoint = metadata.refreshCheckpoint else { throw UIVerification.Failure(message: "successful-source-mixed-result") }
                    refreshEvidence["mixedIncremental"] = checkpoint.isIncremental
                    refreshEvidence["mixedFallback"] = checkpoint.fallbackReason ?? "none"
                    refreshEvidence["mixedReusedDirectories"] = checkpoint.reusedDirectories ?? 0
                    refreshEvidence["mixedReusedEntries"] = checkpoint.reusedEntries
                    refreshEvidence["mixedEnumeratedDirectories"] = checkpoint.enumeratedDirectories
                    try UIVerification.require(checkpoint.isIncremental && (checkpoint.reusedDirectories ?? 0) >= 1
                        && checkpoint.reusedEntries > 0 && checkpoint.enumeratedDirectories < baselineCheckpoint.enumeratedDirectories
                        && mixed.value.bytes.dataLogical.knownBytes == baselineBytes + 1
                        && mixed.value.counts.total == baseline.value.counts.total + 1
                        && mixed.value.counts.regularFiles == baseline.value.counts.regularFiles + 1
                        && metadata.catalogID != unchangedMetadata.catalogID
                        && checkpoint.originalObservedThrough == unchangedCheckpoint.originalObservedThrough
                        && window.statusLabel.stringValue.contains("reused"), "successful-source-mixed-reuse-and-owned-delta")
                    stage = "successful-source-full-reference"
                    window.scanEveryFolderButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.pagedSummaryForVerification?.value == mixed.value
                        && owner.recordedMetadataForVerification?.refreshCheckpoint?.isIncremental == false,
                        "successful-source-complete-value-equals-full-reference")
                    guard let referenceMetadata = owner.recordedMetadataForVerification else {
                        throw UIVerification.Failure(message: "successful-source-reference-record")
                    }
                    refreshEvidence["mixedValue"] = signature(mixed.value)
                    refreshEvidence["retainedCatalog"] = referenceMetadata.catalogID.uuidString
                    refreshEvidence["retainedObserved"] = referenceMetadata.observedThrough.timeIntervalSince1970
                    checks += ["Older exact successful generated tree uses fresh current-helper state; unchanged Update preserves the complete value",
                        "One owned UUID leaf adds one byte/entry; actual mixed Update borrows directories/rows and matches a complete independent full reference"]
                } else if phase == "unchanged-reopen" {
                    stage = "successful-source-cold-reopen"
                    let priorData = try await Task.detached {
                        try PersistenceFixtureIO.read(root.appendingPathComponent("evidence/persistence-unchanged-result.json"), maximum: 8192)
                    }.value
                    let prior = try JSONSerialization.jsonObject(with: priorData) as? [String: Any]
                    guard let prior, prior["passed"] as? Bool == true, prior["ownerIdle"] as? Bool == true,
                          prior["phase"] as? String == "unchanged",
                          let previous = prior["refresh"] as? [String: Any],
                          previous["sourceCase"] as? String == PersistenceFixtureIO.SuccessfulSource.caseID,
                          previous["ownedLeafCleanup"] as? String == "removed-exact-inode-after-drain",
                          let baselineValue = previous["baselineValue"] as? [String: String],
                          let mixedValue = previous["mixedValue"] as? [String: String],
                          let priorCatalog = previous["retainedCatalog"] as? String,
                          let priorObserved = previous["retainedObserved"] as? NSNumber,
                          let baselineDirectories = previous["baselineEnumeratedDirectories"] as? NSNumber,
                          let passive = model.analysisValue else { throw UIVerification.Failure(message: "successful-source-prior-receipt") }
                    try UIVerification.require(passive.observationIsPrevious && model.chartDrill.canBrowse
                        && owner.allScanStartsForSessionReuseVerification == 0,
                        "successful-source-cold-dated-chart-without-scan")
                    model.openFullAnalysis()
                    try hideFunctionalWindows()
                    guard let window = owner.toolWindow else { throw UIVerification.Failure(message: "successful-source-cold-window") }
                    try await UIVerification.waitUntil(stage) { window.pagedReadyForVerification }
                    guard let saved = owner.pagedSummaryForVerification, saved.complete,
                          let savedBytes = saved.value.bytes.dataLogical.knownBytes,
                          let metadata = owner.recordedMetadataForVerification else { throw UIVerification.Failure(message: "successful-source-cold-record") }
                    try UIVerification.require(signature(saved.value) == mixedValue
                        && metadata.catalogID.uuidString == priorCatalog
                        && abs(metadata.observedThrough.timeIntervalSince1970 - priorObserved.doubleValue) < 0.000001
                        && owner.allScanStartsForSessionReuseVerification == 0,
                        "successful-source-exact-current-case-record-restored-without-scan")
                    stage = "successful-source-cold-removal-update"
                    model.analyzeStorage()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && model.analysisValue?.isRunning == false }
                    model.openFullAnalysis()
                    try hideFunctionalWindows()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    guard let removed = owner.pagedSummaryForVerification, removed.complete,
                          let checkpoint = owner.recordedMetadataForVerification?.refreshCheckpoint else {
                        throw UIVerification.Failure(message: "successful-source-cold-refresh")
                    }
                    refreshEvidence["coldIncremental"] = checkpoint.isIncremental
                    refreshEvidence["coldFallback"] = checkpoint.fallbackReason ?? "none"
                    refreshEvidence["coldReusedDirectories"] = checkpoint.reusedDirectories ?? 0
                    refreshEvidence["coldReusedEntries"] = checkpoint.reusedEntries
                    refreshEvidence["coldEnumeratedDirectories"] = checkpoint.enumeratedDirectories
                    try UIVerification.require(checkpoint.isIncremental && (checkpoint.reusedDirectories ?? 0) >= 1
                        && checkpoint.reusedEntries > 0 && checkpoint.enumeratedDirectories < baselineDirectories.uint64Value
                        && signature(removed.value) == baselineValue && savedBytes > 0
                        && removed.value.bytes.dataLogical.knownBytes == savedBytes - 1
                        && removed.value.counts.total + 1 == saved.value.counts.total,
                        "successful-source-cold-removal-reuses-and-restores-complete-baseline")
                    stage = "successful-source-cold-full-reference"
                    settings.analysisRefreshesChangedFolders = false
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.pagedSummaryForVerification?.value == removed.value
                        && owner.recordedMetadataForVerification?.refreshCheckpoint?.isIncremental == false,
                        "successful-source-cold-removal-equals-independent-full-reference")
                    checks += ["Fresh process restores the exact dated current-case record and chart with zero source scans",
                        "Cold incremental Update observes only the owned leaf removal, borrows real unchanged directories and equals original baseline/full reference; no further source mutation"]
                } else if phase == "seed" {
                    try UIVerification.require(owner.allScanStartsForSessionReuseVerification == 0, "properties-does-not-scan")
                    stage = "explicit-scan"
                    model.analyzeStorage()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && model.analysisValue?.isRunning == false }
                    guard let value = model.analysisValue, value.isComplete, let bytes = value.bytes,
                          let counts = value.counts else { throw UIVerification.Failure(message: "complete-scan") }
                    try UIVerification.require(model.attribution != nil && model.chartDrill.canBrowse,
                        "actual-properties-chart")
                    try UIVerification.require(owner.pagedScanStartsForSessionReuseVerification == 1, "one-explicit-scan")
                    let receipt: [String: Any] = ["logicalBytes": bytes.dataLogical.knownBytes ?? 0, "files": counts.regularFiles,
                        "observed": owner.recordedMetadataForVerification?.observedThrough.timeIntervalSince1970 ?? 0,
                        "elapsed": owner.recordedMetadataForVerification?.scanElapsed ?? -1]
                    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                    try await Task.detached { try PersistenceFixtureIO.writeNew(data, to: seed) }.value
                    checks += ["Properties opens without a scan", "Explicit Analyze shows real chart and retains one metadata result"]
                    stage = "recent-analysis-exact-row"
                    await owner.stopAndDrain()
                    let inventory = await owner.recentSavedAnalyses(keepingResults: true)
                    let inventoryLabel: String = switch inventory {
                    case .ready: "ready"
                    case .loading: "loading"
                    case .disabled: "disabled"
                    case .busy: "busy"
                    case .unavailable: "unavailable"
                    case .needsAttention: "needs-attention"
                    }
                    guard case .ready(let recent) = inventory else {
                        let state = await owner.recentOwnerStateForVerification()
                        throw UIVerification.Failure(message: "recent-inventory-\(inventoryLabel)-\(state)")
                    }
                    try UIVerification.require(recent.count == 1, "recent-inventory-count-\(recent.count)")
                    guard let row = recent.first else { throw UIVerification.Failure(message: "recent-row-absent") }
                    try UIVerification.require(row.root.standardizedFileURL.path.utf8
                        .elementsEqual(folder.standardizedFileURL.path.utf8),
                        "recent-row-root-mismatch")
                    try UIVerification.require(row.result == .complete, "recent-row-not-complete")
                    stage = "recent-analysis-visual"
                    checks += try await RecentAnalysisVisualQA.capture(root: root, real: row, settings: settings)
                    stage = "recent-analysis-exact-row"
                    let stale = RecentAnalysis(id: UUID(), root: row.root, observedThrough: row.observedThrough,
                        result: row.result, policy: row.policy)
                    let starts = owner.allScanStartsForSessionReuseVerification
                    try UIVerification.require(owner.beginSavedForVerification(stale), "recent-stale-row-admission")
                    try await UIVerification.waitUntil("recent-stale-row-settles") { !owner.hasWork }
                    try UIVerification.require(owner.recordedOpenIssueForVerification == .changed
                        && owner.recordedMetadataForVerification == nil
                        && owner.allScanStartsForSessionReuseVerification == starts,
                        "recent-stale-id-cannot-scan")
                    try UIVerification.require(owner.beginSavedForVerification(row), "recent-exact-row-admission")
                    try await UIVerification.waitUntil("recent-exact-row-settles") { !owner.hasWork }
                    try UIVerification.require(owner.recordedMetadataForVerification?.catalogID == row.id
                        && owner.allScanStartsForSessionReuseVerification == starts,
                        "recent-exact-id-reopens-without-scanner")
                    checks += ["Recent Analyses shows one complete saved record; a wrong ID refuses without scanning, while its exact ID reopens without a scanner start"]
                    stage = "idle-saved-hover"
                    await owner.stopAndDrain()
                    let hover = await owner.datedHoverSummaryForVerification(root: folder, access: FolderAccessController(stateDirectory: nil))
                    try UIVerification.require(hover?.observationIsPrevious == true
                        && hover?.bytes?.dataLogical.knownBytes == bytes.dataLogical.knownBytes
                        && owner.pagedScanStartsForSessionReuseVerification == 1
                        && !owner.hasWork && ApplicationFileActivity.gate.activeCount == 0,
                        "idle-hover-closes-its-query-owner-without-scanning")
                    checks += ["A saved hover opens and fully releases its idle catalog after foreground drain, without a second scan"]
                } else if phase == "reopen" {
                    stage = "cold-properties"
                    guard let value = model.analysisValue, let bytes = value.bytes, let counts = value.counts else {
                        throw UIVerification.Failure(message: "cold-properties-result")
                    }
                    let expected = try await Task.detached {
                        try JSONSerialization.jsonObject(with: PersistenceFixtureIO.read(seed, maximum: 4096)) as? [String: NSNumber]
                    }.value
                    try UIVerification.require(value.observationIsPrevious && value.message.contains("May be out of date")
                        && value.message.contains("Last analyzed"), "cold-dated-status")
                    try UIVerification.require(expected?["logicalBytes"]?.uint64Value == bytes.dataLogical.knownBytes
                        && expected?["files"]?.uint64Value == counts.regularFiles
                        && abs((expected?["observed"]?.doubleValue ?? 0) - value.observedAt.timeIntervalSince1970) < 0.01,
                        "cold-original-totals-and-date")
                    try UIVerification.require(value.scanElapsed != nil
                        && abs((value.scanElapsed ?? -1) - (expected?["elapsed"]?.doubleValue ?? -2)) < 0.000001,
                        "cold-properties-retains-actual-scan-duration")
                    try UIVerification.require(model.chartDrill.canBrowse && owner.allScanStartsForSessionReuseVerification == 0,
                        "cold-chart-without-traversal")
                    checks += ["Fresh process restores dated Properties chart after a child changed; zero scanner starts"]
                    stage = "cold-hover-summary"
                    let hover = await owner.datedHoverSummaryForVerification(root: folder, access: FolderAccessController(stateDirectory: nil))
                    try UIVerification.require(hover?.observationIsPrevious == true
                        && hover?.message.contains("May have changed") == true
                        && hover?.bytes?.dataLogical.knownBytes == bytes.dataLogical.knownBytes
                        && hover?.counts?.regularFiles == counts.regularFiles
                        && hover?.observedAt == value.observedAt
                        && owner.allScanStartsForSessionReuseVerification == 0
                        && model.chartDrill.canBrowse,
                        "cold-hover-reuses-dated-observation-without-traversal-or-chart-revocation")
                    checks += ["Saved hover summary restores the same dated totals without scanning, even while the Properties chart retains its own query consumer"]
                    stage = "cold-descendant-hover"
                    let access = FolderAccessController(stateDirectory: nil)
                    let project = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Project"), access: access)
                    let empty = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Project/Project/Empty"), access: access)
                    let missing = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Missing"), access: access)
                    let linked = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Link/Project"), access: access)
                    let regular = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Project/Two.swift"), access: access)
                    let sibling = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("../Analysis-sibling"), access: access)
                    try UIVerification.require(project?.observationIsPrevious == true
                        && project?.bytes?.dataLogical.knownBytes == 11 && project?.counts?.regularFiles == 2
                        && project?.counts?.directories == 2 && project?.observedAt == value.observedAt
                        && empty?.bytes?.dataLogical.knownBytes == 0 && empty?.counts?.total == 0
                        && empty?.observationIsPrevious == true && empty?.observedAt == value.observedAt
                        && missing == nil && linked == nil && regular == nil && sibling == nil
                        && owner.allScanStartsForSessionReuseVerification == 0
                        && model.chartDrill.canBrowse && !owner.hasWork && ApplicationFileActivity.gate.activeCount == 0,
                        "cold-descendant-hover-keeps-date-bounds-and-query-ownership")
                    checks += ["Cold saved descendant hover crosses a256-row page boundary and repeated directory names, retains the original date and zero scans; empty is zero, missing/file/symlink/sibling are misses and the foreground chart stays live"]
                    stage = "full-window-handoff"
                    model.openFullAnalysis()
                    try hideFunctionalWindows()
                    guard let window = owner.toolWindow else { throw UIVerification.Failure(message: "full-window") }
                    try await UIVerification.waitUntil(stage) { window.pagedReadyForVerification }
                    try UIVerification.require(window.pagedRowCountForVerification > 0 && window.chartCanBrowseForVerification,
                        "cold-full-chart-and-paged-rows")
                    try UIVerification.require(window.pagedModelForVerification?.canActOnSelection == false,
                        "cold-view-grants-no-file-mutation")
                    try UIVerification.require(model.analysisValue?.counts?.regularFiles == counts.regularFiles
                        && model.analysisValue?.bytes?.dataLogical.knownBytes == bytes.dataLogical.knownBytes
                        && model.analysisValue?.observedAt == value.observedAt
                        && model.analysisValue?.scanElapsed == value.scanElapsed
                        && model.analysisValue?.scanStatus == value.scanStatus
                        && model.analysisValue?.coverage == value.coverage
                        && !model.chartDrill.canBrowse,
                        "properties-keeps-compact-totals-after-query-handoff")
                    checks += ["Properties hands the same recorded view to native chart and paged rows"]
                    stage = "immediate-full-reopen"
                    window.close()
                    model.openFullAnalysis()
                    try hideFunctionalWindows()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(window.chartCanBrowseForVerification
                        && model.analysisValue?.counts?.regularFiles == counts.regularFiles
                        && model.analysisValue?.observedAt == value.observedAt
                        && model.analysisValue?.coverage == value.coverage
                        && owner.allScanStartsForSessionReuseVerification == 0,
                        "one-click-full-reopen-without-properties-reset-or-scan")
                    checks += ["Properties retains dated totals after handoff; one click reopens the saved breakdown after closing Analyzer, without resetting Properties or rescanning"]
                    stage = "refresh"
                    if arguments.contains("--record-analysis-persistence"), let native = window.window {
                        native.title = "Storage Analysis · generated review · retained analysis"
                        native.setContentSize(.init(width: 960, height: 700))
                        native.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                        native.contentView?.layoutSubtreeIfNeeded()
                        refreshHeaderFrames = []
                        sampleRefreshHeader(window)
                        let observed = [window.statusLabel.superview, window.scopeLabel, window.summaryLabel].compactMap { $0 }
                        let frameObservers = observed.map { view in
                            view.postsFrameChangedNotifications = true
                            return BrowserNotificationObservation(name: NSView.frameDidChangeNotification, object: view) { [weak window] _ in
                                MainActor.assumeIsolated { if let window { sampleRefreshHeader(window) } }
                            }
                        }
                        let capture = try await NativeMotionRecorder.record(window: native, root: root,
                            label: "analysis-refresh", sampling: .diagnostic(for: native)) {
                            window.refreshButton.performClick(nil)
                        }
                        try UIVerification.require(capture.streamStopped && capture.writerCompleted
                            && capture.droppedEncoderFrames == 0, "refresh-window-capture")
                        clips.append(["label": "analysis-refresh", "frames": capture.frames.count,
                            "captureGeometry": capture.captureGeometry, "droppedEncoderFrames": capture.droppedEncoderFrames])
                        withExtendedLifetime(frameObservers) {}
                        sampleRefreshHeader(window)
                        if let first = refreshHeaderFrames.first, let height = first["stateHeight"], let frame = first["windowHeight"] {
                            try UIVerification.require(refreshHeaderFrames.allSatisfy {
                                abs(($0["stateHeight"] ?? height) - height) <= 4 && abs(($0["windowHeight"] ?? frame) - frame) <= 1
                            }, "refresh-header-layout-stable")
                        }
                    } else { window.refreshButton.performClick(nil) }
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.allScanStartsForSessionReuseVerification == 1
                        && owner.pagedSummaryForVerification?.value.bytes.dataLogical.knownBytes == 4107
                        && owner.recordedMetadataForVerification != nil && window.chartCanBrowseForVerification,
                        "refresh-replaces-dated-totals-with-new-observation")
                    stage = "incremental-generated-changes"
                    guard let baseline = owner.recordedMetadataForVerification, let fullCheckpoint = baseline.refreshCheckpoint else {
                        throw UIVerification.Failure(message: "full-baseline-has-event-checkpoint")
                    }
                    try UIVerification.require(baseline.scanElapsed != nil && window.scopeLabel.stringValue == folder.path,
                        "recorded-scope-and-actual-scan-time")
                    try await Task.detached { try PersistenceFixtureIO.changeGeneratedProject(folder) }.value
                    // Model distinct user gestures, allowing the event daemon to
                    // receive the completed, fsynced generated edits before Update.
                    try await Task.sleep(for: .milliseconds(250))
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    guard let updated = owner.recordedMetadataForVerification,
                          let refresh = updated.refreshCheckpoint, let incremental = owner.pagedSummaryForVerification else {
                        throw UIVerification.Failure(message: "incremental-observation-published")
                    }
                    refreshEvidence = ["isIncremental": refresh.isIncremental,
                        "fallbackReason": refresh.fallbackReason ?? "none", "reusedEntries": refresh.reusedEntries,
                        "reusedDirectories": refresh.reusedDirectories ?? 0,
                        "enumeratedDirectories": refresh.enumeratedDirectories,
                        "baselineEnumeratedDirectories": fullCheckpoint.enumeratedDirectories]
                    // A fresh tree can replay its earlier creation namespace
                    // through FullHistory and exhaust the bounded dirty plan.
                    // That documented full fallback is a valid Refresh, not a
                    // reuse result. The separate retained-source journey keeps
                    // its strict reduced-enumeration acceptance.
                    if refresh.isIncremental {
                        try UIVerification.require(refresh.fallbackReason == nil
                            && refresh.reusedDirectories != nil && refresh.enumeratedDirectories >= 3
                            && refresh.enumeratedDirectories + (refresh.reusedDirectories ?? 0) == fullCheckpoint.enumeratedDirectories
                            && (refresh.mayContainEarlierObservations
                                ? window.statusLabel.stringValue.contains("reused")
                                : window.statusLabel.stringValue.contains("No earlier observations reused")),
                            "refresh-accounts-for-every-generated-directory-and-reports-actual-reuse")
                    } else {
                        try UIVerification.require(["dirty_overflow", "root_dirty"].contains(refresh.fallbackReason ?? "")
                            && refresh.reusedEntries == 0 && (refresh.reusedDirectories ?? 0) == 0
                            && refresh.enumeratedDirectories == fullCheckpoint.enumeratedDirectories
                            && window.statusLabel.stringValue.contains("full scan"),
                            "fresh-creation-overlap-or-recursive-root-runs-honest-complete-full-fallback")
                    }
                    try UIVerification.require(incremental.value.bytes.dataLogical.knownBytes == 4117
                        && updated.catalogID != baseline.catalogID, "refresh-publishes-exact-new-observation")
                    let oldEmpty = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Project/Project/Empty"), access: access)
                    let renamed = await owner.datedHoverSummaryForVerification(root: folder.appendingPathComponent("Project/Project/Renamed-🧭"), access: access)
                    try UIVerification.require(oldEmpty == nil && renamed?.counts?.total == 0
                        && (refresh.mayContainEarlierObservations ? renamed?.message.contains("Other observations") == true
                            : renamed?.message.hasPrefix("Scanned ") == true),
                        "refresh-rename-removal-and-honest-hover-provenance")
                    stage = "incremental-full-reference"
                    window.scanEveryFolderButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.pagedSummaryForVerification?.value == incremental.value
                        && owner.recordedMetadataForVerification?.refreshCheckpoint?.isIncremental == false,
                        "incremental-totals-equal-independent-full-reference")
                    stage = "incremental-Stop-preserves-old"
                    let beforeStop = owner.recordedMetadataForVerification?.catalogID
                    window.refreshButton.performClick(nil)
                    owner.stopForSessionReuseVerification()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.recordedMetadataForVerification?.catalogID == beforeStop
                        && window.chartCanBrowseForVerification,
                        "Stop-keeps-original-recorded-generation-and-query-consumer")
                    stage = "incremental-history-gap-full-fallback"
                    owner.invalidateNextRefreshHistoryForVerification()
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.pagedReadyForVerification }
                    guard let fallback = owner.recordedMetadataForVerification?.refreshCheckpoint else {
                        throw UIVerification.Failure(message: "gap-fallback-published")
                    }
                    try UIVerification.require(!fallback.isIncremental && fallback.reusedEntries == 0
                        && (fallback.reusedDirectories ?? 0) == 0
                        && fallback.fallbackReason == "event_uuid_changed"
                        && owner.pagedSummaryForVerification?.value == incremental.value
                        && window.statusLabel.stringValue.contains("full scan"),
                        "real-volume-UUID-check-rejects-gap-and-runs-ordinary-full-scanner")
                    checks += [refresh.isIncremental
                            ? "Change-plan Refresh accounts for every generated directory after edit/add/remove/Unicode rename and reports its actual borrowed listings"
                            : "Fresh creation-history overlap selects a complete full Refresh, reports its fallback and claims no borrowed folders",
                        "Refreshed totals equal a separate full scan; Properties/Analyzer retain scope, actual duration and honest observation provenance",
                        "Stop preserves the old generation and its live queries; a mismatched event UUID causes a visible ordinary full scan"]
                    guard let savedBeforeRecordingOff = owner.recordedMetadataForVerification else {
                        throw UIVerification.Failure(message: "recent-analysis-record-before-recording-off")
                    }
                    let savedRow = RecentAnalysis(id: savedBeforeRecordingOff.catalogID, root: folder,
                        observedThrough: savedBeforeRecordingOff.observedThrough, result: .complete,
                        policy: savedBeforeRecordingOff.metadataPolicy)
                    let startsBeforeRecordingOff = owner.allScanStartsForSessionReuseVerification
                    settings.analysisKeepsResults = false
                    window.refreshButton.performClick(nil)
                    try await UIVerification.waitUntil("recording-off-scan") { !owner.hasWork && window.pagedReadyForVerification }
                    try UIVerification.require(owner.allScanStartsForSessionReuseVerification == startsBeforeRecordingOff + 1
                        && owner.recordedMetadataForVerification == nil && window.chartCanBrowseForVerification,
                        "recording-off-keeps-normal-scan-and-shared-pool-accounting")
                    checks += ["Refresh replaces dated totals; recording-off still supports ordinary scan and chart"]
                    stage = "recent-analysis-disabled-and-replaced"
                    guard case .disabled = await owner.recentSavedAnalyses(keepingResults: false) else {
                        throw UIVerification.Failure(message: "recent-disabled-hides-saved-rows")
                    }
                    let startsBeforeRecent = owner.allScanStartsForSessionReuseVerification
                    try UIVerification.require(owner.beginSavedForVerification(savedRow), "recent-disabled-row-admission")
                    try await UIVerification.waitUntil("recent-disabled-row-settles") { !owner.hasWork }
                    try UIVerification.require(owner.recordedMetadataForVerification == nil
                        && owner.allScanStartsForSessionReuseVerification == startsBeforeRecent,
                        "recent-disabled-refuses-open-without-scan")
                    settings.analysisKeepsResults = true
                    try UIVerification.require(owner.sessionReuseCountForVerification > 0,
                        "recent-replaced-id-requires-live-session-cache-candidate")
                    let replaced = RecentAnalysis(id: baseline.catalogID, root: folder,
                        observedThrough: baseline.observedThrough, result: .complete,
                        policy: baseline.metadataPolicy)
                    try UIVerification.require(owner.beginSavedForVerification(replaced), "recent-replaced-row-admission")
                    try await UIVerification.waitUntil("recent-replaced-row-settles") { !owner.hasWork }
                    try UIVerification.require(owner.recordedOpenIssueForVerification == .changed
                        && owner.allScanStartsForSessionReuseVerification == startsBeforeRecent,
                        "recent-replaced-catalog-refuses-without-scan")
                    checks += ["Keep Recent off suppresses rows and exact-row reopening; a replaced catalog ID cannot reopen a newer generation or start a scanner"]
                    stage = "forget"
                    window.onClearSessionResults?()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && window.statusLabel.stringValue.contains("removed") }
                    try UIVerification.require(!model.chartDrill.canBrowse && !window.chartCanBrowseForVerification
                        && window.pagedRowCountForVerification == 0, "forget-revokes-all-view-queries")
                    try UIVerification.require(owner.beginSavedForVerification(savedRow), "recent-forgotten-row-admission")
                    try await UIVerification.waitUntil("recent-forgotten-row-settles") { !owner.hasWork }
                    try UIVerification.require(owner.recordedOpenIssueForVerification == .changed
                        && owner.allScanStartsForSessionReuseVerification == startsBeforeRecent,
                        "recent-forgotten-id-refuses-without-scan")
                    controller.update(urls: [folder])
                    try await UIVerification.waitUntil("post-forget-properties") { !model.isLoading && !owner.hasWork }
                    try UIVerification.require(model.attribution == nil && !model.chartDrill.canBrowse
                        && owner.allScanStartsForSessionReuseVerification == startsBeforeRecordingOff + 1, "forget-no-reopen-or-source-scan")
                    let unchanged = try await Task.detached {
                        try PersistenceFixtureIO.read(folder.appendingPathComponent("One.txt"), maximum: 4096)
                            == Data(repeating: 65, count: 4096)
                    }.value
                    try UIVerification.require(unchanged, "forget-keeps-generated-source")
                    checks += ["Actual Forget revokes both views; reopening misses without scanning or changing source"]
                } else {
                    stage = "interrupted-index"
                    model.analyzeStorage()
                    try await UIVerification.waitUntil(stage) { !owner.hasWork && model.analysisValue?.isRunning == false }
                    try UIVerification.require(owner.allScanStartsForSessionReuseVerification == 0
                        && model.analysisValue?.message.contains("Repair Saved Analyses") == true,
                        "interrupted-index-refuses-before-source-scan")
                    await owner.repairRecordedAnalyses()
                    let canonical = try await Task.detached {
                        (try PersistenceFixtureIO.isAbsent(interruptedStage),
                         try PersistenceFixtureIO.read(index, maximum: 8192))
                    }.value
                    try UIVerification.require(owner.savedAnalysesMaintenanceMessage.contains("is ready")
                        && canonical.0 && canonical.1 == canonicalBefore,
                        "explicit-repair-preserves-canonical-index")
                    model.analyzeStorage()
                    try await UIVerification.waitUntil("scan-after-repair") { !owner.hasWork && model.analysisValue?.isRunning == false }
                    try UIVerification.require(model.analysisValue?.isComplete == true
                        && model.analysisValue?.bytes?.dataLogical.knownBytes == 4117
                        && owner.allScanStartsForSessionReuseVerification == 1,
                        "explicit-repair-restores-normal-analysis")
                    // Reproduce a second user action arriving after maintenance's
                    // flag loop but before its final real-discard join returns.
                    let tail = DrainTail()
                    owner.beforeFinalDrainForVerification = {
                        owner.beforeFinalDrainForVerification = nil
                        tail.entered = true
                        while !tail.released { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                    let draining = Task { @MainActor in await owner.stopAndDrain() }
                    var repairing: Task<Void, Never>?
                    do {
                        try await UIVerification.waitUntil("final-drain-held") { tail.entered }
                        repairing = Task { @MainActor in await owner.repairRecordedAnalyses() }
                        try await UIVerification.waitUntil("late-repair-recorded") { owner.repairPendingForVerification }
                        tail.released = true
                        await draining.value; await repairing?.value
                    } catch {
                        tail.released = true
                        await draining.value; await repairing?.value
                        throw error
                    }
                    try UIVerification.require(!owner.repairPendingForVerification && !owner.hasWork
                        && owner.savedAnalysesMaintenanceMessage.contains("is ready"), "late-repair-completes-before-return")
                    await owner.forgetRecordedAnalyses()
                    checks += ["Interrupted index refuses before source scan; explicit App repair preserves canonical index and restores Analyze",
                        "Repair requested during final drain is consumed and completed before both callers return"]
                }
            }
        } catch {
            failure = stage + ":" + semanticCode(error)
            openIssue = owner.recordedOpenIssueForVerification.map { String(describing: $0) } ?? "none"
            propertyStatus = properties?.model.analysisValue?.message ?? "none"
        }
        let geometry: [String: Double]
        if let window = owner.toolWindow?.window {
            geometry = ["width": window.frame.width, "height": window.frame.height,
                "minimumHeight": window.minSize.height, "contentHeight": Double(window.contentView?.bounds.height ?? 0)]
        } else { geometry = [:] }
        properties?.cancel(); properties?.close()
        await owner.stopAndDrain(shuttingDown: true)
        owner.toolWindow?.close()
        await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
        if let successfulSource {
            do {
                if let ownedLeaf {
                    try await Task.detached { try ownedLeaf.remove(in: successfulSource) }.value
                    refreshEvidence["ownedLeafCleanup"] = "removed-exact-inode-after-drain"
                    checks += ["After real owner drain only the exact new one-byte inode is removed; old metadata inventory/index/receipts remain identical; root directory times may change"]
                } else {
                    try await Task.detached { try successfulSource.validateRestored() }.value
                }
            } catch {
                refreshEvidence["ownedLeafCleanup"] = "retained-or-incomplete-no-retry"
                refreshEvidence["cleanupFailure"] = semanticCode(error)
                failure = failure ?? "successful-source-cleanup:" + semanticCode(error)
            }
        }
        let idle = !owner.hasWork && ApplicationFileActivity.gate.activeCount == 0
        let passed = failure == nil && idle
        var evidenceWritten = false
        if let scope {
            let report: [String: Any] = ["passed": passed, "phase": phase, "failure": failure ?? "none",
                "checks": checks, "ownerIdle": idle, "scannerStarts": owner.allScanStartsForSessionReuseVerification,
                "process": ProcessInfo.processInfo.processIdentifier, "physicalInputQualified": false,
                "offscreenFunctionalFlow": offscreen, "visualAcceptanceClaimed": false,
                "openIssue": openIssue, "propertyStatus": propertyStatus, "clips": clips,
                "toolWindowGeometry": geometry, "refreshHeaderFrames": refreshHeaderFrames,
                "refresh": refreshEvidence, "pagedDiagnostic": owner.pagedDiagnosticForVerification]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                evidenceWritten = (try? await Task.detached {
                    try PersistenceFixtureIO.writeNew(data,
                        to: scope.appendingPathComponent("evidence/persistence-" + phase + "-result.json"))
                    return true
                }.value) == true
            }
        }
        Darwin.exit(passed && evidenceWritten ? 0 : 1)
    }
}
#endif
