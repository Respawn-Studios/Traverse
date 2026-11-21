import AppKit
import ExplorerCore

enum BrowserLocalFileOpenIntent: Sendable, Equatable { case ordinary, systemDefault }

@MainActor
extension BrowserViewController {
    var canOpenSelectedFileInDefaultApp: Bool {
        guard !isBrowserSuspended, !isLoading, !isOfflineCurrentFolder, !isMetadataAccessQualification,
              !isRemoteLocation, !isArchiveLocation, !showsComputerVolumes, hasFileCommandFocus,
              view.window?.attachedSheet == nil, !(view.window?.firstResponder is NSTextView),
              selectedItemCount == 1, let url = orderedSelectedURLs.first,
              let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
        return displayedEntries[row].kind == .file || displayedEntries[row].kind == .package
    }

    @objc func openSelectedFileInDefaultApp(_ sender: Any?) {
        guard canOpenSelectedFileInDefaultApp, let url = orderedSelectedURLs.first,
              let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return }
        let entry = displayedEntries[row]
        if metadataSearch.isShowingResults { metadataSearch.openSelection(entry, intent: .systemDefault) }
        else { openVerifiedLocalFile(entry, intent: .systemDefault) }
    }

    var canEditTextInTraverse: Bool {
        if isRemoteLocation { return ApplicationRemoteTextEditors.shared.canOpen(from: self) }
        guard LocalTextEditorFeature.ordinaryEnabled, !isBrowserSuspended, !isReadOnlyFileSession,
              !isArchiveLocation, !isRemoteLocation, !showsComputerVolumes, !isLoading,
              hasFileCommandFocus, view.window?.attachedSheet == nil,
              !(view.window?.firstResponder is NSTextView), recoverableFileOperations != nil,
              (1...4).contains(selectedItemCount) else { return false }
        return orderedSelectedURLs.allSatisfy { url in
            guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
            return displayedEntries[row].kind == .file && !displayedEntries[row].isDataless
        }
    }

    @objc func editTextInTraverse(_ sender: Any?) {
        if isRemoteLocation { ApplicationRemoteTextEditors.shared.open(from: self); return }
        guard canEditTextInTraverse else { return }
        ApplicationLocalTextEditors.shared.openSelection(orderedSelectedURLs, from: self)
    }

    /// Recommended native defaults and explicit choices affect Open inside Traverse only.
    /// Refusal keeps that intent; it never falls through to an unrelated app.
    func openUsingLocalPreference(_ entry: FileEntry) -> Bool {
        let target = settings.editorPreferences.route(forFilename: entry.name, command: .ordinaryOpen,
                                                      editorAvailable: LocalTextEditorFeature.ordinaryEnabled)
        switch target {
        case .systemDefault:
            // An explicit macOS choice also overrides the archive default.
            if settings.editorPreferences.explicitTarget(forFilename: entry.name) == .systemDefault {
                if !handoffToDefaultApplication(entry.url) { status.stringValue = "No application could open this item." }
                return true
            }
            return false
        case .traverse:
            if entry.isDataless {
                status.stringValue = "This file is online only. Make it available on this Mac to edit it in Traverse."
                return true
            }
            guard entry.kind == .file, canEditTextInTraverse, orderedSelectedURLs == [entry.url] else {
                status.stringValue = "This item cannot be opened in the text editor here. Use Open in Default App or choose another application."
                return true
            }
            ApplicationLocalTextEditors.shared.open(entry.url, from: self)
            return true
        case .externalApplication(let application):
            openAndShare.openPreferredApplication(application, for: entry)
            return true
        }
    }
}
