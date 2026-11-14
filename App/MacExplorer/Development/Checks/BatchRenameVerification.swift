#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations

@MainActor enum BatchRenameVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let packet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b09-batch-rename")
        let repo = packet.deletingLastPathComponent().deletingLastPathComponent()
        let ordinary = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: String])?["action"] == "batch-rename"
        try UIVerification.require((root.deletingLastPathComponent() == packet || ordinary)
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path)
            && (!ordinary || Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app")),
            "Batch Rename QA requires an admitted generated root")
        let parent = root.appendingPathComponent("source/Items"), args = ProcessInfo.processInfo.arguments
        let scale = args.contains("--batch-rename-scale"), drive = args.contains("--drive-batch-rename")
        browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        if args.contains("--large-interface") { browser.settings.interfaceSize = .init(150); browser.settings.appearance = .light; browser.settings.motion.mode = .reduced }
        // Verification sessions deliberately have no ordinary history engine.
        // Install only this admitted case's engine, including first-use state prep.
        let previousEngine = browser.recoverableFileOperations
        browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/operation-recovery"))
        if ordinary { browser.privateNames = ApplicationPrivateNames(directory: root.appendingPathComponent("state/names"), settings: browser.settings) }
        defer { browser.recoverableFileOperations = previousEngine }
        browser.navigate(to: .directory(parent))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.displayedEntries.count == (scale ? 512 : 3) }
        let sources = browser.displayedEntries.map(\.url)
        let hashes = try await digestFiles(parent)
        func open() async throws -> BatchRenameWindowController {
            browser.reloadFileRows(preserving: Set(sources))
            try UIVerification.require(browser.canBatchRename && browser.commandEnabled(#selector(BrowserViewController.batchRenameSelection(_:))), "Native batch Rename command did not bind the selected items")
            browser.batchRenameSelection(nil)
            guard let controller = ApplicationBatchRename.shared.controller else { throw UIVerification.Failure(message: "Batch Rename window missing") }
            try await wait { !controller.model.isPreparing }
            return controller
        }
        let cancelled = try await open()
        try UIVerification.require(cancelled.model.rows.count == sources.count && browser.operationCoordinator.preparationOwner == nil
            && browser.canPrepareTransferClipboard && !browser.hasPendingFileOperation, "An idle preview blocked ordinary file work or lost its selection")
        await ApplicationBatchRename.shared.closeAndDrain()
        let afterCancel = try await digestFiles(parent)
        try UIVerification.require(browser.operationCoordinator.preparationOwner == nil && afterCancel == hashes, "Cancel changed the generated selection or retained admission")
        let baseline = resident(), timer = Heartbeat(), started = ProcessInfo.processInfo.systemUptime
        timer.start()
        let controller = try await open(), model = controller.model
        controller.window?.title = "Generated batch Rename · " + root.lastPathComponent.prefix(8)
        if drive {
            try UIVerification.require(!browser.isControlledVerification && controller.window?.isVisible == true, "Batch input QA needs a visible generated window")
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.result != nil && !model.isRunning }
        } else {
            model.options.prefix = "New "
            try UIVerification.require(model.canApply && model.changes == sources.count, "Native Before/After preview did not update")
            if ordinary, !args.contains("--offscreen"), let window = controller.window {
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/local-batch-review.png"))
            }
            if !scale {
                let occupied = parent.appendingPathComponent("New " + namesForRetry(model))
                try await Task.detached { try Data("Generated occupied target".utf8).write(to: occupied, options: .withoutOverwriting) }.value
                model.apply()
                try await wait { !model.isRunning && browser.operationTask == nil }
                try UIVerification.require(model.result == nil && model.canApply && browser.view.window?.attachedSheet == nil,
                    "Preflight failure prevented an explicit edited retry or opened an automatic modal")
                try await Task.detached { try FileManager().moveItem(at: occupied, to: root.appendingPathComponent("evidence/retained-occupied-target")) }.value
                model.options.prefix = "Retry "
            }
            model.apply()
        }
        try await wait(seconds: 60) { !model.isRunning && model.result != nil && browser.operationTask == nil }
        let forward = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        guard let result = model.result else { throw UIVerification.Failure(message: "Native batch result missing") }
        try UIVerification.require(result.result.disposition == .succeeded && result.completedRecordIDs.count == sources.count, "Native batch did not retain every exact Rename record")
        try UIVerification.require(model.rows.allSatisfy { $0.status == "Renamed" } && model.canUndo, "Batch result actions were not available")
        if !drive {
            model.selection = [0]
            let expectedID = result.units[0].outcome.recordID
            try UIVerification.require(model.selectedRecordID == expectedID && model.canReview, "Selected batch result lost its exact history binding")
            model.reviewSelected()
            try await wait { browser.recoveryWindow?.selectedRecordID == expectedID }
            browser.recoveryWindow?.close(); model.selection = []
            if !browser.isControlledVerification { controller.window?.makeKeyAndOrderFront(nil) }
        }
        if let window = controller.window, !browser.isControlledVerification {
            try await Task.sleep(for: .milliseconds(300)); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/batch-native.png"))
        }
        let undoStart = ProcessInfo.processInfo.systemUptime
        if drive { try await wait(seconds: 90) { model.undoAttempted } }
        else { model.undoCompleted() }
        try await wait(seconds: 60) { !model.isRunning && model.undoResult != nil && browser.operationTask == nil }
        let reverse = (ProcessInfo.processInfo.systemUptime - undoStart) * 1_000
        try UIVerification.require(model.undoResult?.result.disposition == .succeeded && model.rows.allSatisfy { $0.status == "Restored" }, "Native Undo did not restore the complete generated batch")
        try UIVerification.require(try await digestFiles(parent) == hashes, "Generated payloads or names changed after batch Undo")
        await ApplicationBatchRename.shared.closeAndDrain()
        timer.stop()
        try await wait { browser.recoveryInspectionTask == nil || browser.operationCoordinator.inspectionCount == 0 }
        let p95 = timer.p95, worst = timer.worst, peak = peakResident(), added = peak > baseline ? peak - baseline : 0
        if ordinary { try await verifyZIPRename(root: root, browser: browser) }
        return ["passed": !scale || forward <= 30_000 && reverse <= 30_000 && p95 <= 40 && worst <= 250 && added <= 128 * 1_024 * 1_024,
            "items": sources.count, "physicalInput": drive, "forwardMilliseconds": forward, "undoMilliseconds": reverse,
            "heartbeatP95Milliseconds": p95, "heartbeatWorstMilliseconds": worst, "baselineRSS": baseline, "peakRSS": peak, "addedRSS": added,
            "sourceRestored": true, "cancelMadeNoChanges": true, "ordinaryActivation": BatchRenameActivation.enabled,
            "zipBatchUpdateAndUndo": ordinary,
            "notExercised": ["Minimum OS", "Disconnected device", "Case-sensitive APFS", "Network/provider files", "Personal files"]]
    }
    private static func verifyZIPRename(root: URL, browser: BrowserViewController) async throws {
        let source = root.appendingPathComponent("source/Batch Rename.zip")
        let original = try await Task.detached { try Data(contentsOf: source) }.value
        guard let engine = browser.recoverableFileOperations, let window = browser.view.window else {
            throw UIVerification.Failure(message: "ZIP batch engine/window missing")
        }
        let historyCount = try await engine.inspectExistingHistory().records.count
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
        browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.openSelection(nil)
        try await wait { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true && browser.currentArchive?.busy == false }
        guard let archive = browser.currentArchive, let table = archive.table, let model = archive.zipModelForVerification else {
            throw UIVerification.Failure(message: "Native ZIP batch browser missing")
        }
        if !ProcessInfo.processInfo.arguments.contains("--offscreen") {
            guard let row = model.visibleItems.firstIndex(where: { $0.name == "Top.txt" }),
                  let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else {
                throw UIVerification.Failure(message: "Selected ZIP name row missing")
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await wait { model.selection == [model.visibleItems[row].id] }
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
            table.scrollRowToVisible(row); table.layoutSubtreeIfNeeded()
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let label = cell.textField else { throw UIVerification.Failure(message: "Selected ZIP name label missing") }
            browser.settings.renamesSelectedNameOnClick = false
            try UIVerification.require(table.nameClickRenameEnabled?() == false, "ZIP selected-name preference ignored")
            browser.settings.renamesSelectedNameOnClick = true
            try UIVerification.require(table.nameClickRenameEnabled?() == true, "ZIP selected-name Rename not admitted")
            let point = label.convert(NSPoint(x: 8, y: label.bounds.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                throw UIVerification.Failure(message: "Selected ZIP name input missing")
            }
            NSApp.postEvent(up, atStart: true); table.mouseDown(with: down)
            try await wait { ApplicationArchiveCreation.shared.controller?.model.isMemberRename == true
                && ApplicationArchiveCreation.shared.controller?.model.isPreparing == false }
            try UIVerification.require(ApplicationArchiveCreation.shared.controller?.model.memberName == "Top.txt",
                "Selected ZIP name did not reach the existing Rename review")
            await ApplicationArchiveCreation.shared.closeAndDrain()
        }
        let selected = IndexSet(model.visibleItems.indices.filter { ["Folder", "Top.txt"].contains(model.visibleItems[$0].name) })
        try UIVerification.require(selected.count == 2, "ZIP batch fixture selection")
        table.selectRowIndexes(selected, byExtendingSelection: false)
        try await wait { model.selection.count == 2 }
        func open() async throws -> ArchiveCreationWindowController {
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
            try UIVerification.require(browser.commandEnabled(#selector(BrowserViewController.renameSelection(_:))), "ZIP batch native Rename command")
            browser.renameSelection(nil)
            try await wait { ApplicationArchiveCreation.shared.controller?.model.isMemberBatchRename == true
                && ApplicationArchiveCreation.shared.controller?.model.isPreparing == false }
            guard let review = ApplicationArchiveCreation.shared.controller else { throw UIVerification.Failure(message: "ZIP batch review missing") }
            try UIVerification.require(review.model.updatesOriginal && review.model.batchNames.count == 2
                && !review.model.canCreate, "Unchanged ZIP batch must not enable Rename")
            return review
        }
        var review = try await open()
        review.model.batchOptions = .init(mode: .replace, find: "Folder", replacement: "Occupied")
        try await wait { !review.model.isPreparing && !review.model.previewIsPendingForVerification }
        try UIVerification.require(!review.model.canCreate && review.model.notice.contains("conflicts"),
            "ZIP batch implied-folder collision was not refused: " + review.model.notice)
        await ApplicationArchiveCreation.shared.closeAndDrain()
        let unchanged = try await Task.detached { try Data(contentsOf: source) }.value
        let afterCancel = try await engine.inspectExistingHistory()
        try UIVerification.require(unchanged == original && afterCancel.records.count == historyCount,
            "ZIP batch Cancel changed the archive/history")
        review = try await open()
        review.model.batchOptions = .init(mode: .number, base: "Item", start: 7, digits: 2)
        try await wait { review.model.canCreate }
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), let native = review.window {
            native.makeKeyAndOrderFront(nil)
            try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/zip-batch-numbering.png"))
        }
        review.model.batchOptions = .init(prefix: "Reviewed ")
        try await wait { review.model.canCreate }
        try UIVerification.require(review.model.batchRows.allSatisfy { $0.after.hasPrefix("Reviewed ") }, "ZIP batch names not shown before Save")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), let native = review.window {
            try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/zip-batch-review.png"))
        }
        review.model.create()
        try await wait { !review.model.isRunning && review.model.outcome != nil && browser.operationTask == nil }
        try UIVerification.require(review.model.outcome?.result.disposition == .succeeded, "ZIP batch Update failed")
        try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy }
        try UIVerification.require(Set(model.visibleItems.map(\.name)) == ["Reviewed Folder", "Reviewed Top.txt", "Occupied"],
            "ZIP batch live rows were not refreshed")
        try await Task.detached {
            try Data(contentsOf: source).write(to: root.appendingPathComponent("evidence/Batch Edited.zip"), options: .withoutOverwriting)
        }.value
        let history = try await engine.inspectExistingHistory()
        try UIVerification.require(history.records.count == historyCount + 1 && review.model.canUndo,
            "ZIP batch is not one recoverable update")
        review.model.undo()
        try await wait { !review.model.isRunning && review.model.undoOutcome != nil && browser.operationTask == nil }
        try UIVerification.require(review.model.undoOutcome?.result.disposition == .succeeded, "ZIP batch Undo failed")
        let restored = try await Task.detached { try Data(contentsOf: source) }.value
        try UIVerification.require(restored == original, "ZIP batch Undo did not restore exact original bytes")
        await ApplicationArchiveCreation.shared.closeAndDrain()
    }

    private static func namesForRetry(_ model: BatchRenameModel) -> String { model.names[0].name }
    private static func digestFiles(_ parent: URL) async throws -> [String: String] {
        try await Task.detached {
            var result: [String: String] = [:], pending = [parent]
            while let folder = pending.popLast() {
                for url in try FileManager().contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                    let facts = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if facts.isDirectory == true { pending.append(url) }
                    else if facts.isRegularFile == true {
                        result[String(url.path.dropFirst(parent.path.count))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                    } else { throw FileOperationFailure.invalidRequest }
                }
            }
            return result
        }.value
    }
    private static func wait(seconds: Double = 20, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native batch Rename did not settle")
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var values: [Double] = []
        func start() {
            task = Task { [weak self] in
                var previous = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard let self, !Task.isCancelled else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if values.count < 4_096 { values.append((now - previous) * 1_000) }
                    previous = now
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
        var p95: Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { values.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
