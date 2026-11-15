import AppKit
import FileOperations
import LocalStorage

/// One captured archive member, using the ordinary native editor and the existing
/// archive producer/journal. No extracted editable file or second Save engine.
@MainActor final class ArchiveTextDocumentController {
    let id = UUID()
    let window: NativeTextEditorWindow
    private(set) var opened: ArchiveEditableTextDocument
    private var formatName: String { opened.formatName }
    private let engine: RecoverableFileOperations
    private let access: FileAccessLifetimes
    private let interactions: ArchiveEditorInteractions
    private var state: TextDocumentState
    private var pendingEdit: TextEditTicket?
    private var work: Task<Void, Never>?
    private var closeWork: Task<Bool, Never>?
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private var choosing = false, closing = false, closed = false, closeAfterSave = false
    private var nativeDidClose = false
    private var preferences = EditorPreferences()
    private var language = TextSyntaxLanguage.plain
    private var languageOverride = false, wrappingOverride = false
    private var captureGeneration: UUID?
    private var copyName: String?
    private var messageText = "Ready"
    private var explanation: String?
    private(set) var latestRecordID: UUID?
    private var textCopyRecords: [UUID] = []
    var didClose: ((UUID) -> Void)?
    private lazy var preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }

    init(opened: ArchiveEditableTextDocument, engine: RecoverableFileOperations,
         access: FileAccessLifetimes, interactions: ArchiveEditorInteractions,
         installChrome: (NSWindow) -> Void) {
        self.opened = opened; self.engine = engine
        self.access = access; self.interactions = interactions
        state = .init(value: opened.contents, binding: TextDocumentBinding())
        window = .init(displayName: opened.displayName + " · " + opened.formatName, installChrome: installChrome)
        window.surface.install(opened.contents)
        messageText = "Ready · " + opened.formatName
        window.saveAsButton.title = "Save " + opened.formatName + " Copy…"
        window.saveAsMenuTitle = window.saveAsButton.title
        window.recoveryButton.title = "View " + opened.formatName + " Result…"
        window.recoveryMenuTitle = window.recoveryButton.title
        window.saveButton.toolTip = "Update this text file inside its " + opened.formatName + ". The earlier archive is kept for Undo."
        window.onSave = { [weak self] in self?.save() }
        window.captureComparison = { [weak self] in
            guard let self, !closed, !closing, !isBusy,
                  let baseline = state.comparisonBaseline else { return nil }
            return .init(baseline: baseline, current: window.surface.textView.string,
                format: state.value.format, language: language)
        }
        window.onSaveAs = { [weak self] in self?.saveArchiveCopy() }
        window.onTextCopy = { [weak self] in self?.saveTextCopy() }
        window.onTextCopyResults = { [weak self] record in
            guard let self, let id = record ?? textCopyRecords.last else { return }; interactions.showResult(id)
        }
        window.onReload = { [weak self] in self?.reload() }
        window.onRecovery = { [weak self] in
            guard let self, let id = latestRecordID else { return }; interactions.showResult(id)
        }
        window.onStop = { [weak self] in self?.stop() }
        window.onLanguage = { [weak self] value in self?.languageOverride = true; self?.language = value; self?.present() }
        window.onWrapping = { [weak self] in self?.wrappingOverride = true }
        window.surface.onEdit = { [weak self] _, _ in
            guard let self, !closed else { return }
            do {
                pendingEdit = try state.beginEdit()
                if !isBusy && !needsReview { messageText = "Edited · " + formatName }
                present()
            }
            catch { messageText = "This change could not be validated. Keep the editor open." }
            refresh()
        }
        window.surface.onRejectedEdit = { [weak self] _ in
            self?.messageText = "This text exceeds the editor limit. Your current text is kept."; self?.refresh()
        }
        window.shouldClose = { [weak self] in self?.requestClose(); return false }
        window.didClose = { [weak self] in self?.nativeDidClose = true }
        present(); refresh()
    }
    var isClosed: Bool { closed }
    var isDirty: Bool { state.isDirty }
    var isBusy: Bool { work != nil || choosing || closing || state.activeCapture != nil || state.activeSave != nil }
    var needsReview: Bool { state.unresolvedSave != nil }
    func show() { window.presentEditor(in: .local, arrangement: preferences.windowArrangement) }
    func applyPreferences(_ value: EditorPreferences, pointSize: CGFloat) {
        preferences = value
        window.applyEditorPreferences(value, pointSize: pointSize, applyWrapping: !wrappingOverride)
        if !languageOverride { language = value.language(forFilename: opened.displayName) }
        window.selectLanguage(language); present()
    }
    private func present() {
        guard !closed else { return }
        do { try preparation.submit(.presentation(ticket: pendingEdit, surfaceGeneration: window.surface.generation,
            text: window.surface.textView.string, format: state.value.format, language: language,
            detectsLanguage: shouldDetectLanguage)) }
        catch { messageText = "This text could not be prepared. Your visible text is kept." }
    }
    private var shouldDetectLanguage: Bool {
        !languageOverride && language == .plain && preferences.canDetectLanguage(forFilename: opened.displayName)
    }
    private func prepared(_ input: EditorPreparationInput, _ result: EditorPreparationResult) {
        guard !closed else { return }
        switch input {
        case .presentation(let ticket, let generation, _, _, _, _):
            guard generation == window.surface.generation else { return }
            switch result {
            case .presentation(let value, let syntax, let lines, let detected):
                if let ticket { do { try state.acceptEdit(ticket, value: value); pendingEdit = nil } catch { return } }
                if window.surface.present(value, syntax: syntax, lines: lines, for: generation),
                   let detected, shouldDetectLanguage {
                    language = detected; window.selectLanguage(detected)
                }
            case .invalid(let failure):
                if let ticket { try? state.rejectEdit(ticket, failure: failure); pendingEdit = nil }
                messageText = "This text could not be validated. Your visible text is kept."
            default: break
            }
        case .save(let capture, _):
            guard state.activeCapture?.id == capture.id else { return }
            if case .cancelled = result {
                try? state.finishCancelledCapture(capture); copyName = nil; messageText = "Save preparation stopped."
            } else {
                let validation: Result<TextDocumentValue, TextDocumentFailure>
                switch result {
                case .save(let value): validation = .success(value)
                case .invalid(let failure): validation = .failure(failure)
                default: validation = .failure(.invalidReceipt)
                }
                do {
                    let stopped = state.stopRequested
                    let sameGeneration = captureGeneration == state.currentGeneration
                    let snapshot = try state.finishCapture(capture, prepared: validation)
                    if sameGeneration { pendingEdit = nil }
                    if let snapshot { performSave(snapshot, copyName: copyName) }
                    else if stopped { messageText = "Save stopped · text kept" }
                    else if case .failure(let failure) = validation {
                        messageText = "Text was not saved"; explanation = Self.message(failure)
                    } else {
                        messageText = state.isDirty ? "Captured text unchanged · newer edits remain" : "No changes to save · " + formatName
                    }
                } catch { messageText = Self.message(error) }
                copyName = nil
            }
            captureGeneration = nil
        case .copy: break
        }
        refresh()
        finishChosenSave()
    }
    func save() { captureSave(copyName: nil) }
    func saveArchiveCopy() {
        guard !isBusy, !closed, !needsReview, let native = window.window else { return }
        choosing = true; refresh()
        work = Task { [self] in
            let name = await interactions.chooseArchiveCopyName(native, opened.archiveURL)
            work = nil; choosing = false
            if let name, !Task.isCancelled { captureSave(copyName: name) }
            refresh()
        }
    }
    private func captureSave(copyName: String?) {
        guard !closed, !isBusy, !needsReview else { return }
        guard !window.surface.textView.hasMarkedText() else { messageText = "Finish entering this text before Save."; refresh(); return }
        do {
            let capture = try state.captureSave(as: copyName == nil ? .original : .freshCopy(TextDocumentBinding()))
            captureGeneration = state.currentGeneration; self.copyName = copyName
            explanation = nil; messageText = "Preparing captured text…"
            do { try preparation.submit(.save(capture: capture, text: window.surface.textView.string)) }
            catch { try? state.finishCancelledCapture(capture); self.copyName = nil; throw error }
        } catch { messageText = Self.message(error) }
        refresh()
    }
    private func performSave(_ snapshot: TextSaveSnapshot, copyName: String?) {
        let original = opened
        messageText = "Waiting to save " + formatName + "…"
        work = Task { [self] in
            var permit: UUID?
            var received: RecoverableOperationResult?
            var destination = original.archiveURL
            var announcement = NativeTextEditorWindow.SaveAnnouncement.needsReview
            defer {
                if let permit { interactions.finishMutation(permit) }
                work = nil; refresh()
                if !closed, !closing, !closeAfterSave { window.announceSaveResult(announcement, attempt: snapshot.id) }
                finishChosenSave()
                withExtendedLifetime(access) {}
            }
            ApplicationDiagnostics.shared.event(.archiveCreate, .waiting, trace: snapshot.id, relatedTrace: id)
            do {
                permit = try await interactions.acquireMutation(); try Task.checkCancellation()
                let source = try await engine.observeSelection([original.archiveURL])
                if copyName == nil { try await interactions.requireUnreferenced(original.archiveURL) }
                let plan = try await original.prepareSave(contents: snapshot.value, copyName: copyName,
                    observing: source, using: engine)
                if copyName == nil { try await interactions.requireUnreferenced(original.archiveURL) }
                try Task.checkCancellation()
                destination = plan.destination
                messageText = "Saving and verifying " + formatName + "…"; refresh()
                let result = await plan.perform(using: engine, progress: nil)
                received = result
                if let id = result.recordID { latestRecordID = id }
                // Rebind the editor before asking its browser to refresh the
                // same reader. Gzip preparation is a full, cancellable read;
                // a competing refresh must not make a confirmed Save look busy.
                defer { interactions.publish(result, copyName == nil ? original.archiveURL : nil, destination) }
                guard result.result.disposition == .succeeded, result.recordID != nil,
                      result.result.items.count == 1, result.result.items[0].status == .succeeded,
                      result.result.items[0].recoveryURLs.isEmpty else {
                    let uncertain = result.recordID != nil || result.result.items.contains { !$0.recoveryURLs.isEmpty || $0.status == .failed(.recoveryUncertain) }
                    try state.finishSave(snapshot, result: uncertain ? .uncertain : .failed)
                    messageText = uncertain ? formatName + " Save needs review" : formatName + " was not saved"
                    explanation = OperationResultDescription(result: result.result).summary
                    if !uncertain {
                        if result.result.disposition == .cancelled { announcement = .stopped }
                        else if result.result.items.contains(where: { $0.status == .failed(.sourceChanged) }) { announcement = .conflict }
                        else { announcement = .notSaved }
                    }
                    return
                }
                // Success acknowledges only the captured generation and a fresh
                // exact member in the engine-confirmed output, never newer typing.
                let rebound = try await original.reopen(at: destination,
                    expecting: snapshot.value, retaining: access)
                opened = rebound
                try state.finishSave(snapshot, result: .confirmed(TextDocumentBinding()))
                messageText = state.isDirty ? "Captured text saved · newer edits remain" : "Saved · " + formatName
                explanation = nil
                ApplicationDiagnostics.shared.event(.archiveCreate, .completed, trace: snapshot.id, relatedTrace: id)
                announcement = .saved(newerEditsRemain: state.isDirty)
            } catch {
                let published = received?.recordID != nil
                if state.activeSave?.id == snapshot.id {
                    try? state.finishSave(snapshot, result: published ? .uncertain : error is CancellationError ? .cancelledBeforeMutation : .failed)
                }
                messageText = published ? formatName + " Save needs review" : error is CancellationError ? "Save stopped · text kept" : formatName + " was not saved"
                explanation = published ? "The archive operation has a recorded result, but this editor could not confirm its new text. Keep this draft and review its result before another Save." : Self.message(error)
                ApplicationDiagnostics.shared.event(.archiveCreate, published ? .interrupted : error is CancellationError ? .cancelled : .failed,
                    trace: snapshot.id, error: DiagnosticErrors.project(error), relatedTrace: id)
                if !published, !(error is TextDocumentFailure) {
                    announcement = error is CancellationError ? .stopped : (error as? FileOperationFailure) == .sourceChanged ? .conflict : .notSaved
                }
            }
        }
        refresh()
    }
    func reload() {
        guard !closed, !isBusy, !needsReview, let native = window.window else { return }
        choosing = true; refresh()
        work = Task { [self] in
            defer { work = nil; choosing = false; refresh() }
            guard await interactions.confirmReload(native, state.isDirty), !Task.isCancelled else { return }
            do {
                let fresh = try await opened.reopen(retaining: access)
                try Task.checkCancellation()
                // Reload is an explicit whole-buffer decision, not syntax delivery.
                opened = fresh; state = .init(value: fresh.contents, binding: TextDocumentBinding())
                pendingEdit = nil; window.surface.install(fresh.contents)
                messageText = "Reloaded · " + formatName; explanation = nil; present()
            } catch { messageText = "Reload failed · text kept"; explanation = Self.message(error) }
        }
    }
    func stop() {
        if let capture = state.activeCapture { try? state.requestStop(for: capture); preparation.stopSave(capture.id) }
        if let snapshot = state.activeSave { try? state.requestStop(for: snapshot) }
        work?.cancel(); messageText = "Stopping · waiting for the actual work…"; refresh()
    }
    func saveTextCopy() {
        guard !closed, !isBusy, let native = window.window, !window.surface.textView.hasMarkedText() else { return }
        let text = window.surface.textView.string, format = state.value.format, generation = UUID()
        choosing = true; refresh()
        work = Task { [self] in
            var permit: UUID?
            defer { if let permit { interactions.finishMutation(permit) }; work = nil; choosing = false; refresh() }
            do {
                let value = try await Task.detached(priority: .userInitiated) { try TextDocumentValue.edited(text, format: format) }.value
                try Task.checkCancellation()
                guard let destination = await interactions.chooseTextCopy(native, opened.displayName) else { return }
                permit = try await interactions.acquireMutation(); try Task.checkCancellation()
                switch try await interactions.publishTextCopy(value, generation, destination, native) {
                case .saved(let receipt) where receipt.generation == generation && receipt.document.contents == value:
                    textCopyRecords = Array((textCopyRecords + [receipt.recordID]).suffix(8))
                    messageText = "Text copy saved · archive draft kept"
                case .saved(let receipt):
                    textCopyRecords = Array((textCopyRecords + [receipt.recordID]).suffix(8))
                    messageText = "Text copy needs review"
                case .publishedNeedsReload(let publication), .refused(let publication), .uncertain(let publication):
                    if let id = publication.recordID { textCopyRecords = Array((textCopyRecords + [id]).suffix(8)) }
                    messageText = "Text copy needs review"
                }
            } catch { messageText = "Text copy was not saved"; explanation = Self.message(error) }
        }
    }
    func requestClose() {
        guard !closed, !closeAfterSave else { return }; _ = beginClose()
    }
    func closeForTermination() async -> Bool {
        if closed { return true }
        return await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            if closeWork == nil && !closeAfterSave { _ = beginClose() }
        }
    }
    private func beginClose() -> Task<Bool, Never> {
        if let closeWork { return closeWork }
        let task = Task { [self] in
            let result = await decideClose()
            closeWork = nil
            // A chosen Save continues this same intent after its real worker
            // returns. Quit waits for the final native close, not this task.
            if let result { resolveClose(result) }
            return result ?? false
        }
        closeWork = task; return task
    }
    private func resolveClose(_ value: Bool) {
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }
    private func decideClose() async -> Bool? {
        if closed { return true }
        guard !isBusy, !window.surface.textView.hasMarkedText(), let native = window.window else {
            messageText = "Finish or Stop this work before closing. Your text is kept."; show(); refresh(); return false
        }
        closing = true; choosing = true; window.surface.textView.isEditable = false
        defer { closing = false; refresh() }
        let choice = state.closeDisposition == .ready ? EditorCloseChoice.discard
            : await interactions.chooseClose(native, state.closeDisposition)
        choosing = false; window.surface.textView.isEditable = true
        switch choice {
        case .cancel, .review: refresh(); return false
        case .save:
            closing = false; closeAfterSave = true; save()
            if isBusy { return nil }
            closeAfterSave = false; return false
        case .textCopy: closing = false; saveTextCopy(); return false
        case .discard:
            window.surface.textView.isEditable = false
            await preparation.closeAndDrain()
            window.retainPresentationDuringClose = true
            nativeDidClose = false
            await window.closeComparisonAndDrain()
            guard await window.prepareAcceptedClose(), window.window === native, !Task.isCancelled else {
                window.cancelAcceptedClosePreparation()
                preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
                window.retainPresentationDuringClose = false
                if nativeDidClose { window.reopenAfterFailedClose() }
                return false
            }
            window.finishClose()
            guard nativeDidClose else {
                preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
                window.reopenAfterFailedClose(); messageText = "The editor did not close. Your draft stays visible."; refresh(); return false
            }
            do { try state.discardAndClose() }
            catch {
                preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
                window.reopenAfterFailedClose(); messageText = "Closure needs review. Your draft stays visible."; refresh(); return false
            }
            closed = true; window.surface.clearPrivatePresentation(); window.retainPresentationDuringClose = false
            didClose?(id); return true
        }
    }
    private func finishChosenSave() {
        guard closeAfterSave, !isBusy else { return }
        closeAfterSave = false
        if state.closeDisposition == .ready { requestClose() }
        else { resolveClose(false) }
    }
    private func refresh() {
        guard !closed else { return }
        window.surface.textView.isEditable = !choosing && !closing
        window.update(displayName: opened.displayName + " · " + opened.archiveURL.lastPathComponent,
            dirty: state.isDirty, status: messageText, documentFormat: state.value.format,
            canSave: !isBusy && !needsReview, working: isBusy, canReload: !isBusy && !needsReview,
            needsRecovery: needsReview, explanation: explanation, canReviewVersions: latestRecordID != nil,
            canSaveTextCopy: !isBusy, hasTextCopyRecovery: needsReview,
            canViewTextCopyResults: !isBusy && !textCopyRecords.isEmpty,
            textCopyResults: textCopyRecords.map { .init(id: $0, title: "Local Text Copy") },
            location: .archive(opened.archiveURL, member: opened.archivePath))
    }
    static func message(_ error: Error) -> String {
        if let failure = error as? TextDocumentFailure { return LocalTextDocumentController.failureMessage(failure) }
        if let failure = error as? ArchiveOriginalReferences.Failure { return failure.message }
        if let failure = error as? ZIPTextPreviewFailure {
            switch failure {
            case .tooLarge: return "Text files inside a ZIP can be up to256 KiB. Your draft is kept; Save a Text Copy can preserve a larger edit."
            case .notText: return "This ZIP member is not supported UTF-8 text. Preview it as bytes or extract it instead."
            case .unsupported: return "This ZIP member cannot be edited in Traverse. The archive is unchanged."
            case .limitReached: return "Opening this ZIP text reached its limit. The archive is unchanged."
            }
        }
        if (error as? ZIPArchiveFailure) == .changed { return "The ZIP changed. Reload to review its current text, or save your visible text as a separate copy." }
        if let failure = error as? TARMemberEditFailure { return failure.userMessage }
        if error is TARTextPreviewFailure { return ArchiveTextPreviewOwner.message(error, mode: .text) }
        if (error as? TARArchiveFailure) == .changed {
            return "The TAR changed. Reload to review its current text, or save your visible text as a separate copy."
        }
        return ArchiveCreationModel.message(error)
    }
}
