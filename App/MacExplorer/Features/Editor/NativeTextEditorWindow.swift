import AppKit
import Combine
import LocalStorage
import UniformTypeIdentifiers
#if canImport(FileOperations)
import FileOperations
#endif

/// Standard nil-target actions must continue following the focused responder,
/// which may be a document or a Find field rather than this window controller.
@objc private protocol NativeTextUndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

struct EditorTextCopyResult { let id: UUID; let title: String }
struct EditorDiskComparisonSource {
    let url: URL
    let capture: @MainActor () async throws -> EditorComparisonCapture
}

/// Native presentation only. The document owner supplies semantic commands and
/// installs the app's shared tool chrome; this class has no file I/O authority.
@MainActor
final class NativeTextEditorWindow: NSWindowController, NSWindowDelegate, NSPopoverDelegate, NSMenuDelegate, NSUserInterfaceValidations {
    enum SaveAnnouncement {
        case saved(newerEditsRemain: Bool), notSaved, conflict, historyNeedsReview, needsReview, stopped

        var message: String {
            switch self {
            case .saved(false): String(localized: "Saved.")
            case .saved(true): String(localized: "Captured text saved. Newer edits remain unsaved.")
            case .notSaved: String(localized: "Not saved. Your text remains in the editor.")
            case .conflict: String(localized: "Not saved. The file changed. Reload or save a copy.")
            case .historyNeedsReview: String(localized: "Not saved. Review saved versions. Your text remains in the editor.")
            case .needsReview: String(localized: "Save needs review. Keep this text and review the result.")
            case .stopped: String(localized: "Save stopped. Your text remains in the editor.")
            }
        }
    }
    let surface = NativeTextEditorSurface(frame: .zero)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let saveAsButton = NSButton(title: "Save As…", target: nil, action: nil)
    let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    let recoveryButton = NSButton(title: "Review Versions…", target: nil, action: nil)
    let beforeSaveButton = NSButton(title: "Before Save", target: nil, action: nil)
    let editedSaveButton = NSButton(title: "Edited Text", target: nil, action: nil)
    var onRefusedVersion: ((RemoteRetainedTextChoice.Version) -> Void)?
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let textCopyButton = NSButton(title: "Save a Text Copy…", target: nil, action: nil)
    let textCopyResultsButton = NSButton(title: "Copy Results…", target: nil, action: nil)
    let wrapping = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    let language = NSPopUpButton()
    private let status = NSTextField(labelWithString: "Ready")
    private let position = NSTextField(labelWithString: "Ln 1, Col 1")
    private let format = NSTextField(labelWithString: "UTF-8 · LF")
    private let jsonIssuesButton = NSButton()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let locationRow = NSStackView()
    private let locationIcon = NSImageView()
    private let locationLabel = NSTextField(labelWithString: "")
    let scrollContextButton = NSButton()
    private let recoveryActions = NSStackView()
    private let refusedActions = NSStackView()
    private let copyActions = NSStackView()
    private let commandBar = NSStackView()
    private var closing = false
    private var acceptedCloseEditable: Bool?
    private var hasPresentedEditor = false
    let openSearchID = UUID()
    private var openSearchPresented = false
    private var openSearchName: String
    private var openSearchContext = ""
    private var openSearchStorage: EditorOpenSearch?
    var openSearch: EditorOpenSearch {
        if let openSearchStorage { return openSearchStorage }
        let search = EditorOpenSearch(owner: self); openSearchStorage = search
        return search
    }
    var retainPresentationDuringClose = false
    private var ownMenu: NSMenu?
    private var keyboardObservation: AnyCancellable?
    private weak var keyboardSettings: BrowserSettings?
    private var usesControlAliases = false
    private let lineNavigation = EditorLineNavigation()
    private var navigationChoice: Task<Void, Never>?
    private var jsonSchemaSnapshot: String?
    private var comparison: EditorComparisonWindow?
    private var openEditorComparison: EditorComparisonWindow?
    private var diskComparison: (url: URL, view: EditorComparisonWindow)?
    private var clipboardComparison: EditorComparisonWindow?
    private var unsavedChangePreview: NSPopover?
    private var documentWorking = true
    var captureComparison: (@MainActor () -> EditorComparisonCapture?)?
    var diskComparisonSource: (() -> EditorDiskComparisonSource?)?
    private var commandFinderStorage: EditorCommandFinder?
    var commandFinder: EditorCommandFinder {
        if let commandFinderStorage { return commandFinderStorage }
        let finder = EditorCommandFinder(owner: self); commandFinderStorage = finder
        return finder
    }
    private var copyResults: [EditorTextCopyResult] = []
    private var readOnlyPresentation = false
    private var consumedSaveAnnouncement: UUID?
    private(set) var fileSidebar: EditorSidebarPresentation?
    var gitLineReview: GitLineReview?
    private var gitFileHistory: GitFileHistoryWindow?
    private var gitHistoryRequest: Task<Void, Never>?
    private var gitRevisionEditor: NativeTextSnapshotController?
    private var gitRevisionDiff: EditorComparisonWindow?
    var onEditedChanged: (() -> Void)?

    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onTextCopy: (() -> Void)?
    var onTextCopyResults: ((UUID?) -> Void)?
    var onReload: (() -> Void)?
    var onRecovery: (() -> Void)?
    var onStop: (() -> Void)?
    var onLanguage: ((TextSyntaxLanguage) -> Void)?
    var onWrapping: (() -> Void)?
    var saveAsMenuTitle: String?
    var recoveryMenuTitle: String?
    var shouldClose: (() -> Bool)?
    var didClose: (() -> Void)?

    init(displayName: String, supportsFileSidebar: Bool = false, installChrome: (NSWindow) -> Void) {
        openSearchName = displayName
        let window = ToolWindowChrome.makeWindow(title: displayName + " — Traverse", size: .init(width: 920, height: 650),
            minimumSize: .init(width: 720, height: 440))
        super.init(window: window)
        window.delegate = self
        surface.setAccessibilityLabel("Text editor")
        surface.textView.onCompleteLocalName = { [weak self] in self?.completeLocalName(nil) }
        for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton, textCopyButton, textCopyResultsButton, beforeSaveButton, editedSaveButton] {
            button.bezelStyle = .rounded; button.target = self
        }
        saveButton.action = #selector(saveDocument(_:))
        saveAsButton.action = #selector(saveDocumentAs(_:))
        reloadButton.action = #selector(reloadDocument(_:))
        recoveryButton.action = #selector(reviewVersions(_:))
        beforeSaveButton.action = #selector(reviewBeforeSave(_:))
        editedSaveButton.action = #selector(reviewEditedSave(_:))
        beforeSaveButton.setAccessibilityIdentifier("editor-refused-before")
        editedSaveButton.setAccessibilityIdentifier("editor-refused-edited")
        beforeSaveButton.toolTip = "Review the retained starting text for this unsubmitted Save."
        editedSaveButton.toolTip = "Review the exact text captured for this unsubmitted Save, including when you typed afterward."
        beforeSaveButton.isHidden = true; editedSaveButton.isHidden = true
        stopButton.action = #selector(stopDocumentWork(_:))
        textCopyButton.action = #selector(saveTextCopy(_:))
        textCopyResultsButton.action = #selector(showTextCopyResults(_:))
        saveButton.setAccessibilityIdentifier("editor-save")
        saveAsButton.setAccessibilityIdentifier("editor-save-as")
        reloadButton.setAccessibilityIdentifier("editor-reload")
        recoveryButton.setAccessibilityIdentifier("editor-versions")
        stopButton.setAccessibilityIdentifier("editor-stop")
        textCopyButton.setAccessibilityIdentifier("editor-save-text-copy")
        textCopyResultsButton.setAccessibilityIdentifier("editor-text-copy-results")
        wrapping.state = .on; wrapping.target = self; wrapping.action = #selector(toggleWrap(_:))
        language.addItems(withTitles: TextSyntaxLanguage.allCases.map(\.title))
        language.target = self; language.action = #selector(changeLanguage(_:))
        language.setAccessibilityLabel("Syntax language")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = commandBar
        let viewport: NSView
        if supportsFileSidebar {
            let sidebar = EditorSidebarPresentation(text: surface)
            fileSidebar = sidebar
            sidebar.button.target = self
            sidebar.button.action = #selector(toggleEditorSidebar(_:))
            toolbar.addArrangedSubview(sidebar.button)
            viewport = sidebar.split
        } else { viewport = surface }
        for view in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton, spacer] {
            toolbar.addArrangedSubview(view)
        }
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.distribution = .fill; toolbar.alignment = .centerY
        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.maximumNumberOfLines = 1; locationLabel.isSelectable = true
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.setAccessibilityIdentifier("editor-location")
        locationLabel.setAccessibilityLabel("Editing location")
        locationIcon.contentTintColor = .secondaryLabelColor
        locationIcon.setAccessibilityElement(false)
        locationIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        locationIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        locationRow.addArrangedSubview(locationIcon); locationRow.addArrangedSubview(locationLabel)
        scrollContextButton.isBordered = false
        scrollContextButton.alignment = .right
        scrollContextButton.isHidden = true
        scrollContextButton.imagePosition = .imageLeading
        scrollContextButton.contentTintColor = .secondaryLabelColor
        scrollContextButton.cell?.lineBreakMode = .byTruncatingHead
        scrollContextButton.font = .systemFont(ofSize: 11, weight: .semibold)
        scrollContextButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        scrollContextButton.setAccessibilityIdentifier("editor-scroll-context")
        scrollContextButton.target = self
        scrollContextButton.action = #selector(goToVisibleScope(_:))
        locationRow.addArrangedSubview(scrollContextButton)
        scrollContextButton.widthAnchor.constraint(lessThanOrEqualTo: locationRow.widthAnchor, multiplier: 0.46).isActive = true
        scrollContextButton.heightAnchor.constraint(equalTo: locationIcon.heightAnchor).isActive = true
        surface.onScrollContextChanged = { [weak self] in self?.displayScrollContext($0) }
        surface.onReviewUnsavedLine = { [weak self] in self?.reviewUnsavedLine($0) == true }
        surface.onUnsavedLineBaselineChanged = { [weak self] in self?.closeUnsavedChangePreview() }
        locationRow.orientation = .horizontal; locationRow.spacing = 6; locationRow.alignment = .centerY
        locationRow.isHidden = true
        banner.maximumNumberOfLines = 6; banner.textColor = .secondaryLabelColor
        banner.font = .systemFont(ofSize: 12); banner.isSelectable = true; banner.isHidden = true
        // Two native rows keep the complete labels available at minimum width
        // and larger interface sizes, without squeezing four actions together.
        refusedActions.addArrangedSubview(beforeSaveButton); refusedActions.addArrangedSubview(editedSaveButton)
        copyActions.addArrangedSubview(textCopyButton); copyActions.addArrangedSubview(textCopyResultsButton)
        for row in [refusedActions, copyActions] {
            row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
            recoveryActions.addArrangedSubview(row)
        }
        refusedActions.isHidden = true; copyActions.isHidden = true
        recoveryActions.orientation = .vertical; recoveryActions.spacing = 8; recoveryActions.alignment = .leading
        recoveryActions.isHidden = true
        textCopyButton.isHidden = true; textCopyButton.isEnabled = false
        textCopyResultsButton.isHidden = true; textCopyResultsButton.isEnabled = false
        let statusSpacer = NSView(); statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        jsonIssuesButton.isBordered = false
        jsonIssuesButton.isHidden = true
        jsonIssuesButton.font = .systemFont(ofSize: 11, weight: .semibold)
        jsonIssuesButton.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
        jsonIssuesButton.imagePosition = .imageLeading
        jsonIssuesButton.target = self
        jsonIssuesButton.action = #selector(openJSONIssues(_:))
        jsonIssuesButton.setAccessibilityIdentifier("editor-json-issues")
        surface.onJSONIssuesChanged = { [weak self] in self?.displayJSONIssues($0) }
        let bottom = NSStackView(views: [status, statusSpacer, jsonIssuesButton, position, format, wrapping, language])
        bottom.orientation = .horizontal; bottom.spacing = 14; bottom.alignment = .centerY
        for label in [status, position, format] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let separator = NSBox(); separator.boxType = .separator
        let layout = NSStackView(views: [toolbar, locationRow, banner, recoveryActions, viewport, separator, bottom])
        layout.orientation = .vertical; layout.spacing = 10; layout.alignment = .leading
        layout.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { preconditionFailure("Native editor content") }
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        for view in [toolbar, locationRow, banner, recoveryActions, viewport, separator, bottom] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        viewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.onCaret = { [weak self] value in
            self?.position.stringValue = value.map { "Ln \($0.line), Col \($0.column)" } ?? "Updating position…"
        }
        surface.onNavigationJump = { [weak self] position in
            guard let self, let location = EditorDocumentNavigation.shared.location(in: self, position: position) else { return }
            EditorDocumentNavigation.shared.record(location)
        }
        surface.lineCommands.onNotice = { [weak self] notice in
            self?.status.stringValue = notice.message
            self?.status.toolTip = notice.message
            self?.status.textColor = .labelColor
        }
        stopButton.isHidden = true; recoveryButton.isHidden = true
        installChrome(window)
        ToolWindowChrome.position(window, relativeTo: NSApp.keyWindow ?? NSApp.mainWindow)
    }
    required init?(coder: NSCoder) { nil }

    @objc func toggleEditorSidebar(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true else { return }
        fileSidebar?.toggle()
    }

    @objc private func moveEditorFocus(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true else { return }
        fileSidebar?.moveFocus()
    }

    @objc private func showSidebarMode(_ item: NSMenuItem) {
        guard !closing, window?.isKeyWindow == true, let mode = EditorSidebarMode(rawValue: item.tag) else { return }
        fileSidebar?.showMode(mode)
    }

    @objc private func revealCurrentFile(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true, let fileSidebar, fileSidebar.canToggle else { return }
        fileSidebar.showMode(.files)
        fileSidebar.files?.revealCurrentFile()
    }

    var navigationStatus: String { status.stringValue }

    func reportNavigation(_ message: String) {
        status.stringValue = message
        status.toolTip = message
    }

    @objc func showCurrentGitHistory(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true, let files = fileSidebar?.files,
              let url = files.currentHistoryFile else { return }
        files.onHistory?(url)
    }

    @objc private func reviewCurrentGitStagedChanges(_ sender: Any?) { showCurrentGitFolderReview(.index) }
    @objc private func compareCurrentGitWorkingFolder(_ sender: Any?) { showCurrentGitFolderReview(.working) }
    @objc private func stageSavedGitFile(_ sender: Any?) {
        if canEditGitIndex { fileSidebar?.files?.onGitIndexAction?(.stageSavedFile) }
    }
    @objc private func unstageCurrentGitFile(_ sender: Any?) {
        if canEditGitIndex { fileSidebar?.files?.onGitIndexAction?(.unstage) }
    }

    private var canEditGitIndex: Bool {
        !closing && !documentWorking && !readOnlyPresentation && gitHistoryRequest == nil
            && window?.isKeyWindow == true && window?.attachedSheet == nil && !surface.textView.hasMarkedText()
            && fileSidebar?.files?.currentHistoryFile != nil && fileSidebar?.files?.onGitIndexAction != nil
            && !ApplicationFileActivity.gate.isClosed
    }

    func editGitIndex(_ action: GitIndexEditAction, for url: URL, fileSystem: LocalFileSystem,
                      access: FolderAccessController, settings: BrowserSettings, matchingSavedText: LocalTextReadToken?,
                      hasUnsavedEdits: @escaping @MainActor () -> Bool, isCurrent: @escaping @MainActor () -> Bool) {
        guard canEditGitIndex else { return }
        requestGitReview(for: url, fileSystem: fileSystem, access: access, settings: settings) { [weak self] review, path, parent in
            guard let self, isCurrent() else { return }
            do {
                let outcome = try await GitIndexEditFlow.run(action, path: path, using: review, in: parent,
                    hasUnsavedEdits: hasUnsavedEdits, matchingSavedText: matchingSavedText) {
                        !self.closing && parent.isKeyWindow && isCurrent() && !ApplicationFileActivity.gate.isClosed
                    }
                if let notice = outcome.notice(for: action) { reportNavigation(notice) }
            } catch is CancellationError { return }
            catch { reportNavigation(GitIndexEditFlow.message(for: error)) }
        }
    }

    private func showCurrentGitFolderReview(_ mode: GitComparisonModel.Mode) {
        guard !closing, window?.isKeyWindow == true, let files = fileSidebar?.files,
              let url = files.currentHistoryFile else { return }
        files.onFolderReview?(url, mode)
    }

    @objc func chooseCurrentGitRevision(_ sender: Any?) {
        showGitRevisionChoices(.openOrCompare)
    }

    @objc private func compareCurrentGitRevisions(_ sender: Any?) {
        showGitRevisionChoices(.comparePair)
    }

    @objc private func compareEditorWithGit(_ sender: NSMenuItem) {
        guard let intent = EditorGitRevisionIntent(rawValue: sender.tag), intent == .compareHead || intent == .compareIndex else { return }
        showGitRevisionChoices(intent)
    }

    @objc private func chooseCurrentGitWorktree(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true, let files = fileSidebar?.files, let url = files.currentHistoryFile else { return }
        files.onWorktree?(url)
    }

    private func showGitRevisionChoices(_ intent: EditorGitRevisionIntent) {
        guard !closing, window?.isKeyWindow == true, let files = fileSidebar?.files,
              let url = files.currentHistoryFile else { return }
        files.onRevision?(url, intent)
    }

    func openGitHistory(for url: URL, fileSystem: LocalFileSystem, access: FolderAccessController, settings: BrowserSettings) {
        requestGitReview(for: url, fileSystem: fileSystem, access: access, settings: settings) { [weak self] access, path, parent in
            guard let self else { return }
            if let gitFileHistory, gitFileHistory.matches(access.location, path: path) { gitFileHistory.present(); return }
            gitFileHistory?.window?.performClose(nil)
            let review = GitFileHistoryWindow(parent: parent, settings: settings, access: access, path: path,
                local: ApplicationLocalTextEditors.shared.reviewSource(for: url))
            gitFileHistory = review
            review.didClose = { [weak self, weak review] in if self?.gitFileHistory === review { self?.gitFileHistory = nil } }
            review.present()
        }
    }

    func openGitFolderReview(for url: URL, mode: GitComparisonModel.Mode, fileSystem: LocalFileSystem,
                             access: FolderAccessController, settings: BrowserSettings, workspace: BrowserWorkspaceController) {
        requestGitReview(for: url, fileSystem: fileSystem, access: access, settings: settings) { [weak self, weak workspace] review, _, parent in
            guard self?.fileSidebar?.files?.currentHistoryFile == url, let workspace, !workspace.isClosing else { return }
            workspace.presentGitComparison(access: review, parent: parent, settings: settings, mode: mode)
        }
    }

    func chooseGitRevision(for url: URL, intent: EditorGitRevisionIntent,
                           fileSystem: LocalFileSystem, access: FolderAccessController, settings: BrowserSettings,
                           capture: @escaping @MainActor () -> EditorComparisonCapture.Side?) {
        requestGitReview(for: url, fileSystem: fileSystem, access: access, settings: settings) { [weak self] access, path, parent in
            guard let self else { return }
            @MainActor func compareBuffer(with label: String, detail: String,
                                        read: @escaping @MainActor () async throws -> EditorComparisonCapture.Side) async {
                guard !closing, parent.isVisible, parent.isKeyWindow || NSApp.keyWindow == nil,
                      settings.showsGitControls else { return }
                await presentGitRevisionDiff(parent: parent, settings: settings,
                    labels: .init(title: "Git Text Diff", source: path.display, left: label,
                        right: "Editor Buffer · " + url.lastPathComponent, detail: detail, refresh: "Refresh")) {
                    guard let text = capture() else {
                        throw EditorComparisonLoadFailure.unavailable("The editor’s current text is unavailable.")
                    }
                    return .init(left: try await read(), right: text)
                }
            }
            do {
                if intent == .compareHead || intent == .compareIndex {
                    let language = TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: url.lastPathComponent) ?? "")
                    if intent == .compareHead {
                        let (version, contents) = try await access.versionText(path: path, at: .head)
                        guard let source = version.editorTextSource else {
                            reportNavigation("HEAD has no comparable file at this path.")
                            return
                        }
                        let text = try contents ?? .original(Data())
                        let before = EditorComparisonCapture.Side(text: text.text, format: text.format, language: language)
                        await compareBuffer(with: "HEAD · " + source.label,
                            detail: "This comparison keeps the selected HEAD commit. Refresh rereads the editor.") { before }
                    } else {
                        await compareBuffer(with: "Git Index", detail: "Refresh reads the current Git index and the editor again.") {
                            do {
                                let staged = try await access.indexText(for: url)
                                return .init(text: staged.text, format: staged.format, language: language)
                            } catch is CancellationError { throw CancellationError() }
                            catch { throw EditorComparisonLoadFailure.unavailable(GitReviewAccess.message(for: error)) }
                        }
                    }
                    return
                }
                let catalog = try await access.catalog()
                try Task.checkCancellation()
                let options = GitRevisionOption.choices(catalog)
                if intent == .comparePair {
                    guard let pair = await GitFileRevisionPair.choose(filename: path.display, choices: options, in: parent) else { return }
                    try Task.checkCancellation()
                    let comparison = try await pair.resolve(path: path, using: access)
                    await presentGitRevisionDiff(parent: parent, settings: settings, labels: comparison.labels, capture: comparison.read)
                    return
                }
                enum Intent: Sendable { case compare, open }
                let open = GitFileRevisionSheet<Intent>.Command(title: "Open Version", intent: .open)
                let compare = GitFileRevisionSheet<Intent>.Command(title: "Compare with Editor", intent: .compare)
                let canCompare = capture() != nil
                let sheet = GitFileRevisionSheet(filename: url.lastPathComponent, choices: options,
                    primary: canCompare ? compare : open, alternate: canCompare ? open : nil)
                guard let choice = await sheet.choose(in: parent) else { return }
                try Task.checkCancellation()
                switch choice.intent {
                case .open:
                    let (version, contents) = try await access.versionText(path: path, at: choice.revision.revision)
                    try Task.checkCancellation()
                    guard !closing, parent.isVisible else { return }
                    guard let contents, let member = version.editorTextSource?.member else {
                        reportNavigation("The selected revision has no readable text file at this path.")
                        return
                    }
                    await gitRevisionEditor?.closeAndDrain()
                    try Task.checkCancellation()
                    let viewer = NativeTextSnapshotController.gitVersion(text: contents, member: member, commit: version.commit,
                        access: access, settings: settings, parent: parent)
                    gitRevisionEditor = viewer
                    viewer.didClose = { [weak self, weak viewer] _ in if self?.gitRevisionEditor === viewer { self?.gitRevisionEditor = nil } }
                    viewer.show()
                case .compare:
                    let version = try await access.version(path: path, at: choice.revision.revision)
                    try Task.checkCancellation()
                    guard !closing, parent.isVisible else { return }
                    guard let source = version.editorTextSource else {
                        reportNavigation("The selected revision has no comparable file at this path.")
                        return
                    }
                    await compareBuffer(with: source.label,
                        detail: "Compare this pinned Git revision with the open editor. Refresh captures the editor text again.") {
                        try await access.committedSide(source.member)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                reportNavigation(GitReviewAccess.message(for: error))
            }
        }
    }

    func chooseGitWorktree(for url: URL, fileSystem: LocalFileSystem, access: FolderAccessController,
                           settings: BrowserSettings, capture: @escaping @MainActor () -> EditorComparisonCapture.Side?,
                           open: @escaping @MainActor (GitWorktreeFile, NSWindow, EditorDocumentNavigation.Location?) -> Void) {
        enum Intent: Sendable { case open, compare }
        let origin = EditorDocumentNavigation.shared.location(in: self)
        requestGitReview(for: url, fileSystem: fileSystem, access: access, settings: settings) { [weak self] review, path, parent in
            guard let self else { return }
            do {
                let listing = try await review.worktrees()
                try Task.checkCancellation()
                guard parent.isKeyWindow, parent.attachedSheet == nil, settings.showsGitControls,
                      fileSidebar?.files?.currentHistoryFile == url else { return }
                guard let choice = await GitWorktreeSheet<Intent>.choose(listing, title: "File in Git Worktree", file: url.lastPathComponent,
                    primary: .init(title: "Open File", destination: .open, identifier: "git-worktree-file"),
                    alternate: .init(title: "Compare with Editor", destination: .compare, identifier: "git-worktree-compare",
                                     enabled: capture() != nil), in: parent) else { return }
                let file = try await review.worktreeFile(path, in: choice.worktree)
                try Task.checkCancellation()
                guard !closing, parent.isVisible, parent.isKeyWindow, settings.showsGitControls,
                      fileSidebar?.files?.currentHistoryFile == url else { return }
                switch choice.destination {
                case .open: open(file, parent, origin)
                case .compare:
                    guard capture() != nil else { return }
                    let peerBuffer = ApplicationLocalTextEditors.shared.capturedEditorSource(for: file.url)
                    let label = file.head.displayName + " · " + (peerBuffer == nil ? "On Disk" : "Editor Buffer")
                    let language = TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: file.url.lastPathComponent) ?? "")
                    await presentGitRevisionDiff(parent: parent, settings: settings,
                        labels: .init(title: "Worktree Text Diff", source: path.display, left: "Current Editor",
                            right: label, detail: "Compare the current editor with the same path in another checkout.", refresh: "Refresh")) {
                        let result = try await review.worktreeFile(path, in: choice.worktree, readingText: peerBuffer == nil)
                        try Task.checkCancellation()
                        guard let first = capture() else {
                            throw EditorComparisonLoadFailure.unavailable("The original editor’s text is unavailable.")
                        }
                        if let peerBuffer {
                            guard let second = peerBuffer() else {
                                throw EditorComparisonLoadFailure.unavailable("The other editor closed or moved. Open a new comparison.")
                            }
                            return .init(left: first, right: second)
                        }
                        guard let contents = result.text else { throw GitInspectionFailure.worktreeFileUnavailable }
                        return .init(left: first, right: .init(text: contents.text, format: contents.format, language: language))
                    }
                }
            } catch is CancellationError { return }
            catch { reportNavigation(GitReviewAccess.message(for: error)) }
        }
    }

    private func presentGitRevisionDiff(parent: NSWindow, settings: BrowserSettings, labels: EditorComparisonWindow.Labels,
                                        capture: @escaping @MainActor () async throws -> EditorComparisonCapture) async {
        await gitRevisionDiff?.closeAndDrain()
        guard !Task.isCancelled, !closing, parent.isVisible else { return }
        let view = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: surface.textView.font?.pointSize ?? 13, labels: labels, capture: capture)
        gitRevisionDiff = view
        view.didClose = { [weak self, weak view] in if self?.gitRevisionDiff === view { self?.gitRevisionDiff = nil } }
        view.present()
    }

    private func requestGitReview(for url: URL, fileSystem: LocalFileSystem, access: FolderAccessController,
                                  settings: BrowserSettings,
                                  action: @escaping @MainActor (GitReviewAccess, GitSnapshotPath, NSWindow) async -> Void) {
        guard !closing, gitHistoryRequest == nil, window?.isKeyWindow == true, window?.attachedSheet == nil,
              settings.showsGitControls else { return }
        let navigator = fileSidebar?.files
        let previousStatus = status.stringValue
        let opening = "Opening Git review…"
        reportNavigation(opening)
        gitHistoryRequest = Task { [weak self, weak navigator] in
            await navigator?.pauseGitBadges()
            defer {
                navigator?.resumeGitBadges()
                if self?.status.stringValue == opening { self?.reportNavigation(previousStatus) }
                self?.gitHistoryRequest = nil
            }
            let checkout = try? await GitReviewAccess.discover(in: url.deletingLastPathComponent(), fileSystem: fileSystem, access: access)
            guard let self else { return }
            guard !Task.isCancelled, !closing, let parent = window, parent.isKeyWindow, parent.attachedSheet == nil else { return }
            guard let location = checkout?.location, let path = location.filePath(for: url),
                  let reviewAccess = GitReviewAccess(location: location, fileSystem: fileSystem, access: access) else {
                reportNavigation("Git revisions could not be found for this file.")
                return
            }
            await action(reviewAccess, path, parent)
        }
    }

    /// Presentation only; the document owner still supplies the copy action.
    func configureLocalCopyPresentation() {
        saveAsButton.title = "Save Local Copy…"
        saveAsMenuTitle = saveAsButton.title
        saveAsButton.toolTip = "Create a new text file on your Mac. The server file stays unchanged."
    }

    /// Only the remote document owner can offer exact refused-capture reads.
    func configureRefusedReview(available: Bool, enabled: Bool) {
        let available = available && !readOnlyPresentation
        for button in [beforeSaveButton, editedSaveButton] {
            button.isHidden = !available; button.isEnabled = available && enabled
        }
        refusedActions.isHidden = !available
        recoveryActions.isHidden = !available && copyActions.isHidden
        if available && recoveryButton.title == "Review Versions…" { recoveryButton.title = "All Saved Versions…" }
    }

    /// Immutable current-server snapshots have no writing or export handlers.
    /// Keep the native Find, selection, syntax and line-navigation surface.
    func configureReadOnlyPresentation() {
        readOnlyPresentation = true
        surface.textView.isEditable = false
        commandBar.isHidden = true
        for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton,
                       textCopyButton, textCopyResultsButton] {
            button.isHidden = true; button.isEnabled = false
        }
    }

    /// Native menu equivalents remain scoped to this key editor window. The
    /// existing Explorer/Custom behavior decides whether Control aliases exist;
    /// no global monitor or rewriting of text input is involved.
    func bindKeyboardBehavior(to settings: BrowserSettings) {
        keyboardSettings = settings
        synchronizeKeyboardBehavior()
        keyboardObservation = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeKeyboardBehavior() }
        }
    }
    private func synchronizeKeyboardBehavior() {
        let enabled = keyboardSettings?.behavior.controlAliasesEnabled == true
        guard usesControlAliases != enabled else { return }
        usesControlAliases = enabled
        if ToolWindowMenuOwnership.owns(self), window?.isKeyWindow == true {
            ownMenu = ToolWindowMenuOwnership.claim(self) { makeMenu(base: $0) }
        }
    }

    enum Group {
        case local, connection(UUID)
        var identifier: NSWindow.TabbingIdentifier {
            switch self {
            case .local: .init("Traverse.Editor.Local")
            case .connection(let id): .init("Traverse.Editor.Connection." + id.uuidString)
            }
        }
    }
    /// AppKit owns the tab bar, drag-out and window layout. This changes only
    /// presentation: every document keeps its own buffer, Save and close owner.
    func presentEditor(in group: Group, arrangement: EditorWindowArrangement) {
        guard !closing, let window else { return }
        if !hasPresentedEditor {
            window.tabbingIdentifier = group.identifier
            // Explicit grouping avoids pulling a window into a different Space
            // or a group with an attached sheet. System mode stays user-owned.
            window.tabbingMode = arrangement == .system ? .automatic : .disallowed
            if arrangement == .tabs, let existing = NSApp.orderedWindows.first(where: {
                $0 !== window && $0.tabbingIdentifier == group.identifier && $0.isVisible
                    && $0.isOnActiveSpace && !$0.isMiniaturized && $0.attachedSheet == nil
            }) {
                existing.addTabbedWindow(window, ordered: .above)
            }
            hasPresentedEditor = true
        }
        // Joining a native tab group changes the content geometry before the
        // new window becomes key. Settle that geometry before NSTextView's
        // first-responder caret asks TextKit to lay out the document.
        window.contentView?.layoutSubtreeIfNeeded()
        showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    override func showWindow(_ sender: Any?) {
        openSearchPresented = true
        super.showWindow(sender)
    }
    var canSearchOpenBuffer: Bool {
        openSearchPresented && !closing && window != nil && window?.attachedSheet == nil
            && !surface.textView.hasMarkedText()
    }
    var canCompareOpenBuffer: Bool { canSearchOpenBuffer && !documentWorking }
    var openBufferIdentity: EditorBufferIdentity { .init(document: openSearchID, generation: surface.generation) }
    var editableBufferIdentity: EditorBufferIdentity? {
        !readOnlyPresentation && canCompareOpenBuffer && surface.textView.isEditable ? openBufferIdentity : nil
    }
    var openEditorReference: EditorOpenSearch.Reference {
        .init(id: openSearchID, generation: surface.generation, name: openSearchName,
              context: openSearchContext, isEdited: window?.isDocumentEdited == true)
    }
    static func openSearchDocuments(preferred: NativeTextEditorWindow? = nil) -> [NativeTextEditorWindow] {
        var seen = Set<UUID>()
        return ((preferred.map { [$0] } ?? []) + (NSApp.orderedWindows + NSApp.windows).compactMap {
            $0.windowController as? NativeTextEditorWindow
        }).filter { $0.canSearchOpenBuffer && seen.insert($0.openSearchID).inserted }
    }
    func captureOpenSearchBuffer() -> EditorOpenSearch.Buffer? {
        guard canSearchOpenBuffer else { return nil }
        return .init(id: openSearchID, generation: surface.generation, name: openSearchName,
            context: openSearchContext, text: surface.textView.string)
    }
    func revealOpenSearchMatch(_ range: NSRange, generation: UUID, returningTo origin: EditorDocumentNavigation.Location?) -> Bool {
        guard canSearchOpenBuffer, surface.generation == generation,
              Range(range, in: surface.textView.string) != nil else { return false }
        let history = EditorDocumentNavigation.shared
        focusNavigationTarget()
        surface.revealNavigationSelection(range, remembersLocation: false)
        if let origin, history.location(in: self) != origin { history.record(origin) }
        return true
    }

    func focusNavigationTarget() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface.textView)
    }

    /// Owners call once after accepting an actual terminal Save result. Hidden
    /// completions are consumed, never queued for a later focus/tab change.
    func announceSaveResult(_ result: SaveAnnouncement, attempt: UUID) {
        guard consumedSaveAnnouncement != attempt else { return }
        consumedSaveAnnouncement = attempt
        guard !closing, !readOnlyPresentation, NSWorkspace.shared.isVoiceOverEnabled,
              NSApp.isActive, let window, NSApp.keyWindow === window, window.isKeyWindow,
              window.isVisible, window.isOnActiveSpace, !window.isMiniaturized,
              window.occlusionState.contains(.visible), window.attachedSheet == nil,
              window.tabGroup.map({ $0.selectedWindow === window }) ?? true,
              !surface.isHiddenOrHasHiddenAncestor else { return }
        // AppKit requires the application element for announcement requests.
        // No focus, layout or selection notification accompanies the result.
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: result.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func update(displayName: String, dirty: Bool, status message: String,
                documentFormat: TextDocumentFormat, canSave: Bool, working: Bool,
                canReload: Bool, needsRecovery: Bool, explanation: String? = nil,
                canReviewVersions: Bool? = nil,
                canSaveTextCopy: Bool = false, hasTextCopyRecovery: Bool = false, canViewTextCopyResults: Bool = false,
                textCopyResults: [EditorTextCopyResult] = [], location: EditorLocationContext? = nil) {
        window?.title = displayName + " — Traverse"
        openSearchName = displayName; openSearchContext = location?.label ?? ""
        window?.tab.title = displayName
        if let window, window.isDocumentEdited != dirty {
            window.isDocumentEdited = dirty
            onEditedChanged?()
        }
        locationRow.isHidden = location == nil
        locationLabel.stringValue = location?.label ?? ""
        locationLabel.toolTip = location?.detail
        locationIcon.image = location.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        status.stringValue = message
        status.toolTip = message
        // An unconfirmed Save needs the same readable contrast as the text;
        // it must not look like routine background status on a glass surface.
        status.textColor = needsRecovery ? .labelColor : .secondaryLabelColor
        banner.textColor = needsRecovery ? .labelColor : .secondaryLabelColor
        format.stringValue = (documentFormat.bom ? "UTF-8 BOM" : "UTF-8")
            + (documentFormat.lineEnding == .crlf ? " · CRLF" : " · LF")
        saveButton.isEnabled = !readOnlyPresentation && canSave
        documentWorking = working
        if working { closeUnsavedChangePreview() }
        saveAsButton.isEnabled = !readOnlyPresentation && !working && !needsRecovery
        reloadButton.isEnabled = !readOnlyPresentation && canReload
        let reviewAvailable = canReviewVersions ?? needsRecovery
        recoveryButton.isHidden = !reviewAvailable; recoveryButton.isEnabled = reviewAvailable && !working
        stopButton.isHidden = !working; stopButton.isEnabled = working
        banner.stringValue = explanation ?? ""; banner.isHidden = explanation == nil
        textCopyButton.isEnabled = canSaveTextCopy
        textCopyButton.isHidden = !hasTextCopyRecovery
        textCopyResultsButton.isEnabled = canViewTextCopyResults
        copyResults = Array(textCopyResults.prefix(9))
        textCopyResultsButton.isHidden = copyResults.isEmpty
        copyActions.isHidden = !hasTextCopyRecovery && copyResults.isEmpty
        recoveryActions.isHidden = copyActions.isHidden && refusedActions.isHidden
        if readOnlyPresentation {
            for button in [saveButton, saveAsButton, reloadButton, recoveryButton, stopButton,
                           textCopyButton, textCopyResultsButton] {
                button.isHidden = true; button.isEnabled = false
            }
            recoveryActions.isHidden = true
        }
        // NSMenu.update validates that menu's own items, not all children.
        // Keep nested File commands current even before the user opens it.
        for root in ownMenu?.items ?? [] { root.submenu?.update() }
        ownMenu?.update()
    }
    /// Defaults update presentation only. Per-window Wrap/Syntax choices remain
    /// session overrides; the controller decides whether a new default applies.
    func applyEditorPreferences(_ value: EditorPreferences, pointSize: CGFloat,
                                applyWrapping: Bool = true) {
        closeUnsavedChangePreview()
        if applyWrapping {
            wrapping.state = value.wrapsLines ? .on : .off
        }
        surface.applyEditorPreferences(value, pointSize: pointSize, applyWrapping: applyWrapping)
    }

    private func displayScrollContext(_ value: NativeTextEditorSurface.ScrollContext?) {
        guard let value, let scope = value.scopes.last else {
            ToolContentMotion.finishCrossfade(in: scrollContextButton)
            scrollContextButton.isHidden = true
            scrollContextButton.title = ""
            scrollContextButton.image = nil
            scrollContextButton.toolTip = nil
            return
        }
        let fullTitle = value.scopes.map(\.title).joined(separator: " › ")
        let compactTitle = value.scopes.suffix(2).map(\.title).joined(separator: " › ")
        let revealing = scrollContextButton.isHidden
        if !revealing, scrollContextButton.title != compactTitle { ToolContentMotion.crossfade(scrollContextButton) }
        scrollContextButton.title = compactTitle
        scrollContextButton.image = NSImage(systemSymbolName: scope.kind.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        scrollContextButton.toolTip = "Go to " + fullTitle
            + (value.scopes.count > 1 ? ". Option-click to choose a scope." : "")
        scrollContextButton.setAccessibilityLabel("Go to visible scope, " + fullTitle)
        scrollContextButton.setAccessibilityHelp(value.scopes.count > 1 ? "Choose a parent scope from the Go menu." : nil)
        scrollContextButton.isHidden = false
        if revealing { ToolContentMotion.reveal(scrollContextButton, movesContent: false) }
    }
    func selectLanguage(_ value: TextSyntaxLanguage) {
        surface.setEditingLanguage(value)
        let index = TextSyntaxLanguage.allCases.firstIndex(of: value) ?? 0
        language.selectItem(at: index)
    }
    func finishClose() {
        closing = true
        closeUnsavedChangePreview()
        commandFinderStorage?.dismiss(restoringFocus: false)
        openSearchStorage?.dismiss(restoringFocus: false)
        cancelLineNavigation()
        _ = window?.makeFirstResponder(nil)
        // The document owner has already accepted the close and drained its
        // work. It needs the synchronous native didClose acknowledgement before
        // retiring the visible buffer. A second user-close/fade would defer that
        // acknowledgement and incorrectly trigger failed-close recovery.
        if let tool = window as? ToolMotionWindow {
            tool.closeImmediatelyAfterFeatureAcceptance()
        } else if let window {
            let native = window.animationBehavior
            window.animationBehavior = .none; window.close(); window.animationBehavior = native
        }
        acceptedCloseEditable = nil
    }
    /// Called only after the document owner has accepted Close and drained its
    /// work. The actual native close remains synchronous in finishClose().
    func prepareAcceptedClose() async -> Bool {
        guard !closing, acceptedCloseEditable == nil, let window else { return false }
        lineNavigation.cancel()
        acceptedCloseEditable = surface.textView.isEditable
        closing = true; surface.textView.isEditable = false
        closeUnsavedChangePreview()
        let prepared = await ToolWindowCloseMotion.prepareAcceptedClose(window)
        guard prepared, self.window === window else {
            restoreAcceptedClosePresentation(for: window)
            return false
        }
        return true
    }
    func cancelAcceptedClosePreparation() {
        restoreAcceptedClosePresentation(for: window)
    }
    private func restoreAcceptedClosePresentation(for window: NSWindow?) {
        if let window { ToolWindowCloseMotion.cancel(window) }
        if let acceptedCloseEditable { surface.textView.isEditable = acceptedCloseEditable }
        acceptedCloseEditable = nil; closing = false
    }
    /// Document owners join captured-text CPU work before releasing their own
    /// buffers. No file-access lifetime or Save operation belongs to this view.
    func closeComparisonAndDrain() async {
        navigationChoice?.cancel()
        await navigationChoice?.value
        await gitLineReview?.closeAndDrain()
        await openSearchStorage?.closeAndDrain()
        await fileSidebar?.files?.projectSearch?.closeAndDrain()
        gitHistoryRequest?.cancel()
        await gitHistoryRequest?.value
        await gitRevisionEditor?.closeAndDrain()
        await gitRevisionDiff?.closeAndDrain()
        await openEditorComparison?.closeAndDrain()
        await diskComparison?.view.closeAndDrain()
        await clipboardComparison?.closeAndDrain()
        guard let held = comparison else { return }
        await held.closeAndDrain()
        if comparison === held { comparison = nil }
    }
    #if DEBUG
    var comparisonForVerification: EditorComparisonWindow? { comparison }
    var unsavedChangePreviewForVerification: EditorUnsavedChangePreview? {
        guard unsavedChangePreview?.isShown == true else { return nil }
        return unsavedChangePreview?.contentViewController as? EditorUnsavedChangePreview
    }
    var openEditorComparisonForVerification: EditorComparisonWindow? { openEditorComparison }
    var diskComparisonForVerification: EditorComparisonWindow? { diskComparison?.view }
    var clipboardComparisonForVerification: EditorComparisonWindow? { clipboardComparison }
    var readClipboardForComparisonVerification: (() -> String?)?
    var gitRevisionDiffForVerification: EditorComparisonWindow? { gitRevisionDiff }
    var gitRevisionEditorForVerification: NativeTextSnapshotController? { gitRevisionEditor }
    func setJSONSchemaForVerification(_ schema: String) { jsonSchemaSnapshot = schema }
    #endif
    /// A failed post-close local retirement reopens the same native surface,
    /// including its actual Undo history, in recovery-only mode.
    func reopenAfterFailedClose() {
        cancelAcceptedClosePreparation()
        retainPresentationDuringClose = false
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The accepted visual gate blocks input, but only finishClose may
        // perform the native close after the document owner's final recheck.
        guard acceptedCloseEditable == nil else { return false }
        return closing || shouldClose?() == true
    }
    func windowWillClose(_ notification: Notification) {
        closeUnsavedChangePreview()
        fileSidebar?.windowWillClose()
        navigationChoice?.cancel()
        gitHistoryRequest?.cancel()
        gitFileHistory?.window?.close()
        gitRevisionEditor?.window.window?.performClose(nil)
        gitRevisionDiff?.window?.performClose(nil)
        openSearchPresented = false
        commandFinderStorage?.dismiss(restoringFocus: false)
        openSearchStorage?.dismiss(restoringFocus: false)
        cancelLineNavigation()
        if !retainPresentationDuringClose {
            jsonSchemaSnapshot = nil
            surface.clearPrivatePresentation()
        }
        releaseOwnedMenu()
        didClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if !surface.textView.bracketHighlights.isEmpty { surface.textView.needsDisplay = true }
        fileSidebar?.windowDidAppear()
        synchronizeKeyboardBehavior()
        guard !ToolWindowMenuOwnership.owns(self) else { return }
        ownMenu = ToolWindowMenuOwnership.claim(self) { makeMenu(base: $0) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if !surface.textView.bracketHighlights.isEmpty { surface.textView.needsDisplay = true }
        surface.lineCommands.inputDidChange(preservingExpansion: true); releaseOwnedMenu()
    }
    func windowWillBeginSheet(_ notification: Notification) {
        closeUnsavedChangePreview()
        surface.lineCommands.inputDidChange(preservingExpansion: true)
    }
    private func releaseOwnedMenu() {
        ToolWindowMenuOwnership.release(self)
        ownMenu = nil
    }
    private func makeMenu(base: NSMenu?) -> NSMenu {
        let menu = NSMenu()
        if let applicationItem = base?.items.first?.copy() as? NSMenuItem { menu.addItem(applicationItem) }
        @discardableResult
        func section(_ title: String, _ entries: [(String, Selector, String, NSEvent.ModifierFlags, AnyObject?)]) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for (label, action, key, modifiers, target) in entries {
                let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers; item.target = target; submenu.addItem(item)
            }
            root.submenu = submenu; menu.addItem(root)
            return submenu
        }
        let isGitSnapshot = gitLineReview?.isSnapshot == true
        let file = section("File", isGitSnapshot ? [] : [
            ("Save", #selector(saveDocument(_:)), "s", .command, self),
            (saveAsMenuTitle ?? "Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift], self),
            ("Save a Text Copy…", #selector(saveTextCopy(_:)), "", .command, self),
            ("Copy Results…", #selector(showTextCopyResults(_:)), "", .command, self),
            ("Reload from File…", #selector(reloadDocument(_:)), "", .command, self),
            (recoveryMenuTitle ?? "Review Retained Versions…", #selector(reviewVersions(_:)), "", .command, self)
        ])
        file.delegate = self
        if !isGitSnapshot && fileSidebar != nil {
            file.insertItem(BrowserMenus.item("Open Project File…", #selector(findProjectFile(_:)), key: "p", target: self), at: 0)
        }
        if !file.items.isEmpty { file.addItem(.separator()) }
        BrowserMenus.addSection("Compare", to: file) { comparisons in
            if !isGitSnapshot && !readOnlyPresentation {
                comparisons.addItem(BrowserMenus.item("Compare Changes…", #selector(compareChanges(_:)), target: self))
                if diskComparisonSource != nil {
                    comparisons.addItem(BrowserMenus.item("Compare with File on Disk…", #selector(compareWithDisk(_:)), target: self))
                }
            }
            comparisons.addItem(BrowserMenus.item("Compare with Open Editor…", #selector(chooseOpenEditorComparison(_:)), target: self))
            comparisons.addItem(BrowserMenus.item("Compare with Clipboard", #selector(compareWithClipboard(_:)), target: self))
        }
        BrowserMenus.addSection("Git", to: file, identifier: BrowserMenus.gitSectionIdentifier) { git in
            if !isGitSnapshot && fileSidebar != nil {
                git.addItem(BrowserMenus.item("Review Staged Changes…", #selector(reviewCurrentGitStagedChanges(_:)), target: self))
                git.addItem(BrowserMenus.item("Compare Working Folder…", #selector(compareCurrentGitWorkingFolder(_:)), target: self))
                git.addItem(BrowserMenus.item("Stage Saved File…", #selector(stageSavedGitFile(_:)), target: self))
                git.addItem(BrowserMenus.item("Unstage File…", #selector(unstageCurrentGitFile(_:)), target: self))
                git.addItem(.separator())
                git.addItem(BrowserMenus.item("Git File History…", #selector(showCurrentGitHistory(_:)), target: self))
                for (title, intent) in [("Compare Editor with HEAD", EditorGitRevisionIntent.compareHead), ("Compare Editor with Git Index", .compareIndex)] {
                    let item = BrowserMenus.item(title, #selector(compareEditorWithGit(_:)), target: self)
                    item.tag = intent.rawValue
                    git.addItem(item)
                }
                git.addItem(BrowserMenus.item("Open or Compare Git Revision…", #selector(chooseCurrentGitRevision(_:)), target: self))
                git.addItem(BrowserMenus.item("Compare Git Revisions…", #selector(compareCurrentGitRevisions(_:)), target: self))
                git.addItem(BrowserMenus.item("Open or Compare File in Git Worktree…", #selector(chooseCurrentGitWorktree(_:)), target: self))
            }
            if gitLineReview != nil {
                if !git.items.isEmpty { git.addItem(.separator()) }
                git.addItem(BrowserMenus.item("Show Commit for Line…", #selector(showGitLineCommit(_:)), target: self))
                git.addItem(BrowserMenus.item("Stop Git Lookup", #selector(stopGitLineCommit(_:)), target: self))
            }
        }
        menuNeedsUpdate(file)
        file.addItem(.separator())
        file.addItem(BrowserMenus.item("Close", #selector(NSWindow.performClose(_:)), key: "w", target: nil))
        let edit = section("Edit", [
            ("Undo Typing", #selector(NativeTextUndoActions.undo(_:)), "z", .command, nil),
            ("Redo Typing", #selector(NativeTextUndoActions.redo(_:)), "z", [.command, .shift], nil),
            ("Cut", #selector(NSText.cut(_:)), "x", .command, nil),
            ("Copy", #selector(NSText.copy(_:)), "c", .command, nil),
            ("Paste", #selector(NSText.paste(_:)), "v", .command, nil),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command, nil)
        ])
        edit.insertItem(.separator(), at: 2)
        edit.addItem(.separator())
        EditorFindMenu.items(target: self, selector: #selector(performFind(_:)), allowsReplacement: !readOnlyPresentation).forEach(edit.addItem)
        if !readOnlyPresentation {
            edit.addItem(BrowserMenus.item("Replace Occurrences in File…", #selector(replaceOccurrencesInFile(_:)), target: self))
        }
        edit.addItem(BrowserMenus.item("Find in Open Editors…", #selector(findInOpenEditors(_:)), key: "f",
            modifiers: [.command, .shift], target: self))
        BrowserMenus.addSection("Search Scope", to: edit) { scope in
            scope.addItem(EditorFindMenu.selectionItem(target: self, selector: #selector(findInSelection(_:))))
            scope.addItem(BrowserMenus.item("Find in Current Scope…", #selector(findInCurrentScope(_:)), target: self))
            if fileSidebar != nil {
                scope.addItem(BrowserMenus.item("Find in Selected Folder…", #selector(findSelectedFolderText(_:)), target: self))
                scope.addItem(BrowserMenus.item("Find in Project…", #selector(findProjectText(_:)), target: self))
            }
        }
        edit.addItem(.separator())
        edit.addItem(BrowserMenus.item("Select Inside Brackets", #selector(selectInsideBrackets(_:)), target: self))
        EditorSelectionAdjustment.menuItems(target: self, action: #selector(adjustEditorSelection(_:))).forEach(edit.addItem)
        if !readOnlyPresentation {
            edit.addItem(BrowserMenus.item("Complete Name in This File", #selector(completeLocalName(_:)),
                key: String(UnicodeScalar(NSF5FunctionKey)!), modifiers: [], target: self))
        }
        edit.addItem(.separator())
        let lineGroups: [(String, [(Int, String, String, NSEvent.ModifierFlags)])] = [
            ("Lines", [
                (0, "Duplicate Lines", "D", [.command, .shift]),
                (1, "Move Lines Up", String(UnicodeScalar(NSUpArrowFunctionKey)!), .option),
                (2, "Move Lines Down", String(UnicodeScalar(NSDownArrowFunctionKey)!), .option),
                (3, "Toggle Line Comment", "/", .command),
                (6, "Sort Lines Ascending", "", []),
                (7, "Sort Lines Descending", "", []),
                (8, "Trim Trailing Whitespace", "", [])
            ]),
            ("JSON", [(4, "Format JSON", "F", [.option, .shift]), (5, "Compact JSON", "", []),
                      (9, "Indent JSON as Written", "", []), (10, "Repair Missing Delimiter", "", [])])
        ]
        for (group, commands) in lineGroups {
            BrowserMenus.addSection(group, to: edit) { submenu in
                for (tag, title, key, modifiers) in commands {
                    let item = BrowserMenus.item(title, #selector(performLineCommand(_:)), key: key, modifiers: modifiers, target: self)
                    item.tag = tag
                    submenu.addItem(item)
                }
                if group == "JSON" {
                    submenu.addItem(.separator())
                    let syntax = BrowserMenus.item("Check JSON", #selector(checkJSONDocument(_:)), target: self)
                    let schema = BrowserMenus.item("Check Against JSON Schema…", #selector(checkJSONDocument(_:)), target: self)
                    schema.tag = 1
                    let currentSchema = BrowserMenus.item("Check Against Current JSON Schema", #selector(checkJSONDocument(_:)), target: self)
                    currentSchema.tag = 2
                    submenu.addItem(syntax)
                    submenu.addItem(schema)
                    submenu.addItem(currentSchema)
                    if !readOnlyPresentation {
                        submenu.addItem(.separator())
                        submenu.addItem(BrowserMenus.item("Complete from JSON Schema…", #selector(completeWithJSONSchema(_:)), target: self))
                        submenu.addItem(BrowserMenus.item("Forget Local JSON Schema", #selector(forgetJSONSchema(_:)), target: self))
                    }
                }
            }
        }
        let surround = NSMenuItem(title: "Surround Selection", action: nil, keyEquivalent: "")
        let surroundMenu = NSMenu(title: surround.title)
        for pair in EditorSurroundingPair.allCases {
            let item = NSMenuItem(title: pair.title, action: #selector(surroundSelection(_:)), keyEquivalent: "")
            item.tag = pair.rawValue; item.target = self
            surroundMenu.addItem(item)
        }
        surround.submenu = surroundMenu; edit.addItem(surround)
        if !readOnlyPresentation {
            let markers = NSMenuItem(title: "Merge Conflict Markers", action: nil, keyEquivalent: "")
            let choices = NSMenu(title: markers.title)
            for direction in [EditorJumpDirection.next, .previous] {
                let item = BrowserMenus.item(direction == .next ? "Next Conflict" : "Previous Conflict",
                    #selector(visitConflictMarker(_:)), target: self)
                item.tag = direction.rawValue
                choices.addItem(item)
            }
            choices.addItem(.separator())
            for resolution in EditorConflictMarkers.Resolution.allCases {
                let item = BrowserMenus.item(resolution.title, #selector(resolveConflictMarker(_:)), target: self)
                item.tag = resolution.rawValue
                choices.addItem(item)
            }
            markers.submenu = choices; edit.addItem(markers)
        }
        let view = section("View", [
            (NativeTextEditorSurface.whitespaceMarksTitle, #selector(toggleWhitespaceMarks(_:)), "", [], self)
        ])
        BrowserMenus.addSection("Code Folding", to: view) { folding in
            folding.addItem(BrowserMenus.item("Fold Block", #selector(changeCodeFold(_:)), key: "[",
                modifiers: [.command, .option], target: self))
            let unfold = BrowserMenus.item("Unfold Block", #selector(changeCodeFold(_:)), key: "]",
                modifiers: [.command, .option], target: self)
            unfold.tag = 1
            folding.addItem(unfold)
            let all = BrowserMenus.item("Unfold All Blocks", #selector(changeCodeFold(_:)), target: self)
            all.tag = 2
            folding.addItem(all)
        }
        if fileSidebar != nil {
            view.addItem(.separator())
            view.addItem(BrowserMenus.item("Editor Sidebar", #selector(toggleEditorSidebar(_:)), key: "\\", target: self))
            view.addItem(BrowserMenus.item("Switch Between Sidebar and Text", #selector(moveEditorFocus(_:)),
                key: String(UnicodeScalar(NSF6FunctionKey)!), modifiers: [], target: self))
            view.addItem(.separator())
            for (mode, title, key) in [(EditorSidebarMode.files, "Project Files", ""), (.open, "Open Editors", ""), (.outline, "Document Outline", "o")] {
                let item = BrowserMenus.item(title, #selector(showSidebarMode(_:)), key: key, modifiers: [.command, .shift], target: self)
                item.tag = mode.rawValue
                view.addItem(item)
            }
            view.addItem(BrowserMenus.item("Reveal Current File", #selector(revealCurrentFile(_:)), target: self))
        }
        let go = section("Go", [
            ("Go to Line…", #selector(showGoToLine(_:)), "g", .control, self),
            ("Next JSON Issue", #selector(goToJSONIssue(_:)), String(UnicodeScalar(NSF8FunctionKey)!), [], self),
            ("Previous JSON Issue", #selector(goToJSONIssue(_:)), String(UnicodeScalar(NSF8FunctionKey)!), .shift, self),
            ("Review JSON Issues…", #selector(openJSONIssues(_:)), "", [], self),
            ("Go to Matching Bracket", #selector(goToMatchingBracket(_:)), "\\", [.command, .shift], self),
            ("Go to Visible Scope", #selector(goToVisibleScope(_:)), "", [], self),
            ("Choose Visible Scope…", #selector(chooseVisibleScope(_:)), "", [], self),
            ("Find Declaration in This File", #selector(findLocalDeclaration(_:)), String(UnicodeScalar(NSF12FunctionKey)!), [], self),
            ("Go to Symbol in This File…", #selector(goToDocumentSymbol(_:)), "o", [.command, .control], self),
            ("Go to Symbol in Open Editors…", #selector(goToOpenSymbol(_:)), "o", [.command, .option], self)
        ])
        go.item(withTitle: "Next JSON Issue")?.tag = EditorJumpDirection.next.rawValue
        go.item(withTitle: "Previous JSON Issue")?.tag = EditorJumpDirection.previous.rawValue
        BrowserMenus.addSection("Outline", to: go) { menu in
            for direction in EditorJumpDirection.allCases {
                let previous = direction == .previous
                let arrow = String(UnicodeScalar(previous ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!)
                let item = BrowserMenus.item(previous ? "Previous Outline Item" : "Next Outline Item",
                    #selector(visitOutlineItem(_:)), key: arrow, modifiers: [.command, .option], target: self)
                item.tag = direction.rawValue
                menu.addItem(item)
            }
            menu.addItem(BrowserMenus.item("Go to Enclosing Scope", #selector(goToEnclosingScope(_:)), target: self))
        }
        if !readOnlyPresentation {
            go.insertItem(BrowserMenus.item("Go to Last Edit", #selector(goToLastEdit(_:)), target: self), at: 1)
            BrowserMenus.addSection("Line Bookmarks", to: go) { menu in
                menu.addItem(BrowserMenus.item("Toggle Line Bookmark", #selector(toggleLineBookmark(_:)), target: self))
                menu.addItem(BrowserMenus.item("Choose Line Bookmark…", #selector(chooseLineBookmark(_:)), target: self))
                let key = String(UnicodeScalar(NSF2FunctionKey)!)
                for direction in [EditorJumpDirection.next, .previous] {
                    let title = direction == .next ? "Next Bookmark" : "Previous Bookmark"
                    let item = BrowserMenus.item(title, #selector(visitLineBookmark(_:)), key: key,
                        modifiers: direction == .next ? [] : [.shift], target: self)
                    item.tag = direction.rawValue
                    menu.addItem(item)
                }
            }
        }
        if fileSidebar != nil {
            go.addItem(BrowserMenus.item("Find Project Declarations…", #selector(findProjectDeclarations(_:)), target: self))
        }
        go.addItem(.separator())
        EditorJumpDirection.menuItems(target: self, action: #selector(visitTextLocation(_:))).forEach(go.addItem)
        if !readOnlyPresentation {
            EditorJumpDirection.changeMenuItems(target: self, action: #selector(visitUnsavedChange(_:)), qualifier: "Unsaved ")
                .forEach(go.addItem)
            go.addItem(BrowserMenus.item("Review Unsaved Change…", #selector(reviewSelectedUnsavedLine(_:)),
                key: String(UnicodeScalar(NSF7FunctionKey)!), modifiers: .option, target: self))
            go.addItem(BrowserMenus.item("Go to Unsaved Change…", #selector(chooseUnsavedChange(_:)),
                key: String(UnicodeScalar(NSF7FunctionKey)!), modifiers: [.command, .option], target: self))
        }
        if let window {
            let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            item.submenu = NativeWindowMenu.make(tabbedWindow: window)
            menu.addItem(item)
        }
        if let help = base?.items.last, help.title == "Help", let copy = help.copy() as? NSMenuItem {
            // Help must discover the key editor's own commands rather than
            // forwarding into the browser beneath it.
            for item in copy.submenu?.items ?? [] where item.action == #selector(BrowserViewController.findCommand(_:)) {
                item.action = #selector(findEditorCommand(_:)); item.target = self
            }
            menu.addItem(copy)
        }
        if usesControlAliases {
            let basic: Set<String> = ["Save", saveAsMenuTitle ?? "Save As…", "Close", "Undo Typing", "Redo Typing", "Cut", "Copy", "Paste", "Select All", "Find…", "Find in Open Editors…", "Toggle Line Comment"]
            func addAliases(to section: NSMenu) {
                for item in section.items {
                    if let submenu = item.submenu { addAliases(to: submenu) }
                    guard basic.contains(item.title), item.keyEquivalentModifierMask.contains(.command),
                          let alias = item.copy() as? NSMenuItem else { continue }
                    alias.keyEquivalentModifierMask.remove(.command); alias.keyEquivalentModifierMask.insert(.control)
                    alias.isHidden = true; alias.allowsKeyEquivalentWhenHidden = true
                    section.addItem(alias)
                    if item.title == "Redo Typing", let redo = alias.copy() as? NSMenuItem {
                        redo.keyEquivalent = "y"; redo.keyEquivalentModifierMask = .control; section.addItem(redo)
                    }
                }
            }
            for parent in menu.items where ["File", "Edit"].contains(parent.title) {
                guard let submenu = parent.submenu else { continue }
                addAliases(to: submenu)
                if parent.title == "Edit", !readOnlyPresentation {
                    let replace = NSMenuItem(title: "Replace…", action: #selector(performFind(_:)), keyEquivalent: "h")
                    replace.keyEquivalentModifierMask = .control; replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
                    replace.target = self; replace.isHidden = true; replace.allowsKeyEquivalentWhenHidden = true
                    submenu.addItem(replace)
                }
            }
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let git = menu.items.first { $0.identifier == BrowserMenus.gitSectionIdentifier }
        git?.isHidden = fileSidebar?.files?.currentHistoryFile == nil && gitLineReview?.isAvailable != true
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !closing, window?.isKeyWindow == true else { return false }
        switch item.action {
        case #selector(toggleWhitespaceMarks(_:)):
            (item as? NSMenuItem)?.state = surface.showsWhitespaceMarks ? .on : .off
            return window?.attachedSheet == nil && !surface.textView.hasMarkedText()
        case #selector(changeCodeFold(_:)):
            guard canChooseNavigationTarget, let tag = (item as? NSMenuItem)?.tag else { return false }
            return tag == 2 ? surface.hasFoldedCode : surface.canSetSelectedBlock(folded: tag == 0)
        case #selector(toggleEditorSidebar(_:)):
            (item as? NSMenuItem)?.state = fileSidebar?.isShown == true ? .on : .off
            return fileSidebar?.canToggle == true
        case #selector(moveEditorFocus(_:)): return fileSidebar?.canToggle == true
        case #selector(showSidebarMode(_:)), #selector(revealCurrentFile(_:)): return fileSidebar?.canToggle == true
        case #selector(findProjectFile(_:)), #selector(findProjectText(_:)), #selector(findProjectDeclarations(_:)):
            return fileSidebar?.canToggle == true
        case #selector(findSelectedFolderText(_:)):
            let available = fileSidebar?.isShown == true && fileSidebar?.files?.canFindInSelectedFolder == true
            (item as? NSMenuItem)?.isHidden = !available
            return available
        case #selector(goToVisibleScope(_:)):
            return surface.scrollContext != nil && window?.attachedSheet == nil && surface.canGoToLine
        case #selector(chooseVisibleScope(_:)): return canChooseVisibleScope
        case #selector(goToJSONIssue(_:)), #selector(openJSONIssues(_:)): return canGoToJSONIssue
        case #selector(visitOutlineItem(_:)):
            guard canChooseNavigationTarget, let tag = (item as? NSMenuItem)?.tag,
                  let direction = EditorJumpDirection(rawValue: tag) else { return false }
            return surface.adjacentOutlineEntry(toward: direction) != nil
        case #selector(goToEnclosingScope(_:)):
            return canChooseNavigationTarget && surface.enclosingOutlineEntry != nil
        case #selector(goToLastEdit(_:)):
            return window?.attachedSheet == nil && surface.canGoToLastEdit
                && (window?.firstResponder as? NSTextView)?.hasMarkedText() != true
        case #selector(toggleLineBookmark(_:)):
            let line = surface.bookmarkCaretLine
            (item as? NSMenuItem)?.state = line.map { surface.hasBookmark(on: $0) } == true ? .on : .off
            return canChooseNavigationTarget && line != nil
        case #selector(chooseLineBookmark(_:)):
            return canChooseNavigationTarget && !surface.bookmarkedLines.isEmpty
        case #selector(visitLineBookmark(_:)):
            guard canChooseNavigationTarget, let tag = (item as? NSMenuItem)?.tag,
                  let direction = EditorJumpDirection(rawValue: tag) else { return false }
            return surface.bookmarkLine(toward: direction) != nil
        case #selector(findLocalDeclaration(_:)): return canChooseNavigationTarget && surface.canFindDeclaration
        case #selector(completeLocalName(_:)):
            let schema = supportsJSONFormatting
            (item as? NSMenuItem)?.title = schema ? "Complete from JSON Schema…" : "Complete Name in This File"
            return schema ? canCompleteWithJSONSchema : canChooseNavigationTarget && surface.canCompleteLocalName
        case #selector(replaceOccurrencesInFile(_:)): return canChooseNavigationTarget && surface.occurrenceSeed() != nil
        case #selector(findInCurrentScope(_:)): return canChooseNavigationTarget && surface.currentSearchScope != nil
        case #selector(adjustEditorSelection(_:)):
            guard let tag = (item as? NSMenuItem)?.tag, let direction = EditorSelectionAdjustment(rawValue: tag) else { return false }
            return surface.lineCommands.canAdjustSelection(direction)
        case #selector(stageSavedGitFile(_:)), #selector(unstageCurrentGitFile(_:)):
            (item as? NSMenuItem)?.isHidden = fileSidebar?.files?.currentHistoryFile == nil
            return canEditGitIndex
        case #selector(showCurrentGitHistory(_:)), #selector(chooseCurrentGitRevision(_:)), #selector(compareCurrentGitRevisions(_:)),
             #selector(chooseCurrentGitWorktree(_:)), #selector(compareEditorWithGit(_:)),
             #selector(reviewCurrentGitStagedChanges(_:)), #selector(compareCurrentGitWorkingFolder(_:)):
            let available = fileSidebar?.files?.currentHistoryFile != nil
            (item as? NSMenuItem)?.isHidden = !available
            return available && gitHistoryRequest == nil && window?.attachedSheet == nil
                && (item.action != #selector(compareEditorWithGit(_:)) || canCompareOpenBuffer)
        case #selector(showGitLineCommit(_:)):
            (item as? NSMenuItem)?.isHidden = gitLineReview?.isAvailable != true
            return gitLineReview?.canLookUp == true
        case #selector(stopGitLineCommit(_:)):
            let running = gitLineReview?.isRunning == true
            (item as? NSMenuItem)?.isHidden = !running
            return running
        case #selector(saveDocument(_:)): return saveButton.isEnabled
        case #selector(saveDocumentAs(_:)): return saveAsButton.isEnabled
        case #selector(saveTextCopy(_:)): return !textCopyButton.isHidden && textCopyButton.isEnabled
        case #selector(showTextCopyResults(_:)): return !textCopyResultsButton.isHidden && textCopyResultsButton.isEnabled
        case #selector(reloadDocument(_:)): return reloadButton.isEnabled
        case #selector(reviewVersions(_:)): return !recoveryButton.isHidden && recoveryButton.isEnabled
        case #selector(compareChanges(_:)): return canCompare
        case #selector(compareWithDisk(_:)): return canCompare && diskComparisonSource?() != nil
        case #selector(compareWithClipboard(_:)): return canCompareClipboard
        case #selector(chooseOpenEditorComparison(_:)):
            return canCompareOpenBuffer && (openEditorComparison != nil
                || Self.openSearchDocuments(preferred: self).contains { $0 !== self && $0.canCompareOpenBuffer })
        case #selector(stopDocumentWork(_:)): return !stopButton.isHidden && stopButton.isEnabled
        case #selector(findEditorCommand(_:)): return canDiscoverCommands
        case #selector(findInOpenEditors(_:)), #selector(goToOpenSymbol(_:)): return canDiscoverCommands && canSearchOpenBuffer
        case #selector(goToDocumentSymbol(_:)):
            return canDiscoverCommands && canSearchOpenBuffer && surface.currentOutlineForSymbols?.value.entries.isEmpty == false
        case #selector(showGoToLine(_:)): return surface.canGoToLine && window?.attachedSheet == nil
        case #selector(visitTextLocation(_:)):
            return EditorJumpDirection(rawValue: item.tag).map { EditorDocumentNavigation.shared.canVisit($0, from: self) } ?? false
        case #selector(visitUnsavedChange(_:)):
            return window?.isKeyWindow == true && canSearchOpenBuffer && EditorJumpDirection(rawValue: item.tag)
                .flatMap(surface.unsavedChangeLine(toward:)) != nil
        case #selector(reviewSelectedUnsavedLine(_:)):
            return canCompare && surface.selectedUnsavedLine != nil
        case #selector(chooseUnsavedChange(_:)):
            return canChooseNavigationTarget && surface.canGoToLine && surface.unsavedLineChanges?.marks.isEmpty == false
        case #selector(visitConflictMarker(_:)):
            return EditorJumpDirection(rawValue: item.tag).flatMap(conflictDestination(toward:)) != nil
        case #selector(resolveConflictMarker(_:)):
            guard !closing, surface.lineCommands.canPerform, let choice = EditorConflictMarkers.Resolution(rawValue: item.tag),
                  let block = surface.conflictMarkers?.block(containing: surface.textView.selectedRange()) else { return false }
            return choice != .base || block.base != nil
        case #selector(goToMatchingBracket(_:)), #selector(selectInsideBrackets(_:)):
            return surface.lineCommands.canNavigate && selectedSyntaxLanguage.map(EditorBracketNavigation.supports) == true
                && (item.action != #selector(goToMatchingBracket(_:)) || surface.textView.selectedRange().length <= 1)
        case #selector(performFind(_:)):
            guard window?.isVisible == true && window?.attachedSheet == nil else { return false }
            return item.tag != NSTextFinder.Action.setSearchString.rawValue || surface.find.selectedQuery(allowsNewlines: true) != nil
        case #selector(findInSelection(_:)): return surface.find.canFindInSelection
        case #selector(performLineCommand(_:)):
            if item.tag == 10 {
                return !closing && supportsJSONFormatting && surface.lineCommands.canPerform
                    && surface.jsonIssues.first?.missingDelimiter != nil
            }
            return !closing && surface.lineCommands.canPerform && (item.tag != 3 || lineCommentStyle != nil)
                && (![4, 5, 9].contains(item.tag) || supportsJSONFormatting)
        case #selector(checkJSONDocument(_:)):
            let records = selectedSyntaxLanguage == .jsonLines
            if item.tag == 0 { (item as? NSMenuItem)?.title = records ? "Check JSON Lines" : "Check JSON" }
            return canChooseNavigationTarget && !surface.textView.hasMarkedText()
                && (supportsJSONFormatting || records && item.tag == 0)
                && (item.tag != 2 || jsonSchemaSnapshot != nil)
        case #selector(completeWithJSONSchema(_:)):
            return canCompleteWithJSONSchema
        case #selector(forgetJSONSchema(_:)):
            return canChooseNavigationTarget && jsonSchemaSnapshot != nil
        case #selector(surroundSelection(_:)):
            return !closing && surface.lineCommands.canPerform && surface.textView.selectedRange().length > 0
                && EditorSurroundingPair(rawValue: item.tag) != nil
        default: return true
        }
    }
    var canDiscoverCommands: Bool {
        !closing && window?.isVisible == true && window?.attachedSheet == nil
    }
    private var canCompare: Bool {
        !closing && !readOnlyPresentation && !documentWorking && captureComparison != nil && window?.isVisible == true
            && window?.attachedSheet == nil && !surface.textView.hasMarkedText()
    }
    @objc func compareChanges(_ sender: Any?) {
        guard window?.isKeyWindow == true else { return }
        savedComparison()?.present()
    }
    private func savedComparison() -> EditorComparisonWindow? {
        guard canCompare, let parent = window, let captureComparison, let settings = commandDiscoverySettings else { return nil }
        if let comparison, !comparison.closed { return comparison }
        let held = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: surface.textView.font?.pointSize ?? 13, capture: captureComparison)
        comparison = held
        held.didClose = { [weak self, weak held] in
            if self?.comparison === held { self?.comparison = nil }
        }
        return held
    }
    @objc private func toggleWhitespaceMarks(_ sender: Any?) {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil, !surface.textView.hasMarkedText() else { return }
        surface.setWhitespaceMarks(!surface.showsWhitespaceMarks)
    }

    @objc func chooseOpenEditorComparison(_ sender: Any?) {
        guard window?.isKeyWindow == true, canCompareOpenBuffer else { return }
        if let openEditorComparison, !openEditorComparison.closed { openEditorComparison.present(); return }
        openSearch.present(.compare)
    }
    @objc private func compareWithDisk(_ sender: Any?) {
        guard window?.isKeyWindow == true, canCompare, let parent = window,
              let settings = commandDiscoverySettings, let source = diskComparisonSource?() else { return }
        if let existing = diskComparison, !existing.view.closed {
            if existing.url == source.url { existing.view.present() }
            else {
                Task { @MainActor [weak self] in
                    await existing.view.closeAndDrain()
                    self?.compareWithDisk(nil)
                }
            }
            return
        }
        let held = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: surface.textView.font?.pointSize ?? 13,
            labels: .init(title: "Compare with File on Disk", source: source.url.lastPathComponent, left: "File on Disk",
                right: "Editor Buffer", detail: "Review the file as it is on disk alongside your current editor text.",
                refresh: "Refresh"), capture: source.capture)
        diskComparison = (source.url, held)
        held.didClose = { [weak self, weak held] in
            if self?.diskComparison?.view === held { self?.diskComparison = nil }
        }
        held.present()
    }
    func compareOpenBuffers(_ origin: EditorOpenSearch.Reference, with candidate: EditorOpenSearch.Reference,
                            editor: NativeTextEditorWindow) {
        guard editor !== self, canCompareOpenBuffer, editor.canCompareOpenBuffer,
              origin == openEditorReference, candidate == editor.openEditorReference,
              let parent = window, parent.isKeyWindow, let settings = commandDiscoverySettings,
              openEditorComparison == nil else { return }
        let left = comparisonSide(), right = editor.comparisonSide()
        var initial: EditorComparisonCapture? = .init(left: left, right: right)
        func description(_ ref: EditorOpenSearch.Reference) -> String {
            guard origin.name == candidate.name, !ref.context.isEmpty else { return ref.name }
            return ref.context
        }
        let held = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: surface.textView.font?.pointSize ?? 13,
            labels: .init(title: "Compare Open Editors", source: "Open editor buffers", left: description(origin),
                right: description(candidate), detail: "Includes unsaved text from the two selected editors.",
                refresh: "Refresh Current Buffers")) { [weak self, weak editor] in
            if let captured = initial { initial = nil; return captured }
            guard let self, let editor, canCompareOpenBuffer, editor.canCompareOpenBuffer,
                  origin.identifies(openEditorReference), candidate.identifies(editor.openEditorReference) else {
                throw EditorComparisonLoadFailure.unavailable("One of these editors closed, moved or is busy.")
            }
            return .init(left: comparisonSide(), right: editor.comparisonSide())
        }
        openEditorComparison = held
        held.didClose = { [weak self, weak held] in
            if self?.openEditorComparison === held { self?.openEditorComparison = nil }
        }
        held.present()
    }
    private func comparisonSide() -> EditorComparisonCapture.Side {
        .init(text: surface.textView.string, format: surface.documentFormat, language: selectedSyntaxLanguage ?? .plain,
            editor: editableBufferIdentity)
    }

    private var canCompareClipboard: Bool {
        canCompareOpenBuffer && surface.textView.selectedRanges.count == 1
            && clipboardComparison?.canPresentCapture != false
    }

    @objc private func compareWithClipboard(_ sender: Any?) {
        guard canCompareClipboard, let parent = window, parent.isKeyWindow,
              let settings = commandDiscoverySettings else { return }
        let editor = surface.textView
        let selection = editor.selectedRange()
        let source = editor.string
        guard let range = Range(selection, in: source) else { return }
        let text = selection.length == 0 ? source : String(source[range])
        guard let clipboard = clipboardTextForComparison(), !clipboard.isEmpty else {
            status.stringValue = "Copy plain text before starting a clipboard comparison."
            return
        }
        let maximumBytes = TextDocumentValue.maximumBytes
        guard clipboard.utf8.prefix(maximumBytes + 1).count <= maximumBytes,
              text.utf8.prefix(maximumBytes + 1).count <= maximumBytes else {
            status.stringValue = "Clipboard comparisons can read up to 1 MiB from each side. Copy or select a smaller section."
            return
        }
        let scope = selection.length == 0 ? "Editor Buffer" : "Selected Text"
        let labels = EditorComparisonWindow.Labels(title: "Compare with Clipboard", source: openSearchName,
            left: "Clipboard", right: scope, detail: "Captured when you chose Compare with Clipboard.", refresh: nil)
        let capture = EditorComparisonCapture(baseline: clipboard, current: text,
            format: .init(bom: false, lineEnding: .lf), language: selectedSyntaxLanguage ?? .plain)
        if let comparison = clipboardComparison, !comparison.closed {
            comparison.present(capture, labels: labels)
            return
        }
        let comparison = EditorComparisonWindow(relativeTo: parent, settings: settings,
            pointSize: editor.font?.pointSize ?? 13, labels: labels) {
            throw EditorComparisonLoadFailure.unavailable("Choose Compare with Clipboard from the editor.")
        }
        clipboardComparison = comparison
        comparison.didClose = { [weak self, weak comparison] in
            if self?.clipboardComparison === comparison { self?.clipboardComparison = nil }
        }
        comparison.present(capture)
    }

    private func clipboardTextForComparison() -> String? {
        #if DEBUG
        if let readClipboardForComparisonVerification { return readClipboardForComparisonVerification() }
        #endif
        let board = NSPasteboard.general
        let revision = board.changeCount
        let text = board.string(forType: .string)
        return board.changeCount == revision ? text : nil
    }
    var commandDiscoverySettings: BrowserSettings? { keyboardSettings ?? InterfacePresentation.shared.settings }
    func discoverableCommands() -> [(NSMenuItem, String)] {
        guard let ownMenu else { return [] }
        if let file = ownMenu.item(withTitle: "File")?.submenu { menuNeedsUpdate(file) }
        func commands(in menu: NSMenu, category: String, depth: Int) -> [(NSMenuItem, String)] {
            guard depth < 4 else { return [] }
            return menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.flatMap { item in
                if let submenu = item.submenu {
                    return commands(in: submenu, category: category + " › " + item.title, depth: depth + 1)
                }
                return item.action == nil ? [] : [(item, category)]
            }
        }
        return ownMenu.items.filter { ["File", "Edit", "View", "Go", "Window"].contains($0.title) }.flatMap { section in
            section.submenu.map { commands(in: $0, category: section.title, depth: 0) } ?? []
        }
    }
    @objc func findEditorCommand(_ sender: Any?) { if !closing { commandFinder.present() } }
    @objc func findInOpenEditors(_ sender: Any?) { if !closing { openSearch.present() } }
    @objc private func goToOpenSymbol(_ sender: Any?) { if !closing { openSearch.present(.symbols) } }
    @objc private func goToDocumentSymbol(_ sender: Any?) {
        guard !closing, surface.currentOutlineForSymbols?.value.entries.isEmpty == false else { return }
        openSearch.present(.documentSymbols)
    }
    @objc private func findProjectFile(_ sender: Any?) {
        guard !closing else { return }
        fileSidebar?.files?.findProjectFile(in: self)
    }
    @objc private func findProjectText(_ sender: Any?) {
        guard !closing else { return }
        fileSidebar?.files?.findProjectFile(in: self, purpose: .findText)
    }
    @objc private func findProjectDeclarations(_ sender: Any?) {
        guard !closing else { return }
        fileSidebar?.files?.findProjectFile(in: self, purpose: .findDeclarations)
    }
    @objc func findSelectedFolderText(_ sender: Any?) {
        guard !closing, fileSidebar?.isShown == true else { return }
        fileSidebar?.files?.findProjectFile(in: self, purpose: .findFolderText)
    }
    @objc private func surroundSelection(_ sender: NSMenuItem) {
        guard !closing, surface.lineCommands.canPerform, surface.textView.selectedRange().length > 0,
              let pair = EditorSurroundingPair(rawValue: sender.tag) else { return }
        surface.lineCommands.perform(.surroundSelection(pair))
    }
    @objc private func adjustEditorSelection(_ sender: NSMenuItem) {
        guard !closing, let direction = EditorSelectionAdjustment(rawValue: sender.tag) else { return }
        surface.lineCommands.adjustSelection(direction)
    }
    @objc private func changeCodeFold(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender) else { return }
        if sender.tag == 2 { surface.revealAllCodeBlocks() }
        else { surface.setSelectedBlock(folded: sender.tag == 0) }
    }
    @objc private func performLineCommand(_ sender: NSMenuItem) {
        guard !closing, surface.lineCommands.canPerform else { return }
        let command: EditorLineCommand
        switch sender.tag {
        case 0: command = .duplicateSelectedLines
        case 1: command = .moveLinesUp
        case 2: command = .moveLinesDown
        case 3:
            guard let style = lineCommentStyle else { return }
            command = .toggleLineComment(style)
        case 4, 5, 9:
            guard supportsJSONFormatting else { return }
            let style: EditorJSONFormat = switch sender.tag {
            case 5: .compact
            case 9: .asWritten(surface.indentationPreferences)
            default: .indented(surface.indentationPreferences)
            }
            command = .formatJSON(style,
                                  allowsComments: selectedSyntaxLanguage == .jsonc)
        case 6, 7: command = .sortSelectedLines(descending: sender.tag == 7)
        case 8: command = .trimTrailingWhitespace
        case 10:
            guard validateUserInterfaceItem(sender) else { return }
            command = .repairJSONDelimiter(allowsComments: selectedSyntaxLanguage == .jsonc)
        default: return
        }
        surface.lineCommands.perform(command)
    }
    private var selectedSyntaxLanguage: TextSyntaxLanguage? {
        let languages = TextSyntaxLanguage.allCases
        guard languages.indices.contains(language.indexOfSelectedItem) else { return nil }
        return languages[language.indexOfSelectedItem]
    }
    private var lineCommentStyle: EditorLineCommentStyle? { selectedSyntaxLanguage?.lineCommentStyle }
    private var supportsJSONFormatting: Bool {
        selectedSyntaxLanguage == .json || selectedSyntaxLanguage == .jsonc
    }

    private var canCompleteWithJSONSchema: Bool {
        canChooseNavigationTarget && supportsJSONFormatting && surface.textView.isEditable
            && !surface.textView.hasMarkedText() && surface.textView.selectedRanges.count == 1
    }

    @objc private func forgetJSONSchema(_ sender: Any?) {
        guard canChooseNavigationTarget, jsonSchemaSnapshot != nil else { return }
        jsonSchemaSnapshot = nil
        surface.clearCheckedJSONIssues()
        reportNavigation("Local JSON schema removed.")
    }

    private static func chooseJSONSchema(in parent: NSWindow, prompt: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Local JSON Schema"
        panel.prompt = prompt
        panel.allowedContentTypes = [.json]
        panel.resolvesAliases = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = await withTaskCancellationHandler {
            await panel.beginSheetModal(for: parent)
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        return response == .OK ? panel.url : nil
    }

    @objc private func completeWithJSONSchema(_ sender: Any?) {
        guard canCompleteWithJSONSchema, let parent = window else { return }
        let generation = surface.generation, language = selectedSyntaxLanguage
        let selection = surface.textView.selectedRange(), text = surface.textView.string
        guard text.utf8.count <= LocalJSONSchemaCompletion.maximumDocumentBytes else {
            reportNavigation("Schema completion supports JSON documents up to 128 KiB.")
            return
        }
        let retainedSchema = jsonSchemaSnapshot
        let format = surface.documentFormat
        navigationChoice = Task { [weak self, weak parent] in
            defer { self?.navigationChoice = nil }
            guard let parent else { return }
            var schemaFile: URL?
            if retainedSchema == nil {
                guard let selected = await Self.chooseJSONSchema(in: parent, prompt: "Use Schema") else { return }
                schemaFile = selected
            }
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !closing && window === parent && parent.isVisible && parent.attachedSheet == nil
                    && (parent.isKeyWindow || NSApp.keyWindow == nil)
                    && surface.generation == generation && selectedSyntaxLanguage == language
                    && surface.textView.selectedRanges.count == 1 && surface.textView.selectedRange() == selection
                    && surface.textView.isEditable && !surface.textView.hasMarkedText()
                    && surface.textView.string.utf16.elementsEqual(text.utf16)
            }
            guard isCurrent() else { return }
            let source = schemaFile
            let worker = Task.detached(priority: .userInitiated) { () throws -> (LocalJSONSchemaCompletion.Result, String?) in
                let schema: String
                if let retainedSchema { schema = retainedSchema }
                else if let source {
                    switch try LocalJSONCheck.readSchema(source) {
                    case .loaded(let snapshot): schema = snapshot
                    case .unavailable(let message): return (.unavailable(message), nil)
                    }
                } else { return (.unavailable("Choose a local JSON schema first."), nil) }
                let suggestions = try LocalJSONSchemaCompletion.suggest(in: text, selection: selection,
                    allowsComments: language == .jsonc, schema: schema)
                return (suggestions, schema)
            }
            let prepared = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard isCurrent() else { return }
            switch prepared {
            case .failure:
                reportNavigation("Schema completion stopped.")
            case .success((.unavailable(let message), let schema)):
                jsonSchemaSnapshot = schema
                reportNavigation(message)
            case .success((.suggestions(let plan), let schema)):
                jsonSchemaSnapshot = schema
                let property = plan.kind == .property
                guard !plan.candidates.isEmpty else {
                    reportNavigation(property ? "No unused schema properties match this name."
                                              : "No declared schema values match here.")
                    return
                }
                let action = property ? "Complete JSON Property" : "Complete JSON Value"
                let rows = plan.candidates.map { candidate in
                    var details: [String] = []
                    if property {
                        details.append(candidate.required ? "Required" : "Optional")
                        if !candidate.types.isEmpty { details.append(candidate.types.joined(separator: " or ")) }
                        if let summary = candidate.summary { details.append(summary) }
                    } else if candidate.isDefault { details.append("Default") }
                    return NativeChoiceSheet<LocalJSONSchemaCompletion.Candidate>.Row(title: candidate.name,
                        detail: details.joined(separator: " · "), value: candidate, help: property ? candidate.summary : nil)
                }
                let sheet = NativeChoiceSheet(title: action, heading: property ? "Properties from the Local Schema" : "Values from the Local Schema",
                                              confirm: property ? "Insert Property" : "Insert Value", rows: rows,
                                              note: property ? nil : plan.candidates.first?.summary)
                guard let chosen = await sheet.choose(in: parent), isCurrent(),
                      let target = Range(plan.range, in: text),
                      let result = try? TextDocumentValue.edited(text.replacingCharacters(in: target, with: chosen.replacement), format: format)
                else { return }
                let caret = chosen.selectionInReplacement
                let replacement = EditorIndentationReplacement(range: plan.range, text: chosen.replacement,
                    selection: .init(location: plan.range.location + caret.location, length: caret.length))
                if surface.applyTextReplacement(replacement, expecting: result, action: action) {
                    reportNavigation(property ? "Inserted schema property." : "Inserted schema value.")
                }
            }
        }
    }

    private var canGoToJSONIssue: Bool {
        !closing && navigationChoice == nil && selectedSyntaxLanguage?.isJSON == true
            && window?.isKeyWindow == true && window?.attachedSheet == nil
            && (window?.firstResponder as? NSTextView)?.hasMarkedText() != true
            && surface.canGoToLine && surface.textView.selectedRanges.count == 1 && !surface.jsonIssues.isEmpty
    }

    private func displayJSONIssues(_ presentation: NativeTextEditorSurface.JSONIssues) {
        let issues = presentation.issues
        jsonIssuesButton.isHidden = issues.isEmpty
        guard let first = issues.first else { jsonIssuesButton.toolTip = nil; return }
        let count = presentation.hasMore ? "\(issues.count.formatted())+" : issues.count.formatted()
        let title = issues.count == 1 && !presentation.hasMore ? "JSON issue" : "\(count) JSON issues"
        jsonIssuesButton.title = title
        jsonIssuesButton.contentTintColor = .systemRed
        jsonIssuesButton.toolTip = issues.count > 1 ? "Review issues in this draft."
            : "Line \(first.line.formatted()), column \(first.column.formatted()). \(first.message)"
        jsonIssuesButton.setAccessibilityLabel(title)
        jsonIssuesButton.setAccessibilityHelp(jsonIssuesButton.toolTip)
    }

    @objc private func goToJSONIssue(_ sender: NSMenuItem) {
        guard canGoToJSONIssue, let direction = EditorJumpDirection(rawValue: sender.tag) else { return }
        let offset = surface.textView.selectedRange().location
        let issues = surface.jsonIssues
        let issue = direction == .next ? issues.first { $0.offset > offset } ?? issues.first
            : issues.last { $0.offset < offset } ?? issues.last
        if let issue { visitJSONIssue(issue, generation: surface.generation) }
    }

    @objc private func openJSONIssues(_ sender: Any?) {
        guard canGoToJSONIssue, let parent = window else { return }
        let presentation = surface.visibleJSONIssues, generation = surface.generation
        if (sender as? NSButton) === jsonIssuesButton, presentation.issues.count == 1, let issue = presentation.issues.first {
            visitJSONIssue(issue, generation: generation)
            return
        }
        let title = selectedSyntaxLanguage == .jsonLines ? "JSON Lines Issues" : "JSON Issues"
        let count = jsonIssueCount(presentation.issues, more: presentation.hasMore)
        let offset = surface.textView.selectedRange().location
        let selected = presentation.issues.firstIndex { $0.offset == offset } ?? 0
        let sheet = makeJSONIssueSheet(title: title, count: count, issues: presentation.issues, initialSelection: selected)
        chooseNavigationTarget(in: parent, using: sheet, generation: generation) { [weak self] issue in
            guard let self, surface.visibleJSONIssues == presentation else { return }
            visitJSONIssue(issue, generation: generation)
        }
    }

    private func visitJSONIssue(_ issue: LocalJSONCheck.Issue, generation: UUID) {
        if surface.goToTextOffset(issue.offset, generation: generation) { reportNavigation(issue.message) }
    }

    @objc private func checkJSONDocument(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let parent = window else { return }
        let syntax = selectedSyntaxLanguage
        let generation = surface.generation
        let text = surface.textView.string
        let choosesSchema = sender.tag == 1
        let existingSchema = sender.tag == 2 ? jsonSchemaSnapshot : nil
        let records = syntax == .jsonLines
        guard text.utf8.count <= LocalJSONCheck.maximumBytes else {
            reportNavigation("Check a document of 1 MiB or less.")
            return
        }
        navigationChoice = Task { [weak self, weak parent] in
            defer { self?.navigationChoice = nil }
            guard let parent else { return }
            var selectedSchema: URL?
            if choosesSchema {
                guard let url = await Self.chooseJSONSchema(in: parent, prompt: "Check") else { return }
                selectedSchema = url
            }
            guard let self, !Task.isCancelled, !closing, window === parent, parent.isVisible else { return }
            @MainActor func isCurrent() -> Bool {
                surface.generation == generation && selectedSyntaxLanguage == syntax
                    && !surface.textView.hasMarkedText() && surface.textView.string.utf16.elementsEqual(text.utf16)
            }
            guard isCurrent() else { return }
            reportNavigation(records ? "Checking JSON Lines…" : "Checking JSON…")
            let file = selectedSchema
            let allowsComments = syntax == .jsonc
            let worker = Task.detached(priority: .userInitiated) { () throws -> (LocalJSONCheck.Result, String?) in
                if let existingSchema {
                    return (try LocalJSONCheck.check(text, allowsComments: allowsComments, schema: existingSchema), existingSchema)
                }
                if let file {
                    switch try LocalJSONCheck.readSchema(file) {
                    case .loaded(let schema):
                        return (try LocalJSONCheck.check(text, allowsComments: allowsComments, schema: schema), schema)
                    case .unavailable(let message): return (.unavailable(message), nil)
                    }
                }
                let check = try (records ? LocalJSONCheck.checkJSONLines(text) : LocalJSONCheck.check(text, allowsComments: allowsComments))
                return (check, nil)
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, !closing, window === parent, parent.isVisible else { return }
            guard isCurrent() else {
                reportNavigation("The text or language changed. Run the check again.")
                return
            }
            switch result {
            case .failure:
                reportNavigation("The JSON check stopped.")
            case .success((.unavailable(let message), _)):
                reportNavigation(message)
            case .success((.checked(let issues, let more), let schema)):
                if let schema { jsonSchemaSnapshot = schema }
                surface.presentDiagnostics(issues, hasMore: more, for: generation)
                await showJSONIssues(surface.visibleJSONIssues, usedSchema: schema != nil, records: records, in: parent, generation: generation,
                                     isCurrent: isCurrent)
            }
        }
    }

    private func showJSONIssues(_ presentation: NativeTextEditorSurface.JSONIssues, usedSchema: Bool, records: Bool,
                                in parent: NSWindow, generation: UUID, isCurrent: @MainActor () -> Bool) async {
        let title = records ? "JSON Lines Check" : "JSON Check"
        guard !presentation.issues.isEmpty else {
            reportNavigation(usedSchema ? "JSON matches the selected schema." : "\(title) found no issues.")
            return
        }
        let count = jsonIssueCount(presentation.issues, more: presentation.hasMore)
        reportNavigation("\(title) found \(count).")
        let sheet = makeJSONIssueSheet(title: title, count: count, issues: presentation.issues)
        guard let issue = await sheet.choose(in: parent), !closing, window === parent, isCurrent() else { return }
        visitJSONIssue(issue, generation: generation)
    }

    private func jsonIssueCount(_ issues: [LocalJSONCheck.Issue], more: Bool) -> String {
        more ? "\(issues.count.formatted())+ issues" : issues.count == 1 ? "1 issue" : "\(issues.count.formatted()) issues"
    }

    private func makeJSONIssueSheet(title: String, count: String,
                                    issues: [LocalJSONCheck.Issue], initialSelection: Int = 0) -> NativeChoiceSheet<LocalJSONCheck.Issue> {
        NativeChoiceSheet(title: title, heading: "\(title) · \(count)", confirm: "Go to Issue", rows: issues.map {
            .init(title: $0.message, detail: "Line \($0.line.formatted()), column \($0.column.formatted())", value: $0)
        }, initialSelection: initialSelection)
    }

    @objc private func performFind(_ sender: NSMenuItem) {
        guard window?.isKeyWindow == true, window?.isVisible == true, !closing, window?.attachedSheet == nil,
              let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        surface.find.perform(action)
    }
    @objc private func saveDocument(_ sender: Any?) { if !closing && window?.isKeyWindow == true && saveButton.isEnabled { onSave?() } }
    @objc private func saveDocumentAs(_ sender: Any?) { if !closing && window?.isKeyWindow == true && saveAsButton.isEnabled { onSaveAs?() } }
    @objc private func saveTextCopy(_ sender: Any?) { if !closing && window?.isKeyWindow == true && !textCopyButton.isHidden && textCopyButton.isEnabled { onTextCopy?() } }
    @objc private func showTextCopyResults(_ sender: Any?) {
        guard !closing, window?.isKeyWindow == true, !textCopyResultsButton.isHidden, textCopyResultsButton.isEnabled else { return }
        guard copyResults.count > 1 else { onTextCopyResults?(copyResults.first?.id); return }
        let menu = NSMenu()
        for result in copyResults {
            let item = NSMenuItem(title: result.title, action: #selector(showExactTextCopyResult(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = result.id.uuidString; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .init(x: 0, y: textCopyResultsButton.bounds.height), in: textCopyResultsButton)
    }
    @objc private func showExactTextCopyResult(_ sender: NSMenuItem) {
        guard !closing, window?.isKeyWindow == true, textCopyResultsButton.isEnabled,
              let raw = sender.representedObject as? String, let record = UUID(uuidString: raw),
              copyResults.contains(where: { $0.id == record }) else { return }
        onTextCopyResults?(record)
    }
    @objc private func reloadDocument(_ sender: Any?) { if !closing && window?.isKeyWindow == true && reloadButton.isEnabled { onReload?() } }
    @objc private func reviewBeforeSave(_ sender: Any?) {
        if !closing && window?.isKeyWindow == true && beforeSaveButton.isEnabled { onRefusedVersion?(.before) }
    }
    @objc private func reviewEditedSave(_ sender: Any?) {
        if !closing && window?.isKeyWindow == true && editedSaveButton.isEnabled { onRefusedVersion?(.edited) }
    }
    @objc private func reviewVersions(_ sender: Any?) { if !closing && window?.isKeyWindow == true && recoveryButton.isEnabled { onRecovery?() } }
    @objc private func stopDocumentWork(_ sender: Any?) { if !closing && window?.isKeyWindow == true && stopButton.isEnabled { onStop?() } }
    @objc private func showGitLineCommit(_ sender: Any?) { gitLineReview?.lookUp() }
    @objc private func stopGitLineCommit(_ sender: Any?) { gitLineReview?.stop() }
    @objc private func findInSelection(_ sender: Any?) { surface.find.findInSelection() }

    @objc private func findInCurrentScope(_ sender: NSMenuItem) {
        if validateUserInterfaceItem(sender) { surface.find.findInCurrentScope() }
    }

    @objc private func replaceOccurrencesInFile(_ sender: NSMenuItem) {
        guard canChooseNavigationTarget, let seed = surface.occurrenceSeed() else { return }
        surface.find.replaceOccurrences(of: seed.query, wholeWord: seed.wholeWord)
    }
    @objc private func showGoToLine(_ sender: Any?) {
        guard !closing, let window else { return }
        lineNavigation.present(in: window, surface: surface) { [weak self] in
            self?.status.stringValue = "The text changed. Open Go to Line again."
        }
    }
    @objc private func goToMatchingBracket(_ sender: Any?) { navigateBrackets(.matching) }
    @objc private func selectInsideBrackets(_ sender: Any?) { navigateBrackets(.enclosing) }
    @objc private func goToVisibleScope(_ sender: Any?) {
        if (sender as? NSButton) === scrollContextButton, canChooseVisibleScope,
           NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            chooseVisibleScope(sender)
        } else {
            surface.goToVisibleScope()
        }
    }

    private var canChooseVisibleScope: Bool {
        !closing && navigationChoice == nil && window?.isKeyWindow == true && window?.attachedSheet == nil
            && surface.canGoToLine && surface.textView.selectedRanges.count == 1 && (surface.scrollContext?.scopes.count ?? 0) > 1
    }

    @objc private func chooseVisibleScope(_ sender: Any?) {
        guard canChooseVisibleScope, let parent = window, let context = surface.scrollContext else { return }
        let sheet = NativeChoiceSheet<EditorDocumentOutline.Entry>(title: "Visible Scopes", heading: "Scopes at the Top of the Editor",
            confirm: "Go to Scope", rows: context.scopes.map {
                .init(title: $0.title, detail: "Line \($0.line.formatted())", value: $0)
            }, initialSelection: context.scopes.count - 1)
        chooseNavigationTarget(in: parent, using: sheet, generation: context.generation) { [weak self] entry in
            guard let self, surface.scrollContext == context else { return }
            surface.goToTextOffset(entry.offset, generation: context.generation)
        }
    }
    @objc private func visitOutlineItem(_ sender: NSMenuItem) {
        guard canChooseNavigationTarget, let direction = EditorJumpDirection(rawValue: sender.tag),
              let entry = surface.adjacentOutlineEntry(toward: direction) else { return }
        surface.goToTextOffset(entry.offset, generation: surface.generation)
    }
    @objc private func goToEnclosingScope(_ sender: NSMenuItem) {
        guard canChooseNavigationTarget, let entry = surface.enclosingOutlineEntry else { return }
        surface.goToTextOffset(entry.offset, generation: surface.generation)
    }
    @objc private func goToLastEdit(_ sender: NSMenuItem) {
        if validateUserInterfaceItem(sender) { surface.goToLastEdit() }
    }

    @objc private func toggleLineBookmark(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let line = surface.bookmarkCaretLine else { return }
        let wasBookmarked = surface.hasBookmark(on: line)
        let changed = surface.toggleBookmarkAtCaret()
        reportNavigation(changed ? (wasBookmarked ? "Bookmark removed." : "Bookmark added.")
            : "This editor can hold up to \(EditorLineBookmarks.maximumCount) bookmarks.")
    }

    @objc private func visitLineBookmark(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let direction = EditorJumpDirection(rawValue: sender.tag),
              let line = surface.bookmarkLine(toward: direction) else { return }
        surface.goToLine(line, generation: surface.generation)
    }

    @objc private func chooseLineBookmark(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let parent = window, let index = surface.lineIndex else { return }
        let text = surface.textView.string as NSString, generation = surface.generation
        let lines = surface.bookmarkedLines
        let rows = lines.map { line -> NativeChoiceSheet<Int>.Row in
            let excerpt = index.start(ofLine: line).flatMap {
                EditorFindPlan.excerpt(for: .init(location: $0, length: 0), in: text, lines: index)?.text
            }
            return .init(title: "Line \(line.formatted())", detail: excerpt ?? "", value: line)
        }
        let selected = surface.bookmarkCaretLine.flatMap { lines.firstIndex(of: $0) } ?? 0
        let sheet = NativeChoiceSheet<Int>(title: "Line Bookmarks", heading: "Bookmarked Lines",
            confirm: "Go to Bookmark", rows: rows, initialSelection: selected)
        chooseNavigationTarget(in: parent, using: sheet, generation: generation) { [weak self] line in
            guard let self, surface.hasBookmark(on: line) else { return }
            surface.goToLine(line, generation: generation)
        }
    }

    private var canChooseNavigationTarget: Bool {
        !closing && navigationChoice == nil && window?.isKeyWindow == true && window?.attachedSheet == nil
            && window?.firstResponder === surface.textView
    }

    @objc private func findLocalDeclaration(_ sender: Any?) {
        guard canChooseNavigationTarget, surface.canFindDeclaration, let parent = window else { return }
        let candidates = surface.matchingDeclarations()
        guard let first = candidates.first else { reportNavigation("No recognized declaration for this text in the current file."); return }
        let generation = surface.generation
        let jump: @MainActor (EditorDocumentOutline.Entry) -> Void = { [weak self] entry in
            guard let self, surface.goToTextOffset(entry.offset, generation: generation) else { return }
            reportNavigation("Declaration at line \(entry.line.formatted()).")
        }
        if candidates.count == 1 { jump(first.entry); return }
        let sheet = NativeChoiceSheet<EditorDocumentOutline.Entry>(title: "Choose Declaration",
            heading: "Declarations in This File", confirm: "Go to Declaration", rows: candidates.map {
                .init(title: $0.preview, detail: "Line \($0.entry.line.formatted())", value: $0.entry)
            })
        chooseNavigationTarget(in: parent, using: sheet, generation: generation, accept: jump)
    }

    @objc private func completeLocalName(_ sender: Any?) {
        if supportsJSONFormatting { completeWithJSONSchema(sender); return }
        guard canChooseNavigationTarget, surface.canCompleteLocalName, let parent = window else { return }
        guard let request = surface.nameCompletion(), let first = request.entries.first else {
            reportNavigation("No name in this file completes the text at the caret.")
            return
        }
        let insert: @MainActor (EditorDocumentOutline.Entry) -> Void = { [weak self] entry in
            guard let self else { return }
            if surface.completeLocalName(entry, with: request) { reportNavigation("Completed name.") }
        }
        if request.entries.count == 1 { insert(first); return }
        let sheet = NativeChoiceSheet<EditorDocumentOutline.Entry>(title: "Complete Name",
            heading: "Matching Names in This File", confirm: "Complete Name", rows: request.entries.map {
                .init(title: $0.title, detail: "Declared at line \($0.line.formatted())", value: $0)
            })
        chooseNavigationTarget(in: parent, using: sheet, generation: request.generation, accept: insert)
    }

    private func chooseNavigationTarget<Value: Sendable>(in parent: NSWindow, using sheet: NativeChoiceSheet<Value>,
                                                generation: UUID, accept: @escaping @MainActor (Value) -> Void) {
        let language = selectedSyntaxLanguage, selection = surface.textView.selectedRange()
        navigationChoice = Task { [weak self, weak parent] in
            defer { self?.navigationChoice = nil }
            guard let parent, let choice = await sheet.choose(in: parent), let self,
                  !Task.isCancelled, !closing, window === parent, parent.isVisible,
                  parent.attachedSheet == nil, parent.isKeyWindow || NSApp.keyWindow == nil else { return }
            guard surface.generation == generation, selectedSyntaxLanguage == language, surface.textView.selectedRanges.count == 1,
                  surface.textView.selectedRange() == selection, !surface.textView.hasMarkedText() else {
                reportNavigation("The text or selection changed. Try again.")
                return
            }
            accept(choice)
        }
    }
    @objc private func visitTextLocation(_ sender: NSMenuItem) {
        guard !closing, let direction = EditorJumpDirection(rawValue: sender.tag) else { return }
        EditorDocumentNavigation.shared.visit(direction, from: self)
    }
    @objc private func visitUnsavedChange(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let direction = EditorJumpDirection(rawValue: sender.tag),
              let line = surface.unsavedChangeLine(toward: direction) else { return }
        surface.goToLine(line, generation: surface.generation)
    }
    @objc private func reviewSelectedUnsavedLine(_ sender: Any?) {
        if let line = surface.selectedUnsavedLine { _ = reviewUnsavedLine(line) }
    }

    @objc private func chooseUnsavedChange(_ sender: Any?) {
        guard canChooseNavigationTarget, surface.canGoToLine, let parent = window,
              let changes = surface.unsavedLineChanges, !changes.marks.isEmpty else { return }
        let generation = surface.generation
        let line = surface.selectedUnsavedLine.map { $0 - 1 }
        let selected = changes.marks.firstIndex { mark in line.map(mark.lines.contains) == true } ?? 0
        let rows = changes.marks.map { mark -> NativeChoiceSheet<EditorUnsavedLineChanges.Mark>.Row in
            let title: String
            switch mark.kind {
            case .added: title = "Added " + mark.change.currentLineLabel
            case .changed: title = "Edited " + mark.change.currentLineLabel
            case .removed: title = "Deleted " + mark.change.beforeLineLabel
            }
            return .init(title: title, detail: "Saved \(mark.change.beforeLineLabel) · Edited \(mark.change.currentLineLabel)", value: mark)
        }
        let preview: NativeChoiceSheet<EditorUnsavedLineChanges.Mark>.SelectionPreview?
        if let capture = captureComparison?(), let identity = capture.right.editor, identity == editableBufferIdentity {
            let beforeLength = capture.left.text.utf16.count, currentLength = capture.right.text.utf16.count
            preview = changes.marks.allSatisfy {
                NSMaxRange($0.change.beforeRange) <= beforeLength && NSMaxRange($0.change.currentRange) <= currentLength
            } ? EditorChangeExcerpt.selectionPreview(before: ("Saved", capture.left.text),
                after: ("Edited", capture.right.text), change: \.change) : nil
        } else { preview = nil }
        let sheet = NativeChoiceSheet(title: "Go to Unsaved Change", heading: "Changes Since Save", confirm: "Go to Change",
            rows: rows, initialSelection: selected, preview: preview,
            size: preview.map { _ in EditorChangeExcerpt.choiceSize(in: parent) })
        chooseNavigationTarget(in: parent, using: sheet, generation: generation) { [weak self] mark in
            guard let self else { return }
            let line = mark.lines.lowerBound
            guard let current = surface.unsavedLineChanges, current.baselineID == changes.baselineID, current.mark(at: line) == mark else {
                reportNavigation("The saved version changed. Open the list again.")
                return
            }
            surface.goToLine(line + 1, generation: generation)
        }
    }

    private func reviewUnsavedLine(_ line: Int) -> Bool {
        guard canCompare, let parent = window, parent.isKeyWindow,
              let marks = surface.unsavedLineChanges, let mark = marks.mark(at: line - 1),
              let capture = captureComparison?(), let identity = capture.right.editor, identity == editableBufferIdentity,
              NSMaxRange(mark.change.beforeRange) <= capture.left.text.utf16.count,
              NSMaxRange(mark.change.currentRange) <= capture.right.text.utf16.count else { return false }
        closeUnsavedChangePreview()
        let content = EditorUnsavedChangePreview(mark.change, capture: capture) { [weak self, weak parent] in
            guard let self, let parent, window === parent, canCompare, unsavedChangePreview?.isShown == true,
                  editableBufferIdentity == identity, surface.unsavedLineChanges?.baselineID == marks.baselineID,
                  surface.unsavedLineChanges?.mark(at: line - 1) == mark else {
                self?.closeUnsavedChangePreview(); return
            }
            closeUnsavedChangePreview()
            if savedComparison()?.present(capture, at: mark.change) != true {
                reportNavigation("Finish the current comparison, then open this change again.")
            }
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        let motion = commandDiscoverySettings?.motion ?? .init()
        popover.animates = motion.mode == .full && motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = content
        popover.delegate = self
        unsavedChangePreview = popover
        let (anchor, rect) = surface.unsavedLineAnchor(line)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
        if !popover.isShown { closeUnsavedChangePreview(); return false }
        return true
    }

    private func closeUnsavedChangePreview() {
        let previous = unsavedChangePreview
        unsavedChangePreview = nil
        previous?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === unsavedChangePreview { unsavedChangePreview = nil }
    }
    private func conflictDestination(toward direction: EditorJumpDirection) -> Int? {
        guard !closing, surface.lineCommands.canNavigate, surface.canGoToLine else { return nil }
        return surface.conflictMarkers?.destination(from: surface.textView.selectedRange().location, toward: direction)
    }
    @objc private func visitConflictMarker(_ sender: NSMenuItem) {
        guard let direction = EditorJumpDirection(rawValue: sender.tag), let offset = conflictDestination(toward: direction) else { return }
        surface.goToTextOffset(offset, generation: surface.generation)
    }
    @objc private func resolveConflictMarker(_ sender: NSMenuItem) {
        guard validateUserInterfaceItem(sender), let choice = EditorConflictMarkers.Resolution(rawValue: sender.tag) else { return }
        surface.lineCommands.perform(.resolveConflict(choice))
    }
    private func navigateBrackets(_ operation: EditorBracketNavigation) {
        guard !closing, let language = selectedSyntaxLanguage, EditorBracketNavigation.supports(language) else { return }
        surface.lineCommands.perform(.navigateBrackets(operation, language))
    }
    private func cancelLineNavigation() { lineNavigation.cancel() }
    @objc private func toggleWrap(_ sender: Any?) { surface.setWrapping(wrapping.state == .on); onWrapping?() }
    @objc private func changeLanguage(_ sender: Any?) {
        let values = TextSyntaxLanguage.allCases
        guard values.indices.contains(language.indexOfSelectedItem) else { return }
        surface.setEditingLanguage(values[language.indexOfSelectedItem])
        onLanguage?(values[language.indexOfSelectedItem])
    }
}
