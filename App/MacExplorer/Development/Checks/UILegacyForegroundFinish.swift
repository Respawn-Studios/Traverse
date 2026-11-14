#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyForegroundSettings(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
            browser.navigate(to: .directory(root))
            try await settled(browser)
            browser.settings.showsCommandRow = false
            try require(windowController.window?.toolbar?.isVisible == false, "Header-menu preference did not hide")
            browser.settings.showsCommandRow = true
            browser.showSettings(nil)
            try await Task.sleep(for: .milliseconds(180))
            try await snapshot(browser.settingsWindow!, to: output.appendingPathComponent("04-settings.png"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            browser.settingsWindow?.makeKeyAndOrderFront(nil)
            try await waitUntil("Settings keyboard focus") { NSApplication.shared.keyWindow === browser.settingsWindow }
            try require(!browser.canModifyCurrentFolder, "Settings focus left browser file mutations enabled")
            let tabCount = browser.tabs.count
            try require(NSApplication.shared.mainMenu?.performKeyEquivalent(with: key("w", code: 13, flags: .command, window: browser.settingsWindow!)) == true,
                        "Settings close shortcut was not handled")
            try require(browser.tabs.count == tabCount, "Command-W in Settings changed browser tabs")
            try await waitUntil("Settings close animation") { browser.settingsWindow?.isVisible == false }
            windowController.window?.makeKeyAndOrderFront(nil)
            windowController.window?.setContentSize(NSSize(width: 820, height: 520))
            try await snapshot(windowController.window!, to: output.appendingPathComponent("05-compact.png"))
            try require(browser.view.bounds.width <= 821 && browser.folderScroll.contentView.bounds.height > 200,
                        "Browser did not fit the compact window")
            try await verifyExplorerFlows(browser, fixture: root, output: output)
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            windowController.window?.setContentSize(NSSize(width: 1140, height: 760))
            try await snapshot(windowController.window!, to: output.appendingPathComponent("06-dark.png"))
            state.checks.append("Settings, header-menu preference, compact and dark native renders")
            state.checks.append("Click-to-edit and breadcrumb navigation, context selection/copy, Backspace/parent, numbered tabs, F6 focus and overflow resize/close")
            try require(browser.table.accessibilityLabel() != nil && browser.outline.accessibilityLabel() != nil, "Browser controls missing accessibility labels")
            state.checks.append("Basic accessibility labels (VoiceOver not exercised)")
    }

    static func legacyForegroundCapabilities(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
            try await verifyProperties(browser, fixture: root, output: output)
            state.checks.append("Bounded shallow Properties: unavailable coverage, broken links, cancellation, stale results, copy and Light/Dark")
            state.checks += try await verifyPreferences(browser, fixture: root, output: output)
            guard let testPath = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                throw Failure(message: "Disposable capability root was not configured")
            }
            let testRoot = URL(fileURLWithPath: testPath, isDirectory: true)
            state.checks += try await AccessVerification.run(in: testRoot)
            state.checks += try await verifyOperations(browser, in: testRoot, output: output)
            state.checks += try await verifyFinderWorkflows(browser, fixture: root, output: output, interactive: true)
            state.checks += try await verifyRecoveryWorkflows(browser, in: testRoot, output: output, interactive: true)
            state.checks += try await verifyOperationMaturity(browser, in: testRoot, output: output, interactive: true)
            state.checks += try await verifyOperationResults(browser, fixture: root, output: output)
            state.checks += try await verifyOpenAndShareWorkflows(browser, fixture: root, output: output)
            state.checks += try await verifyTransferContinuation(browser, in: testRoot, output: output, interactive: true)
            state.checks += try await verifyDragDropWorkflows(browser, fixture: root, output: output)
            state.checks += try await verifyDestinationDropWorkflows(browser, fixture: root, output: output)
            state.checks += try await verifyTabManagement(browser, fixture: root, output: output)
            state.checks += try await verifyTabStripInteractions(browser, fixture: root, output: output)
            state.checks += try await verifyContentPresentationRouting(browser, fixture: root, output: output)
            state.checks += try await verifyIconsInteractions(browser, fixture: root, output: output)
            state.checks += try await verifyIconsCommands(browser, fixture: root, output: output)
            try await verifyPresentation(browser, fixture: root, output: output)
            state.checks.append("Numeric size, proportional breadcrumb, Copy Path selection, view icons and header-column choices")
    }

    static func legacyForegroundReport(_ context: UILegacyWorkflowContext, plainCount: Int) async throws {
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
        let before = context.before
            let after = try await Task.detached { try fixtureSnapshot(root) }.value
            try require(before == after, "Fixture metadata changed during browsing")
            state.checks.append("Fixture structure, sizes, modes and modification times unchanged")
            let interactiveURL = output.appendingPathComponent("interactive-qualification.json")
            let interactive = (try? Data(contentsOf: interactiveURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var notExercised = ["VoiceOver", "Inter-application copy/paste", "Disconnected network mount", "Minimum macOS runtime", "Cloud placeholders", "Release signing/notarization", "System Reduce Transparency/Increase Contrast changes"]
            notExercised += ["Physical native drag and actual Finder interoperation", "Actual external application handoff", "Native sharing picker and recipient delivery"]
            if ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] != "1" {
                notExercised.append("Real cross-volume operations in the native UI")
            }
            if (interactive?["permissions"] as? [String: Any])?["humanPromptObservation"] as? String == "human-reported-allow" {
                notExercised.append("Downloads denial, other protected folders and consent retention across rebuilds")
            } else { notExercised.append("Protected-folder permission prompts and consent retention across rebuilds") }
            if (interactive?["trash"] as? [String: Any])?["status"] as? String != "trash-and-no-replace-restore-qualified" {
                notExercised.append("Actual system Trash")
            }
            if (interactive?["folderAccess"] as? [String: Any])?["status"] as? String != "human-selection-remember-restore-forget-observed" {
                notExercised.append("Human folder-picker bookmark save/restore/forget")
            }
            if !args.contains("--qualify-glass") { notExercised.append("Compositor glass") }
            var report: [String: Any] = [
                "passed": true, "checks": state.checks, "measurements": state.measurements,
                "captureMethod": args.contains("--qualify-glass")
                    ? "App view renders plus exact owned-window compositor glass captures; excludes desktop and other apps"
                    : "Native app view cacheDisplay; excludes desktop and other apps; compositor glass not captured",
                "clipboard": "Injected writer and private native pasteboard for file Copy/Cut/Paste; system clipboard untouched",
                "preferences": "In memory; user preferences untouched",
                "notExercised": notExercised,
            ]
            if let interactive { report["interactiveQualification"] = interactive }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-verification.json"), options: .atomic)
            print("Native UI verification passed: \(state.checks.count) checks; \(plainCount) generated plain files.")
            NSApplication.shared.terminate(nil)
            return
    }

}
#endif
