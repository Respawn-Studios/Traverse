#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SMBBrowserVerification {
    static func run(root: URL, mode: String, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-browser-qualification")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ["pane-owner-preflight", "workspace-preflight", "offline-stop", "tabs", "stop", "disconnect"].contains(mode), "Unadmitted SMB browser review")
        let protocolFixture = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSMBBrowserProtocolFixture") as? Bool == true
        try require((mode == "pane-owner-preflight") == protocolFixture, "Protocol fixture cannot qualify network behavior")
        let evidence = root.appendingPathComponent("evidence")
        if mode == "workspace-preflight" {
            guard let workspace = browser.workspace, let window = browser.view.window as? BrowserWindow else {
                throw UIVerification.Failure(message: "Native workspace missing before SMB admission")
            }
            try require(window.workspace === workspace, "Native workspace window differs")
            browser.permitsBackgroundVerification = true
            let tab = browser.activeID
            try require(workspace.splitActive(at: .trailing), "Offline workspace could not split")
            let destination = workspace.activeBrowser
            destination.permitsBackgroundVerification = true
            try require(workspace.moveTab(tab, from: browser, into: destination, before: nil), "Offline native tab did not move")
            try require(destination.workspace === workspace && destination.tabs.contains(where: { $0.id == tab }), "Offline native tab owner differs")
            destination.closeTab(id: tab)
            return ["passed": true, "mode": mode, "workspaceAttached": true, "splitMoveClose": true,
                "networkConnections": 0, "personalCredentialQueries": 0]
        }
        // Never consume a server connection just to discover the wrong harness.
        if mode == "tabs" { try require(browser.workspace != nil, "Native workspace missing before SMB admission") }
        let password = try await Task.detached { try SMBAuthenticatedVerification.readPrivatePassword() }.value
        let activity = FileActivityGate(maximumActivities: 1)
        let began = ProcessInfo.processInfo.systemUptime
        var ticks = 0
        let heartbeat = Task { while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(10)) } }
        defer { heartbeat.cancel() }
        if mode == "offline-stop" {
            let connecting = Task { try await SMBBrowserSession.connectGenerated(bundleURL: Bundle.main.bundleURL, generatedCase: root, activity: activity, password: password) }
            do { try await waitMarker(evidence.appendingPathComponent("browser-ready.json")) }
            catch {
                connecting.cancel()
                if let late = try? await connecting.value { _ = await late.close() }
                throw error
            }
            connecting.cancel()
            do { let unexpected = try await connecting.value; _ = await unexpected.close(); throw UIVerification.Failure(message: "Stalled negotiation unexpectedly authenticated") }
            catch SMBBrowserFailure.stopped { }
            try require(activity.activeCount == 0, "Signed native cancelled connection retained its activity")
            return ["passed": true, "mode": mode, "activityAfterDrain": activity.activeCount,
                "mainExecutorTicks": ticks, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
                "serverSessions": 0, "personalCredentialQueries": 0]
        }
        let session = try await SMBBrowserSession.connectGenerated(bundleURL: Bundle.main.bundleURL, generatedCase: root, activity: activity, password: password)
        let owner = SMBTabController(session: session, share: try SMBRemoteName("ExplorerQA"))
        var closed: SMBBrowserDrainResult?
        var stage = "root"
        do {
            browser.permitsBackgroundVerification = true; browser.installSMBTab(owner)
            let tab = browser.activeID
            if mode == "pane-owner-preflight" {
                try await wait { session.latest.snapshot?.state == .complete }
                guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Native workspace missing") }
                let originalRead = session.latest.snapshot?.readID
                try require(workspace.splitActive(at: .trailing), "Ownership preflight split failed")
                let destination = workspace.activeBrowser; destination.permitsBackgroundVerification = true
                try require(workspace.moveTab(tab, from: browser, into: destination, before: nil), "Ownership preflight tab move failed")
                try require(workspace.closeActivePane(), "Ownership preflight pane close failed")
                let survivor = workspace.activeBrowser
                try require(survivor.smbTabs[tab] === owner, "Closing pane lost its SMB owner")
                survivor.selectTab(tab)
                try require(owner.session === session && session.latest.snapshot?.readID == originalRead && owner.drain == nil,
                    "Closing pane restarted or closed its SMB connection")
                survivor.closeTab(id: tab); try await wait { owner.drain != nil }
                try require(owner.drain?.ownerReleased == true && activity.activeCount == 0, "Ownership fixture process did not drain")
                return ["passed": true, "mode": mode, "protocolFixtureOnly": true, "paneCloseRetainsOwner": true,
                    "networkConnections": 0, "networkSecurityQualified": false, "personalCredentialQueries": 0]
            }
            if mode != "tabs" {
                stage = "inflight-failure"
                try await waitMarker(evidence.appendingPathComponent("browser-ready.json"))
                if mode == "stop" { owner.rows.onStop?() }
                try await wait { session.latest.failure != nil }
                try require(session.latest.snapshot?.state != .complete && owner.rows.cache.retainedCount == 0,
                    "Interrupted read falsely completed or published rows")
            } else {
                try await wait { session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 3 }
                let first = ProcessInfo.processInfo.systemUptime - began
                try require(owner.rows.table.numberOfRows == 3 && session.latest.security == .encrypted, "Native root/security differs")
                let initialRead = session.latest.snapshot?.readID
                try require(browser.selectedURLs.isEmpty && !browser.commandEnabled(#selector(BrowserViewController.trashSelection(_:)))
                    && !browser.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:)))
                    && !browser.commandEnabled(#selector(BrowserViewController.showQuickLook(_:))), "Remote row gained local file authority")
                let before = browser.tabs.count; browser.duplicateTab(id: tab)
                try require(browser.tabs.count == before, "Remote duplication silently reused a connection")
                let folder = try owner.directoryLocation(components: [SMBRemoteName("Folder")])
                stage = "folder"
                browser.navigate(to: .smb(folder))
                try await wait { session.latest.snapshot?.readID != initialRead && session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 2 }
                let nested = session.latest.snapshot?.readID
                stage = "back"
                browser.goBack(nil)
                try await wait { session.latest.snapshot?.readID != nested && session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 3 }
                for sort in [SMBDirectorySort.name, .size, .modified] {
                    stage = "sort-" + sort.rawValue
                    owner.rows.table.sortDescriptors = [NSSortDescriptor(key: sort.rawValue, ascending: false)]
                    try await wait { owner.rows.lastPageSort == sort && owner.rows.lastPageDescending == true && owner.rows.cache.retainedCount == 3 && !owner.hasPendingPages }
                    try require(owner.rows.table.numberOfRows == 3, "Native page sort changed its count")
                }
                stage = "workspace"
                guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Native workspace missing") }
                stage = "pane-transfer"
                let readBeforeMove = session.latest.snapshot?.readID
                try require(workspace.splitActive(at: .trailing), "Generated workspace could not split")
                let destination = workspace.activeBrowser; destination.permitsBackgroundVerification = true
                try require(destination.location == .computer, "Split silently duplicated a remote connection")
                try require(workspace.moveTab(tab, from: browser, into: destination, before: nil), "Remote tab did not move")
                try require(destination.smbTabs[tab] === owner && owner.session === session && session.latest.snapshot?.readID == readBeforeMove,
                    "Pane move replaced its SMB owner or restarted the read")
                stage = "pane-close"
                try require(workspace.closeActivePane(), "Native workspace could not close the pane")
                let survivor = workspace.activeBrowser
                try require(survivor.smbTabs[tab] === owner && owner.drain == nil && session.latest.snapshot?.readID == readBeforeMove,
                    "Pane close lost its SMB owner or restarted the read")
                survivor.selectTab(tab)
                survivor.view.layoutSubtreeIfNeeded(); owner.rows.table.displayIfNeeded()
                if let window = survivor.view.window { try await UIVerification.snapshot(window, to: evidence.appendingPathComponent("native-browser.png")) }
                stage = "close"
                survivor.closeTab(id: tab)
                try await wait { owner.drain != nil }
                closed = owner.drain
                try require(await SMBBrowserLifetimes.shared.closeAndDrain(), "Closing native tab retained an uncertain worker")
                guard let closed else { throw UIVerification.Failure(message: "Missing native tab close") }
                try verify(closed, session: session, activity: activity)
                return ["passed": true, "mode": mode, "rootCount": 3, "nestedCount": 2, "sortedPages": 3,
                    "firstNativePageMilliseconds": first * 1000, "mainExecutorTicks": ticks, "sameOwnerAfterPaneMove": true,
                    "sameReadAfterPaneMove": true, "sameOwnerAfterPaneClose": true, "localFileCommandsRefused": true, "explicitDuplicateRequired": true,
                    "actualExit": closed.actualExit, "pipeDrained": closed.pipeDrained, "socketAndCatalogDrained": closed.socketAndCatalogDrained,
                    "forcedContainment": closed.forcedContainment, "activityAfterDrain": activity.activeCount,
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "personalCredentialQueries": 0]
            }
            owner.close(); try await wait { owner.drain != nil }; closed = owner.drain
            guard let closed else { throw UIVerification.Failure(message: "Missing interrupted native close") }; try verify(closed, session: session, activity: activity)
            return ["passed": true, "mode": mode, "outcome": session.latest.failure?.rawValue ?? "none",
                "actualExit": closed.actualExit, "pipeDrained": closed.pipeDrained, "socketAndCatalogDrained": closed.socketAndCatalogDrained,
                "forcedContainment": closed.forcedContainment, "activityAfterDrain": activity.activeCount, "mainExecutorTicks": ticks,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "personalCredentialQueries": 0,
                "commands": session.commandCounts ?? []]
        } catch {
            owner.close(); if closed == nil { closed = await session.close() }
            // Controlled stage/counts only: never serialize an arbitrary error,
            // remote name, endpoint or private credential into diagnostics.
            let facts: [String: Any] = ["passed": false, "stage": stage, "cachedRows": owner.rows.cache.retainedCount,
                "activityAfterDrain": activity.activeCount, "actualExit": closed?.actualExit ?? false,
                "socketAndCatalogDrained": closed?.socketAndCatalogDrained ?? false,
                "forcedContainment": closed?.forcedContainment ?? false]
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) {
                try? await Task.detached { try data.write(to: evidence.appendingPathComponent("native-browser-failure.json"), options: .withoutOverwriting) }.value
            }
            throw error
        }
    }
    private static func verify(_ result: SMBBrowserDrainResult, session: SMBBrowserSession, activity: FileActivityGate) throws {
        try require(result.actualExit && result.pipeDrained && result.socketAndCatalogDrained && result.ownerReleased
            && !result.forcedContainment && activity.activeCount == 0, "Signed SMB browser did not actually drain")
        guard let counts = session.commandCounts else { throw UIVerification.Failure(message: "Native numeric command profile missing") }
        try require(counts.count == 19 && counts[14] > 0 && [7, 8, 9, 10, 11, 15, 16, 17, 18].allSatisfy { counts[$0] == 0 },
            "Native read did not prove metadata-only directory work")
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Native SMB browser did not settle")
    }
    private static func waitMarker(_ marker: URL) async throws {
        for _ in 0..<1500 {
            if await Task.detached(operation: { FileManager.default.fileExists(atPath: marker.path) }).value { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: "Controlled SMB interruption did not become active")
    }
}
#endif
