import Darwin
import ExplorerCore
import Foundation

public struct DirectoryCompletionResult: Sendable {
    public let suggestions: [AddressSuggestion]
    public let observedEntries: Int
    public let isTruncated: Bool
    public let elapsed: TimeInterval
}

public struct DirectoryCompletionPolicy: Sendable {
    public let maximumEntries: Int
    public let maximumSeconds: TimeInterval
    public let maximumSuggestions: Int
    public init(maximumEntries: Int = 10_000, maximumSeconds: TimeInterval = 0.15, maximumSuggestions: Int = 8) {
        self.maximumEntries = min(20_000, max(1, maximumEntries))
        self.maximumSeconds = min(0.5, max(0.001, maximumSeconds))
        self.maximumSuggestions = min(12, max(1, maximumSuggestions))
    }
}

public final class DirectoryCompletionSession: Sendable {
    public let results: AsyncThrowingStream<DirectoryCompletionResult, Error>
    fileprivate let state: CompletionState
    fileprivate init() {
        let stream = AsyncThrowingStream<DirectoryCompletionResult, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = stream.stream; state = CompletionState(stream.continuation)
        let state = state
        stream.continuation.onTermination = { @Sendable _ in state.cancel() }
    }
    public func cancel() { state.cancel() }
}

private final class CompletionState: @unchecked Sendable {
    let lock = NSLock()
    private var stopped = false
    private let continuation: AsyncThrowingStream<DirectoryCompletionResult, Error>.Continuation
    init(_ continuation: AsyncThrowingStream<DirectoryCompletionResult, Error>.Continuation) { self.continuation = continuation }
    var isStopped: Bool { lock.withLock { stopped } }
    func check() throws { if isStopped { throw CancellationError() } }
    func cancel() {
        let finish = lock.withLock { if stopped { return false }; stopped = true; return true }
        if finish { continuation.finish(throwing: CancellationError()) }
    }
    func finish(_ result: Result<DirectoryCompletionResult, Error>) {
        let finish = lock.withLock { if stopped { return false }; stopped = true; return true }
        guard finish else { return }
        switch result {
        case .success(let value): continuation.yield(value); continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
    }
}

/// Two shared workers; one replaceable pending request per owner. No queue grows
/// per keystroke. Access/activity lifetimes outlive actual synchronous syscalls,
/// even after a consumer cancels. No recursion, body reads or persistent cache.
public final class DirectoryCompletionService: @unchecked Sendable {
    private enum Input: Sendable {
        case path(AddressCompletionRequest)
        case locations(FolderNameRequest, [FolderNameLocation])
    }
    private struct Work: Sendable {
        let owner: UUID
        let input: Input
        let policy: DirectoryCompletionPolicy
        let visits: [String: Int]
        let state: CompletionState
        let lifetime: (any Sendable)?
    }
    private let queue: OperationQueue
    private let lock = NSLock()
    private var pending: [UUID: Work] = [:]
    private var order: [UUID] = []
    private var active: [UUID: CompletionState] = [:]
    private var scheduled = 0
    private let activityGate: FileActivityGate?
    internal let beforeEnumeration: (@Sendable () -> Void)?
    internal let afterDirectoryOpened: (@Sendable () -> Void)?
    public convenience init(activityGate: FileActivityGate? = nil) { self.init(activityGate: activityGate, beforeEnumeration: nil) }
    internal init(activityGate: FileActivityGate?, beforeEnumeration: (@Sendable () -> Void)?, afterDirectoryOpened: (@Sendable () -> Void)? = nil) {
        self.activityGate = activityGate; self.beforeEnumeration = beforeEnumeration
        self.afterDirectoryOpened = afterDirectoryOpened
        queue = OperationQueue(); queue.name = "MacExplorer.AddressCompletion"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
    }
    internal var pendingCount: Int { lock.withLock { pending.count } }

    public func start(owner: UUID, request: AddressCompletionRequest, policy: DirectoryCompletionPolicy = .init(),
                      visits: [String: Int] = [:], retaining lifetime: (any Sendable)? = nil) -> DirectoryCompletionSession {
        enqueue(owner: owner, input: .path(request), policy: policy, visits: visits, lifetime: lifetime)
    }

    /// Validates a finite list of familiar folders/mounted roots. No enumeration
    /// of their children, recursive fallback or access based on saved history.
    public func startLocations(owner: UUID, request: FolderNameRequest, locations: [FolderNameLocation],
                               policy: DirectoryCompletionPolicy = .init(), visits: [String: Int] = [:],
                               retaining lifetime: (any Sendable)? = nil) -> DirectoryCompletionSession {
        enqueue(owner: owner, input: .locations(request, Array(locations.prefix(64))), policy: policy, visits: visits, lifetime: lifetime)
    }

    private func enqueue(owner: UUID, input: Input, policy: DirectoryCompletionPolicy, visits: [String: Int],
                         lifetime: (any Sendable)?) -> DirectoryCompletionSession {
        let session = DirectoryCompletionSession()
        lock.withLock {
            active[owner]?.cancel(); pending[owner]?.state.cancel()
            guard active[owner] != nil || pending[owner] != nil || active.count + pending.count < 8 else {
                session.state.finish(.failure(LocalStorageError.busy)); return
            }
            if pending[owner] == nil { order.append(owner) }
            pending[owner] = Work(owner: owner, input: input, policy: policy, visits: visits, state: session.state, lifetime: lifetime)
            if scheduled < 2 { scheduled += 1; queue.addOperation { [self] in drain() } }
        }
        return session
    }
    private func drain() {
        while let work = lock.withLock({ () -> Work? in
            guard let owner = order.first else { scheduled -= 1; return nil }
            // A previous request for this owner can still be unwinding in the
            // other worker. Cancellation keeps publication stale-safe.
            order.removeFirst()
            guard let work = pending.removeValue(forKey: owner) else { return nil }
            active[owner] = work.state; return work
        }) {
            withExtendedLifetime(work.lifetime) {
                do {
                    try work.state.check()
                    let lease = try activityGate?.begin()
                    defer { withExtendedLifetime(lease) {} }
                    beforeEnumeration?()
                    let value = try Self.read(work, afterDirectoryOpened: afterDirectoryOpened)
                    work.state.finish(.success(value))
                } catch { work.state.finish(.failure(error)) }
            }
            lock.withLock { if active[work.owner] === work.state { active.removeValue(forKey: work.owner) } }
        }
    }

    private static func read(_ work: Work, afterDirectoryOpened: (@Sendable () -> Void)?) throws -> DirectoryCompletionResult {
        switch work.input {
        case .path(let request): return try readPath(work, request: request, afterDirectoryOpened: afterDirectoryOpened)
        case .locations(let request, let locations): return try readLocations(work, request: request, locations: locations)
        }
    }
    private static func readLocations(_ work: Work, request: FolderNameRequest, locations: [FolderNameLocation]) throws -> DirectoryCompletionResult {
        let began = ProcessInfo.processInfo.systemUptime
        var ranking = FolderNameSuggestionRanking(request: request, limit: work.policy.maximumSuggestions, visits: work.visits)
        var observed = 0, truncated = false
        for location in locations {
            try work.state.check()
            if observed >= work.policy.maximumEntries || ProcessInfo.processInfo.systemUptime - began >= work.policy.maximumSeconds {
                truncated = true; break
            }
            guard request.match(location.name) != nil, location.url.isFileURL,
                  location.url.standardizedFileURL.path == location.url.path,
                  !AutomaticMetadataPolicy.excludes(location.url) else { continue }
            observed += 1
            do {
                let fd = try openParent(location.url, state: work.state)
                defer { close(fd) }
                var value = stat(), current = stat()
                guard fstat(fd, &value) == 0, lstat(location.url.path, &current) == 0,
                      value.st_dev == current.st_dev, value.st_ino == current.st_ino,
                      path(of: fd) == location.url.path,
                      request.showsHidden || value.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                ranking.consider(location)
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // A hint can be absent, denied or unavailable.
        }
        try work.state.check()
        return DirectoryCompletionResult(suggestions: ranking.suggestions, observedEntries: observed,
            isTruncated: truncated, elapsed: ProcessInfo.processInfo.systemUptime - began)
    }
    private static func readPath(_ work: Work, request: AddressCompletionRequest,
                                 afterDirectoryOpened: (@Sendable () -> Void)?) throws -> DirectoryCompletionResult {
        let start = ProcessInfo.processInfo.systemUptime
        try work.state.check()
        // Check provider/package boundaries before opening each explicit parent.
        // Opening never follows aliases/symlinks or materializes cloud contents.
        let fd = try openParent(request.parent, state: work.state)
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0 else { throw storageError(errno: errno) }
        afterDirectoryOpened?()
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw storageError(errno: errno) }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw storageError(errno: errno) }
        defer { closedir(directory) }
        var ranking = AddressSuggestionRanking(request: request, limit: work.policy.maximumSuggestions, visits: work.visits)
        var count = 0, truncated = false
        while true {
            try work.state.check()
            if count >= work.policy.maximumEntries || ProcessInfo.processInfo.systemUptime - start >= work.policy.maximumSeconds {
                truncated = true; break
            }
            errno = 0
            guard let item = readdir(directory) else {
                guard errno == 0 else { throw storageError(errno: errno) }; break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard request.showsHidden || !name.hasPrefix("."), item.pointee.d_type == DT_DIR || item.pointee.d_type == DT_UNKNOWN else { continue }
            guard !AutomaticMetadataPolicy.excludesComponent(name) else { continue }
            guard ranking.couldEnterResults(directoryName: name) else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0,
                  request.showsHidden || info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            let child = request.parent.appendingPathComponent(name, isDirectory: true)
            let values = try child.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
            guard values.isPackage != true, values.isUbiquitousItem != true else { continue }
            ranking.consider(directoryName: name)
        }
        try work.state.check()
        var final = stat(), current = stat()
        guard fstat(fd, &final) == 0, lstat(request.parent.path, &current) == 0,
              initial.st_dev == current.st_dev, initial.st_ino == current.st_ino,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec, initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              path(of: fd) == request.parent.path else { throw LocalStorageError.unavailable }
        return DirectoryCompletionResult(suggestions: ranking.suggestions, observedEntries: count,
                                         isTruncated: truncated, elapsed: ProcessInfo.processInfo.systemUptime - start)
    }
    private static func openParent(_ url: URL, state: CompletionState) throws -> Int32 {
        guard !AutomaticMetadataPolicy.excludes(url) else { throw LocalStorageError.unavailable }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw storageError(errno: errno) }
        do {
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            for component in url.pathComponents.dropFirst() {
                try state.check()
                current.appendPathComponent(component, isDirectory: true)
                var observed = stat()
                guard fstatat(fd, component, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw storageError(errno: errno) }
                guard observed.st_mode & S_IFMT == S_IFDIR, observed.st_flags & UInt32(SF_DATALESS) == 0 else { throw LocalStorageError.unavailable }
                let values = try current.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
                guard values.isPackage != true, values.isUbiquitousItem != true else { throw LocalStorageError.unavailable }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw storageError(errno: errno) }
                var actual = stat()
                guard fstat(next, &actual) == 0, actual.st_dev == observed.st_dev, actual.st_ino == observed.st_ino,
                      path(of: next) == current.path else { close(next); throw LocalStorageError.unavailable }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func path(of fd: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private static func storageError(errno code: Int32) -> LocalStorageError {
        switch code {
        case EACCES, EPERM: .accessDenied
        case ENOENT: .notFound
        case ENOTDIR: .notDirectory
        default: .unavailable
        }
    }
}
