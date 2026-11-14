import Darwin
import Foundation

/// The lock covers the one exact child from attach through wait/reap. No PID is
/// signalled after the Process owner has declared it reaped.
internal final class DriveHealthChildControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var requested = false
    private var signalled = false
    private var signalTime: TimeInterval?
    private var escalated = false

    var stopRequested: Bool { lock.withLock { requested } }
    var didSignal: Bool { lock.withLock { signalled } }

    func attach(_ child: Process) {
        lock.withLock {
            precondition(process == nil)
            process = child
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
        guard let process, process.isRunning else { return }
        if Darwin.kill(process.processIdentifier, SIGTERM) == 0 {
            signalled = true
            if signalTime == nil { signalTime = ProcessInfo.processInfo.systemUptime }
        }
    }
    func escalateIfNeeded() {
        lock.withLock {
            guard let process, process.isRunning, let signalTime, !escalated,
                  ProcessInfo.processInfo.systemUptime - signalTime >= 2 else { return }
            escalated = true
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    func detachAfterReap() {
        lock.withLock {
            precondition(process?.isRunning == false)
            process = nil
        }
    }
}

internal enum DriveHealthChildProcess {
    private static let maximumReplyBytes = 256
    static func run(_ selection: PreparedDriveHealthSelection,
                    control: DriveHealthChildControl) -> DriveHealthReport {
        let admission: DriveHealthHelperIdentity.Prepared
        do { admission = try DriveHealthHelperIdentity.prepare() }
        catch {
            return .init(outcome: .unavailable(DriveHealthHelperIdentity.compositionDeclared ? .unavailable : .unsupported),
                transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .helperAdmission, admissionFailure: admissionFailure(error)))
        }
        guard !control.stopRequested else {
            return .init(outcome: .unavailable(.stale), transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .installation))
        }
        do { try admission.validateInstallation() }
        catch { return .init(outcome: .unavailable(.unavailable), transport: .notStarted, nativeCleanupConfirmed: true,
            diagnostic: .init(stage: .installation, admissionFailure: admissionFailure(error))) }
        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = admission.helper
        child.arguments = []
        child.environment = ["LANG": "C", "LC_ALL": "C"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        do { try child.run() }
        catch { return .init(outcome: .unavailable(.unavailable), transport: .notStarted, nativeCleanupConfirmed: true,
            diagnostic: .init(stage: .launch)) }
        control.attach(child)
        var sent = false, admitted = false
        var failureStage = DriveHealthDiagnostic.Stage.childAdmission
        var failureAdmission: DriveHealthDiagnostic.AdmissionFailure?
        var nonce = UUID().uuid
        let nonceBytes = withUnsafeBytes(of: &nonce) { Array($0) }
        if !control.stopRequested {
            do {
                try admission.validateChild(child.processIdentifier)
                admitted = true
                failureStage = .request
                let request = DriveHealthWire.request(selection, nonce: nonceBytes)
                try input.fileHandleForWriting.write(contentsOf: request)
                sent = true
            } catch { failureAdmission = admissionFailure(error); control.requestStop() }
        }
        try? input.fileHandleForWriting.close()
        let observation = collect(output: output.fileHandleForReading.fileDescriptor,
                                  errors: errors.fileHandleForReading.fileDescriptor, control: control)
        child.waitUntilExit()
        control.detachAfterReap()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        guard admitted, sent else {
            return .init(outcome: .unavailable(control.stopRequested ? .stale : .uncertain),
                childReaped: true, nativeCleanupConfirmed: false,
                diagnostic: .init(stage: failureStage, childStarted: true, requestSent: sent,
                    admissionFailure: failureAdmission))
        }
        guard child.terminationReason == .exit, child.terminationStatus == 0,
              !control.didSignal, observation.outputEOF, observation.errorEOF,
              !observation.overflow, observation.errorBytes == 0,
              let decoded = DriveHealthWire.decode(observation.bytes, nonce: nonceBytes) else {
            return .init(outcome: .unavailable(.uncertain), childReaped: true, nativeCleanupConfirmed: false,
                diagnostic: .init(stage: .reply, childStarted: true, requestSent: true))
        }
        return decoded
    }

    private static func admissionFailure(_ error: Error) -> DriveHealthDiagnostic.AdmissionFailure? {
        switch error {
        case DriveHealthHelperIdentity.Failure.policy: return .policy
        case DriveHealthHelperIdentity.Failure.changed: return .changed
        case DriveHealthHelperIdentity.Failure.signature: return .signature
        default: return nil
        }
    }

    private struct Observation {
        var bytes = Data()
        var errorBytes = 0
        var outputEOF = false
        var errorEOF = false
        var overflow = false
    }
    private static func collect(output: Int32, errors: Int32,
                                control: DriveHealthChildControl) -> Observation {
        var result = Observation()
        while !result.outputEOF || !result.errorEOF {
            control.escalateIfNeeded()
            var descriptors = [pollfd(fd: result.outputEOF ? -1 : output, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: result.errorEOF ? -1 : errors, events: Int16(POLLIN), revents: 0)]
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                result.overflow = true
                control.requestStop()
                break
            }
            if ready == 0 { continue }
            for index in 0..<2 where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 {
                    if count < 0 { result.overflow = true; control.requestStop(); return result }
                    if index == 0 { result.outputEOF = true } else { result.errorEOF = true }
                    continue
                }
                if index == 0 {
                    if result.bytes.count + count <= maximumReplyBytes {
                        result.bytes.append(contentsOf: buffer.prefix(count))
                    } else { result.overflow = true; control.requestStop() }
                } else {
                    result.errorBytes += count
                    if result.errorBytes > 256 { result.overflow = true; control.requestStop() }
                }
            }
        }
        return result
    }
}
