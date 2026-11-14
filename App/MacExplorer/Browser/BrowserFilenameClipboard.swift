import AppKit
import ExplorerCore

@MainActor extension BrowserViewController {
    /// Cheap menu/discovery eligibility only. The exact complete formatter
    /// still refuses mixed/outside/control-line input before any publication.
    var canCopyFilenameMetadata: Bool {
        !isBrowserSuspended && !isRemoteLocation && !showsComputerVolumes
            && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor && view.window?.attachedSheet == nil
            && location.directoryURL != nil && (1...FilenameClipboardText.maximumItems).contains(selectedItemCount)
    }
    @objc func copyNames(_ sender: Any?) {
        if isArchiveLocation { copyObservedArchiveMetadata(name: true); return }
        if isRemoteLocation { copyObservedRemoteMetadata(name: true); return }
        copyFilenameMetadata(.names)
    }
    @objc func copyRelativePaths(_ sender: Any?) { copyFilenameMetadata(.relativePaths) }

    private func copyFilenameMetadata(_ kind: FilenameClipboardText.Kind) {
        guard canCopyFilenameMetadata else { return }
        let count = selectedItemCount
        let selected = orderedSelectedURLs(upTo: FilenameClipboardText.maximumItems + 1)
        guard selected.count == count else {
            status.stringValue = "The selection changed. Select the items again before copying their names."
            return
        }
        let text: String
        do { text = try FilenameClipboardText.make(selected, kind: kind, relativeTo: location.directoryURL) }
        catch {
            switch error {
            case FilenameClipboardText.Failure.outsideFolder:
                status.stringValue = "Some selected items are outside the current folder. Use Copy Path for those items."
            case FilenameClipboardText.Failure.tooMany, FilenameClipboardText.Failure.tooLarge:
                status.stringValue = "This selection is too large to copy as a text list. Select fewer items and try again."
            case FilenameClipboardText.Failure.unsafeLine:
                status.stringValue = "Some selected names cannot be copied as a line-separated list."
            default:
                status.stringValue = "The selected names could not be prepared. Select local items and try again."
            }
            return
        }
        // Validation refusal above leaves clipboard/Cut unchanged. An admitted
        // explicit Copy replaces the existing app Cut intent, like Copy Path.
        clearCutSelection()
        if case .text = clipboardWriter(text, []) {
            let noun: String
            switch kind { case .names: noun = count == 1 ? "name" : "names"; case .relativePaths: noun = count == 1 ? "relative path" : "relative paths" }
            status.stringValue = "Copied \(count.formatted()) \(noun)."
        } else { status.stringValue = "The clipboard could not be updated. Try again." }
    }
}
