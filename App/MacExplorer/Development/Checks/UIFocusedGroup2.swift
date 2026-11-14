#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func runFocusedGroup2(windowController: BrowserWindowController, args: [String]) async throws -> Bool {
        let browser = windowController.browser
        func argument(_ key: String) throws -> String {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
                throw Failure(message: "Missing verification argument: \(key)")
            }
            return args[index + 1]
        }
            if args.contains("--check-smb-native") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SMBLoopbackQualification.run(packet: root, temporaryMount: args.contains("--b10-internal-mount"),
                    lifecycle: args.contains("--b10-lifecycle"), softMount: args.contains("--b10-soft-mount"))
                try report.write(to: root.appendingPathComponent("signed-app-native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-drive-management") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await DriveManagementVerification.run(root: root)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-drive-details") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await DriveDetailsVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-zip-contents") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await ArchiveContentVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-zip-creation") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await ArchiveCreationVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-zip-extraction") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await ArchiveExtractionVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-selected-extraction") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SelectedArchiveExtractionVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-zip-browser") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await ArchiveBrowserVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-related-names") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await RelatedNamesVerification.run(root: root)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-launch-profiles") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await LaunchProfilesVerification.run(root: root, workspace: windowController.workspace)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-private-import-scale") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PrivateNamesImportVerification.runScale(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-private-import") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PrivateNamesImportVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_PRIVATE_IMPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-private-management") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PrivateNamesManagementVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_PRIVATE_MANAGEMENT " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-private-move-members") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PrivateMoveMemberNativeVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_PRIVATE_MOVE_MEMBERS " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-move-workspace") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let review = args.contains("--show-move-workspace-review")
                let report = try await MoveWorkspaceVerification.run(root: root, browser: browser, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_MOVE_WORKSPACE " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-private-names") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let review = args.contains("--show-private-names-review")
                let report = try await PrivateNamesVerification.run(root: root, browser: browser, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_PRIVATE_NAMES " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-first-use") {
                let report = try await StatePreparationVerification.run(root: URL(fileURLWithPath: argument("--analysis-source")))
                print("MAC_EXPLORER_FIRST_USE " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-workspace-analysis") {
                throw Failure(message: "Historical external-drive acceptance is retired. Use the generated analysis checks.")
            }
            if args.contains("--check-app-accounting") || args.contains("--show-app-accounting-review") {
                let review = args.contains("--show-app-accounting-review")
                let report = try await StorageAppAccountingVerification.run(root: URL(fileURLWithPath: argument("--analysis-source")), browser: browser, review: review)
                print("MAC_EXPLORER_APP_ACCOUNTING " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                if !review { NSApplication.shared.terminate(nil) }
                return true
            }
            if args.contains("--check-location-actions") {
                let report = try await StorageLocationActionsVerification.run(root: URL(fileURLWithPath: argument("--analysis-source")),
                    browser: browser, ordinary: args.contains("--ordinary-location-actions"), selectedTrash: args.contains("--qualify-selected-trash"),
                    review: args.contains("--show-selected-cleanup-review"), internalFixture: args.contains("--internal-selected-fixture"),
                    pickerPreferences: args.contains("--qualify-picker-preferences"),
                    inspectInternalOnly: args.contains("--inspect-internal-selected"),
                    inspectSelectedHistory: args.contains("--inspect-selected-history"))
                print("MAC_EXPLORER_LOCATION_ACTIONS " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                fflush(stdout)
                if !args.contains("--show-selected-cleanup-review") { NSApplication.shared.terminate(nil) }
                return true
            }
            if args.contains("--check-chart-lifecycle") {
                let report = try await StorageChartLifecycleVerification.run()
                print("MAC_EXPLORER_CHART_LIFECYCLE " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-chart-keyboard") {
                let report = try await args.contains("--integrated-chart-keyboard")
                    ? StorageChartKeyboardIntegrationVerification.run(root: URL(fileURLWithPath: argument("--analysis-source")))
                    : StorageChartKeyboardVerification.run()
                print("MAC_EXPLORER_CHART_KEYBOARD " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-sorted-pages") {
                let report = try await StorageSortedPagingVerification.run(browser: browser, ordinary: args.contains("--ordinary-sorted-pages"))
                print("MAC_EXPLORER_SORTED_PAGES " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-summary-hover") {
                try require(!args.contains("--offscreen"), "Native hover callbacks require a key generated window")
                let report = try await FolderSummaryHoverVerification.run(root: URL(fileURLWithPath: argument("--analysis-source")))
                print("MAC_EXPLORER_SUMMARY_HOVER " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--show-browser-repair-review") {
                let source = URL(fileURLWithPath: try argument("--analysis-source"), isDirectory: true)
                browser.settings.showsPathBar = true
                browser.navigate(to: .directory(source))
                try await settled(browser)
                browser.operationPresentation = .init(phaseTitle: "Copy", percentage: 0.35, summary: "Generated progress preview · no file transfer",
                    currentItem: "Generated fixture", completedText: "Presentation check only", samples: [2, 3, 5, 4, 6, 5])
                browser.updateOperationProgressControls()
                windowController.window?.title = "Mac Explorer · B06.2 browser repair review"
                windowController.showWindow(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return true
            }
            if args.contains("--check-browser-regressions") || args.contains("--qualify-address-directory-hint") || args.contains("--check-classification-audit") {
                let source = URL(fileURLWithPath: try argument("--analysis-source"), isDirectory: true)
                let report: [String: Any]
                if args.contains("--check-classification-audit") { report = try await StoragePrefixVerification.auditFixture(root: source) }
                else if args.contains("--qualify-address-directory-hint") { throw Failure(message: "Historical live-index qualification is retired. Use the generated address-completion checks.") }
                else { report = try await BrowserRegressionVerification.run(source: source) }
                print("MAC_EXPLORER_BROWSER_REGRESSIONS " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
        return false
    }
}
#endif
