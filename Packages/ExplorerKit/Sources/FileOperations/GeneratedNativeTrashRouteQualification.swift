#if DEBUG
import Darwin
import Foundation
import CryptoKit

/// Draft only: integrate after App114 and a fresh source/resource review.
/// The default LocalFileOperations convenience initializer remains the sole
/// FileManager.trashItem call site. This gate only counts it and, in warm mode,
/// observes bounded metadata from its exact returned generated object.
@_spi(Qualification) public enum GeneratedNativeTrashMode: String, Sendable {
    case cold, warm
}

@_spi(Qualification) public struct GeneratedNativeTrashCallSnapshot: Sendable {
    public let calls: Int
    public let returned: Int
    public let thrown: Int
    public let warmCompleted: Int
    public let warmIdentityRefused: Int
    public let warmReadRefused: Int
    public let warmBoundRefused: Int
}

@_spi(Qualification) public final class GeneratedNativeTrashRouteSession: @unchecked Sendable {
    fileprivate struct Armed {
        let source: URL
        let ordinal: Int
        let identity: EntrySnapshot
    }
    private let root: URL
    private let mode: GeneratedNativeTrashMode
    private let markerSHA256: String
    private let authoritySHA256: String
    private let lock = NSLock()
    private var armed: Armed?
    private var usedOrdinals = Set<Int>()
    private var calls = 0
    private var returned = 0
    private var thrown = 0
    private var warmCompleted = 0
    private var warmIdentityRefused = 0
    private var warmReadRefused = 0
    private var warmBoundRefused = 0

    fileprivate init(root: URL, mode: GeneratedNativeTrashMode,
                     markerSHA256: String, authoritySHA256: String) {
        self.root = root; self.mode = mode
        self.markerSHA256 = markerSHA256; self.authoritySHA256 = authoritySHA256
    }

    /// Arm exactly one generated regular file after the previous Browser task
    /// has actually drained. No URL outside Input can reach the native call.
    @_spi(Qualification) public func arm(_ source: URL) throws {
        let marker = try GeneratedNativeTrashRouteFactory.privateBytes(root.appendingPathComponent("reservation.json"))
        let authority = try GeneratedNativeTrashRouteFactory.privateBytes(root.appendingPathComponent("native-authority.json"))
        guard GeneratedNativeTrashRouteFactory.sha(marker) == markerSHA256,
              GeneratedNativeTrashRouteFactory.sha(authority) == authoritySHA256 else {
            throw FileOperationFailure.invalidRequest
        }
        let stem = source.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("Generated-"),
              let ordinal = Int(stem.dropFirst("Generated-".count)) else {
            throw FileOperationFailure.invalidRequest
        }
        var rootFacts = stat()
        guard source.deletingLastPathComponent().path == root.appendingPathComponent("Input").path,
              source.resolvingSymlinksInPath().path == source.path,
              (1...4).contains(ordinal),
              source.pathExtension == "dmg" else { throw FileOperationFailure.invalidRequest }
        var facts = stat()
        guard lstat(root.path, &rootFacts) == 0,
              lstat(source.path, &facts) == 0,
              facts.st_mode & S_IFMT == S_IFREG,
              facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_mode & 0o077 == 0, facts.st_size >= 0, facts.st_size <= 16 << 10,
              facts.st_dev == rootFacts.st_dev else { throw FileOperationFailure.invalidRequest }
        guard let fields = try JSONSerialization.jsonObject(with: marker) as? [String: Any],
              let expected = fields["sha256-\(ordinal)"] as? String else {
            throw FileOperationFailure.invalidRequest
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_dev == facts.st_dev, opened.st_ino == facts.st_ino,
              opened.st_size == facts.st_size,
              opened.st_birthtimespec.tv_sec == facts.st_birthtimespec.tv_sec,
              opened.st_birthtimespec.tv_nsec == facts.st_birthtimespec.tv_nsec else {
            throw FileOperationFailure.invalidRequest
        }
        let identity = try EntrySnapshot(fd: fd)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let body = try handle.read(upToCount: (16 << 10) + 1),
              body.count == Int(facts.st_size),
              GeneratedNativeTrashRouteFactory.sha(body) == expected else {
            throw FileOperationFailure.invalidRequest
        }
        lock.lock(); defer { lock.unlock() }
        guard armed == nil, calls < 4, !usedOrdinals.contains(ordinal) else {
            throw FileOperationFailure.invalidRequest
        }
        armed = Armed(source: source, ordinal: ordinal, identity: identity)
    }

    @_spi(Qualification) public func disarm() {
        lock.withLock { armed = nil }
    }

    @_spi(Qualification) public func finishAfterDrain() {
        NativeTrashQualificationGate.shared.finish(self)
    }

    @_spi(Qualification) public var snapshot: GeneratedNativeTrashCallSnapshot {
        lock.withLock {
            .init(calls: calls, returned: returned, thrown: thrown,
                  warmCompleted: warmCompleted,
                  warmIdentityRefused: warmIdentityRefused,
                  warmReadRefused: warmReadRefused,
                  warmBoundRefused: warmBoundRefused)
        }
    }

    fileprivate func beforeNative(_ source: URL) throws -> NativeTrashQualificationWitness {
        lock.lock(); defer { lock.unlock() }
        let marker = try GeneratedNativeTrashRouteFactory.privateBytes(root.appendingPathComponent("reservation.json"))
        let authority = try GeneratedNativeTrashRouteFactory.privateBytes(root.appendingPathComponent("native-authority.json"))
        var live = stat()
        guard let armed, armed.source.path == source.path, calls < 4,
              GeneratedNativeTrashRouteFactory.sha(marker) == markerSHA256,
              GeneratedNativeTrashRouteFactory.sha(authority) == authoritySHA256,
              lstat(source.path, &live) == 0,
              live.st_mode & S_IFMT == S_IFREG,
              live.st_uid == geteuid(), live.st_mode & 0o077 == 0,
              live.st_size >= 0, live.st_size <= 16 << 10,
              live.st_dev == armed.identity.device, live.st_ino == armed.identity.inode,
              live.st_birthtimespec.tv_sec == armed.identity.birthSeconds,
              live.st_birthtimespec.tv_nsec == armed.identity.birthNanos,
              live.st_nlink == 1 else {
            throw FileOperationFailure.invalidRequest
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        guard try EntrySnapshot(fd: fd).sameObject(as: armed.identity) else {
            throw FileOperationFailure.invalidRequest
        }
        // Consume the arm before invoking FileManager. A retry, or a second
        // adapter invocation for this Browser command, cannot spend it again.
        self.armed = nil
        usedOrdinals.insert(armed.ordinal)
        calls += 1
        return .init(session: self, identity: armed.identity, warm: mode == .warm)
    }

    fileprivate func noteThrow() { lock.withLock { thrown += 1 } }

    fileprivate func noteReturn(_ target: URL?, witness: NativeTrashQualificationWitness) {
        lock.withLock { returned += target == nil ? 0 : 1 }
        guard witness.warm, let target else { return }
        // The observation cannot throw into the real adapter result. A refusal
        // is a closed sidecar status; the engine retains its normal checks.
        switch Self.observeMetadata(target, identity: witness.identity) {
        case .complete: lock.withLock { warmCompleted += 1 }
        case .identity: lock.withLock { warmIdentityRefused += 1 }
        case .read: lock.withLock { warmReadRefused += 1 }
        case .bound: lock.withLock { warmBoundRefused += 1 }
        }
    }

    private enum WarmOutcome { case complete, identity, read, bound }
    /// A narrow timing control: same-object stat/birth and bounded xattr
    /// names/values only. It does not read body bytes, ACLs or siblings and
    /// does not recreate VerifiedTree's full fingerprint walk.
    private static func observeMetadata(_ target: URL, identity: EntrySnapshot) -> WarmOutcome {
        guard target.isFileURL, target.resolvingSymlinksInPath().path == target.path else { return .identity }
        var before = stat()
        guard lstat(target.path, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == identity.device, before.st_ino == identity.inode,
              before.st_birthtimespec.tv_sec == identity.birthSeconds,
              before.st_birthtimespec.tv_nsec == identity.birthNanos,
              before.st_nlink == 1 else { return .identity }
        let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .read }
        defer { close(fd) }
        var live = stat()
        guard fstat(fd, &live) == 0,
              (try? EntrySnapshot(fd: fd).sameObject(as: identity)) == true,
              live.st_nlink == 1 else { return .identity }
        let namesLength = flistxattr(fd, nil, 0, 0)
        guard namesLength >= 0 else { return .read }
        guard namesLength <= 4096 else { return .bound }
        var names = [CChar](repeating: 0, count: max(1, namesLength))
        guard flistxattr(fd, &names, namesLength, 0) == namesLength else { return .read }
        var metadataBytes = 0
        for raw in names.prefix(namesLength).split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0 else { return .read }
            guard size <= (64 << 10) - metadataBytes else { return .bound }
            metadataBytes += size
            var value = Data(count: size)
            let read = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { return .read }
        }
        // No body bytes, path, xattr name/value or raw errno leave this scope.
        return .complete
    }
}

struct NativeTrashQualificationWitness {
    let session: GeneratedNativeTrashRouteSession
    let identity: EntrySnapshot
    let warm: Bool
    func noteThrow() { session.noteThrow() }
    func noteReturn(_ target: URL?) { session.noteReturn(target, witness: self) }
}

/// Visible only to the one DEBUG default-adapter call site.
final class NativeTrashQualificationGate: @unchecked Sendable {
    static let shared = NativeTrashQualificationGate()
    private let lock = NSLock()
    private var active: GeneratedNativeTrashRouteSession?

    func install(_ session: GeneratedNativeTrashRouteSession) throws {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw FileOperationFailure.unavailable }
        active = session
    }
    func finish(_ session: GeneratedNativeTrashRouteSession) {
        lock.withLock { if active === session { active = nil } }
    }
    func beforeNative(_ source: URL) throws -> NativeTrashQualificationWitness? {
        let session = lock.withLock { active }
        if ProcessInfo.processInfo.arguments.contains("--check-trash-app-route-native") {
            guard let session else { throw FileOperationFailure.invalidRequest }
            return try session.beforeNative(source)
        }
        return try session?.beforeNative(source)
    }
}

@_spi(Qualification) public enum GeneratedNativeTrashRouteFactory {
    @_spi(Qualification) public static func make(root: URL, mode: GeneratedNativeTrashMode,
        activity: (@Sendable () throws -> any Sendable)? = nil)
        throws -> (RecoverableFileOperations, GeneratedNativeTrashRouteSession) {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard root.isFileURL, root.resolvingSymlinksInPath().path == root.path,
              root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-development").path,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              privateDirectory(root), privateDirectory(root.appendingPathComponent("Input")),
              privateDirectory(root.appendingPathComponent("State")),
              privateFile(root.appendingPathComponent("reservation.json")),
              privateFile(root.appendingPathComponent("native-authority.json")) else {
            throw FileOperationFailure.invalidRequest
        }
        let markerData = try privateBytes(root.appendingPathComponent("reservation.json"))
        let authorityData = try privateBytes(root.appendingPathComponent("native-authority.json"))
        guard let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              let authority = try JSONSerialization.jsonObject(with: authorityData) as? [String: Any]
        else { throw FileOperationFailure.invalidRequest }
        guard marker["packet"] as? String == "traverse-native-trash-browser-v1",
              marker["mode"] as? String == mode.rawValue,
              let sessionIndex = marker["sessionIndex"] as? Int,
              (1...3).contains(sessionIndex),
              mode == (sessionIndex == 2 ? .warm : .cold),
              let profileSet = marker["profileSet"] as? String,
              profileSet == (sessionIndex == 3 ? "marked" : "plain"),
              marker["maximumNativeCalls"] as? Int == 4,
              marker["maximumGeneratedBodyBytes"] as? Int == 64 << 10,
              marker["maximumReturnedEntries"] as? Int == 16,
              authority["approved"] as? Bool == true,
              authority["case"] as? String == root.lastPathComponent,
              authority["reservationSHA256"] as? String == sha(markerData),
              authority["sessionIndex"] as? Int == sessionIndex,
              authority["profileSet"] as? String == profileSet,
              authority["maximumNativeCalls"] as? Int == 4,
              authority["mode"] as? String == mode.rawValue else {
            throw FileOperationFailure.invalidRequest
        }
        let session = GeneratedNativeTrashRouteSession(root: root, mode: mode,
            markerSHA256: sha(markerData), authoritySHA256: sha(authorityData))
        try NativeTrashQualificationGate.shared.install(session)
        let state = root.appendingPathComponent("State")
        let engine = RecoverableFileOperations(journalDirectory: state.appendingPathComponent("operations"),
            hooks: RecoveryHooks(), legacy: LocalFileOperations(activity: activity),
            protecting: [state], activity: activity)
        return (engine, session)
    }

    private static func privateDirectory(_ url: URL) -> Bool {
        guard url.resolvingSymlinksInPath().path == url.path else { return false }
        var facts = stat()
        return lstat(url.path, &facts) == 0 && facts.st_mode & S_IFMT == S_IFDIR
            && facts.st_uid == geteuid() && facts.st_mode & 0o077 == 0
    }
    private static func privateFile(_ url: URL) -> Bool {
        guard url.resolvingSymlinksInPath().path == url.path else { return false }
        var facts = stat()
        return lstat(url.path, &facts) == 0 && facts.st_mode & S_IFMT == S_IFREG
            && facts.st_uid == geteuid() && facts.st_mode & 0o077 == 0
            && facts.st_nlink == 1 && facts.st_size <= 4096
    }
    fileprivate static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    fileprivate static func privateBytes(_ url: URL) throws -> Data {
        guard privateFile(url) else { throw FileOperationFailure.invalidRequest }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        var facts = stat()
        guard fstat(fd, &facts) == 0,
              facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(),
              facts.st_mode & 0o077 == 0, facts.st_nlink == 1,
              facts.st_size <= 4096 else { throw FileOperationFailure.invalidRequest }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try input.read(upToCount: 4097), data.count <= 4096 else {
            throw FileOperationFailure.invalidRequest
        }
        return data
    }
}
#endif
