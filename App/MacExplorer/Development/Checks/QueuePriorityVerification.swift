#if DEBUG
import AppKit
import ExplorerCore
import FileOperations

@MainActor enum QueuePriorityVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-queue-priority" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
        settings.motion.mode = .off
        let owner = BrowserWindowController(settings: settings), browser = owner.browser
        browser.permitsBackgroundVerification = true
        browser.operationResultPresenter = { _ in }; browser.operationErrorPresenter = { _ in }
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("history"))
        browser.recoverableFileOperations = engine
        let queue = browser.operationCoordinator.transfers
        let firstGate = Gate(), secondGate = Gate()
        var failures: [String] = [], checks: [String] = [], metrics: [String: Any] = [:]
        var backdrop: NSWindow?
        do {
            guard let window = owner.window else { throw UIVerification.Failure(message: "Missing generated queue window") }
            window.title = "Queue priority · generated review"; window.setFrame(.init(x: 140, y: 140, width: 960, height: 640), display: true)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); owner.beginBrowsing()
            if ProcessInfo.processInfo.arguments.contains("--record-motion") { backdrop = GlassVerification.makeBrowserBackdropWindow(behind: window) }
            try await wait { owner.workspace.sessionReady }
            browser.navigate(to: .directory(root.appendingPathComponent("source")))
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            browser.transferConflictPrompt = { await firstGate.answer($0) }
            let first = try enqueue("First.txt", root: root, browser: browser, engine: engine)
            try await wait { firstGate.entered }
            browser.updateOperationProgressControls()
            let staleDetailsStop = browser.operationDetails.onStop
            let stale = TransferQueueInspectionView(frame: .init(x: 0, y: 0, width: 380, height: 300))
            stale.onStop = { queue.stopActive(expectedID: $0) }; stale.update(queue)
            let stop = try button(in: stale, title: "Stop")
            browser.transferConflictPrompt = { await secondGate.answer($0) }
            let second = try enqueue("Second.txt", root: root, browser: browser, engine: engine)
            firstGate.release()
            try await wait { secondGate.entered && queue.state.active?.id == second }
            staleDetailsStop?()
            try UIVerification.require(queue.state.active?.stopRequested == false,
                "A stale progress-details Stop for the first transfer stopped a different active transfer")
            stop.performClick(nil)
            try UIVerification.require(queue.state.active?.stopRequested == false,
                "A stale inspector Stop for the first transfer stopped a different active transfer")
            try UIVerification.require(queue.results.contains { $0.id == first }, "First generated worker never drained")
            checks.append("A stale native inspector Stop cannot stop the next transfer")
            try await verifyWaiting(root: root, owner: owner, browser: browser, engine: engine,
                active: second, gate: secondGate, checks: &checks, metrics: &metrics)
        } catch { failures.append(String(describing: error)) }
        queue.stopActive(); queue.cancelAllWaiting(); firstGate.release(); secondGate.release()
        do { try await wait { !queue.hasOutstandingWork && queue.isIdleForCopyPreview } }
        catch { failures.append("Generated worker failed to drain") }
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close(); backdrop?.close()
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics,
            "generatedFileOperations": true, "personalCatalogs": 0, "networkRequests": 0,
            "drained": !queue.hasOutstandingWork && queue.isIdleForCopyPreview], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verifyWaiting(root: URL, owner: BrowserWindowController, browser: BrowserViewController,
        engine: RecoverableFileOperations, active: UUID, gate: Gate,
        checks: inout [String], metrics: inout [String: Any]) async throws {
        let queue = browser.operationCoordinator.transfers
        let third = try enqueue("Third.txt", root: root, browser: browser, engine: engine)
        let fourth = try enqueue("Fourth.txt", root: root, browser: browser, engine: engine)
        let canceled = try enqueue("Canceled.txt", root: root, browser: browser, engine: engine)
        let waitingIDs = Set([third, fourth, canceled])
        try await wait { queue.state.waiting.allSatisfy { $0.phase == .ready } }
        browser.showTransferQueue(nil)
        let inspector = browser.transferQueueDetails, table = inspector.tableForVerification
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require(inspector.frame.width >= 340 && inspector.frame.height >= 250
            && table.rows(in: table.visibleRect).length >= 2, "Native queue inspector has no usable list area")
        func select(_ id: UUID) throws {
            guard let row = inspector.rowIDsForVerification.firstIndex(of: id) else { throw UIVerification.Failure(message: "Missing generated waiting row") }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            owner.window?.makeFirstResponder(table)
        }
        func selected() -> UUID? {
            inspector.rowIDsForVerification.indices.contains(table.selectedRow) ? inspector.rowIDsForVerification[table.selectedRow] : nil
        }
        func painted(_ ids: [UUID]) async throws {
            try await wait { inspector.rowIDsForVerification.filter { waitingIDs.contains($0) } == ids }
        }
        let earlier = try accessibleButton(in: inspector, label: "Move waiting transfer earlier")
        let later = try accessibleButton(in: inspector, label: "Move waiting transfer later")
        try select(fourth); try UIVerification.require(earlier.isEnabled && later.isEnabled, "Native waiting priority controls are unavailable")
        earlier.performClick(nil); try await painted([fourth, third, canceled])
        try UIVerification.require(selected() == fourth && queue.state.active?.id == active, "Priority changed the selected identity or running job")
        table.keyDown(with: UIVerification.key("", code: 125, flags: .option, window: owner.window!))
        try await painted([third, fourth, canceled])
        guard let menu = inspector.menuForVerification(row: table.selectedRow) else { throw UIVerification.Failure(message: "Native priority menu missing") }
        menu.performActionForItem(at: 0); try await painted([fourth, third, canceled])
        guard let staleMenu = inspector.menuForVerification(row: table.selectedRow),
              let row = inspector.rowIDsForVerification.firstIndex(of: canceled),
              let cancel = table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSButton else {
            throw UIVerification.Failure(message: "Native waiting Cancel/menu missing")
        }
        cancel.performClick(nil); try await painted([fourth, third])
        let beforeStale = queue.state
        staleMenu.performActionForItem(at: 1)
        try UIVerification.require(queue.state == beforeStale && !queue.results.contains { $0.id == canceled },
            "A stale row menu moved another job, or waiting cancellation created an execution result")
        checks.append("Native priority buttons, Option-Down and row menu move only waiting jobs; cancellation invalidates an older menu")

        let originalPreset = browser.settings.keyboardProfile, location = browser.location
        for preset in [KeyboardProfile.explorer, .mac] {
            browser.settings.keyboardProfile = preset; try select(third)
            try UIVerification.require(browser.routeBrowserShortcut(UIVerification.key("", code: 126, flags: .option, window: owner.window!)),
                "Queue priority shortcut did not enter native browser routing")
            try await painted([third, fourth])
            try UIVerification.require(browser.location == location, "Queue priority key navigated out of the source folder")
            try UIVerification.require(browser.routeBrowserShortcut(UIVerification.key("", code: 125, flags: .option, window: owner.window!)),
                "Queue priority down key did not route")
            try await painted([fourth, third])
        }
        browser.settings.keyboardProfile = originalPreset; try select(fourth)
        browser.focusBrowserContent()
        try UIVerification.require(!inspector.consumeShortcut(UIVerification.key("", code: 126, flags: .option, window: owner.window!)),
            "Queue keys retained authority after focus left its list")
        try select(fourth)
        checks.append("Explorer/Mac native routing keeps priority keys local to the focused queue, preserving folder navigation elsewhere")

        let reloads = inspector.fullReloadsForVerification, began = CACurrentMediaTime()
        for _ in 0..<200 { inspector.update(queue) }
        metrics["unchangedRefreshMilliseconds"] = (CACurrentMediaTime() - began) * 1000
        metrics["unchangedRefreshCount"] = 200
        metrics["unchangedFullReloads"] = inspector.fullReloadsForVerification - reloads
        try UIVerification.require(inspector.fullReloadsForVerification == reloads && selected() == fourth,
            "Progress refresh reloads unchanged rows or loses selection")
        checks.append("Two hundred unchanged refreshes perform no full table reload and retain the selected transfer")
        if ProcessInfo.processInfo.arguments.contains("--record-motion"), let window = owner.window {
            for mode in BrowserMotionMode.allCases {
                window.title = "Queue priority · generated review"
                browser.settings.motion.mode = mode; inspector.motion = browser.settings.motion
                try select(queue.state.waiting[1].id)
                let desired = [queue.state.waiting[1].id, queue.state.waiting[0].id]
                let report = try await NativeMotionRecorder.record(window: window, root: root, label: "queue-" + mode.rawValue) { earlier.performClick(nil) }
                try await painted(desired)
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/queue-" + mode.rawValue + ".json"), options: .withoutOverwriting)
            }
            checks.append("Native row moves recorded in Full/Reduced/Off with complete stream/writer drain")
        }
        browser.settings.motion.mode = .off; inspector.motion = browser.settings.motion
        if queue.state.waiting.first?.id != fourth { try select(fourth); earlier.performClick(nil); try await painted([fourth, third]) }
        let expected = queue.state.waiting.map(\.id)
        let retiredMove = inspector.onMoveWaiting, retiredStop = inspector.onStop, retiredCancel = inspector.onCancel
        owner.suspendBrowsing()
        let movedWhileRetired = retiredMove?(third, -1, expected) ?? false
        retiredStop?(active); retiredCancel?(fourth)
        try UIVerification.require(!movedWhileRetired && queue.state.active?.stopRequested == false && queue.state.waiting.map(\.id) == expected,
            "A suspended browser retained queue-control authority")
        owner.resumeBrowsing(); try await wait { !browser.isBrowserSuspended && !browser.isLoading }
        browser.showTransferQueue(nil)
        let stop = try button(in: inspector, title: "Stop"); stop.performClick(nil)
        try UIVerification.require(queue.state.active?.id == active && queue.state.active?.stopRequested == true
            && queue.state.isPaused && queue.state.waiting.map(\.id) == expected && !queue.isIdleForVolumeAction,
            "Current Stop released ownership before its actual blocked worker drained")
        gate.release(); try await wait { queue.state.active == nil && queue.isIdleForVolumeAction }
        try UIVerification.require(queue.state.isPaused && queue.state.waiting.map(\.id) == expected,
            "Worker drain silently resumed waiting jobs")
        inspector.update(queue); try button(in: inspector, title: "Resume Queue").performClick(nil)
        try await wait { !queue.hasOutstandingWork && queue.isIdleForVolumeAction }
        let completed = queue.results.filter { expected.contains($0.id) }
        try UIVerification.require(completed.map(\.id) == expected && completed.allSatisfy { $0.outcome.result.disposition == .succeeded },
            "Real generated Copy did not follow the explicitly selected priority")
        for value in completed.reversed() {
            guard let record = value.outcome.recordID else { throw UIVerification.Failure(message: "Generated Copy lost its exact Undo record") }
            let undone = await engine.undo(recordID: record)
            try UIVerification.require(undone.result.disposition == .succeeded, "Generated queue Copy Undo failed")
        }
        let targetsAbsent = await Task.detached {
            ["Third.txt", "Fourth.txt", "Canceled.txt"].allSatisfy { !FileManager.default.fileExists(atPath: root.appendingPathComponent("destination/" + $0).path) }
        }.value
        try UIVerification.require(targetsAbsent, "Undo or waiting cancellation left a public generated target")
        checks.append("Suspended controls refuse; current Stop retains its worker until drain; explicit Resume honors priority and exact Copy Undo removes both new targets")
    }
    private static func enqueue(_ name: String, root: URL, browser: BrowserViewController, engine: RecoverableFileOperations) throws -> UUID {
        guard let id = browser.operationCoordinator.transfers.enqueue(sources: [root.appendingPathComponent("source/" + name)],
            destination: root.appendingPathComponent("destination"), move: false, title: "Generated " + name,
            origin: browser, engine: engine, metadataPolicy: .strict) else { throw UIVerification.Failure(message: "Generated queue admission refused") }
        return id
    }
    private static func button(in view: NSView, title: String) throws -> NSButton {
        var views = [view]
        while let item = views.popLast() {
            if let button = item as? NSButton, button.title == title { return button }
            views += item.subviews
        }
        throw UIVerification.Failure(message: "Missing generated queue button")
    }
    private static func accessibleButton(in view: NSView, label: String) throws -> NSButton {
        var views = [view]
        while let item = views.popLast() {
            if let button = item as? NSButton, button.accessibilityLabel() == label { return button }
            views += item.subviews
        }
        throw UIVerification.Failure(message: "Missing accessible priority button")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 10
        while !condition() {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < until, "Generated queue did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private final class Gate {
        private(set) var entered = false
        private var conflicts: [TransferConflict] = []
        private var continuation: CheckedContinuation<[UUID: TransferConflictResolution]?, Never>?
        func answer(_ conflicts: [TransferConflict]) async -> [UUID: TransferConflictResolution]? {
            entered = true; self.conflicts = conflicts
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume(returning: Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) })); continuation = nil
        }
    }
}
#endif
