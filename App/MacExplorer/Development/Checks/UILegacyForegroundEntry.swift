#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyForegroundActivation(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            windowController.window?.makeKeyAndOrderFront(nil)
            try await waitUntil("Verification app activation") {
                NSApplication.shared.isActive && NSApplication.shared.keyWindow === windowController.window
            }
            try await settled(browser)
    }

    static func legacyPermissionRetryMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let before = context.before
            if args.contains("--qualify-permission-retry") {
                let report = try await PermissionRetryVerification.run(browser, fixture: root, output: output)
                try require(before == (try await Task.detached { try fixtureSnapshot(root) }.value), "Permission retry changed the listing fixture")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyFolderReopenMode(_ context: UILegacyWorkflowContext) async throws -> Bool {
        let browser = context.admitted.windowController.browser
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let requestsFolderReopen = context.admitted.admission.requestsFolderReopen
        let before = context.before
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            if requestsFolderReopen {
                let receipt = args.contains("--resume-folder-access")
                    ? URL(fileURLWithPath: try argument("--resume-folder-access")) : nil
                let report = try await FolderReopenVerification.run(browser, fixture: root, output: output, priorReceipt: receipt)
                let after = try await Task.detached { try fixtureSnapshot(root) }.value
                try require(before == after, "Folder reopen modified the listing fixture")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyGlassReview(_ context: UILegacyWorkflowContext) async throws {
        let browser = context.admitted.windowController.browser
        let windowController = context.admitted.windowController
        let args = context.admitted.args
        let root = context.admitted.fixture.root, output = context.admitted.fixture.output
        let state = context.admitted.state
            if args.contains("--qualify-glass") {
                try GlassVerification.verifyBrowser(browser, output: output)
                let probe = GlassVerification.makeProbeWindow()
                defer { probe.orderOut(nil) }
                try await waitUntil("Glass probe focus") { NSApplication.shared.keyWindow === probe }
                try await Task.sleep(for: .milliseconds(450))
                let capture = output.appendingPathComponent("glass-probe.png")
                let number = probe.windowNumber
                try await Task.detached {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", String(number), capture.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw Failure(message: "Exact app-window glass capture was unavailable; no desktop capture or permission change attempted") }
                }.value
                _ = try GlassVerification.verifyCompositedProbeCapture(at: capture, for: probe)
                probe.orderOut(nil)
                windowController.window?.makeKeyAndOrderFront(nil)
                browser.navigate(to: .directory(root))
                try await settled(browser)
                _ = try await GlassVerification.verifyBrowserBackdrop(browser, fixture: root, output: output)
                browser.navigate(to: .computer)
                try await settled(browser)
                state.checks.append("Exact owned-window glass captures: native Regular material and actual browser backdrop comparison; file rows stay opaque")
            }
    }

}
#endif
