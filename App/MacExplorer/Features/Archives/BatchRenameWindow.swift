import AppKit
import Combine
import ExplorerCore
import FileOperations
import SwiftUI

enum BatchRenameActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-batch-rename")
        #else
        enabled
        #endif
    }
}

@MainActor final class BatchRenameModel: ObservableObject {
    typealias Row = BatchRenamePreviewRow
    @Published var options = BatchRenameOptions() { didSet { rebuild() } }
    @Published var selection = Set<Int>()
    @Published private(set) var rows: [Row] = []
    @Published private(set) var notice = "Checking the selected items…"
    @Published private(set) var validation = ""
    @Published private(set) var isPreparing = true
    @Published private(set) var isRunning = false
    @Published private(set) var result: BatchRenameResult?
    @Published private(set) var undoResult: BatchRenameUndoResult?
    @Published private(set) var undoAttempted = false
    let settings: BrowserSettings
    let parent: URL
    let sources: [URL]
    let names: [BatchRenameName]
    private weak var browser: BrowserViewController?
    private let engine: RecoverableFileOperations
    private let coordinator: ApplicationOperationCoordinator
    private var preparation: UUID?
    private var observation: FileOperationSelection?
    private var lifetime: FileAccessLifetimes?
    private var task: Task<Void, Never>?
    private var coordinatorObservation: AnyCancellable?
    private var closed = false
    weak var window: NSWindow?
    var changes: Int { rows.filter(\.changed).count }
    var canApply: Bool {
        !closed && !isPreparing && !isRunning && result == nil && validation.isEmpty && changes > 0 && observation != nil
            && coordinator.activeOwner == nil && coordinator.preparationOwner == preparation
            && coordinator.transfers.canRunExclusiveCommand && !ApplicationFileActivity.gate.isClosed
    }
    var canUndo: Bool { !closed && !isRunning && !undoAttempted && !(result?.completedRecordIDs.isEmpty ?? true) && browser?.canRunExclusiveFileCommand == true }
    var selectedRecordID: UUID? {
        guard selection.count == 1, let index = selection.first, let result, result.units.indices.contains(index) else { return nil }
        return result.units[index].outcome.recordID
    }
    var canReview: Bool { !isRunning && selectedRecordID != nil && browser?.canRunExclusiveFileCommand == true }
    var rule: BatchRenameRule { options.rule }
    init(browser: BrowserViewController, engine: RecoverableFileOperations, sources: [URL], names: [BatchRenameName], preparation: UUID) {
        self.browser = browser; self.engine = engine; coordinator = browser.operationCoordinator; settings = browser.settings
        self.sources = sources; self.names = names; parent = sources[0].deletingLastPathComponent(); self.preparation = preparation
        coordinatorObservation = Publishers.Merge(coordinator.objectWillChange, coordinator.transfers.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
        rebuild()
    }
    func prepare() {
        task = Task { [self] in
            defer { task = nil; isPreparing = false; releasePreparation(); if closed { lifetime = nil } }
            guard let browser else { releasePreparation(); return }
            let access = await browser.accessLifetime(for: sources + [parent])
            do {
                let observed = try await engine.observeSelection(sources)
                guard !closed, !Task.isCancelled else { return }
                lifetime = access; observation = observed; notice = "Preview only. Nothing has been renamed."
            } catch { if !closed { notice = Self.message(error) }; releasePreparation() }
            withExtendedLifetime(access) {}
        }
    }
    private func rebuild() {
        guard result == nil else { return }
        do {
            rows = try options.preview(names)
            validation = ""
        } catch {
            rows = names.enumerated().map { Row(id: $0.offset, before: $0.element.name, after: "—", status: "Check rule", changed: false) }
            validation = Self.message(error)
        }
    }
    func apply() {
        guard canApply, let browser, !browser.isBrowserSuspended, browser.recoverableFileOperations === engine,
              let observation, browser.operationTask == nil,
              browser.startOperationPresentation("Renaming selected items…", preparation: preparation) else { return }
        self.preparation = nil; isRunning = true; notice = "Renaming reviewed items. Stop finishes the current safe step."
        let chosen = rule, expected = rows.map(\.after)
        let work = Task { [self, browser] in
            defer { task = nil; isRunning = false; browser.finishOperationPresentation(); if closed { lifetime = nil } }
            do {
                let plan = try await engine.prepareBatchRename(sources: sources, rule: chosen, observing: observation)
                guard !Task.isCancelled, !closed || browser.operationTask != nil,
                      zip(plan.items, expected).allSatisfy({ $0.0.newName.utf8.elementsEqual($0.1.utf8) }) else { throw CancellationError() }
                try await coordinator.prepareOperationState(for: engine)
                try Task.checkCancellation()
                let completed = await engine.performBatchRename(plan, progress: browser.operationProgressSink)
                result = completed
                rows = completed.units.enumerated().map { index, unit in
                    Row(id: index, before: unit.item.originalName, after: unit.item.newName,
                        status: Self.status(unit.outcome.result.items.first?.status, hasRecord: unit.outcome.recordID != nil), changed: !unit.item.isUnchanged)
                }
                notice = OperationResultDescription(result: completed.result).summary
                publish(completed.result, browser: browser)
            } catch {
                notice = error is CancellationError ? "Stopped before renaming. No file changes were made." : Self.message(error)
                // No file unit was admitted on this throwing path. Retain the
                // captured source identities for an explicit edited retry;
                // changed/replaced sources still require a new selection.
            }
        }
        task = work; browser.operationTask = work
    }
    func undoCompleted() {
        guard canUndo, let browser, let result, browser.recoverableFileOperations === engine,
              browser.startOperationPresentation("Undoing batch renames…") else { return }
        undoAttempted = true; isRunning = true; notice = "Undoing completed renames in reverse order…"
        let work = Task { [self, browser] in
            defer { task = nil; isRunning = false; browser.finishOperationPresentation(); if closed { lifetime = nil } }
            do {
                let restored = try await engine.undoBatchRename(result, progress: browser.operationProgressSink)
                undoResult = restored
                let statuses = Dictionary(restored.attempted.compactMap { outcome in outcome.recordID.map { ($0, outcome.result.disposition) } }, uniquingKeysWith: { _, last in last })
                rows = result.units.enumerated().map { index, unit in
                    let disposition = unit.outcome.recordID.flatMap { statuses[$0] }
                    return Row(id: index, before: unit.item.originalName, after: unit.item.newName,
                        status: disposition == .succeeded ? "Restored" : disposition != nil ? "Review Undo" : Self.status(unit.outcome.result.items.first?.status, hasRecord: unit.outcome.recordID != nil),
                        changed: !unit.item.isUnchanged)
                }
                notice = restored.result.disposition == .succeeded && restored.remainingRecordIDs.isEmpty
                    ? "Completed renames restored. Later file edits were preserved."
                    : "Undo stopped. Review the affected item in Operation Recovery before continuing."
                publish(restored.result, browser: browser)
            } catch { notice = Self.message(error) }
        }
        task = work; browser.operationTask = work
    }
    func stop() { guard isRunning else { return }; browser?.cancelFileOperation(nil) }
    func reviewSelected() { if let id = selectedRecordID { browser?.openOperationRecovery(recordID: id) } }
    func closeAndDrain() async {
        closed = true
        if !isRunning { task?.cancel() }
        if let task { await task.value }
        releasePreparation(); lifetime = nil; observation = nil
    }
    private func releasePreparation() { if let preparation { coordinator.finishPreparation(owner: preparation); self.preparation = nil } }
    private func publish(_ value: FileOperationResult, browser: BrowserViewController) {
        browser.lastOperationResult = value; browser.lastRecoveryAction = nil; browser.lastRecoveryRecordID = nil
        browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
        browser.status.stringValue = OperationResultDescription(result: value).summary
        browser.operationResultsButton.isHidden = false
        for current in coordinator.liveBrowsers where !current.isBrowserSuspended && current.location.directoryURL == parent { current.loadLocation() }
        browser.inspectOperationRecovery()
    }
    private static func status(_ status: FileOperationStatus?, hasRecord: Bool) -> String {
        switch status {
        case .succeeded: "Renamed"; case .skipped: "Unchanged"; case .notStarted: "Not started"; case .cancelled: "Stopped"
        case .failed(let reason): hasRecord ? "Needs review" : reason == .conflict ? "Name occupied" : "Failed"
        case .none: "Unavailable"
        }
    }
    static func message(_ error: Error) -> String {
        (error as? BatchRenameValidation)?.message ?? (error as? FileOperationFailure)?.userMessage ?? "The selected items could not be checked. Select them again to make a new preview."
    }
}

private struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "character.cursor.ibeam").interfaceFont(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rename Items").interfaceFont(.title2.weight(.semibold))
                    Text("\(model.sources.count) selected items · \(model.parent.lastPathComponent)").interfaceFont(.caption).foregroundStyle(.secondary).help(model.parent.path)
                }
                Spacer()
                if model.isPreparing || model.isRunning { ProgressView().controlSize(.small) }
            }.padding(18)
            Divider()
            BatchRenameRuleFields(options: $model.options, settings: model.settings)
                .padding(18).disabled(model.isPreparing || model.isRunning || model.result != nil)
            HStack {
                Text(model.validation.isEmpty ? model.notice : model.validation).interfaceFont(.callout).textSelection(.enabled)
                    .foregroundStyle(model.validation.isEmpty ? Color.secondary : Color.orange)
                Spacer()
            }.padding(.horizontal, 18).padding(.bottom, 12)
            BatchRenamePreviewTable(rows: model.rows, selection: $model.selection).frame(minHeight: 220)
            Divider()
            HStack {
                Text(model.result == nil ? "\(model.changes) changes · names are checked again before renaming" : "Each completed rename has its own recovery record")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.result == nil && !model.isRunning ? "Cancel" : "Close") { model.window?.performClose(nil) }.keyboardShortcut(.cancelAction)
                if model.isRunning { Button("Stop", action: model.stop) }
                else if model.result != nil {
                    Button("Review Selected…", action: model.reviewSelected).disabled(!model.canReview)
                    Button("Undo Completed", action: model.undoCompleted).disabled(!model.canUndo)
                } else { Button("Rename", action: model.apply).disabled(!model.canApply).keyboardShortcut(.defaultAction) }
            }.padding(18)
        }.frame(minWidth: 840, minHeight: 560)
    }
}

@MainActor final class BatchRenameWindowController: NSWindowController, NSWindowDelegate {
    let model: BatchRenameModel
    var onClose: (() -> Void)?
    init(model: BatchRenameModel) {
        self.model = model
        let window = ToolWindowChrome.makeWindow(title: "Rename Items", size: .init(width: 980, height: 640),
            minimumSize: .init(width: 860, height: 600), content: InterfaceHostingController(rootView: BatchRenameView(model: model)))
        super.init(window: window); window.delegate = self; model.window = window
        ToolWindowChrome.install(in: window, settings: model.settings)
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor final class ApplicationBatchRename {
    static let shared = ApplicationBatchRename()
    private(set) var controller: BatchRenameWindowController?
    private var retirement: Task<Void, Never>?
    func show(from browser: BrowserViewController) {
        guard retirement == nil, browser.canBatchRename, let engine = browser.recoverableFileOperations else { return }
        if let controller {
            if controller.model.isRunning { controller.window?.makeKeyAndOrderFront(nil); return }
            let selected = browser.orderedSelectedURLs, tab = browser.activeID, visit = browser.sessionID
            Task { [weak self, weak browser] in
                guard let self else { return }; await closeAndDrain()
                guard let browser, browser.activeID == tab, browser.sessionID == visit, browser.orderedSelectedURLs == selected else { return }
                show(from: browser)
            }
            return
        }
        let sources = browser.orderedSelectedURLs
        let names = sources.compactMap { url -> BatchRenameName? in
            guard let row = browser.rowsByURL[url], browser.displayedEntries.indices.contains(row) else { return nil }
            let entry = browser.displayedEntries[row]
            return .init(name: entry.name, isDirectory: entry.kind == .directory || entry.kind == .package)
        }
        guard names.count == sources.count else { return }
        let token = UUID(); guard browser.operationCoordinator.beginPreparation(owner: token) else { return }
        let model = BatchRenameModel(browser: browser, engine: engine, sources: sources, names: names, preparation: token)
        let created = BatchRenameWindowController(model: model)
        created.onClose = { [weak self, weak model] in
            guard let self, let model else { return }
            retirement = Task { [self] in await model.closeAndDrain(); controller = nil; retirement = nil }
        }
        controller = created
        if browser.isControlledVerification { created.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
        else if let window = created.window { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        created.showWindow(nil); created.window?.makeKeyAndOrderFront(nil); model.prepare()
    }
    func closeAndDrain() async { controller?.close(); if let retirement { await retirement.value } }
    func closeIdleWindow() { if controller?.model.isRunning == false { controller?.close() } }
}

@MainActor extension BrowserViewController {
    var canBatchRename: Bool {
        BatchRenameActivation.available && canModifyCurrentFolder && recoverableFileOperations != nil && (2...512).contains(orderedSelectedURLs.count)
            && orderedSelectedURLs.allSatisfy { url in
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
                return [.file, .directory, .package].contains(displayedEntries[row].kind)
            }
    }
    @objc func batchRenameSelection(_ sender: Any?) { ApplicationBatchRename.shared.show(from: self) }
}
