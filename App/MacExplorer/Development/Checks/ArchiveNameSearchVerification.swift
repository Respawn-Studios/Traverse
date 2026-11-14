#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum ArchiveNameSearchVerification {
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
              root.resolvingSymlinksInPath().path == root.path, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["action"] as? String == "traverse-archive-search" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.folderSummariesEnabled = false; settings.motion.mode = .off; settings.navigationStyle = .glass
        settings.glassFileContent = true; settings.appearance = .dark
        let owner = BrowserWindowController(settings: settings)
        var failures: [String] = [], checks: [String] = [], metrics: [String: Any] = [:]
        var ticks = 0, maximumGap = 0.0
        let ticker = Task { @MainActor in
            var previous = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = CACurrentMediaTime(); maximumGap = max(maximumGap, now - previous); previous = now; ticks += 1
            }
        }
        do { try await verify(root: root, owner: owner, settings: settings, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        await ApplicationArchiveExtraction.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        ticker.cancel(); await ticker.value
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256 * 1024 * 1024 { failures.append("Native app exceeds256MiB") }
        if maximumGap > 0.4 || ticks < 10 { failures.append("Main-actor response gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual filesystem work remains") }
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures, "metrics": metrics,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": maximumGap, "ticks": ticks,
            "activityCount": ApplicationFileActivity.gate.activeCount, "generatedOnly": true,
            "metadataOnlyBrowsing": true, "explicitPreviewAndExtraction": true, "network": 0, "personalFiles": 0,
            "nativeActionsNotPhysicalInput": true]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, owner: BrowserWindowController, settings: BrowserSettings,
                               checks: inout [String], metrics: inout [String: Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation, "Archive test requires the actual workspace")
        owner.window?.setFrameOrigin(.init(x: -12000, y: -12000))
        let browser = owner.browser; browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("history"))
        owner.beginBrowsing()
        try await wait("workspace") { owner.workspace.sessionReady }
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait("generated source listing") { !browser.isLoading && browser.orderingTask == nil }
        let small = root.appendingPathComponent("source/Small.zip")
        ApplicationZIPBrowser.shared.show(small, from: browser)
        guard let controller = ApplicationZIPBrowser.shared.controller, let window = controller.window else { throw UIVerification.Failure(message: "Archive window missing") }
        let model = controller.model
        window.title = "Archive names · generated review"
        window.setFrame(.init(x: 100, y: 130, width: 960, height: 640), display: true)
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(.init(x: -12000, y: -12000)) }
        try await settled(model)
        try UIVerification.require(model.summary?.files == 604 && model.page?.items.count == 3, "Small generated archive is incomplete")
        if ProcessInfo.processInfo.arguments.contains("--preview-drain-control") {
            model.nameScope = .archive; model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
            let hold = Hold(); defer { hold.release() }
            model.textPreviewForVerification.beforePublicationForVerification = { await hold.pause() }
            guard let first = model.visibleItems.first else { throw UIVerification.Failure(message: "Drain fixture missing") }
            model.selection = [first.id]; model.previewSelected()
            var returned = false
            let drain = Task { await model.drain(); returned = true }
            try await wait("actual checked preview publication held") { hold.entered }
            try await Task.sleep(for: .milliseconds(40))
            let escaped = returned
            metrics["drainReturnedWhileActualPreviewPublicationHeld"] = escaped
            metrics["previewBusyWhileHeld"] = model.isPreviewing
            hold.release(); await drain.value
            try UIVerification.require(!escaped, "Preview publication is still held after model drain")
            try UIVerification.require(model.textPreviewForVerification.textForVerification?.isEmpty == false, "Released preview missing")
            checks.append("Model drain waits for the actual preview child and publication started by selection preparation")
            return
        }
        model.nameScope = .archive; model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
        try UIVerification.require(model.isSearchResults && model.visibleItems.map(\.path).sorted() == ["Design/Notes.txt", "Reports/Notes.txt"],
            "Equal names across folders were lost")
        let notes = model.visibleItems
        try await wait("native location column") { model.rowsForVerification?.table.numberOfRows == 2 }
        guard let rows = model.rowsForVerification else { throw UIVerification.Failure(message: "Native archive rows missing") }
        let location = rows.table.tableColumns.first { $0.identifier.rawValue == "location" }
        try UIVerification.require(location?.isHidden == false && rows.table.usesAutomaticRowHeights == false,
            "Search lacks its real Location column or bounded row geometry")
        guard let find = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) else {
            throw UIVerification.Failure(message: "Generated Find event missing")
        }
        try UIVerification.require(window.performKeyEquivalent(with: find) && window.firstResponder is NSTextView,
            "Archive Command-F did not focus its own live name editor")
        window.makeFirstResponder(rows.table)
        model.filter = ".md"; model.applyFilter(); try await settled(model)
        try UIVerification.require(model.visibleItems.count == 256 && model.visibleTotal == 600 && model.hasNextPage, "Global results are not paged")
        model.nextPage(); try await settled(model)
        try UIVerification.require(model.visibleOffset == 256, "Global next page failed")
        let chosen = model.visibleItems[200]
        model.selection = [chosen.id]; model.showInArchive(); try await settled(model)
        try UIVerification.require(!model.isSearchResults && model.page?.breadcrumbs.last?.name == "Batch"
            && model.visibleOffset == 256 && model.selection == [chosen.id] && model.visibleItems.contains { $0.id == chosen.id },
            "Show in Archive did not reveal the containing page and selected member")
        model.back(); try await settled(model)
        try UIVerification.require(model.isSearchResults && model.filter == ".md" && model.visibleOffset == 256, "Back lost the search/cursor")
        model.forward(); try await settled(model)
        try UIVerification.require(model.page?.breadcrumbs.last?.name == "Batch" && model.visibleOffset == 256, "Forward lost the actual folder/cursor")
        model.back(); try await settled(model)
        model.filter = "Design"; model.applyFilter(); try await settled(model)
        guard let design = model.visibleItems.first(where: { $0.kind == .directory }) else { throw UIVerification.Failure(message: "Global directory match missing") }
        model.openSelection([design.id]); try await settled(model)
        try UIVerification.require(!model.isSearchResults && model.page?.breadcrumbs.last?.name == "Design", "Global folder did not open")
        model.back(); try await settled(model)
        try UIVerification.require(model.isSearchResults && model.filter == "Design", "Folder Back lost the name search")
        checks.append("Actual global rows, equal-name locations,256-row pages, containing-page reveal and search/folder Back/Forward pass")

        let hold = Hold(); defer { hold.release() }
        model.beforePageForVerification = { await hold.pause() }
        let starts = model.pageRequestsForVerification
        model.filter = "Notes"; model.applyFilter(); try await wait("actual page owner held") { hold.entered }
        for value in ["not present", "Entry", "cafe notes file"] { model.filter = value; model.applyFilter() }
        try UIVerification.require(model.pageRequestsForVerification == starts + 1 && !model.viewIsCurrent && !model.canPreviewSelected,
            "Typing queued more than one actual owner or retained selection authority")
        hold.release(); try await settled(model); model.beforePageForVerification = nil
        try UIVerification.require(model.pageRequestsForVerification == starts + 2 && model.visibleItems.map(\.path) == ["Design/Café_notes-file.txt"],
            "Latest criteria failed to coalesce or stale results published")
        model.filter = String(repeating: "é", count: 65); model.applyFilter(); await model.drain()
        try UIVerification.require(!model.viewIsCurrent && !model.canPreviewSelected && !model.notice.isEmpty, "Invalid criteria authorize the old result")
        guard let archiveRoot = model.breadcrumbs.first?.folder else { throw UIVerification.Failure(message: "Root breadcrumb missing") }
        model.navigate(archiveRoot); try await settled(model); model.back(); try await settled(model)
        try UIVerification.require(model.filter == "cafe notes file" && model.viewIsCurrent,
            "Invalid input was retained in history instead of the last accepted search")
        model.filter = "   "; model.applyFilter(); try await settled(model)
        try UIVerification.require(model.visibleTotal == 0 && model.visibleItems.isEmpty, "Blank global query lists arbitrary files")
        checks.append("One actual page owner plus one latest demand rejects stale criteria, invalid/blank input and old selection authority")

        model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
        let selectionHold = Hold(); defer { selectionHold.release() }
        model.beforeSelectionForVerification = { await selectionHold.pause() }
        model.selection = Set(model.visibleItems.map(\.id)); model.extractSelected()
        try await wait("actual selection preparation held") { selectionHold.entered }
        model.filter = "cafe" // Invalidates immediately, before its debounce runs.
        try UIVerification.require(!model.canExtractSelected && model.selection.isEmpty, "Edited criteria retain selected-operation authority")
        selectionHold.release(); await model.drain(); model.beforeSelectionForVerification = nil
        try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil, "Stale selection opened a file-operation review")
        model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
        model.selection = Set(model.visibleItems.map(\.id)); model.extractSelected()
        try await wait("ordinary selected extraction review") { !model.isPreparingSelection && ApplicationArchiveExtraction.shared.controller != nil }
        guard let extract = ApplicationArchiveExtraction.shared.controller?.model else { throw UIVerification.Failure(message: "Selected extraction review missing") }
        try await wait("ordinary selected extraction plan") { !extract.isPreparing && extract.plan != nil }
        guard let plan = extract.plan else { throw UIVerification.Failure(message: "Selected extraction plan unavailable") }
        try UIVerification.require(plan.files == 2 && extract.canExtract, "Search selection widened to unselected archive entries")
        extract.extract(); try await wait("actual extraction completion") { !extract.isRunning && extract.outcome != nil && browser.operationTask == nil }
        try UIVerification.require(extract.outcome?.result.disposition == .succeeded && extract.canUndo, "Search selection extraction failed")
        let hashes = try await outputHashes(plan.destination)
        try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/selected-output.json"), options: .withoutOverwriting)
        extract.undo(); try await wait("exact extraction Undo") { !extract.isRunning && extract.undoOutcome != nil }
        try UIVerification.require(extract.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath: plan.destination.path),
            "Search selection exact Undo failed")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        checks.append("Changed criteria refuse a held selection; explicit cross-folder selection extracts exactly two names and supports exact Undo")

        let mutable = root.appendingPathComponent("source/Mutable.zip")
        model.open(mutable, from: browser); try await settled(model)
        model.nameScope = .archive; model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
        guard let staleID = model.visibleItems.first?.id else { throw UIVerification.Failure(message: "Source replacement fixture missing") }
        let replacement = try await Task.detached {
            var before = stat(), after = stat()
            guard lstat(mutable.path, &before) == 0 else { throw ZIPArchiveFailure.unavailable }
            try FileManager().moveItem(at: mutable, to: root.appendingPathComponent("source/Retained original.zip"))
            try FileManager().copyItem(at: small, to: mutable)
            guard lstat(mutable.path, &after) == 0, before.st_ino != after.st_ino else { throw ZIPArchiveFailure.changed }
            return ["before": before.st_ino, "after": after.st_ino]
        }.value
        metrics["replacedGeneratedSourceIdentity"] = replacement
        model.selection = [staleID]; model.previewSelected(); await model.drain()
        metrics["replacementPreviewBusyAfterDrain"] = model.isPreviewing
        metrics["replacementPreviewTextBytesAfterDrain"] = model.textPreviewForVerification.textForVerification?.utf8.count ?? 0
        metrics["replacementHasChangedNoticeAfterDrain"] = model.textPreviewForVerification.statusForVerification?.contains("changed") == true
        try UIVerification.require(model.textPreviewForVerification.textForVerification?.isEmpty != false
            && model.textPreviewForVerification.statusForVerification?.contains("changed") == true, "Changed archive published a stale text body")
        model.open(small, from: browser); try await settled(model)
        try UIVerification.require(!model.canPreviewSelection([notes[0].id]) && !model.canExtractSelection([notes[0].id]), "Refreshed session accepts old identities")
        checks.append("Actual replaced source refuses preview, and a refreshed archive rejects identities from its previous session")

        let large = root.appendingPathComponent("source/Large.zip"), began = CACurrentMediaTime()
        model.open(large, from: browser); try await settled(model)
        metrics["scaleFirstFolderMilliseconds"] = (CACurrentMediaTime() - began) * 1000
        try UIVerification.require(model.summary?.files == 100000 && model.visibleItems.count == 256, "Full100k archive not listed")
        model.nameScope = .archive
        let queryStart = CACurrentMediaTime(); model.filter = ".txt"; model.applyFilter(); try await settled(model)
        metrics["scaleGlobalQueryToRowsMilliseconds"] = (CACurrentMediaTime() - queryStart) * 1000
        try UIVerification.require((metrics["scaleFirstFolderMilliseconds"] as? Double ?? .infinity) <= 5_000
            && (metrics["scaleGlobalQueryToRowsMilliseconds"] as? Double ?? .infinity) <= 250,
            "Full-workload native query latency gate failed")
        try UIVerification.require(model.visibleTotal == 100000 && model.visibleItems.count == 256 && model.hasNextPage, "Global100k result lost its bound")
        model.nextPage(); try await settled(model)
        try UIVerification.require(model.visibleOffset == 256 && model.visibleItems.first?.name == "Item 000256.txt", "Global100k second page incorrect")
        model.filter = "Item 000000"; model.applyFilter(); try await settled(model)
        model.selection = Set(model.visibleItems.map(\.id)); model.previewSelected(); await model.drain()
        guard let text = model.textPreviewForVerification.textForVerification,
              let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("oracle.json"))) as? [String: Any] else {
            throw UIVerification.Failure(message: "Selected scale preview or oracle missing")
        }
        let textBytes = Data(text.utf8), textHash = SHA256.hash(data: textBytes).map { String(format: "%02x", $0) }.joined()
        try UIVerification.require(textBytes.count == oracle["scalePreviewBytes"] as? Int && textHash == oracle["scalePreviewSHA256"] as? String
            && model.textPreviewForVerification.plainTextPolicyForVerification, "Global result selected preview differs from the independent payload oracle")
        metrics["scalePreviewBytes"] = textBytes.count
        checks.append("Actual100k archive global query, paging and explicit maximum256KiB text preview pass together without content indexing")
        model.textPreviewForVerification.stop(closeWindow: true); await model.textPreviewForVerification.drain()
        model.open(small, from: browser); try await settled(model)
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            window.title = "Archive names · generated review"
            window.setFrameOrigin(.init(x: 100, y: 130)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let backdrop = GlassVerification.makeBrowserBackdropWindow(behind: window)
            defer { backdrop.close() }
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode; model.nameScope = .archive; model.filter = "Notes.txt"; model.applyFilter(); try await settled(model)
                let report = try await NativeMotionRecorder.record(window: window, root: root, label: "archive-names-" + mode.rawValue) {
                    model.filter = "cafe"; model.applyFilter()
                }
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/archive-names-" + mode.rawValue + ".json"), options: .withoutOverwriting)
                try await settled(model)
            }
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/archive-search.png"))
        }
        let closingHold = Hold(); defer { closingHold.release() }
        model.beforePageForVerification = { await closingHold.pause() }
        model.nameScope = .archive; model.filter = "Notes"; model.applyFilter(); try await wait("closing page owner held") { closingHold.entered }
        var closed = false
        let close = Task { await ApplicationZIPBrowser.shared.stopAndDrain(); closed = true }
        try await Task.sleep(for: .milliseconds(40))
        try UIVerification.require(!closed, "Close returned before the owned page request drained")
        closingHold.release(); await close.value
        try UIVerification.require(closed && ApplicationZIPBrowser.shared.controller == nil && ApplicationFileActivity.gate.activeCount == 0,
            "Closed archive retained a page owner, catalog or filesystem work")
        checks.append("Close waits for the actual held page owner, retires the catalog and drains real reader activity")
    }
    private static func settled(_ model: ArchiveBrowserModel) async throws {
        await model.drain()
        try await wait("native archive/search rows") { !model.isLoading && !model.isPaging && !model.isQueryPending && !model.isPreparingSelection }
        try await Task.sleep(for: .milliseconds(16))
        model.window?.contentView?.layoutSubtreeIfNeeded(); model.window?.displayIfNeeded()
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime() + 20
        while !condition() { guard CACurrentMediaTime() < end else { throw UIVerification.Failure(message: message) }; try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func outputHashes(_ directory: URL) async throws -> [String: String] {
        try await Task.detached { try outputHashesSynchronously(directory) }.value
    }
    private nonisolated static func outputHashesSynchronously(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumeration = FileManager().enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { throw ZIPArchiveFailure.unavailable }
        for case let url as URL in enumeration {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= 1024 * 1024 else { throw ZIPArchiveFailure.limited }
                result[String(url.path.dropFirst(directory.path.count + 1))] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
}
#endif
