import Darwin
import Foundation

/// One descriptor-only child lifecycle, shared by bounded and paged analysis.
/// The owner retains access/activity until actual reaping and both pipe EOFs.
enum ScannerWorkerProcess {
    #if DEBUG
    private final class TraversalLaunchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    private static let traversalLaunches = TraversalLaunchCounter()
    static var qualificationTraversalLaunchCount: Int { traversalLaunches.value }
    #endif
    /// Fixed Apple topology inquiries only. The caller owns the argument
    /// allowlist; this pump never logs tool data or runs a shell.
    static func collect(pipes: (stdout: Int32, stderr: Int32), control: ScannerProcessControl,
                        maximumBytes: Int = 4 << 20, deadline: TimeInterval = 5) throws -> Data {
        defer { close(pipes.stdout); close(pipes.stderr) }
        let began = ProcessInfo.processInfo.systemUptime
        var outputOpen = true, errorOpen = true, status: Int32?, rejected = false
        var output = Data(), errorCount = 0
        while outputOpen || errorOpen || status == nil {
            if ProcessInfo.processInfo.systemUptime - began > deadline { rejected = true; control.cancel() }
            control.escalateIfNeeded()
            if status == nil { status = control.reapIfExited() }
            if !outputOpen && !errorOpen && status != nil { break }
            var descriptors = [pollfd(fd: outputOpen ? pipes.stdout : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorOpen ? pipes.stderr : -1, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 && errno != EINTR { rejected = true; control.cancel() }
            for index in 0..<2 where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                var bytes = [UInt8](repeating: 0, count: 16 << 10)
                let count = read(descriptors[index].fd, &bytes, bytes.count)
                if count == 0 { if index == 0 { outputOpen = false } else { errorOpen = false }; continue }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    rejected = true; control.cancel()
                    if index == 0 { outputOpen = false } else { errorOpen = false }; continue
                }
                guard !rejected else { continue }
                if output.count + errorCount + count > maximumBytes { rejected = true; control.cancel(); continue }
                if index == 0 { output.append(contentsOf: bytes.prefix(count)) } else { errorCount += count }
            }
        }
        guard !rejected, !control.cancelled, status == 0, errorCount == 0 else { throw StartupStorageFailure.unavailable }
        return output
    }
    static func launch(workerURL: URL, descriptors: [(Int32, Int32)], arguments: [String],
                       control: ScannerProcessControl) throws -> (stdout: Int32, stderr: Int32) {
        // Normalize every handed descriptor before ordered child remapping.
        var copies: [(Int32, Int32)] = []
        defer { copies.forEach { close($0.1) } }
        let targets = Set(descriptors.map(\.0))
        let startup = arguments.first == "--startup-result"
        let refresh = arguments.first == "--refresh-result"
        guard targets.count == descriptors.count,
              startup || refresh ? targets == Set([3, 4, 5, 6, 7, 8]) : targets.allSatisfy({ (3...6).contains($0) }) else { throw StorageScanFailure.workerUnavailable }
        for (target, descriptor) in descriptors {
            guard descriptor >= 0 else { throw StorageScanFailure.workerUnavailable }
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw StorageScanFailure.workerUnavailable }
            copies.append((target, copy))
        }
        var standard = [Int32](repeating: -1, count: 2), errors = standard
        guard pipe(&standard) == 0 else { throw StorageScanFailure.workerUnavailable }
        guard pipe(&errors) == 0 else { close(standard[0]); close(standard[1]); throw StorageScanFailure.workerUnavailable }
        var keepReads = false
        defer {
            close(standard[1]); close(errors[1])
            if !keepReads { close(standard[0]); close(errors[0]) }
        }
        // Never let a source descriptor alias child targets0...3: another host
        // can legitimately start with stdout/stderr closed. Remap all four
        // endpoints before constructing ordered spawn file actions.
        for index in 0..<2 {
            let safe = fcntl(standard[index], F_DUPFD_CLOEXEC, 10)
            guard safe >= 0 else { throw StorageScanFailure.workerUnavailable }
            close(standard[index]); standard[index] = safe
            let safeError = fcntl(errors[index], F_DUPFD_CLOEXEC, 10)
            guard safeError >= 0 else { throw StorageScanFailure.workerUnavailable }
            close(errors[index]); errors[index] = safeError
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw StorageScanFailure.workerUnavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw StorageScanFailure.workerUnavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var signalMask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&signalMask) == 0,
              sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0, sigaddset(&defaults, SIGINT) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, standard[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0 else { throw StorageScanFailure.workerUnavailable }
        for (target, descriptor) in copies {
            guard posix_spawn_file_actions_adddup2(&actions, descriptor, target) == 0 else { throw StorageScanFailure.workerUnavailable }
        }
        let workerMode = arguments.first
        let arguments = [workerURL.path] + arguments
        var argv = arguments.map { strdup($0) } + [nil]
        var env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { if let value = $0 { free(value) } }; env.forEach { if let value = $0 { free(value) } } }
        guard !argv.dropLast().contains(where: { $0 == nil }), !env.dropLast().contains(where: { $0 == nil }),
              !control.cancelled else { throw CancellationError() }
        var pid: pid_t = 0
        let result = workerURL.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&pid, $0, &actions, &attributes, &argv, &env) } ?? EINVAL
        }
        guard result == 0 else { throw StorageScanFailure.workerUnavailable }
        #if DEBUG
        if workerMode == "--full-result" || workerMode == "--startup-result" || workerMode == "--refresh-result" {
            traversalLaunches.add()
        }
        #endif
        control.attach(pid)
        keepReads = true
        return (standard[0], errors[0])
    }

    /// A synchronous utility-worker pump. Payloads are bounded and never logged.
    /// Rejecting a frame cancels the owned child but continues draining/reaping.
    static func drain(pipes: (stdout: Int32, stderr: Int32), control: ScannerProcessControl,
                      deadline: TimeInterval? = nil, frame: (Data) throws -> Void) throws -> Int32 {
        defer { close(pipes.stdout); close(pipes.stderr) }
        let began = ProcessInfo.processInfo.systemUptime
        var outputOpen = true, errorsOpen = true, status: Int32?, failure: Error?
        var buffer = Data(), stderrCount = 0
        while outputOpen || errorsOpen || status == nil {
            if let deadline, ProcessInfo.processInfo.systemUptime - began > deadline {
                failure = StorageScanFailure.workerFailed; control.cancel()
            }
            control.escalateIfNeeded()
            if status == nil { status = control.reapIfExited() }
            if !outputOpen && !errorsOpen && status != nil { break }
            var descriptors = [pollfd(fd: outputOpen ? pipes.stdout : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorsOpen ? pipes.stderr : -1, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 && errno != EINTR { failure = StorageScanFailure.workerFailed; control.cancel() }
            for index in 0..<2 where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                var bytes = [UInt8](repeating: 0, count: 16 << 10)
                let count = read(descriptors[index].fd, &bytes, bytes.count)
                if count == 0 { if index == 0 { outputOpen = false } else { errorsOpen = false }; continue }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    failure = StorageScanFailure.workerFailed; control.cancel()
                    if index == 0 { outputOpen = false } else { errorsOpen = false }; continue
                }
                if index == 1 {
                    stderrCount += count
                    if stderrCount > 64 << 10 { failure = StorageScanFailure.invalidOutput; control.cancel() }
                    continue
                }
                guard failure == nil else { continue }
                do {
                    try autoreleasepool {
                        var offset = 0
                        while offset < count {
                            let newline = bytes[offset..<count].firstIndex(of: 10), end = newline ?? count
                            guard buffer.count + end - offset < 65536 else { throw StorageScanFailure.invalidOutput }
                            buffer.append(contentsOf: bytes[offset..<end]); offset = end + (newline == nil ? 0 : 1)
                            if newline != nil { try frame(buffer); buffer.removeAll(keepingCapacity: true) }
                        }
                    }
                } catch { failure = error; control.cancel() }
            }
        }
        if let failure { throw failure }
        guard buffer.isEmpty, stderrCount == 0, let status else { throw StorageScanFailure.invalidOutput }
        return status
    }
}
