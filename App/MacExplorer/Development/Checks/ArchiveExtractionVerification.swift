#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileOperations
import LocalStorage

@MainActor enum ArchiveExtractionVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b09-extraction")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Extraction QA requires its admitted generated root")
        let args = ProcessInfo.processInfo.arguments, scale = args.contains("--zip-extraction-scale"), drive = args.contains("--drive-zip-extraction")
        let source = root.appendingPathComponent("source/Generated.zip"), before = try await hash(source)
        let quarantined = args.contains("--zip-extraction-quarantine")
        let sourceSecurity = quarantined ? try await quarantine(source) : nil
        browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        let previous = browser.recoverableFileOperations
        let engine = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/operation-recovery"))
        browser.recoverableFileOperations = engine; defer { browser.recoverableFileOperations = previous }
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
        func open() async throws -> ArchiveExtractionWindowController {
            browser.reloadFileRows(preserving: [source])
            try UIVerification.require(browser.canExtractArchive && browser.commandEnabled(#selector(BrowserViewController.extractArchive(_:))), "Native extraction selection is not eligible")
            browser.extractArchive(nil)
            guard let controller = ApplicationArchiveExtraction.shared.controller else { throw UIVerification.Failure(message: "Extraction review missing") }
            try await wait { !controller.model.isPreparing && controller.model.plan != nil }
            return controller
        }
        let cancelled = try await open()
        try UIVerification.require(cancelled.model.canExtract && browser.operationCoordinator.preparationOwner == nil
            && browser.canPrepareTransferClipboard, "Idle extraction preview lost admission or blocked ordinary file work")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        let originalNames = try await Task.detached { try FileManager().contentsOfDirectory(atPath: source.deletingLastPathComponent().path) }.value
        try UIVerification.require(originalNames == ["Generated.zip"] && !FileManager().fileExists(atPath: root.appendingPathComponent("state/operation-recovery").path), "Cancelled preview created an output or operation history")
        let controller = try await open(), model = controller.model
        controller.window?.title = "Generated archive extraction · " + root.lastPathComponent.prefix(8)
        guard let plan = model.plan else { throw UIVerification.Failure(message: "Extraction preview missing") }
        try UIVerification.require((controller.window?.contentLayoutRect.height ?? 0) >= 440, "Extraction controls were compressed by the chrome fitting size")
        try UIVerification.require(plan.files == (scale ? 9 : 3) && plan.folders == 2
            && plan.logicalBytes == (scale ? 16 * 1_024 * 1_024 : 256 * 1_024), "Native extraction preview lost members or totals")
        let baseline = resident(), heartbeat = Heartbeat()
        heartbeat.start(); try await Task.sleep(for: .milliseconds(25))
        let began = ProcessInfo.processInfo.systemUptime
        if drive {
            try UIVerification.require(!browser.isControlledVerification && controller.window?.isVisible == true, "Input QA needs the visible generated extraction review")
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.outcome != nil && !model.isRunning }
        } else { model.extract() }
        try await wait { model.outcome != nil && !model.isRunning && browser.operationTask == nil }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        try await Task.sleep(for: .milliseconds(30)); heartbeat.stop()
        let forwardPeak = peakResident()
        guard let result = model.outcome, let id = result.recordID else { throw UIVerification.Failure(message: "Extracted result missing") }
        try UIVerification.require(result.result.disposition == .succeeded && model.canUndo && browser.view.window?.attachedSheet == nil,
            "Native extraction did not finish with quiet exact Undo")
        let tree = try await inventory(plan.destination)
        try UIVerification.require(tree.files == plan.files && tree.bytes == plan.logicalBytes, "Published tree differs from reviewed totals")
        let securedNodes: Int
        if let sourceSecurity { securedNodes = try await verifyQuarantineTree(plan.destination, expected:sourceSecurity) }
        else { securedNodes = 0 }
        try UIVerification.require(!quarantined || securedNodes == plan.files + plan.folders + 1,
            "Published native output lost source download-security information")
        model.viewResults()
        try await wait { browser.recoveryWindow?.selectedRecordID == id }
        browser.recoveryWindow?.close()
        if !browser.isControlledVerification { controller.window?.makeKeyAndOrderFront(nil) }
        if let window = controller.window, !browser.isControlledVerification {
            try await Task.sleep(for: .milliseconds(200)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/extraction-native.png"))
        }
        if drive {
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/undo-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.undoAttemptedForVerification }
        } else {
            model.openFolder()
            try await wait { browser.location.directoryURL == plan.destination && !browser.isLoading && browser.orderingTask == nil }
            model.undo()
        }
        try await wait { !model.isRunning && model.undoOutcome != nil && browser.operationTask == nil }
        try UIVerification.require(model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath: plan.destination.path), "Native extraction Undo failed")
        if !drive { try await wait { browser.location.directoryURL == source.deletingLastPathComponent() && !browser.isLoading } }
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        var stopDrain: Double = 0
        if !scale && !drive {
            let stopping = try await open(); stopping.model.extract()
            let start = ProcessInfo.processInfo.systemUptime
            stopping.model.stop(); await ApplicationArchiveExtraction.shared.closeAndDrain()
            stopDrain = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            try UIVerification.require(stopDrain <= 2_000 && browser.operationTask == nil
                && !FileManager().fileExists(atPath: plan.destination.path), "Native admission Stop did not drain or created output")
        }
        var closeDuringRun = false
        if !scale && !drive {
            let closing = try await open(); closing.model.extract()
            try UIVerification.require(closing.model.isRunning, "Close-during-extraction test was not admitted")
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            try UIVerification.require(closing.model.outcome?.result.disposition == .succeeded && browser.operationTask == nil,
                "Closing the workbench detached or cancelled an accepted extraction")
            let closedID = try requireID(closing.model.outcome)
            let undo = await engine.undo(recordID: closedID)
            try UIVerification.require(undo.result.disposition == .succeeded, "Generated closed-window extraction was not undoable")
            closeDuringRun = true
        }
        try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.inspectionCount == 0 }
        try UIVerification.require(try await hash(source) == before, "Extraction or Undo changed the source archive")
        if let sourceSecurity { try UIVerification.require(try await quarantine(source) == sourceSecurity, "Native extraction changed source quarantine") }
        let peak = peakResident(), added = peak > baseline ? peak - baseline : 0
        return ["passed": !scale || elapsed <= 10_000 && added <= 96 * 1_024 * 1_024 && heartbeat.count >= 2 && heartbeat.p95 <= 40,
            "scale": scale, "files": plan.files, "folders": plan.folders, "decodedBytes": plan.logicalBytes,
            "extractionMilliseconds": elapsed, "baselineRSS": baseline, "peakRSS": peak, "addedRSS": added, "forwardPeakRSS": forwardPeak,
            "heartbeatP95Milliseconds": heartbeat.p95, "heartbeatWorstMilliseconds": heartbeat.worst, "heartbeatSamples": heartbeat.count,
            "physicalInput": drive, "highCompression": args.contains("--zip-extraction-compressible"), "streamedDescriptors": args.contains("--zip-extraction-streamed"),
            "sourceUnchanged": true, "exactResults": true, "undoSucceeded": true,
            "cancelCreatedNothing": true, "closeDuringRun": closeDuringRun, "ordinaryActivation": ArchiveExtractionActivation.wholeArchiveAvailable,
            "windowWidth": controller.window?.frame.width ?? 0, "windowHeight": controller.window?.frame.height ?? 0,
            "admissionStopDrainMilliseconds": stopDrain,
            "quarantinePropagation": quarantined, "securedOutputNodes": securedNodes,
            "notExercised": ["Gatekeeper execution", "Minimum OS", "Personal archives", "Device removal", "Cross-device source"]
                + (quarantined ? [] : ["Quarantine propagation"])
                + (args.contains("--zip-extraction-streamed") ? [] : ["Data descriptors"])]
    }
    private static func quarantine(_ file: URL) async throws -> Data {
        try await Task.detached {
            let size=getxattr(file.path,"com.apple.quarantine",nil,0,0,0)
            guard size > 0 && size <= 4096 else { throw UIVerification.Failure(message:"Generated quarantine missing") }
            var bytes=Data(count:size)
            guard bytes.withUnsafeMutableBytes({ getxattr(file.path,"com.apple.quarantine",$0.baseAddress,$0.count,0,0) }) == size else {
                throw UIVerification.Failure(message:"Generated quarantine read changed")
            }
            return bytes
        }.value
    }
    private static func verifyQuarantineTree(_ root: URL, expected: Data) async throws -> Int {
        var pending=[root],count=0
        while let file=pending.popLast() {
            try UIVerification.require(try await quarantine(file) == expected,"Output quarantine differs")
            count += 1
            let children=try await Task.detached { () -> [URL] in
                let facts=try file.resourceValues(forKeys:[.isDirectoryKey])
                return facts.isDirectory == true ? try FileManager().contentsOfDirectory(at:file,includingPropertiesForKeys:nil) : []
            }.value
            pending.append(contentsOf:children)
        }
        return count
    }
    private static func requireID(_ outcome: RecoverableOperationResult?) throws -> UUID {
        guard let id = outcome?.recordID else { throw UIVerification.Failure(message: "Generated close result missing") }; return id
    }
    private static func inventory(_ root: URL) async throws -> (files: Int, bytes: UInt64) {
        try await Task.detached {
            var pending = [root], files = 0, bytes: UInt64 = 0
            while let folder = pending.popLast() {
                for url in try FileManager().contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) {
                    let facts = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    if facts.isDirectory == true { pending.append(url) }
                    else if facts.isRegularFile == true { files += 1; bytes += UInt64(facts.fileSize ?? 0) }
                    else { throw FileOperationFailure.unsupported }
                }
            }
            return (files, bytes)
        }.value
    }
    private static func hash(_ source: URL) async throws -> Data {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }; var hash = SHA256()
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
            return Data(hash.finalize())
        }.value
    }
    private static func wait(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(8)) }
        try UIVerification.require(condition(), "Native extraction did not settle")
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
        return result == KERN_SUCCESS ? UInt64(value.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
