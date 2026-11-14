#if DEBUG
import AppKit
import Darwin
import ExplorerCore

private actor HeldInlinePreviewReader: InlinePreviewSelectionReading {
    struct Snapshot: Sendable { let started: Int, active: Int, maximum: Int }
    private var holding = true, failing = false, started = 0, active = 0, maximum = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func prepare(_ entry: FileEntry) async throws -> InlinePreviewSelectionReader.Decision {
        let lease = try ApplicationFileActivity.gate.begin()
        started += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1; withExtendedLifetime(lease) {} }
        if holding { await withCheckedContinuation { waiting.append($0) } }
        try Task.checkCancellation()
        if failing { throw FileActivityError.capacity }
        return .metadataOnly("Generated held-reader result: " + entry.name)
    }
    func release(failing: Bool = false) {
        holding = false; self.failing = failing
        let captured = waiting; waiting.removeAll()
        captured.forEach { $0.resume() }
    }
    func snapshot() -> Snapshot { .init(started: started, active: active, maximum: maximum) }
}

@MainActor enum InlinePreviewLifetimeVerification {
    private final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var preview: BrowserInlinePreviewController?
        func windowWillClose(_ notification: Notification) { preview?.endSession() }
    }
    @MainActor private final class Pulse {
        var last = CACurrentMediaTime(), gap = 0.0, ticks = 0
        func tick() { let now = CACurrentMediaTime(); gap = max(gap, now-last); last = now; ticks += 1 }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path), baseline = ProcessInfo.processInfo.arguments.contains("--preview-owner-baseline")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["action"] as? String == "traverse-inline-preview-owner" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.folderSummariesEnabled = false
        settings.showsDockProgress = false; settings.motion.mode = .off
        let owner = BrowserWindowController(settings: settings), held = HeldInlinePreviewReader(), pulse = Pulse()
        let controller = BrowserInlinePreviewController(reader: held)
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        var failures: [String] = [], checks: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, owner: owner, held: held, controller: controller, baseline: baseline, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        controller.setEnabled(false); await held.release()
        try? await wait("held reader drain") { await held.snapshot().active == 0 }
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        try? await wait("real activity drain") { ApplicationFileActivity.gate.activeCount == 0 }
        timer.invalidate()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native memory gate failed") }
        if pulse.gap > 0.4 || pulse.ticks < 10 { failures.append("Native response/sampling gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual worker remains") }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "featureGatePassed": failures.isEmpty && !baseline,
            "baseline": baseline, "checks": checks, "failures": failures, "metrics": metrics,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": pulse.gap,
            "activityCount": ApplicationFileActivity.gate.activeCount, "generatedOnly": true,
            "systemClipboardReads": 0, "systemClipboardWrites": 0, "network": 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, owner: BrowserWindowController, held: HeldInlinePreviewReader,
        controller: BrowserInlinePreviewController, baseline: Bool, checks: inout [String], metrics: inout [String: Any]) async throws {
        guard let window = owner.window else { throw UIVerification.Failure(message: "Workspace missing") }
        window.setFrame(.init(x: -12000, y: -12000, width: 1040, height: 700), display: true); window.makeKeyAndOrderFront(nil)
        let browser = owner.browser
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.pinsController = BrowserPinsController(stateDirectory: nil)
        owner.beginBrowsing(); try await wait("workspace ready") { owner.workspace.sessionReady }
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait("generated source") { !browser.isLoading && browser.orderingTask == nil }
        let entries = browser.displayedEntries.filter { $0.name == "First.txt" || $0.name == "Second.txt" }.sorted { $0.name < $1.name }
        try UIVerification.require(entries.count == 2, "Generated selections missing")
        func select(_ index: Int) { browser.reloadFileRows(preserving: [entries[index].url]); controller.updateSelection(from: browser) }
        controller.setEnabled(true); select(0)
        try await wait("first held preparation") { await held.snapshot().started == 1 }
        for index in 0..<16 {
            select((index+1)%2)
            try await Task.sleep(for: .milliseconds(160))
        }
        let storm = await held.snapshot()
        controller.setEnabled(false)
        metrics["startedWhileHeld"] = storm.started; metrics["maximumHeldCallers"] = storm.maximum
        metrics["reportedReleasedWhileHeld"] = controller.hasReleasedSession
        if baseline {
            try UIVerification.require(storm.started >= 4 && storm.maximum >= 4 && controller.hasReleasedSession,
                "Old preparation-owner gap was not reproduced")
            checks.append("Baseline reproduced multiple held controller callers/access activity and a falsely released session after Disable")
        } else {
            try UIVerification.require(storm.started == 1 && storm.maximum == 1 && !controller.hasReleasedSession,
                "Selection storm overlapped readers or falsely dropped its retained owner")
            controller.setEnabled(true); select(1)
            try await Task.sleep(for: .milliseconds(200))
            let reenabled = await held.snapshot()
            try UIVerification.require(reenabled.started == 1, "Re-enable replaced a still-held actual preparation")
            checks.append("Sixteen selection changes and Disable/re-enable retain one actual caller and one latest demand until real retirement")
        }
        await held.release()
        try await wait("held reader returns") { await held.snapshot().active == 0 }
        if !baseline {
            try await wait("latest pending result") { controller.state == .metadataOnly && controller.contextNameForVerification == entries[1].name }
            let retired = await held.snapshot()
            try UIVerification.require(retired.started == 2 && retired.maximum == 1, "Retired owner did not consume only the final pending selection")
            controller.endSession()
            try await wait("retained owner drain") { controller.hasReleasedSession }
            checks.append("Only the latest selection publishes after held cancellation; end/close clears the view and actual owner drains")
        }
        let failing = HeldInlinePreviewReader(); await failing.release(failing: true)
        let failedController = BrowserInlinePreviewController(reader: failing)
        failedController.setEnabled(true); browser.reloadFileRows(preserving: [entries[0].url]); failedController.updateSelection(from: browser)
        try await wait("current preparation attempted") {
            let snapshot = await failing.snapshot()
            return snapshot.started == 1 && snapshot.active == 0
        }
        try await Task.sleep(for: .milliseconds(80))
        metrics["currentFailureState"] = String(describing: failedController.state)
        try UIVerification.require(failedController.state == (baseline ? .preparing : .metadataOnly), "Current preparation failure state differs")
        failedController.setEnabled(false)
        try await wait("failed controller drain") { failedController.hasReleasedSession }
        checks.append(baseline ? "Baseline current thrown preparation remains Preparing" : "Actual thrown current preparation leaves Preparing with a truthful fallback and releases its owner")
        controller.setEnabled(false)
        if !baseline {
            let closingReader = HeldInlinePreviewReader(), closing = BrowserInlinePreviewController(reader: closingReader)
            let closeDelegate = CloseDelegate(); closeDelegate.preview = closing
            let previewWindow = NSWindow(contentRect: .init(x: -12000, y: -12000, width: 340, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            previewWindow.isReleasedWhenClosed = false; previewWindow.isRestorable = false
            previewWindow.delegate = closeDelegate; previewWindow.contentView = closing.view
            previewWindow.title = "Generated held preview close"; previewWindow.orderFront(nil)
            defer { previewWindow.close(); Task { await closingReader.release() } }
            closing.setEnabled(true); closing.updateSelection(from: browser)
            try await wait("closing held reader started") { await closingReader.snapshot().started == 1 }
            previewWindow.close()
            try UIVerification.require(closing.state == .empty && !closing.hasReleasedSession && closing.renderedURL == nil,
                "Native close lost actual ownership or retained a visible stale renderer")
            await closingReader.release()
            try await wait("native closed preview drain") { closing.hasReleasedSession }
            try UIVerification.require(closing.state == .empty && closing.renderedURL == nil, "A closed preview published a held late result")
            withExtendedLifetime(closeDelegate) {}
            checks.append("An actual native window-close callback clears visible preview immediately, retains held worker ownership and refuses late publication until real drain")
            checks += try await InlinePreviewVerification.run(in: root, renderKnownFixtures: true)
        }
    }
    private static func wait(_ message: String, _ condition: @MainActor () async -> Bool) async throws {
        let end = CACurrentMediaTime()+10
        while !(await condition()) {
            try UIVerification.require(CACurrentMediaTime() < end, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
