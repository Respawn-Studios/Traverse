import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// Closed event vocabulary for the app's existing diagnostics recorder.
/// The captured generation correlates events without recording remote paths or text.
enum RemoteTextSaveBoundary {
    case captured, awaitingPermit, permitAcquired, remoteSaveCalled, remoteResultReceived
    case saved, refused(RemoteEditableTextBackend.Refusal), resultNeedsReview
    case captureFailed, captureCancelled, unchanged, failedBeforeRemoteResult, resultApplyFailed

    #if DEBUG
    var qualificationIsTerminal: Bool {
        switch self {
        case .saved, .refused, .resultNeedsReview, .captureFailed, .captureCancelled,
             .unchanged, .failedBeforeRemoteResult, .resultApplyFailed: true
        default: false
        }
    }
    var qualificationLabel: String {
        switch self {
        case .captured: "captured"
        case .awaitingPermit: "awaitingPermit"
        case .permitAcquired: "permitAcquired"
        case .remoteSaveCalled: "remoteSaveCalled"
        case .remoteResultReceived: "remoteResultReceived"
        case .saved: "saved"
        case .refused(let reason): "refused.\(reason.diagnosticLabel)"
        case .resultNeedsReview: "resultNeedsReview"
        case .captureFailed: "captureFailed"
        case .captureCancelled: "captureCancelled"
        case .unchanged: "unchanged"
        case .failedBeforeRemoteResult: "failedBeforeRemoteResult"
        case .resultApplyFailed: "resultApplyFailed"
        }
    }
    #endif
}

/// The captured concrete backend, not the current browser row, owns remote
/// authority. The shared native buffer and generation tickets are never authority.
@MainActor final class RemoteTextDocumentController {
    let id = UUID(), connectionID: UUID
    let window: NativeTextEditorWindow
    let remote: RemoteEditableTextBackend
    let displayName: String
    let locationContext: EditorLocationContext?
    let interactions: RemoteEditorInteractions
    var state: TextDocumentState
    var language = TextSyntaxLanguage.plain
    var preferences = EditorPreferences()
    var languageOverride = false, wrappingOverride = false
    var pendingEdit: TextEditTicket?
    var capturePresentationGeneration: (capture: UUID, generation: UUID)?
    var work: Task<Void, Never>?, stopWork: Task<Void, Never>?, closingWork: Task<Bool, Never>?
    var copying: (capture: TextCopyCapture, destination: EditorSaveDestination)?
    var choosing = false, closed = false, disconnected = false, needsReview = false
    var nativeDidClose = false
    // Once the native close handoff starts, a body pin may have ended even if
    // local retirement later fails. A reopened window is local text recovery.
    var remoteBodyHandoffAttempted = false
    var closeAfterSave = false
    var closeWaiter: CheckedContinuation<Bool, Never>?
    var closingRequest: UUID?
    // Retain an actual backend capture if its UI receipt could not be applied.
    var unappliedSave: TextSaveSnapshot?
    #if DEBUG
    var verificationRejectSaveApplication = false
    private(set) var verificationSaveBoundary = "none"
    private(set) var verificationSaveTerminal = false
    private(set) var verificationSaveTerminalCount = 0
    #endif
    var observedSaveBoundary: ((UUID, RemoteTextSaveBoundary) -> Void)?
    var message: String
    var saveExplanation: String?
    var saveRefusal: RemoteEditableTextBackend.Refusal?
    var refusedSaveGeneration: UUID?
    var manageSavedVersions: (() -> Void)?
    var copyNotice: String?, copyRecords: [UUID] = [], protectedCopies: [URL] = []
    var didClose: ((UUID) -> Void)?
    lazy var preparation = EditorPreparationOwner { [weak self] input, result in self?.prepared(input, result) }

    func noteSaveBoundary(_ boundary: RemoteTextSaveBoundary, generation: UUID) {
        #if DEBUG
        verificationSaveBoundary = boundary.qualificationLabel
        verificationSaveTerminal = boundary.qualificationIsTerminal
        if verificationSaveTerminal { verificationSaveTerminalCount += 1 }
        #endif
        observedSaveBoundary?(generation, boundary)
    }

    convenience init(remote: SFTPInPlaceDocumentSession, contents: TextDocumentValue, connectionID: UUID,
         displayName: String, locationContext: EditorLocationContext? = nil,
         interactions: RemoteEditorInteractions, installChrome: (NSWindow) -> Void) {
        self.init(backend: .sftp(remote), contents: contents, connectionID: connectionID, displayName: displayName,
            locationContext: locationContext, interactions: interactions, installChrome: installChrome)
    }
    init(backend: RemoteEditableTextBackend, contents: TextDocumentValue, connectionID: UUID,
         displayName: String, locationContext: EditorLocationContext? = nil,
         interactions: RemoteEditorInteractions, installChrome: (NSWindow) -> Void) {
        remote = backend; self.connectionID = connectionID; self.displayName = displayName
        message = "Ready · " + backend.protocolName
        self.locationContext = locationContext
        self.interactions = interactions; state = .init(value: contents, binding: TextDocumentBinding())
        window = .init(displayName: displayName + " · " + backend.protocolName, installChrome: installChrome)
        window.configureLocalCopyPresentation()
        window.saveButton.toolTip = "Update this captured server file after checking for changes made elsewhere."
        window.surface.install(contents)
        remote.nativeBufferDidInstall()
        window.onRefusedVersion = { [weak self] version in self?.reviewVersions(version: version) }
        window.onSave = { [weak self] in self?.save() }
        window.captureComparison = { [weak self] in
            guard let self, !closed, closingWork == nil, !isBusy,
                  let baseline = state.comparisonBaseline else { return nil }
            return .init(baseline: baseline, current: window.surface.textView.string,
                format: state.value.format, language: language)
        }
        // A remote Save As must not imply remote creation or switch targets.
        window.onSaveAs = { [weak self] in self?.saveTextCopy() }
        window.onTextCopy = { [weak self] in self?.saveTextCopy() }
        window.onTextCopyResults = { [weak self] record in
            guard let self, let selected = record ?? copyRecords.last else { return }
            interactions.showCopyResult(selected)
        }
        window.onStop = { [weak self] in self?.stop() }
        window.onRecovery = { [weak self] in self?.reviewVersions() }
        window.onLanguage = { [weak self] value in
            guard let self, closingWork == nil, !closed else { return }; languageOverride = true; language = value; present()
        }
        window.onWrapping = { [weak self] in self?.wrappingOverride = true }
        window.surface.onEdit = { [weak self] _, _ in self?.edited() }
        window.surface.onRejectedEdit = { [weak self] _ in self?.message = "Text exceeds the editor limit. Your current text is kept."; self?.refresh() }
        window.shouldClose = { [weak self] in self?.requestClose(); return false }
        window.didClose = { [weak self] in self?.nativeDidClose = true }
        present(); refresh()
    }
    var isBusy: Bool { work != nil || stopWork != nil || choosing || copying != nil || state.activeSave != nil || state.activeCapture != nil }
    func show(visible: Bool = true) {
        if visible { window.presentEditor(in: .connection(connectionID), arrangement: preferences.windowArrangement) }
    }
    func applyPreferences(_ value: EditorPreferences, pointSize: CGFloat) {
        preferences = value
        window.applyEditorPreferences(value, pointSize: pointSize, applyWrapping: !wrappingOverride)
        if !languageOverride { language = value.language(forFilename: displayName) }
        window.selectLanguage(language); present()
    }
    func edited() {
        guard !closed, closingWork == nil else { return }
        do {
            pendingEdit = try state.beginEdit()
            if !isBusy && state.unresolvedSave == nil { message = "Edited" }
            present()
        }
        catch { message = "The editor could not validate this change. Keep this window open." }
        refresh()
    }
    func present() {
        guard !closed else { return }
        do { try preparation.submit(.presentation(ticket: pendingEdit, surfaceGeneration: window.surface.generation,
            text: window.surface.textView.string, format: state.value.format, language: language,
            detectsLanguage: shouldDetectLanguage)) }
        catch { message = "This text could not be prepared. Your visible text is kept." }
    }
    private var shouldDetectLanguage: Bool {
        !languageOverride && language == .plain && preferences.canDetectLanguage(forFilename: displayName)
    }
    func prepared(_ input: EditorPreparationInput, _ result: EditorPreparationResult) {
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
                message = "This text could not be validated within the editor limits. Your visible text is kept."
            default: break
            }
        case .save(let capture, _):
            guard state.activeCapture?.id == capture.id else { return }
            if case .cancelled = result {
                try? state.finishCancelledCapture(capture)
                noteSaveBoundary(.captureCancelled, generation: capture.id)
                message = "Save preparation stopped. Your visible text is kept."
            }
            else {
                let validation: Result<TextDocumentValue, TextDocumentFailure>
                switch result { case .save(let value): validation = .success(value)
                case .invalid(let failure): validation = .failure(failure)
                default: validation = .failure(.invalidReceipt) }
                do {
                    let acknowledgesEdit = !state.stopRequested
                        && capturePresentationGeneration?.capture == capture.id
                        && capturePresentationGeneration?.generation == state.currentGeneration
                    let snapshot = try state.finishCapture(capture, prepared: validation)
                    // A newer native edit has a different generation and stays pending.
                    if acknowledgesEdit { pendingEdit = nil }
                    if let snapshot { startSave(snapshot) }
                    else if state.closeDisposition == .ready {
                        noteSaveBoundary(.unchanged, generation: capture.id)
                        message = "No changes to save · " + remote.protocolName
                    } else {
                        noteSaveBoundary(.captureFailed, generation: capture.id)
                        message = "Save could not be prepared. Your visible text is kept."
                    }
                }
                catch {
                    noteSaveBoundary(.captureFailed, generation: capture.id)
                    message = "Save could not be prepared. Your visible text is kept."
                }
            }
            capturePresentationGeneration = nil
            present()
            finishChosenSaveForCloseIfIdle()
        case .copy(let capture, _):
            guard copying?.capture.id == capture.id else { return }
            if case .copy(let value) = result, let destination = copying?.destination { startCopy(value, capture: capture, destination: destination) }
            else { copying = nil; copyNotice = "Text copy was not saved. Your visible text is kept." }
            present()
        }
        refresh()
    }
    func refresh() {
        let unavailable = isBusy || closingWork != nil
        let explanation = remoteBodyHandoffAttempted
            ? "This is local recovery text. Save a Text Copy to keep it. Remote Save and retained-version reads are unavailable from this window."
            : needsReview
            ? "Needs Review. Retained before/edited versions stay protected. Save a Text Copy preserves visible text locally; it does not confirm the remote Save."
            : disconnected ? "This connection is closed. Your text is kept here. Save a Text Copy to a chosen local folder; reconnect explicitly for further remote editing."
            : saveExplanation
        window.update(displayName: displayName + (remoteBodyHandoffAttempted ? " · Local Recovery" : " · " + remote.protocolName),
            dirty: state.isDirty, status: copyNotice ?? message,
            documentFormat: state.value.format, canSave: !remoteBodyHandoffAttempted && !unavailable && !disconnected && !needsReview
                && saveRefusal?.requiresReopen != true && !closed,
            working: unavailable, canReload: false, needsRecovery: needsReview, explanation: explanation,
            canReviewVersions: !remoteBodyHandoffAttempted, canSaveTextCopy: !unavailable && !closed && protectedCopies.count < 8,
            hasTextCopyRecovery: remoteBodyHandoffAttempted || needsReview || disconnected || unappliedSave != nil
                || saveRefusal?.requiresReopen == true,
            canViewTextCopyResults: !copyRecords.isEmpty && !unavailable,
            textCopyResults: copyRecords.map { .init(id: $0, title: "Local Text Copy") }, location: locationContext)
        // Menu validation uses these native button states too.
        window.stopButton.isEnabled = isBusy && closingWork == nil
        window.saveAsButton.isEnabled = !unavailable && !closed && protectedCopies.count < 8
        window.recoveryButton.title = saveRefusal?.needsVersionManagement == true && manageSavedVersions != nil
            ? "Manage Saved Versions…" : "Review Versions…"
        window.configureRefusedReview(available: refusedSaveGeneration != nil && saveRefusal?.offersCapturedVersionReview == true
            && !needsReview && !remoteBodyHandoffAttempted && !closed, enabled: !unavailable)
        window.surface.textView.isEditable = !closed && closingWork == nil
    }
    /// Forced tab teardown never discards the window or claims Saved.
    func connectionWillClose() {
        copyNotice = nil
        disconnected = true; message = "Connection closing · visible text is kept"
        finishChosenSaveForCloseIfIdle(); refresh()
    }
    func reviewVersions(version: RemoteRetainedTextChoice.Version? = nil) {
        guard !remoteBodyHandoffAttempted, !isBusy, closingWork == nil, !closed, let native = window.window else { return }
        if version == nil, saveRefusal?.needsVersionManagement == true, let manageSavedVersions {
            manageSavedVersions(); return
        }
        let requested: RemoteRetainedTextChoice.RefusedReview?
        if let version {
            guard let generation = refusedSaveGeneration, saveRefusal?.offersCapturedVersionReview == true, !needsReview else { return }
            requested = .init(generation: generation, version: version)
        } else { requested = nil }
        choosing = true; refresh()
        work = Task { [self] in
            await interactions.reviewVersions(remote, native, requested)
            work = nil; choosing = false; refresh()
        }
    }
}
