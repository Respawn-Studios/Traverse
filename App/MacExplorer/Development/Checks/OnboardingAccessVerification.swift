#if DEBUG
import AppKit
import Combine
import ExplorerCore
import LocalStorage

/// Generated metadata and app-owned state only. Does not open a real chooser,
/// System Settings, a server, Keychain, a personal catalog or a protected folder.
@MainActor enum OnboardingAccessVerification {
    static func run() async {
        var controller: BrowserWindowController?
        var preferences: NSWindow?
        var checks: [String] = []
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
            UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
            root.resolvingSymlinksInPath() == root,
            let marker = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
            let reservation = try? JSONSerialization.jsonObject(with: marker) as? [String: Any],
            reservation["action"] as? String == "traverse-access-onboarding-qualification" else { exit(2) }
        func require(_ value: Bool, _ message: String) throws { try UIVerification.require(value, message) }
        do {
            await BrowsingHome.prepare()
            try require(BrowsingHome.url != nil, "Native account-home lookup unavailable")
            if let home = BrowsingHome.url {
                try require(try DirectoryPathInput.resolve("~/Documents", home: home) == home.appendingPathComponent("Documents", isDirectory: true),
                    "Tilde input did not use account home")
            }
            checks += try await AccessVerification.run(in: root)
            checks += try await RememberedReferenceVerification.run(in: root)
            let selected = root.appendingPathComponent("source/Generated Drive")
            let state = root.appendingPathComponent("source/access-state")
            let access = FolderAccessController(stateDirectory: state, backend: OnboardingBookmarkProbe())
            let choice = await access.acceptChosenFolder(selected)
            try require(access.locations.count == 1 && access.locations.first?.isRemembered == false,
                "Session selection did not update the list")
            try require(!FileManager().fileExists(atPath: state.path), "Session selection saved state")
            let saved = await access.acceptChosenFolder(selected, remember: true)
            guard let id = saved?.selection.id, case .saved? = saved?.remembering else {
                throw UIVerification.Failure(message: "Remember did not save")
            }
            try require(access.locations.count == 1 && access.locations.first?.isRemembered == true,
                "Remembered selection duplicated the session row")
            try require(access.selectedRootCovering(selected.appendingPathComponent("Child")) == selected
                && access.selectedRootCovering(root.appendingPathComponent("source/Generated Drive Sibling")) == nil,
                "Drive selection confused sibling prefixes or lost descendants")
            checks.append("Session/remembered list and drive-root coverage update without a filesystem probe")
            let incompatible = FolderAccessController(stateDirectory: state, backend: OnboardingBookmarkProbe(), policy: .localUser)
            _ = await incompatible.resolveRememberedFolders()
            try require(incompatible.storageIssue != nil && !incompatible.hasSelectedAccess(to: selected),
                "A different edition silently reinterpreted access records")
            let reopened = FolderAccessController(stateDirectory: state, backend: OnboardingBookmarkProbe())
            _ = await reopened.resolveRememberedFolders()
            try require(reopened.locations.count == 1 && reopened.locations[0].id == id,
                "Restart lost remembered list state")
            let replacement = root.appendingPathComponent("source/Other Folder")
            let reselected = await reopened.acceptChosenFolder(replacement, remember: true, replacingReference: id)
            try require(reselected?.selection.id == id && !reopened.hasSelectedAccess(to: selected)
                && reopened.locations.count == 1 && reopened.locations[0].url == replacement,
                "Reselect did not replace the exact saved reference")
            try require(await reopened.forget(id: id) == nil && reopened.locations.isEmpty,
                "Forget left a visible reference")
            _ = await reopened.resolveRememberedFolders()
            try require(reopened.locations.isEmpty && choice?.lease.url == selected,
                "Forget returned on restart or invalidated retained work")
            choice?.lease.close(); saved?.lease.close(); reselected?.lease.close()
            checks.append("Remember/reopen/Reselect/Forget are exact; cross-edition references refuse; existing leases drain")
            try await Task.detached {
                let oldDirectory = root.appendingPathComponent("source/legacy-access")
                try FileManager().createDirectory(at: oldDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let oldDocument: [String: Any] = ["version": 1, "records": [["id": id.uuidString,
                    "bookmark": Data(selected.absoluteString.utf8).base64EncodedString()]]]
                let file = oldDirectory.appendingPathComponent("folder-access-bookmarks-v1.json")
                try JSONSerialization.data(withJSONObject: oldDocument).write(to: file, options: .withoutOverwriting)
                try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }.value
            let legacy = FolderAccessController(stateDirectory: root.appendingPathComponent("source/legacy-access"), backend: OnboardingBookmarkProbe())
            _ = await legacy.resolveRememberedFolders()
            try require(legacy.locations.count == 1 && legacy.locations[0].id == id, "Existing scoped bookmark format did not reopen")
            let realBookmark = try await Task.detached {
                let backend = SystemFolderAccessBackend(policy: .localUser)
                let data = try backend.bookmark(for: selected)
                return try backend.resolve(data)
            }.value
            try require(realBookmark.url.path == selected.path && !realBookmark.isStale, "Ordinary native bookmark failed on a generated folder")
            checks.append("Legacy selected-folder records reopen; real native ordinary bookmarks resolve only the generated folder")
            let blocked = FolderAccessController(stateDirectory: root.appendingPathComponent("source/Blocker/state"), backend: OnboardingBookmarkProbe())
            let failedSave = await blocked.acceptChosenFolder(selected, remember: true)
            guard case .failed? = failedSave?.remembering else { throw UIVerification.Failure(message: "Blocked save reported success") }
            try require(blocked.locations.count == 1 && blocked.locations[0].isRemembered == false, "Save failure claimed durable access")
            failedSave?.lease.close()
            let failureState = root.appendingPathComponent("source/forget-failure")
            let failureController = FolderAccessController(stateDirectory: failureState, backend: OnboardingBookmarkProbe())
            let forgetChoice = await failureController.acceptChosenFolder(selected, remember: true)
            guard let forgetID = forgetChoice?.selection.id else { throw UIVerification.Failure(message: "Forget fixture absent") }
            try await Task.detached {
                try FileManager().moveItem(at: failureState, to: root.appendingPathComponent("source/retained-forget-failure"))
                try Data("generated blocker\n".utf8).write(to: failureState, options: .withoutOverwriting)
            }.value
            let forgetFailure = await failureController.forget(id: forgetID)
            try require(forgetFailure != nil && failureController.storageIssue != nil && !failureController.locations.isEmpty,
                "Failed Forget falsely reported removal")
            forgetChoice?.lease.close()
            checks.append("Blocked Save stays session-only; blocked Forget is visible and preserved")
            try require(FolderAccessController.fullDiskAccessSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "Full Disk Access button differs from the SDK-documented destination")
            let uiSaved = await access.acceptChosenFolder(selected, remember: true)
            let uiSession = await access.acceptChosenFolder(replacement)
            uiSaved?.lease.close(); uiSession?.lease.close()
            let settings = BrowserSettings(persist: false)
            InterfacePresentation.shared.bind(settings)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.glassFileContent = true
            let browserWindow = BrowserWindowController(settings: settings); controller = browserWindow
            let browser = browserWindow.browser
            browser.folderAccess = access; browser.permitsBackgroundVerification = true
            let drives: [VolumeInfo] = [.init(url: selected, name: "Generated Drive", kind: .externalDisk,
                totalBytes: 1_000_000, availableBytes: 700_000, isReadOnly: false)]
            browser.readVolumesForVerification = { drives }; browser.volumes = drives
            guard let window = browserWindow.window else { throw UIVerification.Failure(message: "Missing generated window") }
            window.title = "Traverse access · generated review"; window.setContentSize(.init(width: 900, height: 520)); window.center()
            browserWindow.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            try await BrowsingHome.withGeneratedHome(selected, root: root) {
                browser.rebuildSidebar()
                let favorites = browser.sidebarRoots.first { $0.title == "Places" }?.children ?? []
                try require(favorites.first?.location?.directoryURL == selected,
                    "Sidebar Home did not use the browsing home")
                browser.goHome(nil)
                try require(browser.location.directoryURL == selected, "Go Home used another namespace")
                browser.pathField.stringValue = "~/Child"; browser.locationEntered(nil)
                try require(browser.location.directoryURL?.path == selected.appendingPathComponent("Child").path,
                    "Submitted tilde input used another namespace")
                for _ in 0..<100 {
                    if !browser.isLoading && browser.orderingTask == nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(!browser.isLoading && browser.orderingTask == nil, "Generated Home navigation did not drain")
            }
            checks.append("Real account lookup stays separate; Sidebar/Go Home/typed tilde navigation use only a generated browsing home")
            let model = FolderAccessManagementModel(access: access)
            try require(model.remember && !model.busy, "Owner-selected remember default was not enabled")
            try require(settings.startupMode == .lastSession && settings.restoresSession && settings.automaticUpdateChecks
                && !settings.ranksAddressVisits, "Fresh startup/update or optional visit defaults differ")
            let old = BrowserSettings(persist: false, restoredData: Data(#"{"version":19,"startupMode":"This Mac","restoresSession":false}"#.utf8))
            try require(old.startupMode == .computer && !old.restoresSession, "Existing fresh-start choice was overwritten")
            let legacySettings = BrowserSettings(persist: false, restoredData: Data(#"{"version":3}"#.utf8))
            try require(legacySettings.startupMode == .computer && !legacySettings.restoresSession, "Legacy startup policy was silently opted in")
            let persistedFile = root.appendingPathComponent("source/onboarding-preferences/preferences.json")
            let durable = BrowserSettings(persist: false, persistenceFile: persistedFile, skipDiskRead: true)
            try await durable.chooseStartup(.computer)
            let persistedData = try await Task.detached { try Data(contentsOf: persistedFile) }.value
            let durableRestored = BrowserSettings(persist: false, restoredData: persistedData)
            try require(durableRestored.startupMode == .computer && !durableRestored.restoresSession,
                "Explicit startup selection did not survive an actual reopen")
            let blockedSetup = BrowserSettings(persist: false, persistenceFile: root.appendingPathComponent("source/Blocker/preferences.json"), skipDiskRead: true)
            var completionEvents = 0
            let completionObserver = blockedSetup.$initialSetupCompleted.dropFirst().sink { if $0 { completionEvents += 1 } }
            do { try await blockedSetup.completeInitialSetup(); throw UIVerification.Failure(message: "Blocked setup save reported completion") }
            catch is UIVerification.Failure { throw UIVerification.Failure(message: "Blocked setup save reported completion") }
            catch { try require(!blockedSetup.initialSetupCompleted && completionEvents == 0, "Failed setup published completion to update checks") }
            withExtendedLifetime(completionObserver) {}
            checks.append("New profiles reopen by default; existing/legacy choices are preserved; explicit fresh-start choice is durable")
            checks.append("Failed setup acknowledgement never publishes a completed state to update-check observers")
            let requestProbe = OnboardingNetworkRequestProbe()
            let request = LocalNetworkPermissionRequest(trigger: { requestProbe.perform() })
            request.request(); request.request()
            await request.drainForVerification()
            try require(requestProbe.calls == 1 && !request.requesting && !request.notice.isEmpty,
                "Permission requests overlap or remain busy after worker drain")
            request.request(); request.cancel(); await request.drainForVerification()
            try require(!request.requesting && request.notice.isEmpty, "Cancelled permission attempt published stale status")
            let noNetwork = LocalNetworkPermissionRequest(trigger: { 0 })
            noNetwork.request(); await noNetwork.drainForVerification()
            try require(!noNetwork.requesting && noNetwork.notice.contains("could not be started"), "No-network attempt claimed a completed grant")
            checks.append("Injected network request coalesces clicks, drains cancellation and exposes unavailable state without an OS/network request")
            let view = browser.makeSettingsView(initialPage: .permissions)
            try require(view.folderAccess === access && view.accessDrives == browser.volumes, "Settings lost shared access ownership")
            let preferencesWindow = BrowserSettingsWindow.make(view); preferences = preferencesWindow
            preferencesWindow.title = "Traverse settings · generated review"; preferencesWindow.center(); preferencesWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            try await GlassVerification.captureOwnedWindow(preferencesWindow, to: root.appendingPathComponent("evidence/access-settings.png"))
            TraverseSetupController.shared.show(from: browser)
            guard let setup = TraverseSetupController.shared.window, let setupModel = TraverseSetupController.shared.model else {
                throw UIVerification.Failure(message: "Setup missing")
            }
            setup.title = "Traverse setup · generated review"; setupModel.page = 3
            let initialSetupFrame = setup.frame
            let initialSetupContent = (setup.contentViewController as? ToolWindowChrome)?.children.first?.view.bounds.size
            setup.setFrame(.init(x: initialSetupFrame.minX, y: initialSetupFrame.minY - 70,
                width: initialSetupFrame.width + 100, height: initialSetupFrame.height + 70), display: true)
            try await Task.sleep(for: .milliseconds(120))
            guard let expanded = (setup.contentViewController as? ToolWindowChrome)?.children.first?.view.bounds.size,
                  let initialSetupContent else { throw UIVerification.Failure(message: "Setup resize content is unavailable") }
            try require(setup.styleMask.contains(.resizable) && expanded.width >= initialSetupContent.width + 95
                && expanded.height >= initialSetupContent.height + 65, "Setup did not reflow with its expanded window")
            setup.setFrame(initialSetupFrame, display: true)
            checks.append("Setup can be resized; the actual content grows with the window and its footer remains reachable")
            try require(setupModel.rememberAccess && setupModel.rememberUpdateAccess && !setupModel.showsTourAfterSetup && !setupModel.showsAdditionalAccess,
                "Setup defaults differ from the owner-selected remember and optional-detail contract")
            try await Task.sleep(for: .milliseconds(300))
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-checklist.png"))
            setupModel.showsAdditionalAccess = true
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-additional-access.png"))
            setupModel.page = 1
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-navigation.png"))
            let setupMotion = try await NativeMotionRecorder.record(window: setup, root: root, label: "setup-search") { setupModel.page = 2 }
            try JSONEncoder().encode(setupMotion).write(to: root.appendingPathComponent("evidence/setup-motion.json"), options: .withoutOverwriting)
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-search.png"))
            setupModel.page = 4
            ApplicationUpdates.shared.availabilityForVerification = true
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-updates.png"))
            settings.interfaceSize = .init(150)
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-updates-large.png"))
            preferencesWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(preferencesWindow, to: root.appendingPathComponent("evidence/access-settings-large.png"))
            settings.interfaceSize = .standard
            ApplicationUpdates.shared.availabilityForVerification = nil
            try await Task.sleep(for: .milliseconds(150))
            var pending = [preferencesWindow.contentView].compactMap { $0 }, inspected = 0
            while let next = pending.popLast(), inspected < 512 {
                inspected += 1
                if let scroll = next as? NSScrollView, let document = scroll.documentView,
                   document.bounds.height > scroll.contentView.bounds.height + 100 {
                    scroll.contentView.scroll(to: .init(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    break
                }
                pending += next.subviews
            }
            try await Task.sleep(for: .milliseconds(200))
            try await GlassVerification.captureOwnedWindow(preferencesWindow, to: root.appendingPathComponent("evidence/settings-access-actions.png"))
            checks.append("Five grouped setup pages keep navigation, search, access and updates separate, with remembered beta access selected by default")
            setup.close()
            try require(TraverseTourController.shared.window?.isVisible != true, "Tour opened without opting in")
            checks.append("Setup is optional; remember defaults on, tutorial/details off; Settings shares the same access list")
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode
                TraverseTourController.shared.show(from: browser)
                guard let tour = TraverseTourController.shared.window, let tourModel = TraverseTourController.shared.model else {
                    throw UIVerification.Failure(message: "Optional tour missing")
                }
                tour.title = "Traverse tour · generated review"
                try require(tourModel.page == 0, "Reopened tutorial retained its final page")
                if mode == .full {
                    let report = try await NativeMotionRecorder.record(window: tour, root: root, label: "tour-next") { tourModel.next() }
                    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/tour-motion.json"), options: .withoutOverwriting)
                } else { tourModel.next() }
                tourModel.next(); try require(tourModel.page == 2, "Tutorial pages did not advance")
                tourModel.back(); try require(tourModel.page == 1, "Tutorial Back did not work")
                tourModel.next()
                if mode == .full {
                    try await Task.sleep(for: .milliseconds(200))
                    try await GlassVerification.captureOwnedWindow(tour, to: root.appendingPathComponent("evidence/tour.png"))
                }
                tour.close(); try require(TraverseTourController.shared.model == nil, "Closing tutorial retained page state")
            }
            let menus = BrowserMenus.applicationMenu(target: browser)
            try require(menus.items.contains { $0.submenu?.title == "Help" }, "Help reopening entry absent")
            checks.append("Three nonmodal tutorial hints support every motion mode, Back, close and explicit reopening")
            preferencesWindow.close(); browser.suspendBrowser(); window.close()
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "personalFiles": 0,
                "systemPermissionRequests": 0, "networkConnections": 0, "keychainQueries": 0, "ordinaryDistributionChanged": false],
                options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            NSApplication.shared.terminate(nil)
        } catch {
            preferences?.close(); controller?.browser.suspendBrowser(); controller?.window?.close()
            TraverseSetupController.shared.window?.close(); TraverseTourController.shared.window?.close()
            try? JSONSerialization.data(withJSONObject: ["passed": false, "completedChecks": checks, "failure": String(describing: error)], options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct OnboardingBookmarkProbe: FolderAccessBackend {
    func startAccess(to url: URL) -> Bool { false }
    func stopAccess(to url: URL) {}
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ data: Data) throws -> FolderBookmarkResolution {
        guard let value = String(data: data, encoding: .utf8), let url = URL(string: value), url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        return .init(url: url, isStale: false)
    }
}

private final class OnboardingNetworkRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func perform() -> Int {
        lock.lock(); count += 1; lock.unlock()
        Thread.sleep(forTimeInterval: 0.025)
        return 2
    }
}
#endif
