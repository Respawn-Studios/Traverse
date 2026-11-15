import Foundation
import zlib

/// Bounded RFC 1952 wrapper data. Names and comments are opaque bytes, never
/// paths or text used to choose an export destination. XFL is codec-generated.
internal struct GzipArchiveHeader: Sendable, Equatable {
    static let maximumBytes = 65_536
    let modificationTime: UInt32
    let operatingSystem: UInt8
    let text: Bool
    let extra: Data?
    let name: Data?
    let comment: Data?
    let headerCRC: Bool

    init(modificationTime: UInt32, operatingSystem: UInt8, text: Bool,
        extra: Data? = nil, name: Data? = nil, comment: Data? = nil, headerCRC: Bool = false) {
        self.modificationTime = modificationTime; self.operatingSystem = operatingSystem; self.text = text
        self.extra = extra; self.name = name; self.comment = comment; self.headerCRC = headerCRC
    }
    init(_ bytes: Data) throws {
        guard bytes.count >= 10, bytes.prefix(3) == Data([0x1f, 0x8b, 8]), bytes[3] & 0xe0 == 0 else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        let limit = min(bytes.count, Self.maximumBytes), flags = bytes[3]
        var offset = 10
        func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= limit - offset else { throw TARMemberEditFailure.unsupportedArchive }
            defer { offset += count }; return bytes.subdata(in: offset..<(offset + count))
        }
        func terminated() throws -> Data {
            guard offset < limit, let end = bytes[offset..<limit].firstIndex(of: 0) else {
                throw TARMemberEditFailure.unsupportedArchive
            }
            defer { offset = end + 1 }; return bytes.subdata(in: offset..<end)
        }
        if flags & 4 != 0 {
            let size = try take(2)
            extra = try take(Int(size[0]) | Int(size[1]) << 8)
        } else { extra = nil }
        name = flags & 8 != 0 ? try terminated() : nil
        comment = flags & 16 != 0 ? try terminated() : nil
        headerCRC = flags & 2 != 0
        if headerCRC {
            let expected = bytes.prefix(offset).withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(offset)) }
            let crc = try take(2)
            guard UInt16(truncatingIfNeeded: expected) == UInt16(crc[0]) | UInt16(crc[1]) << 8 else {
                throw TARMemberEditFailure.unsupportedArchive
            }
        }
        modificationTime = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << ($1 * 8) }
        operatingSystem = bytes[9]; text = flags & 1 != 0
    }
}
