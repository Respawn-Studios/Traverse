#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyFocusedWorkflow(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let focusedModes = context.admitted.admission.focusedModes
        let state = context.admitted.state
        let before = context.before
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            if !focusedModes.isEmpty {
                guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                    throw Failure(message: "Focused workflow fixture root is not configured")
                }
                if args.contains("--check-git") {
                    state.checks += try await WorkspaceNavigationVerification.run(in: URL(fileURLWithPath: declared),
                        gitOnly: true, gitIndexOnly: args.contains("--git-index-only")).checks
                } else if args.contains("--check-analysis") {
                    if ProcessInfo.processInfo.environment["MAC_EXPLORER_ANALYSIS_SCALE_ONLY"] == "1" {
                        state.checks += try await StorageAnalysisScaleVerification.run(coordinator: .shared, output: output)
                    } else {
                        state.checks += try await StorageAnalysisVerification.run(browser: browser, fixture: root, output: output,
                            interactive: !args.contains("--offscreen"))
                    }
                } else if args.contains("--check-address") {
                    state.checks += try await AddressCompletionVerification.run(in: URL(fileURLWithPath: declared), output: output,
                        interactive: !args.contains("--offscreen"))
                } else if args.contains("--check-drag-tracking") {
                    state.checks += try await verifyDragTrackingPreparation(browser, fixture: root, output: output, interactive: !args.contains("--offscreen"))
                } else if args.contains("--check-tabs") {
                    state.checks += try await verifyTabManagement(browser, fixture: root, output: output)
                    state.checks += try await verifyTabStripInteractions(browser, fixture: root, output: output)
                } else if args.contains("--check-queue") {
                    state.checks += try await QueueWorkflowVerification.run(in: URL(fileURLWithPath: declared), output: output)
                    state.checks += try await CopyPreviewActivationVerification.run(in: URL(fileURLWithPath: declared), output: output)
                    state.checks += try await DriveLifecycleVerification.run(in: URL(fileURLWithPath: declared))
                } else if args.contains("--check-polish") {
                    state.checks += try await verifyDailyPolish(browser, fixture: root, output: output)
                } else if args.contains("--qualify-search-index") {
                    state.checks += try await SearchIndexLiveVerification.run(receiptURL: URL(fileURLWithPath: try argument("--qualify-search-index")), output: output)
                } else if args.contains("--profile-rename") {
                    state.checks += try await RenameWorkflowVerification.profile(in: URL(fileURLWithPath: declared), output: output)
                } else {
                    state.checks += try await RenameWorkflowVerification.run(in: URL(fileURLWithPath: declared), output: output)
                }
                try requireControlledWindowsHidden("focused workflow checks")
                try require(before == (try await Task.detached { try fixtureSnapshot(root) }.value), "Focused checks changed original listing fixture")
                let gitMode = args.contains("--git-index-only") ? "git-index" : "git-review"
                let mode = args.contains("--check-git") ? gitMode : args.contains("--check-analysis") ? "storage-analysis" : args.contains("--check-address") ? "address-completion" : args.contains("--check-drag-tracking") ? "drag-tracking-regression" : args.contains("--check-queue") ? "queue-regression" : args.contains("--check-tabs") ? "tabs-regression" : args.contains("--check-polish") ? "daily-polish-regression" : args.contains("--qualify-search-index") ? "live-search-index" : args.contains("--profile-rename") ? "rename-profile" : "rename-regression"
                let report: [String: Any] = ["passed": true, "mode": mode, "checks": state.checks,
                    "notExercised": ["Owner physical pointer/keyboard delivery", "Personal-file mutation"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacySidebarMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let output = context.admitted.fixture.output
            if args.contains("--check-sidebar") {
                if args.contains("--layout-matrix") { try await verifyLayoutMatrix(browser, output: output) }
                else { try await verifySidebarLayout(browser, output: output) }
                try JSONSerialization.data(withJSONObject: ["passed": true, "mode": "sidebar-native-geometry"], options: [.prettyPrinted])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .atomic)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyPresentationMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
            if args.contains("--check-presentation") {
                try await verifyPresentation(browser, fixture: root, output: output)
                let report: [String: Any] = ["passed": true, "mode": "presentation-regression", "checks": ["Numeric zero-byte size, proportional breadcrumb, Copy Path selection, view-control/context icons, header columns and versioned preferences"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-verification.json"), options: .atomic)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyChromeMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
            if args.contains("--check-chrome") {
                try await verifyChrome(browser, fixture: root, output: output)
                let report: [String: Any] = ["passed": true, "mode": "chrome-regression", "checks": ["Translucent native chrome and centered address display/editor geometry"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacySubstantialMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
        let before = context.before
            if args.contains("--check-substantial") {
                guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(message: "Substantial fixture root is not configured") }
                let testRoot = URL(fileURLWithPath: declared, isDirectory: true)
                state.checks += try await SnapshotIntegrityVerification.run(in: testRoot)
                state.checks += try await WorkspacePersistenceVerification.run(in: testRoot)
                state.checks += try await BehaviorPinsVerification.run(in: testRoot)
                state.checks += try await BrowserShortcutVerification.run(browser, fixture: root, output: output,
                    interactive: !args.contains("--offscreen"))
                state.checks += try await InlinePreviewVerification.run(in: testRoot, renderKnownFixtures: !args.contains("--offscreen"))
                state.checks += try await WorkspaceNavigationVerification.run(in: testRoot).checks
                state.checks += try await WorkspaceTransferVerification.run(in: testRoot)
                state.checks += try await SearchFoundationVerification.run(in: testRoot)
                try requireControlledWindowsHidden("substantial workflows")
                try require(before == (try await Task.detached { try fixtureSnapshot(root) }.value), "Substantial checks changed original listing fixture")
                let offscreen = args.contains("--offscreen")
                var limits = ["Personal-file or Mac-wide index query", "New protected-folder consent", "Native preview of personal files", "WindowServer material transmission", "Physical edge drag by a human"]
                if offscreen { limits.append("Native address editing in an ordered window") }
                let report: [String: Any] = ["passed": true, "mode": offscreen ? "substantial-controlled" : "substantial-foreground",
                    "checks": state.checks, "notExercised": limits]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyWorkspaceMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
        let before = context.before
            if args.contains("--check-workspace") {
                guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                    throw Failure(message: "Workspace fixture root is not configured")
                }
                let testRoot = URL(fileURLWithPath: declared, isDirectory: true)
                try await settled(browser)
                state.checks += try await SessionVerification.run(in: testRoot)
                fputs("Workspace session checks passed.\n", stderr)
                state.checks += try await RememberedReferenceVerification.run(in: testRoot)
                state.checks.append(try FolderReopenVerification.verifyScopeRecorderRefusal(fixture: root))
                fputs("Remembered reference checks passed.\n", stderr)
                state.checks += try await verifyDirectoryRefresh(browser, in: testRoot)
                fputs("Directory refresh checks passed.\n", stderr)
                state.checks += try await verifyMaterialAreas(browser, fixture: root, output: output)
                try require(before == (try await Task.detached { try fixtureSnapshot(root) }.value), "Workspace checks changed the listing fixture")
                let report: [String: Any] = ["passed": true, "mode": "workspace-regression", "checks": state.checks,
                    "notExercised": ["Protected-folder denial/retry", "Cross-process session restore", "Changed system accessibility options", "WindowServer material transmission"]
                        + (args.contains("--offscreen") ? ["Native address-editor refresh deferral: hidden browser rejects address editing"] : [])]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyEverydayMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
        let before = context.before
            if args.contains("--check-everyday") {
                guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                    throw Failure(message: "Everyday workflow fixture root is not configured")
                }
                let offscreen = args.contains("--offscreen")
                browser.permitsBackgroundVerification = offscreen
                defer { browser.permitsBackgroundVerification = false }
                if !offscreen {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    windowController.window?.makeKeyAndOrderFront(nil)
                    try await waitUntil("Everyday workflow activation") {
                        NSApplication.shared.isActive && NSApplication.shared.keyWindow === windowController.window
                    }
                }
                try await settled(browser)
                state.checks += try IncomingFolderVerification.servicePayloads(folder: root.appendingPathComponent("Folder A"))
                state.checks += try await verifyDragDropWorkflows(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyDragDropWorkflows")
                state.checks += try await verifyOperationResults(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyOperationResults")
                state.checks += try await verifyOpenAndShareWorkflows(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyOpenAndShareWorkflows")
                state.checks += try await verifyTransferContinuation(browser, in: URL(fileURLWithPath: declared), output: output, interactive: !offscreen)
                try requireControlledWindowsHidden("verifyTransferContinuation")
                state.checks += try await verifyDestinationDropWorkflows(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyDestinationDropWorkflows")
                state.checks += try await verifyTabManagement(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyTabManagement")
                state.checks += try await verifyTabStripInteractions(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyTabStripInteractions")
                state.checks += try await verifyContentPresentationRouting(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyContentPresentationRouting")
                state.checks += try await verifyIconsInteractions(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyIconsInteractions")
                state.checks += try await verifyIconsCommands(browser, fixture: root, output: output)
                try requireControlledWindowsHidden("verifyIconsCommands")
                try requireControlledWindowsHidden("everyday workflows")
                try require(before == (try await Task.detached { try fixtureSnapshot(root) }.value), "Everyday checks changed original listing fixture")
                let report: [String: Any] = ["passed": true, "mode": offscreen ? "everyday-controlled" : "everyday-foreground",
                    "checks": state.checks, "notExercised": ["Actual Finder drag", "External application handoff", "Native sharing picker and delivery"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyOffscreenMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let windowController = context.admitted.windowController
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let metadata = context.admitted.fixture.metadata
        let requestsRecovery = context.admitted.admission.requestsRecovery
        let before = context.before
            if args.contains("--offscreen") {
                if args.contains("--qualify-trash-fixture") || requestsRecovery {
                    _ = try await InteractiveQualification.run(window: windowController.window!, fixtureRoot: root, evidenceRoot: output)
                }
                try await runOffscreen(windowController, fixture: root, metadata: metadata ?? [:], output: output, before: before)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

}
#endif
