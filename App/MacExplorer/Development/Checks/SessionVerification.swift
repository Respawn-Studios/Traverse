#if DEBUG
import AppKit
import ExplorerCore
import Darwin

/// Real isolated store/startup checks, no fake security lease and no protected
/// folder chooser. All mutation belongs to a new marked disposable fixture.
@MainActor
enum SessionVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Session verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("workspace-session-\(UUID().uuidString)", isDirectory: true)
        let state = owned.appendingPathComponent("state", isDirectory: true)
        let directory = owned.appendingPathComponent("listing", isDirectory: true)
        let selected = directory.appendingPathComponent("kept.txt")
        let untouched = state.appendingPathComponent("folder-access-bookmarks-v1.json")
        try await Task.detached {
            try FileManager().createDirectory(at: owned, withIntermediateDirectories: true)
            try Data("mac-explorer-session-verification-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try FileManager().createDirectory(at: state, withIntermediateDirectories: false)
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
            try Data().write(to: selected, options: .withoutOverwriting)
            try Data().write(to: directory.appendingPathComponent("other.txt"), options: .withoutOverwriting)
            try Data("unrelated-app-bookmark-state-sentinel".utf8).write(to: untouched, options: .withoutOverwriting)
        }.value
        var checks: [String] = []
        let controller = BrowserSessionController(stateDirectory: state)
        _ = await controller.restore(enabled: true)
        let oldTab = BrowserTab(location: .computer)
        var latest = BrowserTab(location: .directory(directory))
        latest.filter = "kept"
        latest.sort = DirectorySort(field: .size, ascending: false)
        latest.state = NavigationState(selection: [selected], scrollOffset: 0)
        let snapshot = try WorkspaceSession.capture([latest, oldTab], activeID: latest.id)
        for _ in 0..<100 { controller.record(try WorkspaceSession.capture([oldTab], activeID: oldTab.id)) }
        controller.record(snapshot)
        try require(await controller.flush() == nil, "Session writes failed")
        let freshController = BrowserSessionController(stateDirectory: state)
        let privateMode = try await Task.detached {
            (try FileManager().attributesOfItem(atPath: state.appendingPathComponent("browser-session-v1.json").path)[.posixPermissions] as? NSNumber)?.intValue
        }.value
        try require(privateMode == 0o600, "Saved session must have private file permissions")
        if case .restored(let restored) = await freshController.restore(enabled: true) {
            try require(restored == snapshot, "A stale queued session overwrote the latest one")
        } else { throw UIVerification.Failure(message: "Real session store did not restore") }
        checks.append("Real versioned session store restores latest queued snapshot with independent tab state")

        controller.record(snapshot)
        controller.setEnabled(false)
        controller.record(snapshot)
        try require(await controller.flush() == nil, "Disable failed to drain its session removal")
        let file = state.appendingPathComponent("browser-session-v1.json")
        let preserved = try await Task.detached {
            let absent = !FileManager().fileExists(atPath: file.path)
            let sentinel = try Data(contentsOf: untouched)
            return absent && sentinel == Data("unrelated-app-bookmark-state-sentinel".utf8)
        }.value
        try require(preserved, "Disable recreated session data or touched unrelated app state")
        checks.append("Disable drains stale writes and forgets only its exact session file")

        controller.setEnabled(true)
        controller.record(snapshot)
        _ = await controller.flush()
        let settings = BrowserSettings(persist: false)
        try require(settings.restoresSession && settings.startupMode == .lastSession, "New profiles should reopen their last session")
        settings.restoresSession = true
        let browser = BrowserViewController(settings: settings)
        browser.sessionPersistence = BrowserSessionController(stateDirectory: state)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = browser
        defer {
            browser.suspendBrowser()
            browser.listingTask?.cancel()
            browser.orderingTask?.cancel()
            browser.sidebarTasks.forEach { $0.cancel() }
            window.close()
        }
        browser.begin()
        let deadline = Date().addingTimeInterval(12)
        while !(browser.sessionPersistence.isReady && browser.location == .directory(directory)
                && !browser.isLoading && browser.orderingTask == nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(browser.location == .directory(directory) && !browser.isLoading && browser.loadError == nil,
                    "Real browser begin did not restore and list the isolated location")
        try require(browser.tabs.count == 2 && browser.tabs[browser.activeIndex].filter == "kept"
                    && browser.tabs[browser.activeIndex].sort.field == .size && !browser.tabs[browser.activeIndex].sort.ascending,
                    "Real browser startup lost tab/filter/sort state")
        try require(browser.displayedEntries.count == 1 && browser.selectedURLs == [selected],
                    "Real browser startup did not restore meaningful selection")
        try require(browser.rememberedFolders.isEmpty, "Session restoration fabricated remembered access grants")
        _ = await browser.sessionPersistence.flush()
        checks.append("Actual browser begin restores isolated tabs/filter/sort/selection and real metadata without a manual access lease")

        let missingState = owned.appendingPathComponent("missing-state", isDirectory: true)
        let missingDirectory = owned.appendingPathComponent("missing-location", isDirectory: true)
        let missingTab = BrowserTab(location: .directory(missingDirectory))
        let missingStore = BrowserSessionController(stateDirectory: missingState)
        _ = await missingStore.restore(enabled: true)
        missingStore.record(try WorkspaceSession.capture([missingTab], activeID: missingTab.id))
        _ = await missingStore.flush()
        let missingSettings = BrowserSettings(persist: false)
        missingSettings.restoresSession = true
        let missingBrowser = BrowserViewController(settings: missingSettings)
        missingBrowser.sessionPersistence = BrowserSessionController(stateDirectory: missingState)
        missingBrowser.folderAccess = FolderAccessController(stateDirectory: nil)
        let missingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        missingWindow.isReleasedWhenClosed = false
        missingWindow.isRestorable = false
        missingWindow.contentViewController = missingBrowser
        defer {
            missingBrowser.suspendBrowser()
            missingBrowser.listingTask?.cancel()
            missingBrowser.orderingTask?.cancel()
            missingBrowser.sidebarTasks.forEach { $0.cancel() }
            missingWindow.close()
        }
        missingBrowser.begin()
        let missingDeadline = Date().addingTimeInterval(12)
        while (missingBrowser.location != .directory(missingDirectory) || missingBrowser.isLoading || missingBrowser.accessDiagnostic == nil) && Date() < missingDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(missingBrowser.location == .directory(missingDirectory) && missingBrowser.accessDiagnostic?.kind == .missing,
                    "Restored missing locations must remain honest missing states")
        checks.append("Actual startup keeps a missing restored location and reports missing rather than replacing it silently")

        let corrupt = Data("unrecognized-data-preserve".utf8)
        try await Task.detached { try corrupt.write(to: file, options: .atomic) }.value
        let invalid = BrowserSessionController(stateDirectory: state)
        if case .unavailable = await invalid.restore(enabled: true) {} else {
            throw UIVerification.Failure(message: "Corrupt session was not reported unavailable")
        }
        invalid.record(snapshot)
        _ = await invalid.flush()
        invalid.setEnabled(false)
        _ = await invalid.flush()
        try require(try await Task.detached { try Data(contentsOf: file) == corrupt }.value,
                    "Corrupt or unrecognized session data was silently replaced")
        checks.append("Corrupt session is reported and preserved instead of overwriting unknown data")
        let fifoState = owned.appendingPathComponent("fifo-state", isDirectory: true)
        let fifo = fifoState.appendingPathComponent("browser-session-v1.json")
        try await Task.detached {
            try FileManager().createDirectory(at: fifoState, withIntermediateDirectories: false)
            guard fifo.withUnsafeFileSystemRepresentation({ mkfifo($0!, 0o600) }) == 0 else {
                throw UIVerification.Failure(message: "Could not prepare the owned non-regular session fixture")
            }
        }.value
        let nonregular = BrowserSessionController(stateDirectory: fifoState)
        if case .unavailable = await nonregular.restore(enabled: true) {} else {
            throw UIVerification.Failure(message: "Non-regular session storage was accepted")
        }
        let fifoPreserved = await Task.detached {
            var value = stat()
            return fifo.withUnsafeFileSystemRepresentation { lstat($0!, &value) == 0 && value.st_mode & S_IFMT == S_IFIFO }
        }.value
        try require(fifoPreserved, "Rejected non-regular session data was removed or replaced")
        checks.append("Non-regular session input is refused without blocking on a FIFO or changing its occupant")
        return checks
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw UIVerification.Failure(message: message) }
    }
}
#endif
