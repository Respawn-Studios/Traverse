#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

/// Generated native commands at the actual main-browser/archive-owner boundary.
/// These are delivered native actions/keys, not physical pointer acceptance.
@MainActor enum InlineArchiveVerification {
    private struct Failure: Error { let stage: String }
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Context {
        let root: URL, owner: BrowserWindowController
        var checks = [String](), metrics = [String: Any](), holds = [Hold]()
        var externalOpenURLs = [URL](), expectedDefaultOpenURLs = [URL]()
        var externalCalls: Int { externalOpenURLs.count }
        var extraWindowControllers = [BrowserWindowController]()
        var snapshotDuringEditorEnd: PaneWorkspaceSnapshot?
        var browser: BrowserViewController { owner.workspace.activeBrowser }
        var source: URL { root.appendingPathComponent("source") }
        init(root: URL, owner: BrowserWindowController) { self.root = root; self.owner = owner }
        func configure(_ browser: BrowserViewController) {
            browser.permitsBackgroundVerification = true
            browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.privateNames = ApplicationPrivateNames(directory: root.appendingPathComponent("state/Names"), settings: browser.settings)
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("state/history"))
            browser.defaultOpenForVerification = { [weak self] url in
                guard let self else { return false }
                self.externalOpenURLs.append(url)
                return self.expectedDefaultOpenURLs.contains(url)
            }
            browser.operationErrorPresenter = { _ in }
            browser.operationResultPresenter = { _ in }
        }
    }
    private static func require(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ value: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !value() { try require(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func argument(_ name: String) throws -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { throw Failure(stage: "missing-phase") }
        return args[index + 1]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func key(_ window: NSWindow, code: UInt16 = 36, characters: String = "\r", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let value = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { throw Failure(stage: "native-key-unavailable") }
        return value
    }
    private static func settled(_ browser: BrowserViewController) async throws -> ArchiveTabController {
        try await wait("archive-owner-settled") { browser.currentArchive?.current == true && browser.currentArchive?.busy == false && browser.currentArchive?.table != nil && browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
        guard let owner = browser.currentArchive else { throw Failure(stage: "archive-owner-missing") }
        return owner
    }
    private static func local(_ browser: BrowserViewController, at source: URL) async throws {
        browser.navigate(to: .directory(source))
        try await wait("local-source-listing") { !browser.isLoading && browser.orderingTask == nil && browser.location == .directory(source) }
    }
    private static func sendLocalOpen(_ browser: BrowserViewController, _ url: URL) async throws {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "source-command-root") }
        let source = URL(fileURLWithPath: raw).appendingPathComponent("source")
        try require(url.isFileURL && url.deletingLastPathComponent().path == source.path
            && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && ["Review.tar", "Review.zip", "Mutable.zip", "Ordinary.txt"].contains(url.lastPathComponent), "source-command-generated-file-guard")
        try await local(browser, at: url.deletingLastPathComponent())
        try require(browser.rowsByURL[url] != nil, "generated-archive-row-missing")
        guard let window = browser.view.window else { throw Failure(stage: "source-command-window-missing") }
        window.makeKeyAndOrderFront(nil); browser.workspace?.activate(browser, focus: false)
        try require(window.makeFirstResponder(browser.table), "source-table-refused-focus")
        browser.setFileSelection([url]); browser.fileSelectionDidChange()
        guard let action = browser.table.doubleAction else { throw Failure(stage: "local-double-action-missing") }
        try require(NSApp.sendAction(action, to: browser.table.target, from: browser.table), "local-double-action-undelivered")
    }
    private static func open(_ browser: BrowserViewController, _ url: URL) async throws -> ArchiveTabController {
        let tab = browser.activeID
        try await sendLocalOpen(browser, url)
        let result = try await settled(browser)
        try require(browser.activeID == tab && result.source == url && browser.location.isArchive,
                    "archive-open-did-not-reuse-current-tab")
        try await wait("completed-archive-content-focus") { browser.view.window?.firstResponder === result.table }
        return result
    }
    private static func path(_ browser: BrowserViewController) -> [String]? {
        if case .archive(let value) = browser.location { return value.folderPath }; return nil
    }
    private static func select(_ name: String, owner: ArchiveTabController) async throws {
        try await wait("actual-native-member-page-rendered") { owner.hasRenderedCurrentRowsForVerification }
        let paths: [String]
        if let model = owner.zipModelForVerification { paths = model.visibleItems.map(\.path) }
        else if let model = owner.tarModelForVerification { paths = model.items.map(\.path) }
        else { throw Failure(stage: "typed-model-unavailable") }
        guard let index = paths.firstIndex(where: { $0.utf8.elementsEqual(name.utf8) }), let table = owner.table else {
            throw Failure(stage: "expected-member-not-in-visible-page")
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if let model = owner.zipModelForVerification {
            let chosen = model.visibleItems[index].id
            try await wait("actual-native-zip-selection-acknowledged") { model.selection == [chosen] }
        } else if let model = owner.tarModelForVerification {
            let chosen = model.items[index].id
            try await wait("actual-native-tar-selection-acknowledged") { model.selection == [chosen] }
        }
    }
    static func run() async {
        var context: Context?, root: URL?, phase = "", failure: String?
        do {
            phase = try argument("--inline-phase")
            guard ["navigation", "ownership", "extraction", "stress", "capacity", "routing", "persistence"].contains(phase),
                  let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope") }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("inline-admission.json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "inline-archive-native"
                && admission?["master"] as? String == "7B4FE5D0-444E-4676-A91F-25E69FDDAF8D" && admission?["phase"] as? String == phase
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"), "scope-identity")
            root = area
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.opensArchivesInTraverse = true; settings.keyboardProfile = .explorer
            settings.motion.mode = .reduced; settings.viewMode = .details
            let windowOwner = BrowserWindowController(settings: settings)
            let test = Context(root: area, owner: windowOwner); context = test
            try require(windowOwner.isWorkspacePresentation, "inline-check-needs-real-workspace")
            let workspace = windowOwner.workspace
            workspace.willStartBrowserForVerification = { [weak test] in test?.configure($0) }
            workspace.sessionReady = true
            guard let window = windowOwner.window else { throw Failure(stage: "source-window-missing") }
            window.title = "Inline archives · generated verification"
            window.setContentSize(.init(width: ["stress", "capacity"].contains(phase) ? 1800 : 1500, height: 950))
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            test.configure(test.browser)
            try await local(test.browser, at: test.source)
            switch phase {
            case "navigation": try await navigation(test)
            case "ownership": try await ownership(test)
            case "extraction": try await extraction(test)
            case "stress": try await stress(test)
            case "capacity": try await capacity(test)
            case "routing": try await routing(test)
            case "persistence": try await persistence(test)
            default: throw Failure(stage: "unknown-phase")
            }
            try require(test.externalOpenURLs == test.expectedDefaultOpenURLs, "unexpected-generated-default-open-sequence")
        } catch { failure = (error as? Failure)?.stage ?? "unexpected-\(String(reflecting: type(of: error)))" }
        context?.holds.forEach { $0.release() }
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        await ApplicationZIPBrowser.shared.stopAndDrain(); await ApplicationTARBrowser.shared.closeAndDrain()
        if let context {
            for controller in [context.owner] + context.extraWindowControllers { controller.suspendBrowsing() }
        }
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        await ApplicationArchiveExports.shared.closeAndDrain()
        if let context {
            for controller in [context.owner] + context.extraWindowControllers {
                for browser in controller.workspace.browsers.values { browser.recoveryWindow?.close() }
                await controller.flushSession(); controller.window?.close()
            }
        }
        let pool = ArchiveTabCatalogPool.shared, active = ApplicationFileActivity.gate.activeCount
        if failure == nil && (pool.retainedCountForVerification != 0 || pool.retiringCountForVerification != 0 || active != 0
                              || ApplicationArchiveExports.shared.countForVerification != 0) { failure = "actual-owner-activity-export-drain" }
        if let root {
            let value: [String: Any] = ["passed": failure == nil, "failureStage": failure.map { $0 as Any } ?? NSNull(), "phase": phase,
                "checks": context?.checks ?? [], "metrics": context?.metrics ?? [:], "externalOpenCalls": context?.externalCalls ?? 0,
                "expectedDefaultOpenFiles": context?.expectedDefaultOpenURLs.map(\.lastPathComponent) ?? [],
                "observedDefaultOpenFiles": context?.externalOpenURLs.map { url in
                    url.deletingLastPathComponent().path == context?.source.path ? url.lastPathComponent : "<outside-generated-source>"
                } ?? [], "extraWindowsTracked": context?.extraWindowControllers.count ?? 0,
                "poolRetainedAfter": pool.retainedCountForVerification, "poolRetiringAfter": pool.retiringCountForVerification,
                "activityAfter": active, "exportsAfter": ApplicationArchiveExports.shared.countForVerification,
                "generatedOnly": true, "explicitExtraction": phase == "extraction", "sourceReplacementPerformed": context?.metrics["sourceReplacementPerformed"] as? Bool ?? false,
                "physicalPointer": false, "spokenAccessibility": false, "networkRequests": 0, "keychainCalls": 0]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/inline-archive-native.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }

    private static func navigation(_ test: Context) async throws {
        let browser = test.browser
        let tar = try await open(browser, test.source.appendingPathComponent("Review.tar"))
        try require(tar.tarModelForVerification?.items.map(\.name) == ["Folder", "Note.txt"], "tar-root-page")
        try require(ApplicationTARBrowser.shared.controller == nil && ApplicationZIPBrowser.shared.controller == nil, "inline-open-created-independent-window")
        try await select("Folder", owner: tar)
        guard let tarTable = tar.table, let window = test.owner.window else { throw Failure(stage: "tar-table-missing") }
        window.makeFirstResponder(tarTable); tarTable.keyDown(with: try key(window))
        _ = try await settled(browser)
        try require(path(browser) == ["Folder"] && tar.tarModelForVerification?.items.map(\.name) == ["Empty", "Member.txt"], "tar-return-folder-history")
        browser.goBack(nil); _ = try await settled(browser)
        try require(path(browser) == [], "tar-back-root")
        browser.goForward(nil); _ = try await settled(browser)
        try require(path(browser) == ["Folder"], "tar-forward-folder")
        test.checks.append("Actual TAR doubleAction reuses its tab; native Return and common Back/Forward follow the virtual folder")

        let zipURL = test.source.appendingPathComponent("Review.zip")
        let zip = try await open(browser, zipURL)
        try require(zip.zipModelForVerification?.visibleItems.count == 256
            && zip.zipModelForVerification?.visibleItems.contains(where: { $0.path == "Target" }) == false, "zip-bounded-first-page")
        guard let next = descendants(zip.view).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "archiveNextPage" && $0.isEnabled }) else { throw Failure(stage: "zip-next-button-missing") }
        next.performClick(nil); _ = try await settled(browser)
        try require(zip.state.offset == 256, "zip-native-next-page")
        try await select("Target", owner: zip)
        guard let zipTable = zip.table else { throw Failure(stage: "zip-table-missing") }
        window.makeFirstResponder(zipTable); zipTable.keyDown(with: try key(window))
        _ = try await settled(browser)
        try require(path(browser) == ["Target"], "zip-return-target")
        zipTable.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try await wait("zip-header-sort") { zip.current && !zip.busy && zip.state.sortField == .size && !zip.state.ascending }
        zipTable.keyDown(with: try key(window, code: 3, characters: "f", flags: .command))
        try await wait("archive-find-native-editor") { browser.filterField.currentEditor() != nil }
        guard let editor = browser.filterField.currentEditor() as? NSTextView else { throw Failure(stage: "archive-find-editor-missing") }
        editor.selectAll(nil); editor.insertText("Item-0399", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        try await wait("archive-find-results") { zip.current && !zip.busy && zip.state.query == "Item-0399" && zip.zipModelForVerification?.visibleItems.count == 1 }
        try await select("Target/Item-0399.txt", owner: zip)
        let criteria = zip.snapshot()
        test.snapshotDuringEditorEnd = nil
        let endObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: browser.filterField, queue: .main) { _ in
            MainActor.assumeIsolated { test.snapshotDuringEditorEnd = try? test.owner.workspace.captureSessionSnapshot(syncViewState: true) }
        }
        defer { NotificationCenter.default.removeObserver(endObserver) }
        browser.goBack(nil); _ = try await settled(browser)
        NotificationCenter.default.removeObserver(endObserver)
        try require(path(browser) == [] && zip.state.offset == 256 && zip.state.selectedPaths == ["Target"], "root-page-selection-restored")
        let capturedSession = test.snapshotDuringEditorEnd?.panes.first(where: { $0.id == browser.paneID })?.tabs
        var captured: ArchiveBrowseState?
        if let capturedSession { captured = capturedSession.tabs[capturedSession.activeTab].archiveState }
        try require(captured?.offset == 256 && captured?.query == "" && captured?.selectedPaths == ["Target"], "editor-end-reentrancy-overwrote-new-visit")
        browser.goForward(nil); _ = try await settled(browser)
        try require(path(browser) == ["Target"] && zip.state.query == criteria.query && zip.state.sortField == criteria.sortField
            && zip.state.selectedPaths == criteria.selectedPaths, "folder-criteria-selection-restored")
        test.checks.append("ZIP Next, header sort, native Find and common history restore exact page/query/order/member selection")

        let deep = try ArchiveLocation(source: zipURL, format: .zip, folderPath: ["Target", "Deep"])
        browser.navigate(to: .archive(deep)); _ = try await settled(browser)
        try require(zip.zipModelForVerification?.visibleItems.map(\.path) == ["Target/Deep/Leaf.txt"], "folder-lookup-beyond-visible-root-page")
        let long = String(repeating: "L", count: 300)
        browser.navigate(to: .archive(try ArchiveLocation(source: zipURL, format: .zip, folderPath: [long])))
        _ = try await settled(browser)
        try require(zip.zipModelForVerification?.visibleItems.first?.path == long + "/Long.txt", "long-zip-browse-path-regressed-to-extraction-limit")
        browser.navigate(to: .archive(try ArchiveLocation(source: zipURL, format: .zip)))
        _ = try await settled(browser)
        browser.goUp(nil)
        try await wait("archive-root-up-real-folder") { browser.location == .directory(test.source) && !browser.isLoading && browser.orderingTask == nil }
        try require(browser.orderedSelectedURLs == [zipURL], "archive-root-up-source-selection")
        test.checks.append("Exact value paths resolve beyond256 rows; long ZIP names remain browsable and root Up restores the real source selection")
        _ = try await open(browser, zipURL)
        try await hiddenRows(test, browser: browser)
    }

    private static func hiddenRows(_ test: Context, browser: BrowserViewController) async throws {
        let sentinel = test.source.appendingPathComponent("Ordinary.txt")
        let stale = FileEntry(url: sentinel, name: "Ordinary.txt", kind: .file)
        browser.rawEntries = [stale]; browser.displayedEntries = [stale]; browser.rowsByURL = [sentinel: 0]
        browser.table.reloadData(); browser.table.selectRowIndexes([0], byExtendingSelection: false)
        let before = browser.transferPasteboard.changeCount
        let selectors = [#selector(BrowserViewController.copyFileURLs(_:)), #selector(BrowserViewController.cutFileURLs(_:)),
            #selector(BrowserViewController.pasteFileURLs(_:)), #selector(BrowserViewController.renameSelection(_:)),
            #selector(BrowserViewController.trashSelection(_:)), #selector(BrowserViewController.showProperties(_:)),
            #selector(BrowserViewController.openWithSelection(_:)), #selector(BrowserViewController.shareSelection(_:)),
            #selector(BrowserViewController.showQuickLook(_:)), #selector(BrowserViewController.editPrivateNames(_:))]
        try require(browser.orderedSelectedURLs.isEmpty && browser.orderedSelectedURLs(upTo: 2).isEmpty
            && browser.selectedURLs.isEmpty && browser.selectedItemCount == 0 && browser.visibleFileEntries.isEmpty
            && browser.location.directoryURL == nil, "hidden-local-selection-leaked")
        try require(selectors.allSatisfy { !browser.commandEnabled($0) }, "archive-enabled-local-operation")
        var prompts = 0
        browser.operationNamePrompt = { _, _ in prompts += 1; return nil }
        browser.operationTrashPrompt = { _ in prompts += 1; return false }
        for action in selectors { _ = NSApp.sendAction(action, to: browser, from: nil) }
        await Task.yield()
        try require(prompts == 0 && browser.operationTask == nil && browser.operationPreparationTask == nil
            && browser.cutPreparationTask == nil && browser.transferPasteboard.changeCount == before && test.externalCalls == 0,
            "direct-local-action-bypassed-archive-boundary")
        browser.rawEntries = []; browser.displayedEntries = []; browser.rowsByURL = [:]; browser.table.deselectAll(nil); browser.table.reloadData()
        test.checks.append("Injected selected hidden local rows cannot supply URLs, clipboard, rename/trash, Properties, Open With, Share or preview authority")
    }

    private static func ownership(_ test: Context) async throws {
        let workspace = test.owner.workspace, browser = test.browser
        let original = try await open(browser, test.source.appendingPathComponent("Review.zip")), tab = browser.activeID
        let state = ArchiveBrowseState(query: "Folder-0299", sortField: .size, ascending: false)
        if case .archive(let location) = browser.location {
            browser.tabs[browser.activeIndex].archiveState = state; original.present(location, state: state, from: browser)
        }
        _ = try await settled(browser)
        browser.newTab(nil); try await local(browser, at: test.source)
        try require(workspace.splitActive(at: .trailing), "native-pane-split-refused")
        let peer = workspace.activeBrowser
        try require(peer !== browser && workspace.moveTab(tab, from: browser, into: peer, before: nil), "archive-tab-transfer-refused")
        let moved = try await settled(peer)
        try require(moved === original && moved.browser === peer && moved.snapshot().query == state.query, "archive-owner-transfer-lost-identity-or-state")
        peer.duplicateTab(id: tab)
        let duplicate = try await settled(peer)
        try require(duplicate !== moved && duplicate.id != moved.id && duplicate.tabID != moved.tabID
            && duplicate.source == moved.source && duplicate.snapshot().query == moved.snapshot().query, "archive-duplicate-reused-authority-or-lost-state")
        peer.selectTab(tab); _ = try await settled(peer)
        try require(peer.currentArchive === original, "archive-tab-isolation")
        test.checks.append("Pane tab transfer retains/rebinds the exact owner; duplication acquires an independent owner and tabs retain separate view state")

        guard let model = moved.zipModelForVerification else { throw Failure(stage: "ownership-zip-model-missing") }
        let hold = Hold(); test.holds.append(hold)
        model.beforePageForVerification = { await hold.pause() }
        moved.setQuery("No-match-held-page")
        try await wait("held-actual-page-entered") { hold.entered }
        moved.stop()
        try require(!moved.current && ArchiveTabCatalogPool.shared.retainedCountForVerification >= 1, "stop-released-owner-before-real-page-return")
        hold.release(); await moved.drain(); model.beforePageForVerification = nil
        try require(!moved.current, "stopped-page-published-late-result")
        moved.refresh(); _ = try await settled(peer)
        test.checks.append("Stop keeps a held actual ZIP page owner charged until return and rejects its stale result")

        let mutable = test.source.appendingPathComponent("Mutable.zip")
        let changed = try await open(peer, mutable)
        peer.navigate(to: .archive(try ArchiveLocation(source: mutable, format: .zip, folderPath: ["Target", "Deep"])))
        _ = try await settled(peer); try await select("Target/Deep/Leaf.txt", owner: changed)
        let replacement = test.source.appendingPathComponent("Replacement.zip")
        try await Task.detached { try Data(contentsOf: replacement).write(to: mutable) }.value
        test.metrics["sourceReplacementPerformed"] = true
        changed.zipModelForVerification?.extractSelected()
        try await wait("changed-source-review-refused") {
            guard let review = ApplicationArchiveExtraction.shared.controller?.model else { return false }
            return !review.isPreparing && review.plan == nil && review.notice.localizedCaseInsensitiveContains("changed")
        }
        try require(ApplicationArchiveExtraction.shared.controller?.model.canExtract == false, "changed-source-retained-extraction-authority")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        test.checks.append("Replacing only the generated source makes its previously selected catalog refuse extraction review")
        test.owner.window?.performClose(nil)
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        try require(ArchiveTabCatalogPool.shared.retainedCountForVerification == 0
            && ArchiveTabCatalogPool.shared.retiringCountForVerification == 0 && ApplicationFileActivity.gate.activeCount == 0,
            "window-close-did-not-drain-inactive-and-active-owners")
        test.checks.append("Actual source-window close drains every active/inactive archive owner")
    }

    private static func extraction(_ test: Context) async throws {
        let browser = test.browser
        let archive = try await open(browser, test.source.appendingPathComponent("Review.tar"))
        browser.navigate(to: .archive(try ArchiveLocation(source: archive.source, format: .tar, folderPath: ["Folder"])))
        _ = try await settled(browser); try await select("Folder/Member.txt", owner: archive)
        archive.tarModelForVerification?.extract(selected: true)
        try await wait("explicit-selected-extraction-review") { ApplicationArchiveExtraction.shared.controller?.model.canExtract == true }
        guard let review = ApplicationArchiveExtraction.shared.controller?.model else { throw Failure(stage: "selected-extraction-review-missing") }
        try require(review.summary?.files == 1 && review.summary?.bytes == 3 && review.tarMembers != nil, "selected-extraction-independent-oracle")
        let archivedTab = browser.activeID
        browser.newTab(nil); try await local(browser, at: test.source); browser.closeTab(id: archivedTab)
        await archive.closeAndDrain()
        try require(archive.isClosed, "source-archive-host-not-retired")
        review.extract()
        try await wait("explicit-extraction-result") { review.outcome != nil && !review.isRunning }
        guard let outcome = review.outcome, let output = outcome.result.items.first?.destination else { throw Failure(stage: "extraction-output-missing") }
        try require(outcome.result.disposition == .succeeded && review.canUndo && review.canViewResults,
                    "extraction-after-host-retirement-failed")
        try require(try await Task.detached { try Data(contentsOf: output.appendingPathComponent("Folder/Member.txt")) == Data("abc".utf8) }.value,
                    "extracted-generated-member-bytes")
        review.viewResults()
        try await wait("extraction-results-reachable") { browser.recoveryWindow?.window?.isVisible == true }
        browser.recoveryWindow?.close()
        review.undo()
        try await wait("selected-extraction-undo") { review.undoOutcome != nil && !review.isRunning }
        try require(review.undoOutcome?.result.disposition == .succeeded && !FileManager.default.fileExists(atPath: output.path), "selected-extraction-undo-output")
        let history = try await browser.recoverableFileOperations!.inspectExistingHistory()
        try require(history.records.count == 1 && history.records[0].operation == "Extract TAR", "extraction-truthful-history")
        test.metrics["extractionOperation"] = outcome.recordID?.uuidString ?? ""
        test.checks.append("Explicit selected TAR extraction retains source authority after archive-tab retirement, copies exact generated bytes, exposes Results and reaches guarded Undo")
    }

    private static func capacityInactiveTabs(_ test: Context) async throws {
        let browser = test.browser, zipURL = test.source.appendingPathComponent("Review.zip")
        var tabIDs = [UUID](), owners = [ArchiveTabController](), states = [ArchiveBrowseState]()
        for index in 0..<5 {
            if index > 0 { browser.newTab(nil) }
            let owner = try await open(browser, zipURL)
            let member = String(format: "Folder-%03d", 295 + index)
            owner.setQuery(member)
            try await wait("capacity-tab-query") { owner.current && !owner.busy && owner.state.query == member
                && owner.zipModelForVerification?.visibleItems.count == 1 }
            owner.table?.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
            try await wait("capacity-tab-sort") { owner.current && !owner.busy && owner.state.sortField == .size && !owner.state.ascending }
            try await select(member, owner: owner)
            tabIDs.append(browser.activeID); owners.append(owner); states.append(owner.snapshot())
            try require(ArchiveTabCatalogPool.shared.retainedCountForVerification <= 4, "inactive-catalog-pool-exceeded-four")
        }
        browser.newTab(nil); try await local(browser, at: test.source)
        try await wait("exact-first-inactive-lru-drained") { owners[0].isClosed && owners[0].zipModelForVerification == nil }
        try require(owners.allSatisfy { !$0.isPresented } && owners.dropFirst().allSatisfy { !$0.isClosed }
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4
            && ArchiveTabCatalogPool.shared.retiringCountForVerification == 0,
            "inactive-lru-evicted-wrong-owner-or-retained-activity")
        try require(zip(tabIDs, states).allSatisfy { pair in browser.tabs.first(where: { $0.id == pair.0 })?.archiveState == pair.1 },
                    "inactive-lru-discarded-value-state")
        browser.selectTab(tabIDs[0])
        let reopened = try await settled(browser)
        try await wait("exact-second-inactive-lru-drained") { owners[1].isClosed && owners[1].zipModelForVerification == nil }
        try require(reopened !== owners[0] && reopened.id != owners[0].id && reopened.tabID == tabIDs[0]
            && reopened.snapshot() == states[0] && owners.dropFirst(2).allSatisfy { !$0.isClosed }
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4
            && ArchiveTabCatalogPool.shared.retiringCountForVerification == 0,
            "evicted-tab-did-not-reacquire-fresh-exact-state")
        test.metrics["inactiveArchiveTabs"] = tabIDs.count
        test.metrics["inactiveLRUVictims"] = [owners[0].id.uuidString, owners[1].id.uuidString]
        test.checks.append("Five inactive archive tabs retain at most four catalogs; exact LRU owners actually close and reopening acquires a fresh owner with saved query/order/selection")
    }

    private static func capacity(_ test: Context) async throws {
        try await capacityInactiveTabs(test)
        let zipURL = test.source.appendingPathComponent("Review.zip"), settings = test.browser.settings
        let ids = [UUID(), UUID(), UUID(), UUID()]
        var layout = PaneLayout(paneID: ids[0])
        try layout.split(ids[0], inserting: ids[1], at: .trailing)
        try layout.split(ids[0], inserting: ids[2], at: .bottom)
        try layout.split(ids[1], inserting: ids[3], at: .bottom)
        let location = try ArchiveLocation(source: zipURL, format: .zip)
        let panes = try ids.map { id -> PaneWorkspaceSnapshot.Pane in
            let tab = BrowserTab(location: .archive(location))
            return .init(id: id, tabs: try WorkspaceSession.capture([tab], activeID: tab.id), viewMode: "Details")
        }
        let workspace = test.owner.workspace
        try workspace.applyRestoredSnapshot(.init(layout: layout, activePane: ids[0], panes: panes))
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        for pane in workspace.browsers.values { test.configure(pane); pane.loadLocation() }
        try await wait("four-small-active-catalogs") { workspace.browsers.values.allSatisfy {
            $0.currentArchive?.current == true && $0.currentArchive?.busy == false
        } }
        let activeOwners = ids.compactMap { workspace.browsers[$0]?.currentArchive }
        try require(activeOwners.count == 4 && Set(activeOwners.map(\.id)).count == 4
            && activeOwners.allSatisfy { $0.isPresented && !$0.isClosed }
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4, "four-active-small-catalogs-not-protected")

        let extra = BrowserWindowController(settings: settings)
        test.extraWindowControllers.append(extra)
        try require(extra.isWorkspacePresentation, "capacity-extra-window-not-workspace")
        extra.workspace.sessionReady = true
        extra.workspace.willStartBrowserForVerification = { [weak test] in test?.configure($0) }
        let fifthBrowser = extra.workspace.activeBrowser
        test.configure(fifthBrowser)
        guard let fifthWindow = extra.window else { throw Failure(stage: "capacity-extra-window-missing") }
        fifthWindow.title = "Fifth archive · generated capacity verification"
        fifthWindow.setContentSize(.init(width: 1000, height: 720)); fifthWindow.center(); fifthWindow.makeKeyAndOrderFront(nil)
        try await sendLocalOpen(fifthBrowser, zipURL)
        try await wait("fifth-active-catalog-truthful-refusal") {
            guard let blocked = fifthBrowser.currentArchive else { return false }
            return !blocked.busy && !blocked.current && blocked.table == nil && capacityNotice(blocked) != nil
        }
        guard let blocked = fifthBrowser.currentArchive, let message = capacityNotice(blocked) else {
            throw Failure(stage: "capacity-refusal-message-missing")
        }
        try require(!blocked.isClosed && blocked.zipModelForVerification == nil
            && activeOwners.allSatisfy { $0.isPresented && !$0.isClosed && $0.current }
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4 && test.externalOpenURLs.isEmpty,
            "fifth-active-owner-displaced-an-active-catalog-or-handed-off")
        test.metrics["fifthCatalogRefusal"] = message
        test.checks.append("Four active pane catalogs protect their ownership; the fifth independent window shows close-an-archive/Refresh and never exceeds four or invokes the system")

        guard let releasedBrowser = workspace.browsers[ids[0]] else { throw Failure(stage: "capacity-release-pane-missing") }
        let released = activeOwners[0]
        try await local(releasedBrowser, at: test.source)
        try require(!released.isPresented && !released.isClosed, "capacity-source-navigation-did-not-make-owner-inactive")
        try require(NSApp.sendAction(#selector(BrowserViewController.refresh(_:)), to: fifthBrowser, from: nil), "capacity-refresh-action-undelivered")
        let admitted = try await settled(fifthBrowser)
        try require(admitted === blocked && released.isClosed && released.zipModelForVerification == nil
            && activeOwners.dropFirst().allSatisfy { !$0.isClosed && $0.current && $0.isPresented }
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4
            && ArchiveTabCatalogPool.shared.retiringCountForVerification == 0 && test.externalOpenURLs.isEmpty,
            "fifth-refresh-did-not-await-exact-eligible-eviction")
        test.metrics["fifthRetryEvictedOwner"] = released.id.uuidString
        test.checks.append("Navigating one active archive away makes only it evictable; actual Refresh drains that owner before the fifth catalog succeeds")
    }

    private static func capacityNotice(_ owner: ArchiveTabController) -> String? {
        descendants(owner.view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue).first { value in
            let text = value.lowercased()
            return text.contains("close") && text.contains("archive") && (text.contains("refresh") || text.contains("retry"))
        }
    }

    private static func routing(_ test: Context) async throws {
        let browser = test.browser, text = test.source.appendingPathComponent("Ordinary.txt"), zipURL = test.source.appendingPathComponent("Review.zip")
        test.expectedDefaultOpenURLs = [text, zipURL]
        try await sendLocalOpen(browser, text)
        try require(test.externalOpenURLs == [text] && browser.location == .directory(test.source) && browser.currentArchive == nil,
                    "ordinary-text-did-not-use-exact-default-open-boundary")
        browser.settings.opensArchivesInTraverse = false
        try await sendLocalOpen(browser, zipURL)
        try require(test.externalOpenURLs == [text, zipURL] && browser.location == .directory(test.source) && browser.currentArchive == nil,
                    "archive-open-optout-did-not-use-original-zip")
        test.checks.append("Actual ordinary-text Open and archive preference opt-out reach exactly the two generated original-file default-open URLs")

        guard let window = browser.view.window else { throw Failure(stage: "routing-window-missing") }
        try require(window.makeFirstResponder(browser.table), "routing-browse-source-focus")
        try require(NSApp.sendAction(#selector(BrowserViewController.browseZIP(_:)), to: browser, from: nil), "explicit-browse-action-undelivered")
        let explicit = try await settled(browser)
        try require(explicit.source == zipURL && !browser.settings.opensArchivesInTraverse
            && test.externalOpenURLs == test.expectedDefaultOpenURLs, "explicit-browse-depended-on-default-open-preference")
        try await wait("explicit-browse-content-focus") { window.firstResponder === explicit.table }
        test.checks.append("Explicit Browse Archive remains in Traverse when natural archive Open is opted out")

        try await local(browser, at: test.source)
        browser.settings.keyboardProfile = .mac
        browser.setFileSelection([zipURL]); browser.fileSelectionDidChange()
        window.makeKeyAndOrderFront(nil); browser.workspace?.activate(browser, focus: false)
        try require(window.makeFirstResponder(browser.table), "mac-return-source-focus")
        browser.table.keyDown(with: try key(window))
        try await wait("routing-mac-return-rename") { browser.inlineRename.isEditing }
        try require(browser.location == .directory(test.source) && browser.currentArchive == nil
            && test.externalOpenURLs == test.expectedDefaultOpenURLs, "mac-return-opened-instead-of-renamed")
        guard let field = browser.inlineRename.field, let editor = field.currentEditor() as? NSTextView else {
            throw Failure(stage: "mac-rename-native-editor-missing")
        }
        try require(browser.inlineRename.control(field, textView: editor, doCommandBy: NSSelectorFromString("cancelOperation:")),
                    "mac-rename-cancel-command-undelivered")
        try await wait("routing-mac-rename-cancel-drain") { !browser.inlineRename.isEditing && browser.operationPreparationTask == nil }
        try require(browser.operationTask == nil && browser.orderedSelectedURLs == [zipURL]
            && test.externalOpenURLs == test.expectedDefaultOpenURLs, "mac-cancel-mutated-selection-or-started-file-operation")
        let history = try await browser.recoverableFileOperations!.inspectExistingHistory()
        try require(history.records.isEmpty, "cancelled-mac-rename-created-operation-history")
        test.checks.append("Mac Return enters the native Rename editor; its Cancel command drains preparation without an operation record or external Open")

        browser.settings.opensArchivesInTraverse = true; browser.settings.keyboardProfile = .explorer
        try require(window.makeFirstResponder(browser.table), "explorer-return-source-focus")
        let originalTab = browser.activeID
        browser.table.keyDown(with: try key(window))
        let opened = try await settled(browser)
        try require(opened.source == zipURL && browser.activeID == originalTab
            && test.externalOpenURLs == test.expectedDefaultOpenURLs, "explorer-return-did-not-open-current-inline-tab")
        try await wait("explorer-return-content-focus") { window.firstResponder === opened.table }
        test.checks.append("Explorer Return naturally opens the current archive tab and transfers content focus without another default-app handoff")
    }

    private static func persistence(_ test: Context) async throws {
        let archivePane = try await persistencePaneDefaults(test)
        try await persistenceFollowingProfile(test, browser: archivePane)
    }

    private static func persistencePaneDefaults(_ test: Context) async throws -> BrowserViewController {
        let workspace = test.owner.workspace, source = test.browser
        source.paneViewMode = .icons
        _ = try await open(source, test.source.appendingPathComponent("Review.zip"))
        let archiveTab = source.activeID
        try require(source.paneViewMode == .icons && source.effectiveViewMode == .details, "persistence-source-icons-forced-details")
        try require(workspace.splitActive(at: .trailing), "persistence-native-icons-split-refused")
        let split = workspace.activeBrowser
        _ = try await settled(split)
        try require(split !== source && split.paneViewMode == .icons && split.effectiveViewMode == .details,
                    "persistence-split-saved-forced-details-as-default")
        let splitSnapshot = try workspace.captureSessionSnapshot(syncViewState: true)
        try require(splitSnapshot.panes.first(where: { $0.id == split.paneID })?.viewMode == BrowserViewMode.icons.rawValue,
                    "persistence-split-snapshot-lost-icons")
        try await local(split, at: test.source)
        try require(split.effectiveViewMode == .icons, "persistence-split-local-icons-not-restored")
        test.checks.append("Actual Split while an archive forces Details preserves the underlying Icons default in the pane, snapshot and next local folder")

        source.newTab(nil); try await local(source, at: test.source)
        source.selectTab(archiveTab); _ = try await settled(source)
        source.paneViewMode = .list
        workspace.activate(source, focus: false)
        try require(source.tabs.count > 1 && source.effectiveViewMode == .details, "persistence-list-move-source")
        try require(workspace.moveTab(archiveTab, from: source, beside: split, edge: .bottom), "persistence-native-list-move-refused")
        let moved = workspace.activeBrowser
        _ = try await settled(moved)
        try require(moved !== source && moved !== split && moved.activeID == archiveTab
            && moved.paneViewMode == .list && moved.effectiveViewMode == .details, "persistence-move-saved-forced-details-as-default")
        let movedSnapshot = try workspace.captureSessionSnapshot(syncViewState: true)
        try require(movedSnapshot.panes.first(where: { $0.id == moved.paneID })?.viewMode == BrowserViewMode.list.rawValue,
                    "persistence-move-snapshot-lost-list")
        try await local(moved, at: test.source)
        try require(moved.effectiveViewMode == .list, "persistence-move-local-list-not-restored")
        _ = try await open(moved, test.source.appendingPathComponent("Review.zip"))
        test.checks.append("Actual Move Tab beside a pane preserves the underlying List default while Details is forced, and the next local folder uses List")
        return moved
    }

    private static func persistenceFollowingProfile(_ test: Context, browser: BrowserViewController) async throws {
        let workspace = test.owner.workspace
        try require(!browser.settings.restoresSession && workspace.activeBrowser === browser,
                    "persistence-following-needs-independent-session-policy")
        let templatesDirectory = test.root.appendingPathComponent("state/ArchiveProfileTemplates", isDirectory: true)
        let workingDirectory = test.root.appendingPathComponent("state/ArchiveProfileWorking", isDirectory: true)
        let templates = LaunchProfileStore(directory: templatesDirectory), memory = WorkspaceProfileStore(directory: workingDirectory)
        workspace.launchProfileStore = templates; workspace.profileWorkspaceStore = memory
        let template = try workspace.captureLaunchProfile(includeFilters: true)
        let saved = try await templates.edit(expected: nil) { try $0.add(name: "Generated archive workspace", snapshot: template, includeFilters: true) }
        guard let profile = saved.library.profiles.first else { throw Failure(stage: "persistence-generated-profile-missing") }
        let following = workspace.profileWorkspaces
        following.noteStartupTemplate(profile, key: try await memory.key(for: profile))
        try await following.setRemembering(true, for: profile)
        try require(following.isFollowing && !browser.settings.restoresSession, "persistence-following-was-not-independent")
        guard let owner = browser.currentArchive else { throw Failure(stage: "persistence-live-archive-missing") }
        owner.setQuery("Folder-299")
        try await wait("persistence-following-live-query") {
            owner.current && !owner.busy && owner.state.query == "Folder-299" && owner.zipModelForVerification?.visibleItems.count == 1
        }
        owner.table?.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try await wait("persistence-following-live-sort") { owner.current && !owner.busy && owner.state.sortField == .size && !owner.state.ascending }
        try await select("Folder-299", owner: owner)
        await following.flush(closing: false)
        let expected = ArchiveBrowseState(query: "Folder-299", sortField: .size, ascending: false)
        let fresh = WorkspaceProfileStore(directory: workingDirectory)
        guard let persisted = try await fresh.load().memory.record(for: profile.id),
              let pane = persisted.snapshot.panes.first(where: { $0.id == browser.paneID }) else {
            throw Failure(stage: "persistence-working-record-not-readable")
        }
        let archived = pane.tabs.tabs[pane.tabs.activeTab]
        try require(archived.location.kind == .archive && archived.location.url == nil && archived.location.connection == nil
            && archived.location.archive?.source == test.source.appendingPathComponent("Review.zip")
            && archived.archiveState == expected && pane.viewMode == BrowserViewMode.list.rawValue,
                    "persistence-working-profile-dropped-live-query-sort-or-local-default")
        let restored = try pane.tabs.restoredTabs()
        guard let activeRestored = restored.tabs.first(where: { $0.id == restored.activeID }) else {
            throw Failure(stage: "persistence-working-profile-restored-active-tab-missing")
        }
        try require(activeRestored.location.isArchive && activeRestored.location.directoryURL == nil
            && activeRestored.archiveState == expected, "persistence-working-profile-restored-fake-local-or-dropped-state")
        let withoutFilters = try workspace.captureWorkingProfile(includeFilters: false)
        guard let cleared = withoutFilters.panes.first(where: { $0.id == browser.paneID })?.tabs else {
            throw Failure(stage: "persistence-filterless-pane-missing")
        }
        let clearedState = cleared.tabs[cleared.activeTab].archiveState
        try require(clearedState == ArchiveBrowseState(sortField: .size, ascending: false)
            && owner.state.selectedPaths == ["Folder-299"], "persistence-template-clearing-changed-live-selection-or-sort")
        let unchangedTemplate = try await LaunchProfileStore(directory: templatesDirectory).load()
        try require(unchangedTemplate.library == saved.library, "persistence-working-save-mutated-launch-template")
        await following.flush(closing: true)
        let held = await memory.heldSessionsForVerification()
        try require(held == 0 && !following.isFollowing, "persistence-working-profile-actual-owner-drain")
        await templates.drain(); await fresh.drain(); await memory.drain()
        test.metrics["persistedArchiveProfile"] = true; test.metrics["profileOwnersAfter"] = held
        test.checks.append("A real generated following profile persists current archive query/sort with general session restore disabled; fresh store/read/restore preserves typed locations and local defaults")
        test.checks.append("Profile projection still clears selection/page/scroll and optional filters without clearing the live archive selection or rewriting its launch template; actual profile ownership drains")
    }

    private static func stress(_ test: Context) async throws {
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        var layout = PaneLayout(paneID: first)
        try layout.split(first, inserting: second, at: .trailing)
        try layout.split(first, inserting: third, at: .bottom)
        try layout.split(second, inserting: fourth, at: .bottom)
        let ids = [first, second, third, fourth]
        let panes = try ids.enumerated().map { index, id -> PaneWorkspaceSnapshot.Pane in
            let location = try ArchiveLocation(source: test.source.appendingPathComponent("Large-\(index).zip"), format: .zip)
            let tab = BrowserTab(location: .archive(location))
            return .init(id: id, tabs: try WorkspaceSession.capture([tab], activeID: tab.id), viewMode: "Details")
        }
        let snapshot = PaneWorkspaceSnapshot(layout: layout, activePane: first, panes: panes)
        try test.owner.workspace.applyRestoredSnapshot(snapshot)
        for browser in test.owner.workspace.browsers.values { test.configure(browser); browser.loadLocation() }
        try await wait("four-large-active-catalogs") {
            test.owner.workspace.browsers.values.allSatisfy { $0.currentArchive?.current == true && $0.currentArchive?.busy == false }
        }
        let owners = test.owner.workspace.browsers.values.compactMap(\.currentArchive)
        try require(owners.count == 4 && Set(owners.map(\.id)).count == 4
            && ArchiveTabCatalogPool.shared.retainedCountForVerification == 4
            && owners.allSatisfy { $0.zipModelForVerification?.summary?.files == 20_000 && $0.table?.numberOfRows == 256 },
            "four-large-catalog-count-bound")
        test.metrics["largeCatalogs"] = 4; test.metrics["recordsPerCatalog"] = 20_000
        test.checks.append("Four active independently generated20000-member zero-payload ZIP catalogs retain exactly four owners and expose only256 native rows each")
        test.owner.window?.performClose(nil)
    }
}
#endif
