import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Security

@_spi(Qualification) public struct SMBCatalogDrainResult: Sendable {
    public let actualExit: Bool
    public let pipeDrained: Bool
    public let catalogClosed: Bool
    public let forcedContainment: Bool
    public let ownerReleased: Bool
}

/// The generated producer qualifies the real native result interface without
/// admitting a remote endpoint.
@_spi(Qualification) public final class SMBGeneratedCatalogSession: Sendable {
    private let owner: CatalogOwner
    public let snapshots: AsyncStream<SMBDirectorySnapshot>
    public var snapshot: SMBDirectorySnapshot? { owner.latest }
    public var failure: SMBDirectoryFailure? { owner.failure }
    private init(owner: CatalogOwner) { self.owner = owner; snapshots = owner.events.stream }
    public static func start(bundleURL: URL, generatedCase: URL, activity: FileActivityGate) async throws -> SMBGeneratedCatalogSession {
        let owner = CatalogOwner(bundle: bundleURL, root: generatedCase, activity: activity)
        try CatalogAdmission.shared.admit(owner)
        let session = SMBGeneratedCatalogSession(owner: owner)
        try await withTaskCancellationHandler {
            if Task.isCancelled { owner.stop() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                owner.start(continuation)
            }
        } onCancel: { owner.stop() }
        if Task.isCancelled { _ = await session.close(); throw SMBDirectoryFailure.stopped }
        return session
    }
    public func find(_ query: RemoteDirectoryFindQuery) async throws -> SMBDirectoryFindResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { owner.find(query, continuation: $0) }
        } onCancel: { owner.stop() }
    }
    public func page(offset: Int64, sort: SMBDirectorySort = .name, descending: Bool = false,
                     find: SMBDirectoryFindResult? = nil) async throws -> SMBDirectoryPage {
        try await withTaskCancellationHandler {
            if Task.isCancelled { throw SMBDirectoryFailure.stopped }
            return try await withCheckedThrowingContinuation { continuation in
                owner.page(offset: offset, sort: sort, descending: descending, find: find, continuation: continuation)
            }
        } onCancel: { owner.stop() }
    }
    public func close() async -> SMBCatalogDrainResult {
        owner.stop()
        return await withCheckedContinuation { owner.wait($0) }
    }
}

private final class CatalogAdmission: @unchecked Sendable {
    static let shared = CatalogAdmission()
    private let lock = NSLock()
    private var owner: CatalogOwner?
    func admit(_ value: CatalogOwner) throws { try lock.withLock { guard owner == nil else { throw SMBDirectoryFailure.busy }; owner = value } }
    func release(_ value: CatalogOwner) { lock.withLock { if owner === value { owner = nil } } }
}
private final class CatalogOwner: @unchecked Sendable {
    let events = AsyncStream.makeStream(of: SMBDirectorySnapshot.self, bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock(), queue = DispatchQueue(label: "MacExplorer.SMB.CatalogQualification", qos: .userInitiated)
    private let bundle: URL, root: URL, activity: FileActivityGate
    private let session = UUID(), read = UUID()
    private var decoder: SMBDirectoryCatalogDecoder
    private var descriptor: Int32 = -1, directory: Int32 = -1, database: Int32 = -1, leaseFD: Int32 = -1
    private var child: pid_t = 0, status: Int32?
    private var buffer = Data(), eof = false, contained = false, helloSent = false
    private var stopAt: TimeInterval?, problem: SMBDirectoryFailure?
    private var lease: FileActivityGate.Lease?
    private var ready: CheckedContinuation<Void, Error>?
    private var waiting: [CheckedContinuation<SMBCatalogDrainResult, Never>] = []
    private var result: SMBCatalogDrainResult?
    private var current: SMBDirectorySnapshot?
    private var queued: (SMBDirectoryPageRequest, CheckedContinuation<SMBDirectoryPage, Error>)?
    private var pending: CheckedContinuation<SMBDirectoryPage, Error>?
    private var queuedFind: (SMBDirectoryFindRequest, CheckedContinuation<SMBDirectoryFindResult, Error>)?
    private var pendingFind: CheckedContinuation<SMBDirectoryFindResult, Error>?
    var latest: SMBDirectorySnapshot? { lock.withLock { current } }
    var failure: SMBDirectoryFailure? { lock.withLock { problem } }
    init(bundle: URL, root: URL, activity: FileActivityGate) {
        self.bundle = bundle; self.root = root; self.activity = activity
        decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
    }
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        ready = continuation; queue.async { self.run() }
    }
    func stop(_ issue: SMBDirectoryFailure = .stopped) {
        lock.withLock {
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime; problem = issue }
            if descriptor >= 0, helloSent { var byte: UInt8 = 83; _ = Darwin.send(descriptor, &byte, 1, MSG_DONTWAIT) }
        }
    }
    func find(_ query: RemoteDirectoryFindQuery, continuation: CheckedContinuation<SMBDirectoryFindResult, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil else { throw SMBDirectoryFailure.stopped }
            guard queued == nil, pending == nil, queuedFind == nil, pendingFind == nil else { throw SMBDirectoryFailure.busy }
            guard let current else { throw RemoteDirectoryFindFailure.stale }
            queuedFind = (.init(query: query, snapshot: current), continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func page(offset: Int64, sort: SMBDirectorySort, descending: Bool, find: SMBDirectoryFindResult?, continuation: CheckedContinuation<SMBDirectoryPage, Error>) {
        do {
            try lock.withLock {
                guard stopAt == nil, result == nil else { throw SMBDirectoryFailure.stopped }
                guard queued == nil, pending == nil, queuedFind == nil, pendingFind == nil else { throw SMBDirectoryFailure.busy }
                guard let current else { throw SMBDirectoryFailure.unavailable }
                let request = try SMBDirectoryPageRequest(snapshot: current, offset: offset, sort: sort, descending: descending, find: find)
                queued = (request, continuation)
            }
        } catch { continuation.resume(throwing: error) }
    }
    func wait(_ continuation: CheckedContinuation<SMBCatalogDrainResult, Never>) {
        let result: SMBCatalogDrainResult? = lock.withLock { if let result { return result }; waiting.append(continuation); return nil }
        if let result { continuation.resume(returning: result) }
    }
    private func run() {
        do { try launch() } catch {
            stop(error as? SMBDirectoryFailure ?? .unavailable)
            lock.withLock { if descriptor >= 0, !helloSent { _ = shutdown(descriptor, SHUT_WR) } }
        }
        let began = ProcessInfo.processInfo.systemUptime
        while child > 0, status == nil || !eof {
            let now = ProcessInfo.processInfo.systemUptime
            if now - began > 30, lock.withLock({ stopAt == nil }) { stop(.unavailable) } // This generated run only.
            if let at = lock.withLock({ stopAt }) {
                if now - at > 0.5, status == nil, !contained { contained = true; _ = kill(child, SIGTERM) }
                if now - at > 1.25, status == nil { _ = kill(child, SIGKILL) }
                if now - at > 3 { contained = true; break }
            }
            if status == nil {
                var value: Int32 = 0; let found = waitpid(child, &value, WNOHANG)
                if found == child { status = value }
                else if found < 0, errno != EINTR { stop(.containment); contained = true; break }
            }
            do { try sendQueued(); if !eof { try receive() } else if status == nil { _ = poll(nil, 0, 10) } }
            catch { stop(error as? SMBDirectoryFailure ?? .invalidOutput) }
        }
        let drained = child == 0 || status != nil && eof
        let complete = decoder.closed && status == 0 && !contained && buffer.isEmpty
        let outcome = SMBCatalogDrainResult(actualExit: child > 0 && status != nil, pipeDrained: eof,
            catalogClosed: complete, forcedContainment: contained, ownerReleased: drained)
        let inFlight = lock.withLock {
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime }
            let values = (queued, pending, queuedFind, pendingFind); queued = nil; pending = nil; queuedFind = nil; pendingFind = nil
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }; return values
        }
        if drained {
            for fd in [directory, database, leaseFD] where fd >= 0 { Darwin.close(fd) }
            directory = -1; database = -1; leaseFD = -1; lease = nil; CatalogAdmission.shared.release(self)
        }
        let failure = lock.withLock { problem } ?? .unavailable
        ready?.resume(throwing: failure); ready = nil
        inFlight.0?.1.resume(throwing: failure); inFlight.1?.resume(throwing: failure)
        inFlight.2?.1.resume(throwing: failure); inFlight.3?.resume(throwing: failure)
        events.continuation.finish()
        // A late close waiter must not receive ownerReleased until the actual
        // descriptors, activity lease and admission above have been released.
        let waiters = lock.withLock { result = outcome; let values = waiting; waiting = []; return values }
        waiters.forEach { $0.resume(returning: outcome) }
    }
    private func sendQueued() throws {
        let find = lock.withLock { () -> (SMBDirectoryFindRequest, CheckedContinuation<SMBDirectoryFindResult, Error>)? in
            guard pending == nil, pendingFind == nil, let value = queuedFind, stopAt == nil else { return nil }
            queuedFind = nil; pendingFind = value.1; return value
        }
        if let find {
            do { try decoder.request(find.0) }
            catch { lock.withLock { pendingFind = nil }; find.1.resume(throwing: error); return }
            do { try write(find.0.command) }
            catch { lock.withLock { pendingFind = nil }; find.1.resume(throwing: error); throw error }
        }
        let request = lock.withLock { () -> (SMBDirectoryPageRequest, CheckedContinuation<SMBDirectoryPage, Error>)? in
            guard pending == nil, pendingFind == nil, let value = queued, stopAt == nil else { return nil }
            queued = nil; pending = value.1; return value
        }
        guard let request else { return }
        do { try decoder.request(request.0) }
        catch { lock.withLock { pending = nil }; request.1.resume(throwing: error); return }
        do { try write(request.0.command) }
        catch { lock.withLock { pending = nil }; request.1.resume(throwing: error); throw error }
    }
    private func receive() throws {
        var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let available = poll(&fd, 1, 10)
        if available < 0 { if errno == EINTR { return }; throw SMBDirectoryFailure.unavailable }
        guard available > 0 else { return }
        var data = [UInt8](repeating: 0, count: 32768)
        let count = Darwin.read(descriptor, &data, data.count)
        if count == 0 { eof = true; return }
        if count < 0 { if errno == EAGAIN || errno == EINTR { return }; throw SMBDirectoryFailure.unavailable }
        #if DEBUG
        SFTPGeneratedBackendObservation.shared.protocolTransferred()
        #endif
        for byte in data.prefix(count) {
            if byte == 10 {
                let event = try decoder.consume(buffer); buffer.removeAll(keepingCapacity: true)
                switch event {
                case .snapshot(let snapshot):
                    lock.withLock { current = snapshot }; events.continuation.yield(snapshot)
                    if snapshot.count > 0 || snapshot.state != .loading, let ready { self.ready = nil; ready.resume() }
                case .page(let page):
                    let continuation = lock.withLock { let value = pending; pending = nil; return value }
                    if lock.withLock({ stopAt == nil }) { continuation?.resume(returning: page) }
                    else { continuation?.resume(throwing: SMBDirectoryFailure.stopped) }
                case .found(let result):
                    let continuation = lock.withLock { let value = pendingFind; pendingFind = nil; return value }
                    if lock.withLock({ stopAt == nil }) { continuation?.resume(returning: result) }
                    else { continuation?.resume(throwing: SMBDirectoryFailure.stopped) }
                case .stale:
                    let continuation = lock.withLock { let value = pending; pending = nil; return value }
                    continuation?.resume(throwing: SMBDirectoryFailure.stale)
                case .findStale:
                    let continuation = lock.withLock { let value = pendingFind; pendingFind = nil; return value }
                    continuation?.resume(throwing: RemoteDirectoryFindFailure.stale)
                case .queryUnavailable:
                    let continuations = lock.withLock { let values = (pending, pendingFind); pending = nil; pendingFind = nil; return values }
                    continuations.0?.resume(throwing: RemoteDirectoryFindFailure.unavailable)
                    continuations.1?.resume(throwing: RemoteDirectoryFindFailure.unavailable)
                case .closed(let reason):
                    if reason != "stopped", reason != "complete" { stop(reason == "quota" ? .quota : .storage) }
                case nil: break
                }
            } else { guard buffer.count < 16512 else { throw SMBDirectoryFailure.invalidOutput }; buffer.append(byte) }
        }
    }
    private func write(_ text: String) throws {
        let data = Data(text.utf8); let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var sent = 0
        while sent < data.count {
            guard lock.withLock({ stopAt == nil }), ProcessInfo.processInfo.systemUptime < deadline else { throw SMBDirectoryFailure.stopped }
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: sent), $0.count - sent, MSG_DONTWAIT) }
            if count > 0 {
                sent += count
                #if DEBUG
                SFTPGeneratedBackendObservation.shared.protocolTransferred()
                #endif
            }
            else if count < 0, errno == EAGAIN || errno == EINTR { var fd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0); _ = poll(&fd, 1, 10) }
            else { throw SMBDirectoryFailure.unavailable }
        }
    }
    private func launch() throws {
        #if DEBUG
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        guard lock.withLock({ stopAt == nil }) else { throw SMBDirectoryFailure.stopped }
        lease = try activity.begin()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-browser-qualification"), root.resolvingSymlinksInPath() == root,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { throw SMBDirectoryFailure.invalidInput }
        let helper = bundle.appendingPathComponent("Contents/Helpers/smb-catalog-worker")
        let info = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard info.count < 65536, let properties = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let expected = properties["MacExplorerSMBCatalogQualificationSHA256"] as? String, expected.count == 64 else { throw SMBDirectoryFailure.unavailable }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw SMBDirectoryFailure.unavailable }
        let binary = Darwin.open(helper.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard binary >= 0 else { throw SMBDirectoryFailure.unavailable }; defer { Darwin.close(binary) }
        var facts = stat(); guard fstat(binary, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1,
              facts.st_size > 0, facts.st_size < 4 << 20 else { throw SMBDirectoryFailure.unavailable }
        var source = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(binary, &bytes, bytes.count); guard count >= 0 else { throw SMBDirectoryFailure.unavailable }
            if count == 0 { break }; source.append(contentsOf: bytes.prefix(count)); guard source.count < 4 << 20 else { throw SMBDirectoryFailure.unavailable }
        }
        guard SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == expected else { throw SMBDirectoryFailure.unavailable }
        let folder = root.appendingPathComponent("stores/native")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard directory >= 0 else { throw SMBDirectoryFailure.storage }
        database = openat(directory, "catalog.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        leaseFD = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard database >= 0, leaseFD >= 0, flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else { throw SMBDirectoryFailure.storage }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SMBDirectoryFailure.unavailable }
        defer { for fd in pair where fd >= 0 { Darwin.close(fd) } }
        var copies: [Int32] = []
        defer { copies.forEach { Darwin.close($0) } }
        for fd in [pair[1], directory, database, leaseFD] {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 32); guard copy >= 0 else { throw SMBDirectoryFailure.unavailable }; copies.append(copy)
        }
        for fd in pair { var one: Int32 = 1; guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SMBDirectoryFailure.unavailable } }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SMBDirectoryFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SMBDirectoryFailure.unavailable }; defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SMBDirectoryFailure.unavailable }; defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0,
              sigaddset(&defaults, SIGTERM) == 0, sigaddset(&defaults, SIGINT) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0 else { throw SMBDirectoryFailure.unavailable }
        for (index, target) in [STDIN_FILENO, 4, 5, 6].enumerated() {
            guard posix_spawn_file_actions_adddup2(&actions, copies[index], target) == 0 else { throw SMBDirectoryFailure.unavailable }
        }
        for fd in [STDOUT_FILENO, STDERR_FILENO] { guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_WRONLY, 0) == 0 else { throw SMBDirectoryFailure.unavailable } }
        var argv = [strdup(helper.path), strdup("--ipc-catalog"), nil], env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        guard !argv.dropLast().contains(where: { $0 == nil }), !env.dropLast().contains(where: { $0 == nil }) else { throw SMBDirectoryFailure.unavailable }
        let result = posix_spawn(&child, helper.path, &actions, &attributes, &argv, &env)
        guard result == 0 else { child = 0; throw SMBDirectoryFailure.unavailable }
        lock.withLock { descriptor = pair[0] }; pair[0] = -1
        let encoded = Data(folder.appendingPathComponent("catalog.sqlite").path.utf8).map { String(format: "%02x", $0) }.joined()
        try write("MEXSMBC1 START \(session.uuidString) \(read.uuidString) \(encoded)\n")
        lock.withLock { helloSent = true }
        if lock.withLock({ stopAt != nil }) { stop() }
    }
}
