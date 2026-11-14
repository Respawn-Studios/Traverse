import AppKit
import FileOperations
import ObjectiveC

#if DEBUG
/// Only a private generated-fixture pasteboard. No native drag session, Finder
/// transfer, external application or production mutation is started by this probe.
@MainActor
final class FixtureDraggingInfo: NSObject, NSDraggingInfo {
    private let board: NSPasteboard
    var pasteboardReadCount = 0
    var onPasteboardRead: ((Int) -> Void)?
    var draggingPasteboard: NSPasteboard {
        pasteboardReadCount += 1
        onPasteboardRead?(pasteboardReadCount)
        return board
    }
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var destinationWindow: NSWindow?
    var location = NSPoint.zero
    var draggingDestinationWindow: NSWindow? { destinationWindow }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?, sequence: Int, allowed: NSDragOperation = [.copy, .move]) {
        self.board = board; draggingSource = source; draggingSequenceNumber = sequence
        draggingSourceOperationMask = allowed
        super.init()
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Timer target enters from a native run-loop callback after the verification
/// Task has suspended, so no Swift Task executor frame surrounds the pump.
@MainActor
private final class DragTrackingProbe: NSObject {
    let start: () -> Void
    let ready: () -> Bool
    let continuation: CheckedContinuation<Bool, Never>
    init(start: @escaping () -> Void, ready: @escaping () -> Bool,
         continuation: CheckedContinuation<Bool, Never>) {
        self.start = start; self.ready = ready; self.continuation = continuation
    }
    @objc func run(_ timer: Timer) {
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(heartbeat, forMode: .eventTracking)
        defer { heartbeat.invalidate() }
        start()
        let deadline = Date(timeIntervalSinceNow: 1)
        while !ready() && Date() < deadline {
            _ = RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.01))
        }
        continuation.resume(returning: ready())
    }
}

@MainActor
private final class PendingDropGate {
    var entered = false
    var returned = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        returned = true
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
extension UIVerification {
    private static func verifyPendingExternalDrop(_ browser: BrowserViewController, board: NSPasteboard,
        source: URL, target: URL, targetRow: Int, output: URL) async throws {
        let controller = browser.dragDrop, queue = browser.operationCoordinator.transfers
        try require(!queue.hasOutstandingWork, "Pending drop verification needs an idle queue")
        let oldEngine = browser.recoverableFileOperations, oldHook = controller.hooks.admitPendingExternal
        let oldQueueHook = queue.beforeAdmissionObservationReturnsForVerification
        let wasPaused = queue.state.isPaused
        browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: target.appendingPathComponent("pending-unused-journal"))
        _ = queue.resume()
        let gate = PendingDropGate()
        var gates = [gate]
        var jobID: UUID?, callbacks = 0, reentrantAccepted = false
        let incoming = FixtureDraggingInfo(board: board, source: nil, sequence: 9179, allowed: .copy)
        queue.beforeAdmissionObservationReturnsForVerification = { _ in await gate.wait() }
        controller.hooks.admitPendingExternal = { request in
            callbacks += 1
            reentrantAccepted = controller.acceptDrop(incoming, row: targetRow, operation: .on)
            jobID = request.enqueue(in: browser)
            return jobID != nil
        }
        defer {
            if let jobID { _ = queue.cancelWaiting(jobID) }
            gates.forEach { $0.release() }
            queue.beforeAdmissionObservationReturnsForVerification = oldQueueHook
            controller.hooks.admitPendingExternal = oldHook
            controller.draggingExited()
            browser.recoverableFileOperations = oldEngine
            if wasPaused { queue.pause() } else { _ = queue.resume() }
        }
        controller.draggingExited()
        let offer = controller.validateDrop(incoming, row: targetRow, operation: .on)
        let accepted = controller.acceptDrop(incoming, row: targetRow, operation: .on)
        let duplicate = controller.acceptDrop(incoming, row: targetRow, operation: .on)
        let preparing = jobID.map { id in queue.state.waiting.contains { $0.id == id && $0.phase == .preparing } } ?? false
        let preparingTitle = queue.presentation?.phaseTitle == "Preparing"
        let initial: [String: Any] = ["copyOffered": offer == .copy, "accepted": accepted,
            "preparing": preparing, "preparingTitle": preparingTitle, "pendingCallbacks": callbacks,
            "duplicateAccepted": duplicate, "reentrantAccepted": reentrantAccepted,
            "physicalFinderExercised": false, "transferPerformed": false]
        try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("pending-external-drop-initial.json"), options: .withoutOverwriting)
        try require(offer == .copy && accepted && preparing && preparingTitle && callbacks == 1
            && !duplicate && !reentrantAccepted, "A cold external drop was lost before its queued Preparing stage")
        try await waitUntil("Pending external drop validation gate") { gate.entered }
        var progressButton: OperationProgressButton?
        try await waitUntil("Pending external Copy has native Preparing feedback") {
            browser.view.window?.contentView?.layoutSubtreeIfNeeded()
            progressButton = [browser.workspace?.operationButton, browser.footerOperationButton, browser.navigationOperationButton]
                .compactMap { $0 }.first { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
                    && $0.accessibilityLabel() == "File operation: Preparing" }
            return progressButton != nil
        }
        guard let window = browser.view.window else { throw Failure(message: "Pending Copy has no native feedback window") }
        try await snapshot(window, to: output.appendingPathComponent("pending-preparing.png"))
        let nativePreparingVisible = progressButton?.accessibilityLabel() == "File operation: Preparing"
        queue.pause()
        try await waitUntil("Accepted external source metadata settles") { controller.verificationState.external }
        let lateDuplicate = controller.acceptDrop(incoming, row: targetRow, operation: .on)
        try require(!lateDuplicate, "A pending drag acquired a second admission after its metadata became ready")
        guard let cancelledID = jobID else { throw Failure(message: "Pending external drop lost its queue identity") }
        try require(queue.cancelWaiting(cancelledID), "Pending external drop could not be cancelled")
        gate.release()
        try await waitUntil("Cancelled pending external validator drains") { gate.returned }
        var observations: [[String: Any]] = []
        func record(_ value: [String: Any]) throws {
            observations.append(value)
            try JSONSerialization.data(withJSONObject: ["cases": observations, "physicalFinderExercised": false],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("pending-external-drop-validation.json"), options: .atomic)
        }
        let cancelled = !queue.state.waiting.contains { $0.id == cancelledID } && queue.state.active == nil
            && !queue.results.contains { $0.id == cancelledID }
            && !FileManager().fileExists(atPath: target.appendingPathComponent(source.lastPathComponent).path)
        try record(["case": "cancelled-preparation", "cancelled": cancelled, "validatorDrained": gate.returned,
            "duplicateAfterMetadataReady": lateDuplicate, "nativePreparingVisible": nativePreparingVisible])
        try require(cancelled, "Late pending drop validation revived cancelled work or transferred a file")

        // A fresh native sequence is another explicit attempt. Replace only the
        // generated target AFTER queue observation and require the real engine
        // to refuse it, rather than copying into the new occupant.
        let staleGate = PendingDropGate(); gates.append(staleGate)
        let repeated = FixtureDraggingInfo(board: board, source: nil, sequence: 9180, allowed: .copy)
        queue.beforeAdmissionObservationReturnsForVerification = { _ in await staleGate.wait() }
        var repeatedCallbacks = 0, repeatedReentry = false
        controller.hooks.admitPendingExternal = { request in
            repeatedCallbacks += 1
            repeatedReentry = controller.acceptDrop(repeated, row: targetRow, operation: .on)
            jobID = request.enqueue(in: browser)
            return jobID != nil
        }
        controller.draggingExited()
        let repeatedOffer = controller.validateDrop(repeated, row: targetRow, operation: .on)
        let repeatedAccepted = controller.acceptDrop(repeated, row: targetRow, operation: .on)
        try require(repeatedOffer == .copy && repeatedAccepted && repeatedCallbacks == 1 && !repeatedReentry,
                    "A cancelled pending drop poisoned the next native sequence")
        try await waitUntil("Repeated pending drop captured target") { staleGate.entered }
        guard let staleID = jobID else { throw Failure(message: "Repeated pending drop lost its job") }
        let held = output.appendingPathComponent("pending-original-target-" + UUID().uuidString, isDirectory: true)
        try FileManager().moveItem(at: target, to: held)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        staleGate.release()
        try await waitUntil("Repeated pending drop becomes ready") { queue.state.waiting.contains { $0.id == staleID && $0.phase == .ready } }
        _ = queue.resume()
        try await waitUntil("Changed pending destination refuses") { queue.results.contains { $0.id == staleID } && queue.state.active == nil }
        guard let stale = queue.results.first(where: { $0.id == staleID }) else { throw Failure(message: "Changed target has no queue result") }
        let staleRefused = stale.outcome.recordID == nil && stale.outcome.result.items.contains { $0.status == .failed(.destinationChanged) }
            && !FileManager().fileExists(atPath: target.appendingPathComponent(source.lastPathComponent).path)
        try record(["case": "changed-destination", "refused": staleRefused,
            "repeatedSequenceAccepted": repeatedAccepted, "callbacks": repeatedCallbacks,
            "reentrantAccepted": repeatedReentry, "validatorDrained": staleGate.returned])
        try require(staleRefused, "Pending Copy entered a substituted destination")
        // Retain the rejected generated occupant; restore the original target
        // namespace for the existing independent drag controls that follow.
        try FileManager().moveItem(at: target, to: output.appendingPathComponent("pending-rejected-target-" + UUID().uuidString))
        try FileManager().moveItem(at: held, to: target)
        browser.navigate(to: .directory(source.deletingLastPathComponent())); try await settled(browser)
        guard let restoredSourceRow = browser.rowsByURL[source] else { throw Failure(message: "Generated source row did not restore") }
        browser.table.selectRowIndexes(IndexSet(integer: restoredSourceRow), byExtendingSelection: false)
        controller.selectionDidChange()
        try await waitUntil("Original generated destination observation restored") { !controller.verificationState.preparing && controller.verificationState.readySource }

        let rejected = FixtureDraggingInfo(board: board, source: nil, sequence: 9181, allowed: .copy)
        board.clearContents(); board.writeObjects([source.deletingLastPathComponent().appendingPathComponent("source-link") as NSURL])
        defer { board.clearContents(); board.writeObjects([source as NSURL]) }
        queue.beforeAdmissionObservationReturnsForVerification = nil
        controller.hooks.admitPendingExternal = { request in jobID = request.enqueue(in: browser); return jobID != nil }
        controller.draggingExited()
        let rejectedOffer = controller.validateDrop(rejected, row: targetRow, operation: .on)
        let rejectedAccepted = controller.acceptDrop(rejected, row: targetRow, operation: .on)
        guard let rejectedID = jobID, rejectedAccepted else { throw Failure(message: "Unsupported generated input did not reach pending validation") }
        try await waitUntil("Unsupported pending input refuses before transfer") { queue.results.contains { $0.id == rejectedID } }
        guard let unsupported = queue.results.first(where: { $0.id == rejectedID }) else { throw Failure(message: "Unsupported pending input has no result") }
        let unsupportedRefused = rejectedOffer == .copy && unsupported.outcome.recordID == nil
            && unsupported.outcome.result.items.contains { $0.status == .failed(.unsupported) }
            && !FileManager().fileExists(atPath: target.appendingPathComponent("source-link").path)
        try record(["case": "unsupported-source", "acceptedForChecking": rejectedAccepted, "refusedBeforeTransfer": unsupportedRefused])
        try require(unsupportedRefused, "Pending external validation accepted an unsupported source")
        board.clearContents(); board.writeObjects([source as NSURL])
        var contextObservations: [[String: Any]] = []
        let previousPreparedHook = controller.hooks.admit
        defer { controller.hooks.admit = previousPreparedHook }
        for (index, phase) in ["pending-materialization", "pending-dedup-key", "prepared-dedup-key"].enumerated() {
            controller.selectionDidChange()
            try await waitUntil("Context-fence generated target ready") { !controller.verificationState.preparing && controller.verificationState.readySource }
            controller.draggingExited()
            let info = FixtureDraggingInfo(board: board, source: nil, sequence: 9260 + index, allowed: .copy)
            _ = controller.validateDrop(info, row: targetRow, operation: .on)
            if phase == "prepared-dedup-key" {
                try await waitUntil("Context-fence prepared external source") { controller.verificationState.external }
            }
            var staleCallbacks = 0, triggered = false
            controller.hooks.admit = { _ in staleCallbacks += 1; return true }
            controller.hooks.admitPendingExternal = { _ in staleCallbacks += 1; return true }
            let oldVisit = browser.sessionID, oldPresentation = browser.filePresentationID
            info.pasteboardReadCount = 0
            info.onPasteboardRead = { count in
                guard count == (phase == "pending-materialization" ? 1 : 2) else { return }
                info.onPasteboardRead = nil
                triggered = true
                // Model the visit/presentation identities replaced by native
                // reentry, while keeping the new context loaded and eligible.
                browser.sessionID = UUID(); browser.filePresentationID = UUID()
                controller.selectionDidChange()
            }
            let staleAccepted = controller.acceptDrop(info, row: targetRow, operation: .on)
            info.onPasteboardRead = nil
            contextObservations.append(["phase": phase, "getterTriggered": triggered,
                "visitChanged": oldVisit != browser.sessionID, "presentationChanged": oldPresentation != browser.filePresentationID,
                "accepted": staleAccepted, "admissionCallbacks": staleCallbacks, "browserLoading": browser.isLoading])
            try JSONSerialization.data(withJSONObject: contextObservations, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("pending-native-context.json"), options: .atomic)
            try require(triggered && !browser.isLoading && !staleAccepted && staleCallbacks == 0,
                        "A native getter admitted a drop from a replaced visit or presentation")
        }
        controller.hooks.admit = previousPreparedHook
        controller.selectionDidChange()
        try await waitUntil("Boundary pending target ready") { !controller.verificationState.preparing && controller.verificationState.readySource }
        let boundaryRoot = output.appendingPathComponent("pending-128-sources-" + UUID().uuidString, isDirectory: true)
        let boundarySources = try await Task.detached {
            try FileManager().createDirectory(at: boundaryRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("MacExplorer generated pending128 fixture v1".utf8).write(to: boundaryRoot.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            return try (0..<BrowserDragDropController.maximumItems).map { index in
                let url = boundaryRoot.appendingPathComponent("generated-\(index).txt")
                try Data("generated bounded drag input".utf8).write(to: url, options: .withoutOverwriting)
                return url
            }
        }.value
        board.clearContents(); board.writeObjects(boundarySources.map { $0 as NSURL })
        let boundaryGate = PendingDropGate(); gates.append(boundaryGate)
        queue.beforeAdmissionObservationReturnsForVerification = { _ in await boundaryGate.wait() }
        controller.hooks.admitPendingExternal = { request in jobID = request.enqueue(in: browser); return jobID != nil }
        controller.draggingExited()
        let boundary = FixtureDraggingInfo(board: board, source: nil, sequence: 9270, allowed: .copy)
        let boundaryOffer = controller.validateDrop(boundary, row: targetRow, operation: .on)
        let boundaryAccepted = controller.acceptDrop(boundary, row: targetRow, operation: .on)
        guard let boundaryID = jobID, boundaryAccepted else { throw Failure(message: "128-source external Copy was not accepted for checking") }
        try await waitUntil("128-source pending validation settles") { boundaryGate.entered || queue.results.contains { $0.id == boundaryID } }
        let boundaryFailures = queue.results.first { $0.id == boundaryID }?.outcome.result.items.compactMap { item -> String? in
            if case .failed(let failure) = item.status { return failure.rawValue }; return nil
        } ?? []
        let boundaryValid = boundaryOffer == .copy && boundaryGate.entered && boundaryFailures.isEmpty
        try record(["case": "128-source-boundary", "actualPasteboardItems": board.pasteboardItems?.count ?? 0,
            "acceptedForChecking": boundaryAccepted, "reachedValidatedGate": boundaryGate.entered, "failures": boundaryFailures])
        try require(boundaryValid, "The admitted128-source boundary failed before its validation gate")
        try require(queue.cancelWaiting(boundaryID), "128-source pending preparation could not be cancelled")
        boundaryGate.release()
        try await waitUntil("128-source pending validator drains") { boundaryGate.returned }
    }
    /// Dispatch the actual Objective-C destination callback on the installed
    /// sidebar. No NSDraggingSession or physical pointer delivery is fabricated.
    private static func verifySidebarDragCompletion(_ browser: BrowserViewController,
                                                    board: NSPasteboard, targetRow: Int,
                                                    sourceRow: Int) async throws -> Int {
        let outline = browser.outline, coordinator = browser.dragDrop
        let originalExit = outline.onFileDragExited
        var callbacks = 0, callbackSawInactive = true
        outline.onFileDragExited = {
            callbacks += 1
            callbackSawInactive = callbackSawInactive && !outline.isFileDragActive
            originalExit?()
        }
        defer { outline.onFileDragExited = originalExit }
        let ended = #selector(NSDraggingDestination.draggingEnded(_:))
        try require(outline.responds(to: ended), "Sidebar drag-end selector is not exposed")
        coordinator.draggingExited()
        for round in 0..<3 {
            let incoming = FixtureDraggingInfo(board: board, source: nil, sequence: 9500 + round * 2, allowed: .copy)
            _ = outline.draggingEntered(incoming)
            try require(outline.isFileDragActive, "Sidebar native drag entry did not become active")
            _ = coordinator.validateDrop(incoming, row: targetRow, operation: .on)
            try await waitUntil("Sidebar drag-end generated external observation") { coordinator.verificationState.external }
            let beforeEnd = callbacks
            _ = outline.perform(ended, with: incoming)
            try require(!outline.isFileDragActive && callbacks == beforeEnd + 1 && callbackSawInactive
                        && !coordinator.verificationState.external,
                        "Sidebar native drag end did not clear active state and destination authority exactly once")

            let next = FixtureDraggingInfo(board: board, source: nil, sequence: 9501 + round * 2, allowed: .copy)
            _ = outline.draggingEntered(next)
            _ = coordinator.validateDrop(next, row: targetRow, operation: .on)
            try await waitUntil("Sidebar next generated drag prepares after native end") { coordinator.verificationState.external }
            let beforeExit = callbacks
            outline.draggingExited(next)
            try require(!outline.isFileDragActive && callbacks == beforeExit + 1 && callbackSawInactive
                        && !coordinator.verificationState.external,
                        "Sidebar native drag exit retained active state or destination authority")
            // AppKit may deliver end after exit. Cleanup must remain harmless,
            // and the next source must still have its immediate native writer.
            _ = outline.perform(ended, with: next)
            try require(!outline.isFileDragActive && callbacks == beforeExit + 2 && callbackSawInactive
                        && !coordinator.verificationState.external
                        && coordinator.pasteboardWriter(for: sourceRow) != nil,
                        "Sidebar exit/end sequence disabled subsequent dragging or repeated admission authority")
        }
        return callbacks
    }

    private static func trackDragPreparation(start: @escaping () -> Void,
                                             until ready: @escaping () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let probe = DragTrackingProbe(start: start, ready: ready, continuation: continuation)
            let timer = Timer(timeInterval: 0.001, target: probe, selector: #selector(DragTrackingProbe.run(_:)),
                              userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .default)
        }
    }

    /// Separate timing regression: uses AppKit's real tracking run-loop mode,
    /// not a real NSDraggingSession or physical Finder delivery.
    static func verifyDragTrackingPreparation(_ browser: BrowserViewController, fixture: URL,
                                               output: URL, interactive: Bool) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try require(output.path.hasPrefix(project.appendingPathComponent(".build").path + "/")
                    && output.resolvingSymlinksInPath() == output, "Drag tracking output is not an owned build root")
        let root = output.appendingPathComponent("drag-tracking-fixture-" + UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("generated.txt")
        try Data("generated drag tracking fixture".utf8).write(to: source, options: .withoutOverwriting)
        let controller = browser.dragDrop
        let oldHooks = controller.hooks, oldVerification = controller.permitsVerification
        let oldBackground = browser.permitsBackgroundVerification
        controller.permitsVerification = true; browser.permitsBackgroundVerification = true
        controller.hooks.admit = { _ in true }
        defer {
            controller.windowWillClose(); controller.hooks = oldHooks
            controller.permitsVerification = oldVerification; browser.permitsBackgroundVerification = oldBackground
        }
        browser.navigate(to: .directory(root)); try await settled(browser)
        guard let row = browser.rowsByURL[source], let targetRow = browser.rowsByURL[target] else {
            throw Failure(message: "Drag tracking generated rows are missing")
        }
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.windowWillClose()
        let coldSourceReady = await trackDragPreparation(start: { controller.selectionDidChange() },
                                                         until: { controller.verificationState.readySource })
        try await waitUntil("Cold drag worker settles after tracking returns") {
            controller.verificationState.readySource && !controller.verificationState.preparing
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([source as NSURL])
        let incoming = FixtureDraggingInfo(board: board, source: nil, sequence: 9401, allowed: .copy)
        let externalReady = await trackDragPreparation(start: {
            _ = controller.validateDrop(incoming, row: targetRow, operation: .on)
        }, until: { controller.verificationState.external })
        // Selection can include offscreen files. The supported128-item
        // selection must take precedence over speculative visible-row warming.
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        let fileRows = browser.displayedEntries.indices.filter { browser.displayedEntries[$0].kind == .file }
        let selectedRows = Array(fileRows.dropFirst(256).prefix(BrowserDragDropController.maximumItems))
        try require(selectedRows.count == BrowserDragDropController.maximumItems, "Retained large fixture is too small for selection-capacity control")
        browser.table.selectRowIndexes(IndexSet(selectedRows), byExtendingSelection: false)
        controller.selectionDidChange()
        try await waitUntil("Bounded selection preparation drains") { !controller.verificationState.preparing }
        let allSelectedReady = selectedRows.allSatisfy { controller.hasPreparedObjectForVerification(browser.displayedEntries[$0].url) }
        try require(allSelectedReady && controller.verificationState.readySource
            && selectedRows.allSatisfy({ controller.pasteboardWriter(for: $0) != nil }),
            "Visible-row warming displaced supported offscreen selected drag sources")
        let selectedURLs = Set(selectedRows.map { browser.displayedEntries[$0].url })
        let originalMode = browser.effectiveViewMode
        var selectionModes = [originalMode.rawValue]
        for mode in BrowserViewMode.allCases where mode != originalMode {
            browser.setPaneViewMode(mode)
            browser.view.layoutSubtreeIfNeeded()
            if browser.usesFileIcons { browser.iconBrowser.setSelection(selectedURLs) }
            else { browser.table.selectRowIndexes(IndexSet(selectedRows), byExtendingSelection: false) }
            browser.fileSelectionDidChange(); controller.selectionDidChange()
            try await waitUntil("Selected drag capacity in \(mode.rawValue)") { !controller.verificationState.preparing && controller.verificationState.readySource }
            try require(browser.selectedItemCount == BrowserDragDropController.maximumItems
                && selectedURLs.allSatisfy({ controller.pasteboardWriter(for: $0) != nil }),
                "Presentation switch lost a supported selected drag writer")
            selectionModes.append(mode.rawValue)
        }
        browser.setPaneViewMode(originalMode)
        browser.navigate(to: .directory(root)); try await settled(browser)
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.selectionDidChange()
        try await waitUntil("Window-transition source restores") { !controller.verificationState.preparing && controller.verificationState.readySource }
        browser.table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        controller.selectionDidChange()
        let visibleWarmCacheRetained = controller.hasPreparedObjectForVerification(source)
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.selectionDidChange()
        try require(visibleWarmCacheRetained && controller.pasteboardWriter(for: row) != nil,
            "A visible selection change invalidated the warmed drag writer during mouse-down")
        var windowTransitions: [[String: Any]] = []
        if interactive {
            guard let main = browser.view.window else { throw Failure(message: "Drag context has no main window") }
            main.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
            browser.focusBrowserContent()
            let properties = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) }, copyPaths: { _ in })
            defer {
                properties.cancel(); properties.close()
                (browser.workspace?.settingsWindow ?? browser.settingsWindow)?.close()
                main.orderOut(nil)
            }
            var admissions = 0
            controller.hooks.admit = { _ in admissions += 1; return true }
            for (index, phase) in ["before-secondary-window", "settings-retained", "properties-and-settings-retained", "repeat-return"].enumerated() {
                if phase == "settings-retained" { browser.showSettings(nil) }
                if phase == "properties-and-settings-retained" {
                    properties.show(urls: [source])
                    try await waitUntil("Generated Properties metadata") { !properties.model.isLoading }
                }
                if phase == "repeat-return" { (browser.workspace?.settingsWindow ?? browser.settingsWindow)?.makeKeyAndOrderFront(nil) }
                if index > 0 {
                    try require((browser.workspace?.settingsWindow ?? browser.settingsWindow)?.isVisible == true,
                        "Settings must remain open during the context check")
                }
                main.makeKeyAndOrderFront(nil)
                try await waitUntil("Browser regains native key-window context") { main.isKeyWindow }
                controller.selectionDidChange()
                try await waitUntil("Returned drag context preparation") { !controller.verificationState.preparing && controller.verificationState.readySource }
                let sequence = 9510 + index
                let writerReady = controller.pasteboardWriter(for: row) != nil
                try require(controller.registerSourceForVerification(sequence: sequence), "Returned source registration failed")
                let info = FixtureDraggingInfo(board: board, source: browser.activeFileView, sequence: sequence, allowed: [.move, .copy])
                let offered = controller.validateDrop(info, row: targetRow, operation: .on)
                let accepted = controller.acceptDrop(info, row: targetRow, operation: .on)
                controller.endSourceForVerification(sequence: sequence)
                windowTransitions.append(["phase": phase, "mainIsKey": main.isKeyWindow,
                    "writerReady": writerReady, "moveOffered": offered == .move, "accepted": accepted,
                    "exclusiveOperation": browser.hasExclusiveBrowserOperation,
                    "sourceAuthorityReleased": !controller.hasSourceAuthorityForVerification(sequence: sequence)])
                try require(writerReady && offered == .move && accepted && admissions == index + 1
                    && !browser.hasExclusiveBrowserOperation && !controller.hasSourceAuthorityForVerification(sequence: sequence),
                    "Retained secondary window disabled native drag admission: \(phase)")
            }
        }
        let report: [String: Any] = ["coldSourceReadyDuringTracking": coldSourceReady,
            "externalReadyDuringTracking": externalReady, "physicalDragExercised": false,
            "finderExercised": false, "fileMutationExercised": false, "selectedCapacity": selectedRows.count,
            "allOffscreenSelectedSourcesReady": allSelectedReady, "visibleWarmCacheRetained": visibleWarmCacheRetained,
            "selectionModes": selectionModes, "windowTransitions": windowTransitions]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("drag-tracking-verification.json"), options: .withoutOverwriting)
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        try require(coldSourceReady && externalReady,
                    "Native eventTracking preparation stalled: coldSource=\(coldSourceReady), external=\(externalReady)")
        return ["Cold source and external file-URL preparation complete while AppKit eventTracking mode remains active; physical Finder delivery is separate"]
            + (interactive ? ["Ready source and authenticated internal-drop callbacks survive repeated return with Settings/Properties retained; no physical pointer or mutation claim"] : [])
    }

    static func verifyDragDropWorkflows(_ browser: BrowserViewController, fixture: URL,
                                        output: URL) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build", isDirectory: true).path + "/"
        try require(output.path.hasPrefix(build) && output.resolvingSymlinksInPath() == output,
                    "Drag verification output is not an owned repository build root")
        let root = output.appendingPathComponent("drag-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        try Data("MacExplorer generated drag fixture v1\n".utf8)
            .write(to: root.appendingPathComponent(".owned-fixture"), options: .withoutOverwriting)
        let first = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try Data("generated drag source".utf8).write(to: first, options: .withoutOverwriting)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("source-link")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: first)

        let coordinator = browser.dragDrop
        let writerExposed = browser.responds(to: #selector(NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)))
        let beginExposed = browser.responds(to: #selector(NSTableViewDataSource.tableView(_:draggingSession:willBeginAt:forRowIndexes:)))
        let endExposed = browser.responds(to: #selector(NSTableViewDataSource.tableView(_:draggingSession:endedAt:operation:)))
        try require(browser.table.dataSource === browser && writerExposed && beginExposed && endExposed,
                    "Native table source callbacks are not exposed: dataSource=\(browser.table.dataSource === browser), writer=\(writerExposed), willBegin=\(beginExposed), ended=\(endExposed)")
        let originalHooks = coordinator.hooks, originalVerification = coordinator.permitsVerification
        let originalBackground = browser.permitsBackgroundVerification
        coordinator.permitsVerification = true; browser.permitsBackgroundVerification = true
        var admissions: [BrowserDropRequest] = []
        var lifecycleFailures: [String] = []
        // Explorer's modifier translation intentionally overrides mouseDown and
        // forwards to AppKit. Comparing method addresses cannot establish that
        // forwarding is broken. Exercise admission/lifecycle below instead;
        // pointer selection has its existing behavioral regression suite.
        coordinator.hooks.admit = { admissions.append($0); return true }
        defer {
            coordinator.windowWillClose(); coordinator.hooks = originalHooks
            coordinator.permitsVerification = originalVerification
            browser.permitsBackgroundVerification = originalBackground
        }
        let op: (Bool, Bool, NSEvent.ModifierFlags, NSDragOperation) -> NSDragOperation = BrowserDragDropController.operation
        try require(op(true, true, [], [.copy, .move]) == .move, "Same-filesystem default is not Move")
        try require(op(true, false, [], [.copy, .move]) == .copy, "Cross-filesystem default is not Copy")
        try require(op(true, true, .option, [.copy, .move]) == .copy, "Option did not request Copy")
        try require(op(true, false, .command, [.copy, .move]) == .move, "Command did not request Move")
        try require(op(true, true, [.option, .command], .every).isEmpty, "Unsupported Link was admitted")
        try require(op(false, true, [], .every) == .copy, "External default is not Copy")
        try require(op(false, true, .command, .every).isEmpty, "Explicit external Move was silently downgraded")
        try require(op(true, true, .command, .copy).isEmpty, "Move ignored the allowed source mask")
        let aliased: (Bool, Bool, NSEvent.ModifierFlags, NSDragOperation, Bool) -> NSDragOperation = BrowserDragDropController.operation
        try require(aliased(true, true, .control, [.copy, .move], true) == .copy
            && aliased(false, false, .control, .copy, true) == .copy, "Explorer Control-drag did not request Copy")
        try require(aliased(true, true, .control, .every, false).isEmpty
            && aliased(true, true, [.control, .shift], .every, true).isEmpty
            && aliased(true, true, [.control, .command], .every, true).isEmpty
            && aliased(true, true, .control, .move, true).isEmpty,
            "Control aliases weakened Mac, Link, contradictory-modifier or source-mask refusal")
        try require(!BrowserDragDropController.validURLs([URL(string: "https://example.invalid/generated")!]),
                    "Remote URL passed file URL admission")
        try require(!BrowserDragDropController.validURLs(Array(repeating: first, count: 129)),
                    "Unbounded/duplicate drag payload was admitted")

        browser.navigate(to: .directory(root)); try await settled(browser)
        guard let sourceRow = browser.rowsByURL[first], let targetRow = browser.rowsByURL[target] else {
            throw Failure(message: "Generated drag rows are missing")
        }
        browser.table.deselectAll(nil)
        coordinator.selectionDidChange(); coordinator.selectionDidChange()
        try await waitUntil("Off-main source and destination drag prewarm") {
            !coordinator.verificationState.preparing && coordinator.verificationState.readyTargets >= 2
        }
        // Native mouse tracking may request the row writer in the same turn as
        // selection changes. No async preparation/yield is allowed in between.
        browser.table.selectRowIndexes(IndexSet(integer: sourceRow), byExtendingSelection: false)
        coordinator.selectionDidChange()
        try require(coordinator.pasteboardWriter(for: sourceRow) != nil,
                    "First selection of an already visible row has no immediate file URL writer")
        try require(coordinator.pasteboardWriter(for: targetRow) == nil,
                    "Writer leaked an unselected row into the drag")
        try require(coordinator.registerSourceForVerification(sequence: 731), "Generated internal registry was not ready")
        try require(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target),
                    "Cached same-app Move was not admitted")
        try require(admissions.last?.move == true && admissions.last?.sources == [first]
                    && admissions.last?.destination == target, "Internal request lost captured URLs or volume policy")
        try require(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target,
                    moveModifier: .option), "Option Copy was not admitted")
        try require(admissions.last?.move == false, "Option request became Move")
        let beforeControl = admissions.count
        let controlAdmitted = await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target,
            moveModifier: .control)
        try require(controlAdmitted == browser.settings.behavior.controlAliasesEnabled,
            "Prepared Control-drag did not follow the active alias preference")
        if controlAdmitted {
            try require(admissions.count == beforeControl + 1 && admissions.last?.move == false
                && admissions.last?.sources == [first] && admissions.last?.destination == target,
                "Prepared Control Copy lost its captured source/destination or became Move")
        }
        try require(!(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target,
                    moveModifier: [.option, .command])), "Link request entered the operation engine")
        let held = admissions[0]
        coordinator.endSourceForVerification()
        try require(!(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target)),
                    "An ended source retained internal Move authority")
        try require(held.sources == [first] && held.observation.urls.contains(first),
                    "Ending source session invalidated an already accepted job snapshot")
        for sequence in 740..<744 {
            try require(coordinator.registerSourceForVerification(sequence: sequence), "Repeated source did not register")
            coordinator.endSourceForVerification(sequence: sequence - 1)
            try require(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target),
                        "Late previous end callback disabled the current source session")
            coordinator.endSourceForVerification(sequence: sequence)
            coordinator.endSourceForVerification(sequence: sequence)
            try require(!(await coordinator.dropForVerification(from: coordinator, urls: [first], destination: target))
                        && coordinator.pasteboardWriter(for: sourceRow) != nil,
                        "Cancelled/duplicate end retained source authority or disabled the next drag writer")
        }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([first as NSURL])
        let external = FixtureDraggingInfo(board: board, source: nil, sequence: 912, allowed: .copy)
        try await verifyPendingExternalDrop(browser, board: board, source: first, target: target, targetRow: targetRow, output: output)
        let sidebarLifecycleCallbacks = try await verifySidebarDragCompletion(browser, board: board,
            targetRow: targetRow, sourceRow: sourceRow)
        _ = coordinator.validateDrop(external, row: targetRow, operation: .on)
        try await waitUntil("External generated URL observation") { coordinator.verificationState.external }
        if !NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.control) {
            try require(coordinator.validateDrop(external, row: targetRow, operation: .on) == .copy,
                        "Native destination callback did not negotiate external Copy")
            try require(coordinator.acceptDrop(external, row: targetRow, operation: .on),
                        "Native destination callback did not admit captured external URLs")
            try require(admissions.last?.move == false, "External callback requested source retirement")
            let acceptedCount = admissions.count
            let duplicateAccepted = coordinator.acceptDrop(external, row: targetRow, operation: .on)
            if duplicateAccepted || admissions.count != acceptedCount {
                lifecycleFailures.append("Repeated native perform callback admits the same external drag twice")
            }
        }
        coordinator.draggingExited()
        try require(!coordinator.verificationState.external, "Exited external observation was not released")
        let reentrant = FixtureDraggingInfo(board: board, source: nil, sequence: 914, allowed: .copy)
        _ = coordinator.validateDrop(reentrant, row: targetRow, operation: .on)
        try await waitUntil("Reentrant external fixture observation") { coordinator.verificationState.external }
        var refuseNext = true, nestedAccepted = true
        let ordinaryAdmission = coordinator.hooks.admit
        coordinator.hooks.admit = { request in
            if refuseNext { refuseNext = false; return false }
            nestedAccepted = coordinator.acceptDrop(reentrant, row: targetRow, operation: .on)
            admissions.append(request)
            return true
        }
        try require(!coordinator.acceptDrop(reentrant, row: targetRow, operation: .on),
                    "Refused native admission was reported as accepted")
        let countBeforeRetry = admissions.count
        try require(coordinator.acceptDrop(reentrant, row: targetRow, operation: .on)
                    && !nestedAccepted && admissions.count == countBeforeRetry + 1,
                    "Native admission could not retry after refusal or re-entered the same session")
        try require(!coordinator.acceptDrop(reentrant, row: targetRow, operation: .on)
                    && admissions.count == countBeforeRetry + 1,
                    "Accepted native session retained duplicate admission authority")
        board.clearContents(); board.writeObjects([first as NSURL])
        _ = coordinator.validateDrop(reentrant, row: targetRow, operation: .on)
        try await waitUntil("Accepted session pasteboard revision observation") { coordinator.verificationState.external }
        try require(!coordinator.acceptDrop(reentrant, row: targetRow, operation: .on)
                    && admissions.count == countBeforeRetry + 1,
                    "Changed pasteboard revision gave an already accepted native session another admission")
        coordinator.hooks.admit = ordinaryAdmission
        coordinator.draggingExited()
        // A fresh drag with the same pasteboard is a new session. Cancellation
        // and a rejected target must not poison the next incoming Copy.
        for sequence in 920..<924 {
            let repeated = FixtureDraggingInfo(board: board, source: nil, sequence: sequence, allowed: .copy)
            _ = coordinator.validateDrop(repeated, row: sourceRow, operation: .on)
            try require(!coordinator.acceptDrop(repeated, row: sourceRow, operation: .on),
                        "Rejected file target admitted a transfer")
            _ = coordinator.validateDrop(repeated, row: targetRow, operation: .on)
            try await waitUntil("Repeated external source prepares after exit/rejection") { coordinator.verificationState.external }
            coordinator.draggingExited()
            try require(!coordinator.verificationState.external && coordinator.pasteboardWriter(for: sourceRow) != nil,
                        "Cancelled external session disabled the next source drag")
        }
        board.clearContents()
        board.setString("generated promise without real file URL", forType: NSPasteboard.PasteboardType("com.apple.filepromise"))
        let promise = FixtureDraggingInfo(board: board, source: nil, sequence: 913)
        try require(coordinator.validateDrop(promise, row: targetRow, operation: .on).isEmpty,
                    "Promise-only pasteboard was accepted")
        try require(!(await coordinator.dropForVerification(from: nil, urls: [link], destination: target, allowed: .copy)),
                    "Source symbolic link was accepted by the external preparation path")

        // Yield between navigation and completion. Old cached targets cannot
        // acquire a new visit's authority, even when paths later happen to match.
        browser.navigate(to: .directory(target))
        try await settled(browser)
        coordinator.selectionDidChange()
        try require(!(await coordinator.dropForVerification(from: nil, urls: [first], destination: root, allowed: .copy)),
                    "Old visit target survived navigation")
        try require(try Data(contentsOf: first) == Data("generated drag source".utf8)
                    && !FileManager().fileExists(atPath: target.appendingPathComponent("source.txt").path),
                    "Injected drag verification mutated a source or destination")

        // A scrollbar changes clip-view bounds without sending a scrollWheel
        // event to the table or selecting a row. Prepare the newly visible rows
        // before their first synchronous native selection/drag-writer request.
        let scrollRoot = root.appendingPathComponent("Scroll fixture", isDirectory: true)
        try FileManager().createDirectory(at: scrollRoot, withIntermediateDirectories: false)
        for index in 0..<96 {
            try Data("generated scrollbar drag fixture".utf8).write(
                to: scrollRoot.appendingPathComponent(String(format: "scroll-%03d.txt", index)),
                options: .withoutOverwriting)
        }
        browser.navigate(to: .directory(scrollRoot)); try await settled(browser)
        let last = scrollRoot.appendingPathComponent("scroll-095.txt")
        guard let lastRow = browser.rowsByURL[last] else { throw Failure(message: "Scrollbar fixture row is missing") }
        browser.table.deselectAll(nil)
        try await waitUntil("Initial scrollbar fixture cache") { !coordinator.verificationState.preparing }
        try require(!coordinator.hasPreparedObjectForVerification(last), "Scrollbar regression needs a row outside the initial viewport")
        let clip = browser.folderScroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: browser.table.rect(ofRow: lastRow).minY))
        browser.folderScroll.reflectScrolledClipView(clip)
        try await waitUntil("Bounds-only scroll prepares newly visible drag rows") {
            coordinator.hasPreparedObjectForVerification(last) && !coordinator.verificationState.preparing
        }
        browser.table.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        try require(coordinator.pasteboardWriter(for: lastRow) != nil,
                    "First click-drag after a bounds-only scroll has no immediate writer")
        // Browser suspension drops the observation. A later active refresh must
        // reinstall it, and repeated refreshes must retain a single observer.
        coordinator.windowWillClose()
        coordinator.selectionDidChange(); coordinator.selectionDidChange()
        try await waitUntil("Resumed scrollbar fixture cache") { coordinator.hasPreparedObjectForVerification(last) }
        browser.table.deselectAll(nil)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -clip.contentInsets.top))
        browser.folderScroll.reflectScrolledClipView(clip)
        let initial = scrollRoot.appendingPathComponent("scroll-000.txt")
        try await waitUntil("Reinstalled bounds observation prepares first rows") {
            coordinator.hasPreparedObjectForVerification(initial) && !coordinator.verificationState.preparing
        }
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        try require(lifecycleFailures.isEmpty, lifecycleFailures.joined(separator: "; "))
        let checks = [
            "Cached same-filesystem Move/cross-filesystem Copy and Option/Command negotiation; Explorer Control-copy honors the alias choice and source mask, while unsupported Link/external Move are rejected",
            "Real file URL row writer; opaque actual-source registry; accepted snapshot survives native source end",
            "Repeated private-pasteboard source/external sessions survive exit, rejected targets and stale end callbacks; native admission rejects duplicate/reentrant callbacks and retries refused admission",
            "Generated destination callbacks and async preparation; promises, links and stale visits rejected; collection views retain AppKit's native mouseDown gesture support",
            "Bounds-only scrollbar scrolling prewarms new rows for immediate first click-drag; observation reinstalls after suspension",
            "Sidebar native draggingEnded selector clears destination state and callback once; repeated enter/end and exit/end preserve the next drag writer",
            "Cold external Copy enters the actual queued Preparing stage once; cancellation drains and fresh sequences survive, while substituted destinations and unsupported inputs fail before transfer",
            "Prepared drag admission is injected; deferred Copy validates through the actual owned queue with a generated destination substitution; no Finder transfer or external application"
        ]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "admittedRequests": admissions.count,
            "sidebarNativeLifecycleCallbacks": sidebarLifecycleCallbacks,
            "sidebarNativeDragEndDispatchExercised": true,
            "finderTransferExercised": false, "nativeDragSessionExercised": false,
            "generatedDestinationSubstitutionExercised": true, "transferPerformed": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("drag-drop-verification.json"))
        return checks
    }
}
#endif
