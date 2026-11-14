#if DEBUG
import AppKit
import ExplorerCore
import LocalStorage

@MainActor enum DragReadinessDiagnosticsVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ condition: Bool, _ line: UInt = #line) throws { if !condition { throw Failure.check(line) } }
    private static func wait(_ condition: () -> Bool, _ line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        while !condition() { try require(ProcessInfo.processInfo.systemUptime < deadline, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pauseOnce() async {
            guard !entered else { return }; entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { let held = continuation; continuation = nil; held?.resume() }
    }
    static func run() async {
        var root: URL?, service: DiagnosticRecorder?, failedLogger: DiagnosticRecorder?, browser: BrowserViewController?, window: NSWindow?
        var gates: [Gate] = [], checks: [String] = [], line: UInt?, failureType: String?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["action"] as? String == "drag-readiness-diagnostics" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            let logger = DiagnosticRecorder(directory: admitted.appendingPathComponent("state/logs"), limits: try .init(bytes: 512 << 10, segmentBytes: 64 << 10), recording: true)
            service = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.motion.mode = .off; settings.showsDockProgress = false
            let owner = BrowserViewController(settings: settings); browser = owner
            owner.permitsBackgroundVerification = true
            let host = NSWindow(contentRect: .init(x: 140, y: 130, width: 960, height: 640), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false; host.contentViewController = owner; host.title = "Generated drag readiness · no file moves"
            host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window = host
            let folder = admitted.appendingPathComponent("source/PRIVATE-DRAG-SENTINEL"), first = folder.appendingPathComponent("PRIVATE-A.txt"), second = folder.appendingPathComponent("PRIVATE-B.txt")
            let controller = owner.dragDrop; controller.permitsVerification = true
            owner.navigate(to: .directory(folder))
            try await wait { !owner.isLoading && owner.orderingTask == nil && owner.rowsByURL[first] != nil && owner.rowsByURL[second] != nil }
            let firstRow = owner.rowsByURL[first]!, secondRow = owner.rowsByURL[second]!
            owner.table.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
            controller.windowWillClose()
            let held = Gate(); gates.append(held)
            controller.sourcePreparationWaitForVerification = { await held.pauseOnce() }
            controller.selectionDidChange(); try await wait { held.entered }
            for _ in 0..<128 { try require(controller.pasteboardWriter(for: firstRow) == nil) }
            let pending = try await events(logger).filter { $0.context?.checkpoint == .dragWriter && $0.phase == .blocked }
            try require(pending.count == 1 && pending[0].context?.flags == [.sourceNotPrepared,.preparationPending] && pending[0].count == 1)
            checks.append("128 synchronous cold writer requests produce one bounded preparation-pending refusal")
            held.release(); try await wait { !controller.verificationState.preparing && controller.hasPreparedObjectForVerification(first) }
            try require(controller.pasteboardWriter(for: firstRow) != nil)
            let prepared = try await events(logger)
            let sourceStart = prepared.last { $0.context?.checkpoint == .dragSources && $0.phase == .requested }
            guard let sourceStart else { throw Failure.scope }
            let lifetime = prepared.filter { $0.trace == sourceStart.trace }
            try require(lifetime.contains { $0.context?.checkpoint == .dragSources && $0.phase == .completed && $0.count == 2 }
                && lifetime.contains { $0.context?.checkpoint == .dragTargets && $0.phase == .completed && $0.count == 1 }
                && prepared.contains { $0.trace == sourceStart.trace && $0.context?.checkpoint == .dragWriter && $0.phase == .admitted })
            checks.append("Actual source/target metadata preparation has one correlated lifetime and ready writer")
            for _ in 0..<128 { try require(controller.pasteboardWriter(for: -1) == nil) }
            let invalid = try await events(logger).filter { $0.context?.checkpoint == .dragWriter && $0.context?.flags == [.wrongPresentation] }
            try require(invalid.count == 1 && invalid[0].trace == sourceStart.trace)
            try require(controller.pasteboardWriter(for: firstRow) != nil)
            checks.append("Invalid native rows are refused once and cannot suppress a later valid writer")
            owner.table.selectRowIndexes(IndexSet(integer: secondRow), byExtendingSelection: false)
            controller.selectionDidChange()
            try require(controller.pasteboardWriter(for: secondRow) != nil)
            checks.append("Visible selection changes retain immediate writers without another async preparation")
            owner.showSettings(nil); host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { host.isKeyWindow }
            try require(controller.pasteboardWriter(for: secondRow) != nil)
            (owner.workspace?.settingsWindow ?? owner.settingsWindow)?.close()
            checks.append("A retained Settings window does not remove the ready source writer")

            controller.windowWillClose(); controller.sourcePreparationWaitForVerification = nil
            try await Task.detached { try FileManager.default.removeItem(at: first) }.value
            owner.table.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
            controller.selectionDidChange(); try await wait { !controller.verificationState.preparing }
            try require(controller.pasteboardWriter(for: firstRow) == nil && controller.hasPreparedObjectForVerification(second))
            let failed = try await events(logger)
            try require(failed.contains { $0.context?.checkpoint == .dragSources && $0.phase == .partial && $0.count == 1 && $0.error != nil }
                && failed.contains { $0.context?.checkpoint == .dragWriter && $0.phase == .blocked && $0.context?.flags == [.sourceNotPrepared] })
            checks.append("A vanished generated source records its real numeric error while another source remains prepared")
            try await Task.detached { try Data("Generated drag A".utf8).write(to: first, options: .withoutOverwriting) }.value
            controller.windowWillClose()
            let stale = Gate(); gates.append(stale)
            controller.sourcePreparationWaitForVerification = { await stale.pauseOnce() }
            controller.selectionDidChange(); try await wait { stale.entered }
            let heldEvents = try await events(logger)
            guard let heldTrace = heldEvents.last(where: { $0.context?.checkpoint == .dragSources && $0.phase == .requested })?.trace else { throw Failure.scope }
            owner.navigate(to: .directory(admitted.appendingPathComponent("source/Empty")))
            try await wait { !owner.isLoading && owner.orderingTask == nil }
            try require(!(try await events(logger)).contains { $0.trace == heldTrace && $0.phase == .cancelled })
            stale.release(); try await Task.sleep(for: .milliseconds(30))
            try require(!controller.hasPreparedObjectForVerification(first))
            let changed = try await events(logger)
            try require(changed.contains { $0.trace == heldTrace && $0.context?.checkpoint == .dragSources && $0.phase == .cancelled })
            checks.append("Context cancellation logs a terminal only after held preparation returns and never publishes stale source authority")

            controller.sourcePreparationWaitForVerification = nil
            owner.navigate(to: .directory(folder)); try await wait { !owner.isLoading && owner.orderingTask == nil }
            try await wait { !controller.verificationState.preparing && controller.hasPreparedObjectForVerification(first) }
            owner.table.selectRowIndexes(IndexSet(integer: owner.rowsByURL[first]!), byExtendingSelection: false)
            controller.selectionDidChange()
            let unavailable = DiagnosticRecorder(directory: admitted.appendingPathComponent("source/Blocker/logs"), limits: try .init(), recording: true)
            failedLogger = unavailable; ApplicationDiagnostics.shared.configureForVerification(unavailable)
            try require(controller.pasteboardWriter(for: owner.rowsByURL[first]!) != nil)
            await unavailable.flush()
            try require(unavailable.status.failure != nil)
            ApplicationDiagnostics.shared.configureForVerification(logger)
            checks.append("An actual unwritable diagnostic store cannot disable an already ready native writer")
            let destination = admitted.appendingPathComponent("evidence/drag-log-export.jsonl")
            guard case let .saved(records,_,incomplete) = await logger.export(to: destination, retainingAccess: "Generated drag logs only") else { throw Failure.scope }
            let text = try await Task.detached { try String(contentsOf: destination, encoding: .utf8) }.value
            try require(records > 0 && !incomplete && !text.contains("PRIVATE-") && !text.contains(admitted.path)
                && !text.contains(first.absoluteString) && !text.contains(Data(first.absoluteString.utf8).base64EncodedString()))
            checks.append("Actual exported stages preserve counts and causes without file names, paths or encoded URL inputs")
            try require(logger.status.failure == nil && logger.status.dropped == 0)
        } catch {
            if case let Failure.check(value) = error { line = value } else { line = 0 }
            failureType = String(reflecting: type(of: error))
        }
        gates.forEach { $0.release() }
        browser?.dragDrop.sourcePreparationWaitForVerification = nil
        browser?.suspendBrowser(); window?.close()
        try? await wait { ApplicationFileActivity.gate.activeCount == 0 }
        ApplicationDiagnostics.shared.configureForVerification(nil)
        await failedLogger?.closeAndDrain(); await service?.closeAndDrain()
        if let root {
            let report: [String: Any] = ["passed":line == nil,"line":line.map { $0 as Any } ?? NSNull(),"failureType":failureType.map { $0 as Any } ?? NSNull(),
                "checks":checks,"activityDrained":ApplicationFileActivity.gate.activeCount == 0,"physicalDragExercised":false,"personalGrants":0,"networkRequests":0,"fileMoves":0]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-drag-diagnostics.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func events(_ service: DiagnosticRecorder) async throws -> [DiagnosticEvent] {
        await service.flush()
        var all: [DiagnosticEvent] = [], cursor: DiagnosticHistoryCursor?
        repeat {
            let page = try await service.page(before: cursor, limit: 256)
            try require(!page.incomplete && all.count < 1024); all += page.events; cursor = page.next
        } while cursor != nil
        return all.sorted { $0.uptimeNanoseconds < $1.uptimeNanoseconds }
    }
}
#endif
