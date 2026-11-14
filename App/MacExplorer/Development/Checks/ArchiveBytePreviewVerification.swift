#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import LocalStorage

@MainActor enum ArchiveBytePreviewVerification {
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Pulse {
        var last = CACurrentMediaTime(), gap = 0.0, ticks = 0
        func tick() { let now = CACurrentMediaTime(); gap = max(gap, now-last); last = now; ticks += 1 }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"), root.resolvingSymlinksInPath() == root,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["action"] as? String == "traverse-archive-bytes-ui" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.folderSummariesEnabled = false; settings.motion.mode = .off; settings.navigationStyle = .glass
        settings.glassFileContent = true; settings.appearance = .dark
        let owner = BrowserWindowController(settings: settings), pulse = Pulse()
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        var failures: [String] = [], checks: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, owner: owner, settings: settings, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        timer.invalidate(); var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native memory gate failed") }
        if pulse.gap > 0.4 || pulse.ticks < 10 { failures.append("Native responsiveness gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual file activity remains") }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures, "metrics": metrics,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": pulse.gap,
            "activityCount": ApplicationFileActivity.gate.activeCount, "generatedOnly": true,
            "explicitSelectedBodiesOnly": true, "network": false, "clipboard": false, "physicalInput": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, owner: BrowserWindowController, settings: BrowserSettings,
        checks: inout [String], metrics: inout [String: Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation, "Byte review requires actual workspace composition")
        if ProcessInfo.processInfo.arguments.contains("--ordinary-byte-preview") {
            try UIVerification.require(ZIPBytePreviewFeature.ordinaryEnabled, "Final native check requires ordinary Hex activation")
            metrics["ordinaryBytePreview"] = true
        }
        owner.window?.setFrameOrigin(.init(x: -12000, y: -12000))
        let browser = owner.browser
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        owner.beginBrowsing(); try await wait("workspace") { owner.workspace.sessionReady }
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait("generated source listing") { !browser.isLoading && browser.orderingTask == nil }
        let source = root.appendingPathComponent("source/Generated.zip")
        ApplicationZIPBrowser.shared.show(source, from: browser)
        guard let controller = ApplicationZIPBrowser.shared.controller, let archiveWindow = controller.window else { throw UIVerification.Failure(message: "Archive missing") }
        let model = controller.model
        archiveWindow.setFrame(.init(x: -12000, y: -12000, width: 960, height: 640), display: true)
        try await settled(model)
        guard let rows = model.rowsForVerification,
              let menu = rows.table.menu?.items.first(where: { $0.title == "Preview as Hex" }),
              let action = menu.action else { throw UIVerification.Failure(message: "Native Hex action missing") }
        let oracle = try object(root.appendingPathComponent("oracle.json"))
        guard let proofs = oracle["members"] as? [String: [String: Any]], proofs.count == 5 else { throw UIVerification.Failure(message: "Python member oracle missing") }
        model.selection = []
        try UIVerification.require(!rows.validateMenuItem(menu), "Empty native selection can preview bytes")
        guard let folder = model.visibleItems.first(where: { $0.kind == .directory }) else { throw UIVerification.Failure(message: "Generated folder missing") }
        model.selection = [folder.id]
        try UIVerification.require(!model.canPreviewSelected, "Folder is offered as a byte member")
        var observed: [String: [String: Any]] = [:]
        for name in ["Binary.bin", "Partial.bin", "Empty.bin", "Boundary.bin", "Readme.txt"] {
            guard let index = model.visibleItems.firstIndex(where: { $0.name == name }) else { throw UIVerification.Failure(message: "Generated member absent") }
            rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try UIVerification.require(rows.validateMenuItem(menu) && NSApp.sendAction(action, to: menu.target, from: menu), "Real context action refused a selected file")
            await model.drain()
            guard let text = model.textPreviewForVerification.textForVerification else { throw UIVerification.Failure(message: "Complete hexadecimal result missing") }
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            let proof = proofs[name]!
            try UIVerification.require(digest == proof["hexSHA256"] as? String
                && text.utf8.count == proof["hexBytes"] as? Int
                && model.textPreviewForVerification.plainTextPolicyForVerification, "Complete native view differs from independent Python oracle or text policy")
            observed[name] = ["hexSHA256": digest, "hexBytes": text.utf8.count]
            if name == "Boundary.bin", let narrow = model.textPreviewForVerification.windowForVerification {
                narrow.setFrame(.init(x: -12000, y: -12000, width: 560, height: 400), display: true)
                narrow.contentView?.layoutSubtreeIfNeeded()
                try UIVerification.require(model.textPreviewForVerification.hexadecimalLayoutForVerification
                    && model.textPreviewForVerification.textForVerification == text, "Narrow Hex view wrapped or changed complete rows")
                narrow.setFrame(.init(x: -12000, y: -12000, width: 960, height: 640), display: true)
            }
        }
        metrics["independentMemberViews"] = observed
        checks.append("Actual Hex context action refuses empty/folder selections and displays all256 byte values, partial rows, empty,256KiB boundary and Unicode text exactly as independent Python oracles")

        let preview = model.textPreviewForVerification
        guard let binaryForText = model.visibleItems.first(where: { $0.name == "Binary.bin" }) else { throw UIVerification.Failure(message: "Binary member missing") }
        model.selection = [binaryForText.id]; model.previewSelected(); await model.drain()
        try UIVerification.require(preview.textForVerification?.isEmpty != false
            && preview.statusForVerification?.contains("UTF-8") == true && preview.wrappedTextLayoutForVerification,
            "Text refusal silently fell back to bytes or retained Hex layout")
        checks.append("Narrow Hex rows stay unwrapped and complete; explicit Text restores wrapping and refuses binary without an automatic byte read")
        preview.findForVerification()
        guard let panel = preview.windowForVerification else { throw UIVerification.Failure(message: "Native byte window missing") }
        try UIVerification.require(panel.firstResponder is NSTextView, "Native Find did not focus text navigation")
        try UIVerification.require(preview.plainTextPolicyForVerification, "Byte view enabled rich text, detection or editing")
        let corrupt = root.appendingPathComponent("source/Corrupt.zip")
        ApplicationZIPBrowser.shared.show(corrupt, from: browser); try await settled(model)
        guard let corruptItem = model.visibleItems.first else { throw UIVerification.Failure(message: "Corrupt-member metadata missing") }
        model.selection = [corruptItem.id]; model.previewSelectedAsBytes(); await model.drain()
        try UIVerification.require(preview.textForVerification?.isEmpty != false && preview.statusForVerification?.contains("checksum") == true,
            "Corrupt member published a hexadecimal prefix")
        checks.append("Native Find remains available with inert read-only policy; bad CRC reports failure and shows no partial content")

        let mutable = root.appendingPathComponent("source/Mutable.zip")
        ApplicationZIPBrowser.shared.show(mutable, from: browser); try await settled(model)
        guard let mutableItem = model.visibleItems.first(where: { $0.name == "Binary.bin" }) else { throw UIVerification.Failure(message: "Mutable selection absent") }
        let replacement = try Data(contentsOf: root.appendingPathComponent("source/Replacement.zip"))
        try replacement.write(to: mutable, options: .atomic)
        model.selection = [mutableItem.id]; model.previewSelectedAsBytes(); await model.drain()
        try UIVerification.require(preview.textForVerification?.isEmpty != false && preview.statusForVerification?.contains("changed") == true,
            "Replaced source reused the old opaque selection")
        checks.append("Generated archive replacement refuses the stale selection without materializing or changing a member")

        ApplicationZIPBrowser.shared.show(source, from: browser); try await settled(model)
        guard let binary = model.visibleItems.first(where: { $0.name == "Binary.bin" }),
              let readme = model.visibleItems.first(where: { $0.name == "Readme.txt" }) else { throw UIVerification.Failure(message: "Refreshed members absent") }
        let selectionHold = Hold(); defer { selectionHold.release() }
        model.beforeSelectionForVerification = { await selectionHold.pause() }
        model.selection = [binary.id]; model.previewSelectedAsBytes()
        try await wait("Actual opaque selection held") { selectionHold.entered }
        model.nameScope = .archive; model.filter = "Readme"; model.applyFilter()
        selectionHold.release(); await model.drain(); model.beforeSelectionForVerification = nil
        try UIVerification.require(preview.textForVerification?.isEmpty != false, "Stale selection after a search change still published bytes")
        try await settled(model)
        model.nameScope = .folder; model.filter = ""; model.applyFilter(); try await settled(model)
        checks.append("Stale page/query changes invalidate the selected Hex request before source access admission")

        let publicationHold = Hold(); defer { publicationHold.release() }
        preview.beforePublicationForVerification = { await publicationHold.pause() }
        model.selection = [binary.id]; model.previewSelectedAsBytes()
        try await wait("Actual checked byte publication held") { publicationHold.entered }
        var returned = false
        let draining = Task { await model.drain(); returned = true }
        try await Task.sleep(for: .milliseconds(30))
        try UIVerification.require(!returned && model.isPreviewing, "Drain escaped a held actual byte publication")
        model.selection = [readme.id]; model.previewSelected()
        try await wait("Latest text selection prepared") { !model.isPreparingSelection }
        preview.beforePublicationForVerification = nil; publicationHold.release(); await draining.value; await model.drain()
        let expectedReadme = oracle["readmeText"] as? String
        try UIVerification.require(preview.textForVerification == expectedReadme && preview.statusForVerification?.contains("UTF-8") == true,
            "Superseded Hex result overwrote the latest explicit text demand")
        checks.append("One actual preview owner retains held work through model drain and rejects obsolete bytes when the latest explicit demand is text")

        let stopping = Hold(); defer { stopping.release() }
        preview.beforePublicationForVerification = { await stopping.pause() }
        model.selection = [binary.id]; model.previewSelectedAsBytes()
        try await wait("Stop publication hold absent") { stopping.entered }
        model.stop(); stopping.release(); preview.beforePublicationForVerification = nil; await model.drain()
        try UIVerification.require(preview.textForVerification?.isEmpty != false && !model.isPreviewing, "Stop published obsolete byte content or released work incorrectly")
        checks.append("Stop clears the preview and joins its actual read/publication without returning a verified prefix")

        archiveWindow.setFrameOrigin(.init(x: -12000, y: -12000))
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode
            model.selection = [readme.id]; model.previewSelectedAsBytes(); await model.drain()
            guard let current = preview.windowForVerification else { throw UIVerification.Failure(message: "Mode preview missing") }
            current.title = "Byte preview · generated review"
            current.setFrame(.init(x: 100, y: 120, width: 960, height: 640), display: true); current.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                let recording = try await NativeMotionRecorder.record(window: current, root: root, label: "archive-bytes-" + mode.rawValue) { model.previewSelected() }
                try JSONEncoder().encode(recording).write(to: root.appendingPathComponent("evidence/archive-bytes-" + mode.rawValue + ".json"), options: .withoutOverwriting)
            } else { model.previewSelected() }
            await model.drain()
            try UIVerification.require(preview.textForVerification == expectedReadme && preview.plainTextPolicyForVerification, "Text/Hex mode change lost exact text or inert policy")
        }
        checks.append("Shared native preview supports Full/Reduced/Off text/hex changes and retains native Find/readonly content")

        let closing = Hold(); defer { closing.release() }
        preview.beforePublicationForVerification = { await closing.pause() }
        model.selection = [binary.id]; model.previewSelectedAsBytes()
        try await wait("Close publication hold absent") { closing.entered }
        preview.windowForVerification?.close()
        var closed = false
        let close = Task { await model.closeAndDrain(); closed = true }
        try await Task.sleep(for: .milliseconds(30))
        try UIVerification.require(!closed, "Close escaped actual byte work")
        closing.release(); await close.value
        try UIVerification.require(preview.windowForVerification == nil && ApplicationFileActivity.gate.activeCount == 0, "Closed preview retained its visible content or actual activity")
        checks.append("Window/model close withdraws bytes immediately and waits for actual retained work to drain")
    }
    private static func object(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count <= 1<<20, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UIVerification.Failure(message: "Bounded generated oracle missing") }
        return value
    }
    private static func settled(_ model: ArchiveBrowserModel) async throws {
        try await wait("Actual archive result did not settle") { !model.isLoading && !model.isPaging && !model.isQueryPending && model.page != nil }
        await model.drain()
        try await wait("Actual native row identities did not update") { model.rowsForVerification?.rowIDsForVerification == model.visibleItems.map(\.id) }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime() + 12
        while !condition() { try UIVerification.require(CACurrentMediaTime() < end, message); try await Task.sleep(for: .milliseconds(10)) }
    }
}
#endif
