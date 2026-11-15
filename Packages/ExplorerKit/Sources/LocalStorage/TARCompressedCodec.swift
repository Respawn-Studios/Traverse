import Foundation
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations

/// Concrete wrapper identity is part of the prepared source proof/cache key.
/// A filename admits a candidate; the codec still verifies its complete bytes.
internal enum TARCompressedCodec: String, Sendable {
    case gzip, bzip2
    static func filename(_ name: String) -> Self? {
        switch ArchiveFilename(name)?.kind {
        case .tarGzip: .gzip
        case .tarBzip2: .bzip2
        default: nil
        }
    }
    func accepts(_ header: Data) -> Bool {
        switch self {
        case .gzip: header.count >= 3 && header.prefix(3) == Data([0x1f, 0x8b, 8])
        case .bzip2: header.count >= 4 && header.prefix(3) == Data("BZh".utf8) && (49...57).contains(header[3])
        }
    }
    var authoredFormat: AuthoredArchiveFormat {
        self == .gzip ? .strictPortableTARGzip : .strictPortableTARBzip2
    }
}
