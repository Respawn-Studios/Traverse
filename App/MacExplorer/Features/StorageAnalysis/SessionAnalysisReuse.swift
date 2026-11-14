import Foundation
import StorageAnalysis

/// One immutable observation. Retains a sealed temporary result, no source
/// access lease, watcher, persistent snapshot or mutation authorization.
@MainActor class SessionAnalysisObservation {
    let root: URL
    let update: PagedStorageScanUpdate
    let summary: StoredAnalysisSummary
    let report: AnalysisAttributionReport
    let observedAt: Date
    let result: StorageAnalysisResult
    init(root: URL, update: PagedStorageScanUpdate, summary: StoredAnalysisSummary,
         report: AnalysisAttributionReport, observedAt: Date) throws {
        guard let result = update.result, update.workerDrained, !update.isStartupPair,
              update.status == .completed || update.status == .partial, !report.isProvisional, summary.sources.isEmpty else { throw StorageScanFailure.invalidOutput }
        self.result = result
        self.root = root.standardizedFileURL; self.update = update; self.summary = summary
        self.report = report; self.observedAt = observedAt
    }
    var dateLabel: String { DateFormatter.localizedString(from: observedAt, dateStyle: .medium, timeStyle: .short) }
    func value(refreshing: Bool, note: String? = nil) -> FolderSummaryValue {
        .init(counts: summary.value.counts, bytes: summary.value.bytes, isRunning: refreshing,
            isComplete: summary.complete, message: StorageScanPresentation.recordedObservation(observedAt,
                refresh: result.refreshCheckpoint) + ". " + (note ?? "Refresh to analyze again."),
            observedAt: observedAt, scanStatus: update.status, coverage: update.coverage, observationIsPrevious: true,
            scanElapsed: result.scanElapsed ?? update.elapsed)
    }
}

/// Reopen eligibility is optional and separate from owning a displayed chart.
@MainActor final class SessionAnalysisSnapshot: SessionAnalysisObservation {
    let stamp: AnalysisSessionReuseStamp
    let accessIdentity: FolderAnalysisAccessIdentity
    init(root: URL, update: PagedStorageScanUpdate, summary: StoredAnalysisSummary,
         report: AnalysisAttributionReport, observedAt: Date, stamp: AnalysisSessionReuseStamp,
         accessIdentity: FolderAnalysisAccessIdentity) throws {
        guard update.result?.id == stamp.resultID else { throw StorageScanFailure.invalidOutput }
        self.stamp = stamp; self.accessIdentity = accessIdentity
        try super.init(root: root, update: update, summary: summary, report: report, observedAt: observedAt)
    }
}

/// Two cache references maximum, plus one currently displayed old snapshot in
/// ApplicationStorageAnalysis and one insertion/eviction owner. Real store pool
/// admission remains authoritative; releasing a handle earns no assumed quota.
@MainActor final class SessionAnalysisReuse {
    private var entries: [SessionAnalysisSnapshot] = [] // LRU, oldest first.
    private(set) var epoch = UUID()
    private(set) var inserting = false
    private(set) var admissionClosed = false
    func suspendAdmissions() { admissionClosed = true; epoch = UUID() }
    func resumeAdmissions() { admissionClosed = false }
    private var eviction: Task<Void, Never>?
    var count: Int { entries.count }
    var isDraining: Bool { eviction != nil || inserting }
    static func capacity(poolLimit: UInt64) -> Int {
        // Reserve one live scan and one displayed/retiring old store in addition
        // to cached handles. The kernel charges every live store at the full
        // maximumSessionBytes, including smaller qualification stores.
        let reservations = poolLimit / AnalysisResultStorage.maximumSessionBytes
        return reservations > 2 ? min(2, Int(reservations - 2)) : 0
    }
    func candidate(root: URL, policy: AnalysisMetadataPolicy, access: FolderAnalysisAccessIdentity) -> SessionAnalysisSnapshot? {
        guard !admissionClosed, !inserting, eviction == nil else { return nil }
        return entries.last { $0.root == root.standardizedFileURL && $0.result.metadataPolicy == policy && $0.accessIdentity == access }
    }
    func touch(_ snapshot: SessionAnalysisSnapshot) {
        guard let index = entries.firstIndex(where: { $0 === snapshot }) else { return }
        entries.remove(at: index); entries.append(snapshot)
    }
    func insert(_ snapshot: SessionAnalysisSnapshot, capacity: Int, expectedEpoch: UUID) async -> Bool {
        guard !admissionClosed, !inserting, capacity > 0, capacity <= 2, epoch == expectedEpoch else { return false }
        inserting = true; defer { inserting = false }
        await drainEviction()
        guard !admissionClosed, epoch == expectedEpoch else { return false }
        var retired = entries.filter { $0.root == snapshot.root || $0.result.id == snapshot.result.id }
        entries.removeAll { $0.root == snapshot.root || $0.result.id == snapshot.result.id }
        while entries.count >= capacity { retired.append(entries.removeFirst()) }
        // Eviction releases ONLY this cache's reference. It does not cancel or
        // globally close a shared result that another consumer can still hold.
        await retireReferences(retired)
        guard !admissionClosed, epoch == expectedEpoch else { return false }
        entries.append(snapshot)
        return true
    }
    /// Invalidates matching before any await. The returned handles remain owned
    /// by the caller until it has revoked its UI consumers and joined readers.
    func takeAll() -> [SessionAnalysisSnapshot] {
        epoch = UUID()
        let old = entries; entries = []; return old
    }
    func invalidate() {
        let old = takeAll()
        guard !old.isEmpty else { return }
        // At most two entries can enter this owner. Another insertion refuses
        // while it is active; invalidating an empty cache adds no new task.
        let previous = eviction
        eviction = Task { [weak self] in
            await previous?.value
            for snapshot in old { await snapshot.result.waitUntilReadersDrained() }
            self?.eviction = nil
        }
    }
    func remove(root: URL) async {
        let old = entries.filter { $0.root == root.standardizedFileURL }
        entries.removeAll { $0.root == root.standardizedFileURL }
        await retireReferences(old)
    }
    func drainEviction() async { await eviction?.value }
    private func retireReferences(_ snapshots: [SessionAnalysisSnapshot]) async {
        for snapshot in snapshots { await snapshot.result.waitUntilReadersDrained() }
    }
}
