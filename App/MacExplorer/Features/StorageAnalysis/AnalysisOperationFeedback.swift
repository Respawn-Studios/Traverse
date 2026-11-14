import AppKit
import Combine
import FileOperations
import SwiftUI

/// One exact completed operation, never the browser's changing "last result".
@MainActor
final class AnalysisOperationFeedback: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var message: String
    @Published private(set) var canUndo = false
    @Published private(set) var canViewResults = false
    @Published private(set) var working = false
    private weak var browser: BrowserViewController?
    private let engine: RecoverableFileOperations
    private let roots: [URL]
    private let scopeIsCurrent: @MainActor () -> Bool
    private let undoConfirmed: @MainActor (UUID) -> Void
    private var undoEligible: Bool
    private var closed = false
    private var observation: AnyCancellable?

    init?(browser: BrowserViewController, engine: RecoverableFileOperations, outcome: RecoverableOperationResult,
          scopeIsCurrent: @escaping @MainActor () -> Bool,
          undoConfirmed: @escaping @MainActor (UUID) -> Void) {
        guard let id = outcome.recordID else { return nil }
        self.id = id; self.browser = browser; self.engine = engine; self.scopeIsCurrent = scopeIsCurrent
        self.undoConfirmed = undoConfirmed
        undoEligible = outcome.result.disposition == .succeeded
        message = undoEligible ? "Moved to Trash · list updated" : "Needs attention · review this operation’s recorded locations"
        roots = Array(Set(outcome.result.items.flatMap { [$0.source, $0.destination].compactMap { $0 } + $0.recoveryURLs }))
        let c = browser.operationCoordinator
        observation = Publishers.Merge3(c.objectWillChange, c.transfers.objectWillChange, c.drives.objectWillChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAvailability() }
        }
        updateAvailability()
    }
    func close() { closed = true; observation = nil; canUndo = false; canViewResults = false }
    private func updateAvailability() {
        let allowed: Bool
        var historyAllowsUndo = false
        if let browser, !closed, scopeIsCurrent(), !browser.isBrowserSuspended,
           !browser.isReadOnlyFileSession, browser.recoverableFileOperations === engine, browser.view.window != nil {
            let c = browser.operationCoordinator
            let record = browser.recoveryRecords.first { $0.id == id }
            historyAllowsUndo = record.map { $0.canUndo && NativeLocalProtectionPolicy.permitsTrashRecovery($0) } ?? false
            if record?.state == "undone", undoEligible, !working {
                undoEligible = false; message = "Undo completed · item restored in the list"
                undoConfirmed(id)
            }
            allowed = c.activeOwner == nil && c.preparationOwner == nil && c.copyPreviewOwner == nil
                && c.inspectionCount == 0 && c.volumeBarrierOwner == nil && !c.drives.isBusy && c.transfers.isIdleForCopyPreview
                && browser.view.window?.attachedSheet == nil
        } else { allowed = false }
        let undo = allowed && undoEligible && historyAllowsUndo && !working, results = allowed && !working
        if canUndo != undo { canUndo = undo }; if canViewResults != results { canViewResults = results }
    }
    func undo() {
        updateAvailability()
        guard canUndo, let browser else { return }
        working = true; updateAvailability()
        let began = browser.beginAnalysisUndo(recordID: id, engine: engine, roots: roots) { [weak self] outcome in
            guard let self, !self.closed else { return }
            self.working = false; self.undoEligible = false
            self.message = outcome.result.disposition == .succeeded
                ? "Undo completed · item restored in the list"
                : "Undo needs attention · review this operation’s recorded locations"
            if outcome.result.disposition == .succeeded { self.undoConfirmed(self.id) }
            self.updateAvailability()
        }
        if !began { working = false; message = "Wait for the current work to finish, then try again."; updateAvailability() }
    }
    func viewResults() {
        updateAvailability()
        guard canViewResults, let browser else { return }
        browser.openOperationRecovery(recordID: id)
    }
}

struct AnalysisOperationFeedbackView: View {
    @ObservedObject var model: AnalysisOperationFeedback
    var body: some View {
        HStack(spacing: 10) {
            if model.working { ProgressView().controlSize(.small) }
            Text(model.message).interfaceFont(.caption).lineLimit(2)
            Spacer(minLength: 4)
            Button("Undo") { model.undo() }.disabled(!model.canUndo)
            Button("View Results") { model.viewResults() }.disabled(!model.canViewResults)
        }.controlSize(.small).padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor extension BrowserViewController {
    /// Explicit analyzer button uses normal writer/progress/recovery ownership;
    /// the engine revalidates this exact record, not a reconstructed selection.
    @discardableResult
    func beginAnalysisUndo(recordID: UUID, engine: RecoverableFileOperations, roots: [URL],
        completion: @escaping @MainActor (RecoverableOperationResult) -> Void) -> Bool {
        guard let record = recoveryRecords.first(where: { $0.id == recordID }), record.canUndo,
              NativeLocalProtectionPolicy.permitsTrashRecovery(record),
              !isBrowserSuspended, !isReadOnlyFileSession, operationTask == nil,
              recoverableFileOperations === engine, view.window != nil, view.window?.attachedSheet == nil,
              operationCoordinator.transfers.isIdleForCopyPreview,
              startOperationPresentation("Undoing selected Trash…") else { return false }
        let tab = activeID, visit = sessionID
        operationTask = Task { [self] in
            let access = await accessLifetime(for: roots)
            defer { withExtendedLifetime(access) {} }
            let outcome = await engine.undo(recordID: recordID, progress: operationProgressSink)
            completeRecoverablePresentation(outcome, initiatingTab: tab, visit: visit)
            completion(outcome)
        }
        return true
    }
}
