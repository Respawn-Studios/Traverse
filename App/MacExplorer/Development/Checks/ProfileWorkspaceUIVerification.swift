#if DEBUG
import AppKit
import ExplorerCore

@MainActor enum ProfileWorkspaceUIVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-profile-workspaces-ui" else { exit(2) }
        var owner: BrowserWindowController?, checks: [String] = [], failures: [String] = []
        do {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.motion.mode = .off
            let controller = BrowserWindowController(settings: settings); owner = controller
            let workspace = controller.workspace, templates = LaunchProfileStore(directory: root.appendingPathComponent("templates"))
            let memory = WorkspaceProfileStore(directory: root.appendingPathComponent("working"))
            workspace.launchProfileStore = templates; workspace.profileWorkspaceStore = memory
            guard let parent = controller.window else { throw UIVerification.Failure(message: "Missing generated workspace window") }
            parent.title = "Profile workspaces · generated review"; parent.setFrame(.init(x: 150, y: 150, width: 960, height: 640), display: true)
            parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); controller.beginBrowsing()
            try await wait { workspace.sessionReady }
            let following = workspace.profileWorkspaces
            let absent = try await following.refresh()
            let workingCreated = await exists(root.appendingPathComponent("working"))
            try UIVerification.require(!absent.exists && !workingCreated, "Passive profile UI created storage")
            let firstTemplate = sample(root, folder: "First"), secondTemplate = sample(root, folder: "Second")
            let saved = try await templates.edit(expected: nil) {
                try $0.add(name: "Development", snapshot: firstTemplate)
                try $0.add(name: "Personal", snapshot: secondTemplate)
            }
            var first = saved.library.profiles[0]; let second = saved.library.profiles[1]
            try await verifyTemplateTransactions(root, snapshot: firstTemplate)
            checks.append("Template writes serialize across independent stores; legacy reads stay passive and pre/post-publication failures stay distinguishable")
            let templateBytes = try await read(root.appendingPathComponent("templates/launch-profiles-v1.json"))
            try await following.open(first, resuming: false); try await settle(workspace)
            try UIVerification.require(!following.isFollowing && following.currentProfile?.id == first.id, "Saved layout silently enabled remembering")
            try await following.setRemembering(true, for: first)
            workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/Later")))
            try await settle(workspace); await following.flush(closing: false)
            let later = try await memory.load().memory.record(for: first.id)
            let afterBrowsingTemplateBytes = try await read(root.appendingPathComponent("templates/launch-profiles-v1.json"))
            try UIVerification.require(following.isFollowing && later?.snapshot.panes[0].tabs.tabs[0].location.url == root.appendingPathComponent("source/Later")
                && !settings.restoresSession && templateBytes == afterBrowsingTemplateBytes,
                "Browsing failed to checkpoint independently of Reopen, or rewrote the template")
            try UIVerification.require(later?.snapshot.panes[0].tabs.tabs[0].selection.isEmpty == true,
                "Working profile retains selected file names")
            checks.append("Explicit per-profile remembering follows navigation without changing the template or global Reopen choice")

            try await following.open(second, resuming: false); try await settle(workspace)
            try UIVerification.require(!following.isFollowing && following.records[second.id] == nil, "A second profile inherited consent")
            try await choose(first.id, workspace: workspace)
            try await settle(workspace)
            try UIVerification.require(following.isFollowing && workspace.activeBrowser.location == .directory(root.appendingPathComponent("source/Later")),
                "Native quick menu failed to Resume the exact remembered workspace")
            try await choose(first.id, workspace: workspace, saved: true); try await settle(workspace)
            let afterSavedLayout = try await memory.load().memory.record(for: first.id)
            try UIVerification.require(!following.isFollowing && workspace.activeBrowser.location == .directory(root.appendingPathComponent("source/First"))
                && afterSavedLayout == later, "Open Saved Layout overwrote working state")
            try await choose(first.id, workspace: workspace)
            checks.append("Native quick-menu Resume/Open Saved Layout retain separate independent workspaces")

            let coordinator = workspace.primaryBrowser.operationCoordinator, busy = UUID()
            try UIVerification.require(coordinator.beginPreparation(owner: busy), "Missing generated busy guard")
            let before = try workspace.captureWorkingProfile(includeFilters: false)
            let refusedBusy = await refuses { try await following.open(second, resuming: false) }
            coordinator.finishPreparation(owner: busy)
            try UIVerification.require(refusedBusy && (try workspace.captureWorkingProfile(includeFilters: false)) == before,
                "Busy profile open replaced the workspace")
            try await verifyNewerNavigation(root, workspace: workspace, following: following, memory: memory, other: second)
            checks.append("Busy work is refused; navigation during a real blocked checkpoint wins over a pending profile switch")

            workspace.showLaunchProfiles(); let model = workspace.launchProfiles; await model.drain()
            model.selected = first.id; model.rename(to: "Development tools"); await model.drain()
            first = try await templates.load().library.profiles.first { $0.id == first.id }!
            try UIVerification.require(following.currentProfile?.name == first.name && following.isFollowing, "Renaming lost qualified template continuity")
            if let window = workspace.launchProfilesWindow?.window {
                window.title = "Launch profiles · generated review"
                window.setFrame(.init(x: 160, y: 160, width: 900, height: 640), display: true)
                try await Task.sleep(for: .milliseconds(350))
                window.contentView?.layoutSubtreeIfNeeded()
                try UIVerification.require(window.frame.width <= 960 && window.frame.height <= 640
                    && window.contentView!.bounds.height >= 580, "Profile manager content collapses or exceeds the review bounds")
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/profiles-native.png"))
                if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                    for mode in BrowserMotionMode.allCases {
                        settings.motion.mode = mode; model.selected = first.id
                        try await Task.sleep(for: .milliseconds(350))
                        let report = try await NativeMotionRecorder.record(window: window, root: root, label: "profiles-" + mode.rawValue) { model.selected = second.id }
                        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/profiles-" + mode.rawValue + ".json"), options: .withoutOverwriting)
                    }
                    checks.append("Exact-window profile pages recorded in Full/Reduced/Off with complete recorder drain")
                }
            }
            settings.motion.mode = .off; model.selected = first.id
            model.setRemembering(false); await model.drain()
            let afterOff = try await memory.load().memory.record(for: first.id)
            try UIVerification.require(!following.isFollowing && afterOff == nil,
                "Native Off did not durably forget the working record")
            workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/First")))
            try await settle(workspace); await following.flush(closing: false)
            try UIVerification.require((try await memory.load().memory.record(for: first.id)) == nil, "Late navigation resurrected disabled remembering")
            model.setRemembering(true); await model.drain()
            model.openSelected(resuming: true)
            try await wait { model.window?.attachedSheet != nil }; try clickSheet(model.window, title: "Cancel")
            try await Task.sleep(for: .milliseconds(40))
            model.openSelected(resuming: true)
            try await wait { model.window?.attachedSheet != nil }; try clickSheet(model.window, title: "Resume Workspace")
            try await wait { following.isFollowing && workspace.launchProfilesWindow == nil }
            await model.drain(); try await settle(workspace)
            try UIVerification.require(following.isFollowing && workspace.launchProfilesWindow == nil, "Native Resume confirmation did not rebind the owner")
            checks.append("Manager Rename, Off, re-enable and actual Resume/Cancel sheet actions preserve privacy and ownership")

            await memory.setCheckpointForVerification { boundary in if case .staged = boundary { throw WorkspaceProfileStore.Failure.unavailable } }
            workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/Later")))
            try await settle(workspace); await following.flush(closing: false)
            let heldAfterFailure = await memory.heldSessionsForVerification()
            try UIVerification.require(!following.isFollowing && !following.notice.isEmpty && heldAfterFailure == 0,
                "Failed autosave retained ownership or pretended to succeed")
            await memory.setCheckpointForVerification(nil)
            try UIVerification.require(await refuses { try await following.open(second, resuming: false) }, "Paused remembering silently abandoned an uncertain workspace")
            try await following.open(first, resuming: true); try await settle(workspace)
            try UIVerification.require(following.isFollowing, "Explicit Resume failed to recover a paused checkpoint")
            checks.append("Injected save failure pauses captures and releases its lease; explicit Resume recovers without automatic retry")

            workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/Second")))
            try await settle(workspace); await following.flush(closing: false)
            try await verifyStartup(root, templates: templates, profile: first)
            checks.append("A second window starts from the saved launch template, writes no working data and acquires no autosave ownership")

            controller.suspendBrowsing(); await controller.flushSession()
            try UIVerification.require(await memory.heldSessionsForVerification() == 0 && !following.isFollowing, "Closed workspace retained an autosave lease")
            controller.resumeBrowsing(); try await wait { !following.isBusy && following.isFollowing }
            try UIVerification.require(await memory.heldSessionsForVerification() == 1, "Reopened window lost or duplicated its existing owner")
            checks.append("Close drains ownership; reopening the same window reacquires one existing lease without replacing its tabs")

            workspace.showLaunchProfiles(); await model.drain(); model.selected = first.id
            let rememberedBeforeUpdate = try await memory.load().memory.record(for: first.id)
            model.saveCurrent(name: "", includeFilters: false, atLaunch: false, replacing: first.id); await model.drain()
            first = try await templates.load().library.profiles.first { $0.id == first.id }!
            let refusesChanged = await refuses { try await following.open(first, resuming: true) }
            let rememberedAfterUpdate = try await memory.load().memory.record(for: first.id)
            try UIVerification.require(!following.isFollowing && refusesChanged && rememberedAfterUpdate == rememberedBeforeUpdate
                && model.templateKeys[first.id] != rememberedAfterUpdate?.templateKey,
                "Template update silently reinterpreted an older remembered workspace")
            checks.append("Updating a saved layout stops its old owner and refuses to reinterpret the older workspace")
            model.removeSelected(); await model.drain()
            let removed = try await templates.load()
            let removedWorking = try await memory.load().memory.record(for: first.id)
            try UIVerification.require(!removed.library.profiles.contains { $0.id == first.id }
                && removedWorking == nil && following.currentProfile == nil,
                "Delete left the working record or active profile behind")
            checks.append("Profile Delete forgets working locations before removing the template; unrelated profile remains")
            workspace.launchProfilesWindow?.close(); await model.drain()
            _ = try await QuickProfileVerification.run(root: root, workspace: workspace)
            checks.append("Existing quick-profile Cancel, stale library/visit, busy, missing/corrupt and close-drain regression also passes")
        } catch { failures.append(String(describing: error)) }
        if let owner {
            owner.workspace.quickProfiles.presentForVerification = nil
            owner.workspace.launchProfilesWindow?.close(); owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "sourceFileMutations": 0, "generatedStateWrites": true, "networkRequests": 0, "personalCatalogs": 0,
            "notExercised": ["Spoken VoiceOver", "Apple-processed installation", "Mixed older-build writers", "Power loss"]], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func sample(_ root: URL, folder: String) -> PaneWorkspaceSnapshot {
        let id = UUID(), layout = PaneLayout(paneID: id)
        return .init(layout: layout, activePane: id, panes: [.init(id: id,
            tabs: .init(tabs: [.init(location: .init(kind: .directory, url: root.appendingPathComponent("source/" + folder)))]),
            viewMode: DirectoryViewMode.details.rawValue)])
    }
    private static func verifyTemplateTransactions(_ root: URL, snapshot: PaneWorkspaceSnapshot) async throws {
        let path = root.appendingPathComponent("template-controls"), store = LaunchProfileStore(directory: path)
        let initial = try await store.edit(expected: nil) { try $0.add(name: "Original", snapshot: snapshot) }
        let id = initial.library.profiles[0].id, peer = LaunchProfileStore(directory: path)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await store.setCheckpointForVerification { boundary in
            if case .staged = boundary { entered.signal(); guard release.wait(timeout: .now() + 3) == .success else { throw WorkspaceProfileStore.Failure.unavailable } }
        }
        let writing = Task { try await store.edit(expected: initial.revision) { try $0.rename(id, to: "Saved Rename") } }
        let reached = await Task.detached { waitSignal(entered) }.value
        let readRefused = await refuses { try await peer.load() }
        let editRefused = await refuses { try await peer.edit(expected: initial.revision) { try $0.remove(id) } }
        release.signal(); let published = try await writing.value
        await store.setCheckpointForVerification(nil)
        try UIVerification.require(reached && readRefused && editRefused, "A second template store ignored the active writer")
        let file = path.appendingPathComponent("launch-profiles-v1.json"), previous = try await read(file)
        await store.setCheckpointForVerification { boundary in if case .staged = boundary { throw WorkspaceProfileStore.Failure.unavailable } }
        let stagedRefused = await refuses { try await store.edit(expected: published.revision) { try $0.remove(id) } }
        let afterStaged = try await read(file)
        try UIVerification.require(stagedRefused && afterStaged == previous, "A staged template failure changed the published layout")
        await store.setCheckpointForVerification { boundary in if case .published = boundary { throw WorkspaceProfileStore.Failure.unavailable } }
        let acknowledgementRefused = await refuses { try await store.edit(expected: published.revision) { try $0.rename(id, to: "Published Rename") } }
        await store.setCheckpointForVerification(nil)
        let afterPublished = try await peer.load()
        try UIVerification.require(acknowledgementRefused && afterPublished.library.profiles[0].name == "Published Rename",
            "A published-but-unacknowledged edit was misreported as unchanged")
        let legacy = root.appendingPathComponent("legacy-template")
        try await Task.detached {
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try previous.write(to: legacy.appendingPathComponent("launch-profiles-v1.json"), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.appendingPathComponent("launch-profiles-v1.json").path)
        }.value
        let oldStore = LaunchProfileStore(directory: legacy), oldRead = try await oldStore.load()
        let repairedDuringRead = await exists(legacy.appendingPathComponent("launch-profiles-v1.json.writer-lock"))
        try UIVerification.require(!repairedDuringRead && oldRead.library == published.library, "Legacy template read rewrote coordination or data")
        _ = try await oldStore.edit(expected: oldRead.revision) { try $0.rename(id, to: "Explicit Upgrade") }
        try UIVerification.require(await exists(legacy.appendingPathComponent("launch-profiles-v1.json.writer-lock")),
            "Explicit template edit did not establish writer coordination")
    }
    private static func choose(_ id: UUID, workspace: BrowserWorkspaceController, saved: Bool = false) async throws {
        var delivered = false
        let quick = workspace.quickProfiles
        quick.presentForVerification = { menu in
            let target = saved ? menu.items.first(where: { $0.submenu != nil })?.submenu : menu
            if let target, let index = target.items.firstIndex(where: { $0.representedObject as? UUID == id }) {
                target.performActionForItem(at: index); delivered = true
            }
        }
        quick.open(); await quick.drain(); quick.presentForVerification = nil
        try UIVerification.require(delivered && quick.lastNotice.isEmpty, "Native profile menu action was not delivered: " + quick.lastNotice)
    }
    private static func verifyStartup(_ root: URL, templates: LaunchProfileStore,
        profile: WorkspaceLaunchProfile) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.motion.mode = .off
        try await settings.chooseStartup(.profile, profile: profile.id)
        let child = BrowserWindowController(settings: settings)
        let ownMemory = WorkspaceProfileStore(directory: root.appendingPathComponent("working"))
        child.workspace.launchProfileStore = templates; child.workspace.profileWorkspaceStore = ownMemory
        let before = try await read(root.appendingPathComponent("working/profile-workspaces-v1.json"))
        child.window?.setFrame(.init(x: 180, y: 180, width: 900, height: 620), display: true)
        child.window?.makeKeyAndOrderFront(nil); child.beginBrowsing()
        try await wait { child.workspace.sessionReady }; try await settle(child.workspace)
        let after = try await read(root.appendingPathComponent("working/profile-workspaces-v1.json"))
        let held = await ownMemory.heldSessionsForVerification()
        let rightTemplate = try child.workspace.captureWorkingProfile(includeFilters: profile.includesFilters) == profile.snapshot
        let context = child.workspace.profileWorkspaces
        let correct = rightTemplate && context.currentProfile?.id == profile.id && !context.isFollowing && held == 0 && before == after
        child.suspendBrowsing(); await child.flushSession(); child.window?.close()
        try UIVerification.require(correct, "Startup resumed working data, changed storage or failed to identify the saved template copy")
    }
    private static func verifyNewerNavigation(_ root: URL, workspace: BrowserWorkspaceController,
        following: ProfileWorkspaceController, memory: WorkspaceProfileStore, other: WorkspaceLaunchProfile) async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await memory.setCheckpointForVerification { boundary in
            if case .staged = boundary { entered.signal(); guard release.wait(timeout: .now() + 3) == .success else { throw WorkspaceProfileStore.Failure.unavailable } }
        }
        workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/First")))
        let reached = await Task.detached { waitSignal(entered) }.value
        try UIVerification.require(reached, "Autosave did not reach the real generated checkpoint")
        let switching = Task { await refuses { try await following.open(other, resuming: false) } }
        try await wait { following.isBusy }
        workspace.activeBrowser.navigate(to: .directory(root.appendingPathComponent("source/Second")))
        release.signal(); let refused = await switching.value
        await memory.setCheckpointForVerification(nil); await following.flush(closing: false)
        try UIVerification.require(refused && workspace.activeBrowser.location == .directory(root.appendingPathComponent("source/Second")),
            "A delayed profile switch erased newer navigation")
    }
    nonisolated private static func waitSignal(_ value: DispatchSemaphore) -> Bool { value.wait(timeout: .now() + 3) == .success }
    private static func settle(_ workspace: BrowserWorkspaceController) async throws {
        for browser in workspace.browsers.values { browser.permitsBackgroundVerification = true }
        try await wait { workspace.browsers.values.allSatisfy { !$0.isLoading && $0.orderingTask == nil && $0.canvasTransition == nil } }
        workspace.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < until, "Generated profile UI did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func clickSheet(_ window: NSWindow?, title: String) throws {
        var views = window?.attachedSheet?.contentView.map { [$0] } ?? []
        while let view = views.popLast() {
            if let button = view as? NSButton, button.title == title { button.performClick(nil); return }
            views += view.subviews
        }
        throw UIVerification.Failure(message: "Missing generated profile confirmation button")
    }
    private static func refuses<T>(_ action: () async throws -> T) async -> Bool { do { _ = try await action(); return false } catch { return true } }
    private static func exists(_ url: URL) async -> Bool { await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value }
    private static func read(_ url: URL) async throws -> Data { try await Task.detached { try Data(contentsOf: url) }.value }
}
#endif
