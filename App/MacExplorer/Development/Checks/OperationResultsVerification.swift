import AppKit
import FileOperations

#if DEBUG
extension UIVerification {
    static func verifyOperationResults(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String] {
        func button(_ title: String, in root: NSView) -> NSButton? {
            if let found = root as? NSButton, found.title == title { return found }
            return root.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        let parent = fixture.appendingPathComponent("Generated result folder", isDirectory: true)
        let moved = FileOperationOutcome(source: parent.appendingPathComponent("Completed.txt"), destination: fixture.appendingPathComponent("Completed.txt"), status: .succeeded, recoveryURLs: [])
        let skipped = FileOperationOutcome(source: parent.appendingPathComponent("Skipped.txt"), destination: fixture.appendingPathComponent("Skipped.txt"), status: .skipped, recoveryURLs: [])
        let pending = FileOperationOutcome(source: parent.appendingPathComponent("Not attempted.txt"), destination: fixture.appendingPathComponent("Not attempted.txt"), status: .notStarted, recoveryURLs: [])
        let retained = FileOperationOutcome(source: parent, destination: fixture, status: .notStarted, recoveryURLs: [], role: .mergeContainer)
        let report = FileOperationResult(items: [moved, skipped, pending, retained], cancellationRequested: true)
        let summary = OperationResultDescription(result: report).summary
        let denied = FileOperationResult(items: [.init(source: parent.appendingPathComponent("Denied.txt"),
            destination: fixture.appendingPathComponent("Denied.txt"), status: .failed(.accessDenied), recoveryURLs: [])], cancellationRequested: false)
        try require(OperationResultDescription(result: denied).offersFolderAccess
            && !OperationResultDescription(result: report).offersFolderAccess
            && !OperationResultDescription.folderAccessExplanation.contains("sandbox"),
            "Folder access advice must follow an actual denial and stay user-facing")
        try require(summary.contains("1 of 3 items completed") && summary.contains("1 source folder retained"),
                    "Partial merge report counted a container as an untouched file")
        let folderDetail = OperationResultDescription.details(for: retained)
        try require(folderDetail.contains("Some children may already have transferred") && !folderDetail.contains("No changes were made"),
                    "Retained container description hides completed child transfers")
        let emptyMerge = FileOperationResult(items: [FileOperationOutcome(source: parent, destination: fixture,
            status: .succeeded, recoveryURLs: [], role: .mergeContainer)], cancellationRequested: false)
        try require(OperationResultDescription(result: emptyMerge).summary == "1 source folder retired.",
                    "Empty merged folder has an empty file denominator")
        let uncertain = FileOperationOutcome(source: parent, destination: fixture, status: .failed(.recoveryUncertain),
            recoveryURLs: [fixture.appendingPathComponent("generated-recovery-area")], role: .mergeContainer)
        try require(OperationResultDescription.title(for: uncertain) == "Folder needs review"
            && !OperationResultDescription.details(for: uncertain).contains("The source folder remains"),
                    "Uncertain folder retirement falsely confirms its original location")
        let uncertainJob = FileOperationOutcome(source: nil, destination: nil,
            status: .failed(.recoveryUncertain), recoveryURLs: [fixture.appendingPathComponent("Completed.txt")], role: .job)
        let changedReport = FileOperationResult(items: [uncertainJob, moved, pending], cancellationRequested: false)
        let changedDescription = OperationResultDescription(result: changedReport)
        try require(changedDescription.summary.contains("1 of 2 items changed")
            && !changedDescription.summary.contains("items completed")
            && changedDescription.itemTitle(moved) == "Changed · needs review"
            && changedDescription.itemDetails(moved).contains("could not be confirmed")
            && !changedDescription.itemDetails(moved).hasPrefix("Completed."),
                    "Uncertain native outcome counted its job as a file or claimed verified completion")
        let changedView = OperationResultsView(result: changedReport) { _ in }
        try require(changedView.visibleItems.count == 3
            && changedView.visibleItems.contains(where: { $0.source == moved.source }),
                    "Attention filter hides the item that changed during an uncertain operation")
        let returned = fixture.appendingPathComponent("Returned.txt")
        let unconfirmed = FileOperationOutcome(source: parent.appendingPathComponent("Returned.txt"),
            destination: returned, status: .failed(.recoveryUncertain), recoveryURLs: [returned])
        let mixedTrash = FileOperationResult(items: [moved, unconfirmed, uncertainJob], cancellationRequested: false)
        let trashDescription = OperationResultDescription(result: mixedTrash)
        try require(trashDescription.summary.contains("1 of 2 items completed")
            && trashDescription.summary.contains("1 needs review")
            && trashDescription.itemTitle(moved) == "Completed"
            && trashDescription.itemTitle(unconfirmed) == "Needs review"
            && trashDescription.itemDetails(unconfirmed).contains(returned.path),
            "An unconfirmed Trash return obscured the verified row or its own recorded destination")
        let normalDescription = OperationResultDescription(result: report)
        try require(normalDescription.itemTitle(moved) == "Completed"
            && normalDescription.itemDetails(moved).hasPrefix("Completed.")
            && !normalDescription.itemNeedsAttention(moved),
                    "A normal partial result lost its independently completed item")
        let failedConfirmation = OperationResultDescription(result: changedReport, recoveryAction: .confirmCopies)
        try require(failedConfirmation.itemTitle(moved) == "Completed"
            && !failedConfirmation.itemNeedsAttention(moved),
                    "A failed evidence-only confirmation was described as a fresh unconfirmed change")
        let confirmedJob = FileOperationOutcome(source: nil, destination: nil, status: .succeeded,
            recoveryURLs: [], role: .job)
        let evidenceOnly = FileOperationResult(items: [confirmedJob, confirmedJob], cancellationRequested: false)
        try require(OperationResultDescription(result: evidenceOnly).summary == "Operation completed.",
                    "Successful job-only work was described as zero completed copies")
        let originalResult = browser.lastOperationResult, originalAction = browser.lastRecoveryAction
        let originalPresenter = browser.operationResultPresenter
        let originalStatus = browser.status.stringValue
        defer {
            browser.lastOperationResult = originalResult; browser.lastRecoveryAction = originalAction
            browser.operationResultPresenter = originalPresenter; browser.status.stringValue = originalStatus
            browser.operationResultsButton.isHidden = originalResult == nil
            browser.operationResultsButton.isEnabled = browser.canInspectLastOperationResult
        }
        browser.operationResultPresenter = { _ in }
        for (action, expected) in [(CopyRecoveryAction.confirmCopies, "Confirmed existing copies."),
                                   (.confirmUndo, "Confirmed completed Undo."), (.finishReview, "Recovery review finished.")] {
            let described = OperationResultDescription(result: evidenceOnly, recoveryAction: action)
            try require(described.summary == expected && !described.summary.contains("items completed"),
                        "Recovery confirmation counted job evidence as fresh file transfers")
            var copiedConfirmation: String?
            let inspection = OperationResultsView(result: evidenceOnly, recoveryAction: action) { copiedConfirmation = $0 }
            button("Copy Selected Details", in: inspection)?.performClick(nil)
            try require(inspection.resultDescription.summary == expected
                && copiedConfirmation == expected,
                        "Native result inspection lost the explicit confirmation context")
            browser.presentOperationResult(evidenceOnly, recoveryAction: action)
            try require(browser.lastRecoveryAction == action && browser.status.stringValue == expected,
                        "Successful confirmation status or shared result lost its captured action")
            let failedJob = FileOperationOutcome(source: nil, destination: nil, status: .failed(.recoveryUncertain),
                recoveryURLs: [fixture.appendingPathComponent("generated-review-location")], role: .job)
            let failed = FileOperationResult(items: [failedJob], cancellationRequested: false)
            browser.presentOperationResult(failed, recoveryAction: action)
            let failureDetail = OperationResultDescription.details(for: failedJob, recoveryAction: action)
            try require(browser.lastRecoveryAction == action && browser.status.stringValue.contains("needs review")
                && !browser.status.stringValue.contains("items completed") && failureDetail.contains(action.title)
                && failureDetail.contains(FileOperationFailure.recoveryUncertain.userMessage)
                && failureDetail.contains(failedJob.recoveryURLs[0].path),
                        "Failed confirmation hid its actual review action, failure or retained location")
            // Queue completion writes shared history directly, whereas ordinary
            // commands use presentOperationResult. Both must retire stale context.
            browser.operationHistory.lastResult = report
            try require(browser.lastRecoveryAction == nil, "A newer queue result inherited recovery confirmation context")
            browser.presentOperationResult(report)
            try require(browser.lastRecoveryAction == nil && browser.status.stringValue == summary,
                        "A newer ordinary result retained confirmation wording")
        }

        var copied: String?
        var revealed: [URL] = []
        let view = OperationResultsView(result: report, reveal: { revealed.append($0) }) { copied = $0 }
        try require(view.visibleItems.count == 2, "Attention view hides pending or retained-container results")
        guard let filter = button("Show only items needing attention", in: view),
              let copy = button("Copy Selected Details", in: view) else { throw Failure(message: "Result inspection controls are missing") }
        copy.performClick(nil)
        try require(copied?.contains("This transfer unit was not attempted") == true, "Selected result details did not copy explicitly")
        guard let source = button("Reveal Source", in: view), let destination = button("Reveal Destination", in: view) else {
            throw Failure(message: "Partial result inspection has no source/destination reveal actions")
        }
        source.performClick(nil); destination.performClick(nil)
        try require(revealed == [pending.source, pending.destination].compactMap { $0 },
                    "Result location actions used current browser selection instead of the captured result")
        let fallback = try await OperationResultsView.availableRevealLocation(for: parent.appendingPathComponent("Missing result item"))
        try require(fallback == fixture, "Missing result item did not resolve to its nearest available parent")
        filter.performClick(nil)
        try require(view.visibleItems.count == 4, "All-results view truncates successful or skipped results")
        guard let resultTable = nativeTables(in: view).first,
              let completedRow = view.visibleItems.firstIndex(where: { $0.source == moved.source }) else {
            throw Failure(message: "The native result identity is unavailable")
        }
        copy.performClick(nil)
        try require(resultTable.selectedRow == view.visibleItems.firstIndex(where: { $0.source == pending.source })
            && copied?.contains("This transfer unit was not attempted") == true,
            "Showing all results silently changed the selected item")
        resultTable.selectRowIndexes(IndexSet(integer: completedRow), byExtendingSelection: false)
        filter.performClick(nil)
        try require(view.visibleItems.count == 2 && resultTable.selectedRow == -1
            && !copy.isEnabled && !source.isEnabled && !destination.isEnabled,
            "Filtering a selected completed result silently chose another item")
        filter.performClick(nil)
        let completedView = OperationResultsView(result: .init(items: [moved], cancellationRequested: false)) { _ in }
        try require(button("Show only items needing attention", in: completedView)?.isHidden != false
            && completedView.visibleItems.count == 1,
            "A fully completed result offered an empty attention filter")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Generated operation results"
        let container = NSView()
        window.contentView = container
        pin(view, inside: container, inset: 16)
        if !browser.permitsBackgroundVerification { window.makeKeyAndOrderFront(nil) }
        defer {
            window.orderOut(nil)
            if !browser.permitsBackgroundVerification { browser.view.window?.makeKeyAndOrderFront(nil) }
        }
        container.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        for control in descendants(view).compactMap({ $0 as? NSButton }) {
            try require(view.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: view)),
                        "Result action clips outside its native accessory: \(control.title)")
        }
        let unlocated = OperationResultsView(result: FileOperationResult(items: [FileOperationOutcome(source: nil,
            destination: nil, status: .failed(.unavailable), recoveryURLs: [], role: .job)], cancellationRequested: false)) { _ in }
        try require(button("Reveal Source", in: unlocated)?.isEnabled == false
                    && button("Reveal Destination", in: unlocated)?.isEnabled == false,
                    "Unlocated result offered an invented source or destination route")
        var revealAllowed = true
        var staleRevealRejected = false
        let revealGate = ResultRevealGate()
        defer { revealGate.release() }
        let staleView = OperationResultsView(result: report, canReveal: {
            if !revealAllowed { staleRevealRejected = true }
            return revealAllowed
        }) { _ in }
        staleView.beforeRevealReturnsForVerification = { await revealGate.suspend() }
        staleView.frame = view.frame
        container.addSubview(staleView)
        button("Reveal Source", in: staleView)?.performClick(nil)
        try await waitUntil("Result location lookup did not reach its controlled return gate") { revealGate.entered }
        revealAllowed = false
        revealGate.release()
        try await waitUntil("Result reveal did not recheck live-host authority after lookup") { staleRevealRejected }
        staleView.removeFromSuperview()
        var accessAllowed = true
        var staleAccessRejected = false
        let accessGate = ResultRevealGate()
        defer { accessGate.release() }
        let staleAccessView = OperationResultsView(result: report, canReveal: {
            if !accessAllowed { staleAccessRejected = true }
            return accessAllowed
        }, acquireRevealAccess: { _ in await accessGate.suspend(); return nil }) { _ in }
        staleAccessView.frame = view.frame
        container.addSubview(staleAccessView)
        button("Reveal Source", in: staleAccessView)?.performClick(nil)
        try await waitUntil("Result reveal did not reach controlled access acquisition") { accessGate.entered }
        accessAllowed = false
        accessGate.release()
        try await waitUntil("Result reveal did not reject stale access acquisition before lookup") { staleAccessRejected }
        staleAccessView.removeFromSuperview()
        try await snapshot(window, to: output.appendingPathComponent("everyday-operation-results.png"))
        try require(view.bounds.height > 300 && view.bounds.width > 600, "Result details did not fit the native accessory layout")
        let changedContainer = NSView()
        window.contentView = changedContainer
        pin(changedView, inside: changedContainer, inset: 16)
        try await snapshot(window, to: output.appendingPathComponent("everyday-operation-results-uncertain.png"))
        return ["Partial-merge result roles count transfer units separately and describe retained containers honestly",
                "Uncertain job results count only selected transfer items and keep changed-but-unconfirmed rows visible without claiming completion",
                "Explicit recovery action context describes existing-copy/Undo evidence and completion honestly, preserves failed review details, and resets on newer queue or ordinary results",
                "Native result table filters attention/all outcomes, copies selected untruncated details and reveals captured locations with honest missing-parent fallback",
                "Changing the results filter retains the exact selected item while it remains visible and clears its actions if it disappears. Completed-only results hide the unused filter.",
                "Bounded result-location lookup rechecks live-host authority after controlled access and lookup suspension and rejects stale reveal delivery"]
    }
}

@MainActor
private final class ResultRevealGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
