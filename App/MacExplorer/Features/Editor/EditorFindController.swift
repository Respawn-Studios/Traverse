import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

final class EditorFindCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
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
        case search(String, String, EditorFindOptions)
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
    }

    func perform(_ action: NSTextFinder.Action) {
        guard !invalidated, let surface, surface.window?.attachedSheet == nil else { return }
        switch action {
        case .showFindInterface: show(replace: false)
        case .showReplaceInterface: show(replace: true)
        case .hideFindInterface: hide()
        case .hideReplaceInterface: show(replace: false)
        case .nextMatch: navigate(backwards: false)
        case .previousMatch: navigate(backwards: true)
        case .replace: replace(all: false, thenFind: false)
        case .replaceAndFind: replace(all: false, thenFind: true)
        case .replaceAll: replace(all: true, thenFind: false)
        case .setSearchString:
            let text = surface.textView.string as NSString, range = surface.textView.selectedRange()
            guard range.location >= 0, range.length > 0, range.location <= text.length,
                  range.length <= text.length - range.location else { return }
            let selected = text.substring(with: range)
            guard selected.utf8.count <= EditorFindPlan.maximumQueryBytes else { return }
            let wasShown = isShown
            bar.query.stringValue = selected; show(replace: showsReplacement)
            if wasShown { requestSearch() }
        default: break
        }
    }
    func show(replace: Bool) {
        guard !invalidated, let surface else { return }
        let wasShown = isShown
        isShown = true; showsReplacement = replace
        bar.isHidden = false; bar.secondRow.isHidden = !replace
        changeHeight(to: bar.presentationHeight)
        surface.window?.makeFirstResponder(bar.query); bar.query.selectText(nil)
        if !wasShown { requestSearch() } else { refreshControls() }
    }
    func applyInterfaceScale(_ value: CGFloat) {
        guard bar.applyInterfaceScale(value) else { return }
        if isShown { changeHeight(to: bar.presentationHeight) }
    }
    func hide() {
        guard isShown else { return }
        isShown = false
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
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface?.textView.findHighlights = []; surface?.textView.currentFindHighlight = nil
        if isShown { requestSearch() } else { refreshControls() }
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
        heightTransition = UUID()
        invalidateWork(); matches = nil; matchedGeneration = nil
        surface?.textView.findHighlights = []; surface?.textView.currentFindHighlight = nil
        bar.clear(); height.constant = 0; bar.isHidden = true
    }
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
        pending = .init(epoch: epoch, generation: surface.generation,
                        work: .search(surface.textView.string, bar.query.stringValue, options))
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
            case .search(let text, let query, let options):
                // Debounce within the single owned task. New input cancels it
                // and replaces one pending snapshot; it never fans out workers.
                do { try await Task.sleep(for: .milliseconds(45)) } catch { flag.cancel() }
                output = .search(EditorFindPlan.search(text: text, query: query, options: options,
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
            guard case .replace(_, _, _, _, let selection, let affinity, let thenFind) = input.work,
                  surface.textView.selectedRanges.count == 1,
                  surface.textView.selectedRange() == selection, surface.textView.selectionAffinity == affinity,
                  !bar.queryHasMarkedText, !bar.replacementHasMarkedText,
                  surface.textView.isEditable, surface.window?.isKeyWindow == true,
                  surface.window?.attachedSheet == nil else { return }
            switch result {
            case .unchanged:
                bar.notice.stringValue = "No changes"
                if thenFind { navigate(backwards: false) }
            case .refused(let reason): showFailure(reason)
            case .invalidText(let reason):
                surface.onRejectedEdit?(reason); bar.notice.stringValue = "This replacement cannot be used."
            case .replace(let plan):
                guard surface.applyFindReplacement(plan, generation: input.generation) else {
                    bar.notice.stringValue = "The document changed. Try again."; return
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
            else { bar.count.stringValue = matches.ranges.isEmpty ? "No matches" : "\(matches.ranges.count) matches" }
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
