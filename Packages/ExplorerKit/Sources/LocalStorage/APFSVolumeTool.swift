import Darwin
import Foundation
import Security

/// Fixed Apple-tool requests on a utility queue. Read-only inquiries may be
/// stopped; an add-volume child is never signalled, even on cancellation,
/// timeout or excessive output. Its actual return always owns the worker.
final class APFSVolumeTool: Sendable {
    enum Failure: Error { case launch, inquiry }
    /// Internal qualification only. Delivered after the mutation child has
    /// actually been reaped; never included in the public creation result.
    struct MutationTerminal: Sendable {
        let stdout, stderr: Data
        let stdoutTruncated, stderrTruncated, readIncomplete: Bool
        let status: Int32
    }
    typealias TerminalObserver = @Sendable (MutationTerminal) -> Void
    private let terminalObserver: TerminalObserver?
    init(terminalObserver: TerminalObserver? = nil) { self.terminalObserver = terminalObserver }
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var inquiry: DriveHealthChildControl?
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true; inquiry?.requestStop() } }
        func attach(_ control: DriveHealthChildControl) {
            lock.withLock { inquiry = control; if cancelled { control.requestStop() } }
        }
        func detach() { lock.withLock { inquiry = nil } }
    }
    private let queue = DispatchQueue(label: "com.respawnstudios.traverse.apfs-volume", qos: .utility)
    func inquire(_ arguments: [String], cancellation: Cancellation? = nil) async throws -> Data {
        let allowed = arguments.count == 3 && arguments.prefix(2) == ["info", "-plist"] && APFSContainerObservation.validDevice(arguments[2])
            || arguments.count == 4 && arguments.prefix(3) == ["apfs", "list", "-plist"] && APFSContainerObservation.validContainer(arguments[3])
        guard allowed else { throw APFSVolumeCreationFailure.unsupported }
        let result = try await run(arguments, mutation: false, cancellation: cancellation)
        guard result.status == 0, !result.overflow, !result.stopped else { throw Failure.inquiry }
        return result.data
    }
    struct MutationReply: Sendable {
        let status: Int32
        let errorCode: Int?
        let diagnosticCategory: APFSVolumeCreationResult.DiagnosticCategory?
    }
    func mutate(_ arguments: [String], submitted: @escaping @Sendable () -> Void) async throws -> MutationReply {
        guard Self.permitsInProcessMutation else { throw APFSVolumeCreationFailure.unavailable }
        guard arguments.count == 5, arguments.prefix(2) == ["apfs", "addVolume"],
              APFSContainerObservation.validContainer(arguments[2]), ["APFS", "Case-sensitive APFS"].contains(arguments[3]),
              (try? APFSVolumeCreation.validatedName(arguments[4])) == arguments[4] else { throw APFSVolumeCreationFailure.unsupported }
        let reply = try await run(arguments, mutation: true, cancellation: nil, submitted: submitted)
        return .init(status: reply.status, errorCode: reply.errorCode, diagnosticCategory: reply.diagnosticCategory)
    }
    /// A folder grant is never disk-operation authority. Even a mistaken App
    /// policy cannot ask diskutil to mutate from a sandboxed parent. Unknown
    /// code-signing/entitlement state also refuses; no helper escapes the box.
    private static var permitsInProcessMutation: Bool {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return false }
        guard let raw = information[kSecCodeInfoEntitlementsDict as String] else { return true }
        guard let entitlements = raw as? [String: Any] else { return false }
        guard let sandbox = entitlements["com.apple.security.app-sandbox"] else { return true }
        return APFSContainerObservation.boolean(sandbox) == false
    }
    private struct Reply: Sendable {
        let status: Int32
        let data: Data
        let overflow, stopped: Bool
        let errorCode: Int?
        let diagnosticCategory: APFSVolumeCreationResult.DiagnosticCategory?
    }
    /// Only a numeric code from a complete recognized Apple-tool Error line survives.
    /// Device names, paths, chosen names and raw tool text never leave here.
    static func numericErrorCode(_ data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^(?:Error: (-?[0-9]{1,10}): [^\r\n]+|Error[^\r\n]*\((-?[0-9]{1,10})\)[ \t]*)\r?$"#),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = (1...2).compactMap({ Range(match.range(at: $0), in: text) }).first else { return nil }
        return Int(text[range])
    }
    /// Only complete fixed tool lines are classified. An exit status, a quoted
    /// name containing permission words, or unfamiliar wording proves no cause.
    /// Streams stay separate so unrelated stdout/stderr fragments cannot join
    /// into an apparently recognized diagnostic.
    static func diagnosticCategory(stdout: Data, stderr: Data) -> APFSVolumeCreationResult.DiagnosticCategory? {
        let matches = [stdout, stderr].flatMap { bytes in
            String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines).compactMap { line -> APFSVolumeCreationResult.DiagnosticCategory? in
                switch line {
                case "Error: The requesting process is not authorized to perform this operation", "Error: This operation requires root":
                    return .authorizationReported
                case "Error: Permission denied", "Error: Operation not permitted":
                    return .permissionReported
                case "Error: -69493: You can't add any more APFS Volumes to its APFS Container":
                    return .volumeLimitReported
                default:
                    return line.hasPrefix("Usage: diskutil apfs addVolume ") || line.hasPrefix("Usage:  diskutil apfs addVolume ") ? .commandUsage : nil
                }
            }
        }
        // Conflicting recognized diagnostics do not establish one category.
        guard let first = matches.first, matches.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    private func run(_ arguments: [String], mutation: Bool, cancellation: Cancellation?,
                     submitted: @escaping @Sendable () -> Void = {}) async throws -> Reply {
        let observer = terminalObserver
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try Self.collect(arguments, mutation: mutation, cancellation: cancellation, submitted: submitted, observer: observer)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func collect(_ arguments: [String], mutation: Bool, cancellation: Cancellation?,
                                submitted: @Sendable () -> Void, observer: TerminalObserver?) throws -> Reply {
        if !mutation, cancellation?.isCancelled == true { throw CancellationError() }
        let child = Process(), output = Pipe(), errors = Pipe()
        let control = DriveHealthChildControl()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        child.arguments = arguments; child.environment = ["LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        do { try child.run() } catch { throw Failure.launch }
        if mutation { submitted() }
        else { control.attach(child); cancellation?.attach(control) }
        defer {
            if !mutation { cancellation?.detach(); control.detachAfterReap() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        var data = Data(), terminalOutput = Data(), terminalErrors = Data()
        var outputTruncated = false, errorsTruncated = false
        var overflow = false, outputEOF = false, errorEOF = false
        let began = ProcessInfo.processInfo.systemUptime
        while !outputEOF || !errorEOF {
            if !mutation {
                if ProcessInfo.processInfo.systemUptime - began > 20 || overflow { control.requestStop() }
                control.escalateIfNeeded()
            }
            var descriptors = [pollfd(fd: outputEOF ? -1 : output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorEOF ? -1 : errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                // Closing our read ends prevents pipe backpressure, while an
                // already submitted mutation still drains normally below.
                overflow = true; break
            }
            for index in 0..<2 where descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 {
                    if count < 0 { overflow = true }
                    if index == 0 { outputEOF = true } else { errorEOF = true }
                } else if mutation {
                    // Keep bounded prefixes separately. Never classify partial
                    // or truncated output; continue draining without signalling.
                    if index == 0 {
                        let available = 8192 - terminalOutput.count
                        terminalOutput.append(contentsOf: buffer.prefix(min(count, available)))
                        outputTruncated = outputTruncated || count > available
                    } else {
                        let available = 8192 - terminalErrors.count
                        terminalErrors.append(contentsOf: buffer.prefix(min(count, available)))
                        errorsTruncated = errorsTruncated || count > available
                    }
                } else if index == 0 {
                    if data.count + count <= 2 << 20 { data.append(contentsOf: buffer.prefix(count)) }
                    else { overflow = true }
                }
                // Transient bounded text is reduced to fixed facts only.
                // Nothing forwards names or raw progress into diagnostics.
            }
        }
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        child.waitUntilExit()
        let status = child.terminationReason == .exit ? child.terminationStatus : -1
        if mutation {
            observer?(.init(stdout: terminalOutput, stderr: terminalErrors, stdoutTruncated: outputTruncated,
                stderrTruncated: errorsTruncated, readIncomplete: overflow, status: status))
        }
        let canClassify = mutation && status != 0 && !overflow && !outputTruncated && !errorsTruncated
        let outputCode = canClassify ? numericErrorCode(terminalOutput) : nil
        let errorCode = canClassify ? numericErrorCode(terminalErrors) : nil
        return .init(status: status, data: data, overflow: overflow, stopped: control.didSignal,
            errorCode: outputCode == nil || errorCode == nil || outputCode == errorCode ? errorCode ?? outputCode : nil,
            diagnosticCategory: canClassify ? diagnosticCategory(stdout: terminalOutput, stderr: terminalErrors) : nil)
    }
}
