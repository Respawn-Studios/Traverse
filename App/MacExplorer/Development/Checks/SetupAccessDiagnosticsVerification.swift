#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import LocalStorage

@MainActor enum SetupAccessDiagnosticsVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 7
        while !condition() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func run() async {
        var root: URL?, logger: DiagnosticRecorder?, window: NSWindow?, active: Task<FolderAccessChoice?, Never>?
        var gates: [Gate] = [], checks: [String] = [], seen = Set<UUID>(), failure: UInt?, failureType: String?
        var traceFacts: [[String: Any]] = []
        var asyncControls: [AsyncControl] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && admitted.resolvingSymlinksInPath() == admitted && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["action"] as? String == "setup-access-diagnostics" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            let service = DiagnosticRecorder(directory: admitted.appendingPathComponent("state/logs"),
                limits: try .init(bytes: 512 << 10, segmentBytes: 64 << 10), recording: true)
            logger = service; ApplicationDiagnostics.shared.configureForVerification(service)
            let folder = admitted.appendingPathComponent("source/PRIVATE-FOLDER-SENTINEL")
            let host = NSWindow(contentRect: .init(x: 120,y: 120,width: 600,height: 360),styleMask: [.titled,.closable],backing: .buffered,defer: false)
            host.isReleasedWhenClosed = false; host.title = "Generated access log check · no personal grants"
            host.makeKeyAndOrderFront(nil); window = host
            let chooser = FolderAccessController(backend: Backend())
            let panelTask = Task { await chooser.chooseFolder(in: host, initialDirectory: folder, purpose: .setup) }
            active = panelTask; try await wait { host.attachedSheet is NSOpenPanel }
            (host.attachedSheet as? NSOpenPanel)?.cancel(nil)
            try require(await panelTask.value == nil); active = nil
            let pickerEvents = try await newTrace(service, seen: &seen)
            try require(pickerEvents.map(\.phase) == [.requested,.presenting,.cancelled]
                && pickerEvents.allSatisfy { $0.context?.checkpoint == .folderPicker })
            traceFacts.append(facts("chooser-cancel", pickerEvents)); checks.append("Real chooser Cancel is one correlated requested/presented/cancelled lifetime")

            let backend = Backend(), access = FolderAccessController(stateDirectory: admitted.appendingPathComponent("state/success"),backend: backend)
            let choice = await access.acceptChosenFolder(folder,remember: true)
            guard let choice, case .saved = choice.remembering else { throw Failure.scope }
            choice.lease.close()
            let saved = try await newTrace(service,seen: &seen)
            try require(saved.filter { $0.phase == .requested }.count == 1
                && saved.contains { $0.phase == .resolving && $0.context?.checkpoint == .folderScope }
                && saved.contains { $0.phase == .completed && $0.context?.checkpoint == .folderBookmark }
                && saved.last?.context?.checkpoint == .folderAccessPublication && saved.last?.phase == .completed
                && backend.counts == [1,1])
            traceFacts.append(facts("remember-success", saved)); checks.append("Remember logs actual scope acquisition, durable acknowledgement and publication without duplicate admission")

            let failing = Backend(failBookmark: true), transient = FolderAccessController(stateDirectory: admitted.appendingPathComponent("state/failure"),backend: failing)
            let partial = await transient.acceptChosenFolder(folder,remember: true)
            guard let partial, case .failed = partial.remembering else { throw Failure.scope }
            partial.lease.close()
            let failed = try await newTrace(service,seen: &seen)
            try require(failed.contains { $0.phase == .failed && $0.context?.checkpoint == .folderBookmark && $0.error?.symbol == "EACCES" }
                && failed.last?.phase == .partial && failed.last?.error?.symbol == "EACCES" && failing.counts == [1,1])
            traceFacts.append(facts("remember-failure", failed)); checks.append("Failed Remember preserves the numeric OS cause while a session selection remains available")

            let invalid = await access.acceptChosenFolder(URL(string:"https://invalid.example/PRIVATE-INPUT-SENTINEL")!)
            let blocked = try await newTrace(service,seen: &seen)
            try require(invalid == nil && blocked.map(\.phase) == [.requested,.blocked])
            traceFacts.append(facts("refused-input",blocked)); checks.append("Refused input records no scope or persistence activity")

            let acquisitionGate = Gate(); gates.append(acquisitionGate)
            let delayed = Backend(acquisition: acquisitionGate), cancelling = FolderAccessController(backend: delayed)
            let acquisition = Task { await cancelling.acceptChosenFolder(folder) }; active = acquisition
            try require(await Task.detached { acquisitionGate.waitUntilEntered() }.value)
            acquisition.cancel(); try await Task.sleep(for: .milliseconds(25))
            let waitingEvents = try await latestTrace(service,seen: seen)
            try require(!waitingEvents.contains { $0.phase == .cancelled || $0.phase == .completed })
            acquisitionGate.release(); try require(await acquisition.value == nil); active = nil
            let cancelled = try await newTrace(service,seen: &seen)
            try require(cancelled.last?.phase == .cancelled && delayed.counts == [1,1] && !acquisitionGate.timedOut)
            traceFacts.append(facts("cancel-acquisition",cancelled)); checks.append("Cancellation waits for held acquisition and scope drain before its terminal event")

            let commitGate = Gate(); gates.append(commitGate)
            let committedBackend = Backend(), state = admitted.appendingPathComponent("state/late-cancel")
            let committing = FolderAccessController(stateDirectory: state,backend: committedBackend)
            committing.rememberedCommitHookForQualification = { commitGate.pause() }
            let committingTask = Task { await committing.acceptChosenFolder(folder,remember: true) }; active = committingTask
            try require(await Task.detached { commitGate.waitUntilEntered() }.value)
            committingTask.cancel(); committing.invalidatePendingRequests()
            let heldCommit = try await latestTrace(service,seen: seen)
            try require(heldCommit.contains { $0.phase == .completed && $0.context?.checkpoint == .folderBookmark }
                && !heldCommit.contains { $0.context?.checkpoint == .folderAccessPublication })
            commitGate.release(); try require(await committingTask.value == nil); active = nil
            let late = try await newTrace(service,seen: &seen)
            let restored = await FolderAccessController(stateDirectory: state,backend: committedBackend).resolveRememberedFolders()
            try require(late.last?.phase == .cancelled && late.last?.context?.checkpoint == .folderAccessPublication
                && restored.count == 1 && committedBackend.counts == [1,1] && !commitGate.timedOut)
            traceFacts.append(facts("cancel-after-commit",late)); checks.append("A cancelled presentation preserves the acknowledged bookmark and confirms it on a fresh restore")

            for title in ["Generated A","Generated B"] {
                let control = AsyncControl(folder: folder), button = NSButton(title:title,target:nil,action:nil)
                asyncControls.append(control); button.target = control; button.action = #selector(AsyncControl.fire(_:))
                button.performClick(nil)
                try await wait { control.pending }
                try require(control.expected != nil && ApplicationDiagnostics.shared.currentTrace == nil)
            }
            try require(asyncControls[0].expected != asyncControls[1].expected)
            for control in asyncControls.reversed() { control.resume(); await control.task?.value }
            let interleaved = try await allEvents(service)
            for control in asyncControls {
                try require(control.observed == control.expected)
                let rows = interleaved.filter { $0.trace == control.expected && $0.action == .folderAccess }
                try require(rows.filter { $0.phase == .requested }.count == 1 && rows.last?.phase == .completed)
                traceFacts.append(facts("async-command",rows))
            }
            try require(ApplicationDiagnostics.shared.currentTrace == nil)
            checks.append("Two native actions resume in reverse order with their own inherited trace and no global correlation leak")

            for blockedSave in [false,true] {
                let settings = blockedSave
                    ? BrowserSettings(persist: false,persistenceFile: admitted.appendingPathComponent("source/Blocker/preferences.json"),skipDiskRead: true)
                    : BrowserSettings(persist: false)
                let browser = BrowserViewController(settings: settings)
                browser.folderAccess = FolderAccessController(backend: Backend())
                let model = TraverseSetupModel(browser: browser); model.window = host
                model.page = 1; model.chooseStartup(.computer)
                try await wait { !model.changingStartup }
                model.page = 4; model.finish()
                try await wait { !model.finishing }
                try require(settings.initialSetupCompleted == !blockedSave)
                model.close(); await settings.drainPreferencesForVerification()
            }
            let events = try await allEvents(service)
            for checkpoint in [DiagnosticCheckpoint.setupStartup,.setupFinish] {
                let requests = events.filter { $0.action == .onboarding && $0.context?.checkpoint == checkpoint && $0.phase == .requested }
                try require(requests.count == 2)
                let outcomes = requests.map { request in events.filter { $0.trace == request.trace }.sorted { $0.uptimeNanoseconds < $1.uptimeNanoseconds } }
                try require(outcomes.contains { $0.map(\.phase) == [.requested,.committing,.completed] }
                    && outcomes.contains { $0.map(\.phase) == [.requested,.committing,.failed] && $0.last?.error != nil })
            }
            checks.append("Setup startup/completion log acknowledged success and actual failed saves with their trace intact")
            try require(events.contains { $0.context?.checkpoint == .setupPage && $0.count == 5 }
                && events.contains { $0.context?.checkpoint == .setupWindow && $0.phase == .finished })
            checks.append("Setup page and window lifetime use bounded numeric state without page text")
            let destination = admitted.appendingPathComponent("evidence/access-log-export.jsonl")
            let outcome = await service.export(to: destination,retainingAccess: "Generated diagnostic export destination only")
            guard case let .saved(records,_,incomplete) = outcome else { throw Failure.scope }
            let exported = try await Task.detached { try Data(contentsOf: destination) }.value
            let text = String(decoding:exported,as:UTF8.self)
            try require(records == events.count && !incomplete && !text.contains("PRIVATE-") && !text.contains(admitted.path)
                && !text.contains(folder.absoluteString) && !text.contains(Data(folder.absoluteString.utf8).base64EncodedString())
                && !text.contains("private-error-message") && !text.contains("invalid.example"))
            checks.append("Actual export preserves engineering stages but excludes path/input/error-description sentinels")
            try require(ApplicationFileActivity.gate.activeCount == 0 && service.status.dropped == 0 && service.status.failure == nil)
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }
            failureType = String(reflecting:type(of:error))
        }
        active?.cancel(); gates.forEach { $0.release() }
        if let active { _ = await active.value }
        for control in asyncControls { control.resume(); await control.task?.value }
        window?.close(); ApplicationDiagnostics.shared.configureForVerification(nil)
        await logger?.closeAndDrain()
        if let root {
            let report: [String: Any] = ["passed":failure == nil,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":failureType.map { $0 as Any } ?? NSNull(),
                "checks":checks,"traceFacts":traceFacts,"activityDrained":ApplicationFileActivity.gate.activeCount == 0,"personalGrants":0,"networkRequests":0]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                .write(to:root.appendingPathComponent("evidence/native-setup-access-diagnostics.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func allEvents(_ service: DiagnosticRecorder) async throws -> [DiagnosticEvent] {
        await service.flush()
        var events: [DiagnosticEvent] = [], cursor: DiagnosticHistoryCursor?
        repeat {
            let page = try await service.page(before:cursor,limit:256)
            try require(!page.incomplete && events.count < 1024)
            events += page.events; cursor = page.next
        } while cursor != nil
        return events.sorted { $0.uptimeNanoseconds < $1.uptimeNanoseconds }
    }
    private static func latestTrace(_ service: DiagnosticRecorder,seen: Set<UUID>) async throws -> [DiagnosticEvent] {
        let events = try await allEvents(service)
        let requested = events.filter { $0.action == .folderAccess && $0.phase == .requested && !seen.contains($0.trace) }
        try require(requested.count == 1)
        return events.filter { $0.trace == requested[0].trace }
    }
    private static func newTrace(_ service: DiagnosticRecorder,seen: inout Set<UUID>) async throws -> [DiagnosticEvent] {
        let events = try await latestTrace(service,seen:seen)
        guard let trace = events.first?.trace else { throw Failure.scope }; seen.insert(trace); return events
    }
    private static func facts(_ label: String,_ events: [DiagnosticEvent]) -> [String: Any] {
        ["control":label,"trace":events.first?.trace.uuidString ?? "missing",
         "stages":events.map { ["phase":$0.phase.rawValue,"checkpoint":$0.context?.checkpoint.rawValue ?? "missing","errorCode":$0.error.map { $0.code as Any } ?? NSNull()] }]
    }
    private final class Gate: @unchecked Sendable {
        private let started = DispatchSemaphore(value:0), finish = DispatchSemaphore(value:0), lock = NSLock()
        private var timeout = false
        var timedOut: Bool { lock.withLock { timeout } }
        func pause() { started.signal(); if finish.wait(timeout:.now()+5) != .success { lock.withLock { timeout = true } } }
        func release() { finish.signal() }
        func waitUntilEntered() -> Bool { started.wait(timeout:.now()+4) == .success }
    }
    private final class Backend: FolderAccessBackend, @unchecked Sendable {
        private let lock = NSLock(), failBookmark: Bool, acquisition: Gate?
        private var starts = 0, stops = 0
        init(failBookmark: Bool = false,acquisition: Gate? = nil) { self.failBookmark = failBookmark; self.acquisition = acquisition }
        var counts: [Int] { lock.withLock { [starts,stops] } }
        func startAccess(to url: URL) -> Bool { lock.withLock { starts += 1 }; acquisition?.pause(); return true }
        func stopAccess(to url: URL) { lock.withLock { stops += 1 } }
        func bookmark(for url: URL) throws -> Data {
            if failBookmark { throw NSError(domain:NSPOSIXErrorDomain,code:Int(EACCES),userInfo:[NSLocalizedDescriptionKey:"private-error-message",NSFilePathErrorKey:url.path]) }
            return Data(url.absoluteString.utf8)
        }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
            guard let raw = String(data:bookmark,encoding:.utf8),let url = URL(string:raw),url.isFileURL else { throw Failure.scope }
            return .init(url:url,isStale:false)
        }
    }
    @MainActor private final class AsyncControl: NSObject {
        private let folder: URL, access = FolderAccessController(backend: Backend())
        private var continuation: CheckedContinuation<Void,Never>?
        private(set) var expected: UUID?, observed: UUID?, task: Task<Void,Never>?
        var pending: Bool { continuation != nil }
        init(folder: URL) { self.folder = folder }
        @objc func fire(_ sender: Any?) {
            expected = ApplicationDiagnostics.shared.currentTrace
            task = Task { @MainActor in
                await withCheckedContinuation { continuation = $0 }
                observed = ApplicationDiagnostics.shared.currentTrace
                let choice = await access.acceptChosenFolder(folder)
                choice?.lease.close()
            }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
}
#endif
