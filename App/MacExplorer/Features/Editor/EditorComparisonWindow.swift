import AppKit
import Combine
import FileOperations
import LocalStorage
import SwiftUI

enum EditorComparisonLoadFailure: Error {
    case unavailable(String)
}

/// A comparison of either captured editor text or loaded documents.
/// Closing joins the source and CPU work before removing the presentation.
@MainActor final class EditorComparisonWindow: NSWindowController, NSWindowDelegate, ObservableObject, NSUserInterfaceValidations {
    typealias TextRead = @MainActor () async throws -> EditorComparisonCapture
    typealias EditIndexChange = @MainActor (NSWindow, EditorComparisonPlan, EditorComparisonChange, () -> Bool) async throws -> Bool

    struct Labels: Sendable {
        let title: String
        let source: String
        let left: String
        let right: String
        let detail: String
        let refresh: String?
    }

    struct Source: Sendable {
        let labels: Labels
        let read: TextRead
        var editIndexChange: EditIndexChange?
    }

    enum IndexAction: Equatable {
        case stage, unstage

        var title: String { self == .stage ? "Stage Selected Change…" : "Unstage Selected Change…" }
        var symbol: String { self == .stage ? "plus.circle" : "minus.circle" }
    }

    struct FileList {
        let count: Int
        let initialIndex: Int
        var excludedCount = 0
        var startsWithSearch = false
        var indexAction: IndexAction?
        let entryAt: @MainActor (Int) -> Source
    }

    struct ChangePosition {
        let index: Int
        let total: Int
        let before: String
        let after: String

        init(_ change: EditorComparisonChange, index: Int, total: Int) {
            self.index = index
            self.total = total
            before = change.beforeLineLabel
            after = change.currentLineLabel
        }

        var summary: String { "Change \(index + 1) of \(total)" }

        func text(stacked: Bool, unified: Bool) -> String {
            if unified { return "\(summary) · Before \(before) · After \(after)" }
            return stacked ? "\(summary) · Top \(before) · Bottom \(after)"
                : "\(summary) · Left \(before) · Right \(after)"
        }
    }

    let beforeSurface = NativeTextEditorSurface(frame: .zero)
    let currentSurface = NativeTextEditorSurface(frame: .zero)
    let diffSearch = EditorDiffSearch()
    @Published private(set) var status = "Preparing comparison…"
    @Published private(set) var position: ChangePosition?
    @Published private(set) var preparing = false
    @Published private(set) var canNavigate = false
    @Published private(set) var linksScrolling: Bool
    @Published private(set) var changeMap: EditorComparisonChangeMap?
    @Published private(set) var labels: Labels
    @Published private(set) var fileIndex: Int?
    @Published private(set) var showsUnifiedDiff = false
    private var unifiedPlan: EditorDiffContextPlan?
    private var contextView: EditorDiffContextView?
    private var comparisonPointSize: CGFloat
    private var comparisonScale: CGFloat
    private var returningToSplit: (side: EditorComparisonPlan.Side, selection: NSRange?)?
    private var fileList: FileList?
    var fileCount: Int { fileList?.count ?? 0 }
    var diffSearchTitle: String { fileCount > 1 ? "Find Across Diffs" : "Find in Diff" }
    var canShowDiffSearch: Bool { !preparing && (fileList != nil || plan != nil) }
    private var capture: TextRead
    private var editIndexChange: EditIndexChange?
    private var preferenceObservation: AnyCancellable?
    private var plan: EditorComparisonPlan? {
        didSet { if fileCount <= 1, oldValue != nil { diffSearch.invalidate() } }
    }
    private var comparisonWhitespace = EditorComparisonWhitespace.exact
    private var showsLineDetails = true
    private var index = 0
    private var updatingScroll = false
    private var previousScrollY = (before: CGFloat.zero, current: CGFloat.zero)
    private var scrollDriver = EditorComparisonPlan.Side.before
    private var keyboardSide = EditorComparisonPlan.Side.current
    private let lineNavigation = EditorLineNavigation()
    private var changeChoice: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var closingWork: Task<Void, Never>?
    private(set) var closed = false
    var canLinkScrolling: Bool { !showsUnifiedDiff && !preparing && plan?.grouped == false }
    var canShowUnifiedDiff: Bool { !preparing && unifiedPlan != nil }
    var didClose: (() -> Void)?
    #if DEBUG
    var planForVerification: EditorComparisonPlan? { plan }
    var hasWorkForVerification: Bool { delivery != nil || changeChoice != nil || closingWork != nil || diffSearch.isRunning }
    #endif

    convenience init(relativeTo parent: NSWindow, settings: BrowserSettings, pointSize: CGFloat,
                     capture: @escaping @MainActor () -> EditorComparisonCapture?) {
        self.init(relativeTo: parent, settings: settings, pointSize: pointSize,
            labels: Labels(title: "Compare Changes", source: parent.tab.title, left: "Saved snapshot",
                right: "Current text", detail: "Compare the editor's last loaded or saved text with the current buffer.",
                refresh: "Refresh Snapshot")) {
            guard let snapshot = capture() else {
                throw EditorComparisonLoadFailure.unavailable("Finish the editor’s current action before refreshing this comparison.")
            }
            return snapshot
        }
    }

    init(relativeTo parent: NSWindow, settings: BrowserSettings, pointSize: CGFloat, labels: Labels,
         files: FileList? = nil, capture: @escaping TextRead) {
        self.capture = capture
        self.labels = labels
        comparisonPointSize = pointSize
        comparisonScale = settings.interfaceSize.scale
        if let files, (0..<files.count).contains(files.initialIndex) {
            fileList = files; fileIndex = files.initialIndex
            editIndexChange = files.entryAt(files.initialIndex).editIndexChange
        }
        linksScrolling = settings.editorPreferences.linksComparisonScrolling
        let viewport = ToolWindowChrome.initialViewport(size: .init(width: 1080, height: 720),
            minimum: .init(width: 620, height: 520), scale: settings.interfaceSize.scale, screen: parent.screen)
        let native = ToolWindowChrome.makeWindow(title: labels.title + " — Traverse",
            size: viewport.size, minimumSize: viewport.minimum)
        super.init(window: native); native.delegate = self
        for surface in [beforeSurface, currentSurface] {
            surface.textView.isEditable = false; surface.textView.allowsUndo = false
            surface.applyEditorPreferences(settings.editorPreferences, pointSize: pointSize)
            surface.find.motion = { [weak settings] in settings?.motion ?? .init() }
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: surface.scrollView.contentView)
        }
        beforeSurface.textView.comparisonAccent = .removed
        currentSurface.textView.comparisonAccent = .inserted
        beforeSurface.onWindowAttachment = { [weak self] in self?.restoreSplitFocus(on: .before) }
        currentSurface.onWindowAttachment = { [weak self] in self?.restoreSplitFocus(on: .current) }
        beforeSurface.setAccessibilityLabel(labels.left + ", read only")
        currentSurface.setAccessibilityLabel(labels.right + ", read only")
        // Reuse the controller's fixed-window sizing policy. A hosting view's
        // intrinsic document height must not resize this viewport to all text.
        native.contentViewController = InterfaceHostingController(rootView: EditorComparisonContent(model: self, settings: settings, search: diffSearch))
        ToolWindowChrome.install(in: native, settings: settings,
            initialContentSize: viewport.size, minimumContentSize: viewport.minimum)
        ToolWindowChrome.position(native, relativeTo: parent)
        if fileList?.startsWithSearch == true { diffSearch.show() }
        preferenceObservation = settings.$editorPreferences.combineLatest(settings.$interfaceSize).dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] preferences, size in
                guard let self, !closed, closingWork == nil else { return }
                comparisonScale = size.scale
                comparisonPointSize = CGFloat(preferences.basePointSize) * comparisonScale
                contextView?.updateMetrics(pointSize: comparisonPointSize, scale: comparisonScale,
                    findColor: preferences.findHighlightColor.nativeColor)
                withoutScrollFeedback {
                    for surface in [beforeSurface, currentSurface] {
                        surface.applyEditorPreferences(preferences, pointSize: CGFloat(preferences.basePointSize) * size.scale)
                    }
                }
            }
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        guard !closed, closingWork == nil else { return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if plan == nil && delivery == nil { prepare(realigning: nil, whitespace: comparisonWhitespace) }
    }

    var canPresentCapture: Bool {
        !closed && closingWork == nil && delivery == nil && changeChoice == nil
            && !diffSearch.isRunning && window?.attachedSheet == nil
    }

    @discardableResult func present(_ capture: EditorComparisonCapture, at change: EditorComparisonChange? = nil,
                                    labels: Labels? = nil) -> Bool {
        guard canPresentCapture else { return false }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        prepare(realigning: nil, whitespace: .exact, captured: capture, selecting: change, labels: labels)
        return true
    }

    func refresh() {
        guard labels.refresh != nil else { return }
        prepare(realigning: nil, whitespace: comparisonWhitespace)
    }

    func canVisitFile(_ direction: EditorJumpDirection) -> Bool {
        guard !closed, closingWork == nil, !preparing, changeChoice == nil, !diffSearch.isRunning, window?.attachedSheet == nil,
              let fileIndex else { return false }
        return (0..<fileCount).contains(fileIndex + direction.offset)
    }

    func visitFile(_ direction: EditorJumpDirection) {
        guard window?.isKeyWindow == true, canVisitFile(direction), let fileList, let fileIndex else { return }
        let next = fileIndex + direction.offset
        prepare(realigning: nil, whitespace: comparisonWhitespace, file: (next, fileList.entryAt(next)))
    }

    func startDiffSearch() {
        guard !closed, closingWork == nil, !preparing, changeChoice == nil, window?.isKeyWindow == true,
              window?.attachedSheet == nil else { return }
        if fileCount <= 1, let plan {
            diffSearch.find(in: plan, named: labels.source, excluded: fileList?.excludedCount ?? 0)
        } else if let fileList {
            let displayed = fileIndex.flatMap { index in plan.map { (index, labels.source, $0) } }
            diffSearch.find(in: fileList, whitespace: comparisonWhitespace, displayed: displayed)
        }
    }

    func presentDiffSearch() {
        guard canShowDiffSearch else { return }
        if !diffSearch.visible, !showsUnifiedDiff, let selection = focusedSurface().find.selectedQuery(maximumUnits: 256) {
            diffSearch.query = selection
        }
        diffSearch.show()
    }

    func openDiffSearchHit(_ hit: EditorDiffSearchHit) {
        guard !closed, closingWork == nil, !preparing, changeChoice == nil, !diffSearch.isRunning, window?.isKeyWindow == true,
              window?.attachedSheet == nil, diffSearch.contains(hit) else { return }
        diffSearch.selected = hit.id
        if let plan, hit.file == (fileIndex ?? 0), plan.snapshot == hit.snapshot {
            reveal(hit, in: plan)
            return
        }
        if let fileList, (0..<fileList.count).contains(hit.file) {
            prepare(realigning: nil, whitespace: comparisonWhitespace, file: (hit.file, fileList.entryAt(hit.file)), finding: hit)
        }
    }

    private func adoptFile(_ file: (index: Int, entry: Source)) {
        capture = file.entry.read
        editIndexChange = file.entry.editIndexChange
        fileIndex = file.index
        adoptLabels(file.entry.labels)
    }

    private func adoptLabels(_ labels: Labels) {
        self.labels = labels
        beforeSurface.setAccessibilityLabel(labels.left + ", read only")
        currentSurface.setAccessibilityLabel(labels.right + ", read only")
    }

    private func prepare(realigning existing: EditorComparisonPlan?, whitespace: EditorComparisonWhitespace,
                         captured: EditorComparisonCapture? = nil, selecting change: EditorComparisonChange? = nil,
                         labels: Labels? = nil,
                         file: (index: Int, entry: Source)? = nil, finding hit: EditorDiffSearchHit? = nil) {
        guard !closed, closingWork == nil, delivery == nil, changeChoice == nil, !diffSearch.isRunning,
              window?.attachedSheet == nil else { return }
        if whitespace != comparisonWhitespace { diffSearch.invalidate() }
        preparing = true
        canNavigate = false
        if let file { status = "Opening comparison for \(file.entry.labels.source)…" }
        else { status = existing == nil ? "Preparing comparison…" : "Updating comparison…" }
        let prior = plan
        let read = file?.entry.read ?? capture
        let changingFile = file.map { $0.index != fileIndex } == true
        delivery = Task { [weak self] in
            let result: Result<(plan: EditorComparisonPlan, context: EditorDiffContextPlan?, replaceLeft: Bool, replaceRight: Bool), Error>
            do {
                let compute: @Sendable () throws -> EditorComparisonPlan
                if let existing {
                    compute = { try EditorTextComparison.realign(existing, whitespace: whitespace, cancelled: { Task.isCancelled }) }
                } else {
                    let input: EditorComparisonCapture
                    if let captured { input = captured }
                    else { input = try await read() }
                    compute = { try EditorTextComparison.prepare(input, whitespace: whitespace, cancelled: { Task.isCancelled }) }
                }
                try Task.checkCancellation()
                let computation = Task.detached(priority: .userInitiated) {
                    let prepared = try compute()
                    if let hit, prepared.snapshot != hit.snapshot {
                        throw EditorComparisonLoadFailure.unavailable("This file changed after the search. Run Find again.")
                    }
                    let context = EditorDiffContextPlan(prepared)
                    if changingFile { return (prepared, context, true, true) }
                    guard existing == nil else { return (prepared, context, false, false) }
                    let leftMatches = prior?.before.encoded == prepared.before.encoded && prior?.beforeSyntax == prepared.beforeSyntax
                    let rightMatches = prior?.current.encoded == prepared.current.encoded && prior?.currentSyntax == prepared.currentSyntax
                    return (prepared, context, !leftMatches, !rightMatches)
                }
                let prepared = try await withTaskCancellationHandler {
                    try await computation.value
                } onCancel: { computation.cancel() }
                try Task.checkCancellation()
                result = .success(prepared)
            } catch { result = .failure(error) }
            guard let self else { return }
            delivery = nil; preparing = false
            guard !closed, closingWork == nil else { return }
            if let hit, !diffSearch.contains(hit) {
                canNavigate = prior?.changes.isEmpty == false
                status = "Search changed. Choose a current result."
                return
            }
            guard case .success(let output) = result else {
                switch result {
                case .failure(EditorComparisonLoadFailure.unavailable(let message)): status = message
                case .failure(is CancellationError): status = "Comparison stopped."
                default: status = "This text comparison could not be prepared."
                }
                if let file, hit == nil, case .failure(let error) = result, !(error is CancellationError) {
                    adoptFile(file)
                    // Keep the file reachable for Refresh or navigation even
                    // when its object cannot be opened as supported text.
                    if let empty = try? TextDocumentValue.original(Data()) {
                        withoutScrollFeedback {
                            for surface in [beforeSurface, currentSurface] {
                                surface.install(empty)
                                surface.textView.comparisonHighlights = []
                                surface.textView.comparisonDetails = []
                            }
                        }
                    }
                    plan = nil; changeMap = nil; position = nil
                    updateUnifiedSource(nil)
                } else if let plan {
                    status += " Showing the previous snapshot."
                    canNavigate = !plan.changes.isEmpty
                }
                return
            }
            let prepared = output.plan
            if let file { adoptFile(file) }
            if let labels { adoptLabels(labels) }
            let leftAnchor = output.replaceLeft && prior != nil && !changingFile ? beforeSurface.scrollAnchor() : nil
            let rightAnchor = output.replaceRight && prior != nil && !changingFile ? currentSurface.scrollAnchor() : nil
            if output.replaceLeft || output.replaceRight {
                withoutScrollFeedback {
                    if output.replaceLeft {
                        beforeSurface.install(prepared.before)
                        _ = beforeSurface.present(prepared.before, syntax: prepared.beforeSyntax,
                            lines: prepared.beforeIndex, for: beforeSurface.generation)
                    }
                    if output.replaceRight {
                        currentSurface.install(prepared.current)
                        _ = currentSurface.present(prepared.current, syntax: prepared.currentSyntax,
                            lines: prepared.currentIndex, for: currentSurface.generation)
                    }
                    window?.contentView?.layoutSubtreeIfNeeded()
                    @MainActor func restore(_ anchor: EditorScrollAnchor?, in surface: NativeTextEditorSurface) {
                        guard let anchor, let lines = surface.lineIndex else { return }
                        surface.scroll(to: .init(line: min(anchor.line, lines.starts.count - 1),
                            column: anchor.column, fragmentProgress: anchor.fragmentProgress))
                    }
                    restore(leftAnchor, in: beforeSurface)
                    restore(rightAnchor, in: currentSurface)
                    if changingFile {
                        beforeSurface.restoreViewportOrigin(.zero)
                        currentSurface.restoreViewportOrigin(.zero)
                    }
                }
            }
            beforeSurface.textView.comparisonHighlights = prepared.changes.map(\.beforeRange)
            currentSurface.textView.comparisonHighlights = prepared.changes.map(\.currentRange)
            comparisonWhitespace = prepared.whitespace
            plan = prepared; canNavigate = !prepared.changes.isEmpty
            updateUnifiedSource(prepared, context: output.context, changingFile: changingFile)
            changeMap = EditorComparisonChangeMap(prepared)
            updateLineDetails()
            if prepared.changes.isEmpty {
                let sameFormat = prepared.before.format == prepared.current.format
                if prepared.exactTextMatches {
                    status = sameFormat ? "No text differences" : "Same text · Different line endings or UTF-8 byte order mark"
                } else {
                    status = sameFormat ? "No visible changes" : "Different line endings or UTF-8 byte order mark"
                }
            } else if let counts = prepared.changedLineCounts {
                let groups = prepared.changes.count
                status = "+\(counts.added) added · −\(counts.removed) removed · \(groups) change \(groups == 1 ? "group" : "groups")"
            } else {
                status = "Large changes grouped for review"
            }
            if prepared.whitespace != .exact { status += " · " + prepared.whitespace.summary }
            if let hit { reveal(hit, in: prepared) }
            else if let change, let selected = prepared.changes.firstIndex(of: change), !prepared.grouped {
                showChange(at: selected, in: prepared)
            } else if prior == nil || changingFile {
                if prepared.changes.isEmpty { position = nil }
                else { showChange(at: 0, in: prepared) }
            } else if existing != nil || output.replaceLeft || output.replaceRight {
                updatePositionNearViewport(prepared)
            } else if prepared.changes.indices.contains(index) {
                showPosition(prepared.changes[index], total: prepared.changes.count)
            } else {
                position = nil
            }
            if output.replaceLeft { ToolContentMotion.reveal(beforeSurface, movesContent: false) }
            if output.replaceRight { ToolContentMotion.reveal(currentSurface, movesContent: false) }
        }
    }

    private func reveal(_ hit: EditorDiffSearchHit, in plan: EditorComparisonPlan) {
        let surface = hit.side == .before ? beforeSurface : currentSurface
        let length = (surface.textView.string as NSString).length
        guard hit.range.location >= 0, hit.range.location <= length,
              hit.range.length <= length - hit.range.location else { return }
        if let index = plan.changes.firstIndex(where: {
            NSIntersectionRange(hit.range, hit.side == .before ? $0.beforeRange : $0.currentRange).length > 0
        }) { showChange(at: index, in: plan) }
        keyboardSide = hit.side
        if showsUnifiedDiff, contextView?.revealMatch(side: hit.side, range: hit.range) == true {
            contextView?.focusTable()
            return
        }
        if showsUnifiedDiff {
            returnToSplit(side: hit.side, selection: hit.range)
            return
        }
        window?.makeFirstResponder(surface.textView)
        surface.textView.setSelectedRange(hit.range)
        withoutScrollFeedback { surface.textView.scrollRangeToVisible(hit.range) }
        alignViewport(from: hit.side)
    }
    func navigate(_ offset: Int) {
        guard canNavigate, let plan else { position = nil; return }
        revealChange(at: (index + offset + plan.changes.count) % plan.changes.count)
    }

    @discardableResult func revealChange(at selected: Int) -> Bool {
        guard !closed, !preparing, closingWork == nil, changeChoice == nil, window?.isKeyWindow == true, window?.attachedSheet == nil,
              let plan, plan.changes.indices.contains(selected) else { return false }
        showChange(at: selected, in: plan)
        return true
    }

    private func showChange(at selected: Int, in plan: EditorComparisonPlan) {
        index = selected
        let change = plan.changes[selected]
        if showsUnifiedDiff {
            contextView?.navigate(toChange: selected)
            showPosition(change, total: plan.changes.count)
            return
        }
        withoutScrollFeedback {
            if linksScrolling && !plan.grouped {
                let left = min(max(0, change.beforeLines.lowerBound - 2), plan.beforeIndex.starts.count - 1)
                let right = min(max(0, change.currentLines.lowerBound - 2), plan.currentIndex.starts.count - 1)
                beforeSurface.scroll(to: .init(line: left, column: 0, fragmentProgress: 0))
                currentSurface.scroll(to: .init(line: right, column: 0, fragmentProgress: 0))
                // TextKit may constrain the context scroll while laying out
                // wrapped fragments. Reveal the exact start in each viewport.
                beforeSurface.textView.scrollRangeToVisible(.init(location: change.beforeRange.location, length: 0))
                currentSurface.textView.scrollRangeToVisible(.init(location: change.currentRange.location, length: 0))
            } else {
                beforeSurface.textView.scrollRangeToVisible(change.beforeRange)
                currentSurface.textView.scrollRangeToVisible(change.currentRange)
            }
        }
        showPosition(change, total: plan.changes.count)
    }

    var unifiedDiffView: EditorDiffContextView {
        if let contextView { return contextView }
        let view = EditorDiffContextView(frame: .zero)
        view.updateMetrics(pointSize: comparisonPointSize, scale: comparisonScale,
            findColor: beforeSurface.textView.findHighlightColor)
        view.didSelectChange = { [weak self] selected in
            guard let self, showsUnifiedDiff, let plan, plan.changes.indices.contains(selected) else { return }
            index = selected
            showPosition(plan.changes[selected], total: plan.changes.count)
        }
        contextView = view
        return view
    }

    private func updateUnifiedSource(_ plan: EditorComparisonPlan?, context: EditorDiffContextPlan? = nil,
                                     changingFile: Bool = false) {
        returningToSplit = nil
        unifiedPlan = context
        if let plan, let unifiedPlan { contextView?.install(plan, context: unifiedPlan, changingFile: changingFile) }
        else if let contextView {
            if showsUnifiedDiff { returnToSplit(side: keyboardSide, selection: nil) }
            contextView.clear()
        }
    }

    func setUnifiedDiff(_ enabled: Bool) {
        guard enabled != showsUnifiedDiff, canShowUnifiedDiff, let plan, let unifiedPlan,
              !closed, closingWork == nil, changeChoice == nil, window?.isKeyWindow == true,
              window?.attachedSheet == nil else { return }
        if enabled {
            let view = unifiedDiffView
            view.install(plan, context: unifiedPlan)
            showsUnifiedDiff = true
            if position != nil { view.navigate(toChange: index) }
            view.focusTable()
        } else {
            let location = contextView?.selectedLocation
            returnToSplit(side: location?.side ?? keyboardSide, selection: location?.range)
        }
    }

    private func returnToSplit(side: EditorComparisonPlan.Side, selection: NSRange?) {
        returningToSplit = (side, selection)
        showsUnifiedDiff = false
        restoreSplitFocus(on: side)
    }

    private func restoreSplitFocus(on side: EditorComparisonPlan.Side) {
        guard !showsUnifiedDiff, let request = returningToSplit, request.side == side, let window else { return }
        let surface = side == .before ? beforeSurface : currentSurface
        guard surface.textView.window === window, window.makeFirstResponder(surface.textView) else { return }
        returningToSplit = nil
        keyboardSide = side
        if let range = request.selection {
            surface.textView.setSelectedRange(range)
            withoutScrollFeedback { surface.textView.scrollRangeToVisible(range) }
            alignViewport(from: side)
        }
    }
    func chooseChange() {
        guard !closed, canNavigate, changeChoice == nil, let window, window.isKeyWindow, window.attachedSheet == nil,
              let plan, changeMap != nil else { return }
        let rows = plan.changes.enumerated().map { index, change in
            let position = ChangePosition(change, index: index, total: plan.changes.count)
            return NativeChoiceSheet<Int>.Row(title: "Change \(index + 1)",
                detail: "First \(position.before) · Second \(position.after)", value: index)
        }
        let preview = EditorChangeExcerpt.selectionPreview(before: (labels.left, plan.before.text),
            after: (labels.right, plan.current.text)) { (index: Int) in
            plan.changes[index]
        }
        let sheet = NativeChoiceSheet<Int>(title: "Go to Change", heading: "Choose a change in the comparison",
            confirm: "Go to Change", rows: rows, initialSelection: index, preview: preview,
            size: EditorChangeExcerpt.choiceSize(in: window))
        changeChoice = Task { [weak self, weak window] in
            guard let window else { self?.changeChoice = nil; return }
            let selected = await sheet.choose(in: window)
            guard let self else { return }
            changeChoice = nil
            guard !closed, closingWork == nil, window.isVisible, let selected else { return }
            showChange(at: selected, in: plan)
        }
    }

    func hasEditorSource(_ side: EditorComparisonPlan.Side) -> Bool {
        sourceEditor(on: side) != nil
    }

    func canEditAtChange(_ side: EditorComparisonPlan.Side) -> Bool {
        editorChangeTarget(on: side) != nil
    }

    func canApplyChange(to side: EditorComparisonPlan.Side) -> Bool {
        plan?.application(of: index, to: side) != nil && editorChangeTarget(on: side) != nil
    }

    var selectedIndexAction: IndexAction? { editIndexChange == nil ? nil : fileList?.indexAction }

    var canEditSelectedIndexChange: Bool {
        guard selectedIndexAction != nil, canPresentCapture, let plan,
              !plan.grouped, plan.whitespace == .exact, plan.changes.indices.contains(index) else { return false }
        return GitIndexTextChange.supports(plan.before) && GitIndexTextChange.supports(plan.current)
    }

    @objc func editSelectedIndexChange(_ sender: Any?) {
        guard canEditSelectedIndexChange, let editIndexChange, let plan, let window, window.isKeyWindow else { return }
        let change = plan.changes[index]
        let selectedFile = fileIndex
        let selectedChange = index
        status = "Checking the selected Git change…"
        changeChoice = Task { [weak self, weak window] in
            guard let self, let window else { self?.changeChoice = nil; return }
            let outcome: Result<Bool, Error>
            do {
                outcome = .success(try await editIndexChange(window, plan, change) {
                    !closed && closingWork == nil && fileIndex == selectedFile && index == selectedChange
                        && self.plan?.snapshot == plan.snapshot && window.isKeyWindow && !ApplicationFileActivity.gate.isClosed
                })
            } catch { outcome = .failure(error) }
            changeChoice = nil
            guard !closed, closingWork == nil else { return }
            switch outcome {
            case .success(true): window.performClose(nil)
            case .success(false), .failure(is CancellationError): status = "No Git index change was applied."
            case .failure(let error): status = GitIndexEditFlow.message(for: error)
            }
        }
    }

    func applyChange(to side: EditorComparisonPlan.Side) {
        guard window?.isKeyWindow == true, let change = plan?.application(of: index, to: side),
              let target = editorChangeTarget(on: side), target.editor.editableBufferIdentity == change.editor else { return }
        target.editor.focusNavigationTarget()
        guard target.editor.editableBufferIdentity == change.editor else {
            status = "The target editor changed. Refresh the comparison to try again."
            return
        }
        target.editor.surface.lineCommands.applyComparedChange(change) { [weak self] applied in
            guard let self, !closed else { return }
            status = applied ? "Applied to the editor. Undo is available there. Refresh to review the new text."
                : "The editor kept its text. Refresh the comparison to try again."
        }
    }

    func editAtChange(_ side: EditorComparisonPlan.Side) {
        guard window?.isKeyWindow == true else { return }
        guard let target = editorChangeTarget(on: side) else {
            status = "The editor changed or closed. Refresh to review the available text."
            return
        }
        target.editor.focusNavigationTarget()
        _ = target.editor.surface.goToTextOffset(target.offset, generation: target.generation)
    }

    private func sourceEditor(on side: EditorComparisonPlan.Side) -> EditorBufferIdentity? {
        side == .before ? plan?.sourceEditors.before : plan?.sourceEditors.current
    }

    private func editorChangeTarget(on side: EditorComparisonPlan.Side) -> (editor: NativeTextEditorWindow, generation: UUID, offset: Int)? {
        guard !closed, closingWork == nil, !preparing, !showsUnifiedDiff, window?.attachedSheet == nil,
              let plan, !plan.grouped, plan.changes.indices.contains(index), let identity = sourceEditor(on: side),
              let editor = NativeTextEditorWindow.openSearchDocuments().first(where: { $0.editableBufferIdentity == identity }),
              editor.surface.canGoToLine else { return nil }
        let change = plan.changes[index]
        return (editor, identity.generation, side == .before ? change.beforeRange.location : change.currentRange.location)
    }

    private var editorCommandSide: EditorComparisonPlan.Side {
        let preferred: EditorComparisonPlan.Side = focusedSurface() === beforeSurface ? .before : .current
        return hasEditorSource(preferred) ? preferred : preferred == .before ? .current : .before
    }

    private func updatePositionNearViewport(_ prepared: EditorComparisonPlan) {
        if showsUnifiedDiff {
            if prepared.changes.indices.contains(index) { showChange(at: index, in: prepared) }
            else { position = nil }
            return
        }
        let surface = scrollDriver == .before ? beforeSurface : currentSurface
        let anchor = surface.scrollAnchor()?.line ?? 0
        func distance(_ change: EditorComparisonChange) -> Int {
            let range = scrollDriver == .before ? change.beforeLines : change.currentLines
            return range.contains(anchor) ? 0 : min(abs(range.lowerBound - anchor), abs(range.upperBound - anchor))
        }
        guard let nearest = prepared.changes.indices.min(by: { distance(prepared.changes[$0]) < distance(prepared.changes[$1]) }) else {
            position = nil
            return
        }
        index = nearest
        showPosition(prepared.changes[nearest], total: prepared.changes.count)
    }

    private func showPosition(_ change: EditorComparisonChange, total: Int) {
        position = .init(change, index: index, total: total)
    }

    func setLinkedScrolling(_ enabled: Bool) {
        guard canLinkScrolling, linksScrolling != enabled else { return }
        linksScrolling = enabled
        if enabled { alignViewport(from: scrollDriver) }
    }

    private func updateLineDetails() {
        beforeSurface.textView.comparisonDetails = showsLineDetails ? plan?.beforeDetails ?? [] : []
        currentSurface.textView.comparisonDetails = showsLineDetails ? plan?.currentDetails ?? [] : []
    }

    private func withoutScrollFeedback(_ update: () -> Void) {
        let previous = updatingScroll
        updatingScroll = true
        defer {
            previousScrollY = (beforeSurface.scrollView.contentView.bounds.minY, currentSurface.scrollView.contentView.bounds.minY)
            updatingScroll = previous
        }
        update()
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard !closed, !updatingScroll, !showsUnifiedDiff, let clip = notification.object as? NSClipView else { return }
        let y = clip.bounds.minY
        if clip === beforeSurface.scrollView.contentView, abs(y - previousScrollY.before) >= 0.25 {
            previousScrollY.before = y
            scrollDriver = .before
        } else if clip === currentSurface.scrollView.contentView, abs(y - previousScrollY.current) >= 0.25 {
            previousScrollY.current = y
            scrollDriver = .current
        } else { return }
        alignViewport(from: scrollDriver)
    }

    private func alignViewport(from side: EditorComparisonPlan.Side) {
        guard linksScrolling, canLinkScrolling, let plan else { return }
        let source = side == .before ? beforeSurface : currentSurface
        let target = side == .before ? currentSurface : beforeSurface
        withoutScrollFeedback {
            guard let anchor = source.scrollAnchor(), let line = plan.correspondingLine(anchor.line, from: side) else { return }
            target.scroll(to: .init(line: line, column: anchor.column, fragmentProgress: anchor.fragmentProgress))
        }
    }

    func stop() { delivery?.cancel(); diffSearch.stop() }
    func closeAndDrain() async {
        if closed { return }
        if let closingWork { await closingWork.value; return }
        let task = Task { [self] in
            preferenceObservation = nil
            lineNavigation.cancel()
            changeChoice?.cancel()
            if let changeChoice { await changeChoice.value }
            await diffSearch.closeAndDrain()
            beforeSurface.find.clear(); currentSurface.find.clear()
            delivery?.cancel()
            if let delivery { await delivery.value }
            await beforeSurface.find.drain(); await currentSurface.find.drain()
            delivery = nil; plan = nil; changeMap = nil; canNavigate = false
            beforeSurface.clearPrivatePresentation(); currentSurface.clearPrivatePresentation()
            closed = true; window?.close()
        }
        closingWork = task; await task.value; closingWork = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closed { return true }
        if delivery == nil, changeChoice == nil, !diffSearch.isRunning, !beforeSurface.find.isWorking, !currentSurface.find.isWorking { return true }
        Task { [self] in await closeAndDrain() }; return false
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; plan = nil; changeMap = nil; canNavigate = false
        fileList = nil; fileIndex = nil; editIndexChange = nil
        delivery?.cancel()
        changeChoice?.cancel()
        diffSearch.dismiss()
        preferenceObservation = nil
        lineNavigation.cancel()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        beforeSurface.clearPrivatePresentation(); currentSurface.clearPrivatePresentation()
        contextView?.clear()
        contextView = nil
        ToolWindowMenuOwnership.release(self)
        window?.contentViewController = nil
        didClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed else { return }
        objectWillChange.send()
        _ = ToolWindowMenuOwnership.claim(self) { base in
            let menu = NSMenu()
            if let item = base?.items.first?.copy() as? NSMenuItem { menu.addItem(item) }
            @discardableResult func section(_ title: String, _ entries: [(String, Selector, String, NSEvent.ModifierFlags, AnyObject?)]) -> NSMenu {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), child = NSMenu(title: title)
                for (title, action, key, modifiers, target) in entries {
                    let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
                    command.keyEquivalentModifierMask = modifiers; command.target = target; child.addItem(command)
                }
                item.submenu = child; menu.addItem(item)
                return child
            }
            let file = section("File", [("Edit at Selected Change", #selector(editSelectedChange(_:)), "", [], self),
                ("Apply Selected Change to Editor", #selector(applySelectedChange(_:)), "", [], self),
                ("Close", #selector(NSWindow.performClose(_:)), "w", .command, window)])
            if let title = labels.refresh {
                file.insertItem(BrowserMenus.item(title, #selector(refreshSnapshot(_:)), key: "r", target: self), at: 2)
            }
            if let action = fileList?.indexAction {
                file.insertItem(BrowserMenus.item(action.title, #selector(editSelectedIndexChange(_:)), target: self), at: 2)
            }
            let edit = section("Edit", [("Copy", #selector(NSText.copy(_:)), "c", .command, nil),
                ("Select All", #selector(NSText.selectAll(_:)), "a", .command, nil)])
            EditorFindMenu.items(target: self, selector: #selector(performFind(_:)), allowsReplacement: false).forEach(edit.addItem)
            edit.addItem(EditorFindMenu.selectionItem(target: self, selector: #selector(findInSelection(_:))))
            edit.addItem(BrowserMenus.item(diffSearchTitle + "…", #selector(showDiffSearch(_:)), key: "F", target: self))
            for direction in EditorJumpDirection.allCases {
                let previous = direction == .previous
                let item = BrowserMenus.item(previous ? "Previous Diff Search Result" : "Next Diff Search Result",
                    #selector(visitDiffSearchResult(_:)), key: previous ? "G" : "g",
                    modifiers: previous ? [.command, .option, .shift] : [.command, .option], target: self)
                item.tag = direction.rawValue
                edit.addItem(item)
            }
            edit.addItem(BrowserMenus.item("Go to Line…", #selector(goToLine(_:)), key: "g", modifiers: .control, target: self))
            EditorJumpDirection.menuItems(target: self, action: #selector(visitTextLocation(_:))).forEach(edit.addItem)
            let view = section("View", [("Switch Compared Text Pane", #selector(switchTextPane(_:)), String(UnicodeScalar(NSF6FunctionKey)!), [], self),
                ("Unified Diff", #selector(toggleUnifiedDiff(_:)), "", [], self),
                ("Toggle Unchanged Section", #selector(toggleUnifiedContext(_:)), "", [], self),
                ("Show All Unchanged Lines", #selector(toggleAllUnifiedContext(_:)), "", [], self),
                ("Highlight Changes Within Lines", #selector(toggleLineDetails(_:)), "", [], self),
                (NativeTextEditorSurface.whitespaceMarksTitle, #selector(toggleWhitespaceMarks(_:)), "", [], self),
                ("Link Scrolling", #selector(toggleLinkedScrolling(_:)), "", [], self)])
            for (index, item) in EditorJumpDirection.changeMenuItems(target: self, action: #selector(visitChange(_:))).enumerated() {
                view.insertItem(item, at: index)
            }
            view.insertItem(BrowserMenus.item("Go to Change…", #selector(showChangeChooser(_:)),
                key: String(UnicodeScalar(NSF7FunctionKey)!), modifiers: .option, target: self), at: 2)
            if fileCount > 1 {
                view.addItem(.separator())
                for direction in EditorJumpDirection.allCases {
                    let previous = direction == .previous
                    let item = BrowserMenus.item(previous ? "Previous Compared File" : "Next Compared File",
                        #selector(visitComparedFile(_:)), key: previous ? "[" : "]", modifiers: [.command, .option], target: self)
                    item.tag = direction.rawValue
                    view.addItem(item)
                }
            }
            let whitespace = NSMenuItem(title: "Whitespace", action: nil, keyEquivalent: "")
            let modes = NSMenu(title: "Whitespace")
            for mode in EditorComparisonWhitespace.allCases {
                let item = BrowserMenus.item(mode.title, #selector(selectWhitespace(_:)), target: self)
                item.tag = mode.rawValue
                modes.addItem(item)
            }
            whitespace.submenu = modes
            view.addItem(whitespace)
            return menu
        }
    }
    func windowDidResignKey(_ notification: Notification) { ToolWindowMenuOwnership.release(self) }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !closed, closingWork == nil, window?.isKeyWindow == true, window?.attachedSheet == nil else { return false }
        switch item.action {
        case #selector(refreshSnapshot(_:)): return labels.refresh != nil && !preparing && !diffSearch.isRunning
        case #selector(showDiffSearch(_:)): return canShowDiffSearch
        case #selector(visitDiffSearchResult(_:)):
            guard !preparing, changeChoice == nil, let direction = EditorJumpDirection(rawValue: item.tag) else { return false }
            return diffSearch.adjacentHit(toward: direction) != nil
        case #selector(editSelectedChange(_:)):
            let side = editorCommandSide
            (item as? NSMenuItem)?.isHidden = !hasEditorSource(side)
            return canEditAtChange(side)
        case #selector(applySelectedChange(_:)):
            let side = editorCommandSide
            (item as? NSMenuItem)?.isHidden = !hasEditorSource(side)
            return canApplyChange(to: side)
        case #selector(editSelectedIndexChange(_:)):
            (item as? NSMenuItem)?.isHidden = selectedIndexAction == nil
            return canEditSelectedIndexChange
        case #selector(visitChange(_:)): return canNavigate
        case #selector(visitComparedFile(_:)):
            guard let item = item as? NSMenuItem, let direction = EditorJumpDirection(rawValue: item.tag) else { return false }
            return canVisitFile(direction)
        case #selector(showChangeChooser(_:)): return canNavigate && changeMap != nil && changeChoice == nil
        case #selector(toggleLinkedScrolling(_:)):
            (item as? NSMenuItem)?.state = linksScrolling && canLinkScrolling ? .on : .off
            return canLinkScrolling
        case #selector(toggleLineDetails(_:)):
            (item as? NSMenuItem)?.state = showsLineDetails ? .on : .off
            return !showsUnifiedDiff && !preparing && (plan.map { !$0.beforeDetails.isEmpty || !$0.currentDetails.isEmpty } ?? false)
        case #selector(toggleWhitespaceMarks(_:)):
            (item as? NSMenuItem)?.state = beforeSurface.showsWhitespaceMarks ? .on : .off
            return !showsUnifiedDiff && !preparing && plan != nil
        case #selector(toggleUnifiedDiff(_:)):
            (item as? NSMenuItem)?.state = showsUnifiedDiff ? .on : .off
            return canShowUnifiedDiff
        case #selector(toggleUnifiedContext(_:)): return showsUnifiedDiff && !preparing && contextView?.canToggleSelectedContext == true
        case #selector(toggleAllUnifiedContext(_:)):
            (item as? NSMenuItem)?.state = contextView?.allContextVisible == true ? .on : .off
            return showsUnifiedDiff && !preparing && contextView?.hasFoldableSections == true
        case #selector(selectWhitespace(_:)):
            if let item = item as? NSMenuItem { item.state = plan?.whitespace.rawValue == item.tag ? .on : .off }
            return !preparing && !diffSearch.isRunning && plan != nil
        case #selector(performFind(_:)):
            if showsUnifiedDiff, let action = NSTextFinder.Action(rawValue: item.tag) {
                switch action {
                case .showFindInterface: return canShowDiffSearch
                case .nextMatch: return diffSearch.adjacentHit(toward: .next) != nil
                case .previousMatch: return diffSearch.adjacentHit(toward: .previous) != nil
                default: return false
                }
            }
            return plan != nil && !preparing && (item.tag != NSTextFinder.Action.setSearchString.rawValue
                || focusedSurface().find.selectedQuery(allowsNewlines: true) != nil)
        case #selector(switchTextPane(_:)): return plan != nil && !preparing && !showsUnifiedDiff
        case #selector(findInSelection(_:)): return plan != nil && !preparing && !showsUnifiedDiff && focusedSurface().find.canFindInSelection
        case #selector(goToLine(_:)):
            guard let plan, !preparing else { return false }
            return showsUnifiedDiff ? plan.beforeIndex.contentLineCount > 0 || plan.currentIndex.contentLineCount > 0
                : focusedSurface().canGoToLine
        case #selector(visitTextLocation(_:)):
            guard plan != nil, !preparing, !showsUnifiedDiff, let direction = EditorJumpDirection(rawValue: item.tag) else { return false }
            return focusedSurface().canVisitTextLocation(direction)
        default: return true
        }
    }
    @objc private func refreshSnapshot(_ sender: Any?) { refresh() }
    @objc private func showDiffSearch(_ sender: Any?) { presentDiffSearch() }
    @objc private func visitDiffSearchResult(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let direction = EditorJumpDirection(rawValue: sender.tag),
              let hit = diffSearch.adjacentHit(toward: direction) else { return }
        openDiffSearchHit(hit)
    }
    @objc private func editSelectedChange(_ sender: Any?) { editAtChange(editorCommandSide) }
    @objc private func applySelectedChange(_ sender: Any?) { applyChange(to: editorCommandSide) }
    @objc private func visitComparedFile(_ sender: NSMenuItem) {
        if let direction = EditorJumpDirection(rawValue: sender.tag) { visitFile(direction) }
    }
    @objc private func visitChange(_ sender: NSMenuItem) {
        if let direction = EditorJumpDirection(rawValue: sender.tag) { navigate(direction.offset) }
    }
    @objc private func showChangeChooser(_ sender: Any?) { chooseChange() }
    @objc private func toggleLinkedScrolling(_ sender: Any?) { setLinkedScrolling(!linksScrolling) }
    @objc private func toggleUnifiedDiff(_ sender: Any?) { setUnifiedDiff(!showsUnifiedDiff) }
    @objc private func toggleUnifiedContext(_ sender: NSMenuItem) {
        if validateUserInterfaceItem(sender) { contextView?.toggleSelectedContext() }
    }
    @objc private func toggleAllUnifiedContext(_ sender: NSMenuItem) {
        if validateUserInterfaceItem(sender) { contextView?.toggleAllContext() }
    }
    @objc private func toggleLineDetails(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender) else { return }
        showsLineDetails.toggle()
        updateLineDetails()
    }

    @objc private func toggleWhitespaceMarks(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender) else { return }
        let visible = !beforeSurface.showsWhitespaceMarks
        withoutScrollFeedback {
            beforeSurface.setWhitespaceMarks(visible)
            currentSurface.setWhitespaceMarks(visible)
        }
    }

    @objc private func selectWhitespace(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let plan, let mode = EditorComparisonWhitespace(rawValue: sender.tag),
              mode != plan.whitespace else { return }
        prepare(realigning: plan, whitespace: mode)
    }

    private func focusedSurface() -> NativeTextEditorSurface {
        if let responder = window?.firstResponder {
            for (side, surface) in [(EditorComparisonPlan.Side.before, beforeSurface), (.current, currentSurface)] {
                if (responder as? NSView)?.isDescendant(of: surface) == true || responder === surface.find.bar.query.currentEditor() {
                    keyboardSide = side
                    return surface
                }
            }
        }
        return keyboardSide == .before ? beforeSurface : currentSurface
    }

    @objc private func performFind(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let action = NSTextFinder.Action(rawValue: sender.tag),
              action != .showReplaceInterface else { return }
        if showsUnifiedDiff {
            if action == .showFindInterface { presentDiffSearch() }
            else if let hit = diffSearch.adjacentHit(toward: action == .previousMatch ? .previous : .next) { openDiffSearchHit(hit) }
            return
        }
        focusedSurface().find.perform(action)
    }

    @objc private func findInSelection(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender) else { return }
        focusedSurface().find.findInSelection()
    }

    @objc private func switchTextPane(_ sender: Any?) {
        guard !closed, closingWork == nil, !preparing, !showsUnifiedDiff, plan != nil, let window,
              window.isKeyWindow, window.attachedSheet == nil else { return }
        let next = focusedSurface() === beforeSurface ? currentSurface : beforeSurface
        if window.makeFirstResponder(next.textView) { keyboardSide = next === beforeSurface ? .before : .current }
    }

    @objc private func goToLine(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let window else { return }
        if showsUnifiedDiff, let plan { goToUnifiedLine(in: window, using: plan); return }
        lineNavigation.present(in: window, surface: focusedSurface()) { [weak self] in
            self?.status = "The text changed. Open Go to Line again."
        }
    }

    private func goToUnifiedLine(in window: NSWindow, using plan: EditorComparisonPlan) {
        let location = contextView?.selectedLocation
        let preferredSide = location?.side ?? keyboardSide
        let choices = [(EditorComparisonPlan.Side.before, "Before", plan.beforeIndex), (.current, "After", plan.currentIndex)]
            .compactMap { side, title, index -> (EditorComparisonPlan.Side, EditorLineNavigation.Target)? in
                let count = index.contentLineCount
                guard count > 0 else { return nil }
                let current = location.flatMap { $0.side == side ? index.location(at: $0.range.location)?.line : nil } ?? 1
                return (side, .init(name: title, index: index, currentLine: current, lastLine: count))
            }
        guard !choices.isEmpty else { return }
        let initial = choices.firstIndex { $0.0 == preferredSide } ?? 0
        let expected = plan.snapshot
        lineNavigation.present(in: window, targets: choices.map(\.1), initial: initial) { [weak self] selected, address in
            guard let self, showsUnifiedDiff, self.plan?.snapshot == expected,
                  let offset = choices[selected].1.index.offset(at: address),
                  contextView?.revealMatch(side: choices[selected].0, range: .init(location: offset, length: 0)) == true else {
                self?.status = "The text changed. Open Go to Line again."
                return
            }
            keyboardSide = choices[selected].0
            contextView?.focusTable()
        }
    }

    @objc private func visitTextLocation(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let direction = EditorJumpDirection(rawValue: sender.tag) else { return }
        focusedSurface().visitTextLocation(direction)
    }
}

private struct EditorComparisonContent: View {
    @ObservedObject var model: EditorComparisonWindow
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var search: EditorDiffSearch
    @Environment(\.interfaceScale) private var scale
    @State private var stacksPanes = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.labels.source).interfaceFont(.headline).lineLimit(1).truncationMode(.middle)
                    .help(model.labels.source)
                Spacer()
                if model.fileCount > 1, let file = model.fileIndex {
                    Button("Previous Compared File", systemImage: "chevron.left") { model.visitFile(.previous) }
                        .disabled(!model.canVisitFile(.previous)).labelStyle(.iconOnly).help("Previous compared file (⌥⌘[)")
                    Text("\(file + 1) of \(model.fileCount)").interfaceFont(.caption).lineLimit(1)
                        .foregroundStyle(.secondary).accessibilityLabel("File \(file + 1) of \(model.fileCount)")
                    Button("Next Compared File", systemImage: "chevron.right") { model.visitFile(.next) }
                        .disabled(!model.canVisitFile(.next)).labelStyle(.iconOnly).help("Next compared file (⌥⌘])")
                }
                Button(model.diffSearchTitle, systemImage: "magnifyingglass", action: model.presentDiffSearch)
                    .labelStyle(.iconOnly).help(model.diffSearchTitle + " (⇧⌘F)").disabled(!model.canShowDiffSearch)
                Button(model.showsUnifiedDiff ? "Show Split Diff" : "Show Unified Diff",
                       systemImage: model.showsUnifiedDiff ? "rectangle.split.2x1" : "list.bullet.rectangle") {
                    model.setUnifiedDiff(!model.showsUnifiedDiff)
                }
                .labelStyle(.iconOnly)
                .disabled(!model.canShowUnifiedDiff)
                .help(model.canShowUnifiedDiff ? (model.showsUnifiedDiff ? "Show Split Diff" : "Show Unified Diff")
                    : "Unified Diff needs a detailed comparison with all whitespace shown")
                if model.preparing {
                    Button("Stop", role: .cancel) { model.stop() }.keyboardShortcut(.cancelAction)
                } else if let title = model.labels.refresh {
                    Button(title, systemImage: "arrow.clockwise") { model.refresh() }.disabled(search.isRunning)
                }
            }
            if search.visible {
                EditorDiffSearchBar(search: search, title: model.diffSearchTitle, searchFiles: model.startDiffSearch, open: model.openDiffSearchHit)
                    .disabled(model.preparing)
            }
            Text(model.labels.detail)
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Previous", systemImage: "chevron.up") { model.navigate(-1) }.disabled(!model.canNavigate)
                Button("Next", systemImage: "chevron.down") { model.navigate(1) }.disabled(!model.canNavigate)
                if let action = model.selectedIndexAction {
                    Button(action.title, systemImage: action.symbol) { model.editSelectedIndexChange(nil) }
                        .labelStyle(.iconOnly).disabled(!model.canEditSelectedIndexChange)
                        .help(action.title)
                }
                Text(model.position?.text(stacked: stacksPanes, unified: model.showsUnifiedDiff) ?? "")
                    .interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if model.changeMap != nil {
                    Button("Go to Change", systemImage: "list.number", action: model.chooseChange)
                        .labelStyle(.iconOnly).help("Go to Change (⌥F7)").disabled(!model.canNavigate)
                }
                if model.preparing { ProgressView().controlSize(.small) }
            }
            if let map = model.changeMap {
                EditorComparisonMapView(map: map, selection: model.position?.index ?? 0, enabled: model.canNavigate,
                    choose: model.revealChange)
                    .frame(height: 14 * scale)
            }
            if model.showsUnifiedDiff {
                HStack(spacing: 14) {
                    unifiedVersion(model.labels.left, symbol: "minus.circle", side: "Before")
                    unifiedVersion(model.labels.right, symbol: "plus.circle", side: "After")
                }
                EditorComparisonSurface(surface: model.unifiedDiffView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AdaptiveToolColumns(settings: settings, minimumWidth: 720, sizing: .viewport,
                    onArrangementChanged: { stacksPanes = $0 }) {
                    pane(model.labels.left, symbol: "minus.circle", side: .before, surface: model.beforeSurface)
                } trailing: {
                    pane(model.labels.right, symbol: "plus.circle", side: .current, surface: model.currentSurface)
                }
            }
            HStack(spacing: 12) {
                Text(model.status).interfaceFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("editor-comparison-status")
                Spacer(minLength: 0)
                if !model.showsUnifiedDiff {
                    Toggle("Link Scrolling", isOn: Binding(get: { model.linksScrolling && model.canLinkScrolling },
                        set: model.setLinkedScrolling))
                        .disabled(!model.canLinkScrolling)
                        .help(model.canLinkScrolling ? "Keep matching lines together while scrolling" : "Line alignment needs a detailed comparison")
                }
            }
        }.padding(18)
    }
    private func unifiedVersion(_ title: String, symbol: String, side: String) -> some View {
        Label(title, systemImage: symbol).interfaceFont(.caption.weight(.medium))
            .lineLimit(1).truncationMode(.middle)
            .help(side + " · " + title).accessibilityLabel(side + ", " + title)
    }
    private func pane(_ title: String, symbol: String, side: EditorComparisonPlan.Side, surface: NativeTextEditorSurface) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).interfaceFont(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(title)
                if model.hasEditorSource(side) {
                    Spacer(minLength: 4)
                    let other = side == .before ? model.labels.right : model.labels.left
                    Button { model.applyChange(to: side) } label: {
                        Label("Take Change", systemImage: "arrow.down.doc").labelStyle(.iconOnly)
                    }
                    .disabled(!model.canApplyChange(to: side))
                    .accessibilityLabel("Take the selected change from \(other) into \(title)")
                    .help("Take the selected change from \(other) into \(title). Undo is available in that editor.")
                    Button { model.editAtChange(side) } label: {
                        Label("Edit at Change", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                    }
                    .disabled(!model.canEditAtChange(side))
                    .accessibilityLabel("Edit \(title) at selected change")
                    .help("Open this editor at the selected change")
                }
            }
            EditorComparisonSurface(surface: surface)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EditorComparisonSurface<Content: NSView>: NSViewRepresentable {
    let surface: Content
    func makeNSView(context: Context) -> Content { surface }
    func updateNSView(_ view: Content, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Content, context: Context) -> CGSize? {
        .init(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }
}

/// The ruler can show a small excerpt without opening another document.
/// Full review uses the original capture and the same detailed comparison.
@MainActor final class EditorUnsavedChangePreview: NSViewController {
    let diff = NSButton(title: "Open Full Diff", target: nil, action: nil)
    private let open: () -> Void

    init(_ change: EditorComparisonChange, capture: EditorComparisonCapture, open: @escaping () -> Void) {
        self.open = open
        super.init(nibName: nil, bundle: nil)
        let position = EditorComparisonWindow.ChangePosition(change, index: 0, total: 1)
        let title = NSTextField(labelWithString: "Unsaved Change")
        title.font = InterfaceMetrics.font(13, weight: .semibold)
        diff.target = self; diff.action = #selector(openDiff(_:)); diff.bezelStyle = .rounded
        diff.font = InterfaceMetrics.font(12); diff.keyEquivalent = "\r"; diff.keyEquivalentModifierMask = []
        diff.setAccessibilityIdentifier("editor-unsaved-open-full-diff")
        let saved = EditorChangeExcerpt.make("Saved · " + position.before, source: capture.left.text as NSString,
            range: change.beforeRange, accent: .removed)
        let edited = EditorChangeExcerpt.make("Edited · " + position.after, source: capture.right.text as NSString,
            range: change.currentRange, accent: .inserted)
        let stack = NSStackView(views: [title, saved, edited, diff])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = InterfaceMetrics.points(9)
        saved.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        edited.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let width = InterfaceMetrics.points(332), inset = InterfaceMetrics.points(13)
        view = NSView(frame: .init(x: 0, y: 0, width: width, height: stack.fittingSize.height + 2 * inset))
        view.setAccessibilityIdentifier("editor-unsaved-change-review")
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.defaultButtonCell = diff.cell as? NSButtonCell
        view.window?.makeFirstResponder(diff)
    }

    @objc private func openDiff(_ sender: Any?) { open() }
}

@MainActor enum EditorChangeExcerpt {
    static func choiceSize(in window: NSWindow) -> NSSize {
        .init(width: min(680, max(544, window.frame.width - 56)), height: InterfaceMetrics.points(285) + 30)
    }

    static func selectionPreview<Value: Sendable>(before: (name: String, text: String), after: (name: String, text: String),
                                                    change: @escaping (Value) -> EditorComparisonChange) -> NativeChoiceSheet<Value>.SelectionPreview {
        let saved = before.text as NSString, current = after.text as NSString
        return .init(height: 92) { value in
            let selected = change(value)
            let removed = make(before.name + " · " + selected.beforeLineLabel, source: saved,
                range: selected.beforeRange, accent: .removed)
            let inserted = make(after.name + " · " + selected.currentLineLabel, source: current,
                range: selected.currentRange, accent: .inserted)
            let excerpts = NSStackView(views: [removed, inserted])
            excerpts.orientation = .horizontal; excerpts.alignment = .top
            excerpts.distribution = .fillEqually; excerpts.spacing = InterfaceMetrics.points(10)
            excerpts.identifier = .init("editor-change-choice-preview")
            return excerpts
        }
    }

    static func make(_ title: String, source: NSString, range: NSRange, accent: EditorComparisonBackground.Accent) -> NSView {
        let heading = NSTextField(labelWithString: range.length == 0 ? title : accent.sign + "  " + title)
        heading.font = InterfaceMetrics.font(11, weight: .medium); heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.toolTip = title
        let stop = NSMaxRange(range)
        var end = min(stop, range.location + 320)
        if end < stop, end > range.location, (0xD800...0xDBFF).contains(source.character(at: end - 1)) { end -= 1 }
        let sample = source.substring(with: .init(location: range.location, length: end - range.location))
        var lines = sample.components(separatedBy: "\n")
        if sample.hasSuffix("\n") { lines.removeLast() }
        let preview = range.length == 0 ? ["No lines"] : Array(lines.prefix(3)) + (end < stop || lines.count > 3 ? ["…"] : [])
        let fields = preview.map { line in
            let label = NSTextField(labelWithString: line.isEmpty ? " " : line)
            label.font = .monospacedSystemFont(ofSize: InterfaceMetrics.points(11), weight: .regular)
            label.textColor = range.length == 0 ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }
        let excerpt = ExcerptLines(accent: range.length > 0 ? accent : nil, fields: fields)
        let block = NSStackView(views: [heading, excerpt])
        block.orientation = .vertical; block.alignment = .leading; block.spacing = InterfaceMetrics.points(3)
        excerpt.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    private final class ExcerptLines: NSStackView {
        let accent: EditorComparisonBackground.Accent?

        init(accent: EditorComparisonBackground.Accent?, fields: [NSTextField]) {
            self.accent = accent
            super.init(frame: .zero)
            orientation = .vertical; alignment = .leading; spacing = InterfaceMetrics.points(3)
            edgeInsets = .init(top: 3, left: 8, bottom: 3, right: 5)
            if let accent { identifier = .init(accent.identifier) }
            fields.forEach(addArrangedSubview)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if let accent { EditorComparisonBackground.Tint(accent, appearance: effectiveAppearance).fill(bounds, clippedTo: dirtyRect) }
        }
    }
}
