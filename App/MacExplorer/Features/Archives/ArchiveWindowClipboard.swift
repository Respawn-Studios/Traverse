import AppKit

/// Standalone ZIP/TAR windows use the workspace's private clipboard and the
/// existing archive models. This adapter owns no file work or pasteboard data.
@MainActor final class ArchiveWindowClipboard {
    private weak var zip: ArchiveBrowserModel?
    private weak var tar: TARBrowserModel?
    private weak var browser: BrowserViewController?
    private weak var state: BrowserClipboardState?
    private weak var table: ArchiveMetadataTable?
    weak var window: NSWindow?
    private var observation: UUID?
    private var retired = false

    init(zip: ArchiveBrowserModel) { self.zip = zip }
    init(tar: TARBrowserModel) { self.tar = tar }

    func attach(to browser: BrowserViewController) {
        if state !== browser.clipboardState {
            if let observation { state?.removeObserver(observation) }
            state = browser.clipboardState
            observation = browser.clipboardState.observe { [weak self] in self?.refreshAppearance() }
        }
        self.browser = browser
    }

    func retire() {
        retired = true
        if state?.scopedItem?.archiveWindowOwner === self { state?.clear() }
        if let observation { state?.removeObserver(observation) }
        observation = nil; state = nil; browser = nil; table = nil
    }

    private var available: Bool {
        !retired && browser?.isBrowserSuspended == false && !ApplicationFileActivity.gate.isClosed
            && !GeneratedSandboxReview.publicationOnlyReviewAdmitted
    }
    private var hasCommandFocus: Bool {
        available && window?.isKeyWindow == true && window?.attachedSheet == nil
            && table != nil && window?.firstResponder === table
    }

    func bind(_ rows: ArchiveMetadataRows) {
        table = rows.table
        rows.onCut = { [weak self] in self?.capture(.move) }
        rows.onCopyMembers = { [weak self] in self?.capture(.copy) }
        rows.canCaptureClipboard = { [weak self] in self?.canCapture($0) == true }
        rows.onPaste = { [weak self] in self?.paste() }
        rows.canPaste = { [weak self] in self?.canPaste == true }
        rows.isCut = { [weak self] id in
            guard let self, let intent = state?.scopedItem, intent.archiveWindowOwner === self,
                  intent.operation == .move, case .zip(let source) = intent.source else { return false }
            return zip?.showsCut(source) == true && source.ids.contains(id)
        }
        configure(rows.table)
    }
    func bind(_ rows: TARMetadataRows) {
        table = rows.table
        rows.onCut = { [weak self] in self?.capture(.move) }
        rows.onCopyMembers = { [weak self] in self?.capture(.copy) }
        rows.canCaptureClipboard = { [weak self] in self?.canCapture($0) == true }
        rows.onPaste = { [weak self] in self?.paste() }
        rows.canPaste = { [weak self] in self?.canPaste == true }
        rows.isCut = { [weak self] id in
            guard let self, let intent = state?.scopedItem, intent.archiveWindowOwner === self,
                  intent.operation == .move, case .tar(let source) = intent.source else { return false }
            return tar?.showsCut(source) == true && source.ids.contains(id)
        }
        configure(rows.table)
    }
    private func configure(_ table: ArchiveMetadataTable) {
        table.onCut = { [weak self] in self?.capture(.move) }
        table.onCopy = { [weak self] in self?.capture(.copy) }
        table.onPaste = { [weak self] in self?.paste() }
        table.commandValidation = { [weak self, weak table] action in
            switch action {
            case #selector(FileTableView.cut(_:)), #selector(BrowserViewController.cutFileURLs(_:)):
                return self?.canCapture(.move) == true
            case #selector(FileTableView.copy(_:)), #selector(BrowserViewController.copyFileURLs(_:)):
                return self?.canCapture(.copy) == true
            case #selector(FileTableView.paste(_:)), #selector(BrowserViewController.pasteFileURLs(_:)):
                return self?.canPaste == true
            default: return self?.hasCommandFocus == true && table?.memberCommandEnabled(action) == true
            }
        }
    }
    private func refreshAppearance() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.upperBound),
                         columnIndexes: IndexSet(integer: 0))
    }

    private func canCapture(_ operation: TransferClipboardFeedback.Intent) -> Bool {
        hasCommandFocus && (zip?.canCaptureClipboardMembers(operation) == true
            || tar?.canCaptureClipboardMembers(operation) == true)
    }
    private func capture(_ operation: TransferClipboardFeedback.Intent) {
        guard canCapture(operation), let browser, let state, state === browser.clipboardState else { return }
        let board = state.pasteboard, revision = state.revision, count = board.changeCount
        let publish: (ScopedItemClipboardIntent) -> Void = { [weak self, weak browser, weak state] intent in
            guard let self, let browser, let state, hasCommandFocus,
                  self.browser === browser, self.state === state, browser.clipboardState === state,
                  state.revision == revision, state.pasteboard === board, board.changeCount == count else { return }
            browser.publishScopedClipboard(intent)
        }
        if let zip { zip.captureClipboardMembers(operation) { [weak self] source in
            if let self { publish(.init(owner: self, source: source, operation: operation)) }
        } }
        else if let tar { tar.captureClipboardMembers(operation) { [weak self] source in
            if let self { publish(.init(owner: self, source: source, operation: operation)) }
        } }
    }

    func retains(_ source: ZIPClipboardSource) -> Bool { available && zip?.retainsClipboard(source) == true }
    func retains(_ source: TARClipboardSource) -> Bool { available && tar?.retainsClipboard(source) == true }
    func matches(_ source: ZIPClipboardSource, in browser: BrowserViewController) -> Bool {
        hasCommandFocus && self.browser === browser && zip?.matchesClipboardSelection(source) == true
    }
    func matches(_ source: TARClipboardSource, in browser: BrowserViewController) -> Bool {
        hasCommandFocus && self.browser === browser && tar?.matchesClipboardSelection(source) == true
    }
    func canExport(_ source: ZIPClipboardSource) -> Bool { available && zip?.canExportClipboard(source) == true }
    func canExport(_ source: TARClipboardSource) -> Bool { available && tar?.canExportClipboard(source) == true }
    func export(_ source: ZIPClipboardSource, context: ScopedItemPaste, to browser: BrowserViewController) {
        guard canExport(source) else { return }; zip?.exportClipboard(source, context: context, to: browser)
    }
    func export(_ source: TARClipboardSource, context: ScopedItemPaste, to browser: BrowserViewController) {
        guard canExport(source) else { return }; tar?.exportClipboard(source, context: context, to: browser)
    }

    private var canAdd: Bool { zip?.canAddMembersInCopy == true || tar?.canCreateMember == true }
    private var canPaste: Bool {
        guard hasCommandFocus, let state else { return false }
        if state.pasteboard.availableType(from: [ScopedItemClipboardIntent.pasteboardType]) != nil {
            guard let context = ScopedItemPaste(state: state), context.isCurrent(),
                  context.intent.archiveWindowOwner === self else { return false }
            switch context.intent.source {
            case .zip(let source): return zip?.canPasteMembers(source, operation: context.intent.operation) == true
            case .tar(let source): return tar?.canPasteMembers(source, operation: context.intent.operation) == true
            default: return false
            }
        }
        guard canAdd, state.pendingCut == nil, state.cutPreparation == nil,
              let capture = state.readFiles(allowOwnedCopy: false) else { return false }
        return (1...511).contains(capture.urls.count) && capture.isCurrent(on: state.pasteboard)
    }
    private func paste() {
        guard canPaste, let state else { return }
        if state.pasteboard.availableType(from: [ScopedItemClipboardIntent.pasteboardType]) != nil {
            guard let context = ScopedItemPaste(state: state), context.isCurrent(),
                  context.intent.archiveWindowOwner === self else { return }
            switch context.intent.source {
            case .zip(let source): zip?.pasteMembers(source, context: context)
            case .tar(let source): tar?.pasteMembers(source, context: context)
            default: break
            }
            return
        }
        let board = state.pasteboard, revision = state.revision
        guard let capture = state.readFiles(allowOwnedCopy: false), capture.isCurrent(on: board),
              (1...511).contains(capture.urls.count) else { return }
        let input = ArchiveAdditionInput(urls: capture.urls, isCurrent: { [weak self, weak state] in
            guard let self, let state else { return false }
            return available && self.state === state && state.revision == revision && state.pasteboard === board
                && state.pendingCut == nil && state.cutPreparation == nil && capture.isCurrent(on: board)
        })
        if let zip { _ = zip.addCopiedFiles(input, updateOriginal: ZIPOriginalUpdateFeature.available) }
        else { tar?.reviewMutation(.add, addedSource: input) }
    }
}
