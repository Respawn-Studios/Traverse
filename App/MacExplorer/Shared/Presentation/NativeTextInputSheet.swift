import AppKit

/// A text field, validation feedback and a cancellable native sheet. Callers
/// own validation and any operation or selection that follows confirmation.
@MainActor final class NativeTextInputSheet: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let field: NSTextField
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let hint: String
    private let validate: (String) -> String?

    init(title: String, confirmTitle: String, message: String, initial: String,
         fieldLabel: String, hint: String = "", additionalControl: NSView? = nil,
         validate: @escaping (String) -> String?) {
        field = NSTextField(string: initial)
        self.hint = hint
        self.validate = validate
        super.init()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        field.delegate = self
        field.setAccessibilityLabel(fieldLabel)
        InterfaceMetrics.setFont(field, base: .systemFont(ofSize: NSFont.systemFontSize))
        InterfaceMetrics.setFont(feedback, base: .systemFont(ofSize: 11))
        feedback.maximumNumberOfLines = 2

        let controls = [field as NSView, feedback] + (additionalControl.map { [$0] } ?? [])
        let content = NSStackView(views: controls)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.frame = .init(x: 0, y: 0, width: InterfaceMetrics.points(360),
            height: InterfaceMetrics.points(additionalControl == nil ? 58 : 88))
        field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        feedback.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        feedback.heightAnchor.constraint(greaterThanOrEqualToConstant: InterfaceMetrics.points(26)).isActive = true
        alert.accessoryView = content
        alert.window.initialFirstResponder = field
        refresh()
    }

    func choose(in parent: NSWindow) async -> String? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            let response = await alert.beginSheetModal(for: parent)
            guard response == .alertFirstButtonReturn, !Task.isCancelled,
                  validate(field.stringValue) == nil else { return nil }
            return field.stringValue
        } onCancel: {
            Task { @MainActor [weak self, weak parent] in
                guard let self, let parent, self.alert.window.sheetParent === parent else { return }
                parent.endSheet(self.alert.window, returnCode: .cancel)
            }
        }
    }

    private func refresh() {
        let issue = validate(field.stringValue)
        alert.buttons.first?.isEnabled = issue == nil
        feedback.stringValue = issue ?? hint
        feedback.textColor = issue == nil ? .secondaryLabelColor : .systemRed
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
        refresh()
        if alert.buttons.first?.isEnabled == true { alert.buttons.first?.performClick(nil) }
        return true
    }
}
