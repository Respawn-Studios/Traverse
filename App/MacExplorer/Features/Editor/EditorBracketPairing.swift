import Foundation

/// A keystroke proposal only. The native view owns admission, Undo and the
/// provenance of closes it inserted. Context is a bounded prefix, never a scan
/// of the full document on each key.
enum EditorBracketPairing {
    enum Plan: Equatable { case native, insert(String, UInt16), skip }

    static func close(forOpening unit: UInt16) -> UInt16? {
        switch unit { case 40: 41; case 91: 93; case 123: 125; default: nil }
    }

    static func isClosing(_ unit: UInt16) -> Bool { unit == 41 || unit == 93 || unit == 125 }

    private static func isJSON(_ language: TextSyntaxLanguage) -> Bool { language == .json || language == .jsonc }

    static func isEnabled(in language: TextSyntaxLanguage, json: Bool, code: Bool) -> Bool {
        isJSON(language) ? json : code && EditorIndentation.supportsCodeStructure(language)
    }

    static func needsContext(_ unit: UInt16, next: UInt16?, ownsNextClose: Bool, language: TextSyntaxLanguage) -> Bool {
        if isJSON(language), unit == 40 || unit == 41 { return false }
        if isClosing(unit) { return ownsNextClose && next == unit }
        guard close(forOpening: unit) != nil else { return false }
        guard let next else { return true }
        return [9, 10, 13, 32, 44, 93, 125].contains(next) || !isJSON(language) && [41, 59].contains(next)
    }

    static func plan(_ typed: String, prefix: String?, next: UInt16?,
                     ownsNextClose: Bool, language: TextSyntaxLanguage, enabled: Bool) -> Plan {
        guard isEnabled(in: language, json: enabled, code: enabled), typed.utf16.count == 1,
              let unit = typed.utf16.first, needsContext(unit, next: next, ownsNextClose: ownsNextClose, language: language),
              let prefix, let close = close(forOpening: unit) ?? (isClosing(unit) ? unit : nil) else { return .native }
        let offset = prefix.utf16.count
        if isJSON(language) {
            guard EditorIndentation.jsonCode(at: offset, in: prefix as NSString) else { return .native }
        } else {
            guard offset < EditorIndentation.lexicalInputLimit else { return .native }
            let probe = (prefix + typed) as NSString
            let lineStart = probe.lineRange(for: .init(location: offset, length: 0)).location
            guard EditorIndentation.codeRanges(at: offset, lineStart: lineStart, in: probe,
                language: language, checkingRustCharacter: true) != nil else { return .native }
        }
        if isClosing(unit) { return .skip }
        return .insert(String(decoding: [unit, close], as: UTF16.self), close)
    }
}
