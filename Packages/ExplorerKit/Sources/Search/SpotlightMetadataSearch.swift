import CoreServices
import Darwin
import ExplorerCore
import Foundation

/// Queries only the existing Spotlight filename index, never filesystem crawling
/// or body-derived attributes. The result engine and application both have caps.
/// A completed query does not prove index coverage or current file access.
public final class SpotlightMetadataSearch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.Search.Spotlight", qos: .userInitiated)
    private let lock = NSLock()
    private var active: SearchSession?
    private var pending: SpotlightRunner?
    private var activationScheduled = false
    // This property is accessed only on the dedicated serial worker queue.
    private var runner: SpotlightRunner?
    private let activityGate: FileActivityGate?

    public init(activityGate: FileActivityGate? = nil) { self.activityGate = activityGate }

    public func start(request: SearchRequest, includeExternalVolumes: Bool = false,
                      policy: SearchPolicy = SearchPolicy(), retaining lifetime: (any Sendable)? = nil) -> SearchSession {
        start(request: request, selectedScope: nil, includeExternalVolumes: includeExternalVolumes, policy: policy, retaining: lifetime)
    }

    /// Query the existing index for one explicitly selected folder. No recursive
    /// fallback, index publication, indexing request, or materialization occurs.
    public func start(request: SearchRequest, scope: SearchScope,
                      policy: SearchPolicy = SearchPolicy(), retaining lifetime: (any Sendable)? = nil) -> SearchSession {
        start(request: request, selectedScope: scope, includeExternalVolumes: true, policy: policy, retaining: lifetime)
    }

    #if DEBUG
    /// Candidate generation only; every result still passes fresh observation.
    public func startDirectoryHintForQualification(request: SearchRequest, scope: SearchScope? = nil,
        policy: SearchPolicy = SearchPolicy(), retaining lifetime: (any Sendable)? = nil) -> SearchSession {
        start(request: request, selectedScope: scope, includeExternalVolumes: true,
              policy: policy, retaining: lifetime, directoryHint: true)
    }
    #endif

    private func start(request: SearchRequest, selectedScope: SearchScope?, includeExternalVolumes: Bool,
                       policy: SearchPolicy, retaining lifetime: (any Sendable)?, directoryHint: Bool = true) -> SearchSession {
        lock.withLock {
            active?.cancel()
            let session = SearchSession(roots: [], policy: policy, source: .spotlightIndex)
            let runner = SpotlightRunner(request: request, includeExternalVolumes: includeExternalVolumes,
                                         selectedScope: selectedScope, state: session.state, queue: queue, lifetime: lifetime,
                                         activityGate: activityGate, directoryHint: directoryHint)
            self.active = session
            pending = runner
            if !activationScheduled {
                activationScheduled = true
                queue.async { [self] in activatePending() }
            }
            return session
        }
    }

    private func activatePending() {
        let next = lock.withLock {
            let next = pending
            pending = nil
            activationScheduled = false
            return next
        }
        runner?.stop()
        runner = next
        next?.start()
    }
}

/// Fixed filename plan and a separately qualified fixed directory-type hint.
/// Indexed types never substitute for actual kind/extension/access-time checks.
enum SpotlightFilenamePlan {
    static let predicateFields: Set<String> = ["kMDItemFSName", "kMDItemContentTypeTree"]
    static let returnedFields: Set<String> = ["kMDItemPath"]

    static func expression(_ request: SearchRequest, directoryHint: Bool = false) -> String {
        // The engine treats '*'/'?' as globs. Prefilter with the longest ordinary
        // segment, then reapply the entire literal request to a typed observation.
        // This avoids relying on undocumented wildcard escaping. A capped broad
        // prefilter is explicitly incomplete, never presented as zero coverage.
        let separators = CharacterSet(charactersIn: "*?\\\"'")
        let fragment = FilenameMatching.indexedLiteralFragment(request.filename,
            symbolTolerant: request.symbolTolerant && request.filenameMatch != .exact)
        let escaped = fragment.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let hasSpecial = request.filename.rangeOfCharacter(from: separators) != nil
        let exact = request.filenameMatch == .exact && !hasSpecial
        let pattern = exact ? escaped : "*" + escaped + "*"
        // Live fixture qualification on the current MDQuery runtime requires
        // this trailing-modifier spelling. MDQueryCreate also accepts the
        // bracketed spelling, but parsing alone did not prove matching behavior.
        let filename = "kMDItemFSName == \"" + pattern + "\"cd"
        return directoryHint && request.kind == .directory
            ? "(" + filename + ") && (kMDItemContentTypeTree == \"public.directory\")" : filename
    }
}

private final class SpotlightRunner: @unchecked Sendable {
    private let request: SearchRequest
    private let directoryHint: Bool
    private let includeExternalVolumes: Bool
    private let selectedScope: SearchScope?
    private let state: SearchSessionState
    private let queue: DispatchQueue
    private var lifetime: (any Sendable)?
    private var query: MDQuery?
    private var roots: [URL] = []
    private var seen: Set<String> = []
    private var stopped = false
    private let activityGate: FileActivityGate?
    private var activity: FileActivityGate.Lease?

    init(request: SearchRequest, includeExternalVolumes: Bool, selectedScope: SearchScope?, state: SearchSessionState,
         queue: DispatchQueue, lifetime: (any Sendable)?, activityGate: FileActivityGate?, directoryHint: Bool) {
        self.request = request; self.includeExternalVolumes = includeExternalVolumes
        self.selectedScope = selectedScope
        self.state = state; self.queue = queue; self.lifetime = lifetime
        self.activityGate = activityGate
        self.directoryHint = directoryHint
    }

    func start() {
        guard !state.isStopped else { stop(); return }
        do { activity = try activityGate?.begin() }
        catch { state.finish(.failed); stop(); return }
        // A running session retains its concrete engine until terminal delivery;
        // queued obsolete sessions never enqueue their own cancellation work.
        state.onCancel { [self, queue] in queue.async { self.stop() } }
        // An empty global query is not a useful first search and must not become
        // a system-wide wildcard scan as a side effect of entering search mode.
        // Initials have no reliable literal Spotlight prefilter.
        guard !request.filename.isEmpty, request.filenameMatch != .navigation else { state.finish(.failed); stop(); return }
        if let selectedScope { roots = [selectedScope.root] }
        else {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey]
        guard let volumes = FileManager().mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
            state.finish(.failed); stop(); return
        }
        for volume in volumes {
            guard !state.isStopped else { stop(); return }
            do {
                let value = try volume.resourceValues(forKeys: keys)
                guard value.volumeIsLocal == true else { state.issue(volume, .unavailable); continue }
                guard let internalVolume = value.volumeIsInternal else { state.issue(volume, .metadataUnavailable); continue }
                if internalVolume || includeExternalVolumes { roots.append(volume.standardizedFileURL) }
                else { state.issue(volume, .excluded) }
            } catch { state.issue(volume, .unavailable) }
        }
        }
        guard !roots.isEmpty else { state.finish(.failed); stop(); return }
        state.setRoots(roots)
        guard let created = MDQueryCreate(kCFAllocatorDefault, SpotlightFilenamePlan.expression(request, directoryHint: directoryHint) as CFString, nil, nil) else {
            state.finish(.failed); stop(); return
        }
        query = created
        MDQuerySetSearchScope(created, roots as CFArray, 0)
        // NSMetadataQuery has no equivalent engine cap. This concrete bound is
        // why this adapter uses MDQuery rather than its Foundation wrapper.
        MDQuerySetMaxCount(created, state.policy.maximumResults)
        MDQuerySetDispatchQueue(created, queue)
        MDQuerySetBatchingParameters(created, MDQueryBatchingParams(first_max_num: 1, first_max_ms: 50,
                                                                   progress_max_num: 128, progress_max_ms: 100,
                                                                   update_max_num: 128, update_max_ms: 100))
        // No live updates, synchronous query, relevance sort or filesystem
        // translation flag. Only existing indexed matches are requested.
        guard MDQueryExecute(created, 0) else { state.finish(.failed); stop(); return }
        poll()
    }

    private func poll() {
        guard !stopped, !state.isStopped, let query else { stop(); return }
        MDQueryDisableUpdates(query)
        let count = MDQueryGetResultCount(query)
        let complete = MDQueryIsGatheringComplete(query)
        for index in 0..<min(count, state.policy.maximumResults) {
            guard !state.isStopped else { break }
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            // Never enumerate an item's attributes or read relevance/snippets.
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  seen.insert(path).inserted else { continue }
            guard state.visit() else { break }
            IndexedResultGate.observe(URL(fileURLWithPath: path), roots: roots, request: request,
                                      includeExternalVolumes: includeExternalVolumes, state: state, scope: selectedScope)
        }
        MDQueryEnableUpdates(query)
        if state.isStopped { stop(); return }
        if count >= state.policy.maximumResults { state.finish(.resultLimit); stop(); return }
        if complete { state.finish(); stop(); return }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.poll() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let query { MDQueryStop(query) }
        query = nil
        activity = nil
        lifetime = nil
    }
}

/// Revalidates indexed paths through an allowlisted observation. Also used by
/// synthetic-result tests without executing a system query or indexing a file.
enum IndexedResultGate {
    static func observe(_ url: URL, roots: [URL], request: SearchRequest,
                        includeExternalVolumes: Bool, state: SearchSessionState, scope: SearchScope? = nil) {
        let normalized = url.standardizedFileURL
        guard normalized.path == url.path,
              let permittedRoot = roots.filter({ $0.path == "/" || normalized.path == $0.path || normalized.path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) else {
            state.issue(url, .excluded); return
        }
        guard !MetadataObservation.isCredentialLocation(url) else { state.issue(url, .credentialLocation); return }
        if let scope, !scope.permits(url) { state.issue(url, .excluded); return }
        let relative = normalized.path.dropFirst(permittedRoot.path == "/" ? 1 : permittedRoot.path.count)
        if scope?.showHidden != true && relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            state.issue(url, .hidden); return
        }
        // Check package/provider boundaries before opening any ancestor. The
        // descriptor is directory-only and every component is no-follow.
        let parent = MetadataObservation.openPermittedDirectory(url.deletingLastPathComponent(), reporting: url, state: state)
        guard parent >= 0 else { return }
        defer { close(parent) }
        guard MetadataObservation.descriptorPath(parent) == url.deletingLastPathComponent().path else {
            state.issue(url, .changedDuringSearch); return
        }
        var observed = stat()
        guard fstatat(parent, url.lastPathComponent, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
            state.issue(url, MetadataObservation.failure(errno)); return
        }
        guard !MetadataObservation.isDataless(observed) else { state.issue(url, .cloudItem); return }
        if scope?.showHidden != true && observed.st_flags & UInt32(UF_HIDDEN) != 0 { state.issue(url, .hidden); return }
        var kind = MetadataObservation.kind(observed)
        if kind == .symbolicLink {
            do {
                let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
                guard values.volumeIsLocal == true else { state.issue(url, .unavailable); return }
                guard includeExternalVolumes || values.volumeIsInternal == true else { state.issue(url, .excluded); return }
            } catch { state.issue(url, .metadataUnavailable); return }
            state.issue(url, .symbolicLink)
        }
        else {
            do {
                let keys: Set<URLResourceKey> = [.isPackageKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey]
                let values = try url.resourceValues(forKeys: keys)
                guard values.volumeIsLocal == true else { state.issue(url, .unavailable); return }
                guard includeExternalVolumes || values.volumeIsInternal == true else { state.issue(url, .excluded); return }
                if values.isUbiquitousItem == true { state.issue(url, .cloudItem); return }
                if kind == .directory && values.isPackage == true { kind = .package }
            } catch { state.issue(url, .metadataUnavailable); return }
            var rechecked = stat()
            guard fstatat(parent, url.lastPathComponent, &rechecked, AT_SYMLINK_NOFOLLOW) == 0,
                  MetadataObservation.sameObject(observed, rechecked) else { state.issue(url, .changedDuringSearch); return }
        }
        let entry = MetadataObservation.entry(url, name: url.lastPathComponent, kind: kind, observed: observed)
        if request.matches(entry) { state.match(SearchMatch(entry: entry, source: .spotlightIndex)) }
    }

}
