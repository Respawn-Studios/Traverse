import AppKit

/// Confirmation presentation only. The displayed URLs cannot authorize a
/// removal; the caller retains the engine's one-use plan independently.
@MainActor
enum OwnedTrashDeletionReview {
    static func make(originalURLs: [URL]) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Permanently delete this entire group?"
        let names = originalURLs.prefix(6).map(\.lastPathComponent).joined(separator: "\n")
        alert.informativeText = "\(originalURLs.count.formatted()) recorded items:\n\n" + names
            + (originalURLs.count > 6 ? "\n…" : "")
            + "\n\nThis permanently removes the group’s Trash copies. Starting deletion ends Restore for the whole group, including any items left if deletion is interrupted. Traverse checks every item before starting."
        let remove = alert.addButton(withTitle: "Permanently Delete Group")
        let cancel = alert.addButton(withTitle: "Cancel")
        remove.hasDestructiveAction = true; remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        alert.window.initialFirstResponder = cancel
        return alert
    }
}
