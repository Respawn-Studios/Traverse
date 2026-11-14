#if DEBUG
import AppKit
import Darwin
import FileOperations

@MainActor
extension UIVerification {
    /// The caller seeds an owned grouped job outside the App target. This seam
    /// deliberately uses only the public catalog and engine review interface.
    /// No action runs unless the caller explicitly requests it for that seed.
    static func verifyGroupedCopyRecovery(_ browser: BrowserViewController,
        engine: RecoverableFileOperations, recordID: UUID, expectedItems: Int,
        in testRoot: URL, output: URL, interactive: Bool,
        action: CopyRecoveryAction? = nil, undo: Bool = false) async throws -> [String] {
        try require(browser.isControlledVerification && !(action != nil && undo),
                    "Copied-file verification needs one controlled explicit action")
        _ = try await Task.detached { try groupedRecoveryFixtureBuildRoot(testRoot) }.value
        let before = try await engine.prepareGroupedRecovery(recordID: recordID)
        try require(expectedItems > 0 && expectedItems <= 1024 && before.items.count == expectedItems,
                    "Copied-file seed has an unexpected member count")
        let prefix = testRoot.standardizedFileURL.path + "/"
        try require(before.items.allSatisfy { item in
            [item.source, item.destination].allSatisfy { $0.standardizedFileURL.path.hasPrefix(prefix) }
        }, "Copied-file seed escaped its generated root")
        let originalEngine = browser.recoverableFileOperations
        let originalPresenter = browser.operationResultPresenter
        let originalLocation = browser.location
        let originalRecords = browser.recoveryRecords
        let originalRefused = browser.refusedRecoveryEntries
        let originalCursor = browser.recoveryNextCursor
        let originalUnfinished = browser.recoveryUnfinishedCount
        browser.recoveryInspectionTask?.cancel(); browser.retentionInspectionTask?.cancel()
        browser.recoveryWindow?.close(); browser.recoveryWindow = nil
        browser.recoverableFileOperations = engine
        var presentedSummary: String?
        var presentedAction: CopyRecoveryAction?
        browser.operationResultPresenter = { [weak browser] _ in
            presentedSummary = browser?.status.stringValue
            presentedAction = browser?.lastRecoveryAction
        }
        defer {
            browser.groupedCopyRecoveryWindow?.close()
            browser.recoveryInspectionTask?.cancel(); browser.retentionInspectionTask?.cancel()
            browser.recoveryWindow?.close(); browser.recoveryWindow = nil
            browser.recoverableFileOperations = originalEngine
            browser.operationResultPresenter = originalPresenter
            browser.recoveryRecords = originalRecords; browser.refusedRecoveryEntries = originalRefused
            browser.recoveryNextCursor = originalCursor; browser.recoveryUnfinishedCount = originalUnfinished
            browser.navigate(to: originalLocation)
        }
        browser.openOperationRecovery(recordID: recordID)
        await browser.recoveryInspectionTask?.value
        let undoEntryChecks = before.canUndo
            ? try await verifyGroupedUndoEntry(browser, engine: engine, recordID: recordID, revision: before.revision)
            : []
        guard let history = browser.recoveryWindow else { throw Failure(message: "Copied-file history did not open") }
        try require(history.selectedRecordID == recordID && history.verificationCanReviewCopiedFiles,
                    "Typed grouped record lacks its explicit copied-file review action")
        try require(browser.recoveryRecords.first(where: { $0.id == recordID })?.canRecover == false,
                    "Grouped record incorrectly exposes ordinary rollback")
        history.verificationReviewCopiedFiles()
        guard let controller = browser.groupedCopyRecoveryWindow else { throw Failure(message: "Native Review Copied Files button did not open its controller") }
        await controller.inspectionTask?.value
        guard let displayed = controller.review else { throw Failure(message: "Native copied-file review did not load public evidence") }
        try require(controller.verificationRows == expectedItems
            && Set(controller.verificationEnabledActions) == Set(displayed.availableActions)
            && controller.verificationCanUndo == displayed.canUndo,
                    "Copied-file rows or guarded action availability differ from fresh engine evidence")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.verificationSelect(expectedItems - 1)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if !controller.verificationHasCompactButtons || !controller.verificationHeaderHidesScrolledRows {
            if let window = controller.window { try await snapshot(window, to: output.appendingPathComponent("grouped-copy-recovery-geometry-failure.png")) }
            throw Failure(message: "Copied-file review stretches native actions or exposes scrolled rows through its header: " + controller.verificationGeometryDescription)
        }
        guard let last = displayed.items.last else { throw Failure(message: "Copied-file last item is missing") }
        try require(controller.verificationDetail.contains(last.source.path)
            && controller.verificationDetail.contains(last.destination.path)
            && controller.verificationDetail.contains(last.state.description)
            && !GroupedCopyRecoveryWindowController.protectionText(last).isEmpty,
                    "The final copied-file row lacks full selectable paths or clear state text")
        let visible = controller.verificationVisibleRowRange
        if expectedItems > 32 {
            try require(visible.length > 0 && visible.length < expectedItems && NSLocationInRange(expectedItems - 1, visible),
                        "Copied-file table did not keep a bounded visible range or reach its final member")
        }
        let unopened = try await engine.prepareGroupedRecovery(recordID: recordID)
        try require(unopened.revision == before.revision && unopened.state == before.state,
                    "Opening copied-file history or scrolling changed durable recovery evidence")
        if let window = controller.window {
            if interactive { controller.showWindow(nil); window.makeKeyAndOrderFront(nil) }
            try await snapshot(window, to: output.appendingPathComponent("grouped-copy-recovery.png"))
            let originalFrame = window.frame
            window.setFrame(NSRect(origin: originalFrame.origin, size: window.minSize), display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            // Header clipping settles during AppKit's display pass after a
            // window resize. Inspect that rendered layout, not its old viewport.
            try await snapshot(window, to: output.appendingPathComponent("grouped-copy-recovery-minimum.png"))
            if !controller.verificationHasCompactButtons || !controller.verificationHeaderHidesScrolledRows {
                throw Failure(message: "Minimum-size copied-file review geometry: " + controller.verificationGeometryDescription)
            }
            window.setFrame(originalFrame, display: false)
        }

        // A different selected record invalidates all displayed consent, even
        // though its utility window remains available to explain the change.
        history.requestSelection(recordID: UUID())
        try require(controller.review == nil && controller.verificationEnabledActions.isEmpty && !controller.verificationCanUndo,
                    "Changing the selected history record retained copied-file consent")
        controller.verificationActivate(.confirmCopies); controller.verificationUndo()
        let deselected = try await engine.prepareGroupedRecovery(recordID: recordID)
        try require(deselected.revision == before.revision && browser.operationTask == nil,
                    "A stale copied-file action changed evidence or acquired the writer")
        history.requestSelection(recordID: recordID); history.verificationReviewCopiedFiles()
        await controller.inspectionTask?.value
        guard let refreshed = controller.review else { throw Failure(message: "Explicit reselected copied-file review did not refresh") }

        // Browsing another folder in the same live pane is not a revocation of
        // historical consent. Completion still uses its own tab/visit guards.
        browser.navigate(to: .directory(testRoot)); try await settled(browser)
        try require(controller.review?.revision == refreshed.revision,
                    "Browsing a folder silently invalidated the historical copied-file review")
        var checks = ["Typed grouped history opens a bounded native copied-file table, including its last member and full selectable details",
            "Default and minimum-size review keep compact native actions and an opaque header covering scrolled rows",
            "Opening/scanning the review never acts; selection changes revoke consent, while same-pane browsing preserves historical review"]
        checks += undoEntryChecks
        if let action {
            try require(refreshed.availableActions.contains(action), "Seed lacks the requested explicit confirmation action")
            controller.verificationActivate(action)
        } else if undo {
            try require(refreshed.canUndo, "Seed lacks fresh guarded copied-file Undo")
            controller.verificationUndo()
        }
        if action != nil || undo {
            try require(browser.operationTask != nil && browser.operationPresentationID != nil,
                        "Explicit copied-file action did not acquire native writer presentation")
            await browser.operationTask?.value
            try await waitUntil("Copied-file post-action review") { controller.review != nil && !controller.isBusy }
            let after = try await engine.prepareGroupedRecovery(recordID: recordID)
            try require(browser.operationPresentationID == nil && browser.lastOperationResult?.disposition == .succeeded
                && after.revision > refreshed.revision,
                        "Explicit copied-file action failed or left the writer reserved")
            if let action {
                try require(!after.availableActions.contains(action), "Confirmed copied-file subset remained eligible for the same action")
                let expected: String
                switch action {
                case .confirmCopies: expected = "Confirmed existing copies."
                case .confirmUndo: expected = "Confirmed completed Undo."
                case .finishReview: expected = "Recovery review finished."
                }
                guard let result = browser.lastOperationResult else { throw Failure(message: "Completed review lacks its inspectable result") }
                try require(result.items.allSatisfy { $0.role == .job } && browser.lastRecoveryAction == action
                    && presentedAction == action && presentedSummary == expected
                    && OperationResultsView(result: result, recoveryAction: browser.lastRecoveryAction, copyText: { _ in }).resultDescription.summary == expected,
                            "Actual native confirmation lost its action context or claimed freshly copied transfer items")
            } else {
                try require(browser.lastRecoveryAction == nil, "Actual guarded Undo retained a prior confirmation label")
                try require(!after.canUndo && after.items.allSatisfy { $0.state == .undone || $0.state == .notStarted || $0.state == .neverStaged || $0.state == .retainedCopy },
                            "Fresh guarded Undo left a published or unconfirmed copied-file member")
            }
            checks.append("Explicit native copied-file action rechecks public evidence, advances durable state and releases the shared writer")
        }
        return checks
    }

    /// Exercise the actual command selector with real catalog records. Restrict
    /// the command's cached page to the captured job; the fresh bounded lookup
    /// must still select that job if the inspector holds another real record.
    private static func verifyGroupedUndoEntry(_ browser: BrowserViewController,
        engine: RecoverableFileOperations, recordID: UUID, revision: Int) async throws -> [String] {
        guard let target = browser.recoveryRecords.first(where: { $0.id == recordID }), target.canUndo else {
            throw Failure(message: "Grouped Undo entry lacks its real Undo-capable history record")
        }
        let other = browser.recoveryRecords.first(where: { $0.id != recordID })
        let background = browser.permitsBackgroundVerification
        browser.permitsBackgroundVerification = true
        defer { browser.permitsBackgroundVerification = background }
        var checks: [String] = []
        for closedHistory in [true, false] {
            if !closedHistory && other == nil { continue }
            browser.groupedCopyRecoveryWindow?.close()
            if closedHistory {
                browser.recoveryWindow?.close(); browser.recoveryWindow = nil
            } else if let other {
                browser.recoveryWindow?.requestSelection(recordID: other.id)
                try require(browser.recoveryWindow?.selectedRecordID == other.id,
                            "Grouped Undo regression did not select its other real history record")
            }
            browser.recoveryRecords = [target]
            browser.focusBrowserContent()
            try require(browser.view.window?.firstResponder === browser.activeFileView && browser.canUndoFileOperation,
                        "Grouped Undo command did not start from browser file focus")
            try require(NSApplication.shared.sendAction(#selector(BrowserViewController.undoFileOperation(_:)), to: browser, from: nil),
                        "Native Undo command selector was not dispatched")
            await browser.recoveryInspectionTask?.value
            guard let controller = browser.groupedCopyRecoveryWindow else {
                throw Failure(message: closedHistory
                    ? "Native grouped Undo did not open review from closed history"
                    : "Native grouped Undo depended on the previously selected history record")
            }
            await controller.inspectionTask?.value
            try require(browser.recoveryWindow?.selectedRecordID == recordID && controller.recordID == recordID
                && controller.review?.recordID == recordID && controller.review?.canUndo == true
                && browser.operationTask == nil && browser.operationPresentationID == nil,
                        "Grouped Undo command selected the wrong job, failed to review, or started mutation without confirmation")
            let after = try await engine.prepareGroupedRecovery(recordID: recordID)
            try require(after.revision == revision,
                        "Opening grouped Undo review changed durable evidence")
            checks.append(closedHistory
                ? "Native Undo from browser file focus opens and selects its captured grouped job with history closed, without mutation"
                : "Native Undo selects its captured grouped job despite another real history selection, without mutation")
        }
        return checks
    }

    /// Both accepted shapes are generated and remain at their original bound
    /// paths. Production process fixtures are never copied or adopted by the UI.
    nonisolated static func groupedRecoveryFixtureBuildRoot(_ root: URL, requiresJournal: Bool = true) throws -> URL {
        func refuse() -> Failure { Failure(message: "Copied-file review refused an unowned or redirected generated fixture") }
        func directory(_ url: URL) throws {
            var attributes = stat()
            guard url.path == url.standardizedFileURL.path, url.resolvingSymlinksInPath().path == url.path,
                  lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
                  attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else { throw refuse() }
        }
        func marker(_ url: URL, limit: Int) throws -> Data {
            try directory(url.deletingLastPathComponent())
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw refuse() }; defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0,
                  before.st_size >= 0, before.st_size <= limit else { throw refuse() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: limit + 1)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count >= 0, result.count + count <= limit else { throw refuse() }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            var after = stat(), linked = stat()
            guard fstat(fd, &after) == 0, lstat(url.path, &linked) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, before.st_mode == after.st_mode,
                  before.st_uid == after.st_uid, after.st_nlink == 1,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  linked.st_dev == after.st_dev, linked.st_ino == after.st_ino else { throw refuse() }
            return result
        }
        func canonicalUUID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString.lowercased() == text }
        try directory(root)
        let fixtures = root.deletingLastPathComponent()
        let parent = fixtures.deletingLastPathComponent()
        let build: URL
        if fixtures.lastPathComponent == "fixtures", parent.lastPathComponent == ".build" {
            try directory(fixtures)
            let data = try marker(root.appendingPathComponent(".mac-explorer-fixture.json"), limit: 4096)
            guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  metadata["generator"] as? String == "mac-explorer-dev", metadata["version"] as? Int == 1,
                  metadata["complete"] as? Bool == true else { throw refuse() }
            build = parent
        } else {
            let base = parent.deletingLastPathComponent()
            build = base.deletingLastPathComponent()
            guard fixtures.lastPathComponent == "fixtures", canonicalUUID(parent.lastPathComponent),
                  base.lastPathComponent == "grouped-copy-production", build.lastPathComponent == ".build",
                  root.lastPathComponent.hasPrefix("copy-"), canonicalUUID(String(root.lastPathComponent.dropFirst(5))) else { throw refuse() }
            for url in [base, parent, fixtures] { try directory(url) }
            guard try marker(parent.appendingPathComponent(".qualification-owner"), limit: 256)
                    == Data("MacExplorer grouped production qualification v1\n\(parent.lastPathComponent)\n".utf8),
                  try marker(root.appendingPathComponent(".owned-grouped-production-fixture"), limit: 256)
                    == Data("MacExplorer generated grouped production fixture v1\n\(root.lastPathComponent)\n".utf8) else { throw refuse() }
        }
        for name in ["source", "destination"] { try directory(root.appendingPathComponent(name, isDirectory: true)) }
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        var journalStat = stat()
        let journalStatus = lstat(journal.path, &journalStat)
        if requiresJournal || journalStatus == 0 { try directory(journal) }
        else if errno != ENOENT { throw refuse() }
        return build
    }
}
#endif
