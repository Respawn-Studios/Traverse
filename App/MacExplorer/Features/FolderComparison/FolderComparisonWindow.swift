import AppKit
import Combine
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

@MainActor final class FolderComparisonSession: ObservableObject {
    typealias Side = FolderComparisonFailure.Side
    enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case left = "Only on left"
        case right = "Only on right"
        case changed = "Different on both sides"
        case unchecked = "Contents unchecked"
        case skipped = "Skipped"

        func includes(_ row: FolderComparisonReport.Row) -> Bool {
            switch self {
            case .all: true
            case .left: row.difference == .onlyOnLeft
            case .right: row.difference == .onlyOnRight
            case .changed: [.differentKind, .differentSize, .differentModificationTime, .differentContents].contains(row.difference)
            case .unchecked: row.contents == .unchecked
            case .skipped: row.difference == .notCompared
            }
        }
    }
    enum State {
        case ready, reading(previous: FolderComparisonReport?), stopping(previous: FolderComparisonReport?), stopped
        case result(FolderComparisonReport)
        case failed(String)
    }

    let left: URL
    let right: URL
    @Published private(set) var includingHidden: Bool
    @Published private(set) var state: State = .ready
    @Published var selectedRows = Set<Int>() {
        didSet { if selectedRows != oldValue { editorPreparation?.cancel() } }
    }
    @Published private(set) var notice: String?
    @Published private(set) var isCopying = false
    @Published private(set) var filter = Filter.all
    @Published private(set) var pathFilterID: UUID?
    @Published private(set) var pathQuery = ""
    @Published private(set) var isFiltering = false
    @Published private(set) var isPreparingEditor = false
    @Published private var filteredRows: [FolderComparisonReport.Row]?
    private let read: @MainActor (Bool, Bool) async throws -> FolderComparisonReport
    private let transfers: ApplicationTransferQueue
    private let submitCopy: @MainActor (FolderComparisonReport.MissingFileCopy) async throws -> UUID
    private let prepareEditor: @MainActor (FolderComparisonReport.EditorSelection, Side) async throws -> LocalTextOpenSelection
    private var task: Task<Void, Never>?
    private var copyPreparation: Task<Void, Never>?
    private var editorPreparation: Task<Void, Never>?
    private var copyJob: UUID?
    private var queueObservation: AnyCancellable?
    private let pathFilter = ReviewRowFilter<FolderComparisonReport.Row>()
    private var visibleRowIDs: Set<Int>?
    private var closed = false

    init(left: URL, right: URL, includingHidden: Bool,
         transfers: ApplicationTransferQueue,
         read: @escaping @MainActor (Bool, Bool) async throws -> FolderComparisonReport,
         submitCopy: @escaping @MainActor (FolderComparisonReport.MissingFileCopy) async throws -> UUID,
         prepareEditor: @escaping @MainActor (FolderComparisonReport.EditorSelection, Side) async throws -> LocalTextOpenSelection) {
        self.left = left
        self.right = right
        self.includingHidden = includingHidden
        self.transfers = transfers
        self.read = read
        self.submitCopy = submitCopy
        self.prepareEditor = prepareEditor
        queueObservation = transfers.$revision.sink { [weak self] _ in self?.updateCopyStatus() }
    }

    var isReading: Bool { task != nil }
    var canStop: Bool { task?.isCancelled == false }
    static let otherPairBusyMessage = "Finish or stop this comparison, then try the other pair again."
    func reportOtherPairBusy() { notice = Self.otherPairBusyMessage }
    var displayedReport: FolderComparisonReport? {
        switch state {
        case .result(let report): report
        case .reading(let previous), .stopping(let previous): previous
        default: nil
        }
    }
    var canCheckContents: Bool {
        guard !isReading, !isCopying, case .result = state else { return false }
        return true
    }
    var visibleRows: [FolderComparisonReport.Row] { filteredRows ?? displayedReport?.rows ?? [] }
    var canFilterPaths: Bool { !closed && displayedReport?.rows.isEmpty == false }
    private var hasVisibleSelection: Bool {
        !isFiltering && (visibleRowIDs.map { selectedRows.isSubset(of: $0) } ?? true)
    }
    var selectedText: FolderComparisonReport.TextSelection? {
        guard hasVisibleSelection, case .result(let report) = state,
              selectedRows.count == 1, let selectedRow = selectedRows.first else { return nil }
        return report.textSelection(for: selectedRow)
    }

    func editorSelection(on side: Side) -> FolderComparisonReport.EditorSelection? {
        guard !closed, !isCopying, !isPreparingEditor, hasVisibleSelection, case .result(let report) = state,
              selectedRows.count == 1, let selectedRow = selectedRows.first else { return nil }
        return report.editorSelection(for: selectedRow, on: side)
    }

    func openEditor(on side: Side, deliver: @escaping @MainActor (LocalTextOpenSelection) -> Void) {
        guard let selection = editorSelection(on: side) else { return }
        isPreparingEditor = true
        let inProgress = "Checking the selected file…"
        notice = inProgress
        editorPreparation = Task { [weak self, prepareEditor] in
            defer {
                self?.editorPreparation = nil
                self?.isPreparingEditor = false
                if self?.notice == inProgress { self?.notice = nil }
            }
            do {
                let checked = try await prepareEditor(selection, side)
                try Task.checkCancellation()
                guard let self, !closed, !isCopying, hasVisibleSelection, case .result = state else { return }
                deliver(checked)
            } catch {
                guard let self, !closed, !Task.isCancelled else { return }
                if let failure = error as? TextComparisonReadFailure {
                    notice = failure == .changed
                        ? "The selected file changed. Refresh the comparison before opening it."
                        : failure.userMessage
                } else { notice = Self.message(for: error) }
            }
        }
    }

    func reportEditor(_ message: String) { if !closed { notice = message } }

    var canFindAcrossDiffs: Bool {
        guard !isFiltering, case .result(let report) = state else { return false }
        return visibleRows.contains { report.textSelection(for: $0.id) != nil }
    }

    func textSelections(startingSearch: Bool) -> TextReview? {
        guard !isFiltering, case .result(let report) = state else { return nil }
        let visible = visibleRows
        let sources = visible.compactMap { row in report.textSelection(for: row.id).map { (row.id, $0) } }
        let selection = selectedRows.count == 1 ? selectedRows.first : nil
        let initial = sources.firstIndex { $0.0 == selection } ?? (startingSearch && !sources.isEmpty ? 0 : nil)
        guard let initial else { return nil }
        return .init(sources: sources.map(\.1), index: initial, excluded: visible.count - sources.count, searching: startingSearch)
    }

    struct TextReview {
        let sources: [FolderComparisonReport.TextSelection]
        let index: Int
        let excluded: Int
        let searching: Bool
    }

    var selectedCopy: FolderComparisonReport.MissingFileCopy? {
        guard !isCopying, hasVisibleSelection, case .result(let report) = state else { return nil }
        return report.missingFileCopy(for: selectedRows)
    }

    var copyTitle: String {
        guard let copy = selectedCopy else { return "Copy Missing Files" }
        let side = copy.destinationSide == .left ? "Left" : "Right"
        return copy.sources.count == 1 ? "Copy to \(side)" : "Copy \(copy.sources.count) to \(side)"
    }

    func showPathFilter() { if canFilterPaths { pathFilterID = UUID() } }

    func hidePathFilter() {
        pathFilterID = nil
        setPathQuery("")
    }

    func setPathQuery(_ text: String) {
        let query = String(text.unicodeScalars.prefix(256))
        guard pathQuery != query else { return }
        pathQuery = query
        applyPathFilter()
    }

    func setFilter(_ value: Filter) {
        guard value != filter else { return }
        selectedRows = []
        filter = value
        applyPathFilter()
    }

    func moveFilteredSelection(by offset: Int) {
        let rows = visibleRows
        guard !isFiltering, !isReading, !rows.isEmpty else { return }
        let current = selectedRows.count == 1 ? selectedRows.first : nil
        let index = rows.firstIndex { $0.id == current } ?? (offset > 0 ? -1 : rows.count)
        selectedRows = [rows[min(rows.count - 1, max(0, index + offset))].id]
    }

    private func applyPathFilter(keepingRows: Bool = true) {
        editorPreparation?.cancel()
        pathFilter.cancel()
        let term = pathQuery.trimmingCharacters(in: .whitespacesAndNewlines), category = filter
        guard !closed, let report = displayedReport, !term.isEmpty || category != .all else {
            filteredRows = nil; visibleRowIDs = nil; isFiltering = false
            return
        }
        if !keepingRows { filteredRows = nil; visibleRowIDs = nil }
        isFiltering = true
        pathFilter.replace(report.rows, matches: { row in
            category.includes(row) && (term.isEmpty || row.relativePath.localizedStandardContains(term))
        }) { [weak self] rows in
            guard let self, !closed else { return }
            let visible = Set(rows.lazy.map(\.id))
            selectedRows.formIntersection(visible)
            visibleRowIDs = visible
            filteredRows = rows
            isFiltering = false
        }
    }

    func setHidden(_ value: Bool) {
        guard !closed, !isReading, !isCopying, includingHidden != value else { return }
        includingHidden = value
        refresh()
    }

    func refresh(checkingContents: Bool = false) {
        guard !closed, !isReading, !isCopying else { return }
        if checkingContents && !canCheckContents { return }
        editorPreparation?.cancel()
        let previous = checkingContents ? displayedReport : nil
        if checkingContents { notice = nil }
        if previous == nil { selectedRows = [] }
        state = .reading(previous: previous)
        if previous == nil { applyPathFilter(keepingRows: false) }
        task = Task { [weak self, read, includingHidden] in
            let next: State
            do {
                let report = try await read(includingHidden, checkingContents)
                try Task.checkCancellation()
                next = .result(report)
            } catch is CancellationError {
                next = .stopped
            } catch {
                next = Task.isCancelled ? .stopped : .failed(Self.message(for: error))
            }
            guard let self, !closed else { return }
            task = nil
            if notice == Self.otherPairBusyMessage {
                notice = "This comparison finished. Choose Compare again for the other pair."
            }
            switch next {
            case .result(let report):
                if let previous { retainSelectedPaths(from: previous, in: report) }
                state = next
                applyPathFilter(keepingRows: false)
            case .stopped:
                guard let previous else {
                    state = next
                    return
                }
                state = .result(previous)
                notice = "Content check stopped. Showing the earlier comparison."
            default:
                selectedRows = []
                state = next
            }
        }
    }

    func stop() {
        guard let task, !task.isCancelled else { return }
        state = .stopping(previous: displayedReport)
        task.cancel()
    }

    private func retainSelectedPaths(from previous: FolderComparisonReport, in current: FolderComparisonReport) {
        guard !selectedRows.isEmpty else { return }
        let paths = Set(selectedRows.compactMap { id -> Data? in
            guard previous.rows.indices.contains(id), previous.rows[id].id == id,
                  previous.rows[id].omission == nil else { return nil }
            return Data(previous.rows[id].relativePath.utf8)
        })
        selectedRows = paths.isEmpty ? [] : Set(current.rows.lazy.filter { row in
            row.omission == nil && paths.contains(Data(row.relativePath.utf8))
        }.map(\.id))
    }

    func copySelectedFiles() {
        guard let selection = selectedCopy else { return }
        copyReviewedFiles(selection)
    }

    func copyReviewedFiles(_ selection: FolderComparisonReport.MissingFileCopy) {
        guard !closed, !isReading, !isCopying else { return }
        editorPreparation?.cancel()
        isCopying = true
        notice = "Preparing copy…"
        copyPreparation = Task { [weak self, submitCopy] in
            defer { self?.copyPreparation = nil }
            do {
                let job = try await submitCopy(selection)
                guard let self, !closed else { return }
                copyJob = job
                updateCopyStatus()
            } catch {
                guard let self, !closed else { return }
                isCopying = false
                notice = error is CancellationError ? "Copy canceled." : Self.message(for: error)
            }
        }
    }

    func stopCopy() {
        if let job = copyJob {
            if transfers.cancelWaiting(job) || transfers.stopActive(expectedID: job) { updateCopyStatus() }
        } else {
            copyPreparation?.cancel()
        }
    }

    private func updateCopyStatus() {
        guard !closed, let job = copyJob else { return }
        if let result = transfers.results.first(where: { $0.id == job }) {
            copyJob = nil
            isCopying = false
            let outcome = result.outcome
            if outcome.result.disposition == .succeeded, outcome.recordID != nil {
                notice = "Copy complete. Undo is available."
                refresh()
            } else if outcome.result.disposition == .partial {
                notice = OperationResultDescription(result: outcome.result).summary
                    + " See Transfer Queue for each result."
                refresh()
            } else {
                let failure = outcome.result.items.lazy.compactMap { item -> FileOperationFailure? in
                    if case .failed(let reason) = item.status { return reason }
                    return nil
                }.first
                notice = failure.map(Self.copyFailureMessage) ?? OperationResultDescription(result: outcome.result).summary
            }
        } else {
            let queue = transfers.state
            let status: String
            if let active = queue.active, active.id == job {
                status = active.stopRequested ? "Stopping copy…" : "Copying…"
            } else if queue.waiting.contains(where: { $0.id == job }) {
                status = queue.isPaused ? "Copy queued. Resume in Transfer Queue." : "Copy added to Transfer Queue."
            } else {
                copyJob = nil
                isCopying = false
                status = "Copy canceled."
            }
            if notice != status { notice = status }
        }
    }

    func close() {
        closed = true
        task?.cancel()
        task = nil
        copyPreparation?.cancel()
        editorPreparation?.cancel()
        queueObservation?.cancel()
        pathFilter.cancel()
        selectedRows = []
        notice = nil
        state = .ready
        filteredRows = nil; visibleRowIDs = nil; pathFilterID = nil; pathQuery = ""; isFiltering = false
    }

    private static func copyFailureMessage(_ failure: FileOperationFailure) -> String {
        switch failure {
        case .sourceChanged, .destinationChanged: "A selected file or its folder changed. Refresh the comparison to try again."
        default: failure.userMessage
        }
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? FolderComparisonFailure {
            switch failure {
            case .unavailable(.left): return "The left folder could not be read. Check its location and access, then refresh."
            case .unavailable(.right): return "The right folder could not be read. Check its location and access, then refresh."
            case .unsupported(.left): return "The left folder is outside the supported local locations."
            case .unsupported(.right): return "The right folder is outside the supported local locations."
            case .sameFolder: return "Both locations point to the same folder. Choose two different folders."
            case .changed: return "A folder or its access changed during comparison. Refresh once both folders are ready."
            case .limitExceeded: return "These folders exceed the comparison limit. Compare smaller folders within them."
            }
        }
        if let failure = error as? LocalStorageError { return failure.userMessage }
        if let failure = error as? FileOperationFailure { return copyFailureMessage(failure) }
        if error is FileActivityError { return "File access is paused. Try again after the current disk operation." }
        return "The folder comparison could not finish. Refresh to try again."
    }
}

@MainActor final class FolderComparisonWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: FolderComparisonSession
    private let onOpenText: (FolderComparisonSession.TextReview, NSWindow) -> Void
    private let onOpenEditor: (LocalTextOpenSelection, FolderComparisonSession.Side, NSWindow) -> Void
    var didClose: (() -> Void)?

    init(session: FolderComparisonSession, parent: NSWindow, settings: BrowserSettings,
         onOpenText: @escaping (FolderComparisonSession.TextReview, NSWindow) -> Void,
         onOpenEditor: @escaping (LocalTextOpenSelection, FolderComparisonSession.Side, NSWindow) -> Void) {
        self.session = session
        self.onOpenText = onOpenText
        self.onOpenEditor = onOpenEditor
        let viewport = ToolWindowChrome.initialViewport(size: .init(width: 920, height: 600),
            minimum: .init(width: 620, height: 400), scale: settings.interfaceSize.scale, screen: parent.screen)
        let native = ToolWindowChrome.makeWindow(title: "Compare Folders — Traverse", size: viewport.size, minimumSize: viewport.minimum)
        super.init(window: native)
        native.contentViewController = InterfaceHostingController(rootView: FolderComparisonContent(session: session,
            openText: { [weak self] in self?.openText(nil) }, findDiffs: { [weak self] in self?.findDiffs(nil) },
            openEditor: { [weak self] side in self?.openEditor(on: side) },
            reviewCopy: { [weak self] in self?.reviewCopy(nil) }))
        native.delegate = self
        ToolWindowChrome.install(in: native, settings: settings,
            initialContentSize: viewport.size, minimumContentSize: viewport.minimum)
        ToolWindowChrome.position(native, relativeTo: parent)
    }

    required init?(coder: NSCoder) { nil }

    func present() { window?.makeKeyAndOrderFront(nil) }

    func windowWillClose(_ notification: Notification) {
        session.close()
        ToolWindowMenuOwnership.release(self)
        didClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = ToolWindowMenuOwnership.claim(self) { base in
            ToolWindowMenuOwnership.reviewMenu(from: base, window: window, actions: [
                BrowserMenus.item("Open Text Diff", #selector(openText(_:)), key: "\r", modifiers: [], target: self),
                BrowserMenus.item("Open Left File in Editor", #selector(openLeftEditor(_:)), target: self),
                BrowserMenus.item("Open Right File in Editor", #selector(openRightEditor(_:)), target: self),
                BrowserMenus.item("Copy Missing Files", #selector(copyFiles(_:)), target: self),
                BrowserMenus.item("Review Copy…", #selector(reviewCopy(_:)), target: self),
                BrowserMenus.item("Check Contents", #selector(checkContents(_:)), target: self),
                BrowserMenus.item("Refresh", #selector(refresh(_:)), key: "r", target: self)
            ], viewActions: [
                BrowserMenus.item("Filter Paths…", #selector(findPaths(_:)), key: "f", target: self),
                BrowserMenus.item("Find Across Diffs…", #selector(findDiffs(_:)), key: "F", target: self)
            ])
        }
    }

    func windowDidResignKey(_ notification: Notification) { ToolWindowMenuOwnership.release(self) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openText(_:)): return window?.isKeyWindow == true && session.selectedText != nil
        case #selector(openLeftEditor(_:)), #selector(openRightEditor(_:)):
            let side: FolderComparisonSession.Side = item.action == #selector(openLeftEditor(_:)) ? .left : .right
            return window?.isKeyWindow == true && window?.attachedSheet == nil && session.editorSelection(on: side) != nil
        case #selector(copyFiles(_:)):
            item.title = session.copyTitle
            fallthrough
        case #selector(reviewCopy(_:)):
            return window?.isKeyWindow == true && window?.attachedSheet == nil && session.selectedCopy != nil
        case #selector(refresh(_:)): return window?.isKeyWindow == true && !session.isReading && !session.isCopying
        case #selector(checkContents(_:)): return window?.isKeyWindow == true && session.canCheckContents
        case #selector(findPaths(_:)): return window?.isKeyWindow == true && session.canFilterPaths
        case #selector(findDiffs(_:)): return window?.isKeyWindow == true && session.canFindAcrossDiffs
        default: return true
        }
    }

    @objc private func refresh(_ sender: Any?) { session.refresh() }
    @objc private func findPaths(_ sender: Any?) { if window?.isKeyWindow == true { session.showPathFilter() } }
    @objc private func checkContents(_ sender: Any?) {
        guard window?.isKeyWindow == true, session.canCheckContents else { return }
        session.refresh(checkingContents: true)
    }
    @objc private func copyFiles(_ sender: Any?) {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return }
        session.copySelectedFiles()
    }

    @objc private func reviewCopy(_ sender: Any?) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, let copy = session.selectedCopy,
              let source = copy.sources.first?.deletingLastPathComponent() else { return }
        let destination = copy.destinationSide == .left ? "Left" : "Right"
        let count = copy.sources.count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Review a copy to the \(destination.lowercased()) folder"
            : "Review copies to the \(destination.lowercased()) folder"
        alert.informativeText = "From \(String(reflecting: source.path))\nTo \(String(reflecting: copy.destinationDirectory.path))"
        alert.addButton(withTitle: count == 1 ? "Copy File" : "Copy \(count) Files")
        alert.addButton(withTitle: "Cancel")

        let scale = InterfacePresentation.shared.size.scale
        let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340 * scale,
            height: CGFloat(min(132, max(48, count * 20 + 12))) * scale))
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.borderType = .bezelBorder
        let names = NSTextView(frame: list.contentView.bounds)
        names.isEditable = false
        names.font = .systemFont(ofSize: NSFont.systemFontSize * scale)
        names.isVerticallyResizable = true
        names.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        names.autoresizingMask = [.width]
        names.textContainerInset = NSSize(width: 6, height: 6)
        names.textContainer?.widthTracksTextView = true
        names.string = copy.sources.map { String(reflecting: $0.lastPathComponent) }.joined(separator: "\n")
        names.setAccessibilityLabel("Files to copy")
        list.documentView = names
        alert.accessoryView = list
        Task { [weak self, weak window] in
            guard let window, window.isVisible, window.attachedSheet == nil else { return }
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                  window.isVisible else { return }
            self?.session.copyReviewedFiles(copy)
        }
    }
    @objc private func openText(_ sender: Any?) {
        openReview(startingSearch: false)
    }
    @objc private func findDiffs(_ sender: Any?) { if session.canFindAcrossDiffs { openReview(startingSearch: true) } }
    @objc private func openLeftEditor(_ sender: Any?) { openEditor(on: .left) }
    @objc private func openRightEditor(_ sender: Any?) { openEditor(on: .right) }

    private func openEditor(on side: FolderComparisonSession.Side) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        session.openEditor(on: side) { [weak self, weak window] selection in
            guard let self, let window, window.isKeyWindow, window.attachedSheet == nil else { return }
            onOpenEditor(selection, side, window)
        }
    }

    private func openReview(startingSearch: Bool) {
        guard let window, window.isKeyWindow, let review = session.textSelections(startingSearch: startingSearch) else { return }
        onOpenText(review, window)
    }
}

private struct FolderComparisonContent: View {
    @ObservedObject var session: FolderComparisonSession
    let openText: () -> Void
    let findDiffs: () -> Void
    let openEditor: (FolderComparisonSession.Side) -> Void
    let reviewCopy: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                location(session.left, side: "Left")
                location(session.right, side: "Right")
            }
            HStack {
                Toggle("Show Hidden Items", isOn: Binding(get: { session.includingHidden }, set: session.setHidden))
                    .disabled(session.isReading || session.isCopying)
                Spacer()
                if session.isReading {
                    Button("Stop", role: .cancel) { session.stop() }
                        .disabled(!session.canStop)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Check Contents", systemImage: "doc.text.magnifyingglass") { session.refresh(checkingContents: true) }
                        .help("Compare the exact bytes of up to 64 same-sized pairs, with 1 MiB per file and 4 MiB read in total.")
                        .disabled(!session.canCheckContents)
                    Button("Refresh", systemImage: "arrow.clockwise") { session.refresh() }
                        .disabled(session.isCopying)
                }
            }
            Divider()
            if let report = session.displayedReport {
                results(report)
            } else {
                switch session.state {
                case .ready, .reading:
                    ProgressView("Comparing folder metadata…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .stopping:
                    ProgressView("Stopping comparison…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .stopped:
                    ContentUnavailableView("Comparison stopped", systemImage: "stop.circle")
                case .failed(let detail):
                    ContentUnavailableView("Comparison unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(detail))
                case .result: EmptyView()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    comparisonStatus
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        actions
                    }
                    comparisonStatus
                }
            }
        }
        .padding(18)
    }

    private var comparisonStatus: some View {
        let help = session.selectedRows.count > 1 && session.selectedCopy == nil && !session.isCopying
            ? "Choose missing files in the same folder and direction to copy them together."
            : "Matches use names, sizes and modification times."
        let defaultText: String
        if session.isReading && session.displayedReport != nil {
            defaultText = session.canStop ? "Checking file contents…" : "Stopping the content check…"
        } else if case .result(let report) = session.state, let contents = report.contentReview,
           session.selectedRows.count <= 1 || session.selectedCopy != nil {
            defaultText = "\(contents.differences) different by content"
        } else { defaultText = help }
        return Text(session.notice ?? defaultText)
            .interfaceFont(.caption).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open Text Diff", systemImage: "square.split.2x1", action: openText)
                .disabled(session.selectedText == nil)
            Menu("Open in Editor", systemImage: "pencil") {
                Button("Left File") { openEditor(.left) }.disabled(session.editorSelection(on: .left) == nil)
                Button("Right File") { openEditor(.right) }.disabled(session.editorSelection(on: .right) == nil)
            }
            .labelStyle(.iconOnly).help("Open the selected file in Traverse’s editor")
            .disabled(session.editorSelection(on: .left) == nil && session.editorSelection(on: .right) == nil)
            if session.canFindAcrossDiffs {
                Button("Find Across Diffs", systemImage: "magnifyingglass", action: findDiffs)
                    .labelStyle(.iconOnly).help("Find Across Diffs (⇧⌘F)")
            }
            if session.isCopying {
                Button("Stop Copy", systemImage: "stop", action: session.stopCopy)
            } else {
                Button("Review Copy…", systemImage: "list.clipboard", action: reviewCopy)
                    .labelStyle(.iconOnly).help("Review the source, destination and files before copying")
                    .disabled(session.selectedCopy == nil)
                Button(session.copyTitle, systemImage: "document.on.document", action: session.copySelectedFiles)
                    .disabled(session.selectedCopy == nil)
            }
        }
    }

    private func location(_ url: URL, side: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(side).interfaceFont(.caption).foregroundStyle(.secondary)
            Label(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, systemImage: "folder")
                .interfaceFont(.headline).lineLimit(1)
            Text(url.path).interfaceFont(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(url.path)
    }

    @ViewBuilder private func results(_ report: FolderComparisonReport) -> some View {
        let differenceCount = report.differenceCount
        if let review = report.contentReview, review.unchecked > 0 {
            Label("Content check incomplete", systemImage: "exclamationmark.circle")
                .interfaceFont(.headline)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                summary(report, differenceCount: differenceCount)
                Spacer()
                filterPicker(report)
            }
            VStack(alignment: .leading, spacing: 8) {
                summary(report, differenceCount: differenceCount)
                filterPicker(report)
            }
        }
        if let pathFilterID = session.pathFilterID {
            ReviewFilterField(query: Binding(get: { session.pathQuery }, set: session.setPathQuery),
                identifier: "folder-comparison-path-filter", visibleCount: session.visibleRows.count,
                totalCount: report.rows.count, isFiltering: session.isFiltering, dismiss: session.hidePathFilter) { command in
                    switch command {
                    case .submit: if session.selectedText != nil { openText() }
                    case .cancel: session.hidePathFilter()
                    case .down: session.moveFilteredSelection(by: 1)
                    case .up: session.moveFilteredSelection(by: -1)
                    }
                    return true
                }
                .id(pathFilterID)
        }
        let rows = session.visibleRows
        if report.rows.isEmpty {
            ContentUnavailableView(report.contentReview == nil ? "No metadata differences" : "No differences found",
                systemImage: "checkmark.circle")
        } else if rows.isEmpty && !session.isFiltering {
            ContentUnavailableView(session.pathQuery.isEmpty ? "No items in this view" : "No matching paths",
                systemImage: "line.3.horizontal.decrease")
        } else {
            GeometryReader { geometry in
                let available = max(240, InterfaceMetrics.insetTableColumnBudget(in: geometry.size.width, scale: scale))
                let detail = min(145 * scale, floor(available * 0.18))
                let difference = min(165 * scale, floor(available * 0.32))
                let path = max(108, floor(available - 2 * detail - difference))
                Table(rows, selection: $session.selectedRows) {
                    TableColumn("Relative path") { row in
                        Text(row.relativePath).lineLimit(1).truncationMode(.middle).help(row.relativePath)
                    }.width(path)
                    TableColumn("Difference") { row in
                        let result = status(for: row)
                        Text(result).lineLimit(1).help(result)
                    }.width(difference)
                    TableColumn("Left") { row in
                        itemCell(row.left, for: row.difference)
                    }.width(detail)
                    TableColumn("Right") { row in
                        itemCell(row.right, for: row.difference)
                    }.width(detail)
                }
                .accessibilityLabel("Folder comparison results")
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .disabled(session.isFiltering)
            }
        }
    }

    private func summary(_ report: FolderComparisonReport, differenceCount: Int) -> some View {
        HStack(spacing: 12) {
            Text(differenceCount == 1 ? "1 difference" : "\(differenceCount) differences")
            if let contents = report.contentReview {
                Text(contents.matches == 1 ? "1 byte match" : "\(contents.matches) byte matches")
                if contents.unchecked > 0 { Text("\(contents.unchecked) unchecked") }
            } else {
                Text(report.matchingFiles == 1 ? "1 metadata match" : "\(report.matchingFiles) metadata matches")
            }
            if report.omissions > 0 { Text("\(report.omissions) skipped") }
        }
        .interfaceFont(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func filterPicker(_ report: FolderComparisonReport) -> some View {
        if !report.rows.isEmpty {
            HStack(spacing: 8) {
                Picker("Show", selection: Binding(get: { session.filter }, set: session.setFilter)) {
                    ForEach(FolderComparisonSession.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                if session.pathFilterID == nil {
                    Button("Filter Paths", systemImage: "magnifyingglass", action: session.showPathFilter)
                        .labelStyle(.iconOnly).help("Filter paths (⌘F)")
                }
            }
        }
    }

    private func status(for row: FolderComparisonReport.Row) -> String {
        switch row.difference {
        case .onlyOnLeft: "Only on left"
        case .onlyOnRight: "Only on right"
        case .differentKind: "Different types"
        case .differentSize: "Different sizes"
        case .differentModificationTime:
            if row.contents == .unchecked { "Different time, bytes unchecked" }
            else { row.matchedContents ? "Same bytes, different time" : "Different modification time" }
        case .differentContents: "Different contents"
        case .contentsNotChecked: "Unchecked"
        case .notCompared:
            switch row.omission {
            case .unreadable, nil: "Could not read"
            case .symbolicLink: "Symbolic link skipped"
            case .specialFile: "Special file skipped"
            case .otherVolume: "Nested volume skipped"
            case .datalessFolder: "Online-only folder skipped"
            case .protectedLocation: "Protected location skipped"
            case .hidden: "Hidden on one side"
            }
        }
    }

    private func itemCell(_ item: FolderComparisonReport.Item?, for result: FolderComparisonReport.Difference) -> some View {
        let detail = itemDetail(item, for: result)
        return Text(detail).lineLimit(1).help(detail)
    }

    private func itemDetail(_ item: FolderComparisonReport.Item?, for result: FolderComparisonReport.Difference) -> String {
        guard let item else { return "" }
        if result == .differentModificationTime, let date = item.modifiedAt {
            return date.formatted(date: .abbreviated, time: .standard)
        }
        switch item.kind {
        case .directory: return "Folder"
        case .package: return "Package"
        case .symbolicLink: return "Symbolic link"
        case .other: return "Other"
        case .file: return item.byteCount?.formatted(.byteCount(style: .file)) ?? "File"
        }
    }
}
