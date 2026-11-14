#if DEBUG
import AppKit
import Foundation
import FileOperations
@_spi(Qualification) import LocalStorage

// SOURCE ONLY. No App entry route or factory is installed. The concrete backend
// and process manifest must be reviewed before this runner can be integrated.
// The runner never creates a remote permit, baseline, body UUID or catalog.
@MainActor protocol GateBBackendAdapter: AnyObject {
    var schema: String { get }
    var initialContents: TextDocumentValue { get }
    var connectionID: UUID { get }
    // Must be a real generated session with actual working-copy storage. Its
    // native buffer has not yet been installed; the real controller does that.
    func makeDocumentSession() async throws -> SFTPInPlaceDocumentSession
    // A fresh separately supervised process must contend on the actual opaque
    // body's owner lock. No same-process FD or UI flag is sufficient here.
    func requireCrossProcessOwnerPin(held: Bool) async throws
    // Only removeUnusedAfterDrain's own commit may consume this once. It must
    // pause after real pin drain, before throwing at that commit's beforeRename.
    func armUnusedRemovalFailure(nativeCloseCount: @escaping @Sendable () -> Int) async throws
    func waitForActualPinDrainBeforeCatalogCommit() async throws
    func releaseOneCatalogFailure() async throws
    // Failure cleanup only: idempotently release/join the owned bounded pause.
    // This must never retry or consume another catalog mutation/fault.
    func abortOwnedFailureHold()
    // Abort above signals before this fallible join. Its owned pause must have
    // a five-second independent expiry; a throw cannot leave it unsignalled.
    func waitForFailureHoldDrain() async throws
    func observations() async throws -> GateBBackendObservations
    func requireExactRetainedGraph() async throws
    // Fresh-process Remove must either progress using a valid graph or refuse
    // review-required without mutation. A UI 'handoff attempted' is no receipt.
    func inspectFreshRemovalAfterDetachment() async throws -> GateBRemovalOutcome
    func closeAndDrain() async throws
}

struct GateBBackendObservations: Sendable, Equatable {
    let instrumentationArmed: Bool
    let nativeBufferCloseEntries: Int, actualPinDrains: Int
    let scopedRemovalCommitEntries: Int, injectedBeforeRenameFailures: Int
    let checkedBodyReadEntries: Int, remoteSaveEntries: Int, remoteStopEntries: Int
    let workerLaunchAttempts: Int, workerIPC: Int, remoteWrites: Int, saveAcknowledgements: Int
    let outstandingOwners: Int
}
enum GateBRemovalOutcome: String, Sendable { case validGraphProgress, reviewRequiredWithoutMutation }

@MainActor protocol GateBActualPublicationPause: AnyObject {
    // Comes from the actual generated engine's archiveProduction .synced hook
    // in ArchiveFileProduction, after verified staging and before publication.
    // The wrapper's publishCopy entry is explicitly insufficient evidence.
    var actualSyncedEntries: Int { get }
    func waitForActualSyncedEntry() async throws
    // Idempotent signalling only, never another file operation. The actual App
    // task is joined separately after this releases its bounded worker pause.
    func release()
}

// Caller must supply the real App browser and its normal local writer service,
// using only a separately validated generated case. These are NOT fabricated
// Save results. Destination access is the retained generated fixture grant.
@MainActor struct GateBApplicationFixture {
    let browser: BrowserViewController
    let destination: (Int) throws -> EditorSaveDestination
    let requireNoExport: (Int) async throws -> Void
    let requireExactExport: (Int, TextDocumentValue) async throws -> Void
    let armActualPublicationPause: (Int) async throws -> any GateBActualPublicationPause
    let closeAndDrain: () async throws -> Void
}

struct GateBApplicationResult: Sendable {
    let status: String, failureStage: String?
    // Fixed cleanup/observation failures are independent of the first runner
    // refusal. No raw Error, path, environment value or input is emitted.
    let cleanupFailureStages: [String]
    // One callback at the actual pin-drain boundary is a separate observation
    // from the cumulative callbacks after later explicit close/disposal.
    let checks: [String], nativeCloseAtFirstPinDrain: Int
    let nativeCloseCallbacks: Int, inputEvents: Int
    let copyPublishEntries: Int, copyResults: [String]
    let removal: GateBRemovalOutcome?
}

@MainActor enum GateBApplicationVerification {
    private struct Failure: Error { let stage: String }
    // Thread-safe native callback observation, not backend pin authority.
    private final class NativeCloseObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
    private final class PreparationPause: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiting = false, released = false
        var entered: Bool { condition.withLock { waiting } }
        func release() { condition.withLock { released = true; condition.broadcast() } }
        func compute(_ input: EditorPreparationInput,
                     _ cancellation: EditorPreparationCancellation) -> EditorPreparationResult {
            if case .copy = input {
                condition.lock(); waiting = true
                let deadline = Date(timeIntervalSinceNow: 5)
                while !released {
                    if !condition.wait(until: deadline) { condition.unlock(); return .invalid(.invalidReceipt) }
                }
                condition.unlock()
            }
            return EditorPreparationOwner.prepare(input, cancellation)
        }
    }
    @MainActor private final class AsyncPause {
        private(set) var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            precondition(!entered && waiter == nil)
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { let held = waiter; waiter = nil; held?.resume() }
    }
    private final class ApplicationObservations {
        var unexpectedSaveAdmission = 0, unexpectedReview = 0
        var chooseCount = 0, publishCount = 0
        var copyResults: [String] = []
        var copyIndex = 0
        var chooserPause: AsyncPause?
    }
    private static func need(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure(stage: stage) }
    }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate() {
            try need(.now < deadline, stage)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func noRemoteChange(_ before: GateBBackendObservations,
                                       _ after: GateBBackendObservations) throws {
        try need(before.instrumentationArmed && after.instrumentationArmed, "backend-observer-not-armed")
        try need(before.checkedBodyReadEntries == after.checkedBodyReadEntries
            && before.remoteSaveEntries == after.remoteSaveEntries
            && before.remoteStopEntries == after.remoteStopEntries
            && before.workerLaunchAttempts == after.workerLaunchAttempts
            && before.workerIPC == after.workerIPC
            && before.remoteWrites == after.remoteWrites
            && before.saveAcknowledgements == after.saveAcknowledgements,
            "detached-native-command-reentered-remote-backend")
    }
    private static func nativeEdit(_ document: RemoteTextDocumentController, text: String) {
        let view = document.window.surface.textView
        document.window.window?.makeFirstResponder(view)
        view.setSelectedRange(.init(location: view.string.utf16.count, length: 0))
        view.insertText(text, replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
    }

    // Missing dependencies refuse before any native controller or fixture owner
    // is created. A future entry must also validate its exact external case and
    // executable admission before constructing either supplied dependency.
    static func run(backend: (any GateBBackendAdapter)?, fixture: GateBApplicationFixture?) async -> GateBApplicationResult {
        guard let backend, let fixture else {
            return .init(status: "DEPENDENCY_UNAVAILABLE", failureStage: "reviewed-generated-factory-unavailable",
                cleanupFailureStages: [], checks: [], nativeCloseAtFirstPinDrain: 0, nativeCloseCallbacks: 0,
                inputEvents: 0, copyPublishEntries: 0,
                copyResults: [], removal: nil)
        }
        var document: RemoteTextDocumentController?
        var checks: [String] = [], failureStage: String?, status = "FAILED"
        var cleanupFailureStages: [String] = []
        var removal: GateBRemovalOutcome?
        var inputEvents = 0
        var nativeCloseAtFirstPinDrain = 0
        let callback = NativeCloseObservation(), app = ApplicationObservations()
        let preparationPause = PreparationPause()
        var failureHoldReleased = false
        var actualPublicationPause: (any GateBActualPublicationPause)?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            // Counts only: never characters, location, target, or event content.
            inputEvents += 1; return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        do {
            try need(!RemoteTextEditorFeature.ordinaryEnabled, "ordinary-remote-editor-must-stay-disabled")
            try need(backend.schema == "traverse.gateb.native-close.v1", "backend-schema-unreviewed")
            let session = try await backend.makeDocumentSession()
            guard var interactions = ApplicationLocalTextEditors.shared.remoteInteractions(from: fixture.browser) else {
                throw Failure(stage: "actual-app-local-copy-service-unavailable")
            }
            let publish = interactions.publishCopy
            interactions.acquireSave = {
                app.unexpectedSaveAdmission += 1
                throw FileOperationFailure.unavailable
            }
            interactions.chooseClose = { _, _ in .discard }
            interactions.reviewVersions = { _, _, _ in app.unexpectedReview += 1 }
            interactions.chooseCopy = { _, _ in
                app.chooseCount += 1
                let index = app.copyIndex
                if let pause = app.chooserPause { await pause.wait() }
                return try? fixture.destination(index)
            }
            interactions.publishCopy = { value, generation, destination, native in
                app.publishCount += 1
                do {
                    let result = try await publish(value, generation, destination, native)
                    switch result {
                    case .saved: app.copyResults.append("saved")
                    case .refused: app.copyResults.append("refused")
                    case .publishedNeedsReload: app.copyResults.append("publishedNeedsReload")
                    case .uncertain: app.copyResults.append("uncertain")
                    }
                    return result
                } catch {
                    app.copyResults.append("threw")
                    throw error
                }
            }
            try need(await session.initialContents == backend.initialContents, "actual-session-initial-text-mismatch")
            let value = RemoteTextDocumentController(remote: session, contents: backend.initialContents,
                connectionID: backend.connectionID, displayName: "Generated Close Check.txt",
                interactions: interactions, installChrome: { ToolWindowChrome.install(in: $0, settings: fixture.browser.settings) })
            document = value
            let originalClose = value.window.didClose
            value.window.didClose = { callback.increment(); originalClose?() }
            value.show()
            let nativeWindow = value.window.window, textView = value.window.surface.textView
            let originalText = backend.initialContents.text
            nativeEdit(value, text: "Generated unsaved edit\n")
            try await wait("actual-native-edit-not-accepted") { value.pendingEdit == nil && value.state.isDirty && !value.preparation.isDraining }
            let visibleText = textView.string
            try need(visibleText != originalText && textView.undoManager?.canUndo == true, "native-edit-or-undo-not-owned")
            try await wait("native-menu-positive-control-not-key") { nativeWindow?.isKeyWindow == true }
            guard let saveAction = value.window.saveButton.action,
                  let versionsAction = value.window.recoveryButton.action else {
                throw Failure(stage: "native-buttons-missing-actions")
            }
            let saveMenu = NSMenuItem(title: "Save", action: saveAction, keyEquivalent: "")
            let versionsMenu = NSMenuItem(title: "Review Versions", action: versionsAction, keyEquivalent: "")
            try need(value.window.validateUserInterfaceItem(saveMenu)
                && value.window.validateUserInterfaceItem(versionsMenu), "initial-native-menu-positive-control-failed")
            try await backend.requireCrossProcessOwnerPin(held: true)
            try await backend.armUnusedRemovalFailure(nativeCloseCount: { callback.value })
            value.requestClose()
            try await backend.waitForActualPinDrainBeforeCatalogCommit()
            nativeCloseAtFirstPinDrain = callback.value
            try need(nativeCloseAtFirstPinDrain == 1 && value.window.window === nativeWindow
                && value.window.surface.textView === textView && nativeWindow?.isVisible == false,
                "actual-native-close-before-pin-drain-not-observed")
            try await backend.requireCrossProcessOwnerPin(held: false)
            let drained = try await backend.observations()
            try need(drained.instrumentationArmed && drained.nativeBufferCloseEntries == 1
                && drained.actualPinDrains == 1 && drained.scopedRemovalCommitEntries == 1
                && drained.injectedBeforeRenameFailures == 0, "wrong-post-drain-failure-boundary")
            try await backend.releaseOneCatalogFailure()
            failureHoldReleased = true
            try await wait("same-native-recovery-window-not-reopened") {
                value.closingWork == nil && value.remoteBodyHandoffAttempted && value.needsReview
                    && value.disconnected && nativeWindow?.isVisible == true
            }
            try need(value.window.window === nativeWindow && value.window.surface.textView === textView
                && textView.string == visibleText && textView.undoManager?.canUndo == true,
                "recovery-replaced-native-text-or-undo")
            try need(nativeWindow?.title.contains("Local Recovery") == true && !value.window.saveButton.isEnabled
                && !value.window.recoveryButton.isEnabled && value.window.textCopyButton.isEnabled,
                "detached-native-actions-not-guarded")
            let detached = try await backend.observations()
            try need(detached.injectedBeforeRenameFailures == 1, "scoped-failure-not-consumed-once")
            try await wait("detached-native-menu-not-key") { nativeWindow?.isKeyWindow == true }
            try need(!value.window.validateUserInterfaceItem(saveMenu)
                && !value.window.validateUserInterfaceItem(versionsMenu), "detached-native-menu-validation-admitted-remote-action")
            value.window.saveButton.performClick(nil); value.window.recoveryButton.performClick(nil)
            value.save(); value.reviewVersions(); value.stop()
            await Task.yield()
            try need(app.unexpectedSaveAdmission == 0 && app.unexpectedReview == 0
                && value.work == nil && value.stopWork == nil, "direct-detached-remote-command-was-admitted")
            try noRemoteChange(detached, try await backend.observations())
            try await backend.requireExactRetainedGraph()
            checks.append("Actual windowWillClose precedes real pin drain; fresh-process EX succeeds only after drain; one exact catalog commit fails")
            checks.append("Same native window/text view/Undo reopens as Local Recovery; remote buttons and direct commands remain unavailable")

            textView.undoManager?.undo()
            try await wait("native-undo-did-not-restore-original") { textView.string == originalText && value.pendingEdit == nil }
            textView.undoManager?.redo()
            try await wait("native-redo-did-not-restore-detached-text") { textView.string == visibleText && value.pendingEdit == nil }
            checks.append("Actual native Undo and Redo preserve the detached visible buffer")

            // Stop during a deliberately retained chooser cannot publish even
            // when the fixture chooser later returns its generated destination.
            let choosePause = AsyncPause(); app.chooserPause = choosePause; app.copyIndex = 0
            value.saveTextCopy()
            try await wait("copy-chooser-not-entered") { choosePause.entered && value.choosing }
            value.stop(); choosePause.release()
            try await wait("cancelled-copy-chooser-not-drained") { !value.isBusy }
            app.chooserPause = nil
            try need(app.publishCount == 0, "stopped-chooser-published")
            try await fixture.requireNoExport(0)

            // Reuse the production preparation compute behind a bounded pause;
            // Stop must cancel that actual immutable copy capture, then join it.
            await value.preparation.closeAndDrain()
            value.preparation = EditorPreparationOwner(compute: { preparationPause.compute($0, $1) },
                completion: { [weak value] input, result in value?.prepared(input, result) })
            app.copyIndex = 1; value.saveTextCopy()
            try await wait("copy-preparation-not-entered") { preparationPause.entered && value.copying != nil }
            value.stop(); preparationPause.release()
            try await wait("stopped-preparation-not-drained") { !value.isBusy && !value.preparation.isDraining }
            try need(app.publishCount == 0, "stopped-preparation-published")
            try await fixture.requireNoExport(1)

            // Publication still uses the real App writer and FileOperations
            // result. Cancellation is never rewritten as a successful receipt.
            let publicationPause = try await fixture.armActualPublicationPause(2)
            actualPublicationPause = publicationPause; app.copyIndex = 2
            value.saveTextCopy()
            try await publicationPause.waitForActualSyncedEntry()
            try need(publicationPause.actualSyncedEntries == 1 && app.publishCount == 1
                && app.copyResults.isEmpty && value.work != nil, "real-file-publication-boundary-not-owned")
            value.stop(); publicationPause.release()
            try await wait("stopped-publication-not-returned") { !value.isBusy && !value.preparation.isDraining }
            try need(publicationPause.actualSyncedEntries == 1, "actual-file-publication-entry-repeated")
            try need(app.publishCount == 1 && app.copyResults.count == 1, "actual-local-publication-result-missing")
            switch app.copyResults[0] {
            case "saved":
                try await fixture.requireExactExport(2, try .edited(visibleText, format: value.state.value.format))
                try need(value.copyRecords.count == 1 && value.protectedCopies.isEmpty, "saved-copy-ui-does-not-match-actual-result")
            case "refused", "threw":
                try await fixture.requireNoExport(2)
                try need(value.copyRecords.isEmpty && value.protectedCopies.isEmpty, "refused-copy-ui-claimed-publication")
            default: throw Failure(stage: "stopped-publication-uncertain-preserve-evidence")
            }
            try need(!value.closed && textView.string == visibleText, "local-copy-stop-discarded-detached-text")

            let recordsBefore = value.copyRecords.count
            app.copyIndex = 3; value.saveTextCopy()
            try await wait("ordinary-local-text-copy-not-settled") { !value.isBusy && !value.preparation.isDraining }
            try need(app.publishCount == 2 && app.copyResults.last == "saved"
                && value.copyRecords.count == recordsBefore + 1, "local-text-copy-not-verified")
            try await fixture.requireExactExport(3, try .edited(visibleText, format: value.state.value.format))
            try noRemoteChange(detached, try await backend.observations())
            try await backend.requireExactRetainedGraph()
            checks.append("Local Text Copy Stop joins chooser/preparation/publication and reports the actual local result without remote work")
            checks.append("A fresh exact local text copy uses the ordinary App writer, preserves visible text and never acknowledges remote Save")

            removal = try await backend.inspectFreshRemovalAfterDetachment()
            // Make a fresh explicit close decision BEFORE teardown. This failure
            // case may remain review-required; that is an expected safe result,
            // not evidence that remote closure or local retirement completed.
            value.requestClose()
            if let closing = value.closingWork { _ = await closing.value }
            if !value.closed {
                try need(value.needsReview && value.remoteBodyHandoffAttempted
                    && value.window.surface.textView === textView && textView.string == visibleText
                    && nativeWindow?.isVisible == true, "fresh-close-lost-review-required-native-buffer")
                checks.append("Fresh explicit close remains review-required with the same visible buffer; no completed remote close is claimed")
            } else {
                checks.append("Fresh explicit close completed according to the actual durable backend result")
            }
            try need(inputEvents == 0, "owner-input-interrupted-native-check")
            status = "PASS"
        } catch let failure as Failure { failureStage = failure.stage }
        catch { failureStage = "dependency-or-actual-operation-refused" }

        // Every failure releases only its owned gates and then joins real work.
        app.chooserPause?.release(); actualPublicationPause?.release(); preparationPause.release()
        if !failureHoldReleased {
            backend.abortOwnedFailureHold()
            do { try await backend.waitForFailureHoldDrain(); failureHoldReleased = true }
            catch { status = "FAILED"; cleanupFailureStages.append("owned-failure-hold-release-incomplete") }
        }
        if let document {
            document.work?.cancel()
            if let work = document.work { await work.value }
            if let closing = document.closingWork { _ = await closing.value }
            await document.preparation.closeAndDrain()
            if !document.closed && !document.remoteBodyHandoffAttempted {
                document.requestClose()
                if let closing = document.closingWork { _ = await closing.value }
            }
            // A failed close can install a new presentation owner while it
            // reopens; join that actual replacement too before fixture disposal.
            await document.preparation.closeAndDrain()
        }
        // Always attempt both independent drains, even if the first throws.
        do { try await backend.closeAndDrain() }
        catch { status = "FAILED"; cleanupFailureStages.append("actual-backend-drain-incomplete") }
        do { try await fixture.closeAndDrain() }
        catch { status = "FAILED"; cleanupFailureStages.append("actual-app-fixture-drain-incomplete") }
        do {
            let final = try await backend.observations()
            try need(final.instrumentationArmed && final.outstandingOwners == 0, "actual-backend-owner-still-pending")
            if let document, !document.closed {
                try need(document.remoteBodyHandoffAttempted, "cannot-dispose-generated-surface-with-live-remote-owner")
                // Generated fixture disposal ONLY, after the independent normal
                // close/refusal oracle and actual backend drain. It is not a
                // passing ordinary Close or remote-retirement receipt.
                document.window.retainPresentationDuringClose = false
                document.window.finishClose()
                try need(document.window.window?.isVisible != true
                    && document.window.surface.textView.string.isEmpty,
                    "generated-native-surface-disposal-incomplete")
            }
        } catch let failure as Failure {
            status = "FAILED"
            switch failure.stage {
            case "actual-backend-owner-still-pending",
                 "cannot-dispose-generated-surface-with-live-remote-owner",
                 "generated-native-surface-disposal-incomplete":
                cleanupFailureStages.append(failure.stage)
            default:
                cleanupFailureStages.append("actual-final-resource-observation-unavailable")
            }
        } catch {
            status = "FAILED"
            cleanupFailureStages.append("actual-final-resource-observation-unavailable")
        }
        if status == "PASS" && !(2...8).contains(callback.value) {
            status = "FAILED"; cleanupFailureStages.append("final-native-close-callback-count")
        }
        return .init(status: status, failureStage: failureStage,
            cleanupFailureStages: cleanupFailureStages, checks: checks,
            nativeCloseAtFirstPinDrain: nativeCloseAtFirstPinDrain,
            nativeCloseCallbacks: callback.value, inputEvents: inputEvents,
            copyPublishEntries: app.publishCount, copyResults: app.copyResults, removal: removal)
    }
}
#endif
