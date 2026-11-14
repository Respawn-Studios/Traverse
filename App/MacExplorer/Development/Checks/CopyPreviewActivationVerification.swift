#if DEBUG
import AppKit
import Darwin
import FileOperations
import SQLite3

/// Native lifecycle and persistence checks, using only this run's generated root.
@MainActor
enum CopyPreviewActivationVerification {
    static func run(in testRoot: URL, output: URL) async throws -> [String] {
        let root = testRoot.appendingPathComponent("copy-preview-activation-" + UUID().uuidString, isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }.value
        var checks: [String] = []
        checks += try await HistoryProtectionVerification.run(in: root)
        let bootstrap = BrowserViewController(settings: BrowserSettings(persist: false)), bootstrapGate = AdmissionGate()
        bootstrap.permitsBackgroundVerification = true
        bootstrap.folderAccess = FolderAccessController(stateDirectory: nil)
        bootstrap.beforeBeginReferencesForVerification = { await bootstrapGate.wait() }
        bootstrap.readVolumesForVerification = { [] }
        var bootstrapFinished = false
        bootstrap.didFinishBeginForVerification = { bootstrapFinished = true }
        bootstrap.begin()
        try await wait { bootstrapGate.entered }
        try require(bootstrap.isLoading && bootstrap.overlay.isHidden && bootstrap.status.stringValue.contains("Loading locations"),
                    "Startup permission/reference wait was presented as an empty machine")
        bootstrapGate.release(); try await wait { bootstrapFinished }
        bootstrap.suspendBrowser()
        checks.append("Initial reference/access wait shows loading, not a false empty drive list")
        for state in ["absent", "schema2", "schema3", "schema4", "legacy", "incomplete", "hot", "busy"] {
            let parent = root.appendingPathComponent(state, isDirectory: true)
            try await Task.detached { try FileManager().createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }.value
            let journal = parent.appendingPathComponent("journal", isDirectory: true)
            let engine = RecoverableFileOperations(journalDirectory: journal)
            var ownerLease: Int32 = -1
            defer { if ownerLease >= 0 { close(ownerLease) } }
            if !["absent", "legacy"].contains(state) {
                let result = await engine.perform(.createFolder(parent: parent, name: "Generated folder"))
                try require(result.result.disposition == .succeeded, "History matrix seeding failed")
                if state == "schema2" {
                    try await Task.detached { try sql(journal, "UPDATE metadata SET value='2' WHERE key='version'; PRAGMA user_version=2") }.value
                } else if state == "schema4" {
                    let qualified = try await scopedEngine(journal: journal, root: parent)
                    try require(await qualified.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled, "Schema4 seeding failed")
                } else if state == "incomplete" {
                    try await Task.detached { try FileManager().moveItem(at: journal.appendingPathComponent(".mac-explorer-sqlite-ready-v2"), to: parent.appendingPathComponent("preserved-ready-token")) }.value
                } else if state == "hot" {
                    try await Task.detached {
                        let url = journal.appendingPathComponent("operations-v2.sqlite-journal")
                        try Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]).write(to: url, options: .withoutOverwriting)
                        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }.value
                } else if state == "busy" {
                    ownerLease = open(journal.appendingPathComponent(".mac-explorer-journal-v1").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    try require(ownerLease >= 0 && flock(ownerLease, LOCK_EX | LOCK_NB) == 0, "Native busy-history lease did not start")
                }
            } else if state == "legacy" {
                try await Task.detached {
                    try FileManager().createDirectory(at: journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    for (name, data) in [(".mac-explorer-journal-v1", Data(UUID().uuidString.utf8)),
                        (UUID().uuidString + "-000000.json", Data("Generated preserved legacy archive".utf8))] {
                        let file = journal.appendingPathComponent(name)
                        try data.write(to: file, options: .withoutOverwriting)
                        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                }.value
            }
            let before = try await Task.detached { try snapshot(journal) }.value
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = true
            let browser = BrowserViewController(settings: settings)
            browser.permitsBackgroundVerification = true; browser.recoverableFileOperations = engine
            _ = browser.view
            browser.inspectOperationRecovery()
            await browser.recoveryInspectionTask?.value
            let settingsWindow = BrowserSettingsWindow.make(browser.makeSettingsView(initialPage: .operations))
            settingsWindow.contentView?.layoutSubtreeIfNeeded()
            settingsWindow.orderOut(nil); settingsWindow.close()
            let expected: OperationHistoryReadiness
            switch state {
            case "schema2": expected = .available(catalogVersion: 2)
            case "schema3": expected = .available(catalogVersion: 3)
            case "schema4": expected = .available(catalogVersion: 4)
            case "legacy": expected = .legacyImportRequired
            case "incomplete": expected = .initializationIncomplete
            case "hot": expected = .recoveryRequired
            case "busy": expected = .busy
            default: expected = .absent
            }
            try require(browser.recoveryHistoryReadiness == expected, "Native history readiness did not match its fixture")
            browser.showOperationRecovery(nil)
            await browser.recoveryInspectionTask?.value
            let needsPreparation = ["schema2", "legacy", "incomplete", "hot"].contains(state)
            try require(browser.recoveryWindow?.offersHistoryPreparationForVerification == needsPreparation,
                        "Recovery did not expose the appropriate explicit preparation action")
            browser.recoveryWindow?.window?.contentView?.layoutSubtreeIfNeeded()
            browser.recoveryWindow?.close()
            try require(before == (try await Task.detached { try snapshot(journal) }.value), "Passive native inspection/Settings changed history")
            browser.suspendBrowser()
            checks.append("Read-only native history and Operations settings: " + state)
        }

        let active = root.appendingPathComponent("activation", isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: active, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }.value
        let journal = active.appendingPathComponent("journal", isDirectory: true)
        let engine = try await scopedEngine(journal: journal, root: active)
        let settings = BrowserSettings(persist: false, persistenceFile: active.appendingPathComponent("preferences.json"))
        let outcome = await engine.activateCopyPreview(review: { disclosure in
            await MainActor.run {
                let alert = BrowserViewController.makeCopyPreviewDisclosureAlert(disclosure)
                return alert.buttons.count == 2 && alert.buttons.first?.title == "Enable Preview"
                    && alert.informativeText.contains("Older builds") && !settings.groupedCopyPreview
            }
        }, persist: { try await settings.commitCopyPreview($0) })
        try require(outcome == .enabled && settings.groupedCopyPreview && settings.copyPreviewReceipt != nil,
                    "Acknowledged native preference activation failed")
        let receipt = settings.copyPreviewReceipt!
        checks.append("Explicit generated activation, disclosure construction and durable preference acknowledgement")
        let before = try await Task.detached { try snapshot(journal) }.value
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        let coordinator = ApplicationOperationCoordinator()
        let fresh = try await scopedEngine(journal: journal, root: active)
        await coordinator.restoreCopyPreviewIfNeeded(engine: fresh, settings: restored)
        try require(fresh.isCopyPreviewEnabled && restored.groupedCopyPreview,
                    "Saved-on native lifecycle did not rebind")
        try require(before == (try await Task.detached { try snapshot(journal) }.value), "Saved-on native lifecycle changed history")
        checks.append("Saved-on startup binds its original existing history without writes")

        try await verifyPreferenceOrdering(root: active, receipt: receipt)
        checks.append("Queued ordinary snapshots cannot overwrite acknowledged preview state; failed commits retain the previous state")
        try await verifyIdleOwnership(root: active, engine: engine)
        checks.append("Idle activation rejects queued, paused, cancelled-but-draining admission and inspection/preparation owners")
        let encoded = try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks,
            "notExercised": ["Owner history upgrade", "Physical first-enable click", "Power loss", "Genuine hot journal in this native window matrix; separately qualified in fresh core processes"]], options: [.prettyPrinted, .sortedKeys])
        try await Task.detached { try encoded.write(to: output.appendingPathComponent("copy-preview-activation.json"), options: .withoutOverwriting) }.value
        return checks
    }

    private static func verifyIdleOwnership(root: URL, engine: RecoverableFileOperations) async throws {
        let coordinator = ApplicationOperationCoordinator(), owner = UUID()
        guard let inspection = coordinator.beginInspection() else { throw UIVerification.Failure(message: "Inspection fixture did not start") }
        try require(!coordinator.beginCopyPreview(owner: owner), "Activation ignored inspection ownership")
        coordinator.finishInspection(inspection)
        try require(coordinator.beginPreparation(owner: owner), "Preparation fixture did not start")
        try require(!coordinator.beginCopyPreview(owner: UUID()), "Activation ignored preparation ownership")
        coordinator.finishPreparation(owner: owner)
        let file = root.appendingPathComponent("Queued sample.txt"), target = root.appendingPathComponent("Queue destination", isDirectory: true)
        try await Task.detached {
            try Data("Generated queue sample".utf8).write(to: file, options: .withoutOverwriting)
            try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        }.value
        let browser = BrowserViewController(settings: BrowserSettings(persist: false))
        browser.permitsBackgroundVerification = true; browser.recoverableFileOperations = engine
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        let queue = coordinator.transfers, gate = AdmissionGate()
        queue.pause(); queue.beforeAdmissionObservationReturnsForVerification = { _ in await gate.wait() }
        defer { gate.release(); queue.beforeAdmissionObservationReturnsForVerification = nil; queue.cancelAllWaiting(); browser.suspendBrowser() }
        guard let id = queue.enqueue(sources: [file], destination: target, move: false, title: "Generated idle check", origin: browser, engine: engine, metadataPolicy: .strict) else {
            throw UIVerification.Failure(message: "Idle queue fixture was refused")
        }
        try await wait { gate.entered }
        try require(!coordinator.beginCopyPreview(owner: owner), "Activation ignored paused queued work")
        try require(queue.cancelWaiting(id) && !queue.hasOutstandingWork && !queue.isIdleForCopyPreview,
                    "Cancelled admission was declared drained too early")
        try require(!coordinator.beginCopyPreview(owner: owner), "Activation ignored cancelled admission lifetime")
        gate.release(); try await wait { queue.isIdleForCopyPreview }
        try require(coordinator.beginCopyPreview(owner: owner), "Fully idle activation ownership did not start")
        try require(coordinator.beginInspection() == nil && !queue.canAdmit && !queue.resume(), "Activation allowed competing ownership")
        coordinator.finishCopyPreview(owner: owner)
        try require(coordinator.beginCopyPreview(owner: owner), "Delayed setup fixture did not reserve ownership")
        let setupSettings = BrowserSettings(persist: false), setupGate = AdmissionGate()
        let work = Task { await setupGate.wait() }
        coordinator.copyPreviewTask = work
        coordinator.setCopyPreviewAwaitingChoice(true, owner: owner)
        let delay = coordinator.watchCopyPreviewDelay(owner: owner, settings: setupSettings, delay: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(20))
        try require(setupSettings.copyPreviewStatus.isEmpty, "Consent was mislabeled as a disk wait")
        coordinator.setCopyPreviewAwaitingChoice(false, owner: owner)
        try await wait { setupSettings.copyPreviewStatus.contains("Waiting for macOS") }
        coordinator.cancelCopyPreviewSetup(settings: setupSettings)
        try require(work.isCancelled && coordinator.copyPreviewStopRequested && coordinator.copyPreviewOwner == owner,
                    "Cancel setup released ownership before its worker drained")
        try require(setupSettings.copyPreviewStatus.contains("Stopping setup"), "Delayed setup did not explain cancellation")
        setupGate.release(); await work.value; delay.cancel()
        coordinator.finishCopyPreview(owner: owner); coordinator.copyPreviewTask = nil
        try require(!coordinator.copyPreviewStopRequested, "Drained setup retained a stale Stop state")
    }

    private static func verifyPreferenceOrdering(root: URL, receipt: CopyPreviewActivationReceipt) async throws {
        let file = root.appendingPathComponent("ordered-preferences.json")
        let persistence = CopyPreviewPreferencePersistence(file: file, receipt: nil, disclosed: false)
        let stale = Data(#"{"version":10,"groupedCopyPreview":false,"showsPathBar":true}"#.utf8)
        try await persistence.commit(stale, receipt: receipt)
        persistence.saveOrdinary(stale)
        await persistence.drainForVerification()
        let data = try await Task.detached { try Data(contentsOf: file) }.value
        let value = BrowserSettings(persist: false, restoredData: data)
        try require(value.groupedCopyPreview && value.copyPreviewReceipt == receipt && value.showsPathBar,
                    "Stale ordinary snapshot erased acknowledged preview state")
        let failingFile = root.appendingPathComponent("failed-preferences.json")
        let failure = CopyPreviewPreferencePersistence(file: failingFile, receipt: nil, disclosed: false,
            beforeWrite: { durable in if durable { throw FileOperationFailure.outOfSpace } })
        do { try await failure.commit(stale, receipt: receipt); throw UIVerification.Failure(message: "Preference fault was not exercised") }
        catch FileOperationFailure.outOfSpace {}
        failure.saveOrdinary(Data(#"{"version":10,"groupedCopyPreview":true}"#.utf8))
        await failure.drainForVerification()
        let saved = try await Task.detached { try Data(contentsOf: failingFile) }.value
        try require(!BrowserSettings(persist: false, restoredData: saved).groupedCopyPreview,
                    "Failed enable contaminated later ordinary preference saving")
        let lostFile = root.appendingPathComponent("lost-ack-preferences.json")
        let lost = CopyPreviewPreferencePersistence(file: lostFile, receipt: nil, disclosed: false,
            beforeWrite: { _ in }, afterWrite: { durable in if durable { throw FileOperationFailure.ioFailure } })
        do { try await lost.commit(stale, receipt: receipt); throw UIVerification.Failure(message: "Lost preference acknowledgement was not exercised") }
        catch FileOperationFailure.ioFailure {}
        let unacknowledged = try await Task.detached { try Data(contentsOf: lostFile) }.value
        try require(BrowserSettings(persist: false, restoredData: unacknowledged).groupedCopyPreview,
                    "Lost acknowledgement fixture never wrote its candidate")
        lost.saveOrdinary(stale); await lost.drainForVerification()
        let repaired = try await Task.detached { try Data(contentsOf: lostFile) }.value
        try require(!BrowserSettings(persist: false, restoredData: repaired).groupedCopyPreview,
                    "Unacknowledged candidate became ordinary writer authority")
        let newer = BrowserSettings(persist: false, restoredData: Data(#"{"version":999}"#.utf8),
            persistenceFile: root.appendingPathComponent("newer-preferences.json"))
        try require(!newer.canPersistCopyPreview, "Unsupported preferences allowed preview persistence")
        do { try await newer.prepareCopyPreviewPreferences(); throw UIVerification.Failure(message: "Unsupported preferences were prepared") }
        catch FileOperationFailure.unavailable {}
    }

    nonisolated static func scopedEngine(journal: URL, root: URL) async throws -> RecoverableFileOperations {
        try await Task.detached {
            let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey])
            guard let text = values.volumeUUIDString, let id = UUID(uuidString: text),
                  let unusedTestVolume = UUID(uuidString: "00000000-0000-4000-8000-000000000001"),
                  let scope = QualifiedCopyPreviewScope(volumes: [id, unusedTestVolume], historyVolume: id) else {
                throw FileOperationFailure.unsupported
            }
            return RecoverableFileOperations(journalDirectory: journal, qualifiedCopyPreview: scope)
        }.value
    }
    nonisolated private static func sql(_ journal: URL, _ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent("operations-v2.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
    }
    nonisolated private static func snapshot(_ journal: URL) throws -> [String: Data] {
        guard FileManager().fileExists(atPath: journal.path) else { return [:] }
        let root = try FileManager().attributesOfItem(atPath: journal.path)
        var result: [String: Data] = [".directory-identity": Data("\(root[.systemFileNumber] ?? "")|\(root[.posixPermissions] ?? "")|\(root[.creationDate] ?? "")".utf8)]
        for name in try FileManager().contentsOfDirectory(atPath: journal.path) {
            let file = journal.appendingPathComponent(name)
            result[name] = try Data(contentsOf: file)
            let attrs = try FileManager().attributesOfItem(atPath: file.path)
            result[name + ".identity"] = Data("\(attrs[.systemFileNumber] ?? "")|\(attrs[.posixPermissions] ?? "")|\(attrs[.creationDate] ?? "")".utf8)
        }
        return result
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw UIVerification.Failure(message: "Generated activation lifetime did not drain")
    }
    @MainActor private final class AdmissionGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
#endif
