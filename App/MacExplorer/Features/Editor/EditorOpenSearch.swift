import AppKit
import ExplorerCore

/// Searches only existing native editor buffers. No file/session, persistence,
/// diagnostic, Save, replacement or export authority belongs to this feature.
@MainActor final class EditorOpenSearch: NSObject, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    enum Purpose { case find, compare, symbols, documentSymbols }
    struct Reference: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: UUID, generation: UUID
        let name: String, context: String
        let isEdited: Bool
        func identifies(_ other: Reference) -> Bool {
            id == other.id && name == other.name && context == other.context
        }
        var description: String { "<open editor reference>" }
        var debugDescription: String { description }
    }
    struct Buffer: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: UUID, generation: UUID
        let name: String, context: String, text: String
        var description: String { "<open editor buffer>" }
        var debugDescription: String { description }
    }
    struct Match: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: UUID, generation: UUID
        let name: String, context: String, excerpt: String
        let line: Int, range: NSRange
        var symbol: Symbol?
        var description: String { "<open editor match>" }
        var debugDescription: String { description }
    }
    struct Symbol: Sendable {
        let entry: EditorDocumentOutline.Entry
        let language: TextSyntaxLanguage
    }
    private struct Outline: Sendable {
        let id: UUID, generation: UUID
        let name: String, context: String
        let language: TextSyntaxLanguage
        let entries: [EditorDocumentOutline.Entry]
    }
    private enum Scope: Sendable {
        case text([Buffer], EditorFindOptions)
        case symbols([Outline])

        var count: Int {
            switch self {
            case .text(let buffers, _): buffers.count
            case .symbols(let outlines): outlines.count
            }
        }
    }
    private struct Input: Sendable {
        let epoch: UUID, scope: Scope, omitted: Int, query: String
    }
    private struct Output: Sendable {
        var matches: [Match] = []
        var limited = false
        var failure: EditorFindFailure?
    }
    nonisolated static let maximumBuffers = 16, maximumResults = 500
    private weak var owner: NativeTextEditorWindow?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var documents: [UUID: WeakDocument] = [:]
    private final class WeakDocument {
        weak var value: NativeTextEditorWindow?
        init(_ value: NativeTextEditorWindow) { self.value = value }
    }
    private var closeObservation: BrowserNotificationObservation?
    private var dismissing = false
    private var comparisonOrigin: Reference?
    private var searchOrigin: EditorDocumentNavigation.Location?
    private var purpose = Purpose.find
    private var candidates: [Reference] = []
    private let input = NativeQueryInput()
    private var epoch = UUID(), pending: Input?
    private var worker: Task<Void, Never>?, cancellation: EditorFindCancellation?
    private(set) var matches: [Match] = []
    private(set) var window: NSPanel?
    var isWorking: Bool { worker != nil || pending != nil }
    let query = NSSearchField(), table = NSTableView()
    let matchesCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    let matchMode = NSPopUpButton()
    let status = label("Type to search text already open in Traverse.", size: 11, color: .secondaryLabelColor)

    init(owner: NativeTextEditorWindow) { self.owner = owner; super.init() }

    func present(_ purpose: Purpose = .find) {
        guard window == nil, let owner, owner.canSearchOpenBuffer,
              let parent = owner.window, parent.isKeyWindow, parent.isVisible,
              parent.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if purpose == .compare {
            guard owner.canCompareOpenBuffer else { return }
            comparisonOrigin = owner.openEditorReference
        } else {
            searchOrigin = EditorDocumentNavigation.shared.location(in: owner)
        }
        self.purpose = purpose
        sourceWindow = parent; sourceResponder = parent.firstResponder
        query.delegate = input; query.target = self; query.action = #selector(searchChanged(_:))
        input.onChange = { [weak self] _ in self?.updateMatches() }
        input.onCommand = { [weak self] command in self?.handle(command) ?? false }
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activateSelection(_:))
        matchesCase.target = self; matchesCase.action = #selector(searchChanged(_:))
        if matchMode.numberOfItems == 0 { matchMode.addItems(withTitles: EditorFindMatchMode.allCases.map(\.title)) }
        matchMode.target = self; matchMode.action = #selector(searchChanged(_:))
        matchMode.setAccessibilityLabel("Text matching")
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(searchChanged(_:)))
        refresh.bezelStyle = .rounded; refresh.toolTip = "Read the current open editors again."
        let controls = NSStackView(views: purpose == .find ? [matchesCase, matchMode, NSView(), refresh] : [NSView(), refresh])
        controls.spacing = 12; controls.alignment = .centerY
        let panel: NSPanel
        switch purpose {
        case .find:
            panel = CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
                title: "Find in Open Editors", scope: "Search text already open in Traverse",
                searchLabel: "Find text in open editors", placeholder: "Find in open editors",
                resultsLabel: "Matching text in open editors", accessory: controls, settings: owner.commandDiscoverySettings)
        case .compare:
            panel = CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
                title: "Compare with Open Editor", scope: "Compare \(owner.openEditorReference.name) with another open buffer",
                searchLabel: "Find an open editor by name or location", placeholder: "Find an open editor",
                resultsLabel: "Open editors available to compare", settings: owner.commandDiscoverySettings)
        case .symbols, .documentSymbols:
            let thisFile = purpose == .documentSymbols
            panel = CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
                title: thisFile ? "Go to Symbol in This File" : "Go to Symbol in Open Editors",
                scope: thisFile ? owner.openEditorReference.name : "Find declarations, headings and keys in open outlines",
                searchLabel: thisFile ? "Find in this file’s outline" : "Find in open outlines",
                placeholder: "Find a symbol",
                resultsLabel: thisFile ? "Matching symbols in this file" : "Matching symbols in open editors", accessory: controls,
                settings: owner.commandDiscoverySettings)
        }
        window = panel; panel.delegate = self
        closeObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: parent) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        query.stringValue = purpose == .find ? (owner.surface.find.selectedQuery(maximumUnits: 256) ?? "") : ""
        updateMatches()
        CommandDiscoveryPresentation.position(panel, relativeTo: parent)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(query)
    }
    func updateMatches() {
        epoch = UUID(); pending = nil; cancellation?.cancel(); worker?.cancel()
        matches = []; candidates = []; documents = [:]
        guard window != nil, let owner else { return }
        let open = purpose == .documentSymbols ? [owner] : NativeTextEditorWindow.openSearchDocuments(preferred: owner)
        if comparisonOrigin != nil {
            let text = query.stringValue
            let peers = open.filter { $0 !== owner && $0.canCompareOpenBuffer }
            let filtered = text.utf8.count <= EditorFindPlan.maximumQueryBytes ? peers.filter {
                let candidate = $0.openEditorReference
                return text.isEmpty || candidate.name.localizedStandardContains(text) || candidate.context.localizedStandardContains(text)
            } : []
            let visible = filtered.prefix(Self.maximumBuffers)
            documents = Dictionary(uniqueKeysWithValues: visible.map { ($0.openSearchID, WeakDocument($0)) })
            candidates = visible.map(\.openEditorReference)
            if text.utf8.count > EditorFindPlan.maximumQueryBytes { status.stringValue = "Try a shorter name or location." }
            else if peers.isEmpty { status.stringValue = "Open another file in Traverse to compare it here." }
            else if candidates.isEmpty { status.stringValue = "No matching open editors." }
            else if filtered.count > candidates.count { status.stringValue = "Showing the first \(candidates.count) matches. Type to narrow the list." }
            else { status.stringValue = "↑ ↓ to choose · Return to compare · Esc to close" }
            reloadResults(); return
        }
        table.reloadData()
        let current = Array(open.prefix(Self.maximumBuffers))
        guard purpose != .find || !query.stringValue.isEmpty else {
            status.stringValue = "Type to search \(current.count) open editor\(current.count == 1 ? "" : "s")."
            return
        }
        guard query.stringValue.utf8.count <= EditorFindPlan.maximumQueryBytes else {
            status.stringValue = "Try a shorter search."; return
        }
        documents = Dictionary(uniqueKeysWithValues: current.map { ($0.openSearchID, WeakDocument($0)) })
        let scope: Scope
        switch purpose {
        case .find:
            let buffers = current.compactMap { $0.captureOpenSearchBuffer() }
            let options = EditorFindOptions(matchesCase: matchesCase.state == .on,
                matchMode: EditorFindMatchMode.allCases[max(0, matchMode.indexOfSelectedItem)])
            scope = .text(buffers, options)
        case .symbols, .documentSymbols:
            let outlines = current.compactMap { document -> Outline? in
                guard let outline = document.surface.currentOutlineForSymbols else { return nil }
                let reference = document.openEditorReference
                return .init(id: reference.id, generation: reference.generation, name: reference.name, context: reference.context,
                    language: outline.language, entries: outline.value.entries)
            }
            guard !outlines.isEmpty else {
                status.stringValue = purpose == .documentSymbols ? "This file’s outline is unavailable. Try Refresh."
                    : "No open editors have a current outline."
                return
            }
            scope = .symbols(outlines)
        case .compare:
            return
        }
        pending = .init(epoch: epoch, scope: scope, omitted: max(0, open.count - current.count), query: query.stringValue)
        status.stringValue = "Finding in \(scopeName(scope.count))…"
        startNext()
    }
    private func startNext() {
        guard worker == nil, window != nil, let input = pending else { return }
        pending = nil
        let flag = EditorFindCancellation(); cancellation = flag
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(45)) } catch { flag.cancel() }
            let output = Self.search(input, cancelled: { flag.isCancelled })
            await self?.complete(input, output: output, cancelled: flag.isCancelled)
        }
    }
    private nonisolated static func search(_ input: Input, cancelled: @Sendable () -> Bool) -> Output {
        if case .symbols(let outlines) = input.scope {
            return searchSymbols(outlines, query: input.query, omitted: input.omitted, cancelled: cancelled)
        }
        guard case .text(let buffers, let options) = input.scope else { return .init() }
        var output = Output()
        for buffer in buffers {
            if cancelled() { output.failure = .cancelled; return output }
            let remaining = maximumResults - output.matches.count
            guard remaining > 0 else { output.limited = true; break }
            switch EditorFindPlan.search(text: buffer.text, query: input.query, options: options,
                                         matchLimit: remaining, cancelled: cancelled) {
            case .refused(let failure): output.failure = failure; return output
            case .matches(let found):
                let lines = EditorLineIndex(buffer.text), source = buffer.text as NSString
                for range in found.ranges {
                    if cancelled() { output.failure = .cancelled; return output }
                    guard let hit = EditorFindPlan.excerpt(for: range, in: source, lines: lines) else {
                        output.failure = .invalidRanges; return output
                    }
                    output.matches.append(.init(id: buffer.id, generation: buffer.generation, name: buffer.name,
                        context: buffer.context, excerpt: hit.text, line: hit.line, range: range))
                }
                if !found.isComplete { output.limited = true; break }
            }
        }
        if input.omitted > 0 { output.limited = true }
        return output
    }

    private nonisolated static func searchSymbols(_ outlines: [Outline], query: String, omitted: Int,
                                                  cancelled: @Sendable () -> Bool) -> Output {
        let name = FilenameMatching.NavigationQuery(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var ranked = Array(repeating: [Match](), count: FilenameMatching.NavigationQuery.Rank.allCases.count)
        var output = Output()
        for outline in outlines {
            for entry in outline.entries {
                if cancelled() { output.failure = .cancelled; return output }
                guard let rank = name.rank(in: entry.title)?.rawValue else { continue }
                guard ranked[rank].count < maximumResults else { output.limited = true; continue }
                ranked[rank].append(.init(id: outline.id, generation: outline.generation, name: outline.name,
                    context: outline.context, excerpt: entry.title, line: entry.line,
                    range: .init(location: entry.offset, length: 0), symbol: .init(entry: entry, language: outline.language)))
            }
        }
        output.matches = Array(ranked.joined().prefix(maximumResults))
        output.limited = output.limited || omitted > 0 || ranked.reduce(0, { $0 + $1.count }) > maximumResults
        return output
    }
    private func complete(_ input: Input, output: Output, cancelled: Bool) {
        worker = nil; cancellation = nil
        if !cancelled, input.epoch == epoch, window != nil {
            matches = output.matches
            if let failure = output.failure {
                matches = []
                status.stringValue = failure == .queryTooLong ? "Try a shorter search." : "This text could not be searched. Refresh to try again."
            } else {
                let count = matches.count
                let scope = scopeName(input.scope.count)
                let kind = purpose == .find ? "text" : "symbols"
                let limitedScope = purpose == .documentSymbols ? scope : "up to \(Self.maximumBuffers) editors"
                status.stringValue = output.limited
                    ? "Showing \(count) matches in \(limitedScope) · refine your search."
                    : count == 0 ? "No matching \(kind) in \(scope)."
                    : "\(count) match\(count == 1 ? "" : "es") in \(scope) · Return to open · Esc to close"
            }
            reloadResults()
        }
        startNext()
    }
    private func scopeName(_ count: Int) -> String {
        purpose == .documentSymbols ? "this file" : "\(count) open editor\(count == 1 ? "" : "s")"
    }
    private func reloadResults() {
        table.reloadData()
        if numberOfRows(in: table) > 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }
    @objc private func searchChanged(_ sender: Any?) {
        guard window?.isKeyWindow == true,
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    private func handle(_ command: NativeQueryInput.Command) -> Bool {
        switch command {
        case .down: move(1)
        case .up: move(-1)
        case .submit: activateSelection(nil)
        case .cancel: window?.performClose(nil)
        }
        return true
    }
    private func move(_ delta: Int) {
        let count = numberOfRows(in: table)
        guard count > 0 else { return }
        let row = min(max(0, table.selectedRow + delta), count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc func activateSelection(_ sender: Any?) {
        guard window?.isKeyWindow == true, (0..<numberOfRows(in: table)).contains(table.selectedRow),
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if let origin = comparisonOrigin {
            let candidate = candidates[table.selectedRow]
            guard let owner, owner.canCompareOpenBuffer, owner.openEditorReference == origin else {
                status.stringValue = "Your editor changed. Reopen Compare with Open Editor to capture its current text."
                return
            }
            guard let peer = documents[candidate.id]?.value, peer.canCompareOpenBuffer, peer.openEditorReference == candidate else {
                updateMatches(); status.stringValue = "That editor changed or closed. Choose its current text."
                return
            }
            dismiss(restoringFocus: true)
            owner.compareOpenBuffers(origin, with: candidate, editor: peer)
            return
        }
        let match = matches[table.selectedRow]
        guard let owner, owner.canSearchOpenBuffer, let document = documents[match.id]?.value, document.canSearchOpenBuffer,
              document.surface.generation == match.generation, matchesCurrentSymbol(match, in: document) else {
            updateMatches(); status.stringValue = "That editor changed or closed. Updating the matches…"; return
        }
        let origin = searchOrigin.flatMap { $0.buffer == owner.openBufferIdentity ? $0 : nil }
        dismiss(restoringFocus: false)
        _ = document.revealOpenSearchMatch(match.range, generation: match.generation, returningTo: origin)
    }

    private func matchesCurrentSymbol(_ match: Match, in document: NativeTextEditorWindow) -> Bool {
        guard let symbol = match.symbol else { return true }
        guard let outline = document.surface.currentOutlineForSymbols, outline.language == symbol.language else { return false }
        return outline.value.entries.contains(symbol.entry)
    }
    func dismiss(restoringFocus: Bool, nativeCloseInProgress: Bool = false) {
        guard !dismissing else { return }; dismissing = true
        let parent = sourceWindow, responder = sourceResponder, wasKey = window?.isKeyWindow == true
        epoch = UUID(); pending = nil; cancellation?.cancel(); worker?.cancel()
        CommandDiscoveryPresentation.retire(window, nativeCloseInProgress: nativeCloseInProgress)
        window = nil
        closeObservation = nil; query.stringValue = ""; matches = []; documents = [:]
        comparisonOrigin = nil; searchOrigin = nil; purpose = .find; candidates = []; table.reloadData()
        sourceWindow = nil; sourceResponder = nil
        if restoringFocus, wasKey, let parent, parent.isVisible, parent.attachedSheet == nil,
           owner?.canDiscoverCommands == true {
            parent.makeKeyAndOrderFront(nil)
            if let responder, (responder as? NSView)?.window === parent { parent.makeFirstResponder(responder) }
        }
        dismissing = false
    }
    func closeAndDrain() async {
        dismiss(restoringFocus: false)
        if let worker { await worker.value }
    }
    func windowWillClose(_ notification: Notification) { dismiss(restoringFocus: true, nativeCloseInProgress: true) }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoringFocus: false) }
    func numberOfRows(in tableView: NSTableView) -> Int { comparisonOrigin == nil ? matches.count : candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if comparisonOrigin != nil {
            guard candidates.indices.contains(row) else { return nil }
            let candidate = candidates[row]
            let context = [candidate.isEdited ? "Unsaved" : "", candidate.context].filter { !$0.isEmpty }.joined(separator: " · ")
            let cell = CommandDiscoveryPresentation.row(title: candidate.name,
                category: context.isEmpty ? "Open editor" : context, shortcut: "↵", enabled: true)
            cell.toolTip = [candidate.name, context].filter { !$0.isEmpty }.joined(separator: "\n")
            return cell
        }
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        if match.symbol != nil {
            let line = "Line \(match.line)"
            let category = purpose == .documentSymbols ? line : "\(match.name) · \(line)"
            let cell = CommandDiscoveryPresentation.row(title: match.excerpt, category: category,
                shortcut: "↵", enabled: true)
            cell.toolTip = [match.context, match.name, line].filter { !$0.isEmpty }.joined(separator: "\n")
            return cell
        }
        let cell = CommandDiscoveryPresentation.row(title: "\(match.name) · Line \(match.line)",
            category: match.excerpt, shortcut: "↵", enabled: true)
        cell.toolTip = [match.context, "Line \(match.line)", match.excerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        return cell
    }
}
