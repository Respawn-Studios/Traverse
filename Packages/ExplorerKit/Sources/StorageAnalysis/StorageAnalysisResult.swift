import CoreFoundation
import Darwin
import ExplorerCore
import Foundation
#if DEBUG
import CryptoKit
#endif

/// Idempotent release, including deinitialization after cancelled preparation.
public final class AnalysisResultReadSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var result: StorageAnalysisResult?
    fileprivate init(result: StorageAnalysisResult) { self.result = result }
    public func release() {
        let old = lock.withLock { let old = result; result = nil; return old }
        old?.resumeReaders()
    }
    deinit { release() }
}

/// A shared, immutable session result. Keeping this handle keeps its private
/// store alive. Releasing the last handle schedules verified discard after
/// actual queued readers drain. It never retains a complete file tree.
public final class StorageAnalysisResult: @unchecked Sendable {
    public let id: UUID
    public let refreshCheckpoint: AnalysisRefreshCheckpoint?
    public let refreshFallbackReason: String?
    public let scanElapsed: TimeInterval?
    private let files: AnalysisStoreFiles
    private let workerURL: URL
    private let activityGate: FileActivityGate
    private let rowOrder: StoredAnalysisRowOrder
    private let policyBinding: AnalysisPolicyBinding
    public var classificationRevision: AnalysisClassificationRevision { policyBinding.classificationRevision }
    public var metadataPolicy: AnalysisMetadataPolicy { policyBinding.policy }
    public var supportsApplicationLayouts: Bool { policyBinding.applicationLayoutRevision == 1 }
    public var supportsSortedPages: Bool { policyBinding.sortedPageRevision == 1 }
    public var supportsPurposeJourney: Bool { policyBinding.purposeJourneyRevision == 1 }
    /// Bound from the validated result contract, including a paired catalog's
    /// synthetic source-root row. This does not grant filesystem access.
    public var maximumStoredHierarchyDepth: Int { policyBinding.maximumStoredHierarchyDepth }
    var largestFilesRevision: Int? { policyBinding.largestFilesRevision }
    var isStartupPairForQueries: Bool { policyBinding.isStartupPair }
    var maximumPathComponentsForQueries: Int { policyBinding.maximumPathComponents }
    private let scopeIsCurrent: @Sendable () -> Bool
    let locationSources: AnalysisLocationSourceScope?
    var supportsChartOverviewForRetention: Bool { policyBinding.chartOverviewRevision == 1 }
    // A fresh cold-open grant stays alive until this result's actual query
    // owners have drained; a saved locator never manufactures access.
    private var retainedAccess: (any Sendable)?
    var policyBindingForLocations: Bool { policyBinding.storedLocationRevision == 1 }
    var scopeIsCurrentForLocations: @Sendable () -> Bool { scopeIsCurrent }
    private let queue = DispatchQueue(label: "MacExplorer.AnalysisResult", qos: .utility)
    private let admission = NSLock()
    private var requests = 0
    private var permanentlyClosed = false
    private let reuseWorkerIdentity: AnalysisSessionWorkerIdentity?
    private var readSuspensions = 0
    private var controls: [ScannerProcessControl] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    public var activeReaderCount: Int { admission.withLock { requests } }
    #if DEBUG
    private var locationHook: (@Sendable () throws -> Void)?
    private var queryWorkerLaunches = 0
    private var queryReleaseHook: (@Sendable () -> Void)?
    private var queryOutcomeFailureForQualification: StorageScanFailure?
    /// Fault injection after an actual native read and release hook, before its
    /// caller receives the outcome. Not a fake result or a UI-only state setter.
    public func installQueryOutcomeFailureForQualification(_ failure: StorageScanFailure?) throws {
        try admission.withLock {
            guard requests == 0 else { throw StorageScanFailure.busy }
            queryOutcomeFailureForQualification = failure
        }
    }
    public func installQueryReleaseHookForQualification(_ hook: (@Sendable () -> Void)?) throws {
        try admission.withLock {
            guard requests == 0 else { throw StorageScanFailure.busy }
            queryReleaseHook = hook
        }
    }
    public var queryWorkerLaunchCountForQualification: Int { admission.withLock { queryWorkerLaunches } }
    public func installLocationHookForQualification(_ hook: (@Sendable () throws -> Void)?) throws {
        try admission.withLock {
            guard requests == 0 else { throw StorageScanFailure.busy }
            locationHook = hook
        }
    }
    public func retainAfterCloseForQualification() { files.preserveUncertain() }
    func runLocationHookForQualification() throws { try admission.withLock { locationHook }?() }
    #endif
    public func cancelReaders() { admission.withLock { controls }.forEach { $0.cancel() } }
    /// Close admission before cancelling/draining existing work. The lease is
    /// independent of Task cancellation and keeps this result alive until release.
    public func suspendReaders() async throws -> AnalysisResultReadSuspension {
        let admitted = admission.withLock { () -> Bool in
            guard !permanentlyClosed, readSuspensions < 16 else { return false }; readSuspensions += 1; return true
        }
        guard admitted else { throw StorageScanFailure.busy }
        let lease = AnalysisResultReadSuspension(result: self)
        cancelReaders()
        await waitUntilReadersDrained()
        return lease
    }
    fileprivate func resumeReaders() { admission.withLock { readSuspensions -= 1 } }
    public func waitUntilReadersDrained() async {
        await withCheckedContinuation { continuation in
            let immediate = admission.withLock {
                if requests == 0 { return true }; drainWaiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    private struct Cache {
        let mode: String
        let parent: UInt64, cursor: UInt64
        let facet: Int
        let frames: [Data]
    }
    // Queue-confined; two pages /512 wrappers, below4 MiB including allowance
    // for Swift object overhead. Eviction happens before adding a third page.
    private var pages: [Cache] = []

    init(id: UUID, files: AnalysisStoreFiles, workerURL: URL, activityGate: FileActivityGate, rowOrder: StoredAnalysisRowOrder = .ordinal, policyBinding: AnalysisPolicyBinding = .standard, locationSources: AnalysisLocationSourceScope? = nil, scopeIsCurrent: @escaping @Sendable () -> Bool = { true }, retainingAccess: (any Sendable)? = nil, refreshCheckpoint: AnalysisRefreshCheckpoint? = nil, refreshFallbackReason: String? = nil, scanElapsed: TimeInterval? = nil) {
        self.id = id; self.files = files; self.workerURL = workerURL; self.activityGate = activityGate
        self.refreshCheckpoint = refreshCheckpoint
        self.refreshFallbackReason = refreshFallbackReason ?? refreshCheckpoint?.fallbackReason
        self.scanElapsed = scanElapsed
        self.rowOrder = rowOrder; self.policyBinding = policyBinding; self.scopeIsCurrent = scopeIsCurrent
        self.locationSources = locationSources; self.retainedAccess = retainingAccess
        reuseWorkerIdentity = try? AnalysisSessionWorkerIdentity.read(workerURL)
    }

    /// Cold factory uses the original scan UUID and existing Rust query path.
    /// Caller first verifies fresh native root access/incarnation and passes
    /// only its live access-retention owner, never persisted locator authority.
    static func openRetained(_ record: RetainedAnalysisRecord, storage: AnalysisResultStorage,
                             workerURL: URL, activityGate: FileActivityGate,
                             admittedBy: FileActivityGate.Lease,
                             retainingAccess: any Sendable) throws -> StorageAnalysisResult {
        // The backend's one admitted lease covers this synchronous cold open.
        // Validate its gate identity; never acquire a second capacity slot.
        let activity = try activityGate.continueOrBegin(admittedBy)
        defer { withExtendedLifetime(activity) {} }
        let binding = try AnalysisPolicyBinding(retained: record)
        let observedHelper = try RetainedHelperObservation.read(workerURL, session: record.catalogID)
        guard observedHelper.sha256 == record.helperSHA256 else { throw StorageScanFailure.changed }
        guard let bytes = UInt64(record.catalog.bytes) else { throw StorageScanFailure.invalidOutput }
        let files = try AnalysisStoreFiles(openExisting: storage, id: record.catalogID,
            expectedBytes: bytes, expectedSHA256: record.catalog.sha256, activityGate: activityGate)
        return StorageAnalysisResult(id: record.catalogID, files: files, workerURL: workerURL,
            activityGate: activityGate, rowOrder: .ordinal, policyBinding: binding,
            locationSources: nil, scopeIsCurrent: { true }, retainingAccess: retainingAccess, refreshCheckpoint: record.refreshCheckpoint, scanElapsed: record.scanElapsed)
    }
    func acquireRefreshBaseline(control: ScannerProcessControl) throws -> AnalysisRefreshBaselineLease {
        guard admission.withLock({
            guard !permanentlyClosed, requests < 2, readSuspensions == 0 else { return false }
            requests += 1; controls.append(control); return true
        }) else { throw StorageScanFailure.busy }
        @Sendable func release() {
            let waiters = admission.withLock {
                controls.removeAll { $0 === control }; requests -= 1
                guard requests == 0 else { return [CheckedContinuation<Void, Never>]() }
                let values = drainWaiters; drainWaiters = []; return values
            }
            waiters.forEach { $0.resume() }
        }
        do {
            let activity = try activityGate.begin()
            try files.fresh(sealed: true)
            let descriptor = openat(files.parent, "result.sqlite", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            var observed = stat(), expected = stat()
            guard descriptor >= 0, fstat(descriptor, &observed) == 0, fstat(files.database, &expected) == 0,
                  observed.st_mode & S_IFMT == S_IFREG, observed.st_dev == expected.st_dev,
                  observed.st_ino == expected.st_ino, observed.st_size == expected.st_size else {
                if descriptor >= 0 { close(descriptor) }; throw StorageScanFailure.changed
            }
            return AnalysisRefreshBaselineLease(descriptor: descriptor, catalogID: id,
                verification: { [self] in try files.fresh(sealed: true) }) {
                withExtendedLifetime(activity) {}; release()
            }
        } catch { release(); throw error }
    }
    func retainedCatalogFingerprint(admittedBy: FileActivityGate.Lease? = nil) async throws -> RetainedAnalysisRecord.Catalog {
        // A caller already holding this gate's lease continues it across the
        // queued digest. Foreign leases are rejected by continueOrBegin.
        let activity = try activityGate.continueOrBegin(admittedBy)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { withExtendedLifetime(activity) {} }
                continuation.resume(with: Result { try files.fingerprint(id: id) })
            }
        }
    }
    func armRetentionPreservation(admittedBy: FileActivityGate.Lease? = nil) async throws {
        let activity = try activityGate.continueOrBegin(admittedBy)
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { withExtendedLifetime(activity) {} }
                continuation.resume(with: Result { try files.armRetentionPreservation() })
            }
        }
    }
    func restoreTemporaryAfterProvenNoMutation() async throws {
        let activity = try activityGate.begin()
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { withExtendedLifetime(activity) {} }
                continuation.resume(with: Result { try files.restoreTemporaryAfterProvenNoMutation() })
            }
        }
    }
    /// Distinct from discard. Caller must revoke every App consumer; this
    /// method itself closes admission, cancels and joins actual native queries.
    func closeAfterRevokingApplicationConsumersAndDrainRetaining() async -> RetainedStoreCloseReceipt? {
        admission.withLock { permanentlyClosed = true }
        cancelReaders()
        await waitUntilReadersDrained()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                pages.removeAll(); retainedAccess = nil
                continuation.resume(returning: files.closeRetainingAndReceipt(expectedID: id))
            }
        }
    }

    /// Permanent, idempotent read closure for a no-longer-owned session result.
    /// Application-ownership SPI: caller must first revoke every app presentation
    /// consumer. NEVER use this to evict only a cache reference. Stale UI references
    /// then refuse new queries. Actual queued readers, descriptors and the existing
    /// verified-discard ticket finish before acknowledgement.
    @_spi(ApplicationOwnership) public func closeAfterRevokingApplicationConsumersAndDrain() async {
        admission.withLock { permanentlyClosed = true }
        cancelReaders()
        await waitUntilReadersDrained()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                pages.removeAll(); files.discardAndClose(); continuation.resume()
            }
        }
    }

    /// Join cleanup tickets already scheduled by last-reference release. The app
    /// calls this only after revoking presentation/worker owners and joining them;
    /// it does not close any result still held by an independent consumer.
    @_spi(ApplicationOwnership) public static func waitForScheduledStoreDiscardsAndDrain() async {
        await AnalysisStoreFiles.waitForScheduledDiscards()
    }

    /// Fresh metadata-only check on the same bounded result-read lane. It is
    /// neither a scanner nor mutation authority. Initial support is APFS local
    /// single-root v4 results; startup and legacy profiles cannot be reused.
    public func validateSessionReuse(root: URL, metadataPolicy: AnalysisMetadataPolicy,
                                     retainingAccess lifetime: any Sendable) async throws -> AnalysisSessionReuseStamp {
        let control = ScannerProcessControl()
        guard admission.withLock({
            guard !permanentlyClosed, requests < 2, readSuspensions == 0 else { return false }
            requests += 1; controls.append(control); return true
        }) else { throw StorageScanFailure.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    var outcome: Swift.Result<AnalysisSessionReuseStamp, Error> = .failure(StorageScanFailure.invalidOutput)
                    defer {
                        #if DEBUG
                        admission.withLock { queryReleaseHook }?()
                        #endif
                        withExtendedLifetime(lifetime) {}
                        control.finished()
                        let waiters = admission.withLock {
                            controls.removeAll { $0 === control }; requests -= 1
                            guard requests == 0 else { return [CheckedContinuation<Void, Never>]() }
                            let old = drainWaiters; drainWaiters = []; return old
                        }
                        waiters.forEach { $0.resume() }
                        if control.cancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(with: outcome) }
                    }
                    do {
                        guard !control.cancelled else { throw CancellationError() }
                        let activity = try activityGate.begin()
                        defer { withExtendedLifetime(activity) {} }
                        try files.fresh(sealed: true)
                        guard metadataPolicy == self.metadataPolicy, policyBinding.classificationRevision == .v4,
                              !policyBinding.isStartupPair, policyBinding.maximumPathComponents == 128,
                              policyBinding.adaptiveCheckpoints,
                              policyBinding.storedLocationRevision == 1, policyBinding.sortedPageRevision == 1, policyBinding.largestFilesRevision == 1,
                              policyBinding.applicationLayoutRevision == 1, policyBinding.purposeJourneyRevision == 1,
                              let roots = locationSources?.roots, roots.count == 1, let source = roots.values.first,
                              source.isAPFS, root.standardizedFileURL == source.url, source.url.path != "/",
                              source.url.path != "/System/Volumes/Data", !StorageAnalysisPolicy.excludes(root, policy: metadataPolicy),
                              let expectedWorker = reuseWorkerIdentity,
                              try AnalysisSessionWorkerIdentity.read(workerURL) == expectedWorker else {
                            throw StorageScanFailure.unsupportedLocation
                        }
                        let descriptor = root.withUnsafeFileSystemRepresentation {
                            $0.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
                        }
                        guard descriptor >= 0 else {
                            throw errno == EACCES || errno == EPERM ? StorageScanFailure.accessDenied : .unavailable
                        }
                        defer { close(descriptor) }
                        try source.validateRoot(descriptor)
                        var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
                        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
                        var bytes = [UInt8](repeating: 0, count: 40)
                        guard fgetattrlist(descriptor, &attributes, &bytes, bytes.count, 0) == 0 else { throw StorageScanFailure.changed }
                        let volume = try StartupNativeRoot.decodeVolume(Data(bytes)).value
                        try source.validateRoot(descriptor)
                        try files.fresh(sealed: true)
                        guard !control.cancelled else { throw CancellationError() }
                        guard try AnalysisSessionWorkerIdentity.read(workerURL) == expectedWorker else { throw StorageScanFailure.changed }
                        outcome = .success(.init(resultID: id, root: source.stamp, volume: volume,
                            policy: metadataPolicy.rawValue, worker: expectedWorker))
                    } catch { outcome = .failure(error) }
                }
            }
        } onCancel: { control.cancel() }
    }

    public func summary() async throws -> StoredAnalysisSummary {
        let frames = try await query("summary")
        guard frames.count == 1, frames[0]["kind"] as? String == "summary",
              let complete = frames[0]["complete"] as? Bool,
              let projected = frames[0]["projected"] as? Bool else { throw StorageScanFailure.invalidOutput }
        let value = try StoredAnalysisValue(encoded: storedBlob(frames[0]["value"], length: 140))
        guard value.counts.total == (try storedNumber(frames[0]["entries"])) else { throw StorageScanFailure.invalidOutput }
        var result = StoredAnalysisSummary(value: value, complete: complete && scopeIsCurrent(), classificationReady: projected)
        if let sources = frames[0]["sources"] {
            guard let sources = sources as? [[String: Any]], sources.count == 2 else { throw StorageScanFailure.invalidOutput }
            var counts = AnalysisEntryCounts(), bytes = AnalysisByteSubtotals(), total: UInt64 = 0
            for (index, row) in sources.enumerated() {
                let id = try storedNumber(row["id"])
                guard id == UInt64(index + 1), let finished = row["finished"] as? Bool else { throw StorageScanFailure.invalidOutput }
                let observed = try StoredAnalysisValue(encoded: storedBlob(row["value"], length: 140))
                let (sum, overflow) = total.addingReportingOverflow(observed.counts.total)
                guard !overflow, sum <= value.counts.total else { throw StorageScanFailure.invalidOutput }; total = sum
                counts.merge(observed.counts); bytes.merge(observed.bytes)
                result.sources.append(.init(id: id, value: observed, traversalFinished: finished))
            }
            guard counts == value.counts, bytes == value.bytes else { throw StorageScanFailure.invalidOutput }
            result.verifiedAliases = try storedNumber(frames[0]["verified_aliases"])
            result.unresolvedAliases = try storedNumber(frames[0]["unresolved_aliases"])
        }
        return result
    }

    /// Cursor is the last row's opaque ID from the same parent, or zero. IDs
    /// need not increase in filename-ordered formats. Native UI replaces its
    /// visible page; it must not concatenate the whole result.
    public func page(parent: UInt64 = 0, after cursor: UInt64 = 0) async throws -> [StoredAnalysisRow] {
        guard parent < Int64.max, cursor < Int64.max else { throw StorageScanFailure.invalidOutput }
        let frames = try await query("page", parent: parent, cursor: cursor)
        return try StoredAnalysisPage.decode(frames, parent: parent, cursor: cursor, order: rowOrder)
    }

    public func groups(_ facet: StoredAnalysisFacet) async throws -> StoredAnalysisGroups {
        if facet == .applicationLayouts {
            guard supportsApplicationLayouts else { throw StorageScanFailure.invalidOutput }
            return try await .decodeApplicationLayouts(query("application-layouts"), classificationRevision: classificationRevision)
        }
        let frames = try await query("groups", facet: facet.rawValue)
        guard frames.count == 1 else { throw StorageScanFailure.invalidOutput }
        return try .decodeChartGroup(frames[0], facet: facet, classificationRevision: classificationRevision)
    }

    /// Compact chart data only: fixed type/role groups and twelve projects plus
    /// a remainder. No snapshot or complete project/folder list is constructed.
    public func attribution(scopeName: String, summary: StoredAnalysisSummary) async throws -> AnalysisAttributionReport? {
        let overview: StoredChartOverview?
        if policyBinding.chartOverviewRevision == 1 {
            overview = try await .decode(query("chart-overview-v1"), summary: summary, classificationRevision: classificationRevision)
        } else { overview = nil }
        let types: StoredAnalysisGroups
        if let overview { types = overview.fileTypes } else { types = try await groups(.fileTypes) }
        func slices(_ result: StoredAnalysisGroups) -> [AnalysisAttributionSlice] {
            result.attributionSlices(scopeName: scopeName)
        }
        if !summary.classificationReady {
            var report = AnalysisAttributionReport(categories: [], fileTypes: slices(types), projects: [], projectCount: 0,
                isComplete: false, crossFolderHardlinkObjects: 0, crossFolderHardlinkCountIsKnown: false)
            report.hasLayoutAttribution = false; return report
        }
        let roles: StoredAnalysisGroups, projects: StoredAnalysisGroups
        if let overview {
            guard let observedRoles = overview.storageRoles, let observedProjects = overview.projects else { throw StorageScanFailure.invalidOutput }
            roles = observedRoles; projects = observedProjects
        } else { roles = try await groups(.storageRoles); projects = try await groups(.projects) }
        guard projects.projectCount <= Int.max else { throw StorageScanFailure.invalidOutput }
        return .init(categories: slices(roles), fileTypes: slices(types), projects: slices(projects), projectCount: Int(projects.projectCount),
            isComplete: summary.complete, crossFolderHardlinkObjects: 0, crossFolderHardlinkCountIsKnown: false)
    }

    private struct Frames: @unchecked Sendable { let values: [[String: Any]] }
    func query(_ mode: String, parent: UInt64 = 0, cursor: UInt64 = 0, facet: Int = 0, filterKey: UInt64? = nil,
               verifyUnchangedForQualification: Bool = false, retainingAccess lifetime: (any Sendable)? = nil,
               onFrames: (@Sendable ([[String: Any]], ScannerProcessControl) throws -> Void)? = nil) async throws -> [[String: Any]] {
        let control = ScannerProcessControl()
        guard admission.withLock({ if permanentlyClosed || requests >= 2 || readSuspensions > 0 { return false }; requests += 1; controls.append(control); return true }) else { throw StorageScanFailure.busy }
        let result: Frames = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    var outcome: Swift.Result<Frames, Error> = .failure(StorageScanFailure.invalidOutput)
                    defer {
                        #if DEBUG
                        admission.withLock { queryReleaseHook }?()
                        if let failure = admission.withLock({ queryOutcomeFailureForQualification }) { outcome = .failure(failure) }
                        #endif
                        withExtendedLifetime(lifetime) {}
                        control.finished()
                        let waiters = admission.withLock {
                            controls.removeAll { $0 === control }; requests -= 1
                            guard requests == 0 else { return [CheckedContinuation<Void, Never>]() }
                            let old = drainWaiters; drainWaiters = []; return old
                        }
                        waiters.forEach { $0.resume() }
                        // A dependent request may start as soon as its caller
                        // resumes. Retire this slot first, including cache and
                        // error paths, rather than exposing a transient Busy.
                        if control.cancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(with: outcome) }
                    }
                    do {
                        guard !control.cancelled else { throw CancellationError() }
                        let activity = try activityGate.begin()
                        defer { withExtendedLifetime(activity) {} }
                        try files.fresh(sealed: true)
                        #if DEBUG
                        let fingerprint = verifyUnchangedForQualification ? try qualificationFingerprint(control) : nil
                        #else
                        guard !verifyUnchangedForQualification else { throw StorageScanFailure.invalidOutput }
                        #endif
                        if mode == "page" || mode == "sorted-page", let cache = pages.first(where: { $0.mode == mode && $0.parent == parent && $0.cursor == cursor && $0.facet == facet }) {
                            let decoded = try cache.frames.map { data -> [String: Any] in
                                guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StorageScanFailure.invalidOutput }
                                return frame
                            }
                            try files.fresh(sealed: true)
                            guard !control.cancelled else { throw CancellationError() }
                            try onFrames?(decoded, control)
                            guard !control.cancelled else { throw CancellationError() }
                            outcome = .success(Frames(values: decoded)); return
                        }
                        #if DEBUG
                        admission.withLock { queryWorkerLaunches += 1 }
                        #endif
                        let pipes = try ScannerWorkerProcess.launch(workerURL: workerURL, descriptors: files.descriptors,
                            arguments: ["--read-result", files.path.path, "--result-quota", String(files.quota),
                                "--session", id.uuidString, "--query", mode, "--parent", String(parent),
                                "--after", String(cursor), "--facet", String(facet)] + (filterKey.map { ["--filter-key", String($0)] } ?? []) + policyBinding.arguments, control: control)
                        var frames: [[String: Any]] = [], rawFrames: [Data] = [], bytes = 0
                        var prelude = false
                        let status = try ScannerWorkerProcess.drain(pipes: pipes, control: control, deadline: 15) { data in
                            bytes += data.count
                            guard bytes <= (mode == "largest-files" ? 512 : 256) << 10, frames.count < (mode == "largest-files" ? 9 : 5),
                                  let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StorageScanFailure.invalidOutput }
                            if policyBinding.policyAware && !prelude {
                                try policyBinding.validateQueryPrelude(frame, session: id); prelude = true; return
                            }
                            guard frame["kind"] as? String != "policy" else { throw StorageScanFailure.invalidOutput }
                            frames.append(frame)
                            rawFrames.append(data)
                        }
                        guard !control.cancelled else { throw CancellationError() }
                        guard status == 0 else { throw StorageScanFailure.workerFailed }
                        guard !policyBinding.policyAware || prelude else { throw StorageScanFailure.invalidOutput }
                        try files.fresh(sealed: true)
                        try onFrames?(frames, control)
                        guard !control.cancelled else { throw CancellationError() }
                        #if DEBUG
                        if let fingerprint, try qualificationFingerprint(control) != fingerprint { throw StorageScanFailure.changed }
                        #endif
                        if mode == "page" || mode == "sorted-page" {
                            if pages.count == 2 { pages.removeFirst() }
                            pages.append(.init(mode: mode, parent: parent, cursor: cursor, facet: facet, frames: rawFrames))
                        }
                        outcome = .success(Frames(values: frames))
                    } catch {
                        if error as? StorageScanFailure == .changed { files.preserveUncertain() }
                        outcome = .failure(error)
                    }
                }
            }
        } onCancel: { control.cancel() }
        return result.values
    }

    #if DEBUG
    /// Runs inside the existing reader queue/lease. Uses pread so hashing cannot
    /// change another reader's file position. Never opens a source/user file.
    private func qualificationFingerprint(_ control: ScannerProcessControl) throws -> SHA256.Digest {
        var observed = stat()
        guard fstat(files.database, &observed) == 0, observed.st_size >= 0, UInt64(observed.st_size) <= files.quota else { throw StorageScanFailure.changed }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        var offset: off_t = 0
        while offset < observed.st_size {
            guard !control.cancelled else { throw CancellationError() }
            let size = min(buffer.count, Int(observed.st_size - offset))
            let count = buffer.withUnsafeMutableBytes { pread(files.database, $0.baseAddress, size, offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            hasher.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        try files.fresh(sealed: true)
        return hasher.finalize()
    }

    public func classificationAuditForQualification() async throws -> StoredClassificationAudit {
        try StoredClassificationAudit.decode(await query("classification-audit", verifyUnchangedForQualification: true))
    }
    #endif
}

func strictInteger(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue == Double(value.intValue) else { return nil }; return value.intValue
}


/// Opaque fresh binding; app code cannot synthesize a matching sealed-result
/// stamp. It contains no authority and does not claim filesystem freshness.
public struct AnalysisSessionReuseStamp: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let resultID: UUID
    fileprivate let root: AnalysisLocationSourceScope.Root.Stamp
    fileprivate let volume: UUID
    fileprivate let policy: String
    fileprivate let worker: AnalysisSessionWorkerIdentity
    public var description: String { "<validated session analysis binding>" }
    public var debugDescription: String { description }
}
fileprivate struct AnalysisSessionWorkerIdentity: Equatable, Sendable {
    let device: Int32, inode: UInt64, generation: UInt32, bytes: Int64
    let birthSeconds: Int, birthNanos: Int, modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard url.isFileURL, url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0,
              value.st_mode & S_IFMT == S_IFREG else { throw StorageScanFailure.changed }
        return .init(device: value.st_dev, inode: value.st_ino, generation: value.st_gen, bytes: value.st_size,
            birthSeconds: value.st_birthtimespec.tv_sec, birthNanos: value.st_birthtimespec.tv_nsec,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec)
    }
}
