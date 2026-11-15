import Foundation

/// The writable gzip profile preserves every supported wrapper field. Optional
/// headers stay browseable, but cannot be silently discarded during a rewrite.
internal struct GzipArchiveHeader: Sendable, Equatable {
    let modificationTime: UInt32
    let operatingSystem: UInt8
    let text: Bool

    init(modificationTime: UInt32, operatingSystem: UInt8, text: Bool) {
        self.modificationTime = modificationTime; self.operatingSystem = operatingSystem; self.text = text
    }
    init(_ bytes: Data) throws {
        guard bytes.count == 10, bytes.prefix(3) == Data([0x1f, 0x8b, 8]), bytes[3] & ~1 == 0 else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        modificationTime = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << ($1 * 8) }
        operatingSystem = bytes[9]; text = bytes[3] == 1
    }
}
