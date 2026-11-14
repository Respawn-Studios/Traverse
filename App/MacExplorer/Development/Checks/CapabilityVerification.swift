import AppKit
import FileOperations
import SwiftUI

#if DEBUG
extension UIVerification {
    static func verifyPreferences(_ browser: BrowserViewController, fixture: URL, output: URL, interactive: Bool = true) async throws -> [String] {
        let legacy = Data(#"{"version":1,"showsCommandRow":false,"showsHiddenFiles":true,"keyboardProfile":"Mac"}"#.utf8)
        let restored = BrowserSettings(persist: false, restoredData: legacy)
        try require(!restored.showsCommandRow && restored.showsHiddenFiles && restored.keyboardProfile == .mac
                    && restored.appearance == .system && restored.navigationStyle == .glass && restored.transferMetadata == .strict,
                    "Legacy preferences lost existing choices or additive defaults")
        restored.appearance = .dark
        restored.navigationStyle = .solid
        restored.viewMode = .list
        restored.rowDensity = .compact
        restored.showsFileExtensions = false
        restored.foldersFirst = false
        restored.showsSizeColumn = false
        restored.transferMetadata = .destinationOwnership
        let roundTrip = BrowserSettings(persist: false, restoredData: try restored.encodedSnapshot())
        try require(roundTrip.appearance == .dark && roundTrip.navigationStyle == .solid && roundTrip.viewMode == .list
                    && roundTrip.rowDensity == .compact && !roundTrip.showsFileExtensions && !roundTrip.foldersFirst
                    && !roundTrip.showsSizeColumn && !roundTrip.showsCommandRow && roundTrip.transferMetadata == .destinationOwnership,
                    "Preference snapshot did not round-trip")
        let invalid = BrowserSettings(persist: false, restoredData: Data("invalid".utf8))
        try require(invalid.showsCommandRow && invalid.viewMode == .details, "Invalid preferences lost safe defaults")

        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        try select("Résumé – नमस्ते – 日本語.txt", in: browser)
        let selection = browser.selectedURLs
        browser.settings.viewMode = .list
        browser.settings.rowDensity = .compact
        browser.settings.showsFileExtensions = false
        browser.settings.appearance = .dark
        browser.settings.navigationStyle = .solid
        try await Task.sleep(for: .milliseconds(120))
        try require(browser.table.headerView == nil && browser.table.rowHeight == 20
                    && browser.table.tableColumns.filter { !$0.isHidden }.count == 1,
                    "List mode or compact rows did not update the native table")
        try require(browser.selectedURLs == selection, "Display preferences erased selection")
        let row = browser.rowsByURL[selection.first!]!
        let cell = browser.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        try require(cell?.textField?.stringValue == "Résumé – नमस्ते – 日本語", "Extension preference did not affect display names")
        try require(browser.navigationSurface?.isUsingOpaqueSurface == true, "Solid navigation preference was ignored")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("12-list-dark.png"))
        browser.settings.viewMode = .details
        browser.settings.rowDensity = .comfortable
        browser.settings.showsFileExtensions = true
        browser.settings.showsKindColumn = false
        browser.settings.foldersFirst = false
        try await Task.sleep(for: .milliseconds(120))
        try await settled(browser)
        try require(browser.table.headerView != nil && browser.table.rowHeight == 25
                    && browser.table.tableColumns.first { $0.identifier.rawValue == "kind" }?.isHidden == true,
                    "Details mode did not restore its header or selected columns")
        try require(!browser.tabs[browser.activeIndex].sort.foldersFirst && browser.selectedURLs == selection,
                    "Sorting preference lost selection or failed to update")
        browser.settings.showsKindColumn = true
        browser.settings.foldersFirst = true
        browser.settings.appearance = .light
        browser.settings.navigationStyle = .glass
        try await Task.sleep(for: .milliseconds(120))
        try await settled(browser)
        try require(browser.navigationSurface?.isUsingOpaqueSurface == NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                    "Glass preference failed to apply the accessibility fallback")
        let settings = BrowserSettingsWindow.make(BrowserSettingsView(settings: browser.settings, initialPage: .appearance))
        settings.title = "Mac Explorer Settings"
        settings.styleMask = [.titled, .closable]
        settings.isReleasedWhenClosed = false
        settings.center()
        if interactive { settings.makeKeyAndOrderFront(nil) }
        else { settings.contentView?.layoutSubtreeIfNeeded() }
        try await snapshot(settings, to: output.appendingPathComponent("13-appearance-settings.png"))
        settings.close()
        if interactive { browser.view.window?.makeKeyAndOrderFront(nil) }

        let location = browser.location
        if interactive {
            browser.focusLocation(nil)
            try require(!browser.commandEnabled(#selector(BrowserViewController.goUp(_:)))
                        && !browser.commandEnabled(#selector(BrowserViewController.openSelection(_:))),
                        "Text editing retained browser-targeted arrow commands")
            _ = NSApplication.shared.mainMenu?.performKeyEquivalent(with: key(String(UnicodeScalar(0xF700)!), code: 126, flags: .command, window: browser.view.window!))
            _ = NSApplication.shared.mainMenu?.performKeyEquivalent(with: key(String(UnicodeScalar(0xF701)!), code: 125, flags: .command, window: browser.view.window!))
            try require(browser.location == location && browser.view.window?.firstResponder is NSTextView,
                        "Command-arrow while editing navigated the browser")
            try require(!browser.handleExplorerShortcut(key("x", code: 7, flags: .control, window: browser.view.window!))
                        && !browser.handleExplorerShortcut(key("v", code: 9, flags: .control, window: browser.view.window!)),
                        "File Cut/Paste aliases intercepted field editing")
        } else {
            // Ordinary address entry deliberately requires a visible window.
            // Hidden verification cannot claim native text-field focus.
            let responder = browser.view.window?.firstResponder, hidden = browser.pathField.isHidden
            browser.focusLocation(nil)
            try require(browser.view.window?.isVisible == false && browser.location == location
                && browser.pathField.isHidden == hidden && browser.view.window?.firstResponder === responder,
                "Hidden address command changed navigation or text focus")
        }
        browser.focusBrowserContent()
        return ["Versioned preferences: legacy migration, complete snapshot round-trip and invalid-data defaults",
                "Native List/Details, compact rows, extensions, columns and folders-first preserve selection",
                "System/Light/Dark and Glass/Solid materials with current accessibility fallback",
                interactive ? "Text field editing retains Command-arrow and Ctrl-X/V behavior"
                    : "Hidden address commands preserve navigation and focus; text editing and foreground event delivery not exercised"]
    }

    static func verifyOperations(_ browser: BrowserViewController, in testRoot: URL, output: URL) async throws -> [String] {
        // AccessVerification has already validated this explicit disposable root.
        let owned = testRoot.appendingPathComponent("ui-operations-\(UUID().uuidString)", isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("mac-explorer-ui-operations-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"))
            for name in ["Alpha.txt", "Cut.txt", "Fresh.txt", "Stale.txt", "Keep.txt"] {
                try Data("Fixture body for \(name)".utf8).write(to: source.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }.value
        var errors: [String] = []
        browser.operationErrorPresenter = { errors.append($0) }
        browser.operationResultPresenter = { _ in }
        browser.operationNamePrompt = { title, _ in title == "New Folder" ? "Created Folder" : "Renamed.txt" }
        browser.operationConflictPrompt = { _ in false }
        browser.operationTrashPrompt = { _ in false } // NEVER exercise the system Trash from this harness.
        defer {
            browser.clearCutSelection()
            browser.operationNamePrompt = nil
            browser.operationConflictPrompt = nil
            browser.operationTrashPrompt = nil
            browser.operationResultPresenter = nil
            browser.operationErrorPresenter = nil
        }
        browser.navigate(to: .directory(source))
        try await settled(browser)
        browser.focusBrowserContent()
        browser.createFolder(BrowserMenus.newFolderItem(target: browser, named: true))
        try await operationSettled(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && FileManager().fileExists(atPath: source.appendingPathComponent("Created Folder").path), "Native New Folder command failed")
        try select("Alpha.txt", in: browser)
        browser.table.keyDown(with: key(String(UnicodeScalar(0xF705)!), code: 120, flags: [], window: browser.view.window!))
        try await operationSettled(browser)
        let renamed = source.appendingPathComponent("Renamed.txt")
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && !FileManager().fileExists(atPath: source.appendingPathComponent("Alpha.txt").path), "Explorer F2 rename failed")
        let original = try Data(contentsOf: renamed)
        try select("Renamed.txt", in: browser)
        browser.table.copy(nil)
        try require(!browser.clipboardStatus.isHidden && browser.clipboardStatus.stringValue.contains("Copied 1 item")
                    && browser.cutURLs.isEmpty, "Copy did not show ready-to-paste feedback")
        browser.refreshStatus()
        try require(browser.clipboardStatus.stringValue.contains("Ready to paste"),
                    "A listing status refresh erased Copy feedback")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("clipboard-copy-ready.png"))
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        try require(!browser.clipboardStatus.isHidden, "Navigation erased valid Copy feedback")
        browser.table.paste(nil)
        try await operationSettled(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && (try Data(contentsOf: destination.appendingPathComponent("Renamed.txt"))) == original
                    && (try Data(contentsOf: renamed)) == original, "Native Copy/Paste did not preserve both file bodies")

        browser.navigate(to: .directory(source))
        try await settled(browser)
        try select("Cut.txt", in: browser)
        browser.table.cut(nil)
        try await waitUntil("Cut observation") { browser.cutPreparationTask == nil }
        try require(browser.pendingCut?.urls == [source.appendingPathComponent("Cut.txt")], "Cut did not retain the observed selection")
        guard let cutRow = browser.rowsByURL[source.appendingPathComponent("Cut.txt")],
              let cutCell = browser.table.view(atColumn: 0, row: cutRow, makeIfNecessary: true) as? FileNameCellView else {
            throw Failure(message: "Cut item did not render a name cell")
        }
        try require(cutCell.alphaValue < 0.75 && !cutCell.cutMarker.isHidden
                    && cutCell.accessibilityLabel()?.contains("ready to move") == true
                    && browser.clipboardStatus.stringValue.contains("Cut 1 item"),
                    "Cut must show dimming, a marker, accessible state and persistent feedback")
        try select("Keep.txt", in: browser)
        browser.refreshStatus()
        try require(browser.clipboardStatus.stringValue.contains("Ready to move"),
                    "Changing selection erased valid Cut feedback")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("clipboard-cut-ready.png"))
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        browser.table.paste(nil)
        try await operationSettled(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded && browser.cutURLs.isEmpty
                    && browser.clipboardStatus.isHidden
                    && !FileManager().fileExists(atPath: source.appendingPathComponent("Cut.txt").path)
                    && (try Data(contentsOf: destination.appendingPathComponent("Cut.txt"))) == Data("Fixture body for Cut.txt".utf8),
                    "Native Cut/Paste did not perform a same-volume move")

        browser.navigate(to: .directory(source))
        try await settled(browser)
        try select("Renamed.txt", in: browser)
        browser.table.copy(nil)
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        browser.table.paste(nil)
        try await operationSettled(browser)
        try require(browser.lastOperationResult == nil && (try Data(contentsOf: destination.appendingPathComponent("Renamed.txt"))) == original,
                    "Conflict cancellation changed the existing destination")

        browser.navigate(to: .directory(source))
        try await settled(browser)
        browser.table.selectRowIndexes(IndexSet([browser.rowsByURL[renamed]!, browser.rowsByURL[source.appendingPathComponent("Fresh.txt")]!]), byExtendingSelection: false)
        browser.table.copy(nil)
        browser.operationConflictPrompt = { _ in
            browser.navigate(to: .directory(source))
            await Task.yield()
            try? await settled(browser)
            try? select("Keep.txt", in: browser)
            return true
        }
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        browser.table.paste(nil)
        try await operationSettled(browser)
        try require(browser.lastOperationResult?.disposition == .succeeded
                    && FileManager().fileExists(atPath: destination.appendingPathComponent("Fresh.txt").path)
                    && (try Data(contentsOf: destination.appendingPathComponent("Renamed.txt"))) == original,
                    "Skip-conflict choice replaced a file or skipped the nonconflicting item")
        try require(browser.location == .directory(source) && browser.selectedURLs == [source.appendingPathComponent("Keep.txt")],
                    "Operation completion disturbed another visit's selection")

        try select("Keep.txt", in: browser)
        browser.table.cut(nil)
        try await waitUntil("Ready Cut before external clipboard change") { browser.cutPreparationTask == nil }
        BrowserClipboard.write("Replacement clipboard text", urls: [], to: browser.transferPasteboard)
        try await waitUntil("Stale Cut feedback clears") {
            browser.cutURLs.isEmpty && browser.clipboardStatus.isHidden
        }
        try require(browser.transferPasteboard.string(forType: .string) == "Replacement clipboard text",
                    "Clearing stale Cut feedback changed newer clipboard contents")
        let writer = browser.clipboardWriter
        browser.clipboardWriter = { _, _ in .failed }
        browser.table.copy(nil)
        browser.clipboardWriter = writer
        try require(browser.clipboardStatus.isHidden && browser.status.stringValue.contains("could not be placed"),
                    "Failed clipboard publication incorrectly claimed Copy succeeded")
        browser.table.cut(nil)
        BrowserClipboard.write("Newer clipboard text", urls: [], to: browser.transferPasteboard)
        try await waitUntil("Late Cut publication") { browser.cutPreparationTask == nil }
        try require(browser.pendingCut == nil && browser.transferPasteboard.string(forType: .string) == "Newer clipboard text",
                    "Delayed Cut overwrote newer clipboard contents")
        let beforeCloseClipboard = browser.transferPasteboard.changeCount
        browser.table.cut(nil)
        let closingCut = browser.cutPreparationTask
        browser.suspendBrowser()
        await closingCut?.value
        try require(browser.pendingCut == nil && browser.transferPasteboard.changeCount == beforeCloseClipboard,
                    "Late Cut publication overwrote the clipboard after browser close")
        browser.resumeBrowser()
        try await settled(browser)
        browser.focusBrowserContent()
        try select("Keep.txt", in: browser)
        browser.trashSelection(nil)
        try await operationSettled(browser)
        try require(FileManager().fileExists(atPath: source.appendingPathComponent("Keep.txt").path), "Cancelled Trash confirmation changed the source")

        try select("Stale.txt", in: browser)
        browser.table.cut(nil)
        try await waitUntil("Stale Cut observation") { browser.cutPreparationTask == nil }
        let stale = source.appendingPathComponent("Stale.txt")
        let displaced = source.appendingPathComponent("Displaced.txt")
        try FileManager().moveItem(at: stale, to: displaced)
        try Data("Replacement occupant".utf8).write(to: stale, options: .withoutOverwriting)
        browser.navigate(to: .directory(destination))
        try await settled(browser)
        let previousErrors = errors.count
        browser.table.paste(nil)
        try await operationSettled(browser)
        try require(errors.count == previousErrors + 1 && !FileManager().fileExists(atPath: destination.appendingPathComponent("Stale.txt").path)
                    && (try Data(contentsOf: stale)) == Data("Replacement occupant".utf8)
                    && FileManager().fileExists(atPath: displaced.path), "Stale Cut moved or damaged a replacement occupant")
        browser.clearCutSelection()

        browser.navigate(to: .directory(source))
        try await settled(browser)
        try select("Keep.txt", in: browser)
        var replacementError: Error?
        browser.operationNamePrompt = { _, _ in
            do {
                try FileManager().moveItem(at: source.appendingPathComponent("Keep.txt"), to: source.appendingPathComponent("Keep-original.txt"))
                try Data("Prompt-time replacement".utf8).write(to: source.appendingPathComponent("Keep.txt"), options: .withoutOverwriting)
            } catch { replacementError = error }
            return "Must-not-rename.txt"
        }
        let renameErrors = errors.count
        browser.renameSelection(nil)
        try await operationSettled(browser)
        try require(replacementError == nil && errors.count == renameErrors + 1
                    && !FileManager().fileExists(atPath: source.appendingPathComponent("Must-not-rename.txt").path)
                    && (try Data(contentsOf: source.appendingPathComponent("Keep.txt"))) == Data("Prompt-time replacement".utf8),
                    "Rename prompt consent transferred to a replacement file")
        browser.refresh(nil)
        try await settled(browser)
        browser.table.deselectAll(nil)
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("14-local-operations.png"))
        return ["Native New Folder, F2 Rename, Copy/Paste and observed same-volume Cut/Paste preserve fixture bodies",
                "Copy/Cut feedback persists through selection and navigation, exposes Cut accessibly and clears on clipboard replacement",
                "Conflict Cancel/Skip preserves existing destinations; completion preserves a newer visit",
                "Delayed Cut preserves a newer private clipboard; stale Cut and prompt-time replacement are refused",
                "Trash confirmation Cancel preserves fixture source; actual Trash intentionally not invoked"]
    }

    static func operationSettled(_ browser: BrowserViewController) async throws {
        try await waitUntil("Local operation") { browser.operationPreparationTask == nil && browser.operationTask == nil }
        try await settled(browser)
    }
}
#endif
