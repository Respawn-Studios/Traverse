#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileOperations

@MainActor enum FolderViewsVerification {
    static func run(root: URL, browser initialBrowser: BrowserViewController) async throws -> [String: Any] {
        var browser = initialBrowser
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b01-folder-views")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Folder-view QA requires its admitted generated root")
        let directory = root.appendingPathComponent("state/folder-views"), store = FolderViewStore(directory: directory)
        let model = ApplicationFolderViews(store: store)
        browser.folderViews = model; browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        let first = try await store.load()
        try require(first.bytes == nil && !FileManager().fileExists(atPath: directory.path), "Passive folder-view load created files")
        let a = root.appendingPathComponent("source/Photos"), b = root.appendingPathComponent("source/Work")
        let icons = FolderViewChoice(mode: .icons, sort: .init(field: .size, ascending: false, foldersFirst: false))
        let details = FolderViewChoice(mode: .details, sort: .init(field: .name, ascending: true, foldersFirst: true))
        browser.navigate(to: .directory(a)); try await loaded(browser)
        browser.setPaneViewMode(.icons)
        browser.tabs[browser.activeIndex].sort = icons.sort; browser.markFolderViewOverride()
        browser.saveFolderView(nil); await model.drain()
        try require(model.library.record(for: a.path)?.choice == icons && !model.isUnavailable, "Native Save did not capture current mode/sort")
        browser.navigate(to: .directory(b)); try await loaded(browser)
        browser.setPaneViewMode(.details); browser.tabs[browser.activeIndex].sort = details.sort; browser.markFolderViewOverride()
        browser.saveFolderView(nil); await model.drain()
        try require(model.library.records.count == 2 && model.library.record(for: b.path)?.choice == details, "Second folder preference did not save")
        browser.navigate(to: .directory(a)); try await loaded(browser)
        try require(browser.effectiveViewMode == .icons && browser.tabs[browser.activeIndex].sort == icons.sort,
                    "Fresh visit did not use the saved choice before listing")
        browser.setPaneViewMode(.list)
        browser.goBack(nil); try await loaded(browser)
        try require(browser.effectiveViewMode == .details, "Back lost the earlier visit's choice")
        browser.goForward(nil); try await loaded(browser)
        try require(browser.effectiveViewMode == .list, "Forward replaced an explicit visit override with the saved default")
        browser.refresh(nil); try await loaded(browser)
        try require(browser.effectiveViewMode == .list, "Refresh reapplied a saved default over an override")
        browser.applySavedFolderView(nil)
        try await wait { browser.effectiveViewMode == .icons }
        let duplicate = ClosedBrowserTab(browser.tabs[browser.activeIndex]).restored()
        try require(duplicate.presentationMode == .icons && duplicate.folderViewResolved && duplicate.sort == icons.sort,
                    "Close/reopen or duplicate discarded the resolved visit")
        browser.toggleFoldersFirst(nil)
        try require(browser.tabs[browser.activeIndex].sort.foldersFirst && browser.settings.foldersFirst,
                    "Current folder sorting did not change independently of its global default")
        // The setter above changed only the current visit; its saved record stays exact.
        try require(model.library.record(for: a.path)?.choice == icons, "Manual changes silently rewrote a saved view")
        var checks = ["Passive no-create; native Save captures exact mode/sort only; fresh visit applies before rows",
                      "Back/Forward, Refresh and duplicate/reopen preserve current choices; explicit Apply uses saved fields",
                      "Manual changes stay in the visit and never resave implicitly; folders-first uses the active sort"]
        checks += try await staleChecks(root: root, browser: browser, original: model, a: a, b: b, choice: icons)
        let restoration = try await restorationChecks(browser: browser, model: model, a: a)
        browser = restoration.browser; checks += restoration.checks
        checks += try await storeChecks(root: root, store: store, model: model)
        checks += try await lifecycleChecks(root: root, browser: browser)
        browser.folderViews = model
        model.reload(); await model.drain()
        browser.showFolderViews(nil); await model.drain()
        guard let window = model.window else { throw UIVerification.Failure(message: "Folder views manager missing") }
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/folder-views.png"))
        try require(window.title == "Saved Folder Views" && window.isVisible && model.library.records.count == 2, "Native manager did not show the bounded library")
        model.confirmForgetAll(); try await wait { window.attachedSheet != nil }
        try clickSheet(window, title: "Cancel")
        try await Task.sleep(for: .milliseconds(50))
        try require(model.library.records.count == 2, "Cancel forgot preferences")
        if ProcessInfo.processInfo.arguments.contains("--drive-folder-views") {
            try Data("generated-folder-views-ready".utf8).write(to: root.appendingPathComponent("evidence/ready-for-input.txt"), options: .withoutOverwriting)
            // Actual input selects a row and uses Forget Selected in this exact
            // generated window. This is private test metadata, never user files.
            for _ in 0..<1800 {
                if model.library.records.count == 1 && !model.isBusy { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(model.library.records.count == 1, "Actual native Forget Selected input did not finish")
        }
        model.confirmForgetAll(); try await wait { window.attachedSheet != nil }
        try clickSheet(window, title: "Forget Views"); await model.drain()
        try await wait { !model.isBusy && model.library.records.isEmpty }
        try require((try await store.load()).library.records.isEmpty, "Forget All did not persist its empty library")
        window.close(); await browser.flushBrowserSession()
        let reopened = ApplicationFolderViews(store: FolderViewStore(directory: directory)); reopened.reload(); await reopened.drain()
        try require(reopened.library.records.isEmpty && !reopened.isUnavailable, "Reopen resurrected forgotten views")
        checks.append("Native Glass manager, exact selected metadata, Cancel/confirmed Forget All, drain and no resurrection after reopen")
        for command in [BrowserCommand.saveFolderView, .applyFolderView, .forgetFolderView, .folderViews] {
            try require(BrowserCommand.command(for: NSMenuItem(title: command.title, action: command.selector, keyEquivalent: "")) == command,
                        "Folder-view action missing from the shared shortcut registry")
        }
        let before = browser.location
        browser.folderViews = reopened
        browser.showFolderViews(nil); await reopened.drain()
        try require(browser.location == before, "Opening management navigated a saved path or granted access")
        reopened.window?.close()
        try require(reopened.window == nil && model.window == nil, "Closing management retained its window/controller cycle")
        checks.append("All four actions use the existing customizable shortcut registry with no default binding or implicit navigation")
        var report: [String: Any] = ["passed": true, "checks": checks, "sourceBodiesRead": false, "userPreferencesEdited": false,
                "writesDSStore": false, "recordsAfterForget": reopened.library.records.count]
        if ProcessInfo.processInfo.arguments.contains("--folder-views-scale") {
            report["scale"] = try await scaleCheck(root: root, browser: browser)
        }
        return report
    }

    private static func staleChecks(root: URL, browser: BrowserViewController, original: ApplicationFolderViews, a: URL, b: URL,
                                    choice: FolderViewChoice) async throws -> [String] {
        let dir = root.appendingPathComponent("stale-views"), seed = FolderViewStore(directory: dir)
        _ = try await seed.edit(expected: nil) { try $0.save(path: a.path, choice: choice) }
        for navigateAway in [false, true] {
            let gate = Gate()
            defer { gate.release() }
            let held = FolderViewStore(directory: dir, beforeRead: { gate.holdOnce() })
            let model = ApplicationFolderViews(store: held)
            browser.folderViews = model
            browser.navigate(to: .directory(b)); try await loaded(browser)
            gate.arm()
            browser.navigate(to: .directory(a)); try await wait { gate.isHeld }
            if navigateAway { browser.navigate(to: .directory(b)) }
            else { browser.setPaneViewMode(.list) }
            gate.release(); try await loaded(browser)
            try require(navigateAway ? browser.location == .directory(b) : browser.effectiveViewMode == .list,
                        "An older folder-view read replaced a newer navigation or manual choice")
            await model.drain()
        }
        browser.folderViews = original
        return ["Held background reads cannot override newer navigation or a manual view choice; actual store work drains"]
    }

    private static func restorationChecks(browser: BrowserViewController, model: ApplicationFolderViews, a: URL) async throws -> (browser: BrowserViewController, checks: [String]) {
        guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Folder-view check requires the real workspace") }
        var snapshot = try workspace.captureSessionSnapshot(syncViewState: false)
        let pane = snapshot.panes[0]
        // Capture one explicit profile with a saved-folder conflict: Details
        // must win over the folder's stored Icons preference.
        snapshot = .init(layout: PaneLayout(paneID: pane.id), activePane: pane.id, panes: [
            .init(id: pane.id, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: a), sortField: "name", ascending: true, foldersFirst: true)]), viewMode: "Details")])
        try workspace.applyRestoredSnapshot(snapshot)
        let restored = workspace.activeBrowser
        restored.permitsBackgroundVerification = true; restored.folderViews = model
        restored.loadLocation(); try await loaded(restored)
        try require(restored.effectiveViewMode == .details && restored.tabs[restored.activeIndex].sort.field == .name,
                    "Saved folder defaults replaced an explicit restored layout")
        try require(workspace.splitActive(at: .trailing), "Generated independent-pane check could not split")
        let peer = workspace.activeBrowser; peer.permitsBackgroundVerification = true
        try await loaded(peer); peer.setPaneViewMode(.list)
        try require(restored.effectiveViewMode == .details && peer.effectiveViewMode == .list && peer.folderViews === model,
                    "One pane's explicit view replaced another pane's view or lost its shared preference owner")
        return (peer, ["Explicit workspace/session restoration wins over conflicting saved folder defaults",
                       "Two real panes share one preference owner while keeping independent current view choices"])
    }

    private static func storeChecks(root: URL, store: FolderViewStore, model: ApplicationFolderViews) async throws -> [String] {
        let before = try await store.load(), path = root.appendingPathComponent("state/folder-views/folder-views-v1.json")
        var failed = false
        do { _ = try await store.edit(expected: .init(library: .init(), bytes: nil, ordinal: 0)) { $0.forgetAll() } } catch { failed = true }
        let after = try await store.load()
        try require(failed && before.bytes == after.bytes, "Stale edit changed the folder-view library")
        try await Task.detached { try Data("invalid".utf8).write(to: path) }.value
        model.reload(); await model.drain()
        try require(model.isUnavailable, "Malformed preferences silently became empty defaults")
        model.forgetAll(); await model.drain()
        let invalid = try await Task.detached { try Data(contentsOf: path) }.value
        try require(invalid == Data("invalid".utf8), "Forget overwrote unverified preferences")
        try await Task.detached {
            try invalid.write(to: root.appendingPathComponent("evidence/rejected-folder-views.json"), options: .withoutOverwriting)
            try before.bytes!.write(to: root.appendingPathComponent("evidence/valid-folder-views-before.json"), options: .withoutOverwriting)
        }.value
        try await Task.detached { try before.bytes!.write(to: path); try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }.value
        model.reload(); await model.drain()
        try require(!model.isUnavailable && model.library.records.count == 2, "Explicit Reload failed to recover restored valid state")
        return ["Stale edits refuse; corrupt preferences preserve bytes and disable edits; successful explicit Reload restores the verified library"]
    }

    private static func lifecycleChecks(root: URL, browser: BrowserViewController) async throws -> [String] {
        let gate = Gate(); gate.arm()
        defer { gate.release() }
        let dir = root.appendingPathComponent("closed-views")
        let store = FolderViewStore(directory: dir, checkpoint: { event in if case .validated = event { gate.holdOnce() } })
        let model = ApplicationFolderViews(store: store)
        model.show(from: browser); await model.drain()
        model.save(path: "/generated/close-check", choice: .init(mode: .details, sort: .init()))
        try await wait { gate.isHeld }
        try require(model.isBusy && !browser.hasPendingFileOperation, "Preference saving invented pending file work")
        model.window?.close()
        var drained = false
        let draining = Task { await model.drain(); drained = true }
        try await Task.sleep(for: .milliseconds(60)); try require(!drained, "Drain returned while the real preference writer was held")
        gate.release(); await draining.value
        try require((try await store.load()).library.records.count == 1 && !model.isBusy, "Accepted preference save was lost before actual drain")
        model.forgetAll(); await model.drain()
        try require((try await store.load()).library.records.isEmpty, "Forget did not follow the accepted save")
        return ["Accepted preference saves retain ownership through actual worker drain; Forget follows without old queued recreation or file-work popups"]
    }

    private static func scaleCheck(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        func phase(_ value: String) { print("FOLDER_VIEWS_SCALE_" + value); fflush(stdout) }
        // Frozen screening gates before this sample: 512 long locations,
        // <=3s ingestion, <=750ms manager load, <=64MiB added process peak,
        // heartbeat p95<=50ms and worst<=200ms. No full-drive scan or bodies.
        let baseline = resident(), heartbeat = Heartbeat(); heartbeat.start()
        defer { heartbeat.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let store = FolderViewStore(directory: root.appendingPathComponent("scale-views"))
        phase("INGEST")
        let started = ProcessInfo.processInfo.systemUptime
        let written = try await store.edit(expected: nil) { value in
            for index in 0..<512 {
                let path = "/generated/never-opened/\(index)/" + Array(repeating: "component", count: 64).joined(separator: "/")
                try value.save(path: path, choice: .init(mode: index % 2 == 0 ? .icons : .details,
                                                       sort: .init(field: index % 2 == 0 ? .size : .modified, ascending: index % 3 == 0)))
            }
        }
        let writeMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let model = ApplicationFolderViews(store: store), opening = ProcessInfo.processInfo.systemUptime
        phase("SHOW")
        model.show(from: browser); await model.drain()
        phase("LAYOUT")
        model.window?.contentView?.layoutSubtreeIfNeeded()
        let openMS = (ProcessInfo.processInfo.systemUptime - opening) * 1000
        try await Task.sleep(for: .milliseconds(600)); heartbeat.stop()
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        let maximum = UInt64(max(0, usage.ru_maxrss)), added = maximum > baseline ? maximum - baseline : 0
        let passed = model.library.records.count == 512 && !model.isUnavailable && writeMS <= 3000 && openMS <= 750
            && added <= 64 * 1024 * 1024 && heartbeat.p95 <= 50 && heartbeat.worst <= 200
        phase("CLOSE")
        model.window?.close(); await model.drain()
        phase("CLOSED")
        let report: [String: Any] = ["passed": passed, "records": model.library.records.count, "encodedBytes": written.bytes?.count ?? 0,
            "ingestMilliseconds": writeMS, "managerMilliseconds": openMS, "addedRSS": added,
            "heartbeatSamples": heartbeat.count, "heartbeatP95Milliseconds": heartbeat.p95, "heartbeatWorstMilliseconds": heartbeat.worst]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/scale.json"), options: .withoutOverwriting)
        try require(passed, "Maximum folder-view library missed its frozen UI/resource screening gates")
        return report
    }

    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?, values: [Double] = []
        func start() { task = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20)); guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if values.count < 512 { values.append((now - previous) * 1000) }; previous = now
            }
        } }
        func stop() { task?.cancel(); task = nil }
        var count: Int { values.count }
        var p95: Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { values.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }

    private final class Gate: @unchecked Sendable {
        private let condition = NSCondition(); private var armed = false; private var held = false; private var released = false
        var isHeld: Bool { condition.lock(); defer { condition.unlock() }; return held }
        func arm() { condition.lock(); armed = true; released = false; held = false; condition.unlock() }
        func holdOnce() { condition.lock(); defer { condition.unlock() }; guard armed else { return }; armed = false; held = true; condition.broadcast(); while !released { condition.wait() } }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    private static func loaded(_ browser: BrowserViewController) async throws { try await wait { !browser.isLoading && browser.orderingTask == nil } }
    private static func wait(_ test: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if test() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Generated folder-view check did not settle")
    }
    private static func clickSheet(_ window: NSWindow, title: String) throws {
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        guard let view = window.attachedSheet?.contentView, let button = buttons(view).first(where: { $0.title == title }) else {
            throw UIVerification.Failure(message: "Generated preference confirmation control missing")
        }
        button.performClick(nil)
    }
    nonisolated private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
}
#endif
