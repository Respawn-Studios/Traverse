import Darwin
import ExplorerCore
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Keep Both uses the same numbered names for local Add and ZIP Copy. A
/// reservation only describes this immutable ZIP namespace before writing.
internal struct ZIPNameReservations {
    private static let locale = Locale(identifier: "en_US_POSIX")
    private var occupied: Set<String>
    init(_ names: some Sequence<String>) { occupied = Set(names.map(Self.key)) }

    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: locale)
    }

    mutating func name(for original: String, isDirectory: Bool, keepOriginal: Bool,
                       pending: Set<String> = [], check: () throws -> Void) throws -> String {
        if keepOriginal, occupied.insert(Self.key(original)).inserted { return original }
        for number in 1...DuplicateDestination.maximumCandidates {
            try check()
            guard let candidate = try? DuplicateDestination.name(original,
                preservesExtension: !isDirectory, number: number) else { throw ZIPMemberRenameFailure.invalidName }
            let key = Self.key(candidate)
            if !pending.contains(key), occupied.insert(key).inserted { return candidate }
        }
        throw ZIPMemberRenameFailure.limitReached
    }
}

internal struct ZIPInputStamp: Equatable, Sendable {
    let device: Int32, inode: UInt64, generation: UInt32
    let mode: UInt16, links: UInt16, uid: UInt32, gid: UInt32, flags: UInt32
    let size: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    let birthSeconds: Int, birthNanoseconds: Int
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    init(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ZIPCreationInventory.failure() }
        device = value.st_dev; inode = value.st_ino; generation = value.st_gen; mode = value.st_mode
        links = value.st_nlink; uid = value.st_uid; gid = value.st_gid; flags = value.st_flags; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        birthSeconds = value.st_birthtimespec.tv_sec; birthNanoseconds = value.st_birthtimespec.tv_nsec
    }
    func sameObject(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && generation == other.generation
            && mode & S_IFMT == other.mode & S_IFMT && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
}
internal struct ZIPCreationInventory: Sendable {
    struct Node: Sendable {
        let path: String, url: URL, stamp: ZIPInputStamp
        let security: ZIPSourceSecurity.CreationInputWitness
        var name: String { path + (stamp.directory ? "/" : "") }
    }
    private let parents: [URL: ZIPInputStamp]
    let nodes: [Node]
    let roots: [ArchiveAddedItemPreview]
    let files: Int, folders: Int, logical: UInt64
    let hasMarkedSource: Bool
    private let allowNativeMarkedSources: Bool
    init(_ sources: [URL], prefix: String = "", allowNativeMarkedSources: Bool = false, reserving existingNames: Set<String>? = nil,
         check: () throws -> Void) throws {
        guard !sources.isEmpty, sources.count <= 512, Set(sources).count == sources.count,
              prefix.isEmpty || !prefix.hasPrefix("/") && !prefix.hasSuffix("/")
                && prefix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ Self.validName(String($0)) }) else { throw ZIPCreationFailure.unsupportedSource }
        var parents: [URL: ZIPInputStamp] = [:]
        var nodes: [Node] = [], total: UInt64 = 0, files = 0, folders = 0
        var limits = ZIPReadLimits(); limits.nodes = 20_000; limits.depth = 63
        var catalog = ZIPCatalogBuilder(limits: limits)
        func visit(_ fd: Int32, path: String, url: URL, depth: Int, device: Int32) throws {
            try check()
            guard depth <= 63, nodes.count < 19_999, path.utf8.count <= 4_096,
                  url.path.utf8.count < PATH_MAX, !AutomaticMetadataPolicy.excludes(url),
                  !url.pathComponents.contains(where: { ["cloudstorage", "mobile documents"].contains($0.lowercased()) }) else { throw ZIPCreationFailure.limitOrPrivacy }
            let before = try ZIPInputStamp(fd)
            guard before.device == device, [S_IFDIR, S_IFREG].contains(before.mode & S_IFMT),
                  before.flags & UInt32(SF_DATALESS) == 0, before.directory || before.links == 1,
                  before.directory || before.size >= 0 && before.size <= 256 * 1_024 * 1_024 else { throw ZIPCreationFailure.unsupportedSource }
            let security = try ZIPSourceSecurity.creationInputWitness(fd, url: url,
                allowingNativeMark: allowNativeMarkedSources)
            let resource = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
            guard resource == 0 || resource == -1 && errno == ENOATTR else { throw ZIPCreationFailure.resourceFork }
            let cloud = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isUbiquitousItemKey])
            guard cloud.isUbiquitousItem != true else { throw ZIPCreationFailure.unsupportedSource }
            if before.directory { folders += 1 }
            else {
                files += 1
                guard files <= 10_000, UInt64(before.size) <= 1_024 * 1_024 * 1_024 - total else { throw ZIPCreationFailure.limitOrPrivacy }
                total += UInt64(before.size)
            }
            nodes.append(.init(path: path, url: url, stamp: before, security: security))
            try catalog.add(name: path + (before.directory ? "/" : ""), kind: before.directory ? .directory : .file,
                logical: before.directory ? 0 : UInt64(before.size), packed: 0, method: 0, encrypted: false)
            if before.directory {
                let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard listing >= 0 else { throw Self.failure() }; defer { close(listing) }
                guard try ZIPInputStamp(listing) == before else { throw ZIPCreationFailure.sourceChanged }
                for name in try Self.names(listing, check: check) {
                    try check()
                    let child = openat(listing, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw Self.failure() }; defer { close(child) }
                    try visit(child, path: path + "/" + name, url: url.appendingPathComponent(name), depth: depth + 1, device: device)
                    try Self.requireEntry(listing, name: name, expected: try ZIPInputStamp(child))
                }
                guard try ZIPInputStamp(listing) == before else { throw ZIPCreationFailure.sourceChanged }
            }
            guard try ZIPInputStamp(fd) == before else { throw ZIPCreationFailure.sourceChanged }
        }
        var seenNames = Set<String>(), roots: [ArchiveAddedItemPreview] = []
        var reservations = existingNames.map { ZIPNameReservations($0) }
        let incomingNames = reservations == nil ? [] : Set(sources.map { ZIPNameReservations.key($0.lastPathComponent) })
        for source in sources {
            try check(); let name = source.lastPathComponent
            guard Self.validName(name) else { throw ZIPCreationFailure.unsupportedSource }
            if reservations == nil, !seenNames.insert(name).inserted { throw ZIPArchiveFailure.ambiguousNames }
            let parent = source.deletingLastPathComponent()
            let anchor = Darwin.open(parent.path, O_SEARCH | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard anchor >= 0 else { throw Self.failure() }; defer { close(anchor) }
            let parentStamp = try ZIPInputStamp(anchor)
            if let earlier = parents[parent], !earlier.sameObject(parentStamp) { throw ZIPCreationFailure.sourceChanged }
            parents[parent] = parentStamp
            let fd = openat(anchor, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Self.failure() }; defer { close(fd) }
            let stamp = try ZIPInputStamp(fd)
            let archiveName = try reservations?.name(for: name, isDirectory: stamp.directory,
                keepOriginal: true, pending: incomingNames, check: check) ?? name
            guard Self.validName(archiveName) else { throw ZIPCreationFailure.unsupportedSource }
            let path = prefix.isEmpty ? archiveName : prefix + "/" + archiveName
            roots.append(.init(originalName: name, archivePath: path, isDirectory: stamp.directory))
            try visit(fd, path: path, url: source,
                      depth: prefix.split(separator: "/").count + 1, device: parentStamp.device)
            try Self.requireEntry(anchor, name: name, expected: try ZIPInputStamp(fd))
            guard try ZIPInputStamp(anchor).sameObject(parentStamp) else { throw ZIPCreationFailure.sourceChanged }
        }
        let result = try catalog.finish(records: nodes.count, centralBytes: 0, zip64: false, cancelled: { (try? check()) == nil })
        guard result.summary.caseConflicts == 0 else { throw ZIPArchiveFailure.ambiguousNames }
        self.parents = parents
        self.roots = roots
        self.nodes = nodes; self.files = files; self.folders = folders; logical = total
        self.hasMarkedSource = nodes.contains { $0.security.marked }
        self.allowNativeMarkedSources = allowNativeMarkedSources
        try validate(check: check)
    }
    func open(_ node: Node, forReading: Bool = false, check: () throws -> Void) throws -> Int32 {
        try check()
        let fd = Darwin.open(node.url.path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        do {
            guard try ZIPInputStamp(fd) == node.stamp else { throw ZIPCreationFailure.sourceChanged }
            if forReading {
                let data = Darwin.open(node.url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
                guard data >= 0 else { throw Self.failure() }
                do {
                    guard try ZIPInputStamp(data) == node.stamp else { throw ZIPCreationFailure.sourceChanged }
                    close(fd); return data
                } catch { close(data); throw error }
            }
            return fd
        } catch { close(fd); throw error }
    }
    func validate(check: () throws -> Void) throws {
        try check()
        try validateParents()
        for node in nodes {
            let opened = try open(node, check: check); defer { close(opened) }
            guard try ZIPSourceSecurity.creationInputWitness(opened, url: node.url,
                allowingNativeMark: allowNativeMarkedSources) == node.security else {
                throw ZIPCreationFailure.sourceChanged
            }
            guard try ZIPInputStamp(opened) == node.stamp else { throw ZIPCreationFailure.sourceChanged }
        }
        try validateParents()
    }
    private func validateParents() throws {
        for (parent, expected) in parents {
            let fd = Darwin.open(parent.path, O_SEARCH | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw ZIPCreationFailure.sourceChanged }; defer { close(fd) }
            guard try ZIPInputStamp(fd).sameObject(expected) else { throw ZIPCreationFailure.sourceChanged }
        }
    }
    private static func names(_ fd: Int32, check: () throws -> Void) throws -> [String] {
        let copied = dup(fd); guard copied >= 0 else { throw failure() }
        guard let stream = fdopendir(copied) else { close(copied); throw failure() }; defer { closedir(stream) }
        rewinddir(stream); var result: [String] = []
        while true {
            try check(); errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
            guard let name else { throw ZIPCreationFailure.unsupportedSource }
            if name == "." || name == ".." { continue }
            guard validName(name), result.count < 20_000 else { throw ZIPCreationFailure.limitOrPrivacy }
            result.append(name)
        }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0) && name.utf8.count <= 255
    }
    private static func requireEntry(_ fd: Int32, name: String, expected: ZIPInputStamp) throws {
        let opened = openat(fd, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw ZIPCreationFailure.sourceChanged }; defer { close(opened) }
        guard try ZIPInputStamp(opened) == expected else { throw ZIPCreationFailure.sourceChanged }
    }
    static func failure(_ code: Int32 = errno) -> FileOperationFailure {
        switch code {
        case EACCES, EPERM, EROFS: .accessDenied
        case ENOSPC: .outOfSpace
        case EDQUOT: .quotaExceeded
        case ENOENT, ESTALE, ELOOP: .sourceChanged
        default: .ioFailure
        }
    }
}
