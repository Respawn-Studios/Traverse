import AppKit
import Combine

@MainActor
extension BrowserViewController {
    func connectDisplayPreferences() {
        settings.$showsTerminalButton.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateNavigationButtons() }
        }.store(in: &subscriptions)
        settings.$showsGitControls.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.gitControls.update() }
        }.store(in: &subscriptions)
        settings.$showsGitFileBadges.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.gitControls.badgePreferenceChanged() }
        }.store(in: &subscriptions)
        settings.$interfaceSize.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canvasTransition?.finish()
                InterfacePresentation.shared.apply(in: self.view)
                InterfaceMetrics.setRowHeight(self.outline, base: 27)
                self.outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.outline.numberOfRows))
                self.outline.reloadData()
                self.tabStrip.needsLayout = true
                self.iconBrowser.needsLayout = true
                self.volumeBrowser.needsLayout = true
                self.applyDisplayPreferences()
            }
        }.store(in: &subscriptions)
        settings.$motion.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.tabStrip.motionEnabled = value.allows(.tabStrip)
            self.tabStrip.motionMode = value.mode
            self.volumeBrowser.motion = value
            self.footerOperationButton.motion = value; self.navigationOperationButton.motion = value
            self.workspace?.operationButton.motion = value
            (self.detailsHeader as? FileTableHeaderView)?.motionEnabled = value.allows(.sortIndicators)
            (self.table.headerView as? FileTableHeaderView)?.motionEnabled = value.allows(.sortIndicators)
            (self.detailsHeader as? FileTableHeaderView)?.motionMode = value.mode
            (self.table.headerView as? FileTableHeaderView)?.motionMode = value.mode
            for owner in self.smbTabs.values { owner.rows.configure(glass: self.contentSurface?.isGlassEnabled == true, motion: value.allows(.sortIndicators), mode: value.mode) }
            for owner in self.sftpTabs.values { owner.rows.configure(glass: self.contentSurface?.isGlassEnabled == true, motion: value.allows(.sortIndicators), mode: value.mode) }
            self.canvasTransition?.finish()
            self.workspace?.applyMotionPreferences(value)
        }.store(in: &subscriptions)
        settings.$privateNamesAddressSuggestions.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.addressCompletion.cancel() }
        }.store(in: &subscriptions)
        settings.$privateNamesSources.removeDuplicates().dropFirst().sink { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !self.metadataSearch.isShowingResults else { return }
                self.metadataSearch.sources = value
            }
        }.store(in: &subscriptions)
        Publishers.Merge(settings.$operationIndicatorPosition.map { _ in () }, settings.$showsDockProgress.map { _ in () })
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.updateOperationProgressControls() }
            }.store(in: &subscriptions)
        operationCoordinator.$activeOwner.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateNavigationButtons(); self?.updateOperationProgressControls() }
        }.store(in: &subscriptions)
        operationCoordinator.$preparationOwner.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateNavigationButtons(); self?.updateOperationProgressControls() }
        }.store(in: &subscriptions)
        operationCoordinator.transfers.$revision.sink { [weak self] _ in
            // A workspace owns its queue presentation. A standalone browser
            // retains the existing local path without scheduling hidden peers.
            guard let self, self.workspace == nil else { return }
            #if DEBUG
            self.queueRevisionCallbacksPendingForVerification += 1
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                defer { self.queueRevisionCallbacksPendingForVerification -= 1 }
                #endif
                guard self.workspace == nil, !self.isBrowserSuspended else { return }
                self.updateOperationProgressControls()
                self.validateNavigationButtons()
                self.consumePendingDirectoryRefresh()
            }
        }.store(in: &subscriptions)
        settings.$appearance.removeDuplicates().sink { value in
            BrowserAppearanceController.apply(value)
        }.store(in: &subscriptions)
        let materials = [
            settings.$navigationStyle.map { _ in () }.eraseToAnyPublisher(),
            settings.$glassNavigation.map { _ in () }.eraseToAnyPublisher(),
            settings.$glassSidebar.map { _ in () }.eraseToAnyPublisher(),
            settings.$glassStatusBar.map { _ in () }.eraseToAnyPublisher(),
            settings.$glassFileContent.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(materials).sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let navigation = self.settings.navigationStyle == .glass && self.settings.glassNavigation
                self.navigationSurface?.isGlassEnabled = navigation
                self.addressLayout?.bottomSurface.isGlassEnabled = navigation
                self.tabStrip.isGlassEnabled = navigation
                (self.pathField.superview as? AddressSurfaceView)?.isGlassEnabled = navigation
                self.pathContainer.drawsSolidBackground = false
                self.tabStrip.drawsSolidBackground = false
                self.updateMaterialSurfaces()
            }
        }.store(in: &subscriptions)
        settings.$restoresSession.removeDuplicates().dropFirst().sink { [weak self] enabled in
            Task { @MainActor [weak self] in self?.sessionRestorePreferenceChanged(enabled) }
        }.store(in: &subscriptions)
        settings.$autoRefreshFolders.removeDuplicates().dropFirst().sink { [weak self] enabled in
            Task { @MainActor [weak self] in self?.updateDirectoryObservationPreference(enabled) }
        }.store(in: &subscriptions)
        settings.$viewMode.removeDuplicates().dropFirst().sink { [weak self] mode in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveCommandPane else { return }
                self.paneViewMode = mode
                self.applyDisplayPreferences()
                self.recordBrowserSession()
            }
        }.store(in: &subscriptions)
        let updates = [
            settings.$viewMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$rowDensity.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsFileExtensions.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsFileThumbnails.map { _ in () }.eraseToAnyPublisher(),
            settings.$editorPreferences.removeDuplicates(by: {
                $0.openingIndicator == $1.openingIndicator && $0.openingRules == $1.openingRules
            }).map { _ in () }.eraseToAnyPublisher(),
            settings.$opensArchivesInTraverse.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$showsModifiedColumn.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsKindColumn.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsSizeColumn.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsCreatedColumn.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsAccessedColumn.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsExtensionColumn.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(updates.map { $0.dropFirst().eraseToAnyPublisher() }).sink { [weak self] in
            // @Published emits before assigning the setting.
            Task { @MainActor [weak self] in self?.applyDisplayPreferences() }
        }.store(in: &subscriptions)
        settings.$foldersFirst.removeDuplicates().dropFirst().sink { [weak self] value in
            guard let self, !self.isArchiveLocation, self.tabs[self.activeIndex].presentationMode == nil else { return }
            self.tabs[self.activeIndex].sort.foldersFirst = value
            self.requestOrdering()
        }.store(in: &subscriptions)
        applyDisplayPreferences()
    }

    func applyDisplayPreferences() {
        updateFileViewControl()
        for owner in sftpTabs.values { owner.rows.refreshOpeningPresentation() }
        if isArchiveLocation { currentArchive?.render(); updateFilePresentationVisibility(); return }
        let selection = selectedURLs
        let offset = currentScrollOffset
        let oldView = activeFileView
        let responder = view.window?.firstResponder as? NSView
        let ownedFocus = responder === oldView || responder?.isDescendant(of: oldView) == true
        let modeChanged = presentedFileViewMode != effectiveViewMode
        let leavingIcons = modeChanged && usesFileIcons
        if modeChanged {
            quickLook.endSession()
            presentedFileViewMode = effectiveViewMode
            filePresentationID = UUID()
            openAndShare.selectionDidChange()
        }
        if detailsHeader == nil {
            detailsHeader = table.headerView ?? NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 1000, height: 28))
        }
        table.headerView = effectiveViewMode == .details ? detailsHeader : nil
        // One sizing owner fits the visible set without turning these
        // programmatic changes into native header-resize preferences.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in table.tableColumns {
            let visible = BrowserColumn(rawValue: column.identifier.rawValue).map(isColumnVisible) ?? true
            if ["searchParent", "searchReason"].contains(column.identifier.rawValue) { column.isHidden = !metadataSearch.isShowingResults }
            else { column.isHidden = column.identifier.rawValue != "name" && (effectiveViewMode == .list || !visible) }
        }
        table.columnSizing.fit(table)
        table.tile()
        InterfaceMetrics.setRowHeight(table, base: settings.rowDensity.rowHeight)
        if let header = detailsHeader {
            var frame = header.frame; frame.size.height = InterfaceMetrics.points(28); header.frame = frame
        }
        updateFilePresentationVisibility()
        let restoredOffset = !restoringScroll && !showsComputerVolumes ? offset : nil
        if modeChanged { renderFilePresentation(selection: selection, scrollOffset: restoredOffset) }
        else { refreshFilePresentation(selection: selection, scrollOffset: restoredOffset) }
        if leavingIcons {
            // A hidden grid must not retain a previous large folder's entry
            // and index snapshots after the table becomes authoritative.
            iconBrowser.update(OrderedRows(entries: [], rowsByURL: [:]), selected: [], cut: [],
                               showsExtensions: settings.showsFileExtensions)
        }
        if modeChanged, !showsComputerVolumes {
            if let selected = orderedSelectedURLs.first { revealFile(selected) }
            if ownedFocus { focusBrowserContent() }
        }
        dragDrop.selectionDidChange()
        refreshStatus()
    }

    func setPaneViewMode(_ mode: BrowserViewMode) {
        markFolderViewOverride(mode: mode)
        if workspace != nil { paneViewMode = mode; applyDisplayPreferences(); recordBrowserSession() }
        else { settings.viewMode = mode }
    }

    @objc func changeViewMode(_ sender: NSMenuItem) {
        guard BrowserViewMode.allCases.indices.contains(sender.tag) else { return }
        setPaneViewMode(BrowserViewMode.allCases[sender.tag])
    }
    @objc func changeViewFromControl(_ sender: NSSegmentedControl) {
        guard BrowserViewMode.allCases.indices.contains(sender.selectedSegment) else { return }
        setPaneViewMode(BrowserViewMode.allCases[sender.selectedSegment])
    }
    @objc func toggleCompactRows(_ sender: Any?) {
        settings.rowDensity = settings.rowDensity == .compact ? .comfortable : .compact
    }
    @objc func toggleExtensions(_ sender: Any?) { settings.showsFileExtensions.toggle() }
    @objc func toggleFoldersFirst(_ sender: Any?) {
        tabs[activeIndex].sort.foldersFirst.toggle(); markFolderViewOverride(); requestOrdering(); recordBrowserSession()
    }
    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let column = BrowserColumn.toggled(by: sender.tag) else { return }
        switch column {
        case .name: break
        case .modified: settings.showsModifiedColumn.toggle()
        case .kind: settings.showsKindColumn.toggle()
        case .size: settings.showsSizeColumn.toggle()
        case .created: settings.showsCreatedColumn.toggle()
        case .accessed: settings.showsAccessedColumn.toggle()
        case .extension: settings.showsExtensionColumn.toggle()
        }
    }

    func isColumnVisible(_ column: BrowserColumn) -> Bool {
        switch column {
        case .name: true
        case .modified: settings.showsModifiedColumn
        case .kind: settings.showsKindColumn
        case .size: settings.showsSizeColumn
        case .created: settings.showsCreatedColumn
        case .accessed: settings.showsAccessedColumn
        case .extension: settings.showsExtensionColumn
        }
    }
}
