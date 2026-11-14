import AppKit
import Combine
import FileOperations

/// Immutable text captured by the session owner. No network, file URL, Save,
/// export or recovery authority is passed to this presentation.
@MainActor final class RemoteTextSnapshotController {
    let id = UUID(), connectionID: UUID
    let window: NativeTextEditorWindow
    let contents: TextDocumentValue
    private let displayName: String, location: EditorLocationContext?
    private let settings: BrowserSettings
    private let retainedCopy: Bool
    private let protocolKind: ExplorerConnectionProtocol
    private var observation: AnyCancellable?
    private var closing: Task<Void, Never>?
    private var languageOverride = false, wrappingOverride = false, disconnected = false, nativeClosed = false
    private(set) var closed = false
    var didClose: ((UUID) -> Void)?
    lazy var preparation = EditorPreparationOwner { [weak self] input, result in
        guard let self, !closed, case .presentation(_, let generation, _, _, _, _) = input,
              case .presentation(let value, let syntax, let lines, _) = result else { return }
        _ = window.surface.present(value, syntax: syntax, lines: lines, for: generation)
    }
    init(contents: TextDocumentValue, name: String, connection: UUID, location: EditorLocationContext?,
         settings: BrowserSettings, retainedCopy: Bool, protocolKind: ExplorerConnectionProtocol = .sftp) {
        self.contents = contents; displayName = name; connectionID = connection
        self.location = location; self.settings = settings; self.retainedCopy = retainedCopy
        self.protocolKind = protocolKind
        window = .init(displayName: name, installChrome: { native in
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
        refresh()
    }
    private func apply(_ value: EditorPreferences) {
        guard !closed else { return }
        window.applyEditorPreferences(value, pointSize: CGFloat(value.basePointSize) * InterfaceMetrics.scale,
            applyWrapping: !wrappingOverride)
        InterfaceMetrics.setFont(window.surface.textView,
            base: .monospacedSystemFont(ofSize: CGFloat(value.basePointSize), weight: .regular))
        if !languageOverride { present(value.language(forFilename: displayName)) }
    }
    private func present(_ language: TextSyntaxLanguage) {
        guard !closed, closing == nil else { return }
        window.language.selectItem(at: TextSyntaxLanguage.allCases.firstIndex(of: language) ?? 0)
        try? preparation.submit(.presentation(ticket: nil, surfaceGeneration: window.surface.generation,
            text: contents.text, format: contents.format, language: language))
    }
    func show(visible: Bool = true) {
        guard !closed, closing == nil else { return }
        if visible { window.presentEditor(in: .connection(connectionID), arrangement: settings.editorPreferences.windowArrangement) }
    }
    func connectionClosed() { disconnected = true; refresh() }
    private func refresh() {
        window.update(displayName: displayName, dirty: false,
            status: disconnected ? "Read-only snapshot · disconnected" : "Read-only snapshot · " + protocolKind.rawValue,
            documentFormat: contents.format, canSave: false, working: false, canReload: false,
            needsRecovery: retainedCopy,
            explanation: retainedCopy ? "Temporary text data was kept because cleanup could not be confirmed. This window cannot change the server file." : nil,
            canReviewVersions: false, location: location)
    }
    func closeAndDrain() async {
        if let closing { await closing.value; return }
        if closed { return }
        let task = Task { [self] in
            await preparation.closeAndDrain()
            await window.closeComparisonAndDrain()
            if !nativeClosed { window.finishClose() }
            if nativeClosed { closed = true; observation = nil; didClose?(id) }
        }
        closing = task; await task.value
    }
}
