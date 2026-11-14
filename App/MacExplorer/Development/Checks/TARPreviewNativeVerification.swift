#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import LocalStorage

@MainActor enum TARPreviewNativeVerification {
    private struct Failure: Error { let stage: String }
    private static let title = "TAR preview · generated review · motion audit"
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Context {
        let root: URL, owner: BrowserWindowController, mode: String
        var checks = [String](), clips = [[String: Any]](), holds = [Hold](), external = [URL]()
        var windowSizing = [[String: Any]]()
        var sourceChanged = false
        var browser: BrowserViewController { owner.workspace.activeBrowser }
        var source: URL { root.appendingPathComponent("source") }
        init(root: URL, owner: BrowserWindowController, mode: String) { self.root = root; self.owner = owner; self.mode = mode }
        func configure(_ browser: BrowserViewController) {
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            browser.defaultOpenForVerification = { [weak self] url in self?.external.append(url); return false }
        }
    }
    private static func require(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() { try require(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func argument(_ name: String) throws -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { throw Failure(stage: "missing-preview-mode") }
        return args[index + 1]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func settled(_ browser: BrowserViewController) async throws -> ArchiveTabController {
        try await wait("archive-preview-source-settled") { browser.currentArchive?.current == true && browser.currentArchive?.busy == false && browser.currentArchive?.table != nil && browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
        guard let owner = browser.currentArchive else { throw Failure(stage: "archive-preview-source-missing") }; return owner
    }
    private static func open(_ test: Context, name: String) async throws -> ArchiveTabController {
        try require(["Review.tar", "Mutable.tar", "Review.zip"].contains(name), "generated-original-source-name")
        let browser = test.browser, url = test.source.appendingPathComponent(name)
        browser.navigate(to: .directory(test.source))
        try await wait("generated-preview-source-listing") { !browser.isLoading && browser.orderingTask == nil && browser.location == .directory(test.source) }
        guard let window = browser.view.window else { throw Failure(stage: "generated-browser-window") }
        window.makeKeyAndOrderFront(nil); browser.workspace?.activate(browser, focus: false)
        try require(window.makeFirstResponder(browser.table) && browser.rowsByURL[url] != nil, "generated-source-command-focus")
        browser.setFileSelection([url]); browser.fileSelectionDidChange()
        guard let action = browser.table.doubleAction else { throw Failure(stage: "generated-source-double-action") }
        try require(NSApp.sendAction(action, to: browser.table.target, from: browser.table), "generated-source-open-undelivered")
        let owner = try await settled(browser)
        try require(owner.source == url && browser.location.isArchive && test.external.isEmpty, "source-open-was-external-or-wrong-archive")
        owner.tarModelForVerification?.previewOffscreenForVerification = false
        return owner
    }
    private static func select(_ path: String, owner: ArchiveTabController) throws {
        let paths = owner.tarModelForVerification?.items.map(\.path) ?? owner.zipModelForVerification?.visibleItems.map(\.path) ?? []
        guard let row = paths.firstIndex(where: { $0.utf8.elementsEqual(path.utf8) }), let table = owner.table else { throw Failure(stage: "preview-member-visible-row") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    private static func context(_ title: String, owner: ArchiveTabController) throws {
        guard let item = owner.table?.menu?.items.first(where: { $0.title == title }), let action = item.action,
              let rows = item.target as? TARMetadataRows else { throw Failure(stage: "native-tar-preview-context-action") }
        try require(rows.validateMenuItem(item) && NSApp.sendAction(action, to: item.target, from: item), "native-tar-preview-context-refused")
    }
    static func run() async {
        var test: Context?, root: URL?, mode = "", failure: String?
        do {
            mode = try argument("--preview-mode")
            guard ["full-dark", "reduced-dark", "off-light150"].contains(mode), let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "preview-scope") }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("preview-admission.json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent && marker?["action"] as? String == "tar-preview-native"
                && admission?["master"] as? String == "7B4FE5D0-444E-4676-A91F-25E69FDDAF8D" && admission?["mode"] as? String == mode
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"), "preview-exact-generated-scope")
            root = area
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.opensArchivesInTraverse = true; settings.keyboardProfile = .explorer
            settings.appearance = mode == "off-light150" ? .light : .dark
            settings.navigationStyle = mode == "off-light150" ? .solid : .glass; settings.glassFileContent = mode != "off-light150"
            settings.motion.mode = mode == "full-dark" ? .full : mode == "reduced-dark" ? .reduced : .off
            settings.interfaceSize = InterfaceSize(mode == "off-light150" ? 150 : 100)
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings), current = Context(root: area, owner: owner, mode: mode); test = current
            try require(owner.isWorkspacePresentation && TARTextPreviewFeature.available, "preview-concrete-workspace-feature")
            owner.workspace.sessionReady = true; owner.workspace.willStartBrowserForVerification = { [weak current] in current?.configure($0) }
            current.configure(current.browser)
            owner.window?.setContentSize(.init(width: 1150, height: 800)); owner.window?.center(); owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await menus(current)
            try await inactiveSelection(current)
            try await lifetimes(current)
            try await previewEviction(current)
            try require(current.external.isEmpty, "preview-opened-external-application")
        } catch { failure = (error as? Failure)?.stage ?? "unexpected-\(String(reflecting: type(of: error)))" }
        test?.holds.forEach { $0.release() }
        test?.owner.suspendBrowsing()
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        await ApplicationArchiveExports.shared.closeAndDrain()
        await ApplicationZIPBrowser.shared.stopAndDrain(); await ApplicationTARBrowser.shared.closeAndDrain()
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        if let test { await test.owner.flushSession(); test.owner.window?.close() }
        let pool = ArchiveTabCatalogPool.shared
        if failure == nil && (ApplicationFileActivity.gate.activeCount != 0 || pool.retainedCountForVerification != 0 || pool.retiringCountForVerification != 0 || ApplicationArchiveExports.shared.countForVerification != 0) { failure = "preview-actual-owner-activity-export-drain" }
        if let root {
            let value: [String: Any] = ["passed": failure == nil, "failureStage": failure.map { $0 as Any } ?? NSNull(), "mode": mode,
                "checks": test?.checks ?? [], "clips": test?.clips ?? [], "windowSizing": test?.windowSizing ?? [], "externalOpenCalls": test?.external.count ?? 0,
                "sourceChanged": test?.sourceChanged ?? false, "activityAfter": ApplicationFileActivity.gate.activeCount,
                "poolRetainedAfter": pool.retainedCountForVerification, "poolRetiringAfter": pool.retiringCountForVerification,
                "exportsAfter": ApplicationArchiveExports.shared.countForVerification, "generatedOnly": true,
                "explicitSelectedBodiesOnly": true, "physicalPointer": false, "spokenAccessibility": false, "networkRequests": 0, "keychainCalls": 0]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-tar-preview.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func menus(_ test: Context) async throws {
        let owner = try await open(test, name: "Review.tar")
        guard let model = owner.tarModelForVerification, let table = owner.table else { throw Failure(stage: "tar-preview-concrete-model") }
        let preview = model.textPreviewForVerification
        table.deselectAll(nil)
        try require(!model.canPreviewSelected, "tar-empty-selection-preview-enabled")
        try select("Folder", owner: owner); try require(!model.canPreviewSelected, "tar-folder-preview-enabled")
        try select("Note.txt", owner: owner)
        guard let action = table.doubleAction else { throw Failure(stage: "tar-member-double-action-missing") }
        try require(NSApp.sendAction(action, to: table.target, from: table), "tar-member-natural-open-undelivered")
        await model.drain()
        try require(preview.textForVerification == "hello" && preview.plainTextPolicyForVerification && preview.wrappedTextLayoutForVerification,
                    "tar-natural-open-incomplete-or-active-text")
        try require(preview.statusForVerification?.contains("source rechecked") == true
            && preview.statusForVerification?.contains("checksum checked") == false
            && preview.statusTipForVerification?.contains("TAR has no per-file content checksum") == true, "tar-preview-false-checksum-claim")
        guard let window = preview.windowForVerification else { throw Failure(stage: "tar-preview-real-window") }
        preview.findForVerification()
        try require(window.firstResponder is NSTextView && preview.plainTextPolicyForVerification && preview.textForVerification == "hello", "tar-preview-native-find-or-readonly-policy")
        test.checks.append("Actual member Open renders complete UTF-8 in the inert read-only native Find window with truthful TAR source/metadata and no-CRC wording")
        try context("Preview as Hex", owner: owner); await model.drain()
        let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: test.root.appendingPathComponent("oracle.json"))) as? [String: Any]
        let hex = preview.textForVerification ?? ""
        try require(digest(hex) == oracle?["helloHexSHA256"] as? String && preview.hexadecimalLayoutForVerification && preview.plainTextPolicyForVerification,
                    "tar-native-hex-not-independent-complete-oracle")
        try select("Markup.txt", owner: owner); try context("Preview Text", owner: owner); await model.drain()
        try require(digest(preview.textForVerification ?? "") == oracle?["markupSHA256"] as? String && preview.plainTextPolicyForVerification,
                    "tar-markup-not-inert-exact-text")
        let chosenWidth = window.frame.width
        try select("Binary.bin", owner: owner); try context("Preview Text", owner: owner); await model.drain()
        preview.layoutForVerification()
        try require(abs(window.frame.width - chosenWidth) <= 1, "long-refusal-does-not-enlarge-user-window")
        try require(preview.textForVerification?.isEmpty != false && preview.statusForVerification?.contains("UTF-8") == true,
                    "tar-binary-text-refusal-retained-body-or-auto-hex")
        try context("Preview as Hex", owner: owner); await model.drain()
        try require(digest(preview.textForVerification ?? "") == oracle?["binaryHexSHA256"] as? String, "tar-binary-hex-incomplete")
        test.checks.append("Native context Text/Hex actions match independent full byte/markup oracles; binary Text refusal shows no prefix and requires explicit Hex")
        // The synthetic Find check is complete. Dismiss this owned bar before
        // recording so an OS-shared find string cannot enter fixture captures.
        if let text = (preview.viewportForVerification as? NSClipView)?.documentView as? NSTextView {
            let closeFind = NSMenuItem(); closeFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
            text.performFindPanelAction(closeFind)
        }
        try await motion(test, owner: owner, model: model)
        preview.stop(closeWindow: true); await model.drain()
        let zip = try await open(test, name: "Review.zip")
        try select("Note.txt", owner: zip)
        guard let zipModel = zip.zipModelForVerification else { throw Failure(stage: "zip-regression-model") }
        zipModel.previewSelected(); await zipModel.drain()
        try require(zipModel.textPreviewForVerification.textForVerification == "hello"
            && zipModel.textPreviewForVerification.statusForVerification?.contains("length and checksum checked") == true, "zip-preview-regression")
        zipModel.textPreviewForVerification.stop(closeWindow: true); await zipModel.drain()
        test.checks.append("The same preview owner keeps ZIP's checked length/CRC wording and complete original UTF-8 behavior")
    }
    private static func motion(_ test: Context, owner: ArchiveTabController, model: TARBrowserModel) async throws {
        try select("Motion.txt", owner: owner); model.previewSelected(); await model.drain()
        let preview = model.textPreviewForVerification
        guard let window = preview.windowForVerification else { throw Failure(stage: "tar-motion-window") }
        preview.beforePublicationForVerification = { [weak window] in window?.title = title }
        defer { preview.beforePublicationForVerification = nil }
        window.title = title; window.center(); window.makeKeyAndOrderFront(nil)
        let visible = window.screen?.visibleFrame ?? .zero
        test.windowSizing.append(["phase": "preview-before-mode-actions", "mode": test.mode,
            "width": window.frame.width, "height": window.frame.height,
            "screenWidth": visible.width, "screenHeight": visible.height,
            "plainText": preview.plainTextPolicyForVerification, "textFontPoints": preview.textFontPointsForVerification ?? 0])
        try await UIVerification.snapshot(window, to: test.root.appendingPathComponent("evidence/preview-window-before-size-check.png"))
        try require(window.frame.width <= 1152 && window.frame.height <= 800 && preview.plainTextPolicyForVerification, "tar-preview-size-policy")
        if test.mode == "full-dark" {
            for (label, mode) in [("tar-preview-to-hex", ArchivePreviewMode.hexadecimal), ("tar-preview-to-text", .text)] {
                window.title = title; try await Task.sleep(for: .milliseconds(250))
                let report = try await NativeMotionRecorder.record(window: window, root: test.root, label: label, sampling: .diagnostic(for: window)) {
                    model.previewSelection(model.selection, mode: mode)
                    window.title = title
                }
                await model.drain()
                try JSONEncoder().encode(report).write(to: test.root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                try require(report.requestedFPS == 120 && report.frames.count >= 3 && report.maximumFrames <= 180 && report.videoBytes > 0 && report.videoBytes <= 4 << 20
                    && report.streamStopped && report.writerCompleted && report.failureCode == nil, "tar-preview-recorder-actual-drain")
                var clip: [String: Any] = ["label": label, "mode": model.settings.motion.mode.rawValue, "frames": report.frames.count,
                    "requestedFPS": report.requestedFPS, "width": report.width, "height": report.height, "captureGeometry": report.captureGeometry,
                    "droppedEncoderFrames": report.droppedEncoderFrames, "windowAppearance": window.effectiveAppearance.name.rawValue]
                if let viewport = preview.viewportForVerification, viewport.window === window {
                    let frame = viewport.convert(viewport.bounds, to: nil)
                    let region = NSRect(x: frame.minX, y: CGFloat(report.height) - frame.maxY, width: frame.width, height: frame.height)
                    if NSRect(x: 0, y: 0, width: report.width, height: report.height).contains(region) {
                        clip["fieldRegion"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
                        clip["fieldVisibility"] = "Read-only TAR preview viewport"; clip["fieldOwnerVerified"] = true
                    }
                }
                test.clips.append(clip)
            }
        } else {
            model.previewSelectedAsBytes(); await model.drain(); try require(preview.hexadecimalLayoutForVerification, "tar-mode-hex-layout")
            model.previewSelected(); await model.drain(); try require(preview.wrappedTextLayoutForVerification, "tar-mode-text-layout")
        }
        try require(preview.renderedTextFitsViewportForVerification, "tar-text-after-hex-rendered-width")
        try require(preview.plainTextPolicyForVerification && InterfacePresentation.shared.size.percent == (test.mode == "off-light150" ? 150 : 100), "tar-preview-mode-interface-policy")
        try require(preview.textFontPointsForVerification == (test.mode == "off-light150" ? 18 : 12), "tar-preview-actual-text-font-scale")
        test.checks.append("Full/Reduced/Off and light150 retain read-only Text/Hex layout; only Full captures two bounded exact-own-window motion clips")
    }
    private static func inactiveSelection(_ test: Context) async throws {
        for name in ["Review.tar", "Review.zip"] {
            let owner = try await open(test, name: name), tab = test.browser.activeID
            let hold = Hold(); test.holds.append(hold)
            let preview: ArchiveTextPreviewOwner
            if let tar = owner.tarModelForVerification {
                preview = tar.textPreviewForVerification
                preview.stop(closeWindow: true); await tar.drain()
                _ = try await settled(test.browser)
                try select("Note.txt", owner: owner)
                try require(tar.canPreviewSelected && tar.selection.count == 1, "inactive-tar-native-selection-admitted")
                tar.beforePreviewSelectionForVerification = { await hold.pause() }
                tar.previewSelected()
            } else if let zip = owner.zipModelForVerification {
                preview = zip.textPreviewForVerification
                preview.stop(closeWindow: true); await zip.drain()
                _ = try await settled(test.browser)
                try select("Note.txt", owner: owner)
                try require(zip.canPreviewSelected && zip.selection.count == 1, "inactive-zip-native-selection-admitted")
                zip.beforeSelectionForVerification = { await hold.pause() }
                zip.previewSelected()
            } else { throw Failure(stage: "inactive-selection-concrete-model") }
            try await wait("inactive-selection-held") { hold.entered }
            test.browser.newTab(nil)
            let temporaryTab = test.browser.activeID
            try require(temporaryTab != tab && !owner.isPresented && !owner.canExtract, "inactive-archive-action-still-admitted")
            hold.release()
            if let tar = owner.tarModelForVerification { await tar.drain(); tar.beforePreviewSelectionForVerification = nil }
            if let zip = owner.zipModelForVerification { await zip.drain(); zip.beforeSelectionForVerification = nil }
            try require(preview.windowForVerification == nil && !preview.isReading && preview.textForVerification?.isEmpty != false,
                        "inactive-archive-selection-published-preview")
            test.browser.closeTab(id: temporaryTab)
            test.browser.selectTab(tab); _ = try await settled(test.browser)
        }
        test.checks.append("Actual tab changes withdraw delayed TAR/ZIP preview preparation and extraction commands before a new body/window is admitted")
    }
    private static func lifetimes(_ test: Context) async throws {
        let owner = try await open(test, name: "Review.tar")
        guard let model = owner.tarModelForVerification else { throw Failure(stage: "tar-lifetime-model") }
        let preview = model.textPreviewForVerification
        let selectionHold = Hold(); test.holds.append(selectionHold)
        model.beforePreviewSelectionForVerification = { await selectionHold.pause() }
        try select("Note.txt", owner: owner); model.previewSelected()
        try await wait("tar-selection-held") { selectionHold.entered }
        model.query = "Markup"; selectionHold.release(); await model.drain(); model.beforePreviewSelectionForVerification = nil
        try require(preview.windowForVerification == nil, "tar-stale-selection-created-preview")
        model.query = ""; _ = try await settled(test.browser)
        test.checks.append("Changing the actual archive query cancels held opaque selection preparation before body admission")
        let latest = Hold(); test.holds.append(latest)
        preview.beforePublicationForVerification = { await latest.pause() }
        try select("Note.txt", owner: owner); model.previewSelectedAsBytes()
        try await wait("tar-publication-held") { latest.entered }
        var drained = false; let draining = Task { await model.drain(); drained = true }
        try await Task.sleep(for: .milliseconds(30)); try require(!drained && preview.isReading, "tar-drain-escaped-held-publication")
        try select("Markup.txt", owner: owner); model.previewSelected()
        try await wait("tar-latest-selection-prepared") { !model.isPreparingPreview }
        preview.beforePublicationForVerification = nil; latest.release(); await draining.value; await model.drain()
        let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: test.root.appendingPathComponent("oracle.json"))) as? [String: Any]
        try require(digest(preview.textForVerification ?? "") == oracle?["markupSHA256"] as? String, "tar-late-hex-overwrote-latest-text")
        test.checks.append("Actual held publication remains owned through drain; the latest explicit Text request supersedes obsolete Hex")
        try await stopAndSuspend(test, owner: owner, model: model)
        preview.stop(closeWindow: true); await model.drain()
        let mutable = try await open(test, name: "Mutable.tar")
        guard let changed = mutable.tarModelForVerification else { throw Failure(stage: "tar-source-change-model") }
        try select("Note.txt", owner: mutable)
        let source = test.source.appendingPathComponent("Mutable.tar"), replacement = test.source.appendingPathComponent("Replacement.tar")
        try await Task.detached { try Data(contentsOf: replacement).write(to: source) }.value
        test.sourceChanged = true; changed.previewSelected(); await changed.drain()
        try require(changed.textPreviewForVerification.textForVerification?.isEmpty != false
            && changed.textPreviewForVerification.statusForVerification?.localizedCaseInsensitiveContains("changed") == true, "tar-source-change-published-stale-body")
        test.checks.append("Replacing only the generated mutable TAR refuses its stale source-bound member without displaying content")
    }
    private static func previewEviction(_ test: Context) async throws {
        let original = try await open(test, name: "Review.tar")
        guard let model = original.tarModelForVerification else { throw Failure(stage: "preview-retained-model") }
        try select("Note.txt", owner: original); model.previewSelected(); await model.drain()
        let preview = model.textPreviewForVerification
        guard let window = preview.windowForVerification else { throw Failure(stage: "preview-retained-window") }
        try require(window.isVisible && original.retainsPreviewPresentation && preview.textForVerification == "hello", "preview-retained-initial")
        var others = [ArchiveTabController]()
        for _ in 0..<4 {
            test.browser.newTab(nil)
            others.append(try await open(test, name: "Review.zip"))
        }
        try require(!original.isClosed && original.retainsPreviewPresentation && window.isVisible && preview.textForVerification == "hello"
            && others.first?.isClosed == true && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4,
                    "inactive-catalog-evicted-visible-preview")
        window.performClose(nil); await model.drain()
        test.browser.newTab(nil); _ = try await open(test, name: "Review.zip")
        try await wait("closed-preview-lru-actually-drained") { original.isClosed }
        try require(!original.retainsPreviewPresentation && preview.windowForVerification == nil
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4, "closed-preview-did-not-release-eviction-protection")
        test.checks.append("A visible selected preview protects its inactive archive from catalog eviction; closing it restores eligibility without exceeding four catalogs")
    }
    private static func stopAndSuspend(_ test: Context, owner: ArchiveTabController, model: TARBrowserModel) async throws {
        let preview = model.textPreviewForVerification
        for command in ["stop", "close", "suspend"] {
            let hold = Hold(); test.holds.append(hold)
            preview.beforePublicationForVerification = { await hold.pause() }
            try select("Note.txt", owner: owner); model.previewSelected()
            try await wait("tar-held-" + command) { hold.entered }
            if command == "stop" {
                guard let content = preview.windowForVerification?.contentView,
                      let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Stop" && $0.isEnabled }) else { throw Failure(stage: "tar-native-stop-button") }
                button.performClick(nil)
            } else if command == "close" { preview.windowForVerification?.performClose(nil) }
            else { model.suspend() }
            var drained = false; let draining = Task { await model.drain(); drained = true }
            try await Task.sleep(for: .milliseconds(30)); try require(!drained, "tar-" + command + "-returned-before-actual-publication")
            preview.beforePublicationForVerification = nil; hold.release(); await draining.value
            try require(!preview.isReading && preview.textForVerification?.isEmpty != false, "tar-" + command + "-published-late-body")
            if command != "stop" { try require(preview.windowForVerification == nil, "tar-closed-or-suspended-window-retained") }
            if command == "suspend" { model.resume(); model.refresh(); _ = try await settled(test.browser) }
        }
        test.checks.append("Native preview Stop/Close and volume-suspension hooks withdraw content, reject late results and join actual publication before returning; Resume reacquires metadata")
    }
}
#endif
