#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func runFocusedGroup1(windowController: BrowserWindowController, args: [String]) async throws -> Bool {
        let browser = windowController.browser
        func argument(_ key: String) throws -> String {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
                throw Failure(message: "Missing verification argument: \(key)")
            }
            return args[index + 1]
        }
            if args.contains("--check-external-tools") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await verifyNativeExternalTools(browser, root: root)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-pane-transfers") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PaneTransferVerification.run(root: root, workspace: windowController.workspace,
                    capture: args.contains("--capture-pane-transfers"))
                print("MAC_EXPLORER_PANE_REPORT " + String(decoding:
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-support-details") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let evidence: URL
                if args.contains("--support-evidence-run") {
                    let run = try argument("--support-evidence-run")
                    try require(["1", "2"].contains(run), "Unknown bounded support follow-up")
                    evidence = root.appendingPathComponent("evidence/support-followup-" + run)
                } else { evidence = root.appendingPathComponent("evidence") }
                let report = try await SupportDetailsVerification.run(root: root, browser: browser,
                    capture: args.contains("--capture-support-details"), evidenceDirectory: evidence)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: evidence.appendingPathComponent("native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-zip-text-preview") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await ArchiveTextPreviewVerification.run(root: root, browser: browser,
                    capture: args.contains("--capture-zip-text-preview"))
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                    .write(to:root.appendingPathComponent("evidence/native.json"),options:.withoutOverwriting)
                NSApplication.shared.terminate(nil);return true
            }
            if args.contains("--check-sandbox-foundation") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SandboxFoundationVerification.run(root: root,
                    phase: argument("--sandbox-phase"), browser: browser)
                print("MAC_EXPLORER_SANDBOX_REPORT " + String(decoding:
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-bundled-notices") || args.contains("--check-bundled-notices-lifetime") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await BundledNoticesVerification.run(root:root,settings:browser.settings,
                    capture: args.contains("--check-bundled-notices"))
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                    .write(to:root.appendingPathComponent("evidence/native.json"),options:.withoutOverwriting)
                NSApplication.shared.terminate(nil);return true
            }
            if args.contains("--check-portable-storage") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await PortableStorageVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-connect") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let review = args.contains("--show-smb-connect-review")
                let report = try await SMBConnectVerification.run(root: root, settings: browser.settings, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/connect.json"), options: .withoutOverwriting)
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-smb-catalog") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SMBCatalogVerification.run(root: root, mode: argument("--catalog-mode"), settings: browser.settings)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-connect-live") {
                let root = URL(fileURLWithPath: try argument("--analysis-source")), phase = try argument("--live-phase")
                let report = try await SMBConnectLiveVerification.run(root: root, phase: phase, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/connect-live-\(phase).json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-motion-modes") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await MotionModesVerification.run(root: root, controller: windowController)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-quick-profiles") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await QuickProfileVerification.run(root: root, workspace: windowController.workspace)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-incoming-folders") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await IncomingFolderVerification.run(root: root)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-browser-ui") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SMBUserInterfaceVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native-ui.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-runtime") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SMBRuntimeVerification.run(root: root, mode: argument("--runtime-mode"))
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native-runtime.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-browser") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await SMBBrowserVerification.run(root: root, mode: argument("--browser-mode"), browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native-browser.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-authenticated") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                guard let run = Int(try argument("--smb-run")) else { throw Failure(message: "Invalid authenticated SMB qualification run") }
                let report = try await SMBAuthenticatedVerification.run(root: root, run: run, settings: browser.settings)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent(String(format: "evidence/native-auth-%02d.json", run)), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-password-vault") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let phase = try argument("--password-phase")
                let report = try await SMBPasswordVerification.run(root: root, phase: phase)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/keychain-\(phase).json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-smb-worker") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                guard let run = Int(try argument("--smb-run")) else { throw Failure(message: "Invalid SMB qualification run") }
                let report = try await SMBWorkerVerification.run(root: root, run: run, settings: browser.settings)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent(String(format: "evidence/native-%02d.json", run)), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--render-tool-window") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let output = URL(fileURLWithPath: try argument("--tool-output"))
                let review = args.contains("--show-tool-window-review")
                let report = try await ToolWindowVerification.render(root: root, output: output, browser: browser, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("native.json"), options: .withoutOverwriting)
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-tool-windows") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let review = args.contains("--show-tool-window-review")
                let report = try await ToolWindowVerification.run(root: root, browser: browser, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_TOOL_WINDOWS " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-tab-motion") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let review = args.contains("--show-move-workspace-review")
                let output = args.contains("--tab-output") ? URL(fileURLWithPath: try argument("--tab-output")) : root
                let report = try await TabMotionVerification.run(root: root, output: output, browser: browser, review: review)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("native.json"), options: .withoutOverwriting)
                print("MAC_EXPLORER_TAB_MOTION " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
                if !review { NSApplication.shared.terminate(nil) }; return true
            }
            if args.contains("--check-batch-rename") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await BatchRenameVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-duplicate") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await DuplicateVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-drive-protection") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                if args.contains("--reopen-protection") {
                    let report = try await DriveProtectionVerification.reopen(root: root)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("evidence/reopen.json"), options: .withoutOverwriting)
                    NSApplication.shared.terminate(nil); return true
                }
                if args.contains("--crash-protection-boundary") {
                    try await DriveProtectionVerification.crash(root: root, boundary: try argument("--crash-protection-boundary"))
                    return true
                }
                let report = try await DriveProtectionVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-folder-views") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await FolderViewsVerification.run(root: root, browser: browser)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-app-components") {
                let root = URL(fileURLWithPath: try argument("--analysis-source"))
                let report = try await AppComponentAccountingVerification.run(root: root)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
        return false
    }
}
#endif
