import ExplorerCore
import Foundation

// App-owned retained analysis seam. Its initializer performs no disk operation
// or native launch; current source access is required when admitting a read.
@_spi(ApplicationOwnership) public struct RecordedSingleRootAccess: Sendable {
    public let root: URL
    public let retainingAccess: any Sendable
    public init(root: URL, retainingAccess: any Sendable) {
        self.root = root; self.retainingAccess = retainingAccess
    }
}

@_spi(ApplicationOwnership) public struct RecordedStartupRootAccess: Sendable {
    public let plan: StartupStoragePlan
    public let retainingAccess: any Sendable
    public init(plan: StartupStoragePlan, retainingAccess: any Sendable) {
        self.plan = plan; self.retainingAccess = retainingAccess
    }
}

/// The App must acquire a *current* scope-bearing lifetime for each open.
/// Recorded locators and catalog IDs are never access grants.
@_spi(ApplicationOwnership) public protocol RecordedAnalysisAccessProvider: Sendable {
    func acquireSingle(recordedRoot: URL) async throws -> RecordedSingleRootAccess
    func acquireStartup() async throws -> RecordedStartupRootAccess
}

private struct RecordedAccessAdapter: RetainedFreshAccessProvider {
    let provider: any RecordedAnalysisAccessProvider
    func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess {
        switch record.scope {
        case .single(let root):
            let grant = try await provider.acquireSingle(recordedRoot: URL(fileURLWithPath: root.locator, isDirectory: true))
            return .single(grant.root, grant.retainingAccess)
        case .startup:
            let grant = try await provider.acquireStartup()
            return .startup(grant.plan, grant.retainingAccess)
        }
    }
}

@_spi(ApplicationOwnership) public enum RecordedAnalysisStatus: Sendable {
    case complete, partial
}

@_spi(ApplicationOwnership) public struct RecordedAnalysisCoverage: Sendable {
    /// Notice counts, never a count of distinct missing objects or bytes.
    public let reasonCounts: [UInt64]
    public let reportedNotices: UInt64
    public let workerNotices: UInt64
    public let uncategorizedNotices: UInt64
    public let reasonCountsAreComplete: Bool
    public let terminalReason: AnalysisScanCoverageReason?
    public let hasGaps: Bool
    private let terminalScanCoverage: AnalysisScanCoverage
    public var scanCoverage: AnalysisScanCoverage { terminalScanCoverage }

    fileprivate init(_ value: RetainedAnalysisRecord.Coverage) throws {
        let counts = value.reasonCounts.compactMap(UInt64.init)
        guard counts.count == 12,
              let reported = UInt64(value.reportedNotices),
              let worker = UInt64(value.workerNotices),
              let uncategorized = UInt64(value.uncategorizedNotices) else {
            throw RetainedAnalysisFailure.invalid
        }
        reasonCounts = counts
        reportedNotices = reported; workerNotices = worker
        uncategorizedNotices = uncategorized
        reasonCountsAreComplete = value.reasonCountsAreComplete
        terminalReason = value.terminalReason.flatMap(AnalysisScanCoverageReason.init(rawValue:))
        hasGaps = value.hasGaps
        terminalScanCoverage = try AnalysisScanCoverage(retained: value)
    }
}

/// Immutable recorded facts. The lexical root is for display/matching only.
@_spi(ApplicationOwnership) public struct RecordedAnalysisMetadata: Sendable {
    public let catalogID: UUID
    public let recordedSingleRoot: URL?
    public let isStartupPair: Bool
    public let observedFrom: Date
    public let observedThrough: Date
    public let status: RecordedAnalysisStatus
    public let coverage: RecordedAnalysisCoverage
    public let committedEntries: UInt64
    public let metadataPolicy: AnalysisMetadataPolicy
    public let refreshCheckpoint: AnalysisRefreshCheckpoint?
    public let scanElapsed: TimeInterval?

    fileprivate init(_ record: RetainedAnalysisRecord) throws {
        try record.validate()
        guard let from = Int64(record.observedFrom.seconds),
              let through = Int64(record.observedThrough.seconds),
              let entries = UInt64(record.committedEntries),
              let policy = AnalysisMetadataPolicy(rawValue: record.metadataPolicy) else {
            throw RetainedAnalysisFailure.invalid
        }
        catalogID = record.catalogID
        refreshCheckpoint = record.refreshCheckpoint
        scanElapsed = record.scanElapsed
        if case .single(let root) = record.scope {
            recordedSingleRoot = URL(fileURLWithPath: root.locator, isDirectory: true)
        } else { recordedSingleRoot = nil }
        isStartupPair = record.scope.isStartup
        observedFrom = Date(timeIntervalSince1970: Double(from) + Double(record.observedFrom.nanoseconds) / 1_000_000_000)
        observedThrough = Date(timeIntervalSince1970: Double(through) + Double(record.observedThrough.nanoseconds) / 1_000_000_000)
        status = record.complete ? .complete : .partial
        coverage = try RecordedAnalysisCoverage(record.coverage)
        committedEntries = entries; metadataPolicy = policy
    }
}

/// One consumer's revocable read lane over the catalog's single native result.
/// A stale view cannot admit a new query or return a late result after revoke.
@_spi(ApplicationOwnership) public final class RecordedAnalysisQueries: @unchecked Sendable {
    private let result: StorageAnalysisResult
    private let retainingAccess: any Sendable
    private let lock = NSLock()
    private var revoked = false
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    private var revocationStartWaiters: [CheckedContinuation<Void, Never>] = []
    func waitForRevocationStartForQualification() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if revoked { return true }
                revocationStartWaiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    #endif
    public let catalogID: UUID
    public let viewID: UUID
    fileprivate init(_ result: StorageAnalysisResult, retainingAccess: any Sendable,
                     viewID: UUID) {
        self.result = result; self.retainingAccess = retainingAccess
        catalogID = result.id; self.viewID = viewID
    }
    /// The App may issue a distinct read-only view for its existing live
    /// result. It must revoke and join that view when its model closes.
    public static func live(_ result: StorageAnalysisResult,
                            retainingAccess: any Sendable) -> RecordedAnalysisQueries {
        .init(result, retainingAccess: retainingAccess, viewID: UUID())
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (StorageAnalysisResult) async throws -> T) async throws -> T {
        let admitted = lock.withLock { () -> Bool in
            guard !revoked else { return false }
            inFlight += 1; return true
        }
        guard admitted else { throw StorageScanFailure.changed }
        defer {
            withExtendedLifetime(retainingAccess) {}
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                inFlight -= 1
                guard inFlight == 0 else { return [] }
                let old = waiters; waiters = []; return old
            }
            ready.forEach { $0.resume() }
        }
        let value = try await body(result)
        guard lock.withLock({ !revoked }) else { throw StorageScanFailure.changed }
        return value
    }

    fileprivate func revokeAdmissions() {
        #if DEBUG
        var started: [CheckedContinuation<Void, Never>] = []
        #endif
        lock.withLock {
            revoked = true
            #if DEBUG
            started = revocationStartWaiters; revocationStartWaiters = []
            #endif
        }
        #if DEBUG
        started.forEach { $0.resume() }
        #endif
    }
    fileprivate func joinInFlight() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                guard inFlight > 0 else { return true }
                waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    public func revokeAndJoin() async {
        revokeAdmissions()
        await joinInFlight()
    }
    fileprivate var activeQueryCount: Int { lock.withLock { inFlight } }

    public var classificationRevision: AnalysisClassificationRevision { result.classificationRevision }
    public var metadataPolicy: AnalysisMetadataPolicy { result.metadataPolicy }
    public var maximumStoredHierarchyDepth: Int { result.maximumStoredHierarchyDepth }
    public var supportsApplicationLayouts: Bool { result.supportsApplicationLayouts }
    public var supportsSortedPages: Bool { result.supportsSortedPages }
    public var supportsPurposeJourney: Bool { result.supportsPurposeJourney }
    public var supportsLargestFiles: Bool { result.supportsLargestFiles }

    public func summary() async throws -> StoredAnalysisSummary { try await read { try await $0.summary() } }
    public func folderValue(relativeComponents: [Data]) async throws -> StoredAnalysisValue? {
        try await read { try await $0.recordedFolderValue(relativeComponents: relativeComponents) }
    }
    public func page(parent: UInt64 = 0, after cursor: UInt64 = 0) async throws -> [StoredAnalysisRow] {
        try await read { try await $0.page(parent: parent, after: cursor) }
    }
    public func sortedPage(parent: UInt64 = 0, after cursor: UInt64 = 0,
                           order: StoredAnalysisSortOrder = .logicalDescending) async throws -> StoredAnalysisSortedPage {
        try await read { try await $0.sortedPage(parent: parent, after: cursor, order: order) }
    }
    public func groups(_ facet: StoredAnalysisFacet) async throws -> StoredAnalysisGroups {
        try await read { try await $0.groups(facet) }
    }
    public func attribution(scopeName: String, summary: StoredAnalysisSummary) async throws -> AnalysisAttributionReport? {
        try await read { try await $0.attribution(scopeName: scopeName, summary: summary) }
    }
    public func breakdown(_ target: StoredAnalysisDrillTarget,
                          metric: AnalysisByteMetric = .dataLogical) async throws -> StoredAnalysisBreakdown {
        try await read { try await $0.breakdown(target, metric: metric) }
    }
    public func projectComposition(_ target: StoredAnalysisDrillTarget,
                                   metric: AnalysisByteMetric = .dataLogical) async throws -> StoredProjectComposition {
        try await read { try await $0.projectComposition(target, metric: metric) }
    }
    public func largestFiles(metric: AnalysisLargestFileMetric = .logical) async throws -> StoredLargestFiles {
        try await read { try await $0.largestFiles(metric: metric) }
    }
    public func purposeProjects(_ role: AnalysisCategory,
                                metric: AnalysisByteMetric = .dataLogical) async throws -> StoredPurposeProjects {
        try await read { try await $0.purposeProjects(role, metric: metric) }
    }
    public func purposeLocations(role: AnalysisCategory, project: UInt64,
                                 metric: AnalysisByteMetric = .dataLogical) async throws -> StoredPurposeLocations {
        try await read { try await $0.purposeLocations(role: role, project: project, metric: metric) }
    }
    public func explainOther(folder: UInt64 = 0) async throws -> StoredAnalysisOtherExplanation {
        try await read { try await $0.explainOther(folder: folder) }
    }
}

/// Every call to openRecorded issues a distinct revocable consumer query view.
@_spi(ApplicationOwnership) public struct RecordedAnalysisPresentation: Sendable {
    public let metadata: RecordedAnalysisMetadata
    public let queries: RecordedAnalysisQueries
    public let consumerID: UUID
    fileprivate init(metadata: RecordedAnalysisMetadata, queries: RecordedAnalysisQueries,
                     consumerID: UUID) {
        self.metadata = metadata; self.queries = queries; self.consumerID = consumerID
    }
}

@_spi(ApplicationOwnership) public struct RecordedAnalysisProgress: Sendable {
    public let status: StorageScanStatus
    public let committedEntries: UInt64
    public let elapsed: TimeInterval
    public let coverage: AnalysisScanCoverage
    public let workerDrained: Bool
    public let isStartupPair: Bool
    public let provisionalFileTypes: CommittedAnalysisPrefix?
    public let workerPeakResidentBytes: UInt64?
    public let diagnostics: AnalysisScanDiagnostics?
    fileprivate init(_ update: PagedStorageScanUpdate) {
        status = update.status; committedEntries = update.committedEntries
        elapsed = update.elapsed; coverage = update.coverage
        workerDrained = update.workerDrained
        isStartupPair = update.isStartupPair
        provisionalFileTypes = update.provisionalFileTypes
        workerPeakResidentBytes = update.workerPeakResidentBytes
        diagnostics = update.diagnostics
    }
}

@_spi(ApplicationOwnership) public enum RecordedAnalysisIssue: Equatable, Sendable {
    case busy, accessDenied, changed, cancelled, unavailable
    case indexRequiresAttention, retentionPending, consumerDrainPending
    case scan(StorageScanFailure)
}

@_spi(ApplicationOwnership) public enum RecordedAnalysisInventory: Sendable {
    case ready([RecordedAnalysisMetadata])
    case unavailable(RecordedAnalysisIssue)
    case needsAttention(RecordedAnalysisIssue)
}

@_spi(ApplicationOwnership) public enum RecordedAnalysisOutcome: Sendable {
    case ready(RecordedAnalysisPresentation)
    case liveTransient(RecordedLiveTransientPresentation)
    case unavailable(RecordedAnalysisIssue)
    case needsAttention(RecordedAnalysisIssue)
}

/// One explicit scan admission. The App consumes this same paged session for
/// its existing progress and result presentation, then returns its terminal
/// update for one-shot retained publication after the worker has drained.
@_spi(ApplicationOwnership) public struct RecordedScanAdmission: Sendable {
    public let session: PagedStorageScanSession
    fileprivate let token: UUID
    fileprivate init(session: PagedStorageScanSession, token: UUID) {
        self.session = session; self.token = token
    }
}

@_spi(ApplicationOwnership) public enum RecordedScanStart: Sendable {
    case started(RecordedScanAdmission)
    case unavailable(RecordedAnalysisIssue)
    case needsAttention(RecordedAnalysisIssue)
}

/// Accepted means this owner now holds the exact result through a warm pin,
/// pending publication or revocable transient view. The App must release its
/// raw reference without invoking the temporary result close path. On a
/// refusal, the App retains its original result-close responsibility.
@_spi(ApplicationOwnership) public enum RecordedScanAdoption: Sendable {
    case accepted(RecordedAnalysisOutcome)
    case notAdopted(RecordedAnalysisIssue)
    case unresolved(RecordedAnalysisIssue)
}

@_spi(ApplicationOwnership) public enum RecordedScanAbandonment: Sendable {
    case abandoned
    case ownerRetainsResult
    case unresolved
}

@_spi(ApplicationOwnership) public struct RecordedLiveTransientPresentation: Sendable {
    public let catalogID: UUID
    public let consumerID: UUID
    public let queries: RecordedAnalysisQueries
    public let terminal: RecordedAnalysisProgress
}

@_spi(ApplicationOwnership) public struct RecordedRetainingQuitReceipt: Sendable {
    public let generation: UUID
    public let indexKnown: Bool
    public let nativeOwnersClosed: Bool
    public let appConsumersJoined: Bool
    public let ownershipWorkJoined: Bool
    fileprivate init(generation: UUID) {
        self.generation = generation; indexKnown = true
        nativeOwnersClosed = true; appConsumersJoined = true
        ownershipWorkJoined = true
    }
}

@_spi(ApplicationOwnership) public enum RecordedAnalysisCoordination: Sendable {
    case complete
    case retainingQuit(RecordedRetainingQuitReceipt)
    case unavailable(RecordedAnalysisIssue)
    case needsAttention(RecordedAnalysisIssue)
}

@_spi(ApplicationOwnership) public struct RecordedAnalysisOwnershipSnapshot: Sendable {
    public let admissionsFenced: Bool
    public let resumeInFlight: Bool
    public let initializing: Bool
    public let opening: Int
    public let closing: Int
    public let scanning: Bool
    public let publishing: Bool
    public let activeOperations: Int
    public let queryViews: Int
    public let queriesInFlight: Int
    public let unresolvedPublications: Int
    public let ownedCatalogs: Int
    public let liveTransientResults: Int
    public let controllerHasWork: Bool
    public let indexKnown: Bool
}

/// The App owns its actual view/query tasks. Revocation must remove every
/// presentation reference and join those tasks before native closure.
@_spi(ApplicationOwnership) public protocol RecordedAnalysisConsumerDrain: Sendable {
    func revokeAndJoin(catalogID: UUID) async throws
    func revokeAllAndJoin() async throws
}

/// App-owned tasks for exactly one model/view. No other catalog consumer is
/// cancelled when this one model releases its query authority.
@_spi(ApplicationOwnership) public protocol RecordedAnalysisViewConsumerDrain: Sendable {
    func revokeAndJoin(consumerID: UUID) async throws
}

private struct RecordedOneDrain: RetainedApplicationConsumerDrain {
    let catalogID: UUID
    let consumers: any RecordedAnalysisConsumerDrain
    let views: [RecordedAnalysisQueries]
    func revokeAndJoin() async throws {
        for view in views { view.revokeAdmissions() }
        try await consumers.revokeAndJoin(catalogID: catalogID)
        for view in views { await view.joinInFlight() }
    }
}
private struct RecordedAllDrain: RetainedApplicationConsumerDrain {
    let consumers: any RecordedAnalysisConsumerDrain
    let views: [RecordedAnalysisQueries]
    func revokeAndJoin() async throws {
        for view in views { view.revokeAdmissions() }
        try await consumers.revokeAllAndJoin()
        for view in views { await view.joinInFlight() }
    }
}
private struct RecordedRetiredDrain: RetainedRetiredConsumerDrain {
    let consumers: any RecordedAnalysisConsumerDrain
    let views: [UUID: [RecordedAnalysisQueries]]
    func revokeAndJoin(catalogID: UUID) async throws {
        for view in views[catalogID] ?? [] { view.revokeAdmissions() }
        try await consumers.revokeAndJoin(catalogID: catalogID)
        for view in views[catalogID] ?? [] { await view.joinInFlight() }
    }
}
private struct RecordedNoConsumers: RetainedApplicationConsumerDrain {
    func revokeAndJoin() async throws {}
}

@_spi(ApplicationOwnership) public actor RecordedAnalysisOwner {
    /// Every explicit full-result scan sharing a pool with recorded results
    /// must prepare and validate its canonical sidecar before the pool admits
    /// a new store. This also applies when recording is disabled: old catalog
    /// tombstones still reserve bytes and own their exact cleanup markers.
    /// Passive Properties lookup never calls this creating operation.
    public nonisolated static func prepareSharedPoolForExplicitAnalysis(
        storage: AnalysisResultStorage, activityGate: FileActivityGate
    ) async throws {
        guard let directory = storage.retentionStateDirectory else {
            throw StorageScanFailure.unsupportedLocation
        }
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        let index = RetainedNativeIndexStore(directory: directory)
        try await index.bootstrap()
        _ = try await index.load()
    }

    private enum OwnershipKind { case initialize, open, close, scan, publication }
    private struct OwnedCatalog {
        let metadata: RecordedAnalysisMetadata
        let result: StorageAnalysisResult
        var views: [UUID: RecordedAnalysisQueries] = [:]
    }
    private struct OwnedTransient {
        let result: StorageAnalysisResult
        let terminal: RecordedAnalysisProgress
        var views: [UUID: RecordedAnalysisQueries] = [:]
    }
    private struct PendingPublication {
        let result: StorageAnalysisResult
        let retainingAccess: any Sendable
        let terminal: RecordedAnalysisProgress?
        let status: RetainedPublicationStatus?
    }
    private enum ScanRequest: Sendable {
        case single(URL, AnalysisMetadataPolicy, any Sendable)
        case startup(StartupStoragePlan, StartupVolumeDiscovery, AnalysisMetadataPolicy, any Sendable)
        var retainingAccess: any Sendable {
            switch self {
            case .single(_, _, let access), .startup(_, _, _, let access): return access
            }
        }
    }
    private struct ScanWork {
        let id: UUID
        let task: Task<RecordedAnalysisOutcome, Never>
    }
    private struct AdmittedScan {
        enum State { case scanning, adopting, abandoning }
        let token: UUID
        let workID: UUID
        let session: PagedStorageScanSession
        let ticket: RetainedPublicationTicket
        let controller: RetainedAnalysisController
        let retainingAccess: any Sendable
        let replacing: UUID?
        let baselineView: RecordedAnalysisPresentation?
        var state: State = .scanning
        var abandonRequested = false
    }
    private let scanner: StorageScanner
    private let storage: AnalysisResultStorage
    private let backend: RetainedNativeBackend
    private var controller: RetainedAnalysisController?
    private var initializing = false
    private var presentations: [UUID: OwnedCatalog] = [:]
    private var liveTransients: [UUID: OwnedTransient] = [:]
    private var pendingPublication: PendingPublication?
    private var openingCatalogs: Set<UUID> = []
    private var closingCatalogs: Set<UUID> = []
    private var closingAll = false
    private var closingIntent: RetainedRevocationIntent?
    private var completedRetainingQuit: RecordedRetainingQuitReceipt?
    private var resumingQuitGeneration: UUID?
    private var pendingRevocation: (ticket: RetainedRevocationTicket, intent: RetainedRevocationIntent)?
    private var pendingResumeAfterForget = false
    private var finishingRevocation = false
    private var scanWork: ScanWork?
    private var admittedScan: AdmittedScan?
    private var startingAdmittedScan = false
    private var completedAdmittedScans: [UUID: Bool] = [:]
    private var completedAdmissionOrder: [UUID] = []
    private var admittedScanWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var ownershipWork: [UUID: OwnershipKind] = [:]
    private var ownershipWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    private var afterConsumerRevokeForQualification: (@Sendable () async -> Void)?
    private var beforeResumeAdmissionsForQualification: (@Sendable () async -> Void)?
    private var beforeAdmittedPublicationForQualification: (@Sendable () async -> Void)?
    private var afterAdmittedAbandonRequestForQualification: (@Sendable () async -> Void)?
    func installBeforeAdmittedPublicationForQualification(_ hook: (@Sendable () async -> Void)?) {
        beforeAdmittedPublicationForQualification = hook
    }
    func installAfterAdmittedAbandonRequestForQualification(_ hook: (@Sendable () async -> Void)?) {
        afterAdmittedAbandonRequestForQualification = hook
    }
    func installAfterConsumerRevokeForQualification(_ hook: (@Sendable () async -> Void)?) {
        afterConsumerRevokeForQualification = hook
    }
    func installBeforeResumeAdmissionsForQualification(_ hook: (@Sendable () async -> Void)?) {
        beforeResumeAdmissionsForQualification = hook
    }
    func resultForQualification(_ catalogID: UUID) -> StorageAnalysisResult? {
        presentations[catalogID]?.result ?? liveTransients[catalogID]?.result ??
            (pendingPublication?.result.id == catalogID ? pendingPublication?.result : nil)
    }
    func installAfterPreservationForQualification(_ hook: (@Sendable () async -> Void)?) async {
        await backend.installAfterPreservationForQualification(hook)
    }
    func installBeforePublicationIntentForQualification(_ hook: (@Sendable () async -> Void)?) async {
        await backend.installBeforePublicationIntentForQualification(hook)
    }
    func setIndexFaultForQualification(_ fault: RetainedIndexFault?) async {
        await backend.setIndexFaultForQualification(fault)
    }
    #endif

    private func beginOwnership(_ kind: OwnershipKind) -> UUID {
        let id = UUID(); ownershipWork[id] = kind; return id
    }
    private func endOwnership(_ id: UUID) {
        ownershipWork.removeValue(forKey: id)
        guard ownershipWork.isEmpty else { return }
        let waiters = ownershipWaiters; ownershipWaiters = []
        waiters.forEach { $0.resume() }
    }
    private func joinOwnershipWork() async {
        await withCheckedContinuation { continuation in
            if ownershipWork.isEmpty { continuation.resume() }
            else { ownershipWaiters.append(continuation) }
        }
    }
    public func ownershipSnapshot() async -> RecordedAnalysisOwnershipSnapshot {
        let native = await controller?.snapshot()
        let views = presentations.values.flatMap { Array($0.views.values) }
            + liveTransients.values.flatMap { Array($0.views.values) }
        return .init(admissionsFenced: closingAll,
            resumeInFlight: resumingQuitGeneration != nil,
            initializing: initializing || ownershipWork.values.contains { if case .initialize = $0 { return true }; return false },
            opening: openingCatalogs.count, closing: closingCatalogs.count,
            scanning: scanWork != nil || admittedScan != nil || startingAdmittedScan ||
                ownershipWork.values.contains { if case .scan = $0 { return true }; return false },
            publishing: ownershipWork.values.contains { if case .publication = $0 { return true }; return false },
            activeOperations: ownershipWork.count, queryViews: views.count,
            queriesInFlight: views.reduce(0) { $0 + $1.activeQueryCount },
            unresolvedPublications: pendingPublication == nil ? 0 : 1,
            ownedCatalogs: presentations.count,
            liveTransientResults: liveTransients.count,
            controllerHasWork: native?.hasWork ?? false,
            indexKnown: native?.indexKnown ?? false)
    }
    /// A complete local-work join once the owner has fenced admissions. The
    /// returned snapshot is observational; Quit uses its own guarded receipt.
    public func awaitOwnershipWorkBarrier() async -> RecordedAnalysisOwnershipSnapshot {
        await joinOwnershipWork()
        return await ownershipSnapshot()
    }

    /// Inert composition. Passive lookup only opens an existing index;
    /// explicit scan or repair is the sole creating/recovery path.
    public init(scanner: StorageScanner, storage: AnalysisResultStorage,
                workerURL: URL, activityGate: FileActivityGate,
                accessProvider: any RecordedAnalysisAccessProvider) throws {
        guard scanner.workerURL == workerURL, scanner.activityGate === activityGate,
              let indexDirectory = storage.retentionStateDirectory else {
            throw StorageScanFailure.unsupportedLocation
        }
        self.scanner = scanner; self.storage = storage
        backend = try RetainedNativeBackend(storage: storage, indexDirectory: indexDirectory,
            workerURL: workerURL, activityGate: activityGate,
            accessProvider: RecordedAccessAdapter(provider: accessProvider))
    }

    #if DEBUG
    /// Read-only diagnosis through the same canonical record, fresh access and
    /// sealed native owner. No query or scan helper is started.
    public func inspectRefreshEventsForQualification(_ catalogID: UUID) async throws -> [String: String] {
        guard !closingAll, scanWork == nil, admittedScan == nil, !startingAdmittedScan,
              pendingPublication == nil else { throw StorageScanFailure.busy }
        guard case .ready(let view) = await openRecorded(catalogID) else { throw StorageScanFailure.unavailable }
        let workID = beginOwnership(.open)
        defer { endOwnership(workID) }
        do {
            guard !closingAll, let controller, let index = await controller.recordedIndex(),
                  let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }),
                  let owned = presentations[catalogID], owned.views[view.consumerID] === view.queries else {
                throw StorageScanFailure.changed
            }
            guard record.complete, record.metadataPolicy == AnalysisMetadataPolicy.standard.rawValue,
                  !record.scope.isStartup, record.refreshCheckpoint != nil else { throw StorageScanFailure.unsupportedLocation }
            let state = await controller.snapshot()
            guard state.admissionsOpen, !state.hasWork else { throw StorageScanFailure.busy }
            guard case .valid(.single(let root, let lifetime)) = await backend.validateCurrentPresentation(record,
                expectedEpoch: index.epoch, result: owned.result), !closingAll else { throw StorageScanFailure.changed }
            let values = try await scanner.inspectRefreshEventsForQualification(record: record, root: root, retainingAccess: lifetime)
            guard !Task.isCancelled, !closingAll, let after = await controller.recordedIndex(),
                  after.epoch == index.epoch, after.visibleRecords.contains(record) else { throw StorageScanFailure.changed }
            await releaseIncrementalView(view)
            return values
        } catch {
            await releaseIncrementalView(view)
            throw error
        }
    }
    #endif

    /// Open-existing sidecar only: no bootstrap, stage recovery, catalog
    /// deletion, access prompt, helper launch, or scan on passive Properties.
    public func inspectRecorded() async -> RecordedAnalysisInventory {
        if closingAll { return .unavailable(.busy) }
        let workID = beginOwnership(.initialize)
        defer { endOwnership(workID) }
        if controller == nil {
            guard !initializing else { return .unavailable(.busy) }
            initializing = true
            defer { initializing = false }
            do {
                let current = try await backend.loadCanonicalIndex()
                controller = RetainedAnalysisController(initial: current, backend: backend)
            } catch { return indexLoadIssue(error) }
        }
        guard let controller, let index = await controller.recordedIndex() else {
            return .needsAttention(.indexRequiresAttention)
        }
        let snapshot = await controller.snapshot()
        if closingAll { return .unavailable(.busy) }
        guard snapshot.indexKnown else { return .needsAttention(.indexRequiresAttention) }
        if !index.pendingForget.isEmpty || index.retiring != nil || snapshot.pins > 0 {
            return .needsAttention(.retentionPending)
        }
        guard snapshot.admissionsOpen else { return .needsAttention(.retentionPending) }
        do { return .ready(try index.visibleRecords.map(RecordedAnalysisMetadata.init)) }
        catch { return .needsAttention(.indexRequiresAttention) }
    }

    /// This is a first-use writer for recorded admission. The shared-pool
    /// preparation API also bootstraps before an ordinary explicit scan.
    /// Native bootstrap accepts exact
    /// absent/empty state or an existing canonical index; unknown inventory
    /// remains needsAttention and is never treated as an empty list.
    private func prepareForExplicitScan() async -> RecordedAnalysisInventory {
        guard !closingAll, scanWork == nil, admittedScan == nil, pendingPublication == nil,
              !initializing else { return .unavailable(.busy) }
        if controller == nil {
            initializing = true
            defer { initializing = false }
            do {
                try await backend.prepareForExplicitApplicationUse()
                let current = try await backend.loadCanonicalIndex()
                controller = RetainedAnalysisController(initial: current, backend: backend)
            } catch { return indexLoadIssue(error) }
        }
        return await inspectRecorded()
    }

    /// Explicit repair commands, never invoked by inspectRecorded or init.
    public func repairInterruptedStage() async -> RecordedAnalysisInventory {
        guard controller == nil, presentations.isEmpty, scanWork == nil, admittedScan == nil, !closingAll,
              !initializing else {
            return .unavailable(.busy)
        }
        let workID = beginOwnership(.initialize)
        defer { endOwnership(workID) }
        do {
            initializing = true
            defer { initializing = false }
            try await backend.recoverInterruptedIndexStage()
        }
        catch { return indexLoadIssue(error) }
        return await inspectRecorded()
    }
    public func repairInterruptedPublication() async -> RecordedAnalysisInventory {
        guard controller == nil, presentations.isEmpty, scanWork == nil, admittedScan == nil, !closingAll,
              !initializing else {
            return .unavailable(.busy)
        }
        let workID = beginOwnership(.initialize)
        defer { endOwnership(workID) }
        do {
            initializing = true
            defer { initializing = false }
            _ = try await backend.recoverInterruptedPublication()
        }
        catch { return indexLoadIssue(error) }
        return await inspectRecorded()
    }

    /// User-invoked repair after the App has drained scans and query views.
    /// Only the existing, exact publication-intent or stage-only recovery may
    /// mutate state. Unknown inventory remains visible as needsAttention.
    public func repairSavedAnalyses() async -> RecordedAnalysisInventory {
        guard presentations.isEmpty, liveTransients.isEmpty,
              pendingPublication == nil, scanWork == nil, admittedScan == nil,
              !startingAdmittedScan, openingCatalogs.isEmpty, closingCatalogs.isEmpty,
              ownershipWork.isEmpty, !closingAll, !initializing,
              resumingQuitGeneration == nil, pendingRevocation == nil,
              !pendingResumeAfterForget, !finishingRevocation else { return .unavailable(.busy) }
        if let controller {
            let state = await controller.snapshot()
            guard !closingAll, !initializing, presentations.isEmpty,
                  liveTransients.isEmpty, pendingPublication == nil,
                  scanWork == nil, admittedScan == nil, !startingAdmittedScan,
                  openingCatalogs.isEmpty, closingCatalogs.isEmpty,
                  ownershipWork.isEmpty, resumingQuitGeneration == nil,
                  pendingRevocation == nil, !pendingResumeAfterForget,
                  !finishingRevocation else { return .unavailable(.busy) }
            guard state.indexKnown else { return .needsAttention(.indexRequiresAttention) }
            guard state.admissionsOpen, !state.hasWork, state.reads == 0,
                  state.pins == 0 else { return .unavailable(.busy) }
            return await inspectRecorded()
        }
        let workID = beginOwnership(.initialize)
        initializing = true
        defer { initializing = false; endOwnership(workID) }
        do {
            do { _ = try await backend.loadCanonicalIndex() }
            catch let failure as StorageScanFailure where failure == .changed {
                do { _ = try await backend.recoverInterruptedPublication() }
                catch let repairFailure as StorageScanFailure where repairFailure == .changed {
                    try await backend.recoverInterruptedIndexStage()
                }
            }
            let current = try await backend.loadCanonicalIndex()
            controller = RetainedAnalysisController(initial: current, backend: backend)
        } catch { return indexLoadIssue(error) }
        return await inspectRecorded()
    }

    /// Reserves one publication ticket before launching the ordinary paged
    /// scanner. The caller owns the sole progress-stream consumer; this actor
    /// does not start a parallel scan or synthesize a result from a saved path.
    public func beginRecordedSingleScan(root: URL, retainingAccess: any Sendable,
                                        metadataPolicy: AnalysisMetadataPolicy = .standard,
                                        replacing: UUID? = nil, updatingChanges: Bool = false) async -> RecordedScanStart {
        guard !closingAll, scanWork == nil, admittedScan == nil, !startingAdmittedScan,
              pendingPublication == nil else { return .unavailable(.busy) }
        startingAdmittedScan = true
        defer { startingAdmittedScan = false }
        let workID = beginOwnership(.scan)
        var transferred = false
        defer { if !transferred { endOwnership(workID) } }
        switch await prepareForExplicitScan() {
        case .ready: break
        case .unavailable(let issue): return .unavailable(issue)
        case .needsAttention(let issue): return .needsAttention(issue)
        }
        var baselineView: RecordedAnalysisPresentation?
        var baseline: StorageAnalysisResult?
        if updatingChanges, metadataPolicy == .standard, let replacing,
           case .ready(let value) = await openRecorded(replacing) {
            baselineView = value
            if value.metadata.status == .complete,
               value.metadata.recordedSingleRoot?.standardizedFileURL == root.standardizedFileURL {
                baseline = presentations[replacing]?.result
            }
        }
        guard !closingAll, scanWork == nil, admittedScan == nil, let controller,
              let ticket = await controller.publicationTicket() else {
            await releaseIncrementalView(baselineView)
            return .unavailable(.busy)
        }
        guard !closingAll else {
            await controller.abandonPublicationTicket(ticket)
            await releaseIncrementalView(baselineView)
            return .unavailable(.cancelled)
        }
        do {
            let session = try scanner.startPagedRetainedCandidate(root: root, storage: storage,
                metadataPolicy: metadataPolicy, retainingAccess: retainingAccess,
                refreshBaseline: baseline, updatingChanges: updatingChanges)
            let token = UUID()
            admittedScan = .init(token: token, workID: workID, session: session,
                ticket: ticket, controller: controller, retainingAccess: retainingAccess,
                replacing: replacing, baselineView: baselineView)
            transferred = true
            return .started(.init(session: session, token: token))
        } catch {
            await controller.abandonPublicationTicket(ticket)
            await releaseIncrementalView(baselineView)
            return .unavailable(issue(error))
        }
    }

    /// Return the exact terminal update consumed from admission.session. A
    /// workerDrained update precedes the queue's final defer, so candidate
    /// extraction additionally waits for ScannerProcessControl.finished.
    public func adoptDrainedResult(admission: RecordedScanAdmission,
                                   terminal: PagedStorageScanUpdate) async -> RecordedScanAdoption {
        guard var scan = admittedScan, scan.token == admission.token,
              scan.session === admission.session else {
            if let retained = completedAdmittedScans[admission.token] {
                return retained ? .accepted(.needsAttention(.retentionPending)) : .notAdopted(.changed)
            }
            return .unresolved(.changed)
        }
        guard case .scanning = scan.state else { return .unresolved(.busy) }
        scan.state = .adopting; admittedScan = scan
        var ownerRetainsResult = false
        defer { finishAdmittedScan(scan.token, workID: scan.workID, ownerRetainsResult: ownerRetainsResult) }
        let candidate = await scan.session.drainedRetainedCandidate()
        await releaseIncrementalView(scan.baselineView)
        guard !closingAll, !Task.isCancelled,
              admittedScan?.token == scan.token,
              admittedScan?.abandonRequested == false else {
            await scan.controller.abandonPublicationTicket(scan.ticket)
            return .notAdopted(.cancelled)
        }
        guard terminal.session == scan.session.id, terminal.workerDrained,
              terminal.result?.id == scan.session.id,
              !terminal.isStartupPair else {
            await scan.controller.abandonPublicationTicket(scan.ticket)
            return .notAdopted(.changed)
        }
        guard let candidate else {
            await scan.controller.abandonPublicationTicket(scan.ticket)
            if let result = terminal.result, terminal.status == .completed || terminal.status == .partial {
                let pending = PendingPublication(result: result, retainingAccess: scan.retainingAccess,
                    terminal: .init(terminal), status: nil)
                pendingPublication = pending
                ownerRetainsResult = true
                return .accepted(issueTransient(pending))
            }
            if case .failed(let failure) = terminal.status { return .notAdopted(.scan(failure)) }
            return .notAdopted(.retentionPending)
        }
        guard terminalMatchesCapture(terminal, capture: candidate.capture) else {
            await scan.controller.abandonPublicationTicket(scan.ticket)
            return .notAdopted(.changed)
        }
        #if DEBUG
        if let hook = beforeAdmittedPublicationForQualification { await hook() }
        #endif
        guard !closingAll, admittedScan?.abandonRequested == false else {
            await scan.controller.abandonPublicationTicket(scan.ticket)
            return .notAdopted(.cancelled)
        }
        let publicationWorkID = beginOwnership(.publication)
        defer { endOwnership(publicationWorkID) }
        let outcome = await finishPublication(candidate, terminal: .init(terminal),
            retainingAccess: scan.retainingAccess, replacing: scan.replacing,
            ticket: scan.ticket, controller: scan.controller)
        ownerRetainsResult = true
        return .accepted(outcome)
    }

    /// Cancellation joins the scanner's actual worker and abandons only this
    /// admission's ticket. A concurrent adoption is joined; its receipt tells
    /// the App which owner must eventually close the exact raw result.
    public func abandonRecordedScan(admission: RecordedScanAdmission) async -> RecordedScanAbandonment {
        guard var scan = admittedScan, scan.token == admission.token,
              scan.session === admission.session else {
            guard let retained = completedAdmittedScans[admission.token] else { return .unresolved }
            return retained ? .ownerRetainsResult : .abandoned
        }
        let ownsAbandonment: Bool
        switch scan.state {
        case .scanning: scan.state = .abandoning; ownsAbandonment = true
        case .adopting, .abandoning: ownsAbandonment = false
        }
        scan.abandonRequested = true; admittedScan = scan
        #if DEBUG
        if let hook = afterAdmittedAbandonRequestForQualification { await hook() }
        #endif
        scan.session.cancel()
        await scan.session.waitUntilDrained()
        if !ownsAbandonment {
            guard let retained = await waitForAdmittedScanCompletion(scan.token) else { return .unresolved }
            return retained ? .ownerRetainsResult : .abandoned
        }
        guard admittedScan?.token == scan.token else {
            guard let retained = completedAdmittedScans[scan.token] else { return .unresolved }
            return retained ? .ownerRetainsResult : .abandoned
        }
        await scan.controller.abandonPublicationTicket(scan.ticket)
        await releaseIncrementalView(scan.baselineView)
        finishAdmittedScan(scan.token, workID: scan.workID, ownerRetainsResult: false)
        return .abandoned
    }

    private func finishAdmittedScan(_ token: UUID, workID: UUID, ownerRetainsResult: Bool) {
        guard admittedScan?.token == token else { return }
        admittedScan = nil; endOwnership(workID)
        completedAdmittedScans[token] = ownerRetainsResult
        completedAdmissionOrder.append(token)
        if completedAdmissionOrder.count > 8 {
            completedAdmittedScans.removeValue(forKey: completedAdmissionOrder.removeFirst())
        }
        let waiters = admittedScanWaiters.removeValue(forKey: token) ?? []
        waiters.forEach { $0.resume(returning: ownerRetainsResult) }
    }

    private func releaseIncrementalView(_ presentation: RecordedAnalysisPresentation?) async {
        guard let presentation else { return }
        presentation.queries.revokeAdmissions()
        await presentation.queries.joinInFlight()
        let catalog = presentation.metadata.catalogID
        if var current = presentations[catalog], current.views[presentation.consumerID] === presentation.queries {
            current.views.removeValue(forKey: presentation.consumerID)
            presentations[catalog] = current
        }
    }

    private func waitForAdmittedScanCompletion(_ token: UUID) async -> Bool? {
        if let completed = completedAdmittedScans[token] { return completed }
        guard admittedScan?.token == token else { return nil }
        return await withCheckedContinuation { continuation in
            admittedScanWaiters[token, default: []].append(continuation)
        }
    }

    private func terminalMatchesCapture(_ terminal: PagedStorageScanUpdate,
                                        capture: RetainedScanCapture) -> Bool {
        guard terminal.result === capture.result,
              terminal.committedEntries == capture.committedEntries,
              terminal.status == (capture.complete ? .completed : .partial),
              !capture.scope.isStartup,
              let notices = terminal.coverage.workerNotices,
              let coverage = try? RetainedAnalysisRecord.Coverage(
                reasonCounts: AnalysisScanCoverageReason.allCases.map { terminal.coverage[$0] },
                reportedNotices: terminal.coverage.reportedNotices, workerNotices: notices,
                uncategorizedNotices: terminal.coverage.uncategorizedNotices,
                reasonCountsAreComplete: terminal.coverage.reasonCountsAreComplete,
                terminalReason: terminal.coverage.terminalReason) else { return false }
        return coverage == capture.coverage
    }

    private func cancelAdmittedScanForRevocation() async {
        guard var scan = admittedScan else { return }
        let ownsAbandonment: Bool
        switch scan.state {
        case .scanning: scan.state = .abandoning; ownsAbandonment = true
        case .adopting, .abandoning: ownsAbandonment = false
        }
        scan.abandonRequested = true; admittedScan = scan
        scan.session.cancel()
        await scan.session.waitUntilDrained()
        guard ownsAbandonment, admittedScan?.token == scan.token else { return }
        await scan.controller.abandonPublicationTicket(scan.ticket)
        await releaseIncrementalView(scan.baselineView)
        finishAdmittedScan(scan.token, workID: scan.workID, ownerRetainsResult: false)
    }

    #if DEBUG
    public func scanSingle(root: URL, retainingAccess: any Sendable,
                           metadataPolicy: AnalysisMetadataPolicy = .standard,
                           replacing: UUID? = nil,
                           onProgress: (@Sendable (RecordedAnalysisProgress) -> Void)? = nil) async -> RecordedAnalysisOutcome {
        await run(.single(root, metadataPolicy, retainingAccess), replacing: replacing, onProgress: onProgress)
    }
    public func scanStartup(plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
                            retainingAccess: any Sendable,
                            metadataPolicy: AnalysisMetadataPolicy = .standard,
                            replacing: UUID? = nil,
                            onProgress: (@Sendable (RecordedAnalysisProgress) -> Void)? = nil) async -> RecordedAnalysisOutcome {
        await run(.startup(plan, discovery, metadataPolicy, retainingAccess), replacing: replacing,
                  onProgress: onProgress)
    }

    private func run(_ request: ScanRequest, replacing: UUID?,
                     onProgress: (@Sendable (RecordedAnalysisProgress) -> Void)?) async -> RecordedAnalysisOutcome {
        guard !closingAll, scanWork == nil, admittedScan == nil,
              !startingAdmittedScan, pendingPublication == nil else { return .unavailable(.busy) }
        let workID = beginOwnership(.scan)
        defer { endOwnership(workID) }
        switch await prepareForExplicitScan() {
        case .ready(_): break
        case .unavailable(let issue): return .unavailable(issue)
        case .needsAttention(let issue): return .needsAttention(issue)
        }
        guard !closingAll, scanWork == nil, let controller,
              let ticket = await controller.publicationTicket() else {
            return .unavailable(.busy)
        }
        let id = UUID()
        let task = Task { await self.performScan(request, replacing: replacing,
            onProgress: onProgress, ticket: ticket, workID: id, controller: controller) }
        scanWork = .init(id: id, task: task)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performScan(_ request: ScanRequest, replacing: UUID?,
                             onProgress: (@Sendable (RecordedAnalysisProgress) -> Void)?,
                             ticket: RetainedPublicationTicket, workID: UUID,
                             controller: RetainedAnalysisController) async -> RecordedAnalysisOutcome {
        let publicationWorkID = beginOwnership(.publication)
        defer { endOwnership(publicationWorkID) }
        defer { if scanWork?.id == workID { scanWork = nil } }
        guard !Task.isCancelled, !closingAll else {
            await controller.abandonPublicationTicket(ticket)
            return .unavailable(.cancelled)
        }
        let session: PagedStorageScanSession
        do {
            switch request {
            case .single(let root, let policy, let access):
                session = try scanner.startPagedRetainedCandidate(root: root, storage: storage,
                    metadataPolicy: policy, retainingAccess: access)
            case .startup(let plan, let discovery, let policy, let access):
                session = try scanner.startStartupRetainedCandidate(plan: plan, discovery: discovery,
                    storage: storage, metadataPolicy: policy, retainingAccess: access)
            }
        } catch {
            await controller.abandonPublicationTicket(ticket)
            return .unavailable(issue(error))
        }
        let terminal = await withTaskCancellationHandler {
            var latestTerminal: PagedStorageScanUpdate?
            for await update in session.updates {
                onProgress?(RecordedAnalysisProgress(update))
                if update.workerDrained { latestTerminal = update }
            }
            await session.waitUntilDrained()
            return latestTerminal
        } onCancel: { session.cancel() }
        guard !Task.isCancelled, let candidate = await session.drainedRetainedCandidate() else {
            await controller.abandonPublicationTicket(ticket)
            if let result = terminal?.result { await result.closeAfterRevokingApplicationConsumersAndDrain() }
            if Task.isCancelled { return .unavailable(.cancelled) }
            if case .some(.failed(let failure)) = terminal?.status { return .unavailable(.scan(failure)) }
            return .needsAttention(.retentionPending)
        }
        return await finishPublication(candidate, terminal: terminal.map(RecordedAnalysisProgress.init),
            retainingAccess: request.retainingAccess, replacing: replacing,
            ticket: ticket, controller: controller)
    }
    #endif

    private func finishPublication(_ candidate: RetainedDrainedCandidate,
                                   terminal: RecordedAnalysisProgress?,
                                   retainingAccess: any Sendable, replacing: UUID?,
                                   ticket: RetainedPublicationTicket,
                                   controller: RetainedAnalysisController) async -> RecordedAnalysisOutcome {
        let result = candidate.capture.result
        let outcome = await controller.publish(candidate, replacing: replacing, ticket: ticket)
        switch outcome {
        case .publication(.committed(let epoch), let allowed, let pinPending):
            guard allowed, !pinPending, !closingAll, !Task.isCancelled else {
                pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                    terminal: terminal, status: .committed(epoch: epoch))
                return .needsAttention(.retentionPending)
            }
            let opened = await openRecorded(candidate.capture.result.id)
            if case .ready = opened { return opened }
            pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: .committed(epoch: epoch))
            if case .unavailable(.busy) = opened { return .needsAttention(.retentionPending) }
            return opened
        case .publication(.notCommitted, _, let pinPending):
            pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: .notCommitted)
            if pinPending { return .needsAttention(.retentionPending) }
            return await reconcilePendingPublication()
        case .publication(.indeterminate, _, _), .indexIndeterminate:
            pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: .indeterminate)
            return .needsAttention(.indexRequiresAttention)
        case .backendRefused(let refusal):
            let pending = PendingPublication(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: nil)
            pendingPublication = pending
            // runPublication returns backendRefused only when pin acquisition
            // fails before index preparation. The completed scan remains an
            // ordinary transient if no native pin was issued.
            if terminal != nil, (await controller.snapshot()).pins == 0 {
                return issueTransient(pending)
            }
            _ = refusal
            return .needsAttention(.retentionPending)
        case .refused(let reason):
            let pending = PendingPublication(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: nil)
            pendingPublication = pending
            if (await controller.snapshot()).pins == 0 {
                if terminal != nil { return issueTransient(pending) }
            }
            return .needsAttention(issue(reason))
        case .pending(_):
            pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: nil)
            return .needsAttention(.retentionPending)
        default:
            pendingPublication = .init(result: result, retainingAccess: retainingAccess,
                terminal: terminal, status: nil)
            return .needsAttention(.indexRequiresAttention)
        }
    }

    private func catalogAbsent(_ id: UUID, from index: RetainedAnalysisIndex) -> Bool {
        !index.visibleRecords.contains { $0.catalogID == id } &&
        index.retiring?.catalog.catalogID != id &&
        !index.pendingForget.contains { $0.catalog.catalogID == id }
    }
    private func issueTransient(_ pending: PendingPublication) -> RecordedAnalysisOutcome {
        guard !closingAll, !Task.isCancelled, let terminal = pending.terminal,
              liveTransients[pending.result.id] == nil else { return .needsAttention(.retentionPending) }
        let consumerID = UUID()
        let queries = RecordedAnalysisQueries(pending.result,
            retainingAccess: pending.retainingAccess, viewID: consumerID)
        liveTransients[pending.result.id] = .init(result: pending.result, terminal: terminal,
            views: [consumerID: queries])
        pendingPublication = nil
        return .liveTransient(.init(catalogID: pending.result.id,
            consumerID: consumerID, queries: queries, terminal: terminal))
    }
    private func reconcilePendingPublication() async -> RecordedAnalysisOutcome {
        guard let pendingPublication, let controller else { return .needsAttention(.retentionPending) }
        guard let index = await controller.recordedIndex() else {
            return .needsAttention(.indexRequiresAttention)
        }
        let snapshot = await controller.snapshot()
        guard !closingAll, !Task.isCancelled,
              self.pendingPublication?.result === pendingPublication.result,
              snapshot.indexKnown, snapshot.pins == 0, !snapshot.hasWork,
              snapshot.epoch == index.epoch else {
            return .needsAttention(.retentionPending)
        }
        switch pendingPublication.status {
        case .some(.notCommitted):
            guard catalogAbsent(pendingPublication.result.id, from: index) else {
                return .needsAttention(.indexRequiresAttention)
            }
            return issueTransient(pendingPublication)
        case .some(.committed):
            guard index.visibleRecords.contains(where: { $0.catalogID == pendingPublication.result.id }) else {
                return .needsAttention(.indexRequiresAttention)
            }
            return await openRecorded(pendingPublication.result.id)
        case .some(.indeterminate), .none:
            return .needsAttention(.indexRequiresAttention)
        }
    }
    /// Retry only a previously owned publication pin. An uncertain result is
    /// never promoted to a query view from a missing or ambiguous receipt.
    public func retryPendingPublicationPin() async -> RecordedAnalysisOutcome {
        guard !closingAll, scanWork == nil, admittedScan == nil, pendingPublication != nil,
              let controller else { return .unavailable(.busy) }
        let workID = beginOwnership(.publication)
        defer { endOwnership(workID) }
        switch await controller.retryPublicationPin() {
        case .pinResolved(let pin, let disposition):
            guard pin.catalogID == pendingPublication?.result.id else {
                return .needsAttention(.indexRequiresAttention)
            }
            if case .preserveUncertain = disposition {
                return .needsAttention(.indexRequiresAttention)
            }
            return await reconcilePendingPublication()
        case .refused(.invalid):
            return await reconcilePendingPublication()
        case .pending(_): return .needsAttention(.retentionPending)
        case .indexIndeterminate: return .needsAttention(.indexRequiresAttention)
        case .refused(.busy): return .unavailable(.busy)
        default: return .needsAttention(.retentionPending)
        }
    }

    private func issuePresentation(_ catalogID: UUID,
                                   retainingAccess: any Sendable) -> RecordedAnalysisPresentation? {
        guard var owned = presentations[catalogID], !closingAll,
              !closingCatalogs.contains(catalogID) else { return nil }
        let consumerID = UUID()
        let queries = RecordedAnalysisQueries(owned.result, retainingAccess: retainingAccess,
            viewID: consumerID)
        owned.views[consumerID] = queries
        presentations[catalogID] = owned
        return .init(metadata: owned.metadata, queries: queries, consumerID: consumerID)
    }

    /// Cached and cold opens both validate fresh root grant, helper, catalog
    /// and current index. Each call issues an independently revocable query view.
    public func openRecorded(_ catalogID: UUID) async -> RecordedAnalysisOutcome {
        guard !closingAll, !closingCatalogs.contains(catalogID),
              openingCatalogs.insert(catalogID).inserted else { return .unavailable(.busy) }
        let workID = beginOwnership(.open)
        defer { endOwnership(workID) }
        defer { openingCatalogs.remove(catalogID) }
        if let existing = presentations[catalogID] {
            guard let controller, let index = await controller.recordedIndex(),
                  let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }) else {
                return .needsAttention(.indexRequiresAttention)
            }
            let before = await controller.snapshot()
            guard before.admissionsOpen, !before.hasWork, !closingAll else {
                return .needsAttention(.retentionPending)
            }
            switch await backend.validateCurrentPresentation(record,
                         expectedEpoch: index.epoch, result: existing.result) {
            case .refused(let reason): return .unavailable(issue(reason))
            case .valid(let grant):
                guard let current = await controller.recordedIndex() else {
                    return .needsAttention(.indexRequiresAttention)
                }
                let after = await controller.snapshot()
                guard !Task.isCancelled, !closingAll,
                      current.epoch == index.epoch,
                      current.visibleRecords.contains(record),
                      after.admissionsOpen, !after.hasWork,
                      let value = issuePresentation(catalogID, retainingAccess: grant) else {
                    return .needsAttention(.retentionPending)
                }
                return .ready(value)
            }
        }
        if controller == nil {
            guard !initializing else { return .unavailable(.busy) }
            initializing = true
            defer { initializing = false }
            do {
                let current = try await backend.loadCanonicalIndex()
                controller = RetainedAnalysisController(initial: current, backend: backend)
            } catch { return outcome(indexLoadIssue(error)) }
        }
        guard let controller else { return .needsAttention(.indexRequiresAttention) }
        switch await controller.openPrevious(catalogID) {
        case .opened(let handle):
            guard !closingAll, !closingCatalogs.contains(catalogID),
                  let index = await controller.recordedIndex(),
                  let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }),
                  let result = await backend.result(for: handle),
                  result.id == catalogID,
                  let metadata = try? RecordedAnalysisMetadata(record) else {
                _ = await controller.closeRead(catalogID, consumers: RecordedNoConsumers())
                return .needsAttention(.indexRequiresAttention)
            }
            switch await backend.validateCurrentPresentation(record,
                         expectedEpoch: index.epoch, result: result) {
            case .refused(let reason):
                _ = await controller.closeRead(catalogID, consumers: RecordedNoConsumers())
                return .unavailable(issue(reason))
            case .valid(let grant):
                guard let current = await controller.recordedIndex() else {
                    _ = await controller.closeRead(catalogID, consumers: RecordedNoConsumers())
                    return .needsAttention(.indexRequiresAttention)
                }
                let after = await controller.snapshot()
                guard !Task.isCancelled, !closingAll, !closingCatalogs.contains(catalogID),
                      current.epoch == index.epoch, current.visibleRecords.contains(record),
                      after.admissionsOpen, !after.hasWork else {
                    _ = await controller.closeRead(catalogID, consumers: RecordedNoConsumers())
                    return .needsAttention(.retentionPending)
                }
                presentations[catalogID] = .init(metadata: metadata, result: result)
                guard let value = issuePresentation(catalogID, retainingAccess: grant) else {
                    return .needsAttention(.retentionPending)
                }
                if pendingPublication?.result === result { pendingPublication = nil }
                return .ready(value)
            }
        case .backendRefused(let refusal): return .unavailable(issue(refusal))
        case .refused(.busy): return .unavailable(.busy)
        case .refused(let reason): return .needsAttention(issue(reason))
        case .indexIndeterminate: return .needsAttention(.indexRequiresAttention)
        default: return .needsAttention(.retentionPending)
        }
    }

    /// Releases one consumer view; the catalog's native owner remains shared.
    public func releaseConsumer(catalogID: UUID, consumerID: UUID,
                                consumers: any RecordedAnalysisViewConsumerDrain) async -> RecordedAnalysisCoordination {
        guard !closingAll, !closingCatalogs.contains(catalogID) else { return .unavailable(.busy) }
        let workID = beginOwnership(.close)
        defer { endOwnership(workID) }
        if let view = presentations[catalogID]?.views[consumerID] {
            view.revokeAdmissions()
            do { try await consumers.revokeAndJoin(consumerID: consumerID) }
            catch { return .needsAttention(.consumerDrainPending) }
            await view.joinInFlight()
            #if DEBUG
            if let hook = afterConsumerRevokeForQualification { await hook() }
            #endif
            if !closingAll, var current = presentations[catalogID],
               current.views[consumerID] === view {
                current.views.removeValue(forKey: consumerID)
                presentations[catalogID] = current
            }
            return .complete
        }
        if let view = liveTransients[catalogID]?.views[consumerID] {
            view.revokeAdmissions()
            do { try await consumers.revokeAndJoin(consumerID: consumerID) }
            catch { return .needsAttention(.consumerDrainPending) }
            await view.joinInFlight()
            #if DEBUG
            if let hook = afterConsumerRevokeForQualification { await hook() }
            #endif
            if !closingAll, var current = liveTransients[catalogID],
               current.views[consumerID] === view {
                current.views.removeValue(forKey: consumerID)
                liveTransients[catalogID] = current
            }
            return .complete
        }
        return .unavailable(.changed)
    }

    /// Catalog-scoped idle closure. The controller reserves the close before
    /// asking App consumers to revoke, so Busy leaves the owned views intact.
    /// Pending keeps the owner and its already-revoked views for explicit retry.
    public func closeCatalog(_ catalogID: UUID,
                             consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        await closeCatalog(catalogID, consumers: consumers, requiringNoViews: false)
    }

    /// Releases a borrowed catalog only when no presentation still owns a view.
    /// The no-view check shares the actual close reservation, so a concurrent
    /// open cannot be revoked between a separate observation and the close.
    public func closeIdleCatalog(_ catalogID: UUID,
                                 consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        await closeCatalog(catalogID, consumers: consumers, requiringNoViews: true)
    }

    private func closeCatalog(_ catalogID: UUID, consumers: any RecordedAnalysisConsumerDrain,
                              requiringNoViews: Bool) async -> RecordedAnalysisCoordination {
        guard !closingAll, scanWork == nil, admittedScan == nil, !openingCatalogs.contains(catalogID),
              closingCatalogs.insert(catalogID).inserted else { return .unavailable(.busy) }
        let workID = beginOwnership(.close)
        defer { endOwnership(workID) }
        defer { closingCatalogs.remove(catalogID) }
        let views = presentations[catalogID].map { Array($0.views.values) } ?? []
        guard !requiringNoViews || (pendingPublication?.result.id != catalogID
            && views.isEmpty && liveTransients[catalogID]?.views.isEmpty != false) else {
            return .unavailable(.busy)
        }
        let drain: any RetainedApplicationConsumerDrain = requiringNoViews ? RecordedNoConsumers()
            : RecordedOneDrain(catalogID: catalogID, consumers: consumers, views: views)
        if let transient = liveTransients[catalogID] {
            let transientDrain: any RetainedApplicationConsumerDrain = requiringNoViews ? RecordedNoConsumers()
                : RecordedOneDrain(catalogID: catalogID, consumers: consumers, views: Array(transient.views.values))
            do { try await transientDrain.revokeAndJoin() }
            catch { return .needsAttention(.consumerDrainPending) }
            await transient.result.closeAfterRevokingApplicationConsumersAndDrain()
            liveTransients.removeValue(forKey: catalogID)
            return .complete
        }
        guard let controller else { return .needsAttention(.indexRequiresAttention) }
        let result: RetainedControllerOutcome
        if await controller.hasRead(catalogID) {
            result = await controller.closeRead(catalogID, consumers: drain)
        } else {
            result = await controller.closeIdleWarm(catalogID, consumers: drain)
        }
        switch result {
        case .readClosed:
            presentations.removeValue(forKey: catalogID)
            return .complete
        case .pending(_): return .needsAttention(.consumerDrainPending)
        case .indexIndeterminate: return .needsAttention(.indexRequiresAttention)
        case .refused(.busy): return .unavailable(.busy)
        default: return .needsAttention(.consumerDrainPending)
        }
    }

    public func reconcileRetiring(consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        let workID = beginOwnership(.close)
        defer { endOwnership(workID) }
        guard !closingAll, let controller,
              let index = await controller.recordedIndex(),
              let old = index.retiring?.catalog.catalogID else {
            return .unavailable(.busy)
        }
        let views = presentations[old].map { Array($0.views.values) } ?? []
        switch await controller.reconcileRetiring(consumers: RecordedRetiredDrain(
            consumers: consumers, views: [old: views])) {
        case .coordinationComplete:
            presentations.removeValue(forKey: old)
            return .complete
        case .indexIndeterminate: return .needsAttention(.indexRequiresAttention)
        case .pending(_): return .needsAttention(.retentionPending)
        default: return .unavailable(.busy)
        }
    }

    public func quitRetaining(consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        await revoke(.retainOnClose, consumers: consumers)
    }
    private func ownsResumingQuit(_ generation: UUID) -> Bool {
        closingAll && closingIntent?.isForget == false &&
        pendingRevocation == nil && !pendingResumeAfterForget &&
        completedRetainingQuit?.generation == generation &&
        resumingQuitGeneration == generation
    }
    /// Only a receipt from this owner's completed retaining Quit may reopen
    /// admissions after the host App has aborted its actual termination.
    public func resumeAfterAbortedQuit(_ receipt: RecordedRetainingQuitReceipt) async -> RecordedAnalysisCoordination {
        guard closingAll, closingIntent?.isForget == false,
              pendingRevocation == nil, !pendingResumeAfterForget,
              completedRetainingQuit?.generation == receipt.generation,
              let controller else { return .unavailable(.changed) }
        // Claim before the first suspension. A second caller cannot consume
        // this receipt, and a late caller cannot clear a later Quit fence.
        guard resumingQuitGeneration == nil else { return .unavailable(.busy) }
        resumingQuitGeneration = receipt.generation
        defer {
            if resumingQuitGeneration == receipt.generation { resumingQuitGeneration = nil }
        }
        await joinOwnershipWork()
        guard ownsResumingQuit(receipt.generation) else { return .unavailable(.changed) }
        let state = await controller.snapshot()
        guard ownsResumingQuit(receipt.generation) else { return .unavailable(.changed) }
        guard state.indexKnown, !state.hasWork,
              state.reads == 0, state.pins == 0,
              presentations.isEmpty, liveTransients.isEmpty,
              pendingPublication == nil else { return .needsAttention(.retentionPending) }
        #if DEBUG
        if let hook = beforeResumeAdmissionsForQualification { await hook() }
        #endif
        guard ownsResumingQuit(receipt.generation) else { return .unavailable(.changed) }
        guard await controller.resumeAdmissions() else { return .needsAttention(.retentionPending) }
        guard ownsResumingQuit(receipt.generation) else { return .unavailable(.changed) }
        closingAll = false; closingIntent = nil; completedRetainingQuit = nil
        return .complete
    }
    public func forgetAll(consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        if controller == nil {
            switch await inspectRecorded() {
            case .ready(_), .needsAttention(.retentionPending): break
            case .unavailable(let issue): return .unavailable(issue)
            case .needsAttention(let issue): return .needsAttention(issue)
            }
        }
        return await revoke(.forgetAll, consumers: consumers)
    }
    private func revoke(_ intent: RetainedRevocationIntent,
                        consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        if closingAll {
            if pendingResumeAfterForget, intent.isForget, let controller {
                guard await controller.resumeAdmissions() else { return .needsAttention(.retentionPending) }
                pendingResumeAfterForget = false; closingAll = false; closingIntent = nil
                return .complete
            }
            if !intent.isForget, resumingQuitGeneration != nil {
                return .unavailable(.busy)
            }
            if !intent.isForget, let receipt = completedRetainingQuit {
                return .retainingQuit(receipt)
            }
            if pendingRevocation == nil, let controller,
               closingIntent?.isForget == intent.isForget,
               let ticket = await controller.beginRevocation(intent) {
                pendingRevocation = (ticket, intent)
                if let work = scanWork { work.task.cancel(); _ = await work.task.value }
                await cancelAdmittedScanForRevocation()
                await joinOwnershipWork()
                return await finishRevocation(ticket, intent: intent,
                    controller: controller, consumers: consumers)
            }
            guard let pendingRevocation,
                  (pendingRevocation.intent.isForget == intent.isForget),
                  let controller else { return .unavailable(.busy) }
            return await finishRevocation(pendingRevocation.ticket, intent: intent,
                controller: controller, consumers: consumers)
        }
        closingAll = true; closingIntent = intent; completedRetainingQuit = nil
        if controller == nil { await joinOwnershipWork() }
        guard let controller else {
            if case .retainOnClose = intent {
                closingAll = false; closingIntent = nil
                return .complete
            }
            return .needsAttention(.indexRequiresAttention)
        }
        guard let ticket = await controller.beginRevocation(intent) else {
            return .needsAttention(.retentionPending)
        }
        pendingRevocation = (ticket, intent)
        if let work = scanWork {
            work.task.cancel()
            _ = await work.task.value
        }
        await cancelAdmittedScanForRevocation()
        await joinOwnershipWork()
        return await finishRevocation(ticket, intent: intent, controller: controller,
            consumers: consumers)
    }
    private func finishRevocation(_ ticket: RetainedRevocationTicket,
                                  intent: RetainedRevocationIntent,
                                  controller: RetainedAnalysisController,
                                  consumers: any RecordedAnalysisConsumerDrain) async -> RecordedAnalysisCoordination {
        guard !finishingRevocation else { return .unavailable(.busy) }
        finishingRevocation = true
        defer { finishingRevocation = false }
        await joinOwnershipWork()
        let views = presentations.values.flatMap { Array($0.views.values) }
            + liveTransients.values.flatMap { Array($0.views.values) }
        let outcome = await controller.completeRevocation(ticket,
            consumers: RecordedAllDrain(consumers: consumers, views: views))
        switch outcome {
        case .coordinationComplete:
            // Controller has closed every retained warm/cold owner. Ordinary
            // transient results are separate and must be closed after their
            // actual App consumers joined above.
            for (id, transient) in Array(liveTransients) {
                await transient.result.closeAfterRevokingApplicationConsumersAndDrain()
                liveTransients.removeValue(forKey: id)
            }
            if let pendingPublication {
                guard let index = await controller.recordedIndex(),
                      (await controller.snapshot()).pins == 0 else {
                    return .needsAttention(.indexRequiresAttention)
                }
                switch pendingPublication.status {
                case .some(.committed):
                    guard (intent.isForget && catalogAbsent(pendingPublication.result.id, from: index)) ||
                            index.visibleRecords.contains(where: { $0.catalogID == pendingPublication.result.id }) else {
                        return .needsAttention(.indexRequiresAttention)
                    }
                case .some(.notCommitted), .none:
                    guard catalogAbsent(pendingPublication.result.id, from: index) else {
                        return .needsAttention(.indexRequiresAttention)
                    }
                    await pendingPublication.result.closeAfterRevokingApplicationConsumersAndDrain()
                case .some(.indeterminate):
                    return .needsAttention(.indexRequiresAttention)
                }
                self.pendingPublication = nil
            }
            let state = await controller.snapshot()
            guard state.indexKnown, !state.hasWork, state.reads == 0,
                  state.pins == 0, ownershipWork.isEmpty else {
                return .needsAttention(.retentionPending)
            }
            presentations.removeAll()
            pendingRevocation = nil
            if case .forgetAll = intent {
                guard await controller.resumeAdmissions() else {
                    pendingResumeAfterForget = true
                    return .needsAttention(.retentionPending)
                }
                closingAll = false; closingIntent = nil
                return .complete
            }
            let receipt = RecordedRetainingQuitReceipt(generation: UUID())
            completedRetainingQuit = receipt
            return .retainingQuit(receipt)
        case .indexIndeterminate: return .needsAttention(.indexRequiresAttention)
        case .pending(_): return .needsAttention(.retentionPending)
        default: return .needsAttention(.consumerDrainPending)
        }
    }

    private func indexLoadIssue(_ error: Error) -> RecordedAnalysisInventory {
        if let failure = error as? StorageScanFailure {
            if failure == .busy { return .unavailable(.busy) }
            if failure == .accessDenied { return .unavailable(.accessDenied) }
        }
        return .needsAttention(.indexRequiresAttention)
    }
    private func outcome(_ inventory: RecordedAnalysisInventory) -> RecordedAnalysisOutcome {
        switch inventory {
        case .ready(_): return .unavailable(.changed)
        case .unavailable(let issue): return .unavailable(issue)
        case .needsAttention(let issue): return .needsAttention(issue)
        }
    }
    private func issue(_ error: Error) -> RecordedAnalysisIssue {
        if error is CancellationError { return .cancelled }
        if let failure = error as? StorageScanFailure {
            switch failure {
            case .busy: return .busy
            case .accessDenied: return .accessDenied
            case .changed: return .changed
            default: return .scan(failure)
            }
        }
        return .unavailable
    }
    private func issue(_ refusal: RetainedBackendRefusal) -> RecordedAnalysisIssue {
        switch refusal {
        case .busy: return .busy
        case .accessDenied: return .accessDenied
        case .changed: return .changed
        case .cancelled: return .cancelled
        case .unavailable, .unsupported: return .unavailable
        }
    }
    private func issue(_ reason: RetainedControllerReason) -> RecordedAnalysisIssue {
        switch reason {
        case .busy: return .busy
        case .cancelled: return .cancelled
        case .stale: return .changed
        case .pendingPin, .pendingReadClose, .pendingCleanup: return .retentionPending
        default: return .indexRequiresAttention
        }
    }
}

private extension RetainedRevocationIntent {
    var isForget: Bool { if case .forgetAll = self { return true }; return false }
}
