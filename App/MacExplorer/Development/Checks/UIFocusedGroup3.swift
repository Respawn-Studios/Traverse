#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func runFocusedGroup3(windowController: BrowserWindowController, args: [String], state: UILegacyRunState) async throws -> Bool {
        let browser = windowController.browser
        func argument(_ key: String) throws -> String {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
                throw Failure(message: "Missing verification argument: \(key)")
            }
            return args[index + 1]
        }
            if args.contains("--show-dimensional-review") {
                let review = StorageDimensionalReviewWindow(); StorageDimensionalChartVerification.review = review
                review.showWindow(nil); review.window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
                return true
            }
            if args.contains("--check-chart-integration") {
                try require(!args.contains("--offscreen"), "Native integration requires its visible generated windows")
                let report = try await StorageChartIntegrationVerification.run(path: argument("--analysis-source"), captureEvidence: !args.contains("--without-chart-captures"), layoutExplanations: args.contains("--analysis-layout-explanations"), applicationLayouts: args.contains("--analysis-application-layouts"))
                StorageChartIntegration.configure(settings: browser.settings)
                print("MAC_EXPLORER_CHART_INTEGRATION " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--show-chart-integration-review") {
                try require(!args.contains("--offscreen"), "Integration review requires its generated visible window")
                try await StorageChartIntegrationVerification.showReview(path: argument("--analysis-source")); return true
            }
            if args.contains("--check-classification-v3") {
                try require(args.contains("--offscreen"), "Classification qualification uses generated offscreen mode")
                let report = try await StorageClassificationVerification.run(ordinaryHelper: args.contains("--ordinary-classification-v3"))
                print("MAC_EXPLORER_CLASSIFICATION_V3 " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-dimensional-chart") {
                try require(!args.contains("--offscreen"), "Native dimensional animation qualification requires its visible generated window")
                let report = try await StorageDimensionalChartVerification.run(keepReview: args.contains("--keep-dimensional-review"),
                    captureEvidence: !args.contains("--without-dimensional-captures"), geometryOnly: args.contains("--dimensional-geometry-only"))
                print("MAC_EXPLORER_DIMENSIONAL_CHART " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                if !args.contains("--keep-dimensional-review") { NSApplication.shared.terminate(nil) }
                return true
            }
            if args.contains("--check-startup-prefix") {
                let token = try argument("--analysis-receipt-token")
                try require(args.contains("--offscreen") && token.utf8.count == 32
                    && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) },
                    "Internal prefix qualification requires an explicit exclusive report token")
                var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                for _ in 0..<3 { root.deleteLastPathComponent() }
                let rows = args.contains("--analysis-prefix-rows") ? UInt64(try argument("--analysis-prefix-rows")) : 1024
                guard let rows, [1024, 4096].contains(rows) else { throw Failure(message: "Unqualified prefix checkpoint size") }
                let report: [String: Any]
                do {
                    if args.contains("--analysis-accounting-only") {
                        report = try await StoragePrefixVerification.startupAccountingOnly()
                    } else {
                        report = try await StoragePrefixVerification.startup(checkpointRows: rows, profiling: args.contains("--analysis-profile"),
                            classificationRevision: args.contains("--analysis-classification-v3") ? .v3 : .v2,
                            audit: args.contains("--analysis-classification-audit"), layoutExplanations: args.contains("--analysis-layout-explanations"), applicationLayouts: args.contains("--analysis-application-layouts"))
                    }
                } catch {
                    // LaunchServices does not forward this child's stdout.
                    // Preserve a bounded coded failure instead of a missing
                    // report that cannot distinguish scan and inspector errors.
                    let message = (error as? Failure)?.message ?? (error as? StorageAnalysis.StorageScanFailure).map { String(describing: $0) } ?? "Unexpected qualification failure"
                    let failed: [String: Any] = ["passed": false, "failure": message]
                    try JSONSerialization.data(withJSONObject: failed, options: [.sortedKeys]).write(
                        to: root.appendingPathComponent(".build/logs/startup-prefix-" + token + ".json"), options: .withoutOverwriting)
                    throw error
                }
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                try data.write(to: root.appendingPathComponent(".build/logs/startup-prefix-" + token + ".json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-analysis-prefix") {
                try require(args.contains("--offscreen"), "Prefix qualification requires generated offscreen mode")
                let report = try await StoragePrefixVerification.run()
                print("MAC_EXPLORER_ANALYSIS_PREFIX " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-analysis-chart") {
                try require(!args.contains("--offscreen"), "Chart pointer review requires its visible generated window")
                let report = try await PagedStorageAnalysisVerification.classification(path: argument("--analysis-source"), interactive: true)
                print("MAC_EXPLORER_ANALYSIS_CHART " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-analysis-paged") {
                try require(args.contains("--offscreen"), "Paged generated controls require offscreen mode")
                try requireControlledWindowsHidden("Paged reporting startup")
                let receiptOutput: URL?
                if args.contains("--analysis-receipt-token") {
                    let token = try argument("--analysis-receipt-token")
                    try require(args.contains("--analysis-personal-app-data") && args.contains("--analysis-startup")
                        && args.contains("--analysis-contracts") && token.utf8.count == 32
                        && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Invalid personal-scope report token")
                    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    for _ in 0..<3 { root.deleteLastPathComponent() }
                    receiptOutput = root.appendingPathComponent(".build/logs/paged-launch-" + token + ".json")
                } else { receiptOutput = nil }
                let report: [String: Any]
                if args.contains("--analysis-completion-controls") { report = try await PagedStorageAnalysisVerification.completionControls() }
                else if args.contains("--analysis-policy-controls") { report = try await PagedStorageAnalysisVerification.policyControls() }
                else if args.contains("--analysis-classification") { report = try await PagedStorageAnalysisVerification.classification(path: argument("--analysis-source")) }
                else if args.contains("--analysis-topology") { report = try await PagedStorageAnalysisVerification.topology() }
                else if args.contains("--analysis-workspace") { throw Failure(message: "Historical external-drive qualification is retired. Use a generated analysis fixture.") }
                else if args.contains("--analysis-contracts") && args.contains("--analysis-startup") { report = try await PagedStorageAnalysisVerification.explicitDriveInterface(startup: true, deeper: args.contains("--analysis-personal-app-data")) }
                else if args.contains("--analysis-contracts") { report = try await PagedStorageAnalysisVerification.contracts() }
                else if args.contains("--analysis-startup") { report = try await PagedStorageAnalysisVerification.startup(stop: args.contains("--analysis-stop"), diagnostic: args.contains("--analysis-diagnostic")) }
                else { report = try await PagedStorageAnalysisVerification.run(name: argument("--analysis-case"),
                    lane: argument("--analysis-lane"), stop: args.contains("--analysis-stop"), appData: args.contains("--analysis-app-data")) }
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                if let receiptOutput {
                    // Launch Services output redirection can refuse an app on
                    // an external development volume before it starts. Keep
                    // this explicit personal-scope test report in our own logs.
                    try data.write(to: receiptOutput, options: .withoutOverwriting)
                }
                print("MAC_EXPLORER_ANALYSIS_PAGED " + String(decoding: data, as: UTF8.self))
                NSApplication.shared.terminate(nil); return true
            }
            if args.contains("--check-analysis-ram") {
                try require(args.contains("--offscreen"), "RAM reporting verification must stay offscreen")
                try requireControlledWindowsHidden("RAM reporting startup")
                state.checks += try StorageRingLayout.verify()
                state.checks += try await StorageScopePreferenceVerification.run()
                state.checks += try await StorageAnalysisVerification.reportingMemoryOnly()
                state.measurements["classification_audit"] = try StorageAnalysisVerification.attributionAuditMemoryOnly()
                try require(!args.contains("--analysis-soak-seconds") || !args.contains("--analysis-cancellation-soak-seconds"),
                    "Analysis soak modes require separate owned processes")
                if args.contains("--analysis-existing-scans") {
                    state.measurements["existing_sources"] = try await StorageAnalysisScaleVerification.reportingExistingSources()
                }
                if args.contains("--analysis-worker-rejection-check") {
                    state.measurements["malformed_worker"] = try await StorageAnalysisScaleVerification.rejectMalformedWorker()
                }
                if args.contains("--analysis-soak-seconds") {
                    guard let seconds = Int(try argument("--analysis-soak-seconds")), (600...21_600).contains(seconds) else {
                        throw Failure(message: "Analysis soak duration is outside its bounded native qualification range")
                    }
                    let soak = try await StorageAnalysisScaleVerification.reportingSoak(seconds: seconds)
                    state.measurements["soak"] = soak
                }
                if args.contains("--analysis-cancellation-soak-seconds") {
                    guard let seconds = Int(try argument("--analysis-cancellation-soak-seconds")), (120...14_400).contains(seconds) else {
                        throw Failure(message: "Cancellation soak duration is outside its bounded native qualification range")
                    }
                    state.measurements["cancellation_soak"] = try await StorageAnalysisScaleVerification.cancellationSoak(seconds: seconds)
                }
                try requireControlledWindowsHidden("RAM reporting completion")
                let report: [String: Any] = ["passed": true, "mode": "analysis-reporting-ram",
                    "checks": state.checks, "measurements": state.measurements,
                    "scope": "Generated RAM observations/native views; optional existing-source checks/soak reuse exact admitted corpora read-only; no new fixtures or result stores",
                    "notExercised": ["Live compositor or physical interaction", "Signed personal-scope access", "Full-volume scan"]]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print("MAC_EXPLORER_ANALYSIS_RAM " + String(decoding: data, as: UTF8.self))
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }
}
#endif
