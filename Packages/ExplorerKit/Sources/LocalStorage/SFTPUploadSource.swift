import CryptoKit
import Darwin
import Foundation

enum SFTPUploadSourceFailure: Error, Sendable, Equatable { case unavailable, unsupported, unsupportedMetadata, changed, stopped, busy }

struct UploadSourceAccessHooks: Sendable {
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
}
private final class UploadSourceAccess: @unchecked Sendable {
    private let url: URL, hooks: UploadSourceAccessHooks, active: Bool
    init(_ url: URL, hooks: UploadSourceAccessHooks) { self.url = url; self.hooks = hooks; active = hooks.start(url) }
    deinit { if active { hooks.stop(url) } }
}

struct SFTPUploadSourceSnapshot: Sendable, Equatable, Codable, CustomDebugStringConvertible {
    let id: UUID, name: String
    let observation: PinnedLocalFileSource.Stamp
    var logicalBytes: UInt64 { UInt64(observation.size) }
    var debugDescription: String { "<SFTP explicit local source>" }
    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("/"), !name.utf8.contains(0),
              observation.size >= 0, observation.size <= SFTPUploadSource.maximumFileBytes,
              observation.mode & S_IFMT == S_IFREG, observation.flags & UInt32(SF_DATALESS) == 0 else {
            throw SFTPUploadSourceFailure.unsupported
        }
    }
}

/// Pinned source for one explicit request. Nothing reads on the main actor;
/// no URL/descriptor escapes after admission. Read cancellation and close wait
/// the actual serial executor, rather than abandoning a still-running pread.
final class SFTPUploadSource: @unchecked Sendable {
    static let maximumFileBytes: Int64 = 1 << 30
    let snapshot: SFTPUploadSourceSnapshot
    private let executor: UploadLocalExecutor
    private let cancellation: UploadCancellation
    private let state = NSLock()
    private let readProbe: (@Sendable () throws -> Void)?
    private final class Storage: @unchecked Sendable {
        var source: PinnedLocalFileSource?
        var access: UploadSourceAccess?
        var editedLease: DownloadPublicationLease?
        var editedSnapshot: SFTPEditedTextSnapshot?
        init(_ source: PinnedLocalFileSource, access: UploadSourceAccess?) { self.source = source; self.access = access }
        func close() {
            source = nil; access = nil
            editedLease?.release(); editedLease = nil
            editedSnapshot?.sourceEndedAfterDrain(); editedSnapshot = nil
        }
    }
    private let storage: Storage
    private var source: PinnedLocalFileSource? { get { storage.source } set { storage.source = newValue } }
    private var offset: UInt64 = 0, failed = false
    private var hash = SHA256(), digest: Data?
    private let expectedEditedDigest: Data?
    private init(source: PinnedLocalFileSource, access: UploadSourceAccess?, executor: UploadLocalExecutor,
                 readProbe: (@Sendable () throws -> Void)?, edited: SFTPEditedTextSnapshot? = nil,
                 lease: DownloadPublicationLease? = nil, digest: Data? = nil) throws {
        var filesystem = statfs()
        guard fstatfs(source.descriptor, &filesystem) == 0 else { throw SFTPUploadSourceFailure.unavailable }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        guard type == "apfs" else { throw SFTPUploadSourceFailure.unsupported }
        // The initial SFTP lane transfers one data fork, not an AppleDouble or
        // resource-fork bundle. Refuse a nonempty extra fork before body reads.
        errno = 0
        let forkSize = fgetxattr(source.descriptor, "com.apple.ResourceFork", nil, 0, 0, 0)
        if forkSize > 0 { throw SFTPUploadSourceFailure.unsupportedMetadata }
        guard forkSize == 0 || errno == ENOATTR else { throw SFTPUploadSourceFailure.unavailable }
        try source.validate()
        snapshot = .init(id: UUID(), name: edited?.uploadSourceName ?? source.url.lastPathComponent,
            observation: source.observed)
        try snapshot.validate(); storage = Storage(source, access: access); self.executor = executor; self.readProbe = readProbe
        storage.editedSnapshot = edited; storage.editedLease = lease
        cancellation = edited?.cancellation ?? UploadCancellation(); expectedEditedDigest = digest
    }
    deinit { let held = storage; executor.enqueueDrain { held.close() } }
    static func prepare(_ edited: SFTPEditedTextSnapshot, readProbe: (@Sendable () throws -> Void)? = nil) async throws -> SFTPUploadSource {
        let executor = UploadLocalExecutor(label: "MacExplorer.SFTP.Upload.EditedSource")
        let (value, late) = try await executor.perform {
            let (pinned, lease, digest) = try edited.claimPinnedSource()
            do { return try SFTPUploadSource(source: pinned, access: nil, executor: executor,
                readProbe: readProbe, edited: edited, lease: lease, digest: digest) }
            catch { lease.release(); edited.sourceEndedAfterDrain(); throw error }
        }
        if late || Task.isCancelled { await value.drain(); throw SFTPUploadSourceFailure.stopped }; return value
    }
    static func prepare(_ url: URL, excluding roots: [URL], readProbe: (@Sendable () throws -> Void)? = nil,
                        accessHooks: UploadSourceAccessHooks = .init()) async throws -> SFTPUploadSource {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/"),
              url.path == url.standardizedFileURL.path, !url.path.utf8.contains(0), url.query == nil, url.fragment == nil,
              roots.allSatisfy({ $0.isFileURL && $0.query == nil && $0.fragment == nil && $0.path.hasPrefix("/") && $0.path == $0.standardizedFileURL.path }) else {
            throw SFTPUploadSourceFailure.unavailable
        }
        let executor = UploadLocalExecutor(label: "MacExplorer.SFTP.Upload.Source")
        let (value, late) = try await executor.perform { () throws -> SFTPUploadSource in
            do {
                let access = UploadSourceAccess(url, hooks: accessHooks)
                return try .init(source: PinnedLocalFileSource(url, excluding: roots), access: access, executor: executor, readProbe: readProbe)
            }
            catch let failure as SFTPUploadSourceFailure { throw failure }
            catch { throw SFTPUploadSourceFailure.unavailable }
        }
        if late || Task.isCancelled { await value.drain(); throw SFTPUploadSourceFailure.stopped }; return value
    }
    func read(offset requested: UInt64, maximum: Int = 32768) async throws -> Data {
        try await withTaskCancellationHandler {
            let (bytes, late) = try await executor.perform { [self] in try readOnSessionExecutor(offset: requested, maximum: maximum) }
            guard !late else { cancellation.cancel(); throw SFTPUploadSourceFailure.stopped }; return bytes
        } onCancel: { self.cancellation.cancel() }
    }
    /// The serial SFTP owner may feed an explicitly admitted source directly;
    /// the same lock serializes these reads with actual cancellation/drain.
    func readOnSessionExecutor(offset requested: UInt64, maximum: Int) throws -> Data {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        return try state.withLock {
            do {
                    try check(); guard !failed, digest == nil, let source, requested == offset, (1...32768).contains(maximum) else { throw SFTPUploadSourceFailure.changed }
                    try validateSource(source)
                    try readProbe?(); try check()
                    let count = min(maximum, Int(snapshot.logicalBytes - offset))
                    let bytes = try source.read(offset, count, maximum: 32768, check: { try self.check() })
                    try validateSource(source); try check()
                    hash.update(data: bytes); offset += UInt64(bytes.count); return bytes
            } catch {
                failed = true
                if let failure = error as? SFTPUploadSourceFailure { throw failure }
                throw SFTPUploadSourceFailure.changed
            }
        }
    }
    func finishReading() async throws -> Data {
        try await withTaskCancellationHandler {
          let (value, late) = try await executor.perform { [self] in try finishOnSessionExecutor() }
          guard !late else { cancellation.cancel(); throw SFTPUploadSourceFailure.stopped }; return value
        } onCancel: { self.cancellation.cancel() }
    }
    func finishOnSessionExecutor() throws -> Data {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        return try state.withLock {
            do {
                try check(); guard !failed, let source, offset == snapshot.logicalBytes else { throw SFTPUploadSourceFailure.changed }
                try validateSource(source); if let digest { return digest }
                let value = Data(hash.finalize())
                guard expectedEditedDigest == nil || expectedEditedDigest == value else { throw SFTPUploadSourceFailure.changed }
                digest = value; return value
            } catch {
                failed = true
                if let failure = error as? SFTPUploadSourceFailure { throw failure }
                throw SFTPUploadSourceFailure.changed
            }
        }
    }
    func validateEditedCreationOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        try state.withLock {
            try check()
            guard !failed, let source else { throw SFTPUploadSourceFailure.changed }
            try validateSource(source)
        }
    }
    private func validateSource(_ source: PinnedLocalFileSource) throws {
        try source.validate()
        if let lease = storage.editedLease {
            try lease.withSource(check: { try self.check() }) { _, _ in try source.validate() }
        }
    }
    private func check() throws { if cancellation.cancelled { throw SFTPUploadSourceFailure.stopped } }
    func requestStop() { cancellation.cancel() }
    func drain() async {
        requestStop()
        await executor.drain { [self] in state.withLock { storage.close() } }
    }
    func closeAfterDrainOnSessionExecutor() throws {
        guard !Thread.isMainThread else { throw SFTPUploadSourceFailure.busy }
        requestStop(); state.withLock { storage.close() }
    }
}

final class UploadCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
}

/// Concrete local-I/O executor shared only by this upload packet. Cancellation
/// never resumes before a queued operation actually returns. Writes report a
/// late cancellation alongside their real committed result.
final class UploadLocalExecutor: @unchecked Sendable {
    private let queue: DispatchQueue, lock = NSLock()
    private let identity = DispatchSpecificKey<Bool>()
    private var pending = 0
    init(label: String) { queue = DispatchQueue(label: label, qos: .utility); queue.setSpecific(key: identity, value: true) }
    func synchronously<T>(cleanup: Bool = false, _ work: () throws -> T) throws -> T {
        guard !Thread.isMainThread, DispatchQueue.getSpecific(key: identity) != true else { throw RemoteSettingsFailure.busy }
        try lock.withLock { guard cleanup || pending < 8 else { throw RemoteSettingsFailure.busy }; pending += 1 }
        defer { lock.withLock { pending -= 1 } }
        return try queue.sync(execute: work)
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> (T, Bool) {
        let request = UploadCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); guard pending < 8 else { lock.unlock(); continuation.resume(throwing: RemoteSettingsFailure.busy); return }; pending += 1
                queue.async { [self] in
                    let result: Result<T, Error> = request.cancelled ? .failure(SFTPUploadSourceFailure.stopped) : Result { try work() }
                    let late = request.cancelled; lock.withLock { pending -= 1 }; continuation.resume(with: result.map { ($0, late) })
                }; lock.unlock()
            }
        } onCancel: { request.cancel() }
    }
    func enqueueDrain(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
    func drain(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in queue.async { work(); continuation.resume() } }
    }
}
