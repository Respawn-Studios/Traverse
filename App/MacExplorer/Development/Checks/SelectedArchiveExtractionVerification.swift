#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileOperations
import LocalStorage

@MainActor enum SelectedArchiveExtractionVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try UIVerification.require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-selected-extraction")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Selected extraction QA needs its admitted generated root")
        let source = root.appendingPathComponent("source/Generated.zip"), drive = ProcessInfo.processInfo.arguments.contains("--drive-selected-extraction")
        let expectedBytes = try await Task.detached {
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/source.json"))) as? [String: Any]
            return (manifest?["logicalBytes"] as? NSNumber)?.uint64Value ?? 0
        }.value
        browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/operation-recovery"))
        browser.permitsBackgroundVerification = true; browser.settings.autoRefreshFolders = false
        browser.settings.reviewsRecoveryAtStartup = false; browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        func openArchive() async throws -> ArchiveBrowserModel {
            ApplicationZIPBrowser.shared.show(source, from: browser)
            guard let model = ApplicationZIPBrowser.shared.controller?.model else { throw UIVerification.Failure(message: "Archive browser missing") }
            try await wait { !model.isLoading && !model.isPaging && model.page != nil }
            return model
        }
        func choose(_ model: ArchiveBrowserModel) throws {
            guard let item = model.page?.items.first(where: { $0.path == "Selected" }) else { throw UIVerification.Failure(message: "Selected root missing") }
            model.selection = [item.id]
            try UIVerification.require(model.canExtractSelected, "Archive selected-extraction command unavailable")
        }
        func preview(_ model: ArchiveBrowserModel) async throws -> ArchiveExtractionWindowController {
            try choose(model); model.extractSelected()
            try await wait { !model.isPreparingSelection && ApplicationArchiveExtraction.shared.controller != nil }
            guard let controller = ApplicationArchiveExtraction.shared.controller else { throw UIVerification.Failure(message: "Selected extraction workbench missing") }
            try await wait { !controller.model.isPreparing && controller.model.plan != nil }
            return controller
        }
        var archive = try await openArchive()
        let cancelled = try await preview(archive)
        try UIVerification.require(cancelled.model.members?.count == 1 && cancelled.model.plan?.files == 2
            && cancelled.model.plan?.folders == 3 && cancelled.model.plan?.logicalBytes == expectedBytes
            && browser.operationCoordinator.preparationOwner == nil, "Selection preview totals or idle admission changed")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        try UIVerification.require(!FileManager().fileExists(atPath: root.appendingPathComponent("state/operation-recovery").path), "Cancelling selected preview wrote history")
        if !drive {
            try choose(archive); archive.extractSelected()
            if let folder = archive.page?.items.first(where: { $0.path == "Selected" })?.folder { archive.navigate(folder) }
            try await wait { !archive.isPreparingSelection && !archive.isPaging }
            try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil, "Stale selection opened after archive navigation")
            await ApplicationZIPBrowser.shared.stopAndDrain()
            archive = try await openArchive()
            try choose(archive); archive.extractSelected(); await ApplicationZIPBrowser.shared.stopAndDrain()
            try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil, "Closed archive opened a late extraction workbench")
            archive = try await openArchive()
        }
        let controller: ArchiveExtractionWindowController
        if drive {
            try choose(archive)
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/archive-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { ApplicationArchiveExtraction.shared.controller != nil }
            guard let visible = ApplicationArchiveExtraction.shared.controller else { throw UIVerification.Failure(message: "Selected workbench not opened by native input") }
            controller = visible; try await wait { controller.model.plan != nil && !controller.model.isPreparing }
        } else { controller = try await preview(archive) }
        let model = controller.model
        guard let plan = model.plan else { throw UIVerification.Failure(message: "Selected extraction preview missing") }
        try UIVerification.require(model.members?.displayNames == ["Selected"] && plan.files == 2 && plan.folders == 3
            && plan.logicalBytes == expectedBytes && (controller.window?.contentLayoutRect.height ?? 0) >= 460, "Selection workbench scope or geometry changed")
        let baseline = resident(), timer = Heartbeat(); timer.start()
        let began = ProcessInfo.processInfo.systemUptime
        if drive {
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.outcome != nil && !model.isRunning }
        } else { model.extract() }
        try await wait { model.outcome != nil && !model.isRunning && browser.operationTask == nil }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        try await Task.sleep(for: .milliseconds(100)); timer.stop()
        guard let outcome = model.outcome, let id = outcome.recordID else { throw UIVerification.Failure(message: "Selected extraction result missing") }
        try UIVerification.require(outcome.result.disposition == .succeeded && model.canUndo && browser.view.window?.attachedSheet == nil,
            "Selected extraction did not complete quietly with exact Undo")
        let hashes = try await outputHashes(plan.destination)
        try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys]).write(to: root.appendingPathComponent("evidence/output.json"), options: .withoutOverwriting)
        try UIVerification.require(hashes.count == 2 && hashes.keys.allSatisfy { $0.hasPrefix("Selected/") }
            && FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Selected/Empty").path)
            && !FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Unselected.bin").path), "Selected extraction included an unselected payload")
        model.viewResults(); try await wait { browser.recoveryWindow?.selectedRecordID == id }; browser.recoveryWindow?.close()
        if let window = controller.window, !browser.isControlledVerification {
            window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/selected-native.png"))
        }
        if drive {
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/undo-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.undoAttemptedForVerification }
        } else { model.undo() }
        try await wait { model.undoOutcome != nil && !model.isRunning && browser.operationTask == nil }
        try UIVerification.require(model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath: plan.destination.path), "Exact selected-extraction Undo failed")
        await ApplicationArchiveExtraction.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        let added = peak() > baseline ? peak() - baseline : 0
        return ["passed": drive || elapsed <= 10_000 && added <= 96 * 1_024 * 1_024 && timer.p95 <= 40 && timer.worst <= 250,
            "physicalInput": drive, "forwardMilliseconds": elapsed, "addedRSS": added, "heartbeatSamples": timer.count,
            "heartbeatP95Milliseconds": timer.p95, "heartbeatWorstMilliseconds": timer.worst, "logicalBytes": expectedBytes,
            "selectedRoots": 1, "files": 2, "folders": 3, "exactUndo": true, "quietResults": true,
            "staleNavigationAndCloseChecked": !drive, "ordinaryActivation": SelectedArchiveExtractionActivation.available,
            "notExercised": ["Personal archive", "Other devices/providers", "Minimum OS", "Physical power loss"]]
    }
    private static func outputHashes(_ root: URL) async throws -> [String: String] {
        try await Task.detached {
            var result: [String: String] = [:], pending = [root]
            while let directory = pending.popLast() {
                for url in try FileManager().contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { pending.append(url) }
                    else { result[String(url.path.dropFirst(root.path.count + 1))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
                }
            }
            return result
        }.value
    }
    private static func wait(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(8)) }
        try UIVerification.require(condition(), "Selected extraction workflow did not settle")
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?, intervals: [Double] = []
        func start() { task = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20)); guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if intervals.count < 4_096 { intervals.append((now - previous) * 1_000) }; previous = now
            }
        } }
        func stop() { task?.cancel(); task = nil }
        var count: Int { intervals.count }
        var p95: Double { let sorted = intervals.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { intervals.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var value = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? value.resident_size : 0
    }
    private static func peak() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
