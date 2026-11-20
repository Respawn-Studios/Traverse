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
        var output = Data(), errorCount = 0
        do {
            let status = try pump(pipes: pipes, control: control, deadline: deadline) { stream, bytes in
                guard output.count + errorCount + bytes.count <= maximumBytes else { throw StartupStorageFailure.unavailable }
                if stream == .stdout { output.append(contentsOf: bytes) }
                else { errorCount += bytes.count }
            }
            guard !control.cancelled, status == 0, errorCount == 0 else { throw StartupStorageFailure.unavailable }
            return output
        } catch { throw StartupStorageFailure.unavailable }
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

    /// Parse bounded newline frames while the shared pump retains the child.
    /// `onPoll` permits a progress observation even when the worker is quiet.
    static func drain(pipes: (stdout: Int32, stderr: Int32), control: ScannerProcessControl,
                      deadline: TimeInterval? = nil, onPoll: () -> Void = {},
                      onRejected: (Error) -> Void = { _ in }, frame: (Data) throws -> Void) throws -> Int32 {
        var buffer = Data(), stderrCount = 0
        let status = try pump(pipes: pipes, control: control, deadline: deadline,
                              onPoll: onPoll, onRejected: onRejected) { stream, bytes in
            if stream == .stderr {
                stderrCount += bytes.count
                guard stderrCount <= 64 << 10 else { throw StorageScanFailure.invalidOutput }
                return // Diagnostic payloads are never retained.
            }
            try autoreleasepool {
                var offset = bytes.startIndex
                while offset < bytes.endIndex {
                    let newline = bytes[offset...].firstIndex(of: 10), end = newline ?? bytes.endIndex
                    guard buffer.count + end - offset < ScannerProtocolDecoder.maximumFrameBytes else {
                        throw StorageScanFailure.invalidOutput
                    }
                    buffer.append(contentsOf: bytes[offset..<end])
                    offset = end + (newline == nil ? 0 : 1)
                    if newline != nil { try frame(buffer); buffer.removeAll(keepingCapacity: true) }
                }
            }
        }
        guard buffer.isEmpty, stderrCount == 0 else { throw StorageScanFailure.invalidOutput }
        return status
    }

    private enum Stream { case stdout, stderr }

    /// A rejected record ends interpretation, while the actual child and both
    /// read ends continue draining. All scanner clients share that ownership.
    private static func pump(pipes: (stdout: Int32, stderr: Int32), control: ScannerProcessControl,
                             deadline: TimeInterval?, onPoll: () -> Void = {},
                             onRejected: (Error) -> Void = { _ in },
                             consume: (Stream, ArraySlice<UInt8>) throws -> Void) throws -> Int32 {
        defer { close(pipes.stdout); close(pipes.stderr) }
        let began = ProcessInfo.processInfo.systemUptime
        var descriptors = [pollfd(fd: pipes.stdout, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: pipes.stderr, events: Int16(POLLIN), revents: 0)]
        var bytes = [UInt8](repeating: 0, count: 16 << 10)
        var status: Int32?, failure: Error?
        func reject(_ error: Error) {
            guard failure == nil else { return }
            failure = error
            onRejected(error)
            control.cancel()
        }
        while true {
            if let deadline, ProcessInfo.processInfo.systemUptime - began > deadline {
                reject(StorageScanFailure.workerFailed)
            }
            control.escalateIfNeeded()
            if status == nil { status = control.reapIfExited() }
            if descriptors.allSatisfy({ $0.fd < 0 }), let status {
                if let failure { throw failure }
                return status
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 && errno != EINTR { reject(StorageScanFailure.workerFailed) }
            if ready > 0 {
                for index in descriptors.indices
                where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    let count = read(descriptors[index].fd, &bytes, bytes.count)
                    if count <= 0 {
                        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                        if count < 0 { reject(StorageScanFailure.workerFailed) }
                        descriptors[index].fd = -1
                    } else if failure == nil {
                        do { try consume(index == 0 ? .stdout : .stderr, bytes[..<count]) }
                        catch { reject(error) }
                    }
                }
            }
            onPoll()
        }
    }
}
