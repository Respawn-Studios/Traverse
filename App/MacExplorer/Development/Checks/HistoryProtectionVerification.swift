#if DEBUG
import AppKit
import FileOperations

@MainActor
enum HistoryProtectionVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        let root = testRoot.appendingPathComponent("history-protection-" + UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        let file = source.appendingPathComponent("Generated sample.txt")
        try await Task.detached {
            for url in [root, source, destination] {
                try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try Data("Generated history boundary check".utf8).write(to: file, options: .withoutOverwriting)
        }.value
        let engine = RecoverableFileOperations(journalDirectory: history)
        let seeded = await engine.perform(.createFolder(parent: destination, name: "Generated folder"))
        try UIVerification.require(seeded.result.disposition == .succeeded, "History protection seeding failed")
        let before = try await Task.detached { try snapshot(history) }.value
        let blocked = await engine.perform(.copy(sources: [file], destinationDirectory: history))
        guard let failure = blocked.result.items.first(where: { $0.status == .failed(.operationHistoryProtected) }) else {
            throw UIVerification.Failure(message: "Actual protected request did not return its known refusal")
        }
        let summary = OperationResultDescription(result: blocked.result).summary
        let view = OperationResultsView(result: blocked.result) { _ in }
        try UIVerification.require(blocked.recordID == nil && blocked.result.items.allSatisfy { $0.recoveryURLs.isEmpty }
            && summary.contains("Request blocked") && !summary.contains("need review")
            && OperationResultDescription.title(for: failure) == "Protected app history"
            && OperationResultDescription.details(for: failure).contains(FileOperationFailure.operationHistoryProtected.userMessage)
            && view.resultDescription.summary == summary,
            "Native blocked request invented recovery uncertainty or lost its explanation")

        let folder = source.appendingPathComponent("history", isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: folder, withIntermediateDirectories: false) }.value
        let plan = try await engine.prepareTransfer(sources: [folder], destinationDirectory: root, move: false)
        guard let conflict = plan.conflicts.first else { throw UIVerification.Failure(message: "Protected conflict disappeared") }
        let (alert, decisions) = makeTransferConflictAlert(plan.conflicts)
        alert.layout()
        alert.window.contentView?.layoutSubtreeIfNeeded()
        alert.accessoryView?.layoutSubtreeIfNeeded()
        guard let table = descendants(alert.accessoryView!).compactMap({ $0 as? NSTableView }).first,
              let rowMenu = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSPopUpButton else {
            throw UIVerification.Failure(message: "Protected conflict has no native row control")
        }
        let rowOptions = rowMenu.itemArray.compactMap { $0.representedObject as? TransferConflictResolution }
        let menus = descendants(alert.accessoryView!).compactMap { $0 as? NSPopUpButton }
        let options = menus.flatMap(\.itemArray).compactMap { $0.representedObject as? TransferConflictResolution }
        try UIVerification.require(!conflict.canReplace && !conflict.canMerge && conflict.destinationProtectionMessage != nil
            && decisions()[conflict.id] == .skip && options.contains(.keepBoth)
            && rowOptions == [.skip, .keepBoth]
            && !options.contains(.replace) && !options.contains(.merge)
            && alert.informativeText.contains("live history is protected"),
            "Native protected conflict exposed Replace/Merge or hid Keep Both")
        alert.window.close()

        // A separate real app queue owns this generated job. Its result is fed
        // through the same native description/view above; no foreground, system
        // clipboard, ordinary owner queue or automatic sheet is exercised here.
        let coordinator = ApplicationOperationCoordinator(), queue = coordinator.transfers
        let browser = BrowserViewController(settings: BrowserSettings(persist: false))
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.operationResultPresenter = { _ in }; browser.operationErrorPresenter = { _ in }
        _ = browser.view
        guard let id = queue.enqueue(sources: [file], destination: history, move: false, title: "Generated protected request",
            origin: browser, engine: engine, metadataPolicy: .strict) else {
            throw UIVerification.Failure(message: "Protected queue request was not admitted for preparation")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (queue.results.first(where: { $0.id == id }) == nil || !queue.isIdleForCopyPreview) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try UIVerification.require(queue.results.contains { $0.id == id && $0.outcome.recordID == nil
            && $0.outcome.result.items.contains { $0.status == .failed(.operationHistoryProtected) } }
            && queue.state.active == nil && !queue.hasOutstandingWork && queue.reviewResultID == id
            && queue.canInspectResults && queue.canResume,
            "Protected queue request remained stuck or lost explicit inspection/resume")
        try UIVerification.require(queue.resume() && queue.reviewResultID == nil && !queue.state.isPaused,
            "Known protected refusal could not clear queue attention")
        let after = try await Task.detached { try snapshot(history) }.value
        try UIVerification.require(before == after, "Protected native checks modified history")
        let production = try await CopyPreviewActivationVerification.scopedEngine(journal: history, root: root)
        try UIVerification.require(await production.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled,
            "Native production queue engine could not explicitly activate")
        let inputs = try await Task.detached {
            try (0..<16).map { index -> URL in
                let url = source.appendingPathComponent("Queued production \(index).txt")
                try Data("Generated queued production copy \(index)".utf8).write(to: url, options: .withoutOverwriting)
                return url
            }
        }.value
        guard let copiedID = queue.enqueue(sources: inputs, destination: destination, move: false, title: "Generated production Copy",
            origin: browser, engine: production, metadataPolicy: .strict, copyExecution: .previewIfAvailable) else {
            throw UIVerification.Failure(message: "Production queue admission failed after protected-result resume")
        }
        let copyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (queue.results.first(where: { $0.id == copiedID }) == nil || !queue.isIdleForCopyPreview) && ContinuousClock.now < copyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let copied = queue.results.first(where: { $0.id == copiedID }), let record = copied.outcome.recordID else {
            throw UIVerification.Failure(message: "Production queue failed to settle with a recorded outcome")
        }
        let inspection = try await production.inspectExistingHistory()
        try UIVerification.require(copied.outcome.result.disposition == .succeeded
            && inspection.records.contains { $0.id == record && $0.kind == .groupedCopy }
            && !queue.state.isPaused && queue.reviewResult == nil,
            "Actual app queue did not select and complete the public production grouped route")
        let copiesMatch = try await Task.detached {
            try inputs.enumerated().allSatisfy { index, url in
                let expected = Data("Generated queued production copy \(index)".utf8)
                return try Data(contentsOf: url) == expected && Data(contentsOf: destination.appendingPathComponent(url.lastPathComponent)) == expected
            }
        }.value
        try UIVerification.require(copiesMatch, "Native production queue copied different generated data")
        let undone = await production.undo(recordID: record)
        let originalsPreserved = try await Task.detached {
            try inputs.enumerated().allSatisfy { index, url in
                try Data(contentsOf: url) == Data("Generated queued production copy \(index)".utf8)
                    && !FileManager().fileExists(atPath: destination.appendingPathComponent(url.lastPathComponent).path)
            }
        }.value
        try UIVerification.require(undone.result.disposition == .succeeded && originalsPreserved,
            "Native production queue Undo did not preserve its generated originals")
        browser.suspendBrowser()
        return [
            "Actual protected Copy has no record/recovery locations; native Results distinguish a blocked request from uncertain work",
            "Protected history conflict keeps default Skip and offers Keep Both while excluding Replace/Merge with a clear explanation",
            "Separate app queue settles protected preparation, exposes inspection and resumes explicitly; original history bytes unchanged",
            "Same app queue resumes into a public qualified production grouped Copy of 16 generated files, verifies data and history kind, and completes guarded Undo"
        ]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    nonisolated private static func snapshot(_ history: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: history.path).map {
            ($0, try Data(contentsOf: history.appendingPathComponent($0)))
        })
    }
}
#endif
