#if DEBUG
import AppKit
import Darwin
import ExplorerCore

/// Generated native fixture and observation only. Actual input comes from CUA;
/// this harness never manufactures key events or writes user files.
@MainActor enum WorkspaceInputAcceptance {
    @MainActor private final class Trace {
        var events: [[String: Any]] = []
        var previous = ""
        var activePanes: Set<UUID> = []
        var maximumTabs = 0
        var minimumPanes = 4
        var previousTick = CACurrentMediaTime(), maximumRawGap = 0.0
        func observe(_ workspace: BrowserWorkspaceController) throws {
            let now = CACurrentMediaTime()
            maximumRawGap = max(maximumRawGap, now - previousTick); previousTick = now
            let ids = workspace.layout.paneIDs
            activePanes.insert(workspace.activePaneID); minimumPanes = min(minimumPanes, ids.count)
            let panes: [[String: Any]] = ids.compactMap { id in
                guard let browser = workspace.browsers[id] else { return nil }
                maximumTabs = max(maximumTabs, browser.tabs.count)
                return ["pane": id.uuidString, "activeTab": browser.activeID.uuidString,
                    "tabIDs": browser.tabs.map { $0.id.uuidString }, "location": browser.location.displayName,
                    "rows": browser.displayedEntries.count,
                    "selectedRows": Array(browser.table.selectedRowIndexes.prefix(16)),
                    "active": workspace.activePaneID == id, "commandFocus": browser.hasFileCommandFocus,
                    "outline": workspace.paneHosts[id]?.showsFocusOutline == true]
            }
            let responder = WorkspaceInputAcceptance.responderPane(workspace)?.uuidString ?? "none"
            let event: [String: Any] = ["activePane": workspace.activePaneID.uuidString, "panes": panes,
                "firstResponderPane": responder]
            let encoded = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            let key = String(decoding: encoded, as: UTF8.self)
            if key != previous {
                guard events.count < 256 else { throw UIVerification.Failure(message: "Input observation bound exceeded") }
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                var observed = event; observed["peakRSSBytes"] = usage.ru_maxrss
                events.append(observed); previous = key
            }
        }
    }
    static func run() async {
        var root: URL?, owner: BrowserWindowController?, failure: String?, inputAssertionsPassed = false
        var footprintPolicy = false
        var memoryPhases: [String: [String: UInt64]] = [:]
        var latestMemory: NativeMemoryObservation?
        var checks: [String] = [], rows: [Int] = [], listingSeconds = 0.0, phases: [String: Int64] = [:]
        let trace = Trace()
        do {
            let admitted = try scope(); root = admitted
            let fixture = try source(in: admitted)
            let focusOnly = ProcessInfo.processInfo.arguments.contains("--workspace-focus-only")
            let memoryProfile = ProcessInfo.processInfo.arguments.contains("--workspace-memory-profile")
            footprintPolicy = ProcessInfo.processInfo.arguments.contains("--workspace-footprint-budget")
            if footprintPolicy {
                let data = try Data(contentsOf: admitted.appendingPathComponent("inputs.json"))
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                try require(!focusOnly && !memoryProfile && value?["memoryPolicy"] as? String == "workspace-footprint-v1"
                    && value?["maximumRSSBytes"] as? Int == 384 * 1024 * 1024
                    && value?["maximumPeakFootprintBytes"] as? Int == 256 * 1024 * 1024,
                    "Footprint policy was not explicitly admitted")
                memoryPhases["beforeWorkspace"] = try NativeMemoryObservation.read().fields
            }
            if memoryProfile {
                let data = try Data(contentsOf: admitted.appendingPathComponent("inputs.json"))
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                try require(value?["memoryProfile"] as? Bool == true && value?["diagnosticCollectionRSSBytes"] as? Int == 384 * 1024 * 1024,
                    "Memory diagnostic scope was not admitted")
            }
            let settings = BrowserSettings(persist: false)
            try await settings.completeInitialSetup(); settings.restoresSession = false
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.folderSummariesEnabled = false; settings.showsDockProgress = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            settings.motion.mode = .full; settings.newTabDestination = .computer
            InterfacePresentation.shared.bind(settings)
            let controller = BrowserWindowController(settings: settings); owner = controller
            guard let window = controller.window, controller.isWorkspacePresentation else {
                throw UIVerification.Failure(message: "Actual workspace window required")
            }
            let workspace = controller.workspace
            workspace.sessionReady = true
            let one = UUID(), two = UUID(), three = UUID(), four = UUID()
            var layout = PaneLayout(paneID: one)
            try layout.split(one, inserting: two, at: .trailing)
            try layout.split(one, inserting: three, at: .bottom)
            try layout.split(two, inserting: four, at: .bottom)
            let panes = try [one, two, three, four].enumerated().map { index, id in
                let name = "Pane " + String(UnicodeScalar(65 + index)!)
                let tab = BrowserTab(location: .directory(fixture.appendingPathComponent("source/" + name)))
                return PaneWorkspaceSnapshot.Pane(id: id,
                    tabs: try .capture([tab, BrowserTab(location: .computer)], activeID: tab.id), viewMode: "Details")
            }
            try workspace.applyRestoredSnapshot(.init(layout: layout, activePane: one, panes: panes))
            for browser in workspace.browsers.values {
                browser.permitsBackgroundVerification = false
                browser.readVolumesForVerification = { [] }
            }
            window.setContentSize(.init(width: 1380, height: 830)); window.center()
            window.title = "Generated four-pane input · " + admitted.lastPathComponent.prefix(8)
            NSApplication.shared.mainMenu = BrowserMenus.applicationMenu(target: workspace.activeBrowser)
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            phases["beforeListings"] = peakRSS()
            let began = CACurrentMediaTime()
            for browser in workspace.browsers.values { browser.loadLocation() }
            try await wait {
                workspace.browsers.values.allSatisfy { !$0.isLoading && $0.orderingTask == nil && $0.displayedEntries.count == 1002 }
            }
            listingSeconds = CACurrentMediaTime() - began
            phases["afterListings"] = peakRSS()
            if footprintPolicy { memoryPhases["afterListings"] = try NativeMemoryObservation.read().fields }
            rows = workspace.layout.paneIDs.compactMap { workspace.browsers[$0]?.displayedEntries.count }
            try require(rows == [1002, 1002, 1002, 1002], "Concurrent pane listing lost rows")
            checks.append("All four actual panes finish exact1,002-entry listings concurrently")
            workspace.activate(workspace.activeBrowser)
            try require(workspace.browsers.values.filter(\.hasFileCommandFocus).count == 1,
                        "Multiple or no command owners in the foreground workspace")
            try require(workspace.paneHosts.values.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .group },
                        "Native pane groups are absent from accessibility")
            checks.append("One active command owner and named accessible native pane groups")
            let before = try workspace.captureSessionSnapshot(syncViewState: false)
            let originalTabs = Set(workspace.browsers.values.flatMap { $0.tabs.map(\.id) })
            try require(!workspace.splitActive(at: .trailing)
                && (try workspace.captureSessionSnapshot(syncViewState: false)) == before, "Fifth pane was admitted")
            checks.append("Fifth-pane refusal preserves the entire current snapshot")
            if focusOnly {
                let browser = workspace.activeBrowser, original = browser.activeID
                browser.newTab(nil)
                try await wait { browser.showsComputerVolumes && !browser.isLoading }
                phases["afterNewTab"] = peakRSS()
                try require(responderPane(workspace) == browser.paneID,
                            "New This Mac tab leaves native keyboard focus in an inactive pane")
                browser.closeTab(id: browser.activeID)
                try await wait { !browser.isLoading }
                browser.selectTab(original)
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.displayedEntries.count == 1002 }
                try require(responderPane(workspace) == browser.paneID,
                            "Returning from This Mac leaves native keyboard focus in an inactive pane")
                checks.append("New/close/select tab preserve actual native first responder in their own pane")
                browser.goComputer(nil)
                try await wait { browser.showsComputerVolumes && !browser.isLoading }
                try require(responderPane(workspace) == browser.paneID, "This Mac navigation loses its pane's native keyboard focus")
                browser.goBack(nil)
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.displayedEntries.count == 1002 }
                try require(responderPane(workspace) == browser.paneID, "Back from This Mac loses its pane's native keyboard focus")
                checks.append("Directory/This Mac/Back replace content without moving focus into another pane")
                phases["afterFocusControls"] = peakRSS()
                for kind in [WorkspaceConnectionBookmark.Kind.smbServer, .sftpServer, .sftpRoute] {
                    let tab = try WorkspaceConnectionBookmark(kind: kind, serverID: UUID(), binding: Data(repeating: 7, count: 32),
                        title: "Generated saved server").disconnectedTab()
                    browser.tabs.append(tab)
                    browser.selectTab(tab.id)
                    try await wait { !browser.isLoading }
                    browser.focusBrowserContent()
                    let responder = window.firstResponder as? NSView
                    let withinContent = responder === browser.activeFileView || responder?.isDescendant(of: browser.activeFileView) == true
                    try require(responderPane(workspace) == browser.paneID && responder?.isHiddenOrHasHiddenAncestor == false && withinContent,
                        "Disconnected location leaves native keyboard focus outside its visible pane")
                    try require(browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty,
                        "Disconnected focus unexpectedly created a network owner")
                    browser.closeTab(id: tab.id)
                    try await wait { !browser.isLoading && browser.orderingTask == nil }
                }
                checks.append("Saved disconnected SMB/SFTP/jump tabs retain visible native focus without connecting")
            } else {
            try write(["ready": true, "rows": rows, "layoutOrder": layout.paneIDs.map(\.uuidString),
                       "activePane": one.uuidString, "actualInputRequired": true], root: admitted, name: "ready")
            trace.previousTick = CACurrentMediaTime()
            let until = ContinuousClock.now.advanced(by: .seconds(240))
            while true {
                // Foundation serialization is test instrumentation. Bound its
                // Objective-C temporaries rather than retaining them across
                // a long async observation session between native input events.
                try autoreleasepool { try trace.observe(workspace) }
                try require(peakRSS() <= (memoryProfile || footprintPolicy ? 384 : 256) * 1024 * 1024,
                    "Four-pane memory bound exceeded during input")
                if footprintPolicy {
                    let sample = try NativeMemoryObservation.read(); latestMemory = sample
                    try require(sample.peakFootprintBytes <= 256 * 1024 * 1024,
                        "Four-pane kernel peak footprint bound exceeded during input")
                }
                let finish = await Task.detached {
                    let file = admitted.appendingPathComponent("evidence/cua-finish.json")
                    guard let facts = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          facts.isRegularFile == true, facts.isSymbolicLink != true, (facts.fileSize ?? 4097) <= 4096,
                          let bytes = try? Data(contentsOf: file),
                          let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                    return value["finished"] as? Bool == true
                }.value
                if finish { break }
                guard ContinuousClock.now < until else { throw UIVerification.Failure(message: "Actual-input deadline expired") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(trace.activePanes.count == 4 && trace.maximumTabs >= 3 && trace.minimumPanes == 3,
                        "Actual input did not exercise all four panes, New Tab and pane teardown")
            try require(trace.events.allSatisfy {
                ($0["firstResponderPane"] as? String) == "none" || ($0["firstResponderPane"] as? String) == ($0["activePane"] as? String)
            }, "Actual input leaves native keyboard focus in an inactive pane")
            try require(trace.events.contains { event in
                guard let panes = event["panes"] as? [[String: Any]] else { return false }
                return panes.contains { ($0["active"] as? Bool) == true && !($0["selectedRows"] as? [Int] ?? []).isEmpty }
            }, "Actual input did not exercise a row selection in the active pane")
            try require(!workspace.preview.isEnabled, "Input/restoration unexpectedly enabled preview body reads")
            let finalTabs = workspace.browsers.values.flatMap { $0.tabs.map(\.id) }
            try require(Set(finalTabs) == originalTabs && finalTabs.count == originalTabs.count,
                "Actual pane close loses or duplicates the original tabs")
            checks.append("Actual input visits all four panes, creates a third tab and closes one pane; preview stays off")
            }
            inputAssertionsPassed = true
        } catch { failure = String(describing: error) }
        if let owner {
            let browsers = Array(owner.workspace.browsers.values)
            let tasks = browsers.flatMap { [$0.listingTask, $0.orderingTask].compactMap { $0 } }
            owner.workspace.suspendWorkspace()
            for task in tasks { await task.value }
            await owner.workspace.flushSession(closingTools: true)
            owner.close()
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if footprintPolicy {
            do {
                let sample = try NativeMemoryObservation.read(); latestMemory = sample
                memoryPhases["afterActualDrain"] = sample.fields
                if sample.peakFootprintBytes > 256 * 1024 * 1024 { failure = failure ?? "Four-pane kernel peak footprint bound exceeded" }
            } catch { failure = failure ?? "Final owned-memory telemetry unavailable" }
        }
        if usage.ru_maxrss > (footprintPolicy ? 384 : 256) * 1024 * 1024 { failure = failure ?? "Four-pane memory bound exceeded" }
        if let root {
            try? write(["passed": failure == nil, "failure": failure as Any, "checks": checks,
                "events": trace.events, "activePanes": trace.activePanes.count, "maximumTabs": trace.maximumTabs,
                "minimumPanes": trace.minimumPanes, "listingRows": rows, "listingSeconds": listingSeconds,
                "maximumRawMainActorGapSeconds": trace.maximumRawGap, "rawGapIncludesMenusAndExternalInput": true,
                "peakRSSBytes": usage.ru_maxrss, "fileOperations": 0, "networkConnections": 0,
                "phasePeakRSSBytes": phases,
                "createdFileNameCells": FileNameCellView.createdCells,
                "createdCutMarkers": FileNameCellView.createdCutMarkers,
                "inputAssertionsPassed": inputAssertionsPassed,
                "memoryPolicy": footprintPolicy ? "workspace-footprint-v1" : "rss-v1",
                "memoryPhases": memoryPhases, "finalMemory": latestMemory?.fields as Any,
                "memoryBarrier": "after actual workspace/listing/order/file-activity drain; before final report and exit",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "automaticPreviewReads": 0, "remainingFileActivity": ApplicationFileActivity.gate.activeCount], root: root, name: "native")
        }
        exit(failure == nil ? 0 : 2)
    }
    private static func peakRSS() -> Int64 {
        var value = rusage(); getrusage(RUSAGE_SELF, &value); return Int64(value.ru_maxrss)
    }
    private static func responderPane(_ workspace: BrowserWorkspaceController) -> UUID? {
        guard let responder = workspace.view.window?.firstResponder as? NSView else { return nil }
        return workspace.layout.paneIDs.first { id in
            workspace.browsers[id].map { responder.isDescendant(of: $0.view) } ?? false
        }
    }
    private static func source(in root: URL) throws -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--workspace-source-case") else { return root }
        guard index + 1 < arguments.count else { throw UIVerification.Failure(message: "Missing source case") }
        let tag = arguments[index + 1]
        guard UUID(uuidString: tag)?.uuidString == tag else { throw UIVerification.Failure(message: "Invalid source case") }
        let fixture = root.deletingLastPathComponent().appendingPathComponent(tag)
        guard fixture.resolvingSymlinksInPath() == fixture,
              let bytes = try? Data(contentsOf: fixture.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              marker["action"] as? String == "workspace-input-acceptance" else { throw UIVerification.Failure(message: "Unmarked source case") }
        return fixture
    }
    private static func scope() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw UIVerification.Failure(message: "Missing scope") }
        let root = URL(fileURLWithPath: text)
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
              root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              marker["action"] as? String == (ProcessInfo.processInfo.arguments.contains("--workspace-footprint-budget")
                ? "workspace-input-footprint-v1" : "workspace-input-acceptance") else { throw UIVerification.Failure(message: "Invalid scope") }
        return root
    }
    private static func write(_ value: [String: Any], root: URL, name: String) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: root.appendingPathComponent("evidence/" + name + ".json"), options: .withoutOverwriting)
    }
    private static func wait(_ predicate: @MainActor () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < until else { throw UIVerification.Failure(message: "Four-pane listing deadline") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func require(_ value: Bool, _ text: String) throws {
        if !value { throw UIVerification.Failure(message: text) }
    }
}
#endif
