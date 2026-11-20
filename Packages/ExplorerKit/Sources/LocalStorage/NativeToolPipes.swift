import Darwin
import Foundation

/// Cancellation owns one exact read-only child until that process is reaped.
/// This control is never attached to a submitted storage mutation.
final class ReadOnlyToolChildControl: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var requested = false
    private var termTime: TimeInterval?
    private var escalated = false

    var stopRequested: Bool { lock.withLock { requested } }

    func attach(_ process: Process) {
        lock.withLock {
            precondition(child == nil)
            child = process
            if requested { signalLocked() }
        }
    }

    func requestStop() {
        lock.withLock {
            requested = true
            signalLocked()
        }
    }

    private func signalLocked() {
        guard termTime == nil, let child, child.isRunning else { return }
        if Darwin.kill(child.processIdentifier, SIGTERM) == 0 {
            termTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func escalateIfNeeded() {
        lock.withLock {
            guard let child, child.isRunning, let termTime, !escalated,
                  ProcessInfo.processInfo.systemUptime - termTime >= 2 else { return }
            escalated = true
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    func detachAfterReap() {
        lock.withLock {
            precondition(child?.isRunning == false)
            child = nil
        }
    }
}

/// Drains a fixed Apple tool or an admitted health worker. Read-only deadlines
/// and cancellation stay active after EOF. A submitted mutation instead keeps
/// draining bounded prefixes and waits for its actual exit without signals.
enum NativeToolPipes {
    struct Query {
        let control: ReadOnlyToolChildControl
        let timeout: TimeInterval?
        let shouldStop: () -> Bool

        init(control: ReadOnlyToolChildControl, timeout: TimeInterval?, shouldStop: @escaping () -> Bool = { false }) {
            self.control = control
            self.timeout = timeout
            self.shouldStop = shouldStop
        }
    }

    struct Output {
        let stdout, stderr: Data
        let stdoutTruncated, stderrTruncated: Bool
        let complete, stopped: Bool
        let status: Int32
    }

    private struct Stream {
        let reader: FileHandle
        let limit: Int?
        var bytes = Data()
        var truncated = false

        mutating func append(_ buffer: [UInt8], count: Int) {
            guard let limit else { return }
            let available = limit - bytes.count
            bytes.append(contentsOf: buffer.prefix(min(count, available)))
            truncated = truncated || count > available
        }
    }

    static func collect(_ child: Process, output: Pipe, outputLimit: Int,
                        errors: Pipe? = nil, errorLimit: Int? = nil, query: Query? = nil) -> Output {
        var streams = [Stream(reader: output.fileHandleForReading, limit: outputLimit)]
        if let errors { streams.append(Stream(reader: errors.fileHandleForReading, limit: errorLimit)) }
        var descriptors = streams.map { pollfd(fd: $0.reader.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        let activity = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        let began = ProcessInfo.processInfo.systemUptime
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var readFailed = false
        var reapWait: Int32 = 1

        while true {
            let allClosed = descriptors.allSatisfy { $0.fd < 0 }
            if let query {
                let timedOut = query.timeout.map { ProcessInfo.processInfo.systemUptime - began >= $0 } ?? false
                if timedOut || query.shouldStop() || streams.contains(where: \.truncated) || readFailed { query.control.requestStop() }
                query.control.escalateIfNeeded()
                if !child.isRunning && (allClosed || query.control.stopRequested) { break }
            } else if allClosed { break }

            // EOF can arrive just before Foundation observes the exit. Check
            // that common gap promptly, then back off for a child that closed
            // its streams early. Deadlines still apply while it is running.
            let wait = allClosed ? reapWait : 100
            if allClosed { reapWait = min(100, reapWait * 2) }
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), wait)
            if ready < 0 {
                if errno == EINTR { continue }
                readFailed = true
                query?.control.requestStop()
                break
            }
            if ready == 0 { continue }
            for index in descriptors.indices where descriptors[index].revents & activity != 0 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count > 0 { streams[index].append(buffer, count: count) }
                else {
                    readFailed = readFailed || count < 0
                    try? streams[index].reader.close()
                    descriptors[index].fd = -1
                }
            }
        }
        let complete = !readFailed && descriptors.allSatisfy { $0.fd < 0 }
        for index in descriptors.indices where descriptors[index].fd >= 0 { try? streams[index].reader.close() }
        if let query, query.control.stopRequested {
            // A poll failure can retire the readers before the child exits.
            while child.isRunning {
                query.control.escalateIfNeeded()
                usleep(10_000)
            }
        }
        child.waitUntilExit()
        let errorStream = streams.count == 2 ? streams[1] : nil
        return .init(stdout: streams[0].bytes, stderr: errorStream?.bytes ?? Data(),
            stdoutTruncated: streams[0].truncated, stderrTruncated: errorStream?.truncated ?? false,
            complete: complete, stopped: query?.control.stopRequested == true,
            status: child.terminationReason == .exit ? child.terminationStatus : -1)
    }
}
