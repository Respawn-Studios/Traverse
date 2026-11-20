import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage
import SwiftUI

extension BrowserViewController {
    @objc func newTab(_ sender: Any?) {
        _ = openNewTab(at: settings.newTabDestination.location(current: location, home: BrowsingHome.url))
    }

    @discardableResult
    func openNewTab(at destination: BrowserLocation) -> Bool {
        guard canOpenBrowserTab else { return false }
        saveViewState()
        let tab = BrowserTab(location: destination)
        tabs.append(tab)
        activeID = tab.id
        loadLocation(animatingTab: true)
        if isActiveCommandPane { focusBrowserContent() }
        return true
    }

    @objc func closeTab(_ sender: Any?) {
        guard let keyWindow = NSApplication.shared.keyWindow else { return }
        if keyWindow !== view.window {
            keyWindow.performClose(sender)
            return
        }
        closeTab(id: activeID)
    }

    func closeTab(id: UUID) {
        ApplicationDiagnostics.shared.event(.closeTab, .requested)
        guard !isBrowserSuspended, !hasExclusiveBrowserOperation, cutPreparationTask == nil, view.window?.attachedSheet == nil else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            if let workspace, workspace.browsers.count > 1 { _ = workspace.closeLastTab(in: self) }
            else { view.window?.performClose(nil) }
            return
        }
        saveViewState()
        smbTabs.removeValue(forKey: id)?.close()
        sftpTabs.removeValue(forKey: id)?.close()
        retireArchiveTab(id)
        sftpClosedUploadNotices.removeValue(forKey: id)
        smbClosedUploadNotices.removeValue(forKey: id)
        rememberClosedTab(tabs[index])
        tabs.remove(at: index)
        if activeID == id {
            activeID = tabs[min(index, tabs.count - 1)].id
            loadLocation(animatingTab: true)
            if isActiveCommandPane { focusBrowserContent() }
        } else {
            tabStrip.update(tabs: tabs, activeID: activeID)
            recordBrowserSession()
        }
    }

    func selectTab(_ id: UUID) {
        guard !isBrowserSuspended, id != activeID, tabs.contains(where: { $0.id == id }) else { return }
        ApplicationDiagnostics.shared.event(.switchTab, .requested)
        saveViewState()
        activeID = id
        loadLocation(animatingTab: true)
        if isActiveCommandPane { focusBrowserContent() }
    }

    @objc func goBack(_ sender: Any?) {
        guard !isBrowserSuspended, tabs[activeIndex].canGoBack else { return }
        saveViewState()
        tabs[activeIndex].goBack()
        recordsNextExplicitVisit = location.directoryURL != nil
        loadLocation(directoryDirection: -1)
    }

    @objc func goForward(_ sender: Any?) {
        guard !isBrowserSuspended, tabs[activeIndex].canGoForward else { return }
        saveViewState()
        tabs[activeIndex].goForward()
        recordsNextExplicitVisit = location.directoryURL != nil
        loadLocation(directoryDirection: 1)
    }

    @objc func goUp(_ sender: Any?) {
        if case .archive(let value) = location, value.folderPath.isEmpty, !isBrowserSuspended {
            saveViewState()
            let parent = BrowserLocation.directory(value.source.deletingLastPathComponent())
            var prior = tabs[activeIndex]
            while prior.canGoBack {
                prior.goBack()
                if prior.location == parent {
                    tabs[activeIndex] = prior; loadLocation(directoryDirection: -1); return
                }
            }
        }
        if case .sftp(let value) = location {
            if let parent = sftpTabs[activeID]?.parent(of: value) { navigate(to: .sftp(parent)) }; return
        }
        if case .smb(let value) = location {
            if let parent = smbTabs[activeID]?.parent(of: value) { navigate(to: .smb(parent)) }
            return
        }
        guard !isBrowserSuspended, location.parent != nil else { return }
        saveViewState()
        tabs[activeIndex].goUp()
        recordsNextExplicitVisit = location.directoryURL != nil
        loadLocation(directoryDirection: -1)
    }

    @objc func goComputer(_ sender: Any?) { navigate(to: .computer) }
    @objc func goHome(_ sender: Any?) {
        guard let home = BrowsingHome.url else {
            status.stringValue = "Home could not be located. Choose your Home folder or enter an absolute path."; return
        }
        navigate(to: .directory(home))
    }

    @objc func refresh(_ sender: Any?) {
        if isArchiveLocation { currentArchive?.refresh(); return }
        if case .smb(let value) = location { loadSMBLocation(value, refresh: true); return }
        if case .sftp(let value) = location { loadSFTPLocation(value, refresh: true); return }
        saveViewState()
        loadLocation()
        gitControls.update(refreshingCheckout: true)
    }

    @objc func chooseFolder(_ sender: Any?) {
        presentFolderChooser(remember: true)
    }

    @objc func openSelection(_ sender: Any?) {
        guard !isBrowserSuspended, !isOfflineCurrentFolder, !isMetadataAccessQualification else { return }
        if isArchiveLocation { currentArchive?.openSelection(); return }
        if isSMBLocation { smbTabs[activeID]?.rows.openSelectedFolder(); return }
        if isSFTPLocation { sftpTabs[activeID]?.rows.openSelectedItem(); return }
        if showsComputerVolumes { volumeBrowser.openSelection(); return }
        guard orderedSelectedURLs.count == 1, let url = orderedSelectedURLs.first,
              let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return }
        let entry = displayedEntries[row]
        if metadataSearch.isShowingResults { metadataSearch.openSelection(entry); return }
        switch entry.kind {
        case .directory: navigate(to: .directory(entry.url))
        case .symbolicLink:
            status.stringValue = "Symbolic links are listed without following their targets in this preview."
        case .file, .package, .other:
            openVerifiedLocalFile(entry)
        }
    }

    /// Called only after the local listing or guarded search-result observation
    /// has admitted this entry. ZIP-compatible documents keep their own Open.
    func openVerifiedLocalFile(_ entry: FileEntry, intent: BrowserLocalFileOpenIntent = .ordinary) {
        if intent == .systemDefault {
            if !handoffToDefaultApplication(entry.url) { status.stringValue = "No application could open this item." }
            return
        }
        if openUsingLocalPreference(entry) { return }
        let archive = entry.kind == .file ? FileOpeningAppearance.archiveKind(name: entry.name,
            zipAvailable: ArchiveBrowseActivation.available, tarAvailable: TARBrowseFeature.available) : nil
        if settings.opensArchivesInTraverse, let archive {
            let tar = archive == .tar
            operationCoordinator.drives.acknowledgeNavigation(to: entry.url)
            if InlineArchiveFeature.available, let value = try? ArchiveLocation(source: entry.url, format: tar ? .tar : .zip) {
                navigate(to: .archive(value))
                // This call follows an admitted, deliberate local Open. The
                // resulting intent belongs only to this presentation, not history.
                currentArchive?.prepareForExplicitUserOpen(value)
            } else if tar { ApplicationTARBrowser.shared.show(entry.url, from: self) }
            else { ApplicationZIPBrowser.shared.show(entry.url, from: self) }
            return
        }
        if !handoffToDefaultApplication(entry.url) { status.stringValue = "No application could open this item." }
    }

    /// The generated native loop observes the actual external-open boundary;
    /// it must never launch another application from a verification session.
    func handoffToDefaultApplication(_ url: URL) -> Bool {
        #if DEBUG
        if isVerificationSession { return defaultOpenForVerification?(url) ?? false }
        #endif
        return NSWorkspace.shared.open(url)
    }

    @objc func copyPath(_ sender: Any?) {
        if isArchiveLocation { copyObservedArchiveMetadata(name: false); return }
        if isRemoteLocation { copyObservedRemoteMetadata(name: false); return }
        let selected = orderedSelectedURLs
        let urls = selected.isEmpty ? location.directoryURL.map { [$0] } ?? [] : selected
        guard !urls.isEmpty else { return }
        clearCutSelection()
        _ = clipboardWriter(urls.map(\.path).joined(separator: "\n"), [])
    }

    @objc func copyFileURLs(_ sender: Any?) {
        if isArchiveLocation { captureArchiveClipboard(.copy); return }
        if isRemoteLocation { copyRemoteSelection(); return }
        let diagnostic = ApplicationDiagnostics.shared.workflow(.browse, context: .init(.clipboardPublish))
        let urls = orderedSelectedURLs
        guard !urls.isEmpty else {
            diagnostic.event(.blocked, context: .init(.clipboardPublish, flags: [.selectionUnavailable]), count: 0)
            return
        }
        clearCutSelection()
        let revision = clipboardRevision
        let publication = clipboardWriter(nil, urls)
        let changedDuringPublication = clipboardRevision != revision
        showTransferFeedback(.copy, urls: urls, publication: publication, revision: revision)
        let accepted = clipboardRevision == revision && transferFeedback?.intent == .copy && transferFeedback?.urls == urls
        diagnostic.event(accepted ? .completed : .blocked,
            context: .init(.clipboardPublish, flags: accepted ? [] : [changedDuringPublication ? .contextChanged : .clipboardPublicationFailed]),
            count: UInt64(urls.count))
    }

    @objc func focusLocation(_ sender: Any?) {
        if isRemoteLocation { focusRemoteAddress(); return }
        guard !isBrowserSuspended, isActiveCommandPane, let window = view.window,
              window.isVisible, window.attachedSheet == nil else { return }
        folderFilter.dismiss()
        if case .archive(let value) = location {
            currentArchive?.cancelAddressNavigation(); addressCompletion.cancel()
            pathField.stringValue = value.editablePath
            pathField.toolTip = "Type a folder within this archive, or its full displayed path. ../ goes to its parent. Return opens; Escape cancels."
            addressEditingContext = .init(pane: paneID, tab: activeID, visit: sessionID, window: ObjectIdentifier(window))
        }
        else {
            pathField.stringValue = location.directoryURL?.path ?? "This Mac"
            pathField.toolTip = "Enter a local folder path. Return opens; Escape cancels."
            addressEditingContext = nil
        }
        pathControl.isHidden = true
        pathField.isHidden = false
        (pathField.superview as? AddressSurfaceView)?.setEditing(true)
        focusLocationField()
    }

    func focusLocationField() {
        view.window?.makeFirstResponder(pathField)
        pathField.selectText(nil)
        if let editor = pathField.currentEditor() as? NSTextView {
            // Keep Select All for replacement while showing the useful tail of
            // a long local, server or virtual archive address.
            editor.scrollRangeToVisible(.init(location: editor.string.utf16.count, length: 0))
        }
    }

    @objc func toggleLocationEditing(_ sender: Any?) {
        if pathField.isHidden { focusLocation(sender) }
        else { cancelLocationEditing() }
    }

    func cancelLocationEditing(restoringFocus: Bool = true) {
        addressEditingContext = nil
        currentArchive?.cancelAddressNavigation()
        addressCompletion.cancel()
        pathField.abortEditing()
        pathField.stringValue = isRemoteLocation ? remoteAddressText ?? "" : location.directoryURL?.path ?? "This Mac"
        if case .archive(let value) = location { pathField.stringValue = value.editablePath }
        pathField.isHidden = true
        pathControl.isHidden = false
        (pathField.superview as? AddressSurfaceView)?.setEditing(false)
        if restoringFocus && isActiveCommandPane { focusBrowserContent() }
    }

    @objc func locationEntered(_ sender: Any?) {
        let text = pathField.stringValue
        if isRemoteLocation { enterRemoteAddress(text, usingEditor: true); return }
        if case .archive(let archive) = location {
            do {
                if let target = try archive.resolvingAddress(text) {
                    enterArchiveAddress(target, text: text); return
                }
            } catch { status.stringValue = "Enter a folder in this archive. ../ cannot go above its root; use Up to leave the archive."; return }
        }
        if (text == "~" || text.hasPrefix("~/")) && BrowsingHome.url == nil {
            status.stringValue = "Home could not be located. Choose your Home folder or enter an absolute path."; return
        }
        if text.caseInsensitiveCompare("This Mac") == .orderedSame {
            navigate(to: .computer)
        } else if let url = try? DirectoryPathInput.resolve(text, home: BrowsingHome.url) {
            navigate(to: .directory(url))
        } else {
            status.stringValue = "Choose a folder-name suggestion with Tab or a click, then Return; or enter a path beginning with / or ~."
            return
        }
        focusBrowserContent()
    }

    private func enterArchiveAddress(_ target: ArchiveLocation, text: String) {
        guard !isBrowserSuspended, isActiveCommandPane, let window = view.window, window.isVisible,
              window.attachedSheet == nil, let owner = currentArchive,
              let editor = pathField.currentEditor(), !pathField.isHidden,
              addressEditingContext == .init(pane: paneID, tab: activeID, visit: sessionID, window: ObjectIdentifier(window)) else {
            status.stringValue = "The source tab changed. Open its address again before navigating."; return
        }
        let context = addressEditingContext
        let accepted = owner.openFolderAddress(target) { [weak self, weak owner, weak editor] state in
            guard let self, let owner, let editor, self.currentArchive === owner, self.isActiveCommandPane,
                  !self.isBrowserSuspended, self.view.window === window, window.attachedSheet == nil,
                  self.addressEditingContext == context, self.pathField.currentEditor() === editor,
                  editor.string.utf8.elementsEqual(text.utf8) else { return }
            guard let state else { self.status.stringValue = "That folder was not found. Check the archive path and try again."; return }
            self.cancelLocationEditing()
            self.navigateArchive(to: target, state: state)
            self.focusBrowserContent()
        }
        if !accepted { status.stringValue = "Finish the current archive task, or Prepare the archive, before opening a folder path." }
    }

    @objc func pathClicked(_ sender: Any?) {
        pathControl.activateClickedPathItem()
    }

    @objc func chooseDirectFilter(_ sender: Any?) { folderFilter.selectScope(0) }
    @objc func chooseFolderSearch(_ sender: Any?) { folderFilter.selectScope(1) }
    @objc func chooseThisMacSearch(_ sender: Any?) { folderFilter.selectScope(2) }
    @objc func showMetadataSearch(_ sender: Any?) { metadataSearch.show() }
    @objc func splitPaneRight(_ sender: Any?) { _ = workspace?.splitActive(at: .trailing) }
    @objc func splitPaneBelow(_ sender: Any?) { _ = workspace?.splitActive(at: .bottom) }
    @objc func closePane(_ sender: Any?) { _ = workspace?.closeActivePane() }
    @objc func focusOtherPane(_ sender: Any?) { workspace?.focusOtherPane() }
    @objc func swapPaneSides(_ sender: Any?) { workspace?.performDividerAction(.swap) }
    @objc func balancePaneSizes(_ sender: Any?) { workspace?.performDividerAction(.balance) }
    @objc func rotatePaneSplit(_ sender: Any?) { workspace?.performDividerAction(.rotate) }
    @objc func toggleLinkedPaneNavigation(_ sender: Any?) { workspace?.performDividerAction(.link) }
    @objc func selectMatchingPaneItem(_ sender: Any?) {
        guard isActiveCommandPane, hasFileCommandFocus else { return }
        workspace?.performDividerAction(.selectMatch)
    }
    @objc func comparePaneGitCheckouts(_ sender: Any?) { workspace?.performDividerAction(.compareGit) }
    @objc func toggleInlinePreview(_ sender: Any?) { workspace?.togglePreview(sender) }
    @objc func toggleSidebar(_ sender: Any?) { workspace?.toggleSidebar() }

    @objc func focusFilter(_ sender: Any?) {
        guard folderFilter.displaysSearch || (!showsComputerVolumes && !metadataSearch.isShowingResults) else { return }
        folderFilter.focus()
    }

    @objc func toggleHidden(_ sender: Any?) { settings.showsHiddenFiles.toggle() }
    @objc func toggleCommandRow(_ sender: Any?) { settings.showsCommandRow.toggle() }

    @objc func changeSort(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        saveViewState()
        guard BrowserColumn.allCases.indices.contains(item.tag) else { return }
        tabs[activeIndex].sort.field = BrowserColumn.allCases[item.tag].sortField
        markFolderViewOverride()
        syncSortIndicators()
        requestOrdering()
    }

    @objc func toggleAscending(_ sender: Any?) {
        saveViewState()
        tabs[activeIndex].sort.ascending.toggle()
        markFolderViewOverride()
        syncSortIndicators()
        requestOrdering()
    }

    @objc func showSettings(_ sender: Any?) {
        if let workspace { workspace.showWorkspaceSettings(); return }
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = BrowserSettingsWindow.make(makeSettingsView())
        window.title = "Traverse Settings"
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func makeSettingsView(initialPage: BrowserSettingsView.Page = .general) -> BrowserSettingsView {
        BrowserSettingsView(
            settings: settings,
            initialPage: initialPage,
            namesOwner: privateNames,
            onReviewRecovery: { [weak self] in self?.showOperationRecovery(nil) },
            onCompactJournal: { [weak self] in self?.compactOperationJournal() },
            copyPreviewAvailability: recoverableFileOperations?.copyPreviewAvailability ?? .qualificationPending,
            onPrepareHistory: { [weak self] in self?.prepareOperationHistoryForReview() },
            onCopyPreviewChange: { [weak self] in self?.changeCopyPreview($0) },
            onManageLaunchProfiles: { [weak self] in self?.workspace?.showLaunchProfiles() },
            onShowSetup: { [weak self] in if let self { TraverseSetupController.shared.show(from: self) } },
            folderAccess: folderAccess, accessDrives: volumes,
            onShowConnections: { [weak self] in self?.showSMBConnections(nil) },
            onAccessChanged: { [weak self] in await self?.refreshRememberedFolderReferences() })
    }

    func handleExplorerShortcut(_ event: NSEvent) -> Bool { routeBrowserShortcut(event) }

    var orderedSelectedURLs: [URL] {
        if isArchiveLocation || isRemoteLocation { return [] }
        if showsComputerVolumes { return volumeBrowser.selectedURLs }
        if usesFileIcons { return iconBrowser.orderedSelectedURLs }
        return table.selectedRowIndexes.compactMap { displayedEntries.indices.contains($0) ? displayedEntries[$0].url : nil }
    }

    func orderedSelectedURLs(upTo limit: Int) -> [URL] {
        guard !isArchiveLocation, !isRemoteLocation else { return [] }
        guard limit > 0 else { return [] }
        if showsComputerVolumes { return Array(volumeBrowser.selectedURLs.prefix(limit)) }
        if usesFileIcons { return iconBrowser.orderedSelectedURLs(upTo: limit) }
        return table.selectedRowIndexes.prefix(limit).compactMap {
            displayedEntries.indices.contains($0) ? displayedEntries[$0].url : nil
        }
    }

    var selectedItemCount: Int {
        if isRemoteLocation || isArchiveLocation { return 0 }
        if showsComputerVolumes { return volumeBrowser.selectedCount }
        return usesFileIcons ? iconBrowser.selectedCount : table.numberOfSelectedRows
    }

    func focusBrowserContent() {
        if showsComputerVolumes { volumeBrowser.focus() } else { view.window?.makeFirstResponder(activeFileView) }
    }

    func cycleBrowserFocus(backward: Bool, startingAt: NSView? = nil) {
        synchronizeTransferClipboard()
        let content: NSView = showsComputerVolumes ? volumeBrowser.collectionView : activeFileView
        let owner = workspace?.operationBrowser ?? self
        let indicator: NSView = settings.operationIndicatorPosition == .statusBar
            ? (workspace?.operationButton ?? footerOperationButton) : owner.navigationOperationButton
        let progress: [NSView] = owner.displayedOperationPresentation == nil || indicator.isHidden ? [] : [indicator]
        let clipboard: [NSView] = transferFeedback != nil && !clipboardStatus.isHiddenOrHasHiddenAncestor
            && clipboardStatus.window === view.window ? [clipboardStatus] : []
        let sidebar: NSView
        if let workspace, workspace.isSidebarCollapsed { sidebar = workspace.sidebarRestoreButton }
        else { sidebar = outline }
        let address: NSView = pathField.isHidden ? pathControl : pathField
        let controls = ([sidebar, address] + (folderFilter.displaysSearch || (!showsComputerVolumes && !metadataSearch.isShowingResults) ? [folderFilter.focusTarget] : []) + [content] + clipboard + progress)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window === view.window }
        guard !controls.isEmpty else { return }
        let responder: NSResponder? = startingAt ?? view.window?.firstResponder
        let current = controls.firstIndex { control in
            responder === control || (responder is NSTextView && (control as? NSControl)?.currentEditor() === responder)
        }
        let step = backward ? controls.count - 1 : 1
        let next = current.map { ($0 + step) % controls.count } ?? (backward ? controls.count - 1 : 0)
        for offset in 0..<controls.count {
            let index = (next + offset * step) % controls.count
            if view.window?.makeFirstResponder(controls[index]) == true { return }
        }
    }

    func cycleTab(backward: Bool) {
        let offset = backward ? tabs.count - 1 : 1
        selectTab(tabs[(activeIndex + offset) % tabs.count].id)
    }
}

extension BrowserViewController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { commandEnabled(item.action) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(compareGitRevisions(_:)) || item.action == #selector(reviewStagedChanges(_:))
            || item.action == #selector(compareGitWorkingFolder(_:)) || item.action == #selector(browseGitWorktrees(_:))
            || item.action == #selector(showGitFolderHistory(_:)) {
            item.isHidden = !gitControls.isAvailable
        }
        if item.action == #selector(showGitFileHistory(_:)) { item.isHidden = !canShowGitFileHistory }
        if item.action == #selector(compareSelectedGitFileRevisions(_:)) || item.action == #selector(compareSelectedGitWorkingFile(_:)) {
            item.isHidden = !canShowGitFileHistory
        }
        if item.action == BrowserCommand.stageGitFile.selector || item.action == BrowserCommand.unstageGitFile.selector {
            item.isHidden = !canShowGitFileHistory
        }
        if item.action == #selector(copyToOtherPane(_:)) {
            // Clear a preceding remote version explanation when this menu is
            // reused locally or with an eligible/connection-specific action.
            item.toolTip = nil
            if isSFTPLocation, let owner = sftpTabs[activeID], owner.session.latest.failure == nil,
               owner.session.latest.directoryRejection == nil {
                item.toolTip = RemoteDownloadPublicationFeature.versionHoldExplanation(featureAvailable: SFTPDownloadFeature.available)
            } else if isSMBLocation, let owner = smbTabs[activeID], owner.session.latest.failure == nil,
                      owner.session.latest.directoryRejection == nil {
                item.toolTip = RemoteDownloadPublicationFeature.versionHoldExplanation(featureAvailable: SMBDownloadFeature.available)
            }
        }
        if item.action == #selector(deleteRemoteFilePermanently(_:)) { item.isHidden = !isRemoteLocation }
        if item.action == #selector(trashSelection(_:)) {
            item.title = trashCommandTitle
        }
        if item.action == #selector(createFolder(_:)) {
            let named = item.representedObject as? String == "named-local-folder"
            item.title = named || isRemoteLocation || isArchiveLocation ? "New Folder…" : "New Folder"
            item.isHidden = named && (isRemoteLocation || isArchiveLocation)
        }
        if item.action == #selector(copyPath(_:)) {
            item.title = isArchiveLocation ? "Copy Path in Archive" : "Copy Path"
        }
        if item.action == #selector(renameSelection(_:)) {
            item.toolTip = sftpTabs[activeID].flatMap { sftpFileActions.renameExplanation(from: $0) }
        }
        if item.action == #selector(toggleSelectedFolderPin(_:)) {
            item.title = selectedFolderURL.map { isPinned($0) ? "Unpin Folder" : "Pin Folder" } ?? "Pin Folder"
        }
        switch item.action {
        case #selector(toggleHidden(_:)): item.state = settings.showsHiddenFiles ? .on : .off
        case #selector(toggleCommandRow(_:)): item.state = settings.showsCommandRow ? .on : .off
        case #selector(toggleInlinePreview(_:)): item.state = workspace?.preview.isEnabled == true ? .on : .off
        case #selector(toggleSidebar(_:)): item.title = workspace?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
        case #selector(toggleLinkedPaneNavigation(_:)):
            item.state = workspace?.folderNavigation.isLinked(workspace?.layout.parent(of: paneID)?.id) == true ? .on : .off
        case #selector(comparePaneGitCheckouts(_:)): item.isHidden = workspace?.canPerformDividerAction(.compareGit) != true
        case #selector(togglePathBar(_:)): item.state = settings.showsPathBar ? .on : .off
        case #selector(toggleAscending(_:)): item.state = tabs[activeIndex].sort.ascending ? .on : .off
        case #selector(changeViewMode(_:)): item.state = item.tag == BrowserViewMode.allCases.firstIndex(of: effectiveViewMode) ? .on : .off
        case #selector(toggleCompactRows(_:)): item.state = settings.rowDensity == .compact ? .on : .off
        case #selector(toggleExtensions(_:)): item.state = settings.showsFileExtensions ? .on : .off
        case #selector(toggleFoldersFirst(_:)): item.state = tabs[activeIndex].sort.foldersFirst ? .on : .off
        case #selector(compareTextFiles(_:)): item.title = textComparisonTitle
        case #selector(saveFolderView(_:)):
            let saved = folderViewPath.flatMap { folderViews.library.record(for: $0) }
            item.title = saved == nil ? "Save View for This Folder" : "Update Saved View for This Folder"
            item.state = saved?.choice == folderViewChoice ? .on : .off
        case #selector(toggleColumn(_:)):
            guard let column = BrowserColumn.toggled(by: item.tag) else { return false }
            item.state = isColumnVisible(column) ? .on : .off
            if column == .name { return false }
        case #selector(changeSort(_:)):
            let fields = BrowserColumn.allCases.map(\.sortField)
            item.state = fields.indices.contains(item.tag) && fields[item.tag] == tabs[activeIndex].sort.field ? .on : .off
        default: break
        }
        return commandEnabled(item.action)
    }

    func commandEnabled(_ action: Selector?, synchronizingClipboard: Bool = true) -> Bool {
        if action == #selector(openTerminalHere(_:)) { return openAndShare.canOpenTerminal }
        if action == #selector(openSelectedFolderInTerminal(_:)) {
            return openAndShare.canOpenTerminal && selectedFolderURL != nil && orderedSelectedURLs.count == 1
        }
        if action == #selector(compareSelectedFiles(_:)) { return openAndShare.canCompare }
        if action == #selector(compareFolders(_:)) { return canCompareFolders }
        if action == #selector(compareTextFiles(_:)) { return canCompareTextFiles }
        if action == #selector(showGitFileHistory(_:)) { return canShowGitFileHistory }
        if action == #selector(compareSelectedGitFileRevisions(_:)) || action == #selector(compareSelectedGitWorkingFile(_:)) {
            return canCompareSelectedGitFile
        }
        if action == BrowserCommand.stageGitFile.selector || action == BrowserCommand.unstageGitFile.selector {
            return canEditSelectedGitIndex
        }
        if action == #selector(browseGitWorktrees(_:)) { return canBrowseGitWorktrees }
        if action == #selector(showGitMenu(_:)) || action == #selector(compareGitRevisions(_:))
            || action == #selector(reviewStagedChanges(_:)) || action == #selector(compareGitWorkingFolder(_:))
            || action == #selector(showGitFolderHistory(_:)) {
            return gitControls.isAvailable && isActiveCommandPane && view.window?.attachedSheet == nil
        }
        if action == #selector(selectByName(_:)) { return nameSelection.canPresent }
        if action == #selector(showKeyboardContextMenu(_:)) {
            return !isBrowserSuspended && keyboardContextTarget != nil && view.window?.attachedSheet == nil
        }
        if action == #selector(pasteFileURLs(_:)), hasScopedItemPasteboardType { return canPasteScopedItem }
        if [#selector(pasteWithOptions(_:)), #selector(moveCopiedFiles(_:)), #selector(pasteIntoSelection(_:))].contains(where: { $0 == action }),
           hasScopedItemPasteboardType { return false }
        if action == #selector(cutFileURLs(_:)), isRemoteLocation { return canCutRemoteSelection }
        if action == #selector(copyFileURLs(_:)), isRemoteLocation { return canCopyRemoteSelection }
        if action == #selector(uploadFileToSMB(_:)) {
            return smbTabs[activeID].map { smbUpload.canRequest(from: $0) } ?? false
        }
        if action == #selector(showSMBUploadOutcomes(_:)) {
            return !isBrowserSuspended && (smbTabs[activeID]?.uploads != nil || smbClosedUploadNotices[activeID] != nil)
        }
        if action == #selector(openSelectedFileInDefaultApp(_:)) { return canOpenSelectedFileInDefaultApp }
        if action == #selector(viewTextInTraverse(_:)) { return ApplicationRemoteTextViews.shared.canOpen(from: self) }
        if action == #selector(reconnectFromConnectionStatus(_:)) {
            guard !isBrowserSuspended, isRemoteLocation, view.window?.attachedSheet == nil else { return false }
            if let bookmark = tabs[activeIndex].connectionBookmark, savedServerLocations.connectingPhase(for: bookmark) != nil { return false }
            if let owner = sftpTabs[activeID] { return !owner.isClosing && owner.session.latest.failure != nil }
            if let owner = smbTabs[activeID] { return !owner.isClosing && owner.session.latest.failure != nil && owner.session.latest.failure != .stopped }
            return true
        }
        if action == #selector(showCurrentConnectionProperties(_:)) { return isRemoteLocation && hasLiveRemoteNavigation && !isBrowserSuspended }
        if let enabled = archiveCommandEnabled(action) { return enabled }
        if isRemoteLocation {
            if [#selector(focusLocation(_:)), #selector(toggleLocationEditing(_:)), #selector(focusFilter(_:)), #selector(selectAllBrowserFiles(_:))].contains(where: { $0 == action }) {
                return hasLiveRemoteNavigation && !isBrowserSuspended
            }
            if action == #selector(showProperties(_:)) { return observedRemoteItem != nil }
            if action == #selector(copyNames(_:)) { return observedRemoteItem?.copyName != nil }
            if action == #selector(copyPath(_:)) { return observedRemoteItem?.copyPath != nil }
        }
        if action == #selector(copyNames(_:)) || action == #selector(copyRelativePaths(_:)) { return canCopyFilenameMetadata }
        if action == #selector(findCommand(_:)) { return !isBrowserSuspended && view.window?.attachedSheet == nil }
        if action == #selector(showBundledNotices(_:)) { return !isBrowserSuspended }
        if action == #selector(showSMBConnections(_:)) { return SMBConnectionFeature.ordinaryEnabled && !isBrowserSuspended && !operationCoordinator.drives.isBusy }
        if action == #selector(showSMBConnectionActivity(_:)) {
            return SMBConnectionFeature.ordinaryEnabled && !isBrowserSuspended && !operationCoordinator.drives.isBusy
        }
        if action == #selector(showSFTPConnectionActivity(_:)) {
            return SFTPConnectionFeature.ordinaryEnabled && !isBrowserSuspended && !operationCoordinator.drives.isBusy
        }
        if action == #selector(disconnectCurrentConnection(_:)) {
            return !isBrowserSuspended && view.window?.attachedSheet == nil
                && (isSFTPLocation && sftpTabs[activeID]?.isClosing == false
                    || isSMBLocation && smbTabs[activeID]?.isClosing == false)
        }
        if action == #selector(disconnectSMBConnection(_:)) { return isSMBLocation && smbTabs[activeID]?.isClosing == false }
        if action == #selector(disconnectSFTPConnection(_:)) { return isSFTPLocation && sftpTabs[activeID]?.isClosing == false }
        if isSFTPLocation {
            if action == #selector(openSelection(_:)) { return sftpTabs[activeID]?.rows.canOpenSelectedItem == true }
            if let owner = sftpTabs[activeID] {
                if action == #selector(pasteFileURLs(_:)) { return sftpDropUpload.canPasteClipboard(to: owner) }
                if action == #selector(createTextFile(_:)) { return sftpNewFile.canRequest(from: owner) }
                if action == #selector(createFolder(_:)) { return sftpFileActions.canRequest(.newFolder, from: owner) }
                if action == #selector(renameSelection(_:)) { return sftpFileActions.canRename(from: owner) }
                if action == #selector(copyServerSelection(_:)) || action == #selector(duplicateSelection(_:)) { return sftpFileActions.canCopy(from: owner) }
                if action == #selector(moveServerSelection(_:)) { return sftpFileActions.canMove(from: owner) }
                if action == #selector(deleteRemoteFilePermanently(_:)) { return sftpFileActions.canDelete(from: owner) }
            }
            if action == #selector(goUp(_:)), case .sftp(let value) = location { return sftpTabs[activeID]?.parent(of: value) != nil }
            if smbRejectsLocalAction(action) { return false }
        }
        if isSMBLocation {
            if action == #selector(openSelection(_:)) { return smbTabs[activeID]?.rows.canOpenSelectedFolder == true }
            if let owner = smbTabs[activeID] {
                if action == #selector(copyServerSelection(_:)) || action == #selector(duplicateSelection(_:)) {
                    return smbFileActions.canCopy(from: owner)
                }
                if action == #selector(moveServerSelection(_:)) {
                    return SMBRemoteActionFeature.movesAvailable && smbFileActions.canRequest(from: owner)
                }
                if action == #selector(renameSelection(_:)) || action == #selector(deleteRemoteFilePermanently(_:)) {
                    return smbFileActions.canRequest(from: owner)
                }
                if action == #selector(createTextFile(_:)) { return smbNewItems.canRequest(.textFile, from: owner) }
                if action == #selector(createFolder(_:)) { return smbNewItems.canRequest(.folder, from: owner) }
            }
            if action == #selector(pasteFileURLs(_:)), let owner = smbTabs[activeID] {
                return smbUpload.canPasteClipboard(to: owner)
            }
            if action == #selector(goUp(_:)), case .smb(let value) = location { return smbTabs[activeID]?.parent(of: value) != nil }
            if smbRejectsLocalAction(action) { return false }
        }
        if synchronizingClipboard { synchronizeTransferClipboard() }
        if ApplicationFileActivity.gate.isClosed {
            return [#selector(showDriveControls(_:)), #selector(showSettings(_:)), #selector(copyPath(_:)),
                    #selector(dismissAppClipboard(_:))].contains(where: { $0 == action })
        }
        switch action {
        case #selector(showDriveManagement(_:)): return DriveManagementFeature.ordinaryEnabled && !isReadOnlyFileSession
        case #selector(showDriveBenchmark(_:)): return DriveBenchmarkFeature.available && !isReadOnlyFileSession
        case #selector(deleteRemoteFilePermanently(_:)), #selector(moveServerSelection(_:)), #selector(copyServerSelection(_:)): return false
        case #selector(duplicateSelection(_:)): return canDuplicateSelection
        case #selector(copyToOtherPane(_:)): return canCopyToOtherPane
        case #selector(moveToOtherPane(_:)): return canTransferToOtherPane
        case #selector(uploadToSFTPPane(_:)): return sftpPaneUpload.canRequest
        case #selector(browseZIP(_:)): return selectedArchiveURL != nil && !(view.window?.firstResponder is NSTextView)
        case #selector(extractArchive(_:)): return canExtractArchive && !(view.window?.firstResponder is NSTextView)
        case #selector(extractArchiveDirect(_:)): return canExtractArchiveDirect && !(view.window?.firstResponder is NSTextView)
        case #selector(createZIP(_:)): return canCreateZIP && !(view.window?.firstResponder is NSTextView)
        case #selector(compressSelection(_:)): return canCompressSelection && !(view.window?.firstResponder is NSTextView)
        case #selector(batchRenameSelection(_:)): return canBatchRename && !(view.window?.firstResponder is NSTextView)
        case #selector(showLaunchProfiles(_:)): return workspace != nil && !isReadOnlyFileSession
        case #selector(switchLaunchProfile(_:)): return workspace?.canOpenLaunchProfile == true && !isReadOnlyFileSession
        case #selector(showFolderViews(_:)): return !isReadOnlyFileSession
        case #selector(saveFolderView(_:)): return folderViewPath != nil && !isBrowserSuspended && !isReadOnlyFileSession && !folderViews.isBusy && !folderViews.isUnavailable
        case #selector(applySavedFolderView(_:)), #selector(forgetFolderView(_:)):
            return folderViewPath.flatMap { folderViews.library.record(for: $0) } != nil && !isBrowserSuspended && !isReadOnlyFileSession && !folderViews.isBusy && !folderViews.isUnavailable
        case #selector(editPrivateNames(_:)): return orderedSelectedURLs.count == 1 && !showsComputerVolumes && !isBrowserSuspended && !isReadOnlyFileSession
        case #selector(showPrivateNames(_:)): return !isReadOnlyFileSession
        case #selector(splitPaneRight(_:)): return workspace?.canSplitActive(at: .trailing) == true
        case #selector(splitPaneBelow(_:)): return workspace?.canSplitActive(at: .bottom) == true
        case #selector(closePane(_:)): return workspace.map { $0.canChangePaneLayout && $0.browsers.count > 1 } ?? false
        case #selector(focusOtherPane(_:)): return hasFileCommandFocus && (workspace.map { $0.browsers.count > 1 } ?? false)
        case #selector(swapPaneSides(_:)): return workspace?.canPerformDividerAction(.swap) == true
        case #selector(balancePaneSizes(_:)): return workspace?.canPerformDividerAction(.balance) == true
        case #selector(rotatePaneSplit(_:)): return workspace?.canPerformDividerAction(.rotate) == true
        case #selector(selectMatchingPaneItem(_:)):
            return isActiveCommandPane && hasFileCommandFocus && workspace?.canPerformDividerAction(.selectMatch) == true
        case #selector(toggleLinkedPaneNavigation(_:)): return workspace?.canPerformDividerAction(.link) == true
        case #selector(comparePaneGitCheckouts(_:)): return workspace?.canPerformDividerAction(.compareGit) == true
        case #selector(nextBrowserControl(_:)), #selector(previousBrowserControl(_:)): return hasFileCommandFocus && !isBrowserSuspended
        case #selector(pinCurrentFolder(_:)): return canPinCurrentFolder
        case #selector(toggleSelectedFolderPin(_:)): return selectedFolderURL != nil && pinsController.canEdit
        case #selector(removeSelectedPin(_:)), #selector(renameSelectedPin(_:)): return canManageSelectedPin
        case #selector(moveSelectedPinUp(_:)): return canMoveSelectedPinUp
        case #selector(moveSelectedPinDown(_:)): return canMoveSelectedPinDown
        case #selector(toggleInlinePreview(_:)): return workspace != nil && !isBrowserSuspended
        case #selector(toggleSidebar(_:)): return workspace?.canToggleSidebar == true
        case #selector(chooseDirectFilter(_:)): return !isBrowserSuspended && !showsComputerVolumes
        case #selector(chooseFolderSearch(_:)): return !isReadOnlyFileSession && !isBrowserSuspended && metadataSearch.canSearchFolder
        case #selector(chooseThisMacSearch(_:)): return !isReadOnlyFileSession && !isBrowserSuspended
        case #selector(showMetadataSearch(_:)): return !isReadOnlyFileSession && !isBrowserSuspended
        case #selector(goBack(_:)): return tabs[activeIndex].canGoBack
        case #selector(newTab(_:)): return canOpenBrowserTab
        case #selector(duplicateCurrentTab(_:)): return canManageBrowserTabs
        case #selector(nextBrowserTab(_:)), #selector(previousBrowserTab(_:)): return canManageBrowserTabs && tabs.count > 1
        case #selector(reopenClosedTab(_:)): return canManageBrowserTabs && !closedTabs.isEmpty
        case #selector(moveCurrentTabLeft(_:)): return canManageBrowserTabs && activeIndex > 0
        case #selector(moveCurrentTabRight(_:)): return canManageBrowserTabs && activeIndex + 1 < tabs.count
        case #selector(goForward(_:)): return tabs[activeIndex].canGoForward
        case #selector(goUp(_:)): return location.parent != nil && !(view.window?.firstResponder is NSTextView)
        case #selector(copyPath(_:)): return selectedItemCount > 0 || location.directoryURL != nil
        case #selector(copyFileURLs(_:)): return selectedItemCount > 0
        case #selector(pasteWithOptions(_:)):
            return canAdmitTransfer && recoverableFileOperations != nil
                && !(view.window?.firstResponder is NSTextView)
                && transferPasteboard.availableType(from: [.fileURL]) != nil
        case #selector(openSelection(_:)): return selectedItemCount == 1 && !(view.window?.firstResponder is NSTextView)
        case #selector(showQuickLook(_:)): return canQuickLook
        case #selector(openWithSelection(_:)): return canOpenWithSelection
        case #selector(editTextInTraverse(_:)): return canEditTextInTraverse
        case #selector(shareSelection(_:)): return canShareSelection
        case #selector(sendViaAirDrop(_:)): return canSendViaAirDrop
        case #selector(newFolderWithSelection(_:)): return canStartSelectionGroup
        case #selector(createTextFile(_:)): return canCreateTextFile
        case #selector(createFolder(_:)): return canModifyCurrentFolder
        case #selector(renameSelection(_:)): return canModifyCurrentFolder && selectedItemCount == 1 && !(view.window?.firstResponder is NSTextView)
        case #selector(cutFileURLs(_:)):
            return canPrepareTransferClipboard && selectedItemCount > 0 && !(view.window?.firstResponder is NSTextView)
        case #selector(trashSelection(_:)):
            return !isArchiveLocation && canTrashCurrentSelection && !(view.window?.firstResponder is NSTextView)
        case #selector(pasteFileURLs(_:)):
            return canAdmitTransfer && transferPasteboard.availableType(from: [.fileURL]) != nil
        case #selector(moveCopiedFiles(_:)):
            return canAdmitTransfer && !(view.window?.firstResponder is NSTextView)
                && transferPasteboard.availableType(from: [.fileURL]) != nil
        case #selector(undoFileOperation(_:)): return canUndoFileOperation
        case #selector(showOperationRecovery(_:)): return !isReadOnlyFileSession && recoverableFileOperations != nil
        case #selector(showOwnedTrash(_:)): return OwnedTrashFeature.browseAvailable && !isReadOnlyFileSession && recoverableFileOperations != nil
        case #selector(showFileOperationDetails(_:)): return (workspace?.operationBrowser ?? self).displayedOperationPresentation != nil
        case #selector(showTransferQueue(_:)): return operationCoordinator.transfers.canInspect
        case #selector(showLastOperationResult(_:)): return canInspectLastOperationResult
        case #selector(continueRemainingTransfer(_:)): return canContinueRemainingTransfer
        case #selector(cancelFileOperation(_:)):
            if let active = operationCoordinator.transfers.state.active { return !active.stopRequested }
            let owner = workspace?.operationBrowser ?? self
            return owner.operationTask != nil && !owner.operationStopRequested
        case #selector(pasteIntoSelection(_:)):
            return canAdmitTransfer && selectedFolderURL != nil && transferPasteboard.availableType(from: [.fileURL]) != nil
        case #selector(openSelectionInNewTab(_:)): return selectedFolderURL != nil
        case #selector(openContainingFolder(_:)):
            return metadataSearch.isShowingResults && orderedSelectedURLs.count == 1
        case #selector(showProperties(_:)), #selector(revealInFinder(_:)):
            return selectedItemCount > 0 || location.directoryURL != nil
        case #selector(focusFilter(_:)): return folderFilter.displaysSearch || (!showsComputerVolumes && !metadataSearch.isShowingResults)
        case #selector(changeSort(_:)), #selector(toggleAscending(_:)): return !showsComputerVolumes
        default: return true
        }
    }
}

extension BrowserViewController: NSTextFieldDelegate, NSSearchFieldDelegate {
    @objc func clearEmptyFolderFilter(_ sender: NSSearchField) {
        if isRemoteLocation {
            guard folderFilter.permitsEmptyFilterAction(sender) else { return }; setRemoteLoadedQuery(""); return
        }
        if isArchiveLocation {
            guard folderFilter.permitsEmptyFilterAction(sender) else { return }
            currentArchive?.setQuery(""); filterField.stringValue = ""; return
        }
        guard folderFilter.permitsEmptyFilterAction(sender), !tabs[activeIndex].filter.isEmpty else { return }
        saveViewState()
        tabs[activeIndex].filter = ""
        folderFilter.synchronize()
        recordBrowserSession()
        requestOrdering()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if !isRemoteLocation, notification.object as? NSTextField === pathField, let editor = pathField.currentEditor() as? NSTextView {
            addressCompletion.beganEditing(editor)
        }
        if notification.object as? NSSearchField === folderFilter.displayedField { folderFilter.beganEditing(notification) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === pathField {
            if isArchiveLocation { currentArchive?.cancelAddressNavigation() }
            else if !isRemoteLocation { addressCompletion.changed() }
            return
        }
        if isRemoteLocation, notification.object as? NSSearchField === filterField {
            guard folderFilter.permitsTextChange(notification) else { return }
            setRemoteLoadedQuery(filterField.stringValue); return
        }
        if isArchiveLocation, notification.object as? NSSearchField === filterField {
            guard folderFilter.permitsTextChange(notification) else { return }
            currentArchive?.setQuery(filterField.stringValue); return
        }
        if folderFilter.displaysSearch, notification.object as? NSSearchField === folderFilter.displayedField {
            folderFilter.synchronize()
            if metadataSearch.queryField.stringValue.isEmpty { consumePendingDirectoryRefresh() }
            return // Draft text only; never auto-submit a broader search.
        }
        guard !metadataSearch.isShowingResults, notification.object as? NSSearchField === filterField,
              folderFilter.permitsTextChange(notification) else { return }
        guard tabs[activeIndex].filter != filterField.stringValue else { folderFilter.synchronize(); return }
        saveViewState()
        tabs[activeIndex].filter = filterField.stringValue
        folderFilter.synchronize()
        recordBrowserSession()
        requestOrdering()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === pathField { addressCompletion.endedEditing() }
        if notification.object as? NSSearchField === folderFilter.displayedField { folderFilter.endedEditing(notification) }
        recordBrowserSession()
        consumePendingDirectoryRefresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField && addressCompletion.handle(commandSelector, editor: textView) { return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === pathField {
                cancelLocationEditing()
                return true
            } else if control === filterField {
                filterField.stringValue = ""
                if isRemoteLocation {
                    setRemoteLoadedQuery("")
                    folderFilter.dismiss()
                    focusBrowserContent()
                    return true
                }
                if isArchiveLocation { currentArchive?.setQuery(""); folderFilter.dismiss(); return true }
                tabs[activeIndex].filter = ""
                folderFilter.synchronize()
                folderFilter.dismiss()
                recordBrowserSession()
                requestOrdering()
            } else if control === metadataSearch.queryField {
                metadataSearch.cancel()
                folderFilter.dismiss()
            }
            focusBrowserContent()
            return true
        }
        return false
    }
}
