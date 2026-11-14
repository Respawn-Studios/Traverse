import Darwin
import ExplorerCore
import Foundation

public struct ListingIssue: Sendable {
    public let message: String
    public let url: URL?

    public init(message: String, url: URL? = nil) {
        self.message = message
        self.url = url
    }
}

public enum ListingEvent: Sendable {
    case batch([FileEntry])
    case finished(issues: [ListingIssue])
}

public enum VolumeKind: String, Sendable {
    case internalDisk, externalDisk, network, unknown
}

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let kind: VolumeKind
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let isReadOnly: Bool?

    public init(url: URL, name: String, kind: VolumeKind, totalBytes: Int64? = nil,
                availableBytes: Int64? = nil, isReadOnly: Bool? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
    }
}

public enum LocalStorageError: Error, Sendable {
    case accessDenied, notFound, notDirectory, unavailable, busy, other(String)

    public var userMessage: String {
        switch self {
        case .accessDenied: "Access to this location was denied."
        case .notFound: "This location could not be found."
        case .notDirectory: "This location is not a folder."
        case .unavailable: "This location is currently unavailable."
        case .busy: "Location inspection is busy. Wait for the current checks to finish, then try again."
        case .other: "This location could not be read."
        }
    }
}

/// Reads shallow directory names and resource metadata only. No content reads, writes,
/// recursion or requests to download ubiquitous items are performed. Listed symbolic-link
/// entries are not followed; an explicitly provided root can contain symlink ancestors.
/// All blocking work runs on this instance's bounded worker queue.
public final class LocalFileSystem: @unchecked Sendable {
    private let queue: OperationQueue
    private let batchSize: Int
    private let activityGate: FileActivityGate?
    internal static let maximumNearestLocationRequests = 8
    private let nearestReadLock = NSLock()
    private var nearestReadCount = 0
    internal var nearestLocationOutstandingCount: Int { nearestReadLock.withLock { nearestReadCount } }

    public init(batchSize: Int = 256, maximumConcurrentReads: Int = 2, activityGate: FileActivityGate? = nil) {
        self.batchSize = max(1, batchSize)
        self.activityGate = activityGate
        queue = OperationQueue()
        queue.name = "MacExplorer.LocalStorage"
        queue.maxConcurrentOperationCount = max(1, maximumConcurrentReads)
        queue.qualityOfService = .userInitiated
    }

    /// Retains a caller-supplied access lease through actual filesystem-worker
    /// completion, including after the consumer cancels its stream.
    public func entries(in url: URL, showHidden: Bool = false, retaining lifetime: (any Sendable)? = nil,
                        didDrain: (@Sendable () -> Void)? = nil) -> AsyncThrowingStream<ListingEvent, Error> {
        let batchSize = batchSize
        let activityGate = activityGate
        return AsyncThrowingStream { continuation in
            let cancellation = ReadCancellation()
            let operation = BlockOperation {
                defer { withExtendedLifetime(lifetime) {} }
                do {
                    let activity = try activityGate?.begin()
                    defer { withExtendedLifetime(activity) {} }
                    try Self.enumerate(url, showHidden: showHidden, batchSize: batchSize,
                                       cancellation: cancellation, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Completion also runs for a cancelled queued operation. Consumers
            // can coalesce new demand until actual worker/lease completion,
            // rather than mistaking stream cancellation for an I/O drain.
            operation.completionBlock = didDrain
            continuation.onTermination = { @Sendable _ in
                cancellation.cancel()
                // A cancelled queued operation never begins filesystem work.
                operation.cancel()
            }
            queue.addOperation(operation)
        }
    }

    public func volumes() async throws -> [VolumeInfo] {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    do {
                        try cancellation.check()
                        let activity = try self.activityGate?.begin()
                        defer { withExtendedLifetime(activity) {} }
                        let keys: Set<URLResourceKey> = [
                            .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey,
                        ]
                        guard let urls = FileManager().mountedVolumeURLs(
                            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
                        ) else { throw LocalStorageError.unavailable }
                        var result: [VolumeInfo] = []
                        for url in urls {
                            try cancellation.check()
                            // A disconnected or inaccessible mount remains visible with unknown facts.
                            let values: URLResourceValues
                            do { values = try url.resourceValues(forKeys: keys) }
                            catch {
                                result.append(VolumeInfo(url: url, name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                                                         kind: .unknown))
                                continue
                            }
                            let kind: VolumeKind
                            if values.volumeIsLocal == false { kind = .network }
                            else if values.volumeIsInternal == true { kind = .internalDisk }
                            else if values.volumeIsLocal == true && values.volumeIsInternal == false { kind = .externalDisk }
                            else { kind = .unknown }
                            result.append(VolumeInfo(
                                url: url, name: values.volumeName ?? url.lastPathComponent,
                                kind: kind, totalBytes: values.volumeTotalCapacity.map(Int64.init),
                                availableBytes: values.volumeAvailableCapacity.map(Int64.init),
                                isReadOnly: values.volumeIsReadOnly
                            ))
                        }
                        try cancellation.check()
                        continuation.resume(returning: result.sorted { $0.url.path < $1.url.path })
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Finds the reported entry or its nearest existing ancestor with at most
    /// 64 metadata-only probes. The final entry's symlink is not followed.
    /// Denied/disconnected observations throw instead of claiming absence.
    /// Cancellation never frees a worker slot or access lease before a blocked
    /// probe has returned; canceled queued requests perform no filesystem read.
    public func nearestExistingLocation(to url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> URL? {
        try await nearestExistingLocation(to: url, retaining: lifetime, afterProbe: nil, didEnqueue: nil)
    }

    /// Reserve bounded admission before acquiring access. The exact resulting
    /// lifetime transfers to the worker and remains held through actual drain.
    public func nearestExistingLocation(to url: URL,
        acquiring lifetime: @Sendable () async throws -> (any Sendable)?) async throws -> URL? {
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        try reserveNearestRead()
        let retained: (any Sendable)?
        do {
            try Task.checkCancellation()
            retained = try await lifetime()
            try Task.checkCancellation()
        } catch { releaseNearestRead(); throw error }
        return try await enqueueNearestRead(to: url, retaining: retained, afterProbe: nil, didEnqueue: nil)
    }

    // Gates surround actual metadata observations in focused worker-drain tests.
    internal func nearestExistingLocation(to url: URL, retaining lifetime: (any Sendable)?,
                                          afterProbe: (@Sendable (URL) -> Void)?,
                                          didEnqueue: (@Sendable () -> Void)?) async throws -> URL? {
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        try reserveNearestRead()
        return try await enqueueNearestRead(to: url, retaining: lifetime, afterProbe: afterProbe, didEnqueue: didEnqueue)
    }

    private func reserveNearestRead() throws {
        try nearestReadLock.withLock {
            guard nearestReadCount < Self.maximumNearestLocationRequests else { throw LocalStorageError.busy }
            nearestReadCount += 1
        }
    }
    private func releaseNearestRead() { nearestReadLock.withLock { nearestReadCount -= 1 } }

    private func enqueueNearestRead(to url: URL, retaining lifetime: (any Sendable)?,
                                    afterProbe: (@Sendable (URL) -> Void)?,
                                    didEnqueue: (@Sendable () -> Void)?) async throws -> URL? {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    defer { withExtendedLifetime(lifetime) {}; self.releaseNearestRead() }
                    do {
                        try cancellation.check()
                        let activity = try self.activityGate?.begin()
                        defer { withExtendedLifetime(activity) {} }
                        guard url.isFileURL else { throw LocalStorageError.unavailable }
                        var candidate = url
                        for _ in 0..<64 {
                            try cancellation.check()
                            var observation = stat()
                            let (status, failure) = candidate.withUnsafeFileSystemRepresentation { pointer -> (Int32, Int32) in
                                guard let pointer else { return (-1, EINVAL) }
                                let status = lstat(pointer, &observation)
                                return (status, errno)
                            }
                            afterProbe?(candidate)
                            try cancellation.check()
                            if status == 0 {
                                // Deleting a URL component adds a directory hint,
                                // even when the existing ancestor is a regular file.
                                let isDirectory = observation.st_mode & S_IFMT == S_IFDIR
                                let result = candidate.hasDirectoryPath == isDirectory ? candidate
                                    : URL(fileURLWithPath: candidate.path, isDirectory: isDirectory)
                                continuation.resume(returning: result)
                                return
                            }
                            guard failure == ENOENT || failure == ENOTDIR else { throw Self.storageError(errno: failure) }
                            let parent = candidate.deletingLastPathComponent()
                            if parent == candidate { continuation.resume(returning: nil); return }
                            candidate = parent
                        }
                        try cancellation.check()
                        continuation.resume(returning: nil)
                    } catch { continuation.resume(throwing: error) }
                }
                didEnqueue?()
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func enumerate(
        _ url: URL, showHidden: Bool, batchSize: Int, cancellation: ReadCancellation,
        continuation: AsyncThrowingStream<ListingEvent, Error>.Continuation
    ) throws {
        try cancellation.check()
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        let directory = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.flatMap { opendir($0) }
        }
        guard let directory else { throw storageError(errno: errno) }
        defer { closedir(directory) }
        var batch: [FileEntry] = []
        var issues: [ListingIssue] = []
        var omittedIssues = 0
        func recordIssue(_ entryURL: URL) {
            // Avoid unbounded diagnostics and never include the user's path in message text.
            if issues.count < 100 {
                issues.append(ListingIssue(message: "Some metadata could not be read for this item.", url: entryURL))
            } else { omittedIssues += 1 }
        }
        while true {
            try cancellation.check()
            errno = 0
            guard let item = readdir(directory) else {
                let failure = errno
                if failure != 0 { throw storageError(errno: failure) }
                break
            }
            let name: String = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
            let entryURL = url.appendingPathComponent(name)
            var observation = stat()
            let status = entryURL.withUnsafeFileSystemRepresentation { pointer in
                pointer.map { lstat($0, &observation) } ?? -1
            }
            var kind: FileKind = .other
            var byteCount: Int64?
            var modifiedAt: Date?
            var createdAt: Date?
            var accessedAt: Date?
            if status == 0 {
                if !showHidden && observation.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let mode = observation.st_mode & S_IFMT
                if mode == S_IFLNK {
                    // lstat observes the link itself; never ask Foundation for target metadata.
                    kind = .symbolicLink
                } else if mode == S_IFDIR { kind = .directory }
                else if mode == S_IFREG { kind = .file }
                if kind == .file || kind == .symbolicLink { byteCount = Int64(observation.st_size) }
                modifiedAt = Date(timeIntervalSince1970: Double(observation.st_mtimespec.tv_sec)
                    + Double(observation.st_mtimespec.tv_nsec) / 1_000_000_000)
                createdAt = observedCreationDate(observation.st_birthtimespec)
                accessedAt = Date(timeIntervalSince1970: Double(observation.st_atimespec.tv_sec)
                    + Double(observation.st_atimespec.tv_nsec) / 1_000_000_000)
                if kind != .symbolicLink {
                    do {
                        // Package and Finder-hidden flags need public URL resource metadata.
                        let values = try entryURL.resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
                        if !showHidden && values.isHidden == true { continue }
                        if kind == .directory && values.isPackage == true { kind = .package }
                    } catch { recordIssue(entryURL) }
                }
            } else { recordIssue(entryURL) }
            try cancellation.check()
            batch.append(FileEntry(url: entryURL, name: name, kind: kind,
                                   byteCount: byteCount, modifiedAt: modifiedAt,
                                   createdAt: createdAt, accessedAt: accessedAt))
            if batch.count >= batchSize {
                if case .terminated = continuation.yield(.batch(batch)) { return }
                batch.removeAll(keepingCapacity: true)
            }
        }
        try cancellation.check()
        if !batch.isEmpty, case .terminated = continuation.yield(.batch(batch)) { return }
        if omittedIssues > 0 {
            issues.append(ListingIssue(message: "Metadata was unavailable for additional items."))
        }
        continuation.yield(.finished(issues: issues))
    }

    private static func storageError(errno code: Int32) -> LocalStorageError {
        switch code {
        case EACCES, EPERM: .accessDenied
        case ENOENT: .notFound
        case ENOTDIR: .notDirectory
        case ENODEV, ENXIO, ESTALE, ENOTCONN, ETIMEDOUT, EIO: .unavailable
        default: .other("Filesystem metadata read failed.")
        }
    }

    private static func storageError(_ error: Error) -> LocalStorageError {
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain { return storageError(errno: Int32(cocoa.code)) }
        switch cocoa.code {
        case NSFileReadNoPermissionError: return .accessDenied
        case NSFileReadNoSuchFileError: return .notFound
        default: return .unavailable
        }
    }
}

/// Some filesystems report an all-zero birth time when creation metadata is unavailable.
/// Negative seconds and positive subsecond values at the Unix epoch remain valid dates.
internal func observedCreationDate(_ time: timespec) -> Date? {
    guard time.tv_nsec >= 0, time.tv_nsec < 1_000_000_000,
          time.tv_sec != 0 || time.tv_nsec != 0 else { return nil }
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
}

private final class ReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
