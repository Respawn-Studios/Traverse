import Darwin
import ExplorerCore
import Foundation

/// On-demand, descriptor-anchored metadata search. One worker and one active
/// session per instance; starting again cancels obsolete queued/running work.
/// No file-body descriptor, download, index, log, or persistence is created.
public final class LocalMetadataSearch: @unchecked Sendable {
    private let queue: OperationQueue
    private let activityGate: FileActivityGate?
    private let lock = NSLock()
    private var active: SearchSession?
    private var pending: Work?
    private var workerScheduled = false
    private let qualificationVisit: (@Sendable () -> Void)?

    private struct Work: Sendable {
        let request: SearchRequest
        let scope: SearchScope
        let state: SearchSessionState
        let lifetime: (any Sendable)?
    }

    public convenience init(activityGate: FileActivityGate? = nil) {
        self.init(activityGate: activityGate, checkpoint: nil)
    }
    private init(activityGate: FileActivityGate?, checkpoint: (@Sendable () -> Void)?) {
        self.activityGate = activityGate
        qualificationVisit = checkpoint
        queue = OperationQueue()
        queue.name = "MacExplorer.Search.Metadata"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }
    #if DEBUG
    /// Delays actual observation only. No result, authority or policy can be
    /// injected; the native qualifier still owns a bounded generated root.
    @_spi(Qualification) public convenience init(activityGate: FileActivityGate?, qualificationVisit: @escaping @Sendable () -> Void) {
        self.init(activityGate: activityGate, checkpoint: qualificationVisit)
    }
    #endif

    public func start(request: SearchRequest, scope: SearchScope, policy: SearchPolicy = SearchPolicy(),
                      retaining lifetime: (any Sendable)? = nil) -> SearchSession {
        lock.withLock {
            active?.cancel()
            let session = SearchSession(roots: [scope.root], policy: policy, source: .recursiveMetadata)
            active = session
            // Replace the sole waiting request, rather than adding one operation
            // per keystroke behind a potentially slow filesystem syscall.
            pending = Work(request: request, scope: scope, state: session.state, lifetime: lifetime)
            if !workerScheduled {
                workerScheduled = true
                queue.addOperation { [self] in drain() }
            }
            return session
        }
    }

    private func drain() {
        while let work = lock.withLock({ () -> Work? in
            let work = pending
            pending = nil
            if work == nil { workerScheduled = false }
            return work
        }) {
            withExtendedLifetime(work.lifetime) {
                guard !work.state.isStopped else { return }
                do {
                    let activity = try activityGate?.begin()
                    defer { withExtendedLifetime(activity) {} }
                    Self.search(request: work.request, scope: work.scope, state: work.state, checkpoint: qualificationVisit)
                } catch { work.state.issue(work.scope.root, .unavailable); work.state.finish(.failed) }
            }
        }
    }

    private static func search(request: SearchRequest, scope: SearchScope, state: SearchSessionState, checkpoint: (@Sendable () -> Void)?) {
        guard !MetadataObservation.isCredentialLocation(scope.root) else {
            state.issue(scope.root, .credentialLocation); state.finish(.failed); return
        }
        let descriptor = MetadataObservation.openPermittedDirectory(scope.root, reporting: scope.root, state: state)
        guard descriptor >= 0 else {
            state.finish(.failed); return
        }
        defer { close(descriptor) }
        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0 else {
            state.issue(scope.root, .unavailable); state.finish(.failed); return
        }
        do {
            let values = try scope.root.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
            if values.isPackage == true { state.issue(scope.root, .package); state.finish(.failed); return }
            if values.isUbiquitousItem == true || MetadataObservation.isDataless(rootStat) {
                state.issue(scope.root, .cloudItem); state.finish(.failed); return
            }
        } catch { state.issue(scope.root, .metadataUnavailable); state.finish(.failed); return }
        walk(descriptor, url: scope.root, depth: 0, rootDevice: rootStat.st_dev, scope: scope, request: request, state: state, checkpoint: checkpoint)
        state.finish()
    }

    private static func walk(_ descriptor: Int32, url: URL, depth: Int, rootDevice: dev_t,
                             scope: SearchScope, request: SearchRequest, state: SearchSessionState, checkpoint: (@Sendable () -> Void)?) {
        guard !state.isStopped else { return }
        guard MetadataObservation.descriptorPath(descriptor) == url.path else {
            state.issue(url, .changedDuringSearch); return
        }
        let copied = dup(descriptor)
        guard copied >= 0, let directory = fdopendir(copied) else {
            if copied >= 0 { close(copied) }
            state.issue(url, MetadataObservation.failure(errno)); return
        }
        defer { closedir(directory) }
        state.directory()
        while !state.isStopped {
            // Foundation metadata creates autoreleased URL/resource temporaries.
            // Bound them to one observation, including recursive entry lifetime;
            // published Swift values retain their normal strong ownership.
            let continueWalking = autoreleasepool { () -> Bool in
                // A renamed/replaced parent must not redirect subsequent observation.
                guard MetadataObservation.descriptorPath(descriptor) == url.path else {
                    state.issue(url, .changedDuringSearch); return false
                }
                errno = 0
                guard let item = readdir(directory) else {
                    if errno != 0 { state.issue(url, MetadataObservation.failure(errno)) }
                    return false
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { return true }
                guard state.visit() else { return false }
                checkpoint?()
                guard !state.isStopped else { return false }
                let child = url.appendingPathComponent(name)
                guard scope.permits(child) else { state.issue(child, .excluded); return true }
                guard !MetadataObservation.isCredentialLocation(child) else { state.issue(child, .credentialLocation); return true }
                if !scope.showHidden && name.hasPrefix(".") { state.issue(child, .hidden); return true }
                var observed = stat()
                guard fstatat(descriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                    state.issue(child, MetadataObservation.failure(errno)); return true
                }
                if !scope.showHidden && observed.st_flags & UInt32(UF_HIDDEN) != 0 { state.issue(child, .hidden); return true }
                guard observed.st_dev == rootDevice else { state.issue(child, .nestedVolume); return true }
                if MetadataObservation.isDataless(observed) { state.issue(child, .cloudItem); return true }
                var kind = MetadataObservation.kind(observed)
                if kind == .symbolicLink {
                    state.issue(child, .symbolicLink)
                } else {
                    do {
                        let values = try child.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey, .isHiddenKey])
                        if values.isUbiquitousItem == true { state.issue(child, .cloudItem); return true }
                        if !scope.showHidden && values.isHidden == true { state.issue(child, .hidden); return true }
                        if kind == .directory && values.isPackage == true { kind = .package }
                    } catch {
                        // Do not descend when package/provider boundaries are unknown.
                        state.issue(child, .metadataUnavailable); return true
                    }
                    var rechecked = stat()
                    guard fstatat(descriptor, name, &rechecked, AT_SYMLINK_NOFOLLOW) == 0,
                          MetadataObservation.sameObject(observed, rechecked) else {
                        state.issue(child, .changedDuringSearch); return true
                    }
                }
                let entry = MetadataObservation.entry(child, name: name, kind: kind, observed: observed)
                if request.matches(entry) { state.match(SearchMatch(entry: entry)) }
                guard !state.isStopped else { return false }
                if kind == .package { state.issue(child, .package); return true }
                guard kind == .directory else { return true }
                guard depth < state.policy.maximumDepth else { state.issue(child, .depthLimit); return true }
                let childFD = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { state.issue(child, MetadataObservation.failure(errno)); return true }
                var opened = stat()
                if fstat(childFD, &opened) == 0 && MetadataObservation.sameObject(observed, opened) {
                    walk(childFD, url: child, depth: depth + 1, rootDevice: rootDevice, scope: scope, request: request, state: state, checkpoint: checkpoint)
                } else { state.issue(child, .changedDuringSearch) }
                close(childFD)
                return true
            }
            if !continueWalking { return }
        }
    }
}

enum MetadataObservation {
    /// Deny known credential boundaries before asking for any metadata below them.
    static func isCredentialLocation(_ url: URL) -> Bool {
        AutomaticMetadataPolicy.excludes(url)
    }
    static func isDataless(_ value: stat) -> Bool { value.st_flags & UInt32(SF_DATALESS) != 0 }
    static func kind(_ value: stat) -> FileKind {
        switch value.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }
    static func sameObject(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && (left.st_mode & S_IFMT) == (right.st_mode & S_IFMT)
    }
    static func entry(_ url: URL, name: String, kind: FileKind, observed: stat) -> FileEntry {
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
        let birth = observed.st_birthtimespec
        return FileEntry(url: url, name: name, kind: kind,
                         byteCount: kind == .file || kind == .symbolicLink ? Int64(observed.st_size) : nil,
                         modifiedAt: date(observed.st_mtimespec),
                         createdAt: birth.tv_sec == 0 && birth.tv_nsec == 0 ? nil : date(birth),
                         accessedAt: date(observed.st_atimespec))
    }
    static func failure(_ code: Int32) -> SearchBoundary {
        switch code {
        case EACCES, EPERM: .denied
        case ELOOP: .symbolicLink
        default: .unavailable
        }
    }
    static func descriptorPath(_ descriptor: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    /// Check each package/provider boundary before opening that ancestor, and
    /// bind every step to its no-follow descriptor observation. This also rejects
    /// selecting a root inside a package/cloud boundary or symlink ancestor.
    static func openPermittedDirectory(_ url: URL, reporting result: URL, state: SearchSessionState) -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { state.issue(result, failure(errno)); return -1 }
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            guard !state.isStopped else { close(descriptor); return -1 }
            path.appendPathComponent(component, isDirectory: true)
            var observed = stat()
            guard fstatat(descriptor, component, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                state.issue(result, failure(errno)); close(descriptor); return -1
            }
            if kind(observed) == .symbolicLink { state.issue(result, .symbolicLink); close(descriptor); return -1 }
            if isDataless(observed) { state.issue(result, .cloudItem); close(descriptor); return -1 }
            do {
                let values = try path.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
                if values.isPackage == true { state.issue(result, .package); close(descriptor); return -1 }
                if values.isUbiquitousItem == true { state.issue(result, .cloudItem); close(descriptor); return -1 }
            } catch { state.issue(result, .metadataUnavailable); close(descriptor); return -1 }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let errorCode = errno
            close(descriptor)
            guard next >= 0 else { state.issue(result, failure(errorCode)); return -1 }
            var opened = stat()
            guard fstat(next, &opened) == 0, sameObject(observed, opened), descriptorPath(next) == path.path else {
                state.issue(result, .changedDuringSearch); close(next); return -1
            }
            descriptor = next
        }
        return descriptor
    }
}
