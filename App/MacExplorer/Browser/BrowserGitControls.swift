import AppKit
import ExplorerCore
import LocalStorage

@MainActor final class BrowserGitControls {
    private enum WorktreePlacement: Sendable { case tab, pane }
    private enum WorkingFileSource: Sendable { case disk, editor }
    private struct Visit: Equatable {
        let tab: UUID
        let session: UUID
        let directory: URL
    }

    private weak var browser: BrowserViewController?
    private var requested: Visit?
    private var work: Task<Void, Never>?
    private let selectionRequest = GitReviewRequest()
    private(set) var checkout: GitCheckoutObservation?
    var repository: GitRepositoryLocation? { checkout?.location }
    private lazy var badges = GitViewportBadges(request: { [weak self] in self?.badgeRequest() },
        delivered: { [weak self] changed, _ in self?.browser?.redrawGitBadges(changed) })

    init(browser: BrowserViewController) { self.browser = browser }
    isolated deinit { work?.cancel() }

    var isAvailable: Bool {
        guard let browser else { return false }
        return browser.settings.showsGitControls && !browser.isBrowserSuspended && !browser.isOfflineCurrentFolder
            && !browser.metadataSearch.isShowingResults && repository != nil && requested == visit(browser)
    }

    func update(refreshingCheckout: Bool = false) {
        let next = browser.flatMap(visit)
        guard requested != next else {
            if refreshingCheckout { startIfIdle() }
            updateBadges()
            return
        }
        requested = next
        checkout = nil
        badges.invalidate(clear: true)
        browser?.updateGitButton()
        work?.cancel()
        selectionRequest.stop()
        startIfIdle()
    }

    func cancel() {
        requested = nil
        checkout = nil
        work?.cancel()
        selectionRequest.stop()
        badges.invalidate(clear: true)
        browser?.updateGitButton()
    }

    private func visit(_ browser: BrowserViewController) -> Visit? {
        guard browser.settings.showsGitControls, !browser.isBrowserSuspended, !browser.isReadOnlyFileSession,
              !browser.isOfflineCurrentFolder, !browser.metadataSearch.isShowingResults,
              let directory = browser.location.directoryURL, directory.isFileURL else { return nil }
        return .init(tab: browser.activeID, session: browser.sessionID, directory: directory)
    }

    private func startIfIdle() {
        guard work == nil, let request = requested, let browser else { return }
        let access = browser.folderAccess
        let fileSystem = browser.fileSystem
        work = Task { [weak self] in
            let found = try? await GitReviewAccess.discover(in: request.directory, fileSystem: fileSystem, access: access)
            guard let self else { return }
            work = nil
            if requested != request {
                startIfIdle()
                return
            }
            guard !Task.isCancelled, let browser = self.browser, visit(browser) == request else { return }
            if checkout?.head != found?.head { badges.invalidate(clear: false) }
            checkout = found
            browser.updateGitButton()
            updateBadges()
        }
    }

    func badge(for entry: FileEntry) -> GitStatusBadge? {
        guard entry.kind == .file, browser?.settings.showsGitFileBadges == true, isAvailable else { return nil }
        return badges.badge(for: entry.url)
    }

    func badgePreferenceChanged() {
        badges.invalidate(clear: true)
        updateBadges()
    }

    var isChoosing: Bool { selectionRequest.isRunning }

    func editIndex(_ action: GitIndexEditAction, file: (url: URL, path: GitSnapshotPath),
                   using access: GitReviewAccess, in parent: NSWindow) {
        guard !isChoosing, let browser else { return }
        let originalVisit = requested
        let prior = browser.status.stringValue
        browser.status.stringValue = "Checking the Git index…"

        @MainActor func isCurrent(_ owner: BrowserGitControls, _ window: NSWindow) -> Bool {
            guard let browser = owner.browser, let selected = browser.selectedGitFile else { return false }
            return owner.requested == originalVisit && selected.path == file.path && selected.url == file.url
                && browser.viewIfLoaded?.window === window && window.isKeyWindow
                && browser.workspace?.isClosing == false && !ApplicationFileActivity.gate.isClosed
        }

        selectionRequest.start(preservesOutcome: true, { [weak self, weak parent] in
            guard let self, let parent else { throw CancellationError() }
            await badges.pauseAndDrain()
            defer { badges.resume() }
            try Task.checkCancellation()
            let source = ApplicationLocalTextEditors.shared.reviewSource(for: file.url)
            return try await GitIndexEditFlow.run(action, path: file.path, using: access, in: parent,
                hasUnsavedEdits: source.hasDraft, isCurrent: { isCurrent(self, parent) })
        }, accept: { [weak self, weak parent] result in
            guard let self, let parent, requested == originalVisit, let browser = self.browser,
                  browser.viewIfLoaded?.window === parent else { return }
            switch result {
            case .success(let outcome):
                browser.status.stringValue = outcome.notice(for: action) ?? prior
            case .failure(is CancellationError):
                browser.status.stringValue = prior
            case .failure(let error):
                browser.status.stringValue = GitIndexEditFlow.message(for: error)
            }
        })
    }

    func browseWorktrees(using access: GitReviewAccess, in parent: NSWindow) {
        guard !isChoosing, let browser else { return }
        let originalVisit = requested
        let status = browser.status.stringValue
        let reading = "Reading Git worktrees…"
        browser.status.stringValue = reading

        func currentBrowser(_ owner: BrowserGitControls, _ window: NSWindow) -> BrowserViewController? {
            guard owner.requested == originalVisit, owner.isAvailable, let browser = owner.browser,
                  browser.canOpenWorktree, browser.viewIfLoaded?.window === window, window.isKeyWindow else { return nil }
            return browser
        }

        selectionRequest.start({ [weak self, weak parent] () async throws -> (url: URL, placement: WorktreePlacement, atRoot: Bool)? in
            guard let self, let parent else { throw CancellationError() }
            defer {
                if requested == originalVisit, self.browser?.status.stringValue == reading { self.browser?.status.stringValue = status }
            }
            let listing = try await access.worktrees()
            guard let browser = currentBrowser(self, parent) else { throw CancellationError() }
            guard let choice = await GitWorktreeSheet<WorktreePlacement>.choose(listing,
                matchingFolder: GitSnapshotPath(access.location.relativeFolder),
                primary: .init(title: "Open in Tab", destination: .tab, identifier: "git-worktree-tab"),
                alternate: .init(title: "Open in Pane", destination: .pane, identifier: "git-worktree-pane",
                                 enabled: browser.worktreeSplitEdge != nil), in: parent) else { return nil }
            let url = try await access.verifiedURL(for: choice.worktree, matching: choice.folder)
            return (url, choice.destination, choice.folder != nil && url == choice.worktree.url)
        }, accept: { [weak self, weak parent] result in
            guard let self, let parent, let browser = currentBrowser(self, parent) else { return }
            switch result {
            case .success(let choice?):
                switch choice.placement {
                case .tab:
                    if let open = browser.tabs.first(where: { $0.location.directoryURL?.path.utf8.elementsEqual(choice.url.path.utf8) == true }) {
                        browser.selectTab(open.id)
                    } else { browser.openNewTab(at: .directory(choice.url)) }
                case .pane:
                    guard let edge = browser.worktreeSplitEdge,
                          browser.workspace?.splitActive(at: edge, showing: .directory(choice.url)) == true else {
                        browser.status.stringValue = "Make room for another pane or open the worktree in a tab."
                        return
                    }
                }
                if choice.atRoot { browser.status.stringValue = "Matching folder unavailable. Opened the checkout root." }
            case .failure(let error) where !(error is CancellationError):
                browser.status.stringValue = GitReviewAccess.message(for: error)
            default: break
            }
        })
    }

    func compareFile(path: GitSnapshotPath, workingFile: URL? = nil, using access: GitReviewAccess, in parent: NSWindow) {
        guard !isChoosing, let browser else { return }
        let originalVisit = requested
        let previousStatus = browser.status.stringValue
        let opening = "Opening Git revisions…"
        let captureEditor = workingFile.flatMap { ApplicationLocalTextEditors.shared.capturedEditorSource(for: $0) }
        browser.status.stringValue = opening

        func isCurrent(_ owner: BrowserGitControls, _ window: NSWindow) -> Bool {
            guard let browser = owner.browser, let selection = browser.selectedGitFile else { return false }
            return owner.requested == originalVisit && browser.viewIfLoaded?.window === window && window.isKeyWindow
                && selection.path == path && (workingFile == nil || workingFile == selection.url)
        }

        selectionRequest.start({ [weak self, weak parent] () async throws -> EditorComparisonWindow.Source? in
            guard let self, let parent else { throw CancellationError() }
            await badges.pauseAndDrain()
            defer {
                badges.resume()
                if self.browser?.status.stringValue == opening { self.browser?.status.stringValue = previousStatus }
            }
            try Task.checkCancellation()
            let catalog = try await access.catalog()
            guard isCurrent(self, parent) else { throw CancellationError() }
            let options = GitRevisionOption.choices(catalog)
            if let workingFile {
                return try await compareWorkingFile(workingFile, path: path, captureEditor: captureEditor,
                    choices: options, using: access, in: parent)
            }
            guard let choice = await GitFileRevisionPair.choose(filename: path.display, choices: options, in: parent) else { return nil }
            try Task.checkCancellation()
            return try await choice.resolve(path: path, using: access)
        }, accept: { [weak self, weak parent] result in
            guard let self, let parent, isCurrent(self, parent), let browser = self.browser,
                  let workspace = browser.workspace, !workspace.isClosing else { return }
            switch result {
            case .success(let comparison?):
                workspace.presentTextComparison(relativeTo: parent, settings: browser.settings, labels: comparison.labels,
                                                capture: comparison.read)
            case .failure(let error) where !(error is CancellationError):
                browser.status.stringValue = GitReviewAccess.message(for: error)
            default: break
            }
        })
    }

    private func compareWorkingFile(_ file: URL, path: GitSnapshotPath, captureEditor: (@MainActor () -> EditorComparisonCapture.Side?)?,
                                    choices: [GitRevisionOption], using access: GitReviewAccess, in parent: NSWindow)
        async throws -> EditorComparisonWindow.Source? {
        let sheet = GitFileRevisionSheet<WorkingFileSource>(filename: path.display, choices: choices,
            primary: .init(title: "Compare On-Disk File", intent: .disk),
            alternate: captureEditor.map { _ in .init(title: "Compare Open Editor", intent: .editor) })
        guard let choice = await sheet.choose(in: parent) else { return nil }
        try Task.checkCancellation()
        let version = try await access.version(path: path, at: choice.revision.revision)
        guard let source = version.editorTextSource else {
            throw EditorComparisonLoadFailure.unavailable("This revision contains a folder, symbolic link or submodule at this path.")
        }
        let editor = choice.intent == .editor
        let local = ApplicationLocalTextEditors.shared.reviewSource(for: file)
        let labels = EditorComparisonWindow.Labels(title: "Git Text Diff", source: path.display,
            left: choice.revision.title + " · " + source.label,
            right: editor ? "Editor Buffer · " + file.lastPathComponent : local.label(.disk),
            detail: editor ? "Refresh captures the same editor and keeps the revision pinned."
                : "Refresh rereads the file on disk and keeps the revision pinned.",
            refresh: editor ? "Refresh Editor" : "Refresh On-Disk File")
        return .init(labels: labels, read: {
            let current: EditorComparisonCapture.Side
            if editor {
                guard let text = captureEditor?() else {
                    throw EditorComparisonLoadFailure.unavailable("The original editor moved, closed or is busy. Open a new comparison to use another editor.")
                }
                current = text
            } else {
                current = try await local.read(.disk, through: access)
            }
            return .init(left: try await access.committedSide(source.member), right: current)
        })
    }

    func updateBadges(windowBecameKey: Bool = false) {
        if windowBecameKey { badges.invalidate(clear: false) }
        badges.update()
    }

    private func badgeRequest() -> GitViewportBadges.Request? {
        guard let browser, browser.settings.showsGitFileBadges, isAvailable, let repository, !browser.isLoading,
              browser.viewIfLoaded?.window?.isKeyWindow == true else { return nil }
        let urls = browser.visibleFileEntries.lazy
            .filter { $0.kind == .file && repository.filePath(for: $0.url) != nil }
            .prefix(GitViewportBadges.maximumVisibleFiles).map(\.url)
        guard !urls.isEmpty, let access = GitReviewAccess(location: repository,
            fileSystem: browser.fileSystem, access: browser.folderAccess) else { return nil }
        return .init(access: access, urls: Array(urls), generation: browser.filePresentationID, inspectWorkingBytes: false)
    }
}

@MainActor extension BrowserViewController {
    func redrawGitBadges(_ urls: Set<URL>) {
        guard !urls.isEmpty, isViewLoaded, !isRemoteLocation, !isArchiveLocation, !showsComputerVolumes else { return }
        if usesFileIcons {
            iconBrowser.refreshGitBadges(at: urls)
        } else if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
            for url in urls {
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row),
                      let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? FileNameCellView else { continue }
                let entry = displayedEntries[row]
                decorateFilenameCell(cell, for: entry, opening: fileOpeningAppearance(entry), cut: cutURLs.contains(url))
            }
        }
    }

    fileprivate var selectedGitFile: (url: URL, path: GitSnapshotPath)? {
        guard gitControls.isAvailable, hasFileCommandFocus, !isLoading, view.window?.attachedSheet == nil,
              selectedItemCount == 1, let url = orderedSelectedURLs(upTo: 1).first,
              let row = rowsByURL[url], displayedEntries.indices.contains(row), displayedEntries[row].kind == .file,
              let path = gitControls.repository?.filePath(for: url) else { return nil }
        return (url, path)
    }

    var canShowGitFileHistory: Bool { selectedGitFile != nil }
    var canCompareSelectedGitFile: Bool { canShowGitFileHistory && !gitControls.isChoosing }
    var canEditSelectedGitIndex: Bool {
        canCompareSelectedGitFile && isActiveCommandPane && !hasExclusiveBrowserOperation
            && workspace?.isClosing == false && !ApplicationFileActivity.gate.isClosed
    }

    fileprivate var canOpenWorktree: Bool {
        isActiveCommandPane && canOpenBrowserTab && !hasExclusiveBrowserOperation && cutPreparationTask == nil
            && workspace?.isClosing == false && !ApplicationFileActivity.gate.isClosed
    }

    fileprivate var worktreeSplitEdge: PaneDropEdge? {
        [.trailing, .bottom].first { workspace?.canSplitActive(at: $0) == true }
    }

    var canBrowseGitWorktrees: Bool { gitControls.isAvailable && canOpenWorktree && !gitControls.isChoosing }

    @objc func browseGitWorktrees(_ sender: Any?) {
        guard canBrowseGitWorktrees, let access = gitReviewAccess, let parent = view.window, parent.isKeyWindow else { return }
        gitControls.browseWorktrees(using: access, in: parent)
    }

    private var gitReviewAccess: GitReviewAccess? {
        guard gitControls.isAvailable, isActiveCommandPane, let repository = gitControls.repository else { return nil }
        return GitReviewAccess(location: repository, fileSystem: fileSystem, access: folderAccess)
    }

    func canCompareGitCheckout(with peer: BrowserViewController) -> Bool {
        guard gitControls.isAvailable, peer.gitControls.isAvailable, !isLoading, !peer.isLoading,
              let parent = viewIfLoaded?.window, parent.attachedSheet == nil, parent === peer.viewIfLoaded?.window,
              let first = gitControls.checkout, first.head != nil,
              let second = peer.gitControls.checkout, second.head != nil else { return false }
        return first.location.canCompareCheckedOutRevisions(with: second.location)
    }

    @discardableResult func compareGitCheckout(with peer: BrowserViewController) -> Bool {
        guard canCompareGitCheckout(with: peer), let first = gitControls.repository, let second = peer.gitControls.repository,
              let parent = viewIfLoaded?.window, let workspace, !workspace.isClosing,
              let left = GitReviewAccess(location: first, fileSystem: fileSystem, access: folderAccess),
              let right = GitReviewAccess(location: second, fileSystem: peer.fileSystem, access: peer.folderAccess) else { return false }
        workspace.presentGitComparison(access: left, parent: parent, settings: settings, pairedWith: right)
        return true
    }

    func updateGitButton() {
        // Git discovery and ordinary navigation validation also affect the
        // actions beside a split, even while the pointer remains still.
        defer { workspace?.refreshPaneDividerControls() }
        guard let button = navigationButtons.first(where: { $0.1 == #selector(showGitMenu(_:)) })?.0 else { return }
        button.isEnabled = commandEnabled(#selector(showGitMenu(_:)))
        let head = gitControls.checkout?.head?.displayName
        button.toolTip = head.map { "Git Tools · " + $0 } ?? "Git Tools"
        button.setAccessibilityValue([gitControls.repository?.root.lastPathComponent, head].compactMap { $0 }.joined(separator: ", "))
        addressLayout?.updateCommandVisibility()
    }

    @objc func showGitMenu(_ sender: NSButton) {
        guard gitControls.isAvailable, isActiveCommandPane, let parent = view.window, parent.attachedSheet == nil else { return }
        gitToolsMenu().popUp(positioning: nil, at: .init(x: 0, y: sender.bounds.minY), in: sender)
    }

    func gitToolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Git")
        if let head = gitControls.checkout?.head { menu.addItem(.sectionHeader(title: head.displayName)) }
        BrowserMenus.gitReviewItems(target: self).filter(validateMenuItem).forEach(menu.addItem)
        return menu
    }

    @objc func compareGitRevisions(_ sender: Any?) {
        showGitComparison(.revisions)
    }

    @objc func compareGitWorkingFolder(_ sender: Any?) {
        showGitComparison(.working)
    }

    @objc func reviewStagedChanges(_ sender: Any?) {
        showGitComparison(.index)
    }

    @objc func showGitFolderHistory(_ sender: Any?) {
        showGitComparison(.folderHistory)
    }

    private func showGitComparison(_ mode: GitComparisonModel.Mode) {
        guard let access = gitReviewAccess, let parent = view.window, parent.attachedSheet == nil,
              let workspace, !workspace.isClosing else { return }
        workspace.presentGitComparison(access: access, parent: parent, settings: settings, mode: mode)
    }

    @objc func showGitFileHistory(_ sender: Any?) {
        guard let selected = selectedGitFile, let access = gitReviewAccess, let parent = view.window,
              let workspace, !workspace.isClosing else { return }
        let (url, path) = selected
        workspace.presentGitFileHistory(access: access, parent: parent, settings: settings, path: path,
                                        local: ApplicationLocalTextEditors.shared.reviewSource(for: url))
    }

    @objc func compareSelectedGitFileRevisions(_ sender: Any?) {
        guard canCompareSelectedGitFile, let selected = selectedGitFile, let access = gitReviewAccess,
              let parent = view.window, parent.isKeyWindow, workspace?.isClosing == false else { return }
        gitControls.compareFile(path: selected.path, using: access, in: parent)
    }

    @objc func compareSelectedGitWorkingFile(_ sender: Any?) {
        guard canCompareSelectedGitFile, let selected = selectedGitFile, let access = gitReviewAccess,
              let parent = view.window, parent.isKeyWindow, workspace?.isClosing == false else { return }
        gitControls.compareFile(path: selected.path, workingFile: selected.url, using: access, in: parent)
    }

    @objc func stageSelectedGitFile(_ sender: Any?) { editSelectedGitIndex(.stageSavedFile) }
    @objc func unstageSelectedGitFile(_ sender: Any?) { editSelectedGitIndex(.unstage) }

    private func editSelectedGitIndex(_ action: GitIndexEditAction) {
        guard canEditSelectedGitIndex, let file = selectedGitFile, let access = gitReviewAccess,
              let parent = view.window, parent.isKeyWindow else { return }
        gitControls.editIndex(action, file: file, using: access, in: parent)
    }
}
