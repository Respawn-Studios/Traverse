import Foundation

/// A keystroke proposal only. The native view owns admission, Undo and the
/// provenance of closes it inserted. Context is a bounded prefix, never a scan
/// of the full document on each key.
enum EditorBracketPairing {
    enum Plan: Equatable { case native, insert(String, UInt16), skip }

    static func plan(_ typed: String, prefix: String?, next: UInt16?,
                     ownsNextClose: Bool, language: TextSyntaxLanguage, enabled: Bool) -> Plan {
        guard enabled, language == .json || language == .jsonc, typed.utf16.count == 1,
              let unit = typed.utf16.first, [91, 93, 123, 125].contains(unit), let prefix,
              EditorIndentation.jsonCode(at: prefix.utf16.count, in: prefix as NSString) else { return .native }
        if (unit == 125 || unit == 93), ownsNextClose, next == unit { return .skip }
        guard unit == 123 || unit == 91 else { return .native }
        // In front of existing content, leave the ordinary native insertion
        // alone. A close, comma, whitespace or EOF is a useful JSON boundary.
        if let next, ![9, 10, 13, 32, 44, 93, 125].contains(next) { return .native }
        return unit == 123 ? .insert("{}", 125) : .insert("[]", 93)
    }
}
