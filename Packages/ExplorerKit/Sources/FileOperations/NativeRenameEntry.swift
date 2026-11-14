import Darwin
import Foundation

/// Narrow, qualified native namespace observations. These are not content guards,
/// never-reused incarnation IDs, or authority to follow an item to another parent.
internal struct NativeRenameVolume: Codable, Equatable, Sendable {
    let device: dev_t
    let mountID: Data
    let uuid: Data

    /// Nil means a known unqualified filesystem: ordinary Rename may use its old
    /// tree protocol. Missing/malformed identity on an eligible volume throws.
    static func qualified(in parent: DirectoryAnchor) throws -> Self? {
        var fs = statfs()
        guard fstatfs(parent.fd, &fs) == 0 else { throw posixFailure() }
        let kind = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard kind == "apfs", fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
        let mountPath = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let mount = try DirectoryAnchor(URL(fileURLWithPath: mountPath), resolve: false)
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_ATTRIBUTES)
        let caps = try nativeRenameAttributes(fd: mount.fd, name: nil, attributes: &attributes)
        guard caps.u32(8) & UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_ATTRIBUTES) == UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_ATTRIBUTES),
              caps.count >= 96 else { throw FileOperationFailure.unsupported }
        let format = caps.u32(24), validFormat = caps.u32(40)
        let formatRequired = UInt32(VOL_CAP_FMT_CASE_SENSITIVE | VOL_CAP_FMT_CASE_PRESERVING | VOL_CAP_FMT_PERSISTENTOBJECTIDS)
        guard validFormat & formatRequired == formatRequired else { throw FileOperationFailure.unsupported }
        // Case-sensitive APFS remains on the legacy protocol until separately qualified.
        guard format & UInt32(VOL_CAP_FMT_CASE_SENSITIVE) == 0 else { return nil }
        guard format & UInt32(VOL_CAP_FMT_CASE_PRESERVING | VOL_CAP_FMT_PERSISTENTOBJECTIDS) == UInt32(VOL_CAP_FMT_CASE_PRESERVING | VOL_CAP_FMT_PERSISTENTOBJECTIDS),
              caps.u32(44) & UInt32(VOL_CAP_INT_RENAME_EXCL) != 0,
              caps.u32(28) & UInt32(VOL_CAP_INT_RENAME_EXCL) != 0,
              caps.u32(72) & UInt32(ATTR_CMNEXT_LINKID) != 0 else { throw FileOperationFailure.unsupported }
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        let id = try nativeRenameAttributes(fd: mount.fd, name: nil, attributes: &attributes)
        guard id.count >= 40, id.u32(8) & UInt32(ATTR_VOL_UUID) != 0 else { throw FileOperationFailure.unsupported }
        let uuid = id.subdata(in: 24..<40)
        guard uuid.contains(where: { $0 != 0 }) else { throw FileOperationFailure.unsupported }
        let mountID = withUnsafeBytes(of: fs.f_fsid) { Data($0) }
        return Self(device: parent.identity.device, mountID: mountID, uuid: uuid)
    }

    func validate(in parent: DirectoryAnchor) throws {
        guard try Self.qualified(in: parent) == self else { throw FileOperationFailure.destinationChanged }
    }

    func validateRepresentation() throws {
        guard mountID.count == 8, uuid.count == 16, uuid.contains(where: { $0 != 0 }) else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}

internal struct NativeRenameEntry: Codable, Equatable, Sendable {
    let identity: EntrySnapshot
    let fileID: UInt64
    let linkID: UInt64
    let parentID: UInt64
    let nameBytes: Data

    var name: String { String(decoding: nameBytes, as: UTF8.self) }

    /// Deliberately rejects hard-link topology changes; linkID can change even
    /// while fileID does not. Size, contents, times and permissions are not Undo guards.
    func sameEntry(as other: Self) -> Bool {
        identity.sameObject(as: other.identity) && fileID == other.fileID &&
            linkID == other.linkID && parentID == other.parentID
    }

    static func observe(parent: DirectoryAnchor, name: String) throws -> Self {
        try validateName(name)
        let before = try EntrySnapshot(parent: parent.fd, name: name)
        guard [S_IFREG, S_IFDIR, S_IFLNK].contains(before.type), before.device == parent.identity.device else {
            throw FileOperationFailure.unsupported
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_FILEID | ATTR_CMN_PARENTID)
        attributes.forkattr = UInt32(ATTR_CMNEXT_LINKID)
        let data = try nativeRenameAttributes(fd: parent.fd, name: name, attributes: &attributes)
        guard data.count >= 56, data.u32(4) & attributes.commonattr == attributes.commonattr,
              data.u32(20) & attributes.forkattr == attributes.forkattr else { throw FileOperationFailure.unsupported }
        let offset = Int(data.i32(24)) + 24, length = Int(data.u32(28))
        guard offset >= 56, length > 1, length <= 4096, offset <= data.count,
              length <= data.count - offset, data[offset + length - 1] == 0 else { throw FileOperationFailure.recoveryUncertain }
        let bytes = data.subdata(in: offset..<(offset + length - 1))
        guard let stored = String(data: bytes, encoding: .utf8), Data(stored.utf8) == bytes else { throw FileOperationFailure.unsupported }
        try validateName(stored)
        let fileID = data.u64(32), parentID = data.u64(40), linkID = data.u64(48)
        let after = try EntrySnapshot(parent: parent.fd, name: name)
        guard before.sameObject(as: after), fileID == UInt64(after.inode), parentID == UInt64(parent.identity.inode), linkID != 0 else {
            throw FileOperationFailure.sourceChanged
        }
        return Self(identity: after, fileID: fileID, linkID: linkID, parentID: parentID, nameBytes: bytes)
    }

    static func optional(parent: DirectoryAnchor, name: String) throws -> Self? {
        do { return try observe(parent: parent, name: name) }
        catch FileOperationFailure.notFound { return nil }
    }

    func validateRepresentation() throws {
        guard fileID == UInt64(identity.inode), fileID != 0, linkID != 0, parentID != 0,
              [S_IFREG, S_IFDIR, S_IFLNK].contains(identity.type),
              let string = String(data: nameBytes, encoding: .utf8), Data(string.utf8) == nameBytes else {
            throw FileOperationFailure.recoveryUncertain
        }
        try validateName(string)
    }
}

/// Returned fields are packed to 4-byte boundaries by Darwin. Decode explicitly
/// with unaligned loads; never infer Swift structure padding or accept truncation.
private func nativeRenameAttributes(fd: Int32, name: String?, attributes: inout attrlist) throws -> Data {
    var bytes = Data(count: 8192)
    let options = UInt(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_REPORT_FULLSIZE)
    let result = bytes.withUnsafeMutableBytes { raw in
        if let name { return getattrlistat(fd, name, &attributes, raw.baseAddress!, raw.count, options) }
        return fgetattrlist(fd, &attributes, raw.baseAddress!, raw.count, UInt32(options))
    }
    guard result == 0 else { throw posixFailure() }
    let length = Int(bytes.u32(0))
    guard length >= 24, length <= bytes.count else { throw FileOperationFailure.recoveryUncertain }
    return bytes.prefix(length)
}

private extension Data {
    func u32(_ offset: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
    func i32(_ offset: Int) -> Int32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) } }
    func u64(_ offset: Int) -> UInt64 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) } }
}
