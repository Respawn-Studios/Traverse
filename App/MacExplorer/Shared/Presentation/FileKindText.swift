import Foundation

/// Local and server lists describe the same observed kinds without a file or
/// Launch Services query. A label never implies that Open is available.
enum FileKindText {
    static func string(name: String, kind: String) -> String {
        switch kind {
        case "directory": return "Folder"
        case "package": return "Package"
        case "symbolicLink": return "Symbolic link"
        case "file":
            let suffix = (name as NSString).pathExtension
            return suffix.isEmpty ? "File" : "\(suffix.uppercased()) file"
        default: return "Item"
        }
    }
}
