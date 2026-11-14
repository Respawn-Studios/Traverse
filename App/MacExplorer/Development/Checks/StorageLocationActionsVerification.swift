#if DEBUG
import AppKit
import Darwin
import StorageAnalysis
import FileOperations

private final class LocationAccessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    var count: Int { lock.withLock { live } }
    func acquire() -> Token { lock.withLock { live += 1 }; return Token(self) }
    final class Token: @unchecked Sendable {
        private let owner: LocationAccessTracker
        init(_ owner: LocationAccessTracker) { self.owner = owner }
        deinit { owner.lock.withLock { owner.live -= 1 } }
    }
}
private final class LocationCheckHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func pause() throws {
        condition.lock(); defer { condition.unlock() }; started = true
        while !released {
            guard condition.wait(until: Date().addingTimeInterval(5)) else { throw UIVerification.Failure(message: "Held location check deadline") }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@MainActor enum StorageLocationActionsVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func validateInternalFixture(_ root: URL) async throws {
        try await Task.detached(priority: .utility) {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            guard root.deletingLastPathComponent().path == cache?.appendingPathComponent("MacExplorer-B06-Qualification").path else { throw StorageScanFailure.invalidOutput }
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw StorageScanFailure.invalidOutput }; defer { close(fd) }
            var folder = stat()
            guard fstat(fd, &folder) == 0, folder.st_uid == geteuid(), folder.st_mode & 0o777 == 0o700 else { throw StorageScanFailure.invalidOutput }
            let group = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard group >= 0 else { throw StorageScanFailure.invalidOutput }; defer { close(group) }
            var groupInfo = stat()
            guard fstat(group, &groupInfo) == 0, groupInfo.st_uid == geteuid(), groupInfo.st_mode & 0o777 == 0o700 else { throw StorageScanFailure.invalidOutput }
            let marker = openat(group, ".b06-internal-selected", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard marker >= 0 else { throw StorageScanFailure.invalidOutput }; defer { close(marker) }
            var value = stat()
            let expected = Array("Generated B06 internal selected fixture v1\n\(root.lastPathComponent)\n".utf8)
            guard fstat(marker, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
                  value.st_nlink == 1, value.st_mode & 0o777 == 0o600, value.st_size == expected.count else { throw StorageScanFailure.invalidOutput }
            var bytes = [UInt8](repeating: 0, count: expected.count + 1)
            guard read(marker, &bytes, bytes.count) == expected.count, Array(bytes.prefix(expected.count)) == expected else { throw StorageScanFailure.invalidOutput }
            var after = stat()
            guard fstatat(group, ".b06-internal-selected", &after, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == value.st_dev, after.st_ino == value.st_ino, after.st_size == value.st_size,
                  after.st_mode == value.st_mode, after.st_uid == value.st_uid, after.st_nlink == 1 else { throw StorageScanFailure.invalidOutput }
        }.value
    }
    static func run(root: URL, browser: BrowserViewController, ordinary: Bool, selectedTrash: Bool = false,
                    review: Bool = false, internalFixture: Bool = false, pickerPreferences: Bool = false,
                    inspectInternalOnly: Bool = false, inspectSelectedHistory: Bool = false) async throws -> [String: Any] {
        var stage = "fixture", finished = false
        defer { if !finished { print("MAC_EXPLORER_LOCATION_STAGE " + stage); fflush(stdout) } }
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let prefix = "location-fixture-", suffix = root.lastPathComponent.dropFirst(prefix.count)
        try require(root.lastPathComponent.hasPrefix(prefix) && suffix.count == 32
            && suffix.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Generated location fixture required")
        if internalFixture {
            try require(ordinary && selectedTrash && !review, "Internal fixture is limited to the selected-Trash check")
            try await validateInternalFixture(root)
        } else { try require(root.deletingLastPathComponent() == repository.appendingPathComponent(".build/b06-analyzer"), "Repository fixture required") }
        if inspectInternalOnly || inspectSelectedHistory {
            try require(inspectInternalOnly != inspectSelectedHistory && !pickerPreferences,
                        "Choose one admitted read-only reconciliation mode")
            if inspectInternalOnly {
                try require(internalFixture, "Internal reconciliation requires the exact cache fixture")
            } else {
                try require(!internalFixture && ordinary && selectedTrash && !review,
                            "Repository reconciliation requires the admitted selected fixture")
            }
            let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("PrivateState/operation-recovery"))
            let history = try await engine.inspectExistingHistory()
            let trashed = history.records.filter { $0.operation == "Move to Trash" }
            let created = history.records.filter { $0.operation == "New Folder" }
            try require(history.refusedEntries.isEmpty && history.nextCursor == nil && history.unfinishedCount == 0
                && history.unfinishedCountIsComplete && history.records.count == 3
                && trashed.count == 2 && trashed.allSatisfy { $0.state == "undone" && !$0.canUndo && !$0.canRecover }
                && created.count == 1 && created[0].state == "committed", "Selected fixture has an uncertain history")
            if inspectSelectedHistory {
                let folders = trashed.filter(\.nativeDirectoryTrashContract)
                let files = trashed.filter(\.nativeRegularFileTrashContract)
                try require(folders.count == 1 && files.count == 1
                    && folders[0].locations.contains { $0.path == root.appendingPathComponent("Folder").path }
                    && files[0].locations.contains { $0.path == root.appendingPathComponent("Other.txt").path }
                    && created[0].locations.contains { $0.path == root.appendingPathComponent("Newer operation").path },
                    "Selected fixture does not contain the expected native v11/v12 history")
            }
            guard case .available = history.readiness else { throw StorageScanFailure.invalidOutput }
            finished = true
            var report: [String: Any] = ["passed": true, "read_only_reconciliation": true, "record_count": history.records.count,
                    "verified_undone_trash_records": trashed.count, "source_mutations": false,
                    "checks": ["fresh guarded existing-history inspection", "both exact generated Trash records are undone", "no interrupted or refused records"]]
            if inspectSelectedHistory {
                report["native_trash_contracts"] = ["file-v11", "folder-v12"]
                report["expected_generated_paths_verified"] = ["Folder", "Other.txt", "Newer operation"]
            }
            return report
        }
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 8 << 20, preserveAfterClose: false)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage, workerURL: ordinary ? nil
            : repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-stored-locations/worker"))
        coordinator.configurePicker(from: browser)
        let owner = UUID()
        var accesses = 0, copied: String?
        var result: StorageAnalysisResult?
        let accessTracker = LocationAccessTracker(), hold = LocationCheckHold()
        let originalWriter = browser.clipboardWriter
        browser.clipboardWriter = { text, urls in copied = text; return urls.isEmpty ? .text : .failed }
        StoredAnalysisTableProbe.enabled = true
        defer {
            if !finished { result?.retainAfterCloseForQualification() }
            hold.release()
            browser.clipboardWriter = originalWriter; StoredAnalysisTableProbe.enabled = false
            if !review { browser.propertiesController.cancel(); browser.propertiesController.close(); coordinator.toolWindow?.close() }
        }
        coordinator.analyzeProperties(owner: owner, root: root, access: {
            accesses += 1; return accessTracker.acquire()
        }, onChange: { _, _ in })
        do {
            try await wait("Generated location scan") { coordinator.pagedResultForVerification != nil && !coordinator.hasWork }
        } catch {
            print("MAC_EXPLORER_LOCATION_DIAGNOSTIC " + String(describing: coordinator.pagedUpdateForVerification?.status)
                + " " + String(describing: coordinator.pagedDiagnosticForVerification) + " work=" + String(coordinator.hasWork))
            fflush(stdout)
            throw error
        }
        stage = "result capability"
        result = coordinator.pagedResultForVerification
        guard let id = result?.id, result?.supportsStoredLocations == true else { throw StorageScanFailure.invalidOutput }
        try require(coordinator.openFullAnalysis(owner: owner, root: root), "Full-analysis handoff refused")
        stage = "table rows"
        guard let tool = coordinator.toolWindow else { throw StorageScanFailure.invalidOutput }
        try await wait("Actual paged native table") { tool.pagedReadyForVerification && StoredAnalysisTableProbe.latest?.window === tool.window }
        guard let model = tool.pagedModelForVerification else { throw UIVerification.Failure(message: "Missing page model") }
        guard let folder = model.rows.first(where: { $0.title == "Folder" }),
              let other = model.rows.first(where: { $0.title == "Other.txt" }) else {
            throw UIVerification.Failure(message: "Generated root rows differ: \(model.rows.map(\.title).joined(separator: ",")); \(model.message)")
        }
        guard let table = StoredAnalysisTableProbe.latest else { throw UIVerification.Failure(message: "Missing native table") }
        try await wait("Native root rows installed") { table.numberOfRows == model.rows.count }
        if pickerPreferences {
            try require(!internalFixture && !review && !selectedTrash, "Picker preferences need their own generated mode")
            let checks = try await AnalysisFolderPickerVerification.livePreferences(browser: browser, coordinator: coordinator,
                root: root, output: repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018"))
            tool.close(); await coordinator.stopAndDrain()
            finished = true
            return ["passed": true, "checks": checks, "source_mutations": false, "preferences_persisted": false]
        }
        if review {
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("PrivateState/operation-recovery"))
            browser.propertiesController.cancel(); browser.propertiesController.close()
            model.select(folder.id)
            let previousClose = tool.onClose
            let store = storage.directory.appendingPathComponent("session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            tool.onClose = {
                previousClose?()
                Task {
                    await coordinator.stopAndDrain()
                    let disposed = await Task.detached(priority: .utility) {
                        for _ in 0..<200 {
                            if !FileManager.default.fileExists(atPath: store.path) { return true }
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        return false
                    }.value
                    print("MAC_EXPLORER_SELECTED_REVIEW_CLOSED disposed=" + String(disposed)); fflush(stdout)
                }
            }
            tool.window?.title = "Storage Analysis · generated selected-item review"
            tool.window?.makeKeyAndOrderFront(nil)
            let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/selected-cleanup-review-" + UUID().uuidString + ".png")
            if let window = tool.window { try await UIVerification.snapshot(window, to: capture) }
            finished = true
            return ["passed": true, "review": true, "generated_source": root.path, "capture": capture.lastPathComponent, "mutations_so_far": false]
        }
        if selectedTrash {
            var selectedResult = result
            guard selectedResult != nil else { throw StorageScanFailure.invalidOutput }
            var report = try await StorageSelectedTrashVerification.run(root: root, browser: browser, coordinator: coordinator,
                result: selectedResult!, model: model, folder: folder,
                evidenceDirectory: repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018"))
            tool.close(); await coordinator.stopAndDrain()
            browser.cancelDirectoryObservation()
            result = nil; selectedResult = nil
            let store = storage.directory.appendingPathComponent("session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            let disposed = await Task.detached(priority: .utility) {
                for _ in 0..<200 {
                    if !FileManager.default.fileExists(atPath: store.path) { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }.value
            try require(disposed, "Selected-operation catalog retained after closing and actual drain")
            report["checks"] = (report["checks"] as? [String] ?? []) + ["selected-operation close disposes owned catalog"]
            finished = true
            return report
        }
        func menu(_ row: StoredAnalysisRow) throws -> NSMenu {
            guard let index = model.rows.firstIndex(where: { $0.id == row.id }), let menu = table.contextMenu?(index) else { throw StorageScanFailure.invalidOutput }
            return menu
        }
        func perform(_ action: StoredLocationAction, menu: NSMenu) throws {
            guard let item = menu.items.first(where: { $0.title == action.rawValue }), item.isEnabled, let selector = item.action else {
                throw UIVerification.Failure(message: "Native location menu action unavailable")
            }
            try require(NSApp.sendAction(selector, to: item.target, from: item), "Native menu selector failed")
        }
        let captured = try menu(folder)
        stage = "origin menu"
        // A different Properties window becomes key between menu creation and
        // activation. The action must retain its original table row/browser.
        browser.propertiesController.show(urls: [root.appendingPathComponent("Other.txt")], relativeTo: browser.view.window)
        try await wait("Background Properties metadata") { !browser.propertiesController.model.isLoading }
        browser.propertiesController.window?.makeKeyAndOrderFront(nil)
        try perform(.copyPath, menu: captured)
        try await wait("Origin-bound Copy Path") { !model.actionRunning && !coordinator.hasWork }
        try require(copied == root.appendingPathComponent("Folder").path && model.actionMessage == "Path copied.", "Another window substituted its selection")
        try perform(.showInExplorer, menu: menu(folder))
        stage = "Explorer reveal"
        try await wait("Show in Explorer selection") { !model.actionRunning && !coordinator.hasWork && !browser.isLoading && browser.orderingTask == nil }
        try require(browser.location.directoryURL == root && browser.selectedURLs.contains(root.appendingPathComponent("Folder")), "Explorer did not reveal the recorded row")
        model.select(other.id); let staleMenu = try menu(other)
        model.open(folder)
        stage = "child page"
        try await wait("Stored child page") { !model.loading }
        copied = nil; try perform(.copyPath, menu: staleMenu)
        try require(copied == nil && !model.actionRunning, "A stale page menu acted on another row")
        guard let file = model.rows.first(where: { $0.title == "Selected.txt" }) else { throw StorageScanFailure.invalidOutput }
        // The table's coordinator receives row updates on the next native pass.
        try await wait("Native child page") { table.numberOfRows == model.rows.count }
        model.select(file.id); model.act(.properties)
        stage = "Properties"
        try await wait("Recorded Properties") { !model.actionRunning && !coordinator.hasWork && !browser.propertiesController.model.isLoading }
        try require(browser.propertiesController.model.urls == [root.appendingPathComponent("Folder/Selected.txt")], "Properties target changed")
        let fileURL = root.appendingPathComponent("Folder/Selected.txt")
        try await Task.detached(priority: .utility) { try FileManager.default.moveItem(at: fileURL, to: fileURL.deletingLastPathComponent().appendingPathComponent("Renamed.txt")) }.value
        copied = nil; model.act(.copyPath)
        stage = "changed source"
        try await wait("Changed source refusal") { !model.actionRunning && !coordinator.hasWork }
        try require(copied == nil && model.actionMessage.contains("changed") && coordinator.pagedResultForVerification?.id == id,
            "Missing source produced a path or invalidated the sealed catalog")
        try require(accesses == 5, "Location checks did not acquire exactly one fresh access per explicit action")
        try await wait("No prior location readers") { result?.activeReaderCount == 0 && accessTracker.count == 0 }
        try result?.installLocationHookForQualification { try hold.pause() }
        stage = "held cancellation"
        model.select(file.id); model.act(.copyPath)
        try await wait("Native metadata check held") { hold.entered }
        try require(coordinator.hasWork && result?.activeReaderCount == 1 && accessTracker.count == 1
            && ApplicationFileActivity.gate.activeCount > 0, "Location work released access/activity before completion")
        model.up()
        var drained = false
        let drain = Task { @MainActor in await coordinator.stopAndDrain(); drained = true }
        try await Task.sleep(for: .milliseconds(30))
        try require(!drained && coordinator.hasWork && accessTracker.count == 1, "Cancellation mistook a held native read for drained work")
        hold.release(); await drain.value
        try await wait("Cancelled location drains") { !coordinator.hasWork && !model.loading && result?.activeReaderCount == 0 && accessTracker.count == 0 }
        try require(copied == nil && model.actionMessage.isEmpty && model.selectedID == nil, "Cancelled row work published into another page")
        let store = storage.directory.appendingPathComponent("session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        stage = "close and disposal"
        tool.close(); await coordinator.stopAndDrain(); await result?.waitUntilReadersDrained()
        browser.propertiesController.cancel(); browser.propertiesController.close()
        browser.cancelDirectoryObservation()
        try await wait("Selected-location activity drain") { ApplicationFileActivity.gate.activeCount == 0 }
        try require(!coordinator.hasWork && result?.activeReaderCount == 0 && ApplicationFileActivity.gate.activeCount == 0,
            "Closing selected-item analysis retained work: coordinator=\(coordinator.hasWork), readers=\(result?.activeReaderCount ?? -1), gate=\(ApplicationFileActivity.gate.activeCount)")
        result = nil
        let disposed = await Task.detached(priority: .utility) {
            for _ in 0..<200 {
                if !FileManager.default.fileExists(atPath: store.path) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }.value
        try require(disposed, "Owned temporary location catalog was retained after readers drained")
        finished = true
        return ["passed": true, "checks": ["origin-bound native menu", "fresh metadata ancestry", "Copy Path without clipboard mutation in test", "Explorer selected tab", "Properties target", "stale page refusal", "source-change refusal", "page cancellation", "actual reader/access drain", "owned store disposal"],
            "source_body_reads": false, "file_mutations": "generated rename only", "ordinary_helper": ordinary, "activity_count": ApplicationFileActivity.gate.activeCount]
    }
}
#endif
