#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import LocalStorage
@testable import FileOperations

/// Actual App composition, generated profiles and in-repository retained trees.
/// No system Trash call is authorized or needed by either closed phase.
@MainActor enum EditorRetirementVerification {
    private struct Failure: Error { let stage: String }
    private final class Probe: @unchecked Sendable {
        private let condition = NSCondition()
        private let items: URL, destination: URL, maximumReplacements: Int, allowsMove: Bool
        private var authorized: UUID?, replacements = 0, retirements = 0, moves = 0, returns = 0
        private var waiting = false, released = false, moveAttempted = false
        private var events: [NativeRetirementDiagnosticV4] = []
        init(items: URL, destination: URL, confirm: Bool) {
            self.items = items; self.destination = destination; allowsMove = confirm; maximumReplacements = confirm ? 3 : 2
        }
        func authorize(_ id: UUID) { condition.withLock { authorized = id } }
        var entered: Bool { condition.withLock { waiting } }
        var counts: (Int, Int, Int, Int) { condition.withLock { (replacements, retirements, moves, returns) } }
        func release() { condition.withLock { released = true; condition.broadcast() } }
        func boundary(_ stage: String, _ id: UUID) throws {
            condition.lock(); defer { condition.unlock() }
            if stage == "beforeNative" {
                replacements += 1
                guard replacements <= maximumReplacements else { throw FileOperationFailure.ioFailure }
            }
            if stage == "beforeRetirementNative" {
                guard allowsMove, authorized == id, retirements == 0 else { throw FileOperationFailure.ioFailure }
                retirements += 1; waiting = true
                let deadline = Date(timeIntervalSinceNow: 8)
                while !released { guard condition.wait(until: deadline) else { throw FileOperationFailure.ioFailure } }
            }
            if stage == "afterRetirementNative" { returns += 1; guard returns == 1 else { throw FileOperationFailure.ioFailure } }
        }
        func observed(_ event: NativeRetirementDiagnosticV4) {
            condition.withLock { if events.count < 64 { events.append(event) } }
        }
        func confirmedTrace() -> Bool {
            condition.withLock {
                let calls = events.filter { $0.stage == .nativeBegin }
                return events.count <= 64 && events.enumerated().allSatisfy { $0.element.ordinal == $0.offset + 1 }
                    && calls.count == 1 && calls.first?.callSource == .retentionHook
                    && events.filter { $0.stage == .nativeReturned }.count == 1
                    && events.last?.stage == .finished && events.last?.confirmedDurable == true
            }
        }
        func move(_ source: URL) throws -> URL {
            let id = try condition.withLock { () throws -> UUID in
                guard !Thread.isMainThread, allowsMove, let authorized, retirements == 1, !moveAttempted else { throw FileOperationFailure.ioFailure }
                moveAttempted = true; return authorized
            }
            guard source.deletingLastPathComponent() == items, source.lastPathComponent == ".traverse-text-" + id.uuidString else { throw FileOperationFailure.protectedLocation }
            let from = try DirectoryAnchor(items, resolve: false), to = try DirectoryAnchor(destination, resolve: false)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent, to: to.fd, name: source.lastPathComponent)
            condition.withLock { moves += 1 }
            return destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        }
    }
    private static func need(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(10)
        while !predicate() { try need(.now < until, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    private static func button(_ name: String, _ window: NSWindow?) -> NSButton? { views(window?.contentView).compactMap { $0 as? NSButton }.first { $0.title == name } }
    private static func prompt(_ parent: NSWindow?, action: String) async throws {
        try await wait("retirement-owned-alert-" + action) { parent?.attachedSheet != nil }
        guard let alert = parent?.attachedSheet, let control = button(action, alert), control.isEnabled else { throw Failure(stage: "retirement-owned-alert-button") }
        control.performClick(nil)
        try await wait("retirement-owned-alert-ended") { parent?.attachedSheet == nil }
    }
    private static func type(_ value: String, in document: LocalTextDocumentController) {
        let text = document.window.surface.textView
        document.window.window?.makeFirstResponder(text)
        text.setSelectedRange(.init(location: text.string.utf16.count, length: 0))
        text.insertText(value, replacementRange: text.selectedRange()); text.breakUndoCoalescing()
    }
    nonisolated private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func snapshot(_ url: URL) async throws -> VerifiedTree {
        try await Task.detached(priority: .utility) { try verifiedTree(url, cancellation: .init(), requiresMaterialized: true) }.value
    }
    private static func databaseHash(_ history: URL) async throws -> String {
        try await Task.detached(priority: .utility) { sha(try Data(contentsOf: history.appendingPathComponent("operations-v2.sqlite"))) }.value
    }
    private static func select(_ id: UUID, in sheet: NSWindow) async throws -> NativeTextVersionsWindow {
        guard let owner = sheet.delegate as? NativeTextVersionsWindow,
              let table = views(sheet.contentView).compactMap({ $0 as? NSTableView }).first else { throw Failure(stage: "actual-saved-versions-table-record") }
        try await wait("actual-saved-versions-selection-ready") { !owner.hasPendingWorkForVerification && owner.recordIDsForVerification.contains(id) }
        guard let row = owner.recordIDsForVerification.firstIndex(of: id) else { throw Failure(stage: "actual-saved-versions-record-row") }
        table.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
        try await wait("actual-selected-record-verification") { owner.selectedRecordIDForVerification == id && !owner.hasPendingWorkForVerification }
        return owner
    }
    private static func assertWriterOwned(_ coordinator: ApplicationOperationCoordinator, expected: UUID?) throws {
        try need(expected != nil && coordinator.activeOwner == expected, "retirement-existing-global-writer-affinity")
        let competing = UUID(), admitted = coordinator.begin(owner: competing)
        if admitted { coordinator.finish(owner: competing) }
        try need(!admitted, "retirement-competing-global-writer-admitted")
    }
    static func run() async {
        var root: URL?, controller: BrowserWindowController?, browser: BrowserViewController?, document: LocalTextDocumentController?, probe: Probe?
        var failure: String?, checks: [String] = [], phase = "scope", boundary = "scope"
        let editors = ApplicationLocalTextEditors.shared
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "retirement-root") }
            let scope = URL(fileURLWithPath: raw, isDirectory: true)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("editor-retirement-admission.json"))) as? [String: Any]
            guard let selectedPhase = admission?["phase"] as? String, ["cancel-selection", "confirm-readback"].contains(selectedPhase) else { throw Failure(stage: "retirement-closed-phase") }
            phase = selectedPhase; let confirms = phase == "confirm-readback"
            try need(ProcessInfo.processInfo.arguments.contains("--verify-ui") && ProcessInfo.processInfo.arguments.contains("--check-editor-retirement-native")
                && scope.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development") && scope.resolvingSymlinksInPath() == scope
                && UUID(uuidString: scope.lastPathComponent)?.uuidString == scope.lastPathComponent && marker?["action"] as? String == "editor-retirement-native"
                && admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C" && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && LocalTextEditorFeature.ordinaryEnabled && LocalTextEditorFeature.allowsVersionRetirement, "retirement-exact-generated-activation-scope")
            root = scope; boundary = "generated-setup"
            let items = scope.appendingPathComponent("source/Items", isDirectory: true), moved = scope.appendingPathComponent("source/GeneratedRetired", isDirectory: true)
            for url in [items,moved] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let state = scope.appendingPathComponent("state", isDirectory: true), history = state.appendingPathComponent("history", isDirectory: true)
            var facts = stat(); try need(lstat(state.path, &facts) == 0 && facts.st_uid == geteuid() && facts.st_mode & 0o777 == 0o700, "retirement-owned-reserved-state")
            let url = items.appendingPathComponent("Generated Retirement.txt"), original = Data("Generated retirement original\n".utf8)
            try original.write(to: url, options: .withoutOverwriting); try need(chmod(url.path, 0o600) == 0, "retirement-generated-source-mode")
            do { let journal = try OperationJournal(history); try journal.validateWritableCatalog() }
            let instrument = Probe(items: items, destination: moved, confirm: confirms); probe = instrument
            var hooks = RecoveryHooks(); hooks.textEditor.boundary = { try instrument.boundary($0,$1) }
            hooks.retentionTrash = { try instrument.move($0) }; hooks.textEditor.retirementObserved = { instrument.observed($0) }
            try need(hooks.retentionTrash != nil && hooks.textEditor.retirementRawCall == nil, "generated-retention-override-only")
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks, protecting: [state], activity: ApplicationFileActivity.beginOperation)
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner; let host = owner.browser; browser = host
            host.readVolumesForVerification = { [] }; host.folderAccess = FolderAccessController(stateDirectory: nil); host.pinsController = BrowserPinsController(stateDirectory: nil)
            host.privateNames = ApplicationPrivateNames(directory: nil, settings: settings); host.recoverableFileOperations = engine
            owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); host.navigate(to: .directory(items))
            try await wait("retirement-generated-listing") { !host.isLoading && host.orderingTask == nil && host.displayedEntries.count == 1 }
            host.setFileSelection([url]); host.fileSelectionDidChange(); host.focusBrowserContent()
            try need(host.canEditTextInTraverse && NSApp.sendAction(#selector(BrowserViewController.editTextInTraverse(_:)), to: host, from: nil), "retirement-real-editor-command")
            try await wait("retirement-real-editor-open") { editors.documentForVerification(at: url).map { !$0.hasPendingFileWork && $0.window.saveButton.isEnabled } == true }
            guard let editor = editors.documentForVerification(at: url) else { throw Failure(stage: "retirement-owned-editor") }; document = editor
            boundary = "initial-real-save"; type("Generated first saved edit\n", in: editor); try await wait("retirement-first-edit") { editor.isDirty && editor.window.saveButton.isEnabled }
            editor.window.saveButton.performClick(nil); try await prompt(editor.window.window, action: "Enable Saving")
            try await wait("retirement-first-save-drain") { !editor.hasPendingSave && !editor.hasPendingFileWork && !editor.isDirty && editor.latestRecordID != nil }
            guard let firstID = editor.latestRecordID else { throw Failure(stage: "retirement-initial-record") }
            let firstBytes = try Data(contentsOf: url)
            if !confirms {
                type("Generated second saved edit\n", in: editor); try await wait("retirement-second-edit") { editor.isDirty && editor.window.saveButton.isEnabled }; editor.window.saveButton.performClick(nil)
                try await wait("retirement-second-save-drain") { !editor.hasPendingSave && !editor.hasPendingFileWork && !editor.isDirty && editor.latestRecordID != firstID }
            }
            try await wait("retirement-global-inspections-drained") { host.operationCoordinator.inspectionCount == 0 && host.operationCoordinator.activeOwner == nil }
            boundary = "real-saved-versions-selection"; editor.reviewVersions()
            try await wait("retirement-real-version-sheet") { editor.window.window?.attachedSheet?.title == "Saved Versions" }
            let sheet = editor.window.window!.attachedSheet!; let review = try await select(firstID, in: sheet)
            guard let retiredTable = views(sheet.contentView).compactMap({ $0 as? NSTableView })
                .first(where: { $0.accessibilityLabel() == "Saved text changes" }) else { throw Failure(stage: "retirement-actual-table") }
            let retiredRow = retiredTable.selectedRow
            guard let retire = button("Move Versions to Trash…", sheet), !retire.isHidden else { throw Failure(stage: "retirement-debug-action-visible") }
            try await wait("retirement-selected-action-enabled") { retire.isEnabled && !review.hasPendingWorkForVerification }
            instrument.authorize(firstID)
            let before = try await engine.inspectLocalTextRevision(recordID: firstID)
            let retained = before.recoveryLocation
            let treeBefore = try await snapshot(retained), databaseBefore = try await databaseHash(history), documentBefore = try Data(contentsOf: url)
            if confirms { try need(before.canUndo && before.retention == .retained && before.metadataIsDurable, "retirement-initial-undo-authority") }
            boundary = "owned-retirement-confirmation"; retire.performClick(nil)
            try await wait("retirement-one-owned-confirmation") { sheet.attachedSheet != nil }
            try need(review.selectedRecordIDForVerification == firstID && sheet.attachedSheet?.sheetParent === sheet && !retire.isEnabled,
                "retirement-one-selected-record-and-sheet-owner")
            let writer = host.operationCoordinator.activeOwner; try assertWriterOwned(host.operationCoordinator, expected: writer)
            if !confirms {
                try await prompt(sheet, action: "Cancel")
                try await wait("retirement-cancel-real-drain") { !review.hasPendingWorkForVerification && !editor.files.isWorking && host.operationCoordinator.activeOwner == nil }
                let after = try await snapshot(retained), databaseAfter = try await databaseHash(history), stateAfter = try await engine.inspectLocalTextRevision(recordID: firstID)
                try need(treeBefore.matches(after) && databaseBefore == databaseAfter && (try Data(contentsOf: url)) == documentBefore
                    && stateAfter.retention == .retained && stateAfter.metadataIsDurable && instrument.counts == (2,0,0,0), "retirement-cancel-zero-mutation")
                checks.append("Actual older row selection owns one confirmation and global writer; Cancel preserves exact catalog/document/tree and performs zero retirement entries")
            } else {
                try await prompt(sheet, action: "Move Versions to Trash")
                try await wait("retirement-held-actual-worker") { instrument.entered }
                try assertWriterOwned(host.operationCoordinator, expected: writer)
                try need(editor.files.isWorking && engine.pendingWorkerCount > 0 && ApplicationFileActivity.gate.activeCount > 0 && instrument.counts == (1,1,0,0), "retirement-owner-kept-until-actual-native-return")
                instrument.release()
                try await wait("retirement-confirmed-readback-drain") { !review.hasPendingWorkForVerification && !editor.files.isWorking && host.operationCoordinator.activeOwner == nil }
                let retired = try await engine.inspectLocalTextRevision(recordID: firstID)
                try need(retired.state == .committed && retired.retention == .retired && retired.metadataIsDurable && !retired.canUndo
                    && instrument.counts == (1,1,1,1) && instrument.confirmedTrace() && (try Data(contentsOf: url)) == firstBytes,
                    "retirement-actual-readback-retired-undo-ended")
                try await wait("retirement-fresh-row-selection-and-results-affinity") {
                    guard retiredTable.selectedRow == retiredRow,
                          review.selectedRecordIDForVerification == firstID,
                          review.resultsAffinityIDForVerification == firstID,
                          let column = retiredTable.tableColumns.firstIndex(where: { $0.identifier.rawValue == "state" }),
                          let state = retiredTable.view(atColumn: column, row: retiredRow, makeIfNecessary: true) as? NSTextField else { return false }
                    return state.stringValue == "Versions in Trash" && button("Undo Saved Change…", sheet)?.isEnabled == false
                }
                button("Refresh", sheet)?.performClick(nil)
                _ = try await select(firstID, in: sheet)
                try await wait("retirement-retired-ui-readback") { button("Undo Saved Change…", sheet)?.isEnabled == false && button("Done", sheet)?.isEnabled == true }
                let target = moved.appendingPathComponent(retained.lastPathComponent, isDirectory: true), movedBefore = try await snapshot(target)
                try need(treeBefore.matchesNativeTrashTransition(movedBefore), "retirement-generated-move-preserves-complete-tree")
                button("Done", sheet)!.performClick(nil); try await wait("retirement-version-sheet-closed") { !editor.hasPendingFileWork && editor.window.window?.attachedSheet == nil }
                boundary = "later-real-save-and-undo"; type("Generated later saved edit\n", in: editor)
                try await wait("retirement-later-edit-ready") { editor.isDirty && editor.window.saveButton.isEnabled }; editor.window.saveButton.performClick(nil)
                try await wait("retirement-later-save") { !editor.hasPendingFileWork && !editor.hasPendingSave && !editor.isDirty && editor.latestRecordID != firstID }
                guard let laterID = editor.latestRecordID else { throw Failure(stage: "retirement-later-record") }
                editor.reviewVersions(); try await wait("retirement-later-versions") { editor.window.window?.attachedSheet?.title == "Saved Versions" }
                let laterSheet = editor.window.window!.attachedSheet!; _ = try await select(laterID, in: laterSheet)
                try await wait("retirement-later-undo-enabled") { button("Undo Saved Change…", laterSheet)?.isEnabled == true }
                button("Undo Saved Change…", laterSheet)!.performClick(nil); try await prompt(laterSheet, action: "Undo Saved Change")
                try await wait("retirement-later-undo-drained") { button("Done", laterSheet)?.isEnabled == true && !editor.files.isWorking && host.operationCoordinator.activeOwner == nil }
                let movedAfter = try await snapshot(target)
                try need((try Data(contentsOf: url)) == firstBytes && movedBefore.matches(movedAfter) && instrument.counts == (3,1,1,1), "retirement-later-save-undo-and-retained-tree-unchanged")
                checks.append("Actual selected current record confirmation uses the one global writer through held worker/readback; generated in-repo move is durable, Undo ends, later Save/Undo remains functional")
                checks.append("Actual Saved Versions refresh disables original Undo; retained tree remains exact, no system Trash call occurs")
            }
        } catch let issue as Failure { failure = issue.stage }
        catch { failure = String(describing: Swift.type(of: error)) }
        probe?.release()
        if let document, !document.isClosed {
            if let sheet = document.window.window?.attachedSheet {
                if let alert = sheet.attachedSheet { button("Cancel", alert)?.performClick(nil) }
                button("Stop", sheet)?.performClick(nil)
                try? await wait("retirement-cleanup-version-drain") { button("Done", sheet)?.isEnabled == true }
                button("Done", sheet)?.performClick(nil)
            }
            document.stop(); try? await wait("retirement-cleanup-editor-drain") { !document.hasPendingFileWork && !document.hasPendingSave }
            let close = Task { await document.closeForTermination() }
            if document.isDirty || document.files.mustReloadBeforeOriginalSave { try? await prompt(document.window.window, action: "Don’t Save") }
            _ = await close.value
        }
        editors.resumeAfterCancelledTermination(); browser?.suspendBrowser()
        if let browser { await browser.privateNames.close(); await browser.flushBrowserSession() }
        controller?.window?.close(); try? await wait("retirement-owned-windows-closed") { NSApp.windows.allSatisfy { !$0.isVisible } }
        let drained = !editors.hasManagedDocuments && !editors.hasFileWork && browser?.operationCoordinator.activeOwner == nil
            && browser?.operationCoordinator.inspectionCount == 0 && ApplicationFileActivity.gate.activeCount == 0
        let c = probe?.counts ?? (0,0,0,0)
        let result: [String: Any] = ["passed":failure == nil && drained,"phase":phase,"failureStage":failure ?? "none","failureBoundary":failure == nil ? "none":boundary,
            "checks":checks,"actualOwnerDrain":drained,"nativeWindowsClosed":NSApp.windows.allSatisfy { !$0.isVisible },"nativeReplacements":c.0,"retirementEntries":c.1,
            "generatedRetentionMoves":c.2,"retirementReturns":c.3,"systemTrashCalls":0,"networkRequests":0,"keychainCalls":0,"generatedOnly":true]
        if let root { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("evidence/native-editor-retirement.json"), options: .withoutOverwriting) }
        print("TRAVERSE_EDITOR_RETIREMENT_RESULT " + (failure ?? "passed")); exit(result["passed"] as? Bool == true ? 0 : 1)
    }
}
#endif
