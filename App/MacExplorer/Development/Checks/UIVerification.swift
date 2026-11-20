import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
@_spi(ApplicationOwnership) import StorageAnalysis

#if DEBUG
/// Development-only verification uses generated fixtures, in-memory preferences,
/// and an injected clipboard writer. It never captures another application's UI.
@MainActor
enum UIVerification {
    struct Failure: Error { let message: String }
    private static var captureBytesWritten = 0
    private static var rowEventNumber = 1_000_000
    @MainActor private final class ClickReceipt { var received = false }

    /// Populate an already-owned Git fixture. The generated repository runs
    /// with no user configuration, template hooks or network transport.
    nonisolated static func generateGit(in root: URL, _ arguments: [String], expectedStatus: Int32 = 0) throws {
        var project = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { project.deleteLastPathComponent() }
        guard root.path.hasPrefix(project.appendingPathComponent(".build").path + "/"),
              root.path == root.standardizedFileURL.path, root.resolvingSymlinksInPath().path == root.path else {
            throw Failure(message: "A generated Git fixture must be under this repository’s build directory")
        }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        tool.currentDirectoryURL = root
        tool.arguments = ["-c", "user.name=Generated", "-c", "user.email=fixture@example.invalid",
                          "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "gc.auto=0"] + arguments
        tool.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "GIT_CONFIG_GLOBAL": "/dev/null",
                            "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0"]
        tool.standardInput = FileHandle.nullDevice
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationReason == .exit, tool.terminationStatus == expectedStatus else {
            throw Failure(message: "Could not build the generated Git fixture")
        }
    }

    static func nativeTables(in root: NSView?) -> [NSTableView] {
        guard let root else { return [] }
        if let table = root as? NSTableView { return [table] }
        return root.subviews.flatMap { nativeTables(in: $0) }
    }

    static func menuItem(_ path: String...) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for name in path {
            item = menu?.item(withTitle: name)
            menu = item?.submenu
        }
        return item
    }

    static func completeNameSelection(in parent: NSWindow, text: String, mode: NameSelectionPrompt.Mode,
                                      cancel: Bool = false) async throws {
        try await waitUntil("Select by Name attached sheet") { parent.attachedSheet?.firstResponder is NSTextView }
        guard let sheet = parent.attachedSheet, let editor = sheet.firstResponder as? NSTextView,
              let content = sheet.contentView else { throw Failure(message: "Select by Name did not focus its native field") }
        let controls = WorkspaceNetworkVerification.descendants(content)
        guard let modeControl = controls.compactMap({ $0 as? NSPopUpButton }).first,
              let apply = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply" }),
              let dismiss = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) else {
            throw Failure(message: "Select by Name controls are unavailable")
        }
        try require(!apply.isEnabled, "An empty pattern enabled Apply")
        modeControl.selectItem(at: mode.rawValue)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try require(apply.isEnabled, "Ordinary native input did not enable Apply")
        if cancel { dismiss.performClick(nil) }
        else { sheet.sendEvent(key("\r", code: 36, flags: [], window: sheet)) }
    }

    /// Own-process native event dispatch, with no global pointer injection.
    /// Posting the complete pair keeps AppKit's current-event/tracking state
    /// coherent; direct mouseDown plus a queued mouseUp does not establish it.
    static func clickRow(_ row: Int, in table: NSTableView, modifiers: NSEvent.ModifierFlags = []) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--verify-ui"),
              row >= 0, row < table.numberOfRows, let window = table.window, window.isVisible else {
            throw Failure(message: "Native row click requires its visible generated window")
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let focusDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !NSApp.isActive || !window.isKeyWindow {
            try require(window.isVisible && ProcessInfo.processInfo.systemUptime < focusDeadline,
                "Generated row window could not acquire native focus")
            try await Task.sleep(for: .milliseconds(5))
        }
        table.scrollRowToVisible(row); window.contentView?.layoutSubtreeIfNeeded()
        let local = NSPoint(x: min(80, table.bounds.midX), y: table.rect(ofRow: row).midY)
        try require(table.row(at: local) == row && table.visibleRect.contains(local), "Generated row is outside its native viewport")
        let point = table.convert(local, to: nil), number = window.windowNumber
        rowEventNumber += 2
        let downNumber = rowEventNumber, upNumber = rowEventNumber + 1
        let receipt = ClickReceipt()
        // Tracking controls may consume mouseUp inside mouseDown. A queued
        // private barrier is observed after both events return to the app loop.
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined, handler: { event in
            guard event.windowNumber == number && event.subtype.rawValue == 0x5452
                && event.data1 == upNumber else { return event }
            MainActor.assumeIsolated {
                receipt.received = true
            }
            return nil
        }) else { throw Failure(message: "Generated row click could not establish its native receipt") }
        defer { NSEvent.removeMonitor(monitor) }
        func event(_ type: NSEvent.EventType, _ eventNumber: Int) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: 1) else {
                throw Failure(message: "Generated row click event unavailable")
            }
            return event
        }
        let down = try event(.leftMouseDown, downNumber), up = try event(.leftMouseUp, upNumber)
        guard let barrier = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil,
            subtype: 0x5452, data1: upNumber, data2: 0) else {
            throw Failure(message: "Generated row click barrier unavailable")
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        NSApp.postEvent(barrier, atStart: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !receipt.received {
            try require(window.isVisible && ProcessInfo.processInfo.systemUptime < deadline,
                "Generated row click did not finish native dispatch")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Explicit legacy scan checks use an existing generated review profile,
    /// never the ordinary app's shared user cache or an unindexed pool.
    static func isolatedAnalysisStorage() async throws -> AnalysisResultStorage {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let owned = repo.appendingPathComponent(".build").path + "/"
        guard let layout = AppStorageLocations.layout,
              layout.analysisDirectory.path.hasPrefix(owned), layout.stateDirectory.path.hasPrefix(owned) else {
            throw Failure(message: "This scan check requires its generated repository review profile")
        }
        try await AppStoragePreparation.owner(for: layout.stateDirectory).prepare()
        let storage = try AnalysisResultStorage(directory: layout.analysisDirectory,
            retentionStateDirectory: layout.stateDirectory.appendingPathComponent("retained-analysis", isDirectory: true))
        try await RecordedAnalysisOwner.prepareSharedPoolForExplicitAnalysis(storage: storage,
            activityGate: ApplicationFileActivity.gate)
        return storage
    }

    #if TRAVERSE_NETWORK_QUALIFICATION
    static func run(windowController: BrowserWindowController) async {
        // Focused network controls are dispatched explicitly by AppDelegate.
        // This binary cannot qualify any of the omitted legacy workflows.
        FileHandle.standardError.write(Data("Legacy UI workflow is unavailable in the focused network qualification build\n".utf8))
        Darwin.exit(78)
    }
    #else
    static func run(windowController: BrowserWindowController) async {
        let browser = windowController.browser
        let state = UILegacyRunState()
        do {
            let args = ProcessInfo.processInfo.arguments
            if try await legacyTesterRepairs(windowController: windowController, args: args) { return }
            let admission = try legacyValidateModes(args)
            if try await runFocusedGroup1(windowController: windowController, args: args) { return }
            if try await runFocusedGroup2(windowController: windowController, args: args) { return }
            if try await runFocusedGroup3(windowController: windowController, args: args, state: state) { return }
            let fixture = try await legacyPrepareFixture(args: args, admission: admission)
            let root = fixture.root, output = fixture.output
            state.evidence = output
            try requireControlledWindowsHidden("startup")
            let admitted = UILegacyAdmittedContext(windowController: windowController, args: args,
                admission: admission, fixture: fixture, state: state)
            if try await legacyDriveMode(admitted) { return }
            try legacyControlledReopen(args: args)
            if try await legacyResponsivenessMode(admitted) { return }
            if try await legacyQueueMode(admitted) { return }
            if try await legacyRecoveryMode(admitted) { return }
            try require(!args.contains(where: { $0.hasPrefix("--grouped-") }),
                        "Copied-file fixture arguments require --verify-grouped-recovery")
            let before = try await Task.detached { try fixtureSnapshot(root) }.value
            let clipboard = UILegacyClipboardCapture()
            let privatePasteboard = NSPasteboard.withUniqueName()
            defer { privatePasteboard.releaseGlobally() }
            browser.transferPasteboard = privatePasteboard
            browser.clipboardWriter = { text, urls in
                clipboard.text = text
                clipboard.urls = urls
                return BrowserClipboard.publish(text, urls: urls, to: privatePasteboard)
            }
            let context = UILegacyWorkflowContext(admitted: admitted, before: before,
                clipboard: clipboard, privatePasteboard: privatePasteboard)
            if try await legacyFocusedWorkflow(context) { return }
            if try await legacySidebarMode(context) { return }
            if try await legacyPresentationMode(context) { return }
            if try await legacyChromeMode(context) { return }
            if try await legacySubstantialMode(context) { return }
            if try await legacyWorkspaceMode(context) { return }
            if try await legacyEverydayMode(context) { return }
            if try await legacyOffscreenMode(context) { return }
            try await legacyForegroundActivation(context)
            if try await legacyPermissionRetryMode(context) { return }
            if try await legacyFolderReopenMode(context) { return }
            try await legacyGlassReview(context)
            let plainCount = try await legacyForegroundListing(context)
            try await legacyForegroundFilter(context)
            try await legacyForegroundPartialRows(context)
            try await legacyForegroundTabs(context)
            try await legacyForegroundPathAndSidebar(context, plainCount: plainCount)
            try await legacyForegroundSettings(context)
            try await legacyForegroundCapabilities(context)
            try await legacyForegroundReport(context, plainCount: plainCount)
            return
        } catch {
            await legacyFailure(error, browser: browser, state: state)
            return
        }
    }

    #endif
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }


    static func settled(_ browser: BrowserViewController) async throws {
        try await waitUntil("Directory session") { !browser.isLoading && browser.orderingTask == nil }
        browser.view.layoutSubtreeIfNeeded()
    }

    static func verifyDiffSearch(in review: NSWindow, workspace: BrowserWorkspaceController,
                                          query: String, expectedPath: String, files: Int,
                                 expectedSide: EditorComparisonPlan.Side = .current) async throws {
        try await waitUntil("Review owns Find Across Diffs") {
            review.isKeyWindow && menuItem("View", "Find Across Diffs…")?.target === review.windowController
        }
        let chord = key("F", code: 3, flags: [.command, .shift], window: review)
        try require(NSApp.mainMenu?.performKeyEquivalent(with: chord) == true,
            "Review did not route Find Across Diffs")
        try await waitUntil("The review opens the comparison with its exact file list") {
            workspace.textComparisonWindow?.window?.isKeyWindow == true && workspace.textComparisonWindow?.fileCount == files
                && workspace.textComparisonWindow?.preparing == false
        }
        guard let diff = workspace.textComparisonWindow, let window = diff.window else {
            throw Failure(message: "Missing Diff search window")
        }
        try require(diff.diffSearch.visible, "Git opened a comparison without its requested search")
        try await waitUntil("The prepared diff search owns its native field editor") {
            guard let view = window.contentView, let field = WorkspaceNetworkVerification.descendants(view).compactMap({ $0 as? NSSearchField })
                .first(where: { $0.identifier?.rawValue == "diff-search-query" }), let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor && field.isEnabled
        }
        for letter in query { window.sendEvent(key(String(letter), code: 0, flags: [], window: window)) }
        try await waitUntil("The typed Diff query reached the native field") { diff.diffSearch.query == query }
        window.sendEvent(key("\r", code: 36, flags: [], window: window))
        try await waitUntil("The search returns one exact match across the visible pairs") {
            diff.diffSearch.report?.checked == files && diff.diffSearch.report?.hits.count == 1
                && diff.diffSearch.selectedHit?.name == expectedPath && diff.diffSearch.selectedHit?.side == expectedSide
        }
        window.sendEvent(key("\r", code: 36, flags: [], window: window))
        try await waitUntil("Diff search opens the precise selection") {
            let text = expectedSide == .before ? diff.beforeSurface.textView : diff.currentSurface.textView
            guard !diff.preparing, diff.labels.source == expectedPath, window.firstResponder === text else { return false }
            let source = text.string as NSString
            let selection = text.selectedRange()
            return selection.location != NSNotFound && NSMaxRange(selection) <= source.length && source.substring(with: selection) == query
        }
        await diff.closeAndDrain()
        review.makeKeyAndOrderFront(nil)
    }

    static func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline { throw Failure(message: "Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    static func select(_ name: String, in browser: BrowserViewController) throws {
        guard let row = browser.displayedEntries.firstIndex(where: { $0.name == name }) else { throw Failure(message: "Fixture item missing: \(name)") }
        browser.setFileSelection([browser.displayedEntries[row].url])
        browser.fileSelectionDidChange()
    }

    static func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                         isARepeat: false, keyCode: code)!
    }

    static func snapshot(_ window: NSWindow, to url: URL) async throws {
        try await Task.sleep(for: .milliseconds(160))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView, let capture = content.superview ?? window.contentView,
              let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { throw Failure(message: "Unable to render native window") }
        capture.effectiveAppearance.performAsCurrentDrawingAppearance {
            capture.cacheDisplay(in: capture.bounds, to: bitmap)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Unable to encode native render") }
        if let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET"] {
            guard let budget = Int(text), (16_384...(4 << 20)).contains(budget),
                  data.count <= budget - captureBytesWritten else {
                throw Failure(message: "Native capture refused before writing: packet capture budget exhausted")
            }
        }
        // Reserve before suspending so concurrent snapshots share one ceiling.
        captureBytesWritten += data.count
        do { try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value }
        catch { captureBytesWritten -= data.count; throw error }
    }

    static func requireControlledWindowsHidden(_ stage: String) throws {
        guard ProcessInfo.processInfo.arguments.contains("--offscreen") else { return }
        let visible = NSApplication.shared.windows.filter(\.isVisible)
        let descriptions = visible.map { "\(type(of: $0)) [\($0.title)]" }.joined(separator: "; ")
        try require(visible.isEmpty,
                    "Controlled verification ordered a window on screen at \(stage): \(descriptions)")
    }

    nonisolated static func fixtureSnapshot(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw Failure(message: "Unable to inspect owned fixture")
        }
        var result: [String: String] = [:]
        let urls = [root] + enumerator.compactMap { $0 as? URL }
        for url in urls {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &info) } ?? -1 }) == 0 else {
                throw Failure(message: "Unable to inspect fixture metadata")
            }
            result[url.path] = "\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }
        return result
    }
}
#endif
