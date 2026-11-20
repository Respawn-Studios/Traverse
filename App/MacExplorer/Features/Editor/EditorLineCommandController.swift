import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

enum EditorCommandNotice: Sendable {
    case cannotFormatJSON, noMatchingBracket, noEnclosingBrackets, noCompleteConflict
    var message: String {
        switch self {
        case .cannotFormatJSON: "This JSON could not be formatted. Check its syntax; your text is unchanged."
        case .noMatchingBracket: "Place the caret beside a matched code bracket."
        case .noEnclosingBrackets: "No enclosing bracket pair is available for this selection."
        case .noCompleteConflict: "Place the caret inside a complete conflict marker block."
        }
    }
}

@MainActor enum EditorSelectionAdjustment: Int, CaseIterable {
    case expand, shrink

    static func menuItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
        allCases.map { choice in
            let next = choice == .expand
            let item = BrowserMenus.item(next ? "Expand Selection" : "Shrink Selection", action,
                key: next ? "\u{f703}" : "\u{f702}", modifiers: [.command, .control, .shift], target: target)
            item.tag = choice.rawValue
            return item
        }
    }
}

/// One explicit in-memory edit; no URL, file access, Save or durable history.
private enum EditorPreparedLineCommand: Sendable {
    case unchanged, cancelled
    case select(NSRange)
    case replace(EditorIndentationReplacement, TextDocumentValue)
    case refused(TextDocumentFailure)
    case notice(EditorCommandNotice)

    static func make(_ command: EditorLineCommand, text: String, selection: NSRange,
                     format: TextDocumentFormat, structure: EditorSelectionStructure?) -> Self {
        guard !Task.isCancelled else { return .cancelled }
        let plan = EditorLineCommands.plan(command, text: text, selection: selection,
                                           maximumBytes: TextDocumentValue.maximumBytes, structure: structure)
        guard !Task.isCancelled else { return .cancelled }
        switch plan {
        case .unchanged: return .unchanged
        case .select(let range): return .select(range)
        case .refused(let reason):
            if reason == .cannotFormatJSON { return .notice(.cannotFormatJSON) }
            if reason == .noMatchingBracket { return .notice(.noMatchingBracket) }
            if reason == .noEnclosingBrackets { return .notice(.noEnclosingBrackets) }
            if reason == .noCompleteConflict { return .notice(.noCompleteConflict) }
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
    private var expansionTrail: [EditorNavigationPosition] = []
    private var expandedSelection: NSRange?
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

    var canNavigate: Bool {
        guard !closed, let surface, let window = surface.window,
              window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
              window.firstResponder === surface.textView,
              !surface.textView.hasMarkedText(), surface.textView.selectedRanges.count == 1 else { return false }
        return true
    }

    var canPerform: Bool { canNavigate && surface?.textView.isEditable == true }

    func canAdjustSelection(_ direction: EditorSelectionAdjustment) -> Bool {
        guard canNavigate, let surface, let lines = surface.lineIndex, lines.length > 0 else { return false }
        if direction == .expand { return surface.textView.selectedRange().length < lines.length }
        return worker == nil && !expansionTrail.isEmpty && expandedSelection == surface.textView.selectedRange()
    }

    func adjustSelection(_ direction: EditorSelectionAdjustment) {
        guard canAdjustSelection(direction), let surface else { return }
        if direction == .expand { perform(.expandSelection); return }
        guard let prior = expansionTrail.popLast() else { return }
        applying = true
        defer { applying = false }
        surface.restoreNavigationPosition(prior)
        expandedSelection = expansionTrail.isEmpty ? nil : prior.selection
    }

    private func forgetExpansion() {
        expandedSelection = nil
        expansionTrail.removeAll(keepingCapacity: true)
    }

    private func admits(_ command: EditorLineCommand) -> Bool { command.changesText ? canPerform : canNavigate }

    func perform(_ command: EditorLineCommand) {
        guard admits(command) else { return }
        if worker != nil {
            guard pending.count < 8 else { NSSound.beep(); return }
            pending.append(command)
            return
        }
        begin(command)
    }

    func applyComparedChange(_ change: EditorComparisonApplication, completion: @escaping (Bool) -> Void) {
        guard worker == nil, pending.isEmpty, surface?.generation == change.editor.generation, canPerform else {
            completion(false); return
        }
        begin(.applyComparedChange(change), completion: completion)
    }

    private func startNext() {
        guard worker == nil, let next = pending.first else { return }
        guard admits(next) else { pending.removeAll(); return }
        begin(pending.removeFirst())
    }

    private func begin(_ command: EditorLineCommand, completion: ((Bool) -> Void)? = nil) {
        guard worker == nil, admits(command), let surface else { completion?(false); return }
        let original = surface.textView.string
        let selection = surface.textView.selectedRange()
        let generation = surface.generation
        let format = surface.documentFormat
        let structure = command == .expandSelection ? surface.selectionStructure() : nil
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
            return EditorPreparedLineCommand.make(command, text: original, selection: selection, format: format, structure: structure)
        }
        worker = task
        delivery = Task { [weak self] in
            var applied = false
            defer { completion?(applied) }
            #if DEBUG
            verificationEvent?(.deliveryStarted)
            defer { verificationEvent?(.deliveryFinished) }
            #endif
            let prepared = await task.value
            guard let self, self.request == id else { return }
            self.request = nil; self.worker = nil; self.delivery = nil; self.admittedSelection = nil
            defer { self.startNext() }
            guard self.inputEpoch == epoch else { return }
            guard self.admits(command), let current = self.surface,
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
                if command == .expandSelection, let position = current.navigationPosition() {
                    current.revealNavigationSelection(range, remembersLocation: false)
                    guard current.textView.selectedRange() == range else { self.forgetExpansion(); return }
                    if self.expansionTrail.count == 24 { self.expansionTrail.removeFirst() }
                    self.expansionTrail.append(position)
                    self.expandedSelection = range
                } else {
                    self.forgetExpansion()
                    current.revealNavigationSelection(range, remembersLocation: !command.changesText)
                }
            case .replace(let edit, let value):
                guard command.changesText else { return }
                self.forgetExpansion()
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
                case .resolveConflict(let choice): name = choice.title
                case .applyComparedChange: name = "Apply Compared Change"
                case .navigateBrackets, .expandSelection: return
                }
                applied = current.applyTextReplacement(edit, expecting: value, action: name)
                if !applied { self.pending.removeAll() }
            }
        }
    }

    /// Synchronous input-boundary invalidation. Retain the cancelled worker
    /// until its actual delivery so a returning user cannot start a second one.
    func inputDidChange(preservingExpansion: Bool = false) {
        guard !closed, !applying else { return }
        if !preservingExpansion { forgetExpansion() }
        inputEpoch = UUID(); pending.removeAll(); worker?.cancel()
    }

    func selectionDidChange() {
        guard !applying, let surface else { return }
        let selection = surface.textView.selectedRange()
        if let expandedSelection, selection != expandedSelection { forgetExpansion() }
        if let admittedSelection, selection != admittedSelection { inputDidChange() }
    }

    func close() {
        forgetExpansion()
        closed = true; inputEpoch = UUID(); pending.removeAll()
        worker?.cancel(); surface = nil; onNotice = nil
        // Completion still clears request/worker/delivery after actual drain.
    }
}
