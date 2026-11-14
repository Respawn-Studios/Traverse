import Darwin
import ExplorerCore
import Foundation

/// Internal observations only: no descriptor, mutation capability, server trust,
/// mount ownership or URL suitable for general filesystem browsing is exposed.
internal struct SMBMountObservation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Object: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let generation: UInt32
        let kind: UInt16
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = value.st_ino; generation = value.st_gen
            kind = value.st_mode & S_IFMT
            birthSeconds = Int64(value.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        }
        init(device: Int64, inode: UInt64, generation: UInt32 = 0, kind: UInt16 = UInt16(S_IFDIR),
             birthSeconds: Int64 = 0, birthNanoseconds: Int64 = 0) {
            self.device = device; self.inode = inode; self.generation = generation; self.kind = kind
            self.birthSeconds = birthSeconds; self.birthNanoseconds = birthNanoseconds
        }
    }
    let object: Object
    let fileSystemID: Int32
    let fileSystemIDExtra: Int32
    let flags: UInt32
    // Raw bytes avoid Swift String's canonical-equivalence comparison treating
    // different native source/root spellings as the same observation.
    let fileSystem: Data
    let root: Data
    let source: Data
    var description: String { "SMB mount observation" }
    var debugDescription: String { description }

    func validate(root expected: SMBMountPath) throws {
        guard object.kind == UInt16(S_IFDIR), object.inode != 0,
              root == expected.bytes else { throw SMBConnectionProblem.invalidResult }
        guard fileSystem == Data("smbfs".utf8), flags & UInt32(MNT_LOCAL) == 0 else { throw SMBConnectionProblem.notSMB }
        guard flags & UInt32(MNT_RDONLY) != 0 else { throw SMBConnectionProblem.writableMount }
        guard (3...4095).contains(source.count), source.starts(with: [47, 47]), !source.contains(0),
              String(data: source, encoding: .utf8) != nil else { throw SMBConnectionProblem.invalidResult }
    }
    static func admitted(root: SMBMountPath, first: Self, reopened: Self, last: Self) throws -> Self {
        try first.validate(root: root); try reopened.validate(root: root); try last.validate(root: root)
        guard first == reopened, first == last else { throw SMBConnectionProblem.changed }
        return first
    }
}

/// Lexical admission performs no DNS, resolving, resource query or file opening.
internal struct SMBMountPath: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let path: String
    let bytes: Data
    var description: String { "SMB mount path" }
    var debugDescription: String { description }
    init(_ url: URL) throws {
        guard url.baseURL == nil, url.isFileURL, url.host == nil || url.host == "",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.absoluteString.utf8.count <= 16_384,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decoded = encoded.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SMBConnectionProblem.invalidResult }
        let path = url.path
        guard path.hasPrefix("/"), (2...4095).contains(path.utf8.count),
              !path.hasPrefix("/.file/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw SMBConnectionProblem.invalidResult }
        // Already checked lexically. Foundation's filesystem standardizer can
        // resolve /private/tmp to /tmp and touch the filesystem on this caller.
        // Native root/identity validation belongs to the bounded worker below.
        self.path = path; bytes = Data(path.utf8)
    }
}

/// At most four actual/queued probes, on one blocking-filesystem worker. A
/// cancelled task does not complete early or drop its lease while a syscall runs.
internal final class SMBMountObserver: @unchecked Sendable {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }
    private let queue = DispatchQueue(label: "MacExplorer.SMBMountObservation", qos: .userInitiated)
    private let lock = NSLock()
    private var outstanding = 0
    private let activity: FileActivityGate?
    private let probe: @Sendable (SMBMountPath) throws -> SMBMountObservation
    var outstandingCount: Int { lock.withLock { outstanding } }
    init(activity: FileActivityGate? = nil) { self.activity = activity; probe = Self.probe }
    init(activity: FileActivityGate? = nil, probe: @escaping @Sendable (SMBMountPath) throws -> SMBMountObservation) {
        self.activity = activity; self.probe = probe
    }
    func observe(_ url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> SMBMountObservation {
        let path = try SMBMountPath(url)
        try Task.checkCancellation()
        try lock.withLock {
            guard outstanding < 4 else { throw SMBConnectionProblem.busy }
            outstanding += 1
        }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result = Result<SMBMountObservation, Error> {
                        defer { withExtendedLifetime(lifetime) {} }
                        try cancellation.check()
                        let lease = try activity?.begin()
                        defer { withExtendedLifetime(lease) {} }
                        let value = try probe(path)
                        try cancellation.check()
                        return value
                    }
                    lock.withLock { outstanding -= 1 }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func probe(_ path: SMBMountPath) throws -> SMBMountObservation {
        func openRoot() throws -> Int32 {
            let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw errno == EACCES || errno == EPERM ? SMBConnectionProblem.denied : .unavailable }
            return fd
        }
        let held = try openRoot(); defer { Darwin.close(held) }
        let first = try observeDescriptor(held)
        // Refuse a local/writable/subdirectory result before another path open.
        try first.validate(root: path)
        let fresh = try openRoot(); defer { Darwin.close(fresh) }
        return try .admitted(root: path, first: first, reopened: observeDescriptor(fresh), last: observeDescriptor(held))
    }
    private static func observeDescriptor(_ fd: Int32) throws -> SMBMountObservation {
        var object = stat(), fs = statfs()
        guard fstat(fd, &object) == 0, fstatfs(fd, &fs) == 0 else { throw SMBConnectionProblem.unavailable }
        func bytes<T>(_ field: T) throws -> Data {
            try withUnsafeBytes(of: field) { raw in
                guard let end = raw.firstIndex(of: 0) else { throw SMBConnectionProblem.invalidResult }
                return Data(raw[..<end])
            }
        }
        return try .init(object: .init(object), fileSystemID: fs.f_fsid.val.0, fileSystemIDExtra: fs.f_fsid.val.1,
            flags: fs.f_flags, fileSystem: bytes(fs.f_fstypename), root: bytes(fs.f_mntonname), source: bytes(fs.f_mntfromname))
    }
}
