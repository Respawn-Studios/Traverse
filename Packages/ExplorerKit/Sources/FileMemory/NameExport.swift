import Darwin
import ExplorerCore
import Foundation
import LocalStorage
import SQLite3

/// An opaque, revocable preview. It never retains authored text in the caller.
public final class PreparedNameExport: Sendable {
    internal let token = UUID()
    internal let authority: NamePublicationAuthority
    internal let epoch: UInt64
    public let recordCount: Int
    public let encodedBytes: Int
    public let includesLocations: Bool
    public static let formatVersion = 1
    public static let maximumBytes = 16 * 1_024 * 1_024
    internal init(authority: NamePublicationAuthority, epoch: UInt64, count: Int, bytes: Int, locations: Bool) {
        self.authority = authority; self.epoch = epoch; recordCount = count; encodedBytes = bytes; includesLocations = locations
    }
    deinit { authority.cancelExport(self) }
}

public enum NameExportFailure: Error, Sendable, Equatable {
    case stalePreview, tooLarge, empty, invalidDestination, unsupportedDestination, destinationChanged
    case alreadyExists, accessDenied, cancelled, writeFailed, synchronizationFailed
}
public enum NameExportOutcome: Sendable, Equatable {
    case saved(bytes: Int, records: Int)
    /// A new external file exists. It may be partial or have uncertain durability.
    case createdButIncomplete(NameExportFailure)
    /// Exclusive creation never succeeded; this method published no file.
    case notCreated(NameExportFailure)
}
internal enum NameExportBoundary: String, Sendable { case admitted, beforeCreate, created, writing, written, synchronized }
internal typealias NameExportProbe = @Sendable (NameExportBoundary) throws -> Void

extension PersistentNameStore {
    public func prepareExport(includeLocations: Bool = false,
                              cancellation: RememberedNameCancellation = .init()) throws -> PreparedNameExport {
        try requireOpen()
        guard try database.pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
        let activityLease = try activity?.begin(), use = try publication.beginDiscoveryUse()
        defer { withExtendedLifetime(activityLease) {}; withExtendedLifetime(use) {} }
        let epoch = try publication.exportEpoch()
        try catalog.validate()
        let payload = try database.exportPayload(includeLocations: includeLocations, cancellation: cancellation) {
            try self.publication.checkExportEpoch(epoch)
        }
        try catalog.validate()
        return try publication.captureExport(payload.data, count: payload.count, locations: includeLocations, epoch: epoch)
    }
    public nonisolated func cancelExport(_ preview: PreparedNameExport) { publication.cancelExport(preview) }
    public func export(_ preview: PreparedNameExport, to destination: URL,
                       cancellation: RememberedNameCancellation = .init()) async -> NameExportOutcome {
        await export(preview, to: destination, cancellation: cancellation, probe: nil)
    }
    internal func export(_ preview: PreparedNameExport, to destination: URL,
                         cancellation: RememberedNameCancellation = .init(), probe: NameExportProbe?) async -> NameExportOutcome {
        do {
            try requireOpen(); try catalog.validate()
            guard !destination.standardizedFileURL.path.hasPrefix(catalog.directory.path + "/"),
                  destination.standardizedFileURL != catalog.directory else { return .notCreated(.invalidDestination) }
            let lease = try activity?.begin()
            let publication = self.publication
            // No actor callback is required to release the interval or use.
            // Forget may await actual drain while this worker finishes.
            return await Task.detached(priority: .utility) {
                defer { withExtendedLifetime(lease) {} }
                do {
                    let (data, use) = try publication.beginExport(preview)
                    defer { publication.endExport(preview); withExtendedLifetime(use) {} }
                    return NameExportFile.write(data, records: preview.recordCount, to: destination,
                                                cancellation: cancellation, probe: probe)
                } catch { return .notCreated(.stalePreview) }
            }.value
        } catch { return .notCreated(.stalePreview) }
    }
}

private struct PortableNameRecord: Encodable {
    let id: String
    let nickname: String?
    let alternateNames: [String]
    let labels: [String]
    let lastKnownLocation: String?
}
extension NameIndexDatabase {
    func exportPayload(includeLocations: Bool, cancellation: RememberedNameCancellation,
                       current: () throws -> Void) throws -> (data: Data, count: Int) {
        var data = Data("{\"format\":\"MacExplorer.PrivateNames\",\"version\":1,\"includesLocations\":\(includeLocations),\"records\":[".utf8)
        let rows = try prepare(includeLocations && hasReferenceFormat
            ? "SELECT n.id,r.hint FROM records n LEFT JOIN item_references r USING(record) WHERE n.hidden=0 ORDER BY n.record"
            : "SELECT id,NULL FROM records WHERE hidden=0 ORDER BY record")
        defer { sqlite3_finalize(rows) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var count = 0
        while try step(rows) {
            try current()
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NameExportFailure.cancelled }
            guard let uuid = UUID(uuidString: try text(rows, column: 0)), count < NameStoreFormat.maximumRecords else { throw NameStoreFailure.unsafe }
            let id = RememberedItemID(uuid), snapshot = try snapshot(id)
            // The optional hint is read directly. Export never decodes a
            // bookmark, resolves it or activates source access.
            let location = sqlite3_column_type(rows, 1) == SQLITE_NULL ? nil : try text(rows, column: 1)
            let record = PortableNameRecord(id: uuid.uuidString, nickname: snapshot.names.nickname,
                alternateNames: snapshot.names.alternateNames, labels: snapshot.names.labels, lastKnownLocation: location)
            let bytes = try encoder.encode(record)
            guard data.count + bytes.count + 3 <= PreparedNameExport.maximumBytes else { throw NameExportFailure.tooLarge }
            if count > 0 { data.append(0x2c) }; data.append(bytes); count += 1
        }
        guard count > 0 else { throw NameExportFailure.empty }
        data.append(contentsOf: [0x5d, 0x7d]); return (data, count)
    }
}

/// Deliberately publishes a newly created export directly. There are no hidden
/// plaintext staging files to rediscover, resume or clean after a process crash.
private enum NameExportFile {
    static func write(_ data: Data, records: Int, to url: URL, cancellation: RememberedNameCancellation,
                      probe: NameExportProbe?) -> NameExportOutcome {
        var created = false
        do {
            try probe?(.admitted)
            guard url.isFileURL, url.path == url.standardizedFileURL.path, !url.path.utf8.contains(0),
                  !url.lastPathComponent.isEmpty, url.path != "/", url.lastPathComponent.utf8.count <= 255,
                  !AutomaticMetadataPolicy.excludes(url),
                  !url.pathComponents.contains(where: { ["CloudStorage", "Mobile Documents", "FileProvider", ".Trash", ".Trashes"].contains($0)
                      || $0.hasSuffix(".icloud") || $0.lowercased().hasPrefix(".mac-explorer-recovery-") }) else {
                throw NameExportFailure.invalidDestination
            }
            let parentURL = url.deletingLastPathComponent()
            let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
            guard parent >= 0 else { throw failure(errno) }; defer { Darwin.close(parent) }
            let parentID = try identity(parent, directory: true)
            var fs = statfs()
            guard fstatfs(parent, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NameExportFailure.unsupportedDestination }
            let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard type == "apfs" else { throw NameExportFailure.unsupportedDestination }
            let metadata = try parentURL.resourceValues(forKeys: [.isUbiquitousItemKey])
            guard metadata.isUbiquitousItem != true else { throw NameExportFailure.unsupportedDestination }
            try probe?(.beforeCreate)
            try checkCancellation(cancellation)
            try verifyParent(parentURL, parentID)
            let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw failure(errno) }; created = true
            defer { Darwin.close(fd) }
            let fileID = try identity(fd, directory: false)
            try probe?(.created)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkCancellation(cancellation); try probe?(.writing)
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw failure(errno) }; offset += count
                }
            }
            try probe?(.written)
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw NameExportFailure.synchronizationFailed }
            guard try identity(fd, directory: false) == fileID else { throw NameExportFailure.destinationChanged }
            var entry = stat()
            guard fstatat(parent, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(entry) == fileID, entry.st_size == data.count else { throw NameExportFailure.destinationChanged }
            try verifyParent(parentURL, parentID)
            guard fsync(parent) == 0 else { throw NameExportFailure.synchronizationFailed }
            try probe?(.synchronized)
            return .saved(bytes: data.count, records: records)
        } catch {
            let reason = (error as? NameExportFailure) ?? .writeFailed
            return created ? .createdButIncomplete(reason) : .notCreated(reason)
        }
    }
    private struct Identity: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32, birth: Int, nanos: Int
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino; generation = info.st_gen; birth = info.st_birthtimespec.tv_sec; nanos = info.st_birthtimespec.tv_nsec }
    }
    private static func identity(_ fd: Int32, directory: Bool) throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NameExportFailure.destinationChanged }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), info.st_uid == geteuid(),
              directory || info.st_nlink == 1 && info.st_mode & 0o777 == 0o600 else { throw NameExportFailure.invalidDestination }
        if !directory {
            errno = 0
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?; errno = 0
                guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw NameExportFailure.invalidDestination }
            } else if errno != ENOENT { throw NameExportFailure.invalidDestination }
        }
        return Identity(info)
    }
    private static func verifyParent(_ url: URL, _ expected: Identity) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw NameExportFailure.destinationChanged }; defer { Darwin.close(fd) }
        guard try identity(fd, directory: true) == expected else { throw NameExportFailure.destinationChanged }
    }
    private static func checkCancellation(_ value: RememberedNameCancellation) throws {
        guard !value.isCancelled, !Task.isCancelled else { throw NameExportFailure.cancelled }
    }
    private static func failure(_ code: Int32) -> NameExportFailure {
        switch code { case EEXIST: .alreadyExists; case EACCES, EPERM: .accessDenied; default: .writeFailed }
    }
}
