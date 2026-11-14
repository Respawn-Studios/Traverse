import AppKit

/// Searches only existing native editor buffers. No file/session, persistence,
/// diagnostic, Save, replacement or export authority belongs to this feature.
@MainActor final class EditorOpenSearch: NSObject, NSWindowDelegate,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
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
        var description: String { "<open editor match>" }
        var debugDescription: String { description }
    }
    private struct Input: Sendable {
        let epoch: UUID, buffers: [Buffer], omitted: Int, query: String, options: EditorFindOptions
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

    func present() {
        guard window == nil, let owner, owner.canSearchOpenBuffer,
              let parent = owner.window, parent.isKeyWindow, parent.isVisible,
              parent.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        sourceWindow = parent; sourceResponder = parent.firstResponder
        query.delegate = self; query.target = self; query.action = #selector(searchChanged(_:))
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activateSelection(_:))
        matchesCase.target = self; matchesCase.action = #selector(searchChanged(_:))
        if matchMode.numberOfItems == 0 { matchMode.addItems(withTitles: EditorFindMatchMode.allCases.map(\.title)) }
        matchMode.target = self; matchMode.action = #selector(searchChanged(_:))
        matchMode.setAccessibilityLabel("Text matching")
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(searchChanged(_:)))
        refresh.bezelStyle = .rounded; refresh.toolTip = "Search the current text in open editors again."
        let controls = NSStackView(views: [matchesCase, matchMode, NSView(), refresh])
        controls.spacing = 12; controls.alignment = .centerY
        let panel = CommandDiscoveryPresentation.makePanel(query: query, table: table, status: status,
            title: "Find in Open Editors", scope: "Only text already open in Traverse · no files or folders are scanned",
            searchLabel: "Find text in open editors", placeholder: "Find in open editors",
            resultsLabel: "Matching text in open editors", accessory: controls, settings: owner.commandDiscoverySettings)
        window = panel; panel.delegate = self
        closeObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: parent) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        let selected = owner.surface.textView.selectedRange(), text = owner.surface.textView.string as NSString
        if selected.length > 0, selected.length <= 256, selected.location >= 0,
           selected.location <= text.length, selected.length <= text.length - selected.location {
            let value = text.substring(with: selected)
            query.stringValue = value.rangeOfCharacter(from: .newlines) == nil ? value : ""
        } else { query.stringValue = "" }
        updateMatches()
        CommandDiscoveryPresentation.position(panel, relativeTo: parent)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(query)
        CommandDiscoveryPresentation.animateEntrance(panel,
            motion: owner.commandDiscoverySettings?.motion ?? InterfacePresentation.shared.motion)
    }
    func updateMatches() {
        epoch = UUID(); pending = nil; cancellation?.cancel(); worker?.cancel()
        matches = []; table.reloadData()
        guard window != nil, let owner else { return }
        let open = NativeTextEditorWindow.openSearchDocuments(preferred: owner)
        let current = Array(open.prefix(Self.maximumBuffers))
        documents = Dictionary(uniqueKeysWithValues: current.map { ($0.openSearchID, WeakDocument($0)) })
        let buffers = current.compactMap { $0.captureOpenSearchBuffer() }
        guard !query.stringValue.isEmpty else {
            status.stringValue = "Type to search \(buffers.count) open editor\(buffers.count == 1 ? "" : "s")."
            return
        }
        guard query.stringValue.utf8.count <= EditorFindPlan.maximumQueryBytes else {
            status.stringValue = "Try a shorter search."; return
        }
        let options = EditorFindOptions(matchesCase: matchesCase.state == .on,
            matchMode: EditorFindMatchMode.allCases[max(0, matchMode.indexOfSelectedItem)])
        pending = .init(epoch: epoch, buffers: buffers, omitted: max(0, open.count - buffers.count),
            query: query.stringValue, options: options)
        status.stringValue = "Finding in \(buffers.count) open editors…"; startNext()
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
        var output = Output()
        for buffer in input.buffers {
            if cancelled() { output.failure = .cancelled; return output }
            let remaining = maximumResults - output.matches.count
            guard remaining > 0 else { output.limited = true; break }
            switch EditorFindPlan.search(text: buffer.text, query: input.query, options: input.options,
                                         matchLimit: remaining, cancelled: cancelled) {
            case .refused(let failure): output.failure = failure; return output
            case .matches(let found):
                let lines = EditorLineIndex(buffer.text), source = buffer.text as NSString
                for range in found.ranges {
                    if cancelled() { output.failure = .cancelled; return output }
                    guard let location = lines.location(at: range.location), let start = lines.start(ofLine: location.line) else {
                        output.failure = .invalidRanges; return output
                    }
                    let end = lines.start(ofLine: location.line + 1).map { max(start, $0 - 1) } ?? source.length
                    var from = max(start, range.location - 60), to = min(end, range.location + min(range.length, 80) + 80)
                    // Keep snippets small even on a one-megabyte line and do
                    // not split a UTF-16 surrogate at either display edge.
                    if from > 0, from < source.length, (0xDC00...0xDFFF).contains(source.character(at: from)) { from -= 1 }
                    if to > 0, to < source.length, (0xDC00...0xDFFF).contains(source.character(at: to)) { to += 1 }
                    let excerpt = (from > start ? "…" : "")
                        + source.substring(with: .init(location: from, length: max(0, to - from)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        + (to < end ? "…" : "")
                    output.matches.append(.init(id: buffer.id, generation: buffer.generation, name: buffer.name,
                        context: buffer.context, excerpt: excerpt, line: location.line, range: range))
                }
                if !found.isComplete { output.limited = true; break }
            }
        }
        if input.omitted > 0 { output.limited = true }
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
                let scope = "\(input.buffers.count) open editor\(input.buffers.count == 1 ? "" : "s")"
                status.stringValue = output.limited
                    ? "Showing \(count) matches in up to \(Self.maximumBuffers) editors · refine your search."
                    : count == 0 ? "No matching text in \(scope)."
                    : "\(count) match\(count == 1 ? "" : "es") in \(scope) · Return to open · Esc to close"
            }
            table.reloadData()
            if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
        }
        startNext()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === query,
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    @objc private func searchChanged(_ sender: Any?) {
        guard window?.isKeyWindow == true,
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateMatches()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === query, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(nil); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(restoringFocus: true); return true
        default: return false
        }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc func activateSelection(_ sender: Any?) {
        guard window?.isKeyWindow == true, matches.indices.contains(table.selectedRow),
              (query.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let match = matches[table.selectedRow]
        guard let document = documents[match.id]?.value, document.canSearchOpenBuffer,
              document.surface.generation == match.generation else {
            updateMatches(); status.stringValue = "That editor changed or closed. Updating the matches…"; return
        }
        dismiss(restoringFocus: false)
        _ = document.revealOpenSearchMatch(match.range, generation: match.generation)
    }
    func dismiss(restoringFocus: Bool) {
        guard !dismissing else { return }; dismissing = true
        let parent = sourceWindow, responder = sourceResponder, wasKey = window?.isKeyWindow == true
        epoch = UUID(); pending = nil; cancellation?.cancel(); worker?.cancel()
        window?.delegate = nil; window?.orderOut(nil); window?.close(); window = nil
        closeObservation = nil; query.stringValue = ""; matches = []; documents = [:]; table.reloadData()
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
    func windowWillClose(_ notification: Notification) { dismiss(restoringFocus: true) }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoringFocus: false) }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        let cell = CommandDiscoveryPresentation.row(title: "\(match.name) · Line \(match.line)",
            category: match.excerpt, shortcut: "↵", enabled: true)
        cell.toolTip = [match.context, "Line \(match.line)", match.excerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        return cell
    }
}
