import Foundation
import ExplorerCore

enum ArchiveActionNames {
    static func formatName(for source: URL) -> String {
        let kind = ArchiveFilename(source.lastPathComponent)?.kind
        if kind == .tarBzip2 { return "TAR.bz2" }
        if kind == .tarGzip { return "TAR.gz" }
        return source.pathExtension.uppercased()
    }

    static func editedCopyName(_ source: URL) -> String {
        let leaf = source.lastPathComponent
        let suffix = ArchiveFilename(leaf).map { String(leaf.suffix($0.matchedExtension.count + 1)) }
            ?? "." + source.pathExtension
        let stem = String(leaf.dropLast(suffix.count))
        return stem + "-edited" + suffix
    }

    static func extractionFolder(for source: URL) -> String {
        let leaf = source.lastPathComponent
        let stem = ArchiveFilename.removingExtension(from: leaf) ?? source.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Archive" : stem
    }

    static func extractionTitle(for source: URL?) -> String {
        guard let source else { return "Extract to New Folder" }
        let name = extractionFolder(for: source)
        let label = name.count > 48 ? String(name.prefix(45)) + "…" : name
        return "Extract to “\(label)”"
    }

    static func isTAR(_ source: URL) -> Bool {
        guard let kind = ArchiveFilename(source.lastPathComponent)?.kind else { return false }
        return [.tar, .tarGzip, .tarBzip2].contains(kind)
    }
}
