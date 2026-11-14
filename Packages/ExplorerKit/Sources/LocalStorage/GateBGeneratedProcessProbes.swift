#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
import Darwin
import ExplorerCore
import Foundation

/// Darwin's observed birth identity is checked immediately before every
/// signal. A Foundation Process object alone is not proof that its PID still
/// names the launched child.
struct GateBObservedChild: Equatable {
    let pid: pid_t, parent: pid_t, uid: uid_t
    let birthSeconds: UInt64, birthMicroseconds: UInt64
    let executable: String
    static func current(_ pid: pid_t) -> Self? {
        guard pid > 0 else { return nil }
        var facts = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &facts,
                                 Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == Int32(MemoryLayout<proc_bsdinfo>.size),
              facts.pbi_pid == UInt32(pid) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0, length < Int32(path.count) else { return nil }
        return Self(pid: pid, parent: pid_t(facts.pbi_ppid), uid: facts.pbi_uid,
                    birthSeconds: facts.pbi_start_tvsec,
                    birthMicroseconds: facts.pbi_start_tvusec,
                    executable: path.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }))
    }
    func signal(_ value: Int32) throws {
        guard Self.current(pid) == self, Darwin.kill(pid, value) == 0 else {
            throw GateBGeneratedFailure(stage: "owned-child-identity-or-signal")
        }
    }
}

/// Own the parent pipe end explicitly. A retained parent write handle would
/// prevent EOF even after the child exits. Read at most two bytes under the
/// same whole-probe deadline; a second byte or missing EOF is a refusal.
private enum GateBChildProcessReceipt {
    static func oneByte(_ process: Process, pipe: Pipe, readyPipe: Pipe,
                        expectedExecutable: String, deadline: TimeInterval,
                        stage: String) throws -> UInt8 {
        guard let owner = GateBObservedChild.current(process.processIdentifier),
              owner.parent == getpid(), owner.uid == geteuid(),
              owner.executable == expectedExecutable else {
            // An unobserved child receives no release byte. Its bounded local
            // handshake should exit; reap it if that already happened.
            let until = min(deadline, ProcessInfo.processInfo.systemUptime + 1.6)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { usleep(5_000) }
            if !process.isRunning { process.waitUntilExit() }
            throw GateBGeneratedFailure(stage: stage + "-unobserved-or-wrong-child")
        }
        do {
        let writer = readyPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else {
            throw GateBGeneratedFailure(stage: stage + "-release-pipe-mode")
        }
        var release: UInt8 = 0xA5
        guard Darwin.write(writer, &release, 1) == 1 else {
            throw GateBGeneratedFailure(stage: stage + "-release-pipe-write")
        }
        readyPipe.fileHandleForWriting.closeFile()
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning {
            try owner.signal(SIGTERM)
            let grace = min(deadline + 0.25, ProcessInfo.processInfo.systemUptime + 0.25)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
            if process.isRunning {
                try owner.signal(SIGKILL)
                let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline { usleep(5_000) }
            }
            guard !process.isRunning else { throw GateBGeneratedFailure(stage: stage + "-drain-uncertain") }
            process.waitUntilExit()
            throw GateBGeneratedFailure(stage: stage + "-expired")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GateBGeneratedFailure(stage: stage + "-exit") }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw GateBGeneratedFailure(stage: stage + "-pipe-mode")
        }
        var bytes = [UInt8](repeating: 0, count: 2), received = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&item, 1, 20)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw GateBGeneratedFailure(stage: stage + "-pipe-poll") }
            if ready == 0 { continue }
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: received), 2 - received)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count == 0 {
                guard received == 1 else { throw GateBGeneratedFailure(stage: stage + "-pipe-count") }
                return bytes[0]
            }
            guard count > 0, received + count == 1 else {
                throw GateBGeneratedFailure(stage: stage + "-pipe-count")
            }
            received += count
        }
        throw GateBGeneratedFailure(stage: stage + "-pipe-eof-expired")
        } catch {
            if process.isRunning {
                do { try owner.signal(SIGTERM) }
                catch { throw GateBGeneratedFailure(stage: stage + "-drain-identity-uncertain") }
                let termUntil = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < termUntil { usleep(5_000) }
                if process.isRunning {
                    do { try owner.signal(SIGKILL) }
                    catch { throw GateBGeneratedFailure(stage: stage + "-drain-identity-uncertain") }
                    let killUntil = ProcessInfo.processInfo.systemUptime + 1
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < killUntil { usleep(5_000) }
                }
            }
            guard !process.isRunning else { throw GateBGeneratedFailure(stage: stage + "-drain-uncertain") }
            process.waitUntilExit()
            throw error
        }
    }
}

/// The same reviewed App image is invoked as a separate process. It receives
/// only the generated case/body UUID and the exact expected lock identity,
/// derives the path under the fixed development owner, and uses its own fd.
@_spi(Qualification) public enum GateBGeneratedOwnerPinChild {
    public static func runOrExit() -> Never {
        do { try run(); exit(0) } catch { exit(71) }
    }
    private static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 8, args[1] == "--gateb-owner-pin-child",
              let caseID = UUID(uuidString: args[2]), caseID.uuidString == args[2],
              let bodyID = UUID(uuidString: args[3]), bodyID.uuidString == args[3],
              let expectedDevice = UInt64(args[4]), let expectedInode = UInt64(args[5]),
              let expectedBirthSeconds = Int(args[6]), let expectedBirthNanos = Int(args[7]),
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.executableURL?.path.contains("/.build/traverse-development/") == true
        else { throw GateBGeneratedFailure(stage: "pin-child-arguments") }
        try GateBGeneratedChildAdmission.awaitParentRelease()
        let admission = try GateBGeneratedChildAdmission.requireChild(caseID: caseID,
            maximumSeconds: 5)
        let root = admission.root
        guard ProcessInfo.processInfo.systemUptime < admission.deadline else {
            throw GateBGeneratedFailure(stage: "pin-child-admission-deadline")
        }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw GateBGeneratedFailure(stage: "pin-child-case-open") }
        defer { Darwin.close(fd) }
        var rootFacts = stat()
        guard fstat(fd, &rootFacts) == 0, rootFacts.st_uid == geteuid(),
              rootFacts.st_mode & S_IFMT == S_IFDIR, rootFacts.st_mode & 0o7777 == 0o700 else {
            throw GateBGeneratedFailure(stage: "pin-child-case-private")
        }
        for name in ["state", "ApplicationSupport", "local.macexplorer.development.gateb",
                     "connection-workspace.original-bodies", "download-" + bodyID.uuidString] {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard next >= 0 else { throw GateBGeneratedFailure(stage: "pin-child-component-open") }
            var facts = stat()
            guard fstat(next, &facts) == 0, facts.st_uid == geteuid(),
                  facts.st_dev == rootFacts.st_dev, facts.st_mode & S_IFMT == S_IFDIR,
                  facts.st_mode & 0o7777 == 0o700 else {
                Darwin.close(next); throw GateBGeneratedFailure(stage: "pin-child-component-private")
            }
            Darwin.close(fd); fd = next
        }
        let lock = openat(fd, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lock >= 0 else { throw GateBGeneratedFailure(stage: "pin-child-lock-open") }
        defer { Darwin.close(lock) }
        var facts = stat(), named = stat()
        guard fstat(lock, &facts) == 0,
              fstatat(fd, "owner.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              facts.st_uid == geteuid(), facts.st_mode & S_IFMT == S_IFREG,
              facts.st_mode & 0o7777 == 0o600, facts.st_nlink == 1, facts.st_size == 0,
              UInt64(truncatingIfNeeded: facts.st_dev) == expectedDevice,
              UInt64(facts.st_ino) == expectedInode,
              Int(facts.st_birthtimespec.tv_sec) == expectedBirthSeconds,
              Int(facts.st_birthtimespec.tv_nsec) == expectedBirthNanos,
              facts.st_dev == named.st_dev, facts.st_ino == named.st_ino,
              facts.st_birthtimespec.tv_sec == named.st_birthtimespec.tv_sec,
              facts.st_birthtimespec.tv_nsec == named.st_birthtimespec.tv_nsec else {
            throw GateBGeneratedFailure(stage: "pin-child-lock-identity")
        }
        var result: UInt8
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { result = 65; _ = flock(lock, LOCK_UN) }
        else if errno == EWOULDBLOCK { result = 66 }
        else { throw GateBGeneratedFailure(stage: "pin-child-lock-refused") }
        guard Darwin.write(STDOUT_FILENO, &result, 1) == 1 else {
            throw GateBGeneratedFailure(stage: "pin-child-result-pipe")
        }
    }
}

/// The parent validates the real body record and then supervises the exact
/// image's independent lock attempt. One byte, actual exit, EOF and a five
/// second deadline are mandatory; no same-process contender is accepted.
enum GateBGeneratedPinProbe {
    static func check(root: URL, bodies: URL, reference: SFTPOriginalSpoolReference, held: Bool) async throws {
        try await Task.detached {
            guard bodies.path.hasPrefix(root.path + "/") else { throw GateBGeneratedFailure(stage: "pin-parent-body-scope") }
            let pool = open(bodies.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard pool >= 0 else { throw GateBGeneratedFailure(stage: "pin-parent-pool-open") }
            defer { Darwin.close(pool) }
            let record = try DownloadDisk.record(pool, name: "download-" + reference.id.uuidString)
            guard record.summary.id == reference.id, record.summary.expectedBytes == reference.logicalBytes,
                  let identity = record.files["owner.lock"] else {
                throw GateBGeneratedFailure(stage: "pin-parent-record-identity")
            }
            let admission = try GateBGeneratedChildAdmission.parentEnvironment(root: root,
                maximumSeconds: 5)
            let process = Process(), pipe = Pipe(), readyPipe = Pipe()
            process.executableURL = admission.image
            process.arguments = ["--gateb-owner-pin-child", root.lastPathComponent,
                reference.id.uuidString, String(UInt64(truncatingIfNeeded: identity.device)),
                String(UInt64(identity.inode)), String(identity.birthSeconds), String(identity.birthNanos)]
            process.environment = admission.environment
            process.standardInput = readyPipe
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let deadline = admission.deadline
            defer {
                readyPipe.fileHandleForReading.closeFile()
                readyPipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.closeFile()
                pipe.fileHandleForWriting.closeFile()
            }
            try process.run()
            readyPipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            let byte = try GateBChildProcessReceipt.oneByte(process, pipe: pipe,
                readyPipe: readyPipe,
                expectedExecutable: admission.image.path,
                deadline: deadline, stage: "pin-child")
            guard byte == (held ? 66 : 65) else {
                throw GateBGeneratedFailure(stage: "separate-process-owner-ex-result")
            }
        }.value
    }
}

private final class GateBChildByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var byte: UInt8?
    func set(_ value: UInt8?) { lock.withLock { byte = value } }
    func get() -> UInt8? { lock.withLock { byte } }
}

/// Fresh, independent process. It asks the real ConnectionWorkspace retirement
/// owner for a choice and invokes Remove only if one was actually minted. A
/// staged catalog refusal is reported as R; the parent must prove byte/identity
/// preservation independently before accepting R.
@_spi(Qualification) public enum GateBGeneratedRemovalChild {
    public static func runOrExit() -> Never {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--gateb-removal-child",
              let id = UUID(uuidString: args[2]), id.uuidString == args[2],
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.executableURL?.path.contains("/.build/traverse-development/") == true else { exit(71) }
        do { try GateBGeneratedChildAdmission.awaitParentRelease() }
        catch { exit(71) }
        let result = GateBChildByteBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                let admission = try GateBGeneratedChildAdmission.requireChild(caseID: id,
                    maximumSeconds: 12)
                let root = admission.root
                guard ProcessInfo.processInfo.systemUptime < admission.deadline else {
                    throw GateBGeneratedFailure(stage: "remove-child-admission-deadline")
                }
                let layout = try ApplicationStorageLayout(applicationSupport: root.appendingPathComponent("state/ApplicationSupport", isDirectory: true),
                    caches: root.appendingPathComponent("state/Caches", isDirectory: true),
                    bundleIdentifier: "local.macexplorer.development.gateb")
                let workspace = try ConnectionWorkspace(layout: layout)
                var value: UInt8?
                do {
                    let choices = try await workspace.retainedDocumentsAfterExplicitRequest()
                    guard choices.count == 1 else { throw GateBGeneratedFailure(stage: "remove-child-exact-choice") }
                    try await workspace.removeRetainedDocument(choices[0])
                    value = 80 // P: real Remove progressed.
                } catch RemoteSettingsFailure.recoveryRequired { value = 82 }
                  catch ConnectionWorkspaceFailure.reviewRequired { value = 82 }
                  catch SFTPSharedBudgetFailure.recoveryRequired { value = 82 }
                  catch { value = nil }
                // Every path after workspace creation takes the real owner
                // drain before a result byte can leave this process. A timeout
                // in the outer bounded supervisor remains an explicit refusal.
                await workspace.stopAndDrain()
                result.set(value)
            } catch { result.set(nil) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { task.cancel(); exit(71) }
        guard var resultByte = result.get(),
              Darwin.write(STDOUT_FILENO, &resultByte, 1) == 1 else { exit(71) }
        exit(0)
    }
}

/// Parent supervision for the fresh Remove attempt. It accepts exactly one
/// byte with actual exit and EOF before the process deadline.
enum GateBGeneratedRemovalProbe {
    static func attempt(root: URL) async throws -> UInt8 {
        try await Task.detached {
            let admission = try GateBGeneratedChildAdmission.parentEnvironment(root: root,
                maximumSeconds: 12)
            let process = Process(), pipe = Pipe(), readyPipe = Pipe()
            process.executableURL = admission.image
            process.arguments = ["--gateb-removal-child", root.lastPathComponent]
            process.environment = admission.environment
            process.standardInput = readyPipe
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let deadline = admission.deadline
            defer {
                readyPipe.fileHandleForReading.closeFile()
                readyPipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.closeFile()
                pipe.fileHandleForWriting.closeFile()
            }
            try process.run()
            readyPipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            let byte = try GateBChildProcessReceipt.oneByte(process, pipe: pipe,
                readyPipe: readyPipe,
                expectedExecutable: admission.image.path,
                deadline: deadline, stage: "remove-child")
            guard byte == 80 || byte == 82 else {
                throw GateBGeneratedFailure(stage: "fresh-remove-process-result")
            }
            return byte
        }.value
    }
}
#endif
