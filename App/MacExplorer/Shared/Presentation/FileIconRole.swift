import Foundation

/// Presentation-only classification of supplied names. Never inspects a file.
enum FileIconRole: String, CaseIterable {
    case directory, package, symbolicLink, file, other, cut
    case code, configuration, database, document, image, audio, video, archive
    case application, diskImage, font, pdf, spreadsheet, presentation, model3D
    case shortcut, calendar, contact, log, patch

    var title: String {
        switch self {
        case .directory: "Folder"
        case .package: "Package"
        case .symbolicLink: "Symbolic link"
        case .file: "File"
        case .other: "Item"
        case .cut: "Cut: ready to move"
        case .code: "Source code"
        case .configuration: "Configuration"
        case .database: "Database"
        case .document: "Document"
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .archive: "Archive"
        case .application: "Application"
        case .diskImage: "Disk image"
        case .font: "Font"
        case .pdf: "PDF document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .model3D: "3D model"
        case .shortcut: "Web shortcut"
        case .calendar: "Calendar"
        case .contact: "Contact card"
        case .log: "Log"
        case .patch: "Patch"
        }
    }

    static func classify(name: String, kind: String) -> Self {
        switch kind {
        case "directory": return .directory
        case "package":
            switch (name as NSString).pathExtension.lowercased() {
            case "app": return .application
            case "sparsebundle": return .diskImage
            case "numbers": return .spreadsheet
            case "key": return .presentation
            case "pages": return .document
            default: return .package
            }
        case "symbolicLink": return .symbolicLink
        case "file": break
        default: return .other
        }
        let lower = name.lowercased()
        switch lower {
        case "dockerfile", "containerfile", "makefile", "gemfile", "procfile", "cmakelists.txt",
             ".gitignore", ".gitattributes", ".env", ".editorconfig", ".npmrc", ".yarnrc":
            return .configuration
        default: break
        }
        if [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].contains(where: lower.hasSuffix) { return .archive }
        let suffix = (lower as NSString).pathExtension
        switch suffix {
        case "swift", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "py", "js", "jsx", "ts", "tsx", "go", "java", "kt", "kts", "dart", "sh", "bash", "zsh", "fish", "ps1", "html", "css", "scss", "sass", "less", "vue", "svelte", "astro", "rb", "lua", "r", "pl", "ex", "exs", "zig", "cmake", "ipynb": return .code
        case "json", "jsonc", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "xml", "plist", "conf", "config", "lock": return .configuration
        case "db", "sqlite", "sqlite3", "sql": return .database
        case "txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "pages", "epub": return .document
        case "pdf": return .pdf
        case "xls", "xlsx", "xlsm", "ods", "csv", "tsv", "numbers": return .spreadsheet
        case "ppt", "pptx", "odp", "key": return .presentation
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "tif", "tiff", "bmp", "ico", "icns", "svg", "psd", "ai", "sketch": return .image
        case "mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "opus", "midi", "mid": return .audio
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpeg", "mpg", "mts": return .video
        case "zip", "tar", "gz", "bz2", "xz", "zst", "7z", "rar", "tgz", "tbz", "tbz2", "txz", "lz", "lzma": return .archive
        case "pkg", "mpkg": return .package
        case "dmg", "iso", "img", "sparseimage", "vhd", "vhdx", "vmdk", "vdi", "qcow", "qcow2": return .diskImage
        case "ttf", "otf", "ttc", "dfont", "woff", "woff2": return .font
        case "obj", "stl", "gltf", "glb", "usdz", "usd", "usda", "usdc", "fbx", "blend": return .model3D
        case "webloc", "url", "inetloc": return .shortcut
        case "ics", "ical", "ifb": return .calendar
        case "vcf", "vcard": return .contact
        case "log": return .log
        case "diff", "patch": return .patch
        default: return .file
        }
    }
}
