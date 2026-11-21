import AppKit
import ExplorerCore

@MainActor
extension BrowserViewController {
    @objc func viewTextInTraverse(_ sender: Any?) {
        ApplicationRemoteTextViews.shared.open(from: self)
    }
    func fileOpeningAppearance(_ entry: FileEntry) -> FileOpeningAppearance {
        guard !isRemoteLocation, !isArchiveLocation else { return .ordinary }
        if entry.isDataless { return .onlineOnly }
        return .resolve(name: entry.name, kind: entry.kind.rawValue,
            preferences: settings.editorPreferences, editorAvailable: LocalTextEditorFeature.ordinaryEnabled,
            localEditorEligible: !isReadOnlyFileSession && recoverableFileOperations != nil,
            opensArchives: settings.opensArchivesInTraverse,
            zipAvailable: ArchiveBrowseActivation.available, tarAvailable: TARBrowseFeature.available)
    }
}
