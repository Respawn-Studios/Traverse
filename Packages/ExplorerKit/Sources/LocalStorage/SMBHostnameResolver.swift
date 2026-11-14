import Darwin
#if !SMB_RESOLVER_STANDALONE
import ExplorerCore
#endif
import Foundation

@_spi(Qualification) public enum SMBResolverMode: String, Sendable {
    case native, empty = "test-empty", blockedSubmission = "test-blocked-submit"
    case nullError = "test-null-error", overflow = "test-overflow", scoped = "test-scope", removed = "test-remove"
}
@_spi(Qualification) public struct SMBResolverLifetime: Sendable {
    public let childStarted: Bool
    public let actualExit: Bool
    public let pipeDrained: Bool
    public let forcedContainment: Bool
    public let ownerReleased: Bool
    public let lookupStarted: Bool
    public let callbackCount: Int
    public let submittedNativeQuery: Bool
    public let deallocatedNativeReference: Bool
}
@_spi(Qualification) public struct SMBHostnameResult: Sendable {
    public let addresses: [SMBResolvedAddress]
    public let failure: SMBResolutionFailure?
    public let lifetime: SMBResolverLifetime
}

/// Credential-free DNS module. Preparation, native lookup and process drain
/// have separate lifetimes. The lookup deadline starts after child admission;
/// an OS signature/preparation call retains its owner until it actually returns.
@_spi(Qualification) public enum SMBHostnameResolver {
    public static func resolve(_ host: String, bundleURL: URL, activity: FileActivityGate,
        mode: SMBResolverMode = .native, lookupDeadline: TimeInterval = 10) async throws -> SMBHostnameResult {
        let host = host.lowercased()
        guard valid(host), (0.1...10).contains(lookupDeadline), mode == .native || host == "localhost" else {
            throw SMBResolutionFailure.invalidInput
        }
        let owner = ResolverOwner(host: host, bundle: bundleURL, activity: activity, mode: mode, deadline: lookupDeadline)
        try ResolverAdmission.shared.admit(owner)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                owner.queue.async { continuation.resume(returning: owner.run()) }
            }
        } onCancel: { owner.stop() }
        // Cancellation can arrive after the executor completed but before its
        // caller resumes. No candidate may be published in that late interval.
        if Task.isCancelled { return SMBHostnameResult(addresses: [], failure: .stopped, lifetime: result.lifetime) }
        return result
    }
    private static func valid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            (1...63).contains(part.utf8.count) && part.first != "-" && part.last != "-"
                && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

private final class ResolverAdmission: @unchecked Sendable {
    static let shared = ResolverAdmission()
    private let lock = NSLock()
    private var held: ResolverOwner?
    func admit(_ owner: ResolverOwner) throws {
        try lock.withLock { guard held == nil else { throw SMBResolutionFailure.busy }; held = owner }
    }
    func release(_ owner: ResolverOwner) { lock.withLock { if held === owner { held = nil } } }
}

private final class ResolverOwner: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacExplorer.SMB.Hostname", qos: .userInitiated)
    private let lock = NSLock()
    private let host: String, bundle: URL, activity: FileActivityGate, mode: SMBResolverMode, deadline: TimeInterval
    private let generation = UUID()
    private var descriptor: Int32 = -1
    private var child: pid_t = 0
    private var stopAt: TimeInterval?
    private var problem: SMBResolutionFailure?
    private var helloSent = false
    private var lease: FileActivityGate.Lease?
    private var contained = false
    private var exitStatus: Int32?
    private var eof = false
    private var buffer = Data()
    private var receivedBytes = 0
    private var decoder: SMBResolverDecoder

    init(host: String, bundle: URL, activity: FileActivityGate, mode: SMBResolverMode, deadline: TimeInterval) {
        self.host = host; self.bundle = bundle; self.activity = activity; self.mode = mode; self.deadline = deadline
        decoder = SMBResolverDecoder(generation: generation)
    }
    func stop(_ reason: SMBResolutionFailure = .stopped) {
        lock.withLock {
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime; problem = reason }
            if descriptor >= 0 && helloSent {
                var byte: UInt8 = 83; _ = Darwin.send(descriptor, &byte, 1, MSG_DONTWAIT)
            }
        }
    }
    func run() -> SMBHostnameResult {
        do { try launch() }
        catch {
            stop(error as? SMBResolutionFailure ?? .unavailable)
            lock.withLock { if descriptor >= 0 { _ = shutdown(descriptor, SHUT_WR) } }
        }
        let began = ProcessInfo.processInfo.systemUptime
        var drainBegan: TimeInterval?
        while child > 0 && (exitStatus == nil || !eof) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - began >= deadline && lock.withLock({ stopAt == nil }) { stop(.deadline) }
            let stopped = lock.withLock { stopAt }
            if stopped != nil {
                if drainBegan == nil { drainBegan = now }
                let elapsed = now - (drainBegan ?? now)
                if elapsed > 0.5 && exitStatus == nil && !contained { contained = true; _ = kill(child, SIGTERM) }
                if elapsed > 1.25 && exitStatus == nil { _ = kill(child, SIGKILL) }
                if elapsed > 3 { contained = true; break }
            }
            if exitStatus == nil {
                var status: Int32 = 0
                let found = waitpid(child, &status, WNOHANG)
                if found == child { exitStatus = status }
                else if found < 0 && errno != EINTR { stop(.containment); contained = true; break }
            }
            if !eof {
                do { try readAvailable() }
                catch { stop(error as? SMBResolutionFailure ?? .invalidOutput) }
            } else if exitStatus == nil { _ = poll(nil, 0, 20) }
            if exitStatus != nil && eof { break }
        }
        let terminal = decoder.terminal
        let drained = child == 0 || exitStatus != nil && eof
        lock.withLock { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        if drained { lease = nil; ResolverAdmission.shared.release(self) }
        let stopped = lock.withLock { problem }
        let failure: SMBResolutionFailure?
        if let stopped { failure = stopped }
        else if contained || !drained { failure = .containment }
        else if exitStatus != 0 || !buffer.isEmpty { failure = .workerExited }
        else {
            switch terminal?.outcome {
            case "resolved": failure = nil
            case "stopped": failure = .stopped
            case "deadline": failure = .deadline
            case "invalid-input": failure = .invalidInput
            case "limit", "invalid-address": failure = .invalidOutput
            default: failure = .unavailable
            }
        }
        let lifetime = SMBResolverLifetime(childStarted: child > 0, actualExit: exitStatus != nil,
            pipeDrained: eof, forcedContainment: contained, ownerReleased: drained,
            lookupStarted: decoder.started,
            callbackCount: terminal?.callbackCount ?? 0, submittedNativeQuery: terminal?.submitted ?? false,
            deallocatedNativeReference: terminal?.deallocated ?? false)
        return SMBHostnameResult(addresses: failure == nil ? terminal?.addresses ?? [] : [], failure: failure, lifetime: lifetime)
    }
    private func launch() throws {
        #if DEBUG && !SMB_RESOLVER_STANDALONE
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        guard lock.withLock({ stopAt == nil }) else { throw SMBResolutionFailure.stopped }
        lease = try activity.begin()
        let identity = try SMBBundledHelperIdentity.prepare(.resolver, bundle: bundle)
        try identity.validateInstallation()
        let helper = identity.helper
        guard lock.withLock({ stopAt == nil }) else { throw SMBResolutionFailure.stopped }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SMBResolutionFailure.unavailable }
        defer { if pair[0] >= 0 { Darwin.close(pair[0]) }; Darwin.close(pair[1]) }
        for index in 0..<2 {
            let copy = fcntl(pair[index], F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw SMBResolutionFailure.unavailable }
            Darwin.close(pair[index]); pair[index] = copy
            var one: Int32 = 1
            guard setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SMBResolutionFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SMBResolutionFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SMBResolutionFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SMBResolutionFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              sigaddset(&defaults, SIGINT) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { throw SMBResolutionFailure.unavailable }
        var argv = [strdup(helper.path), nil], env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        guard !argv.dropLast().contains(where: { $0 == nil }), !env.dropLast().contains(where: { $0 == nil }) else { throw SMBResolutionFailure.unavailable }
        let status = helper.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&child, $0, &actions, &attributes, &argv, &env) } ?? EINVAL
        }
        guard status == 0 else { child = 0; throw SMBResolutionFailure.unavailable }
        lock.withLock { descriptor = pair[0] }; pair[0] = -1
        try identity.validateChild(child)
        let encoded = Data(host.utf8).map({ String(format: "%02x", $0) }).joined()
        let hello = Data("MEXDNS1 START \(generation.uuidString) \(encoded) \(mode.rawValue)\n".utf8)
        try lock.withLock {
            guard stopAt == nil else { throw SMBResolutionFailure.stopped }
            let count = hello.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            #if DEBUG && !SMB_RESOLVER_STANDALONE
            if count > 0 { SFTPGeneratedBackendObservation.shared.protocolTransferred() }
            #endif
            guard count == hello.count else { throw SMBResolutionFailure.unavailable }
            helloSent = true
        }
    }
    private func readAvailable() throws {
        var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 20)
        if ready < 0 { if errno == EINTR { return }; throw SMBResolutionFailure.unavailable }
        guard ready > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(self.descriptor, &bytes, bytes.count)
        if count == 0 { eof = true; return }
        if count < 0 { if errno == EAGAIN || errno == EINTR { return }; throw SMBResolutionFailure.unavailable }
        #if DEBUG && !SMB_RESOLVER_STANDALONE
        SFTPGeneratedBackendObservation.shared.protocolTransferred()
        #endif
        receivedBytes += count
        guard receivedBytes <= 32768 else { throw SMBResolutionFailure.invalidOutput }
        for byte in bytes.prefix(count) {
            if byte == 10 { _ = try decoder.consume(buffer); buffer.removeAll(keepingCapacity: true) }
            else { guard buffer.count < 1024 else { throw SMBResolutionFailure.invalidOutput }; buffer.append(byte) }
        }
    }
}
