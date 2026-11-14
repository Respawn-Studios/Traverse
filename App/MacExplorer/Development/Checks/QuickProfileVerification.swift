#if DEBUG
    import AppKit
    import ExplorerCore

    @MainActor enum QuickProfileVerification {
        static func run(root: URL, workspace: BrowserWorkspaceController) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let workingProfilePacket = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
                && ProcessInfo.processInfo.arguments.contains("--check-profile-workspaces-ui")
                && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-profile-workspaces-ui"
            try UIVerification.require(
                (root.deletingLastPathComponent() == repo.appendingPathComponent(".build/overnight-foundation") || workingProfilePacket)
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Quick profile QA needs an owned generated case")
            try await wait { workspace.sessionReady }
            for browser in workspace.browsers.values { browser.permitsBackgroundVerification = true }
            let store = LaunchProfileStore(directory: root.appendingPathComponent("profiles"))
            workspace.launchProfileStore = store
            workspace.profileWorkspaceStore = WorkspaceProfileStore(directory: root.appendingPathComponent("profile-working"))
            let one = UUID()
            let two = UUID()
            func template(_ id: UUID, _ folder: String) -> PaneWorkspaceSnapshot {
                let layout = PaneLayout(paneID: id)
                return .init(
                    layout: layout, activePane: id,
                    panes: [
                        .init(
                            id: id,
                            tabs: .init(tabs: [
                                .init(
                                    location: .init(
                                        kind: .directory,
                                        url: root.appendingPathComponent("source/" + folder))),
                                .init(location: .init(kind: .computer)),
                            ]), viewMode: "Details")
                    ])
            }
            let first = template(one, "Folder A")
            let second = template(two, "Profile Folder")
            var saved = try await store.edit(expected: nil) {
                try $0.add(name: "Daily", snapshot: first)
                try $0.add(name: "Studio", snapshot: second)
            }
            let daily = saved.library.profiles[0].id
            let studio = saved.library.profiles[1].id
            let quick = workspace.quickProfiles
            func choose(_ id: UUID, in menu: NSMenu) throws {
                guard let index = menu.items.firstIndex(where: { $0.representedObject as? UUID == id }) else {
                    throw UIVerification.Failure(message: "Native quick profile entry missing")
                }
                menu.performActionForItem(at: index)
            }
            let initial = try workspace.captureSessionSnapshot(syncViewState: false)
            quick.presentForVerification = { _ in }  // Cancel.
            quick.open()
            await quick.drain()
            try UIVerification.require(
                try workspace.captureSessionSnapshot(syncViewState: false) == initial,
                "Menu Cancel changed the workspace")
            quick.presentForVerification = { menu in try? choose(studio, in: menu) }
            quick.open()
            await quick.drain()
            try UIVerification.require(
                workspace.activePaneID == two && workspace.activeBrowser.tabs.count == 2
                    && workspace.activeBrowser.location
                        == .directory(root.appendingPathComponent("source/Profile Folder")),
                "Native profile selection did not apply the exact saved layout")
            for browser in workspace.browsers.values { browser.permitsBackgroundVerification = true }
            try await wait { !workspace.activeBrowser.isLoading && workspace.activeBrowser.orderingTask == nil }
            let before = try workspace.captureSessionSnapshot(syncViewState: false)
            quick.presentForVerification = { menu in
                workspace.activeBrowser.navigate(to: .computer)
                try? choose(daily, in: menu)
            }
            quick.open()
            await quick.drain()
            try UIVerification.require(
                workspace.activePaneID == two && workspace.activeBrowser.location == .computer
                    && !quick.lastNotice.isEmpty,
                "Quick profile stole a newer visit")
            try await wait { !workspace.activeBrowser.isLoading }
            let changedVisit = try workspace.captureSessionSnapshot(syncViewState: false)
            let revision = saved.revision
            quick.presentForVerification = { menu in
                _ = try? await store.edit(expected: revision) { try $0.rename(daily, to: "Daily changed") }
                try? choose(daily, in: menu)
            }
            quick.open()
            await quick.drain()
            try UIVerification.require(
                try workspace.captureSessionSnapshot(syncViewState: false) == changedVisit,
                "Changed library applied a stale menu choice")
            saved = try await store.load()
            let reservation = UUID()
            let coordinator = workspace.primaryBrowser.operationCoordinator
            quick.presentForVerification = { menu in
                _ = coordinator.beginPreparation(owner: reservation)
                try? choose(studio, in: menu)
            }
            quick.open()
            await quick.drain()
            coordinator.finishPreparation(owner: reservation)
            try UIVerification.require(
                try workspace.captureSessionSnapshot(syncViewState: false) == changedVisit,
                "Busy selection replaced the workspace")
            workspace.launchProfileStore = LaunchProfileStore(directory: root.appendingPathComponent("absent"))
            var emptyMenu = false
            quick.presentForVerification = { menu in
                emptyMenu = menu.items.contains { $0.title == "No profiles saved" && !$0.isEnabled }
            }
            quick.open()
            await quick.drain()
            try UIVerification.require(
                emptyMenu && !FileManager().fileExists(atPath: root.appendingPathComponent("absent").path),
                "Empty menu wrote a profile store or lost its management path")
            workspace.launchProfileStore = LaunchProfileStore(directory: root.appendingPathComponent("corrupt"))
            quick.open()
            await quick.drain()
            try UIVerification.require(
                !quick.lastNotice.isEmpty
                    && (try workspace.captureSessionSnapshot(syncViewState: false)) == changedVisit,
                "Invalid library changed the workspace")
            workspace.launchProfileStore = store
            var entered = false
            var release: CheckedContinuation<Void, Never>?
            quick.presentForVerification = { _ in
                entered = true
                await withCheckedContinuation { release = $0 }
            }
            quick.open()
            try await wait { entered }
            quick.close()
            var drained = false
            let pending = Task {
                await quick.drain()
                drained = true
            }
            try await Task.sleep(for: .milliseconds(25))
            try UIVerification.require(!drained, "Closed menu lost its pending owner")
            release?.resume()
            release = nil
            await pending.value
            try UIVerification.require(
                (try workspace.captureSessionSnapshot(syncViewState: false)) == changedVisit,
                "Closed menu applied a late choice")
            let final = try await store.load()
            try UIVerification.require(
                final.revision == saved.revision && settingsUnchanged(workspace.primaryBrowser.settings),
                "Quick selection changed profile storage or launch defaults")
            quick.presentForVerification = nil
            let menu = BrowserMenus.menu(.go, target: workspace.activeBrowser)
            let binding = menu.items.first { $0.action == #selector(BrowserViewController.switchLaunchProfile(_:)) }
            try UIVerification.require(
                binding?.keyEquivalent == "p" && binding?.keyEquivalentModifierMask == [.command, .control],
                "Quick switch does not use shared custom shortcuts")
            return [
                "passed": true, "nativeMenuActions": true, "cancelPreservesWorkspace": true, "exactSavedLayout": true,
                "newerVisitAndLibraryWin": true, "busyRefused": true, "emptyReadIsPassive": true,
                "corruptStorePreserved": true,
                "closeDrainsPendingOwner": true, "launchDefaultsUnchanged": true, "profileWorkingSessionsAdded": false,
                "priorLayoutDifferent": before != changedVisit,
                "notExercised": ["Physical menu pointer selection", "Full VoiceOver task"],
            ]
        }
        private static func settingsUnchanged(_ settings: BrowserSettings) -> Bool {
            settings.startupMode == .computer && settings.startupProfileID == nil
        }
        private static func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw UIVerification.Failure(message: "Generated quick profile workflow did not settle")
        }
    }
#endif
