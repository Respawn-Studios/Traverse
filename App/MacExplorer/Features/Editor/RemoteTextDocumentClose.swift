import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

@MainActor extension RemoteTextDocumentController {
    func requestClose() {
        guard !closed, closingWork == nil, !closeAfterSave else { return }
        let request = UUID(); closingRequest = request
        closingWork = Task { [self] in
            let result = await decideClose()
            if closingRequest == request { closingWork = nil; closingRequest = nil }
            // nil hands this SAME close intent to its chosen Save.
            if let result { resolveClose(result) }
            if !closed { refresh() }
            return result ?? false
        }
        refresh()
    }
    func closeForTermination() async -> Bool {
        if closed { return true }
        guard closingWork != nil || closeAfterSave || (!isBusy && window.window != nil) else {
            message = "Finish or Stop this work before closing. Your text stays owned."
            show(); refresh(); return false
        }
        return await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            if closingWork == nil && !closeAfterSave { requestClose() }
        }
    }
    private func resolveClose(_ value: Bool) {
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }
    /// Call after actual preparation/Save/Stop completion. A newer edit or
    /// uncertain result resolves false without silently making a new decision.
    func finishChosenSaveForCloseIfIdle() {
        guard closeAfterSave, !isBusy else { return }
        closeAfterSave = false
        guard !disconnected, !needsReview, unappliedSave == nil,
              state.closeDisposition == .ready else {
            resolveClose(false); refresh(); return
        }
        requestClose()
    }
    private func decideClose() async -> Bool? {
        guard !isBusy, let native = window.window, let request = closingRequest else {
            message = "Finish or Stop this work, then close again. Your text and workers stay owned."
            show(); refresh(); return false
        }
        guard !window.surface.textView.hasMarkedText() else {
            message = "Finish entering this text before closing. Your text is kept."; refresh(); return false
        }
        window.surface.textView.isEditable = false
        let mustDecide = state.isDirty || needsReview || state.unresolvedSave != nil || unappliedSave != nil
        if mustDecide {
            let choice = await interactions.chooseClose(native, needsReview || disconnected || saveRefusal?.requiresReopen == true)
            switch choice {
            case .cancel: return false
            case .review: closingWork = nil; reviewVersions(); return false
            case .save:
                closingWork = nil; closeAfterSave = true
                window.surface.textView.isEditable = true
                save(); return nil
            case .textCopy:
                closingWork = nil; saveTextCopy(); return false
            case .discard: break
            }
        }
        let backend = await remote.closeAfterExplicitBufferDecision()
        let needsBufferHandoff: Bool
        switch backend {
        case .pending, .needsReview:
            needsReview = true; message = "Closure needs review. This document and its text remain owned."; return false
        case .readyToCloseBuffer: needsBufferHandoff = true
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            // A terminal backend result before the first native close would
            // mean the body was retired while its text was still visible.
            guard remoteBodyHandoffAttempted else {
                needsReview = true; message = "Closure needs review. Keep this text visible."; return false
            }
            needsBufferHandoff = false
        }
        await window.closeComparisonAndDrain()
        await preparation.closeAndDrain()
        window.retainPresentationDuringClose = true
        nativeDidClose = false
        let faded = await window.prepareAcceptedClose()
        guard closingRequest == request, window.window === native else {
            window.cancelAcceptedClosePreparation()
            reopenAfterIncompleteClose(); return false
        }
        // The remote close handoff is already sealed. Re-show/cancellation can
        // stop its optional fade, but cannot make that backend editable again.
        if !faded { window.cancelAcceptedClosePreparation() }
        if !nativeDidClose { window.finishClose() }
        guard nativeDidClose else {
            preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
            window.reopenAfterFailedClose()
            needsReview = true; message = "The editor window did not close. Your text stays visible."
            return false
        }
        let final = needsBufferHandoff ? await remote.nativeBufferDidClose() : backend
        if needsBufferHandoff { remoteBodyHandoffAttempted = true }
        switch final {
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            do { try state.discardAndClose() }
            catch {
                reopenAfterIncompleteClose(); return false
            }
        case .readyToCloseBuffer, .pending, .needsReview:
            reopenAfterIncompleteClose(); return false
        }
        closed = true; pendingEdit = nil; copying = nil; capturePresentationGeneration = nil
        unappliedSave = nil; window.surface.clearPrivatePresentation()
        window.retainPresentationDuringClose = false
        didClose?(id)
        return true
    }
    private func reopenAfterIncompleteClose() {
        preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
        window.reopenAfterFailedClose(); nativeDidClose = false
        disconnected = true; needsReview = true
        message = remoteBodyHandoffAttempted
            ? "Local recovery text and Undo history are kept. Save a Text Copy; remote reads are unavailable here."
            : "Local closure needs review. Your text and Undo history are kept; save a Text Copy if needed."
        present(); refresh()
    }
}
