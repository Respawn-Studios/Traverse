import Foundation
#if canImport(FileOperations)
import FileOperations
#endif

// These opaque UI bindings/tickets confer no filesystem or journal authority.
// A future integration must accept only actual engine outcomes after drain.
struct TextDocumentBinding: Equatable, Sendable { let id = UUID() }
struct TextEditTicket: Equatable, Sendable {
    fileprivate let owner: UUID
    fileprivate let generation: UUID
}
/// Captures the visible edit generation before off-main Save serialization.
/// This reserves UI intent only; it confers no filesystem authority.
struct TextSaveCapture: Sendable {
    let id: UUID
    let format: TextDocumentFormat
    let sourceBinding: TextDocumentBinding?
    let intent: TextSaveSnapshot.Intent
    let checkpointsUnchangedOriginal: Bool
    fileprivate let owner: UUID
    fileprivate let generation: UUID
}
struct TextSaveSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Intent: Equatable, Sendable { case original, freshCopy(TextDocumentBinding) }
    let id: UUID
    let value: TextDocumentValue
    let sourceBinding: TextDocumentBinding?
    let intent: Intent
    let checkpointsUnchangedOriginal: Bool
    fileprivate let owner: UUID
    fileprivate let generation: UUID
    var description: String { "<text save snapshot>" }
    var debugDescription: String { description }
}
enum TextSaveResult: Sendable {
    case confirmed(TextDocumentBinding)
    case failed
    case cancelledBeforeMutation
    case uncertain
}
enum TextSaveReconciliation: Sendable {
    case confirmed(TextDocumentBinding)
    case notPerformed
    case stillUncertain
}

@MainActor
final class TextDocumentState {
    enum CloseDisposition: Equatable, Sendable {
        case ready, needsSaveDecision, waitingForSave, needsRecoveryDecision, closed
    }
    private let owner = UUID()
    private var generation = UUID()
    private var savedValue: TextDocumentValue
    private var savedGeneration = UUID()
    private(set) var value: TextDocumentValue
    private(set) var binding: TextDocumentBinding?
    private var pendingEdit: TextEditTicket?
    private(set) var validationFailure: TextDocumentFailure?
    private(set) var activeSave: TextSaveSnapshot?
    private(set) var activeCapture: TextSaveCapture?
    private(set) var unresolvedSave: TextSaveSnapshot?
    private(set) var stopRequested = false
    private var dirty = false
    private var closed = false

    init(value: TextDocumentValue, binding: TextDocumentBinding?) {
        self.value = value; savedValue = value; self.binding = binding
        dirty = binding == nil && !value.text.isEmpty
    }
    var isDirty: Bool { dirty || pendingEdit != nil || validationFailure != nil }
    var canSaveValidatedText: Bool { !closed && pendingEdit == nil && validationFailure == nil && activeSave == nil && activeCapture == nil && unresolvedSave == nil }
    var currentValidatedValue: TextDocumentValue? { !closed && pendingEdit == nil && validationFailure == nil ? value : nil }
    var currentGeneration: UUID { generation }
    /// Display-only baseline: the last successful Open/Reload or confirmed Save,
    /// never an assertion about a possibly changed current file or server.
    var comparisonBaseline: String? { closed ? nil : savedValue.text }
    var savedTextBaseline: EditorSavedTextBaseline? { comparisonBaseline.map { .init(id: savedGeneration, text: $0) } }
    var closeDisposition: CloseDisposition {
        if closed { return .closed }
        if activeSave != nil || activeCapture != nil { return .waitingForSave }
        if unresolvedSave != nil { return .needsRecoveryDecision }
        return isDirty ? .needsSaveDecision : .ready
    }

    func beginEdit() throws -> TextEditTicket {
        guard !closed else { throw TextDocumentFailure.closed }
        generation = UUID(); let ticket = TextEditTicket(owner: owner, generation: generation)
        pendingEdit = ticket; validationFailure = nil; dirty = true
        return ticket
    }
    func acceptEdit(_ ticket: TextEditTicket, value: TextDocumentValue) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard ticket.owner == owner, ticket == pendingEdit, ticket.generation == generation else { throw TextDocumentFailure.staleEdit }
        // Format belongs to the opened document until an explicit future
        // encoding choice is qualified. Validation cannot silently convert it.
        guard value.format == self.value.format else { throw TextDocumentFailure.invalidReceipt }
        self.value = value; pendingEdit = nil; validationFailure = nil
        dirty = activeSave != nil || activeCapture != nil || unresolvedSave != nil || differsFromSaved
    }
    func rejectEdit(_ ticket: TextEditTicket, failure: TextDocumentFailure) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard ticket.owner == owner, ticket == pendingEdit, ticket.generation == generation else { throw TextDocumentFailure.staleEdit }
        pendingEdit = nil; validationFailure = failure; dirty = true
    }

    func beginSave(as intent: TextSaveSnapshot.Intent = .original) throws -> TextSaveSnapshot? {
        guard !closed else { throw TextDocumentFailure.closed }
        guard pendingEdit == nil, validationFailure == nil else { throw TextDocumentFailure.validationPending }
        guard activeSave == nil, activeCapture == nil else { throw TextDocumentFailure.saveInProgress }
        guard unresolvedSave == nil else { throw TextDocumentFailure.reviewRequired }
        if intent == .original {
            guard binding != nil else { throw TextDocumentFailure.needsDestination }
            if value.encoded == savedValue.encoded { dirty = false; return nil }
        }
        if case .freshCopy(let target) = intent, target == binding { throw TextDocumentFailure.invalidReceipt }
        let snapshot = TextSaveSnapshot(id: UUID(), value: value, sourceBinding: binding,
            intent: intent, checkpointsUnchangedOriginal: false, owner: owner, generation: generation)
        activeSave = snapshot; stopRequested = false
        return snapshot
    }
    func captureSave(as intent: TextSaveSnapshot.Intent = .original,
                     checkpointUnchangedOriginal: Bool = false) throws -> TextSaveCapture {
        guard !closed else { throw TextDocumentFailure.closed }
        guard activeSave == nil, activeCapture == nil else { throw TextDocumentFailure.saveInProgress }
        guard unresolvedSave == nil else { throw TextDocumentFailure.reviewRequired }
        if intent == .original, binding == nil { throw TextDocumentFailure.needsDestination }
        if case .freshCopy(let target) = intent, target == binding { throw TextDocumentFailure.invalidReceipt }
        guard !checkpointUnchangedOriginal || intent == .original else { throw TextDocumentFailure.invalidReceipt }
        let capture = TextSaveCapture(id: UUID(), format: value.format, sourceBinding: binding,
            intent: intent, checkpointsUnchangedOriginal: checkpointUnchangedOriginal,
            owner: owner, generation: generation)
        activeCapture = capture; stopRequested = false
        return capture
    }
    /// The caller supplies the immutable raw buffer captured with this intent;
    /// background validation may finish after newer native edits. Never replace
    /// those edits or wait for a quiet typing interval to fulfill Command-S.
    func finishCapture(_ capture: TextSaveCapture, prepared: Result<TextDocumentValue, TextDocumentFailure>) throws -> TextSaveSnapshot? {
        try validateCapture(capture)
        if case .success(let value) = prepared, value.format != capture.format { throw TextDocumentFailure.invalidReceipt }
        activeCapture = nil
        let stopped = stopRequested; stopRequested = false
        if stopped { dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved; return nil }
        switch prepared {
        case .failure(let failure):
            if generation == capture.generation {
                pendingEdit = nil; validationFailure = failure; dirty = true
            }
            dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved
            return nil
        case .success(let capturedValue):
            if generation == capture.generation {
                value = capturedValue; pendingEdit = nil; validationFailure = nil
            }
            if capture.intent == .original, !capture.checkpointsUnchangedOriginal,
               capturedValue.encoded == savedValue.encoded {
                dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved
                return nil
            }
            let snapshot = TextSaveSnapshot(id: capture.id, value: capturedValue,
                sourceBinding: capture.sourceBinding, intent: capture.intent,
                checkpointsUnchangedOriginal: capture.checkpointsUnchangedOriginal,
                owner: owner, generation: capture.generation)
            activeSave = snapshot; dirty = true
            return snapshot
        }
    }
    func requestStop(for capture: TextSaveCapture) throws { try validateCapture(capture); stopRequested = true }
    /// Called only after the preparation owner reports that the captured
    /// computation really returned. Cancellation is not a text-validation error.
    func finishCancelledCapture(_ capture: TextSaveCapture) throws {
        try validateCapture(capture)
        activeCapture = nil; stopRequested = false
        dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved
    }
    func requestStop(for snapshot: TextSaveSnapshot) throws {
        try validateActive(snapshot); stopRequested = true
        // Actual operation ownership and close/save availability remain held.
    }
    func finishSave(_ snapshot: TextSaveSnapshot, result: TextSaveResult) throws {
        try validateActive(snapshot)
        activeSave = nil; stopRequested = false
        switch result {
        case .confirmed(let freshBinding): acknowledge(snapshot, binding: freshBinding)
        case .uncertain: unresolvedSave = snapshot; dirty = true
        case .failed, .cancelledBeforeMutation:
            dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved
        }
    }
    func reconcile(_ snapshot: TextSaveSnapshot, result: TextSaveReconciliation) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard snapshot.owner == owner, unresolvedSave?.id == snapshot.id,
              activeSave == nil, activeCapture == nil, snapshot.sourceBinding == binding else { throw TextDocumentFailure.invalidReceipt }
        switch result {
        case .confirmed(let freshBinding): unresolvedSave = nil; acknowledge(snapshot, binding: freshBinding)
        case .notPerformed:
            unresolvedSave = nil
            dirty = pendingEdit != nil || validationFailure != nil || differsFromSaved
        case .stillUncertain: break
        }
    }
    func discardAndClose() throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard activeSave == nil, activeCapture == nil else { throw TextDocumentFailure.saveInProgress }
        value = savedValue; pendingEdit = nil; validationFailure = nil; dirty = false; closed = true
        // Keep unresolvedSave as an outcome correlation. No recovery cleanup,
        // file change or authority follows from discarding this memory buffer.
    }
    func acceptsStyling(for generation: UUID) -> Bool {
        !closed && pendingEdit == nil && validationFailure == nil && self.generation == generation
    }

    private func validateActive(_ snapshot: TextSaveSnapshot) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard snapshot.owner == owner, activeSave?.id == snapshot.id,
              snapshot.sourceBinding == binding else { throw TextDocumentFailure.invalidReceipt }
    }
    private func validateCapture(_ capture: TextSaveCapture) throws {
        guard !closed else { throw TextDocumentFailure.closed }
        guard capture.owner == owner, activeCapture?.id == capture.id,
              capture.sourceBinding == binding else { throw TextDocumentFailure.invalidReceipt }
    }
    private var differsFromSaved: Bool {
        binding == nil && !value.text.isEmpty || value.encoded != savedValue.encoded
    }
    private func acknowledge(_ snapshot: TextSaveSnapshot, binding: TextDocumentBinding) {
        savedValue = snapshot.value; savedGeneration = UUID(); self.binding = binding
        // Acknowledgement of g must not clear newer (even pending) edits.
        dirty = snapshot.generation != generation || pendingEdit != nil || validationFailure != nil
    }
}
