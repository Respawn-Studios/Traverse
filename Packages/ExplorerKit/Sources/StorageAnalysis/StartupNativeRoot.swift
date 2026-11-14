import Darwin
import Foundation

struct StartupNativeIdentity: Equatable, Sendable {
    let object: AnalysisObjectIdentity
    let returnedDevice: UInt32, fsid0: Int32, fsid1: Int32
    let realDevice: UInt32, realInode: UInt64, realFSID0: Int32, realFSID1: Int32
    let volume: APFSIdentity<APFSVolumeTag>
    let mountedFrom: String
}

/// Descriptor-only root metadata. All returned masks are checked before a
/// value is used; absent real identity does not become a returned zero.
final class StartupNativeRoot: @unchecked Sendable {
    let descriptor: Int32
    let url: URL
    let identity: StartupNativeIdentity
    init(url: URL, info: StartupInfoFacts) throws {
        let original = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard original >= 0 else { throw StartupStorageFailure.unavailable }
        let safe = fcntl(original, F_DUPFD_CLOEXEC, 10); close(original)
        guard safe >= 0 else { throw StartupStorageFailure.unavailable }
        descriptor = safe; self.url = url
        do { identity = try Self.observe(safe, expected: info) }
        catch { close(safe); throw error }
    }
    deinit { close(descriptor) }
    func revalidate(info: StartupInfoFacts) throws {
        let fresh = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fresh >= 0 else { throw StartupStorageFailure.changed }; defer { close(fresh) }
        guard try Self.observe(descriptor, expected: info) == identity,
              try Self.observe(fresh, expected: info) == identity else { throw StartupStorageFailure.changed }
    }
    private static func observe(_ fd: Int32, expected: StartupInfoFacts) throws -> StartupNativeIdentity {
        var value = stat(), filesystem = statfs()
        guard fstat(fd, &value) == 0, fstatfs(fd, &filesystem) == 0,
              value.st_mode & S_IFMT == S_IFDIR, value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StartupStorageFailure.nativeIdentityUnavailable }
        func string<T>(_ tuple: inout T) throws -> String {
            try withUnsafeBytes(of: &tuple) { bytes in
                guard let end = bytes.firstIndex(of: 0),
                      let value = String(bytes: bytes[..<end], encoding: .utf8) else { throw StartupStorageFailure.nativeIdentityUnavailable }
                return value
            }
        }
        let mountedFrom = try string(&filesystem.f_mntfromname)
        guard try string(&filesystem.f_fstypename) == "apfs", mountedFrom == "/dev/" + expected.device,
              try string(&filesystem.f_mntonname) == expected.mount else { throw StartupStorageFailure.changed }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_FILEID)
        attributes.forkattr = UInt32(ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_REALFSID)
        var buffer = [UInt8](repeating: 0, count: 256)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_RETURN_REALDEV)
        guard fgetattrlist(fd, &attributes, &buffer, buffer.count, options) == 0 else { throw StartupStorageFailure.nativeIdentityUnavailable }
        let facts = try decode(Data(buffer))
        var volumeAttributes = attrlist()
        volumeAttributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        volumeAttributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        volumeAttributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        buffer = [UInt8](repeating: 0, count: 64)
        guard fgetattrlist(fd, &volumeAttributes, &buffer, buffer.count, 0) == 0 else { throw StartupStorageFailure.nativeIdentityUnavailable }
        let volume = try decodeVolume(Data(buffer))
        // RETURN_REALDEV also returns the physical inode on a firmlink view.
        // fstat's namespace identity and this native physical identity are
        // separately retained and revalidated; equality is not an APFS rule.
        guard volume == expected.volume else { throw StartupStorageFailure.changed }
        return .init(object: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino),
            returnedDevice: facts.device, fsid0: filesystem.f_fsid.val.0, fsid1: filesystem.f_fsid.val.1,
            realDevice: facts.realDevice, realInode: facts.inode, realFSID0: facts.realFSID0, realFSID1: facts.realFSID1,
            volume: volume, mountedFrom: mountedFrom)
    }
    struct ExtendedFields: Equatable, Sendable {
        let device: UInt32, inode: UInt64
        let realDevice: UInt32, realFSID0: Int32, realFSID1: Int32
    }
    static func decode(_ bytes: Data) throws -> ExtendedFields {
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        }
        guard bytes.count >= 48, u32(0) == 48,
              u32(4) == UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_FILEID),
              u32(8) == 0,
              u32(12) == 0, u32(16) == 0,
              u32(20) == UInt32(ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_REALFSID) else { throw StartupStorageFailure.nativeIdentityUnavailable }
        let inode = bytes[28..<36].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        guard inode > 0, u32(24) > 0, u32(36) > 0, u32(24) == u32(36) else { throw StartupStorageFailure.nativeIdentityUnavailable }
        return .init(device: u32(24), inode: inode,
            realDevice: u32(36), realFSID0: Int32(bitPattern: u32(40)), realFSID1: Int32(bitPattern: u32(44)))
    }
    static func decodeVolume(_ bytes: Data) throws -> APFSIdentity<APFSVolumeTag> {
        func u32(_ offset: Int) -> UInt32 { bytes[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) } }
        guard bytes.count >= 40, u32(0) == 40, u32(4) == UInt32(ATTR_CMN_RETURNED_ATTRS),
              u32(8) == UInt32(ATTR_VOL_UUID), u32(12) == 0, u32(16) == 0, u32(20) == 0 else { throw StartupStorageFailure.nativeIdentityUnavailable }
        let v = Array(bytes[24..<40])
        let uuid = UUID(uuid: (v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11],v[12],v[13],v[14],v[15]))
        return try APFSIdentity(uuid.uuidString)
    }

}
