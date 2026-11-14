#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
@_spi(ArchiveProduction) @_spi(Qualification) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) @testable import LocalStorage

/// Exact configured Debug app, generated loopback peer/profile only. This route
/// returns before normal startup and never saves a server, host or password.
@MainActor enum SFTPDownloadVerification {
    private enum Failure: Error { case generated, check(UInt) }
    private static var retained: BrowserWindowController?
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, seconds: Double = 12, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < deadline, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func runStandalone() async {
        if ProcessInfo.processInfo.arguments.contains("--batch-flow") { await runBatch(); return }
        let args = ProcessInfo.processInfo.arguments
        var root: URL?, service: ApplicationSMBConnections?, tab: SFTPTabController?, ticker: Task<Void, Never>?
        var stage = "input", maximumGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        do {
            func field(_ key: String) throws -> String {
                guard let at = args.firstIndex(of: key), args.indices.contains(at + 1) else { throw Failure.generated }; return args[at + 1]
            }
            let location = URL(fileURLWithPath: try field("--analysis-source")); root = location
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == location.path
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app")
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil)
            let scenario = try field("--download-scenario"); try require(["success", "stop", "layout", "pane", "pane-layout", "pane-access", "destination-identity"].contains(scenario))
            guard let port = UInt16(try field("--generated-port")), port > 0 else { throw Failure.generated }
            let fingerprint = try field("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            let controller = BrowserWindowController(settings: settings); retained = controller
            let browser = controller.browser, profile = location.appendingPathComponent("source/Profile")
            let destination = location.appendingPathComponent(["pane", "pane-access", "destination-identity"].contains(scenario) ? "source/Destination/Requested.bin" : "source/Destination/Received.bin")
            let bodies = profile.appendingPathComponent("remote-downloads"), vault = SFTPPasswordVault.generatedQualification(namespace: UUID(uuidString: location.lastPathComponent)!)
            let storage = try SFTPDownloadStorage(directory: bodies, publicQuarantinePolicy: .sourceQualification), metadata = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"))
            let engine = RecoverableFileOperations(journalDirectory: profile.appendingPathComponent("operation-recovery"), protecting: [bodies, profile.appendingPathComponent("sftp-servers"), metadata.directory], receivedDownloadPublicQuarantinePolicy: .sourceQualification)
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }; browser.recoverableFileOperations = engine
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.tabs = [BrowserTab(location: .directory(location.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id
            browser.loadLocation(); guard let window = controller.window else { throw Failure.generated }
            window.minSize = .init(width: 850, height: 530); window.setContentSize(.init(width: 900, height: 580)); window.title = "SFTP Download · generated review"; window.center(); window.makeKeyAndOrderFront(nil)
            if scenario == "layout" {
                stage = "offline-layout"; try await Task.sleep(for: .milliseconds(200))
                window.title = "SFTP Download · generated review"
                let original = window.frame
                var oversized = original; oversized.size.width = 1025; window.setFrame(oversized, display: false)
                do { try NativeMotionRecorder.validateScope(window: window, root: location, label: "download-layout"); throw Failure.generated }
                catch NativeMotionRecorder.Failure.scope {}
                oversized.size.width = 1024; window.setFrame(oversized, display: false)
                try NativeMotionRecorder.validateScope(window: window, root: location, label: "download-layout")
                window.setFrame(original, display: false)
                let geometry: [String: Any] = ["width": window.frame.width, "height": window.frame.height, "visible": window.isVisible, "generatedTitle": window.title.contains("generated review")]
                try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/window.json"), options: .withoutOverwriting)
                let report = try await NativeMotionRecorder.record(window: window, root: location, label: "download-layout") {
                    _ = browser.startOperationPresentation("Generated receive presentation only")
                    browser.operationPresentation = .init(phaseTitle: "Receive", percentage: 0.42, summary: "Generated presentation · no connection or file operation", currentItem: "Requested.bin")
                    browser.updateOperationProgressControls()
                }
                browser.finishOperationPresentation()
                try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
                try JSONSerialization.data(withJSONObject: ["passed": true, "scenario": scenario, "networkConnections": 0, "motionFrames": report.frames.count], options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/native-download.json"), options: .withoutOverwriting)
                retained = nil; NSApplication.shared.terminate(nil); return
            }
            var peerPane: BrowserViewController?
            if ["pane", "pane-layout", "pane-access", "destination-identity"].contains(scenario) {
                stage = "pane-layout"
                window.setContentSize(.init(width: 1140, height: 760))
                window.contentView?.superview?.layoutSubtreeIfNeeded(); await Task.yield()
                controller.workspace.willStartBrowserForVerification = { peer in
                    peer.permitsBackgroundVerification = true; peer.readVolumesForVerification = { [] }
                    peer.tabs = [BrowserTab(location: .directory(destination.deletingLastPathComponent()))]; peer.activeID = peer.tabs[0].id
                }
                let workspace = controller.workspace
                let facts: [String: Any] = ["canChange": workspace.canChangePaneLayout,
                    "trailing": workspace.canSplitActive(at: .trailing), "bottom": workspace.canSplitActive(at: .bottom),
                    "width": window.frame.width, "height": window.frame.height, "viewWidth": workspace.view.bounds.width, "viewHeight": workspace.view.bounds.height]
                try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/pane-layout.json"), options: .withoutOverwriting)
                let edge: PaneDropEdge = workspace.canSplitActive(at: .trailing) ? .trailing : .bottom
                try require(workspace.splitActive(at: edge))
                peerPane = controller.workspace.activeBrowser
                try await wait { peerPane?.isLoading == false }
                controller.workspace.activate(browser)
                if scenario == "pane-layout" {
                    try JSONSerialization.data(withJSONObject: ["passed": true, "scenario": scenario, "networkConnections": 0, "localPeerPane": true], options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/native-download.json"), options: .withoutOverwriting)
                    retained = nil; NSApplication.shared.terminate(nil); return
                }
            }
            let initialPresentation = ProcessInfo.processInfo.systemUptime - previous
            previous = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - previous); previous = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }}
            SFTPDownloadFeature.qualifying = true
            SFTPUploadFeature.qualifying = args.contains("--download-with-upload-mode")
            let connections = ApplicationSMBConnections(directory: profile, sftpPasswords: vault, sftpEnabled: true); service = connections
            stage = "connect"; connections.present(in: browser); try await wait { connections.verificationWindow?.model.managing == false }
            guard let connect = connections.verificationWindow else { throw Failure.generated }
            let model = connect.model; model.connectionProtocol = .sftp; model.address = "sftp://127.0.0.1:\(port)/"; model.account = "generated"
            model.password = "ephemeral qualification password"; model.name = "Generated Download"
            model.freshUploads = args.contains("--download-with-upload-mode")
            try require(!model.rememberPassword && !model.rememberServer)
            model.connect(); try await wait { connections.verificationSFTPTrust != nil || !model.busy }
            guard let trust = connections.verificationSFTPTrust else { throw Failure.generated }
            try require(trust.model.review.kind == .first && trust.model.review.fingerprint == fingerprint)
            trust.model.rememberKey = false; trust.model.proceed(); try await wait { !model.busy }
            try require(model.connected)
            guard let owner = browser.sftpTabs[browser.activeID] else { throw Failure.generated }; tab = owner
            try require(owner.session.allowsFreshUploads == args.contains("--download-with-upload-mode"))
            try await wait { owner.rows.cache.retainedCount == 2 && owner.session.latest.snapshot?.state == .complete && !owner.hasPendingPages }
            let table = owner.rows.table
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); try require(owner.rows.selectedDownload == nil)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); try require(owner.rows.selectedDownload?.logicalBytes == 1_048_593)
            try require(ApplicationOperationCoordinator.shared.protectedStorageLocations.contains(bodies) && !browser.commandEnabled(#selector(BrowserViewController.trashSelection(_:))))
            guard let item = table.menu?.items.first(where: { $0.title == "Download…" }), let action = item.action else { throw Failure.generated }
            try require(!item.isHidden && owner.rows.validateMenuItem(item))
            stage = "occupied-destination"
            let occupied = destination.deletingLastPathComponent().appendingPathComponent("Existing.txt")
            browser.sftpDownload.chooseForVerification = { _ in occupied }
            NSApp.sendAction(action, to: item.target, from: item)
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            try require(browser.sftpDownload.lastOutcome == nil && browser.sftpDownload.lastNotice.contains("not published"))
            let before = try await storage.inspect(); try require(before.isEmpty)
            var accessCounter: LeaseCounter?
            if scenario == "pane-access", let peerPane {
                stage = "pane-access"
                accessCounter = try await verifyPaneAccess(browser: browser, owner: owner, peer: peerPane,
                    storage: storage, root: location, destination: destination)
            }
            var destinationReplaced = false
            if scenario == "destination-identity" {
                browser.sftpDownload.receivedForQualification = {
                    let parent = destination.deletingLastPathComponent(), retained = location.appendingPathComponent("source/Retained original destination")
                    let metadata = try await Task.detached {
                        var before = stat(), after = stat()
                        guard lstat(parent.path, &before) == 0 else { throw Failure.generated }
                        try FileManager().moveItem(at: parent, to: retained)
                        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        guard lstat(parent.path, &after) == 0 else { throw Failure.generated }
                        return ["beforeDevice": Int64(before.st_dev), "beforeInode": Int64(before.st_ino),
                            "afterDevice": Int64(after.st_dev), "afterInode": Int64(after.st_ino)]
                    }.value
                    destinationReplaced = true
                    try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                        .write(to: location.appendingPathComponent("evidence/destination-replacement.json"), options: .withoutOverwriting)
                }
            }
            stage = "download"
            browser.sftpDownload.chooseForVerification = { _ in destination }
            // Navigation normally refreshes the native window title; restore
            // this exact generated label before the recorder's scope check.
            window.title = "SFTP Download · generated review"
            let geometry: [String: Any] = ["width": window.frame.width, "height": window.frame.height, "visible": window.isVisible, "generatedTitle": window.title.contains("generated review")]
            try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/window.json"), options: .withoutOverwriting)
            var recording: NativeMotionRecorder.Report?
            if args.contains("--record-download-motion") {
                recording = try await NativeMotionRecorder.record(window: window, root: location, label: "download-" + scenario) {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                try JSONEncoder().encode(recording).write(to: location.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
            } else {
                if ["pane", "pane-access", "destination-identity"].contains(scenario) { browser.sftpDownload.request(from: owner, toPane: true) }
                else { NSApp.sendAction(action, to: item.target, from: item) }
            }
            if scenario == "stop" {
                try await wait { browser.operationTask != nil }
                // The wrapper waits for the generated server's actual READ
                // observation before it writes this one exact control file.
                let control = location.appendingPathComponent("source/Stop.control")
                try await wait { FileManager.default.fileExists(atPath: control.path) }
                browser.cancelFileOperation(nil)
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                let retained = try await storage.inspect(); try require(retained.count == 1 && !retained[0].active && owner.drain?.localResourcesEnded == true)
                try require(!FileManager.default.fileExists(atPath: destination.path))
                let state = SFTPRememberedState(settings: .init(directory: profile.appendingPathComponent("sftp-servers")), passwords: vault)
                let review = SFTPConnectionStorageWindow(settings: settings, remembered: state, storage: metadata, downloads: storage)
                review.present(relativeTo: window); try await wait { !review.model.busy }
                try require(review.model.bodies.count == 1); review.model.discardBody(retained[0].id); try await wait { !review.model.busy }
                try require(review.model.bodies.isEmpty); await review.closeAndDrain()
            } else if scenario == "destination-identity" {
                stage = "destination-identity"
                try await wait { destinationReplaced && browser.operationTask == nil && browser.operationPreparationTask == nil }
                let retained = try await storage.inspect()
                let publicFile = FileManager().fileExists(atPath: destination.path)
                let probe: [String: Any] = ["publicFileExists": publicFile, "hasOperationOutcome": browser.sftpDownload.lastOutcome != nil,
                    "notice": browser.sftpDownload.lastNotice, "retainedBodyCount": retained.count,
                    "retainedBodiesInactive": retained.allSatisfy { !$0.active }]
                try JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys])
                    .write(to: location.appendingPathComponent("evidence/destination-identity.json"), options: .withoutOverwriting)
                try require(!publicFile && browser.sftpDownload.lastOutcome == nil && retained.count == 1 && !retained[0].active
                    && browser.sftpDownload.lastNotice.localizedCaseInsensitiveContains("destination changed"))
                // Only this generated, verified inactive staging is discarded.
                // The renamed original directory and both fixtures stay intact.
                try await storage.discardIncomplete(retained[0].id)
                browser.disconnectSFTPConnection(nil)
                try await wait { browser.sftpTabs[browser.activeID] == nil }
                try require(owner.drain?.localResourcesEnded == true && owner.drain?.temporaryStoreRemoved == true)
            } else {
                try await wait { browser.sftpDownload.lastOutcome != nil && browser.operationTask == nil }
                guard let outcome = browser.sftpDownload.lastOutcome, let id = outcome.recordID else { throw Failure.generated }
                try require(outcome.result.disposition == .succeeded && browser.lastRecoveryRecordID == id)
                let valid = try await Task.detached {
                    let data = try Data(contentsOf: destination)
                    let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
                    let previous = try Data(contentsOf: occupied)
                    return data.count == 1_048_593 && data.enumerated().allSatisfy { $0.element == UInt8((UInt64($0.offset) * 31 + 7) % 251) }
                        && quarantine != nil && previous == Data("Existing generated file".utf8)
                }.value
                try require(valid); let empty = try await storage.inspect(); try require(empty.isEmpty)
                if let peerPane { try await wait { peerPane.displayedEntries.contains(where: { $0.url == destination }) } }
                stage = "results-and-undo"
                browser.openOperationRecovery(recordID: id); try await wait { browser.recoveryWindow?.selectedRecordID == id && browser.recoveryRecords.contains(where: { $0.id == id && $0.canUndo }) }
                guard let record = browser.recoveryRecords.first(where: { $0.id == id }) else { throw Failure.generated }
                browser.startRecoveryOperation(record, rollback: false); try await wait { browser.operationTask == nil }
                try require(browser.lastOperationResult?.disposition == .succeeded && !FileManager.default.fileExists(atPath: destination.path))
                browser.recoveryWindow?.close(); browser.disconnectSFTPConnection(nil)
                try await wait { browser.sftpTabs[browser.activeID] == nil }; try require(owner.drain?.localResourcesEnded == true && owner.drain?.temporaryStoreRemoved == true)
            }
            stage = "drain"; await connections.closeAndDrain(); service = nil
            let endBodies = try await storage.inspect(), catalogs = try await SMBTemporaryCatalogPool(storage: metadata).inspect()
            try require(endBodies.isEmpty && catalogs.isEmpty)
            if let accessCounter {
                peerPane?.suspendBrowser()
                try await wait { accessCounter.active == 0 }
            }
            ticker?.cancel(); await ticker?.value; ticker = nil
            var report: [String: Any] = ["passed": true, "scenario": scenario, "stage": stage, "configuredSignatureHelper": true,
                "actualSharedConnect": true, "normalStartupPrevented": true, "metadataDefaultUntilExplicitAction": true,
                "occupiedDestinationPreservedBeforeBody": true, "sourceUnchanged": true, "poolEmpty": true,
                "exactResultsAndUndo": scenario != "stop" && scenario != "destination-identity", "actualStopDrain": scenario == "stop",
                "destinationIdentityRefused": scenario == "destination-identity", "localPeerPane": ["pane", "pane-access", "destination-identity"].contains(scenario), "keychainQueries": 0,
                "maximumMainActorGapSeconds": maximumGap, "motionFrames": recording?.frames.count ?? 0]
            report["uploadCapableSession"] = owner.session.allowsFreshUploads
            if let accessCounter {
                report["destinationLeaseStarts"] = accessCounter.starts
                report["destinationLeaseStops"] = accessCounter.stops
                report["appBodyRequests"] = browser.sftpDownload.bodyRequestsForQualification
            }
            report["initialPresentationSeconds"] = initialPresentation
            if let timing = browser.sftpDownload.lastTimings {
                report["receiveAndSealSeconds"] = timing.receive; report["publicationSeconds"] = timing.publication; report["completeDownloadSeconds"] = timing.complete
            }
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: location.appendingPathComponent("evidence/native-download.json"), options: .withoutOverwriting)
            SFTPDownloadFeature.qualifying = false; SFTPUploadFeature.qualifying = false; retained = nil; NSApplication.shared.terminate(nil)
        } catch {
            ticker?.cancel(); await ticker?.value
            if let tab { _ = await tab.close().value }; await service?.closeAndDrain()
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false, "stage": stage, "errorType": String(reflecting: type(of: error)), "motionFailure": (error as? NativeMotionRecorder.Failure)?.rawValue ?? ""], options: [.sortedKeys]).write(to: root.appendingPathComponent("evidence/native-download.json"), options: .withoutOverwriting) }
            SFTPDownloadFeature.qualifying = false; SFTPUploadFeature.qualifying = false; retained = nil; NSApplication.shared.terminate(nil)
        }
    }

    private static func verifyPaneAccess(browser: BrowserViewController, owner: SFTPTabController,
        peer: BrowserViewController, storage: SFTPDownloadStorage, root: URL, destination: URL) async throws -> LeaseCounter {
        let counter = LeaseCounter(), parent = destination.deletingLastPathComponent()
        peer.folderAccess = FolderAccessController(backend: counter)
        let choice = await peer.folderAccess.acceptChosenFolder(parent)
        choice?.lease.close()
        let baseline = counter.active
        var ownsChosenAccess = false, countAtAcquisition = -1
        defer {
            browser.sftpDownload.destinationAccessForQualification = nil
            browser.sftpDownload.destinationCheckedForQualification = nil
        }
        browser.sftpDownload.destinationAccessForQualification = { access in
            ownsChosenAccess = access.leases.contains { $0.url == parent }
            countAtAcquisition = counter.active
            // This ownership control deliberately cancels before body admission.
            browser.operationPreparationTask?.cancel()
        }
        browser.sftpDownload.request(from: owner, toPane: true)
        try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
        let empty = try await storage.inspect()
        let control: [String: Any] = ["ownsChosenAccess": ownsChosenAccess, "activeAtAcquisition": countAtAcquisition,
            "baseline": baseline, "activeAfterDrain": counter.active,
            "appBodyRequests": browser.sftpDownload.bodyRequestsForQualification, "emptyBodyPool": empty.isEmpty]
        try JSONSerialization.data(withJSONObject: control, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/pane-access-boundary.json"), options: .withoutOverwriting)
        try require(ownsChosenAccess && countAtAcquisition == baseline + 1 && counter.active == baseline
            && browser.sftpDownload.bodyRequestsForQualification == 0 && empty.isEmpty)

        for change in 0..<3 {
            var entered = false
            let action: () async -> Void = {
                entered = true
                if change == 0 { peer.navigate(to: .directory(root.appendingPathComponent("source/Local"))) }
                else { owner.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
            browser.sftpDownload.destinationAccessForQualification = change == 2 ? nil : { _ in await action() }
            browser.sftpDownload.destinationCheckedForQualification = change == 2 ? action : nil
            browser.sftpDownload.request(from: owner, toPane: true)
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            let unused = try await storage.inspect()
            let refused = entered && browser.sftpDownload.bodyRequestsForQualification == 0 && unused.isEmpty
                && browser.sftpDownload.lastOutcome == nil && !FileManager().fileExists(atPath: destination.path)
            try JSONSerialization.data(withJSONObject: ["passed": refused, "appBodyRequests": browser.sftpDownload.bodyRequestsForQualification,
                "emptyBodyPool": unused.isEmpty, "notice": browser.sftpDownload.lastNotice], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/pane-access-stale-\(change).json"), options: .withoutOverwriting)
            try require(refused)
            peer.navigate(to: .directory(parent)); try await wait { !peer.isLoading && peer.orderingTask == nil }
            owner.rows.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
        return counter
    }
    private final class LeaseCounter: FolderAccessBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, stopped = 0
        var starts: Int { lock.withLock { started } }
        var stops: Int { lock.withLock { stopped } }
        var active: Int { lock.withLock { started - stopped } }
        func startAccess(to url: URL) -> Bool { lock.withLock { started += 1 }; return true }
        func stopAccess(to url: URL) { lock.withLock { stopped += 1 } }
        func bookmark(for url: URL) throws -> Data { throw Failure.generated }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw Failure.generated }
    }

    /// The existing native download check also exercises the whole group UI
    /// against an in-memory peer. Actual SSH/runtime evidence remains separate.
    private static func runBatch() async {
        var area: URL?, browser: BrowserViewController?, window: NSWindow?, connection: SFTPTabController?
        var stage = "scope", checks: [String] = [], failed = false, motionAccepted = false
        let promiseFlow = ProcessInfo.processInfo.arguments.contains("--promise-flow")
        let folderFlow = promiseFlow && ProcessInfo.processInfo.arguments.contains("--folder-flow")
        let gestureFlow = promiseFlow && ProcessInfo.processInfo.arguments.contains("--interactive-sftp-promise")
        let externalReceiver = gestureFlow && !folderFlow
            && ProcessInfo.processInfo.arguments.contains("--external-promise-receiver")
        let evidenceName = externalReceiver ? "native-sftp-external-promise.json"
            : folderFlow ? "native-sftp-folder-drop.json" : promiseFlow ? "native-sftp-promise.json" : "native-download-batch.json"
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.generated }
            let root = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && root.resolvingSymlinksInPath() == root
                && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                && marker?["action"] as? String == (gestureFlow ? "native-sftp-promise-gesture" : "native-sftp-download-batch")
                && (marker?["externalPromiseReceiver"] as? Bool == true) == externalReceiver
                && (!ProcessInfo.processInfo.arguments.contains("--external-promise-receiver") || externalReceiver)
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            area = root
            let parent = root.appendingPathComponent("source/Destination"), partial = root.appendingPathComponent("source/Partial")
            for folder in [parent, partial] { try FileManager().createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let settings = BrowserSettings(persist: false), large = ProcessInfo.processInfo.arguments.contains("--large-interface")
            settings.appearance = large ? .light : .dark; settings.interfaceSize = .init(large ? 150 : 100)
            settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.startupMode = .computer
            if large { settings.motion.mode = .reduced }
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserViewController(settings: settings); browser = owner
            owner.readVolumesForVerification = { [] }; owner.permitsBackgroundVerification = true
            if externalReceiver { owner.folderAccess = FolderAccessController(stateDirectory: nil) }
            let workspace = BrowserWorkspaceController(primaryBrowser: owner)
            let storage = try SFTPDownloadStorage(directory: root.appendingPathComponent("state/downloads"),
                publicQuarantinePolicy: .sourceQualification, selectedGroupPublicQuarantinePolicy: .sourceQualification)
            let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"),
                protecting: [root.appendingPathComponent("state/downloads")],
                receivedDownloadPublicQuarantinePolicy: .sourceQualification,
                receivedFolderPublicQuarantinePolicy: RemoteDownloadPublicationFeature.qualifiesPublicQuarantineFolderDownload ? .sourceQualification : .held)
            owner.recoverableFileOperations = engine
            let host = ToolWindowChrome.makeWindow(title: "SFTP Download · generated review", size: .init(width: 920, height: 620), minimumSize: .zero)
            window = host; host.contentViewController = workspace; ToolWindowChrome.install(in: host, settings: settings)
            host.center(); host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            workspace.begin(); try await wait { workspace.sessionReady }
            let peer = BatchTransport(promiseGesture: gestureFlow, folders: folderFlow), session = SFTPBrowserSession(id: UUID(), transport: peer)
            if promiseFlow {
                SFTPFilePromiseFeature.qualifying = true
                SFTPFilePromiseFeature.externalForVerification = !folderFlow && (!gestureFlow || externalReceiver)
                SFTPFilePromiseFeature.requiresParentGrantForVerification = externalReceiver
            }
            let tab = SFTPTabController(session: session, address: try .init("sftp://generated.invalid"), title: "Generated files", downloads: storage,
                reviewsUploads: !folderFlow)
            connection = tab; owner.installSFTPTab(tab)
            try await wait { tab.rows.cache.retainedCount == 4 && !tab.hasPendingPages }
            let table = tab.rows.table
            if promiseFlow {
                stage = "promise-callbacks"
                if folderFlow {
                    stage = "folder-pane-flow"
                    checks = try await verifyFolderPane(browser: owner, tab: tab, peer: peer, storage: storage,
                        engine: engine, root: root, parent: parent, window: host, workspace: workspace, gesture: gestureFlow)
                } else if externalReceiver {
                    stage = "external-finder-promise"
                    checks = try await verifyExternalPromiseReceiver(browser: owner, tab: tab, peer: peer,
                        storage: storage, engine: engine, root: root, parent: parent, window: host, workspace: workspace)
                } else if gestureFlow {
                    checks = try await verifyPromiseGesture(browser: owner, tab: tab, peer: peer,
                        storage: storage, engine: engine, root: root, parent: parent, window: host, workspace: workspace)
                } else {
                    checks = try await verifyPromiseFlow(browser: owner, tab: tab, peer: peer, storage: storage,
                        root: root, parent: parent, workspace: workspace)
                }
                let promisesDrained = await ApplicationSFTPFilePromises.shared.closeAndDrain()
                try require(promisesDrained && ApplicationSFTPFilePromises.shared.countForVerification == 0)
                _ = await tab.close().value; owner.suspendBrowser(); host.close()
                SFTPFilePromiseFeature.qualifying = false
                SFTPFilePromiseFeature.externalForVerification = nil
                SFTPFilePromiseFeature.requiresParentGrantForVerification = false
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "networkConnections": 0,
                    "keychainCalls": 0, "nativeProviderCallbacks": externalReceiver ? 1 : gestureFlow || folderFlow ? 0 : 6,
                    "actualReceiverDrag": externalReceiver, "actualFinderReceiver": externalReceiver,
                    "actualTraversePaneDrops": gestureFlow && !externalReceiver ? (folderFlow ? 1 : 2) : 0,
                    "previewActivation": false], options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/" + evidenceName), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return
            }
            stage = "selection-and-cancel"
            table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
            try require(tab.rows.selectedDownloadBatch == nil)
            table.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
            try require(tab.sealedBatchDownload?.items.count == 3 && owner.remoteBatchDownload.canRequest(from: tab))
            guard let command = table.menu?.items.first(where: { $0.title == "Download…" }), let action = command.action else { throw Failure.generated }
            try require(tab.rows.validateMenuItem(command))
            owner.remoteBatchDownload.chooseForVerification = { _ in nil }
            NSApp.sendAction(action, to: command.target, from: command)
            try await wait { owner.remoteBatchDownload.work == nil }
            let before = await peer.downloads, empty = try await storage.inspect()
            try require(before == 0 && empty.isEmpty)
            checks.append("Mixed folders/files refuse; one Cancel leaves body/history untouched")

            stage = "whole-destination-preflight"
            let occupied = parent.appendingPathComponent("Second.txt")
            try Data("Keep existing".utf8).write(to: occupied, options: .withoutOverwriting)
            owner.remoteBatchDownload.chooseForVerification = { _ in parent }
            NSApp.sendAction(action, to: command.target, from: command)
            try await wait { owner.remoteBatchDownload.work == nil }
            let refused = await peer.downloads
            try require(refused == 0 && Data(contentsOf: occupied) == Data("Keep existing".utf8))
            try FileManager().removeItem(at: occupied)
            checks.append("Every target is checked before any body and existing files stay exact")

            stage = "receive-and-publication"
            NSApp.sendAction(action, to: command.target, from: command)
            try await wait { owner.remoteBatchDownload.work == nil && owner.operationTask == nil }
            guard let batch = owner.operationHistory.downloadBatch else { throw Failure.generated }
            try require(batch.completed == 3 && batch.result.disposition == .succeeded)
            for name in BatchTransport.fileNames {
                try require(Data(contentsOf: parent.appendingPathComponent(name)) == BatchTransport.body(name))
            }
            let drained = try await storage.inspect(), bodyCount = await peer.downloads
            try require(drained.isEmpty && bodyCount == 3)
            checks.append("One native group command receives all three files then publishes exact local bodies")

            stage = "results-and-selected-undo"
            owner.showLastOperationResult(nil)
            try await wait { host.attachedSheet != nil }
            guard let sheet = host.attachedSheet, let content = sheet.contentView else { throw Failure.generated }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let results = descendants(content).compactMap({ $0 as? OperationResultsView }).first,
                  let rows = descendants(results).compactMap({ $0 as? NSTableView }).first,
                  let undo = descendants(results).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Undo Selected File" }) else { throw Failure.generated }
            try require(rows.numberOfRows == 3)
            rows.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try require(undo.isEnabled)
            host.title = "SFTP Download · generated review"
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(350))
            try JSONSerialization.data(withJSONObject: ["appActive": NSApp.isActive, "mainVisible": host.isVisible,
                "mainAlpha": host.alphaValue, "sheetVisible": sheet.isVisible, "sheetAlpha": sheet.alphaValue,
                "sheetOnscreen": sheet.occlusionState.contains(.visible), "parentMatches": sheet.sheetParent === host,
                "mainOnscreen": host.occlusionState.contains(.visible), "mainFrame": NSStringFromRect(host.frame),
                "sheetFrame": NSStringFromRect(sheet.frame), "mainActiveSpace": host.isOnActiveSpace,
                "sheetActiveSpace": sheet.isOnActiveSpace, "keyNumber": NSApp.keyWindow?.windowNumber ?? -1,
                "mainNumber": host.windowNumber, "sheetNumber": sheet.windowNumber,
                "orderedNumbers": NSApp.orderedWindows.map(\.windowNumber),
                "screens": NSScreen.screens.map { NSStringFromRect($0.visibleFrame) },
                "contentHidden": content.isHidden, "sheetChildren": content.subviews.count,
                "captureTarget": "ownedParentWithAttachedSheet"], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/results-window-state.json"), options: .withoutOverwriting)
            // The sheet's internal window number need not name a compositor
            // surface. Its visible, owned parent includes the real sheet and
            // avoids accepting an all-black internal-window capture.
            try await GlassVerification.captureOwnedWindow(host, to: root.appendingPathComponent("evidence/batch-results-parent.png"))
            if ProcessInfo.processInfo.arguments.contains("--record-download-motion") {
                do {
                    let report = try await NativeMotionRecorder.record(window: host, root: root, label: "download-batch-results", sampling: .diagnostic(for: host)) {
                        rows.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                        rows.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                    }
                    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
                    motionAccepted = true
                } catch {
                    try JSONSerialization.data(withJSONObject: ["passed": false, "errorType": String(reflecting: type(of: error)), "functionalCheckContinues": true])
                        .write(to: root.appendingPathComponent("evidence/motion-result.json"), options: .withoutOverwriting)
                }
            }
            undo.performClick(nil)
            try await wait { owner.operationHistory.downloadBatch?.items[1].undone == true && owner.operationTask == nil }
            try require(!FileManager().fileExists(atPath: parent.appendingPathComponent("Second.txt").path))
            for name in ["First.txt", "Third.txt"] { try require(Data(contentsOf: parent.appendingPathComponent(name)) == BatchTransport.body(name)) }
            owner.showLastOperationResult(nil)
            try await wait { host.attachedSheet != nil }
            if let sheet = host.attachedSheet { host.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            owner.recoveryWindow?.close()
            checks.append("Results preserve the group after one exact fresh-record Undo; other files remain unchanged")

            stage = "changed-download-undo-refusal"
            try await wait { host.attachedSheet == nil }
            let changed = parent.appendingPathComponent("First.txt"), changedBytes = Data("Keep changed local download\n".utf8)
            try changedBytes.write(to: changed)
            owner.showLastOperationResult(nil)
            try await wait { host.attachedSheet != nil }
            guard let refusalSheet = host.attachedSheet, let refusalContent = refusalSheet.contentView,
                  let refusalRows = descendants(refusalContent).compactMap({ $0 as? NSTableView }).first,
                  let refusalUndo = descendants(refusalContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Undo Selected File" }) else { throw Failure.generated }
            refusalRows.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try require(refusalUndo.isEnabled); refusalUndo.performClick(nil)
            stage = "changed-download-undo-outcome"
            try await wait { owner.operationHistory.downloadBatch?.items[0].undoNeedsReview == true && owner.operationTask == nil }
            try require(Data(contentsOf: changed) == changedBytes)
            try require(Data(contentsOf: parent.appendingPathComponent("Third.txt")) == BatchTransport.body("Third.txt"))
            owner.showLastOperationResult(nil)
            stage = "changed-download-undo-attention"
            try await wait { host.attachedSheet != nil }
            guard let attentionSheet = host.attachedSheet, let attentionContent = attentionSheet.contentView,
                  let attentionResults = descendants(attentionContent).compactMap({ $0 as? OperationResultsView }).first,
                  let attentionToggle = descendants(attentionContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Show only items needing attention" }) else { throw Failure.generated }
            try require(attentionToggle.state == .on && attentionResults.visibleItems.count == 1)
            try require(owner.operationHistory.downloadBatch?.describe(attentionResults.visibleItems[0]).title == "Undo needs review")
            host.endSheet(attentionSheet, returnCode: .alertFirstButtonReturn)
            checks.append("Changed local downloads refuse Undo, preserve their bytes and remain visible in the needs-attention results")

            stage = "partial-local-publication"
            try await wait { host.attachedSheet == nil }
            owner.remoteBatchDownload.chooseForVerification = { _ in partial }
            owner.remoteBatchDownload.beforePublicationForVerification = { index in
                if index == 1 { try? Data("Keep late arrival".utf8).write(to: partial.appendingPathComponent("Second.txt"), options: .withoutOverwriting) }
            }
            NSApp.sendAction(action, to: command.target, from: command)
            try await wait { owner.remoteBatchDownload.work == nil && owner.operationTask == nil }
            guard let partialResult = owner.operationHistory.downloadBatch else { throw Failure.generated }
            try require(partialResult.completed == 1 && partialResult.items[1].outcome == nil && partialResult.items[2].outcome == nil)
            try require(Data(contentsOf: partial.appendingPathComponent("First.txt")) == BatchTransport.body("First.txt"))
            try require(Data(contentsOf: partial.appendingPathComponent("Second.txt")) == Data("Keep late arrival".utf8))
            try require(!FileManager().fileExists(atPath: partial.appendingPathComponent("Third.txt").path))
            let retained = try await storage.inspect(); try require(retained.count == 2 && retained.allSatisfy { !$0.active })
            for entry in retained { try await storage.discardIncomplete(entry.id) }
            checks.append("A late conflict preserves the committed prefix and existing file, publishes no tail and retains only inactive staging")

            stage = "ordinary-other-pane-command"
            owner.remoteBatchDownload.beforePublicationForVerification = nil
            var unexpectedPicker = false
            owner.remoteBatchDownload.chooseForVerification = { _ in unexpectedPicker = true; return nil }
            let paneParent = root.appendingPathComponent("source/Pane Destination")
            try FileManager().createDirectory(at: paneParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workspace.activate(owner)
            try require(workspace.splitActive(at: .trailing))
            let receiver = workspace.activeBrowser; receiver.permitsBackgroundVerification = true
            receiver.navigate(to: .directory(paneParent))
            try await wait { !receiver.isLoading && receiver.location.directoryURL == paneParent }
            workspace.activate(owner); owner.focusBrowserContent()
            table.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
            try require(owner.commandEnabled(#selector(BrowserViewController.copyToOtherPane(_:))))
            try require(!owner.commandEnabled(#selector(BrowserViewController.moveToOtherPane(_:))))
            let fileMenu = BrowserMenus.menu(.file, target: owner)
            guard let copyIndex = fileMenu.items.firstIndex(where: { $0.action == #selector(BrowserViewController.copyToOtherPane(_:)) }) else { throw Failure.generated }
            fileMenu.performActionForItem(at: copyIndex)
            try await wait { owner.remoteBatchDownload.work == nil && owner.operationTask == nil }
            try require(!unexpectedPicker && owner.operationHistory.downloadBatch?.completed == 3)
            for name in BatchTransport.fileNames { try require(Data(contentsOf: paneParent.appendingPathComponent(name)) == BatchTransport.body(name)) }
            let finalStorage = try await storage.inspect(); try require(finalStorage.isEmpty)
            workspace.activate(receiver); try require(workspace.closeActivePane())
            checks.append("The ordinary File-menu Copy to Other Pane downloads the sealed group without a chooser; remote Move stays disabled")
            let projection = DiagnosticErrors.project(SFTPDownloadBatchIssue.tooLarge)
            try require(projection.code == 864)
        } catch {
            failed = true
            if let area { try? JSONSerialization.data(withJSONObject: ["passed": false, "failureStage": stage, "errorType": String(reflecting: type(of: error)), "error": String(describing: error), "checks": checks], options: [.sortedKeys]).write(to: area.appendingPathComponent("evidence/" + evidenceName)) }
        }
        SFTPFilePromiseFeature.qualifying = false
        SFTPFilePromiseFeature.externalForVerification = nil
        SFTPFilePromiseFeature.requiresParentGrantForVerification = false
        guard await ApplicationSFTPFilePromises.shared.closeAndDrain() else { return }
        if let connection { _ = await connection.close().value }
        browser?.suspendBrowser(); window?.close()
        if !failed, let area {
            try? JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "networkConnections": 0, "keychainCalls": 0, "ordinarySource": true, "motionAccepted": motionAccepted], options: [.sortedKeys])
                .write(to: area.appendingPathComponent("evidence/native-download-batch.json"))
        }
        NSApplication.shared.terminate(nil)
    }

    /// The same generated peer and ordinary SFTP row now reach a real external
    /// NSFilePromiseReceiver. Finder and the native parent picker are driven by
    /// the existing dev.py case; this is Debug receiver evidence, not a server
    /// or signed sandbox qualification.
    private static func verifyExternalPromiseReceiver(browser: BrowserViewController, tab: SFTPTabController,
        peer: BatchTransport, storage: SFTPDownloadStorage, engine: RecoverableFileOperations,
        root: URL, parent: URL, window: NSWindow, workspace: BrowserWorkspaceController) async throws -> [String] {
        let name = "Generated Promise.txt", delivered = parent.appendingPathComponent(name)
        let before = try await storage.inspect(), initialDownloads = await peer.downloads
        try require(before.isEmpty && initialDownloads == 0 && !FileManager.default.fileExists(atPath: delivered.path))
        try require(SFTPFilePromiseFeature.externalAvailable && SFTPFilePromiseFeature.requiresParentGrantForVerification)
        var handed: [SFTPFilePromiseExport] = []
        browser.sftpDownload.promiseHandoffForVerification = { [weak browser] job in
            handed.append(job)
            job.settledForVerification = { [weak browser, weak job] confirmedRecord in
                guard let browser, let job, let identifier = confirmedRecord,
                      browser.lastOperationResult?.disposition == .succeeded,
                      browser.lastRecoveryRecordID == identifier,
                      job.externalCallbackURLForVerification?.path == delivered.path else {
                    ArchivePromiseGestureVerification.report("failed", ["stage": "SFTP-external-promise-publication"])
                    return
                }
                ArchivePromiseGestureVerification.report("write-completed", ["recordID": identifier.uuidString,
                    "nativeCallback": true, "parentChoices": job.parentChoicesForVerification])
            }
            ArchivePromiseGestureVerification.report("gesture-admitted", ["ordinarySFTPRows": true, "providers": 1])
        }
        defer { browser.sftpDownload.promiseHandoffForVerification = nil }
        workspace.activate(browser)
        // This early Debug entry returns before ordinary startup installs the
        // app menu. Reuse it so native window positioning remains available.
        NSApp.mainMenu = BrowserMenus.applicationMenu(target: browser)
        let table = tab.rows.table
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try require(tab.rows.selectedDownload?.row.entry.name.displayName == name)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(.init(x: screen.minX + 16, y: screen.minY + 30,
            width: min(740, screen.width * 0.46), height: min(700, screen.height - 60)), display: true)
        window.title = "Generated SFTP Finder promise · " + root.lastPathComponent.prefix(8)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try require(window.makeFirstResponder(table))
        ArchivePromiseGestureVerification.report("ready", ["ordinarySFTPRows": true,
            "receiver": "Finder", "simulatedPeer": true, "generatedDestination": true])
        guard await readGestureControl() == Data("finish\n".utf8) else { throw CancellationError() }
        try require(handed.count == 1)
        await handed[0].drain()
        if let inspection = browser.recoveryInspectionTask { await inspection.value }
        try await wait { browser.operationCoordinator.inspectionCount == 0
            && ApplicationSFTPFilePromises.shared.countForVerification == 0 }
        guard let identifier = browser.lastRecoveryRecordID,
              browser.lastOperationResult?.disposition == .succeeded else { throw Failure.generated }
        let deliveredFacts = try await Task.detached { () throws -> (Data, Bool) in
            let facts = try delivered.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .quarantinePropertiesKey])
            guard facts.isRegularFile == true, facts.fileSize == BatchTransport.body(name).count else {
                throw Failure.generated
            }
            let body = try Data(contentsOf: delivered)
            let marked = facts.quarantineProperties?.isEmpty == false
            return (body, marked)
        }.value
        let after = try await storage.inspect(), downloads = await peer.downloads
        let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: identifier)
        let history = try await engine.inspectExistingHistory()
        try require(handed[0].externalCallbackURLForVerification?.path == delivered.path
            && handed[0].parentChoicesForVerification == 1
            && deliveredFacts.0 == BatchTransport.body(name) && deliveredFacts.1
            && downloads == 1 && after.isEmpty && catalog.version == 14
            && catalog.purpose == "receivedFile" && catalog.state == "committed"
            && catalog.requiresPublicQuarantine
            && history.records.contains { $0.id == identifier && $0.canUndo })
        ArchivePromiseGestureVerification.report("publication-acknowledged", ["recordID": identifier.uuidString,
            "oneParentChooser": true, "documentedPropertyPresent": true, "simulatedPeer": true])
        let fresh = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"),
            receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let undone = await fresh.undo(recordID: identifier)
        let gone = await Task.detached { !FileManager.default.fileExists(atPath: delivered.path) }.value
        try require(undone.result.disposition == .succeeded && gone)
        ArchivePromiseGestureVerification.report("undo-completed", ["recordID": identifier.uuidString,
            "succeeded": true, "freshEngine": true])
        return ["Actual Finder callback delivers one selected SFTP row to its exact receiver leaf after a native parent choice",
            "The generated peer remains offline; v14 documented-property publication and fresh-engine Undo complete"]
    }

    /// Actual SFTP rows and ordinary local-pane drop admission. The parent
    /// independently verifies each delivery before acknowledging cold Undo.
    /// This reuses the existing workspace and simulated peer; no receiver app.
    private static func verifyPromiseGesture(browser: BrowserViewController, tab: SFTPTabController,
        peer: BatchTransport, storage: SFTPDownloadStorage, engine: RecoverableFileOperations,
        root: URL, parent: URL, window: NSWindow, workspace: BrowserWorkspaceController) async throws -> [String] {
        let name = "Generated Promise.txt"
        var handed: [SFTPFilePromiseExport] = []
        browser.sftpDownload.promiseHandoffForVerification = { [weak browser] job in
            handed.append(job)
            job.settledForVerification = { [weak browser] confirmedRecord in
                guard let browser, browser.lastOperationResult?.disposition == .succeeded,
                      let identifier = confirmedRecord,
                      browser.lastRecoveryRecordID == identifier else {
                    ArchivePromiseGestureVerification.report("failed", ["stage": "SFTP-promise-publication"])
                    return
                }
                ArchivePromiseGestureVerification.report("write-completed", ["recordID": identifier.uuidString,
                    "ordinarySFTPRows": true, "phase": "single"])
            }
            ArchivePromiseGestureVerification.report("gesture-admitted", ["ordinarySFTPRows": true, "providers": 1])
        }
        defer { browser.sftpDownload.promiseHandoffForVerification = nil }
        workspace.activate(browser)
        try require(workspace.splitActive(at: .trailing))
        let receiver = workspace.activeBrowser
        receiver.permitsBackgroundVerification = true
        receiver.dragDrop.permitsVerification = true
        receiver.recoverableFileOperations = engine
        receiver.navigate(to: .directory(parent))
        try await wait { !receiver.isLoading && receiver.location.directoryURL == parent }
        workspace.activate(browser)
        tab.rows.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try require(tab.rows.selectedDownload?.row.entry.name.displayName == name)
        let before = try await storage.inspect(), beforeDownloads = await peer.downloads
        try require(before.isEmpty && beforeDownloads == 0)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(.init(x: screen.minX + 24, y: screen.minY + 30,
            width: min(1300, screen.width - 48), height: min(700, screen.height - 60)), display: true)
        window.title = "Generated SFTP pane drag · " + root.lastPathComponent.prefix(8)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try require(window.makeFirstResponder(tab.rows.table))
        receiver.dragDrop.selectionDidChange()
        try await wait { receiver.dragDrop.hasPreparedDestinationForVerification(parent)
            && !receiver.dragDrop.verificationState.preparing }
        guard let observedTarget = receiver.dragDrop.preparedDestinationForVerification(parent) else { throw Failure.generated }
        ArchivePromiseGestureVerification.report("target-readiness", [
            "exactURLObjects": observedTarget.observation.urls == [observedTarget.directory],
            "samePath": observedTarget.observation.urls.map(\.path) == [observedTarget.directory.path]])
        try require(observedTarget.matchesObservedDirectory)
        ArchivePromiseGestureVerification.report("ready", ["phase": "single", "ordinarySFTPRows": true,
            "simulatedPeer": true, "networkConnections": 0, "receiver": "Traverse local pane"])
        let control = await readGestureControl()
        guard control == Data("finish\n".utf8) else { throw CancellationError() }
        try require(!handed.isEmpty)
        for job in handed { await job.drain() }
        if let inspection = browser.recoveryInspectionTask { await inspection.value }
        try await wait { browser.operationCoordinator.inspectionCount == 0
            && ApplicationSFTPFilePromises.shared.countForVerification == 0 }
        guard let identifier = browser.lastRecoveryRecordID,
              browser.lastOperationResult?.disposition == .succeeded else { throw Failure.generated }
        let delivered = parent.appendingPathComponent(name)
        let bytes = try await Task.detached { try Data(contentsOf: delivered) }.value
        let history = try await engine.inspectExistingHistory(), after = try await storage.inspect()
        let downloads = await peer.downloads
        try require(bytes == BatchTransport.body(name) && downloads == 1 && after.isEmpty
            && history.records.contains { $0.id == identifier && $0.canUndo })
        try await wait { !receiver.isLoading && receiver.displayedEntries.contains { $0.url.lastPathComponent == name } }
        ArchivePromiseGestureVerification.report("publication-acknowledged", ["recordID": identifier.uuidString,
            "phase": "single", "independentReaderFinished": true, "visibleInDestination": true])
        try await Task.sleep(for: .seconds(1))
        let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"), receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let undone = await cold.undo(recordID: identifier)
        let gone = await Task.detached { !FileManager().fileExists(atPath: delivered.path) }.value
        try require(undone.result.disposition == .succeeded && gone)
        browser.operationCoordinator.reloadLocalDirectory(parent)
        try await wait { !receiver.isLoading && !receiver.displayedEntries.contains { $0.url.lastPathComponent == name } }
        ArchivePromiseGestureVerification.report("undo-completed", ["succeeded": true, "coldEngine": true,
            "phase": "single", "recordID": identifier.uuidString])

        let groupParent = root.appendingPathComponent("source/Group Destination")
        try FileManager().createDirectory(at: groupParent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        receiver.navigate(to: .directory(groupParent))
        try await wait { !receiver.isLoading && receiver.location.directoryURL == groupParent }
        workspace.activate(browser)
        tab.rows.table.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
        try require(tab.rows.selectedDownloadBatch?.items.count == 3)
        var unexpectedChooser = false
        browser.remoteBatchDownload.chooseForVerification = { _ in unexpectedChooser = true; return nil }
        defer { browser.remoteBatchDownload.chooseForVerification = nil }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try require(window.makeFirstResponder(tab.rows.table))
        receiver.dragDrop.selectionDidChange()
        try await wait { receiver.dragDrop.hasPreparedDestinationForVerification(groupParent)
            && !receiver.dragDrop.verificationState.preparing }
        let monitor = Task { @MainActor in
            while browser.remoteBatchDownload.work == nil { try await Task.sleep(for: .milliseconds(20)) }
            while browser.remoteBatchDownload.work != nil || browser.operationTask != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let batch = browser.operationHistory.downloadBatch, batch.completed == 3,
                  batch.result.disposition == .succeeded else {
                ArchivePromiseGestureVerification.report("failed", ["stage": "SFTP-group-drop-publication"])
                return
            }
            try await wait { !receiver.isLoading && receiver.displayedEntries.count == 3 }
            ArchivePromiseGestureVerification.report("write-completed", ["phase": "group", "files": 3,
                "ordinarySFTPRows": true, "visibleInDestination": true])
        }
        defer { monitor.cancel() }
        ArchivePromiseGestureVerification.report("ready", ["phase": "group", "ordinarySFTPRows": true,
            "files": 3, "receiver": "Traverse local pane", "networkConnections": 0])
        let groupControl = await readGestureControl()
        guard groupControl == Data("finish\n".utf8) else { throw CancellationError() }
        try await monitor.value
        guard let batch = browser.operationHistory.downloadBatch else { throw Failure.generated }
        let names = [name, "Second.txt", "Third.txt"]
        try require(!unexpectedChooser && batch.completed == 3 && !batch.retainedStaging
            && batch.items.count == 3 && batch.parent == groupParent)
        for file in names {
            let body = try await Task.detached { try Data(contentsOf: groupParent.appendingPathComponent(file)) }.value
            try require(body == BatchTransport.body(file))
        }
        let finalDownloads = await peer.downloads, finalStorage = try await storage.inspect()
        try require(finalDownloads == 4 && finalStorage.isEmpty)
        let records = try batch.items.map { try needRecord($0.outcome?.recordID) }
        try await Task.sleep(for: .seconds(1))
        for record in records {
            let result = await cold.undo(recordID: record)
            try require(result.result.disposition == .succeeded)
        }
        for file in names {
            let gone = await Task.detached { !FileManager().fileExists(atPath: groupParent.appendingPathComponent(file).path) }.value
            try require(gone)
        }
        browser.operationCoordinator.reloadLocalDirectory(groupParent)
        try await wait { !receiver.isLoading && receiver.displayedEntries.isEmpty }
        ArchivePromiseGestureVerification.report("undo-completed", ["phase": "group", "coldEngine": true,
            "succeeded": true, "recordIDs": records.map(\.uuidString), "files": 3])
        return ["Actual one-file drag from ordinary SFTP rows into another Traverse pane publishes exact bytes and cold Undo",
            "Actual three-file native group drop reuses the batch receiver without a chooser and each independent cold Undo",
            "Network transport is simulated; no server, Keychain, Trash or external receiver acceptance is claimed"]
    }
    private static func needRecord(_ value: UUID?) throws -> UUID {
        guard let value else { throw Failure.generated }; return value
    }
    private static func readGestureControl() async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            var line = Data()
            for _ in 0..<8 {
                guard let byte = try? FileHandle.standardInput.read(upToCount: 1), byte.count == 1 else { return nil }
                line.append(byte)
                if byte.first == 10 { return line }
            }
            return nil
        }.value
    }

    /// A folder drop supplies only the captured destination to the existing
    /// metadata review, tree receipt, publication and whole-operation Undo.
    private static func verifyFolderPane(browser: BrowserViewController, tab: SFTPTabController,
        peer: BatchTransport, storage: SFTPDownloadStorage, engine: RecoverableFileOperations,
        root: URL, parent: URL, window: NSWindow, workspace: BrowserWorkspaceController,
        gesture: Bool) async throws -> [String] {
        workspace.activate(browser); try require(workspace.splitActive(at: .trailing))
        let receiver = workspace.activeBrowser
        receiver.permitsBackgroundVerification = true; receiver.dragDrop.permitsVerification = true
        receiver.recoverableFileOperations = engine; receiver.navigate(to: .directory(parent))
        try await wait { !receiver.isLoading && receiver.location.directoryURL == parent }
        workspace.activate(browser); tab.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        guard let selected = tab.rows.selectedFolderDownload else { throw Failure.generated }
        let observed = try await browser.fileOperations.observeDirectory(parent)
        let destination = ArchiveExtractionDestination(directory: parent, observation: observed, access: .init(leases: []))
        var chooserCalls = 0, reviews = 0, validReviews = true
        browser.sftpFolderDownload.chooseForVerification = { _ in chooserCalls += 1; return nil }
        browser.sftpFolderDownload.reviewForVerification = { review in
            reviews += 1
            validReviews = validReviews && review.model.summary.files == 2 && review.model.summary.folders == 2
                && review.model.summary.logicalBytes == UInt64(BatchTransport.folderBody.count)
            return reviews == 1 ? .cancel : .download(review.model.name)
        }
        defer {
            browser.sftpFolderDownload.chooseForVerification = nil
            browser.sftpFolderDownload.reviewForVerification = nil
        }
        try require(!browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
            destination: .init(directory: root, observation: observed, access: .init(leases: [])), current: { true }))
        try require(!browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
            destination: destination, current: { false }))
        try require(browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
            destination: destination, current: { true }))
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        let cancelFacts = await peer.folderFacts, cancelStorage = try await storage.inspect()
        let cancelHistory = try await engine.inspectExistingHistory()
        try require(reviews == 1 && validReviews && chooserCalls == 0 && cancelFacts == [1, 1, 0]
            && browser.sftpFolderDownload.bodyRequestsForVerification == 0 && cancelStorage.isEmpty
            && tab.session.latest.failure == nil && cancelHistory.records.isEmpty)
        let folder = parent.appendingPathComponent("Folder")
        try require(!FileManager().fileExists(atPath: folder.path))
        var checks = ["Wrong-parent and stale target drops refuse; Cancel releases metadata with zero body, history or destination mutation"]

        if gesture {
            window.title = "Generated SFTP folder drag · " + root.lastPathComponent.prefix(8)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try require(window.makeFirstResponder(tab.rows.table))
            receiver.dragDrop.selectionDidChange()
            try await wait { receiver.dragDrop.hasPreparedDestinationForVerification(parent)
                && !receiver.dragDrop.verificationState.preparing }
            ArchivePromiseGestureVerification.report("ready", ["phase": "folder", "files": 2,
                "ordinarySFTPRows": true, "simulatedPeer": true, "receiver": "Traverse local pane"])
            let monitor = Task { @MainActor in
                while browser.sftpFolderDownload.bodyRequestsForVerification == 0 { try await Task.sleep(for: .milliseconds(20)) }
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                guard let outcome = browser.sftpFolderDownload.lastOutcome,
                      outcome.result.disposition == .succeeded, let record = outcome.recordID else {
                    ArchivePromiseGestureVerification.report("failed", ["stage": "SFTP-folder-drop-publication"]); return
                }
                ArchivePromiseGestureVerification.report("write-completed", ["phase": "folder", "recordID": record.uuidString])
            }
            defer { monitor.cancel() }
            guard await readGestureControl() == Data("finish\n".utf8) else { throw CancellationError() }
            try await monitor.value
        } else {
            let writer = tab.rows.tableView(tab.rows.table, pasteboardWriterForRow: 0)
            try require(writer is NSPasteboardItem && !(writer is NSFilePromiseProvider))
            try require(browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
                destination: destination, current: { true }))
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        }
        guard let result = browser.sftpFolderDownload.lastOutcome, let record = result.recordID else { throw Failure.generated }
        let body = try await Task.detached { try Data(contentsOf: folder.appendingPathComponent("Notes/Report.txt")) }.value
        let facts = await peer.folderFacts, after = try await storage.inspect()
        try require(result.result.disposition == .succeeded && validReviews && reviews == 2 && chooserCalls == 0
            && facts == [2, 1, 1] && after.isEmpty && body == BatchTransport.folderBody
            && FileManager().fileExists(atPath: folder.appendingPathComponent("Empty").path)
            && Data(contentsOf: folder.appendingPathComponent("Zero.txt")).isEmpty)
        try await wait { !receiver.isLoading && receiver.displayedEntries.contains { $0.url.lastPathComponent == "Folder" } }
        // A second drop into the same name is refused before another metadata
        // review or body request. The confirmed first result remains unchanged.
        try require(browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
            destination: destination, current: { true }))
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
        let collisionFacts = await peer.folderFacts
        try require(collisionFacts == facts && reviews == 2 && browser.sftpFolderDownload.lastOutcome?.recordID == record)
        let publicTree = RemoteDownloadPublicationFeature.qualifiesPublicQuarantineFolderDownload
        if publicTree {
            let requirement = try await engine.undoAccessRequirement(recordID: record)
            try require(requirement?.directory.path == parent.path)
        }
        let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"),
            receivedDownloadPublicQuarantinePolicy: .sourceQualification,
            receivedFolderPublicQuarantinePolicy: publicTree ? .sourceQualification : .held)
        if gesture { try await Task.sleep(for: .seconds(1)) }
        let undone = await cold.undo(recordID: record)
        try require(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: folder.path))
        browser.operationCoordinator.reloadLocalDirectory(parent)
        try await wait { !receiver.isLoading && receiver.displayedEntries.isEmpty }
        if gesture {
            ArchivePromiseGestureVerification.report("undo-completed", ["phase": "folder", "coldEngine": true,
                "succeeded": true, "recordID": record.uuidString, "files": 2])
        }
        checks.append("One folder drop reuses review, exact nested/zero-byte/empty-directory delivery, visible refresh, collision refusal and whole-folder cold Undo")
        if !gesture {
            // The same ordinary controller also covers the Normal connection
            // path without a review adapter or another confirmation sheet.
            browser.sftpFolderDownload.reviewForVerification = nil
            let normalParent = root.appendingPathComponent("source/Normal Destination", isDirectory: true)
            try await Task.detached {
                try FileManager().createDirectory(at: normalParent, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }.value
            receiver.navigate(to: .directory(normalParent))
            try await wait { !receiver.isLoading && receiver.location.directoryURL == normalParent }
            let normalObservation = try await browser.fileOperations.observeDirectory(normalParent)
            try require(!tab.reviewsUploads && browser.sftpFolderDownload.requestDropped(from: tab, expected: selected,
                destination: .init(directory: normalParent, observation: normalObservation, access: .init(leases: [])),
                current: { true }))
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
            guard let normal = browser.sftpFolderDownload.lastOutcome, let normalID = normal.recordID else { throw Failure.generated }
            let normalFolder = normalParent.appendingPathComponent("Folder", isDirectory: true)
            let normalBody = try await Task.detached { try Data(contentsOf: normalFolder.appendingPathComponent("Notes/Report.txt")) }.value
            let normalFacts = await peer.folderFacts, normalStorage = try await storage.inspect()
            try require(normalID != record && normal.result.disposition == .succeeded
                && window.attachedSheet == nil && reviews == 2 && chooserCalls == 0
                && normalFacts == [3, 1, 2] && normalStorage.isEmpty && normalBody == BatchTransport.folderBody
                && FileManager().fileExists(atPath: normalFolder.appendingPathComponent("Empty").path)
                && Data(contentsOf: normalFolder.appendingPathComponent("Zero.txt")).isEmpty)
            try await wait { !receiver.isLoading && receiver.displayedEntries.contains { $0.url.lastPathComponent == "Folder" } }
            let normalUndo = await cold.undo(recordID: normalID)
            try require(normalUndo.result.disposition == .succeeded && !FileManager().fileExists(atPath: normalFolder.path))
            browser.operationCoordinator.reloadLocalDirectory(normalParent)
            try await wait { !receiver.isLoading && receiver.displayedEntries.isEmpty }
            checks.append("Normal folder drop starts directly without a confirmation or review adapter, publishes exact contents, refreshes its pane and Undoes through the same cold engine")
        }
        checks.append("No external folder promise, server, Keychain, Trash or new filesystem writer")
        return checks
    }

    /// Reuses the generated in-memory SFTP peer. Direct native callbacks cover
    /// source admission and local publication; a real drag receiver is a
    /// separate activation gate and is deliberately not claimed by this run.
    private static func verifyPromiseFlow(browser: BrowserViewController, tab: SFTPTabController,
        peer: BatchTransport, storage: SFTPDownloadStorage, root: URL, parent: URL,
        workspace: BrowserWorkspaceController) async throws -> [String] {
        let table = tab.rows.table, responses = PromiseResponses()
        let existing = parent.appendingPathComponent("Occupied.txt")
        try Data("Keep existing".utf8).write(to: existing, options: .withoutOverwriting)
        func offer() throws -> (NSFilePromiseProvider, SFTPFilePromiseDelegate, SFTPFilePromiseExport) {
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            guard let provider = tab.rows.tableView(table, pasteboardWriterForRow: 1) as? NSFilePromiseProvider,
                  let delegate = provider.userInfo as? SFTPFilePromiseDelegate else { throw Failure.generated }
            let board = NSPasteboard(name: .init("Traverse.Generated.SFTPPromise." + UUID().uuidString))
            defer { board.releaseGlobally() }
            try require(board.writeObjects([provider]))
            let nativeTypes = NSFilePromiseReceiver.readableDraggedTypes
            try require(board.types?.contains(where: { nativeTypes.contains($0.rawValue) }) == true)
            browser.sftpDownload.promiseBegan(from: tab, rows: IndexSet(integer: 1))
            guard let job = browser.sftpDownload.activePromiseForVerification else { throw Failure.generated }
            return (provider, delegate, job)
        }
        func deliver(_ offer: (NSFilePromiseProvider, SFTPFilePromiseDelegate, SFTPFilePromiseExport),
            to target: URL, key: String) {
            offer.1.filePromiseProvider(offer.0, writePromiseTo: target) { responses.receive(key, $0) }
        }
        func finish(_ job: SFTPFilePromiseExport, key: String, operation: NSDragOperation = .copy) async throws {
            await job.drain()
            try await wait { responses.status(key).count == 1 && ApplicationSFTPFilePromises.shared.countForVerification == 0 }
            browser.sftpDownload.promiseEnded(operation: operation)
        }
        let initialBodies = try await storage.inspect(), initialDownloads = await peer.downloads
        try require(initialBodies.isEmpty && initialDownloads == 0)
        var checks: [String] = []

        let stopped = try offer()
        guard let credentials = URL(string: "file://user:secret@localhost/tmp/Receiver.txt"),
              let port = URL(string: "file://localhost:445/tmp/Receiver.txt") else { throw Failure.generated }
        try require(stopped.2.candidate.destinationName(at: credentials) == nil
            && stopped.2.candidate.destinationName(at: port) == nil)
        checks.append("A callback URL with embedded credentials or an authority port is refused before body admission")
        deliver(stopped, to: parent.appendingPathComponent("Stopped.txt"), key: "stopped")
        stopped.2.stop(); try await finish(stopped.2, key: "stopped", operation: [])
        let stoppedDownloads = await peer.downloads, stoppedBodies = try await storage.inspect()
        try require(responses.status("stopped") == [CocoaError.userCancelled.rawValue]
            && stoppedDownloads == 0 && !FileManager().fileExists(atPath: parent.appendingPathComponent("Stopped.txt").path)
            && stoppedBodies.isEmpty)
        checks.append("A stopped handed offer completes its native callback once without receiving a body or publishing")

        let conflict = try offer()
        deliver(conflict, to: existing, key: "conflict")
        try await finish(conflict.2, key: "conflict")
        let conflictDownloads = await peer.downloads, conflictBodies = try await storage.inspect()
        try require(responses.status("conflict") == [CocoaError.fileWriteFileExists.rawValue]
            && conflictDownloads == 0 && Data(contentsOf: existing) == Data("Keep existing".utf8)
            && conflictBodies.isEmpty)
        checks.append("An occupied callback leaf is refused before body admission and preserves the existing bytes")

        let accepted = try offer(), delivered = parent.appendingPathComponent("Receiver First.txt")
        let beforeAccepted = try await storage.inspect(), beforeAcceptedDownloads = await peer.downloads
        try require(beforeAccepted.isEmpty && beforeAcceptedDownloads == 0)
        deliver(accepted, to: delivered, key: "accepted")
        try await finish(accepted.2, key: "accepted")
        guard let recordID = browser.lastRecoveryRecordID else { throw Failure.generated }
        let acceptedBodies = try await storage.inspect(), acceptedDownloads = await peer.downloads
        try require(responses.status("accepted") == [0] && Data(contentsOf: delivered) == BatchTransport.body("First.txt")
            && acceptedBodies.isEmpty && acceptedDownloads == 1)
        accepted.1.filePromiseProvider(accepted.0, writePromiseTo: parent.appendingPathComponent("Replay.txt")) {
            responses.receive("replay", $0)
        }
        try require(responses.status("replay") == [CocoaError.fileWriteUnknown.rawValue]
            && !FileManager().fileExists(atPath: parent.appendingPathComponent("Replay.txt").path))
        browser.openOperationRecovery(recordID: recordID)
        try await wait { browser.recoveryRecords.contains(where: { $0.id == recordID && $0.canUndo }) }
        if let inspection = browser.recoveryInspectionTask { await inspection.value }
        try await wait { browser.operationCoordinator.inspectionCount == 0 }
        browser.recoveryWindow?.close()
        let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"), receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let undone = await cold.undo(recordID: recordID)
        try require(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: delivered.path))
        checks.append("An exact renamed native callback publishes selected bytes once, exposes Results and survives cold Undo; replay is refused")

        let internalParent = root.appendingPathComponent("source/Internal Destination")
        try FileManager().createDirectory(at: internalParent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let internalObservation = try await browser.fileOperations.observeDirectory(internalParent)
        workspace.activate(browser)
        try require(workspace.splitActive(at: .trailing))
        let receiver = workspace.activeBrowser
        receiver.permitsBackgroundVerification = true
        receiver.recoverableFileOperations = browser.recoverableFileOperations
        receiver.navigate(to: .directory(internalParent))
        try await wait { !receiver.isLoading && receiver.location.directoryURL == internalParent }
        workspace.activate(browser)
        try JSONSerialization.data(withJSONObject: [
            "exactURLObjects": internalObservation.urls == [internalParent],
            "samePath": internalObservation.urls.map(\.path) == [internalParent.path]], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/internal-destination-shape.json"), options: .withoutOverwriting)
        let internalOffer = try offer()
        try require(!internalOffer.2.requestInternal(to: .init(directory: parent,
            observation: internalObservation, access: .init(leases: [])), current: { true }))
        let beforeInternal = await peer.downloads
        try require(beforeInternal == 1)
        SFTPFilePromiseFeature.externalForVerification = false
        defer { SFTPFilePromiseFeature.externalForVerification = nil }
        let refused = internalParent.appendingPathComponent("Unqualified external.txt")
        deliver(internalOffer, to: refused, key: "external-held")
        try await wait { responses.status("external-held").count == 1 }
        await internalOffer.2.drain()
        internalOffer.2.request(url: refused, completion: ArchivePromiseCompletion { responses.receive("direct-held", $0) })
        let afterRefusal = await peer.downloads, afterRefusalBodies = try await storage.inspect()
        try require(responses.status("external-held") == [CocoaError.fileWriteUnknown.rawValue]
            && responses.status("direct-held") == [CocoaError.fileWriteUnknown.rawValue]
            && afterRefusal == beforeInternal && afterRefusalBodies.isEmpty
            && internalOffer.2.canReceiveInternal && !FileManager().fileExists(atPath: refused.path))
        try require(internalOffer.2.requestInternal(to: .init(directory: internalParent,
            observation: internalObservation, access: .init(leases: [])), current: { true }))
        await internalOffer.2.drain()
        browser.sftpDownload.promiseEnded(operation: .copy)
        try await wait { ApplicationSFTPFilePromises.shared.countForVerification == 0 }
        guard let internalRecord = browser.lastRecoveryRecordID else { throw Failure.generated }
        try require(browser.lastOperationResult?.disposition == .succeeded
            && Data(contentsOf: internalParent.appendingPathComponent("First.txt")) == BatchTransport.body("First.txt"))
        try await wait { !receiver.isLoading && receiver.displayedEntries.contains { $0.url.lastPathComponent == "First.txt" } }
        let internalUndo = await cold.undo(recordID: internalRecord)
        try require(internalUndo.result.disposition == .succeeded)
        browser.operationCoordinator.reloadLocalDirectory(internalParent)
        try await wait { !receiver.isLoading && receiver.displayedEntries.isEmpty }
        workspace.activate(receiver); try require(workspace.closeActivePane())
        SFTPFilePromiseFeature.externalForVerification = true
        checks.append("Refused external delegate and direct callbacks receive no body and do not consume the same offer's internal delivery, visible refresh or cold Undo")

        let changed = try offer(), oldParent = root.appendingPathComponent("source/Retained original destination")
        changed.2.receivedForVerification = {
            try await Task.detached {
                let files = FileManager()
                try files.moveItem(at: parent, to: oldParent)
                try files.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }.value
        }
        deliver(changed, to: parent.appendingPathComponent("Changed parent.txt"), key: "changed")
        try await finish(changed.2, key: "changed")
        let held = try await storage.inspect(), changedDownloads = await peer.downloads
        try require(responses.status("changed") == [CocoaError.fileWriteUnknown.rawValue]
            && changedDownloads == 3 && held.count == 1 && held.allSatisfy { !$0.active }
            && !FileManager().fileExists(atPath: parent.appendingPathComponent("Changed parent.txt").path)
            && Data(contentsOf: oldParent.appendingPathComponent("Occupied.txt")) == Data("Keep existing".utf8))
        for entry in held { try await storage.discardIncomplete(entry.id) }
        try require((try await storage.inspect()).isEmpty)
        checks.append("Replacing the observed parent after receipt refuses publication and keeps only inactive review staging")
        return checks
    }

    private final class PromiseResponses: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [Int]] = [:]
        func receive(_ key: String, _ error: Error?) {
            lock.withLock { replies[key, default: []].append(error.map { ($0 as NSError).code } ?? 0) }
        }
        func status(_ key: String) -> [Int] { lock.withLock { replies[key] ?? [] } }
    }

    private actor BatchTransport: SFTPDirectoryTransport {
        nonisolated let allowsRequestedDownloads = true
        nonisolated let allowsRequestedFolderDownloads: Bool
        private let promiseGesture: Bool
        private var generation = UUID(), complete = false
        private var folderRequest: UUID?, folderPrepares = 0, folderReleases = 0, folderReceives = 0
        var folderFacts: [Int] { [folderPrepares, folderReleases, folderReceives] }
        private(set) var downloads = 0
        static let fileNames = ["First.txt", "Second.txt", "Third.txt"]
        init(promiseGesture: Bool = false, folders: Bool = false) {
            self.promiseGesture = promiseGesture; allowsRequestedFolderDownloads = folders
        }
        nonisolated static let folderBody = Data("Traverse generated folder control\n".utf8)
        nonisolated static func body(_ name: String) -> Data {
            name == "Generated Promise.txt" ? Data("Traverse generated promise control\n".utf8)
                : Data(("Generated " + name + "\n").utf8)
        }
        private var snapshot: SFTPStoredSnapshot { .init(read: 1, revision: 1, count: complete ? 4 : 0, folders: complete ? 1 : 0, state: complete ? .complete : .loading) }
        func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) { generation = UUID(); complete = false; return (generation, snapshot) }
        func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { complete = true; return snapshot }
        func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
            guard generation == self.generation else { throw SFTPBrowserFailure.stale }
            let folder = SFTPStoredRow(observation: 1, entry: .init(name: try .init(Data("Folder".utf8)), logicalBytes: nil, modifiedSeconds: 1, permissions: 0o040700))
            let names = promiseGesture ? ["Generated Promise.txt"] + Self.fileNames.dropFirst() : Self.fileNames
            let files = try names.enumerated().map { index, name in
                SFTPStoredRow(observation: UInt64(index + 2), entry: .init(name: try .init(Data(name.utf8)), logicalBytes: UInt64(Self.body(name).count), modifiedSeconds: 1, permissions: 0o100600))
            }
            return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: 0, rows: [folder] + files)
        }
        func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile, progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPDownloadReceipt {
            downloads += 1
            let bytes = Self.body(selection.row.entry.name.displayName)
            try await file.append(request: selection.request, offset: 0, bytes: bytes); progress?(UInt64(bytes.count))
            return .init(selection: selection, receivedBytes: UInt64(bytes.count))
        }
        func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection,
            progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload {
            guard allowsRequestedFolderDownloads, folderRequest == nil, selection.generation == generation,
                  selection.row.entry.name.displayName == "Folder" else { throw SFTPBrowserFailure.stale }
            let manifest = try SFTPFolderManifest(nodes: [
                .init(components: [], size: nil, modified: 1, permissions: 0o040700),
                .init(components: [Data("Empty".utf8)], size: nil, modified: 1, permissions: 0o040700),
                .init(components: [Data("Notes".utf8)], size: nil, modified: 1, permissions: 0o040700),
                .init(components: [Data("Notes".utf8), Data("Report.txt".utf8)], size: UInt64(Self.folderBody.count), modified: 1, permissions: 0o100600),
                .init(components: [Data("Zero.txt".utf8)], size: 0, modified: 1, permissions: 0o100600)])
            let prepared = try SFTPPreparedFolderDownload(selection: selection, manifest: manifest)
            folderRequest = selection.request; folderPrepares += 1; return prepared
        }
        func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws {
            guard folderRequest == prepared.selection.request else { throw SFTPBrowserFailure.stale }
            folderRequest = nil; folderReleases += 1
        }
        func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
            progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPFolderDownloadReceipt {
            guard folderRequest == prepared.selection.request else { throw SFTPBrowserFailure.stale }
            for (ordinal, node) in prepared.manifest.nodes.enumerated() where !node.directory {
                try tree.beginMember(request: prepared.selection.request, ordinal: ordinal)
                if node.size != 0 {
                    try tree.appendOnSessionExecutor(request: prepared.selection.request, ordinal: ordinal,
                        offset: 0, bytes: Self.folderBody)
                }
                try tree.endMember(request: prepared.selection.request, ordinal: ordinal, receivedBytes: node.size!)
            }
            folderRequest = nil; folderReceives += 1
            return .init(request: prepared.selection.request, bytes: prepared.logicalBytes, files: prepared.files)
        }
        func close() async -> SFTPWorkerClose { .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true) }
    }
}
#endif
