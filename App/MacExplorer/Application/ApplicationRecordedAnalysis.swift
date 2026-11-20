import Foundation
import ExplorerCore
@_spi(ApplicationOwnership) import StorageAnalysis

struct RecentAnalysis: Identifiable, Sendable {
    enum Result: Equatable, Sendable { case complete, partial }
    let id: UUID
    let root: URL
    let observedThrough: Date
    let result: Result
    let policy: AnalysisMetadataPolicy
}

enum RecentAnalysisInventory: Sendable {
    case ready([RecentAnalysis])
    case loading, disabled, busy, unavailable, needsAttention
}

/// App composition for dated, metadata-only results. The existing analysis
/// coordinator still owns its one scan, progress stream and foreground demand.
/// This owner retains catalogs and joins their actual presentation consumers.
@MainActor
final class ApplicationRecordedAnalysis {
    struct Prepared: Sendable {
        let presentation: RecordedAnalysisPresentation
        let summary: StoredAnalysisSummary
        let report: AnalysisAttributionReport
        var coverage: AnalysisScanCoverage { presentation.metadata.coverage.scanCoverage }
    }
    private var owner: RecordedAnalysisOwner?
    private var directory: URL?
    private let consumers = RecordedAnalysisPresentationConsumers()
    private lazy var drain = RecordedAnalysisConsumerDrainAdapter(consumers)
    private var quitReceipt: RecordedRetainingQuitReceipt?
    private var consumerClosure: RecordedAnalysisPresentationConsumers.ClosureReceipt?
    private var pendingClose = Set<UUID>()
    private var pendingIdleClose = Set<UUID>()
    private var pendingConsumerRelease: [UUID: Set<UUID>] = [:]
    private(set) var managedResults = Set<UUID>()
    private(set) var current: RecordedAnalysisPresentation?
    private(set) var currentCatalogID: UUID?
    private var currentIsRecorded = false
    var recordedQueries: RecordedAnalysisQueries? { currentIsRecorded ? current?.queries : nil }
    private var currentRevoke: (@MainActor () -> Void)?
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?
    private(set) var forgetCompleted = false
    private(set) var lastOpenIssue: RecordedAnalysisIssue?
    private(set) var maintenanceMessage = ""
    var hasWork: Bool { cleanup != nil || !pendingConsumerRelease.isEmpty }

    func configure(scanner: StorageScanner, storage: AnalysisResultStorage, worker: URL,
                   indexDirectory: URL) throws {
        if let directory {
            guard directory == storage.directory else { throw StorageScanFailure.busy }
            return
        }
        // A sibling sidecar keeps the existing result-pool inventory unchanged.
        // Both locations are app-owned state/cache, not selected user folders.
        let retained = try AnalysisResultStorage(directory: storage.directory,
            sessionByteLimit: storage.sessionByteLimit, poolByteLimit: storage.poolByteLimit,
            preserveAfterClose: storage.preserveAfterClose, retentionStateDirectory: indexDirectory)
        owner = try RecordedAnalysisOwner(scanner: scanner, storage: retained, workerURL: worker,
            activityGate: ApplicationFileActivity.gate, accessProvider: ApplicationRecordedAnalysisAccess())
        directory = storage.directory
    }

    /// Passive inventory contains display hints only; it grants no source access.
    func inspectRecent() async -> RecentAnalysisInventory {
        guard let owner, quitReceipt == nil else { return .unavailable }
        switch await owner.inspectRecorded() {
        case .ready(let records):
            return .ready(records.compactMap { record in
                guard !record.isStartupPair, let root = record.recordedSingleRoot else { return nil }
                let result: RecentAnalysis.Result = switch record.status {
                case .complete: record.coverage.hasGaps ? .partial : .complete
                case .partial: .partial
                }
                return RecentAnalysis(id: record.catalogID, root: root,
                    observedThrough: record.observedThrough,
                    result: result,
                    policy: record.metadataPolicy)
            }.sorted { $0.observedThrough > $1.observedThrough })
        case .unavailable(.busy): return .busy
        case .unavailable: return .unavailable
        case .needsAttention: return .needsAttention
        }
    }

    #if DEBUG
    func recentOwnerStateForVerification() async -> String {
        let snapshot = await owner?.ownershipSnapshot()
        return "quit-\(quitReceipt != nil)-index-\(snapshot?.indexKnown ?? false)-fenced-\(snapshot?.admissionsFenced ?? false)-views-\(snapshot?.queryViews ?? -1)"
    }
    #endif

    func begin(root: URL, retainingAccess: any Sendable,
               policy: AnalysisMetadataPolicy, using access: FolderAccessController,
               updatingChanges: Bool = false) async -> RecordedScanAdmission? {
        guard let owner, quitReceipt == nil else { return nil }
        await drainReleasedCatalogs()
        if case .needsAttention(.retentionPending) = await owner.inspectRecorded() {
            // Explicit Analyze may finish a previously committed replacement.
            // Passive lookup never deletes a retired catalog.
            _ = await owner.reconcileRetiring(consumers: drain)
        }
        var replacing: UUID?
        if case .ready(let records) = await owner.inspectRecorded() {
            replacing = records.last(where: { $0.metadataPolicy == policy
                && $0.recordedSingleRoot?.standardizedFileURL.path.utf8
                    .elementsEqual(root.standardizedFileURL.path.utf8) == true })?.catalogID
            if replacing == nil, records.count >= 2 {
                replacing = records.min(by: { $0.observedThrough < $1.observedThrough })?.catalogID
            }
        }
        let replacement = replacing
        return await ApplicationRecordedAnalysisAccess.withFolder(root, using: access) {
            switch await owner.beginRecordedSingleScan(root: root, retainingAccess: retainingAccess,
                metadataPolicy: policy, replacing: replacement, updatingChanges: updatingChanges) {
            case .started(let admission): return admission
            case .unavailable, .needsAttention: return nil
            }
        }
    }

    #if DEBUG
    func refreshEventsForVerification(root: URL, using access: FolderAccessController) async throws -> [String: String] {
        guard let owner, quitReceipt == nil else { throw StorageScanFailure.unavailable }
        await drainReleasedCatalogs()
        guard case .ready(let records) = await owner.inspectRecorded(),
              let record = records.last(where: { !$0.isStartupPair && $0.metadataPolicy == .standard
                  && $0.recordedSingleRoot?.standardizedFileURL.path.utf8
                    .elementsEqual(root.standardizedFileURL.path.utf8) == true }) else { throw StorageScanFailure.unavailable }
        defer { pendingIdleClose.insert(record.catalogID); scheduleCleanup() }
        return try await ApplicationRecordedAnalysisAccess.withFolder(root, using: access) {
            try await owner.inspectRefreshEventsForQualification(record.catalogID)
        }
    }
    #endif

    /// True transfers the raw result's closing responsibility to the domain
    /// owner, even if its immediate query presentation is unavailable.
    func adopt(_ admission: RecordedScanAdmission, terminal: PagedStorageScanUpdate,
               root: URL, using access: FolderAccessController,
               replacingCurrent: Bool = false,
               revoke: @escaping @MainActor () -> Void,
               join: @escaping @MainActor () async -> Void) async -> (managed: Bool, canPresent: Bool) {
        guard let owner else { return (false, true) }
        let outcome = await ApplicationRecordedAnalysisAccess.withFolder(root, using: access) {
            await owner.adoptDrainedResult(admission: admission, terminal: terminal)
        }
        switch outcome {
        case .notAdopted: return (false, true)
        case .unresolved:
            if let id = terminal.result?.id { managedResults.insert(id) }
            return (true, false)
        case .accepted(let outcome):
            guard let id = terminal.result?.id else { return (true, false) }
            managedResults.insert(id)
            if replacingCurrent {
                guard case .ready = outcome else { pendingClose.insert(id); return (true, false) }
                revokeCurrent()
            }
            let consumerID: UUID, viewID: UUID
            var retainedPresentation: RecordedAnalysisPresentation?
            if case .ready(let presentation) = outcome {
                retainedPresentation = presentation
                consumerID = presentation.consumerID; viewID = presentation.queries.viewID
            } else if case .liveTransient(let presentation) = outcome {
                consumerID = presentation.consumerID; viewID = presentation.queries.viewID
            } else {
                // A pending native publication can still own the live result.
                // This App identity grants no query or filesystem authority.
                consumerID = UUID(); viewID = UUID()
            }
            guard currentCatalogID == nil, consumers.register(catalogID: id,
                consumerID: consumerID, viewID: viewID, revoke: revoke, join: join) else {
                pendingClose.insert(id)
                return (true, false)
            }
            current = retainedPresentation
            currentCatalogID = id; currentIsRecorded = false; currentRevoke = revoke
            _ = await owner.reconcileRetiring(consumers: drain)
            return (true, true)
        }
    }

    func abandon(_ admission: RecordedScanAdmission, result: StorageAnalysisResult? = nil) async {
        guard let owner else { return }
        switch await owner.abandonRecordedScan(admission: admission) {
        case .abandoned: break
        case .ownerRetainsResult, .unresolved:
            if let id = result?.id { managedResults.insert(id) }
        }
    }

    func open(root: URL, policy: AnalysisMetadataPolicy, expectedCatalogID: UUID? = nil,
              using access: FolderAccessController, reportsIssue: Bool = true) async -> Prepared? {
        if reportsIssue { lastOpenIssue = nil }
        guard let owner else {
            if reportsIssue { lastOpenIssue = .unavailable }
            return nil
        }
        guard quitReceipt == nil else {
            if reportsIssue { lastOpenIssue = .busy }
            return nil
        }
        await drainReleasedCatalogs()
        return await ApplicationRecordedAnalysisAccess.withFolder(root, using: access) {
            guard !Task.isCancelled else { return nil }
            let records: [RecordedAnalysisMetadata]
            switch await owner.inspectRecorded() {
            case .ready(let values): records = values
            case .unavailable(let issue), .needsAttention(let issue):
                if reportsIssue { lastOpenIssue = issue }; return nil
            }
            guard let record = records.last(where: {
                      (expectedCatalogID == nil || $0.catalogID == expectedCatalogID)
                          && !$0.isStartupPair && $0.metadataPolicy == policy
                          && $0.recordedSingleRoot?.standardizedFileURL.path.utf8
                              .elementsEqual(root.standardizedFileURL.path.utf8) == true
                  }) else {
                if reportsIssue && expectedCatalogID != nil { lastOpenIssue = .changed }
                return nil
            }
            let presentation: RecordedAnalysisPresentation
            switch await owner.openRecorded(record.catalogID) {
            case .ready(let value): presentation = value
            case .unavailable(let issue), .needsAttention(let issue):
                if reportsIssue { lastOpenIssue = issue }; return nil
            case .liveTransient: if reportsIssue { lastOpenIssue = .unavailable }; return nil
            }
            do {
                try Task.checkCancellation()
                let summary = try await presentation.queries.summary()
                let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
                guard let report = try await presentation.queries.attribution(scopeName: name, summary: summary) else {
                    throw StorageScanFailure.invalidOutput
                }
                try Task.checkCancellation()
                managedResults.insert(record.catalogID)
                return Prepared(presentation: presentation, summary: summary, report: report)
            } catch {
                if reportsIssue { lastOpenIssue = .unavailable }
                _ = await releaseBorrowed(presentation)
                scheduleCleanup()
                return nil
            }
        }
    }

    /// Copies an existing dated observation, then releases its real query
    /// consumer. It never starts a scanner, adopts a presentation or changes the
    /// foreground window's issue state. Access and source identity are checked
    /// by the same retained-result owner used for explicit reopening.
    func datedFolderSummary(root: URL, using access: FolderAccessController) async -> FolderSummaryValue? {
        guard let owner, quitReceipt == nil, root.isFileURL else { return nil }
        await drainReleasedCatalogs()
        guard !Task.isCancelled, case .ready(let records) = await owner.inspectRecorded() else { return nil }
        // At most two saved records exist. Prefer the closest recorded parent,
        // then its newest observation. No locator grants access to that parent.
        let candidates = records.compactMap { record -> (RecordedAnalysisMetadata, URL, [Data])? in
            guard !record.isStartupPair, record.metadataPolicy == .standard,
                  let parent = record.recordedSingleRoot,
                  let components = Self.relativeComponents(root, within: parent) else { return nil }
            return (record, parent, components)
        }.sorted { left, right in
            let a = left.1.standardizedFileURL.path.utf8.count, b = right.1.standardizedFileURL.path.utf8.count
            return a == b ? left.0.observedThrough > right.0.observedThrough : a > b
        }
        guard let (record, parent, components) = candidates.first else { return nil }
        return await ApplicationRecordedAnalysisAccess.withFolder(parent, using: access) {
            guard !Task.isCancelled else { return nil }
            let presentation: RecordedAnalysisPresentation
            switch await owner.openRecorded(record.catalogID) {
            case .ready(let value): presentation = value
            default: return nil
            }
            var observation: FolderSummaryValue?
            do {
                try Task.checkCancellation()
                let summary = try await presentation.queries.summary()
                let value: StoredAnalysisValue?
                if components.isEmpty { value = summary.value }
                else { value = try await presentation.queries.folderValue(relativeComponents: components) }
                if let value {
                    let metadata = presentation.metadata
                    let complete = summary.complete && !metadata.coverage.hasGaps
                    let date = metadata.observedThrough.formatted(date: .abbreviated, time: .shortened)
                    let message = !complete ? "Partial scan · \(date) · May have changed"
                        : metadata.refreshCheckpoint?.mayContainEarlierObservations == true
                            ? StorageScanPresentation.recordedObservation(metadata.observedThrough, refresh: metadata.refreshCheckpoint)
                            : "Scanned \(date) · May have changed"
                    observation = FolderSummaryValue(counts: value.counts, bytes: value.bytes, isRunning: false,
                        isComplete: complete, message: message, observedAt: metadata.observedThrough,
                        scanStatus: complete ? .completed : .partial, coverage: metadata.coverage.scanCoverage,
                        observationIsPrevious: true, scanElapsed: metadata.scanElapsed)
                }
            } catch { /* A failed saved lookup falls back to ordinary hover. */ }
            let released = await releaseBorrowed(presentation)
            await drainReleasedCatalogs()
            return Task.isCancelled || !released ? nil : observation
        }
    }

    /// Lexical selection of a saved catalog only. Native current-root access
    /// and identity are still required before any query can be admitted.
    private static func relativeComponents(_ folder: URL, within parent: URL) -> [Data]? {
        guard folder.isFileURL, parent.isFileURL else { return nil }
        let child = Array(folder.standardizedFileURL.path.utf8)
        var prefix = Array(parent.standardizedFileURL.path.utf8)
        if child == prefix { return [] }
        if prefix.last != 47 { prefix.append(47) }
        guard child.starts(with: prefix) else { return nil }
        let pieces = child.dropFirst(prefix.count).split(separator: 47, omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 64, pieces.allSatisfy({ !$0.isEmpty && $0.count <= 255 }) else { return nil }
        return pieces.map { Data($0) }
    }

    /// Register actual views before their first query or UI publication.
    func install(_ prepared: Prepared, revoke: @escaping @MainActor () -> Void,
                 join: @escaping @MainActor () async -> Void) -> Bool {
        let value = prepared.presentation
        guard currentCatalogID == nil, consumers.register(catalogID: value.metadata.catalogID,
            consumerID: value.consumerID, viewID: value.queries.viewID, revoke: revoke, join: join) else { return false }
        current = value; currentCatalogID = value.metadata.catalogID
        currentIsRecorded = true; currentRevoke = revoke
        return true
    }

    @discardableResult func discard(_ prepared: Prepared) async -> Bool {
        guard owner != nil else { return false }
        let value = prepared.presentation
        let released = await releaseBorrowed(value)
        await drainReleasedCatalogs()
        return released || pendingConsumerRelease[value.metadata.catalogID]?.contains(value.consumerID) != true
    }
    private func releaseBorrowed(_ value: RecordedAnalysisPresentation) async -> Bool {
        guard let owner else { return false }
        let catalog = value.metadata.catalogID, consumer = value.consumerID
        switch await owner.releaseConsumer(catalogID: catalog, consumerID: consumer, consumers: drain) {
        case .complete, .unavailable(.changed):
            pendingConsumerRelease[catalog]?.remove(consumer)
            if pendingConsumerRelease[catalog]?.isEmpty == true { pendingConsumerRelease.removeValue(forKey: catalog) }
            pendingIdleClose.insert(catalog); return true
        default:
            pendingConsumerRelease[catalog, default: []].insert(consumer)
            return false
        }
    }

    /// Called synchronously on demand replacement, access changes and close.
    func revokeCurrent() {
        guard let catalog = currentCatalogID else { return }
        let revoke = currentRevoke
        current = nil; currentCatalogID = nil; currentIsRecorded = false; currentRevoke = nil
        pendingClose.insert(catalog)
        revoke?()
        scheduleCleanup()
    }

    func release(result: UUID) {
        guard managedResults.contains(result) else { return }
        if currentCatalogID == result { revokeCurrent() }
        pendingClose.insert(result)
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        guard cleanup == nil else { return }
        let id = UUID(); cleanupID = id
        cleanup = Task { [self] in
            await closeReleasedCatalogs()
            if cleanupID == id { cleanup = nil; cleanupID = nil }
        }
    }
    func drainReleasedCatalogs() async {
        await cleanup?.value
        await closeReleasedCatalogs()
    }
    private func closeReleasedCatalogs() async {
        guard let owner else { return }
        for (catalog, ids) in pendingConsumerRelease {
            for id in ids {
                switch await owner.releaseConsumer(catalogID: catalog, consumerID: id, consumers: drain) {
                case .complete, .unavailable(.changed):
                    pendingConsumerRelease[catalog]?.remove(id); pendingIdleClose.insert(catalog)
                default: break
                }
            }
            if pendingConsumerRelease[catalog]?.isEmpty == true { pendingConsumerRelease.removeValue(forKey: catalog) }
        }
        for id in pendingClose {
            if case .complete = await owner.closeCatalog(id, consumers: drain) {
                pendingClose.remove(id); pendingIdleClose.remove(id); pendingConsumerRelease.removeValue(forKey: id); managedResults.remove(id)
            }
        }
        for id in pendingIdleClose where !pendingClose.contains(id) {
            if case .complete = await owner.closeIdleCatalog(id, consumers: drain) {
                pendingIdleClose.remove(id); pendingConsumerRelease.removeValue(forKey: id); managedResults.remove(id)
            }
        }
    }

    func stopAndDrain(forgetting: Bool = false) async {
        if forgetting, quitReceipt != nil { await resume() }
        if forgetting { forgetCompleted = false }
        revokeCurrent()
        consumerClosure = consumers.closeAdmissions()
        await cleanup?.value
        guard let owner else { return }
        let outcome = forgetting ? await owner.forgetAll(consumers: drain)
            : await owner.quitRetaining(consumers: drain)
        switch outcome {
        case .retainingQuit(let receipt):
            quitReceipt = receipt; managedResults.removeAll(); pendingClose.removeAll(); pendingIdleClose.removeAll(); pendingConsumerRelease.removeAll()
        case .complete:
            managedResults.removeAll(); pendingClose.removeAll(); pendingIdleClose.removeAll(); pendingConsumerRelease.removeAll()
            if forgetting { forgetCompleted = true }
        case .unavailable, .needsAttention: break // Native uncertainty stays owned.
        }
    }

    /// The App's shared drain/repair task owns this call. Healthy catalogs are
    /// simply readable; a repair never authorizes clearing an unknown index.
    func repairSavedAnalyses() async {
        guard let owner, quitReceipt == nil else {
            maintenanceMessage = "Saved analyses are unavailable. Your files are untouched."
            return
        }
        let outcome = await owner.repairSavedAnalyses()
        switch outcome {
        case .ready:
            maintenanceMessage = "Saved analysis storage is ready. Scan Again for current totals."
        case .unavailable(.busy):
            maintenanceMessage = "Saved analyses are busy. Wait for analysis work to finish, then try again."
        case .unavailable:
            maintenanceMessage = "No saved analyses are available. Your files are untouched."
        case .needsAttention:
            maintenanceMessage = "Saved analyses still need attention. Your files are untouched. Export App Logs from Help for support."
        }
    }

    func resume() async {
        if let receipt = quitReceipt, let owner {
            guard case .complete = await owner.resumeAfterAbortedQuit(receipt) else { return }
            quitReceipt = nil
        }
        if let closure = consumerClosure, consumers.reopenAdmissions(closure) { consumerClosure = nil }
    }
    func resumeWhenReady() {
        let previous = cleanup, id = UUID(); cleanupID = id
        cleanup = Task { [self] in
            await previous?.value
            await resume()
            if cleanupID == id { cleanup = nil; cleanupID = nil }
        }
    }
}
