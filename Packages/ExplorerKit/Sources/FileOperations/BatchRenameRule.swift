import Foundation

/// Display/formatting data only, never a file observation or mutation token.
public struct BatchRenameName: Sendable {
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) { self.name = name; self.isDirectory = isDirectory }
}

public enum BatchRenameValidation: Error, Equatable, Sendable {
    case invalidRule, unsafeName, duplicateTarget, dependentNames, tooManyItems
    public var message: String {
        switch self {
        case .invalidRule: "Enter valid text and numbering options. Replace needs some text to find."
        case .unsafeName: "A resulting name is empty, too long, or contains a character that filenames cannot use."
        case .duplicateTarget: "Two resulting names would collide. Choose distinct names before renaming."
        case .dependentNames: "A result uses another selected item's current name. Swaps and rename chains are not supported yet."
        case .tooManyItems: "Choose up to 512 items in one folder."
        }
    }
}

/// Literal, bounded transforms. No regex, filesystem access or locale-dependent
/// search rules are hidden behind the preview.
public enum BatchRenameRule: Sendable, Equatable {
    case addText(prefix: String, suffix: String, preserveExtension: Bool)
    case replace(find: String, with: String, preserveExtension: Bool)
    case numbered(base: String, separator: String, start: Int, digits: Int, preserveExtension: Bool)

    public func names(for input: [BatchRenameName]) throws -> [String] {
        guard !input.isEmpty, input.count <= 512 else { throw BatchRenameValidation.tooManyItems }
        let originals = input.map { Self.key($0.name) }
        let originalKeys = Set(originals)
        guard originalKeys.count == originals.count else { throw BatchRenameValidation.duplicateTarget }
        var targets = Set<String>(), results: [String] = []
        for (index, item) in input.enumerated() {
            try Self.check(item.name)
            let result = try transformed(item, index: index)
            try Self.check(result)
            let key = Self.key(result)
            guard targets.insert(key).inserted else { throw BatchRenameValidation.duplicateTarget }
            if key != originals[index], originalKeys.contains(key) { throw BatchRenameValidation.dependentNames }
            results.append(result)
        }
        return results
    }
    private func transformed(_ item: BatchRenameName, index: Int) throws -> String {
        let preserve: Bool
        switch self {
        case .addText(_, _, let value), .replace(_, _, let value), .numbered(_, _, _, _, let value): preserve = value
        }
        let (stem, ext) = Self.components(item.name, split: preserve && !item.isDirectory)
        switch self {
        case .addText(let prefix, let suffix, _):
            guard prefix.utf8.count <= 255, suffix.utf8.count <= 255 else { throw BatchRenameValidation.invalidRule }
            return prefix + stem + suffix + ext
        case .replace(let find, let replacement, _):
            guard !find.isEmpty, find.utf8.count <= 255, replacement.utf8.count <= 255 else { throw BatchRenameValidation.invalidRule }
            return stem.replacingOccurrences(of: find, with: replacement, options: .literal) + ext
        case .numbered(let base, let separator, let start, let digits, _):
            guard !base.isEmpty, base.utf8.count <= 255, separator.utf8.count <= 16,
                  (0...999_999_999).contains(start), (1...9).contains(digits) else { throw BatchRenameValidation.invalidRule }
            let (number, overflow) = start.addingReportingOverflow(index)
            guard !overflow, number <= 999_999_999 else { throw BatchRenameValidation.invalidRule }
            let text = String(number)
            return base + separator + String(repeating: "0", count: max(0, digits - text.count)) + text + ext
        }
    }
    private static func components(_ name: String, split: Bool) -> (String, String) {
        guard split, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
    private static func check(_ name: String) throws {
        do { try validateName(name) } catch { throw BatchRenameValidation.unsafeName }
    }
    internal static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
