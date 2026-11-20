import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor extension BrowserViewController {
    private struct TextComparisonPeer {
        let destination: LocalPaneDestination
        let url: URL
    }

    var textComparisonTitle: String {
        !isArchiveLocation && selectedItemCount == 1 ? "Compare Text with Other Pane…" : "Compare Text Files…"
    }

    var canCompareTextFiles: Bool {
        if isArchiveLocation {
            return hasFileCommandFocus && !isBrowserSuspended && view.window?.attachedSheet == nil
                && currentArchive?.canCompareSelectedText == true
        }
        return comparisonFilePair != nil || acrossPaneTextSelection != nil
    }

    private var comparisonSingleFile: LocalPaneFileSelection? {
        guard !isLoading, selectedItemCount == 1, let directory = location.directoryURL, directory.isFileURL,
              let url = orderedSelectedURLs(upTo: 1).first else { return nil }
        let selection = LocalPaneFileSelection(browser: self, url: url, directory: directory)
        return selection.isCurrent ? selection : nil
    }

    private var acrossPaneTextSelection: (source: LocalPaneFileSelection, peers: [TextComparisonPeer])? {
        guard isViewLoaded, hasFileCommandFocus, isActiveCommandPane, view.window?.attachedSheet == nil,
              let source = comparisonSingleFile else { return nil }
        let peers = LocalPaneDestination.available(from: self, for: .comparison).compactMap { destination -> TextComparisonPeer? in
            guard let url = workspace?.browsers[destination.pane]?.textComparisonTarget(for: source.url),
                  url.standardizedFileURL != source.url.standardizedFileURL else { return nil }
            return .init(destination: destination, url: url)
        }
        return peers.isEmpty ? nil : (source, peers)
    }

    private func textComparisonTarget(for source: URL) -> URL? {
        comparisonSingleFile?.url ?? matchingTextFile(named: source.lastPathComponent)
    }

    private func matchingTextFile(named name: String) -> URL? {
        guard selectedItemCount == 0,
              let type = EditorOpeningSupport.key(forFilename: name), EditorOpeningSupport.extensions.contains(type) else { return nil }
        guard let entry = matchingLocalItem(named: name, kind: .file),
              let bytes = entry.byteCount, (0...Int64(TextDocumentValue.maximumBytes)).contains(bytes) else { return nil }
        return entry.url
    }

    private var localFolderForNameMatch: URL? {
        guard isViewLoaded, !isBrowserSuspended, !isOfflineCurrentFolder, !isReadOnlyFileSession,
              !metadataSearch.isShowingResults, !isLoading, let directory = location.directoryURL, directory.isFileURL else { return nil }
        return directory
    }

    private func matchingLocalItem(named name: String, kind: FileKind) -> FileEntry? {
        guard let directory = localFolderForNameMatch else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: kind == .directory || kind == .package)
        guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return nil }
        let entry = displayedEntries[row]
        return entry.kind == kind && entry.name.utf8.elementsEqual(name.utf8) ? entry : nil
    }

    func unselectedNameMatch(for source: BrowserViewController) -> URL? {
        guard source !== self, source.localFolderForNameMatch != nil, source.selectedItemCount == 1,
              selectedItemCount == 0, let url = source.orderedSelectedURLs(upTo: 1).first,
              let row = source.rowsByURL[url], source.displayedEntries.indices.contains(row) else { return nil }
        let item = source.displayedEntries[row]
        return matchingLocalItem(named: item.name, kind: item.kind)?.url
    }

    private func textSelectionPair(with peer: BrowserViewController, matchingName: Bool) -> (URL, URL)? {
        guard let workspace, !workspace.isClosing, peer.workspace === workspace,
              let parent = viewIfLoaded?.window, peer.viewIfLoaded?.window === parent, parent.attachedSheet == nil else { return nil }
        let pair: (URL, URL)
        switch (comparisonSingleFile?.url, peer.comparisonSingleFile?.url, matchingName) {
        case (let left?, let right?, false): pair = (left, right)
        case (let left?, nil, true):
            guard let right = peer.matchingTextFile(named: left.lastPathComponent) else { return nil }
            pair = (left, right)
        case (nil, let right?, true):
            guard let left = matchingTextFile(named: right.lastPathComponent) else { return nil }
            pair = (left, right)
        default: return nil
        }
        return pair.0.standardizedFileURL != pair.1.standardizedFileURL ? pair : nil
    }

    func canCompareSelectedText(with peer: BrowserViewController, matchingName: Bool = false) -> Bool {
        textSelectionPair(with: peer, matchingName: matchingName) != nil
    }

    func compareSelectedText(with peer: BrowserViewController, matchingName: Bool = false) -> Bool {
        guard let (left, right) = textSelectionPair(with: peer, matchingName: matchingName) else { return false }
        presentLocalTextComparison(left, right, peerAccess: peer.folderAccess)
        return true
    }

    private var comparisonFilePair: (URL, URL)? {
        guard isViewLoaded, hasFileCommandFocus, !isBrowserSuspended, !isOfflineCurrentFolder,
              !isArchiveLocation, !isRemoteLocation, !showsComputerVolumes, !isLoading,
              view.window?.attachedSheet == nil, selectedItemCount == 2 else { return nil }
        let files = orderedSelectedURLs(upTo: 2)
        guard files.count == 2, files.allSatisfy({ url in
            guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
            return displayedEntries[row].kind == .file
        }) else { return nil }
        return (files[0], files[1])
    }

    @objc func compareTextFiles(_ sender: Any?) {
        if isArchiveLocation {
            guard canCompareTextFiles else { return }
            currentArchive?.compareSelectedText(relativeTo: view.window)
            return
        }
        guard let parent = view.window, let workspace, !workspace.isClosing else { return }
        let left: URL, right: URL, peerAccess: FolderAccessController
        if let pair = comparisonFilePair {
            (left, right) = pair
            peerAccess = folderAccess
        } else {
            guard let (source, peers) = acrossPaneTextSelection,
                  let picked = LocalPaneDestination.choose(peers.map(\.destination), from: self, in: view,
                    title: "Compare Text with Other Pane", for: .comparison),
                  let peer = peers.first(where: { $0.destination == picked }),
                  let browser = picked.currentBrowser(from: self, for: .comparison),
                  let current = browser.textComparisonTarget(for: source.url), current.path.utf8.elementsEqual(peer.url.path.utf8),
                  source.isCurrent, isActiveCommandPane,
                  view.window === parent, parent.attachedSheet == nil else { return }
            (left, right) = (source.url, current)
            peerAccess = browser.folderAccess
        }
        presentLocalTextComparison(left, right, peerAccess: peerAccess)
    }

    private func presentLocalTextComparison(_ left: URL, _ right: URL, peerAccess: FolderAccessController) {
        guard let parent = view.window, let workspace, !workspace.isClosing else { return }
        let names = [left.lastPathComponent, right.lastPathComponent]
        let languages = names.map { TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: $0) ?? "") }
        let titles = names[0] == names[1] ? [left.path, right.path] : names
        let labels = EditorComparisonWindow.Labels(title: "Compare Text Files",
            source: "Local files", left: titles[0], right: titles[1],
            detail: "A read-only comparison. Refresh reads these two files again.", refresh: "Refresh")
        workspace.presentTextComparison(relativeTo: parent, settings: settings, labels: labels) {
            [fileSystem, access = folderAccess] in
            let lifetime = try await access.retainComparisonAccess(for: [left], alongside: (peerAccess, right))
            let documents: TextComparisonDocuments
            do { documents = try await fileSystem.readTextComparison(left: left, right: right, retaining: lifetime) }
            catch let failure as TextComparisonReadFailure {
                throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
            } catch let failure as LocalStorageError {
                throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
            }
            return .init(documents: documents, leftLanguage: languages[0], rightLanguage: languages[1])
        }
    }
}

@MainActor extension FolderAccessController {
    func retainComparisonAccess(for urls: [URL], alongside peer: (access: FolderAccessController, url: URL)? = nil) async throws -> FileAccessLifetimes {
        let requested = urls + (peer.map { [$0.url] } ?? [])
        let localURLs = peer?.access === self ? requested : urls
        let preparation = prepareAccess(to: localURLs)
        let other = peer.flatMap { $0.access === self ? nil : $0 }
        let otherPreparation = other.map { $0.access.prepareAccess(to: [$0.url]) }
        var leases = await retainAccess(for: localURLs).leases
        if let other, let otherPreparation {
            leases += await other.access.retainAccess(for: [other.url]).leases
            guard other.access.isCurrent(otherPreparation) else {
                throw EditorComparisonLoadFailure.unavailable("Folder access changed. Restore access in Traverse, then refresh.")
            }
        }
        try Task.checkCancellation()
        guard isCurrent(preparation) else {
            throw EditorComparisonLoadFailure.unavailable("Folder access changed. Restore access in Traverse, then refresh.")
        }
        let lifetime = FileAccessLifetimes(leases: leases)
        if TraverseAccessPolicy.requiresFolderSelection, !requested.allSatisfy(lifetime.covers) {
            throw EditorComparisonLoadFailure.unavailable("Choose access to the source folders in Traverse, then refresh.")
        }
        return lifetime
    }
}

@MainActor extension BrowserWorkspaceController {
    func presentTextComparison(relativeTo parent: NSWindow, settings: BrowserSettings, labels: EditorComparisonWindow.Labels,
                               files: EditorComparisonWindow.FileList? = nil, capture: @escaping EditorComparisonWindow.TextRead) {
        guard !isClosing else { return }
        if let previous = textComparisonWindow, previous.preparing {
            if parent.isVisible { previous.present() }
            return
        }
        textComparisonWindow?.window?.close()
        let pointSize = CGFloat(settings.editorPreferences.basePointSize) * settings.interfaceSize.scale
        let comparison = EditorComparisonWindow(relativeTo: parent, settings: settings, pointSize: pointSize,
                                                labels: labels, files: files, capture: capture)
        textComparisonWindow = comparison
        comparison.didClose = { [weak self, weak comparison] in
            if self?.textComparisonWindow === comparison { self?.textComparisonWindow = nil }
        }
        if parent.isVisible { comparison.present() }
        else { comparison.refresh() }
    }
}
