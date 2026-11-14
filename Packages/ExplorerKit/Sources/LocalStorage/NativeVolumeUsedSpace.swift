import Darwin
import Foundation

/// A separate filesystem observation, not capacity minus free, exclusive file
/// allocation, or a prediction of space released by deletion.
public struct NativeVolumeUsedSpace: Equatable, Sendable {
    public let bytes: UInt64
    public let observedAt: Date
    public init(bytes: UInt64, observedAt: Date = Date()) {
        self.bytes = bytes; self.observedAt = observedAt
    }

    /// A bounded blocking metadata call. The caller owns the directory
    /// descriptor, access lifetime, off-main scheduling and path/volume fence.
    /// Unsupported, denied and malformed responses remain unavailable.
    public static func read(directoryDescriptor: Int32) -> Self? {
        var info = stat()
        guard fstat(directoryDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = (UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED))
        var buffer = Data(count: 32)
        let status = buffer.withUnsafeMutableBytes {
            fgetattrlist(directoryDescriptor, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard status == 0, let bytes = decode(buffer) else { return nil }
        return .init(bytes: bytes, observedAt: Date())
    }

    /// Exact used-only request profile: UInt32 length, five returned masks,
    /// then an optional signed off_t. No naturally aligned Swift wire struct.
    static func decode(_ data: Data) -> UInt64? {
        guard data.count >= 24 else { return nil }
        return data.withUnsafeBytes { bytes in
            let length = Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let common = bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let volume = bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            guard length <= data.count, length <= 32, length >= 24,
                  common == UInt32(ATTR_CMN_RETURNED_ATTRS),
                  volume & ~(UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)) == 0,
                  [12, 16, 20].allSatisfy({ bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self) == 0 }),
                  volume & UInt32(ATTR_VOL_SPACEUSED) != 0, length == 32 else { return nil }
            let used = bytes.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            return UInt64(exactly: used)
        }
    }
}
