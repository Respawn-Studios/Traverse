import Foundation

enum ArchiveActionNames {
    static func editedCopyName(_ source: URL) -> String {
        let leaf = source.lastPathComponent
        let suffix = leaf.lowercased().hasSuffix(".tar.gz") ? String(leaf.suffix(7)) : "." + source.pathExtension
        let stem = String(leaf.dropLast(suffix.count))
        return stem + "-edited" + suffix
    }

    static func extractionFolder(for source: URL) -> String {
        let leaf = source.lastPathComponent
        let suffixes = [".tar.gz", ".tgz", ".tar", ".zip", ".jar"]
        let stem = suffixes.first { leaf.lowercased().hasSuffix($0) }
            .map { String(leaf.dropLast($0.count)) } ?? source.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Archive" : stem
    }

    static func extractionTitle(for source: URL?) -> String {
        guard let source else { return "Extract to New Folder" }
        let name = extractionFolder(for: source)
        let label = name.count > 48 ? String(name.prefix(45)) + "…" : name
        return "Extract to “\(label)”"
    }

    static func isTAR(_ source: URL) -> Bool {
        let name = source.lastPathComponent.lowercased()
        return name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }
}
