#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyFailure(_ error: Error, browser: BrowserViewController, state: UILegacyRunState) async {
        let checks = state.checks, measurements = state.measurements, evidence = state.evidence
            let message = (error as? Failure)?.message ?? "Native UI verification failed: \(error)"
            // A failed assertion can leave a native Rename awaiting text. End
            // only that presentation and drain the captured preparation so the
            // ordinary pending-work guard does not reject the failure's Quit.
            // An admitted mutation has no active editor and is never bypassed.
            // A check's defer may already have retired the field while its
            // resumed preparation is still queued on the main actor.
            let inlinePreparation = browser.operationPreparationTask
            browser.inlineRename.cancel()
            if let inlinePreparation { await inlinePreparation.value }
            if ProcessInfo.processInfo.arguments.contains("--check-support-details") {
                print("MAC_EXPLORER_SUPPORT_DETAILS_FAILURE " + message)
                NSApplication.shared.terminate(nil); return
            }
            if ProcessInfo.processInfo.arguments.contains("--check-zip-text-preview") {
                await ApplicationZIPBrowser.shared.stopAndDrain()
                print("MAC_EXPLORER_ZIP_TEXT_FAILURE " + message)
                NSApplication.shared.terminate(nil); return
            }
            if ProcessInfo.processInfo.arguments.contains("--check-sandbox-foundation") {
                await ApplicationStorageAnalysis.shared.stopAndDrain()
                await SandboxFeatureVerification.stopAndDrain()
                var report: [String: Any] = ["passed": false, "failure": message,
                    "networkRequests": 0, "keychainQueries": 0, "testFlightQualified": false]
                report.merge(SandboxFoundationVerification.failureDetails) { _, qualified in qualified }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print("MAC_EXPLORER_SANDBOX_REPORT " + String(decoding: data, as: UTF8.self))
                }
                NSApplication.shared.terminate(nil); return
            }
            // A failed generated-fixture assertion may leave a gated queue job.
            // Drain this verification process's own work before normal app quit;
            // never bypass the production pending-work guard or report a pass.
            let queue = browser.operationCoordinator.transfers
            let drives = browser.operationCoordinator.drives
            if ProcessInfo.processInfo.arguments.contains("--verify-drive-lifecycle") { drives.cancel() }
            queue.cancelAllWaiting()
            queue.stopActive()
            let drainDeadline = Date().addingTimeInterval(10)
            while (queue.hasOutstandingWork || drives.isBusy), Date() < drainDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if ProcessInfo.processInfo.arguments.contains("--check-pane-transfers") {
                let report: [String: Any] = ["passed": false, "failure": message,
                    "outstandingWork": queue.hasOutstandingWork,
                    "localActivity": ApplicationFileActivity.gate.activeCount]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print("MAC_EXPLORER_PANE_REPORT " + String(decoding: data, as: UTF8.self))
                }
                NSApplication.shared.terminate(nil); return
            }
            if ProcessInfo.processInfo.arguments.contains("--check-analysis-ram") || ProcessInfo.processInfo.arguments.contains("--check-analysis-paged") {
                // This dedicated mode admits no mutation job or filesystem
                // output. Preserve a machine-readable failure without a
                // receipt, and make the direct command fail after real drain.
                await ApplicationStorageAnalysis.shared.stopAndDrain()
                let report: [String: Any] = ["passed": false, "mode": "analysis-reporting-ram",
                    "checks": checks, "failure": message, "measurements": measurements]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    print("MAC_EXPLORER_ANALYSIS_RAM " + String(decoding: data, as: UTF8.self))
                }
                fflush(stdout)
                exit(EXIT_FAILURE)
            }
            if let evidence {
                let report: [String: Any] = ["passed": false, "checks": checks, "failure": message, "measurements": measurements,
                    "nativeRequestMayBePending": drives.pending?.intent.phase == .submitted,
                    "driveCheckMayBePending": drives.isBusy, "readerAdmissionClosed": ApplicationFileActivity.gate.isClosed]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: evidence.appendingPathComponent("ui-verification.json"), options: .atomic)
                }
            }
            print(message)
            NSApplication.shared.terminate(nil)
            return
    }

}
#endif
