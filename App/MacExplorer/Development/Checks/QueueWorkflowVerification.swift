#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations

/// Actual engine operations on marked generated fixtures, with private clipboard
/// and controlled prompt gates. No Finder delivery or power-loss claim is made.
@MainActor
enum QueueWorkflowVerification {
    static func run(in testRoot: URL, output: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Queue verification requires its explicit unredirected disposable root")
        }
        let coordinator = ApplicationOperationCoordinator.shared
        let queue = coordinator.transfers
        try require(!queue.hasOutstandingWork && coordinator.activeOwner == nil, "Queue fixture requires idle operation ownership")
        _ = queue.resume()
        let owned = testRoot.appendingPathComponent("transfer-queue-\(UUID().uuidString)", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-queue-verification-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        }.value
        let board = NSPasteboard.withUniqueName()
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        let primary = BrowserViewController(settings: settings)
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        primary.transferPasteboard = board
        primary.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        primary.recoverableFileOperations = engine
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.browser = primary; window.workspace = workspace
        workspace.onActiveBrowserChanged = { [weak window] in window?.browser = $0 }
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 1300, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        var initialBeginFinished = false
        primary.didFinishBeginForVerification = { initialBeginFinished = true }
        workspace.startBrowser(primary)
        primary.operationResultPresenter = { _ in }
        primary.operationErrorPresenter = { _ in }
        let state = RunState()
        let context = RunContext(coordinator: coordinator, queue: queue, owned: owned,
            board: board, settings: settings, primary: primary, engine: engine,
            workspace: workspace, window: window, output: output, state: state)
        defer {
            queue.beforeAdmissionObservationReturnsForVerification = nil
            workspace.isClosing = true
            workspace.browsers.values.forEach { $0.suspendBrowser() }
            window.orderOut(nil); window.close(); board.releaseGlobally()
        }
        do {
            try await waitUntil("Queue initial browser startup") { initialBeginFinished }
            primary.didFinishBeginForVerification = nil
            try await verifyPresentationBurst(workspace, primary: primary, fixture: owned)
            state.checks.append("queuePresentationBurst")
            let moved = try await verifyFIFO(context)
            let host = workspace.activeBrowser
            try await verifyRetiredOriginRecovery(context, host: host, moved: moved)
            try await verifySourceReplacement(context, host: host)
            try await verifyStopAndClipboard(context, host: host)
            try await verifyNativeSheets(context, host: host)
            try await verifyDestinationReplacement(context, host: host)
            try await verifyPartialCopy(context, host: host)
            let admission = try await beginAdmissionReview(context, host: host)
            let oldQueueInspector = TransferQueueInspectionView(frame: NSRect(origin: .zero, size: OperationProgressDetailsView.cardSize))
            let oldQueueWindow = NSWindow(contentRect: oldQueueInspector.frame, styleMask: [], backing: .buffered, defer: false)
            oldQueueWindow.isReleasedWhenClosed = false
            oldQueueWindow.contentView = oldQueueInspector
            defer { oldQueueWindow.orderOut(nil); oldQueueWindow.close() }
            try await finishAdmissionReview(context, host: host, admission: admission, oldQueueInspector: oldQueueInspector)
            try await verifyGuardedResultActions(context, host: host)
            try await verifyCapturedPolicies(context, host: host)
            try await verifyAdmissionCancellation(context, host: host)
        } catch {
            state.gates.forEach { $0.release() }
            queue.beforeAdmissionObservationReturnsForVerification = nil
            queue.stopActive(); queue.cancelAllWaiting()
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            try? await waitUntil("Failed queue fixture cleanup drain") { !queue.hasOutstandingWork }
            throw error
        }
        _ = queue.resume()
        return state.checks
    }

    /// Queue-only state; checks and prompt gates survive any extracted phase throwing.
    @MainActor private final class RunState {
        var gates: [Gate] = []
        var checks: [String] = []
    }
    @MainActor private struct RunContext {
        let coordinator: ApplicationOperationCoordinator
        let queue: ApplicationTransferQueue
        let owned: URL
        let board: NSPasteboard
        let settings: BrowserSettings
        let primary: BrowserViewController
        let engine: RecoverableFileOperations
        let workspace: BrowserWorkspaceController
        let window: BrowserWindow
        let output: URL
        let state: RunState
    }
    @MainActor private struct AdmissionReviewPhase {
        let phase: Phase
        let missing: UUID
    }

    private static func admit(_ context: RunContext, _ phase: Phase, _ name: String, origin: BrowserViewController,
                   move: Bool = false, clipboard: MoveClipboardContext? = nil,
                   retaining access: FileAccessLifetimes? = nil, chooseMetadata: Bool = false) throws -> UUID {
            let queue = context.queue, engine = context.engine
            guard let id = queue.enqueue(sources: [phase.source(name)], destination: phase.destination,
                move: move, title: "Generated queued \(name)", origin: origin, engine: engine,
                retaining: access, clipboard: clipboard, metadataPolicy: .strict, chooseMetadata: chooseMetadata) else {
                throw UIVerification.Failure(message: "Generated queue admission was refused: \(name)")
            }
            return id
        }
    private static func waitReady(_ context: RunContext, _ ids: [UUID]) async throws {
            let queue = context.queue
            try await waitUntil("Queued fixture observations did not become ready") {
                ids.allSatisfy { id in queue.state.waiting.contains { $0.id == id && $0.phase == .ready } }
            }
        }

    private static func verifyFIFO(_ context: RunContext) async throws -> UUID {
        let queue = context.queue
        let owned = context.owned
        let board = context.board
        let primary = context.primary
        let workspace = context.workspace
        let state = context.state
            let fifo = try await makePhase(owned, "FIFO", names: ["Hold.txt", "Copy.txt", "Canceled.txt", "Move.txt"], conflicts: ["Hold.txt"])
            primary.navigate(to: .directory(fifo.sourceDirectory))
            try await waitUntil("Queue source listing") { !primary.isLoading && primary.orderingTask == nil }
            try require(workspace.splitActive(at: .trailing), "Queue fixture could not split its window")
            let peer = workspace.activeBrowser
            peer.permitsBackgroundVerification = true
            peer.operationResultPresenter = { _ in }; peer.operationErrorPresenter = { _ in }
            let firstGate = Gate(); state.gates.append(firstGate)
            primary.transferConflictPrompt = { await firstGate.answer($0) }
            let first = try admit(context, fifo, "Hold.txt", origin: primary)
            try await waitUntil("First real queue plan did not reach conflict review") { firstGate.entered }
            // Paste starts in a destination pane, while its captured sources
            // still belong to the earlier folder. The result must name those
            // sources even after the origin pane navigates elsewhere.
            peer.navigate(to: .directory(fifo.destination))
            try await waitUntil("Queue destination-pane listing") { !peer.isLoading && peer.orderingTask == nil }
            let second = try admit(context, fifo, "Copy.txt", origin: peer)
            let canceled = try admit(context, fifo, "Canceled.txt", origin: peer)
            BrowserClipboard.write(nil, urls: [fifo.source("Move.txt")], to: board)
            primary.pendingCut = try await primary.fileOperations.observeSelection([fifo.source("Move.txt")])
            primary.pendingCutChangeCount = board.changeCount; primary.cutURLs = [fifo.source("Move.txt")]
            primary.showTransferFeedback(.move, urls: [fifo.source("Move.txt")])
            let clipboard = MoveClipboardContext(changeCount: board.changeCount, sources: [fifo.source("Move.txt")],
                operationSources: [fifo.source("Move.txt")], revision: primary.clipboardRevision)
            var retained: FolderAccessLease? = FolderAccessLease(url: owned, backend: LeaseBackend())
            let retainedProbe = LeaseProbe(retained)
            let moved = try admit(context, fifo, "Move.txt", origin: primary, move: true, clipboard: clipboard,
                                  retaining: FileAccessLifetimes(leases: [retained!]))
            retained = nil
            try await waitReady(context, [second, canceled, moved])
            try require(retainedProbe.value != nil && queue.state.active?.id == first,
                        "Waiting transfer lost access or overlapped the active engine")
            peer.showTransferQueue(nil)
            guard let capturedPause = descendantsForReview(peer.transferQueueDetails).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Pause Queue" }) else {
                throw UIVerification.Failure(message: "Active queue inspector has no native Pause Queue control")
            }
            queue.pause()
            capturedPause.performClick(nil)
            try require(queue.state.isPaused,
                        "A still-labelled Pause Queue native action resumed a queue that paused before inspector repaint")
            peer.transferQueueDetails.update(queue)
            guard let explicitResume = descendantsForReview(peer.transferQueueDetails).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Resume Queue" }) else {
                throw UIVerification.Failure(message: "Manual paused queue has no native explicit Resume action")
            }
            explicitResume.performClick(nil)
            try require(!queue.state.isPaused && queue.state.active?.id == first,
                        "A current Resume intent for a manual pause did not preserve its existing active transfer")
            peer.operationDetails.onClose?()
            try require(queue.cancelWaiting(canceled), "Waiting cancellation was refused")
            guard let feedback = primary.transferFeedback else { throw UIVerification.Failure(message: "Queued Move feedback missing") }
            let nativeBeforeDismiss = ClipboardSnapshot(board)
            try require(primary.clipboardState.dismiss(feedbackID: feedback.id), "Queued Move app dismissal failed")
            let retiredResume = primary.transferQueueDetails.onPauseOrResume
            workspace.activate(primary)
            try require(workspace.closeActivePane() && primary.isBrowserSuspended,
                        "Origin pane cannot close independently of accepted jobs")
            try require(queue.state.active?.id == first && queue.hasOutstandingWork,
                        "Pane closure canceled application-owned queue work")
            queue.pause()
            retiredResume?(true, nil)
            try require(queue.state.isPaused, "A retired pane's delayed Resume callback retained queue authority")
            try require(queue.resume(), "Live fixture host could not resume after rejecting retired pane authority")
            firstGate.release()
            try await waitUntil("FIFO copies/move did not settle") { !queue.hasOutstandingWork }
            let expected = [first, second, moved]
            try require(queue.results.filter { expected.contains($0.id) }.map(\.id) == expected,
                        "Real transfer completion order violated FIFO")
            try require(queue.results.filter { expected.contains($0.id) }.allSatisfy {
                $0.originDescription == fifo.sourceDirectory.lastPathComponent
            }, "Queued source label came from the destination/origin pane instead of captured sources")
            try require(!queue.results.contains { $0.id == canceled } && !queue.state.isPaused,
                        "Waiting cancellation created an execution result or paused clean FIFO advancement")
            try await requireBytes(fifo.target("Copy.txt"), expected: fifo.bytes("Copy.txt"))
            try await requireBytes(fifo.target("Move.txt"), expected: fifo.bytes("Move.txt"))
            try require(!FileManager().fileExists(atPath: fifo.source("Move.txt").path)
                        && !FileManager().fileExists(atPath: fifo.target("Canceled.txt").path)
                        && ClipboardSnapshot(board) == nativeBeforeDismiss && retainedProbe.value == nil,
                        "Queued Move changed a dismissed native clipboard, canceled job wrote, or access outlived drain")
            state.checks.append("Real gated FIFO Copy/Move jobs retain access, cancel waiting jobs without writes, survive origin-pane closure, reject retired Resume authority and preserve dismissed private clipboard bytes")
        return moved
    }

    private static func verifyRetiredOriginRecovery(_ context: RunContext, host: BrowserViewController, moved: UUID) async throws -> Void {
        let queue = context.queue
        let primary = context.primary
        let window = context.window
        let state = context.state
            guard let retiredOriginResult = queue.results.first(where: { $0.id == moved }),
                  let retiredOriginRecord = retiredOriginResult.outcome.recordID else {
                throw UIVerification.Failure(message: "Retired-origin transfer did not retain its recovery record")
            }
            queue.showResult(moved, in: host)
            guard let retiredSheet = window.attachedSheet,
                  let recoveryAction = descendantsForReview(retiredSheet.contentView ?? NSView()).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Open Recovery" }) else {
                throw UIVerification.Failure(message: "Retired-origin queued result has no reachable Open Recovery action")
            }
            try require(recoveryAction.isEnabled && host.canRunExclusiveFileCommand,
                        "Retired-origin Recovery action was disabled before its native click")
            recoveryAction.performClick(nil)
            try await waitUntil("Retired-origin result sheet did not close for Recovery") { window.attachedSheet == nil }
            try await waitUntil("Retired-origin Recovery action did not reach a live controller") { host.recoveryWindow != nil }
            await host.recoveryInspectionTask?.value
            try require(host.recoveryWindow?.selectedRecordID == retiredOriginRecord
                        && primary.isBrowserSuspended && !host.hasExclusiveBrowserOperation,
                        "Open Recovery selected an unrelated job or depended on the retired origin pane; selected=\(String(describing: host.recoveryWindow?.selectedRecordID)), expected=\(retiredOriginRecord), controller=\(host.recoveryWindow != nil), exclusive=\(host.hasExclusiveBrowserOperation), retired=\(primary.isBrowserSuspended), readOnly=\(host.isReadOnlyFileSession), live=\(!host.isBrowserSuspended), task=\(host.recoveryInspectionTask != nil), records=\(host.recoveryRecords.count)")
            host.recoveryWindow?.close()
            state.checks.append("A queued result survives origin-pane retirement and Open Recovery selects its exact record through the surviving host without starting recovery")
    }

    private static func verifySourceReplacement(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let coordinator = context.coordinator
        let queue = context.queue
        let owned = context.owned
        let window = context.window
        let state = context.state
            let stale = try await makePhase(owned, "Replacement", names: ["Hold.txt", "Changed.txt", "Late conflict.txt", "Later.txt"], conflicts: ["Hold.txt"])
            let staleGate = Gate(); state.gates.append(staleGate)
            var lateConflicts = 0
            // Exercise actual automatic presentation for failures/Stop, rather
            // than hiding a modal regression behind the generic presenter seam.
            host.operationResultPresenter = nil
            host.transferConflictPrompt = { conflicts in
                if conflicts.contains(where: { $0.source.lastPathComponent == "Hold.txt" }) { return await staleGate.answer(conflicts) }
                lateConflicts += 1
                return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) })
            }
            _ = try admit(context, stale, "Hold.txt", origin: host)
            try await waitUntil("Replacement hold prompt") { staleGate.entered }
            let changed = try admit(context, stale, "Changed.txt", origin: host)
            let conflict = try admit(context, stale, "Late conflict.txt", origin: host)
            let later = try admit(context, stale, "Later.txt", origin: host)
            try await waitReady(context, [changed, conflict, later])
            try await Task.detached {
                try FileManager().moveItem(at: stale.source("Changed.txt"), to: stale.sourceDirectory.appendingPathComponent("Retained old occupant"))
                try stale.bytes("Changed.txt").write(to: stale.source("Changed.txt"), options: .withoutOverwriting)
                try Data("new conflict created while queued".utf8).write(to: stale.target("Late conflict.txt"), options: .withoutOverwriting)
            }.value
            staleGate.release()
            try await waitUntil("Changed source did not pause queue") { queue.state.isPaused && queue.state.active == nil }
            try require(window.attachedSheet == nil,
                        "A failed queued transfer automatically opened Results instead of in-window attention")
            host.refreshStatus()
            try require(!host.operationResultsButton.isHidden && host.operationResultsButton.isEnabled
                        && host.operationResultsButton.title == "Needs attention",
                        "The paused transfer lost persistent attention after its folder status refreshed")
            try require(queue.results.first(where: { $0.id == changed })?.outcome.result.items.contains(where: { $0.status == .failed(.sourceChanged) }) == true
                        && !FileManager().fileExists(atPath: stale.target("Changed.txt").path)
                        && !FileManager().fileExists(atPath: stale.target("Later.txt").path),
                        "Replaced source inherited old intent or later queued writes bypassed failure review")
            try await verifyPausedSheet(queue, id: changed, browser: host)
            let exclusive = UUID()
            try require(coordinator.begin(owner: exclusive) && !queue.resume(), "Paused queue did not serialize exclusive recovery ownership")
            queue.showResult(changed, in: host)
            try require(window.attachedSheet == nil, "Queue result actions opened while exclusive recovery owned the writer lane")
            coordinator.finish(owner: exclusive)
            try require(queue.state.isPaused && queue.state.active == nil, "Exclusive completion silently resumed queued writes")
            try require(queue.resume(), "Explicit queue resume failed")
            try await waitUntil("Resumed queue did not finish") { !queue.hasOutstandingWork }
            try require(lateConflicts == 1 && queue.results.contains { $0.id == conflict } && queue.results.contains { $0.id == later },
                        "Start-time destination conflict was not reviewed before later work")
            try await requireBytes(stale.target("Late conflict.txt"), expected: Data("new conflict created while queued".utf8))
            state.checks.append("Equal-byte replacement fails source identity at start; queue pauses, exclusive recovery stays serialized, and newly created destination conflicts receive fresh review")
    }

    private static func verifyStopAndClipboard(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let board = context.board
        let state = context.state
            let stopped = try await makePhase(owned, "Stop", names: ["Hold.txt", "Newer clipboard Move.txt"], conflicts: ["Hold.txt"])
            let stopGate = Gate(); state.gates.append(stopGate)
            host.transferConflictPrompt = { await stopGate.answer($0) }
            let stopping = try admit(context, stopped, "Hold.txt", origin: host)
            try await waitUntil("Stop hold prompt") { stopGate.entered }
            BrowserClipboard.write(nil, urls: [stopped.source("Newer clipboard Move.txt")], to: board)
            let oldContext = MoveClipboardContext(changeCount: board.changeCount, sources: [stopped.source("Newer clipboard Move.txt")],
                operationSources: [stopped.source("Newer clipboard Move.txt")], revision: host.clipboardRevision)
            let waitingMove = try admit(context, stopped, "Newer clipboard Move.txt", origin: host, move: true, clipboard: oldContext)
            try await waitReady(context, [waitingMove])
            BrowserClipboard.write("newer private clipboard remains", urls: [], to: board)
            let newerClipboard = ClipboardSnapshot(board)
            queue.stopActive()
            try require(queue.state.isPaused && queue.state.active?.id == stopping && queue.state.active?.stopRequested == true
                        && !queue.resume(), "Stop released active ownership before controlled prompt drain")
            stopGate.release()
            try await waitUntil("Stopped prompt did not drain") { queue.state.active == nil }
            try require(queue.state.isPaused && queue.state.waiting.map(\.id) == [waitingMove]
                        && !FileManager().fileExists(atPath: stopped.target("Newer clipboard Move.txt").path),
                        "Stop advanced waiting work automatically")
            try await verifyPausedSheet(queue, id: stopping, browser: host)
            try require(queue.resume(), "Stopped queue could not explicitly resume")
            try await waitUntil("Move with newer clipboard did not complete") { !queue.hasOutstandingWork }
            try await requireBytes(stopped.target("Newer clipboard Move.txt"), expected: stopped.bytes("Newer clipboard Move.txt"))
            try require(ClipboardSnapshot(board) == newerClipboard, "Older queued Move cleared a newer native clipboard")
            state.checks.append("Stop pauses before controlled prompt drain; later jobs require explicit resume and an older queued Move preserves newer private clipboard data")
    }

    private static func verifyNativeSheets(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let window = context.window
        let state = context.state
            // The real queue-owned NSAlert must end on Stop. An unrelated sheet
            // instead delays metadata choice, and remains owned by its caller.
            let native = try await makePhase(owned, "Native sheets", names: ["Hold.txt", "Options.txt"], conflicts: ["Hold.txt"])
            host.transferConflictPrompt = nil; host.transferMetadataPrompt = nil
            _ = try admit(context, native, "Hold.txt", origin: host)
            try await waitUntil("Native queue conflict sheet did not attach") { window.attachedSheet != nil }
            queue.stopActive()
            try await waitUntil("Native queue-owned sheet did not stop/drain") { window.attachedSheet == nil && queue.state.active == nil }
            try require(queue.state.isPaused, "Native prompt Stop did not pause queue")
            _ = queue.resume()
            let unrelated = NSAlert(); unrelated.messageText = "Generated unrelated sheet"
            unrelated.addButton(withTitle: "Done")
            unrelated.beginSheetModal(for: window) { _ in }
            let options = try admit(context, native, "Options.txt", origin: host, chooseMetadata: true)
            try await waitUntil("Metadata job did not reach active head") { queue.state.active?.id == options }
            try require(window.attachedSheet === unrelated.window && !queue.results.contains { $0.id == options },
                        "Busy prompt host silently canceled metadata admission or replaced an unrelated sheet")
            window.endSheet(unrelated.window, returnCode: .alertFirstButtonReturn)
            try await waitUntil("Metadata prompt did not attach after unrelated sheet") { window.attachedSheet != nil && window.attachedSheet !== unrelated.window }
            guard let metadataSheet = window.attachedSheet else { throw UIVerification.Failure(message: "Metadata sheet missing") }
            window.endSheet(metadataSheet, returnCode: .alertFirstButtonReturn)
            try await waitUntil("Metadata job did not finish") { !queue.hasOutstandingWork }
            try await requireBytes(native.target("Options.txt"), expected: native.bytes("Options.txt"))
            state.checks.append("Native queue-owned conflict sheet ends on Stop; a metadata job waits behind another owner's sheet and proceeds only after its explicit choice")
    }

    private static func verifyDestinationReplacement(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let state = context.state
            let replacedDestination = try await makePhase(owned, "Destination replacement", names: ["Preserved.txt"], conflicts: [])
            queue.pause()
            let destinationJob = try admit(context, replacedDestination, "Preserved.txt", origin: host)
            try await waitReady(context, [destinationJob])
            let retainedDestination = replacedDestination.destination.deletingLastPathComponent().appendingPathComponent("Retained original destination", isDirectory: true)
            try await Task.detached {
                try FileManager().moveItem(at: replacedDestination.destination, to: retainedDestination)
                try FileManager().createDirectory(at: replacedDestination.destination, withIntermediateDirectories: false)
            }.value
            try require(queue.resume(), "Destination-replacement queue could not resume")
            try await waitUntil("Replacement destination did not pause queue") { queue.state.isPaused && queue.state.active == nil }
            try require(queue.results.first(where: { $0.id == destinationJob })?.outcome.result.items.contains(where: { $0.status == .failed(.destinationChanged) }) == true
                        && !FileManager().fileExists(atPath: replacedDestination.target("Preserved.txt").path),
                        "A replacement destination directory inherited admitted write authority")
            try await requireBytes(replacedDestination.source("Preserved.txt"), expected: replacedDestination.bytes("Preserved.txt"))
            _ = queue.resume()
            state.checks.append("Replacing an observed destination directory before its turn refuses publication and preserves the generated source")
    }

    private static func verifyPartialCopy(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let engine = context.engine
        let workspace = context.workspace
        let window = context.window
        let output = context.output
        let state = context.state
            // Deliberately overlapping generated namespaces: replacing the
            // first destination retains the original folder, then invalidates
            // the second source's captured parent. This produces a real partial
            // result deterministically, without timing or a synthetic result.
            let partial = try await makePhase(owned, "Overlapping partial", names: ["Later.txt"], conflicts: [])
            let sourceContainer = partial.sourceDirectory.appendingPathComponent("Container", isDirectory: true)
            let oldContainer = partial.destination.appendingPathComponent("Container", isDirectory: true)
            let nestedName = "Second.txt"
            let originalBytes = Data("Generated original subtree".utf8)
            let replacementBytes = Data("Generated replacement subtree".utf8)
            try await Task.detached {
                try FileManager().createDirectory(at: sourceContainer, withIntermediateDirectories: false)
                try FileManager().createDirectory(at: oldContainer, withIntermediateDirectories: false)
                try replacementBytes.write(to: sourceContainer.appendingPathComponent(nestedName), options: .withoutOverwriting)
                try originalBytes.write(to: oldContainer.appendingPathComponent(nestedName), options: .withoutOverwriting)
            }.value
            try require(workspace.splitActive(at: .trailing), "Partial review could not create its disposable origin pane")
            let partialOrigin = workspace.activeBrowser
            partialOrigin.permitsBackgroundVerification = true
            partialOrigin.operationResultPresenter = nil
            partialOrigin.transferConflictPrompt = { conflicts in Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .replace) }) }
            guard let partialJob = queue.enqueue(sources: [sourceContainer, oldContainer.appendingPathComponent(nestedName)],
                destination: partial.destination, move: false, title: "Generated overlapping partial Copy", origin: partialOrigin,
                engine: engine, metadataPolicy: .strict) else {
                throw UIVerification.Failure(message: "Partial review fixture admission was refused")
            }
            try await waitUntil("Overlapping partial Copy did not reach protected review") { queue.state.active == nil && queue.reviewResultID == partialJob }
            guard let partialResult = queue.reviewResult else { throw UIVerification.Failure(message: "Partial result was not retained") }
            try require(partialResult.outcome.result.disposition == .partial
                        && !partialResult.outcome.result.cancellationRequested && partialResult.outcome.recordID != nil
                        && partialResult.outcome.result.items.contains { $0.source == sourceContainer && $0.status == .succeeded }
                        && partialResult.outcome.result.items.contains { $0.source == oldContainer.appendingPathComponent(nestedName) && $0.status == .failed(.sourceChanged) }
                        && window.attachedSheet == nil && !FileManager().fileExists(atPath: partial.target(nestedName).path),
                        "Real partial Copy hid its failure, opened Results automatically or published the invalidated source")
            guard let displaced = partialResult.outcome.result.items.flatMap(\.recoveryURLs).first(where: {
                $0.lastPathComponent == "displaced" && $0.deletingLastPathComponent().deletingLastPathComponent() == partial.destination
            }) else { throw UIVerification.Failure(message: "Partial Copy did not expose its generated retained original") }
            try await requireBytes(displaced.appendingPathComponent(nestedName), expected: originalBytes)
            try await requireBytes(sourceContainer.appendingPathComponent(nestedName), expected: replacementBytes)
            try await requireBytes(oldContainer.appendingPathComponent(nestedName), expected: replacementBytes)
            try require(workspace.closeLastTab(in: partialOrigin) && partialOrigin.isBrowserSuspended
                        && workspace.activeBrowser === host && queue.reviewResultID == partialJob,
                        "Retiring the partial transfer's origin lost or changed its pinned review")
            let afterPartial = try admit(context, partial, "Later.txt", origin: host)
            try await waitReady(context, [afterPartial])
            try openAttentionCard(queue, id: partialJob, browser: host, reviewEnabled: true)
            try await UIVerification.snapshot(window, to: output.appendingPathComponent("queue-attention-partial.png"))
            host.transferQueueDetails.onClose?()
            try await verifyPausedSheet(queue, id: partialJob, browser: host)
            try require(queue.state.waiting.map(\.id) == [afterPartial] && queue.resume(), "Partial review could not explicitly resume only later work")
            try await waitUntil("Later work did not finish after partial review") { !queue.hasOutstandingWork }
            host.validateNavigationButtons()
            try require(queue.reviewResultID == nil && host.operationResultsButton.title == "Results"
                        && queue.results.first(where: { $0.id == partialJob })?.outcome.recordID == partialResult.outcome.recordID
                        && !FileManager().fileExists(atPath: partial.target(nestedName).path),
                        "Resume retained stale attention or retried/discarded the protected partial job")
            try await requireBytes(partial.target("Later.txt"), expected: partial.bytes("Later.txt"))
            state.checks.append("Real overlapping-namespace partial Copy stays quiet, retains both trees and its exact recovery record across origin-pane closure; explicit Resume starts only later work and clears attention")
    }

    private static func beginAdmissionReview(_ context: RunContext, host: BrowserViewController) async throws -> AdmissionReviewPhase {
        let queue = context.queue
        let owned = context.owned
        let settings = context.settings
        let engine = context.engine
        let window = context.window
        let output = context.output
        let state = context.state
            let review = try await makePhase(owned, "Admission review", names: ["Hold.txt", "After review.txt", "After newer review.txt"], conflicts: ["Hold.txt"])
            let reviewGate = Gate(); state.gates.append(reviewGate)
            host.transferConflictPrompt = { await reviewGate.answer($0) }
            let cleanActive = try admit(context, review, "Hold.txt", origin: host)
            try await waitUntil("Admission-review hold prompt") { reviewGate.entered }
            let missing = try admit(context, review, "Missing.txt", origin: host)
            let afterReview = try admit(context, review, "After review.txt", origin: host)
            try await waitUntil("Later admission failure did not pause active queue") {
                queue.state.isPaused && queue.reviewResultID == missing && queue.state.active?.id == cleanActive
            }
            try await waitReady(context, [afterReview])
            try require(window.attachedSheet == nil,
                        "An admission failure interrupted the active transfer with an automatic Results sheet")
            try openAttentionCard(queue, id: missing, browser: host, reviewEnabled: false)
            try require(queue.state.active?.id == cleanActive
                        && queue.presentation?.queueSummary?.contains("Needs attention") == true,
                        "Inspecting attention changed the active job or hid the paused cause from progress")
            try await UIVerification.snapshot(window, to: output.appendingPathComponent("queue-attention-active.png"))
            host.transferQueueDetails.onClose?()
            do {
                // The generic presenter seam suppresses native sheets. Exercise
                // the actual completion→presentation path for this ordering.
                let previousPresenter = host.operationResultPresenter
                let previousStatusObserver = host.queuedTransferStatusPresentedForVerification
                defer {
                    host.operationResultPresenter = previousPresenter
                    host.queuedTransferStatusPresentedForVerification = previousStatusObserver
                }
                // Listing refresh may restore the item count before idle is
                // observed. Capture the real completion message at delivery;
                // this observer neither suppresses nor replaces presentation.
                var completionStatus: String?
                host.queuedTransferStatusPresentedForVerification = { id, text in
                    if id == cleanActive { completionStatus = text }
                }
                host.operationResultPresenter = nil
                reviewGate.release()
                try await waitUntil("Earlier clean job did not drain after admission failure") { queue.state.active == nil }
                try require(window.attachedSheet == nil,
                            "A successful queued transfer automatically reopened the older pinned review")
                guard let completed = queue.results.first(where: { $0.id == cleanActive }) else {
                    throw UIVerification.Failure(message: "Clean completion result disappeared before status inspection")
                }
                let completionSummary = OperationResultDescription(result: completed.outcome.result).summary
                let showsLatest = completionStatus?.hasPrefix("Latest transfer: \(completionSummary)") == true
                let showsAttention = completionStatus?.contains("Another transfer needs attention") == true
                try require(showsLatest && showsAttention
                            && host.lastOperationResult?.disposition == .failed,
                            "Completion status confused the latest transfer with another job's pinned review: "
                                + "latest=\(showsLatest); attention=\(showsAttention); "
                                + "pinned=\(String(describing: host.lastOperationResult?.disposition)); "
                                + "statusDelivered=\(completionStatus != nil)")
            }
            try require(queue.state.isPaused && queue.reviewResultID == missing && queue.pausedSummary.contains("Missing.txt")
                        && queue.results.first(where: { $0.id == cleanActive })?.outcome.result.disposition == .succeeded
                        && queue.state.waiting.map(\.id) == [afterReview],
                        "An earlier active success hid the later admission failure requiring review")
            host.refreshStatus()
            try require(host.operationResultsButton.title == "Needs attention" && !host.operationResultsButton.isHidden,
                        "A normal listing refresh cleared pinned transfer attention")
            try verifyAttentionInEmptyWindow(queue, id: missing, settings: settings, engine: engine)
            try verifyInspector(queue, waiting: afterReview, review: missing)
        return AdmissionReviewPhase(phase: review, missing: missing)
    }

    private static func finishAdmissionReview(_ context: RunContext, host: BrowserViewController, admission: AdmissionReviewPhase, oldQueueInspector: TransferQueueInspectionView) async throws -> Void {
        let queue = context.queue
        let window = context.window
        let state = context.state
        let review = admission.phase, missing = admission.missing
            oldQueueInspector.onPauseOrResume = host.transferQueueDetails.onPauseOrResume
            oldQueueInspector.update(queue)
            guard let oldQueueResume = descendantsForReview(oldQueueInspector).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Resume Queue" }) else {
                throw UIVerification.Failure(message: "Captured review A inspector has no native Resume Queue control")
            }
            try openAttentionReview(queue, id: missing, browser: host)
            guard let reviewSheet = window.attachedSheet else {
                throw UIVerification.Failure(message: "Paused queue review did not open its native result sheet")
            }
            func reviewButtons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { reviewButtons($0) }
            }
            let reviewActions = reviewSheet.contentView.map { reviewButtons($0) } ?? []
            let hasResume = reviewActions.contains { $0.title == "Resume Queue" && $0.isEnabled }
            let hasLocations = ["Reveal Source", "Reveal Destination"].allSatisfy { title in
                reviewActions.contains { $0.title == title && $0.isEnabled }
            }
            try require(hasResume && hasLocations,
                        "Paused queue review results have no reachable Resume Queue and source/destination actions")
            let resultViews = reviewSheet.contentView.map { descendantsForReview($0) } ?? []
            try require(resultViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Missing.txt") }
                        && !reviewActions.contains { $0.title == "Continue Remaining" || $0.title == "Open Recovery" },
                        "Admission-review Results lost its captured job context or offered ungranted continuation/recovery")
            // Simulate another window's explicit Resume while review A's sheet
            // remains open, then a newer admission failure requiring review B.
            try require(queue.resume(), "Another host could not explicitly resume the reviewed queue")
            try await waitUntil("Earlier reviewed waiting job did not finish") { !queue.hasOutstandingWork }
            let newerMissing = try admit(context, review, "Missing newer.txt", origin: host)
            let afterNewerReview = try admit(context, review, "After newer review.txt", origin: host)
            try await waitUntil("Newer review failure did not become the pinned cause") { queue.reviewResultID == newerMissing && queue.state.active == nil }
            try await waitReady(context, [afterNewerReview])
            oldQueueResume.performClick(nil)
            try require(queue.state.isPaused && queue.reviewResultID == newerMissing
                        && queue.state.waiting.map(\.id) == [afterNewerReview],
                        "An obsolete review A Queue card resumed or dismissed newer review B")
            var oldActionReturned = false
            guard let oldResultView = resultViews.compactMap({ $0 as? OperationResultsView }).first else {
                throw UIVerification.Failure(message: "Older native review result view is unavailable")
            }
            oldResultView.resultActionFinishedForVerification = { oldActionReturned = true }
            reviewActions.first { $0.title == "Resume Queue" }?.performClick(nil)
            try await waitUntil("Older native result action did not finish") { window.attachedSheet == nil && oldActionReturned }
            try require(queue.state.isPaused && queue.reviewResultID == newerMissing
                        && queue.state.waiting.map(\.id) == [afterNewerReview]
                        && !FileManager().fileExists(atPath: review.target("After newer review.txt").path),
                        "An obsolete review A Results action resumed or dismissed newer review B")
            try openAttentionReview(queue, id: newerMissing, browser: host)
            guard let newerSheet = window.attachedSheet,
                  let newerResume = descendantsForReview(newerSheet.contentView ?? NSView()).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Resume Queue" }) else {
                throw UIVerification.Failure(message: "Newer paused review has no explicit Resume Queue action")
            }
            newerResume.performClick(nil)
            try await waitUntil("Reviewed admission queue did not settle") { !queue.hasOutstandingWork }
            try require(!queue.state.isPaused && queue.results.first(where: { $0.id == missing })?.outcome.result.disposition == .failed
                        && !FileManager().fileExists(atPath: review.target("Missing.txt").path),
                        "Resume Queue changed or retried the reviewed admission failure")
            try await requireBytes(review.target("After review.txt"), expected: review.bytes("After review.txt"))
            try await requireBytes(review.target("After newer review.txt"), expected: review.bytes("After newer review.txt"))
            host.transferConflictPrompt = nil
            state.checks.append("Admission failure while another job runs remains pinned after older success; compact inspector routes review actions, and an obsolete review A sheet cannot resume newer review B")
    }

    private static func verifyGuardedResultActions(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let engine = context.engine
        let window = context.window
        let state = context.state
            let remaining = try await makePhase(owned, "Guarded result actions", names: ["Completed.txt", "Remaining.txt", "Later.txt"], conflicts: ["Remaining.txt"])
            host.transferConflictPrompt = { conflicts in Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }) }
            guard let remainingJob = queue.enqueue(sources: [remaining.source("Completed.txt"), remaining.source("Remaining.txt")],
                destination: remaining.destination, move: false, title: "Generated remaining-work review", origin: host,
                engine: engine, metadataPolicy: .strict) else {
                throw UIVerification.Failure(message: "Remaining-work fixture admission was refused")
            }
            try await waitUntil("Remaining-work fixture did not finish") { !queue.hasOutstandingWork }
            guard let remainingResult = queue.results.first(where: { $0.id == remainingJob }),
                  let remainingToken = remainingResult.outcome.continuation,
                  let remainingRecord = remainingResult.outcome.recordID else {
                throw UIVerification.Failure(message: "Real skipped transfer lost its guarded continuation or recovery record")
            }
            queue.pause()
            let laterRemaining = try admit(context, remaining, "Later.txt", origin: host)
            try await waitReady(context, [laterRemaining])
            var continuationPromptCanceled = false
            host.transferConflictPrompt = { _ in continuationPromptCanceled = true; return nil }
            queue.showResult(remainingJob, in: host)
            guard let remainingSheet = window.attachedSheet else { throw UIVerification.Failure(message: "Guarded continuation Results missing") }
            let remainingButtons = descendantsForReview(remainingSheet.contentView ?? NSView()).compactMap { $0 as? NSButton }
            try require(["Continue Remaining", "Open Recovery", "Resume Queue"].allSatisfy { title in
                remainingButtons.contains { $0.title == title && $0.isEnabled }
            }, "Queued Results did not expose distinct guarded continuation, recovery and waiting-only resume actions")
            remainingButtons.first { $0.title == "Continue Remaining" }?.performClick(nil)
            try await waitUntil("Canceled continuation did not drain") {
                window.attachedSheet == nil && host.operationTask == nil
                    && continuationPromptCanceled
            }
            try require(queue.state.isPaused && queue.state.waiting.map(\.id) == [laterRemaining]
                        && host.lastTransferContinuation?.id == remainingToken.id
                        && !FileManager().fileExists(atPath: remaining.target("Later.txt").path),
                        "Canceling guarded continuation resumed waiting work or discarded its original token")
            queue.showResult(remainingJob, in: host)
            guard let recoverySheet = window.attachedSheet,
                  let openRecovery = descendantsForReview(recoverySheet.contentView ?? NSView()).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Open Recovery" }) else {
                throw UIVerification.Failure(message: "Guarded result recovery action missing")
            }
            openRecovery.performClick(nil)
            try await waitUntil("Guarded Results did not close for Recovery") { window.attachedSheet == nil }
            try await waitUntil("Guarded Results did not select its exact Recovery record") {
                host.recoveryWindow?.selectedRecordID == remainingRecord
            }
            try require(host.recoveryWindow?.selectedRecordID == remainingRecord && queue.state.isPaused,
                        "Open Recovery selected unrelated history or resumed waiting jobs")
            host.openOperationRecovery(recordID: UUID())
            await host.recoveryInspectionTask?.value
            let recoveryDetails = host.recoveryWindow?.window?.contentView.map { descendantsForReview($0).compactMap { $0 as? NSTextView } } ?? []
            try require(host.recoveryWindow?.selectedRecordID == nil
                        && recoveryDetails.contains { $0.string.contains("requested operation is unavailable") },
                        "Unavailable requested recovery record silently selected another operation")
            host.recoveryWindow?.close()
            queue.showResult(remainingJob, in: host)
            guard let resumeSheet = window.attachedSheet,
                  let resumeAction = descendantsForReview(resumeSheet.contentView ?? NSView()).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Resume Queue" }) else {
                throw UIVerification.Failure(message: "Guarded result resume action missing")
            }
            resumeAction.performClick(nil)
            try await waitUntil("Waiting-only Resume Queue did not settle") { window.attachedSheet == nil && !queue.hasOutstandingWork }
            try await requireBytes(remaining.target("Completed.txt"), expected: remaining.bytes("Completed.txt"))
            try await requireBytes(remaining.source("Remaining.txt"), expected: remaining.bytes("Remaining.txt"))
            try await requireBytes(remaining.target("Remaining.txt"), expected: Data("Generated existing destination".utf8))
            try await requireBytes(remaining.target("Later.txt"), expected: remaining.bytes("Later.txt"))
            try require(queue.results.first(where: { $0.id == remainingJob })?.outcome.recordID == remainingRecord,
                        "Resume Queue modified the earlier reviewed job")
            host.transferConflictPrompt = nil
            state.checks.append("Real queued continuation remains distinct from Recovery and Resume; canceled continuation leaves waiting jobs paused, exact/missing recovery selection is honest, and Resume changes only later waiting work")
    }

    private static func verifyCapturedPolicies(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let state = context.state
            let policies = try await makePhase(owned, "Captured conflict preferences", names: ["Automatic copy.txt", "Automatic move.txt"],
                                               conflicts: ["Automatic copy.txt", "Automatic move.txt"])
            queue.pause()
            let originalPreferences = host.settings.conflictPreferences
            var unexpectedPrompts = 0
            host.transferConflictPrompt = { _ in unexpectedPrompts += 1; return nil }
            host.settings.conflictPreferences = TransferConflictPreferences(files: .keepBoth)
            let automaticCopy = try admit(context, policies, "Automatic copy.txt", origin: host)
            host.settings.conflictPreferences = TransferConflictPreferences(files: .skip)
            let automaticMove = try admit(context, policies, "Automatic move.txt", origin: host, move: true)
            host.settings.conflictPreferences = .init() // Waiting jobs must retain their earlier choices.
            try await waitReady(context, [automaticCopy, automaticMove])
            try require(queue.resume(), "Captured-policy queue failed to resume")
            try await waitUntil("Captured automatic policies did not settle") { !queue.hasOutstandingWork || queue.reviewResultID != nil }
            host.settings.conflictPreferences = originalPreferences
            host.transferConflictPrompt = nil
            try require(!queue.hasOutstandingWork && !queue.state.isPaused && unexpectedPrompts == 0,
                        "Automatic nondestructive policies prompted, paused, or used changed Settings")
            try await requireBytes(policies.target("Automatic copy (1).txt"), expected: policies.bytes("Automatic copy.txt"))
            try await requireBytes(policies.target("Automatic copy.txt"), expected: Data("Generated existing destination".utf8))
            try await requireBytes(policies.source("Automatic move.txt"), expected: policies.bytes("Automatic move.txt"))
            try await requireBytes(policies.target("Automatic move.txt"), expected: Data("Generated existing destination".utf8))
            state.checks.append("Queued automatic Keep Both and Skip capture independent policies, ignore later Settings changes, avoid prompts/review loops, preserve originals and advance normally")
    }

    private static func verifyAdmissionCancellation(_ context: RunContext, host: BrowserViewController) async throws -> Void {
        let queue = context.queue
        let owned = context.owned
        let state = context.state
            let admission = try await makePhase(owned, "Admission cancellation", names: ["Deferred.txt", "Ready behind head.txt"], conflicts: [])
            let admissionGate = Gate(); state.gates.append(admissionGate)
            var suspendedID: UUID?
            queue.beforeAdmissionObservationReturnsForVerification = { id in if id == suspendedID { await admissionGate.suspend() } }
            var incoming: FolderAccessLease? = FolderAccessLease(url: owned, backend: LeaseBackend())
            let incomingProbe = LeaseProbe(incoming)
            let preparing = try admit(context, admission, "Deferred.txt", origin: host, retaining: FileAccessLifetimes(leases: [incoming!]))
            suspendedID = preparing
            incoming = nil
            try await waitUntil("Admission return hook did not suspend") { admissionGate.entered }
            let readyBehind = try admit(context, admission, "Ready behind head.txt", origin: host)
            try await waitReady(context, [readyBehind])
            try require(queue.state.active == nil && queue.state.waiting.map(\.id) == [preparing, readyBehind],
                        "A ready later job overtook a still-preparing FIFO head")
            try require(queue.cancelWaiting(preparing) && incomingProbe.value != nil && queue.state.active?.id == readyBehind,
                        "Canceling a suspended head released access early or failed to admit the ready successor")
            admissionGate.release()
            try await waitUntil("Canceled admission and its successor did not drain") { incomingProbe.value == nil && !queue.hasOutstandingWork }
            queue.beforeAdmissionObservationReturnsForVerification = nil
            try require(!queue.results.contains { $0.id == preparing }
                        && queue.results.contains { $0.id == readyBehind }
                        && !FileManager().fileExists(atPath: admission.target("Deferred.txt").path),
                        "Late canceled-head completion affected the successor or performed writes")
            try await requireBytes(admission.target("Ready behind head.txt"), expected: admission.bytes("Ready behind head.txt"))
            state.checks.append("A preparing head blocks a ready successor; Cancel admits the successor while retaining old access until late suspension/unwind drains; actual blocking filesystem observation remains unexercised")
    }

    private struct Phase: Sendable {
        let sourceDirectory: URL
        let destination: URL
        func source(_ name: String) -> URL { sourceDirectory.appendingPathComponent(name) }
        func target(_ name: String) -> URL { destination.appendingPathComponent(name) }
        func bytes(_ name: String) -> Data { Data("Generated queue payload: \(name)".utf8) }
    }
    private static func verifyPresentationBurst(_ workspace: BrowserWorkspaceController,
                                               primary: BrowserViewController, fixture: URL) async throws {
        let queue = primary.operationCoordinator.transfers
        try require(workspace.browsers.count == 1 && !queue.hasOutstandingWork, "Presentation fixture requires one idle pane")
        primary.navigate(to: .directory(fixture))
        try await waitUntil("Presentation source listing") { !primary.isLoading && primary.orderingTask == nil }
        let oldHook = workspace.willStartBrowserForVerification
        var finished = Set<UUID>()
        workspace.willStartBrowserForVerification = { pane in
            pane.permitsBackgroundVerification = true
            pane.didFinishBeginForVerification = { finished.insert(pane.paneID) }
        }
        defer { workspace.willStartBrowserForVerification = oldHook }
        try require(workspace.splitActive(at: .trailing) && workspace.splitActive(at: .bottom), "Presentation fixture split")
        workspace.activate(primary)
        try require(workspace.splitActive(at: .bottom) && workspace.browsers.count == 4, "Presentation fixture four panes")
        try await waitUntil("Presentation pane startup") { finished.count == 3 }
        for pane in workspace.browsers.values {
            await pane.recoveryInspectionTask?.value
            pane.didFinishBeginForVerification = nil
        }
        try await waitUntil("Presentation callbacks before burst") { !workspace.queuePresentationPendingForVerification }
        workspace.activate(primary)
        let responder = primary.view.window?.firstResponder
        let before = workspace.queueSharedRendersForVerification
        for _ in 0..<32 { queue.pause() }
        try await waitUntil("Presentation callbacks did not drain") { !workspace.queuePresentationPendingForVerification }
        try require(workspace.queueSharedRendersForVerification - before == 1,
                    "A synchronous queue revision burst repeated shared presentation per pane instead of coalescing once")
        try require(queue.state.isPaused && workspace.activeBrowser === primary
                    && primary.view.window?.firstResponder === responder,
                    "Presentation coalescing changed queue intent or active pane/focus")

        // A new revision during the native render callback must schedule a
        // following update even though the older callback is still on stack.
        guard let presenter = workspace.queuePresentation else {
            throw UIVerification.Failure(message: "Workspace queue presentation owner is missing")
        }
        let beforeReentry = workspace.queueSharedRendersForVerification
        presenter.beforeRefreshForVerification = { [weak presenter] in
            presenter?.beforeRefreshForVerification = nil
            queue.pause()
        }
        queue.pause()
        try await waitUntil("Reentrant queue presentation callbacks") { !workspace.queuePresentationPendingForVerification }
        try require(workspace.queueSharedRendersForVerification - beforeReentry == 2,
                    "A revision arriving during presentation was lost or rendered repeatedly")

        let beforeClosing = workspace.queueSharedRendersForVerification
        queue.pause()
        try require(workspace.queuePresentationPendingForVerification, "Closing test has no scheduled presentation")
        workspace.isClosing = true
        try require(!workspace.queuePresentationPendingForVerification, "Closing did not cancel scheduled presentation")
        workspace.isClosing = false
        queue.pause()
        try await waitUntil("New presentation after canceled ticket") { !workspace.queuePresentationPendingForVerification }
        try require(workspace.queueSharedRendersForVerification - beforeClosing == 1,
                    "A canceled presentation erased or duplicated a newer window update")

        guard let retired = workspace.browsers.values.first(where: { $0 !== primary }) else {
            throw UIVerification.Failure(message: "Retired presentation pane is missing")
        }
        let retiredRenders = retired.operationProgressRendersForVerification
        queue.pause()
        try require(workspace.closeLastTab(in: retired), "Could not retire pane before scheduled presentation")
        try await waitUntil("Presentation after pane retirement") {
            !workspace.queuePresentationPendingForVerification && retired.queueRevisionCallbacksPendingForVerification == 0
        }
        try require(retired.operationProgressRendersForVerification == retiredRenders && retired.isBrowserSuspended,
                    "A delayed presentation rendered a retired pane")

        let standalone = BrowserViewController(settings: primary.settings)
        standalone.permitsBackgroundVerification = true
        standalone.loadViewIfNeeded()
        defer { standalone.suspendBrowser() }
        try await waitUntil("Standalone queue subscription") { standalone.queueRevisionCallbacksPendingForVerification == 0 }
        let beforeStandalone = standalone.operationProgressRendersForVerification
        queue.pause()
        try await waitUntil("Standalone queue callback") { standalone.queueRevisionCallbacksPendingForVerification == 0 }
        try require(standalone.workspace == nil && standalone.operationProgressRendersForVerification == beforeStandalone + 1,
                    "Window coalescing removed standalone queue presentation")
        _ = queue.resume()
        try await waitUntil("Presentation Resume callbacks") { !workspace.queuePresentationPendingForVerification }
        for pane in Array(workspace.browsers.values) where pane !== primary {
            try require(workspace.closeLastTab(in: pane), "Presentation fixture pane close")
        }
        workspace.activate(primary)
    }

    private static func makePhase(_ root: URL, _ name: String, names: [String], conflicts: [String]) async throws -> Phase {
        let phase = Phase(sourceDirectory: root.appendingPathComponent(name + "/Source", isDirectory: true),
                          destination: root.appendingPathComponent(name + "/Destination", isDirectory: true))
        try await Task.detached {
            try FileManager().createDirectory(at: phase.sourceDirectory, withIntermediateDirectories: true)
            try FileManager().createDirectory(at: phase.destination, withIntermediateDirectories: true)
            for item in names { try phase.bytes(item).write(to: phase.source(item), options: .withoutOverwriting) }
            for item in conflicts { try Data("Generated existing destination".utf8).write(to: phase.target(item), options: .withoutOverwriting) }
        }.value
        return phase
    }
    private static func requireBytes(_ url: URL, expected: Data) async throws {
        let actual = try await Task.detached { try Data(contentsOf: url) }.value
        try require(actual == expected, "Generated queue destination bytes differ")
    }
    private static func verifyInspector(_ queue: ApplicationTransferQueue, waiting: UUID, review: UUID) throws {
        let inspector = TransferQueueInspectionView(frame: NSRect(origin: .zero, size: OperationProgressDetailsView.cardSize))
        let window = NSWindow(contentRect: inspector.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = inspector
        defer { window.orderOut(nil); window.close() }
        inspector.update(queue)
        inspector.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let controls = descendants(inspector)
        guard let table = controls.compactMap({ $0 as? NSTableView }).first,
              let result = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSButton,
              let cancel = table.view(atColumn: 1, row: 1, makeIfNecessary: true) as? NSButton else {
            throw UIVerification.Failure(message: "Native queue inspector did not materialize waiting/review actions")
        }
        var canceled: UUID?, inspected: UUID?
        var closed = false
        inspector.onCancel = { canceled = $0 }; inspector.onResult = { inspected = $0 }; inspector.onClose = { closed = true }
        let before = queue.state
        cancel.performClick(nil); result.performClick(nil)
        try require(canceled == waiting && inspected == review && result.title == "Review" && table.accessibilityLabel() == "Waiting transfers and recent results"
                    && cancel.accessibilityLabel()?.contains("Cancel waiting") == true && result.isEnabled,
                    "Queue inspector did not prioritize the review cause or expose distinct accessible row actions")
        for control in descendants(inspector).compactMap({ $0 as? NSButton }) where !control.isHiddenOrHasHiddenAncestor && !control.visibleRect.isEmpty {
            let rect = control.convert(control.bounds, to: inspector)
            try require(inspector.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                        "Native queue inspector control clips outside its compact card: \(control.title), \(rect), card=\(inspector.bounds)")
        }
        inspector.focusPrimaryAction()
        try require((window.firstResponder as? NSButton)?.title == "Resume Queue", "Paused queue inspector cannot focus its Resume Queue action")
        inspector.cancelOperation(nil)
        try require(closed && queue.state == before, "Closing queue inspection canceled or resumed file work")
    }
    private static func descendantsForReview(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendantsForReview($0) }
    }
    private static func verifyPausedSheet(_ queue: ApplicationTransferQueue, id: UUID,
                                          browser: BrowserViewController) async throws {
        guard let window = browser.view.window else { throw UIVerification.Failure(message: "Paused review host is unavailable") }
        let before = queue.state
        try require(window.attachedSheet == nil,
                    "A stopped or failed transfer opened Results before an explicit Review action")
        try openAttentionReview(queue, id: id, browser: browser)
        guard let sheet = window.attachedSheet else { throw UIVerification.Failure(message: "Paused review has no native Results route") }
        let controls = descendantsForReview(sheet.contentView ?? NSView())
        let buttons = controls.compactMap { $0 as? NSButton }
        try require(buttons.contains { $0.title == "Resume Queue" && $0.isEnabled }
                    && buttons.contains { $0.title == "Reveal Source" && $0.isEnabled }
                    && buttons.contains { $0.title == "Reveal Destination" && $0.isEnabled },
                    "Stopped/failed review lost its safe Resume Queue and captured location routes")
        try require(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("starts only waiting jobs") },
                    "Resume Queue does not explain that reviewed work stays protected")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil("Paused Results Done did not close its sheet") { window.attachedSheet == nil }
        try require(queue.state == before, "Closing paused Results resumed or changed queued work")
        browser.transferQueueDetails.onClose?()
    }

    @discardableResult
    private static func openAttentionCard(_ queue: ApplicationTransferQueue, id: UUID,
                                          browser: BrowserViewController, reviewEnabled: Bool) throws -> NSButton {
        browser.validateNavigationButtons()
        try require(queue.reviewResultID == id && !browser.operationResultsButton.isHidden
                    && browser.operationResultsButton.isEnabled && browser.operationResultsButton.title == "Needs attention"
                    && browser.operationResultsButton.accessibilityLabel()?.contains("attention") == true,
                    "Pinned transfer attention is unavailable from the native footer")
        let before = queue.state
        browser.operationResultsButton.performClick(nil)
        let host = browser.workspace?.activeBrowser ?? browser
        host.transferQueueDetails.layoutSubtreeIfNeeded()
        let controls = descendantsForReview(host.transferQueueDetails)
        guard let table = controls.compactMap({ $0 as? NSTableView }).first,
              let review = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSButton else {
            throw UIVerification.Failure(message: "Attention card did not expose the pinned review row")
        }
        try require(!host.operationDetailsContainer.isHidden && !host.transferQueueDetails.isHidden
                    && host.view.window?.attachedSheet == nil && queue.state == before
                    && review.title == "Review" && review.isEnabled == reviewEnabled,
                    "Opening in-window attention changed work or misrepresented guarded Review availability")
        if !reviewEnabled {
            try require(controls.compactMap({ $0 as? NSTextField }).contains {
                $0.stringValue.contains("Review actions wait")
            }, "Busy attention did not explain why Review must wait for the current operation")
        }
        return review
    }

    private static func openAttentionReview(_ queue: ApplicationTransferQueue, id: UUID,
                                            browser: BrowserViewController) throws {
        let review = try openAttentionCard(queue, id: id, browser: browser, reviewEnabled: true)
        review.performClick(nil)
        try require(browser.view.window?.attachedSheet != nil,
                    "The explicit attention Review action did not open its guarded Results")
    }

    private static func verifyAttentionInEmptyWindow(_ queue: ApplicationTransferQueue, id: UUID,
                                                     settings: BrowserSettings, engine: RecoverableFileOperations) throws {
        let peer = BrowserViewController(settings: settings)
        let board = NSPasteboard.withUniqueName()
        peer.permitsBackgroundVerification = true
        peer.folderAccess = FolderAccessController(stateDirectory: nil)
        peer.pinsController = BrowserPinsController(stateDirectory: nil)
        peer.transferPasteboard = board
        peer.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        peer.recoverableFileOperations = engine
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.browser = peer; window.contentViewController = peer
        defer { peer.suspendBrowser(); window.orderOut(nil); window.close(); board.releaseGlobally() }
        try require(peer.lastOperationResult == nil, "The new attention window unexpectedly inherited local result history")
        _ = try openAttentionCard(queue, id: id, browser: peer, reviewEnabled: true)
        try require(queue.reviewResultID == id && peer.lastOperationResult == nil,
                    "Inspecting shared attention silently replaced the new window's local history")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        try require(condition(), message)
    }
    private struct ClipboardSnapshot: Equatable {
        let generation: Int
        let types: [[NSPasteboard.PasteboardType]]
        let data: [[Data?]]
        init(_ board: NSPasteboard) {
            generation = board.changeCount
            let items = board.pasteboardItems ?? []
            types = items.map(\.types)
            data = items.map { item in item.types.map { item.data(forType: $0) } }
        }
    }
    @MainActor private final class Gate {
        private(set) var entered = false
        private var conflicts: [TransferConflict] = []
        private var answerContinuation: CheckedContinuation<[UUID: TransferConflictResolution]?, Never>?
        private var suspension: CheckedContinuation<Void, Never>?
        func answer(_ conflicts: [TransferConflict]) async -> [UUID: TransferConflictResolution]? {
            self.conflicts = conflicts; entered = true
            return await withCheckedContinuation { answerContinuation = $0 }
        }
        func suspend() async { entered = true; await withCheckedContinuation { suspension = $0 } }
        func release() {
            answerContinuation?.resume(returning: Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }))
            answerContinuation = nil
            suspension?.resume(); suspension = nil
        }
    }
    @MainActor private final class LeaseProbe {
        weak var value: FolderAccessLease?
        init(_ value: FolderAccessLease?) { self.value = value }
    }
    private final class LeaseBackend: FolderAccessBackend, @unchecked Sendable {
        func startAccess(to url: URL) -> Bool { true }
        func stopAccess(to url: URL) {}
        func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
            guard let value = String(data: bookmark, encoding: .utf8), let url = URL(string: value), url.isFileURL else {
                throw FileOperationFailure.invalidRequest
            }
            return FolderBookmarkResolution(url: url, isStale: false)
        }
    }
}
#endif
