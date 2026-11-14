#if DEBUG
import AppKit
import FileOperations
import StorageAnalysis

@MainActor enum StorageSelectedTrashVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < until else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run(root: URL, browser: BrowserViewController, coordinator: ApplicationStorageAnalysis,
                    result: StorageAnalysisResult, model: PagedAnalysisBrowserModel,
                    folder: StoredAnalysisRow, evidenceDirectory: URL) async throws -> [String: Any] {
        // The caller admits exactly the generated location-fixture-* root.
        let state = root.appendingPathComponent("PrivateState")
        let history = state.appendingPathComponent("operation-recovery")
        guard let engine = browser.operationCoordinator.nativeAnalyzerEngineForVerification(at: history) else {
            throw UIVerification.Failure(message: "Selected native Trash requires a fresh coordinator-owned engine")
        }
        let previousEngine = browser.recoverableFileOperations, previousPrompt = browser.operationTrashPrompt
        browser.recoverableFileOperations = engine
        defer { browser.recoverableFileOperations = previousEngine; browser.operationTrashPrompt = previousPrompt }
        var checks: [String] = []
        let recordedIDs = model.rows.map(\.id)
        var layout: [String: Double] = [:]
        var finished = false
        defer {
            if !finished {
                print("MAC_EXPLORER_SELECTED_DIAGNOSTIC " + checks.joined(separator: ",") + " layout=" + String(describing: layout)
                    + " readers=" + String(result.activeReaderCount))
                fflush(stdout)
            }
        }
        func measure(_ phase: String) async throws {
            try await Task.sleep(for: .milliseconds(40))
            coordinator.toolWindow?.window?.contentView?.layoutSubtreeIfNeeded()
            guard let table = StoredAnalysisTableProbe.latest, let scroll = table.enclosingScrollView,
                  table.window === coordinator.toolWindow?.window else {
                throw UIVerification.Failure(message: "Selected-item table layout probe unavailable")
            }
            layout[phase] = scroll.contentView.bounds.height
        }
        try await measure("before")
        let launches = result.queryWorkerLaunchCountForQualification
        let lease = try await result.suspendReaders()
        do {
            _ = try await result.page()
            throw UIVerification.Failure(message: "A suspended cached page admitted work")
        } catch StorageScanFailure.busy {}
        try require(result.activeReaderCount == 0 && result.queryWorkerLaunchCountForQualification == launches,
                    "Suspended result started a worker")
        lease.release(); lease.release()
        _ = try await result.summary()
        checks += ["closed reader admission", "cached page cannot bypass suspension", "idempotent reader release"]
        try await wait("Initial chart/table reads did not drain") {
            result.activeReaderCount == 0 && !model.loading && coordinator.toolWindow?.chartDrillForVerification.loading != true
        }
        let hold = SelectedTrashReaderHold()
        defer { hold.release() }
        try result.installLocationHookForQualification { try hold.pause() }
        let read = Task { try await result.resolveLocation(node: folder.id, retainingAccess: root) }
        try await wait("Held metadata reader did not enter") { hold.entered }
        var suspended = false
        let pause = Task { let value = try await result.suspendReaders(); suspended = true; return value }
        try await Task.sleep(for: .milliseconds(25))
        pause.cancel()
        try require(!suspended && result.activeReaderCount == 1 && ApplicationFileActivity.gate.activeCount > 0,
                    "Cancelled suspension released a real reader early")
        hold.release()
        let heldLease = try await pause.value
        do { _ = try await read.value; throw UIVerification.Failure(message: "Cancelled metadata read returned a location") }
        catch is CancellationError {}
        heldLease.release()
        try result.installLocationHookForQualification(nil)
        try require(suspended && result.activeReaderCount == 0, "Suspension failed to drain the native reader")
        checks += ["held native metadata reader drains", "cancelled suspension retains actual activity"]
        var confirmations = 0, replacedScope = false, deniedReader = false, exactCount = true
        browser.operationTrashPrompt = { count in
            confirmations += 1
            exactCount = exactCount && count == 1
            do { _ = try await result.summary() } catch StorageScanFailure.busy { deniedReader = true } catch {}
            coordinator.analyzeProperties(owner: UUID(), root: root, access: {
                replacedScope = true; return FileAccessLifetimes(leases: [])
            }, onChange: { _, _ in })
            return false
        }
        model.select(folder.id); model.act(.reviewTrash)
        try await wait("Cancel review did not drain") { !model.actionRunning && !coordinator.hasWork }
        try require(confirmations == 1 && exactCount && deniedReader && !replacedScope && coordinator.pagedResultForVerification?.id == result.id,
                    "Review lost its single-selection/suspension/source scope")
        try require(model.actionMessage.contains("Cancelled") && !FileManager().fileExists(atPath: state.path),
                    "Cancel created state/history or changed its result")
        try require(coordinator.toolWindow?.statusLabel.stringValue == "Recorded analysis · selected-item review finished",
                    "Cancel claimed a confirmed file change")
        try require(FileManager().fileExists(atPath: root.appendingPathComponent("Folder/Selected.txt").path), "Cancel changed a source")
        _ = try await result.summary()
        checks += ["one exact-item review", "new scan refused during review", "reader held through review", "Cancel creates no state/history", "recorded result retained"]
        browser.operationTrashPrompt = { count in confirmations += 1; return count == 1 }
        model.act(.reviewTrash)
        try await wait("Native selected Trash did not finish") {
            !model.actionRunning && !coordinator.hasWork && browser.operationTask == nil && browser.operationCoordinator.inspectionCount == 0
        }
        try require(confirmations == 2 && browser.lastOperationResult?.disposition == .succeeded,
                    "Selected native Trash was not verified")
        try require(!FileManager().fileExists(atPath: root.appendingPathComponent("Folder").path)
                    && model.actionMessage.contains("Refresh"), "Selected source/result stale state is wrong")
        try await wait("Confirmed Trash row remained visible") {
            model.rows.map(\.id) == recordedIDs.filter { $0 != folder.id } && model.selectedID == nil
                && StoredAnalysisTableProbe.latest?.numberOfRows == 1
        }
        let queryCount = result.queryWorkerLaunchCountForQualification
        model.changeSort(.nameAscending)
        try await wait("Recorded sort resurrected a confirmed Trash row") { !model.loading && model.rows.count == 1 && model.rows.first?.id != folder.id }
        model.changeSort(.logicalDescending)
        try await wait("Recorded re-sort did not settle") { !model.loading && model.rows.count == 1 }
        try require(result.queryWorkerLaunchCountForQualification <= queryCount + 2, "Known-row presentation launched extra queries")
        checks += ["verified removal hides its exact row", "recorded sorting retains known removal"]
        guard let id = browser.lastRecoveryRecordID,
              let record = browser.recoveryRecords.first(where: { $0.id == id }), record.canUndo else {
            throw UIVerification.Failure(message: "Selected Trash lost ordinary guarded Undo")
        }
        try require(record.nativeDirectoryTrashContract, "Selected folder Trash did not use the native v12 contract")
        checks += ["native Trash returned location recorded", "existing recovery record", "stale scan labelled", "no automatic rescan"]
        guard let feedback = model.operationFeedback, feedback.id == id else { throw UIVerification.Failure(message: "Missing exact-operation outcome card") }
        try await wait("Outcome card did not become available") { feedback.canUndo && feedback.canViewResults }
        try await measure("afterTrash")
        browser.beginFileOperation(.createFolder(parent: root, name: "Newer operation"), title: "Creating generated comparison folder…", roots: [root])
        try await wait("Newer generated operation did not finish") { browser.operationTask == nil && browser.operationCoordinator.inspectionCount == 0 }
        try require(browser.lastRecoveryRecordID != id && FileManager().fileExists(atPath: root.appendingPathComponent("Newer operation").path),
                    "No independent newer operation for exact-record test")
        try await wait("Outcome did not recover after another operation") { feedback.canUndo && feedback.canViewResults }
        feedback.viewResults()
        try await wait("View Results selected another operation") { browser.recoveryWindow?.selectedRecordID == id && browser.operationCoordinator.inspectionCount == 0 }
        browser.recoveryWindow?.close()
        coordinator.toolWindow?.window?.makeKeyAndOrderFront(nil)
        try await wait("Outcome Undo unavailable") { feedback.canUndo }
        guard let other = model.rows.first(where: { $0.title == "Other.txt" }) else { throw StorageScanFailure.invalidOutput }
        model.select(other.id); model.act(.reviewTrash)
        try await wait("Second selected Trash did not finish") {
            !model.actionRunning && !coordinator.hasWork && browser.operationTask == nil && browser.operationCoordinator.inspectionCount == 0
        }
        guard let secondFeedback = model.operationFeedback, secondFeedback.id != id else { throw UIVerification.Failure(message: "Second outcome did not retain its own operation") }
        try require(browser.recoveryRecords.first(where: { $0.id == secondFeedback.id })?.nativeRegularFileTrashContract == true,
                    "Selected file Trash did not use the native v11 contract")
        try await wait("Second row did not disappear") { model.rows.isEmpty && StoredAnalysisTableProbe.latest?.numberOfRows == 0 }
        feedback.undo()
        try require(browser.operationTask == nil, "Replaced outcome started an old Undo")
        try require(browser.beginAnalysisUndo(recordID: id, engine: engine, roots: record.locations, completion: { _ in }), "Independent earlier Undo refused")
        try await wait("Known earlier Undo did not restore its row") {
            browser.operationTask == nil && browser.operationCoordinator.inspectionCount == 0
                && model.rows.map(\.id) == [folder.id] && !secondFeedback.working
        }
        try await wait("Newest outcome Undo unavailable") { secondFeedback.canUndo }
        let undoQueries = result.queryWorkerLaunchCountForQualification
        secondFeedback.undo()
        try await wait("In-analyzer Undo did not finish") { !secondFeedback.working && browser.operationTask == nil && browser.operationCoordinator.inspectionCount == 0 }
        try await wait("Undo did not restore recorded rows") { model.rows.map(\.id) == recordedIDs && StoredAnalysisTableProbe.latest?.numberOfRows == recordedIDs.count }
        try require(result.queryWorkerLaunchCountForQualification == undoQueries, "Undo row restoration rescanned or queried the catalog")
        try require(browser.lastOperationResult?.disposition == .succeeded
            && FileManager().fileExists(atPath: root.appendingPathComponent("Folder/Selected.txt").path)
            && FileManager().fileExists(atPath: root.appendingPathComponent("Newer operation").path)
            && !secondFeedback.canUndo && secondFeedback.message.contains("Undo completed"),
            "In-analyzer Undo did not restore its exact selected folder")
        try require(result.activeReaderCount == 0 && browser.operationCoordinator.activeOwner == nil
            && browser.operationCoordinator.preparationOwner == nil, "Selected cleanup released or leaked command ownership")
        try await measure("afterUndo")
        let originalSize = coordinator.toolWindow?.window?.contentView?.bounds.size
        coordinator.toolWindow?.window?.setContentSize(.init(width: 740, height: 480))
        try await measure("compactAfterUndo")
        if let originalSize { coordinator.toolWindow?.window?.setContentSize(originalSize) }
        print("MAC_EXPLORER_SELECTED_LAYOUT " + String(decoding: try JSONSerialization.data(withJSONObject: layout, options: .sortedKeys), as: UTF8.self))
        fflush(stdout)
        try require((layout["afterTrash"] ?? 0) >= 100 && (layout["afterUndo"] ?? 0) >= 100
            && (layout["compactAfterUndo"] ?? 0) >= 75, "Selected-item outcome collapsed the native table viewport")
        checks.append("usable table after Trash/Undo and compact resizing")
        checks += ["in-analyzer exact-operation Undo", "View Results keeps exact history selection", "newer operation not substituted", "Undo ends its action", "actual reader/command drain"]
        checks += ["multiple known removals persist", "observed earlier Undo restores only its own row", "current Undo restores row without a scan/query"]
        let capture = evidenceDirectory.appendingPathComponent("selected-cleanup-layout-" + UUID().uuidString + ".png")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: evidenceDirectory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }.value
        try await Task.sleep(for: .milliseconds(40))
        if let window = coordinator.toolWindow?.window { try await UIVerification.snapshot(window, to: capture) }
        secondFeedback.close()
        secondFeedback.undo()
        try require(browser.operationTask == nil, "A stale outcome card started Undo")
        checks.append("closed outcome cannot start work")
        finished = true
        return ["passed": true, "checks": checks, "native_trash_contracts": ["file-v11", "folder-v12"],
                "source_mutations": "generated selected folder and file Trash/Undo, plus one independent generated folder creation",
                "content_indexing": false, "confirmation_count": confirmations, "persistent_analysis_created": false,
                "table_viewport_points": layout, "capture": capture.lastPathComponent]
    }
}

private final class SelectedTrashReaderHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func pause() throws {
        condition.lock(); defer { condition.unlock() }; started = true
        while !released {
            guard condition.wait(until: Date().addingTimeInterval(5)) else { throw StorageScanFailure.unavailable }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
#endif
