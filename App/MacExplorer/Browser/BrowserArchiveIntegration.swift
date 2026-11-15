import AppKit
import ExplorerCore

enum InlineArchiveFeature {
    static var available: Bool {
        if GeneratedSandboxReview.admitted { return true }
        if AppFeatureAvailability.allows(.archiveTabs) { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--check-inline-archives")
            || ProcessInfo.processInfo.arguments.contains("--check-tar-archive") && ProcessInfo.processInfo.arguments.contains("--compressed-tar")
            || ProcessInfo.processInfo.arguments.contains("--check-inline-archive-motion")
            || ProcessInfo.processInfo.arguments.contains("--check-tar-preview-native")
            || ProcessInfo.processInfo.arguments.contains("--check-archive-open-routing")
            || ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            || ProcessInfo.processInfo.arguments.contains("--check-editor-preferences")
        #else
        return false
        #endif
    }
}

@MainActor
extension BrowserViewController {
    var currentArchive: ArchiveTabController? { isArchiveLocation ? archiveTabs[activeID] : nil }

    func navigateArchive(to value: ArchiveLocation, state: ArchiveBrowseState) {
        guard !isBrowserSuspended, (try? state.validate(format: value.format)) != nil else { return }
        saveViewState()
        tabs[activeIndex].navigate(to: .archive(value))
        tabs[activeIndex].archiveState = state
        recordsNextExplicitVisit = false
        loadLocation(directoryDirection: 1)
    }

    func captureArchiveViewState() {
        guard isArchiveLocation else { return }
        if !isInstallingLocation, let currentArchive, !currentArchive.isClosed { tabs[activeIndex].archiveState = currentArchive.snapshot() }
        tabs[activeIndex].state = NavigationState()
    }

    func loadArchiveLocation(_ value: ArchiveLocation) {
        isLoading = false; folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
        restoringScroll = false; overlay.isHidden = true
        guard InlineArchiveFeature.available else {
            status.stringValue = "Archive tabs are not available in this edition yet. Open the archive from its containing folder."
            return
        }
        if let owner = archiveTabs[activeID], owner.isClosed || owner.source != value.source || owner.format != value.format {
            archiveTabs.removeValue(forKey: activeID)
            ArchiveTabCatalogPool.shared.retire(owner)
        }
        let state = tabs[activeIndex].archiveState ?? ArchiveBrowseState()
        let owner = archiveTabs[activeID] ?? ArchiveTabController(tabID: activeID, location: value, state: state, browser: self)
        archiveTabs[activeID] = owner
        archiveHost.subviews.filter { $0 !== owner.view }.forEach { $0.removeFromSuperview() }
        if owner.view.superview !== archiveHost { pin(owner.view, inside: archiveHost) }
        owner.present(value, state: state, from: self)
        updateFilePresentationVisibility(); renderCurrentArchiveStatus()
    }

    func renderCurrentArchiveStatus() {
        guard isArchiveLocation else { return }
        overlay.isHidden = true
        if let owner = currentArchive {
            archiveHost.layoutSubtreeIfNeeded()
            owner.view.layoutSubtreeIfNeeded()
            // The reader may not have installed its table yet. Reserve the
            // heading region immediately, before any old rows can paint across
            // the new archive's tools or its future native column header.
            canvasTransition?.restrictForeground(to: owner.presentingPreparation ? owner.foregroundContainer : owner.scroll?.contentView ?? owner.foregroundContainer,
                excludingHeader: owner.presentingPreparation ? nil : owner.table?.headerView,
                topInset: owner.scroll == nil ? InterfaceMetrics.points(28) : 0)
            canvasTransition?.stageIncomingForeground()
            if owner.busy { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
            status.stringValue = owner.format.rawValue.uppercased() + " archive" + (owner.isReadOnly ? " · Read-only" : "")
                + (owner.selectedCount > 0 ? " · \(owner.selectedCount) selected" : "")
            if filterField.currentEditor() == nil, filterField.stringValue != owner.query { filterField.stringValue = owner.query }
            if owner.current || owner.presentingPreparation { canvasTransition?.reveal() }
        } else { loadingIndicator.stopAnimation(nil); status.stringValue = "Opening archive…" }
        folderFilter.synchronize()
        validateNavigationButtons()
    }

    func updateArchiveBreadcrumbs() -> Bool {
        guard case .archive(let value) = location else { return false }
        var items: [NSPathControlItem] = []
        let parent = NSPathControlItem(); parent.title = value.source.deletingLastPathComponent().lastPathComponent
        parent.image = breadcrumbSymbol("folder", "Containing folder")
        items.append(parent); breadcrumbLocations = [.directory(value.source.deletingLastPathComponent())]
        for index in 0...value.folderPath.count {
            let item = NSPathControlItem()
            item.title = index == 0 ? value.source.lastPathComponent : value.folderPath[index - 1]
            if index == 0 { item.image = breadcrumbSymbol("archivebox", "Archive") }
            if let next = try? ArchiveLocation(source: value.source, format: value.format, folderPath: Array(value.folderPath.prefix(index))) {
                items.append(item); breadcrumbLocations.append(.archive(next))
            }
        }
        pathControl.setBreadcrumbs(items: items, locations: breadcrumbLocations)
        pathControl.toolTip = value.source.lastPathComponent + (value.folderPath.isEmpty ? "" : " › " + value.folderPath.joined(separator: " › "))
            + "\nBrowse folders inside this archive. Edit location opens its containing folder path."
        return true
    }

    var canPasteLocalCopiesIntoArchive: Bool {
        currentArchive?.canAddCopiedFiles == true && canPasteLocalCopies
    }

    func canCaptureArchiveClipboard(_ operation: TransferClipboardFeedback.Intent) -> Bool {
        !GeneratedSandboxReview.publicationOnlyReviewAdmitted
            && hasFileCommandFocus && canRunExclusiveFileCommand && view.window?.attachedSheet == nil
            && !(view.window?.firstResponder is NSTextView) && currentArchive?.canCaptureClipboardMembers(operation) == true
    }

    func captureArchiveClipboard(_ operation: TransferClipboardFeedback.Intent) {
        guard canCaptureArchiveClipboard(operation), let owner = currentArchive else { return }
        let state = clipboardState, board = transferPasteboard, revision = state.revision
        let changeCount = board.changeCount
        owner.captureClipboardMembers(operation) { [weak self, weak owner] intent in
            guard let self, let owner, currentArchive === owner, hasFileCommandFocus,
                  !(view.window?.firstResponder is NSTextView), view.window?.attachedSheet == nil,
                  clipboardState === state, state.revision == revision,
                  transferPasteboard === board, board.changeCount == changeCount else { return }
            publishScopedClipboard(intent)
        }
    }

    func pasteLocalCopiesIntoArchive() {
        guard canPasteLocalCopiesIntoArchive, let owner = currentArchive else { return }
        let state = clipboardState, board = transferPasteboard, revision = state.revision
        let tab = activeID, visit = sessionID
        guard let capture = state.readFiles(allowOwnedCopy: false), (1...511).contains(capture.urls.count),
              capture.urls.allSatisfy(\.isFileURL), capture.isCurrent(on: board) else {
            status.stringValue = "Copy up to 511 local files or folders to paste into this archive."
            return
        }
        let input = ArchiveAdditionInput(urls: capture.urls, isCurrent: { [weak self, weak owner] in
            guard capture.isCurrent(on: board), let self, let owner, currentArchive === owner, !isBrowserSuspended,
                  activeID == tab, sessionID == visit, clipboardState === state, transferPasteboard === board,
                  state.revision == revision, pendingCut == nil, cutPreparationTask == nil else { return false }
            return true
        })
        _ = owner.addCopiedFiles(input)
    }

    /// Archive member IDs must never fall through to the previous local table.
    /// Global history/recovery/navigation actions retain their ordinary owners.
    func archiveCommandEnabled(_ action: Selector?) -> Bool? {
        guard isArchiveLocation else { return nil }
        switch action {
        case #selector(openSelection(_:)): return currentArchive?.canOpen == true
        case #selector(renameSelection(_:)): return currentArchive?.canRenameInCopy == true
        case #selector(duplicateSelection(_:)): return canDuplicateSelection
        case #selector(showProperties(_:)), #selector(copyPath(_:)), #selector(copyNames(_:)):
            return observedArchiveMember != nil
        case #selector(createFolder(_:)): return currentArchive?.canCreateFolder == true
        case #selector(newFolderWithSelection(_:)): return currentArchive?.canGroupSelection == true
        case #selector(createTextFile(_:)): return currentArchive?.canCreateFile == true
        case #selector(cutFileURLs(_:)): return canCaptureArchiveClipboard(.move)
        case #selector(copyFileURLs(_:)): return canCaptureArchiveClipboard(.copy)
        case #selector(pasteFileURLs(_:)): return canPasteLocalCopiesIntoArchive
        case #selector(trashSelection(_:)): return canTrashCurrentSelection
        case #selector(focusFilter(_:)), #selector(chooseDirectFilter(_:)), #selector(showMetadataSearch(_:)):
            return !isBrowserSuspended
        case #selector(copyRelativePaths(_:)),
             #selector(moveCopiedFiles(_:)), #selector(pasteWithOptions(_:)), #selector(pasteIntoSelection(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(uploadToSFTPPane(_:)), #selector(openWithSelection(_:)), #selector(shareSelection(_:)), #selector(sendViaAirDrop(_:)),
             #selector(showQuickLook(_:)), #selector(revealInFinder(_:)),
             #selector(editPrivateNames(_:)), #selector(openSelectionInNewTab(_:)), #selector(openContainingFolder(_:)),
             #selector(browseZIP(_:)), #selector(extractArchive(_:)), #selector(extractArchiveDirect(_:)),
             #selector(createZIP(_:)), #selector(compressSelection(_:)), #selector(batchRenameSelection(_:)),
             #selector(changeViewMode(_:)), #selector(changeSort(_:)), #selector(toggleAscending(_:)),
             #selector(toggleFoldersFirst(_:)), #selector(toggleColumn(_:)), #selector(saveFolderView(_:)),
             #selector(applySavedFolderView(_:)), #selector(forgetFolderView(_:)),
             #selector(chooseFolderSearch(_:)), #selector(chooseThisMacSearch(_:)):
            return false
        default: return nil
        }
    }

    func retireArchiveTab(_ id: UUID) {
        guard let owner = archiveTabs.removeValue(forKey: id) else { return }
        ArchiveTabCatalogPool.shared.retire(owner)
    }
}
