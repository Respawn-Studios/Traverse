import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

@MainActor struct RemoteEditorInteractions {
    var acquireSave: () async throws -> UUID
    var acquireCopy: () async throws -> UUID
    var finishMutation: (UUID) -> Void
    var chooseCopy: (NSWindow, String) async -> EditorSaveDestination?
    var publishCopy: (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult
    var showCopyResult: (UUID) -> Void
    var chooseClose: (NSWindow, Bool) async -> EditorCloseChoice
    var reviewVersions: (RemoteEditableTextBackend, NSWindow,
        RemoteRetainedTextChoice.RefusedReview?) async -> Void
}

@MainActor extension RemoteTextDocumentController {
    func save() {
        defer { finishChosenSaveForCloseIfIdle() }
        guard !remoteBodyHandoffAttempted, !isBusy, closingWork == nil, !closed, !disconnected, !needsReview,
              saveRefusal?.requiresReopen != true else { return }
        guard !window.surface.textView.hasMarkedText() else { message = "Finish entering this text before Save."; refresh(); return }
        // Capture before any suspension; new typing must never replace this Save.
        let raw = window.surface.textView.string
        copyNotice = nil
        saveExplanation = nil
        saveRefusal = nil
        refusedSaveGeneration = nil
        var capturedGeneration: UUID?
        do {
            let capture = try state.captureSave()
            capturedGeneration = capture.id
            noteSaveBoundary(.captured, generation: capture.id)
            capturePresentationGeneration = (capture.id, state.currentGeneration)
            message = "Preparing captured text…"
            do { try preparation.submit(.save(capture: capture, text: raw)) }
            catch { try? state.finishCancelledCapture(capture); capturePresentationGeneration = nil; throw error }
        } catch {
            if let capturedGeneration { noteSaveBoundary(.captureFailed, generation: capturedGeneration) }
            message = "Save could not be prepared. Your text is kept."
        }
        refresh()
    }
    func startSave(_ snapshot: TextSaveSnapshot) {
        precondition(work == nil)
        message = "Waiting to save the captured remote file…"
        noteSaveBoundary(.awaitingPermit, generation: snapshot.id)
        work = Task { [self] in
            var permit: UUID?
            var receivedRemoteResult = false
            var announcement = NativeTextEditorWindow.SaveAnnouncement.needsReview
            do {
                permit = try await interactions.acquireSave()
                noteSaveBoundary(.permitAcquired, generation: snapshot.id)
                try Task.checkCancellation()
                // A forced Disconnect may have occurred while admission waited.
                guard !disconnected else { throw CancellationError() }
                message = "Saving captured remote file…"; refresh()
                noteSaveBoundary(.remoteSaveCalled, generation: snapshot.id)
                let result = await remote.save(contents: snapshot.value, generation: snapshot.id)
                receivedRemoteResult = true
                #if TRAVERSE_SFTP_EDITOR_QA
                if GeneratedSandboxReview.smbOriginalSaveReviewAdmitted,
                   let checkpoint = await remote.smbSaveDiagnosticCheckpoint(for: snapshot.id) {
                    // The counted review records only a fixed boundary number.
                    print("TRAVERSE_SMB_EDITOR_SAVE_CHECKPOINT \(checkpoint)")
                    fflush(stdout)
                }
                #endif
                noteSaveBoundary(.remoteResultReceived, generation: snapshot.id)
                #if DEBUG
                if verificationRejectSaveApplication { throw TextDocumentFailure.invalidReceipt }
                #endif
                switch result {
                case .saved(let generation) where generation == snapshot.id:
                    try state.finishSave(snapshot, result: .confirmed(TextDocumentBinding()))
                    noteSaveBoundary(.saved, generation: snapshot.id)
                    message = state.isDirty ? "Captured text saved · newer visible edits remain unsaved" : "Saved · " + remote.protocolName
                    announcement = .saved(newerEditsRemain: state.isDirty)
                case .refusedBeforeSubmission(let reason):
                    try state.finishSave(snapshot, result: .failed)
                    saveRefusal = reason
                    refusedSaveGeneration = reason.offersCapturedVersionReview ? snapshot.id : nil
                    noteSaveBoundary(.refused(reason), generation: snapshot.id)
                    let notice = reason.presentation
                    message = notice.status; saveExplanation = notice.explanation
                    announcement = .notSaved
                case .needsReview, .saved:
                    // A verified remote write with incomplete recovery is still
                    // not permission to replace the trusted UI baseline.
                    try state.finishSave(snapshot, result: .uncertain)
                    noteSaveBoundary(.resultNeedsReview, generation: snapshot.id)
                    needsReview = true; disconnected = true
                    message = "Needs Review · before/edited versions retained"
                }
            } catch {
                if receivedRemoteResult {
                    noteSaveBoundary(.resultApplyFailed, generation: snapshot.id)
                    // The backend returned an actual outcome. Failure to apply it
                    // cannot establish that submission never happened.
                    unappliedSave = snapshot; needsReview = true; disconnected = true
                    if state.activeSave?.id == snapshot.id { try? state.finishSave(snapshot, result: .uncertain) }
                    message = "Needs Review · the remote Save result could not be applied; retained versions stay protected"
                } else {
                    noteSaveBoundary(.failedBeforeRemoteResult, generation: snapshot.id)
                    if state.activeSave?.id == snapshot.id { try? state.finishSave(snapshot, result: .failed) }
                    message = "Save did not start. Your text is kept."
                    announcement = error is CancellationError ? .stopped : .notSaved
                }
            }
            // Actual remote save returned; task cancellation is never a receipt.
            if let permit { interactions.finishMutation(permit) }
            work = nil; present(); refresh()
            if !closed, closingWork == nil, !closeAfterSave { window.announceSaveResult(announcement, attempt: snapshot.id) }
            finishChosenSaveForCloseIfIdle()
        }
    }
    func stop() {
        guard closingWork == nil, !closed else { return }
        if remoteBodyHandoffAttempted {
            // The reopened native surface owns local text only. Stop may cancel
            // its chooser or preparation; publication still reports its actual
            // result. Never call the retired remote session from this state.
            guard work != nil || copying != nil || choosing else { return }
            if let copy = copying { preparation.stopSave(copy.capture.id) }
            work?.cancel()
            copyNotice = "Stopping local text copy…"; refresh()
            return
        }
        copyNotice = nil
        if let capture = state.activeCapture { try? state.requestStop(for: capture); preparation.stopSave(capture.id) }
        if let save = state.activeSave { try? state.requestStop(for: save) }
        if let copy = copying { preparation.stopSave(copy.capture.id) }
        // Cancel only waiting admission/local copy tasks. Submitted remote Save
        // still joins its actor task; requestStop joins the connection worker.
        work?.cancel()
        guard stopWork == nil else { return }
        disconnected = true; message = "Stopping this " + remote.protocolName + " connection…"; refresh()
        stopWork = Task { [self] in
            let result = await remote.stopAndDrain()
            if result { message = "Stopped · visible text and retained versions are kept" }
            else { needsReview = true; message = "Needs Review · actual closure is incomplete" }
            stopWork = nil; finishChosenSaveForCloseIfIdle(); refresh()
        }
    }
    func saveTextCopy() {
        guard !isBusy, closingWork == nil, !closed, protectedCopies.count < 8,
              !window.surface.textView.hasMarkedText(), let native = window.window,
              let binding = state.binding else { return }
        let raw = window.surface.textView.string
        let capture = TextCopyCapture(binding: binding, surfaceGeneration: window.surface.generation, format: state.value.format)
        choosing = true; copyNotice = "Choose a local text copy destination…"; refresh()
        work = Task { [self] in
            let target = await interactions.chooseCopy(native, displayName)
            choosing = false; work = nil
            guard !Task.isCancelled, !closed, let target else { copyNotice = "Text copy cancelled. Your text is kept."; refresh(); return }
            let intended = target.directory.appendingPathComponent(target.name).standardizedFileURL
            guard !protectedCopies.contains(intended) else { copyNotice = "That unconfirmed copy stays protected. Choose another new filename."; refresh(); return }
            copying = (capture, target)
            do { try preparation.submit(.copy(capture: capture, text: raw)) }
            catch { copying = nil; copyNotice = "Text copy could not be prepared. Your text is kept." }
            refresh()
        }
    }
    func startCopy(_ value: TextDocumentValue, capture: TextCopyCapture, destination: EditorSaveDestination) {
        guard let native = window.window else { copying = nil; return }
        precondition(work == nil)
        work = Task { [self] in
            let intended = destination.directory.appendingPathComponent(destination.name).standardizedFileURL
            var permit: UUID?
            do {
                permit = try await interactions.acquireCopy(); try Task.checkCancellation()
                let result = try await interactions.publishCopy(value, capture.id, destination, native)
                switch result {
                case .saved(let receipt) where receipt.generation == capture.id && receipt.document.contents == value:
                    copyRecords = Array((copyRecords + [receipt.recordID]).suffix(8))
                    copyNotice = window.surface.generation == capture.surfaceGeneration
                        ? "A local text copy was saved. The remote document stays open."
                        : "Captured text saved locally. Newer visible edits remain unsaved."
                case .saved:
                    protectedCopies.append(intended); copyNotice = "Local text copy needs review. Keep this visible text."
                case .uncertain(let publication), .publishedNeedsReload(let publication):
                    protectedCopies.append(intended)
                    if publication.generation == capture.id, publication.intendedURL.standardizedFileURL == intended,
                       let record = publication.recordID { copyRecords = Array((copyRecords + [record]).suffix(8)) }
                    copyNotice = "Local text copy is unconfirmed. Keep this text and review Copy Results."
                case .refused: copyNotice = "Local text copy was not saved. Your text is kept."
                }
            } catch { copyNotice = "Local text copy was not saved. Your text is kept." }
            if let permit { interactions.finishMutation(permit) }
            withExtendedLifetime(destination.access) {}
            copying = nil; work = nil; present(); refresh()
            // No local copy acknowledges an uncertain remote Save or closes
            // dirty visible text. Closing requires a fresh explicit decision.
        }
    }
}
