#if DEBUG
import AppKit
import Darwin
import StorageAnalysis

private final class AppAccountingHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func pause() throws {
        condition.lock(); defer { condition.unlock() }; started = true
        while !released {
            guard condition.wait(until: Date().addingTimeInterval(8)) else { throw StorageScanFailure.unavailable }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@MainActor enum StorageAppAccountingVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run(root: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        try require(root.deletingLastPathComponent() == repository.appendingPathComponent(".build/test-fixtures")
            && root.lastPathComponent.hasPrefix("analysis-storage-pool-") && root.resolvingSymlinksInPath() == root,
            "Only the generated app-storage fixture is admitted")
        let state = root.appendingPathComponent("State"), pool = root.appendingPathComponent("Pool")
        let marker = try await Task.detached { try Data(contentsOf: root.appendingPathComponent(".fixture-owner")) }.value
        try require(marker == Data("mac-explorer-analysis-storage-v1".utf8), "Generated app-storage marker missing")
        let settings = BrowserSettings(persist: false, persistenceFile: state.appendingPathComponent("preferences.json"))
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.temporaryStorageDirectoryForVerification = pool
        defer { if !review { coordinator.toolWindow?.close() }; coordinator.temporaryStorageDirectoryForVerification = nil }
        coordinator.showAppStorage(settings: settings)
        try await wait("Missing-state inventory did not drain") { !coordinator.hasWork }
        guard let tool = coordinator.toolWindow else { throw StorageScanFailure.invalidOutput }
        try require(tool.appComponentRows.count == 1 && tool.appComponentRows[0].title == "Temporary analysis results"
            && tool.appComponentRows[0].logical == FileSizeText.string(21)
            && tool.appComponentRows[0].note.contains("1 sessions") && tool.appComponentRows[0].note.contains("1 with no held"),
            "Missing app state hid or misreported the independently declared pool")
        try require(!FileManager().fileExists(atPath: state.path) && coordinator.updateForVerification == nil,
            "Inventory created state or started its scanner")
        try await Task.detached {
            try FileManager().createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard FileManager().createFile(atPath: state.appendingPathComponent("preferences.json").path,
                contents: Data("{}".utf8), attributes: [.posixPermissions: 0o600]) else { throw StorageScanFailure.unavailable }
        }.value
        coordinator.showAppStorage(settings: settings)
        try await wait("Combined app-state/pool inventory did not drain") { !coordinator.hasWork && coordinator.attributionForVerification != nil }
        try require(tool.appComponentRows.filter { $0.title == "Temporary analysis results" }.count == 1
            && tool.appComponentRows.first(where: { $0.title == "Preferences" })?.logical == FileSizeText.string(2)
            && tool.appComponentRows.first(where: { $0.title == "Operation history" })?.logical == "Not created"
            && !FileManager().fileExists(atPath: state.appendingPathComponent("operation-recovery").path),
            "Pool observation was erased by scan rendering or created operation history")
        let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/app-storage-" + UUID().uuidString + ".png")
        if let window = tool.window { try await UIVerification.snapshot(window, to: capture) }
        if review {
            tool.window?.title = "App Storage · generated accounting review"
            tool.window?.makeKeyAndOrderFront(nil)
            return ["passed": true, "review": true, "checks": ["missing state remains absent", "separate pool observation", "state and pool render together"]]
        }
        let lock = open(pool.appendingPathComponent("pool.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard lock >= 0 else { throw StorageScanFailure.unavailable }; defer { close(lock) }
        try require(flock(lock, LOCK_EX | LOCK_NB) == 0, "Generated pool lock unavailable")
        coordinator.showAppStorage(settings: settings)
        try await wait("Busy pool observation did not finish") { !coordinator.hasWork && coordinator.attributionForVerification != nil }
        try require(tool.appComponentRows.first(where: { $0.title == "Temporary analysis results" })?.logical == "Busy"
            && tool.appComponentRows.first(where: { $0.title == "Preferences" })?.logical == FileSizeText.string(2),
            "Busy pool became zero or discarded the independent state observation")
        _ = flock(lock, LOCK_UN)
        let hold = AppAccountingHold(); defer { hold.release() }
        try coordinator.temporaryStorageReaderForVerification.installAfterInventoryForQualification { try hold.pause() }
        coordinator.showAppStorage(settings: settings)
        try await wait("Held pool observation did not enter") { hold.entered }
        var drained = false
        let drain = Task { await coordinator.stopAndDrain(); drained = true }
        try await Task.sleep(for: .milliseconds(35))
        try require(!drained && coordinator.hasWork && coordinator.temporaryStorageReaderForVerification.isBusy
            && ApplicationFileActivity.gate.activeCount >= 1, "Stop released the real pool reader early")
        hold.release(); await drain.value
        try require(!coordinator.hasWork && !coordinator.temporaryStorageReaderForVerification.isBusy
            && tool.appComponentRows.isEmpty, "Cancelled pool observation published stale content")
        try require(browser.location.directoryURL == nil, "Scope-clear control requires This Mac")
        coordinator.show(from: browser)
        try require(tool.appComponentRows.isEmpty, "A new scope retained app-storage content")
        tool.close(); await coordinator.stopAndDrain()
        try require(ApplicationFileActivity.gate.activeCount == 0, "App-storage close did not drain actual activity")
        return ["passed": true, "checks": ["missing state remains absent", "non-SQLite database metadata only", "state and pool render together",
            "no history creation", "busy is not zero", "Stop retains actual reader", "stale publication rejected", "scope and close clear content"],
            "activity_count": ApplicationFileActivity.gate.activeCount, "source_body_reads": false,
            "pool_database_opened": false, "state_history_created": false, "capture": capture.lastPathComponent]
    }
}
#endif
