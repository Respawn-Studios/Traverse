import CoreServices
import Darwin
import Foundation

public struct AnalysisRefreshCheckpoint: Codable, Equatable, Sendable {
    public let catalogID: UUID
    public let eventUUID: UUID
    public let cursor: String
    public let originalObservedThrough: Date
    public let reusedEntries: UInt64
    public let reusedDirectories: UInt64?
    public let enumeratedDirectories: UInt64
    public let isIncremental: Bool
    public let fallbackReason: String?

    public init(catalogID: UUID, eventUUID: UUID, cursor: String, originalObservedThrough: Date,
                reusedEntries: UInt64, enumeratedDirectories: UInt64, isIncremental: Bool, fallbackReason: String?,
                reusedDirectories: UInt64? = nil) {
        self.catalogID = catalogID; self.eventUUID = eventUUID; self.cursor = cursor
        self.originalObservedThrough = originalObservedThrough; self.reusedEntries = reusedEntries
        self.reusedDirectories = reusedDirectories
        self.enumeratedDirectories = enumeratedDirectories; self.isIncremental = isIncremental
        self.fallbackReason = fallbackReason
    }

    public func validate() throws {
        guard let value = UInt64(cursor), String(value) == cursor, value != UInt64.max,
              originalObservedThrough.timeIntervalSince1970.isFinite,
              fallbackReason.map({ AnalysisRefreshEvents.reasons.contains($0) }) ?? true,
              !isIncremental || fallbackReason == nil else { throw StorageScanFailure.invalidOutput }
    }

    /// Empty borrowed directory listings matter even when no rows were replayed.
    /// Older checkpoints without that count keep their conservative dated label.
    public var mayContainEarlierObservations: Bool {
        isIncremental && (reusedEntries > 0 || (reusedDirectories.map { $0 > 0 } ?? true))
    }
}

struct AnalysisRefreshDirtyDirectory: Equatable, Sendable {
    let path: Data
    let recursive: Bool
}

/// A direct listing and a recursive subtree have different coverage. Only an
/// already-recursive ancestor subsumes another scope; no siblings are promoted
/// and no event is discarded based on its age. The collector owns locking,
/// overflow fallback and the lifetime of this bounded plan.
struct AnalysisRefreshDirtyPlan: Sendable {
    private var entries: [Data: Bool] = [:]
    private(set) var pathBytes = 0
    var count: Int { entries.count }
    var directCount: Int { entries.values.filter { !$0 }.count }
    var recursiveCount: Int { entries.values.filter { $0 }.count }
    var exceedsLimits: Bool { count > 256 || pathBytes > 48 * 1024 }
    var directories: [AnalysisRefreshDirtyDirectory] {
        entries.map { .init(path: $0.key, recursive: $0.value) }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    mutating func insert(_ path: Data, recursive: Bool) {
        if let existing = entries[path], existing || !recursive { return }
        if entries.contains(where: { $0.value && Self.descendant(path, of: $0.key) }) { return }
        if recursive {
            for child in entries.keys.filter({ Self.descendant($0, of: path) }) {
                entries.removeValue(forKey: child); pathBytes -= child.count
            }
        }
        if entries.updateValue(recursive, forKey: path) == nil { pathBytes += path.count }
    }

    mutating func removeAll() { entries.removeAll(); pathBytes = 0 }

    private static func descendant(_ path: Data, of ancestor: Data) -> Bool {
        guard path.count > ancestor.count else { return false }
        return ancestor.isEmpty || path.starts(with: ancestor) && path.dropFirst(ancestor.count).first == 47
    }
}

/// All mutable callback state is protected by `lock`. The synchronous owner is
/// a background scanner; close stops delivery and drains the private queue before
/// its unretained C context can be released. No UI or actor-isolated work occurs.
final class AnalysisRefreshEvents: @unchecked Sendable {
    static let reasons: Set<String> = ["unsupported_volume", "root_changed", "history_unavailable",
        "event_uuid_changed", "cursor_out_of_range", "events_dropped", "event_ids_wrapped",
        "replay_timeout", "dirty_overflow", "invalid_event_path", "baseline_missing", "baseline_unavailable",
        "refresh_catalog", "refresh_profile", "refresh_partial", "refresh_root", "refresh_request",
        "refresh_shared_objects", "unsupported_scope", "refresh_incomplete", "root_dirty", "unknown_event"]
    private let queue = DispatchQueue(label: "com.respawn.analysis.refresh-events", qos: .utility)
    private let lock = NSLock()
    private let cancelled: @Sendable () -> Bool
    private var stream: FSEventStreamRef?
    private var reason: String?
    // Old checkpoint rejection is distinct from uncertainty in this watch.
    // Only a sound NEW interval may seed the next immutable generation.
    private var watchIssue: String?
    private var replayBarrierComplete = false
    private var enumerationBegan = false
    private var dirtyPlan = AnalysisRefreshDirtyPlan()
    private var historyDone = false
    private var latest: UInt64 = 0
    private var closed = false
    private var eventUUID: UUID?
    private var device: dev_t = 0
    private var fence: UInt64 = 0
    private var relativeRoot = Data()
    private var absoluteMount = ""
    private let previous: AnalysisRefreshCheckpoint?
    #if DEBUG
    private var eventCounts: [String: UInt64] = [:]
    private var firstRelevantID: UInt64?
    private var lastRelevantID: UInt64 = 0
    private var initialFence: UInt64 = 0
    private var peakPaths = 0, peakDirect = 0, peakRecursive = 0, peakBytes = 0
    private static let diagnosticFlags: [(UInt32, String)] = [
        (UInt32(kFSEventStreamEventFlagItemCreated), "created"), (UInt32(kFSEventStreamEventFlagItemRemoved), "removed"),
        (UInt32(kFSEventStreamEventFlagItemRenamed), "renamed"), (UInt32(kFSEventStreamEventFlagItemInodeMetaMod), "inode_meta"),
        (UInt32(kFSEventStreamEventFlagItemModified), "modified"), (UInt32(kFSEventStreamEventFlagItemIsDir), "directory"),
        (UInt32(kFSEventStreamEventFlagItemIsFile), "file"), (UInt32(kFSEventStreamEventFlagItemIsSymlink), "symlink"),
        (UInt32(kFSEventStreamEventFlagMustScanSubDirs), "recursive")
    ]
    #endif

    var fallbackReason: String? { lock.lock(); defer { lock.unlock() }; return reason }

    init(root: URL, descriptor: Int32, previous: AnalysisRefreshCheckpoint?, cancelled: @escaping @Sendable () -> Bool) throws {
        self.previous = previous; self.cancelled = cancelled
        var info = stat(), fs = statfs(), named = stat()
        guard fstat(descriptor, &info) == 0, fstatfs(descriptor, &fs) == 0,
              root.withUnsafeFileSystemRepresentation({ p in p.map { lstat($0, &named) == 0 } ?? false }),
              info.st_dev == named.st_dev, info.st_ino == named.st_ino,
              info.st_mode & S_IFMT == S_IFDIR else { reason = "root_changed"; return }
        let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        absoluteMount = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        // Device-relative monitoring needs the physical volume spelling. This
        // never changes the selected URL/grant or any source-opening authority.
        func descriptorPath(_ command: Int32) -> Data? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, command, &buffer) == 0 else { return nil }
            return Data(buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) })
        }
        guard let physicalPath = descriptorPath(F_GETPATH_NOFIRMLINK),
              let visiblePath = descriptorPath(F_GETPATH) else { reason = "root_changed"; return }
        guard String(data: physicalPath, encoding: .utf8) != nil,
              String(data: visiblePath, encoding: .utf8) != nil else { reason = "invalid_event_path"; return }
        guard type == "apfs", fs.f_flags & UInt32(MNT_LOCAL) != 0,
              !StorageAnalysisPolicy.excludes(root) else {
            reason = "unsupported_volume"; return
        }
        let mount = Data(absoluteMount.utf8)
        let prefix = absoluteMount == "/" ? Data([47]) : mount + Data([47])
        if physicalPath.starts(with: prefix), physicalPath != mount {
            relativeRoot = Data(physicalPath.dropFirst(prefix.count))
        } else {
            // A mounted volume can retain /Volumes in fstatfs/F_GETPATH while
            // NOFIRMLINK prefixes that spelling with /System/Volumes/Data.
            // Both queries use this same admitted FD. Require the exact same
            // UTF-8 suffix; do not open the mount or any ancestor to resolve it.
            guard visiblePath.starts(with: prefix), visiblePath != mount else {
                reason = "unsupported_volume"; return
            }
            let relative = Data(visiblePath.dropFirst(prefix.count))
            let suffix = Data([47]) + relative
            guard physicalPath.count > suffix.count,
                  physicalPath.suffix(suffix.count) == suffix else {
                reason = "unsupported_volume"; return
            }
            relativeRoot = relative
        }
        device = info.st_dev
        guard let uuid = Self.uuid(device) else { reason = "history_unavailable"; return }
        eventUUID = uuid
        // Captured before enumeration, never replaced by arriving callbacks.
        fence = FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
        #if DEBUG
        initialFence = fence
        #endif
        var since = fence
        if let previous {
            do { try previous.validate() } catch { reason = "cursor_out_of_range" }
            if previous.eventUUID != uuid { reason = "event_uuid_changed" }
            if let value = UInt64(previous.cursor), value != UInt64.max, value > 0, reason == nil {
                // A validated ordinary ID from this same device history is
                // Apple's restart cursor. The timestamp query is conservative,
                // not an upper bound: it cannot invalidate that saved ID.
                since = value
                fence = max(fence, value)
            } else if reason == nil { reason = "cursor_out_of_range" }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, flags, ids in
            guard let context else { return }
            let owner = Unmanaged<AnalysisRefreshEvents>.fromOpaque(context).takeUnretainedValue()
            let strings = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            owner.lock.lock(); defer { owner.lock.unlock() }
            for index in 0..<count {
                owner.consume(Data(bytes: strings[index], count: strlen(strings[index])), flags: flags[index], id: ids[index])
            }
        }
        var options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        if previous != nil { options |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFullHistory) }
        guard let created = FSEventStreamCreateRelativeToDevice(kCFAllocatorDefault, callback, &context, device,
            [String(decoding: relativeRoot, as: UTF8.self)] as CFArray, since, 0.05, options) else {
            reason = "history_unavailable"; return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) { reason = "history_unavailable"; close() }
    }

    func dirtyDirectories() throws -> [AnalysisRefreshDirtyDirectory]? {
        if cancelled() { throw CancellationError() }
        guard let stream else { return nil }
        let target = FSEventStreamFlushAsync(stream)
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if cancelled() { throw CancellationError() }
            lock.lock()
            let ready = historyDone && (target == 0 || latest >= target)
            let mustStop = reason == "root_changed" || reason == "event_ids_wrapped"
            // This is the last checkpoint adjustment, before enumeration.
            // All delivered IDs are from this device stream. A full baseline
            // also drains preexisting events so they need not dirty it again.
            if ready && !mustStop {
                fence = max(fence, latest)
                replayBarrierComplete = watchIssue == nil
                enumerationBegan = true
            }
            let result = ready && reason == nil && previous != nil ? dirtyPlan.directories : nil
            lock.unlock()
            if mustStop { return nil }
            if ready { return result }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); failWatch("replay_timeout"); lock.unlock()
        return nil
    }

    func checkpoint(catalogID: UUID, observedThrough: Date, reusedEntries: UInt64,
                    enumeratedDirectories: UInt64, reusedDirectories: UInt64, incremental: Bool) -> AnalysisRefreshCheckpoint? {
        guard finishWatchInterval() else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let eventUUID, fence > 0, Self.uuid(device) == eventUUID else { return nil }
        // An OLD UUID/cursor rejection can precede a sound full scan. A safety
        // failure in THIS interval cannot: lost events may hide changes to a
        // subtree already traversed, even when the full scan itself finishes.
        guard stream != nil, replayBarrierComplete, watchIssue == nil else { return nil }
        return AnalysisRefreshCheckpoint(catalogID: catalogID, eventUUID: eventUUID, cursor: String(fence),
            originalObservedThrough: observedThrough, reusedEntries: reusedEntries,
            enumeratedDirectories: enumeratedDirectories, isIncremental: incremental && reason == nil, fallbackReason: reason,
            reusedDirectories: reusedDirectories)
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let owned = stream; stream = nil
        lock.unlock()
        if let owned { FSEventStreamStop(owned); FSEventStreamInvalidate(owned); queue.sync {}; FSEventStreamRelease(owned) }
    }
    deinit { close() }

    #if DEBUG
    var qualificationDiagnostics: [String: String] {
        lock.lock(); defer { lock.unlock() }
        var values: [String: String] = [:]
        for group in ["old", "new", "baseline"] {
            for name in ["events", "after_enumeration", "namespace_directory", "metadata_directory"] {
                values["refresh_" + name + "_" + group] = "0"
            }
            for (_, name) in Self.diagnosticFlags { values["refresh_flag_" + name + "_" + group] = "0" }
        }
        for (key, value) in eventCounts { values[key] = String(value) }
        values["refresh_saved_cursor"] = previous?.cursor ?? "0"
        values["refresh_initial_time_fence"] = String(initialFence)
        values["refresh_fence"] = String(fence)
        values["refresh_latest_ordinary_id"] = String(latest)
        values["refresh_first_relevant_id"] = String(firstRelevantID ?? 0)
        values["refresh_last_relevant_id"] = String(lastRelevantID)
        values["refresh_saved_uuid_matches"] = previous.map { $0.eventUUID == eventUUID ? "1" : "0" } ?? "0"
        values["refresh_history_done"] = historyDone ? "1" : "0"
        values["refresh_replay_barrier_complete"] = replayBarrierComplete ? "1" : "0"
        values["refresh_peak_paths"] = String(peakPaths)
        values["refresh_peak_direct"] = String(peakDirect)
        values["refresh_peak_recursive"] = String(peakRecursive)
        values["refresh_peak_path_bytes"] = String(peakBytes)
        values["refresh_watch_reason"] = reason ?? "none"
        values["refresh_watch_issue"] = watchIssue ?? "none"
        return values
    }

    /// Diagnostic observation only; never creates or advances a checkpoint.
    func finishQualificationDiagnostics() -> [String: String] {
        let delivered = finishWatchInterval()
        close()
        var values = qualificationDiagnostics
        values["refresh_final_flush_delivered"] = delivered ? "1" : "0"
        return values
    }

    /// Caller holds lock. Fixed keys only; no path/name or unbounded histogram.
    private func countEvent(flags: UInt32, id: UInt64) {
        firstRelevantID = min(firstRelevantID ?? id, id)
        lastRelevantID = max(lastRelevantID, id)
        let group = previous.flatMap { UInt64($0.cursor) }.map { id <= $0 ? "old" : "new" } ?? "baseline"
        eventCounts["refresh_events_" + group, default: 0] += 1
        if enumerationBegan { eventCounts["refresh_after_enumeration_" + group, default: 0] += 1 }
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            if flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 {
                eventCounts["refresh_namespace_directory_" + group, default: 0] += 1
            }
            if flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
                eventCounts["refresh_metadata_directory_" + group, default: 0] += 1
            }
        }
        for (flag, name) in Self.diagnosticFlags where flags & flag != 0 {
            eventCounts["refresh_flag_" + name + "_" + group, default: 0] += 1
        }
    }
    #endif

    private static func uuid(_ device: dev_t) -> UUID? {
        guard let value = FSEventsCopyUUIDForDevice(device) else { return nil }
        return UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, value) as String)
    }

    /// Caller holds lock. Sticky for this stream's complete lifetime.
    private func failWatch(_ code: String) {
        watchIssue = watchIssue ?? code
        reason = watchIssue
        replayBarrierComplete = false
    }

    /// End-of-scan safety delivery only. This never changes the saved fence;
    /// ordinary changes after enumeration began must replay next time.
    private func finishWatchInterval() -> Bool {
        guard let stream else { return false }
        let target = FSEventStreamFlushAsync(stream)
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if cancelled() { return false }
            lock.lock()
            let failed = watchIssue != nil || !replayBarrierComplete
            let delivered = target == 0 || latest >= target
            lock.unlock()
            if failed { return false }
            if delivered { queue.sync {}; return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); failWatch("replay_timeout"); lock.unlock()
        return false
    }

    private func consume(_ path: Data, flags: FSEventStreamEventFlags, id: UInt64) {
        let historicalMarker = flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0
        if historicalMarker { historyDone = true }
        if flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { failWatch("event_ids_wrapped"); return }
        if flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { failWatch("events_dropped"); return }
        if flags & UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagMount) != 0 { failWatch("root_changed"); return }
        if historicalMarker { return }
        guard id > 0, id != UInt64.max else { failWatch("cursor_out_of_range"); return }
        latest = max(latest, id)
        var componentsPath = path
        while componentsPath.first == 47 { componentsPath.removeFirst() }
        while componentsPath.last == 47 { componentsPath.removeLast() }
        guard !componentsPath.isEmpty, componentsPath.count <= 8192, !componentsPath.contains(0),
              String(data: componentsPath, encoding: .utf8) != nil,
              !componentsPath.split(separator: 47, omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == Data([46]) || $0 == Data([46, 46]) }) else {
            failWatch("invalid_event_path"); return
        }
        // The per-device timestamp fence is conservative. Relevant events
        // after it must participate in this refresh, and can safely replay
        // again because callback arrival never advances the saved cursor.
        let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let file = flags & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
        let recursive = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
        let namespaceChange = flags & UInt32(kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
        guard let target = Self.normalize(path, relativeRoot: relativeRoot, mount: absoluteMount, recursive: true) else { return }
        #if DEBUG
        countEvent(flags: flags, id: id)
        #endif
        // Flags are hints, not a type log. MustScanSubDirs documents a
        // directory even without ItemIsDir; a file hint contradicts that scope.
        guard !(directory && file), !(recursive && file), directory || file || recursive else {
            failWatch("unknown_event"); return
        }
        // Full traversal does not need a dirty plan. Keep validating delivery,
        // paths and safety flags, without budgeting unused historical names.
        guard previous != nil, reason == nil, !enumerationBegan else { return }
        if recursive {
            dirty(target, recursive: true)
            if let parent = Self.normalize(path, relativeRoot: relativeRoot, mount: absoluteMount, recursive: false) {
                dirty(parent, recursive: false)
            }
        } else if directory {
            // Namespace changes can replace a directory incarnation. Its whole
            // subtree stays dirty even when FullHistory repeats an older event.
            if namespaceChange { dirty(target, recursive: true) }
            else { dirty(target, recursive: false) }
            if let parent = Self.normalize(path, relativeRoot: relativeRoot, mount: absoluteMount, recursive: false) {
                dirty(parent, recursive: false)
            }
        } else if file {
            if let parent = Self.normalize(path, relativeRoot: relativeRoot, mount: absoluteMount, recursive: false) {
                dirty(parent, recursive: false)
            }
        }
        #if DEBUG
        peakPaths = max(peakPaths, dirtyPlan.count)
        peakDirect = max(peakDirect, dirtyPlan.directCount)
        peakRecursive = max(peakRecursive, dirtyPlan.recursiveCount)
        peakBytes = max(peakBytes, dirtyPlan.pathBytes)
        #endif
        if dirtyPlan.exceedsLimits {
            dirtyPlan.removeAll()
            // All events arrived, but the bounded reuse plan is too broad.
            // A full scan reconciles it; true watch uncertainty remains sticky
            // independently and can still prevent that scan seeding a cursor.
            reason = "dirty_overflow"
        }
    }

    /// Caller holds lock. Recursive dirtiness always wins over direct listing.
    private func dirty(_ path: Data, recursive: Bool) {
        dirtyPlan.insert(path, recursive: recursive)
    }

    /// Per-device event paths are relative to the volume root. Reject malformed
    /// or out-of-root paths and exclusions before retaining any name bytes.
    static func normalize(_ path: Data, relativeRoot: Data, mount: String, recursive: Bool) -> Data? {
        var bytes = path
        while bytes.first == 47 { bytes.removeFirst() }
        while bytes.last == 47 { bytes.removeLast() }
        let components = bytes.split(separator: 47, omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == Data([46]) || $0 == Data([46,46]) }),
              !bytes.contains(0), let text = String(data: bytes, encoding: .utf8),
              !StorageAnalysisPolicy.excludes(URL(fileURLWithPath: mount).appendingPathComponent(text)) else { return nil }
        guard bytes == relativeRoot || bytes.starts(with: relativeRoot + Data([47])) else { return nil }
        if bytes == relativeRoot { return Data() }
        var relative = Data(bytes.dropFirst(relativeRoot.count + 1))
        if !recursive {
            if let slash = relative.lastIndex(of: 47) { relative = Data(relative[..<slash]) }
            else { relative = Data() }
        }
        return relative
    }
}
