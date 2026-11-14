import Darwin
import Foundation

/// Descriptor-bound APFS volume identity for durable workspace records. The
/// mount device number is retained only for checks within one live operation.
enum ConnectionWorkspaceVolumeIdentity {
    static func read(_ descriptor: Int32) throws -> UUID {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 64)
        guard fgetattrlist(descriptor, &attributes, &bytes, bytes.count, 0) == 0 else {
            throw ConnectionWorkspaceFailure.unsafe
        }
        func word(_ offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].enumerated().reduce(0) {
                $0 | (UInt32($1.element) << ($1.offset * 8))
            }
        }
        guard word(0) == 40, word(4) == UInt32(ATTR_CMN_RETURNED_ATTRS),
              word(8) == UInt32(ATTR_VOL_UUID), word(12) == 0,
              word(16) == 0, word(20) == 0 else { throw ConnectionWorkspaceFailure.unsafe }
        let value = Array(bytes[24..<40])
        guard value.contains(where: { $0 != 0 }) else { throw ConnectionWorkspaceFailure.unsafe }
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
}
