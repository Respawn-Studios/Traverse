import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    func chooseTransferMetadata(default policy: TransferMetadataPolicy) async -> TransferMetadataPolicy? {
        if let prompt = transferMetadataPrompt { return await prompt(policy) }
        guard let window = view.window else { return nil }
        let (alert, picker) = makeTransferMetadataAlert(default: policy)
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
            status.stringValue = "Paste cancelled. No files changed."
            return nil
        }
        return picker.indexOfSelectedItem == 0 ? .strict : .destinationOwnership
    }
}

@MainActor
func makeTransferMetadataAlert(default policy: TransferMetadataPolicy) -> (NSAlert, NSPopUpButton) {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28), pullsDown: false)
        picker.addItems(withTitles: TransferMetadataPreference.allCases.map(\.rawValue))
        picker.selectItem(at: policy == .strict ? 0 : 1)
        picker.setAccessibilityLabel("Metadata mode for this transfer")
        let alert = NSAlert()
        alert.messageText = "Paste options"
        alert.informativeText = "Strict preservation requires matching ownership. Native owner/group permits only ownership differences, which can change who existing permissions apply to. Both verify file data, permissions and recorded native security metadata. This choice applies to this transfer without changing Settings."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = picker
        return (alert, picker)
}

/// The queued job owns these controls; they never mutate global preferences.
@MainActor
func makeTransferOptionsAlert(metadata: TransferMetadataPolicy, conflicts: TransferConflictPreferences)
    -> (NSAlert, () -> (TransferMetadataPolicy, TransferConflictPreferences)) {
    let (alert, metadataPicker) = makeTransferMetadataAlert(default: metadata)
    let files = NSPopUpButton(), folders = NSPopUpButton()
    for picker in [files, folders] { picker.addItems(withTitles: TransferConflictDefault.allCases.map(\.title)) }
    files.selectItem(at: TransferConflictDefault.allCases.firstIndex(of: conflicts.files) ?? 0)
    folders.selectItem(at: TransferConflictDefault.allCases.firstIndex(of: conflicts.folders) ?? 0)
    files.setAccessibilityLabel("File conflicts for this transfer")
    folders.setAccessibilityLabel("Folder conflicts for this transfer")
    let grid = NSGridView(views: [
        [NSTextField(labelWithString: "Metadata"), metadataPicker],
        [NSTextField(labelWithString: "Existing files"), files],
        [NSTextField(labelWithString: "Existing folders"), folders],
    ])
    grid.rowSpacing = 8; grid.columnSpacing = 12
    grid.setFrameSize(grid.fittingSize)
    alert.accessoryView = grid
    alert.informativeText += " Skip and Keep Both resolve ordinary name collisions automatically. Replace/Merge and unsupported conflict types still ask."
    return (alert, {
        (metadataPicker.indexOfSelectedItem == 0 ? .strict : .destinationOwnership,
         TransferConflictPreferences(files: TransferConflictDefault.allCases[max(0, files.indexOfSelectedItem)],
                                     folders: TransferConflictDefault.allCases[max(0, folders.indexOfSelectedItem)]))
    })
}
