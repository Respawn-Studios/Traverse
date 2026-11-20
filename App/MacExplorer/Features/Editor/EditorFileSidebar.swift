import AppKit
import Combine
import ExplorerCore
import FileOperations
import LocalStorage

struct EditorOpenFile {
    let url: URL
    let isEdited: Bool
}

enum EditorSidebarMode: Int, CaseIterable {
    case files, open, outline

    var title: String {
        switch self {
        case .files: "Files"
        case .open: "Open"
        case .outline: "Outline"
        }
    }
}

struct EditorSidebarVisit {
    let shown: Bool
    let width: CGFloat
    let folder: URL?
    let mode: EditorSidebarMode
}

/// The native outline owns selection and expansion. Its reader only visits
/// the current root and branches expanded by the user or the current file.
@MainActor final class EditorFileSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let missingCurrentFile = "The current file is missing from this listing. Refresh Files to check again."

    private final class Item {
        let url: URL, name: String
        let folder: Bool
        var children: [Item]?

        init(url: URL, name: String, folder: Bool) {
            self.url = url
            self.name = name
            self.folder = folder
        }
    }

    private final class Section {
        let entry: EditorDocumentOutline.Entry
        init(_ entry: EditorDocumentOutline.Entry) { self.entry = entry }
    }

    let view = NSView()
    let outline = EditorFilesOutline()
    private let scroll = NSScrollView()
    let modeControl = NSSegmentedControl(labels: EditorSidebarMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let compactModeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "")
    let outlineSearch = NSSearchField()
    private let outlineInput = NativeQueryInput()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(frame: .zero)
    private let fileSystem: LocalFileSystem
    private let folderAccess: FolderAccessController
    private let settings: BrowserSettings
    private let openFiles: () -> [EditorOpenFile]
    private let open: (URL, EditorFileJump?, LocalTextOpenSelection?) -> Void
    var onHistory: ((URL) -> Void)?
    var onRevision: ((URL, EditorGitRevisionIntent) -> Void)?
    var onWorktree: ((URL) -> Void)?
    var onFolderReview: ((URL, GitComparisonModel.Mode) -> Void)?
    var onGitIndexAction: ((GitIndexEditAction) -> Void)?
    private var document: URL
    private let preferredFolder: URL?
    private var mode = EditorSidebarMode.files
    private var root: Item?
    private var openItems: [Item] = []
    private weak var text: NativeTextEditorSurface?
    private var shownOutline: EditorDocumentOutline?
    private var sections: [Section] = []
    private var outlineQuery = ""
    private var edited = Set<URL>()
    private var queued: [Item] = []
    private var loadedFolders = 0
    private var work: Task<Void, Never>?
    private var version = UUID()
    private var visible = false
    private var rootAttempted = false
    private var openObservation: AnyCancellable?
    private var repository: GitRepositoryLocation?
    private var checkoutHead: GitWorktree.Head?
    private var restoringExpanded = Set<URL>()
    private let column = NSTableColumn(identifier: .init("editor-file"))
    private lazy var gitBadges = GitViewportBadges(request: { [weak self] in self?.gitBadgeRequest() },
        delivered: { [weak self] _, available in
            self?.refreshButton.toolTip = available ? "Refresh Files" : "Refresh Files. Git status is unavailable."
            self?.redrawRows()
        })
    private var badgeObservation: AnyCancellable?
    private var gitPreference: AnyCancellable?
    private var workingPreference: AnyCancellable?
    private var sizeObservation: AnyCancellable?
    private var availableWidth: CGFloat = 0
    private(set) var projectSearch: EditorProjectFileSearch?

    init(document: URL, fileSystem: LocalFileSystem, access: FolderAccessController, settings: BrowserSettings,
         visit: EditorSidebarVisit?, repository: GitRepositoryLocation?,
         openChanges: AnyPublisher<Void, Never>, openFiles: @escaping () -> [EditorOpenFile],
         open: @escaping (URL, EditorFileJump?, LocalTextOpenSelection?) -> Void) {
        self.document = document.standardizedFileURL
        self.fileSystem = fileSystem
        self.folderAccess = access
        self.settings = settings
        self.preferredFolder = visit?.folder
        self.repository = repository
        self.openFiles = openFiles
        self.open = open
        super.init()
        if let visit { mode = visit.mode }
        buildView()
        openObservation = openChanges.sink { [weak self] _ in self?.refreshOpenFiles() }
        badgeObservation = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.updateGitBadges() }
        gitPreference = settings.$showsGitControls.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.resetGitBadges()
            self?.updateFolderHeading()
        }
        workingPreference = settings.$editorPreferences.map(\.showsWorkingGitChanges).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.resetGitBadges() }
        sizeObservation = NotificationCenter.default.publisher(for: InterfacePresentation.didChange, object: InterfacePresentation.shared)
            .sink { [weak self] _ in self?.updateModeControlLayout() }
    }

    isolated deinit { work?.cancel() }

    private func buildView() {
        modeControl.target = self
        modeControl.action = #selector(switchMode(_:))
        modeControl.selectedSegment = mode.rawValue
        modeControl.setAccessibilityLabel("Editor sidebar view")
        modeControl.setAccessibilityIdentifier("editor-sidebar-mode")
        compactModeControl.addItems(withTitles: EditorSidebarMode.allCases.map(\.title))
        compactModeControl.selectItem(at: mode.rawValue)
        compactModeControl.target = self
        compactModeControl.action = #selector(switchCompactMode(_:))
        compactModeControl.setAccessibilityLabel("Editor sidebar view")
        compactModeControl.setAccessibilityIdentifier("editor-sidebar-compact-mode")
        compactModeControl.isHidden = true
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Files")
        refreshButton.bezelStyle = .recessed
        refreshButton.toolTip = "Refresh Files"
        refreshButton.target = self
        refreshButton.action = #selector(refreshFiles(_:))
        refreshButton.isHidden = mode != .files
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [modeControl, compactModeControl, spacer, refreshButton])
        controls.spacing = 4
        controls.alignment = .centerY
        controls.orientation = .horizontal
        folderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.isHidden = true
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 25
        InterfaceMetrics.setRowHeight(outline, base: 25)
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizingMask = [.width]
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        column.minWidth = 90
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelection(_:))
        outline.onEnter = { [weak self] in self?.openSelection(nil) }
        outline.setAccessibilityLabel("Editor files")
        outline.setAccessibilityIdentifier("editor-file-outline")
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let heading = NSView()
        outlineSearch.placeholderString = "Find in Outline"
        outlineSearch.setAccessibilityLabel("Find in Document Outline")
        outlineSearch.setAccessibilityIdentifier("editor-outline-search")
        outlineSearch.sendsSearchStringImmediately = true
        outlineSearch.delegate = outlineInput
        InterfaceMetrics.setFont(outlineSearch, base: .systemFont(ofSize: 11))
        outlineInput.onChange = { [weak self] in self?.searchOutline($0) }
        outlineInput.onCommand = { [weak self] in self?.outlineCommand($0) == true }
        for content in [folderLabel, outlineSearch] {
            content.translatesAutoresizingMaskIntoConstraints = false
            heading.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
                content.centerYAnchor.constraint(equalTo: heading.centerYAnchor)
            ])
        }
        heading.heightAnchor.constraint(equalToConstant: 24).interfaceScaled.isActive = true
        updateHeading()
        let stack = NSStackView(views: [controls, heading, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ] + stack.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        InterfacePresentation.shared.register(view)
    }

    func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, availableWidth != width else { return }
        availableWidth = width
        updateModeControlLayout()
    }

    private func updateModeControlLayout() {
        guard availableWidth > 0 else { return }
        let font = modeControl.font ?? InterfaceMetrics.font(13)
        let required = EditorSidebarMode.allCases.reduce(CGFloat(0)) { width, choice in
            let label = (choice.title as NSString).size(withAttributes: [.font: font]).width
            let segment = ceil(label) + 18
            if modeControl.width(forSegment: choice.rawValue) != segment {
                modeControl.setWidth(segment, forSegment: choice.rawValue)
            }
            return width + segment
        }
        // Reserve Refresh's space in every mode so the switch never moves when
        // Files, Open and Outline replace one another at the same divider width.
        let compact = availableWidth < required + max(32, refreshButton.fittingSize.width) + 26
        guard compact != modeControl.isHidden else { return }
        let old: NSControl = compact ? modeControl : compactModeControl
        let next: NSControl = compact ? compactModeControl : modeControl
        let window = view.window, restoreFocus = window?.firstResponder === old
        old.isHidden = true
        next.isHidden = false
        window?.recalculateKeyViewLoop()
        if restoreFocus { window?.makeFirstResponder(next) }
    }

    func documentChanged(to url: URL) {
        let url = url.standardizedFileURL
        guard document != url else { return }
        document = url
        outlineQuery = ""
        outlineSearch.stringValue = ""
        resetTree(preserveExpansion: false)
        refreshOpenFiles()
    }

    var projectFolder: URL {
        root?.url ?? projectFolder(containing: document.deletingLastPathComponent(), repository: repository)
    }

    var canFindInSelectedFolder: Bool { visible && mode == .files && selected?.folder == true }

    func revealCurrentFile() {
        guard visible, mode == .files, !select(document, scroll: true) else { return }
        outline.deselectAll(nil)
        if !revealDocument() { showStatus(Self.missingCurrentFile) }
    }

    func findProjectFile(in editor: NativeTextEditorWindow, purpose: EditorProjectFileSearch.Purpose = .openFile) {
        guard let parent = editor.window else { return }
        let project = projectFolder, current = document
        let folder: URL
        if purpose == .findFolderText {
            guard canFindInSelectedFolder, let selected else { return }
            folder = selected.url
        } else { folder = project }
        let origin = EditorDocumentNavigation.shared.location(in: editor)
        let picker = projectSearch ?? EditorProjectFileSearch(access: folderAccess, fileSystem: fileSystem, settings: settings)
        projectSearch = picker
        let query = purpose == .findText || purpose == .findFolderText ? editor.surface.find.selectedQuery(maximumUnits: 256) : nil
        picker.present(in: parent, root: folder, purpose: purpose, query: query, isCurrent: { [weak self] in
            self?.document == current && self?.projectFolder == project
        }) { [weak self] selection, destination in
            self?.open(selection.url, .init(destination: destination, origin: origin), selection)
        }
    }

    private func projectFolder(containing directory: URL, repository: GitRepositoryLocation?) -> URL {
        if let repository { return repository.root }
        if let preferredFolder, directory.pathComponents.map({ Data($0.utf8) })
            .starts(with: preferredFolder.pathComponents.map({ Data($0.utf8) })) { return preferredFolder }
        return directory
    }

    func bindOutline(to surface: NativeTextEditorSurface) {
        text = surface
        surface.onOutlineChanged = { [weak self] in self?.refreshOutline() }
    }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if value {
            refreshOpenFiles()
            if mode == .outline { refreshOutline(forceReload: true) }
            enqueueVisibleFolders()
            startRead()
        } else {
            if root == nil { rootAttempted = false }
            work?.cancel()
            queued.removeAll()
            clearGitBadges()
        }
    }

    func visit(shown: Bool, width: CGFloat) -> EditorSidebarVisit {
        .init(shown: shown, width: width, folder: root?.url, mode: mode)
    }

    private var rows: [Item] { mode == .files ? root?.children ?? [] : openItems }
    private var selected: Item? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? Item : nil
    }

    private func refreshOpenFiles() {
        guard visible, mode != .outline else { return }
        let files = openFiles()
        let nextEdited = Set(files.lazy.filter(\.isEdited).map { $0.url.standardizedFileURL })
        let changedEdits = edited.symmetricDifference(nextEdited)
        if settings.editorPreferences.showsWorkingGitChanges, !edited.isSubset(of: nextEdited) { gitBadges.invalidate(clear: false) }
        edited = nextEdited
        if mode == .open {
            let previous = selected?.url ?? document
            openItems = files.map { Item(url: $0.url.standardizedFileURL, name: $0.url.lastPathComponent, folder: false) }
            outline.reloadData()
            select(previous, scroll: false)
            folderLabel.stringValue = openItems.isEmpty ? "No open local files" : "Open local files"
            folderLabel.toolTip = nil
        } else if !changedEdits.isEmpty {
            // A native tab switch can leave old cells cached outside the
            // viewport. Refresh the exact edited rows even before scrolling.
            let changedRows = IndexSet(changedEdits.compactMap { row(for: $0) })
            outline.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
        }
        updateGitBadges()
    }

    @objc private func switchMode(_ sender: NSSegmentedControl) {
        guard let choice = EditorSidebarMode(rawValue: sender.selectedSegment) else { return }
        selectMode(choice)
    }

    @objc private func switchCompactMode(_ sender: NSPopUpButton) {
        guard let choice = EditorSidebarMode(rawValue: sender.indexOfSelectedItem) else { return }
        selectMode(choice)
    }

    func selectMode(_ choice: EditorSidebarMode) {
        guard mode != choice else { return }
        let previous = selected?.url ?? document
        if mode == .files { recordExpanded() }
        mode = choice
        modeControl.selectedSegment = mode.rawValue
        compactModeControl.selectItem(at: mode.rawValue)
        refreshButton.isHidden = mode != .files
        updateHeading()
        outline.setAccessibilityLabel(mode == .outline ? "Document outline" : "Editor files")
        showStatus(nil)
        switch mode {
        case .open:
            refreshOpenFiles()
        case .outline:
            clearGitBadges()
            refreshOutline(forceReload: true)
        case .files:
            outline.reloadData()
            updateFolderHeading()
            restoreExpanded(rows)
            select(previous, scroll: false)
            startRead()
            refreshOpenFiles()
        }
        if visible { ToolContentMotion.reveal(scroll) }
    }

    private func updateHeading() {
        outlineSearch.isHidden = mode != .outline
        folderLabel.isHidden = mode == .outline
    }

    private func updateFolderHeading() {
        guard mode == .files else { return }
        let folder = root?.url ?? document.deletingLastPathComponent()
        let name = root?.name ?? folder.lastPathComponent
        let head = settings.showsGitControls && root != nil ? checkoutHead?.displayName : nil
        folderLabel.stringValue = head.map { name + " · " + $0 } ?? name
        folderLabel.toolTip = head.map { folder.path + "\n" + $0 } ?? folder.path
    }

    #if DEBUG
    var folderHeadingForVerification: String { folderLabel.stringValue }
    #endif

    func focusOutlineSearch() {
        if view.window?.makeFirstResponder(outlineSearch) == true { outlineSearch.selectText(nil) }
    }

    func ownsFocus(_ responder: NSResponder?) -> Bool {
        if let editor = outlineSearch.currentEditor(), responder === editor { return true }
        return (responder as? NSView)?.isDescendant(of: view) == true
    }

    private func searchOutline(_ text: String) {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != outlineQuery else { return }
        outlineQuery = next
        refreshOutline(forceReload: true)
        if outline.selectedRow < 0 { selectOutlineRow(0) }
    }

    private func selectOutlineRow(_ row: Int) {
        guard sections.indices.contains(row) else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func outlineCommand(_ command: NativeQueryInput.Command) -> Bool {
        guard visible, mode == .outline else { return false }
        switch command {
        case .submit:
            if outline.selectedRow < 0 { selectOutlineRow(0) }
            openSelection(nil)
        case .cancel:
            if outlineQuery.isEmpty { view.window?.makeFirstResponder(text?.textView) }
            else {
                outlineSearch.stringValue = ""
                (outlineSearch.currentEditor() as? NSTextView)?.string = ""
                searchOutline("")
            }
        case .up: selectOutlineRow(max(0, outline.selectedRow - 1))
        case .down: selectOutlineRow(min(sections.count - 1, outline.selectedRow + 1))
        }
        return true
    }

    private func refreshOutline(forceReload: Bool = false) {
        let presentation = text?.outlinePresentation
        if presentation == nil, shownOutline != nil, !visible || mode != .outline {
            shownOutline = nil
            sections = []
            if mode == .outline { outline.reloadData() }
        }
        guard visible, mode == .outline else { return }
        let value = presentation?.value
        if forceReload || value != shownOutline {
            let selected = outline.selectedRow < 0 ? nil : (outline.item(atRow: outline.selectedRow) as? Section)?.entry
            let visibleFrame = scroll.contentView.bounds
            shownOutline = value
            let entries = value?.entries ?? []
            if outlineQuery.isEmpty { sections = entries.map(Section.init) }
            else if outlineQuery.utf8.count <= 256 {
                sections = entries.filter { $0.title.localizedStandardContains(outlineQuery) }.map(Section.init)
            } else { sections = [] }
            outline.reloadData()
            if let selected, let row = sections.firstIndex(where: { $0.entry.title == selected.title && $0.entry.line == selected.line }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if !forceReload {
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(visibleFrame).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        outline.setAccessibilityLabel("Document outline")
        guard let presentation, presentation.generation == text?.generation else {
            showStatus("Updating outline…")
            return
        }
        switch presentation.value.availability {
        case .unsupported: showStatus("Outline is unavailable for this language.")
        case .limited: showStatus(!outlineQuery.isEmpty && sections.isEmpty ? "No matches in the available outline."
            : "Showing the available outline within the document limits.")
        case .ready: showStatus(sections.isEmpty ? (outlineQuery.isEmpty ? "No outline entries yet." : "No matching entries.") : nil)
        }
    }

    @objc private func refreshFiles(_ sender: Any?) { resetTree(preserveExpansion: true) }

    private func recordExpanded() {
        for index in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: index) as? Item, item.folder, outline.isItemExpanded(item) {
                restoringExpanded.insert(item.url)
            }
        }
    }

    private func restoreExpanded(_ items: [Item]) {
        for item in items where restoringExpanded.remove(item.url) != nil {
            outline.expandItem(item)
            if let children = item.children { restoreExpanded(children) }
        }
    }

    private func resetTree(preserveExpansion: Bool) {
        if preserveExpansion && mode == .files { recordExpanded() }
        else { restoringExpanded.removeAll() }
        work?.cancel()
        version = UUID()
        root = nil
        if !preserveExpansion {
            repository = nil
            checkoutHead = nil
            updateFolderHeading()
        }
        clearGitBadges()
        queued.removeAll()
        loadedFolders = 0
        rootAttempted = false
        if mode == .files { outline.reloadData(); startRead() }
    }

    private func enqueueVisibleFolders() {
        guard mode == .files else { return }
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? Item, outline.isItemExpanded(item) else { continue }
            enqueue(item)
        }
    }

    private func enqueue(_ item: Item) {
        guard item.folder, item.children == nil, !queued.contains(where: { $0 === item }) else { return }
        guard loadedFolders + queued.count + (work == nil ? 0 : 1) < 32 else {
            showStatus("This sidebar has reached its expanded-folder limit.")
            return
        }
        queued.append(item)
    }

    private func startRead() {
        guard visible, mode == .files, work == nil else { return }
        let revision = version
        if let root {
            guard !queued.isEmpty else { return }
            let next = queued.removeFirst()
            work = Task { [weak self] in await self?.read(next, within: root, revision: revision) }
        } else if !rootAttempted {
            rootAttempted = true
            let directory = document.deletingLastPathComponent()
            work = Task { [weak self] in await self?.openRoot(containing: directory, revision: revision) }
        }
    }

    private func openRoot(containing directory: URL, revision: UUID) async {
        defer { work = nil; startRead() }
        let checkout = settings.showsGitControls ? try? await GitReviewAccess.discover(in: directory,
            fileSystem: fileSystem, access: folderAccess) : nil
        let repo = checkout?.location
        guard !Task.isCancelled, revision == version else { return }
        let url = projectFolder(containing: directory, repository: repo)
        let item = Item(url: url, name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent, folder: true)
        do {
            let snapshot = try await list(item, within: item)
            guard !Task.isCancelled, revision == version else { return }
            repository = repo
            checkoutHead = checkout?.head
            root = item
            install(snapshot, at: item)
        } catch { if !Task.isCancelled, revision == version { showStatus(readMessage(error)) } }
    }

    private func read(_ item: Item, within root: Item, revision: UUID) async {
        defer { work = nil; startRead() }
        guard item.children == nil else { return }
        do {
            let snapshot = try await list(item, within: root)
            guard !Task.isCancelled, revision == version else { return }
            install(snapshot, at: item)
        } catch { if !Task.isCancelled, revision == version { showStatus(readMessage(error)) } }
    }

    private func list(_ item: Item, within root: Item) async throws -> BoundedFolderListing {
        if mode == .files { showStatus("Reading \(item.name)…") }
        let prepared = folderAccess.prepareAccess(to: [item.url])
        let lifetime = await folderAccess.retainAccess(for: [item.url])
        try Task.checkCancellation()
        guard folderAccess.isCurrent(prepared), !TraverseAccessPolicy.requiresFolderSelection || lifetime.covers(item.url) else {
            throw LocalStorageError.accessDenied
        }
        return try await fileSystem.boundedEntries(in: item.url, within: root.url,
            showHidden: settings.showsHiddenFiles, retaining: lifetime)
    }

    private func install(_ snapshot: BoundedFolderListing, at item: Item) {
        item.children = snapshot.entries.filter { $0.name.lowercased() != ".git" && ($0.kind == .directory || $0.kind == .file) }.map {
            Item(url: $0.url.standardizedFileURL, name: $0.name, folder: $0.kind == .directory)
        }
        loadedFolders += 1
        guard mode == .files else { return }
        if item === root {
            updateFolderHeading()
            outline.reloadData()
        } else { outline.reloadItem(item, reloadChildren: true) }
        restoreExpanded(item.children ?? [])
        let currentFileMissing = selected == nil && !revealDocument()
        showStatus(!snapshot.isComplete ? "Showing part of this folder. Open it in the browser to see all files."
            : snapshot.hasUnavailableItems ? "Some items could not be shown."
            : currentFileMissing ? Self.missingCurrentFile : nil)
        updateGitBadges()
    }

    func row(for url: URL) -> Int? {
        (0..<outline.numberOfRows).first {
            guard let item = outline.item(atRow: $0) as? Item else { return false }
            return item.url.path.utf8.elementsEqual(url.path.utf8)
        }
    }

    @discardableResult private func select(_ url: URL, scroll: Bool) -> Bool {
        guard let row = row(for: url) else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll { outline.scrollRowToVisible(row) }
        return true
    }

    // A pending ancestor uses the same bounded reader as manual expansion.
    // Once a listing arrives, an explicit selection takes precedence.
    private func revealDocument() -> Bool {
        guard let root else { return true }
        let parts = document.pathComponents, project = root.url.pathComponents
        guard parts.count > project.count, zip(parts, project).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { return false }
        var branch = rows
        for name in parts.dropFirst(project.count).dropLast() {
            guard let folder = branch.first(where: { $0.folder && $0.name.utf8.elementsEqual(name.utf8) }) else { return false }
            outline.expandItem(folder)
            guard let children = folder.children else { return true }
            branch = children
        }
        return select(document, scroll: true)
    }

    func historyTarget(for url: URL) -> GitRepositoryLocation? {
        guard settings.showsGitControls, let repository, repository.filePath(for: url) != nil else { return nil }
        return repository
    }

    var currentHistoryFile: URL? { historyTarget(for: document) == nil ? nil : document }

    #if DEBUG
    var gitStatusForVerification: String {
        let rows = outline.rows(in: outline.visibleRect)
        let eligible = repository.map { visibleGitBadgeURLs(in: $0).count } ?? 0
        return "visible \(visible), mode \(mode), key \(view.window?.isKeyWindow == true), visible rows \(rows.length), eligible \(eligible), paused \(gitBadges.paused), request \(gitBadges.isReading), viewport \(gitBadges.inspectedCount), marks \(gitBadges.markedCount), status \(refreshButton.toolTip ?? "empty")"
    }
    #endif

    func windowDidBecomeKey() {
        gitBadges.invalidate(clear: false)
        refreshOpenFiles()
    }

    func pauseGitBadges() async {
        await gitBadges.pauseAndDrain()
    }

    func resumeGitBadges() {
        gitBadges.resume()
    }

    private func clearGitBadges() {
        gitBadges.invalidate(clear: true)
    }

    private func resetGitBadges() {
        clearGitBadges()
        updateGitBadges()
    }

    private func redrawRows() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let end = min(outline.numberOfRows, NSMaxRange(visible))
        guard end > visible.location else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<end), columnIndexes: IndexSet(integer: 0))
    }

    private func visibleGitBadgeURLs(in repository: GitRepositoryLocation) -> [URL] {
        guard visible, mode != .outline, view.window?.isKeyWindow == true, settings.showsGitControls,
              self.repository == repository else { return [] }
        let viewport = outline.rows(in: outline.visibleRect)
        guard viewport.location != NSNotFound, viewport.length > 0 else { return [] }
        let end = min(outline.numberOfRows, NSMaxRange(viewport))
        guard end > viewport.location else { return [] }
        let urls = (viewport.location..<end).lazy.compactMap { [self] row -> URL? in
            guard let item = outline.item(atRow: row) as? Item, !item.folder, repository.filePath(for: item.url) != nil else { return nil }
            return item.url
        }
        return Array(urls.prefix(GitViewportBadges.maximumVisibleFiles))
    }

    func updateGitBadges() { gitBadges.update() }

    private func gitBadgeRequest() -> GitViewportBadges.Request? {
        guard let repository else { return nil }
        let urls = visibleGitBadgeURLs(in: repository)
        guard !urls.isEmpty, let access = GitReviewAccess(location: repository, fileSystem: fileSystem, access: folderAccess) else { return nil }
        return .init(access: access, urls: urls, generation: version,
                     inspectWorkingBytes: settings.editorPreferences.showsWorkingGitChanges)
    }

    @objc private func openSelection(_ sender: Any?) {
        guard visible else { return }
        if mode == .outline {
            guard outline.selectedRow >= 0, let section = outline.item(atRow: outline.selectedRow) as? Section,
                  let text, let presentation = text.outlinePresentation,
                  presentation.generation == text.generation, presentation.value == shownOutline else { return }
            _ = text.goToTextOffset(section.entry.offset, generation: presentation.generation)
            return
        }
        guard let selected else { return }
        if selected.folder {
            if outline.isItemExpanded(selected) { outline.collapseItem(selected) }
            else { outline.expandItem(selected) }
        } else { open(selected.url, nil, nil) }
    }

    @objc private func historySelection(_ sender: Any?) {
        guard let selected, !selected.folder, historyTarget(for: selected.url) != nil else { return }
        onHistory?(selected.url)
    }

    @objc private func revisionSelection(_ item: NSMenuItem) {
        guard let selected, !selected.folder, historyTarget(for: selected.url) != nil,
              let intent = EditorGitRevisionIntent(rawValue: item.tag) else { return }
        onRevision?(selected.url, intent)
    }

    private func showStatus(_ message: String?) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
    }

    private func readMessage(_ error: Error) -> String {
        (error as? LocalStorageError)?.userMessage ?? "This folder could not be read."
    }

    func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if mode == .outline { return item == nil ? sections.count : 0 }
        return (item as? Item).map { $0.children?.count ?? 0 } ?? rows.count
    }
    func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if mode == .outline { return sections[index] }
        if let parent = item as? Item { return parent.children![index] }
        return rows[index]
    }
    func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let value = item as? Item else { return false }
        return value.folder && value.children?.isEmpty != true
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Item else { return }
        enqueue(item)
        startRead()
    }
    func outlineView(_ view: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("EditorFileCell")
        let cell = view.makeView(withIdentifier: identifier, owner: nil) as? EditorFileCell ?? EditorFileCell()
        cell.identifier = identifier
        if let entry = item as? Item {
            cell.configure(name: entry.name, folder: entry.folder, edited: edited.contains(entry.url), location: entry.url.path,
                git: settings.showsGitControls ? gitBadges.badge(for: entry.url) : nil)
        } else if let section = item as? Section { cell.configure(outline: section.entry) }
        else { return nil }
        return cell
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let item = outline.item(atRow: row) as? Item else { return nil }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = NSMenu()
        if item.folder {
            guard canFindInSelectedFolder, let editor = view.window?.windowController as? NativeTextEditorWindow else { return nil }
            menu.addItem(BrowserMenus.item("Find Text in Folder…", #selector(NativeTextEditorWindow.findSelectedFolderText(_:)), target: editor))
            return menu
        }
        menu.addItem(BrowserMenus.item("Open in Editor", #selector(openSelection(_:)), target: self))
        if historyTarget(for: item.url) != nil {
            menu.addItem(BrowserMenus.item("Git File History…", #selector(historySelection(_:)), target: self))
            menu.addItem(BrowserMenus.item("Open or Compare Git Revision…", #selector(revisionSelection(_:)), target: self))
            let pair = BrowserMenus.item("Compare Git Revisions…", #selector(revisionSelection(_:)), target: self)
            pair.tag = EditorGitRevisionIntent.comparePair.rawValue
            menu.addItem(pair)
        }
        return menu
    }

    private final class EditorFileCell: NSTableCellView {
        private let mark = NSImageView()
        private let trailingNote = NSTextField(labelWithString: "")
        private var rowLeading: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            imageView = icon
            textField = label
            mark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved edits")
            mark.contentTintColor = .controlAccentColor
            mark.setAccessibilityElement(false)
            trailingNote.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            trailingNote.textColor = .secondaryLabelColor
            trailingNote.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailingNote.setAccessibilityElement(false)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [icon, label, spacer, mark, trailingNote])
            stack.spacing = 6; stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            rowLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
            NSLayoutConstraint.activate([
                rowLeading,
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15).interfaceScaled,
                icon.heightAnchor.constraint(equalToConstant: 15).interfaceScaled,
                mark.widthAnchor.constraint(equalToConstant: 8).interfaceScaled,
                mark.heightAnchor.constraint(equalToConstant: 8).interfaceScaled
            ])
        }
        required init?(coder: NSCoder) { nil }

        func configure(name: String, folder: Bool, edited: Bool, location: String, git: GitStatusBadge?) {
            rowLeading.constant = 2
            textField?.stringValue = name
            imageView?.image = NSImage(systemSymbolName: folder ? "folder" : "doc.text", accessibilityDescription: nil)
            imageView?.contentTintColor = .secondaryLabelColor
            mark.isHidden = !edited
            let details = (edited ? ["Unsaved edits"] : []) + (git?.details ?? [])
            trailingNote.stringValue = git?.text ?? ""
            trailingNote.isHidden = git == nil
            toolTip = ([location] + details).joined(separator: " · ")
            setAccessibilityLabel(([name] + details).joined(separator: ", "))
            InterfacePresentation.shared.apply(in: self)
        }

        func configure(outline entry: EditorDocumentOutline.Entry) {
            let line = "Line \(entry.line)"
            configure(name: entry.title, folder: false, edited: false, location: line, git: nil)
            rowLeading.constant = 2 + CGFloat(min(6, entry.depth)) * 10
            imageView?.image = NSImage(systemSymbolName: entry.kind.icon, accessibilityDescription: nil)
            setAccessibilityLabel(entry.title + ", " + line)
            trailingNote.stringValue = String(entry.line)
            trailingNote.isHidden = false
        }
    }

    final class EditorFilesOutline: NSOutlineView {
        var onEnter: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if selectedRow >= 0 && (event.keyCode == 36 || event.keyCode == 76)
                && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                onEnter?()
            } else { super.keyDown(with: event) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            (delegate as? EditorFileSidebar)?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
        }
    }
}
