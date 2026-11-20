/// Filename-only container identity. Recognition grants no read, write or
/// preparation capability; each consumer still admits its concrete operation.
public struct ArchiveFilename: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case zip, jar, zipPackage, tar, tarGzip, tarBzip2, tarXZ, tarZstandard

        public var isTAR: Bool {
            switch self {
            case .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstandard: true
            case .zip, .jar, .zipPackage: false
            }
        }
    }

    public let kind: Kind
    /// Lowercase suffix without its leading dot; compound suffixes stay whole.
    public let matchedExtension: String

    private static let suffixes: [(String, Kind)] = [
        ("tar.gz", .tarGzip), ("tgz", .tarGzip),
        ("tar.bz2", .tarBzip2), ("tbz2", .tarBzip2), ("tbz", .tarBzip2),
        ("tar.xz", .tarXZ), ("txz", .tarXZ),
        ("tar.zst", .tarZstandard), ("tzst", .tarZstandard),
        ("tar", .tar), ("zip", .zip), ("jar", .jar),
        ("cbz", .zipPackage), ("epub", .zipPackage), ("whl", .zipPackage)
    ]

    public init?(_ filename: String) {
        let lower = filename.lowercased()
        guard let value = Self.suffixes.first(where: { lower.hasSuffix("." + $0.0) }) else { return nil }
        matchedExtension = value.0; kind = value.1
    }

    public static func removingExtension(from filename: String) -> String? {
        guard let value = Self(filename) else { return nil }
        return String(filename.dropLast(value.matchedExtension.count + 1))
    }
}
