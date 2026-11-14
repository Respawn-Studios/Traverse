#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum ArchivePaneDestinationVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ordinary = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
        guard ordinary || root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath() == root,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["action"] as? String == "traverse-archive-pane-destination",
              !ordinary || marker["packet"] as? String == "traverse-development-v1" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.motion.mode = .off
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
        if ProcessInfo.processInfo.arguments.contains("--large-interface") {
            settings.interfaceSize = .init(150); settings.appearance = .light
        }
        InterfacePresentation.shared.bind(settings)
        let owner = BrowserWindowController(settings: settings)
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, owner: owner, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics, "generatedOnly": true, "networkRequests": 0, "personalFiles": 0,
            "ordinaryOpenPaneEnabled": ArchivePaneDestinationActivation.enabled,
            "nativeActionNotPhysicalInput": true, "osGrantAcceptance": false,
            "drained": ApplicationFileActivity.gate.activeCount == 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }

    private static func verify(root: URL, owner: BrowserWindowController, checks: inout [String], metrics: inout [String: Any]) async throws {
        guard let window = owner.window else { throw UIVerification.Failure(message: "Generated pane window missing") }
        // Two 400-point native panes plus the real sidebar need >1,001 points.
        // Only the separate extraction window is the recorder's bounded target.
        let large = ProcessInfo.processInfo.arguments.contains("--large-interface")
        window.setFrame(.init(x: 100, y: 130, width: large ? 1620 : 1140, height: large ? 880 : 760), display: true)
        window.title = "ZIP destinations · generated review"
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); owner.beginBrowsing()
        let workspace = owner.workspace, browser = owner.browser
        try UIVerification.require(owner.isWorkspacePresentation && workspace.isViewLoaded,
            "This control requires the actual native workspace composition")
        browser.permitsBackgroundVerification = true
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        let engine = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/history"))
        browser.recoverableFileOperations = engine
        let source = root.appendingPathComponent("source/Source/Generated.zip")
        let destination = root.appendingPathComponent("source/Destination")
        let alternative = root.appendingPathComponent("source/Alternative")
        try await wait { workspace.sessionReady }
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait { settled(browser) }
        try UIVerification.require(LocalPaneDestination.available(from: browser).isEmpty, "Single pane offered itself")
        try UIVerification.require(workspace.splitActive(at: .trailing), "Generated destination pane missing")
        var peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true
        peer.navigate(to: .directory(destination)); try await wait { settled(peer) }
        func tabTitleSizes(_ view: NSView) -> [CGFloat] {
            let own = (view as? NSButton).flatMap { button in
                button.accessibilityRole() == .radioButton ? button.font?.pointSize : nil
            }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap(tabTitleSizes)
        }
        let sourceSizes = tabTitleSizes(browser.tabStrip), peerSizes = tabTitleSizes(peer.tabStrip)
        try UIVerification.require(sourceSizes.count == 1 && peerSizes.count == 1
            && abs(sourceSizes[0] - peerSizes[0]) < 0.01,
            "A newly created pane did not inherit the existing tab's interface size")
        metrics["paneTabTitlePointSizes"] = [sourceSizes, peerSizes]
        if CGPreflightScreenCaptureAccess() {
            try await Task.sleep(for: .milliseconds(180))
            try await GlassVerification.captureOwnedWindow(window,
                to: root.appendingPathComponent("evidence/two-pane-layout.png"))
        }
        let backend = LeaseCounter()
        peer.folderAccess = FolderAccessController(backend: backend)
        let choice = await peer.folderAccess.acceptChosenFolder(destination)
        choice?.lease.close()
        workspace.activate(browser)
        try await wait { settled(browser) }

        func candidate() throws -> LocalPaneDestination {
            guard let value = LocalPaneDestination.available(from: browser).first(where: { $0.pane == peer.paneID }) else {
                throw UIVerification.Failure(message: "Current local pane not offered")
            }
            return value
        }
        func open(members: ZIPExtractionSelection? = nil) async throws -> ArchiveExtractionWindowController {
            ApplicationArchiveExtraction.shared.show(source: source, from: browser, members: members)
            guard let controller = ApplicationArchiveExtraction.shared.controller else {
                throw UIVerification.Failure(message: "Actual extraction review missing")
            }
            try await wait { !controller.model.isPreparing && (controller.model.plan != nil
                || controller.model.notice != "Checking the archive and destination…") }
            try UIVerification.require(controller.model.plan != nil,
                "Extraction preparation refused: " + controller.model.notice)
            return controller
        }
        func choose(_ model: ArchiveExtractionModel) async throws {
            model.chooseDestination(try candidate())
            try await wait { !model.isChoosing && !model.isPreparing && model.plan != nil && model.parent == destination }
        }

        let initial = try await open(), model = initial.model
        try UIVerification.require(model.openPaneDestinations.count == 1 && model.parent == source.deletingLastPathComponent(),
            "Pane shortcut changed the initial destination")
        for change in 0..<3 {
            let stale = try candidate()
            if change == 0 { peer.refresh(nil) }
            else if change == 1 { peer.newTab(nil) }
            else { peer.navigate(to: .directory(alternative)) }
            model.chooseDestination(stale)
            try UIVerification.require(!model.isChoosing && model.parent == source.deletingLastPathComponent(),
                "A stale destination visit/tab/path was admitted")
            // Target the peer tab itself. The general Command-W action
            // correctly closes the key tool window when one is in front.
            if change == 1 { peer.closeTab(id: peer.activeID) }
            peer.navigate(to: .directory(destination)); try await wait { settled(peer) }
        }
        metrics["acquisitionAdmission"] = ["canReview": model.canReview, "preparing": model.isPreparing,
            "choosing": model.isChoosing, "running": model.isRunning,
            "hasOutcome": model.outcome != nil, "activeOwner": browser.operationCoordinator.activeOwner != nil,
            "preparationOwner": browser.operationCoordinator.preparationOwner != nil,
            "queueExclusive": browser.operationCoordinator.transfers.canRunExclusiveCommand,
            "gateClosed": ApplicationFileActivity.gate.isClosed, "notice": model.notice] as [String: Any]
        try UIVerification.require(model.canReview, "Generated review cannot admit the held acquisition")
        let held = Hold()
        defer { held.release() }
        let browsingLeaseBaseline = backend.active
        model.destinationAcquiredForQualification = { await held.pause() }
        model.chooseDestination(try candidate())
        try await wait { held.entered }
        try UIVerification.require(model.isChoosing && backend.active == browsingLeaseBaseline + 1,
            "Actual destination lease was not retained independently of the browser's live listing")
        peer.navigate(to: .directory(alternative)); held.release()
        try await wait { !model.isChoosing }
        model.destinationAcquiredForQualification = nil
        try UIVerification.require(model.parent == source.deletingLastPathComponent() && backend.active == 0,
            "An asynchronously stale pane changed the destination or leaked its lease")
        peer.navigate(to: .directory(destination)); try await wait { settled(peer) }
        checks.append("Single/stale visit/tab/path and changes during actual access acquisition refuse without changing the review")

        workspace.activate(peer)
        try UIVerification.require(workspace.splitActive(at: .bottom), "Third pane missing")
        let third = workspace.activeBrowser
        third.permitsBackgroundVerification = true
        third.navigate(to: .directory(alternative)); try await wait { settled(third) }
        workspace.activate(browser)
        try UIVerification.require(model.openPaneDestinations.count == 2, "Multiple local panes were not separately offered")
        third.navigate(to: .smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Generated offline destination")))
        try await wait { settled(third) }
        try UIVerification.require(model.openPaneDestinations.count == 1, "A remote pane was offered to local extraction")
        workspace.activate(third); _ = workspace.closeActivePane(); workspace.activate(browser)
        checks.append("Multiple targets keep their own pane/folder identity; remote locations are excluded without a connection")

        if ProcessInfo.processInfo.arguments.contains("--record-motion"), let review = initial.window {
            review.title = "ZIP destination · generated review"
            review.setFrame(.init(x: 150, y: 140, width: 820, height: 550), display: true)
            review.makeKeyAndOrderFront(nil)
            for mode in BrowserMotionMode.allCases {
                browser.settings.motion.mode = .off
                peer.navigate(to: .directory(alternative)); try await wait { settled(peer) }
                model.chooseDestination(try candidate())
                try await wait { !model.isChoosing && !model.isPreparing && model.parent == alternative && model.plan != nil }
                peer.navigate(to: .directory(destination)); try await wait { settled(peer) }
                browser.settings.motion.mode = mode
                let target = try candidate()
                let report = try await NativeMotionRecorder.record(window: review, root: root, label: "archive-pane-" + mode.rawValue) {
                    model.chooseDestination(target)
                }
                try await wait { !model.isChoosing && !model.isPreparing && model.parent == destination && model.plan != nil }
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/archive-pane-" + mode.rawValue + ".json"), options: .withoutOverwriting)
            }
            checks.append("Actual destination changes recorded in Full/Reduced/Off without retaining an outgoing page")
        }
        browser.settings.motion.mode = .off
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        try UIVerification.require(backend.active == browsingLeaseBaseline, "Closing a review retained the chosen pane lease")
        let cancelledNames = try await names(destination)
        try UIVerification.require(cancelledNames == ["Existing"] && !FileManager().fileExists(atPath: root.appendingPathComponent("state/history").path),
            "Destination selection or Cancel wrote an output/history")
        checks.append("Choosing a destination and cancelling create no extracted files or operation history")

        let whole = try await open(), wholeModel = whole.model
        try await choose(wholeModel)
        wholeModel.name = "Existing"
        try await wait { !wholeModel.isPreparing && !wholeModel.notice.hasPrefix("Checking the archive") }
        let conflictNames = try await names(destination)
        try UIVerification.require(wholeModel.plan == nil && !wholeModel.canExtract && conflictNames == ["Existing"],
            "An existing output folder was accepted or modified")
        wholeModel.name = "Whole archive"
        try await wait { !wholeModel.isPreparing && wholeModel.plan != nil }
        guard let wholePlan = wholeModel.plan else { throw UIVerification.Failure(message: "Whole extraction plan missing") }
        peer.navigate(to: .directory(alternative)); try await wait { settled(peer) }
        workspace.activate(peer); _ = workspace.closeActivePane(); workspace.activate(browser)
        try UIVerification.require(backend.active == 1 && wholeModel.parent == destination && wholeModel.canExtract,
            "Closing a pane withdrew the already reviewed fixed destination/access")
        wholeModel.extract()
        try await wait { !wholeModel.isRunning && wholeModel.outcome != nil && browser.operationTask == nil }
        try UIVerification.require(wholeModel.outcome?.result.disposition == .succeeded && wholeModel.canUndo,
            "Whole ZIP extraction to the captured pane failed")
        let wholeHashes = try await hashes(wholePlan.destination)
        try JSONSerialization.data(withJSONObject: wholeHashes, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/whole-output.json"), options: .withoutOverwriting)
        try UIVerification.require(!(try await names(alternative)).contains("Whole archive"), "Pane navigation redirected accepted extraction")
        wholeModel.undo(); try await wait { wholeModel.undoOutcome != nil && !wholeModel.isRunning && browser.operationTask == nil }
        try UIVerification.require(wholeModel.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath: wholePlan.destination.path),
            "Exact extraction Undo failed")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        try UIVerification.require(backend.active == 0, "Actual extraction/Undo/close failed to balance destination access")
        metrics["destinationLeaseStarts"] = backend.starts; metrics["destinationLeaseStops"] = backend.stops
        checks.append("Conflict refuses; a chosen folder/access survives pane navigation/close; whole extraction and exact Undo succeed")

        try UIVerification.require(workspace.splitActive(at: .trailing), "Selected extraction peer missing")
        peer = workspace.activeBrowser; peer.permitsBackgroundVerification = true
        peer.navigate(to: .directory(destination)); try await wait { settled(peer) }; workspace.activate(browser)
        peer.folderAccess = FolderAccessController(backend: backend)
        let secondChoice = await peer.folderAccess.acceptChosenFolder(destination)
        secondChoice?.lease.close()
        ApplicationZIPBrowser.shared.show(source, from: browser)
        guard let archive = ApplicationZIPBrowser.shared.controller?.model else { throw UIVerification.Failure(message: "ZIP browser missing") }
        try await wait { !archive.isLoading && !archive.isPaging && archive.page != nil }
        guard let selected = archive.page?.items.first(where: { $0.path == "Selected" }) else { throw UIVerification.Failure(message: "Generated member missing") }
        archive.selection = [selected.id]; archive.extractSelected()
        try await wait { !archive.isPreparingSelection && ApplicationArchiveExtraction.shared.controller != nil }
        guard let selectedModel = ApplicationArchiveExtraction.shared.controller?.model else { throw UIVerification.Failure(message: "Selected review missing") }
        try await wait { !selectedModel.isPreparing && selectedModel.plan != nil }
        try await choose(selectedModel)
        guard let selectedPlan = selectedModel.plan else { throw UIVerification.Failure(message: "Selected plan missing") }
        selectedModel.extract(); try await wait { !selectedModel.isRunning && selectedModel.outcome != nil && browser.operationTask == nil }
        try UIVerification.require(selectedModel.outcome?.result.disposition == .succeeded && selectedModel.canUndo,
            "Selected member extraction to the pane failed")
        let selectedHashes = try await hashes(selectedPlan.destination)
        try JSONSerialization.data(withJSONObject: selectedHashes, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/selected-output.json"), options: .withoutOverwriting)
        selectedModel.undo(); try await wait { !selectedModel.isRunning && selectedModel.undoOutcome != nil }
        try UIVerification.require(selectedModel.undoOutcome?.result.disposition == .succeeded, "Selected pane extraction exact Undo failed")
        await ApplicationArchiveExtraction.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        checks.append("The actual ZIP browser selected-member action uses the same chosen destination and exact Undo")

        // The held acquisition is actual owned work. Closing waits for it even
        // when its caller has already cancelled further publication.
        let closing = try await open(), closingModel = closing.model, closeHold = Hold()
        defer { closeHold.release() }
        let closingBaseline = backend.active
        closingModel.destinationAcquiredForQualification = { await closeHold.pause() }
        closingModel.chooseDestination(try candidate()); try await wait { closeHold.entered }
        var returned = false
        let closeTask = Task { await ApplicationArchiveExtraction.shared.closeAndDrain(); returned = true }
        try await Task.sleep(for: .milliseconds(25))
        let early = returned
        closeHold.release(); await closeTask.value
        try UIVerification.require(!early && !closingModel.isChoosing && ApplicationArchiveExtraction.shared.controller == nil && backend.active == closingBaseline,
            "Close detached an actual destination acquisition or published a late destination")
        checks.append("Close waits for actual destination acquisition before retiring the review")

        // Regression through the shared destination rule's other real caller.
        workspace.activate(browser); try await wait { settled(browser) && settled(peer) }
        let copy = source.deletingLastPathComponent().appendingPathComponent("Copy.txt")
        browser.renderFilePresentation(selection: [copy]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        let queue = browser.operationCoordinator.transfers, before = Set(queue.results.map(\.id))
        try UIVerification.require(browser.canTransferToOtherPane, "Shared destination rule disabled eligible pane Copy")
        browser.copyToOtherPane(nil)
        try await wait { !queue.hasOutstandingWork && queue.results.contains(where: { !before.contains($0.id) }) }
        guard let copied = queue.results.first(where: { !before.contains($0.id) }), let id = copied.outcome.recordID else {
            throw UIVerification.Failure(message: "Pane Copy regression has no exact result")
        }
        try UIVerification.require(copied.outcome.result.disposition == .succeeded, "Pane Copy regression failed")
        let undone = await engine.undo(recordID: id)
        try UIVerification.require(undone.result.disposition == .succeeded, "Pane Copy regression Undo failed")
        guard let wholeID = wholeModel.outcome?.recordID, let selectedID = selectedModel.outcome?.recordID else {
            throw UIVerification.Failure(message: "Extraction lost its exact history identity")
        }
        var retained: [[String: Any]] = []
        for (kind, operationID) in [("whole", wholeID), ("selected", selectedID), ("copy", id)] {
            let record = try await engine.retentionRecord(recordID: operationID)
            let heldTreeCleanup = ArchiveExtractionActivation.qualifiesPublicZIPTree && kind != "copy"
            try UIVerification.require(record.canCleanup == !heldTreeCleanup && record.areas.count == 1 && record.areas.allSatisfy {
                $0.verified == !heldTreeCleanup && $0.url.deletingLastPathComponent() == destination
            }, "Exact Undo recovery area did not verify through the ordinary inspector")
            retained.append(["kind": kind, "operation": operationID.uuidString,
                "area": record.areas[0].url.lastPathComponent, "verified": record.areas.allSatisfy(\.verified),
                "cleanupAvailable": record.canCleanup])
        }
        try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/retained-recovery.json"), options: .withoutOverwriting)
        try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.inspectionCount == 0 }
        peer.navigate(to: .directory(alternative)); try await wait { settled(peer) && backend.active == 0 }
        metrics["finalDestinationLeaseStarts"] = backend.starts; metrics["finalDestinationLeaseStops"] = backend.stops
        checks.append("Existing Copy to Other Pane and exact Undo still pass through the shared native intent rule")
    }

    private static func settled(_ browser: BrowserViewController) -> Bool {
        !browser.isLoading && browser.orderingTask == nil && browser.operationTask == nil && browser.operationPreparationTask == nil
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Generated open-pane extraction did not settle at line \(line)")
    }
    private static func names(_ parent: URL) async throws -> [String] {
        try await Task.detached { try FileManager().contentsOfDirectory(atPath: parent.path).sorted() }.value
    }
    private static func hashes(_ folder: URL) async throws -> [String: String] {
        try await Task.detached {
            var result: [String: String] = [:], pending = [folder]
            while let parent = pending.popLast() {
                for file in try FileManager().contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                    let facts = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if facts.isDirectory == true { pending.append(file) }
                    else if facts.isRegularFile == true {
                        let data = try Data(contentsOf: file)
                        guard data.count <= 1 << 20 else { throw UIVerification.Failure(message: "Generated output cap exceeded") }
                        result[String(file.path.dropFirst(folder.path.count + 1))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    } else { throw UIVerification.Failure(message: "Unexpected generated output") }
                }
            }
            return result
        }.value
    }
    @MainActor private final class Hold {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private final class LeaseCounter: FolderAccessBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, stopped = 0
        var starts: Int { lock.withLock { started } }
        var stops: Int { lock.withLock { stopped } }
        var active: Int { lock.withLock { started - stopped } }
        func startAccess(to url: URL) -> Bool { lock.withLock { started += 1 }; return true }
        func stopAccess(to url: URL) { lock.withLock { stopped += 1 } }
        func bookmark(for url: URL) throws -> Data { throw CancellationError() }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw CancellationError() }
    }
}
#endif
