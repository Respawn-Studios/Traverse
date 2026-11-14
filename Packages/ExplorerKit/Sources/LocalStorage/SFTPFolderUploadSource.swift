import CryptoKit
import Darwin
import ExplorerCore
import Foundation

struct SFTPFolderUploadObservation: Sendable, Equatable, Codable {
    let device: Int32, inode: UInt64, generation: UInt32, size: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    let mode: UInt16, flags: UInt32, links: UInt16
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    static func read(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw SFTPUploadSourceFailure.unavailable }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG, value.st_size >= 0,
              value.st_flags & UInt32(SF_DATALESS) == 0,
              kind != S_IFREG || value.st_nlink == 1 else { throw SFTPUploadSourceFailure.unsupported }
        return .init(device: value.st_dev, inode: value.st_ino, generation: value.st_gen, size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec,
            mode: value.st_mode, flags: value.st_flags, links: value.st_nlink)
    }
}

struct SFTPFolderUploadSourceSnapshot: Sendable, Equatable, Codable, CustomDebugStringConvertible {
    let id: UUID, name: String, observation: SFTPFolderUploadObservation, manifestDigest: Data, inventoryDigest: Data
    let files: Int, folders: Int, logicalBytes: UInt64
    var debugDescription: String { "<SFTP explicit local folder source>" }
    func validate() throws {
        guard id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
              SFTPFolderUploadManifest.validComponent(Data(name.utf8)), observation.directory,
              observation.size >= 0, observation.inode > 0, observation.links > 0,
              (0..<1_000_000_000).contains(observation.modifiedNanoseconds), (0..<1_000_000_000).contains(observation.changedNanoseconds),
              observation.flags & UInt32(SF_DATALESS) == 0, manifestDigest.count == 32, inventoryDigest.count == 32,
              (0...SFTPFolderUploadManifest.maximumFiles).contains(files), folders >= 0,
              folders < SFTPFolderUploadManifest.maximumNodes, files + folders < SFTPFolderUploadManifest.maximumNodes,
              logicalBytes <= SFTPFolderUploadManifest.maximumLogicalBytes else { throw SFTPUploadSourceFailure.unsupported }
    }
}

/// One concrete pinned local tree, owned by the explicit Upload request. The
/// inventory never reads bodies. Actual file reads require a later admission,
/// bind a manifest index and offset, and drain on the same serial executor.
final class SFTPFolderUploadSource: @unchecked Sendable {
    let snapshot: SFTPFolderUploadSourceSnapshot, manifest: SFTPFolderUploadManifest
    private let executor = UploadLocalExecutor(label: "Traverse.SFTP.FolderUpload.Source")
    private let stop = UploadCancellation(), lock = NSLock()
    private final class Storage: @unchecked Sendable {
        var root: Int32, active: Int32 = -1
        var access: (URL, UploadSourceAccessHooks, Bool)?
        init(root: Int32, access: (URL, UploadSourceAccessHooks, Bool)) { self.root = root; self.access = access }
        func close() {
            if active >= 0 { Darwin.close(active); active = -1 }
            if root >= 0 { Darwin.close(root); root = -1 }
            if let (url, hooks, held) = access, held { hooks.stop(url) }; access = nil
        }
        deinit { close() }
    }
    private let storage: Storage, url: URL, exclusions: [URL], observations: [SFTPFolderUploadObservation]
    private let readProbe: (@Sendable () throws -> Void)?
    private var admitted = false, failed = false, nextFile: Int, offset: UInt64 = 0
    private var hash = SHA256(), hashes: [Data?]

    private init(url: URL, root: Int32, access: (URL, UploadSourceAccessHooks, Bool), excluding: [URL],
                 inventory: (SFTPFolderUploadManifest, [SFTPFolderUploadObservation]), readProbe: (@Sendable () throws -> Void)?) throws {
        self.url = url; exclusions = excluding; manifest = inventory.0; observations = inventory.1
        var fingerprint = SHA256(); fingerprint.update(data: inventory.0.encoded)
        for stamp in inventory.1 {
            func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { fingerprint.update(bufferPointer: $0) } }
            append(stamp.device); append(stamp.inode); append(stamp.generation); append(stamp.size)
            append(Int64(stamp.modifiedSeconds)); append(Int64(stamp.modifiedNanoseconds)); append(Int64(stamp.changedSeconds)); append(Int64(stamp.changedNanoseconds))
            append(stamp.mode); append(stamp.flags); append(stamp.links)
        }
        snapshot = .init(id: UUID(), name: url.lastPathComponent, observation: inventory.1[0], manifestDigest: inventory.0.digest, inventoryDigest: Data(fingerprint.finalize()),
            files: inventory.0.files, folders: inventory.0.folders, logicalBytes: inventory.0.logicalBytes)
        try snapshot.validate(); storage = Storage(root: root, access: access); self.readProbe = readProbe
        nextFile = inventory.0.nodes.firstIndex(where: { !$0.directory }) ?? inventory.0.nodes.count
        hashes = Array(repeating: nil, count: inventory.0.nodes.count)
    }
    deinit { let held = storage; executor.enqueueDrain { held.close() } }

    static func prepare(_ url: URL, excluding: [URL], accessHooks: UploadSourceAccessHooks = .init(),
                        readProbe: (@Sendable () throws -> Void)? = nil,
                        inventoryProbe: (@Sendable () throws -> Void)? = nil) async throws -> SFTPFolderUploadSource {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), url.path != "/", url.standardizedFileURL.path == url.path, !url.path.utf8.contains(0),
              excluding.allSatisfy({ $0.isFileURL && $0.query == nil && $0.fragment == nil && $0.path.hasPrefix("/") && $0.standardizedFileURL.path == $0.path }) else { throw SFTPUploadSourceFailure.unavailable }
        let worker = UploadLocalExecutor(label: "Traverse.SFTP.FolderUpload.Inventory")
        let cancellation = UploadCancellation()
        return try await withTaskCancellationHandler {
          let (source, late) = try await worker.perform {
            let held = accessHooks.start(url); var descriptor: Int32 = -1, accepted = false
            defer { if !accepted { if descriptor >= 0 { Darwin.close(descriptor) }; if held { accessHooks.stop(url) } } }
            try Self.allowed(url, excluding: excluding)
            descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard descriptor >= 0 else { throw SFTPUploadSourceFailure.unavailable }
            var filesystem = statfs()
            guard fstatfs(descriptor, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw SFTPUploadSourceFailure.unsupported }
            let type = withUnsafePointer(to: &filesystem.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            guard type == "apfs" else { throw SFTPUploadSourceFailure.unsupported }
            let inventory = try Self.inventory(descriptor, url: url, excluding: excluding, check: {
                if cancellation.cancelled { throw SFTPUploadSourceFailure.stopped }
                try inventoryProbe?()
                if cancellation.cancelled { throw SFTPUploadSourceFailure.stopped }
            })
            let value = try Self(url: url, root: descriptor, access: (url, accessHooks, held), excluding: excluding, inventory: inventory, readProbe: readProbe)
            accepted = true; return value
          }
          guard !late, !Task.isCancelled else { await source.drain(); throw SFTPUploadSourceFailure.stopped }; return source
        } onCancel: { cancellation.cancel() }
    }

    private static func allowed(_ url: URL, excluding: [URL]) throws {
        guard !AutomaticMetadataPolicy.excludes(url),
              !url.pathComponents.contains(where: { ["cloudstorage", "mobile documents"].contains($0.lowercased()) }),
              !excluding.contains(where: { $0.path == "/" || url.path == $0.path || url.path.hasPrefix($0.path + "/") }),
              try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem != true else { throw SFTPUploadSourceFailure.unavailable }
    }
    private static func named<T>(_ name: Data, _ work: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        try (Array(name) + [0]).withUnsafeBufferPointer { try $0.baseAddress!.withMemoryRebound(to: CChar.self, capacity: $0.count) { try work($0) } }
    }
    private static func noExtraFork(_ descriptor: Int32) throws {
        errno = 0; let size = fgetxattr(descriptor, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard size == 0 || size < 0 && errno == ENOATTR else { throw SFTPUploadSourceFailure.unsupportedMetadata }
    }
    private static func names(_ descriptor: Int32, check: () throws -> Void) throws -> [Data] {
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copy >= 0 else { throw SFTPUploadSourceFailure.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw SFTPUploadSourceFailure.unavailable }
        defer { closedir(stream) }; var result: [Data] = []
        while true {
            try check(); errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw SFTPUploadSourceFailure.unavailable }; break }
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { Data(bytes: $0, count: length) } }
            if bytes == Data([46]) || bytes == Data([46, 46]) { continue }
            guard SFTPFolderUploadManifest.validComponent(bytes), result.count < SFTPFolderUploadManifest.maximumNodes else { throw SFTPUploadSourceFailure.unsupported }
            result.append(bytes)
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }
    private static func inventory(_ root: Int32, url: URL, excluding: [URL], check: () throws -> Void) throws -> (SFTPFolderUploadManifest, [SFTPFolderUploadObservation]) {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        let rootStamp = try SFTPFolderUploadObservation.read(root)
        guard rootStamp.directory else { throw SFTPUploadSourceFailure.unsupported }
        var nodes: [SFTPFolderUploadManifest.Node] = [], stamps: [SFTPFolderUploadObservation] = [], files = 0
        var bytes: UInt64 = 0, encodedSize = 12
        func visit(_ fd: Int32, _ parts: [Data], _ location: URL) throws {
            try check(); let stamp = try SFTPFolderUploadObservation.read(fd)
            guard stamp.device == rootStamp.device, parts.count <= SFTPFolderUploadManifest.maximumDepth,
                  nodes.count < SFTPFolderUploadManifest.maximumNodes else { throw SFTPUploadSourceFailure.unsupported }
            let added = 10 + parts.reduce(0, { $0 + 2 + $1.count })
            guard added <= SFTPFolderUploadManifest.maximumEncodedBytes - encodedSize else { throw SFTPUploadSourceFailure.unsupported }
            encodedSize += added
            try noExtraFork(fd)
            if !stamp.directory {
                guard files < SFTPFolderUploadManifest.maximumFiles, UInt64(stamp.size) <= SFTPFolderUploadManifest.maximumLogicalBytes - bytes else { throw SFTPUploadSourceFailure.unsupported }
                files += 1; bytes += UInt64(stamp.size)
            }
            nodes.append(.init(kind: stamp.directory ? .directory : .file, components: parts, size: stamp.directory ? 0 : UInt64(stamp.size))); stamps.append(stamp)
            if stamp.directory {
                for name in try names(fd, check: check) {
                    try check(); let childURL = location.appendingPathComponent(String(decoding: name, as: UTF8.self))
                    try allowed(childURL, excluding: excluding)
                    let child = named(name) { openat(fd, $0, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
                    guard child >= 0 else { throw SFTPUploadSourceFailure.unavailable }; defer { Darwin.close(child) }
                    let seen = try SFTPFolderUploadObservation.read(child)
                    if seen.directory {
                        let directory = named(name) { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
                        guard directory >= 0 else { throw SFTPUploadSourceFailure.unavailable }; defer { Darwin.close(directory) }
                        guard try SFTPFolderUploadObservation.read(directory) == seen else { throw SFTPUploadSourceFailure.changed }
                        try visit(directory, parts + [name], childURL)
                    } else { try visit(child, parts + [name], childURL) }
                    guard try SFTPFolderUploadObservation.read(child) == seen else { throw SFTPUploadSourceFailure.changed }
                }
            }
            guard try SFTPFolderUploadObservation.read(fd) == stamp else { throw SFTPUploadSourceFailure.changed }
        }
        try visit(root, [], url); return (try SFTPFolderUploadManifest(nodes: nodes), stamps)
    }

    private func check() throws { if stop.cancelled { throw SFTPUploadSourceFailure.stopped }; guard !failed, storage.root >= 0 else { throw SFTPUploadSourceFailure.changed } }
    private func validateRoot() throws {
        try check(); let fresh = Darwin.open(url.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fresh >= 0 else { throw SFTPUploadSourceFailure.changed }; defer { Darwin.close(fresh) }
        guard try SFTPFolderUploadObservation.read(fresh) == observations[0], try SFTPFolderUploadObservation.read(storage.root) == observations[0] else { throw SFTPUploadSourceFailure.changed }
    }
    private func validateInventory() throws {
        try validateRoot(); let current = try Self.inventory(storage.root, url: url, excluding: exclusions, check: check)
        guard current.0 == manifest, current.1 == observations else { throw SFTPUploadSourceFailure.changed }
    }
    func validateBeforeMutationOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        try lock.withLock { do { guard !admitted else { throw SFTPUploadSourceFailure.changed }; try validateInventory(); admitted = true } catch { failed = true; throw error } }
    }
    func validateBeforeMutation() async throws {
        let (_, late) = try await executor.perform { [self] in try validateBeforeMutationOnSessionExecutor() }
        guard !late else { requestStop(); throw SFTPUploadSourceFailure.stopped }
    }
    func revalidateOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        try lock.withLock { do { guard admitted else { throw SFTPUploadSourceFailure.changed }; try validateInventory() } catch { failed = true; throw error } }
    }
    private func openFile(_ index: Int) throws {
        try validateRoot(); var parent = storage.root, owned: Int32 = -1
        defer { if owned >= 0 { Darwin.close(owned) } }
        let parts = manifest.nodes[index].components
        for depth in 1..<parts.count {
            let next = Self.named(parts[depth - 1]) { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
            guard next >= 0 else { throw SFTPUploadSourceFailure.changed }
            let path = Array(parts.prefix(depth))
            guard let slot = manifest.nodes.firstIndex(where: { $0.components == path }),
                  try SFTPFolderUploadObservation.read(next) == observations[slot] else { Darwin.close(next); throw SFTPUploadSourceFailure.changed }
            if owned >= 0 { Darwin.close(owned) }; owned = next; parent = next
        }
        let file = Self.named(parts.last!) { openat(parent, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard file >= 0 else { throw SFTPUploadSourceFailure.changed }
        do { guard try SFTPFolderUploadObservation.read(file) == observations[index] else { throw SFTPUploadSourceFailure.changed }; try Self.noExtraFork(file) }
        catch { Darwin.close(file); throw error }
        storage.active = file
    }
    func readOnSessionExecutor(node: Int, offset requested: UInt64, maximum: Int) throws -> Data {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        return try lock.withLock {
            do {
                try check(); guard admitted, node == nextFile, node < manifest.nodes.count, requested == offset,
                      (1...32768).contains(maximum) else { throw SFTPUploadSourceFailure.changed }
                if storage.active < 0 { try openFile(node) }
                guard try SFTPFolderUploadObservation.read(storage.active) == observations[node] else { throw SFTPUploadSourceFailure.changed }
                try readProbe?(); try check()
                let count = min(maximum, Int(manifest.nodes[node].size - offset)); var bytes = Data(count: count)
                try bytes.withUnsafeMutableBytes { buffer in
                    var done = 0
                    while done < count {
                        try check(); let amount = pread(storage.active, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                        if amount < 0 && errno == EINTR { continue }
                        guard amount > 0 else { throw SFTPUploadSourceFailure.changed }; done += amount
                    }
                }
                guard try SFTPFolderUploadObservation.read(storage.active) == observations[node] else { throw SFTPUploadSourceFailure.changed }
                hash.update(data: bytes); offset += UInt64(bytes.count); return bytes
            } catch { failed = true; throw error }
        }
    }
    func finishFileOnSessionExecutor(node: Int, digest: Data) throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        try lock.withLock {
            do {
                try check(); guard admitted, node == nextFile, node < manifest.nodes.count, digest.count == 32,
                      offset == manifest.nodes[node].size else { throw SFTPUploadSourceFailure.changed }
                if storage.active < 0 { try openFile(node) }
                guard try SFTPFolderUploadObservation.read(storage.active) == observations[node], digest == Data(hash.finalize()) else { throw SFTPUploadSourceFailure.changed }
                hashes[node] = digest; Darwin.close(storage.active); storage.active = -1
                nextFile = ((node + 1)..<manifest.nodes.count).first(where: { !manifest.nodes[$0].directory }) ?? manifest.nodes.count
                offset = 0; hash = SHA256()
            } catch { failed = true; throw error }
        }
    }
    func finishOnSessionExecutor() throws -> Data {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        return try lock.withLock {
            do {
                try check(); guard admitted, nextFile == manifest.nodes.count, storage.active < 0 else { throw SFTPUploadSourceFailure.changed }
                try validateInventory(); var tree = SHA256(); tree.update(data: manifest.encoded)
                for (node, digest) in zip(manifest.nodes, hashes) where !node.directory { guard let digest else { throw SFTPUploadSourceFailure.changed }; tree.update(data: digest) }
                return Data(tree.finalize())
            } catch { failed = true; throw error }
        }
    }
    func requestStop() { stop.cancel() }
    func drain() async { requestStop(); await executor.drain { [self] in lock.withLock { storage.close() } } }
    func closeAfterDrainOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }; requestStop(); lock.withLock { storage.close() }
    }
}
