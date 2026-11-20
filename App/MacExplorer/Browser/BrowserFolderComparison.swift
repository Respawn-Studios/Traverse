import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor extension BrowserViewController {
    private enum ComparisonChoice: Equatable {
        case selection(URL, URL)
        case otherPane(URL, [LocalPaneDestination])
    }

    var canCompareFolders: Bool { folderComparisonChoice != nil }

    private var localComparisonDirectory: URL? {
        guard isViewLoaded, view.window?.attachedSheet == nil, !isBrowserSuspended, !isReadOnlyFileSession,
              !isLoading, !isOfflineCurrentFolder, !metadataSearch.isShowingResults,
              let current = location.directoryURL, current.isFileURL else { return nil }
        return current
    }

    private var folderComparisonChoice: ComparisonChoice? {
        guard let workspace, !workspace.isClosing, isActiveCommandPane, let current = localComparisonDirectory else { return nil }
        if selectedItemCount == 2 {
            let folders = orderedSelectedURLs(upTo: 2)
            guard folders.count == 2, folders.allSatisfy({ url in
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
                return displayedEntries[row].kind == .directory
            }) else { return nil }
            return .selection(folders[0], folders[1])
        }

        let left: URL
        if selectedItemCount == 0 { left = current }
        else if let folder = selectedFolderURL { left = folder }
        else { return nil }
        let destinations = LocalPaneDestination.available(from: self, excluding: left, for: .comparison)
        return destinations.isEmpty ? nil : .otherPane(left, destinations)
    }

    @objc func compareFolders(_ sender: Any?) {
        guard let choice = folderComparisonChoice else { return }
        let left: URL, right: URL
        let rightAccess: FolderAccessController
        switch choice {
        case .selection(let first, let second):
            (left, right) = (first, second)
            rightAccess = folderAccess
        case .otherPane(let first, let destinations):
            let tab = activeID, visit = sessionID
            guard let selected = LocalPaneDestination.choose(destinations, from: self, in: view,
                title: "Compare with Other Pane", for: .comparison),
                activeID == tab, sessionID == visit, folderComparisonChoice == choice,
                let peer = selected.currentBrowser(from: self, excluding: first, for: .comparison) else { return }
            (left, right) = (first, selected.directory)
            rightAccess = peer.folderAccess
        }
        presentFolderComparison(left, right, rightAccess: rightAccess)
    }

    private func currentComparisonPair(with peer: BrowserViewController) -> (URL, URL)? {
        guard let left = localComparisonDirectory,
              let right = LocalPaneDestination.available(from: self, excluding: left, for: .comparison)
                .first(where: { $0.pane == peer.paneID })?.directory else { return nil }
        return (left, right)
    }

    func canCompareCurrentFolders(with peer: BrowserViewController) -> Bool { currentComparisonPair(with: peer) != nil }

    @discardableResult func compareCurrentFolders(with peer: BrowserViewController) -> Bool {
        guard let (left, right) = currentComparisonPair(with: peer) else { return false }
        presentFolderComparison(left, right, rightAccess: peer.folderAccess)
        return true
    }

    private func presentFolderComparison(_ left: URL, _ right: URL, rightAccess: FolderAccessController) {
        guard let workspace, !workspace.isClosing, let parent = view.window else { return }

        if let existing = workspace.folderComparisonWindow {
            let samePair = existing.session.left == left && existing.session.right == right
            if existing.session.isReading || samePair {
                if !samePair {
                    existing.session.reportOtherPairBusy()
                    status.stringValue = FolderComparisonSession.otherPairBusyMessage
                }
                if parent.isVisible { existing.present() }
                return
            }
            existing.close()
        }

        let leftAccess = folderAccess
        @MainActor func access(on side: FolderComparisonFailure.Side) -> FolderAccessController {
            side == .left ? leftAccess : rightAccess
        }
        @MainActor func retainPair() async throws -> FileAccessLifetimes {
            let leftPreparation = leftAccess.prepareAccess(to: [left])
            let rightPreparation = rightAccess.prepareAccess(to: [right])
            let first = await leftAccess.acquireAccess(to: left)
            try Task.checkCancellation()
            let second = await rightAccess.acquireAccess(to: right)
            try Task.checkCancellation()
            guard leftAccess.isCurrent(leftPreparation), rightAccess.isCurrent(rightPreparation) else {
                throw FolderComparisonFailure.changed
            }
            if FolderAccessController.requiresAnalysisSelection {
                guard first != nil else { throw FolderComparisonFailure.unavailable(.left) }
                guard second != nil else { throw FolderComparisonFailure.unavailable(.right) }
            }
            return FileAccessLifetimes(leases: [first, second].compactMap { $0 })
        }
        let transfers = operationCoordinator.transfers
        let session = FolderComparisonSession(left: left, right: right, includingHidden: settings.showsHiddenFiles,
                                              transfers: transfers) { [fileSystem] includingHidden, checkingContents in
            let lifetime = try await retainPair()
            return try await fileSystem.compareFolders(left: left, right: right, includingHidden: includingHidden,
                checkingContents: checkingContents, retaining: lifetime)
        } submitCopy: { [weak self, weak workspace] selected in
            guard let self, let workspace, self.workspace === workspace, !workspace.isClosing,
                  let engine = recoverableFileOperations else { throw FileOperationFailure.unavailable }
            let lifetime = try await retainPair()
            try Task.checkCancellation()
            guard self.workspace === workspace, !workspace.isClosing, recoverableFileOperations === engine,
                  let job = transfers.enqueue(sources: selected.sources, destination: selected.destinationDirectory,
                    move: false, title: "Copy from Folder Comparison", origin: self, engine: engine,
                    observation: selected.observation, retaining: lifetime, metadataPolicy: .strict,
                    requireVacantDestination: true) else { throw FileOperationFailure.unavailable }
            return job
        } prepareEditor: { [fileSystem] selection, side in
            let access = access(on: side)
            let preparation = access.prepareAccess(to: [selection.url])
            let lease = await access.acquireAccess(to: selection.url)
            try Task.checkCancellation()
            if FolderAccessController.requiresAnalysisSelection, lease == nil { throw FolderComparisonFailure.unavailable(side) }
            guard access.isCurrent(preparation) else { throw FolderComparisonFailure.changed }
            let checked = try await fileSystem.prepareFolderComparisonEditor(selection, retaining: lease)
            try Task.checkCancellation()
            guard access.isCurrent(preparation) else { throw FolderComparisonFailure.changed }
            return checked
        }
        let comparison = FolderComparisonWindow(session: session, parent: parent, settings: settings) {
            [weak workspace, fileSystem, settings] review, window in
            @MainActor func entry(_ selection: FolderComparisonReport.TextSelection) -> EditorComparisonWindow.Source {
                let name = selection.relativePath.split(separator: "/").last.map(String.init) ?? selection.relativePath
                let language = TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: name) ?? "")
                let labels = EditorComparisonWindow.Labels(title: "Folder Text Diff", source: selection.relativePath,
                    left: left.lastPathComponent + (selection.hasLeftFile ? " · " + name : " · Absent"),
                    right: right.lastPathComponent + (selection.hasRightFile ? " · " + name : " · Absent"),
                    detail: "This compares the files from the folder report. If they change, refresh the report to review the new versions.",
                    refresh: "Refresh")
                return .init(labels: labels) {
                    let documents: TextComparisonDocuments
                    do {
                        let lifetime = try await retainPair()
                        documents = try await fileSystem.readFolderComparisonText(selection, retaining: lifetime)
                    } catch let failure as TextComparisonReadFailure {
                        let message = failure == .changed
                            ? "This row changed since the folders were compared. Refresh the folder comparison to review it again."
                            : failure.userMessage
                        throw EditorComparisonLoadFailure.unavailable(message)
                    } catch let failure as LocalStorageError {
                        throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
                    }
                    return .init(documents: documents, leftLanguage: language, rightLanguage: language)
                }
            }
            let initial = entry(review.sources[review.index])
            let files = EditorComparisonWindow.FileList(count: review.sources.count, initialIndex: review.index,
                excludedCount: review.excluded, startsWithSearch: review.searching) { entry(review.sources[$0]) }
            workspace?.presentTextComparison(relativeTo: window, settings: settings, labels: initial.labels,
                files: files, capture: initial.read)
        } onOpenEditor: { [weak self, weak workspace, weak session] selection, side, window in
            guard let self, let workspace, let session, self.workspace === workspace, !workspace.isClosing,
                  workspace.folderComparisonWindow?.session === session else { return }
            ApplicationLocalTextEditors.shared.open(selection, from: self, in: window, access: access(on: side)) {
                [weak session] message in session?.reportEditor(message)
            }
        }
        workspace.folderComparisonWindow = comparison
        comparison.didClose = { [weak workspace, weak comparison] in
            guard workspace?.folderComparisonWindow === comparison else { return }
            workspace?.folderComparisonWindow = nil
        }
        if parent.isVisible { comparison.present() }
        session.refresh()
    }
}
