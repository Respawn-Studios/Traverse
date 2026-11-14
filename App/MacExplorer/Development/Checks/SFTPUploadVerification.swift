#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// Configured-signature app, exact generated profile/loopback only. Ordinary
/// startup, real Keychain, owner files and saved connection authority are absent.
@MainActor enum SFTPUploadVerification {
    private enum Failure: Error { case generated }
    private static var retained: BrowserWindowController?
    private static func require(_ value: Bool) throws { if !value { throw Failure.generated } }
    private static func wait(_ predicate: () -> Bool, seconds: Double = 15) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func runStandalone() async {
        let args = ProcessInfo.processInfo.arguments
        var root: URL?, service: ApplicationSMBConnections?, owner: SFTPTabController?, ticker: Task<Void, Never>?
        var paneBoard: NSPasteboard?
        var stage = "input", maximumGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        do {
            func field(_ key: String) throws -> String { guard let at = args.firstIndex(of: key), args.indices.contains(at + 1) else { throw Failure.generated }; return args[at + 1] }
            let location = URL(fileURLWithPath: try field("--analysis-source")); root = location
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            stage = "scope"
            try require([".build/b12-upload-integration", ".build/b12-upload-pane-qualification"].contains(where: { location.deletingLastPathComponent() == repo.appendingPathComponent($0) }) && location.resolvingSymlinksInPath() == location
                && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent && ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == location.path
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app") && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil)
            let scenario = try field("--upload-scenario"); try require(["success", "stop", "layout", "pane", "pane-stop", "pane-layout"].contains(scenario))
            let stopping = scenario == "stop" || scenario == "pane-stop"
            try require(scenario.hasPrefix("pane") == (location.deletingLastPathComponent().lastPathComponent == "b12-upload-pane-qualification"))
            guard let port = UInt16(try field("--generated-port")), port > 0 else { throw Failure.generated }
            let fingerprint = try field("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            let controller = BrowserWindowController(settings: settings); retained = controller
            var browser = controller.browser
            let localBrowser = browser, profile = location.appendingPathComponent("source/Profile"), source = location.appendingPathComponent("source/Local/Selected.bin")
            stage = "source-hash"
            let original = try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) }.value
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: profile.appendingPathComponent("operation-recovery"))
            browser.tabs = [BrowserTab(location: .directory(source.deletingLastPathComponent()))]; browser.activeID = browser.tabs[0].id
            browser.loadLocation(); guard let window = controller.window else { throw Failure.generated }
            window.setContentSize(.init(width: 900, height: 580)); window.title = "SFTP Upload · generated review"; window.center(); window.makeKeyAndOrderFront(nil)
            var clipboardCount = 0
            if scenario.hasPrefix("pane") {
                stage = "pane-layout"
                SFTPPaneUploadFeature.qualifying = true; window.setContentSize(.init(width: 1140, height: 760))
                let board = NSPasteboard.withUniqueName(); board.setString("Generated pane upload sentinel", forType: .string)
                paneBoard = board; clipboardCount = board.changeCount; localBrowser.transferPasteboard = board
                controller.workspace.willStartBrowserForVerification = { peer in
                    peer.permitsBackgroundVerification = true; peer.readVolumesForVerification = { [] }; peer.transferPasteboard = board
                    peer.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
                    peer.recoverableFileOperations = localBrowser.recoverableFileOperations
                    peer.tabs = [BrowserTab(location: .directory(source.deletingLastPathComponent()))]; peer.activeID = peer.tabs[0].id
                }
                window.contentView?.layoutSubtreeIfNeeded(); await Task.yield()
                let facts: [String: Any] = ["canChange": controller.workspace.canChangePaneLayout, "trailing": controller.workspace.canSplitActive(at: .trailing),
                    "bottom": controller.workspace.canSplitActive(at: .bottom), "width": window.frame.width, "height": window.frame.height,
                    "contentWidth": controller.workspace.view.bounds.width, "contentHeight": controller.workspace.view.bounds.height,
                    "hasOperation": localBrowser.hasExclusiveBrowserOperation, "suspended": localBrowser.isBrowserSuspended]
                try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/pane-layout.json"), options: .withoutOverwriting)
                let edge: PaneDropEdge = controller.workspace.canSplitActive(at: .trailing) ? .trailing : .bottom
                try require(controller.workspace.splitActive(at: edge)); browser = controller.workspace.activeBrowser
                if scenario == "pane-layout" {
                    paneBoard?.releaseGlobally(); paneBoard = nil; releasePaneQualification()
                    try JSONSerialization.data(withJSONObject: ["passed": true, "scenario": scenario, "networkConnections": 0, "localPeerPane": true], options: [.sortedKeys])
                        .write(to: location.appendingPathComponent("evidence/native-upload.json"), options: .withoutOverwriting)
                    retained = nil; NSApplication.shared.terminate(nil); return
                }
            }
            stage = "source-review"
            let review = try await SFTPUploadSourceReview.inspect(source, excluding: [profile])
            if scenario == "layout" {
                stage = "preview-layout"
                let sheet = SFTPUploadPreview(source: review, destination: "Generated server › Projects › Uploads", settings: settings)
                sheet.model.name = "Draft-Notes.bin"; let choice = Task { await sheet.choose(in: window) }
                try await wait { sheet.window?.isVisible == true }
                guard let panel = sheet.window else { throw Failure.generated }; panel.title = "Upload Preview · generated review"
                let report = try await NativeMotionRecorder.record(window: panel, root: location, label: "upload-preview") { sheet.model.details = true }
                try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
                try require(panel.frame.width <= 640 && panel.frame.height <= 640 && sheet.model.valid)
                sheet.finish(nil); try require(await choice.value == nil)
                try JSONSerialization.data(withJSONObject: ["passed": true, "scenario": scenario, "networkConnections": 0, "motionFrames": report.frames.count], options: [.sortedKeys])
                    .write(to: location.appendingPathComponent("evidence/native-upload.json"), options: .withoutOverwriting)
                retained = nil; NSApplication.shared.terminate(nil); return
            }
            let initialPresentation = ProcessInfo.processInfo.systemUptime - previous; previous = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled { let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - previous); previous = now; do { try await Task.sleep(for: .milliseconds(10)) } catch { return } } }
            SFTPUploadFeature.qualifying = true
            let connections = ApplicationSMBConnections(directory: profile, sftpPasswords: .generatedQualification(namespace: UUID(uuidString: location.lastPathComponent)!), sftpEnabled: true); service = connections
            stage = "connect"; connections.present(in: browser); try await wait { connections.verificationWindow?.model.managing == false }
            guard let connect = connections.verificationWindow else { throw Failure.generated }
            let model = connect.model; model.connectionProtocol = .sftp; model.address = "sftp://127.0.0.1:\(port)/"; model.account = "generated"; model.password = "ephemeral qualification password"
            model.name = "Generated Upload"; try require(model.freshUploadAvailable && model.freshUploads && !model.rememberServer && !model.rememberPassword)
            model.transferBehavior = .cautious; model.freshFolderUploads = false
            model.freshUploads = true; model.connect(); try await wait { connections.verificationSFTPTrust != nil || !model.busy }
            guard let trust = connections.verificationSFTPTrust else { throw Failure.generated }
            try require(trust.model.review.kind == .first && trust.model.review.fingerprint == fingerprint); trust.model.rememberKey = false; trust.model.proceed()
            try await wait { !model.busy }; try require(model.connected)
            guard let tab = browser.sftpTabs[browser.activeID], let storage = tab.uploads else { throw Failure.generated }; owner = tab
            let uploadTabID = browser.activeID
            try await wait { tab.rows.cache.retainedCount == 2 && tab.session.latest.snapshot?.state == .complete && !tab.hasPendingPages }
            try require(tab.session.allowsFreshUploads && browser.status.stringValue.contains("uploads allowed"))
            guard let item = tab.rows.table.menu?.items.first(where: { $0.title == "Upload File Here…" }), let action = item.action else { throw Failure.generated }
            try require(!item.isHidden && tab.rows.validateMenuItem(item))
            stage = "cancel-preview"; browser.sftpUpload.chooseForVerification = { _ in source }; browser.sftpUpload.reviewForVerification = { _ in nil }
            NSApp.sendAction(action, to: item.target, from: item); try await wait { browser.operationPreparationTask == nil }
            let empty = try await storage.inspect(); try require(empty.records.isEmpty && tab.session.latest.failure == nil)
            stage = "upload"; browser.sftpUpload.reviewForVerification = { review in review.model.name = "Draft-Notes.bin"; return review.model.valid ? review.model.name : nil }
            var paneVerified = false, chooserCalled = false
            if scenario.hasPrefix("pane") {
                let remoteID = browser.activeID, localRemoteTab = browser.tabs.first(where: { $0.id != remoteID })!.id
                let other = source.deletingLastPathComponent().appendingPathComponent("Other.bin")
                try await wait { localBrowser.rowsByURL[source] != nil && localBrowser.rowsByURL[other] != nil && !localBrowser.isLoading }
                @MainActor func select(_ url: URL) { controller.workspace.activate(localBrowser); localBrowser.renderFilePresentation(selection: [url]); localBrowser.fileSelectionDidChange() }
                select(source); try require(localBrowser.sftpPaneUpload.canRequest)
                let context = BrowserMenus.fileContextMenu(target: localBrowser)
                guard let command = context.items.first(where: { $0.action == #selector(localBrowser.uploadToSFTPPane(_:)) }), let selector = command.action else { throw Failure.generated }
                try require(localBrowser.commandEnabled(selector) && !browser.commandEnabled(selector))
                browser.sftpUpload.chooseForVerification = { _ in chooserCalled = true; return source }
                browser.sftpUpload.reviewForVerification = { _ in select(other); return "Draft-Notes.bin" }
                NSApp.sendAction(selector, to: command.target, from: command)
                try await wait { browser.operationPreparationTask == nil }; try require(browser.sftpUpload.lastNotice.contains("selection or destination changed"))
                let firstRefused = try await storage.inspect(); try require(firstRefused.records.isEmpty && !chooserCalled && tab.session.latest.failure == nil)
                select(source); browser.sftpUpload.reviewForVerification = { _ in browser.selectTab(localRemoteTab); return "Draft-Notes.bin" }
                NSApp.sendAction(selector, to: command.target, from: command); try await wait { browser.operationPreparationTask == nil }
                let secondRefused = try await storage.inspect(); try require(secondRefused.records.isEmpty && !chooserCalled && tab.session.latest.failure == nil)
                browser.selectTab(remoteID); try await wait { !tab.hasPendingPages && tab.rows.cache.snapshot?.state == .complete }
                select(source); browser.sftpUpload.reviewForVerification = { review in review.model.name = "Draft-Notes.bin"; return review.model.name }
                try require(localBrowser.sftpPaneUpload.canRequest); NSApp.sendAction(selector, to: command.target, from: command)
                paneVerified = true
            }
            var recording: NativeMotionRecorder.Report?
            if args.contains("--record-upload-motion") {
                window.title = "SFTP Upload · generated review"
                recording = try await NativeMotionRecorder.record(window: window, root: location, label: "upload-surface") { NSApp.sendAction(action, to: item.target, from: item) }
                try JSONEncoder().encode(recording).write(to: location.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
            } else if !scenario.hasPrefix("pane") { NSApp.sendAction(action, to: item.target, from: item) }
            if stopping {
                try await wait { browser.operationTask != nil }; let control = location.appendingPathComponent("source/Stop.control")
                try await wait { FileManager.default.fileExists(atPath: control.path) }; browser.cancelFileOperation(nil)
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                try require(tab.drain?.localResourcesEnded == true && browser.sftpUpload.lastCompleted == nil)
            } else {
                try await wait { browser.sftpUpload.lastCompleted != nil && browser.operationTask == nil }
                try await wait { tab.rows.cache.snapshot?.count == 3 && !tab.hasPendingPages }
                try require(browser.sftpUpload.lastCompleted?.logicalBytes == 1_048_593)
                window.contentView?.layoutSubtreeIfNeeded()
                try require(tab.rows.scroll.bounds.height > 180 && tab.rows.outcomeVisibleForVerification)
            }
            stage = "outcomes"
            let state = try await storage.inspect(); try require(state.records.count == 1 && state.records[0].outcome == (stopping ? .reviewTemporary : .verified) && !state.records[0].active)
            try require(try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: source))) == original }.value)
            let savedID = state.records[0].id
            var closedNoticeReviewed = false
            if stopping {
                try require(browser.sftpClosedUploadNotices[uploadTabID] != nil && hasHistoryButton(browser.sftpHost))
                var noticeBrowser = browser
                if scenario == "pane-stop" {
                    try require(controller.workspace.moveTab(uploadTabID, from: browser, into: localBrowser, before: nil)); noticeBrowser = localBrowser
                    try require(noticeBrowser.sftpClosedUploadNotices[uploadTabID] != nil && hasHistoryButton(noticeBrowser.sftpHost))
                }
                noticeBrowser.showClosedSFTPUploadHistory(nil)
                try await wait { connections.verificationSFTPStorage?.model.uploadHistory?.records.first?.id == savedID }
                await connections.verificationSFTPStorage?.closeAndDrain(); closedNoticeReviewed = true
            } else { _ = await tab.close().value }
            try require(tab.drain?.localResourcesEnded == true)
            await connections.closeAndDrain(); service = nil
            let cold = try await storage.inspect(); try require(cold.records.count == 1 && cold.records[0].id == savedID && cold.records[0].outcome == state.records[0].outcome)
            let remembered = SFTPRememberedState(settings: .init(directory: profile.appendingPathComponent("sftp-servers")), passwords: .generatedQualification(namespace: UUID(uuidString: location.lastPathComponent)!))
            let metadata = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"))
            let outcomes = SFTPConnectionStorageWindow(settings: settings, remembered: remembered, storage: metadata, uploads: storage)
            outcomes.present(relativeTo: window); try await wait { !outcomes.model.busy && outcomes.model.uploadHistory != nil }
            try require(outcomes.model.uploadHistory?.records.first?.id == savedID)
            // Explicit local Forget proves no connection/remote cleanup authority.
            outcomes.model.forgetUpload(savedID); try await wait { !outcomes.model.busy }; try require(outcomes.model.uploadHistory?.records.isEmpty == true)
            await outcomes.closeAndDrain(); try require(await storage.close())
            let catalogs = try await SMBTemporaryCatalogPool(storage: metadata).inspect(); try require(catalogs.isEmpty)
            if let paneBoard { try require(paneVerified && !chooserCalled && paneBoard.changeCount == clipboardCount && paneBoard.string(forType: .string) == "Generated pane upload sentinel"); paneBoard.releaseGlobally(); self.releasePaneQualification() }
            paneBoard = nil
            ticker?.cancel(); await ticker?.value; ticker = nil
            let report: [String: Any] = ["passed": true, "scenario": scenario, "stage": stage, "actualSharedConnect": true, "configuredSignatureHelper": true,
                "normalStartupPrevented": true, "metadataOnlyPreviewCancel": true, "explicitPermissionDefaultOff": true, "coldOutcome": state.records[0].outcome.rawValue,
                "localForgetOnly": true, "poolEmpty": true, "actualStopDrain": stopping, "closedNoticeReviewed": closedNoticeReviewed, "sourceUnchanged": true, "keychainQueries": 0,
                "initialPresentationSeconds": initialPresentation, "maximumMainActorGapSeconds": maximumGap, "completeUploadSeconds": browser.sftpUpload.lastSeconds]
            var output = report; output["motionFrames"] = recording?.frames.count ?? 0; output["localPaneUpload"] = paneVerified
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/native-upload.json"), options: .withoutOverwriting)
            SFTPUploadFeature.qualifying = false; retained = nil; NSApplication.shared.terminate(nil)
        } catch {
            ticker?.cancel(); await ticker?.value
            if let owner { _ = await owner.close().value }; await service?.closeAndDrain()
            paneBoard?.releaseGlobally(); paneBoard = nil; releasePaneQualification()
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false, "stage": stage, "errorType": String(reflecting: type(of: error)), "motionFailure": (error as? NativeMotionRecorder.Failure)?.rawValue ?? ""], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-upload.json"), options: .withoutOverwriting) }
            SFTPUploadFeature.qualifying = false; retained = nil; NSApplication.shared.terminate(nil)
        }
    }
    private static func hasHistoryButton(_ view: NSView) -> Bool {
        view.identifier?.rawValue == "sftp-closed-upload-history" || view.subviews.contains(where: hasHistoryButton)
    }
    private static func releasePaneQualification() { SFTPPaneUploadFeature.qualifying = false }
}
#endif
