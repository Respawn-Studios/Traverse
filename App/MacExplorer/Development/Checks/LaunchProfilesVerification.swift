#if DEBUG
import AppKit
import ExplorerCore

@MainActor enum LaunchProfilesVerification {
    static func run(root: URL, workspace: BrowserWorkspaceController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-continuity-management")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Profile QA needs an admitted generated root")
        let state = root.appendingPathComponent("profiles"), store = LaunchProfileStore(directory: root.appendingPathComponent("profiles"))
        workspace.profileWorkspaceStore = WorkspaceProfileStore(directory: root.appendingPathComponent("profile-working"))
        let absent = try await store.load()
        try UIVerification.require(!absent.exists && !FileManager().fileExists(atPath: state.path), "Passive profile read wrote storage")
        let one = UUID(), two = UUID(), folder = root.appendingPathComponent("source/Folder A")
        var layout = PaneLayout(paneID: one); try layout.split(one, inserting: two, at: .trailing)
        let sample = PaneWorkspaceSnapshot(layout: layout, activePane: two, panes: [
            .init(id: one, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: folder), filter: "not retained"),
                .init(location: .init(kind: .computer))], activeTab: 1), viewMode: "Icons"),
            .init(id: two, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: root.appendingPathComponent("source/Missing")))]), viewMode: "Details")])
        let saved = try await store.edit(expected: nil) { try $0.add(name: "Studio", snapshot: sample) }
        let profile = saved.library.profiles[0]
        try UIVerification.require(profile.snapshot.panes[0].tabs.tabs[0].filter.isEmpty, "Save retained an unrequested filter")
        let bytes = try await Task.detached { try Data(contentsOf: state.appendingPathComponent("launch-profiles-v1.json")) }.value
        var refused = false
        do { _ = try await store.edit(expected: nil) { try $0.remove(profile.id) } } catch { refused = true }
        try UIVerification.require(refused, "Stale profile mutation was admitted")
        let unchanged = try await Task.detached { try Data(contentsOf: state.appendingPathComponent("launch-profiles-v1.json")) == bytes }.value
        try UIVerification.require(unchanged, "Stale profile edit changed data")
        try await verifyInvalidCopies(root: root, bytes: bytes)
        try await verifyExpectedVersion(root: root, saved: saved.library)
        try await verifyStartup(root: root, store: store, profile: profile)
        let snapshotChecks = try await SnapshotIntegrityVerification.run(in: root)
        let legacyChecks = try await WorkspacePersistenceVerification.run(in: root)
        let settings = workspace.primaryBrowser.settings
        var legacy = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as! [String: Any]
        legacy.removeValue(forKey: "startupMode"); legacy.removeValue(forKey: "startupProfileID"); legacy["restoresSession"] = true; legacy["version"] = 16
        let migrated = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: legacy))
        try UIVerification.require(migrated.startupMode == .lastSession && migrated.restoresSession, "Legacy Reopen preference did not migrate")
        try await settings.chooseStartup(.profile, profile: profile.id)
        let roundTrip = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try UIVerification.require(roundTrip.startupMode == .profile && !roundTrip.restoresSession && roundTrip.startupProfileID == profile.id,
            "Selected profile preference did not round-trip")
        try await verifyStartupPicker(root: root, workspace: workspace)
        try await wait { workspace.sessionReady }
        workspace.launchProfileStore = store
        workspace.showLaunchProfiles()
        let model = workspace.launchProfiles
        await model.drain()
        try UIVerification.require(model.profiles.count == 1 && model.selection?.id == profile.id, "Native profile library did not load")
        await workspace.flushSession()
        try UIVerification.require(workspace.launchProfilesWindow != nil && model.profiles.count == 1,
            "Routine workspace flush closed the profile manager")
        if workspace.primaryBrowser.isControlledVerification { workspace.launchProfilesWindow?.window?.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        let coordinator = workspace.primaryBrowser.operationCoordinator, reservation = UUID()
        try UIVerification.require(coordinator.beginPreparation(owner: reservation), "Could not establish generated busy interval")
        let before = try workspace.captureSessionSnapshot(syncViewState: false)
        refused = false
        do { try workspace.openLaunchProfile(profile) } catch { refused = true }
        coordinator.finishPreparation(owner: reservation)
        try UIVerification.require(refused && (try workspace.captureSessionSnapshot(syncViewState: false)) == before, "Busy profile open replaced browser hosts")
        model.openSelected()
        try await wait { model.window?.attachedSheet != nil }
        try clickSheet(model.window, title: "Cancel")
        try await Task.sleep(for: .milliseconds(80))
        try UIVerification.require((try workspace.captureSessionSnapshot(syncViewState: false)) == before, "Cancel changed the current layout")
        model.openSelected()
        try await wait { model.window?.attachedSheet != nil }
        try clickSheet(model.window, title: "Open Profile")
        try await wait { workspace.browsers.count == 2 && workspace.launchProfilesWindow == nil }
        try UIVerification.require(workspace.activePaneID == two && workspace.browsers[one]?.tabs.count == 2
            && workspace.browsers[two]?.location == .directory(root.appendingPathComponent("source/Missing")), "Native apply lost active/missing locations or tabs")
        for browser in workspace.browsers.values { browser.permitsBackgroundVerification = true }
        try await wait { workspace.browsers.values.allSatisfy { !$0.isLoading && $0.orderingTask == nil } }
        try UIVerification.require(workspace.preview.isEnabled == false, "Profile automatically enabled a preview")
        workspace.showLaunchProfiles(); await model.drain()
        model.saveCurrent(name: "Daily", includeFilters: false, atLaunch: true)
        workspace.launchProfilesWindow?.close()
        await model.drain()
        let afterClosedSave = try await store.load()
        try UIVerification.require(afterClosedSave.library.profiles.count == 2 && settings.startupMode == .profile
            && afterClosedSave.library.profiles.contains(where: { $0.id == settings.startupProfileID && $0.name == "Daily" }),
            "Close lost a submitted save/startup intent")
        workspace.showLaunchProfiles(); await model.drain()
        model.selected = settings.startupProfileID
        model.rename(to: "Daily work"); await model.drain()
        try UIVerification.require(model.selection?.name == "Daily work", "Native rename failed")
        try await Task.sleep(for: .milliseconds(400)) // Let the accepted page entrance finish before compositor capture.
        if let window = workspace.launchProfilesWindow?.window {
            window.contentView?.layoutSubtreeIfNeeded()
            if workspace.primaryBrowser.isControlledVerification { try await UIVerification.snapshot(window, to: root.appendingPathComponent("profiles-native.png")) }
            else { try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("profiles-native.png")) }
        }
        model.removeSelected(); await model.drain()
        try UIVerification.require(model.profiles.count == 1 && settings.startupMode == .computer && settings.startupProfileID == nil,
            "Deleting a launch profile left a stale active default")
        workspace.launchProfilesWindow?.close(); await model.drain()
        await workspace.flushSession()
        try UIVerification.require(FileManager().fileExists(atPath: folder.path), "Profile actions mutated a source directory")
        return ["passed": true, "metadataOnly": true, "checks": ["Passive read creates nothing", "Atomic explicit save and stale edit refusal",
            "Newer/corrupt preservation and exact previous-version guard", "Legacy and selected-profile preferences",
            "Native two-pane/active-tab/missing-folder apply", "Actual Open/Cancel sheet buttons and busy refusal",
            "Submitted save/startup drains after close", "Rename/delete and launch-default fallback",
            "Selected/missing startup; newer navigation and preference win",
            ProcessInfo.processInfo.arguments.contains("--drive-startup-picker") ? "Actual native startup-picker input" : "Native General factory"],
            "snapshotRegressions": snapshotChecks, "legacyWorkspaceRegressions": legacyChecks,
            "notExercised": ["Power loss", "Physical profile-list pointer selection"]]
    }
    private static func verifyStartupPicker(root: URL, workspace: BrowserWorkspaceController) async throws {
        let settings = workspace.primaryBrowser.settings
        let window = BrowserSettingsWindow.make(workspace.makeWorkspaceSettingsView())
        window.title = "Startup picker · generated " + root.lastPathComponent.prefix(8)
        defer { window.close() }
        if !workspace.primaryBrowser.isControlledVerification { window.center(); window.makeKeyAndOrderFront(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        // SwiftUI's current menu picker need not expose an NSPopUpButton.
        // Actual input qualification uses its public accessibility surface;
        // controlled store tests do not claim synthetic button delivery here.
        if ProcessInfo.processInfo.arguments.contains("--drive-startup-picker") {
            try UIVerification.require(window.isVisible, "Picker input qualification requires its visible generated window")
            try JSONSerialization.data(withJSONObject: ["window": window.windowNumber, "title": window.title])
                .write(to: root.appendingPathComponent("picker-ready"), options: .withoutOverwriting)
            for choice in [BrowserStartupMode.lastSession, .computer, .profile] {
                let deadline = ProcessInfo.processInfo.systemUptime + 90
                while settings.startupMode != choice || settings.changingStartup {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: "Native startup picker input timed out") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        if window.isVisible {
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(350)) // A newly ordered window needs a compositor frame.
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("startup-settings-native.png"))
        }
    }
    private static func verifyInvalidCopies(root: URL, bytes: Data) async throws {
        try await Task.detached {
            var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; value["version"] = 99
            for (name, data) in [("corrupt", Data("{invalid".utf8)), ("newer", try JSONSerialization.data(withJSONObject: value))] {
                let directory = root.appendingPathComponent(name)
                try FileManager().createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try data.write(to: directory.appendingPathComponent("launch-profiles-v1.json"), options: .withoutOverwriting)
            }
        }.value
        for name in ["corrupt", "newer"] {
            let directory = root.appendingPathComponent(name), store = LaunchProfileStore(directory: root.appendingPathComponent(name))
            let file = directory.appendingPathComponent("launch-profiles-v1.json")
            let before = try await Task.detached { try Data(contentsOf: file) }.value
            var refused = false
            do { _ = try await store.load() } catch { refused = true }
            try UIVerification.require(refused, "Unusable profile document was accepted")
            refused = false
            do { _ = try await store.edit(expected: nil) { _ in } } catch { refused = true }
            let after = try await Task.detached { try Data(contentsOf: file) }.value
            try UIVerification.require(refused && before == after, "Unusable profile document was overwritten")
        }
    }
    private static func verifyExpectedVersion(root: URL, saved: WorkspaceLaunchProfiles) async throws {
        try await Task.detached {
            let file = BrowserSnapshotFile(directory: root.appendingPathComponent("version-guard"), name: "profiles.json", maximumBytes: 4_194_304)
            let first = try JSONEncoder().encode(saved)
            func validate(_ data: Data) throws { try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: data).validate() }
            try file.write(first, replacing: .absent, validating: validate)
            var edited = saved; try edited.rename(edited.profiles[0].id, to: "Concurrent")
            let next = try JSONEncoder().encode(edited); try file.write(next, replacing: .bytes(first), validating: validate)
            var refused = false
            do { try file.write(first, replacing: .bytes(first), validating: validate) } catch { refused = true }
            let actual = try file.read()
            guard refused && actual == next else { throw UIVerification.Failure(message: "Expected-version guard overwrote a changed document") }
        }.value
    }
    @MainActor private final class StartupBarrier {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private static func verifyStartup(root: URL, store: LaunchProfileStore, profile: WorkspaceLaunchProfile) async throws {
        for scenario in ["selected", "missing", "navigation", "preference"] {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
            try await settings.chooseStartup(.profile, profile: scenario == "missing" ? UUID() : profile.id)
            let browser = BrowserViewController(settings: settings)
            browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            let workspace = BrowserWorkspaceController(primaryBrowser: browser)
            workspace.launchProfileStore = store
            workspace.persistence = BrowserWorkspacePersistence(stateDirectory: nil)
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isRestorable = false; window.contentViewController = workspace
            window.contentView?.layoutSubtreeIfNeeded()
            let barrier = StartupBarrier()
            if scenario == "navigation" || scenario == "preference" { workspace.persistence.beforeRestoreResult = { await barrier.pause() } }
            defer {
                barrier.release(); workspace.persistence.beforeRestoreResult = nil; workspace.isClosing = true
                for pane in workspace.browsers.values { pane.suspendBrowser() }
                window.close()
            }
            workspace.begin()
            if scenario == "navigation" || scenario == "preference" {
                try await wait { barrier.entered }
                if scenario == "navigation" { browser.tabs[browser.activeIndex].navigate(to: .directory(root.appendingPathComponent("source/Folder B"))) }
                else { try await settings.chooseStartup(.computer) }
                barrier.release()
            }
            try await wait { workspace.sessionReady }
            if scenario == "selected" {
                try UIVerification.require(workspace.browsers.count == 2 && workspace.activePaneID == profile.snapshot.activePane
                    && !workspace.preview.isEnabled, "Selected launch profile failed at actual startup")
            } else {
                try UIVerification.require(workspace.primaryBrowser === browser && workspace.browsers.count == 1,
                    "Missing or stale startup replaced the safe current workspace")
                if scenario == "navigation" {
                    try UIVerification.require(browser.location == .directory(root.appendingPathComponent("source/Folder B")), "Late startup erased newer navigation")
                }
            }
        }
    }
    private static func clickSheet(_ window: NSWindow?, title: String) throws {
        guard let content = window?.attachedSheet?.contentView else { throw UIVerification.Failure(message: "Profile sheet missing") }
        var pending = [content]
        while let view = pending.popLast() {
            if let button = view as? NSButton, button.title == title { button.performClick(nil); return }
            pending.append(contentsOf: view.subviews)
        }
        throw UIVerification.Failure(message: "Profile sheet button missing")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native launch-profile work did not settle")
    }
}
#endif
