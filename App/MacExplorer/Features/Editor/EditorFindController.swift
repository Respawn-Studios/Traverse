import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

@MainActor enum EditorFindMenu {
    static func items(target: AnyObject, selector: Selector, allowsReplacement: Bool) -> [NSMenuItem] {
        let commands: [(String, NSTextFinder.Action, String, NSEvent.ModifierFlags)] = [
            ("Find…", .showFindInterface, "f", .command),
            ("Find Next", .nextMatch, "g", .command),
            ("Find Previous", .previousMatch, "G", [.command, .shift]),
            ("Replace…", .showReplaceInterface, "f", [.command, .option]),
            ("Use Selection for Find", .setSearchString, "e", .command)
        ]
        return commands.compactMap { title, action, key, modifiers in
            guard allowsReplacement || action != .showReplaceInterface else { return nil }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target
            item.tag = action.rawValue
            item.keyEquivalentModifierMask = modifiers
            return item
        }
    }

    static func selectionItem(target: AnyObject, selector: Selector) -> NSMenuItem {
        BrowserMenus.item("Find in Selection…", selector, key: "l", modifiers: [.command, .option], target: target)
    }
}

final class EditorFindCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum EditorFindScopeLabel: Equatable {
    case selection, outline(String)

    var title: String {
        switch self { case .selection: "Selection"; case .outline(let name): name }
    }
}

/// One loaded-buffer search/replacement worker, one latest pending request.
/// A replacement is completely planned off the main actor, then admitted as
/// one native text insertion against the exact unchanged document generation.
@MainActor
final class EditorFindController {
    let bar = EditorFindBar(frame: .zero)
    private weak var surface: NativeTextEditorSurface?
    private var height: NSLayoutConstraint!
    private var epoch = UUID()
    private var heightTransition = UUID()
    private var matches: EditorFindMatches?
    private var matchedGeneration: UUID?
    private var options = EditorFindOptions()
    private enum Scope {
        case document, limited(NSRange, UUID, EditorFindScopeLabel), expired(EditorFindScopeLabel)
        var label: EditorFindScopeLabel? {
            switch self {
            case .document: nil
            case .limited(_, _, let label), .expired(let label): label
            }
        }
    }
    private var scope = Scope.document
    private var pending: Input?
    private var worker: Task<Void, Never>?
    private var cancellation: EditorFindCancellation?
    private var navigation: [Bool] = []
    private var invalidated = false
    private(set) var isShown = false
    private(set) var showsReplacement = false
    var motion: () -> BrowserMotionPreferences = { .init() }
    var isWorking: Bool { worker != nil }
    var matchCount: Int { matches?.ranges.count ?? 0 }
    var currentOptions: EditorFindOptions { options }
    private enum Work: Sendable {
        case search(String, String, EditorFindOptions, NSRange?)
        case replace(EditorFindMatches, String, TextDocumentFormat, Int?, NSRange, NSSelectionAffinity, Bool)
    }
    private struct Input: Sendable { let epoch: UUID; let generation: UUID; let work: Work }
    private enum Output: Sendable { case search(EditorFindSearchResult); case replace(EditorFindReplacementResult) }

    init(surface: NativeTextEditorSurface) {
        self.surface = surface
        bar.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(bar)
        height = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            bar.topAnchor.constraint(equalTo: surface.topAnchor), height
        ])
        bar.isHidden = true
        bar.onQuery = { [weak self] in self?.requestSearch() }
        bar.onReplacement = { [weak self] in self?.refreshControls() }
        bar.onCommand = { [weak self] action in self?.perform(action) }
        bar.onOptions = { [weak self] value in self?.setOptions(value) }
        bar.onSelectionScope = { [weak self] in self?.toggleSelectionScope() }
        bar.onWholeDocument = { [weak self] in self?.findInWholeDocument() }
    }

    func perform(_ action: NSTextFinder.Action) {
        guard !invalidated, let surface, surface.window?.attachedSheet == nil else { return }
        switch action {
        case .showFindInterface: show(replace: false)
        case .showReplaceInterface: if surface.textView.isEditable { show(replace: true) }
        case .hideFindInterface: hide()
        case .hideReplaceInterface: show(replace: false)
        case .nextMatch: navigate(backwards: false)
        case .previousMatch: navigate(backwards: true)
        case .replace: replace(all: false, thenFind: false)
        case .replaceAndFind: replace(all: false, thenFind: true)
        case .replaceAll: replace(all: true, thenFind: false)
        case .setSearchString:
            guard let selected = selectedQuery(allowsNewlines: true) else { return }
            let wasShown = isShown
            bar.query.stringValue = selected; show(replace: showsReplacement)
            if wasShown { requestSearch() }
        default: break
        }
    }
    func show(replace: Bool, focusReplacement: Bool = false) {
        guard !invalidated, let surface else { return }
        let wasShown = isShown
        isShown = true; showsReplacement = replace
        bar.isHidden = false; bar.secondRow.isHidden = !replace
        changeHeight(to: bar.presentationHeight)
        let field = focusReplacement ? bar.replacement : bar.query
        surface.window?.makeFirstResponder(field); field.selectText(nil)
        if !wasShown { requestSearch() } else { refreshControls() }
    }

    func replaceOccurrences(of query: String, wholeWord: Bool) {
        guard !invalidated, surface?.textView.isEditable == true else { return }
        let wasShown = isShown
        scope = .document
        options.matchesCase = true
        options.matchMode = wholeWord ? .wholeWord : .contains
        bar.setOptions(options)
        bar.query.stringValue = query
        bar.replacement.stringValue = ""
        show(replace: true, focusReplacement: true)
        if wasShown { requestSearch() }
    }
    var canFindInSelection: Bool {
        guard !invalidated, let surface, surface.window?.attachedSheet == nil,
              !surface.textView.hasMarkedText(), !bar.queryHasMarkedText,
              surface.textView.selectedRanges.count == 1 else { return false }
        return surface.textView.selectedRange().length > 0
    }

    func selectedQuery(maximumUnits: Int = EditorFindPlan.maximumQueryBytes, allowsNewlines: Bool = false) -> String? {
        guard canFindInSelection, !bar.replacementHasMarkedText, let editor = surface?.textView else { return nil }
        let selection = editor.selectedRange(), text = editor.string
        guard selection.length <= maximumUnits, let range = Range(selection, in: text) else { return nil }
        let query = String(text[range])
        guard query.utf8.count <= EditorFindPlan.maximumQueryBytes,
              allowsNewlines || query.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return query
    }

    func findInSelection() {
        guard canFindInSelection, let surface else { return }
        find(within: surface.textView.selectedRange(), label: .selection, generation: surface.generation)
    }

    func findInCurrentScope() {
        guard !invalidated, !bar.queryHasMarkedText, !bar.replacementHasMarkedText,
              let surface, let current = surface.currentSearchScope else { return }
        find(within: current.range, label: .outline(current.name), generation: surface.generation)
    }

    private func find(within range: NSRange, label: EditorFindScopeLabel, generation: UUID) {
        scope = .limited(range, generation, label)
        let wasShown = isShown
        show(replace: showsReplacement)
        if wasShown { requestSearch() }
    }

    private func toggleSelectionScope() {
        if scope.label == .selection { findInWholeDocument() }
        else { findInSelection() }
    }

    private func findInWholeDocument() {
        scope = .document
        requestSearch()
    }
    func applyInterfaceScale(_ value: CGFloat) {
        guard bar.applyInterfaceScale(value) else { return }
        if isShown { changeHeight(to: bar.presentationHeight) }
    }
    func hide() {
        guard isShown else { return }
        isShown = false; scope = .document
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface?.textView.findHighlights = []; surface?.textView.currentFindHighlight = nil
        surface?.window?.makeFirstResponder(surface?.textView)
        changeHeight(to: 0)
        refreshControls()
    }
    private func changeHeight(to value: CGFloat) {
        guard let surface else { return }
        surface.layoutSubtreeIfNeeded()
        let preferences = motion()
        let duration = preferences.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && surface.window?.isVisible == true ? 0.14 * preferences.mode.durationScale : 0
        let ticket = UUID(); heightTransition = ticket
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration; context.allowsImplicitAnimation = duration > 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            height.constant = value
            surface.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.heightTransition == ticket, !self.isShown else { return }
                self.bar.isHidden = true
            }
        }
    }
    func setOptions(_ value: EditorFindOptions) {
        options = value; bar.setOptions(value); requestSearch()
    }
    func documentDidChange() {
        if case .limited(_, let generation, let label) = scope, generation != surface?.generation { scope = .expired(label) }
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface?.textView.findHighlights = []; surface?.textView.currentFindHighlight = nil
        if isShown { requestSearch() } else { refreshControls() }
    }

    func outlineLanguageDidChange() {
        guard case .limited(_, _, let label) = scope, case .outline = label else { return }
        scope = .expired(label)
        requestSearch()
    }
    func inputSettled() {
        if isShown, matches == nil, worker == nil, surface?.textView.hasMarkedText() == false { requestSearch() }
    }
    func selectionDidChange() {
        guard isShown else { return }
        refreshControls()
    }
    func clear() {
        invalidated = true; isShown = false; showsReplacement = false
        scope = .document
        heightTransition = UUID()
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface?.textView.findHighlights = []; surface?.textView.currentFindHighlight = nil
        bar.clear(); height.constant = 0; bar.isHidden = true
    }
    func drain() async { await worker?.value }
    private func invalidateWork() {
        epoch = UUID(); pending = nil; navigation = []
        cancellation?.cancel(); worker?.cancel()
    }
    private func requestSearch() {
        guard !invalidated, isShown, let surface else { return }
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface.textView.findHighlights = []; surface.textView.currentFindHighlight = nil
        bar.notice.stringValue = ""
        guard !surface.textView.hasMarkedText(), !bar.queryHasMarkedText else { bar.count.stringValue = ""; refreshControls(); return }
        let selection: NSRange?
        switch scope {
        case .document: selection = nil
        case .limited(let range, let generation, _) where generation == surface.generation: selection = range
        case .limited(_, _, let label), .expired(let label):
            scope = .expired(label)
            let selection = label == .selection
            bar.count.stringValue = selection ? "Select text again" : "Scope changed"
            bar.count.toolTip = selection
                ? "The selected text changed. Select text again or turn off Find in Selection."
                : "Choose Find in Current Scope again, or choose Search Whole Document in Find options."
            refreshControls(); return
        }
        bar.count.toolTip = nil
        pending = .init(epoch: epoch, generation: surface.generation,
                        work: .search(surface.textView.string, bar.query.stringValue, options, selection))
        bar.count.stringValue = bar.query.stringValue.isEmpty ? "" : "Finding…"
        startNext(); refreshControls()
    }
    private func startNext() {
        guard worker == nil, !invalidated, let input = pending else { return }
        pending = nil
        let flag = EditorFindCancellation(); cancellation = flag
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let output: Output
            switch input.work {
            case .search(let text, let query, let options, let scope):
                // Debounce within the single owned task. New input cancels it
                // and replaces one pending snapshot; it never fans out workers.
                do { try await Task.sleep(for: .milliseconds(45)) } catch { flag.cancel() }
                output = .search(EditorFindPlan.search(text: text, query: query, options: options, within: scope,
                                                       cancelled: { flag.isCancelled }))
            case .replace(let matches, let text, let format, let index, _, _, _):
                output = .replace(EditorFindPlan.replace(matches, with: text, format: format,
                                                         only: index, cancelled: { flag.isCancelled }))
            }
            await self?.complete(input, output: output, cancelled: flag.isCancelled)
        }
    }
    private func complete(_ input: Input, output: Output, cancelled: Bool) {
        worker = nil; cancellation = nil
        defer { startNext(); refreshControls() }
        guard !cancelled, !invalidated, isShown, input.epoch == epoch,
              let surface, surface.generation == input.generation,
              !surface.textView.hasMarkedText() else { return }
        switch output {
        case .search(.matches(let value)):
            guard !bar.queryHasMarkedText, value.query == bar.query.stringValue, value.options == options,
                  surface.textView.string.utf16.elementsEqual(value.text.utf16) else { return }
            matches = value; matchedGeneration = input.generation
            surface.textView.findHighlights = value.highlightRanges
            let queued = navigation; navigation = []
            for backwards in queued { navigate(backwards: backwards) }
        case .search(.refused(let reason)): showFailure(reason)
        case .replace(let result):
            guard case .replace(let previousMatches, let replacement, _, _, let selection, let affinity, let thenFind) = input.work,
                  surface.textView.selectedRanges.count == 1,
                  surface.textView.selectedRange() == selection, surface.textView.selectionAffinity == affinity,
                  !bar.queryHasMarkedText, !bar.replacementHasMarkedText,
                  surface.textView.isEditable, surface.window?.isKeyWindow == true,
                  surface.window?.attachedSheet == nil else { return }
            guard bar.replacement.stringValue.utf16.elementsEqual(replacement.utf16) else {
                bar.notice.stringValue = "Replacement text changed"
                return
            }
            switch result {
            case .unchanged:
                bar.notice.stringValue = "No changes"
                if thenFind { navigate(backwards: false) }
            case .refused(let reason): showFailure(reason)
            case .invalidText(let reason):
                surface.onRejectedEdit?(reason); bar.notice.stringValue = "This replacement cannot be used."
            case .replace(let plan):
                let selectionScope = scope.label == .selection
                guard surface.applyFindReplacement(plan, generation: input.generation) else {
                    bar.notice.stringValue = "The document changed. Try again."; return
                }
                if selectionScope, let captured = previousMatches.selection {
                    let length = captured.length + plan.value.utf16Count - previousMatches.utf16Length
                    scope = length > 0 ? .limited(.init(location: captured.location, length: length), surface.generation, .selection) : .expired(.selection)
                    requestSearch()
                }
                bar.notice.stringValue = plan.count == 1 ? "Replaced 1 match" : "Replaced \(plan.count) matches"
                if thenFind { navigation = [false] }
            }
        }
    }
    private func navigate(backwards: Bool) {
        guard let surface, !invalidated else { return }
        if !isShown { show(replace: false) }
        guard let matches, matchedGeneration == surface.generation,
              matches.query == bar.query.stringValue, matches.options == options,
              !surface.textView.hasMarkedText(), !bar.queryHasMarkedText else {
            if navigation.count < 32 { navigation.append(backwards) }; return
        }
        guard let index = matches.nextIndex(from: surface.textView.selectedRange(), backwards: backwards) else {
            bar.notice.stringValue = "No more matches"; return
        }
        let range = matches.ranges[index]
        surface.revealFoldedText(range)
        surface.textView.setSelectedRange(range)
        surface.textView.scrollRangeToVisible(range)
        refreshControls()
    }
    private func replace(all: Bool, thenFind: Bool) {
        guard !invalidated, isShown, worker == nil, let surface, let matches,
              matchedGeneration == surface.generation, matches.isComplete,
              matches.query == bar.query.stringValue, matches.options == options,
              surface.textView.isEditable, !surface.textView.hasMarkedText(), !bar.queryHasMarkedText, !bar.replacementHasMarkedText,
              surface.textView.selectedRanges.count == 1, surface.window?.isKeyWindow == true,
              surface.window?.attachedSheet == nil,
              surface.textView.string.utf16.elementsEqual(matches.text.utf16), !matches.ranges.isEmpty else { return }
        let index = all ? nil : exactSelectedMatch() ?? matches.nextIndex(from: surface.textView.selectedRange(), backwards: false)
        if !all && index == nil { return }
        invalidateWork()
        pending = .init(epoch: epoch, generation: surface.generation,
            work: .replace(matches, bar.replacement.stringValue, surface.documentFormat, index,
                           surface.textView.selectedRange(), surface.textView.selectionAffinity, thenFind))
        startNext(); refreshControls()
    }
    private func exactSelectedMatch() -> Int? {
        guard let surface, let ranges = matches?.ranges else { return nil }
        let selection = surface.textView.selectedRange()
        var low = 0, high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].location < selection.location { low = middle + 1 } else { high = middle }
        }
        return low < ranges.count && ranges[low] == selection ? low : nil
    }
    private func refreshControls() {
        bar.setScope(scope.label, canSelect: canFindInSelection || scope.label == .selection)
        let ready = isShown && !invalidated && worker == nil && pending == nil
            && surface?.textView.hasMarkedText() == false && !bar.queryHasMarkedText && matchedGeneration == surface?.generation
        let found = ready && matches?.ranges.isEmpty == false
        bar.previous.isEnabled = found; bar.next.isEnabled = found
        let canReplace = found && matches?.isComplete == true && surface?.textView.isEditable == true
            && surface?.textView.selectedRanges.count == 1 && !bar.replacementHasMarkedText
        bar.replace.isEnabled = canReplace; bar.replaceAll.isEnabled = canReplace
        if let matches, ready {
            if matches.query.isEmpty { bar.count.stringValue = "" }
            else if let index = exactSelectedMatch() { bar.count.stringValue = "\(index + 1) of \(matches.ranges.count)" }
            else {
                let count = matches.ranges.count
                bar.count.stringValue = count == 0 ? "No matches" : "\(count) \(count == 1 ? "match" : "matches")"
            }
            if let index = exactSelectedMatch() { surface?.textView.currentFindHighlight = matches.ranges[index] }
            else { surface?.textView.currentFindHighlight = nil }
        }
    }
    private func showFailure(_ reason: EditorFindFailure) {
        let message: String
        switch reason {
        case .queryTooLong: message = "Use a shorter search."
        case .documentTooLarge: message = "The replacement would make this document too large."
        case .tooManyMatches: message = "Not all matches are ready. Try again."
        case .invalidRanges: message = "The document changed. Try again."
        case .cancelled: return
        }
        bar.notice.stringValue = message; bar.count.stringValue = message; bar.count.toolTip = message
    }
}
