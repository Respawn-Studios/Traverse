#if DEBUG
import AppKit
import Darwin
import CryptoKit
import ExplorerCore
import StorageAnalysis

/// Current signed Debug application + bundled Rust worker + attribution/charts
/// and native rows. Reuses two exact generated corpora; synthetic stress inputs
/// stay in RAM. No personal scope, body read, fixture creation or engine switch.
@MainActor
enum StorageAnalysisScaleVerification {
    /// The exact existing generated corpora, with no output artifact or new
    /// filesystem fixture. This is independent of the long-running frozen soak.
    static func reportingExistingSources() async throws -> [[String: Any]] {
        let coordinator = ApplicationStorageAnalysis.shared
        var samples: [[String: Any]] = []
        for index in 0..<3 {
            for name in index % 2 == 0 ? ["wide", "mixed"] : ["mixed", "wide"] {
                samples.append(try await actual(name, repeatIndex: index, coordinator: coordinator))
            }
        }
        samples.append(try await postScanStop(coordinator))
        await coordinator.stopAndDrain(); coordinator.toolWindow?.close()
        try UIVerification.require(!coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0,
            "Existing-source reporting released UI before actual work drain")
        return samples
    }

    private final class HeldProjection: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var waiting = false
        var isWaiting: Bool { lock.withLock { waiting } }
        func hold() throws {
            lock.withLock { waiting = true }
            guard gate.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
            try Task.checkCancellation()
        }
        func release() { gate.signal() }
    }

    /// Existing generated source only. Exercise Properties' post-scan state,
    /// handoff without a rescan, and the real native Stop control while the
    /// attribution task is deterministically held after the child has exited.
    private static func postScanStop(_ coordinator: ApplicationStorageAnalysis) async throws -> [String: Any] {
        await coordinator.stopAndDrain()
        let root = try await admittedSource("wide"), owner = UUID(), hold = HeldProjection()
        var value: FolderSummaryValue?, accessCalls = 0
        defer { hold.release(); coordinator.projectionHookForVerification = nil; coordinator.toolWindow?.close() }
        coordinator.projectionHookForVerification = { try hold.hold() }
        coordinator.analyzeProperties(owner: owner, root: root, access: {
            accessCalls += 1
            return FileAccessLifetimes(leases: [])
        }, onChange: { observed, _ in value = observed })
        do {
            try await UIVerification.waitUntil("Existing-source post-scan projection is held") {
                hold.isWaiting && coordinator.activeSession == nil
            }
            let propertiesRunning = value?.isRunning == true && value?.message.contains("Preparing storage breakdown") == true
            try UIVerification.require(coordinator.openFullAnalysis(owner: owner, root: root),
                "In-flight Properties handoff refused its own observed root")
            guard let tool = coordinator.toolWindow else { throw UIVerification.Failure(message: "Post-scan tool window is unavailable") }
            try await UIVerification.waitUntil("Post-scan native rows finish while breakdown remains held") {
                tool.preparedFolderCount == 101 && !tool.isPreparingRows
            }
            let offeredStop = tool.stopButton.isEnabled
            tool.stopButton.performClick(nil)
            let retained = coordinator.hasWork && coordinator.activeSession == nil && tool.preparedFolderCount == 101
                && !tool.isPreparingRows && tool.statusLabel.stringValue.contains("Stopped preparing")
            var drained = false
            let drain = Task { @MainActor in await coordinator.stopAndDrain(); drained = true }
            try await Task.sleep(for: .milliseconds(30))
            let waited = !drained
            hold.release(); await drain.value
            try UIVerification.require(propertiesRunning && offeredStop && retained && waited && accessCalls == 1
                && !coordinator.hasWork && coordinator.attributionForVerification == nil
                && ApplicationFileActivity.gate.activeCount == 0,
                "Post-scan Stop/handoff lost phase state, restarted rows/scanning or released an actual owner early")
            return ["case": "post-scan-stop", "properties_running": propertiesRunning,
                "native_stop_enabled": offeredStop, "rows_preserved": true, "access_calls": accessCalls,
                "actual_projection_drain": waited, "new_fixture_or_store": false]
        } catch {
            hold.release(); await coordinator.stopAndDrain(); throw error
        }
    }

    private final class LeaseEndCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var ended: Int { lock.withLock { count } }
        func end() { lock.withLock { count += 1 } }
    }
    private final class RetentionLease: Sendable {
        let counter: LeaseEndCounter
        init(_ counter: LeaseEndCounter) { self.counter = counter }
        deinit { counter.end() }
    }

    /// Reuses the exact previously generated helper that emits malformed output
    /// and ignores SIGTERM. No new helper, source fixture or result file.
    static func rejectMalformedWorker() async throws -> [[String: Any]] {
        let root = try await admittedSource("wide")
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let helper = repository.appendingPathComponent(".build/b06-consumer-profile-build/paged-protocol-c9e7e58f3d474992bf67309fff10c890/stubborn-worker")
        try await Task.detached(priority: .utility) {
            let descriptor = open(helper.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard descriptor >= 0 else { throw UIVerification.Failure(message: "Qualified malformed helper is unavailable") }
            defer { close(descriptor) }
            var observed = stat(), bytes = [UInt8](repeating: 0, count: 33_521)
            guard fstat(descriptor, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
                  observed.st_uid == geteuid(), observed.st_nlink == 1, observed.st_size == 33_520,
                  observed.st_mode & 0o777 == 0o755,
                  pread(descriptor, &bytes, bytes.count, 0) == 33_520 else {
                throw UIVerification.Failure(message: "Qualified malformed helper changed")
            }
            let digest = SHA256.hash(data: Data(bytes.prefix(33_520))).map { String(format: "%02x", $0) }.joined()
            guard digest == "14afb3a6cdc10ba3efdfebe352a3ee48a24fc696c25e2581c3fa13650345463c" else {
                throw UIVerification.Failure(message: "Qualified malformed helper bytes changed")
            }
        }.value
        let gate = FileActivityGate(), counter = LeaseEndCounter()
        let scanner = StorageScanner(workerURL: helper, activityGate: gate)
        var results: [[String: Any]] = []
        for index in 0..<2 {
            let began = ProcessInfo.processInfo.systemUptime
            let session = try scanner.start(root: root, retainingAccess: RetentionLease(counter))
            do {
                _ = try scanner.start(root: root, retainingAccess: "Rejected concurrent demand")
                throw UIVerification.Failure(message: "Ordinary scanner admitted concurrent actual work")
            } catch let error as StorageScanFailure { try UIVerification.require(error == .busy, "Concurrent scanner refusal changed") }
            var last: StorageScanUpdate?
            for await update in session.updates { last = update }
            await session.waitUntilDrained()
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            try UIVerification.require(last?.status == .failed(.invalidOutput) && last?.workerDrained == true
                && last?.snapshot?.isComplete == false && gate.activeCount == 0 && counter.ended == index + 1
                && elapsed >= 1.8 && elapsed < 8,
                "Ordinary malformed-worker refusal did not retain access through actual child drain")
            results.append(["repeat": index, "seconds": elapsed, "invalid_output": true,
                "actual_drain": true, "released_leases": counter.ended, "gate_active": gate.activeCount])
        }
        return results
    }

    /// Low-cadence overnight lifecycle qualification. Large generated model
    /// records remain in RAM; periodic real scans use the original admitted
    /// corpus identities. No new source fixture, store, capture or receipt.
    static func reportingSoak(seconds: Int) async throws -> [String: Any] {
        try UIVerification.require((600...21_600).contains(seconds), "Unbounded analysis soak")
        let began = ProcessInfo.processInfo.systemUptime
        let coordinator = ApplicationStorageAnalysis.shared
        let heartbeat = Heartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeat.tick() }
        }
        defer { timer.invalidate() }
        var cycles = 0, actualScans = 0
        var maximumRSS: UInt64 = 0, firstRSS: UInt64 = 0, lastRSS: UInt64 = 0
        var maximumCycleSeconds = 0.0
        while ProcessInfo.processInfo.systemUptime - began < Double(seconds) {
            try Task.checkCancellation()
            let cycleBegan = ProcessInfo.processInfo.systemUptime
            _ = try await synthetic(cycles % 2 == 0 ? "folders" : "projects")
            if cycles % 15 == 0 {
                for name in ["wide", "mixed"] {
                    _ = try await actual(name, repeatIndex: actualScans / 2, coordinator: coordinator)
                    actualScans += 1
                }
                await coordinator.stopAndDrain()
                coordinator.toolWindow?.close()
                try UIVerification.require(!coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0,
                    "Soak released UI demand before actual scan/projection drain")
            }
            try UIVerification.requireControlledWindowsHidden("analysis soak cycle")
            // Yield a run-loop turn before measuring retained state; copied
            // native views and autoreleased drawing temporaries can retire.
            try await Task.sleep(for: .milliseconds(100))
            let current = resources()["current_rss_bytes"] ?? 0
            try UIVerification.require(current > 0 && current < 1_073_741_824,
                "Analysis soak exceeded its 1 GiB resident safety ceiling")
            if cycles == 0 { firstRSS = current }
            lastRSS = current; maximumRSS = max(maximumRSS, current)
            maximumCycleSeconds = max(maximumCycleSeconds, ProcessInfo.processInfo.systemUptime - cycleBegan)
            cycles += 1
            if cycles % 3 == 0 {
                print("MAC_EXPLORER_ANALYSIS_SOAK cycles=\(cycles) actual_scans=\(actualScans) rss_bytes=\(current)")
                fflush(stdout)
            }
            let remaining = Double(seconds) - (ProcessInfo.processInfo.systemUptime - began)
            let delay = min(max(0, 20 - (ProcessInfo.processInfo.systemUptime - cycleBegan)), max(0, remaining))
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        await coordinator.stopAndDrain(); coordinator.toolWindow?.close()
        heartbeat.tick()
        return ["duration_seconds": ProcessInfo.processInfo.systemUptime - began, "cycles": cycles,
            "actual_read_only_scans": actualScans, "first_retained_rss_bytes": firstRSS,
            "last_retained_rss_bytes": lastRSS, "maximum_retained_rss_bytes": maximumRSS,
            "maximum_cycle_seconds": maximumCycleSeconds,
            "maximum_main_heartbeat_gap_seconds": heartbeat.maximumGap,
            "scope": "Descriptive overnight lifecycle/retention observations under concurrent development; not matched timing or a simultaneous-memory bound",
            "safety_ceiling_bytes": UInt64(1_073_741_824)]
    }

    @MainActor private final class Heartbeat {
        var last = ProcessInfo.processInfo.systemUptime
        var maximumGap = 0.0
        func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, now - last); last = now
        }
    }

    static func run(coordinator: ApplicationStorageAnalysis, output: URL) async throws -> [String] {
        let heartbeat = Heartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeat.tick() }
        }
        defer { timer.invalidate() }
        var samples: [[String: Any]] = []
        for repeatIndex in 0..<3 {
            for name in repeatIndex % 2 == 0 ? ["wide", "mixed"] : ["mixed", "wide"] {
                samples.append(try await actual(name, repeatIndex: repeatIndex, coordinator: coordinator))
            }
        }
        await coordinator.stopAndDrain(); coordinator.toolWindow?.close()
        for name in ["folders", "projects"] { samples.append(try await synthetic(name)) }
        heartbeat.tick()
        let report: [String: Any] = ["schema": 1, "passed": true, "samples": samples,
            "maximum_main_heartbeat_gap_seconds": heartbeat.maximumGap,
            "scope": "Current signed Debug app; descriptive current-pipeline qualification, not an optimized comparative benchmark or full-internal-disk scan.",
            "memory_note": "Parent peak is process-lifetime and includes earlier native checks. Worker peak is separate; summing independent peaks is only a conservative bound, not a sampled simultaneous maximum.",
            "limits": "Existing 220k fixture entries / 1 GiB logical / 2 GiB allocation and 2 GiB isolated tooling remain unchanged. Stress records are in memory only."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try UIVerification.require(data.count <= 32_768, "Scale receipt exceeded its admitted projection")
        try data.write(to: output.appendingPathComponent("analysis-scale.json"), options: .withoutOverwriting)
        return ["Current signed app: six alternating actual Rust wide/mixed scan-to-display samples, coverage and category/project reconciliation; actual worker drain",
                "Current native display: 220k in-memory folders and 110k project scopes; attribution/chart preparation, lazy row counts and descriptive parent/worker memory recorded"]
    }

    private static func actual(_ name: String, repeatIndex: Int,
                               coordinator: ApplicationStorageAnalysis) async throws -> [String: Any] {
        let root = try await admittedSource(name)
        let began = ProcessInfo.processInfo.systemUptime, before = resources()
        coordinator.verificationBegin(root: root) { FileAccessLifetimes(leases: []) }
        coordinator.toolWindow?.showWindow(nil)
        var firstProgress: Double?
        while coordinator.hasWork {
            if firstProgress == nil, (coordinator.updateForVerification?.progress?.processedRecords ?? 0) > 0 {
                firstProgress = ProcessInfo.processInfo.systemUptime - began
            }
            try UIVerification.require(ProcessInfo.processInfo.systemUptime - began < 60, "Scale current-pipeline scan timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
        let expectedFolders = name == "wide" ? 101 : 165
        try await UIVerification.waitUntil("Scale native folder rows") {
            coordinator.toolWindow?.isPreparingRows == false
                && coordinator.toolWindow?.preparedFolderCount == expectedFolders
        }
        guard let update = coordinator.updateForVerification, let snapshot = update.snapshot,
              let report = coordinator.attributionForVerification else {
            throw UIVerification.Failure(message: "Scale current observation was not retained")
        }
        let expectedRecords: UInt64 = name == "wide" ? 100_000 : 99_392
        let expectedFiles: UInt64 = name == "wide" ? 99_900 : 99_228
        // Frozen generator: 64 bytes on each sixteenth regular entry; other
        // entries are empty. Mixed's depth-omitted names all belong to its
        // zero-byte cohort, so this declared logical subtotal stays unchanged.
        let expectedLogical: UInt64 = name == "wide" ? 399_616 : 399_360
        try UIVerification.require(update.workerDrained && snapshot.root.counts.total == expectedRecords
            && snapshot.root.counts.regularFiles == expectedFiles && snapshot.rejectedRecords == 0
            && (name == "wide" ? update.status == .completed : update.status == .partial),
            "Scale \(name) coverage mismatch: status=\(update.status), entries=\(snapshot.root.counts.total), input_events=\(snapshot.processedRecords), files=\(snapshot.root.counts.regularFiles), rejected=\(snapshot.rejectedRecords), drained=\(update.workerDrained)")
        try UIVerification.require(snapshot.root.namespaceSubtotals.dataLogical.knownBytes == expectedLogical
            && snapshot.root.namespaceSubtotals.allForkLogical.knownBytes == expectedLogical
            && snapshot.distinctObjects.byteSubtotals.dataLogical.knownBytes == expectedLogical
            && snapshot.distinctObjects.knownObjectCount == expectedFiles,
            "Scale source declaration, namespace bytes or distinct-object accounting changed")
        if name == "mixed" {
            try UIVerification.require(update.coverage[.depthLimit] > 0, "Mixed depth omission lost its explanation")
        }
        try reconcile(snapshot, report)
        return ["case": name, "repeat": repeatIndex, "observed_entries": snapshot.root.counts.total,
            "input_events_including_gap_notices": snapshot.processedRecords,
            "folders": expectedFolders, "scan_to_prepared_display_seconds": ProcessInfo.processInfo.systemUptime - began,
            "first_observation_seconds": firstProgress as Any? ?? NSNull(), "parent_before": before,
            "parent_after": resources(), "worker_peak_bytes": update.workerPeakResidentBytes as Any? ?? NSNull(),
            "allocated_folder_wrappers": coordinator.toolWindow?.allocatedFolderItemCount ?? -1]
    }

    static func admittedSource(_ name: String) async throws -> URL {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let corpus = repository.appendingPathComponent(".build/b06-analyzer/20261017T140537Z-6faf182f69")
        let root = corpus.appendingPathComponent("fixtures/" + name, isDirectory: true)
        // The exact original generated identity is required before starting.
        return try await Task.detached(priority: .utility) {
            guard ["wide", "mixed"].contains(name), root.standardizedFileURL == root.resolvingSymlinksInPath() else {
                throw UIVerification.Failure(message: "Scale corpus scope was redirected")
            }
            let manifest = corpus.appendingPathComponent("manifests/" + name + ".json")
            let descriptor = open(manifest.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard descriptor >= 0 else { throw UIVerification.Failure(message: "Scale corpus declaration could not be opened") }
            defer { close(descriptor) }
            var before = stat(), after = stat(), bytes = [UInt8](repeating: 0, count: 4097)
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size > 0, before.st_size <= 4096,
                  pread(descriptor, &bytes, bytes.count, 0) == Int(before.st_size),
                  fstat(descriptor, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw UIVerification.Failure(message: "Scale corpus declaration changed or exceeded its bound")
            }
            let data = Data(bytes.prefix(Int(before.st_size)))
            guard let proof = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  proof["root"] as? String == root.path else {
                throw UIVerification.Failure(message: "Scale generated-corpus declaration is missing")
            }
            var metadata = stat()
            guard lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  (proof["dev"] as? NSNumber)?.uint64Value == UInt64(UInt32(bitPattern: metadata.st_dev)),
                  (proof["ino"] as? NSNumber)?.uint64Value == metadata.st_ino else {
                throw UIVerification.Failure(message: "Scale generated-corpus identity changed")
            }
            return root
        }.value
    }

    /// Current-build cancellation/replacement lifecycle under a low cadence.
    /// Only exact existing corpora are read. Each cycle must fully drain before
    /// another begins; this is a retention/race check, not a speed benchmark.
    static func cancellationSoak(seconds: Int) async throws -> [String: Any] {
        try UIVerification.require((120...14_400).contains(seconds), "Unbounded cancellation soak")
        let coordinator = ApplicationStorageAnalysis.shared
        let began = ProcessInfo.processInfo.systemUptime, heartbeat = Heartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeat.tick() }
        }
        defer { timer.invalidate() }
        var cycles = 0, completeChecks = 0, maximumRSS: UInt64 = 0
        var maximumStopSeconds = 0.0
        while ProcessInfo.processInfo.systemUptime - began < Double(seconds) {
            try Task.checkCancellation()
            let cycleBegan = ProcessInfo.processInfo.systemUptime
            let name = cycles % 2 == 0 ? "wide" : "mixed"
            let root = try await admittedSource(name)
            let phase = cycles % 4
            var preparationCalls = 0
            coordinator.verificationBegin(root: root) {
                preparationCalls += 1
                if phase == 2 { try? await Task.sleep(for: .milliseconds(200)) }
                return FileAccessLifetimes(leases: [])
            }
            coordinator.toolWindow?.showWindow(nil)
            switch phase {
            case 0:
                break // Stop while preparation is queued, before a task turn.
            case 1:
                try await UIVerification.waitUntil("Cancellation soak first metadata observation") {
                    (coordinator.updateForVerification?.progress?.processedRecords ?? 0) > 0
                }
            case 2:
                try await UIVerification.waitUntil("Cancellation soak access preparation starts") { preparationCalls == 1 }
            default:
                try await UIVerification.waitUntil("Replacement soak first metadata observation") {
                    (coordinator.updateForVerification?.progress?.processedRecords ?? 0) > 0
                }
                let latest = try await admittedSource("wide")
                coordinator.verificationBegin(root: root) { FileAccessLifetimes(leases: []) }
                coordinator.verificationBegin(root: latest) { FileAccessLifetimes(leases: []) }
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                while coordinator.hasWork {
                    try UIVerification.require(ProcessInfo.processInfo.systemUptime < deadline, "Replacement soak did not settle")
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard coordinator.currentRoot == latest,
                      let update = coordinator.updateForVerification, update.status == .completed,
                      let snapshot = update.snapshot, snapshot.root.counts.total == 100_000,
                      let report = coordinator.attributionForVerification else {
                    throw UIVerification.Failure(message: "Replacement soak accepted a stale scan result")
                }
                try reconcile(snapshot, report)
                completeChecks += 1
            }
            let stopBegan = ProcessInfo.processInfo.systemUptime
            await coordinator.stopAndDrain()
            try await UIVerification.waitUntil("Cancellation soak actual owner drain") {
                !coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0
            }
            maximumStopSeconds = max(maximumStopSeconds, ProcessInfo.processInfo.systemUptime - stopBegan)
            if cycles % 8 == 7 {
                _ = try await actual("mixed", repeatIndex: completeChecks, coordinator: coordinator)
                completeChecks += 1
                await coordinator.stopAndDrain()
            }
            coordinator.toolWindow?.close()
            try UIVerification.requireControlledWindowsHidden("cancellation soak cycle")
            try await Task.sleep(for: .milliseconds(100))
            let rss = resources()["current_rss_bytes"] ?? 0
            try UIVerification.require(rss > 0 && rss < 1_073_741_824,
                "Cancellation soak exceeded its 1 GiB resident safety ceiling")
            maximumRSS = max(maximumRSS, rss); cycles += 1
            if cycles % 4 == 0 {
                print("MAC_EXPLORER_CANCELLATION_SOAK cycles=\(cycles) complete_checks=\(completeChecks) rss_bytes=\(rss)")
                fflush(stdout)
            }
            let remaining = Double(seconds) - (ProcessInfo.processInfo.systemUptime - began)
            let delay = min(max(0, 20 - (ProcessInfo.processInfo.systemUptime - cycleBegan)), max(0, remaining))
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        await coordinator.stopAndDrain(); coordinator.toolWindow?.close(); heartbeat.tick()
        return ["duration_seconds": ProcessInfo.processInfo.systemUptime - began, "cycles": cycles,
            "complete_fixture_checks": completeChecks, "maximum_retained_rss_bytes": maximumRSS,
            "maximum_stop_seconds": maximumStopSeconds, "maximum_main_heartbeat_gap_seconds": heartbeat.maximumGap,
            "scope": "Current signed app: prelaunch, streaming and access-preparation Stop; latest-request replacement; actual drain; read-only generated corpora; concurrent-work timing is descriptive"]
    }

    private static func synthetic(_ name: String) async throws -> [String: Any] {
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        window.showWindow(nil)
        defer { window.close() }
        let began = ProcessInfo.processInfo.systemUptime, before = resources()
        let (snapshot, report) = try await Task.detached(priority: .utility) {
            var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
            let count = name == "folders" ? 220_000 : 110_000
            var identity: UInt64 = 2
            for i in 0..<count {
                try Task.checkCancellation()
                let path = "d\(i)"
                guard model.consume(.init(relativePath: Data(path.utf8), kind: .directory,
                    identity: .returned(.init(device: 1, inode: identity)), linkCount: .returned(1), flags: .returned(0))) == .accepted else {
                    throw UIVerification.Failure(message: "Synthetic folder was refused")
                }
                identity += 1
                if name == "projects" {
                    guard model.consume(.init(relativePath: Data((path + "/Cargo.toml").utf8), kind: .regularFile,
                        identity: .returned(.init(device: 1, inode: identity)), linkCount: .returned(1), flags: .returned(0),
                        bytes: .init(dataLogical: .returned(1), allForkLogical: .returned(1),
                                     dataAllocated: .returned(1), allForkAllocated: .returned(1)))) == .accepted else {
                        throw UIVerification.Failure(message: "Synthetic project marker was refused")
                    }
                    identity += 1
                }
            }
            let snapshot = model.finish()
            return (snapshot, try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated"))
        }.value
        try reconcile(snapshot, report)
        window.showSyntheticForVerification(snapshot, report: report)
        try await UIVerification.waitUntil("Scale synthetic native rows") { !window.isPreparingRows }
        window.window?.contentView?.layoutSubtreeIfNeeded(); window.window?.displayIfNeeded()
        try UIVerification.require(window.preparedFolderCount == (name == "folders" ? 220_001 : 110_001)
            && report.projects.count <= 14 && snapshot.processedRecords == 220_000,
            "Synthetic native hierarchy or compact project bounds changed")
        return ["case": "in-memory-" + name, "records": snapshot.processedRecords,
            "model_to_prepared_display_seconds": ProcessInfo.processInfo.systemUptime - began,
            "parent_before": before, "parent_after": resources(),
            "project_rows": report.projects.count, "folder_wrappers": window.allocatedFolderItemCount]
    }

    private static func reconcile(_ snapshot: StorageAnalysisSnapshot, _ report: AnalysisAttributionReport) throws {
        for metric in AnalysisByteMetric.allCases {
            let categories = report.categories.reduce(UInt64(0)) { $0 + ($1.bytes[metric].knownBytes ?? 0) }
            let projects = report.projects.reduce(UInt64(0)) { $0 + ($1.bytes[metric].knownBytes ?? 0) }
            let types = report.fileTypes.reduce(UInt64(0)) { $0 + ($1.bytes[metric].knownBytes ?? 0) }
            try UIVerification.require(categories == snapshot.root.namespaceSubtotals[metric].knownBytes
                && projects == categories && types == categories, "Scale attribution did not partition observed bytes")
        }
    }

    private static func resources() -> [String: UInt64] {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        var values: [String: UInt64] = [:]
        if result == KERN_SUCCESS { values["current_rss_bytes"] = info.resident_size }
        if usageResult == 0 { values["process_lifetime_peak_bytes"] = UInt64(usage.ru_maxrss) }
        return values
    }
}
#endif
