import Darwin
import ExplorerCore
import Foundation

/// Explicit preparation for one app-owned state leaf. Construction is inert;
/// callers must not invoke prepare from passive history or startup inspection.
public final class PrivateStateDirectory: @unchecked Sendable {
    private let directory: URL
    private let activity: FileActivityGate?
    private let requireNew: Bool
    private let queue = DispatchQueue(label: "MacExplorer.StatePreparation", qos: .utility)
    private let admission = NSLock()
    private var submitted = false
    // Accessed only by this object's serial worker. These are identity pins,
    // never cached access/freshness decisions.
    private var established: Identity?
    private var establishedParent: Identity?
    private let probe: (@Sendable (Stage) throws -> Void)?
    enum Stage: Sendable { case beforeCreate, created, beforeSync, synchronized }
    public init(directory: URL, activity: FileActivityGate? = nil, requireNew: Bool = false) {
        self.directory = directory; self.activity = activity; self.probe = nil; self.requireNew = requireNew
    }
    init(directory: URL, activity: FileActivityGate? = nil, probe: @escaping @Sendable (Stage) throws -> Void) {
        self.directory = directory; self.activity = activity; self.probe = probe; self.requireNew = false
    }

    public func prepare() async throws {
        try Task.checkCancellation()
        guard admission.withLock({ if submitted { return false }; submitted = true; return true }) else {
            throw StateDirectoryPreparationError.busy
        }
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    let result: Result<Void, Error> = Result {
                        try cancellation.check()
                        let lease = try activity?.begin()
                        defer { withExtendedLifetime(lease) {} }
                        try prepare(cancellation)
                    }
                    // Resume only after native work, descriptors and activity
                    // have drained, including when the awaiting task cancels.
                    admission.withLock { submitted = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
    }

    /// For an already bounded background writer that must preserve its serial
    /// ordering. This never dispatches back onto that writer or the main actor.
    /// Prefer prepare() from async callers. Both entries share admission/pins.
    public func prepareFromBackgroundThread() throws {
        guard !Thread.isMainThread else { throw StateDirectoryPreparationError.requiresBackgroundWorker }
        guard admission.withLock({ if submitted { return false }; submitted = true; return true }) else {
            throw StateDirectoryPreparationError.busy
        }
        defer { admission.withLock { submitted = false } }
        let lease = try activity?.begin()
        defer { withExtendedLifetime(lease) {} }
        try prepare(Cancellation())
    }

    private func prepare(_ cancellation: Cancellation) throws {
        let decodedPath = URLComponents(url: directory, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              let decodedPath, !decodedPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              directory.standardizedFileURL.path == directory.path,
              !directory.path.utf8.contains(0) else { throw StateDirectoryPreparationError.invalidLocation }
        let parentURL = directory.deletingLastPathComponent(), name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw StateDirectoryPreparationError.invalidLocation }
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw StateDirectoryPreparationError.unavailable }
        defer { close(parent) }
        let parentIdentity = try identity(parent)
        if let establishedParent, establishedParent != parentIdentity { throw StateDirectoryPreparationError.changed }
        var prior = stat()
        let exists = fstatat(parent, name, &prior, AT_SYMLINK_NOFOLLOW) == 0
        if exists, requireNew, established == nil { throw StateDirectoryPreparationError.unsafeState }
        if !exists {
            guard errno == ENOENT, established == nil else { throw StateDirectoryPreparationError.changed }
            try probe?(.beforeCreate)
            try cancellation.check()
            // Never repair arbitrary missing ancestors, chmod existing state,
            // or accept a raced EEXIST as the directory we just created.
            guard mkdirat(parent, name, 0o700) == 0 else { throw StateDirectoryPreparationError.unavailable }
        }
        let leaf = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard leaf >= 0 else { throw StateDirectoryPreparationError.unsafeState }
        defer { close(leaf) }
        let current = try identity(leaf)
        if exists {
            guard current == Identity(prior) else { throw StateDirectoryPreparationError.changed }
        }
        if let established, established != current { throw StateDirectoryPreparationError.changed }
        try validateNamespace(parentURL, parent: parentIdentity, leaf: current)
        // Pin even if cancellation or synchronization fails next: a subsequent
        // replacement must not silently create/adopt fresh operation history.
        established = current; establishedParent = parentIdentity
        if !exists { try probe?(.created) }
        try cancellation.check()
        try probe?(.beforeSync)
        guard fsync(leaf) == 0, fsync(parent) == 0 else { throw StateDirectoryPreparationError.unavailable }
        try validateNamespace(parentURL, parent: parentIdentity, leaf: current)
        try probe?(.synchronized)
        try cancellation.check()
    }

    private func validateNamespace(_ parentURL: URL, parent: Identity, leaf: Identity) throws {
        let fresh = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fresh >= 0 else { throw StateDirectoryPreparationError.changed }
        defer { close(fresh) }
        guard try identity(fresh) == parent else { throw StateDirectoryPreparationError.changed }
        let freshLeaf = openat(fresh, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard freshLeaf >= 0 else { throw StateDirectoryPreparationError.changed }
        defer { close(freshLeaf) }
        guard try identity(freshLeaf) == leaf else { throw StateDirectoryPreparationError.changed }
    }

    private func identity(_ descriptor: Int32) throws -> Identity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw StateDirectoryPreparationError.unavailable }
        // Existing owner-created 0755 state remains valid; preparation does not
        // relabel it. Group/world-writable state or a foreign owner is refused.
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else { throw StateDirectoryPreparationError.unsafeState }
        return Identity(info)
    }

    private struct Identity: Equatable {
        let device: Int32, inode: UInt64, generation: UInt32
        let birthSeconds: Int, birthNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; generation = info.st_gen
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.withLock { stopped = true } }
        func check() throws { if lock.withLock({ stopped }) { throw CancellationError() } }
    }
}

public enum StateDirectoryPreparationError: Error, LocalizedError, Sendable {
    case invalidLocation, unavailable, unsafeState, changed, busy, requiresBackgroundWorker
    public var errorDescription: String? {
        switch self {
        case .changed, .unsafeState: "Mac Explorer’s operation folder changed or is not securely owned. Existing files were preserved; review the app’s storage location."
        case .busy: "Mac Explorer is still preparing its operation folder. Try again when preparation finishes."
        case .requiresBackgroundWorker: "Private storage preparation requires its background worker."
        case .invalidLocation, .unavailable: "Mac Explorer couldn’t prepare its operation folder. Check that the app’s storage drive is available and writable."
        }
    }
}
