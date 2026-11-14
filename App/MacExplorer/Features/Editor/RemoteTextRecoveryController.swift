import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// Explicit body review only. Choices carry engine-owned affinity; no raw
/// recovery paths, caller-created record lookup or remote retry action exists.
@MainActor final class RemoteTextRecoveryController {
    #if DEBUG
    static var viewerForVerification: ((RemoteTextRecoveryController?) -> Void)?
    #endif
    let window: NativeTextEditorWindow
    let contents: TextDocumentValue
    private let retainedView: RemoteRetainedTextView?
    /// Existing SFTP native pin checks observe the original concrete owner.
    var viewed: SFTPInPlaceViewedVersion? {
        if case .sftp(let view)? = retainedView { return view }; return nil
    }
    private var retainedTitle: String { "Retained " + (retainedView?.protocolName ?? "Server") + " Text" }
    let locationContext: EditorLocationContext?
    let acquire: () async throws -> UUID, finish: (UUID) -> Void
    let choose: (NSWindow) async -> EditorSaveDestination?
    let publish: (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult
    let showResult: (UUID) -> Void
    var work: Task<Void, Never>?, closing: Task<Void, Never>?
    var closed = false, nativeClosed = false
    var waiter: CheckedContinuation<Void, Never>?
    var message = "Retained version · read only"
    var uncertainDestinations: [URL] = [], copyRecords: [UUID] = []
    lazy var preparation = EditorPreparationOwner { [weak self] input, result in
        guard let self, case .presentation(_, let generation, _, _, _, _) = input,
              case .presentation(let value, let syntax, let lines, _) = result else { return }
        _ = window.surface.present(value, syntax: syntax, lines: lines, for: generation)
    }
    init(contents: TextDocumentValue, viewed: RemoteRetainedTextView? = nil, settings: BrowserSettings,
         locationContext: EditorLocationContext? = nil,
         acquire: @escaping () async throws -> UUID, finish: @escaping (UUID) -> Void,
         choose: @escaping (NSWindow) async -> EditorSaveDestination?,
         publish: @escaping (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult,
         showResult: @escaping (UUID) -> Void) {
        self.contents = contents; retainedView = viewed; self.acquire = acquire; self.finish = finish
        self.locationContext = locationContext
        self.choose = choose; self.publish = publish; self.showResult = showResult
        window = .init(displayName: "Retained " + (viewed?.protocolName ?? "Server") + " Text", installChrome: { native in
            native.isRestorable = false; ToolWindowChrome.install(in: native, settings: settings)
        })
        window.configureLocalCopyPresentation()
        window.surface.install(contents); window.surface.textView.isEditable = false
        window.applyEditorPreferences(settings.editorPreferences,
            pointSize: CGFloat(settings.editorPreferences.basePointSize) * InterfaceMetrics.scale)
        window.onSaveAs = { [weak self] in self?.copy() }
        window.onTextCopy = { [weak self] in self?.copy() }
        window.onTextCopyResults = { [weak self] record in
            guard let self, let id = record ?? copyRecords.last else { return }; showResult(id)
        }
        window.onStop = { [weak self] in self?.work?.cancel() }
        window.onWrapping = {}
        window.onLanguage = { [weak self] language in self?.present(language) }
        window.shouldClose = { [weak self] in
            guard let self, work == nil else { return false }
            Task { [self] in await closeAndDrain() }
            return false
        }
        window.didClose = { [weak self] in self?.nativeClosed = true }
        present(.plain); refresh()
    }
    func present(_ language: TextSyntaxLanguage) {
        guard !closed, closing == nil else { return }
        try? preparation.submit(.presentation(ticket: nil, surfaceGeneration: window.surface.generation,
            text: contents.text, format: contents.format, language: language))
    }
    func refresh() {
        window.update(displayName: retainedTitle, dirty: false, status: message, documentFormat: contents.format,
            canSave: false, working: work != nil, canReload: false, needsRecovery: true,
            explanation: "This is a verified retained version, not a read of the current server file. Saving a local copy does not confirm or retry the remote Save.",
            canReviewVersions: false, canSaveTextCopy: work == nil && uncertainDestinations.count < 8,
            hasTextCopyRecovery: !uncertainDestinations.isEmpty, canViewTextCopyResults: work == nil && !copyRecords.isEmpty,
            textCopyResults: copyRecords.map { .init(id: $0, title: "Retained Text Copy") }, location: locationContext)
        window.saveAsButton.isEnabled = !closed && closing == nil && work == nil && uncertainDestinations.count < 8
    }
    func copy() {
        guard !closed, closing == nil, work == nil, uncertainDestinations.count < 8, let native = window.window else { return }
        let generation = UUID()
        work = Task { [self] in
            var permit: UUID?
            var held: EditorSaveDestination?
            do {
                guard let destination = await choose(native) else { throw CancellationError() }; held = destination
                let target = destination.directory.appendingPathComponent(destination.name).standardizedFileURL
                guard !uncertainDestinations.contains(target) else { throw FileOperationFailure.recoveryUncertain }
                permit = try await acquire(); try Task.checkCancellation()
                switch try await publish(contents, generation, destination, native) {
                case .saved(let receipt) where receipt.generation == generation && receipt.document.contents == contents:
                    copyRecords = Array((copyRecords + [receipt.recordID]).suffix(8)); message = "Retained text copied locally · remote result unchanged"
                case .saved:
                    uncertainDestinations.append(target); message = "Local copy needs review · retained version is protected"
                case .uncertain(let value), .publishedNeedsReload(let value):
                    uncertainDestinations.append(target)
                    if value.generation == generation, value.intendedURL.standardizedFileURL == target, let record = value.recordID {
                        copyRecords = Array((copyRecords + [record]).suffix(8))
                    }
                    message = "Local copy unconfirmed · review Copy Results"
                case .refused: message = "Local copy not saved · retained version is protected"
                }
            } catch { message = "Local copy not saved · retained version is protected" }
            if let permit { finish(permit) }
            withExtendedLifetime(held?.access) {}
            work = nil; refresh()
        }
        refresh()
    }
    /// A read-only viewer still owns its real export and preparation workers.
    /// Parent Stop/Quit joins those workers before releasing the viewed body.
    func presentUntilClosed(visible: Bool = true) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !closed else { continuation.resume(); return }
                precondition(waiter == nil)
                waiter = continuation
                if visible { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil) }
            }
        } onCancel: {
            Task { @MainActor [self] in await closeAndDrain() }
        }
    }
    func closeAndDrain() async {
        if closed { return }
        if let closing { await closing.value; return }
        let task = Task { [self] in
            let held = work; held?.cancel()
            if let held { await held.value }
            await preparation.closeAndDrain()
            await window.closeComparisonAndDrain()
            window.retainPresentationDuringClose = true
            nativeClosed = false
            window.finishClose()
            // The actual AppKit close ends the displayed version. The pin
            // remains through every export and presentation worker above.
            let pinEnded: Bool
            if nativeClosed { pinEnded = await retainedView?.closeAndDrain() ?? true }
            else { pinEnded = false }
            if nativeClosed && pinEnded {
                closed = true
                window.surface.clearPrivatePresentation(); window.retainPresentationDuringClose = false
                waiter?.resume(); waiter = nil
            } else {
                preparation = EditorPreparationOwner { [weak self] input, result in
                    guard let self, case .presentation(_, let generation, _, _, _, _) = input,
                          case .presentation(let value, let syntax, let lines, _) = result else { return }
                    _ = self.window.surface.present(value, syntax: syntax, lines: lines, for: generation)
                }
                window.reopenAfterFailedClose()
                message = "Review remains open; local closure is not confirmed. The retained text stays owned."
                refresh()
            }
        }
        closing = task; await task.value; closing = nil
    }

    static func review(document: RemoteEditableTextBackend, from host: NSWindow, settings: BrowserSettings,
        refusedReview: RemoteRetainedTextChoice.RefusedReview? = nil,
        acquire: @escaping () async throws -> UUID, finish: @escaping (UUID) -> Void,
        choose: @escaping (NSWindow) async -> EditorSaveDestination?,
        publish: @escaping (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult,
        showResult: @escaping (UUID) -> Void) async {
        do {
            let choices = try await document.recoveryChoicesAfterExplicitRequest()
            try Task.checkCancellation()
            guard host.attachedSheet == nil else { return }
            let chosen: (RemoteRetainedTextChoice, RemoteRetainedTextChoice.Version)
            if let refusedReview {
                guard let exact = RemoteRetainedTextChoice.refusedChoice(in: choices, generation: refusedReview.generation),
                      exact.availableVersions.contains(refusedReview.version) else {
                    let alert = NSAlert(); alert.messageText = "This Save's retained version is unavailable"
                    alert.informativeText = "No single verified retained record matches this unsubmitted Save. Your visible text is kept. Use Save a Text Copy or All Saved Versions. No older version was substituted and no server read or retry occurred."
                    await alert.beginSheetModal(for: host); return
                }
                chosen = (exact, refusedReview.version)
            } else {
                // A finite native selector; refuse excessive metadata rather than
                // silently hide retained records or infer current-server contents.
                let values = choices.flatMap { choice in choice.availableVersions.map { (choice, $0) } }
                guard !values.isEmpty, values.count <= 64 else {
                    let alert = NSAlert(); alert.messageText = "Retained versions are unavailable for review here"
                    alert.informativeText = "No current server read or retry occurred. Existing retained data stays protected."
                    await alert.beginSheetModal(for: host); return
                }
                let picker = NSPopUpButton(frame: .init(x: 0, y: 0, width: 320, height: 26))
                for (index, value) in values.enumerated() {
                    let name: String
                    switch value.1 { case .before: name = "Before Save"; case .edited: name = "Edited Text" }
                    picker.addItem(withTitle: "Version \(index + 1) · \(name)")
                }
                picker.setAccessibilityLabel("Retained " + document.protocolName + " version")
                let alert = NSAlert(); alert.messageText = "Review a retained " + document.protocolName + " version"
                alert.informativeText = "Open one verified local before/edited version. This does not read the server or confirm the earlier Save."
                alert.accessoryView = picker; alert.addButton(withTitle: "Review"); alert.addButton(withTitle: "Cancel")
                guard await alert.beginSheetModal(for: host) == .alertFirstButtonReturn,
                      values.indices.contains(picker.indexOfSelectedItem) else { return }
                chosen = values[picker.indexOfSelectedItem]
            }
            let viewed = try await chosen.0.readPinnedVersion(chosen.1)
            if Task.isCancelled { _ = await viewed.closeAndDrain(); throw CancellationError() }
            let controller = RemoteTextRecoveryController(contents: viewed.contents, viewed: viewed, settings: settings,
                locationContext: .retained(file: chosen.0.presentation.fileName, server: chosen.0.presentation.server,
                    version: chosen.1 == .before ? "Before Save" : "Edited Text"),
                acquire: acquire, finish: finish, choose: choose, publish: publish, showResult: showResult)
            InterfacePresentation.shared.register(controller.window.surface)
            #if DEBUG
            viewerForVerification?(controller)
            #endif
            await controller.presentUntilClosed()
            #if DEBUG
            viewerForVerification?(nil)
            #endif
            withExtendedLifetime(controller) {}
        } catch {
            guard host.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Retained version could not be verified"
            alert.informativeText = "The copy was not exported. Keep the visible editor text and use Save a Text Copy if needed. No remote retry occurred."
            await alert.beginSheetModal(for: host)
        }
    }
}
