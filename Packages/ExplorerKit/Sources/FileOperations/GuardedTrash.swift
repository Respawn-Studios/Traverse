import Darwin
import Foundation

/// A fresh, metadata-only selection for the stricter selected-cleanup route.
/// Engine-bound and single-use. Neither this value nor an analysis grants access.
public struct GuardedTrashSelection: Sendable {
    public let selection: FileOperationSelection
    public let observedItems: Int
    fileprivate let engine: UUID
    fileprivate let policy: GuardedTrashPolicy
}

extension RecoverableFileOperations {
    /// Does not create/open writable history or read file bodies. Callers retain
    /// ordinary access and exclude competing work through execution/drain.
    public func prepareGuardedTrash(_ sources: [URL], protecting roots: [URL],
        excluding excluded: @escaping @Sendable (URL) -> Bool = { _ in false }) async throws -> GuardedTrashSelection {
        // Selected cleanup may reuse the native file/folder contract, but the
        // file-only and held profiles cannot acquire a guarded mutation.
        guard nativeTrashPolicy == .existingVerifiedPaths || nativeTrashPolicy == .regularFilesAndDirectories else {
            throw FileOperationFailure.unsupported
        }
        return try await worker { cancellation in
            try withoutMaterialization {
                let policy = try GuardedTrashPolicy(sources: sources, protecting: [self.directory] + roots,
                                                    excluding: excluded, cancellation: cancellation)
                let items = try policy.preflight(cancellation: cancellation)
                return GuardedTrashSelection(selection: policy.selection, observedItems: items,
                                             engine: self.continuationSession, policy: policy)
            }
        }
    }

    /// Uses the ordinary recoverable Trash protocol; there is no weaker fallback.
    public func performGuardedTrash(_ reviewed: GuardedTrashSelection,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                guard self.nativeTrashPolicy == .existingVerifiedPaths
                    || self.nativeTrashPolicy == .regularFilesAndDirectories else {
                    throw FileOperationFailure.unsupported
                }
                guard reviewed.engine == self.continuationSession, reviewed.policy.claim() else {
                    throw FileOperationFailure.invalidRequest
                }
                // Generated Copy authorities cannot acquire a new mutation kind.
                if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
                return try withoutMaterialization {
                    try self.validateCopyExecutionSession(locations: reviewed.selection.urls, directories: [])
                    _ = try reviewed.policy.preflight(cancellation: cancellation)
                    return self.trash(reviewed.selection.urls, observing: reviewed.selection,
                                      cancellation: cancellation, guarded: reviewed.policy)
                }
            }
        } catch {
            result = RecoverableOperationResult(result: FileOperationResult(items: [
                FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error), recoveryURLs: [], role: .job)
            ] + reviewed.selection.urls.map {
                FileOperationOutcome(source: $0, destination: nil, status: .notStarted, recoveryURLs: [])
            }, cancellationRequested: error is CancellationError), recordID: nil)
        }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }
}

/// Thread policy must surround synchronous work, never an async suspension.
internal func withoutMaterialization<T>(_ action: () throws -> T) throws -> T {
    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    guard previous >= 0 else { throw FileOperationFailure.unsupported }
    defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
    guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                        IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
          getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else { throw FileOperationFailure.unsupported }
    return try action()
}

/// All mutable native guards are confined to the creating engine's serial
/// worker. Only the single-use claim is accessed through its own lock.
internal final class GuardedTrashPolicy: @unchecked Sendable {
    let selection: FileOperationSelection
    private let parents: [DirectoryAnchor]
    private let protections: [HistoryProtection]
    private let history: HistoryProtection
    private let excluded: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var claimed = false

    init(sources: [URL], protecting roots: [URL], excluding: @escaping @Sendable (URL) -> Bool,
         cancellation: OperationCancellation) throws {
        guard !sources.isEmpty, sources.count <= OperationJournal.maximumInputs, roots.count <= 32 else {
            throw FileOperationFailure.invalidRequest
        }
        // Fixed, bounded private roots. HistoryProtection also guards ancestors,
        // descendants, missing paths and alternate links to metadata objects.
        self.excluded = excluding
        guard let historyURL = roots.first else { throw FileOperationFailure.invalidRequest }
        history = try HistoryProtection(historyURL, cancellation: cancellation)
        protections = try Array(Set(roots.dropFirst().map(\.standardizedFileURL))).map {
            try HistoryProtection($0, cancellation: cancellation)
        }
        var observed: [EntrySnapshot] = [], urls: [URL] = [], parents: [DirectoryAnchor] = []
        for source in sources {
            try cancellation.check(); try Self.requirePath(source)
            try validateName(source.lastPathComponent)
            guard !excluding(source) else { throw FileOperationFailure.unsupported }
            let parent = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let entry = try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent)
            guard [S_IFREG, S_IFDIR].contains(entry.type), entry.device == parent.identity.device else {
                throw FileOperationFailure.unsupported
            }
            try Self.requireProtection(history: history, additional: protections, parent: parent,
                                       name: source.lastPathComponent, snapshot: entry)
            // A directory with its own filesystem identity is not an ordinary
            // selected folder, even if APFS gives a projected st_dev alias.
            let fd = openat(parent.fd, source.lastPathComponent, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            defer { close(fd) }
            var filesystem = statfs()
            guard fstatfs(fd, &filesystem) == 0 else { throw posixFailure() }
            let mount = withUnsafeBytes(of: &filesystem.f_mntonname) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard source.path != mount, Self.isLocalWritableAPFS(filesystem) else { throw FileOperationFailure.unsupported }
            observed.append(entry); urls.append(source); parents.append(parent)
        }
        for a in urls.indices { for b in urls.indices where a != b {
            guard !urls[b].path.hasPrefix(urls[a].path + "/"), !observed[a].sameObject(as: observed[b]) else {
                throw FileOperationFailure.invalidRequest
            }
        } }
        guard Set(urls).count == urls.count else { throw FileOperationFailure.invalidRequest }
        self.parents = parents
        selection = FileOperationSelection(urls: urls, identities: observed)
    }

    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }

    /// One complete metadata admission before any integrity/body verification.
    @discardableResult
    func preflight(cancellation: OperationCancellation) throws -> Int {
        let budget = TraversalBudget()
        func visit(parent: Int32, name: String, url: URL, root: EntrySnapshot, depth: Int) throws {
            try cancellation.check()
            let before = try EntrySnapshot(parent: parent, name: name)
            try budget.consume(before, depth: depth)
            try validateBeforeOpen(parent: parent, name: name, url: url, root: root)
            if before.isDirectory {
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
                guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }
                for child in try childNames(in: fd, cancellation: cancellation, limit: budget.remaining) {
                    try visit(parent: fd, name: child, url: url.appendingPathComponent(child), root: root, depth: depth + 1)
                }
                guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }
            }
            guard try EntrySnapshot(parent: parent, name: name) == before else { throw FileOperationFailure.sourceChanged }
        }
        for index in selection.urls.indices {
            try validateRoot(index)
            try visit(parent: parents[index].fd, name: selection.urls[index].lastPathComponent,
                      url: selection.urls[index], root: selection.identities[index], depth: 0)
            try validateRoot(index)
        }
        return budget.nodes
    }

    func validateRoot(_ index: Int) throws {
        let url = selection.urls[index]
        try parents[index].validate()
        guard try EntrySnapshot(parent: parents[index].fd, name: url.lastPathComponent) == selection.identities[index] else {
            throw FileOperationFailure.sourceChanged
        }
        try Self.requireProtection(history: history, additional: protections, parent: parents[index], name: url.lastPathComponent)
    }

    func validateBeforeOpen(parent: Int32, name: String, url: URL, root: EntrySnapshot) throws {
        try Self.requirePath(url)
        guard !excluded(url) else { throw FileOperationFailure.unsupported }
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        try Self.requireMaterialized(value)
        guard value.st_dev == root.device else { throw FileOperationFailure.unsupported }
        // O_EVTONLY observes metadata without requesting file data. Symlink
        // entries are inspected themselves; their targets are never followed.
        let fd = openat(parent, name, O_EVTONLY | O_CLOEXEC | O_NONBLOCK | (value.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        guard try EntrySnapshot(fd: fd) == EntrySnapshot(parent: parent, name: name) else { throw FileOperationFailure.sourceChanged }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0, Self.isLocalWritableAPFS(filesystem) else { throw FileOperationFailure.unsupported }
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 1_048_576 else { throw FileOperationFailure.unsupported }
        var names = [CChar](repeating: 0, count: max(1, size))
        guard flistxattr(fd, &names, size, 0) == size else { throw FileOperationFailure.sourceChanged }
        for raw in names.prefix(size).split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
            guard !["com.apple.fileprovider", "com.apple.icloud", "com.apple.ubiquity"].contains(where: { name.hasPrefix($0) }) else {
                throw FileOperationFailure.unsupported
            }
        }
        // A protected descendant or alternate metadata hard link cannot be
        // admitted merely because the top-level selection looked ordinary.
        if value.st_mode & S_IFMT == S_IFDIR || value.st_nlink > 1 {
            let anchor = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            try Self.requireProtection(history: history, additional: protections, parent: anchor, name: name)
        }
    }

    static func requireMaterialized(_ value: stat) throws {
        guard [S_IFREG, S_IFDIR, S_IFLNK].contains(value.st_mode & S_IFMT),
              value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { throw FileOperationFailure.unsupported }
    }
    private static func requireProtection(history: HistoryProtection, additional: [HistoryProtection],
        parent: DirectoryAnchor, name: String, snapshot: EntrySnapshot? = nil) throws {
        try history.requireEntry(parent: parent, name: name, snapshot: snapshot)
        do { for protection in additional { try protection.requireEntry(parent: parent, name: name, snapshot: snapshot) } }
        catch FileOperationFailure.operationHistoryProtected { throw FileOperationFailure.protectedLocation }
    }
    private static func isLocalWritableAPFS(_ value: statfs) -> Bool {
        var value = value
        return value.f_flags & UInt32(MNT_LOCAL) != 0 && value.f_flags & UInt32(MNT_RDONLY) == 0
            && withUnsafeBytes(of: &value.f_fstypename) { $0.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8)) }
    }
    private static func requirePath(_ url: URL) throws {
        guard url.isFileURL, url.query == nil, url.fragment == nil,
              url == url.standardizedFileURL, url.path.utf8.count < 1024 else { throw FileOperationFailure.invalidRequest }
        let parts = Array(url.pathComponents.dropFirst()).map { $0.lowercased() }
        let logical = parts.starts(with: ["system", "volumes", "data"]) ? Array(parts.dropFirst(3)) : parts
        guard logical.count > 1, !["system", "private", "dev", "network", "net", ".vol"].contains(logical[0]),
              !parts.contains(where: { ["cloudstorage", "mobile documents", ".trash", ".trashes", ".ssh", ".gnupg", "keychains"].contains($0) }),
              !(logical[0] == "volumes" && logical.count == 2),
              !(logical[0] == "users" && logical.count <= 2) else { throw FileOperationFailure.unsupported }
    }
}
