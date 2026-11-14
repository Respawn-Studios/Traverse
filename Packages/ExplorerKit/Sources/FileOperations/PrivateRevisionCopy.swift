import Darwin
import Foundation

internal enum NativeCopyProfile: Sendable { case ordinary, privateTextRevisionV1 }

internal func preflightPrivateTextCopyEntry(parent: Int32, name: String) throws {
    var value = stat()
    guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
          value.st_size >= 0, value.st_size <= 1_048_576,
          value.st_flags == 0 || value.st_flags == UInt32(UF_TRACKED) else { throw FileOperationFailure.unsupported }
}

private func validatePrivateTextCopyMetadata(_ fd: Int32) throws {
    let length = flistxattr(fd, nil, 0, 0)
    guard length >= 0 else { throw posixFailure() }
    guard length <= 65_536 else { throw FileOperationFailure.unsupported }
    var names = [CChar](repeating: 0, count: max(1, length))
    guard flistxattr(fd, &names, length, 0) == length else { throw FileOperationFailure.sourceChanged }
    var charged = length
    for bytes in names.prefix(length).split(separator: 0) {
        guard let name = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw FileOperationFailure.unsupported }
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size >= 0 else { throw posixFailure() }
        let (total, overflow) = charged.addingReportingOverflow(size)
        guard !overflow, total <= 262_144 else { throw FileOperationFailure.unsupported }; charged = total
    }
    errno = 0
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let size = acl_size(acl)
        guard size >= 0 else { throw posixFailure() }
        let (total, overflow) = charged.addingReportingOverflow(size)
        guard !overflow, total <= 262_144 else { throw FileOperationFailure.unsupported }
    } else if errno != ENOENT { throw posixFailure() }
}

// A private staging-copy policy only. It never changes an existing source or
// installs a replacement. The caller retains its private-area/access authority.
internal func validatePrivateTextCopySource(_ fd: Int32, destinationParent: Int32,
                                          depth: Int, relative: String) throws {
    var source = stat(), parent = stat(), volume = statfs()
    guard fstat(fd, &source) == 0, fstat(destinationParent, &parent) == 0,
          fstatfs(fd, &volume) == 0 else { throw posixFailure() }
    let type = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    guard depth == 0, relative.isEmpty, source.st_mode & S_IFMT == S_IFREG,
          source.st_uid == geteuid(), source.st_nlink == 1, source.st_size >= 0, source.st_size <= 1_048_576,
          source.st_flags == 0 || source.st_flags == UInt32(UF_TRACKED),
          parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(), parent.st_mode & 0o077 == 0,
          parent.st_dev == source.st_dev, type == "apfs", volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
        throw FileOperationFailure.unsupported
    }
    try validatePrivateTextCopyMetadata(fd)
    // Recheck the exact destination descriptor on every private copy. The
    // ready event is evidence of an earlier check, never a permission cache.
    let duplicate = fcntl(destinationParent, F_DUPFD_CLOEXEC, 3)
    guard duplicate >= 0 else { throw posixFailure() }; defer { close(duplicate) }
    errno = 0
    if let acl = acl_get_fd_np(duplicate, ACL_TYPE_EXTENDED) {
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else { throw FileOperationFailure.accessDenied }
    } else if errno != ENOENT { throw posixFailure() }
}
internal func preservePrivateTextCopyBirth(source: Int32, destination: Int32, created: EntrySnapshot) throws {
    var before = stat(), copy = stat()
    guard fstat(source, &before) == 0, fstat(destination, &copy) == 0 else { throw posixFailure() }
    guard before.st_mode & S_IFMT == S_IFREG, copy.st_mode & S_IFMT == S_IFREG,
          before.st_uid == geteuid(), copy.st_uid == geteuid(), before.st_nlink == 1, copy.st_nlink == 1,
          before.st_dev == copy.st_dev, before.st_ino != copy.st_ino,
          copy.st_dev == created.device, copy.st_ino == created.inode, created.type == S_IFREG,
          before.st_size == copy.st_size else { throw FileOperationFailure.copyMetadataMismatch }
    let original = try EntrySnapshot(fd: source), copied = try EntrySnapshot(fd: destination)
    var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = UInt32(ATTR_CMN_CRTIME)
    var birth = before.st_birthtimespec
    guard fsetattrlist(destination, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0 else { throw posixFailure() }
    var after = stat(), sourceAfter = stat()
    guard fstat(destination, &after) == 0, fstat(source, &sourceAfter) == 0 else { throw posixFailure() }
    guard try EntrySnapshot(fd: source) == original,
          before.st_uid == sourceAfter.st_uid, before.st_gid == sourceAfter.st_gid,
          before.st_nlink == sourceAfter.st_nlink, before.st_flags == sourceAfter.st_flags,
          after.st_dev == copied.device, after.st_ino == copied.inode, after.st_mode == copy.st_mode,
          after.st_size == copy.st_size, after.st_uid == copy.st_uid, after.st_gid == copy.st_gid,
          after.st_nlink == copy.st_nlink, after.st_flags == copy.st_flags,
          after.st_mtimespec.tv_sec == copy.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == copy.st_mtimespec.tv_nsec,
          after.st_birthtimespec.tv_sec == birth.tv_sec, after.st_birthtimespec.tv_nsec == birth.tv_nsec else {
        throw FileOperationFailure.copyMetadataMismatch
    }
}
