import AppKit
import Combine
import FileOperations
@_spi(Qualification) import LocalStorage

/// The ordinary editor uses the same guarded Save/recovery owner in both
/// configurations. Packaging/publication still follows release acceptance.
enum LocalTextEditorFeature {
    static var ordinaryEnabled: Bool { !GeneratedArchiveDriveReview.requested }
    static var allowsVersionRetirement: Bool { ordinaryEnabled }
}

@MainActor
final class ApplicationLocalTextEditors {
    static let shared = ApplicationLocalTextEditors()
    private struct Entry {
        let document: LocalTextDocumentController
        let context: Context
        let preferencesObservation: AnyCancellable
    }
    @MainActor private final class Context {
        weak var browser: BrowserViewController?
        let access: FolderAccessController
        let settings: BrowserSettings
        let engine: RecoverableFileOperations
        init(browser: BrowserViewController, engine: RecoverableFileOperations) {
            self.browser = browser; access = browser.folderAccess; settings = browser.settings; self.engine = engine
        }
    }
    private let coordinator = ApplicationOperationCoordinator.shared
    private var documents: [UUID: Entry] = [:]
    private var opening: [UUID: Task<Void, Never>] = [:]
    private var openingURLs = Set<URL>()
    private var historicalReviews: [UUID: Task<Void, Never>] = [:]
    private var reviewControllers: [UUID: NativeTextVersionsWindow] = [:]
    private var reviewDrainFailures: [UUID: LocalEditorFileSession] = [:]
    private var signals = Set<AnyCancellable>()
    private var reviewingTermination = false
    private var terminationPrepared = false
    private let archiveEditors = ApplicationArchiveTextEditors()
    private lazy var mutationAdmission = EditorMutationAdmission(begin: { [weak self] id in
        self?.coordinator.begin(owner: id) == true
    }, end: { [weak self] id in self?.coordinator.finish(owner: id) })

    var hasManagedDocuments: Bool { !documents.isEmpty || !opening.isEmpty || !historicalReviews.isEmpty || !reviewDrainFailures.isEmpty || archiveEditors.hasManagedDocuments }
    var hasFileWork: Bool { !opening.isEmpty || documents.values.contains { $0.document.hasPendingFileWork || $0.document.hasPendingSave } || archiveEditors.hasFileWork }
    var documentCount: Int { documents.count + archiveEditors.documentCount }
    var documentReservationCount: Int { documents.count + opening.count + archiveEditors.reservationCount }

    func openArchiveText(_ selection: ZIPTextPreviewSelection, source: URL, path: String,
                         reader: ZIPArchiveReader, retaining access: FileAccessLifetimes,
                         from browser: BrowserViewController) {
        openArchiveText(.zip(selection, reader), source: source, path: path, retaining: access, from: browser)
    }
    func openArchiveText(_ selection: TARTextPreviewSelection, source: URL, path: String,
                         reader: TARArchiveReader, retaining access: FileAccessLifetimes,
                         from browser: BrowserViewController) {
        openArchiveText(.tar(selection, reader), source: source, path: path, retaining: access, from: browser)
    }
    private func openArchiveText(_ request: ArchiveTextEditorRequest, source: URL, path: String,
                         retaining access: FileAccessLifetimes, from browser: BrowserViewController) {
        guard request.isAllowed(from: browser), !reviewingTermination, !terminationPrepared,
              let engine = browser.recoverableFileOperations else { return }
        if archiveEditors.showExisting(source: source, path: path) { return }
        guard documentReservationCount + ApplicationRemoteTextEditors.shared.allTextReservationCount < 4 else {
            browser.status.stringValue = "Close another editor. Up to four local and remote text documents can be open."; return
        }
        bindAdmissionSignalsIfNeeded()
        let context = Context(browser: browser, engine: engine)
        let names = browser.privateNames
        let interactions = ArchiveEditorInteractions(
            acquireMutation: { [self] in try await acquireMutation(engine) },
            finishMutation: { [self] in mutationAdmission.finish($0) },
            requireUnreferenced: { original in
                try await ArchiveOriginalReferences.requireUnreferenced([original], names: names, retaining: access)
            },
            confirmReload: { window, dirty in await Self.confirmReload(in: window, dirty: dirty) },
            chooseArchiveCopyName: ArchiveEditorInteractions.chooseArchiveCopyName,
            chooseTextCopy: { [self] window, name in
                if GeneratedArchiveDriveReview.requested { return nil }
                return await chooseDestination(in: window, source: nil, context: context, isTextCopy: true, suggestedName: name)
            },
            publishTextCopy: { [self] value, generation, destination, window in
                try await publishTextCopy(value, generation: generation, destination: destination, window: window, engine: engine)
            },
            showResult: { [self] id in _ = showResults(id, context: context) },
            chooseClose: { window, disposition in await Self.closeChoice(in: window, disposition: disposition, archive: true) },
            publish: { [weak browser, coordinator] result, original, destination in
                if let browser {
                    browser.lastOperationResult = result.result; browser.lastRecoveryRecordID = result.recordID; browser.lastRecoveryAction = nil
                    browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
                    browser.operationResultsButton.isHidden = false; browser.inspectOperationRecovery()
                }
                for current in coordinator.liveBrowsers where !current.isBrowserSuspended {
                    if current.location.directoryURL == destination.deletingLastPathComponent() { current.loadLocation() }
                }
                if let original { ArchiveOriginalReferences.refresh(original, in: coordinator) }
            })
        archiveEditors.open(request, source: source, path: path, engine: engine,
                            access: access, settings: browser.settings, interactions: interactions,
                            report: { [weak browser] message in browser?.status.stringValue = message })
    }

    #if DEBUG
    func archiveDocumentForVerification(source: URL, path: String) -> ArchiveTextDocumentController? {
        archiveEditors.documentForVerification(source: source, path: path)
    }
    #endif

    /// An empty text file uses the existing text producer, journal and receipt.
    /// There is no placeholder original-file token or direct UI filesystem write.
    func createTextFile(from browser: BrowserViewController) {
        guard LocalTextEditorFeature.ordinaryEnabled, !reviewingTermination, !terminationPrepared,
              browser.canModifyCurrentFolder, let parent = browser.location.directoryURL,
              let engine = browser.recoverableFileOperations,
              documentReservationCount + ApplicationRemoteTextEditors.shared.allTextReservationCount < 4 else { return }
        bindAdmissionSignalsIfNeeded()
        let id = UUID(), tab = browser.activeID, visit = browser.sessionID
        let trace = ApplicationDiagnostics.shared.currentTrace ?? id
        let context = Context(browser: browser, engine: engine)
        opening[id] = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            var permit: UUID?
            defer {
                if let permit { self.mutationAdmission.finish(permit) }
                self.opening.removeValue(forKey: id)
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !browser.isBrowserSuspended && !self.reviewingTermination
                    && !self.terminationPrepared && browser.activeID == tab && browser.sessionID == visit
                    && browser.location.directoryURL == parent && browser.recoverableFileOperations === engine
                    && browser.isActiveCommandPane
            }
            guard let name = await browser.promptForName(title: FilenamePrompt.newFileTitle,
                initial: FilenamePrompt.newFileDefaultName,
                message: FilenamePrompt.newFileInstructions), isCurrent() else {
                ApplicationDiagnostics.shared.event(.fileOperation, .cancelled, trace: trace,
                    command: .newTextFile, context: .init(.newTextFile)); return
            }
            let access = await browser.accessLifetime(for: [parent])
            defer { withExtendedLifetime(access) {} }
            do {
                ApplicationDiagnostics.shared.event(.fileOperation, .waiting, trace: trace,
                    command: .newTextFile, context: .init(.newTextFile))
                permit = try await self.acquireMutation(engine)
                guard isCurrent(), let native = browser.view.window, native.attachedSheet == nil else { throw CancellationError() }
                let contents = try TextDocumentValue.original(Data())
                let destination = EditorSaveDestination(directory: parent, name: name, access: access)
                ApplicationDiagnostics.shared.event(.fileOperation, .preparing, trace: trace,
                    command: .newTextFile, context: .init(.newTextFile))
                let reply = try await self.publishTextCopy(contents, generation: id,
                    destination: destination, window: native, engine: engine, newFile: true)
                // The actual worker returned before writer/access ownership ends.
                if let owner = permit { self.mutationAdmission.finish(owner); permit = nil }
                browser.inspectOperationRecovery()
                switch reply {
                case .saved(let receipt):
                    guard receipt.generation == id, receipt.document.contents == contents else {
                        ApplicationDiagnostics.shared.event(.fileOperation, .interrupted, trace: trace,
                            command: .newTextFile, error: DiagnosticErrors.operation(.recoveryUncertain),
                            context: .init(.newTextFile), relatedTrace: receipt.recordID)
                        if !browser.isBrowserSuspended { browser.status.stringValue = "The new file needs review. Open Operation Recovery before trying that name again." }
                        return
                    }
                    ApplicationDiagnostics.shared.event(.fileOperation, .completed, trace: trace,
                        command: .newTextFile, context: .init(.newTextFile), relatedTrace: receipt.recordID)
                    guard isCurrent() else { return }
                    browser.status.stringValue = "File created."
                    browser.loadLocation()
                    self.opening.removeValue(forKey: id)
                    self.open(parent.appendingPathComponent(name), from: browser)
                case .refused(let publication):
                    let error: DiagnosticErrorCode? = if case .failed(let reason) = publication.status { DiagnosticErrors.operation(reason) } else { nil }
                    ApplicationDiagnostics.shared.event(.fileOperation, publication.status == .cancelled ? .cancelled : .failed,
                        trace: trace, command: .newTextFile, error: error,
                        context: .init(.newTextFile), relatedTrace: publication.recordID)
                    guard !browser.isBrowserSuspended else { return }
                    if let record = publication.recordID { _ = self.showResults(record, context: context) }
                    else if case .failed(let failure) = publication.status { browser.showOperationError(failure) }
                case .publishedNeedsReload(let publication), .uncertain(let publication):
                    ApplicationDiagnostics.shared.event(.fileOperation, .interrupted, trace: trace,
                        command: .newTextFile, error: DiagnosticErrors.operation(.recoveryUncertain),
                        context: .init(.newTextFile), relatedTrace: publication.recordID)
                    if let record = publication.recordID { _ = self.showResults(record, context: context) }
                    if !browser.isBrowserSuspended { browser.status.stringValue = "The new file needs review. Its recorded result is kept; nothing will be retried automatically." }
                }
            } catch is CancellationError {
                ApplicationDiagnostics.shared.event(.fileOperation, .cancelled, trace: trace,
                    command: .newTextFile, context: .init(.newTextFile))
            } catch {
                ApplicationDiagnostics.shared.event(.fileOperation, .failed, trace: trace,
                    command: .newTextFile, error: DiagnosticErrors.operation(error as? FileOperationFailure ?? .ioFailure),
                    context: .init(.newTextFile))
                if !browser.isBrowserSuspended { browser.showOperationError(error) }
            }
        }
    }
    #if DEBUG
    func documentForVerification(at url: URL) -> LocalTextDocumentController? {
        documents.values.first { $0.document.currentURL.standardizedFileURL == url.standardizedFileURL }?.document
    }
    var waitingMutationsForVerification: Int { mutationAdmission.waitingCount }
    var reviewingTerminationForVerification: Bool { reviewingTermination }
    var pendingHistoricalReviewsForVerification: Int { historicalReviews.count }
    var afterHistoricalAccessForVerification: (() async -> Void)?
    #endif

    /// Admit the complete explicit selection before reserving any new document.
    /// Each file still opens through its existing concrete access/Save owner.
    func openSelection(_ urls: [URL], from browser: BrowserViewController) {
        guard !urls.isEmpty, urls.count <= 4, urls.allSatisfy(\.isFileURL) else { return }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        let existing = Set(documents.values.map { $0.document.currentURL.standardizedFileURL })
        let required = unique.filter { !existing.contains($0.standardizedFileURL) && !openingURLs.contains($0.standardizedFileURL) }.count
        guard documentReservationCount + ApplicationRemoteTextEditors.shared.allTextReservationCount + required <= 4 else {
            browser.status.stringValue = "Close another editor before opening this selection. Up to four text documents can be open at once."
            return
        }
        for url in unique { open(url, from: browser) }
    }

    func open(_ url: URL, from browser: BrowserViewController) {
        guard LocalTextEditorFeature.ordinaryEnabled, !reviewingTermination, !terminationPrepared, url.isFileURL,
              !browser.isBrowserSuspended, let engine = browser.recoverableFileOperations else { return }
        let canonical = url.standardizedFileURL
        if let existing = documents.values.first(where: { $0.document.currentURL.standardizedFileURL == canonical }) {
            existing.document.window.showWindow(nil); existing.document.window.window?.makeKeyAndOrderFront(nil); return
        }
        guard !openingURLs.contains(canonical) else { return }
        guard documentReservationCount + ApplicationRemoteTextEditors.shared.allTextReservationCount < 4 else {
            browser.status.stringValue = "Close another editor to open this file. Up to four text documents can be open at once."
            return
        }
        bindAdmissionSignalsIfNeeded()
        let ticket = UUID(), context = Context(browser: browser, engine: engine)
        openingURLs.insert(canonical)
        opening[ticket] = Task { [weak self, weak browser] in
            guard let self else { return }
            defer { self.opening.removeValue(forKey: ticket); self.openingURLs.remove(canonical) }
            guard let browser else { return }
            let access = await browser.accessLifetime(for: [url])
            guard !Task.isCancelled, !self.reviewingTermination else { return }
            let files = LocalEditorFileSession(engine: engine, retaining: access)
            let document = LocalTextDocumentController(url: url, files: files,
                interactions: self.interactions(context), installChrome: { native in
                    native.isRestorable = false
                    ToolWindowChrome.install(in: native, settings: context.settings)
                })
            document.window.bindKeyboardBehavior(to: context.settings)
            document.window.surface.find.motion = { [weak settings = context.settings] in settings?.motion ?? .init() }
            let preferencesObservation = context.settings.$editorPreferences.removeDuplicates().sink { [weak document] value in
                guard let document else { return }
                document.applyEditorPreferences(value, pointSize: CGFloat(value.basePointSize) * InterfaceMetrics.scale)
                InterfaceMetrics.setFont(document.window.surface.textView,
                    base: .monospacedSystemFont(ofSize: CGFloat(value.basePointSize), weight: .regular))
            }
            self.documents[document.id] = .init(document: document, context: context,
                preferencesObservation: preferencesObservation)
            self.installDiagnostics(on: document)
            document.didClose = { [weak self] id in self?.documents.removeValue(forKey: id) }
            document.didChangeURL = { [weak self] _, _ in
                for browser in self?.coordinator.liveBrowsers ?? [] where !browser.isBrowserSuspended {
                    browser.inspectOperationRecovery()
                }
            }
            if let native = document.window.window {
                self.position(native, relativeTo: browser.view.window)
                InterfaceMetrics.setFont(document.window.surface.textView,
                    base: .monospacedSystemFont(ofSize: CGFloat(context.settings.editorPreferences.basePointSize), weight: .regular))
                InterfacePresentation.shared.register(document.window.surface)
            }
            document.showAndOpen()
        }
    }

    /// Generic operation history may outlive or lose the original file. Open
    /// one exact text record without requiring a body read or fabricating a
    /// current-document token. Its session/access remains owned until Done.
    func review(_ record: OperationRecoveryRecord, from browser: BrowserViewController, in host: NSWindow?) {
        guard LocalTextEditorFeature.ordinaryEnabled, record.kind == .textRevision,
              !reviewingTermination, !terminationPrepared, !browser.isBrowserSuspended,
              let engine = browser.recoverableFileOperations, let host, host.isVisible, host.attachedSheet == nil,
              historicalReviews.count < 4 else { return }
        bindAdmissionSignalsIfNeeded()
        let id = UUID(), context = Context(browser: browser, engine: engine)
        historicalReviews[id] = Task { [weak self, weak host] in
            guard let self else { return }
            defer { self.reviewControllers.removeValue(forKey: id); self.historicalReviews.removeValue(forKey: id) }
            guard let capturedHost = host else { return }
            let hostClosure = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: capturedHost) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // A presented sheet owns its normal Done/Stop lifetime.
                    // Cancel only the still-pending access acquisition.
                    if self?.reviewControllers[id] == nil { self?.historicalReviews[id]?.cancel() }
                }
            }
            defer { withExtendedLifetime(hostClosure) {} }
            let access = await browser.accessLifetime(for: record.locations)
            #if DEBUG
            if let barrier = self.afterHistoricalAccessForVerification { await barrier() }
            #endif
            guard !Task.isCancelled, !self.reviewingTermination, !self.terminationPrepared,
                  !browser.isBrowserSuspended, browser.recoverableFileOperations === engine,
                  let host, host.isVisible, host.attachedSheet == nil,
                  host !== browser.recoveryWindow?.window || browser.recoveryWindow?.isClosed == false else { return }
            let files = LocalEditorFileSession(engine: engine, retaining: access, selectedHistoricalRecordID: record.id)
            let review = NativeTextVersionsWindow(files: files, interactions: self.versionInteractions(context),
                installChrome: { native in
                    native.isRestorable = false; ToolWindowChrome.install(in: native, settings: context.settings)
                })
            self.reviewControllers[id] = review
            await review.present(from: host, focus: record.id)
            do { try files.closeAfterDrain() }
            catch {
                self.reviewDrainFailures[id] = files
                browser.status.stringValue = "Saved versions are still finishing. Their access remains retained."
            }
        }
    }

    private func installDiagnostics(on document: LocalTextDocumentController) {
        let documentID = document.id
        document.observedFileEvent = { event, generation, record, result in
            let action: DiagnosticAction, phase: DiagnosticPhase
            switch event {
            case .opening: action = .open; phase = .reading
            case .opened: action = .open; phase = .completed
            case .openFailed: action = .open; phase = .failed
            case .saveCaptured: action = .fileOperation; phase = .preparing
            case .saveWaiting: action = .fileOperation; phase = .waiting
            case .saveStarted: action = .fileOperation; phase = .committing
            case .saved: action = .fileOperation; phase = .completed
            case .saveFailed: action = .fileOperation; phase = result == .cancelled ? .cancelled : .failed
            case .saveUncertain: action = .fileOperation; phase = .interrupted
            case .historyReviewRequired: action = .recovery; phase = .blocked
            case .reloadStarted: action = .open; phase = .reading
            case .reloaded: action = .open; phase = .completed
            case .reloadFailed: action = .open; phase = .failed
            case .reviewingVersions: action = .recovery; phase = .presenting
            case .closed: action = .control; phase = .finished
            case .textCopyCaptured: action = .fileOperation; phase = .preparing
            case .textCopyWaiting: action = .fileOperation; phase = .waiting
            case .textCopyStarted: action = .fileOperation; phase = .committing
            case .textCopySaved: action = .fileOperation; phase = .completed
            case .textCopyFailed: action = .fileOperation; phase = result == .cancelled ? .cancelled : .failed
            case .textCopyUncertain: action = .fileOperation; phase = .interrupted
            }
            let context: DiagnosticContext?
            switch event {
            case .textCopyCaptured, .textCopyWaiting, .textCopyStarted, .textCopySaved, .textCopyFailed, .textCopyUncertain:
                context = .init(.editorTextCopy)
            default: context = nil
            }
            let error: DiagnosticErrorCode?
            if case .historyReviewRequired(let reason) = event { error = DiagnosticErrors.localEditorCapacity(reason) }
            else if let result, case .failed(let failure) = result { error = DiagnosticErrors.operation(failure) }
            else { error = nil }
            ApplicationDiagnostics.shared.event(action, phase, trace: generation ?? documentID,
                error: error, context: context, relatedTrace: record)
        }
    }

    private func bindAdmissionSignalsIfNeeded() {
        guard signals.isEmpty else { return }
        // Existing transfers retain their priority. When their actual owner or
        // a volume barrier changes, try the queued editor intent again. No loop
        // polls the disk/coordinator and no second writer is introduced.
        Publishers.Merge3(coordinator.objectWillChange, coordinator.transfers.objectWillChange,
            coordinator.drives.objectWillChange).receive(on: RunLoop.main).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.mutationAdmission.workDidChange() }
            }.store(in: &signals)
    }
    private func acquireMutation(_ engine: RecoverableFileOperations) async throws -> UUID {
        let permit = try await mutationAdmission.acquire()
        do { try Task.checkCancellation(); try await coordinator.prepareOperationState(for: engine); return permit }
        catch { mutationAdmission.finish(permit); throw error }
    }
    private func acquireInspection() throws -> UUID {
        guard let id = coordinator.beginInspection() else { throw FileOperationFailure.unavailable }
        return id
    }
    /// Remote Save and local fallback share the exact existing global writer
    /// queue. No second coordinator or parallel mutation lane is introduced.
    func remoteInteractions(from browser: BrowserViewController) -> RemoteEditorInteractions? {
        guard let engine = browser.recoverableFileOperations else { return nil }
        bindAdmissionSignalsIfNeeded()
        let context = Context(browser: browser, engine: engine)
        return .init(acquireSave: { [self] in
            let permit = try await mutationAdmission.acquire()
            do { try Task.checkCancellation(); return permit }
            catch { mutationAdmission.finish(permit); throw error }
        }, acquireCopy: { [self] in try await acquireMutation(engine) },
        finishMutation: { [self] in mutationAdmission.finish($0) },
        chooseCopy: { [self] window, name in
            await chooseDestination(in: window, source: nil, context: context, isTextCopy: true, suggestedName: name)
        }, publishCopy: { [self] value, generation, destination, window in
            try await publishTextCopy(value, generation: generation, destination: destination, window: window, engine: engine)
        }, showCopyResult: { [self] id in _ = showResults(id, context: context) },
        chooseClose: { window, recovery in
            guard window.attachedSheet == nil else { return .cancel }
            let alert = NSAlert()
            alert.messageText = recovery ? "Keep this text before closing?" : "Save remote changes before closing?"
            alert.informativeText = recovery
                ? "The remote connection or Save needs review. A local text copy preserves the visible text without confirming that Save. Closing discards only the visible buffer. Review any retained versions separately."
                : "Save updates the original captured remote file. Don't Save discards this window's visible changes."
            alert.addButton(withTitle: recovery ? "Save a Text Copy…" : "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = alert.buttons.last
            if recovery { alert.buttons[0].keyEquivalent = ""; alert.buttons[2].keyEquivalent = "\r" }
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            if response == .alertFirstButtonReturn { return recovery ? .textCopy : .save }
            if response == .alertSecondButtonReturn { return .discard }
            return .cancel
        }, reviewVersions: { remote, window, request in
            await RemoteTextRecoveryController.review(document: remote, from: window, settings: context.settings,
                refusedReview: request,
                acquire: { [self] in try await acquireMutation(engine) },
                finish: { [self] in mutationAdmission.finish($0) },
                choose: { [self] native in await chooseDestination(in: native, source: nil,
                    context: context, isTextCopy: true, suggestedName: "Remote saved text.txt") },
                publish: { [self] value, generation, destination, native in
                    try await publishTextCopy(value, generation: generation, destination: destination, window: native, engine: engine)
                }, showResult: { [self] id in _ = showResults(id, context: context) })
        })
    }
    /// Global retained review uses the SAME local engine, destination grants and
    /// mutation writer. It requires no remote browser/session/editor selection.
    func savedVersionsContext(from browser: BrowserViewController) -> RemoteSavedVersionsContext? {
        guard let engine = browser.recoverableFileOperations else { return nil }
        bindAdmissionSignalsIfNeeded()
        let context = Context(browser: browser, engine: engine)
        return .init(settings: context.settings,
            acquire: { [self] in try await acquireMutation(engine) },
            finish: { [self] in mutationAdmission.finish($0) },
            choose: { [self] native in await chooseDestination(in: native, source: nil,
                context: context, isTextCopy: true, suggestedName: "Retained text.txt") },
            publish: { [self] value, generation, destination, native in
                try await publishTextCopy(value, generation: generation,
                    destination: destination, window: native, engine: engine)
            }, showResult: { [self] id in _ = showResults(id, context: context) })
    }
    private func publishTextCopy(_ value: TextDocumentValue, generation: UUID,
        destination: EditorSaveDestination, window: NSWindow, engine: RecoverableFileOperations,
        newFile: Bool = false) async throws -> LocalTextSaveAsResult {
            // Match the accepted local editor's explicit history compatibility
            // behavior; an old history is never silently upgraded.
            switch try await engine.inspectExistingHistory().readiness {
            case .available(catalogVersion: 10): break
            case .absent:
                let result = await engine.upgradeLocalTextHistory()
                guard result.status == .succeeded, result.catalogVersion == 10 else { throw FileOperationFailure.recoveryUncertain }
            case .available(catalogVersion: 3), .available(catalogVersion: 4), .available(catalogVersion: 7), .available(catalogVersion: 9):
                guard await Self.confirm(in: window, title: newFile ? "Enable creating text files?" : "Enable saving text copies?",
                    message: "Traverse will update its Undo history. Earlier Traverse builds cannot use the updated history. Existing files are unchanged by this update.", action: "Enable Saving") else { throw CancellationError() }
                let result = await engine.upgradeLocalTextHistory()
                guard result.status == .succeeded, result.catalogVersion == 10 else { throw FileOperationFailure.recoveryUncertain }
            default: throw FileOperationFailure.recoveryUncertain
            }
            try Task.checkCancellation()
            let plan = try await engine.prepareLocalTextSaveAs(contents: value, generation: generation,
                destinationDirectory: destination.directory, name: destination.name)
            // Keep destination access through publication and actual readback.
            let result = await engine.performLocalTextSaveAs(plan)
            withExtendedLifetime(destination.access) {}
            return result
    }
    private func interactions(_ context: Context) -> EditorDocumentInteractions {
        .init(chooseDestination: { [weak self] native, source in
                await self?.chooseDestination(in: native, source: source, context: context)
            }, confirmReload: { native, needsDecision in
                await Self.confirmReload(in: native, dirty: needsDecision)
            }, confirmHistoryUpgrade: { native in
                await Self.confirm(in: native, title: "Enable saving in the editor?",
                    message: "Traverse will update its Undo history and keep a backup. Earlier Traverse builds won’t be able to use the updated history. Your documents are not changed by this update.", action: "Enable Saving")
            }, chooseClose: { native, disposition in await Self.closeChoice(in: native, disposition: disposition) },
            reviewVersions: { [weak self] document, record in
                guard let self, let parent = document.window.window else { return }
                let review = NativeTextVersionsWindow(files: document.files, publication: document.unresolvedPublication,
                    interactions: self.versionInteractions(context), installChrome: { native in
                        native.isRestorable = false
                        ToolWindowChrome.install(in: native, settings: context.settings)
                    })
                await review.present(from: parent, focus: record)
            }, acquireInspection: { [weak self] in
                guard let self else { throw FileOperationFailure.unavailable }; return try self.acquireInspection()
            }, finishInspection: { [weak self] in self?.coordinator.finishInspection($0) },
            acquireMutation: { [weak self] in
                guard let self else { throw FileOperationFailure.unavailable }
                return try await self.acquireMutation(context.engine)
            }, finishMutation: { [weak self] in self?.mutationAdmission.finish($0) },
            chooseTextCopyDestination: { [weak self] native, source in
                await self?.chooseDestination(in: native, source: source, context: context, isTextCopy: true)
            }, showTextCopyResults: { [weak self, weak context] record in
                guard let self, let context else { return false }
                return self.showResults(record, context: context)
            })
    }
    private func versionInteractions(_ context: Context) -> EditorVersionInteractions {
        .init(acquireInspection: { [weak self] in
                guard let self else { throw FileOperationFailure.unavailable }; return try self.acquireInspection()
            }, finishInspection: { [weak self] in self?.coordinator.finishInspection($0) },
            acquireMutation: { [weak self] in
                guard let self else { throw FileOperationFailure.unavailable }; return try await self.acquireMutation(context.engine)
            }, finishMutation: { [weak self] in self?.mutationAdmission.finish($0) },
            chooseDirectory: { native in
                guard let choice = await context.access.chooseFolder(in: native, remember: true, purpose: .fileOperation) else { return nil }
                return .init(url: choice.selection.url, access: FileAccessLifetimes(leases: [choice.lease]))
            }, confirmUndo: { native in
                await Self.confirm(in: native, title: "Undo this saved change?",
                    message: "The file will return to the verified version before this saved change. Any open editor keeps its current text; reload it afterwards. Text Undo is a separate command.", action: "Undo Saved Change")
            }, confirmRetirement: { native, _ in
                guard LocalTextEditorFeature.allowsVersionRetirement else { return false }
                return await Self.confirm(in: native, title: "Move these saved versions to Trash?",
                    message: "This ends Undo for the selected saved change. Your current document will stay where it is. Only these verified retained versions will move to Trash; nothing will be permanently deleted.", action: "Move Versions to Trash")
            }, showOperationResults: { [weak self, weak context] id in
                guard let self, let context else { return false }
                return self.showResults(id, context: context)
            }, allowsRetirement: LocalTextEditorFeature.allowsVersionRetirement,
            confirmUndoSection: { native, review in
                let count = review.endedUndoCount
                let changes = count == 1 ? "1 earlier saved change" : "\(count) earlier saved changes"
                let undoMessage = count == 0 ? "There are no earlier file Undo actions to end in this section."
                    : "File Undo will end for \(changes)."
                var message = undoMessage + " All \(review.retainedRecords) reviewed changes stay recorded, and available version copies are kept. Your visible editor text is not saved by this action."
                if review.adoptsExternalBaseline {
                    message += " The file you explicitly reloaded will become the new starting point."
                }
                return await Self.confirm(in: native, title: "Start a new Undo section?",
                    message: message, action: "Start New Section")
            })
    }

    private func showResults(_ id: UUID, context: Context) -> Bool {
        func eligible(_ browser: BrowserViewController) -> Bool {
            !browser.isBrowserSuspended && !browser.isReadOnlyFileSession
                && browser.recoverableFileOperations === context.engine
                && browser.isViewLoaded && browser.view.window != nil && browser.view.window?.attachedSheet == nil
                && browser.canRunExclusiveFileCommand
        }
        let candidates = context.browser.map { [$0] } ?? []
        let browser = (candidates + coordinator.liveBrowsers).first(where: eligible)
            ?? (NSApp.delegate as? ApplicationDelegate)?.revealEditorRecoveryHost(for: context.engine)
        guard let browser, eligible(browser) else { return false }
        browser.openOperationRecovery(recordID: id)
        return true
    }

    private func chooseDestination(in window: NSWindow, source: URL?, context: Context, isTextCopy: Bool = false, suggestedName: String? = nil) async -> EditorSaveDestination? {
        let picker = NSSavePanel()
        picker.title = isTextCopy ? "Save a Text Copy" : "Save a New File"
        picker.prompt = isTextCopy ? "Save Text Copy" : "Save New File"
        picker.message = isTextCopy
            ? "Save this captured text under a new name. The editor stays on the original, and the earlier Save still needs review. Existing files will not be replaced."
            : "Create a new file and keep the original. Existing files will not be replaced."
        picker.canCreateDirectories = false; picker.isExtensionHidden = false
        picker.directoryURL = source?.deletingLastPathComponent()
        let name = (suggestedName ?? source?.lastPathComponent ?? "Text.txt") as NSString
        let stem = name.deletingPathExtension
        picker.nameFieldStringValue = stem + " copy" + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension)
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in picker.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } onCancel: { Task { @MainActor in picker.cancel(nil) } }
        guard response == .OK, !Task.isCancelled, let url = picker.url, url.isFileURL else { return nil }
        let directory = url.deletingLastPathComponent()
        var leases: [FolderAccessLease] = []
        if TraverseAccessPolicy.requiresFolderSelection && !context.access.hasSelectedAccess(to: directory) {
            guard let choice = await context.access.chooseFolder(in: window, initialDirectory: directory,
                remember: true, purpose: .fileOperation), context.access.hasSelectedAccess(to: directory) else { return nil }
            leases.append(choice.lease)
        }
        if let lease = await context.access.acquireAccess(to: directory) { leases.append(lease) }
        guard !Task.isCancelled else { return nil }
        return .init(directory: directory, name: url.lastPathComponent, access: FileAccessLifetimes(leases: leases))
    }
    private static func confirm(in window: NSWindow, title: String, message: String, action: String) async -> Bool {
        guard window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }
    private static func confirmReload(in window: NSWindow, dirty: Bool) async -> Bool {
        guard dirty else { return true }
        return await confirm(in: window, title: "Reload this file?",
            message: "The visible editor text will be replaced by a fresh read of the file. Unsaved text will be discarded. This does not confirm or clean up an earlier interrupted Save.", action: "Reload")
    }
    private static func closeChoice(in window: NSWindow, disposition: TextDocumentState.CloseDisposition, archive: Bool = false) async -> EditorCloseChoice {
        guard window.attachedSheet == nil else { return .cancel }
        let alert = NSAlert()
        let needsRecovery = disposition == .needsRecoveryDecision
        alert.messageText = needsRecovery ? "Keep this visible text before closing?" : "Save your changes before closing?"
        alert.informativeText = needsRecovery
            ? "The earlier Save is still unconfirmed. A saved version of this visible text may not exist. Save a separate text copy, or cancel and review the earlier result. Closing discards this window’s visible text without confirming the Save."
            : archive ? "Save updates this text file inside its archive and keeps the earlier archive for Undo. A changed archive is never overwritten. Don’t Save discards only this window’s changes."
                : "Unsaved text will be lost if you close without saving. If the saved file changed, Save creates a separate new file."
        alert.addButton(withTitle: needsRecovery ? "Save a Text Copy…" : "Save")
        alert.addButton(withTitle: needsRecovery ? "Close and Discard Visible Text" : "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        if needsRecovery { alert.buttons[0].keyEquivalent = ""; alert.buttons[2].keyEquivalent = "\r" }
        let reply: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if reply == .alertFirstButtonReturn { return needsRecovery ? .textCopy : .save }
        if reply == .alertSecondButtonReturn { return .discard }
        return .cancel
    }
    private func position(_ window: NSWindow, relativeTo owner: NSWindow?) {
        ToolWindowChrome.position(window, relativeTo: owner)
    }

    /// Returns only after actual grant acquisition and each approved document
    /// close has joined. Cancel keeps the remaining documents open and editable.
    func prepareForTermination() async -> Bool {
        guard !reviewingTermination, !terminationPrepared else { return terminationPrepared }
        reviewingTermination = true
        defer { reviewingTermination = false }
        for (id, files) in reviewDrainFailures {
            guard !files.isWorking else { return false }
            do { try files.closeAfterDrain(); reviewDrainFailures.removeValue(forKey: id) }
            catch { return false }
        }
        if !historicalReviews.isEmpty {
            reviewControllers.values.first?.window?.makeKeyAndOrderFront(nil)
            return false
        }
        let pending = Array(opening.values); pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        guard await archiveEditors.prepareForTermination() else { return false }
        let current = documents.values.map(\.document)
        for document in current {
            if !document.isClosed {
                let closed = await document.closeForTermination()
                if !closed { return false }
            }
        }
        let ready = documents.isEmpty && opening.isEmpty && !mutationAdmission.hasActiveOwner && mutationAdmission.waitingCount == 0
        if ready { terminationPrepared = true; mutationAdmission.closeWaiters() }
        return ready
    }
    func resumeAfterCancelledTermination() {
        ApplicationRemoteTextEditors.shared.resumeAfterCancelledTermination()
        archiveEditors.resumeAfterCancelledTermination()
        terminationPrepared = false; mutationAdmission.resumeAfterCancelledTermination()
    }
}
