import AppKit

@MainActor enum RemoteDeleteConfirmation {
    static func confirm(name: String, destination: String, emptyFolder: Bool = false, in window: NSWindow) async -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)” permanently?"
        let explanation = emptyFolder
            ? "This folder can be deleted only if it is empty. It will not go to Trash, and Traverse cannot Undo this deletion."
            : "This server file will not go to Trash. Traverse cannot Undo this deletion."
        alert.informativeText = "\(destination)\n\n\(explanation)"
        alert.addButton(withTitle: "Delete Permanently"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}
