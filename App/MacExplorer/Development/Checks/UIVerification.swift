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
