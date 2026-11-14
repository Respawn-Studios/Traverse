import AppKit
import ExplorerCore

/// One optional Cautious review, shared by concrete SMB/SFTP upload owners.
@MainActor enum FileUploadGroupReview {
    static func choose(names: [String], bytes: UInt64, destination: String, in window: NSWindow?) async -> Bool {
        guard let window, !names.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = "Upload \(names.count) \(names.count == 1 ? "item" : "items")?"
        let shown = names.prefix(8).map { "• " + $0 }.joined(separator: "\n")
        let rest = names.count > 8 ? "\n…and \(names.count - 8) more." : ""
        alert.informativeText = "To \(destination)\n\n\(shown)\(rest)\n\n\(FileSizeText.string(Int64(bytes))) · Existing names are kept. Your local originals stay here."
        alert.addButton(withTitle: "Upload"); alert.addButton(withTitle: "Cancel")
        return await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        } onCancel: {
            Task { @MainActor in
                if window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
            }
        }
    }
}
