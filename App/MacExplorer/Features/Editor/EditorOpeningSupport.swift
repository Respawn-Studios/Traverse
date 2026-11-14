import Foundation

/// Authored text formats only. A name does not prove that a particular file
/// passes the editor's existing access, UTF-8, size or line checks.
enum EditorOpeningSupport {
    struct FileType: Identifiable, Equatable, Sendable {
        let fileExtension: String
        let title: String
        var filenames: [String] = []
        var id: String { fileExtension }
        var sampleFilename: String { filenames.first ?? "Generated." + fileExtension }
        var matchLabel: String { filenames.isEmpty ? "." + fileExtension : filenames.joined(separator: ", ") }
    }
    static let fileTypes: [FileType] = [
        .init(fileExtension: "bash", title: "Bash"),
        .init(fileExtension: "c", title: "C source"),
        .init(fileExtension: "cc", title: "C++ source"),
        .init(fileExtension: "cfg", title: "Configuration"),
        .init(fileExtension: "cjs", title: "JavaScript"),
        .init(fileExtension: "conf", title: "Configuration"),
        .init(fileExtension: "cpp", title: "C++ source"),
        .init(fileExtension: "css", title: "CSS"),
        .init(fileExtension: "csv", title: "Comma-separated text"),
        .init(fileExtension: "cts", title: "TypeScript"),
        .init(fileExtension: "cxx", title: "C++ source"),
        .init(fileExtension: "h", title: "C / Objective-C header"),
        .init(fileExtension: "hh", title: "C++ header"),
        .init(fileExtension: "hpp", title: "C++ header"),
        .init(fileExtension: "htm", title: "HTML source"),
        .init(fileExtension: "html", title: "HTML source"),
        .init(fileExtension: "hxx", title: "C++ header"),
        .init(fileExtension: "ini", title: "Configuration"),
        .init(fileExtension: "js", title: "JavaScript"),
        .init(fileExtension: "json", title: "JSON"),
        .init(fileExtension: "jsonc", title: "JSON with comments"),
        .init(fileExtension: "jsx", title: "JavaScript"),
        .init(fileExtension: "less", title: "Less"),
        .init(fileExtension: "log", title: "Text log"),
        .init(fileExtension: "m", title: "Objective-C source"),
        .init(fileExtension: "markdown", title: "Markdown"),
        .init(fileExtension: "md", title: "Markdown"),
        .init(fileExtension: "mjs", title: "JavaScript"),
        .init(fileExtension: "mm", title: "Objective-C++ source"),
        .init(fileExtension: "mts", title: "TypeScript"),
        .init(fileExtension: "properties", title: "Configuration"),
        .init(fileExtension: "py", title: "Python"),
        .init(fileExtension: "pyw", title: "Python"),
        .init(fileExtension: "rs", title: "Rust"),
        .init(fileExtension: "scss", title: "SCSS"),
        .init(fileExtension: "sh", title: "Shell"),
        .init(fileExtension: "sql", title: "SQL"),
        .init(fileExtension: "swift", title: "Swift"),
        .init(fileExtension: "text", title: "Plain text"),
        .init(fileExtension: "toml", title: "TOML"),
        .init(fileExtension: "ts", title: "TypeScript"),
        .init(fileExtension: "tsv", title: "Tab-separated text"),
        .init(fileExtension: "tsx", title: "TypeScript"),
        .init(fileExtension: "txt", title: "Plain text"),
        .init(fileExtension: "xml", title: "XML source"),
        .init(fileExtension: "yaml", title: "YAML"),
        .init(fileExtension: "yml", title: "YAML"),
        .init(fileExtension: "zsh", title: "Zsh"),
        .init(fileExtension: "dockerfile", title: "Container build files", filenames: ["Dockerfile", "Containerfile"]),
        .init(fileExtension: "makefile", title: "Makefiles", filenames: ["Makefile", "GNUmakefile"]),
        .init(fileExtension: "gitconfig", title: "Git configuration", filenames: [".gitignore", ".gitattributes", ".gitmodules", ".gitconfig"]),
        .init(fileExtension: "shellprofile", title: "Shell profiles", filenames: [".profile", ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".zshenv"]),
        .init(fileExtension: "env", title: "Environment files", filenames: [".env", ".env.local", ".env.development", ".env.production", ".env.test"]),
        .init(fileExtension: "readme", title: "Plain documentation", filenames: ["README", "LICENSE", "LICENCE", "NOTICE", "AUTHORS", "CHANGELOG", "COPYING"])
    ]
    static let extensions = Set(fileTypes.map(\.fileExtension))
    /// A finite name family shares the existing file-type preference key. No
    /// content read, wildcard execution or stored-rule migration is involved.
    static func key(forFilename name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("/"), !name.utf8.contains(0) else { return nil }
        if let family = fileTypes.first(where: { $0.filenames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) {
            return family.fileExtension
        }
        return EditorPreferences.extensionKey((name as NSString).pathExtension)
    }
    static func recommendedTarget(for key: String) -> EditorOpeningTarget {
        extensions.contains(key) ? .traverse : .systemDefault
    }
}
