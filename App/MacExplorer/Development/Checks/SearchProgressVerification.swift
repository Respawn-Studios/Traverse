#if DEBUG
import AppKit
import ExplorerCore
import FileMemory
@_spi(Qualification) import Search

/// Delays the actual, metadata-only worker and private-name pages in a fresh
/// admitted case. Never fabricates search rows, references or access authority.
@MainActor enum SearchProgressVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-search-progress" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.showsHiddenFiles = true; settings.appearance = .dark; settings.navigationStyle = .glass
        settings.glassFileContent = true; settings.motion.mode = .off
        let owner = BrowserWindowController(settings: settings), browser = owner.browser
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        let names = ApplicationPrivateNames(directory: root.appendingPathComponent("private-names"), settings: settings)
        browser.privateNames = names
        var failures: [String] = [], checks: [String] = [], metrics: [String: Any] = [:]
        var backdrop: NSWindow?
        let activity = FileActivityGate(), heldPages = Hold(), heldEntries = Hold()
        var gates: [VisitGate] = []
        do {
            guard let window = owner.window else { throw UIVerification.Failure(message: "Missing generated search window") }
            window.setFrame(.init(x: 140, y: 140, width: 960, height: 640), display: true)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); owner.beginBrowsing()
            if ProcessInfo.processInfo.arguments.contains("--record-motion") { backdrop = GlassVerification.makeBrowserBackdropWindow(behind: window) }
            try await wait("workspace ready") { owner.workspace.sessionReady }
            browser.navigate(to: .directory(root.appendingPathComponent("source")))
            try await idle(browser)
            let search = browser.metadataSearch
            search.sources = .files
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode
                let gate = VisitGate(); gates.append(gate)
                search.localForVerification = LocalMetadataSearch(activityGate: activity, qualificationVisit: { gate.visit() })
                search.show(scopeIndex: 0, copyFilter: false); search.queryField.stringValue = "Report"; search.submit()
                try await wait("actual first observation held") { gate.count >= 1 }
                try await Task.sleep(for: .milliseconds(280)); gate.first.signal()
                try await wait("progressive first match") {
                    gate.count >= 2 && search.coverage != nil && browser.displayedEntries.count == 1 && browser.orderingTask == nil
                }
                try UIVerification.require(search.coverage?.finishedAt == nil && search.coverage?.isComplete == false
                    && browser.status.stringValue.contains("items seen") && activity.activeCount == 1,
                    "Interim coverage claimed completion, lost its count or released the real worker")
                let oldStop = search.capturedButtonActionForVerification
                let firstURL = browser.displayedEntries[0].url
                let menu = NSMenu(); menu.autoenablesItems = false; search.appendSearchOptions(to: menu)
                try UIVerification.require(menu.items.first?.title == "Stop Search and Keep Results" && menu.items.first?.isEnabled == true,
                    "Native search menu lacks a live Stop action")
                let began = CACurrentMediaTime()
                if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                    window.title = "Search progress · generated review"
                    let report = try await NativeMotionRecorder.record(window: window, root: root, label: "search-" + mode.rawValue) {
                        search.searchButton.performClick(nil)
                    }
                    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/search-" + mode.rawValue + ".json"), options: .withoutOverwriting)
                } else { search.searchButton.performClick(nil) }
                try await wait("Stop keeps a partial row") { !browser.isLoading && browser.orderingTask == nil && search.coverage?.completion == .cancelled }
                try UIVerification.require(browser.displayedEntries.map(\.url) == [firstURL] && activity.activeCount == 1,
                    "Stop discarded a real match or claimed worker drain before the held call returned")
                metrics["stopPresentation" + mode.rawValue + "Milliseconds"] = (CACurrentMediaTime() - began) * 1000
                // Return starts a new generation; an earlier rendered action or
                // menu must never stop that new query, even on the same path.
                search.queryField.stringValue = "Report"; search.submit()
                oldStop?(); menu.performActionForItem(at: 0)
                try UIVerification.require(search.hasActiveSession, "A stale native Stop action stopped the replacement query")
                gate.second.signal()
                try await wait("new query and held worker drain") { !browser.isLoading && browser.orderingTask == nil && activity.activeCount == 0 }
                try UIVerification.require(browser.displayedEntries.count == 12 && search.coverage?.isComplete == true && !gate.timedOut,
                    "Replacement query lost observations or retained an old cancellation")
                search.cancel(); try await idle(browser)
            }
            checks.append("Full/Reduced/Off show actual progressive rows/counts, retain rows on Stop and hold activity until real drain")
            checks.append("Rendered Stop button/menu generations cannot cancel a newer query; the fresh query completes")
            search.localForVerification = nil
            let alpha = root.appendingPathComponent("source/Report 00.txt"), beta = root.appendingPathComponent("source/Report 01.txt")
            _ = try await names.save(AuthoredNames(nickname: "Orion Alpha"), source: alpha, id: nil, revision: nil, access: nil, allowFollowing: true)
            _ = try await names.save(AuthoredNames(nickname: "Orion Beta"), source: beta, id: nil, revision: nil, access: nil, allowFollowing: true)
            search.sources = .saved; search.show(scopeIndex: 0, copyFilter: false)
            var pageCalls = 0
            search.savedNames.beforeLoadedPageForVerification = {
                pageCalls += 1
                if pageCalls == 1 { await heldPages.wait() }
            }
            search.queryField.stringValue = "Orion"; search.submit()
            try await wait("first real saved page held") { heldPages.entered }
            search.searchButton.performClick(nil)
            try UIVerification.require(!search.savedNames.isRunning && search.savedNames.hasWorkerForVerification,
                "Saved Stop released its actual page task early")
            search.queryField.stringValue = "No matching saved item"; search.submit()
            search.queryField.stringValue = "Orion Beta"; search.submit()
            try UIVerification.require(pageCalls == 1 && search.savedNames.isRunning, "Replacement saved queries built another actual reader")
            heldPages.release()
            try await wait("latest saved query publishes") { !browser.isLoading && browser.orderingTask == nil && !search.savedNames.hasWorkerForVerification }
            try UIVerification.require(pageCalls == 2 && browser.displayedEntries.map(\.url) == [beta],
                "Saved query coalescing ran an obsolete pending query or published stale rows")
            checks.append("One real saved-name owner and one latest pending query coalesce repeated submissions")
            search.savedNames.beforeLoadedPageForVerification = nil
            search.savedNames.afterVerifiedEntryForVerification = { if !heldEntries.entered { await heldEntries.wait() } }
            search.queryField.stringValue = "Orion"; search.submit()
            try await wait("verified saved match visible while later work waits") {
                heldEntries.entered && browser.displayedEntries.count == 1 && browser.orderingTask == nil
            }
            let retained = browser.displayedEntries[0].url
            guard let remembered = search.savedNames.matches[retained] else { throw UIVerification.Failure(message: "Generated saved match missing") }
            search.searchButton.performClick(nil)
            try await wait("saved Stop preserves observed match") { !browser.isLoading && browser.orderingTask == nil }
            try UIVerification.require(browser.displayedEntries.map(\.url) == [retained] && search.savedNames.status.contains("stopped")
                && search.savedNames.hasWorkerForVerification, "Saved Stop lost the verified row or its actual worker")
            let forget = Task { try await names.forget(remembered.id) }
            try await wait("Forget withdraws stopped display") { browser.rawEntries.isEmpty && search.queryField.stringValue.isEmpty }
            heldEntries.release()
            let forgotten = try await forget.value
            await search.savedNames.drain()
            try UIVerification.require(forgotten == .forgotten && search.savedNames.matches.isEmpty && browser.rawEntries.isEmpty,
                "Forget failed to drain/withdraw a stopped saved-name match")
            checks.append("Stopped verified names retain display authority; real Forget withdraws rows and text before durable drain")
            search.savedNames.afterVerifiedEntryForVerification = nil
            search.sources = .files
            let navigationGate = VisitGate(); gates.append(navigationGate)
            search.localForVerification = LocalMetadataSearch(activityGate: activity, qualificationVisit: { navigationGate.visit() })
            search.queryField.stringValue = "Report"; search.submit()
            try await wait("navigation case held") { navigationGate.count == 1 }
            browser.navigate(to: .computer)
            navigationGate.releaseAll()
            try await wait("navigation discards pending search") { !browser.isLoading && activity.activeCount == 0 }
            try UIVerification.require(browser.location == .computer && !search.isShowingResults && !navigationGate.timedOut,
                "A late search publication replaced newer navigation")
            checks.append("Newer This Mac navigation rejects late search publications after actual worker drain")
        } catch { failures.append(String(describing: error)) }
        gates.forEach { $0.releaseAll() }; heldPages.release(); heldEntries.release()
        browser.metadataSearch.cancel(restoreFolder: false); await browser.metadataSearch.savedNames.drain()
        await names.close()
        do { try await wait("all actual metadata activity drained") { activity.activeCount == 0 } }
        catch { failures.append(String(describing: error)) }
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close(); backdrop?.close()
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics, "generatedOnly": true, "personalCatalogs": 0, "networkRequests": 0,
            "drained": activity.activeCount == 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func idle(_ browser: BrowserViewController) async throws {
        try await wait("generated folder listing settles") { !browser.isLoading && browser.orderingTask == nil }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), message)
    }
    @MainActor private final class Hold {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private final class VisitGate: @unchecked Sendable {
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var visits = 0, timeout = false
        var count: Int { lock.withLock { visits } }
        var timedOut: Bool { lock.withLock { timeout } }
        func visit() {
            let value = lock.withLock { visits += 1; return visits }
            guard value <= 2 else { return }
            if (value == 1 ? first : second).wait(timeout: .now() + 8) != .success { lock.withLock { timeout = true } }
        }
        func releaseAll() { first.signal(); second.signal() }
    }
}
#endif
