import Darwin
import ExplorerCore
import Foundation
import FileOperations

public enum RememberedReferenceAvailability: String, Sendable, Equatable {
    case available, unavailable, accessNeeded, needsRelink, needsReconciliation, accessRemoved, unsupported
}

public enum RememberedReferenceFailure: Error, Sendable, Equatable {
    case unsupported, unavailable, accessNeeded, changed, stale, capacity, cancelled, followingRequired
    case alreadyRemembered(RememberedItemID)
}

/// Stored evidence is not mutation authority. No source body is read or mapped
/// by this adapter. Original-object operation proofs remain independent.
internal struct NativeDocumentReference: Codable, Sendable, Equatable {
    enum Kind: Int, Codable, Sendable { case file, folder }
    enum Scope: Int, Codable, Sendable { case locatorOnly, readOnly }
    let version: Int
    let kind: Kind
    let scope: Scope
    let volume: UUID
    let document: UInt32
    let path: String
    let bookmark: Data

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 131_072 else { throw RememberedReferenceFailure.capacity }
        return data
    }
    init(kind: Kind, scope: Scope, volume: UUID, document: UInt32, path: String, bookmark: Data) throws {
        version = 1; self.kind = kind; self.scope = scope; self.volume = volume
        self.document = document; self.path = path; self.bookmark = bookmark
        try validate()
    }
    init(data: Data) throws {
        do {
            guard data.count <= 131_072 else { throw NameStoreFailure.unsafe }
            self = try JSONDecoder().decode(Self.self, from: data)
            guard try encoded() == data else { throw NameStoreFailure.unsafe }
        } catch { throw NameStoreFailure.unsafe }
    }
    private func validate() throws {
        guard version == 1, document > 0, !bookmark.isEmpty, bookmark.count <= 65_536,
              path.utf8.count <= 8_192, path.hasPrefix("/"), !path.utf8.contains(0),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw NameStoreFailure.unsafe }
    }
}

internal struct NativeReferenceObservation: Sendable {
    let reference: NativeDocumentReference
    let url: URL
    let stale: Bool
}

internal struct NativeDocumentIdentity: Sendable {
    let volume: UUID
    let document: UInt32
}

/// Two actual native workers, independent of the catalog actor. Cancellation
/// suppresses results but never frees admission, activity or scope before return.
internal final class NativeDocumentReferenceReader: @unchecked Sendable {
    private let queue: OperationQueue
    private let lock = NSLock()
    private var pending = 0
    private let activity: FileActivityGate?
    internal var qualificationHold: (@Sendable () -> Void)?

    init(activity: FileActivityGate?) {
        self.activity = activity
        queue = OperationQueue(); queue.name = "MacExplorer.PrivateReferences"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
    }
    func capture(_ url: URL, scope: NativeDocumentReference.Scope = .locatorOnly, allowDocumentFollowing: Bool = false,
                 moveSource: MoveReferenceTicket? = nil, movedObject: MoveReferenceEvidence? = nil,
                 cancellation: RememberedNameCancellation) async throws -> NativeReferenceObservation {
        try await run(cancellation) {
            try Self.policy(url)
            let started = scope == .readOnly && url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try Self.coordinated(url) { candidate in
                // Volume roots are not ordinary remembered documents. Refuse
                // before any optional tracking metadata can be changed.
                guard try candidate.resourceValues(forKeys: [.isVolumeKey]).isVolume != true else {
                    throw RememberedReferenceFailure.unsupported
                }
                let original = try Anchor(candidate)
                defer { original.close() }
                try moveSource?.validateSourceDescriptor(original.fd, at: candidate)
                try movedObject?.validateDescriptor(original.fd, at: candidate)
                let evidence: (kind: NativeDocumentReference.Kind, volume: UUID, document: UInt32)
                do { evidence = try original.evidence(candidate) }
                catch RememberedReferenceFailure.followingRequired where allowDocumentFollowing {
                    try Self.enableFollowing(original, url: candidate)
                    evidence = try original.evidence(candidate)
                }
                let options: URL.BookmarkCreationOptions = scope == .readOnly
                    ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.withoutImplicitSecurityScope]
                let bookmark = try candidate.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                try original.verify(candidate)
                try moveSource?.validateSourceDescriptor(original.fd, at: candidate)
                try movedObject?.validateDescriptor(original.fd, at: candidate)
                let stored = try NativeDocumentReference(kind: evidence.kind, scope: scope, volume: evidence.volume,
                    document: evidence.document, path: candidate.path, bookmark: bookmark)
                let resolved = try Self.resolveSynchronously(stored)
                guard resolved.reference.volume == evidence.volume, resolved.reference.document == evidence.document,
                      resolved.reference.kind == evidence.kind else { throw RememberedReferenceFailure.changed }
                try original.verify(candidate)
                // Native bookmarks may add the directory URL's trailing slash.
                // Exact path plus the pinned object/parent is authoritative.
                guard (moveSource == nil && movedObject == nil) || resolved.url.path == candidate.path else {
                    throw RememberedReferenceFailure.changed
                }
                try moveSource?.validateSourceDescriptor(original.fd, at: candidate)
                try movedObject?.validateDescriptor(original.fd, at: candidate)
                return resolved
            }
        }
    }
    func resolve(_ stored: NativeDocumentReference, cancellation: RememberedNameCancellation) async throws -> NativeReferenceObservation {
        try await run(cancellation) { try Self.resolveSynchronously(stored) }
    }

    /// Observe an existing exact file without making a bookmark or enabling
    /// document following. A missing document ID means this object is not
    /// tracked; it never turns an access or integrity error into absence.
    func currentIdentity(_ url: URL, cancellation: RememberedNameCancellation) async throws -> NativeDocumentIdentity? {
        try await run(cancellation) {
            try Self.bindingObservationPolicy(url)
            return try Self.coordinated(url) { candidate in
                guard candidate.standardizedFileURL.path == url.standardizedFileURL.path else {
                    throw RememberedReferenceFailure.changed
                }
                try Self.bindingObservationPolicy(candidate)
                let anchor = try Anchor(candidate)
                defer { anchor.close() }
                guard anchor.original.st_mode & S_IFMT == S_IFREG else { throw RememberedReferenceFailure.unsupported }
                do {
                    let evidence = try anchor.evidence(candidate)
                    return NativeDocumentIdentity(volume: evidence.volume, document: evidence.document)
                } catch RememberedReferenceFailure.followingRequired {
                    try anchor.verify(candidate)
                    return nil
                }
            }
        }
    }

    final class Access: @unchecked Sendable {
        let observation: NativeReferenceObservation
        let scopedURL: URL
        let started: Bool
        init(_ observation: NativeReferenceObservation, scopedURL: URL, started: Bool) {
            self.observation = observation; self.scopedURL = scopedURL; self.started = started
        }
    }
    func access(_ stored: NativeDocumentReference, cancellation: RememberedNameCancellation) async throws -> Access {
        // Admission cancellation is checked before creation. Once a scope is
        // returned it must reach the caller for unconditional actual release.
        try await run(cancellation, checkAfter: false) {
            var stale = false
            let url = try URL(resolvingBookmarkData: stored.bookmark,
                options: stored.scope == .readOnly ? [.withSecurityScope, .withoutUI, .withoutMounting]
                    : [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            try Self.policy(url)
            let started = stored.scope == .readOnly && url.startAccessingSecurityScopedResource()
            do {
                let observed = try Self.resolveSynchronously(stored)
                return Access(observed, scopedURL: url, started: started)
            } catch { if started { url.stopAccessingSecurityScopedResource() }; throw error }
        }
    }
    func release(_ access: Access) async {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                if access.started { access.scopedURL.stopAccessingSecurityScopedResource() }
                continuation.resume()
            }
        }
    }

    /// Experimental explicit-Remember preparation only. The ordinary reader
    /// never calls this. It preserves existing flags and refuses foreign owners,
    /// hardlinks, unsupported kinds/volumes, redirects and changed entries.
    func qualificationEnableTracking(_ url: URL, cancellation: RememberedNameCancellation) async throws {
        try await run(cancellation) {
            try Self.policy(url)
            let anchor = try Anchor(url); defer { anchor.close() }
            try Self.enableFollowing(anchor, url: url)
            _ = try anchor.evidence(url)
        }
    }

    private static func enableFollowing(_ anchor: Anchor, url: URL) throws {
        guard anchor.original.st_uid == geteuid(),
              anchor.original.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { throw RememberedReferenceFailure.unsupported }
        try anchor.verifyAPFS()
        (url as NSURL).removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isUbiquitousItemKey])
        guard values.isAliasFile != true, values.isUbiquitousItem != true else { throw RememberedReferenceFailure.unsupported }
        try anchor.verify(url)
        guard fchflags(anchor.fd, anchor.original.st_flags | UInt32(UF_TRACKED)) == 0 else { throw failure(errno) }
        try anchor.verify(url)
    }

    private func run<T: Sendable>(_ cancellation: RememberedNameCancellation, checkAfter: Bool = true,
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try lock.withLock {
            guard pending < 64 else { throw RememberedReferenceFailure.capacity }; pending += 1
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    let result: Result<T, Error> = Result {
                        defer { self.lock.withLock { self.pending -= 1 } }
                        guard !cancellation.isCancelled else { throw RememberedReferenceFailure.cancelled }
                        let activity = try self.activity?.begin()
                        defer { withExtendedLifetime(activity) {} }
                        self.qualificationHold?()
                        guard !cancellation.isCancelled else { throw RememberedReferenceFailure.cancelled }
                        let result = try autoreleasepool(invoking: work)
                        guard !checkAfter || !cancellation.isCancelled else { throw RememberedReferenceFailure.cancelled }
                        return result
                    }
                    continuation.resume(with: result.mapError { Self.classify($0) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func resolveSynchronously(_ stored: NativeDocumentReference) throws -> NativeReferenceObservation {
        var stale = false
        let options: URL.BookmarkResolutionOptions = stored.scope == .readOnly
            ? [.withSecurityScope, .withoutUI, .withoutMounting]
            : [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
        let url: URL
        do { url = try URL(resolvingBookmarkData: stored.bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw error is CancellationError ? RememberedReferenceFailure.cancelled : classify(error) }
        try policy(url)
        let started = stored.scope == .readOnly && url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try coordinated(url) { candidate in
            let anchor = try Anchor(candidate); defer { anchor.close() }
            let evidence = try anchor.evidence(candidate)
            guard evidence.volume == stored.volume, evidence.document == stored.document, evidence.kind == stored.kind else {
                throw RememberedReferenceFailure.changed
            }
            try anchor.verify(candidate)
            // Keep original bookmark until a separately admitted refresh commits.
            let observed = try NativeDocumentReference(kind: stored.kind, scope: stored.scope, volume: stored.volume,
                document: stored.document, path: candidate.path, bookmark: stored.bookmark)
            return NativeReferenceObservation(reference: observed, url: candidate, stale: stale)
        }
    }
    private static func coordinated<T>(_ url: URL, _ work: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges, .immediatelyAvailableMetadataOnly], error: &error) { candidate in
            result = Result { try work(candidate) }
        }
        if let result { return try result.get() }
        if let error { throw classify(error) }
        throw RememberedReferenceFailure.unavailable
    }
    private static func policy(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !AutomaticMetadataPolicy.excludes(url),
              !url.pathComponents.contains(where: { $0.lowercased().hasPrefix(".mac-explorer-recovery-") }),
              !url.pathComponents.contains(where: { [".Trash", ".Trashes", "CloudStorage", "Mobile Documents", "FileProvider"].contains($0) }),
              !url.pathComponents.contains(where: { $0.hasSuffix(".icloud") }) else { throw RememberedReferenceFailure.unsupported }
        let parts = url.pathComponents
        for pair in zip(parts, parts.dropFirst()) where pair.0 == "Library" && ["Mail", "Messages", "Safari"].contains(pair.1) {
            throw RememberedReferenceFailure.unsupported
        }
    }
    private static func bindingObservationPolicy(_ url: URL) throws {
        guard url.isFileURL, url.path.utf8.count <= 8_192,
              url.standardizedFileURL.path == url.path else { throw RememberedReferenceFailure.unsupported }
        let parent = url.deletingLastPathComponent()
        let area = parent.lastPathComponent
        if ["displaced", "payload"].contains(url.lastPathComponent),
           area.hasPrefix(".mac-explorer-recovery-"),
           UUID(uuidString: String(area.dropFirst(".mac-explorer-recovery-".count))) != nil {
            try policy(parent.deletingLastPathComponent())
        } else {
            try policy(url)
        }
    }
    static func classify(_ error: Error) -> RememberedReferenceFailure {
        if let value = error as? RememberedReferenceFailure { return value }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return failure(Int32(value.code)) }
        if value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError { return .accessNeeded }
        return .unavailable
    }
    private static func failure(_ code: Int32) -> RememberedReferenceFailure {
        if code == EACCES || code == EPERM { return .accessNeeded }
        if code == ELOOP || code == EMLINK || code == ENOTSUP { return .unsupported }
        return .unavailable
    }

    private final class Anchor {
        let fd: Int32
        let original: stat
        init(_ url: URL) throws {
            fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw failure(errno) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw failure(errno) }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG && info.st_nlink == 1 else {
                Darwin.close(fd); throw RememberedReferenceFailure.unsupported
            }
            original = info
        }
        func close() { Darwin.close(fd) }
        func verifyAPFS() throws {
            var fs = statfs()
            guard fstatfs(fd, &fs) == 0 else { throw failure(errno) }
            let kind = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard kind == "apfs" else { throw RememberedReferenceFailure.unsupported }
        }
        func verify(_ url: URL) throws {
            let fresh = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
            guard fresh >= 0 else { throw RememberedReferenceFailure.changed }
            defer { Darwin.close(fresh) }
            var info = stat()
            guard fstat(fresh, &info) == 0, info.st_dev == original.st_dev, info.st_ino == original.st_ino,
                  info.st_gen == original.st_gen,
                  info.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec,
                  info.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec,
                  info.st_mode & S_IFMT == original.st_mode & S_IFMT,
                  info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1 else { throw RememberedReferenceFailure.changed }
        }
        func evidence(_ url: URL) throws -> (kind: NativeDocumentReference.Kind, volume: UUID, document: UInt32) {
            try verifyAPFS(); try verify(url)
            (url as NSURL).removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .isAliasFileKey, .isUbiquitousItemKey])
            guard values.isAliasFile != true, values.isUbiquitousItem != true,
                  let text = values.volumeUUIDString, let volume = UUID(uuidString: text) else { throw RememberedReferenceFailure.unsupported }
            var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_DOCUMENT_ID)
            var buffer = [UInt8](repeating: 0, count: 64)
            guard fgetattrlist(fd, &attributes, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { throw failure(errno) }
            func word(_ at: Int) -> UInt32 { buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
            guard word(0) == 28, word(4) & UInt32(ATTR_CMN_DOCUMENT_ID) != 0 else {
                throw RememberedReferenceFailure.unsupported
            }
            guard word(24) != 0 else { throw RememberedReferenceFailure.followingRequired }
            try verify(url)
            return (original.st_mode & S_IFMT == S_IFDIR ? .folder : .file, volume, word(24))
        }
    }
}
