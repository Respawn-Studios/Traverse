#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import LocalStorage
import FileMemory
@testable import FileOperations

/// Actual application coordinator/menu/chrome/quit composition. The only
/// writer delay is an owned, deadline-bounded generated filesystem hook.
@MainActor enum LocalTextEditorVerification {
    private struct Failure: Error { let stage: String }
    private final class NativeHold: @unchecked Sendable {
        private let lock = NSCondition()
        private var used = false, released = false, reached = false
        var entered: Bool { lock.withLock { reached } }
        func pauseOnce(_ stage: String) throws {
            guard stage == "beforeNative" else { return }
            lock.lock(); defer { lock.unlock() }
            guard !used else { return }; used = true; reached = true
            let deadline = Date(timeIntervalSinceNow: 8)
            while !released {
                guard lock.wait(until: deadline) else { throw FileOperationFailure.ioFailure }
            }
        }
        func release() { lock.withLock { released = true; lock.broadcast() } }
    }
    @MainActor private final class PendingReviewHold {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private static func need(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() { try need(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func views(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) }
    }
    private static func button(_ name: String, _ window: NSWindow?) -> NSButton? {
        views(window?.contentView).compactMap { $0 as? NSButton }.first { $0.title == name }
    }
    private static func prompt(_ parent: NSWindow?, action: String) async throws {
        try await wait("native-editor-prompt-" + action) { parent?.attachedSheet != nil }
        guard let sheet = parent?.attachedSheet, let control = button(action, sheet) else { throw Failure(stage: "native-editor-prompt-button") }
        control.performClick(nil)
        try await wait("native-editor-prompt-drain") { parent?.attachedSheet == nil }
    }
    private static func type(_ value: String, _ document: LocalTextDocumentController) {
        let text = document.window.surface.textView
        text.setSelectedRange(.init(location: text.string.utf16.count, length: 0))
        text.insertText(value, replacementRange: text.selectedRange()); text.breakUndoCoalescing()
    }
    static func run() async {
        var root: URL?, controller: BrowserWindowController?, browser: BrowserViewController?
        var documents: [LocalTextDocumentController] = [], failure: String?, checks: [String] = []
        var boundary = "scope", errorCode = 0, errorDomain = "none"
        let hold = NativeHold(), editors = ApplicationLocalTextEditors.shared
        let pendingReview = PendingReviewHold()
        var barrier: UUID?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "editor-app-root") }
            let scope = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("editor-app-admission.json"))) as? [String: Any]
            try need(scope.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && scope.resolvingSymlinksInPath() == scope && UUID(uuidString: scope.lastPathComponent)?.uuidString == scope.lastPathComponent
                && marker?["action"] as? String == "editor-native-application"
                && admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development", "editor-app-scope")
            root = scope
            let items = scope.appendingPathComponent("source/Items"), state = scope.appendingPathComponent("state")
            boundary = "generated-directory-setup"
            try FileManager().createDirectory(at: items, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var stateInfo = stat()
            try need(lstat(state.path, &stateInfo) == 0 && stateInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                && stateInfo.st_uid == geteuid() && stateInfo.st_mode & 0o777 == 0o700, "editor-app-owned-reserved-state")
            let one = items.appendingPathComponent("Generated Editor.swift"), two = items.appendingPathComponent("Generated Other.json")
            let originalOne = Data("let generated = 1\n".utf8), originalTwo = Data("{\"generated\": true}\n".utf8)
            try originalOne.write(to: one, options: .withoutOverwriting); try originalTwo.write(to: two, options: .withoutOverwriting)
            for url in [one, two] { try need(chmod(url.path, 0o600) == 0, "editor-app-source-mode") }
            let branchText = "let generated = 0\n"
            let gitWitnesses = [items.appendingPathComponent(".git/HEAD"), items.appendingPathComponent(".git/index")]
            let beforeGit = try await Task.detached {
                try UIVerification.generateGit(in: items, ["init", "--template=", "--initial-branch=main"])
                try Data(branchText.utf8).write(to: one)
                try UIVerification.generateGit(in: items, ["add", "-A"])
                try UIVerification.generateGit(in: items, ["commit", "-m", "Earlier generated draft"])
                try UIVerification.generateGit(in: items, ["branch", "earlier-saved-base"])
                try originalOne.write(to: one)
                try UIVerification.generateGit(in: items, ["commit", "-am", "Current file before Traverse Save"])
                return try gitWitnesses.map { try Data(contentsOf: $0) }
            }.value
            let history = state.appendingPathComponent("history")
            boundary = "generated-history-setup"
            do { let journal = try OperationJournal(history); try journal.validateWritableCatalog() }
            var hooks = RecoveryHooks(); hooks.textEditor.boundary = { stage, _ in try hold.pauseOnce(stage) }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks, protecting: [state], activity: ApplicationFileActivity.beginOperation)
            let settings = BrowserSettings(persist: false)
            boundary = "native-window-setup"
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.navigationStyle = .glass
            settings.glassFileContent = true; settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let host = owner.browser; browser = host
            host.readVolumesForVerification = { [] }
            host.folderAccess = FolderAccessController(stateDirectory: nil)
            host.pinsController = BrowserPinsController(stateDirectory: nil)
            host.privateNames = ApplicationPrivateNames(directory: state.appendingPathComponent("names"), settings: settings)
            host.recoverableFileOperations = engine
            boundary = "generated-remembered-document"
            let remembered = try await host.privateNames.save(AuthoredNames(nickname: "Generated editor continuity"),
                source: one, id: nil, revision: nil, access: nil, allowFollowing: true)
            let rememberedBefore = try await host.privateNames.entry(remembered)
            try need(rememberedBefore.url == one, "remembered-generated-document-before-open")
            guard let delegate = NSApp.delegate as? ApplicationDelegate else { throw Failure(stage: "actual-editor-app-delegate") }
            delegate.attachIncomingForSystemVerification(owner)
            owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            host.navigate(to: .directory(items))
            boundary = "ordinary-editor-opening"
            try await wait("editor-app-listing") { !host.isLoading && host.orderingTask == nil && host.displayedEntries.count == 2 }
            for url in [one, two] {
                owner.window?.makeKeyAndOrderFront(nil)
                host.setFileSelection([url]); host.fileSelectionDidChange(); host.focusBrowserContent()
                try need(host.canEditTextInTraverse && host.commandEnabled(#selector(BrowserViewController.editTextInTraverse(_:)))
                    && NSApp.sendAction(#selector(BrowserViewController.editTextInTraverse(_:)), to: host, from: nil), "ordinary-editor-command-admission")
                try await wait("editor-app-native-open") {
                    guard let document = editors.documentForVerification(at: url) else { return false }
                    return !document.hasPendingFileWork && document.window.saveButton.isEnabled
                }
                guard let document = editors.documentForVerification(at: url) else { throw Failure(stage: "editor-app-owned-document") }
                documents.append(document)
                try need(document.window.window?.contentView?.superview != nil
                    && document.window.window?.contentViewController is ToolWindowChrome,
                    "editor-app-shared-glass-chrome")
            }
            let openedHistory = try await engine.inspectExistingHistory()
            try need(editors.documentCount == 2 && openedHistory.records.isEmpty,
                "passive-editor-open-created-history-records")
            let first = documents[0], second = documents[1], coordinator = host.operationCoordinator
            boundary = "coordinator-save-and-stop"
            type("// Generated queued text\n", first); type("// Generated other edit\n", second)
            try await wait("editor-app-marks-unsaved-insertion") {
                documents.allSatisfy { $0.window.surface.unsavedLineChanges?.kind(at: 1) == .added }
            }
            let markerPreferences = settings.editorPreferences
            var hiddenMarkers = markerPreferences
            hiddenMarkers.showsUnsavedLineChanges = false
            settings.updateEditorPreferences(hiddenMarkers)
            try need(documents.allSatisfy { $0.window.surface.unsavedLineChanges == nil }, "editor-app-marker-preference-clears-gutter")
            settings.updateEditorPreferences(markerPreferences)
            try await wait("editor-app-restores-markers") {
                documents.allSatisfy { $0.window.surface.unsavedLineChanges?.kind(at: 1) == .added }
            }
            try await wait("editor-app-observations-drain") { coordinator.inspectionCount == 0 }
            second.window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("editor-app-key-window") { second.window.window?.isKeyWindow == true }
            if let native = second.window.window {
                let surface = second.window.surface
                guard let added = surface.lineIndex?.start(ofLine: 2),
                      let menu = NSApp.mainMenu, let change = UIVerification.menuItem("Go", "Next Unsaved Change") else {
                    throw Failure(stage: "editor-app-unsaved-change-command-available")
                }
                try need(surface.goToLine(1, generation: surface.generation, remembersLocation: false)
                    && second.window.validateUserInterfaceItem(change), "editor-app-can-jump-to-unsaved-change")
                let f7 = String(UnicodeScalar(NSF7FunctionKey)!)
                try need(menu.performKeyEquivalent(with: UIVerification.key(f7, code: 98, flags: [], window: native))
                    && surface.textView.selectedRange() == NSRange(location: added, length: 0), "editor-app-f7-jumps-to-unsaved-line")
                try await UIVerification.snapshot(native, to: scope.appendingPathComponent("evidence/editor-unsaved-line-marker.png"))
                try await verifyUnsavedChangeReview(second, native: native, settings: settings, fixture: scope)
                checks.append("The native change marker and Option-F7 reach the same edited lines. The preview distinguishes inserted and removed lines and labels missing sides. Escape closes the preview, Return opens the exact change, and a draft edit invalidates a retained button.")
            }
            first.window.saveButton.performClick(nil)
            try need(first.window.window?.isKeyWindow == false && !first.hasPendingSave && !first.hasPendingFileWork,
                "background-editor-button-does-not-dispatch-save")
            let gate = UUID(); try need(coordinator.beginVolumeBarrier(gate), "editor-app-volume-barrier-admission"); barrier = gate
            first.window.window?.makeKeyAndOrderFront(nil); first.window.saveButton.performClick(nil)
            second.window.window?.makeKeyAndOrderFront(nil); second.window.saveButton.performClick(nil)
            try await wait("editor-app-two-queued-captures") { editors.waitingMutationsForVerification == 2 }
            second.window.stopButton.performClick(nil)
            try await wait("editor-app-queued-stop") { editors.waitingMutationsForVerification == 1 && !second.hasPendingSave && !second.hasPendingFileWork }
            try need(second.window.surface.unsavedLineChanges?.kind(at: 1) == .added,
                "editor-app-stopped-save-keeps-markers")
            try need((try Data(contentsOf: one)) == originalOne && (try Data(contentsOf: two)) == originalTwo,
                "editor-app-queued-save-entered-before-barrier")
            second.window.saveButton.performClick(nil)
            try await wait("editor-app-second-requeued") { editors.waitingMutationsForVerification == 2 }
            coordinator.finishVolumeBarrier(gate); barrier = nil
            try await prompt(first.window.window, action: "Enable Saving")
            try await wait("editor-app-actual-first-native-entry") { hold.entered }
            try need(coordinator.activeOwner != nil && editors.waitingMutationsForVerification == 1
                && (try Data(contentsOf: one)) == originalOne && (try Data(contentsOf: two)) == originalTwo,
                "editor-app-released-writer-before-actual-native-return")
            hold.release()
            try await wait("editor-app-both-saves-real-drain") {
                documents.allSatisfy { !$0.hasPendingFileWork && !$0.hasPendingSave && !$0.isDirty }
                    && coordinator.activeOwner == nil && editors.waitingMutationsForVerification == 0
            }
            try need((try Data(contentsOf: one)) == Data(first.window.surface.textView.string.utf8)
                && (try Data(contentsOf: two)) == Data(second.window.surface.textView.string.utf8), "editor-app-save-contents")
            try await wait("editor-app-confirmed-saved-markers-retired") {
                documents.allSatisfy { $0.window.surface.unsavedLineChanges?.marks.isEmpty == true }
            }
            let readiness = try await engine.inspectExistingHistory().readiness
            try need(readiness == .available(catalogVersion: 10), "editor-app-explicit-history-upgrade")
            let rememberedAfterSave = try await host.privateNames.entry(remembered)
            try need(rememberedAfterSave.url == one, "remembered-document-continuity-after-native-save")
            try need(try await host.prepareSelectionGroupHistoryForVerification(engine: engine, host: owner.window!),
                "grouping-retains-known-history10-admission")
            checks.append("Known catalog10 keeps existing grouping admission without another upgrade or file mutation")
            checks.append("Actual File command opens two local editors; passive Open leaves operation records unchanged")
            checks.append("Real coordinator volume barrier, two captured Save intents, queued Stop, automatic signal wakeup and one actual writer through native return")
            checks.append("Real history upgrade consent and two exact captured saves")
            checks.append("Native editor gutters mark inserted lines against the saved buffer, follow the display preference, preserve marks after Stop, and clear them after a confirmed Save")

            owner.window?.makeKeyAndOrderFront(nil); host.focusBrowserContent(); host.inspectOperationRecovery()
            boundary = "file-undo-review-and-host-lifetime"
            try await wait("editor-app-file-undo-history") { host.recoveryRecords.contains { $0.kind == .textRevision && $0.canUndo } }
            editors.afterHistoricalAccessForVerification = { await pendingReview.pause() }
            host.undoFileOperation(nil)
            try await wait("editor-app-pending-historical-access") { pendingReview.entered }
            owner.window?.performClose(nil)
            try await wait("editor-app-pending-host-closed") { host.isBrowserSuspended && owner.window?.isVisible == false }
            pendingReview.release()
            try await wait("editor-app-pending-review-actual-drain") { editors.pendingHistoricalReviewsForVerification == 0 }
            try need(owner.window?.attachedSheet == nil && editors.documentCount == 2,
                "late-historical-access-created-orphaned-sheet")
            editors.afterHistoricalAccessForVerification = nil
            owner.showWindow(nil); owner.resumeBrowsing(); owner.window?.makeKeyAndOrderFront(nil)
            try await wait("editor-app-resumed-history-host") { !host.isLoading && host.orderingTask == nil }
            host.focusBrowserContent()
            host.undoFileOperation(nil)
            try await wait("editor-app-file-undo-review-barrier") { owner.window?.attachedSheet?.title == "Saved Versions" }
            let fileUndoReview = owner.window!.attachedSheet!
            try await wait("editor-app-file-undo-review-inspected") { button("Done", fileUndoReview)?.isEnabled == true }
            try need((try Data(contentsOf: one)) == Data(first.window.surface.textView.string.utf8)
                && (try Data(contentsOf: two)) == Data(second.window.surface.textView.string.utf8),
                "explorer-file-undo-bypassed-text-review")
            button("Done", fileUndoReview)!.performClick(nil)
            try await wait("editor-app-file-undo-review-closed") { owner.window?.attachedSheet == nil }
            checks.append("Explorer File Undo opens an exact text-version review instead of performing an unreviewed inverse or skipping to another operation")
            checks.append("Actual late historical access is cancelled/drained after its host closes; no orphaned sheet or retained pending Quit barrier")

            owner.window?.performClose(nil)
            try await wait("editor-browser-closed") { host.isBrowserSuspended && owner.window?.isVisible == false }
            first.window.window?.makeKeyAndOrderFront(nil); first.reviewVersions()
            boundary = "editor-undo-and-results-host"
            try await wait("editor-app-versions-sheet") { first.window.window?.attachedSheet?.title == "Saved Versions" }
            let review = first.window.window!.attachedSheet!
            try await wait("editor-app-versions-inspected") { button("View Results", review)?.isEnabled == true }
            try need(button("Move Versions to Trash…", review)?.isHidden == !LocalTextEditorFeature.allowsVersionRetirement,
                "retirement-action-does-not-match-qualified-feature-policy")
            guard let versionOwner = review.delegate as? NativeTextVersionsWindow,
                  let versionTable = views(review.contentView).compactMap({ $0 as? NSTableView })
                    .first(where: { $0.accessibilityLabel() == "Saved text changes" }),
                  let undoRecord = first.latestRecordID else { throw Failure(stage: "editor-app-undo-table") }
            let undoRow = versionTable.selectedRow
            try need(undoRow >= 0 && versionOwner.selectedRecordIDForVerification == undoRecord, "editor-app-undo-initial-selection")
            let beforeText = String(decoding: originalOne, as: UTF8.self)
            let savedText = first.window.surface.textView.string
            func compareSavedVersions() async throws -> EditorComparisonWindow {
                review.makeKeyAndOrderFront(nil)
                try await wait("editor-app-saved-comparison-ready") { button("Compare Versions…", review)?.isEnabled == true }
                button("Compare Versions…", review)?.performClick(nil)
                try await wait("editor-app-saved-comparison-rendered") {
                    guard let diff = versionOwner.comparisonForVerification else { return false }
                    return diff.window?.isKeyWindow == true && diff.planForVerification != nil && !diff.hasWorkForVerification
                }
                guard let diff = versionOwner.comparisonForVerification else { throw Failure(stage: "editor-app-saved-comparison-window") }
                try need(!diff.beforeSurface.textView.isEditable && !diff.currentSurface.textView.isEditable,
                         "editor-app-saved-comparison-is-read-only")
                return diff
            }
            let saveDiff = try await compareSavedVersions()
            try need(saveDiff.labels.left == "Before Save" && saveDiff.labels.right == "Submitted Text"
                && saveDiff.beforeSurface.textView.string == beforeText && saveDiff.currentSurface.textView.string == savedText
                && (try Data(contentsOf: one)) == Data(savedText.utf8) && versionTable.selectedRow == undoRow,
                "editor-app-retained-save-before-after-exact")
            if let diffWindow = saveDiff.window {
                try await UIVerification.snapshot(diffWindow, to: scope.appendingPathComponent("evidence/editor-saved-comparison.png"))
            }
            await saveDiff.closeAndDrain()
            @MainActor func gitChoice() async throws -> NSWindow {
                review.makeKeyAndOrderFront(nil)
                try await wait("saved-versions-git-action-ready") {
                    guard let action = button("Compare with Git Revision…", review) else { return false }
                    return review.isKeyWindow && action.isEnabled && !action.isHidden
                }
                button("Compare with Git Revision…", review)?.performClick(nil)
                try await wait("saved-versions-native-git-search") {
                    guard let sheet = review.attachedSheet else { return false }
                    return sheet.title == "Git Revision" && sheet.isKeyWindow && sheet.firstResponder is NSTextView
                }
                guard let sheet = review.attachedSheet else { throw Failure(stage: "saved-git-choice-sheet") }
                return sheet
            }
            let dismissed = try await gitChoice()
            dismissed.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: dismissed))
            try await wait("saved-versions-git-cancel-ends-selection") { review.attachedSheet == nil && !versionOwner.hasPendingWorkForVerification }
            try need(versionOwner.comparisonForVerification == nil && versionTable.selectedRow == undoRow, "saved-versions-git-cancel-keeps-saved-review")
            let picker = try await gitChoice()
            for character in "earlier" { picker.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: picker)) }
            try await wait("saved-versions-git-search-accepts-typing") { (picker.firstResponder as? NSTextView)?.string == "earlier" }
            try await Task.sleep(for: .milliseconds(100))
            picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
            try await wait("saved-versions-git-diff-exact") {
                guard let diff = versionOwner.comparisonForVerification else { return false }
                return diff.window?.isKeyWindow == true && diff.planForVerification != nil && !diff.hasWorkForVerification
            }
            guard let gitDiff = versionOwner.comparisonForVerification else { throw Failure(stage: "saved-versions-git-diff-window") }
            try need(gitDiff.beforeSurface.textView.string == branchText && gitDiff.currentSurface.textView.string == savedText
                && gitDiff.labels.right == "Submitted Text" && versionTable.selectedRow == undoRow
                && (try Data(contentsOf: one)) == Data(savedText.utf8), "saved-versions-git-pinned-branch-and-exact-attempt")
            if let diffWindow = gitDiff.window {
                try await UIVerification.snapshot(diffWindow, to: scope.appendingPathComponent("evidence/editor-saved-git-comparison.png"))
            }
            await gitDiff.closeAndDrain()
            let afterGit = try await Task.detached { try gitWitnesses.map { try Data(contentsOf: $0) } }.value
            try need(beforeGit == afterGit, "saved-versions-git-checkout-or-index-changed")
            review.makeKeyAndOrderFront(nil)
            button("Undo Saved Change…", review)?.performClick(nil)
            try await prompt(review, action: "Undo Saved Change")
            try await wait("editor-app-file-undo-drain") { button("Done", review)?.isEnabled == true && !first.files.isWorking }
            try await wait("editor-app-undo-fresh-row-and-selection") {
                guard versionTable.selectedRow == undoRow,
                      versionOwner.selectedRecordIDForVerification == undoRecord,
                      versionOwner.resultsAffinityIDForVerification == undoRecord,
                      let stateColumn = versionTable.tableColumns.firstIndex(where: { $0.identifier.rawValue == "state" }),
                      let nameColumn = versionTable.tableColumns.firstIndex(where: { $0.identifier.rawValue == "change" }),
                      let state = versionTable.view(atColumn: stateColumn, row: undoRow, makeIfNecessary: true) as? NSTextField,
                      let name = versionTable.view(atColumn: nameColumn, row: undoRow, makeIfNecessary: true) as? NSTextField else { return false }
                return state.stringValue == "Undone" && !name.stringValue.contains(" · Current")
                    && button("Start New Undo Section…", review)?.isEnabled == false
            }
            try need((try Data(contentsOf: one)) == originalOne && first.files.mustReloadBeforeOriginalSave,
                "editor-app-saved-undo-not-bound-to-original")
            let rememberedAfterUndo = try await host.privateNames.entry(remembered)
            try need(rememberedAfterUndo.url == one, "remembered-document-continuity-after-native-undo")
            checks.append("Explicit generated Remember follows the verified tracked document through actual Save and Undo")
            button("View Results", review)!.performClick(nil)
            try await wait("editor-results-reopens-browser-exact-record") {
                !host.isBrowserSuspended && owner.window?.isVisible == true
                    && host.recoveryWindow?.selectedRecordID == first.latestRecordID
            }
            try need(host.recoverableFileOperations === engine, "editor-results-created-different-history")
            host.recoveryWindow?.close()
            let undoDiff = try await compareSavedVersions()
            try need(undoDiff.labels.left == "Before Undo" && undoDiff.labels.right == "Restore Target"
                && undoDiff.beforeSurface.textView.string == savedText && undoDiff.currentSurface.textView.string == beforeText
                && first.window.surface.textView.string == savedText && (try Data(contentsOf: one)) == originalOne,
                "editor-app-retained-undo-before-after-exact")
            review.makeKeyAndOrderFront(nil)
            button("Done", review)!.performClick(nil)
            try await wait("editor-app-versions-closed") { !first.hasPendingFileWork && first.window.window?.attachedSheet == nil }
            try need(undoDiff.closed && !undoDiff.hasWorkForVerification && !first.files.isWorking,
                "editor-app-saved-comparison-drains-with-parent-sheet")
            checks.append("Actual attached Saved Versions uses real Undo confirmation; retirement visibility follows the explicit Debug/Release feature policy")
            checks.append("Compare Versions in Saved Versions uses exact retained Save and Undo pairs, keeps the live document and original selection, and drains the diff when the review closes")
            checks.append("Saved Versions compares an exact retained Save with an earlier Git branch through the native picker while preserving the selected change, on-disk text, Git HEAD and index")
            checks.append("Exact View Results reopens the closed originating Explorer with the same history engine")

            boundary = "editor-compare-with-disk"
            first.window.window?.makeKeyAndOrderFront(nil)
            try await wait("editor-disk-comparison-parent-key") { first.window.window?.isKeyWindow == true }
            type("// Generated draft for disk comparison\n", first)
            let visibleDraft = first.window.surface.textView.string
            let priorBinding = first.files.binding
            let priorHistory = try await engine.inspectExistingHistory().records.map(\.id)
            guard let compareDisk = UIVerification.menuItem("File", "Compare", "Compare with File on Disk…"),
                  let compareDiskAction = compareDisk.action else { throw Failure(stage: "editor-disk-native-menu") }
            try need(compareDisk.target === first.window && first.window.validateUserInterfaceItem(compareDisk)
                && NSApp.sendAction(compareDiskAction, to: first.window, from: compareDisk), "editor-disk-menu-admission")
            try await wait("editor-disk-comparison-presented") {
                guard let diff = first.window.diskComparisonForVerification else { return false }
                return !diff.hasWorkForVerification && diff.window?.isKeyWindow == true && diff.planForVerification != nil
            }
            guard let diskDiff = first.window.diskComparisonForVerification, let diskWindow = diskDiff.window else {
                throw Failure(stage: "editor-disk-comparison-window")
            }
            try need(diskDiff.labels.left == "File on Disk" && diskDiff.labels.right == "Editor Buffer"
                && diskDiff.planForVerification?.before.encoded == originalOne
                && diskDiff.currentSurface.textView.string == visibleDraft,
                "editor-disk-compares-current-on-disk-bytes-with-unsaved-buffer")
            let unchangedSide = diskDiff.beforeSurface.generation
            first.window.window?.makeKeyAndOrderFront(nil)
            type("// Newer editor text\n", first)
            let updatedDraft = first.window.surface.textView.string
            diskWindow.makeKeyAndOrderFront(nil)
            try await wait("editor-disk-refresh-menu") { diskWindow.isKeyWindow && ToolWindowMenuOwnership.owns(diskDiff) }
            guard let refresh = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first(where: { $0.title == "Refresh" }),
                  let refreshAction = refresh.action, NSApp.sendAction(refreshAction, to: diskDiff, from: refresh) else {
                throw Failure(stage: "editor-disk-native-refresh")
            }
            try await wait("editor-disk-updated-draft") {
                !diskDiff.hasWorkForVerification && diskDiff.currentSurface.textView.string == updatedDraft
            }
            let historyAfterComparison = try await engine.inspectExistingHistory().records.map(\.id)
            try need(diskDiff.beforeSurface.generation == unchangedSide && first.files.binding == priorBinding
                && first.files.mustReloadBeforeOriginalSave && first.isDirty
                && (try Data(contentsOf: one)) == originalOne
                && historyAfterComparison == priorHistory,
                "editor-disk-refresh-changed-save-authority-history-or-unchanged-side")
            let earlierSize = settings.interfaceSize
            settings.interfaceSize = .init(150)
            try await UIVerification.snapshot(diskWindow, to: scope.appendingPathComponent("evidence/disk-editor-diff-150.png"))
            settings.interfaceSize = earlierSize
            await diskDiff.closeAndDrain()
            try need(first.window.diskComparisonForVerification == nil && !diskDiff.hasWorkForVerification
                && coordinator.inspectionCount == 0, "editor-disk-comparison-drain")
            checks.append("Compare with File on Disk reads the current local file into the shared diff, including an unsaved editor buffer. Refresh keeps the unchanged pane, and the comparison does not adopt a Save baseline or add history")

            boundary = "new-text-file-command"
            let created = items.appendingPathComponent("New Note.txt")
            host.operationNamePrompt = { _, _ in "New Note.txt" }
            var creationErrors: [String] = []
            host.operationErrorPresenter = { creationErrors.append($0) }
            owner.window?.makeKeyAndOrderFront(nil); host.focusBrowserContent()
            try await wait("new-text-file-command-enabled") { host.canCreateTextFile }
            try need(BrowserMenus.commandItem(#selector(BrowserViewController.createTextFile(_:)),
                in: BrowserMenus.menu(.file, target: host)) != nil && NSApp.sendAction(#selector(BrowserViewController.createTextFile(_:)), to: host, from: nil),
                "new-text-file-native-file-menu")
            try await wait("new-text-file-created-and-opened") {
                guard let document = editors.documentForVerification(at: created) else { return false }
                return document.window.surface.textView.isEditable && !document.hasPendingFileWork
            }
            guard let createdDocument = editors.documentForVerification(at: created) else { throw Failure(stage: "new-text-file-editor") }
            documents.append(createdDocument)
            try need(try Data(contentsOf: created).isEmpty, "new-text-file-has-no-invented-body")
            try need(!createdDocument.isDirty && createdDocument.window.surface.textView.string.isEmpty
                && creationErrors.isEmpty, "new-text-file-ordinary-editor-receipt")
            createdDocument.requestClose()
            try await wait("new-text-file-editor-close") { createdDocument.isClosed }
            owner.window?.makeKeyAndOrderFront(nil); host.focusBrowserContent()
            try await wait("new-text-file-collision-admission") { host.canCreateTextFile }
            host.createTextFile(nil)
            try await wait("new-text-file-collision-drain") { !creationErrors.isEmpty && !editors.hasFileWork }
            try need(try Data(contentsOf: created).isEmpty, "new-text-file-collision-preserves-existing")
            try need(editors.documentCount == 2 && creationErrors.count == 1, "new-text-file-collision-created-editor")
            host.operationNamePrompt = { _, _ in nil }
            host.createTextFile(nil)
            try await wait("new-text-file-cancel-drain") { !editors.hasFileWork }
            host.operationNamePrompt = nil; host.operationErrorPresenter = nil
            host.inspectOperationRecovery()
            try await wait("new-text-file-has-file-undo") {
                host.recoveryRecords.contains { $0.locations.contains(created) && $0.canUndo }
                    && host.canUndoFileOperation
            }
            host.undoFileOperation(nil)
            try await wait("new-text-file-actual-undo") {
                host.operationTask == nil && !FileManager.default.fileExists(atPath: created.path)
            }
            try need(host.lastOperationResult?.disposition == .succeeded
                && (try Data(contentsOf: one)) == originalOne, "new-text-file-undo-touched-earlier-document")
            checks.append("New Text File uses the existing guarded producer and native editor; occupied-name refusal, Cancel and exact file Undo pass")

            first.window.window?.makeKeyAndOrderFront(nil); type("// Generated unsaved Quit text\n", first)
            boundary = "dirty-app-quit"
            let visible = first.window.surface.textView.string
            try need(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "editor-app-quit-not-deferred")
            try await prompt(first.window.window, action: "Cancel")
            try await wait("editor-app-quit-cancel-drain") { !editors.reviewingTerminationForVerification }
            try need(!first.isClosed && first.window.surface.textView.string == visible
                && (try Data(contentsOf: one)) == originalOne, "editor-app-quit-cancel-lost-edits")
            checks.append("Actual AppDelegate Quit is deferred; Cancel preserves native text and recorded file outcome")
        } catch let error as Failure { failure = error.stage }
        catch {
            failure = String(describing: Swift.type(of: error))
            let value = error as NSError; errorCode = value.code
            errorDomain = value.domain == NSCocoaErrorDomain ? "cocoa" : value.domain == NSPOSIXErrorDomain ? "posix" : "other"
        }
        hold.release()
        pendingReview.release(); editors.afterHistoricalAccessForVerification = nil
        if let barrier { browser?.operationCoordinator.finishVolumeBarrier(barrier) }
        for document in documents where !document.isClosed {
            if let sheet = document.window.window?.attachedSheet {
                if sheet.title == "Saved Versions" {
                    if let alert = sheet.attachedSheet { button("Cancel", alert)?.performClick(nil) }
                    button("Stop", sheet)?.performClick(nil)
                    try? await wait("cleanup-editor-version-work") { button("Done", sheet)?.isEnabled == true }
                    button("Done", sheet)?.performClick(nil)
                } else { button("Cancel", sheet)?.performClick(nil) }
            }
            document.stop()
            try? await wait("cleanup-editor-actual-work") { !document.hasPendingFileWork && !document.hasPendingSave }
            let close = Task { await document.closeForTermination() }
            do { if document.isDirty || document.files.mustReloadBeforeOriginalSave { try await prompt(document.window.window, action: "Don’t Save") } }
            catch { if failure == nil { failure = "editor-cleanup-prompt" } }
            _ = await close.value
        }
        ApplicationLocalTextEditors.shared.resumeAfterCancelledTermination()
        browser?.recoveryWindow?.close(); browser?.suspendBrowser()
        if let browser { await browser.privateNames.close(); await browser.flushBrowserSession() }
        controller?.window?.close()
        try? await wait("editor-native-windows-close") { NSApp.windows.allSatisfy { !$0.isVisible } }
        let drained = !editors.hasManagedDocuments && !editors.hasFileWork
            && browser?.operationCoordinator.activeOwner == nil && ApplicationFileActivity.gate.activeCount == 0
        let result: [String: Any] = ["passed": failure == nil && drained,
            "failureStage": failure ?? "none", "checks": checks,
            "failureBoundary": failure == nil ? "none" : boundary, "errorDomainClass": errorDomain, "errorCode": errorCode,
            "actualOwnerDrain": drained, "nativeWindowsClosed": NSApp.windows.allSatisfy { !$0.isVisible },
            "networkRequests": 0, "keychainCalls": 0, "systemTrashCalls": 0,
            "maximumNativeReplacements": 4, "generatedOnly": true]
        if let root { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-editor-app.json"), options: .withoutOverwriting) }
        print("TRAVERSE_EDITOR_APP_RESULT " + (failure ?? "passed"))
        exit(result["passed"] as? Bool == true ? 0 : 1)
    }

    private static func verifyUnsavedChangeReview(_ document: LocalTextDocumentController, native: NSWindow,
                                                  settings: BrowserSettings, fixture: URL) async throws {
        let editor = document.window, surface = editor.surface, text = surface.textView
        let firstDraft = text.string
        text.insertText("// Earlier generated edit\n", replacementRange: .init(location: 0, length: 0))
        text.breakUndoCoalescing()
        try await wait("change-review-two-distinct-marks") { surface.unsavedLineChanges?.marks.count == 2 && surface.canGoToLine }
        try need(surface.goToLine(3, generation: surface.generation, remembersLocation: false), "change-review-visit-second-change")
        let caret = text.selectedRange(), origin = surface.scrollView.contentView.bounds.origin, draft = text.string
        let f7 = String(UnicodeScalar(NSF7FunctionKey)!)
        func chooser(_ phase: String) async throws -> NSWindow {
            native.makeFirstResponder(text)
            try await wait("unsaved-change-chooser-menu-admission-" + phase) {
                guard let item = UIVerification.menuItem("Go", "Go to Unsaved Change…"), item.target === editor else { return false }
                return editor.validateUserInterfaceItem(item)
            }
            guard let item = UIVerification.menuItem("Go", "Go to Unsaved Change…"), item.target === editor,
                  editor.validateUserInterfaceItem(item) else { throw Failure(stage: "unsaved-change-chooser-menu-admission") }
            let key = UIVerification.key(f7, code: 98, flags: [.command, .option], window: native)
            try need(NSApp.mainMenu?.performKeyEquivalent(with: key) == true, "unsaved-change-chooser-native-shortcut")
            do {
                try await wait("unsaved-change-chooser-opens") {
                    native.attachedSheet?.title == "Go to Unsaved Change" && native.attachedSheet?.isKeyWindow == true
                }
            } catch {
                print("UNSAVED_CHOICE phase=\(phase) sheet=\(native.attachedSheet != nil) sheetKey=\(native.attachedSheet?.isKeyWindow == true) parentKey=\(native.isKeyWindow) popover=\(editor.unsavedChangePreviewForVerification != nil) mask=\(item.keyEquivalentModifierMask.rawValue) selectionChanged=\(text.selectedRange() != caret)")
                throw error
            }
            guard let sheet = native.attachedSheet else { throw Failure(stage: "unsaved-change-chooser-sheet") }
            return sheet
        }
        let cancel = try await chooser("cancel")
        cancel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancel))
        try await wait("unsaved-change-chooser-cancel-preserves-position") {
            native.attachedSheet == nil && native.isKeyWindow && text.selectedRange() == caret
        }
        let list = try await chooser("choose")
        guard let table = UIVerification.nativeTables(in: list.contentView).first else { throw Failure(stage: "unsaved-change-chooser-rows") }
        func shows(_ line: String) -> Bool {
            guard let content = list.contentView,
                  let excerpt = views(content).first(where: { $0.identifier?.rawValue == "diff-excerpt-inserted" }) else { return false }
            return views(excerpt).contains { ($0 as? NSTextField)?.stringValue == line }
        }
        try need(table.numberOfRows == 2 && table.selectedRow == 1, "unsaved-change-chooser-preselects-caret-change")
        try await wait("unsaved-change-chooser-previews-exact-edited-line") { shows("// Generated other edit") }
        try await UIVerification.snapshot(list, to: fixture.appendingPathComponent("evidence/editor-unsaved-change-list.png"))
        NSApp.sendEvent(UIVerification.key("\u{f700}", code: 126, flags: [], window: list))
        try await wait("unsaved-change-chooser-moves-and-updates-preview") {
            table.selectedRow == 0 && shows("// Earlier generated edit") && !shows("// Generated other edit")
        }
        try need(text.selectedRange() == caret && surface.scrollView.contentView.bounds.origin == origin,
            "unsaved-change-chooser-preview-keeps-original-caret")
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: list))
        try await wait("unsaved-change-chooser-jumps-to-first-edit") {
            native.attachedSheet == nil && native.isKeyWindow && text.selectedRange().location == 0
        }
        guard let previous = UIVerification.menuItem("Go", "Previous Text Location"), let back = previous.action else {
            throw Failure(stage: "unsaved-change-chooser-return-command")
        }
        try need(editor.validateUserInterfaceItem(previous) && NSApp.sendAction(back, to: editor, from: previous),
            "unsaved-change-chooser-shares-text-location-trail")
        try await wait("unsaved-change-chooser-returns-to-caret") {
            text.selectedRange() == caret && surface.scrollView.contentView.bounds.origin == origin
        }
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(f7, code: 98, flags: .option, window: native)) == true,
            "change-review-native-key-equivalent")
        try await wait("change-review-first-native-popover") { editor.unsavedChangePreviewForVerification?.view.window != nil }
        guard let preview = editor.unsavedChangePreviewForVerification, let popover = preview.view.window else { throw Failure(stage: "change-review-popover-window") }
        let labels = views(preview.view).compactMap { ($0 as? NSTextField)?.stringValue }
        try need(labels.contains("No lines") && labels.contains("// Generated other edit")
            && labels.contains { $0.hasPrefix("+  Edited") } && !labels.contains("// Earlier generated edit"),
            "change-review-exact-short-excerpt-and-inserted-sign")
        try await UIVerification.snapshot(popover, to: fixture.appendingPathComponent("evidence/editor-unsaved-change-preview.png"))
        popover.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: popover))
        try await wait("change-review-Escape-dismisses") { editor.unsavedChangePreviewForVerification == nil }
        native.makeKeyAndOrderFront(nil)
        try await wait("change-review-source-visible") { native.isKeyWindow }
        let (gutter, hit) = surface.unsavedLineAnchor(3)
        try need(gutter is NSRulerView && !hit.isEmpty, "change-review-pointer-gutter-target")
        let point = gutter.convert(.init(x: hit.midX, y: hit.midY), to: nil)
        guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(stage: "change-review-pointer-event") }
        native.sendEvent(click)
        try await wait("change-review-pointer-opens-marked-line") { editor.unsavedChangePreviewForVerification?.view.window != nil }
        guard let pointerPreview = editor.unsavedChangePreviewForVerification, let popup = pointerPreview.view.window else {
            throw Failure(stage: "change-review-pointer-popover")
        }
        do {
            try await wait("change-review-popover-default-key-focus") { popup.defaultButtonCell === pointerPreview.diff.cell }
            popup.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: popup))
            try await wait("change-review-full-diff") {
                editor.comparisonForVerification?.position?.index == 1 && editor.comparisonForVerification?.window?.isKeyWindow == true
            }
        } catch {
            print("CHANGE_REVIEW default=\(popup.defaultButtonCell === pointerPreview.diff.cell) popupKey=\(popup.isKeyWindow) parentKey=\(native.isKeyWindow) shown=\(editor.unsavedChangePreviewForVerification != nil) comparison=\(editor.comparisonForVerification != nil) exactIndex=\(editor.comparisonForVerification?.position?.index ?? -1)")
            throw error
        }
        guard let comparison = editor.comparisonForVerification else { throw Failure(stage: "change-review-full-diff-owner") }
        try need(comparison.planForVerification?.current.text == draft && document.isDirty && text.selectedRange() == caret
            && surface.scrollView.contentView.bounds.origin == origin, "change-review-preserves-exact-draft-and-viewport")
        await comparison.closeAndDrain()
        native.makeKeyAndOrderFront(nil)
        try await wait("change-review-source-returns") { native.isKeyWindow }
        native.makeFirstResponder(text)
        let initialSize = settings.interfaceSize, initialAppearance = settings.appearance
        settings.interfaceSize = .init(150); settings.appearance = .light
        defer { settings.interfaceSize = initialSize; settings.appearance = initialAppearance }
        try await wait("change-review-larger-interface-committed") { InterfaceMetrics.scale == 1.5 }
        let enlarged = try await chooser("stale")
        try await UIVerification.snapshot(enlarged, to: fixture.appendingPathComponent("evidence/editor-unsaved-change-list-150.png"))
        text.insertText("// New edit while choice is open\n", replacementRange: .init(location: 0, length: 0))
        text.breakUndoCoalescing()
        let editedCaret = text.selectedRange()
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: enlarged))
        try await wait("unsaved-change-chooser-refuses-outdated-choice") {
            native.attachedSheet == nil && native.isKeyWindow && text.selectedRange() == editedCaret
                && editor.navigationStatus == "The text or selection changed. Try again."
        }
        text.undoManager?.undo()
        try await wait("unsaved-change-chooser-edit-Undo-and-preparation") {
            text.string == draft && surface.unsavedLineChanges?.marks.count == 2
        }
        try need(surface.goToLine(3, generation: surface.generation, remembersLocation: false), "change-review-restores-second-change")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(f7, code: 98, flags: .option, window: native)) == true,
            "change-review-large-key-equivalent")
        try await wait("change-review-large-popover-visible") { editor.unsavedChangePreviewForVerification?.view.window != nil }
        guard let stale = editor.unsavedChangePreviewForVerification, let large = stale.view.window else {
            throw Failure(stage: "change-review-large-native-popover")
        }
        try await UIVerification.snapshot(large, to: fixture.appendingPathComponent("evidence/editor-unsaved-change-preview-150.png"))
        let button = stale.diff.convert(stale.diff.bounds, to: stale.view)
        try need(stale.view.bounds.width > 480 && stale.view.bounds.insetBy(dx: 1, dy: 1).contains(button)
            && button.width >= 90, "change-review-large-native-button-fits")
        text.insertText("// New edit invalidates the review\n", replacementRange: .init(location: 0, length: 0))
        text.breakUndoCoalescing()
        try await wait("change-review-new-edit-closes-stale-preview") { editor.unsavedChangePreviewForVerification == nil }
        stale.diff.performClick(nil)
        try need(editor.comparisonForVerification == nil && text.string.hasPrefix("// New edit invalidates the review"),
            "change-review-retained-native-action-refuses-new-buffer")
        text.undoManager?.undo()
        try await wait("change-review-first-Undo-preserves-earlier-draft") { text.string == draft }
        text.undoManager?.undo()
        try await wait("change-review-Undo-restores-original-fixture-state") {
            text.string == firstDraft && surface.unsavedLineChanges?.kind(at: 1) == .added
        }
        let original = (text.string as NSString).range(of: "true")
        try need(original.location != NSNotFound, "change-review-replacement-baseline")
        text.breakUndoCoalescing()
        text.insertText("false", replacementRange: original)
        text.breakUndoCoalescing()
        try await wait("change-review-replacement-prepared") { surface.canGoToLine && text.string.contains("false") }
        try need(surface.goToLine(2, generation: surface.generation, remembersLocation: false), "change-review-replacement-position")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(f7, code: 98, flags: .option, window: native)) == true,
            "change-review-replacement-native-key-equivalent")
        try await wait("change-review-replacement-visible") { editor.unsavedChangePreviewForVerification?.view.window != nil }
        guard let changed = editor.unsavedChangePreviewForVerification, let changedWindow = changed.view.window else {
            throw Failure(stage: "change-review-replacement-popover")
        }
        let content = views(changed.view)
        let headings = content.compactMap { ($0 as? NSTextField)?.stringValue }
        try need(headings.contains { $0.hasPrefix("−  Saved") } && headings.contains { $0.hasPrefix("+  Edited") }
            && content.contains { $0.identifier?.rawValue == "diff-excerpt-removed" }
            && content.contains { $0.identifier?.rawValue == "diff-excerpt-inserted" }, "change-review-both-signed-excerpts")
        try await UIVerification.snapshot(changedWindow, to: fixture.appendingPathComponent("evidence/editor-change-replacement-150.png"))
        changedWindow.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: changedWindow))
        try await wait("change-review-replacement-closed") { editor.unsavedChangePreviewForVerification == nil }
        text.undoManager?.undo()
        try await wait("change-review-replacement-Undo-keeps-prior-draft") {
            text.string == firstDraft && document.isDirty && surface.unsavedLineChanges?.kind(at: 1) == .added
        }
    }
}
#endif
