import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

/// Applies private tab styles while native character editing and Undo retain ownership.
/// The caller controls presentation preferences; no text notifications are synthesized.
@MainActor
enum EditorTabPresentation {
    enum Outcome: Equatable { case applied, deferredForComposition, refused }
    static func apply(columns: CGFloat, to surface: NativeTextEditorSurface) -> Outcome {
        guard columns.isFinite, [CGFloat(2), 4, 8].contains(columns) else { return .refused }
        let text = surface.textView
        guard !text.hasMarkedText() else { return .deferredForComposition }
        guard text.string.utf8.count <= TextDocumentValue.maximumBytes,
              let storage = text.textStorage, let font = text.font else { return .refused }
        let interval = (" " as NSString).size(withAttributes: [.font: font]).width * columns
        guard interval.isFinite, interval > 0 else { return .refused }
        func copyStyle(_ value: Any?, fallback: NSParagraphStyle) -> NSParagraphStyle? {
            guard value == nil || value is NSParagraphStyle,
                  let copy = ((value as? NSParagraphStyle) ?? fallback).mutableCopy() as? NSMutableParagraphStyle else { return nil }
            copy.tabStops = []; copy.defaultTabInterval = interval
            return copy.copy() as? NSParagraphStyle
        }
        let base = text.defaultParagraphStyle ?? NSParagraphStyle.default
        guard let defaultStyle = copyStyle(base, fallback: base) else { return .refused }
        let typing = text.typingAttributes
        guard let typingStyle = copyStyle(typing[.paragraphStyle], fallback: base) else { return .refused }
        var runs: [(NSRange, NSParagraphStyle)] = []
        var cursor = 0
        while cursor < storage.length {
            var range = NSRange()
            let value = storage.attribute(.paragraphStyle, at: cursor, effectiveRange: &range)
            guard range.location <= cursor, range.length > 0, NSMaxRange(range) <= storage.length,
                  let style = copyStyle(value, fallback: base) else { return .refused }
            runs.append((range, style)); cursor = NSMaxRange(range)
        }
        // Preserve a caller's existing registration-disable nesting. Never
        // remove actions, open/close groups or change groupsByEvent.
        let manager = text.undoManager
        let registrationWasEnabled = manager?.isUndoRegistrationEnabled == true
        if registrationWasEnabled { manager?.disableUndoRegistration() }
        defer { if registrationWasEnabled { manager?.enableUndoRegistration() } }
        text.defaultParagraphStyle = defaultStyle
        storage.beginEditing()
        for (range, style) in runs { storage.addAttribute(.paragraphStyle, value: style, range: range) }
        storage.endEditing()
        var updatedTyping = typing
        updatedTyping[.paragraphStyle] = typingStyle
        text.typingAttributes = updatedTyping
        return .applied
    }
}
