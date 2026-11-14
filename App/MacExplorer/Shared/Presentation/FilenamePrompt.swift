import AppKit

/// Name entry only. The caller owns the observed parent, conflict policy and
/// actual operation. Validation never broadens access or starts a filesystem read.
@MainActor final class FilenamePrompt: NSObject, NSTextFieldDelegate {
    static let newFileTitle = "New File"
    static let newFileDefaultName = "Untitled"
    static let newFileInstructions = "Enter a name and an optional extension, such as .json, .py or .txt. No extension creates plain text. Existing files are kept."
    enum LengthLimit {
        case utf8Bytes(Int), utf16Units(Int)
        func allows(_ name: String) -> Bool {
            switch self {
            case .utf8Bytes(let limit): return name.utf8.count <= limit
            case .utf16Units(let limit): return name.utf16.count <= limit
            }
        }
    }
    /// A convenience from already observed names, never an absence guarantee.
    static func suggestedName(_ original: String, isOccupied: (String) -> Bool) -> String {
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        for ordinal in 1...100 {
            let candidate = ordinal == 1 ? original : stem + " " + String(ordinal) + (ext.isEmpty ? "" : "." + ext)
            if !isOccupied(candidate) { return candidate }
        }
        return original
    }
    private let alert = NSAlert()
    private let field: NSTextField
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let validation: ((String) -> String?)?
    private let lengthLimit: LengthLimit
    init(title: String, initial: String, message: String?, lengthLimit: LengthLimit = .utf8Bytes(255),
         validation: ((String) -> String?)?) {
        field = NSTextField(string: initial); self.validation = validation; self.lengthLimit = lengthLimit
        super.init()
        alert.messageText = title; alert.informativeText = message ?? ""
        alert.addButton(withTitle: title == "Rename" ? "Rename" : "Create")
        alert.addButton(withTitle: "Cancel")
        field.delegate = self; field.setAccessibilityLabel("Full name, including extension")
        InterfaceMetrics.setFont(field, base: .systemFont(ofSize: NSFont.systemFontSize))
        InterfaceMetrics.setFont(feedback, base: .systemFont(ofSize: 11)); feedback.maximumNumberOfLines = 2
        let content = NSStackView(views: [field, feedback])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 6
        content.frame = .init(x: 0, y: 0, width: InterfaceMetrics.points(360), height: InterfaceMetrics.points(58))
        field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        feedback.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        feedback.heightAnchor.constraint(greaterThanOrEqualToConstant: InterfaceMetrics.points(26)).isActive = true
        alert.accessoryView = content; alert.window.initialFirstResponder = field
        refresh()
    }
    func choose(in parent: NSWindow) async -> String? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            let response = await alert.beginSheetModal(for: parent)
            guard response == .alertFirstButtonReturn, !Task.isCancelled, issue == nil else { return nil }
            return field.stringValue
        } onCancel: { Task { @MainActor [weak self, weak parent] in
            guard let self, let parent, self.alert.window.sheetParent === parent else { return }
            parent.endSheet(self.alert.window, returnCode: .cancel)
        } }
    }
    private var issue: String? {
        let name = field.stringValue
        if name.isEmpty { return "Enter a name." }
        if name == "." || name == ".." || name.contains("/") || name.utf8.contains(0)
            || name.contains("\n") || name.contains("\r") { return "Choose a name without slashes or line breaks." }
        if !lengthLimit.allows(name) { return "This name is too long. Use a shorter name." }
        return validation?(name)
    }
    private func refresh() {
        let error = issue
        alert.buttons.first?.isEnabled = error == nil
        feedback.stringValue = error ?? "Full name, including its extension."
        feedback.textColor = error == nil ? .secondaryLabelColor : .systemRed
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        refresh(); if alert.buttons.first?.isEnabled == true { alert.buttons.first?.performClick(nil) }
        return true
    }
}
