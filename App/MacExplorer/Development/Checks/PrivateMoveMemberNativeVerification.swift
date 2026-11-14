#if DEBUG
import AppKit
import Combine
import FileMemory
import FileOperations

@MainActor enum PrivateMoveMemberNativeVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-continuity-management", isDirectory: true)
        try UIVerification.require(root.deletingLastPathComponent() == expected,
            "Member native qualification requires the separate admitted packet")
        try UIVerification.require(UUID(uuidString: root.lastPathComponent) != nil && root.resolvingSymlinksInPath() == root
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Changed generated member root")
        let source = root.appendingPathComponent("source"), folder = source.appendingPathComponent("Project")
        let child = folder.appendingPathComponent("Nested/Document.txt"), target = root.appendingPathComponent("destination")
        let names = root.appendingPathComponent("names"), history = root.appendingPathComponent("history")
        let settings = browser.settings
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        browser.permitsBackgroundVerification = true
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        let engine = RecoverableFileOperations(journalDirectory: history, protecting: [names])
        browser.recoverableFileOperations = engine
        var owner = ApplicationPrivateNames(directory: names, settings: settings)
        browser.privateNames = owner
        browser.navigate(to: .directory(source))
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        let childID = try await owner.save(AuthoredNames(nickname: "Orion child"), source: child,
            id: nil, revision: nil, access: nil, allowFollowing: true)
        let folderID = try await owner.save(AuthoredNames(nickname: "Orion project"), source: folder,
            id: nil, revision: nil, access: nil, allowFollowing: true)
        try UIVerification.require(!owner.moveMembersAvailable, "Remember implicitly upgraded the private catalog")
        let library = PrivateNamesWindowController(owner: owner)
        library.show(browser: browser)
        library.model.enableMoveFollowing()
        try await wait { library.window?.attachedSheet != nil }
        if let sheet = library.window?.attachedSheet { library.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        try await wait { library.window?.attachedSheet == nil }
        try UIVerification.require(!owner.moveMembersAvailable && !owner.moveContinuityAvailable, "Cancel enabled following")
        library.model.enableMoveFollowing()
        try await wait { library.window?.attachedSheet != nil }
        if let sheet = library.window?.attachedSheet { library.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        try await wait { owner.moveMembersAvailable && !owner.isSaving }
        library.close()
        try UIVerification.require(owner.moveMembersAvailable && owner.moveContinuityAvailable, "Explicit member update unavailable")
        let queue = browser.operationCoordinator.transfers
        var attention: [Bool] = []
        let observation = owner.$moveAttention.sink { attention.append($0) }
        guard let job = queue.enqueue(sources: [folder], destination: target, move: true, title: "Generated descendant Move",
            origin: browser, engine: engine, metadataPolicy: .strict) else { throw UIVerification.Failure(message: "Native queue refused member Move") }
        try await wait { queue.results.contains { $0.id == job } && !queue.hasOutstandingWork }
        let files = queue.results.first { $0.id == job }!.outcome
        try UIVerification.require(files.result.disposition == .succeeded && !queue.state.isPaused, "Member following blocked file results")
        try UIVerification.require(try await owner.availability(childID).location?.path == target.appendingPathComponent("Project/Nested/Document.txt").path,
            "Actual queue did not follow its selected remembered descendant")
        try UIVerification.require(try await owner.availability(folderID).location?.path == target.appendingPathComponent("Project").path,
            "Member admission lost ordinary root following")
        observation.cancel()
        try UIVerification.require(!attention.contains(true) && browser.recoveryWindow == nil
            && browser.view.window?.attachedSheet == nil, "Clean member Move opened/flashed review UI")
        guard let operation = files.recordID else { throw UIVerification.Failure(message: "Missing member operation") }
        await owner.close()
        owner = ApplicationPrivateNames(directory: names, settings: settings); browser.privateNames = owner
        _ = try await owner.readableStore()
        let record = try await engine.inspectExistingHistory().records.first { $0.id == operation }
        guard let record else { throw UIVerification.Failure(message: "Missing native Undo record") }
        browser.startRecoveryOperation(record, rollback: false)
        try await wait { browser.operationTask == nil && browser.operationPresentationID == nil }
        try UIVerification.require(browser.lastOperationResult?.disposition == .succeeded, "Native member Undo failed")
        try UIVerification.require(try await owner.availability(childID).location?.path == child.path, "Cold native Undo lost descendant")
        try UIVerification.require(try await owner.availability(folderID).location?.path == folder.path, "Cold native Undo lost root")
        // An admitted operation cancelled before execution retires without a
        // nagging reconciliation round trip or any file-history write.
        let unstarted = try await engine.prepareTransfer(sources: [folder], destinationDirectory: target, move: true)
        let pending = await owner.prepareMoveNames(plan: unstarted, choices: [:], engine: engine)
        try UIVerification.require(pending?.handoffs.count == 2, "Second member admission missing")
        await owner.finishMoveNames(pending, engine: engine)
        let originalLocation = try await owner.availability(childID).location?.path
        try UIVerification.require(!owner.moveAttention && originalLocation == child.path,
            "Unstarted member Move left false attention")
        try await UIVerification.snapshot(browser.view.window!, to: root.appendingPathComponent("native-members.png"))
        await owner.close()
        return ["passed": true, "operation": operation.uuidString,
            "checks": ["Native enable sheet Cancel leaves catalog unchanged; explicit v4 update succeeds", "No Remember/startup upgrade", "Actual queued root and nested member following",
                "Cold native Undo restores both references", "No unsolicited review/queue pause", "Unstarted admission retires quietly"],
            "notExercised": ["Physical drag acceptance", "Power loss", "Additional native cross-device run; separate actual-disk core cases cover both directions"]]
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native member workflow did not drain")
    }
}
#endif
