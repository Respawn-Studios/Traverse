import Foundation
import StorageAnalysis
import SwiftUI

/// Display policy only. Scan state, cancellation and stored-result ownership
/// remain with the coordinator. Never infer completion from a byte count.
struct StorageScanPresentation {
    static let refreshHelp = "Check for changes here. Saved observations are reused when enabled; a full scan runs when needed."
    static let fullScanHelp = "Check every folder here, including folders that have not changed. Your files are untouched."
    static func location(_ root: URL) -> String { "Location: " + root.path }

    static func scanTime(_ duration: TimeInterval?, working: Bool = false, previous: Bool = false) -> String? {
        guard let duration else { return nil }
        let title = previous ? "Previous scan time: " : working ? "Elapsed: " : "Scan time: "
        return title + elapsed(duration)
    }

    static func retainedObservation(_ date: Date, complete: Bool, refreshing: Bool = false,
                                    refresh: AnalysisRefreshCheckpoint? = nil) -> String {
        (refreshing ? "Refreshing… · " : "") + recordedObservation(date, refresh: refresh)
            + (complete ? "" : " · Partial result")
    }
    static func recordedObservation(_ date: Date, refresh: AnalysisRefreshCheckpoint?) -> String {
        let latest = date.formatted(date: .abbreviated, time: .shortened)
        if let refresh, refresh.mayContainEarlierObservations {
            let original = refresh.originalObservedThrough.formatted(date: .abbreviated, time: .shortened)
            return "Changes refreshed \(latest) · Other observations from \(original) · May have changed"
        }
        return "Last analyzed \(latest) · May be out of date"
    }

    static func refreshResult(_ result: StorageAnalysisResult) -> String? {
        if let refresh = result.refreshCheckpoint, refresh.isIncremental {
            guard refresh.mayContainEarlierObservations else {
                return "Folders refreshed · No earlier observations reused"
            }
            let original = refresh.originalObservedThrough.formatted(date: .abbreviated, time: .shortened)
            return "Changed folders updated · Other observations reused from \(original)"
        }
        return result.refreshFallbackReason == nil ? nil : "A full scan was needed to update this folder."
    }

    let title: String
    let guidance: String
    let isWorking: Bool

    init(status: StorageScanStatus?, working: Bool, coverage: AnalysisScanCoverage = .init(), hasCurrentResults: Bool = true, fallback: String = "Ready to scan") {
        isWorking = working
        switch status {
        case .preparing: title = "Getting ready…"; guidance = "Preparing access to your chosen location."
        case .scanning: title = "Scanning…"; guidance = "Results appear as files are counted. You can keep browsing."
        case .completed:
            title = working ? "Finishing your results…" : "Scan complete"
            guidance = working ? "Organizing the breakdown." : "Choose a group or folder to explore its size."
        case .partial:
            title = working ? "Finishing your results…" : "Some items weren’t included"
            guidance = StorageAnalysisCoverageText.guidance(coverage)
        case .cancelled:
            title = working ? "Stopping…" : "Scan stopped"
            guidance = working ? "Waiting for scanning to finish safely."
                : hasCurrentResults ? "These results cover only the files already counted."
                : "No results are available from this stopped scan. Choose Refresh when you’re ready."
        case .failed(let failure):
            title = working ? "Stopping…" : "Couldn’t finish this scan"
            switch failure {
            case .accessDenied: guidance = "Check this location in Review Access. Its permissions may still limit which files you can read."
            case .busy: guidance = "Let the current file operation finish, then try again."
            case .unavailable: guidance = "Reconnect this drive or choose another folder."
            case .unsupportedLocation: guidance = "Choose a local folder or drive to analyze."
            case .changed: guidance = "This location changed during the scan. Scan again for a fresh result."
            case .resourceLimit: guidance = "Try scanning a smaller folder. Results already counted may still be available."
            default: guidance = "Try scanning again. If this continues, export App Logs from Help."
            }
        case nil: title = working ? "Getting ready…" : fallback; guidance = working ? "Preparing your chosen location." : ""
        }
    }

    init(_ value: FolderSummaryValue) {
        self.init(status: value.scanStatus, working: value.isRunning, coverage: value.coverage,
            hasCurrentResults: !value.observationIsPrevious && value.counts != nil && value.bytes != nil, fallback: value.message)
    }

    static func size(_ bytes: AnalysisByteSubtotals, files: UInt64, live: Bool) -> String {
        if hasObservedSize(bytes.dataLogical, files: files), hasObservedSize(bytes.allForkAllocated, files: files) {
            return "File size: " + storageMetricText(bytes.dataLogical, files: files)
                + " · Size on disk: " + storageMetricText(bytes.allForkAllocated, files: files)
                + (live ? " counted so far" : "")
        }
        return storageMetricText(bytes.dataLogical, files: files) + (live ? " counted so far" : " in files")
    }

    private static func hasObservedSize(_ subtotal: AnalysisMetricSubtotal, files: UInt64) -> Bool {
        guard subtotal.knownBytes != nil, !subtotal.overflowed else { return false }
        let missing = subtotal.notReturnedCount.addingReportingOverflow(subtotal.failedCount)
        // Empty folders have genuine zero totals. For nonempty observations,
        // an all-missing metric's initial zero is not an observed allocation.
        return !missing.overflow && (files == 0 ? missing.partialValue == 0 : missing.partialValue < files)
    }

    static func sizeHelp(_ details: String? = nil) -> String {
        let explanation = "File size counts logical file data. Size on disk is reported allocation, including resource forks. Sparse files, compression, hard links and APFS clones can make these totals differ; hard-linked names can overlap. Allocation is not exclusive physical usage, drive used space or space guaranteed to be freed by deletion. Partial totals cover only observed files and returned metadata."
        guard let details, !details.isEmpty else { return explanation }
        return explanation + "\n\n" + details
    }

    static func counts(_ counts: AnalysisEntryCounts) -> String {
        "\(counts.regularFiles.formatted()) files · \(counts.directories.formatted()) folders"
    }

    static func elapsed(_ elapsed: TimeInterval) -> String {
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return "Time unavailable" }
        if elapsed < 60 { return String(format: "%.1f s", elapsed) }
        let seconds = Int(elapsed)
        return seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// A real preparing state, not an empty capacity ring or fabricated chart.
struct StorageScanPlaceholder: View {
    var working: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie").interfaceFont(.title).foregroundStyle(.secondary)
            Text(working ? "Building your storage picture" : "Your storage breakdown appears here")
                .interfaceFont(.callout.weight(.medium))
            Text(working ? "The chart fills in as files are counted." : "Scan a folder or drive to see what takes up space.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 150).padding(12)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("storage-analysis-chart-placeholder")
    }
}
