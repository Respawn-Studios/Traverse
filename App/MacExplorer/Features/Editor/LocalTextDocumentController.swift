import AppKit
import FileOperations
import LocalStorage

/// A chosen *directory* grant is held for the real Save As worker, including
/// private staging and any interrupted outcome. It is not inferred from a URL.
struct EditorSaveDestination: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let directory: URL
    let name: String
    let access: any Sendable
    var description: String { "<chosen editor destination>" }
    var debugDescription: String { description }
}

enum EditorCloseChoice { case save, textCopy, discard, review, cancel }

/// A closed, input-free observation vocabulary. No text, names, locations or
/// native error descriptions cross this optional application diagnostic seam.
enum EditorFileEvent {
    case opening, opened, openFailed, saveCaptured, saveWaiting, saveStarted
    case saved, saveFailed, saveUncertain, reloadStarted, reloaded, reloadFailed
    case reviewingVersions, closed
    case textCopyCaptured, textCopyWaiting, textCopyStarted, textCopySaved, textCopyFailed, textCopyUncertain
    case historyReviewRequired(LocalTextCapacityReason)
}

struct EditorUnresolvedPublication: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: Sendable { case originalSave, freshCopyUnconfirmed, freshCopyPublishedNeedsRead }
    let generation: UUID
    let recordID: UUID?
    let intendedURL: URL
    let kind: Kind
    let publicationStatus: FileOperationStatus
    var description: String { "<unresolved editor publication>" }
    var debugDescription: String { description }
}

/// These are presentation/admission decisions only. They cannot manufacture a
/// filesystem result: the concrete FileSession consumes actual engine receipts.
@MainActor
struct EditorDocumentInteractions {
    var chooseDestination: (NSWindow, URL) async -> EditorSaveDestination?
    var confirmReload: (NSWindow, Bool) async -> Bool
    var confirmHistoryUpgrade: (NSWindow) async -> Bool
    var chooseClose: (NSWindow, TextDocumentState.CloseDisposition) async -> EditorCloseChoice
    var reviewVersions: (LocalTextDocumentController, UUID?) async -> Void
    var acquireInspection: () throws -> UUID
    var finishInspection: (UUID) -> Void
    var acquireMutation: () async throws -> UUID
    var finishMutation: (UUID) -> Void
    var chooseTextCopyDestination: ((NSWindow, URL) async -> EditorSaveDestination?)? = nil
    var showTextCopyResults: ((UUID) -> Bool)? = nil
}

/// One visible document owns one CPU-preparation worker and one real file task.
/// Save captures the visible generation immediately; typing may continue while
/// that immutable generation is queued or written. Native text Undo never calls
/// filesystem Undo. Closing joins actual work before releasing access/buffers.
@MainActor
final class LocalTextDocumentController {
    let id = UUID()
    let window: NativeTextEditorWindow
    let files: LocalEditorFileSession
    private let interactions: EditorDocumentInteractions
    private var state: TextDocumentState?
    private var pendingEdit: TextEditTicket?
    private var pendingFileJump: (jump: EditorFileJump, generation: UUID, selection: NSRange, viewport: NSPoint)?
    private var language = TextSyntaxLanguage.plain
    private var editorPreferences = EditorPreferences()
    private var languageWasOverridden = false
    private var wrappingWasOverridden = false
    private var fileTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private var nativeDidClose = false
    private var destination: EditorSaveDestination?
    private var pendingTextCopy: TextCopyCapture?
    private var textCopyDestination: EditorSaveDestination?
    private var textCopyNotice: String?
    private struct UnconfirmedTextCopy { let url: URL; let recordID: UUID? }
    private var unconfirmedTextCopies: [UnconfirmedTextCopy] = []
    private(set) var textCopyRecordID: UUID?
    private var choosing = false
    private var closing = false
    private var closed = false
    private var closeAfterSave = false
    private var message = "Opening…"
    private var explanation: String?
    private var historyReviewReason: LocalTextCapacityReason?
    private(set) var latestRecordID: UUID?
    private(set) var uncertainRecordID: UUID?
    private(set) var unresolvedPublication: EditorUnresolvedPublication?
    private(set) var initialURL: URL
    var didClose: ((UUID) -> Void)?
    var didChangeURL: ((UUID, URL) -> Void)?
    var observedFileEvent: ((EditorFileEvent, UUID?, UUID?, FileOperationStatus?) -> Void)?
    private lazy var preparation = EditorPreparationOwner { [weak self] input, result in
        self?.prepared(input, result)
    }

    init(url: URL, files: LocalEditorFileSession, interactions: EditorDocumentInteractions,
         installChrome: (NSWindow) -> Void) {
        initialURL = url; self.files = files; self.interactions = interactions
        window = NativeTextEditorWindow(displayName: url.lastPathComponent, supportsFileSidebar: true, installChrome: installChrome)
        window.onSave = { [weak self] in self?.save() }
        window.onSaveAs = { [weak self] in self?.chooseSaveAs() }
        window.onTextCopy = { [weak self] in self?.chooseTextCopy() }
        window.onTextCopyResults = { [weak self] record in self?.viewTextCopyResults(record) }
        window.onReload = { [weak self] in self?.reload() }
        window.onStop = { [weak self] in self?.stop() }
        window.onRecovery = { [weak self] in self?.reviewVersions() }
        window.captureComparison = { [weak self] in
            guard let self, canCaptureComparison,
                  let state, let baseline = state.comparisonBaseline else { return nil }
            return .init(baseline: baseline, current: window.surface.textView.string,
                format: state.value.format, language: language, currentEditor: window.editableBufferIdentity)
        }
        window.diskComparisonSource = { [weak self] in self?.diskComparison() }
        window.onLanguage = { [weak self] value in
            self?.languageWasOverridden = true; self?.changeLanguage(value)
        }
        window.onWrapping = { [weak self] in self?.wrappingWasOverridden = true }
        window.shouldClose = { [weak self] in self?.requestClose(); return false }
        window.didClose = { [weak self] in
            self?.nativeDidClose = true
        }
        window.surface.onEdit = { [weak self] text, generation in self?.edited(text, generation: generation) }
        window.surface.onRejectedEdit = { [weak self] failure in
            self?.message = Self.failureMessage(failure); self?.refresh()
        }
        refresh()
    }

    /// Live app preferences change presentation only. Per-document Wrap/Syntax
    /// choices retain priority through Reload and newer preference notifications.
    func applyEditorPreferences(_ value: EditorPreferences, pointSize: CGFloat) {
        guard !closed, value.isValid else { return }
        let oldLanguage = language
        let detectionChanged = editorPreferences.detectsLanguageWithoutExtension != value.detectsLanguageWithoutExtension
            || editorPreferences.defaultLanguage != value.defaultLanguage
        editorPreferences = value
        window.applyEditorPreferences(value, pointSize: pointSize, applyWrapping: !wrappingWasOverridden)
        if !languageWasOverridden {
            language = value.language(forFilename: currentURL.lastPathComponent)
            window.selectLanguage(language)
        }
        if language != oldLanguage || (detectionChanged && !languageWasOverridden)
            || window.surface.needsLineChangePreparation(for: state?.savedTextBaseline) {
            submitPresentation(ticket: pendingEdit)
        }
    }

    var currentURL: URL { files.currentURL ?? initialURL }
    var isDirty: Bool { state?.isDirty ?? false }
    var isClosed: Bool { closed }
    var hasPendingFileWork: Bool { fileTask != nil || files.isWorking || choosing }
    var hasPendingSave: Bool { state?.activeCapture != nil || state?.activeSave != nil || pendingTextCopy != nil }
    private var canCaptureComparison: Bool {
        !closed && !closing && !hasPendingFileWork && !hasPendingSave && !window.surface.textView.hasMarkedText()
    }
    var canCaptureDraft: Bool { isDirty && canCaptureComparison }
    var canCaptureCurrentText: Bool { canCaptureComparison && state != nil }

    func editGitIndex(_ action: GitIndexEditAction, fileSystem: LocalFileSystem, access: FolderAccessController,
                      settings: BrowserSettings) {
        guard canCaptureCurrentText, !needsTextRecovery, let url = files.currentURL, let binding = files.binding else { return }
        let token = action == .stageSavedFile ? files.savedTextToken : nil
        if action == .stageSavedFile && token == nil {
            window.reportNavigation("Reload the saved file before staging it.")
            return
        }
        window.editGitIndex(action, for: url, fileSystem: fileSystem, access: access, settings: settings,
            matchingSavedText: token, hasUnsavedEdits: { [weak self] in self?.isDirty == true }) { [weak self] in
                guard let self else { return false }
                return canCaptureCurrentText && !needsTextRecovery && files.binding == binding && files.currentURL == url
            }
    }

    func captureDraft() -> EditorComparisonCapture.Side? {
        guard isDirty else { return nil }
        return captureCurrentText()
    }

    func captureCurrentText() -> EditorComparisonCapture.Side? {
        guard canCaptureComparison, let state else { return nil }
        return .init(text: window.surface.textView.string, format: state.value.format, language: language,
            editor: window.editableBufferIdentity)
    }

    private func diskComparison() -> EditorDiskComparisonSource? {
        guard canCaptureComparison, state != nil, let source = files.currentURL else { return nil }
        return .init(url: source) { [weak self] in
            guard let self, files.currentURL == source, let draft = captureCurrentText() else {
                throw EditorComparisonLoadFailure.unavailable("The editor moved to another file or is busy.")
            }
            let generation = window.surface.generation
            let disk: TextDocumentValue
            do {
                let inspection = try interactions.acquireInspection()
                defer { interactions.finishInspection(inspection) }
                disk = try await files.diskSnapshot(at: source)
            } catch is CancellationError { throw CancellationError() }
            catch {
                throw EditorComparisonLoadFailure.unavailable("The file on disk could not be read. Your editor text is still here.")
            }
            guard canCaptureComparison, generation == window.surface.generation, files.currentURL == source else {
                throw EditorComparisonLoadFailure.unavailable("The editor changed during the read. Refresh to compare the current text.")
            }
            return .init(left: .init(text: disk.text, format: disk.format, language: draft.language), right: draft)
        }
    }

    private var needsTextRecovery: Bool { state?.unresolvedSave != nil || unresolvedPublication != nil }

    func showAndOpen(jump: EditorFileJump? = nil, matching selection: LocalTextOpenSelection? = nil) {
        guard !closed else { return }
        guard fileTask == nil, state == nil else { window.showWindow(nil); return }
        window.presentEditor(in: .local, arrangement: editorPreferences.windowArrangement)
        observedFileEvent?(.opening, nil, nil, nil)
        window.surface.textView.isEditable = false
        fileTask = Task { [weak self] in
            guard let self else { return }
            var inspection: UUID?
            defer { if let inspection { self.interactions.finishInspection(inspection) } }
            do {
                inspection = try self.interactions.acquireInspection()
                let opened = try await self.files.open(self.initialURL, matching: selection)
                self.install(opened)
                if let jump { self.deferFileJump(jump) }
                self.observedFileEvent?(.opened, nil, nil, .succeeded)
            } catch is CancellationError { self.message = "Opening cancelled" }
            catch let failure as FileOperationFailure {
                self.message = selection != nil && (failure == .sourceChanged || failure == .notFound)
                    ? "This file changed after it was selected. Return to the review or picker and choose it again."
                    : "This file could not be opened in the editor. Use Open in Default App or choose another text file."
                self.observedFileEvent?(.openFailed, nil, nil, .failed(failure))
            } catch {
                self.message = "This file could not be opened in the editor. Use Open in Default App or choose another text file."
                self.observedFileEvent?(.openFailed, nil, nil, .failed(.unsupported))
            }
            self.fileTask = nil; self.refresh()
        }
    }

    private func install(_ opened: EditorOpenedDocument) {
        state = TextDocumentState(value: opened.contents, binding: opened.binding)
        pendingEdit = nil
        pendingFileJump = nil
        window.surface.install(opened.contents)
        if !languageWasOverridden { language = editorPreferences.language(forFilename: opened.url.lastPathComponent) }
        window.selectLanguage(language)
        window.surface.textView.isEditable = true
        message = "Ready"; explanation = nil; historyReviewReason = nil
        didChangeURL?(id, opened.url)
        submitPresentation(ticket: nil)
    }

    private func deferFileJump(_ jump: EditorFileJump) {
        let surface = window.surface
        pendingFileJump = (jump, surface.generation, surface.textView.selectedRange(), surface.scrollView.contentView.bounds.origin)
    }

    func revealFileJump(_ jump: EditorFileJump) {
        let surface = window.surface
        guard state != nil, !closed, !closing, window.window?.isKeyWindow == true, !surface.textView.hasMarkedText() else { return }
        guard surface.canGoToLine else { deferFileJump(jump); return }
        switch jump.destination {
        case .line(let address):
            if !surface.goTo(address, generation: surface.generation, remembersLocation: false) {
                message = "Opened the file. The requested line or column is outside it."
                refresh()
            }
        case .match(let match):
            if let range = match.verifiedRange(in: surface.textView.string) {
                surface.revealNavigationSelection(range, remembersLocation: false)
            } else {
                message = "The matching text has changed. The editor kept its current position."
                refresh()
            }
        case .declaration(let entry, let language):
            guard surface.presentedGeneration == surface.generation else { deferFileJump(jump); return }
            if let outline = surface.currentOutlineForSymbols, outline.language == language,
               outline.value.entries.contains(where: { $0 == entry && $0.title.utf16.elementsEqual(entry.title.utf16) }) {
                surface.revealNavigationSelection(.init(location: entry.offset, length: 0), remembersLocation: false)
            } else {
                message = "The declaration could not be verified in this editor. Your current position is unchanged."
                refresh()
            }
        case nil: break
        }
        let navigation = EditorDocumentNavigation.shared
        if let origin = jump.origin, navigation.location(in: window) != origin { navigation.record(origin) }
    }

    private func resolveFileJump(for generation: UUID) {
        guard let request = pendingFileJump else { return }
        pendingFileJump = nil
        let surface = window.surface
        guard request.generation == generation, request.selection == surface.textView.selectedRange(),
              request.viewport == surface.scrollView.contentView.bounds.origin else { return }
        revealFileJump(request.jump)
    }

    private func edited(_ text: String, generation: UUID) {
        pendingFileJump = nil
        guard let state, !closed, !choosing, !closing else { return }
        do {
            let ticket = try state.beginEdit(); pendingEdit = ticket
            try preparation.submit(.presentation(ticket: ticket, surfaceGeneration: generation,
                text: text, format: state.value.format, language: language,
                detectsLanguage: shouldDetectLanguage,
                baseline: window.surface.prepareLineChangeBaseline(state.savedTextBaseline)))
            message = "Edited"; refresh()
        } catch { message = "The edit could not be prepared. Your visible text is still here."; refresh() }
    }
    private func submitPresentation(ticket: TextEditTicket?) {
        guard let state, !closed else { return }
        try? preparation.submit(.presentation(ticket: ticket, surfaceGeneration: window.surface.generation,
            text: window.surface.textView.string, format: state.value.format, language: language,
            detectsLanguage: shouldDetectLanguage,
            baseline: window.surface.prepareLineChangeBaseline(state.savedTextBaseline)))
    }
    private var shouldDetectLanguage: Bool {
        !languageWasOverridden && language == .plain
            && editorPreferences.canDetectLanguage(forFilename: currentURL.lastPathComponent)
    }
    private func changeLanguage(_ value: TextSyntaxLanguage) {
        language = value; submitPresentation(ticket: pendingEdit)
    }
    private func prepared(_ input: EditorPreparationInput, _ result: EditorPreparationResult) {
        guard let state, !closed else { return }
        switch input {
        case .presentation(let request):
            let ticket = request.ticket, surfaceGeneration = request.generation
            switch result {
            case .presentation(let prepared):
                if let ticket, ticket == pendingEdit {
                    do { try state.acceptEdit(ticket, value: prepared.value); pendingEdit = nil }
                    catch { return }
                }
                if window.surface.present(prepared, for: surfaceGeneration) {
                    if let detected = prepared.detectedLanguage, shouldDetectLanguage {
                        language = detected; window.selectLanguage(detected)
                    }
                    resolveFileJump(for: surfaceGeneration)
                }
            case .invalid(let failure):
                if let ticket, ticket == pendingEdit {
                    try? state.rejectEdit(ticket, failure: failure); pendingEdit = nil
                    message = Self.failureMessage(failure)
                }
            case .cancelled, .save, .copy: break
            }
        case .save(let capture, _):
            do {
                if case .cancelled = result {
                    try state.finishCancelledCapture(capture)
                    destination = nil; message = "Save stopped"; closeAfterSave = false
                    resolveClose(false)
                } else {
                    let value: Result<TextDocumentValue, TextDocumentFailure>
                    switch result {
                    case .save(let document): value = .success(document)
                    case .invalid(let failure): value = .failure(failure)
                    default: value = .failure(.invalidReceipt)
                    }
                    if let snapshot = try state.finishCapture(capture, prepared: value) {
                        startSave(snapshot)
                    } else {
                        destination = nil
                        if case .failure(let failure) = value { message = Self.failureMessage(failure) }
                        else { message = state.isDirty ? "Edited" : "No changes to save" }
                        if closeAfterSave, state.closeDisposition == .ready {
                            closeAfterSave = false; requestClose()
                        } else { closeAfterSave = false; resolveClose(false) }
                    }
                }
            } catch { destination = nil; closeAfterSave = false; resolveClose(false); message = "Save preparation needs review. Your visible text is still here." }
        case .copy(let capture, _):
            guard pendingTextCopy?.id == capture.id else { return }
            if case .copy(let value) = result, state.binding == capture.binding,
               files.binding == capture.binding, value.format == capture.format,
               let target = textCopyDestination, !closing {
                textCopyDestination = nil
                startTextCopy(value, capture: capture, destination: target)
            } else {
                pendingTextCopy = nil; textCopyDestination = nil
                if case .cancelled = result { textCopyNotice = "Text copy stopped. Your visible text is still here." }
                else if case .invalid(let failure) = result { textCopyNotice = Self.failureMessage(failure) }
                else { textCopyNotice = "The text copy could not be prepared. Your visible text is still here." }
                let status: FileOperationStatus = if case .cancelled = result { .cancelled } else { .failed(.invalidRequest) }
                observedFileEvent?(.textCopyFailed, capture.id, nil, status)
            }
            // Copy can supersede an in-flight presentation, never its edit.
            // Revalidate the current visible generation after copy preparation.
            submitPresentation(ticket: pendingEdit)
        }
        refresh()
    }

    func save() { captureSave(intent: .original, to: nil) }
    private func captureSave(intent: TextSaveSnapshot.Intent, to target: EditorSaveDestination?) {
        guard let state, fileTask == nil, !closed, !choosing, !closing, unresolvedPublication == nil else {
            closeAfterSave = false; resolveClose(false); return
        }
        guard intent != .original || !files.mustReloadBeforeOriginalSave else {
            closeAfterSave = false; resolveClose(false); message = "Reload the changed file before saving"; refresh(); return
        }
        guard !window.surface.textView.hasMarkedText() else {
            closeAfterSave = false; resolveClose(false); message = "Finish entering this text before saving"; refresh(); return
        }
        do {
            let capture = try state.captureSave(as: intent,
                checkpointUnchangedOriginal: intent == .original && files.requiresUnchangedCheckpoint)
            destination = target
            observedFileEvent?(.saveCaptured, capture.id, nil, nil)
            // Copy-on-write capture happens before any Task suspension.
            let raw = window.surface.textView.string
            message = "Preparing Save…"
            do { try preparation.submit(.save(capture: capture, text: raw)) }
            catch {
                // A rejected admission started no worker for this capture.
                try? state.finishCancelledCapture(capture)
                destination = nil; throw error
            }
            refresh()
        } catch { closeAfterSave = false; resolveClose(false); message = "Finish the current Save or review its result before saving again."; refresh() }
    }
    func chooseSaveAs() {
        guard let state, let nativeWindow = window.window, fileTask == nil, !hasPendingSave,
              state.unresolvedSave == nil, unresolvedPublication == nil, !choosing, !closing, !closed else {
            closeAfterSave = false; resolveClose(false); return
        }
        choosing = true; window.surface.textView.isEditable = false; refresh()
        presentationTask = Task { [weak self] in
            guard let self else { return }
            let choice = await self.interactions.chooseDestination(nativeWindow, self.currentURL)
            self.choosing = false; self.presentationTask = nil
            self.window.surface.textView.isEditable = true
            if let choice, !Task.isCancelled, !self.closed {
                self.captureSave(intent: .freshCopy(TextDocumentBinding()), to: choice)
            } else { self.closeAfterSave = false; self.resolveClose(false); self.refresh() }
        }
    }

    /// Keep an uncertain original Save sealed while publishing a separate,
    /// immutable capture under a new name. This never follows the new file or
    /// acknowledges the original result, even when its copy is confirmed.
    func chooseTextCopy() {
        guard let state, let binding = state.binding, let native = window.window,
              needsTextRecovery, fileTask == nil, !hasPendingSave, !choosing,
              !closing, !closed, files.binding == binding else { resolveClose(false); return }
        guard unconfirmedTextCopies.count < 8 else {
            textCopyNotice = "Several text copies still need review. Keep this window open and review their results."; refresh(); return
        }
        guard !window.surface.textView.hasMarkedText() else {
            textCopyNotice = "Finish entering this text before making a copy."; refresh(); return
        }
        // Capture by COW before a chooser or task can suspend this owner.
        let raw = window.surface.textView.string
        let capture = TextCopyCapture(binding: binding, surfaceGeneration: window.surface.generation,
            format: state.value.format)
        pendingTextCopy = capture; textCopyNotice = "Choose a new file for this text."
        choosing = true; window.surface.textView.isEditable = false
        observedFileEvent?(.textCopyCaptured, capture.id, nil, nil); refresh()
        presentationTask = Task { [weak self] in
            guard let self else { return }
            let picker = self.interactions.chooseTextCopyDestination ?? self.interactions.chooseDestination
            let target = await picker(native, self.currentURL)
            self.choosing = false; self.presentationTask = nil
            self.window.surface.textView.isEditable = true
            guard let target, !Task.isCancelled, !self.closed,
                  self.pendingTextCopy?.id == capture.id, self.state?.binding == capture.binding,
                  self.files.binding == capture.binding else {
                self.pendingTextCopy = nil; self.textCopyDestination = nil
                self.textCopyNotice = "Text copy cancelled. Your visible text is still here."
                self.observedFileEvent?(.textCopyFailed, capture.id, nil, .cancelled)
                self.refresh(); return
            }
            let intended = target.directory.appendingPathComponent(target.name).standardizedFileURL
            let reported = self.unresolvedPublication?.intendedURL.standardizedFileURL
            guard intended != self.currentURL.standardizedFileURL, intended != reported,
                  !self.unconfirmedTextCopies.contains(where: { $0.url == intended }) else {
                self.pendingTextCopy = nil; self.textCopyDestination = nil
                self.textCopyNotice = "Choose a different new filename. The original and any unconfirmed copy must stay protected."
                self.observedFileEvent?(.textCopyFailed, capture.id, nil, .failed(.invalidRequest))
                self.refresh(); return
            }
            self.textCopyDestination = target; self.textCopyNotice = "Preparing text copy…"
            do { try self.preparation.submit(.copy(capture: capture, text: raw)) }
            catch {
                self.pendingTextCopy = nil; self.textCopyDestination = nil
                self.textCopyNotice = "The text copy could not be prepared. Your visible text is still here."
                self.observedFileEvent?(.textCopyFailed, capture.id, nil, .failed(.unavailable))
            }
            self.refresh()
        }
    }

    private func ensureSavingHistory() async throws {
        let readiness = try await files.historyReadiness()
        switch readiness {
        case .available(catalogVersion: 10): break
        case .absent:
            let upgrade = try await files.upgradeHistoryAfterConsent()
            guard upgrade.status == .succeeded, upgrade.catalogVersion == 10 else { throw FileOperationFailure.recoveryUncertain }
        case .available(catalogVersion: 3), .available(catalogVersion: 4), .available(catalogVersion: 7), .available(catalogVersion: 9):
            guard let native = window.window, await interactions.confirmHistoryUpgrade(native) else { throw CancellationError() }
            try Task.checkCancellation()
            let upgrade = try await files.upgradeHistoryAfterConsent()
            guard upgrade.status == .succeeded, upgrade.catalogVersion == 10 else { throw FileOperationFailure.recoveryUncertain }
        default: throw FileOperationFailure.recoveryUncertain
        }
    }

    private func startTextCopy(_ value: TextDocumentValue, capture: TextCopyCapture,
                               destination target: EditorSaveDestination) {
        precondition(fileTask == nil && pendingTextCopy?.id == capture.id)
        let intended = target.directory.appendingPathComponent(target.name).standardizedFileURL
        textCopyNotice = "Waiting to save the text copy…"
        observedFileEvent?(.textCopyWaiting, capture.id, nil, nil)
        fileTask = Task { [weak self] in
            guard let self else { return }
            var permit: UUID?
            do {
                permit = try await self.interactions.acquireMutation()
                try Task.checkCancellation()
                try await self.ensureSavingHistory()
                try Task.checkCancellation()
                self.textCopyNotice = "Saving text copy…"; self.refresh()
                self.observedFileEvent?(.textCopyStarted, capture.id, nil, nil)
                let reply = try await self.files.saveTextCopy(value: value, generation: capture.id,
                    expectedBinding: capture.binding, directory: target.directory, name: target.name, access: target.access)
                self.acceptTextCopy(reply, value: value, capture: capture, intended: intended)
            } catch {
                let status: FileOperationStatus
                if error is CancellationError { status = .cancelled }
                else if let failure = error as? FileOperationFailure { status = .failed(failure) }
                else { status = .failed(.unavailable) }
                self.textCopyNotice = status == .cancelled ? "Text copy stopped. Your visible text is still here."
                    : "The text copy was not saved. Check the chosen folder and try a different new filename. Your visible text is still here."
                self.observedFileEvent?(.textCopyFailed, capture.id, nil, status)
            }
            // The actual worker has returned. Neither cancellation nor a view
            // dismissal may release its mutation permit/destination grant early.
            if let permit { self.interactions.finishMutation(permit) }
            withExtendedLifetime(target.access) {}
            self.pendingTextCopy = nil; self.textCopyDestination = nil; self.fileTask = nil
            self.submitPresentation(ticket: self.pendingEdit); self.refresh()
        }
    }

    private func acceptTextCopy(_ reply: LocalTextSaveAsResult, value: TextDocumentValue,
                                capture: TextCopyCapture, intended: URL) {
        func protectUnconfirmedTarget(recordID: UUID?) {
            if !unconfirmedTextCopies.contains(where: { $0.url == intended }) {
                unconfirmedTextCopies.append(.init(url: intended, recordID: recordID))
            }
        }
        switch reply {
        case .saved(let receipt):
            guard receipt.generation == capture.id, receipt.document.contents == value else {
                protectUnconfirmedTarget(recordID: nil)
                textCopyNotice = "The text copy needs review. Keep this visible text and choose another new filename if you need a further copy."
                observedFileEvent?(.textCopyUncertain, capture.id, nil, .failed(.recoveryUncertain)); return
            }
            textCopyRecordID = receipt.recordID
            textCopyNotice = window.surface.generation == capture.surfaceGeneration
                ? "A text copy was saved. The earlier Save still needs review."
                : "The captured text was saved as a copy. Newer visible edits remain unsaved; the earlier Save still needs review."
            observedFileEvent?(.textCopySaved, capture.id, receipt.recordID, .succeeded)
        case .publishedNeedsReload(let publication), .uncertain(let publication):
            let matched = publication.generation == capture.id && publication.intendedURL.standardizedFileURL == intended
            let record = matched ? publication.recordID : nil
            protectUnconfirmedTarget(recordID: record)
            if let record { textCopyRecordID = record }
            textCopyNotice = "The text copy could not be fully confirmed. Keep this visible text and review Copy Results before using that filename again. The earlier Save still needs review."
            observedFileEvent?(.textCopyUncertain, capture.id, record, .failed(.recoveryUncertain))
        case .refused(let publication):
            let matched = publication.generation == capture.id && publication.intendedURL.standardizedFileURL == intended
            let record = matched ? publication.recordID : nil
            if let record { textCopyRecordID = record }
            textCopyNotice = "The text copy was not saved. Choose a different new filename or check folder access. Your visible text is still here."
            observedFileEvent?(.textCopyFailed, capture.id, record,
                matched ? publication.status : .failed(.recoveryUncertain))
        }
    }

    private var textCopyResults: [EditorTextCopyResult] {
        var result: [EditorTextCopyResult] = []
        if let record = textCopyRecordID { result.append(.init(id: record, title: "Latest available text copy")) }
        for (index, copy) in unconfirmedTextCopies.enumerated() {
            if let record = copy.recordID, !result.contains(where: { $0.id == record }) {
                result.append(.init(id: record, title: "Unconfirmed text copy \(index + 1)"))
            }
        }
        return result
    }
    func viewTextCopyResults(_ chosenRecord: UUID? = nil) {
        guard let record = chosenRecord ?? textCopyRecordID, textCopyResults.contains(where: { $0.id == record }),
              !hasPendingFileWork, !hasPendingSave, !closing, !closed else { return }
        if interactions.showTextCopyResults?(record) != true {
            textCopyNotice = "Copy Results could not be opened yet. Your visible text and the recorded result are kept."; refresh()
        }
    }
    private func startSave(_ snapshot: TextSaveSnapshot) {
        guard fileTask == nil else { preconditionFailure("One real editor file task") }
        let target = destination; destination = nil
        message = "Waiting to save…"
        observedFileEvent?(.saveWaiting, snapshot.id, nil, nil)
        fileTask = Task { [weak self] in
            guard let self else { return }
            var permit: UUID?
            let reply: EditorFileSaveReply
            do {
                permit = try await self.interactions.acquireMutation()
                try Task.checkCancellation()
                try await self.ensureSavingHistory()
                try Task.checkCancellation()
                self.message = "Saving…"; self.refresh()
                self.observedFileEvent?(.saveStarted, snapshot.id, nil, nil)
                if snapshot.intent == .original {
                    reply = await self.files.saveOriginal(snapshot)
                } else if let target {
                    try self.files.retainAccess(target.access)
                    reply = await self.files.saveAs(snapshot, directory: target.directory, name: target.name)
                } else { reply = .refused(.failed(.invalidRequest), recordID: nil) }
            } catch is CancellationError { reply = .refused(.cancelled, recordID: nil) }
            catch let failure as FileOperationFailure { reply = .refused(.failed(failure), recordID: nil) }
            catch is EditorMutationAdmission.Failure { reply = .refused(.failed(.unavailable), recordID: nil) }
            catch { reply = .refused(.failed(.recoveryUncertain), recordID: nil) }
            // Actual worker return comes before admission/access can be released.
            if let permit { self.interactions.finishMutation(permit) }
            let announcement = self.accept(reply, for: snapshot)
            self.fileTask = nil; self.refresh()
            if !self.closed, !self.closing, !self.closeAfterSave, let announcement {
                self.window.announceSaveResult(announcement, attempt: snapshot.id)
            }
            if self.closeAfterSave {
                self.closeAfterSave = false
                if self.state?.closeDisposition == .ready { self.requestClose() }
                else { self.resolveClose(false) }
            }
        }
    }
    private func accept(_ reply: EditorFileSaveReply, for snapshot: TextSaveSnapshot) -> NativeTextEditorWindow.SaveAnnouncement? {
        guard let state else { return nil }
        var announcement = NativeTextEditorWindow.SaveAnnouncement.needsReview
        do {
            switch reply {
            case .confirmed(let generation, let binding, let url, let record, let baselineAdopted):
                guard generation == snapshot.id else { throw TextDocumentFailure.invalidReceipt }
                try state.finishSave(snapshot, result: .confirmed(binding))
                initialURL = url; latestRecordID = record ?? latestRecordID; uncertainRecordID = nil
                unresolvedPublication = nil; historyReviewReason = nil
                message = state.isDirty ? "Saved · newer edits remain" : "Saved"
                explanation = baselineAdopted ? "The reloaded file is now the starting point for future Saves. Earlier versions remain available for review." : nil
                didChangeURL?(id, url)
                observedFileEvent?(.saved, generation, record, .succeeded)
                announcement = .saved(newerEditsRemain: state.isDirty)
            case .historyReviewRequired(let reason):
                try state.finishSave(snapshot, result: .failed)
                closeAfterSave = false; resolveClose(false); historyReviewReason = reason
                message = "Not saved · review saved versions"
                switch reason {
                case .checkpointRequired:
                    explanation = "This document's Undo section is full. Open Review Versions to start a new section. Earlier copies are kept; your visible edits are not saved yet."
                case .storeCapacity:
                    explanation = "Space for saved versions is unavailable. Your text is still here. Free space and try again; no Save was assumed."
                case .sourceChanged:
                    explanation = "The file changed. Explicitly Reload it before reviewing a new starting point, or use Save As to keep this text in a new file."
                case .pendingMaintenance, .unfinishedPreparation, .unknownNativePrefix:
                    explanation = "A previous versions action needs review. Keep this window open and use Review Versions, then Refresh. Your visible edits are not saved."
                case .legacyHistoryRequiresReview:
                    explanation = "The older saved history cannot be verified for this location. Your edits are still here. Use Save As to keep them in a new file; the original and earlier versions stay unchanged."
                default:
                    explanation = "Saved versions could not be checked. Keep your text here and review the recorded changes before trying again."
                }
                observedFileEvent?(.historyReviewRequired(reason), snapshot.id, nil, nil)
                announcement = reason == .sourceChanged ? .conflict : .historyNeedsReview
            case .refused(let status, let record):
                try state.finishSave(snapshot, result: status == .cancelled ? .cancelledBeforeMutation : .failed)
                latestRecordID = record ?? latestRecordID; closeAfterSave = false
                resolveClose(false)
                message = status == .cancelled ? "Save stopped" : "Not saved"
                explanation = "Your visible text is still here. The file may have changed, access may be unavailable, or its saved versions may need review. You can Reload or Save As a new file."
                observedFileEvent?(.saveFailed, snapshot.id, record, status)
                announcement = status == .cancelled ? .stopped : status == .failed(.sourceChanged) ? .conflict : .notSaved
            case .uncertain(let record, let intendedURL, let isFreshCopy):
                try state.finishSave(snapshot, result: .uncertain)
                uncertainRecordID = record; latestRecordID = record ?? latestRecordID; closeAfterSave = false
                unresolvedPublication = .init(generation: snapshot.id, recordID: record, intendedURL: intendedURL,
                    kind: isFreshCopy ? .freshCopyUnconfirmed : .originalSave, publicationStatus: .failed(.recoveryUncertain))
                resolveClose(false)
                message = "Save needs review"
                explanation = "The file may have changed, but the complete Save could not be confirmed. Keep this text and review the retained versions before trying another Save."
                observedFileEvent?(.saveUncertain, snapshot.id, record, .failed(.recoveryUncertain))
            case .publishedNeedsReload(let record, let intendedURL):
                try state.finishSave(snapshot, result: .uncertain)
                uncertainRecordID = record; latestRecordID = record ?? latestRecordID; closeAfterSave = false
                unresolvedPublication = .init(generation: snapshot.id, recordID: record, intendedURL: intendedURL,
                    kind: .freshCopyPublishedNeedsRead, publicationStatus: .succeeded)
                resolveClose(false)
                message = "New copy needs review"
                explanation = "A new copy was created at “\(intendedURL.lastPathComponent)”, but it changed before the editor could follow it. This window still shows the original document. Review the reported copy; Reload here reads the original."
                observedFileEvent?(.saveUncertain, snapshot.id, record, .failed(.sourceChanged))
            }
        } catch {
            try? state.finishSave(snapshot, result: .uncertain)
            message = "Save needs review"; explanation = "The Save result could not be matched to this edit. Keep this window open and review the retained versions."
            closeAfterSave = false
            resolveClose(false)
            observedFileEvent?(.saveUncertain, snapshot.id, latestRecordID, .failed(.recoveryUncertain))
        }
        return announcement
    }

    func reload() {
        guard let state, fileTask == nil, !hasPendingSave, !choosing, !closing, !closed, let native = window.window else { return }
        choosing = true; window.surface.textView.isEditable = false; refresh()
        fileTask = Task { [weak self] in
            guard let self else { return }
            let approved = await self.interactions.confirmReload(native, state.isDirty || state.unresolvedSave != nil)
            self.choosing = false
            if approved, !Task.isCancelled {
                self.observedFileEvent?(.reloadStarted, nil, self.latestRecordID, nil)
                var inspection: UUID?
                defer { if let inspection { self.interactions.finishInspection(inspection) } }
                do {
                    inspection = try self.interactions.acquireInspection()
                    let opened = try await self.files.reload()
                    self.install(opened)
                    self.message = "Reloaded"
                    self.observedFileEvent?(.reloaded, nil, self.latestRecordID, .succeeded)
                    self.explanation = self.unresolvedPublication == nil
                        ? "The next Save will use this file as its new starting point. Earlier versions stay available."
                        : "This is a new read of the original document. It does not confirm the earlier Save or its reported copy; that outcome still needs review."
                } catch {
                    self.message = "Reload failed · your current text is still here"
                    self.observedFileEvent?(.reloadFailed, nil, self.latestRecordID, .failed(.unavailable))
                }
            }
            self.fileTask = nil; self.window.surface.textView.isEditable = true; self.refresh()
        }
    }
    func stop() {
        let stoppingTextCopy = pendingTextCopy != nil
        if let capture = state?.activeCapture {
            try? state?.requestStop(for: capture); preparation.stopSave(capture.id)
        }
        if let snapshot = state?.activeSave { try? state?.requestStop(for: snapshot) }
        if let copy = pendingTextCopy { preparation.stopSave(copy.id) }
        if choosing { presentationTask?.cancel() }
        fileTask?.cancel()
        if stoppingTextCopy { textCopyNotice = pendingTextCopy == nil ? "Text copy stopped. Your visible text is still here." : "Stopping text copy…" }
        else { message = "Stopping…" }
        refresh()
    }
    func reviewVersions() {
        guard !hasPendingFileWork, !hasPendingSave, !closing, !closed else { return }
        choosing = true; window.surface.textView.isEditable = false; refresh()
        observedFileEvent?(.reviewingVersions, nil, uncertainRecordID ?? latestRecordID, nil)
        presentationTask = Task { [weak self] in
            guard let self else { return }
            let previousSection = self.files.lastConfirmedSectionID
            await self.interactions.reviewVersions(self, self.uncertainRecordID ?? self.latestRecordID)
            if self.files.lastConfirmedSectionID != previousSection {
                self.historyReviewReason = nil
                self.message = self.state?.isDirty == true ? "New Undo section ready · edits are not saved" : "New Undo section ready"
                self.explanation = "Earlier version copies are kept. Starting a section does not save your visible text. Use Save when you are ready."
            }
            self.choosing = false; self.presentationTask = nil
            if self.files.mustReloadBeforeOriginalSave {
                self.message = "The saved file changed · Reload to continue saving"
                self.explanation = "Your visible text is still here. Reload reads the file again, or use Save As to keep this text in a new file."
            }
            self.window.surface.textView.isEditable = true; self.refresh()
        }
    }

    func requestClose() {
        guard !closed, closeTask == nil, !closeAfterSave else { return }
        if hasPendingFileWork || hasPendingSave {
            message = "Finish or Stop the current work before closing"; refresh(); return
        }
        guard let native = window.window else { return }
        guard !window.surface.textView.hasMarkedText() else {
            message = "Finish entering this text before closing"; resolveClose(false); refresh(); return
        }
        closing = true; window.surface.textView.isEditable = false; refresh()
        closeTask = Task { [weak self] in
            guard let self else { return }
            let disposition: TextDocumentState.CloseDisposition
            if self.unresolvedPublication != nil { disposition = .needsRecoveryDecision }
            else if self.files.mustReloadBeforeOriginalSave { disposition = .needsSaveDecision }
            else { disposition = self.state?.closeDisposition ?? .ready }
            let choice: EditorCloseChoice = disposition == .ready ? .discard
                : await self.interactions.chooseClose(native, disposition)
            switch choice {
            case .cancel:
                self.closeTask = nil; self.closing = false
                self.resolveClose(false)
                self.window.surface.textView.isEditable = true; self.refresh()
            case .review:
                self.closeTask = nil; self.closing = false
                self.resolveClose(false)
                self.window.surface.textView.isEditable = true; self.reviewVersions()
            case .save:
                self.closeTask = nil; self.closing = false; self.closeAfterSave = true
                self.window.surface.textView.isEditable = true
                if self.files.mustReloadBeforeOriginalSave { self.chooseSaveAs() }
                else { self.save() }
            case .textCopy:
                self.closeTask = nil; self.closing = false
                self.resolveClose(false)
                self.window.surface.textView.isEditable = true; self.chooseTextCopy()
            case .discard:
                self.window.surface.textView.isEditable = false
                await self.window.closeComparisonAndDrain()
                await self.preparation.closeAndDrain()
                self.window.retainPresentationDuringClose = true
                self.nativeDidClose = false
                guard await self.window.prepareAcceptedClose(), self.window.window === native,
                      self.fileTask == nil, !self.files.isWorking, !Task.isCancelled else {
                    self.window.cancelAcceptedClosePreparation()
                    self.preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
                    self.closeTask = nil; self.closing = false; self.resolveClose(false)
                    self.window.retainPresentationDuringClose = false
                    if self.nativeDidClose { self.window.reopenAfterFailedClose() }
                    self.window.surface.textView.isEditable = true; self.refresh(); return
                }
                // Keep the canonical text and access alive through the visual
                // exit. Nothing may suspend between this check and native close.
                self.window.finishClose()
                do {
                    guard self.nativeDidClose else { throw TextDocumentFailure.invalidReceipt }
                    try self.state?.discardAndClose()
                    try self.files.closeAfterDrain()
                    self.closed = true; self.state = nil; self.pendingEdit = nil; self.destination = nil
                    self.pendingTextCopy = nil; self.textCopyDestination = nil; self.textCopyNotice = nil
                    self.unconfirmedTextCopies = []; self.textCopyRecordID = nil
                    self.observedFileEvent?(.closed, nil, self.latestRecordID, nil)
                    self.window.surface.onEdit = nil; self.window.surface.onRejectedEdit = nil
                    self.window.surface.clearPrivatePresentation(); self.window.retainPresentationDuringClose = false
                    self.didClose?(self.id)
                    self.resolveClose(true)
                } catch {
                    self.preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }
                    self.closing = false; self.window.reopenAfterFailedClose(); self.resolveClose(false)
                    self.message = "The editor is still finishing. Keep this window open."; self.refresh()
                }
                self.closeTask = nil
            }
        }
    }

    /// The app can review dirty documents before Quit without polling, nested
    /// application termination loops, or treating a window dismissal as drain.
    func closeForTermination() async -> Bool {
        if closed { return true }
        guard closeTask != nil || closeAfterSave || (!hasPendingFileWork && !hasPendingSave && window.window != nil) else {
            window.showWindow(nil); message = "Finish or Stop the current work before quitting"; refresh(); return false
        }
        return await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            if closeTask == nil && !closeAfterSave { requestClose() }
        }
    }
    private func resolveClose(_ value: Bool) {
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func refresh() {
        if !closed, !closing, window.surface.needsLineChangePreparation(for: state?.savedTextBaseline) {
            submitPresentation(ticket: pendingEdit)
        }
        let working = hasPendingFileWork || hasPendingSave || closing
        let detail = [explanation, textCopyNotice].compactMap { $0 }.joined(separator: "\n")
        window.update(displayName: currentURL.lastPathComponent, dirty: state?.isDirty ?? false,
            status: message, documentFormat: state?.value.format ?? .init(bom: false, lineEnding: .lf),
            canSave: state != nil && !working && state?.unresolvedSave == nil && unresolvedPublication == nil && !files.mustReloadBeforeOriginalSave && historyReviewReason != .checkpointRequired && !closed,
            working: working, canReload: state != nil && !working && !closed,
            needsRecovery: latestRecordID != nil || state?.unresolvedSave != nil || unresolvedPublication != nil || historyReviewReason != nil || files.sectionNeedsReview,
            explanation: detail.isEmpty ? nil : detail,
            canReviewVersions: state != nil && !closed,
            canSaveTextCopy: state != nil && needsTextRecovery && !working && !closed && unconfirmedTextCopies.count < 8,
            hasTextCopyRecovery: needsTextRecovery, canViewTextCopyResults: !textCopyResults.isEmpty && !working && !closed,
            textCopyResults: textCopyResults, location: .local(currentURL))
        // The window's generic Save As enablement also needs a successfully read
        // document. Opening failures must never offer a new empty document.
        window.saveAsButton.isEnabled = state != nil && !working && state?.unresolvedSave == nil && unresolvedPublication == nil && !closed
    }
    private static func syntax(for url: URL) -> TextSyntaxLanguage {
        TextSyntaxLanguage.inferred(extension: url.pathExtension)
    }
    static func failureMessage(_ failure: TextDocumentFailure) -> String {
        switch failure {
        case .tooLarge: "This editor supports text up to 1 MiB. The edit was not saved."
        case .tooManyLines: "This editor supports up to 20,000 lines. The edit was not saved."
        case .lineTooLong: "A line is too long for this editor. The edit was not saved."
        case .embeddedNUL, .invalidUTF8: "This text is not supported. The edit was not saved."
        case .mixedLineEndings, .unsupportedLineEnding: "These line endings are not supported. The edit was not saved."
        default: "The text could not be prepared. Your visible text is still here."
        }
    }
}
