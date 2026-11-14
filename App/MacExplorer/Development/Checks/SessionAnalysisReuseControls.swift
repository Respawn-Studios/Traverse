#if DEBUG
import AppKit
import Foundation
import ExplorerCore
import LocalStorage
@_spi(ApplicationOwnership) import StorageAnalysis

final class ReuseHeldRelease: @unchecked Sendable {
    private final class Totals: @unchecked Sendable { let lock = NSLock(); var timeouts = 0 }
    private static let totals = Totals()
    static var timeoutCountForRunner: Int { totals.lock.withLock { totals.timeouts } }
    private let lock = NSLock()
    private var enteredValue = false, timedOutValue = false
    let release = DispatchSemaphore(value: 0)
    func hold() {
        let first = lock.withLock { () -> Bool in
            guard !enteredValue else { return false }; enteredValue = true; return true
        }
        guard first else { return }
        if release.wait(timeout: .now() + 8) != .success {
            lock.withLock { timedOutValue = true }
            Self.totals.lock.withLock { Self.totals.timeouts += 1 }
        }
    }
    var entered: Bool { lock.withLock { enteredValue } }
    var timedOut: Bool { lock.withLock { timedOutValue } }
}
private struct GeneratedReuseAccess: FolderAccessBackend {
    func startAccess(to url: URL) -> Bool { true }
    func stopAccess(to url: URL) {}
    func bookmark(for url: URL) throws -> Data { Data("generated-access".utf8) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw StorageScanFailure.unsupportedLocation }
}

/// Root-admitted controls only. No test runs are implied by this source. Roots,
/// storage and worker must be exact generated/admitted inputs; no production
/// files are created, deleted, reparented or used as a destructive fixture here.
@MainActor enum SessionAnalysisReuseControls {
    enum Failure: Error { case check(String) }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.check(label) }
    }
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.check(label) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func snapshot(scanner: StorageScanner, root: URL, storage: AnalysisResultStorage,
                                 access: FolderAnalysisAccessIdentity) async throws -> SessionAnalysisSnapshot {
        let session = try scanner.startPaged(root: root, storage: storage, retainingAccess: FileAccessLifetimes(leases: []))
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates { if update.workerDrained { terminal = update } }
        await session.waitUntilDrained()
        guard let update = terminal, update.status == .completed, let result = update.result else { throw Failure.check("actual-sealed-generated-result-required") }
        let summary = try await result.summary()
        guard let report = try await result.attribution(scopeName: "Generated root", summary: summary) else { throw Failure.check("actual-sealed-chart-report-required") }
        let stamp = try await result.validateSessionReuse(root: root, metadataPolicy: .standard, retainingAccess: FileAccessLifetimes(leases: []))
        return try .init(root: root, update: update, summary: summary, report: report, observedAt: Date(timeIntervalSince1970: 1_790_000_000),
                         stamp: stamp, accessIdentity: access)
    }
    /// Three real generated scanner results exercise LRU/shared ownership. The
    /// query-release hook holds an ACTUAL native query before its slot retires.
    static func retention(roots: [URL], storage: AnalysisResultStorage, worker: URL) async throws -> [String] {
        try require(roots.count == 3 && roots.allSatisfy { $0.isFileURL && $0.path.contains("/.build/traverse-development/") }, "three-owned-generated-roots-required")
        try require(SessionAnalysisReuse.capacity(poolLimit: storage.poolByteLimit) == 2, "actual-pool-reserves-two-cache-plus-two-transient-stores")
        let scanner = StorageScanner(workerURL: worker, activityGate: ApplicationFileActivity.gate)
        let identity = FolderAnalysisAccessIdentity(controller: UUID(), revision: UUID(), selectedGrant: nil)
        let first = try await snapshot(scanner: scanner, root: roots[0], storage: storage, access: identity)
        let second = try await snapshot(scanner: scanner, root: roots[1], storage: storage, access: identity)
        let third = try await snapshot(scanner: scanner, root: roots[2], storage: storage, access: identity)
        let cache = SessionAnalysisReuse(), epoch = cache.epoch
        do {
            try require(await cache.insert(first, capacity: 2, expectedEpoch: epoch), "insert-first-real-handle")
            try require(await cache.insert(second, capacity: 2, expectedEpoch: epoch), "insert-second-real-handle")
            cache.touch(first) // second becomes the actual eviction candidate.
            let held = ReuseHeldRelease()
            defer { held.release.signal() }
            try second.result.installQueryReleaseHookForQualification(held.hold)
            let query = Task { try await second.result.summary() }
            try await wait("real-reader-held-before-slot-release") { held.entered && second.result.activeReaderCount == 1 }
            var insertionReturned = false
            let insertion = Task { @MainActor in
                let value = await cache.insert(third, capacity: 2, expectedEpoch: epoch)
                insertionReturned = true; return value
            }
            try await wait("eviction-holds-actual-reader-lifetime") { cache.inserting }
            try require(!insertionReturned && second.result.activeReaderCount == 1, "cache-reference-not-released-before-reader-drain")
            held.release.signal()
            _ = try await query.value
            let inserted = await insertion.value
            try require(inserted && !held.timedOut, "actual-reader-drained-before-eviction-finished")
            try second.result.installQueryReleaseHookForQualification(nil)
            try require(cache.count == 2 && cache.candidate(root: second.root, policy: .standard, access: identity) == nil,
                        "bounded-LRU-evicts-one-cache-reference")
            // Another consumer still holds this real shared handle. Eviction
            // MUST NOT globally close it, cancel future readers or delete it.
            _ = try await second.result.summary()
            let stale = first.value(refreshing: true, note: "Refresh cancelled.")
            try require(stale.observedAt == first.observedAt && stale.observationIsPrevious
                        && stale.message.contains("Last analyzed") && stale.message.contains("May be out of date"), "dated-observation-never-relabelled-current")
            let otherAccess = FolderAnalysisAccessIdentity(controller: identity.controller, revision: UUID(), selectedGrant: nil)
            try require(cache.candidate(root: first.root, policy: .standard, access: otherAccess) == nil, "revoked-access-identity-cannot-hit")
            try require(cache.candidate(root: first.root, policy: .applicationData, access: identity) == nil, "policy-mismatch-cannot-hit")
            _ = cache.takeAll()
            try require(!((await cache.insert(first, capacity: 2, expectedEpoch: epoch))), "stale-epoch-cannot-repopulate-cleared-cache")
            _ = try await first.result.summary() // Pure cache clear preserves another consumer.
            // Explicit clear has a different authority fence: this test owns
            // every third-result consumer and permanently revokes new readers.
            let heldClear = ReuseHeldRelease()
            defer { heldClear.release.signal() }
            try third.result.installQueryReleaseHookForQualification(heldClear.hold)
            let clearQuery = Task { try await third.result.summary() }
            try await wait("clear-has-real-reader-held") { heldClear.entered && third.result.activeReaderCount == 1 }
            var clearReturned = false
            let clear = Task { @MainActor in
                await third.result.closeAfterRevokingApplicationConsumersAndDrain()
                clearReturned = true
            }
            try await Task.sleep(for: .milliseconds(10))
            try require(!clearReturned && third.result.activeReaderCount == 1, "explicit-clear-awaits-actual-reader-release")
            heldClear.release.signal()
            do { _ = try await clearQuery.value } catch is CancellationError {} // Clear cancels this admitted reader.
            await clear.value
            try require(!heldClear.timedOut && third.result.activeReaderCount == 0, "explicit-clear-finishes-after-reader-drain")
            var refused = false
            do { _ = try await third.result.summary() } catch StorageScanFailure.busy { refused = true }
            try require(refused, "permanently-revoked-owner-refuses-late-reader")
            try require(SessionAnalysisReuse.capacity(poolLimit: 6 << 30) == 1
                        && SessionAnalysisReuse.capacity(poolLimit: 4 << 30) == 0, "smaller-pools-tighten-retention-without-weakening-kernel-limits")
        } catch {
            _ = cache.takeAll(); await cache.drainEviction()
            // These are test-owned results; all test UI consumers are absent.
            for value in [first, second, third] { await value.result.closeAfterRevokingApplicationConsumersAndDrain() }
            throw error
        }
        _ = cache.takeAll(); await cache.drainEviction()
        for value in [first, second, third] { await value.result.closeAfterRevokingApplicationConsumersAndDrain() }
        return ["Three actual sealed generated results", "Reader-held eviction awaits actual slot release", "Shared handle remains readable after eviction/cache-reference clear", "LRU/two-slot/access/policy/epoch bounds", "Explicit owned close awaits held reader and refuses late admission", "Dated cancellation semantics and smaller-pool fallback"]
    }
    /// Root must admit an exact disposable single-root fixture and an absent
    /// sibling backup path. The generated old root is retained for inspection.
    /// This control changes no real user root and executes no mutation here.
    static func replacedRoot(root: URL, backup: URL, storage: AnalysisResultStorage, worker: URL) async throws -> [String] {
        try require(root.isFileURL && root.path.contains("/.build/traverse-development/")
                    && backup.deletingLastPathComponent() == root.deletingLastPathComponent()
                    && backup != root, "exact-owned-replacement-fixture-required")
        let backupExists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: backup.path) }.value
        try require(!backupExists, "generated-backup-must-be-absent")
        let identity = FolderAnalysisAccessIdentity(controller: UUID(), revision: UUID(), selectedGrant: nil)
        let scanner = StorageScanner(workerURL: worker, activityGate: ApplicationFileActivity.gate)
        let old = try await snapshot(scanner: scanner, root: root, storage: storage, access: identity)
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.moveItem(at: root, to: backup)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            }.value
            var rejected = false
            do { _ = try await old.result.validateSessionReuse(root: root, metadataPolicy: .standard, retainingAccess: FileAccessLifetimes(leases: [])) }
            catch StorageScanFailure.changed { rejected = true }
            try require(rejected, "same-path-replaced-root-must-fail-actual-identity-binding")
            _ = try await old.result.summary() // Readable dated chart is still an immutable observation.
        } catch {
            await old.result.closeAfterRevokingApplicationConsumersAndDrain(); throw error
        }
        await old.result.closeAfterRevokingApplicationConsumersAndDrain()
        return ["Actual generated same-path root replacement rejects reuse", "Replaced-root observation remains a readable dated result without mutation authority"]
    }
    static func accessIdentity(root: URL) async throws -> [String] {
        let backend = GeneratedReuseAccess(), owner = FolderAccessController(stateDirectory: nil, backend: GeneratedReuseAccess())
        let lease = FolderAccessLease(url: root, backend: backend)
        try require(owner.acceptOpenedFolder(root, retaining: lease), "generated-explicit-access-accepted")
        guard let original = owner.analysisReuseIdentity(for: root, requiringSelection: true), let id = owner.locations.first?.id else { throw Failure.check("generated-grant-identity-required") }
        owner.invalidatePendingRequests()
        try require(owner.analysisReuseIdentity(for: root, requiringSelection: true) == original, "chooser-cancellation-does-not-revoke-unchanged-grant")
        _ = await owner.forget(id: id)
        try require(owner.analysisReuseIdentity(for: root, requiringSelection: true) == nil, "forgotten-grant-cannot-authorize-reuse")
        return ["Actual FolderAccess identity follows grants rather than chooser tasks", "Forget invalidates selected access without persistence or OS bookmark changes"]
    }
    /// Actual ApplicationStorageAnalysis + Properties/Analyzer handoff. This
    /// opens only its generated Analyzer window. Root must admit native UI.
    static func application(root: URL, worker: URL, storage: AnalysisResultStorage) async throws -> [String] {
        try require(root.isFileURL && root.path.contains("/.build/traverse-development/"), "owned-app-reuse-root-required")
        let owner = ApplicationStorageAnalysis.shared
        await owner.stopAndDrain()
        owner.enablePagedForQualification(storage: storage, workerURL: worker)
        owner.requiresAnalysisSelectionForVerification = false
        owner.verificationBegin(root: root) { FileAccessLifetimes(leases: []) }
        try await wait("first-actual-local-scan-and-retention") { !owner.hasWork && owner.sessionSnapshotForVerification != nil }
        guard let first = owner.sessionSnapshotForVerification else { throw Failure.check("first-real-app-snapshot") }
        let starts = owner.pagedScanStartsForSessionReuseVerification
        owner.verificationBegin(root: root) { FileAccessLifetimes(leases: []) }
        try await wait("reopen-fresh-binding-without-rescan") { !owner.hasWork && owner.sessionPresentationIsPreviousForVerification }
        try require(owner.sessionSnapshotForVerification?.result.id == first.result.id
                    && owner.pagedScanStartsForSessionReuseVerification == starts, "actual-reopen-dispatches-zero-scanners")
        let properties = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) }, settings: BrowserSettings(persist: false), copyPaths: { _ in })
        if ProcessInfo.processInfo.arguments.contains("--analysis-reuse-visible") { properties.show(urls: [root]) }
        else { properties.model.update(urls: [root]) }
        try await wait("actual-properties-restores-dated-chart") { properties.model.attribution != nil && properties.model.analysisValue?.observationIsPrevious == true && !owner.hasWork }
        try require(properties.model.chartDrill.scopeIdentity == first.result.id
                    && owner.pagedScanStartsForSessionReuseVerification == starts, "properties-matching-reopen-has-no-automatic-scan")
        properties.model.openFullAnalysis()
        try await wait("properties-to-analyzer-query-owner-handoff") { !owner.hasWork }
        let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
        let orderingMatchesMode = owner.toolWindow?.window?.isVisible == !offscreen
        try require(properties.model.chartDrill.scopeIdentity == nil && orderingMatchesMode
                    && owner.toolWindow?.displayedResultForSessionReuseVerification == first.result.id
                    && owner.toolWindow?.hasVisibleReportForSessionReuseVerification == true,
                    "old-properties-reader-revoked-before-analyzer-handoff")
        owner.refreshForSessionReuseVerification()
        owner.stopForSessionReuseVerification()
        try await wait("stop-before-fresh-worker-start-drains") { !owner.hasWork }
        try require(owner.sessionSnapshotForVerification?.observedAt == first.observedAt
                    && owner.sessionSnapshotForVerification?.result.id == first.result.id, "cancelled-refresh-keeps-original-date-and-chart")
        owner.refreshForSessionReuseVerification()
        try await wait("explicit-full-refresh-replaces-sealed-result") { !owner.hasWork && owner.sessionSnapshotForVerification?.result.id != first.result.id }
        guard let refreshed = owner.sessionSnapshotForVerification else { throw Failure.check("refreshed-real-snapshot") }
        try require(owner.pagedScanStartsForSessionReuseVerification == starts + 1 && refreshed.observedAt >= first.observedAt,
                    "explicit-refresh-starts-full-scanner-once")
        // A deliberately unavailable generated helper path causes an actual
        // failed refresh; it cannot convert the old observation into current.
        owner.enablePagedForQualification(storage: storage, workerURL: root.appendingPathComponent("Generated Missing Worker"))
        owner.refreshForSessionReuseVerification()
        try await wait("failed-refresh-drains") { !owner.hasWork }
        try require(owner.sessionSnapshotForVerification?.result.id == refreshed.result.id
                    && owner.sessionSnapshotForVerification?.observedAt == refreshed.observedAt
                    && owner.toolWindow?.statusLabel.stringValue.contains("Last analyzed") == true, "failed-refresh-keeps-dated-chart")
        owner.enablePagedForQualification(storage: storage, workerURL: worker)
        var trashRefusal = ""
        owner.reviewReusedTrashForVerification { trashRefusal = $0 }
        try require(trashRefusal.contains("dated observation"), "cached-chart-cannot-authorize-trash")
        properties.cancel()
        await owner.stopAndDrain(shuttingDown: true)
        try require(!owner.hasWork && owner.sessionReuseCountForVerification == 0 && owner.pagedResultForVerification == nil,
                    "clear-quit-detaches-both-consumers-and-joins-actual-work")
        owner.resumeAfterCancelledTermination()
        return ["Actual app cache hit launches zero scans", "Actual Properties/Analyzer consumer handoff", "Cancelled and failed Refresh preserve date/result", "Explicit Refresh uses full scanner once", "Cached Trash refusal", "Clear/Quit joins real readers and releases owned session handles"]
    }
}
#endif
