import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Security

@_spi(Qualification) public struct SMBWorkerCloseResult: Sendable {
    public let exitStatus: Int32?
    public let actualExit: Bool
    public let localDrainProved: Bool
    public let forcedContainment: Bool
    public let diagnostics: SMBWorkerDiagnostics?
}

/// Bounded numeric lifetime evidence; contains no endpoint, name or credential.
@_spi(Qualification) public struct SMBWorkerDiagnostics: Sendable {
    public let outcome: String
    public let joined: Int
    public let pending: Int
    public let tasks: Int
    public let observed: Int
    public let drainMicroseconds: UInt64
    public let commands: [UInt64]
}

/// Generated-only session qualification. Ordinary remote locations cannot use
/// this SPI. Helpers have a fixed generated loopback endpoint; authenticated
/// input crosses only the private channel, never arguments/environment.
@_spi(Qualification) public final class SMBWorkerSession: @unchecked Sendable {
    private let owner: SMBWorkerOwner
    private init(_ owner: SMBWorkerOwner) { self.owner = owner }

    public static func connectGenerated(bundleURL: URL, activity: FileActivityGate) async throws -> SMBWorkerSession {
        let owner = SMBWorkerOwner(bundle: bundleURL, activity: activity)
        return try await connect(owner)
    }
    public static func connectGeneratedAuthenticated(bundleURL: URL, activity: FileActivityGate, password: SMBPassword,
        policy: SMBWorkerSecurityPolicy = .encrypted, share: SMBGeneratedShare = .standard) async throws -> SMBWorkerSession {
        let owner = SMBWorkerOwner(bundle: bundleURL, activity: activity, profile: .authenticated(policy),
                                   share: share, password: password)
        return try await connect(owner)
    }
    public var security: SMBWorkerSecurity? { owner.security }
    private static func connect(_ owner: SMBWorkerOwner) async throws -> SMBWorkerSession {
        try SMBWorkerAdmission.shared.reserve(owner)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                owner.queue.async {
                    do { try owner.launch(); try owner.waitConnected(); continuation.resume() }
                    catch { owner.requestStop(); _ = owner.finish(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { owner.requestStop() }
        return SMBWorkerSession(owner)
    }

    /// Page callbacks occur on the session executor. Native callers dispatch to
    /// their UI executor and recheck allowsPublication there before rendering.
    public func readGeneratedDirectory(nested: Bool = false, onPage: @escaping @Sendable (SMBWorkerPage) -> Void) async throws -> Int {
        let owner = self.owner
        let id = try owner.admitRead()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.queue.async {
                    do {
                        let count = try owner.read(id: id, nested: nested, onPage: onPage)
                        owner.endRead(); continuation.resume(returning: count)
                    } catch {
                        owner.requestStop(); _ = owner.finish(); owner.endRead()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { owner.requestStop() }
    }
    public func allowsPublication(_ readID: UUID) -> Bool { owner.allowsPublication(readID) }
    public func close() async -> SMBWorkerCloseResult {
        let owner = self.owner
        owner.requestStop()
        return await withCheckedContinuation { continuation in
            owner.queue.async { continuation.resume(returning: owner.finish()) }
        }
    }
    deinit {
        let retained = owner
        retained.requestStop()
        retained.queue.async { _ = retained.finish() }
    }
}

/// A genuinely uncertain child keeps its owner/lease and closes admission. A
/// timeout cannot silently create replacement helpers behind a closed view.
private final class SMBWorkerAdmission: @unchecked Sendable {
    static let shared = SMBWorkerAdmission()
    private let lock = NSLock()
    private var owner: SMBWorkerOwner?
    func reserve(_ value: SMBWorkerOwner) throws {
        try lock.withLock { guard owner == nil else { throw SMBWorkerFailure.busy }; owner = value }
    }
    func release(_ value: SMBWorkerOwner) {
        lock.withLock { if owner === value { owner = nil } }
    }
}

private final class SMBWorkerOwner: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacExplorer.SMBWorker", qos: .userInitiated)
    private let lock = NSLock()
    private let bundle: URL
    private let activity: FileActivityGate
    private let profile: SMBWorkerWireProfile
    private let share: SMBGeneratedShare
    private var privateCredentialInput: Data?
    private var actualSecurity: SMBWorkerSecurity?
    private let sessionID = UUID()
    private var lease: FileActivityGate.Lease?
    // Only short bookkeeping/control writes occur under lock. Blocking work is
    // confined to queue. Closing the descriptor also takes lock to avoid reuse.
    private var descriptor: Int32 = -1
    private var pid: pid_t = 0
    private var stopAt: TimeInterval?
    private var readID: UUID?
    private var reading = false
    private var finished = false
    private var exitStatus: Int32?
    private var contained = false
    private var eof = false
    private var buffer = Data()
    private var decoder: SMBWorkerDecoder
    private var pendingEvents: [SMBWorkerEvent] = []

    init(bundle: URL, activity: FileActivityGate, profile: SMBWorkerWireProfile = .guestQualification,
         share: SMBGeneratedShare = .standard, password: SMBPassword? = nil) {
        self.bundle = bundle; self.activity = activity; self.profile = profile; self.share = share
        decoder = SMBWorkerDecoder(session: sessionID, profile: profile)
        if let password {
            var payload = Data("CREDENTIALS 6e6f626f6479 ".utf8)
            let digits = Array("0123456789abcdef".utf8)
            password.withUTF8Bytes { bytes in
                for byte in bytes { payload.append(digits[Int(byte >> 4)]); payload.append(digits[Int(byte & 15)]) }
            }
            payload.append(contentsOf: " -\n".utf8); privateCredentialInput = payload
        }
    }
    var security: SMBWorkerSecurity? { lock.withLock { actualSecurity } }
    func admitRead() throws -> UUID {
        try lock.withLock {
            guard stopAt == nil, !finished, !reading, pid > 0 else { throw SMBWorkerFailure.busy }
            let id = UUID(); readID = id; reading = true; return id
        }
    }
    func endRead() { lock.withLock { reading = false } }
    func allowsPublication(_ id: UUID) -> Bool { lock.withLock { stopAt == nil && !finished && readID == id } }
    func requestStop() {
        lock.withLock {
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime }
            if descriptor >= 0 {
                var byte: UInt8 = 83
                _ = Darwin.send(descriptor, &byte, 1, MSG_DONTWAIT)
            }
        }
    }
    private func write(_ value: String) throws {
        try write(Data(value.utf8))
    }
    private func write(_ data: Data) throws {
        try lock.withLock {
            guard stopAt == nil, descriptor >= 0 else { throw SMBWorkerFailure.stopped }
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            #if DEBUG
            if count > 0 { SFTPGeneratedBackendObservation.shared.protocolTransferred() }
            #endif
            guard count == data.count else {
                _ = shutdown(descriptor, SHUT_WR) // A partial private input cannot await a later Stop byte inside a line.
                throw SMBWorkerFailure.unavailable
            }
        }
    }
    func launch() throws {
        #if DEBUG
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        guard lock.withLock({ stopAt == nil }) else { throw SMBWorkerFailure.stopped }
        lease = try activity.begin()
        let helper = bundle.appendingPathComponent(profile.authenticated ? "Contents/Helpers/smb-auth-worker" : "Contents/Helpers/smb-metadata-worker")
        let info = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let expected = value[profile.authenticated ? "MacExplorerSMBAuthQualificationSHA256" : "MacExplorerSMBQualificationSHA256"] as? String,
              expected.count == 64 else { throw SMBWorkerFailure.unavailable }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw SMBWorkerFailure.unavailable }
        let opened = Darwin.open(helper.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard opened >= 0 else { throw SMBWorkerFailure.unavailable }
        defer { Darwin.close(opened) }
        var facts = stat()
        guard fstat(opened, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1,
              facts.st_size > 0, facts.st_size <= 16 << 20 else { throw SMBWorkerFailure.unavailable }
        var source = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(opened, &bytes, bytes.count)
            guard count >= 0 else { throw SMBWorkerFailure.unavailable }
            if count == 0 { break }; source.append(contentsOf: bytes.prefix(count))
            guard source.count <= 16 << 20 else { throw SMBWorkerFailure.unavailable }
        }
        guard SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == expected else { throw SMBWorkerFailure.unavailable }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SMBWorkerFailure.unavailable }
        defer { if pair[0] >= 0 { Darwin.close(pair[0]) }; Darwin.close(pair[1]) }
        // Normalize away from child0...2 and close every unrelated descriptor.
        for index in 0..<2 {
            let copy = fcntl(pair[index], F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw SMBWorkerFailure.unavailable }
            Darwin.close(pair[index]); pair[index] = copy
            var one: Int32 = 1
            guard setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SMBWorkerFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SMBWorkerFailure.unavailable }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SMBWorkerFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SMBWorkerFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              sigaddset(&defaults, SIGINT) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { throw SMBWorkerFailure.unavailable }
        var argv = [helper.path, "--ipc-worker"].map { strdup($0) } + [nil]
        var env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        guard !argv.dropLast().contains(where: { $0 == nil }), !env.dropLast().contains(where: { $0 == nil }) else { throw SMBWorkerFailure.unavailable }
        var child: pid_t = 0
        let result = helper.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&child, $0, &actions, &attributes, &argv, &env) } ?? EINVAL
        }
        guard result == 0 else { throw SMBWorkerFailure.unavailable }
        lock.withLock { descriptor = pair[0]; pid = child }; pair[0] = -1
        switch profile {
        case .guestQualification: try write("MEXSMB1 START \(sessionID.uuidString)\n")
        case .authenticated(let policy):
            defer { privateCredentialInput = nil }
            guard let input = privateCredentialInput else { throw SMBWorkerFailure.unavailable }
            try write("MEXSMB2 START \(sessionID.uuidString) \(policy.rawValue) \(share.rawValue)\n")
            try write(input)
        }
    }
    func waitConnected() throws {
        let began = ProcessInfo.processInfo.systemUptime
        while true {
            guard ProcessInfo.processInfo.systemUptime - began <= 12 else { throw SMBWorkerFailure.deadline }
            if let event = try nextEvent() {
                if case .connected = event { lock.withLock { actualSecurity = decoder.security }; return }
                if case .closed(let result) = event { throw failure(result) }
                throw SMBWorkerFailure.invalidOutput
            }
        }
    }
    func read(id: UUID, nested: Bool, onPage: @Sendable (SMBWorkerPage) -> Void) throws -> Int {
        try write("READ \(id.uuidString) \(nested ? "0046006f006c006400650072" : "-")\n")
        try decoder.beginRead(id)
        let began = ProcessInfo.processInfo.systemUptime
        while true {
            guard ProcessInfo.processInfo.systemUptime - began <= 30 else { throw SMBWorkerFailure.deadline }
            if let event = try nextEvent() {
                switch event {
                case .page(let page):
                    if allowsPublication(id) { onPage(page); try write("N") }
                case .readEnd(let completed, let count):
                    guard completed == id, allowsPublication(id) else { throw SMBWorkerFailure.stopped }; return count
                case .closed(let result): throw failure(result)
                case .connected: throw SMBWorkerFailure.invalidOutput
                }
            }
        }
    }
    private func failure(_ result: SMBWorkerTerminal) -> SMBWorkerFailure {
        switch result.outcome {
        case "stopped": .stopped
        case "remote-error": .remote
        case "request-deadline": .deadline
        case "authentication": .authentication
        case "denied": .denied
        case "security": .security
        default: .invalidOutput
        }
    }
    private func nextEvent() throws -> SMBWorkerEvent? {
        if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }
        let fd = lock.withLock { descriptor }
        guard fd >= 0, !eof else { throw SMBWorkerFailure.workerExited }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 20)
        if ready < 0 && errno != EINTR { throw SMBWorkerFailure.unavailable }
        if ready > 0 {
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { eof = true; throw SMBWorkerFailure.workerExited }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return nil }; throw SMBWorkerFailure.unavailable
            }
            #if DEBUG
            SFTPGeneratedBackendObservation.shared.protocolTransferred()
            #endif
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if let event = try decoder.consume(buffer) { pendingEvents.append(event) }
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    guard buffer.count < 16_512 else { throw SMBWorkerFailure.invalidOutput }; buffer.append(byte)
                }
            }
            guard pendingEvents.count <= 256 else { throw SMBWorkerFailure.invalidOutput }
        }
        return pendingEvents.isEmpty ? nil : pendingEvents.removeFirst()
    }
    func finish() -> SMBWorkerCloseResult {
        privateCredentialInput = nil
        if lock.withLock({ finished }) { return closeResult() }
        requestStop()
        let began = ProcessInfo.processInfo.systemUptime
        let child = lock.withLock { pid }
        if child > 0 {
            while exitStatus == nil || !eof {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed > 2 && !contained { contained = true; _ = kill(child, SIGTERM) }
                if elapsed > 3 && exitStatus == nil { _ = kill(child, SIGKILL) }
                if exitStatus == nil {
                    var status: Int32 = 0
                    let found = waitpid(child, &status, WNOHANG)
                    if found == child { exitStatus = status }
                    else if found < 0 && errno != EINTR { contained = true; break }
                }
                if !eof { _ = try? nextEvent() }
                else if exitStatus == nil { _ = poll(nil, 0, 20) }
                if elapsed > 5 { contained = true; break }
            }
        }
        lock.withLock {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            finished = true
        }
        // A failed wait never claims actual drain or releases this lifetime.
        // The known child has been reaped in every passing qualification path.
        if child == 0 || exitStatus != nil {
            lease = nil; SMBWorkerAdmission.shared.release(self)
        }
        return closeResult()
    }
    private func closeResult() -> SMBWorkerCloseResult {
        SMBWorkerCloseResult(exitStatus: exitStatus, actualExit: exitStatus != nil,
            localDrainProved: exitStatus == 0 && eof && buffer.isEmpty && decoder.terminal?.provesDrain == true && !contained,
            forcedContainment: contained, diagnostics: decoder.terminal.map {
                SMBWorkerDiagnostics(outcome: $0.outcome, joined: $0.joined, pending: $0.pending,
                    tasks: $0.tasks, observed: $0.observed, drainMicroseconds: $0.drainMicroseconds, commands: $0.commands)
            })
    }
}
