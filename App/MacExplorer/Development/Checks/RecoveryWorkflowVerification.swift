#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import FileOperations

@MainActor
extension UIVerification {
    static func verifyRecoveryWorkflows(_ browser: BrowserViewController, in testRoot: URL, output: URL,
                                       interactive: Bool) async throws -> [String] {
        let owned = testRoot.appendingPathComponent("recovery-ui-\(UUID().uuidString)", isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        let originalService = browser.recoverableFileOperations
        let originalNamePrompt = browser.operationNamePrompt
        let originalConflictPrompt = browser.transferConflictPrompt
        let originalResult = browser.operationResultPresenter
        let originalError = browser.operationErrorPresenter
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("MacExplorer owned recovery UI fixture v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            for (name, body) in [("Copy.txt", "generated copy"), ("Move.txt", "generated move"), ("Conflict.txt", "new generated body"),
                                 ("PartialConflict.txt", "generated partial conflict"), ("PartialFresh.txt", "generated partial fresh"),
                                 ("Move Clipboard.txt", "new generated clipboard body"), ("Alias Cut.txt", "generated alias cut"),
                                 ("Alias Copied Move.txt", "generated alias copied move")] {
                try Data(body.utf8).write(to: source.appendingPathComponent(name), options: .withoutOverwriting)
            }
            // Exercise the native app's security propagation with an explicitly
            // generated quarantined file as well as the package worker's fixtures.
            let fd = open(source.appendingPathComponent("Copy.txt").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure(message: "Unable to open generated quarantine fixture") }
            defer { close(fd) }
            let quarantine = Data("0083;67000000;MacExplorerGeneratedFixture;00000000-0000-0000-0000-000000000001".utf8)
            guard quarantine.withUnsafeBytes({ fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }) == 0 else {
                throw Failure(message: "Unable to set generated quarantine metadata")
            }
            try Data("old generated body".utf8).write(to: destination.appendingPathComponent("Conflict.txt"), options: .withoutOverwriting)
            try Data("keep generated partial destination".utf8).write(to: destination.appendingPathComponent("PartialConflict.txt"), options: .withoutOverwriting)
            try Data("old generated clipboard body".utf8).write(to: destination.appendingPathComponent("Move Clipboard.txt"), options: .withoutOverwriting)
            for parent in [source, destination] {
                let merge = parent.appendingPathComponent("Merge Folder", isDirectory: true)
                try fm.createDirectory(at: merge, withIntermediateDirectories: false)
                try Data((parent == source ? "new generated shared" : "old generated shared").utf8)
                    .write(to: merge.appendingPathComponent("Shared.txt"), options: .withoutOverwriting)
                try Data("generated unique child".utf8)
                    .write(to: merge.appendingPathComponent(parent == source ? "Incoming.txt" : "Unrelated.txt"), options: .withoutOverwriting)
            }
        }.value
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        browser.recoverableFileOperations = engine
        browser.operationNamePrompt = { _, _ in "Undo Folder" }
        browser.operationResultPresenter = { _ in }
        var errors: [String] = []
        browser.operationErrorPresenter = { errors.append($0) }
        defer {
            browser.recoveryInspectionTask?.cancel()
            browser.recoverableFileOperations = originalService
            browser.operationNamePrompt = originalNamePrompt
            browser.transferConflictPrompt = originalConflictPrompt
            browser.operationResultPresenter = originalResult
            browser.operationErrorPresenter = originalError
            browser.recoveryRecords = []
            browser.refusedRecoveryEntries = []
            browser.clearCutSelection()
        }
        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try await verifyTransferOptions(browser, source: source, destination: destination, output: output, interactive: interactive)
        browser.createFolder(BrowserMenus.newFolderItem(target: browser, named: true)); try await waitRecoveryOperation(browser)
        let created = source.appendingPathComponent("Undo Folder", isDirectory: true)
        try require(FileManager().fileExists(atPath: created.path), "Recoverable native New Folder did not create its fixture")
        try await waitUntil("Created-folder Undo capability") { browser.canUndoFileOperation }
        if interactive {
            let undo = key("z", code: 6, flags: .command, window: browser.view.window!)
            try require(NSApplication.shared.mainMenu?.performKeyEquivalent(with: undo) == true,
                        "Native Command-Z did not route through the file-list responder")
        } else { browser.table.undo(nil) }
        try await waitRecoveryOperation(browser)
        try require(!FileManager().fileExists(atPath: created.path), "Native file-list Undo did not reverse New Folder")

        func choose(_ name: String) throws {
            guard let row = browser.displayedEntries.firstIndex(where: { $0.name == name }) else {
                throw Failure(message: "Recovery fixture row is missing")
            }
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try choose("Copy.txt"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.table.paste(nil); try await waitRecoveryOperation(browser)
        let copied = destination.appendingPathComponent("Copy.txt")
        try require(FileManager().fileExists(atPath: copied.path) && FileManager().fileExists(atPath: source.appendingPathComponent("Copy.txt").path),
                    "Recoverable native Copy/Paste lost a fixture occupant")
        try await waitUntil("Copy Undo capability") { browser.canUndoFileOperation }
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(!FileManager().fileExists(atPath: copied.path) && FileManager().fileExists(atPath: source.appendingPathComponent("Copy.txt").path),
                    "Native Copy Undo removed the source or left the published copy")

        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try choose("Move.txt"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.moveCopiedFiles(nil); try await waitRecoveryOperation(browser)
        try require(!FileManager().fileExists(atPath: source.appendingPathComponent("Move.txt").path)
            && FileManager().fileExists(atPath: destination.appendingPathComponent("Move.txt").path),
                    "Finder Move Copied Items did not move the observed fixture")
        try require(browser.transferPasteboard.types?.isEmpty != false && browser.pendingCut == nil,
                    "Fully consumed Move clipboard retained stale source references")
        try await waitUntil("Move Undo capability") { browser.canUndoFileOperation }
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(FileManager().fileExists(atPath: source.appendingPathComponent("Move.txt").path)
            && !FileManager().fileExists(atPath: destination.appendingPathComponent("Move.txt").path),
                    "Native Move Undo did not restore the fixture")

        // Local listings preserve an explicitly browsed alias. Move observations
        // use physical paths; those roles must not turn Cut into Copy.
        let alias = owned.appendingPathComponent("Source Alias", isDirectory: true)
        try await Task.detached { try FileManager().createSymbolicLink(at: alias, withDestinationURL: source) }.value
        for (name, cut) in [("Alias Cut.txt", true), ("Alias Copied Move.txt", false)] {
            browser.navigate(to: .directory(alias)); try await settled(browser); browser.focusBrowserContent()
            try choose(name)
            if cut {
                browser.table.cut(nil); await browser.cutPreparationTask?.value
                try require(browser.pendingCut?.urls == [source.appendingPathComponent(name)],
                            "Alias-root Cut did not retain physical object observations")
            } else { browser.table.copy(nil) }
            browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
            if cut { browser.table.paste(nil) } else { browser.moveCopiedFiles(nil) }
            try await waitRecoveryOperation(browser)
            try require(browser.lastOperationResult?.disposition == .succeeded
                && !FileManager().fileExists(atPath: source.appendingPathComponent(name).path)
                && FileManager().fileExists(atPath: destination.appendingPathComponent(name).path)
                && browser.transferPasteboard.types?.isEmpty != false,
                        "Alias-root Move copied instead, or retained stale clipboard references")
            browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
            try require(FileManager().fileExists(atPath: source.appendingPathComponent(name).path),
                        "Alias-root Move Undo did not restore its observed original")
        }

        // A skipped input must not silently convert a partially consumed Cut
        // into ordinary Copy on the next Paste.
        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        let partialURLs = ["PartialConflict.txt", "PartialFresh.txt"].map { source.appendingPathComponent($0) }
        browser.table.selectRowIndexes(IndexSet(partialURLs.compactMap { browser.rowsByURL[$0] }), byExtendingSelection: false)
        browser.table.cut(nil)
        let preparation = browser.cutPreparationTask
        await preparation?.value
        let partialClipboardCount = browser.transferPasteboard.changeCount
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.transferConflictPrompt = { conflicts in Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }) }
        browser.table.paste(nil); try await waitRecoveryOperation(browser)
        try require(browser.pendingCut?.urls == partialURLs && browser.transferPasteboard.changeCount == partialClipboardCount,
                    "Partial Cut was cleared or converted to Copy after skipping a conflict")
        try require(browser.clipboardStatus.stringValue.contains("Move unfinished"),
                    "Partial Move incorrectly presented every clipboard item as ready to move")
        try require(FileManager().fileExists(atPath: partialURLs[0].path) && !FileManager().fileExists(atPath: partialURLs[1].path)
            && (try String(contentsOf: destination.appendingPathComponent("PartialConflict.txt"), encoding: .utf8)) == "keep generated partial destination",
                    "Partial Move failed to preserve the skipped original/destination")
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(FileManager().fileExists(atPath: partialURLs[1].path), "Partial Move Undo did not restore its moved input")
        browser.clearCutSelection()
        try require(!browser.operationCoordinator.transfers.state.isPaused,
                    "Explicit Skip choices were incorrectly classified as unresolved transfer failures")

        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try choose("Move Clipboard.txt"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.transferConflictPrompt = { conflicts in
            BrowserClipboard.write("Newer generated move clipboard", urls: [], to: browser.transferPasteboard)
            return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .replace) })
        }
        browser.moveCopiedFiles(nil)
        try await waitRecoveryOperation(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
            && !FileManager().fileExists(atPath: source.appendingPathComponent("Move Clipboard.txt").path)
            && browser.transferPasteboard.string(forType: .string) == "Newer generated move clipboard",
                    "Move completion replaced a newer clipboard")
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)

        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try choose("Merge Folder"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.transferConflictPrompt = { conflicts in
            Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, $0.canMerge ? .merge : .replace) })
        }
        browser.table.paste(nil); try await waitRecoveryOperation(browser)
        let merged = destination.appendingPathComponent("Merge Folder", isDirectory: true)
        try require(browser.lastOperationResult?.disposition == .succeeded
            && (try String(contentsOf: merged.appendingPathComponent("Shared.txt"), encoding: .utf8)) == "new generated shared"
            && FileManager().fileExists(atPath: merged.appendingPathComponent("Incoming.txt").path)
            && FileManager().fileExists(atPath: merged.appendingPathComponent("Unrelated.txt").path),
                    "Native folder Merge/nested Replace lost unrelated destination contents")
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
            && (try String(contentsOf: merged.appendingPathComponent("Shared.txt"), encoding: .utf8)) == "old generated shared"
            && !FileManager().fileExists(atPath: merged.appendingPathComponent("Incoming.txt").path)
            && FileManager().fileExists(atPath: merged.appendingPathComponent("Unrelated.txt").path),
                    "Native Merge Undo failed to restore its destination while preserving unrelated contents")

        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try choose("Conflict.txt"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        var seenConflicts: [TransferConflict] = []
        browser.transferConflictPrompt = { conflicts in
            seenConflicts = conflicts
            return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .replace) })
        }
        browser.table.paste(nil); try await waitRecoveryOperation(browser)
        try require(seenConflicts.count == 1 && seenConflicts[0].destination == destination.appendingPathComponent("Conflict.txt"),
                    "Native replacement choices were not tied to the observed target")
        let conflict = destination.appendingPathComponent("Conflict.txt")
        try require(try String(contentsOf: conflict, encoding: .utf8) == "new generated body", "Explicit Replace failed")
        try await waitUntil("Replace Undo capability") { browser.canUndoFileOperation }
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(try String(contentsOf: conflict, encoding: .utf8) == "old generated body", "Replace Undo failed to restore displaced destination")

        // A changed destination is a real failed inverse, not a simulated crash.
        // Fresh-process crash evidence is supplied by the dedicated package worker.
        browser.transferConflictPrompt = nil
        browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
        try choose("Copy.txt"); browser.table.copy(nil)
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        browser.table.paste(nil); try await waitRecoveryOperation(browser)
        let id = try requireRecoveryID(browser)
        try await Task.detached { try Data("edited generated destination".utf8).write(to: copied) }.value
        browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
        try require(try String(contentsOf: copied, encoding: .utf8) == "edited generated destination", "Undo changed an edited destination")
        let fresh = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        let inspection = try await fresh.recoveryRecords()
        try require(inspection.refusedEntries.isEmpty && inspection.records.contains(where: { $0.id == id && $0.state == "needsReview" }),
                    "Failed inverse did not survive fresh engine inspection as review-required")
        let inspector = OperationRecoveryWindowController(onUndo: { _ in }, onRecover: { _ in }, onRefresh: {})
        inspector.update(records: inspection.records, refusedEntries: inspection.refusedEntries)
        if let window = inspector.window { try await snapshot(window, to: output.appendingPathComponent("operation-recovery.png")) }
        let refused = owned.appendingPathComponent("journal/unrecognized.json")
        try await Task.detached { try Data("generated unrecognized record".utf8).write(to: refused, options: .withoutOverwriting) }.value
        let refusedInspection = try await fresh.recoveryRecords()
        try require(refusedInspection.refusedEntries.contains(refused), "Generated unrecognized record was not preserved for inspection")
        inspector.update(records: [], refusedEntries: refusedInspection.refusedEntries)
        try require(recoveryText(in: inspector.window?.contentView).contains(refused.path),
                    "Refused-only recovery inspection did not expose its preserved path")
        if let window = inspector.window { try await snapshot(window, to: output.appendingPathComponent("operation-recovery-refused.png")) }
        try require(errors.isEmpty, "Native recovery workflow unexpectedly failed preflight")
        if interactive {
            browser.focusLocation(nil)
            try require(!browser.canUndoFileOperation && !browser.commandEnabled(#selector(BrowserViewController.moveCopiedFiles(_:))),
                        "File Undo or Move Copied Items intercepted native text editing")
            guard let window = browser.view.window, let editor = window.firstResponder as? NSTextView else {
                throw Failure(message: "Address field editor is missing")
            }
            let priorText = editor.string
            editor.breakUndoCoalescing()
            editor.selectAll(nil)
            editor.insertText("Generated address edit for native text Undo", replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
            try require(editor.string != priorText && editor.undoManager?.canUndo == true && window.isKeyWindow,
                        "Native editor did not accept an undoable generated edit in its key window")
            BrowserShortcutMenus.refresh(NSApplication.shared.mainMenu, browser: browser)
            func menuItems(in menu: NSMenu?) -> [NSMenuItem] {
                menu?.items.flatMap { [$0] + menuItems(in: $0.submenu) } ?? []
            }
            let undoItems = menuItems(in: NSApplication.shared.mainMenu).filter {
                $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == .command
            }
            try require(undoItems.count == 1 && undoItems[0].action == #selector(FileTableView.undo(_:)),
                        "Native Edit Undo must be the sole Command-Z menu route while editing")
            try require(NSApplication.shared.mainMenu?.performKeyEquivalent(with:
                key("z", code: 6, flags: .command, window: window)) == true,
                        "Command-Z was not delivered through the native Edit menu")
            try require(editor.string == priorText && browser.lastRecoveryRecordID == id,
                        "Native text Undo failed to restore typing or changed file-operation history")
            try JSONSerialization.data(withJSONObject: ["passed": true, "singleNativeShortcutOwner": true,
                "textRestored": true, "fileHistoryUnchanged": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-text-undo.json"), options: .withoutOverwriting)
        }
        browser.focusBrowserContent()
        var checks = ["Native recoverable New Folder/Copy and file-list Undo route through journaled operation engine",
                      "Metadata options preserve defaults, explicit cancellation pause and captured queued sources across newer clipboard data; generated quarantined copy supports Undo",
                "Finder Move Copied Items and guarded Undo; consumed clipboard clears, skipped Cut and newer clipboard are preserved",
                "Cut/Paste and Finder Move from an explicitly browsed symlink-root alias retain physical move semantics and consume only their owned clipboard",
                "Identity-bound native Replace consent retains displaced fixture; Undo restores it",
                "Native folder Merge and nested Replace preserve unrelated contents; Undo restores the original destination",
                "Edited destination refuses Undo, survives fresh journal inspection and exposes recovery/refused paths"]
        try await verifyRecoveryInspectionContext(fresh, alternate: engine)
        checks.append("Recovery inspection rejects an obsolete engine and detached window before publishing captured history")
        if interactive {
            browser.transferConflictPrompt = nil
            // Exercise the real operation sheet and the window delegate's close
            // guard while that actual operation is awaiting a decision.
            browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
            try choose("Conflict.txt"); browser.table.copy(nil)
            browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
            browser.table.paste(nil)
            try await waitUntil("Native observed-conflict sheet") { browser.view.window?.attachedSheet != nil }
            let sheet = browser.view.window!.attachedSheet!
            try await snapshot(sheet, to: output.appendingPathComponent("transfer-conflicts.png"))
            browser.view.window?.performClose(nil)
            try require(browser.view.window?.isVisible == true && !browser.isBrowserSuspended && browser.hasPendingFileOperation,
                        "Browser closed while an actual conflict operation was pending")
            guard let cancel = recoveryButton("Cancel", in: sheet.contentView) else { throw Failure(message: "Conflict Cancel is unavailable") }
            cancel.performClick(nil)
            try await waitRecoveryOperation(browser)
            try require(try String(contentsOf: conflict, encoding: .utf8) == "old generated body", "Native conflict cancellation changed its target")
            try resumeReviewedTransferQueue(browser, after: "native conflict Cancel")

            let defaultsSource = owned.appendingPathComponent("Defaults Source", isDirectory: true)
            let defaultsDestination = owned.appendingPathComponent("Defaults Destination", isDirectory: true)
            let defaultURLs = try await Task.detached {
                try FileManager().createDirectory(at: defaultsSource, withIntermediateDirectories: false)
                try FileManager().createDirectory(at: defaultsDestination, withIntermediateDirectories: false)
                return try (0..<40).map { index -> URL in
                    let url = defaultsSource.appendingPathComponent("Default \(index).txt")
                    try Data("new generated default".utf8).write(to: url, options: .withoutOverwriting)
                    try Data("keep generated default".utf8).write(to: defaultsDestination.appendingPathComponent(url.lastPathComponent), options: .withoutOverwriting)
                    return url
                }
            }.value
            let defaultPlan = try await engine.prepareTransfer(sources: defaultURLs, destinationDirectory: defaultsDestination, move: false)
            let choices = Task { await browser.chooseTransferConflicts(defaultPlan.conflicts) }
            try await waitUntil("Native default-Skip choices") { browser.view.window?.attachedSheet != nil }
            guard let defaultsSheet = browser.view.window?.attachedSheet,
                  let proceed = recoveryButton("Continue", in: defaultsSheet.contentView) else { throw Failure(message: "Conflict Continue is unavailable") }
            try await waitUntil("First conflict is visible after native accessory layout") {
                guard let table = recoveryTable(in: defaultsSheet.contentView) else { return false }
                return table.rows(in: table.visibleRect).location == 0
            }
            try await snapshot(defaultsSheet, to: output.appendingPathComponent("transfer-defaults.png"))
            proceed.performClick(nil)
            guard let resolutions = await choices.value else { throw Failure(message: "Default Skip choices cancelled unexpectedly") }
            try require(resolutions.count == 40 && resolutions.values.allSatisfy { $0 == .skip },
                        "Continue omitted default Skip choices, including nonvisible rows")
            let skipped = await engine.perform(defaultPlan, resolutions: resolutions)
            try require(skipped.recordID == nil && skipped.result.disposition == .succeeded
                && skipped.result.items.count == 40 && skipped.result.items.allSatisfy { $0.status == .skipped },
                        "All-Skip transfer unexpectedly mutated or failed preflight")

            let reopened = BrowserWindowController(settings: BrowserSettings(persist: false))
            reopened.window?.isReleasedWhenClosed = false
            reopened.browser.recoverableFileOperations = fresh
            defer { reopened.browser.suspendBrowser(); reopened.close() }
            var reopenedBeginFinished = false
            reopened.browser.didFinishBeginForVerification = { reopenedBeginFinished = true }
            reopened.showWindow(nil)
            reopened.window?.makeKeyAndOrderFront(nil)
            reopened.browser.begin()
            try await waitUntil("Fresh browser startup inspection") { reopenedBeginFinished }
            await reopened.browser.recoveryInspectionTask?.value
            try require(reopened.browser.hasRecoveryAttention && !reopened.browser.recoveryAttentionButton.isHidden
                && reopened.window?.attachedSheet == nil && reopened.browser.recoveryAttentionButton.isEnabled,
                        "Fresh startup recovery was modal or unavailable through in-window attention")
            if let window = reopened.window {
                try await snapshot(window, to: output.appendingPathComponent("startup-recovery-attention.png"))
            }
            reopened.browser.recoveryAttentionButton.performClick(nil)
            try require(reopened.browser.recoveryWindow != nil, "Startup attention did not expose retained history")
            reopened.browser.recoveryWindow?.close()
            await reopened.browser.recoveryInspectionTask?.value
            let second = BrowserWindowController(settings: BrowserSettings(persist: false))
            second.window?.isReleasedWhenClosed = false
            second.browser.recoverableFileOperations = fresh
            defer {
                if let sheet = second.window?.attachedSheet { second.window?.endSheet(sheet, returnCode: .abort) }
                second.browser.suspendBrowser(); second.close()
            }
            var secondBeginFinished = false
            second.browser.didFinishBeginForVerification = { secondBeginFinished = true }
            second.showWindow(nil)
            second.browser.begin()
            try await waitUntil("Second browser recovery inspection") { secondBeginFinished }
            await second.browser.recoveryInspectionTask?.value
            try require(second.browser.hasRecoveryAttention && second.window?.attachedSheet == nil,
                        "A second window unexpectedly opened modal startup recovery")
            try require(Set(second.browser.recoveryRecords.map(\.id)) == Set(reopened.browser.recoveryRecords.map(\.id))
                && Set(second.browser.refusedRecoveryEntries) == Set(reopened.browser.refusedRecoveryEntries),
                        "Quiet startup hid retained recovery records")
            second.browser.showOperationRecovery(nil)
            try require(second.browser.recoveryWindow != nil,
                        "Quiet startup disabled explicit Operation Recovery")
            second.browser.recoveryWindow?.close()
            reopened.browser.suspendBrowser()
            reopened.close()
            browser.view.window?.makeKeyAndOrderFront(nil)
            browser.focusBrowserContent()
            checks.append("Native file/text Command-Z, busy-close protection, conflict Cancel/default Continue across 40 rows and repeated quiet startup attention with explicit history still available")
        }
        if ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1" {
            let other = try await Task.detached { () throws -> (root: URL, sourceDevice: Int32, destinationDevice: Int32) in
                var sourceInfo = stat(), tempInfo = stat()
                guard source.withUnsafeFileSystemRepresentation({ lstat($0!, &sourceInfo) }) == 0,
                      lstat("/private/tmp", &tempInfo) == 0, tempInfo.st_mode & S_IFMT == S_IFDIR,
                      sourceInfo.st_dev != tempInfo.st_dev else {
                    throw Failure(message: "Explicit cross-volume UI check requires distinct actual fixture devices")
                }
                var template = Array("/private/tmp/mac-explorer-native-cross-volume-XXXXXX".utf8CString)
                guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
                    guard let created = mkdtemp(buffer.baseAddress!) else { return nil }
                    return String(cString: created)
                }) else {
                    throw Failure(message: "Could not create the private cross-volume UI fixture")
                }
                let root = URL(fileURLWithPath: path, isDirectory: true)
                try Data("MacExplorer owned native cross-volume fixture v1\n\(UUID().uuidString)".utf8)
                    .write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
                return (root, sourceInfo.st_dev, tempInfo.st_dev)
            }.value
            let crossSource = source.appendingPathComponent("Native Cross Volume.txt")
            let crossDestination = other.root.appendingPathComponent(crossSource.lastPathComponent)
            let body = Data((0..<65_536).map { UInt8($0 % 251) })
            try await Task.detached { try body.write(to: crossSource, options: .withoutOverwriting) }.value
            browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
            try choose(crossSource.lastPathComponent); browser.table.cut(nil)
            await browser.cutPreparationTask?.value
            browser.navigate(to: .directory(other.root)); try await settled(browser); browser.focusBrowserContent()
            browser.table.paste(nil); try await waitRecoveryOperation(browser)
            try require(browser.lastOperationResult?.disposition == .succeeded
                && !FileManager().fileExists(atPath: crossSource.path) && (try Data(contentsOf: crossDestination)) == body,
                        "Native cross-volume Cut/Paste did not retire the source after verified publication")
            let crossRecord = try requireRecoveryID(browser)
            browser.undoFileOperation(nil); try await waitRecoveryOperation(browser)
            try require(browser.lastOperationResult?.disposition == .succeeded && (try Data(contentsOf: crossSource)) == body
                && !FileManager().fileExists(atPath: crossDestination.path),
                        "Native cross-volume Undo did not restore the original generated body")
            let receipt: [String: Any] = ["passed": true, "recordID": crossRecord.uuidString,
                "sourceFixture": crossSource.path, "destinationFixture": crossDestination.path,
                "sourceDevice": other.sourceDevice, "destinationDevice": other.destinationDevice,
                "payloadBytes": body.count, "movePayloadMatched": true, "undoPayloadMatched": true,
                "scope": "Native observed Cut/Paste and Undo on two existing local volumes; UUID-marked disposable fixtures only. Retained recovery areas remain. No remount, permanent cleanup or personal file operation."]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("recoverable-native-cross-volume.json"), options: .withoutOverwriting)
            checks.append("Native observed Cut/Paste across two actual local devices and journaled Undo preserve a generated 64 KiB payload")
        }
        if ProcessInfo.processInfo.arguments.contains("--qualify-trash-fixture") {
            let payload = source.appendingPathComponent("mac-explorer-recovery-trash-\(UUID().uuidString).txt")
            let data = Data("MacExplorer generated native Trash Undo payload v1".utf8)
            try await Task.detached { try data.write(to: payload, options: .withoutOverwriting) }.value
            let observed = try await engine.observeSelection([payload])
            let trashed = await engine.perform(.trash(sources: [payload]), observing: observed)
            let attempt: [String: Any] = ["passed": trashed.result.disposition == .succeeded,
                "recordID": trashed.recordID?.uuidString ?? "none", "disposition": trashed.result.disposition.rawValue,
                "items": trashed.result.items.map { item in
                    ["source": item.source?.path ?? "none", "destination": item.destination?.path ?? "none",
                     "status": String(describing: item.status), "recoveryURLs": item.recoveryURLs.map(\.path)] as [String: Any]
                }]
            try JSONSerialization.data(withJSONObject: attempt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("recoverable-native-trash-attempt.json"), options: .withoutOverwriting)
            guard trashed.result.disposition == .succeeded, let record = trashed.recordID,
                  let location = trashed.result.items.first?.destination else {
                throw Failure(message: "Owned native recovery Trash did not qualify; inspect retained recovery records/locations")
            }
            let undone = await engine.undo(recordID: record)
            try require(undone.result.disposition == .succeeded && (try Data(contentsOf: payload)) == data,
                        "Owned native Trash Undo did not restore its exact generated payload; inspect recovery locations")
            let receipt: [String: Any] = ["passed": true, "authorization": "explicit-owned-fixture", "recordID": record.uuidString,
                "originalFixture": payload.path, "knownSystemTrashLocation": location.path,
                "restoredFixture": payload.path, "originalAndRestoredPayloadMatched": true,
                "boundary": "Only newly generated fixture; no Trash enumeration, personal file, permanent cleanup or human confirmation claim"]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("recoverable-native-trash.json"), options: .withoutOverwriting)
            checks.append("Explicit real native system Trash and journaled Undo restore only the generated owned payload")
        }
        return checks
    }

    private static func verifyTransferOptions(_ browser: BrowserViewController, source: URL, destination: URL,
                                              output: URL, interactive: Bool) async throws {
        let preference = browser.settings.transferMetadata
        let prompt = browser.transferMetadataPrompt
        defer {
            browser.settings.transferMetadata = preference
            browser.transferMetadataPrompt = prompt
        }
        browser.settings.transferMetadata = .destinationOwnership
        try select("Copy.txt", in: browser)
        browser.table.copy(nil)
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        browser.focusBrowserContent()
        var offered: TransferMetadataPolicy?
        browser.transferMetadataPrompt = { offered = $0; return nil }
        browser.pasteWithOptions(nil)
        try await waitRecoveryOperation(browser)
        try require(offered == .destinationOwnership && browser.settings.transferMetadata == .destinationOwnership
                    && !FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                    "Cancelling Paste with Options changed files or the default metadata mode")
        try resumeReviewedTransferQueue(browser, after: "metadata options Cancel")
        if interactive {
            browser.transferMetadataPrompt = nil
            browser.pasteWithOptions(nil)
            try await waitUntil("Native metadata options sheet") { browser.view.window?.attachedSheet != nil }
            guard let sheet = browser.view.window?.attachedSheet,
                  let picker = recoveryMetadataPicker(in: sheet.contentView),
                  let cancel = recoveryButton("Cancel", in: sheet.contentView) else {
                throw Failure(message: "Metadata options sheet lacks native picker or Cancel")
            }
            try require(picker.itemTitles == TransferMetadataPreference.allCases.map(\.rawValue)
                        && picker.indexOfSelectedItem == 1, "Native metadata options did not select the captured default")
            try await snapshot(sheet, to: output.appendingPathComponent("metadata-transfer-options.png"))
            cancel.performClick(nil)
            try await waitRecoveryOperation(browser)
            try require(!FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                        "Native options Cancel copied a file")
            try resumeReviewedTransferQueue(browser, after: "native metadata options Cancel")
        }
        browser.transferMetadataPrompt = { _ in
            BrowserClipboard.write("Newer generated clipboard text", urls: [], to: browser.transferPasteboard)
            return .strict
        }
        browser.pasteWithOptions(nil)
        try await waitRecoveryOperation(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && (try Data(contentsOf: destination.appendingPathComponent("Copy.txt")))
                        == Data(contentsOf: source.appendingPathComponent("Copy.txt"))
                    && browser.transferPasteboard.string(forType: .string) == "Newer generated clipboard text",
                    "Accepted Paste with Options lost its captured sources or changed a newer clipboard")
        try await waitUntil("Captured options Copy Undo capability") { browser.canUndoFileOperation }
        browser.undoFileOperation(nil)
        try await waitRecoveryOperation(browser)
        try require(!FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                    "Captured options Copy Undo left its generated destination")
        browser.navigate(to: .directory(source))
        try await settled(browser)
        try select("Copy.txt", in: browser)
        browser.table.copy(nil)
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        browser.focusBrowserContent()
        browser.transferMetadataPrompt = { _ in .strict }
        browser.pasteWithOptions(nil)
        try await waitRecoveryOperation(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && browser.settings.transferMetadata == .destinationOwnership
                    && FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                    "One-transfer metadata override failed or changed the saved preference")
        browser.undoFileOperation(nil)
        try await waitRecoveryOperation(browser)
        try require(!FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                    "Quarantined options copy could not be undone with its actual destination metadata")
        browser.settings.transferMetadata = .strict
        browser.navigate(to: .directory(source))
        try await settled(browser)
        browser.focusBrowserContent()
    }

    private static func verifyRecoveryInspectionContext(_ engine: RecoverableFileOperations,
                                                        alternate: RecoverableFileOperations) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        let probe = BrowserViewController(settings: settings)
        probe.pinsController = BrowserPinsController(stateDirectory: nil)
        probe.folderAccess = FolderAccessController(stateDirectory: nil)
        probe.recoverableFileOperations = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = probe
        defer {
            probe.beforeRecoveryInspectionReturnsForVerification = nil
            probe.suspendBrowser(); window.orderOut(nil); window.close()
        }
        for context in ["engine", "window", "suspended"] {
            let gate = RecoveryInspectionReturnGate()
            defer { gate.release() }
            probe.recoverableFileOperations = engine
            window.contentViewController = probe
            probe.beforeRecoveryInspectionReturnsForVerification = { await gate.wait() }
            probe.inspectOperationRecovery()
            let task = probe.recoveryInspectionTask
            try await waitUntil("Captured recovery inspection return") { gate.entered }
            switch context {
            case "engine": probe.recoverableFileOperations = alternate
            case "window": window.contentViewController = nil
            default: probe.suspendBrowser()
            }
            gate.release()
            await task?.value
            try require(probe.recoveryRecords.isEmpty && probe.refusedRecoveryEntries.isEmpty
                        && probe.recoveryUnfinishedCount == 0 && window.attachedSheet == nil,
                        "A stale \(context) recovery inspection published captured history or opened review")
        }
    }

    private static func requireRecoveryID(_ browser: BrowserViewController) throws -> UUID {
        guard let id = browser.lastRecoveryRecordID else { throw Failure(message: "Native recoverable operation lost its record ID") }
        return id
    }
    private static func waitRecoveryOperation(_ browser: BrowserViewController) async throws {
        do { try await waitUntil("Recoverable native command completion") { !browser.hasPendingFileOperation } }
        catch {
            let state = browser.operationCoordinator.transfers.state
            throw Failure(message: "Recoverable command did not drain: \(error); queue active=\(String(describing: state.active?.id)); waiting=\(state.waiting.count); paused=\(state.isPaused); browserTask=\(browser.operationTask != nil); preparing=\(browser.operationPreparationTask != nil)")
        }
        await browser.recoveryInspectionTask?.value
        try await settled(browser)
    }
    private static func resumeReviewedTransferQueue(_ browser: BrowserViewController, after context: String) throws {
        let queue = browser.operationCoordinator.transfers
        try require(queue.state.isPaused && queue.state.active == nil,
                    "Queue failed to retain its explicit pause after \(context)")
        try require(queue.resume(), "Reviewed queue could not resume after \(context)")
    }
    private static func recoveryButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { recoveryButton(title, in: $0) }.first
    }
    private static func recoveryMetadataPicker(in view: NSView?) -> NSPopUpButton? {
        guard let view else { return nil }
        if let picker = view as? NSPopUpButton { return picker }
        return view.subviews.lazy.compactMap { recoveryMetadataPicker(in: $0) }.first
    }
    private static func recoveryText(in view: NSView?) -> String {
        guard let view else { return "" }
        return (view as? NSTextView)?.string ?? view.subviews.map { recoveryText(in: $0) }.joined(separator: "\n")
    }
    private static func recoveryTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { recoveryTable(in: $0) }.first
    }
}

@MainActor
private final class RecoveryInspectionReturnGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let pending = continuation; continuation = nil
        pending?.resume()
    }
}
#endif
