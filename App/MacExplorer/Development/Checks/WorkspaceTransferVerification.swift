#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations

@MainActor
enum WorkspaceTransferVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Workspace transfer verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("workspace-transfer-\(UUID().uuidString)", isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let commandFolder = source.appendingPathComponent("Command Context", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        let destinationCommandFolder = destination.appendingPathComponent("Destination Command Context", isDirectory: true)
        let movable = source.appendingPathComponent("Move.txt")
        let conflicting = source.appendingPathComponent("Conflict.txt")
        let moved = destination.appendingPathComponent("Move.txt")
        let conflictTarget = destination.appendingPathComponent("Conflict.txt")
        let movableBytes = Data("generated workspace move and Undo".utf8)
        let sourceConflictBytes = Data("generated source conflict remains".utf8)
        let destinationConflictBytes = Data("generated destination conflict remains".utf8)
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-workspace-transfer-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try manager.createDirectory(at: source, withIntermediateDirectories: false)
            try manager.createDirectory(at: commandFolder, withIntermediateDirectories: false)
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            try manager.createDirectory(at: destinationCommandFolder, withIntermediateDirectories: false)
            try movableBytes.write(to: movable, options: .withoutOverwriting)
            try sourceConflictBytes.write(to: conflicting, options: .withoutOverwriting)
            try destinationConflictBytes.write(to: conflictTarget, options: .withoutOverwriting)
        }.value
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.showsDockProgress = false
        settings.reviewsRecoveryAtStartup = false
        settings.operationIndicatorPosition = .statusBar
        settings.keyboardProfile = .explorer
        let left = BrowserViewController(settings: settings)
        left.permitsBackgroundVerification = true
        left.dragDrop.permitsVerification = true
        left.pinsController = BrowserPinsController(stateDirectory: nil)
        left.folderAccess = FolderAccessController(stateDirectory: nil)
        left.recoverableFileOperations = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        left.transferPasteboard = board
        left.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        let tab = BrowserTab(location: .directory(source))
        left.tabs = [tab]; left.activeID = tab.id
        let workspace = BrowserWorkspaceController(primaryBrowser: left)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1300, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 1300, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            workspace.isClosing = true
            for browser in workspace.browsers.values {
                browser.operationPreparationTask?.cancel()
                browser.operationTask?.cancel()
                browser.operationResultPresenter = nil
                browser.operationErrorPresenter = nil
                browser.transferConflictPrompt = nil
                browser.dragDrop.windowWillClose()
                browser.suspendBrowser()
            }
            window.close()
        }
        workspace.startBrowser(left)
        try await waitUntil("Workspace source fixture listing") { left.rowsByURL[movable] != nil && left.rowsByURL[conflicting] != nil && settled(left) }
        try require(workspace.splitActive(at: .trailing), "Workspace transfer could not create a destination pane")
        let right = workspace.activeBrowser
        right.permitsBackgroundVerification = true
        right.dragDrop.permitsVerification = true
        right.navigate(to: .directory(destination))
        try await waitUntil("Workspace destination fixture listing") { right.rowsByURL[conflictTarget] != nil && settled(right) }
        var errors: [String] = []
        for browser in [left, right] {
            browser.operationResultPresenter = { _ in }
            browser.operationErrorPresenter = { errors.append($0) }
            browser.dragDrop.permitsVerification = true
        }
        var checks: [String] = []
        func select(_ urls: Set<URL>, in browser: BrowserViewController) {
            browser.renderFilePresentation(selection: urls)
            browser.fileSelectionDidChange()
        }

        // Exercise the real source registry and captured target observation with
        // injected admission only. No native mouse/Finder delivery is claimed.
        workspace.activate(left)
        select([movable], in: left)
        let divider = workspace.layout.rootID
        let clipboardBeforeCopy = board.changeCount
        try require(workspace.canPerformDividerAction(.copy, split: divider), "Adjacent local destination did not admit divider Copy")
        try WorkspaceNavigationVerification.pressDivider(.copy, split: divider, in: workspace)
        try await waitUntil("Divider Copy refreshes only the adjacent destination") { right.rowsByURL[moved] != nil && settled(right) }
        let exactCopy = await Task.detached {
            (try? Data(contentsOf: movable)) == movableBytes && (try? Data(contentsOf: moved)) == movableBytes
        }.value
        try require(exactCopy && board.changeCount == clipboardBeforeCopy && workspace.activeBrowser === left
            && left.selectedURLs == [movable],
            "Divider Copy changed the source, selection, clipboard or active pane")
        try await waitUntil("Divider Copy has a native Undo") { left.canUndoFileOperation }
        left.undoFileOperation(nil)
        await left.operationPreparationTask?.value
        await left.operationTask?.value
        try await waitUntil("Divider Copy Undo refreshes the adjacent view") { right.rowsByURL[moved] == nil && settled(right) }
        let exactUndo = await Task.detached {
            (try? Data(contentsOf: movable)) == movableBytes && !FileManager().fileExists(atPath: moved.path)
        }.value
        try require(exactUndo, "Divider Copy Undo changed its source or kept the created file")
        checks.append("Divider Copy uses the normal local transfer queue and exact neighboring pane; its visible copy and Undo preserve source, clipboard and focus")
        select([movable], in: left)
        left.dragDrop.selectionDidChange(); right.dragDrop.selectionDidChange()
        try await waitUntil("Cross-pane source/target observation") {
            left.dragDrop.verificationState.readySource && right.dragDrop.verificationState.readyTargets > 0
                && !left.dragDrop.verificationState.preparing && !right.dragDrop.verificationState.preparing
        }
        try require(left.dragDrop.registerSourceForVerification(sequence: 9921), "Cross-pane source registry did not prepare")
        var admission: BrowserDropRequest?
        right.dragDrop.hooks.admit = { admission = $0; return true }
        try require(await right.dragDrop.dropForVerification(from: left.dragDrop, urls: [movable], destination: destination),
                    "Cross-pane observed drag request was not admitted")
        try require(admission?.move == true && admission?.sources == [movable] && admission?.destination == destination,
                    "Cross-pane drag changed captured source/destination or same-volume Move policy")
        left.dragDrop.endSourceForVerification()
        try require(!(await right.dragDrop.dropForVerification(from: left.dragDrop, urls: [movable], destination: destination)),
                    "Ended cross-pane source retained Move authority")
        right.dragDrop.hooks.admit = nil
        checks.append("Synthetic cross-pane file drag uses the authenticated source registry and observed destination with same-volume Move semantics; ended sources refuse, without claiming physical drag/Finder delivery")

        // Exercise the exact production admission focus transition through its
        // marked-fixture-only seam. The normal verifier still cannot enqueue a
        // native mutation. Native responder delivery follows without yielding.
        workspace.activate(left)
        select([commandFolder], in: left)
        // A real Return should navigate the destination's folder. A text-file
        // selection would now correctly open the native editor, which is not
        // part of this offscreen command-ownership flow.
        select([destinationCommandFolder], in: right)
        left.dragDrop.selectionDidChange(); right.dragDrop.selectionDidChange()
        try await waitUntil("Cross-pane command source preparation") {
            left.dragDrop.verificationState.readySource && right.dragDrop.verificationState.readyTargets > 0
                && !left.dragDrop.verificationState.preparing && !right.dragDrop.verificationState.preparing
        }
        try require(left.dragDrop.registerSourceForVerification(sequence: 9922), "Command ownership source was not ready")
        let dropAdmitted = await right.dragDrop.activateDestinationForAdmissionForVerification(
            from: left.dragDrop, ownedFixtureRoot: owned)
        try await waitUntil("Accepted drop activates its destination after tracking callback") { workspace.activeBrowser === right }
        let activeIsDestination = workspace.activeBrowser === right
        let responder = window.firstResponder
        let responderIsSource = responder === left.activeFileView
        let responderIsDestination = responder === right.activeFileView
        let copyRouted = responder?.tryToPerform(#selector(FileTableView.copy(_:)), with: nil) == true
        let copied = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { ($0 as? NSURL).map { $0 as URL } } ?? []
        responder?.keyDown(with: UIVerification.key("\r", code: 36, flags: [], window: window))
        let sourceNavigated = left.location.directoryURL != source
        let destinationNavigated = right.location.directoryURL == destinationCommandFolder
        let sourceAuthorityPreserved = left.dragDrop.hasSourceAuthorityForVerification(sequence: 9922)
        // Only context activation ran; no native job was enqueued and the
        // generated folder remains untouched while the listing is restored.
        left.dragDrop.endSourceForVerification(sequence: 9922)
        let sourceAuthorityEnded = !left.dragDrop.hasSourceAuthorityForVerification(sequence: 9922)
        left.navigate(to: .directory(source))
        right.navigate(to: .directory(destination))
        try await waitUntil("Restore command ownership fixture") { left.rowsByURL[movable] != nil && settled(left) }
        try await waitUntil("Restore destination command fixture") { right.rowsByURL[conflictTarget] != nil && settled(right) }
        try require(dropAdmitted && activeIsDestination && copyRouted && copied == [destinationCommandFolder] && !sourceNavigated && destinationNavigated
                    && sourceAuthorityPreserved && sourceAuthorityEnded,
                    "Cross-pane drop contradicts active command ownership: admitted=\(dropAdmitted), activeDestination=\(activeIsDestination), responderSource=\(responderIsSource), responderDestination=\(responderIsDestination), copyRouted=\(copyRouted), copiedDestinationSelection=\(copied == [destinationCommandFolder]), ReturnNavigatedSource=\(sourceNavigated), ReturnNavigatedDestination=\(destinationNavigated), sourceAuthorityPreserved=\(sourceAuthorityPreserved), sourceAuthorityEnded=\(sourceAuthorityEnded)")
        checks.append("Production cross-pane drop context activation preserves agreement between visibly active command pane and following native Copy/Return ownership; marked-fixture seam enqueues no mutation")

        // A resignation occurring after admission but before the default-loop
        // focus transition revokes only that pending transition. Hidden-window
        // admission remains supported; key status alone is not the authority.
        workspace.activate(left)
        select([commandFolder], in: left)
        left.dragDrop.selectionDidChange(); right.dragDrop.selectionDidChange()
        try await waitUntil("Deferred drop resignation source preparation") {
            left.dragDrop.verificationState.readySource && right.dragDrop.verificationState.readyTargets > 0
                && !left.dragDrop.verificationState.preparing && !right.dragDrop.verificationState.preparing
        }
        try require(left.dragDrop.registerSourceForVerification(sequence: 9923), "Resignation source was not ready")
        let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        unrelatedWindow.isReleasedWhenClosed = false
        defer { unrelatedWindow.close() }
        func drainDeferredActivation() async throws {
            let drain = DefaultLoopDrain()
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { drain.completed = true }
            }
            try await waitUntil("Deferred drop activation default-loop drain") { drain.completed }
        }
        let unrelatedAdmitted = await right.dragDrop.activateDestinationForAdmissionForVerification(
            from: left.dragDrop, ownedFixtureRoot: owned)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelatedWindow)
        try await drainDeferredActivation()
        let unrelatedAllowed = workspace.activeBrowser === right && window.firstResponder === right.activeFileView
        var resignationFailures: [String] = []
        for (name, object, label) in [
            (NSWindow.didResignKeyNotification, window as AnyObject, "target window resignation"),
            (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject, "application resignation"),
        ] {
            workspace.activate(left)
            let activePane = workspace.activePaneID
            let precedingResponder = window.firstResponder
            let admitted = await right.dragDrop.activateDestinationForAdmissionForVerification(
                from: left.dragDrop, ownedFixtureRoot: owned)
            // Post on the actual native notification seam without yielding to
            // the default-loop activation between scheduling and resignation.
            NotificationCenter.default.post(name: name, object: object)
            try await drainDeferredActivation()
            if !admitted || workspace.activePaneID != activePane || window.firstResponder !== precedingResponder {
                resignationFailures.append("\(label): admitted=\(admitted), paneUnchanged=\(workspace.activePaneID == activePane), responderUnchanged=\(window.firstResponder === precedingResponder)")
            }
        }
        let resignationPreservedSource = left.dragDrop.hasSourceAuthorityForVerification(sequence: 9923)
        left.dragDrop.endSourceForVerification(sequence: 9923)
        try require(unrelatedAdmitted && unrelatedAllowed && resignationFailures.isEmpty && resignationPreservedSource,
                    "Deferred drop activation outlived native focus authority: unrelatedAdmitted=\(unrelatedAdmitted), unrelatedAllowed=\(unrelatedAllowed), sourcePreserved=\(resignationPreservedSource); \(resignationFailures.joined(separator: "; "))")
        checks.append("Target-window/application resignation before the deferred drop transition preserves prior pane and responder ownership; unrelated-window resignation permits activation and native source authority remains until ended")

        select([movable, conflicting], in: left)
        workspace.activate(right)
        let clipboardBeforeInactiveCut = board.changeCount
        left.cutFileURLs(nil)
        try await Task.sleep(for: .milliseconds(40))
        try require(left.pendingCut == nil && board.changeCount == clipboardBeforeInactiveCut && left.cutPreparationTask == nil,
                    "An inactive pane wrote a Cut intent through controlled focus bypass")
        workspace.activate(left)
        left.cutFileURLs(nil)
        try await waitUntil("Shared Cut observation") { left.pendingCut != nil && left.cutPreparationTask == nil }
        try await waitUntil("Shared Cut presentation") {
            left.clipboardStatus.stringValue.contains("Cut 2") && right.clipboardStatus.stringValue.contains("Cut 2")
        }
        try require(right.pendingCut?.urls == left.pendingCut?.urls && left.cutURLs == [movable, conflicting] && right.cutURLs == left.cutURLs,
                    "Cut observation/markers did not cross pane boundaries")
        let beforePastePreserved = try await Task.detached {
            let first = try Data(contentsOf: movable), second = try Data(contentsOf: conflicting)
            return first == movableBytes && second == sourceConflictBytes && !FileManager().fileExists(atPath: moved.path)
        }.value
        try require(beforePastePreserved, "Cut changed generated source bytes before Paste")
        checks.append("Inactive pane Cut is refused; active Cut shares exact observed source intent and feedback across panes while leaving source bytes untouched before Paste")

        var promptEntered = false
        var releaseConflict = false
        right.transferConflictPrompt = { conflicts in
            promptEntered = true
            while !releaseConflict, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            guard !Task.isCancelled else { return nil }
            return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, TransferConflictResolution.skip) })
        }
        workspace.activate(right)
        right.pasteFileURLs(nil)
        try await waitUntil("Real move conflict review") { promptEntered && right.operationCoordinator.transfers.state.active != nil }
        workspace.activate(left)
        try await waitUntil("Global operation ring belongs to the new queue origin after changing command focus") {
            workspace.operationBrowser === right && workspace.operationButton.presentation != nil
                && !workspace.operationButton.isHidden && left.hasPendingFileOperation
        }
        left.focusBrowserContent()
        left.cycleBrowserFocus(backward: false)
        try require(window.firstResponder === left.clipboardStatus,
                    "File-browser focus cycling missed shared clipboard inspection from another pane")
        left.cycleBrowserFocus(backward: false)
        try require(window.firstResponder === workspace.operationButton,
                    "File-browser focus cycling missed the shared progress ring from another pane")
        try require(workspace.canChangePaneLayout, "Accepted queue work incorrectly blocked independent pane management")
        releaseConflict = true
        try await waitUntil("Actual cross-pane move completion", seconds: 25) { !right.operationCoordinator.transfers.hasOutstandingWork && right.operationPreparationTask == nil && right.lastOperationResult != nil }
        try await waitUntil("Shared progress ring completed its queued presentation") {
            workspace.operationButton.isHidden && workspace.operationButton.presentation == nil
        }
        let responderType = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        try require(window.firstResponder === left.activeFileView,
                    "Shared progress ring retired without returning focus to the active pane (responder: \(responderType), active pane: \(workspace.activeBrowser === left), key window: \(window.isKeyWindow))")
        let moveOutcomePreserved = try await Task.detached {
            let destinationData = try Data(contentsOf: moved)
            let originalConflict = try Data(contentsOf: conflicting)
            let existingConflict = try Data(contentsOf: conflictTarget)
            return !FileManager().fileExists(atPath: movable.path) && destinationData == movableBytes
                && originalConflict == sourceConflictBytes && existingConflict == destinationConflictBytes
        }.value
        try require(moveOutcomePreserved && right.lastTransferContinuation != nil, "Guarded Paste failed to move the admitted item/preserve skipped conflicts")
        try await waitUntil("Inactive pane recovery refresh") { left.canUndoFileOperation }
        left.undoFileOperation(nil)
        try require(left.operationPreparationTask != nil || left.operationTask != nil,
                    "Cross-pane Undo command was not admitted")
        // Access preparation precedes the inverse worker. A nil worker at this
        // point does not mean Undo finished, and must not trigger fixture reads
        // or teardown while the accepted preparation is still running.
        await left.operationPreparationTask?.value
        await left.operationTask?.value
        try await waitUntil("Cross-pane Undo completion", seconds: 25) {
            left.operationPreparationTask == nil && left.operationTask == nil && settled(left)
        }
        let undone = try await Task.detached {
            let restored = try Data(contentsOf: movable)
            return restored == movableBytes && !FileManager().fileExists(atPath: moved.path)
        }.value
        try require(undone && errors.isEmpty, "Surviving active pane Undo did not restore the actual moved source")
        checks.append("Real recoverable Cut in one pane/Paste in another moves the absent target, preserves skipped conflict bytes, keeps global progress bound to the owner through focus changes, and Undo from the other pane restores the source")

        // Produce another real continuation and retain it across origin teardown.
        left.refresh(nil); right.refresh(nil)
        try await waitUntil("Restored sources and refreshed destination") {
            left.rowsByURL[movable] != nil && right.rowsByURL[conflictTarget] != nil && settled(left) && settled(right)
        }
        workspace.activate(left)
        select([movable, conflicting], in: left)
        left.copyFileURLs(nil)
        workspace.activate(right)
        right.pasteFileURLs(nil)
        try await waitUntil("Real partial copy continuation", seconds: 25) {
            !right.operationCoordinator.transfers.hasOutstandingWork && right.operationPreparationTask == nil && right.lastTransferContinuation != nil
        }
        guard let continuationID = right.lastTransferContinuation?.id, let result = right.lastOperationResult else {
            throw UIVerification.Failure(message: "Real copy did not retain continuation/results")
        }
        try require(left.lastTransferContinuation?.id == continuationID && left.lastOperationResult?.items.count == result.items.count,
                    "Inactive pane cannot inspect shared completed operation history")
        workspace.activate(left)
        select([conflicting], in: left)
        left.cutFileURLs(nil)
        try await waitUntil("Cut before origin-pane closure") { left.pendingCut?.urls == [conflicting] && left.cutPreparationTask == nil }
        try require(workspace.closeActivePane(), "Origin pane failed to close after its write was complete")
        let survivor = workspace.activeBrowser
        survivor.permitsBackgroundVerification = true
        try require(workspace.browsers.count == 1 && survivor.lastTransferContinuation?.id == continuationID
                    && survivor.lastOperationResult?.items.count == result.items.count && survivor.canInspectLastOperationResult
                    && survivor.pendingCut?.urls == [conflicting], "Pane teardown lost shared results/continuation or valid Cut intent")
        board.clearContents(); board.setString("newer private clipboard", forType: .string)
        try await waitUntil("Window-owned clipboard polling after origin removal", seconds: 3) {
            survivor.pendingCut == nil && survivor.transferFeedback == nil && survivor.cutURLs.isEmpty
        }
        try require(survivor.lastTransferContinuation?.id == continuationID && survivor.lastOperationResult != nil,
                    "Clipboard refresh accidentally forgot operation history")
        let finalPreservation = try await Task.detached {
            let sourceData = try Data(contentsOf: movable), copiedData = try Data(contentsOf: moved)
            let conflictData = try Data(contentsOf: conflictTarget)
            return sourceData == movableBytes && copiedData == movableBytes && conflictData == destinationConflictBytes
        }.value
        try require(finalPreservation && errors.isEmpty, "Cross-pane fixture completion changed preserved source/conflict data")
        checks.append("Real continuation and result history survive origin-pane closure; shared Cut remains valid until newer private clipboard data clears it through window-owned polling, with no history loss")
        return checks
    }

    private static func settled(_ browser: BrowserViewController) -> Bool { !browser.isLoading && browser.orderingTask == nil }
    @MainActor private final class DefaultLoopDrain { var completed = false }
    private static func waitUntil(_ message: String, seconds: TimeInterval = 12, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        try require(condition(), message)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
}
#endif
