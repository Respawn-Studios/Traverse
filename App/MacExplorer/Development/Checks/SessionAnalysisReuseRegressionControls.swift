#if DEBUG
import AppKit
import Foundation
import ExplorerCore
import LocalStorage
@_spi(ApplicationOwnership) import StorageAnalysis

/// Successor regressions. Root must admit exact tiny generated APFS roots,
/// native browser/window setup, bounded storage and an actual current worker.
/// These functions are source only; none were compiled or executed here.
@MainActor enum SessionAnalysisReuseRegressionControls {
    private static func require(_ value: Bool, _ label: String) throws { try SessionAnalysisReuseControls.require(value, label) }
    private static func wait(_ label: String, _ condition: () -> Bool) async throws { try await SessionAnalysisReuseControls.wait(label, condition) }
    private static func setup(root: URL, storage: AnalysisResultStorage, worker: URL) async throws -> SessionAnalysisObservation {
        try require(root.isFileURL && root.path.contains("/.build/traverse-development/"), "exact-generated-regression-root-required")
        let owner = ApplicationStorageAnalysis.shared
        await owner.stopAndDrain()
        owner.resumeAfterCancelledTermination()
        owner.enablePagedForQualification(storage: storage, workerURL: worker)
        owner.requiresAnalysisSelectionForVerification = false
        owner.verificationBegin(root: root) { FileAccessLifetimes(leases: []) }
        try await wait("real-current-chart-published") { !owner.hasWork && owner.pagedSummaryForVerification != nil }
        try await wait("native-first-page-query-drained") { owner.toolWindow?.hasPageRequestForSessionReuseVerification == false }
        try require(owner.sessionSnapshotForVerification != nil, "readable-current-chart-has-independent-displayed-observation")
        guard let observation = owner.sessionSnapshotForVerification else { throw NSError(domain: "GeneratedReuseControl", code: 1) }
        return observation
    }
    private static func historical(_ old: SessionAnalysisObservation, _ phase: String) throws {
        let owner = ApplicationStorageAnalysis.shared
        try require(owner.sessionSnapshotForVerification?.result.id == old.result.id
            && owner.sessionSnapshotForVerification?.observedAt == old.observedAt,
            phase + "-keeps-original-result-and-date")
        try require(owner.toolWindow?.displayedResultForSessionReuseVerification == old.result.id
            && owner.toolWindow?.hasVisibleReportForSessionReuseVerification == true
            && owner.toolWindow?.statusLabel.stringValue.contains("Last analyzed " + old.dateLabel) == true
            && owner.toolWindow?.statusLabel.stringValue.contains("May be out of date") == true,
            phase + "-native-old-chart-is-always-visibly-dated")
    }

    /// RED on70F: a held ACTUAL native page query suspends Clear inside its
    /// native consumer drain; eligible hover changes generation/enqueues work,
    /// and Choose Folder invokes the picker while Clear is suspended.
    static func clearAdmission(browser: BrowserViewController, entry: FileEntry,
                               storage: AnalysisResultStorage, worker: URL) async throws -> [String] {
        try require(entry.kind == .directory && StorageAnalysisPolicy.allowsAutomaticRoot(entry.url)
            && browser.displayedEntries.contains(entry) && browser.location.directoryURL == entry.url.deletingLastPathComponent()
            && browser.summaryBrowsingAccess != nil && !browser.isBrowserSuspended && !browser.isOfflineCurrentFolder
            && !browser.isLoading && browser.loadError == nil && browser.issueCount == 0
            && browser.volumes.contains(where: { ($0.kind == .internalDisk || $0.kind == .externalDisk)
                && ($0.url.path == "/" || entry.url.path == $0.url.path || entry.url.path.hasPrefix($0.url.path + "/")) }),
            "root-admitted-actually-eligible-native-hover-entry-required")
        let old = try await setup(root: entry.url, storage: storage, worker: worker)
        let owner = ApplicationStorageAnalysis.shared
        owner.configurePicker(from: browser)
        let held = ReuseHeldRelease(); defer { held.release.signal() }
        var pickerInvocations = 0
        owner.chooseFolderForVerification = { _, _ in pickerInvocations += 1; return nil }
        defer { owner.chooseFolderForVerification = nil }
        try old.result.installQueryReleaseHookForQualification(held.hold)
        owner.toolWindow?.requestFirstPageForSessionReuseVerification()
        try await wait("actual-native-page-reader-held") { held.entered && old.result.activeReaderCount == 1 }
        let clearing = Task { @MainActor in await owner.stopAndDrain() }
        try await wait("clear-suspended-in-real-native-consumer-drain") { owner.clearActiveForSessionReuseVerification && owner.toolWindow?.hasRetiringSessionConsumers == true }
        let state = owner.demandStateForSessionReuseVerification, starts = owner.allScanStartsForSessionReuseVerification
        var responses: [FolderSummaryValue] = []
        owner.beginHover(owner: UUID(), entry: entry, browser: browser) { responses.append($0) }
        owner.openFolderPickerForVerification()
        owner.verificationBegin(root: entry.url) { FileAccessLifetimes(leases: []) }
        // Yield while the real query is still held, rather than accepting an
        // eventually finished worker as proof that admission was shut.
        await Task.yield()
        let after = owner.demandStateForSessionReuseVerification
        var admissionFailure: Error?
        do {
            try require(after.generation == state.generation && after.hover == nil && !after.pending && !after.choosing
                && owner.allScanStartsForSessionReuseVerification == starts && pickerInvocations == 0
                && responses.count == 1 && responses[0].counts == nil && responses[0].message.contains("cleared"),
                "held-clear-refuses-hover-picker-explicit-owner-before-enqueue")
        } catch { admissionFailure = error } // Preserve RED while still joining fixture work.
        let quitting = Task { @MainActor in await owner.stopAndDrain(shuttingDown: true) }
        await Task.yield()
        try require(owner.clearActiveForSessionReuseVerification && old.result.activeReaderCount == 1,
            "concurrent-clear-quit-joins-same-held-owner")
        held.release.signal()
        await clearing.value; await quitting.value
        if let admissionFailure {
            await owner.stopAndDrain(shuttingDown: true)
            owner.resumeAfterCancelledTermination()
            throw admissionFailure
        }
        try require(!held.timedOut && !owner.hasWork && owner.sessionReuseCountForVerification == 0
            && owner.pagedResultForVerification == nil && owner.allScanStartsForSessionReuseVerification == starts,
            "clear-quit-actual-drain-with-zero-new-workers")
        owner.resumeAfterCancelledTermination()
        return ["Actual native page-reader-held Clear rejects eligible hover/picker/explicit admission", "Generation/pending/owner unchanged while held; zero new worker starts", "Concurrent Clear→Quit joins real task/read/discard drain"]
    }

    /// RED on70F: terminal full Refresh sets BreakdownPreparing and overwrites
    /// its visible old date with Finishing while the real summary reader holds.
    /// Optional Properties route exercises that handoff during the same hold.
    static func heldProjection(root: URL, storage: AnalysisResultStorage, worker: URL,
                               failRead: Bool, cancel: Bool, propertiesHandoff: Bool) async throws -> [String] {
        let old = try await setup(root: root, storage: storage, worker: worker)
        let owner = ApplicationStorageAnalysis.shared, held = ReuseHeldRelease()
        defer { held.release.signal(); owner.pagedProjectionAdmissionForSessionReuseVerification = nil }
        var hookError: Error?
        owner.pagedProjectionAdmissionForSessionReuseVerification = { result in
            do {
                try result.installQueryReleaseHookForQualification(held.hold)
                if failRead { try result.installQueryOutcomeFailureForQualification(.invalidOutput) }
            } catch { hookError = error }
        }
        let properties: FilePropertiesWindowController?
        if propertiesHandoff {
            try require(owner.sessionReuseCountForVerification > 0, "properties-handoff-requires-cache-enabled-pool")
            let controller = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) },
                settings: BrowserSettings(persist: false), copyPaths: { _ in })
            properties = controller
            if ProcessInfo.processInfo.arguments.contains("--analysis-reuse-visible") { controller.show(urls: [root]) }
            else { controller.model.update(urls: [root]) }
            try await wait("actual-properties-reuses-old-chart") { controller.model.attribution != nil
                && controller.model.analysisValue?.observationIsPrevious == true && !owner.hasWork }
            controller.model.analyzeStorage()
        } else { properties = nil; owner.refreshForSessionReuseVerification() }
        try await wait("actual-refreshed-summary-reader-held") { held.entered || hookError != nil }
        if let hookError { throw hookError }
        try require(owner.pagedResultForVerification?.id != old.result.id
            && owner.pagedResultForVerification?.activeReaderCount == 1, "new-result-worker-finished-but-actual-projection-reader-held")
        if let properties {
            try require(properties.model.analysisValue?.observedAt == old.observedAt
                && properties.model.analysisValue?.observationIsPrevious == true, "properties-keeps-original-dated-chart-during-projection")
            properties.model.openFullAnalysis()
        }
        try historical(old, "held-terminal-projection")
        if cancel { owner.toolWindow?.stopThroughNativeControlForSessionReuseVerification(); try historical(old, "stopped-held-projection") }
        held.release.signal()
        try await wait("real-refreshed-projection-drained") { !owner.hasWork }
        try require(!held.timedOut, "projection-hold-did-not-expire")
        if failRead || cancel { try historical(old, "failed-or-cancelled-projection") }
        else {
            try require(owner.sessionSnapshotForVerification?.result.id != old.result.id
                && owner.toolWindow?.displayedResultForSessionReuseVerification != old.result.id,
                "only-readable-valid-replacement-removes-old-chart")
        }
        properties?.cancel()
        owner.pagedProjectionAdmissionForSessionReuseVerification = nil
        await owner.stopAndDrain()
        return ["Actual terminal projection hold preserves native Last analyzed/date/stale text", "Valid replacement/read-failure/Stop behavior checked for requested variant", propertiesHandoff ? "Actual Properties→Analyzer handoff while summary reader holds" : "Analyzer projection route"]
    }

    /// Real six/eight-GiB pool boundary with every store held by an actual
    /// independent consumer. An uncertain store remains protected and charged.
    static func poolBoundary(roots: [URL], storage: AnalysisResultStorage, worker: URL) async throws -> [String] {
        let slots = Int(storage.poolByteLimit / AnalysisResultStorage.maximumSessionBytes)
        try require((slots == 3 || slots == 4) && roots.count == slots + 1
            && roots.allSatisfy { $0.isFileURL && $0.path.contains("/.build/traverse-development/") },
            "exact-six-or-eight-GiB-generated-boundary-fixture-required")
        let cache = SessionAnalysisReuse(), capacity = SessionAnalysisReuse.capacity(poolLimit: storage.poolByteLimit)
        try require(capacity == slots - 2, "one-or-two-cache-headroom-without-cap-increase")
        let scanner = StorageScanner(workerURL: worker, activityGate: ApplicationFileActivity.gate)
        let access = FolderAnalysisAccessIdentity(controller: UUID(), revision: UUID(), selectedGrant: nil)
        var values: [SessionAnalysisSnapshot] = []
        do {
            for root in roots.prefix(slots) {
                values.append(try await SessionAnalysisReuseControls.snapshot(scanner: scanner, root: root, storage: storage, access: access))
            }
            let live = try await AnalysisTemporaryStorageReader(activityGate: ApplicationFileActivity.gate).read(directory: storage.directory)
            try require(live.isComplete && live.sessions == slots && live.openSessions == slots && live.unheldSessions == 0,
                "fresh-generated-pool-inventory-matches-exact-live-store-bound")
            values.last?.result.retainAfterCloseForQualification()
            for value in values.prefix(capacity) {
                try require(await cache.insert(value, capacity: capacity, expectedEpoch: cache.epoch), "actual-boundary-cache-reference-admitted")
            }
            let epoch = cache.epoch
            cache.suspendAdmissions()
            try require(!((await cache.insert(values[0], capacity: capacity, expectedEpoch: epoch))), "clearing-cache-fence-rejects-real-handle-insertion")
            cache.resumeAdmissions()
            _ = cache.takeAll() // Independent actual handles remain alive.
            _ = try await values[0].result.summary()
            let rejected = try scanner.startPaged(root: roots.last!, storage: storage, retainingAccess: FileAccessLifetimes(leases: []))
            var terminal: PagedStorageScanUpdate?
            for await update in rejected.updates { if update.workerDrained { terminal = update } }
            await rejected.waitUntilDrained()
            if let unexpected = terminal?.result { await unexpected.closeAfterRevokingApplicationConsumersAndDrain() }
            try require(terminal?.status == .failed(.resourceLimit), "real-pool-still-charges-reader-held-and-uncertain-stores-after-cache-reference-clear")
        } catch {
            _ = cache.takeAll(); await cache.drainEviction()
            for value in values { await value.result.closeAfterRevokingApplicationConsumersAndDrain() }
            await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain(); throw error
        }
        _ = cache.takeAll(); await cache.drainEviction()
        for value in values { await value.result.closeAfterRevokingApplicationConsumersAndDrain() }
        await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
        let retained = try await AnalysisTemporaryStorageReader(activityGate: ApplicationFileActivity.gate).read(directory: storage.directory)
        try require(retained.isComplete && retained.sessions == 1 && retained.openSessions == 0 && retained.unheldSessions == 1
            && (retained.logicalFileBytes ?? 0) > 0 && (retained.allocatedNameBytes ?? 0) > 0,
            "actual-post-close-uncertain-session-remains-with-positive-observed-bytes")
        return ["Actual six/eight-GiB one/two-cache store saturation", "Independent and uncertain held stores remain charged after cache-reference release", "Extra store refused by unchanged real pool", "Post-close metadata inventory confirms one unheld uncertain store and positive observed bytes; no scalar quota credit claimed"]
    }

    /// RED on70F at the first displayed-observation assertion:4GiB deliberately
    /// disables LRU insertion but previously also lost old-chart ownership.
    /// Another test-owned actual store fills the pool; Refresh's third store
    /// must fail honestly without increasing the cap or blanking the chart.
    static func cacheDisabledFallback(root: URL, extraRoot: URL, storage: AnalysisResultStorage,
                                      worker: URL, refuseAtEightGiB: Bool = false) async throws -> [String] {
        let owner = ApplicationStorageAnalysis.shared
        try require(storage.poolByteLimit == (UInt64(refuseAtEightGiB ? 8 : 4) << 30), "actual-four-or-eight-GiB-fixture-pool-required")
        if refuseAtEightGiB {
            owner.cacheInsertionAdmissionForSessionReuseVerification = { owner.invalidateOnlyReopenCacheForSessionReuseVerification() }
        }
        defer { owner.cacheInsertionAdmissionForSessionReuseVerification = nil }
        let old = try await setup(root: root, storage: storage, worker: worker)
        try require(owner.sessionReuseCountForVerification == 0 && owner.sessionSnapshotForVerification?.result.id == old.result.id,
            "current-readable-chart-owned-independently-of-zero-or-refused-LRU-insertion")
        owner.refreshForSessionReuseVerification(); owner.stopForSessionReuseVerification()
        try await wait("cache-disabled-stop-before-worker-drain") { !owner.hasWork }
        try historical(old, "cache-disabled-cancel-before-launch")
        if !refuseAtEightGiB {
            let identity = FolderAnalysisAccessIdentity(controller: UUID(), revision: UUID(), selectedGrant: nil)
            let extra = try await SessionAnalysisReuseControls.snapshot(scanner: StorageScanner(workerURL: worker,
                activityGate: ApplicationFileActivity.gate), root: extraRoot, storage: storage, access: identity)
            do {
                owner.refreshForSessionReuseVerification()
                try await wait("actual-four-GiB-third-store-refused") { !owner.hasWork }
                try historical(old, "actual-pool-resource-refusal")
                try require(owner.pagedUpdateForVerification?.status == .failed(.resourceLimit), "unchanged-real-pool-refuses-third-live-store")
            } catch { await extra.result.closeAfterRevokingApplicationConsumersAndDrain(); throw error }
            await extra.result.closeAfterRevokingApplicationConsumersAndDrain()
        }
        owner.enablePagedForQualification(storage: storage, workerURL: root.appendingPathComponent("Generated Missing Worker"))
        owner.refreshForSessionReuseVerification()
        try await wait("cache-disabled-real-worker-failure-drains") { !owner.hasWork }
        try historical(old, "cache-disabled-failed-refresh")
        owner.enablePagedForQualification(storage: storage, workerURL: worker)
        await owner.stopAndDrain()
        return ["Actual current chart survives zero/refused cache insertion", "Cancel and actual worker failure retain original native date/chart", refuseAtEightGiB ? "Eight-GiB epoch-refused insertion retains display" : "Actual four-GiB third-store refusal preserves old chart without cap increase"]
    }
}
#endif
