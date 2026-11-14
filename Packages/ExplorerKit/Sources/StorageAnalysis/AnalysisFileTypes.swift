import Foundation

/// Result provenance, not a preference that can reinterpret an existing scan.
public enum AnalysisClassificationRevision: Int, Sendable {
    case v2 = 2, v3 = 3, v4 = 4
    public var fileTypes: [AnalysisFileType] {
        switch self { case .v2: Array(AnalysisFileType.allCases.prefix(15))
        case .v3: Array(AnalysisFileType.allCases.prefix(16)); case .v4: AnalysisFileType.allCases }
    }
    var supportsApplicationRules: Bool { self != .v2 }
}

/// Filename hints only. A suffix does not establish contents, ownership, active
/// use or cleanup safety. Regular-file namespace bytes partition exactly once.
public enum AnalysisFileType: Int, CaseIterable, Sendable {
    case other, documents, textAndSource, spreadsheets, presentations, images
    case video, audio, archives, diskImages, virtualDisks, models, fonts
    case databases, compiledFiles, applicationResources, dataFiles

    public var title: String {
        switch self {
        case .other: return "Other / no recognized extension"
        case .documents: return "Documents"
        case .textAndSource: return "Text, source and configuration"
        case .spreadsheets: return "Spreadsheets"
        case .presentations: return "Presentations"
        case .images: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archives: return "Archives and packaged assets"
        case .diskImages: return "Disk images"
        case .virtualDisks: return "Virtual disks"
        case .models: return "Model files"
        case .fonts: return "Fonts"
        case .databases: return "Database files"
        case .compiledFiles: return "Compiled code and libraries"
        case .applicationResources: return "Application resources"
        case .dataFiles: return "Data and scientific files"
        }
    }

    public var explanation: String {
        if self == .dataFiles {
            return "Filename-extension hint for tables, arrays, saved objects or other data. Contents, actual formats and cleanup safety were not inspected."
        }
        return self == .other
            ? "No supported filename-extension rule matched. File bodies were not inspected."
            : "Filename-extension hint only; file bodies, actual format and cleanup safety were not inspected."
    }

    static func match(_ path: Data, revision: AnalysisClassificationRevision = .v2) -> Self {
        let start = path.lastIndex(of: 47).map { path.index(after: $0) } ?? path.startIndex
        let name = path[start...]
        guard let dot = name.lastIndex(of: 46), dot != start else { return .other }
        let suffix = name[name.index(after: dot)...]
        guard (1...16).contains(suffix.count), suffix.allSatisfy({ $0 < 128 }) else { return .other }
        // Keep raw names intact. ASCII suffix matching also works for a name
        // whose prefix cannot be decoded as UTF-8; no locale or file I/O needed.
        let ext = String(bytes: suffix.map { (65...90).contains($0) ? $0 + 32 : $0 }, encoding: .utf8)!
        if revision == .v4, ["csv","tsv","parquet","arrow","arrows","feather","orc","avro","npy","npz","h5","hdf5","fits","netcdf","rds","rdata"].contains(ext) { return .dataFiles }
        if revision.supportsApplicationRules {
            switch ext {
            case "car", "nib", "rsrc": return .applicationResources
            case "plist", "strings", "stringsdict", "entitlements", "xcconfig", "xib", "storyboard": return .textAndSource
            case "icns": return .images
            default: break
            }
        }
        switch ext {
        case "pdf", "doc", "docx", "pages", "rtf", "rtfd", "odt", "epub": return .documents
        case "txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonl", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "swift", "rs", "c", "h", "cpp", "hpp", "m", "mm", "py", "pyi", "dart", "js", "jsx", "ts", "tsx", "html", "css", "scss", "sh", "bash", "zsh", "go", "java", "kt", "kts", "sql": return .textAndSource
        case "xls", "xlsx", "xlsm", "numbers", "ods": return .spreadsheets
        case "ppt", "pptx", "key", "odp": return .presentations
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "tif", "tiff", "bmp", "svg", "ico", "dng", "raw", "psd": return .images
        case "mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "mts", "m2ts": return .video
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "alac": return .audio
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2", "txz", "vpk", "pak", "pck": return .archives
        case "dmg", "iso", "img", "sparseimage", "toast": return .diskImages
        case "vmdk", "vdi", "vhd", "vhdx", "qcow", "qcow2", "hdd": return .virtualDisks
        case "gguf", "ggml", "safetensors", "onnx", "mlmodel", "tflite": return .models
        case "ttf", "otf", "woff", "woff2", "ttc": return .fonts
        case "db", "sqlite", "sqlite3", "mdb", "accdb", "duckdb", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm", "sqlite3-wal", "sqlite3-shm": return .databases
        case "dylib", "so", "a", "o", "obj", "dll", "exe", "class", "jar", "wasm", "metallib", "pyc": return .compiledFiles
        default: return .other
        }
    }
}

public struct AnalysisFileTypeSummary: Sendable {
    public let type: AnalysisFileType
    public let bytes: AnalysisByteSubtotals
    public let files: UInt64
}
