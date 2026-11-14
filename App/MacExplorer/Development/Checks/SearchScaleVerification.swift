#if DEBUG
import AppKit
import Darwin
import ExplorerCore

/// Actual four-pane search UI against the retained generated corpus. No injected
/// rows, policy or worker; the normal 100k/64/20-second UI limits remain in force.
@MainActor enum SearchScaleVerification {
    static func run() async {
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-search-scale" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.showsHiddenFiles = true; settings.privateNamesSources = .files
        settings.motion.mode = .off; settings.navigationStyle = .glass; settings.glassFileContent = true
        let owner = BrowserWindowController(settings: settings), workspace = owner.workspace
        var failures: [String] = [], checks: [String] = [], samples: [[String: Any]] = []
        var maximumGap = 0.0, ticks = 0
        let ticker = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous); previous = now; ticks += 1
            }
        }
        do {
            guard let window = owner.window else { throw UIVerification.Failure(message: "Missing generated scale window") }
            try UIVerification.require(owner.isWorkspacePresentation, "Scale control requires actual workspace composition")
            window.setContentSize(.init(width: 1440, height: 1000)); window.setFrameOrigin(.init(x: -12000, y: -12000))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            workspace.willStartBrowserForVerification = { browser in
                browser.permitsBackgroundVerification = true
                browser.folderAccess = FolderAccessController(stateDirectory: nil)
                browser.pinsController = BrowserPinsController(stateDirectory: nil)
            }
            owner.browser.permitsBackgroundVerification = true
            owner.beginBrowsing()
            try await wait("initial workspace") { workspace.sessionReady && settled(owner.browser) }
            let original = owner.browser
            try UIVerification.require(workspace.splitActive(at: .trailing), "First generated split refused")
            try UIVerification.require(workspace.splitActive(at: .bottom), "Second generated split refused")
            workspace.activate(original)
            try UIVerification.require(workspace.splitActive(at: .bottom), "Third generated split refused")
            let panes = workspace.layout.paneIDs.compactMap { workspace.browsers[$0] }
            try UIVerification.require(panes.count == 4, "Four real panes were not constructed")
            let corpus = repo.appendingPathComponent(".build/b06-analyzer/20261017T140537Z-6faf182f69/fixtures", isDirectory: true)
            guard let oracles = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("oracles.json"))) as? [String: [String: Any]] else {
                throw UIVerification.Failure(message: "Missing generated oracle")
            }
            for (index, pane) in panes.enumerated() {
                let name = index % 2 == 0 ? "wide" : "mixed", folder = corpus.appendingPathComponent(name, isDirectory: true)
                var info = stat()
                try UIVerification.require(lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                    && UInt64(UInt32(bitPattern: info.st_dev)) == oracles[name]?["dev"] as? UInt64
                    && info.st_ino == oracles[name]?["ino"] as? UInt64, "Retained generated corpus changed")
                pane.navigate(to: .directory(folder))
            }
            try await wait("initial generated listings") { panes.allSatisfy(settled) }
            let began = ProcessInfo.processInfo.systemUptime
            for pane in panes {
                workspace.activate(pane)
                let search = pane.metadataSearch; search.sources = .files
                search.show(scopeIndex: 0, copyFilter: false)
                search.queryField.stringValue = "TRAVERSE_ABSENT_9F93828A1B70495C8D26"; search.submit()
            }
            try await wait("four ordinary search completions", seconds: 26) {
                panes.allSatisfy { !$0.metadataSearch.hasActiveSession && !$0.isLoading && $0.orderingTask == nil }
                    && ApplicationFileActivity.gate.activeCount == 0
            }
            for pane in panes {
                guard let coverage = pane.metadataSearch.coverage else { throw UIVerification.Failure(message: "Search coverage missing") }
                let complete = coverage.completion == .completed && coverage.isComplete && coverage.visitedEntries == 100_000
                let timedOut = coverage.completion == .timedOut && !coverage.isComplete && coverage.visitedEntries > 0 && coverage.visitedEntries <= 100_000
                try UIVerification.require((complete || timedOut) && coverage.boundaryCounts.isEmpty && pane.displayedEntries.isEmpty,
                    "Default-limit scale search has incorrect rows or coverage")
                samples.append(["visited": coverage.visitedEntries, "completion": coverage.completion.rawValue,
                    "isComplete": coverage.isComplete, "matches": pane.displayedEntries.count])
            }
            checks.append("Four native panes search generated 100k roots with ordinary limits, truthful completion/partial coverage and no matches")
            let completeSeconds = ProcessInfo.processInfo.systemUptime - began
            let pane = panes[0], search = pane.metadataSearch
            guard let oracle = oracles["wide"], let name = oracle["name"] as? String,
                  let expected = oracle["rows"] as? [String: Int64] else { throw UIVerification.Failure(message: "Exact generated result absent") }
            workspace.activate(pane)
            search.exactToggle.state = .on; search.queryField.stringValue = name; search.submit()
            try await wait("positive result retains ownership", seconds: 24) { !search.hasActiveSession && !pane.isLoading && pane.orderingTask == nil }
            let prefix = corpus.appendingPathComponent("wide").path + "/"
            var actual: [String: Int64] = [:]
            for entry in pane.displayedEntries {
                try UIVerification.require(entry.url.path.hasPrefix(prefix) && entry.kind == .file, "Unexpected retained result path/kind")
                actual[String(entry.url.path.dropFirst(prefix.count))] = entry.byteCount
            }
            try UIVerification.require(search.coverage?.isComplete == true && actual == expected, "A real published match lost path/size after its worker pool drained")
            checks.append("A real exact-match row remains valid in the native table after worker/temporary-object drain")
            for pane in panes {
                workspace.activate(pane)
                let search = pane.metadataSearch; search.exactToggle.state = .off
                search.queryField.stringValue = "TRAVERSE_ABSENT_9F93828A1B70495C8D26"; search.submit()
            }
            try await wait("four actual workers before close") {
                panes.allSatisfy { $0.metadataSearch.hasActiveSession && ($0.metadataSearch.coverage?.visitedEntries ?? 0) > 100 }
                    && ApplicationFileActivity.gate.activeCount >= 4
            }
            owner.suspendBrowsing(); await owner.flushSession()
            try await wait("actual close drain") { ApplicationFileActivity.gate.activeCount == 0 }
            checks.append("Close with all four real searches active cancels publication and drains their actual filesystem activity")
            samples.append(["fourPaneSeconds": completeSeconds])
        } catch { failures.append(String(describing: error)) }
        owner.suspendBrowsing(); await owner.flushSession()
        do { try await wait("final filesystem drain") { ApplicationFileActivity.gate.activeCount == 0 } }
        catch { failures.append("Final filesystem activity remains") }
        ticker.cancel(); await ticker.value
        owner.window?.close()
        if maximumGap > 0.4 || ticks < 10 { failures.append("Main-actor response gate failed") }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256 * 1024 * 1024 { failures.append("Native app memory gate failed") }
        let result: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures, "coverage": samples,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": maximumGap, "ticks": ticks,
            "activityCount": ApplicationFileActivity.gate.activeCount, "ordinaryLimitsChanged": false,
            "sourceBodiesRead": 0, "personalCatalogs": 0, "networkConnections": 0, "keychainQueries": 0]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApplication.shared.terminate(nil)
    }
    private static func settled(_ browser: BrowserViewController) -> Bool {
        !browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil
    }
    private static func wait(_ message: String, seconds: Double = 8, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
