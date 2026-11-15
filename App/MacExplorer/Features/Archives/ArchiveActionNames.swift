import Foundation

enum ArchiveActionNames {
    static func formatName(for source: URL) -> String {
        let name = source.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { return "TAR.bz2" }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "TAR.gz" }
        return source.pathExtension.uppercased()
    }

    static func editedCopyName(_ source: URL) -> String {
        let leaf = source.lastPathComponent
        let compound = [".tar.gz", ".tar.bz2"].first { leaf.lowercased().hasSuffix($0) }
        let suffix = compound.map { String(leaf.suffix($0.count)) } ?? "." + source.pathExtension
        let stem = String(leaf.dropLast(suffix.count))
        return stem + "-edited" + suffix
    }

    static func extractionFolder(for source: URL) -> String {
        let leaf = source.lastPathComponent
        let suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar", ".zip", ".jar"]
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
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2")
    }
}
