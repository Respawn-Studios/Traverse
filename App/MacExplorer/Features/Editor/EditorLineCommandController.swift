import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

enum EditorCommandNotice: Sendable {
    case cannotFormatJSON
    var message: String { "This JSON could not be formatted. Check its syntax; your text is unchanged." }
}

/// One explicit in-memory edit; no URL, file access, Save or durable history.
private enum EditorPreparedLineCommand: Sendable {
    case unchanged, cancelled
    case select(NSRange)
    case replace(EditorIndentationReplacement, TextDocumentValue)
    case refused(TextDocumentFailure)
    case notice(EditorCommandNotice)

    static func make(_ command: EditorLineCommand, text: String, selection: NSRange,
                     format: TextDocumentFormat) -> Self {
        guard !Task.isCancelled else { return .cancelled }
        let plan = EditorLineCommands.plan(command, text: text, selection: selection,
                                           maximumBytes: TextDocumentValue.maximumBytes)
        guard !Task.isCancelled else { return .cancelled }
        switch plan {
        case .unchanged: return .unchanged
        case .select(let range): return .select(range)
        case .refused(let reason):
            if reason == .cannotFormatJSON { return .notice(.cannotFormatJSON) }
            return .refused(reason == .tooLarge ? .tooLarge : .invalidReceipt)
        case .replace(let edit):
            let expected = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
            do {
                let value = try TextDocumentValue.edited(expected, format: format)
                guard value.text.utf16.elementsEqual(expected.utf16) else { return .refused(.invalidReceipt) }
                return Task.isCancelled ? .cancelled : .replace(edit, value)
            } catch let reason as TextDocumentFailure { return .refused(reason) }
            catch { return .refused(.invalidReceipt) }
        }
    }
}

/// One preparation and at most eight explicit repeated commands. Each queued
/// command takes a fresh snapshot; stale input clears the queue rather than
/// replaying commands against another document or text control.
@MainActor
final class EditorLineCommandController {
    private weak var surface: NativeTextEditorSurface?
    private var worker: Task<EditorPreparedLineCommand, Never>?
    private var delivery: Task<Void, Never>?
    private var request: UUID?
    private var pending: [EditorLineCommand] = []
    private var inputEpoch = UUID()
    private var admittedSelection: NSRange?
    private var applying = false
    private var closed = false
    var onNotice: ((EditorCommandNotice) -> Void)?

    #if DEBUG
    /// Qualification only: task-boundary observations and one async hold. Neither
    /// hook can replace a plan, text, selection, native admission or its result.
    enum VerificationEvent: Sendable {
        case preparationStarted, preparationFinished, deliveryStarted, deliveryFinished
    }
    struct VerificationState: Sendable {
        let hasWorker: Bool, hasDelivery: Bool, pendingCount: Int, isClosed: Bool
        var hasRetainedWork: Bool { hasWorker || hasDelivery || pendingCount != 0 }
    }
    var eventForVerification: (@Sendable (VerificationEvent) -> Void)?
    var preparationHoldForVerification: (@Sendable () async -> Void)?
    var stateForVerification: VerificationState {
        .init(hasWorker: worker != nil, hasDelivery: delivery != nil,
              pendingCount: pending.count, isClosed: closed)
    }
    #endif

    init(surface: NativeTextEditorSurface) { self.surface = surface }

    var canPerform: Bool {
        guard !closed, let surface, let window = surface.window,
              window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
              window.firstResponder === surface.textView, surface.textView.isEditable,
              !surface.textView.hasMarkedText(), surface.textView.selectedRanges.count == 1 else { return false }
        return true
    }

    func perform(_ command: EditorLineCommand) {
        guard canPerform else { return }
        if worker != nil {
            guard pending.count < 8 else { NSSound.beep(); return }
            pending.append(command)
            return
        }
        begin(command)
    }

    private func startNext() {
        guard canPerform else { pending.removeAll(); return }
        guard worker == nil, !pending.isEmpty else { return }
        begin(pending.removeFirst())
    }

    private func begin(_ command: EditorLineCommand) {
        guard worker == nil, canPerform, let surface else { return }
        let original = surface.textView.string
        let selection = surface.textView.selectedRange()
        let generation = surface.generation
        let format = surface.documentFormat
        let id = UUID(), epoch = inputEpoch
        request = id; admittedSelection = selection
        #if DEBUG
        let verificationEvent = eventForVerification
        let verificationHold = preparationHoldForVerification
        #endif
        let task = Task.detached(priority: .userInitiated) {
            #if DEBUG
            verificationEvent?(.preparationStarted)
            defer { verificationEvent?(.preparationFinished) }
            await verificationHold?()
            #endif
            return EditorPreparedLineCommand.make(command, text: original, selection: selection, format: format)
        }
        worker = task
        delivery = Task { [weak self] in
            #if DEBUG
            verificationEvent?(.deliveryStarted)
            defer { verificationEvent?(.deliveryFinished) }
            #endif
            let prepared = await task.value
            guard let self, self.request == id else { return }
            self.request = nil; self.worker = nil; self.delivery = nil; self.admittedSelection = nil
            defer { self.startNext() }
            guard self.inputEpoch == epoch else { return }
            guard self.canPerform, let current = self.surface,
                  current.generation == generation,
                  current.documentFormat == format,
                  current.textView.selectedRange() == selection,
                  current.textView.string.utf16.elementsEqual(original.utf16) else { self.pending.removeAll(); return }
            self.applying = true
            defer { self.applying = false }
            switch prepared {
            case .cancelled: self.pending.removeAll(); return
            case .unchanged: return
            case .refused(let reason): self.pending.removeAll(); current.onRejectedEdit?(reason)
            case .notice(let notice): self.pending.removeAll(); self.onNotice?(notice)
            case .select(let range):
                // Identical line movement changes the caret, never text Undo.
                current.textView.setSelectedRange(range)
                current.textView.scrollRangeToVisible(range)
            case .replace(let edit, let value):
                current.textView.breakUndoCoalescing()
                current.textView.insertText(edit.text, replacementRange: edit.range)
                current.textView.breakUndoCoalescing()
                guard current.textView.string.utf16.elementsEqual(value.text.utf16) else { self.pending.removeAll(); return }
                let name: String
                switch command {
                case .duplicateSelectedLines: name = "Duplicate Lines"
                case .moveLinesUp: name = "Move Lines Up"
                case .moveLinesDown: name = "Move Lines Down"
                case .toggleLineComment: name = "Toggle Line Comment"
                case .formatJSON(let style, _):
                    if case .compact = style { name = "Compact JSON" } else { name = "Format JSON" }
                case .sortSelectedLines(let descending): name = descending ? "Sort Lines Descending" : "Sort Lines Ascending"
                case .trimTrailingWhitespace: name = "Trim Trailing Whitespace"
                case .surroundSelection: name = "Surround Selection"
                }
                current.textView.undoManager?.setActionName(name)
                current.textView.setSelectedRange(edit.selection)
                current.textView.scrollRangeToVisible(edit.selection)
            }
        }
    }

    /// Synchronous input-boundary invalidation. Retain the cancelled worker
    /// until its actual delivery so a returning user cannot start a second one.
    func inputDidChange() {
        guard !closed, !applying else { return }
        inputEpoch = UUID(); pending.removeAll(); worker?.cancel()
    }

    func selectionDidChange() {
        guard !applying, let admittedSelection, let surface,
              surface.textView.selectedRange() != admittedSelection else { return }
        inputDidChange()
    }

    func close() {
        closed = true; inputEpoch = UUID(); pending.removeAll()
        worker?.cancel(); surface = nil; onNotice = nil
        // Completion still clears request/worker/delivery after actual drain.
    }
}
