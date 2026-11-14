#if DEBUG
import AppKit
import FileOperations

@MainActor
extension UIVerification {
    static func verifyTransferContinuation(_ browser: BrowserViewController, in testRoot: URL, output: URL,
                                           interactive: Bool) async throws -> [String] {
        let owned = testRoot.appendingPathComponent("continuation-ui-" + UUID().uuidString, isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("Mac Explorer generated continuation fixture v1".utf8)
                .write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            for name in ["Original clipboard", "Newer clipboard"] {
                let root = owned.appendingPathComponent(name, isDirectory: true)
                let source = root.appendingPathComponent("Source", isDirectory: true)
                let destination = root.appendingPathComponent("Destination", isDirectory: true)
                try FileManager().createDirectory(at: source, withIntermediateDirectories: true)
                try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("generated completed source".utf8).write(to: source.appendingPathComponent("Completed.txt"), options: .withoutOverwriting)
                try Data("generated remaining source".utf8).write(to: source.appendingPathComponent("Remaining.txt"), options: .withoutOverwriting)
                try Data("generated existing destination".utf8).write(to: destination.appendingPathComponent("Remaining.txt"), options: .withoutOverwriting)
            }
        }.value
        try await verifyTransferConflictGeometry(browser, root: owned.appendingPathComponent("Original clipboard", isDirectory: true), output: output)
        let originalEngine = browser.recoverableFileOperations
        let originalPrompt = browser.transferConflictPrompt
        let originalResult = browser.operationResultPresenter
        let originalError = browser.operationErrorPresenter
        let originalPolicy = browser.settings.transferMetadata
        var errors: [String] = []
        browser.operationResultPresenter = { _ in }
        browser.operationErrorPresenter = { errors.append($0) }
        browser.settings.transferMetadata = .strict
        defer {
            browser.recoveryInspectionTask?.cancel()
            browser.recoverableFileOperations = originalEngine
            browser.transferConflictPrompt = originalPrompt
            browser.operationResultPresenter = originalResult
            browser.operationErrorPresenter = originalError
            browser.settings.transferMetadata = originalPolicy
            browser.lastTransferContinuation = nil
            browser.continuationMoveClipboard = nil
            browser.recoveryRecords = []
            browser.clearCutSelection()
        }
        func completed() async throws {
            try await waitUntil("Native continuation completion") { !browser.hasPendingFileOperation }
            await browser.recoveryInspectionTask?.value
            try await settled(browser)
        }
        for (index, name) in ["Original clipboard", "Newer clipboard"].enumerated() {
            let root = owned.appendingPathComponent(name, isDirectory: true)
            let source = root.appendingPathComponent("Source", isDirectory: true)
            let destination = root.appendingPathComponent("Destination", isDirectory: true)
            browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal", isDirectory: true))
            browser.navigate(to: .directory(source)); try await settled(browser); browser.focusBrowserContent()
            browser.table.selectAll(nil)
            browser.table.cut(nil); await browser.cutPreparationTask?.value
            let clipboardCount = browser.transferPasteboard.changeCount
            browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
            browser.transferConflictPrompt = { conflicts in Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }) }
            browser.table.paste(nil); try await completed()
            guard let firstID = browser.lastRecoveryRecordID, let token = browser.lastTransferContinuation else {
                throw Failure(message: "Partial native move has no guarded remaining-work token")
            }
            try require(token.remainingSources == [source.appendingPathComponent("Remaining.txt")]
                && token.metadataPolicy == .strict && browser.transferPasteboard.changeCount == clipboardCount,
                        "Native partial move lost its exact remainder or original clipboard")
            let queue = browser.operationCoordinator.transfers
            try require(!queue.state.isPaused && queue.state.active == nil && queue.canRunExclusiveCommand,
                        "Explicit Skip decisions did not leave the idle queue available for exclusive continuation")
            browser.transferConflictPrompt = { _ in nil }
            if interactive && index == 0 {
                browser.showLastOperationResult(nil)
                guard let sheet = browser.view.window?.attachedSheet,
                      let button = continuationButton("Continue Remaining", in: sheet.contentView) else {
                    throw Failure(message: "Result sheet has no explicit Continue Remaining action")
                }
                try await snapshot(sheet, to: output.appendingPathComponent("everyday-continue-remaining.png"))
                button.performClick(nil)
                try await waitUntil("Result sheet continuation dismissal") { browser.view.window?.attachedSheet == nil }
            } else { browser.continueRemainingTransfer(nil) }
            try await completed()
            try require(browser.lastTransferContinuation?.id == token.id
                && FileManager().fileExists(atPath: source.appendingPathComponent("Remaining.txt").path),
                        "Cancelled continuation consumed its token or changed the source")
            browser.transferConflictPrompt = { conflicts in
                if index == 1 { BrowserClipboard.write("Newer explicit fixture clipboard", urls: [], to: browser.transferPasteboard) }
                return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .replace) })
            }
            browser.continueRemainingTransfer(nil); try await completed()
            guard let secondID = browser.lastRecoveryRecordID else { throw Failure(message: "Native continuation has no separate Undo record") }
            try require(secondID != firstID && browser.lastTransferContinuation == nil
                && browser.lastOperationResult?.disposition == .succeeded
                && !FileManager().fileExists(atPath: source.appendingPathComponent("Remaining.txt").path)
                && !FileManager().fileExists(atPath: source.appendingPathComponent("Completed.txt").path),
                        "Native continuation retried completed work or failed to move its exact remainder")
            if index == 0 {
                try require(browser.transferPasteboard.types?.isEmpty != false && browser.pendingCut == nil,
                            "Physically complete continued move retained the original Cut clipboard")
            } else {
                try require(browser.transferPasteboard.string(forType: .string) == "Newer explicit fixture clipboard",
                            "Continuation overwrote a newer clipboard")
            }
            try await waitUntil("Continuation Undo availability") { browser.canUndoFileOperation }
            browser.undoFileOperation(nil); try await completed()
            try require(FileManager().fileExists(atPath: source.appendingPathComponent("Remaining.txt").path)
                && !FileManager().fileExists(atPath: source.appendingPathComponent("Completed.txt").path),
                        "Continuation Undo changed the earlier job")
            try await waitUntil("Earlier job Undo availability") { browser.canUndoFileOperation }
            browser.undoFileOperation(nil); try await completed()
            try require(FileManager().fileExists(atPath: source.appendingPathComponent("Completed.txt").path),
                        "Earlier job Undo did not remain independent")
            try require(!queue.state.isPaused && queue.state.active == nil,
                        "Exclusive continuation/Undo changed clean queue advancement state")
        }
        try require(errors.isEmpty, "Native continuation reported an unexpected error")
        return ["Native conflict sheets show all small-list rows and scroll larger lists without changing default Skip decisions",
                "Explicit native Continue Remaining preserves original guards/policy, Cancel and completed work",
                "Continued Move has independent Undo, consumes only its original clipboard and preserves a newer clipboard"]
    }

    private static func verifyTransferConflictGeometry(_ browser: BrowserViewController, root: URL, output: URL) async throws {
        // Planning observes the existing generated conflict; this geometry check
        // never performs a transfer or opens a recovery catalog.
        let before = try await Task.detached { try fixtureSnapshot(root) }.value
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("geometry-unused-journal"))
        var conflicts: [TransferConflict] = []
        for _ in 0..<32 {
            let plan = try await engine.prepareTransfer(sources: [root.appendingPathComponent("Source/Remaining.txt")],
                destinationDirectory: root.appendingPathComponent("Destination"), move: false)
            guard let conflict = plan.conflicts.first else { throw Failure(message: "Generated conflict geometry plan has no conflict") }
            conflicts.append(conflict)
        }
        let sameFolderPlan = try await engine.prepareTransfer(sources: [root.appendingPathComponent("Source/Remaining.txt")],
            destinationDirectory: root.appendingPathComponent("Source"), move: false)
        guard let sameFolder = sameFolderPlan.conflicts.first, !sameFolder.canReplace else {
            throw Failure(message: "Same-folder Copy did not produce its non-replaceable conflict")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func select(_ resolution: TransferConflictResolution, in menu: NSPopUpButton) {
            menu.select(menu.itemArray.first { $0.representedObject as? TransferConflictResolution == resolution })
            menu.sendAction(menu.action, to: menu.target)
        }
        var observations: [[String: Any]] = []
        var failures: [String] = []
        let cases = [1, 2, 3, 6, 32].map { ("existing-destination", Array(conflicts.prefix($0))) }
            + [("same-folder-copy", [sameFolder])]
        for (kind, selected) in cases {
            let count = selected.count
            let (alert, decisions) = makeTransferConflictAlert(selected)
            alert.layout()
            defer { alert.window.orderOut(nil) }
            guard let accessory = alert.accessoryView,
                  let table = descendants(accessory).compactMap({ $0 as? NSTableView }).first,
                  let scroll = table.enclosingScrollView else { throw Failure(message: "Native conflict geometry has no table") }
            alert.window.contentView?.layoutSubtreeIfNeeded()
            accessory.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentView.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = scroll.documentVisibleRect
            let first = table.rect(ofRow: 0), last = table.rect(ofRow: count - 1)
            let allSmallRowsVisible = first.minY >= visible.minY - 1 && last.maxY <= visible.maxY + 1
            table.scrollRowToVisible(count - 1)
            accessory.layoutSubtreeIfNeeded()
            let scrolled = scroll.documentVisibleRect
            let lastVisible = last.minY >= scrolled.minY - 1 && last.maxY <= scrolled.maxY + 1
            let defaultSkip = selected.allSatisfy { decisions()[$0.id] == .skip }
            let controls = descendants(accessory).compactMap { $0 as? NSPopUpButton }
            let nativeRows = (0..<min(count, 6)).compactMap { table.view(atColumn: 1, row: $0, makeIfNecessary: true) }
            let nativeRowFrames = nativeRows.map { table.convert($0.bounds, from: $0) }
            let rowsFit = nativeRowFrames.count == min(count, 6) && nativeRowFrames.enumerated().allSatisfy { index, frame in
                let row = table.rect(ofRow: index)
                return frame.height.isFinite && frame.height > 0 && frame.minY >= row.minY - 1 && frame.maxY <= row.maxY + 1
            }
            let actionsFitHorizontally = nativeRowFrames.allSatisfy { $0.minX >= visible.minX - 1 && $0.maxX <= visible.maxX + 1 }
            let rowMenu = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSPopUpButton
            let rowOptions = rowMenu?.itemArray.compactMap { ($0.representedObject as? TransferConflictResolution)?.rawValue } ?? []
            let safeOptions = rowOptions.contains("keepBoth") && rowOptions.contains("skip")
                && rowOptions.contains("replace") == selected[0].canReplace
                && rowOptions.contains("merge") == selected[0].canMerge
            var rowActionPreserved = false
            if let rowMenu {
                select(.keepBoth, in: rowMenu)
                rowActionPreserved = decisions()[selected[0].id] == .keepBoth
                select(.skip, in: rowMenu)
            }
            var bulkActionsPreserved = false
            var bulkReplaceEligible = false
            if let all = controls.first(where: { $0.itemTitle(at: 0) == "Set all to Skip" }) {
                bulkReplaceEligible = all.itemArray.contains { $0.representedObject as? TransferConflictResolution == .replace }
                    == selected.contains(where: \.canReplace)
                select(.replace, in: all)
                let replaced = selected.allSatisfy { decisions()[$0.id] == ($0.canReplace ? .replace : .skip) }
                select(.keepBoth, in: all)
                let kept = selected.allSatisfy { decisions()[$0.id] == .keepBoth }
                select(.skip, in: all)
                bulkActionsPreserved = replaced && kept && selected.allSatisfy { decisions()[$0.id] == .skip }
            }
            observations.append(["kind": kind, "count": count, "accessory": NSStringFromRect(accessory.frame),
                "tableFrame": NSStringFromRect(table.frame), "tableBounds": NSStringFromRect(table.bounds),
                "columnWidths": table.tableColumns.map(\.width), "columnMinimums": table.tableColumns.map(\.minWidth),
                "columnAutoresizing": table.columnAutoresizingStyle.rawValue,
                "clipFrame": NSStringFromRect(scroll.contentView.frame),
                "rowHeight": table.rowHeight, "rowSpacing": table.intercellSpacing.height,
                "visible": NSStringFromRect(visible), "firstRow": NSStringFromRect(first),
                "lastRow": NSStringFromRect(last), "scrolledVisible": NSStringFromRect(scrolled),
                "allSmallRowsVisible": allSmallRowsVisible, "lastVisibleAfterScroll": lastVisible,
                "nativeRowsFit": rowsFit, "defaultSkip": defaultSkip, "popupCount": controls.count,
                "actionsFitHorizontally": actionsFitHorizontally,
                "rowOptions": rowOptions, "safeOptions": safeOptions, "rowKeepBothAction": rowActionPreserved,
                "nativeActionFrames": nativeRowFrames.map(NSStringFromRect), "bulkActionsPreserved": bulkActionsPreserved,
                "bulkReplaceEligible": bulkReplaceEligible,
                "buttons": alert.buttons.map(\.title)])
            if count <= 6 && !allSmallRowsVisible { failures.append("\(count)-item conflict sheet clips a row") }
            if !actionsFitHorizontally { failures.append("\(count)-item conflict sheet clips an action popup horizontally") }
            if !lastVisible || !rowsFit || !defaultSkip || !safeOptions || !rowActionPreserved || !bulkActionsPreserved || !bulkReplaceEligible || accessory.frame.height > 390.5
                || alert.buttons.map(\.title) != ["Continue", "Cancel"] {
                failures.append("\(count)-item conflict sheet lost native layout, scroll or default decisions")
            }
            if [1, 3, 32].contains(count) && kind == "existing-destination" {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentView.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await snapshot(alert.window, to: output.appendingPathComponent("conflict-sheet-\(count).png"))
            }
        }
        let after = try await Task.detached { try fixtureSnapshot(root) }.value
        if before != after { failures.append("Conflict geometry validation changed its generated fixture") }
        let data = try JSONSerialization.data(withJSONObject: ["cases": observations, "failures": failures,
            "fixtureUnchanged": before == after, "transferPerformed": false, "catalogOpened": false], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("conflict-sheet-geometry.json"), options: .withoutOverwriting)
        try require(failures.isEmpty, failures.joined(separator: "; "))
    }

    private static func continuationButton(_ title: String, in root: NSView?) -> NSButton? {
        guard let root else { return nil }
        if let button = root as? NSButton, button.title == title { return button }
        return root.subviews.lazy.compactMap { continuationButton(title, in: $0) }.first
    }
}
#endif
