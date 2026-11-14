#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

/// Generated native actions against the ordinary grouping adapter. No internal
/// engine proof constructors, fabricated results, personal scopes or Trash.
@MainActor enum SelectionGroupNativeVerification {
    private struct Failure: Error { let stage: String }
    private static let title = "Grouping · generated review · motion audit"
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Context {
        let root: URL, owner: BrowserWindowController, mode: String, phase: String
        let clipboardCount = NSPasteboard.general.changeCount
        var checks = [String](), clips = [[String: Any]](), layouts = [[String: Any]](), holds = [Hold]()
        var browsers = [BrowserViewController](), otherWindows = [BrowserWindowController]()
        var groupIDs = [UUID](), externalCalls = 0
        var observationGuardChecks = 0, pendingDisplays = 0, cleanupTargetDisplays = 0
        var browser: BrowserViewController { owner.workspace.activeBrowser }
        var items: URL { root.appendingPathComponent("source/Items") }
        var history: URL { root.appendingPathComponent("state/history") }
        var sources: [URL] { ["Alpha.txt", "Folder", "Empty"].map { items.appendingPathComponent($0) } }
        init(root: URL, owner: BrowserWindowController, mode: String, phase: String) { self.root = root; self.owner = owner; self.mode = mode; self.phase = phase }
        func configure(_ browser: BrowserViewController) {
            if !browsers.contains(where: { $0 === browser }) { browsers.append(browser) }
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.privateNames = ApplicationPrivateNames(directory: root.appendingPathComponent("state/Names"), settings: browser.settings)
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: history)
            browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
            browser.defaultOpenForVerification = { [weak self] _ in self?.externalCalls += 1; return false }
        }
        var engine: RecoverableFileOperations { browser.recoverableFileOperations! }
    }
    private static func require(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() { try require(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func argument(_ name: String) throws -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { throw Failure(stage: "missing-group-argument") }; return args[i+1]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func key(_ window: NSWindow, code: UInt16, text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw Failure(stage: "generated-key") }; return event
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        try await wait("group-browser-settled") { !browser.isLoading && browser.orderingTask == nil && browser.operationPreparationTask == nil && browser.operationTask == nil }
    }
    private static func local(_ test: Context) async throws {
        test.owner.window?.makeKeyAndOrderFront(nil); test.owner.workspace.activate(test.browser, focus: false)
        test.browser.navigate(to: .directory(test.items)); try await settled(test.browser)
        test.browser.focusBrowserContent()
    }
    private static func select(_ test: Context, _ urls: [URL]? = nil) throws {
        let browser = test.browser, selected = urls ?? test.sources
        try require(selected.allSatisfy { browser.rowsByURL[$0] != nil }, "generated-selection-visible")
        browser.setFileSelection(Set(selected)); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        try require(browser.orderedSelectedURLs.count == selected.count && Set(browser.orderedSelectedURLs) == Set(selected), "actual-selection-exact")
    }
    private static func command(_ browser: BrowserViewController) throws {
        let selector = #selector(BrowserViewController.newFolderWithSelection(_:))
        try require(browser.commandEnabled(selector) && NSApp.sendAction(selector, to: browser, from: nil), "ordinary-group-selector")
    }
    private static func editor(_ test: Context) async throws -> NSTextView {
        try await wait("group-native-field-editor") { test.browser.selectionGroupDraft.field?.currentEditor() is NSTextView }
        guard let editor = test.browser.selectionGroupDraft.field?.currentEditor() as? NSTextView else { throw Failure(stage: "group-field-editor-missing") }; return editor
    }
    private static func type(_ value: String, in editor: NSTextView) { editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)); editor.breakUndoCoalescing() }
    private static func enter(_ test: Context, _ value: String) async throws {
        let field = try await editor(test); type(value, in: field)
        guard let window = field.window else { throw Failure(stage: "group-field-window") }
        field.keyDown(with: try key(window, code: 36, text: "\r"))
    }
    private static func escape(_ test: Context) async throws {
        let field = try await editor(test); guard let window = field.window else { throw Failure(stage: "group-escape-window") }
        field.keyDown(with: try key(window, code: 53, text: "\u{1b}")); try await settled(test.browser)
        try require(!test.browser.selectionGroupDraft.isPresenting, "Escape-revokes-draft")
    }
    private static func history(_ test: Context) async throws -> OperationRecoveryInspection { try await test.engine.inspectExistingHistory() }
    private static func prompt(_ test: Context, title: String) async throws {
        try await wait("real-history-prompt") { test.owner.window?.attachedSheet != nil }
        guard let sheet = test.owner.window?.attachedSheet, let content = sheet.contentView,
              let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw Failure(stage: "history-prompt-real-button") }
        button.performClick(nil)
        try await wait("history-prompt-dismissed") { test.owner.window?.attachedSheet == nil }
    }
    private static func group(_ test: Context, name: String, urls: [URL]? = nil) async throws -> SelectionGroupResult {
        try await local(test); try select(test, urls); let before = test.browser.operationHistory.selectionGroup?.recordID
        try command(test.browser); try await enter(test, name)
        try await wait("group-actual-outcome") { test.browser.operationHistory.selectionGroup?.recordID != before && test.browser.operationTask == nil && test.browser.operationPreparationTask == nil }
        guard let result = test.browser.operationHistory.selectionGroup?.result else { throw Failure(stage: "typed-group-outcome") }
        try require(result.authoritative && result.state == .grouped && result.status == .succeeded && result.recordID != nil, "group-one-real-job")
        test.groupIDs.append(result.recordID!); try await settled(test.browser); return result
    }
    private static func review(_ test: Context, _ id: UUID) async throws -> SelectionGroupResultsWindow {
        test.browser.showSelectionGroupResults(recordID: id)
        try await wait("typed-review-drain") { test.browser.selectionGroupWindow?.review?.recordID == id && test.browser.selectionGroupWindow?.inspectionTask == nil }
        guard let window = test.browser.selectionGroupWindow else { throw Failure(stage: "typed-results-window") }
        try require(window.engine === test.engine && !window.isBusy && window.retainedAccess != nil, "typed-review-engine-access-bound")
        try observationDisplay(test, window)
        return window
    }
    private static func undo(_ test: Context, _ controller: SelectionGroupResultsWindow) async throws -> SelectionGroupResult {
        let before = controller.presentationID
        try require(controller.undoButtonForVerification.isEnabled, "actual-Undo-button-enabled")
        controller.undoButtonForVerification.performClick(nil)
        try await wait("actual-Undo-task-and-review-drain") { test.browser.operationTask == nil && controller.inspectionTask == nil && controller.presentationID != before }
        if controller.review != nil { try observationDisplay(test, controller) }
        guard let result = test.browser.operationHistory.selectionGroup?.result else { throw Failure(stage: "typed-Undo-result") }; return result
    }
    private static func closeReview(_ test: Context) async {
        guard let controller = test.browser.selectionGroupWindow else { return }
        controller.close(); await controller.drain()
        test.owner.window?.makeKeyAndOrderFront(nil); test.browser.focusBrowserContent()
    }

    static func run() async {
        var test: Context?, root: URL?, mode = "", phase = "", failure: String?
        do {
            mode = try argument("--group-mode"); phase = try argument("--group-phase")
            guard ["full-dark", "reduced-dark", "off-light150"].contains(mode), ["suite", "recover"].contains(phase),
                  let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "group-scope-arguments") }
            let area = URL(fileURLWithPath: raw).standardizedFileURL
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("selection-group-admission-\(phase).json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath().path == area.path && area.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-development").path
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent && marker?["action"] as? String == "selection-group-native"
                && marker?["packet"] as? String == "traverse-development-v1"
                && admission?["format"] as? String == "ordinary-selection-group-review-v1"
                && admission?["case"] as? String == area.lastPathComponent
                && admission?["mode"] as? String == mode && admission?["phase"] as? String == phase
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL.path == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app").path, "group-exact-generated-admission")
            root = area
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = mode == "off-light150" ? .light : .dark; settings.keyboardProfile = .explorer
            settings.motion.mode = mode == "full-dark" ? .full : mode == "reduced-dark" ? .reduced : .off
            settings.interfaceSize = InterfaceSize(mode == "off-light150" ? 150 : 100); InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings), current = Context(root: area, owner: owner, mode: mode, phase: phase); test = current
            try require(owner.isWorkspacePresentation && SelectionGroupFeature.available, "real-group-workspace-feature")
            owner.workspace.sessionReady = true; owner.workspace.willStartBrowserForVerification = { [weak current] in current?.configure($0) }
            current.configure(current.browser)
            if mode == "off-light150", let frame = owner.window?.screen?.visibleFrame {
                owner.window?.setContentSize(.init(width: min(1300, frame.width-40), height: min(860, frame.height-100)))
            } else { owner.window?.setContentSize(.init(width: 1120, height: 730)) }
            owner.window?.title = title; owner.window?.center(); owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await local(current)
            if phase == "recover" { try await coldRecovery(current) }
            else {
                try await preparation(current); try await naming(current); try await revocation(current)
                try await groupingAndResults(current); try await stopAndBusy(current); try await staleReview(current)
                let result = try await group(current, name: "RestartGroup", urls: [current.items.appendingPathComponent("Restart.txt")])
                try JSONSerialization.data(withJSONObject: ["recordID": result.recordID!.uuidString, "mode": mode], options: [.sortedKeys]).write(to: area.appendingPathComponent("evidence/group-restart.json"), options: .withoutOverwriting)
                current.checks.append("A real typed group remains for a separately reserved fresh-process review and Undo")
            }
            try require(NSPasteboard.general.changeCount == current.clipboardCount && current.externalCalls == 0, "clipboard-or-external-application-changed")
        } catch { failure = (error as? Failure)?.stage ?? (error as? NativeMotionRecorder.Failure).map { "motion-" + $0.rawValue } ?? "unexpected-\(String(reflecting: Swift.type(of: error)))" }
        if let test {
            test.holds.forEach { $0.release() }
            for browser in test.browsers {
                browser.beforeSelectionGroupPerformForVerification = nil; browser.beforeSelectionGroupReviewActionForVerification = nil
                browser.selectionGroupDraft.cancel(); browser.operationPreparationTask?.cancel(); browser.operationTask?.cancel()
                await browser.operationPreparationTask?.value; await browser.operationTask?.value
                browser.selectionGroupWindow?.close(); await browser.selectionGroupWindow?.drain()
                browser.recoveryWindow?.close(); browser.retentionInspectionTask?.cancel(); browser.recoveryInspectionTask?.cancel()
                await browser.retentionInspectionTask?.value; await browser.recoveryInspectionTask?.value
            }
            await SelectionGroupResultsWindow.closeAllAndDrain()
            test.otherWindows.forEach { $0.suspendBrowsing(); $0.window?.close() }
            test.owner.suspendBrowsing(); await test.owner.flushSession(); test.owner.window?.close()
            if failure == nil && (ApplicationFileActivity.gate.activeCount != 0
                || test.browser.operationCoordinator.activeOwner != nil || test.browser.operationCoordinator.preparationOwner != nil
                || test.browser.operationCoordinator.inspectionCount != 0 || SelectionGroupResultsWindow.pendingInspectionCountForVerification != 0) { failure = "group-actual-coordinator-worker-inspection-drain" }
        }
        if let root {
            let value: [String: Any] = ["passed": failure == nil, "failureStage": failure.map { $0 as Any } ?? NSNull(), "mode": mode, "phase": phase,
                "checks": test?.checks ?? [], "clips": test?.clips ?? [], "layouts": test?.layouts ?? [], "typedRecordIDs": test?.groupIDs.map(\.uuidString) ?? [],
                "activityAfter": ApplicationFileActivity.gate.activeCount, "engineWorkerCounter": "not publicly exposed; public operations awaited",
                "operationTasksAfter": test?.browsers.filter { $0.operationTask != nil || $0.operationPreparationTask != nil }.count ?? 0,
                "inspectionsAfter": ApplicationOperationCoordinator.shared.inspectionCount,
                "coordinatorIdle": ApplicationOperationCoordinator.shared.activeOwner == nil && ApplicationOperationCoordinator.shared.preparationOwner == nil,
                "clipboardUnchanged": test.map { NSPasteboard.general.changeCount == $0.clipboardCount } ?? false,
                "observationDisplayGuardChecks": test?.observationGuardChecks ?? 0,
                "pendingEdgeDisplaysExercised": test?.pendingDisplays ?? 0,
                "verifiedCleanupTargetDisplaysExercised": test?.cleanupTargetDisplays ?? 0,
                "externalOpenCalls": test?.externalCalls ?? 0, "generatedOnly": true, "ordinaryAdapter": true,
                "physicalPointer": false, "spokenAccessibility": false, "systemTrashCalls": 0, "networkRequests": 0, "keychainCalls": 0]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-selection-group\(phase == "recover" ? "-recover" : "").json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func preparation(_ test: Context) async throws {
        try require(try await history(test).readiness == .absent && !FileManager.default.fileExists(atPath: test.history.path), "passive-history-absent")
        try select(test); try command(test.browser); try await prompt(test, title: "Cancel"); try await settled(test.browser)
        try require(!FileManager.default.fileExists(atPath: test.history.path) && !test.browser.selectionGroupDraft.isPresenting, "cancel-history-does-not-create")
        try select(test); try command(test.browser); try await prompt(test, title: "Enable Preview")
        _ = try await editor(test)
        let prepared = try await history(test)
        try require(prepared.readiness == .available(catalogVersion: 7) && prepared.records.isEmpty, "explicit-real-history-upgrade7")
        let names = try FileManager.default.contentsOfDirectory(atPath: test.root.appendingPathComponent("state").path)
        try require(names.contains { $0.hasPrefix("operation-history-backup-") }, "public-protected-upgrade-backup")
        try require(test.sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "history-upgrade-does-not-group")
        try await escape(test)
        test.checks.append("Actual first-use NSAlert Cancel creates nothing; Prepare History explicitly initializes and upgrades7 with protected backup before naming")
    }
    private static func naming(_ test: Context) async throws {
        let browser = test.browser
        guard let window = test.owner.window else { throw Failure(stage: "group-main-window") }
        let selector = #selector(BrowserViewController.newFolderWithSelection(_:))
        for mode in DirectoryViewMode.allCases {
            browser.setPaneViewMode(mode); try await settled(browser); try select(test)
            let menu = BrowserMenus.fileContextMenu(target: browser)
            guard let item = menu.items.first(where: { $0.action == selector }) else { throw Failure(stage: "group-context-menu-missing") }
            try require(browser.validateMenuItem(item), "group-context-action-enabled")
            if mode == .details && test.mode == "full-dark" {
                window.title = title
                let fieldPresentBeforeAction = isVisible(browser.selectionGroupDraft.field, in: window)
                let report = try await NativeMotionRecorder.record(window: window, root: test.root, label: "selection-group-draft", sampling: .diagnostic(for: window)) {
                    _ = NSApp.sendAction(selector, to: item.target, from: item)
                }
                _ = try await editor(test)
                try recordClip(test, report, label: "selection-group-draft", window: window, field: browser.selectionGroupDraft.field,
                    fieldPresentBeforeAction: fieldPresentBeforeAction)
            } else { try require(NSApp.sendAction(selector, to: item.target, from: item), "group-context-delivered") }
            let native = try await editor(test)
            guard let field = browser.selectionGroupDraft.field else { throw Failure(stage: "actual-proposed-field") }
            try require(browser.orderedSelectedURLs.count == 3 && !browser.displayedEntries.contains { $0.name == "New Folder with Items" }
                && browser.rowsByURL[test.items.appendingPathComponent("New Folder with Items")] == nil, "accessory-is-not-a-file-row")
            let before = native.string; type("Typed proposed name", in: native)
            try require(try await history(test).records.isEmpty && !FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Typed proposed name").path), "typing-zero-mutation")
            try require(!browser.routeBrowserShortcut(try key(window, code: 6, text: "z", flags: [.command])), "text-Undo-not-file-command")
            native.undoManager?.undo()
            try require(native.string == before, "actual-native-text-Undo")
            try await enter(test, "bad/name")
            let invalidHistory = try await history(test)
            try require(browser.selectionGroupDraft.isEditing && invalidHistory.records.isEmpty, "invalid-literal-stays-inline")
            try await enter(test, "Taken")
            try await wait("occupied-name-stays-inline") { browser.selectionGroupDraft.field?.isEditable == true && browser.selectionGroupDraft.isEditing }
            try require(try await history(test).records.isEmpty && FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Taken").path), "occupied-name-no-overwrite")
            try await UIVerification.snapshot(window, to: test.root.appendingPathComponent("evidence/draft-\(mode.rawValue.lowercased()).png"))
            try layout(test, field: field, label: "draft-" + mode.rawValue.lowercased())
            try await escape(test)
        }
        browser.setPaneViewMode(.details); try await settled(browser); try select(test)
        let fileMenu = BrowserMenus.menu(.file, target: browser)
        guard let fileItem = BrowserMenus.commandItem(selector, in: fileMenu) else { throw Failure(stage: "group-File-menu-missing") }
        try require(browser.validateMenuItem(fileItem) && NSApp.sendAction(selector, to: fileItem.target, from: fileItem), "actual-File-menu-group-command")
        _ = try await editor(test); try await escape(test)
        try require(browser.routeBrowserShortcut(try key(window, code: 45, text: "n", flags: [.control, .command])), "default-group-shortcut-routed")
        _ = try await editor(test); try await escape(test)
        browser.setFileSelection([]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        try require(!browser.commandEnabled(selector), "empty-selection-refuses-group")
        try select(test)
        test.checks.append("Actual File and Details/List/Icons context commands and Control-Command-N share the native draft; native text Undo/Escape, unsafe and occupied names preserve files and history")
    }
    private static func revocation(_ test: Context) async throws {
        let browser = test.browser
        for reason in ["navigation", "selection", "view", "tab", "resize", "pane"] {
            try await local(test); try select(test); try command(browser); _ = try await editor(test)
            switch reason {
            case "navigation": browser.navigate(to: .directory(test.items.appendingPathComponent("Away")))
            case "selection": browser.setFileSelection([test.sources[0]]); browser.fileSelectionDidChange()
            case "view": browser.setPaneViewMode(.icons)
            case "tab": browser.newTab(nil)
            case "resize":
                if let window = test.owner.window { var frame = window.frame; frame.size.width -= 4; window.setFrame(frame, display: true) }
            default:
                try require(test.owner.workspace.splitActive(at: .trailing), "actual-pane-split")
                try await wait("new-pane-listing") { !test.browser.isLoading }
            }
            try await wait("draft-revoked-" + reason) { !browser.selectionGroupDraft.isPresenting && browser.operationPreparationTask == nil }
            try require(try await test.engine.inspectExistingHistory().records.isEmpty, "revoked-context-no-job")
            if reason == "pane" {
                try require(test.owner.workspace.closeActivePane(), "close-generated-peer")
                test.owner.workspace.activate(browser)
            }
            if reason == "tab" { browser.closeTab(id: browser.activeID) }
            browser.setPaneViewMode(.details); try await local(test)
        }
        let secondary = BrowserWindowController(settings: browser.settings); test.otherWindows.append(secondary)
        secondary.workspace.sessionReady = true
        secondary.workspace.willStartBrowserForVerification = { [weak test] in test?.configure($0) }
        let other = secondary.workspace.activeBrowser; test.configure(other)
        secondary.window?.makeKeyAndOrderFront(nil); other.navigate(to: .directory(test.items)); try await settled(other)
        other.setFileSelection(Set(test.sources)); other.fileSelectionDidChange(); other.focusBrowserContent()
        try command(other)
        try await wait("secondary-window-draft") { other.selectionGroupDraft.isEditing }
        secondary.suspendBrowsing(); secondary.window?.close()
        try await wait("closed-window-draft-drain") { !other.selectionGroupDraft.isPresenting && other.operationPreparationTask == nil }
        try require(try await history(test).records.isEmpty, "window-close-cannot-commit")
        try await local(test)
        test.checks.append("Navigation, selection, view, tab, resize, pane switch and actual generated window close revoke ordinary drafts; no delayed job appears")
    }
    private static func groupingAndResults(_ test: Context) async throws {
        let parent = try await test.engine.observeDirectory(test.items)
        let earlier = await test.engine.perform(.createFolder(parent: test.items, name: "Earlier Operation"), observing: parent)
        guard earlier.result.disposition == .succeeded && earlier.result.items.count == 1 && earlier.result.items.allSatisfy({ $0.status == .succeeded }), let earlierID = earlier.recordID else { throw Failure(stage: "ordinary-create-on-catalog7") }
        try require(try await history(test).records.contains { $0.id == earlierID && $0.canUndo }, "real-older-Undo-candidate")
        let result = try await group(test, name: "Grouped")
        let records = try await history(test).records
        try require(records.count == 2 && records.first?.id == result.recordID
            && records.filter { $0.kind == .selectionGroup }.count == 1 && test.browser.lastOperationResult == nil, "one-typed-job-and-older-ordinary-history")
        let folder = test.items.appendingPathComponent("Grouped")
        let file = folder.appendingPathComponent("Alpha.txt"), handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("-edited".utf8)); try handle.close()
        try Data("added current child".utf8).write(to: folder.appendingPathComponent("Folder/Added.txt"), options: .withoutOverwriting)
        let controller = try await review(test, result.recordID!)
        guard let window = controller.window else { throw Failure(stage: "real-results-window") }
        window.title = title; window.makeKeyAndOrderFront(nil)
        try require(controller.tableForVerification.numberOfRows == 3 && controller.detailForVerification.string.contains("Original:")
            && controller.presentation?.recordID == result.recordID
            && controller.outcomeForVerification.contains("Selected items were grouped in the new folder."), "typed-results-real-member-evidence")
        if test.mode == "full-dark" {
            controller.tableForVerification.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let otherOriginal = controller.review!.items[2].source.path
            let fieldPresentBeforeAction = isVisible(controller.tableForVerification.enclosingScrollView?.contentView, in: window)
            let report = try await NativeMotionRecorder.record(window: window, root: test.root, label: "selection-group-results", sampling: .diagnostic(for: window)) {
                controller.refreshButtonForVerification.performClick(nil)
                try require(controller.review == nil && !controller.undoButtonForVerification.isEnabled
                    && controller.tableForVerification.numberOfRows == 3 && controller.tableForVerification.selectedRow == 1,
                    "refresh-revokes-authority-with-stable-display")
                controller.tableForVerification.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                try require(controller.detailForVerification.string.contains(otherOriginal), "refresh-selection-shows-matching-cached-detail")
            }
            try await wait("recorded-results-refresh-drained") { controller.inspectionTask == nil && controller.review != nil }
            try require(controller.tableForVerification.selectedRow == 2, "refresh-preserves-selected-member")
            try recordClip(test, report, label: "selection-group-results", window: window, field: controller.tableForVerification.enclosingScrollView?.contentView,
                fieldPresentBeforeAction: fieldPresentBeforeAction)
        }
        try await UIVerification.snapshot(window, to: test.root.appendingPathComponent("evidence/results.png"))
        guard let viewport = controller.tableForVerification.enclosingScrollView?.contentView else { throw Failure(stage: "real-results-viewport") }
        try layout(test, field: viewport, label: "results", window: window)
        test.owner.window?.makeKeyAndOrderFront(nil); test.browser.focusBrowserContent()
        guard let browserWindow = test.owner.window else { throw Failure(stage: "direct-Undo-window") }
        let cancelled = Hold(); test.holds.append(cancelled)
        test.browser.beforeSelectionGroupReviewActionForVerification = { await cancelled.pause() }
        try require(test.browser.routeBrowserShortcut(try key(browserWindow, code: 6, text: "z", flags: [.command])), "ordinary-cancellable-Command-Z-routed")
        try await wait("Command-Z-held-before-mutation") { cancelled.entered && controller.isBusy && test.browser.operationTask != nil }
        let undoOwner = test.browser.operationCoordinator.activeOwner
        try require(undoOwner != nil, "cancelled-Undo-owns-coordinator")
        try stopThroughProgress(test)
        try require(test.browser.operationCoordinator.activeOwner == undoOwner, "cancelled-Undo-retains-owner-before-drain")
        cancelled.release(); try await settled(test.browser); test.browser.beforeSelectionGroupReviewActionForVerification = nil
        try require(!controller.isBusy && controller.refreshButtonForVerification.isEnabled && controller.inspectionTask == nil
            && test.browser.operationCoordinator.activeOwner == nil
            && FileManager.default.fileExists(atPath: file.path), "cancelled-Command-Z-existing-Results-recovers")
        controller.refreshButtonForVerification.performClick(nil)
        try await wait("cancelled-Undo-real-Refresh") { controller.inspectionTask == nil && controller.review?.canUndo == true }
        try observationDisplay(test, controller)
        test.owner.window?.makeKeyAndOrderFront(nil); test.browser.focusBrowserContent()
        try require(test.browser.routeBrowserShortcut(try key(browserWindow, code: 6, text: "z", flags: [.command])), "ordinary-Command-Z-routed")
        try await wait("ordinary-Command-Z-fresh-Undo-drain") {
            test.browser.operationTask == nil && controller.inspectionTask == nil
                && test.browser.operationHistory.selectionGroup?.result?.state == .undone
        }
        guard let inverse = test.browser.operationHistory.selectionGroup?.result else { throw Failure(stage: "direct-Undo-typed-result") }
        try require(inverse.state == .undone && inverse.status == .succeeded
            && FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Earlier Operation").path), "ordinary-typed-Undo-does-not-target-older-job")
        try require(!controller.isBusy && controller.refreshButtonForVerification.isEnabled, "completed-Command-Z-Results-refreshable")
        controller.refreshButtonForVerification.performClick(nil)
        try await wait("completed-Command-Z-real-Refresh") { controller.inspectionTask == nil && controller.review?.state == "undone" }
        try observationDisplay(test, controller)
        try require(try String(contentsOf: test.items.appendingPathComponent("Alpha.txt"), encoding: .utf8) == "generated alpha-edited"
            && FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Folder/Added.txt").path), "Undo-retains-current-object-edits-and-children")
        try require(!controller.undoButtonForVerification.isEnabled && controller.review?.canUndo == false, "terminal-Undo-not-reoffered")
        await closeReview(test)
        let ordinaryInverse = await test.engine.undo(recordID: earlierID)
        try require(ordinaryInverse.result.disposition == .succeeded && ordinaryInverse.result.items.count == 1 && ordinaryInverse.result.items.allSatisfy({ $0.status == .succeeded })
            && !FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Earlier Operation").path), "ordinary-Create-Undo-still-works-on-catalog7")
        let partial = try await group(test, name: "Partial")
        let foreign = test.items.appendingPathComponent("Partial/Foreign.txt")
        try Data("foreign generated child".utf8).write(to: foreign, options: .withoutOverwriting)
        let partialView = try await review(test, partial.recordID!)
        let incomplete = try await undo(test, partialView)
        try require(incomplete.state == .membersRestored && incomplete.status != .succeeded
            && test.sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            && FileManager.default.fileExists(atPath: foreign.path), "honest-members-restored-foreign-child-preserved")
        try require(partialView.outcomeForVerification.contains("Items have returned. The new folder still needs attention.")
            && partialView.review?.state == "membersRestored", "actual-partial-results-wording")
        guard let keep = partialView.buttonForVerification(.keepCurrentLocations), keep.isEnabled else { throw Failure(stage: "explicit-partial-closure-button") }
        keep.performClick(nil)
        try await wait("partial-closure-drain") { test.browser.operationTask == nil && partialView.inspectionTask == nil && partialView.review?.state == "closedRetained" }
        try require(test.browser.operationHistory.selectionGroup?.result?.state == .partial && !partialView.undoButtonForVerification.isEnabled, "successful-partial-closure-not-full-Undo")
        try observationDisplay(test, partialView)
        await closeReview(test)
        test.checks.append("Cancelled actual Command-Z drains and leaves existing Results refreshable; successful fresh Command-Z preserves current edits/children; foreign-child Undo reports membersRestored and explicit partial closure preserves the foreign entry")
    }
    private static func stopThroughProgress(_ test: Context) throws {
        test.browser.showFileOperationDetails(nil)
        guard let stop = descendants(test.browser.operationDetails).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Stop" && $0.isEnabled }) else { throw Failure(stage: "actual-progress-Stop-button") }
        stop.performClick(nil)
        try require(test.browser.operationStopRequested, "actual-progress-Stop-requested")
    }
    private static func stopAndBusy(_ test: Context) async throws {
        try await local(test); try select(test); try command(test.browser); _ = try await editor(test)
        let coordinator = test.browser.operationCoordinator, occupied = UUID()
        try require(coordinator.begin(owner: occupied), "generated-rival-coordinator-owner")
        defer { coordinator.finish(owner: occupied) }
        try await enter(test, "Busy")
        try await wait("busy-name-retry-visible") { test.browser.selectionGroupDraft.isEditing }
        try require(coordinator.activeOwner == occupied && !FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Busy").path), "busy-Enter-does-not-queue")
        coordinator.finish(owner: occupied); try await Task.sleep(for: .milliseconds(80))
        try require(!FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Busy").path), "released-lane-does-not-auto-commit")
        try await escape(test)
        let before = try await history(test).records.count
        let hold = Hold(); test.holds.append(hold)
        test.browser.beforeSelectionGroupPerformForVerification = { await hold.pause() }
        try select(test); try command(test.browser); try await enter(test, "Stopped")
        try await wait("ordinary-perform-held") { hold.entered && test.browser.operationTask != nil }
        let owner = coordinator.activeOwner
        try require(owner != nil && !coordinator.beginPreparation(owner: UUID()), "actual-operation-holds-exclusive-lane")
        try stopThroughProgress(test)
        try require(test.browser.operationStopRequested && coordinator.activeOwner == owner, "Stop-retains-owner-until-drain")
        hold.release(); try await settled(test.browser); test.browser.beforeSelectionGroupPerformForVerification = nil
        let stoppedHistory = try await history(test)
        try require(coordinator.activeOwner == nil
            && stoppedHistory.records.count == before && !FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Stopped").path), "Stop-drains-without-new-job")
        try require(test.browser.operationHistory.selectionGroup?.result?.state == .notStarted
            && test.browser.operationHistory.selectionGroup?.result?.status != .succeeded, "Stop-notStarted-is-typed-and-honest")
        test.checks.append("Busy Enter retains the same draft without queued replay; actual progress Stop keeps coordinator ownership until the held ordinary task and public result drain")
    }
    private static func staleReview(_ test: Context) async throws {
        let result = try await group(test, name: "StaleGroup", urls: [test.items.appendingPathComponent("Stale.txt")])
        let view = try await review(test, result.recordID!)
        let revision = view.review?.revision, generation = view.presentationID
        // Another genuine public review changes only this generated job. The
        // ordinary button still carries its original displayed opaque token.
        let rival = try await test.engine.inspectSelectionGroup(recordID: result.recordID!)
        let closed = await test.engine.confirmSelectionGroup(rival, disposition: .keepCurrentLocations)
        try require(closed.status == .succeeded, "real-rival-review-closure")
        view.undoButtonForVerification.performClick(nil)
        try await wait("stale-UI-token-rechecked") { test.browser.operationTask == nil && view.presentationID != generation }
        try require(view.review?.revision != revision && view.review?.state == "closedRetained" && !view.undoButtonForVerification.isEnabled
            && FileManager.default.fileExists(atPath: test.items.appendingPathComponent("StaleGroup/Stale.txt").path), "stale-token-never-silently-substituted")
        try require(view.noticeForVerification.contains("Review the updated locations"), "stale-review-explicit-reconsent")
        try observationDisplay(test, view)
        await closeReview(test)
        test.checks.append("A real competing public disposition invalidates the displayed opaque review; actual Undo refreshes evidence and requires a new choice without moving data")
    }
    private static func coldRecovery(_ test: Context) async throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: test.root.appendingPathComponent("evidence/group-restart.json"))) as? [String: Any]
        guard let raw = value?["recordID"] as? String, let id = UUID(uuidString: raw), value?["mode"] as? String == test.mode else { throw Failure(stage: "cold-generated-record-ID") }
        let observed = try await history(test)
        try require(observed.readiness == .available(catalogVersion: 7) && observed.records.contains { $0.id == id && $0.kind == .selectionGroup }, "fresh-process-typed-history")
        test.browser.openOperationRecovery(recordID: id)
        await test.browser.recoveryInspectionTask?.value
        await test.browser.retentionInspectionTask?.value
        try await wait("fresh-process-history-selection") { test.browser.recoveryWindow?.selectedRecordID == id && test.browser.operationCoordinator.inspectionCount == 0 }
        guard let historyWindow = test.browser.recoveryWindow, let window = historyWindow.window, let content = window.contentView,
              let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title.contains("Review Grouping") }) else { throw Failure(stage: "actual-history-review-grouping-button") }
        try require(button.isEnabled, "fresh-history-grouping-button-enabled"); button.performClick(nil)
        try await wait("fresh-process-review-loaded") { test.browser.selectionGroupWindow?.review?.recordID == id && test.browser.selectionGroupWindow?.inspectionTask == nil }
        guard let controller = test.browser.selectionGroupWindow else { throw Failure(stage: "cold-typed-controller") }
        try observationDisplay(test, controller)
        let result = try await undo(test, controller)
        try require(result.state == .undone && result.status == .succeeded
            && FileManager.default.fileExists(atPath: test.items.appendingPathComponent("Restart.txt").path), "fresh-process-actual-Undo")
        test.groupIDs.append(id); await closeReview(test)
        test.checks.append("A separately launched App opens the exact persisted History row, its real Review Grouping button and fresh typed Undo; no cached result authorizes inverse work")
    }
    private static func observationDisplay(_ test: Context, _ controller: SelectionGroupResultsWindow) throws {
        guard let review = controller.review, !controller.isBusy else { throw Failure(stage: "actual-observation-review-required") }
        for action in [SelectionGroupDisposition.confirmObservedLocation, .confirmCleanup] {
            let offered = SelectionGroupResultsWindow.canOffer(action, from: review)
            try require(controller.buttonForVerification(action)?.isEnabled == offered, "displayed-confirmation-matches-real-observation")
        }
        if let pending = review.pending {
            // Only actual facade output enters this branch. The ordinary suite
            // does not manufacture a private pending record to exercise it.
            try require(controller.detailForVerification.string.contains("From: " + pending.from.path)
                && controller.detailForVerification.string.contains("To: " + pending.to.path), "pending-edge-direction-displayed")
            if let observed = pending.observedURL {
                try require(controller.dispositionForVerification.contains(observed.path), "recognized-pending-location-displayed")
            } else {
                try require(controller.dispositionForVerification.contains("Current location could not be confirmed."), "unknown-location-never-inferred")
            }
            test.pendingDisplays += 1
        } else {
            try require(!SelectionGroupResultsWindow.canOffer(.confirmObservedLocation, from: review), "settled-review-has-no-pending-confirmation")
        }
        if let target = review.verifiedCleanupTarget {
            try require(controller.dispositionForVerification.contains(target.path)
                && controller.detailForVerification.string.contains("Recovery folder now at: " + target.path), "verified-cleanup-target-displayed")
            test.cleanupTargetDisplays += 1
        } else {
            try require(!SelectionGroupResultsWindow.canOffer(.confirmCleanup, from: review), "unverified-cleanup-target-grants-no-button")
        }
        if review.pending == nil && review.verifiedCleanupTarget == nil {
            try require(controller.dispositionForVerification.isEmpty, "settled-review-displays-no-invented-disposition")
        }
        test.observationGuardChecks += 1
    }
    private static func layout(_ test: Context, field: NSView, label: String, window supplied: NSWindow? = nil) throws {
        guard let window = supplied ?? test.owner.window, let content = window.contentView, field.window === window else { throw Failure(stage: "group-layout-owner") }
        content.layoutSubtreeIfNeeded()
        let rect = field.convert(field.bounds, to: content)
        try require(rect.width > 40 && rect.height > 18 && content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "group-field-or-table-clipped")
        for button in descendants(content).compactMap({ $0 as? NSButton }).filter({ !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled && $0.title.contains("Grouping") }) {
            try require(content.bounds.insetBy(dx: -1, dy: -1).contains(button.convert(button.bounds, to: content)), "group-action-button-clipped")
        }
        if field === test.browser.selectionGroupDraft.field {
            let viewport = test.browser.activeFileScrollView.contentView
            let rowRect = viewport.convert(viewport.bounds, to: content)
            test.layouts.append(["label": label + "-before-overlap-check", "field": NSStringFromRect(rect), "viewport": NSStringFromRect(rowRect),
                "accessory": field.superview.map { NSStringFromRect($0.convert($0.bounds, to: content)) } ?? "missing"])
            try require(!rect.intersects(rowRect), "draft-overlays-real-file-rows")
        }
        test.layouts.append(["label": label, "mode": test.mode, "windowWidth": window.frame.width, "windowHeight": window.frame.height,
            "fieldX": rect.minX, "fieldY": rect.minY, "fieldWidth": rect.width, "fieldHeight": rect.height,
            "interfacePercent": InterfacePresentation.shared.size.percent, "appearance": window.effectiveAppearance.name.rawValue])
    }
    private static func isVisible(_ field: NSView?, in window: NSWindow) -> Bool {
        guard let field else { return false }
        return field.window === window && window.isVisible && !field.isHiddenOrHasHiddenAncestor
    }
    private static func recordClip(_ test: Context, _ report: NativeMotionRecorder.Report, label: String, window: NSWindow, field: NSView?,
        fieldPresentBeforeAction: Bool) throws {
        try JSONEncoder().encode(report).write(to: test.root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
        try require(report.requestedFPS == 120 && report.frames.count >= 3 && report.maximumFrames <= 180 && report.videoBytes > 0 && report.videoBytes <= 4 << 20
            && report.streamStopped && report.writerCompleted && report.failureCode == nil, "group-recorder-actual-drain")
        var clip: [String: Any] = ["label": label, "mode": test.browser.settings.motion.mode.rawValue, "frames": report.frames.count,
            "requestedFPS": report.requestedFPS, "width": report.width, "height": report.height, "captureGeometry": report.captureGeometry,
            "droppedEncoderFrames": report.droppedEncoderFrames, "windowAppearance": window.effectiveAppearance.name.rawValue]
        if let field, field.window === window {
            let rect = field.convert(field.bounds, to: nil), region = NSRect(x: rect.minX, y: CGFloat(report.height)-rect.maxY, width: rect.width, height: rect.height)
            if NSRect(x: 0, y: 0, width: report.width, height: report.height).contains(region) {
                clip["fieldRegion"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
                clip["fieldVisibility"] = label == "selection-group-draft" ? "Actual proposed name field" : "Actual typed member evidence table"
                clip["fieldOwnerVerified"] = true
                clip["fieldPresentBeforeAction"] = fieldPresentBeforeAction
            }
        }
        test.clips.append(clip)
    }
}
#endif
