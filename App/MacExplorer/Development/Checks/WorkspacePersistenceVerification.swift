#if DEBUG
import AppKit
import ExplorerCore

/// Real, isolated v2 storage plus deterministic startup-result races. The only
/// filesystem mutations belong to the marked fixture; UI stays on MainActor.
@MainActor
enum WorkspacePersistenceVerification {
    private struct Document: Codable, Sendable {
        let owner: String
        let snapshot: PaneWorkspaceSnapshot
    }
    @MainActor
    private final class RestoreBarrier {
        var entered = false
        var returned = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            returned = true
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.pathComponents.contains(".build") else {
            throw UIVerification.Failure(message: "Workspace persistence verification requires its explicit ignored fixture root.")
        }
        let owned = testRoot.appendingPathComponent("workspace-persistence-\(UUID().uuidString)", isDirectory: true)
        let firstFolder = owned.appendingPathComponent("Folder A", isDirectory: true)
        let secondFolder = owned.appendingPathComponent("Folder B", isDirectory: true)
        try await Task.detached {
            guard testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
                throw UIVerification.Failure(message: "Workspace persistence fixture root was redirected.")
            }
            let fm = FileManager()
            try fm.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-workspace-persistence-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try fm.createDirectory(at: firstFolder, withIntermediateDirectories: false)
            try fm.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        }.value
        var firstTab = BrowserTab(location: .computer)
        firstTab.navigate(to: .directory(firstFolder))
        firstTab.filter = "remembered-first"
        firstTab.sort = DirectorySort(field: .size, ascending: false)
        var secondTab = BrowserTab(location: .directory(secondFolder))
        secondTab.filter = "remembered-second"
        let firstSession = try WorkspaceSession.capture([firstTab, BrowserTab(location: .computer)], activeID: firstTab.id)
        let secondSession = try WorkspaceSession.capture([secondTab], activeID: secondTab.id)
        let firstID = UUID(), secondID = UUID()
        var layout = PaneLayout(paneID: firstID)
        try layout.split(firstID, inserting: secondID, at: .trailing)
        let snapshot = PaneWorkspaceSnapshot(layout: layout, activePane: secondID, panes: [
            .init(id: firstID, tabs: firstSession, viewMode: BrowserViewMode.details.rawValue),
            .init(id: secondID, tabs: secondSession, viewMode: BrowserViewMode.icons.rawValue)
        ], sidebar: .init(isCollapsed: true, expandedWidth: 263))
        try snapshot.validate()
        var checks: [String] = []

        let savedState = owned.appendingPathComponent("v2-state", isDirectory: true)
        let persistence = BrowserWorkspacePersistence(stateDirectory: savedState)
        _ = await persistence.restore(enabled: true, legacyPane: firstID, viewMode: BrowserViewMode.details.rawValue)
        persistence.record(snapshot)
        try require(await persistence.flush() == nil, "V2 workspace save failed")
        let reader = BrowserWorkspacePersistence(stateDirectory: savedState)
        let restored = await reader.restore(enabled: true, legacyPane: UUID(), viewMode: BrowserViewMode.list.rawValue)
        try require(restored == snapshot, "V2 round trip lost pane layout, active pane, independent visits or view modes")
        checks.append("V2 storage round trip preserves multi-pane layout, active pane, independent visits/filter/sort, per-pane view mode and collapsed sidebar width")

        let migrationState = owned.appendingPathComponent("legacy-state", isDirectory: true)
        let legacyBytes = try await Task.detached {
            let store = BrowserSessionStore(migrationState)
            let data = try store.encoded(firstSession)
            try store.save(data)
            return data
        }.value
        let migration = BrowserWorkspacePersistence(stateDirectory: migrationState)
        let importedID = UUID()
        let imported = await migration.restore(enabled: true, legacyPane: importedID, viewMode: BrowserViewMode.list.rawValue)
        try require(imported?.layout.paneIDs == [importedID] && imported?.activePane == importedID
                    && imported?.panes.first?.tabs == firstSession && imported?.panes.first?.viewMode == BrowserViewMode.list.rawValue,
                    "Legacy import lost visit state or synthesized the wrong pane")
        guard let imported else { throw UIVerification.Failure(message: "Legacy import was absent") }
        migration.record(imported)
        try require(await migration.flush() == nil, "Imported workspace could not be saved as v2")
        let legacyUnchanged = try await Task.detached {
            try Data(contentsOf: migrationState.appendingPathComponent("browser-session-v1.json")) == legacyBytes
        }.value
        try require(legacyUnchanged, "V2 migration changed its legacy evidence")
        checks.append("Legacy v1 imports once into a single pane and remains byte-identical after v2 save")

        for _ in 0..<100 { migration.record(snapshot) }
        migration.setEnabled(false)
        migration.record(snapshot)
        try require(await migration.flush() == nil, "Disable failed to drain queued v2 writes")
        let disabledAbsent = await Task.detached {
            !FileManager().fileExists(atPath: migrationState.appendingPathComponent("browser-workspace-v2.json").path)
                && !FileManager().fileExists(atPath: migrationState.appendingPathComponent("browser-session-v1.json").path)
        }.value
        try require(disabledAbsent, "A queued save resurrected disabled workspace or legacy data")
        checks.append("Disable drains the FIFO writer and removes both owned versions without queued-save resurrection")

        let newer = PaneWorkspaceSnapshot(layout: snapshot.layout, activePane: snapshot.activePane, panes: snapshot.panes, version: 99)
        let newerBytes = try JSONEncoder().encode(Document(owner: "mac-explorer-pane-workspace", snapshot: newer))
        for (label, bytes) in [("corrupt", Data("{invalid-generated-snapshot".utf8)), ("newer", newerBytes)] {
            let state = owned.appendingPathComponent(label, isDirectory: true)
            try await Task.detached {
                let legacy = BrowserSessionStore(state)
                try legacy.save(legacy.encoded(firstSession))
                try bytes.write(to: state.appendingPathComponent("browser-workspace-v2.json"), options: .withoutOverwriting)
            }.value
            let guarded = BrowserWorkspacePersistence(stateDirectory: state)
            let value = await guarded.restore(enabled: true, legacyPane: UUID(), viewMode: BrowserViewMode.details.rawValue)
            try require(value == nil && guarded.lastFailure != nil, "Invalid v2 fell back to legacy or hid its failure")
            guarded.record(snapshot)
            try require(await guarded.flush() != nil, "Invalid v2 was overwritten by save")
            guarded.setEnabled(false)
            try require(await guarded.flush() != nil, "Invalid v2 was silently forgotten")
            let preserved = try await Task.detached {
                try Data(contentsOf: state.appendingPathComponent("browser-workspace-v2.json")) == bytes
            }.value
            try require(preserved, "Invalid or newer v2 bytes changed")
            checks.append("\(label.capitalized) v2 refuses legacy fallback, overwrite and deletion while preserving exact bytes")
        }

        // Each startup owns its own state copy: later UI recording cannot change
        // the common saved fixture used by the next deterministic race.
        for scenario in ["restore", "filter", "sort", "view-mode", "closing"] {
            let state = owned.appendingPathComponent("startup-\(scenario)", isDirectory: true)
            let seed = BrowserWorkspacePersistence(stateDirectory: state)
            _ = await seed.restore(enabled: true, legacyPane: UUID(), viewMode: BrowserViewMode.details.rawValue)
            seed.record(snapshot)
            try require(await seed.flush() == nil, "Startup fixture seed failed")
            let settings = BrowserSettings(persist: false)
            settings.restoresSession = true
            settings.autoRefreshFolders = false
            settings.reviewsRecoveryAtStartup = false
            settings.showsDockProgress = false
            settings.viewMode = .details
            let browser = BrowserViewController(settings: settings)
            browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            let initialTab = BrowserTab(location: .directory(firstFolder))
            browser.tabs = [initialTab]; browser.activeID = initialTab.id
            let workspace = BrowserWorkspaceController(primaryBrowser: browser)
            workspace.persistence = BrowserWorkspacePersistence(stateDirectory: state)
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentViewController = workspace
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.contentView?.layoutSubtreeIfNeeded()
            let barrier = RestoreBarrier()
            workspace.persistence.beforeRestoreResult = { await barrier.wait() }
            defer {
                barrier.release()
                workspace.persistence.beforeRestoreResult = nil
                workspace.isClosing = true
                workspace.preview.setEnabled(false)
                for pane in workspace.browsers.values { pane.suspendBrowser() }
                window.close()
            }
            if scenario == "restore" { workspace.preview.setEnabled(true) }
            workspace.begin()
            try await waitUntil("Startup did not reach delayed restore result") { barrier.entered }
            switch scenario {
            case "filter": browser.tabs[browser.activeIndex].filter = "new-owner-edit"
            case "sort": browser.tabs[browser.activeIndex].sort = DirectorySort(field: .size, ascending: false)
            case "view-mode": browser.paneViewMode = .icons
            case "closing": workspace.suspendWorkspace()
            default: break
            }
            let edited = try workspace.captureSessionSnapshot(syncViewState: false)
            barrier.release()
            try await waitUntil("Delayed restore did not return") { barrier.returned }
            if scenario == "closing" {
                _ = await workspace.persistence.flush()
                try require(!workspace.sessionReady && workspace.primaryBrowser === browser
                            && workspace.layout.paneIDs == [browser.paneID], "Closing workspace applied a delayed restore")
                checks.append("Closing a workspace suppresses its already-read delayed restoration")
                workspace.persistence.beforeRestoreResult = nil
                workspace.resumeWorkspace()
                try await waitUntil("Reopened workspace did not complete a fresh startup restore") { workspace.sessionReady }
                try require(workspace.layout == snapshot.layout && workspace.activePaneID == snapshot.activePane
                            && workspace.browsers.count == 2 && !workspace.preview.isEnabled
                            && workspace.sidebarSnapshot == snapshot.sidebar,
                            "Reopening after interrupted startup failed to restore the saved panes")
                checks.append("Reopening after interrupted startup restores two panes, persistence readiness and collapsed sidebar width with preview off")
            } else {
                try await waitUntil("Startup session did not become ready") { workspace.sessionReady }
                if scenario == "restore" {
                    try require(workspace.layout == snapshot.layout && workspace.activePaneID == snapshot.activePane
                                && workspace.browsers.count == 2 && !workspace.preview.isEnabled
                                && workspace.sidebarSnapshot == snapshot.sidebar,
                                "Startup did not restore multi-pane layout with preview off")
                    checks.append("Real startup restores v2 pane identity/layout and collapsed sidebar width while turning inline preview off")
                } else {
                    try require(workspace.primaryBrowser === browser && workspace.layout.paneIDs == [browser.paneID]
                                && (try workspace.captureSessionSnapshot(syncViewState: false)) == edited,
                                "Delayed startup replaced a newer UI edit")
                    checks.append("A \(scenario) edit made while startup restore is delayed wins over the saved workspace")
                }
            }
        }
        return checks
    }

    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(condition(), message)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
}
#endif
