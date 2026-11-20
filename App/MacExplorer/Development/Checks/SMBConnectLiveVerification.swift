#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// Actual form -> coordinator -> generated Keychain namespace -> signed worker
/// -> native tab. No fake authenticated success and no ordinary activation.
@MainActor enum SMBConnectLiveVerification {
    private static let namespace = UUID(uuidString: "5A2FE3FA-68B5-4B8E-AD37-F5E0567FAD98")!
    static func run(root: URL, phase: String, browser: BrowserViewController) async throws -> [String: Any] {
        if ["uploads", "uploads-cold", "uploads-retained", "uploads-preflight", "uploads-folders", "uploads-folders-cold", "uploads-folders-retained", "uploads-new-items", "uploads-new-items-cold", "file-actions", "file-actions-cold", "directory-actions", "directory-actions-cold", "file-actions-move", "file-actions-move-cold", "file-actions-cut", "file-actions-cut-cold", "file-actions-copy", "file-actions-copy-cold", "editor-original", "editor-original-cold", "download-drops", "download-drops-gestures", "download-drops-folder"].contains(phase) {
            return try await runUploads(root: root, phase: phase, browser: browser)
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-completion-qualification")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ["create", "reopen", "concurrent", "cleanup", "verify-cleanup", "forget-ui"].contains(phase), "Unadmitted live Connect fixture")
        let secret: SMBPassword
        if phase == "forget-ui" { secret = try SMBPassword("unused-generated-ui-control") }
        else { secret = try await Task.detached { try SMBAuthenticatedVerification.readPrivatePassword() }.value }
        let text = secret.withUTF8Bytes { String(decoding: $0, as: UTF8.self) }
        let state = root.appendingPathComponent("stores/profile"), vault = SMBPasswordVault.generatedQualification(namespace: namespace)
        let storage = try SMBTemporaryStorage(directory: state.appendingPathComponent("smb-browsing")), pool = SMBTemporaryCatalogPool(storage: storage)
        let service = ApplicationSMBConnections(directory: state, passwords: vault)
        let store = SMBSavedServerStore(directory: state.appendingPathComponent("smb-servers"))
        browser.permitsBackgroundVerification = true
        let activity = ApplicationSMBActivity.gate, began = ProcessInfo.processInfo.systemUptime
        var ticks = 0, maximumGap = 0.0, maximumRawGap = 0.0, lastTick = began, lastRawTick = began, owners: [SMBTabController] = []
        var results: [String: Any] = [:], nativeSheetCalls: [String: Double] = [:]
        let heartbeat = Task {
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - lastTick); lastTick = now; ticks += 1
                maximumRawGap = max(maximumRawGap, now - lastRawTick); lastRawTick = now
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { heartbeat.cancel() }
        // AppKit's synchronous sheet show/end methods drive their own native
        // animation. Measure those calls separately from network/storage work;
        // preserve the raw timer gap too, rather than hiding either cost.
        func sheetAction(_ name: String, _ action: () throws -> Void) rethrows {
            let before = ProcessInfo.processInfo.systemUptime
            defer {
                let after = ProcessInfo.processInfo.systemUptime
                nativeSheetCalls[name] = (after - before) * 1000; lastTick = after
            }
            try action()
        }
        func form(port: UInt16 = 15445) async throws -> SMBConnectModel {
            service.present(in: browser, offscreen: true)
            guard let controller = service.verificationWindow else { throw UIVerification.Failure(message: "Actual native Connect form missing") }
            try await wait { !controller.model.managing }
            let model = controller.model
            model.choose(nil); model.address = "smb://127.0.0.1:\(port)/ExplorerQA"; model.account = "nobody"; model.name = "Generated Completion"
            return model
        }
        func connected(_ model: SMBConnectModel) async throws -> SMBTabController {
            model.connect(); try await wait { !model.busy }
            try require(model.connected && !model.rememberingIncomplete, "Actual native Connect failed or remembering incomplete")
            guard let owner = browser.smbTabs[browser.activeID] else { throw UIVerification.Failure(message: "Actual Connect did not hand off a tab") }
            owners.append(owner); return owner
        }
        func close(_ owner: SMBTabController) async throws -> SMBBrowserDrainResult {
            if let tab = browser.smbTabs.first(where: { $0.value === owner })?.key { browser.closeTab(id: tab) } else { owner.close() }
            try await wait { owner.drain != nil }
            let value = owner.drain!
            try require(value.actualExit && value.pipeDrained && value.socketAndCatalogDrained && value.ownerReleased
                && !value.forcedContainment && value.temporaryCatalogRemoved == true, "Actual Connect worker/catalog did not drain cleanly")
            try require(value.peakResidentBytes != nil && value.peakResidentBytes! < 256 << 20, "Actual child memory gate failed")
            guard let counts = owner.session.commandCounts else { throw UIVerification.Failure(message: "Live metadata command proof missing") }
            try require(counts.count == 19 && counts[14] > 0 && [7,8,9,10,11,15,16,17,18].allSatisfy { counts[$0] == 0 }, "Live connection exceeded metadata-only commands")
            return value
        }
        func rootReady(_ owner: SMBTabController) async throws {
            try await wait { owner.session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 5 && !owner.hasPendingPages }
            try require(owner.rows.table.numberOfRows == 5 && owner.session.latest.security == .encrypted, "Generated root count/security differs")
        }
        func large(_ owner: SMBTabController) async throws -> [String: Any] {
            if let tab = browser.smbTabs.first(where: { $0.value === owner })?.key { browser.selectTab(tab) }
            let start = ProcessInfo.processInfo.systemUptime
            let path = try owner.directoryLocation(components: [SMBRemoteName("Large")])
            browser.navigate(to: .smb(path))
            try await wait { (owner.rows.cache.snapshot?.count ?? 0) > 0 && owner.rows.cache.snapshot?.readID != nil
                && owner.rows.table.numberOfRows > 5 && owner.rows.cache.entry(at: 0) != nil }
            let first = ProcessInfo.processInfo.systemUptime - start
            try await wait { owner.session.latest.snapshot?.state == .complete && owner.session.latest.snapshot?.count == 20000 && !owner.hasPendingPages }
            let complete = ProcessInfo.processInfo.systemUptime - start
            try require(owner.rows.table.numberOfRows == 20000 && owner.rows.cache.retainedCount <= 1024, "Large native rows were not paged")
            owner.rows.table.scrollRowToVisible(19999)
            try await wait { owner.rows.cache.entry(at: 19999) != nil && !owner.hasPendingPages }
            try require(owner.rows.cache.entry(at: 19999)?.name.displayName == "Item 19999.txt", "Last actual remote row differs")
            owner.rows.table.sortDescriptors = [NSSortDescriptor(key: SMBDirectorySort.name.rawValue, ascending: false)]
            owner.rows.table.scrollRowToVisible(0)
            try await wait { owner.rows.lastPageDescending == true && owner.rows.cache.entry(at: 0) != nil && !owner.hasPendingPages }
            try require(owner.rows.cache.entry(at: 0)?.name.displayName == "Item 19999.txt" && owner.rows.cache.retainedCount <= 1024, "Descending native page differs")
            return ["entries": 20000, "firstNativePageMilliseconds": first * 1000,
                "sealedMilliseconds": complete * 1000, "retainedNativeRows": owner.rows.cache.retainedCount, "lastAndDescendingRowsVerified": true]
        }
        do {
            switch phase {
            case "forget-ui":
                let preparation = PrivateStateDirectory(directory: state, activity: ApplicationFileActivity.gate)
                try await preparation.prepare()
                let draft = try SMBServerDraft(name: "Generated Forget", address: SMBConnectionAddress("smb://127.0.0.1:15445/ExplorerQA"),
                    account: "generated", domain: "", security: .encrypted)
                let opened = try await store.openForExplicitWrite()
                let saved = try await store.apply(.saveServer(draft, id: nil, credentialID: nil), expectedRevision: opened.snapshot.revision)
                await store.close()
                service.present(in: browser, offscreen: true)
                guard let window = service.verificationWindow else { throw UIVerification.Failure(message: "Generated Forget form missing") }
                try await wait { !window.model.managing && window.model.servers.count == 1 }
                let alertBegan = ProcessInfo.processInfo.systemUptime
                sheetAction("show") { window.model.onForgetServer?(saved.serverID!) }
                results["synchronousAlertPresentationMilliseconds"] = (ProcessInfo.processInfo.systemUptime - alertBegan) * 1000
                try await wait { window.window?.attachedSheet != nil }
                try await Task.sleep(for: .milliseconds(50))
                guard let content = window.window?.attachedSheet?.contentView,
                      let confirm = buttons(content).first(where: { $0.title == "Forget Server" }) else { throw UIVerification.Failure(message: "Generated Forget confirmation missing") }
                let clickBegan = ProcessInfo.processInfo.systemUptime
                try sheetAction("confirm") { try require(confirm.isEnabled && confirm.sendAction(confirm.action, to: confirm.target), "Generated confirmation action refused") }
                results["programmaticConfirmationMilliseconds"] = (ProcessInfo.processInfo.systemUptime - clickBegan) * 1000
                try await wait { !window.model.managing && window.model.servers.isEmpty }
                results["actualForgetWithoutNetwork"] = true; results["keychainEntriesCreated"] = 0; results["maximumConnectionAdmissions"] = 0
            case "create":
                results["stage"] = "wrong-password"
                let failed = try await form(); failed.password = "deliberately-wrong-generated-password"
                failed.rememberServer = true; failed.rememberPassword = true; failed.connect()
                try await wait { !failed.busy }
                let before = try await store.inspect(), failedStores = try await pool.inspect()
                try require(!failed.connected && failed.message.contains("wasn’t accepted") && before == nil && failedStores.isEmpty
                    && browser.smbTabs.isEmpty, "Failed authentication saved a record, exposed a tab or retained a clean runtime")
                failed.password = text
                results["stage"] = "remember-and-root"
                let owner = try await connected(failed); try await rootReady(owner)
                let snapshot = try await store.inspect()
                try require(snapshot?.visibleServers.count == 1 && snapshot?.credentials.count == 1 && snapshot?.credentials.first?.state == .ready,
                    "Actual authenticated remembering differs")
                results["stage"] = "large-directory"
                results["largeDirectory"] = try await large(owner)
                let drained = try await close(owner); results["childPeakRSSBytes"] = drained.peakResidentBytes
                results["failedAuthenticationRememberedNothing"] = true; results["savedProfileRetainedForReopen"] = true
                results["keychainEntriesCreated"] = 1; results["maximumConnectionAdmissions"] = 2
            case "reopen":
                results["stage"] = "saved-reopen"
                let existing = try await store.inspect()
                guard let saved = existing?.visibleServers.first, let reference = existing?.credentials.first?.reference else {
                    throw UIVerification.Failure(message: "Generated persisted server/password reference missing")
                }
                service.present(in: browser, offscreen: true)
                guard let controller = service.verificationWindow else { throw UIVerification.Failure(message: "Reopened native form missing") }
                try await wait { !controller.model.managing && controller.model.servers.count == 1 }
                let model = controller.model; model.choose(saved.id)
                try require(model.password.isEmpty && model.servers[0].hasSavedPassword, "Saved form exposed or lost its password intent")
                let owner = try await connected(model); try await rootReady(owner)
                let reopened = try await store.inspect()
                try require(reopened?.credentials.count == 1 && reopened?.visibleServers.first?.credentialID == reference.id,
                    "Native reconnect detached or replaced its saved password")
                service.present(in: browser, offscreen: true)
                guard let management = service.verificationWindow else { throw UIVerification.Failure(message: "Forget form missing") }
                results["stage"] = "explicit-forget"
                try await wait { !management.model.managing && management.model.servers.count == 1 }
                sheetAction("show") { management.model.onForgetServer?(saved.id) }
                try await wait { management.window?.attachedSheet != nil }
                try await Task.sleep(for: .milliseconds(50))
                guard let sheet = management.window?.attachedSheet, let content = sheet.contentView else { throw UIVerification.Failure(message: "Explicit Forget confirmation missing") }
                let controls = buttons(content)
                guard let also = controls.first(where: { $0.title == "Also remove its saved password from Keychain" }),
                      let confirm = controls.first(where: { $0.title == "Forget Server" }) else { throw UIVerification.Failure(message: "Generated Forget controls differ") }
                also.state = .on
                try sheetAction("confirm") { try require(confirm.isEnabled && confirm.sendAction(confirm.action, to: confirm.target), "Generated confirmation action refused") }
                try await wait { !management.model.managing && management.model.servers.isEmpty }
                let final = try await store.inspect()
                try require(final?.servers.isEmpty == true && final?.credentials.isEmpty == true, "Actual Forget did not finish durable cleanup")
                do { _ = try await vault.password(reference, binding: saved.details.credentialBinding()); throw UIVerification.Failure(message: "Forgotten generated password remains") }
                catch SMBPasswordFailure.missing { }
                try require(owner.session.latest.security == .encrypted && owner.session.latest.snapshot?.state == .complete, "Forget disconnected an open tab")
                let drained = try await close(owner); results["childPeakRSSBytes"] = drained.peakResidentBytes
                results["actualKeychainReopen"] = true; results["actualUIForgetAndMissingRead"] = true
                results["openConnectionSurvivedForget"] = true; results["keychainEntriesCreated"] = 0; results["maximumConnectionAdmissions"] = 1
            case "concurrent":
                results["stage"] = "held-first-connection"
                let firstModel = try await form(); firstModel.password = text
                let first = try await connected(firstModel)
                try await marker(root.appendingPathComponent("evidence/concurrent-held.json"))
                let secondModel = try await form(port: 15447); secondModel.password = text
                results["stage"] = "independent-second-connection"
                let secondBegan = ProcessInfo.processInfo.systemUptime, second = try await connected(secondModel)
                try await rootReady(second)
                results["otherConnectionReadyMilliseconds"] = (ProcessInfo.processInfo.systemUptime - secondBegan) * 1000
                let active = try await pool.inspect()
                try require(active.count == 2 && active.allSatisfy(\.active) && activity.activeCount == 2, "Concurrent connections do not own distinct live catalogs")
                let third = try await form(); third.password = text; third.connect(); try await wait { !third.busy }
                results["stage"] = "capacity-and-close"
                let afterRefusal = try await pool.inspect()
                try require(!third.connected && third.message.contains("connection limit") && afterRefusal == active && browser.smbTabs.count == 2,
                    "Third connection bypassed admission or disturbed live owners")
                third.cancel()
                let firstDrain = try await close(first)
                try require(activity.activeCount == 1 && second.session.latest.snapshot?.state == .complete && second.drain == nil,
                    "Closing the held connection disturbed its peer")
                results["stage"] = "peer-large-directory"
                results["largeDirectory"] = try await large(second)
                let secondDrain = try await close(second)
                results["childPeakRSSBytes"] = [firstDrain.peakResidentBytes!, secondDrain.peakResidentBytes!]
                results["thirdAdmissionRefused"] = true; results["oneCloseLeavesPeerUsable"] = true
                results["keychainEntriesCreated"] = 0; results["maximumConnectionAdmissions"] = 3
            default:
                try require(await removeGeneratedRecords(bundle: Bundle.main.bundleURL, storage: storage, store: store, vault: vault, activity: activity),
                    "Explicit generated credential cleanup incomplete")
                results["generatedPasswordCleanupCompleted"] = true; results["maximumConnectionAdmissions"] = 0; results["keychainEntriesCreated"] = 0
            }
            await service.closeAndDrain(); await store.close(); await vault.drain()
            try require(await SMBBrowserLifetimes.shared.closeAndDrain(), "Native live owners remain uncertain")
            let leftovers = try await pool.inspect()
            results["temporaryStoresAfterDrain"] = leftovers.count
            results["activityAfterDrain"] = activity.activeCount
            results["mainExecutorTicks"] = ticks
            results["maximumMainExecutorGapMilliseconds"] = maximumGap * 1000
            results["rawMaximumMainExecutorGapMilliseconds"] = maximumRawGap * 1000
            results["nativeSheetCallMilliseconds"] = nativeSheetCalls
            try require(leftovers.isEmpty && activity.activeCount == 0, "Live runtime cleanup failed")
            // An empty cleanup can legitimately finish before ten timer ticks.
            // Its actual drain is checked above; live browsing has a meaningful
            // observation interval for the responsiveness threshold.
            if phase == "create" || phase == "reopen" || phase == "concurrent" || phase == "forget-ui" {
                try require(ticks > 0 && maximumGap < 0.25, "Live main-executor responsiveness failed")
                try require(nativeSheetCalls.values.allSatisfy { $0 < 400 }, "Native sheet presentation exceeded its separate measured gate")
            }
            results.merge(["passed": true, "phase": phase, "mainExecutorTicks": ticks, "maximumMainExecutorGapMilliseconds": maximumGap * 1000,
                "activityAfterDrain": activity.activeCount, "temporaryStoresAfterDrain": leftovers.count,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "personalCredentialQueries": 0,
                "generatedKeychainNamespace": namespace.uuidString, "ordinaryConnectEnabled": false], uniquingKeysWith: { _, new in new })
            return results
        } catch {
            for owner in owners { owner.close() }
            let closed = await SMBBrowserLifetimes.shared.closeAndDrain()
            await service.closeAndDrain(); await store.close(); await vault.drain()
            var removed = false
            if closed {
                removed = await removeGeneratedRecords(bundle: Bundle.main.bundleURL, storage: storage, store: store, vault: vault, activity: activity)
            }
            let failure: [String: Any] = ["passed": false, "phase": phase, "workersDrained": closed,
                "generatedPasswordCleanupCompleted": removed, "activityAfterDrain": activity.activeCount,
                "stage": results["stage"] ?? "preparation", "temporaryStoresAfterDrain": results["temporaryStoresAfterDrain"] ?? -1,
                "mainExecutorTicks": ticks, "maximumMainExecutorGapMilliseconds": maximumGap * 1000,
                "rawMaximumMainExecutorGapMilliseconds": maximumRawGap * 1000, "nativeSheetCallMilliseconds": nativeSheetCalls]
            var details = failure
            if let elapsed = results["synchronousAlertPresentationMilliseconds"] { details["synchronousAlertPresentationMilliseconds"] = elapsed }
            if let elapsed = results["programmaticConfirmationMilliseconds"] { details["programmaticConfirmationMilliseconds"] = elapsed }
            if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
                try? await Task.detached { try data.write(to: root.appendingPathComponent("evidence/connect-live-failure-\(phase).json"), options: .withoutOverwriting) }.value
            }
            throw error
        }
    }
    /// One real-App acceptance flow. Only the generated secret's storage is
    /// substituted; connection preparation, authentication, tabs and transfers
    /// use their ordinary production owners and signed worker.
    private static func runUploads(root: URL, phase: String, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && marker?["action"] as? String == "native-smb-connected-uploads"
            && Bundle.main.bundleIdentifier == "local.macexplorer.development", "Generated Upload scope differs")
        let profile = root.appendingPathComponent("state/Profile", isDirectory: true)
        let source = root.appendingPathComponent("source/Local", isDirectory: true)
        let history = SMBUploadStorage(directory: profile.appendingPathComponent("smb-upload-history"))
        let vault = SMBPasswordVault.generatedMemoryQualification()
        let service = ApplicationSMBConnections(directory: profile, passwords: vault, sftpEnabled: false)
        let saved = SavedServerLocations.controller(directory: profile)
        let earlierService = browser.connectionService, earlierSaved = browser.savedServerLocations
        let board = NSPasteboard.withUniqueName()
        let previousBoard = browser.transferPasteboard
        browser.connectionService = service; browser.savedServerLocations = saved
        browser.transferPasteboard = board
        browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
        browser.settings.autoRefreshFolders = false; browser.settings.folderSummariesEnabled = false
        browser.settings.reviewsRecoveryAtStartup = false
        let downloadingOnly = phase.hasPrefix("download-drops")
        let cuttingOnly = phase == "file-actions-cut" || phase == "file-actions-cut-cold"
        let copyingOnly = phase == "file-actions-copy" || phase == "file-actions-copy-cold"
        let editingOnly = phase == "editor-original" || phase == "editor-original-cold"
        let earlierEditorQualification = RemoteTextEditorFeature.qualifyingSMB
        if editingOnly {
            RemoteTextEditorFeature.qualifyingSMB = true
        }
        let earlierCutQualification = RemoteClipboardFeature.qualifying
        SMBUploadFeature.qualifying = true; SMBFolderUploadFeature.qualifying = true
        SMBDownloadFeature.qualifying = downloadingOnly; SMBFolderDownloadFeature.qualifying = downloadingOnly
        SMBRemoteActionFeature.qualifying = phase.hasPrefix("file-actions") || phase.hasPrefix("directory-actions")
        SMBRemoteActionFeature.qualifyingDirectories = phase.hasPrefix("directory-actions") || phase.hasPrefix("file-actions-move") || cuttingOnly
        SMBRemoteActionFeature.qualifyingMoves = phase.hasPrefix("file-actions-move") || cuttingOnly
        SMBRemoteActionFeature.qualifyingCopies = copyingOnly
        if cuttingOnly { RemoteClipboardFeature.qualifying = true }
        defer {
            browser.smbUpload.chooseForVerification = nil; browser.smbUpload.chooseGroupForVerification = nil
            browser.smbUpload.groupReviewForVerification = nil
            browser.operationNamePrompt = nil
            browser.smbFileActions.destinationForVerification = nil
            browser.connectionService = earlierService; browser.savedServerLocations = earlierSaved
            browser.transferPasteboard = previousBoard; board.releaseGlobally()
            SMBUploadFeature.qualifying = false; SMBFolderUploadFeature.qualifying = false
            SMBDownloadFeature.qualifying = false; SMBFolderDownloadFeature.qualifying = false
            SMBRemoteActionFeature.qualifying = false
            SMBRemoteActionFeature.qualifyingDirectories = false
            SMBRemoteActionFeature.qualifyingMoves = false
            SMBRemoteActionFeature.qualifyingCopies = false
            RemoteTextEditorFeature.qualifyingSMB = earlierEditorQualification
            if cuttingOnly { RemoteClipboardFeature.qualifying = earlierCutQualification }
        }
        var stage = "profile", checks: [String] = [], owners: [SMBTabController] = []
        let foldersOnly = phase == "uploads-folders" || phase == "uploads-folders-cold" || phase == "uploads-folders-retained"
        let creatingOnly = phase == "uploads-new-items" || phase == "uploads-new-items-cold"
        let actionsOnly = phase == "file-actions" || phase == "file-actions-cold"
        let directoryActions = phase == "directory-actions" || phase == "directory-actions-cold"
        let movingOnly = phase == "file-actions-move" || phase == "file-actions-move-cold" || cuttingOnly
        var connections = 0, facts: [String: Any] = ["phase": phase, "realKeychainCalls": 0, "generalClipboardUsed": false]
        if phase == "uploads" || phase == "uploads-preflight" || phase == "uploads-folders" || phase == "uploads-new-items" || phase == "file-actions" || phase == "directory-actions" || phase == "file-actions-move" || phase == "file-actions-cut" || phase == "file-actions-copy" || phase == "editor-original" || downloadingOnly {
            let logs = root.appendingPathComponent("state/App Logs", isDirectory: true)
            let layout = try ApplicationStorageLayout(developmentState: logs, legacyAnalysis: logs)
            browser.settings.diagnosticHistoryEnabled = true
            ApplicationDiagnostics.shared.start(settings: browser.settings, layout: layout)
        }
        func captureAppLogs() async {
            guard let recorder = ApplicationDiagnostics.shared.recorder else { return }
            await recorder.flush()
            let outcome = await recorder.export(to: root.appendingPathComponent("evidence/app-logs.json"), retainingAccess: ())
            if case .saved(let records, _, let incomplete) = outcome {
                facts["appLogsRecords"] = records; facts["appLogsIncomplete"] = incomplete
            }
        }
        do {
            guard let window = browser.view.window else { throw UIVerification.Failure(message: "Native upload window missing") }
            if editingOnly { try SMBOriginalEditorVerification.prepare(browser, root: root) }
            window.setContentSize(.init(width: 1100, height: 720)); window.center(); window.makeKeyAndOrderFront(nil)
            window.title = "SMB saved reconnect and uploads · generated review"
            NSApp.activate(ignoringOtherApps: true)
            if phase == "editor-original-cold" {
                facts.merge(try await SMBOriginalEditorVerification.cold(browser, service: service, root: root),
                    uniquingKeysWith: { _, new in new })
                await service.closeAndDrain(); await vault.drain(); _ = await history.close()
                facts["passed"] = true; facts["realKeychainCalls"] = 0; facts["generalClipboardUsed"] = false
                return facts
            }
            if phase == "file-actions-cold" || phase == "directory-actions-cold" || phase == "file-actions-move-cold" || phase == "file-actions-cut-cold" || phase == "file-actions-copy-cold" {
                let actions = SMBActionStorage(directory: profile.appendingPathComponent("smb-file-action-history"))
                let before = try await actions.inspect()
                let previous = copyingOnly ? "file-actions-copy" : cuttingOnly ? "file-actions-cut" : movingOnly ? "file-actions-move" : directoryActions ? "directory-actions" : "file-actions"
                let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/connect-live-\(previous).json"))) as? [String: Any]
                let rows = actionRows(before)
                let warmReferencePassed = expected?["passed"] as? Bool == true
                let warmRowsCompared = warmReferencePassed && expected?["actionRows"] as? [String] == rows
                try require(warmRowsCompared
                    && before.records.count == (movingOnly ? 4 : directoryActions || copyingOnly ? 3 : 2)
                    && before.records.allSatisfy { !$0.active && ($0.outcome == .confirmed || directoryActions && $0.outcome == .notEmpty || movingOnly && ($0.outcome == .collision || $0.outcome == .notStarted) || copyingOnly && $0.outcome == .collision) }, "Cold file-action records differ")
                let layout = try ApplicationStorageLayout(developmentState: profile, legacyAnalysis: profile.appendingPathComponent("unused-analysis-layout"))
                let storage = try await ConnectionWorkspace(layout: layout).prepareForConnect().metadataStorage
                let coordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage,
                    servers: SMBSavedServerStore(directory: profile.appendingPathComponent("smb-servers")), passwords: vault,
                    activity: ApplicationSMBActivity.gate)
                let review = SMBConnectionStorageWindow(settings: browser.settings, coordinator: coordinator, storage: storage, uploads: history, actions: actions)
                review.present(relativeTo: window)
                try await wait { !review.model.busy }
                try require(!review.model.actionRecoveryRequired && review.model.actionHistory.map(actionRows) == rows,
                    "Cold native File Actions missing")
                if let native = review.window, CGPreflightScreenCaptureAccess() {
                    try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/smb-actions-cold.png"))
                }
                await review.closeAndDrain(); await coordinator.drain(); await service.closeAndDrain(); await vault.drain()
                let after = try await actions.inspect()
                try require(before.revision == after.revision && actionRows(after) == rows
                    && vault.generatedMemoryQualificationCounts?.reads == 0 && vault.generatedMemoryQualificationCounts?.saves == 0,
                    "Cold review changed outcomes or accessed a credential")
                try require(await actions.close(), "Cold file-action owner did not close")
                _ = await history.close()
                return ["passed": true, "phase": phase, "actionRows": rows, "networkConnections": 0,
                    "warmReferencePassed": warmReferencePassed, "warmRowsCompared": warmRowsCompared,
                    "realKeychainCalls": 0, "generalClipboardUsed": false,
                    "checks": ["Server-off native Connection Activity retains exact action IDs, names, source/destination parents, dates and outcomes without retrying or authentication"]]
            }
            if phase == "uploads-cold" || phase == "uploads-retained" || phase == "uploads-folders-cold" || phase == "uploads-folders-retained" || phase == "uploads-new-items-cold" {
                let before = try await history.inspect()
                let previous = creatingOnly ? "uploads-new-items" : foldersOnly ? "uploads-folders" : "uploads"
                let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/connect-live-\(previous).json"))) as? [String: Any]
                let rows = before.records.map { $0.id.uuidString + ":" + $0.outcome.rawValue }.sorted()
                if phase == "uploads-folders-retained" {
                    try require(expected?["passed"] as? Bool == false && expected?["stage"] as? String == "folder"
                        && before.records.count == 1 && before.records[0].outcome == .reviewTemporary,
                        "Retained folder-only outcomes differ")
                } else if phase == "uploads-retained" {
                    try require(expected?["passed"] as? Bool == false && expected?["stage"] as? String == "folder"
                        && before.records.count == 4 && before.records.filter { $0.outcome == .verified }.count == 2
                        && before.records.filter { $0.outcome == .finalCollision }.count == 1
                        && before.records.filter { $0.outcome == .reviewTemporary }.count == 1,
                        "Retained failed-folder outcomes differ")
                } else {
                    try require(expected?["passed"] as? Bool == true && expected?["historyRows"] as? [String] == rows
                        && before.records.count == (creatingOnly ? 2 : foldersOnly ? 4 : 6), "Cold outcomes changed")
                }
                try require(before.records.allSatisfy { !$0.active }, "Cold outcomes are still active")
                let layout = try ApplicationStorageLayout(developmentState: profile, legacyAnalysis: profile.appendingPathComponent("unused-analysis-layout"))
                let storage = try await ConnectionWorkspace(layout: layout).prepareForConnect().metadataStorage
                let coordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage,
                    servers: SMBSavedServerStore(directory: profile.appendingPathComponent("smb-servers")), passwords: vault,
                    activity: ApplicationSMBActivity.gate)
                let review = SMBConnectionStorageWindow(settings: browser.settings, coordinator: coordinator, storage: storage, uploads: history)
                review.present(relativeTo: window)
                try await wait { !review.model.busy }
                try require(!review.model.uploadRecoveryRequired && review.model.uploadHistory?.records.count == before.records.count,
                    "Cold native outcomes missing")
                if let native = review.window, CGPreflightScreenCaptureAccess() {
                    try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/smb-upload-cold.png"))
                }
                await review.closeAndDrain(); await coordinator.drain(); await service.closeAndDrain(); await vault.drain()
                let after = try await history.inspect()
                try require(after.revision == before.revision
                    && after.records.map { $0.id.uuidString + ":" + $0.outcome.rawValue }.sorted() == rows,
                    "Review changed retained outcomes")
                try require(vault.generatedMemoryQualificationCounts?.reads == 0
                    && vault.generatedMemoryQualificationCounts?.saves == 0, "Cold review read a credential")
                _ = await history.close()
                return ["passed": true, "phase": phase, "historyRows": rows,
                    "networkConnections": 0, "realKeychainCalls": 0, "generalClipboardUsed": false,
                    "checks": [phase == "uploads-retained" || phase == "uploads-folders-retained"
                        ? "Cold native Connection Storage preserves every failed-run outcome; no authentication or mutation"
                        : "Cold native Connection Storage shows the same verified/collision outcomes with no authentication or mutation"]]
            }
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--generated-port"), args.indices.contains(index + 1),
                  let port = UInt16(args[index + 1]), port > 1024 else { throw UIVerification.Failure(message: "Generated port missing") }
            let secret = try await Task.detached { try SMBAuthenticatedVerification.readPrivatePassword() }.value
            let password = secret.withUTF8Bytes { String(decoding: $0, as: UTF8.self) }
            let inputs = creatingOnly || copyingOnly || editingOnly ? [:] : uploadFixtureBodies()
            try await Task.detached {
                for (name, expected) in inputs {
                    let url = source.appendingPathComponent(name)
                    guard url.resolvingSymlinksInPath() == url, try Data(contentsOf: url) == expected else {
                        throw UIVerification.Failure(message: "Generated source inventory differs")
                    }
                }
            }.value
            if phase == "uploads-preflight" {
                try require(secret.withUTF8Bytes { $0.count == 64 && $0.allSatisfy {
                    (48...57).contains($0) || (97...102).contains($0)
                } }, "Generated secret encoding differs")
                await service.closeAndDrain(); await vault.drain(); _ = await history.close()
                facts = ["passed": true, "phase": phase, "networkConnections": 0,
                    "realKeychainCalls": 0, "generalClipboardUsed": false,
                    "checks": ["Actual private stdin reader accepts the generated UTF-8 password; exact fixture inventory passes before Connect"]]
                await captureAppLogs()
                return facts
            }
            browser.tabs = [.init(location: .computer)]; browser.activeID = browser.tabs[0].id
            browser.loadLocation()
            func openForm() async throws -> SMBTabController {
                browser.showSMBConnections(nil); await service.gateAWaitForSetup()
                guard let form = service.verificationWindow else { throw UIVerification.Failure(message: "Ordinary Connect missing") }
                try await wait { !form.model.managing }
                let model = form.model
                model.choose(nil); model.serverField = "127.0.0.1"; model.portField = String(port)
                model.shareField = "UploadEncryptedQA"; model.account = "nobody"; model.name = "Generated saved server"
                model.transferBehavior = .normal
                model.rememberServer = !foldersOnly && !creatingOnly && !directoryActions && !movingOnly && !copyingOnly && !editingOnly && !downloadingOnly
                model.rememberPassword = model.rememberServer; model.password = password
                connections += 1; try require(connections <= (foldersOnly || creatingOnly || directoryActions || movingOnly || copyingOnly || editingOnly || downloadingOnly ? 1 : 2), "Authentication ceiling")
                model.connect()
                if RemoteTextEditorFeature.smbAvailable {
                    try await wait { form.window?.attachedSheet != nil || !model.busy }
                    if let content = form.window?.attachedSheet?.contentView {
                        let choice = editingOnly ? "Enable Editing" : "Browse Without Editing"
                        guard let button = buttons(content).first(where: { $0.title == choice }) else {
                            throw UIVerification.Failure(message: "Unexpected confirmation during generated SMB Connect")
                        }
                        button.performClick(nil)
                    } else if editingOnly {
                        throw UIVerification.Failure(message: "First SMB Edit setup did not offer explicit consent")
                    }
                }
                try await wait { !model.busy }
                try require(model.connected && !model.rememberingIncomplete, "Real Connect or remembering failed")
                guard let owner = browser.smbTabs[browser.activeID] else { throw UIVerification.Failure(message: "No connected native tab") }
                owners.append(owner)
                try await wait { owner.uploadDestination != nil }
                try require(owner.session.latest.security == .encrypted && owner.session.allowsFolderUploads, "Upload capability/security differs")
                return owner
            }
            func close(_ owner: SMBTabController) async throws {
                let id = browser.smbTabs.first(where: { $0.value === owner })?.key
                let value = await owner.close().value
                facts["workerDrain"] = ["actualExit": value.actualExit,
                    "pipeDrained": value.pipeDrained,
                    "socketAndCatalogDrained": value.socketAndCatalogDrained,
                    "ownerReleased": value.ownerReleased,
                    "forcedContainment": value.forcedContainment]
                try require(value.actualExit && value.pipeDrained && value.socketAndCatalogDrained
                    && value.ownerReleased && !value.forcedContainment, "Upload owner did not drain")
                try await wait { owner.drain != nil }
                if let id, browser.tabs.contains(where: { $0.id == id }) { browser.closeTab(id: id) }
                browser.navigate(to: .computer)
            }
            func ready(_ owner: SMBTabController, in components: [SMBRemoteName] = []) async throws {
                try await wait { owner.session.latest.failure != nil || browser.operationTask == nil && browser.operationPreparationTask == nil && owner.uploadDestination != nil }
                try require(browser.smbTabs[browser.activeID] === owner && owner.uploadDestination?.components == components
                    && !owner.isClosing && owner.session.latest.security == .encrypted,
                    "Generated destination changed or connection ended: " + (owner.session.latest.failure?.rawValue ?? "none"))
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(owner.rows.table)
            }
            func paste(_ names: [String], into owner: SMBTabController) async throws {
                try await ready(owner)
                let urls = names.map { source.appendingPathComponent($0, isDirectory: $0 == "Generated Folder" || $0 == "Mixed Folder") }
                try require(board.name != .general && browser.transferPasteboard === board, "Private clipboard ownership lost")
                board.clearContents(); try require(board.writeObjects(urls as [NSURL]), "Generated clipboard publication failed")
                let decoded = browser.clipboardState.readFiles(allowOwnedCopy: false)
                try require(decoded?.urls == urls && decoded?.isCurrent(on: board) == true, "Generated clipboard source differs")
                try require(browser.smbUpload.pasteClipboard(to: owner), "Native Paste adapter refused")
                try await wait(seconds: 90) { browser.operationTask == nil && browser.operationPreparationTask == nil }
                try require(!owner.isClosing && owner.session.latest.failure == nil,
                    "Upload connection ended: " + browser.smbUpload.lastNotice)
            }
            func selectActionItem(_ name: String, on owner: SMBTabController) async throws {
                try await ready(owner)
                try await wait { owner.rows.cache.loadedEntries.contains { $0.row.name.displayName == name } }
                guard let row = (0..<owner.rows.table.numberOfRows).first(where: {
                    owner.rows.cache.entry(at: Int64($0))?.name.displayName == name
                }) else { throw UIVerification.Failure(message: "Generated action row missing") }
                owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                owner.rows.table.scrollRowToVisible(row); owner.rows.table.layoutSubtreeIfNeeded()
                try require(browser.smbFileActions.canRequest(from: owner), "Selected native item lacks verified action capability")
            }
            func renameEditor() async throws -> (NSTextField, NSTextView) {
                browser.renameSelection(nil)
                try await wait { browser.inlineRename.field?.currentEditor() is NSTextView }
                guard let field = browser.inlineRename.field, let editor = field.currentEditor() as? NSTextView else {
                    throw UIVerification.Failure(message: "Ordinary inline Rename missing")
                }
                return (field, editor)
            }
            func answerDelete(_ title: String, on owner: SMBTabController) async throws {
                browser.smbFileActions.request(.delete, from: owner)
                try await wait { window.attachedSheet != nil }
                guard let content = window.attachedSheet?.contentView,
                      let button = buttons(content).first(where: { $0.title == title }) else {
                    throw UIVerification.Failure(message: "Native Delete confirmation missing")
                }
                if title == "Delete Permanently", CGPreflightScreenCaptureAccess() {
                    let label = directoryActions ? "smb-directory-delete-confirm" : "smb-action-delete-confirm"
                    let output = root.appendingPathComponent("evidence/\(label).png")
                    if !FileManager.default.fileExists(atPath: output.path) {
                        try await GlassVerification.captureOwnedWindow(window.attachedSheet!, to: output)
                    }
                }
                button.performClick(nil); try await ready(owner)
            }
            func finishActions(_ owner: SMBTabController, checks completed: [String], verifyDrain: (() throws -> Void)? = nil) async throws -> [String: Any] {
                try await close(owner); await service.closeAndDrain(); await vault.drain()
                try verifyDrain?()
                let cold = SMBActionStorage(directory: profile.appendingPathComponent("smb-file-action-history"))
                facts["actionRows"] = actionRows(try await cold.inspect())
                try require(await cold.close(), "File-action history reader did not close")
                try require(vault.generatedMemoryQualificationCounts?.reads == 0 && vault.generatedMemoryQualificationCounts?.saves == 0,
                    "File actions used a saved credential")
                _ = await history.close()
                facts["passed"] = true; facts["stage"] = "finished"; facts["authenticationReservations"] = connections
                facts["workersDrained"] = true; facts["commandCounts"] = owner.session.commandCounts
                facts["checks"] = completed
                await captureAppLogs(); return facts
            }
            stage = creatingOnly ? "connect-new-items" : foldersOnly ? "connect-folders" : "remember"
            let first = try await openForm()
            if editingOnly {
                stage = "editor-original"
                facts.merge(try await SMBOriginalEditorVerification.warm(browser, owner: first, root: root),
                    uniquingKeysWith: { _, new in new })
                try await close(first); await service.closeAndDrain(); await vault.drain(); _ = await history.close()
                try require(vault.generatedMemoryQualificationCounts?.reads == 0
                    && vault.generatedMemoryQualificationCounts?.saves == 0, "SMB editor used a saved credential")
                facts["passed"] = true; facts["stage"] = "finished"; facts["authenticationReservations"] = connections
                facts["workersDrained"] = true; facts["commandCounts"] = first.session.commandCounts
                await captureAppLogs(); return facts
            }
            if downloadingOnly {
                stage = "seed-download-inputs"
                try await paste(["Final.bin", "Verified.bin", "Generated Folder"], into: first)
                guard let uploadOwner = first.uploads else { throw UIVerification.Failure(message: "Connected Upload history owner missing") }
                let seeded = try await uploadOwner.inspect()
                try require(seeded.records.count == 3 && seeded.records.allSatisfy { !$0.active && $0.outcome == .verified },
                    "Download input Upload did not verify")
                stage = "native-download-drops"
                checks = try await verifyDownloadDrops(root: root, browser: browser, owner: first,
                    includeSingle: phase == "download-drops", includeGroup: phase != "download-drops-folder")
                try await close(first)
                facts["commandCounts"] = first.session.commandCounts
                await saved.work?.value; await service.closeAndDrain(); await vault.drain()
                _ = await history.close()
                facts["passed"] = true; facts["stage"] = "finished"; facts["checks"] = checks
                facts["authenticationReservations"] = connections; facts["workersDrained"] = true
                facts["generatedCredentialReads"] = vault.generatedMemoryQualificationCounts?.reads ?? -1
                facts["generatedCredentialSaves"] = vault.generatedMemoryQualificationCounts?.saves ?? -1
                facts["downloadDestination"] = "source/Download Destination"
                await captureAppLogs()
                return facts
            }
            if copyingOnly {
                let owner = first
                guard let actions = owner.remoteActions else { throw UIVerification.Failure(message: "Shared Copy action owner missing") }
                func browse(_ names: [String]) async throws {
                    let path = try names.map { try SMBRemoteName($0) }
                    browser.navigate(to: .smb(try owner.directoryLocation(components: path)))
                    try await ready(owner, in: path)
                }
                stage = "create-copy-destination"
                browser.operationNamePrompt = { _, _ in "Copy Destination" }
                browser.createFolder(nil); try await ready(owner); browser.operationNamePrompt = nil
                try await browse(["Copy Destination"])
                browser.operationNamePrompt = { _, _ in "Occupied.bin" }
                browser.createTextFile(nil)
                try await ready(owner, in: [SMBRemoteName("Copy Destination")]); browser.operationNamePrompt = nil
                try await browse([])
                try await selectActionItem("Existing.bin", on: owner)
                guard let sourceBefore = owner.rows.selectedObservation else { throw UIVerification.Failure(message: "Copy source missing") }
                func copy(to name: String, cancel: Bool = false) async throws {
                    try await selectActionItem("Existing.bin", on: owner)
                    var formFailure: String?
                    browser.smbFileActions.destinationForVerification = { model in
                        guard model.operation == .copy && !model.canMove else {
                            formFailure = "Copy did not start with a distinct destination requirement"; return nil
                        }
                        model.path = "/Copy Destination"; model.destinationName = name
                        guard model.canMove else { formFailure = "Valid Copy destination was refused"; return nil }
                        let review = RemoteMoveDestination(model: model, settings: browser.settings)
                        let pressing = Task {
                            do {
                                try await wait { window.attachedSheet === review.window && review.window?.isVisible == true }
                                try await Task.sleep(for: .milliseconds(180))
                                try require(SFTPFolderUploadPreviewVerification.pressMove(in: review, cancel: cancel), "Copy sheet action unavailable")
                            } catch {
                                formFailure = (error as? UIVerification.Failure)?.message ?? "Copy sheet did not finish"
                                review.finish(nil)
                            }
                        }
                        let answer = await review.choose(in: window); await pressing.value
                        return answer
                    }
                    defer { browser.smbFileActions.destinationForVerification = nil }
                    try require(browser.commandEnabled(#selector(BrowserViewController.copyServerSelection(_:))), "Copy command missing")
                    browser.copyServerSelection(nil); try await ready(owner)
                    try require(formFailure == nil, formFailure ?? "Copy form failed")
                }
                stage = "copy-cancel"; try await copy(to: "Copied.bin", cancel: true)
                try require(try await actions.inspect().records.isEmpty, "Cancelled Copy submitted an action")
                stage = "copy-collision"; try await copy(to: "Occupied.bin")
                let collision = try await actions.inspect()
                try require(collision.records.count == 1 && collision.records[0].operation == .copy
                    && collision.records[0].outcome == .collision && !collision.records[0].active,
                    "Early Copy collision was not a definite unchanged outcome")
                stage = "copy-file"; try await copy(to: "Copied.bin")
                let copied = try await actions.inspect()
                try require(copied.records.count == 2 && copied.records[1].operation == .copy
                    && copied.records[1].outcome == .confirmed && !copied.records[1].active, "Copy was not confirmed")
                stage = "duplicate-file"; try await selectActionItem("Existing.bin", on: owner)
                guard let menu = owner.rows.table.contextMenuProvider?(),
                      let index = menu.items.firstIndex(where: { $0.title == "Duplicate" }) else {
                    throw UIVerification.Failure(message: "Native server Duplicate menu missing")
                }
                menu.performActionForItem(at: index); try await ready(owner)
                let final = try await actions.inspect()
                try require(final.records.count == 3 && final.records[2].operation == .copy
                    && final.records[2].outcome == .confirmed && final.records.allSatisfy { !$0.active }, "Duplicate was not confirmed")
                try require(Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName })
                    == Set(["Existing.bin", "Existing copy.bin", "Copy Destination"]), "Copy source namespace differs")
                try await selectActionItem("Existing.bin", on: owner)
                guard let sourceAfter = owner.rows.selectedObservation else { throw UIVerification.Failure(message: "Original disappeared") }
                try require(sourceAfter.objectID == sourceBefore.objectID && sourceAfter.parentID == sourceBefore.parentID
                    && sourceAfter.logicalBytes == sourceBefore.logicalBytes && sourceAfter.attributes == sourceBefore.attributes
                    && sourceAfter.modifiedFileTime == sourceBefore.modifiedFileTime, "Copy changed observed original metadata")
                try await browse(["Copy Destination"])
                try require(Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName }) == Set(["Copied.bin", "Occupied.bin"]),
                    "Copy destination namespace differs")
                return try await finishActions(owner, checks: [
                    "Native Copy To Cancel submits no action; an occupied final name refuses before stage creation and keeps the connection usable",
                    "Copy To and one-click Duplicate use the same authenticated share, preserve the original and refresh visible rows",
                    "Exact confirmed/collision records survive normal worker/service drain; server inventory is checked independently afterward"], verifyDrain: {
                        guard let counts = owner.session.commandCounts else { throw UIVerification.Failure(message: "Copy command proof missing") }
                        // New File verifies EOF at both the private stage and
                        // the published name. Both body loops are empty.
                        // Copied data is never relayed through this client.
                        try require(counts.count == 19 && counts[8] == 2 && counts[9] == 0 && counts[11] == 4,
                            "Copy exceeded the expected server-side command path")
                    })
            }
            if movingOnly {
                let owner = first
                guard let actions = owner.remoteActions else { throw UIVerification.Failure(message: "Shared Move action owner missing") }
                func browse(_ names: [String]) async throws {
                    let path = try names.map { try SMBRemoteName($0) }
                    browser.navigate(to: .smb(try owner.directoryLocation(components: path)))
                    try await ready(owner, in: path)
                }
                func create(_ name: String, folder: Bool, in path: [String] = []) async throws {
                    try await browse(path)
                    browser.operationNamePrompt = { _, _ in name }
                    defer { browser.operationNamePrompt = nil }
                    if folder { browser.createFolder(nil) } else { browser.createTextFile(nil) }
                    try await ready(owner, in: try path.map { try SMBRemoteName($0) })
                    try require(owner.rows.cache.loadedEntries.contains { $0.row.name.displayName == name }, "Move destination input was not created")
                }
                func move(_ name: String, to destination: String, cancel: Bool = false) async throws {
                    try await selectActionItem(name, on: owner)
                    var formFailure: String?
                    browser.smbFileActions.destinationForVerification = { model in
                        guard !model.canMove else { formFailure = "Same-folder Move was enabled"; return nil }
                        if model.isFolder {
                            model.path = "/Generated Folder/Nested"
                            guard !model.canMove else { formFailure = "Descendant Move was enabled"; return nil }
                        }
                        model.path = destination
                        guard model.canMove else { formFailure = "Valid destination refused"; return nil }
                        let review = RemoteMoveDestination(model: model, settings: browser.settings)
                        let pressing = Task {
                            do {
                                try await wait { window.attachedSheet === review.window && review.window?.isVisible == true }
                                try await Task.sleep(for: .milliseconds(180))
                                try require(SFTPFolderUploadPreviewVerification.pressMove(in: review, cancel: cancel), "Move sheet button unavailable")
                            } catch {
                                formFailure = (error as? UIVerification.Failure)?.message ?? "Move sheet did not finish"
                                review.finish(nil)
                            }
                        }
                        let answer = await review.choose(in: window)
                        await pressing.value
                        return answer
                    }
                    defer { browser.smbFileActions.destinationForVerification = nil }
                    try require(browser.commandEnabled(#selector(BrowserViewController.moveServerSelection(_:))), "Ordinary Move command missing")
                    let command = NSMenuItem(title: BrowserCommand.moveOnServer.title,
                        action: BrowserCommand.moveOnServer.selector, keyEquivalent: "")
                    command.target = browser
                    try require(NSApp.sendAction(command.action!, to: browser, from: command), "Move command did not dispatch")
                    try await ready(owner)
                    try require(formFailure == nil, formFailure ?? "Move form failed")
                }
                func cutMove(_ name: String, to destination: [String], expectedNames: Set<String>,
                             collision: Bool = false, reusingCut: Bool = false) async throws {
                    try await selectActionItem(name, on: owner)
                    guard case .smb(let sourceLocation) = browser.location,
                          let sourceComponents = owner.navigationComponents(sourceLocation) else {
                        throw UIVerification.Failure(message: "Cut source directory was not admitted")
                    }
                    let connection = owner.connectionID, session = owner.session, tab = browser.activeID
                    try require(board.name != .general && browser.transferPasteboard === board,
                        "Remote Cut lost its private pasteboard")
                    if !reusingCut {
                        guard let menu = owner.rows.table.contextMenuProvider?(),
                              let index = menu.items.firstIndex(where: { $0.title == "Cut" }) else {
                            throw UIVerification.Failure(message: "Ordinary remote Cut menu missing")
                        }
                        try require(browser.canCutRemoteSelection
                            && browser.commandEnabled(#selector(BrowserViewController.cutFileURLs(_:))), "Remote Cut command unavailable")
                        menu.performActionForItem(at: index)
                    }
                    guard let intent = browser.clipboardState.scopedItem,
                          case .smb(let captured) = intent.source else {
                        throw UIVerification.Failure(message: "Remote Cut intent was not retained")
                    }
                    try require(intent.smbOwner === owner && captured.connectionID == connection
                        && captured.directory == sourceComponents && captured.row.name.displayName == name
                        && browser.pendingCut == nil && !browser.canPasteScopedItem,
                        "Remote Cut changed its source or enabled a same-folder Paste")
                    try require(board.types == [ScopedItemClipboardIntent.pasteboardType]
                        && board.string(forType: .string) == nil && board.availableType(from: [.fileURL]) == nil,
                        "Remote Cut exposed local file URLs or text")
                    let generation = board.changeCount
                    try await browse(destination)
                    let destinationComponents = try destination.map { try SMBRemoteName($0) }
                    try require(browser.activeID == tab && owner.connectionID == connection && owner.session === session
                        && browser.clipboardState.scopedItem === intent && board.changeCount == generation
                        && browser.canPasteScopedItem && owner.rows.pasteAllowed?() == true
                        && browser.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))),
                        "Remote Cut did not survive same-session destination navigation")
                    // Use the ordinary native table route, not the Move To
                    // verifier or a directly constructed remote-action request.
                    owner.rows.table.paste(nil)
                    try await ready(owner, in: destinationComponents)
                    try await wait {
                        owner.session.latest.failure != nil
                            || Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName }) == expectedNames
                    }
                    try require(owner.session === session && owner.connectionID == connection && connections == 1
                        && owner.session.latest.failure == nil && !owner.isClosing
                        && owner.clipboardDestination?.components == destinationComponents
                        && browser.smbFileActions.lastOutcome == (collision ? .collision : .confirmed),
                        "Cut/Paste did not finish on the same healthy connection and visible destination")
                    try require(collision ? browser.clipboardState.scopedItem === intent : browser.clipboardState.scopedItem == nil,
                        "Cut was not retained for a definite collision or consumed after success")
                    try require(browser.transferPasteboard === board && board.name != .general
                        && board.availableType(from: [.fileURL]) == nil && board.string(forType: .string) == nil,
                        "Remote Paste exposed a local-file clipboard representation")
                    browser.navigate(to: .smb(sourceLocation))
                    try await ready(owner, in: sourceComponents)
                    try await wait {
                        guard let snapshot = owner.rows.cache.snapshot, snapshot.state == .complete,
                              Int64(owner.rows.cache.retainedCount) == snapshot.count, !owner.hasPendingPages else { return false }
                        let present = owner.rows.cache.loadedEntries.contains { $0.row.name.displayName == name }
                        return present == collision
                    }
                    try require(browser.activeID == tab && owner.session === session
                        && owner.connectionID == connection && owner.session.latest.failure == nil,
                        "Returning to the original source replaced the authenticated owner")
                }
                stage = "move-inputs"
                try await paste(["Final.bin", "Generated Folder"], into: owner)
                try require(browser.smbUpload.lastGroupCompleted?.completedRoots == 2, "Move source group did not upload")
                for name in ["Destination", "Occupied"] { try await create(name, folder: true) }
                try await create("Final.bin", folder: false, in: ["Occupied"])
                try await browse([])
                stage = "move-cancel"
                try await move("Final.bin", to: "/Destination", cancel: true)
                try require(try await actions.inspect().records.isEmpty, "Cancelled Move submitted an action")
                if cuttingOnly {
                    stage = "cut-folder-move-cancel"
                    try await move("Generated Folder", to: "/Destination", cancel: true)
                    try require(try await actions.inspect().records.isEmpty,
                        "Folder same-parent/descendant validation or Cancel submitted an action")
                }
                stage = "move-missing-destination"
                if cuttingOnly { try require(browser.clipboardState.scopedItem == nil, "Unavailable destination must use Move To, not Cut/Paste") }
                try await move("Final.bin", to: "/Missing Destination")
                let missing = try await actions.inspect()
                try require(missing.records.count == 1 && missing.records[0].outcome == .notStarted
                    && !missing.records[0].active && !owner.isClosing && owner.session.latest.failure == nil
                    && owner.uploadNotice?.contains("Choose another folder") == true, "Missing destination did not preserve a usable connection")
                stage = "move-collision"
                if cuttingOnly { try await cutMove("Final.bin", to: ["Occupied"], expectedNames: ["Final.bin"], collision: true) }
                else { try await move("Final.bin", to: "/Occupied") }
                let collision = try await actions.inspect()
                try require(collision.records.count == 2 && collision.records[1].outcome == .collision
                    && !collision.records[1].active && collision.records[1].operation == .move
                    && owner.session.latest.failure == nil, "Move collision did not preserve a usable connection")
                stage = "move-file"
                if cuttingOnly { try await cutMove("Final.bin", to: ["Destination"], expectedNames: ["Final.bin"], reusingCut: true) }
                else { try await move("Final.bin", to: "/Destination") }
                let fileMoved = try await actions.inspect()
                try require(fileMoved.records.count == 3 && fileMoved.records[2].outcome == .confirmed
                    && fileMoved.records[2].operation == .move, "File Move was not confirmed")
                let oldFolder = try owner.directoryLocation(components: [SMBRemoteName("Generated Folder"), SMBRemoteName("Nested")])
                stage = "move-folder"
                if cuttingOnly { try await cutMove("Generated Folder", to: ["Destination"], expectedNames: ["Final.bin", "Generated Folder"]) }
                else { try await move("Generated Folder", to: "/Destination") }
                let final = try await actions.inspect()
                try require(final.records.count == 4 && final.records[3].operation == .moveDirectory
                    && final.records[3].outcome == .confirmed && final.records.allSatisfy { !$0.active }, "Folder Move was not confirmed")
                try require(owner.navigationComponents(oldFolder) == nil, "Moved folder retained its old descendant reference")
                try require(Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName }) == Set(["Existing.bin", "Destination", "Occupied"]), "Move source namespace differs")
                try await browse(["Destination"])
                try require(Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName }) == Set(["Final.bin", "Generated Folder"]), "Move destination namespace differs")
                var moveChecks = [cuttingOnly
                    ? "One authenticated session runs native Cut, destination navigation and Paste on a private token-only board; Move To Cancel/same-parent/descendant validation sends nothing"
                    : "One authenticated session runs ordinary Move To with native Cancel/Move buttons; same-folder and descendant validation sends nothing",
                    "A missing destination records Not started and keeps the same connection available for the next Move",
                    cuttingOnly ? "Occupied-name refusal preserves the connection and both existing objects without replacement or automatic retry"
                        : "Occupied-name refusal preserves the connection and both existing objects without replacement or retry",
                    "A file and a nonempty folder move through the same server-side namespace operation; old descendant references expire",
                    "Both parent paths and exact confirmed/collision outcomes survive service drain"]
                if cuttingOnly {
                    facts["remoteCutPaste"] = true
                    moveChecks += [
                        "Definite collision retains the exact Cut for a successful Paste into another folder; confirmed file/folder outcomes consume only that Cut",
                        "Every remote Cut Paste refreshes the visible destination and returns to the captured source on the same authenticated owner without local URLs or another sign-in"]
                }
                return try await finishActions(owner, checks: moveChecks)
            }
            if directoryActions {
                let owner = first
                guard let actions = owner.remoteActions else { throw UIVerification.Failure(message: "Shared directory-action owner missing") }
                stage = "create-directory-inputs"
                browser.operationNamePrompt = { _, _ in "CreatedFolder" }
                browser.createFolder(nil); try await ready(owner); browser.operationNamePrompt = nil
                try await paste(["Generated Folder"], into: owner)
                stage = "directory-rename-cancel"
                try await selectActionItem("Generated Folder", on: owner)
                let (cancelField, cancelEditor) = try await renameEditor()
                _ = browser.inlineRename.control(cancelField, textView: cancelEditor, doCommandBy: NSSelectorFromString("cancelOperation:"))
                try await ready(owner)
                try require(try await actions.inspect().records.isEmpty, "Cancelled directory Rename submitted an action")
                stage = "directory-rename-validation"
                try await selectActionItem("Generated Folder", on: owner)
                let (field, editor) = try await renameEditor()
                for invalid in ["CreatedFolder", "generated folder"] {
                    editor.string = invalid
                    _ = browser.inlineRename.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:"))
                    let unchanged = try await actions.inspect()
                    try require(browser.inlineRename.field === field && field.toolTip != nil
                        && unchanged.records.isEmpty, "Invalid directory Rename escaped validation")
                }
                stage = "directory-rename"; editor.string = "RenamedFolder"
                _ = browser.inlineRename.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:"))
                try await ready(owner)
                let renamed = try await actions.inspect()
                try require(renamed.records.count == 1 && renamed.records[0].operation == .renameDirectory
                    && renamed.records[0].outcome == .confirmed && !renamed.records[0].active, "Directory Rename was not confirmed")
                stage = "nonempty-delete"
                try await selectActionItem("RenamedFolder", on: owner)
                try await answerDelete("Delete Permanently", on: owner)
                let refused = try await actions.inspect()
                try require(refused.records.count == 2 && refused.records[1].operation == .deleteEmptyDirectory
                    && refused.records[1].outcome == .notEmpty && !refused.records[1].active
                    && owner.uploadNotice?.contains("No items were deleted") == true, "Nonempty Delete was not refused truthfully")
                try await selectActionItem("CreatedFolder", on: owner)
                stage = "empty-delete-cancel"; try await answerDelete("Cancel", on: owner)
                try require(try await actions.inspect().records.count == 2, "Cancelled directory Delete submitted an action")
                stage = "empty-delete"; try await answerDelete("Delete Permanently", on: owner)
                let final = try await actions.inspect()
                try require(final.records.count == 3 && final.records[2].operation == .deleteEmptyDirectory
                    && final.records[2].outcome == .confirmed && final.records.allSatisfy { !$0.active }, "Empty Delete was not confirmed")
                try require(Set(owner.rows.cache.loadedEntries.map { $0.row.name.displayName }) == Set(["Existing.bin", "RenamedFolder"]), "Final directory namespace differs")
                try await close(owner); await service.closeAndDrain(); await vault.drain()
                let cold = SMBActionStorage(directory: profile.appendingPathComponent("smb-file-action-history"))
                facts["actionRows"] = actionRows(try await cold.inspect())
                try require(await cold.close(), "Directory-action history reader did not close")
                try require(vault.generatedMemoryQualificationCounts?.reads == 0 && vault.generatedMemoryQualificationCounts?.saves == 0,
                    "Directory flow used a saved credential")
                _ = await history.close()
                facts["passed"] = true; facts["stage"] = "finished"; facts["authenticationReservations"] = connections
                facts["workersDrained"] = true
                facts["checks"] = ["Ordinary folder Rename shares native inline validation/Cancel and preserves the directory object",
                    "Server-refused nonempty Delete retains its explicit unchanged outcome; no recursive removal",
                    "Ordinary empty-folder Delete Cancel and confirmation share existing history and actual session drain"]
                await captureAppLogs(); return facts
            }
            if actionsOnly {
                stage = "status-direct-reconnect"
                saved.refresh(); await saved.work?.value
                let keptTab = browser.activeID
                browser.disconnectSMBConnection(nil)
                try await wait { first.drain != nil && browser.smbTabs[keptTab] == nil }
                try require(first.drain?.actualExit == true && first.drain?.socketAndCatalogDrained == true
                    && browser.tabs[browser.activeIndex].connectionBookmark != nil, "Normal Disconnect did not preserve a reconnect target")
                browser.updateConnectionStatusIndicator()
                try require(browser.connectionIndicator.phaseForVerification == .disconnected, "Closed connection did not show red status")
                connections += 1; try require(connections <= 2, "Reconnect authentication ceiling")
                browser.connectionIndicator.performClick(nil)
                try await wait { browser.smbTabs[keptTab] != nil && saved.connectionProgress.isEmpty }
                guard let owner = browser.smbTabs[keptTab] else { throw UIVerification.Failure(message: "Status reconnect did not attach") }
                owners.append(owner); try await ready(owner)
                try require(browser.activeID == keptTab && service.verificationWindow?.window?.isVisible != true,
                    "Status reconnect changed tab or forced a Connect form")
                checks.append("Red connection status reconnects in the existing tab using only the generated in-memory saved password; no Connect form")
                guard let actions = owner.remoteActions else { throw UIVerification.Failure(message: "Shared file-action owner missing") }
                stage = "create-action-input"; try await paste(["Final.bin"], into: owner)
                stage = "rename-cancel"; try await selectActionItem("Final.bin", on: owner)
                let (cancelField, cancelEditor) = try await renameEditor()
                _ = browser.inlineRename.control(cancelField, textView: cancelEditor, doCommandBy: NSSelectorFromString("cancelOperation:"))
                try await ready(owner)
                try require(try await actions.inspect().records.isEmpty, "Cancelled Rename submitted an action")
                stage = "rename-validation"; try await selectActionItem("Final.bin", on: owner)
                let (field, editor) = try await renameEditor()
                for invalid in ["Existing.bin", "final.bin"] {
                    editor.string = invalid
                    _ = browser.inlineRename.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:"))
                    let unchanged = try await actions.inspect()
                    try require(browser.inlineRename.field === field && field.toolTip != nil
                        && unchanged.records.isEmpty, "Invalid Rename escaped native validation")
                }
                if CGPreflightScreenCaptureAccess() {
                    try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/smb-action-inline-rename.png"))
                }
                stage = "rename"; editor.string = "Conflict.bin"
                _ = browser.inlineRename.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:"))
                try await ready(owner)
                let renamed = try await actions.inspect()
                try require(renamed.records.count == 1 && renamed.records[0].outcome == .confirmed
                    && renamed.records[0].operation == .rename && !renamed.records[0].active,
                    "Rename was not confirmed in the shared history")
                try await selectActionItem("Conflict.bin", on: owner)
                for title in ["Cancel", "Delete Permanently"] {
                    stage = title == "Cancel" ? "delete-cancel" : "delete"
                    try await answerDelete(title, on: owner)
                    let current = try await actions.inspect()
                    try require(current.records.count == (title == "Cancel" ? 1 : 2)
                        && current.records.allSatisfy { !$0.active && $0.outcome == .confirmed }, "Delete outcome differs")
                }
                checks.append("One encrypted connection uses real inline Rename; Escape, occupied name and case-only change send no action")
                checks.append("Same-handle Rename and explicit permanent Delete confirm through ordinary commands; Delete Cancel submits nothing")
                try require(owner.rows.cache.loadedEntries.map { $0.row.name.displayName } == ["Existing.bin"], "Final native namespace differs")
                try await close(owner); await service.closeAndDrain(); await vault.drain()
                let cold = SMBActionStorage(directory: profile.appendingPathComponent("smb-file-action-history"))
                facts["actionRows"] = actionRows(try await cold.inspect())
                try require(await cold.close(), "Action-history reader did not close")
                try require(vault.generatedMemoryQualificationCounts?.reads == 1 && vault.generatedMemoryQualificationCounts?.saves == 1,
                    "Status reconnect did not reuse its exact generated in-memory credential")
                _ = await history.close()
                facts["passed"] = true; facts["stage"] = "finished"; facts["checks"] = checks
                facts["authenticationReservations"] = connections; facts["workersDrained"] = true
                await captureAppLogs(); return facts
            }
            if creatingOnly {
                let owner = first
                stage = "new-item-cancel"
                try await ready(owner)
                try require(browser.smbNewItems.canRequest(.textFile, from: owner)
                    && browser.smbNewItems.canRequest(.folder, from: owner), "Empty-item capabilities missing")
                browser.operationNamePrompt = { _, _ in nil }
                try require(browser.commandEnabled(#selector(BrowserViewController.createFolder(_:)))
                    && browser.commandEnabled(#selector(BrowserViewController.createTextFile(_:))), "Native New Item routes unavailable")
                browser.createFolder(nil)
                try await ready(owner)
                try require(try await history.inspect().records.isEmpty, "Cancelled creation wrote an outcome")
                stage = "new-item-observed-collision"
                browser.operationNamePrompt = { _, _ in "Existing.bin" }
                browser.createTextFile(nil)
                try await ready(owner)
                try require(try await history.inspect().records.isEmpty && owner.uploadNotice?.contains("Nothing was created") == true,
                    "Known collision was sent or not explained")
                guard let activeHistory = owner.uploads else { throw UIVerification.Failure(message: "Connection upload history missing") }
                for (name, folder) in [("Created.txt", false), ("CreatedFolder", true)] {
                    stage = folder ? "create-empty-folder" : "create-empty-file"
                    browser.operationNamePrompt = { _, _ in name }
                    if folder { browser.createFolder(nil) } else { browser.createTextFile(nil) }
                    try await ready(owner)
                    // The live connection holds the writer lease. Inspect its
                    // owner, then use the independent reader after actual drain.
                    let created = try await activeHistory.inspect()
                    try require(created.records.contains { $0.remoteName.displayName == name && $0.outcome == .verified
                        && !$0.active && $0.logicalBytes == 0 && ($0.folder != nil) == folder }, "Empty item was not verified by the existing upload owner")
                }
                browser.operationNamePrompt = nil
                try await close(owner); await service.closeAndDrain(); await vault.drain()
                let final = try await history.inspect()
                try require(final.records.count == 2 && final.records.allSatisfy { !$0.active && $0.outcome == .verified },
                    "Created-item outcomes differ")
                let noPrivateSource = await Task.detached {
                    !FileManager.default.fileExists(atPath: profile.appendingPathComponent("smb-generated-items").path)
                }.value
                try require(noPrivateSource && vault.generatedMemoryQualificationCounts?.reads == 0
                    && vault.generatedMemoryQualificationCounts?.saves == 0, "A private source or saved credential was created")
                facts["historyRows"] = final.records.map { $0.id.uuidString + ":" + $0.outcome.rawValue }.sorted()
                _ = await history.close()
                facts["passed"] = true; facts["stage"] = "finished"; facts["authenticationReservations"] = connections
                facts["workersDrained"] = true; facts["generatedCredentialReads"] = vault.generatedMemoryQualificationCounts?.reads ?? -1
                facts["generatedCredentialSaves"] = vault.generatedMemoryQualificationCounts?.saves ?? -1
                facts["checks"] = ["Ordinary File New Item routes share one encrypted connection and the existing upload owners",
                    "Cancel and an observed-name collision create no source or upload outcome",
                    "Empty text file and empty folder publish with verified zero-byte outcomes; no replacement or automatic editor/Download",
                    "Disconnect drains normally; no real or generated saved credential is used"]
                await captureAppLogs()
                return facts
            }
            let owner: SMBTabController
            if foldersOnly {
                owner = first
                checks.append("One explicit encrypted Connect admits only the existing generated folder flow; no remembering or credential lookup")
            } else {
                saved.refresh(); await saved.work?.value; browser.refreshConnectedLocations(force: true)
                guard let bookmark = saved.snapshot.locations.first, saved.snapshot.locations.count == 1 else {
                    throw UIVerification.Failure(message: "Saved server was not discovered")
                }
                let store = SMBSavedServerStore(directory: profile.appendingPathComponent("smb-servers"))
                let remembered = try await store.inspect(); await store.close()
                try require(remembered?.credentials.count == 1 && remembered?.credentials.first?.state == .ready, "Generated password was not saved")
                stage = "saved-reconnect"; try await close(first)
                browser.refreshConnectedLocations(force: true)
                try await wait { !browser.volumeBrowser.isHidden && !browser.volumeBrowser.connectedServers.visibleTiles.isEmpty }
                connections += 1; try require(connections <= 2, "Authentication ceiling")
                guard let tile = browser.volumeBrowser.connectedServers.visibleTiles.first else { throw UIVerification.Failure(message: "Saved tile missing") }
                try require(tile.performAccessibleOpen(NSAccessibilityCustomAction(name: "Open", handler: { true })), "Saved native tile refused")
                try await wait { browser.smbTabs[browser.activeID]?.connectionID != first.connectionID && browser.smbTabs[browser.activeID] != nil
                    && saved.connectionProgress.isEmpty }
                guard let reconnected = browser.smbTabs[browser.activeID] else { throw UIVerification.Failure(message: "Saved reconnect did not attach") }
                owner = reconnected
                owners.append(owner); try await ready(owner)
                guard let liveHistory = owner.uploads else { throw UIVerification.Failure(message: "Actual Upload Outcomes owner missing") }
                try require(service.verificationWindow?.window?.isVisible != true && owner.savedConnection?.serverID == bookmark.serverID,
                    "Saved reconnect reopened the form or lost the bookmark")
                try require(vault.generatedMemoryQualificationCounts?.reads == 1
                    && vault.generatedMemoryQualificationCounts?.saves == 1, "Saved reconnect did not reuse its exact generated credential")
                checks.append("Normal Remember persists one exact generated server/credential; an actual saved tile reconnects through the real helper without showing Connect")
                stage = "file-group"; try await paste(["Final.bin", "Verified.bin"], into: owner)
                try require(browser.smbUpload.lastGroupCompleted?.completedRoots == 2, "File group did not complete")
                stage = "collision"; try await paste(["Existing.bin"], into: owner)
                let collision = try await liveHistory.inspect()
                try require(collision.records.count == 3 && collision.records.filter { $0.outcome == .finalCollision }.count == 1,
                    "Final collision result differs")
                checks.append("Private native file Paste verifies two selected files; a same-name attempt preserves the existing destination with a recorded collision")
            }
            stage = "folder"; try await paste(["Generated Folder"], into: owner)
            try require(browser.smbUpload.lastGroupCompleted?.completedRoots == 1, "Folder upload did not complete")
            stage = "mixed"; try await paste(["Mixed.txt", "Mixed Folder"], into: owner)
            try require(browser.smbUpload.lastGroupCompleted?.completedRoots == 2, "Mixed roots did not complete")
            checks.append("One folder including nested files/empty directory and a mixed file/folder group use the same operation owner without a Normal confirmation")
            if foldersOnly {
                stage = "folder-collision"
                try await paste(["Generated Folder"], into: owner)
                guard let outcomes = owner.uploads else { throw UIVerification.Failure(message: "Folder outcomes missing") }
                let collision = try await outcomes.inspect()
                try require(collision.records.count == 4 && collision.records.filter { $0.outcome == .finalCollision }.count == 1,
                    "Occupied folder name was not preserved")
                checks.append("Repeating the folder upload preserves its complete published tree and retains the separate verified working root")
            }
            try await close(owner)
            stage = "source-preservation"
            try await Task.detached {
                for (name, expected) in inputs {
                    let url = source.appendingPathComponent(name)
                    guard url.resolvingSymlinksInPath() == url, try Data(contentsOf: url) == expected else {
                        throw UIVerification.Failure(message: "A local generated original changed")
                    }
                }
            }.value
            await saved.work?.value; await service.closeAndDrain(); await vault.drain()
            let final = try await history.inspect()
            try require(final.records.count == (foldersOnly ? 4 : 6)
                && final.records.filter { $0.outcome == .verified }.count == (foldersOnly ? 3 : 5)
                && final.records.allSatisfy { !$0.active }, "Final upload outcomes differ")
            facts["historyRows"] = final.records.map { $0.id.uuidString + ":" + $0.outcome.rawValue }.sorted()
            facts["workingNames"] = final.records.filter { $0.outcome == .finalCollision }.map(\.temporaryName)
            _ = await history.close()
            facts["passed"] = true; facts["stage"] = "finished"; facts["checks"] = checks
            facts["authenticationReservations"] = connections; facts["workersDrained"] = true
            facts["generatedCredentialReads"] = vault.generatedMemoryQualificationCounts?.reads ?? -1
            facts["generatedCredentialSaves"] = vault.generatedMemoryQualificationCounts?.saves ?? -1
            await captureAppLogs()
            return facts
        } catch {
            facts["connectionFailures"] = owners.map { $0.session.latest.failure?.rawValue ?? "none" }
            facts["uploadNotice"] = creatingOnly ? owners.last?.uploadNotice ?? "" : browser.smbUpload.lastNotice
            if let interruption = browser.smbUpload.lastGroupInterruption {
                facts["uploadFailureCode"] = DiagnosticErrors.project(interruption).code
                facts["verifiedRoots"] = interruption.completedRoots
                facts["unsubmittedRoots"] = interruption.notSubmitted
            }
            var drained = true
            for owner in owners {
                let result = await owner.close().value
                drained = drained && result.actualExit && result.pipeDrained && result.socketAndCatalogDrained
                    && result.ownerReleased && !result.forcedContainment
            }
            if editingOnly && drained {
                for document in ApplicationRemoteTextEditors.shared.documentsForVerification
                    where owners.contains(where: { $0.connectionID == document.connectionID }) {
                    document.connectionWillClose(); await document.work?.value; await document.stopWork?.value
                    do { try await SMBOriginalEditorVerification.close(document) }
                    catch { drained = false }
                }
            }
            await saved.work?.value; await service.closeAndDrain(); await vault.drain(); _ = await history.close()
            facts["passed"] = false; facts["stage"] = stage; facts["checks"] = checks
            facts["authenticationReservations"] = connections
            facts["failureType"] = String(reflecting: type(of: error))
            facts["failure"] = (error as? UIVerification.Failure)?.message ?? String(describing: DiagnosticErrors.project(error).code)
            facts["workersDrained"] = drained
            facts["commandCounts"] = owners.map { $0.session.commandCounts ?? [] }
            facts["folderDiagnostics"] = owners.compactMap { owner -> [String: Any]? in
                guard let value = owner.session.folderUploadDiagnostic else { return nil }
                var result: [String: Any] = ["boundary": Int(value.boundary), "cause": Int(value.cause)]
                if let command = value.command { result["command"] = Int(command) }
                if let status = value.status { result["status"] = UInt64(status) }
                return result
            }
            await captureAppLogs()
            return facts
        }
    }
    /// One real SMB connection and the existing native source/receiver owners.
    /// File, group and folder receipts share the ordinary local history/Undo.
    private static func verifyDownloadDrops(root: URL, browser: BrowserViewController,
        owner: SMBTabController, includeSingle: Bool, includeGroup: Bool) async throws -> [String] {
        guard let workspace = browser.workspace, let window = browser.view.window else {
            throw UIVerification.Failure(message: "Download workspace missing")
        }
        let parent = root.appendingPathComponent("source/Download Destination", isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: parent,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }.value
        let journal = root.appendingPathComponent("state/drop-history", isDirectory: true)
        let engine = RecoverableFileOperations(journalDirectory: journal)
        browser.recoverableFileOperations = engine
        workspace.activate(browser); try require(workspace.splitActive(at: .trailing), "Download pane missing")
        let receiver = workspace.activeBrowser
        receiver.permitsBackgroundVerification = true; receiver.dragDrop.permitsVerification = true
        receiver.recoverableFileOperations = engine; receiver.navigate(to: .directory(parent))
        try await wait { !receiver.isLoading && receiver.location.directoryURL?.path == parent.path }
        workspace.activate(browser)
        let observation = try await browser.fileOperations.observeDirectory(parent)
        let destination = ArchiveExtractionDestination(directory: parent, observation: observation, access: .init(leases: []))
        var chooserCalls = 0, reviews = 0, validReviews = true
        browser.smbDownload.chooseForVerification = { _ in chooserCalls += 1; return nil }
        browser.remoteBatchDownload.chooseForVerification = { _ in chooserCalls += 1; return nil }
        browser.smbFolderDownload.chooseForVerification = { _ in chooserCalls += 1; return nil }
        browser.smbFolderDownload.reviewForVerification = { review in
            reviews += 1
            validReviews = validReviews && review.model.summary.files == 2 && review.model.summary.folders == 2
                && review.model.summary.logicalBytes == 32808
            return reviews == 1 ? .cancel : .download(review.model.name)
        }
        defer {
            browser.smbDownload.chooseForVerification = nil
            browser.remoteBatchDownload.chooseForVerification = nil
            browser.smbFolderDownload.chooseForVerification = nil
            browser.smbFolderDownload.reviewForVerification = nil
        }
        func select(_ names: [String]) async throws {
            workspace.activate(browser)
            try await wait { !owner.hasPendingPages && owner.session.latest.snapshot?.state == .complete }
            let indexes = (0..<owner.rows.table.numberOfRows).filter {
                names.contains(owner.rows.cache.entry(at: Int64($0))?.name.displayName ?? "")
            }
            try require(indexes.count == names.count, "Download source rows missing")
            owner.rows.table.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
            owner.rows.table.scrollRowToVisible(indexes[0]); owner.rows.table.layoutSubtreeIfNeeded()
            try require(browser.smbDownload.canRequest(from: owner), "Selected SMB rows cannot download")
        }
        func settled() async throws {
            try await wait(seconds: 90) { browser.operationTask == nil && browser.operationPreparationTask == nil }
            try require(!owner.isClosing && owner.session.latest.failure == nil, "Download ended its connection")
        }
        func exactFiles(_ files: [String: Data]) async throws {
            try await Task.detached {
                for (name, expected) in files {
                    guard try Data(contentsOf: parent.appendingPathComponent(name)) == expected else {
                        throw UIVerification.Failure(message: "Downloaded bytes differ")
                    }
                }
            }.value
        }
        func undo(_ identifiers: [UUID]) async throws {
            let cold = RecoverableFileOperations(journalDirectory: journal)
            for identifier in identifiers {
                let result = await cold.undo(recordID: identifier)
                try require(result.result.disposition == .succeeded, "Cold download Undo failed")
            }
            browser.operationCoordinator.reloadLocalDirectory(parent)
            try await wait { !receiver.isLoading && receiver.displayedEntries.isEmpty }
            // Undo deliberately retains private recovery data. Only the
            // delivered names must disappear; never discard recovery to make
            // a fixture directory empty.
            let deliveredNamesGone = await Task.detached {
                ["Final.bin", "Verified.bin", "Generated Folder"].allSatisfy {
                    !FileManager().fileExists(atPath: parent.appendingPathComponent($0).path)
                }
            }.value
            try require(deliveredNamesGone, "Cold download Undo left a delivered item")
        }
        func readyForGesture(_ phase: String) async throws {
            workspace.activate(browser)
            window.title = "Generated SMB pane drag · " + root.lastPathComponent.prefix(8)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try require(window.makeFirstResponder(owner.rows.table), "SMB drag source did not gain focus")
            receiver.dragDrop.selectionDidChange()
            try await wait { receiver.dragDrop.hasPreparedDestinationForVerification(parent)
                && !receiver.dragDrop.verificationState.preparing }
            ArchivePromiseGestureVerification.report("ready", ["phase": phase, "ordinarySMBRows": true,
                "realServer": true, "receiver": "Traverse local pane", "waitSeconds": 600])
        }

        // The one-file adapter rejects stale/wrong-parent drops before it
        // invokes the existing receive/publish operation.
        if includeSingle {
        try await select(["Final.bin"])
        guard let selected = owner.selectedDownload else { throw UIVerification.Failure(message: "SMB file selection missing") }
        try require(!browser.smbDownload.requestDropped(from: owner, expected: selected,
            destination: destination, current: { false }), "Stale drop admitted")
        try require(!browser.smbDownload.requestDropped(from: owner, expected: selected,
            destination: .init(directory: root, observation: observation, access: .init(leases: [])),
            current: { true }), "Wrong-parent drop admitted")
        let offer = RemoteDownloadDragOffer(browser: browser, owner: owner,
            rows: owner.rows.table.selectedRowIndexes, selection: .smbFile(selected))
        try require(offer.admit(to: destination, current: { true }), "SMB file drop refused")
        try await settled()
        guard let single = browser.smbDownload.lastOutcome, let singleID = single.recordID else {
            throw UIVerification.Failure(message: "SMB file drop result missing: " + browser.smbDownload.lastNotice)
        }
        try require(single.result.disposition == .succeeded, "SMB file publication needs review")
        try await exactFiles(["Final.bin": uploadFixtureBodies()["Final.bin"]!])
        try await wait { !receiver.isLoading && receiver.displayedEntries.count == 1 }
        let fileRequests = browser.smbDownload.bodyRequestsForQualification
        try require(browser.smbDownload.requestDropped(from: owner, expected: selected,
            destination: destination, current: { true }), "Collision check did not enter preflight")
        try await settled()
        try require(browser.smbDownload.bodyRequestsForQualification == fileRequests
            && browser.smbDownload.lastOutcome?.recordID == singleID, "Collision performed a second receive")
        try await undo([singleID])
        ArchivePromiseGestureVerification.report("file-copy-undo-passed", ["coldEngine": true, "files": 1])
        }

        if includeGroup {
            try await select(["Final.bin", "Verified.bin"])
            guard owner.sealedBatchDownload?.items.count == 2 else { throw UIVerification.Failure(message: "SMB group selection missing") }
            try await readyForGesture("group")
            try await wait(seconds: 600) { browser.operationHistory.downloadBatch?.parent.path == parent.path || owner.isClosing }
            try await settled()
            guard let batch = browser.operationHistory.downloadBatch else { throw UIVerification.Failure(message: "SMB group result missing") }
            try require(batch.items.count == 2 && batch.completed == 2 && batch.result.disposition == .succeeded
                && !batch.retainedStaging && chooserCalls == 0, "SMB group did not complete")
            try await exactFiles(["Final.bin": uploadFixtureBodies()["Final.bin"]!, "Verified.bin": uploadFixtureBodies()["Verified.bin"]!])
            try await wait { !receiver.isLoading && receiver.displayedEntries.count == 2 }
            let records = batch.items.compactMap { $0.outcome?.recordID }
            try require(records.count == 2, "SMB group lost Undo records")
            ArchivePromiseGestureVerification.report("write-completed", ["phase": "group", "files": 2, "visibleInDestination": true])
            try await Task.sleep(for: .seconds(1)); try await undo(records)
            ArchivePromiseGestureVerification.report("undo-completed", ["phase": "group", "succeeded": true, "coldEngine": true])
        }

        try await select(["Generated Folder"])
        guard let folder = owner.selectedFolderDownload else { throw UIVerification.Failure(message: "SMB folder selection missing") }
        try require(browser.smbFolderDownload.requestDropped(from: owner, expected: folder,
            destination: destination, current: { true }), "SMB folder Cancel check refused")
        try await settled()
        try require(reviews == 1, "SMB folder Cancel review count differs: \(reviews), expected 1")
        try require(validReviews, "SMB folder Cancel summary differs: expected 2 files, 2 folders, 32808 bytes")
        try require(browser.smbFolderDownload.bodyRequestsForVerification == 0,
            "SMB folder Cancel received bodies: \(browser.smbFolderDownload.bodyRequestsForVerification) requests, expected 0")
        try require(receiver.displayedEntries.isEmpty,
            "SMB folder Cancel changed destination: \(receiver.displayedEntries.count) visible entries, expected 0")
        try await readyForGesture("folder")
        try await wait(seconds: 600) { browser.smbFolderDownload.lastOutcome != nil || owner.isClosing }
        try await settled()
        guard let result = browser.smbFolderDownload.lastOutcome, let folderID = result.recordID else {
            throw UIVerification.Failure(message: "SMB folder result missing: " + browser.smbFolderDownload.lastNotice)
        }
        try require(result.result.disposition == .succeeded && reviews == 2 && validReviews && chooserCalls == 0,
            "SMB folder publication needs review")
        let bodies = uploadFixtureBodies()
        try await exactFiles(["Generated Folder/Note.txt": bodies["Generated Folder/Note.txt"]!,
            "Generated Folder/Nested/Member.bin": bodies["Generated Folder/Nested/Member.bin"]!])
        let emptyDirectory = try await Task.detached {
            try FileManager().contentsOfDirectory(atPath: parent.appendingPathComponent("Generated Folder/Empty").path).isEmpty
        }.value
        try require(emptyDirectory, "Empty folder was not preserved")
        try await wait { !receiver.isLoading && receiver.displayedEntries.count == 1 }
        ArchivePromiseGestureVerification.report("write-completed", ["phase": "folder", "files": 2, "visibleInDestination": true])
        try await Task.sleep(for: .seconds(1)); try await undo([folderID])
        ArchivePromiseGestureVerification.report("undo-completed", ["phase": "folder", "succeeded": true, "coldEngine": true])
        let final = try await engine.inspectExistingHistory()
        let expectedRecords = 1 + (includeSingle ? 1 : 0) + (includeGroup ? 2 : 0)
        try require(final.records.count == expectedRecords && final.records.allSatisfy { !$0.canUndo }, "Cold Undo history differs")
        var checks = [includeGroup
                ? "Actual native two-file group and one-folder pane drags with visible refresh and exact local bytes"
                : "Actual native one-folder pane drag with visible refresh and exact local bytes",
            "Folder review Cancel receives no bodies; nested and empty directories survive whole-folder cold Undo",
            "One connection, no real Keychain, general clipboard, new container, external export or new writer"]
        if includeSingle { checks.insert("Real SMB file drop, stale target refusal, occupied-name preservation and cold Undo", at: 0) }
        return checks
    }

    private static func actionRows(_ snapshot: SMBActionHistorySnapshot) -> [String] {
        snapshot.records.map { row in
            [row.id.uuidString, row.operation.rawValue, row.outcome.rawValue, row.source.displayName,
             row.target?.displayName ?? "", row.server.host, row.server.share.displayName,
             row.directory.map(\.displayName).joined(separator: "/"),
             row.destinationDirectory?.map(\.displayName).joined(separator: "/") ?? "",
             String(row.createdAt.timeIntervalSince1970)].joined(separator: "|")
        }.sorted()
    }
    static func uploadFixtureBodies() -> [String: Data] {
        ["Final.bin": Data((0..<128).map { UInt8($0) }),
         "Verified.bin": Data((0..<32769).map { UInt8($0 % 251) }),
         "Existing.bin": Data("Generated collision input.\n".utf8),
         "Mixed.txt": Data("Generated mixed upload.\n".utf8),
         "Generated Folder/Note.txt": Data("Generated folder note.\n".utf8),
         "Generated Folder/Nested/Member.bin": Data((0..<32785).map { UInt8(($0 + 7) % 251) }),
         "Mixed Folder/Member.txt": Data("Generated mixed folder.\n".utf8)]
    }
    private static func removeGeneratedRecords(bundle: URL, storage: SMBTemporaryStorage, store: SMBSavedServerStore,
        vault: SMBPasswordVault, activity: FileActivityGate) async -> Bool {
        let cleanup = SMBConnectionCoordinator(bundleURL: bundle, storage: storage, servers: store, passwords: vault, activity: activity)
        var complete = false
        do {
            if let snapshot = try await cleanup.inspect() {
                for server in snapshot.servers { _ = await cleanup.forget(.server(server.id, removePassword: true)) }
                if let remaining = try await cleanup.inspect() {
                    for claim in remaining.credentials { _ = await cleanup.forget(.password(claim.reference.id)) }
                }
            }
            let final = try await cleanup.inspect(); complete = final == nil || final?.servers.isEmpty == true && final?.credentials.isEmpty == true
        } catch { complete = false }
        await cleanup.drain(); return complete
    }
    static func buttons(_ root: NSView) -> [NSButton] { (root as? NSButton).map { [$0] } ?? root.subviews.flatMap(buttons) }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    static func wait(seconds: Int = 20, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 100) { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Actual generated Connect did not settle")
    }
    private static func marker(_ path: URL) async throws {
        for _ in 0..<1500 {
            if await Task.detached(operation: { FileManager.default.fileExists(atPath: path.path) }).value { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: "Actual generated query hold did not become ready")
    }
}
#endif
