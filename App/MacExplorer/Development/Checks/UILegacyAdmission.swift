#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyTesterRepairs(windowController: BrowserWindowController, args: [String]) async throws -> Bool {
        let browser = windowController.browser
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            if args.contains("--check-tester-repairs") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report: [String: Any]
                if args.contains("--motion-mode") {
                    report = try await ToolWindowVerification.browserMotion(root: root, browser: browser)
                } else if args.contains("--connect-layout") {
                    report = try await ToolWindowVerification.connectLayout(root: root, browser: browser)
                } else if args.contains("--project-composition") {
                    report = try await ProjectCompositionVerification.run(root: root)
                } else if args.contains("--chart-finish") {
                    report = try await ToolWindowVerification.chartFinish(root: root, browser: browser)
                } else if args.contains("--interface-sizing") {
                    try InterfaceSizingVerification.admit(root)
                    report = try await InterfaceSizingVerification.run(browser: browser, root: root)
                } else if args.contains("--update-resume") {
                    try InterfaceSizingVerification.admit(root)
                    report = try await UpdateWorkspaceResumeVerification.run(root: root, browser: browser)
                } else { report = try await ToolWindowVerification.testerRepairs(root: root, browser: browser) }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
        return false
    }

    static func legacyValidateModes(_ args: [String]) throws -> UILegacyAdmission {
            let focusedModes = ["--show-chart-integration-review", "--check-chart-integration", "--check-classification-v3", "--show-dimensional-review", "--check-dimensional-chart", "--check-startup-prefix", "--check-analysis-prefix", "--check-analysis-chart", "--check-analysis-paged", "--check-analysis-ram", "--check-analysis", "--check-git", "--check-address", "--check-tabs", "--check-rename", "--profile-rename", "--check-polish", "--qualify-search-index", "--check-queue", "--check-drag-tracking", "--verify-grouped-recovery", "--verify-grouped-copy-queue", "--verify-grouped-copy-responsiveness"].filter(args.contains)
            try require(!args.contains("--git-index-only") || focusedModes == ["--check-git"], "Git index checks require the generated Git route")
            let allFocusedModes = focusedModes + ["--check-chart-keyboard", "--check-workspace-analysis", "--check-app-accounting", "--show-app-accounting-review", "--check-sorted-pages", "--check-chart-lifecycle", "--check-location-actions", "--check-first-use", "--check-summary-hover", "--check-browser-regressions", "--show-browser-repair-review", "--qualify-address-directory-hint", "--check-classification-audit"].filter(args.contains)
            if !allFocusedModes.isEmpty {
                let otherModes = ["--check-substantial", "--check-sidebar", "--check-everyday", "--check-workspace", "--check-chrome", "--check-presentation", "--layout-matrix", "--qualify-permissions", "--qualify-permission-retry", "--qualify-folder-access", "--qualify-trash", "--qualify-trash-fixture", "--qualify-glass", "--qualify-folder-reopen", "--resume-folder-access", "--restore-trash-fixture"]
                try require(allFocusedModes.count == 1 && !otherModes.contains(where: args.contains),
                            "Focused workflow checks require one separate generated-fixture mode")
            }
            try require(!args.contains("--check-git") || !args.contains("--offscreen"),
                        "Git review checks require a visible generated window")
            try require(!args.contains("--layout-matrix") || args.contains("--check-sidebar"),
                        "Layout matrix requires the sidebar-only verification mode")
            let requestsFolderReopen = args.contains("--qualify-folder-reopen") || args.contains("--resume-folder-access")
            let requestsForeground = ["--qualify-permissions", "--qualify-permission-retry", "--qualify-folder-access", "--qualify-trash", "--qualify-glass", "--qualify-folder-reopen", "--resume-folder-access"].contains { args.contains($0) }
            let requestsRecovery = args.contains("--restore-trash-fixture")
            try require(!args.contains("--check-sidebar") || (!requestsForeground && !requestsRecovery
                && !["--qualify-trash-fixture", "--check-chrome", "--check-presentation", "--check-workspace", "--check-everyday"].contains(where: args.contains)),
                "Sidebar checks require their separate generated-fixture mode")
            try require(!args.contains("--check-everyday") || (!requestsForeground && !requestsRecovery
                && !args.contains("--qualify-trash-fixture") && !args.contains("--check-chrome")
                && !args.contains("--check-presentation") && !args.contains("--check-workspace")),
                        "Everyday workflow mode cannot combine unrelated qualification")
            try require(!args.contains("--check-workspace") || (!requestsForeground && !requestsRecovery
                && !args.contains("--qualify-trash-fixture") && !args.contains("--check-presentation") && !args.contains("--check-chrome")),
                "Workspace-only checks cannot be combined with other qualification modes")
            try require(!args.contains("--check-chrome") || (!requestsForeground && !requestsRecovery
                && !args.contains("--qualify-trash-fixture") && !args.contains("--check-presentation")),
                "Chrome-only checks cannot be combined with other qualification modes")
            try require(!requestsForeground || !args.contains("--offscreen"), "Foreground qualification cannot run offscreen")
            try require(!args.contains("--qualify-permission-retry") || !["--qualify-permissions", "--qualify-folder-access", "--qualify-trash",
                "--qualify-trash-fixture", "--qualify-glass", "--qualify-folder-reopen", "--resume-folder-access", "--restore-trash-fixture"].contains(where: args.contains),
                "Permission retry requires its separate foreground mode")
            try require(!requestsFolderReopen || (!args.contains("--qualify-permissions") && !args.contains("--qualify-folder-access")
                && !args.contains("--qualify-trash") && !args.contains("--qualify-trash-fixture") && !args.contains("--qualify-glass")),
                "Folder reopen is separate from other qualification modes")
            try require(!requestsRecovery || (args.contains("--offscreen") && !requestsForeground && !args.contains("--qualify-trash-fixture") && !args.contains("--check-presentation")),
                        "Receipt recovery requires offscreen mode alone")
            try require(!(requestsForeground || args.contains("--qualify-trash-fixture") || requestsRecovery) || !args.contains("--check-presentation"),
                        "Qualification cannot be combined with presentation-only checks")
        return .init(focusedModes: focusedModes, requestsFolderReopen: requestsFolderReopen,
            requestsForeground: requestsForeground, requestsRecovery: requestsRecovery)
    }

    static func legacyArgument(_ key: String, in args: [String]) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
                    throw Failure(message: "Missing verification argument: \(key)")
                }
                return args[index + 1]
    }

    static func legacyPrepareFixture(args: [String], admission: UILegacyAdmission) async throws -> UILegacyFixture {
        let focusedModes = admission.focusedModes
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            try require(!args.contains("--fixture-lease-fd") || args.contains("--verify-grouped-copy-responsiveness"),
                        "Inherited fixture lease requires its dedicated responsiveness mode")
            let root = URL(fileURLWithPath: try argument("--fixture-root"), isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: try argument("--evidence-root"), isDirectory: true).standardizedFileURL
            let buildRoot: URL
            let metadata: [String: Any]?
            if args.contains("--verify-drive-lifecycle") {
                try require(args.contains("--offscreen") && focusedModes.isEmpty, "Native drive qualification requires its isolated offscreen mode")
                metadata = nil
                buildRoot = try await Task.detached { try NativeDriveLifecycleVerification.validate(root, output: output) }.value
            } else if args.contains("--verify-grouped-recovery") || args.contains("--verify-grouped-copy-queue")
                || args.contains("--verify-grouped-copy-responsiveness") {
                metadata = nil
                let requiresJournal = !args.contains("--verify-grouped-copy-queue") && !args.contains("--verify-grouped-copy-responsiveness")
                buildRoot = try await Task.detached { try groupedRecoveryFixtureBuildRoot(root, requiresJournal: requiresJournal) }.value
            } else {
                let marker = root.appendingPathComponent(".mac-explorer-fixture.json")
                let markerData = try Data(contentsOf: marker)
                metadata = try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
                try require(metadata?["generator"] as? String == "mac-explorer-dev" && metadata?["complete"] as? Bool == true,
                            "Refused an unowned fixture")
                try require(root.deletingLastPathComponent().lastPathComponent == "fixtures"
                            && root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build",
                            "Fixture must be repository development data")
                buildRoot = root.deletingLastPathComponent().deletingLastPathComponent()
            }
            try require(output.path.hasPrefix(buildRoot.appendingPathComponent("evidence").path + "/"), "Evidence must stay in .build/evidence")
        return .init(root: root, output: output, metadata: metadata)
    }

}
#endif
