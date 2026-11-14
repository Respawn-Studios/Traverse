import Darwin
import Foundation

/// Serial, off-main local mutations. Cancellation returns only after the worker has stopped,
/// allowing the caller to retain security-scoped access for the entire operation.
/// Descriptor-relative no-follow mutation and exclusive commits prevent silent replacement.
/// Source entry replacement after the last check is detected after rename. A mismatched
/// destination is preserved and reported for recovery; no inode-conditional rename is available.
public final class LocalFileOperations: @unchecked Sendable {
    private let queue: OperationQueue
    private let trash: @Sendable (URL) throws -> URL?
    private let hooks: OperationHooks
    private let activity: (@Sendable () throws -> any Sendable)?

    public convenience init(activity: (@Sendable () throws -> any Sendable)? = nil) {
        self.init(trash: { url in
            #if DEBUG
            let qualification = try NativeTrashQualificationGate.shared.beforeNative(url)
            #endif
            var result: NSURL?
            do {
                try FileManager().trashItem(at: url, resultingItemURL: &result)
            } catch {
                #if DEBUG
                qualification?.noteThrow()
                #endif
                throw error
            }
            #if DEBUG
            qualification?.noteReturn(result as URL?)
            #endif
            return result as URL?
        }, activity: activity)
    }

    internal init(trash: @escaping @Sendable (URL) throws -> URL?, hooks: OperationHooks = OperationHooks(),
                  activity: (@Sendable () throws -> any Sendable)? = nil) {
        self.trash = trash
        self.hooks = hooks
        self.activity = activity
        queue = OperationQueue()
        queue.name = "MacExplorer.FileOperations"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public func perform(_ request: FileOperationRequest, observing selection: FileOperationSelection? = nil) async -> FileOperationResult {
        let cancellation = OperationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation { [self] in
                    let result: FileOperationResult
                    do {
                        try cancellation.check()
                        let activity = try activity?()
                        defer { withExtendedLifetime(activity) {} }
                        result = execute(request, observing: selection, cancellation: cancellation)
                    } catch {
                        result = FileOperationResult(items: [FileOperationOutcome(source: nil, destination: nil,
                            status: operationStatus(error), recoveryURLs: [])], cancellationRequested: cancellation.isCancelled)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Observational only. A clean preflight never substitutes for exclusive commit checks.
    public func conflicts(for request: FileOperationRequest, observing selection: FileOperationSelection? = nil) async throws -> [URL] {
        try await observe { cancellation in
            try cancellation.check()
            return try self.makePlans(request, observing: selection, cancellation: cancellation).compactMap { plan in
                try cancellation.check()
                guard let destination = plan.destinationParent,
                      !(plan.kind == .rename && plan.source?.url == plan.destination) else { return nil }
                do { try requireAbsent(plan.name, in: destination.fd); return nil }
                catch FileOperationFailure.conflict { return plan.destination }
            }
        }
    }

    public func observeSelection(_ sources: [URL]) async throws -> FileOperationSelection {
        try await observe { cancellation in
            guard !sources.isEmpty else { throw FileOperationFailure.invalidRequest }
            let observed = try sources.map { url in
                try cancellation.check()
                return try observeObject(url)
            }
            return FileOperationSelection(urls: observed.map(\.url), identities: observed.map(\.snapshot))
        }
    }

    /// Captures the actual parent directory, including volume roots and explicit symlink aliases.
    public func observeDirectory(_ directory: URL) async throws -> FileOperationSelection {
        try await observe { cancellation in
            try cancellation.check()
            let anchor = try DirectoryAnchor(directory)
            return FileOperationSelection(urls: [anchor.url], identities: [anchor.identity])
        }
    }

    private func observe<T: Sendable>(_ action: @escaping @Sendable (OperationCancellation) throws -> T) async throws -> T {
        let cancellation = OperationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    do {
                        try cancellation.check()
                        let activity = try self.activity?()
                        defer { withExtendedLifetime(activity) {} }
                        let result = try action(cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    internal func execute(_ request: FileOperationRequest, observing selection: FileOperationSelection?, cancellation: OperationCancellation,
                          beforeMutation: (() throws -> Void)? = nil) -> FileOperationResult {
        let raw = request.inputs
        let plans: [Plan]
        do {
            try cancellation.check()
            plans = try makePlans(request, observing: selection, cancellation: cancellation)
            hooks.afterPreflight?()
        } catch {
            let status = operationStatus(error)
            let items = raw.isEmpty ? [FileOperationOutcome(source: nil, destination: nil, status: status, recoveryURLs: [])]
                : raw.map { FileOperationOutcome(source: $0, destination: nil, status: status, recoveryURLs: []) }
            return FileOperationResult(items: items, cancellationRequested: cancellation.isCancelled)
        }
        var items: [FileOperationOutcome] = []
        for plan in plans {
            defer { plan.source?.unpin() }
            var recovery: [URL] = []
            var staging: Stage?
            do {
                try cancellation.check()
                if plan.kind == .copy, let type = plan.source?.snapshot.type,
                   type != S_IFREG && type != S_IFDIR && type != S_IFLNK {
                    throw FileOperationFailure.unsupported
                }
                try plan.source?.pin()
                try plan.validate()
                switch plan.kind {
                case .create, .copy:
                    guard let destination = plan.destinationParent else { throw FileOperationFailure.invalidRequest }
                    try requireAbsent(plan.name, in: destination.fd)
                    let stage = try Stage(in: destination) { recovery = [$0] }
                    staging = stage
                    let expected: [String: TreeNode]
                    if plan.kind == .create {
                        guard mkdirat(stage.fd, "payload", 0o777) == 0 else { throw posixFailure() }
                        expected = try snapshotTree(parent: stage.fd, name: "payload", cancellation: cancellation)
                    } else {
                        guard let source = plan.source else { throw FileOperationFailure.invalidRequest }
                        var copied: [String: TreeNode] = [:]
                        try copyNode(sourceParent: source.parent.fd, sourceName: source.name,
                                     destinationParent: stage.fd, destinationName: "payload", relative: "",
                                     originalDevice: source.snapshot.device, cancellation: cancellation, observations: &copied)
                        expected = copied
                    }
                    let staged = try snapshotTree(parent: stage.fd, name: "payload", cancellation: cancellation)
                    guard equivalentCopies(expected, staged) else { throw FileOperationFailure.ioFailure }
                    hooks.beforeCommit?(plan.destination)
                    try cancellation.check()
                    try plan.validate()
                    try stage.validate(in: destination)
                    if let source = plan.source {
                        let current = try snapshotTree(parent: source.parent.fd, name: source.name, cancellation: cancellation)
                        guard current == expected else { throw FileOperationFailure.sourceChanged }
                    }
                    let committedIdentity = try EntrySnapshot(parent: stage.fd, name: "payload")
                    try exclusiveRename(from: stage.fd, name: "payload", to: destination.fd, name: plan.name)
                    hooks.afterCopyCommit?()
                    guard let actual = try? EntrySnapshot(parent: destination.fd, name: plan.name),
                          actual.sameObject(as: committedIdentity) else {
                        if let current = destination.currentURL?.appendingPathComponent(plan.name) { recovery.append(current) }
                        throw FileOperationFailure.recoveryUncertain
                    }
                    do { try destination.validate() }
                    catch {
                        if let actual = destination.currentURL?.appendingPathComponent(plan.name) { recovery.append(actual) }
                        throw FileOperationFailure.recoveryUncertain
                    }
                    // Remove only our now-empty staging directory using its anchored parent.
                    do {
                        try stage.validate(in: destination)
                        if unlinkat(destination.fd, stage.name, AT_REMOVEDIR) == 0 { recovery = [] }
                        else { recovery = stage.currentURL.map { [$0] } ?? [] }
                    } catch { recovery = stage.currentURL.map { [$0] } ?? [] }
                case .rename, .move:
                    guard let source = plan.source, let destination = plan.destinationParent else { throw FileOperationFailure.invalidRequest }
                    if source.url == plan.destination { break }
                    guard source.snapshot.device == (hooks.destinationDeviceOverride ?? destination.identity.device) else {
                        throw FileOperationFailure.crossVolumeMoveUnsupported
                    }
                    hooks.beforeCommit?(plan.destination)
                    try cancellation.check()
                    try plan.validate()
                    hooks.beforeRename?()
                    try exclusiveRename(from: source.parent.fd, name: source.name, to: destination.fd, name: plan.name)
                    hooks.afterRename?()
                    guard let observed = try? EntrySnapshot(parent: destination.fd, name: plan.name),
                          observed.sameObject(as: source.snapshot) else {
                        // This can mean either source substitution before rename or destination
                        // substitution afterwards. Moving the mismatched destination back would
                        // mutate an unrelated occupant. Preserve both current locations instead.
                        recovery = [source.parent.currentURL?.appendingPathComponent(source.name),
                                    destination.currentURL?.appendingPathComponent(plan.name)].compactMap { $0 }
                        throw FileOperationFailure.recoveryUncertain
                    }
                    do { try destination.validate() }
                    catch {
                        if let actual = destination.currentURL?.appendingPathComponent(plan.name) { recovery.append(actual) }
                        throw FileOperationFailure.recoveryUncertain
                    }
                case .trash:
                    guard let source = plan.source else { throw FileOperationFailure.invalidRequest }
                    hooks.beforeCommit?(nil)
                    try cancellation.check()
                    try plan.validate()
                    try beforeMutation?()
                    let result = try trash(source.url)
                    if let result {
                        recovery = [result]
                        do {
                            let parent = try DirectoryAnchor(result.deletingLastPathComponent())
                            let observed = try EntrySnapshot(parent: parent.fd, name: result.lastPathComponent)
                            guard observed.sameObject(as: source.snapshot) else { throw FileOperationFailure.recoveryUncertain }
                        } catch { throw FileOperationFailure.recoveryUncertain }
                        recovery = []
                    }
                    items.append(FileOperationOutcome(source: source.url, destination: result, status: .succeeded, recoveryURLs: []))
                    hooks.afterItem?()
                    continue
                }
                items.append(FileOperationOutcome(source: plan.source?.url, destination: plan.destination,
                                                  status: .succeeded, recoveryURLs: recovery))
            } catch {
                if let staging {
                    recovery = recovery.filter { $0 != staging.url } + (staging.currentURL.map { [$0] } ?? [])
                }
                items.append(FileOperationOutcome(source: plan.source?.url, destination: plan.destination,
                                                  status: operationStatus(error), recoveryURLs: recovery))
            }
            hooks.afterItem?()
        }
        return FileOperationResult(items: items, cancellationRequested: cancellation.isCancelled)
    }

    private func makePlans(_ request: FileOperationRequest, observing selection: FileOperationSelection? = nil,
                           cancellation: OperationCancellation) throws -> [Plan] {
        var guards: [String: ObservedGuard] = [:]
        if let selection {
            for (url, identity) in zip(selection.urls, selection.identities) {
                try cancellation.check()
                let observation = ObservedGuard(url: url, snapshot: identity)
                try observation.validate()
                guards[url.path] = observation
            }
        }
        hooks.afterObservationValidation?()
        let plans = try preparePlans(request, cancellation: cancellation)
        let referencePaths = Set(plans.flatMap { [$0.source?.url, $0.destinationParent?.url].compactMap { $0?.path } })
        guard guards.keys.allSatisfy(referencePaths.contains) else { throw FileOperationFailure.invalidRequest }
        return try plans.map { plan in
            var guarded = plan
            guarded.observations = [plan.source?.url, plan.destinationParent?.url]
                .compactMap { $0 }.compactMap { guards[$0.path] }
            // Bind the original token to prepared identities; observing a replacement during
            // preparation cannot supersede the pre-confirmation observation.
            for observation in guarded.observations {
                if let source = plan.source, observation.url.path == source.url.path,
                   !observation.matches(source.snapshot) { throw FileOperationFailure.sourceChanged }
                if let destination = plan.destinationParent, observation.url.path == destination.url.path,
                   !observation.matches(destination.identity) { throw FileOperationFailure.destinationChanged }
            }
            return guarded
        }
    }

    private func preparePlans(_ request: FileOperationRequest, cancellation: OperationCancellation) throws -> [Plan] {
        switch request {
        case .createFolder(let parent, let name):
            try validateName(name)
            return [Plan(kind: .create, source: nil, destinationParent: try DirectoryAnchor(parent), name: name)]
        case .rename(let source, let name):
            try validateName(name)
            let observed = try SourceObservation(source)
            return [Plan(kind: .rename, source: observed,
                         destinationParent: try DirectoryAnchor(observed.parentURL, resolve: false), name: name)]
        case .copy(let urls, let directory), .move(let urls, let directory):
            let sources = try validatedSources(urls, cancellation: cancellation)
            let destination = try DirectoryAnchor(directory)
            // Query the anchored destination itself, not a path that may have been replaced.
            // Unknown case rules use conservative folding; exclusive rename is authoritative.
            let caseSensitive = fpathconf(destination.fd, _PC_CASE_SENSITIVE) == 1
            var targetNames: Set<String> = []
            for source in sources {
                try cancellation.check()
                let targetName = caseSensitive ? source.name : source.name.folding(
                    options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                guard targetNames.insert(targetName).inserted else { throw FileOperationFailure.invalidRequest }
                if source.url.deletingLastPathComponent() == destination.url { throw FileOperationFailure.invalidRequest }
                if source.snapshot.isDirectory && isDescendant(destination.url.path, of: source.url.path) {
                    throw FileOperationFailure.invalidRequest
                }
            }
            let kind: Plan.Kind = if case .copy = request { .copy } else { .move }
            return sources.map { Plan(kind: kind, source: $0, destinationParent: destination, name: $0.name) }
        case .moveObserved(let selection, let directory):
            let plans = try makePlans(.move(sources: selection.urls, destinationDirectory: directory), cancellation: cancellation)
            guard plans.count == selection.identities.count,
                  zip(plans, selection.identities).allSatisfy({ $0.0.source?.snapshot == $0.1 }) else {
                throw FileOperationFailure.sourceChanged
            }
            return plans
        case .trash(let urls):
            return try validatedSources(urls, cancellation: cancellation).map { Plan(kind: .trash, source: $0, destinationParent: nil, name: $0.name) }
        }
    }
}

internal struct OperationHooks: Sendable {
    var afterPreflight: (@Sendable () -> Void)?
    var beforeCommit: (@Sendable (URL?) -> Void)?
    var afterItem: (@Sendable () -> Void)?
    var beforeRename: (@Sendable () -> Void)?
    var afterRename: (@Sendable () -> Void)?
    // Allows an EXDEV preflight decision to be exercised without mounting or touching another volume.
    var destinationDeviceOverride: dev_t?
    var afterCopyCommit: (@Sendable () -> Void)?
    var afterObservationValidation: (@Sendable () -> Void)?
}

private extension FileOperationRequest {
    var inputs: [URL] {
        switch self {
        case .createFolder: []
        case .rename(let source, _): [source]
        case .copy(let sources, _), .move(let sources, _), .trash(let sources): sources
        case .moveObserved(let selection, _): selection.urls
        }
    }
}

private struct Plan {
    enum Kind { case create, rename, copy, move, trash }
    let kind: Kind
    let source: SourceObservation?
    let destinationParent: DirectoryAnchor?
    let name: String
    var observations: [ObservedGuard] = []
    var destination: URL? { destinationParent?.url.appendingPathComponent(name) }

    func validate() throws {
        try source?.validate()
        do { try destinationParent?.validate() }
        catch { throw FileOperationFailure.destinationChanged }
        for observation in observations { try observation.validate() }
    }
}

private struct ObservedGuard {
    let url: URL
    let snapshot: EntrySnapshot
    func matches(_ current: EntrySnapshot) -> Bool {
        // Directory children may change while a sheet is open; replacing the directory may not.
        snapshot.isDirectory ? snapshot.sameObject(as: current) : snapshot == current
    }
    func validate() throws {
        guard let current = try? observeObject(url, resolve: false), matches(current.snapshot) else {
            throw FileOperationFailure.sourceChanged
        }
    }
}

internal func observeObject(_ input: URL, resolve: Bool = true) throws -> (url: URL, snapshot: EntrySnapshot) {
    if input.path == "/" {
        let root = try DirectoryAnchor(input, resolve: resolve)
        return (root.url, root.identity)
    }
    guard input.isFileURL else { throw FileOperationFailure.invalidRequest }
    let name = input.lastPathComponent
    try validateName(name)
    let parent = try DirectoryAnchor(input.deletingLastPathComponent(), resolve: resolve)
    return (parent.url.appendingPathComponent(name), try EntrySnapshot(parent: parent.fd, name: name))
}

internal final class DirectoryAnchor {
    let url: URL
    let fd: Int32
    let identity: EntrySnapshot

    init(_ input: URL, resolve: Bool = true) throws {
        guard input.isFileURL, input.path.hasPrefix("/"), input.host == nil || input.host == "" || input.host == "localhost" else {
            throw FileOperationFailure.invalidRequest
        }
        if resolve { url = try canonicalDirectoryURL(input) }
        else { url = input }
        let opened = try Self.openDescriptor(url)
        do {
            identity = try EntrySnapshot(fd: opened)
            fd = opened
        } catch { close(opened); throw error }
    }

    /// Native path resolution rejects symlinks at every component. The descriptor
    /// walk remains authoritative where a full path or this flag is unsupported.
    internal static func openDescriptor(_ url: URL,
        openPath: (String, Int32) -> Int32 = { Darwin.open($0, $1) }) throws -> Int32 {
        let components = url.pathComponents.dropFirst()
        for component in components { try validateName(component) }
        // Preserve search-only directory access; listing permission is not required.
        let opened = openPath(url.path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if opened >= 0 { return opened }
        let failure = errno
        guard failure == ENAMETOOLONG || failure == EINVAL || failure == ENOTSUP || failure == EOPNOTSUPP else {
            throw posixFailure(failure)
        }
        // Never weaken a symlink/access/missing-path refusal into a different lookup.
        var current = Darwin.open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw posixFailure() }
        do {
            for component in components {
                let next = openat(current, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixFailure() }
                close(current)
                current = next
            }
            return current
        } catch { close(current); throw error }
    }

    func validate() throws {
        let current = try DirectoryAnchor(url, resolve: false)
        guard current.identity.sameObject(as: identity) else { throw FileOperationFailure.destinationChanged }
    }
    var currentURL: URL? { directoryURL(for: fd, matching: identity) }
    deinit { close(fd) }
}

private final class SourceObservation {
    let parentURL: URL
    private let parentIdentity: EntrySnapshot
    private var activeParent: DirectoryAnchor?
    var parent: DirectoryAnchor { activeParent! }
    let name: String
    let url: URL
    let snapshot: EntrySnapshot
    private var fd: Int32?

    init(_ input: URL) throws {
        guard input.isFileURL, input.path != "/" else { throw FileOperationFailure.invalidRequest }
        name = input.lastPathComponent
        try validateName(name)
        let parent = try DirectoryAnchor(input.deletingLastPathComponent())
        parentURL = parent.url
        parentIdentity = parent.identity
        url = parent.url.appendingPathComponent(name)
        snapshot = try EntrySnapshot(parent: parent.fd, name: name)
        guard !snapshot.isDirectory || snapshot.device == parent.identity.device else { throw FileOperationFailure.invalidRequest }
    }

    /// Preparation retains observations only. One executing item owns its live anchors.
    func pin() throws {
        let parent = try DirectoryAnchor(parentURL, resolve: false)
        guard parent.identity.sameObject(as: parentIdentity) else { throw FileOperationFailure.sourceChanged }
        // Event-only opens can still block on FIFOs. NONBLOCK also protects the gap in which
        // an observed regular entry is replaced by a special file before this open.
        // O_SYMLINK opens the link itself. Combining it with O_NOFOLLOW rejects links
        // with ELOOP on macOS; inode/type validation below still rejects substitutions.
        let opened = openat(parent.fd, name, O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw posixFailure() }
        do {
            let pinned = try EntrySnapshot(fd: opened)
            guard pinned == snapshot else { throw FileOperationFailure.sourceChanged }
            fd = opened
            activeParent = parent
        } catch { close(opened); throw error }
    }

    func validate() throws {
        do {
            guard let parent = activeParent, let fd else { throw FileOperationFailure.sourceChanged }
            try parent.validate()
            guard try EntrySnapshot(parent: parent.fd, name: name) == snapshot,
                  try EntrySnapshot(fd: fd) == snapshot else { throw FileOperationFailure.sourceChanged }
        } catch { throw FileOperationFailure.sourceChanged }
    }
    func unpin() {
        if let fd { close(fd) }
        fd = nil
        activeParent = nil
    }
    deinit { unpin() }
}

internal final class Stage {
    let name = ".mac-explorer-stage-" + UUID().uuidString
    let url: URL
    let fd: Int32
    let identity: EntrySnapshot

    init(in parent: DirectoryAnchor, created: (URL) -> Void) throws {
        url = parent.url.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw posixFailure() }
        created(url)
        let opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw FileOperationFailure.recoveryUncertain }
        do { identity = try EntrySnapshot(fd: opened); fd = opened }
        catch { close(opened); throw error }
    }

    func validate(in parent: DirectoryAnchor) throws {
        guard try EntrySnapshot(parent: parent.fd, name: name).sameObject(as: identity) else {
            throw FileOperationFailure.destinationChanged
        }
    }
    var currentURL: URL? {
        directoryURL(for: fd, matching: identity)
    }
    deinit { close(fd) }
}

internal func canonicalDirectoryURL(_ input: URL) throws -> URL {
    // Foundation standardization can turn '/private/tmp' into the '/tmp' symlink.
    // Native realpath returns the physical spelling for the subsequent no-follow walk.
    let resolved = input.withUnsafeFileSystemRepresentation { path in
        path.flatMap { Darwin.realpath($0, nil) }
    }
    guard let resolved else { throw posixFailure() }
    defer { free(resolved) }
    guard let path = String(validatingCString: resolved) else { throw FileOperationFailure.unsupported }
    return URL(fileURLWithPath: path, isDirectory: true)
}

internal func directoryURL(for fd: Int32, matching identity: EntrySnapshot) -> URL? {
    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
    let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }
    guard result == 0 else { return nil }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let string = String(bytes: bytes, encoding: .utf8) else { return nil }
    let url = URL(fileURLWithPath: string, isDirectory: true)
    guard let current = try? DirectoryAnchor(url, resolve: false), current.identity.sameObject(as: identity) else { return nil }
    return url
}

internal struct EntrySnapshot: Equatable, Sendable, Codable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let birthSeconds: Int
    let birthNanos: Int
    var type: mode_t { mode & S_IFMT }
    var isDirectory: Bool { type == S_IFDIR }

    init(fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixFailure() }
        self.init(value)
    }
    init(parent: Int32, name: String) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        self.init(value)
    }
    private init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        birthSeconds = value.st_birthtimespec.tv_sec; birthNanos = value.st_birthtimespec.tv_nsec
    }
    func sameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && type == other.type &&
            birthSeconds == other.birthSeconds && birthNanos == other.birthNanos
    }
}

private struct EntryIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t
    init(_ snapshot: EntrySnapshot) { device = snapshot.device; inode = snapshot.inode; type = snapshot.type }
}

private func validatedSources(_ urls: [URL], cancellation: OperationCancellation) throws -> [SourceObservation] {
    guard !urls.isEmpty else { throw FileOperationFailure.invalidRequest }
    var identities: Set<EntryIdentity> = []
    let sources = try urls.map { url in
        try cancellation.check()
        let source = try SourceObservation(url)
        guard identities.insert(EntryIdentity(source.snapshot)).inserted else { throw FileOperationFailure.invalidRequest }
        return source
    }
    var previousDirectory: String?
    // Path component order keeps a selected directory immediately before all descendants.
    let ordered = sources.sorted { $0.url.pathComponents.lexicographicallyPrecedes($1.url.pathComponents) }
    for source in ordered {
        try cancellation.check()
        if let previousDirectory, isDescendant(source.url.path, of: previousDirectory) {
            throw FileOperationFailure.invalidRequest
        }
        if source.snapshot.isDirectory { previousDirectory = source.url.path }
    }
    return sources
}

private func isDescendant(_ path: String, of parent: String) -> Bool { path == parent || path.hasPrefix(parent + "/") }
internal func validateName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
          !name.contains("/"), !name.contains(":"),
          name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        throw FileOperationFailure.invalidRequest
    }
}

internal func requireAbsent(_ name: String, in parent: Int32) throws {
    var value = stat()
    if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { throw FileOperationFailure.conflict }
    guard errno == ENOENT else { throw posixFailure() }
}

internal func exclusiveRename(from source: Int32, name sourceName: String, to destination: Int32, name destinationName: String) throws {
    guard renameatx_np(source, sourceName, destination, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
}

internal func posixFailure(_ code: Int32 = errno) -> FileOperationFailure {
    FileOperationDiagnostics.nativeFailure(code)
    return switch code {
    case EEXIST, ENOTEMPTY: .conflict
    case EACCES, EPERM, EROFS: .accessDenied
    case ENOENT: .notFound
    case EXDEV: .crossVolumeMoveUnsupported
    case ENOTSUP: .unsupported
    case ENODEV, ESTALE, ENXIO, ENOTCONN: .unavailable
    case ENOSPC: .outOfSpace
    case EDQUOT: .quotaExceeded
    default: .ioFailure
    }
}

internal func operationStatus(_ error: Error) -> FileOperationStatus {
    if error is CancellationError { return .cancelled }
    if let failure = error as? FileOperationFailure { return .failed(failure) }
    var current = error as NSError
    var seen = Set<ObjectIdentifier>()
    var cocoaFallback: FileOperationFailure?
    // Only classify bounded, typed error codes. Never retain descriptions or userInfo.
    for _ in 0..<8 {
        guard seen.insert(ObjectIdentifier(current)).inserted else { break }
        if current.domain == NSPOSIXErrorDomain, let code = Int32(exactly: current.code) {
            return .failed(posixFailure(code))
        }
        if current.domain == NSCocoaErrorDomain, cocoaFallback == nil {
            switch current.code {
            case NSFileWriteOutOfSpaceError: cocoaFallback = .outOfSpace
            case NSFileWriteFileExistsError: cocoaFallback = .conflict
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: cocoaFallback = .accessDenied
            case NSFileReadNoSuchFileError: cocoaFallback = .notFound
            default: break
            }
        }
        guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
        current = underlying
    }
    return .failed(cocoaFallback ?? .ioFailure)
}

internal final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var shieldsCancellation = false
    private let parent: OperationCancellation?
    let progress: OperationProgressReporter?
    init(progress: OperationProgressReporter? = nil, parent: OperationCancellation? = nil) { self.progress = progress; self.parent = parent }
    /// A started mutation drains its validation, sync and journal segment despite Stop.
    func draining() -> OperationCancellation { OperationCancellation(progress: progress) }
    func segment() -> OperationCancellation { OperationCancellation(progress: progress, parent: self) }
    func beginMutation() throws {
        try check()
        if parent != nil { lock.withLock { shieldsCancellation = true } }
    }
    var isCancelled: Bool { lock.withLock { !shieldsCancellation && (cancelled || (parent?.isCancelled ?? false)) } }
    func cancel() { lock.withLock { cancelled = true }; progress?.requestStop() }
    func check() throws { if isCancelled { throw CancellationError() } }
}
