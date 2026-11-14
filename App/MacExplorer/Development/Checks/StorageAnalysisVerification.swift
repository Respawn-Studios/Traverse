#if DEBUG
import AppKit
import CoreGraphics
import Darwin
import ExplorerCore
import LocalStorage
import StorageAnalysis

/// Generated, metadata-only integration checks. No test path is a personal
/// folder, no file body is read, and failures leave their fixture/evidence intact.
@MainActor
enum StorageAnalysisVerification {
    /// No fixture/output URL and no scanner launch. This can verify reporting
    /// when a separately bounded filesystem experiment has no entry headroom.
    static func reportingMemoryOnly() async throws -> [String] {
        let (snapshot, report) = try await Task.detached(priority: .utility) {
            var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
            func entry(_ name: String, kind: AnalysisEntryKind, inode: UInt64,
                       bytes: AnalysisByteObservation = .init()) -> AnalysisEntryObservation {
                .init(relativePath: Data(name.utf8), kind: kind, identity: .returned(.init(device: 1, inode: inode)),
                    linkCount: .returned(1), flags: .returned(0), bytes: bytes)
            }
            let zero = AnalysisByteObservation(dataLogical: .returned(0), allForkLogical: .returned(0),
                dataAllocated: .returned(0), allForkAllocated: .returned(0))
            model.consume(entry("Cargo.toml", kind: .regularFile, inode: 2, bytes: zero))
            for (name, inode, value) in [("large", UInt64(3), UInt64.max), ("one", UInt64(4), UInt64(1))] {
                model.consume(entry(name, kind: .regularFile, inode: inode,
                    bytes: .init(dataLogical: .returned(value), allForkLogical: .returned(value),
                        dataAllocated: .returned(value), allForkAllocated: .returned(value))))
            }
            model.consume(entry(".cache", kind: .directory, inode: 5))
            model.consume(entry(".cache/unavailable", kind: .regularFile, inode: 6,
                bytes: .init(dataLogical: .notReturned, allForkLogical: .failed(code: 13),
                    dataAllocated: .notReturned, allForkAllocated: .failed(code: 5))))
            let snapshot = model.finish()
            return (snapshot, try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated/Project"))
        }.value
        let direct = report.categories[AnalysisCategory.other.rawValue]
        guard let project = report.projects.first(where: { $0.folder == .root }) else {
            throw UIVerification.Failure(message: "Generated reporting project was unavailable")
        }
        for metric in AnalysisByteMetric.allCases {
            try require(direct.bytes[metric].knownBytes == nil && direct.bytes[metric].overflowed
                && direct.bytes[metric].failedCount == 0 && direct.bytes[metric].notReturnedCount == 0
                && project.bytes[metric].failedCount == 0 && project.bytes[metric].notReturnedCount == 0,
                "Overflow reporting duplicated a disjoint child's metadata gaps")
            let categories = report.categories.reduce(UInt64(0)) { $0 + $1.bytes[metric].notReturnedCount }
            let projects = report.projects.reduce(UInt64(0)) { $0 + $1.bytes[metric].failedCount }
            try require(categories == snapshot.root.namespaceSubtotals[metric].notReturnedCount
                && projects == snapshot.root.namespaceSubtotals[metric].failedCount,
                "Native reporting did not partition support observations")
        }
        let card = FolderSummaryCard(name: "Generated folder")
        card.render(.init(counts: snapshot.root.counts, bytes: AnalysisByteSubtotals(),
                          isRunning: false, isComplete: true, message: "Generated observation", observedAt: Date()))
        let previousCounts = card.valueTextsForVerification.counts
        card.render(.waiting("Automatic summary is unavailable here."))
        try require(card.valueTextsForVerification.size == "Size not calculated"
                    && card.valueTextsForVerification.counts == "No counts available"
                    && card.valueTextsForVerification.counts != previousCounts,
                    "Unavailable hover summary retained stale values or kept claiming to calculate")
        card.render(.init(counts: nil, bytes: nil, isRunning: true, isComplete: false,
                          message: "Preparing another observation", observedAt: Date()))
        try require(card.valueTextsForVerification.size == "Calculating…"
                    && card.valueTextsForVerification.counts == "Reading folder metadata",
                    "Preparing hover summary inherited values from its previous observation")
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        window.showWindow(nil)
        defer { window.close() }
        window.showSyntheticForVerification(snapshot, report: report)
        try await waitRows(window, count: 2)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.window?.displayIfNeeded()
        try require(window.preparedRowsWereOffMain == true && window.allocatedFolderItemCount <= 2,
            "Native reporting eagerly allocated a hierarchy or prepared it on-main")
        try require(window.window?.isVisible == false && !report.isComplete,
            "RAM reporting became visible or declared overflow complete")
        try await reportingLayout(window)
        window.close()
        window.showAttribution(report)
        try require(window.preparedFolderCount == 0 && !window.isPreparingRows,
            "Closed reporting window retained or revived folder preparation")
        try await AnalysisFolderPickerVerification.memoryOnlyProcessing()
        try await rowPreparationLifetime(snapshot: snapshot, report: report)
        try await propertiesPreparingLifetime()
        try await toolPreparingLifetime()
        try await reportingOwnership(snapshot: snapshot, report: report)
        return ["Actual native reporting: disjoint support counts stay exact after byte overflow; all four byte families remain unavailable rather than fabricated",
                "Native hover card: unavailable or preparing updates clear prior counts/sizes; an idle unavailable result never keeps claiming to calculate",
                "RAM snapshot to native lazy folder table/chart: off-main preparation, two folder rows, incomplete state, six Light/Dark size cases, hidden window and idempotent close; no scanner or file/store creation",
                "RAM picker: rapid navigation and close retain the processing slot through actual detached-sort completion; only latest demand starts and stale rows cannot replace it",
                "Native row preparation: one running task plus latest demand; close/reopen and final close retain the owner until actual return and reject stale rows",
                "Properties Stop/restart: a held access callback keeps preparing active and Stop available; close retains actual ownership, drains without launching a worker and leaves activity admission empty",
                "Native analysis preparation: Stop is reachable while access is held; cancellation waits for that owner and launches no scanner afterward",
                "Closed standalone analyzer controllers, windows, content and outlines release after actual row preparation; three RAM observations, no scanner or new file/store"]
    }

    @MainActor private final class WeakReportingViews {
        weak var controller: StorageAnalysisWindowController?
        weak var window: NSWindow?
        weak var content: NSView?
        weak var outline: NSOutlineView?
        var released: Bool { controller == nil && window == nil && content == nil && outline == nil }
    }

    private static func reportingOwnership(snapshot: StorageAnalysisSnapshot, report: AnalysisAttributionReport) async throws {
        for _ in 0..<3 {
            let observed = WeakReportingViews()
            func prepareAndClose() async throws {
                let controller = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
                observed.controller = controller; observed.window = controller.window
                observed.content = controller.window?.contentView; observed.outline = controller.outlineView
                defer { controller.close() }
                controller.showWindow(nil)
                controller.showSyntheticForVerification(snapshot, report: report)
                try await waitRows(controller, count: snapshot.folders.count)
            }
            try await prepareAndClose()
            try await UIVerification.waitUntil("Closed native analysis views release their owners") { observed.released }
        }
    }

    /// Observes current heuristic behavior without declaring it the desired
    /// taxonomy. All paths/observations are synthetic; nothing is opened/read.
    static func attributionAuditMemoryOnly() throws -> [String: Any] {
        func inspect(_ scope: String, _ entries: [(String, AnalysisEntryKind, UInt64)]) throws -> AnalysisAttributionReport {
            var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
            var expected: UInt64 = 0
            for (index, entry) in entries.enumerated() {
                let (path, kind, bytes) = entry
                let values = AnalysisByteObservation(dataLogical: .returned(bytes), allForkLogical: .returned(bytes),
                    dataAllocated: .returned(bytes), allForkAllocated: .returned(bytes))
                guard model.consume(.init(relativePath: Data(path.utf8), kind: kind,
                    identity: .returned(.init(device: 1, inode: UInt64(index + 2))), linkCount: .returned(1),
                    flags: .returned(0), bytes: values)) == .accepted else {
                    throw UIVerification.Failure(message: "Synthetic attribution-audit observation was refused")
                }
                if kind == .regularFile { expected += bytes }
            }
            let snapshot = model.finish()
            let report = try AnalysisAttributionReport.make(snapshot, scopePath: scope)
            for metric in AnalysisByteMetric.allCases {
                try require(snapshot.root.namespaceSubtotals[metric].knownBytes == expected
                            && report.categories.reduce(UInt64(0), { $0 + ($1.bytes[metric].knownBytes ?? 0) }) == expected
                            && report.projects.reduce(UInt64(0), { $0 + ($1.bytes[metric].knownBytes ?? 0) }) == expected,
                            "Synthetic attribution-audit partitions lost observed bytes")
            }
            return report
        }
        func roles(_ report: AnalysisAttributionReport) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: report.categories.compactMap { slice in
                guard let bytes = slice.bytes.dataLogical.knownBytes, bytes > 0 else { return nil }
                return (slice.title, bytes)
            })
        }
        let parent = try inspect("/Generated/Library/Caches", [
            ("huggingface", .directory, 0), ("huggingface/weights.bin", .regularFile, 7)])
        let child = try inspect("/Generated/Library/Caches/huggingface", [("weights.bin", .regularFile, 7)])
        let gitDirectory = try inspect("/Generated/Repository", [(".git", .directory, 0), ("ordinary.bin", .regularFile, 7)])
        let gitFile = try inspect("/Generated/Repository", [(".git", .regularFile, 0), ("ordinary.bin", .regularFile, 7)])
        let npm = try inspect("/Generated/.npm/_cacache", [("opaque.bin", .regularFile, 7)])
        let generated = try inspect("/Generated/Project", [("Cargo.toml", .regularFile, 0), ("build", .directory, 0),
            ("build/package.json", .regularFile, 0), ("build/ordinary.bin", .regularFile, 7)])
        return ["scope": "Synthetic metadata only; current heuristic observations, not desired-rule assertions or adoption",
            "parent_cache_roles": roles(parent), "selected_child_cache_roles": roles(child),
            "scope_dependent_roles_observed": roles(parent) != roles(child),
            "git_directory_project_count": gitDirectory.projectCount, "git_file_project_count": gitFile.projectCount,
            "npm_cache_roles": roles(npm), "generated_build_marker_project_count": generated.projectCount,
            "four_metric_partitions_reconcile": true, "file_body_or_config_read": false, "new_files_or_stores": false]
    }

    private static func reportingLayout(_ controller: StorageAnalysisWindowController) async throws {
        guard let window = controller.window, let content = window.contentView,
              let listing = controller.outlineView.enclosingScrollView,
              let actions = controller.stopButton.superview else {
            throw UIVerification.Failure(message: "Native reporting layout surfaces are missing")
        }
        let originalFrame = window.frame, originalAppearance = window.appearance
        defer { window.appearance = originalAppearance; window.setFrame(originalFrame, display: false) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 740, height: 480), NSSize(width: 960, height: 650), NSSize(width: 1280, height: 800)] {
                window.setFrame(NSRect(origin: originalFrame.origin, size: size), display: false)
                await Task.yield()
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try require(abs(window.frame.width - size.width) <= 1 && abs(window.frame.height - size.height) <= 1,
                            "Native reporting did not retain its requested layout size")
                for view in [actions, controller.statusLabel, controller.summaryLabel, controller.progressLabel, listing] {
                    let rect = view.convert(view.bounds, to: content)
                    try require(rect.width > 0 && rect.height > 0
                                && rect.minX >= -1 && rect.minY >= -1
                                && rect.maxX <= content.bounds.maxX + 1 && rect.maxY <= content.bounds.maxY + 1,
                                "Native reporting actions, text or listing escaped its minimum-size content")
                }
                try require(listing.bounds.height >= 89
                            && controller.summaryLabel.fittingSize.height <= controller.summaryLabel.bounds.height + 1,
                            "Native reporting clipped its summary or lost the minimum folder viewport")
            }
        }
    }

    private struct Fixture: Sendable {
        let owned: URL
        let scope: URL
        let partial: URL
        let deep: URL
        let regularEdges: [URL]
    }

    private struct Oracle: Sendable {
        let namespaceLogical: UInt64
        let namespaceAllocated: UInt64
        let objectLogical: UInt64
        let objectAllocated: UInt64
        let objects: Int
    }

    private final class Observation {
        var last: StorageScanUpdate?
        var ended = false
        var updates = 0
    }

    private final class AccessFactoryToken {}
    private final class StopSessionOwner { var session: StorageScanSession? }
    private final class PropertiesAccessCounter { var calls = 0 }
    private final class ProjectionLatch: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var entered = false
        private var finished = false
        private var calls = 0
        var invocationCount: Int { lock.withLock { calls } }
        var isWaiting: Bool { lock.withLock { entered && !finished } }
        var hasFinished: Bool { lock.withLock { finished } }
        func wait() throws {
            lock.withLock { entered = true }
            defer { lock.withLock { finished = true } }
            guard gate.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            try Task.checkCancellation()
        }
        func release() { gate.signal() }
        func holdFirst() throws {
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first { try wait() }
            else { try Task.checkCancellation() }
        }
    }

    private static func rowPreparationLifetime(snapshot: StorageAnalysisSnapshot,
                                                report: AnalysisAttributionReport) async throws {
        let latch = ProjectionLatch()
        var stopRequests = 0
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: { stopRequests += 1 }, onAppStorage: {})
        window.rowPreparationHookForVerification = { try latch.holdFirst() }
        defer { latch.release(); window.close() }
        window.showWindow(nil)
        window.showSyntheticForVerification(snapshot, report: report)
        try await UIVerification.waitUntil("Native row preparation is actually running") { latch.isWaiting }
        for _ in 0..<4 {
            window.showSyntheticForVerification(snapshot, report: report)
            try await Task.sleep(for: .milliseconds(20))
        }
        window.close()
        try require(!window.rowWorkIsDrainedForVerification && window.preparedFolderCount == 0,
            "Closing the native analysis window abandoned its processing owner")
        window.showWindow(nil)
        window.showSyntheticForVerification(snapshot, report: report)
        let bounded = latch.invocationCount == 1 && window.isPreparingRows
        latch.release()
        try await waitRows(window, count: snapshot.folders.count)
        try require(bounded && latch.invocationCount == 2,
            "Native analysis admitted overlapping row preparation before cancelled work actually returned")
        window.close()
        let closingLatch = ProjectionLatch()
        window.rowPreparationHookForVerification = { try closingLatch.holdFirst() }
        defer { closingLatch.release() }
        window.showWindow(nil)
        window.showSyntheticForVerification(snapshot, report: report)
        try await UIVerification.waitUntil("Native row preparation close control is held") { closingLatch.isWaiting }
        window.close()
        let retainedOwner = !window.rowWorkIsDrainedForVerification
        closingLatch.release()
        try await UIVerification.waitUntil("Closed native row preparation actually drains") { window.rowWorkIsDrainedForVerification }
        try require(retainedOwner && window.isClosed && window.preparedFolderCount == 0 && !window.isPreparingRows,
            "Closed native row preparation published late results or lost actual work ownership")
        let stoppingLatch = ProjectionLatch()
        defer { stoppingLatch.release(); window.close() }
        window.rowPreparationHookForVerification = { try stoppingLatch.holdFirst() }
        window.showWindow(nil)
        window.showSyntheticForVerification(snapshot, report: report)
        try await UIVerification.waitUntil("Native post-scan row work is held for Stop") { stoppingLatch.isWaiting }
        let offeredStop = window.stopButton.isEnabled
        window.stopButton.performClick(nil)
        let stopped = stopRequests == 1 && !window.isPreparingRows && !window.rowWorkIsDrainedForVerification
        stoppingLatch.release()
        try await UIVerification.waitUntil("Stopped native post-scan row work actually returns") { window.rowWorkIsDrainedForVerification }
        try require(offeredStop && stopped && window.preparedFolderCount == 0,
                    "Native Stop was unavailable or ignored after scanning while folder rows still prepared")
    }

    private struct MemoryPropertiesReader: FilePropertiesReading {
        func read(_ urls: [URL]) async throws -> FilePropertiesReport {
            try Task.checkCancellation()
            return FilePropertiesReport(selectedCount: urls.count, observations: urls.prefix(1).map { root in
                FilePropertyObservation(id: 0, url: root, kind: "Folder", byteCount: nil,
                    createdAt: nil, modifiedAt: nil, accessedAt: nil, mode: 0o700,
                    ownerID: nil, groupID: nil, isSymbolicLink: false, isDirectory: true,
                    isImmutable: false, isVolumeReadOnly: false, failure: nil)
            })
        }
    }

    /// Real model/coordinator callbacks, but a RAM-only metadata reader and an
    /// access callback held before scanner admission. No path is opened.
    private static func propertiesPreparingLifetime() async throws {
        let coordinator = ApplicationStorageAnalysis.shared
        await coordinator.stopAndDrain()
        var pending: CheckedContinuation<(any Sendable)?, Never>?
        var accessBegan = false
        let model = FilePropertiesModel(reader: MemoryPropertiesReader(), analysisAccess: { _ in
            accessBegan = true
            return await withCheckedContinuation { pending = $0 }
        }, copyPaths: { _ in })
        defer { model.cancel(); pending?.resume(returning: nil) }
        model.update(urls: [URL(fileURLWithPath: "/Generated/PropertiesPreparingOnly", isDirectory: true)])
        try await UIVerification.waitUntil("RAM Properties metadata") { !model.isLoading }
        try require(model.canAnalyzeStorage, "RAM Properties directory action is unavailable")
        model.analyzeStorage()
        try await UIVerification.waitUntil("RAM Properties preparation is actually held") { accessBegan }
        model.stopAnalysis()
        model.openFullAnalysis()
        let unavailableFeedback = model.analysisValue?.message.contains("Choose Analyze Again") == true
        model.analyzeStorage()
        let reportedRunning = model.analysisValue?.isRunning == true
        model.cancel()
        let heldOwner = coordinator.hasWork && coordinator.activeSession == nil
        pending?.resume(returning: nil); pending = nil
        await coordinator.stopAndDrain()
        try require(unavailableFeedback, "Cancelled Properties analysis silently opened an empty Full Analysis view")
        try require(reportedRunning && heldOwner && !coordinator.hasWork
                    && coordinator.activeSession == nil && ApplicationFileActivity.gate.activeCount == 0,
                    "Repeated Properties preparation hid Stop or discarded its held access owner")
    }

    /// No root is opened: admission is held before scanner launch, then actual
    /// drain invalidates the generation before the empty access value returns.
    private static func toolPreparingLifetime() async throws {
        let coordinator = ApplicationStorageAnalysis.shared
        for handoff in [false, true] {
            await coordinator.stopAndDrain()
            let root = URL(fileURLWithPath: "/Generated/ToolPreparingOnly", isDirectory: true)
            let owner = UUID()
            var pending: CheckedContinuation<FileAccessLifetimes, Never>?
            var accessCalls = 0
            let access: @MainActor () async -> FileAccessLifetimes = {
                accessCalls += 1
                return await withCheckedContinuation { pending = $0 }
            }
            if handoff {
                coordinator.analyzeProperties(owner: owner, root: root, access: access, onChange: { _, _ in })
            } else { coordinator.verificationBegin(root: root, access: access) }
            guard let window = coordinator.toolWindow else { throw UIVerification.Failure(message: "Native preparing window is unavailable") }
            defer { pending?.resume(returning: FileAccessLifetimes(leases: [])); window.close() }
            window.showWindow(nil)
            try await UIVerification.waitUntil("Native tool access preparation is held") { accessCalls == 1 }
            var refusedUnrelatedRoot = true
            if handoff {
                refusedUnrelatedRoot = !coordinator.openFullAnalysis(owner: owner,
                    root: URL(fileURLWithPath: "/Generated/UnrelatedToolRoot", isDirectory: true))
                try require(coordinator.openFullAnalysis(owner: owner, root: root),
                            "Properties handoff lost its pending preparation")
            }
            let offeredStop = window.stopButton.isEnabled
                && window.statusLabel.stringValue.contains("Getting ready")
            window.stopButton.performClick(nil)
            let stopped = window.statusLabel.stringValue.contains("cancelled before it started")
                && !window.stopButton.isEnabled && coordinator.hasWork && coordinator.activeSession == nil
            let refusedEmptyHandoff = !coordinator.openFullAnalysis(owner: owner, root: root)
            var drained = false
            let drain = Task { @MainActor in await coordinator.stopAndDrain(); drained = true }
            try await Task.sleep(for: .milliseconds(30))
            let waited = !drained
            pending?.resume(returning: FileAccessLifetimes(leases: [])); pending = nil
            await drain.value
            try require(refusedUnrelatedRoot && offeredStop && stopped && refusedEmptyHandoff && waited && accessCalls == 1 && !coordinator.hasWork
                        && coordinator.activeSession == nil && ApplicationFileActivity.gate.activeCount == 0,
                        "Native preparation Stop lost its owner or accepted a cancelled handoff with no result")
        }
    }

    /// The delayed chooser control supplies no security grant and performs no
    /// native permission query. Its selected URL is still a generated fixture.
    private final class ChooserBackend: FolderAccessBackend, @unchecked Sendable {
        func startAccess(to url: URL) -> Bool { false }
        func stopAccess(to url: URL) {}
        func bookmark(for url: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw CocoaError(.fileReadNoPermission) }
    }

    static func run(browser: BrowserViewController, fixture: URL, output: URL,
                    interactive: Bool) async throws -> [String] {
        guard browser.isVerificationSession,
              let declaration = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
            throw UIVerification.Failure(message: "Analysis checks require the generated verification session")
        }
        let declared = URL(fileURLWithPath: declaration, isDirectory: true).standardizedFileURL
        let original = fixture.standardizedFileURL
        let buildRoot = original.deletingLastPathComponent().deletingLastPathComponent()
        try require(original.deletingLastPathComponent().lastPathComponent == "fixtures"
                    && buildRoot.lastPathComponent == ".build"
                    && declared.path.hasPrefix(buildRoot.path + "/")
                    && output.path.hasPrefix(buildRoot.appendingPathComponent("evidence").path + "/"),
                    "Analysis fixture and evidence must remain in this repository's ignored build ownership")
        let coordinator = ApplicationStorageAnalysis.shared
        try require(!coordinator.hasWork, "An existing analysis consumer owns the scanner")
        // Frozen legacy/hover/App Storage lifetime regressions. The ordinary
        // paged route has its separate signed current-worker contract controls.
        coordinator.useLegacyReferenceForQualification()
        try require(declared == declared.resolvingSymlinksInPath().standardizedFileURL,
                    "Analysis fixture parent is redirected")
        try require(output.standardizedFileURL == output.resolvingSymlinksInPath().standardizedFileURL,
                    "Analysis evidence parent is redirected")
        // The listing fixture is separately owned by UIVerification. Adding a
        // child to it would invalidate the original immutable-fixture check.
        try require(declared.path != original.path && !declared.path.hasPrefix(original.path + "/"),
                    "Analysis scratch must be outside the original listing fixture")
        let stamp = UUID().uuidString
        let owned = declared.appendingPathComponent("analysis-" + stamp, isDirectory: true)
        let originalBefore = try await Task.detached { try UIVerification.fixtureSnapshot(original) }.value
        let reused = ProcessInfo.processInfo.environment["MAC_EXPLORER_ANALYSIS_REUSE"]
        let generated = try await Task.detached {
            if let reused { return try loadFixture(URL(fileURLWithPath: reused), parent: declared) }
            return try makeFixture(owned)
        }.value
        let before = try await Task.detached { try UIVerification.fixtureSnapshot(generated.owned) }.value
        try require(before.count <= 180, "Analysis fixture exceeded its small entry projection")
        let expected = try await Task.detached { try oracle(generated.regularEdges) }.value
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
        let gate = FileActivityGate()
        let scanner = StorageScanner(workerURL: worker, activityGate: gate)
        var checks = try await StorageScopePreferenceVerification.run()
        // That memory-only preference check temporarily binds its own live
        // Properties settings. Restore this flow's owner before any scan.
        coordinator.configureScopePreferences(browser.settings)
        var notExercised = ["TCC prompts or protected-folder consent", "Human folder-picker/bookmark grants",
                            "Physical pointer/keyboard delivery", "Personal or provider roots",
                            "Concurrent worker/UI maximum-memory envelope"]
        var captures: [URL] = []
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        defer { window.close(); browser.folderSummary.cancel() }
        do {
            let complete = try await scan(scanner, root: generated.scope)
            guard complete.status == .completed, let snapshot = complete.snapshot else {
                throw UIVerification.Failure(message: "Bundled helper did not produce a complete generated observation: \(complete.status)")
            }
            try require(complete.workerDrained && snapshot.isComplete && gate.activeCount == 0,
                        "Complete publication did not drain the actual session")
            try require(snapshot.root.counts.regularFiles == 83 && snapshot.root.counts.directories == 5
                        && snapshot.root.counts.symbolicLinks == 1 && snapshot.root.counts.total == 89,
                        "Bundled helper followed a link, skipped package contents or miscounted the fixture")
            try require(snapshot.distinctObjects.knownObjectCount == UInt64(expected.objects)
                        && expected.objects == 82 && snapshot.distinctObjects.observedCrossFolderHardlinkObjects == 1,
                        "Global hardlink accounting disagreed with independent generated identities")
            for metric in AnalysisByteMetric.allCases {
                let logical = metric == .dataLogical || metric == .allForkLogical
                try require(snapshot.root.namespaceSubtotals[metric].knownBytes
                            == (logical ? expected.namespaceLogical : expected.namespaceAllocated),
                            "Namespace byte family disagreed with independent no-follow metadata")
                try require(snapshot.distinctObjects.byteSubtotals[metric].knownBytes
                            == (logical ? expected.objectLogical : expected.objectAllocated),
                            "Object byte family disagreed with independent no-follow metadata")
            }
            checks.append("Actual bundled helper/session: 89 namespace edges, 83 regular names, 82 objects, package descendants, a cross-folder hardlink and an unfollowed outside symlink; all four metrics match independent lstat metadata")

            window.showWindow(nil)
            if !interactive { try UIVerification.requireControlledWindowsHidden("analysis window construction") }
            window.render(root: generated.scope, update: complete)
            try await waitRows(window, count: 6)
            try require(window.preparedRowsWereOffMain == true, "Actual folder-row construction ran on the main thread")
            try require(window.statusLabel.stringValue == "Scan complete",
                        "Completed window did not show the completed scan status")
            try require(!window.stopButton.isEnabled, "Completed window retained an enabled Stop action")
            try require((window.window?.contentView?.bounds.width ?? 0) >= 740,
                        "Analysis window shrank below its native minimum width")
            let oldSort = window.outlineView.sortDescriptors
            window.outlineView.sortDescriptors = [NSSortDescriptor(key: "files", ascending: true)]
            try await waitRows(window, count: 6)
            try require(childNames(window) == ["Empty", "Package.app", "Alpha", "Beta"],
                        "Real outline sort did not use folder namespace file counts")
            try require(oldSort.first?.key == "logical", "Initial observed folder sort changed unexpectedly")
            let completeCapture = output.appendingPathComponent("analysis-" + stamp + "-complete.png")
            try await UIVerification.snapshot(window.window!, to: completeCapture)
            captures.append(completeCapture)
            checks.append("Nonmodal window renders actual completed metadata; folder rows prepare off-main and real outline sorting orders 0/1/40/40 files")

            let partial = try await scan(scanner, root: generated.partial)
            try require(partial.status == .partial && partial.workerDrained && partial.snapshot?.isComplete == false
                        && partial.snapshot?.root.counts.regularFiles == 1
                        && partial.snapshot?.root.counts.directories == 1
                        && partial.coverage[.policyExclusion] == 1
                        && partial.coverage.omittedDetails == 0,
                        "Actual generated policy exclusion lost partial coverage or enumerated its child")
            window.render(root: generated.scope, update: complete)
            window.render(root: generated.partial, update: partial)
            try await waitRows(window, count: 2)
            try require(window.scopeLabel.stringValue == generated.partial.path
                        && window.statusLabel.stringValue == "Some items weren’t included"
                        && !window.coverageButton.isHidden
                        && window.summaryLabel.stringValue.contains(FileSizeText.string(0)),
                        "Stale completed rows replaced the real partial zero-byte observation")
            try verifyMetricFormatting(window)
            let partialCapture = output.appendingPathComponent("analysis-" + stamp + "-partial.png")
            try await UIVerification.snapshot(window.window!, to: partialCapture)
            captures.append(partialCapture)
            checks.append("Actual excluded generated credential subtree stays partial; returned zero stays numeric; pure-derived missing/mixed/overflow subtotals render Unknown/Known/Unavailable")

            let deep = try await scan(scanner, root: generated.deep)
            try require(deep.status == .partial && deep.workerDrained && deep.snapshot?.rejectedRecords == 0
                        && deep.snapshot?.root.counts.directories == 64 && deep.snapshot?.root.counts.regularFiles == 0
                        && deep.snapshot?.issues.contains(where: { $0.code == .coverage(.truncated) }) == true,
                        "Signed worker and consumer disagree on the 64-component boundary")
            checks.append("Signed helper depth regression: boundary directory metadata is retained; component-65 filename is not emitted; public session reports truncated partial coverage without invalid output")

            window.render(root: generated.scope, update: complete)
            window.close()
            let closedGeneration = window.renderGeneration
            window.render(root: generated.partial, update: partial)
            try await Task.sleep(for: .milliseconds(120))
            try require(window.isClosed && !window.isPreparingRows && window.preparedFolderCount == 0
                        && window.renderGeneration == closedGeneration,
                        "Close accepted a late row preparation or render")
            window.showWindow(nil)
            window.render(root: generated.partial, update: partial)
            try await waitRows(window, count: 2)
            checks.append("Close invalidates real row preparation and rejects late publication; reopening accepts a fresh observed snapshot")

            checks += try await verifyStop(scanner, gate: gate, scope: generated.scope)
            checks += try await verifyPreparation(coordinator, generated: generated)
            checks += try await verifyChooserAndAdmission(coordinator, generated: generated)
            checks += try await verifyShutdownAdmission(coordinator, generated: generated)
            checks += try verifySummaryPreferences()
            checks += try await AnalysisFolderPickerVerification.run(root: generated.owned, output: output)
            checks += try await verifyAppStorage(coordinator, generated: generated, restoring: browser.settings)
            let propertiesCapture = output.appendingPathComponent("analysis-" + stamp + "-properties.png")
            let fullCapture = output.appendingPathComponent("analysis-" + stamp + "-breakdown.png")
            checks += try await verifyProperties(coordinator, generated: generated, settings: browser.settings, interactive: interactive,
                propertiesCapture: propertiesCapture, fullCapture: fullCapture)
            captures += [propertiesCapture, fullCapture]
            let hoverCapture = output.appendingPathComponent("analysis-" + stamp + "-hover.png")
            checks += try await verifyHoverAndKeys(browser, scope: generated.scope, tool: window,
                                                   interactive: interactive, capture: hoverCapture)
            if interactive { captures.append(hoverCapture) }
            if !interactive { notExercised.append("Independent enabled-hover dwell while the browser is a key window") }
            await coordinator.stopAndDrain()
            coordinator.toolWindow?.close()
            window.close()
            if ProcessInfo.processInfo.environment["MAC_EXPLORER_ANALYSIS_SCALE"] == "1" {
                checks += try await StorageAnalysisScaleVerification.run(coordinator: coordinator, output: output)
            }
            if !interactive { try UIVerification.requireControlledWindowsHidden("analysis checks complete") }
            let after = try await Task.detached { try UIVerification.fixtureSnapshot(generated.owned) }.value
            let originalAfter = try await Task.detached { try UIVerification.fixtureSnapshot(original) }.value
            try require(before == after && originalBefore == originalAfter,
                        "Metadata analysis changed a generated or original fixture")
            let captureURLs = captures
            let captureBytes = try await Task.detached {
                try captureURLs.reduce(Int64(0)) { total, url in
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    return total + Int64(size)
                }
            }.value
            try require(captureBytes <= 4 << 20, "Analysis capture projection exceeded; evidence preserved")
            checks.append("Generated and original fixture structure, sizes, modes and modification times remain unchanged; failed cases are never cleaned")
            let report: [String: Any] = ["passed": true, "checks": checks, "notExercised": notExercised,
                "generatedRoot": generated.owned.path, "reusedGeneratedFixture": reused != nil,
                "generatedEntriesIncludingRoot": before.count,
                "fixtureDataProjectionBytes": 4096, "captureProjectionBytes": 4 << 20,
                "captureBytes": captureBytes, "worker": worker.path,
                "scope": "Generated metadata-only Debug app/helper integration; no TCC or real-root qualification"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("analysis-" + stamp + ".json"), options: .withoutOverwriting)
            return checks
        } catch {
            await coordinator.stopAndDrain()
            coordinator.toolWindow?.close()
            throw error
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        try UIVerification.require(condition, message)
    }

    nonisolated private static func makeFixture(_ owned: URL) throws -> Fixture {
        let manager = FileManager()
        try manager.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("mac-explorer-analysis-fixture-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        let scope = owned.appendingPathComponent("scope", isDirectory: true)
        let partial = owned.appendingPathComponent("partial", isDirectory: true)
        let deep = owned.appendingPathComponent("deep", isDirectory: true)
        for path in [scope, scope.appendingPathComponent("Alpha"), scope.appendingPathComponent("Beta"),
                     scope.appendingPathComponent("Package.app"), scope.appendingPathComponent("Package.app/Contents"),
                     scope.appendingPathComponent("Empty"), owned.appendingPathComponent("outside"), partial,
                     partial.appendingPathComponent(".ssh")] {
            try manager.createDirectory(at: path, withIntermediateDirectories: false)
        }
        var regular: [URL] = []
        for index in 0..<80 {
            let file = scope.appendingPathComponent(index < 40 ? "Alpha/f\(index)" : "Beta/f\(index)")
            try Data(repeating: UInt8(index), count: index % 17 + 1).write(to: file, options: .withoutOverwriting)
            regular.append(file)
        }
        for (path, length) in [("zero", 0), ("Package.app/Contents/payload", 37)] {
            let file = scope.appendingPathComponent(path)
            try Data(repeating: 7, count: length).write(to: file, options: .withoutOverwriting)
            regular.append(file)
        }
        let linked = scope.appendingPathComponent("hardlink")
        try manager.linkItem(at: regular[0], to: linked)
        regular.append(linked)
        try Data(repeating: 9, count: 128).write(to: owned.appendingPathComponent("outside/unobserved"), options: .withoutOverwriting)
        try manager.createSymbolicLink(atPath: scope.appendingPathComponent("outside-link").path,
                                       withDestinationPath: "../outside")
        try Data().write(to: partial.appendingPathComponent("zero"), options: .withoutOverwriting)
        try Data(repeating: 4, count: 13).write(to: partial.appendingPathComponent(".ssh/not-enumerated"), options: .withoutOverwriting)
        try manager.createDirectory(at: deep, withIntermediateDirectories: false)
        var leaf = deep
        for _ in 0..<64 { leaf.appendPathComponent("d"); try manager.createDirectory(at: leaf, withIntermediateDirectories: false) }
        try Data().write(to: leaf.appendingPathComponent("beyond-component-limit"), options: .withoutOverwriting)
        return Fixture(owned: owned, scope: scope, partial: partial, deep: deep, regularEdges: regular)
    }

    nonisolated private static func loadFixture(_ root: URL, parent: URL) throws -> Fixture {
        let prefix = "analysis-"
        guard root.deletingLastPathComponent() == parent, root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              root == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Reused analysis fixture ownership or root redirection refused")
        }
        let marker = root.appendingPathComponent(".fixture-owner")
        var info = stat()
        let expected = Data("mac-explorer-analysis-fixture-v1".utf8)
        guard lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == expected.count, try Data(contentsOf: marker) == expected else {
            throw UIVerification.Failure(message: "Reused generated analysis marker refused")
        }
        let scope = root.appendingPathComponent("scope", isDirectory: true)
        var regular = (0..<80).map { scope.appendingPathComponent($0 < 40 ? "Alpha/f\($0)" : "Beta/f\($0)") }
        regular += [scope.appendingPathComponent("zero"), scope.appendingPathComponent("Package.app/Contents/payload"),
                    scope.appendingPathComponent("hardlink")]
        return Fixture(owned: root, scope: scope, partial: root.appendingPathComponent("partial", isDirectory: true),
            deep: root.appendingPathComponent("deep", isDirectory: true), regularEdges: regular)
    }

    nonisolated private static func oracle(_ edges: [URL]) throws -> Oracle {
        var namespaceLogical: UInt64 = 0, namespaceAllocated: UInt64 = 0
        var objectLogical: UInt64 = 0, objectAllocated: UInt64 = 0
        var identities = Set<AnalysisObjectIdentity>()
        for url in edges {
            var observed = stat()
            guard lstat(url.path, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
                  observed.st_size >= 0, observed.st_blocks >= 0 else {
                throw UIVerification.Failure(message: "Generated regular-file oracle metadata unavailable")
            }
            let logical = UInt64(observed.st_size), allocated = UInt64(observed.st_blocks) * 512
            namespaceLogical += logical; namespaceAllocated += allocated
            if identities.insert(.init(device: UInt64(UInt32(bitPattern: observed.st_dev)), inode: observed.st_ino)).inserted {
                objectLogical += logical; objectAllocated += allocated
            }
        }
        return Oracle(namespaceLogical: namespaceLogical, namespaceAllocated: namespaceAllocated,
                      objectLogical: objectLogical, objectAllocated: objectAllocated, objects: identities.count)
    }

    private static func scan(_ scanner: StorageScanner, root: URL,
                             onUpdate: ((StorageScanUpdate) -> Void)? = nil) async throws -> StorageScanUpdate {
        let session = try scanner.start(root: root, retainingAccess: FileAccessLifetimes(leases: []))
        return try await consume(session, onUpdate: onUpdate)
    }

    private static func consume(_ session: StorageScanSession,
                                onUpdate: ((StorageScanUpdate) -> Void)? = nil) async throws -> StorageScanUpdate {
        let observation = Observation()
        let collector = Task { @MainActor in
            for await update in session.updates {
                observation.last = update; observation.updates += 1; onUpdate?(update)
            }
            observation.ended = true
        }
        do {
            try await UIVerification.waitUntil("Analysis session EOF and reaping") { observation.ended }
            await session.waitUntilDrained()
            await collector.value
            guard let result = observation.last, result.session == session.id, result.workerDrained else {
                throw UIVerification.Failure(message: "Analysis stream ended without its own drained result")
            }
            return result
        } catch {
            session.cancel(); await session.waitUntilDrained(); await collector.value
            throw error
        }
    }

    private static func waitRows(_ window: StorageAnalysisWindowController, count: Int) async throws {
        try await UIVerification.waitUntil("Observed folder rows") {
            !window.isPreparingRows && window.preparedFolderCount == count
        }
    }

    private static func childNames(_ window: StorageAnalysisWindowController) -> [String] {
        let outline = window.outlineView
        let root = window.outlineView(outline, child: 0, ofItem: nil)
        guard let column = outline.tableColumns.first else { return [] }
        return (0..<window.outlineView(outline, numberOfChildrenOfItem: root)).compactMap { index in
            let item = window.outlineView(outline, child: index, ofItem: root)
            return (window.outlineView(outline, viewFor: column, item: item) as? NSTableCellView)?.textField?.stringValue
        }
    }

    private static func verifyMetricFormatting(_ window: StorageAnalysisWindowController) throws {
        func subtotal(_ observations: [AnalysisMetadata<UInt64>]) -> AnalysisMetricSubtotal {
            var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
            for (index, value) in observations.enumerated() {
                model.consume(.init(relativePath: Data("f\(index)".utf8), kind: .regularFile,
                    identity: .returned(.init(device: 1, inode: UInt64(index + 2))), linkCount: .returned(1),
                    flags: .returned(0), bytes: .init(dataLogical: value)))
            }
            return model.finish().root.namespaceSubtotals.dataLogical
        }
        try require(window.metricText(subtotal([.returned(0)]), observedRegularFiles: 1) == FileSizeText.string(0), "Returned zero became unknown")
        try require(window.metricText(subtotal([.notReturned]), observedRegularFiles: 1) == "Unknown", "Entirely missing metadata became zero")
        try require(window.metricText(subtotal([.returned(0), .failed(code: 13)]), observedRegularFiles: 2).hasPrefix("Known "), "Mixed support lost its subtotal qualification")
        try require(window.metricText(subtotal([.returned(UInt64.max), .returned(1)]), observedRegularFiles: 2) == "Unavailable", "Overflow became a numeric size")
    }

    private static func verifyStop(_ scanner: StorageScanner, gate: FileActivityGate, scope: URL) async throws -> [String] {
        var clicks = 0
        let owner = StopSessionOwner()
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {
            clicks += 1; owner.session?.cancel()
        }, onAppStorage: {})
        defer { owner.session?.cancel(); window.close() }
        window.showWindow(nil)
        // Product presentation exists before worker admission. Constructing an
        // AppKit window after starting this tiny fixture would delay collection
        // long enough to hide every legitimate in-flight update.
        let session = try scanner.start(root: scope, retainingAccess: FileAccessLifetimes(leases: []))
        owner.session = session
        let terminal = try await consume(session) { update in
            window.render(root: scope, update: update)
            if clicks == 0 && !update.workerDrained && window.stopButton.isEnabled { window.stopButton.performClick(nil) }
        }
        try require(gate.activeCount == 0 && terminal.workerDrained && !window.stopButton.isEnabled,
                    "Stop/EOF released UI before actual session drain")
        owner.session = nil
        let cancelled = try scanner.start(root: scope, retainingAccess: FileAccessLifetimes(leases: []))
        cancelled.cancel()
        let cancelledResult = try await consume(cancelled)
        try require(cancelledResult.workerDrained && gate.activeCount == 0,
                    "Immediate cancellation retained an actual child/activity lease")
        return [clicks == 1
            ? "Real streamed in-flight update enabled native Stop; its action requested cancellation of the same session and actual drain released its activity lease"
            : "Tiny helper completed before an in-flight Stop frame was delivered: native Stop transition unexercised; actual immediate cancellation and drain still passed"]
    }

    private static func verifyPreparation(_ coordinator: ApplicationStorageAnalysis, generated: Fixture) async throws -> [String] {
        var pending: CheckedContinuation<FileAccessLifetimes, Never>?
        var began = false
        defer { pending?.resume(returning: FileAccessLifetimes(leases: [])) }
        coordinator.verificationBegin(root: generated.scope) {
            began = true
            return await withCheckedContinuation { pending = $0 }
        }
        try await UIVerification.waitUntil("Controlled access preparation") { began }
        coordinator.verificationBegin(root: generated.partial) { FileAccessLifetimes(leases: []) }
        pending?.resume(returning: FileAccessLifetimes(leases: [])); pending = nil
        try await UIVerification.waitUntil("Latest explicit analysis request") {
            !coordinator.hasWork && coordinator.currentRoot == generated.partial
                && coordinator.toolWindow?.preparedFolderCount == 2 && coordinator.toolWindow?.isPreparingRows == false
        }
        try require(coordinator.toolWindow?.scopeLabel.stringValue == generated.partial.path
                    && coordinator.updateForVerification?.status == .partial
                    && coordinator.toolWindow?.statusLabel.stringValue == "Some items weren’t included",
                    "Stale access preparation replaced the newest actual request: scope=\(coordinator.toolWindow?.scopeLabel.stringValue == generated.partial.path), status=\(String(describing: coordinator.updateForVerification?.status)), label=\(coordinator.toolWindow?.statusLabel.stringValue ?? "missing")")
        began = false
        coordinator.verificationBegin(root: generated.scope) {
            began = true
            return await withCheckedContinuation { pending = $0 }
        }
        try await UIVerification.waitUntil("Close during access preparation") { began }
        coordinator.toolWindow?.close()
        pending?.resume(returning: FileAccessLifetimes(leases: [])); pending = nil
        try await UIVerification.waitUntil("Closed analysis preparation drains") { !coordinator.hasWork }
        try require(coordinator.activeSession == nil && coordinator.toolWindow?.isClosed == true,
                    "Closing during access preparation launched a stale worker")
        return ["Actual coordinator pump supersedes suspended access preparation with the newest root; closing during preparation invalidates it without launching a stale worker"]
    }

    private static func verifyHoverAndKeys(_ browser: BrowserViewController, scope: URL,
                                           tool: StorageAnalysisWindowController, interactive: Bool,
                                           capture: URL) async throws -> [String] {
        let enabled = browser.settings.folderSummariesEnabled, delay = browser.settings.folderSummaryDelay
        let mode = browser.effectiveViewMode, background = browser.permitsBackgroundVerification
        defer {
            browser.folderSummary.cancel()
            browser.settings.folderSummariesEnabled = enabled; browser.settings.folderSummaryDelay = delay
            browser.setPaneViewMode(mode); browser.permitsBackgroundVerification = background
        }
        browser.setPaneViewMode(.details)
        browser.navigate(to: .directory(scope)); try await UIVerification.settled(browser)
        let alpha = scope.appendingPathComponent("Alpha", isDirectory: true)
        guard let row = browser.rowsByURL[alpha], let entry = browser.displayedEntries.first(where: { $0.url == alpha }) else {
            throw UIVerification.Failure(message: "Generated hover row unavailable")
        }
        browser.settings.folderSummaryDelay = 0.3
        browser.settings.folderSummariesEnabled = false
        let rect = browser.table.rect(ofRow: row), point = NSPoint(x: rect.midX, y: rect.midY)
        browser.table.onSummaryPointer?(point)
        try await Task.sleep(for: .milliseconds(400))
        try require(!browser.folderSummary.isVisible && !ApplicationStorageAnalysis.shared.hasWork,
                    "Disabled hover submitted recursive analysis")
        browser.settings.folderSummariesEnabled = true
        browser.view.window?.orderOut(nil)
        browser.table.onSummaryPointer?(point)
        try await Task.sleep(for: .milliseconds(400))
        try require(!browser.folderSummary.isVisible && !ApplicationStorageAnalysis.shared.hasWork,
                    "Non-key browser submitted recursive hover analysis")
        browser.permitsBackgroundVerification = false
        let tabs = browser.tabs.count
        if let toolWindow = tool.window {
            let key = UIVerification.key("t", code: 17, flags: .command, window: toolWindow)
            try require(!browser.routeBrowserShortcut(key) && browser.tabs.count == tabs,
                        "Non-key browser stole a tool-window shortcut")
        }
        var checks = ["Synthetic real-view callbacks: disabled and non-key table hover and non-key tool-window shortcut routing start no recursive scan or browser tab action; physical pointer delivery remains unexercised"]
        if interactive, let host = browser.view.window {
            host.makeKeyAndOrderFront(nil)
            try await UIVerification.waitUntil("Generated browser becomes key for hover") { host.isKeyWindow }
            browser.table.scrollRowToVisible(row)
            browser.table.onSummaryPointer?(point)
            try await UIVerification.waitUntil("Enabled dwell publishes real generated summary") {
                browser.folderSummary.isVisible && browser.view.subviews.compactMap { $0 as? FolderSummaryCard }.contains {
                    textLabels($0).contains(where: { $0.contains("40 files") && $0.contains("0 folders") })
                }
            }
            if CGPreflightScreenCaptureAccess() {
                try await GlassVerification.captureOwnedWindow(host, to: capture)
                checks.append("Hover appearance captured from the exact owned window compositor using existing screen-capture access")
            } else {
                try await UIVerification.snapshot(host, to: capture)
                checks.append("Hover geometry captured with native view caching; compositor material fidelity remains unexercised because capture access was unavailable")
            }
            let captureSize = try await Task.detached {
                try capture.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }.value
            try require(captureSize <= 2 << 20, "Hover capture exceeded its small projection; evidence preserved")
            browser.table.onSummaryPointer?(nil)
            try await UIVerification.waitUntil("Hover exit removes card and drains actual demand") {
                !browser.folderSummary.isVisible && !ApplicationStorageAnalysis.shared.hasWork
            }
            await ApplicationStorageAnalysis.shared.stopAndDrain()
            let originalIssues = browser.issueCount
            browser.issueCount = originalIssues + 1
            var unavailable: FolderSummaryValue?
            ApplicationStorageAnalysis.shared.beginHover(owner: UUID(), entry: entry, browser: browser) { unavailable = $0 }
            browser.issueCount = originalIssues
            try require(unavailable?.counts == nil && unavailable?.isRunning == false
                        && unavailable?.isComplete == false && !ApplicationStorageAnalysis.shared.hasWork,
                        "Partial parent listing admitted an automatic recursive worker")
            checks.append("Enabled key-window table dwell uses the actual successful listing access and helper: card reports 40 files/0 folders; exit removes it and drains demand; parent-listing issue count refuses a worker. Callback injection is synthetic, not physical pointer delivery")
        }
        if browser.outline.numberOfRows > 1, let host = browser.view.window {
            let rowRect = browser.outline.rect(ofRow: 1)
            let location = browser.outline.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                browser.outline.mouseMoved(with: event)
                try await Task.sleep(for: .milliseconds(400))
                browser.outline.mouseExited(with: event)
                try require(!browser.folderSummary.isVisible && !ApplicationStorageAnalysis.shared.hasWork,
                            "Sidebar hover submitted recursive analysis")
                checks.append("Synthetic native sidebar mouse-move/exit callback remains presentation-only and starts no recursive scan")
            }
        }
        return checks
    }

    private static func textLabels(_ view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(textLabels)
    }

    private static func visibleTextLabels(_ view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { visibleTextLabels($0) }
    }

    private static func verifyAppStorage(_ coordinator: ApplicationStorageAnalysis, generated: Fixture,
                                          restoring settings: BrowserSettings) async throws -> [String] {
        // This check redirects only an in-memory settings instance. A complete
        // restored snapshot prevents its initializer from reading preferences;
        // no settings properties are changed or saved afterward.
        try require(settings.storageStateDirectory == nil,
                    "App Storage route control requires original in-memory verification settings")
        let restored = try BrowserSettings(persist: false).encodedSnapshot()
        let controlled = BrowserSettings(persist: false, restoredData: restored,
            persistenceFile: generated.scope.appendingPathComponent("nonexistent-preferences.json"))
        try require(controlled.storageStateDirectory == generated.scope, "Controlled settings storage parent changed")
        defer {
            // The original verification settings have no persistent storage
            // root. Resetting this route cannot start a personal-state scan.
            coordinator.showAppStorage(settings: settings)
            coordinator.toolWindow?.close()
        }
        coordinator.showAppStorage(settings: controlled)
        try await UIVerification.waitUntil("Actual App Storage generated-root route") {
            !coordinator.hasWork && coordinator.toolWindow?.preparedFolderCount == 6
                && coordinator.toolWindow?.isPreparingRows == false
        }
        guard let tool = coordinator.toolWindow, let content = tool.window?.contentView else {
            throw UIVerification.Failure(message: "Actual App Storage window is missing")
        }
        let labels = visibleTextLabels(content)
        try require(coordinator.currentRoot == generated.scope && tool.window?.title == "App Storage"
                    && tool.progressLabel.stringValue.contains("83 files")
                    && tool.progressLabel.stringValue.contains("5 folders")
                    && labels.contains(where: { $0.contains("Local app state") && $0.contains("macOS Spotlight storage are excluded") }),
                    "App Storage route used a different root or lost its honest scope explanation")
        try require(tool.appComponentRows.contains(where: { $0.title == "Preferences" && $0.logical == "Not created" })
                    && tool.appComponentRows.contains(where: { $0.title == "Content index" && $0.logical == "Not created" })
                    && tool.appComponentRows.contains(where: { $0.title == "Recovery files on other volumes" && $0.logical == "Not measured" }),
                    "Declared storage inventory invented an index, created preferences or hid outside recovery scope")
        return ["Actual App Storage action uses the settings storage parent, verified with an in-memory settings object bound to existing generated data; 83-file/5-folder observation, limited scope explanation and original settings route restored without creating preferences or opening a catalog"]
    }

    private static func verifyProperties(_ coordinator: ApplicationStorageAnalysis, generated: Fixture, settings: BrowserSettings,
                                         interactive: Bool, propertiesCapture: URL, fullCapture: URL) async throws -> [String] {
        try require(PropertyVolumeCapacity.observed(blocks: .max, available: 1, blockSize: 4096) == nil
                    && PropertyVolumeCapacity.observed(blocks: 1, available: 2, blockSize: 4096) == nil
                    && PropertyVolumeCapacity.observed(blocks: 4, available: 1, blockSize: 4096)?.available == 4096,
                    "Volume capacity overflow, invalid free-space or unit handling failed")
        let access = PropertiesAccessCounter()
        let properties = FilePropertiesWindowController(retainAccess: { _ in
            access.calls += 1
            return FileAccessLifetimes(leases: [])
        }, copyPaths: { _ in })
        let other = FilePropertiesWindowController(copyPaths: { _ in })
        defer { properties.close(); properties.cancel(); other.close(); other.cancel(); coordinator.toolWindow?.close() }
        let compositorCapture = interactive && CGPreflightScreenCaptureAccess()
        func capture(_ window: NSWindow, to destination: URL) async throws {
            if compositorCapture {
                try await Task.sleep(for: .milliseconds(160))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await GlassVerification.captureOwnedWindow(window, to: destination)
            } else { try await UIVerification.snapshot(window, to: destination) }
        }
        let scanStartsBeforeProperties = coordinator.allScanStartsForSessionReuseVerification
        properties.update(urls: [generated.scope])
        try await UIVerification.waitUntil("Shallow Properties metadata and optional saved lookup") {
            !properties.model.isLoading && !coordinator.hasWork
        }
        try require(properties.model.canAnalyzeStorage && properties.model.analysisValue?.isRunning != true
                    && coordinator.allScanStartsForSessionReuseVerification == scanStartsBeforeProperties,
                    "Opening Properties started recursive analysis or missed the directory action")
        properties.model.analyzeStorage()
        try await UIVerification.waitUntil("Embedded Properties scan and attribution") {
            !coordinator.hasWork && properties.model.attribution != nil
        }
        try require(properties.model.analysisValue?.counts?.regularFiles == 83
                    && properties.model.attribution?.categories[0].bytes.dataLogical.knownBytes != nil,
                    "Embedded analysis lost its real scan or compact attribution")
        if interactive { properties.show(urls: [generated.scope])
            // show replaces the selection and returns to shallow metadata by
            // contract. Start only after that new selection has been admitted.
            try await UIVerification.waitUntil("Visible Properties metadata") { !properties.model.isLoading }
            properties.model.analyzeStorage()
            try await UIVerification.waitUntil("Visible embedded observation") { !coordinator.hasWork && properties.model.attribution != nil }
        }
        if interactive {
            let previousPresentation = InterfacePresentation.shared.settings
            let enlarged = BrowserSettings(persist: false); enlarged.interfaceSize = .init(150)
            InterfacePresentation.shared.bind(enlarged)
            defer { InterfacePresentation.shared.bind(previousPresentation ?? settings) }
            try await capture(properties.window!, to: propertiesCapture)
        } else { try await capture(properties.window!, to: propertiesCapture) }
        let beforeHandoff = access.calls
        properties.model.openFullAnalysis()
        try await UIVerification.waitUntil("Full Analysis handoff") {
            coordinator.toolWindow?.preparedFolderCount == 6 && coordinator.toolWindow?.isPreparingRows == false
        }
        try require(!coordinator.hasWork && access.calls == beforeHandoff
                    && coordinator.currentRoot == generated.scope
                    && properties.model.analysisValue?.message == "Continues in Storage Analysis.",
                    "Open Full Analysis rescanned, reacquired access or lost the existing result")
        try require((coordinator.toolWindow?.window?.contentView?.bounds.width ?? 0) >= 740,
                    "Chart hosting resized the native analyzer below its minimum width")
        if let tool = coordinator.toolWindow, let window = tool.window, let content = window.contentView {
            let originalSize = content.bounds.size
            window.setContentSize(.init(width: 740, height: 448))
            content.layoutSubtreeIfNeeded()
            try require((tool.outlineView.enclosingScrollView?.bounds.height ?? 0) >= 89,
                        "Compact chart squeezed the native folder table below its usable height")
            window.setContentSize(originalSize)
            content.layoutSubtreeIfNeeded()
        }
        try await capture(coordinator.toolWindow!.window!, to: fullCapture)

        other.update(urls: [generated.partial])
        try await UIVerification.waitUntil("Second Properties metadata and saved lookup") {
            !other.model.isLoading && !coordinator.hasWork
        }
        properties.model.analyzeStorage()
        // Both enabled gestures are immediate. The existing latest-request
        // owner must retain the second while the prior readers finish.
        other.model.analyzeStorage()
        properties.cancel()
        try await UIVerification.waitUntil("Latest explicit analysis replaces the prior consumer") {
            !coordinator.hasWork && other.model.attribution != nil
        }
        try require(properties.model.analysisValue?.isRunning == false
                    && other.model.analysisValue?.counts?.regularFiles == 1
                    && other.model.analysisValue?.isComplete == false
                    && coordinator.currentRoot == generated.partial,
                    "Superseded Properties cancelled another consumer or accepted a stale result")
        other.model.analyzeStorage()
        let detachedObservationDate = other.model.analysisValue?.observedAt
        other.cancel()
        await coordinator.stopAndDrain()
        try require(!coordinator.hasWork && !other.model.isLoading && !other.model.chartDrill.canBrowse
                    && other.model.analysisValue?.observedAt == detachedObservationDate,
                    "Closing Properties left preparation or recursive I/O active")

        let stoppedProjection = ProjectionLatch()
        defer { stoppedProjection.release(); coordinator.projectionHookForVerification = nil }
        coordinator.projectionHookForVerification = { try stoppedProjection.wait() }
        other.model.analyzeStorage()
        try await UIVerification.waitUntil("Held post-scan projection") { stoppedProjection.isWaiting && coordinator.activeSession == nil }
        other.model.stopAnalysis()
        try require(coordinator.hasWork && other.model.analysisValue?.message.contains("Stopped preparing") == true,
                    "Stop during post-scan attribution stranded the scanner owner or discarded observed counts")
        var stoppedDrained = false
        let stoppedDrain = Task { @MainActor in await coordinator.stopAndDrain(); stoppedDrained = true }
        try await Task.sleep(for: .milliseconds(30))
        try require(!stoppedDrained, "Drain forgot preparation that had already been cancelled by Stop")
        stoppedProjection.release()
        await stoppedDrain.value
        try await UIVerification.waitUntil("Stopped projection actual completion") { stoppedProjection.hasFinished }

        let drainingProjection = ProjectionLatch()
        defer { drainingProjection.release(); coordinator.projectionHookForVerification = nil }
        coordinator.projectionHookForVerification = { try drainingProjection.wait() }
        other.model.analyzeStorage()
        try await UIVerification.waitUntil("Held projection drain control") { drainingProjection.isWaiting && coordinator.activeSession == nil }
        var drained = false
        let drain = Task { @MainActor in await coordinator.stopAndDrain(); drained = true }
        try await Task.sleep(for: .milliseconds(30))
        try require(!drained, "Drain returned before the actual cancelled projection completed")
        drainingProjection.release()
        await drain.value
        coordinator.projectionHookForVerification = nil
        try require(drained && !coordinator.hasWork, "Post-scan projection did not drain")

        let sample = try await scan(StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"),
            activityGate: ApplicationFileActivity.gate), root: generated.scope)
        let snapshot = sample.snapshot!
        let controls = try await Task.detached {
            let replaced = try AppStorageInventory.inspect(root: generated.partial, snapshot: snapshot)
            let link = try AppStorageInventory.inspect(root: generated.scope.appendingPathComponent("outside-link"), snapshot: snapshot)
            return replaced.first?.logical == "Unavailable" && link.first?.logical == "Unavailable"
        }.value
        try require(controls, "Component inspection followed a redirected root or accepted a different root identity")
        let handoff = try await verifyRetiringPropertyDemand(coordinator: coordinator, root: generated.scope)
        return ["Properties metadata and optional saved lookup start no recursive scan; explicit embedded scan/category chart carries83 files; full-window handoff reuses the result without another access request or scan",
                "Latest explicit request replaces the prior Properties consumer; closing its old view cannot cancel the new scan; Stop/close drains preparation and rejects stale publications",
                "Deterministically held post-scan projection: Stop retains observed counts without stranding ownership; stopAndDrain waits for actual cancelled preparation completion",
                "App-owned component reader refuses mismatched and symlink roots, uses metadata only, creates no preferences/index/history and exposes outside-scope recovery files honestly",
                compositorCapture ? "Visible Properties at150% and Analyzer images use the exact owned-window compositor capture with existing screen access"
                    : "Properties and Analyzer images use native view caching; compositor material/color fidelity remains unexercised"] + handoff
    }

    /// Hold one real query-retirement callback while exercising the ordinary
    /// request API. This reproduces the enabled-but-dropped Analyze gesture
    /// without relying on the filesystem or renderer to hit a timing window.
    private static func verifyRetiringPropertyDemand(coordinator: ApplicationStorageAnalysis, root: URL) async throws -> [String] {
        for finish in ["latest", "stop", "close"] {
            let previous = UUID(), replaced = UUID(), latest = UUID(), latch = ProjectionLatch()
            var originalValue: FolderSummaryValue?, firstValue: FolderSummaryValue?, latestValue: FolderSummaryValue?
            var waitingOwnerDrains = 0
            do {
                coordinator.analyzeProperties(owner: previous, root: root,
                    access: { FileAccessLifetimes(leases: []) }, drainQueries: {
                        _ = try? await Task.detached { try latch.wait() }.value
                    }, onChange: { value, _ in originalValue = value })
                try await UIVerification.waitUntil("Prior Properties result before held query retirement") {
                    !coordinator.hasWork && originalValue?.counts?.regularFiles == 83
                }
                coordinator.closeProperties(owner: previous)
                try await UIVerification.waitUntil("Actual prior Properties query retirement is held") { latch.isWaiting }
                let before = coordinator.allScanStartsForSessionReuseVerification
                coordinator.analyzeProperties(owner: replaced, root: root,
                    access: { FileAccessLifetimes(leases: []) }, drainQueries: { waitingOwnerDrains += 1 },
                    onChange: { value, _ in firstValue = value })
                coordinator.analyzeProperties(owner: latest, root: root,
                    access: { FileAccessLifetimes(leases: []) }, drainQueries: { waitingOwnerDrains += 1 },
                    onChange: { value, _ in latestValue = value })
                try require(firstValue?.isRunning == false && latestValue?.isRunning == true
                    && coordinator.hasWork && coordinator.resultForProperties(owner: latest) == nil
                    && coordinator.recordedQueriesForProperties(owner: latest) == nil,
                    "Queued Analyze did not expose Preparing/Stop, or granted fresh reads during old query retirement")
                coordinator.closeProperties(owner: replaced)
                try await Task.sleep(for: .milliseconds(25))
                try require(latch.isWaiting && waitingOwnerDrains == 0
                    && coordinator.allScanStartsForSessionReuseVerification == before,
                    "A waiting Properties owner started a scan, chained another drain or lost the retained prior reader")
                if finish == "stop" { coordinator.stopProperties(owner: latest) }
                else if finish == "close" { coordinator.closeProperties(owner: latest) }
                if finish != "latest" {
                    try require(coordinator.hasWork && latestValue?.isRunning == false,
                        "Stop/close lost actual retirement ownership or left queued Analyze running")
                }
                latch.release()
                try await UIVerification.waitUntil("Queued Properties request completes after actual query retirement") { !coordinator.hasWork }
                try require(coordinator.allScanStartsForSessionReuseVerification == before + (finish == "latest" ? 1 : 0),
                    "Retired-query handoff started a stale, duplicate or cancelled scan")
                if finish == "latest" {
                    try require(latestValue?.counts?.regularFiles == 83 && latestValue?.isRunning == false,
                        "The latest queued Analyze required another user gesture or lost its final result")
                    coordinator.closeProperties(owner: latest)
                }
                await coordinator.stopAndDrain()
                try require(latch.hasFinished && !coordinator.hasWork,
                    "Properties demand completed without actually draining its old query owner")
            } catch {
                latch.release(); await coordinator.stopAndDrain(); throw error
            }
        }
        return ["Enabled Analyze waits for actual prior-query retirement and automatically runs only the latest request; no fresh reads or drain chains appear while waiting",
                "Stop and close cancel a waiting Analyze before any scan starts, while stale-owner close cannot cancel the current request and actual old-reader ownership stays retained"]
    }

    private static func verifySummaryPreferences() throws -> [String] {
        let defaults = BrowserSettings(persist: false)
        try require(defaults.folderSummariesEnabled && defaults.folderSummaryDelay == 1.0,
                    "Folder summary initial defaults changed")
        defaults.folderSummariesEnabled = false
        defaults.folderSummaryDelay = 2.75
        let restored = BrowserSettings(persist: false, restoredData: try defaults.encodedSnapshot())
        try require(!restored.folderSummariesEnabled && restored.folderSummaryDelay == 2.75
                    && restored.storageStateDirectory == nil,
                    "Folder summary preference snapshot lost enabled/delay values or created a storage root")
        return ["In-memory preferences default summaries on with a 1-second dwell; explicit disabled/2.75-second values round-trip through the real settings encoder/decoder without filesystem persistence"]
    }

    private static func verifyShutdownAdmission(_ coordinator: ApplicationStorageAnalysis,
                                                 generated: Fixture) async throws -> [String] {
        var pending: CheckedContinuation<FileAccessLifetimes, Never>?
        var accessBegan = false, shutdownBegan = false, drained = false, replacementAccessed = false
        defer {
            pending?.resume(returning: FileAccessLifetimes(leases: []))
            coordinator.resumeAfterCancelledTermination()
        }
        coordinator.toolWindow?.showWindow(nil)
        coordinator.verificationBegin(root: generated.scope) {
            accessBegan = true
            return await withCheckedContinuation { pending = $0 }
        }
        try await UIVerification.waitUntil("Access held during termination admission") { accessBegan }
        let rootBeforeShutdown = coordinator.currentRoot
        let shutdown = Task { @MainActor in
            shutdownBegan = true
            await coordinator.stopAndDrain(shuttingDown: true)
            drained = true
        }
        try await UIVerification.waitUntil("Termination drain begins") { shutdownBegan }
        try require(!drained, "Termination drain ignored outstanding access preparation")
        coordinator.verificationBegin(root: generated.partial) {
            replacementAccessed = true
            return FileAccessLifetimes(leases: [])
        }
        try require(coordinator.currentRoot == rootBeforeShutdown && !replacementAccessed,
                    "An action during asynchronous termination admitted a replacement request")
        pending?.resume(returning: FileAccessLifetimes(leases: [])); pending = nil
        await shutdown.value
        try require(drained && !coordinator.hasWork && coordinator.activeSession == nil
                    && !replacementAccessed && coordinator.currentRoot == rootBeforeShutdown,
                    "Termination drain resurrected a late helper request")
        coordinator.resumeAfterCancelledTermination()
        coordinator.verificationBegin(root: generated.partial) { FileAccessLifetimes(leases: []) }
        try await UIVerification.waitUntil("Cancelled termination restores actual analysis admission") {
            !coordinator.hasWork && coordinator.toolWindow?.preparedFolderCount == 2
                && coordinator.toolWindow?.isPreparingRows == false
        }
        try require(coordinator.currentRoot == generated.partial
                    && coordinator.updateForVerification?.status == .partial
                    && coordinator.toolWindow?.statusLabel.stringValue == "Some items weren’t included",
                    "Cancelled termination did not restore a normal actual helper request")
        return ["Held access preparation remains owned during shutdown drain; new requests cannot replace its root or launch a helper; cancelling termination restores a normal actual helper scan"]
    }

    private static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    private static func verifyChooserAndAdmission(_ coordinator: ApplicationStorageAnalysis,
                                                  generated: Fixture) async throws -> [String] {
        guard let tool = coordinator.toolWindow else {
            throw UIVerification.Failure(message: "Actual coordinator window is missing")
        }
        var pending: CheckedContinuation<FolderAccessChoice?, Never>?
        var chooserBegan = false
        let originalChooser = coordinator.chooseFolderForVerification
        defer {
            pending?.resume(returning: nil)
            coordinator.chooseFolderForVerification = originalChooser
        }
        coordinator.chooseFolderForVerification = { _, _ in
            chooserBegan = true
            return await withCheckedContinuation { pending = $0 }
        }
        func choice(_ root: URL) -> FolderAccessChoice {
            .init(selection: .init(id: UUID(), url: root), lease: FolderAccessLease(url: root, backend: ChooserBackend()), remembering: .notRequested)
        }
        tool.showWindow(nil)
        guard let choose = button("Choose Folder…", in: tool.window?.contentView) else {
            throw UIVerification.Failure(message: "Actual Choose Folder control is missing")
        }
        let rootBeforeChoice = coordinator.currentRoot
        choose.performClick(nil)
        try await UIVerification.waitUntil("Actual chooser action is suspended") { chooserBegan }
        tool.close()
        try require(tool.isClosed, "Chooser close pre-resume invariant failed: controllerClosed=0")
        try require(coordinator.activeSession == nil, "Chooser close pre-resume invariant failed: activeSessionPresent=1")
        try require(coordinator.currentRoot == rootBeforeChoice, "Chooser close pre-resume invariant failed: currentRootChanged=1")
        pending?.resume(returning: choice(generated.partial)); pending = nil
        try await UIVerification.waitUntil("Closed chooser task settles") { !coordinator.hasWork }
        try require(tool.isClosed && coordinator.activeSession == nil && coordinator.currentRoot == rootBeforeChoice,
                    "Late chosen-folder callback reopened a closed analysis consumer")

        tool.showWindow(nil); chooserBegan = false
        choose.performClick(nil)
        try await UIVerification.waitUntil("Chooser before replacement request") { chooserBegan }
        coordinator.verificationBegin(root: generated.partial) { FileAccessLifetimes(leases: []) }
        pending?.resume(returning: choice(generated.scope)); pending = nil
        try await UIVerification.waitUntil("Replacement request and stale chooser settle") {
            !coordinator.hasWork && tool.preparedFolderCount == 2 && !tool.isPreparingRows
        }
        try require(coordinator.currentRoot == generated.partial && tool.statusLabel.stringValue == "Some items weren’t included",
                    "Stale chooser selection replaced the newer actual helper result")

        chooserBegan = false
        choose.performClick(nil)
        try await UIVerification.waitUntil("Chooser included in drain ownership") { chooserBegan }
        var drained = false, drainBegan = false
        let drain = Task { @MainActor in drainBegan = true; await coordinator.stopAndDrain(); drained = true }
        try await UIVerification.waitUntil("Chooser drain task begins") { drainBegan }
        try require(!drained, "Stop-and-drain ignored a still-held chooser callback")
        pending?.resume(returning: choice(generated.scope)); pending = nil
        await drain.value
        try require(drained && !coordinator.hasWork && coordinator.activeSession == nil,
                    "Cancelled chooser retained work after its actual callback returned")

        let scanStartsBeforeClosedGate = coordinator.allScanStartsForSessionReuseVerification
        guard let token = ApplicationFileActivity.gate.closeAdmission() else {
            throw UIVerification.Failure(message: "Generated admission control could not own a gate token")
        }
        coordinator.verificationBegin(root: generated.scope) { FileAccessLifetimes(leases: []) }
        do {
            try await UIVerification.waitUntil("Closed-gate analysis request settles") { !coordinator.hasWork }
            try require(coordinator.activeSession == nil
                        && coordinator.allScanStartsForSessionReuseVerification == scanStartsBeforeClosedGate
                        && tool.statusLabel.stringValue == "Couldn’t finish this scan"
                        && tool.progressLabel.stringValue == "Let the current file operation finish, then try again.",
                        "Closed activity admission launched a scanner or hid the unavailable state")
        } catch {
            _ = ApplicationFileActivity.gate.reopen(token)
            throw error
        }
        try require(ApplicationFileActivity.gate.reopen(token), "Generated activity admission token did not reopen")

        var factoryToken: AccessFactoryToken? = AccessFactoryToken()
        weak let retainedFactory = factoryToken
        coordinator.verificationBegin(root: generated.scope) { [retained = factoryToken!] in
            withExtendedLifetime(retained) {}
            return FileAccessLifetimes(leases: [])
        }
        factoryToken = nil
        try await UIVerification.waitUntil("Retained access factory request completes") {
            !coordinator.hasWork && tool.preparedFolderCount == 6 && !tool.isPreparingRows
        }
        try require(retainedFactory != nil, "Completed open consumer lost its refresh access factory")
        tool.close()
        try require(retainedFactory == nil, "Closed consumer retained its access factory")
        return ["Actual Choose Folder action: late callback after close/replacement is rejected and stop-and-drain waits for chooser completion; closed activity admission settles unavailable; closing releases the refresh access factory"]
    }
}
#endif
