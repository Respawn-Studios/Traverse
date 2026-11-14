#if DEBUG
import AppKit
import ExplorerCore

@MainActor
extension UIVerification {
    /// Real vnode notifications and browser refresh against a new disposable
    /// directory. No protected folder, owner file, polling watcher or mock event.
    static func verifyDirectoryRefresh(_ browser: BrowserViewController, in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL,
              let window = browser.view.window else { throw Failure(message: "Directory refresh needs its owned fixture root") }
        let owned = testRoot.appendingPathComponent("browser-watch-\(UUID().uuidString)", isDirectory: true)
        let first = owned.appendingPathComponent("first", isDirectory: true)
        let second = owned.appendingPathComponent("second", isDirectory: true)
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-browser-watch-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try fm.createDirectory(at: first, withIntermediateDirectories: false)
            try fm.createDirectory(at: second, withIntermediateDirectories: false)
            for index in 0..<180 {
                try Data().write(to: first.appendingPathComponent(String(format: "kept-%03d.txt", index)), options: .withoutOverwriting)
            }
            try Data().write(to: second.appendingPathComponent("second-only.txt"), options: .withoutOverwriting)
        }.value
        let original = browser.settings.autoRefreshFolders
        let originalVerificationFocus = browser.permitsBackgroundVerification
        let originalPrompt = browser.operationNamePrompt
        var pendingPrompt: CheckedContinuation<String?, Never>?
        defer {
            pendingPrompt?.resume(returning: nil)
            browser.operationNamePrompt = originalPrompt
            browser.permitsBackgroundVerification = originalVerificationFocus
            window.makeFirstResponder(browser.table)
            browser.cancelDirectoryObservation()
            browser.settings.autoRefreshFolders = original
        }
        browser.settings.autoRefreshFolders = true
        browser.permitsBackgroundVerification = true
        window.makeFirstResponder(browser.table)
        browser.navigate(to: .directory(first))
        try await settled(browser)
        guard let observation = browser.directoryObservation, await observation.waitUntilStarted() else {
            throw Failure(message: "Real browser directory monitor did not start")
        }
        let selected = first.appendingPathComponent("kept-070.txt")
        guard let row = browser.rowsByURL[selected] else { throw Failure(message: "Watcher selection fixture missing") }
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        browser.table.scrollRowToVisible(row)
        browser.saveViewState()
        let offset = browser.currentScrollOffset
        let added = first.appendingPathComponent("kept-created.txt")
        try await Task.detached { try Data().write(to: added, options: .withoutOverwriting) }.value
        try await waitUntil("External creation auto refresh") {
            !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[added] != nil
        }
        try require(browser.selectedURLs == [selected] && abs(browser.currentScrollOffset - offset) <= 1,
                    "Automatic refresh lost stable selection or scroll position")
        let renamed = first.appendingPathComponent("kept-renamed.txt")
        try await Task.detached { try FileManager().moveItem(at: added, to: renamed) }.value
        try await waitUntil("External rename auto refresh") {
            !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[renamed] != nil && browser.rowsByURL[added] == nil
        }
        try await Task.detached { try FileManager().removeItem(at: renamed) }.value
        try await waitUntil("External deletion auto refresh") {
            !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[renamed] == nil && browser.rawEntries.count == 180
        }
        var checks = ["Real current-folder create/rename/delete notifications refresh rows and preserve stable selection/scroll"]

        let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
        let addressWasHidden = browser.pathField.isHidden
        let addressBefore = browser.pathField.stringValue
        browser.focusLocation(nil)
        let editor = browser.pathField.currentEditor() as? NSTextView
        // Hidden windows are intentionally refused by the ordinary address
        // command. Establish the editor before attributing a later loss to a
        // refresh; do not bypass that production guard in controlled checks.
        let admission: [String: Bool] = ["offscreen": offscreen, "windowVisible": window.isVisible,
            "windowKey": window.isKeyWindow, "editorAttached": editor != nil,
            "addressHidden": browser.pathField.isHidden]
        let admissionData = try JSONSerialization.data(withJSONObject: admission, options: [.prettyPrinted, .sortedKeys])
        try await Task.detached {
            try admissionData.write(to: owned.appendingPathComponent("address-editor-admission.json"), options: .withoutOverwriting)
        }.value
        if offscreen {
            try require(!window.isVisible && editor == nil && browser.pathField.isHidden == addressWasHidden
                && browser.pathField.stringValue == addressBefore,
                "Hidden browser unexpectedly admitted or changed native address editing")
        } else {
            try require(window.isVisible && editor != nil,
                "Native address editor was not admitted; refresh deferral was not exercised")
            editor?.string = "Literal unfinished address"
            browser.pathField.stringValue = "Literal unfinished address"
        }
        let editingVisit = browser.sessionID
        let deferred = first.appendingPathComponent("kept-deferred.txt")
        try await Task.detached { try Data().write(to: deferred, options: .withoutOverwriting) }.value
        if offscreen {
            try await waitUntil("External change without an address editor") {
                !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[deferred] != nil
            }
            checks.append("Hidden browser refuses address editing; real filesystem changes refresh normally without an editor. Native address-editor deferral NOT EXERCISED")
        } else {
            try await waitUntil("Deferred external change") { browser.directoryRefreshPending }
            try await Task.sleep(for: .milliseconds(350))
            try require(browser.sessionID == editingVisit && browser.pathField.stringValue == "Literal unfinished address"
                        && browser.pathField.currentEditor() === editor && browser.rowsByURL[deferred] == nil,
                        "Automatic refresh interrupted native address editing")
            window.makeFirstResponder(browser.table)
            try await waitUntil("Refresh after editing") {
                !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[deferred] != nil
            }
            checks.append("Native address editing defers filesystem refresh until editing ends")
        }

        browser.operationNamePrompt = { _, _ in
            await withCheckedContinuation { pendingPrompt = $0 }
        }
        browser.createFolder(BrowserMenus.newFolderItem(target: browser, named: true))
        try await waitUntil("Real New Folder preparation") { pendingPrompt != nil }
        let preparationVisit = browser.sessionID
        let duringPreparation = first.appendingPathComponent("kept-preparation.txt")
        try await Task.detached { try Data().write(to: duringPreparation, options: .withoutOverwriting) }.value
        try await waitUntil("Change during operation preparation") { browser.directoryRefreshPending }
        try await Task.sleep(for: .milliseconds(350))
        try require(browser.sessionID == preparationVisit && browser.operationPreparationTask != nil
                    && browser.rowsByURL[duringPreparation] == nil, "Auto refresh invalidated an operation before its prompt finished")
        pendingPrompt?.resume(returning: nil)
        pendingPrompt = nil
        try await waitUntil("Refresh after operation prompt cancellation") {
            browser.operationPreparationTask == nil && !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[duringPreparation] != nil
        }
        browser.operationNamePrompt = originalPrompt
        checks.append("Real New Folder preflight/prompt defers refresh, and cancellation releases the pending update without writing")

        browser.folderFilter.selectScope(0)
        browser.focusBrowserContent()
        browser.filterField.stringValue = "deferred"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        let filtered = first.appendingPathComponent("kept-deferred-two.txt")
        try await Task.detached { try Data().write(to: filtered, options: .withoutOverwriting) }.value
        try await waitUntil("Filtered folder auto refresh") {
            !browser.isLoading && browser.orderingTask == nil && browser.displayedEntries.count == 2
        }
        try require(browser.tabs[browser.activeIndex].filter == "deferred"
                    && browser.displayedEntries.allSatisfy { $0.name.contains("deferred") }, "Refresh discarded filename filter")
        browser.filterField.stringValue = ""
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        browser.navigate(to: .directory(second))
        try await settled(browser)
        let secondVisit = browser.sessionID
        try await Task.detached { try Data().write(to: first.appendingPathComponent("stale-first-event.txt"), options: .withoutOverwriting) }.value
        try await Task.sleep(for: .milliseconds(400))
        try require(browser.location == .directory(second) && browser.sessionID == secondVisit
                    && browser.displayedEntries.map(\.name) == ["second-only.txt"], "Stale directory event repainted the newer visit")
        checks.append("Automatic refresh retains filters and rejects events from a previous directory")

        browser.settings.autoRefreshFolders = false
        try await waitUntil("Disable observation") { browser.directoryObservation == nil }
        let manual = second.appendingPathComponent("manual-refresh.txt")
        try await Task.detached { try Data().write(to: manual, options: .withoutOverwriting) }.value
        try await Task.sleep(for: .milliseconds(350))
        try require(browser.sessionID == secondVisit && browser.rowsByURL[manual] == nil, "Disabled automatic refresh still updated rows")
        browser.refresh(nil)
        try await settled(browser)
        try require(browser.rowsByURL[manual] != nil, "Manual refresh stopped working when automatic refresh was off")
        browser.settings.autoRefreshFolders = true
        try await waitUntil("Re-enable observation") { browser.directoryObservation != nil && !browser.isLoading }
        let priorObservation = browser.directoryObservation
        browser.suspendBrowser()
        await priorObservation?.waitUntilStopped()
        try require(browser.directoryObservation == nil && browser.isBrowserSuspended, "Closed browser retained its directory observation")
        browser.resumeBrowser()
        try await settled(browser)
        try require(browser.rowsByURL[manual] != nil && browser.directoryObservation != nil && !browser.isBrowserSuspended,
                    "Reopened browser did not resume listing and observation")
        checks.append("Auto-refresh preference, manual refresh and close/reopen observation lifecycle use real files")
        return checks
    }
}
#endif
