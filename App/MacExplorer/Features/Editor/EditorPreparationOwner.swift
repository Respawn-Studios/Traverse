import Dispatch
import Foundation
#if canImport(FileOperations)
import FileOperations
#endif

/// Detached copy correlation only; no document-state or filesystem authority.
struct TextCopyCapture: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let binding: TextDocumentBinding
    let surfaceGeneration: UUID
    let format: TextDocumentFormat
    init(id: UUID = UUID(), binding: TextDocumentBinding, surfaceGeneration: UUID, format: TextDocumentFormat) {
        self.id = id; self.binding = binding; self.surfaceGeneration = surfaceGeneration; self.format = format
    }
    var description: String { "<text copy capture>" }
    var debugDescription: String { description }
}

enum EditorPreparationInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case presentation(ticket: TextEditTicket?, surfaceGeneration: UUID, text: String,
                      format: TextDocumentFormat, language: TextSyntaxLanguage,
                      detectsLanguage: Bool = false)
    case save(capture: TextSaveCapture, text: String)
    case copy(capture: TextCopyCapture, text: String)
    var description: String { "<editor preparation request>" }
    var debugDescription: String { description }

    // Both explicit publication intents occupy the same immutable slot. The
    // existing name remains compatible with ordinary Save callers.
    var isSave: Bool { switch self { case .save, .copy: true; case .presentation: false } }
    var captureID: UUID? { switch self { case .save(let capture, _): capture.id; case .copy(let capture, _): capture.id; case .presentation: nil } }
    var text: String {
        switch self { case .presentation(_, _, let text, _, _, _), .save(_, let text), .copy(_, let text): text }
    }
    var format: TextDocumentFormat {
        switch self { case .presentation(_, _, _, let format, _, _): format; case .save(let capture, _): capture.format; case .copy(let capture, _): capture.format }
    }
}

enum EditorPreparationResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case presentation(TextDocumentValue, TextSyntaxResult, EditorLineIndex,
                      detectedLanguage: TextSyntaxLanguage? = nil)
    case save(TextDocumentValue)
    case copy(TextDocumentValue)
    case invalid(TextDocumentFailure)
    case cancelled
    var description: String { "<editor preparation result>" }
    var debugDescription: String { description }
}

final class EditorPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    var isCancelled: Bool { lock.withLock { stopped } }
}

/// One real computation per open document, one immutable Save/copy and one replaceable
/// presentation request. Typing can supersede coloring, never Command-S.
/// No file, bookmark, journal, network, autosave or draft-persistence authority.
@MainActor
final class EditorPreparationOwner {
    typealias Compute = @Sendable (EditorPreparationInput, EditorPreparationCancellation) -> EditorPreparationResult
    typealias Completion = @MainActor (EditorPreparationInput, EditorPreparationResult) -> Void
    private struct Request: Sendable {
        let id = UUID()
        let input: EditorPreparationInput
        let cancellation = EditorPreparationCancellation()
    }
    private let queue = DispatchQueue(label: "local.traverse.editor-preparation", qos: .userInitiated)
    private let compute: Compute
    private var completion: Completion?
    private var active: Request?
    private var pendingSave: Request?
    private var pendingPresentation: Request?
    private var latestPresentation: UUID?
    private var closed = false
    private var drainers: [CheckedContinuation<Void, Never>] = []

    init(compute: @escaping Compute = EditorPreparationOwner.prepare,
         completion: @escaping Completion) {
        self.compute = compute; self.completion = completion
    }
    var activeCount: Int { active == nil ? 0 : 1 }
    var pendingCount: Int { (pendingSave == nil ? 0 : 1) + (pendingPresentation == nil ? 0 : 1) }
    var hasSave: Bool { pendingSave != nil || active?.input.isSave == true }
    var isDraining: Bool { active != nil || pendingCount != 0 }

    func submit(_ input: EditorPreparationInput) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        if input.isSave, hasSave { throw TextDocumentFailure.saveInProgress }
        if !input.isSave {
            latestPresentation = UUID(); pendingPresentation = nil
            if active?.input.isSave == false { active?.cancellation.cancel() }
        }
        // Admission avoids retaining an unbounded paste. Full validation and
        // encoding/token/index construction run only on the actual worker.
        guard input.text.utf8.count <= TextDocumentValue.maximumBytes else {
            completion?(input, .invalid(.tooLarge)); return
        }
        let request = Request(input: input)
        if input.isSave {
            pendingSave = request
            if active?.input.isSave == false { active?.cancellation.cancel() }
        } else {
            latestPresentation = request.id
            pendingPresentation = request
            if active?.input.isSave == false { active?.cancellation.cancel() }
        }
        startIfPossible()
    }

    func stopSave(_ captureID: UUID) {
        if active?.input.captureID == captureID { active?.cancellation.cancel() }
        if let pending = pendingSave, pending.input.captureID == captureID {
            pendingSave = nil
            completion?(pending.input, .cancelled)
        }
        finishDrainersIfIdle()
    }

    /// Awaiting the real worker is mandatory. Cancelling a Task or dismissing a
    /// window does not prove that it released the immutable text it owns.
    func closeAndDrain() async {
        closed = true; latestPresentation = nil; pendingPresentation = nil
        active?.cancellation.cancel()
        if let pending = pendingSave {
            pendingSave = nil; completion?(pending.input, .cancelled)
        }
        if active != nil {
            await withCheckedContinuation { drainers.append($0) }
        }
        completion = nil
    }

    nonisolated static func prepare(_ input: EditorPreparationInput,
                                    _ cancellation: EditorPreparationCancellation) -> EditorPreparationResult {
        guard !cancellation.isCancelled else { return .cancelled }
        let value: TextDocumentValue
        do { value = try .edited(input.text, format: input.format) }
        catch let failure as TextDocumentFailure { return .invalid(failure) }
        catch { return .invalid(.invalidReceipt) }
        guard !cancellation.isCancelled else { return .cancelled }
        switch input {
        case .save: return .save(value)
        case .copy: return .copy(value)
        case .presentation(_, _, _, _, let language, let detectsLanguage):
            let lines = EditorLineIndex(value.text)
            guard !cancellation.isCancelled else { return .cancelled }
            let detected = detectsLanguage && language == .plain
                ? TextSyntaxLanguage.detected(in: value.text, cancelled: { cancellation.isCancelled }) : nil
            guard !cancellation.isCancelled else { return .cancelled }
            let syntax = TextSyntax.color(value, language: detected ?? language, cancelled: { cancellation.isCancelled })
            return cancellation.isCancelled ? .cancelled : .presentation(value, syntax, lines, detectedLanguage: detected)
        }
    }

    private func startIfPossible() {
        guard !closed, active == nil else { return }
        let request: Request
        if let save = pendingSave { pendingSave = nil; request = save }
        else if let presentation = pendingPresentation { pendingPresentation = nil; request = presentation }
        else { finishDrainersIfIdle(); return }
        active = request
        let compute = compute
        queue.async { [self] in
            let result = compute(request.input, request.cancellation)
            DispatchQueue.main.async { [self] in finish(request, result: result) }
        }
    }

    private func finish(_ request: Request, result: EditorPreparationResult) {
        precondition(active?.id == request.id)
        active = nil
        if request.input.isSave {
            completion?(request.input, request.cancellation.isCancelled ? .cancelled : checked(result, for: request.input))
        } else if !closed, latestPresentation == request.id, !request.cancellation.isCancelled {
            completion?(request.input, checked(result, for: request.input))
        }
        startIfPossible()
        finishDrainersIfIdle()
    }

    private func checked(_ result: EditorPreparationResult, for input: EditorPreparationInput) -> EditorPreparationResult {
        switch result {
        case .save(let value):
            guard case .save = input, value.format == input.format else { return .invalid(.invalidReceipt) }
            return result
        case .copy(let value):
            guard case .copy = input, value.format == input.format else { return .invalid(.invalidReceipt) }
            return result
        case .presentation(let value, _, let lines, let detected):
            guard case .presentation(_, _, _, _, let requested, let allowsDetection) = input,
                  value.format == input.format, lines.matches(value.text),
                  detected == nil || allowsDetection && requested == .plain else { return .invalid(.invalidReceipt) }
            return result
        case .invalid, .cancelled: return result
        }
    }
    private func finishDrainersIfIdle() {
        guard active == nil, pendingCount == 0 else { return }
        let waiting = drainers; drainers = []
        for waiter in waiting { waiter.resume() }
    }
}
