#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import LocalStorage

@MainActor enum ArchiveContentVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b09-archive-content-check")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Content QA requires an admitted generated root")
        let source = root.appendingPathComponent("source/Generated.zip"), args = ProcessInfo.processInfo.arguments
        let scale = args.contains("--zip-content-scale"), drive = args.contains("--drive-zip-contents")
        let before = try await digest(source)
        browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
        browser.reloadFileRows(preserving: [source]); browser.browseZIP(nil)
        guard let controller = ApplicationZIPBrowser.shared.controller else { throw UIVerification.Failure(message: "Native archive tool missing") }
        let model = controller.model
        controller.window?.title = "Generated archive content check · " + root.lastPathComponent.prefix(8)
        try await wait { !model.isLoading && !model.isPaging && model.page != nil }
        try await Task.sleep(for: .milliseconds(100))
        try UIVerification.require(!model.isChecking && model.contentReport == nil && model.contentProgress == nil && model.canCheckContents,
            "Metadata browsing started a content check or failed explicit admission")
        let baseline = resident(), heartbeat = Heartbeat(), began = ProcessInfo.processInfo.systemUptime
        heartbeat.start()
        try await Task.sleep(for: .milliseconds(25))
        if drive {
            try UIVerification.require(!browser.isControlledVerification && controller.window?.isVisible == true, "Input QA needs a visible generated window")
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.isChecking || model.contentReport != nil }
        } else { model.checkContents() }
        try await wait { !model.isChecking && model.contentReport != nil }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        guard let report = model.contentReport else { throw UIVerification.Failure(message: "Native content receipt missing") }
        try UIVerification.require(report.files == (scale ? 9 : 3) && report.folders == 1
            && report.decodedBytes == (scale ? 32 * 1_024 * 1_024 : 256 * 1_024) && model.checkedAt != nil,
            "Native check did not verify the complete generated snapshot")
        let checkMilliseconds = report.seconds * 1_000
        // Even a sub-frame codec run must cross a real UI tick before this
        // responsiveness screen can pass; zero samples are not zero latency.
        try await Task.sleep(for: .milliseconds(35))
        if let window = controller.window, !browser.isControlledVerification {
            try await Task.sleep(for: .milliseconds(200)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/content-native.png"))
        }
        let added = max(heartbeat.peak, peakResident()) > baseline ? max(heartbeat.peak, peakResident()) - baseline : 0
        let p95 = heartbeat.p95, worst = heartbeat.worst
        heartbeat.stop()
        model.refresh(); await model.drain()
        try UIVerification.require(model.contentReport == nil && model.checkedAt == nil && model.page != nil, "Refresh retained a stale content receipt")
        model.checkContents()
        try UIVerification.require(model.isChecking, "Repeated explicit check was not admitted")
        let stopStart = ProcessInfo.processInfo.systemUptime
        model.stop(); await model.drain()
        let drain = (ProcessInfo.processInfo.systemUptime - stopStart) * 1_000
        try UIVerification.require(!model.isChecking && model.contentReport == nil && model.page != nil
            && ApplicationFileActivity.gate.activeCount == 0, "Stop published success, lost the listing or leaked the worker lease")
        ApplicationZIPBrowser.shared.prepareForVolumeQuiescence()
        try UIVerification.require(!model.canCheckContents && model.suspended, "Quiescence admitted a content check")
        ApplicationZIPBrowser.shared.resumeAfterVolumeQuiescence()
        model.checkContents()
        await ApplicationZIPBrowser.shared.stopAndDrain()
        try UIVerification.require(ApplicationZIPBrowser.shared.controller == nil && ApplicationFileActivity.gate.activeCount == 0,
            "Closing an active checker retained its actual I/O owner")
        try UIVerification.require(try await digest(source) == before, "Content checking changed its source")
        let names = try await Task.detached { try FileManager().contentsOfDirectory(atPath: root.appendingPathComponent("source").path) }.value
        try UIVerification.require(names == ["Generated.zip"], "Content checking materialized a member")
        return ["passed": !scale || checkMilliseconds <= 5_000 && added <= 64 * 1_024 * 1_024 && heartbeat.count >= 2 && p95 <= 40 && drain <= 2_000,
            "scale": scale, "files": report.files, "decodedBytes": report.decodedBytes, "packedBytes": report.packedBytes,
            "codecVersion": report.codecVersion, "checkMilliseconds": checkMilliseconds, "actionToReportMilliseconds": elapsed,
            "baselineRSS": baseline, "peakRSS": max(heartbeat.peak, peakResident()), "addedRSS": added,
            "heartbeatP95Milliseconds": p95, "heartbeatWorstMilliseconds": worst, "heartbeatSamples": heartbeat.count,
            "stopDrainMilliseconds": drain, "sourceUnchanged": true, "membersMaterialized": false, "physicalInput": drive,
            "ordinaryActivation": ArchiveContentCheckActivation.enabled, "streamedDescriptors": args.contains("--zip-content-streamed"),
            "notExercised": ["Extraction", "Minimum OS", "Personal archives", "Device removal"]
                + (args.contains("--zip-content-streamed") ? [] : ["Data descriptors"])]
    }
    private static func digest(_ source: URL) async throws -> Data {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
            return Data(hash.finalize())
        }.value
    }
    private static func wait(seconds: Double = 20, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(5)) }
        try UIVerification.require(condition(), "Native content check did not settle")
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var intervals: [Double] = []
        private(set) var peak: UInt64 = 0
        func start() {
            task = Task { [weak self] in
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard let self, !Task.isCancelled else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if intervals.count < 4_096 { intervals.append((now - last) * 1_000) }
                    last = now; peak = max(peak, resident())
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
        var count: Int { intervals.count }
        var p95: Double { let sorted = intervals.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { intervals.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage); return UInt64(max(0, usage.ru_maxrss)) }
}
#endif
