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
            try await wait("editor-app-observations-drain") { coordinator.inspectionCount == 0 }
            second.window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("editor-app-key-window") { second.window.window?.isKeyWindow == true }
            first.window.saveButton.performClick(nil)
            try need(first.window.window?.isKeyWindow == false && !first.hasPendingSave && !first.hasPendingFileWork,
                "background-editor-button-does-not-dispatch-save")
            let gate = UUID(); try need(coordinator.beginVolumeBarrier(gate), "editor-app-volume-barrier-admission"); barrier = gate
            first.window.window?.makeKeyAndOrderFront(nil); first.window.saveButton.performClick(nil)
            second.window.window?.makeKeyAndOrderFront(nil); second.window.saveButton.performClick(nil)
            try await wait("editor-app-two-queued-captures") { editors.waitingMutationsForVerification == 2 }
            second.window.stopButton.performClick(nil)
            try await wait("editor-app-queued-stop") { editors.waitingMutationsForVerification == 1 && !second.hasPendingSave && !second.hasPendingFileWork }
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
            button("Done", review)!.performClick(nil)
            try await wait("editor-app-versions-closed") { !first.hasPendingFileWork && first.window.window?.attachedSheet == nil }
            checks.append("Actual attached Saved Versions uses real Undo confirmation; retirement visibility follows the explicit Debug/Release feature policy")
            checks.append("Exact View Results reopens the closed originating Explorer with the same history engine")

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
}
#endif
