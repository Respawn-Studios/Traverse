#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations

@MainActor enum DuplicateVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try UIVerification.require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-duplicate")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Duplicate QA requires its admitted generated root")
        let args = ProcessInfo.processInfo.arguments, scale = args.contains("--duplicate-scale"), drive = args.contains("--drive-duplicate")
        let parent = root.appendingPathComponent("source/Items"), engine = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/operation-recovery"))
        browser.recoverableFileOperations = engine; browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        browser.transferPasteboard = board; board.setString("generated clipboard sentinel", forType: .string)
        let clipboardGeneration = board.changeCount
        var promptCount = 0
        browser.transferConflictPrompt = { _ in promptCount += 1; return nil }
        browser.transferMetadataPrompt = { _ in promptCount += 1; return nil }
        defer { browser.transferConflictPrompt = nil; browser.transferMetadataPrompt = nil }
        browser.navigate(to: .directory(parent))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.displayedEntries.count == (scale ? 128 : 3) }
        let sources = browser.displayedEntries.map(\.url), original = try await hashes(parent)
        browser.reloadFileRows(preserving: Set(sources)); browser.focusBrowserContent()
        let queue = browser.operationCoordinator.transfers
        let rejectedMove = try await engine.prepareTransfer(sources: [sources[0]], destinationDirectory: root.appendingPathComponent("source"), move: true)
        do { _ = try DuplicateChoices.resolutions(for: rejectedMove); throw UIVerification.Failure(message: "Duplicate accepted a general Move plan") }
        catch FileOperationFailure.invalidRequest {}
        let baseline = resident(), heartbeat = Heartbeat(); heartbeat.start()
        let start = ProcessInfo.processInfo.systemUptime
        if drive {
            try UIVerification.require(!browser.isControlledVerification, "Duplicate physical-input QA needs the generated visible window")
            browser.view.window?.title = "Generated Duplicate · " + root.lastPathComponent.prefix(8)
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
        } else { browser.duplicateSelection(nil) }
        try await wait(seconds: drive ? 90 : 30) { !queue.hasOutstandingWork && !queue.results.isEmpty }
        let forward = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        guard let first = queue.results.last, let firstID = first.outcome.recordID else { throw UIVerification.Failure(message: "Duplicate result missing") }
        try UIVerification.require(first.outcome.result.disposition == .succeeded && first.outcome.result.items.count == sources.count
            && promptCount == 0 && browser.view.window?.attachedSheet == nil, "Duplicate failed or opened an unnecessary choice")
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.canUndoFileOperation }
        let destinations = Set(first.outcome.result.items.compactMap(\.destination))
        try UIVerification.require(Set(destinations.map(\.path)) == Set(browser.selectedURLs.map(\.path)) && sources.allSatisfy { !destinations.contains($0) }, "Duplicate did not select the new objects: expected \(destinations.map(\.lastPathComponent)), observed \(browser.selectedURLs.map(\.lastPathComponent))")
        let forwardHashes = try await hashes(parent)
        for source in sources {
            let destination = try unwrap(first.outcome.result.items.first { $0.source == source }?.destination, "Duplicate source mapping missing")
            for (name, digest) in original where name == source.lastPathComponent || name.hasPrefix(source.lastPathComponent + "/") {
                let mapped = destination.lastPathComponent + name.dropFirst(source.lastPathComponent.count)
                try UIVerification.require(forwardHashes[mapped] == digest, "Duplicate content differed from source")
            }
        }
        if !browser.isControlledVerification {
            try await GlassVerification.captureOwnedWindow(browser.view.window!, to: root.appendingPathComponent("evidence/duplicate-native.png"))
        }
        let undoStart = ProcessInfo.processInfo.systemUptime
        if drive {
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/undo-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { browser.operationTask != nil || browser.recoveryRecords.contains { $0.id == firstID && $0.state == "undone" } }
        } else { browser.undoFileOperation(nil) }
        try await wait(seconds: 30) { browser.operationTask == nil && browser.recoveryRecords.contains { $0.id == firstID && $0.state == "undone" } }
        let reverse = (ProcessInfo.processInfo.systemUptime - undoStart) * 1_000
        try UIVerification.require(try await hashes(parent) == original, "Duplicate Undo changed originals or left published copies")
        if !scale && !drive {
            // A retained Settings window must not cause a stale origin or require
            // a conflict sheet. Admission uses the active browser's file context.
            browser.showSettings(nil); browser.view.window?.makeKeyAndOrderFront(nil); browser.focusBrowserContent()
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            browser.reloadFileRows(preserving: Set(sources)); browser.duplicateSelection(nil)
            try await wait { !queue.hasOutstandingWork && queue.results.count == 2 }
            try UIVerification.require(queue.results.last?.outcome.result.disposition == .succeeded, "Duplicate with a retained tool window failed")
            browser.settingsWindow?.close()
            let secondID = try unwrap(queue.results.last?.outcome.recordID, "Second Duplicate record missing")
            try UIVerification.require(await engine.undo(recordID: secondID).result.disposition == .succeeded, "Second Duplicate Undo failed")
            try UIVerification.require(try await hashes(parent) == original, "Repeated Duplicate altered original content")
        }
        heartbeat.stop()
        try await wait { queue.isIdleForCopyPreview && browser.operationCoordinator.inspectionCount == 0 }
        try UIVerification.require(board.changeCount == clipboardGeneration && board.string(forType: .string) == "generated clipboard sentinel"
            && promptCount == 0, "Duplicate changed the clipboard or asked for conflict choices")
        let added = peak() > baseline ? peak() - baseline : 0
        return ["passed": !scale || forward <= 20_000 && reverse <= 20_000 && added <= 96 * 1_024 * 1_024 && heartbeat.p95 <= 40 && heartbeat.worst <= 250,
            "items": sources.count, "physicalInput": drive, "forwardMilliseconds": forward, "undoMilliseconds": reverse,
            "addedRSS": added, "heartbeatP95Milliseconds": heartbeat.p95, "heartbeatWorstMilliseconds": heartbeat.worst,
            "clipboardUnchanged": true, "sourceRestored": true, "quietResults": true, "ordinaryActivation": DuplicateActivation.enabled,
            "notExercised": ["Minimum OS", "Other devices/providers", "Personal files", "Physical power loss"]]
    }
    private static func hashes(_ parent: URL) async throws -> [String: String] {
        try await Task.detached {
            var result: [String: String] = [:], pending = [parent]
            while let folder = pending.popLast() {
                for url in try FileManager().contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                    if folder == parent && url.lastPathComponent.hasPrefix(".mac-explorer-recovery-") { continue }
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { pending.append(url) }
                    else { result[String(url.path.dropFirst(parent.path.count + 1))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
                }
            }
            return result
        }.value
    }
    private static func wait(seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native Duplicate workflow did not settle")
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw UIVerification.Failure(message: message) }; return value
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?, values: [Double] = []
        func start() { task = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20)); guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if values.count < 4_096 { values.append((now - previous) * 1_000) }; previous = now
            }
        } }
        func stop() { task?.cancel(); task = nil }
        var p95: Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { values.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func peak() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
