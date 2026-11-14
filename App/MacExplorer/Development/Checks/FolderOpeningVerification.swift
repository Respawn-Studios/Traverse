#if DEBUG
import AppKit
import Darwin
import SwiftUI

private actor GeneratedFolderOpeningService: FolderOpeningService {
    enum Mode: Equatable { case adopt, decline, fail, ignore, readbackFailure }
    var observed: FolderOpeningApplication?
    var mode: Mode = .adopt
    var reads = 0, requests: [URL] = []
    var holdRead = false, holdRequest = false, failRead = false
    private var readContinuation: CheckedContinuation<FolderOpeningApplication?, Error>?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    init(_ observed: FolderOpeningApplication?) { self.observed = observed }
    func current() async throws -> FolderOpeningApplication? {
        reads += 1
        if holdRead {
            holdRead = false
            return try await withCheckedThrowingContinuation { readContinuation = $0 }
        }
        if failRead || (mode == .readbackFailure && !requests.isEmpty) { throw FolderOpeningFailure.unavailable }
        return observed
    }
    func request(application: URL) async throws {
        requests.append(application)
        if holdRequest { holdRequest = false; await withCheckedContinuation { requestContinuation = $0 } }
        switch mode {
        case .adopt, .readbackFailure: observed = .init(url: application, name: application.deletingPathExtension().lastPathComponent)
        case .decline: throw FolderOpeningFailure.declined
        case .fail: throw FolderOpeningFailure.failed
        case .ignore: break
        }
    }
    func configure(_ observed: FolderOpeningApplication?, mode: Mode = .adopt, failRead: Bool = false) {
        self.observed = observed; self.mode = mode; self.failRead = failRead
    }
    func holdNextRead() { holdRead = true }
    func holdNextRequest() { holdRequest = true }
    var readHeld: Bool { readContinuation != nil }
    var requestHeld: Bool { requestContinuation != nil }
    func releaseRead() { let held = readContinuation; readContinuation = nil; held?.resume(returning: observed) }
    func releaseRequest() { let held = requestContinuation; requestContinuation = nil; held?.resume() }
}

@MainActor enum FolderOpeningVerification {
    @MainActor private final class Pulse {
        var previous = CACurrentMediaTime(), gap = 0.0, ticks = 0
        var stage = "model-controls", maximumGapStage = ""
        func tick() {
            let now = CACurrentMediaTime(), elapsed = now - previous
            if elapsed > gap { gap = elapsed; maximumGapStage = stage }
            previous = now; ticks += 1
        }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"), root.resolvingSymlinksInPath() == root,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["action"] as? String == "traverse-folder-opener" else { exit(2) }
        let pulse = Pulse(), timer = Timer(timeInterval: 0.016, repeats: true) { _ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, pulse: pulse, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        timer.invalidate(); var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        metrics["maximumGapStage"] = pulse.maximumGapStage
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native memory gate failed") }
        if pulse.gap > 0.4 || pulse.ticks < 10 { failures.append("Native responsiveness gate failed") }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures, "metrics": metrics,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": pulse.gap,
            "systemSetterCalls": 0, "generatedOnly": true, "ordinaryActivation": false, "bodyReads": false,
            "network": false, "clipboard": false, "actualSystemConsent": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, pulse: Pulse, checks: inout [String], metrics: inout [String: Any]) async throws {
        let previous = FolderOpeningApplication(url: root.appendingPathComponent("source/Previous Files.app"), name: "Previous Files")
        let target = root.appendingPathComponent("source/Traverse.app")
        let service = GeneratedFolderOpeningService(previous)
        let model = FolderOpeningPreferenceModel(service: service, application: target)
        model.open(); await model.drain()
        try UIVerification.require(model.outcome == .other && model.canRequest && model.current == previous, "Initial handler observation failed")
        try UIVerification.require(await service.requests.isEmpty, "Opening a preference made a request")
        guard let stale = model.proposal() else { throw UIVerification.Failure(message: "Initial proposal missing") }
        model.close(); model.open(); await model.drain()
        try UIVerification.require(!model.confirm(stale), "Stale presentation confirmation was admitted")
        await service.configure(nil); model.refresh(); await model.drain()
        try UIVerification.require(model.outcome == .unavailable && !model.canRequest && model.proposal() == nil, "Unknown handler was presented as a choice")
        await service.configure(previous, failRead: true); model.refresh(); await model.drain()
        try UIVerification.require(model.current == nil && model.outcome == .unavailable, "Failed read kept stale handler authority")
        checks.append("Opening/refreshing makes no setter request; unknown/failed reads and stale-presentation confirmation refuse")

        for (mode, expected) in [(GeneratedFolderOpeningService.Mode.adopt, FolderOpeningPreferenceModel.Outcome.current),
            (.decline, .declined), (.fail, .failed), (.ignore, .unverified), (.readbackFailure, .unverified)] {
            let peer = GeneratedFolderOpeningService(previous); await peer.configure(previous, mode: mode)
            let current = FolderOpeningPreferenceModel(service: peer, application: target)
            current.open(); await current.drain()
            guard let proposal = current.proposal() else { throw UIVerification.Failure(message: "Fresh proposal missing") }
            try UIVerification.require(current.confirm(proposal) && !current.confirm(proposal), "Concurrent duplicate confirmation was admitted")
            await current.drain()
            let requested = await peer.requests
            try UIVerification.require(current.outcome == expected && requested == [target], "Request/readback outcome or exact bundle target differs")
            try UIVerification.require(!current.confirm(proposal), "Consumed confirmation was replayable")
            current.close(); await current.drain()
        }
        checks.append("Exact target, success/readback, system decline, failed setter, wrong readback and failed readback stay distinct; confirmations are single-use")

        let durableSettings = BrowserSettings(persist: false)
        let durablePeer = GeneratedFolderOpeningService(previous)
        let durable = FolderOpeningPreferenceModel(service: durablePeer, application: target, settings: durableSettings)
        durable.open(); await durable.drain()
        guard let durableProposal = durable.proposal() else { throw UIVerification.Failure(message: "Durable proposal missing") }
        try UIVerification.require(durable.confirm(durableProposal), "Durable proposal was refused")
        await durable.drain()
        let restoredPreferences = BrowserSettings(persist: false, restoredData: try durableSettings.encodedSnapshot())
        try UIVerification.require(durable.isCurrent && durable.canRestore
            && restoredPreferences.previousFolderApplication == previous.url,
            "Exact previous application did not survive the preference contract")
        durable.restorePrevious(); await durable.drain()
        let durableRequests = await durablePeer.requests
        try UIVerification.require(durable.current == previous && durableSettings.previousFolderApplication == nil
            && durableRequests == [target, previous.url], "Previous handler restore changed its target or did not confirm completion")
        durable.close()
        let blockedSettings = BrowserSettings(persist: false, restoredData: Data(#"{"version":999}"#.utf8))
        let blockedPeer = GeneratedFolderOpeningService(previous)
        let blocked = FolderOpeningPreferenceModel(service: blockedPeer, application: target, settings: blockedSettings)
        blocked.open(); await blocked.drain()
        guard let blockedProposal = blocked.proposal() else { throw UIVerification.Failure(message: "Blocked persistence proposal missing") }
        _ = blocked.confirm(blockedProposal); await blocked.drain()
        try UIVerification.require(await blockedPeer.requests.isEmpty, "Failed recovery-preference save still changed the system handler")
        blocked.close()
        checks.append("Exact previous app survives preference encoding, confirmed restore clears it, and a refused recovery save prevents any setter")

        await service.configure(previous); model.refresh(); await model.drain()
        guard let changed = model.proposal() else { throw UIVerification.Failure(message: "External-change proposal missing") }
        await service.configure(.init(url: root.appendingPathComponent("source/Third Files.app"), name: "Third Files"))
        try UIVerification.require(model.confirm(changed), "Fresh confirmation admission failed")
        await model.drain()
        let afterExternalChange = await service.requests
        try UIVerification.require(model.outcome == .changedElsewhere && afterExternalChange.isEmpty, "External default change was silently overwritten")
        checks.append("Preflight rejects an externally changed handler without requesting a system change")

        await service.configure(previous); model.refresh(); await model.drain()
        await service.holdNextRead(); let before = await service.reads
        model.refresh()
        try await wait("Held read missing") { await service.readHeld }
        for _ in 0..<40 { model.refresh() }
        await service.releaseRead(); await model.drain()
        try UIVerification.require(await service.reads == before + 2, "Refreshes were not one active plus one latest")
        await service.holdNextRead()
        guard let closing = model.proposal(), model.confirm(closing) else { throw UIVerification.Failure(message: "Held preflight admission missing") }
        try await wait("Held preflight missing") { await service.readHeld }
        model.close()
        try UIVerification.require(model.current == nil && model.phase == .requesting, "Close released actual work prematurely")
        await service.releaseRead(); await model.drain()
        try UIVerification.require(await service.requests.isEmpty, "Closed preflight still submitted a system request")
        model.open(); await model.drain()
        await service.holdNextRequest()
        guard let reopening = model.proposal(), model.confirm(reopening) else { throw UIVerification.Failure(message: "Held request admission missing") }
        try await wait("Held request missing") { await service.requestHeld }
        model.close(); model.open()
        try UIVerification.require(model.current == nil && model.phase == .requesting, "Reopen invented completed adoption")
        await service.releaseRequest(); await model.drain()
        let afterReopening = await service.requests
        try UIVerification.require(model.outcome == .current && model.phase == .idle && afterReopening == [target], "Request close/reopen did not retain actual work and reobserve")
        checks.append("Held preflight/actual request, close/reopen, stale publication, forty refresh coalescing and real drain pass")
        model.close(); await model.drain()

        let native = NativeFolderOpeningService()
        try UIVerification.require(!FolderOpeningFeature.ordinaryEnabled, "Unaccepted global setter is enabled")
        let observed = try await native.current()
        metrics["publicReadOnlyHandlerObserved"] = observed != nil
        do { try await native.request(application: target); throw UIVerification.Failure(message: "Production setter gate failed") }
        catch FolderOpeningFailure.notQualified { }
        checks.append("One real public read-only handler observation completes; disabled production setter refuses before system submission")

        let settings = BrowserSettings(persist: false)
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true; settings.motion.mode = .off
        let shownService = GeneratedFolderOpeningService(previous)
        let shown = FolderOpeningPreferenceModel(service: shownService, application: target)
        pulse.stage = "native-window-construction"
        let window = NSWindow(contentRect: .init(x: 100, y: 120, width: 960, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let view = VStack(alignment: .leading, spacing: 22) {
            Text("Folder opening").font(.largeTitle.bold())
            Text("Generated review · simulated changes only").font(.caption).foregroundStyle(.secondary)
            GroupBox { FolderOpeningPreferenceView(model: shown, onRequest: { [weak window] in
                if let window { FolderOpeningConfirmation.present(model: shown, window: window) }
            }).padding(14) }
            Spacer()
        }.padding(26)
        // The review has a fixed AppKit frame. Do not let a transient proposed
        // SwiftUI fitting size become this window's persistent content minimum.
        let hosting = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false; window.title = "Folder opening · generated review"
        _ = ToolWindowChrome.install(in: window, settings: settings)
        // The recorder bounds the whole frame, not the content rectangle plus
        // its title bar. Keep its existing capture/privacy limit unchanged.
        window.setFrame(.init(x: 100, y: 120, width: 960, height: 640), display: true)
        window.makeKeyAndOrderFront(nil); shown.open(); await shown.drain()
        let backdrop = GlassVerification.makeBrowserBackdropWindow(behind: window)
        defer { shown.close(); window.close(); backdrop.close() }
        // Separate actual user actions by a sampled common-mode presentation
        // turn. Do not combine construction + begin/end + another begin in one
        // impossible zero-turn gesture; the unmodified gap gate stays active.
        let windowTick = pulse.ticks
        try await wait("Initial presentation turn missing") { pulse.ticks > windowTick }
        metrics["initialReviewFrame"] = ["width": window.frame.width, "height": window.frame.height]
        pulse.stage = "native-cancel-sheet-begin"
        try UIVerification.require(FolderOpeningConfirmation.present(model: shown, window: window)
            && !FolderOpeningConfirmation.present(model: shown, window: window), "Native duplicate confirmation appeared")
        guard let sheet = window.attachedSheet else { throw UIVerification.Failure(message: "Actual confirmation sheet missing") }
        let sheetTick = pulse.ticks
        try await wait("Cancel sheet presentation turn missing") { pulse.ticks > sheetTick }
        pulse.stage = "native-cancel-sheet-end"
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let cancelledTick = pulse.ticks
        try await wait("Cancel did not dismiss") { window.attachedSheet == nil && pulse.ticks > cancelledTick }
        try UIVerification.require(await shownService.requests.isEmpty, "Cancel made a request")
        pulse.stage = "native-continue-sheet-begin"
        try UIVerification.require(FolderOpeningConfirmation.present(model: shown, window: window), "Second confirmation missing")
        guard let accepted = window.attachedSheet else { throw UIVerification.Failure(message: "Continue sheet missing") }
        let acceptedTick = pulse.ticks
        try await wait("Continue sheet presentation turn missing") { pulse.ticks > acceptedTick }
        pulse.stage = "native-continue-sheet-end"
        window.endSheet(accepted, returnCode: .alertFirstButtonReturn)
        try await wait("Continue did not submit exact request") { await shownService.requests == [target] }
        await shown.drain()
        try UIVerification.require(shown.isCurrent, "Native confirmation did not bind to current proposal")
        checks.append("Actual native sheet permits one confirmation, Cancel makes no request and Continue uses the exact generated target")

        pulse.stage = "shared-motion-review"
        metrics["reviewFrame"] = ["width": window.frame.width, "height": window.frame.height]
        try UIVerification.require(window.frame.width <= 960 && window.frame.height <= 640, "Review frame exceeds unchanged recorder bounds")
        guard let chrome = window.contentViewController as? ToolWindowChrome else { throw UIVerification.Failure(message: "Shared glass chrome missing") }
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode; await shownService.configure(previous); shown.refresh(); await shown.drain()
            try await Task.sleep(for: .milliseconds(350))
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                let recording = try await NativeMotionRecorder.record(window: window, root: root, label: "folder-opening-" + mode.rawValue) {
                    ToolContentMotion.reveal(chrome.contentHost, effect: .pages)
                }
                try JSONEncoder().encode(recording).write(to: root.appendingPathComponent("evidence/folder-opening-" + mode.rawValue + ".json"), options: .withoutOverwriting)
            } else { ToolContentMotion.reveal(chrome.contentHost, effect: .pages) }
        }
        shown.close(); await shown.drain()
        checks.append("Shared glass native preference remains readable through Full/Reduced/Off review and close/drain")
    }
    private static func wait(_ message: String, _ condition: () async -> Bool) async throws {
        let end = CACurrentMediaTime() + 10
        while !(await condition()) {
            try UIVerification.require(CACurrentMediaTime() < end, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
