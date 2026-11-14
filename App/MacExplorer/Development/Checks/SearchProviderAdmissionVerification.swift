#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import Search

/// Retained native controls cannot turn a remote/closed pane into a local query.
@MainActor enum SearchProviderAdmissionVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, owner: BrowserWindowController?, browser: BrowserViewController?, checkpoint = "scope", checks = [String]()
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let admitted = URL(fileURLWithPath: raw), marker = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: raw).appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == "search-provider-admission" && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = admitted; let scope = admitted.appendingPathComponent("source/Search")
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.motion.mode = .off
            let controller = BrowserWindowController(settings: settings); owner = controller
            guard controller.isWorkspacePresentation, let window = controller.window else { throw Failure.scope }
            window.setContentSize(.init(width: 970, height: 650)); window.center(); window.title = "Search provider admission · generated review"
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            controller.browser.readVolumesForVerification = { [] }; checkpoint = "workspace"; controller.beginBrowsing()
            try await wait { controller.workspace.sessionReady }
            let current = controller.browser; browser = current; current.readVolumesForVerification = { [] }; current.permitsBackgroundVerification = true
            current.folderAccess = FolderAccessController(stateDirectory: nil)
            current.navigate(to: .directory(scope)); try await wait { !current.isLoading && current.orderingTask == nil }
            let search = current.metadataSearch
            // Even the expected red state can query only this generated scope.
            search.indexedFixtureScope = try SearchScope(root: scope)
            search.show(scopeIndex: 1, copyFilter: false); search.queryField.stringValue = "Generated"
            let remote: [BrowserLocation] = [
                .smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Generated SMB")),
                .sftp(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Generated SFTP"))]
            for (index, location) in remote.enumerated() {
                checkpoint = "remote-show-\(index)"; current.navigate(to: location)
                try require(current.isRemoteLocation && current.smbTabs.isEmpty && current.sftpTabs.isEmpty)
                search.show(); try require(!search.hasActiveSession && !search.isShowingResults)
                checks.append("Remote Show refuses without a connection")
                for source in [PrivateNameSources.files, .saved, .both] {
                    checkpoint = "remote-submit-\(index)-\(source.rawValue)"
                    search.sources = source; search.scopePopup.selectItem(at: 1); search.queryField.stringValue = "Generated"
                    search.submit()
                    try require(!search.hasActiveSession && !search.isShowingResults && current.location == location)
                }
                checks.append("Retained submit refuses Files/Saved Names/Both in remote pane")
            }
            checkpoint = "local-positive"; current.navigate(to: .directory(scope)); try await wait { !current.isLoading && current.orderingTask == nil }
            search.show(scopeIndex: 0, copyFilter: false); search.sources = .files; search.queryField.stringValue = "Generated-Match"
            search.submit(); try await wait { !search.hasActiveSession }
            try require(search.isShowingResults && current.displayedEntries.map(\.name) == ["Generated-Match.txt"])
            checks.append("Explicit local filename search remains available")
            search.cancel(restoreFolder: true); try await wait { !current.isLoading && current.orderingTask == nil }
            checkpoint = "suspended-submit"; current.suspendBrowser(); search.queryField.stringValue = "Generated"; search.submit()
            try require(!search.hasActiveSession && !search.isShowingResults)
            checks.append("Suspended pane refuses retained submit")
            try write(["passed": true, "checks": checks, "networkConnections": 0, "personalIndexScopes": 0,
                "indexSafetyScopeInstalled": true, "bodyIndexing": false, "savedCatalogSelected": false], root: admitted)
        } catch {
            browser?.metadataSearch.cancel(restoreFolder: false)
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "checkpoint": checkpoint, "line": line, "checks": checks, "errorType": String(reflecting: type(of: error))], root: root) }
        }
        browser?.metadataSearch.cancel(restoreFolder: false); browser?.suspendBrowser(); owner?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-search-provider.json"), options: .withoutOverwriting)
    }
}
#endif
