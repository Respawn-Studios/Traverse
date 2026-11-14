import AppKit
import FileOperations

/// UI decisions and the existing application mutation queue. Filesystem
/// authority remains in the concrete archive reader and FileOperations plans.
@MainActor struct ArchiveEditorInteractions {
    var acquireMutation: () async throws -> UUID
    var finishMutation: (UUID) -> Void
    var requireUnreferenced: (URL) async throws -> Void
    var confirmReload: (NSWindow, Bool) async -> Bool
    var chooseZIPCopyName: (NSWindow, URL) async -> String?
    var chooseTextCopy: (NSWindow, String) async -> EditorSaveDestination?
    var publishTextCopy: (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult
    var showResult: (UUID) -> Void
    var chooseClose: (NSWindow, TextDocumentState.CloseDisposition) async -> EditorCloseChoice
    var publish: (RecoverableOperationResult, URL?, URL) -> Void

    static func chooseZIPCopyName(in window: NSWindow, source: URL) async -> String? {
        guard window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = "Save an edited ZIP copy"
        alert.informativeText = "The copy will be saved beside the original ZIP. Existing files are kept. This editor will follow the new copy."
        let field = NSTextField(string: source.deletingPathExtension().lastPathComponent + "-edited.zip")
        field.frame = .init(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("ZIP copy name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Copy"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
