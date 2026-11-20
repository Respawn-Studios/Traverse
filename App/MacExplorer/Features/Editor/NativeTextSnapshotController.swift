import AppKit
import Combine
import FileOperations

/// Immutable text captured by the session owner. The presentation receives
/// the bytes and their provenance alongside a native window group.
@MainActor final class NativeTextSnapshotController {
    let id = UUID()
    let window: NativeTextEditorWindow
    private var contents: TextDocumentValue?
    private let filename: String, displayName: String, location: EditorLocationContext?
    private let settings: BrowserSettings
    private let group: NativeTextEditorWindow.Group?
    private let explanation: String?
    private var observation: AnyCancellable?
    private var closing: Task<Void, Never>?
    private var languageOverride = false, wrappingOverride = false, nativeClosed = false
    private(set) var closed = false
    var initialLine: Int?
    var didClose: ((UUID) -> Void)?
    lazy var preparation = EditorPreparationOwner { [weak self] input, result in
        guard let self, !closed, case .presentation(let request) = input,
              case .presentation(let prepared) = result else { return }
        let generation = request.generation
        if window.surface.present(prepared, for: generation), let initialLine {
            self.initialLine = nil
            window.surface.goToLine(initialLine, generation: generation, remembersLocation: false)
        }
    }
    init(contents: TextDocumentValue, filename: String, title: String? = nil, location: EditorLocationContext?,
         status: String, explanation: String? = nil, settings: BrowserSettings, group: NativeTextEditorWindow.Group? = nil) {
        self.contents = contents
        self.filename = filename
        self.displayName = title ?? filename
        self.location = location
        self.settings = settings
        self.group = group
        self.explanation = explanation
        window = .init(displayName: title ?? filename, installChrome: { native in
            native.isRestorable = false; ToolWindowChrome.install(in: native, settings: settings)
        })
        window.surface.install(contents); window.configureReadOnlyPresentation()
        window.bindKeyboardBehavior(to: settings)
        window.onLanguage = { [weak self] language in
            guard let self else { return }; languageOverride = true; present(language)
        }
        window.onWrapping = { [weak self] in self?.wrappingOverride = true }
        window.shouldClose = { [weak self] in
            guard let self, !closed else { return true }
            Task { [self] in await closeAndDrain() }; return false
        }
        window.didClose = { [weak self] in
            guard let self else { return }; nativeClosed = true
            if closing == nil { Task { [self] in await closeAndDrain() } }
        }
        apply(settings.editorPreferences)
        observation = settings.$editorPreferences.removeDuplicates().sink { [weak self] value in self?.apply(value) }
        InterfacePresentation.shared.register(window.surface)
        updateStatus(status)
    }
    private func apply(_ value: EditorPreferences) {
        guard !closed else { return }
        window.applyEditorPreferences(value, pointSize: CGFloat(value.basePointSize) * InterfaceMetrics.scale,
            applyWrapping: !wrappingOverride)
        InterfaceMetrics.setFont(window.surface.textView,
            base: .monospacedSystemFont(ofSize: CGFloat(value.basePointSize), weight: .regular))
        if !languageOverride { present(value.language(forFilename: filename)) }
    }
    private func present(_ language: TextSyntaxLanguage) {
        guard !closed, closing == nil, let contents else { return }
        window.language.selectItem(at: TextSyntaxLanguage.allCases.firstIndex(of: language) ?? 0)
        try? preparation.submit(.presentation(ticket: nil, surfaceGeneration: window.surface.generation,
            text: contents.text, format: contents.format, language: language))
    }
    func show(visible: Bool = true) {
        guard visible, !closed, closing == nil else { return }
        if let group { window.presentEditor(in: group, arrangement: settings.editorPreferences.windowArrangement) }
        else { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil) }
    }
    func updateStatus(_ status: String) {
        guard let contents else { return }
        window.update(displayName: displayName, dirty: false,
            status: status, documentFormat: contents.format, canSave: false, working: false, canReload: false,
            needsRecovery: explanation != nil, explanation: explanation,
            canReviewVersions: false, location: location)
    }
    func closeAndDrain() async {
        if let closing { await closing.value; return }
        if closed { return }
        let task = Task { [self] in
            await preparation.closeAndDrain()
            await window.closeComparisonAndDrain()
            if !nativeClosed {
                let faded = await window.prepareAcceptedClose()
                if !faded { window.cancelAcceptedClosePreparation() }
                if !nativeClosed { window.finishClose() }
            }
            if nativeClosed {
                closed = true; observation = nil; contents = nil
                window.surface.clearPrivatePresentation()
                didClose?(id)
            }
        }
        closing = task; await task.value
    }
}
