import AppKit

/// Feedback belongs to this exact clipboard revision, independent of the open
/// folder or selection. It describes file references, never a completed transfer.
@MainActor
struct TransferClipboardFeedback {
    enum Intent: Sendable { case copy, move }
    enum ScopedItems { case server(String, String), archive(String, String, [String]) }
    let intent: Intent
    let urls: [URL]
    let changeCount: Int
    var scopedItem: ScopedItems? = nil
    let id = UUID()
    let attention = ClipboardAttention()
    var moveAttemptIncomplete = false

    var message: String {
        switch scopedItem {
        case .server: return intent == .move ? "Cut 1 server item · Ready to move" : "Copied 1 server item · Ready to paste"
        case .archive(let format, _, let paths): return "\(intent == .move ? "Cut" : "Copied") \(paths.count) \(format) item\(paths.count == 1 ? "" : "s") · Ready to \(intent == .move ? "move" : "paste")"
        case nil: break
        }
        let items = "\(urls.count) item\(urls.count == 1 ? "" : "s")"
        if moveAttemptIncomplete { return "\(items) on clipboard · Move unfinished" }
        return intent == .move ? "Cut \(items) · Ready to move" : "Copied \(items) · Ready to paste"
    }

    /// The bounded inspector presents file-reference metadata only. Full source
    /// paths distinguish identical filenames copied from different directories.
    var detailLines: [String] {
        switch scopedItem {
        case .server(let name, let source):
            return [name + "\nSource: " + source,
                intent == .move ? "Paste in another folder on this connection. The source stays in place until Move succeeds. Remote moves have no automatic Undo."
                    : "Paste into a folder on this connection. The original stays in place."]
        case .archive(let format, let name, let paths):
            var lines = paths.prefix(6).map { "\($0)\nSource: \(name)" }
            if paths.count > 6 { lines.append("\(paths.count - 6) more items") }
            if intent == .move {
                lines.append("Paste in another folder in this ZIP tab to review the move. You can Undo the update.")
            } else if format == "ZIP", ZIPOriginalUpdateFeature.available && SelectedArchiveExtractionActivation.available {
                lines.append("Paste into this ZIP tab or a local folder in Traverse. Original items stay in place.")
            } else if format == "ZIP" {
                lines.append("Paste in this ZIP tab. Original items stay in place.")
            } else {
                lines.append("Paste into a local folder in Traverse. The archive stays unchanged.")
            }
            return lines
        case nil: break
        }
        var lines = urls.prefix(6).map { "\($0.lastPathComponent)\nSource: \($0.deletingLastPathComponent().path)" }
        if urls.count > 6 { lines.append("\(urls.count - 6) more items on the clipboard") }
        lines.append(moveAttemptIncomplete
            ? "Move unfinished. Review the operation result; select remaining items and Cut again before another move."
            : intent == .move ? "Ready to move. Source items stay in place until the move succeeds."
            : "Ready to paste. These are file references; no transfer has completed yet.")
        return lines
    }
}

@MainActor
extension BrowserViewController {
    func showTransferFeedback(_ intent: TransferClipboardFeedback.Intent, urls: [URL],
                              publication: BrowserClipboard.Publication? = nil, revision: UUID? = nil) {
        if let publication {
            // Failed/no-op writers cannot borrow equal old native references.
            guard intent == .copy, let revision,
                  clipboardState.acceptCopy(publication, urls: urls, revision: revision) else {
                // A reentrant writer may have installed newer local intent.
                if revision == clipboardRevision {
                    clearCutSelection()
                    status.stringValue = "The file references could not be placed on the clipboard. Try again."
                }
                return
            }
            renderTransferFeedback()
            clipboardState.beginObservation()
            return
        }
        guard let capture = clipboardState.readFiles(allowOwnedCopy: false),
              capture.urls == urls, !urls.isEmpty else {
            clearCutSelection()
            status.stringValue = "The file references could not be placed on the clipboard. Try again."
            return
        }
        transferFeedback = TransferClipboardFeedback(intent: intent, urls: urls,
            changeCount: capture.changeCount)
        renderTransferFeedback()
        clipboardState.beginObservation()
    }

    /// NSPasteboard has no general change notification. Poll only while this
    /// window owns feedback; command validation also refreshes it immediately.
    func synchronizeTransferClipboard() {
        clipboardState.synchronize()
    }

    /// Local-file Paste into an archive or a server is Copy only. Leave native
    /// text editing, a pending Cut, and virtual item references with their owners.
    var canPasteLocalCopies: Bool {
        guard hasFileCommandFocus, cutPreparationTask == nil,
              !(view.window?.firstResponder is NSTextView) else { return false }
        synchronizeTransferClipboard()
        return pendingCut == nil && cutPreparationTask == nil && !hasScopedItemPasteboardType
            && transferPasteboard.availableType(from: [.fileURL]) != nil
    }

    func renderTransferFeedback() {
        renderScopedClipboardAppearance()
        clipboardStatus.liveFeedback = { [weak self] in
            guard let self else { return nil }
            self.synchronizeTransferClipboard()
            return self.transferFeedback
        }
        clipboardStatus.onDismiss = { [weak self] id in
            guard let self else { return false }
            let responder = self.view.window?.firstResponder as? NSView
            let restoreFocus = responder === self.clipboardStatus
                || responder?.isDescendant(of: self.clipboardStatus) == true
                || self.clipboardStatus.ownsDetailsFocus
            guard self.clipboardState.dismiss(feedbackID: id) else {
                self.clipboardStatus.update(self.transferFeedback)
                return false
            }
            self.renderTransferFeedback()
            if restoreFocus { self.focusBrowserContent() }
            return true
        }
        clipboardStatus.update(transferFeedback)
    }
}
