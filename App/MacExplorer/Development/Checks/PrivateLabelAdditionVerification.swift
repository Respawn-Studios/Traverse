#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileMemory

@MainActor enum PrivateLabelAdditionVerification {
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Phase {
        var current = "generated-reference-setup"
        var gaps: [[String: Any]] = []
        var turns = 0
    }
    static func run() async {
        guard let value = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: value)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
              root.resolvingSymlinksInPath().path == root.path, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-private-labels" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.reviewsRecoveryAtStartup = false; settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
        settings.showsDockProgress = false; settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark; settings.motion.mode = .off
        let browserOwner = BrowserWindowController(settings: settings)
        let owner = ApplicationPrivateNames(directory: root.appendingPathComponent("source/catalog"), settings: settings)
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        let phase = Phase()
        var ticks = 0, gap = 0.0
        let ticker = Task { @MainActor in
            var previous = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = CACurrentMediaTime(), elapsed = now - previous
                gap = max(gap, elapsed)
                if elapsed > 0.05, phase.gaps.count < 32 { phase.gaps.append(["phase": phase.current, "seconds": elapsed]) }
                previous = now; ticks += 1
                phase.turns += 1
            }
        }
        do { try await verify(root: root, browserOwner: browserOwner, owner: owner, settings: settings, phase: phase, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        await owner.close(); browserOwner.suspendBrowsing(); await browserOwner.flushSession(); browserOwner.window?.close()
        ticker.cancel(); await ticker.value
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256 * 1024 * 1024 { failures.append("Native memory gate failed") }
        if gap > 0.4 || ticks < 10 { failures.append("Main-actor response gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual file activity remains") }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics, "slowNativeIntervals": phase.gaps, "maximumMainActorGapSeconds": gap, "peakRSSBytes": usage.ru_maxrss, "ticks": ticks,
            "activityCount": ApplicationFileActivity.gate.activeCount, "generatedOnly": true,
            "network": 0, "keychainQueries": 0, "personalCatalogs": 0, "nativeActionsNotPhysicalInput": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, browserOwner: BrowserWindowController, owner: ApplicationPrivateNames,
                               settings: BrowserSettings, phase: Phase, checks: inout [String], metrics: inout [String: Any]) async throws {
        try UIVerification.require(PrivateLabelAdditionActivation.enabled, "Ordinary development label action is disabled")
        let source = root.appendingPathComponent("source/Generated.txt"), folder = root.appendingPathComponent("source/Generated Folder")
        let seed = try await PersistentNameStore.createRemembering(directory: root.appendingPathComponent("source/catalog"),
            first: AuthoredNames(nickname: "Linked report", alternateNames: ["Project Atlas"], labels: ["existing"]), source: source,
            activity: ApplicationFileActivity.gate, allowDocumentFollowing: true)
        let first = try await seed.firstItemID()
        let captured = try await seed.prepareRemembering(AuthoredNames(nickname: "Linked folder", labels: ["existing"]),
            source: folder, allowDocumentFollowing: true)
        let second = try await seed.apply(captured)
        phase.current = "generated-catalog-setup"
        for index in 2..<80 {
            let names = try AuthoredNames(nickname: index == 79 ? "Full labels" : "Generated \(index)",
                labels: index == 79 ? (0..<16).map { "full\($0)" } : ["existing"])
            _ = try await seed.apply(seed.prepareNew(names))
        }
        let firstReference = try await seed.resolveReference(first), secondReference = try await seed.resolveReference(second)
        try UIVerification.require(firstReference.publish { _ in } && secondReference.publish { _ in }, "Generated native references missing")
        await seed.close()
        phase.current = "workspace-startup"
        let flags = try await sourceFlags([source,folder])
        try UIVerification.require(browserOwner.isWorkspacePresentation, "Label UI requires actual workspace")
        browserOwner.window?.setFrameOrigin(.init(x: -12000,y: -12000)); browserOwner.browser.permitsBackgroundVerification = true
        browserOwner.beginBrowsing(); try await wait("workspace") { browserOwner.workspace.sessionReady }
        phase.current = "library-window-create"
        let library = PrivateNamesWindowController(owner: owner), model = library.model
        defer { library.close() }
        phase.current = "library-window-show"
        library.show(browser: browserOwner.browser)
        guard let window = library.window else { throw UIVerification.Failure(message: "Remembered Items window missing") }
        window.title = "Private labels · generated review"; window.setFrame(.init(x: 100,y: 130,width: 860,height: 560),display: true)
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(.init(x: -12000,y: -12000)) }
        phase.current = "first-library-page"
        try await wait("first real library page") { !model.loading && model.rows.count == 64 }
        phase.current = "second-library-page"
        model.reload(more: true); try await wait("second real library page") { !model.loading && model.rows.count == 80 }
        phase.current = "oversized-selection"
        model.selectedIDs = Set(model.rows.prefix(65).map(\.id))
        try UIVerification.require(!model.canAddLabels, "More than64 targets were silently truncated")
        model.addLabels(); try UIVerification.require(model.labelSheet == nil, "Oversized selection opened a partial editor")
        phase.current = "linked-selection"
        model.selectedIDs = [first,second]
        guard let firstRow = model.rows.first(where: { $0.id == first }), let secondRow = model.rows.first(where: { $0.id == second }) else {
            throw UIVerification.Failure(message: "Generated linked rows missing")
        }
        let before = (firstRow.names.revision,secondRow.names.revision)
        phase.current = "first-label-sheet-create"
        model.addLabels()
        guard let sheet = model.labelSheet else { throw UIVerification.Failure(message: "Selected labels editor missing") }
        await nextNativeTurn(phase)
        if ProcessInfo.processInfo.arguments.contains("--label-privacy-control") {
            sheet.model.draft = "unsaved generated draft"; sheet.model.addDraft()
            phase.current = "minimized-privacy-withdrawal"
            _ = try await owner.forget(first)
            metrics["privacyFinishAttempts"] = sheet.finishAttemptsForVerification
            metrics["privacyNativeIntervals"] = sheet.nativeIntervalsForVerification
            try UIVerification.require(sheet.model.withdrawn && sheet.model.labels.isEmpty && sheet.model.titles.isEmpty
                && model.labelSheet == nil, "Minimized privacy withdrawal retained editor content")
            try UIVerification.require(sheet.finishAttemptsForVerification == 1, "Privacy withdrawal dismissed the native sheet more than once")
            checks.append("Minimized actual sheet/Forget withdrawal has no private text")
            return
        }
        sheet.model.draft = "reviewed"; sheet.model.addDraft()
        phase.current = "first-label-save"
        let began = CACurrentMediaTime(); sheet.model.save()
        try await wait("first Save including writer opening") { !owner.isSaving && !sheet.model.saving && model.labelSheet == nil && window.attachedSheet == nil }
        metrics["twoItemSaveMilliseconds"] = (CACurrentMediaTime() - began) * 1000
        let store = try await requireStore(owner)
        for (id,revision) in [(first,before.0),(second,before.1)] {
            let value = try await saved(store,id)
            try UIVerification.require(value.revision == revision + 1 && value.names.labels == ["existing","reviewed"], "Actual UI lost its draft on writer opening or missed selected records")
            let reference = try await store.resolveReference(id)
            var available = false; _ = reference.publish { available = $0.availability == .available }
            try UIVerification.require(available, "A label change broke an existing native reference")
        }
        let preserved = try await saved(store,first), afterFlags = try await sourceFlags([source,folder])
        try UIVerification.require(preserved.names.alternateNames == ["Project Atlas"]
            && afterFlags == flags, "Labels changed unrelated authored fields or native flags")
        checks.append("Actual multi-selection refuses65, saves two linked descriptions across first writer opening, preserves names/native references/flags and changes only labels")

        phase.current = "label-query-and-noop"
        model.query = "reviewed"; model.labelOnly = true; model.reload()
        try await wait("normal direct label search") { !model.loading && Set(model.rows.map(\.id)) == [first,second] }
        model.selectedIDs = [first,second]; model.addLabels()
        guard let noop = model.labelSheet else { throw UIVerification.Failure(message: "No-op editor missing") }
        await nextNativeTurn(phase)
        noop.model.draft = "reviewed"; noop.model.save()
        try await wait("no-op Save") { !owner.isSaving && !noop.model.saving && model.labelSheet == nil && window.attachedSheet == nil }
        let noopFirst = try await saved(store,first), noopSecond = try await saved(store,second)
        try UIVerification.require(noopFirst.revision == before.0 + 1 && noopSecond.revision == before.1 + 1,
            "No-op UI bumped revisions")
        model.selectedIDs = [first,second]; model.addLabels()
        phase.current = "stale-label-sheet"
        guard let stale = model.labelSheet else { throw UIVerification.Failure(message: "Stale editor missing") }
        await nextNativeTurn(phase)
        stale.model.draft = "must stay absent"; stale.model.addDraft()
        let previous = try await store.snapshot(first)
        _ = try await store.apply(store.prepareEdit(previous, names: AuthoredNames(nickname: "Linked report changed", alternateNames: ["Project Atlas"], labels: ["existing","reviewed"])))
        stale.model.save(); try await wait("stale Save refuses all") { !owner.isSaving && !stale.model.saving && !stale.model.notice.isEmpty }
        let staleOther = try await saved(store,second)
        try UIVerification.require(model.labelSheet === stale && stale.model.labels == ["must stay absent"]
            && staleOther.names.labels == ["existing","reviewed"], "Stale Save lost its draft or changed another description")
        stale.model.cancel()
        await nextNativeTurn(phase)
        checks.append("Normal direct label search finds updated items; no-op preserves revisions; stale revision refuses the whole Save and keeps its draft")

        phase.current = "full-selection-reload"
        model.query = ""; model.labelOnly = false; model.reload(); try await wait("reload for full selection") { !model.loading && model.rows.count == 64 }
        model.reload(more: true); try await wait("full selection list") { !model.loading && model.rows.count == 80 }
        guard let full = model.rows.first(where: { $0.title == "Full labels" }) else { throw UIVerification.Failure(message: "Full-label target missing") }
        phase.current = "full-label-sheet"
        model.selectedIDs = [first,full.id]; model.addLabels()
        guard let overflow = model.labelSheet else { throw UIVerification.Failure(message: "Limit editor missing") }
        await nextNativeTurn(phase)
        overflow.model.draft = "extra"; overflow.model.save()
        try await wait("whole selection limit refusal") { !owner.isSaving && !overflow.model.saving && !overflow.model.notice.isEmpty }
        let overflowFirst = try await saved(store,first), overflowFull = try await saved(store,full.id)
        try UIVerification.require(overflowFirst.names.labels == ["existing","reviewed"] && overflowFull.names.labels.count == 16,
            "A per-record limit caused partial application")
        overflow.model.cancel()
        await nextNativeTurn(phase)
        model.selectedIDs = [first,second]; model.addLabels()
        guard let privacy = model.labelSheet else { throw UIVerification.Failure(message: "Privacy draft missing") }
        await nextNativeTurn(phase)
        privacy.model.draft = "private unsaved draft"; privacy.model.addDraft()
        phase.current = "privacy-forget"
        _ = try await owner.forget(first)
        metrics["privacyFinishAttempts"] = privacy.finishAttemptsForVerification
        metrics["privacyNativeIntervals"] = privacy.nativeIntervalsForVerification
        try UIVerification.require(privacy.model.withdrawn && privacy.model.labels.isEmpty && privacy.model.draft.isEmpty
            && privacy.model.titles.isEmpty && model.labelSheet == nil, "Forget left private editor text or authority")
        try UIVerification.require(privacy.finishAttemptsForVerification == 1, "Forget repeated native sheet dismissal")
        checks.append("One full label list refuses all selected changes; Forget immediately clears an open draft/titles and retires its editor without a fade")

        phase.current = "maximum-selection-reload"
        model.query = ""; model.reload(); try await wait("remaining descriptions") { !model.loading && model.rows.count == 64 }
        model.reload(more: true); try await wait("remaining pages") { !model.loading && model.rows.count == 79 }
        let targets = model.rows.filter { $0.id != full.id }.prefix(64)
        phase.current = "maximum-selection"
        model.selectedIDs = Set(targets.map(\.id)); model.addLabels()
        guard let maximum = model.labelSheet else { throw UIVerification.Failure(message: "Maximum selection missing") }
        await nextNativeTurn(phase)
        phase.current = "maximum-label-save"
        maximum.model.draft = "batch64"; maximum.model.save()
        try await wait("actual64-item Save") { !owner.isSaving && !maximum.model.saving && model.labelSheet == nil && window.attachedSheet == nil }
        model.query = "batch64"; model.labelOnly = true; model.reload()
        try await wait("exact64 updated items") { !model.loading && model.rows.count == 64 }
        checks.append("The actual64-item native Save and direct index return all64 descriptions with no prefix application")

        phase.current = "recorded-sheet"
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            window.setFrameOrigin(.init(x: 100,y: 130)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode; model.selectedIDs = Set(model.rows.prefix(3).map(\.id)); model.addLabels()
                guard let editor = model.labelSheet, let panel = editor.window else { throw UIVerification.Failure(message: "Recorded label sheet missing") }
                await nextNativeTurn(phase)
                panel.title = "Private labels · generated review"
                let report = try await NativeMotionRecorder.record(window: panel, root: root, label: "private-labels-" + mode.rawValue) {
                    editor.model.draft = "ready for review"; editor.model.addDraft()
                }
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/private-labels-" + mode.rawValue + ".json"),options: .withoutOverwriting)
                if mode == .full { try await GlassVerification.captureOwnedWindow(panel,to: root.appendingPathComponent("evidence/private-labels.png")) }
                editor.model.cancel()
                await nextNativeTurn(phase)
            }
        }
        phase.current = "close-preparation"
        model.selectedIDs = Set(model.rows.prefix(2).map(\.id)); model.addLabels()
        guard let closing = model.labelSheet else { throw UIVerification.Failure(message: "Closing editor missing") }
        await nextNativeTurn(phase)
        let hold = Hold(); defer { hold.release() }
        owner.beforeLabelApplyForVerification = { await hold.pause() }
        closing.model.draft = "must never save"; closing.model.save()
        try await wait("actual prepared label Save held") { hold.entered && owner.isSaving }
        var closed = false
        let close = Task { await owner.close(); closed = true }
        try await Task.sleep(for: .milliseconds(40))
        try UIVerification.require(!closed && closing.model.withdrawn && closing.model.labels.isEmpty && closing.model.draft.isEmpty,
            "Owner close returned before actual label preparation drain or kept its draft")
        hold.release(); await close.value; await closing.model.drain()
        let reopened = try await PersistentNameStore.open(directory: root.appendingPathComponent("source/catalog"))
        let absent = try await reopened.query(RememberedNameQuery(text: "must never save"))
        var count = -1; _ = absent.publish { count = $0.count }
        try UIVerification.require(count == 0, "Closed preparation published labels after withdrawal")
        await reopened.close(); library.close()
        checks.append("Close withdraws private text, waits for the actual held preparation and cold reopening proves no cancelled labels were saved")
    }
    private static func requireStore(_ owner: ApplicationPrivateNames) async throws -> PersistentNameStore {
        guard let store = try await owner.writer() else { throw NameIndexFailure.missingRecord }; return store
    }
    private static func saved(_ store: PersistentNameStore,_ id: RememberedItemID) async throws -> RememberedNamesSnapshot {
        let snapshot = try await store.snapshot(id); var value: RememberedNamesSnapshot?
        guard snapshot.publish({ value = $0 }), let value else { throw NameIndexFailure.stalePage }; return value
    }
    private static func sourceFlags(_ urls: [URL]) async throws -> [UInt32] {
        try await Task.detached {
            try urls.map { url in var info = stat(); guard lstat(url.path,&info) == 0 else { throw NameStoreFailure.unavailable }; return info.st_flags }
        }.value
    }
    private static func wait(_ message: String,_ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime() + 15
        while !condition() { guard CACurrentMediaTime() < end else { throw UIVerification.Failure(message: message) }; try await Task.sleep(for: .milliseconds(10)) }
    }
    /// AppKit's native sheet open/close calls synchronously wait for their own
    /// transition. Give the responsiveness sampler a real run-loop turn before
    /// issuing a different simulated user action; no production delay is added.
    private static func nextNativeTurn(_ phase: Phase) async {
        let previous = phase.turns
        while phase.turns == previous { await Task.yield() }
    }
}
#endif
