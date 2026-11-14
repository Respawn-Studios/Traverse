#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import Search

/// Generated native fixtures only. The real index lifecycle check is explicitly
/// scoped to the owned fixture; it never issues a Mac-wide/personal-file query.
@MainActor
enum SearchFoundationVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL,
              testRoot.pathComponents.contains(".build") else {
            throw UIVerification.Failure(message: "Search verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("search-native-\(UUID().uuidString)", isDirectory: true)
        let named = owned.appendingPathComponent("nested/FILE_SENTINEL_713842-Café.txt")
        let bodyOnly = owned.appendingPathComponent("ordinary.txt")
        let literal = owned.appendingPathComponent("literal*?.txt")
        let nextFolder = owned.appendingPathComponent("next-folder", isDirectory: true)
        let openReady = owned.appendingPathComponent("open-ready.txt")
        let openReplaced = owned.appendingPathComponent("open-replaced.txt")
        let openMissing = owned.appendingPathComponent("open-missing.txt")
        let openChanged = owned.appendingPathComponent("open-changed.txt")
        let openAlias = owned.appendingPathComponent("open-alias.txt")
        let openSpecial = owned.appendingPathComponent("open-special")
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try manager.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: false)
            try manager.createDirectory(at: nextFolder, withIntermediateDirectories: false)
            try Data("mac-explorer-native-search-fixture-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try Data("Generated body\n".utf8).write(to: named, options: .withoutOverwriting)
            try Data("BODY_SENTINEL_947168\n".utf8).write(to: bodyOnly, options: .withoutOverwriting)
            try Data("Literal wildcard filename\n".utf8).write(to: literal, options: .withoutOverwriting)
            try Data("Next folder\n".utf8).write(to: nextFolder.appendingPathComponent("next.txt"), options: .withoutOverwriting)
            for index in 0..<100 {
                try Data("Generated scroll fixture\n".utf8).write(to: owned.appendingPathComponent("ordinary-scroll-\(index).txt"), options: .withoutOverwriting)
            }
            for url in [openReady, openReplaced, openMissing, openChanged] {
                try Data("Generated Open candidate\n".utf8).write(to: url, options: .withoutOverwriting)
            }
            let aliasData = try openReady.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(aliasData, to: openAlias)
            guard mkfifo(openSpecial.path, 0o600) == 0 else { throw UIVerification.Failure(message: "Could not create owned special-file Open fixture") }
        }.value

        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        let windowController = BrowserWindowController(settings: settings)
        let browser = windowController.browser
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.permitsBackgroundVerification = true
        let privatePasteboard = NSPasteboard.withUniqueName()
        browser.transferPasteboard = privatePasteboard
        var copiedURLs: [URL] = []
        var copiedText: String?
        browser.clipboardWriter = { text, urls in copiedText = text; copiedURLs = urls; return .failed }
        defer { privatePasteboard.releaseGlobally() }
        _ = browser.view
        guard let window = windowController.window else { throw UIVerification.Failure(message: "Search verification has no controlled native window") }
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        browser.tabs[browser.activeIndex].navigate(to: .directory(owned))
        browser.loadLocation()
        defer { browser.metadataSearch.cancel(restoreFolder: false); browser.suspendBrowser() }
        try await settled(browser)
        let search = browser.metadataSearch
        try require(browser.canModifyCurrentFolder, "Controlled ordinary fixture could not establish baseline command admission")
        search.show()
        search.scopePopup.selectItem(at: 0)
        search.queryField.stringValue = "FILE_SENTINEL_713842"
        try require(!search.isShowingResults && !search.hasActiveSession,
                    "Showing/typing in the search strip issued a query")
        try require(search.queryField.maximumRecents == 0 && search.queryField.recentsAutosaveName == nil
                    && search.queryField.searchMenuTemplate != nil,
                    "Search enabled query-history persistence or omitted its discoverable native scope menu")
        browser.tabs[browser.activeIndex].filter = "ordinary"
        browser.requestOrdering()
        try await settled(browser)
        browser.renderFilePresentation(selection: [bodyOnly])
        browser.view.layoutSubtreeIfNeeded()
        browser.restoreFileScrollOffset(400)
        browser.restoringScroll = false
        browser.saveViewState()
        let originalState = browser.tabs[browser.activeIndex].state
        try require(originalState.scrollOffset > 100, "Owned folder fixture did not establish a meaningful previous scroll offset")
        search.submit()
        try await finished(browser)
        try require(browser.displayedEntries.map(\.url) == [named] && search.isShowingResults,
                    "Recursive native search lost its generated nested filename or reused the loaded-name filter")
        guard let parentColumn = browser.table.tableColumns.first(where: { $0.identifier.rawValue == "searchParent" }),
              let parentCell = browser.tableView(browser.table, viewFor: parentColumn, row: 0) as? NSTableCellView else {
            throw UIVerification.Failure(message: "Search omitted its native containing-folder column")
        }
        try require(!parentColumn.isHidden && parentCell.textField?.stringValue == named.deletingLastPathComponent().path,
                    "Search containing-folder cell reported the base folder instead of the result's actual parent")
        try require(browser.status.stringValue.contains("selected exclusions") && browser.status.toolTip?.contains("hidden items excluded") == true,
                    "Search conflated its intentional hidden-file policy with an unread location")
        try require(browser.currentScrollOffset < 1, "Search inherited the ordinary folder's previous scroll position")
        try require(!browser.canModifyCurrentFolder, "Search result rows were admitted to ambiguous folder mutations")
        try require(browser.tabs[browser.activeIndex].state == originalState
                    && browser.tabs[browser.activeIndex].filter == "ordinary",
                    "Search rewrote the ordinary folder's selection or filter")
        browser.setFileSelection([named])
        browser.fileSelectionDidChange()
        try require(browser.orderedSelectedURLs == [named] && search.resultViewState.selection == [named]
                    && browser.tabs[browser.activeIndex].state == originalState,
                    "Native search selection leaked into the ordinary folder visit")
        browser.copyFileURLs(nil)
        try require(copiedURLs == [named], "Search result Copy lost its selected observed reference")
        browser.copyPath(nil)
        try require(copiedText == named.path, "Search result Copy Path used the base folder instead of the selected result")

        search.queryField.stringValue = "BODY_SENTINEL_947168"
        search.submit()
        try await finished(browser)
        try require(browser.rawEntries.isEmpty && search.coverage?.completion == .completed,
                    "Native metadata search matched generated file-body text")
        try require(browser.overlayTitle.stringValue != "This folder is empty",
                    "Search absence was presented as an empty ordinary folder")

        search.queryField.stringValue = "cafe"
        search.kindPopup.selectItem(at: 1)
        search.datePopup.selectItem(at: 2)
        search.minimumSizeField.stringValue = "1"
        search.maximumSizeField.stringValue = "128"
        search.submit()
        try await finished(browser)
        try require(browser.displayedEntries.map(\.url) == [named], "Native type/date/size or Unicode filename filters failed")
        search.kindPopup.selectItem(at: 0)
        search.datePopup.selectItem(at: 0)
        search.minimumSizeField.stringValue = ""
        search.maximumSizeField.stringValue = ""
        search.queryField.stringValue = "*?"
        search.submit()
        try await finished(browser)
        try require(browser.displayedEntries.map(\.url) == [literal], "Native filename search treated wildcard text as executable query syntax")

        search.queryField.stringValue = "open-"
        search.submit()
        try await finished(browser)
        let openCandidates = Dictionary(uniqueKeysWithValues: browser.displayedEntries.map { ($0.url, $0) })
        guard let readyEntry = openCandidates[openReady], let replacedEntry = openCandidates[openReplaced],
              let missingEntry = openCandidates[openMissing], let changedEntry = openCandidates[openChanged],
              let aliasEntry = openCandidates[openAlias], let specialEntry = openCandidates[openSpecial] else {
            throw UIVerification.Failure(message: "Native search omitted owned Open-validation candidates")
        }
        let openReader = SearchResultOpenReader()
        try require(await openReader.validate(readyEntry) == .ready, "Fresh generated search result was not eligible for observed Open")
        let aliasValidation = await openReader.validate(aliasEntry)
        let specialValidation = await openReader.validate(specialEntry)
        try require(aliasValidation == .unsupported && specialValidation == .unsupported,
                    "Search Open admitted a Finder alias or special file")
        var openCount = 0
        search.resultOpenHandler = { _ in openCount += 1 }
        browser.setFileSelection([openReady])
        browser.fileSelectionDidChange()
        browser.openSelection(nil)
        try await waitUntil { !search.isValidatingResultOpen }
        try require(openCount == 1, "Fresh search-result Open lost its active browser/selection context")
        try await Task.detached {
            let manager = FileManager()
            try manager.removeItem(at: openReplaced)
            try manager.createSymbolicLink(at: openReplaced, withDestinationURL: openReady)
            try manager.removeItem(at: openMissing)
            try Data("Generated replacement with deliberately different length\n".utf8).write(to: openChanged, options: .atomic)
        }.value
        try require(await openReader.validate(replacedEntry) == .unsupported, "Search Open followed a result replaced by a symbolic link")
        try require(await openReader.validate(missingEntry) == .missing, "Missing search result was admitted to Open")
        try require(await openReader.validate(changedEntry) == .changed, "Changed result size/mtime was admitted to Open")
        browser.setFileSelection([openReplaced])
        browser.fileSelectionDidChange()
        browser.openSelection(nil)
        try await waitUntil { !search.isValidatingResultOpen }
        try require(openCount == 1, "Stale result replacement reached the native Open handoff")

        search.cancel()
        try await settled(browser)
        try require(!search.isShowingResults && search.view.isHidden
                    && browser.status.toolTip == nil
                    && browser.tabs[browser.activeIndex].filter == "ordinary"
                    && browser.tabs[browser.activeIndex].state == originalState,
                    "Closing search did not restore the ordinary folder visit")
        var checks = [
            "Native search is explicit-submit only; recursive nested filename results reuse the active surface and reject body-only sentinels",
            "Search has separate selection/filter state, guarded read-only result mutations, private fixture Copy/Copy Path, literal Unicode/wildcard matching and visible type/date/size filters",
            "Close search restores the ordinary folder visit without persisting a query or result list"
        ]
        checks.append("Search Open revalidates metadata off-main, admits a fresh fixture through an owned hook and refuses alias/FIFO/link replacement, missing path and changed size/mtime without launching another app")

        // Execute a real MDQuery against this UUID fixture only. `.build` may be
        // Spotlight-excluded: zero indexed matches is an honest accepted outcome.
        search.show()
        search.scopePopup.selectItem(at: 1)
        search.indexedFixtureScope = try SearchScope(root: owned)
        search.queryField.stringValue = "FILE_SENTINEL_713842"
        search.submit()
        try await finished(browser, timeout: 25)
        guard let indexedCoverage = search.coverage else { throw UIVerification.Failure(message: "Fixture index query omitted terminal coverage") }
        try require(indexedCoverage.source == .spotlightIndex && indexedCoverage.requestedRoots == [owned],
                    "Native index qualification escaped its owned fixture scope")
        try require(indexedCoverage.completion == .completed || indexedCoverage.completion == .resultLimit,
                    "Fixture-only MDQuery did not finish its asynchronous gathering lifecycle")
        try require(indexedCoverage.indexedCoverageUnverified && !indexedCoverage.isComplete,
                    "Index completion was presented as complete filesystem coverage")
        try require(browser.rawEntries.allSatisfy { $0.url.path.hasPrefix(owned.path + "/") },
                    "Fixture-only index query exposed an out-of-scope path")
        checks.append("Real asynchronous MDQuery completed in the native app with an explicit owned fixture scope; \(browser.rawEntries.count) indexed matches, filesystem/index coverage remains unverified")
        search.indexedFixtureScope = nil

        search.scopePopup.selectItem(at: 0)
        search.queryField.stringValue = "FILE_SENTINEL_713842"
        search.submit()
        browser.navigate(to: .directory(nextFolder))
        try await settled(browser)
        try await Task.sleep(for: .milliseconds(100))
        try require(!search.isShowingResults && !search.hasActiveSession
                    && browser.displayedEntries.map(\.name) == ["next.txt"],
                    "Navigation allowed a cancelled search to overwrite the next folder")
        checks.append("Native navigation cancels search generation and rejects late result publication into the next folder")

        browser.navigate(to: .directory(owned))
        try await settled(browser)
        search.show()
        search.scopePopup.selectItem(at: 0)
        search.queryField.stringValue = "open-ready"
        search.submit()
        try await finished(browser)
        browser.setFileSelection([openReady])
        browser.fileSelectionDidChange()
        var validationStarted = false
        var releaseValidation = false
        search.beforeResultOpenValidation = {
            validationStarted = true
            while !releaseValidation && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        }
        browser.openSelection(nil)
        try await waitUntil { validationStarted }
        browser.navigate(to: .directory(nextFolder))
        releaseValidation = true
        search.beforeResultOpenValidation = nil
        try await settled(browser)
        try await Task.sleep(for: .milliseconds(100))
        try require(openCount == 1 && !search.isValidatingResultOpen && browser.displayedEntries.map(\.name) == ["next.txt"],
                    "A pending search Open survived stale navigation context")
        checks.append("Search Open abandons an in-flight generated validation when browser visit/navigation generation changes")

        browser.navigate(to: .directory(owned))
        try await settled(browser)
        search.show()
        search.scopePopup.selectItem(at: 0)
        search.queryField.stringValue = "open-ready"
        search.submit()
        try await finished(browser)
        browser.setFileSelection([openReady])
        browser.fileSelectionDidChange()
        let focusVisit = browser.sessionID
        let focusTab = browser.activeID
        var focusValidationStarted = false
        var focusBarrier: CheckedContinuation<Void, Never>?
        defer { focusBarrier?.resume(); focusBarrier = nil; search.beforeResultOpenValidation = nil }
        search.beforeResultOpenValidation = {
            focusValidationStarted = true
            // Deliberately retain this controlled barrier after cancellation,
            // representing a worker that returns only after focus is readmitted.
            await withCheckedContinuation { focusBarrier = $0 }
        }
        browser.openSelection(nil)
        try await waitUntil { focusValidationStarted }
        windowController.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        try require(browser.hasFileCommandFocus && browser.isActiveCommandPane && browser.sessionID == focusVisit
                    && browser.activeID == focusTab && browser.orderedSelectedURLs == [openReady],
                    "Controlled focus return did not retain the intended unchanged browser context")
        focusBarrier?.resume()
        focusBarrier = nil
        search.beforeResultOpenValidation = nil
        try await Task.sleep(for: .milliseconds(100))
        try require(openCount == 1 && !search.isValidatingResultOpen && search.isShowingResults,
                    "A pending search Open regained authority after key-window focus returned")
        browser.openSelection(nil)
        try await waitUntil { !search.isValidatingResultOpen }
        try require(openCount == 2, "Focus loss permanently disabled a fresh explicit search Open")
        checks.append("Controlled real window-controller resignation invalidates delayed search Open even with unchanged visit/selection and readmitted command focus; a fresh explicit Open still succeeds")
        let duplicate = nextFolder.appendingPathComponent(named.lastPathComponent)
        try await Task.detached { try Data("Generated duplicate filename\n".utf8).write(to: duplicate, options: .withoutOverwriting) }.value
        search.queryField.stringValue = "FILE_SENTINEL_713842"
        search.submit(); try await finished(browser)
        try require(Set(browser.displayedEntries.map(\.url)) == [named, duplicate], "Duplicate-name search lost one parent location")
        for row in browser.displayedEntries.indices {
            let cell = browser.tableView(browser.table, viewFor: parentColumn, row: row) as? NSTableCellView
            try require(cell?.textField?.stringValue == browser.displayedEntries[row].url.deletingLastPathComponent().path,
                        "Duplicate result displayed another item's parent")
        }
        browser.setFileSelection([duplicate]); browser.fileSelectionDidChange()
        try require(browser.commandEnabled(#selector(BrowserViewController.openContainingFolder(_:))), "Search omitted Open Containing Folder admission")
        browser.openContainingFolder(nil); try await settled(browser)
        try require(!search.isShowingResults && browser.location.directoryURL == nextFolder && parentColumn.isHidden
            && browser.selectedURLs == [duplicate], "Open Containing Folder did not return to ordinary browsing and select the result")
        checks.append("Duplicate filenames expose their distinct parent folders; Open Containing Folder performs fresh normal browsing, selects the result and hides the search-only column")
        return checks
    }

    private static func finished(_ browser: BrowserViewController, timeout: TimeInterval = 10) async throws {
        try await waitUntil(timeout: timeout) {
            !browser.isLoading && browser.orderingTask == nil && browser.metadataSearch.coverage != nil
        }
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        try await waitUntil { !browser.isLoading && browser.orderingTask == nil }
    }
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: "Native search fixture did not settle before its deadline")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw UIVerification.Failure(message: message) }
    }
}
#endif
