import AppKit
import Combine
import ExplorerCore
import LocalStorage

enum ArchiveBrowsingGuidance {
    static var navigationHint: String {
        ArchiveExtractionActivation.available
            ? "Open a folder, or select items and choose Extract."
            : "Open folders or preview a selected file. Extraction is unavailable in this version."
    }
    static var contentHelp: String {
        ArchiveExtractionActivation.available
            ? "Browse recorded names and sizes. Extract a selection to make a local copy."
            : "Browse names and sizes, or preview a supported file. Extraction is unavailable in this version."
    }
}

/// Holds an existing content-focus intent while an archive acquires its slot.
/// A field/sidebar click replaces that intent and is never stolen on arrival.
@MainActor
final class ArchiveFocusHost: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Concrete archive owners retain their own catalog authority. Only inactive
/// owners are evictable; a slot remains charged through actual reader drain.
@MainActor
final class ArchiveTabCatalogPool {
    static let shared = ArchiveTabCatalogPool()
    private struct Entry {
        let owner: ArchiveTabController
        var touched: UInt64
        var retiring = false
    }
    private var entries: [UUID: Entry] = [:]
    private var clock: UInt64 = 0
    private var retirements: [UUID: Task<Void, Never>] = [:]

    func touch(_ owner: ArchiveTabController) {
        clock &+= 1
        if entries[owner.id] != nil { entries[owner.id]?.touched = clock }
    }

    func admit(_ owner: ArchiveTabController) async -> Bool {
        guard !owner.isClosed, !Task.isCancelled else { return false }
        if entries[owner.id] != nil { touch(owner); return true }
        if entries.count >= 4 {
            let victim = entries.filter { !$0.value.retiring && !$0.value.owner.isPresented && !$0.value.owner.retainsPreviewPresentation }
                .min { $0.value.touched < $1.value.touched }
            guard let victim else { return false }
            let old = victim.value.owner
            entries[victim.key]?.retiring = true
            await old.closeAndDrain()
        }
        guard !owner.isClosed, !Task.isCancelled, entries.count < 4 else { return false }
        clock &+= 1
        entries[owner.id] = Entry(owner: owner, touched: clock)
        return true
    }

    func release(_ owner: ArchiveTabController) { entries.removeValue(forKey: owner.id) }

    func retire(_ owner: ArchiveTabController) {
        guard retirements[owner.id] == nil else { return }
        owner.stop()
        let id = owner.id
        retirements[id] = Task { [self, owner] in
            await owner.closeAndDrain()
            retirements.removeValue(forKey: id)
        }
    }

    func closeAndDrain() async {
        let owners = entries.values.map(\.owner)
        owners.forEach { retire($0) }
        while let task = retirements.values.first { await task.value }
    }

    #if DEBUG
    var retainedCountForVerification: Int { entries.count }
    var retiringCountForVerification: Int { retirements.count }
    #endif
}

/// AppKit composition of two qualified concrete archive models. A member is
/// never represented as a filesystem URL, and BrowserTab alone owns history.
@MainActor
final class ArchiveTabController: NSObject, NSMenuItemValidation {
    let id = UUID()
    let tabID: UUID
    let source: URL
    let format: ArchiveFormat
    private var allowsOriginalMutation: Bool {
        format == .tar ? (TARBrowserModel.isCompressed(source) ? TARBrowserModel.allowsCompressedEditing(source) : TARArchiveEditingFeature.available)
            : ZIPOriginalUpdateFeature.available
    }
    var isReadOnly: Bool {
        if format == .tar { return !allowsOriginalMutation }
        return format != .zip || !(ZIPOriginalUpdateFeature.available || ZIPTextEditorFeature.available
            || ZIPMemberRenameFeature.available)
    }
    let view = NSView()
    private(set) weak var browser: BrowserViewController?
    private(set) var isClosed = false
    private var visit: ArchiveLocation
    private var desiredState: ArchiveBrowseState
    private enum Model {
        case zip(ArchiveBrowserModel, ArchiveMetadataRows)
        case tar(TARBrowserModel, TARMetadataRows)
    }
    private var model: Model?
    private var opening: Task<Void, Never>?
    private var addressWork: Task<Void, Never>?
    private var addressNotice: String?
    private var closing: Task<Void, Never>?
    private var presentation = UUID()
    private var explicitPreparationPresentation: UUID?
    private var restoresScroll = false
    private var updateScheduled = false
    private var lastRecordedState: ArchiveBrowseState?
    private var observations = Set<AnyCancellable>()
    private var scrollObservation: NSObjectProtocol?
    private let body = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let extractButton = NSButton(title: "Extract…", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let range = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "Opening archive…")
    private let previous = NSButton(title: "Previous", target: nil, action: nil)
    private let next = NSButton(title: "Next", target: nil, action: nil)
    private var preparationView: NSView?

    init(tabID: UUID, location: ArchiveLocation, state: ArchiveBrowseState, browser: BrowserViewController) {
        self.tabID = tabID; source = location.source; format = location.format
        visit = location; desiredState = state; self.browser = browser
        super.init()
        buildView()
    }

    var isPresented: Bool {
        guard let browser, !browser.isBrowserSuspended, browser.activeID == tabID,
              case .archive(let current) = browser.location else { return false }
        return current.source == source && current.format == format && browser.archiveTabs[tabID] === self
    }
    var retainsPreviewPresentation: Bool {
        switch model { case .zip(let m, _): m.retainsPreviewPresentation; case .tar(let m, _): m.retainsPreviewPresentation; case nil: false }
    }

    func rebind(to browser: BrowserViewController) {
        self.browser = browser
        // A moved inactive tab must also replace the model's weak extraction
        // browser without starting a new read. The next presentation does that.
        if isPresented { present(visit, state: snapshot(), from: browser) }
    }

    var table: FileTableView? {
        switch model { case .zip(_, let rows): rows.table; case .tar(_, let rows): rows.table; case nil: nil }
    }
    var scroll: NSScrollView? {
        switch model { case .zip(_, let rows): rows.fileScrollView; case .tar(_, let rows): rows.fileScrollView; case nil: nil }
    }
    var foregroundContainer: NSView { body }
    var state: ArchiveBrowseState {
        switch model {
        case .zip(let model, _): model.embeddedViewState
        case .tar(let model, _): model.embeddedViewState
        case nil: desiredState
        }
    }
    var query: String { state.query }
    var busy: Bool {
        if addressWork != nil { return true }
        return switch model { case .zip(let m, _): m.showsStop; case .tar(let m, _): m.busy || m.isPreparingPreview || m.isPreviewing; case nil: opening != nil }
    }
    var current: Bool {
        switch model { case .zip(let m, _): m.viewIsCurrent; case .tar(let m, _): m.current; case nil: false }
    }
    var presentingPreparation: Bool {
        if case .tar(let model, _) = model { return model.showsCompressedPreparation }
        return false
    }
    var selectedCount: Int {
        guard current else { return 0 }
        return switch model { case .zip(let m, _): m.selection.count; case .tar(let m, _): m.selection.count; case nil: 0 }
    }
    var selectedMemberObservation: ArchiveMemberObservation? {
        guard isPresented else { return nil }
        switch model {
        case .zip(let model, _): return model.observedMember(model.selection)
        case .tar(let model, _): return model.observedMember
        case nil: return nil
        }
    }
    var canOpen: Bool {
        guard current, selectedCount == 1 else { return false }
        switch model {
        case .zip(let m, _):
            return !m.isLoading && !m.isPaging && !m.isQueryPending && !m.isChecking && !m.isPreparingSelection
                && (m.visibleItems.contains { m.selection.contains($0.id) && $0.folder != nil } || m.canPreviewSelected)
        case .tar(let m, _): return !m.busy && !m.isPreparingPreview
            && (m.items.contains { m.selection.contains($0.id) && $0.folder != nil } || m.canPreviewSelected)
        case nil: return false
        }
    }
    private var canPreview: Bool {
        switch model { case .zip(let m, _): m.canPreviewSelected; case .tar(let m, _): m.canPreviewSelected; case nil: false }
    }
    var canExtract: Bool {
        return switch model { case .zip(let m, _): m.canExtractWhole; case .tar(let m, _): m.canExtract; case nil: false }
    }
    var canExtractSelected: Bool {
        if ArchiveExtractionActivation.limitsToSingleZIPFile {
            if case .zip(let model, _) = model { return model.canExtractSelected }
            return false
        }
        return switch model { case .zip(let m, _): m.canExtractSelected; case .tar(let m, _): m.canExtract && m.selectedSupported; case nil: false }
    }
    var canRenameInCopy: Bool {
        if case .tar(let model, _) = model { return model.canModifySelectedMembers }
        if case .zip(let model, _) = model { return model.canRenameMemberInCopy }
        return false
    }
    func canCaptureClipboardMembers(_ operation: TransferClipboardFeedback.Intent) -> Bool {
        guard isPresented else { return false }
        switch model {
        case .zip(let model, _): return model.canCaptureClipboardMembers(operation)
        case .tar(let model, _): return model.canCaptureClipboardMembers(operation)
        case nil: return false
        }
    }
    func captureClipboardMembers(_ operation: TransferClipboardFeedback.Intent,
        _ publish: @escaping @MainActor (ScopedItemClipboardIntent) -> Void) {
        guard canCaptureClipboardMembers(operation) else { return }
        switch model {
        case .zip(let model, _):
            model.captureClipboardMembers(operation) { [weak self] source in
                if let self { publish(.init(owner: self, source: source, operation: operation)) }
            }
        case .tar(let model, _):
            model.captureClipboardMembers(operation) { [weak self] source in
                if let self { publish(.init(owner: self, source: source, operation: operation)) }
            }
        case nil: break
        }
    }
    func retainsClipboard(_ source: ZIPClipboardSource) -> Bool {
        guard !isClosed, case .zip(let model, _) = model else { return false }
        return model.retainsClipboard(source)
    }
    func matchesClipboardSelection(_ source: ZIPClipboardSource) -> Bool {
        guard isPresented, case .zip(let model, _) = model else { return false }
        return model.matchesClipboardSelection(source)
    }
    func canPasteMembers(_ source: ZIPClipboardSource, operation: TransferClipboardFeedback.Intent) -> Bool {
        guard isPresented, case .zip(let model, _) = model else { return false }
        return model.canPasteMembers(source, operation: operation)
    }
    func pasteMembers(_ source: ZIPClipboardSource, context: ScopedItemPaste) {
        guard isPresented, case .zip(let model, _) = model else { return }
        model.pasteMembers(source, context: context)
    }
    func canExportClipboard(_ source: ZIPClipboardSource) -> Bool {
        guard !isClosed, case .zip(let model, _) = model else { return false }
        return model.canExportClipboard(source)
    }
    func exportClipboard(_ source: ZIPClipboardSource, context: ScopedItemPaste, to target: BrowserViewController) {
        guard !isClosed, case .zip(let model, _) = model else { return }
        model.exportClipboard(source, context: context, to: target)
    }
    func retainsClipboard(_ source: TARClipboardSource) -> Bool {
        guard !isClosed, case .tar(let model, _) = model else { return false }
        return model.retainsClipboard(source)
    }
    func matchesClipboardSelection(_ source: TARClipboardSource) -> Bool {
        guard isPresented, case .tar(let model, _) = model else { return false }
        return model.matchesClipboardSelection(source)
    }
    func canPasteMembers(_ source: TARClipboardSource, operation: TransferClipboardFeedback.Intent) -> Bool {
        guard isPresented, case .tar(let model, _) = model else { return false }
        return model.canPasteMembers(source, operation: operation)
    }
    func pasteMembers(_ source: TARClipboardSource, context: ScopedItemPaste) {
        guard isPresented, case .tar(let model, _) = model else { return }
        model.pasteMembers(source, context: context)
    }
    func canExportClipboard(_ source: TARClipboardSource) -> Bool {
        guard !isClosed, case .tar(let model, _) = model else { return false }
        return model.canExportClipboard(source)
    }
    func exportClipboard(_ source: TARClipboardSource, context: ScopedItemPaste, to target: BrowserViewController) {
        guard !isClosed, case .tar(let model, _) = model else { return }
        model.exportClipboard(source, context: context, to: target)
    }
    func renameSelectionInCopy() {
        guard isPresented else { return }
        switch model { case .zip(let m, _): m.renameMemberInCopy(m.selection); case .tar(let m, _): m.reviewMutation(.rename, updateOriginal: false); case nil: break }
    }
    func renameSelection() {
        guard isPresented else { return }
        switch model {
        case .zip(let m, _): m.renameMemberInCopy(m.selection, updateOriginal: ZIPOriginalUpdateFeature.available)
        case .tar(let m, _): m.reviewMutation(.rename)
        case nil: break
        }
    }
    var canDuplicate: Bool {
        if case .zip(let model, _) = model { return model.canDuplicateMembers }
        if case .tar(let model, _) = model { return model.canModifySelectedMembers }
        return false
    }
    func duplicateSelection() {
        guard isPresented else { return }
        switch model { case .zip(let m, _): m.duplicateMembers(m.selection, updateOriginal: ZIPOriginalUpdateFeature.available); case .tar(let m, _): m.reviewMutation(.duplicate); case nil: break }
    }
    var canRemoveFromCopy: Bool {
        if case .zip(let model, _) = model { return model.canRemoveMembersInCopy }
        if case .tar(let model, _) = model { return model.canModifySelectedMembers }
        return false
    }
    func removeSelectionFromCopy() {
        guard isPresented else { return }
        switch model { case .zip(let m, _): m.removeMembersInCopy(m.selection); case .tar(let m, _): m.reviewMutation(.remove, updateOriginal: false); case nil: break }
    }
    func removeSelection() {
        guard isPresented else { return }
        switch model {
        case .zip(let m, _) where ZIPOriginalUpdateFeature.available: m.removeMembersInCopy(m.selection, updateOriginal: true)
        case .tar(let m, _): m.reviewMutation(.remove)
        default: break
        }
    }
    var canCreateFolder: Bool {
        if case .zip(let model, _) = model { return model.canCreateFolderInZIP }
        if case .tar(let model, _) = model { return model.canCreateMember }
        return false
    }
    func createFolder() {
        guard isPresented else { return }
        switch model { case .zip(let m, _): _ = m.createFolderInZIP(updateOriginal: ZIPOriginalUpdateFeature.available); case .tar(let m, _): m.reviewMutation(.newFolder); case nil: break }
    }
    var canGroupSelection: Bool {
        if isPresented, case .zip(let model, _) = model { return model.canGroupSelection }
        if isPresented, case .tar(let model, _) = model { return model.canGroupMembers }
        return false
    }
    func groupSelection() {
        guard canGroupSelection else { return }
        switch model { case .zip(let m, _): m.groupSelection(updateOriginal: ZIPOriginalUpdateFeature.available); case .tar(let m, _): m.reviewMutation(.group); case nil: break }
    }
    var canCreateFile: Bool {
        if case .zip(let model, _) = model { return model.canCreateFileInZIP }
        if case .tar(let model, _) = model { return model.canCreateMember }
        return false
    }
    func createFile() {
        guard isPresented else { return }
        switch model { case .zip(let m, _): _ = m.createFileInZIP(updateOriginal: ZIPOriginalUpdateFeature.available); case .tar(let m, _): m.reviewMutation(.newFile); case nil: break }
    }
    var canAddCopiedFiles: Bool {
        if isPresented, case .zip(let model, _) = model { return model.canAddMembersInCopy }
        if isPresented, case .tar(let model, _) = model { return model.canCreateMember }
        return false
    }
    @discardableResult func addCopiedFiles(_ input: ArchiveAdditionInput) -> Bool {
        guard isPresented else { return false }
        switch model {
        case .zip(let m, _): return m.addCopiedFiles(input, updateOriginal: ZIPOriginalUpdateFeature.available)
        case .tar(let m, _) where m.canCreateMember:
            m.reviewMutation(.add, addedSource: input); return true
        default: return false
        }
    }

    private func buildView() {
        caption.stringValue = format.rawValue.uppercased() + (isReadOnly ? " · Read-only" : " Archive")
        InterfaceMetrics.setFont(caption, base: .systemFont(ofSize: 12, weight: .medium))
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.toolTip = ArchiveBrowsingGuidance.contentHelp
        extractButton.target = self; extractButton.action = #selector(extractPrimary(_:)); extractButton.controlSize = .small
        actions.addItem(withTitle: "More")
        for (title, action) in [("Extract Selected…", #selector(extractSelected(_:))),
            ("Extract All…", #selector(extractAll(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        if format == .zip, ArchiveContentCheckActivation.available {
            let item = NSMenuItem(title: "Test ZIP Contents", action: #selector(testZIPContents(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = "Read and check ZIP checksums without extracting or changing files. This checks corruption, not malware or authenticity."
            actions.menu?.addItem(item)
        }
        actions.menu?.addItem(.separator())
        for (title, action) in [("Refresh", #selector(refreshArchive(_:))), ("Stop", #selector(stopArchive(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        if format == .tar, TARBrowserModel.isCompressed(source) {
            let item = NSMenuItem(title: "Prepare Compressed Archive", action: #selector(prepareCompressedArchive(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        actions.menu?.addItem(.separator())
        for (title, action) in [("Preview Text", #selector(previewText(_:))), ("Preview as Hex", #selector(previewHex(_:)))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;actions.menu?.addItem(item)
        }
        if format == .zip && ZIPTextEditorFeature.available || format == .tar && allowsOriginalMutation {
            let item = NSMenuItem(title: "Edit in Traverse", action: #selector(editText(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        actions.controlSize = .small; actions.setAccessibilityLabel("Archive actions")
        if format == .zip && ZIPMemberCreationFeature.available || format == .tar && allowsOriginalMutation {
            let file = NSMenuItem(title: "Create File in \(format.rawValue.uppercased())…", action: #selector(createZIPFile(_:)), keyEquivalent: "")
            file.target = self; actions.menu?.addItem(file)
            let item = NSMenuItem(title: "New Folder in \(format.rawValue.uppercased())…", action: #selector(createZIPFolder(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
            let group = NSMenuItem(title: "New Folder with Selection…", action: #selector(groupZIPSelection(_:)), keyEquivalent: "")
            group.target = self; actions.menu?.addItem(group)
        }
        if allowsOriginalMutation {
            let label = format.rawValue.uppercased()
            for (title, action) in [("Rename in \(label)…", #selector(renameOriginal(_:))),
                ("Remove from \(label)…", #selector(removeOriginal(_:))), ("Add to \(label)…", #selector(addOriginal(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; actions.menu?.addItem(item)
            }
        }
        if format == .zip && ZIPMemberRenameFeature.available || format == .tar && allowsOriginalMutation {
            let item = NSMenuItem(title: "Rename in \(format.rawValue.uppercased()) Copy…", action: #selector(renameInCopy(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        if format == .zip && ZIPMemberRemovalFeature.available || format == .tar && allowsOriginalMutation {
            let item = NSMenuItem(title: "Remove from \(format.rawValue.uppercased()) Copy…", action: #selector(removeFromCopy(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        if format == .zip && ZIPMemberAdditionFeature.available || format == .tar && allowsOriginalMutation {
            let item = NSMenuItem(title: "Add to \(format.rawValue.uppercased()) Copy…", action: #selector(addToCopy(_:)), keyEquivalent: "")
            item.target = self; actions.menu?.addItem(item)
        }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let tools = stack([caption, spacer, progress, extractButton, actions], orientation: .horizontal, spacing: 8)
        previous.target = self; previous.action = #selector(previousPage(_:)); previous.controlSize = .small
        next.target = self; next.action = #selector(nextPage(_:)); next.controlSize = .small
        previous.title = ""; previous.image = symbol("chevron.left", "Previous archive page")
        next.title = ""; next.image = symbol("chevron.right", "Next archive page")
        previous.setAccessibilityLabel("Previous archive page"); next.setAccessibilityLabel("Next archive page")
        previous.toolTip = "Previous page"; next.toolTip = "Next page"
        previous.identifier = .init("archivePreviousPage"); next.identifier = .init("archiveNextPage")
        previous.widthAnchor.constraint(equalToConstant: 28).interfaceScaled.isActive = true
        next.widthAnchor.constraint(equalToConstant: 28).interfaceScaled.isActive = true
        InterfaceMetrics.setFont(range, base: .systemFont(ofSize: 11)); range.textColor = .secondaryLabelColor
        range.lineBreakMode = .byTruncatingTail; range.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = stack([range, footerSpacer, previous, next], orientation: .horizontal, spacing: 8)
        notice.maximumNumberOfLines = 3; notice.lineBreakMode = .byWordWrapping; notice.textColor = .secondaryLabelColor
        InterfaceMetrics.setFont(notice, base: .systemFont(ofSize: 12))
        for surface in [tools, body, footer, notice] { surface.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(surface) }
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), tools.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tools.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), tools.heightAnchor.constraint(equalToConstant: 28).interfaceScaled,
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor), body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 6), body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -4),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), notice.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).interfaceScaled
        ])
        InterfacePresentation.shared.register(view)
    }

    func present(_ location: ArchiveLocation, state: ArchiveBrowseState, from browser: BrowserViewController) {
        guard !isClosed, location.source == source, location.format == format else { return }
        addressWork?.cancel(); addressNotice = nil
        explicitPreparationPresentation = nil
        self.browser = browser; visit = location; desiredState = state; presentation = UUID(); restoresScroll = true
        if let model { present(model); ArchiveTabCatalogPool.shared.touch(self); return }
        guard opening == nil else { return }
        progress.startAnimation(nil)
        opening = Task { [self] in
            defer { opening = nil; render() }
            guard await ArchiveTabCatalogPool.shared.admit(self), !isClosed, !Task.isCancelled,
                  let browser = self.browser else {
                explicitPreparationPresentation = nil
                if !isClosed { notice.stringValue = "Close another archive or its preview, then Refresh to open this one." }
                return
            }
            installModel(browser: browser)
            if let model { present(model) }
        }
    }

    func prepareForExplicitUserOpen(_ location: ArchiveLocation) {
        guard CompressedArchiveOpenFeature.available, !isClosed, isPresented,
              format == .tar, visit == location, source == location.source,
              TARBrowserModel.isCompressed(source) else { return }
        explicitPreparationPresentation = presentation
        // The same tab may already own an unprepared/stopped model. It needs
        // no new pool slot, but must consume exactly the same one-shot intent.
        if let model { present(model) }
    }

    private func present(_ model: Model) {
        guard let browser, !isClosed else { return }
        let prepares = explicitPreparationPresentation == presentation && isPresented
        explicitPreparationPresentation = nil
        switch model {
        case .zip(let model, _): model.presentEmbedded(visit, state: desiredState, from: browser)
        case .tar(let model, _): model.presentEmbedded(visit, state: desiredState, from: browser,
            preparesCompressed: prepares)
        }
        render()
    }

    private func installModel(browser: BrowserViewController) {
        let excluded = (browser.developmentStateDirectory.map { [$0] } ?? []) + AppStorageLocations.protectedDirectories
        switch format {
        case .zip:
            let m = ArchiveBrowserModel(settings: browser.settings,
                reader: ZIPArchiveReader(activity: ApplicationFileActivity.gate, excludedRoots: excluded))
            let rows = ArchiveMetadataRows(); rows.animatesNewRows = false
            rows.bindActions(to: m)
            rows.onCut = { [weak self] in self?.browser?.cutFileURLs(nil) }
            rows.onCopyMembers = { [weak self] in self?.browser?.copyFileURLs(nil) }
            rows.canCaptureClipboard = { [weak self] operation in self?.browser?.canCaptureArchiveClipboard(operation) == true }
            rows.onPaste = { [weak self] in self?.browser?.pasteFileURLs(nil) }
            rows.canPaste = { [weak self] in
                self?.browser?.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))) == true
            }
            rows.isCut = { [weak self, weak m] id in
                guard let self, let m, let intent = self.browser?.clipboardState.scopedItem,
                      intent.operation == .move, intent.archiveOwner === self,
                      case .zip(let source) = intent.source else { return false }
                return m.showsCut(source) && source.ids.contains(id)
            }
            rows.table.onCut = rows.onCut; rows.table.onCopy = rows.onCopyMembers; rows.table.onPaste = rows.onPaste
            rows.embeddedShortcut = { [weak self] in self?.shortcut($0) == true }
            rows.memberDragSource = ArchiveMemberDragSource(model: m, table: rows.table)
            rows.table.memberDragSource = rows.memberDragSource
            m.embeddedNavigate = { [weak self] in self?.navigate($0, state: $1) }
            m.embeddedBack = { [weak self] in self?.browser?.goBack(nil) }
            m.embeddedForward = { [weak self] in self?.browser?.goForward(nil) }
            m.embeddedUp = { [weak self] in self?.browser?.goUp(nil) }
            m.embeddedIsPresented = { [weak self] in self?.isPresented == true }
            #if DEBUG
            m.rowsForVerification = rows
            #endif
            model = .zip(m, rows); pin(rows, inside: body)
            rows.table.commandValidation = { [weak self] in self?.browser?.fileResponderCommandEnabled($0) == true }
            rows.table.marquee?.onBegin = { [weak self] in guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false) }
            InterfacePresentation.shared.register(rows)
            m.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &observations)
        case .tar:
            let m = TARBrowserModel(settings: browser.settings,
                reader: ApplicationCompressedArchives.shared.reader(excluding: excluded))
            let rows = TARMetadataRows(model: m); rows.animatesNewRows = false
            rows.onCut = { [weak self] in self?.browser?.cutFileURLs(nil) }
            rows.onCopyMembers = { [weak self] in self?.browser?.copyFileURLs(nil) }
            rows.canCaptureClipboard = { [weak self] in self?.browser?.canCaptureArchiveClipboard($0) == true }
            rows.onPaste = { [weak self] in self?.browser?.pasteFileURLs(nil) }
            rows.canPaste = { [weak self] in self?.browser?.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))) == true }
            rows.isCut = { [weak self, weak m] id in
                guard let self, let m, let intent = self.browser?.clipboardState.scopedItem,
                      intent.operation == .move, intent.archiveOwner === self,
                      case .tar(let source) = intent.source else { return false }
                return m.showsCut(source) && source.ids.contains(id)
            }
            rows.table.onCut = rows.onCut; rows.table.onCopy = rows.onCopyMembers; rows.table.onPaste = rows.onPaste
            rows.embeddedShortcut = { [weak self] in self?.shortcut($0) == true }
            m.embeddedNavigate = { [weak self] in self?.navigate($0, state: $1) }
            m.embeddedBack = { [weak self] in self?.browser?.goBack(nil) }
            m.embeddedForward = { [weak self] in self?.browser?.goForward(nil) }
            m.embeddedUp = { [weak self] in self?.browser?.goUp(nil) }
            m.embeddedIsPresented = { [weak self] in self?.isPresented == true }
            model = .tar(m, rows); pin(rows, inside: body)
            let preparation = InterfaceHostingView(content: CompressedArchivePreparationView(model: m))
            preparation.sizingOptions = []; preparation.isHidden = true
            preparationView = preparation; pin(preparation, inside: body)
            rows.table.commandValidation = { [weak self] in self?.browser?.fileResponderCommandEnabled($0) == true }
            rows.table.marquee?.onBegin = { [weak self] in guard let browser = self?.browser else { return }; browser.workspace?.activate(browser, focus: false) }
            InterfacePresentation.shared.register(rows)
            m.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &observations)
        }
        browser.settings.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &observations)
        if let clip = scroll?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureScroll() }
            }
        }
        if isPresented, browser.isActiveCommandPane, let window = view.window, window.isKeyWindow,
           window.firstResponder === browser.archiveHost, let table {
            window.makeFirstResponder(table)
        }
    }

    private func navigate(_ path: [String], state: ArchiveBrowseState) {
        guard isPresented, let next = try? ArchiveLocation(source: source, format: format, folderPath: path) else { return }
        captureScroll(); browser?.navigateArchive(to: next, state: state)
    }

    private func captureScroll() {
        guard !restoresScroll, let clip = scroll?.contentView else { return }
        let offset = max(0, clip.bounds.origin.y + clip.contentInsets.top)
        switch model { case .zip(let m, _): m.embeddedScrollOffset = offset; case .tar(let m, _): m.embeddedScrollOffset = offset; case nil: break }
    }

    func snapshot() -> ArchiveBrowseState { captureScroll(); return state }
    func setQuery(_ value: String) {
        addressWork?.cancel(); addressNotice = nil
        switch model { case .zip(let m, _): m.filter = value; case .tar(let m, _): m.query = value; case nil: desiredState.query = value }
        scheduleUpdate()
    }
    /// Check an explicit address against the exact live catalog before changing
    /// BrowserTab history. A typo retains both the current rows and field text.
    @discardableResult
    func openFolderAddress(_ target: ArchiveLocation, completed: @escaping @MainActor (ArchiveBrowseState?) -> Void) -> Bool {
        guard isPresented, current, !busy, !ApplicationFileActivity.gate.isClosed,
              target.source == source, target.format == format, let model else { return false }
        let token = presentation
        addressNotice = nil
        addressWork = Task { [self] in
            defer { addressWork = nil; scheduleUpdate() }
            do {
                switch model {
                case .zip(let owner, _): try await owner.validateAddressFolder(target.folderPath)
                case .tar(let owner, _): try await owner.validateAddressFolder(target.folderPath)
                }
                try Task.checkCancellation()
                guard isPresented, presentation == token else { return }
                var state = snapshot()
                state.query = ""; state.scope = .folder; state.offset = 0; state.selectedPaths = []; state.scrollOffset = 0
                completed(state)
            } catch {
                guard !Task.isCancelled, isPresented, presentation == token else { return }
                addressNotice = "That folder is unavailable in this archive. Check its name, or Refresh if the archive changed."
                completed(nil)
            }
        }
        scheduleUpdate(); return true
    }
    func cancelAddressNavigation() { addressWork?.cancel() }
    func openSelection() { guard isPresented else { return }; switch model { case .zip(let m, _): m.openSelection(m.selection); case .tar(let m, _): m.openSelection(); case nil: break } }
    func selectAll() { table?.selectAll(nil) }

    private func shortcut(_ event: NSEvent) -> Bool {
        guard isPresented, let browser else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), flags.intersection([.command, .control, .option]).isEmpty {
            openSelection(); return true
        }
        if event.keyCode == 49, flags.intersection([.command, .control, .option]).isEmpty {
            switch model {
            case .zip(let m, _): m.previewSelected()
            case .tar(let m, _): m.previewSelected()
            case nil: break
            }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" { browser.focusFilter(nil); return true }
        if flags.contains(.option), event.keyCode == 123 { browser.goBack(nil); return true }
        if flags.contains(.option), event.keyCode == 124 { browser.goForward(nil); return true }
        if flags.contains(.command), event.keyCode == 126 { browser.goUp(nil); return true }
        return browser.routeBrowserShortcut(event)
    }

    private func scheduleUpdate() {
        guard !updateScheduled, !isClosed else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }; self.updateScheduled = false
            guard !self.isClosed else { return }
            self.render()
            if self.isPresented {
                self.browser?.renderCurrentArchiveStatus()
                let state = self.snapshot()
                if state != self.lastRecordedState {
                    self.lastRecordedState = state; self.browser?.recordBrowserSession()
                }
            }
        }
    }

    func render() {
        guard let browser, !isClosed else { return }
        let glass = browser.settings.navigationStyle == .glass && browser.settings.glassFileContent
        let offset: Int, total: Int, count: Int, hasNext: Bool
        switch model {
        case .zip(let m, let rows):
            rows.table.behavior = browser.settings.behavior
            rows.configure(glass: glass, motion: browser.settings.motion, order: ArchiveOrderingActivation.available ? m.ordering : nil)
            rows.setExternalExportsReady(m.externalExportReady)
            // A retained tab may still have its previous page while the new
            // visit is queried. It must not paint that page before the fade.
            rows.observe(m.viewIsCurrent ? m.visibleItems : [], selection: m.viewIsCurrent ? m.selection : [], showsLocation: m.isSearchResults)
            offset = m.visibleOffset; total = m.visibleTotal; count = m.visibleItems.count; hasNext = m.hasNextPage
            notice.stringValue = m.notice.isEmpty ? ArchiveBrowsingGuidance.navigationHint : m.notice
            if m.isChecking, let update = m.contentProgress {
                notice.stringValue = "Checking \(update.completedEntries.formatted()) of \(update.totalEntries.formatted()) items…"
            }
        case .tar(let m, let rows):
            let showsPreparation = m.showsCompressedPreparation
            let newlyShowingPreparation = showsPreparation && preparationView?.isHidden == true
            let newlyShowingRows = !showsPreparation && preparationView?.isHidden == false
            preparationView?.isHidden = !showsPreparation
            rows.isHidden = showsPreparation
            if newlyShowingPreparation, let preparationView { ToolContentMotion.reveal(preparationView) }
            if newlyShowingRows { ToolContentMotion.reveal(rows.fileScrollView.contentView) }
            caption.stringValue = m.formatName
                + (m.allowsTextEditing ? " · Editing" : " · Read-only")
            caption.toolTip = m.compressedSizeDescription.map { $0 + "\nArchive is the original compressed size. Prepared TAR includes headers and padding. Files is the sum of recorded member sizes." }
                ?? ArchiveBrowsingGuidance.contentHelp
            rows.update(m, settings: browser.settings, glassOverride: glass, showsOnlyCurrent: true)
            offset = m.offset; total = m.total; count = m.items.count; hasNext = m.hasNext
            notice.stringValue = m.notice.isEmpty ? ArchiveBrowsingGuidance.navigationHint : m.notice
        case nil:
            offset = 0; total = 0; count = 0; hasNext = false
        }
        if let addressNotice { notice.stringValue = addressNotice }
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        range.stringValue = current ? "\(total == 0 ? 0 : offset + 1)–\(offset + count) of \(total.formatted()) items" : ""
        previous.isEnabled = current && !busy && offset > 0; next.isEnabled = current && !busy && hasNext
        extractButton.isEnabled = selectedCount > 0 ? canExtractSelected : canExtract
        extractButton.toolTip = ArchiveExtractionActivation.available
            ? (selectedCount > 0 ? "Review extraction of \(selectedCount) selected items" : "Review extraction of the entire archive")
            : "Extraction is unavailable in this version. You can still browse and preview files."
        if restoresScroll, current, !busy, let scroll {
            restoresScroll = false; scroll.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            var bounds = clip.bounds; bounds.origin = .init(x: 0, y: max(0, desiredState.scrollOffset) - clip.contentInsets.top)
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin); scroll.reflectScrolledClipView(clip)
            captureScroll()
        }
    }

    func refresh() {
        guard !isClosed else { return }
        addressWork?.cancel(); addressNotice = nil
        switch model { case .zip(let m, _): m.refresh(); case .tar(let m, _): m.refresh(); case nil: if let browser { present(visit, state: desiredState, from: browser) } }
    }
    func stop() {
        explicitPreparationPresentation = nil
        opening?.cancel(); addressWork?.cancel()
        switch model { case .zip(let m, _): m.stop(); case .tar(let m, _): m.stop(); case nil: break }
    }
    func suspend() { stop(); switch model { case .zip(let m, _): m.prepareForVolumeQuiescence(); case .tar(let m, _): m.suspend(); case nil: break } }
    func resume() { switch model { case .zip(let m, _): m.resumeAfterVolumeQuiescence(); case .tar(let m, _): m.resume(); case nil: break }; scheduleUpdate() }
    func drain() async {
        if let opening { await opening.value }
        if let addressWork { await addressWork.value }
        switch model { case .zip(let m, _): await m.drain(); case .tar(let m, _): await m.drain(); case nil: break }
    }
    func closeAndDrain() async {
        if let closing { await closing.value; return }
        isClosed = true; stop()
        let task = Task { [self] in
            if let opening { await opening.value }
            if let addressWork { await addressWork.value }
            observations.removeAll()
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation); self.scrollObservation = nil }
            switch model {
            case .zip(let m, let rows):
                rows.embeddedShortcut = nil; rows.memberDragSource?.retire(); rows.memberDragSource = nil; rows.table.memberDragSource = nil
                rows.onNewFolder = nil; rows.canNewFolder = nil
                rows.onGroup = nil; rows.canGroup = nil
                rows.onNewFile = nil; rows.onCut = nil; rows.onCopyMembers = nil; rows.canCaptureClipboard = nil
                rows.onPaste = nil; rows.canPaste = nil
                rows.isCut = nil
                rows.table.onCut = nil; rows.table.onCopy = nil; rows.table.onPaste = nil
                rows.table.onRename = nil; rows.table.nameClickRenameEnabled = nil
                rows.table.marquee?.cancel(restore: false); rows.table.marquee = nil
                await m.closeAndDrain()
            case .tar(let m, let rows): rows.embeddedShortcut = nil; rows.retire(); await m.closeAndDrain()
            case nil: break
            }
            preparationView?.removeFromSuperview(); preparationView = nil
            model = nil; view.removeFromSuperview(); ArchiveTabCatalogPool.shared.release(self)
        }
        closing = task; await task.value; closing = nil
    }

    func setScope(_ value: ArchiveSearchScope) {
        guard isPresented else { return }
        let whole = value == .archive
        switch model { case .zip(let m, _): m.nameScope = whole ? .archive : .folder; case .tar(let m, _): m.scope = whole ? .archive : .folder; case nil: desiredState.scope = whole ? .archive : .folder }
    }
    @objc private func extractPrimary(_ sender: Any?) {
        guard isPresented else { return }
        if selectedCount > 0 { extractSelected(sender) } else { extractAll(sender) }
    }
    @objc private func previousPage(_ sender: Any?) { restoresScroll = false; switch model { case .zip(let m, _): m.previousPage(); case .tar(let m, _): m.page(false); case nil: break } }
    @objc private func nextPage(_ sender: Any?) { restoresScroll = false; switch model { case .zip(let m, _): m.nextPage(); case .tar(let m, _): m.page(true); case nil: break } }
    @objc private func prepareCompressedArchive(_ sender: Any?) {
        guard isPresented, case .tar(let model, _) = model else { return }
        model.prepareCompressed()
    }
    @objc private func extractSelected(_ sender: Any?) { switch model { case .zip(let m, _): m.reviewExtraction(m.selection); case .tar(let m, _): m.extract(selected: true); case nil: break } }
    @objc private func extractAll(_ sender: Any?) { switch model { case .zip(let m, _): m.extract(); case .tar(let m, _): m.extract(selected: false); case nil: break } }
    @objc private func previewText(_ sender:Any?) {switch model{case .zip(let m,_):m.previewSelected();case .tar(let m,_):m.previewSelected();case nil:break}}
    @objc private func editText(_ sender: Any?) {
        guard isPresented else { return }
        switch model { case .zip(let m, _): m.editSelectedText(); case .tar(let m, _): m.editSelectedText(); case nil: break }
    }
    @objc private func previewHex(_ sender:Any?) {switch model{case .zip(let m,_):m.previewSelectedAsBytes();case .tar(let m,_):m.previewSelectedAsBytes();case nil:break}}
    @objc private func refreshArchive(_ sender: Any?) { refresh() }
    @objc private func testZIPContents(_ sender: Any?) {
        guard isPresented, case .zip(let model, _) = model else { return }
        model.checkContents()
    }
    @objc private func renameInCopy(_ sender: Any?) { renameSelectionInCopy() }
    @objc private func createZIPFolder(_ sender: Any?) { createFolder() }
    @objc private func groupZIPSelection(_ sender: Any?) { groupSelection() }
    @objc private func createZIPFile(_ sender: Any?) { createFile() }
    @objc private func renameOriginal(_ sender: Any?) { renameSelection() }
    @objc private func removeOriginal(_ sender: Any?) { removeSelection() }
    @objc private func addOriginal(_ sender: Any?) {
        if isPresented, case .zip(let model, _) = model, ZIPOriginalUpdateFeature.available { model.addMembersInCopy(updateOriginal: true) }
        if isPresented, case .tar(let model, _) = model { model.reviewMutation(.add) }
    }
    @objc private func removeFromCopy(_ sender: Any?) { removeSelectionFromCopy() }
    @objc private func addToCopy(_ sender: Any?) {
        if case .zip(let model, _) = model { model.addMembersInCopy() }
        if case .tar(let model, _) = model { model.reviewMutation(.add, updateOriginal: false) }
    }
    @objc private func stopArchive(_ sender: Any?) { stop() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !isClosed, browser?.isBrowserSuspended == false else { return false }
        if item.action == #selector(previewText(_:)) {
            item.title = switch model {
            case .zip(let model, _): model.preferredPreview.commandTitle
            case .tar(let model, _): model.preferredPreview.commandTitle
            case nil: "Preview"
            }
        }
        return switch item.action {
        case #selector(createZIPFolder(_:)): canCreateFolder
        case #selector(groupZIPSelection(_:)): canGroupSelection
        case #selector(createZIPFile(_:)): canCreateFile
        case #selector(extractSelected(_:)): canExtractSelected
        case #selector(extractAll(_:)): canExtract
        case #selector(renameInCopy(_:)): canRenameInCopy
        case #selector(renameOriginal(_:)): allowsOriginalMutation && canRenameInCopy
        case #selector(removeOriginal(_:)): allowsOriginalMutation && canRemoveFromCopy
        case #selector(addOriginal(_:)): canAddCopiedFiles
        case #selector(removeFromCopy(_:)): canRemoveFromCopy
        case #selector(addToCopy(_:)): canAddCopiedFiles
        case #selector(previewText(_:)), #selector(previewHex(_:)): canPreview
        case #selector(editText(_:)):
            switch model { case .zip(let m, _): m.canEditSelectedText; case .tar(let m, _): m.canEditSelectedText; case nil: false }
        case #selector(refreshArchive(_:)): true
        case #selector(testZIPContents(_:)):
            if case .zip(let model, _) = model { isPresented && model.canCheckContents } else { false }
        case #selector(prepareCompressedArchive(_:)):
            if case .tar(let model, _) = model { model.canPrepareCompressed } else { false }
        case #selector(stopArchive(_:)): busy
        default: false
        }
    }
    #if DEBUG
    var hasRenderedCurrentRowsForVerification: Bool {
        switch model {
        case .zip(let model, let rows): model.viewIsCurrent && rows.rowIDsForVerification == model.visibleItems.map(\.id)
        case .tar(let model, let rows): model.current && rows.rowIDsForVerification == model.items.map(\.id)
        case nil: false
        }
    }
    #endif
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    var zipModelForVerification: ArchiveBrowserModel? { if case .zip(let m, _) = model { return m }; return nil }
    #endif
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA || (TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION)
    var tarModelForVerification: TARBrowserModel? { if case .tar(let m, _) = model { return m }; return nil }
    #endif
}
