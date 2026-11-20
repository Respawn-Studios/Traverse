import AppKit

/// Name entry only. The caller owns the observed parent, conflict policy and
/// actual operation. Validation never broadens access or starts a filesystem read.
@MainActor final class FilenamePrompt {
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
    private let sheet: NativeTextInputSheet
    init(title: String, initial: String, message: String?, lengthLimit: LengthLimit = .utf8Bytes(255),
         validation: ((String) -> String?)?) {
        sheet = NativeTextInputSheet(title: title, confirmTitle: title == "Rename" ? "Rename" : "Create",
            message: message ?? "", initial: initial, fieldLabel: "Full name, including extension",
            hint: "Full name, including its extension.") { name in
            if name.isEmpty { return "Enter a name." }
            if name == "." || name == ".." || name.contains("/") || name.utf8.contains(0)
                || name.contains("\n") || name.contains("\r") { return "Choose a name without slashes or line breaks." }
            if !lengthLimit.allows(name) { return "This name is too long. Use a shorter name." }
            return validation?(name)
        }
    }
    func choose(in parent: NSWindow) async -> String? {
        await sheet.choose(in: parent)
    }
}
