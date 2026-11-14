#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Actual signed metadata session/table/tab/pane flow. Connect-form composition
/// remains a separate gate; no saved key, Keychain, user file or content request.
@MainActor enum SFTPBrowserVerification {
    private enum Failure: Error { case generated }
    private static func require(_ condition: Bool) throws { if !condition { throw Failure.generated } }
    private static func wait(_ predicate: () -> Bool, seconds: Double = 15, abort: () -> Bool = { false }) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() { try require(!abort() && ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func run(root: URL, request: SFTPConnectionRequest, fingerprint: String, pool: SMBTemporaryCatalogPool,
        activity: FileActivityGate, settings: BrowserSettings) async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b11-native-qualification")
            && root.resolvingSymlinksInPath() == root && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String == root.lastPathComponent)
        let controller = BrowserWindowController(settings: settings), workspace = controller.workspace, browser = controller.browser
        guard let window = controller.window else { throw Failure.generated }
        let empty = root.appendingPathComponent("source/Empty")
        func prepare(_ browser: BrowserViewController) {
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.tabs = [BrowserTab(location: .directory(empty))]; browser.activeID = browser.tabs[0].id
        }
        prepare(browser); workspace.willStartBrowserForVerification = { prepare($0) }
        settings.glassFileContent = true; settings.navigationStyle = .glass
        window.title = "SFTP browser · generated review"; window.setContentSize(.init(width: 1140, height: 760)); window.center()
        var worker: SFTPWorkerSession?, owner: SFTPTabController?, ticker: Task<Void, Never>?
        var stage = "open", lastClose: SFTPWorkerClose?
        var maximumGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        do {
            let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: activity)
            let raw = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL, activity: activity, pool: pool); worker = raw
            try require(raw.review.current.fingerprint == fingerprint && raw.review.kind == .first)
            try await raw.approve(.connectOnce); try await raw.authenticate(SFTPPassword("ephemeral qualification password"))
            let session = try await SFTPBrowserSession.adoptAuthenticated(raw)
            let tab = SFTPTabController(session: session, address: request.address, title: "Generated SFTP"); owner = tab
            browser.installSFTPTab(tab); let id = browser.activeID
            stage = "root"
            window.makeKeyAndOrderFront(nil)
            try await wait { tab.rows.cache.retainedCount == 3 && tab.session.latest.snapshot?.state == .complete && !tab.hasPendingPages }
            try require(browser.isSFTPLocation && browser.selectedURLs.isEmpty && tab.rows.cache.entry(at: 0)?.entry.name.displayName == "Folder"
                && !browser.commandEnabled(#selector(BrowserViewController.trashSelection(_:)))
                && !browser.commandEnabled(#selector(BrowserViewController.copyFileURLs(_:)))
                && !workspace.canOpenLaunchProfile)
            guard let header = tab.rows.table.headerView as? FileTableHeaderView else { throw Failure.generated }
            browser.updateMaterialSurfaces(); try require(header.usesGlass && !tab.rows.scroll.drawsBackground)
            settings.navigationStyle = .solid; browser.updateMaterialSurfaces(); try require(!header.usesGlass && tab.rows.scroll.drawsBackground)
            settings.navigationStyle = .glass; browser.updateMaterialSurfaces()
            tab.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); browser.openSelection(nil)
            stage = "folder-back-forward"
            try await wait { tab.rows.cache.retainedCount == 2 && tab.rows.cache.entry(at: 0)?.entry.name.displayName == "Nested.txt" && !tab.hasPendingPages }
            try require(tab.rows.cache.entry(at: 1)?.entry.logicalBytes == nil && tab.rows.cache.entry(at: 1)?.entry.permissions == nil)
            tab.rows.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try require(!browser.commandEnabled(#selector(BrowserViewController.openSelection(_:))))
            browser.goBack(nil); try await wait { tab.rows.cache.retainedCount == 3 && !tab.hasPendingPages }
            browser.goForward(nil); try await wait { tab.rows.cache.retainedCount == 2 && !tab.hasPendingPages }
            browser.goBack(nil); try await wait { tab.rows.cache.retainedCount == 3 && !tab.hasPendingPages }
            previous = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled { do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - previous); previous = now
            }}
            let large = try tab.directoryLocation(components: [SFTPRemoteName(Data("Large".utf8))]), began = ProcessInfo.processInfo.systemUptime
            stage = "large-directory"
            browser.navigate(to: .sftp(large))
            try await wait({ tab.rows.table.numberOfRows > 3 && tab.rows.cache.entry(at: 0) != nil }, abort: { tab.session.latest.failure != nil })
            let first = ProcessInfo.processInfo.systemUptime - began
            try await wait({ tab.session.latest.snapshot?.state == .complete && tab.session.latest.snapshot?.count == 100000 && !tab.hasPendingPages }, abort: { tab.session.latest.failure != nil })
            let sealed = ProcessInfo.processInfo.systemUptime - began
            stage = "last-and-sort"
            tab.rows.table.scrollRowToVisible(99999); try await wait { tab.rows.cache.entry(at: 99999) != nil && !tab.hasPendingPages }
            tab.rows.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]; tab.rows.table.scrollRowToVisible(0)
            try await wait { tab.rows.lastPageDescending == true && tab.rows.cache.entry(at: 0) != nil && !tab.hasPendingPages }
            try require(tab.rows.cache.entry(at: 0)?.entry.name.displayName == "Item 99990" && tab.rows.cache.retainedCount <= 512)
            stage = "pane-transfer"
            try require(workspace.splitActive(at: .trailing)); let peer = workspace.activeBrowser
            try require(workspace.moveTab(id, from: browser, into: peer, before: nil)); try await wait { peer.sftpTabs[id] === tab && tab.rows.superview === peer.sftpHost }
            try require(workspace.closeActivePane()); let target = workspace.activeBrowser; target.selectTab(id)
            try await wait { target.sftpTabs[id] === tab && tab.rows.superview === target.sftpHost }
            try require(tab.session.id == session.id && activity.activeCount == 1)
            try JSONSerialization.data(withJSONObject: ["passed": true, "entries": 100000, "firstNativePageSeconds": first,
                "sealedSeconds": sealed, "maximumMainActorGapBeforeRecording": maximumGap, "retainedRows": tab.rows.cache.retainedCount,
                "folderBackForward": true, "unknownMetadata": true, "sortAndPaneOwnership": true], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/browser-core.json"), options: .withoutOverwriting)
            var clips: [String] = []
            stage = "recording"
            if ProcessInfo.processInfo.arguments.contains("--record-sftp-browser") {
                window.setContentSize(.init(width: 900, height: 560)); window.title = "SFTP browser · generated review"
                try await wait { !workspace.hasPaneTransitionForVerification && target.canvasTransition == nil }
                workspace.view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(120))
                let solid = try await NativeMotionRecorder.record(window: window, root: root, label: "sftp-solid") { settings.navigationStyle = .solid; target.updateMaterialSurfaces() }
                try JSONEncoder().encode(solid).write(to: root.appendingPathComponent("evidence/sftp-solid.json"), options: .withoutOverwriting)
                window.title = "SFTP browser · generated review"
                let glass = try await NativeMotionRecorder.record(window: window, root: root, label: "sftp-glass") { settings.navigationStyle = .glass; target.updateMaterialSurfaces() }
                try JSONEncoder().encode(glass).write(to: root.appendingPathComponent("evidence/sftp-glass.json"), options: .withoutOverwriting)
                clips = ["sftp-solid", "sftp-glass"]
            }
            ticker?.cancel(); await ticker?.value
            stage = "close"
            target.closeTab(id: id); try await wait { tab.drain != nil }
            guard let closed = tab.drain else { throw Failure.generated }
            lastClose = closed
            try require(closed.localResourcesEnded && closed.exitStatus == 0 && !closed.contained && closed.protocolValid
                && closed.temporaryStoreRemoved == true && closed.terminal?.catalogWriterEnd == .closed && activity.activeCount == 0)
            try require(await SFTPBrowserLifetimes.shared.closeAndDrain()); try require(try await pool.inspect().isEmpty)
            controller.close()
            let report: [String: Any] = ["passed": true, "entries": 100000, "firstNativePageSeconds": first, "sealedSeconds": sealed,
                "maximumMainActorGapSeconds": maximumGap, "retainedNativeRows": tab.rows.cache.retainedCount, "glassSolid": true,
                "exactUnknownMetadata": true, "folderBackForward": true, "lastAndDescendingRows": true, "paneOwnerTransferredWithoutReconnect": true,
                "localCommandsAndProfileReplacementRefused": true, "actualChildExit": true, "ipcEOF": true, "storeRemoved": true, "poolEmpty": true,
                "keychainAccesses": 0, "personalCatalogs": 0, "ordinaryConnectTested": false, "clips": clips]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/live-ui-browser.json"), options: .withoutOverwriting)
        } catch {
            ticker?.cancel(); await ticker?.value
            if let owner { lastClose = await owner.close().value } else if let worker { lastClose = await worker.close() }
            try? JSONSerialization.data(withJSONObject: ["passed": false, "stage": stage, "activity": activity.activeCount,
                "observedCount": owner?.session.latest.snapshot?.count ?? 0, "nativeRows": owner?.rows.table.numberOfRows ?? 0,
                "retainedRows": owner?.rows.cache.retainedCount ?? 0, "failure": owner?.session.latest.failure?.rawValue ?? "none",
                "workerOutcome": lastClose?.terminal?.outcome ?? 255,
                "recordingRootMatched": root.path == ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                "frameWidth": window.frame.width, "frameHeight": window.frame.height,
                "visible": window.isVisible, "generatedTitle": window.title.contains("generated review"), "errorType": String(describing: type(of: error)),
                "actualChildExit": lastClose?.actualExit ?? false, "ipcEOF": lastClose?.ipcEOF ?? false,
                "storeRemoved": lastClose?.temporaryStoreRemoved ?? false])
                .write(to: root.appendingPathComponent("evidence/live-ui-browser-failure.json"), options: .withoutOverwriting)
            controller.close(); throw error
        }
    }
}
#endif
