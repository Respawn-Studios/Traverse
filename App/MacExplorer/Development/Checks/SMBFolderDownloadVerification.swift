#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
@_spi(Qualification) @testable import LocalStorage

@MainActor enum SMBFolderDownloadVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static var host: BrowserWindowController?
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 30
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var hit = false
        var pending: Bool { lock.withLock { hit } }
        func observe(_ bytes: UInt64) { if bytes >= 32768, lock.withLock({ if hit { return false }; hit = true; return true }) { _ = semaphore.wait(timeout: .now() + 3) } }
        func release() { semaphore.signal() }
    }
    private static func password() async throws -> SMBPassword {
        let data = try await Task.detached {
            var data = Data()
            while data.count <= 64 {
                var f = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), byte: UInt8 = 0
                guard poll(&f, 1, 2000) > 0, Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { throw Failure.scope }
                if byte == 10 { return data }; data.append(byte)
            }; throw Failure.scope
        }.value
        guard data.count == 64, data.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), let text = String(data: data, encoding: .ascii) else { throw Failure.scope }
        return try SMBPassword(text)
    }
    static func run() async {
        var root: URL?, session: SMBBrowserSession?, owner: SMBTabController?, bodies: SMBDownloadStorage?, catalogs: SMBTemporaryStorage?
        var stage = "scope", failure: UInt?, failureType: String?, helperFailure: String?, checks: [String] = [], clips: [[String: Any]] = [], drain: SMBBrowserDrainResult?
        let barrier = Barrier()
        do {
            let arguments = ProcessInfo.processInfo.arguments
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"], let at = arguments.firstIndex(of: "--smb-folder-scenario"), arguments.indices.contains(at + 1) else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), scenario = arguments[at + 1]
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "smb-folder-download-native" && ["preflight", "success", "stop"].contains(scenario)
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = area; SMBDownloadFeature.qualifying = true; SMBFolderDownloadFeature.qualifying = true
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = scenario == "stop" ? .light : .dark
            settings.motion.mode = scenario == "stop" ? .reduced : .full; settings.interfaceSize = .init(scenario == "stop" ? 150 : 100)
            InterfacePresentation.shared.bind(settings)
            let windowOwner = BrowserWindowController(settings: settings); host = windowOwner; let browser = windowOwner.browser
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.tabs = [.init(location: .directory(area.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            let profile = area.appendingPathComponent("source/Profile"), pool = profile.appendingPathComponent("remote-downloads"), journal = profile.appendingPathComponent("history")
            let storage = try SMBDownloadStorage(directory: pool); bodies = storage
            let metadata = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"), sessionByteLimit: 8 << 20, poolByteLimit: SMBTemporaryStorage.maximumSessionBytes); catalogs = metadata
            let engine = RecoverableFileOperations(journalDirectory: journal, protecting: [pool, metadata.directory]); browser.recoverableFileOperations = engine
            guard let window = windowOwner.window else { throw Failure.scope }
            window.setContentSize(.init(width: 1180, height: 680)); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            window.contentView?.superview?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
            stage = "layout"
            windowOwner.workspace.willStartBrowserForVerification = { next in
                next.permitsBackgroundVerification = true; next.readVolumesForVerification = { [] }
                next.tabs = [.init(location: .directory(area.appendingPathComponent("source/Destination")))]; next.activeID = next.tabs[0].id
            }
            try require(windowOwner.workspace.splitActive(at: .trailing)); let receiver = windowOwner.workspace.activeBrowser
            try await wait { !receiver.isLoading }; windowOwner.workspace.activate(browser)
            checks.append("Actual two-pane local destination settles without inspecting personal drives")
            if scenario == "preflight" {
                stage = "preflight"
                let address = try SMBConnectionAddress(server: "127.0.0.1", port: 10445, share: "FolderEncryptedQA")
                stage = "helper-identity"
                _ = try await Task.detached { try SMBBundledHelperIdentity.prepare(.browser, bundle: Bundle.main.bundleURL) }.value
                stage = "endpoint"
                _ = try await SMBPreparedConnection.prepareValidated(address, bundleURL: Bundle.main.bundleURL, activity: ApplicationSMBActivity.gate)
                stage = "catalog-reserve"
                let catalog = try await SMBTemporaryCatalogPool(storage: metadata).reserve()
                stage = "catalog-release"; try require(await catalog.finishWithoutWorker())
                try require(try await storage.inspect().isEmpty)
                stage = "recorder-scope"
                window.title = "SMB folders · generated review"
                try NativeMotionRecorder.validateScope(window: window, root: area, label: "smb-folder-details")
                window.title = "Ordinary window"
                var ordinaryRefused = false
                do { try NativeMotionRecorder.validateScope(window: window, root: area, label: "smb-folder-details") }
                catch NativeMotionRecorder.Failure.scope { ordinaryRefused = true }
                try require(ordinaryRefused)
                window.title = "SMB folders · generated review"
                checks.append("Current signed helper, catalog lifecycle and passive body inspection pass without credentials or network")
                checks.append("Recorder admits only this exact generated F1 window and refuses an ordinary title, without capture")
                stage = "finished"; throw Finished.done
            }
            guard let portAt = arguments.firstIndex(of: "--generated-port"), arguments.indices.contains(portAt + 1), let port = UInt16(arguments[portAt + 1]), port > 1024 else { throw Failure.scope }
            let address = try SMBConnectionAddress(server: "127.0.0.1", port: port, share: "FolderEncryptedQA"), draft = try SMBServerDraft(name: "Generated folders", address: address, account: "nobody", domain: "", security: .encrypted)
            stage = "connect"
            let endpoint = try await SMBPreparedConnection.prepareValidated(address, bundleURL: Bundle.main.bundleURL, activity: ApplicationSMBActivity.gate), secret = try await password()
            let opened = try await SMBBrowserSession.connectPrepared(bundleURL: Bundle.main.bundleURL, request: draft, endpoint: endpoint, storage: metadata,
                activity: ApplicationSMBActivity.gate, password: secret, selectedDownloads: true, folderDownloads: true); session = opened
            let tab = SMBTabController(session: opened, share: address.share, title: "Generated folders", downloads: storage); owner = tab; browser.installSMBTab(tab)
            try await wait {
                guard let snapshot = opened.latest.snapshot else { return false }
                return opened.latest.idle && snapshot.state == .complete && !tab.hasPendingPages && Int64(tab.rows.cache.retainedCount) == snapshot.count
            }
            try require(opened.latest.security == .encrypted && opened.allowsFolderDownloads)
            guard let row = (0..<tab.rows.table.numberOfRows).first(where: { tab.rows.cache.entry(at: Int64($0))?.name.displayName == "Folder" }) else { throw Failure.scope }
            tab.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try require(tab.selectedDownload == nil && tab.selectedFolderDownload != nil && browser.smbDownload.canRequest(from: tab, toPane: true))
            var reviews = 0, reviewFailure = false
            browser.smbFolderDownload.reviewForVerification = { review in
                reviews += 1; let pending = Task { @MainActor in await review.choose(in: window) }
                do {
                    try await wait { window.attachedSheet === review.window }; try await Task.sleep(for: .milliseconds(200))
                    if reviews == 2, scenario == "success" {
                        window.title = "SMB folders · generated review"
                        let report = try await NativeMotionRecorder.record(window: window, root: area, label: "smb-folder-details", sampling: .diagnostic(for: window)) { review.model.details = true }
                        try JSONEncoder().encode(report).write(to: area.appendingPathComponent("evidence/smb-folder-motion.json"), options: .withoutOverwriting)
                        clips.append(DevelopmentMotionVerification.clip("smb-folder-details", report: report, field: nil, window: window))
                    }
                    try require(SFTPFolderUploadPreviewVerification.pressDownload(in: review, cancel: reviews == 1))
                } catch { reviewFailure = true; review.finish(.cancel) }
                return await pending.value
            }
            stage = "cancel-review"
            browser.smbDownload.request(from: tab, toPane: true); try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
            try require(reviews == 1 && !reviewFailure && browser.smbFolderDownload.bodyRequestsForVerification == 0 && opened.latest.failure == nil)
            try require(try await storage.inspect().isEmpty); try require(try await engine.inspectExistingHistory().records.isEmpty)
            checks.append("Actual native Cancel closes prepared directory handles, with no body reservation or history")
            stage = "download"
            if scenario == "stop" { browser.smbFolderDownload.didReceiveBytesForVerification = { barrier.observe($0) } }
            browser.smbDownload.request(from: tab, toPane: true)
            if scenario == "stop" { try await wait { barrier.pending }; browser.cancelFileOperation(nil); barrier.release() }
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
            try require(reviews == 2 && !reviewFailure)
            let output = area.appendingPathComponent("source/Destination/Folder")
            if scenario == "stop" {
                let pending = try await storage.inspect(); try require(pending.count == 1 && !pending[0].active && pending[0].isFolder && pending[0].observedBytes >= 32768)
                try require(!FileManager().fileExists(atPath: output.path) && browser.smbFolderDownload.lastOutcome == nil)
                drain = await tab.close().value; try await storage.discardIncomplete(pending[0].id)
                checks.append("Stop after a real append drains the helper and retains one inactive, explicitly discardable tree; nothing publishes")
            } else {
                guard let result = browser.smbFolderDownload.lastOutcome, let id = result.recordID else { throw Failure.scope }
                try require(result.result.disposition == .succeeded)
                let exact = try await Task.detached {
                    let paths: [String: Int] = ["Café/Report.bin":65537,"Large.bin":1 << 20,"One.bin":1,"Zero.bin":0]
                    for (name, count) in paths {
                        let url = output.appendingPathComponent(name), data = try Data(contentsOf: url)
                        guard data.count == count, data.enumerated().allSatisfy({ $0.element == UInt8($0.offset % 251) }), try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { return false }
                    }
                    return try FileManager().contentsOfDirectory(atPath: output.appendingPathComponent("Empty").path).isEmpty
                }.value
                try require(exact && browser.lastRecoveryRecordID == id)
                browser.openOperationRecovery(recordID: id); try await wait { browser.recoveryWindow?.selectedRecordID == id }; browser.recoveryWindow?.close()
                let cold = RecoverableFileOperations(journalDirectory: journal, protecting: [pool, metadata.directory]), undone = await cold.undo(recordID: id)
                try require(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: output.path))
                checks.append("Native Download to Other Pane checks four exact files plus two folders, inherits quarantine, shows exact Results and cold-Undoes")
            }
            stage = "drain"; if drain == nil { drain = await tab.close().value }
            try require(drain?.actualExit == true && drain?.pipeDrained == true && drain?.socketAndCatalogDrained == true && drain?.ownerReleased == true && drain?.forcedContainment == false)
            try require(try await storage.inspect().isEmpty); try require(try await SMBTemporaryCatalogPool(storage: metadata).inspect().isEmpty)
            try require(ApplicationSMBActivity.gate.activeCount == 0)
            checks.append("Actual worker, IPC, socket, catalog, staging and activity owners drain without remote mutation or Keychain use")
            stage = "finished"
        } catch Finished.done {} catch {
            if case Failure.check(let line) = error { failure = line } else { failure = 0 }
            failureType = String(reflecting: type(of: error))
            if let value = error as? SMBTemporaryStorageFailure { helperFailure = String(describing: value) }
            if let value = error as? SMBBundledHelperIdentity.Failure { helperFailure = String(describing: value) }
        }
        barrier.release()
        if let owner { let closed = await owner.close().value; if drain == nil { drain = closed } }
        else if let session { drain = await session.close() }
        host?.browser.suspendBrowser(); host?.window?.close(); host = nil; SMBDownloadFeature.qualifying = false; SMBFolderDownloadFeature.qualifying = false
        if let root {
            let pending = try? await bodies?.inspect(), remaining = try? await catalogs.map { SMBTemporaryCatalogPool(storage: $0) }?.inspect()
            let report: [String: Any] = ["passed":failure == nil,"stage":stage,"failureLine":failure as Any? ?? NSNull(),"failureType":failureType as Any? ?? NSNull(),"helperFailure":helperFailure as Any? ?? NSNull(),"checks":checks,"keychainCalls":0,
                "actualExit":drain?.actualExit as Any? ?? NSNull(),"pipeDrained":drain?.pipeDrained as Any? ?? NSNull(),"socketAndCatalogDrained":drain?.socketAndCatalogDrained as Any? ?? NSNull(),
                "contained":drain?.forcedContainment as Any? ?? NSNull(),"activityDrained":ApplicationSMBActivity.gate.activeCount == 0,
                "remainingBodies":pending?.count as Any? ?? NSNull(),"remainingCatalogs":remaining?.count as Any? ?? NSNull(),"commandCounts":session?.commandCounts as Any? ?? NSNull(),"clips":clips]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("evidence/native-smb-folder.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private enum Finished: Error { case done }
}
#endif
